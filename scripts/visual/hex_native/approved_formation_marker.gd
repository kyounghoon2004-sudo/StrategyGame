extends "res://scripts/visual/step2r_formation_marker.gd"

## Preserve status API and selection behavior; replace all legacy formation art.
const Registry = preload("res://scripts/visual/hex_native/approved_asset_registry.gd")
const FormationSpriteCompositor = preload("res://scripts/visual/hex_native/formation_sprite_compositor.gd")
const SemanticZoomCls = preload("res://scripts/step2r/semantic_zoom.gd")
const PresentationOrientationCls = preload("res://scripts/core/presentation_orientation.gd")
var approved_resource: String = ""
var _content_rect: Rect2
var _stakes: Texture2D
var _semantic_scale: float = 1.0
## Presentation multiplier (perspective view draws formations a little
## smaller so the body stays inside its own hex). 1.0 = unchanged.
var presentation_scale: float = 1.0

## Static art: selection / hover redraw on state change (update_status), never
## per frame. The legacy base class pulsed every frame for a glow this
## approved art does not draw, so per-frame processing stays off.
func _ready() -> void:
	super._ready()
	set_process(false)

func set_presentation_scale(p: float) -> void:
	presentation_scale = p
	scale = Vector2(_semantic_scale, _semantic_scale) * presentation_scale

func setup(p_class: String, p_faction: String, p_count: int, p_zoom: float = 1.15) -> void:
	super.setup(p_class, p_faction, p_count, p_zoom)
	set_camera_zoom(p_zoom)

## Semantic zoom (§8): partial compensation only. The node no longer inherits
## raw camera zoom (which ballooned soldiers at close view); instead it eases
## 0.82 macro → 0.92 strategic → 1.00 tactical → ~0.92 close. Epsilon-gated.
func set_camera_zoom(zoom_val: float) -> void:
	var cz: float = clampf(zoom_val, 0.25, 8.0)
	var s: float = SemanticZoomCls.formation_mult_for_zoom(cz)
	if is_equal_approx(current_zoom, cz) and is_equal_approx(_semantic_scale, s):
		return
	current_zoom = cz
	_semantic_scale = s
	scale = Vector2(s, s) * presentation_scale
	queue_redraw()

# Hex-proportioned unit presentation (director-approved visual tuning).
# Body-referenced fill: the art's dense soldier cluster (Registry.body —
# banners/spears excluded) fills the hex cell: body head at the hex top edge
# (-21), body feet on the hex bottom edge (+21). Banners/spears rise above
# the hex naturally. Body width clamped to the hex's bottom-edge taper.
const UNIT_GROUND_Y := 21.0
const UNIT_BODY_HEIGHT := 42.0
const UNIT_BODY_MAX_WIDTH := 32.0

func _update_textures() -> void:
	approved_resource = Registry.unit(unit_class, faction)
	# HEADLESS (training / audits): nothing is ever drawn, so the 1024 px
	# formation art is not loaded. Layout metadata below comes from JSON.
	var headless: bool = PresentationOrientationCls.is_headless()
	var art_bounds: Rect2 = Registry.bounds(approved_resource)
	var body: Rect2 = Registry.body(approved_resource)
	if headless:
		_tex_formation = null
	elif unit_class == "hq" or unit_class == "supply":
		_tex_formation = Registry.cropped(approved_resource)
	else:
		var formation: Dictionary = FormationSpriteCompositor.compose(approved_resource)
		_tex_formation = formation.get("texture") as Texture2D
		art_bounds = formation.get("bounds", art_bounds)
		body = formation.get("body", body)
	_tex_banner = null # Faction banners are already in the approved render.
	var factor: float = UNIT_BODY_HEIGHT / body.size.y
	if body.size.x * factor > UNIT_BODY_MAX_WIDTH:
		factor = UNIT_BODY_MAX_WIDTH / body.size.x
	var size: Vector2 = art_bounds.size * factor
	# Body feet land on UNIT_GROUND_Y; offset -x centers the BODY (not the
	# bounds box), keeping overhanging banners balanced over the soldier.
	var body_center_x: float = (body.position.x + body.end.x) * 0.5 - art_bounds.position.x
	# Draw-rect top such that texture-space body.end.y maps to UNIT_GROUND_Y:
	# pos.y + (body.end.y - bounds.position.y) * factor == UNIT_GROUND_Y.
	_content_rect = Rect2(Vector2(-body_center_x * factor, UNIT_GROUND_Y - (body.end.y - art_bounds.position.y) * factor), size)
	_stakes = null if headless else Registry.cropped(Registry.path_for("fort", "defensive_stakes_A"))

func _draw() -> void:
	if _tex_formation == null:
		return
	var alpha: float = 0.45 if is_routed else (0.60 if is_dimmed else 1.0)
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	draw_texture_rect(_tex_formation, _content_rect, false, Color(1,1,1,alpha))
	if is_fortified and not is_routed and _stakes != null:
		draw_texture_rect(_stakes, Rect2(-12,6,24,6), false)
	if is_selected or is_hovered:
		draw_arc(Vector2(0,6), 11.0, 0.0, TAU, 24, Color(1,0.86,0.42,0.75), 0.8, true)
