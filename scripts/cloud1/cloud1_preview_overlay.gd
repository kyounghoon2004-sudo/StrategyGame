class_name Cloud1PreviewOverlay
extends Node2D

## Research-console map preview (additive, pure drawing).
##
## Shows the compiled plan on the battlefield BEFORE Execute:
##   small amber dot = planned unit source (membership)
##   cyan polyline + disc = planned MOVE route + destination
##   red line + X = planned ATTACK (unit -> target)
##   blue ring = planned HOLD position
##   red-orange X = rejected unit current position (FAILED)
##   white ring = focused unit (result-row linking)
## Routes are resolved by the dock via the live command service
## (preview_move, read-only). No geometry system of its own.

const HexUtilsCls = preload("res://scripts/core/hex_utils.gd")

const COL_MOVE := Color(0.35, 0.8, 1.0, 0.95)
const COL_MOVE_FILL := Color(0.35, 0.8, 1.0, 0.35)
const COL_ATTACK := Color(1.0, 0.32, 0.26, 0.95)
const COL_HOLD := Color(0.5, 0.65, 1.0, 0.95)
const COL_SRC := Color(1.0, 0.85, 0.3, 0.85)
const COL_FAIL := Color(1.0, 0.45, 0.2, 0.95)
const COL_FOCUS := Color(1.0, 1.0, 1.0, 0.95)

var _routes: Array = []
var _failed: Array = []
var _sources: Array = []
var _focus: Array = []


func set_preview(routes: Array, failed_cells: Array = [], source_cells: Array = []) -> void:
	_routes = routes
	_failed = failed_cells
	_sources = source_cells
	queue_redraw()


func set_focus(cell: Array) -> void:
	_focus = cell
	queue_redraw()


func clear_preview() -> void:
	_routes = []
	_failed = []
	_sources = []
	_focus = []
	queue_redraw()


func has_preview() -> bool:
	return not _routes.is_empty() or not _failed.is_empty()


func _draw() -> void:
	for cell in _sources:
		_dot(cell, 5.0, COL_SRC)
	for r_val in _routes:
		if not r_val is Dictionary:
			continue
		var r: Dictionary = r_val
		match str(r.get("kind", "move")):
			"move":
				_draw_move(r)
			"attack":
				_draw_attack(r)
			"hold":
				var h: Array = r.get("at_cell", [])
				if h.size() == 2:
					_ring(h, 14.0, COL_HOLD, 3.0)
	for cell in _failed:
		_cross(cell, 12.0, COL_FAIL, 3.0)
	if _focus.size() == 2:
		_ring(_focus, 24.0, COL_FOCUS, 3.0)


func _draw_move(r: Dictionary) -> void:
	var pts := PackedVector2Array()
	for c in (r.get("path_cells", []) as Array):
		if c is Array and (c as Array).size() == 2:
			pts.append(HexUtilsCls.hex_to_pixel(int((c as Array)[0]), int((c as Array)[1])))
	if pts.size() >= 2:
		draw_polyline(pts, COL_MOVE, 3.0, true)
	if not pts.is_empty():
		var dst: Vector2 = pts[pts.size() - 1]
		draw_circle(dst, 10.0, COL_MOVE_FILL)
		draw_arc(dst, 10.0, 0.0, TAU, 20, COL_MOVE, 2.5)


func _draw_attack(r: Dictionary) -> void:
	var a: Array = r.get("from_cell", [])
	var b: Array = r.get("to_cell", [])
	if a.size() != 2 or b.size() != 2:
		return
	var pa := HexUtilsCls.hex_to_pixel(int(a[0]), int(a[1]))
	var pb := HexUtilsCls.hex_to_pixel(int(b[0]), int(b[1]))
	draw_line(pa, pb, COL_ATTACK, 3.0, true)
	_cross(b, 11.0, COL_ATTACK, 3.0)


func _dot(cell: Variant, radius: float, color: Color) -> void:
	if not cell is Array or (cell as Array).size() != 2:
		return
	draw_circle(HexUtilsCls.hex_to_pixel(int((cell as Array)[0]), int((cell as Array)[1])), radius, color)


func _ring(cell: Variant, radius: float, color: Color, width: float) -> void:
	if not cell is Array or (cell as Array).size() != 2:
		return
	draw_arc(HexUtilsCls.hex_to_pixel(int((cell as Array)[0]), int((cell as Array)[1])), radius, 0.0, TAU, 28, color, width)


func _cross(cell: Variant, half: float, color: Color, width: float) -> void:
	if not cell is Array or (cell as Array).size() != 2:
		return
	var p := HexUtilsCls.hex_to_pixel(int((cell as Array)[0]), int((cell as Array)[1]))
	var d := Vector2(half, half)
	draw_line(p - d, p + d, color, width, true)
	draw_line(p + Vector2(-half, half), p + Vector2(half, -half), color, width, true)
