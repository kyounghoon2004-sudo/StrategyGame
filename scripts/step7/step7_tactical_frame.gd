class_name Step7TacticalFrame
extends RefCounted

## LEGACY — fixed one-third sector prototype (LEFT_WING / CENTER / RIGHT_WING).
## Retired as tactical authority by the ADAPTIVE FRIENDLY FORMATION CLUSTERS
## milestone. Canonical authority is now Step7FormationClusters (formation-
## derived L*/C/R* bands, frozen per turn). This file is kept intact ONLY as
## a compatibility adapter: the planner maps SECTOR_CLASS scopes and SECTOR
## targets onto macro wings, and old probes may still call get_sector().
## New code must NOT use get_sector()/classify_n() for tactical decisions.
##
## Battle Tactical Frame — original fixed-partition documentation follows.
##
## Canonical sector authority. The overlay consumes get_sector(); it never
## recreates partition math. Camera/pan/zoom/viewport never affect membership.
##
## FRAME SOURCE (map-independent, no hidden truth):
## - ORIGIN: logical battle center (0, 0) — hexagon center, stable mission geometry.
## - FORWARD: BLUE EAST (+q). Canonical BLUE forward from Step7ActionCommand
##   ("BLUE forward is EAST") and the planner axis model (FORWARD = q).
##   Grounded in stable battle geometry: friendly deployment clusters west
##   (B_HQ_1 at -26,0; BLUE forces q -28..-5) and the canonical objective
##   Capital_Luoyang sits east (14,-5). No enemy positions, no camera, no pixels.
## - LATERAL: logical world Y (HexUtils.hex_to_pixel y = r*42 + q*21).
##   Facing FORWARD (east), LEFT = north = negative Y.
## - SPAN: max |lateral_y| across ACTUAL playable hexes (not fixed numbers).
##   Canonical hexagon R=40 gives +/-1680, but the code derives it every build,
##   so irregular/transformed envelopes still partition by normalized geometry.
##
## PARTITION (geometric bands, inclusive CENTER):
##   n = lateral_y / max_abs_y  in [-1, +1]
##   n < -1/3  -> LEFT_WING
##   n > +1/3  -> RIGHT_WING
##   else      -> CENTER (boundaries inclusive to CENTER, deterministic)
##
## STABILITY: built once per battle (lazy static cache). Units change sector by
## moving; the frame never rotates from formation positions.

const VERSION := "tactical_frame_v1"
const SECTORS: Array = ["LEFT_WING", "CENTER", "RIGHT_WING"]
const ORIGIN := Vector2i(0, 0)
const FORWARD_AXIS := "FORWARD"
const LATERAL_AXIS := "LATERAL_Y"
const THIRD := 1.0 / 3.0

# World-Y geometry mirrors HexUtils.hex_to_pixel (COL_STEP=36, ROW_STEP=42,
# ODD_Q_Y_OFFSET=21). Kept local so the frame has zero pathing/render deps.
const ROW_STEP := 42
const ODD_Q_Y_OFFSET := 21

const BoundaryScript = preload("res://scripts/step2r/step2r_world_boundary.gd")

# Canonical language aliases — DATA ONLY. No parser lives here; a future
# language layer maps words to these tokens, Godot keeps owning membership.
const ALIASES := {
	"LEFT_WING": ["left", "left side", "left wing", "좌", "좌측", "왼쪽", "좌익"],
	"CENTER": ["center", "centre", "middle", "중앙", "중부"],
	"RIGHT_WING": ["right", "right side", "right wing", "우", "우측", "오른쪽", "우익"],
}

static var _sector_by_hex: Dictionary = {}
static var _initialized: bool = false
static var _min_y: float = 0.0
static var _max_y: float = 0.0
static var _max_abs_y: float = 1.0
static var _counts := {"LEFT_WING": 0, "CENTER": 0, "RIGHT_WING": 0}


static func lateral_y(q: int, r: int) -> float:
	return float(r * ROW_STEP + q * ODD_Q_Y_OFFSET)


static func normalized_lateral(q: int, r: int) -> float:
	ensure_initialized()
	if _max_abs_y <= 0.0:
		return 0.0
	return lateral_y(q, r) / _max_abs_y


static func classify_n(n: float) -> String:
	if n < -THIRD:
		return "LEFT_WING"
	if n > THIRD:
		return "RIGHT_WING"
	return "CENTER"


static func ensure_initialized() -> void:
	if _initialized:
		return
	var ys: Array = []
	var coords: Array = []
	for q in range(-BoundaryScript.HEX_RADIUS, BoundaryScript.HEX_RADIUS + 1):
		for r in range(-BoundaryScript.HEX_RADIUS, BoundaryScript.HEX_RADIUS + 1):
			var c := Vector2i(q, r)
			if not BoundaryScript.is_playable_hex(c):
				continue
			coords.append(c)
			ys.append(lateral_y(q, r))
	if ys.is_empty():
		_initialized = true
		return
	_min_y = ys[0]
	_max_y = ys[0]
	for y in ys:
		_min_y = minf(_min_y, float(y))
		_max_y = maxf(_max_y, float(y))
	_max_abs_y = maxf(absf(_min_y), absf(_max_y))
	if _max_abs_y <= 0.0:
		_max_abs_y = 1.0
	_sector_by_hex.clear()
	_counts = {"LEFT_WING": 0, "CENTER": 0, "RIGHT_WING": 0}
	for c in coords:
		var s := classify_n(lateral_y((c as Vector2i).x, (c as Vector2i).y) / _max_abs_y)
		_sector_by_hex["%d,%d" % [(c as Vector2i).x, (c as Vector2i).y]] = s
		_counts[s] = int(_counts.get(s, 0)) + 1
	_initialized = true


## Rebuild from an explicit playable cell set (keys "q,r"). Used for
## irregular/transformed envelopes and map-independence tests. Replaces cache.
static func rebuild_from_cell_data(cell_data: Dictionary) -> Dictionary:
	var ys: Array = []
	var coords: Array = []
	for key in cell_data.keys():
		var parts := str(key).split(",")
		if parts.size() != 2 or not parts[0].is_valid_int() or not parts[1].is_valid_int():
			continue
		var q := int(parts[0])
		var r := int(parts[1])
		coords.append(Vector2i(q, r))
		ys.append(lateral_y(q, r))
	if ys.is_empty():
		return {"ok": false, "total": 0}
	_min_y = float(ys[0])
	_max_y = float(ys[0])
	for y in ys:
		_min_y = minf(_min_y, float(y))
		_max_y = maxf(_max_y, float(y))
	_max_abs_y = maxf(absf(_min_y), absf(_max_y))
	if _max_abs_y <= 0.0:
		_max_abs_y = 1.0
	_sector_by_hex.clear()
	_counts = {"LEFT_WING": 0, "CENTER": 0, "RIGHT_WING": 0}
	for c in coords:
		var s := classify_n(lateral_y((c as Vector2i).x, (c as Vector2i).y) / _max_abs_y)
		_sector_by_hex["%d,%d" % [(c as Vector2i).x, (c as Vector2i).y]] = s
		_counts[s] = int(_counts.get(s, 0)) + 1
	_initialized = true
	return {"ok": true, "total": coords.size(), "counts": _counts.duplicate()}


static func reset_to_canonical() -> void:
	_initialized = false
	_sector_by_hex.clear()
	ensure_initialized()


## Canonical resolver. Returns "" for non-playable coords (honest, never NONE
## for a valid playable hex — every playable hex is classified at build time).
static func get_sector(q: int, r: int) -> String:
	ensure_initialized()
	return str(_sector_by_hex.get("%d,%d" % [q, r], ""))


static func get_sector_of_unit(unit: Dictionary) -> String:
	return get_sector(int(unit.get("q", 0)), int(unit.get("r", 0)))


static func sector_counts() -> Dictionary:
	ensure_initialized()
	return _counts.duplicate()


static func sector_map() -> Dictionary:
	ensure_initialized()
	return _sector_by_hex.duplicate()


static func frame_info() -> Dictionary:
	ensure_initialized()
	return {
		"version": VERSION,
		"origin": [ORIGIN.x, ORIGIN.y],
		"forward": FORWARD_AXIS,
		"forward_detail": "BLUE EAST (+q): deployment west, objective Capital_Luoyang east",
		"lateral": LATERAL_AXIS,
		"lateral_detail": "world Y (north negative = LEFT facing east); y = r*42 + q*21",
		"min_y": _min_y,
		"max_y": _max_y,
		"max_abs_y": _max_abs_y,
		"boundaries": "LEFT n<-1/3; CENTER -1/3<=n<=+1/3; RIGHT n>+1/3",
		"counts": _counts.duplicate(),
		"total": int(_counts.get("LEFT_WING", 0)) + int(_counts.get("CENTER", 0)) + int(_counts.get("RIGHT_WING", 0)),
	}


## Normalize a human word to a canonical sector token (data lookup only).
static func normalize_sector_token(word: String) -> String:
	var w := word.strip_edges().to_lower()
	for sector in ALIASES.keys():
		for alias in (ALIASES[sector] as Array):
			if str(alias).to_lower() == w:
				return str(sector)
	var u := word.strip_edges().to_upper()
	if u in SECTORS:
		return u
	return ""


## Generic position-based filter: units whose CURRENT hex sits in the sector.
## Deterministic order: sorted by unit id. No Dictionary-iteration dependence.
static func filter_units(units: Array, sector: String, unit_class: String) -> Array:
	var s := sector.strip_edges().to_upper()
	var c := unit_class.strip_edges().to_upper()
	var out: Array = []
	for u_val in units:
		if not u_val is Dictionary:
			continue
		var u: Dictionary = u_val
		if str(u.get("class", "")).to_upper() != c:
			continue
		if get_sector(int(u.get("q", 0)), int(u.get("r", 0))) != s:
			continue
		out.append(u)
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a.get("id", "")) < str(b.get("id", "")))
	return out


## Scope entry point for the planner: live side-filtered formations by sector+class.
## Fog-safe: reads only the requesting side's CURRENT positions for membership.
## Geometry itself uses zero unit reads (playable hexes only).
static func resolve_sector_class(sector: String, unit_class: String, side: String, formation_source: RefCounted) -> Array:
	if formation_source == null or not formation_source.has_method("get_all_units_including_garrisoned"):
		return []
	var live: Array = []
	for u_val in formation_source.get_all_units_including_garrisoned():
		if not u_val is Dictionary:
			continue
		var u: Dictionary = u_val
		if str(u.get("faction", "")) != side:
			continue
		if int(u.get("soldier_count", 0)) <= 0:
			continue
		live.append(u)
	return filter_units(live, sector, unit_class)


## Membership of one side+class across all three sectors (DEV inspection).
static func membership_by_sector(side: String, unit_class: String, formation_source: RefCounted) -> Dictionary:
	return {
		"LEFT_WING": resolve_sector_class("LEFT_WING", unit_class, side, formation_source),
		"CENTER": resolve_sector_class("CENTER", unit_class, side, formation_source),
		"RIGHT_WING": resolve_sector_class("RIGHT_WING", unit_class, side, formation_source),
	}


## Pilot sector-target anchor: centroid of the requested sector's playable hexes,
## snapped to the nearest playable hex inside that sector. One deterministic
## point — REPOSITION toward a sector seeks this anchor (documented pilot rule).
static func sector_anchor(sector: String) -> Vector2i:
	ensure_initialized()
	var s := sector.strip_edges().to_upper()
	var sum_q := 0.0
	var sum_r := 0.0
	var n := 0.0
	for key in _sector_by_hex.keys():
		if str(_sector_by_hex[key]) != s:
			continue
		var parts := str(key).split(",")
		sum_q += float(int(parts[0]))
		sum_r += float(int(parts[1]))
		n += 1.0
	if n <= 0.0:
		return ORIGIN
	var cq := int(round(sum_q / n))
	var cr := int(round(sum_r / n))
	if get_sector(cq, cr) == s:
		return Vector2i(cq, cr)
	var best := Vector2i(cq, cr)
	var best_d := 1 << 30
	for key in _sector_by_hex.keys():
		if str(_sector_by_hex[key]) != s:
			continue
		var parts := str(key).split(",")
		var p := Vector2i(int(parts[0]), int(parts[1]))
		var d := absi(p.x - cq) + absi(p.y - cr)
		if d < best_d:
			best_d = d
			best = p
	return best
