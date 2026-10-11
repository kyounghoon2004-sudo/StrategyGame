class_name Cloud2LocalBrainLauncher
extends RefCounted

## LOCAL BRAIN (Qwen3-8B CSFT5) — Godot-owned server lifecycle.
##
## Used ONLY by the "DEV: Human vs Local (Qwen 8B)" mode. The game owns the
## local Brain completely (same contract as the Laya worker): if a server
## with the VERIFIED CSFT5 identity already answers on 127.0.0.1:8096 it is
## reused and never killed; otherwise a hidden worker is spawned
## (tools/contract_sft/brain_server.py), polled until /health reports the
## CSFT5 adapter sha256, and shut down gracefully (/admin/shutdown, which
## releases the GPU lock) when the scene exits. Any identity mismatch
## (e.g. CSFT6) -> DISABLED; the game never talks to an unverified model.
##
## The server itself generates text only; the game's production packet
## builder, system prompt, parser, validator and adoption stay authoritative.

const HttpCls = preload("res://scripts/laya/laya_http.gd")

const HOST := "127.0.0.1"
## 2026-10-06: WATCH_BRAIN_PORT moves it (a second data collector runs its own proxy in parallel).
static var PORT: int = _port_from_env()
static var ENDPOINT: String = "http://127.0.0.1:%d/v1/chat/completions" % PORT


static func _port_from_env() -> int:
	var v := OS.get_environment("WATCH_BRAIN_PORT").strip_edges()
	return int(v) if v.is_valid_int() and int(v) > 0 else 8096
const MODEL_ID := "csft5"
const LABEL := "Local Qwen3-8B (CSFT5)"
const CSFT5_SHA256 := "d82e5369be7bb2155c7eda537a79316734743061458f4254977cc6053e92b4ae"
const CSFT6_SHA256 := "546d2b1e9a88ddd223e60b27f393530b15a6163163838018741f983c7d5a4635"
const PY_CANDIDATES := ["D:/StrategyAI/runtimes/qwen3_8b_rl_v0/.venv/Scripts/pythonw.exe",
	"D:/StrategyAI/runtimes/qwen3_8b_rl_v0/.venv/Scripts/python.exe"]
const SERVER_REL := "res://tools/contract_sft/brain_server.py"
## Adapter selection: env LOCAL_BRAIN_ADAPTER (unset/"csft5" = CSFT5, the default production identity).
## Each entry pins the expected adapter sha; the server refuses anything else.
const ADAPTER_ENV := "LOCAL_BRAIN_ADAPTER"
const ADAPTERS := {
	"csft5": {"dir": "res://artifacts/contract_sft_v1/candidate_CSFT5", "sha": CSFT5_SHA256},
	"s0b": {"dir": "res://artifacts/contextual_brain_s0b/candidate_S0B",
		"sha": "32029f7acf0bdac257e38a4a72d550697c15cd17184b00791eeb322b7e65205b"},
	# External RL policy server (tools/contextual_brain/rl_vs_utility.py): never spawned by the game;
	# accepted only when /health reports label RL_POLICY and the session token in env RL_SESSION.
	"rl_policy": {"dir": "", "sha": "", "external": true},
}


static func selected_adapter() -> String:
	var a := OS.get_environment(ADAPTER_ENV).strip_edges().to_lower()
	return a if ADAPTERS.has(a) else "csft5"
const STARTUP_TIMEOUT_MS := 240000

# COLD | BOOTING | READY | DISABLED
static var _status := "COLD"
static var _owned := false
static var _pid := -1
static var _identity := {}
static var _error := ""
static var _session := ""


static func status_snapshot() -> Dictionary:
	return {"status": _status, "owned": _owned, "pid": _pid, "error": _error, "session": _session,
		"label": str(_identity.get("label", "")), "adapter_sha256": str(_identity.get("adapter_sha256", "")),
		"calls": int(_identity.get("calls", 0))}


## GET /health (blocking, bounded). Returns the identity dict or {}.
static func probe_identity(timeout_ms: int = 3000) -> Dictionary:
	var res: Dictionary = HttpCls.get_json(HOST, PORT, "/health", timeout_ms)
	if not bool(res.get("ok", false)):
		return {}
	var parsed: Variant = JSON.parse_string(str(res.get("body", "")))
	return parsed if parsed is Dictionary else {}


static func identity_ok(ident: Dictionary) -> bool:
	if bool(ADAPTERS[selected_adapter()].get("external", false)):
		var token := OS.get_environment("RL_SESSION").strip_edges()
		return not token.is_empty() and str(ident.get("label", "")) == "RL_POLICY" and str(ident.get("rl_session", "")) == token
	var sha := str(ident.get("adapter_sha256", ""))
	return sha == str(ADAPTERS[selected_adapter()]["sha"]) and sha != CSFT6_SHA256 and not bool(ident.get("adapter_is_csft6", true))


## Reuse a verified running server or spawn an owned one (non-blocking).
## Returns {ok, status, error}. Caller then polls poll_ready().
static func start() -> Dictionary:
	if _status == "READY" or _status == "BOOTING":
		return {"ok": true, "status": _status}
	var ident := probe_identity(2000)
	if not ident.is_empty():
		if identity_ok(ident):
			_identity = ident
			_owned = false
			_status = "READY"
			print("[LocalBrain] reusing running CSFT5 server (not owned) sha=%s" % str(ident.get("adapter_sha256", "")))
			return {"ok": true, "status": _status}
		_status = "DISABLED"
		_error = "IDENTITY_MISMATCH: port %d serves adapter %s (not CSFT5)" % [PORT, str(ident.get("adapter_sha256", "?"))]
		push_warning("[LocalBrain] %s" % _error)
		return {"ok": false, "status": _status, "error": _error}
	if bool(ADAPTERS[selected_adapter()].get("external", false)):
		_status = "DISABLED"
		_error = "EXTERNAL_POLICY_SERVER_NOT_RUNNING on port %d" % PORT
		return {"ok": false, "status": _status, "error": _error}
	var py := ""
	for c in PY_CANDIDATES:
		if FileAccess.file_exists(c):
			py = c
			break
	if py.is_empty():
		_status = "DISABLED"
		_error = "NO_RL_RUNTIME_PYTHON"
		return {"ok": false, "status": _status, "error": _error}
	# LOCAL_BRAIN_SESSION (set by tools/contract_sft/launch_csft5_human_test.ps1)
	# puts server telemetry next to the captured game log for the report join.
	_session = OS.get_environment("LOCAL_BRAIN_SESSION").strip_edges()
	if _session.is_empty():
		_session = "hvl_" + Time.get_datetime_string_from_system(false, true).replace("-", "").replace(":", "").replace(" ", "_")
	var args := PackedStringArray([ProjectSettings.globalize_path(SERVER_REL), "--port", str(PORT), "--session", _session,
		"--adapter", ProjectSettings.globalize_path(str(ADAPTERS[selected_adapter()]["dir"]))])
	_pid = OS.create_process(py, args, false)
	if _pid <= 0:
		_status = "DISABLED"
		_error = "SPAWN_FAILED"
		return {"ok": false, "status": _status, "error": _error}
	_owned = true
	_status = "BOOTING"
	print("[LocalBrain] spawned owned CSFT5 server pid=%d session=%s" % [_pid, _session])
	return {"ok": true, "status": _status}


## One bounded readiness check (call repeatedly from an async loop).
static func poll_ready() -> String:
	if _status != "BOOTING":
		return _status
	if _owned and _pid > 0 and not OS.is_process_running(_pid):
		_status = "DISABLED"
		_error = "SERVER_EXITED_DURING_BOOT (see artifacts/contract_sft_v1/human_benchmark/%s/server.log)" % _session
		return _status
	var ident := probe_identity(1500)
	if ident.is_empty():
		return _status
	if not identity_ok(ident):
		_status = "DISABLED"
		_error = "IDENTITY_MISMATCH: %s" % str(ident.get("adapter_sha256", "?"))
		shutdown_owned()
		return _status
	_identity = ident
	_status = "READY"
	print("[LocalBrain] READY label=%s sha=%s owned=%s" % [str(ident.get("label", "")),
		str(ident.get("adapter_sha256", "")), str(_owned)])
	return _status


static func refresh_identity() -> void:
	if _status == "READY":
		var ident := probe_identity(800)
		if not ident.is_empty():
			_identity = ident


## Graceful stop of an OWNED server only (reused servers are never touched).
static func shutdown_owned() -> Dictionary:
	if not _owned or _pid <= 0:
		return {"owned": false}
	var pid := _pid
	HttpCls.post_json(HOST, PORT, "/admin/shutdown", "{}", 3000)
	var deadline := Time.get_ticks_msec() + 8000
	while Time.get_ticks_msec() < deadline and OS.is_process_running(pid):
		OS.delay_msec(100)
	var forced := false
	if OS.is_process_running(pid):
		OS.kill(pid)
		forced = true
	_owned = false
	_pid = -1
	_status = "COLD"
	return {"owned": true, "pid": pid, "forced": forced}
