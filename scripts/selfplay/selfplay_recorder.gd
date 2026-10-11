extends Node

## HEADLESS SELF-PLAY V1 — trajectory recorder.
##
## Attaches to a live SymLocMount and persists append-safe per-match JSONL:
##   brain.jsonl .... one record per Brain (VictoryPlan) audit row, drained
##                    from each side's mission-manager audit (trigger, tokens,
##                    latency, validation, disposition, plan before/after).
##   laya.jsonl ..... one record per Laya Hands decision/event, from the
##                    already-emitted laya_decision signal (candidates,
##                    ranking, latency, execution outcome).
##   referee.jsonl .. fog rows + turn-boundary progress + tactics digests.
##                    REFEREE TELEMETRY ONLY (NOT_POLICY_INPUT).
##   referee_truth.jsonl .. full Godot unit table at start/end.
##                    NEVER policy input (NOT_POLICY_INPUT).
##   events.jsonl ... match lifecycle + stalemate watch.
##   match.json ..... terminal summary (rewards, latency sums, trigger
##                    counts, trajectory counts). Written atomically once.
##   terminal.json .. reward-attach join table (side -> decision ids).
##
## Policy files (brain/laya) contain NO hidden opponent truth by
## construction: brain records carry observation digests (counts/hashes),
## never unit tables; laya records carry candidate ids/ranking only.
## Full truth lives ONLY in referee_truth.jsonl.
##
## No training: this node only observes and writes.

const ObsCls = preload("res://scripts/cloud1/cloud1_observation.gd")
const BrainCls = preload("res://scripts/symloc/symloc_brain.gd")
const MatchLib = preload("res://scripts/selfplay/selfplay_match.gd")

var mount: Node = null
var out_dir := ""
var run_id := ""
var match_id := ""
var seed := ""
var scenario := ""
var status := "STARTED"

var _brain_f: FileAccess = null
var _laya_f: FileAccess = null
var _ref_f: FileAccess = null
var _truth_f: FileAccess = null
var _ev_f: FileAccess = null

var _seen := {"red": {}, "blue": {}}
var _last_plan := {"red": {}, "blue": {}}
var _merge_seq := {}
var _fog_count := 0
var _had_fog_leak := false

var _brain_n := {"red": 0, "blue": 0}
var _brain_trig := {"red": {}, "blue": {}}
var _brain_dec := {"red": {}, "blue": {}}
var _brain_ms := {"red": 0, "blue": 0}
var _brain_gen_tok := {"red": 0, "blue": 0}
var _brain_in_tok := {"red": 0, "blue": 0}
var _vp_history_n := 0
var _brain_ids := {"red": [], "blue": []}

var _laya_n := {"red": 0, "blue": 0}
var _laya_ev_n := {"red": 0, "blue": 0}
var _laya_ms := {"red": 0.0, "blue": 0.0}
var _laya_exec_ok := {"red": 0, "blue": 0}
var _laya_exec_fail := {"red": 0, "blue": 0}

var _ref_n := 0
var _truth_n := 0
var _t0_msec := 0
var _t0_unix := 0.0
var _t_mount_ready_unix := 0.0


static func _env(key: String, fallback: String) -> String:
	var v := OS.get_environment(key).strip_edges()
	return v if not v.is_empty() else fallback


func setup(mount_node: Node, cfg: Dictionary) -> Dictionary:
	mount = mount_node
	out_dir = str(cfg.get("out_dir", _env("SELFPLAY_OUT_DIR", "")))
	run_id = str(cfg.get("run_id", _env("SELFPLAY_RUN_ID", "run_local")))
	match_id = str(cfg.get("match_id", _env("SELFPLAY_MATCH_ID", "m1")))
	_t0_msec = Time.get_ticks_msec()
	_t0_unix = Time.get_unix_time_from_system()
	_t_mount_ready_unix = float(cfg.get("mount_ready_unix", _t0_unix))
	if out_dir.is_empty():
		return {"ok": false, "error": "SELFPLAY_OUT_DIR is empty"}
	var mk := DirAccess.make_dir_recursive_absolute(out_dir)
	if mk != OK:
		return {"ok": false, "error": "mkdir failed: %s" % out_dir}
	_brain_f = FileAccess.open(out_dir + "/brain.jsonl", FileAccess.WRITE)
	_laya_f = FileAccess.open(out_dir + "/laya.jsonl", FileAccess.WRITE)
	_ref_f = FileAccess.open(out_dir + "/referee.jsonl", FileAccess.WRITE)
	_truth_f = FileAccess.open(out_dir + "/referee_truth.jsonl", FileAccess.WRITE)
	_ev_f = FileAccess.open(out_dir + "/events.jsonl", FileAccess.WRITE)
	if _brain_f == null or _laya_f == null or _ref_f == null or _truth_f == null or _ev_f == null:
		return {"ok": false, "error": "failed to open JSONL handles"}
	seed = str((mount.get("match_meta") as Dictionary).get("seed", ""))
	scenario = str((mount.get("match_meta") as Dictionary).get("scenario", ""))
	var head := {"record": "header", "run_id": run_id, "match_id": match_id,
		"seed": seed, "scenario": scenario,
		"brain_model": _env("SELFPLAY_BRAIN_MODEL", "?"),
		"brain_revision": _env("SELFPLAY_BRAIN_REVISION", "?"),
		"brain_adapter": _env("SELFPLAY_BRAIN_ADAPTER", "victory/cloud2"),
		"hands_version": _env("SELFPLAY_HANDS_VERSION", "laya-multilingual-322m"),
		"max_turns": MatchLib.max_turns(),
		"no_progress_window": MatchLib.no_progress_window(),
		"started_unix": _t0_unix, "training": "NONE"}
	_write(_brain_f, head)
	_write(_laya_f, head)
	var rhead := head.duplicate(true)
	rhead["NOT_POLICY_INPUT"] = true
	_write(_ref_f, rhead)
	_write(_truth_f, rhead)
	_write(_ev_f, head)
	var rc: Node = mount.get("red_controller")
	var bc: Node = mount.get("blue_controller")
	if rc != null:
		rc.connect("laya_decision", _on_laya.bind("red"))
	if bc != null:
		bc.connect("laya_decision", _on_laya.bind("blue"))
	_last_plan["red"] = _side_plan("red")
	_last_plan["blue"] = _side_plan("blue")
	_write(_ev_f, {"record": "match_start", "run_id": run_id, "match_id": match_id,
		"unix": _t0_unix, "red_brain": BrainCls.backend_label(mount.get("red_config")),
		"blue_brain": BrainCls.backend_label(mount.get("blue_config")),
		"opening_rule": str((mount.get("match_meta") as Dictionary).get("opening_rule", ""))})
	_write_truth("match_start")
	_write(_ref_f, {"record": "policy_digest_start", "run_id": run_id,
		"match_id": match_id, "NOT_POLICY_INPUT": true,
		"red": _obs_digest("red"), "blue": _obs_digest("blue")})
	_ref_n += 1
	_flush_all()
	print("[SelfplayRec] recording -> %s" % out_dir)
	return {"ok": true, "out_dir": out_dir}


func _write(f: FileAccess, obj: Dictionary) -> void:
	if f != null:
		f.store_string(JSON.stringify(obj) + "\n")


func _flush_all() -> void:
	for f in [_brain_f, _laya_f, _ref_f, _truth_f, _ev_f]:
		if f != null:
			(f as FileAccess).flush()


func _ctl(side: String) -> Node:
	return mount.get("red_controller" if side == "red" else "blue_controller")


func _mgr(side: String) -> RefCounted:
	var c := _ctl(side)
	if c == null:
		return null
	return c.get("_manager") as RefCounted


func _side_plan(side: String) -> Dictionary:
	var m := _mgr(side)
	if m == null:
		return {}
	return (m as RefCounted).call("vp_get_plan")


## Side-authorized observation DIGEST (counts + snapshot ref + hash).
## Never embeds unit tables, so no hidden truth can leak into brain.jsonl.
func _obs_digest(side: String) -> Dictionary:
	var d := {"side": side, "ok": false}
	var bridge: RefCounted = mount.get("bridge") as RefCounted
	if bridge == null:
		return d
	var obs := ObsCls.build(bridge, side)
	if not bool(obs.get("ok", false)):
		return d
	d = {"side": side, "ok": true,
		"snapshot_id": str(obs.get("snapshot_id", "")),
		"turn": int(obs.get("turn", 0)),
		"friendly_count": ((obs.get("friendly_units", []) as Array).size()),
		"known_foe_count": ((obs.get("known_enemy_units", []) as Array).size()),
		"events_count": ((obs.get("recent_events", []) as Array).size()),
		"mission_status": str((obs.get("mission", {}) as Dictionary).get("status", "")),
		"obs_hash": hash(JSON.stringify(obs))}
	return d


func _missions_of(plan: Dictionary) -> Array:
	var out: Array = []
	var cur_id := str(plan.get("current_phase_id", ""))
	for p_val in (plan.get("phases", []) as Array):
		if not p_val is Dictionary:
			continue
		var p: Dictionary = p_val
		if str(p.get("phase_id", "")) != cur_id:
			continue
		for m_val in (p.get("missions", []) as Array):
			if m_val is Dictionary:
				var m: Dictionary = m_val
				out.append({"mission_id": str(m.get("mission_id", "")),
					"task": str(m.get("task", "")), "area": str(m.get("area", "")),
					"units": ((m.get("assigned_units", []) as Array).duplicate(true)),
					"status": str(m.get("status", ""))})
	return out


## Drain new mission-manager audit rows for both sides into brain.jsonl.
func poll() -> Dictionary:
	var added := {"red": 0, "blue": 0}
	for side in ["red", "blue"]:
		var m := _mgr(side)
		if m == null:
			continue
		var audit: Array = (m as RefCounted).call("vp_get_audit")
		for row_val in audit:
			if not row_val is Dictionary:
				continue
			var row: Dictionary = row_val
			var cid := str(row.get("call_id", ""))
			if cid.is_empty() or ((_seen[side]) as Dictionary).has(cid):
				continue
			((_seen[side]) as Dictionary)[cid] = true
			_record_brain(side, row)
			added[side] = int(added[side]) + 1
	# Drain new fog rows into referee.jsonl.
	var fog: Array = mount.get("fog_rows")
	while _fog_count < fog.size():
		var fr: Dictionary = fog[_fog_count]
		_fog_count += 1
		_ref_n += 1
		var rrow: Dictionary = (fr as Dictionary).get("red", {})
		var brow: Dictionary = (fr as Dictionary).get("blue", {})
		if bool(rrow.get("leak", false)) or bool(brow.get("leak", false)):
			_had_fog_leak = true
		_write(_ref_f, {"record": "fog", "run_id": run_id, "match_id": match_id,
			"NOT_POLICY_INPUT": true, "row": fr})
	_flush_all()
	return added


func _merge_key(side: String, turn: int, req_type: String) -> Dictionary:
	var kind := "REVIEW"
	if str(req_type).to_upper().contains("INITIAL"):
		kind = "INITIAL"
	var k := "%s|%d|%s" % [side, turn, kind]
	var seq := int(_merge_seq.get(k, 0))
	_merge_seq[k] = seq + 1
	return {"side": side, "turn": turn, "kind": kind, "seq": seq}


func _record_brain(side: String, row: Dictionary) -> void:
	var usage: Dictionary = row.get("usage", {})
	var in_tok := int(usage.get("prompt_tokens", usage.get("input_tokens", 0)))
	var gen_tok := int(usage.get("completion_tokens", usage.get("output_tokens", 0)))
	var before: Dictionary = (_last_plan[side] as Dictionary).duplicate(true)
	var after := _side_plan(side)
	_last_plan[side] = after.duplicate(true)
	var validation: Dictionary = row.get("validation", {})
	if str(validation.get("code", "")) == "VP_HISTORY":
		_vp_history_n += 1
	var trig := str(row.get("trigger", "?"))
	var dec := str(row.get("decision", "-"))
	_brain_n[side] = int(_brain_n[side]) + 1
	(_brain_trig[side] as Dictionary)[trig] = int(((_brain_trig[side]) as Dictionary).get(trig, 0)) + 1
	(_brain_dec[side] as Dictionary)[dec] = int(((_brain_dec[side]) as Dictionary).get(dec, 0)) + 1
	_brain_ms[side] = int(_brain_ms[side]) + int(row.get("latency_ms", 0))
	_brain_gen_tok[side] = int(_brain_gen_tok[side]) + gen_tok
	_brain_in_tok[side] = int(_brain_in_tok[side]) + in_tok
	(_brain_ids[side] as Array).append(str(row.get("call_id", "")))
	var cfg: RefCounted = mount.get("red_config" if side == "red" else "blue_config")
	_write(_brain_f, {"record": "brain", "run_id": run_id, "match_id": match_id,
		"turn": int(row.get("turn", 0)), "side": side,
		"decision_id": str(row.get("call_id", "")),
		"trigger_reason": trig, "why": str(row.get("why", "")),
		"request_type": str(row.get("request_type", "?")),
		"model": str(cfg.get("model")) if cfg != null else "?",
		"revision": _env("SELFPLAY_BRAIN_REVISION", "?"),
		"adapter_id": "%s/%s" % [_env("SELFPLAY_BRAIN_ADAPTER", "victory/cloud2"),
			BrainCls.backend_label(cfg)],
		"backend": str(row.get("backend", "?")),
		"obs_ref": _obs_digest(side),
		"plan_before": before, "phase_before": str(row.get("phase_before", "-")),
		"missions_before": _missions_of(before),
		"input_tokens": in_tok, "generated_tokens": gen_tok,
		"reasoning_tokens": int(usage.get("reasoning_tokens", 0)),
		"final_tokens": int(usage.get("final_output_tokens", 0)),
		"total_tokens": in_tok + gen_tok,
		"tokens_available": not usage.is_empty(),
		"raw_ref": null,
		"merge_key": _merge_key(side, int(row.get("turn", 0)), str(row.get("request_type", "?"))),
		"parsed": {"decision": dec, "reason": str(row.get("why", ""))},
		"validation": validation,
		"disposition": dec, "outcome": str(row.get("outcome", "?")),
		"plan_after": after, "phase_after": str(row.get("phase_after", "-")),
		"revision_before": int(row.get("revision_before", 0)),
		"revision_after": int(row.get("revision_after", 0)),
		"latency_ms": int(row.get("latency_ms", 0)),
		"http_status": str(row.get("http_status", "?")),
		"finish_reason": str(row.get("finish_reason", "")),
		"final_chars": int(row.get("final_chars", 0)),
		"reasoning_present": bool(row.get("reasoning_present", false)),
		"reasoning_chars": int(row.get("reasoning_chars", 0)),
		"output_budget": int(row.get("output_budget", 0)),
		"retry_of": str(row.get("retry_of", "")),
		"contract": str(row.get("contract", "")),
		"prefetch": bool(row.get("prefetch", false)),
		"provider_outcome": str(row.get("provider_outcome", "?")),
		"provider_message": str(row.get("provider_message", "")),
		"change_summary": (row.get("change_summary", []) as Array).duplicate(true),
		"mission_changes": (row.get("mission_changes", []) as Array).duplicate(true),
		"laya_notified": bool(row.get("laya_notified", false)),
		"snapshot_id": str(row.get("snapshot_id", "")),
		"poll_msec": Time.get_ticks_msec() - _t0_msec})


func _on_laya(info: Dictionary, side: String) -> void:
	var ev := str(info.get("event", "?"))
	var is_decision := ev == "DECISION" or ev == "FORCED_SINGLE_LEGAL_ACTION"
	if is_decision:
		_laya_n[side] = int(_laya_n[side]) + 1
		_laya_ms[side] = float(_laya_ms[side]) + float(info.get("latency_ms", 0.0))
		if bool(info.get("executed", false)):
			_laya_exec_ok[side] = int(_laya_exec_ok[side]) + 1
		elif ev == "DECISION":
			_laya_exec_fail[side] = int(_laya_exec_fail[side]) + 1
	else:
		_laya_ev_n[side] = int(_laya_ev_n[side]) + 1
	_write(_laya_f, {"record": "laya_decision" if is_decision else "laya_event",
		"run_id": run_id, "match_id": match_id, "event": ev,
		"turn": int(info.get("turn", 0)), "step": int(info.get("step", 0)),
		"side": side, "unit_id": str(info.get("unit_id", "")),
		"mission_id": str(info.get("mission_id", "")),
		"selected": str(info.get("selected", "")),
		"action_type": str(info.get("action_type", "")),
		"candidate_ids": (info.get("candidate_ids", []) as Array).duplicate(true),
		"candidate_count": int(info.get("candidate_count", 0)),
		"top5": (info.get("top5", []) as Array).duplicate(true),
		"scores_available": bool(info.get("scores_available", false)),
		"confidence": info.get("confidence"),
		"latency_ms": float(info.get("latency_ms", 0.0)),
		"server_ms": float(info.get("server_ms", 0.0)),
		"executed": bool(info.get("executed", false)),
		"exec_code": str(info.get("exec_code", "")),
		"squeeze": bool(info.get("squeeze", false)),
		"error": str(info.get("error", info.get("reason", info.get("code", "")))),
		"poll_msec": Time.get_ticks_msec() - _t0_msec})


func note_turn_boundary(info: Dictionary) -> void:
	_write(_ev_f, {"record": "turn_boundary", "run_id": run_id, "match_id": match_id,
		"turn": int(info.get("turn", 0)), "progress": bool(info.get("progress", false)),
		"events": info.get("events", []),
		"quiet_turns": int(info.get("turns_without_progress", 0)),
		"poll_msec": Time.get_ticks_msec() - _t0_msec})
	_write(_ref_f, {"record": "tactics_digest", "run_id": run_id, "match_id": match_id,
		"NOT_POLICY_INPUT": true, "turn": int(info.get("turn", 0)),
		"red": _tactics_digest("red"), "blue": _tactics_digest("blue")})
	_ref_n += 1
	_flush_all()


func _tactics_digest(side: String) -> Dictionary:
	var c := _ctl(side)
	if c == null or not c.has_method("laya_tactics_view"):
		return {}
	var tv: Dictionary = c.call("laya_tactics_view")
	var boards: Dictionary = tv.get("blackboards", {})
	var commits := 0
	for mid in boards.keys():
		commits += (((boards[mid]) as Dictionary).get("commitments", []) as Array).size()
	return {"missions": boards.size(), "commitments": commits,
		"coordinator_runs": ((tv.get("coordinator_runs", []) as Array).size())}


func _write_truth(when: String) -> void:
	var mgr: RefCounted = mount.get("shell").get("unit_manager") as RefCounted
	var rows: Array = []
	if mgr != null:
		rows = ((mgr as RefCounted).call("get_all_units_including_garrisoned") as Array).duplicate(true)
	_truth_n += 1
	_write(_truth_f, {"record": "referee_truth", "run_id": run_id, "match_id": match_id,
		"NOT_POLICY_INPUT": true, "when": when,
		"turn": int(MatchLib.progress_snapshot(mount.get("shell")).get("turn", 0)),
		"units": rows, "poll_msec": Time.get_ticks_msec() - _t0_msec})


func finalize(term: Dictionary, extra: Dictionary) -> Dictionary:
	poll()
	status = str(extra.get("status", "COMPLETE"))
	var end_unix := Time.get_unix_time_from_system()
	var rc := _ctl("red")
	var bc := _ctl("blue")
	var rs: Dictionary = rc.call("laya_stats") if rc != null else {}
	var bs: Dictionary = bc.call("laya_stats") if bc != null else {}
	_write_truth("match_end")
	_write(_ref_f, {"record": "policy_digest_end", "run_id": run_id,
		"match_id": match_id, "NOT_POLICY_INPUT": true,
		"red": _obs_digest("red"), "blue": _obs_digest("blue")})
	_ref_n += 1
	# Full blackboard snapshots (side-authorized, bounded) for Laya context.
	_write_json_file(out_dir + "/blackboard_red.json",
		rc.call("laya_tactics_view") if rc != null and rc.has_method("laya_tactics_view") else {})
	_write_json_file(out_dir + "/blackboard_blue.json",
		bc.call("laya_tactics_view") if bc != null and bc.has_method("laya_tactics_view") else {})
	var winner := str(term.get("winner", "DRAW"))
	var oc := MatchLib.outcomes_for_winner(winner)
	var summary := {"record": "match", "run_id": run_id, "match_id": match_id,
		"seed": seed, "scenario": scenario, "status": status,
		"side_assignment": {"red": "local_brain+laya", "blue": "local_brain+laya"},
		"brain_model": _env("SELFPLAY_BRAIN_MODEL", "?"),
		"brain_revision": _env("SELFPLAY_BRAIN_REVISION", "?"),
		"brain_adapter": _env("SELFPLAY_BRAIN_ADAPTER", "victory/cloud2"),
		"red_brain": BrainCls.backend_label(mount.get("red_config")),
		"blue_brain": BrainCls.backend_label(mount.get("blue_config")),
		"hands_version": _env("SELFPLAY_HANDS_VERSION", "laya-multilingual-322m"),
		"started_unix": _t0_unix, "mount_ready_unix": _t_mount_ready_unix,
		"ended_unix": end_unix,
		"wall_seconds": snappedf(end_unix - _t0_unix, 0.001),
		"turn_count": int(term.get("turn", 0)),
		"terminal_reason": str(term.get("reason", "")),
		"winner": winner,
		"reward_red": int(oc.get("reward_red", -2)) if status == "COMPLETE" else null,
		"reward_blue": int(oc.get("reward_blue", -2)) if status == "COMPLETE" else null,
		"brain_calls_red": int(_brain_n["red"]), "brain_calls_blue": int(_brain_n["blue"]),
		"brain_calls_total": int(_brain_n["red"]) + int(_brain_n["blue"]),
		"brain_triggers_red": (_brain_trig["red"] as Dictionary).duplicate(true),
		"brain_triggers_blue": (_brain_trig["blue"] as Dictionary).duplicate(true),
		"brain_decisions_red": (_brain_dec["red"] as Dictionary).duplicate(true),
		"brain_decisions_blue": (_brain_dec["blue"] as Dictionary).duplicate(true),
		"brain_ms_red": int(_brain_ms["red"]), "brain_ms_blue": int(_brain_ms["blue"]),
		"brain_input_tokens_red": int(_brain_in_tok["red"]),
		"brain_input_tokens_blue": int(_brain_in_tok["blue"]),
		"brain_generated_tokens_red": int(_brain_gen_tok["red"]),
		"brain_generated_tokens_blue": int(_brain_gen_tok["blue"]),
		"vp_history_rejections": _vp_history_n,
		"laya_decisions_red": int(_laya_n["red"]),
		"laya_decisions_blue": int(_laya_n["blue"]),
		"laya_events_red": int(_laya_ev_n["red"]),
		"laya_events_blue": int(_laya_ev_n["blue"]),
		"laya_ms_red": snappedf(float(_laya_ms["red"]), 1),
		"laya_ms_blue": snappedf(float(_laya_ms["blue"]), 1),
		"laya_exec_ok_red": int(_laya_exec_ok["red"]),
		"laya_exec_ok_blue": int(_laya_exec_ok["blue"]),
		"laya_exec_fail_red": int(_laya_exec_fail["red"]),
		"laya_exec_fail_blue": int(_laya_exec_fail["blue"]),
		"laya_stats_red": _stats_digest(rs), "laya_stats_blue": _stats_digest(bs),
		"fog_rows": _fog_count, "fog_leak": _had_fog_leak,
		"trajectory": {"brain_records": int(_brain_n["red"]) + int(_brain_n["blue"]),
			"laya_records": int(_laya_n["red"]) + int(_laya_n["blue"])
				+ int(_laya_ev_n["red"]) + int(_laya_ev_n["blue"]),
			"referee_records": _ref_n, "truth_records": _truth_n},
		"brain_audit_final_red": _final_audit("red"),
		"brain_audit_final_blue": _final_audit("blue"),
		"tracker": (extra.get("tracker", {}) as Dictionary).duplicate(true),
		"mount_match": mount.get("match_result"),
		"training": "NONE"}
	_write(_ev_f, {"record": "match_end", "run_id": run_id, "match_id": match_id,
		"unix": end_unix, "status": status, "winner": winner,
		"reason": str(term.get("reason", ""))})
	_flush_all()
	_close_all()
	_write_json_file(out_dir + "/match.json", summary)
	_write_json_file(out_dir + "/terminal.json",
		{"match_id": match_id, "status": status,
			"reward_red": summary["reward_red"], "reward_blue": summary["reward_blue"],
			"brain_decision_ids_red": (_brain_ids["red"] as Array).duplicate(true),
			"brain_decision_ids_blue": (_brain_ids["blue"] as Array).duplicate(true)})
	print("[SelfplayRec] MATCH_JSON %s status=%s winner=%s reason=%s turns=%d brain=%d laya=%d" % [
		out_dir + "/match.json", status, winner, str(term.get("reason", "")),
		int(term.get("turn", 0)),
		int(_brain_n["red"]) + int(_brain_n["blue"]),
		int(_laya_n["red"]) + int(_laya_n["blue"])])
	return summary


func _stats_digest(s: Dictionary) -> Dictionary:
	if s.is_empty():
		return {}
	var lat: Array = s.get("latency_ms", [])
	var pools: Array = s.get("pool_sizes", [])
	return {"authority": str(s.get("authority", "?")), "side": str(s.get("side", "?")),
		"side_turns": int(s.get("side_turns", 0)),
		"decision_count": int(s.get("decision_count", 0)),
		"forced_count": int(s.get("forced_count", 0)),
		"fallback_count": int(s.get("fallback_count", 0)),
		"fallback_active": bool(s.get("fallback_active", false)),
		"fallback_reason": str(s.get("fallback_reason", "")),
		"moves": int(s.get("moves", 0)), "attacks": int(s.get("attacks", 0)),
		"waits": int(s.get("waits", 0)), "other": int(s.get("other", 0)),
		"exec_failures": int(s.get("exec_failures", 0)),
		"latency_count": lat.size(),
		"latency_ms_total": snappedf(_sum(lat), 1),
		"pool_count": pools.size(),
		"service": (s.get("service", {}) as Dictionary).duplicate(true)}


func _sum(a: Array) -> float:
	var t := 0.0
	for v in a:
		t += float(v)
	return t


func _final_audit(side: String) -> Array:
	var m := _mgr(side)
	if m == null:
		return []
	return ((m as RefCounted).call("vp_get_audit") as Array).duplicate(true)


func _close_all() -> void:
	for f in [_brain_f, _laya_f, _ref_f, _truth_f, _ev_f]:
		if f != null:
			(f as FileAccess).close()
	_brain_f = null
	_laya_f = null
	_ref_f = null
	_truth_f = null
	_ev_f = null


func _write_json_file(path: String, obj: Dictionary) -> void:
	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		push_warning("[SelfplayRec] cannot write %s" % tmp)
		return
	f.store_string(JSON.stringify(obj, "\t"))
	f.close()
	var d := DirAccess.open(out_dir)
	if d != null:
		if d.file_exists(path.get_file()):
			d.remove(path.get_file())
		var err := d.rename(tmp.get_file(), path.get_file())
		if err != OK:
			push_warning("[SelfplayRec] rename failed %s -> %s (%d)" % [tmp, path, err])
