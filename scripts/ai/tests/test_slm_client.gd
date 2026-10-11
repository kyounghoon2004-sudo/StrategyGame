extends SceneTree
## SLM 시스템 통합 테스트 (Headless 실행용)
## 실행: godot --headless --path "D:/Game development/Demon slayer/StrategyGame" -s res://scripts/ai/tests/test_slm_client.gd
##
## - RuleBasedFallback 4종 + SLMParser + AISchemas를 동기 호출로 검증
## - HTTP 없이 오프라인 폴백만으로 전체 JSON 스키마 준수 여부 확인
## - 실패 시 exit 1, 성공 시 exit 0

const Fallback := preload("res://scripts/ai/rule_based_fallback.gd")
const Parser := preload("res://scripts/ai/slm_parser.gd")
const Schemas := preload("res://scripts/ai/ai_schemas.gd")

var _passed: int = 0
var _failed: int = 0

func _init() -> void:
	print("========================================")
	print(" SLM Intelligence & Narrative AI — TEST ")
	print("========================================")

	test_staff_fallback()
	test_king_fallback()
	test_enemy_fallback()
	test_prisoner_fallback()
	test_parser()
	test_schemas()
	test_edge_cases()

	print("")
	print("----------------------------------------")
	print(" 결과: %d passed / %d failed" % [_passed, _failed])
	print("----------------------------------------")
	if _failed > 0:
		print("TEST FAILED")
		quit(1)
	else:
		print("ALL TESTS PASSED")
		quit(0)


func _assert(cond: bool, msg: String) -> void:
	if cond:
		_passed += 1
		print("  ✓ %s" % msg)
	else:
		_failed += 1
		print("  ✗ FAIL: %s" % msg)

# ─────────────────────────────────────────────
func test_staff_fallback() -> void:
	print("\n[1] Staff Fallback")
	var cases: Array = [
		{
			"staff_name": "왕박", "staff_personality": "신중파", "staff_ability": 78,
			"friendly_total": 4200, "enemy_estimated_total": 5000, "friendly_morale_avg": 62.0,
			"supply_days": 12.0, "terrain_summary": "평야 42%, 숲 30%", "fog_hexes": 9, "scout_available": 1,
			"available_coords": [[4,7],[6,3],[5,5]]
		},
		{
			"staff_personality": "맹진파", "staff_ability": 72,
			"friendly_total": 6000, "enemy_estimated_total": 3500, "friendly_morale_avg": 78.0,
			"supply_days": 18.0, "terrain_summary": "평야 60%", "fog_hexes": 2, "scout_available": 2,
			"available_coords": [[6,3],[5,6],[8,5]]
		},
		{
			"staff_personality": "계략파", "staff_ability": 65,
			"friendly_total": 3800, "enemy_estimated_total": 4500, "supply_days": 3.0,
			"terrain_summary": "평야 50%", "fog_hexes": 4, "scout_available": 2,
			"available_coords": [[3,4],[7,6],[5,5]]
		},
		{
			"staff_personality": "신중파", "staff_ability": 28,
			"friendly_total": 3000, "enemy_estimated_total": 4000, "fog_hexes": 14, "scout_available": 0,
			"available_coords": [[4,7],[6,3],[5,5]]
		},
		{},  # 빈 context — 크래시 없어야 함
	]
	for i in range(cases.size()):
		var ctx: Dictionary = cases[i] as Dictionary
		var result: Dictionary = Fallback.get_staff_advice(ctx)
		_assert(result.has("staff_dialogue") and str(result["staff_dialogue"]).length() >= 20, "staff[%d] dialogue 존재" % i)
		_assert(result.get("confidence_level", "") in ["high", "medium", "low"], "staff[%d] confidence enum" % i)
		_assert(result.has("tactical_options") and (result["tactical_options"] as Array).size() == 3, "staff[%d] options==3" % i)
		_assert(result.get("is_fallback", false) == true, "staff[%d] is_fallback=true" % i)
		# tactical option 내부 검증
		for opt in (result["tactical_options"] as Array):
			_assert(opt is Dictionary and opt.has("id") and opt.has("action_type"), "staff[%d] option 필드" % i)
	# 저능력 참모는 confidence low
	var low_ctx: Dictionary = {"staff_personality": "신중파", "staff_ability": 28, "fog_hexes": 14, "scout_available": 0, "available_coords": [[4,7],[6,3],[5,5]]}
	var low_res: Dictionary = Fallback.get_staff_advice(low_ctx)
	_assert(low_res["confidence_level"] == "low", "staff 저능력 confidence==low")
	# 신중파 저능력은 불확실성 문구 포함
	_assert("확실치" in str(low_res["staff_dialogue"]) or "짐작" in str(low_res["staff_dialogue"]), "staff 저능력 불확실성 문구")


func test_king_fallback() -> void:
	print("\n[2] King Fallback")
	var cases: Array = [
		{"king_personality": "현명파", "king_trust": 65, "request_mode": "mission", "turn": 1, "recent_battle_summary": "교전 없음"},
		{"king_personality": "현명파", "king_trust": 70, "request_mode": "evaluation", "recent_battle_summary": "성 함락 성공, 적 600 섬멸", "morale_avg": 75.0},
		{"king_personality": "변덕파", "king_trust": 35, "request_mode": "sudden_order", "turn": 6, "trigger_for_sudden_order": "적 별동대 수도 접근설"},
		{"king_personality": "의심파", "king_trust": 25, "request_mode": "mixed", "recent_battle_summary": "실패, 손실 큼", "morale_avg": 40.0},
		{},  # 빈 context
	]
	for i in range(cases.size()):
		var ctx: Dictionary = cases[i] as Dictionary
		var result: Dictionary = Fallback.get_king_order(ctx)
		_assert(result.has("king_dialogue") and str(result["king_dialogue"]).length() >= 10, "king[%d] dialogue" % i)
		_assert(result.get("mood", "") in ["pleased", "neutral", "angered", "furious"], "king[%d] mood enum" % i)
		_assert(result.get("is_fallback", false) == true, "king[%d] is_fallback" % i)
	# mission 모드는 mission 필드 필수
	var mission_res: Dictionary = Fallback.get_king_order({"request_mode": "mission", "king_personality": "현명파", "turn": 1})
	_assert(mission_res.has("mission"), "king mission 모드 mission 필드 존재")
	_assert(int(mission_res["mission"]["turn_limit"]) >= 1, "king mission turn_limit 유효")


func test_enemy_fallback() -> void:
	print("\n[3] Enemy Fallback")
	var cases: Array = [
		{"enemy_personality": "지장형", "enemy_total": 4000, "enemy_morale": 68.0, "enemy_supply_days": 12.0, "encircled": false, "terrain_summary": "숲 30%", "friendly_est_total": 3800, "available_coords": [[5,8],[6,6],[3,2]]},
		{"enemy_personality": "냉정형", "enemy_total": 2800, "enemy_morale": 25.0, "enemy_supply_days": 2.0, "encircled": true, "enemy_staff_alive": false, "available_coords": [[3,2],[3,3],[4,4]], "friendly_est_total": 5000},
		{"enemy_personality": "수성형", "enemy_total": 3200, "enemy_morale": 60.0, "enemy_supply_days": 20.0, "encircled": false, "terrain_summary": "성벽 20%", "available_coords": [[9,6],[9,7],[8,6]], "friendly_est_total": 4000},
		{"enemy_morale": 15.0, "enemy_supply_days": 10.0, "available_coords": [[5,5],[6,6]]},  # 사기 붕괴 → 후퇴
		{},  # 빈 context
	]
	for i in range(cases.size()):
		var ctx: Dictionary = cases[i] as Dictionary
		var result: Dictionary = Fallback.get_enemy_decision(ctx)
		_assert(result.has("enemy_dialogue"), "enemy[%d] dialogue" % i)
		_assert(result.has("commander_thought"), "enemy[%d] thought" % i)
		_assert(result.has("decision") and (result["decision"] as Dictionary).has("action_type"), "enemy[%d] decision.action_type" % i)
		_assert(result.get("is_fallback", false) == true, "enemy[%d] is_fallback" % i)
		var act: String = str((result["decision"] as Dictionary).get("action_type", ""))
		_assert(act in ["frontal_assault","flank_attack","ambush","feint_retreat","hold_fortify","retreat","breakout","supply_raid","siege_assault","scout_probe","surrender"], "enemy[%d] action_type enum (%s)" % [i, act])
	# 포위+보급부족+참모사망 → breakout
	var enc: Dictionary = Fallback.get_enemy_decision({"encircled": true, "enemy_morale": 20.0, "enemy_supply_days": 1.5, "enemy_staff_alive": false, "available_coords": [[3,2]], "friendly_est_total": 5000, "enemy_total": 2000})
	_assert(str((enc["decision"] as Dictionary)["action_type"]) in ["breakout", "surrender"], "enemy 포위 탈출/항복 분기")
	# 참모 사망 시 통제력 하락
	_assert(float(enc.get("staff_control_modifier", 1.0)) < 0.6, "enemy 참모사망 통제력 <0.6")


func test_prisoner_fallback() -> void:
	print("\n[4] Prisoner Fallback")
	var cases: Array = [
		{"prisoner_personality": "충의파", "loyalty": 92, "days_captive": 2, "treatment": "보통", "interrogation_style": "persuade", "question": "병력을 말하라", "true_info": {"enemy_total": 4800, "supply_days": 14.0, "commander": "왕건"}, "offer_made": "관직 보장"},
		{"prisoner_personality": "교활파", "loyalty": 45, "interrogation_style": "persuade", "true_info": {"enemy_total": 5200, "supply_days": 10.0, "commander": "유지겸"}},
		{"prisoner_personality": "현실파", "loyalty": 55, "interrogation_style": "bribe", "offer_made": "종사관 직위", "true_info": {"enemy_total": 4100, "supply_days": 12.0, "commander": "맹지상"}},
		{"prisoner_personality": "겁약파", "loyalty": 30, "interrogation_style": "intimidate", "true_info": {"enemy_total": 4800, "supply_days": 8.0, "commander": "왕초"}},
		{"prisoner_personality": "원한파", "loyalty": 40, "interrogation_style": "persuade", "true_info": {"enemy_total": 3000, "supply_days": 5.0, "commander": "배신한주군"}},
		{},  # 빈 context
	]
	for i in range(cases.size()):
		var ctx: Dictionary = cases[i] as Dictionary
		var result: Dictionary = Fallback.get_prisoner_response(ctx)
		_assert(result.has("prisoner_dialogue"), "prisoner[%d] dialogue" % i)
		_assert(result.get("attitude", "") in ["defiant","evasive","cooperative","deceptive","broken","conditional"], "prisoner[%d] attitude enum" % i)
		_assert(result.get("truthfulness", "") in ["true","partial","false"], "prisoner[%d] truthfulness enum" % i)
		_assert(result.get("is_fallback", false) == true, "prisoner[%d] is_fallback" % i)
		_assert(result.has("revealed_info"), "prisoner[%d] revealed_info" % i)
	# 충의파는 투항 거부
	var loyal_res: Dictionary = Fallback.get_prisoner_response({"prisoner_personality": "충의파", "loyalty": 92, "interrogation_style": "persuade", "true_info": {"enemy_total": 4800, "supply_days": 14.0, "commander": "왕건"}})
	_assert(loyal_res["attitude"] == "defiant" and float(loyal_res["surrender_will"]) < 0.2, "prisoner 충의파 defiant+낮은 surrender_will")
	# 교활파는 거짓
	var deceit_res: Dictionary = Fallback.get_prisoner_response({"prisoner_personality": "교활파", "loyalty": 45, "interrogation_style": "persuade", "true_info": {"enemy_total": 5200, "supply_days": 10.0, "commander": "유지겸"}})
	_assert(deceit_res["truthfulness"] == "false" and deceit_res["attitude"] == "deceptive", "prisoner 교활파 deceptive+false")


func test_parser() -> void:
	print("\n[5] SLMParser")
	# 정상 JSON
	var p1: Dictionary = Parser.extract_json('{"staff_dialogue": "주공", "confidence_level": "high"}')
	_assert(p1.has("staff_dialogue"), "parser 정상 JSON")
	# 코드블록 감싼 JSON
	var p2: Dictionary = Parser.extract_json('```json\n{"king_dialogue": "짐이 명하노니", "mood": "neutral"}\n```')
	_assert(p2.has("king_dialogue"), "parser 코드블록 JSON")
	# 잡텍스트 섞인 JSON
	var p3: Dictionary = Parser.extract_json('주공, 판단하건대 ... {"king_dialogue": "짐이 명하노니", "mood": "neutral"} 이상입니다.')
	_assert(p3.has("king_dialogue"), "parser 잡텍스트 섞인 JSON")
	# trailing comma 복구
	var p4: Dictionary = Parser.extract_json('{"enemy_dialogue": "돌격!", "commander_thought": "밀어붙인다", "decision": {"action_type": "frontal_assault", "aggression": 0.9, "risk": "high",},}')
	_assert(p4.has("enemy_dialogue"), "parser trailing comma 복구")
	# 빈 문자열
	var p5: Dictionary = Parser.extract_json('')
	_assert(p5.is_empty(), "parser 빈 문자열 → empty")
	# 검증: staff
	var v1: Dictionary = Parser.validate_staff_advice({"staff_dialogue": "주공", "confidence_level": "high", "staff_personality": "균형파", "tactical_options": [{"id": "option_a", "title": "정찰", "risk": "low", "action_type": "scout_target"}]})
	_assert(v1.has("tactical_options"), "parser staff 검증")
	# 검증: 빈 데이터는 빈 반환
	var v2: Dictionary = Parser.validate_staff_advice({})
	_assert(v2.is_empty(), "parser 빈 데이터 검증 → empty")


func test_schemas() -> void:
	print("\n[6] AISchemas")
	_assert(not Schemas.get_schema("staff").is_empty(), "schema staff 존재")
	_assert(not Schemas.get_schema("king").is_empty(), "schema king 존재")
	_assert(not Schemas.get_schema("enemy").is_empty(), "schema enemy 존재")
	_assert(not Schemas.get_schema("prisoner").is_empty(), "schema prisoner 존재")
	_assert(Schemas.STAFF_ACTION_TYPES.size() == 8, "STAFF_ACTION_TYPES 8개")
	_assert(Schemas.ENEMY_ACTION_TYPES.size() == 11, "ENEMY_ACTION_TYPES 11개")
	var errs: Array = Schemas.quick_validate({"staff_dialogue": "주공", "confidence_level": "high", "staff_personality": "균형파", "tactical_options": []}, "staff")
	_assert(errs.is_empty(), "quick_validate 정상 케이스 통과")
	var errs2: Array = Schemas.quick_validate({"staff_dialogue": "주공"}, "staff")
	_assert(errs2.size() > 0, "quick_validate 누락 필드 감지")


func test_edge_cases() -> void:
	print("\n[7] Edge Cases")
	# 모든 폴백에 빈 Dictionary — 크래시 없어야 함
	var r1: Dictionary = Fallback.get_staff_advice({})
	var r2: Dictionary = Fallback.get_king_order({})
	var r3: Dictionary = Fallback.get_enemy_decision({})
	var r4: Dictionary = Fallback.get_prisoner_response({})
	_assert(not r1.is_empty() and not r2.is_empty() and not r3.is_empty() and not r4.is_empty(), "빈 context 폴백 크래시 없음")
	# JSON 파싱 엣지
	var p_empty: Dictionary = Parser.extract_json('{}')
	_assert(p_empty is Dictionary, "빈 JSON 객체 파싱")
	var p_invalid: Dictionary = Parser.extract_json('not json at all')
	_assert(p_invalid.is_empty(), "완전 비JSON → empty")
