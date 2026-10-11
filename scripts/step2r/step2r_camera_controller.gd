class_name Step2RCameraController
extends Camera2D

## Step2RCameraController — 격리형 전술 카메라 (STEP-2R)
## 정상 줌 범위(NORMAL) 내에서만 동작하며, 외부 전역 시스템과 분리.
##
## NORMAL ZOOM CONTRACT (1920x1080 기준 문서화):
##   NORMAL_MIN_ZOOM  = 0.60  — 가장 넓은 정상 전술 조망 (전체 36x24 + 여백 포함)
##   DEFAULT_ZOOM     = 0.95  — 기본 전술 조망 (운영자 첫 진입 시점)
##   NORMAL_MAX_ZOOM  = 1.85  — 가장 가까운 정상 게임 플레이 줌 (아트 밀도 검증 기준)
## 아트는 NORMAL_MAX_ZOOM에서 더 많은 디테일을 드러내야 하며, 단순 픽셀 확대가 아니어야 한다.
## 디버그 극한 줌은 허용하지 않고 1.85를 하드 상한으로 둔다 (요구 §15 위반 방지).

signal camera_updated(cam_pos: Vector2, zoom_val: float)

# ---- Zoom contract: overview extends to 0.30, close tactical zoom extends to 8.0 ----
# OVERVIEW 0.30-0.84  TACTICAL 0.85-2.00  CLOSE TACTICAL 2.00-8.00 (continuous, no snapping)
const OVERVIEW_MIN_ZOOM: float = 0.30
const NORMAL_MIN_ZOOM: float = 0.85  # tactical min (legacy alias)
const NORMAL_MAX_ZOOM: float = 8.0
const DEFAULT_ZOOM: float = 1.15

@export_group("Limits")
@export var min_zoom: float = OVERVIEW_MIN_ZOOM
@export var max_zoom: float = NORMAL_MAX_ZOOM
@export var zoom_step: float = 0.10
@export var pan_speed: float = 620.0

@export_group("Smoothing")
@export var position_smoothing: float = 16.0
@export var zoom_smoothing: float = 12.0

var target_position: Vector2 = Vector2.ZERO
var target_zoom: float = DEFAULT_ZOOM

var _is_dragging: bool = false
var _drag_button: int = 0
var _drag_start_mouse: Vector2 = Vector2.ZERO
var _drag_start_cam: Vector2 = Vector2.ZERO

var _has_bounds: bool = false
var _map_min: Vector2 = Vector2.ZERO
var _map_max: Vector2 = Vector2.ZERO
var _bounds_margin: Vector2 = Vector2(180, 140)
## Dynamic strategic view (set by the shell when the perspective presentation
## is active): the pan margin beyond the playable map shrinks as you zoom
## out, reaching zero at the commander zoom, so zooming out naturally
## recenters over the battlefield instead of showing off-map forest.
var commander_recenter: bool = false
const RECENTER_ZOOM_FULL_MARGIN: float = 1.0
const RECENTER_ZOOM_NO_MARGIN: float = 0.55
## Optional zoom-toward-cursor solver: Callable(screen_pos, new_zoom) ->
## Variant (new camera target keeping the ground point under the cursor
## fixed, or null over sky). Set by the shell for the perspective view.
var zoom_anchor_solver: Callable = Callable()

## HQ-ANCHORED FRAMING (perspective presentation). When set, the camera
## path is a function of the friendly HQ's LIVE position:
##   position = anchor_provider(current_zoom) + pan_offset
## The provider returns the camera target that puts the HQ at its screen
## anchor for that zoom, so zooming always pivots on the HQ (it never drifts
## during the zoom animation) and the framing follows the HQ if it moves.
## Pan (WASD / drag), focus_on (NEXT unit) and reset (Space / R) act on the
## offset only. Nothing here touches gameplay.
var anchor_provider: Callable = Callable()
var pan_offset: Vector2 = Vector2.ZERO
var _pan_target: Vector2 = Vector2.ZERO
var _drag_start_offset: Vector2 = Vector2.ZERO

func is_anchored() -> bool:
	return anchor_provider.is_valid()

func _anchor_at(z: float) -> Vector2:
	return anchor_provider.call(z)

func _zoom_to(new_zoom: float, cursor: Vector2) -> void:
	new_zoom = clampf(new_zoom, min_zoom, max_zoom)
	if is_anchored():
		target_zoom = new_zoom
		return
	if zoom_anchor_solver.is_valid():
		var t: Variant = zoom_anchor_solver.call(cursor, new_zoom)
		if t != null:
			target_position = t
	target_zoom = new_zoom
	if commander_recenter:
		_clamp_bounds()
# PERF-V1: gate camera_updated so 64 formation markers + badges are not
# re-scaled / re-queued every frame while the camera is stationary.
var _last_emit_pos: Vector2 = Vector2(1e18, 1e18)
var _last_emit_zoom: float = -1.0

func _ready() -> void:
	make_current()
	target_position = global_position
	target_zoom = zoom.x if zoom.x > 0.1 else DEFAULT_ZOOM
	target_zoom = clampf(target_zoom, min_zoom, max_zoom)

func set_map_bounds(b_min: Vector2, b_max: Vector2, margin: Vector2 = Vector2(180, 140)) -> void:
	_map_min = b_min - margin
	_map_max = b_max + margin
	_bounds_margin = margin
	_has_bounds = true
	_clamp_bounds()

func focus_on(world_pos: Vector2, instant: bool = false) -> void:
	if is_anchored():
		_pan_target = world_pos - _anchor_at(target_zoom)
		if instant:
			pan_offset = _pan_target
			global_position = _anchor_at(zoom.x) + pan_offset
			target_position = global_position
		return
	target_position = world_pos
	_clamp_bounds()
	# Instant lands on the CLAMPED target: jumping to the raw point and then
	# easing back inside the bounds reads as a camera drift after every
	# instant focus (and fans out camera_updated for hundreds of frames).
	if instant:
		global_position = target_position

func set_zoom_level(val: float, instant: bool = false) -> void:
	target_zoom = clampf(val, min_zoom, max_zoom)
	if instant:
		zoom = Vector2(target_zoom, target_zoom)
	_clamp_bounds()

## Optional "home" framing (e.g. friendly HQ at bottom-center). When set,
## reset_view() (Space / R) returns here instead of the map center.
var _has_home: bool = false
var _home_position: Vector2 = Vector2.ZERO
var _home_zoom: float = DEFAULT_ZOOM

func set_home_view(world_pos: Vector2, zoom_val: float) -> void:
	_has_home = true
	_home_position = world_pos
	_home_zoom = clampf(zoom_val, min_zoom, max_zoom)

func reset_view() -> void:
	if is_anchored():
		_pan_target = Vector2.ZERO
		target_zoom = _home_zoom if _has_home else target_zoom
		return
	if _has_home:
		target_zoom = _home_zoom
		target_position = _home_position
		_clamp_bounds()
		return
	target_zoom = DEFAULT_ZOOM
	if _has_bounds:
		target_position = (_map_min + _map_max) * 0.5
	else:
		target_position = Vector2.ZERO
	_clamp_bounds()

func get_semantic_zoom_t() -> float:
	return SemanticZoom.zoom_t(zoom.x)

func get_normal_zoom_contract() -> Dictionary:
	return {
		"overview_min": OVERVIEW_MIN_ZOOM,
		"normal_min": NORMAL_MIN_ZOOM,
		"default": DEFAULT_ZOOM,
		"normal_max": NORMAL_MAX_ZOOM,
		"current": target_zoom,
		"min_limit": min_zoom,
		"max_limit": max_zoom,
		"semantic_zoom_t": get_semantic_zoom_t(),
	}

func _unhandled_input(event: InputEvent) -> void:
	# 1. Wheel zoom (proportional steps for smooth navigation from 0.30 to 8.0)
	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event as InputEventMouseButton
		if mb.pressed:
			if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
				var step: float = maxf(0.08, target_zoom * 0.15)
				_zoom_to(target_zoom + step, mb.position)
				get_viewport().set_input_as_handled()
			elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				var step: float = maxf(0.08, target_zoom * 0.15)
				_zoom_to(target_zoom - step, mb.position)
				get_viewport().set_input_as_handled()
			# PRIMARY: left drag on empty battlefield, ALSO middle drag
			elif mb.button_index == MOUSE_BUTTON_LEFT or mb.button_index == MOUSE_BUTTON_MIDDLE:
				_is_dragging = true
				_drag_button = mb.button_index
				_drag_start_mouse = get_viewport().get_mouse_position()
				_drag_start_cam = target_position
				_drag_start_offset = _pan_target
				# grab cursor visual if practical
				if has_method("_update_cursor_grab"):
					Input.set_default_cursor_shape(Input.CURSOR_DRAG)
				get_viewport().set_input_as_handled()
		else:
			if mb.button_index == MOUSE_BUTTON_LEFT or mb.button_index == MOUSE_BUTTON_MIDDLE:
				# only stop if releasing the active drag button (or either)
				if _is_dragging and (mb.button_index == _drag_button or _drag_button == 0):
					_is_dragging = false
					_drag_button = 0
					Input.set_default_cursor_shape(Input.CURSOR_ARROW)

	# 2. Mouse drag motion - immediate tracking
	if _is_dragging and event is InputEventMouseMotion:
		var mm: InputEventMouseMotion = event as InputEventMouseMotion
		var delta: Vector2 = mm.position - _drag_start_mouse
		if not is_zero_approx(rotation):
			# Presentation rotation (DEV sandbox chess-style board): convert the
			# SCREEN drag delta into world space so the board keeps following the
			# cursor. yaw 0 (production) skips this and is byte-identical.
			delta = delta.rotated(rotation)
		if is_anchored():
			_pan_target = _drag_start_offset - (delta / maxf(zoom.x, 0.01))
		else:
			target_position = _drag_start_cam - (delta / target_zoom)
			_clamp_bounds()
		get_viewport().set_input_as_handled()

	# 3. Quick reset
	if event is InputEventKey:
		var ik: InputEventKey = event as InputEventKey
		if ik.pressed and not ik.echo:
			if ik.keycode == KEY_SPACE or ik.keycode == KEY_R:
				reset_view()
				get_viewport().set_input_as_handled()

func _process(delta: float) -> void:
	# Keyboard pan - WASD + arrows, normalized diagonals
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
		if not is_zero_approx(rotation):
			# Presentation rotation (DEV sandbox chess-style board): WASD/arrows
			# stay SCREEN-relative. yaw 0 (production) skips this.
			move_dir = move_dir.rotated(rotation)
		if is_anchored():
			_pan_target += move_dir * pan_speed * delta / maxf(zoom.x, 0.01)
		else:
			target_position += move_dir * pan_speed * delta / target_zoom
			_clamp_bounds()

	var t_pos: float = 1.0 - exp(-position_smoothing * delta)
	var t_zoom: float = 1.0 - exp(-zoom_smoothing * delta)
	var cur_z: float = lerpf(zoom.x, target_zoom, t_zoom)
	zoom = Vector2(cur_z, cur_z)
	if is_anchored():
		# HQ-anchored path evaluated at the CURRENT (smoothed) zoom: the HQ
		# stays exactly on its screen anchor throughout the zoom animation.
		pan_offset = pan_offset.lerp(_pan_target, t_pos)
		var base: Vector2 = _anchor_at(zoom.x)
		var pos: Vector2 = base + pan_offset
		if _has_bounds:
			var clamped := Vector2(clampf(pos.x, _map_min.x, _map_max.x), clampf(pos.y, _map_min.y, _map_max.y))
			if not clamped.is_equal_approx(pos):
				pos = clamped
				pan_offset = pos - base
				_pan_target = pan_offset
		global_position = pos
		target_position = pos
	else:
		# Smooth lerp - no inertia drift when input stops, but responsive
		global_position = global_position.lerp(target_position, t_pos)

	# PERF-V1: emit only on real movement; idle smoothing convergence must not
	# fan out into per-frame unit/badge rescale + marker redraw work.
	if global_position.distance_squared_to(_last_emit_pos) > 0.01 or absf(zoom.x - _last_emit_zoom) > 0.0005:
		_last_emit_pos = global_position
		_last_emit_zoom = zoom.x
		camera_updated.emit(global_position, zoom.x)

func _clamp_bounds() -> void:
	if not _has_bounds or is_anchored():
		return
	var vp_size: Vector2 = get_viewport().get_visible_rect().size
	var half_view: Vector2 = vp_size * 0.5 / target_zoom
	if not is_zero_approx(rotation):
		# Rotated presentation (blue-near-side battle board): clamp against the
		# world-space bounding box of the rotated view (a 90deg yaw reduces to
		# the plain axis swap).
		var c: float = absf(cos(rotation))
		var s: float = absf(sin(rotation))
		half_view = Vector2(c * half_view.x + s * half_view.y, s * half_view.x + c * half_view.y)
	var shrink: Vector2 = Vector2.ZERO
	if commander_recenter:
		shrink = _bounds_margin * (1.0 - smoothstep(RECENTER_ZOOM_NO_MARGIN, RECENTER_ZOOM_FULL_MARGIN, target_zoom))
	var lo: Vector2 = _map_min + shrink
	var hi: Vector2 = _map_max - shrink
	var min_pos: Vector2 = lo + half_view
	var max_pos: Vector2 = hi - half_view
	if min_pos.x <= max_pos.x:
		target_position.x = clampf(target_position.x, min_pos.x, max_pos.x)
	else:
		target_position.x = (lo.x + hi.x) * 0.5
	if min_pos.y <= max_pos.y:
		target_position.y = clampf(target_position.y, min_pos.y, max_pos.y)
	else:
		target_position.y = (lo.y + hi.y) * 0.5
