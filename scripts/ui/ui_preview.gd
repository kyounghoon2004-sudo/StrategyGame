extends Control
## UI 구동 데모 씬 컨트롤러 — 모든 전술 UI를 한 번에 검증
## F1: 인터뷰 / F2: 전과보고(승리) / F3: 칙령 / F4: 보급위기 / F5: 유닛카드
## 좌측 툴바 버튼으로도 조작 가능

var battle_hud: Control
var interview_panel: Control
var mission_panel: Control

@onready var _log_label: RichTextLabel = get_node_or_null("LogPanel/Margin/LogLabel") as RichTextLabel
@onready var _bg: ColorRect = get_node_or_null("Background") as ColorRect

func _ready() -> void:
	# 인스턴스 찾기 (tscn에서 직접 배치된 경우)
	battle_hud = get_node_or_null("BattleHUD") as Control
	interview_panel = get_node_or_null("InterviewPanel") as Control
	mission_panel = get_node_or_null("MissionResultPanel") as Control

	# tscn에 직접 포함 안 됐다면 코드로 인스턴스화 (fallback)
	if battle_hud == null:
		var scn: PackedScene = load("res://scenes/ui/battle_hud.tscn") as PackedScene
		if scn:
			battle_hud = scn.instantiate() as Control
			add_child(battle_hud)
	if interview_panel == null:
		var scn2: PackedScene = load("res://scenes/ui/interview_panel.tscn") as PackedScene
		if scn2:
			interview_panel = scn2.instantiate() as Control
			add_child(interview_panel)
	if mission_panel == null:
		var scn3: PackedScene = load("res://scenes/ui/mission_result_panel.tscn") as PackedScene
		if scn3:
			mission_panel = scn3.instantiate() as Control
			add_child(mission_panel)

	_connect_signals()
	_setup_demo_state()
	_log("[시스템] UI 프리뷰 준비 완료 — 버튼 또는 F1~F5로 UI를 호출하십시오.")

func _connect_signals() -> void:
	if interview_panel and interview_panel.has_signal("option_selected"):
		if not interview_panel.is_connected("option_selected", _on_interview_option):
			interview_panel.connect("option_selected", _on_interview_option)
		if not interview_panel.is_connected("interview_closed", _on_interview_closed):
			interview_panel.connect("interview_closed", _on_interview_closed)
	if mission_panel:
		if mission_panel.has_signal("confirmed") and not mission_panel.is_connected("confirmed", _on_mission_confirmed):
			mission_panel.connect("confirmed", _on_mission_confirmed)
		if mission_panel.has_signal("dismissed") and not mission_panel.is_connected("dismissed", _on_mission_dismissed):
			mission_panel.connect("dismissed", _on_mission_dismissed)
		if mission_panel.has_signal("briefing_confirmed") and not mission_panel.is_connected("briefing_confirmed", _on_briefing_confirmed):
			mission_panel.connect("briefing_confirmed", _on_briefing_confirmed)
	if battle_hud and battle_hud.has_signal("action_requested"):
		if not battle_hud.is_connected("action_requested", _on_hud_action):
			battle_hud.connect("action_requested", _on_hud_action)

func _setup_demo_state() -> void:
	if battle_hud:
		# 상단 바 더미 데이터 (정상 → 보급 위기까지 보여줌)
		battle_hud.update_supply(18.0)
		battle_hud.update_troops(3200, 2800)
		battle_hud.update_morale(68.0)
		# 유닛 카드는 기본 숨김 — F5/버튼으로 토글
		battle_hud.hide_unit_card()
		# 강제 초기 턴 라벨 (TurnManager 없으면 fallback)
		var tm: Node = get_node_or_null("/root/TurnManager")
		if tm == null:
			# 프리뷰 단독 실행 시 TurnManager 대체 표시
			var tl: Label = battle_hud.get_node_or_null("TopBar/Margin/HBox/TurnBox/TurnLabel") as Label
			if tl:
				tl.text = "3일차"
			var pl: Label = battle_hud.get_node_or_null("TopBar/Margin/HBox/PhaseBox/PhaseLabel") as Label
			if pl:
				pl.text = "교전"

## ── 툴바 버튼 핸들러 (tscn에서 연결) ──
func _on_btn_interview_pressed() -> void:
	_show_interview()

func _on_btn_briefing_pressed() -> void:
	if mission_panel:
		mission_panel.show_briefing("칙령", "짐이 명하노니, 하북의 반란을 평정하고 백성을 안정케 하라.", "· 하북 3성을 10일 내 점령\n· 아군 사상 500명 이하\n· 보급 15일 이상 유지")
		_log("[칙령] 왕의 칙령 창을 열었습니다.")

func _on_btn_result_victory_pressed() -> void:
	if mission_panel:
		mission_panel.show_result({
			"is_victory": true,
			"ally_casualties": 87,
			"enemy_casualties": 312,
			"prisoners": 48,
			"loot": "군량 420석 · 병기 60벌",
			"fame_delta": 18,
			"reputation_delta": 12,
			"extra": "[color=#8a8070]포로 중 적 장수 1명이 투항을 청하고 있다.[/color]"
		})
		_log("[전과] 승리 보고서를 열었습니다.")

func _on_btn_result_defeat_pressed() -> void:
	if mission_panel:
		mission_panel.show_result({
			"is_victory": false,
			"ally_casualties": 340,
			"enemy_casualties": 120,
			"prisoners": 8,
			"loot": "없음",
			"fame_delta": -12,
			"reputation_delta": -8,
			"extra": "[color=#8a8070]부대가 동요 상태에 빠졌습니다. 후퇴를 검토하십시오.[/color]"
		})
		_log("[전과] 패배 보고서를 열었습니다.")

func _on_btn_supply_crisis_pressed() -> void:
	if battle_hud:
		# 보급 위기 연출 토글
		var current: float = battle_hud.get("_supply_days") if battle_hud.get("_supply_days") != null else 18.0
		var next: float = 2.0 if current > 5 else 18.0
		battle_hud.update_supply(next)
		if next < 3:
			_log("[보급] 보급 위기! (2일 남음) — 상단 바 경고 표시 확인")
		else:
			_log("[보급] 보급 정상화 (18일)")

func _on_btn_unit_card_pressed() -> void:
	if battle_hud == null:
		return
	if battle_hud.is_card_visible():
		battle_hud.hide_unit_card()
		_log("[HUD] 부대 카드 숨김")
	else:
		var demo_units: Array[Dictionary] = [
			{"name_kr": "정예 보병", "soldier_count": 420, "morale": 68.0, "move": 2, "attack": 10, "defense": 10, "supply_days": 12.0, "faction": "player"},
			{"name_kr": "궁병대", "soldier_count": 180, "morale": 55.0, "move": 2, "attack": 12, "defense": 4, "supply_days": 8.0, "faction": "player"},
			{"name_kr": "중기병", "soldier_count": 260, "morale": 35.0, "move": 3, "attack": 14, "defense": 6, "supply_days": 3.0, "faction": "player"},
			{"name_kr": "공성부대", "soldier_count": 120, "morale": 72.0, "move": 1, "attack": 18, "defense": 2, "supply_days": 20.0, "faction": "player"},
		]
		var pick: Dictionary = demo_units[randi() % demo_units.size()]
		battle_hud.show_unit(pick, randi() % 10, randi() % 10)
		_log("[HUD] 부대 카드 표시: %s (%d명, 사기 %d)" % [pick["name_kr"], pick["soldier_count"], int(pick["morale"])])

func _on_btn_morale_low_pressed() -> void:
	if battle_hud:
		var morale: float = 22.0 if battle_hud.get("_ally_morale_avg") > 30 else 68.0
		battle_hud.update_morale(morale)
		if morale < 30:
			_log("[사기] 사기 저하! (22 — 패주 직전) — 바 색상 적색 확인")
		else:
			_log("[사기] 사기 회복 (68)")

func _on_btn_force_toggle_pressed() -> void:
	if battle_hud:
		var ally: int = int(battle_hud.get("_ally_troops"))
		if ally > 3000:
			battle_hud.update_troops(1800, 4000)
			_log("[군세] 열세 상황 (1800 vs 4000) — 군세 바 적색")
		else:
			battle_hud.update_troops(3800, 1600)
			_log("[군세] 우세 상황 (3800 vs 1600) — 군세 바 금색")

## ── 내부: 인터뷰 표시 ──
func _show_interview() -> void:
	if interview_panel == null:
		return
	var text: String = "주공, 전황을 아뢰옵니다. 적의 보급로가 [color=#d4a843]노출[/color]되어 있사오니, 지금이 결단의 시점이옵니다. 세 가지 방책을 올리오니, 하나를 택하여 주시옵소서.\n\n[color=#8a8070]※ 선택지 클릭 시 헥스 맵에 이동 가이드라인 및 목표 하이라이트가 연계됩니다.[/color]"
	var opts: Array = [
		{"id": &"advance", "text": "전군 전진 — 적 보급로 차단", "tooltip": "북진 3헥스 · 아군 사기 +5 · 보급 -2일"},
		{"id": &"siege", "text": "포위 후 공성 — 성벽을 에워싼다", "tooltip": "공성병 필수 · 보급 -3일 · 명성 +10"},
		{"id": &"retreat", "text": "일단 후퇴 — 전열을 재정비한다", "tooltip": "피해 최소화 · 명성 -10 · 사기 -5"},
	]
	interview_panel.setup_interview("제갈량", "군사 · 병조참의", null, text, opts)
	_log("[인터뷰] 참모 인터뷰 창을 열었습니다. (타이핑 효과 관찰 → 선택지 클릭)")

## ── 시그널 핸들러 ──
func _on_interview_option(option_id: StringName) -> void:
	_log("[인터뷰] 선택: [b]%s[/b] — 헥스 맵 가이드라인 연계 지점 (option_id=%s)" % [option_id, option_id])
	# 데모: 선택 후 0.6초 뒤 인터뷰 닫고 전과로 이어지는 흐름 시연 (advance만)
	if option_id == &"advance":
		await get_tree().create_timer(0.5).timeout
		if interview_panel:
			interview_panel.hide_interview()
		_log("[연계] 헥스 맵에 이동 가이드라인 표시 (연출) — 실제 전투에서는 HexGrid.highlight_hex() 호출")

func _on_interview_closed() -> void:
	_log("[인터뷰] 창 닫힘")

func _on_mission_confirmed() -> void:
	_log("[임무창] 확인 — 다음 페이즈로 진행")

func _on_mission_dismissed() -> void:
	_log("[임무창] 닫힘")

func _on_briefing_confirmed() -> void:
	_log("[칙령] 출정 승인 — 전투 시작")

func _on_hud_action(action_id: StringName, unit) -> void:
	var uname: String = str(unit.get("name_kr", unit.get("name", "부대"))) if unit is Dictionary else str(unit)
	if unit != null and not (unit is Dictionary):
		var ut = unit.get("unit_type")
		if ut:
			uname = str(ut.get("name_kr"))
	_log("[HUD] 행동 요청: [b]%s[/b] (unit=%s)" % [action_id, uname])

func _log(msg: String) -> void:
	if _log_label:
		var time: String = Time.get_time_string_from_system()
		_log_label.append_text("\n[color=#6a6458][%s][/color] %s" % [time, msg])
		# 자동 스크롤
		await get_tree().process_frame
		_log_label.scroll_to_line(_log_label.get_line_count() - 1)
	print("[UIPreview] %s" % msg)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_F1:
				_show_interview()
				get_viewport().set_input_as_handled()
			KEY_F2:
				_on_btn_result_victory_pressed()
				get_viewport().set_input_as_handled()
			KEY_F3:
				_on_btn_briefing_pressed()
				get_viewport().set_input_as_handled()
			KEY_F4:
				_on_btn_supply_crisis_pressed()
				get_viewport().set_input_as_handled()
			KEY_F5:
				_on_btn_unit_card_pressed()
				get_viewport().set_input_as_handled()
