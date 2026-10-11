extends SceneTree

## One RL rollout match on the REAL watch scene (headless): RED = live policy server (via WATCH_BRAIN_ADAPTER=rl_policy)
## -> frozen Hand A/B, BLUE = GX Utility. Plays to the normal terminal result or WATCH_TURN_CAP, then writes a result JSON.
## Env: RL_MATCH_OUT, RL_FAMILY, RL_SEED, RL_TIER, RL_STYLE (+ WATCH_BRAIN_ADAPTER, WATCH_TURN_CAP, RL_SESSION).
##   godot --headless --path <proj> -s res://tools/rl_match_runner.gd

const WatchCls = preload("res://scripts/cloud_pipeline/watch_llm_vs_utility.gd")
const RuntimeCls = preload("res://scripts/episodes/episode_runtime.gd")


func _initialize() -> void:
	call_deferred("_run")


func _env(k: String, d: String) -> String:
	var v := OS.get_environment(k).strip_edges()
	return v if not v.is_empty() else d


func _side_soldiers(mgr: RefCounted) -> Dictionary:
	var out := {"red": 0, "blue": 0}
	for u in mgr.call("get_all_units_including_garrisoned"):
		var f := str(u.get("faction", ""))
		if out.has(f):
			out[f] += maxi(0, int(u.get("soldier_count", 0)))
	return out


func _run() -> void:
	var t0 := Time.get_ticks_msec()
	var deadline := t0 + int(_env("RL_MATCH_TIMEOUT_S", "5400")) * 1000
	WatchCls.start_match(self, _env("RL_FAMILY", "mild"), int(_env("RL_SEED", "1")), _env("RL_TIER", "BASIC"), _env("RL_STYLE", "BULWARK"))
	await process_frame
	await process_frame
	var scene := current_scene
	var driver: Node = scene.get_node("WatchDriver")
	var shell: Node = scene.get_node("Battle")
	var mount: Node = scene.get_node("Cloud2LiveMount")
	var mgr: RefCounted = shell.get("unit_manager")
	var start := _side_soldiers(mgr)
	var timed_out := false
	while not bool(driver.get("match_finished")):
		if Time.get_ticks_msec() > deadline:
			timed_out = true
			break
		await process_frame
	var end := _side_soldiers(mgr)
	var ctl: Node = mount.get("cloud_controller")
	var fault: Dictionary = ctl.call("strict_fault") if ctl != null and ctl.has_method("strict_fault") else {}
	var stats: Dictionary = ctl.call("laya_stats") if ctl != null else {}
	var over := bool(shell.call("_battle_over"))
	var outcome := "ABORTED" if bool(driver.get("aborted")) else "TIMEOUT" if timed_out else ("CAP" if not over else ("RED_WIN" if bool(shell.get("_battle_lost")) else ("BLUE_WIN" if bool(shell.get("_battle_won")) else "ENDED")))
	var gx: Node = driver.get("gx")
	var res := {
		"outcome": outcome, "turn": int(mgr.call("get_current_turn")), "turn_cap": int(driver.get("turn_cap")),
		"soldiers_start": start, "soldiers_end": end,
		"red_frac": float(end["red"]) / maxf(1.0, float(start["red"])), "blue_frac": float(end["blue"]) / maxf(1.0, float(start["blue"])),
		"strict_fault": fault, "episode": RuntimeCls.launch_record(),
		"gx_profile": str(((gx.get("bot") as RefCounted).call("profile") as Dictionary).get("profile_id", "")) if gx != null else "",
		"red_stats": {"decisions": stats.get("decision_count"), "fallbacks": stats.get("fallback_count"),
			"exec_failures": stats.get("exec_failures"), "pipeline_failures": (stats.get("hand_ab", {}) as Dictionary).get("pipeline_failure_count")},
		"wall_s": (Time.get_ticks_msec() - t0) / 1000.0, "driver_stage": str(driver.get("_stage")),
	}
	var f := FileAccess.open(_env("RL_MATCH_OUT", "user://rl_match.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(res, "  ", true))
	f.close()
	print("[RLMatch] %s turn=%d red_frac=%.3f blue_frac=%.3f wall=%.0fs" % [outcome, res["turn"], res["red_frac"], res["blue_frac"], res["wall_s"]])
	for c in root.get_children():
		c.queue_free()
	var until := Time.get_ticks_msec() + 15000
	while Time.get_ticks_msec() < until:
		await process_frame
	quit(0)
