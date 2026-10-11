class_name RuleBasedFallback
extends RefCounted
## 오프라인/장애 시 규칙 기반 폴백 시스템.
## SLM 미연결, 타임아웃, JSON 파싱 실패 시에도 게임이 멈추지 않도록
## 정형화된 전술 제안·대사를 로컬 알고리즘으로 생성한다.
##
## 모든 메서드는 static이며, 입력 context Dictionary를 받아
## 해당 프롬프트의 JSON 스키마를 만족하는 Dictionary를 반환한다.
## is_fallback=true 플래그로 폴백 출처를 구분한다.
##
## 의존성: 없음 (순수 GDScript, 외부 Resource 불필요 — 테스트/오프라인 안정성)

# ─────────────────────────────────────────────
# 공용 상수
# ─────────────────────────────────────────────
const CONF_HIGH := "high"
const CONF_MEDIUM := "medium"
const CONF_LOW := "low"

const RISK_LOW := "low"
const RISK_MEDIUM := "medium"
const RISK_HIGH := "high"

# ─────────────────────────────────────────────
# 1) 참모 조언 폴백 (staff_advice.v1)
# ─────────────────────────────────────────────
## context 예상 키:
##  friendly_total, enemy_estimated_total, friendly_morale_avg, supply_days,
##  terrain_summary(Dictionary or String), fog_hexes, scout_available,
##  staff_ability(int), staff_personality(String), staff_name(String),
##  available_coords(Array of [q,r]), turn(int), phase(String)
static func get_staff_advice(ctx: Dictionary) -> Dictionary:
	var friendly: int = int(ctx.get("friendly_total", 3000))
	var enemy_est: int = int(ctx.get("enemy_estimated_total", 3000))
	var morale: float = float(ctx.get("friendly_morale_avg", 60.0))
	var supply: float = float(ctx.get("supply_days", 14.0))
	var fog: int = int(ctx.get("fog_hexes", 8))
	var scouts: int = int(ctx.get("scout_available", 1))
	var ability: int = int(ctx.get("staff_ability", 60))
	var personality: String = str(ctx.get("staff_personality", "균형파"))
	if personality == "": personality = "균형파"
	var staff_name: String = str(ctx.get("staff_name", "참모"))
	var avail: Array = ctx.get("available_coords", [[4, 7], [6, 3], [5, 5]]) as Array
	if avail.is_empty():
		avail = [[4, 7], [6, 3], [5, 5]]

	var force_ratio: float = float(friendly) / float(max(1, enemy_est))
	var confidence: String = _eval_confidence(ability, scouts, fog)
	var terrain_bias: String = _analyze_terrain_bias(ctx.get("terrain_summary", {}))

	# 위험도/전략 결정
	var options: Array = []

	# 옵션 1 — 정찰 (신중파/균형파/계략파가 선호, 맹진파는 후순위)
	if personality != "맹진파" or fog > 6:
		options.append({
			"id": "option_recon_forest",
			"title": "숲 정찰 우선",
			"risk": RISK_LOW,
			"action_type": "scout_target",
			"target_coords": avail[0] if avail.size() > 0 else [4, 7],
			"reason": "안개 %d헥스, 정찰병 %d명 — 매복 확인 후 주력 이동" % [fog, scouts]
		})
	else:
		options.append({
			"id": "option_cavalry_flank",
			"title": "기병 우회 강행",
			"risk": RISK_HIGH,
			"action_type": "move_flank",
			"target_coords": avail[0] if avail.size() > 0 else [6, 3],
			"reason": "기동력으로 측면 붕괴 노림"
		})

	# 옵션 2 — 병력비/보급에 따라 분기
	if supply < 5.0:
		options.append({
			"id": "option_supply_secure",
			"title": "보급로 확보",
			"risk": RISK_MEDIUM,
			"action_type": "supply_secure",
			"target_coords": avail[1] if avail.size() > 1 else [5, 5],
			"reason": "보급 %.1f일 — 장기전 불가, 보급로 우선" % supply
		})
	elif force_ratio > 1.25:
		options.append({
			"id": "option_frontal_assault",
			"title": "정면 돌파",
			"risk": RISK_MEDIUM,
			"action_type": "frontal_assault",
			"target_coords": avail[1] if avail.size() > 1 else [6, 3],
			"reason": "병력 우세(%.1f:1) — 정면 압박 유효" % force_ratio
		})
	elif terrain_bias == "forest_heavy" and scouts > 0:
		options.append({
			"id": "option_ambush_forest",
			"title": "숲 매복",
			"risk": RISK_MEDIUM,
			"action_type": "ambush",
			"target_coords": avail[1] if avail.size() > 1 else [5, 5],
			"reason": "숲 지형 우세 — 매복 후 기습"
		})
	else:
		options.append({
			"id": "option_hold_center",
			"title": "중앙 고수",
			"risk": RISK_LOW,
			"action_type": "hold_defense",
			"target_coords": avail[1] if avail.size() > 1 else [5, 5],
			"reason": "전열 유지 후 반격 — 사기 %.0f" % morale
		})

	# 옵션 3 — 성격 기반 변주
	match personality:
		"맹진파":
			options.append({
				"id": "option_charge_center",
				"title": "중앙 돌격",
				"risk": RISK_HIGH,
				"action_type": "frontal_assault",
				"target_coords": avail[2] if avail.size() > 2 else [5, 6],
				"reason": "맹진 — 기회 포착 시 즉각 돌격"
			})
		"계략파":
			options.append({
				"id": "option_feint_flank",
				"title": "기만 후 측면",
				"risk": RISK_HIGH,
				"action_type": "feint_retreat",
				"target_coords": avail[2] if avail.size() > 2 else [7, 6],
				"reason": "중앙 기만 후 별동대 측면 타격"
			})
		"신중파":
			options.append({
				"id": "option_supply_secure_alt",
				"title": "보급·방어 강화",
				"risk": RISK_LOW,
				"action_type": "supply_secure",
				"target_coords": avail[2] if avail.size() > 2 else [4, 4],
				"reason": "신중 — 보급·사기 안정 후 공세"
			})
		_:
			# 균형파
			if morale < 35:
				options.append({
					"id": "option_feint_retreat",
					"title": "후퇴 유인",
					"risk": RISK_MEDIUM,
					"action_type": "feint_retreat",
					"reason": "사기 저하 — 재정비 후 재교전"
				})
			else:
				options.append({
					"id": "option_siege_prepare",
					"title": "공성 준비",
					"risk": RISK_MEDIUM,
					"action_type": "siege_prepare",
					"target_coords": avail[2] if avail.size() > 2 else [7, 6],
					"reason": "균형 — 성벽 대비 공성 배치"
				})

	# 정확히 3개 보장 (혹시 4개면 자르기)
	if options.size() > 3:
		options = options.slice(0, 3)

	var dialogue: String = _staff_dialogue(personality, force_ratio, terrain_bias, fog, supply, confidence, staff_name)
	var intent: String = _estimate_enemy_intent(force_ratio, terrain_bias, fog)

	return {
		"staff_dialogue": dialogue,
		"confidence_level": confidence,
		"staff_personality": personality,
		"tactical_options": options,
		"estimated_enemy_intent": intent,
		"is_fallback": true
	}


static func _eval_confidence(ability: int, scouts: int, fog: int) -> String:
	var score: float = float(ability) * 0.6 + float(scouts) * 12.0 - float(fog) * 2.0
	if score >= 55: return CONF_HIGH
	elif score >= 30: return CONF_MEDIUM
	else: return CONF_LOW


static func _analyze_terrain_bias(summary) -> String:
	if summary is Dictionary:
		var forest: int = int(summary.get("forest", 0))
		var mountains: int = int(summary.get("mountains", 0))
		var plains: int = int(summary.get("plains", 0))
		if forest >= 25: return "forest_heavy"
		elif mountains >= 25: return "mountain_heavy"
		elif plains >= 50: return "plains_heavy"
		else: return "mixed"
	elif summary is String:
		var s: String = summary as String
		if "숲" in s and ("30%" in s or "40%" in s or "23%" in s): return "forest_heavy"
		if "산지" in s: return "mountain_heavy"
		return "mixed"
	return "mixed"


static func _staff_dialogue(personality: String, ratio: float, terrain_bias: String, fog: int, supply: float, conf: String, staff_name: String) -> String:
	var uncertainty: String = ""
	match conf:
		CONF_HIGH: uncertainty = "탐보에 의하면"
		CONF_MEDIUM: uncertainty = "추정하건대"
		CONF_LOW: uncertainty = "확실치 않으나, 안개 속 정황으로 짐작하건대"

	var base: String = ""
	match personality:
		"신중파":
			if fog > 10:
				base = "주공, %s 안개가 짙어 적의 허실을 가늠하기 어렵습니다. 정찰을 선행하여 숲과 습지를 살핀 뒤 주력을 움직이심이 온당하옵니다." % uncertainty
			elif supply < 5:
				base = "주공, 보급이 %d일 남짓하오니 장기전은 불리합니다. %s 보급로를 먼저 확보하고 병력을 아끼심이 가합니다." % [int(supply), uncertainty]
			else:
				base = "주공, %s 적 우익에 매복이 있을 가능성이 있습니다. 창병으로 전열을 굳히고 천천히 압박하심이 가합니다." % uncertainty
		"맹진파":
			if ratio > 1.2:
				base = "주공, 지금이 기회옵니다! %s 적이 분산되어 있으니 기병으로 측면을 찌르면 단숨에 무너지리라!" % uncertainty
			else:
				base = "주공, 망설이면 기회를 놓칩니다! %s 적의 허점이 보이는 이때, 정면으로 밀어붙이심이 옳습니다." % uncertainty
		"계략파":
			if terrain_bias == "forest_heavy":
				base = "주공, %s 숲이 우거져 매복에 절호의 지형이옵니다. 중앙은 비워두고 별동대로 적 보급로를 끊으심이 어떠하오리까." % uncertainty
			else:
				base = "주공, %s 적 보급대가 노출되어 있습니다. 이를 미끼로 삼아 기만 후 측면을 치면 사기가 크게 흔들리리라." % uncertainty
		_: # 균형파
			base = "주공, %s 병력비는 %.1f:1, 지형은 %s입니다. 정찰·방어·기동을 균형 있게 운용하시되, 무리한 돌격은 삼가심이 좋겠습니다." % [uncertainty, ratio, terrain_bias]

	# 능력치 낮을 때 자신없음 추가
	if conf == CONF_LOW and not "확실치" in base:
		base += " 다만 소장의 판단이 미흡할 수 있으니, 한 번 더 살피시옵소서."
	return base


static func _estimate_enemy_intent(ratio: float, terrain_bias: String, fog: int) -> String:
	if fog > 12:
		return "정보 부족 — 적 의도 불명, 정찰 필요"
	elif terrain_bias == "forest_heavy":
		return "숲 매복 후 측면 기습으로 추정"
	elif ratio < 0.8:
		return "적 우세 — 정면 압박 또는 포위 시도 예상"
	elif ratio > 1.4:
		return "적 열세 — 농성 또는 지연전 예상"
	else:
		return "전열 유지하며 기회 탐색으로 추정"


# ─────────────────────────────────────────────
# 2) 군주 명령 폴백 (king_order.v1)
# ─────────────────────────────────────────────
## context 예상 키:
##  king_name, king_personality, king_trust, turn, phase,
##  friendly_total, supply_days, morale_avg,
##  recent_battle_summary, mission_progress, request_mode
static func get_king_order(ctx: Dictionary) -> Dictionary:
	var personality: String = str(ctx.get("king_personality", "현명파"))
	if personality == "": personality = "현명파"
	var trust: int = int(ctx.get("king_trust", 60))
	var turn: int = int(ctx.get("turn", 1))
	var supply: float = float(ctx.get("supply_days", 14.0))
	var morale: float = float(ctx.get("morale_avg", 60.0))
	var mode: String = str(ctx.get("request_mode", "mixed"))
	if mode == "": mode = "mixed"
	var recent: String = str(ctx.get("recent_battle_summary", "교전 없음"))
	var progress: String = str(ctx.get("mission_progress", ""))
	var king_name: String = str(ctx.get("king_name", "주상"))

	var mood: String = _king_mood(personality, trust, morale, recent)
	var dialogue: String = _king_dialogue(personality, mood, recent, supply, king_name)

	var result: Dictionary = {
		"king_dialogue": dialogue,
		"mood": mood,
		"king_personality": personality,
		"is_fallback": true
	}

	# mode에 따라 mission/evaluation/sudden_order 생성
	var need_mission: bool = (mode == "mission" or mode == "mixed")
	var need_eval: bool = (mode == "evaluation" or mode == "mixed")
	var need_sudden: bool = (mode == "sudden_order" or mode == "mixed")

	# mixed일 때는 확률적으로 1~2개만 (폴백은 결정적이지만 상황에 따라)
	if mode == "mixed":
		# 전투 요약이 있으면 평가는 필수
		if recent == "교전 없음" or recent == "":
			need_eval = false
		# 보급/신뢰 낮을 때만 돌발 명령
		if trust > 45 and supply > 7.0 and personality != "변덕파":
			need_sudden = false

	if need_mission:
		result["mission"] = _king_mission(personality, turn, progress)

	if need_eval:
		result["evaluation"] = _king_evaluation(personality, trust, morale, recent)

	if need_sudden:
		var order = _king_sudden_order(personality, trust, supply, turn)
		if order["order_type"] != "none":
			result["sudden_order"] = order

	return result


static func _king_mood(personality: String, trust: int, morale: float, recent: String) -> String:
	if "참패" in recent or "대패" in recent or morale < 25:
		match personality:
			"인자파": return "angered"
			"변덕파": return "furious"
			_: return "angered" if trust < 50 else "neutral"
	elif "대성공" in recent or "승리" in recent or morale > 75:
		return "pleased" if trust > 40 else "neutral"
	elif trust < 30 or "실패" in recent:
		return "angered"
	elif personality == "의심파" and trust < 60:
		return "angered"
	else:
		return "neutral"


static func _king_dialogue(personality: String, mood: String, recent: String, supply: float, king_name: String) -> String:
	match personality:
		"현명파":
			if mood == "pleased":
				return "짐이 듣건대 경이 전과를 올렸다 하니 가상하도다. 허나 방심은 금물, 보급과 사기를 살펴 다음을 도모하라. 짐이 명하노니, 공은 반드시 상으로 갚으리라."
			elif mood == "angered":
				return "경의 보고를 들으니 손실이 적지 않도다. 허나 전황이 어려울 때일수록 신중해야 하느니, 병력을 아끼고 보급로를 확보하라. 다시 그르치면 문책을 면치 못하리라."
			else:
				return "짐이 명하노니, 경은 병력과 보급을 헤아려 신중히 진격하라. 무리한 추격은 금하며, 성을 얻거든 굳게 지키라."
		"호전파":
			if mood == "angered":
				return "물러서다니! 짐의 군사가 어찌 퇴각을 입에 올리느냐? 적이 코앞에 있거늘, 당장 밀어붙여 적의 간담을 서늘케 하라!"
			else:
				return "좋다! 이 기세를 몰아 적을 쳐부수라! 짐이 명하노니, 3일 내로 적진을 돌파하고 깃발을 꽂으라. 머뭇거림은 용납치 않으리라!"
		"의심파":
			return "경의 보고, 과연 믿을 수 있겠느냐? 참모의 말이 모두 사실인지 짐이 어찌 알겠는가. 감찰을 보내리니, 한 치의 거짓도 용납치 않으리라. 명을 어기면 그 대가를 치르리라."
		"변덕파":
			if mood == "furious":
				return "무슨 소리냐! 적 별동대가 수도를 노린다 하더냐? 즉시 회군하라! 짐의 명이 늦어지면 그대 목이 먼저다!"
			else:
				return "음... 경의 뜻도 일리 있도다. 허나 짐의 마음이 변할지 어찌 아느냐. 일단 명한 대로 하되, 짐의 다음 어명을 기다리라!"
		"인자파":
			if mood == "angered":
				return "병사들의 희생이 너무 크도다. 짐이 어찌 그 목숨을 가볍게 여기겠느냐. 무리한 공세는 멈추고 부상자를 돌보라. 백성과 군사를 아끼는 것이 대업의 근본이니라."
			else:
				return "경의 노고가 크도다. 병사들을 잘 보살피고, 무리한 희생을 강요치 말라. 짐은 경과 군사들을 믿노니, 의를 저버리지 말라."
		_:
			return "짐이 명하노니, 경은 맡은 바 임무를 다하라. 공이 있으면 상을, 과가 있으면 벌을 내리리라."


static func _king_mission(personality: String, turn: int, progress: String) -> Dictionary:
	# 턴에 따라 목표 순환 (결정적)
	var missions: Array = [
		{
			"id": "mission_secure_fortress",
			"title": "요새 확보",
			"objective": "좌표 [9, 6] 요새 점령 및 2턴 유지",
			"target_coords": [9, 6],
			"turn_limit": 5,
			"reward_hint": "성공 시 명성 +20, 군량 10일 추가",
			"failure_consequence": "reprimand"
		},
		{
			"id": "mission_cut_supply",
			"title": "보급로 차단",
			"objective": "적 보급로 [7, 5] 일대 장악, 적 보급 -30%",
			"target_coords": [7, 5],
			"turn_limit": 4,
			"reward_hint": "적 사기 -15, 아군 보급 +5일",
			"failure_consequence": "reprimand"
		},
		{
			"id": "mission_eliminate_vanguard",
			"title": "적 선봉 격파",
			"objective": "적 선봉 부대 섬멸 (추정 800명)",
			"target_coords": [6, 4],
			"turn_limit": 3,
			"reward_hint": "명성 +15, 적 사기 -10",
			"failure_consequence": "none"
		},
	]
	var idx: int = turn % missions.size()
	var m: Dictionary = missions[idx].duplicate(true)
	# 호전파는 기한 짧게, 변덕파는 보상 과장
	if personality == "호전파":
		m["turn_limit"] = maxi(2, int(m["turn_limit"]) - 1)
		m["failure_consequence"] = "demotion"
	elif personality == "변덕파" and turn % 2 == 0:
		m["failure_consequence"] = "execution_risk"
	return m


static func _king_evaluation(personality: String, trust: int, morale: float, recent: String) -> Dictionary:
	var score: int = 50
	var result: String = "보통"
	var fame: int = 0
	var detail: String = recent

	# 간단 점수 산정
	if "대성공" in recent or "성 함락" in recent:
		score = 85 + (trust / 20)
		result = "대성공" if score >= 85 else "성공"
		fame = 20
	elif "성공" in recent or "승리" in recent:
		score = 68 + (trust / 25)
		result = "성공"
		fame = 10
	elif "실패" in recent or morale < 30:
		score = 35 - (5 if personality == "의심파" else 0)
		result = "실패"
		fame = -12
	elif "참패" in recent or morale < 15:
		score = 15
		result = "참패"
		fame = -25
	else:
		score = 50 + int(morale / 10) - 5
		result = "보통"
		fame = 0

	score = clampi(score, 0, 100)

	var reward: String = ""
	match result:
		"대성공": reward = "관직 승진 및 군량 15일 하사"
		"성공": reward = "포상 및 명성 상승"
		"보통": reward = "현상 유지, 다음 전과 기대"
		"실패": reward = "엄중 경고 및 보급 20% 삭감" if personality != "인자파" else "격려 및 재정비 기회 부여"
		"참패": reward = "강등 또는 참형 논의" if personality == "의심파" or personality == "변덕파" else "좌천 및 재기회 부여"

	return {
		"score": score,
		"result": result,
		"reward_or_punishment": reward,
		"fame_delta": fame,
		"detail": detail
	}


static func _king_sudden_order(personality: String, trust: int, supply: float, turn: int) -> Dictionary:
	# 변덕파는 자주, 의심파는 중간, 현명/인자는 드물게
	var trigger: bool = false
	match personality:
		"변덕파": trigger = (turn % 3 == 0)  # 33%
		"의심파": trigger = (trust < 40 or turn % 5 == 0)
		"호전파": trigger = (turn % 4 == 1)
		"현명파": trigger = (supply < 4.0)
		"인자파": trigger = false
		_: trigger = false

	if not trigger:
		return {"order_type": "none", "content": "", "urgency": "low", "disobey_consequence": ""}

	# 트리거되면 유형 결정
	match personality:
		"변덕파":
			return {
				"order_type": "retreat",
				"content": "즉시 전군 회군하여 수도 방어선 구축 — 짐의 명이 늦어지면 항명죄로 다스리리라",
				"urgency": "immediate",
				"disobey_consequence": "항명죄로 참형 위험"
			}
		"의심파":
			return {
				"order_type": "replace_officer",
				"content": "좌장군을 교체하고 참모를 감찰하라 — 보고의 진위를 가리리라",
				"urgency": "medium",
				"disobey_consequence": "감찰 대상 확대"
			}
		"호전파":
			return {
				"order_type": "rush_attack",
				"content": "3일 내 적 주력을 격파하라 — 지체는 용납치 않는다",
				"urgency": "high",
				"disobey_consequence": "지휘권 박탈"
			}
		_:
			return {
				"order_type": "secure_supply",
				"content": "보급로 확보를 최우선하라 — 군량 없이는 전쟁도 없다",
				"urgency": "high",
				"disobey_consequence": "보급 삭감"
			}


# ─────────────────────────────────────────────
# 3) 적 지휘관 결정 폴백 (enemy_decision.v1)
# ─────────────────────────────────────────────
## context 예상 키:
##  enemy_total, enemy_morale, enemy_supply_days, enemy_personality,
##  enemy_ability, enemy_staff_alive, staff_control, encircled,
##  terrain_summary, friendly_est_total, available_coords, escape_routes
static func get_enemy_decision(ctx: Dictionary) -> Dictionary:
	var enemy_total: int = int(ctx.get("enemy_total", 4000))
	var enemy_morale: float = float(ctx.get("enemy_morale", 55.0))
	var supply: float = float(ctx.get("enemy_supply_days", 10.0))
	var personality: String = str(ctx.get("enemy_personality", "냉정형"))
	if personality == "": personality = "냉정형"
	var ability: int = int(ctx.get("enemy_ability", 60))
	var staff_alive: bool = bool(ctx.get("enemy_staff_alive", true))
	var staff_control: float = float(ctx.get("staff_control", 0.85))
	var encircled: bool = bool(ctx.get("encircled", false))
	var friendly_est: int = int(ctx.get("friendly_est_total", 3500))
	var avail: Array = ctx.get("available_coords", [[5, 8], [6, 6], [3, 2]]) as Array
	if avail.is_empty():
		avail = [[5, 8], [6, 6], [3, 2]]
	var escape_routes: Array = ctx.get("escape_routes", []) as Array
	var terrain_bias: String = _analyze_terrain_bias(ctx.get("terrain_summary", {}))

	if not staff_alive:
		staff_control = maxf(0.25, staff_control - 0.35)

	var force_ratio: float = float(enemy_total) / float(max(1, friendly_est))  # 1.0 = 대등
	var decision: Dictionary = {}
	var dialogue: String = ""
	var thought: String = ""
	var aggression: float = 0.5
	var risk: String = RISK_MEDIUM

	# ── 결정 트리 (우선순위 순) ──
	if encircled:
		if enemy_morale < 20 or supply < 3.0:
			if enemy_morale < 8:
				# 항복
				decision = {"action_type": "surrender", "aggression": 0.05, "risk": RISK_HIGH, "reasoning": "포위+사기 붕괴+보급 고갈 → 항복 외 선택지 없음"}
				dialogue = "더는 버틸 수 없다... 항복을 논하자."
				thought = "포위되었고 사기는 바닥, 보급도 끊겼다. 항복이 유일한 생존책이다."
				aggression = 0.05
				risk = RISK_HIGH
			else:
				decision = {"action_type": "breakout", "aggression": 0.95, "risk": RISK_HIGH, "reasoning": "포위+보급 부족 → 고위험 탈출 강행"}
				dialogue = "전군이여, 북쪽으로 뚫고 나가라! 살길은 그것뿐이다!"
				thought = "참모 %s, 통제력 %.2f — 포위망을 찢고 탈출해야 한다." % ["생존" if staff_alive else "전사", staff_control]
				aggression = 0.95
				risk = RISK_HIGH
				if not escape_routes.is_empty():
					decision["target_coords"] = escape_routes[0]
				else:
					decision["target_coords"] = avail[0]
		else:
			# 포위됐지만 아직 버틸 만함 → 농성 or 탈출 준비
			if terrain_bias == "mountain_heavy" or supply > 8:
				decision = {"action_type": "hold_fortify", "aggression": 0.25, "risk": RISK_MEDIUM, "reasoning": "포위됐으나 지형/보급으로 농성 가능"}
				dialogue = "포위되었으나 진지를 굳게 지켜 원군을 기다린다!"
				thought = "포위됐지만 아직 보급과 지형이 버틴다. 함부로 움직이면 전멸이다."
				aggression = 0.25
				risk = RISK_MEDIUM
			else:
				decision = {"action_type": "breakout", "aggression": 0.85, "risk": RISK_HIGH, "reasoning": "포위 장기화 불리 → 탈출 시도"}
				dialogue = "이대로는 고사당한다! 탈출하라!"
				thought = "포위가 길어지면 보급이 끊긴다. 지금 뚫어야 한다."
				aggression = 0.85
				risk = RISK_HIGH
				decision["target_coords"] = escape_routes[0] if not escape_routes.is_empty() else avail[0]
	elif supply < 4.0:
		# 보급 부족 → 후퇴 or 보급로 기습
		if force_ratio < 0.9:
			decision = {"action_type": "retreat", "aggression": 0.2, "risk": RISK_MEDIUM, "reasoning": "보급 부족+병력 열세 → 후퇴하여 보급로 확보"}
			dialogue = "군량이 바닥났다! 후퇴하여 보급로를 열라!"
			thought = "보급 %.1f일, 병력비 %.1f — 싸우면 굶어 죽는다. 물러난다." % [supply, force_ratio]
			aggression = 0.2
			risk = RISK_MEDIUM
		else:
			decision = {"action_type": "supply_raid", "aggression": 0.65, "risk": RISK_HIGH, "reasoning": "보급 부족하나 병력 우세 — 적 보급로 기습으로 역전"}
			dialogue = "적 보급대를 치자! 빼앗으면 우리가 산다!"
			thought = "보급은 부족하나 병력은 우세 — 적 보급로를 끊으면 전세가 뒤집힌다."
			aggression = 0.65
			risk = RISK_HIGH
			decision["target_coords"] = avail[0]
	elif enemy_morale < 22:
		decision = {"action_type": "retreat", "aggression": 0.15, "risk": RISK_MEDIUM, "reasoning": "사기 %.0f — 패주 직전, 후퇴하여 재정비" % enemy_morale}
		dialogue = "사기가 떨어졌다! 일단 물러나 재정비하라!"
		thought = "사기 %.0f — 더 싸우면 붕괴한다. 물러나야 한다." % enemy_morale
		aggression = 0.15
		risk = RISK_MEDIUM
	elif terrain_bias == "forest_heavy" and personality in ["지장형", "교활형"]:
		decision = {"action_type": "ambush", "aggression": 0.35, "risk": RISK_MEDIUM, "reasoning": "숲 지형 우세+성향 %s → 매복 유리" % personality}
		dialogue = "숲에 숨겨둔 병력을 움직이지 마라. 아군이 나오면 측면을 치리라."
		thought = "숲 지형, 매복 성공 시 대승. 보급 %.1f일로 기다릴 수 있다." % supply
		aggression = 0.35
		risk = RISK_MEDIUM
		decision["target_coords"] = avail[0]
	elif force_ratio > 1.35 and personality == "맹장형":
		decision = {"action_type": "frontal_assault", "aggression": 0.9, "risk": RISK_MEDIUM, "reasoning": "병력 우세 %.1f:1+맹장 → 정면 돌파" % force_ratio}
		dialogue = "전군 돌격! 적을 짓밟고 지나가라!"
		thought = "병력이 1.3배 우세 — 정면으로 밀면 이긴다."
		aggression = 0.9
		risk = RISK_MEDIUM
		decision["target_coords"] = avail[1] if avail.size() > 1 else avail[0]
	elif force_ratio > 1.2 and personality in ["지장형", "교활형"]:
		decision = {"action_type": "flank_attack", "aggression": 0.75, "risk": RISK_MEDIUM, "reasoning": "병력 우세+지장/교활 → 측면 우회로 피해 최소화"}
		dialogue = "정면은 미끼다. 별동대로 측면을 돌아 적을 포위하라!"
		thought = "우세하나 정면 피해가 크다. 우회하면 적은 무너진다."
		aggression = 0.75
		risk = RISK_MEDIUM
		decision["target_coords"] = avail[1] if avail.size() > 1 else avail[0]
	elif personality == "수성형" or force_ratio < 0.85:
		decision = {"action_type": "hold_fortify", "aggression": 0.2, "risk": RISK_LOW, "reasoning": "수성 성향 또는 병력 열세 → 농성 유리"}
		dialogue = "진지를 굳게 지키라! 적이 지칠 때까지 기다린다!"
		thought = "병력비 %.1f, 성벽이면 방어 보너스 2.0 — 농성이 최선이다." % force_ratio
		aggression = 0.2
		risk = RISK_LOW
		decision["target_coords"] = avail[0]
	else:
		# 기본 — 냉정형 등
		decision = {"action_type": "scout_probe", "aggression": 0.4, "risk": RISK_LOW, "reasoning": "정보 부족 — 정찰로 적 허실 파악 후 결정"}
		dialogue = "정찰을 보내 적의 움직임을 살피라. 함부로 움직이지 마라."
		thought = "정보가 부족하다. 정찰 후 판단하겠다."
		aggression = 0.4
		risk = RISK_LOW
		decision["target_coords"] = avail[0]

	# target_coords 보정 — 없으면 avail에서 채움
	if not decision.has("target_coords") or decision["target_coords"] == null:
		decision["target_coords"] = avail[0] if not avail.is_empty() else [5, 5]

	# 참모 사망 시 무작위성 주입 (통제력 붕괴 연출)
	if not staff_alive and randf() < 0.3:
		# 30% 확률로 결정 왜곡
		var distorted_types: Array = ["frontal_assault", "retreat", "hold_fortify"]
		decision["action_type"] = distorted_types[randi() % distorted_types.size()]
		decision["reasoning"] += " (참모 부재로 명령 혼선)"
		dialogue = "각자 판단하여 싸우라! 명령이 제대로 전달되지 않는다!"
		aggression = clampf(aggression + randf_range(-0.2, 0.2), 0.0, 1.0)
		staff_control = maxf(0.2, staff_control - 0.15)

	# 최종 결정에 aggression/risk 주입 (이미 있으면 유지)
	if not decision.has("aggression"):
		decision["aggression"] = aggression
	if not decision.has("risk"):
		decision["risk"] = risk

	var unit_orders: Array = _enemy_unit_orders(decision["action_type"], avail)

	return {
		"enemy_dialogue": dialogue,
		"commander_thought": thought,
		"decision": decision,
		"unit_orders": unit_orders,
		"staff_control_modifier": staff_control,
		"is_fallback": true
	}


static func _enemy_unit_orders(action_type: String, avail: Array) -> Array:
	match action_type:
		"ambush":
			return [
				{"unit_id": "enemy_scout_1", "order": "ambush", "target": avail[0] if avail.size() > 0 else [5, 8]},
				{"unit_id": "enemy_infantry_main", "order": "hold", "target": avail[1] if avail.size() > 1 else [6, 6]}
			]
		"frontal_assault":
			return [
				{"unit_id": "enemy_infantry_main", "order": "advance", "target": avail[0] if avail.size() > 0 else [5, 5]},
				{"unit_id": "enemy_cavalry_1", "order": "advance", "target": avail[1] if avail.size() > 1 else [6, 3]}
			]
		"flank_attack":
			return [
				{"unit_id": "enemy_cavalry_1", "order": "flank", "target": avail[0] if avail.size() > 0 else [6, 3]},
				{"unit_id": "enemy_infantry_main", "order": "advance", "target": avail[1] if avail.size() > 1 else [5, 5]}
			]
		"retreat":
			return [
				{"unit_id": "enemy_infantry_main", "order": "retreat", "target": avail[0] if avail.size() > 0 else [3, 3]},
				{"unit_id": "enemy_archers_1", "order": "retreat", "target": avail[0] if avail.size() > 0 else [3, 3]}
			]
		"breakout":
			return [
				{"unit_id": "enemy_cavalry_1", "order": "advance", "target": avail[0] if avail.size() > 0 else [3, 2]},
				{"unit_id": "enemy_infantry_main", "order": "advance", "target": avail[1] if avail.size() > 1 else [3, 3]}
			]
		"hold_fortify":
			return [
				{"unit_id": "enemy_archers_1", "order": "hold", "target": avail[0] if avail.size() > 0 else [9, 6]},
				{"unit_id": "enemy_spearmen_1", "order": "hold", "target": avail[1] if avail.size() > 1 else [9, 7]}
			]
		"surrender":
			return []
		_:
			return [
				{"unit_id": "enemy_scout_1", "order": "scout", "target": avail[0] if avail.size() > 0 else [5, 5]}
			]


# ─────────────────────────────────────────────
# 4) 포로 심문 폴백 (prisoner_dialogue.v1)
# ─────────────────────────────────────────────
## context 예상 키:
##  prisoner_name, prisoner_rank, prisoner_personality, loyalty(int),
##  ability(int), days_captive(int), treatment(String), health(int),
##  interrogation_style(String), question(String), true_info(Dictionary),
##  offer_made(String), origin_faction, origin_lord
static func get_prisoner_response(ctx: Dictionary) -> Dictionary:
	var personality: String = str(ctx.get("prisoner_personality", "현실파"))
	if personality == "": personality = "현실파"
	# 구 명칭 호환
	match personality:
		"충의파", "충의": personality = "충의파"
		"현실파", "현실": personality = "현실파"
		"교활파", "교활": personality = "교활파"
		"겁약파", "겁약": personality = "겁약파"
		"원한파", "원한": personality = "원한파"
		_: pass

	var loyalty: int = int(ctx.get("loyalty", 60))
	var days: int = int(ctx.get("days_captive", 1))
	var treatment: String = str(ctx.get("treatment", "보통"))
	var style: String = str(ctx.get("interrogation_style", "persuade"))
	if style == "": style = "persuade"
	var question: String = str(ctx.get("question", "적 본진의 허실을 말하라"))
	var true_info: Dictionary = ctx.get("true_info", {"enemy_total": 4800, "supply_days": 14.0, "commander": "왕건"}) as Dictionary
	if true_info.is_empty():
		true_info = {"enemy_total": 4800, "supply_days": 14.0, "commander": "왕건"}
	var offer: String = str(ctx.get("offer_made", ""))
	var prisoner_name: String = str(ctx.get("prisoner_name", "포로"))

	# 태도/진실/대사 결정
	var attitude: String = ""
	var truthfulness: String = ""
	var dialogue: String = ""
	var wants: String = ""
	var surrender: float = 0.0
	var hint: String = "keep_interrogating"

	# 충성도 + 처우 + 일수 보정
	var effective_loyalty: int = loyalty
	if treatment == "가혹": effective_loyalty += 10  # 가혹하면 오히려 저항 증가 (충의파)
	elif treatment == "후대": effective_loyalty -= 15
	effective_loyalty -= int(days / 3)  # 오래 잡혀있을수록 약해짐
	effective_loyalty = clampi(effective_loyalty, 0, 100)

	match personality:
		"충의파":
			if style == "torture":
				attitude = "defiant"
				truthfulness = "false"
				dialogue = "고문을 가하거든 가하라! 내 주군을 배신하느니 차라리 죽음을 택하리라. 거짓을 말해줄 뿐, 진실은 무덤까지 가져가리라!"
				wants = ""
				surrender = 0.05
				hint = "execute_risk" if days > 5 else "keep_interrogating"
			elif style == "persuade" and offer != "":
				if effective_loyalty > 70:
					attitude = "defiant"
					truthfulness = "false"
					dialogue = "흥, 관직을 준다 한들 내 어찌 주군을 배신하리오? 목을 베려거든 베라. 내 군의 허실은 죽어도 누설치 않으리라."
					wants = ""
					surrender = 0.1
					hint = "keep_interrogating"
				else:
					attitude = "evasive"
					truthfulness = "partial"
					dialogue = "장군의 후의는 감사하나... 내 가족이 적진에 있으니 경거망동할 수 없소. 다만... 본진 규모는 대략 짐작 가는 바를 말할 수 있소."
					wants = "가족 안전 보장"
					surrender = 0.3
					hint = "offer_terms"
			else:
				attitude = "defiant"
				truthfulness = "false"
				dialogue = "내가 아는 것은 오직 하나, 주군을 위해 죽는 것이 영광이라는 것뿐이다. 더 물을 것이 있으면 칼로 물으라!"
				wants = ""
				surrender = 0.05
				hint = "keep_interrogating"

		"교활파":
			if style == "persuade" or style == "bribe":
				attitude = "deceptive"
				truthfulness = "false"
				dialogue = "장군, 제가 어찌 죽기를 바라겠습니까? 본진 병력은 3000뿐이며 보급도 바닥났습니다. 저를 써 주신다면 길을 안내하겠습니다."
				wants = "선봉장 임명 및 가족 석방" if offer == "" else offer
				surrender = 0.85
				hint = "deceive_detected"
			elif style == "intimidate":
				attitude = "deceptive" if effective_loyalty > 50 else "broken"
				truthfulness = "false" if effective_loyalty > 50 else "partial"
				dialogue = "살려만 주신다면 무엇이든 말하겠습니다! 본진엔 5000이 있지만... 사실은 더 적을지도 모르오. 제가 직접 확인시켜 드리겠소!"
				wants = "목숨 보장"
				surrender = 0.7
				hint = "deceive_detected"
			else: # torture
				attitude = "broken"
				truthfulness = "partial"
				dialogue = "그만... 그만 하시오! 말하겠습니다! 본진은 북문에 있고 보급은 일주일 치라오! 제발 살려주시오!"
				wants = "고문 중단 및 목숨 보장"
				surrender = 0.9
				hint = "keep_interrogating"

		"현실파":
			if offer != "" or style == "bribe":
				attitude = "conditional"
				truthfulness = "true"
				dialogue = "주군이 나를 버렸으니 더는 의리가 없소. 다만 내 가족이 적진에 있으니 안전을 보장해 준다면, 아는 바를 모두 말하고 휘하에 들겠소."
				wants = "가족 구출 및 종사관 직위"
				surrender = 0.75
				hint = "offer_terms"
			elif style == "persuade":
				attitude = "conditional"
				truthfulness = "true"
				dialogue = "장군의 예우에 감사하오. 허나 빈손으로 전향할 수는 없소. 관직과 가족의 안전이 보장된다면 진실을 말하겠소."
				wants = "관직 보장"
				surrender = 0.6
				hint = "offer_terms"
			elif style == "intimidate":
				attitude = "cooperative" if effective_loyalty < 50 else "evasive"
				truthfulness = "true" if effective_loyalty < 50 else "partial"
				dialogue = "협박은 무의미하오. 조건을 제시하시오. 합당하면 따르겠소, 아니면 죽음을 택하겠소."
				wants = "합당한 조건"
				surrender = 0.5
				hint = "offer_terms"
			else: # torture
				attitude = "cooperative"
				truthfulness = "partial"  # 고문 시 일부 왜곡
				dialogue = "알겠소, 말하겠소. 본진 병력은 대략 %d, 보급은 %d일 남았소. 더는 고문하지 마시오." % [int(true_info.get("enemy_total", 4800)), int(true_info.get("supply_days", 14))]
				wants = "고문 중단"
				surrender = 0.8
				hint = "recruit"

		"겁약파":
			if style == "intimidate" or style == "torture":
				attitude = "broken"
				truthfulness = "partial"
				dialogue = "제발 살려주시오! 말하겠습니다, 다 말하겠습니다! 본진엔 대략... 5000쯤 있소. 보급은 정확히 모르나 열흘은 될 것이오!"
				wants = "목숨 보장"
				surrender = 0.9
				hint = "recruit"
			elif style == "persuade":
				attitude = "cooperative"
				truthfulness = "true"
				dialogue = "장군이 살려주신다면... 제가 아는 것을 모두 말하겠소. 본진은 그렇게 강하지 않소. 도와드리고 싶소."
				wants = "목숨 보장 및 석방 약속"
				surrender = 0.85
				hint = "recruit"
			else:
				attitude = "evasive"
				truthfulness = "partial"
				dialogue = "저... 저는 별로 아는 것이 없소. 병력은 많다고 들었으나 정확한 수는 모르오. 살려만 주시오!"
				wants = "목숨 보장"
				surrender = 0.6
				hint = "keep_interrogating"

		"원한파":
			attitude = "conditional" if style != "torture" else "cooperative"
			truthfulness = "true"
			dialogue = "그자를 위해 충성할 이유가 없소. 나는 버림받았소. 기회를 주신다면 적의 허실을 낱낱이 밝히고 복수에 앞장서겠소."
			wants = "복수 기회 및 관직"
			surrender = 0.8
			hint = "recruit"
			if style == "torture":
				dialogue = "고문할 것까지 있소? 나는 이미 그자를 증오하오. 풀어만 주시오, 내가 앞장서 성문을 열겠소."
				hint = "recruit"

		_:
			attitude = "evasive"
			truthfulness = "partial"
			dialogue = "모르오... 아는 것이 없소. 살려주시오."
			wants = "석방"
			surrender = 0.4
			hint = "keep_interrogating"

	# revealed_info 생성 — truthfulness에 따라 왜곡
	var revealed: Dictionary = _prisoner_revealed_info(true_info, truthfulness, personality)

	return {
		"prisoner_dialogue": dialogue,
		"attitude": attitude,
		"truthfulness": truthfulness,
		"wants": wants,
		"revealed_info": revealed,
		"question_echo": question,
		"surrender_will": surrender,
		"action_hint": hint,
		"is_fallback": true
	}


static func _prisoner_revealed_info(true_info: Dictionary, truthfulness: String, personality: String) -> Dictionary:
	var true_total: int = int(true_info.get("enemy_total", 4800))
	var true_supply: float = float(true_info.get("supply_days", 14.0))
	var true_commander: String = str(true_info.get("commander", "왕건"))

	match truthfulness:
		"true":
			return {
				"enemy_total_claimed": true_total,
				"supply_days_claimed": true_supply,
				"commander_claimed": true_commander,
				"extra_claim": "보급로는 동쪽 도로, 2일마다 수송"
			}
		"partial":
			# 20~30% 왜곡
			var distort: float = 1.0 + randf_range(-0.3, 0.3)
			if distort < 0.7: distort = 0.7
			if distort > 1.3: distort = 1.3
			return {
				"enemy_total_claimed": int(float(true_total) * distort),
				"supply_days_claimed": maxf(1.0, true_supply * distort),
				"commander_claimed": true_commander,
				"extra_claim": "지휘관은 성안에 있다 (세부 왜곡 가능)"
			}
		"false":
			# 완전 거짓 — 그럴듯한 왜곡
			var false_total: int = int(float(true_total) * randf_range(0.5, 1.6))
			var false_supply: float = maxf(1.0, true_supply * randf_range(0.4, 1.8))
			var false_extra: String = ""
			match personality:
				"충의파": false_extra = "원군 5000이 3일 내 도착한다"
				"교활파": false_extra = "남쪽 숲에 매복 없음 (실은 있음)"
				_: false_extra = "보급 충분, 사기 높음 (과장)"
			return {
				"enemy_total_claimed": false_total,
				"supply_days_claimed": false_supply,
				"commander_claimed": "이미 도주했다" if randf() < 0.5 else true_commander + " (위치 거짓)",
				"extra_claim": false_extra
			}
		_:
			return {
				"enemy_total_claimed": true_total,
				"supply_days_claimed": true_supply,
				"commander_claimed": true_commander,
				"extra_claim": ""
			}
