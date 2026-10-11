class_name AIBackendBootstrap
extends Node

## Embedded-backend milestone: game-owned startup gate.
##
## On [게임 시작] the game behaves like any other game with embedded assets:
##   1. Reuse the running Ollama server if 127.0.0.1:11434 answers.
##   2. Otherwise auto-start `ollama serve` (no shell, controlled args only)
##      and poll for readiness.
##   3. Verify the hard-locked/selected model is installed (never download).
##   4. VRAM preload: one tiny chat with a long keep_alive so the model is
##      resident BEFORE entering battle. First Advisor call is then fast.
##
## No downloads, no benchmarks, no routing, no fallback models. A started
## server is conservatively LEFT RUNNING on exit (possibly shared).
## Every public entry bumps _session; stale async continuations abort
## silently so retry/cancel can never mark a new config READY.

signal state_changed(state: int, state_name: String)
signal status_message(text: String)
signal models_updated(models: Array)
signal start_finished(ok: bool, info: Dictionary)

enum State {
	IDLE,
	CHECKING_SERVER,
	STARTING_SERVER,
	WAITING_FOR_SERVER,
	CHECKING_MODEL,
	WARMING_MODEL,
	READY,
	FAILED,
}

const STATE_NAMES := ["IDLE", "CHECKING_SERVER", "STARTING_SERVER",
	"WAITING_FOR_SERVER", "CHECKING_MODEL", "WARMING_MODEL",
	"READY", "FAILED"]

const ConfigScript = preload("res://scripts/ai/ai_backend_config.gd")
const SemanticMgrScript = preload("res://scripts/step7/step7_semantic_model_manager.gd")

const POLL_INTERVAL_SEC := 0.75
const TAGS_TIMEOUT_SEC := 5.0

const AI_FREE_HINT := "AI 연결 없이 게임을 시작할 수 있습니다."

var state: int = State.IDLE
var last_error_kind := ""
var last_player_message := ""
var last_models: Array = []
var last_info: Dictionary = {}

var _session := 0
var _cfg: Dictionary = {}
var _t0_total := 0
var _lat: Dictionary = {}
var _server_was_running := false
var _started_by_game := false
var _ollama_exe := ""
var _exe_source := ""
var _ollama_pid := -1
var _semantic_info: Dictionary = {}


func state_name(s: int = -1) -> String:
	var idx := state if s < 0 else s
	if idx >= 0 and idx < STATE_NAMES.size():
		return str(STATE_NAMES[idx])
	return "UNKNOWN"


func is_busy() -> bool:
	return state != State.IDLE and state != State.READY and state != State.FAILED


func cancel() -> void:
	_session += 1
	_set_state(State.IDLE, "설정을 변경하면 다시 시도할 수 있습니다.")


func dev_snapshot() -> Dictionary:
	return {
		"state": state_name(),
		"backend_type": str(_cfg.get("backend_type", "?")),
		"endpoint": str(_cfg.get("endpoint", "?")),
		"model": str(_cfg.get("model", "?")),
		"semantic": _semantic_info.duplicate(true),
		"server_reachable": _server_was_running or _started_by_game,
		"ollama_exe": _ollama_exe,
		"exe_source": _exe_source,
		"server_was_running": _server_was_running,
		"started_by_game": _started_by_game,
		"pid": _ollama_pid,
		"model_count": last_models.size(),
		"latencies_ms": _lat.duplicate(),
		"last_error": last_error_kind,
		"api_key_present": ConfigScript.has_api_key(),
	}


# --- Public flows ------------------------------------------------------

## Tags-only discovery for the dropdown. Never starts a process, never runs
## inference. Used by the settings panel refresh button.
func fetch_models(endpoint: String) -> Dictionary:
	_session += 1
	var my := _session
	last_models = []
	var ep := ConfigScript.sanitize_endpoint(endpoint.strip_edges())
	if not bool(ep.get("ok", false)):
		return {"ok": false, "models": [], "http_status": 0}
	var r := await _http_get_tags(ConfigScript.tags_url(str(ep.get("value", ""))), TAGS_TIMEOUT_SEC)
	if my != _session:
		return {"ok": false, "models": [], "http_status": 0, "cancelled": true}
	if bool(r.get("ok", false)):
		last_models = r.get("models", [])
		models_updated.emit(last_models.duplicate())
		return {"ok": true, "models": last_models.duplicate(), "http_status": int(r.get("http_status", 0))}
	return {"ok": false, "models": [], "http_status": int(r.get("http_status", 0))}


## Full preparation gate for [게임 시작]: server up -> model present ->
## VRAM preload -> READY. Generic backends only probe reachability.
func start_preparation(cfg: Dictionary) -> void:
	_session += 1
	var my := _session
	_cfg = cfg.duplicate()
	_lat = {}
	last_models = []
	last_error_kind = ""
	last_player_message = ""
	_server_was_running = false
	_started_by_game = false
	_ollama_pid = -1
	_semantic_info = {}
	_ollama_exe = ""
	_exe_source = ""
	_t0_total = Time.get_ticks_msec()
	if str(_cfg.get("backend_type", ConfigScript.BACKEND_LOCAL_OLLAMA)) != ConfigScript.BACKEND_LOCAL_OLLAMA:
		await _prepare_generic(my)
		return
	# 1) Server already up? Reuse it — never start a duplicate.
	_set_state(State.CHECKING_SERVER, "AI 서버 연결 확인 중...")
	var t0 := Time.get_ticks_msec()
	var first := await _http_get_tags(ConfigScript.tags_url(str(_cfg.get("endpoint", ""))), TAGS_TIMEOUT_SEC)
	if not _alive(my):
		return
	_lat["detection_ms"] = Time.get_ticks_msec() - t0
	if bool(first.get("ok", false)):
		_server_was_running = true
		last_models = first.get("models", [])
		models_updated.emit(last_models.duplicate())
	else:
		# 2) Start local Ollama in the background, then poll for readiness.
		var found := discover_ollama_exe()
		if not _alive(my):
			return
		if not bool(found.get("found", false)):
			_fail_start(my, "EXE_NOT_FOUND", "Ollama 실행 파일을 찾을 수 없습니다. Ollama를 먼저 설치하십시오.")
			return
		_ollama_exe = str(found.get("path", ""))
		_exe_source = str(found.get("source", ""))
		_set_state(State.STARTING_SERVER, "AI 서버 시작 중... (ollama serve)")
		var ts := Time.get_ticks_msec()
		_ollama_pid = _spawn_ollama(_ollama_exe)
		_lat["start_ms"] = Time.get_ticks_msec() - ts
		if not _alive(my):
			return
		if _ollama_pid < 0:
			_fail_start(my, "START_FAILED", "AI 서버를 시작하지 못했습니다. 직접 실행 후 다시 시도하십시오.")
			return
		_started_by_game = true
		_set_state(State.WAITING_FOR_SERVER, "AI 서버 연결 대기 중...")
		var tw := Time.get_ticks_msec()
		var ready := await _poll_tags(my, float(_cfg.get("startup_timeout_sec", ConfigScript.DEFAULT_STARTUP_TIMEOUT_SEC)))
		_lat["ready_ms"] = Time.get_ticks_msec() - tw
		if not _alive(my):
			return
		if not bool(ready.get("ok", false)):
			_fail_start(my, "SERVER_UNREACHABLE", "AI 서버에 연결할 수 없습니다. 잠시 후 다시 시도하십시오.")
			return
		last_models = ready.get("models", [])
		models_updated.emit(last_models.duplicate())
	# 3) Model installed? Never auto-download: warn and stop.
	_set_state(State.CHECKING_MODEL, "모델 확인 중...")
	var want := str(_cfg.get("model", "")).strip_edges()
	if not _alive(my):
		return
	if want.is_empty():
		_fail_start(my, "MODEL_MISSING", "모델 이름이 비어 있습니다.")
		return
	if not (want in last_models):
		_fail_start(my, "MODEL_MISSING", "선택한 모델 %s 이 설치되어 있지 않습니다. (ollama list로 확인)" % want)
		return
	# 4) VRAM preload: tiny chat with long keep_alive forces model residency.
	# Like any other game's loading screen: battle entry waits for this.
	_set_state(State.WARMING_MODEL, "모델을 VRAM에 올리는 중... (%s)\n처음 한 번은 시간이 걸릴 수 있습니다." % want)
	var twarm := Time.get_ticks_msec()
	var warm := await _chat_once(my, want, "Reply with exactly: READY.", 8, float(_cfg.get("warmup_timeout_sec", ConfigScript.DEFAULT_WARMUP_TIMEOUT_SEC)))
	_lat["warmup_ms"] = Time.get_ticks_msec() - twarm
	if not _alive(my):
		return
	if not bool(warm.get("ok", false)):
		var kind := str(warm.get("kind", "WARMUP_FAILED"))
		var msg := "모델을 VRAM에 올리는 중 시간이 초과되었습니다." if kind == "WARMUP_TIMEOUT" else "모델을 불러오지 못했습니다. 다시 시도하십시오."
		_fail_start(my, kind, msg)
		return
	_lat["total_ms"] = Time.get_ticks_msec() - _t0_total
	# 5) Semantic frontend (NON-FATAL): tiny Qwen3-0.6B tag present?
	# Missing -> download GGUF once -> ollama create -> warm into VRAM.
	# Any failure degrades to the large-model semantic path; battle entry
	# is NEVER blocked by the frontend.
	_set_state(State.WARMING_MODEL, "의미 모델 준비 중...")
	var tw := Time.get_ticks_msec()
	var sem := await _ensure_semantic(my)
	_lat["semantic_ms"] = Time.get_ticks_msec() - tw
	if not _alive(my):
		return
	_semantic_info = sem
	_lat["total_ms"] = Time.get_ticks_msec() - _t0_total
	if bool(sem.get("ok", false)):
		_set_state(State.READY, "준비 완료 — 출정할 수 있습니다.")
	else:
		_set_state(State.READY, "준비 완료 (의미 모델 없이 대형 모델로 운용) — 출정할 수 있습니다.")
	start_finished.emit(true, _start_info(true, "", "준비 완료", bool(warm.get("ready_seen", false)), sem))


# --- Generic API: probe only, no auto-start/warmup ----------
func _prepare_generic(my: int) -> void:
	_set_state(State.CHECKING_SERVER, "외부 API 연결 확인 중...")
	var t0 := Time.get_ticks_msec()
	var tags := await _http_get_tags(ConfigScript.tags_url(str(_cfg.get("endpoint", ""))), TAGS_TIMEOUT_SEC)
	if not _alive(my):
		return
	_lat["detection_ms"] = Time.get_ticks_msec() - t0
	_lat["total_ms"] = Time.get_ticks_msec() - _t0_total
	if not bool(tags.get("ok", false)):
		_fail_start(my, "SERVER_UNREACHABLE", "외부 API에 연결할 수 없습니다. 주소와 키를 확인하십시오.")
		return
	last_models = tags.get("models", [])
	models_updated.emit(last_models.duplicate())
	_set_state(State.READY, "준비 완료 — 출정할 수 있습니다.")
	start_finished.emit(true, _start_info(true, "", "준비 완료", false))


# --- Semantic frontend ensure (non-fatal) --------------------------------
## Owns a one-shot Step7SemanticModelManager child, forwards its player
## status + download progress, and returns its finished info dict.
func _ensure_semantic(my: int) -> Dictionary:
	var mgr := SemanticMgrScript.new()
	mgr.name = "SemanticModelManager"
	add_child(mgr)
	mgr.state_changed.connect(func(_sn: String, text: String) -> void:
		if _alive(my) and not text.is_empty():
			status_message.emit(text))
	mgr.download_progress.connect(func(dl: int, total: int) -> void:
		if _alive(my):
			status_message.emit("의미 모델 다운로드 중... %d / %d MB" % [dl / 1048576, total / 1048576]))
	mgr.ensure_async({
		"endpoint": str(_cfg.get("endpoint", ConfigScript.DEFAULT_ENDPOINT)),
		"keep_alive": str(_cfg.get("keep_alive", ConfigScript.DEFAULT_KEEP_ALIVE)),
		"warmup_timeout_sec": float(_cfg.get("warmup_timeout_sec", ConfigScript.DEFAULT_WARMUP_TIMEOUT_SEC)),
	})
	var res: Array = await mgr.finished
	mgr.queue_free()
	if res.size() < 2 or not (res[1] is Dictionary):
		return {"ok": false, "error_kind": "SEMANTIC_UNKNOWN"}
	return res[1]


# --- Ollama executable discovery (no hard-coded developer username) -----
## Returns {found, path, source}. No shell, no key material involved.
func discover_ollama_exe() -> Dictionary:
	var cands: Array = []
	var local := OS.get_environment("LOCALAPPDATA")
	if not local.strip_edges().is_empty():
		cands.append([local.strip_edges() + "/Programs/Ollama/ollama.exe", "LOCALAPPDATA"])
	for env in ["PROGRAMFILES", "PROGRAMFILES(X86)", "PROGRAMW6432"]:
		var p := OS.get_environment(env).strip_edges()
		if not p.is_empty():
			cands.append([p + "/Ollama/ollama.exe", env])
	for c in cands:
		var path := str(c[0])
		if FileAccess.file_exists(path):
			return {"found": true, "path": path, "source": str(c[1])}
	var pathenv := OS.get_environment("PATH")
	if not pathenv.strip_edges().is_empty():
		for d in pathenv.split(";"):
			var dir := d.strip_edges().trim_suffix("/").trim_suffix("\\")
			if dir.is_empty():
				continue
			var t := dir + "/ollama.exe"
			if FileAccess.file_exists(t):
				return {"found": true, "path": t, "source": "PATH"}
	return {"found": false, "path": "", "source": ""}


## Direct executable invocation with controlled args only ("serve").
## No shell, no PowerShell, no user strings — no injection surface.
func _spawn_ollama(exe_path: String) -> int:
	var args := PackedStringArray(["serve"])
	return OS.create_process(exe_path, args, false)


# --- HTTP primitives (one-shot nodes, no shared-state races) ------------
func _http_get_tags(url: String, timeout_sec: float) -> Dictionary:
	var http := HTTPRequest.new()
	http.timeout = maxf(2.0, timeout_sec)
	add_child(http)
	var err := http.request(url, PackedStringArray(["Accept: application/json"]), HTTPClient.METHOD_GET)
	if err != OK:
		http.queue_free()
		return {"ok": false, "transport_error": err, "http_status": 0}
	var res: Array = await http.request_completed
	if not is_instance_valid(http):
		return {"ok": false, "transport_error": -1, "http_status": 0}
	http.queue_free()
	if res.size() < 4:
		return {"ok": false, "transport_error": -2, "http_status": 0}
	var godot_result := int(res[0])
	var code := int(res[1])
	var body := res[3] as PackedByteArray
	if godot_result != HTTPRequest.RESULT_SUCCESS:
		return {"ok": false, "transport_error": godot_result, "http_status": 0}
	if code < 200 or code >= 300:
		return {"ok": false, "transport_error": 0, "http_status": code}
	return {"ok": true, "http_status": code, "models": _parse_model_names(body.get_string_from_utf8())}


func _poll_tags(my: int, timeout_sec: float) -> Dictionary:
	var deadline := Time.get_ticks_msec() + int(clampf(timeout_sec, 10.0, 300.0) * 1000.0)
	var last := {"ok": false}
	while Time.get_ticks_msec() < deadline:
		if not _alive(my):
			return {"ok": false, "cancelled": true}
		var r := await _http_get_tags(ConfigScript.tags_url(str(_cfg.get("endpoint", ""))), 4.0)
		if not _alive(my):
			return {"ok": false, "cancelled": true}
		if bool(r.get("ok", false)):
			return r
		last = r
		await get_tree().create_timer(POLL_INTERVAL_SEC).timeout
		if not is_inside_tree():
			return {"ok": false, "cancelled": true}
	return last


## VRAM-preload chat: minimal tokens, long keep_alive so the model stays
## resident for the session. Never battle state, never cached as advice.
func _chat_once(my: int, model: String, user_text: String, num_predict: int, timeout_sec: float) -> Dictionary:
	var http := HTTPRequest.new()
	http.timeout = maxf(10.0, timeout_sec)
	http.body_size_limit = 262144
	add_child(http)
	var payload := {
		"model": model,
		"stream": false,
		"keep_alive": str(_cfg.get("keep_alive", ConfigScript.DEFAULT_KEEP_ALIVE)),
		"think": false,
		"options": {"temperature": 0.0, "num_predict": num_predict},
		"messages": [
			{"role": "system", "content": "You are a local game AI preload endpoint."},
			{"role": "user", "content": user_text},
		],
	}
	var err := http.request(ConfigScript.chat_url(str(_cfg.get("endpoint", ""))),
		PackedStringArray(["Content-Type: application/json"]),
		HTTPClient.METHOD_POST, JSON.stringify(payload))
	if err != OK:
		http.queue_free()
		return {"ok": false, "kind": "OFFLINE"}
	var res: Array = await http.request_completed
	if not _alive(my) or not is_instance_valid(http):
		if is_instance_valid(http):
			http.queue_free()
		return {"ok": false, "kind": "CANCELLED"}
	http.queue_free()
	if res.size() < 4:
		return {"ok": false, "kind": "BAD_RESPONSE"}
	var godot_result := int(res[0])
	var code := int(res[1])
	var body := res[3] as PackedByteArray
	if godot_result == HTTPRequest.RESULT_TIMEOUT or godot_result == HTTPRequest.RESULT_REQUEST_FAILED:
		return {"ok": false, "kind": "WARMUP_TIMEOUT"}
	if godot_result != HTTPRequest.RESULT_SUCCESS:
		return {"ok": false, "kind": "OFFLINE"}
	if code == 404:
		return {"ok": false, "kind": "MODEL_MISSING"}
	if code < 200 or code >= 300:
		return {"ok": false, "kind": "HTTP_ERROR"}
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	if not parsed is Dictionary:
		return {"ok": false, "kind": "BAD_RESPONSE"}
	var msg: Variant = (parsed as Dictionary).get("message", {})
	if not msg is Dictionary:
		return {"ok": false, "kind": "BAD_RESPONSE"}
	var content := str((msg as Dictionary).get("content", ""))
	if content.strip_edges().is_empty():
		return {"ok": false, "kind": "BAD_RESPONSE"}
	return {"ok": true, "kind": "", "ready_seen": content.to_upper().contains("READY")}


static func _parse_model_names(body_text: String) -> Array:
	var out: Array = []
	var parsed: Variant = JSON.parse_string(body_text)
	if parsed is Dictionary:
		for m in ((parsed as Dictionary).get("models", []) as Array):
			if m is Dictionary and str((m as Dictionary).get("name", "")).length() > 0:
				out.append(str((m as Dictionary).get("name", "")))
	out.sort()
	return out


# --- State / staleness / info --------------------------------------------
func _alive(my: int) -> bool:
	return my == _session


func _set_state(s: int, msg: String) -> void:
	state = s
	state_changed.emit(s, state_name(s))
	if not msg.is_empty():
		status_message.emit(msg)


func _fail_start(my: int, kind: String, player_message: String) -> void:
	if not _alive(my):
		return
	last_error_kind = kind
	last_player_message = player_message
	_lat["total_ms"] = Time.get_ticks_msec() - _t0_total
	_set_state(State.FAILED, player_message)
	start_finished.emit(false, _start_info(false, kind, player_message, false))


func _start_info(ok: bool, kind: String, player_message: String, warm_ready: bool, sem: Dictionary = {}) -> Dictionary:
	return {
		"ok": ok,
		"models": last_models.duplicate(),
		"model": str(_cfg.get("model", "")),
		"semantic": sem.duplicate(true),
		"warm_ready_token": warm_ready,
		"server_was_running": _server_was_running,
		"started_by_game": _started_by_game,
		"ollama_exe": _ollama_exe,
		"exe_source": _exe_source,
		"pid": _ollama_pid,
		"latencies_ms": _lat.duplicate(),
		"error_kind": kind,
		"player_message": player_message,
		"hint": "" if ok else AI_FREE_HINT,
		"dev": dev_snapshot(),
	}
