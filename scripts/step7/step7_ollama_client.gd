class_name Step7OllamaAdvisorClient
extends Node

## Direct Ollama HTTP client for the tactical Advisor pilot.
##
## Owns ONLY: one HTTPRequest, POST <base>/api/chat (non-streaming),
## timeout/offline/HTTP errors, raw-result normalization with timing.
##
## Owns NOTHING about battles: no options, no prompts, no parsing of the
## tactical contract, no game state, no execution. Untrusted model text is
## returned verbatim for the selector to validate; never executed here.
##
## Result Dictionary (emitted via chat_finished):
##   ok=true:  {ok, request_id, http_status, content_text, message_role,
##              prompt_eval_count, eval_count, prompt_eval_duration_ns,
##              eval_duration_ns, total_duration_ns, load_duration_ns,
##              latency_ms, done_reason}
##   ok=false: {ok:false, request_id, code, detail, http_status, latency_ms}
## Codes: OFFLINE (connection refused/unreachable), TIMEOUT, HTTP_ERROR,
## MODEL_MISSING (404), BAD_RESPONSE (non-JSON envelope).

signal chat_finished(request_id: String, result: Dictionary)

const BODY_SIZE_LIMIT := 2097152 # 2 MiB: model JSON must stay far below this.

var _http: HTTPRequest = null
var _active_request_id := ""
var _active_t0_msec := 0


func _ready() -> void:
	_http = HTTPRequest.new()
	_http.name = "OllamaChatRequest"
	_http.timeout = 125.0
	_http.body_size_limit = BODY_SIZE_LIMIT
	add_child(_http)
	_http.request_completed.connect(_on_request_completed)


## Fire one non-streaming chat request. Cancels any in-flight request first
## (single active request bound). Returns {ok} synchronously; the real
## outcome always arrives via chat_finished.
##
## api_key is the memory-only secret from AIBackendConfig.get_api_key().
## When non-empty (generic backends), it is sent as
## "Authorization: Bearer <key>" and never logged. When empty (local
## Ollama default), no Authorization header is sent at all.
func request_chat(request_id: String, endpoint: String, model: String,
		messages: Array, options: Dictionary, timeout_sec: float,
		api_key: String = "") -> Dictionary:
	if _http == null:
		return {"ok": false, "code": "OFFLINE", "detail": "HTTP node not ready."}
	cancel_active()
	_active_request_id = request_id
	_active_t0_msec = Time.get_ticks_msec()
	_http.timeout = maxf(5.0, timeout_sec + 5.0)
	var payload := {
		"model": model,
		"stream": false,
		"format": "json",
		"think": bool(options.get("think", false)),
		"options": {
			"temperature": float(options.get("temperature", 0.2)),
			"num_predict": int(options.get("num_predict", 768)),
			"num_ctx": int(options.get("num_ctx", 12288)),
		},
		"messages": messages,
	}
	var body := JSON.stringify(payload)
	var headers := PackedStringArray(["Content-Type: application/json"])
	if not api_key.strip_edges().is_empty():
		headers.append("Authorization: Bearer " + api_key.strip_edges())
	var err := _http.request(endpoint,
		headers,
		HTTPClient.METHOD_POST, body)
	if err != OK:
		var detail := "HTTPRequest start failed (err=%d)." % err
		_active_request_id = ""
		return {"ok": false, "code": "OFFLINE", "detail": detail}
	return {"ok": true, "request_id": request_id}


func has_active() -> bool:
	return not _active_request_id.is_empty()


func active_request_id() -> String:
	return _active_request_id


## Supersede the in-flight request without emitting (the response, if it
## still arrives, is ignored because the id no longer matches).
func cancel_active() -> void:
	if _http != null and has_active():
		_http.cancel_request()
	_active_request_id = ""


func _latency_ms() -> int:
	return Time.get_ticks_msec() - _active_t0_msec


func _finish_fail(request_id: String, code: String, detail: String, http_status: int) -> void:
	chat_finished.emit(request_id, {
		"ok": false, "request_id": request_id, "code": code,
		"detail": detail, "http_status": http_status,
		"latency_ms": _latency_ms(),
	})


func _on_request_completed(godot_result: int, response_code: int,
		_headers: PackedStringArray, body: PackedByteArray) -> void:
	var request_id := _active_request_id
	_active_request_id = ""
	if request_id.is_empty():
		return # superseded/cancelled: discard silently, never display.
	var latency := _latency_ms()
	if godot_result != HTTPRequest.RESULT_SUCCESS:
		var code := "OFFLINE"
		var detail := "Ollama server unreachable."
		match godot_result:
			HTTPRequest.RESULT_CANT_CONNECT, HTTPRequest.RESULT_CONNECTION_ERROR:
				code = "OFFLINE"
				detail = "Ollama server unreachable (connection refused). Is Ollama running?"
			HTTPRequest.RESULT_TIMEOUT, HTTPRequest.RESULT_REQUEST_FAILED:
				code = "TIMEOUT"
				detail = "Ollama request timed out."
			HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR:
				code = "OFFLINE"
				detail = "TLS error talking to the local Ollama endpoint."
			_:
				code = "OFFLINE"
				detail = "Local model request failed (transport err=%d)." % godot_result
		chat_finished.emit(request_id, {"ok": false, "request_id": request_id,
			"code": code, "detail": detail, "http_status": 0,
			"latency_ms": latency})
		return
	if response_code == 404:
		_finish_fail(request_id, "MODEL_MISSING",
			"Model not found on the Ollama server.", response_code)
		return
	if response_code < 200 or response_code >= 300:
		_finish_fail(request_id, "HTTP_ERROR",
			"Ollama HTTP status %d." % response_code, response_code)
		return
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	if not parsed is Dictionary:
		_finish_fail(request_id, "BAD_RESPONSE",
			"Ollama returned a non-JSON envelope.", response_code)
		return
	var env: Dictionary = parsed
	var message: Dictionary = env.get("message", {})
	var content := str(message.get("content", ""))
	if content.strip_edges().is_empty():
		_finish_fail(request_id, "BAD_RESPONSE",
			"Ollama returned an empty message.", response_code)
		return
	chat_finished.emit(request_id, {"ok": true, "request_id": request_id,
		"http_status": response_code, "content_text": content,
		"message_role": str(message.get("role", "assistant")),
		"done_reason": str(env.get("done_reason", "")),
		"prompt_eval_count": int(env.get("prompt_eval_count", 0)),
		"eval_count": int(env.get("eval_count", 0)),
		"prompt_eval_duration_ns": int(env.get("prompt_eval_duration", 0)),
		"eval_duration_ns": int(env.get("eval_duration", 0)),
		"total_duration_ns": int(env.get("total_duration", 0)),
		"load_duration_ns": int(env.get("load_duration", 0)),
		"latency_ms": latency})
