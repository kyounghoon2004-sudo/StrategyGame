extends Camera2D

## CameraController: 2D camera with pan (WASD/edges/mouse drag) + zoom (wheel).
## Features map bounds clamping and smooth lerp movement.

@export_group("Limits")
@export var min_zoom: float = 0.4
@export var max_zoom: float = 3.0
@export var zoom_step: float = 0.12
@export var pan_speed: float = 400.0
@export var edge_scroll_margin: float = 20.0
@export var edge_scroll_speed: float = 300.0

@export_group("Smoothing")
@export var position_smoothing: float = 10.0
@export var zoom_smoothing: float = 8.0

var map_min: Vector2 = Vector2.ZERO
var map_max: Vector2 = Vector2.ZERO
var _has_bounds: bool = false
var target_position: Vector2 = Vector2.ZERO
var target_zoom_level: float = 1.0
var is_dragging: bool = false
var drag_start_mouse: Vector2 = Vector2.ZERO
var drag_start_camera: Vector2 = Vector2.ZERO


func _ready() -> void:
	target_position = global_position
	target_zoom_level = zoom.x
	make_current()


func _unhandled_input(event: InputEvent) -> void:
	# --- Zoom with mouse wheel ---
	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event as InputEventMouseButton
		if mb.pressed:
			if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
				target_zoom_level = clampf(target_zoom_level + zoom_step, min_zoom, max_zoom)
				get_viewport().set_input_as_handled()
			elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				target_zoom_level = clampf(target_zoom_level - zoom_step, min_zoom, max_zoom)
				get_viewport().set_input_as_handled()
			elif mb.button_index == MOUSE_BUTTON_MIDDLE:
				is_dragging = true
				drag_start_mouse = get_viewport().get_mouse_position()
				drag_start_camera = target_position
			elif mb.button_index == MOUSE_BUTTON_RIGHT:
				is_dragging = true
				drag_start_mouse = get_viewport().get_mouse_position()
				drag_start_camera = target_position

	if event is InputEventMouseButton:
		var mb2: InputEventMouseButton = event as InputEventMouseButton
		if not mb2.pressed and (mb2.button_index == MOUSE_BUTTON_MIDDLE or mb2.button_index == MOUSE_BUTTON_RIGHT):
			is_dragging = false

	if is_dragging and event is InputEventMouseMotion:
		var mm: InputEventMouseMotion = event as InputEventMouseMotion
		var delta: Vector2 = mm.position - drag_start_mouse
		# Drag camera opposite to mouse in world space (account for zoom)
		target_position = drag_start_camera - delta / target_zoom_level


func _process(delta: float) -> void:
	# --- Keyboard pan (WASD + arrows) ---
	var dir: Vector2 = Vector2.ZERO
	if Input.is_action_pressed("move_left"):
		dir.x -= 1.0
	if Input.is_action_pressed("move_right"):
		dir.x += 1.0
	if Input.is_action_pressed("move_up"):
		dir.y -= 1.0
	if Input.is_action_pressed("move_down"):
		dir.y += 1.0

	# Normalize diagonal
	if dir.length_squared() > 0:
		dir = dir.normalized()
		target_position += dir * pan_speed * delta / target_zoom_level

	# --- Edge scroll ---
	if not is_dragging:
		var mouse_pos: Vector2 = get_viewport().get_mouse_position()
		var vp_size: Vector2 = get_viewport().get_visible_rect().size
		var edge_dir: Vector2 = Vector2.ZERO
		if mouse_pos.x < edge_scroll_margin:
			edge_dir.x -= 1.0
		elif mouse_pos.x > vp_size.x - edge_scroll_margin:
			edge_dir.x += 1.0
		if mouse_pos.y < edge_scroll_margin:
			edge_dir.y -= 1.0
		elif mouse_pos.y > vp_size.y - edge_scroll_margin:
			edge_dir.y += 1.0
		if edge_dir.length_squared() > 0:
			# Clamp edge scroll to not be too aggressive
			target_position += edge_dir.normalized() * edge_scroll_speed * delta / target_zoom_level

	# --- Smooth lerp to target ---
	var t_pos: float = 1.0 - exp(-position_smoothing * delta)
	global_position = global_position.lerp(target_position, t_pos)

	var t_zoom: float = 1.0 - exp(-zoom_smoothing * delta)
	var cur_zoom: float = zoom.x
	cur_zoom = lerpf(cur_zoom, target_zoom_level, t_zoom)
	zoom = Vector2(cur_zoom, cur_zoom)

	# --- Clamp to map bounds ---
	_clamp_to_bounds()


func set_map_bounds(b_min: Vector2, b_max: Vector2) -> void:
	map_min = b_min
	map_max = b_max
	_has_bounds = true
	_clamp_to_bounds()


func _clamp_to_bounds() -> void:
	if not _has_bounds:
		return
	var vp_size: Vector2 = get_viewport().get_visible_rect().size
	# Visible half-size in world coords
	var half_view: Vector2 = vp_size * 0.5 / zoom.x
	var min_pos: Vector2 = map_min + half_view
	var max_pos: Vector2 = map_max - half_view
	# Only clamp if viewport is smaller than map
	if min_pos.x <= max_pos.x:
		target_position.x = clampf(target_position.x, min_pos.x, max_pos.x)
		global_position.x = clampf(global_position.x, min_pos.x, max_pos.x)
	else:
		var center_x: float = (map_min.x + map_max.x) * 0.5
		target_position.x = center_x
		global_position.x = center_x
	if min_pos.y <= max_pos.y:
		target_position.y = clampf(target_position.y, min_pos.y, max_pos.y)
		global_position.y = clampf(global_position.y, min_pos.y, max_pos.y)
	else:
		var center_y: float = (map_min.y + map_max.y) * 0.5
		target_position.y = center_y
		global_position.y = center_y


func reset_view() -> void:
	target_zoom_level = 1.0
	# Center on map if bounds are set
	if _has_bounds:
		target_position = (map_min + map_max) * 0.5
	else:
		target_position = Vector2.ZERO


func focus_on(world_pos: Vector2) -> void:
	target_position = world_pos
