class_name Cloud2TurnBar
extends CanvasLayer

## Always-visible Step 2 turn control, docked under the top-right turn
## panel. No AI Settings required: mode select (AUTO/STEP/PAUSE), RUN
## CLOUD TURN, live RED stage status, and RETRY/HOLD/SKIP exactly when a
## Cloud decision is awaited. Created by the Cloud2 mount only, so
## production/deterministic battles never see it.

const ThemeCls = preload("res://scripts/visual/historical_ui_theme.gd")

var _controller: Node = null
var _mode_opt: OptionButton = null
var _status_lbl: Label = null
var _run_btn: Button = null
var _retry_btn: Button = null
var _hold_btn: Button = null
var _skip_btn: Button = null


func _init() -> void:
	layer = 40
	name = "Cloud2TurnBar"


func _ready() -> void:
	var panel := PanelContainer.new()
	panel.name = "TurnBarPanel"
	panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	panel.offset_left = -224
	panel.offset_top = 60
	panel.offset_right = -24
	panel.offset_bottom = 224
	panel.add_theme_stylebox_override("panel",
		ThemeCls.create_lacquer_panel(1, 4, ThemeCls.COLOR_GOLD_BORDER))
	add_child(panel)
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_bottom", 8)
	panel.add_child(margin)
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	margin.add_child(vbox)
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 8)
	vbox.add_child(top)
	var cap := Label.new()
	cap.text = "CLOUD"
	cap.add_theme_font_size_override("font_size", 14)
	cap.add_theme_color_override("font_color", ThemeCls.COLOR_GOLD_BRIGHT)
	top.add_child(cap)
	_mode_opt = OptionButton.new()
	_mode_opt.add_item("AUTO", 0)
	_mode_opt.add_item("STEP", 1)
	_mode_opt.add_item("PAUSE", 2)
	_mode_opt.custom_minimum_size = Vector2(108, 28)
	_mode_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_mode_opt.item_selected.connect(_on_mode_selected)
	top.add_child(_mode_opt)
	_status_lbl = Label.new()
	_status_lbl.name = "StatusLabel"
	_status_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_lbl.custom_minimum_size = Vector2(0, 40)
	_status_lbl.add_theme_font_size_override("font_size", 13)
	_status_lbl.add_theme_color_override("font_color", Color(0.92, 0.88, 0.78))
	vbox.add_child(_status_lbl)
	_run_btn = Button.new()
	_run_btn.name = "RunBtn"
	_run_btn.text = "RUN CLOUD TURN"
	_run_btn.custom_minimum_size = Vector2(0, 32)
	_run_btn.pressed.connect(_on_run_pressed)
	vbox.add_child(_run_btn)
	var dec := HBoxContainer.new()
	dec.add_theme_constant_override("separation", 6)
	vbox.add_child(dec)
	_retry_btn = _mk_dec_btn(dec, "RETRY")
	_hold_btn = _mk_dec_btn(dec, "HOLD ALL")
	_skip_btn = _mk_dec_btn(dec, "SKIP")
	_retry_btn.pressed.connect(_on_retry_pressed)
	_hold_btn.pressed.connect(_on_hold_pressed)
	_skip_btn.pressed.connect(_on_skip_pressed)


func _mk_dec_btn(parent: Container, text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, 28)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(b)
	return b


func setup(controller: Node) -> void:
	_controller = controller
	_controller.cloud_state_changed.connect(_on_state)
	_on_state(_controller.get_state())


func current_status_text() -> String:
	return _status_lbl.text if _status_lbl != null else ""


func _on_mode_selected(idx: int) -> void:
	if _controller == null:
		return
	match idx:
		0:
			_controller.set_paused(false)
			_controller.set_mode("AUTO")
		1:
			_controller.set_paused(false)
			_controller.set_mode("STEP")
		_:
			_controller.set_paused(true)


func _on_run_pressed() -> void:
	if _controller != null:
		_controller.request_step()


func _on_retry_pressed() -> void:
	if _controller != null:
		_controller.decide_retry()


func _on_hold_pressed() -> void:
	if _controller != null:
		_controller.decide_hold_all()


func _on_skip_pressed() -> void:
	if _controller != null:
		_controller.decide_skip()


func _on_state(state: Dictionary) -> void:
	if _status_lbl == null:
		return
	var phase := str(state.get("phase", ""))
	var note := str(state.get("note", ""))
	var mode := str(state.get("mode", "AUTO"))
	var paused := bool(state.get("paused", false))
	var active := bool(state.get("phase_active", false))
	var failure_class := str(state.get("failure_class", ""))
	# Mode selector mirrors the controller (programmatic select emits nothing).
	if paused:
		_mode_opt.select(2)
	elif mode == "STEP":
		_mode_opt.select(1)
	else:
		_mode_opt.select(0)
	_status_lbl.text = _status_text(phase, note, mode, paused, active, failure_class)
	var awaiting := phase == "NEEDS_CONFIG" or phase == "WAITING_STEP" \
		or phase.begins_with("FAILED_")
	_run_btn.visible = mode == "STEP" and not paused
	_retry_btn.visible = awaiting and phase != "WAITING_STEP"
	_hold_btn.visible = awaiting
	_skip_btn.visible = awaiting


func _status_text(phase: String, note: String, mode: String, paused: bool, active: bool, failure_class: String = "") -> String:
	var short := note.left(90)
	if paused or phase == "PAUSED":
		return "Cloud paused.\n%s" % short if not short.is_empty() else "Cloud paused."
	if not active:
		if mode == "STEP":
			return "STEP: RUN arms the next RED turn."
		return "Cloud will act automatically."
	match phase:
		"WAITING_STEP":
			return "RED CLOUD — waiting.\nPress RUN CLOUD TURN."
		"NEEDS_CONFIG":
			return "RED CLOUD BLOCKED\n%s" % short
		"OBSERVING":
			return "RED CLOUD\nOBSERVING"
		"THINKING":
			return "RED CLOUD\nTHINKING..."
		"RETRYING":
			return "RED CLOUD\nRETRYING (larger budget)..."
		"VALIDATING":
			return "RED CLOUD\nVALIDATING"
		"EXECUTING":
			return "RED CLOUD — EXECUTING\n%s" % short
		"DONE":
			return "RED CLOUD\nTURN COMPLETE"
		"SKIPPED":
			return "RED CLOUD — SKIPPED"
		_:
			if phase.begins_with("FAILED_"):
				if failure_class == "general_plan":
					return "GENERAL PLAN ERROR\n%s" % phase.trim_prefix("FAILED_")
				return "RED CLOUD ERROR\n%s" % short
			return "RED CLOUD — %s" % phase
