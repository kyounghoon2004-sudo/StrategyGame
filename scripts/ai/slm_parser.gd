class_name SLMParser
extends RefCounted
## SLM 응답 JSON 파서 & 스키마 검증기.
## - 코드블록/잡텍스트로부터 JSON 추출
## - 스키마별 필수 필드 검증 및 기본값 보정
## - 예외 처리 — 절대 크래시하지 않음

# ─────────────────────────────────────────────
# 공용: JSON 추출
# ─────────────────────────────────────────────
## SLM이 종종 ```json ... ``` 코드블록이나 설명을 섞어 보내므로,
## 첫 번째 '{'부터 마지막 '}'까지를 추출하여 파싱 시도.
## 실패 시 빈 Dictionary 반환 (호출자가 폴백 처리).
static func extract_json(raw_text: String) -> Dictionary:
	if raw_text == null or raw_text.strip_edges() == "":
		return {}
	var text: String = raw_text.strip_edges()

	# 1) 코드블록 제거: ```json ... ``` 또는 ``` ... ```
	if "```" in text:
		# 가장 바깥 코드블록 추출 시도
		var start_block: int = text.find("```")
		var end_block: int = text.rfind("```")
		if start_block != -1 and end_block != -1 and end_block > start_block:
			var block: String = text.substr(start_block, end_block - start_block + 3)
			# block 내부에서 { } 추출
			var b_open: int = block.find("{")
			var b_close: int = block.rfind("}")
			if b_open != -1 and b_close != -1 and b_close > b_open:
				text = block.substr(b_open, b_close - b_open + 1)
			else:
				# 코드블록이지만 JSON 없음 → 원문 유지
				pass
		else:
			# 단일 ``` 만 있으면 이후 텍스트에서 JSON 찾기
			pass

	# 2) { ... } 범위 추출 (중첩 고려: 첫 '{' ~ 마지막 '}')
	var open_idx: int = text.find("{")
	var close_idx: int = text.rfind("}")
	if open_idx == -1 or close_idx == -1 or close_idx <= open_idx:
		return {}
	var json_str: String = text.substr(open_idx, close_idx - open_idx + 1)

	# 3) 파싱
	var json := JSON.new()
	var err: int = json.parse(json_str)
	if err != OK:
		# trailing comma 복구 시도 (SLM이 자주 생성)
		var fixed: String = _fix_trailing_commas(json_str)
		err = json.parse(fixed)
		if err != OK:
			push_warning("[SLMParser] JSON 파싱 실패: %s | 원문: %s" % [json.get_error_message(), json_str.left(300)])
			return {}
	var data = json.get_data()
	if data is Dictionary:
		return data as Dictionary
	else:
		push_warning("[SLMParser] 파싱 결과가 Dictionary가 아님: %s" % str(typeof(data)))
		return {}


## trailing comma 제거 (예: {"a": 1,} → {"a": 1})
static func _fix_trailing_commas(s: String) -> String:
	# 정규식 없이 단순 치환: ,} → } , ,] → ]
	var result: String = s
	result = result.replace(",}", "}")
	result = result.replace(",]", "]")
	# 공백 포함 케이스
	result = result.replace(", }", "}")
	result = result.replace(", ]", "]")
	return result


# ─────────────────────────────────────────────
# 스키마 검증 — 각 타입별 최소 필수 필드 확인
# 부족하면 기본값으로 보정하여 반환 (부분 성공 허용)
# ─────────────────────────────────────────────
static func validate_staff_advice(data: Dictionary) -> Dictionary:
	if data.is_empty():
		return {}
	# 필수: staff_dialogue, confidence_level, tactical_options
	if not data.has("staff_dialogue"):
		data["staff_dialogue"] = "주공, 전황이 불분명하오니 신중히 살피심이 가합니다."
	if not data.has("confidence_level"):
		data["confidence_level"] = "low"
	elif str(data["confidence_level"]) not in ["high", "medium", "low"]:
		data["confidence_level"] = "medium"
	if not data.has("staff_personality"):
		data["staff_personality"] = "균형파"
	if not data.has("tactical_options"):
		data["tactical_options"] = []
	# tactical_options는 정확히 3개여야 하나, 1개 이상이면 통과 (폴백은 3개 보장)
	var opts = data.get("tactical_options", [])
	if opts is Array and opts.size() > 0:
		for opt in opts:
			if opt is Dictionary:
				if not opt.has("id"): opt["id"] = "option_unknown"
				if not opt.has("title"): opt["title"] = "미정"
				if not opt.has("risk"): opt["risk"] = "medium"
				if not opt.has("action_type"): opt["action_type"] = "hold_defense"
	else:
		# 옵션이 전혀 없으면 기본 1개라도 채움
		data["tactical_options"] = [
			{"id": "option_hold_center", "title": "중앙 고수", "risk": "low", "action_type": "hold_defense"}
		]
	if not data.has("is_fallback"):
		data["is_fallback"] = false
	return data


static func validate_king_order(data: Dictionary) -> Dictionary:
	if data.is_empty():
		return {}
	if not data.has("king_dialogue"):
		data["king_dialogue"] = "짐이 명하노니, 경은 맡은 바를 다하라."
	if not data.has("mood"):
		data["mood"] = "neutral"
	elif str(data["mood"]) not in ["pleased", "neutral", "angered", "furious"]:
		data["mood"] = "neutral"
	# mission/evaluation/sudden_order는 선택적 — 있으면 내부 필드 보정
	if data.has("mission") and data["mission"] is Dictionary:
		var m: Dictionary = data["mission"]
		if not m.has("id"): m["id"] = "mission_unknown"
		if not m.has("title"): m["title"] = "임무"
		if not m.has("objective"): m["objective"] = "목표 달성"
		if not m.has("turn_limit"): m["turn_limit"] = 5
	if data.has("evaluation") and data["evaluation"] is Dictionary:
		var e: Dictionary = data["evaluation"]
		if not e.has("score"): e["score"] = 50
		if not e.has("result"): e["result"] = "보통"
		if not e.has("reward_or_punishment"): e["reward_or_punishment"] = "현상 유지"
	if data.has("sudden_order") and data["sudden_order"] is Dictionary:
		var s: Dictionary = data["sudden_order"]
		if not s.has("order_type"): s["order_type"] = "none"
		if not s.has("content"): s["content"] = ""
	if not data.has("is_fallback"):
		data["is_fallback"] = false
	return data


static func validate_enemy_decision(data: Dictionary) -> Dictionary:
	if data.is_empty():
		return {}
	if not data.has("enemy_dialogue"):
		data["enemy_dialogue"] = "전군, 진지를 지켜라!"
	if not data.has("commander_thought"):
		data["commander_thought"] = "상황을 주시한다."
	if not data.has("decision"):
		data["decision"] = {"action_type": "hold_fortify", "aggression": 0.3, "risk": "low"}
	else:
		var d = data["decision"]
		if d is Dictionary:
			if not d.has("action_type"): d["action_type"] = "hold_fortify"
			if not d.has("aggression"): d["aggression"] = 0.5
			if not d.has("risk"): d["risk"] = "medium"
	if not data.has("is_fallback"):
		data["is_fallback"] = false
	return data


static func validate_prisoner_response(data: Dictionary) -> Dictionary:
	if data.is_empty():
		return {}
	if not data.has("prisoner_dialogue"):
		data["prisoner_dialogue"] = "모르오... 아는 것이 없소."
	if not data.has("attitude"):
		data["attitude"] = "evasive"
	elif str(data["attitude"]) not in ["defiant", "evasive", "cooperative", "deceptive", "broken", "conditional"]:
		data["attitude"] = "evasive"
	if not data.has("truthfulness"):
		data["truthfulness"] = "partial"
	elif str(data["truthfulness"]) not in ["true", "partial", "false"]:
		data["truthfulness"] = "partial"
	if not data.has("surrender_will"):
		data["surrender_will"] = 0.3
	if not data.has("action_hint"):
		data["action_hint"] = "keep_interrogating"
	if not data.has("is_fallback"):
		data["is_fallback"] = false
	return data


## 타입 문자열로 자동 분기 검증
static func validate_by_type(data: Dictionary, type: String) -> Dictionary:
	match type:
		"staff": return validate_staff_advice(data)
		"king": return validate_king_order(data)
		"enemy": return validate_enemy_decision(data)
		"prisoner": return validate_prisoner_response(data)
		_: return data
