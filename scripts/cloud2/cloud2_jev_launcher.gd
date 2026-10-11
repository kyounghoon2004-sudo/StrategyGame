class_name Cloud2JevLauncher
extends RefCounted

## JEV SINGLE-LAUNCH RUNTIME (SHADOW ONLY) ??process ownership + handshake.
##
## Godot owns the JEV worker lifecycle completely: discover Python, pick a
## localhost port, spawn a hidden child worker, verify its identity via a
## strict health handshake, and terminate exactly that worker on game exit.
## The user never starts, configures, or stops anything.
##
## Modes:
##   AUTO (default, JEV_SHADOW_ENABLE unset or "1", no JEV_SHADOW_URL):
##     spawn an owned hidden worker on a dynamic port. Failure at any step
##     -> SHADOW_DISABLED (fail-open), game continues deterministically.
##   FIXED (JEV_SHADOW_URL set): never spawn; handshake the given endpoint
##     and reuse it only when identity matches. Never killed on exit.
##   OFF (JEV_SHADOW_ENABLE == "0"): no spawn, no HTTP, zero behavior change.
##
## Authority: SHADOW_ONLY. This file manages a local inference process; it
## never issues commands, mutates units, or touches the tactical selector.

const MODEL_IDENTITY := "jev-policy-v0.6.0-mission1"
const CHECKPOINT_SHA256 := "2c3eae26b09021e2a856090de3bf343f5df432dd50f01c43c1c1d8fefd413867"
const PROTOCOL_VERSION := "jev-shadow-protocol-v1"
const CONTRACT_VERSION := "jev-shadow-contract-v1"
const REQUEST_VERSION := "jev-shadow-request-v1"
const RESPONSE_VERSION := "jev-shadow-response-v1"
const SLOTMAP_VERSION := "jev-shadow-slotmap-v1"
const MISSIONMAP_VERSION := "jev-shadow-missionmap-v1"
const OBSERVATION_SCHEMA := "observation-layout-v0.1.0"
const ACTION_SCHEMA := "jev-shadow-slotmap-v1"

const HOST := "127.0.0.1"
const DEFAULT_PORT := 11439
const DEFAULT_STARTUP_TIMEOUT_MS := 90000
const FIXED_PROBE_TIMEOUT_MS := 5000
const HEALTH_SLICE_TIMEOUT_MS := 3000
const SHUTDOWN_TIMEOUT_MS := 5000
const WORKER_REL_PATH := "res://tools/jev_shadow/worker.py"
const WORKER_LOG_REL := "res://artifacts/jev_shadow_single_launch_v0/worker.log"

# Status: COLD (never attempted) | BOOTING | READY | DISABLED.
static var _status := "COLD"
static var _mode := "AUTO"
static var _owned := false
static var _pid := -1
static var _port := DEFAULT_PORT
static var _host := HOST
static var _python := ""
static var _python_source := ""
static var _started_msec := 0
static var _startup_latency_ms := -1.0
static var _identity := {}
static var _last_error := ""
static var _token := ""
static var _worker_log := ""


static func auto_enabled() -> bool:
	return OS.get_environment("JEV_SHADOW_ENABLE").strip_edges() != "0"


static func fixed_url_mode() -> bool:
	return not OS.get_environment("JEV_SHADOW_URL").strip_edges().is_empty()


static func startup_timeout_ms() -> int:
	if OS.has_environment("JEV_SHADOW_STARTUP_TIMEOUT_MS"):
		return clampi(int(OS.get_environment("JEV_SHADOW_STARTUP_TIMEOUT_MS")),
			5000, 600000)
	return DEFAULT_STARTUP_TIMEOUT_MS


static func is_ready() -> bool:
	return _status == "READY"


static func is_disabled() -> bool:
	return _status == "DISABLED"


static func boot_in_progress() -> bool:
	return _status == "BOOTING"


static func health_url() -> String:
	return "http://%s:%d" % [_host, _port]


static func active_host() -> String:
	return _host


static func active_port() -> int:
	return _port


static func worker_pid() -> int:
	return _pid if _status == "READY" else -1


static func owned_pid_alive() -> bool:
	return _owned and _pid > 0 and OS.is_process_running(_pid)


static func status_snapshot() -> Dictionary:
	return {
		"status": _status, "mode": _mode, "owned": _owned,
		"pid": _pid, "port": _port, "host": _host,
		"python": _python, "python_source": _python_source,
		"started_unix": _started_unix(), "startup_latency_ms": _startup_latency_ms,
		"model": MODEL_IDENTITY, "checkpoint_sha256": CHECKPOINT_SHA256,
		"protocol_version": PROTOCOL_VERSION, "contract": CONTRACT_VERSION,
		"request_schema": REQUEST_VERSION, "response_schema": RESPONSE_VERSION,
		"slot_map": SLOTMAP_VERSION, "mission_map": MISSIONMAP_VERSION,
		"observation_schema": OBSERVATION_SCHEMA, "action_schema": ACTION_SCHEMA,
		"worker_identity": _identity.duplicate(true),
		"worker_up": OS.is_process_running(_pid) if _pid > 0 else false,
		"last_error": _last_error,
	}


static var _started_unix_s := 0.0


## Idempotent blocking entry point. Bounded by startup_timeout_ms().
## Safe to call from the synchronous SceneTree harness and from observe().
static func ensure_started_sync(timeout_ms: int = -1) -> Dictionary:
	if not auto_enabled():
		_status = "DISABLED"
		_mode = "OFF"
		_last_error = "EXPLICIT_OFF"
		return status_snapshot()
	if _status == "READY":
		if _owned and not OS.is_process_running(_pid):
			mark_disabled("WORKER_CRASHED")
		return status_snapshot()
	if _status == "DISABLED":
		return status_snapshot()
	var budget := startup_timeout_ms() if timeout_ms < 0 else timeout_ms
	if fixed_url_mode():
		_probe_fixed_sync()
		return status_snapshot()
	if _status == "COLD":
		var spawned := spawn_owned_or_fixed()
		if not bool(spawned.get("ok", false)):
			return status_snapshot()
	return await_ready_sync(Time.get_ticks_msec() + budget)


## Fast non-blocking part for the autoload: discover + spawn, then return
## with status BOOTING. The caller polls health asynchronously.
static func spawn_owned_or_fixed() -> Dictionary:
	if not auto_enabled():
		_status = "DISABLED"
		_mode = "OFF"
		_last_error = "EXPLICIT_OFF"
		return {"ok": false, "error": "EXPLICIT_OFF"}
	if _status == "READY" or _status == "BOOTING":
		return {"ok": true, "status": _status, "pid": _pid, "port": _port}
	if _status == "DISABLED":
		return {"ok": false, "error": "ALREADY_DISABLED"}
	if fixed_url_mode():
		_mode = "FIXED"
		return {"ok": true, "status": "COLD", "mode": "FIXED"}
	_mode = "AUTO"
	var py := discover_python()
	if not bool(py.get("found", false)):
		mark_disabled("PYTHON_NOT_FOUND")
		return {"ok": false, "error": "PYTHON_NOT_FOUND"}
	var worker_global := ProjectSettings.globalize_path(WORKER_REL_PATH)
	if not FileAccess.file_exists(worker_global):
		_last_error = "WORKER_SCRIPT_MISSING"
		mark_disabled("WORKER_SCRIPT_MISSING")
		return {"ok": false, "error": "WORKER_SCRIPT_MISSING"}
	var port := pick_port()
	if port < 0:
		mark_disabled("NO_FREE_PORT")
		return {"ok": false, "error": "NO_FREE_PORT"}
	_prepare_worker_log()
	_token = _new_token()
	var args := PackedStringArray([
		"-u", worker_global,
		"--host", HOST, "--port", str(port),
		"--parent-pid", str(OS.get_process_id()),
		"--shutdown-token", _token,
	])
	if not _worker_log.is_empty():
		args.append("--log-file")
		args.append(_worker_log)
	_started_msec = Time.get_ticks_msec()
	_started_unix_s = Time.get_unix_time_from_system()
	var pid := OS.create_process(str(py["path"]), args, false)
	if pid <= 0:
		_token = ""
		mark_disabled("SPAWN_FAILED")
		return {"ok": false, "error": "SPAWN_FAILED"}
	_status = "BOOTING"
	_owned = true
	_pid = pid
	_port = port
	_host = HOST
	_python = str(py["path"])
	_python_source = str(py["source"])
	_last_error = ""
	print("[JEVLAUNCH] spawned owned worker pid=%d port=%d python=%s" % [pid, port, _python_source])
	return {"ok": true, "status": "BOOTING", "pid": pid, "port": port}


## Blocking health wait for an already-spawned worker. Bounded by deadline.
static func await_ready_sync(deadline_msec: int) -> Dictionary:
	while Time.get_ticks_msec() < deadline_msec:
		if _status != "BOOTING":
			return status_snapshot()
		if _owned and _pid > 0 and not OS.is_process_running(_pid):
			mark_disabled("WORKER_DIED_DURING_BOOT")
			return status_snapshot()
		var res := _http_get(_host, _port, "/health", HEALTH_SLICE_TIMEOUT_MS)
		if _status != "BOOTING":
			return status_snapshot()
		if bool(res.get("ok", false)):
			var parsed: Variant = JSON.parse_string(str(res.get("body", "")))
			if parsed is Dictionary:
				var v := verify_health_dict(parsed)
				if bool(v.get("ok", false)):
					mark_ready(v.get("identity", {}))
					return status_snapshot()
				mark_disabled(str(v.get("error", "HEALTH_MISMATCH")))
				return status_snapshot()
		OS.delay_msec(250)
	on_boot_timeout()
	return status_snapshot()


static func _probe_fixed_sync() -> void:
	_mode = "FIXED"
	var parsed := _parse_url(OS.get_environment("JEV_SHADOW_URL").strip_edges())
	_host = str(parsed[0])
	_port = int(parsed[1])
	_owned = false
	_pid = -1
	var res := _http_get(_host, _port, "/health", FIXED_PROBE_TIMEOUT_MS)
	if not bool(res.get("ok", false)):
		mark_disabled("FIXED_UNREACHABLE: %s" % str(res.get("error", "?")))
		return
	var h: Variant = JSON.parse_string(str(res.get("body", "")))
	if not h is Dictionary:
		mark_disabled("FIXED_BAD_HEALTH_JSON")
		return
	var v := verify_health_dict(h)
	if not bool(v.get("ok", false)):
		mark_disabled("FIXED_IDENTITY_MISMATCH: %s" % str(v.get("error", "?")))
		return
	_started_msec = Time.get_ticks_msec()
	_started_unix_s = Time.get_unix_time_from_system()
	_startup_latency_ms = 0.0
	_identity = v.get("identity", {})
	_status = "READY"
	_last_error = ""
	print("[JEVLAUNCH] fixed worker READY (reused, not owned) %s:%d pid=%s" % [_host, _port, str(_identity.get("pid", "?"))])


static func fixed_endpoint() -> Dictionary:
	var parsed := _parse_url(OS.get_environment("JEV_SHADOW_URL").strip_edges())
	return {"host": str(parsed[0]), "port": int(parsed[1])}


## Adopt an already-verified fixed endpoint (async autoload path).
static func adopt_fixed_health(identity: Dictionary, host: String, port: int) -> void:
	_mode = "FIXED"
	_host = host
	_port = port
	_owned = false
	_pid = int(identity.get("pid", -1))
	_started_msec = Time.get_ticks_msec()
	_started_unix_s = Time.get_unix_time_from_system()
	_startup_latency_ms = 0.0
	_identity = identity
	_status = "READY"
	_last_error = ""
	print("[JEVLAUNCH] fixed worker READY (reused, not owned) %s:%d pid=%d" % [_host, _port, _pid])


## Strict identity handshake. Shared by the sync and async boot paths.
static func verify_health_dict(h: Dictionary) -> Dictionary:
	if not bool(h.get("ok", false)):
		return {"ok": false, "error": "HEALTH_NOT_OK"}
	if str(h.get("service", "")) != "jev-shadow-worker":
		return {"ok": false, "error": "HEALTH_WRONG_SERVICE"}
	if str(h.get("status", "")) != "READY":
		return {"ok": false, "error": "HEALTH_NOT_READY"}
	if str(h.get("protocol_version", "")) != PROTOCOL_VERSION:
		return {"ok": false, "error": "PROTOCOL_MISMATCH"}
	if str(h.get("observation_schema", "")) != OBSERVATION_SCHEMA:
		return {"ok": false, "error": "OBSERVATION_SCHEMA_MISMATCH"}
	if str(h.get("mission_schema", "")) != MISSIONMAP_VERSION:
		return {"ok": false, "error": "MISSION_SCHEMA_MISMATCH"}
	if str(h.get("action_schema", "")) != ACTION_SCHEMA:
		return {"ok": false, "error": "ACTION_SCHEMA_MISMATCH"}
	var pid := int(h.get("pid", 0))
	if pid <= 0:
		return {"ok": false, "error": "HEALTH_BAD_PID"}
	var ident: Dictionary = h.get("identity", {})
	if ident.is_empty():
		return {"ok": false, "error": "HEALTH_NO_IDENTITY"}
	if str(ident.get("model_version", "")) != MODEL_IDENTITY:
		return {"ok": false, "error": "MODEL_MISMATCH"}
	if str(ident.get("checkpoint_sha256", "")).to_lower() != CHECKPOINT_SHA256.to_lower():
		return {"ok": false, "error": "CHECKPOINT_MISMATCH"}
	if str(ident.get("contract", "")) != CONTRACT_VERSION:
		return {"ok": false, "error": "CONTRACT_MISMATCH"}
	if str(ident.get("request_schema", "")) != REQUEST_VERSION:
		return {"ok": false, "error": "REQUEST_SCHEMA_MISMATCH"}
	if str(ident.get("response_schema", "")) != RESPONSE_VERSION:
		return {"ok": false, "error": "RESPONSE_SCHEMA_MISMATCH"}
	if str(ident.get("slot_map", "")) != SLOTMAP_VERSION:
		return {"ok": false, "error": "SLOTMAP_MISMATCH"}
	if str(ident.get("mission_map", "")) != MISSIONMAP_VERSION:
		return {"ok": false, "error": "MISSIONMAP_MISMATCH"}
	if not bool(ident.get("eval_mode", false)):
		return {"ok": false, "error": "WORKER_NOT_EVAL"}
	if bool(ident.get("gradients", true)):
		return {"ok": false, "error": "WORKER_GRADIENTS_ON"}
	return {"ok": true, "identity": {
		"pid": pid, "parent_pid": h.get("parent_pid", null),
		"model_version": str(ident.get("model_version", "")),
		"checkpoint_sha256": str(ident.get("checkpoint_sha256", "")).to_lower(),
		"n_parameters": int(ident.get("n_parameters", 0)),
		"uptime_s": float(h.get("uptime_s", 0.0)),
	}}


static func mark_ready(identity: Dictionary) -> void:
	_identity = identity
	_startup_latency_ms = float(Time.get_ticks_msec() - _started_msec)
	_status = "READY"
	_last_error = ""
	print("[JEVLAUNCH] Shadow READY pid=%d port=%d model=%s sha=%s latency=%.0fms owned=%s" % [
		_pid, _port, MODEL_IDENTITY,
		str(_identity.get("checkpoint_sha256", "")).left(12),
		_startup_latency_ms, str(_owned)])


static func mark_disabled(error: String) -> void:
	# Never orphan a worker we spawned: if it is still alive while BOOTING,
	# terminate exactly that PID (fail-open for the game, clean for the OS).
	if _status == "BOOTING" and _owned and _pid > 0 and OS.is_process_running(_pid):
		OS.kill(_pid)
		var deadline := Time.get_ticks_msec() + 3000
		while Time.get_ticks_msec() < deadline and OS.is_process_running(_pid):
			OS.delay_msec(100)
	_status = "DISABLED"
	_last_error = error.left(300)
	_token = ""
	push_warning("[JEVLAUNCH] Shadow DISABLED: %s (game continues deterministically)" % _last_error)


static func on_boot_timeout() -> void:
	if _status == "BOOTING":
		mark_disabled("STARTUP_TIMEOUT")


## Graceful owned shutdown: token-authenticated /shutdown, then exact-PID
## kill as a bounded fallback. Never touches a non-owned process.
static func shutdown_owned() -> Dictionary:
	if not _owned or _pid <= 0:
		return {"stopped": false, "reason": "NOT_OWNED", "orphan": false,
			"pid": _pid, "owned": _owned}
	var pid := _pid
	if not OS.is_process_running(pid):
		_reset_to_cold()
		return {"stopped": true, "method": "ALREADY_EXITED", "orphan": false, "pid": pid}
	var method := "GRACEFUL"
	if not _token.is_empty():
		var res := _http_post(_host, _port, "/shutdown",
			JSON.stringify({"token": _token}), SHUTDOWN_TIMEOUT_MS)
		if not bool(res.get("ok", false)):
			method = "KILL_AFTER_GRACEFUL_FAIL"
	var deadline := Time.get_ticks_msec() + SHUTDOWN_TIMEOUT_MS
	while Time.get_ticks_msec() < deadline and OS.is_process_running(pid):
		OS.delay_msec(100)
	if OS.is_process_running(pid):
		method = "KILL" if method == "GRACEFUL" else method
		OS.kill(pid)
		deadline = Time.get_ticks_msec() + SHUTDOWN_TIMEOUT_MS
		while Time.get_ticks_msec() < deadline and OS.is_process_running(pid):
			OS.delay_msec(100)
	var orphan := OS.is_process_running(pid)
	_reset_to_cold()
	print("[JEVLAUNCH] owned worker pid=%d stopped=%s method=%s orphan=%s" % [pid, str(not orphan), method, str(orphan)])
	return {"stopped": not orphan, "method": method, "orphan": orphan, "pid": pid}


static func _reset_to_cold() -> void:
	_status = "COLD"
	_owned = false
	_pid = -1
	_token = ""
	_identity = {}
	_startup_latency_ms = -1.0


# --- Python discovery (deterministic order, pythonw preferred for hidden) ---

static func discover_python() -> Dictionary:
	var explicit := OS.get_environment("JEV_SHADOW_PYTHON").strip_edges()
	if not explicit.is_empty():
		if FileAccess.file_exists(explicit):
			return {"found": true, "path": explicit, "source": "JEV_SHADOW_PYTHON"}
		return {"found": false, "path": "", "source": "",
			"error": "JEV_SHADOW_PYTHON missing: %s" % explicit}
	var proj := ProjectSettings.globalize_path("res://")
	for rel in [".venv/Scripts/pythonw.exe", ".venv/Scripts/python.exe",
			".venv/bin/python3", ".venv/bin/python"]:
		var p: String = proj.rstrip("/\\") + "/" + rel
		if FileAccess.file_exists(p):
			return {"found": true, "path": p, "source": "PROJECT_VENV"}
	var local := OS.get_environment("LOCALAPPDATA").strip_edges()
	if not local.is_empty():
		for ver in ["Python313", "Python312", "Python311"]:
			for exe in ["pythonw.exe", "python.exe"]:
				var q: String = local.rstrip("/\\") + "/Programs/Python/%s/%s" % [ver, exe]
				if FileAccess.file_exists(q):
					return {"found": true, "path": q, "source": "LOCALAPPDATA_" + ver}
	var pathenv := OS.get_environment("PATH")
	if not pathenv.strip_edges().is_empty():
		for exe in ["pythonw.exe", "python.exe"]:
			for d in pathenv.split(";"):
				var dir := d.strip_edges().trim_suffix("/").trim_suffix("\\")
				if dir.is_empty():
					continue
				var t: String = dir + "/" + exe
				if FileAccess.file_exists(t):
					return {"found": true, "path": t, "source": "PATH"}
	return {"found": false, "path": "", "source": "",
		"error": "no usable python (venv, LOCALAPPDATA, PATH all empty)"}


# --- Dynamic localhost port (fixed 11439 first, then ephemeral scan) ---

static func pick_port() -> int:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var cands: Array = [DEFAULT_PORT]
	for _i in range(8):
		cands.append(rng.randi_range(49152, 65535))
	for c in cands:
		var port := int(c)
		var srv := TCPServer.new()
		var err := srv.listen(port, HOST)
		srv.stop()
		if err == OK:
			return port
	return -1


static func _parse_url(url: String) -> Array:
	var s := url.strip_edges()
	if s.begins_with("http://"):
		s = s.substr(7)
	elif s.begins_with("https://"):
		s = s.substr(8)
	s = s.rstrip("/")
	var host := HOST
	var port := DEFAULT_PORT
	if s.contains(":"):
		var parts := s.split(":")
		host = parts[0]
		port = int(parts[1]) if parts.size() > 1 and parts[1].is_valid_int() else DEFAULT_PORT
	elif not s.is_empty():
		host = s
	return [host, port]


static func _prepare_worker_log() -> void:
	_worker_log = ""
	var global := ProjectSettings.globalize_path(WORKER_LOG_REL)
	var err := DirAccess.make_dir_recursive_absolute(global.get_base_dir())
	if err == OK:
		_worker_log = global


static func _new_token() -> String:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var out := ""
	for _i in range(32):
		out += "%x" % rng.randi_range(0, 15)
	return out


static func _started_unix() -> float:
	return _started_unix_s


# --- Blocking bounded HTTP helpers (mirror Cloud2JevShadow transport) ---

static func _http_get(host: String, port: int, path: String, timeout_ms: int) -> Dictionary:
	return _http_request(HTTPClient.METHOD_GET, host, port, path, "", timeout_ms)


static func _http_post(host: String, port: int, path: String, body: String,
	timeout_ms: int) -> Dictionary:
	return _http_request(HTTPClient.METHOD_POST, host, port, path, body, timeout_ms)


static func _http_request(method: int, host: String, port: int, path: String,
	body: String, timeout_ms: int) -> Dictionary:
	var deadline := Time.get_ticks_msec() + timeout_ms
	var http := HTTPClient.new()
	var err := http.connect_to_host(host, port)
	if err != OK:
		return {"ok": false, "error": "CONNECT_FAIL: %s" % error_string(err)}
	while true:
		if Time.get_ticks_msec() > deadline:
			http.close()
			return {"ok": false, "error": "TIMEOUT_CONNECT"}
		http.poll()
		var st := http.get_status()
		if st == HTTPClient.STATUS_CONNECTED:
			break
		if st != HTTPClient.STATUS_RESOLVING and st != HTTPClient.STATUS_CONNECTING:
			http.close()
			return {"ok": false, "error": "CONNECT_STATUS_%d" % st}
		OS.delay_msec(5)
	if method == HTTPClient.METHOD_POST:
		err = http.request(method, path,
			PackedStringArray(["Content-Type: application/json"]), body)
	else:
		err = http.request(method, path, PackedStringArray([]), "")
	if err != OK:
		http.close()
		return {"ok": false, "error": "REQUEST_FAIL: %s" % error_string(err)}
	while http.get_status() == HTTPClient.STATUS_REQUESTING:
		if Time.get_ticks_msec() > deadline:
			http.close()
			return {"ok": false, "error": "TIMEOUT_REQUEST"}
		http.poll()
		OS.delay_msec(5)
	if http.get_response_code() != 200:
		http.close()
		return {"ok": false, "error": "HTTP_%d" % http.get_response_code()}
	var chunks := PackedByteArray()
	while http.get_status() == HTTPClient.STATUS_BODY:
		if Time.get_ticks_msec() > deadline:
			http.close()
			return {"ok": false, "error": "TIMEOUT_BODY"}
		http.poll()
		var chunk := http.read_response_body_chunk()
		if chunk.size() > 0:
			chunks.append_array(chunk)
		else:
			OS.delay_msec(2)
	http.close()
	return {"ok": true, "body": chunks.get_string_from_utf8()}
