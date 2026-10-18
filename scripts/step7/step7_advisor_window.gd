class_name Step7AdvisorWindow
extends PanelContainer
signal close_requested

## PLAYER-FACING tactical Advisor window (deterministic front-end).
##
## Visual shell reuses the project's accepted Advisor language —
## InterviewPanel's dark/gold lacquer + portrait header + dialogue brief,
## TacticalSidebar's portrait/dialogue/tactic-button composition — but as a
## compact right-dock panel so the map stays the primary surface.
## No chat input, no model-backend wiring, no token delivery: six compact
## tactical cards driven by Step7AdvisorViewModel over the deterministic evaluator.
##
## Layout contract (§19): fixed right-dock rect inside the viewport,
## internal ScrollContainer for the cards only, header/footer always
## retained, collapsible via the header toggle.

const ViewModelScript = preload("res://scripts/step7/step7_advisor_viewmodel.gd")
const DevModeScript = preload("res://scripts/step7/step7_dev_mode.gd")

var controller = null # Step7AdvisorAdapter (untyped: avoids cyclic class ref)

var _body: VBoxContainer = null
var _collapse_btn: Button = null
var _portrait: TextureRect = null
var _title_lbl: Label = null
var _sub_lbl: Label = null
var _brief_lbl: Label = null
var _scope_lbl: Label = null
var _card_box: VBoxContainer = null
var _detail_lbl: Label = null
var _status_lbl: Label = null
var _overlay_check: CheckButton = null
var _exec_btn: Button = null
var _cancel_btn: Button = null
var _card_btns: Dictionary = {} # slot -> Button
var _card_avail: Dictionary = {} # slot -> bool (evaluator availability)
var _approval_on := false # staged chat plan awaiting [실행]/[취소]
var _card_can_exec := false
var _card_can_cancel := false
var _ui_locked := false
var _last_cards: Array = []
var _recommended_slot := 0 # option slot highlighted as ★ 서유선 추천, 0 = none
var _selected_slot := -1
var _llm_lbl: Label = null
var _llm_refresh_btn: Button = null
var _llm_row = null # HBoxContainer (legacy DEV refresh row)
var _cards_scroll: ScrollContainer = null
var _footer = null # HBoxContainer (DEV card footer)
var _chat_history: RichTextLabel = null
var _chat_input: LineEdit = null
var _chat_send_btn: Button = null
var _dev_llm_lbl: Label = null
var _collapsed := false
## Embedded mode: fill the parent right-dock section instead of
## self-anchoring as a standalone dock (geometry owned by the dock).
var embedded := false


func _ready() -> void:
	_build()


func bind(advisor_controller) -> void:
	controller = advisor_controller


func _lacquer() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.065, 0.075, 0.095, 0.95)
	sb.border_color = Color(0.72, 0.60, 0.30, 0.9)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(4)
	sb.shadow_color = Color(0, 0, 0, 0.7)
	sb.shadow_size = 6
	return sb


func _build() -> void:
	if embedded:
		size_flags_vertical = Control.SIZE_EXPAND_FILL
		size_flags_horizontal = Control.SIZE_EXPAND_FILL
	else:
		# Standalone LEFT-dock footprint (legacy): narrow, viewport-bounded.
		set_anchors_preset(Control.PRESET_TOP_LEFT)
		anchor_bottom = 1.0
		offset_left = 8
		offset_right = 372
		offset_top = 70
		offset_bottom = -300
		grow_horizontal = Control.GROW_DIRECTION_END
	custom_minimum_size = Vector2(320, 240)
	add_theme_stylebox_override("panel", _lacquer())
	name = "AdvisorWindow"

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 6)
	root.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(root)

	# --- Header: portrait + title + collapse (always retained) ---
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 8)
	root.add_child(header)
	_portrait = TextureRect.new()
	_portrait.custom_minimum_size = Vector2(56, 56)
	_portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_portrait.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	if ResourceLoader.exists("res://assets/ui/portrait_advisor.png"):
		_portrait.texture = load("res://assets/ui/portrait_advisor.png") as Texture2D
	header.add_child(_portrait)
	var title_box := VBoxContainer.new()
	title_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_box.alignment = BoxContainer.ALIGNMENT_CENTER
	header.add_child(title_box)
	_title_lbl = Label.new()
	_title_lbl.text = "전술 조언 · 서유선"
	_title_lbl.add_theme_font_size_override("font_size", 15)
	_title_lbl.add_theme_color_override("font_color", Color(0.92, 0.82, 0.45, 1.0))
	title_box.add_child(_title_lbl)
	_sub_lbl = Label.new()
	_sub_lbl.text = "부대 미선택"
	_sub_lbl.add_theme_font_size_override("font_size", 11)
	_sub_lbl.add_theme_color_override("font_color", Color(0.72, 0.70, 0.64, 1.0))
	title_box.add_child(_sub_lbl)
	_collapse_btn = Button.new()
	_collapse_btn.text = "[–]"
	_collapse_btn.focus_mode = Control.FOCUS_NONE
	_collapse_btn.tooltip_text = "참모창 접기/펼치기"
	_collapse_btn.pressed.connect(_on_collapse)
	header.add_child(_collapse_btn)
	var close_btn := Button.new()
	close_btn.name = "CloseBtn"
	close_btn.text = "X"
	close_btn.focus_mode = Control.FOCUS_NONE
	close_btn.tooltip_text = "조언창 닫기"
	close_btn.pressed.connect(func(): close_requested.emit())
	header.add_child(close_btn)

	# --- Collapsible body ---
	_body = VBoxContainer.new()
	_body.add_theme_constant_override("separation", 6)
	_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(_body)

	_brief_lbl = Label.new()
	_brief_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_brief_lbl.add_theme_font_size_override("font_size", 13)
	_brief_lbl.add_theme_color_override("font_color", Color(0.92, 0.90, 0.84, 1.0))
	_brief_lbl.text = ViewModelScript.neutral_briefing()
	_body.add_child(_brief_lbl)

	_scope_lbl = Label.new()
	_scope_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_scope_lbl.add_theme_font_size_override("font_size", 12)
	_scope_lbl.add_theme_color_override("font_color", Color(0.78, 0.65, 0.32, 1.0))
	_body.add_child(_scope_lbl)

	_cards_scroll = ScrollContainer.new()
	_cards_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_cards_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_cards_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_body.add_child(_cards_scroll)
	_card_box = VBoxContainer.new()
	_card_box.add_theme_constant_override("separation", 4)
	_card_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_cards_scroll.add_child(_card_box)

	_detail_lbl = Label.new()
	_detail_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_detail_lbl.add_theme_font_size_override("font_size", 12)
	_detail_lbl.add_theme_color_override("font_color", Color(0.92, 0.90, 0.84, 1.0))
	_body.add_child(_detail_lbl)

	# --- Ollama Advisor verdict (recommendation highlight + rationale) ---
	_llm_lbl = Label.new()
	_llm_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_llm_lbl.add_theme_font_size_override("font_size", 12)
	_llm_lbl.add_theme_color_override("font_color", Color(0.95, 0.86, 0.55, 1.0))
	_body.add_child(_llm_lbl)

	_llm_row = HBoxContainer.new()
	_llm_row.add_theme_constant_override("separation", 6)
	_body.add_child(_llm_row)
	_llm_refresh_btn = Button.new()
	_llm_refresh_btn.text = "전술 자문 요청"
	_llm_refresh_btn.focus_mode = Control.FOCUS_NONE
	_llm_refresh_btn.tooltip_text = "서유선에게 현재 전황의 자문을 다시 청합니다"
	_llm_refresh_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_llm_refresh_btn.pressed.connect(_on_llm_refresh)
	_llm_row.add_child(_llm_refresh_btn)

	# --- Chat: the primary PLAYER command interface ---
	_chat_history = RichTextLabel.new()
	_chat_history.bbcode_enabled = false
	_chat_history.scroll_following = true
	_chat_history.scroll_active = true
	_chat_history.custom_minimum_size = Vector2(0, 130)
	_chat_history.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_chat_history.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_chat_history.add_theme_font_size_override("normal_font_size", 12)
	_chat_history.add_theme_color_override("default_color", Color(0.92, 0.90, 0.84, 1.0))
	_body.add_child(_chat_history)
	var chat_row := HBoxContainer.new()
	chat_row.add_theme_constant_override("separation", 6)
	_body.add_child(chat_row)
	_chat_input = LineEdit.new()
	_chat_input.placeholder_text = "명령 또는 질문 입력... (예: 좌익 기병대를 전진시켜)"
	_chat_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_chat_input.text_submitted.connect(_on_chat_submitted)
	chat_row.add_child(_chat_input)
	_chat_send_btn = Button.new()
	_chat_send_btn.text = "보내기"
	_chat_send_btn.focus_mode = Control.FOCUS_NONE
	_chat_send_btn.tooltip_text = "서유선에게 명령·질문을 보냅니다"
	_chat_send_btn.pressed.connect(_on_chat_send)
	chat_row.add_child(_chat_send_btn)

	_dev_llm_lbl = Label.new()
	_dev_llm_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_dev_llm_lbl.add_theme_font_size_override("font_size", 10)
	_dev_llm_lbl.add_theme_color_override("font_color", Color(0.55, 0.58, 0.60, 1.0))
	_dev_llm_lbl.visible = DevModeScript.is_dev_mode()
	_body.add_child(_dev_llm_lbl)

	# --- Footer (DEV card flow; hidden in PLAYER chat flow) ---
	_footer = HBoxContainer.new()
	_footer.add_theme_constant_override("separation", 6)
	_body.add_child(_footer)
	_overlay_check = CheckButton.new()
	_overlay_check.text = "전술 구역 보기"
	_overlay_check.focus_mode = Control.FOCUS_NONE
	_overlay_check.toggled.connect(_on_overlay_toggled)
	_footer.add_child(_overlay_check)
	_exec_btn = Button.new()
	_exec_btn.text = "실행"
	_exec_btn.focus_mode = Control.FOCUS_NONE
	_exec_btn.disabled = true
	_exec_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_exec_btn.pressed.connect(_on_execute)
	_footer.add_child(_exec_btn)
	_cancel_btn = Button.new()
	_cancel_btn.text = "취소"
	_cancel_btn.focus_mode = Control.FOCUS_NONE
	_cancel_btn.disabled = true
	_cancel_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_cancel_btn.pressed.connect(_on_cancel)
	_footer.add_child(_cancel_btn)

	_status_lbl = Label.new()
	_status_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_lbl.add_theme_font_size_override("font_size", 11)
	_status_lbl.add_theme_color_override("font_color", Color(0.65, 0.62, 0.52, 1.0))
	_body.add_child(_status_lbl)
	refresh_mode()


func _on_collapse() -> void:
	_collapsed = not _collapsed
	_body.visible = not _collapsed
	_collapse_btn.text = "[+]" if _collapsed else "[–]"


func _on_overlay_toggled(on: bool) -> void:
	if controller != null and controller.has_method("set_tactical_overlay"):
		controller.set_tactical_overlay(on)


func _on_execute() -> void:
	# Staged chat plan wins; DEV card pick is the fallback (routed in adapter).
	if controller != null and controller.has_method("on_execute_button"):
		controller.on_execute_button()
	elif controller != null and controller.has_method("execute_selected"):
		controller.execute_selected()


func _on_cancel() -> void:
	if controller != null and controller.has_method("on_cancel_button"):
		controller.on_cancel_button()
	elif controller != null and controller.has_method("cancel"):
		controller.cancel()


func _on_llm_refresh() -> void:
	if controller != null and controller.has_method("request_llm_advice"):
		controller.request_llm_advice()


func _on_chat_send() -> void:
	if _chat_input == null:
		return
	var text := _chat_input.text.strip_edges()
	if text.is_empty():
		return
	_chat_input.text = ""
	if controller != null and controller.has_method("send_chat"):
		controller.send_chat(text)


func _on_chat_submitted(_text: String) -> void:
	_on_chat_send()


# --- Chat render API (primary PLAYER interface) ---

func append_chat(author: String, text: String) -> void:
	if _chat_history == null:
		return
	var prefix := "주공"
	if author == "ADVISOR":
		prefix = "서유선"
	elif author == "SYSTEM":
		prefix = "알림"
	_chat_history.append_text("%s: %s\n" % [prefix, text])


func set_chat_busy(b: bool) -> void:
	if _chat_input != null:
		_chat_input.editable = not b
	if _chat_send_btn != null:
		_chat_send_btn.disabled = b


func clear_chat() -> void:
	if _chat_history != null:
		_chat_history.clear()


## PLAYER: chat + [실행]/[취소] approval (six cards + legacy verdict hidden).
## DEV: full surfaces (cards, legacy refresh, diagnostics).
func refresh_mode() -> void:
	var dev := DevModeScript.is_dev_mode()
	if _cards_scroll != null:
		_cards_scroll.visible = dev
	if _detail_lbl != null:
		_detail_lbl.visible = dev
	if _footer != null:
		_footer.visible = true
	if _overlay_check != null:
		_overlay_check.visible = true
	if _llm_row != null:
		_llm_row.visible = dev
	if _llm_lbl != null:
		_llm_lbl.visible = dev
	if _dev_llm_lbl != null and not dev:
		_dev_llm_lbl.visible = false
	_refresh_exec_buttons()


# --- Render API (called by the adapter; data only, no engine reads) ---

func show_neutral() -> void:
	_sub_lbl.text = "부대 미선택"
	_brief_lbl.text = ViewModelScript.neutral_briefing()
	_scope_lbl.text = ""
	_rebuild_cards([])
	_detail_lbl.text = ""
	set_footer(false, false, "")
	_set_selected_visual(-1)


func show_unsupported(unit_label: String, class_label: String) -> void:
	_sub_lbl.text = unit_label
	_brief_lbl.text = ViewModelScript.unsupported_briefing(class_label)
	_scope_lbl.text = ""
	_rebuild_cards([])
	_detail_lbl.text = ""
	set_footer(false, false, "")


func show_unit(unit_label: String, scope_text: String, briefing: String, cards: Array) -> void:
	_sub_lbl.text = unit_label
	_brief_lbl.text = briefing
	_scope_lbl.text = scope_text
	_rebuild_cards(cards)
	_detail_lbl.text = ""
	set_footer(false, false, "")


func _rebuild_cards(cards: Array) -> void:
	for c in _card_box.get_children():
		c.queue_free()
	_card_btns.clear()
	_card_avail.clear()
	_last_cards = cards.duplicate(true)
	for card_val in cards:
		if not card_val is Dictionary:
			continue
		var card: Dictionary = card_val
		var b := Button.new()
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.focus_mode = Control.FOCUS_NONE
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var slot := int(card.get("slot", 0))
		var text := str(card.get("title", "?"))
		if slot == _recommended_slot and bool(card.get("available", false)):
			text = "★ 서유선 추천 · " + text
		if not bool(card.get("available", false)):
			b.disabled = true
			text += "\n" + str(card.get("note", "현재 실행 가능한 경로 없음"))
		else:
			for line in (card.get("lines", []) as Array):
				text += "\n  " + str(line)
			if str(card.get("note", "")).length() > 0:
				text += "\n" + str(card.get("note", ""))
		b.text = text
		b.pressed.connect(_on_card.bind(slot))
		_card_box.add_child(b)
		_card_btns[slot] = b
		_card_avail[slot] = bool(card.get("available", false))
	_refresh_card_visuals()


func _on_card(slot: int) -> void:
	if controller != null and controller.has_method("select_option"):
		controller.select_option(slot)


func _set_selected_visual(slot: int) -> void:
	_selected_slot = slot
	_refresh_card_visuals()


## Player's armed selection wins the strong highlight; the Advisor
## recommendation keeps a distinct restrained gold tint underneath.
func _refresh_card_visuals() -> void:
	for s in _card_btns:
		var b: Button = _card_btns[s]
		if int(s) == _selected_slot:
			b.modulate = Color(1.0, 0.88, 0.55)
		elif int(s) == _recommended_slot:
			b.modulate = Color(1.0, 0.96, 0.72)
		else:
			b.modulate = Color.WHITE


func set_selected(slot: int, detail: String, can_execute: bool) -> void:
	_set_selected_visual(slot)
	_detail_lbl.text = detail
	set_footer(can_execute, true, "")


func set_footer(can_execute: bool, can_cancel: bool, status: String) -> void:
	_card_can_exec = can_execute
	_card_can_cancel = can_cancel
	_refresh_exec_buttons()
	if not status.is_empty():
		_status_lbl.text = status


## Staged-plan approval affordance: [실행]/[취소] live only with a plan.
func set_approval(on: bool) -> void:
	_approval_on = on
	_refresh_exec_buttons()


func is_overlay_checked() -> bool:
	return _overlay_check != null and bool(_overlay_check.button_pressed)


func _refresh_exec_buttons() -> void:
	var exec_on := (_approval_on or _card_can_exec) and not _ui_locked
	var cancel_on := (_approval_on or _card_can_cancel) and not _ui_locked
	if _exec_btn != null:
		_exec_btn.disabled = not exec_on
	if _cancel_btn != null:
		_cancel_btn.disabled = not cancel_on


func set_status(status: String) -> void:
	_status_lbl.text = status


func set_busy(b: bool) -> void:
	_ui_locked = b
	_refresh_exec_buttons()
	for s in _card_btns:
		var btn: Button = _card_btns[s]
		btn.disabled = b or not bool(_card_avail.get(int(s), false))


func clear_preview_state() -> void:
	_set_selected_visual(-1)
	_detail_lbl.text = ""
	_card_can_exec = false
	_card_can_cancel = false
	_refresh_exec_buttons()


# --- Ollama Advisor render API (recommendation display only) ---------------

static func confidence_word(v: float) -> String:
	if v >= 0.75:
		return "높음"
	if v >= 0.5:
		return "보통"
	return "낮음"


func show_llm_loading() -> void:
	_llm_lbl.text = "서유선이 전황을 검토 중입니다..."
	if DevModeScript.is_dev_mode():
		_dev_llm_lbl.visible = true


func show_llm_recommendation(rec: Dictionary) -> void:
	var profile := str(rec.get("profile", "?")).to_upper()
	var title := ViewModelScript.profile_kr(profile)
	var lines: Array = ["★ 서유선 추천: %s(%s) · 확신 %s" % [
		title, profile, confidence_word(float(rec.get("confidence", 0.0)))]]
	lines.append(str(rec.get("reason", "")))
	lines.append("주요 위험: " + str(rec.get("primary_risk", "")))
	var alt := str(rec.get("alternative_profile", ""))
	if not alt.is_empty():
		lines.append("차선: %s(%s) — %s" % [
			ViewModelScript.profile_kr(alt), alt, str(rec.get("alternative_reason", ""))])
	var assess := str(rec.get("battlefield_assessment", "")).strip_edges()
	if not assess.is_empty():
		lines.append("전황: " + assess)
	_llm_lbl.text = "\n".join(lines)
	_recommended_slot = int(rec.get("slot", 0))
	if not _last_cards.is_empty():
		_rebuild_cards(_last_cards)
	else:
		_refresh_card_visuals()
	if DevModeScript.is_dev_mode():
		_dev_llm_lbl.visible = true
		_dev_llm_lbl.text = "DEV 자문: model=%s req=%s sv=%d latency=%dms prompt/eval=%d/%d" % [
			str(rec.get("model", "?")), str(rec.get("request_id", "?")),
			int(rec.get("state_version", -1)),
			int(rec.get("latency_ms", 0)), int(rec.get("prompt_eval_count", 0)),
			int(rec.get("eval_count", 0))]


## DEV-only backend diagnostic line (safe snapshot text from the adapter;
## never contains the API key). No-op in PLAYER mode visibility.
func set_llm_dev(text: String) -> void:
	if DevModeScript.is_dev_mode():
		_dev_llm_lbl.visible = true
		_dev_llm_lbl.text = text


func show_llm_unavailable(msg: String) -> void:
	_recommended_slot = 0
	_llm_lbl.text = msg
	_refresh_card_visuals()
	if DevModeScript.is_dev_mode():
		_dev_llm_lbl.visible = true


func clear_llm_state() -> void:
	_recommended_slot = 0
	_llm_lbl.text = ""
	_dev_llm_lbl.text = ""
	_refresh_card_visuals()


func set_overlay_state(on: bool) -> void:
	if _overlay_check != null:
		_overlay_check.set_pressed_no_signal(on)


## Test/audit helper: every player-visible string in the window.
func player_texts() -> Array:
	var out: Array = []
	for lbl in [_title_lbl, _sub_lbl, _brief_lbl, _scope_lbl, _detail_lbl, _status_lbl, _llm_lbl]:
		if lbl != null:
			out.append(str((lbl as Label).text))
	if _chat_history != null:
		out.append(_chat_history.get_parsed_text())
	for s in _card_btns:
		out.append(str((_card_btns[s] as Button).text))
	if _llm_refresh_btn != null:
		out.append(str(_llm_refresh_btn.text))
	return out
