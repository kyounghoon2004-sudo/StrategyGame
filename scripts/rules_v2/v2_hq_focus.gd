class_name V2HqFocus
extends Node

## Rules V2 "HQ focus" (2026-11-01)
##  - BLUR: one pass under every canvas layer (layer -1) that blurs + mutes the 3D battlefield,
##    so ground, roads and buildings become soft backing. Badges (layer 5), supply lines, bands
##    and the HUD all draw above it and stay crisp: units are the only thing that reads.
##  - BANDS: three morale zones drawn in SCREEN space through the 3D camera (the same
##    unproject the unit badges use), so the hexes sit exactly on the board hexes. An earlier
##    version drew them in the 2D canvas, which drifts against the 3D board.
##      near (morale +10, heals)  green
##      mid  (morale held)        amber
##      out  (morale decays)      untinted - the blurred backdrop is the signal
## Driven by V2Overlay.show_bands(); hidden whenever no HQ is selected.

const HexUtilsCls = preload("res://scripts/core/hex_utils.gd")
const WorldBoundaryCls = preload("res://scripts/step2r/step2r_world_boundary.gd")

const S := 0.1875                  # 3D world scale: 4.5 unit hex radius / 24 px (see civ_battlefield_view)
const BLUR_LAYER := -1
const BAND_LAYER := 2              # above the blur, below the unit badges (5)
const NONE_HEX := Vector2i(-999, -999)
const HEX_PX := 24.0               # 2D hex radius the projection expects
const PULSE_PERIOD := 1.15         # seconds between pulses
const GREEN_PERIOD := 1.1          # near (heal) pulse: its own, faster beat
const ORANGE_PERIOD := 4.6         # range pulse: its own, slower beat - independent of green
const COL_NEAR_OUTLINE := Color(0.40, 0.70, 1.0, 0.65) # standing outline on the heal edge (blue)
const WAVE_WIDTH := 0.9            # hexes of tint behind the front

const COL_PULSE := Color(0.36, 0.66, 1.0, 0.18)        # near zone pulse: ally blue
const COL_PULSE_ORANGE := Color(1.0, 0.58, 0.20, 0.18)  # range pulse, every PULSE_EVERY-th
const COL_RANGE_OUTLINE := Color(1.0, 0.62, 0.25, 0.55) # standing outline on the last held hex
const COL_MOVE_OUTLINE := Color(1.0, 1.0, 1.0, 0.85)    # Civ-style move reach: plain white

var _blur_layer: CanvasLayer = null
var _rect: ColorRect = null
var _mat: ShaderMaterial = null
var _band_layer: CanvasLayer = null
var _bands: BandDrawer = null
var _on: bool = false
var _blur_on: bool = false
var _hq: Vector2i = NONE_HEX
var _cam_sig: String = ""
var _t: float = 0.0
var _move_from: Vector2i = NONE_HEX
var _move_cells: Dictionary = {}   # "q,r" -> Vector2i
var _ground_provider: Node = null
var _ground_cam: Camera3D = null
var _near_r: int = 3
var _normal_r: int = 6


class BandDrawer extends Node2D:
	var host: Node = null

	func _draw() -> void:
		if host != null:
			host.call("_draw_bands", self)


func _ready() -> void:
	_blur_layer = CanvasLayer.new()
	_blur_layer.name = "HqFocusBlur"
	_blur_layer.layer = BLUR_LAYER
	add_child(_blur_layer)
	_rect = ColorRect.new()
	_rect.name = "HqFocusRect"
	_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sh: Shader = load("res://scripts/rules_v2/v2_hq_focus.gdshader")
	if sh == null:
		push_error("[V2HqFocus] shader missing - blur disabled")
	else:
		_mat = ShaderMaterial.new()
		_mat.shader = sh
		_mat.set_shader_parameter("strength", 0.0)
		_rect.material = _mat
	_blur_layer.add_child(_rect)
	_blur_layer.visible = false

	_band_layer = CanvasLayer.new()
	_band_layer.name = "HqFocusBands"
	_band_layer.layer = BAND_LAYER
	add_child(_band_layer)
	_bands = BandDrawer.new()
	_bands.host = self
	_band_layer.add_child(_bands)


func _process(delta: float) -> void:
	if _bands == null:
		return
	if _hq == NONE_HEX and _move_from == NONE_HEX:
		return
	if _hq != NONE_HEX:
		_t += delta
	_bands.queue_redraw()

func show_bands(hq: Vector2i, near_r: int, normal_r: int) -> void:
	if hq != _hq:
		_t = 0.0
	_hq = hq
	_near_r = maxi(1, near_r)
	_normal_r = maxi(_near_r + 1, normal_r)

## White movement reach for the selected field unit (the HQ keeps its own supply reading).
## White outline around the hexes the unit can actually reach this turn (terrain costs applied).
func show_move_area(origin: Vector2i, cells: Array) -> void:
	var d: Dictionary = {}
	for h in cells:
		var v: Vector2i = h if h is Vector2i else Vector2i(int(h.x), int(h.y))
		d[_k(v)] = v
	if origin == _move_from and d.size() == _move_cells.size():
		return
	_move_from = origin
	_move_cells = d
	if _bands != null:
		_bands.queue_redraw()

func clear_move_ring() -> void:
	if _move_from == NONE_HEX and _move_cells.is_empty():
		return
	_move_from = NONE_HEX
	_move_cells.clear()
	if _bands != null:
		_bands.queue_redraw()

func clear() -> void:
	_hq = NONE_HEX
	if _bands != null:
		_bands.queue_redraw()
	set_blur(false)


## Selection-gated part: the blur/mute backing. The pulse itself stays on either way.
func set_blur(on: bool) -> void:
	if _blur_layer == null or on == _blur_on:
		return
	_blur_on = on
	if on:
		_blur_layer.visible = true
		if _mat != null:
			var tw := create_tween()
			tw.tween_method(_set_strength, 0.0, 1.0, 0.22)
		return
	if _mat == null:
		_blur_layer.visible = false
		return
	var tw := create_tween()
	tw.tween_method(_set_strength, float(_mat.get_shader_parameter("strength")), 0.0, 0.16)
	tw.tween_callback(_hide_blur)


func _hide_blur() -> void:
	if _blur_on or _blur_layer == null:
		return
	_blur_layer.visible = false
	_set_strength(0.0)

func _set_strength(v: float) -> void:
	if _mat != null:
		_mat.set_shader_parameter("strength", v)


## Screen position of a hex centre, using the same 3D camera and world scale as the unit badges.
func _proj(cam: Camera3D, hex: Vector2i) -> Vector2:
	var p := HexUtilsCls.hex_to_pixel(hex.x, hex.y)
	return cam.unproject_position(Vector3(p.x * S, 0.0, p.y * S))


## A pulse leaves the HQ every WAVE_PERIOD seconds and runs outward. Hexes light up only while the
## front passes them, in their zone colour: green inside the heal radius, amber while morale holds,
## red once it decays. Nothing is left painted, so the range never reads as "movable area".
## Blue pulses keep rolling out of the HQ; every PULSE_EVERY-th pulse is drawn orange, which
## marks the range itself. Nothing beyond the normal radius is painted (that zone is ignored),
## nothing stays tinted, and the alphas are deliberately low so the board is not washed over.
## Pulse colours follow the zones, weakly:
##   every pulse        a short GREEN ripple inside the heal radius (near, morale +10)
##   every 5th pulse    an ORANGE ripple out to the normal radius (morale held edge)
## nothing is painted past the normal radius (out of range is ignored), nothing stays tinted.
## Two things live here:
##  1. a STANDING outline on the last hex that still holds morale - always on, no selection needed
##  2. green pulses run 0 -> heal edge every beat; every PULSE_EVERY-th beat an orange pulse
##     continues from that edge out to the range edge. Nothing is painted past the outline and
##     nothing stays tinted.
## Passive range reading, all of it drawn whether or not anything is selected:
##  - a standing outline on the heal edge (green) and one on the range edge (orange)
##  - two pulses with their OWN frequencies: green runs 0 -> heal edge every GREEN_PERIOD,
##    orange runs heal edge -> range edge every ORANGE_PERIOD. They never share a beat, so the
##    board shows a fast inner ripple and a slow outer sweep at the same time.
## Nothing is painted past the range outline, nothing stays tinted, out-of-range is not drawn.
## Passive range reading, drawn whether or not anything is selected:
##  - a standing outline on the heal edge (green) and one on the range edge (orange)
##  - two pulses with independent clocks, both evaluated every frame so neither waits for the other:
##      green  0 -> heal edge, every GREEN_PERIOD, steady alpha (a constant blink)
##      orange heal edge -> range edge -> BACK, every ORANGE_PERIOD, fading in and out so the
##             turnaround never pops
## Nothing is painted past the range outline, nothing stays tinted, out-of-range is not drawn.
## HQ: standing heal-edge / range outlines plus the two independent pulses.
## Field unit: ONE white outline at the shared movement reach, nothing else.
func _draw_bands(ci: CanvasItem) -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	if _move_from != NONE_HEX:
		_draw_move_area(ci, cam)
	if _hq == NONE_HEX:
		return
	_fringe(ci, cam, _hq, _normal_r, COL_RANGE_OUTLINE, 1.6)
	_fringe(ci, cam, _hq, _near_r, COL_NEAR_OUTLINE, 2.4)

	var gphase: float = fposmod(_t, GREEN_PERIOD) / GREEN_PERIOD
	var gfade: float = clampf(minf(gphase / 0.12, (1.0 - gphase) / 0.18), 0.0, 1.0)
	_pulse_ring(ci, cam, float(_near_r) * gphase, COL_PULSE, gfade)

	var ophase: float = fposmod(_t, ORANGE_PERIOD) / ORANGE_PERIOD
	var tri: float = ophase * 2.0 if ophase < 0.5 else (1.0 - ophase) * 2.0
	var ofront: float = float(_near_r) + (float(_normal_r) - float(_near_r)) * tri
	var ofade: float = 0.30 + 0.70 * sin(PI * tri)
	_pulse_ring(ci, cam, ofront, COL_PULSE_ORANGE, ofade)

func _pulse_ring(ci: CanvasItem, cam: Camera3D, front: float, col: Color, fade: float) -> void:
	var limit: int = _normal_r + 1
	for dq in range(-limit, limit + 1):
		for dr in range(maxi(-limit, -dq - limit), mini(limit, -dq + limit) + 1):
			var hex := Vector2i(_hq.x + dq, _hq.y + dr)
			var d: float = float(sv_dist(_hq, hex))
			var gap: float = absf(d - front)
			if gap > WAVE_WIDTH:
				continue
			var k: float = 1.0 - gap / WAVE_WIDTH
			var pts := _hex_pts(cam, hex)
			if pts.is_empty():
				continue
			ci.draw_colored_polygon(pts, Color(col.r, col.g, col.b, col.a * k * k * fade))

## One white outline hugging the reachable set: an edge is drawn only where the neighbour across
## it is NOT reachable, so mountains, rivers and forest cost show up as dents in the shape.
func _draw_move_area(ci: CanvasItem, cam: Camera3D) -> void:
	for key in _move_cells.keys():
		var h: Vector2i = _move_cells[key]
		var pts := _hex_pts(cam, h)
		if pts.is_empty():
			continue
		var c2d := HexUtilsCls.hex_to_pixel(h.x, h.y)
		for e in range(6):
			var a0 := deg_to_rad(60.0 * e)
			var a1 := deg_to_rad(60.0 * (e + 1))
			var m2d: Vector2 = c2d + (Vector2(cos(a0), sin(a0)) + Vector2(cos(a1), sin(a1))) * (HEX_PX * 0.5)
			var outward: Vector2 = (m2d - c2d).normalized()
			var probe: Vector2i = WorldBoundaryCls.world_to_axial(m2d + outward * 7.0)
			if not _move_cells.has(_k(probe)):
				# dark under-stroke first so white stays readable on pale grass and sand
				ci.draw_line(pts[e], pts[(e + 1) % 6], Color(0.05, 0.07, 0.09, 0.55), 4.6, true)
				ci.draw_line(pts[e], pts[(e + 1) % 6], COL_MOVE_OUTLINE, 3.2, true)


static func _k(h: Vector2i) -> String:
	return "%d,%d" % [h.x, h.y]


## Only the edges of the ring_r hexes around `center` that face out, chained into one outline.
func _fringe(ci: CanvasItem, cam: Camera3D, center: Vector2i, ring_r: int, col: Color, w: float) -> void:
	for dq in range(-ring_r - 1, ring_r + 2):
		for dr in range(maxi(-ring_r - 1, -dq - ring_r - 1), mini(ring_r + 1, -dq + ring_r + 1) + 1):
			var ohex := Vector2i(center.x + dq, center.y + dr)
			if sv_dist(center, ohex) != ring_r:
				continue
			var opts := _hex_pts(cam, ohex)
			if opts.is_empty():
				continue
			var o2d := HexUtilsCls.hex_to_pixel(ohex.x, ohex.y)
			for e in range(6):
				var a0 := deg_to_rad(60.0 * e)
				var a1 := deg_to_rad(60.0 * (e + 1))
				var m2d: Vector2 = o2d + (Vector2(cos(a0), sin(a0)) + Vector2(cos(a1), sin(a1))) * (HEX_PX * 0.5)
				var outward: Vector2 = (m2d - o2d).normalized()
				var probe: Vector2i = WorldBoundaryCls.world_to_axial(m2d + outward * 7.0)
				if sv_dist(center, probe) > ring_r:
					ci.draw_line(opts[e], opts[(e + 1) % 6], col, w, true)

## The 3D board lifts hexes onto terrain, so the flat y=0 plane would project the outline a
## few pixels off the grid. Ask the board view for the true ground point when it can give one
## (civ_battlefield_view._ground3), otherwise stay on the plane.
func _world3(cam: Camera3D, p: Vector2) -> Vector3:
	if cam != _ground_cam:
		_ground_cam = cam
		_ground_provider = null
		var n: Node = cam
		while n != null:
			if n.has_method("_ground3"):
				_ground_provider = n
				break
			n = n.get_parent()
	if _ground_provider != null:
		return _ground_provider.call("_ground3", p)
	return Vector3(p.x * S, 0.0, p.y * S)

func _hex_pts(cam: Camera3D, hex: Vector2i) -> PackedVector2Array:
	var base := HexUtilsCls.hex_to_pixel(hex.x, hex.y)
	if cam.is_position_behind(_world3(cam, base)):
		return PackedVector2Array()
	var pts := PackedVector2Array()
	for i in range(6):
		var ang := deg_to_rad(60.0 * i)
		var v := base + Vector2(cos(ang), sin(ang)) * HEX_PX
		pts.append(cam.unproject_position(_world3(cam, v)))
	return pts

func _world_of(hex: Vector2i) -> Vector3:
	var p := HexUtilsCls.hex_to_pixel(hex.x, hex.y)
	return Vector3(p.x * S, 0.0, p.y * S)


func _closed(ci: CanvasItem, pts: PackedVector2Array, col: Color, w: float) -> void:
	var closed := pts.duplicate()
	closed.append(pts[0])
	ci.draw_polyline(closed, col, w, true)


static func sv_dist(a: Vector2i, b: Vector2i) -> int:
	var dq := a.x - b.x
	var dr := a.y - b.y
	return maxi(abs(dq), maxi(abs(dr), abs(dq + dr)))
