class_name SemanticZoom
extends RefCounted

## SemanticZoom — ONE normalized visual-zoom authority for battlefield UX.
## Derived from the live Step2RCameraController range (0.30 far .. 8.00 close,
## larger value = closer view, default 1.15). Presentation only: zoom_t never
## carries gameplay truth, and every scale curve below is continuous
## (smoothstep blends, no hard threshold switches).

const ZOOM_MIN: float = 0.30
const ZOOM_MAX: float = 8.0
const ZOOM_DEFAULT: float = 1.15

# Formation world-presentation multipliers per semantic level (§8).
const FORMATION_MACRO: float = 0.82
const FORMATION_STRATEGIC: float = 0.92
const FORMATION_TACTICAL: float = 1.00
const FORMATION_CLOSE: float = 0.92

# World-space label readability: perceived screen px target for troop counts (§9).
# Target screen perceived size: roughly 14–20 px equivalent across all zoom levels.
# Sizing must NOT allow 40–80 px-looking giant numbers at close zoom.
const LABEL_SCREEN_PX: float = 15.0
const LABEL_SCALE_MIN: float = 0.16
const LABEL_SCALE_MAX: float = 2.00

# Transient floating combat text may shrink further (short-lived, z=80).
const FLOAT_SCALE_MIN: float = 0.14

# HP bar: 24x4 px texture (§10). Width holds ~45-60% of hex at tactical; screen height ~4-7px.
const HP_WIDTH_WORLD: float = 24.0
const HP_TACTICAL_SCREEN_W: float = 26.0
const HP_SCREEN_H: float = 5.0
const HP_SX_MIN: float = 0.12
const HP_SX_MAX: float = 1.35
const HP_SY_MIN: float = 0.15
const HP_SY_MAX: float = 1.40

# Badge container multiplier (§11): hierarchy inverts with zoom. Zoomed out,
# the badge is the PRIMARY identification aid (formation detail unreadable);
# zoomed in, formation art takes over and the badge yields.
const BADGE_MACRO: float = 2.40
const BADGE_STRATEGIC: float = 1.40
const BADGE_TACTICAL: float = 1.00
const BADGE_CLOSE: float = 0.85

# Known-route exemption contrast multiplier by zoom (§15): roads read
# stronger at macro, settle into terrain at close. Geometry never widens.
const ROUTE_CONTRAST_MACRO: float = 1.18
const ROUTE_CONTRAST_CLOSE: float = 0.88


## Expose primary helper as requested by §5
static func get_semantic_zoom_t(zoom_val: float) -> float:
	return zoom_t(zoom_val)


## Normalized visual zoom: 0.0 = far strategic, 1.0 = close tactical.
## Logarithmic: camera zoom is multiplicative (0.30 overview .. 8.00 close),
## so equal wheel-travel maps to equal semantic travel. This lands the
## camera's own documented bands onto macro / strategic / tactical / close.
static func zoom_t(zoom_val: float) -> float:
	var c: float = clampf(zoom_val, ZOOM_MIN, ZOOM_MAX)
	return log(c / ZOOM_MIN) / log(ZOOM_MAX / ZOOM_MIN)


static func sstep(a: float, b: float, x: float) -> float:
	return smoothstep(a, b, x)


## Continuous four-level weights (macro 0.0-0.25, strategic 0.25-0.50, tactical 0.50-0.78, close 0.78-1.0).
## Partition of unity; no popping at boundaries.
static func level_weights(t: float) -> Vector4:
	var tc: float = clampf(t, 0.0, 1.0)
	var a: float = sstep(0.15, 0.35, tc) # macro -> strategic (centered at 0.25)
	var b: float = sstep(0.40, 0.60, tc) # strategic -> tactical (centered at 0.50)
	var c: float = sstep(0.68, 0.88, tc) # tactical -> close (centered at 0.78)
	var w_close: float = c
	var w_tact: float = (1.0 - c) * b
	var w_strat: float = (1.0 - c) * (1.0 - b) * a
	var w_macro: float = (1.0 - c) * (1.0 - b) * (1.0 - a)
	return Vector4(w_macro, w_strat, w_tact, w_close)


## Partial-compensation formation multiplier (§8). Never fully counters the
## camera (macro formations stay readable) and never fully inherits it
## (close formations stop just under tactical size).
static func formation_mult(t: float) -> float:
	var w: Vector4 = level_weights(t)
	return (FORMATION_MACRO * w.x + FORMATION_STRATEGIC * w.y
		+ FORMATION_TACTICAL * w.z + FORMATION_CLOSE * w.w)


static func formation_mult_for_zoom(zoom_val: float) -> float:
	return formation_mult(zoom_t(zoom_val))


## Badge container multiplier (§11): 2.40 macro → 1.40 strategic →
## 1.00 tactical → 0.85 close, blended continuously.
static func badge_mult(t: float) -> float:
	var w: Vector4 = level_weights(t)
	return (BADGE_MACRO * w.x + BADGE_STRATEGIC * w.y
		+ BADGE_TACTICAL * w.z + BADGE_CLOSE * w.w)


static func badge_mult_for_zoom(zoom_val: float) -> float:
	return badge_mult(zoom_t(zoom_val))


## World-space label scale so perceived screen text stays ~LABEL_SCREEN_PX (~14-18px).
## Labels never explode at close zoom and stay compact at macro.
static func label_scale(zoom_val: float, font_px: float) -> float:
	var z: float = maxf(zoom_val, 0.05)
	var s: float = LABEL_SCREEN_PX / (maxf(font_px, 1.0) * z)
	return clampf(s, LABEL_SCALE_MIN, LABEL_SCALE_MAX)


## Dynamic outline size for labels (§9: "no giant outline").
## Prevents 24px thick black outlines at high camera zoom.
static func label_outline_size(zoom_val: float) -> int:
	if zoom_val >= 3.0:
		return 1
	elif zoom_val >= 1.6:
		return 1
	return 2


static func float_text_scale(zoom_val: float, font_px: float) -> float:
	var z: float = maxf(zoom_val, 0.05)
	var s: float = LABEL_SCREEN_PX / (maxf(font_px, 1.0) * z)
	return clampf(s, FLOAT_SCALE_MIN, LABEL_SCALE_MAX)


## HP bar node scale (§10): constant restrained screen footprint across zoom.
static func hp_scale(zoom_val: float) -> Vector2:
	var z: float = maxf(zoom_val, 0.05)
	var sx: float = clampf(HP_TACTICAL_SCREEN_W / (HP_WIDTH_WORLD * z), HP_SX_MIN, HP_SX_MAX)
	var sy: float = clampf((HP_SCREEN_H / 4.0) / z * 1.15, HP_SY_MIN, HP_SY_MAX)
	return Vector2(sx, sy)


## Objective / stronghold badge scale helper (§14):
## Macro: strong compact icon + short label
## Strategic/Tactical: readable icon + full label
## Close: restrained, allows structure art to shine without ballooning.
static func objective_badge_scale(zoom_val: float, is_capital: bool) -> Vector2:
	var z: float = maxf(zoom_val, 0.10)
	var base: float = 1.30 if is_capital else 1.10
	var t: float = zoom_t(zoom_val)
	var w: Vector4 = level_weights(t)
	var mult: float = 1.12 * w.x + 1.00 * w.y + 0.88 * w.z + 0.68 * w.w
	# Inverse scale capped so perceived screen size is 18-24px equivalent
	var s: float = (base * mult) / (0.88 * pow(z, 0.70))
	s = clampf(s, 0.24, 1.35)
	return Vector2(s, s)


## Objective label text formatting by semantic zoom level (§14):
static func objective_label_text(structure_name: String, is_capital: bool, zoom_t_val: float) -> String:
	var sname: String = structure_name
	if sname == "호뢰관 (虎牢關)":
		if zoom_t_val < 0.25:
			return "[護] 호뢰관"
		elif zoom_t_val > 0.78:
			return "[護] 호뢰관"
		else:
			return "[護] 호뢰관 (虎牢關)"
	elif sname == "낙양 (洛陽)":
		if zoom_t_val < 0.25:
			return "★ 낙양"
		elif zoom_t_val > 0.78:
			return "★ 낙양 ★"
		else:
			return "★ 낙양 (洛陽) ★"
	# Fallback for any other objective
	if is_capital:
		return "★ %s ★" % sname
	return "[護] %s" % sname


## Road exemption contrast (§15): geometry untouched, alpha breathes only.
static func route_contrast(t: float) -> float:
	var tc: float = clampf(t, 0.0, 1.0)
	return lerpf(ROUTE_CONTRAST_MACRO, ROUTE_CONTRAST_CLOSE, sstep(0.1, 0.9, tc))

