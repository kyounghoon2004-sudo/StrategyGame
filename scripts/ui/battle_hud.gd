extends Control
## 전술 맵 HUD — 오대십국 전략 게임 헥스 전장 오버레이
## 상단 전황 바 (턴/보급/군세/사기) + 부대 상태 카드 + 행동 버튼
## TurnManager 시그널과 결합 가능한 모듈형 구조 — 외부에서 update_*() 호출 또는 시그널 연결

class_name BattleHUD

signal action_requested(action_id: StringName, unit)
signal unit_card_closed
signal hud_phase_clicked

## ── 노드 캐시 ──
var _turn_label: Label
var _phase_label: Label
var _supply_label: Label
var _supply_icon: Label
var _troop_label: Label
var _force_bar: ProgressBar
var _force_label: Label
var _morale_bar: ProgressBar
var _morale_label: Label
var _unit_card: Panel
var _unit_icon: TextureRect
var _unit_name: Label
var _unit_count: Label
var _unit_morale_bar: ProgressBar
var _unit_morale_label: Label
var _unit_morale_state: Label
var _unit_move_label: Label
var _unit_atk_label: Label
var _unit_def_label: Label
var _unit_supply_label: Label
var _unit_pos_label: Label
var _btn_confirm: Button
var _btn_wait: Button
var _btn_split: Button
var _btn_merge: Button
var _btn_retreat: Button
var _top_bar: Panel
var _supply_warning: Panel

## ── 상태 ──
var _selected_unit = null  # Unit (RefCounted)
var _selected_hex: Vector2i = Vector2i(-999, -999)
var _supply_days: float = 30.0
var _ally_troops: int = 0
var _enemy_troops: int = 0
var _ally_morale_avg: float = 70.0
var _card_tween: Tween = null

func _ready() -> void:
	_cache_nodes()
	_connect_turn_manager()
	_setup_initial_values()
	# 유닛 카드는 기본 숨김
	if _unit_card:
		_unit_card.visible = false
		_unit_card.modulate = Color(1, 1, 1, 0)
	_update_top_bar()

func _cache_nodes() -> void:
	_top_bar = get_node_or_null("TopBar") as Panel
	_turn_label = get_node_or_null("TopBar/Margin/HBox/TurnBox/TurnLabel") as Label
	_phase_label = get_node_or_null("TopBar/Margin/HBox/PhaseBox/PhaseLabel") as Label
	_supply_label = get_node_or_null("TopBar/Margin/HBox/SupplyBox/SupplyLabel") as Label
	_supply_icon = get_node_or_null("TopBar/Margin/HBox/SupplyBox/SupplyIcon") as Label
	_supply_warning = get_node_or_null("TopBar/Margin/HBox/SupplyBox") as Panel
	_troop_label = get_node_or_null("TopBar/Margin/HBox/TroopBox/TroopLabel") as Label
	_force_bar = get_node_or_null("TopBar/Margin/HBox/ForceBox/ForceBar") as ProgressBar
	_force_label = get_node_or_null("TopBar/Margin/HBox/ForceBox/ForceLabel") as Label
	_morale_bar = get_node_or_null("TopBar/Margin/HBox/MoraleBox/MoraleBar") as ProgressBar
	_morale_label = get_node_or_null("TopBar/Margin/HBox/MoraleBox/MoraleLabel") as Label

	_unit_card = get_node_or_null("UnitCard") as Panel
	_unit_icon = get_node_or_null("UnitCard/Margin/VBox/Header/UnitIcon") as TextureRect
	_unit_name = get_node_or_null("UnitCard/Margin/VBox/Header/Info/UnitName") as Label
	_unit_count = get_node_or_null("UnitCard/Margin/VBox/Header/Info/UnitCount") as Label
	_unit_morale_bar = get_node_or_null("UnitCard/Margin/VBox/MoraleRow/MoraleBar") as ProgressBar
	_unit_morale_label = get_node_or_null("UnitCard/Margin/VBox/MoraleRow/MoraleValue") as Label
	_unit_morale_state = get_node_or_null("UnitCard/Margin/VBox/MoraleRow/MoraleState") as Label
	_unit_move_label = get_node_or_null("UnitCard/Margin/VBox/StatsGrid/MoveValue") as Label
	_unit_atk_label = get_node_or_null("UnitCard/Margin/VBox/StatsGrid/AtkValue") as Label
	_unit_def_label = get_node_or_null("UnitCard/Margin/VBox/StatsGrid/DefValue") as Label
	_unit_supply_label = get_node_or_null("UnitCard/Margin/VBox/StatsGrid/SupplyValue") as Label
	_unit_pos_label = get_node_or_null("UnitCard/Margin/VBox/PosLabel") as Label
	_btn_confirm = get_node_or_null("UnitCard/Margin/VBox/Actions/BtnConfirm") as Button
	_btn_wait = get_node_or_null("UnitCard/Margin/VBox/Actions/BtnWait") as Button
	_btn_split = get_node_or_null("UnitCard/Margin/VBox/Actions/BtnSplit") as Button
	_btn_merge = get_node_or_null("UnitCard/Margin/VBox/Actions/BtnMerge") as Button
	_btn_retreat = get_node_or_null("UnitCard/Margin/VBox/Actions2/BtnRetreat") as Button

	if _btn_confirm: _btn_confirm.pressed.connect(func(): _emit_action(&"confirm_move"))
	if _btn_wait: _btn_wait.pressed.connect(func(): _emit_action(&"wait"))
	if _btn_split: _btn_split.pressed.connect(func(): _emit_action(&"split"))
	if _btn_merge: _btn_merge.pressed.connect(func(): _emit_action(&"merge"))
	if _btn_retreat: _btn_retreat.pressed.connect(func(): _emit_action(&"retreat"))

	var close_btn: Button = get_node_or_null("UnitCard/Margin/VBox/Header/CloseBtn") as Button
	if close_btn:
		close_btn.pressed.connect(hide_unit_card)

func _connect_turn_manager() -> void:
	# Autoload TurnManager 시그널 연결 — 엔진과 느슨한 결합
	var tm: Node = get_node_or_null("/root/TurnManager")
	if tm == null:
		# 지연 연결 시도 (autoload 아직 준비 안 됐을 수 있음)
		call_deferred("_connect_turn_manager_deferred")
		return
	_connect_tm_signals(tm)

func _connect_turn_manager_deferred() -> void:
	var tm: Node = get_node_or_null("/root/TurnManager")
	if tm:
		_connect_tm_signals(tm)

func _connect_tm_signals(tm: Node) -> void:
	if tm.has_signal("turn_count_changed"):
		if not tm.is_connected("turn_count_changed", _on_turn_count_changed):
			tm.connect("turn_count_changed", _on_turn_count_changed)
	if tm.has_signal("phase_changed"):
		if not tm.is_connected("phase_changed", _on_phase_changed):
			tm.connect("phase_changed", _on_phase_changed)

func _setup_initial_values() -> void:
	var tm: Node = get_node_or_null("/root/TurnManager")
	if tm:
		_on_turn_count_changed(tm.get("current_turn") if tm.get("current_turn") != null else 1)
		var ph: int = tm.get("current_phase") if tm.get("current_phase") != null else 0
		_on_phase_changed(-1, ph, StringName("player"))

## ── TurnManager 시그널 핸들러 ──
func _on_turn_count_changed(turn: int) -> void:
	if _turn_label:
		_turn_label.text = "%d일차" % turn

func _on_phase_changed(old_phase: int, new_phase: int, _faction: StringName) -> void:
	if _phase_label:
		var label: String = "알 수 없음"
		# TurnManager.phase_label 정적 호출 시도
		var tm_script: Script = load("res://scripts/core/turn_manager.gd") as Script
		if tm_script and tm_script.has_method("phase_label"):
			pass # 정적 호출은 TurnManager 인스턴스 필요 — 아래 하드코딩 폴백
		match new_phase:
			0: label = "정찰"
			1: label = "배치"
			2: label = "교전"
			3: label = "종결"
			_: label = "단계 %d" % new_phase
		_phase_label.text = label

## ── 공개 API: 상단 전황 바 업데이트 ──

func update_supply(days: float) -> void:
	_supply_days = days
	if _supply_label:
		_supply_label.text = "보급 %d일" % int(days)
		# 경고 색상
		if days < 0:
			_supply_label.add_theme_color_override("font_color", Color(1, 0.3, 0.3, 1))
		elif days < 3:
			_supply_label.add_theme_color_override("font_color", Color(1, 0.55, 0.2, 1))
		elif days < 7:
			_supply_label.add_theme_color_override("font_color", Color(1, 0.85, 0.3, 1))
		else:
			_supply_label.remove_theme_color_override("font_color")
	if _supply_icon:
		if days < 3:
			_supply_icon.text = "⚠"
			_supply_icon.modulate = Color(1, 0.3, 0.25, 1) if days < 0 else Color(1, 0.6, 0.2, 1)
			# 깜빡임 (보급 위기)
			if days < 0:
				var tw := create_tween().set_loops()
				tw.tween_property(_supply_icon, "modulate:a", 0.3, 0.5)
				tw.tween_property(_supply_icon, "modulate:a", 1.0, 0.5)
		else:
			_supply_icon.text = "◈"
			_supply_icon.modulate = Color(0.7, 0.65, 0.55, 1)

func update_troops(ally: int, enemy: int) -> void:
	_ally_troops = ally
	_enemy_troops = enemy
	if _troop_label:
		_troop_label.text = "아군 %s / 적 %s" % [_format_number(ally), _format_number(enemy)]
	if _force_bar:
		var total: int = ally + enemy
		if total > 0:
			var pct: float = float(ally) / float(total) * 100.0
			_force_bar.value = pct
			# 색상: 우세면 금색, 열세면 붉은기
			if pct > 55:
				_force_bar.modulate = Color(1, 0.95, 0.6, 1)
			elif pct < 45:
				_force_bar.modulate = Color(1, 0.6, 0.5, 1)
			else:
				_force_bar.modulate = Color(1, 1, 1, 1)
		else:
			_force_bar.value = 50
	if _force_label:
		var total2: int = ally + enemy
		if total2 > 0:
			_force_label.text = "군세 %d:%d" % [ally, enemy]
		else:
			_force_label.text = "군세 --"

func update_morale(avg_morale: float) -> void:
	_ally_morale_avg = avg_morale
	if _morale_bar:
		_morale_bar.value = clampf(avg_morale, 0, 100)
		if avg_morale >= 60:
			_morale_bar.modulate = Color(0.4, 0.85, 0.4, 1)
		elif avg_morale >= 40:
			_morale_bar.modulate = Color(0.9, 0.85, 0.3, 1)
		elif avg_morale >= 20:
			_morale_bar.modulate = Color(0.95, 0.55, 0.2, 1)
		else:
			_morale_bar.modulate = Color(0.95, 0.25, 0.25, 1)
	if _morale_label:
		_morale_label.text = "사기 %d" % int(avg_morale)
		var state: String = _morale_state_label(avg_morale)
		_morale_label.tooltip_text = "평균 사기: %s (%.1f)" % [state, avg_morale]

func _update_top_bar() -> void:
	update_supply(_supply_days)
	update_troops(_ally_troops, _enemy_troops)
	update_morale(_ally_morale_avg)

## ── 부대 상태 카드 ──

## 부대 선택 시 카드 표시 — Unit 객체 또는 Dictionary를 받음
func show_unit(unit, hex_q: int = 0, hex_r: int = 0) -> void:
	_selected_unit = unit
	_selected_hex = Vector2i(hex_q, hex_r)
	_populate_unit_card(unit, hex_q, hex_r)
	_animate_card_in()

## 외부에서 Unit + 위치로 갱신 (HexGrid cell_clicked 연동 시)
func show_unit_at(unit, q: int, r: int) -> void:
	show_unit(unit, q, r)

func hide_unit_card() -> void:
	if _unit_card == null or not _unit_card.visible:
		return
	_animate_card_out()
	_selected_unit = null

func is_card_visible() -> bool:
	return _unit_card != null and _unit_card.visible and _unit_card.modulate.a > 0.5

func _populate_unit_card(unit, hex_q: int, hex_r: int) -> void:
	if unit == null:
		return
	# Unit (RefCounted) 또는 Dictionary 모두 지원
	var type_name: String = "알 수 없음"
	var count: int = 0
	var morale: float = 0.0
	var move_pt: int = 0
	var atk: int = 0
	var def: int = 0
	var supply: float = 0.0
	var faction: String = ""
	var icon_tex: Texture2D = null

	if unit is Dictionary:
		type_name = str(unit.get("name_kr", unit.get("name", "부대")))
		count = int(unit.get("soldier_count", unit.get("count", 0)))
		morale = float(unit.get("morale", unit.get("current_morale", 0)))
		move_pt = int(unit.get("move", unit.get("movement", 0)))
		atk = int(unit.get("attack", 0))
		def = int(unit.get("defense", 0))
		supply = float(unit.get("supply_days", unit.get("supply", 0)))
		faction = str(unit.get("faction", ""))
	else:
		# Unit RefCounted — 속성 직접 읽기
		var ut = unit.get("unit_type")
		if ut != null:
			type_name = str(ut.get("name_kr") if ut.get("name_kr") != "" else ut.get("name_en"))
			atk = int(ut.get("attack"))
			def = int(ut.get("defense"))
			# 아이콘 로드 시도: assets/sprites/unit_<id>_<faction>.png
			var uid: String = str(ut.get("id"))
			var fac: String = str(unit.get("faction")) if str(unit.get("faction")) != "" else "blue"
			if fac == "player": fac = "blue"
			if fac == "enemy": fac = "red"
			var icon_path: String = "res://assets/sprites/unit_%s_%s.png" % [uid, fac]
			if ResourceLoader.exists(icon_path):
				icon_tex = load(icon_path) as Texture2D
		count = int(unit.get("soldier_count"))
		morale = float(unit.get("current_morale"))
		supply = float(unit.get("current_supply_days"))
		faction = str(unit.get("faction"))
		if unit.has_method("get_movement_points"):
			move_pt = int(unit.get_movement_points())
		elif unit.has_method("get_movement_points_from_unit"):
			move_pt = 0
		else:
			# 폴백: UnitType base_movement
			var ut2 = unit.get("unit_type")
			if ut2:
				move_pt = int(ut2.get("base_movement"))

	if _unit_name:
		_unit_name.text = type_name
		if faction == "enemy" or faction == "red":
			_unit_name.add_theme_color_override("font_color", Color(0.95, 0.5, 0.45, 1))
		elif faction == "player" or faction == "blue":
			_unit_name.add_theme_color_override("font_color", Color(0.55, 0.75, 0.95, 1))
		else:
			_unit_name.remove_theme_color_override("font_color")
	if _unit_count:
		_unit_count.text = "%s명" % _format_number(count)
	if _unit_icon and icon_tex:
		_unit_icon.texture = icon_tex
		_unit_icon.visible = true
	elif _unit_icon:
		_unit_icon.visible = false
	# 사기
	if _unit_morale_bar:
		_unit_morale_bar.value = clampf(morale, 0, 100)
		if morale >= 60:
			_unit_morale_bar.modulate = Color(0.4, 0.85, 0.4, 1)
		elif morale >= 40:
			_unit_morale_bar.modulate = Color(0.9, 0.85, 0.3, 1)
		elif morale >= 20:
			_unit_morale_bar.modulate = Color(0.95, 0.55, 0.2, 1)
		else:
			_unit_morale_bar.modulate = Color(0.95, 0.25, 0.25, 1)
	if _unit_morale_label:
		_unit_morale_label.text = "%d" % int(morale)
	if _unit_morale_state:
		_unit_morale_state.text = _morale_state_label(morale)
	# 스탯
	if _unit_move_label:
		_unit_move_label.text = "%d" % move_pt
	if _unit_atk_label:
		_unit_atk_label.text = "%d" % atk
	if _unit_def_label:
		_unit_def_label.text = "%d" % def
	if _unit_supply_label:
		_unit_supply_label.text = "%d일" % int(supply) if supply >= 0 else "고갈!"
		if supply < 3:
			_unit_supply_label.add_theme_color_override("font_color", Color(1, 0.4, 0.3, 1))
		else:
			_unit_supply_label.remove_theme_color_override("font_color")
	if _unit_pos_label:
		if hex_q != -999 or hex_r != -999:
			_unit_pos_label.text = "위치 (%d, %d)" % [hex_q, hex_r]
		else:
			_unit_pos_label.text = ""

	# 버튼 활성/비활성: 사기 패주 이하면 일부 행동 불가
	var can_act: bool = morale >= 20.0
	if _btn_confirm: _btn_confirm.disabled = not can_act
	if _btn_wait: _btn_wait.disabled = false  # 대기는 항상 가능
	if _btn_retreat: _btn_retreat.disabled = false
	if _btn_split: _btn_split.disabled = count < 20
	if _btn_merge: _btn_merge.disabled = false

func _animate_card_in() -> void:
	if _unit_card == null:
		return
	if _card_tween and _card_tween.is_valid():
		_card_tween.kill()
	_unit_card.visible = true
	_unit_card.position = Vector2(_unit_card.position.x, 8) # 시작 오프셋
	_unit_card.modulate = Color(1, 1, 1, 0)
	_card_tween = create_tween().set_parallel(true)
	_card_tween.tween_property(_unit_card, "modulate", Color(1, 1, 1, 1), 0.22).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	_card_tween.tween_property(_unit_card, "position:y", 0, 0.22).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

func _animate_card_out() -> void:
	if _unit_card == null:
		return
	if _card_tween and _card_tween.is_valid():
		_card_tween.kill()
	_card_tween = create_tween()
	_card_tween.tween_property(_unit_card, "modulate", Color(1, 1, 1, 0), 0.16)
	_card_tween.tween_property(_unit_card, "position:y", 8, 0.16)
	_card_tween.tween_callback(func():
		if _unit_card:
			_unit_card.visible = false
			unit_card_closed.emit()
	)

func _emit_action(action_id: StringName) -> void:
	action_requested.emit(action_id, _selected_unit)
	# 로그
	print("[BattleHUD] action=%s unit=%s" % [action_id, _selected_unit])

## ── 보조 ──
func _format_number(n: int) -> String:
	if n >= 10000:
		return "%d.%d천" % [n / 1000, (n % 1000) / 100] if n % 1000 >= 100 else "%d천" % (n / 1000)
	return str(n)

func _morale_state_label(morale: float) -> String:
	if morale >= 60: return "정상"
	if morale >= 40: return "동요"
	if morale >= 20: return "패주"
	if morale >= 5: return "붕괴"
	return "항복"

## ── 외부 편의: HexGrid cell_clicked 시그널 직접 연결용 ──
func bind_hex_grid(hex_grid: Node) -> void:
	if hex_grid and hex_grid.has_signal("cell_clicked"):
		if not hex_grid.is_connected("cell_clicked", _on_cell_clicked):
			hex_grid.connect("cell_clicked", _on_cell_clicked)

func _on_cell_clicked(cell, _screen_pos: Vector2) -> void:
	if cell == null:
		hide_unit_card()
		return
	var unit = cell.get("occupying_unit") if "occupying_unit" in cell else null
	if unit != null:
		show_unit(unit, int(cell.get("q")), int(cell.get("r")))
	else:
		# 빈 헥스 클릭 시 카드 숨김 (선택 해제)
		hide_unit_card()

## ── 데모용 더미 데이터 ──
func demo_populate() -> void:
	update_supply(5.0)
	update_troops(3200, 2800)
	update_morale(62.0)
	var dummy_unit: Dictionary = {
		"name_kr": "정예 보병",
		"soldier_count": 420,
		"morale": 68.0,
		"move": 2,
		"attack": 10,
		"defense": 10,
		"supply_days": 12.0,
		"faction": "player",
	}
	show_unit(dummy_unit, 4, 7)
