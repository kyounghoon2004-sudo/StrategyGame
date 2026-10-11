class_name Cloud2Panel
extends VBoxContainer

## CLOUD-GENERAL STEP 2 — CLOUD tab (Cloud RED general console).
##
## Five sections:
##   CLOUD CONNECTION — provider/model/endpoint/key + Test Connection.
##     The human pastes the API key here; it stays in memory only (masked
##     field, normal Ctrl+V, optional Paste button, Test Connection gate).
##   TURN CONTROLS — AUTO/STEP/PAUSE + STEP trigger + RETRY/SKIP/HOLD ALL.
##   CLOUD CONTROL — LEGACY_DIRECT vs MISSION_HIERARCHY switch + manual
##     General review request (hierarchy mode).
##   TURN INSPECTOR — model/turn/latency/snapshot/plan/orders/validation/
##     resolved/compiled/result/summary of the last RED Cloud turn.
##   GENERAL LAB — strategic plan, doctrine, missions, controller traces,
##     review state, and call-count telemetry (hierarchy mode).
##
## Presentation only: all tactics, validation, and execution live in the
## Cloud2TurnController / Cloud2Response / shared Step-1 authorities.

const ConfigCls = preload("res://scripts/cloud2/cloud2_config.gd")
const AdapterCls = preload("res://scripts/cloud2/cloud2_adapter.gd")
const ControllerCls = preload("res://scripts/cloud2/cloud2_turn_controller.gd")
const AISetupScript = preload("res://scripts/ai/ai_setup_panel.gd")
const GeneralPlanCls = preload("res://scripts/cloud2/cloud2_general_plan.gd")
const MissionManagerCls = preload("res://scripts/cloud2/cloud2_mission_manager.gd")
const MissionControllerCls = preload("res://scripts/cloud2/cloud2_mission_controller.gd")
const ModelViewCls = preload("res://scripts/cloud2/cloud2_model_view.gd")

var _controller: ControllerCls = null
var _config: ConfigCls = null
var _adapter: AdapterCls = null

var _provider_opt: OptionButton = null
var _model_edit: LineEdit = null
var _endpoint_edit: LineEdit = null
var _key_edit: LineEdit = null
var _show_btn: Button = null
var _paste_btn: Button = null
var _test_btn: Button = null
var _ai_btn: Button = null
var _conn_status: Label = null
var _gate_status: Label = null
var _effective_lbl: Label = null
var _save_check: CheckBox = null
var _save_btn: Button = null

var _mode_auto_btn: Button = null
var _mode_step_btn: Button = null
var _pause_btn: Button = null
var _step_btn: Button = null
var _retry_btn: Button = null
var _skip_btn: Button = null
var _hold_btn: Button = null
var _phase_label: Label = null

var _view: TextEdit = null
var _ctl_legacy_btn: Button = null
var _ctl_hier_btn: Button = null
var _review_btn: Button = null
var _retry_plan_btn: Button = null
var _model_view_btn: Button = null
var _model_view: Window = null
var _general_view: TextEdit = null
var _bound := false


func _init() -> void:
	add_theme_constant_override("separation", 6)


func setup(controller: ControllerCls, config: ConfigCls, adapter: AdapterCls) -> void:
	_controller = controller
	_config = config
	_adapter = adapter
	_build()
	_wire()
	_bound = true
	refresh_all()


func is_bound() -> bool:
	return _bound


func _wire() -> void:
	_provider_opt.item_selected.connect(_on_provider_selected)
	_model_edit.text_changed.connect(_on_model_changed)
	_endpoint_edit.text_changed.connect(_on_endpoint_changed)
	_key_edit.text_changed.connect(_on_key_changed)
	_show_btn.pressed.connect(_on_show_toggle)
	_paste_btn.pressed.connect(_on_paste)
	_test_btn.pressed.connect(_on_test)
	_ai_btn.pressed.connect(_open_ai_settings)
	_save_btn.pressed.connect(_on_save_local)
	_mode_auto_btn.pressed.connect(_on_mode_auto)
	_mode_step_btn.pressed.connect(_on_mode_step)
	_pause_btn.pressed.connect(_on_pause_toggle)
	_step_btn.pressed.connect(_on_step)
	_retry_btn.pressed.connect(func() -> void: _controller.decide_retry())
	_skip_btn.pressed.connect(func() -> void: _controller.decide_skip())
	_hold_btn.pressed.connect(func() -> void: _controller.decide_hold_all())
	_ctl_legacy_btn.pressed.connect(_on_ctl_legacy)
	_ctl_hier_btn.pressed.connect(_on_ctl_hier)
	_review_btn.pressed.connect(func() -> void: _controller.request_general_review())
	_retry_plan_btn.pressed.connect(_on_retry_plan)
	_model_view_btn.pressed.connect(_on_model_view)
	_controller.cloud_state_changed.connect(_on_state_changed)
	_controller.phase_finished.connect(_on_phase_finished)
	_adapter.test_finished.connect(_on_test_finished)


func refresh_all() -> void:
	_refresh_connection()
	_refresh_controls()
	_refresh_view()
	_update_effective()


## Read-only effective block, generated from the SAME config object the
## adapter consumes (never UI-local variables, never the AI window's disk
## values). This is the arbiter when displays disagree. No key shown.
func _update_effective() -> void:
	if _effective_lbl == null or _config == null:
		return
	var s := _config.effective_snapshot()
	var proto := str(s.get("protocol", ""))
	if proto.is_empty():
		proto = "— (unresolved)"
	_effective_lbl.text = "Provider: %s\nModel: %s\nProtocol: %s\nEndpoint: %s\nConnection: %s%s" % [
		str(s.get("provider_label", "?")) if not str(s.get("provider", "")).is_empty() else "— (not configured)",
		str(s.get("model", "—")) if not str(s.get("model", "")).is_empty() else "—",
		proto,
		str(s.get("endpoint", "—")) if not str(s.get("endpoint", "")).is_empty() else "—",
		str(s.get("connection", "?")),
		" (key: session)" if bool(s.get("has_key", false)) else " (key: none)"]


# --- construction ----------------------------------------------------------

func _section(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 12)
	l.add_theme_color_override("font_color", Color(1.0, 0.72, 0.62))
	return l


func _row(parent: Control, label_text: String) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	parent.add_child(row)
	var lab := Label.new()
	lab.text = label_text
	lab.custom_minimum_size = Vector2(74, 0)
	lab.add_theme_font_size_override("font_size", 12)
	row.add_child(lab)
	return row


func _mini_btn(parent: Control, text: String, tip: String) -> Button:
	var b := Button.new()
	b.text = text
	b.tooltip_text = tip
	b.add_theme_font_size_override("font_size", 12)
	parent.add_child(b)
	return b


func _build() -> void:
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(box)
	# CONNECTION
	box.add_child(_section("CLOUD CONNECTION (RED GENERAL)"))
	var r1: Control = _row(box, "PROVIDER")
	_provider_opt = OptionButton.new()
	_provider_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_provider_opt.add_theme_font_size_override("font_size", 12)
	for pid in ConfigCls.provider_ids():
		_provider_opt.add_item(ConfigCls.provider_label(pid))
		_provider_opt.set_item_metadata(_provider_opt.item_count - 1, pid)
	r1.add_child(_provider_opt)
	var r2: Control = _row(box, "MODEL")
	_model_edit = LineEdit.new()
	_model_edit.placeholder_text = "model id (editable)"
	_model_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_model_edit.add_theme_font_size_override("font_size", 12)
	r2.add_child(_model_edit)
	var r2b: Control = _row(box, "ENDPOINT")
	_endpoint_edit = LineEdit.new()
	_endpoint_edit.placeholder_text = "https://... (auto per provider)"
	_endpoint_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_endpoint_edit.add_theme_font_size_override("font_size", 11)
	r2b.add_child(_endpoint_edit)
	var r3: Control = _row(box, "API KEY")
	_key_edit = LineEdit.new()
	_key_edit.placeholder_text = "paste key (session only, never stored)"
	_key_edit.secret = true
	_key_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_key_edit.add_theme_font_size_override("font_size", 12)
	r3.add_child(_key_edit)
	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 6)
	box.add_child(btn_row)
	_paste_btn = _mini_btn(btn_row, "Paste", "Paste the clipboard into the masked key field.")
	_show_btn = _mini_btn(btn_row, "Show", "Show/hide the key.")
	_show_btn.toggle_mode = true
	_test_btn = _mini_btn(btn_row, "Test Connection", "Smallest valid provider request. Touches no battle state.")
	_ai_btn = _mini_btn(btn_row, "AI 설정", "Open the shared AI Settings window (OpenCode Go discovery, protocol, Context/Chat/Tools).")
	_conn_status = Label.new()
	_conn_status.add_theme_font_size_override("font_size", 12)
	_conn_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_conn_status)
	_gate_status = Label.new()
	_gate_status.add_theme_font_size_override("font_size", 11)
	_gate_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_gate_status)
	var save_row := HBoxContainer.new()
	save_row.add_theme_constant_override("separation", 6)
	box.add_child(save_row)
	_save_check = CheckBox.new()
	_save_check.text = "Remember provider/model locally"
	_save_check.tooltip_text = "Explicit opt-in: saves provider/model/endpoint to user:// (outside the repo). The API key is NEVER stored."
	_save_check.add_theme_font_size_override("font_size", 11)
	save_row.add_child(_save_check)
	_save_btn = _mini_btn(save_row, "Save", "Save non-secret connection fields locally (never the key).")
	# EFFECTIVE (read-only, from the adapter's own config object).
	box.add_child(_section("EFFECTIVE CLOUD BACKEND"))
	_effective_lbl = Label.new()
	_effective_lbl.add_theme_font_size_override("font_size", 11)
	_effective_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_effective_lbl.add_theme_color_override("font_color", Color(0.75, 0.78, 0.82))
	box.add_child(_effective_lbl)
	# CONTROLS
	box.add_child(_section("TURN CONTROLS"))
	var mode_row := HBoxContainer.new()
	mode_row.add_theme_constant_override("separation", 6)
	box.add_child(mode_row)
	_mode_auto_btn = _mini_btn(mode_row, "AUTO CLOUD", "Cloud acts automatically when the RED turn begins.")
	_mode_auto_btn.toggle_mode = true
	_mode_step_btn = _mini_btn(mode_row, "STEP CLOUD", "STEP mode: arm exactly one Cloud turn / trigger the waiting turn.")
	_mode_step_btn.toggle_mode = true
	_pause_btn = _mini_btn(mode_row, "PAUSE", "Pause at the next safe boundary (model call / order).")
	_pause_btn.toggle_mode = true
	_step_btn = _mini_btn(mode_row, "TRIGGER", "Trigger the waiting STEP turn now.")
	var dec_row := HBoxContainer.new()
	dec_row.add_theme_constant_override("separation", 6)
	box.add_child(dec_row)
	_retry_btn = _mini_btn(dec_row, "RETRY", "Retry the Cloud turn (nothing executed yet).")
	_skip_btn = _mini_btn(dec_row, "SKIP", "Skip the RED Cloud phase (no orders).")
	_hold_btn = _mini_btn(dec_row, "HOLD ALL", "Deterministic HOLD-all fallback (no model tactics).")
	_phase_label = Label.new()
	_phase_label.add_theme_font_size_override("font_size", 12)
	_phase_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_phase_label)
	# CLOUD CONTROL (compatibility switch; temporary benchmark path)
	box.add_child(_section("CLOUD CONTROL"))
	var ctl_row := HBoxContainer.new()
	ctl_row.add_theme_constant_override("separation", 6)
	box.add_child(ctl_row)
	_ctl_legacy_btn = _mini_btn(ctl_row, "LEGACY DIRECT LLM CONTROL", "Regression/debug only: per-turn tactical Cloud inference. NOT the canonical DEV path.")
	_ctl_legacy_btn.toggle_mode = true
	_ctl_hier_btn = _mini_btn(ctl_row, "HIERARCHICAL GENERAL", "Canonical DEV path: persistent Cloud General plan executed by deterministic mission controllers.")
	_ctl_hier_btn.toggle_mode = true
	_review_btn = _mini_btn(ctl_row, "REQUEST REVIEW", "Force a General review on the next hierarchy RED turn.")
	_retry_plan_btn = _mini_btn(ctl_row, "RETRY PLAN", "Re-arm a FAILED initial VictoryPlan generation and prefetch immediately from live state.")
	_model_view_btn = _mini_btn(ctl_row, "MODEL VIEW", "Open the floating CLOUD GENERAL — MODEL VIEW window (exact request/response history).")
	# INSPECTOR
	box.add_child(_section("TURN INSPECTOR"))
	_view = TextEdit.new()
	_view.editable = false
	_view.custom_minimum_size = Vector2(0, 260)
	_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_view.add_theme_font_size_override("font_size", 11)
	var mono := SystemFont.new()
	mono.font_names = PackedStringArray(["Consolas", "Menlo", "monospace"])
	_view.add_theme_font_override("font", mono)
	box.add_child(_view)
	# GENERAL LAB (hierarchy observability)
	box.add_child(_section("GENERAL LAB"))
	_general_view = TextEdit.new()
	_general_view.editable = false
	_general_view.custom_minimum_size = Vector2(0, 220)
	_general_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_general_view.add_theme_font_size_override("font_size", 11)
	_general_view.add_theme_font_override("font", mono)
	box.add_child(_general_view)


# --- connection ------------------------------------------------------------

func _refresh_connection() -> void:
	if _config == null:
		return
	for i in range(_provider_opt.item_count):
		if str(_provider_opt.get_item_metadata(i)) == _config.provider_id:
			_provider_opt.select(i)
			break
	if _model_edit.text.is_empty() and not _config.model.is_empty():
		_model_edit.text = _config.model
	if _config.is_opencode():
		# OpenCode Go endpoints are derived per model — always mirror, never type.
		_endpoint_edit.text = _config.endpoint
		_endpoint_edit.editable = false
		_endpoint_edit.placeholder_text = "auto (per-model protocol — use AI 설정 discovery)"
	elif _endpoint_edit.text.is_empty() and not _config.endpoint.is_empty():
		_endpoint_edit.text = _config.endpoint
	if not _config.is_opencode():
		_endpoint_edit.editable = true
		_endpoint_edit.placeholder_text = "https://... (auto per provider)"
	_update_conn_status()
	_update_gate()


func _update_conn_status() -> void:
	var s := _config.connection_status
	_conn_status.text = "CONNECTION: %s%s" % [s, (" — " + _config.connection_note) if not _config.connection_note.is_empty() else ""]
	if _config.is_opencode():
		if _config.is_protocol_resolved():
			_conn_status.text += "\nPROTOCOL: %s (from %s)" % [_config.resolved_transport, _config.protocol_source]
		else:
			_conn_status.text += "\nPROTOCOL: UNSUPPORTED / UNKNOWN — open AI 설정"
	match s:
		"CONNECTED":
			_conn_status.add_theme_color_override("font_color", Color(0.55, 0.9, 0.6))
		"TESTING":
			_conn_status.add_theme_color_override("font_color", Color(0.95, 0.8, 0.4))
		"ERROR":
			_conn_status.add_theme_color_override("font_color", Color(1.0, 0.5, 0.45))
		_:
			_conn_status.add_theme_color_override("font_color", Color(0.62, 0.66, 0.7))


func _update_gate() -> void:
	var g := _config.validate_for_start()
	if bool(g.get("ok", false)):
		_gate_status.text = "START GATE: READY — Cloud turns may run."
		_gate_status.add_theme_color_override("font_color", Color(0.55, 0.9, 0.6))
	else:
		_gate_status.text = "START GATE: %s — %s" % [str(g.get("code", "")), str(g.get("detail", ""))]
		_gate_status.add_theme_color_override("font_color", Color(0.95, 0.8, 0.4))
	_update_effective()


func _on_provider_selected(idx: int) -> void:
	var pid := str(_provider_opt.get_item_metadata(idx))
	_config.set_provider(pid)
	_endpoint_edit.text = _config.endpoint
	if _model_edit.text.strip_edges().is_empty():
		var models := ConfigCls.default_models_for(pid)
		if not models.is_empty() and not str(models[0]).is_empty():
			_model_edit.text = str(models[0])
			_config.set_model(_model_edit.text)
	_update_conn_status()
	_update_gate()


func _on_model_changed(t: String) -> void:
	_config.set_model(t)
	if _config.is_opencode():
		_endpoint_edit.text = _config.endpoint # derived endpoint follows the model
	_update_conn_status()
	_update_gate()


func _on_endpoint_changed(t: String) -> void:
	_config.set_endpoint(t)
	_update_conn_status()
	_update_gate()


func _on_key_changed(t: String) -> void:
	_config.set_api_key(t)
	_update_conn_status()
	_update_gate()


func _on_show_toggle() -> void:
	_key_edit.secret = not _show_btn.button_pressed
	_show_btn.text = "Hide" if _show_btn.button_pressed else "Show"


func _on_paste() -> void:
	var clip := DisplayServer.clipboard_get().strip_edges(true, true)
	if clip.is_empty():
		return
	_key_edit.text = clip
	_config.set_api_key(clip)
	_update_conn_status()
	_update_gate()


func _on_test() -> void:
	if not _config.is_configured():
		_config.mark_test_result(false, "ERROR", "Fill provider, model, endpoint, and key first.")
		_update_conn_status()
		_update_gate()
		return
	_config.mark_test_result(false, "TESTING", "Contacting provider...")
	_update_conn_status()
	var res := _adapter.test_connection(_config)
	if not bool(res.get("ok", false)):
		_config.mark_test_result(false, "ERROR", str(res.get("detail", "Test failed to start.")))
		_update_conn_status()
		_update_gate()


func _on_test_finished(result: Dictionary) -> void:
	if bool(result.get("ok", false)):
		_config.mark_test_result(true, "CONNECTED", "%s · %d ms" % [_config.model, int(result.get("latency_ms", 0))])
		# V3: backend just became READY — fire an armed boot prefetch from
		# the frozen opening snapshot (local event; exactly once).
		if _controller != null and _controller.has_method("victory_backend_ready"):
			_controller.victory_backend_ready()
	else:
		_config.mark_test_result(false, "ERROR", _friendly_error(result))
	_update_conn_status()
	_update_gate()


func _friendly_error(result: Dictionary) -> String:
	match str(result.get("code", "")):
		"UNAUTHORIZED":
			return "INVALID API KEY"
		"TIMEOUT":
			return "TIMEOUT"
		"RATE_LIMITED":
			return "RATE LIMITED"
		"MODEL_MISSING":
			return "MODEL/ENDPOINT NOT FOUND"
		"OFFLINE":
			return "OFFLINE — provider unreachable"
		"BAD_RESPONSE":
			return "BAD RESPONSE from provider"
		"RESPONSE_TOO_LARGE":
			return "RESPONSE TOO LARGE from provider"
		"NON_JSON_ENVELOPE":
			return "NON-JSON RESPONSE from provider"
		"STREAMING_RESPONSE_DETECTED":
			return "STREAMING RESPONSE (expected one JSON body)"
		"EMPTY_MODEL_CONTENT":
			return "EMPTY MODEL REPLY (no text)"
		"REASONING_BUDGET_EXHAUSTED":
			return "OUTPUT BUDGET SPENT ON REASONING (no final text)"
		"FINISH_LENGTH_NO_FINAL":
			return "OUTPUT CUT OFF (length) with no final text"
		"MODEL_REFUSAL":
			return "MODEL REFUSED the request"
		"TOOL_CALLS_NO_TEXT":
			return "TOOL CALLS with no final text"
		"UNSUPPORTED_RESPONSE_SHAPE":
			return "UNSUPPORTED RESPONSE SHAPE from provider"
		"CLOUD_NOT_CONFIGURED":
			return "CLOUD NOT CONFIGURED"
		"REQUEST_IN_FLIGHT":
			return "BUSY — another Cloud request is still in flight"
		"UNSUPPORTED_PROTOCOL", "PROTOCOL_ERROR":
			return "PROTOCOL ERROR — unknown OpenCode Go model protocol"
		"INVALID_REQUEST":
			return "INVALID REQUEST BODY — %s" % _provider_msg(result)
		"UNSUPPORTED_FIELD":
			return "UNSUPPORTED FIELD — %s" % _provider_msg(result)
		"REGION_RESTRICTED":
			return "REGION RESTRICTED — %s" % _provider_msg(result)
		"MODEL_ACCESS_DENIED":
			return "MODEL ACCESS DENIED — %s" % _provider_msg(result)
	return "PROVIDER ERROR — %s" % str(result.get("detail", ""))


func _provider_msg(result: Dictionary) -> String:
	var m := str(result.get("provider_message", "")).strip_edges()
	if m.is_empty():
		m = str(result.get("detail", "")).strip_edges()
	if m.length() > 220:
		m = m.left(220) + "..."
	return m if not m.is_empty() else "(no provider message)"


## The SAME AI Settings window as the title screen, bound to this live
## Cloud stack (adjust-mode: apply in place, never change scenes).
func _open_ai_settings() -> void:
	var scene := get_tree().current_scene
	if scene == null:
		return
	# Topmost layer: the HUD lives at layer 30 and the dock overlaps a
	# centered 700px dialog on narrow windows — the modal must sit above
	# every battle control to receive its own input.
	var layer := scene.get_node_or_null("AISetupLayerCloud") as CanvasLayer
	if layer == null or not is_instance_valid(layer):
		layer = CanvasLayer.new()
		layer.name = "AISetupLayerCloud"
		layer.layer = 100
		scene.add_child(layer)
	var panel: Control = layer.get_node_or_null("AISetupPanelCloud") as Control
	if panel == null or not is_instance_valid(panel):
		panel = AISetupScript.new()
		panel.name = "AISetupPanelCloud"
		layer.add_child(panel)
	# The AI window edits the live config in place; re-mirror every field
	# (model/endpoint/protocol/effective block) when it applies or closes.
	if not panel.is_connected("config_applied", refresh_all):
		panel.connect("config_applied", refresh_all)
	if not panel.is_connected("panel_closed", refresh_all):
		panel.connect("panel_closed", refresh_all)
	panel.set("adjust_mode", true)
	panel.call("open_for_cloud", _config, _controller, _adapter)
	refresh_all()


func _on_save_local() -> void:
	if not _save_check.button_pressed:
		_gate_status.text = "SAVE: tick the opt-in box first (key is never stored)."
		return
	var res := _config.save_local_settings()
	_gate_status.text = "SAVE: %s" % str(res.get("detail", ""))


# --- controls ----------------------------------------------------------------

func _refresh_controls() -> void:
	if _controller == null:
		return
	_mode_auto_btn.button_pressed = _controller.get_mode() == "AUTO"
	_mode_step_btn.button_pressed = _controller.get_mode() == "STEP"
	_pause_btn.button_pressed = _controller.is_paused()
	_ctl_legacy_btn.button_pressed = _controller.get_control_mode() == "LEGACY_DIRECT"
	_ctl_hier_btn.button_pressed = _controller.get_control_mode() == "MISSION_HIERARCHY"
	_review_btn.disabled = _controller.get_control_mode() != "MISSION_HIERARCHY"
	_refresh_retry_plan()
	_on_state_changed(_controller.get_state())


## Repair V1: RETRY PLAN is armed exactly when no VictoryPlan exists and
## the initial latch sits FAILED (or never started with a backend now
## available). Disabled while a request is in flight or a plan is bound.
func _refresh_retry_plan() -> void:
	if _retry_plan_btn == null or _controller == null:
		return
	if not _controller.has_method("victory_initial_status") or not _controller.has_method("get_victory_plan_view"):
		_retry_plan_btn.disabled = true
		return
	var view: Dictionary = _controller.get_victory_plan_view()
	if bool(view.get("has_plan", false)):
		_retry_plan_btn.disabled = true
		return
	var st := str((_controller.victory_initial_status() as Dictionary).get("state", "NOT_STARTED"))
	_retry_plan_btn.disabled = not (st == "FAILED" or st == "NOT_STARTED")


func _on_retry_plan() -> void:
	if _controller != null and _controller.has_method("victory_retry_initial"):
		var res: Dictionary = _controller.victory_retry_initial()
		print("[Cloud2Panel] RETRY PLAN ok=%s started=%s reason=%s" % [str(bool(res.get("ok", false))),
			str(bool(res.get("started", false))), str(res.get("reason", res.get("code", "")))])
	_refresh_retry_plan()
	refresh_all()


func _on_ctl_legacy() -> void:
	_controller.set_control_mode("LEGACY_DIRECT")
	_refresh_controls()


func _on_ctl_hier() -> void:
	_controller.set_control_mode("MISSION_HIERARCHY")
	_refresh_controls()


## Floating DEV Model View: one shared window, rebound to the live
## controller on every open. Hidden on close; history lives on.
func _on_model_view() -> void:
	if _model_view != null and is_instance_valid(_model_view):
		_model_view.call("bind_controller", _controller)
		(_model_view as Window).show()
		(_model_view as Window).move_to_foreground()
		return
	_model_view = ModelViewCls.new()
	if get_tree() != null:
		get_tree().root.add_child(_model_view)
	else:
		add_child(_model_view)
	_model_view.call("bind_controller", _controller)
	(_model_view as Window).show()


func _on_mode_auto() -> void:
	_controller.set_mode("AUTO")
	_refresh_controls()


func _on_mode_step() -> void:
	_controller.set_mode("STEP")
	_refresh_controls()


func _on_pause_toggle() -> void:
	_controller.set_paused(_pause_btn.button_pressed)
	_refresh_controls()


func _on_step() -> void:
	_controller.request_step()


func _on_state_changed(state: Dictionary) -> void:
	var phase := str(state.get("phase", "IDLE"))
	var note := str(state.get("note", ""))
	_phase_label.text = "[%s] %s" % [phase, note]
	match phase:
		"DONE", "SKIPPED", "HOLD_ALL":
			_phase_label.add_theme_color_override("font_color", Color(0.55, 0.9, 0.6))
		"THINKING", "EXECUTING", "VALIDATING", "OBSERVING":
			_phase_label.add_theme_color_override("font_color", Color(0.55, 0.85, 1.0))
		"PAUSED", "WAITING_STEP", "NEEDS_CONFIG":
			_phase_label.add_theme_color_override("font_color", Color(0.95, 0.8, 0.4))
		_:
			if phase.begins_with("FAILED"):
				_phase_label.add_theme_color_override("font_color", Color(1.0, 0.5, 0.45))
			else:
				_phase_label.add_theme_color_override("font_color", Color(0.62, 0.66, 0.7))
	var waiting := phase in ["WAITING_STEP", "NEEDS_CONFIG"] or phase.begins_with("FAILED")
	_retry_btn.disabled = not waiting
	_skip_btn.disabled = not waiting
	_hold_btn.disabled = not waiting
	_step_btn.disabled = phase != "WAITING_STEP"
	_pause_btn.disabled = not bool(state.get("phase_active", false))
	_refresh_view()


func _on_phase_finished(_result: Dictionary) -> void:
	_refresh_controls()
	_refresh_view()


# --- inspector ---------------------------------------------------------------

func _refresh_view() -> void:
	if _controller == null or _view == null:
		return
	_view.text = render_turn_view(_controller.get_last_view(), _controller.get_state())
	if _general_view != null:
		_general_view.text = render_general_view(_controller.get_general_view())


## General Lab rendering (presentation only; no secrets pass through —
## plans carry missions/doctrine, never keys or hidden reasoning).
## Layout mirrors the architecture: GENERAL (Cloud-owned plan) vs LOCAL
## EXECUTION (Godot-owned scoring, compiler checks, execution results).
static func render_general_view(general: Dictionary) -> String:
	if str(general.get("control_mode", "")) == "LEGACY_DIRECT" and (general.get("plan", {}) as Dictionary).is_empty():
		return "GENERAL LAB (LEGACY DIRECT LLM CONTROL active — regression path).\nSwitch CLOUD CONTROL to HIERARCHICAL GENERAL, then END TURN as BLUE."
	var lines: Array = []
	var plan: Dictionary = general.get("plan", {})
	var tel: Dictionary = general.get("telemetry", {})
	var last: Dictionary = tel.get("last_review", {})
	lines.append("--- GENERAL (Cloud owns the plan) ---")
	lines.append("Model: %s · %s" % [str(general.get("provider", "?")), str(general.get("model", "?"))])
	lines.append("Control: %s | staged=%s in_flight=%s" % [
		str(general.get("control_mode", "?")),
		"yes" if bool(general.get("staged", false)) else "no",
		"yes" if bool(general.get("review_in_flight", false)) else "no"])
	var wake: Dictionary = general.get("wakeup", {})
	if not wake.is_empty():
		lines.append("Wake: pending=%s events=%d kinds=%s" % [
			"YES" if bool(wake.get("review_pending", false)) else "NO",
			int(wake.get("pending_event_count", 0)),
			",".join(wake.get("pending_event_kinds", [])) if not (wake.get("pending_event_kinds", []) as Array).is_empty() else "-"])
		var last_wake: Dictionary = wake.get("last_review", {})
		if not last_wake.is_empty():
			lines.append("Last wake: trigger=%s count=%d decision=%s result=%s plan_v%s" % [
				str(last_wake.get("trigger", "-")), int(last_wake.get("event_count", 0)),
				str(last_wake.get("decision", "-")), str(last_wake.get("status", last_wake.get("result", "-"))),
				str(last_wake.get("plan_version", "-"))])
	if GeneralPlanCls.has_plan(plan):
		var c: Dictionary = plan.get("concept", {})
		var d: Dictionary = plan.get("doctrine", {})
		lines.append("Plan: v%d (supersedes v%d) src=%s created_t%d reviewed_t%d" % [
			int(plan.get("plan_version", 0)), int(plan.get("supersedes_version", 0)),
			str(plan.get("source", "?")), int(plan.get("created_turn", 0)),
			int(plan.get("last_review_turn", 0))])
		lines.append("Intent: %s" % (str(c.get("intent", "-")) if not str(c.get("intent", "")).is_empty() else "-"))
		lines.append("Main effort: %s" % (str(c.get("main_effort", "-")) if not str(c.get("main_effort", "")).is_empty() else "-"))
		lines.append("Doctrine: agg=%.2f risk=%.2f tempo=%.2f pursuit=%.2f reserve=%.2f deception=%.2f" % [
			float(d.get("aggression", 0.5)), float(d.get("risk_tolerance", 0.5)),
			float(d.get("tempo", 0.5)), float(d.get("pursuit", 0.5)),
			float(d.get("reserve_discipline", 0.5)), float(d.get("deception", 0.0))])
		lines.append("Last review: turn %s (%s, %s)" % [
			str(last.get("turn", "-")), str(last.get("trigger", "-")), str(last.get("disposition", "-"))])
		lines.append("Next review: %s" % _next_review_text(plan, int(general.get("current_turn", 0))))
	else:
		lines.append("Plan: (none yet — initial General plan pending)")
		lines.append("Next review: INITIAL_PLAN on the first configured RED turn")
	lines.append("--- PLAN ---")
	lines.append(GeneralPlanCls.render_summary(plan))
	lines.append("--- MISSIONS (Cloud-assigned) ---")
	var statuses: Array = general.get("statuses", [])
	lines.append(MissionManagerCls.render_statuses(statuses) if not statuses.is_empty() else "(no mission statuses yet)")
	lines.append("--- LOCAL EXECUTION (Godot decides the move) ---")
	lines.append(render_local_execution(general.get("traces", []), general.get("execution", [])))
	var review: Dictionary = general.get("review", {})
	lines.append("--- REVIEW ---")
	lines.append("requested=%s trigger=%s reason=%s" % [
		str(bool(review.get("requested", false))), str(review.get("trigger", "-")), str(review.get("reason", "-"))])
	if not tel.is_empty():
		lines.append("--- TELEMETRY ---")
		lines.append("calls=%d (%.2f/10t) avg_lat=%dms | RED llm=%d nollm=%d | decisions=%d" % [
			int(tel.get("general_calls", 0)), float(tel.get("general_calls_per_10_turns", 0.0)),
			int(tel.get("average_general_latency_ms", 0)),
			int(tel.get("turns_with_llm", 0)), int(tel.get("turns_without_llm", 0)),
			int(tel.get("controller_decisions", 0))])
		lines.append("plans applied=%d staged=%d stale=%d rejected=%d" % [
			int(tel.get("plans_applied", 0)), int(tel.get("plans_staged", 0)),
			int(tel.get("plans_stale", 0)), int(tel.get("plans_rejected", 0))])
		lines.append("last_review turn=%s trigger=%s latency=%sms disposition=%s plan_v%s snapshot=%s" % [
			str(last.get("turn", "-")), str(last.get("trigger", "-")), str(last.get("latency_ms", "-")),
			str(last.get("disposition", "-")), str(last.get("plan_version", "-")), str(last.get("snapshot", "-")).left(40)])
		if not str(last.get("code", "")).is_empty():
			lines.append("last_review code=%s (transport SUCCESS with this code = plan rejected, not a network failure)" % str(last.get("code", "")))
		var coord: Dictionary = general.get("coordination", {})
		if not coord.is_empty():
			var cparts: Array = []
			for gid in (coord.get("choices", {}) as Dictionary).keys():
				cparts.append("%s->%s" % [str(gid), str((coord.get("choices", {}) as Dictionary)[gid])])
			cparts.sort()
			lines.append("Coord: %s" % " ".join(cparts))
			var cwarns: Array = coord.get("warnings", []) as Array
			if not cwarns.is_empty():
				lines.append("Coord warnings (%d): %s" % [cwarns.size(), str(cwarns[0]).left(90)])
		lines.append("replan_triggers=%s" % JSON.stringify(tel.get("replan_triggers", {})))
	return "\n".join(lines)


## Next-review line: plan review_conditions plus the periodic horizon
## countdown from the last review turn.
static func _next_review_text(plan: Dictionary, current_turn: int) -> String:
	var conds: Array = []
	for c_val in (plan.get("review_conditions", []) as Array):
		if c_val is Dictionary and not str((c_val as Dictionary).get("trigger", "")).is_empty():
			conds.append(str((c_val as Dictionary).get("trigger", "")))
	var horizon := int(plan.get("review_horizon_turns", 0))
	var last_rev := int(plan.get("last_review_turn", 0))
	var due_in := last_rev + horizon - current_turn
	var parts: Array = []
	if not conds.is_empty():
		parts.append("on %s" % ",".join(conds))
	if horizon > 0:
		parts.append("horizon in %d turn(s) (t%d)" % [maxi(0, due_in), last_rev + horizon])
	if parts.is_empty():
		return "-"
	return " + ".join(parts)


## Local-execution block: per mission, the scored candidates, the chosen
## local move, its compiler check, and its execution result. Makes it
## obvious the Cloud chose the mission and Godot chose the move.
static func render_local_execution(traces: Array, execution: Array) -> String:
	if traces.is_empty():
		return "(no controller decisions yet)"
	var exec_by_mission := {}
	for e_val in execution:
		if e_val is Dictionary:
			exec_by_mission[str((e_val as Dictionary).get("mission_id", "?"))] = e_val
	var blocks: Array = []
	for t_val in traces:
		if not t_val is Dictionary:
			continue
		var t: Dictionary = t_val
		var mid := str(t.get("mission_id", "?"))
		var bl: Array = []
		bl.append("MISSION %s (%s) ready=[%s]" % [mid, str(t.get("task", "?")),
			",".join(t.get("ready_units", []))])
		bl.append("Candidates:")
		for c_val in (t.get("candidates", []) as Array):
			if not c_val is Dictionary:
				continue
			var c: Dictionary = c_val
			if bool(c.get("feasible", false)):
				bl.append("  %-24s %5.1f" % [str(c.get("label", "?")), float(c.get("score", 0.0))])
			else:
				bl.append("  %-24s INFEASIBLE(%s)" % [str(c.get("label", "?")), str(c.get("code", "?"))])
		var chosen := str(t.get("chosen", "?"))
		bl.append("Chosen: %s%s" % [chosen, " (seeded tie-break)" if bool(t.get("rolled", false)) else ""])
		bl.append("Compiler: %s" % _chosen_compiler_text(t, chosen))
		if exec_by_mission.has(mid):
			var ex: Dictionary = exec_by_mission[mid]
			bl.append("Execution: %s (exec=%d failed=%d plan_failed=%d)" % [
				str(ex.get("status", "?")), int(ex.get("executed", 0)),
				int(ex.get("failed", 0)), int(ex.get("plan_failed", 0))])
		else:
			bl.append("Execution: (pending)")
		if not str(t.get("reason", "")).is_empty():
			bl.append("note: %s" % str(t.get("reason", "")))
		for u_val in (t.get("units", []) as Array):
			if u_val is Dictionary:
				bl.append(_unit_options_line(u_val))
		blocks.append("\n".join(bl))
	return "\n".join(blocks)


## One unit's six class options on compact lines: every slot with its
## score or mask, then the selection + resolution. This is the primary
## WHAT-GODOT-DID readout (the Cloud chose the mission above).
static func _unit_options_line(t: Dictionary) -> String:
	var cells: Array = []
	for o_val in (t.get("options", []) as Array):
		if not o_val is Dictionary:
			continue
		var o: Dictionary = o_val
		var star := ""
		if int(o.get("slot", -2)) == int(t.get("selected_slot", -1)):
			star = "*"
		if bool(o.get("masked", false)):
			cells.append("[%d] %s MASKED(%s)%s" % [int(o.get("slot", -1)),
				str(o.get("option_id", "?")), str(o.get("mask_reason", "?")), star])
		else:
			cells.append("[%d] %s %.1f%s" % [int(o.get("slot", -1)),
				str(o.get("option_id", "?")), float(o.get("final_score", 0.0)), star])
	var sel := "UNIT %s (%s): %s" % [str(t.get("unit_id", "?")),
		str(t.get("unit_class", "?")), " | ".join(cells)]
	var cmd: Dictionary = t.get("resolved_command", {})
	var res := "  SELECTED %s -> %s %s compiler=%s" % [str(t.get("selected_id", "?")),
		str(cmd.get("action", "-")), _cmd_target_text(cmd), str(t.get("compiler", "?"))]
	var scores: Array = t.get("target_scores", [])
	if not scores.is_empty():
		var tops: Array = []
		for s_val in scores.slice(0, 3):
			tops.append("%s %.0f" % [str((s_val as Dictionary).get("target_id", "?")),
				float((s_val as Dictionary).get("score", 0.0))])
		res += " targets=[%s]" % ", ".join(tops)
	var dest: Array = t.get("resolved_destination", [])
	if not dest.is_empty():
		res += " dest=%s" % JSON.stringify(dest)
	return sel + "\n" + res


static func _cmd_target_text(cmd: Dictionary) -> String:
	var tgt: Dictionary = cmd.get("target", {})
	if tgt.is_empty():
		return ""
	if not str(tgt.get("unit_id", "")).is_empty():
		return str(tgt.get("unit_id", ""))
	if not str(tgt.get("direction", "")).is_empty():
		return str(tgt.get("direction", ""))
	if not str(tgt.get("zone", "")).is_empty():
		return "ZONE(%s)" % str(tgt.get("zone", ""))
	return JSON.stringify(tgt)


static func _chosen_compiler_text(trace: Dictionary, chosen: String) -> String:
	for c_val in (trace.get("candidates", []) as Array):
		if c_val is Dictionary and str((c_val as Dictionary).get("label", "?")) == chosen:
			if bool((c_val as Dictionary).get("feasible", false)):
				return "PASS (dry-run planned %d)" % int((c_val as Dictionary).get("planned_count", 0))
			return "INFEASIBLE(%s)" % str((c_val as Dictionary).get("code", "?"))
	return "(no candidate row)"


static func render_turn_view(view: Dictionary, state: Dictionary) -> String:
	if view.is_empty():
		return "No Cloud turn yet.\n\n1. CLOUD CONNECTION: choose provider/model, paste key, Test Connection.\n2. Play BLUE, then END TURN.\n3. STEP mode: press TRIGGER when the RED turn waits.\n4. Inspect every order below (validation -> resolved -> compiled -> result)."
	var lines: Array = []
	lines.append("MODEL %s · %s | TURN %s | LATENCY %s ms%s" % [
		str(view.get("provider", "?")), str(view.get("model", "?")),
		str(view.get("turn", "?")), str(view.get("latency_ms", "?")),
		" (MOCK)" if bool(view.get("mock", false)) else ""])
	lines.append("SNAPSHOT %s (v%s)" % [str(view.get("snapshot_id", "-")), str(view.get("state_version", "?"))])
	lines.append("STATUS %s | orders=%s executed=%s rejected=%s" % [
		str(view.get("status", "?")), str(view.get("order_count", "?")),
		str(view.get("executed_count", "?")), str(view.get("rejected_count", "?"))])
	var plan: Dictionary = view.get("plan", {})
	if not plan.is_empty() and (str(plan.get("objective", "")).is_empty() == false or str(plan.get("intent", "")).is_empty() == false):
		lines.append("PLAN objective=%s" % str(plan.get("objective", "-")))
		lines.append("PLAN intent=%s" % str(plan.get("intent", "-")))
		lines.append("PLAN reconsider_if=%s" % str(plan.get("reconsider_if", "-")))
	if view.has("failure"):
		var f: Dictionary = view.get("failure", {})
		lines.append("FAILURE %s: %s" % [str(f.get("code", "?")), str(f.get("detail", ""))])
	if view.has("diag") and (view.get("diag", {}) as Dictionary).has("code"):
		var d: Dictionary = view.get("diag", {})
		lines.append("DIAG http=%s finish=%s final=%s chars(%s) reasoning=%s(%s chars) refusal=%s tools=%s retry=%s" % [
			str(d.get("http_status", "?")), str(d.get("finish_reason", "-")) if not str(d.get("finish_reason", "")).is_empty() else "-",
			str(d.get("content_chars", "?")), str(d.get("content_type", "?")),
			"yes" if bool(d.get("reasoning_present", false)) else "no", str(d.get("reasoning_chars", 0)),
			"yes" if bool(d.get("refusal_present", false)) else "no", str(d.get("tool_calls", 0)),
			str(d.get("auto_retries", 0))])
		if bool(d.get("sse_suspected", false)):
			lines.append("DIAG response looks like SSE/streaming, not one JSON body")
	if view.has("auto_retries") and int(view.get("auto_retries", 0)) > 0:
		lines.append("auto_retries=%d" % int(view.get("auto_retries", 0)))
	var i := 0
	for o_val in (view.get("orders", []) as Array):
		i += 1
		var o: Dictionary = o_val
		var cmd: Dictionary = o.get("order", {})
		var v: Dictionary = o.get("validation", {})
		lines.append("--- order %d [%s] %s" % [i, str(o.get("status", "?")), str(cmd.get("action", "?"))])
		lines.append("  scope=%s" % JSON.stringify(cmd.get("scope", {})))
		lines.append("  target=%s" % JSON.stringify(cmd.get("target", {})))
		if bool(v.get("ok", false)):
			lines.append("  validation OK")
		else:
			lines.append("  validation REJECT %s: %s" % [str(v.get("code", "?")), str(v.get("detail", ""))])
		var res: Array = o.get("resolved_units", [])
		if not res.is_empty():
			lines.append("  resolved[%d]=%s" % [res.size(), ",".join(res)])
		for e_val in (o.get("executed", []) as Array):
			var e: Dictionary = e_val
			lines.append("  EXEC %s %s" % [str(e.get("unit_id", "?")), _row_short(e)])
		for f_val in (o.get("failed", []) as Array):
			var fr: Dictionary = f_val
			lines.append("  FAIL %s %s: %s" % [str(fr.get("unit_id", "?")), str(fr.get("code", "?")), str(fr.get("detail", ""))])
		for p_val in (o.get("plan_failed", []) as Array):
			var pr: Dictionary = p_val
			lines.append("  PLAN-FAIL %s %s: %s" % [str(pr.get("unit_id", "?")), str(pr.get("code", "?")), str(pr.get("detail", ""))])
	lines.append("pre =%s" % str(view.get("pre_fingerprint", "-")).left(72))
	lines.append("post=%s" % str(view.get("post_fingerprint", "-")).left(72))
	if not str(view.get("log_path", "")).is_empty():
		lines.append("log=%s" % str(view.get("log_path", "")))
	lines.append("summary=%s" % str(view.get("summary", "-")))
	lines.append("controller=[%s] %s" % [str(state.get("phase", "?")), str(state.get("note", ""))])
	return "\n".join(lines)


static func _row_short(e: Dictionary) -> String:
	var kind := str(e.get("action", "?"))
	if kind == "MOVE":
		return "MOVE %s->%s" % [str(e.get("from", "?")), str(e.get("to", "?"))]
	if kind == "ATTACK":
		return "ATTACK %s" % str(e.get("target_unit_id", "?"))
	return kind
