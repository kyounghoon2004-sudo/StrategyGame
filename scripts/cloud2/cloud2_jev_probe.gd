extends SceneTree

## JEV SINGLE-LAUNCH PROBE (SHADOW ONLY) — headless lifecycle test.
##
## Usage:
##   Godot_console --headless --path <StrategyGame> -s res://scripts/cloud2/cloud2_jev_probe.gd -- --probe-out=<json>
##
## Spawns the owned worker via Cloud2JevLauncher, waits for the health
## handshake, records the ownership snapshot, shuts the worker down, and
## writes one JSON result. No battle, no authority, no state changes.

const LauncherCls = preload("res://scripts/cloud2/cloud2_jev_launcher.gd")


func _init() -> void:
	var out := ""
	for a in OS.get_cmdline_user_args():
		if str(a).begins_with("--probe-out="):
			out = str(a).substr("--probe-out=".length())
	var t0 := Time.get_ticks_msec()
	var ens: Dictionary = LauncherCls.ensure_started_sync()
	var snap: Dictionary = LauncherCls.status_snapshot()
	var pid := int(snap.get("pid", -1))
	var result := {
		"godot_pid": OS.get_process_id(),
		"startup_wall_ms": float(Time.get_ticks_msec() - t0),
		"launcher": snap,
	}
	var shut := {"stopped": false, "reason": "NOT_ATTEMPTED", "orphan": false}
	if str(snap.get("status", "")) == "READY" and bool(snap.get("owned", false)):
		shut = LauncherCls.shutdown_owned()
	elif str(snap.get("status", "")) == "READY":
		shut = {"stopped": false, "reason": "NOT_OWNED_REUSED", "orphan": false,
			"pid": pid}
	result["shutdown"] = shut
	result["worker_exited"] = (not OS.is_process_running(pid)) if pid > 0 else true
	if not out.is_empty():
		DirAccess.make_dir_recursive_absolute(out.get_base_dir())
		var f := FileAccess.open(out, FileAccess.WRITE)
		if f != null:
			f.store_string(JSON.stringify(result, "\t"))
			f.close()
	print("[JEVPROBE] %s" % JSON.stringify(result))
	quit(0 if str(snap.get("status", "")) == "READY" else 1)
