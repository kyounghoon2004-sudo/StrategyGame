extends Control
## 인터뷰 모드 UI — 오대십국 전략 게임 전술 인터뷰 시스템
## 고전 전략/RPG 감성: 반투명 어두운 배경 + 금빛 테두리 픽셀 테마
## 타이핑 효과, 동적 선택지, 참모 초상화 지원
## 시그널 option_selected(option_id) 로 외부(헥스 맵/전투 시스템)와 연계

class_name InterviewPanel

signal option_selected(option_id: StringName)
signal dialogue_finished
signal interview_closed

## ── 설정 ──
@export var typing_speed: float = 38.0  ## 초당 글자 수
@export var auto_show_on_ready: bool = false

## ── 상태 ──
var _full_text: String = ""
var _is_typing: bool = false
var _typing_tween: Tween = null
var _current_options: Array[Dictionary] = []
var _is_visible_interview: bool = false

## ── 노드 참조 (tscn 구조와 동기화 — _ready에서 캐시) ──
var _dim_bg: ColorRect
var _dialog_panel: Panel
var _name_label: Label
var _title_label: Label
var _portrait_rect: TextureRect
var _dialogue_label: RichTextLabel
var _options_container: VBoxContainer
var _hint_label: Label

## ── 라이프사이클 ──
func _ready() -> void:
	_cache_nodes()
	if auto_show_on_ready:
		show_interview()
	else:
		visible = false
		# DimBackground는 visible=false로 시작 → show_interview에서 페이드 인

func _cache_nodes() -> void:
	_dim_bg = get_node_or_null("DimBackground") as ColorRect
	_dialog_panel = get_node_or_null("DimBackground/CenterContainer/DialogPanel") as Panel
	_name_label = get_node_or_null("DimBackground/CenterContainer/DialogPanel/Margin/MainVBox/Header/InfoVBox/NameLabel") as Label
	_title_label = get_node_or_null("DimBackground/CenterContainer/DialogPanel/Margin/MainVBox/Header/InfoVBox/TitleLabel") as Label
	_portrait_rect = get_node_or_null("DimBackground/CenterContainer/DialogPanel/Margin/MainVBox/Header/PortraitFrame/Portrait") as TextureRect
	_dialogue_label = get_node_or_null("DimBackground/CenterContainer/DialogPanel/Margin/MainVBox/DialogueScroll/DialogueLabel") as RichTextLabel
	_options_container = get_node_or_null("DimBackground/CenterContainer/DialogPanel/Margin/MainVBox/OptionsContainer") as VBoxContainer
	_hint_label = get_node_or_null("DimBackground/CenterContainer/DialogPanel/Margin/MainVBox/HintLabel") as Label
	if _dialogue_label:
		_dialogue_label.visible_characters = 0
		_dialogue_label.bbcode_enabled = true
		_dialogue_label.fit_content = true
	if _hint_label:
		_hint_label.visible = false

func _unhandled_input(event: InputEvent) -> void:
	if not visible or not _is_visible_interview:
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if _is_typing:
			skip_typing()
			get_viewport().set_input_as_handled()
		elif _current_options.is_empty():
			# 선택지 없이 대화만 있는 경우 클릭 시 닫기 힌트
			if _options_container and _options_container.get_child_count() == 0:
				pass
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_SPACE or event.keycode == KEY_ENTER:
			if _is_typing:
				skip_typing()
				get_viewport().set_input_as_handled()

## ── 공개 API ──

## 인터뷰 표시 — 페이드 인 + 대화 타이핑 시작
func show_interview() -> void:
	visible = true
	_is_visible_interview = true
	if _dim_bg:
		_dim_bg.color = Color(0, 0, 0, 0)
		var tw := create_tween()
		tw.tween_property(_dim_bg, "color", Color(0, 0, 0, 0.68), 0.28).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	if _dialog_panel:
		_dialog_panel.modulate = Color(1, 1, 1, 0)
		_dialog_panel.scale = Vector2(0.96, 0.96)
		var tw2 := create_tween().set_parallel(true)
		tw2.tween_property(_dialog_panel, "modulate", Color(1, 1, 1, 1), 0.32).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
		tw2.tween_property(_dialog_panel, "scale", Vector2(1, 1), 0.32).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

## 인터뷰 숨김 — 페이드 아웃
func hide_interview() -> void:
	if not _is_visible_interview:
		visible = false
		return
	_is_visible_interview = false
	_cancel_typing()
	var tw := create_tween()
	if _dim_bg:
		tw.tween_property(_dim_bg, "color", Color(0, 0, 0, 0), 0.22)
	if _dialog_panel:
		var tw2 := create_tween().set_parallel(true)
		tw2.tween_property(_dialog_panel, "modulate", Color(1, 1, 1, 0), 0.22)
		tw2.tween_property(_dialog_panel, "scale", Vector2(0.98, 0.98), 0.22)
	tw.tween_callback(func(): visible = false)
	interview_closed.emit()

## 참모 정보 + 브리핑 텍스트 + 선택지 세팅 (원샷)
## options 예시: [{"id": &"advance", "text": "전진한다", "tooltip": "보급 -2일", "disabled": false}, ...]
func setup_interview(staff_name: String, staff_title: String, portrait: Texture2D, briefing_text: String, options: Array) -> void:
	set_staff_info(staff_name, staff_title, portrait)
	set_briefing(briefing_text, options)
	show_interview()

func set_staff_info(staff_name: String, staff_title: String, portrait: Texture2D) -> void:
	if _name_label:
		_name_label.text = staff_name
	if _title_label:
		_title_label.text = staff_title
	if _portrait_rect:
		if portrait:
			_portrait_rect.texture = portrait
			_portrait_rect.visible = true
		else:
			# 폴백: 단색 플레이스홀더 유지
			_portrait_rect.visible = true

func set_briefing(text: String, options: Array = []) -> void:
	_full_text = text
	_current_options = []
	for o in options:
		if o is Dictionary:
			_current_options.append(o)
		elif o is String:
			_current_options.append({"id": StringName(o), "text": o})
	# 옵션 영역 초기화
	_clear_options()
	if _dialogue_label:
		_dialogue_label.text = _full_text
		_dialogue_label.visible_characters = 0
		_hint_label.visible = false
	_start_typing()

## 외부에서 턴/보급 정보를 헤더에 주입 (Battle HUD와 별개로 인터뷰창 자체 표시)
func set_header_extra(extra_text: String) -> void:
	if _title_label:
		# TitleLabel 아래 보조 정보로 활용 — 중복 호출 시 덮어쓰기
		pass

## ── 타이핑 효과 ──
func _start_typing() -> void:
	_cancel_typing()
	if _dialogue_label == null or _full_text.is_empty():
		_on_typing_finished()
		return
	_is_typing = true
	var char_count: int = _dialogue_label.get_total_character_count()
	if char_count == 0:
		# 텍스트 세팅 직후 아직 레이아웃 안 잡혔을 수 있어 next frame 재시도
		await get_tree().process_frame
		char_count = _dialogue_label.get_total_character_count()
		if char_count == 0:
			char_count = _full_text.length()
	var duration: float = float(char_count) / max(1.0, typing_speed)
	if duration < 0.05:
		_dialogue_label.visible_characters = -1
		_on_typing_finished()
		return
	_typing_tween = create_tween()
	_typing_tween.tween_property(_dialogue_label, "visible_characters", char_count, duration).set_trans(Tween.TRANS_LINEAR)
	_typing_tween.tween_callback(_on_typing_finished)

func skip_typing() -> void:
	if not _is_typing:
		return
	_cancel_typing()
	if _dialogue_label:
		_dialogue_label.visible_characters = -1
	_on_typing_finished()

func _cancel_typing() -> void:
	_is_typing = false
	if _typing_tween and _typing_tween.is_valid():
		_typing_tween.kill()
	_typing_tween = null

func _on_typing_finished() -> void:
	_is_typing = false
	_typing_tween = null
	if _dialogue_label:
		_dialogue_label.visible_characters = -1
	_build_options()
	dialogue_finished.emit()
	# 선택지 없이 대화만 끝나면 힌트 표시
	if _current_options.is_empty() and _hint_label:
		_hint_label.text = "▶ 클릭 또는 [Space] 로 계속"
		_hint_label.visible = true

## ── 선택지 동적 생성 ──
func _clear_options() -> void:
	if _options_container == null:
		return
	for child in _options_container.get_children():
		child.queue_free()

func _build_options() -> void:
	if _options_container == null:
		return
	_clear_options()
	if _current_options.is_empty():
		return
	for idx in range(_current_options.size()):
		var opt: Dictionary = _current_options[idx]
		var opt_id: StringName = StringName(opt.get("id", "option_%d" % idx))
		var opt_text: String = str(opt.get("text", "선택지 %d" % (idx + 1)))
		var opt_tooltip: String = str(opt.get("tooltip", ""))
		var opt_disabled: bool = bool(opt.get("disabled", false))
		var opt_icon: Texture2D = opt.get("icon", null) as Texture2D

		var btn := Button.new()
		btn.text = "%d. %s" % [idx + 1, opt_text]
		btn.tooltip_text = opt_tooltip
		btn.disabled = opt_disabled
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.custom_minimum_size = Vector2(0, 38)
		# 숫자키 단축키 힌트
		if idx < 9:
			btn.text += "  [%d]" % (idx + 1)
		if opt_icon:
			btn.icon = opt_icon
			btn.expand_icon = true

		# 클릭 시그널 — id 캡처
		var captured_id: StringName = opt_id
		btn.pressed.connect(func(): _on_option_pressed(captured_id))

		# 페이드 인 연출 (순차)
		btn.modulate = Color(1, 1, 1, 0)
		_options_container.add_child(btn)
		var tw := create_tween()
		tw.tween_property(btn, "modulate", Color(1, 1, 1, 1), 0.18).set_delay(idx * 0.06)

	# 키보드 1/2/3 선택 지원: _unhandled_key_input에서 처리하려면 별도 InputMap 불필요 — _input에서 체크
	if _hint_label:
		_hint_label.text = "번호키 [1-%d] 또는 클릭으로 선택" % _current_options.size()
		_hint_label.visible = true

func _on_option_pressed(option_id: StringName) -> void:
	# 연출: 선택된 버튼 하이라이트 후 시그널
	option_selected.emit(option_id)
	# 선택 후 즉시 닫지 않음 — 외부에서 hide_interview() 결정 (헥스 가이드라인 표시 등)

func _input(event: InputEvent) -> void:
	if not visible or not _is_visible_interview or _is_typing:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		# 숫자키 1-9로 선택지 선택
		if _current_options.size() > 0:
			var num: int = -1
			if event.keycode >= KEY_1 and event.keycode <= KEY_9:
				num = int(event.keycode - KEY_1)
			elif event.keycode >= KEY_KP_1 and event.keycode <= KEY_KP_9:
				num = int(event.keycode - KEY_KP_1)
			if num >= 0 and num < _current_options.size():
				var opt: Dictionary = _current_options[num]
				if not bool(opt.get("disabled", false)):
					_on_option_pressed(StringName(opt.get("id", "option_%d" % num)))
					get_viewport().set_input_as_handled()

## ── 외부 유틸: 현재 타이핑 중인지 ──
func is_typing() -> bool:
	return _is_typing

func _on_close_pressed() -> void:
	hide_interview()

## 테스트/데모용 원샷 헬퍼
func demo_show_sample() -> void:
	var sample_text := "주공, 전황을 아뢰옵니다. 적의 보급로가 노출되어 있사오니, 지금이 결단의 시점이옵니다. 세 가지 방책을 올리오니, 하나를 택하여 주시옵소서."
	var sample_options: Array = [
		{"id": &"advance", "text": "전군 전진 — 적 보급로 차단", "tooltip": "이동 가이드라인: 북진 3헥스 / 사기 +5"},
		{"id": &"siege", "text": "포위 후 공성 — 성벽을 에워싼다", "tooltip": "공성병 필수 / 보급 -3일"},
		{"id": &"retreat", "text": "일단 후퇴 — 전열을 재정비한다", "tooltip": "피해 최소화 / 명성 -10"},
	]
	setup_interview("제갈량", "군사 · 병조참의", null, sample_text, sample_options)
