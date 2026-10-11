extends SceneTree

## DEV RL ARENA: ONE persistent game window that plays every RL rollout match in sequence.
## The RL loop (tools/contextual_brain/rl_vs_utility.py) drops a job file; the arena reloads the watch scene
## in this same window (no process restart), plays the match, writes the result JSON, and waits for the next job.
## Dev-mode only: nothing here changes the game backend.
##   RL_ARENA_DIR=<abs dir> godot --path <proj> -s res://tools/rl_arena.gd
## Jobs (<dir>/job.json, written atomically): {"cmd":"play", "out", "family", "seed", "tier", "style", "turn_cap",
##   "session", "timeout_s"} | {"cmd":"idle"} (stop the Hands worker so the GPU is clear for training) | {"cmd":"quit"}.
## Heartbeat: <dir>/alive.json every ~1 s. Ack for idle: <dir>/idle_ack.json.

const WatchCls = preload("res://scripts/cloud_pipeline/watch_llm_vs_utility.gd")
const RuntimeCls = preload("res://scripts/episodes/episode_runtime.gd")
const LocalBrainCls = preload("res://scripts/cloud2/cloud2_local_brain_launcher.gd")
const LYLaunchCls = preload("res://scripts/laya/laya_launcher.gd")

var dir := ""
var _last_beat := 0
var _state := "IDLE"


func _initialize() -> void:
	call_deferred("_loop")


func _beat(force := false) -> void:
	if not force and Time.get_ticks_msec() - _last_beat < 1000:
		return
	_last_beat = Time.get_ticks_msec()
	var f := FileAccess.open(dir + "/alive.json", FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify({"t": Time.get_unix_time_from_system(), "state": _state, "pid": OS.get_process_id()}))
		f.close()


func _write(path: String, d: Dictionary) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(d, "  ", true))
	f.close()


func _loop() -> void:
	dir = OS.get_environment("RL_ARENA_DIR").replace("\\", "/")
	print("[RLArena] up dir=%s" % dir)
	while true:
		_beat()
		var jp := dir + "/job.json"
		if FileAccess.file_exists(jp):
			var job: Variant = JSON.parse_string(FileAccess.get_file_as_string(jp))
			DirAccess.remove_absolute(jp)
			if not (job is Dictionary):
				await process_frame
				continue
			var cmd := str(job.get("cmd", ""))
			print("[RLArena] job %s" % cmd)
			if cmd == "quit":
				break
			if cmd == "idle":
				_state = "IDLE"
				var res := LYLaunchCls.shutdown_owned()
				_write(dir + "/idle_ack.json", {"hands": res, "t": Time.get_unix_time_from_system()})
			elif cmd == "play":
				await _play(job)
		await process_frame
	for c in root.get_children():
		c.queue_free()
	var until := Time.get_ticks_msec() + 15000
	while Time.get_ticks_msec() < until:
		await process_frame
	quit(0)


func _side_soldiers(mgr: RefCounted) -> Dictionary:
	var out := {"red": 0, "blue": 0}
	for u in mgr.call("get_all_units_including_garrisoned"):
		var f := str(u.get("faction", ""))
		if out.has(f):
			out[f] += maxi(0, int(u.get("soldier_count", 0)))
	return out


func _hq_soldiers(mgr: RefCounted) -> Dictionary:
	var out := {"red": 0, "blue": 0}
	for u in mgr.call("get_all_units_including_garrisoned"):
		var f := str(u.get("faction", ""))
		if out.has(f) and str(u.get("class", "")) == "hq":
			out[f] += maxi(0, int(u.get("soldier_count", 0)))
	return out


## Every unit now: [id, faction, class, q, r, soldiers, max soldiers, fieldworks HP].
func _snapshot(mgr: RefCounted) -> Array:
	var out: Array = []
	for u in mgr.call("get_all_units_including_garrisoned"):
		var fw := int(u.get("field_fortification_hp", 0))
		if fw <= 0 and (bool(u.get("field_fortified", false)) or bool(u.get("fortified", false))):
			fw = 1
		out.append([str(u.get("id", "")), str(u.get("faction", "")), str(u.get("class", "")), int(u.get("q", 0)),
			int(u.get("r", 0)), int(u.get("soldier_count", 0)), int(u.get("max_count", u.get("soldier_count", 0))), fw])
	return out


## A controller's executed actions (the commander and GX controllers keep action_log), [] when there is none.
func _actions(c: Variant) -> Array:
	if c == null or not (c as Object).get("action_log") is Array:
		return []
	return (c as Object).get("action_log")


func _units(mgr: RefCounted) -> Dictionary:
	var out := {"red": 0, "blue": 0}
	for u in mgr.call("get_all_units_including_garrisoned"):
		var f := str(u.get("faction", ""))
		if out.has(f) and int(u.get("soldier_count", 0)) > 0:
			out[f] += 1
	return out


static func _hexd(a: Array, b: Array) -> int:
	var dq := int(a[0]) - int(b[0])
	var dr := int(a[1]) - int(b[1])
	return (absi(dq) + absi(dr) + absi(dq + dr)) / 2


## Wandering: per RED unit, net hexes gained (first -> last sampled position)
## over hexes travelled; straightness 1.0 = straight line, near 0 = back and forth.
static func _wander(traj: Dictionary) -> Dictionary:
	var rows := {}
	var s_sum := 0.0
	var n := 0
	for uid in traj.keys():
		var pts: Array = traj[uid]
		var path := 0
		for i in range(1, pts.size()):
			path += _hexd(pts[i - 1], pts[i])
		var net := _hexd(pts[0], pts[pts.size() - 1]) if pts.size() > 0 else 0
		var st := float(net) / float(path) if path > 0 else 1.0
		rows[uid] = {"path": path, "net": net, "straightness": snappedf(st, 0.001), "turns": pts.size()}
		if path >= 3:
			s_sum += st
			n += 1
	return {"mean_straightness": snappedf(s_sum / n, 0.001) if n > 0 else null, "units_measured": n, "per_unit": rows}


func _brain_stats(ctl: Node) -> Dictionary:
	var mgr = ctl.get("_manager") if ctl != null else null
	if mgr == null:
		return {}
	var dec := {}
	var phases: Array = []
	var failures := 0
	for r_val in (mgr.call("vp_get_audit") as Array):
		var r: Dictionary = r_val
		var d := str(r.get("decision", "-"))
		dec[d] = int(dec.get(d, 0)) + 1
		# No Brain response to judge (timeout / transport / 5xx): not the policy's fault, the game is excluded.
		if str(r.get("outcome", "")) == "FAILED" and str(r.get("http_status", "")) != "200":
			failures += 1
		var ph := str(r.get("phase_after", "-"))
		if ph != "-" and (phases.is_empty() or phases[phases.size() - 1] != ph):
			phases.append(ph)
	var vp: Dictionary = mgr.call("vp_get_plan")
	return {"decisions": dec, "phase_path": phases, "final_phase": str(vp.get("current_phase_id", "-")),
		"final_revision": int(vp.get("revision", 0)), "brain_failures": failures}


func _play(job: Dictionary) -> void:
	_state = "PLAYING"
	var t0 := Time.get_ticks_msec()
	var deadline := t0 + int(job.get("timeout_s", 7200)) * 1000
	OS.set_environment("WATCH_BRAIN_ADAPTER", "rl_policy")
	OS.set_environment("WATCH_TURN_CAP", str(int(job.get("turn_cap", 50))))
	OS.set_environment("RL_SESSION", str(job.get("session", "")))
	OS.set_environment("WATCH_STRICT_REVIEWS", "1" if bool(job.get("strict_reviews", true)) else "0")
	OS.set_environment("WATCH_RED_GX_STYLE", str(job.get("red_style", "")))  # GX vs GX: RED's style for this game
	OS.set_environment("WATCH_RED_HANDOFF_TURN", str(job.get("red_handoff_turn", OS.get_environment("WATCH_RED_HANDOFF_TURN"))))
	OS.set_environment("WATCH_RANDOM_ROSTER", "1" if bool(job.get("random_roster", false)) else "0")  # same random army per side
	OS.set_environment("WATCH_ROSTER_SIZES", str(job.get("roster_sizes", "")))  # allowed units per side incl. HQ
	OS.set_environment("WATCH_MISSION_MAP", str(job.get("mission_map", "")))  # a generated mission map file (2026-10-09)
	OS.set_environment("WATCH_OVERLAY_FILE", str(job.get("overlay", "")))  # a replay: the original game's exact rules
	# A new rollout phase serves a new policy (new session token): re-verify the Brain on the next mount.
	LocalBrainCls._status = "COLD"
	WatchCls.start_match(self, str(job["family"]), int(job["seed"]), str(job["tier"]), str(job["style"]))
	await process_frame
	await process_frame
	var scene := current_scene
	var driver: Node = scene.get_node("WatchDriver")
	var shell: Node = scene.get_node("Battle")
	var mount: Node = scene.get_node("Cloud2LiveMount")
	var mgr: RefCounted = shell.get("unit_manager")
	var start := _side_soldiers(mgr)
	var units0 := _units(mgr)
	var hq0 := _hq_soldiers(mgr)
	var traj := {}
	# Full record for the prediction model (2026-10-08): every unit of both sides at the start of each phase, and
	# both controllers' action logs (below).
	var snaps: Array = []  # every unit at the start of each side's phase ("to_act")
	var seen_phase := -1
	var seen_turn := -1
	var timed_out := false
	while not bool(driver.get("match_finished")):
		_beat()
		var t := int(mgr.call("get_current_turn"))
		var ph := int(shell.get("_turn_phase"))  # 0 = BLUE's phase (it acts first each round), else RED's
		if t * 10 + ph != seen_phase:
			seen_phase = t * 10 + ph
			snaps.append({"turn": t, "to_act": "blue" if ph == 0 else "red", "units": _snapshot(mgr)})
		if t != seen_turn:
			seen_turn = t
			for u in mgr.call("get_all_units"):
				if str(u.get("faction", "")) == "red":
					var uid := str(u.get("id", ""))
					var pts: Array = traj.get(uid, [])
					pts.append([int(u["q"]), int(u["r"])])
					traj[uid] = pts
		if Time.get_ticks_msec() > deadline:
			timed_out = true
			break
		await process_frame
	for u in mgr.call("get_all_units"):
		if str(u.get("faction", "")) == "red" and traj.has(str(u.get("id", ""))):
			(traj[str(u.get("id", ""))] as Array).append([int(u["q"]), int(u["r"])])
	var end := _side_soldiers(mgr)
	var units1 := _units(mgr)
	var hq1 := _hq_soldiers(mgr)
	var ctl: Node = mount.get("cloud_controller")
	var rc: Node = driver.get("red_cmd")  # COMMANDER mode: the Brain commands units directly (no Hands)
	if rc != null:
		ctl = rc
	var rg: Node = driver.get("red_gx")  # GX vs GX: RED is the GX bot; the Brain mount stays idle (its stub plan is no fault)
	var fault: Dictionary = {} if rg != null else (ctl.call("strict_fault") if ctl != null and ctl.has_method("strict_fault") else {})
	var stats: Dictionary = {} if rg != null else (ctl.call("laya_stats") if ctl != null else {})
	var bc: Node = driver.get("blue_cmd")  # cloud vs cloud: a BLUE commander fault ends the game the same way
	if fault.is_empty() and bc != null:
		fault = bc.call("strict_fault")
	var over := bool(shell.call("_battle_over"))
	var outcome := "INVALID" if not fault.is_empty() else "ABORTED" if bool(driver.get("aborted")) else "TIMEOUT" if timed_out else ("CAP" if not over else ("RED_WIN" if bool(shell.get("_battle_lost")) else ("BLUE_WIN" if bool(shell.get("_battle_won")) else "ENDED")))
	var gx: Node = driver.get("gx")
	var res := {
		"outcome": outcome, "turn": int(mgr.call("get_current_turn")), "turn_cap": int(driver.get("turn_cap")),
		"soldiers_start": start, "soldiers_end": end,
		"red_frac": float(end["red"]) / maxf(1.0, float(start["red"])), "blue_frac": float(end["blue"]) / maxf(1.0, float(start["blue"])),
		"strict_fault": fault, "episode": RuntimeCls.launch_record(), "win_rule": str(driver.get("win_rule")),
		"mission": {} if driver.get("mission_rules") == null else {"outcome": (driver.get("mission_rules") as Node).get("outcome"),
			"family": ((driver.get("mission_rules") as Node).get("mission") as Dictionary).get("family", ""),
			"roles": ((driver.get("mission_rules") as Node).get("mission") as Dictionary).get("roles", {}),
			"round_limit": ((driver.get("mission_rules") as Node).get("mission") as Dictionary).get("round_limit", 0),
			"map": str(driver.get("mission_map"))},
		"rout_rule": bool(driver.get("rout_rule")),
		# Older drivers (the frozen collection runtime copy) have no hand-off fields: get() is null there (2026-10-10).
		"red_handoff": {"requested_turn": int(driver.get("red_handoff_turn")) if driver.get("red_handoff_turn") != null else -1,
			"actual_turn": int(driver.get("red_handoff_actual")) if driver.get("red_handoff_actual") != null else -1,
			"profile": (rg.get("bot") as RefCounted).call("profile") if rg != null else {}},
		"gx_profile": str(((gx.get("bot") as RefCounted).call("profile") as Dictionary).get("profile_id", "")) if gx != null else "",
		"red_stats": {"decisions": stats.get("decision_count"), "fallbacks": stats.get("fallback_count"),
			"exec_failures": stats.get("exec_failures"), "pipeline_failures": (stats.get("hand_ab", {}) as Dictionary).get("pipeline_failure_count")},
		"wall_s": (Time.get_ticks_msec() - t0) / 1000.0, "driver_stage": str(driver.get("_stage")),
		"units": {"red": {"start": units0["red"], "alive": units1["red"]}, "blue": {"start": units0["blue"], "alive": units1["blue"]}},
		"hq": {"red": {"start": hq0["red"], "end": hq1["red"]}, "blue": {"start": hq0["blue"], "end": hq1["blue"]}},
		"red_actions": {"moves": stats.get("moves"), "attacks": stats.get("attacks"), "waits": stats.get("waits")},
		"brain": {} if rg != null else _brain_stats(ctl) if rc == null else {"decisions": {"COMMAND": stats.get("decision_count", 0)},
			"brain_failures": 0, "phase_path": [], "final_phase": "-", "final_revision": 0},
		"wander": _wander(traj),
		"record": {"snapshots": snaps + [{"turn": int(mgr.call("get_current_turn")), "units": _snapshot(mgr), "final": true}],
			"actions": {"red": _actions(rc) + _actions(rg), "blue": _actions(gx)},
			"rules": RuntimeCls.rules()},  # this game's actual rules (per-match movement/attack variation)
	}
	_write(str(job["out"]), res)
	print("[RLArena] %s turn=%d red_frac=%.3f blue_frac=%.3f wall=%.0fs" % [outcome, res["turn"], res["red_frac"], res["blue_frac"], res["wall_s"]])
	_state = "IDLE"
	_beat(true)
