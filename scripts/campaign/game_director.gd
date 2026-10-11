class_name GameDirector
extends Node
## 군주 어명 & 브리핑 시퀀스 + 돌발 이벤트 + 결산/처형 판정 — 오대십국 캠페인 게임 디렉터
## - campaign_manager.gd와 짝을 이뤄 풀 플로우 구동: 브리핑 → 출진 → 전투 → 결산 → 다음 장 → 엔딩
## - MissionResultPanel.show_briefing() / show_result() 연출 담당
## - SLMClient 또는 character_profiles 대사로 대사 출력 (폴백: RuleBasedFallback)
## - events_table.json 트리거 조건(3턴 경과, 보급 5일 이하 등) 체크 — 전령 도착 연출 및 전황 수정

# ─────────────────────────────────────────────
# 상태 머신
# ─────────────────────────────────────────────
enum DirectorState { IDLE, BRIEFING, BATTLE, EVENT_CHOICE, RESULT, CAMP, GAME_OVER, VICTORY }

var state: int = DirectorState.IDLE

# ─────────────────────────────────────────────
# 외부 참조 (에디터에서 할당하거나 자동 탐색)
# ─────────────────────────────────────────────
var campaign_manager: Node
var battle_map: Node
var mission_result_panel: Node
var battle_hud: Node
var slm_client: Node

# 내부
var _current_turn: int = 0
var _is_battle_active: bool = false
var _pending_event: Dictionary = {}
var _battle_timer: Timer = null
var _turn_limit_cache: int = 8
var _initial_ally: int = 0
var _initial_enemy: int = 0
var _auto_simulate: bool = true  ## headless 테스트/시연용 — 실제 플레이에서는 수동 전투 감지 로직으로 교체

# 시그널
signal briefing_started(mission_id: String)
signal battle_started(mission_id: String)
signal event_triggered(event_id: String)
signal mission_finished(result: Dictionary)
signal campaign_ended(ending_id: String)

# ─────────────────────────────────────────────
# 라이프사이클
# ─────────────────────────────────────────────
func _ready() -> void:
	_resolve_references()
	_connect_signals()
	_setup_battle_timer()
	print("[GameDirector] 준비 완료 — state=IDLE")

func _resolve_references() -> void:
	# CampaignManager
	if campaign_manager == null:
		campaign_manager = get_node_or_null("../CampaignManager")
	if campaign_manager == null:
		campaign_manager = get_node_or_null("/root/Main/CampaignManager")
	if campaign_manager == null:
		campaign_manager = get_tree().current_scene.get_node_or_null("CampaignManager") if get_tree().current_scene else null
	# BattleMap
	if battle_map == null:
		battle_map = get_node_or_null("../BattleMap") as Node
	if battle_map == null:
		battle_map = get_node_or_null("/root/Main/BattleMap") as Node
	if battle_map == null:
		battle_map = get_tree().current_scene.get_node_or_null("BattleMap") if get_tree().current_scene else null
	# MissionResultPanel — 여러 경로 탐색
	if mission_result_panel == null:
		mission_result_panel = get_node_or_null("../MissionResultPanel")
	if mission_result_panel == null:
		mission_result_panel = get_node_or_null("../CanvasLayer/MissionResultPanel")
	if mission_result_panel == null:
		mission_result_panel = get_node_or_null("/root/Main/MissionResultPanel")
	if mission_result_panel == null:
		mission_result_panel = get_node_or_null("/root/Main/CanvasLayer/MissionResultPanel")
	if mission_result_panel == null and get_tree().current_scene:
		mission_result_panel = get_tree().current_scene.get_node_or_null("CanvasLayer/MissionResultPanel")
	if mission_result_panel == null and get_tree().current_scene:
		mission_result_panel = get_tree().current_scene.get_node_or_null("MissionResultPanel")
	# BattleHUD
	if battle_hud == null:
		battle_hud = get_node_or_null("../BattleHUD")
	if battle_hud == null:
		battle_hud = get_node_or_null("/root/Main/BattleHUD")
	if battle_hud == null:
		battle_hud = get_node_or_null("/root/Main/CanvasLayer/BattleHUD")
	if battle_hud == null and get_tree().current_scene:
		battle_hud = get_tree().current_scene.get_node_or_null("CanvasLayer/BattleHUD")
	if battle_hud == null and get_tree().current_scene:
		battle_hud = get_tree().current_scene.get_node_or_null("BattleHUD")
	# SLMClient
	if slm_client == null:
		slm_client = get_node_or_null("../SLMClient")
	if slm_client == null:
		slm_client = get_node_or_null("/root/Main/SLMClient")
	if slm_client == null and get_tree().current_scene:
		slm_client = get_tree().current_scene.get_node_or_null("SLMClient")
	# 자동 생성 폴백: SLMClient가 없으면 생성 (RuleBasedFallback만으로 동작)
	if slm_client == null:
		var sc_script: Script = load("res://scripts/ai/slm_client.gd") as Script
		if sc_script != null:
			slm_client = sc_script.new()
			slm_client.name = "SLMClient"
			add_child(slm_client)
			print("[GameDirector] SLMClient 자동 생성 (폴백 모드)")

func _connect_signals() -> void:
	# TurnManager Autoload 연결
	var tm: Node = get_node_or_null("/root/TurnManager")
	if tm != null:
		if tm.has_signal("turn_count_changed") and not tm.is_connected("turn_count_changed", _on_turn_count_changed):
			tm.connect("turn_count_changed", _on_turn_count_changed)
		if tm.has_signal("phase_changed") and not tm.is_connected("phase_changed", _on_phase_changed):
			tm.connect("phase_changed", _on_phase_changed)

func _setup_battle_timer() -> void:
	_battle_timer = Timer.new()
	_battle_timer.name = "BattleSimTimer"
	_battle_timer.wait_time = 1.2
	_battle_timer.one_shot = false
	add_child(_battle_timer)
	_battle_timer.timeout.connect(_on_battle_tick)

func _connect_panel_signals() -> void:
	if mission_result_panel == null:
		return
	if mission_result_panel.has_signal("briefing_confirmed"):
		if not mission_result_panel.is_connected("briefing_confirmed", _on_briefing_confirmed):
			mission_result_panel.connect("briefing_confirmed", _on_briefing_confirmed)
	if mission_result_panel.has_signal("confirmed"):
		if not mission_result_panel.is_connected("confirmed", _on_panel_confirmed):
			mission_result_panel.connect("confirmed", _on_panel_confirmed)
	if mission_result_panel.has_signal("dismissed"):
		if not mission_result_panel.is_connected("dismissed", _on_panel_dismissed):
			mission_result_panel.connect("dismissed", _on_panel_dismissed)

# ─────────────────────────────────────────────
# 캠페인 시작 — 메인 씬에서 호출
# ─────────────────────────────────────────────
func start_campaign() -> void:
	if campaign_manager == null:
		push_error("[GameDirector] campaign_manager가 없음 — 시작 불가")
		return
	_resolve_references()
	_connect_panel_signals()
	if campaign_manager.campaign_data.is_empty():
		var ok: bool = campaign_manager.load_campaign_data()
		if not ok:
			push_error("[GameDirector] 캠페인 데이터 로드 실패")
			return
	campaign_manager.current_mission_index = 1
	campaign_manager.general_renown = 50
	state = DirectorState.IDLE
	print("[GameDirector] 캠페인 시작: %s" % str(campaign_manager.campaign_data.get("title_kr", "campaign_01")))
	_enter_briefing()

# ─────────────────────────────────────────────
# 브리핑 시퀀스
# ─────────────────────────────────────────────
func _enter_briefing() -> void:
	if campaign_manager == null or mission_result_panel == null:
		push_warning("[GameDirector] 브리핑에 필요한 노드 없음 — 브리핑 스킵 후 전투 개시")
		_start_battle()
		return

	var mission: Dictionary = campaign_manager.get_current_mission()
	if mission.is_empty():
		push_error("[GameDirector] 현재 미션 데이터 없음 (index %d)" % campaign_manager.current_mission_index)
		return

	# 4장 공성책 선택 — RECON 페이즈 분기
	if int(mission.get("chapter", campaign_manager.current_mission_index)) == 4 and campaign_manager.selected_siege_approach == "":
		_present_siege_choice(mission)
		return

	state = DirectorState.BRIEFING
	_current_turn = 0
	_is_battle_active = false
	_turn_limit_cache = int(mission.get("turn_limit", 8))

	# 칙령 데이터 조합
	var king: Dictionary = campaign_manager.get_king_profile()
	var advisor: Dictionary = campaign_manager.get_advisor_profile()
	var intro: Dictionary = mission.get("intro_cutscene_kr", {}) as Dictionary

	var king_title: String = str(king.get("full_title_kr", king.get("name_kr", "장종 황제")))
	if king_title == "":
		king_title = "대당 장종 황제"
	var decree_text: String = ""
	if intro.has("king_line"):
		decree_text = str(intro.get("king_line", ""))
	if decree_text == "":
		var quotes: Array = king.get("quotes", [])
		if quotes.size() > 0 and quotes[0] is Dictionary:
			decree_text = str((quotes[0] as Dictionary).get("line_kr", ""))
	if decree_text == "" or decree_text == "<null>":
		decree_text = "장군, %s — 짐이 그대에게 삼군을 맡기노니, 승전보를 기다리겠다." % str(mission.get("title_kr", "임무"))
		if intro.has("king_messenger_line"):
			decree_text = str(intro["king_messenger_line"])
	# 참모 대사
	var advisor_line: String = str(intro.get("advisor_line", ""))
	if advisor_line == "":
		var _adv_quotes: Array = advisor.get("quotes", []) as Array
		if _adv_quotes.size() > 0 and _adv_quotes[0] is Dictionary:
			advisor_line = str((_adv_quotes[0] as Dictionary).get("line_kr", ""))
		else:
			advisor_line = ""

	# 목표 조합
	var objectives: Dictionary = mission.get("objectives", {}) as Dictionary
	var primary: Array = objectives.get("primary", []) as Array
	var secondary: Array = objectives.get("secondary", []) as Array
	var obj_lines: Array = []
	for p in primary:
		if p is Dictionary:
			obj_lines.append("· [주] %s" % str(p.get("description_kr", "")))
	for s in secondary:
		if s is Dictionary:
			obj_lines.append("· [보] %s" % str(s.get("description_kr", "")))
	obj_lines.append("· 턴 제한: %d턴" % _turn_limit_cache)
	var enemy_cmd: String = str(mission.get("forces", {}) is Dictionary and (mission["forces"] as Dictionary).get("enemy_commander_kr", ""))
	if enemy_cmd != "":
		obj_lines.append("· 적장: %s" % enemy_cmd)
	var objective_text: String = "\n".join(obj_lines)

	# 병력 정보 부가 — 명성 비례 하사 규모 표시
	var ally_forces: Array = campaign_manager.generate_initial_forces_for_current_mission()
	var total_ally: int = 0
	var force_hint: String = ""
	var force_parts: Array = []
	for f in ally_forces:
		if f is Dictionary:
			var cnt: int = int(f.get("count", 0))
			total_ally += cnt
			force_parts.append("%s %d" % [str(f.get("unit_type", "")), cnt])
	force_hint = " · ".join(force_parts)
	_initial_ally = total_ally
	_initial_enemy = campaign_manager.initial_enemy_total_for_mission

	# SLM 대사 — 비동기 요청 (타임아웃 시 RuleBasedFallback)
	var slm_dialogue: String = ""
	if slm_client != null:
		slm_dialogue = await _request_slm_or_fallback(mission)
		if slm_dialogue != "":
			advisor_line = slm_dialogue

	var full_objective: String = objective_text
	if advisor_line != "":
		full_objective += "\n\n[color=#8ab4f8]서유선: \"%s\"[/color]" % advisor_line
	if force_hint != "":
		full_objective += "\n\n[color=#8a8070]하사 병력(%d명): %s — 명성 %d (%s) / 신임도 %d (%s)[/color]" % [
			total_ally, force_hint,
			campaign_manager.general_renown, campaign_manager.get_renown_label(),
			campaign_manager.king_trust, campaign_manager.get_trust_label(),
		]

	# BattleMap 미리 초기화 (지형/병력) — 출진 전 미리 준비하되, 실제 교전은 [출진] 후 개시
	if battle_map != null:
		var ok: bool = campaign_manager.prepare_battle_map(battle_map)
		if not ok:
			push_warning("[GameDirector] BattleMap 초기화 실패 — 브리핑은 계속 진행")

	# HUD 갱신
	if battle_hud != null:
		battle_hud.update_supply(campaign_manager.supply_days)
		battle_hud.update_troops(_initial_ally, _initial_enemy)
		battle_hud.update_morale(campaign_manager.army_morale)

	# MissionResultPanel 연출
	_connect_panel_signals()
	var chapter_label: String = "%d장 %s" % [campaign_manager.current_mission_index, str(mission.get("title_kr", ""))]
	mission_result_panel.show_briefing(king_title, decree_text, full_objective)
	# 버튼 텍스트 보정 — 출진 버튼
	if mission_result_panel.get_node_or_null("DimBackground/CenterContainer/MainPanel/Margin/VBox/Buttons/ConfirmBtn") is Button:
		var btn: Button = mission_result_panel.get_node("DimBackground/CenterContainer/MainPanel/Margin/VBox/Buttons/ConfirmBtn") as Button
		btn.text = "출진한다"
	# 왕의 어명 → 궁중 징 SFX + 배너 슬라이드
	var am: Node = get_node_or_null("/root/AudioManager")
	if am != null:
		am.call("play_sfx", "decree_gong")
		am.call("show_banner", "칙 령", "%s · %d장" % [king_title, campaign_manager.current_mission_index], Color(0.85, 0.65, 0.18, 0.95))

	print("[GameDirector] 브리핑 표시 — chapter %d: %s (ally %d, enemy %d, turn_limit %d)" % [
		campaign_manager.current_mission_index, str(mission.get("title_kr", "")), _initial_ally, _initial_enemy, _turn_limit_cache
	])
	briefing_started.emit(str(mission.get("id", "")))

func _request_slm_or_fallback(mission: Dictionary) -> String:
	if slm_client == null:
		return ""
	# 컨텍스트 구성 — SLMClient.request_staff_advice 의 ctx 스키마에 맞춤
	var ctx: Dictionary = {
		"staff_name": str(campaign_manager.staff_profile.get("name_kr", "서유선")),
		"staff_personality": str(campaign_manager.staff_profile.get("personality", "신중")),
		"staff_ability": int(campaign_manager.staff_profile.get("ability", 70)),
		"friendly_total": _initial_ally if _initial_ally > 0 else 600,
		"enemy_estimated_total": _initial_enemy if _initial_enemy > 0 else 400,
		"friendly_morale_avg": campaign_manager.army_morale,
		"supply_days": campaign_manager.supply_days,
		"terrain_summary": str(mission.get("map_config", {}).get("terrain_layout_kr", "평야")),
		"fog_hexes": 6,
		"scout_available": 1,
		"turn": 1,
		"phase": "RECON",
		"available_coords": [[4,7],[6,3],[5,5]],
	}
	# 비동기 요청 — 3초 타임아웃 후 폴백
	var result_holder: Dictionary = {}
	var got_result: bool = false

	# 시그널 일회성 연결
	var on_staff := func(res: Dictionary):
		result_holder = res
		got_result = true

	if slm_client.has_signal("staff_advice_received"):
		slm_client.staff_advice_received.connect(on_staff, CONNECT_ONE_SHOT)
		slm_client.request_staff_advice(ctx)
		# 최대 3.2초 대기 (폴백 포함 — RuleBasedFallback은 즉시 시그널)
		var waited: float = 0.0
		while not got_result and waited < 3.2:
			await get_tree().create_timer(0.1).timeout
			waited += 0.1
		if not got_result:
			# 타임아웃 — RuleBasedFallback 직접 호출
			if slm_client.has_method("get_fallback_staff_advice"):
				result_holder = slm_client.get_fallback_staff_advice(ctx)
			else:
				var Fallback: Script = load("res://scripts/ai/rule_based_fallback.gd") as Script
				if Fallback != null:
					result_holder = Fallback.get_staff_advice(ctx)
			got_result = true
	else:
		# SLMClient 시그널 없음 — 즉시 폴백
		var Fallback2: Script = load("res://scripts/ai/rule_based_fallback.gd") as Script
		if Fallback2 != null:
			result_holder = Fallback2.get_staff_advice(ctx)
			got_result = true

	if got_result and result_holder.has("staff_dialogue"):
		return str(result_holder["staff_dialogue"])
	return ""

func _present_siege_choice(mission: Dictionary) -> void:
	# 4장 특수 — 세 공성책 중 택1. 자동 분기 또는 UI 선택.
	state = DirectorState.BRIEFING
	var approaches: Array = mission.get("siege_approaches", []) as Array
	if approaches.is_empty():
		push_warning("[GameDirector] 4장 siege_approaches 비어있음 — 강공으로 강제")
		campaign_manager.set_siege_approach("assault")
		_enter_briefing()
		return

	# 최적 공성책 자동 추천 (로그라이트 서사 반영)
	var recommended: String = _recommend_siege_approach(approaches)
	# 플레이어가 선택할 여지를 주기 위해 브리핑 패널에 표시 — [출진] 시 선택된 책략으로 진행
	# 여기서는 로그라이트 누적에 따른 자동 추천을 적용하되, 메시지에는 3택1을 명시
	var choice_desc: Array = []
	for a in approaches:
		if a is Dictionary:
			choice_desc.append("· %s (%s) — %s / 턴 %s" % [
				str(a.get("title_kr", "")), str(a.get("id", "")),
				str(a.get("description_kr", "")).left(60),
				str(a.get("turn_limit", "?")),
			])
	var choice_text: String = "\n".join(choice_desc)
	choice_text += "\n\n[color=#d4a843]추천 책략: %s[/color]\n[color=#8a8070]출진 버튼을 누르면 추천 책략으로 진행됩니다. (수동 선택은 다음 패치에서 버튼 분기 예정)[/color]" % recommended

	if mission_result_panel != null:
		_connect_panel_signals()
		var king_title: String = str(campaign_manager.get_king_profile().get("full_title_kr", "장종 황제"))
		var decree: String = "장군, 낙양이 눈앞이다. 짐은 더 이상 기다리지 않으리라. 성을 떨구어 천하에 당의 부흥을 알리라!"
		var advisor_line: String = str(mission.get("intro_cutscene_kr", {}).get("advisor_line", "장군, 세 길을 아뢰오니..."))
		var full_obj: String = choice_text + "\n\n[color=#8ab4f8]서유선: \"%s\"[/color]" % advisor_line
		mission_result_panel.show_briefing("%s — 공성책 선택" % king_title, decree, full_obj)
		# 선택 기억 — 출진 시 확정
		_pending_event = {"type": "siege_choice_pending", "recommended": recommended}
		print("[GameDirector] 4장 공성책 선택 프롬프트 표시 — 추천: %s" % recommended)
	else:
		campaign_manager.set_siege_approach(recommended)
		_enter_briefing()

func _recommend_siege_approach(approaches: Array) -> String:
	# GDD 규칙 기반 추천:
	# - 민심 70+ & 포로 선처 flag → 내통
	# - 보급 충분(10일+) & 신임도 50+ → 포위
	# - 그 외 → 강공
	var has_mercy: bool = false
	for f in campaign_manager.narrative_flags:
		if str(f).contains("ledger_cleared") or str(f).contains("aided_refugees") or str(f).contains("low_casualty"):
			has_mercy = true
			break
	if campaign_manager.civilian_trust >= 65 and (has_mercy or campaign_manager.advisor_branch == "benevolent_guardian"):
		return "infiltration"
	elif campaign_manager.supply_days >= 8.0 and campaign_manager.king_trust >= 45:
		return "siege_encirclement"
	else:
		return "assault"

# ─────────────────────────────────────────────
# [출진] — 브리핑 확인 후 전투 개시
# ─────────────────────────────────────────────
func _on_briefing_confirmed() -> void:
	if state != DirectorState.BRIEFING:
		return
	# 4장 공성책 대기 중이면 선택 확정
	if _pending_event.get("type", "") == "siege_choice_pending":
		var rec: String = str(_pending_event.get("recommended", "assault"))
		campaign_manager.set_siege_approach(rec)
		_pending_event.clear()
		# 실제 브리핑으로 전환
		_enter_briefing()
		return

	# 일반 출진
	_start_battle()

func _on_panel_confirmed() -> void:
	# MissionResultPanel의 confirmed는 briefing과 result 모두에서 발송됨
	# state에 따라 분기 — BATTLE 중 event, RESULT 후 다음 장 전이
	if state == DirectorState.EVENT_CHOICE:
		_resolve_pending_event_choice("a")
	elif state == DirectorState.RESULT:
		_on_result_confirmed()
	elif state == DirectorState.GAME_OVER or state == DirectorState.VICTORY:
		# 엔딩 확인 후 — 게임 종료 또는 재시작
		print("[GameDirector] 엔딩 확인 — 캠페인 종료")
		state = DirectorState.IDLE

func _on_panel_dismissed() -> void:
	if state == DirectorState.EVENT_CHOICE:
		_resolve_pending_event_choice("b")
	elif state == DirectorState.BRIEFING:
		# 브리핑에서 뒤로 — 무시 (다시 브리핑 유지)
		pass

func _start_battle() -> void:
	state = DirectorState.BATTLE
	_is_battle_active = true
	_current_turn = 1
	# TurnManager 리셋 — 새 전투 진입 시 1턴부터
	var tm: Node = get_node_or_null("/root/TurnManager")
	if tm != null and tm.has_method("reset_turn_state"):
		tm.call("reset_turn_state")
		if tm.has_method("start_player_turn"):
			tm.call("start_player_turn")
		_current_turn = int(tm.get("current_turn")) if tm.get("current_turn") != null else 1
	else:
		_current_turn = 1

	if battle_map != null:
		# 이미 prepare_battle_map으로 초기화됨 — 카메라 포커스 등 추가 연출 가능
		var cam: Node = battle_map.get_node_or_null("Camera2D")
		if cam != null and cam.has_method("reset_view"):
			cam.call("reset_view")

	if battle_hud != null:
		battle_hud.update_supply(campaign_manager.supply_days)
		battle_hud.update_troops(_initial_ally, _initial_enemy)
		battle_hud.update_morale(campaign_manager.army_morale)

	print("[GameDirector] 전투 개시 — chapter %d turn_limit %d (battle_map=%s)" % [
		campaign_manager.current_mission_index, _turn_limit_cache, battle_map.name if battle_map else "null"
	])
	battle_started.emit(str(campaign_manager.get_current_mission().get("id", "")))

	# mission_start 트리거 이벤트 1개 추첨 — 브리핑 직후 전령 도착 가능
	_check_and_trigger_events("mission_start")

	# 전투 시뮬레이션 타이머 시작 (자동 진행 — headless/데모용)
	if _auto_simulate:
		_battle_timer.start()

# ─────────────────────────────────────────────
# 전투 중 턴 진행 — TurnManager 시그널 및 타이머 틱
# ─────────────────────────────────────────────
func _on_turn_count_changed(turn: int) -> void:
	if not _is_battle_active:
		return
	_current_turn = turn
	if battle_hud != null:
		# HUD는 TurnManager 시그널로 자동 갱신되나, 보급/사기 별도 갱신
		battle_hud.update_supply(campaign_manager.supply_days)
		battle_hud.update_morale(campaign_manager.army_morale)
	_check_crisis_events()

func _on_phase_changed(_old_phase: int, _new_phase: int, _faction: StringName) -> void:
	if not _is_battle_active:
		return
	# phase 변화 시에도 이벤트 체크 가능 (DEPLOY→ENGAGE 등)
	pass

func _on_battle_tick() -> void:
	if not _is_battle_active or state != DirectorState.BATTLE:
		return
	_current_turn += 1
	if _current_turn > _turn_limit_cache + 2:
		# 턴 제한 초과 — 자동 패배 처리
		_battle_timer.stop()
		_finish_battle(false, {"reason": "turn_limit_exceeded", "turn_used": _current_turn})
		return

	# 보급 감소 시뮬레이션 — 매 턴 보급 0.5일 소모
	if _current_turn % 2 == 0:
		campaign_manager.supply_days = clampf(campaign_manager.supply_days - 0.5, -5.0, 20.0)
		if battle_hud != null:
			battle_hud.update_supply(campaign_manager.supply_days)

	# TurnManager에도 턴 진행 알림 (실제 게임이 아니므로 시그널만 에뮬레이트)
	var tm: Node = get_node_or_null("/root/TurnManager")
	if tm != null and tm.has_method("set") :
		tm.set("current_turn", _current_turn)
		if tm.has_signal("turn_count_changed"):
			tm.emit_signal("turn_count_changed", _current_turn)

	_check_crisis_events()

	# 승리/패배 자동 판정 시뮬레이션 — 5~7턴 이후 확률적 종료
	if _current_turn >= 4 and not _pending_event.has("type"):
		var progress: float = float(_current_turn) / float(maxi(_turn_limit_cache, 6))
		var win_roll: float = randf()
		# 명성과 진행도에 따라 승리 확률 보정 — 4장에서는 더 낮음
		var base_win: float = 0.55 + (float(campaign_manager.general_renown) / 100.0) * 0.20 - progress * 0.15
		if campaign_manager.current_mission_index == 4:
			base_win -= 0.15
		if win_roll < base_win and _current_turn >= 5:
			# 승리 시뮬레이션
			_battle_timer.stop()
			_finish_battle(true, {"turn_used": _current_turn})
			return
		elif _current_turn >= _turn_limit_cache and progress >= 1.0:
			# 턴 제한 도달 — 패배 또는 간신히 승리
			_battle_timer.stop()
			var is_win: bool = win_roll < 0.35
			_finish_battle(is_win, {"turn_used": _current_turn})
			return

func _check_crisis_events() -> void:
	if not _is_battle_active or state != DirectorState.BATTLE:
		return
	# 이벤트 체크 조건:
	# - 3턴 경과 (mid_battle_turn_3)
	# - 보급 5일 이하
	# - 신임도 40 미만에서 조정 음모 가중
	var triggers_to_check: Array = []
	if _current_turn == 3:
		triggers_to_check.append("mid_battle_turn_3")
	# 보급 위기 트리거 — events_table에 직접 명시되진 않으나 스펙상 "보급 5일 이하" 발생 조건으로 간주
	if campaign_manager.supply_days <= 5.0 and _current_turn >= 2:
		# evt_06(야습) 또는 evt_05(역병)가 보급 관련 — mid_battle 트리거로 대체
		if randf() < 0.35:
			triggers_to_check.append("mid_battle_turn_3")
	# on_king_messenger — 2장 2턴 강제 이벤트 또는 신임도 낮을 때
	if campaign_manager.king_trust < 40 and _current_turn >= 2 and randf() < 0.25:
		triggers_to_check.append("on_king_messenger")
	# mission_start는 전투 시작 시 이미 처리 — 여기서는 중복 방지
	for trig in triggers_to_check:
		_check_and_trigger_events(str(trig))
		if state == DirectorState.EVENT_CHOICE:
			break # 이벤트 연출 중에는 추가 트리거 중단

func _check_and_trigger_events(trigger_when: String) -> void:
	if campaign_manager == null:
		return
	# 이미 이벤트 연출 중이면 스킵
	if state == DirectorState.EVENT_CHOICE:
		return
	var drawn: Array = campaign_manager.draw_crisis_events(trigger_when, 1)
	if drawn.is_empty():
		return
	var evt: Dictionary = drawn[0] as Dictionary
	_trigger_event(evt)

func _trigger_event(event: Dictionary) -> void:
	var eid: String = str(event.get("id", "evt_unknown"))
	var title: String = str(event.get("title_kr", eid))
	var flavor: String = str(event.get("flavor_kr", ""))
	var choices: Array = event.get("choices", []) as Array
	print("[GameDirector] 돌발 이벤트 발동: %s (%s) at turn %d" % [eid, title, _current_turn])
	event_triggered.emit(eid)

	# 전령 도착 연출 — MissionResultPanel을 전령 모드로 재활용
	# 타이머 정지 — 이벤트 해결까지 전투 일시 정지
	if _battle_timer != null and _battle_timer.is_stopped() == false:
		_battle_timer.stop()

	state = DirectorState.EVENT_CHOICE
	_pending_event = event

	# 이벤트 설명 + 선택지 텍스트 조합
	var choice_text: String = flavor + "\n\n"
	choice_text += "[color=#d4a843]— 선택 —[/color]\n"
	for c in choices:
		if c is Dictionary:
			var cid: String = str(c.get("id", ""))
			var label: String = str(c.get("label_kr", cid))
			var desc: String = str(c.get("description_kr", ""))
			var advisor_cmt: String = str(c.get("advisor_comment_kr", ""))
			choice_text += "· [%s] %s — %s\n" % [cid.to_upper(), label, desc]
			if advisor_cmt != "":
				choice_text += "  [i][color=#8ab4f8]%s[/color][/i]\n" % advisor_cmt

	var supply_warn: String = ""
	if campaign_manager.supply_days <= 5.0:
		supply_warn = "\n[color=#e07040]⚠ 보급 %d일 — 전령의 보고가 전황을 뒤흔든다.[/color]" % int(campaign_manager.supply_days)
	choice_text += supply_warn

	if mission_result_panel != null:
		mission_result_panel.show_briefing("傳令 — %s" % title, flavor, choice_text)
		# 버튼 텍스트를 선택지로 덮어쓰기 — Confirm = A, Dismiss = B, 세 번째는 자동 순환
		var confirm_btn: Button = mission_result_panel.get_node_or_null("DimBackground/CenterContainer/MainPanel/Margin/VBox/Buttons/ConfirmBtn") as Button
		var dismiss_btn: Button = mission_result_panel.get_node_or_null("DimBackground/CenterContainer/MainPanel/Margin/VBox/Buttons/DismissBtn") as Button
		if confirm_btn:
			confirm_btn.text = "선택 A"
			confirm_btn.visible = true
		if dismiss_btn:
			dismiss_btn.text = "선택 B"
			dismiss_btn.visible = true
	else:
		# 패널 없음 — 자동 선택 A로 진행 (테스트 안정성)
		_resolve_pending_event_choice("a")

	# headless/자동 시연 모드에서는 1초 후 자동 선택
	if _auto_simulate and mission_result_panel != null:
		await get_tree().create_timer(1.4).timeout
		if state == DirectorState.EVENT_CHOICE and _pending_event.get("id", "") == eid:
			_resolve_pending_event_choice("a")

func _resolve_pending_event_choice(choice_id: String) -> void:
	if _pending_event.is_empty():
		return
	var eid: String = str(_pending_event.get("id", ""))
	var chosen_id: String = choice_id.to_lower()
	# 유효 선택지 검증 — 없으면 a로 폴백
	var choices: Array = _pending_event.get("choices", []) as Array
	var valid_ids: Array = []
	for c in choices:
		if c is Dictionary:
			valid_ids.append(str(c.get("id", "")).to_lower())
	if not valid_ids.has(chosen_id):
		chosen_id = str(valid_ids[0]) if valid_ids.size() > 0 else "a"

	var result: Dictionary = campaign_manager.apply_event_choice(eid, chosen_id)
	var advisor_comment: String = str(result.get("advisor_comment", ""))
	print("[GameDirector] 이벤트 해결: %s / 선택 %s → flag=%s comment=%s" % [
		eid, chosen_id, str(result.get("flag", "")), advisor_comment.left(60)
	])

	# 즉각 전황 수정 — 보급 차단 / 회군 어명 등 이벤트별 특수 효과
	_apply_event_battlefield_mutation(eid, chosen_id)

	# HUD 갱신
	if battle_hud != null:
		battle_hud.update_supply(campaign_manager.supply_days)
		battle_hud.update_morale(campaign_manager.army_morale)
		battle_hud.update_troops(_initial_ally, _initial_enemy)

	# 이벤트 패널 닫기
	if mission_result_panel != null and mission_result_panel.visible:
		mission_result_panel.hide_panel()

	_pending_event.clear()
	state = DirectorState.BATTLE

	# 회군 어명 등 특수 이벤트는 즉시 전투 종료로 이어질 수 있음
	if eid in ["evt_04_kings_deadline", "evt_01_embezzlement_slander"] and chosen_id == "a":
		# 강공/해명 선택 시 전투 지속 — 타이머 재개
		pass

	# 전투 재개
	if _is_battle_active and _auto_simulate:
		_battle_timer.start()

func _apply_event_battlefield_mutation(event_id: String, choice_id: String) -> void:
	# 이벤트별 전황 즉각 수정 — 예: 보급 차단, 지형 변화, 회군 어명 등
	match event_id:
		"evt_03_torrential_rain":
			# 폭우 — 평야 30% 습지화, 기병 -1 (choice b/c에 따라 완화)
			if choice_id == "b":
				campaign_manager.army_morale = clampf(campaign_manager.army_morale + 2.0, 0, 100)
			elif choice_id == "c":
				campaign_manager.supply_days -= 1.0
		"evt_04_kings_deadline":
			if choice_id == "a":
				# 어명 받들고 강공 — 왕의 신임 회복되나 사기 하락
				campaign_manager.army_morale = clampf(campaign_manager.army_morale - 4.0, 0, 100)
				_turn_limit_cache = maxi(3, _turn_limit_cache - 1)
			elif choice_id == "c":
				# 상소 — 성공 시 턴 연장, 실패 시 턴 단축 (여기선 50% 확률 시뮬)
				if randf() < 0.50:
					_turn_limit_cache += 2
				else:
					_turn_limit_cache = maxi(3, _turn_limit_cache - 1)
		"evt_06_supply_fire":
			if choice_id == "a":
				campaign_manager.supply_days = maxf(campaign_manager.supply_days - 1.0, -5.0)
			elif choice_id == "c":
				campaign_manager.civilian_trust = maxi(campaign_manager.civilian_trust - 8, 0)
		"evt_10_civilian_refugees":
			# 난민 도움 시 민심 상승 — 이미 campaign_manager에서 처리
			pass
		"evt_02_feigned_defection":
			if choice_id == "a":
				# 50% 위장 판정 — 실패 시 사상자
				var true_defection: bool = randf() < 0.55
				if not true_defection:
					campaign_manager.army_morale = clampf(campaign_manager.army_morale - 6.0, 0, 100)
				else:
					_initial_enemy = int(float(_initial_enemy) * 0.85)
		_:
			pass # 기타 이벤트는 campaign_manager.apply_event_choice로 수치만 반영

# ─────────────────────────────────────────────
# 결산 — 전투 종료 호출 (외부 전투 시스템 또는 시뮬레이션에서 호출)
# ─────────────────────────────────────────────
func _finish_battle(is_victory: bool, extra: Dictionary = {}) -> void:
	if not _is_battle_active:
		return
	_is_battle_active = false
	if _battle_timer != null:
		_battle_timer.stop()

	# 시뮬레이션 사상자 생성
	var sim: Dictionary = _simulate_battle_result(is_victory, extra)
	var ally_cas: int = int(sim.get("ally_casualties", 80))
	var enemy_cas: int = int(sim.get("enemy_casualties", 150))
	var turn_used: int = int(extra.get("turn_used", _current_turn))

	# 캠페인 매니저 결산
	var battle_result: Dictionary = {
		"is_victory": is_victory,
		"ally_casualties": ally_cas,
		"enemy_casualties": enemy_cas,
		"ally_initial": _initial_ally,
		"enemy_initial": _initial_enemy,
		"turn_used": turn_used,
		"turn_limit": _turn_limit_cache,
	}
	# 이벤트 보너스 병합
	for k in extra.keys():
		if k not in battle_result:
			battle_result[k] = extra[k]

	var settlement: Dictionary = campaign_manager.settle_mission(battle_result)
	mission_finished.emit(settlement)
	_show_result_panel(settlement, battle_result)
	# 종결 — 징/팡파르 사운드 (배틀맵의 _enter_resolve_phase 와 중복될 수 있으나,
	# 자동 시뮬레이션 경로(턴 제한 초과)에서는 여기만 호출됨 — 멱등 처리됨)
	var am: Node = get_node_or_null("/root/AudioManager")
	if am != null:
		if is_victory:
			am.call("play_sfx", "decree_gong")
		else:
			am.call("play_sfx", "morale_break")

func _simulate_battle_result(is_victory: bool, extra: Dictionary) -> Dictionary:
	# 명성과 전황에 따른 그럴듯한 사상자 시뮬레이션
	var ally_base: int = _initial_ally if _initial_ally > 0 else 600
	var enemy_base: int = _initial_enemy if _initial_enemy > 0 else 500
	var ally_cas: int
	var enemy_cas: int
	if is_victory:
		# 승리 — 사상률 8~32% (명성 높을수록 저손실)
		var loss_rate: float = 0.08 + randf() * 0.18 - (float(campaign_manager.general_renown) / 100.0) * 0.08
		# 4장에서는 사상률 추가 +8%
		if campaign_manager.current_mission_index == 4:
			loss_rate += 0.07
		loss_rate = clampf(loss_rate, 0.05, 0.45)
		ally_cas = int(float(ally_base) * loss_rate)
		enemy_cas = int(float(enemy_base) * (0.35 + randf() * 0.25))
	else:
		# 패배 — 사상률 25~55%
		var loss_rate2: float = 0.25 + randf() * 0.30
		ally_cas = int(float(ally_base) * loss_rate2)
		enemy_cas = int(float(enemy_base) * (0.10 + randf() * 0.20))
	ally_cas = clampi(ally_cas, 0, ally_base - 10)
	enemy_cas = clampi(enemy_cas, 0, enemy_base)
	return {"ally_casualties": ally_cas, "enemy_casualties": enemy_cas}

func _show_result_panel(settlement: Dictionary, battle_result: Dictionary) -> void:
	state = DirectorState.RESULT
	var is_victory: bool = bool(settlement.get("is_victory", false))
	var ally_cas: int = int(settlement.get("ally_casualties", 0))
	var enemy_cas: int = int(settlement.get("enemy_casualties", 0))
	var renown_delta: int = int(settlement.get("renown_delta", 0))
	var trust_delta: int = int(settlement.get("king_trust_delta", 0))
	var casualty_rate: float = float(settlement.get("casualty_rate", 0.0))
	var reason: String = str(settlement.get("reason", ""))

	var prisoners: int = int(enemy_cas * 0.12) if is_victory else 0
	var loot: String = "군량 %d석 · 병기 %d벌" % [120 + randi() % 180, 30 + randi() % 40] if is_victory else "없음"
	var extra: String = ""
	if is_victory:
		if casualty_rate <= 0.15:
			extra = "[color=#8ab4f8]서유선: \"장군께서 병사를 아끼시니 병사들도 장군을 따르옵니다.\"[/color]\n[color=#d4a843]사상률 %.1f%% — 정예 보존, 명성 대폭 상승![/color]" % (casualty_rate*100.0)
		elif casualty_rate <= 0.25:
			extra = "[color=#8ab4f8]서유선: \"좋은 승리이옵니다, 장군.\"[/color]\n[color=#8a8070]사상률 %.1f%% — 무난한 승리.[/color]" % (casualty_rate*100.0)
		elif casualty_rate <= 0.40:
			extra = "[color=#e0a030]서유선: \"피로 쌓은 승리는 다음 전투를 갉아먹사옵니다, 장군.\"[/color]\n[color=#e07040]사상률 %.1f%% — 병력을 갈아넣은 승리, 명성 소폭 상승.[/color]" % (casualty_rate*100.0)
		else:
			extra = "[color=#e05030]서유선: \"장군, 이 승리로 무엇을 얻었사옵니까...\"[/color]\n[color=#c04030]사상률 %.1f%% — 피로스 승리, 명성 정체.[/color]" % (casualty_rate*100.0)
		extra += "\n[color=#8a8070]%s[/color]" % reason
	else:
		var next_action: String = str(settlement.get("next_action", ""))
		if next_action == "execution":
			extra = "[color=#e05030]왕의 사자가 도착했다. \"군법을 어겼으니 참형에 처한다.\"[/color]\n[color=#c04030]%s[/color]" % reason
		elif next_action == "retry":
			extra = "[color=#e0a030]왕의 전령: \"이번은 경고를 주노라. 다음엔 용서치 않으리라.\"[/color]\n[color=#8a8070]%s[/color]" % reason
		else:
			extra = "[color=#8a8070]%s[/color]" % reason

	extra += "\n[color=#6a6a6a]신임도 %+d (%d→%d) · 보급 %.1f일 · 사기 %.1f[/color]" % [
		trust_delta, int(settlement.get("old_king_trust", 0)), int(settlement.get("new_king_trust", 0)),
		campaign_manager.supply_days, campaign_manager.army_morale
	]

	if mission_result_panel != null:
		_connect_panel_signals()
		var panel_data: Dictionary = {
			"is_victory": is_victory,
			"ally_casualties": ally_cas,
			"enemy_casualties": enemy_cas,
			"prisoners": prisoners,
			"loot": loot,
			"fame_delta": renown_delta,
			"reputation_delta": trust_delta,
			"extra": extra,
		}
		mission_result_panel.show_result(panel_data)
		# 버튼 텍스트 보정
		var btn: Button = mission_result_panel.get_node_or_null("DimBackground/CenterContainer/MainPanel/Margin/VBox/Buttons/ConfirmBtn") as Button
		if btn:
			var next_action2: String = str(settlement.get("next_action", ""))
			match next_action2:
				"next_mission": btn.text = "다음 장으로"
				"retry": btn.text = "재도전한다"
				"execution": btn.text = "…"
				"campaign_complete": btn.text = "엔딩으로"
				_: btn.text = "확인"
		print("[GameDirector] 결산 표시 — %s ally_cas=%d enemy_cas=%d renown %+d trust %+d → %s" % [
			"승리" if is_victory else "패배", ally_cas, enemy_cas, renown_delta, trust_delta, str(settlement.get("next_action", ""))
		])
	else:
		# 패널 없음 — 자동 진행
		_on_result_confirmed()

	# headless 자동 진행 — 1.2초 후 자동 확인
	if _auto_simulate and mission_result_panel != null:
		await get_tree().create_timer(1.5).timeout
		if state == DirectorState.RESULT:
			_on_result_confirmed()

func _on_result_confirmed() -> void:
	if state != DirectorState.RESULT:
		return
	# 마지막 결산 상태를 기준으로 다음 행동 결정 — campaign_manager의 마지막 settlement를 참조
	# settlement 정보가 없으면 현재 상태로 추론 — 여기서는 campaign_manager의 실패 카운트 등으로 대체
	if campaign_manager.is_game_over:
		_show_game_over()
		return
	if campaign_manager.current_mission_index >= campaign_manager.get_mission_count():
		# 4장까지 완료 — 결산이 승리였다면 엔딩, 패배였다면 재시도/처형
		var last_should_be_victory: bool = not campaign_manager.is_game_over
		# 실제 settlement의 is_victory를 재확인 — last settlement가 execution이면 game_over가 이미 true
		_show_ending_or_next()
		return

	# settlement의 next_action을 확인 — 실패 후 retry면 재시도, next_mission이면 다음 장
	# 간단 판정: consecutive_failures가 증가했고 아직 game_over가 아니면 retry
	if campaign_manager.consecutive_failures > 0 and not campaign_manager.is_game_over:
		# retry 또는 다음 장 — campaign_manager의 advance 상태로 구분
		# 여기서는 승리 실패 여부에 따라 분기: 마지막 결산이 승리면 advance, 패배면 retry
		# victory 여부는 Panel의 subtitle 등으로 유추 불가하므로 별도 캐시 필요 — _last_settlement 저장
		if _last_settlement_is_victory():
			_advance_to_next_chapter()
		else:
			_retry_current_mission()
	else:
		_advance_to_next_chapter()

var _last_was_victory: bool = true
func _last_settlement_is_victory() -> bool:
	return _last_was_victory

func _finish_battle_track_victory(is_victory: bool) -> void:
	_last_was_victory = is_victory

# _finish_battle에서 호출되는 래퍼 — _last_was_victory 갱신
func _finish_battle_with_track(is_victory: bool, extra: Dictionary = {}) -> void:
	_last_was_victory = is_victory
	_finish_battle(is_victory, extra)

func _advance_to_next_chapter() -> void:
	if campaign_manager.current_mission_index >= campaign_manager.get_mission_count():
		_show_ending_or_next()
		return
	var ok: bool = campaign_manager.advance_to_next_mission()
	if not ok:
		_show_ending_or_next()
		return
	# 야전막사 — campaign_overview.md의 camp_choices (휴식/훈련/정찰) — 자동 선택: 사기 낮으면 휴식, 그 외 정찰
	state = DirectorState.CAMP
	var camp_choice: String = "scout"
	if campaign_manager.army_morale < 50.0:
		camp_choice = "rest"
		campaign_manager.army_morale = clampf(campaign_manager.army_morale + 6.0, 0, 92)
		campaign_manager.supply_days = clampf(campaign_manager.supply_days - 1.0, -5, 20)
	elif campaign_manager.gold_taels >= 100:
		camp_choice = "drill"
		campaign_manager.army_morale = clampf(campaign_manager.army_morale + 3.0, 0, 92)
	else:
		camp_choice = "scout"
	campaign_manager._add_narrative_flag("camp_" + camp_choice + "_%02d" % (campaign_manager.current_mission_index - 1))
	print("[GameDirector] 야전막사: %s 선택 — morale=%.1f supply=%.1f" % [camp_choice, campaign_manager.army_morale, campaign_manager.supply_days])
	# 패널 닫힌 후 1초 뒤 다음 브리핑
	await get_tree().create_timer(0.6).timeout
	if mission_result_panel != null and mission_result_panel.visible:
		mission_result_panel.hide_panel()
	await get_tree().create_timer(0.4).timeout
	_enter_briefing()

func _retry_current_mission() -> void:
	campaign_manager.retry_current_mission()
	state = DirectorState.BRIEFING
	await get_tree().create_timer(0.6).timeout
	if mission_result_panel != null and mission_result_panel.visible:
		mission_result_panel.hide_panel()
	await get_tree().create_timer(0.4).timeout
	_enter_briefing()

func _show_game_over() -> void:
	state = DirectorState.GAME_OVER
	if mission_result_panel != null:
		mission_result_panel.hide_panel()
		await get_tree().create_timer(0.3).timeout
		var decree: String = "짐이 그대를 믿었거늘... 중원의 문을 열어젓고 적에게 바쳤구나. 군법은 사정을 두지 않는다. 끌고 가라!"
		var obj: String = "[color=#c04030]처형 — 의심의 대가[/color]\n장군의 목은 낙양성 밖에 효수되었다.\n\n[color=#8a8070]명성 %d / 신임도 %d / 연속 실패 %d회[/color]\n[color=#8a8070]캠페인 실패 — 그러나 로그라이트이니 재도전할 수 있다.[/color]" % [
			campaign_manager.general_renown, campaign_manager.king_trust, campaign_manager.consecutive_failures
		]
		mission_result_panel.show_briefing("참형", decree, obj)
		var btn: Button = mission_result_panel.get_node_or_null("DimBackground/CenterContainer/MainPanel/Margin/VBox/Buttons/ConfirmBtn") as Button
		if btn:
			btn.text = "재도전"
		print("[GameDirector] 게임 오버 — 처형 (renown %d, trust %d)" % [campaign_manager.general_renown, campaign_manager.king_trust])
	else:
		print("[GameDirector] 게임 오버 — 처형")

func _show_ending_or_next() -> void:
	# 4장 승리 시 엔딩, 그 외는 캠페인 완료 또는 재시도
	if campaign_manager.is_game_over:
		_show_game_over()
		return
	# 엔딩 결정 — campaign_manager의 _determine_ending 로직 재사용
	var mission: Dictionary = campaign_manager.get_current_mission()
	var endings: Array = mission.get("endings", []) as Array
	if campaign_manager.campaign_data.has("missions"):
		var all_m: Array = campaign_manager.campaign_data["missions"] as Array
		if all_m.size() >= 4:
			var m04: Dictionary = all_m[3] as Dictionary
			endings = m04.get("endings", []) as Array

	var casualty_rate: float = 0.0 # 근사 — 마지막 결산의 casualty_rate를 알 수 없으므로 renown으로 역추정
	var ending_id: String = "ending_triumph"
	if campaign_manager.general_renown >= 60 and campaign_manager.king_trust >= 60:
		ending_id = "ending_triumph"
	elif campaign_manager.civilian_trust >= 65 and campaign_manager.selected_siege_approach == "infiltration":
		ending_id = "ending_bloodless"
	elif campaign_manager.general_renown < 40 or campaign_manager.king_trust < 40:
		ending_id = "ending_bittersweet"
	else:
		ending_id = "ending_triumph"

	var ending_dict: Dictionary = {}
	for e in endings:
		if e is Dictionary and str(e.get("id", "")) == ending_id:
			ending_dict = e as Dictionary
			break
	if ending_dict.is_empty() and endings.size() > 0:
		ending_dict = endings[0] as Dictionary
		ending_id = str(ending_dict.get("id", "ending_triumph"))

	state = DirectorState.VICTORY
	if mission_result_panel != null:
		mission_result_panel.hide_panel()
		await get_tree().create_timer(0.4).timeout
		var title: String = str(ending_dict.get("title_kr", "개선"))
		var desc: String = str(ending_dict.get("description_kr", "낙양의 깃발이 바뀌었다."))
		var cond: String = str(ending_dict.get("condition_kr", ""))
		var rewards: String = str(ending_dict.get("rewards_kr", ""))
		var extra2: String = "[color=#d4a843]%s[/color]\n\n[color=#8a8070]조건: %s[/color]\n[color=#8ab4f8]보상: %s[/color]\n\n[color=#8a8070]명성 %d (%s) · 신임도 %d (%s) · 민심 %d · 보급 %.1f일[/color]" % [
			desc, cond, rewards,
			campaign_manager.general_renown, campaign_manager.get_renown_label(),
			campaign_manager.king_trust, campaign_manager.get_trust_label(),
			campaign_manager.civilian_trust, campaign_manager.supply_days
		]
		var king_line: String = str(ending_dict.get("king_line_kr", "장하다! 낙양의 종이 다시 울리는구나!"))
		mission_result_panel.show_briefing(title, king_line, extra2)
		var btn2: Button = mission_result_panel.get_node_or_null("DimBackground/CenterContainer/MainPanel/Margin/VBox/Buttons/ConfirmBtn") as Button
		if btn2:
			btn2.text = "캠페인 완료"
		print("[GameDirector] 엔딩 도달 — %s: %s" % [ending_id, title])
		campaign_ended.emit(ending_id)
	else:
		print("[GameDirector] 엔딩 — %s" % ending_id)
		campaign_ended.emit(ending_id)

# ─────────────────────────────────────────────
# 외부에서 전투 종료를 강제 호출 (실제 BattleMap 전투 시스템에서 연동)
# ─────────────────────────────────────────────
func report_battle_result(is_victory: bool, data: Dictionary = {}) -> void:
	_last_was_victory = is_victory
	_finish_battle(is_victory, data)

# 편의 — 외부에서 현재 진행 상태를 문자열로
func get_status_text() -> String:
	return "chapter %d/4 · renown %d(%s) · trust %d(%s) · supply %.1f · morale %.0f · state %d" % [
		campaign_manager.current_mission_index if campaign_manager else 0,
		campaign_manager.general_renown if campaign_manager else 0,
		campaign_manager.get_renown_label() if campaign_manager else "-",
		campaign_manager.king_trust if campaign_manager else 0,
		campaign_manager.get_trust_label() if campaign_manager else "-",
		campaign_manager.supply_days if campaign_manager else 0.0,
		campaign_manager.army_morale if campaign_manager else 0.0,
		state,
	]



# ─────────────────────────────────────────────
# 외부 테스트/스모크용 공개 API (스모크 테스트/디버그 콘솔에서 호출)
# ─────────────────────────────────────────────
## 처형/재기회 판정 (settle_mission의 실패 분기와 동일)
func evaluate_execution_judgement() -> Dictionary:
	if campaign_manager == null:
		return {"verdict": "unknown", "reason": "campaign_manager null"}
	var cm = campaign_manager
	var fails: int = int(cm.consecutive_failures)
	var renown: int = int(cm.general_renown)
	var trust: int = int(cm.king_trust)
	var verdict: String = "retry_warning"
	var reason: String = ""
	if fails >= 2 or renown < 20 or trust < 15:
		verdict = "execution"
		reason = "2회 연속 실패 또는 명성/신임 한계 미만 (fails=%d renown=%d trust=%d)" % [fails, renown, trust]
	elif renown >= 55 and trust >= 40:
		verdict = "retry_warning"
		reason = "명성(%d)·신임(%d) 우량 — 1회 재기회 (경고)" % [renown, trust]
	elif renown >= 30 or trust >= 30:
		verdict = "retry_demotion"
		reason = "명성(%d)·신임(%d) 보통 — 1회 재기회 (강등)" % [renown, trust]
	else:
		verdict = "execution"
		reason = "명성(%d)·신임(%d) 모두 낮음 — 처형" % [renown, trust]
	return {"verdict": verdict, "reason": reason, "fails": fails, "renown": renown, "trust": trust}

## 시뮬레이션: 임무 결산 — 명성/신임 변동 (settle_mission을 헤드리스로 호출)
## is_victory: bool, casualty_rate: float (0~1), turn_used: int
func settle_mission_aftermath(is_victory: bool, casualty_rate: float, turn_used: int) -> Dictionary:
	if campaign_manager == null:
		return {}
	var cm = campaign_manager
	var mission: Dictionary = cm.get_current_mission()
	var ally_initial: int = int(cm.initial_ally_total_for_mission) if int(cm.initial_ally_total_for_mission) > 0 else 600
	var ally_cas: int = int(round(float(ally_initial) * float(casualty_rate)))
	var enemy_cas: int = int(round(float(cm.initial_enemy_total_for_mission) * 0.6)) if is_victory else int(round(float(cm.initial_enemy_total_for_mission) * 0.3))
	var result: Dictionary = cm.settle_mission({
		"is_victory": is_victory,
		"ally_casualties": ally_cas,
		"enemy_casualties": enemy_cas,
		"turn_used": int(turn_used),
		"turn_limit": int(mission.get("turn_limit", 8)),
	})
	return result

## 외부에서 공성책 추천 호출 (private _recommend_siege_approach 위임)
func recommend_siege_approach(approaches: Array) -> String:
	return _recommend_siege_approach(approaches)

## 엔딩 분기 (settle_mission 내부의 _determine_ending과 동일 로직, 외부 인자 기반)
func determine_ending(approach: String, casualty_rate: float, is_victory: bool) -> String:
	if campaign_manager == null:
		return "ending_triumph"
	var cm = campaign_manager
	var has_infiltration: bool = (approach == "infiltration") or (str(approach) == "infiltration")
	var ct: int = int(cm.civilian_trust)
	var trust: int = int(cm.king_trust)
	var renown: int = int(cm.general_renown)
	if not is_victory:
		if trust >= 25 and renown >= 25:
			return "ending_retreat_rebuild"
		else:
			return "ending_execution"
	# 승리 분기
	if has_infiltration and ct >= 65:
		return "ending_bloodless"
	if trust >= 60 and casualty_rate <= 0.30:
		return "ending_triumph"
	if casualty_rate >= 0.40 or trust < 40:
		return "ending_bittersweet"
	return "ending_triumph"
