class_name LayaLauncher
extends RefCounted

## LAYA LIVE V0 — owned local inference process lifecycle.
##
## Godot owns the Laya worker completely (discover Python, pick a localhost
## port, spawn a hidden child, verify identity via a strict health handshake,
## terminate exactly that worker on scene exit). The user never runs Python
## manually.
##
## Modes:
##   AUTO (default, LAYA_ENABLE unset or "1", no LAYA_URL):
##     spawn an owned hidden worker on a dynamic port.
##   FIXED (LAYA_URL set): never spawn; handshake the given endpoint
##     and reuse it only when identity matches. Never killed on exit.
##   OFF (LAYA_ENABLE == "0"): no spawn, no HTTP. The Laya battle
##     mode refuses to run RED via Laya (explicit blocked state).
##
## Env overrides:
##   LAYA_PYTHON, LAYA_URL, LAYA_ENABLE,
##   LAYA_STARTUP_TIMEOUT_MS, LAYA_MODEL_DIR, LAYA_DEVICE (cuda).

const HttpCls = preload("res://scripts/laya/laya_http.gd")

const MODEL_IDENTITY := "laya-multilingual-322m"
const MODEL_REPO := "convaiinnovations/laya-multilingual"
const MODEL_REV := "052592a15d198d9ad47da779604259b10b47b7aa"
const EXPECTED_PARAMS := 321908995
## Operational context budgets (RECORDED OVERRIDE of checkpoint defaults
## 1024/256): backbone is ModernBERT/RoPE with max_position_embeddings=8192
## (verified in encoder/config.json), so 2048 inference positions are
## natively supported. The default 256-token head budget mechanically
## destroyed per-unit option text (squeeze to 4-7 tokens/option for 31-57
## option sets); 1024 head fits complete per-unit sets. Tokenization
## parameters only — no weight/architecture change. No silent truncation:
## every decision logs full token telemetry via the worker.
const EXPECTED_MAX_LEN := 2048
const EXPECTED_HEAD_MAX_LEN := 1024
const TEMPLATE_VERSION := "L2"
const PROTOCOL_VERSION := "laya-protocol-v1"
const REQUEST_VERSION := "laya-unit-choice-v1"
const RESPONSE_VERSION := "laya-unit-choice-response-v1"
const GROUP_REQUEST_VERSION := "laya-group-choice-v1"
const GROUP_RESPONSE_VERSION := "laya-group-choice-response-v1"

const HOST := "127.0.0.1"
const DEFAULT_PORT := 11442
const DEFAULT_STARTUP_TIMEOUT_MS := 240000
const FIXED_PROBE_TIMEOUT_MS := 5000
const HEALTH_SLICE_TIMEOUT_MS := 4000
const SHUTDOWN_TIMEOUT_MS := 8000
const WORKER_REL_PATH := "res://tools/laya/worker.py"
const DEFAULT_MODEL_DIR := "D:/LayaRuntime/models/laya-multilingual"
const DEFAULT_WORKER_LOG := "D:/LayaRuntime/logs/laya-worker.log"

## CLOUD FULL PIPELINE V0: HANDS_AB profile = frozen Hand A + Hand B in one
## owned worker (tools/cloud_pipeline/hands_worker.py). Same spawn / port /
## health / shutdown lifecycle; only the script and identity handshake differ.
## The default LAYA profile is untouched.
const PROFILE_LAYA := "LAYA"
const PROFILE_HANDS_AB := "HANDS_AB"
const HANDS_WORKER_REL_PATH := "res://tools/cloud_pipeline/hands_worker.py"
const HANDS_SERVICE := "hands-ab-worker"
const HANDS_PROTOCOL_VERSION := "hands-ab-protocol-v0"
const HANDS_IDENTITY := "hand_a_v1_best+hand_b_v1_final"
const HAND_A_DIR_REL := "res://artifacts/laya_hand_a_v1/run1/checkpoints/best"
const HAND_B_DIR_REL := "res://artifacts/laya_hand_b_v1/run1/final"
const HAND_A_SHA256 := "0bf9324be4220fa845555c32e64dd089d74cb578d5e19913b37b90a1c67fd719"
const HAND_B_SHA256 := "4ef88372aeb55fdbd6f5c471c6a0fafa2d3f5c9cdd37f5ae373b0cf0a2693ca9"
const HANDS_WORKER_LOG := "D:/LayaRuntime/logs/hands-ab-worker.log"

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
static var _load_info := {}
static var _last_error := ""
static var _token := ""
static var _worker_log := ""
static var _started_unix_s := 0.0
static var _profile := PROFILE_LAYA


## Switch this process to the frozen Hand A + Hand B worker. Must be called
## before the first spawn (a live worker of the other profile is refused).
static func use_hands_ab_profile() -> bool:
	if _profile == PROFILE_HANDS_AB:
		return true
	if _status == "READY" or _status == "BOOTING":
		push_warning("[LAYALAUNCH] cannot switch profile while a %s worker is %s" % [_profile, _status])
		return false
	_profile = PROFILE_HANDS_AB
	_status = "COLD"
	_last_error = ""
	return true


static func profile() -> String:
	return _profile


static func model_label() -> String:
	return HANDS_IDENTITY if _profile == PROFILE_HANDS_AB else MODEL_IDENTITY


static func auto_enabled() -> bool:
	return OS.get_environment("LAYA_ENABLE").strip_edges() != "0"


static func fixed_url_mode() -> bool:
	return not OS.get_environment("LAYA_URL").strip_edges().is_empty()


static func startup_timeout_ms() -> int:
	if OS.has_environment("LAYA_STARTUP_TIMEOUT_MS"):
		return clampi(int(OS.get_environment("LAYA_STARTUP_TIMEOUT_MS")),
			10000, 900000)
	return DEFAULT_STARTUP_TIMEOUT_MS


static func model_dir() -> String:
	var override := OS.get_environment("LAYA_MODEL_DIR").strip_edges()
	if not override.is_empty():
		return override
	return DEFAULT_MODEL_DIR


static func device_name() -> String:
	var d := OS.get_environment("LAYA_DEVICE").strip_edges().to_lower()
	return d if not d.is_empty() else "cuda"


static func is_ready() -> bool:
	return _status == "READY"


static func is_disabled() -> bool:
	return _status == "DISABLED"


static func boot_in_progress() -> bool:
	return _status == "BOOTING"


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
		"model_dir": model_dir(), "device": device_name(),
		"started_unix": _started_unix_s, "startup_latency_ms": _startup_latency_ms,
		"model": model_label(),
		"model_rev": MODEL_REV if _profile == PROFILE_LAYA else HAND_A_SHA256.left(12) + "/" + HAND_B_SHA256.left(12),
		"profile": _profile,
		"protocol_version": PROTOCOL_VERSION if _profile == PROFILE_LAYA else HANDS_PROTOCOL_VERSION,
		"request_schema": REQUEST_VERSION, "response_schema": RESPONSE_VERSION,
		"template_version": TEMPLATE_VERSION,
		"worker_identity": _identity.duplicate(true),
		"load_info": _load_info.duplicate(true),
		"worker_up": OS.is_process_running(_pid) if _pid > 0 else false,
		"worker_log": _worker_log,
		"last_error": _last_error,
	}


## Idempotent blocking entry point for synchronous harnesses.
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


## Fast non-blocking part for the mount: discover + spawn, then return
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
	var hands := _profile == PROFILE_HANDS_AB
	var worker_global := ProjectSettings.globalize_path(HANDS_WORKER_REL_PATH if hands else WORKER_REL_PATH)
	if not FileAccess.file_exists(worker_global):
		mark_disabled("WORKER_SCRIPT_MISSING")
		return {"ok": false, "error": "WORKER_SCRIPT_MISSING"}
	if hands:
		for d in [HAND_A_DIR_REL, HAND_B_DIR_REL]:
			if not FileAccess.file_exists(ProjectSettings.globalize_path(d) + "/model.safetensors"):
				mark_disabled("HAND_CHECKPOINT_MISSING: " + d)
				return {"ok": false, "error": "HAND_CHECKPOINT_MISSING"}
	elif not FileAccess.file_exists(model_dir() + "/model.safetensors"):
		mark_disabled("MODEL_WEIGHTS_MISSING: " + model_dir())
		return {"ok": false, "error": "MODEL_WEIGHTS_MISSING"}
	var port := pick_port()
	if port < 0:
		mark_disabled("NO_FREE_PORT")
		return {"ok": false, "error": "NO_FREE_PORT"}
	_prepare_worker_log()
	_token = _new_token()
	var args := PackedStringArray([
		"-u", worker_global,
		"--host", HOST, "--port", str(port),
		"--device", device_name(),
		"--parent-pid", str(OS.get_process_id()),
		"--shutdown-token", _token,
	])
	if not hands:
		args.append_array(PackedStringArray(["--model-dir", model_dir()]))
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
	print("[LAYALAUNCH] spawned owned worker pid=%d port=%d python=%s profile=%s model=%s" % [pid, port, _python_source, _profile,
		model_label() if hands else model_dir()])
	return {"ok": true, "status": "BOOTING", "pid": pid, "port": port}


## Blocking health wait for an already-spawned worker. Bounded by deadline.
static func await_ready_sync(deadline_msec: int) -> Dictionary:
	while Time.get_ticks_msec() < deadline_msec:
		if _status != "BOOTING":
			return status_snapshot()
		if _owned and _pid > 0 and not OS.is_process_running(_pid):
			mark_disabled("WORKER_DIED_DURING_BOOT")
			return status_snapshot()
		var res := HttpCls.get_json(_host, _port, "/health", HEALTH_SLICE_TIMEOUT_MS)
		if _status != "BOOTING":
			return status_snapshot()
		if bool(res.get("ok", false)):
			var parsed: Variant = JSON.parse_string(str(res.get("body", "")))
			if parsed is Dictionary:
				var v := verify_health_dict(parsed)
				if bool(v.get("ok", false)):
					mark_ready(v.get("identity", {}), (parsed as Dictionary).get("load", {}))
					return status_snapshot()
				mark_disabled(str(v.get("error", "HEALTH_MISMATCH")))
				return status_snapshot()
		OS.delay_msec(500)
	on_boot_timeout()
	return status_snapshot()


static func _probe_fixed_sync() -> void:
	_mode = "FIXED"
	var parsed := _parse_url(OS.get_environment("LAYA_URL").strip_edges())
	_host = str(parsed[0])
	_port = int(parsed[1])
	_owned = false
	_pid = -1
	var res := HttpCls.get_json(_host, _port, "/health", FIXED_PROBE_TIMEOUT_MS)
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
	_load_info = (h as Dictionary).get("load", {})
	_status = "READY"
	_last_error = ""
	print("[LAYALAUNCH] fixed worker READY (reused, not owned) %s:%d" % [_host, _port])


static func fixed_endpoint() -> Dictionary:
	var parsed := _parse_url(OS.get_environment("LAYA_URL").strip_edges())
	return {"host": str(parsed[0]), "port": int(parsed[1])}


## Adopt an already-verified fixed endpoint (async mount path).
static func adopt_fixed_health(identity: Dictionary, load_info: Dictionary, host: String, port: int) -> void:
	_mode = "FIXED"
	_host = host
	_port = port
	_owned = false
	_pid = int(identity.get("pid", -1))
	_started_msec = Time.get_ticks_msec()
	_started_unix_s = Time.get_unix_time_from_system()
	_startup_latency_ms = 0.0
	_identity = identity
	_load_info = load_info
	_status = "READY"
	_last_error = ""
	print("[LAYALAUNCH] fixed worker READY (reused, not owned) %s:%d pid=%d" % [_host, _port, _pid])


## Strict identity handshake. Shared by the sync and async boot paths.
## Keys must match tools/laya/worker.py LayaDecider.identity().
static func verify_health_dict(h: Dictionary) -> Dictionary:
	if _profile == PROFILE_HANDS_AB:
		return _verify_hands_health(h)
	if not bool(h.get("ok", false)):
		return {"ok": false, "error": "HEALTH_NOT_OK"}
	if str(h.get("service", "")) != "laya-worker":
		return {"ok": false, "error": "HEALTH_WRONG_SERVICE"}
	if str(h.get("status", "")) != "READY":
		return {"ok": false, "error": "HEALTH_NOT_READY"}
	if str(h.get("protocol_version", "")) != PROTOCOL_VERSION:
		return {"ok": false, "error": "PROTOCOL_MISMATCH"}
	var pid := int(h.get("pid", 0))
	if pid <= 0:
		return {"ok": false, "error": "HEALTH_BAD_PID"}
	var ident: Dictionary = h.get("identity", {})
	if ident.is_empty():
		return {"ok": false, "error": "HEALTH_NO_IDENTITY"}
	if str(ident.get("model", "")) != MODEL_IDENTITY:
		return {"ok": false, "error": "MODEL_MISMATCH"}
	if str(ident.get("revision", "")) != MODEL_REV:
		return {"ok": false, "error": "MODEL_REV_MISMATCH"}
	if int(ident.get("n_parameters", -1)) != EXPECTED_PARAMS:
		return {"ok": false, "error": "PARAM_MISMATCH"}
	if int(ident.get("max_len", -1)) != EXPECTED_MAX_LEN:
		return {"ok": false, "error": "MAXLEN_MISMATCH"}
	if int(ident.get("head_max_len", -1)) != EXPECTED_HEAD_MAX_LEN:
		return {"ok": false, "error": "HEADLEN_MISMATCH"}
	if str(ident.get("template_version", "")) != TEMPLATE_VERSION:
		return {"ok": false, "error": "TEMPLATE_MISMATCH"}
	if str(ident.get("request_schema", "")) != REQUEST_VERSION:
		return {"ok": false, "error": "REQUEST_SCHEMA_MISMATCH"}
	if str(ident.get("response_schema", "")) != RESPONSE_VERSION:
		return {"ok": false, "error": "RESPONSE_SCHEMA_MISMATCH"}
	if str(ident.get("group_request_schema", "")) != GROUP_REQUEST_VERSION:
		return {"ok": false, "error": "GROUP_SCHEMA_MISMATCH"}
	if str(ident.get("group_response_schema", "")) != GROUP_RESPONSE_VERSION:
		return {"ok": false, "error": "GROUP_RESPONSE_MISMATCH"}
	if not bool(ident.get("eval", false)):
		return {"ok": false, "error": "WORKER_NOT_EVAL"}
	if not bool(ident.get("no_grad", false)):
		return {"ok": false, "error": "WORKER_GRADIENTS_ON"}
	return {"ok": true, "identity": {
		"pid": pid, "parent_pid": h.get("parent_pid", null),
		"model": MODEL_IDENTITY, "model_rev": MODEL_REV,
		"template_version": TEMPLATE_VERSION,
		"device": str(ident.get("device", "?")),
		"dtype": str(ident.get("dtype", "?")),
		"n_parameters": int(ident.get("n_parameters", 0)),
		"uptime_s": float(h.get("uptime_s", 0.0)),
	}}


## HANDS_AB handshake: service, protocol, BOTH pinned checkpoint sha256,
## 2048/1024 budgets, inference-only. Keys = hands_worker.Hands.identity().
static func _verify_hands_health(h: Dictionary) -> Dictionary:
	if not bool(h.get("ok", false)):
		return {"ok": false, "error": "HEALTH_NOT_OK"}
	if str(h.get("service", "")) != HANDS_SERVICE:
		return {"ok": false, "error": "HEALTH_WRONG_SERVICE"}
	if str(h.get("status", "")) != "READY":
		return {"ok": false, "error": "HEALTH_NOT_READY"}
	if str(h.get("protocol_version", "")) != HANDS_PROTOCOL_VERSION:
		return {"ok": false, "error": "PROTOCOL_MISMATCH"}
	var pid := int(h.get("pid", 0))
	if pid <= 0:
		return {"ok": false, "error": "HEALTH_BAD_PID"}
	var ident: Dictionary = h.get("identity", {})
	if str(ident.get("hand_a_sha256", "")) != HAND_A_SHA256:
		return {"ok": false, "error": "HAND_A_SHA_MISMATCH"}
	if str(ident.get("hand_b_sha256", "")) != HAND_B_SHA256:
		return {"ok": false, "error": "HAND_B_SHA_MISMATCH"}
	if int(ident.get("max_len", -1)) != EXPECTED_MAX_LEN or int(ident.get("head_max_len", -1)) != EXPECTED_HEAD_MAX_LEN:
		return {"ok": false, "error": "MAXLEN_MISMATCH"}
	if not bool(ident.get("eval", false)) or not bool(ident.get("no_grad", false)):
		return {"ok": false, "error": "WORKER_NOT_INFERENCE_ONLY"}
	return {"ok": true, "identity": {
		"pid": pid, "parent_pid": h.get("parent_pid", null),
		"model": HANDS_IDENTITY, "profile": PROFILE_HANDS_AB,
		"hand_a_dir": str(ident.get("hand_a_dir", "")), "hand_a_sha256": HAND_A_SHA256,
		"hand_b_dir": str(ident.get("hand_b_dir", "")), "hand_b_sha256": HAND_B_SHA256,
		"device": ident.get("device", {}),
		"log_path": str(h.get("log_path", "")),
		"uptime_s": float(h.get("uptime_s", 0.0)),
	}}


static func mark_ready(identity: Dictionary, load_info: Dictionary = {}) -> void:
	_identity = identity
	_load_info = load_info
	_startup_latency_ms = float(Time.get_ticks_msec() - _started_msec)
	_status = "READY"
	_last_error = ""
	print("[LAYALAUNCH] Laya READY pid=%d port=%d model=%s latency=%.0fms owned=%s load_s=%s vram=%s" % [
		_pid, _port, model_label(), _startup_latency_ms, str(_owned),
		str(load_info.get("load_s", "?")), str(load_info.get("vram_gb", "?"))])


static func mark_disabled(error: String) -> void:
	# Never orphan a worker we spawned: if it is still alive while BOOTING,
	# terminate exactly that PID (fail-open for the OS; the mode reports
	# the explicit blocked state, never silent deterministic play).
	if _status == "BOOTING" and _owned and _pid > 0 and OS.is_process_running(_pid):
		OS.kill(_pid)
		var deadline := Time.get_ticks_msec() + 3000
		while Time.get_ticks_msec() < deadline and OS.is_process_running(_pid):
			OS.delay_msec(100)
	_status = "DISABLED"
	_last_error = error.left(300)
	_token = ""
	push_warning("[LAYALAUNCH] Laya DISABLED: %s" % _last_error)


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
		var res := HttpCls.post_json(_host, _port, "/shutdown",
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
	print("[LAYALAUNCH] owned worker pid=%d stopped=%s method=%s orphan=%s" % [pid, str(not orphan), method, str(orphan)])
	return {"stopped": not orphan, "method": method, "orphan": orphan, "pid": pid}


static func _reset_to_cold() -> void:
	_status = "COLD"
	_owned = false
	_pid = -1
	_token = ""
	_identity = {}
	_load_info = {}
	_startup_latency_ms = -1.0


# --- Python discovery (Laya runtime first, pythonw preferred hidden) ---

static func discover_python() -> Dictionary:
	var explicit := OS.get_environment("LAYA_PYTHON").strip_edges()
	if not explicit.is_empty():
		if FileAccess.file_exists(explicit):
			return {"found": true, "path": explicit, "source": "LAYA_PYTHON"}
		return {"found": false, "path": "", "source": "",
			"error": "LAYA_PYTHON missing: %s" % explicit}
	# 1. Dedicated Laya runtime (D:\LayaRuntime\venv).
	for exe in ["pythonw.exe", "python.exe"]:
		var rt: String = "D:/LayaRuntime/venv/Scripts/" + exe
		if FileAccess.file_exists(rt):
			return {"found": true, "path": rt, "source": "LAYA_RUNTIME_VENV"}
	# 2. Project venvs.
	var proj := ProjectSettings.globalize_path("res://")
	for rel in [".venv/Scripts/pythonw.exe", ".venv/Scripts/python.exe",
			".venv/bin/python3", ".venv/bin/python"]:
		var p: String = proj.rstrip("/\\") + "/" + rel
		if FileAccess.file_exists(p):
			return {"found": true, "path": p, "source": "PROJECT_VENV"}
	var local := OS.get_environment("LOCALAPPDATA").strip_edges()
	if not local.is_empty():
		for ver in ["Python313", "Python312", "Python311"]:
			for exe2 in ["pythonw.exe", "python.exe"]:
				var q: String = local.rstrip("/\\") + "/Programs/Python/%s/%s" % [ver, exe2]
				if FileAccess.file_exists(q):
					return {"found": true, "path": q, "source": "LOCALAPPDATA_" + ver}
	var pathenv := OS.get_environment("PATH")
	if not pathenv.strip_edges().is_empty():
		for exe3 in ["pythonw.exe", "python.exe"]:
			for d in pathenv.split(";"):
				var dir := d.strip_edges().trim_suffix("/").trim_suffix("\\")
				if dir.is_empty():
					continue
				var t: String = dir + "/" + exe3
				if FileAccess.file_exists(t):
					return {"found": true, "path": t, "source": "PATH"}
	return {"found": false, "path": "", "source": "",
		"error": "no usable python (laya runtime, project venvs, LOCALAPPDATA, PATH all empty)"}


# --- Dynamic localhost port (fixed 11442 first, then ephemeral scan) ---

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
	var want := HANDS_WORKER_LOG if _profile == PROFILE_HANDS_AB else DEFAULT_WORKER_LOG
	var err := DirAccess.make_dir_recursive_absolute(want.get_base_dir())
	if err == OK:
		_worker_log = want
		return
	var fallback := ProjectSettings.globalize_path("res://artifacts/laya_live_integration_v0/worker.log")
	if DirAccess.make_dir_recursive_absolute(fallback.get_base_dir()) == OK:
		_worker_log = fallback


static func _new_token() -> String:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var out := ""
	for _i in range(32):
		out += "%x" % rng.randi_range(0, 15)
	return out
