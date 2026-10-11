class_name Cloud2JevRuntime
extends Node

## JEV SINGLE-LAUNCH AUTOLOAD (SHADOW ONLY) — "JevShadowRuntime".
##
## Boots the owned JEV worker when the game starts and stops exactly that
## worker when the game exits. Boot is non-blocking: the child process is
## spawned synchronously (milliseconds) and the health handshake is polled
## asynchronously across frames, so game startup never stalls on PyTorch.
## Any failure degrades to SHADOW_DISABLED; authoritative gameplay is
## untouched. On tree exit the owned worker is shut down gracefully with a
## bounded exact-PID kill fallback. A crashed game is covered by the
## worker-side parent-PID monitor.

const LauncherCls = preload("res://scripts/cloud2/cloud2_jev_launcher.gd")

const POLL_INTERVAL_SEC := 0.5
const PROBE_TIMEOUT_SEC := 4.0

var _boot_task := 0


func _ready() -> void:
	if not LauncherCls.auto_enabled():
		return
	# Another path (e.g. a synchronous SceneTree entry) may already have
	# booted, readied, or disabled the runtime; never double-spawn.
	if str(LauncherCls.status_snapshot().get("status", "COLD")) != "COLD":
		return
	if LauncherCls.fixed_url_mode():
		_boot_task += 1
		_boot_fixed_async(_boot_task)
		return
	var spawned: Dictionary = LauncherCls.spawn_owned_or_fixed()
	if not bool(spawned.get("ok", false)):
		return
	if str(spawned.get("status", "")) == "READY":
		return
	_boot_task += 1
	_boot_owned_async(_boot_task)


func _exit_tree() -> void:
	_boot_task += 1
	var res: Dictionary = LauncherCls.shutdown_owned()
	if bool(res.get("orphan", false)):
		push_warning("[JEVRUNTIME] owned worker pid=%s did not exit; orphan=%s" % [
			str(res.get("pid", "?")), str(res.get("orphan", true))])


func shadow_status() -> Dictionary:
	return LauncherCls.status_snapshot()


func _boot_fixed_async(my: int) -> void:
	# Fixed-URL mode: bounded async handshake across frames, never spawn,
	# never own, never kill. Identity mismatch fails closed immediately.
	var deadline := Time.get_ticks_msec() + LauncherCls.FIXED_PROBE_TIMEOUT_MS * 3
	while Time.get_ticks_msec() < deadline:
		if my != _boot_task:
			return
		if LauncherCls.is_ready() or LauncherCls.is_disabled():
			return
		var ep: Dictionary = LauncherCls.fixed_endpoint()
		var res: Dictionary = await _http_get_json(
			str(ep.get("host", "127.0.0.1")), int(ep.get("port", 11439)),
			"/health", PROBE_TIMEOUT_SEC)
		if my != _boot_task:
			return
		if LauncherCls.is_ready() or LauncherCls.is_disabled():
			return
		if bool(res.get("ok", false)) and res.get("body", {}) is Dictionary:
			var v: Dictionary = LauncherCls.verify_health_dict(res.get("body", {}))
			if bool(v.get("ok", false)):
				LauncherCls.adopt_fixed_health(
					v.get("identity", {}), str(ep.get("host", "")),
					int(ep.get("port", 11439)))
				return
			LauncherCls.mark_disabled("FIXED_IDENTITY_MISMATCH: %s" % str(v.get("error", "?")))
			return
		await get_tree().create_timer(POLL_INTERVAL_SEC).timeout
	LauncherCls.mark_disabled("FIXED_UNREACHABLE")


func _boot_owned_async(my: int) -> void:
	var deadline := Time.get_ticks_msec() + LauncherCls.startup_timeout_ms()
	while Time.get_ticks_msec() < deadline:
		if my != _boot_task:
			return
		if LauncherCls.is_ready() or LauncherCls.is_disabled():
			return
		if not LauncherCls.boot_in_progress():
			return
		if not LauncherCls.owned_pid_alive():
			LauncherCls.mark_disabled("WORKER_DIED_DURING_BOOT")
			return
		var snap: Dictionary = LauncherCls.status_snapshot()
		var res: Dictionary = await _http_get_json(
			str(snap.get("host", "127.0.0.1")), int(snap.get("port", 11439)),
			"/health", PROBE_TIMEOUT_SEC)
		if my != _boot_task:
			return
		if LauncherCls.is_ready() or LauncherCls.is_disabled():
			return
		if not LauncherCls.boot_in_progress():
			return
		if bool(res.get("ok", false)) and res.get("body", {}) is Dictionary:
			var v: Dictionary = LauncherCls.verify_health_dict(res.get("body", {}))
			if bool(v.get("ok", false)):
				LauncherCls.mark_ready(v.get("identity", {}))
				return
			LauncherCls.mark_disabled(str(v.get("error", "HEALTH_MISMATCH")))
			return
		await get_tree().create_timer(POLL_INTERVAL_SEC).timeout
	LauncherCls.on_boot_timeout()


func _http_get_json(host: String, port: int, path: String,
	timeout_sec: float) -> Dictionary:
	var http := HTTPRequest.new()
	http.timeout = maxf(2.0, timeout_sec)
	add_child(http)
	var err := http.request("http://%s:%d%s" % [host, port, path],
		PackedStringArray(["Accept: application/json"]), HTTPClient.METHOD_GET)
	if err != OK:
		http.queue_free()
		return {"ok": false, "error": "REQUEST_FAIL_%d" % err}
	var res: Array = await http.request_completed
	if not is_instance_valid(http):
		return {"ok": false, "error": "FREED_DURING_REQUEST"}
	http.queue_free()
	if res.size() < 4:
		return {"ok": false, "error": "BAD_RESULT_SHAPE"}
	if int(res[0]) != HTTPRequest.RESULT_SUCCESS:
		return {"ok": false, "error": "TRANSPORT_%d" % int(res[0])}
	if int(res[1]) != 200:
		return {"ok": false, "error": "HTTP_%d" % int(res[1])}
	var parsed: Variant = JSON.parse_string((res[3] as PackedByteArray).get_string_from_utf8())
	if not parsed is Dictionary:
		return {"ok": false, "error": "BAD_JSON"}
	return {"ok": true, "body": parsed}
