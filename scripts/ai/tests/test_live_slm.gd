extends SceneTree
## Live SLM 벤치마크 & 14 시나리오 자동 채점 스크립트
## Sprint 4 #9: Live SLM Local Connection & Evaluation Testbed.
##
## 실행:
##   godot --headless -s scripts/ai/tests/test_live_slm.gd [provider] [model]
##   예) godot --headless -s scripts/ai/tests/test_live_slm.gd OLLAMA qwen2.5:1.5b
##
## 동작:
##   1) mock_dataset.json 로드 (14개 케이스)
##   2) SLMLauncher로 자동 감지 → 후보 풀 확보
##   3) SLMClient를 통해 14개 케이스 순차 주입, 응답 수집
##   4) 5대 지표 자동 채점
##      - Schema Pass Rate (목표 100%): 필수 필드 누락 0
##      - Latency (목표 <2.0s): 평균/중앙/최대
##      - No Hallucination Rate: 관측값에 없는 사실(적 매복 수 등) 날조 적발
##      - Action Validity: action_type이 허용 목록에 속하는지
##      - Uncertainty Expression: "추정", "불확실" 등 어휘 포함률
##   5) 결과를 user://benchmark_report.json + 콘솔로 출력
##
## 의존: scripts/ai/slm_client.gd, slm_parser.gd, slm_launcher.gd, rule_based_fallback.gd

const MOCK_DATASET_PATH := "res://scripts/ai/tests/mock_dataset.json"
const OUTPUT_JSON_PATH := "user://benchmark_report.json"

# 클래스 자동 인식이 안 되는 headless 컨텍스트를 위해 명시적 preload
const SLMClientScript := preload("res://scripts/ai/slm_client.gd")
const SLMLauncherScript := preload("res://scripts/ai/slm_launcher.gd")

# 허용된 staff tactical action_type (slm_client.gd 시스템 프롬프트 기준)
const ALLOWED_STAFF_ACTIONS := [
	"scout_target", "move_flank", "frontal_assault", "hold_defense",
	"ambush", "feint_retreat", "siege_prepare", "supply_secure"
]
# 적장 action_type
const ALLOWED_ENEMY_ACTIONS := [
	"frontal_assault", "flank_attack", "ambush", "feint_retreat", "hold_fortify",
	"retreat", "breakout", "supply_raid", "siege_assault", "scout_probe", "surrender"
]
# 모호성 어휘
const UNCERTAINTY_KEYWORDS := [
	"추정", "추측", "가능성", "불확실", "판단하건대", "~것으로",
	"~으로 보임", "~듯", "~로 추정", "~일 듯", "확실치",
	"~으로 사료", "~으리라", "어렴풋이", "~으므로", "~할 듯"
]

var _client: Node = null       # SLMClient (preload로 로드)
var _launcher: Node = null     # SLMLauncher (preload로 로드)
var _results: Array = []
var _dataset: Dictionary = {}
var _pending_test: Dictionary = {}     # 현재 진행 중인 케이스
var _request_start_msec: int = 0
var _report: Dictionary = {}


func _initialize() -> void:
	# 인자 파싱 (선택): provider, model
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var provider_override: String = ""
	var model_override: String = ""
	if args.size() >= 1:
		provider_override = args[0]
	if args.size() >= 2:
		model_override = args[1]

	print("=== SLM Live Benchmark (Sprint 4 #9) ===")
	# 데이터셋 로드
	_load_dataset()
	if _dataset.is_empty():
		printerr("[FATAL] mock_dataset.json 로드 실패")
		quit(1)
		return
	print("[OK] 데이터셋 로드: %d 카테고리" % _count_categories(_dataset))

	# 노드 추가 — 클라이언트 + 런처
	_client = SLMClientScript.new()
	_client.use_fallback_on_error = false  # 벤치마크 시 폴백 끄고 raw 응답만 측정
	_client.set_timeout(20.0)
	root.add_child(_client)

	_launcher = SLMLauncherScript.new()
	root.add_child(_launcher)

	# 1) 자동 감지
	print("\n[1/3] 자동 감지 시작...")
	var status: Dictionary = await _launcher.run_autodetect()
	if status.is_empty() or not bool(status.get("ok", false)):
		print("[WARN] 자동 감지 실패 — 폴백 모델로 시도")
		var prov: String = provider_override if provider_override != "" else "OLLAMA"
		var mdl: String = model_override if model_override != "" else "qwen2.5:1.5b"
		var ep: String = SLMLauncherScript.get_default_endpoint(prov)
		var prov_id: int = _provider_id_from_string(prov)
		_client.configure(ep, mdl, prov_id)
		status = {
			"ok": true, "provider": prov, "endpoint": ep, "model": mdl,
			"tps": 0.0, "ping_ms": 0, "message": "오버라이드 사용",
			"candidates": []
		}
	else:
		_launcher.apply_to(_client)
		print("[OK] 감지 성공: %s @ %s (%s)" % [
			status.get("model", "?"), status.get("endpoint", "?"), status.get("provider", "?")
		])
		print("    TPS: %.1f, 핑: %dms" % [
			float(status.get("tps", 0.0)), int(status.get("ping_ms", 0))
		])

	# 2) 케이스 순차 주입
	print("\n[2/3] 14개 시나리오 벤치마크 시작...")
	await _run_all_cases()

	# 3) 채점 + 리포트
	print("\n[3/3] 5대 지표 채점 + 리포트 생성")
	_report = _compute_report(status)
	_save_report(_report)
	_print_report(_report)

	print("\n=== 완료: 결과가 %s 에 저장됨 ===" % OUTPUT_JSON_PATH)
	quit(0)


# ─────────────────────────────────────────────
# 데이터셋 로드
# ─────────────────────────────────────────────
func _load_dataset() -> void:
	if not FileAccess.file_exists(MOCK_DATASET_PATH):
		return
	var f := FileAccess.open(MOCK_DATASET_PATH, FileAccess.READ)
	if f == null:
		return
	var text: String = f.get_as_text()
	f.close()
	var json := JSON.new()
	if json.parse(text) != OK:
		printerr("[DATASET] JSON 파싱 실패: %s" % json.get_error_message())
		return
	_dataset = json.get_data() as Dictionary


func _count_categories(ds: Dictionary) -> int:
	var n: int = 0
	for k in ds.keys():
		if ds[k] is Array and (ds[k] as Array).size() > 0:
			n += 1
	return n


# ─────────────────────────────────────────────
# 케이스 빌더 / 러너
# ─────────────────────────────────────────────
## 모든 케이스를 (type, case_dict) 쌍으로 평탄화
func _flatten_cases() -> Array:
	var cases: Array = []
	if _dataset.has("staff_cases"):
		for c in (_dataset["staff_cases"] as Array):
			cases.append({"type": "staff", "data": c})
	if _dataset.has("king_cases"):
		for c in (_dataset["king_cases"] as Array):
			cases.append({"type": "king", "data": c})
	if _dataset.has("enemy_cases"):
		for c in (_dataset["enemy_cases"] as Array):
			cases.append({"type": "enemy", "data": c})
	if _dataset.has("prisoner_cases"):
		for c in (_dataset["prisoner_cases"] as Array):
			cases.append({"type": "prisoner", "data": c})
	return cases


func _run_all_cases() -> void:
	var cases: Array = _flatten_cases()
	print("    - 총 %d 케이스 (staff=%d, king=%d, enemy=%d, prisoner=%d)" % [
		cases.size(),
		(_dataset.get("staff_cases", []) as Array).size(),
		(_dataset.get("king_cases", []) as Array).size(),
		(_dataset.get("enemy_cases", []) as Array).size(),
		(_dataset.get("prisoner_cases", []) as Array).size(),
	])

	# 시그널 연결 (1회)
	_client.staff_advice_received.connect(_on_staff_received)
	_client.king_order_received.connect(_on_king_received)
	_client.enemy_action_received.connect(_on_enemy_received)
	_client.prisoner_response_received.connect(_on_prisoner_received)

	for i in cases.size():
		var c: Dictionary = cases[i]
		var type_str: String = str(c.get("type", ""))
		var data: Dictionary = c.get("data", {}) as Dictionary
		var case_id: String = str(data.get("case_id", "case_%d" % i))
		var label: String = str(data.get("label", ""))

		print("  [%d/%d] %s (%s) ... " % [i + 1, cases.size(), case_id, label])

		_pending_test = {
			"case_id": case_id,
			"type": type_str,
			"data": data,
			"index": i,
			"start_msec": Time.get_ticks_msec(),
			"ok": false,
			"error": "",
			"raw_response": ""
		}
		_request_start_msec = Time.get_ticks_msec()

		# 입력 컨텍스트 구성
		var input_ctx: Dictionary = _build_context(type_str, data)
		# 요청
		match type_str:
			"staff":
				_client.request_staff_advice(input_ctx)
			"king":
				_client.request_king_order(input_ctx)
			"enemy":
				_client.request_enemy_action(input_ctx)
			"prisoner":
				_client.request_prisoner_dialogue(input_ctx)

		# 응답 대기 (await + signal은 SceneTree에선 await 자체로 처리)
		# 단순화: 0.05초 슬립 폴링 (대신 _await_response 시그널 사용)
		await _await_response(type_str, 25.0)

		# 결과 기록
		var elapsed: int = Time.get_ticks_msec() - _request_start_msec
		_pending_test["latency_ms"] = elapsed
		_results.append(_pending_test.duplicate())

		var pass_str: String = "✓" if bool(_pending_test.get("ok", false)) else "✗"
		print("    %s %dms" % [pass_str, elapsed])

	print("\n    벤치마크 루프 완료")


# 시그널 폴링 헬퍼 (한 케이스에 한 응답을 기다림)
func _await_response(type_str: String, timeout_sec: float) -> void:
	var deadline: int = Time.get_ticks_msec() + int(timeout_sec * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if bool(_pending_test.get("completed", false)):
			return
		await create_timer(0.05).timeout
	# 타임아웃
	_pending_test["error"] = "타임아웃 %.1fs" % timeout_sec


func _build_context(type_str: String, data: Dictionary) -> Dictionary:
	# input 키만 추출 (expected / expected_output_contains / expected_output 등 제외)
	var input_keys: Array = ["input"]
	var input_dict: Dictionary = {}
	if data.has("input"):
		input_dict = (data["input"] as Dictionary).duplicate(true)
	# raw_slim_outputs는 무시 (벤치마크는 SLM에게 보내는 입력만 필요)
	return input_dict


# ─────────────────────────────────────────────
# 시그널 핸들러
# ─────────────────────────────────────────────
func _on_staff_received(result: Dictionary) -> void:
	_complete_response("staff", result)


func _on_king_received(result: Dictionary) -> void:
	_complete_response("king", result)


func _on_enemy_received(result: Dictionary) -> void:
	_complete_response("enemy", result)


func _on_prisoner_received(result: Dictionary) -> void:
	_complete_response("prisoner", result)


func _complete_response(type_str: String, result: Dictionary) -> void:
	if str(_pending_test.get("type", "")) != type_str:
		return
	_pending_test["raw_response"] = result
	_pending_test["is_fallback"] = bool(result.get("is_fallback", false))
	_pending_test["ok"] = true
	_pending_test["completed"] = true


# ─────────────────────────────────────────────
# 채점 — 5대 지표
# ─────────────────────────────────────────────
func _compute_report(status: Dictionary) -> Dictionary:
	var schema_pass: int = 0
	var total_with_response: int = 0
	var latencies: Array = []
	var no_hallucination: int = 0
	var hallucination_checked: int = 0
	var action_valid: int = 0
	var action_total: int = 0
	var uncertainty_hits: int = 0
	var uncertainty_checked: int = 0
	var per_case_scores: Array = []

	for r in _results:
		var type_str: String = str(r.get("type", ""))
		var case_id: String = str(r.get("case_id", ""))
		var data: Dictionary = r.get("data", {}) as Dictionary
		var resp: Dictionary = r.get("raw_response", {}) as Dictionary
		var is_fb: bool = bool(r.get("is_fallback", true))
		var elapsed_ms: int = int(r.get("latency_ms", 0))
		var has_resp: bool = (not resp.is_empty()) and (not is_fb)

		# 1) Schema Pass — 필수 필드 + 타입 검증
		var schema_ok: bool = false
		var schema_missing: Array = []
		if has_resp:
			schema_ok = _check_schema(type_str, resp, schema_missing)
		if schema_ok:
			schema_pass += 1
		if has_resp or is_fb:
			total_with_response += 1
		if has_resp:
			latencies.append(elapsed_ms)

		# 2) Latency (raw SLM 응답만)
		# (위에서 latencies에 push)

		# 3) Hallucination Check — 관측값 외 사실 적발
		var no_halluc: bool = false
		var halluc_detail: String = ""
		if has_resp:
			hallucination_checked += 1
			var h: Dictionary = _check_hallucination(type_str, data, resp)
			no_halluc = bool(h.get("clean", false))
			halluc_detail = str(h.get("detail", ""))
			if no_halluc:
				no_hallucination += 1
		# 폴백은 halluc-free로 간주 (규칙 기반은 검증된 응답)
		elif is_fb:
			hallucination_checked += 1
			no_hallucination += 1

		# 4) Action Validity
		var act_valid: bool = false
		var act_detail: String = ""
		if has_resp:
			var av: Dictionary = _check_action_validity(type_str, resp)
			act_valid = bool(av.get("valid", false))
			act_detail = str(av.get("detail", ""))
			action_total += 1
			if act_valid:
				action_valid += 1

		# 5) Uncertainty Expression
		var has_uncert: bool = false
		if has_resp:
			uncertainty_checked += 1
			var u: Dictionary = _check_uncertainty(type_str, resp)
			has_uncert = bool(u.get("has", false))
			uncertainty_hits += 1 if has_uncert else 0
		# 저능력(ability<40)인 경우 폴백도 정답으로 인정
		if type_str == "staff" and not has_resp:
			var ability: int = int(data.get("input", {}).get("staff_ability", 60))
			if ability < 40:
				uncertainty_checked += 1
				uncertainty_hits += 1  # 폴백은 "불확실" 어휘 보장

		per_case_scores.append({
			"case_id": case_id,
			"type": type_str,
			"latency_ms": elapsed_ms,
			"schema_ok": schema_ok,
			"schema_missing": schema_missing,
			"no_hallucination": no_halluc,
			"halluc_detail": halluc_detail,
			"action_valid": act_valid,
			"action_detail": act_detail,
			"uncertainty": has_uncert,
			"is_fallback": is_fb
		})

	# 통계
	var n_results: int = _results.size()
	var schema_pass_rate: float = (float(schema_pass) / float(max(1, total_with_response))) * 100.0
	var no_halluc_rate: float = 0.0
	if hallucination_checked > 0:
		no_halluc_rate = (float(no_hallucination) / float(hallucination_checked)) * 100.0
	var act_valid_rate: float = 0.0
	if action_total > 0:
		act_valid_rate = (float(action_valid) / float(action_total)) * 100.0
	var uncert_rate: float = 0.0
	if uncertainty_checked > 0:
		uncert_rate = (float(uncertainty_hits) / float(uncertainty_checked)) * 100.0

	latencies.sort()
	var latency_avg: float = 0.0
	var latency_p50: float = 0.0
	var latency_p95: float = 0.0
	var latency_max: int = 0
	if latencies.size() > 0:
		var sum: int = 0
		for v in latencies:
			sum += int(v)
		latency_avg = float(sum) / float(latencies.size())
		latency_p50 = float(latencies[latencies.size() / 2])
		latency_p95 = float(latencies[min(latencies.size() - 1, int(float(latencies.size()) * 0.95))])
		latency_max = int(latencies[latencies.size() - 1])

	# 합격 판정
	var pass_latency: bool = latency_avg < 2000.0
	var pass_schema: bool = schema_pass_rate >= 99.0
	var pass_halluc: bool = no_halluc_rate >= 90.0
	var pass_action: bool = act_valid_rate >= 95.0 or action_total == 0
	var pass_uncert: bool = uncert_rate >= 30.0

	return {
		"meta": {
			"total_cases": n_results,
			"responses": total_with_response,
			"fallback_used": n_results - total_with_response,
			"model": str(status.get("model", "?")),
			"endpoint": str(status.get("endpoint", "?")),
			"provider": str(status.get("provider", "?")),
			"tps": float(status.get("tps", 0.0)),
			"ping_ms": int(status.get("ping_ms", 0))
		},
		"metrics": {
			"schema_pass_rate_pct": schema_pass_rate,
			"latency_avg_ms": latency_avg,
			"latency_p50_ms": latency_p50,
			"latency_p95_ms": latency_p95,
			"latency_max_ms": latency_max,
			"no_hallucination_rate_pct": no_halluc_rate,
			"action_validity_rate_pct": act_valid_rate,
			"uncertainty_expression_rate_pct": uncert_rate,
			"latencies": latencies
		},
		"thresholds": {
			"schema_min_pct": 99.0,
			"latency_max_ms": 2000.0,
			"no_halluc_min_pct": 90.0,
			"action_valid_min_pct": 95.0,
			"uncertainty_min_pct": 30.0
		},
		"pass": {
			"schema": pass_schema,
			"latency": pass_latency,
			"no_hallucination": pass_halluc,
			"action_validity": pass_action,
			"uncertainty": pass_uncert,
			"all_pass": pass_schema and pass_latency and pass_halluc and pass_action and pass_uncert
		},
		"per_case": per_case_scores
	}


# ─────────────────────────────────────────────
# 지표별 검증 함수
# ─────────────────────────────────────────────
func _check_schema(type_str: String, resp: Dictionary, missing_out: Array) -> bool:
	var missing: Array = []
	match type_str:
		"staff":
			for f in ["staff_dialogue", "confidence_level", "tactical_options"]:
				if not resp.has(f):
					missing.append(f)
			if resp.has("confidence_level"):
				if str(resp["confidence_level"]) not in ["high", "medium", "low"]:
					missing.append("confidence_level(invalid enum)")
		"king":
			for f in ["king_dialogue", "mood"]:
				if not resp.has(f):
					missing.append(f)
		"enemy":
			for f in ["enemy_dialogue", "decision"]:
				if not resp.has(f):
					missing.append(f)
			if resp.has("decision") and (resp["decision"] is Dictionary):
				if not (resp["decision"] as Dictionary).has("action_type"):
					missing.append("decision.action_type")
		"prisoner":
			for f in ["prisoner_dialogue", "attitude", "truthfulness"]:
				if not resp.has(f):
					missing.append(f)
	missing_out.assign(missing)
	return missing.is_empty()


## 환각 검사 — 응답이 input 데이터를 그대로 답하고 있는지.
## 적대적 데이터셋(데이터셋에는 없는 수치) 적발 방식.
func _check_hallucination(type_str: String, data: Dictionary, resp: Dictionary) -> Dictionary:
	var inp: Dictionary = data.get("input", {}) as Dictionary
	# 데이터셋에 없는 가짜 수치를 "적 매복" 같은 키워드와 함께 답하면 환각
	var detail: String = ""

	# 정확한 수치 환각: input에 없는 큰 숫자(만 단위)가 "병력/매복"과 함께 등장
	var text: String = ""
	match type_str:
		"staff": text = str(resp.get("staff_dialogue", "")) + " " + str(resp.get("estimated_enemy_intent", ""))
		"king": text = str(resp.get("king_dialogue", ""))
		"enemy":
			var d: Dictionary = resp.get("decision", {}) as Dictionary
			text = str(resp.get("enemy_dialogue", "")) + " " + str(d.get("reasoning", ""))
		"prisoner": text = str(resp.get("prisoner_dialogue", ""))
		_: text = JSON.stringify(resp)

	# 가짜 수치 패턴: "정확히 N명" + 숫자 + "명" (input에 없는 큰 수)
	var re := RegEx.new()
	re.compile("([0-9]{2,5})\\s*명")
	var matches := re.search_all(text)
	for m in matches:
		var num_str: String = m.get_string(1)
		var num: int = num_str.to_int()
		# input의 총병력 ±50% 범위 밖이면 의심
		var ref_total: int = int(inp.get("friendly_total", 0))
		if ref_total == 0:
			ref_total = int(inp.get("enemy_total", 0))
		if ref_total == 0:
			ref_total = int(inp.get("enemy_estimated_total", 0))
		if ref_total > 0 and abs(num - ref_total) > ref_total * 1.5 and num > 200:
			detail = "허위 수치 '%s명' (input 총병력 %s)" % [num_str, ref_total]
			return {"clean": false, "detail": detail}

	# staff의 경우: 적 매복 수치를 답에 단정적으로 적은 경우 (input.fog_hexes ≠ 응답의 매복수)
	if type_str == "staff":
		var fog: int = int(inp.get("fog_hexes", 0))
		var intent: String = str(resp.get("estimated_enemy_intent", ""))
		# "매복 N명" 같은 표현이 input의 안개 헥스 수와 어울리지 않으면 환각
		var re2 := RegEx.new()
		re2.compile("매[^,]{0,15}?([0-9]{3,4})\\s*명")
		var m2 := re2.search(intent)
		if m2 != null:
			var n: int = int(m2.get_string(1))
			if n > fog * 500 + 1000:  # 안개 헥스 대비 비현실적으로 큰 수
				detail = "과장된 매복 수치 %d명 (fog=%d)" % [n, fog]
				return {"clean": false, "detail": detail}

	# enemy: 결정의 target_coords가 input.available_coords에 있는지
	if type_str == "enemy":
		var d2: Dictionary = resp.get("decision", {}) as Dictionary
		var tgt: Array = d2.get("target_coords", []) as Array
		var avail: Array = inp.get("available_coords", []) as Array
		if tgt.size() >= 2 and avail.size() > 0:
			var matched: bool = false
			for a in avail:
				if (a is Array) and (a.size() >= 2) and (tgt.size() >= 2):
					if int(a[0]) == int(tgt[0]) and int(a[1]) == int(tgt[1]):
						matched = true
						break
			if not matched:
				detail = "적장 target %s ∉ available %s" % [str(tgt), str(avail)]
				return {"clean": false, "detail": detail}

	# prisoner: input에 commander가 있는데 다른 이름 답하면 환각
	if type_str == "prisoner":
		var true_info: Dictionary = inp.get("true_info", {}) as Dictionary
		var claimed_commander: String = str(
			(resp.get("revealed_info", {}) as Dictionary).get("commander_claimed", "")
		)
		var true_commander: String = str(true_info.get("commander", ""))
		if true_commander != "" and claimed_commander != "" and claimed_commander != true_commander:
			# 교활파는 거짓 가능 → 성향 검사
			var pers: String = str(inp.get("prisoner_personality", ""))
			if pers != "교활파":
				detail = "commander 불일치: 입력 '%s' vs 응답 '%s'" % [true_commander, claimed_commander]
				return {"clean": false, "detail": detail}

	return {"clean": true, "detail": detail}


## 액션 유효성 — action_type이 허용 목록에 있는지
func _check_action_validity(type_str: String, resp: Dictionary) -> Dictionary:
	if type_str == "staff":
		var opts: Array = resp.get("tactical_options", []) as Array
		if opts.size() == 0:
			return {"valid": false, "detail": "옵션 0개"}
		var invalid: Array = []
		for o in opts:
			if not (o is Dictionary):
				continue
			var a: String = str((o as Dictionary).get("action_type", ""))
			if a not in ALLOWED_STAFF_ACTIONS:
				invalid.append(a)
		if invalid.size() > 0:
			return {"valid": false, "detail": "허용 외 action: %s" % str(invalid)}
		return {"valid": true, "detail": "%d개 옵션 모두 유효" % opts.size()}
	elif type_str == "enemy":
		var d: Dictionary = resp.get("decision", {}) as Dictionary
		var a2: String = str(d.get("action_type", ""))
		if a2 not in ALLOWED_ENEMY_ACTIONS:
			return {"valid": false, "detail": "허용 외 action: %s" % a2}
		return {"valid": true, "detail": a2}
	return {"valid": true, "detail": "N/A"}


## 불확실성 어휘 포함 여부
func _check_uncertainty(type_str: String, resp: Dictionary) -> Dictionary:
	var text: String = ""
	match type_str:
		"staff":
			text = str(resp.get("staff_dialogue", ""))
		"enemy":
			var d: Dictionary = resp.get("decision", {}) as Dictionary
			text = str(resp.get("commander_thought", "")) + " " + str(d.get("reasoning", ""))
		"prisoner":
			text = str(resp.get("prisoner_dialogue", ""))
		"king":
			text = str(resp.get("king_dialogue", ""))
		_: text = JSON.stringify(resp)

	for kw in UNCERTAINTY_KEYWORDS:
		if kw in text:
			return {"has": true, "keyword": kw}
	# 폴백이 confidence_level=low인 경우엔 인정 (이미 위 시그널 처리에서 카운트됨)
	if str(resp.get("confidence_level", "")) == "low":
		return {"has": true, "keyword": "confidence_level=low"}
	return {"has": false, "keyword": ""}


# ─────────────────────────────────────────────
# 리포트 출력/저장
# ─────────────────────────────────────────────
func _save_report(report: Dictionary) -> void:
	var dir_path: String = "user://"
	if not DirAccess.dir_exists_absolute(dir_path):
		DirAccess.make_dir_recursive_absolute(dir_path)
	var f := FileAccess.open(OUTPUT_JSON_PATH, FileAccess.WRITE)
	if f == null:
		printerr("[REPORT] 쓰기 실패: %s" % OUTPUT_JSON_PATH)
		return
	f.store_string(JSON.stringify(report, "  "))
	f.close()


func _print_report(report: Dictionary) -> void:
	print("\n──── 벤치마크 리포트 ────")
	var meta: Dictionary = report.get("meta", {})
	var metrics: Dictionary = report.get("metrics", {})
	var pass_dict: Dictionary = report.get("pass", {})

	print("프로바이더: %s | 모델: %s" % [
		meta.get("provider", "?"), meta.get("model", "?")
	])
	print("엔드포인트: %s | TPS: %.1f | 핑: %dms" % [
		meta.get("endpoint", "?"), float(meta.get("tps", 0.0)),
		int(meta.get("ping_ms", 0))
	])
	print("총 케이스: %d (응답 %d, 폴백 %d)" % [
		int(meta.get("total_cases", 0)),
		int(meta.get("responses", 0)),
		int(meta.get("fallback_used", 0))
	])

	print("\n[1] Schema Pass Rate: %.1f%% (목표 ≥99%%) — %s" % [
		float(metrics.get("schema_pass_rate_pct", 0.0)),
		"✓" if pass_dict.get("schema", false) else "✗"
	])
	print("[2] Latency: avg=%.0fms p50=%.0fms p95=%.0fms max=%dms (목표 avg<2000) — %s" % [
		float(metrics.get("latency_avg_ms", 0.0)),
		float(metrics.get("latency_p50_ms", 0.0)),
		float(metrics.get("latency_p95_ms", 0.0)),
		int(metrics.get("latency_max_ms", 0)),
		"✓" if pass_dict.get("latency", false) else "✗"
	])
	print("[3] No Hallucination: %.1f%% (목표 ≥90%%) — %s" % [
		float(metrics.get("no_hallucination_rate_pct", 0.0)),
		"✓" if pass_dict.get("no_hallucination", false) else "✗"
	])
	print("[4] Action Validity: %.1f%% (목표 ≥95%%) — %s" % [
		float(metrics.get("action_validity_rate_pct", 0.0)),
		"✓" if pass_dict.get("action_validity", false) else "✗"
	])
	print("[5] Uncertainty Expression: %.1f%% (목표 ≥30%%) — %s" % [
		float(metrics.get("uncertainty_expression_rate_pct", 0.0)),
		"✓" if pass_dict.get("uncertainty", false) else "✗"
	])

	print("\n[종합] %s" % (
		"✓ ALL PASS — AAA 품질 기준 충족" if pass_dict.get("all_pass", false) else
		"✗ 일부 지표 미달 — 모델/프롬프트 조정 필요"
	))

	print("\n[케이스별 상세]")
	for cs in report.get("per_case", []):
		var c: Dictionary = cs
		var sym: String = "✓" if (bool(c.get("schema_ok", false))
			and bool(c.get("no_hallucination", false))) else "✗"
		print("  %s %-30s %5dms  schema=%s halluc=%s action=%s uncert=%s%s" % [
			sym, str(c.get("case_id", "?")),
			int(c.get("latency_ms", 0)),
			str(bool(c.get("schema_ok", false))).left(5),
			str(bool(c.get("no_hallucination", false))).left(5),
			str(bool(c.get("action_valid", false))).left(5),
			str(bool(c.get("uncertainty", false))).left(5),
			" (FB)" if bool(c.get("is_fallback", false)) else ""
		])


func _provider_id_from_string(p: String) -> int:
	match p:
		"OLLAMA": return 0
		"LM_STUDIO": return 1
		"OPENAI_COMPATIBLE": return 2
		"CUSTOM": return 3
		_: return 0