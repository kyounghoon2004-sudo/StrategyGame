class_name Step2RUnitRenderer
extends Node2D

## Step2RUnitRenderer — 24x24 기반을 확장 스케일, 그림자, 외곽선, 배지 분리로 가시성 강화
## 요구 §20-22 충족: DEFAULT 줌에서 즉시 보이고, NORMAL_MAX에서 배지와 분리되어 읽힘

signal unit_hovered(unit_data: Dictionary)
signal unit_unhovered(unit_data: Dictionary)
signal unit_clicked(unit_data: Dictionary)

var HexUtilsCls: Script = preload("res://scripts/core/hex_utils.gd")
const _HexUtilsStatic = preload("res://scripts/core/hex_utils.gd")
var Step2RUnitBadgeCls: Script = preload("res://scripts/step2r/step2r_unit_badge.gd")
var Step2RFormationMarkerCls: Script = preload("res://scripts/visual/hex_native/approved_formation_marker.gd")
var S6: Script = preload("res://scripts/step6/step6_config.gd")
const SemanticZoomCls = preload("res://scripts/step2r/semantic_zoom.gd")
const PresentationOrientationCls = preload("res://scripts/core/presentation_orientation.gd")

var _units: Array[Dictionary] = []
var _unit_nodes: Dictionary = {}        # id -> Node2D container
var _badge_nodes: Dictionary = {}       # id -> Node2D badge
var _formation_nodes: Dictionary = {}   # id -> Step2RFormationMarker
var _hovered_unit_id: String = ""
var _selected_unit_id: String = ""
var _deemphasized_units: Dictionary = {} # id -> bool
var _dimmed_units: Dictionary = {}       # id -> bool
var _current_zoom: float = 1.15
var _display_mode: int = 0

const TYPE_MAP := {
	"infantry": "infantry",
	"archers": "archer",
	"archer": "archer",
	"cavalry": "cavalry",
	"spearmen": "spearman",
	"spearman": "spearman",
	"spear": "spearman",  # episode_spec_v0 canonical name
	"siege": "siege",
	"conscripts": "conscript",
	"conscript": "conscript",
	"scouts": "scout",
	"scout": "scout",
	"hq": "hq",
}

# Display tuning — terrain-first hierarchy: live formations occupy a compact
# central footprint while badges/HP remain readable interaction affordances.
const UNIT_DISPLAY_SCALE: float = 0.58
const FORMATION_PRESENTATION_SCALE: float = 1.0
const BADGE_PRESENTATION_SCALE: float = 0.28
# Overhead info (badge / HP bar / count label) is nearly invisible until the
# unit is hovered or selected — director request: map art stays clean.
const INFO_IDLE_ALPHA: float = 0.10
const INFO_ACTIVE_ALPHA: float = 0.95
const DEFAULT_UNIT_OPACITY: float = 0.65
const HOVER_SCALE_BOOST: float = 1.06

# Hex layout (y in [-21, 21]):
# TOP: HP Bar (y = -26), Badge (y = -12)
const BADGE_OFFSET: Vector2 = Vector2(0, -12)
const BADGE_OFFSET_Y_MIN_ZOOM: float = -13.0
const BADGE_OFFSET_Y_MAX_ZOOM: float = -11.0
const HP_BAR_OFFSET: Vector2 = Vector2(0, -26)
const HP_BAR_WIDTH: int = 24
const HP_BAR_HEIGHT: int = 4

# CENTER: Unit sprite (y = 1), Ground shadow (y = 6), Faction ring (y = 5)
const SPRITE_OFFSET: Vector2 = Vector2(0, 1)
const SHADOW_OFFSET: Vector2 = Vector2(0, 6)
const RING_OFFSET: Vector2 = Vector2(0, 5)
const SHADOW_RING_SCALE: Vector2 = Vector2(0.65, 0.65)

# BOTTOM: Count / Supply label (y in [13, 29])
const COUNT_LABEL_OFFSET: Vector2 = Vector2(-24, 12)
const COUNT_LABEL_SIZE: Vector2 = Vector2(48, 14)

# STEP-06R2 §3: Canonical render order structurally enforced:
# BASE TERRAIN (0) < TERRAIN DECORATION (5) < OVERLAYS (20..29) < LIVE UNITS (100..180) < BADGES (110..200) < SELECTION (250..300)
# Clamped elevation based on axial r (-40..40 maps to 100..180)
const UNIT_CONTAINER_Z_BASE: int = 100
const UNIT_CONTAINER_Z_FLOOR: int = 100

static func calculate_unit_z(r: int, q: int = 0) -> int:
	if PresentationOrientationCls.is_rotated():
		# Friendly-side yaw: painter's order follows SCREEN depth so a unit's
		# overhead HP bar / badge never tucks under the neighbour below it.
		# Same 0..80 band as the yaw-0 path (one step per hex row).
		var depth: float = PresentationOrientationCls.screen_depth(_HexUtilsStatic.hex_to_pixel(q, r))
		return UNIT_CONTAINER_Z_BASE + clampi(int(round(depth / 42.0)) + 40, 0, 80)
	return UNIT_CONTAINER_Z_BASE + clampi(r + 40, 0, 80)

const SUBSPRITE_Z_FLOOR: int = 2
const MARKER_BASE_PX: float = 20.0
const MARKER_MIN_SCALE: float = 0.65
const MARKER_MAX_SCALE: float = 1.00

static func calculate_badge_offset(zoom_val: float) -> Vector2:
	var t_zoom: float = clampf((zoom_val - 0.85) / (8.0 - 0.85), 0.0, 1.0)
	return Vector2(0, lerpf(BADGE_OFFSET_Y_MIN_ZOOM, BADGE_OFFSET_Y_MAX_ZOOM, t_zoom))


## Presentation compensation (DEV sandbox chess-style board).
##
## The Camera2D rotates the whole world canvas, so a unit's COSMETIC subnodes
## (shadow, ring, sprite, outline, formation art, badge, HP bar — labels already
## handle themselves) inherit that rotation and would render lying sideways.
## They cancel it at their own node level: the container keeps its canonical
## world position / z / id, only these visual children are counter-rotated, and
## their offsets are re-expressed in player (screen) space so nothing drifts.
## With yaw 0 (production) both helpers return the original values verbatim.
##
## The unit CONTAINER now carries the whole presentation frame (yaw + the
## perspective pre-stretch, see _apply_upright_frame), so cosmetic children
## use plain screen-space offsets and no rotation of their own. The container
## keeps its canonical world position / z / id; only its basis changes.
static func _vis_offset(offset: Vector2) -> Vector2:
	return offset


static func _vis_rotation() -> float:
	return 0.0


## Container basis = R(yaw) * S(1, stretch): children render upright and at
## a natural aspect after the perspective projection. The ground footprint
## cancels the stretch again (a flat-top hex is 120deg-symmetric, so only the
## stretch needs undoing). Identity at yaw 0 / no perspective.
## `lean` (perspective convergence) becomes a skew of the container's y axis:
## board basis M = [(1,0), st*(-lean,1)]; the footprint applies M^-1.
func _apply_upright_frame(container: Node2D, stretch: float, lean: float = 0.0, boost: float = 1.0) -> void:
	container.rotation = PresentationOrientationCls.upright_rotation()
	container.skew = atan(lean)
	container.scale = Vector2(boost, boost * stretch * sqrt(1.0 + lean * lean))
	container.set_meta("upright_frame", Vector3(stretch, lean, boost))
	if PresentationOrientationCls.frame_provider.is_valid():
		_plant_in_hex(container, stretch, boost)
	for n in ["HexFootprint", "HexFootprintEdge"]:
		var fp: Node2D = container.get_node_or_null(n) as Node2D
		if fp:
			# Exact inverse of the container basis: the footprint is ground and
			# keeps the true one-hex size (no stretch, lean or boost).
			fp.skew = -atan(lean * stretch)
			fp.scale = Vector2(1.0 / boost, sqrt(lean * lean + 1.0 / (stretch * stretch)) / boost)

## Perspective hex discipline: the formation art was authored top-down with
## its feet on the hex's bottom EDGE (+21). Standing up in perspective that
## puts the legs below the hex on screen. Here the feet are planted a little
## in front of the hex center (FEET_GROUND world px, inside the footprint),
## the body is drawn at PERSPECTIVE_FORMATION_SCALE, and the HP bar / count
## follow the body so the whole read stays on ONE hex.
const FEET_GROUND: float = 6.0
const TOPDOWN_FEET_GROUND: float = 17.0
const CLOSE_PRESENCE: float = 1.40
const PERSPECTIVE_FORMATION_SCALE: float = 0.84

## Both blend with the live view: at the commander (near top-down) view the
## original top-down layout returns (feet on the hex bottom edge, full size),
## at the battlefield view the perspective planting applies.
func _plant_in_hex(container: Node2D, stretch: float, boost: float) -> void:
	var ve: float = PresentationOrientationCls.view_e
	var feet_ground: float = lerpf(TOPDOWN_FEET_GROUND, FEET_GROUND, ve)
	# Battlefield view: formations stand at full size with a presence boost
	# (the army physically in front of you); the footprint hex is unchanged.
	var form_scale: float = lerpf(1.0, PERSPECTIVE_FORMATION_SCALE, smoothstep(0.0, 0.6, ve)) * lerpf(1.0, CLOSE_PRESENCE, smoothstep(0.55, 1.0, ve))
	var feet_local: float = feet_ground / maxf(0.01, stretch * boost)
	var form: Node2D = container.get_node_or_null("FormationMarker") as Node2D
	if form == null:
		return
	if absf(float(form.get("presentation_scale")) - form_scale) > 0.002 and form.has_method("set_presentation_scale"):
		form.call("set_presentation_scale", form_scale)
	var fs: float = form.scale.y
	form.position = Vector2(0.0, feet_local - 21.0 * fs)
	var hp: Node2D = container.get_node_or_null("HPBar") as Node2D
	if hp:
		hp.position = Vector2(0.0, feet_local - 42.0 * fs - 4.0)
	# Strategic read: toward the commander view the one-hex footprint becomes
	# a solid faction tile (clean tactical symbol); close in it is a light
	# ground tint under the standing formation.
	var sym: float = 1.0 - smoothstep(0.0, 0.45, ve)
	var fill: Polygon2D = container.get_node_or_null("HexFootprint") as Polygon2D
	if fill:
		fill.color.a = lerpf(0.26, 0.72, sym)
	var edge: Line2D = container.get_node_or_null("HexFootprintEdge") as Line2D
	if edge:
		edge.width = lerpf(1.6, 2.4, sym)
	var cl: Control = container.get_node_or_null("CountLabel") as Control
	if cl:
		cl.position = Vector2(COUNT_LABEL_OFFSET.x, feet_local + 1.0)

func _process(_delta: float) -> void:
	# CLOSEUP draws its own cards and HEADLESS draws nothing: the 2D unit nodes
	# are not on screen, so their upright frames are left until HIGH returns.
	if not PresentationOrientationCls.frame_provider.is_valid() or not PresentationOrientationCls.board_presented():
		return
	for id in _unit_nodes:
		var c: Node2D = _unit_nodes[id] as Node2D
		if is_instance_valid(c):
			var f: Vector3 = PresentationOrientationCls.frame_at_world(c.position)
			var cur: Vector3 = c.get_meta("upright_frame", Vector3.ZERO)
			# view_e is folded in so formation scale / planting follow zoom
			# even when stretch and lean happen to be unchanged.
			var ve: float = PresentationOrientationCls.view_e
			if (cur - f).length_squared() > 0.00002 or absf(float(c.get_meta("view_e", -1.0)) - ve) > 0.002:
				c.set_meta("view_e", ve)
				_apply_upright_frame(c, f.x, f.y, f.z)
			# Low pitch: a front formation can overlap the one behind it, so
			# the count label + HP bar render above ALL unit art (absolute z),
			# still depth-ordered among themselves.
			for ln in ["CountLabel", "HPBar", "SupplyLabel"]:
				var li: CanvasItem = c.get_node_or_null(ln) as CanvasItem
				if li:
					li.z_as_relative = false
					li.z_index = c.z_index + 150

func set_camera_zoom(zoom_val: float) -> void:
	# PERF-V1: camera_updated fires every frame; skip no-change updates so 64
	# formation markers are not redrawn at 60fps while idle.
	if is_equal_approx(_current_zoom, zoom_val):
		return
	_current_zoom = zoom_val
	var offset: Vector2 = calculate_badge_offset(zoom_val)
	var bmult: float = SemanticZoomCls.badge_mult_for_zoom(zoom_val)
	for id in _badge_nodes.keys():
		var badge: Node = _badge_nodes[id]
		if is_instance_valid(badge):
			badge.position = _vis_offset(offset)
			badge.scale = Vector2(BADGE_PRESENTATION_SCALE, BADGE_PRESENTATION_SCALE) * bmult
			if badge.has_method("set_camera_zoom"):
				badge.call("set_camera_zoom", zoom_val)
			# Marker scaling bounded across overview and close tactical zoom
			var inv_scale: float = clampf(MARKER_BASE_PX / (24.0 * maxf(zoom_val, 0.6)), MARKER_MIN_SCALE, MARKER_MAX_SCALE)
			var rest_icon: Node = badge.get_node_or_null("RestIcon") as Node
			if rest_icon and rest_icon is Sprite2D:
				(rest_icon as Sprite2D).scale = Vector2(inv_scale, inv_scale)
			var fort_icon: Node = badge.get_node_or_null("FortifiedIcon") as Node
			if fort_icon and fort_icon is Sprite2D:
				(fort_icon as Sprite2D).scale = Vector2(inv_scale, inv_scale)
	# Semantic zoom: HP bars hold a constant screen footprint (§10) and troop
	# counts stay ~15px on screen (§9) instead of ballooning with the camera.
	for id in _unit_nodes.keys():
		var node: Node2D = _unit_nodes[id] as Node2D
		if is_instance_valid(node):
			var hp: Sprite2D = node.get_node_or_null("HPBar") as Sprite2D
			if hp:
				hp.scale = SemanticZoomCls.hp_scale(zoom_val)
			for lbl_name in ["CountLabel", "SupplyLabel"]:
				var num_lbl: Label = node.get_node_or_null(lbl_name) as Label
				if num_lbl:
					var fpx: float = 10.0
					if num_lbl.has_theme_font_size_override("font_size"):
						fpx = float(num_lbl.get_theme_font_size("font_size"))
					var ls: float = SemanticZoomCls.label_scale(zoom_val, fpx)
					num_lbl.scale = Vector2(ls, ls)
					num_lbl.add_theme_constant_override("outline_size", SemanticZoomCls.label_outline_size(zoom_val))
	for id in _formation_nodes.keys():
		var fm: Node = _formation_nodes[id]
		if is_instance_valid(fm) and fm.has_method("set_camera_zoom"):
			fm.call("set_camera_zoom", zoom_val)

func _ready() -> void:
	z_index = 0 # Transparent root layer, containers use absolute canonical z (100..180)

func clear_units() -> void:
	for n in _unit_nodes.values():
		if is_instance_valid(n):
			n.queue_free()
	_units.clear()
	_unit_nodes.clear()
	_badge_nodes.clear()
	_formation_nodes.clear()
	_hovered_unit_id = ""

func spawn_unit(id: String, unit_class: String, faction: String, q: int, r: int, soldier_count: int, form_factor: String = "form_a") -> Dictionary:
	if unit_class.to_lower() == "supply":
		push_warning("[UnitRenderer] Supply-class unit spawning is retired and prohibited: " + id)
		return {}
	if not TYPE_MAP.has(unit_class.to_lower()):
		push_error("[UnitRenderer] unknown unit class '%s' for %s; spawning as infantry" % [unit_class, id])
	var norm_class: String = TYPE_MAP.get(unit_class.to_lower(), "infantry")
	var norm_faction: String = "red" if (faction.to_lower() == "red" or faction.to_lower() == "enemy") else "blue"
	# STEP-06R1 §2: re-spawning an already-live id must never stack a second
	# node (desync reads as disappearance). Snap the live node to truth.
	if _unit_nodes.has(id) and is_instance_valid(_unit_nodes[id]):
		update_unit_position(id, q, r)
		update_unit_health(id, soldier_count)
		(_unit_nodes[id] as Node2D).visible = true
		for u in _units:
			if str(u["id"]) == id:
				u["class"] = norm_class
				u["faction"] = norm_faction
				return u
	var data: Dictionary = {
		"id": id,
		"class": norm_class,
		"faction": norm_faction,
		"q": q,
		"r": r,
		"soldier_count": soldier_count,
		"max_count": soldier_count,
		"form_factor": form_factor
	}
	_units.append(data)
	_build_unit_node(data)
	return data

# STEP-06R1 §2: visibility authority helpers. Ordinary movement, cavalry
# post-attack moves and repositioning must NEVER hide a live friendly.
func has_live_node(id: String) -> bool:
	return _unit_nodes.has(id) and is_instance_valid(_unit_nodes[id])

func set_node_visible(id: String, vis: bool) -> void:
	if _unit_nodes.has(id) and is_instance_valid(_unit_nodes[id]):
		(_unit_nodes[id] as Node2D).visible = vis

const FOOTPRINT_RADIUS: float = 20.5 # hex circumradius is 24; stays inside borders
const FOOTPRINT_FILL_BLUE := Color(0.20, 0.40, 0.82, 0.26)
const FOOTPRINT_FILL_RED := Color(0.80, 0.20, 0.16, 0.26)
const FOOTPRINT_EDGE_BLUE := Color(0.46, 0.66, 1.00, 0.85)
const FOOTPRINT_EDGE_RED := Color(1.00, 0.46, 0.38, 0.85)

func _add_hex_footprint(container: Node2D, is_blue: bool) -> void:
	var pts := PackedVector2Array()
	for k in range(6):
		var a: float = deg_to_rad(60.0 * k)
		pts.append(Vector2(cos(a), sin(a) * (42.0 / 41.569)) * FOOTPRINT_RADIUS)
	var fill := Polygon2D.new()
	fill.name = "HexFootprint"
	fill.polygon = pts
	fill.color = FOOTPRINT_FILL_BLUE if is_blue else FOOTPRINT_FILL_RED
	fill.z_index = -4
	container.add_child(fill)
	var edge := Line2D.new()
	edge.name = "HexFootprintEdge"
	for p in pts:
		edge.add_point(p)
	edge.closed = true
	edge.width = 1.6
	edge.antialiased = true
	edge.default_color = FOOTPRINT_EDGE_BLUE if is_blue else FOOTPRINT_EDGE_RED
	edge.z_index = -4
	container.add_child(edge)

func _build_unit_node(data: Dictionary) -> Node2D:
	var q: int = data["q"]
	var r: int = data["r"]
	var id: String = data["id"]
	var world_pos: Vector2 = HexUtilsCls.hex_to_pixel(q, r)

	var container: Node2D = Node2D.new()
	container.name = "Unit_%s" % id
	container.position = world_pos
	# STEP-06R2 §3: Live Units canonical Z range is 100..180 (always strictly above terrain & overlays)
	container.z_index = calculate_unit_z(r, q)
	container.set_meta("unit_id", id)
	container.set_meta("q", q)
	container.set_meta("r", r)
	add_child(container)

	# 00. Hex occupancy footprint — "this hex is held, and by whom". Inset
	# inside the owning hex (never touches a neighbour), world-aligned (the
	# flat-top hex is 120deg-symmetric, so it matches the grid under the
	# friendly-side yaw too). Sits under all unit art.
	_add_hex_footprint(container, str(data["faction"]) == "blue")
	_apply_upright_frame(container, PresentationOrientationCls.stretch_at_world(world_pos))

	# 0. Ground shadow — contrast and placement anchor
	var shadow: Sprite2D = Sprite2D.new()
	shadow.name = "GroundShadow"
	shadow.centered = true
	shadow.position = _vis_offset(SHADOW_OFFSET)
	shadow.rotation = _vis_rotation()
	shadow.scale = SHADOW_RING_SCALE
	shadow.z_index = -2
	shadow.texture = _generate_shadow_texture()
	shadow.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	container.add_child(shadow)

	# 0b. Faction ring under unit for instant faction read
	var ring: Sprite2D = Sprite2D.new()
	ring.name = "FactionRing"
	ring.centered = true
	ring.position = _vis_offset(RING_OFFSET)
	ring.rotation = _vis_rotation()
	ring.scale = SHADOW_RING_SCALE
	ring.z_index = -1
	if str(data["class"]) == "supply":
		ring.texture = _generate_supply_ring(data["faction"] == "blue")
	elif str(data["class"]) == "hq":
		ring.texture = _generate_hq_ring(data["faction"] == "blue")
	else:
		ring.texture = _generate_faction_ring(data["faction"] == "blue")
	ring.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	container.add_child(ring)
	# STEP-06R2 §24: Compact supply unit map representation. Label is hidden by default.
	if str(data["class"]) == "supply":
		var sup_lbl: Label = Label.new()
		sup_lbl.name = "SupplyLabel"
		sup_lbl.text = "보급대"
		# World-space text stays horizontal under a rotated presentation
		# (DEV sandbox chess-style board); yaw 0 -> original offset.
		sup_lbl.position = COUNT_LABEL_OFFSET
		sup_lbl.size = COUNT_LABEL_SIZE
		sup_lbl.pivot_offset = COUNT_LABEL_SIZE * 0.5
		sup_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		sup_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		sup_lbl.add_theme_font_size_override("font_size", 10)
		var sup_gold := Color(1.0, 0.88, 0.45, 1.0)
		sup_lbl.add_theme_color_override("font_color", sup_gold)
		sup_lbl.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.95))
		sup_lbl.add_theme_constant_override("shadow_offset_x", 1)
		sup_lbl.add_theme_constant_override("shadow_offset_y", 1)
		sup_lbl.add_theme_constant_override("outline_size", 3)
		sup_lbl.add_theme_color_override("font_outline_color", Color(0.12, 0.08, 0.02, 1.0))
		sup_lbl.z_index = 36
		sup_lbl.visible = false
		container.add_child(sup_lbl)

	# 1. Outline duplicate behind main sprite for contrast on any terrain
	var outline_sprite: Sprite2D = Sprite2D.new()
	outline_sprite.name = "CharacterOutline"
	outline_sprite.centered = true
	outline_sprite.position = _vis_offset(SPRITE_OFFSET)
	outline_sprite.rotation = _vis_rotation()
	outline_sprite.scale = Vector2(UNIT_DISPLAY_SCALE * 1.08, UNIT_DISPLAY_SCALE * 1.08)
	outline_sprite.modulate = Color(0, 0, 0, 0.50)
	outline_sprite.z_index = 9
	outline_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	var sprite_path: String = "res://assets/sprites/unit_%s_%s.png" % [data["class"], data["faction"]]
	var sprite_tex: Texture2D = _load_tex(sprite_path)
	if sprite_tex == null:
		# STEP-06: HQ / supply convoy reuse the closest body sprite (no new art).
		var fallback_class: String = "infantry" if str(data["class"]) == "hq" else "conscript"
		sprite_tex = _load_tex("res://assets/sprites/unit_%s_%s.png" % [fallback_class, data["faction"]])
		if sprite_tex == null:
			push_warning("[Step2RUnitRenderer] Missing sprite: %s" % sprite_path)
	if sprite_tex != null:
		outline_sprite.texture = sprite_tex
	outline_sprite.visible = false # Legacy body silhouette retired.
	container.add_child(outline_sprite)

	# 2. Main 24x24 Character Counter Sprite (retained as node reference for compatibility)
	var sprite: Sprite2D = Sprite2D.new()
	sprite.name = "CharacterSprite"
	sprite.centered = true
	sprite.position = _vis_offset(SPRITE_OFFSET)
	sprite.rotation = _vis_rotation()
	sprite.scale = Vector2(UNIT_DISPLAY_SCALE, UNIT_DISPLAY_SCALE)
	sprite.modulate = Color(1.0, 1.0, 1.0, DEFAULT_UNIT_OPACITY)
	sprite.z_index = 10
	sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	if sprite_tex != null:
		sprite.texture = sprite_tex
	else:
		push_warning("[Step2RUnitRenderer] Missing sprite: %s" % sprite_path)
	sprite.visible = false # Submerged: replaced by stylized Army Formation Marker
	container.add_child(sprite)

	# 2b. Five Dynasties Army Formation & War Banner Marker — the visible unit art.
	var formation: Node2D = Step2RFormationMarkerCls.new() as Node2D
	formation.name = "FormationMarker"
	formation.position = Vector2.ZERO
	formation.rotation = _vis_rotation()
	formation.scale = Vector2(FORMATION_PRESENTATION_SCALE, FORMATION_PRESENTATION_SCALE)
	formation.z_index = 12
	if formation.has_method("setup"):
		formation.call("setup", data["class"], data["faction"], data["soldier_count"], _current_zoom)
	container.add_child(formation)
	_formation_nodes[id] = formation

	# 3. Always-On Overhead Badge — adaptive scaling & vertical offset
	var badge: Node2D = Step2RUnitBadgeCls.new() as Node2D
	badge.name = "OverheadBadge"
	badge.position = _vis_offset(calculate_badge_offset(_current_zoom))
	badge.rotation = _vis_rotation()
	badge.scale = Vector2(BADGE_PRESENTATION_SCALE, BADGE_PRESENTATION_SCALE) * SemanticZoomCls.badge_mult_for_zoom(_current_zoom)
	badge.z_index = 28
	if badge.has_method("setup"):
		badge.call("setup", data["class"], data["faction"], data["form_factor"], _current_zoom)
	container.add_child(badge)

	# 4. HP bar — compact width & height right above badge in hex top slot
	var hp_bar: Sprite2D = Sprite2D.new()
	hp_bar.name = "HPBar"
	hp_bar.centered = true
	hp_bar.position = _vis_offset(HP_BAR_OFFSET)
	hp_bar.rotation = _vis_rotation()
	hp_bar.texture = _generate_hp_texture(1.0, data["faction"] == "blue")
	hp_bar.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	hp_bar.z_index = 35 # above badge (28) and markers (32)
	container.add_child(hp_bar)

	# 5. Soldier count label — compact single-hex bottom slot.
	# pivot_offset centers semantic-zoom scaling so the count does not drift.
	var count_lbl: Label = Label.new()
	count_lbl.name = "CountLabel"
	# World-space text stays horizontal under a rotated presentation
	# (DEV sandbox chess-style board); yaw 0 -> original offset.
	count_lbl.position = COUNT_LABEL_OFFSET
	count_lbl.size = COUNT_LABEL_SIZE
	count_lbl.pivot_offset = COUNT_LABEL_SIZE * 0.5
	count_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	count_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	if str(data["class"]) == "supply":
		count_lbl.text = ""
	else:
		count_lbl.text = _format_soldier_count(data["soldier_count"])
	count_lbl.add_theme_font_size_override("font_size", 10)
	# Stat numbers stay legible but recede: warm off-white, semi-transparent.
	count_lbl.add_theme_color_override("font_color", Color(1.0, 0.97, 0.90, 1.0))
	count_lbl.modulate = Color(1, 1, 1, 0.74)
	count_lbl.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.95))
	count_lbl.add_theme_constant_override("shadow_offset_x", 1)
	count_lbl.add_theme_constant_override("shadow_offset_y", 1)
	count_lbl.add_theme_constant_override("outline_size", SemanticZoomCls.label_outline_size(_current_zoom))
	count_lbl.add_theme_color_override("font_outline_color", Color(0.10, 0.08, 0.05, 0.85))
	container.add_child(count_lbl)

	_unit_nodes[id] = container
	_badge_nodes[id] = badge
	# New spawns inherit the live semantic-zoom state immediately (no 1-frame
	# uncompensated flash before the next camera_updated).
	if formation.has_method("set_camera_zoom"):
		formation.call("set_camera_zoom", _current_zoom)
	var _hp0: Sprite2D = container.get_node_or_null("HPBar") as Sprite2D
	if _hp0:
		_hp0.scale = SemanticZoomCls.hp_scale(_current_zoom)
	for _ln in ["CountLabel", "SupplyLabel"]:
		var _nl: Label = container.get_node_or_null(_ln) as Label
		if _nl:
			var _fp: float = 10.0
			if _nl.has_theme_font_size_override("font_size"):
				_fp = float(_nl.get_theme_font_size("font_size"))
			var _ls: float = SemanticZoomCls.label_scale(_current_zoom, _fp)
			_nl.scale = Vector2(_ls, _ls)
			_nl.add_theme_constant_override("outline_size", SemanticZoomCls.label_outline_size(_current_zoom))
	return container

func _format_soldier_count(count: int) -> String:
	if count >= 1000:
		var k: float = float(count) / 1000.0
		return "%.1fk" % k if (count % 1000 >= 100) else "%dk" % int(k)
	return str(count)

## Procedural marker / bar textures depend only on their key (faction, fill
## pixels, kind): built once per process and shared by every unit instead of
## re-rasterized per spawn / HP update / fog pass (VISUAL ONLY, same pixels).
static var _tex_cache: Dictionary = {}

static func _cache_texture(key: String, tex: Texture2D) -> Texture2D:
	_tex_cache[key] = tex
	return tex

func _generate_shadow_texture() -> Texture2D:
	var _ck: String = "shadow"
	if _tex_cache.has(_ck):
		return _tex_cache[_ck]
	var w: int = 32
	var h: int = 12
	var img: Image = Image.create(w, h, false, Image.FORMAT_RGBA8)
	for y in range(h):
		for x in range(w):
			var dx: float = float(x - w/2) / float(w/2)
			var dy: float = float(y - h/2) / float(h/2)
			var d: float = dx*dx + dy*dy
			var a: float = clampf(0.55 * (1.0 - d), 0.0, 0.55)
			# feather edge
			if d > 0.7:
				a *= 1.0 - (d - 0.7)/0.3
			img.set_pixel(x, y, Color(0, 0, 0, a))
	return _cache_texture(_ck, ImageTexture.create_from_image(img))

func _generate_faction_ring(is_blue: bool) -> Texture2D:
	var _ck: String = "ring_%s" % str(is_blue)
	if _tex_cache.has(_ck):
		return _tex_cache[_ck]
	var w: int = 36
	var h: int = 14
	var img: Image = Image.create(w, h, false, Image.FORMAT_RGBA8)
	var col: Color = Color(0.24, 0.52, 0.95, 0.55) if is_blue else Color(0.92, 0.32, 0.28, 0.55)
	var border: Color = Color(1, 1, 1, 0.85) if is_blue else Color(1, 0.92, 0.6, 0.85)
	for y in range(h):
		for x in range(w):
			var dx: float = float(x - w/2) / float(w/2)
			var dy: float = float(y - h/2) / float(h/2)
			var d: float = dx*dx + dy*dy
			if d > 1.0:
				img.set_pixel(x, y, Color(0,0,0,0))
			elif d > 0.75:
				# ring border
				img.set_pixel(x, y, border)
			elif d > 0.20:
				img.set_pixel(x, y, col)
			else:
				img.set_pixel(x, y, Color(0,0,0,0))
	return _cache_texture(_ck, ImageTexture.create_from_image(img))

# STEP-06R1 S14: logistics-only ring - grain-gold with faction-tinted border.
# Blue convoy: gold fill + pale border. Red convoy: bronze fill + red border.
func _generate_supply_ring(is_blue: bool) -> Texture2D:
	var _ck: String = "supply_ring_%s" % str(is_blue)
	if _tex_cache.has(_ck):
		return _tex_cache[_ck]
	var w: int = 36
	var h: int = 14
	var img: Image = Image.create(w, h, false, Image.FORMAT_RGBA8)
	var col: Color = Color(0.85, 0.66, 0.22, 0.60) if is_blue else Color(0.62, 0.42, 0.18, 0.60)
	var border: Color = Color(1.0, 0.90, 0.55, 0.95) if is_blue else Color(1.0, 0.72, 0.42, 0.95)
	for y in range(h):
		for x in range(w):
			var dx: float = float(x - w/2) / float(w/2)
			var dy: float = float(y - h/2) / float(h/2)
			var d: float = dx*dx + dy*dy
			if d > 1.0:
				img.set_pixel(x, y, Color(0,0,0,0))
			elif d > 0.75:
				img.set_pixel(x, y, border)
			elif d > 0.20:
				img.set_pixel(x, y, col)
			else:
				img.set_pixel(x, y, Color(0,0,0,0))
	# Dashed logistics read: punch two dark gaps on the flanks.
	for y in range(5, 9):
		for x in [2, 3, w - 4, w - 3]:
			img.set_pixel(x, y, Color(0, 0, 0, 0))
	return _cache_texture(_ck, ImageTexture.create_from_image(img))

# STEP-06R3 §32: HQ Command Camp ground ring — gold double-ring strategic anchor identity
func _generate_hq_ring(is_blue: bool) -> Texture2D:
	var _ck: String = "hq_ring_%s" % str(is_blue)
	if _tex_cache.has(_ck):
		return _tex_cache[_ck]
	var w: int = 40
	var h: int = 16
	var img: Image = Image.create(w, h, false, Image.FORMAT_RGBA8)
	var col: Color = Color(0.95, 0.78, 0.20, 0.70) if is_blue else Color(0.85, 0.35, 0.20, 0.70)
	var border: Color = Color(1.0, 0.95, 0.65, 0.95) if is_blue else Color(1.0, 0.75, 0.55, 0.95)
	for y in range(h):
		for x in range(w):
			var dx: float = float(x - w/2) / float(w/2)
			var dy: float = float(y - h/2) / float(h/2)
			var d: float = dx*dx + dy*dy
			if d > 1.0:
				img.set_pixel(x, y, Color(0, 0, 0, 0))
			elif d > 0.80:
				img.set_pixel(x, y, border)
			elif d > 0.45:
				img.set_pixel(x, y, col)
			elif d > 0.30:
				img.set_pixel(x, y, border) # inner concentric ring
			else:
				img.set_pixel(x, y, Color(0, 0, 0, 0))
	return _cache_texture(_ck, ImageTexture.create_from_image(img))

func _generate_hp_texture(ratio: float, is_friendly: bool) -> Texture2D:
	var _ck: String = "hp_%d_%s" % [roundi(float(HP_BAR_WIDTH - 2) * clampf(ratio, 0.0, 1.0)), str(is_friendly)]
	if _tex_cache.has(_ck):
		return _tex_cache[_ck]
	var width: int = HP_BAR_WIDTH
	var height: int = HP_BAR_HEIGHT
	var image: Image = Image.create(width, height, false, Image.FORMAT_RGBA8)
	var black: Color = Color(0.04, 0.04, 0.06, 1.0)
	var border: Color = Color(0.08, 0.08, 0.12, 1.0)
	var fill_col: Color = Color(0.16, 0.84, 0.44, 1.0) if is_friendly else Color(0.92, 0.28, 0.24, 1.0)
	# 1. Outer border + dark background
	for y in range(height):
		for x in range(width):
			if y == 0 or y == height - 1 or x == 0 or x == width - 1:
				image.set_pixel(x, y, border)
			else:
				image.set_pixel(x, y, black)
	# 2. Fill bar
	var inner_w: int = width - 2
	var fill_pixels: int = int(roundi(float(inner_w) * clampf(ratio, 0.0, 1.0)))
	for y in range(1, height - 1):
		for x in range(1, 1 + fill_pixels):
			image.set_pixel(x, y, fill_col)
	# 3. Highlight line on top row & shadow line on bottom row
	for x in range(1, 1 + fill_pixels):
		image.set_pixel(x, 1, fill_col.lightened(0.28))
		if height > 3:
			image.set_pixel(x, height - 2, fill_col.darkened(0.22))
	# 4. High-density military segmented gauge tick notches (25%, 50%, 75%)
	var notch_positions: Array[int] = [1 + inner_w / 4, 1 + inner_w / 2, 1 + (inner_w * 3) / 4]
	var tick_dark: Color = Color(0.04, 0.05, 0.08, 0.92)
	var tick_faint: Color = Color(0.16, 0.16, 0.22, 0.85)
	for nx in notch_positions:
		var col: Color = tick_dark if nx <= (1 + fill_pixels) else tick_faint
		for y in range(1, height - 1):
			image.set_pixel(nx, y, col)
	return _cache_texture(_ck, ImageTexture.create_from_image(image))

func _load_tex(path: String) -> Texture2D:
	if ResourceLoader.exists(path):
		return load(path) as Texture2D
	elif FileAccess.file_exists(path):
		var img: Image = Image.load_from_file(path)
		if img != null:
			return ImageTexture.create_from_image(img)
	return null

func get_unit_at(q: int, r: int) -> Dictionary:
	for u in _units:
		if int(u["q"]) == q and int(u["r"]) == r:
			return u
	return {}

func get_all_units() -> Array[Dictionary]:
	return _units.duplicate()

func set_selected_unit(id: String) -> void:
	var old_id: String = _selected_unit_id
	_selected_unit_id = id
	if old_id != "" and old_id != id:
		_update_unit_visual_state(old_id)
	if _selected_unit_id != "":
		_update_unit_visual_state(_selected_unit_id)

func get_selected_unit_id() -> String:
	return _selected_unit_id

func _update_unit_visual_state(id: String) -> void:
	var node: Node2D = _unit_nodes.get(id, null) as Node2D
	if node == null or not is_instance_valid(node):
		return
	var sprite: Sprite2D = node.get_node_or_null("CharacterSprite") as Sprite2D
	var outline: Sprite2D = node.get_node_or_null("CharacterOutline") as Sprite2D
	if sprite == null:
		return
	
	var is_hovered: bool = (id == _hovered_unit_id)
	var is_selected: bool = (id == _selected_unit_id)
	var is_deemp: bool = bool(_deemphasized_units.get(id, false))
	var is_dim: bool = bool(_dimmed_units.get(id, false))
	
	if is_hovered:
		# Hover: 100% opacity, 1.06x scale bump, full emphasis
		sprite.modulate = Color(1.08, 1.08, 1.08, 1.0)
		sprite.scale = Vector2(UNIT_DISPLAY_SCALE * HOVER_SCALE_BOOST, UNIT_DISPLAY_SCALE * HOVER_SCALE_BOOST)
		if outline:
			outline.modulate = Color(0, 0, 0, 0.85)
			outline.scale = Vector2(UNIT_DISPLAY_SCALE * 1.16, UNIT_DISPLAY_SCALE * 1.16)
	elif is_selected:
		# Selected: full 100% opacity, crisp focus
		sprite.modulate = Color(1.0, 1.0, 1.0, 1.0)
		sprite.scale = Vector2(UNIT_DISPLAY_SCALE * 1.02, UNIT_DISPLAY_SCALE * 1.02)
		if outline:
			outline.modulate = Color(0, 0, 0, 0.80)
			outline.scale = Vector2(UNIT_DISPLAY_SCALE * 1.12, UNIT_DISPLAY_SCALE * 1.12)
	elif is_deemp:
		# Logistics mode muted presentation for non-active combat units
		sprite.modulate = Color(0.40, 0.42, 0.48, 0.45)
		sprite.scale = Vector2(UNIT_DISPLAY_SCALE, UNIT_DISPLAY_SCALE)
		if outline:
			outline.modulate = Color(0, 0, 0, 0.30)
			outline.scale = Vector2(UNIT_DISPLAY_SCALE * 1.08, UNIT_DISPLAY_SCALE * 1.08)
	elif is_dim:
		sprite.modulate = Color(0.55, 0.55, 0.60, 0.50)
		sprite.scale = Vector2(UNIT_DISPLAY_SCALE, UNIT_DISPLAY_SCALE)
		if outline:
			outline.modulate = Color(0, 0, 0, 0.35)
			outline.scale = Vector2(UNIT_DISPLAY_SCALE * 1.08, UNIT_DISPLAY_SCALE * 1.08)
	else:
		# Default normal state: 65% opacity, base 0.92 scale
		sprite.modulate = Color(1.0, 1.0, 1.0, DEFAULT_UNIT_OPACITY)
		sprite.scale = Vector2(UNIT_DISPLAY_SCALE, UNIT_DISPLAY_SCALE)
		if outline:
			outline.modulate = Color(0, 0, 0, 0.50)
			outline.scale = Vector2(UNIT_DISPLAY_SCALE * 1.08, UNIT_DISPLAY_SCALE * 1.08)

	var formation: Variant = _formation_nodes.get(id, null)
	if formation and formation.has_method("update_status"):
		var is_routed: bool = false
		for u in _units:
			if str(u["id"]) == id:
				is_routed = bool(u.get("routed", false))
				break
		var is_fortified: bool = false
		var badge: Node2D = _badge_nodes.get(id, null) as Node2D
		if badge:
			var fort_icon: Node = badge.get_node_or_null("FortifiedIcon")
			if fort_icon and fort_icon is CanvasItem:
				is_fortified = (fort_icon as CanvasItem).visible
		formation.call("update_status", is_selected, is_hovered, is_routed, is_fortified, is_dim or is_deemp)

	# Overhead info (badge/HP/count) is nearly invisible unless hovered/selected.
	var info_alpha: float = INFO_ACTIVE_ALPHA if (is_hovered or is_selected) else INFO_IDLE_ALPHA
	var info_badge: Node2D = _badge_nodes.get(id, null) as Node2D
	if info_badge:
		info_badge.modulate = Color(1, 1, 1, info_alpha)
	var hp_node: Sprite2D = node.get_node_or_null("HPBar") as Sprite2D
	if hp_node:
		hp_node.self_modulate = Color(1, 1, 1, info_alpha)
	var cnt_node: Label = node.get_node_or_null("CountLabel") as Label
	if cnt_node:
		cnt_node.modulate = Color(1, 1, 1, info_alpha)

func set_hover_at_hex(q: int, r: int) -> void:
	var target_id: String = ""
	for u in _units:
		if int(u["q"]) == q and int(u["r"]) == r:
			target_id = str(u["id"])
			break
	if target_id == _hovered_unit_id:
		return
	var prev_id: String = _hovered_unit_id
	# clear previous
	if prev_id != "" and _badge_nodes.has(prev_id):
		var prev_badge: Node = _badge_nodes[prev_id]
		if prev_badge and prev_badge.has_method("set_hovered"):
			prev_badge.call("set_hovered", false)
		var prev_data: Dictionary = {}
		for u in _units:
			if str(u["id"]) == prev_id:
				prev_data = u
				break
		if not prev_data.is_empty():
			unit_unhovered.emit(prev_data)
	_hovered_unit_id = target_id
	if prev_id != "":
		_update_unit_visual_state(prev_id)
	if _hovered_unit_id != "" and _badge_nodes.has(_hovered_unit_id):
		var badge: Node = _badge_nodes[_hovered_unit_id]
		if badge and badge.has_method("set_hovered"):
			badge.call("set_hovered", true)
		_update_unit_visual_state(_hovered_unit_id)
		for u in _units:
			if str(u["id"]) == _hovered_unit_id:
				unit_hovered.emit(u)
				break

func clear_hover() -> void:
	var prev_id: String = _hovered_unit_id
	if prev_id != "" and _badge_nodes.has(prev_id):
		var badge: Node = _badge_nodes[prev_id]
		if badge and badge.has_method("set_hovered"):
			badge.call("set_hovered", false)
		var prev_data: Dictionary = {}
		for u in _units:
			if str(u["id"]) == prev_id:
				prev_data = u
				break
		if not prev_data.is_empty():
			unit_unhovered.emit(prev_data)
	_hovered_unit_id = ""
	if prev_id != "":
		_update_unit_visual_state(prev_id)

func get_hovered_unit_id() -> String:
	return _hovered_unit_id

func get_unit_node(id: String) -> Node2D:
	return _unit_nodes.get(id, null) as Node2D

func update_unit_position(id: String, q: int, r: int) -> void:
	for u in _units:
		if str(u["id"]) == id:
			u["q"] = q
			u["r"] = r
			break
	if _unit_nodes.has(id):
		var node: Node2D = _unit_nodes[id] as Node2D
		if is_instance_valid(node):
			# DRIFT-FIX: a truth snap supersedes any in-flight presentation motion
			# (attack lunge / hit shake). Killing it also discards its stale
			# captured restore target so it can never snap the node back to an
			# older hex after the truth changed.
			_kill_motion_tween(node)
			node.position = HexUtilsCls.hex_to_pixel(q, r)
			# STEP-06R2 §3: Structurally enforce canonical Z elevation (100..180)
			node.z_index = calculate_unit_z(r, q)
			node.set_meta("q", q)
			node.set_meta("r", r)

func set_unit_dimmed(id: String, dimmed: bool) -> void:
	_dimmed_units[id] = dimmed
	_update_unit_visual_state(id)

func _generate_rest_marker_texture() -> Texture2D:
	var _ck: String = "rest_marker"
	if _tex_cache.has(_ck):
		return _tex_cache[_ck]
	# STEP-04R10 §7: ZZZ REST marker — LEFT side, 32x32 high-density medallion
	var sz: int = 32
	var img: Image = Image.create(sz, sz, false, Image.FORMAT_RGBA8)
	var cx: float = 16.0
	var cy: float = 16.0
	var col_dark := Color(0.05, 0.06, 0.08, 1.0)
	var col_silver := Color(0.82, 0.88, 0.98, 1.0)
	var col_indigo_top := Color(0.32, 0.42, 0.72, 1.0)
	var col_indigo_bot := Color(0.14, 0.20, 0.40, 1.0)
	var col_white := Color(1.0, 1.0, 1.0, 1.0)

	for y in range(sz):
		for x in range(sz):
			var dx: float = float(x) - cx + 0.5
			var dy: float = float(y) - cy + 0.5
			var d: float = sqrt(dx * dx + dy * dy)
			if d <= 14.5 and d > 13.5:
				img.set_pixel(x, y, col_dark)
			elif d <= 13.5 and d > 11.5:
				img.set_pixel(x, y, col_silver if y <= 16 else col_silver.darkened(0.20))
			elif d <= 11.5:
				var t: float = float(y - 5) / 22.0
				img.set_pixel(x, y, col_indigo_top.lerp(col_indigo_bot, clampf(t, 0.0, 1.0)))

	# Draw crisp high-density 1px stepped ZZZ
	var z_offsets: Array = [[7, 9], [13, 12], [18, 15]]
	for zo in z_offsets:
		var zx: int = zo[0]
		var zy: int = zo[1]
		for x in range(zx, zx + 6):
			img.set_pixel(x + 1, zy + 1, col_dark)
			img.set_pixel(x + 1, zy + 6, col_dark)
		for i in range(5):
			img.set_pixel(zx + 4 - i + 1, zy + i + 2, col_dark)
		for x in range(zx, zx + 6):
			img.set_pixel(x, zy, col_white)
			img.set_pixel(x, zy + 5, col_white)
		for i in range(5):
			img.set_pixel(zx + 4 - i, zy + i + 1, col_white)
	return _cache_texture(_ck, ImageTexture.create_from_image(img))

func _generate_fortify_marker_texture() -> Texture2D:
	var _ck: String = "fortify_marker"
	if _tex_cache.has(_ck):
		return _tex_cache[_ck]
	# STEP-04R9 §18: Fortify marker — RIGHT side, 32x32 high-density warm defensive medallion
	var sz: int = 32
	var img: Image = Image.create(sz, sz, false, Image.FORMAT_RGBA8)
	var cx: float = 16.0
	var cy: float = 16.0
	var col_dark := Color(0.05, 0.05, 0.07, 1.0)
	var col_gold := Color(0.95, 0.80, 0.35, 1.0)
	var col_amber_top := Color(0.72, 0.52, 0.16, 1.0)
	var col_amber_bot := Color(0.38, 0.22, 0.06, 1.0)
	var col_shield := Color(1.0, 0.95, 0.80, 1.0)

	for y in range(sz):
		for x in range(sz):
			var dx: float = float(x) - cx + 0.5
			var dy: float = float(y) - cy + 0.5
			var d: float = sqrt(dx * dx + dy * dy)
			if d <= 14.5 and d > 13.5:
				img.set_pixel(x, y, col_dark)
			elif d <= 13.5 and d > 11.5:
				var is_stud: bool = (int(round(d * 4.0)) % 3 == 0)
				img.set_pixel(x, y, col_gold.lightened(0.20) if is_stud else col_gold)
			elif d <= 11.5:
				var t: float = float(y - 5) / 22.0
				img.set_pixel(x, y, col_amber_top.lerp(col_amber_bot, clampf(t, 0.0, 1.0)))

	# Battlements / crenellations
	for x in range(11, 21):
		img.set_pixel(x, 10, col_dark)
	for cx_bar in [11, 12, 15, 16, 19, 20]:
		img.set_pixel(cx_bar, 9, col_shield)
		img.set_pixel(cx_bar, 10, col_shield)
	# Tower body
	for y in range(11, 18):
		for x in range(11, 21):
			if x == 11 or x == 20:
				img.set_pixel(x, y, col_shield.darkened(0.15))
			else:
				img.set_pixel(x, y, col_shield)
	# Cross embrasure
	for y in range(13, 16):
		img.set_pixel(15, y, col_dark)
		img.set_pixel(16, y, col_dark)
	for x in range(13, 19):
		img.set_pixel(x, 14, col_dark)
	# Pointed base
	for i in range(5):
		var w: int = 4 - i
		for x in range(15 - w, 16 + w + 1):
			img.set_pixel(x, 18 + i, col_shield if (x > 15 - w and x < 16 + w) else col_shield.darkened(0.20))
	return _cache_texture(_ck, ImageTexture.create_from_image(img))

func set_unit_resting(id: String, resting: bool) -> void:
	# STEP-04R9 §16: LEFT side REST marker [REST ICON] UNIT [FORTIFY ICON]
	if _badge_nodes.has(id):
		var badge: Node2D = _badge_nodes[id] as Node2D
		if is_instance_valid(badge):
			var icon: Sprite2D = badge.get_node_or_null("RestIcon") as Sprite2D
			if resting:
				if icon == null:
					icon = Sprite2D.new()
					icon.name = "RestIcon"
					icon.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
					icon.position = Vector2(-16, 0) # LEFT flank of badge
					icon.z_index = 32
					badge.add_child(icon)
				icon.texture = _generate_rest_marker_texture()
				var scl: float = clampf(MARKER_BASE_PX / (24.0 * maxf(_current_zoom, 0.6)), MARKER_MIN_SCALE, MARKER_MAX_SCALE)
				icon.scale = Vector2(scl, scl)
				icon.visible = true
			else:
				if icon != null:
					icon.visible = false

func is_unit_resting(id: String) -> bool:
	if _badge_nodes.has(id):
		var badge: Node2D = _badge_nodes[id] as Node2D
		if is_instance_valid(badge):
			var icon: CanvasItem = badge.get_node_or_null("RestIcon") as CanvasItem
			if icon and icon.visible:
				return true
	return false

func set_unit_fortified(id: String, fortified: bool) -> void:
	if _badge_nodes.has(id):
		var badge: Node2D = _badge_nodes[id] as Node2D
		if is_instance_valid(badge):
			var icon: Sprite2D = badge.get_node_or_null("FortifiedIcon") as Sprite2D
			if fortified:
				if icon == null:
					icon = Sprite2D.new()
					icon.name = "FortifiedIcon"
					icon.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
					icon.position = Vector2(16, 0) # RIGHT flank of badge
					icon.z_index = 32
					badge.add_child(icon)
				icon.texture = _generate_fortify_marker_texture()
				var scl2: float = clampf(MARKER_BASE_PX / (24.0 * maxf(_current_zoom, 0.6)), MARKER_MIN_SCALE, MARKER_MAX_SCALE)
				icon.scale = Vector2(scl2, scl2)
				icon.visible = true
			else:
				if icon != null:
					icon.visible = false

func is_unit_fortified(id: String) -> bool:
	if _badge_nodes.has(id):
		var badge: Node2D = _badge_nodes[id] as Node2D
		if is_instance_valid(badge):
			var icon: CanvasItem = badge.get_node_or_null("FortifiedIcon") as CanvasItem
			if icon and icon.visible:
				return true
	return false

# ------------------------------------------------------------------
# STEP-06 markers: HQ gold banner, routed red alarm, convoy sack.
# TOP slot (0,-15); kinds are mutually exclusive by game logic.
# ------------------------------------------------------------------
func _s6_marker_scale() -> Vector2:
	var scl: float = clampf(MARKER_BASE_PX / (24.0 * maxf(_current_zoom, 0.6)), MARKER_MIN_SCALE, MARKER_MAX_SCALE)
	return Vector2(scl, scl)

func _s6_set_icon(id: String, node_name: String, tex: Texture2D, on: bool) -> void:
	if not _badge_nodes.has(id):
		return
	var badge: Node2D = _badge_nodes[id] as Node2D
	if not is_instance_valid(badge):
		return
	var icon: Sprite2D = badge.get_node_or_null(node_name) as Sprite2D
	if on:
		if icon == null:
			icon = Sprite2D.new()
			icon.name = node_name
			icon.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
			icon.position = Vector2(0, -15)
			icon.z_index = 33
			badge.add_child(icon)
		icon.texture = tex
		icon.scale = _s6_marker_scale()
		icon.visible = true
	elif icon != null:
		icon.visible = false

func _s6_ring_image(base: Color, ring: Color) -> Image:
	var sz: int = 32
	var img: Image = Image.create(sz, sz, false, Image.FORMAT_RGBA8)
	var cx: float = sz / 2.0
	var cy: float = sz / 2.0
	var col_dark := Color(0.04, 0.05, 0.07, 1.0)
	for y in range(sz):
		for x in range(sz):
			var dx: float = float(x) - cx + 0.5
			var dy: float = float(y) - cy + 0.5
			var d: float = sqrt(dx * dx + dy * dy)
			if d <= 14.5 and d > 13.5:
				img.set_pixel(x, y, col_dark)
			elif d <= 13.5 and d > 11.0:
				img.set_pixel(x, y, ring)
			elif d <= 11.0:
				var t: float = float(y - 5) / 22.0
				img.set_pixel(x, y, base.lightened(0.12 * (1.0 - clampf(t, 0.0, 1.0))))
	return img

func _generate_hq_marker_texture() -> Texture2D:
	var _ck: String = "hq_marker"
	if _tex_cache.has(_ck):
		return _tex_cache[_ck]
	var img: Image = _s6_ring_image(Color(0.85, 0.68, 0.15, 1.0), Color(1.0, 0.92, 0.55, 1.0))
	var sc: Color = Color(1.0, 0.98, 0.85, 1.0)
	var dark := Color(0.15, 0.10, 0.02, 1.0)
	for y in range(8, 24):
		var w: int = 7 - absi(y - 16)
		for x in range(16 - w, 16 + w + 1):
			if x == 16 - w or x == 16 + w or y == 8 or y == 23:
				img.set_pixel(x, y, dark)
			else:
				img.set_pixel(x, y, sc)
	return _cache_texture(_ck, ImageTexture.create_from_image(img))

func _generate_routed_marker_texture() -> Texture2D:
	var _ck: String = "routed_marker"
	if _tex_cache.has(_ck):
		return _tex_cache[_ck]
	var img: Image = _s6_ring_image(Color(0.75, 0.12, 0.10, 1.0), Color(1.0, 0.55, 0.50, 1.0))
	var sc: Color = Color(1.0, 1.0, 1.0, 1.0)
	var dark := Color(0.20, 0.02, 0.02, 1.0)
	for y in range(8, 19):
		for x in range(14, 18):
			img.set_pixel(x, y, dark if (x == 14 or x == 17) else sc)
	for y in range(20, 24):
		for x in range(14, 18):
			img.set_pixel(x, y, dark if (x == 14 or x == 17) else sc)
	return _cache_texture(_ck, ImageTexture.create_from_image(img))

func _generate_convoy_marker_texture() -> Texture2D:
	var _ck: String = "convoy_marker"
	if _tex_cache.has(_ck):
		return _tex_cache[_ck]
	var img: Image = _s6_ring_image(Color(0.55, 0.38, 0.16, 1.0), Color(1.0, 0.85, 0.55, 1.0))
	var sack: Color = Color(0.96, 0.88, 0.60, 1.0)
	var dark := Color(0.18, 0.12, 0.04, 1.0)
	for y in range(13, 24):
		for x in range(11, 22):
			if y == 13 or y == 23 or x == 11 or x == 21:
				img.set_pixel(x, y, dark)
			else:
				img.set_pixel(x, y, sack)
	for x in range(13, 20):
		img.set_pixel(x, 11, sack)
		img.set_pixel(x, 12, dark)
	return _cache_texture(_ck, ImageTexture.create_from_image(img))

func set_unit_hq(id: String, on: bool) -> void:
	_s6_set_icon(id, "HqIcon", _generate_hq_marker_texture(), on)

func set_unit_routed(id: String, on: bool) -> void:
	_s6_set_icon(id, "RoutedIcon", _generate_routed_marker_texture(), on)

func set_unit_convoy(id: String, on: bool) -> void:
	_s6_set_icon(id, "ConvoyIcon", _generate_convoy_marker_texture(), on)

func animate_unit_move(id: String, path_coords: Array[Vector2i], sec_per_hex: float = 0.12, on_complete: Callable = Callable()) -> void:
	if not _unit_nodes.has(id) or path_coords.size() < 2:
		if on_complete.is_valid():
			on_complete.call()
		return
	
	var container: Node2D = _unit_nodes[id] as Node2D
	if not is_instance_valid(container):
		if on_complete.is_valid():
			on_complete.call()
		return
	
	# Slightly accelerate long routes (Section 26)
	var step_time: float = sec_per_hex
	if path_coords.size() > 8:
		step_time = maxf(0.06, sec_per_hex * 0.75)
	
	# DRIFT-FIX: one owned motion tween per container. Killing any in-flight
	# attack/hit motion tween here is collision-safe: a step starting from an
	# interrupted offset simply converges onto the path's step positions, and
	# the shell's post-move update_unit_position snap is authoritative anyway.
	_kill_motion_tween(container)
	var tw: Tween = create_tween()
	tw.set_trans(Tween.TRANS_SINE)
	tw.set_ease(Tween.EASE_IN_OUT)
	
	for i in range(1, path_coords.size()):
		var target_c: Vector2i = path_coords[i]
		var target_pos: Vector2 = HexUtilsCls.hex_to_pixel(target_c.x, target_c.y)
		var target_z: int = calculate_unit_z(target_c.y, target_c.x)
		tw.tween_property(container, "position", target_pos, step_time)
		tw.tween_callback(func():
			if is_instance_valid(container):
				container.z_index = target_z
				container.set_meta("q", target_c.x)
				container.set_meta("r", target_c.y)
		)
	
	var dest: Vector2i = path_coords[path_coords.size() - 1]
	tw.tween_callback(func():
		update_unit_position(id, dest.x, dest.y)
		if on_complete.is_valid():
			on_complete.call()
	)

# ------------------------------------------------------------------
# Combat Visuals & Health Updates (Section 34, 45, 46)
# ------------------------------------------------------------------
func update_unit_health(id: String, current_count: int, max_count: int = -1) -> void:
	var is_blue: bool = true
	for u in _units:
		if str(u["id"]) == id:
			u["soldier_count"] = current_count
			if max_count > 0:
				u["max_count"] = max_count
			else:
				max_count = int(u.get("max_count", current_count))
			is_blue = (str(u.get("faction", "blue")) == "blue")
			break
	
	if _unit_nodes.has(id):
		var node: Node2D = _unit_nodes[id] as Node2D
		if is_instance_valid(node):
			# STEP-05R2: Only blue friendly units write exact soldier count directly.
			# Red enemy count labels are strictly controlled by set_enemy_observation_display.
			if is_blue:
				var count_lbl: Label = node.get_node_or_null("CountLabel") as Label
				if count_lbl:
					count_lbl.text = _format_soldier_count(current_count)
			
			var hp_bar: Sprite2D = node.get_node_or_null("HPBar") as Sprite2D
			if hp_bar:
				var m_cnt: int = max_count if max_count > 0 else 100
				var ratio: float = clampf(float(current_count) / float(maxi(1, m_cnt)), 0.0, 1.0)
				hp_bar.texture = _generate_hp_texture(ratio, is_blue)

# STEP-05R2 §19-§20/§24: enemy world-badge display shares ONE observation record
# with the intel panel. NEVER writes exact truth into the badge:
# - combat-assessed + visible => compact approx ("~400") + remaining-strength bar
# - otherwise => "?" with bar hidden (class stays on the badge icon itself).
func set_enemy_observation_display(id: String, badge_text: String, health_ratio: float) -> void:
	if not _unit_nodes.has(id):
		return
	var node: Node2D = _unit_nodes[id] as Node2D
	if not is_instance_valid(node):
		return
	var count_lbl: Label = node.get_node_or_null("CountLabel") as Label
	if count_lbl:
		count_lbl.text = badge_text
	var hp_bar: Sprite2D = node.get_node_or_null("HPBar") as Sprite2D
	if hp_bar:
		if health_ratio >= 0.0:
			hp_bar.visible = true
			hp_bar.texture = _generate_hp_texture(clampf(health_ratio, 0.0, 1.0), false)
		else:
			hp_bar.visible = false

# ------------------------------------------------------------------
# DRIFT-FIX: canonical presentation helpers.
#
# Attack/hit presentation must never move the unit container AWAY from the
# world position implied by its CURRENT authoritative hex — neither
# permanently (cumulative drift) nor as the origin for the next animation.
#
# Two rules:
#   1. Canonical capture: the lunge origin/destination is captured from the
#      truth hex (container meta q/r), NEVER from the current animated
#      "position", which may be mid-lunge when a hit/combo arrives.
#   2. One tween owns a node's motion: starting a new motion tween kills any
#      in-flight motion tween first, and every motion tween ends with an
#      ABSOLUTE restore to its captured canonical position (never -delta
#      arithmetic), so an interrupted tween can never leave a partial offset
#      behind. Non-motion tweens (modulate/flash) are unaffected.
# ------------------------------------------------------------------
const _MOTION_META := "drift_motion_tween"

static func _kill_motion_tween(node: Node2D) -> void:
	# NOTE: Godot 4.2 get_meta(key, default) ERR_FAILs (console noise) when the
	# key is absent even with a default, so has_meta is checked first.
	if not node.has_meta(_MOTION_META):
		return
	var prev: Tween = node.get_meta(_MOTION_META) as Tween
	if prev != null and prev.is_valid():
		prev.kill()
	node.remove_meta(_MOTION_META)

## Absolute canonical world position of a unit right now: derived from the
## CURRENT authoritative hex stored on the container (set by spawn_unit /
## update_unit_position / move callbacks), never from the animated position.
func _canonical_unit_pos(id: String) -> Vector2:
	var node: Node2D = _unit_nodes.get(id, null) as Node2D
	if node == null or not is_instance_valid(node):
		return Vector2.ZERO
	var q: int = int(node.get_meta("q", 0))
	var r: int = int(node.get_meta("r", 0))
	return HexUtilsCls.hex_to_pixel(q, r)

## One owned motion tween per node; kills any previous motion tween on the
## node (interruption-safe). Restoration itself is done by the caller's
## ABSOLUTE position steps + final callback (never -delta arithmetic), so an
## interrupted tween can never leave a partial offset behind.
func _new_motion_tween(node: Node2D) -> Tween:
	_kill_motion_tween(node)
	var tw: Tween = create_tween()
	node.set_meta(_MOTION_META, tw)
	return tw

func animate_unit_attack(id: String, target_coord: Vector2i, on_complete: Callable = Callable()) -> void:
	if not _unit_nodes.has(id):
		if on_complete.is_valid():
			on_complete.call()
		return
	
	var node: Node2D = _unit_nodes[id] as Node2D
	if not is_instance_valid(node):
		if on_complete.is_valid():
			on_complete.call()
		return
	
	# DRIFT-FIX: origin captured from the CURRENT truth hex, not from the
	# possibly-mid-animation "position". A stationary attack always animates
	# away from and back to the canonical hex; an attack fired while a previous
	# lunge is airborne chains after an absolute canonical restore.
	var orig_pos: Vector2 = _canonical_unit_pos(id)
	var target_pos: Vector2 = HexUtilsCls.hex_to_pixel(target_coord.x, target_coord.y)
	var dir: Vector2 = (target_pos - orig_pos).normalized() * 12.0
	
	var tw: Tween = _new_motion_tween(node)
	tw.tween_property(node, "position", orig_pos + dir, 0.09).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_property(node, "position", orig_pos, 0.11).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.tween_callback(func():
		if is_instance_valid(node):
			node.position = orig_pos   # absolute canonical restore (DRIFT-FIX)
			if node.has_meta(_MOTION_META):
				node.remove_meta(_MOTION_META)
		if on_complete.is_valid():
			on_complete.call()
	)

func animate_unit_hit(id: String, casualties: int, on_complete: Callable = Callable()) -> void:
	if not _unit_nodes.has(id):
		if on_complete.is_valid():
			on_complete.call()
		return
	
	var node: Node2D = _unit_nodes[id] as Node2D
	if not is_instance_valid(node):
		if on_complete.is_valid():
			on_complete.call()
		return
	
	# DRIFT-FIX: the shell plays defender/retaliation hit feedback ~0.12s into
	# the 0.20s attack lunge on the SAME container. Previously this captured
	# orig_pos = node.position MID-LUNGE, killed nothing, and ended the shake
	# there — permanently parking the unit off-hex and making the next attack
	# lunge from the offset origin (cumulative drift). Now the hit shake owns
	# the motion: it pre-empts the lunge tween and shakes around the CURRENT
	# truth hex's canonical position, ending there absolutely. No intermediate
	# animated offset can ever survive the hit.
	var orig_pos: Vector2 = _canonical_unit_pos(id)
	var tw: Tween = _new_motion_tween(node)
	
	# Flash white/red
	tw.tween_property(node, "modulate", Color(1.8, 0.4, 0.4, 1.0), 0.06)
	tw.tween_property(node, "position", orig_pos + Vector2(3, 0), 0.04)
	tw.tween_property(node, "position", orig_pos + Vector2(-3, 0), 0.04)
	tw.tween_property(node, "position", orig_pos, 0.04)
	tw.tween_property(node, "modulate", Color(1.0, 1.0, 1.0, 1.0), 0.08)
	tw.tween_callback(func():
		if is_instance_valid(node):
			node.position = orig_pos   # absolute restore (DRIFT-FIX)
			if node.has_meta(_MOTION_META):
				node.remove_meta(_MOTION_META)
		if on_complete.is_valid():
			on_complete.call()
	)

func remove_unit(id: String) -> void:
	if _unit_nodes.has(id):
		var node: Node2D = _unit_nodes[id] as Node2D
		if is_instance_valid(node):
			var tw: Tween = create_tween()
			tw.tween_property(node, "modulate:a", 0.0, 0.25)
			tw.tween_property(node, "scale", Vector2(0.5, 0.5), 0.25)
			tw.tween_callback(func():
				if is_instance_valid(node):
					node.queue_free()
			)
		_unit_nodes.erase(id)
	
	if _badge_nodes.has(id):
		_badge_nodes.erase(id)
	
	if _formation_nodes.has(id):
		_formation_nodes.erase(id)
	
	for i in range(_units.size() - 1, -1, -1):
		if str(_units[i]["id"]) == id:
			_units.remove_at(i)
			break
	
	if _hovered_unit_id == id:
		_hovered_unit_id = ""

func spawn_floating_text(coord: Vector2i, text: String, color: Color) -> void:
	var world_pos: Vector2 = HexUtilsCls.hex_to_pixel(coord.x, coord.y)
	var lbl: Label = Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", 14)
	lbl.pivot_offset = Vector2(36, 7)
	var st_ft: float = PresentationOrientationCls.stretch_at_world(world_pos)
	lbl.scale = Vector2(1.0, st_ft) * SemanticZoomCls.float_text_scale(_current_zoom, 14.0)
	lbl.add_theme_color_override("font_color", color)
	lbl.modulate = Color(1, 1, 1, 0.82) # floating combat text: present, not dominant
	lbl.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.95))
	lbl.add_theme_constant_override("shadow_offset_x", 1)
	lbl.add_theme_constant_override("shadow_offset_y", 1)
	lbl.add_theme_constant_override("outline_size", 2)
	lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	# Upright under a rotated presentation (DEV sandbox); yaw 0 -> original values.
	# Pivot (label center) lands 27 screen-px above the hex center. The offset
	# is a SCREEN offset, so only it (not world_pos) is re-expressed in world.
	lbl.position = world_pos + PresentationOrientationCls.upright_vector(Vector2(0, -27), st_ft) - lbl.pivot_offset
	lbl.rotation = PresentationOrientationCls.upright_rotation()
	lbl.z_index = 80
	add_child(lbl)
	
	var tw: Tween = create_tween().set_parallel(true)
	# Drift is authored in SCREEN space so the float still rises on screen.
	var drift: Vector2 = PresentationOrientationCls.upright_vector(Vector2(0.0, -28.0), st_ft)
	tw.tween_property(lbl, "position", lbl.position + drift, 0.85).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tw.tween_property(lbl, "modulate:a", 0.0, 0.85).set_delay(0.35)
	tw.chain().tween_callback(func():
		if is_instance_valid(lbl):
			lbl.queue_free()
	)

func set_supply_label_visible(id: String, on: bool) -> void:
	if _unit_nodes.has(id):
		var node: Node2D = _unit_nodes[id] as Node2D
		if is_instance_valid(node):
			var lbl: Label = node.get_node_or_null("SupplyLabel") as Label
			if lbl:
				lbl.visible = on

func set_unit_deemphasized(id: String, deemphasized: bool) -> void:
	_deemphasized_units[id] = deemphasized
	_update_unit_visual_state(id)

# STEP-06R3 §7-§8: Unit Overhead Information Switch
# In Battle Mode: show soldier strength (e.g. 420, 580); supply units compact (no large text).
# In Logistics Mode: replace troop-number display with remaining supply days (e.g. 5.0일, 2.1일, 0.0일) with urgency color.
func set_overhead_display_mode(mode: int, unit_manager: RefCounted, step6: RefCounted, cell_data: Dictionary = {}, stronghold_cells: Dictionary = {}) -> void:
	_display_mode = mode
	for u in _units:
		var uid: String = str(u.get("id", ""))
		var node: Node2D = _unit_nodes.get(uid, null) as Node2D
		if node == null or not is_instance_valid(node):
			continue
		var count_lbl: Label = node.get_node_or_null("CountLabel") as Label
		if count_lbl == null:
			continue
			
		var is_blue: bool = (str(u.get("faction", "blue")) == "blue")
		var cls: String = str(u.get("class", ""))
		
		# Fetch fresh data from unit_manager if available
		var u_fresh: Dictionary = u
		if unit_manager != null and unit_manager.has_method("get_unit_by_id"):
			var uf: Dictionary = unit_manager.get_unit_by_id(uid)
			if not uf.is_empty():
				u_fresh = uf
				
		if mode == S6.MAP_MODE_BATTLE:
			# BATTLE MODE: troop counts prominent, logistics minimized
			if is_blue:
				if cls == "supply":
					count_lbl.text = ""
					set_supply_label_visible(uid, false)
				else:
					count_lbl.text = _format_soldier_count(int(u_fresh.get("soldier_count", 0)))
					count_lbl.add_theme_font_size_override("font_size", 10)
					count_lbl.add_theme_color_override("font_color", Color(1, 1, 1, 1))
					count_lbl.add_theme_constant_override("outline_size", 3)
					count_lbl.add_theme_color_override("font_outline_color", Color(0.10, 0.08, 0.05, 0.85))
			set_unit_deemphasized(uid, false)
		else:
			# LOGISTICS MODE: supply days & urgency, combat units muted
			if is_blue:
				if cls == "supply":
					var cargo: float = 400.0
					if step6 != null and step6.has_method("convoy_info"):
						var ci: Dictionary = step6.convoy_info(uid)
						cargo = float(ci.get("cargo", float(u_fresh.get("convoy_cargo", 400.0))))
					count_lbl.text = "🌾 %.0f" % cargo
					count_lbl.add_theme_font_size_override("font_size", 13)
					count_lbl.add_theme_color_override("font_color", Color(1.0, 0.90, 0.40, 1.0))
					count_lbl.add_theme_constant_override("outline_size", 3)
					count_lbl.add_theme_color_override("font_outline_color", Color(0.15, 0.10, 0.02, 1.0))
					set_unit_deemphasized(uid, false)
				elif cls == "hq":
					count_lbl.text = "👑 본영"
					count_lbl.add_theme_font_size_override("font_size", 13)
					count_lbl.add_theme_color_override("font_color", Color(1.0, 0.95, 0.45, 1.0))
					count_lbl.add_theme_constant_override("outline_size", 3)
					count_lbl.add_theme_color_override("font_outline_color", Color(0.18, 0.12, 0.02, 1.0))
					set_unit_deemphasized(uid, false)
				else:
					var troops: int = int(u_fresh.get("soldier_count", 0))
					var maxt: int = maxi(1, int(u_fresh.get("max_count", troops)))
					var local_food: float = float(u_fresh.get("local_supply", 0.0))
					var turns: float = S6.buffer_turns(local_food, maxt)
					if step6 != null and step6.has_method("is_unit_secure"):
						if step6.is_unit_secure(u_fresh, cell_data, stronghold_cells):
							turns = maxf(turns, S6.LOCAL_SUPPLY_TURNS)
					count_lbl.text = "%.1f일" % turns
					count_lbl.add_theme_font_size_override("font_size", 13)
					count_lbl.add_theme_color_override("font_color", S6.supply_days_color(turns))
					count_lbl.add_theme_constant_override("outline_size", 3)
					count_lbl.add_theme_color_override("font_outline_color", Color(0.10, 0.08, 0.05, 0.85))
					set_unit_deemphasized(uid, true)
