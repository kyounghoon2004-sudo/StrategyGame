class_name Step2RUnitBadge
extends Node2D

## Step2RUnitBadge — Adaptive tactical badge scaling with Camera2D zoom & hover
## ZOOM OUT (0.85): Tactical badges scale up to prioritize strategic readability.
## DEFAULT ZOOM (1.15): Badges use reference size (1.20x).
## ZOOM IN (1.85): Tactical badges shrink to prioritize character/unit artwork.
## Hover expands badge relative to current adaptive scale with safe maximum clamping.

signal badge_hover_changed(is_hovered: bool)

@export var unit_class: String = "infantry"
@export var faction: String = "blue"
@export var form_factor: String = "form_a"

# ---- Adaptive Scaling Constants: prominent high-density 32x32 badge scaling ----
const DEFAULT_ZOOM: float = 1.15
const NORMAL_MIN_ZOOM: float = 0.85
const NORMAL_MAX_ZOOM: float = 8.0
const OVERVIEW_MIN_ZOOM: float = 0.30
const OVERVIEW_CAP_THRESHOLD: float = 0.50  # Below 0.50, badge scale is capped

const BASE_SCALE: float = 0.85
const SCALE_EXPONENT: float = 1.10
const MIN_ADAPTIVE_SCALE: float = 0.22
const MAX_ADAPTIVE_SCALE: float = 1.25
# Overview clamp — below 0.85 badges stay bounded/readable, not explode
const OVERVIEW_CLAMP_SCALE: float = 1.15
const OVERVIEW_HOVER_CLAMP: float = 1.45
const OVERVIEW_THRESHOLD: float = 0.65  # below this, LOD compactness kicks in

const HOVER_MULTIPLIER: float = 1.25
const MIN_HOVER_SCALE: float = 0.70
const MAX_HOVER_SCALE: float = 1.50
const TWEEN_DURATION: float = 0.14

var _sprite: Sprite2D
var _hover_tween: Tween
var _is_hovered: bool = false
var _current_zoom: float = DEFAULT_ZOOM

# Director decision: the shield sprite is retired entirely — unit art alone
# carries class readability. The badge node survives as the anchor for the
# rest/fortify flank markers and HP/count info toggles.
const SHIELD_RETIRED := true
const IDLE_ALPHA: float = 0.10
const HOVER_ALPHA: float = 0.35

# Current calculated target scales
var _base_scale: Vector2 = Vector2(BASE_SCALE, BASE_SCALE)
var _hover_scale: Vector2 = Vector2(BASE_SCALE * HOVER_MULTIPLIER, BASE_SCALE * HOVER_MULTIPLIER)

const BADGE_MAP := {
	"infantry": "infantry",
	"spearman": "spearman",
	"spearmen": "spearman",
	"archer": "archer",
	"archers": "archer",
	"cavalry": "cavalry",
	"scout": "scout",
	"scouts": "scout",
	"conscript": "conscript",
	"conscripts": "conscript",
	"siege": "siege",
	"hq": "hq",
	"supply": "supply",
}

func _ready() -> void:
	z_index = 28
	_ensure_sprite()
	update_zoom_scale(_current_zoom, true)
	update_badge()

func setup(p_class: String, p_faction: String, p_form: String = "form_a", initial_zoom: float = DEFAULT_ZOOM) -> void:
	unit_class = p_class.to_lower()
	faction = "red" if (p_faction.to_lower() == "red" or p_faction.to_lower() == "enemy") else "blue"
	form_factor = p_form.to_lower()
	_current_zoom = initial_zoom
	_ensure_sprite()
	update_zoom_scale(_current_zoom, true)
	update_badge()

func _ensure_sprite() -> void:
	if SHIELD_RETIRED:
		return
	if _sprite == null or not is_instance_valid(_sprite):
		_sprite = Sprite2D.new()
		_sprite.name = "BadgeSprite"
		_sprite.centered = true
		_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		_sprite.modulate = Color(1, 1, 1, HOVER_ALPHA if _is_hovered else IDLE_ALPHA)
		_sprite.scale = _hover_scale if _is_hovered else _base_scale
		add_child(_sprite)

func set_camera_zoom(zoom_val: float) -> void:
	update_zoom_scale(zoom_val, false)

func update_zoom_scale(zoom_val: float, instant: bool = false) -> void:
	# PERF-V1: per-frame zoom echo must not re-scale 64+ badge sprites while idle.
	var cz: float = clampf(zoom_val, 0.25, 8.0)
	if not instant and is_equal_approx(_current_zoom, cz):
		return
	_current_zoom = cz
	# Container scale in Step2RUnitRenderer owns semantic zoom sizing via SemanticZoom.badge_mult.
	# Internal sprite remains at canonical scale (1.0) with clean hover boost (1.25x).
	_base_scale = Vector2.ONE
	_hover_scale = Vector2(HOVER_MULTIPLIER, HOVER_MULTIPLIER)
	
	if _sprite and is_instance_valid(_sprite):
		if instant or (_hover_tween == null or not _hover_tween.is_valid()):
			_sprite.scale = _hover_scale if _is_hovered else _base_scale

static var _dense_badge_cache: Dictionary = {}

const SHIELD_BOUNDS := {
	2: [7, 24],
	3: [6, 25],
	4: [5, 26],
	5: [5, 26],
	6: [5, 26],
	7: [5, 26],
	8: [5, 26],
	9: [5, 26],
	10: [5, 26],
	11: [5, 26],
	12: [5, 26],
	13: [5, 26],
	14: [5, 26],
	15: [5, 26],
	16: [5, 26],
	17: [5, 26],
	18: [5, 26],
	19: [6, 25],
	20: [6, 25],
	21: [7, 24],
	22: [7, 24],
	23: [8, 23],
	24: [9, 22],
	25: [10, 21],
	26: [11, 20],
	27: [12, 19],
	28: [13, 18],
	29: [14, 17],
	30: [15, 16],
}

static func get_dense_badge_texture(uclass: String, is_blue: bool) -> Texture2D:
	var norm: String = BADGE_MAP.get(uclass.to_lower(), "infantry")
	var key: String = "%s_%s" % [norm, "b" if is_blue else "r"]
	if _dense_badge_cache.has(key):
		return _dense_badge_cache[key]
	var tex: Texture2D = _generate_dense_badge(norm, is_blue)
	if tex != null:
		_dense_badge_cache[key] = tex
	return tex

static func _generate_dense_badge(norm_class: String, is_blue: bool) -> Texture2D:
	var sz: int = 32
	var img: Image = Image.create(sz, sz, false, Image.FORMAT_RGBA8)
	
	var col_outline := Color(0.04, 0.05, 0.07, 1.0)
	var col_trim := Color(0.82, 0.88, 0.98, 1.0) if is_blue else Color(0.95, 0.78, 0.35, 1.0)
	var col_trim_hi := Color(1.0, 1.0, 1.0, 1.0) if is_blue else Color(1.0, 0.95, 0.75, 1.0)
	var col_bg_top := Color(0.15, 0.30, 0.60, 1.0) if is_blue else Color(0.68, 0.16, 0.16, 1.0)
	var col_bg_bot := Color(0.05, 0.12, 0.28, 1.0) if is_blue else Color(0.30, 0.06, 0.06, 1.0)
	
	# 1. Base shield drawing
	for y in range(sz):
		if not SHIELD_BOUNDS.has(y):
			continue
		var b: Array = SHIELD_BOUNDS[y]
		var x0: int = b[0]
		var x1: int = b[1]
		var is_top_row: bool = (y == 2)
		var is_bot_row: bool = (y == 30)
		
		for x in range(x0, x1 + 1):
			# Outer outline
			if is_top_row or is_bot_row or x == x0 or x == x1:
				img.set_pixel(x, y, col_outline)
			# Metallic trim
			elif y == 3 or y == 29 or x == x0 + 1 or x == x1 - 1:
				if (x == x0 + 1 and y <= 6) or (y == 3 and x <= 10):
					img.set_pixel(x, y, col_trim_hi)
				else:
					img.set_pixel(x, y, col_trim)
			# Faction background
			else:
				var t: float = float(y - 4) / 25.0
				var c: Color = col_bg_top.lerp(col_bg_bot, t)
				# Center crease/sheen
				if x == 15 or x == 16:
					c = c.lightened(0.12)
				img.set_pixel(x, y, c)

	# 2. Draw class emblem
	_draw_emblem(img, norm_class, is_blue)
	return ImageTexture.create_from_image(img)

static func _draw_emblem(img: Image, norm_class: String, _is_blue: bool) -> void:
	var white := Color(1.0, 1.0, 1.0, 1.0)
	var cream := Color(0.96, 0.94, 0.88, 1.0)
	var gold := Color(1.0, 0.86, 0.35, 1.0)
	var amber := Color(0.85, 0.62, 0.18, 1.0)
	var shadow := Color(0.04, 0.06, 0.10, 1.0)
	var steel := Color(0.72, 0.78, 0.88, 1.0)
	var dark_steel := Color(0.40, 0.45, 0.55, 1.0)
	var red_accent := Color(0.90, 0.20, 0.20, 1.0)

	match norm_class:
		"infantry":
			# Detailed crossed dao / broadswords with crossguards and pommels
			for i in range(14):
				var px1: int = 9 + i
				var py1: int = 7 + i
				var px2: int = 22 - i
				var py2: int = 7 + i
				img.set_pixel(px1, py1 + 1, shadow)
				img.set_pixel(px2, py2 + 1, shadow)
				img.set_pixel(px1, py1, white if i < 10 else gold)
				img.set_pixel(px2, py2, cream if i < 10 else gold)
				if i < 9:
					img.set_pixel(px1 - 1, py1, steel)
					img.set_pixel(px2 + 1, py2, steel)
			for dx in range(-2, 3):
				img.set_pixel(19 + dx, 18 - dx, gold)
				img.set_pixel(12 + dx, 18 + dx, gold)
			img.set_pixel(22, 21, amber)
			img.set_pixel(9, 21, amber)
			img.set_pixel(15, 13, gold)
			img.set_pixel(16, 13, gold)
			img.set_pixel(15, 14, gold)
			img.set_pixel(16, 14, amber)

		"spearman":
			# Twin upward barbed pikes / halberds crossing
			for sp in [[11, 6], [20, 6]]:
				var tx: int = sp[0]
				var ty: int = sp[1]
				img.set_pixel(tx, ty, white)
				for row in range(1, 6):
					var w: int = 1 if row < 3 else (2 if row < 5 else 3)
					for dx in range(-w, w + 1):
						img.set_pixel(tx + dx, ty + row, white if dx == 0 else steel)
				img.set_pixel(tx, ty + 6, gold)
				img.set_pixel(tx - 1, ty + 6, amber)
				img.set_pixel(tx + 1, ty + 6, amber)
				img.set_pixel(tx, ty + 7, red_accent)
				img.set_pixel(tx - 1, ty + 7, red_accent)
				img.set_pixel(tx + 1, ty + 7, red_accent)
			for i in range(12):
				var sx1: int = 11 + i
				var sy1: int = 14 + i
				var sx2: int = 20 - i
				var sy2: int = 14 + i
				if sy1 <= 24:
					img.set_pixel(sx1, sy1, gold)
					img.set_pixel(sx2, sy2, amber)

		"archer":
			# Heavy recurve bow drawn with knocked arrow pointing right
			var bow_pts := [
				[12,7],[11,8],[10,9],[9,11],[8,13],[8,15],[8,17],[9,19],[10,21],[11,22],[12,23]
			]
			for pt in bow_pts:
				var bx: int = pt[0]
				var by: int = pt[1]
				img.set_pixel(bx, by, gold)
				img.set_pixel(bx + 1, by, amber)
			for y in range(7, 16):
				var t: float = float(y - 7) / 8.0
				var sx: int = int(round(12.0 + 4.0 * t))
				img.set_pixel(sx, y, white)
			for y in range(16, 24):
				var t: float = float(y - 15) / 8.0
				var sx: int = int(round(16.0 - 4.0 * t))
				img.set_pixel(sx, y, white)
			for x in range(13, 24):
				img.set_pixel(x, 15, white)
				img.set_pixel(x, 16, shadow)
			img.set_pixel(25, 15, steel)
			img.set_pixel(24, 14, white)
			img.set_pixel(24, 15, white)
			img.set_pixel(24, 16, white)
			img.set_pixel(23, 13, steel)
			img.set_pixel(23, 14, white)
			img.set_pixel(23, 16, white)
			img.set_pixel(23, 17, steel)
			img.set_pixel(13, 13, red_accent)
			img.set_pixel(14, 14, red_accent)
			img.set_pixel(13, 17, red_accent)
			img.set_pixel(14, 16, red_accent)

		"cavalry":
			# Warhorse head & neck silhouette facing right
			img.set_pixel(14, 7, cream)
			img.set_pixel(15, 8, white)
			img.set_pixel(17, 8, cream)
			img.set_pixel(18, 9, white)
			for x in range(15, 23):
				img.set_pixel(x, 11, white)
			for x in range(17, 24):
				img.set_pixel(x, 12, white)
			for x in range(19, 24):
				img.set_pixel(x, 13, cream)
			img.set_pixel(23, 14, shadow)
			img.set_pixel(22, 14, cream)
			img.set_pixel(21, 15, cream)
			img.set_pixel(20, 15, cream)
			for x in range(16, 20):
				img.set_pixel(x, 16, white)
				img.set_pixel(x, 17, cream)
			img.set_pixel(18, 12, shadow)
			img.set_pixel(17, 13, gold)
			img.set_pixel(18, 14, gold)
			img.set_pixel(19, 15, gold)
			img.set_pixel(20, 14, gold)
			for y in range(13, 24):
				var nx0: int = 10 + (y - 13) / 3
				var nx1: int = 16 + (y - 13) / 4
				for x in range(nx0, nx1 + 1):
					img.set_pixel(x, y, cream)
			for y in range(9, 20):
				var mx: int = 10 + (y - 9) / 3
				img.set_pixel(mx - 1, y, gold)
				img.set_pixel(mx, y, amber)

		"scout":
			# Fierce scouting eagle/falcon silhouette with wings aloft & sharp eye
			img.set_pixel(15, 8, white)
			img.set_pixel(16, 8, white)
			img.set_pixel(17, 8, gold)
			img.set_pixel(18, 9, gold)
			img.set_pixel(16, 9, white)
			img.set_pixel(15, 9, shadow)
			img.set_pixel(8, 9, white)
			img.set_pixel(9, 9, white)
			img.set_pixel(10, 10, cream)
			img.set_pixel(11, 11, cream)
			img.set_pixel(12, 12, cream)
			img.set_pixel(9, 11, steel)
			img.set_pixel(10, 12, steel)
			img.set_pixel(11, 13, steel)
			img.set_pixel(23, 9, white)
			img.set_pixel(22, 9, white)
			img.set_pixel(21, 10, cream)
			img.set_pixel(20, 11, cream)
			img.set_pixel(19, 12, cream)
			img.set_pixel(22, 11, steel)
			img.set_pixel(21, 12, steel)
			img.set_pixel(20, 13, steel)
			for y in range(10, 18):
				for x in range(14, 18):
					img.set_pixel(x, y, cream if x <= 15 else white)
			for y in range(18, 24):
				var tw: int = (y - 18) / 2
				for x in range(15 - tw, 16 + tw + 1):
					img.set_pixel(x, y, gold if (x == 15 - tw or x == 16 + tw) else white)

		"conscript":
			# Militia spear with large fluttering pennant flag
			for y in range(6, 25):
				img.set_pixel(11, y, gold)
				img.set_pixel(12, y, amber)
			img.set_pixel(11, 5, white)
			img.set_pixel(10, 6, steel)
			img.set_pixel(12, 6, steel)
			img.set_pixel(11, 6, white)
			for y in range(8, 19):
				var dist: int = 10 - absi(y - 13)
				var end_x: int = 13 + dist
				for x in range(13, end_x + 1):
					if y == 13 or y == 14:
						img.set_pixel(x, y, gold)
					else:
						img.set_pixel(x, y, red_accent)
				img.set_pixel(end_x, y, shadow)

		"siege":
			# Heavy siege catapult with stone basket & fortified timbers
			for x in range(9, 23):
				img.set_pixel(x, 21, amber)
				img.set_pixel(x, 22, gold)
			for wx in [10, 20]:
				for dy in range(-1, 2):
					for dx in range(-1, 2):
						img.set_pixel(wx + dx, 23 + dy, dark_steel)
				img.set_pixel(wx, 23, steel)
			for i in range(6):
				img.set_pixel(12 + i, 20 - i, gold)
				img.set_pixel(18 - i, 20 - i, amber)
			img.set_pixel(15, 15, steel)
			img.set_pixel(16, 15, steel)
			for i in range(12):
				var ax: int = 11 + i
				var ay: int = 19 - i
				img.set_pixel(ax, ay, white)
				img.set_pixel(ax, ay + 1, amber)
			for dy in range(3):
				for dx in range(3):
					img.set_pixel(9 + dx, 18 + dy, dark_steel)
			img.set_pixel(22, 7, gold)
			img.set_pixel(23, 7, gold)
			img.set_pixel(23, 8, white)
			img.set_pixel(22, 8, steel)

		"hq":
			# Imperial Command General Helmet & Crown
			img.set_pixel(11, 7, gold)
			img.set_pixel(15, 5, gold)
			img.set_pixel(16, 5, gold)
			img.set_pixel(20, 7, gold)
			for x in range(10, 22):
				img.set_pixel(x, 8, gold)
				img.set_pixel(x, 9, amber)
			img.set_pixel(15, 8, red_accent)
			img.set_pixel(16, 8, red_accent)
			for y in range(10, 16):
				var hw: int = 5
				for x in range(15 - hw, 16 + hw + 1):
					img.set_pixel(x, y, white if x == 15 else steel)
			for x in range(12, 20):
				img.set_pixel(x, 16, shadow)
			img.set_pixel(13, 16, gold)
			img.set_pixel(18, 16, gold)
			for y in range(17, 21):
				var nw: int = 4 - (y - 17)
				for x in range(15 - nw, 16 + nw + 1):
					img.set_pixel(x, y, gold)
			for y in range(11, 24):
				img.set_pixel(9, y, red_accent)
				img.set_pixel(22, y, red_accent)

		"supply":
			# Sturdy logistics transport cart wheel & twin grain bundles
			for dy in range(-6, 7):
				for dx in range(-6, 7):
					var d2: int = dx * dx + dy * dy
					if d2 >= 25 and d2 <= 40:
						img.set_pixel(15 + dx, 17 + dy, gold)
					elif d2 <= 4:
						img.set_pixel(15 + dx, 17 + dy, steel)
			for i in range(-5, 6):
				img.set_pixel(15 + i, 17, amber)
				img.set_pixel(15, 17 + i, amber)
			for i in range(-4, 5):
				img.set_pixel(15 + i, 17 + i, amber)
				img.set_pixel(15 + i, 17 - i, amber)
			for y in range(7, 13):
				for x in range(10, 15):
					img.set_pixel(x, y, cream if x == 12 else gold)
			for y in range(7, 13):
				for x in range(16, 21):
					img.set_pixel(x, y, cream if x == 18 else gold)
			for x in range(9, 16):
				img.set_pixel(x, 10, amber)
			for x in range(15, 22):
				img.set_pixel(x, 10, amber)

func update_badge() -> void:
	if SHIELD_RETIRED:
		return
	_ensure_sprite()
	var norm_class: String = BADGE_MAP.get(unit_class, "infantry")
	var is_blue: bool = (faction == "blue")
	var tex: Texture2D = get_dense_badge_texture(norm_class, is_blue)
	if tex == null:
		var path: String = "res://assets/badges/%s/badge_%s_%s_%s.png" % [faction, norm_class, faction, form_factor]
		var fallback_path: String = "res://assets/badges/%s/badge_%s_%s.png" % [faction, norm_class, faction]
		tex = _load_tex(path)
		if tex == null:
			tex = _load_tex(fallback_path)
	if tex != null:
		_sprite.texture = tex
	else:
		push_warning("[Step2RUnitBadge] Badge texture missing: %s %s" % [norm_class, faction])

func _load_tex(path: String) -> Texture2D:
	if ResourceLoader.exists(path):
		return load(path) as Texture2D
	elif FileAccess.file_exists(path):
		var img: Image = Image.load_from_file(path)
		if img != null:
			return ImageTexture.create_from_image(img)
	return null

func set_hovered(hovered: bool) -> void:
	if _is_hovered == hovered:
		return
	_is_hovered = hovered
	if SHIELD_RETIRED:
		return
	if _hover_tween and _hover_tween.is_valid():
		_hover_tween.kill()
	_hover_tween = create_tween().set_parallel(true)
	if _is_hovered:
		z_index = 65
		_hover_tween.tween_property(_sprite, "scale", _hover_scale, TWEEN_DURATION).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		_hover_tween.tween_property(_sprite, "modulate", Color(1.18, 1.18, 1.15, HOVER_ALPHA), TWEEN_DURATION)
	else:
		z_index = 28
		_hover_tween.tween_property(_sprite, "scale", _base_scale, TWEEN_DURATION * 0.9).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		_hover_tween.tween_property(_sprite, "modulate", Color(1.0, 1.0, 1.0, IDLE_ALPHA), TWEEN_DURATION * 0.9)
	badge_hover_changed.emit(_is_hovered)

func is_hovered() -> bool:
	return _is_hovered

func get_adaptive_scale() -> float:
	return _base_scale.x

func get_hover_scale() -> float:
	return _hover_scale.x

func get_current_zoom() -> float:
	return _current_zoom

func get_badge_info() -> Dictionary:
	return {
		"class": BADGE_MAP.get(unit_class, "infantry"),
		"faction": faction,
		"form_factor": form_factor,
		"is_hovered": _is_hovered,
		"adaptive_scale": _base_scale.x,
		"hover_scale": _hover_scale.x,
		"current_zoom": _current_zoom
	}
