extends Node
class_name SLMLauncher
## SLM Launcher — 자동 감지 + 추천 모델 풀 + TPS 헬스체커.
## Sprint 4 #9: Live SLM Local Connection & Evaluation Testbed.
##
## 책임:
##   1) Ollama (http://localhost:11434) / LM Studio (http://localhost:1234) 자동 감지
##   2) 추천 모델 풀(qwen2.5/llama3.2/mistral 1~3B 우선순위) 자동 선택
##   3) 헬스체크 — 연결성, 모델 가용성, 초당 토큰 속도(TPS)
##   4) 발견된 첫 번째 정상 엔드포인트를 SLMClient에 적용
##
## 사용법:
##   var launcher := SLMLauncher.new()
##   add_child(launcher)
##   var status: Dictionary = await launcher.run_autodetect()
##   # status = { provider, endpoint, model, tps, ping_ms, ok, message, candidates }
##   launcher.apply_to(client)  # SLMClient 인스턴스에 적용
##
## 모든 HTTP 호출은 비동기. 실패 시 ok=false + message로 사유 반환.
## 폴백 체인을 보장하기 위해 detect_all_providers()는 양쪽을 모두 시도.

# ─────────────────────────────────────────────
# 상수 — 추천 모델 풀
# ─────────────────────────────────────────────

## Ollama 권장 풀 (우선순위 순). 권장 1~3B → 고성능 폴백.
const OLLAMA_RECOMMENDED: Array[String] = [
	"qwen2.5:1.5b",      # 1순위 — 1.5B, JSON/한국어 양호
	"qwen2.5:3b",        # 2순위 — 3B, 정확도 향상
	"llama3.2:1b",       # 3순위 — 1B, 경량 폴백
	"llama3.2:3b",       # 4순위 — 3B, 인스트럭션 강함
	"mistral:7b",        # 5순위 — 고성능 PC
	"qwen2:1.5b",        # 구세대 호환
	"gemma2:2b",         # 대안
]

const LM_STUDIO_DEFAULT_MODEL: String = "qwen2.5-3b-instruct"

const OLLAMA_DEFAULT_ENDPOINT: String = "http://localhost:11434"
const LM_STUDIO_DEFAULT_ENDPOINT: String = "http://localhost:1234"

# ─────────────────────────────────────────────
# 시그널
# ─────────────────────────────────────────────
signal detection_started()
signal detection_finished(status: Dictionary)        # 최종 status dict
signal health_check_completed(result: Dictionary)   # 단일 후보 점검 결과
signal model_pulled(model: String, ok: bool)

# ─────────────────────────────────────────────
# 상태
# ─────────────────────────────────────────────
var http: HTTPRequest = null
var timeout_sec: float = 6.0
var debug_log: bool = false

# 후보 풀 (감지 후 채워짐)
var candidates: Array[Dictionary] = []
# 마지막 최종 결과
var last_status: Dictionary = {}

# 비동기 await 헬퍼용 시그널 캐시
var _pending_result: Dictionary = {}
var _awaiting: bool = false


# ─────────────────────────────────────────────
# 라이프사이클
# ─────────────────────────────────────────────
func _ready() -> void:
	http = HTTPRequest.new()
	http.timeout = int(timeout_sec)
	add_child(http)


func set_timeout(sec: float) -> void:
	timeout_sec = maxf(2.0, sec)
	if http != null:
		http.timeout = int(timeout_sec)


# ─────────────────────────────────────────────
# 메인 진입: 자동 감지 → 후보 풀 구성 → TPS 헬스체크 → 최적 후보 반환
# ─────────────────────────────────────────────
## 비동기. 양쪽 프로바이더(Ollama + LM Studio) 자동 감지, 모델 풀 점검, TPS 측정.
## 반환: { provider, endpoint, model, tps, ping_ms, ok, message, candidates }
func run_autodetect() -> Dictionary:
	detection_started.emit()
	candidates.clear()
	last_status = {}

	# 1) Ollama 감지
	var ollama_models: Array[String] = []
	var ollama_ok: bool = await _probe_provider(
		OLLAMA_DEFAULT_ENDPOINT, "/api/tags", ollama_models
	)
	if ollama_ok:
		# 풀 가용 모델로 우선순위 풀 구성
		var pool: Array[String] = []
		for m in OLLAMA_RECOMMENDED:
			if m in ollama_models:
				pool.append(m)
		# 풀에 없으면 가용 첫 모델 사용 (사용자 정의 모델)
		if pool.is_empty() and ollama_models.size() > 0:
			pool.append(ollama_models[0])
		for m in pool:
			var cand: Dictionary = await _health_check_ollama(OLLAMA_DEFAULT_ENDPOINT, m)
			candidates.append(cand)

	# 2) LM Studio 감지
	var lms_models: Array[String] = []
	var lms_ok: bool = await _probe_provider(
		LM_STUDIO_DEFAULT_ENDPOINT, "/v1/models", lms_models
	)
	if lms_ok:
		# LM Studio는 모델 풀 점검 (최대 3개)
		var pool_lms: Array[String] = []
		for m in lms_models:
			if pool_lms.size() >= 3:
				break
			pool_lms.append(m)
		if pool_lms.is_empty():
			pool_lms.append(LM_STUDIO_DEFAULT_MODEL)
		for m in pool_lms:
			var cand2: Dictionary = await _health_check_lm_studio(LM_STUDIO_DEFAULT_ENDPOINT, m)
			candidates.append(cand2)

	# 3) 최적 후보 선택 — ok=true 중 TPS 가장 높은 것
	var best: Dictionary = _pick_best(candidates)
	last_status = best
	detection_finished.emit(last_status)
	return last_status


## SLMClient 인스턴스에 감지 결과를 적용 (헬퍼)
func apply_to(client: Node, fallback_endpoint: String = "", fallback_model: String = "") -> bool:
	if client == null:
		return false
	var status: Dictionary = last_status
	if not status.get("ok", false):
		# 실패 시 명시적 폴백 사용
		if fallback_endpoint == "":
			return false
		var prov: int = _provider_id_from_string("OLLAMA")
		client.configure(fallback_endpoint, fallback_model, prov)
		return true
	var prov2: int = _provider_id_from_string(str(status.get("provider", "OLLAMA")))
	client.configure(
		str(status.get("endpoint", OLLAMA_DEFAULT_ENDPOINT)),
		str(status.get("model", "qwen2.5:1.5b")),
		prov2
	)
	return true


# ─────────────────────────────────────────────
# 프로바이더 프로빙 — 단순 GET으로 존재 여부 확인
# ─────────────────────────────────────────────
## endpoint 베이스 + 경로로 GET 시도. 가용 모델 목록도 채워줌.
func _probe_provider(endpoint: String, path: String, out_models: Array) -> bool:
	out_models.clear()
	var url: String = "%s%s" % [endpoint, path]
	var headers: PackedStringArray = PackedStringArray(["Accept: application/json"])
	var err: int = http.request(url, headers, HTTPClient.METHOD_GET)
	if err != OK:
		if debug_log:
			print("[SLMLauncher] 프로빙 실패(시작): %s err=%d" % [url, err])
		return false

	# 응답 대기
	var res: Array = await http.request_completed
	if res.size() < 3:
		return false
	var result: int = res[0]
	var code: int = res[1]
	var body: PackedByteArray = res[3]
	if result != HTTPRequest.RESULT_SUCCESS:
		return false
	if code < 200 or code >= 300:
		return false

	# 모델 목록 파싱 시도
	var body_text: String = body.get_string_from_utf8()
	var json := JSON.new()
	if json.parse(body_text) != OK:
		return true  # 연결은 됐지만 포맷 미상 — 일단 true
	var data = json.get_data()
	if data is Dictionary:
		var d: Dictionary = data
		# Ollama /api/tags → {"models":[{"name":"qwen2.5:1.5b"},...]}
		if d.has("models") and d["models"] is Array:
			for m in (d["models"] as Array):
				if m is Dictionary and (m as Dictionary).has("name"):
					out_models.append(str((m as Dictionary)["name"]))
			return true
		# OpenAI 호환 /v1/models → {"data":[{"id":"qwen2.5-3b"},...]}
		if d.has("data") and d["data"] is Array:
			for m in (d["data"] as Array):
				if m is Dictionary:
					var mid: String = str((m as Dictionary).get("id", ""))
					if mid != "":
						out_models.append(mid)
			return true
	return true


# ─────────────────────────────────────────────
# 헬스체크 — Ollama: 작은 chat 호출로 TPS 측정
# ─────────────────────────────────────────────
func _health_check_ollama(endpoint: String, model: String) -> Dictionary:
	var start_msec: int = Time.get_ticks_msec()
	var url: String = "%s/api/chat" % endpoint
	var headers: PackedStringArray = PackedStringArray(["Content-Type: application/json"])
	var body: Dictionary = {
		"model": model,
		"messages": [
			{"role": "system", "content": "JSON만 답하라."},
			{"role": "user", "content": "{\"ping\":\"ok\"} 그대로 출력하라."}
		],
		"stream": false,
		"options": {"temperature": 0.0, "num_predict": 32}
	}
	var body_json: String = JSON.stringify(body)
	var err: int = http.request(url, headers, HTTPClient.METHOD_POST, body_json)
	if err != OK:
		return _mk_candidate("OLLAMA", endpoint, model, false, "요청 시작 실패 %d" % err, 0.0, 0)
	var res: Array = await http.request_completed
	var elapsed: int = Time.get_ticks_msec() - start_msec
	if res.size() < 3:
		return _mk_candidate("OLLAMA", endpoint, model, false, "응답 형식 오류", 0.0, elapsed)
	var result: int = res[0]
	var code: int = res[1]
	var body_bytes: PackedByteArray = res[3]
	if result != HTTPRequest.RESULT_SUCCESS or code < 200 or code >= 300:
		var msg: String = "HTTP result=%d code=%d" % [result, code]
		if code == 404:
			msg += " (모델 미설치 — `ollama pull %s` 권장)" % model
		return _mk_candidate("OLLAMA", endpoint, model, false, msg, 0.0, elapsed)

	var text: String = body_bytes.get_string_from_utf8()
	var json := JSON.new()
	if json.parse(text) != OK:
		return _mk_candidate("OLLAMA", endpoint, model, false, "JSON 파싱 실패", 0.0, elapsed)
	var data = json.get_data()
	if not (data is Dictionary):
		return _mk_candidate("OLLAMA", endpoint, model, false, "응답이 dict 아님", 0.0, elapsed)
	var d: Dictionary = data
	# Ollama는 eval_count / eval_duration (나노초) 제공
	var tokens: int = int(d.get("eval_count", 0))
	var ns: int = int(d.get("eval_duration", 0))
	var tps: float = 0.0
	if ns > 0 and tokens > 0:
		tps = float(tokens) / (float(ns) / 1_000_000_000.0)
	var ok: bool = tps > 0.0 or elapsed < 5000  # TPS 0이어도 응답이 빨라야 OK
	var cand: Dictionary = _mk_candidate("OLLAMA", endpoint, model, ok, "", tps, elapsed)
	cand["available"] = bool(d.get("done", false))
	health_check_completed.emit(cand)
	return cand


# ─────────────────────────────────────────────
# 헬스체크 — LM Studio: OpenAI 호환 chat/completions 호출
# ─────────────────────────────────────────────
func _health_check_lm_studio(endpoint: String, model: String) -> Dictionary:
	var start_msec: int = Time.get_ticks_msec()
	var url: String = "%s/v1/chat/completions" % endpoint
	var headers: PackedStringArray = PackedStringArray(["Content-Type: application/json"])
	var body: Dictionary = {
		"model": model,
		"messages": [
			{"role": "system", "content": "JSON만 답하라."},
			{"role": "user", "content": "{\"ping\":\"ok\"} 그대로 출력하라."}
		],
		"temperature": 0.0,
		"max_tokens": 16
	}
	var body_json: String = JSON.stringify(body)
	var err: int = http.request(url, headers, HTTPClient.METHOD_POST, body_json)
	if err != OK:
		return _mk_candidate("LM_STUDIO", endpoint, model, false, "요청 시작 실패 %d" % err, 0.0, 0)
	var res: Array = await http.request_completed
	var elapsed: int = Time.get_ticks_msec() - start_msec
	if res.size() < 3:
		return _mk_candidate("LM_STUDIO", endpoint, model, false, "응답 형식 오류", 0.0, elapsed)
	var result: int = res[0]
	var code: int = res[1]
	var body_bytes: PackedByteArray = res[3]
	if result != HTTPRequest.RESULT_SUCCESS or code < 200 or code >= 300:
		return _mk_candidate("LM_STUDIO", endpoint, model, false,
			"HTTP result=%d code=%d" % [result, code], 0.0, elapsed)

	var text: String = body_bytes.get_string_from_utf8()
	var json := JSON.new()
	if json.parse(text) != OK:
		return _mk_candidate("LM_STUDIO", endpoint, model, false, "JSON 파싱 실패", 0.0, elapsed)
	var data = json.get_data()
	if not (data is Dictionary):
		return _mk_candidate("LM_STUDIO", endpoint, model, false, "응답이 dict 아님", 0.0, elapsed)
	var d: Dictionary = data
	# OpenAI 호환 usage
	var tps: float = 0.0
	if d.has("usage") and d["usage"] is Dictionary:
		var u: Dictionary = d["usage"]
		var comp_tokens: int = int(u.get("completion_tokens", 0))
		# 정확한 TPS는 eval_duration 없음 → 단순화: comp_tokens / (elapsed_sec)
		if elapsed > 0 and comp_tokens > 0:
			tps = float(comp_tokens) / (float(elapsed) / 1000.0)
	var cand: Dictionary = _mk_candidate("LM_STUDIO", endpoint, model, true, "", tps, elapsed)
	health_check_completed.emit(cand)
	return cand


# ─────────────────────────────────────────────
# 후보 평가 / 선택
# ─────────────────────────────────────────────
func _pick_best(cands: Array) -> Dictionary:
	var best: Dictionary = {
		"ok": false, "provider": "NONE", "endpoint": "", "model": "",
		"tps": 0.0, "ping_ms": 0, "message": "사용 가능한 SLM이 없습니다. Ollama 또는 LM Studio를 실행하세요.",
		"candidates": cands
	}
	var best_tps: float = -1.0
	for c in cands:
		if not (c is Dictionary):
			continue
		var cd: Dictionary = c
		if not bool(cd.get("ok", false)):
			continue
		var tps: float = float(cd.get("tps", 0.0))
		if tps > best_tps:
			best_tps = tps
			best = {
				"ok": true,
				"provider": str(cd.get("provider", "OLLAMA")),
				"endpoint": str(cd.get("endpoint", OLLAMA_DEFAULT_ENDPOINT)),
				"model": str(cd.get("model", "qwen2.5:1.5b")),
				"tps": tps,
				"ping_ms": int(cd.get("ping_ms", 0)),
				"message": "성공" if tps > 0.0 else "응답 수신 (TPS 추정 불가)",
				"candidates": cands
			}
	return best


func _mk_candidate(provider: String, endpoint: String, model: String,
		ok: bool, msg: String, tps: float, ping_ms: int) -> Dictionary:
	return {
		"provider": provider,
		"endpoint": endpoint,
		"model": model,
		"ok": ok,
		"tps": tps,
		"ping_ms": ping_ms,
		"message": msg
	}


# SLMClient.Provider enum을 문자열로 매핑.
# client.configure()가 enum을 받지만, 런타임에서 캐스트 안전하게 처리하기 위함.
func _provider_id_from_string(p: String) -> int:
	# SLMClient.Provider: OLLAMA=0, LM_STUDIO=1, OPENAI_COMPATIBLE=2, CUSTOM=3
	match p:
		"OLLAMA": return 0
		"LM_STUDIO": return 1
		"OPENAI_COMPATIBLE": return 2
		"CUSTOM": return 3
		_: return 0


# ─────────────────────────────────────────────
# 모델 풀 헬퍼 (UI에서 사용)
# ─────────────────────────────────────────────
static func get_recommended_pool() -> Array[String]:
	return OLLAMA_RECOMMENDED.duplicate()


static func get_default_endpoint(provider_str: String) -> String:
	match provider_str:
		"OLLAMA": return OLLAMA_DEFAULT_ENDPOINT
		"LM_STUDIO": return LM_STUDIO_DEFAULT_ENDPOINT
		"OPENAI_COMPATIBLE": return "https://api.openai.com"
		_: return OLLAMA_DEFAULT_ENDPOINT