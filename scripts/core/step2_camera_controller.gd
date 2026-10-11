class_name Step2CameraController
extends Camera2D

## Step2CameraController — Tactical 2D Camera with Mouse Drag, WASD / Arrow Keys, and Wheel Zoom
## Predictable strategy game feel, map bounds clamping, and smooth lerp interpolation.

signal camera_updated(cam_pos: Vector2, zoom_val: float)

@export_group("Limits")
@export var min_zoom: float = 0.35
@export var max_zoom: float = 2.50
@export var zoom_step: float = 0.12
@export var pan_speed: float = 650.0

@export_group("Smoothing")
@export var position_smoothing: float = 14.0
@export var zoom_smoothing: float = 12.0

var target_position: Vector2 = Vector2.ZERO
var target_zoom: float = 1.0

var _is_dragging: bool = false
var _drag_start_mouse: Vector2 = Vector2.ZERO
var _drag_start_cam: Vector2 = Vector2.ZERO

var _has_bounds: bool = false
var _map_min: Vector2 = Vector2.ZERO
var _map_max: Vector2 = Vector2.ZERO
var _bounds_margin: Vector2 = Vector2(160, 120)

func _ready() -> void:
	make_current()
	target_position = global_position
	target_zoom = zoom.x

func set_map_bounds(b_min: Vector2, b_max: Vector2, margin: Vector2 = Vector2(160, 120)) -> void:
	_map_min = b_min - margin
	_map_max = b_max + margin
	_bounds_margin = margin
	_has_bounds = true
	_clamp_bounds()

func focus_on(world_pos: Vector2, instant: bool = false) -> void:
	target_position = world_pos
	if instant:
		global_position = world_pos
	_clamp_bounds()

func set_zoom_level(val: float, instant: bool = false) -> void:
	target_zoom = clampf(val, min_zoom, max_zoom)
	if instant:
		zoom = Vector2(target_zoom, target_zoom)
	_clamp_bounds()

func reset_view() -> void:
	target_zoom = 1.0
	if _has_bounds:
		target_position = (_map_min + _map_max) * 0.5
	else:
		target_position = Vector2.ZERO
	_clamp_bounds()

func _unhandled_input(event: InputEvent) -> void:
	# 1. Mouse Wheel Zoom
	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event as InputEventMouseButton
		if mb.pressed:
			if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
				target_zoom = clampf(target_zoom + zoom_step, min_zoom, max_zoom)
				get_viewport().set_input_as_handled()
			elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				target_zoom = clampf(target_zoom - zoom_step, min_zoom, max_zoom)
				get_viewport().set_input_as_handled()
			elif mb.button_index == MOUSE_BUTTON_RIGHT or mb.button_index == MOUSE_BUTTON_MIDDLE:
				_is_dragging = true
				_drag_start_mouse = get_viewport().get_mouse_position()
				_drag_start_cam = target_position
				get_viewport().set_input_as_handled()
		else:
			if mb.button_index == MOUSE_BUTTON_RIGHT or mb.button_index == MOUSE_BUTTON_MIDDLE:
				_is_dragging = false
	
	# 2. Mouse Drag Motion
	if _is_dragging and event is InputEventMouseMotion:
		var mm: InputEventMouseMotion = event as InputEventMouseMotion
		var delta: Vector2 = mm.position - _drag_start_mouse
		target_position = _drag_start_cam - (delta / target_zoom)
		_clamp_bounds()
		get_viewport().set_input_as_handled()
	
	# 3. Quick Keys
	if event is InputEventKey:
		var ik: InputEventKey = event as InputEventKey
		if ik.pressed and not ik.echo:
			if ik.keycode == KEY_SPACE or ik.keycode == KEY_R:
				reset_view()
				get_viewport().set_input_as_handled()

func _process(delta: float) -> void:
	# 1. Keyboard Pan (WASD + Arrows)
	var move_dir: Vector2 = Vector2.ZERO
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):
		move_dir.x -= 1.0
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
		move_dir.x += 1.0
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):
		move_dir.y -= 1.0
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):
		move_dir.y += 1.0
	
	if move_dir.length_squared() > 0:
		move_dir = move_dir.normalized()
		target_position += move_dir * pan_speed * delta / target_zoom
		_clamp_bounds()
	
	# 2. Smooth Lerp
	var t_pos: float = 1.0 - exp(-position_smoothing * delta)
	global_position = global_position.lerp(target_position, t_pos)
	
	var t_zoom: float = 1.0 - exp(-zoom_smoothing * delta)
	var cur_z: float = lerpf(zoom.x, target_zoom, t_zoom)
	zoom = Vector2(cur_z, cur_z)
	
	camera_updated.emit(global_position, zoom.x)

func _clamp_bounds() -> void:
	if not _has_bounds:
		return
	var vp_size: Vector2 = get_viewport().get_visible_rect().size
	var half_view: Vector2 = vp_size * 0.5 / target_zoom
	
	var min_pos: Vector2 = _map_min + half_view
	var max_pos: Vector2 = _map_max - half_view
	
	if min_pos.x <= max_pos.x:
		target_position.x = clampf(target_position.x, min_pos.x, max_pos.x)
	else:
		target_position.x = (_map_min.x + _map_max.x) * 0.5
	
	if min_pos.y <= max_pos.y:
		target_position.y = clampf(target_position.y, min_pos.y, max_pos.y)
	else:
		target_position.y = (_map_min.y + _map_max.y) * 0.5
