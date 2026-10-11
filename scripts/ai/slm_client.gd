extends Node
class_name SLMClient
## SLM 통신 비동기 클라이언트 (Godot 4 HTTPRequest 기반)
## - Ollama (http://localhost:11434/api/chat)
## - LM Studio / OpenAI 호환 (http://localhost:1234/v1/chat/completions)
## - 클라우드 OpenAI 호환 엔드포인트
## - 네트워크 장애/지연/파싱 실패 시 RuleBasedFallback으로 자동 폴백
##
## 사용법:
##   var client = SLMClient.new()
##   add_child(client)
##   client.configure("http://localhost:11434", "qwen2:7b", SLMClient.Provider.OLLAMA)
##   client.request_staff_advice({"friendly_total": 4200, ...})
##   # 시그널 연결: staff_advice_received(result: Dictionary)
##
## 모든 request_* 메서드는 비동기 — 즉시 반환, 결과는 시그널로 전달.
## 폴백 발생 시에도 동일한 시그널로 결과가 전달되며, result.is_fallback=true로 구분.

# ─────────────────────────────────────────────
# Provider / 상수
# ─────────────────────────────────────────────
enum Provider {
	OLLAMA,              # /api/chat  (messages 기반, stream:false)
	LM_STUDIO,           # /v1/chat/completions (OpenAI 호환)
	OPENAI_COMPATIBLE,   # /v1/chat/completions (OpenAI 호환, api_key 필요)
	CUSTOM               # 사용자가 endpoint 전체를 지정
}

const DEFAULT_TIMEOUT_SEC := 15.0
const DEFAULT_TEMPERATURE := 0.7
const DEFAULT_MAX_TOKENS := 800

# Preloaded helper scripts (class_name may not be resolvable from autoload order at parse time)
var SLMParserCls: Script = preload("res://scripts/ai/slm_parser.gd")
var RuleBasedFallbackCls: Script = preload("res://scripts/ai/rule_based_fallback.gd")

# ─────────────────────────────────────────────
# 시그널
# ─────────────────────────────────────────────
signal staff_advice_received(result: Dictionary)
signal king_order_received(result: Dictionary)
signal enemy_action_received(result: Dictionary)
signal prisoner_response_received(result: Dictionary)
## 범용 완료 시그널 (타입, 폴백 여부)
signal slm_request_completed(type: String, from_fallback: bool)
## 오류 알림 (폴백 사용 여부 포함)
signal slm_error(error_msg: String, fallback_used: bool)

# ─────────────────────────────────────────────
# 상태
# ─────────────────────────────────────────────
var provider: Provider = Provider.OLLAMA
var endpoint: String = "http://localhost:11434"
var model: String = "qwen2:7b"
var api_key: String = ""  # OPENAI_COMPATIBLE에서만 사용
var timeout_sec: float = DEFAULT_TIMEOUT_SEC
var temperature: float = DEFAULT_TEMPERATURE
var use_fallback_on_error: bool = true
var debug_log: bool = false

# 내부
var _http: HTTPRequest = null
var _pending_type: String = ""       # "staff"|"king"|"enemy"|"prisoner"
var _pending_context: Dictionary = {}
var _request_timer: Timer = null
var _is_requesting: bool = false

# 프롬프트 템플릿 캐시 (파일 로드 실패 시 내장 기본 프롬프트 사용)
var _prompt_cache: Dictionary = {}

# ─────────────────────────────────────────────
# 라이프사이클
# ─────────────────────────────────────────────
func _ready() -> void:
	_http = HTTPRequest.new()
	_http.timeout = int(timeout_sec)  # Godot 4.3+ HTTPRequest.timeout (초)
	add_child(_http)
	_http.request_completed.connect(_on_http_completed)

	_request_timer = Timer.new()
	_request_timer.one_shot = true
	_request_timer.wait_time = timeout_sec
	add_child(_request_timer)
	_request_timer.timeout.connect(_on_timeout)

	# 프롬프트 템플릿 사전 로드 시도 (실패해도 동작 — 하드코딩 폴백)
	_preload_prompt_templates()


func _preload_prompt_templates() -> void:
	var paths: Dictionary = {
		"staff": "res://scripts/ai/prompts/staff_prompt.md",
		"king": "res://scripts/ai/prompts/king_prompt.md",
		"enemy": "res://scripts/ai/prompts/enemy_ai_prompt.md",
		"prisoner": "res://scripts/ai/prompts/prisoner_prompt.md",
	}
	for key in paths:
		var p: String = paths[key]
		if FileAccess.file_exists(p):
			var f := FileAccess.open(p, FileAccess.READ)
			if f != null:
				_prompt_cache[key] = f.get_as_text()
				f.close()
			else:
				push_warning("[SLMClient] 프롬프트 로드 실패: %s" % p)
		else:
			if debug_log:
				print("[SLMClient] 프롬프트 파일 없음 (내장 기본 사용): %s" % p)


# ─────────────────────────────────────────────
# 설정
# ─────────────────────────────────────────────
## endpoint: 베이스 URL (예: "http://localhost:11434" 또는 "https://api.openai.com")
## model: 모델명 (예: "qwen2:7b", "gpt-4o-mini")
func configure(p_endpoint: String, p_model: String, p_provider: Provider = Provider.OLLAMA, p_api_key: String = "") -> void:
	endpoint = p_endpoint.trim_suffix("/")
	model = p_model
	provider = p_provider
	if p_api_key != "":
		api_key = p_api_key
	if debug_log:
		print("[SLMClient] configure: provider=%d endpoint=%s model=%s" % [provider, endpoint, model])


func set_timeout(sec: float) -> void:
	timeout_sec = maxf(3.0, sec)
	if _http != null:
		_http.timeout = int(timeout_sec)
	if _request_timer != null:
		_request_timer.wait_time = timeout_sec


# ─────────────────────────────────────────────
# 공용 요청 진입점
# ─────────────────────────────────────────────
func request_staff_advice(context: Dictionary) -> int:
	return _request("staff", context)

func request_king_order(context: Dictionary) -> int:
	return _request("king", context)

func request_enemy_action(context: Dictionary) -> int:
	return _request("enemy", context)

func request_prisoner_dialogue(context: Dictionary) -> int:
	return _request("prisoner", context)

## 범용 요청 (type: staff|king|enemy|prisoner)
func _request(type: String, context: Dictionary) -> int:
	if _is_requesting:
		push_warning("[SLMClient] 이미 요청 진행 중 — 큐잉 없이 무시: %s" % type)
		# 폴백을 즉시 반환하여 게임 블로킹 방지
		_emit_fallback(type, context, "이전 요청 진행 중")
		return ERR_BUSY

	_pending_type = type
	_pending_context = context.duplicate(true)
	_is_requesting = true

	var system_prompt: String = _build_system_prompt(type, context)
	var user_prompt: String = _build_user_prompt(type, context)

	if debug_log:
		print("[SLMClient] → %s 요청 (model=%s)\n  system: %s\n  user: %s" % [type, model, system_prompt.left(200), user_prompt.left(300)])

	var url: String = _resolve_url()
	var headers: PackedStringArray = PackedStringArray(["Content-Type: application/json"])
	if provider == Provider.OPENAI_COMPATIBLE and api_key != "":
		headers.push_back("Authorization: Bearer %s" % api_key)

	var body: Dictionary = _build_request_body(system_prompt, user_prompt)
	var body_json: String = JSON.stringify(body)

	var err: int = _http.request(url, headers, HTTPClient.METHOD_POST, body_json)
	if err != OK:
		push_warning("[SLMClient] HTTP 요청 시작 실패: %d (%s)" % [err, url])
		_is_requesting = false
		_emit_fallback(type, context, "HTTP 요청 시작 실패: %d" % err)
		return err

	_request_timer.start()
	return OK


func _resolve_url() -> String:
	match provider:
		Provider.OLLAMA:
			return "%s/api/chat" % endpoint
		Provider.LM_STUDIO, Provider.OPENAI_COMPATIBLE:
			return "%s/v1/chat/completions" % endpoint
		Provider.CUSTOM:
			return endpoint  # 전체 URL을 그대로 사용
		_:
			return "%s/api/chat" % endpoint


func _build_request_body(system_prompt: String, user_prompt: String) -> Dictionary:
	match provider:
		Provider.OLLAMA:
			return {
				"model": model,
				"messages": [
					{"role": "system", "content": system_prompt},
					{"role": "user", "content": user_prompt}
				],
				"stream": false,
				"options": {
					"temperature": temperature,
					"num_predict": DEFAULT_MAX_TOKENS
				}
			}
		Provider.LM_STUDIO, Provider.OPENAI_COMPATIBLE, Provider.CUSTOM:
			return {
				"model": model,
				"messages": [
					{"role": "system", "content": system_prompt},
					{"role": "user", "content": user_prompt}
				],
				"temperature": temperature,
				"max_tokens": DEFAULT_MAX_TOKENS
			}
		_:
			return {
				"model": model,
				"messages": [
					{"role": "system", "content": system_prompt},
					{"role": "user", "content": user_prompt}
				],
				"stream": false
			}


# ─────────────────────────────────────────────
# 프롬프트 빌더
# ─────────────────────────────────────────────
func _build_system_prompt(type: String, ctx: Dictionary) -> String:
	match type:
		"staff":
			var name: String = str(ctx.get("staff_name", "참모"))
			var courtesy: String = str(ctx.get("staff_courtesy", ""))
			var pers: String = str(ctx.get("staff_personality", "균형파"))
			var abil: int = int(ctx.get("staff_ability", 60))
			return _render_staff_system(name, courtesy, pers, abil)
		"king":
			var kname: String = str(ctx.get("king_name", "주상"))
			var temple: String = str(ctx.get("king_temple", ""))
			var pers: String = str(ctx.get("king_personality", "현명파"))
			return _render_king_system(kname, temple, pers)
		"enemy":
			var ename: String = str(ctx.get("enemy_commander_name", "적장"))
			var epers: String = str(ctx.get("enemy_personality", "냉정형"))
			var eabil: int = int(ctx.get("enemy_ability", 60))
			var sname: String = str(ctx.get("enemy_staff_name", "적 참모"))
			var salive: String = "생존" if bool(ctx.get("enemy_staff_alive", true)) else "전사"
			var sabil: int = int(ctx.get("enemy_staff_ability", 50))
			return _render_enemy_system(ename, epers, eabil, sname, salive, sabil)
		"prisoner":
			var pname: String = str(ctx.get("prisoner_name", "포로"))
			var prank: String = str(ctx.get("prisoner_rank", "장수"))
			var ppers: String = str(ctx.get("prisoner_personality", "현실파"))
			var loyal: int = int(ctx.get("loyalty", 60))
			var days: int = int(ctx.get("days_captive", 1))
			var treat: String = str(ctx.get("treatment", "보통"))
			var style: String = str(ctx.get("interrogation_style", "persuade"))
			return _render_prisoner_system(pname, prank, ppers, loyal, days, treat, style)
		_:
			return "당신은 오대십국시대 전략 게임의 AI다. 반드시 순수 JSON 하나로만 답하라."

func _build_user_prompt(type: String, ctx: Dictionary) -> String:
	match type:
		"staff": return _render_staff_user(ctx)
		"king": return _render_king_user(ctx)
		"enemy": return _render_enemy_user(ctx)
		"prisoner": return _render_prisoner_user(ctx)
		_: return JSON.stringify(ctx)


# ── Staff 프롬프트 렌더러 ──
func _render_staff_system(staff_name: String, courtesy: String, personality: String, ability: int) -> String:
	return """당신은 오대십국 시대의 참모 %s%s다. 성향은 %s, 능력 %d/100이다.
주공을 "주공"이라 호칭하며 고풍 어조로 말한다.
[핵심 원칙] 정보는 불확실하다. 추정/예측 표현("추정하건대", "가능성이 높다")을 반드시 포함하고, 능력치가 낮을수록 자신 없음을 드러낸다.
[출력 규칙] 오직 JSON 하나로만 답한다. 마크다운/코드블록 금지.
스키마: {"staff_dialogue": string(80-180자), "confidence_level": "high"|"medium"|"low", "staff_personality": "%s", "tactical_options": [{"id": "option_*", "title": string, "risk": "low"|"medium"|"high", "action_type": "scout_target"|"move_flank"|"frontal_assault"|"hold_defense"|"ambush"|"feint_retreat"|"siege_prepare"|"supply_secure", "target_coords": [q,r]}], "estimated_enemy_intent": string, "is_fallback": false}
tactical_options는 정확히 3개, action_type은 허용 목록에서만.""" % [staff_name, " (%s)" % courtesy if courtesy != "" else "", personality, ability, personality]

func _render_staff_user(ctx: Dictionary) -> String:
	var avail_str: String = JSON.stringify(ctx.get("available_coords", [[4,7],[6,3],[5,5]]))
	return """[전황 요약 — 턴 %s / %s]
- 아군 총병력: %s명 (보병 %s / 궁병 %s / 기병 %s / 창병 %s / 정찰 %s)
- 추정 적 총병력: %s명 (정확도 %s%%)
- 아군 평균 사기: %s / 보급: %s일
- 지형: %s
- 안개: %s헥스, 정찰병 %s명 가용
- 특이: %s
- 가용 좌표: %s
위 정보를 바탕으로 3가지 전술 선택지를 JSON으로 답하라.""" % [
		str(ctx.get("turn", 1)), str(ctx.get("phase", "RECON")),
		str(ctx.get("friendly_total", 3000)), str(ctx.get("infantry_cnt", "-")), str(ctx.get("archer_cnt", "-")), str(ctx.get("cavalry_cnt", "-")), str(ctx.get("spearmen_cnt", "-")), str(ctx.get("scout_available", 1)),
		str(ctx.get("enemy_estimated_total", 3000)), str(ctx.get("enemy_est_accuracy", 60)),
		str(ctx.get("friendly_morale_avg", 60)), str(ctx.get("supply_days", 14)),
		str(ctx.get("terrain_summary", "평야 40%, 숲 20%")),
		str(ctx.get("fog_hexes", 6)), str(ctx.get("scout_available", 1)),
		str(ctx.get("battlefield_notes", "특이 없음")),
		avail_str
	]

# ── King 프롬프트 렌더러 ──
func _render_king_system(king_name: String, temple: String, personality: String) -> String:
	return """당신은 오대십국 군주 %s%s다. 성향 %s.
"짐이 명하노니" 어조로 위엄 있게 말한다.
모드: 임무 하달(mission) / 성과 평가(evaluation) / 돌발 명령(sudden_order).
출력은 순수 JSON 하나만. 스키마: {"king_dialogue": string, "mood": "pleased"|"neutral"|"angered"|"furious", "king_personality": "%s", "mission": {"id": string, "title": string, "objective": string, "target_coords": [q,r], "turn_limit": int, "reward_hint": string, "failure_consequence": string}, "evaluation": {"score": 0-100, "result": "대성공"|"성공"|"보통"|"실패"|"참패", "reward_or_punishment": string, "fame_delta": int}, "sudden_order": {"order_type": "retreat"|"rush_attack"|"hold_position"|"replace_officer"|"secure_supply"|"none", "content": string, "urgency": string}, "is_fallback": false}
mood/personality는 입력 성향에 맞게.""" % [king_name, " (%s)" % temple if temple != "" else "", personality, personality]

func _render_king_user(ctx: Dictionary) -> String:
	return """[군주 컨텍스트] 군주: %s (%s), 신뢰 %s/100, 턴 %s/%s
모드: %s
아군 %s명 보급 %s일 사기 %s
적 추정 %s명
최근 전투: %s
임무 진행: %s
돌발 촉발: %s
위 정보로 군주 어명을 JSON으로 답하라.""" % [
		str(ctx.get("king_name", "주상")), str(ctx.get("king_personality", "현명파")), str(ctx.get("king_trust", 60)), str(ctx.get("turn", 1)), str(ctx.get("phase", "RECON")),
		str(ctx.get("request_mode", "mixed")),
		str(ctx.get("friendly_total", 3000)), str(ctx.get("supply_days", 14)), str(ctx.get("morale_avg", 60)),
		str(ctx.get("enemy_est_total", 3000)),
		str(ctx.get("recent_battle_summary", "교전 없음")),
		str(ctx.get("mission_progress", "진행 중")),
		str(ctx.get("trigger_for_sudden_order", "없음"))
	]

# ── Enemy 프롬프트 렌더러 ──
func _render_enemy_system(ename: String, epers: String, eabil: int, sname: String, salive: String, sabil: int) -> String:
	return """당신은 적군 지휘관 %s (성향 %s, 능력 %d)다. 참모 %s(%s, 능력 %d).
성향: 맹장=정면돌파, 지장=매복/기만, 수성=농성, 교활=보급로기습, 냉정=손익계산 후퇴.
참모 사망 시 통제력 붕괴(무작위성 증가). 보급 5일 미만이면 후퇴/보급로 확보 우선. 포위 시 탈출/항복.
출력 순수 JSON 하나만. 스키마: {"enemy_dialogue": string, "commander_thought": string, "decision": {"action_type": "frontal_assault"|"flank_attack"|"ambush"|"feint_retreat"|"hold_fortify"|"retreat"|"breakout"|"supply_raid"|"siege_assault"|"scout_probe"|"surrender", "target_coords": [q,r], "aggression": 0.0-1.0, "risk": "low"|"medium"|"high", "reasoning": string}, "unit_orders": [{"unit_id": string, "order": string, "target": [q,r]}], "staff_control_modifier": 0.0-1.0, "is_fallback": false}""" % [ename, epers, eabil, sname, salive, sabil]

func _render_enemy_user(ctx: Dictionary) -> String:
	var avail_str: String = JSON.stringify(ctx.get("available_coords", [[5,8],[6,6],[3,2]]))
	return """[적군 상황] 지휘관 %s(%s) 사기 %s, 참모 %s(생사 %s) 통제력 %s, 총병력 %s명, 추정 아군 %s명(정확도 %s%%), 보급 %s일, 포위 %s, 지형 %s, 턴 %s/%s, 특이 %s, 가용좌표 %s, 이전행동 %s → JSON으로 다음 행동을 결정하라.""" % [
		str(ctx.get("enemy_commander_name", "적장")), str(ctx.get("enemy_personality", "냉정형")), str(ctx.get("enemy_morale", 55)), str(ctx.get("enemy_staff_name", "참모")), str(ctx.get("enemy_staff_alive", true)), str(ctx.get("staff_control", 0.85)), str(ctx.get("enemy_total", 4000)), str(ctx.get("friendly_est_total", 3500)), str(ctx.get("friendly_est_accuracy", 60)), str(ctx.get("enemy_supply_days", 10)), str(ctx.get("encircled", false)), str(ctx.get("terrain_summary", "평야")), str(ctx.get("turn", 1)), str(ctx.get("phase", "ENGAGE")), str(ctx.get("battlefield_notes", "특이 없음")), avail_str, str(ctx.get("prev_enemy_action", "없음"))
	]

# ── Prisoner 프롬프트 렌더러 ──
func _render_prisoner_system(pname: String, prank: String, ppers: String, loyal: int, days: int, treat: String, style: String) -> String:
	return """당신은 포로 %s(%s, 성향 %s, 충성 %d, %d일째, 처우 %s)다. 심문 방식: %s.
성향: 충의=투항거부/거짓정보, 현실=조건충족시전향, 교활=거짓투항, 겁약=위협에굴복, 원한=복수위해전향.
truthfulness는 "true"|"partial"|"false"로 엔진 검증용.
출력 순수 JSON 하나만. 스키마: {"prisoner_dialogue": string, "attitude": "defiant"|"evasive"|"cooperative"|"deceptive"|"broken"|"conditional", "truthfulness": "true"|"partial"|"false", "wants": string, "revealed_info": {"enemy_total_claimed": int, "supply_days_claimed": float, "commander_claimed": string, "extra_claim": string}, "surrender_will": 0.0-1.0, "action_hint": "keep_interrogating"|"offer_terms"|"execute_risk"|"release"|"recruit"|"deceive_detected", "is_fallback": false}""" % [pname, prank, ppers, loyal, days, treat, style]

func _render_prisoner_user(ctx: Dictionary) -> String:
	return """[포로] %s(%s, %s, 충성 %s, 능력 %s) %s일째, 처우 %s, 건강 %s, 심문방식 %s, 심문자 %s, 질문: "%s", 진실: %s, 회유조건: %s → JSON으로 답하라.""" % [
		str(ctx.get("prisoner_name", "포로")), str(ctx.get("prisoner_rank", "장수")), str(ctx.get("prisoner_personality", "현실파")), str(ctx.get("loyalty", 60)), str(ctx.get("ability", 60)), str(ctx.get("days_captive", 1)), str(ctx.get("treatment", "보통")), str(ctx.get("health", 80)), str(ctx.get("interrogation_style", "persuade")), str(ctx.get("interrogator_name", "장군")), str(ctx.get("question", "적 본진의 허실을 말하라")), JSON.stringify(ctx.get("true_info", {})), str(ctx.get("offer_made", "없음"))
	]

# ─────────────────────────────────────────────
# HTTP 콜백
# ─────────────────────────────────────────────
func _on_http_completed(result: int, response_code: int, headers: PackedStringArray, body: PackedByteArray) -> void:
	_request_timer.stop()
	if not _is_requesting:
		return  # 이미 타임아웃 폴백 처리됨
	_is_requesting = false

	var type: String = _pending_type
	var ctx: Dictionary = _pending_context

	if result != HTTPRequest.RESULT_SUCCESS:
		var msg: String = "HTTP 실패 result=%d code=%d" % [result, response_code]
		push_warning("[SLMClient] %s" % msg)
		_emit_fallback(type, ctx, msg)
		return
	if response_code < 200 or response_code >= 300:
		var msg2: String = "HTTP 오류 code=%d body=%s" % [response_code, body.get_string_from_utf8().left(400)]
		push_warning("[SLMClient] %s" % msg2)
		_emit_fallback(type, ctx, msg2)
		return

	var body_text: String = body.get_string_from_utf8()
	if debug_log:
		print("[SLMClient] 원시 응답 (%s): %s" % [type, body_text.left(600)])

	var content_text: String = _extract_content_text(body_text)
	if content_text.strip_edges() == "":
		push_warning("[SLMClient] 응답에서 content 추출 실패: %s" % body_text.left(400))
		_emit_fallback(type, ctx, "content 추출 실패")
		return

	var parsed: Dictionary = SLMParserCls.extract_json(content_text)
	if parsed.is_empty():
		push_warning("[SLMClient] SLM JSON 파싱 실패 — 폴백 사용. 원문: %s" % content_text.left(500))
		_emit_fallback(type, ctx, "JSON 파싱 실패")
		return

	# 스키마 검증
	var validated: Dictionary = SLMParserCls.validate_by_type(parsed, type)
	if validated.is_empty():
		push_warning("[SLMClient] 스키마 검증 실패 — 폴백 사용. 파싱: %s" % str(parsed).left(400))
		_emit_fallback(type, ctx, "스키마 검증 실패")
		return

	# 성공 — validated에 is_fallback=false 보장
	validated["is_fallback"] = false
	_emit_success(type, validated)


func _extract_content_text(body_text: String) -> String:
	var json := JSON.new()
	if json.parse(body_text) != OK:
		# JSON이 아니면 그대로 반환 (일부 SLM이 텍스트만 보냄)
		return body_text

	var data = json.get_data()
	if data is Dictionary:
		var d: Dictionary = data as Dictionary
		# Ollama: {"message": {"content": "..."}}
		if d.has("message") and d["message"] is Dictionary and (d["message"] as Dictionary).has("content"):
			return str((d["message"] as Dictionary)["content"])
		# OpenAI 호환: {"choices": [{"message": {"content": "..."}}]}
		if d.has("choices") and d["choices"] is Array and (d["choices"] as Array).size() > 0:
			var first = (d["choices"] as Array)[0]
			if first is Dictionary and (first as Dictionary).has("message"):
				var msg = (first as Dictionary)["message"]
				if msg is Dictionary and (msg as Dictionary).has("content"):
					return str((msg as Dictionary)["content"])
			# 일부 변형: {"choices": [{"text": "..."}]}
			if first is Dictionary and (first as Dictionary).has("text"):
				return str((first as Dictionary)["text"])
		# Ollama generate: {"response": "..."}
		if d.has("response"):
			return str(d["response"])
		# content 키 직접
		if d.has("content"):
			return str(d["content"])
		# 전체가 이미 SLM JSON이면 그대로 stringify 후 반환 (직접 게임 JSON을 보낸 경우)
		# 예: {"staff_dialogue": "..."} 자체 — 이 경우 body_text를 그대로 content로 간주
		if d.has("staff_dialogue") or d.has("king_dialogue") or d.has("enemy_dialogue") or d.has("prisoner_dialogue"):
			return body_text
		# 알 수 없는 래퍼 — body_text 전체를 content로 시도
		return body_text
	return body_text


func _on_timeout() -> void:
	if not _is_requesting:
		return
	_is_requesting = false
	_http.cancel_request()
	var type: String = _pending_type
	var ctx: Dictionary = _pending_context
	push_warning("[SLMClient] 타임아웃(%.0f초) — 폴백 사용: %s" % [timeout_sec, type])
	_emit_fallback(type, ctx, "타임아웃 %.0f초" % timeout_sec)


# ─────────────────────────────────────────────
# 결과 방출
# ─────────────────────────────────────────────
func _emit_success(type: String, result: Dictionary) -> void:
	match type:
		"staff": staff_advice_received.emit(result)
		"king": king_order_received.emit(result)
		"enemy": enemy_action_received.emit(result)
		"prisoner": prisoner_response_received.emit(result)
	slm_request_completed.emit(type, false)
	if debug_log:
		print("[SLMClient] ✓ %s 성공 (SLM)" % type)


func _emit_fallback(type: String, ctx: Dictionary, reason: String) -> void:
	if not use_fallback_on_error:
		slm_error.emit(reason, false)
		slm_request_completed.emit(type, false)
		return

	var fallback_result: Dictionary = {}
	match type:
		"staff": fallback_result = RuleBasedFallbackCls.get_staff_advice(ctx)
		"king": fallback_result = RuleBasedFallbackCls.get_king_order(ctx)
		"enemy": fallback_result = RuleBasedFallbackCls.get_enemy_decision(ctx)
		"prisoner": fallback_result = RuleBasedFallbackCls.get_prisoner_response(ctx)
		_: fallback_result = {"error": reason, "is_fallback": true}

	slm_error.emit(reason, true)

	match type:
		"staff": staff_advice_received.emit(fallback_result)
		"king": king_order_received.emit(fallback_result)
		"enemy": enemy_action_received.emit(fallback_result)
		"prisoner": prisoner_response_received.emit(fallback_result)

	slm_request_completed.emit(type, true)
	if debug_log:
		print("[SLMClient] ⚠ %s 폴백 사용 (사유: %s)" % [type, reason])

# ─────────────────────────────────────────────
# 동기 폴백 헬퍼 — HTTP 없이 즉시 폴백 결과를 받고 싶을 때
# 테스트/오프라인 전용. 실제 게임은 request_* (비동기) 사용.
# ─────────────────────────────────────────────
static func get_fallback_staff_advice(ctx: Dictionary) -> Dictionary:
	return (load("res://scripts/ai/rule_based_fallback.gd") as Script).get_staff_advice(ctx)

static func get_fallback_king_order(ctx: Dictionary) -> Dictionary:
	return (load("res://scripts/ai/rule_based_fallback.gd") as Script).get_king_order(ctx)

static func get_fallback_enemy_decision(ctx: Dictionary) -> Dictionary:
	return (load("res://scripts/ai/rule_based_fallback.gd") as Script).get_enemy_decision(ctx)

static func get_fallback_prisoner_response(ctx: Dictionary) -> Dictionary:
	return (load("res://scripts/ai/rule_based_fallback.gd") as Script).get_prisoner_response(ctx)

# ─────────────────────────────────────────────
# 유틸: 연결 가능 여부 체크 (health_check)
# ─────────────────────────────────────────────
## 간단한 GET으로 엔드포인트 생존 확인. 결과는 health_checked 시그널로.
signal health_checked(ok: bool, message: String)
var _health_http: HTTPRequest = null

func health_check() -> void:
	if _health_http == null:
		_health_http = HTTPRequest.new()
		add_child(_health_http)
		_health_http.request_completed.connect(_on_health_completed)
	var url: String = ""
	match provider:
		Provider.OLLAMA: url = "%s/api/tags" % endpoint
		Provider.LM_STUDIO, Provider.OPENAI_COMPATIBLE: url = "%s/v1/models" % endpoint
		Provider.CUSTOM: url = endpoint
	var headers: PackedStringArray = PackedStringArray()
	if provider == Provider.OPENAI_COMPATIBLE and api_key != "":
		headers.push_back("Authorization: Bearer %s" % api_key)
	var err: int = _health_http.request(url, headers, HTTPClient.METHOD_GET)
	if err != OK:
		health_checked.emit(false, "요청 시작 실패: %d" % err)

func _on_health_completed(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS:
		health_checked.emit(false, "연결 실패 result=%d" % result)
		return
	if code >= 200 and code < 300:
		health_checked.emit(true, "연결 성공 (%d) %s" % [code, body.get_string_from_utf8().left(200)])
	else:
		health_checked.emit(false, "HTTP %d %s" % [code, body.get_string_from_utf8().left(200)])
