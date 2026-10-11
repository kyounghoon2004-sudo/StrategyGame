extends Control

## CIV3D minimap (VISUAL ONLY): a zoomed-in window of the land around the
## camera (not the whole map), in dull, nearly colourless tones, with fog of
## war, unit dots and the camera's view, oriented like the screen (friendly
## forward = up). Click / drag moves the camera (the shell's Camera2D, as WASD
## does). Reads the board, the view's fog texture and unit positions; writes
## nothing but the camera focus.

const HexUtilsCls = preload("res://scripts/core/hex_utils.gd")
const SIZE := 256
## The texture is drawn at this resolution and filtered up (seamless tiles).
const RES := 128
## The window shows this share of the map's extent around the camera (so it
## scales with the map), never less than MIN_SPAN_HEXES across.
const SPAN_OF_MAP: float = 0.35
const MIN_SPAN_HEXES: float = 10.0

## Terrain as muted greys with only a trace of hue (achromatic look).
const TERRAIN_COL := {
	0: Color(0.42, 0.48, 0.28), 1: Color(0.50, 0.46, 0.40), 2: Color(0.20, 0.30, 0.16),
	3: Color(0.30, 0.38, 0.30), 4: Color(0.62, 0.58, 0.50), 5: Color(0.64, 0.56, 0.38),
	6: Color(0.70, 0.62, 0.44), 7: Color(0.30, 0.45, 0.55), 8: Color(0.55, 0.52, 0.46),
	9: Color(0.60, 0.56, 0.48), 10: Color(0.55, 0.52, 0.46), 11: Color(0.66, 0.60, 0.48),
	12: Color(0.55, 0.52, 0.46), 13: Color(0.34, 0.36, 0.28),
}
const HUE_KEEP: float = 0.18                       # how much of the terrain hue survives
const UNEXPLORED := Color(0.16, 0.16, 0.17)        # shroud
const OFFMAP := Color(0.10, 0.10, 0.11)
const REMEMBERED_DIM: float = 0.55                 # explored but not in sight

var shell: Node = null
var view: Node = null
var _terrain: Dictionary = {} # Vector2i -> terrain id
var _img: Image
var _tex: ImageTexture
var _fwd := Vector2(0, -1)
var _right := Vector2(1, 0)
var _scale := 1.0   # minimap px per rotated world px
var _center := Vector2.ZERO # rotated world coords at the window centre
var _built_center := Vector2(INF, INF)
var _fog_sig := -2
var _timer := 0.0
var _dragging := false

func setup(p_shell: Node, p_view: Node) -> void:
	shell = p_shell
	view = p_view
	mouse_filter = Control.MOUSE_FILTER_STOP
	clip_contents = true # the land fills the panel; what spills over is cut
	tooltip_text = "미니맵: 클릭하면 그 위치로 이동"
	var f3: Vector3 = view.get("fwd")
	_fwd = Vector2(f3.x, f3.z).normalized()
	var r3: Vector3 = f3.cross(Vector3.UP)
	_right = Vector2(r3.x, r3.z).normalized()
	var cells: Dictionary = shell.get("hex_grid").get("cell_data")
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for c in cells.values():
		_terrain[Vector2i(int(c.q), int(c.r))] = int(c.terrain)
		var uv := _rot(HexUtilsCls.hex_to_pixel(int(c.q), int(c.r)))
		lo = Vector2(minf(lo.x, uv.x), minf(lo.y, uv.y))
		hi = Vector2(maxf(hi.x, uv.x), maxf(hi.y, uv.y))
	var hex_px: float = HexUtilsCls.hex_to_pixel(1, 0).distance_to(HexUtilsCls.hex_to_pixel(0, 0))
	var extent: float = maxf(hi.x - lo.x, hi.y - lo.y) + hex_px
	var span: float = clampf(extent * SPAN_OF_MAP, MIN_SPAN_HEXES * hex_px, extent)
	_scale = float(SIZE) / span
	_img = Image.create(RES, RES, false, Image.FORMAT_RGBA8)
	_tex = ImageTexture.create_from_image(_img)
	_recenter(true)

## world px -> screen-oriented minimap coords (before scaling)
func _rot(w: Vector2) -> Vector2:
	return Vector2(w.dot(_right), -w.dot(_fwd))

func _to_px(uv: Vector2) -> Vector2:
	return (uv - _center) * _scale + Vector2(SIZE, SIZE) * 0.5

func _from_px(px: Vector2) -> Vector2:
	var uv: Vector2 = (px - Vector2(SIZE, SIZE) * 0.5) / _scale + _center
	# inverse of _rot (right / fwd are orthonormal)
	return _right * uv.x - _fwd * uv.y

## Follow the camera; rebuild the land image when it has moved far enough.
func _recenter(force: bool) -> void:
	var cam: Node2D = shell.get("camera")
	if cam == null:
		return
	_center = _rot(cam.global_position)
	if force or _center.distance_to(_built_center) * _scale > 6.0:
		_rebuild()

func _tone(t: int) -> Color:
	var col: Color = TERRAIN_COL.get(t, TERRAIN_COL[0])
	var l: float = col.get_luminance()
	var grey := Color(l, l, l * 0.98)
	return grey.lerp(col, HUE_KEEP)

func _rebuild() -> void:
	_built_center = _center
	var fog_img: Image = view.get("_cell_img")
	var outer: int = int(view.get("OUTER_R"))
	var k: float = float(SIZE) / float(RES)
	for py in range(RES):
		for px in range(RES):
			var w: Vector2 = _from_px(Vector2(px + 0.5, py + 0.5) * k)
			var h: Vector2i = HexUtilsCls.pixel_to_hex(w)
			var col: Color = OFFMAP
			if _terrain.has(h):
				col = _tone(int(_terrain[h]))
				var g := 255
				if fog_img != null and absi(h.x) <= outer and absi(h.y) <= outer:
					g = fog_img.get_pixel(h.x + outer, h.y + outer).g8
				if g < 64:
					col = UNEXPLORED
				elif g < 200:
					col = Color(col.r * REMEMBERED_DIM, col.g * REMEMBERED_DIM, col.b * REMEMBERED_DIM)
			_img.set_pixel(px, py, col)
	_tex.update(_img)
	queue_redraw()

func _process(delta: float) -> void:
	if not is_visible_in_tree() or view == null:
		return
	_timer -= delta
	if _timer > 0.0:
		return
	_timer = 0.15
	var sig: int = int(view.get("_fow_sig"))
	var fog_changed: bool = sig != _fog_sig
	_fog_sig = sig
	_recenter(fog_changed)
	queue_redraw()

func _draw() -> void:
	var rect := Rect2(Vector2.ZERO, size)
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.08, 0.08, 0.085, 0.94)
	bg.border_color = Color(0.46, 0.45, 0.42)
	bg.set_border_width_all(2)
	bg.set_corner_radius_all(6)
	draw_style_box(bg, rect)
	var k: float = maxf(size.x, size.y) / SIZE # fill the panel (no side bars)
	var off := (size - Vector2(SIZE, SIZE) * k) * 0.5
	# the image was built around _built_center; shift it by how far the camera has moved since
	var shift: Vector2 = (_built_center - _center) * _scale * k
	draw_set_transform(Vector2.ZERO)
	var inner := Rect2(Vector2(3, 3), size - Vector2(6, 6))
	draw_texture_rect_region(_tex, inner, Rect2((inner.position - off - shift) / (k * float(SIZE) / float(RES)), inner.size / (k * float(SIZE) / float(RES))))
	# units
	var units: Dictionary = view.get("_units")
	for id in units.keys():
		var d: Dictionary = units[id]
		var root: Node3D = d.get("root")
		if root == null or not is_instance_valid(root) or not root.visible:
			continue
		var lp: Vector2 = d.get("last_pos", Vector2.INF)
		if lp == Vector2.INF:
			continue
		var p: Vector2 = off + _to_px(_rot(lp)) * k
		if not inner.has_point(p):
			continue
		var col := Color(0.50, 0.64, 0.86) if d.get("faction", "blue") == "blue" else Color(0.82, 0.42, 0.36)
		draw_circle(p, 3.4, Color(0, 0, 0, 0.75))
		draw_circle(p, 2.5, col)
	# camera view: screen corners projected to the ground
	var vp: Vector2 = get_viewport().get_visible_rect().size
	var corners := [Vector2(0, 0), Vector2(vp.x, 0), Vector2(vp.x, vp.y), Vector2(0, vp.y)]
	var poly := PackedVector2Array()
	for sc in corners:
		var w: Vector2 = view.call("screen_to_world", sc)
		if w.x > 1.0e6:
			w = view.call("screen_to_world", Vector2(sc.x, vp.y * 0.35)) # sky: clamp to the horizon band
		poly.append(off + _to_px(_rot(w)) * k) # clipped by the panel
	poly.append(poly[0])
	draw_polyline(poly, Color(0.86, 0.85, 0.80, 0.85), 1.4, true)
	var frame := StyleBoxFlat.new()
	frame.draw_center = false
	frame.border_color = Color(0.46, 0.45, 0.42)
	frame.set_border_width_all(2)
	frame.set_corner_radius_all(6)
	draw_style_box(frame, rect)

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		_dragging = (event as InputEventMouseButton).pressed
		if _dragging:
			_jump((event as InputEventMouseButton).position)
		accept_event()
	elif event is InputEventMouseMotion and _dragging:
		# the window follows the camera, so a drag grabs the land and pans it
		var k: float = maxf(size.x, size.y) / SIZE
		var rel: Vector2 = (event as InputEventMouseMotion).relative / (k * _scale)
		var cam: Node2D = shell.get("camera")
		if cam and cam.has_method("focus_on"):
			cam.call("focus_on", cam.global_position - (_right * rel.x - _fwd * rel.y), true)
		accept_event()

func _jump(local: Vector2) -> void:
	var k: float = maxf(size.x, size.y) / SIZE
	var off := (size - Vector2(SIZE, SIZE) * k) * 0.5
	var w: Vector2 = _from_px((local - off) / k)
	var cam: Node = shell.get("camera")
	if cam and cam.has_method("focus_on"):
		cam.call("focus_on", w, false)
