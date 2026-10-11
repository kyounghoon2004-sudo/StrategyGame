class_name AISSetupPanel
extends Control

## Player-facing AI backend configuration panel (dual provider).
##
## Backend = 로컬 Ollama: original embedded-backend milestone behavior —
## [게임 시작] reuses/starts `ollama serve`, verifies + VRAM-preloads the
## model BEFORE entering battle. Unchanged.
##
## Backend = OpenCode Go: Cloud General configuration. The user only pastes
## the API key; GET /models discovery fills the dropdown, per-model protocol
## routing picks chat/responses/messages, [Test Connection] gates Apply.
## No endpoint entry, no PowerShell, no source edits.
##
## Opened from the title screen (configure + save) or bound to the live
## Human-vs-Cloud stack via open_for_cloud() (configure + push live).
## The DEV inspection tabs (Context/Chat/Tools) live below the form.
##
## Security: the API key travels UI -> apply_runtime memory only. It is
## never persisted, never logged, never placed in evidence/DEV output
## (only api_key_present YES/NO is ever exposed).

signal launch_started(ai_enabled: bool)
signal config_applied
signal panel_closed

const ConfigScript = preload("res://scripts/ai/ai_backend_config.gd")
const BootstrapScript = preload("res://scripts/ai/ai_backend_bootstrap.gd")
const CloudConfigScript = preload("res://scripts/cloud2/cloud2_config.gd")
const CloudAdapterScript = preload("res://scripts/cloud2/cloud2_adapter.gd")
const OpenCodeScript = preload("res://scripts/cloud2/cloud2_opencode.gd")
const SessionScript = preload("res://scripts/cloud2/cloud2_session.gd")
const InspectorScript = preload("res://scripts/cloud2/cloud2_inspector.gd")

const BATTLE_SCENE := "res://scenes/step2r_battlefield_shell.tscn"

const COL_BG := Color(0.08, 0.06, 0.04, 0.97)
const COL_GOLD := Color(0.79, 0.64, 0.15, 1.0)
const COL_GOLD_BRIGHT := Color(1.0, 0.85, 0.35, 1.0)
const COL_TEXT := Color(0.92, 0.87, 0.72, 1.0)
const COL_MUTED := Color(0.70, 0.65, 0.55, 1.0)
const COL_OK := Color(0.55, 0.95, 0.55, 1.0)
const COL_BAD := Color(1.0, 0.45, 0.38, 1.0)
const COL_IDLE := Color(0.60, 0.58, 0.52, 1.0)
const COL_WORK := Color(1.0, 0.85, 0.35, 1.0)

const MSG_TAGS_FAIL := "Ollama 모델 목록을 가져올 수 없습니다. 모델 이름을 직접 입력할 수 있습니다."
const MSG_OC_NO_KEY := "OpenCode Go API 키를 먼저 붙여넣으십시오."
const MSG_OC_NO_PROTO := "UNSUPPORTED / UNKNOWN API PROTOCOL — 목록에서 모델을 고르거나 Advanced 프로토콜을 지정하십시오."
const MSG_OC_NEED_TEST := "먼저 [Test Connection]을 통과하십시오. (Cloud는 준비 없는 시작이 없습니다)"

var adjust_mode := false

var _backend_opt: OptionButton
var _model_opt: OptionButton
var _model_edit: LineEdit
var _endpoint_edit: LineEdit
var _api_edit: LineEdit
var _api_note: Label
var _dot: Label
var _status_lbl: Label
var _dev_lbl: Label
var _start_btn: Button
var _free_btn: Button
var _cancel_btn: Button
var _refresh_btn: Button
var _hint_lbl: Label
var _live_lbl: Label

# OpenCode Go rows (visible only when backend == OpenCode Go).
var _erow: HBoxContainer
var _oc_ep_row: HBoxContainer
var _oc_ep_lbl: Label
var _paste_btn: Button
var _clear_btn: Button
var _proto_row: HBoxContainer
var _proto_opt: OptionButton
var _proto_lbl: Label
var _test_btn: Button
var _insp_toggle: Button
var _insp_host: VBoxContainer
var _inspector: Control = null

var _bootstrap: AIBackendBootstrap
var _cloud_adapter: Cloud2Adapter = null # panel-owned; used when no live stack is bound
var _cfg: Dictionary = {}
var _refreshing := false
var _preparing := false
var _flow_session := 0
var _pending_key := ""
var _last_failed_identity := ""
## Explicit key-field intent (never inferred from LineEdit.text == ""):
## KEEP = blank field preserves the session secret; REPLACE = typed/pasted
## text supersedes it; CLEAR = only the Clear button destroys it.
const KEY_ACTION_KEEP := 0
const KEY_ACTION_REPLACE := 1
const KEY_ACTION_CLEAR := 2
var _key_action := KEY_ACTION_KEEP

# OpenCode Go state. _oc is the working Cloud2Config: the LIVE target when
# opened from the Lab, a scratch config on the title screen.
var _oc: Cloud2Config = null
var _cloud_live: Cloud2Config = null
var _cloud_controller: Cloud2TurnController = null
var _cloud_adapter_live: Cloud2Adapter = null
var _testing := false
var _models_loading := false
var _tested_key := ""
var _oc_session := 0
var _last_backend_idx := -1


func _ready() -> void:
	# anchors+offsets: set_anchors_preset() alone preserves the (0,0) rect
	# via compensating offsets when the parent is a bare CanvasLayer.
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build()
	_bootstrap = BootstrapScript.new()
	_bootstrap.name = "AIBackendBootstrap"
	add_child(_bootstrap)
	_bootstrap.state_changed.connect(_on_state_changed)
	_bootstrap.status_message.connect(_on_status_message)
	_bootstrap.models_updated.connect(_on_models_updated)
	_bootstrap.start_finished.connect(_on_start_finished)
	_cloud_adapter = CloudAdapterScript.new()
	_cloud_adapter.name = "AISetupCloudAdapter"
	add_child(_cloud_adapter)
	_cloud_adapter.models_fetched.connect(_on_models_fetched)
	_cloud_adapter.test_finished.connect(_on_cloud_test_finished)
	_cfg = ConfigScript.load_safe()
	_apply_cfg_to_ui()
	_set_status("idle", "확인되지 않음")
	visible = false


func open() -> void:
	_cfg = ConfigScript.load_safe()
	_cloud_live = null
	_cloud_controller = null
	_disconnect_live_adapter()
	_cloud_adapter_live = null
	_oc = CloudConfigScript.new()
	_oc.set_provider("opencode")
	_last_backend_idx = -1
	_apply_cfg_to_ui()
	_flow_session += 1
	_refreshing = false
	_preparing = false
	_testing = false
	_models_loading = false
	_pending_key = ""
	_tested_key = ""
	_update_buttons()
	_set_status("idle", "확인되지 않음")
	_refresh_dev()
	_update_start_text()
	_free_btn.visible = not adjust_mode
	visible = true
	_setup_inspector()
	SessionScript.trace("TITLE_SETTINGS_OPEN", _oc, _cloud_live)
	if _is_opencode():
		_reuse_discovery_cache()
		_auto_opencode_probe()
	else:
		_silent_model_probe()


## Open bound to the live Human-vs-Cloud stack (adjust-mode: apply in place,
## never change scenes). controller/adapter may be null only in tests.
func open_for_cloud(live_config: Cloud2Config, controller: Cloud2TurnController, adapter: Cloud2Adapter) -> void:
	_cfg = ConfigScript.load_safe()
	adjust_mode = true
	_disconnect_live_adapter()
	_cloud_live = live_config
	_cloud_controller = controller
	_cloud_adapter_live = adapter
	if _cloud_adapter_live != null:
		_cloud_adapter_live.models_fetched.connect(_on_models_fetched)
		_cloud_adapter_live.test_finished.connect(_on_cloud_test_finished)
	# Bound mode works on a SCRATCH opencode config; opening the window never
	# mutates live. Prefill the scratch from live when live is already
	# OpenCode; otherwise start empty (Lab is cloud-only — never show disk
	# Ollama/Qwen values as if they were live). Apply pushes scratch->live.
	_oc = CloudConfigScript.new()
	_oc.set_provider("opencode")
	if _cloud_live != null and _cloud_live.is_opencode():
		_oc.set_protocol_override(_cloud_live.protocol_override)
		_oc.set_discovered_models(_cloud_live.discovered_models)
		_oc.set_model(_cloud_live.model)
		_oc.set_api_key(_cloud_live.api_key)
		if _cloud_live.connection_tested:
			_oc.mark_test_result(true, _cloud_live.connection_status, _cloud_live.connection_note)
			_tested_key = _cloud_live.api_key
		_cfg["backend_type"] = ConfigScript.BACKEND_OPENCODE_GO
		ConfigScript.set_slot(_cfg, ConfigScript.BACKEND_OPENCODE_GO, _oc.model, _oc.endpoint)
		_cfg["model"] = _oc.model
		_cfg["endpoint"] = _oc.endpoint
		_cfg["opencode_transport"] = _oc.resolved_transport
		_cfg["opencode_override"] = _oc.protocol_override
		_cfg["opencode_tested"] = _oc.connection_tested
	else:
		_cfg["backend_type"] = ConfigScript.BACKEND_OPENCODE_GO
		_cfg["model"] = ""
		_cfg["endpoint"] = ""
		_cfg["opencode_transport"] = ""
		_cfg["opencode_override"] = ""
		_cfg["opencode_tested"] = false
		_tested_key = ""
	_last_backend_idx = -1
	_apply_cfg_to_ui()
	_refresh_live_lbl()
	_flow_session += 1
	_refreshing = false
	_preparing = false
	_testing = false
	_models_loading = false
	_pending_key = ""
	_update_buttons()
	if _oc != null and _oc.is_opencode() and _oc.connection_tested:
		_set_status("ok", "Connected — %s (%s)" % [_oc.model, _proto_short(_oc.resolved_transport)])
	else:
		_set_status("idle", "확인되지 않음")
	_refresh_dev()
	_update_start_text()
	_free_btn.visible = false
	visible = true
	_setup_inspector()
	SessionScript.trace("INGAME_SETTINGS_OPEN", _oc, _cloud_live)
	if _is_opencode() and _oc != null and _oc.discovered_models.is_empty():
		if _reuse_discovery_cache() == 0:
			_auto_opencode_probe()
	elif not _is_opencode():
		_silent_model_probe()


func close() -> void:
	SessionScript.trace("CLOSE", _oc, _cloud_live)
	_flow_session += 1
	_refreshing = false
	_preparing = false
	_testing = false
	_models_loading = false
	_pending_key = ""
	_tested_key = ""
	if _bootstrap != null:
		_bootstrap.cancel()
	_disconnect_live_adapter()
	_cloud_live = null
	_cloud_controller = null
	_cloud_adapter_live = null
	_oc = null
	_api_edit.text = ""
	visible = false
	panel_closed.emit()


func is_preparing() -> bool:
	return _preparing


func is_busy() -> bool:
	return _preparing or _refreshing or _testing or _models_loading


## Bound-mode honesty line: what the LIVE stack actually holds right now,
## read from the live object itself. Updated on open/test/apply/discovery.
func _refresh_live_lbl() -> void:
	if _live_lbl == null:
		return
	if _cloud_live == null:
		_live_lbl.visible = false
		return
	_live_lbl.visible = true
	var s := _cloud_live.effective_snapshot()
	if str(s.get("provider", "")).is_empty():
		_live_lbl.text = "LIVE: not configured — configure OpenCode Go below."
	else:
		_live_lbl.text = "LIVE: %s / %s / %s / %s" % [
			str(s.get("provider_label", "?")), str(s.get("model", "—")),
			str(s.get("protocol", "—")) if not str(s.get("protocol", "")).is_empty() else "unresolved",
			str(s.get("connection", "?"))]


func _disconnect_live_adapter() -> void:
	if _cloud_adapter_live != null and is_instance_valid(_cloud_adapter_live):
		if _cloud_adapter_live.models_fetched.is_connected(_on_models_fetched):
			_cloud_adapter_live.models_fetched.disconnect(_on_models_fetched)
		if _cloud_adapter_live.test_finished.is_connected(_on_cloud_test_finished):
			_cloud_adapter_live.test_finished.disconnect(_on_cloud_test_finished)


func _active_adapter() -> Cloud2Adapter:
	if _cloud_adapter_live != null and is_instance_valid(_cloud_adapter_live):
		return _cloud_adapter_live
	return _cloud_adapter


func _setup_inspector() -> void:
	if _inspector != null and _inspector.has_method("setup"):
		# Bound: inspect the LIVE stack (what turns actually use).
		# Title: inspect the working config (test it, then chat with it).
		var cfg_for_insp: Cloud2Config = _cloud_live if _cloud_live != null else _oc
		_inspector.call("setup", _cloud_controller, cfg_for_insp, _active_adapter())


# --- Construction ---------------------------------------------------------

func _build() -> void:
	var dim := ColorRect.new()
	dim.name = "Dim"
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0, 0, 0, 0.72)
	add_child(dim)
	var center := CenterContainer.new()
	center.name = "Center"
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var panel := PanelContainer.new()
	panel.name = "Panel"
	panel.custom_minimum_size = Vector2(700, 0)
	var sb := StyleBoxFlat.new()
	sb.bg_color = COL_BG
	sb.border_color = COL_GOLD
	sb.set_border_width_all(3)
	sb.set_corner_radius_all(6)
	sb.content_margin_left = 0
	sb.content_margin_right = 0
	panel.add_theme_stylebox_override("panel", sb)
	center.add_child(panel)
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 28)
	margin.add_theme_constant_override("margin_top", 24)
	margin.add_theme_constant_override("margin_right", 28)
	margin.add_theme_constant_override("margin_bottom", 24)
	panel.add_child(margin)
	# The form + inspector exceed 1080p: the dialog scrolls instead of
	# stranding the inspector toggle and buttons below the fold.
	var scroll := ScrollContainer.new()
	scroll.name = "Scroll"
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var vh := get_viewport_rect().size.y if is_inside_tree() else 1080.0
	scroll.custom_minimum_size = Vector2(0, maxf(420.0, vh - 160.0))
	margin.add_child(scroll)
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 12)
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(vbox)
	var title := Label.new()
	title.text = "AI 설정"
	title.add_theme_font_size_override("font_size", 24)
	title.add_theme_color_override("font_color", COL_GOLD_BRIGHT)
	vbox.add_child(title)
	_hint_lbl = Label.new()
	_hint_lbl.text = "시작을 누르면 AI 서버를 자동 시작하고 모델을 VRAM에 미리 올린 뒤 출정합니다. 처음 한 번은 시간이 걸릴 수 있습니다."
	_hint_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint_lbl.add_theme_font_size_override("font_size", 14)
	_hint_lbl.add_theme_color_override("font_color", COL_MUTED)
	vbox.add_child(_hint_lbl)
	_live_lbl = Label.new()
	_live_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_live_lbl.add_theme_font_size_override("font_size", 13)
	_live_lbl.add_theme_color_override("font_color", Color(0.55, 0.85, 1.0))
	_live_lbl.visible = false
	vbox.add_child(_live_lbl)
	# Backend row.
	var brow := HBoxContainer.new()
	brow.add_theme_constant_override("separation", 10)
	vbox.add_child(brow)
	brow.add_child(_row_label("백엔드"))
	_backend_opt = OptionButton.new()
	_backend_opt.custom_minimum_size = Vector2(380, 38)
	_backend_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_backend_opt.add_theme_font_size_override("font_size", 16)
	_backend_opt.add_item("로컬 Ollama", 0)
	_backend_opt.add_item("OpenCode Go", 1)
	_backend_opt.item_selected.connect(_on_backend_selected)
	brow.add_child(_backend_opt)
	# Model row (dropdown + refresh).
	var mrow := HBoxContainer.new()
	mrow.add_theme_constant_override("separation", 10)
	vbox.add_child(mrow)
	mrow.add_child(_row_label("모델"))
	_model_opt = OptionButton.new()
	_model_opt.custom_minimum_size = Vector2(330, 38)
	_model_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_model_opt.add_theme_font_size_override("font_size", 15)
	_model_opt.item_selected.connect(_on_model_selected)
	mrow.add_child(_model_opt)
	_refresh_btn = Button.new()
	_refresh_btn.text = "⟳"
	_refresh_btn.custom_minimum_size = Vector2(44, 38)
	_refresh_btn.tooltip_text = "모델 목록 새로고침"
	_refresh_btn.pressed.connect(_on_refresh_pressed)
	mrow.add_child(_refresh_btn)
	# Model manual entry (custom tags always allowed).
	var mrow2 := HBoxContainer.new()
	mrow2.add_theme_constant_override("separation", 10)
	vbox.add_child(mrow2)
	var spacer := Label.new()
	spacer.custom_minimum_size = Vector2(90, 0)
	mrow2.add_child(spacer)
	_model_edit = LineEdit.new()
	_model_edit.custom_minimum_size = Vector2(380, 36)
	_model_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_model_edit.add_theme_font_size_override("font_size", 15)
	_model_edit.placeholder_text = "모델 태그 직접 입력 (예: qwen38-jrell-mtp-256k:latest)"
	_model_edit.text_changed.connect(_on_model_text_changed)
	mrow2.add_child(_model_edit)
	# Endpoint row (Ollama only).
	_erow = HBoxContainer.new()
	_erow.add_theme_constant_override("separation", 10)
	vbox.add_child(_erow)
	_erow.add_child(_row_label("주소"))
	_endpoint_edit = LineEdit.new()
	_endpoint_edit.custom_minimum_size = Vector2(380, 36)
	_endpoint_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_endpoint_edit.add_theme_font_size_override("font_size", 15)
	_endpoint_edit.placeholder_text = "http://127.0.0.1:11434"
	_erow.add_child(_endpoint_edit)
	# Auto endpoint row (OpenCode Go only, read-only).
	_oc_ep_row = HBoxContainer.new()
	_oc_ep_row.add_theme_constant_override("separation", 10)
	vbox.add_child(_oc_ep_row)
	_oc_ep_row.add_child(_row_label("주소 (자동)"))
	_oc_ep_lbl = Label.new()
	_oc_ep_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_oc_ep_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_oc_ep_lbl.add_theme_font_size_override("font_size", 13)
	_oc_ep_lbl.add_theme_color_override("font_color", COL_MUTED)
	_oc_ep_row.add_child(_oc_ep_lbl)
	# API key row (memory only).
	var krow := HBoxContainer.new()
	krow.add_theme_constant_override("separation", 10)
	vbox.add_child(krow)
	krow.add_child(_row_label("API Key"))
	_api_edit = LineEdit.new()
	_api_edit.custom_minimum_size = Vector2(330, 36)
	_api_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_api_edit.add_theme_font_size_override("font_size", 15)
	_api_edit.secret = true
	_api_edit.text_changed.connect(_on_key_text_changed)
	krow.add_child(_api_edit)
	_paste_btn = Button.new()
	_paste_btn.text = "붙여넣기"
	_paste_btn.custom_minimum_size = Vector2(90, 36)
	_paste_btn.tooltip_text = "클립보드의 키를 붙여넣습니다 (양끝 공백 자동 제거)"
	_paste_btn.pressed.connect(_on_paste_pressed)
	krow.add_child(_paste_btn)
	_clear_btn = Button.new()
	_clear_btn.text = "Clear"
	_clear_btn.custom_minimum_size = Vector2(70, 36)
	_clear_btn.tooltip_text = "세션 키를 즉시 파기합니다 (필드 + 세션 + 라이브, tested 해제)"
	_clear_btn.pressed.connect(_on_clear_key_pressed)
	krow.add_child(_clear_btn)
	_api_note = Label.new()
	_api_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_api_note.add_theme_font_size_override("font_size", 13)
	_api_note.add_theme_color_override("font_color", COL_MUTED)
	vbox.add_child(_api_note)
	# Protocol row (OpenCode Go only).
	_proto_row = HBoxContainer.new()
	_proto_row.add_theme_constant_override("separation", 10)
	vbox.add_child(_proto_row)
	_proto_row.add_child(_row_label("프로토콜"))
	_proto_opt = OptionButton.new()
	_proto_opt.custom_minimum_size = Vector2(220, 36)
	_proto_opt.add_theme_font_size_override("font_size", 14)
	_proto_opt.add_item("자동 (권장)", 0)
	_proto_opt.add_item("chat/completions", 1)
	_proto_opt.add_item("responses", 2)
	_proto_opt.add_item("messages", 3)
	_proto_opt.tooltip_text = "Advanced: 알 수 없는 모델에만 수동 지정하십시오. 보통은 자동을 유지하십시오."
	_proto_opt.item_selected.connect(_on_proto_selected)
	_proto_row.add_child(_proto_opt)
	_proto_lbl = Label.new()
	_proto_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_proto_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_proto_lbl.add_theme_font_size_override("font_size", 13)
	_proto_lbl.add_theme_color_override("font_color", COL_MUTED)
	_proto_row.add_child(_proto_lbl)
	# Refresh row.
	var rrow := HBoxContainer.new()
	rrow.add_theme_constant_override("separation", 10)
	vbox.add_child(rrow)
	rrow.add_child(_row_label(""))
	var refresh_lbl := Button.new()
	refresh_lbl.text = "모델 목록 새로고침"
	refresh_lbl.tooltip_text = "Ollama: /api/tags 조회만 수행합니다 (모델 실행 없음). OpenCode Go: /models 목록을 가져옵니다."
	refresh_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	refresh_lbl.pressed.connect(_on_refresh_pressed)
	rrow.add_child(refresh_lbl)
	_test_btn = Button.new()
	_test_btn.text = "Test Connection"
	_test_btn.tooltip_text = "선택된 모델로 최소 요청 1회를 보냅니다. 전투 상태는 건드리지 않습니다."
	_test_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_test_btn.pressed.connect(_on_test_pressed)
	rrow.add_child(_test_btn)
	# Status row.
	var srow := HBoxContainer.new()
	srow.add_theme_constant_override("separation", 10)
	vbox.add_child(srow)
	srow.add_child(_row_label("상태"))
	_dot = Label.new()
	_dot.text = "●"
	_dot.add_theme_font_size_override("font_size", 16)
	srow.add_child(_dot)
	_status_lbl = Label.new()
	_status_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_lbl.add_theme_font_size_override("font_size", 15)
	_status_lbl.add_theme_color_override("font_color", COL_TEXT)
	srow.add_child(_status_lbl)
	# Buttons.
	var btns := HBoxContainer.new()
	btns.add_theme_constant_override("separation", 8)
	btns.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_child(btns)
	_start_btn = _make_btn("게임 시작")
	_start_btn.pressed.connect(_on_start_pressed)
	btns.add_child(_start_btn)
	_free_btn = _make_btn("AI 없이 시작")
	_free_btn.pressed.connect(_on_free_pressed)
	btns.add_child(_free_btn)
	_cancel_btn = _make_btn("취소")
	_cancel_btn.pressed.connect(_on_cancel_pressed)
	btns.add_child(_cancel_btn)
	# DEV diagnostics (hidden in player mode; never shows the key).
	_dev_lbl = Label.new()
	_dev_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_dev_lbl.add_theme_font_size_override("font_size", 12)
	_dev_lbl.add_theme_color_override("font_color", COL_MUTED)
	_dev_lbl.visible = _is_dev()
	vbox.add_child(_dev_lbl)
	# Inspection area (Context / Chat / Tools), collapsed by default.
	_insp_toggle = Button.new()
	_insp_toggle.text = "▸ 검사 패널 (Context / Chat / Tools)"
	_insp_toggle.toggle_mode = true
	_insp_toggle.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_insp_toggle.tooltip_text = "모델 입력(Context), 직접 대화(Chat), 노출 스키마(Tools) 검사"
	_insp_toggle.toggled.connect(_on_insp_toggled)
	vbox.add_child(_insp_toggle)
	_insp_host = VBoxContainer.new()
	_insp_host.custom_minimum_size = Vector2(0, 430)
	_insp_host.visible = false
	vbox.add_child(_insp_host)
	_inspector = InspectorScript.new()
	_inspector.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_insp_host.add_child(_inspector)
func _row_label(text: String) -> Label:
	var l := Label.new()
	l.custom_minimum_size = Vector2(90, 0)
	l.text = text
	l.add_theme_font_size_override("font_size", 16)
	l.add_theme_color_override("font_color", COL_TEXT)
	return l


func _make_btn(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(140, 44)
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_size_override("font_size", 16)
	b.add_theme_color_override("font_color", COL_GOLD_BRIGHT)
	var n := StyleBoxFlat.new()
	n.bg_color = Color(0.14, 0.10, 0.07, 0.95)
	n.border_color = Color(0.79, 0.64, 0.15, 0.85)
	n.set_border_width_all(2)
	n.set_corner_radius_all(4)
	b.add_theme_stylebox_override("normal", n)
	var h := n.duplicate() as StyleBoxFlat
	h.bg_color = Color(0.22, 0.15, 0.09, 0.98)
	h.border_color = Color(1, 0.85, 0.32, 1)
	b.add_theme_stylebox_override("hover", h)
	b.add_theme_stylebox_override("pressed", h)
	b.add_theme_stylebox_override("focus", h)
	var d := n.duplicate() as StyleBoxFlat
	d.bg_color = Color(0.07, 0.06, 0.05, 0.9)
	d.border_color = Color(0.35, 0.30, 0.20, 0.6)
	b.add_theme_stylebox_override("disabled", d)
	return b


# --- Backend mapping ----------------------------------------------------------

func _is_opencode() -> bool:
	return _backend_opt.selected == 1


func _backend_id_from_idx(idx: int) -> String:
	return ConfigScript.BACKEND_OPENCODE_GO if idx == 1 else ConfigScript.BACKEND_LOCAL_OLLAMA


func _backend_idx_from_id(bid: String) -> int:
	# Legacy GENERIC_API placeholder maps to OpenCode Go (both are remote-API
	# concepts; the placeholder never had a working flow to preserve).
	if bid == ConfigScript.BACKEND_OPENCODE_GO or bid == ConfigScript.BACKEND_GENERIC_API:
		return 1
	return 0


func _proto_short(t: String) -> String:
	match t:
		"openai_chat":
			return "chat"
		"openai_responses":
			return "responses"
		"anthropic_messages":
			return "messages"
	return "?"


func _override_from_ui() -> String:
	match _proto_opt.selected:
		1:
			return "openai_chat"
		2:
			return "openai_responses"
		3:
			return "anthropic_messages"
	return ""


func _override_to_idx(t: String) -> int:
	match t.strip_edges().to_lower():
		"openai_chat":
			return 1
		"openai_responses":
			return 2
		"anthropic_messages":
			return 3
	return 0


func _update_start_text() -> void:
	if adjust_mode:
		_start_btn.text = "설정 적용"
	elif _is_opencode():
		_start_btn.text = "설정 저장"
	else:
		_start_btn.text = "게임 시작"


# --- Config <-> UI ----------------------------------------------------------

func _apply_cfg_to_ui() -> void:
	var backend := str(_cfg.get("backend_type", ConfigScript.DEFAULT_BACKEND))
	_backend_opt.select(_backend_idx_from_id(backend))
	_endpoint_edit.text = ConfigScript.slot_endpoint(_cfg, ConfigScript.BACKEND_LOCAL_OLLAMA)
	var active := _backend_id_from_idx(_backend_opt.selected)
	var cur_model := ConfigScript.slot_model(_cfg, active)
	_model_edit.text = cur_model
	_model_opt.clear()
	_model_opt.add_item(cur_model if not cur_model.is_empty() else "(모델 없음)", 0)
	_model_opt.set_item_metadata(0, cur_model)
	_model_opt.select(0)
	_proto_opt.select(_override_to_idx(str(_cfg.get("opencode_override", ""))))
	_api_edit.text = ""
	_sync_oc_from_cfg()
	_on_backend_selected(_backend_opt.selected)


## Mirror the form's opencode state (model/override) into the working config
## so protocol + endpoint labels always reflect the exact resolution.
func _sync_oc_from_cfg() -> void:
	if _oc == null:
		return
	if not _oc.is_opencode():
		_oc.set_provider("opencode")
	_oc.set_protocol_override(str(_cfg.get("opencode_override", "")))
	var m := _model_edit.text.strip_edges()
	if not m.is_empty():
		_oc.set_model(m)
	_refresh_oc_labels()


func _cfg_from_ui() -> Dictionary:
	var cfg := _cfg.duplicate(true)
	var active := _backend_id_from_idx(_backend_opt.selected)
	cfg["backend_type"] = active
	# Stash the visible values into their own backend slot (no cross-talk).
	var typed := _model_edit.text.strip_edges()
	if active == ConfigScript.BACKEND_LOCAL_OLLAMA:
		var ep := ConfigScript.sanitize_endpoint(_endpoint_edit.text.strip_edges())
		ConfigScript.set_slot(cfg, active,
			typed if not typed.is_empty() else ConfigScript.DEFAULT_MODEL,
			str(ep.get("value", ConfigScript.DEFAULT_ENDPOINT)) if bool(ep.get("ok", false)) else ConfigScript.DEFAULT_ENDPOINT)
	else:
		ConfigScript.set_slot(cfg, active, typed, _oc.endpoint if _oc != null else "")
	cfg["model"] = ConfigScript.slot_model(cfg, active)
	cfg["endpoint"] = ConfigScript.slot_endpoint(cfg, active)
	if _oc != null and active == ConfigScript.BACKEND_OPENCODE_GO:
		cfg["opencode_transport"] = _oc.resolved_transport
		cfg["opencode_override"] = _oc.protocol_override
		cfg["opencode_tested"] = _oc.connection_tested and _oc.connection_status == "CONNECTED" \
			and _effective_key() == _tested_key and not _tested_key.is_empty()
	cfg["ai_enabled"] = true
	return cfg


## Failure-escape identity: backend|endpoint|model (no revision, no secret).
static func _cfg_identity(cfg: Dictionary) -> String:
	return "%s|%s|%s" % [
		str(cfg.get("backend_type", "")).strip_edges().to_upper(),
		str(cfg.get("endpoint", "")).strip_edges(),
		str(cfg.get("model", "")).strip_edges()]


## Effective key by explicit KEY_ACTION (never bare text-emptiness):
## REPLACE = typed/pasted text; CLEAR = nothing (destruction already ran);
## KEEP = blank field preserves the session secret, resolved through the
## working config, live stack, process session, then shared runtime.
func _effective_key() -> String:
	if _key_action == KEY_ACTION_CLEAR:
		return ""
	var typed := _api_edit.text.strip_edges(true, true)
	if _key_action == KEY_ACTION_REPLACE and not typed.is_empty():
		return typed
	if _oc != null and not _oc.api_key.strip_edges().is_empty():
		return _oc.api_key.strip_edges(true, true)
	if _cloud_live != null and not _cloud_live.api_key.strip_edges().is_empty():
		return _cloud_live.api_key.strip_edges(true, true)
	if SessionScript.key_present():
		return SessionScript.get_key().strip_edges(true, true)
	if ConfigScript.has_api_key():
		return ConfigScript.get_api_key().strip_edges(true, true)
	return ""


func _has_kept_key() -> bool:
	if _oc != null and not _oc.api_key.strip_edges().is_empty():
		return true
	if _cloud_live != null and not _cloud_live.api_key.strip_edges().is_empty():
		return true
	if SessionScript.key_present():
		return true
	return ConfigScript.has_api_key()


func _on_backend_selected(idx: int) -> void:
	var incoming := _backend_id_from_idx(idx)
	# Stash the outgoing backend's visible values, but ONLY on a real switch:
	# _apply_cfg_to_ui calls here with the incoming value already in the field.
	if _last_backend_idx != -1 and idx != _last_backend_idx:
		var outgoing := ConfigScript.BACKEND_OPENCODE_GO if incoming == ConfigScript.BACKEND_LOCAL_OLLAMA else ConfigScript.BACKEND_LOCAL_OLLAMA
		var typed := _model_edit.text.strip_edges()
		if outgoing == ConfigScript.BACKEND_LOCAL_OLLAMA:
			ConfigScript.set_slot(_cfg, outgoing,
				typed if not typed.is_empty() else ConfigScript.slot_model(_cfg, outgoing),
				_endpoint_edit.text.strip_edges())
		else:
			if not typed.is_empty():
				ConfigScript.set_slot(_cfg, outgoing, typed, _oc.endpoint if _oc != null else "")
	_last_backend_idx = idx
	_cfg["backend_type"] = incoming
	_model_edit.text = ConfigScript.slot_model(_cfg, incoming)
	_model_opt.clear()
	var cur := _model_edit.text.strip_edges()
	_model_opt.add_item(cur if not cur.is_empty() else "(모델 없음)", 0)
	_model_opt.set_item_metadata(0, cur)
	_model_opt.select(0)
	var oc := idx == 1
	_erow.visible = not oc
	_oc_ep_row.visible = oc
	_proto_row.visible = oc
	_test_btn.visible = oc
	_paste_btn.visible = oc
	_clear_btn.visible = oc
	if oc:
		_hint_lbl.text = "API 키만 붙여넣으십시오. [모델 목록 새로고침]으로 모델을 가져온 뒤 고르고, [Test Connection]을 통과시킨 뒤 저장하십시오."
		_model_edit.placeholder_text = "모델 ID (목록에서 선택 권장)"
		_refresh_btn.tooltip_text = "모델 목록 새로고침 (GET /models)"
		if _has_kept_key():
			_api_edit.placeholder_text = "세션 키 유지됨 (비우면 유지, 입력하면 교체)"
		else:
			_api_edit.placeholder_text = "OpenCode Go API 키 붙여넣기"
		_api_note.text = "키는 메모리에만 보관되며 저장·기록되지 않습니다. 주소는 모델별 프로토콜에 따라 자동 결정됩니다."
		_sync_oc_from_cfg()
	else:
		_hint_lbl.text = "시작을 누르면 AI 서버를 자동 시작하고 모델을 VRAM에 미리 올린 뒤 출정합니다. 처음 한 번은 시간이 걸릴 수 있습니다."
		_model_edit.placeholder_text = "모델 태그 직접 입력 (예: qwen38-jrell-mtp-256k:latest)"
		_refresh_btn.tooltip_text = "모델 목록 새로고침 (/api/tags 조회만, 실행 없음)"
		_api_edit.text = ""
		_api_edit.placeholder_text = "로컬 Ollama에서는 필요하지 않습니다"
		_api_note.text = "로컬 Ollama는 API 키 없이 동작합니다. 키는 저장·기록되지 않습니다."
	_update_start_text()
	_update_buttons()


func _on_model_selected(idx: int) -> void:
	var mid := str(_model_opt.get_item_metadata(idx))
	if mid.is_empty():
		mid = _model_opt.get_item_text(idx)
	_model_edit.text = mid
	_on_model_text_changed(mid)


func _on_model_text_changed(new_text: String) -> void:
	if not _is_opencode() or _oc == null:
		return
	_oc.set_model(new_text.strip_edges())
	_refresh_oc_labels()


func _on_proto_selected(_idx: int) -> void:
	if _oc == null:
		return
	_oc.set_protocol_override(_override_from_ui())
	_cfg["opencode_override"] = _oc.protocol_override
	_cfg["opencode_transport"] = _oc.resolved_transport
	_refresh_oc_labels()
	_refresh_dev()


func _refresh_oc_labels() -> void:
	if _oc == null:
		return
	if _oc.endpoint.strip_edges().is_empty():
		_oc_ep_lbl.text = "(모델 선택 후 자동 결정)"
	else:
		_oc_ep_lbl.text = _oc.endpoint
	if _oc.model.strip_edges().is_empty():
		_proto_lbl.text = "모델을 선택하십시오."
		_proto_lbl.add_theme_color_override("font_color", COL_MUTED)
	elif _oc.is_protocol_resolved():
		_proto_lbl.text = "프로토콜: %s · 출처: %s" % [_proto_short(_oc.resolved_transport), _oc.protocol_source]
		_proto_lbl.add_theme_color_override("font_color", COL_OK)
	else:
		_proto_lbl.text = MSG_OC_NO_PROTO
		_proto_lbl.add_theme_color_override("font_color", COL_BAD)


func _on_key_text_changed(t: String) -> void:
	# Non-empty (typed or pasted) always means REPLACE. Empty NEVER means
	# CLEAR — clears come only from the Clear button; every other blanking
	# (apply/close/open/programmatic) falls back to KEEP.
	_key_action = KEY_ACTION_REPLACE if not t.strip_edges().is_empty() else KEY_ACTION_KEEP


func _on_paste_pressed() -> void:
	var clip := DisplayServer.clipboard_get().strip_edges(true, true)
	if clip.is_empty():
		_set_status("idle", "클립보드가 비어 있습니다.")
		return
	_api_edit.text = clip
	# Programmatic sets never emit text_changed: declare REPLACE explicitly
	# (same pattern as _on_model_selected's explicit echo call).
	_key_action = KEY_ACTION_REPLACE
	_set_status("idle", "키를 붙여넣었습니다. [모델 목록 새로고침]을 누르십시오.")


## Explicit session-key destruction: field + working config + live stack +
## shared runtime + session authority. Tested state falls everywhere.
func _on_clear_key_pressed() -> void:
	if is_busy():
		return
	_api_edit.text = ""
	_key_action = KEY_ACTION_CLEAR # set AFTER clearing: the "" echo must not flip it to KEEP
	_tested_key = ""
	if _oc != null:
		_oc.set_api_key("")
	if _cloud_live != null:
		_cloud_live.set_api_key("")
	ConfigScript.clear_api_key()
	_cfg["opencode_tested"] = false
	_refresh_oc_labels()
	_refresh_dev()
	_refresh_live_lbl()
	_set_status("idle", "세션 키를 파기했습니다. 다시 붙여넣고 테스트하십시오.")


func _on_refresh_pressed() -> void:
	if _preparing or _testing or _models_loading:
		return
	if _is_opencode():
		_refresh_opencode_models()
	else:
		_silent_model_probe()


func _auto_opencode_probe() -> void:
	if _effective_key().is_empty():
		_set_status("idle", "API 키를 붙여넣은 뒤 [모델 목록 새로고침]을 누르십시오.")
		return
	_refresh_opencode_models()


# --- OpenCode Go discovery (GET /models via the shared adapter) ---------------

func _refresh_opencode_models() -> void:
	if _refreshing or _preparing or _testing or _models_loading:
		return
	var key := _effective_key()
	if key.is_empty():
		_set_status("bad", MSG_OC_NO_KEY)
		return
	if _oc == null:
		_oc = CloudConfigScript.new()
		_oc.set_provider("opencode")
	_flow_session += 1
	_oc_session = _flow_session
	_models_loading = true
	_update_buttons()
	_set_status("work", "모델 목록 조회 중... (GET /models)")
	var res := _active_adapter().fetch_models(key)
	if not bool(res.get("ok", false)):
		_models_loading = false
		_update_buttons()
		_set_status("bad", str(res.get("detail", "모델 조회 시작 실패")))
		return
	# Outcome arrives via _on_models_fetched.


func _on_models_fetched(result: Dictionary) -> void:
	if not visible or _oc_session != _flow_session:
		return # superseded by close/reopen: ignore.
	_models_loading = false
	_update_buttons()
	if not bool(result.get("ok", false)):
		_set_status("bad", _friendly_models_error(result))
		return
	var models: Array = result.get("models", [])
	if models.is_empty():
		_set_status("bad", "모델이 없습니다. 키/계정을 확인하십시오.")
		return
	_oc.set_discovered_models(models)
	SessionScript.note_discovered(models)
	_fill_oc_dropdown(models)
	_set_status("ok", "모델 %d개를 찾았습니다. 목록에서 고르십시오." % models.size())


## Fill the OpenCode dropdown from a discovery list (live fetch or session
## cache), keeping the current model when it is still present.
func _fill_oc_dropdown(models: Array) -> void:
	if _oc == null or models.is_empty():
		return
	var keep := _model_edit.text.strip_edges()
	_model_opt.clear()
	var sel := 0
	for i in range(models.size()):
		var m: Dictionary = models[i]
		var label := "%s (%s)" % [str(m.get("name", "")), str(m.get("id", ""))]
		_model_opt.add_item(label, i)
		_model_opt.set_item_metadata(i, str(m.get("id", "")))
		if str(m.get("id", "")) == keep:
			sel = i
	_model_opt.select(sel)
	_model_edit.text = str(_model_opt.get_item_metadata(sel))
	_oc.set_model(_model_edit.text)
	_refresh_oc_labels()
	_refresh_dev()
	_refresh_live_lbl()


## Reuse the session discovery cache so a fresh window shows the known
## models instantly (Refresh still re-fetches live). Returns cache count.
func _reuse_discovery_cache() -> int:
	if _oc == null or not _oc.discovered_models.is_empty():
		return _oc.discovered_models.size() if _oc != null else 0
	var cached := SessionScript.discovered_cache()
	if cached.is_empty():
		return 0
	_oc.set_discovered_models(cached)
	_fill_oc_dropdown(cached)
	return cached.size()


func _friendly_models_error(result: Dictionary) -> String:
	match str(result.get("code", "")):
		"UNAUTHORIZED":
			return "INVALID API KEY — 키를 확인하십시오."
		"TIMEOUT":
			return "TIMEOUT — 잠시 후 다시 시도하십시오."
		"RATE_LIMITED":
			return "RATE LIMITED — 잠시 후 다시 시도하십시오."
		"OFFLINE":
			return "OFFLINE — OpenCode Go에 닿지 않습니다."
		"BAD_RESPONSE":
			return "PROVIDER ERROR — 모델 목록 형식이 낯섭니다."
		"CLOUD_NOT_CONFIGURED":
			return MSG_OC_NO_KEY
	return "PROVIDER ERROR — %s" % str(result.get("detail", ""))


# --- OpenCode Go test connection (1-token probe, no game mutation) -------------

func _on_test_pressed() -> void:
	if _preparing or _refreshing or _testing or _models_loading:
		return
	if _oc == null:
		return
	var model := _model_edit.text.strip_edges()
	if model.is_empty():
		_set_status("bad", "모델을 선택하거나 입력하십시오.")
		return
	_oc.set_model(model)
	var key := _effective_key()
	if key.is_empty():
		_set_status("bad", MSG_OC_NO_KEY)
		return
	_oc.set_api_key(key)
	if not _oc.is_protocol_resolved():
		_set_status("bad", MSG_OC_NO_PROTO)
		return
	_flow_session += 1
	_oc_session = _flow_session
	_testing = true
	_update_buttons()
	_set_status("work", "Testing... (%s · %s, 전투 상태 변경 없음)" % [model, _proto_short(_oc.resolved_transport)])
	SessionScript.trace("TITLE_TEST_BEFORE", _oc, _cloud_live)
	var res := _active_adapter().test_connection(_oc)
	if not bool(res.get("ok", false)):
		_testing = false
		_update_buttons()
		_set_status("bad", _friendly_test_error(res))
		return
	# Outcome arrives via _on_cloud_test_finished.


func _on_cloud_test_finished(result: Dictionary) -> void:
	if not visible or _oc_session != _flow_session or _oc == null:
		return
	_testing = false
	_update_buttons()
	if bool(result.get("ok", false)):
		_tested_key = _effective_key()
		_oc.mark_test_result(true, "CONNECTED", "%s · %d ms" % [_oc.model, int(result.get("latency_ms", 0))])
		_cfg["opencode_tested"] = true
		SessionScript.arm_from_config(_oc) # test-pass arms the session immediately
		if _cloud_live != null:
			_push_scratch_to_live(_tested_key) # bound test-pass propagates at once; Apply not required
		_set_status("ok", "CONNECTED — %s (%s)" % [_oc.model, _proto_short(_oc.resolved_transport)])
	else:
		_tested_key = ""
		_oc.mark_test_result(false, "ERROR", _friendly_test_error(result))
		_cfg["opencode_tested"] = false
		_set_status("bad", _friendly_test_error(result))
	SessionScript.trace("TITLE_TEST_AFTER", _oc, _cloud_live)
	_refresh_dev()
	_refresh_live_lbl()


func _friendly_test_error(result: Dictionary) -> String:
	var tail := _provider_tail(result)
	match str(result.get("code", "")):
		"UNAUTHORIZED":
			return "INVALID API KEY" + tail
		"TIMEOUT":
			return "TIMEOUT"
		"RATE_LIMITED":
			return "RATE LIMITED" + tail
		"MODEL_MISSING":
			return "MODEL NOT AVAILABLE" + tail
		"OFFLINE":
			return "OFFLINE — provider unreachable"
		"PROTOCOL_ERROR", "UNSUPPORTED_PROTOCOL":
			return "PROTOCOL ERROR — " + MSG_OC_NO_PROTO
		"INVALID_REQUEST":
			return "INVALID REQUEST BODY" + tail
		"UNSUPPORTED_FIELD":
			return "UNSUPPORTED FIELD" + tail
		"REGION_RESTRICTED":
			return "REGION RESTRICTED" + tail + " — try another model (e.g. GPT 5.6 Luna for /responses)."
		"MODEL_ACCESS_DENIED":
			return "MODEL ACCESS DENIED" + tail
		"BAD_RESPONSE":
			return "BAD RESPONSE from provider"
		"CLOUD_NOT_CONFIGURED":
			return "CLOUD NOT CONFIGURED"
	return "PROVIDER ERROR — %s" % str(result.get("detail", ""))


## Sanitized provider reason, bounded for the status line (already redacted
## by the adapter; never contains the key). Empty when the provider said
## nothing usable.
func _provider_tail(result: Dictionary) -> String:
	var m := str(result.get("provider_message", "")).strip_edges()
	if m.is_empty():
		var d := str(result.get("detail", "")).strip_edges()
		if d.begins_with("HTTP 400"):
			m = d
	if m.is_empty():
		return ""
	if m.length() > 220:
		m = m.left(220) + "..."
	return " — %s" % m
# --- Model discovery: GET /api/tags ONLY (Ollama) -------------------------------
# Tag listing for the dropdown. Never loads, runs, warms, benchmarks, or
# health-checks any model. Failure is nonfatal: manual entry always works.

func _silent_model_probe() -> void:
	if _refreshing or _preparing or _testing or _models_loading:
		return
	var ep := ConfigScript.sanitize_endpoint(_endpoint_edit.text.strip_edges())
	if not bool(ep.get("ok", false)):
		_set_status("idle", MSG_TAGS_FAIL)
		return
	_flow_session += 1
	var my := _flow_session
	_refreshing = true
	_update_buttons()
	_set_status("work", "모델 목록 조회 중... (/api/tags)")
	var http := HTTPRequest.new()
	http.timeout = 5.0
	add_child(http)
	var url := ConfigScript.tags_url(str(ep.get("value", "")))
	var err := http.request(url, PackedStringArray(["Accept: application/json"]), HTTPClient.METHOD_GET)
	if err != OK:
		http.queue_free()
		_refreshing = false
		_update_buttons()
		_set_status("idle", MSG_TAGS_FAIL)
		return
	var res: Array = await http.request_completed
	if not is_instance_valid(http):
		return
	http.queue_free()
	if my != _flow_session:
		return # superseded by close/reopen: ignore.
	_refreshing = false
	_update_buttons()
	if res.size() < 4 or int(res[0]) != HTTPRequest.RESULT_SUCCESS or int(res[1]) < 200 or int(res[1]) >= 300:
		_set_status("idle", MSG_TAGS_FAIL)
		return
	var names: Array = []
	var parsed: Variant = JSON.parse_string((res[3] as PackedByteArray).get_string_from_utf8())
	if parsed is Dictionary:
		for m in ((parsed as Dictionary).get("models", []) as Array):
			if m is Dictionary and not str((m as Dictionary).get("name", "")).is_empty():
				names.append(str((m as Dictionary).get("name", "")))
	names.sort()
	if names.is_empty():
		_set_status("idle", "설치된 모델이 없습니다. 모델 이름을 직접 입력할 수 있습니다.")
		return
	_on_models_updated(names)
	_set_status("ok", "모델 %d개를 찾았습니다. 목록에서 고르거나 직접 입력하십시오." % names.size())


# --- Button flows ---------------------------------------------------------------

func _on_start_pressed() -> void:
	if _preparing or _testing or _models_loading or _refreshing:
		return
	if _is_opencode():
		_on_opencode_apply()
		return
	var cfg := _cfg_from_ui()
	var ep := ConfigScript.sanitize_endpoint(str(cfg.get("endpoint", "")))
	if not bool(ep.get("ok", false)):
		_set_status("bad", "주소가 올바르지 않습니다. (http:// 또는 https://)")
		return
	cfg["endpoint"] = str(ep.get("value", ""))
	if str(cfg.get("model", "")).strip_edges().is_empty():
		_set_status("bad", "모델을 선택하거나 입력하십시오.")
		return
	_cfg = cfg
	ConfigScript.save_safe(_cfg)
	# Local Ollama never takes a key: snapshot nothing so memory stays clean.
	var key := ""
	# Second press after a preload failure forces entry without preload.
	if _last_failed_identity != "" and _last_failed_identity == _cfg_identity(cfg):
		_last_failed_identity = ""
		_pending_key = ""
		ConfigScript.apply_runtime(_cfg, key)
		_api_edit.text = ""
		_refresh_dev()
		if adjust_mode:
			config_applied.emit()
			close()
			return
		_set_status("ok", "준비 없이 출정합니다.")
		_enter_battle(true)
		return
	_flow_session += 1
	_preparing = true
	_pending_key = key
	_update_buttons()
	_set_status("work", "출정 준비 중... (AI 서버 시작 + VRAM 예열)")
	_bootstrap.start_preparation(cfg)


## OpenCode Go apply: key + model + resolved protocol + passed test, then
## persist (non-secret) and publish. No bootstrap, no preload, no scene
## change on the title screen — the DEV Human-vs-Cloud entry picks the
## runtime up. When bound to the Lab, Apply is the single propagation
## moment: the validated scratch config is pushed into the live stack, so
## the controller/adapter/chat all switch atomically without a restart.
func _on_opencode_apply() -> void:
	if _oc == null:
		return
	var model := _model_edit.text.strip_edges()
	if model.is_empty():
		_set_status("bad", "모델을 선택하거나 입력하십시오.")
		return
	_oc.set_protocol_override(_override_from_ui())
	_oc.set_model(model)
	var key := _effective_key()
	if key.is_empty():
		_set_status("bad", MSG_OC_NO_KEY)
		return
	_oc.set_api_key(key)
	if not _oc.is_protocol_resolved():
		_set_status("bad", MSG_OC_NO_PROTO)
		return
	# The tested triple (key + model + transport) must be exactly what passed.
	if not _oc.connection_tested or _oc.connection_status != "CONNECTED" \
			or _tested_key.is_empty() or key != _tested_key:
		_set_status("bad", MSG_OC_NEED_TEST)
		return
	var cfg := _cfg_from_ui()
	_cfg = cfg
	ConfigScript.save_safe(_cfg)
	ConfigScript.apply_runtime(_cfg, key)
	SessionScript.arm_from_config(_oc) # full-fidelity session (incl. cache + source)
	SessionScript.trace("TITLE_APPLY", _oc, _cloud_live)
	if _cloud_live != null:
		_push_scratch_to_live(key)
		SessionScript.trace("SESSION_AFTER_APPLY", _oc, _cloud_live)
	_api_edit.text = ""
	_last_failed_identity = ""
	_refresh_dev()
	_refresh_live_lbl()
	_setup_inspector()
	if adjust_mode:
		_set_status("ok", "OpenCode Go 설정을 적용했습니다. (%s · %s)" % [model, _proto_short(_oc.resolved_transport)])
		config_applied.emit()
		close()
		return
	_set_status("ok", "OpenCode Go 설정이 저장되었습니다. DEV: Human vs Cloud General로 진입하십시오.")
	close()


## Bound-mode propagation: validated scratch -> live stack. Order matters:
## discovered metadata first (metadata-first resolution), then model, then
## key, then the carried CONNECTED mark. Memory only; never the disk.
func _push_scratch_to_live(key: String) -> void:
	if _cloud_live == null or _oc == null:
		return
	_cloud_live.set_provider("opencode")
	_cloud_live.set_protocol_override(_oc.protocol_override)
	_cloud_live.set_discovered_models(_oc.discovered_models)
	_cloud_live.set_model(_oc.model)
	_cloud_live.set_api_key(key)
	_cloud_live.mark_test_result(true, "CONNECTED",
		"%s · applied from AI Settings" % _cloud_live.model)
	SessionScript.trace("PUSH_LIVE", _oc, _cloud_live)


func _on_free_pressed() -> void:
	if adjust_mode or _preparing:
		if _preparing:
			_flow_session += 1
			_preparing = false
			_pending_key = ""
			_bootstrap.cancel()
			_update_buttons()
		else:
			return
		if adjust_mode:
			return
	_flow_session += 1
	_pending_key = ""
	_tested_key = ""
	_last_failed_identity = ""
	var cfg := _cfg_from_ui()
	cfg["ai_enabled"] = false
	ConfigScript.clear_api_key()
	ConfigScript.save_safe(cfg)
	ConfigScript.apply_runtime(cfg, "")
	_api_edit.text = ""
	_refresh_dev()
	_enter_battle(false)


func _unhandled_key_input(event: InputEvent) -> void:
	if not visible:
		return
	var ke := event as InputEventKey
	if ke == null or not ke.pressed or ke.echo:
		return
	if ke.keycode == KEY_ESCAPE:
		_on_cancel_pressed()
		get_viewport().set_input_as_handled()
	elif ke.keycode == KEY_F1 and _is_dev():
		# gui_get_hovered_control() is 4.3+; null (not a crash) on 4.2.
		var hov: Control = null
		if get_viewport().has_method("gui_get_hovered_control"):
			hov = get_viewport().gui_get_hovered_control() as Control
		var layer := -1
		var p: Node = self
		while p != null:
			if p is CanvasLayer:
				layer = (p as CanvasLayer).layer
				break
			p = p.get_parent()
		print("[AISetup][F1] hovered=%s panel_rect=%s layer=%d global=%s" % [
			str(hov.get_path()) if hov != null else "(none)",
			str(get_global_rect()), layer, str(global_position)])
		get_viewport().set_input_as_handled()


func _on_cancel_pressed() -> void:
	if _preparing:
		_flow_session += 1
		_preparing = false
		_pending_key = ""
		_bootstrap.cancel()
		_set_status("idle", "취소되었습니다. 설정을 변경 후 다시 시도하십시오.")
		_update_buttons()
		return
	close()


func _on_insp_toggled(on: bool) -> void:
	_insp_host.visible = on
	_insp_toggle.text = "▾ 검사 패널 (Context / Chat / Tools)" if on else "▸ 검사 패널 (Context / Chat / Tools)"
	if on:
		_setup_inspector()
		if _inspector != null and _inspector.has_method("refresh_all"):
			_inspector.call("refresh_all")


# --- Bootstrap callbacks (flow-session guarded, Ollama only) --------------------

func _on_state_changed(_s: int, _sn: String) -> void:
	_refresh_dev()
	if not _preparing:
		return


func _on_status_message(text: String) -> void:
	if _preparing:
		_set_status("work", text)
	_refresh_dev()


func _on_start_finished(ok: bool, info: Dictionary) -> void:
	if not _preparing:
		return # cancelled or superseded: never enter battle from stale callback.
	_preparing = false
	_update_buttons()
	_refresh_dev(_format_dev(info))
	if ok:
		_last_failed_identity = ""
		ConfigScript.clear_api_key()
		ConfigScript.save_safe(_cfg)
		ConfigScript.apply_runtime(_cfg, _pending_key)
		_pending_key = ""
		_api_edit.text = ""
		_refresh_dev()
		if adjust_mode:
			_set_status("ok", "AI 설정을 적용했습니다. (새 모델 VRAM 예열 완료)")
			config_applied.emit()
			close()
			return
		_set_status("ok", "준비 완료 — 출정합니다.")
		_enter_battle(true)
	else:
		_last_failed_identity = _cfg_identity(_cfg)
		_pending_key = ""
		var msg := str(info.get("player_message", "준비 실패"))
		var hint := str(info.get("hint", ""))
		_set_status("bad", msg + (("\n" + hint) if not hint.is_empty() else "") + "\n[게임 시작]을 다시 누르면 준비 없이 시작합니다.")


# --- Discovery callback (Ollama) --------------------------------------------------

func _on_models_updated(models: Array) -> void:
	var keep := _model_edit.text.strip_edges()
	_model_opt.clear()
	if models.is_empty():
		_model_opt.add_item("(설치된 모델 없음)", 0)
		_model_opt.set_item_metadata(0, "")
		_model_opt.select(0)
		return
	for i in range(models.size()):
		_model_opt.add_item(str(models[i]), i)
		_model_opt.set_item_metadata(i, str(models[i]))
	var sel := 0
	if not keep.is_empty() and keep in models:
		sel = models.find(keep)
	elif str(_cfg.get("model", "")) in models:
		sel = models.find(str(_cfg.get("model", "")))
	_model_opt.select(sel)
	_model_edit.text = _model_opt.get_item_text(sel)


func _enter_battle(ai_enabled: bool) -> void:
	launch_started.emit(ai_enabled)
	visible = false
	get_tree().change_scene_to_file(BATTLE_SCENE)


# --- Presentation ---------------------------------------------------------------

func _set_status(kind: String, text: String) -> void:
	_status_lbl.text = text
	match kind:
		"ok":
			_dot.add_theme_color_override("font_color", COL_OK)
		"bad":
			_dot.add_theme_color_override("font_color", COL_BAD)
		"work":
			_dot.add_theme_color_override("font_color", COL_WORK)
		_:
			_dot.add_theme_color_override("font_color", COL_IDLE)


func _update_buttons() -> void:
	var busy := is_busy()
	var oc := _is_opencode()
	_refresh_btn.disabled = busy
	_start_btn.disabled = _refreshing or _models_loading or _testing
	_free_btn.disabled = _preparing
	_test_btn.disabled = busy
	_backend_opt.disabled = busy
	_model_opt.disabled = busy
	_model_edit.editable = not busy
	_endpoint_edit.editable = not busy
	_api_edit.editable = (not busy) and oc
	_paste_btn.disabled = busy or not oc
	_clear_btn.disabled = busy or not oc
	_proto_opt.disabled = busy or not oc
	_cancel_btn.text = "준비 취소" if _preparing else "취소"


## DEV diagnostics: backend/endpoint/model/key-presence/protocol only.
## NEVER the key.
func _refresh_dev(extra: String = "") -> void:
	if not _is_dev():
		return
	var cur: Dictionary = ConfigScript.current()
	var boot: Dictionary = _bootstrap.dev_snapshot() if _bootstrap != null else {}
	var sem: Dictionary = boot.get("semantic", {})
	var oc_info := "—"
	if _oc != null and _oc.is_opencode():
		oc_info = "model=%s proto=%s src=%s tested=%s discovered=%d" % [
			_oc.model, _proto_short(_oc.resolved_transport), _oc.protocol_source,
			str(_oc.connection_tested), _oc.discovered_models.size()]
	var live_fp := "—"
	if _cloud_live != null:
		live_fp = _cloud_live.fingerprint()
	var xchg := "—"
	var ad := _active_adapter()
	if ad != null and is_instance_valid(ad):
		var lx: Dictionary = ad.last_exchange()
		if not lx.is_empty():
			xchg = "%s %s -> %s (%s ms)" % [str(lx.get("method", "?")),
				str(lx.get("endpoint", "?")), str(lx.get("http_status", "?")),
				str(lx.get("latency_ms", "?"))]
	_dev_lbl.text = "DEV backend=%s endpoint=%s model=%s ai=%s apikey=%s identity=%s prep=%s\nDEV semantic=%s state=%s err=%s lat=%s\nDEV opencode: %s\nDEV live-fp: %s\nDEV last-xchg: %s\n%s" % [
		str(cur.get("backend_type", "?")), str(cur.get("endpoint", "?")),
		str(cur.get("model", "?")), str(cur.get("ai_enabled", "?")),
		"YES" if bool(cur.get("api_key_present", false)) else "NO",
		str(cur.get("config_identity", "?")), str(boot.get("state", "?")),
		str(cur.get("semantic_model", "?")), str(sem.get("state", "—")),
		str(sem.get("last_error", sem.get("error_kind", "—"))),
		str((sem.get("latencies_ms", {}) as Dictionary).get("total_ms", "—")), oc_info, live_fp, xchg, extra]


func _format_dev(info: Dictionary) -> String:
	var lat: Dictionary = info.get("latencies_ms", {})
	var sem: Dictionary = info.get("semantic", {})
	var sem_lat: Dictionary = sem.get("latencies_ms", {})
	return "last: ok=%s model=%s started_by_game=%s err=%s warm=%sms total=%sms\nlast semantic: ok=%s tag=%s err=%s total=%sms" % [
		str(info.get("ok", "?")), str(info.get("model", "?")),
		str(info.get("started_by_game", "?")), str(info.get("error_kind", "—")),
		str(lat.get("warmup_ms", "—")), str(lat.get("total_ms", "—")),
		str(sem.get("ok", "?")), str(sem.get("tag", "—")),
		str(sem.get("error_kind", "—")), str(sem_lat.get("total_ms", "—"))]


func _is_dev() -> bool:
	if OS.is_debug_build():
		return true
	for a in OS.get_cmdline_args():
		if a in ["--dev", "--step7-dev"]:
			return true
	return false

