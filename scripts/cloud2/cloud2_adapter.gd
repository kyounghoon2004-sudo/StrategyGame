class_name Cloud2Adapter
extends Node

## CLOUD-GENERAL STEP 2 — Provider-neutral Cloud model boundary.
##
## The ONLY file that touches the network for Step 2. Owns one HTTPRequest,
## two wire shapes (OpenAI-compatible chat-completions, Anthropic messages),
## timeout/offline/HTTP errors, and raw-result normalization with timing.
##
## Owns NOTHING about battles: no packets, no prompts, no parsing of the
## tactical contract, no game state, no execution. Untrusted model text is
## returned verbatim for Cloud2Response to validate; never executed here.
##
## Secrets: the API key travels only in the Authorization header of the
## outbound request. It is never logged, never stored in results, and never
## placed in previews. See Cloud2Config for key lifecycle.
##
## Result Dictionary (emitted via turn_finished / test_finished):
##   ok=true:  {ok, request_id, http_status, content_text, latency_ms,
##              provider, model, transport, finish_reason, envelope}
##   ok=false: {ok:false, request_id, code, detail, http_status, latency_ms,
##              provider, model, envelope}
## `envelope` is SAFE response metadata (sizes, finish_reason, field
## presence — never key material, never chain-of-thought text).
## Transport codes: OFFLINE, TIMEOUT, UNAUTHORIZED, RATE_LIMITED,
## MODEL_MISSING, HTTP_ERROR, PROVIDER_ERROR, NOT_CONFIGURED.
## Response-envelope codes (2xx body problems, each precise):
## RESPONSE_TOO_LARGE, NON_JSON_ENVELOPE, STREAMING_RESPONSE_DETECTED,
## EMPTY_MODEL_CONTENT, REASONING_BUDGET_EXHAUSTED, FINISH_LENGTH_NO_FINAL,
## MODEL_REFUSAL, TOOL_CALLS_NO_TEXT, UNSUPPORTED_RESPONSE_SHAPE.
##
## Mock mode (fixture testing without network): set mock_mode=true and push
## fixture results into mock_queue. Requests pop one fixture each and emit
## it deferred. Default off; live play never enables it.

signal turn_finished(request_id: String, result: Dictionary)
signal test_finished(result: Dictionary)
signal chat_finished(request_id: String, result: Dictionary)
signal models_fetched(result: Dictionary)

const ConfigCls = preload("res://scripts/cloud2/cloud2_config.gd")
const OpenCodeCls = preload("res://scripts/cloud2/cloud2_opencode.gd")
const SessionCls = preload("res://scripts/cloud2/cloud2_session.gd")
const EpisodeRuntimeCls = preload("res://scripts/episodes/episode_runtime.gd")

const BODY_SIZE_LIMIT := 2097152 # 2 MiB: model JSON must stay far below this.
## Tactical output budget. Rationale: reasoning-capable OpenCode models
## spend output tokens in reasoning_content BEFORE final content; the old
## 2048 budget proved too small live (HTTP 200, empty content, reasoning
## present). The final tactical JSON needs ~1-2K tokens, so 4096 leaves
## headroom for reasoning overhead plus the decision without inviting
## essays. One bounded retry may use TURN_RETRY_MAX_TOKENS. OpenCode
## exposes no per-model cap in discovery metadata, so this fixed policy
## applies to every model; the minimal body sends only max_tokens (a field
## the gateway accepts), never speculative extras.
const TURN_MAX_TOKENS := 4096
## Single automatic-retry budget for output-exhaustion failures only.
const TURN_RETRY_MAX_TOKENS := 8192
const TURN_TEMPERATURE := 0.2
const CHAT_MAX_TOKENS := 1024
const CHAT_TEMPERATURE := 0.7
const MODELS_TIMEOUT := 15.0
## Minimal connection probe: proves auth + model access + routing with the
## smallest valid per-protocol body. No system prompt, no JSON mode, no
## temperature/stream extras — those belong to turns, never to the probe.
const PROBE_TEXT := "Reply with OK."
const PROBE_MAX_TOKENS := 16
const EXCHANGE_BODY_CHARS := 4000
const ERROR_BODY_CHARS := 2000

var _http: HTTPRequest = null
var _http_models: HTTPRequest = null
var _active_request_id := ""
var _active_t0_msec := 0
var _active_provider := ""
var _active_model := ""
var _active_transport := ""
var _active_is_test := false
var _active_is_chat := false
var _models_t0_msec := 0
## Sanitized record of the last HTTP exchange (method/endpoint/protocol/
## model/status + truncated bodies with any key material redacted).
## Never auto-logged; exposed for DEV UI via last_exchange().
var _last_exchange := {}
var _active_body_text := ""
## In-flight key copy (memory only, cleared the moment the flight ends) so
## response sanitizing can redact echoed key material. Never logged.
var _active_key := ""
var _models_key := ""
## Gate-resolved wire key for this flight (session key when the session
## healed the config, else the config's own). Set by request_* after the
## session gate; _post consumes it. Never logged.
var _send_key := ""

var mock_mode := false
var mock_queue: Array = []
## Mock body for fetch_models when mock_mode is on (a canned /models JSON).
var mock_models_text := ""


func _ready() -> void:
	_http = HTTPRequest.new()
	_http.name = "Cloud2ChatRequest"
	_http.timeout = 65.0
	_http.body_size_limit = BODY_SIZE_LIMIT
	add_child(_http)
	_http.request_completed.connect(_on_request_completed)
	_http_models = HTTPRequest.new()
	_http_models.name = "Cloud2ModelsRequest"
	_http_models.timeout = MODELS_TIMEOUT
	_http_models.body_size_limit = BODY_SIZE_LIMIT
	add_child(_http_models)
	_http_models.request_completed.connect(_on_models_completed)


## Fire one non-streaming turn request. Single active request bound: when a
## flight is already in flight the newcomer is REJECTED (REQUEST_IN_FLIGHT),
## never silently cancelled (a cancelled flight emits nothing and would
## orphan its waiter). Returns {ok} synchronously; the real outcome always
## arrives via turn_finished.
## max_tokens_override > 0 replaces TURN_MAX_TOKENS for this flight only
## (the controller's single output-exhaustion retry uses it).
## timeout_override > 0 replaces config.timeout_sec for this flight only
## (General planning calls budget longer than tactical turns).
func request_turn(request_id: String, packet: Dictionary, config: ConfigCls, system_prompt: String, max_tokens_override: int = 0, timeout_override: float = 0.0) -> Dictionary:
	var gate := SessionCls.resolve_for_use(config)
	SessionCls.trace("RED_ADAPTER_SEND", null, config)
	if not bool(gate.get("ok", false)):
		return {"ok": false, "code": str(gate.get("code", "CLOUD_NOT_CONFIGURED")),
			"detail": str(gate.get("detail", ""))}
	var clash := _active_clash("turn")
	if not clash.is_empty():
		return clash
	_send_key = str(gate.get("key", ""))
	if mock_mode:
		_active_request_id = request_id
		_active_t0_msec = Time.get_ticks_msec()
		_active_provider = config.provider_id
		_active_model = config.model
		_active_transport = config.effective_transport()
		_active_is_test = false
		_active_is_chat = false
		_record_exchange_request(request_id, config, JSON.stringify(packet).left(EXCHANGE_BODY_CHARS))
		_emit_mock_deferred(request_id, false)
		return {"ok": true, "request_id": request_id, "mock": true}
	if _http == null:
		return {"ok": false, "code": "OFFLINE", "detail": "HTTP node not ready."}
	cancel_active()
	var packet_text := JSON.stringify(packet)
	var messages := [
		{"role": "system", "content": system_prompt},
		{"role": "user", "content": packet_text},
	]
	var budget := TURN_MAX_TOKENS
	if max_tokens_override > 0:
		budget = max_tokens_override
	return _post(request_id, config, messages, budget, TURN_TEMPERATURE, false, true, false, false, timeout_override)


## Minimal protocol-specific probe ("Reply with OK."). Proves auth +
## model access + routing with the smallest valid body for the resolved
## transport. Never touches battle state. Outcome arrives via test_finished.
func test_connection(config: ConfigCls) -> Dictionary:
	if not config.is_configured():
		return {"ok": false, "code": "CLOUD_NOT_CONFIGURED",
			"detail": "Provider, model, endpoint, and API key are required first."}
	if config.is_opencode() and not config.is_protocol_resolved():
		return {"ok": false, "code": "UNSUPPORTED_PROTOCOL",
			"detail": "Model '%s' has an unknown OpenCode Go API protocol." % config.model}
	var clash := _active_clash("connection test")
	if not clash.is_empty():
		return clash
	if mock_mode:
		_active_request_id = "test"
		_active_t0_msec = Time.get_ticks_msec()
		_active_provider = config.provider_id
		_active_model = config.model
		_active_transport = config.effective_transport()
		_active_is_test = true
		_active_is_chat = false
		_record_exchange_request("test", config, JSON.stringify(build_probe_body(config.effective_transport(), config.model)))
		_emit_mock_deferred("test", true)
		return {"ok": true, "request_id": "test", "mock": true}
	if _http == null:
		return {"ok": false, "code": "OFFLINE", "detail": "HTTP node not ready."}
	cancel_active()
	_send_key = "" # a probe always validates the config's own key, never a resolved one
	return _post("test", config, [], 0, 0.0, true, false, false, true)


## Direct developer chat with the selected model. Same adapter, same
## transport, same key — but NEVER wired to battle execution: the outcome
## arrives via chat_finished as plain text and nothing else consumes it.
## opts: {max_tokens, temperature, json_mode}. Requires a tested connection.
func request_chat(request_id: String, config: ConfigCls, messages: Array, opts: Dictionary = {}) -> Dictionary:
	var gate := SessionCls.resolve_for_use(config)
	SessionCls.trace("CHAT_ADAPTER_SEND", null, config)
	if not bool(gate.get("ok", false)):
		return {"ok": false, "code": str(gate.get("code", "CLOUD_NOT_CONFIGURED")),
			"detail": str(gate.get("detail", ""))}
	var clash := _active_clash("chat")
	if not clash.is_empty():
		return clash
	_send_key = str(gate.get("key", ""))
	var max_tokens := int(opts.get("max_tokens", CHAT_MAX_TOKENS))
	var temperature := float(opts.get("temperature", CHAT_TEMPERATURE))
	var json_mode := bool(opts.get("json_mode", false))
	if mock_mode:
		_active_request_id = request_id
		_active_t0_msec = Time.get_ticks_msec()
		_active_provider = config.provider_id
		_active_model = config.model
		_active_transport = config.effective_transport()
		_active_is_test = false
		_active_is_chat = true
		_record_exchange_request(request_id, config, JSON.stringify(messages).left(EXCHANGE_BODY_CHARS))
		_emit_mock_deferred(request_id, false)
		return {"ok": true, "request_id": request_id, "mock": true}
	if _http == null:
		return {"ok": false, "code": "OFFLINE", "detail": "HTTP node not ready."}
	cancel_active()
	return _post(request_id, config, messages, max_tokens, temperature, false, json_mode, true)


## Live model discovery: GET the OpenCode Go /models catalog.
## Outcome arrives via models_fetched: {ok, models: [{id, name}],
## count, code, detail, latency_ms}. Never touches battle state.
func fetch_models(api_key: String) -> Dictionary:
	if api_key.strip_edges().is_empty():
		return {"ok": false, "code": "CLOUD_NOT_CONFIGURED",
			"detail": "Paste the OpenCode Go API key first."}
	if mock_mode:
		_emit_models_mock_deferred()
		return {"ok": true, "mock": true}
	if _http_models == null:
		return {"ok": false, "code": "OFFLINE", "detail": "HTTP node not ready."}
	_http_models.cancel_request()
	_models_t0_msec = Time.get_ticks_msec()
	_models_key = api_key.strip_edges()
	# NOTE: headers bear the secret and are never printed anywhere.
	var err := _http_models.request(OpenCodeCls.MODELS_URL,
		OpenCodeCls.models_headers(api_key), HTTPClient.METHOD_GET)
	if err != OK:
		return {"ok": false, "code": "OFFLINE",
			"detail": "Models request failed to start (err=%d)." % err}
	return {"ok": true}


func _post(request_id: String, config: ConfigCls, messages: Array, max_tokens: int, temperature: float, is_test: bool, json_mode: bool, is_chat: bool = false, probe: bool = false, timeout_override: float = 0.0) -> Dictionary:
	_active_request_id = request_id
	_active_t0_msec = Time.get_ticks_msec()
	_active_provider = config.provider_id
	_active_model = config.model
	_active_transport = config.effective_transport()
	_active_is_test = is_test
	_active_is_chat = is_chat
	var flight_timeout := config.timeout_sec
	if timeout_override > 0.0:
		flight_timeout = timeout_override
	_http.timeout = maxf(5.0, flight_timeout + 5.0)
	var transport := _active_transport
	_active_key = _send_key if not _send_key.is_empty() else config.api_key
	_send_key = ""
	# OpenCode Go speaks minimal bodies (live: extras rejected, probes pass);
	# every other provider keeps its proven wire shape.
	var minimal := config.provider_id == ConfigCls.OPENCODE_ID
	var body := ""
	if probe:
		var probe_body := build_probe_body(transport, config.model)
		if probe_body.is_empty():
			_active_request_id = ""
			_active_key = ""
			return {"ok": false, "code": "PROTOCOL_ERROR",
				"detail": "Model '%s' has an unsupported/unknown API protocol; no request was sent." % config.model}
		body = JSON.stringify(probe_body)
	elif transport == ConfigCls.TRANSPORT_ANTHROPIC:
		body = JSON.stringify(build_anthropic_body(config.model, messages, max_tokens, temperature, minimal))
	elif transport == ConfigCls.TRANSPORT_RESPONSES:
		body = JSON.stringify(OpenCodeCls.build_responses_body(config.model, messages, max_tokens, temperature, json_mode, minimal))
	elif transport == ConfigCls.TRANSPORT_OPENAI:
		body = JSON.stringify(build_openai_body(config.model, messages, max_tokens, temperature, minimal))
	else:
		_active_request_id = ""
		return {"ok": false, "code": "PROTOCOL_ERROR",
			"detail": "Model '%s' has an unsupported/unknown API protocol; no request was sent." % config.model}
	_record_exchange_request(request_id, config, body)
	print("[Cloud2Adapter] POST %s %s model=%s chars=%d lane=%s" % [transport,
		config.endpoint.strip_edges(), config.model, body.length(),
		"test" if is_test else ("chat" if is_chat else "turn")])
	# NOTE: headers (which bear the secret) are never printed anywhere.
	var headers := OpenCodeCls.auth_headers(_active_key, transport)
	# Episode provenance goes ONLY to loopback endpoints (local Brain server);
	# a local spec path is never sent to a remote provider.
	if _is_loopback(config.endpoint):
		headers.append_array(EpisodeRuntimeCls.provenance_headers())
	var err := _http.request(config.endpoint.strip_edges(), headers, HTTPClient.METHOD_POST, body)
	if err != OK:
		_active_request_id = ""
		_active_key = ""
		return {"ok": false, "code": "OFFLINE",
			"detail": "HTTPRequest start failed (err=%d)." % err}
	return {"ok": true, "request_id": request_id}


static func _is_loopback(endpoint: String) -> bool:
	var host := endpoint.strip_edges().trim_prefix("http://").trim_prefix("https://").get_slice("/", 0).get_slice(":", 0)
	return host in ["127.0.0.1", "localhost"]  # IPv6 literal -> not loopback (safe default)


## Sanitized record of the last exchange for DEV UI. Safe to display:
## bodies are truncated and any key material is redacted. {} before use.
func last_exchange() -> Dictionary:
	return _last_exchange.duplicate(true)


func _record_exchange_request(request_id: String, config: ConfigCls, body_text: String) -> void:
	_active_body_text = body_text
	_last_exchange = {
		"request_id": request_id,
		"method": "POST",
		"endpoint": config.endpoint.strip_edges(),
		"protocol": config.effective_transport(),
		"model": config.model,
		"provider": config.provider_id,
		"request_chars": body_text.length(),
		"request_json": sanitize_text(body_text, _active_key, EXCHANGE_BODY_CHARS),
		"http_status": 0,
		"response_chars": 0,
		"response_text": "",
		"latency_ms": 0,
	}


func _record_exchange_response(http_status: int, body_text: String, api_key: String) -> void:
	_last_exchange["http_status"] = http_status
	_last_exchange["response_chars"] = body_text.length()
	_last_exchange["response_text"] = sanitize_text(body_text, api_key, EXCHANGE_BODY_CHARS)
	_last_exchange["latency_ms"] = _latency_ms()


func has_active() -> bool:
	return not _active_request_id.is_empty()


## Overlap guard: one HTTP lane serves turn/test/chat. A newcomer must never
## silently kill an in-flight request — the orphaned lane's waiter would spin
## forever (proven: cancelled flights emit nothing, so no result ever lands).
## Sequential callers always find the lane free; only genuine overlaps reject
## here with a precise code, and every caller already surfaces start-failure.
func _active_clash(lane: String) -> Dictionary:
	if not has_active():
		return {}
	var flying := "turn"
	if _active_is_test:
		flying = "connection test"
	elif _active_is_chat:
		flying = "chat"
	return {"ok": false, "code": "REQUEST_IN_FLIGHT",
		"detail": "A Cloud %s request (%s) is still in flight; this %s was not sent. Wait for it to finish." % [
			flying, _active_request_id, lane]}


func active_request_id() -> String:
	return _active_request_id


## Supersede the in-flight request without emitting (a late response is
## discarded because the id no longer matches).
func cancel_active() -> void:
	if _http != null and has_active():
		_http.cancel_request()
	_active_request_id = ""
	_active_key = ""


func _emit_mock_deferred(request_id: String, is_test: bool) -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	if _active_request_id != request_id:
		return # superseded/cancelled
	var is_chat := _active_is_chat
	var latency := Time.get_ticks_msec() - _active_t0_msec
	_active_request_id = ""
	_active_key = ""
	var fixture: Dictionary = {"ok": true, "content_text": "{\"orders\": []}", "latency_ms": latency}
	if not mock_queue.is_empty():
		var raw: Variant = mock_queue.pop_front()
		if raw is Dictionary:
			fixture = (raw as Dictionary).duplicate(true)
	_record_exchange_response(int(fixture.get("http_status", 200 if bool(fixture.get("ok", false)) else 0)),
		str(fixture.get("content_text", fixture.get("detail", ""))), "")
	if bool(fixture.get("ok", false)):
		var res := {
			"ok": true, "request_id": request_id, "http_status": 200,
			"content_text": str(fixture.get("content_text", "")),
			"latency_ms": int(fixture.get("latency_ms", latency)),
			"provider": _active_provider, "model": _active_model,
			"transport": _active_transport, "finish_reason": "mock",
			"mock": true,
			"envelope": {"mock": true, "finish_reason": "mock",
				"content_chars": str(fixture.get("content_text", "")).length()},
		}
		if is_test:
			test_finished.emit(res)
		elif is_chat:
			chat_finished.emit(request_id, res)
		else:
			turn_finished.emit(request_id, res)
	else:
		# Mock failure mirrors the REAL failure envelope shape: the fixture's
		# safe diagnostic envelope (reasoning_present/reasoning_chars/finish_
		# reason/usage) is passed through so budget-exhaustion fixtures exercise
		# the same trace path as live responses. Mock-only; no network path here.
		var menv: Dictionary = {"mock": true}
		if fixture.get("envelope") is Dictionary:
			var fenv: Dictionary = (fixture.get("envelope") as Dictionary).duplicate(true)
			for mk in fenv.keys():
				menv[str(mk)] = fenv[mk]
			menv["mock"] = true
		var fres := {
			"ok": false, "request_id": request_id,
			"code": str(fixture.get("code", "PROVIDER_ERROR")),
			"detail": str(fixture.get("detail", "Mock failure.")),
			"http_status": int(fixture.get("http_status", 0)),
			"latency_ms": int(fixture.get("latency_ms", latency)),
			"provider": _active_provider, "model": _active_model,
			"mock": true,
			"envelope": menv,
		}
		if is_test:
			test_finished.emit(fres)
		elif is_chat:
			chat_finished.emit(request_id, fres)
		else:
			turn_finished.emit(request_id, fres)


func _emit_models_mock_deferred() -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	if mock_models_text.strip_edges().is_empty():
		models_fetched.emit({"ok": false, "models": [], "count": 0,
			"code": "MOCK_MODELS_EMPTY", "detail": "mock_models_text is empty.",
			"latency_ms": 0, "mock": true})
		return
	var parsed := OpenCodeCls.parse_models_response(mock_models_text)
	parsed["latency_ms"] = 0
	parsed["mock"] = true
	models_fetched.emit(parsed)


func _latency_ms() -> int:
	return Time.get_ticks_msec() - _active_t0_msec


func _finish_fail(request_id: String, is_test: bool, code: String, detail: String, http_status: int, is_chat: bool = false, provider_message: String = "", provider_type: String = "") -> void:
	var res := {
		"ok": false, "request_id": request_id, "code": code,
		"detail": detail, "http_status": http_status,
		"latency_ms": _latency_ms(),
		"provider": _active_provider, "model": _active_model,
		"provider_message": provider_message, "provider_type": provider_type,
	}
	if is_test:
		test_finished.emit(res)
	elif is_chat:
		chat_finished.emit(request_id, res)
	else:
		turn_finished.emit(request_id, res)


func _on_request_completed(godot_result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	var request_id := _active_request_id
	var is_test := _active_is_test
	var is_chat := _active_is_chat
	var transport := _active_transport
	var provider := _active_provider
	var model := _active_model
	var flight_key := _active_key
	_active_request_id = ""
	_active_key = ""
	if request_id.is_empty():
		return # superseded/cancelled: discard silently, never display.
	var latency := Time.get_ticks_msec() - _active_t0_msec
	if godot_result == HTTPRequest.RESULT_TIMEOUT:
		_record_exchange_response(response_code, "", flight_key)
		_active_provider = provider
		_active_model = model
		_active_t0_msec = Time.get_ticks_msec() - latency
		_finish_fail(request_id, is_test, "TIMEOUT", "Provider request timed out.", response_code, is_chat)
		return
	if godot_result != HTTPRequest.RESULT_SUCCESS:
		_record_exchange_response(response_code, "", flight_key)
		_active_provider = provider
		_active_model = model
		_active_t0_msec = Time.get_ticks_msec() - latency
		_finish_fail(request_id, is_test, "OFFLINE", "Provider unreachable (result=%d)." % godot_result, response_code, is_chat)
		return
	var text := body.get_string_from_utf8()
	_record_exchange_response(response_code, text, flight_key)
	print("[Cloud2Adapter] <- HTTP %d %s %dms lane=%s" % [response_code, request_id,
		int(Time.get_ticks_msec() - _active_t0_msec), "test" if is_test else ("chat" if is_chat else "turn")])
	if response_code < 200 or response_code >= 300:
		var info := provider_error_info(response_code, text, flight_key)
		_emit_simple(request_id, is_test, str(info.get("code", "HTTP_ERROR")), str(info.get("detail", "")),
			response_code, latency, provider, model, is_chat,
			str(info.get("provider_message", "")), str(info.get("provider_type", "")))
		return
	# 2xx: typed envelope classification (pure, tested). Every outcome —
	# success or precise failure — carries safe diagnostics in `envelope`.
	var judged := classify_http_body(transport, response_code, text, flight_key)
	var env: Dictionary = (judged.get("envelope", {}) as Dictionary).duplicate(true)
	_last_exchange["response_meta"] = env.duplicate(true)
	if not bool(judged.get("ok", false)):
		_emit_simple(request_id, is_test, str(judged.get("code", "NON_JSON_ENVELOPE")),
			str(judged.get("detail", "")), response_code, latency, provider, model,
			is_chat, "", "", env)
		return
	var res := {
		"ok": true, "request_id": request_id, "http_status": response_code,
		"content_text": str(judged.get("content_text", "")), "latency_ms": latency,
		"provider": provider, "model": model, "transport": transport,
		"finish_reason": str(judged.get("finish_reason", "")),
		"envelope": env,
	}
	if is_test:
		test_finished.emit(res)
	elif is_chat:
		chat_finished.emit(request_id, res)
	else:
		turn_finished.emit(request_id, res)


func _on_models_completed(godot_result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	var latency := Time.get_ticks_msec() - _models_t0_msec
	var flight_key := _models_key
	_models_key = ""
	if godot_result == HTTPRequest.RESULT_TIMEOUT:
		models_fetched.emit({"ok": false, "models": [], "count": 0,
			"code": "TIMEOUT", "detail": "Models request timed out.",
			"http_status": response_code, "latency_ms": latency})
		return
	if godot_result != HTTPRequest.RESULT_SUCCESS:
		models_fetched.emit({"ok": false, "models": [], "count": 0,
			"code": "OFFLINE", "detail": "OpenCode Go unreachable (result=%d)." % godot_result,
			"http_status": response_code, "latency_ms": latency})
		return
	if response_code < 200 or response_code >= 300:
		var info := provider_error_info(response_code, body.get_string_from_utf8(), flight_key)
		models_fetched.emit({"ok": false, "models": [], "count": 0,
			"code": str(info.get("code", "HTTP_ERROR")), "detail": str(info.get("detail", "")),
			"provider_message": str(info.get("provider_message", "")),
			"provider_type": str(info.get("provider_type", "")),
			"http_status": response_code, "latency_ms": latency})
		return
	var parsed := OpenCodeCls.parse_models_response(body.get_string_from_utf8())
	parsed["http_status"] = response_code
	parsed["latency_ms"] = latency
	models_fetched.emit(parsed)


func _emit_simple(request_id: String, is_test: bool, code: String, detail: String, http_status: int, latency: int, provider: String, model: String, is_chat: bool = false, provider_message: String = "", provider_type: String = "", envelope: Dictionary = {}) -> void:
	var res := {
		"ok": false, "request_id": request_id, "code": code,
		"detail": detail, "http_status": http_status, "latency_ms": latency,
		"provider": provider, "model": model,
		"provider_message": provider_message, "provider_type": provider_type,
		"envelope": envelope.duplicate(true),
	}
	if is_test:
		test_finished.emit(res)
	elif is_chat:
		chat_finished.emit(request_id, res)
	else:
		turn_finished.emit(request_id, res)


# --- pure wire-shape builders/extractors (unit-testable, no network) --------

## Map an HTTP status to a deterministic adapter code (pure, tested).
static func classify_status(http_status: int) -> Dictionary:
	if http_status == 401 or http_status == 403:
		return {"code": "UNAUTHORIZED", "detail": "Invalid API key (HTTP %d)." % http_status}
	if http_status == 429:
		return {"code": "RATE_LIMITED", "detail": "Provider rate limit (HTTP 429)."}
	if http_status == 404:
		return {"code": "MODEL_MISSING", "detail": "Endpoint or model not found (HTTP 404)."}
	if http_status == 408:
		return {"code": "TIMEOUT", "detail": "Provider timed out (HTTP 408)."}
	if http_status >= 500:
		return {"code": "PROVIDER_ERROR", "detail": "Provider error (HTTP %d)." % http_status}
	if http_status < 200 or http_status >= 300:
		return {"code": "HTTP_ERROR", "detail": "Provider error (HTTP %d)." % http_status}
	return {"code": "OK", "detail": ""}


## Minimal per-protocol connection probe. Each family gets ONLY its own
## required fields — no temperature, stream, JSON mode, or system prompt.
## Returns {} for an unknown transport (caller must not send).
static func build_probe_body(transport: String, model: String) -> Dictionary:
	if transport == ConfigCls.TRANSPORT_ANTHROPIC:
		return {"model": model, "max_tokens": PROBE_MAX_TOKENS,
			"messages": [{"role": "user", "content": PROBE_TEXT}]}
	if transport == ConfigCls.TRANSPORT_RESPONSES:
		return {"model": model, "max_output_tokens": PROBE_MAX_TOKENS,
			"input": [{"role": "user", "content": PROBE_TEXT}]}
	if transport == ConfigCls.TRANSPORT_OPENAI:
		return {"model": model, "max_tokens": PROBE_MAX_TOKENS,
			"messages": [{"role": "user", "content": PROBE_TEXT}]}
	return {}


## Redact key material and bound length. Safe for UI/DEV display.
static func sanitize_text(text: String, secret: String, limit: int) -> String:
	var t := text
	var s := secret.strip_edges()
	if not s.is_empty() and t.find(s) != -1:
		t = t.replace(s, "***REDACTED***")
	if t.length() > limit:
		t = t.left(limit) + "...(truncated, %d chars total)" % text.length()
	return t


## Body-aware provider error classification (pure, tested). classify_status()
## stays the no-body fallback; this refines using the actual provider body.
## Categories are used ONLY with supporting evidence — a bare 400 without a
## body never becomes INVALID API KEY or any other specific claim.
## Returns {code, detail, provider_message, provider_type, provider_body}.
static func provider_error_info(http_status: int, body_text: String, api_key: String) -> Dictionary:
	var raw := body_text.left(16384)
	var msg := ""
	var etype := ""
	var parsed: Variant = JSON.parse_string(raw)
	if parsed is Dictionary:
		var d: Dictionary = parsed
		var err: Variant = d.get("error", null)
		if err is Dictionary:
			msg = str((err as Dictionary).get("message", ""))
			etype = str((err as Dictionary).get("type", (err as Dictionary).get("code", "")))
		elif err is String:
			msg = str(err)
		if msg.is_empty():
			msg = str(d.get("message", d.get("detail", "")))
		if etype.is_empty():
			etype = str(d.get("type", d.get("code", "")))
	msg = sanitize_text(msg.strip_edges(), api_key, 500)
	etype = sanitize_text(etype.strip_edges(), api_key, 120)
	var clean_body := sanitize_text(raw.strip_edges(), api_key, ERROR_BODY_CHARS)
	var base := classify_status(http_status)
	var code := str(base.get("code", "HTTP_ERROR"))
	var detail := str(base.get("detail", ""))
	if http_status == 400:
		var low := (msg + " " + etype).to_lower()
		var category := "INVALID REQUEST BODY"
		code = "INVALID_REQUEST"
		if low.find("region") != -1 or low.find("geograph") != -1 or low.find("location") != -1 or low.find("country") != -1:
			code = "REGION_RESTRICTED"
			category = "REGION RESTRICTED"
		elif low.find("entitle") != -1 or low.find("forbidden") != -1 or low.find("permission") != -1 \
				or low.find("access denied") != -1 or low.find("not entitled") != -1 \
				or low.find("terms") != -1 or low.find("contributor") != -1:
			code = "MODEL_ACCESS_DENIED"
			category = "MODEL ACCESS DENIED"
		elif low.find("unknown parameter") != -1 or low.find("unsupported") != -1 \
				or low.find("unexpected field") != -1 or low.find("unknown field") != -1 \
				or low.find("invalid field") != -1 or low.find("additional properties") != -1:
			code = "UNSUPPORTED_FIELD"
			category = "UNSUPPORTED FIELD"
		detail = "HTTP 400 %s" % category
		if not msg.is_empty():
			detail += " — %s" % msg
		elif not etype.is_empty():
			detail += " — (%s)" % etype
	elif not msg.is_empty():
		detail += " Provider says: %s" % msg
	return {"code": code, "detail": detail, "provider_message": msg,
		"provider_type": etype, "provider_body": clean_body}


static func build_openai_body(model: String, messages: Array, max_tokens: int, temperature: float, minimal: bool = false) -> Dictionary:
	if minimal:
		# OpenCode Go gateway: live evidence shows extras (temperature /
		# stream / response_format) rejected while minimal probes pass.
		return {"model": model, "messages": messages, "max_tokens": max_tokens}
	return {
		"model": model,
		"messages": messages,
		"max_tokens": max_tokens,
		"temperature": temperature,
		"stream": false,
		"response_format": {"type": "json_object"},
	}


static func build_anthropic_body(model: String, messages: Array, max_tokens: int, temperature: float, minimal: bool = false) -> Dictionary:
	var system_text := ""
	var convo: Array = []
	for m_val in messages:
		if not m_val is Dictionary:
			continue
		var m: Dictionary = m_val
		if str(m.get("role", "")) == "system":
			if system_text.is_empty():
				system_text = str(m.get("content", ""))
			else:
				system_text += "\n" + str(m.get("content", ""))
		else:
			convo.append({"role": "user", "content": str(m.get("content", ""))})
	if minimal:
		# OpenCode Go gateway: extras rejected while minimal probes pass.
		var min_body := {"model": model, "max_tokens": max_tokens, "messages": convo}
		if not system_text.is_empty():
			min_body["system"] = system_text
		return min_body
	var body := {
		"model": model,
		"max_tokens": max_tokens,
		"temperature": temperature,
		"stream": false,
		"messages": convo,
	}
	if not system_text.is_empty():
		body["system"] = system_text
	return body


## Pure 2xx body classifier (unit-testable, no network). Routes the raw
## HTTP body through size check -> JSON parse -> per-transport typed
## extraction. Returns {ok, content_text, finish_reason, code, detail,
## envelope, body_prefix}. envelope is SAFE metadata only.
static func classify_http_body(transport: String, http_status: int, text: String, api_key: String = "") -> Dictionary:
	var base_diag := {"http_status": http_status, "response_chars": text.length()}
	if text.length() > BODY_SIZE_LIMIT:
		base_diag["body_prefix"] = sanitize_text(text.left(300), api_key, 300)
		return {"ok": false, "content_text": "", "finish_reason": "",
			"code": "RESPONSE_TOO_LARGE",
			"detail": "Response (%d chars) exceeds the %d-byte limit." % [text.length(), BODY_SIZE_LIMIT],
			"envelope": base_diag, "body_prefix": str(base_diag["body_prefix"])}
	var parsed: Variant = JSON.parse_string(text)
	if not parsed is Dictionary:
		base_diag["sse_suspected"] = looks_like_sse(text)
		base_diag["body_prefix"] = sanitize_text(text.left(300), api_key, 300)
		if bool(base_diag["sse_suspected"]):
			return {"ok": false, "content_text": "", "finish_reason": "",
				"code": "STREAMING_RESPONSE_DETECTED",
				"detail": "Response is not a JSON object; it looks like an SSE/streaming body (data:/event: markers).",
				"envelope": base_diag, "body_prefix": str(base_diag["body_prefix"])}
		return {"ok": false, "content_text": "", "finish_reason": "",
			"code": "NON_JSON_ENVELOPE",
			"detail": "Response is not a JSON object.",
			"envelope": base_diag, "body_prefix": str(base_diag["body_prefix"])}
	var judged: Dictionary
	if transport == ConfigCls.TRANSPORT_ANTHROPIC:
		judged = extract_anthropic_final(parsed)
	elif transport == ConfigCls.TRANSPORT_RESPONSES:
		judged = extract_responses_final(parsed)
	else:
		judged = extract_openai_final(parsed)
	var env: Dictionary = (judged.get("envelope", {}) as Dictionary).duplicate(true)
	env["http_status"] = http_status
	env["response_chars"] = text.length()
	judged["envelope"] = env
	return judged


## SSE/chunked-body sniff: data:/event: markers near the head of a body
## that failed JSON parsing. Conservative — evidence for classification.
static func looks_like_sse(text: String) -> bool:
	var head := text.strip_edges().left(2000).to_lower()
	if head.begins_with("data:") or head.begins_with("event:"):
		return true
	return head.find("\ndata:") != -1 or head.find("\nevent:") != -1


## TACTICAL FINAL-TEXT RULE: execution requires FINAL model text.
## For OpenAI Chat the final channel is message.content ONLY. Reasoning
## fields (reasoning_content / reasoning) inform diagnostics and NEVER
## become content_text: hidden working text is not a tactical command.
## Returns {ok, content_text, finish_reason, code, detail, envelope} where
## envelope holds SAFE metadata (lengths/presence, never private text).
static func extract_openai_final(wire: Dictionary) -> Dictionary:
	var diag := {
		"choices_count": 0, "finish_reason": "", "message_keys": [],
		"content_type": "missing", "content_chars": 0,
		"reasoning_present": false, "reasoning_chars": 0,
		"refusal_present": false, "tool_calls": 0,
		"usage": {},
	}
	diag["usage"] = usage_of(wire)
	var choices: Variant = wire.get("choices", [])
	if not choices is Array or (choices as Array).is_empty():
		return _final_fail("UNSUPPORTED_RESPONSE_SHAPE",
			"Chat envelope carries no choices array.", diag)
	diag["choices_count"] = (choices as Array).size()
	var first: Variant = (choices as Array)[0]
	if not first is Dictionary:
		return _final_fail("UNSUPPORTED_RESPONSE_SHAPE",
			"Chat envelope choice [0] is not an object.", diag)
	var finish := str((first as Dictionary).get("finish_reason", ""))
	diag["finish_reason"] = finish
	var msg: Variant = (first as Dictionary).get("message", {})
	if not msg is Dictionary:
		return _final_fail("UNSUPPORTED_RESPONSE_SHAPE",
			"Chat envelope choice [0] carries no message object.", diag)
	var keys: Array = []
	for k in (msg as Dictionary).keys():
		keys.append(str(k))
	keys.sort()
	diag["message_keys"] = keys
	# Refusal is authoritative: the model declined; nothing here is a command.
	var refusal := str((msg as Dictionary).get("refusal", ""))
	if not refusal.strip_edges().is_empty():
		diag["refusal_present"] = true
		return _final_fail("MODEL_REFUSAL",
			"Model refused the request (refusal with no tactical text).", diag)
	if finish.strip_edges().to_lower() == "content_filter":
		diag["refusal_present"] = true
		return _final_fail("MODEL_REFUSAL",
			"Model output was content-filtered (no tactical text).", diag)
	var tools: Variant = (msg as Dictionary).get("tool_calls", [])
	diag["tool_calls"] = (tools as Array).size() if tools is Array else 0
	# Reasoning presence/length for diagnostics ONLY. Never executed.
	var r_chars := _reasoning_chars(msg as Dictionary)
	diag["reasoning_present"] = r_chars > 0
	diag["reasoning_chars"] = r_chars
	# Typed final-text extraction: String normal, documented text blocks
	# joined, null/missing empty, anything else an unsupported shape.
	var raw: Variant = (msg as Dictionary).get("content", null)
	var joined := _join_openai_content(raw, diag)
	if bool(joined.get("unsupported", false)):
		return _final_fail("UNSUPPORTED_RESPONSE_SHAPE",
			"Chat content has an unsupported type (%s)." % str(diag.get("content_type", "?")), diag)
	var text := str(joined.get("text", ""))
	diag["content_chars"] = text.length()
	if not text.strip_edges().is_empty():
		return {"ok": true, "content_text": text, "finish_reason": finish,
			"code": "", "detail": "", "envelope": diag}
	# Empty final text: classify WHY (budget/refusal/tools/shape).
	if _is_length_finish(finish):
		if bool(diag["reasoning_present"]):
			return _final_fail("REASONING_BUDGET_EXHAUSTED",
				"Output budget exhausted: reasoning present (%d chars) but no final text (finish=%s)." % [r_chars, finish], diag)
		return _final_fail("FINISH_LENGTH_NO_FINAL",
			"Output budget exhausted with no final text (finish=%s)." % finish, diag)
	if int(diag["tool_calls"]) > 0:
		return _final_fail("TOOL_CALLS_NO_TEXT",
			"Model returned %d tool call(s) with no final text." % int(diag["tool_calls"]), diag)
	return _final_fail("EMPTY_MODEL_CONTENT",
		"Response carries no model text.", diag)


## Provider-reported token usage passthrough (pure, read-only). Numbers only:
## never estimated, never fabricated; absent fields stay absent. Carried in
## the safe envelope so the Lab's THINKING telemetry can show ACTUAL usage
## when the provider reports it, next to char counts (which are separate).
static func usage_of(wire: Dictionary) -> Dictionary:
	var u: Variant = wire.get("usage", null)
	if not u is Dictionary:
		return {}
	var src: Dictionary = u
	var out := {}
	for key in ["prompt_tokens", "completion_tokens", "total_tokens",
			"input_tokens", "output_tokens"]:
		var v: Variant = src.get(key, null)
		if v is int or v is float:
			out[key] = int(v)
	var details: Variant = src.get("completion_tokens_details",
		src.get("output_tokens_details", null))
	if details is Dictionary:
		var rt: Variant = (details as Dictionary).get("reasoning_tokens", null)
		if rt is int or rt is float:
			out["reasoning_tokens"] = int(rt)
		# SELFPLAY V1: local Qwen runtime also reports final_output_tokens
		# (reasoning/final split of completion_tokens). Pure passthrough.
		var ft: Variant = (details as Dictionary).get("final_output_tokens", null)
		if ft is int or ft is float:
			out["final_output_tokens"] = int(ft)
	return out


## Lengths only — the caller never sees private working text.
static func _reasoning_chars(msg: Dictionary) -> int:
	var total := 0
	var rc: Variant = msg.get("reasoning_content", null)
	if rc is String:
		total += (rc as String).length()
	elif rc is Array:
		for b in (rc as Array):
			if b is String:
				total += (b as String).length()
			elif b is Dictionary:
				total += str((b as Dictionary).get("text", "")).length()
	var r2: Variant = msg.get("reasoning", null)
	if r2 is String:
		total += (r2 as String).length()
	elif r2 is Dictionary:
		total += str((r2 as Dictionary).get("text", (r2 as Dictionary).get("content", ""))).length()
	return total


static func _is_length_finish(finish: String) -> bool:
	var f := finish.strip_edges().to_lower()
	return f == "length" or f == "max_tokens"


## Join ONLY documented final-text blocks. Sets diag content_type.
## Returns {text, unsupported}.
static func _join_openai_content(raw: Variant, diag: Dictionary) -> Dictionary:
	if raw == null:
		diag["content_type"] = "null"
		return {"text": "", "unsupported": false}
	if raw is String:
		diag["content_type"] = "string"
		return {"text": raw as String, "unsupported": false}
	if raw is Array:
		diag["content_type"] = "blocks"
		var parts: Array = []
		for b_val in (raw as Array):
			if b_val is Dictionary:
				var t := str((b_val as Dictionary).get("type", ""))
				if t == "text" or t == "output_text":
					var s := str((b_val as Dictionary).get("text", ""))
					if not s.is_empty():
						parts.append(s)
			elif b_val is String and not (b_val as String).is_empty():
				parts.append(b_val as String)
		return {"text": "".join(parts), "unsupported": false}
	if raw is Dictionary:
		diag["content_type"] = "object"
	else:
		diag["content_type"] = "scalar"
	return {"text": "", "unsupported": true}


static func _final_fail(code: String, detail: String, diag: Dictionary) -> Dictionary:
	return {"ok": false, "content_text": "", "finish_reason": str(diag.get("finish_reason", "")),
		"code": code, "detail": detail, "envelope": diag}


## Back-compat shim: final text or "". Live paths use extract_openai_final.
static func extract_openai_content(wire: Dictionary) -> String:
	return str(extract_openai_final(wire).get("content_text", ""))


## Typed Anthropic-messages extraction. Same contract as extract_openai_final.
static func extract_anthropic_final(wire: Dictionary) -> Dictionary:
	var diag := {
		"block_count": 0, "finish_reason": "", "content_type": "blocks",
		"content_chars": 0, "tool_calls": 0, "refusal_present": false,
		"usage": {},
	}
	diag["usage"] = usage_of(wire)
	var stop := str(wire.get("stop_reason", ""))
	diag["finish_reason"] = stop
	var blocks: Variant = wire.get("content", [])
	if not blocks is Array:
		diag["content_type"] = "missing"
		return _final_fail("UNSUPPORTED_RESPONSE_SHAPE",
			"Messages envelope carries no content blocks.", diag)
	diag["block_count"] = (blocks as Array).size()
	var parts: Array = []
	var tools := 0
	for b_val in (blocks as Array):
		if not b_val is Dictionary:
			continue
		var t := str((b_val as Dictionary).get("type", ""))
		if t == "text":
			var s := str((b_val as Dictionary).get("text", ""))
			if not s.is_empty():
				parts.append(s)
		elif t == "tool_use":
			tools += 1
	diag["tool_calls"] = tools
	var text := "".join(parts)
	diag["content_chars"] = text.length()
	if not text.strip_edges().is_empty():
		return {"ok": true, "content_text": text, "finish_reason": stop,
			"code": "", "detail": "", "envelope": diag}
	if stop.strip_edges().to_lower() == "max_tokens":
		return _final_fail("FINISH_LENGTH_NO_FINAL",
			"Output budget exhausted with no final text (stop=max_tokens).", diag)
	if tools > 0:
		return _final_fail("TOOL_CALLS_NO_TEXT",
			"Model returned %d tool call(s) with no final text." % tools, diag)
	return _final_fail("EMPTY_MODEL_CONTENT",
		"Response carries no model text.", diag)


## Back-compat shim: final text or "". Live paths use extract_anthropic_final.
static func extract_anthropic_content(wire: Dictionary) -> String:
	return str(extract_anthropic_final(wire).get("content_text", ""))


## Typed OpenAI-Responses extraction. Same contract as extract_openai_final.
static func extract_responses_final(wire: Dictionary) -> Dictionary:
	var diag := {
		"output_count": 0, "finish_reason": "", "content_type": "parts",
		"content_chars": 0, "tool_calls": 0, "refusal_present": false,
		"usage": {},
	}
	diag["usage"] = usage_of(wire)
	var status := str(wire.get("status", ""))
	diag["finish_reason"] = status
	var out: Variant = wire.get("output", [])
	diag["output_count"] = (out as Array).size() if out is Array else 0
	var text := OpenCodeCls.extract_responses_content(wire)
	diag["content_chars"] = text.length()
	if not text.strip_edges().is_empty():
		return {"ok": true, "content_text": text, "finish_reason": status,
			"code": "", "detail": "", "envelope": diag}
	if status.strip_edges().to_lower() == "incomplete":
		return _final_fail("FINISH_LENGTH_NO_FINAL",
			"Output budget exhausted with no final text (status=incomplete).", diag)
	return _final_fail("EMPTY_MODEL_CONTENT",
		"Response carries no model text.", diag)


## Safe preview of what a request would carry: structure only, no secret.
static func request_preview(config: ConfigCls, packet: Dictionary, system_prompt: String) -> Dictionary:
	var messages := [
		{"role": "system", "content_chars": system_prompt.length()},
		{"role": "user", "content_chars": JSON.stringify(packet).length()},
	]
	return {
		"provider": config.provider_id,
		"model": config.model,
		"endpoint": config.endpoint,
		"transport": config.effective_transport(),
		"protocol_source": config.protocol_source,
		"timeout_sec": config.timeout_sec,
		"has_key": config.has_key(),
		"key": config.redacted_key(),
		"messages": messages,
		"packet_keys": packet.keys(),
	}
