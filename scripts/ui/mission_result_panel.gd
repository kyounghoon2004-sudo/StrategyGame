extends Control
## 임무 브리핑 & 결과 창 — 오대십국 전략 게임
## 왕의 칙령(어명) 연출 + 전투 종료 후 전과 보고서
## 두 모드를 하나의 패널에서 전환: BRIEFING(출정 전) / RESULT(전투 후)

class_name MissionResultPanel

signal confirmed
signal dismissed
signal briefing_confirmed

enum Mode { BRIEFING, RESULT }

## ── 상태 ──
var _mode: int = Mode.RESULT
var _is_visible_panel: bool = false

## ── 노드 캐시 ──
var _dim_bg: ColorRect
var _main_panel: Panel
var _title_label: Label
var _subtitle_label: Label
var _seal_label: Label
var _briefing_text: RichTextLabel
var _result_grid: GridContainer
var _casualty_ally: Label
var _casualty_enemy: Label
var _prisoners_label: Label
var _loot_label: Label
var _fame_label: Label
var _reputation_label: Label
var _extra_info: RichTextLabel
var _confirm_btn: Button
var _dismiss_btn: Button
var _result_section: VBoxContainer
var _briefing_section: VBoxContainer

func _ready() -> void:
	_cache_nodes()
	visible = false
	_is_visible_panel = false

func _cache_nodes() -> void:
	_dim_bg = get_node_or_null("DimBackground") as ColorRect
	_main_panel = get_node_or_null("DimBackground/CenterContainer/MainPanel") as Panel
	_title_label = get_node_or_null("DimBackground/CenterContainer/MainPanel/Margin/VBox/Title") as Label
	_subtitle_label = get_node_or_null("DimBackground/CenterContainer/MainPanel/Margin/VBox/Subtitle") as Label
	_seal_label = get_node_or_null("DimBackground/CenterContainer/MainPanel/Margin/VBox/SealRow/Seal") as Label
	_briefing_text = get_node_or_null("DimBackground/CenterContainer/MainPanel/Margin/VBox/BriefingSection/BriefingText") as RichTextLabel
	_briefing_section = get_node_or_null("DimBackground/CenterContainer/MainPanel/Margin/VBox/BriefingSection") as VBoxContainer
	_result_section = get_node_or_null("DimBackground/CenterContainer/MainPanel/Margin/VBox/ResultSection") as VBoxContainer
	_result_grid = get_node_or_null("DimBackground/CenterContainer/MainPanel/Margin/VBox/ResultSection/ResultGrid") as GridContainer
	_casualty_ally = get_node_or_null("DimBackground/CenterContainer/MainPanel/Margin/VBox/ResultSection/ResultGrid/AllyCasValue") as Label
	_casualty_enemy = get_node_or_null("DimBackground/CenterContainer/MainPanel/Margin/VBox/ResultSection/ResultGrid/EnemyCasValue") as Label
	_prisoners_label = get_node_or_null("DimBackground/CenterContainer/MainPanel/Margin/VBox/ResultSection/ResultGrid/PrisonersValue") as Label
	_loot_label = get_node_or_null("DimBackground/CenterContainer/MainPanel/Margin/VBox/ResultSection/ResultGrid/LootValue") as Label
	_fame_label = get_node_or_null("DimBackground/CenterContainer/MainPanel/Margin/VBox/ResultSection/ResultGrid/FameValue") as Label
	_reputation_label = get_node_or_null("DimBackground/CenterContainer/MainPanel/Margin/VBox/ResultSection/ResultGrid/ReputationValue") as Label
	_extra_info = get_node_or_null("DimBackground/CenterContainer/MainPanel/Margin/VBox/ResultSection/ExtraInfo") as RichTextLabel
	_confirm_btn = get_node_or_null("DimBackground/CenterContainer/MainPanel/Margin/VBox/Buttons/ConfirmBtn") as Button
	_dismiss_btn = get_node_or_null("DimBackground/CenterContainer/MainPanel/Margin/VBox/Buttons/DismissBtn") as Button
	if _confirm_btn and not _confirm_btn.pressed.is_connected(_on_confirm_pressed):
		_confirm_btn.pressed.connect(_on_confirm_pressed)
	if _dismiss_btn and not _dismiss_btn.pressed.is_connected(_on_dismiss_pressed):
		_dismiss_btn.pressed.connect(_on_dismiss_pressed)
	# 닫기 버튼 (헤더 X)
	var close_btn: Button = get_node_or_null("DimBackground/CenterContainer/MainPanel/Margin/VBox/HeaderRow/CloseBtn") as Button
	if close_btn and not close_btn.pressed.is_connected(_on_dismiss_pressed):
		close_btn.pressed.connect(_on_dismiss_pressed)

## ── 공개 API ──

## 왕의 칙령(브리핑) 모드 표시
## 어명 연출: 예) "짐이 명하노니, 하북을 평정하라"
func show_briefing(king_title: String, decree_text: String, objective_text: String = "") -> void:
	_mode = Mode.BRIEFING
	_apply_mode()
	if _title_label:
		_title_label.text = king_title if king_title != "" else "어명"
	if _subtitle_label:
		_subtitle_label.text = "왕의 칙령"
	if _seal_label:
		_seal_label.text = "玉璽"
	if _briefing_text:
		var bb: String = "[center][color=#d4a843][b]%s[/b][/color][/center]\n\n%s" % [decree_text, objective_text]
		if objective_text != "":
			bb += "\n\n[color=#8a8070]— 목표 —[/color]\n%s" % objective_text
		_briefing_text.text = bb
	if _confirm_btn:
		_confirm_btn.text = "출정한다"
		_confirm_btn.visible = true
	if _dismiss_btn:
		_dismiss_btn.text = "뒤로"
		_dismiss_btn.visible = true
	_show_panel()

## 전과 보고서 모드 표시
## data 예시: {"ally_casualties": 120, "enemy_casualties": 340, "prisoners": 45, "loot": "군량 300석", "fame_delta": 15, "reputation_delta": 8, "extra": "추가 보고..."}
func show_result(data: Dictionary) -> void:
	_mode = Mode.RESULT
	_apply_mode()
	if _title_label:
		_title_label.text = "전과 보고"
	if _subtitle_label:
		var is_victory: bool = bool(data.get("is_victory", true))
		_subtitle_label.text = "대승" if is_victory else "전투 종료"
		if is_victory:
			_subtitle_label.add_theme_color_override("font_color", Color(0.98, 0.92, 0.6, 1))
		else:
			_subtitle_label.add_theme_color_override("font_color", Color(0.9, 0.6, 0.5, 1))
	if _seal_label:
		_seal_label.text = "戰報"

	var ally_cas: int = int(data.get("ally_casualties", data.get("ally_cas", 0)))
	var enemy_cas: int = int(data.get("enemy_casualties", data.get("enemy_cas", 0)))
	var prisoners: int = int(data.get("prisoners", 0))
	var loot: String = str(data.get("loot", data.get("loot_text", "없음")))
	var fame: int = int(data.get("fame_delta", data.get("fame", 0)))
	var rep: int = int(data.get("reputation_delta", data.get("reputation", 0)))
	var extra: String = str(data.get("extra", data.get("extra_info", "")))

	if _casualty_ally:
		_casualty_ally.text = "%d명" % ally_cas
		_casualty_ally.add_theme_color_override("font_color", Color(0.95, 0.5, 0.45, 1) if ally_cas > 200 else Color(0.92, 0.88, 0.78, 1))
	if _casualty_enemy:
		_casualty_enemy.text = "%d명" % enemy_cas
		_casualty_enemy.add_theme_color_override("font_color", Color(0.5, 0.85, 0.5, 1) if enemy_cas > ally_cas else Color(0.92, 0.88, 0.78, 1))
	if _prisoners_label:
		_prisoners_label.text = "%d명" % prisoners if prisoners > 0 else "없음"
	if _loot_label:
		_loot_label.text = loot
	if _fame_label:
		_fame_label.text = ("%+d" % fame) if fame != 0 else "±0"
		if fame > 0:
			_fame_label.add_theme_color_override("font_color", Color(0.98, 0.92, 0.6, 1))
		elif fame < 0:
			_fame_label.add_theme_color_override("font_color", Color(0.95, 0.4, 0.35, 1))
		else:
			_fame_label.remove_theme_color_override("font_color")
	if _reputation_label:
		_reputation_label.text = ("%+d" % rep) if rep != 0 else "±0"
		if rep > 0:
			_reputation_label.add_theme_color_override("font_color", Color(0.5, 0.85, 0.5, 1))
		elif rep < 0:
			_reputation_label.add_theme_color_override("font_color", Color(0.95, 0.4, 0.35, 1))
		else:
			_reputation_label.remove_theme_color_override("font_color")
	if _extra_info:
		if extra != "":
			_extra_info.text = extra
			_extra_info.visible = true
		else:
			_extra_info.visible = false
	if _confirm_btn:
		_confirm_btn.text = "확인"
		_confirm_btn.visible = true
	if _dismiss_btn:
		_dismiss_btn.visible = false
	_show_panel()

## 패널 숨김
func hide_panel() -> void:
	if not _is_visible_panel:
		visible = false
		return
	_is_visible_panel = false
	var tw := create_tween().set_parallel(true)
	if _dim_bg:
		tw.tween_property(_dim_bg, "color", Color(0, 0, 0, 0), 0.2)
	if _main_panel:
		tw.tween_property(_main_panel, "modulate", Color(1, 1, 1, 0), 0.2)
		tw.tween_property(_main_panel, "scale", Vector2(0.98, 0.98), 0.2)
	tw.chain().tween_callback(func(): visible = false)
	dismissed.emit()

## ── 내부 ──
func _apply_mode() -> void:
	if _briefing_section and _result_section:
		_briefing_section.visible = (_mode == Mode.BRIEFING)
		_result_section.visible = (_mode == Mode.RESULT)

func _show_panel() -> void:
	visible = true
	_is_visible_panel = true
	if _dim_bg:
		_dim_bg.color = Color(0, 0, 0, 0)
		var tw := create_tween()
		tw.tween_property(_dim_bg, "color", Color(0, 0, 0, 0.72), 0.28).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	if _main_panel:
		_main_panel.modulate = Color(1, 1, 1, 0)
		_main_panel.scale = Vector2(0.94, 0.94)
		var tw2 := create_tween().set_parallel(true)
		tw2.tween_property(_main_panel, "modulate", Color(1, 1, 1, 1), 0.32).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
		tw2.tween_property(_main_panel, "scale", Vector2(1, 1), 0.32).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

func _on_confirm_pressed() -> void:
	if _mode == Mode.BRIEFING:
		briefing_confirmed.emit()
		confirmed.emit()
	else:
		confirmed.emit()
	hide_panel()

func _on_dismiss_pressed() -> void:
	hide_panel()

func _unhandled_input(event: InputEvent) -> void:
	if not visible or not _is_visible_panel:
		return
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_ESCAPE:
			hide_panel()
			get_viewport().set_input_as_handled()
		elif event.keycode == KEY_ENTER or event.keycode == KEY_SPACE:
			_on_confirm_pressed()
			get_viewport().set_input_as_handled()

## ── 데모용 ──
func demo_show_briefing() -> void:
	show_briefing("칙령", "짐이 명하노니, 하북의 반란을 평정하고 백성을 안정케 하라.", "· 하북 3성을 10일 내 점령\n· 아군 사상 500명 이하\n· 보급 15일 이상 유지")

func demo_show_result(victory: bool = true) -> void:
	show_result({
		"is_victory": victory,
		"ally_casualties": 87,
		"enemy_casualties": 312,
		"prisoners": 48,
		"loot": "군량 420석 · 병기 60벌",
		"fame_delta": 18,
		"reputation_delta": 12,
		"extra": "[color=#8a8070]포로 중 적 장수 1명이 투항을 청하고 있다.[/color]"
	})
