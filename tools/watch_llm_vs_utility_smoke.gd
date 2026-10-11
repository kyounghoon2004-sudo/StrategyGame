extends SceneTree

## Headless smoke for the DEV watch scene: start a match exactly as the title entry does, let it run
## WATCH_TURNS full turns, then check wiring. Writes JSON to WATCH_OUT.
##   WATCH_OUT=<abs json> WATCH_TURNS=2 godot --headless --path . -s res://tools/watch_llm_vs_utility_smoke.gd

const WatchCls = preload("res://scripts/cloud_pipeline/watch_llm_vs_utility.gd")
const RuntimeCls = preload("res://scripts/episodes/episode_runtime.gd")
const LocalBrainCls = preload("res://scripts/cloud2/cloud2_local_brain_launcher.gd")

var out := {}


func _initialize() -> void:
	call_deferred("_run")


func _positions(shell: Node) -> Dictionary:
	var out := {}
	for u in (shell.get("unit_manager") as RefCounted).call("get_all_units"):
		out[str(u.get("id", u.get("unit_id", "")))] = [str(u.get("faction", "")), int(u["q"]), int(u["r"])]
	return out


func _moved(a: Dictionary, b: Dictionary) -> Dictionary:
	var out := {"red": 0, "blue": 0}
	for k in a.keys():
		if b.has(k) and (a[k][1] != b[k][1] or a[k][2] != b[k][2]) and out.has(a[k][0]):
			out[a[k][0]] += 1
	return out


func _run() -> void:
	var path := OS.get_environment("WATCH_OUT")
	var turns := int(OS.get_environment("WATCH_TURNS")) if OS.get_environment("WATCH_TURNS").is_valid_int() else 2
	var deadline := Time.get_ticks_msec() + 3600 * 1000
	WatchCls.start_match(self, "mild", 3, "INTER", "BULWARK")
	await process_frame
	await process_frame
	var scene := current_scene
	var driver: Node = scene.get_node("WatchDriver")
	var shell: Node = scene.get_node("Battle")
	var mount: Node = scene.get_node("Cloud2LiveMount")
	var red_seen := 0
	var in_red := false
	var packet := {}
	var pos0 := _positions(shell)
	while Time.get_ticks_msec() < deadline and not bool(shell.call("_battle_over")):
		var ph := int(shell.get("_turn_phase"))
		if ph == 1:
			in_red = true
		elif in_red:
			in_red = false
			red_seen += 1
			if red_seen == 1:
				packet = (mount.get("cloud_controller").call("get_general_view") as Dictionary).get("last_general_packet", {})
			if red_seen >= turns:
				break
		await process_frame
	var ctl: Node = mount.get("cloud_controller")
	var gx: Node = driver.get("gx")
	var stats: Dictionary = ctl.call("laya_stats")
	var gx_obs: Dictionary = gx.call("_build_observation") if gx != null else {}
	var mgr: RefCounted = shell.get("unit_manager")
	var oob := 0
	var occ := {}
	var dup := 0
	var cells: Dictionary = (shell.get("hex_grid") as Node).get("cell_data")
	for u in mgr.call("get_all_units"):
		if bool(u.get("garrisoned", false)):
			continue
		var key := "%d,%d" % [int(u["q"]), int(u["r"])]
		oob += 0 if cells.has(key) else 1
		dup += 1 if occ.has(key) else 0
		occ[key] = true
	out = {
		"red_turns_seen": red_seen, "battle_over": bool(shell.call("_battle_over")),
		"brain": LocalBrainCls.status_snapshot(), "brain_adapter_env": OS.get_environment("LOCAL_BRAIN_ADAPTER"),
		"context_env": OS.get_environment("BRAIN_CONTEXT_PACK"),
		"packet_request": str(packet.get("request", "")), "packet_has_context": packet.has("context"),
		"packet_context_episode": (packet.get("context", {}) as Dictionary).get("episode", {}),
		"runtime_episode": RuntimeCls.launch_record(),
		"gx_side": str(gx.get("side")) if gx != null else "", "gx_profile": (gx.get("bot") as RefCounted).call("profile") if gx != null else {},
		"gx_bot_class": (gx.get("bot") as RefCounted).get_script().resource_path if gx != null else "",
		"gx_obs_episode": str(gx_obs.get("episode_id", "")), "gx_obs_side": str(gx_obs.get("side", "")),
		"gx_ruleset_equals_runtime": JSON.stringify(gx_obs.get("ruleset_override", {})) == JSON.stringify(RuntimeCls.rules()),
		"gx_last_phase": gx.get("last_phase_result") if gx != null else {},
		"hands": (stats.get("service", {}) as Dictionary).get("worker_identity", {}),
		"red_stats": {"decisions": stats.get("decision_count"), "fallbacks": stats.get("fallback_count"),
			"exec_failures": stats.get("exec_failures"), "pipeline_failures": (stats.get("hand_ab", {}) as Dictionary).get("pipeline_failure_count")},
		"sandbox_active": bool(shell.get("is_step0_sandbox")), "runtime_rules_base_mp": RuntimeCls.rules().get("base_mp", {}),
		"units_moved": _moved(pos0, _positions(shell)), "unit_count": pos0.size(),
		"oob": oob, "dup": dup, "red_controller_mode": str(shell.call("red_controller_mode")),
	}
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(out, "  ", true))
	f.close()
	print("[WatchSmoke] done red_turns=%d" % red_seen)
	for c in root.get_children():
		c.queue_free()
	var until := Time.get_ticks_msec() + 15000
	while Time.get_ticks_msec() < until:
		await process_frame
	quit(0)
