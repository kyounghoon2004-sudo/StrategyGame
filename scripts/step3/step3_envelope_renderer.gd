class_name Step3EnvelopeRenderer
extends Node2D

## STEP-03 Movement Envelope & Route Preview Tactical Overlay Renderer
## Renders high-readability translucent hex overlays for Blue, Red, and Black envelopes,
## plus directional route path preview and destination confirmation reticles.

const HexUtilsCls = preload("res://scripts/core/hex_utils.gd")
const Step3ConfigCls = preload("res://scripts/core/step3_config.gd")

# Colors
const COLOR_BLUE_FILL: Color = Color(0.18, 0.42, 0.92, 0.32)
const COLOR_BLUE_BORDER: Color = Color(0.30, 0.55, 1.0, 0.88)

const COLOR_RED_FILL: Color = Color(0.92, 0.18, 0.18, 0.32)
const COLOR_RED_BORDER: Color = Color(1.0, 0.30, 0.30, 0.88)

const COLOR_BLACK_FILL: Color = Color(0.08, 0.06, 0.10, 0.42)
const COLOR_BLACK_BORDER: Color = Color(0.45, 0.40, 0.55, 0.90)

const COLOR_SELECTED_RING: Color = Color(1.0, 0.85, 0.30, 0.95)
const COLOR_PREVIEW_TARGET: Color = Color(1.0, 1.0, 1.0, 0.90)

# Attack Targeting Colors (Distinct from movement envelopes - Section 35)
const COLOR_ATTACK_RETICLE: Color = Color(1.0, 0.22, 0.18, 0.95)
const COLOR_ATTACK_FILL: Color = Color(0.85, 0.15, 0.15, 0.22)
const COLOR_ATTACK_LOCKON: Color = Color(1.0, 0.85, 0.15, 0.98)

var _blue_hexes: Array[Vector2i] = []
var _red_hexes: Array[Vector2i] = []
var _black_hexes: Array[Vector2i] = []
var _attackable_hexes: Array[Vector2i] = []
var _selected_coord: Vector2i = Vector2i(-999, -999)
var _preview_route: Array[Vector2i] = []
var _preview_march_class: int = Step3ConfigCls.MarchClass.GREEN
var _preview_dest: Vector2i = Vector2i(-999, -999)
var _preview_attack_target: Vector2i = Vector2i(-999, -999)

var _pulse_phase: float = 0.0
var _deploy_hexes: Array[Vector2i] = []
# PERF-V1: cached corner polygons + centers per set (setters run once, _draw
# runs every frame while selected). Avoids per-frame hex_to_pixel + array
# allocation for every envelope hex.
var _blue_polys: Array = []
var _red_polys: Array = []
var _black_polys: Array = []
var _deploy_polys: Array = []
var _route_pts: PackedVector2Array = PackedVector2Array()

func _ready() -> void:
	z_index = 8 # Render above terrain (0) and below units (10)
	set_process(true)

func _process(delta: float) -> void:
	_pulse_phase += delta * 3.5
	if _pulse_phase > TAU:
		_pulse_phase -= TAU
	if _selected_coord.x != -999 or not _preview_route.is_empty() or not _attackable_hexes.is_empty() or _preview_attack_target.x != -999 or not _deploy_hexes.is_empty():
		queue_redraw()

func clear_all() -> void:
	_blue_hexes.clear()
	_red_hexes.clear()
	_black_hexes.clear()
	_attackable_hexes.clear()
	_deploy_hexes.clear()
	_selected_coord = Vector2i(-999, -999)
	_preview_route.clear()
	_preview_dest = Vector2i(-999, -999)
	_preview_attack_target = Vector2i(-999, -999)
	_rebuild_poly_cache()
	queue_redraw()

# PERF-V1: rebuild cached draw geometry after any set/clear.
func _rebuild_poly_cache() -> void:
	_blue_polys = _polys_for(_blue_hexes, 21.0)
	_red_polys = _polys_for(_red_hexes, 21.0)
	_black_polys = _polys_for(_black_hexes, 21.0)
	_deploy_polys = _polys_for(_deploy_hexes, 21.0)
	_route_pts = PackedVector2Array()
	for c in _preview_route:
		_route_pts.append(HexUtilsCls.hex_to_pixel(c.x, c.y))

func _polys_for(hexes: Array[Vector2i], radius: float) -> Array:
	var out: Array = []
	out.resize(hexes.size())
	for i in range(hexes.size()):
		var center: Vector2 = HexUtilsCls.hex_to_pixel(hexes[i].x, hexes[i].y)
		out[i] = [center, _get_hex_corners(center, radius)]
	return out

func _visible_world_rect() -> Rect2:
	var vp: Viewport = get_viewport()
	if vp == null:
		return Rect2(-4000.0, -3000.0, 8000.0, 6000.0)
	# Closeup presentation drapes the whole board's overlay on its ground.
	var v3: Variant = get_parent().get("_view3d") if get_parent() != null else null
	if v3 != null and bool((v3 as Node).call("is_active")):
		return (v3 as Node).call("visible_world_rect") as Rect2
	# Perspective presentation shows more world than the flat camera rect.
	var proj: Variant = get_parent().get("_projection") if get_parent() != null else null
	if proj != null:
		return ((proj as Node).call("visible_world_rect") as Rect2).grow(48.0)
	var scr := Rect2(Vector2.ZERO, vp.get_visible_rect().size)
	return (get_canvas_transform().affine_inverse() * scr).grow(48.0)

func set_envelope(
	selected_coord: Vector2i,
	blue: Array[Vector2i],
	red: Array[Vector2i],
	black: Array[Vector2i]
) -> void:
	_selected_coord = selected_coord
	_blue_hexes = blue.duplicate()
	_red_hexes = red.duplicate()
	_black_hexes = black.duplicate()
	_rebuild_poly_cache()
	queue_redraw()

func set_attack_targets(targets: Array[Vector2i]) -> void:
	_attackable_hexes = targets.duplicate()
	queue_redraw()

func clear_attack_targets() -> void:
	_attackable_hexes.clear()
	_preview_attack_target = Vector2i(-999, -999)
	queue_redraw()

func set_attack_preview(target: Vector2i) -> void:
	_preview_attack_target = target
	queue_redraw()

func clear_attack_preview() -> void:
	_preview_attack_target = Vector2i(-999, -999)
	queue_redraw()

func set_route_preview(
	route: Array[Vector2i],
	march_class: int,
	destination: Vector2i
) -> void:
	_preview_route = route.duplicate()
	_preview_march_class = march_class
	_preview_dest = destination
	_rebuild_poly_cache()
	queue_redraw()

func clear_route_preview() -> void:
	_preview_route.clear()
	_preview_dest = Vector2i(-999, -999)
	_rebuild_poly_cache()
	queue_redraw()

func set_deploy_preview(hexes: Array) -> void:
	_deploy_hexes.clear()
	for h in hexes:
		if h is Vector2i:
			_deploy_hexes.append(h)
		elif h is Array and h.size() >= 2:
			_deploy_hexes.append(Vector2i(int(h[0]), int(h[1])))
	_rebuild_poly_cache()
	queue_redraw()

func clear_deploy_preview() -> void:
	_deploy_hexes.clear()
	_rebuild_poly_cache()
	queue_redraw()

func _draw() -> void:
	# PERF-V1: lazy cache guard (setters rebuild; covers direct mutation paths).
	if _blue_polys.size() != _blue_hexes.size() or _red_polys.size() != _red_hexes.size() or _black_polys.size() != _black_hexes.size():
		_rebuild_poly_cache()
	var vis: Rect2 = _visible_world_rect()
	# 0. Draw deploy-valid hexes (deploy mode) — bright green pulsing
	var dpulse: float = 0.45 + 0.55 * sin(_pulse_phase * 3.0)
	for entry in _deploy_polys:
		var dcenter: Vector2 = entry[0]
		if not vis.has_point(dcenter):
			continue
		var dpoly: PackedVector2Array = entry[1]
		draw_colored_polygon(dpoly, Color(0.22, 0.92, 0.28, 0.28 + 0.18 * dpulse))
		draw_polyline(dpoly, Color(0.30, 1.0, 0.45, 0.92), 2.2, true)
		draw_circle(dcenter, 4.0, Color(1,1,1,0.92))

	# 1. Draw envelope fills and borders
	_draw_poly_batch(_blue_polys, COLOR_BLUE_FILL, COLOR_BLUE_BORDER, vis)
	_draw_poly_batch(_red_polys, COLOR_RED_FILL, COLOR_RED_BORDER, vis)
	_draw_poly_batch(_black_polys, COLOR_BLACK_FILL, COLOR_BLACK_BORDER, vis)
	
	# 2. Draw attackable enemy targets (Section 35)
	for th in _attackable_hexes:
		var is_locked: bool = (th == _preview_attack_target)
		_draw_attack_target(th, is_locked)
	
	# 3. Draw origin selection ring
	if _selected_coord.x != -999:
		var origin_pos: Vector2 = HexUtilsCls.hex_to_pixel(_selected_coord.x, _selected_coord.y)
		var pulse: float = 0.5 + 0.5 * sin(_pulse_phase)
		var ring_color: Color = Color(COLOR_SELECTED_RING.r, COLOR_SELECTED_RING.g, COLOR_SELECTED_RING.b, 0.70 + 0.30 * pulse)
		var poly: PackedVector2Array = _get_hex_corners(origin_pos, 22.0 + 1.5 * pulse)
		draw_polyline(poly, ring_color, 2.5, true)
	
	# 4. Draw route preview polyline and node dots
	if _route_pts.size() >= 2:
		var line_color: Color = _get_march_color(_preview_march_class)
		var pts: PackedVector2Array = _route_pts

		# Draw shadow line under route
		draw_polyline(pts, Color(0.05, 0.05, 0.08, 0.75), 5.5)
		# Draw main colored line
		draw_polyline(pts, line_color, 3.2)

		# Draw waypoint nodes
		for i in range(pts.size()):
			var p: Vector2 = pts[i]
			if i == 0:
				continue
			if i == pts.size() - 1:
				# Destination pulse marker
				var pulse_r: float = 8.0 + 3.0 * (0.5 + 0.5 * sin(_pulse_phase * 1.5))
				draw_circle(p, pulse_r, Color(line_color.r, line_color.g, line_color.b, 0.40))
				draw_circle(p, 5.0, line_color)
				draw_circle(p, 2.5, Color(1, 1, 1, 0.95))
			else:
				draw_circle(p, 4.0, Color(0.1, 0.1, 0.1, 0.9))
				draw_circle(p, 2.5, line_color)

func _draw_attack_target(coord: Vector2i, is_locked: bool) -> void:
	var center: Vector2 = HexUtilsCls.hex_to_pixel(coord.x, coord.y)
	var pulse: float = 0.5 + 0.5 * sin(_pulse_phase * 2.0)
	
	if is_locked:
		# Prominent locked-on attack reticle
		var poly: PackedVector2Array = _get_hex_corners(center, 23.0 + 2.0 * pulse)
		draw_colored_polygon(poly, Color(COLOR_ATTACK_LOCKON.r, COLOR_ATTACK_LOCKON.g, COLOR_ATTACK_LOCKON.b, 0.35))
		draw_polyline(poly, COLOR_ATTACK_LOCKON, 3.0, true)
		
		# Crosshair lines
		var arm: float = 14.0 + 2.0 * pulse
		draw_line(center + Vector2(-arm, 0), center + Vector2(-4, 0), COLOR_ATTACK_LOCKON, 2.2)
		draw_line(center + Vector2(4, 0), center + Vector2(arm, 0), COLOR_ATTACK_LOCKON, 2.2)
		draw_line(center + Vector2(0, -arm), center + Vector2(0, -4), COLOR_ATTACK_LOCKON, 2.2)
		draw_line(center + Vector2(0, 4), center + Vector2(0, arm), COLOR_ATTACK_LOCKON, 2.2)
	else:
		# Subdued attackable candidate indicator
		var poly: PackedVector2Array = _get_hex_corners(center, 21.0)
		draw_colored_polygon(poly, COLOR_ATTACK_FILL)
		var reticle_col: Color = Color(COLOR_ATTACK_RETICLE.r, COLOR_ATTACK_RETICLE.g, COLOR_ATTACK_RETICLE.b, 0.70 + 0.30 * pulse)
		draw_polyline(poly, reticle_col, 2.0, true)
		
		# Small corner crosshair marks
		var arm: float = 8.0
		draw_line(center + Vector2(-arm, 0), center + Vector2(arm, 0), reticle_col, 1.5)
		draw_line(center + Vector2(0, -arm), center + Vector2(0, arm), reticle_col, 1.5)

func _draw_hex_batch(hexes: Array[Vector2i], fill_col: Color, border_col: Color) -> void:
	for h in hexes:
		var center: Vector2 = HexUtilsCls.hex_to_pixel(h.x, h.y)
		var corners: PackedVector2Array = _get_hex_corners(center, 21.0)
		draw_colored_polygon(corners, fill_col)
		# subtle outline
		var outline: PackedVector2Array = _get_hex_corners(center, 21.0)
		draw_polyline(outline, border_col, 1.8, true)

# PERF-V1: cached-polygon batch with viewport culling (replaces per-frame
# hex_to_pixel + corner allocation inside _draw).
func _draw_poly_batch(polys: Array, fill_col: Color, border_col: Color, vis: Rect2) -> void:
	for entry in polys:
		var center: Vector2 = entry[0]
		if not vis.has_point(center):
			continue
		var corners: PackedVector2Array = entry[1]
		draw_colored_polygon(corners, fill_col)
		draw_polyline(corners, border_col, 1.8, true)

func _get_hex_corners(center: Vector2, radius: float) -> PackedVector2Array:
	# Flat-top hexagon geometry (48x42, width=48, height=42)
	# Radius corresponds to ~24px width, ~21px height
	var w: float = radius
	var h: float = radius * 0.866025
	return PackedVector2Array([
		center + Vector2(-w, 0),
		center + Vector2(-w * 0.5, -h),
		center + Vector2(w * 0.5, -h),
		center + Vector2(w, 0),
		center + Vector2(w * 0.5, h),
		center + Vector2(-w * 0.5, h),
		center + Vector2(-w, 0)
	])

func _get_march_color(march_class: int) -> Color:
	match march_class:
		Step3ConfigCls.MarchClass.GREEN:
			return Color(0.30, 0.55, 1.0, 1.0) # Blue
		Step3ConfigCls.MarchClass.ORANGE:
			return Color(1.0, 0.30, 0.30, 1.0) # Red
		Step3ConfigCls.MarchClass.RED:
			return Color(0.30, 0.25, 0.38, 1.0) # Dark purple-black
	return Color(1, 1, 1, 1)
