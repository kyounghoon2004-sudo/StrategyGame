class_name Step2RFormationMarker
extends Node2D

## Step2RFormationMarker — Five Dynasties Military Formation & War Banner System
## Renders stylized tactical army formations:
## - Authentic saw-tooth silk military war banner with Chinese character seal (帥, 步, 槍, 弓, 騎, 勇, 斥, 器, 糧)
## - Small formation of soldiers (3 to 5 figures in tactical rank and file)
## - Class-specific weapons, armor, shields, warhorses, siege engines, and baggage carts
## - Zoom-adaptive LOD: soldier figures dominate at tactical zoom; banners dominate at overview
## - Clear faction differentiation: Deep Blue & Gold (Allies) vs Dark Crimson & Bronze/Black (Enemies)
## - States: Selected (radiant gold aura), Hovered (crisp highlight), Normal (harmonious),
##   Routed (broken banner & disarray), Fortified (wooden palisade stakes), HQ (imperial command canopy)

const FACTION_BLUE_BANNER := Color(0.16, 0.32, 0.62, 1.0)
const FACTION_BLUE_TRIM := Color(0.92, 0.80, 0.32, 1.0)
const FACTION_BLUE_TUNIC := Color(0.20, 0.38, 0.70, 1.0)

const FACTION_RED_BANNER := Color(0.72, 0.16, 0.16, 1.0)
const FACTION_RED_TRIM := Color(0.92, 0.72, 0.28, 1.0)
const FACTION_RED_TUNIC := Color(0.68, 0.18, 0.18, 1.0)

const COLOR_ARMOR_IRON := Color(0.28, 0.30, 0.34, 1.0)
const COLOR_ARMOR_BRONZE := Color(0.55, 0.44, 0.26, 1.0)
const COLOR_WOOD_TIMBER := Color(0.42, 0.30, 0.20, 1.0)
const COLOR_STEEL_WEAPON := Color(0.85, 0.88, 0.92, 1.0)
const COLOR_HORSE_BAY := Color(0.38, 0.24, 0.16, 1.0)
const COLOR_HORSE_WHITE := Color(0.88, 0.86, 0.82, 1.0)
const COLOR_PALISADE_WOOD := Color(0.48, 0.36, 0.22, 1.0)

var unit_class: String = "infantry"
var faction: String = "blue"
var soldier_count: int = 100
var max_count: int = 100

var is_selected: bool = false
var is_hovered: bool = false
var is_routed: bool = false
var is_fortified: bool = false
var is_hq: bool = false
var is_convoy: bool = false
var is_dimmed: bool = false

var current_zoom: float = 1.15
var _pulse_time: float = 0.0

static var _formation_texture_cache: Dictionary = {}
static var _banner_texture_cache: Dictionary = {}
var _tex_formation: Texture2D = null
var _tex_banner: Texture2D = null

func _ready() -> void:
	z_index = 2
	_update_textures()
	set_process(true)

func _process(delta: float) -> void:
	_pulse_time += delta * 3.5
	if _pulse_time > TAU:
		_pulse_time -= TAU
	if is_selected or is_hovered:
		queue_redraw()

func setup(p_class: String, p_faction: String, p_count: int, p_zoom: float = 1.15) -> void:
	unit_class = p_class.to_lower()
	faction = "red" if (p_faction.to_lower() == "red" or p_faction.to_lower() == "enemy") else "blue"
	soldier_count = p_count
	max_count = maxi(p_count, 1)
	current_zoom = p_zoom
	is_hq = (unit_class == "hq")
	is_convoy = (unit_class == "supply")
	_update_textures()
	queue_redraw()

func _update_textures() -> void:
	var is_blue := (faction == "blue")
	var side_dir: String = "ally" if is_blue else "enemy"
	var side_tag: String = "ally" if is_blue else "enemy"
	var norm_class: String = unit_class
	if norm_class == "spearmen": norm_class = "spearman"
	elif norm_class == "archers": norm_class = "archer"
	elif norm_class == "scouts": norm_class = "scout"
	elif norm_class == "conscripts": norm_class = "conscript"

	var form_path: String = "res://assets/visual_overhaul_r3/formations/%s/formation_%s.png" % [side_dir, norm_class]
	var banner_path: String = "res://assets/visual_overhaul_r3/formations/banners/banner_%s_%s.png" % [side_tag, norm_class]

	_tex_formation = _get_or_load_texture(form_path, _formation_texture_cache)
	_tex_banner = _get_or_load_texture(banner_path, _banner_texture_cache)

static func _get_or_load_texture(path: String, cache: Dictionary) -> Texture2D:
	if cache.has(path):
		return cache[path]
	var tex: Texture2D = null
	if ResourceLoader.exists(path):
		tex = load(path) as Texture2D
	else:
		var os_path: String = path.replace("res://", "D:/Game development/Demon slayer/StrategyGame/")
		if FileAccess.file_exists(os_path):
			var img: Image = Image.load_from_file(os_path)
			if img != null:
				tex = ImageTexture.create_from_image(img)
	if tex != null:
		cache[path] = tex
	return tex

func set_camera_zoom(zoom_val: float) -> void:
	# PERF-V1: early-out keeps idle frames free of full-formation _draw rebuilds.
	var cz: float = clampf(zoom_val, 0.25, 8.0)
	if is_equal_approx(current_zoom, cz):
		return
	current_zoom = cz
	queue_redraw()

func update_status(
	p_selected: bool,
	p_hovered: bool,
	p_routed: bool,
	p_fortified: bool,
	p_dimmed: bool = false
) -> void:
	is_selected = p_selected
	is_hovered = p_hovered
	is_routed = p_routed
	is_fortified = p_fortified
	is_dimmed = p_dimmed
	queue_redraw()

func _class_bulk() -> float:
	# Cavalry / siege / HQ / supply read slightly larger; ordinary
	# formations target ~55-65% of hex flat-to-flat width (terrain first).
	match unit_class:
		"cavalry", "siege", "hq", "supply", "scout":
			return 1.2
		_:
			return 1.0

func _draw() -> void:
	var is_blue := (faction == "blue")
	var banner_col := FACTION_BLUE_BANNER if is_blue else FACTION_RED_BANNER
	var trim_col := FACTION_BLUE_TRIM if is_blue else FACTION_RED_TRIM
	var tunic_col := FACTION_BLUE_TUNIC if is_blue else FACTION_RED_TUNIC

	# Master alpha based on status
	var alpha_mult: float = 1.0
	if is_routed:
		alpha_mult = 0.45
	elif is_dimmed:
		alpha_mult = 0.60

	# 1. Formation Ground Decal (Subtle rank plinth)
	_draw_ground_plinth(is_blue, trim_col, alpha_mult)

	# 2. Fortified Palisade Stakes (if fortified)
	if is_fortified and not is_routed:
		_draw_palisade_stakes()

	# 3. Small Group of Soldiers (tactical figures)
	# Zoom LOD: Fade soldiers when zooming far out, simplify to banner
	var soldier_alpha: float = clampf((current_zoom - 0.55) / 0.35, 0.0, 1.0) * alpha_mult
	if _tex_formation != null:
		if soldier_alpha > 0.02 and not is_routed:
			var bulk: float = _class_bulk()
			var sc := Vector2(0.15 * bulk, 0.15 * bulk)
			var off := Vector2(-float(_tex_formation.get_width()) * 0.5 * sc.x, -float(_tex_formation.get_height()) * 0.65 * sc.y)
			draw_texture_rect(_tex_formation, Rect2(off, Vector2(_tex_formation.get_width() * sc.x, _tex_formation.get_height() * sc.y)), false, Color(1, 1, 1, soldier_alpha))
		elif is_routed:
			_draw_routed_soldiers(tunic_col, 0.45)
	else:
		if soldier_alpha > 0.02 and not is_routed:
			_draw_soldier_formation(tunic_col, soldier_alpha)
		elif is_routed:
			# Disordered fleeing figures
			_draw_routed_soldiers(tunic_col, 0.45)

	# 4. War Banner (The primary command identifier)
	if _tex_banner != null:
		var b_sc := Vector2(0.17 * _class_bulk(), 0.17 * _class_bulk())
		var b_pos := Vector2(-11.0, -16.0)
		if is_routed:
			b_pos = Vector2(-7.0, -9.0)
		draw_texture_rect(_tex_banner, Rect2(b_pos, Vector2(_tex_banner.get_width() * b_sc.x, _tex_banner.get_height() * b_sc.y)), false, Color(1, 1, 1, alpha_mult))
	else:
		_draw_war_banner(banner_col, trim_col, alpha_mult)

	# 5. Selection / Hover Radiance Aura
	if is_selected:
		var pulse: float = 0.5 + 0.5 * sin(_pulse_time)
		var aura_col := Color(1.0, 0.88, 0.30, 0.40 + 0.35 * pulse)
		draw_arc(Vector2(0, 4), 13.0 + 1.5 * pulse, 0.0, TAU, 24, aura_col, 2.5, true)
		draw_arc(Vector2(0, 4), 15.5, 0.0, TAU, 20, Color(1.0, 0.95, 0.60, 0.25 * pulse), 1.2, true)
	elif is_hovered:
		draw_arc(Vector2(0, 4), 14.0, 0.0, TAU, 24, Color(1.0, 1.0, 0.85, 0.70), 1.8, true)

func _draw_ground_plinth(is_blue: bool, trim_col: Color, alpha_mult: float) -> void:
	# Stylized formation footprint (rounded tactical plinth)
	var plinth_rect := Rect2(-12, -1, 24, 11)
	var base_col := Color(0.08, 0.10, 0.14, 0.40 * alpha_mult)
	draw_rect(plinth_rect, base_col)
	# Faction border trim
	var border_col := trim_col * Color(1, 1, 1, 0.65 * alpha_mult)
	draw_rect(plinth_rect, border_col, false, 1.2)
	# Tactical corner markers
	var c_len := 4.0
	draw_line(Vector2(-12, -1), Vector2(-12 + c_len, -1), trim_col * alpha_mult, 1.6)
	draw_line(Vector2(-12, -1), Vector2(-12, -1 + c_len), trim_col * alpha_mult, 1.6)
	draw_line(Vector2(12, -1), Vector2(12 - c_len, -1), trim_col * alpha_mult, 1.6)
	draw_line(Vector2(12, -1), Vector2(12, -1 + c_len), trim_col * alpha_mult, 1.6)

func _draw_palisade_stakes() -> void:
	# Wooden sharpened stake fence in front of formation
	var stake_x := [-12, -8, -4, 0, 4, 8, 12]
	for sx in stake_x:
		var p_top := Vector2(sx, 5)
		var p_bot := Vector2(sx + (1 if sx > 0 else -1), 10)
		draw_line(p_top, p_bot, COLOR_PALISADE_WOOD, 2.2)
		# Sharpened point
		draw_circle(p_top, 1.2, Color(0.85, 0.75, 0.55))

func _draw_war_banner(banner_col: Color, trim_col: Color, alpha_mult: float) -> void:
	# War Banner located on rear flank (x = -13, y = -14)
	var bx: float = -13.0
	var by: float = -4.0
	var staff_top: float = -28.0
	var banner_w: float = 12.0
	var banner_h: float = 20.0

	if is_routed:
		# Tilted broken banner
		bx = -8.0
		by = 2.0
		staff_top = -14.0
		banner_h = 14.0

	# 1. Timber Staff
	var pole_top := Vector2(bx, by + staff_top)
	var pole_bot := Vector2(bx, by + 8.0)
	draw_line(pole_top, pole_bot, COLOR_WOOD_TIMBER, 2.0)

	# Gilded spearhead finial on top
	var finial := PackedVector2Array([
		pole_top + Vector2(0, -5),
		pole_top + Vector2(-2.5, 0),
		pole_top + Vector2(2.5, 0)
	])
	draw_colored_polygon(finial, trim_col * alpha_mult)

	# 2. Silk War Banner Body
	var b_origin := pole_top + Vector2(1.5, 3.0)
	var banner_poly := PackedVector2Array([
		b_origin,
		b_origin + Vector2(banner_w, 2.0),
		b_origin + Vector2(banner_w, banner_h + 2.0),
		b_origin + Vector2(0, banner_h)
	])
	draw_colored_polygon(banner_poly, banner_col * Color(1, 1, 1, alpha_mult))

	# Gold/Black Silk Border
	draw_polyline(banner_poly, trim_col * Color(1, 1, 1, alpha_mult), 1.2, true)

	# 3. Saw-tooth Flame Fringes (火焰边 - 4 triangles on outer trailing edge)
	var fringe_count := 4
	var step_y := banner_h / float(fringe_count)
	for f in range(fringe_count):
		var fy := b_origin.y + 2.0 + float(f) * step_y
		var tooth := PackedVector2Array([
			Vector2(b_origin.x + banner_w, fy),
			Vector2(b_origin.x + banner_w + 3.5, fy + step_y * 0.5),
			Vector2(b_origin.x + banner_w, fy + step_y)
		])
		draw_colored_polygon(tooth, trim_col * Color(1, 1, 1, alpha_mult))

	# 4. Chinese Character Seal on Banner (Inscribed with traditional brush strokes)
	var seal_center := b_origin + Vector2(banner_w * 0.5, banner_h * 0.5)
	_draw_banner_chinese_character(seal_center, trim_col, alpha_mult)

func _draw_banner_chinese_character(c: Vector2, col: Color, alpha: float) -> void:
	var stroke_col := col * Color(1, 1, 1, alpha)
	var s: float = 1.0

	# Distinct authentic Chinese glyph representations:
	match unit_class:
		"hq":
			# 帥 (Commander)
			draw_line(c + Vector2(-3, -5), c + Vector2(-3, 5), stroke_col, 1.4)
			draw_line(c + Vector2(-3, -2), c + Vector2(0, -2), stroke_col, 1.2)
			draw_line(c + Vector2(0, -5), c + Vector2(3, -5), stroke_col, 1.2)
			draw_line(c + Vector2(2, -5), c + Vector2(2, 5), stroke_col, 1.4)
			draw_line(c + Vector2(-1, 0), c + Vector2(4, 0), stroke_col, 1.2)
		"infantry":
			# 步 (Infantry)
			draw_line(c + Vector2(-3, -4), c + Vector2(3, -4), stroke_col, 1.2)
			draw_line(c + Vector2(0, -5), c + Vector2(0, 1), stroke_col, 1.4)
			draw_line(c + Vector2(-2, 1), c + Vector2(2, 1), stroke_col, 1.2)
			draw_line(c + Vector2(-2, 1), c + Vector2(-3, 5), stroke_col, 1.2)
			draw_line(c + Vector2(1, 1), c + Vector2(3, 5), stroke_col, 1.2)
		"spearman":
			# 槍 (Spear)
			draw_line(c + Vector2(-3, -5), c + Vector2(-3, 5), stroke_col, 1.4)
			draw_line(c + Vector2(-4, -2), c + Vector2(-1, -2), stroke_col, 1.2)
			draw_line(c + Vector2(0, -4), c + Vector2(4, -4), stroke_col, 1.2)
			draw_line(c + Vector2(2, -4), c + Vector2(2, 5), stroke_col, 1.4)
			draw_line(c + Vector2(0, 2), c + Vector2(4, 2), stroke_col, 1.2)
		"archer":
			# 弓 (Bow)
			draw_line(c + Vector2(-3, -5), c + Vector2(2, -5), stroke_col, 1.4)
			draw_line(c + Vector2(2, -5), c + Vector2(2, -1), stroke_col, 1.2)
			draw_line(c + Vector2(-3, -1), c + Vector2(2, -1), stroke_col, 1.2)
			draw_line(c + Vector2(-3, -1), c + Vector2(-3, 5), stroke_col, 1.4)
			draw_line(c + Vector2(-3, 5), c + Vector2(2, 5), stroke_col, 1.4)
		"cavalry":
			# 騎 (Cavalry)
			draw_line(c + Vector2(-3, -5), c + Vector2(-3, 5), stroke_col, 1.4)
			draw_line(c + Vector2(-3, -4), c + Vector2(-1, -4), stroke_col, 1.2)
			draw_line(c + Vector2(-3, 0), c + Vector2(-1, 0), stroke_col, 1.2)
			draw_line(c + Vector2(1, -4), c + Vector2(4, -4), stroke_col, 1.2)
			draw_line(c + Vector2(2, -4), c + Vector2(2, 5), stroke_col, 1.4)
			draw_line(c + Vector2(0, 4), c + Vector2(4, 4), stroke_col, 1.2)
		"scout":
			# 斥 (Scout)
			draw_line(c + Vector2(-3, -4), c + Vector2(3, -4), stroke_col, 1.4)
			draw_line(c + Vector2(0, -4), c + Vector2(-3, 4), stroke_col, 1.4)
			draw_line(c + Vector2(-1, 0), c + Vector2(3, 5), stroke_col, 1.4)
			draw_circle(c + Vector2(2, -2), 1.0, stroke_col)
		"conscript":
			# 勇 (Brave / Militia)
			draw_line(c + Vector2(-3, -4), c + Vector2(3, -4), stroke_col, 1.2)
			draw_line(c + Vector2(-3, -1), c + Vector2(3, -1), stroke_col, 1.2)
			draw_line(c + Vector2(-2, -1), c + Vector2(-2, 4), stroke_col, 1.2)
			draw_line(c + Vector2(2, -1), c + Vector2(2, 4), stroke_col, 1.2)
			draw_line(c + Vector2(-2, 4), c + Vector2(2, 4), stroke_col, 1.2)
		"siege":
			# 器 (Engine)
			draw_rect(Rect2(c.x - 3, c.y - 4, 3, 3), stroke_col, false, 1.0)
			draw_rect(Rect2(c.x + 1, c.y - 4, 3, 3), stroke_col, false, 1.0)
			draw_line(c + Vector2(-2, 1), c + Vector2(2, 1), stroke_col, 1.2)
			draw_rect(Rect2(c.x - 3, c.y + 2, 3, 3), stroke_col, false, 1.0)
			draw_rect(Rect2(c.x + 1, c.y + 2, 3, 3), stroke_col, false, 1.0)
		"supply":
			# 糧 (Grain / Supply)
			draw_line(c + Vector2(-3, -5), c + Vector2(3, -5), stroke_col, 1.2)
			draw_line(c + Vector2(-3, -1), c + Vector2(3, -1), stroke_col, 1.2)
			draw_line(c + Vector2(0, -5), c + Vector2(0, 5), stroke_col, 1.4)
			draw_line(c + Vector2(-3, 2), c + Vector2(-1, 5), stroke_col, 1.2)
			draw_line(c + Vector2(3, 2), c + Vector2(1, 5), stroke_col, 1.2)
		_:
			draw_circle(c, 2.5, stroke_col)

func _draw_soldier_formation(tunic_col: Color, alpha: float) -> void:
	match unit_class:
		"cavalry":
			# 3 Mounted Cavalrymen with Warhorses & Barded Armor
			_draw_cavalryman(Vector2(-3, 0), tunic_col, alpha, COLOR_HORSE_BAY)
			_draw_cavalryman(Vector2(6, -3), tunic_col, alpha, COLOR_HORSE_WHITE)
			_draw_cavalryman(Vector2(8, 5), tunic_col, alpha, COLOR_HORSE_BAY)
		"scout":
			# 2 Swift Light Riders
			_draw_cavalryman(Vector2(0, -2), tunic_col, alpha, COLOR_HORSE_WHITE, true)
			_draw_cavalryman(Vector2(7, 3), tunic_col, alpha, COLOR_HORSE_BAY, true)
		"spearman":
			# 4 Armored Spearmen with Upright Pikes in 2 Ranks
			_draw_spearman(Vector2(-2, -3), tunic_col, alpha)
			_draw_spearman(Vector2(7, -3), tunic_col, alpha)
			_draw_spearman(Vector2(0, 5), tunic_col, alpha)
			_draw_spearman(Vector2(9, 5), tunic_col, alpha)
		"archer":
			# 3 Archers in line holding composite bows
			_draw_archer(Vector2(-2, -2), tunic_col, alpha)
			_draw_archer(Vector2(5, 0), tunic_col, alpha)
			_draw_archer(Vector2(11, 4), tunic_col, alpha)
		"siege":
			# Heavy Trebuchet / Engine + 2 crewmen
			_draw_siege_engine(Vector2(4, 2), alpha)
			_draw_infantryman(Vector2(-4, 4), tunic_col, alpha)
			_draw_infantryman(Vector2(12, 4), tunic_col, alpha)
		"hq":
			# Commanding General on Charger under Gold Umbrella Canopy + 2 bodyguards
			_draw_command_canopy(Vector2(4, -6), alpha)
			_draw_cavalryman(Vector2(4, 2), tunic_col, alpha, COLOR_HORSE_WHITE)
			_draw_spearman(Vector2(-4, 3), tunic_col, alpha)
			_draw_spearman(Vector2(12, 3), tunic_col, alpha)
		"supply":
			# Wooden baggage cart with oxen & teamster
			_draw_supply_wagon(Vector2(4, 3), alpha)
			_draw_infantryman(Vector2(-4, 5), tunic_col, alpha)
		"conscript":
			# 4 Levies with simple tunics and spears
			_draw_conscript(Vector2(-2, -2), tunic_col, alpha)
			_draw_conscript(Vector2(6, -2), tunic_col, alpha)
			_draw_conscript(Vector2(0, 5), tunic_col, alpha)
			_draw_conscript(Vector2(8, 5), tunic_col, alpha)
		_: # infantry default
			# 4 Swordsmen with round rattan shields
			_draw_infantryman(Vector2(-2, -3), tunic_col, alpha)
			_draw_infantryman(Vector2(7, -3), tunic_col, alpha)
			_draw_infantryman(Vector2(0, 5), tunic_col, alpha)
			_draw_infantryman(Vector2(9, 5), tunic_col, alpha)

func _draw_infantryman(pos: Vector2, tunic_col: Color, alpha: float) -> void:
	var t_col := tunic_col * Color(1, 1, 1, alpha)
	# Body / Tunic
	draw_rect(Rect2(pos.x - 2.5, pos.y - 5, 5, 7), t_col)
	# Iron Helmet
	draw_circle(pos + Vector2(0, -7), 2.5, COLOR_ARMOR_IRON * Color(1, 1, 1, alpha))
	# Red Tassel on Helmet
	draw_circle(pos + Vector2(0, -9.5), 1.0, Color(0.9, 0.2, 0.2, alpha))
	# Round Shield (Teng Pai) on left arm
	draw_circle(pos + Vector2(-3, -2), 3.0, Color(0.65, 0.45, 0.25, alpha))
	draw_circle(pos + Vector2(-3, -2), 1.8, Color(0.85, 0.75, 0.40, alpha))
	# Dao Sword in right hand
	draw_line(pos + Vector2(3, -1), pos + Vector2(5, -6), COLOR_STEEL_WEAPON * Color(1, 1, 1, alpha), 1.4)

func _draw_spearman(pos: Vector2, tunic_col: Color, alpha: float) -> void:
	var t_col := tunic_col * Color(1, 1, 1, alpha)
	# Body / Armor
	draw_rect(Rect2(pos.x - 2.5, pos.y - 5, 5, 7), t_col)
	# Helmet
	draw_circle(pos + Vector2(0, -7), 2.5, COLOR_ARMOR_IRON * Color(1, 1, 1, alpha))
	# Long Pike (Qiang) held upright (14px tall)
	var p_top := pos + Vector2(3, -16)
	var p_bot := pos + Vector2(3, 4)
	draw_line(p_top, p_bot, COLOR_WOOD_TIMBER * Color(1, 1, 1, alpha), 1.4)
	# Spearhead glint
	draw_line(p_top, p_top + Vector2(0, -4), COLOR_STEEL_WEAPON * Color(1, 1, 1, alpha), 1.8)
	# Red tassel under spearhead
	draw_circle(p_top, 1.2, Color(0.9, 0.2, 0.2, alpha))

func _draw_archer(pos: Vector2, tunic_col: Color, alpha: float) -> void:
	var t_col := tunic_col * Color(1, 1, 1, alpha)
	# Body / Tunic
	draw_rect(Rect2(pos.x - 2, pos.y - 5, 4, 7), t_col)
	# Head
	draw_circle(pos + Vector2(0, -7), 2.2, Color(0.85, 0.72, 0.58, alpha))
	# Quiver on back
	draw_line(pos + Vector2(-2, -5), pos + Vector2(-4, -10), Color(0.45, 0.32, 0.20, alpha), 1.8)
	# Recurve Bow held ready
	draw_arc(pos + Vector2(3, -4), 4.5, -PI * 0.45, PI * 0.45, 6, Color(0.55, 0.38, 0.20, alpha), 1.5)
	# Bowstring
	draw_line(pos + Vector2(3, -8), pos + Vector2(3, 0), Color(0.9, 0.9, 0.9, 0.7 * alpha), 1.0)

func _draw_cavalryman(pos: Vector2, tunic_col: Color, alpha: float, horse_col: Color, light_scout: bool = false) -> void:
	var h_col := horse_col * Color(1, 1, 1, alpha)
	# Horse Body
	draw_rect(Rect2(pos.x - 4, pos.y - 3, 8, 6), h_col)
	# Horse Neck & Head
	draw_line(pos + Vector2(3, 0), pos + Vector2(7, -5), h_col, 3.0)
	draw_circle(pos + Vector2(7.5, -5.5), 2.2, h_col)
	# Horse Legs
	draw_line(pos + Vector2(-3, 3), pos + Vector2(-3, 7), h_col, 1.4)
	draw_line(pos + Vector2(3, 3), pos + Vector2(3, 7), h_col, 1.4)
	# Horse Caparison / Barding (if heavy cavalry)
	if not light_scout:
		draw_rect(Rect2(pos.x - 3.5, pos.y - 1, 7, 3), tunic_col * Color(1, 1, 1, alpha))

	# Armored Rider
	draw_rect(Rect2(pos.x - 2, pos.y - 8, 4, 6), tunic_col * Color(1, 1, 1, alpha))
	draw_circle(pos + Vector2(0, -9.5), 2.2, COLOR_ARMOR_IRON * Color(1, 1, 1, alpha))
	# Cavalry Lance with Pennant
	var l_top := pos + Vector2(8, -17)
	var l_bot := pos + Vector2(0, 0)
	draw_line(l_top, l_bot, COLOR_WOOD_TIMBER * Color(1, 1, 1, alpha), 1.4)
	draw_line(l_top, l_top + Vector2(0, -3), COLOR_STEEL_WEAPON * Color(1, 1, 1, alpha), 1.6)
	# Lance Pennant
	var pennant := PackedVector2Array([
		l_top,
		l_top + Vector2(4, 2),
		l_top + Vector2(0, 4)
	])
	draw_colored_polygon(pennant, tunic_col * Color(1, 1, 1, alpha))

func _draw_conscript(pos: Vector2, tunic_col: Color, alpha: float) -> void:
	var t_col := tunic_col.darkened(0.2) * Color(1, 1, 1, alpha)
	# Rough linen tunic
	draw_rect(Rect2(pos.x - 2, pos.y - 5, 4, 6), t_col)
	# Head with cloth turban
	draw_circle(pos + Vector2(0, -7), 2.2, Color(0.75, 0.65, 0.50, alpha))
	draw_line(pos + Vector2(-2, -7), pos + Vector2(2, -7), Color(0.9, 0.8, 0.4, alpha), 1.2)
	# Bamboo Spear
	draw_line(pos + Vector2(2, -12), pos + Vector2(2, 4), Color(0.55, 0.48, 0.28, alpha), 1.2)

func _draw_siege_engine(pos: Vector2, alpha: float) -> void:
	# Wooden Trebuchet / Catapult Frame
	var wood_col := COLOR_WOOD_TIMBER * Color(1, 1, 1, alpha)
	draw_line(pos + Vector2(-8, 5), pos + Vector2(8, 5), wood_col, 2.5)
	draw_line(pos + Vector2(-5, 5), pos + Vector2(0, -6), wood_col, 2.0)
	draw_line(pos + Vector2(5, 5), pos + Vector2(0, -6), wood_col, 2.0)
	# Throwing Arm
	draw_line(pos + Vector2(-4, -1), pos + Vector2(7, -12), Color(0.6, 0.45, 0.3, alpha), 2.2)
	# Counterweight box
	draw_rect(Rect2(pos.x - 7, pos.y - 3, 5, 5), Color(0.3, 0.25, 0.2, alpha))

func _draw_command_canopy(pos: Vector2, alpha: float) -> void:
	# Imperial Golden Parasol (Luosan)
	var canopy_col := Color(0.95, 0.82, 0.25, 0.90 * alpha)
	var pole_col := Color(0.65, 0.50, 0.20, alpha)
	# Staff
	draw_line(pos + Vector2(0, -14), pos + Vector2(0, 4), pole_col, 1.8)
	# Curved umbrella top
	var canopy_poly := PackedVector2Array([
		pos + Vector2(0, -15),
		pos + Vector2(-9, -10),
		pos + Vector2(-6, -8),
		pos + Vector2(0, -9),
		pos + Vector2(6, -8),
		pos + Vector2(9, -10)
	])
	draw_colored_polygon(canopy_poly, canopy_col)
	# Red tassels hanging from umbrella rim
	draw_line(pos + Vector2(-9, -10), pos + Vector2(-9, -6), Color(0.9, 0.2, 0.2, alpha), 1.2)
	draw_line(pos + Vector2(9, -10), pos + Vector2(9, -6), Color(0.9, 0.2, 0.2, alpha), 1.2)

func _draw_supply_wagon(pos: Vector2, alpha: float) -> void:
	# Wooden baggage cart with wheels
	var wood_col := COLOR_WOOD_TIMBER * Color(1, 1, 1, alpha)
	draw_rect(Rect2(pos.x - 6, pos.y - 4, 12, 6), wood_col)
	# Grain sacks
	draw_circle(pos + Vector2(-3, -4), 2.8, Color(0.82, 0.76, 0.58, alpha))
	draw_circle(pos + Vector2(2, -4), 2.8, Color(0.82, 0.76, 0.58, alpha))
	# Wheels
	draw_circle(pos + Vector2(-4, 3), 3.0, Color(0.3, 0.22, 0.15, alpha))
	draw_circle(pos + Vector2(4, 3), 3.0, Color(0.3, 0.22, 0.15, alpha))

func _draw_routed_soldiers(tunic_col: Color, alpha: float) -> void:
	# Scattered fleeing figures
	for i in range(3):
		var rx := float(i * 6) - 6.0
		var ry := float(i * 4) + 1.0
		draw_rect(Rect2(rx - 2, ry - 3, 4, 5), tunic_col * Color(1, 1, 1, alpha))
		draw_circle(Vector2(rx, ry - 4.5), 1.8, Color(0.7, 0.6, 0.5, alpha))
		# Discarded weapon on ground
		draw_line(Vector2(rx - 4, ry + 3), Vector2(rx, ry + 2), COLOR_STEEL_WEAPON * Color(1, 1, 1, alpha), 1.0)
