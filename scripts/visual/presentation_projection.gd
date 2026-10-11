class_name PresentationProjection
extends Node

## PresentationProjection — VISUAL ONLY zoom-driven battlefield camera.
##
## The 2D battlefield is still simulated, laid out and hit-tested exactly as a
## flat board. This node renders that same World2D canvas into an offscreen
## SubViewport and re-projects it onto a pitched ground plane (pinhole camera),
## drawn on a CanvasLayer that sits between the world and the HUD.
##
## DYNAMIC VIEW: one continuous blend value `e` is derived from the camera
## zoom every frame —  e = 0  commander view (near top-down, ~orthographic),
## e ~ 0.7  tactical view, e = 1  battlefield view (low pitch, strong depth,
## horizon). Pitch, field of view, lens shift, far horizon band, haze, sun,
## upright compensation and unit presentation are all smooth functions of e,
## so zooming is one continuous camera move, never a switch.
##
## Coordinates:
##   world  — battlefield world pixels (hex_to_pixel space, unchanged)
##   board  — the flat top-down screen the Camera2D produces, centered on the
##            screen middle (board = main_canvas_xform * world - screen_center)
##   screen — final projected pixels (centered), y down
##
## screen_to_world() is the exact inverse of the CURRENT frame's projection,
## so a click always resolves to the hex drawn under the cursor at any zoom.

const ShaderRes = preload("res://scripts/visual/shaders/presentation_projection.gdshader")
const DressingCls = preload("res://scripts/visual/hex_native/hex_dressing_compositor.gd")
const PresentationOrientationCls = preload("res://scripts/core/presentation_orientation.gd")

# ---- View curve (zoom -> e) -------------------------------------------------
## Zoom at/below which the view is the commander (near top-down) view.
const ZOOM_COMMANDER: float = 0.50
## Zoom at/above which the view is the full battlefield view.
const ZOOM_BATTLEFIELD: float = 3.00

# ---- Parameter ranges (commander -> battlefield) ----------------------------
const PITCH_FAR: float = 88.0
const PITCH_NEAR: float = 17.0
## Vertical half field of view (deg): ~orthographic far, wide near.
const HFOV_FAR: float = 5.0
const HFOV_NEAR: float = 38.0
## Lens shift (screen px, +down) puts the board focus below screen center so
## the field ahead and the far horizon band fit on screen at low pitch.
const SHIFT_NEAR: float = 10.0
## Height (px) of the far scenery band at the top of the screen (<0 = none).
const BAND_FAR: float = -120.0
const BAND_NEAR: float = 200.0
const HAZE_NEAR: float = 0.40
## Units keep this share of their exact upright height at low pitch so a
## formation stands about one hex row tall (1 unit = 1 hex); 1.0 top-down.
const UNIT_KEEP_NEAR: float = 1.0
## Static upright art (peaks, buildings) is pre-stretched for this ground
## magnification; top-down it is exactly 1.
const NOMINAL_T_NEAR: float = 0.80

## Two-tier offscreen render. NEAR holds the foreground at full
## supersampling; FAR holds distant ground (minified on screen anyway) at low
## resolution, so the ground can run almost to the horizon at close zoom
## without blurring the troops. Split where ground magnification t < T_SPLIT.
const SS_TARGET: float = 1.35
const SS_MAX: float = 1.8
const MAX_TARGET: Vector2i = Vector2i(6400, 4096)
const T_SPLIT: float = 0.62
const SS_FAR: float = 0.32
const FAR_TARGET: Vector2i = Vector2i(4608, 2048)
const SPLIT_OVERLAP: float = 90.0
const PAD: float = 48.0
const STRETCH_MAX: float = 14.0
const TREE_PRESENCE: float = 1.45
const UNIT_PRESENCE: float = 1.25

var _vp: Viewport = null
var _sub: SubViewport = null
var _sub_far: SubViewport = null
var _layer: CanvasLayer = null
var _rect: TextureRect = null
var _mat: ShaderMaterial = null
var _screen: Vector2 = Vector2(1920, 1080)

# Current view state (recomputed every frame from zoom).
var e: float = 0.7
var _sp: float = 0.7
var _cp: float = 0.7
var _focal: float = 1200.0
var _shift: float = 0.0
var _gy_min: float = -2400.0
var _src_origin: Vector2 = Vector2.ZERO # near window (board px)
var _src_size_board: Vector2 = Vector2.ONE
var _far_origin: Vector2 = Vector2.ZERO
var _far_size_board: Vector2 = Vector2.ONE
var _gy_split: float = -1.0e9
var _ss: float = SS_TARGET
var _ss_far: float = SS_FAR
var _last_zoom: float = -1.0
# Last view pushed to the upright-art materials (see _push_view_to_scene).
var _pushed_xf: Transform2D = Transform2D()
var _pushed_e: float = -1.0

func _init() -> void:
	name = "PresentationProjection"
	process_priority = 1000 # after the Camera2D has moved this frame

## Curved view blend: x is linear in log-zoom; e = 1 - (1 - x)^2 is nearly
## flat at the battlefield end (subtle angle change close in) and steepest
## toward the commander end (strong swing to top-down as you zoom out).
static func view_e_for_zoom(zoom: float) -> float:
	var a: float = log(ZOOM_COMMANDER)
	var b: float = log(ZOOM_BATTLEFIELD)
	var x: float = clampf((log(maxf(zoom, 0.01)) - a) / (b - a), 0.0, 1.0)
	return 1.0 - (1.0 - x) * (1.0 - x)

## Static nominal stretch used before the projection node exists (build time).
static func nominal_stretch_for_zoom(zoom: float) -> float:
	var ev: float = view_e_for_zoom(zoom)
	var pitch: float = lerpf(PITCH_FAR, PITCH_NEAR, ev)
	return 1.0 / (sin(deg_to_rad(pitch)) * lerpf(1.0, NOMINAL_T_NEAR, ev))

static func _ease(x: float) -> float:
	return pow(x, 0.8)

func setup(main_viewport: Viewport) -> void:
	_vp = main_viewport
	_screen = _vp.get_visible_rect().size
	_sub = SubViewport.new()
	_sub.name = "ProjectedWorld"
	_sub.world_2d = _vp.world_2d
	_sub.transparent_bg = true
	_sub.disable_3d = true
	_sub.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_sub.canvas_item_default_texture_filter = _vp.canvas_item_default_texture_filter
	_sub.size = _required_target_size()
	add_child(_sub)
	_sub_far = SubViewport.new()
	_sub_far.name = "ProjectedWorldFar"
	_sub_far.world_2d = _vp.world_2d
	_sub_far.transparent_bg = true
	_sub_far.disable_3d = true
	_sub_far.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_sub_far.canvas_item_default_texture_filter = Viewport.DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_LINEAR
	_sub_far.size = FAR_TARGET
	add_child(_sub_far)
	_layer = CanvasLayer.new()
	_layer.name = "ProjectedWorldLayer"
	_layer.layer = 1
	add_child(_layer)
	_rect = TextureRect.new()
	_rect.name = "ProjectedWorld"
	_rect.texture = _sub.get_texture()
	_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_rect.stretch_mode = TextureRect.STRETCH_SCALE
	_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_mat = ShaderMaterial.new()
	_mat.shader = ShaderRes
	_mat.set_shader_parameter("screen_size", _screen)
	_mat.set_shader_parameter("src_tex", _sub.get_texture())
	_mat.set_shader_parameter("far_tex", _sub_far.get_texture())
	_rect.material = _mat
	_layer.add_child(_rect)
	PresentationOrientationCls.set_upright_stretch(1.0, Callable(self, "stretch_at_world"))
	PresentationOrientationCls.frame_provider = Callable(self, "upright_frame_at_world")
	_sync(true)
	print("[Projection] dynamic view | offscreen %s px | commander<=%.2f battlefield>=%.2f" % [str(_sub.size), ZOOM_COMMANDER, ZOOM_BATTLEFIELD])

## Worst-case offscreen size over the whole zoom range at SS_TARGET (capped).
func _required_target_size() -> Vector2i:
	var need := Vector2.ZERO
	for i in range(11):
		_configure_e(float(i) / 10.0)
		need.x = maxf(need.x, _src_size_board.x)
		need.y = maxf(need.y, _src_size_board.y)
	need *= SS_TARGET
	return Vector2i(mini(ceili(need.x), MAX_TARGET.x), mini(ceili(need.y), MAX_TARGET.y))

## Set every view parameter for zoom (used for framing before the camera
## has reached that zoom, e.g. the friendly-HQ home view).
func configure_for_zoom(zoom: float) -> void:
	_configure_e(view_e_for_zoom(zoom))

func _configure_e(p_e: float) -> void:
	e = clampf(p_e, 0.0, 1.0)
	var k: float = e
	var pitch: float = lerpf(PITCH_FAR, PITCH_NEAR, k)
	_sp = sin(deg_to_rad(pitch))
	_cp = cos(deg_to_rad(pitch))
	_focal = (_screen.y * 0.5) / tan(deg_to_rad(lerpf(HFOV_FAR, HFOV_NEAR, k)))
	_shift = lerpf(0.0, SHIFT_NEAR, k)
	_compute_source_window()

## Board-space windows the projected screen can see: far cap (scenery band
## above it) -> split (far tier) -> bottom row (near tier).
func _compute_source_window() -> void:
	var half: Vector2 = _screen * 0.5
	_gy_min = -1.0e9
	var bottom: Dictionary = unproject_board(Vector2(0, half.y))
	var gy_bottom: float = float(bottom["g"].y)
	var band: float = lerpf(BAND_FAR, BAND_NEAR, smoothstep(0.2, 0.9, e))
	var cap: Dictionary = unproject_board(Vector2(0, -half.y + band))
	var gy_cap: float = float(cap["g"].y) if bool(cap["ok"]) else -_focal * 12.0
	# Far-tier budget: deepest ground the low-res target can hold.
	var fw: float = float(FAR_TARGET.x) / SS_FAR - 2.0 * PAD
	var fh: float = float(FAR_TARGET.y) / SS_FAR - 2.0 * PAD
	var t_min: float = clampf(_screen.x / fw, 0.02, 1.0)
	gy_cap = maxf(gy_cap, _gy_at_t(t_min))
	# Split: where ground magnification drops below T_SPLIT (never beyond the
	# near-tier budget). Shallow (top-down) views never need the far tier.
	var nw: float = float(MAX_TARGET.x) / SS_TARGET - 2.0 * PAD
	var nh: float = float(MAX_TARGET.y) / SS_TARGET - 2.0 * PAD
	var gy_split: float = maxf(_gy_at_t(maxf(T_SPLIT, _screen.x / nw)), gy_bottom - nh)
	if gy_split <= gy_cap:
		gy_split = gy_cap
	else:
		gy_cap = maxf(gy_cap, gy_split - fh + SPLIT_OVERLAP)
	_gy_min = gy_cap
	_gy_split = gy_split
	var near_top: float = maxf(gy_cap, gy_split - SPLIT_OVERLAP)
	var hw_near: float = half.x / _t_of(near_top)
	_src_origin = Vector2(-hw_near - PAD, near_top - PAD)
	_src_size_board = Vector2(2.0 * (hw_near + PAD), (gy_bottom - near_top) + 2.0 * PAD)
	var hw_far: float = half.x / _t_of(gy_cap)
	_far_origin = Vector2(-hw_far - PAD, gy_cap - PAD)
	_far_size_board = Vector2(2.0 * (hw_far + PAD), (gy_split + SPLIT_OVERLAP - gy_cap) + 2.0 * PAD)

## Board depth (gy) at which ground magnification equals t.
func _gy_at_t(t: float) -> float:
	return _focal * (1.0 - 1.0 / t) / maxf(_cp, 0.0001)

func _t_of(gy: float) -> float:
	return _focal / (_focal - gy * _cp)

## board (centered) -> screen (centered)
func project_board(g: Vector2) -> Vector2:
	var t: float = _t_of(g.y)
	return Vector2(g.x * t, g.y * _sp * t + _shift)

## screen (centered) -> board (centered); ok=false above the far cap/horizon.
func unproject_board(s: Vector2) -> Dictionary:
	var syp: float = s.y - _shift
	var den: float = _focal * _sp + syp * _cp
	if den <= 1.0:
		return {"ok": false, "g": Vector2.ZERO}
	var gy: float = syp * _focal / den
	var t: float = _t_of(gy)
	var ok: bool = gy >= _gy_min - 0.5
	return {"ok": ok, "g": Vector2(s.x / t, gy)}

func horizon_screen_y() -> float:
	return -_focal * _sp / maxf(_cp, 0.0001) + _shift

func unit_keep() -> float:
	return lerpf(1.0, UNIT_KEEP_NEAR, e)

## Close-range physical presence: upright world art grows as the view
## flattens (subtle until the tactical view, full at the battlefield view),
## so the world acquires scale instead of reading as a zoomed flat board.
static func presence_for_e(ev: float, full: float) -> float:
	return lerpf(1.0, full, smoothstep(0.45, 1.0, ev))

func nominal_stretch() -> float:
	return 1.0 / (_sp * lerpf(1.0, NOMINAL_T_NEAR, e))

## Vertical pre-stretch that makes upright art at this world position read at
## its natural aspect after projection (1 / (sin(pitch) * local magnification)).
func stretch_at_world(world: Vector2) -> float:
	if _vp == null:
		return 1.0
	var g: Vector2 = _vp.get_canvas_transform() * world - _screen * 0.5
	var t: float = _t_of(maxf(g.y, _gy_min))
	return clampf(1.0 / (_sp * t), 1.0, STRETCH_MAX)

## (stretch, lean, boost) for live units: stretch keeps the unit about one hex
## row tall, lean cancels perspective convergence so art stands vertical
## anywhere on screen, boost enlarges far formations a little (<= 1.45x) so
## distant enemies stay legible. Their ground footprint is never boosted.
func upright_frame_at_world(world: Vector2) -> Vector3:
	if _vp == null:
		return Vector3(1.0, 0.0, 1.0)
	var g: Vector2 = _vp.get_canvas_transform() * world - _screen * 0.5
	var t: float = _t_of(maxf(g.y, _gy_min))
	# True perspective near-to-mid field (nearer = bigger). Only the very far
	# band (ground magnification < 0.32) gets a small legibility floor.
	var boost: float = clampf(pow(0.32 / t, 0.5), 1.0, 1.5)
	return Vector3(clampf(unit_keep() / (_sp * t), 1.0, STRETCH_MAX), g.x * _cp * t / _focal, boost)

## Zoom toward cursor: camera target (world) for `new_zoom` such that the
## ground point currently under `cursor` stays under it once the zoom has
## settled, solved with the projection parameters of the NEW zoom.
## board = zoom * R(-yaw) * (world - target)  =>  target = W - R(yaw) g / zoom.
func zoom_anchor_target(cursor: Vector2, new_zoom: float) -> Variant:
	var w: Variant = screen_to_world(cursor)
	if w == null:
		return null
	var cur_zoom: float = _vp.get_canvas_transform().x.length()
	configure_for_zoom(new_zoom)
	var r: Dictionary = unproject_board(cursor - _screen * 0.5)
	configure_for_zoom(cur_zoom) # restore live parameters
	if not bool(r["ok"]):
		return null
	var g: Vector2 = r["g"]
	return (w as Vector2) - g.rotated(PresentationOrientationCls.yaw_rad) / new_zoom

## Exact pointer inverse: real screen pixel -> battlefield world position.
## Returns null when the pixel shows sky / backdrop (no hex under it).
func screen_to_world(screen_pos: Vector2) -> Variant:
	if _vp == null:
		return null
	var r: Dictionary = unproject_board(screen_pos - _screen * 0.5)
	if not bool(r["ok"]):
		return null
	var board_px: Vector2 = (r["g"] as Vector2) + _screen * 0.5
	return _vp.get_canvas_transform().affine_inverse() * board_px

## World position -> real screen pixel (for overlays / tests).
func world_to_screen(world: Vector2) -> Vector2:
	var g: Vector2 = _vp.get_canvas_transform() * world - _screen * 0.5
	return project_board(g) + _screen * 0.5

## World-space AABB of everything the projected screen can show (culling).
func visible_world_rect() -> Rect2:
	var inv: Transform2D = _vp.get_canvas_transform().affine_inverse()
	var r := Rect2(_src_origin + _screen * 0.5, _src_size_board).merge(Rect2(_far_origin + _screen * 0.5, _far_size_board))
	return inv * r

func _process(_delta: float) -> void:
	_sync(false)

func _sync(force: bool) -> void:
	if _sub == null or _vp == null:
		return
	var xf: Transform2D = _vp.get_canvas_transform()
	var zoom: float = xf.x.length()
	if force or absf(zoom - _last_zoom) > 0.00001:
		_last_zoom = zoom
		_configure_e(view_e_for_zoom(zoom))
		var tgt := Vector2(_sub.size)
		_ss = minf(SS_MAX, minf(tgt.x / _src_size_board.x, tgt.y / _src_size_board.y))
		var ftg := Vector2(_sub_far.size)
		_ss_far = minf(SS_FAR * 1.25, minf(ftg.x / _far_size_board.x, ftg.y / _far_size_board.y))
		_push_projection_uniforms()
	# offscreen px = (board - origin) * ss, board = main - center
	var to_src := Transform2D(0.0, Vector2(_ss, _ss), 0.0, -(_src_origin + _screen * 0.5) * _ss)
	_sub.canvas_transform = to_src * xf
	var far_active: bool = _gy_split > _gy_min + 1.0
	_sub_far.render_target_update_mode = SubViewport.UPDATE_ALWAYS if far_active else SubViewport.UPDATE_DISABLED
	if far_active:
		var to_far := Transform2D(0.0, Vector2(_ss_far, _ss_far), 0.0, -(_far_origin + _screen * 0.5) * _ss_far)
		_sub_far.canvas_transform = to_far * xf
	# Upright-art uniforms only change with the view: idle frames push nothing.
	if force or absf(e - _pushed_e) > 0.00001 or not xf.is_equal_approx(_pushed_xf):
		_pushed_xf = xf
		_pushed_e = e
		_push_view_to_scene(xf)

func _push_projection_uniforms() -> void:
	_mat.set_shader_parameter("pitch_sin", _sp)
	_mat.set_shader_parameter("pitch_cos", _cp)
	_mat.set_shader_parameter("focal", _focal)
	_mat.set_shader_parameter("lens_shift", _shift)
	_mat.set_shader_parameter("gy_min", _gy_min)
	# The source window is (src_size * ss) px inside a larger fixed target.
	var tgt := Vector2(_sub.size)
	_mat.set_shader_parameter("src_origin", _src_origin)
	_mat.set_shader_parameter("src_size", tgt / _ss)
	_mat.set_shader_parameter("far_origin", _far_origin)
	_mat.set_shader_parameter("far_size", Vector2(_sub_far.size) / _ss_far)
	_mat.set_shader_parameter("gy_split", _gy_split)
	_mat.set_shader_parameter("split_blend", SPLIT_OVERLAP * 0.8)
	var depth: float = -_gy_min
	_mat.set_shader_parameter("haze_start", depth * 0.60)
	_mat.set_shader_parameter("haze_end", depth)
	_mat.set_shader_parameter("haze_max", HAZE_NEAR * smoothstep(0.25, 1.0, e))
	_mat.set_shader_parameter("sun_strength", lerpf(0.25, 0.6, e))
	# Sharpen keeps pixel art crisp through re-projection; the near-top-down
	# commander view is already ~1:1 supersampled so it needs less.
	_mat.set_shader_parameter("sharpen", lerpf(0.35, 0.65, e))

## Publish the current view to everything that stands upright.
func _push_view_to_scene(xf: Transform2D) -> void:
	PresentationOrientationCls.view_e = e
	PresentationOrientationCls.presence = presence_for_e(e, 1.0)
	PresentationOrientationCls.upright_stretch = nominal_stretch()
	for m in [DressingCls.billboard_material(true), DressingCls.small_material()]:
		m.set_shader_parameter("perspective", true)
		m.set_shader_parameter("board_x", xf.x)
		m.set_shader_parameter("board_y", xf.y)
		m.set_shader_parameter("board_o", xf.origin - _screen * 0.5)
		m.set_shader_parameter("focal", _focal)
		m.set_shader_parameter("pitch_sin", _sp)
		m.set_shader_parameter("pitch_cos", _cp)
		m.set_shader_parameter("gy_min", _gy_min)
		m.set_shader_parameter("keep", lerpf(1.0, 0.92, e))
		m.set_shader_parameter("presence", presence_for_e(e, TREE_PRESENCE))
	DressingCls.small_material().set_shader_parameter("opacity", lerpf(0.18, 1.0, smoothstep(0.15, 0.75, e)))
	# Ground cover right at the viewer would read as pasted clumps; thin it.
	DressingCls.small_material().set_shader_parameter("near_fade_start", 1.9)
	DressingCls.small_material().set_shader_parameter("near_fade_end", 3.6)
	# Bushes / rocks read as dark blobs from straight above; soften them at
	# the commander view, fully present from the tactical view on.
	DressingCls.billboard_material(true).set_shader_parameter("opacity", lerpf(0.55, 1.0, smoothstep(0.10, 0.60, e)))
	# Trees / bushes right at the lens thin out so the foreground army reads.
	DressingCls.billboard_material(true).set_shader_parameter("near_fade_start", 2.2)
	DressingCls.billboard_material(true).set_shader_parameter("near_fade_end", 3.4)
	DressingCls.billboard_material(true).set_shader_parameter("near_fade_floor", 0.35)
