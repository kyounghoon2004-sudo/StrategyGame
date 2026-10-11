extends SceneTree

## INTEGRATED TACTICAL QA probe — Mode A scripted control (SYSTEM_DEBUG).
## One deterministic battle exercising the full repaired chain in combination:
## FIX approach/contact/pressure + FLANK maneuver/exploit + hard designation +
## same-batch death handling + mission failure + MISSION_FAILED review +
## M00 provenance + ADJUST reclaim + HQ-threat defense. No scoring/move changes;
## diagnostic/acceptance only. Normal stack only (manager.red_turn ->
## response gate -> compiler.execute w/ manager exec_ctx -> post_turn ->
## review service -> BLUE aggressive -> sim_end_turn).
##
## Modes (--mode=scripted|determinism):
##   scripted:    8-turn integrated battle, compact per-turn trace.
##   determinism: scripted twice; compare fingerprints + exec sigs +
##                mission transitions + review turns + cancel/retarget counts.
##
## Flags: --tag=<t> --out-dir=<abs> --inject-turn=<N> (0 = no attrition
## injection; N>0 weakens the M02 wing before turn N's RED phase, mlc vehicle).
##
## Usage:
##   Godot console --headless --path <StrategyGame> -s res://tools/itqa_battle_probe.gd -- --mode=scripted --tag=qa --inject-turn=0 --out-dir="<abs dir>"

const SimControllerCls = preload("res://scripts/sim/sim_controller.gd")
const ObsCls = preload("res://scripts/cloud1/cloud1_observation.gd")
const TableCls = preload("res://scripts/cloud1/cloud1_action_table.gd")
const CompilerCls = preload("res://scripts/cloud1/cloud1_compiler.gd")
const ScenariosCls = preload("res://scripts/cloud2/cloud2_debug_scenarios.gd")
const CoordMenuCls = preload("res://scripts/cloud2/cloud2_coord_menu.gd")
const MissionCls = preload("res://scripts/cloud2/cloud2_mission.gd")
const PlanCls = preload("res://scripts/cloud2/cloud2_general_plan.gd")
const ManagerCls = preload("res://scripts/cloud2/cloud2_mission_manager.gd")
const OpportunityCls = preload("res://scripts/cloud2/cloud2_opportunity.gd")
const ResponseCls = preload("res://scripts/cloud2/cloud2_response.gd")

const QA_TURNS := 8

var _out_dir := ""
var _mode := "scripted"
var _tag := "qa"
var _inject_turn := 0


func _init() -> void:
	_parse_args()
	if _out_dir.is_empty():
		print("[ITQA] FATAL: need --out-dir=<abs dir>")
		quit(4)
		return
	var res := {}
	match _mode:
		"scripted":
			res = {"battle": _run_scripted_battle()}
		"determinism":
			res = _mode_determinism()
		_:
			print("[ITQA] FATAL: unknown mode %s" % _mode)
			quit(4)
			return
	_write("%s_%s.json" % [_tag, _mode], res)
	print("[ITQA] mode=%s ok=%s" % [_mode, str(bool(res.get("ok", (res.get("battle", {}) as Dictionary).get("ok", true))))])
	quit(0)


func _parse_args() -> void:
	var all: Array = []
	all.append_array(OS.get_cmdline_user_args())
	all.append_array(OS.get_cmdline_args())
	for a_val in all:
		var a := str(a_val).strip_edges()
		if a.begins_with("--out-dir="):
			_out_dir = a.get_slice("=", 1).strip_edges().trim_prefix("\"").trim_suffix("\"")
		elif a.begins_with("--mode="):
			_mode = a.get_slice("=", 1).strip_edges()
		elif a.begins_with("--tag="):
			_tag = a.get_slice("=", 1).strip_edges()
		elif a.begins_with("--inject-turn="):
			_inject_turn = int(a.get_slice("=", 1).strip_edges())


func _write(name: String, data: Dictionary) -> void:
	var path := _out_dir.rstrip("/") + "/" + name
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		print("[ITQA] FATAL: cannot write %s" % path)
		return
	f.store_string(JSON.stringify(data, "  "))
	f.close()
	print("[ITQA] wrote %s" % path)


func _load(scenario_id: String) -> Dictionary:
	var built: Dictionary = ScenariosCls.build(scenario_id)
	if not bool(built.get("ok", false)):
		return {"ok": false}
	var sim: RefCounted = SimControllerCls.new()
	var loaded: Dictionary = sim.load_scenario(built.get("scenario", {}))
	if not bool(loaded.get("ok", false)):
		return {"ok": false}
	return {"ok": true, "sim": sim}


func _obs_of(sim: RefCounted) -> Dictionary:
	return ObsCls.build(sim, "red")


func _weaken(sim: RefCounted, uid: String, soldiers: int) -> void:
	var units: Dictionary = (sim.get_manager() as Object)._units
	if units.has(uid):
		(units[uid] as Dictionary)["soldier_count"] = soldiers


func _soldiers_of(sim: RefCounted, uid: String) -> int:
	var u: Dictionary = sim.get_manager().get_unit_by_id(uid)
	if u.is_empty():
		return 0
	return int(u.get("soldier_count", 0))


func _std_doctrine() -> Dictionary:
	return {"aggression": "STANDARD", "tempo": "STANDARD", "risk": "BALANCED", "reserve": "STANDARD", "pursuit": "STANDARD"}


func _mission_dict(mid: String, task: String, area: String, units: Array, objective: Dictionary,
	policy: String, success: Array = [], aborts: Array = []) -> Dictionary:
	var m := MissionCls.default_mission(mid, task)
	m["area"] = area
	m["assigned_units"] = units.duplicate(true)
	m["objective"] = objective.duplicate(true)
	m["engagement"] = {"policy": policy}
	m["success_conditions"] = success.duplicate(true)
	var ab: Array = []
	for a_val in aborts:
		if a_val is Dictionary:
			ab.append(a_val)
		else:
			ab.append({"trigger": str(a_val), "params": {"mission_id": mid}})
	m["abort_conditions"] = ab
	m["report_conditions"] = []
	return m


func _plan_dict(missions: Array, obs: Dictionary) -> Dictionary:
	return {
		"plan_version": 1, "based_on_snapshot": str(obs.get("snapshot_id", "")),
		"created_turn": int(obs.get("turn", 1)), "last_review_turn": int(obs.get("turn", 1)),
		"mission": (obs.get("mission", {}) as Dictionary).duplicate(true),
		"concept": {"objective": "qa", "intent": "qa", "main_effort": "CENTER", "risk_posture": "BALANCED"},
		"doctrine": CoordMenuCls.doctrine_to_numeric(_std_doctrine()),
		"missions": missions, "contingencies": [], "opponent_hypotheses": [],
		"review_conditions": [{"trigger": "MISSION_BLOCKED", "params": {}}],
		"review_horizon_turns": 4, "source": "probe_forced",
	}


## Integrated v1 plan (HQ_CRITICAL): M01 FIX/HARD on the HQ-threatening
## B_CAV_1 (HQ defense expressed as designation, no new mission types);
## M02 FLANK/SOFT wing on the same T (exploit + later SOFT behavior);
## M03 HOLD the HQ. M02 carries a real abort (no success) so the failure
## leg is available; B_INF_1/B_ARC_1 stay unrelated for off-target detection.
func _qa_plan() -> Array:
	return [
		_mission_dict("M01", "FIX", "CENTER", ["R_ARC_1", "R_INF_1", "R_INF_2", "R_SPE_1"],
			{"kind": "ENEMY_FORMATION", "unit_id": "B_CAV_1"}, "ATTACK_DESIGNATED_ONLY",
			[{"trigger": "TARGET_DESTROYED", "params": {"unit_id": "B_CAV_1"}}],
			[{"trigger": "FORCE_STRENGTH_BELOW", "params": {}}]),
		_mission_dict("M02", "FLANK", "CENTER", ["R_CAV_1", "R_SCT_1"],
			{"kind": "ENEMY_FORMATION", "unit_id": "B_CAV_1"}, "PURSUE_WEAKENED",
			[],
			[{"trigger": "FORCE_STRENGTH_BELOW", "params": {}}]),
		_mission_dict("M03", "HOLD", "ANY", ["R_HQ_1"],
			{"kind": "ZONE", "zone": "HQ"}, "HOLD_FIRE"),
	]


func _execute_order(sim: RefCounted, o: Dictionary) -> Dictionary:
	var order: Dictionary = (o.get("order", {}) as Dictionary).duplicate(true)
	var gate: Dictionary = ResponseCls.check_order(order, {"acting_side": "RED"})
	var row := {"mission_id": str(o.get("mission_id", "?")), "command": order,
		"gate_ok": bool(gate.get("ok", false)), "gate_code": str(gate.get("code", "")),
		"ctx_used": o.has("exec_ctx")}
	if not bool(gate.get("ok", false)):
		row["exec_status"] = "GATE_REJECTED"
		row["executed"] = []
		row["failed"] = []
		row["cancelled"] = []
		return row
	# Production headless path: manager-attached exec_ctx enables
	# execution-time revalidation (group-retarget repair).
	var ex: Dictionary = CompilerCls.execute(sim, order, "", "red",
		(o.get("exec_ctx", {}) as Dictionary).duplicate(true))
	row["exec_status"] = str(ex.get("execution_status", "?"))
	row["executed"] = ex.get("executed_units", [])
	row["failed"] = ex.get("execution_failed", [])
	row["cancelled"] = ex.get("cancelled_units", [])
	row["plan_failed"] = ex.get("plan_failed", [])
	return row


func _sel_kind(t: Dictionary) -> String:
	for o_val in (t.get("options", []) as Array):
		if int((o_val as Dictionary).get("slot", -2)) == int(t.get("selected_slot", -1)):
			return str((o_val as Dictionary).get("kind", ""))
	return ""


## Service one MISSION_FAILED review through the production ADJUST path
## (menu-derived baseline, one group re-picked, expand_adjust, apply_plan).
## Mirrors the lifecycle gate's proven vehicle. Returns the service record.
func _service_adjust(sim: RefCounted, mgr: RefCounted, obs: Dictionary, turn: int) -> Dictionary:
	var menu: Dictionary = CoordMenuCls.build_menu(obs)
	var baseline := {"choices": {}}
	var changes: Array = []
	var first := true
	for g_val in (menu.get("groups", []) as Array):
		var g: Dictionary = g_val
		var opts: Array = g.get("options", [])
		if opts.is_empty() or not (opts[0] is Dictionary) or not (opts[0] as Dictionary).has("id"):
			continue
		var gid := str(g.get("id", ""))
		(baseline["choices"] as Dictionary)[gid] = str((opts[0] as Dictionary).get("id", ""))
		if first and opts.size() > 1:
			changes.append({"group": gid, "choice": str((opts[1] as Dictionary).get("id", ""))})
			first = false
	var v_before := int(mgr.get_plan().get("plan_version", 0))
	var expanded: Dictionary = CoordMenuCls.expand_adjust(menu, baseline, changes, turn,
		str(obs.get("snapshot_id", "")),
		(mgr.get_plan().get("mission", {}) as Dictionary).duplicate(true),
		mgr.get_plan(), [])
	var rec := {"serviced": false, "changes": changes, "version_before": v_before,
		"expand_ok": bool(expanded.get("ok", false)),
		"expand_code": str(expanded.get("code", "")), "version_after": v_before}
	if not bool(expanded.get("ok", false)):
		rec["detail"] = str(expanded.get("detail", ""))
		return rec
	var applied: Dictionary = mgr.apply_plan((expanded.get("plan", {}) as Dictionary).duplicate(true),
		turn, str(obs.get("snapshot_id", "")), str(obs.get("battle_id", "")))
	rec["apply_ok"] = bool(applied.get("ok", false))
	rec["apply_code"] = str(applied.get("code", ""))
	rec["version_after"] = int(applied.get("version", v_before))
	rec["serviced"] = bool(applied.get("ok", false))
	rec["m00_units_after"] = _m00_units(mgr.get_plan())
	rec["ownership_after"] = _ownership(mgr.get_plan(), ["R_CAV_1", "R_SCT_1"])
	return rec


func _m00_units(plan: Dictionary) -> Array:
	for m_val in (plan.get("missions", []) as Array):
		if m_val is Dictionary and str((m_val as Dictionary).get("mission_id", "")) == "M00" \
			and not str((m_val as Dictionary).get("status", "")) in ["SUCCESS", "FAILED", "ABORTED"]:
			return ((m_val as Dictionary).get("assigned_units", []) as Array).duplicate(true)
	return []


func _ownership(plan: Dictionary, uids: Array) -> Dictionary:
	var out := {}
	for uid in uids:
		var owner := ""
		for m_val in (plan.get("missions", []) as Array):
			var m: Dictionary = m_val
			if str(m.get("status", "")) in ["SUCCESS", "FAILED", "ABORTED"]:
				continue
			if str(uid) in ((m.get("assigned_units", []) as Array) as Array):
				owner = "%s/%s" % [str(m.get("mission_id", "")), str(m.get("task", ""))]
				break
		out[str(uid)] = owner
	return out


func _unit_mission_map(plan: Dictionary) -> Dictionary:
	var out := {}
	for m_val in (plan.get("missions", []) as Array):
		if not m_val is Dictionary:
			continue
		for u in (((m_val as Dictionary).get("assigned_units", []) as Array)):
			out[str(u)] = str((m_val as Dictionary).get("mission_id", ""))
	return out


func _blue_phase(sim: RefCounted) -> Array:
	var acts: Array = []
	var mgr: RefCounted = sim.get_manager()
	var ids: Array = []
	for u_val in mgr.get_all_units():
		var u: Dictionary = u_val
		if str(u.get("faction", "")) != "blue":
			continue
		if bool(u.get("action_ended", false)) or int(u.get("soldier_count", 0)) <= 0:
			continue
		ids.append(str(u.get("id", "")))
	ids.sort()
	for uid in ids:
		var u2: Dictionary = mgr.get_unit_by_id(uid)
		var cmd := {}
		if str(u2.get("class", "")) == "hq":
			cmd = TableCls.make_command("HOLD", TableCls.scope_units([uid]))
		else:
			var targets: Array = mgr.get_attackable_targets(uid)
			if targets.is_empty():
				cmd = TableCls.make_command("ADVANCE", TableCls.scope_units([uid]), TableCls.target_direction("EAST"))
			else:
				var tids: Array = []
				for t_val in targets:
					tids.append(str((t_val as Dictionary).get("id", "")))
				tids.sort()
				cmd = TableCls.make_command("ATTACK", TableCls.scope_units([uid]), TableCls.target_formation(tids[0]))
		var ex: Dictionary = CompilerCls.execute(sim, cmd, "", "blue")
		acts.append({"unit_id": uid, "command": cmd, "status": str(ex.get("execution_status", "?")),
			"executed": ex.get("executed_units", []), "failed": ex.get("execution_failed", [])})
	return acts


func _decisive(sim: RefCounted) -> bool:
	var blue_alive := 0
	var red_alive := 0
	for u_val in sim.get_manager().get_all_units():
		if int((u_val as Dictionary).get("soldier_count", 0)) > 0:
			if str((u_val as Dictionary).get("faction", "")) == "blue":
				blue_alive += 1
			elif str((u_val as Dictionary).get("faction", "")) == "red":
				red_alive += 1
	return blue_alive == 0 or red_alive == 0


func _mission_row(plan: Dictionary, mid: String) -> Dictionary:
	for m_val in (plan.get("missions", []) as Array):
		if m_val is Dictionary and str((m_val as Dictionary).get("mission_id", "")) == mid:
			return m_val
	return {}


func _run_scripted_battle() -> Dictionary:
	var l := _load("HQ_CRITICAL")
	if not bool(l.get("ok", false)):
		return {"ok": false, "detail": "load failed"}
	var sim: RefCounted = l["sim"]
	var mgr := ManagerCls.new()
	var obs0: Dictionary = _obs_of(sim)
	var applied: Dictionary = mgr.apply_plan(_plan_dict(_qa_plan(), obs0), 1,
		str(obs0.get("snapshot_id", "")), str(obs0.get("battle_id", "")))
	if not bool(applied.get("ok", false)):
		return {"ok": false, "detail": "apply failed: %s" % str(applied.get("code", ""))}
	var turns: Array = []
	var exec_index := 0
	var prev_events := 0
	var adjust_done := false
	var failed_service_turn := 0
	for t in range(1, QA_TURNS + 1):
		if _inject_turn == t:
			# M02 wing baseline is 470 (320 + 150); dropping the cavalry to
			# 60 puts the mission at 210 < 470*0.5 (mlc vehicle, legitimate
			# FORCE_STRENGTH_BELOW condition).
			_weaken(sim, "R_CAV_1", 60)
		var obs: Dictionary = _obs_of(sim)
		if not bool(obs.get("ok", false)):
			break
		var turn := int(obs.get("turn", t))
		var decided: Dictionary = mgr.red_turn(sim, obs)
		var plan: Dictionary = mgr.get_plan()
		var trow := {"turn": turn, "snapshot_id": str(obs.get("snapshot_id", "")),
			"plan_version": int(plan.get("plan_version", 0)),
			"review": decided.get("review", {}),
			"statuses": decided.get("statuses", []),
			"m00_units": _m00_units(plan),
			"fallback_provenance": (plan.get("fallback_provenance", []) as Array).duplicate(true),
			"unit_mission": _unit_mission_map(plan),
			"unit_rows": [], "orders": [], "blue": [],
			"hq_threatened": bool(OpportunityCls.hq_threatened(obs).get("threatened", false)),
			"hq_hp": _soldiers_of(sim, "R_HQ_1"),
			"t_hp": {"B_CAV_1": _soldiers_of(sim, "B_CAV_1"),
				"B_INF_1": _soldiers_of(sim, "B_INF_1"),
				"B_ARC_1": _soldiers_of(sim, "B_ARC_1")}}
		for tr_val in (decided.get("traces", []) as Array):
			var tr: Dictionary = tr_val
			for u_val in (tr.get("units", []) as Array):
				var u: Dictionary = u_val
				var mrow := _mission_row(plan, str(u.get("mission_id", "?")))
				(trow["unit_rows"] as Array).append({"unit_id": str(u.get("unit_id", "?")),
					"mission_id": str(u.get("mission_id", "?")),
					"mission_target_id": str((mrow.get("objective", {}) as Dictionary).get("unit_id", "")),
					"policy": str((mrow.get("engagement", {}) as Dictionary).get("policy", "")),
					"dpol": str(u.get("designation_policy", "NONE")),
					"selected": str(u.get("selected_id", "?")), "kind": _sel_kind(u),
					"resolved_target": str(u.get("resolved_target", "")),
					"resolved_destination": u.get("resolved_destination", []),
					"match": u.get("target_match", null),
					"reason": str(u.get("target_substitution_reason", ""))})
		var acted: Array = []
		for o_val in (decided.get("orders", []) as Array):
			var ex := _execute_order(sim, o_val)
			for e_val in (ex.get("executed", []) as Array):
				(e_val as Dictionary)["execution_index"] = exec_index
				exec_index += 1
				acted.append({"unit_id": str((e_val as Dictionary).get("unit_id", ""))})
			for f_val in (ex.get("failed", []) as Array):
				(f_val as Dictionary)["execution_index"] = exec_index
				exec_index += 1
			for c_val in (ex.get("cancelled", []) as Array):
				(c_val as Dictionary)["execution_index"] = exec_index
				exec_index += 1
			(trow["orders"] as Array).append(ex)
		mgr.post_turn(acted, turn)
		# Service the FIRST MISSION_FAILED review via production ADJUST (the
		# decision itself is SYSTEM_DEBUG; the path is production).
		var rev: Dictionary = decided.get("review", {})
		if not adjust_done and str(rev.get("trigger", "")) == "MISSION_FAILED":
			adjust_done = true
			failed_service_turn = turn
			trow["adjust_service"] = _service_adjust(sim, mgr, _obs_of(sim), turn)
		var events: Array = mgr.get_events()
		var delta: Array = []
		for i in range(prev_events, events.size()):
			delta.append(str((events[i] as Dictionary).get("kind", "?")))
		prev_events = events.size()
		trow["events_added"] = events.size()
		trow["events_delta"] = delta
		trow["blue"] = _blue_phase(sim)
		trow["fingerprint_post"] = str(sim.fingerprint())
		trow["truth"] = _truth_map(sim)
		turns.append(trow)
		if _decisive(sim):
			break
		sim.sim_end_turn()
	return {"ok": true, "scenario": "HQ_CRITICAL", "inject_turn": _inject_turn,
		"adjust_serviced_turn": failed_service_turn, "turns": turns,
		"final_strength": _side_strength(sim)}


func _mode_determinism() -> Dictionary:
	var a := _run_scripted_battle()
	var b := _run_scripted_battle()
	var fa: Array = []
	var fb: Array = []
	var sa: Array = []
	var sb: Array = []
	var ta: Array = []
	var tb: Array = []
	var ra: Array = []
	var rb: Array = []
	var ca: Array = []
	var cb: Array = []
	for t_val in (a.get("turns", []) as Array):
		fa.append(str((t_val as Dictionary).get("fingerprint_post", "")))
		sa.append(_exec_sig(t_val))
		ta.append(_transition_sig(t_val))
		ra.append(str(((t_val as Dictionary).get("review", {}) as Dictionary).get("trigger", "")))
		ca.append(_cancel_sig(t_val))
	for t2_val in (b.get("turns", []) as Array):
		fb.append(str((t2_val as Dictionary).get("fingerprint_post", "")))
		sb.append(_exec_sig(t2_val))
		tb.append(_transition_sig(t2_val))
		rb.append(str(((t2_val as Dictionary).get("review", {}) as Dictionary).get("trigger", "")))
		cb.append(_cancel_sig(t2_val))
	return {"ok": true, "fingerprints_match": fa == fb, "exec_match": sa == sb,
		"transitions_match": ta == tb, "reviews_match": ra == rb,
		"cancels_match": ca == cb, "turns_a": fa.size(), "turns_b": fb.size()}


func _exec_sig(t_val: Dictionary) -> String:
	var parts: Array = []
	for o_val in ((t_val as Dictionary).get("orders", []) as Array):
		var o: Dictionary = o_val
		for e_val in (o.get("executed", []) as Array):
			var e: Dictionary = e_val
			parts.append("%s:%s:%s>%s" % [str(e.get("unit_id", "")), str(e.get("action", "")),
				str(e.get("original_target_id", e.get("target_unit_id", ""))), str(e.get("target_unit_id", ""))])
		for f_val in (o.get("failed", []) as Array):
			parts.append("FAIL:%s:%s" % [str((f_val as Dictionary).get("unit_id", "")), str((f_val as Dictionary).get("code", ""))])
		for x_val in (o.get("cancelled", []) as Array):
			parts.append("CANCEL:%s:%s" % [str((x_val as Dictionary).get("unit_id", "")), str((x_val as Dictionary).get("cancel_reason", "?"))])
	parts.sort()
	return "|".join(parts)


func _transition_sig(t_val: Dictionary) -> String:
	var parts: Array = []
	for s_val in ((t_val as Dictionary).get("statuses", []) as Array):
		var s: Dictionary = s_val
		parts.append("%s=%s/%s@%d" % [str(s.get("mission_id", "?")), str(s.get("status", "?")),
			str(s.get("reason", "")), int(s.get("turn", 0))])
	parts.sort()
	return "|".join(parts)


func _cancel_sig(t_val: Dictionary) -> String:
	var n_cancel := 0
	var n_retarget := 0
	for o_val in ((t_val as Dictionary).get("orders", []) as Array):
		n_cancel += ((o_val as Dictionary).get("cancelled", []) as Array).size()
		for e_val in ((o_val as Dictionary).get("executed", []) as Array):
			if (e_val as Dictionary).has("original_target_id"):
				n_retarget += 1
	return "%d/%d" % [n_cancel, n_retarget]


func _truth_map(sim: RefCounted) -> Dictionary:
	var out := {}
	for u_val in sim.get_manager().get_all_units_including_garrisoned():
		var u: Dictionary = u_val
		out[str(u.get("id", ""))] = int(u.get("soldier_count", 0))
	return out


func _side_strength(sim: RefCounted) -> Dictionary:
	var out := {"red": 0, "blue": 0}
	for u_val in sim.get_manager().get_all_units_including_garrisoned():
		var u: Dictionary = u_val
		if int(u.get("soldier_count", 0)) <= 0:
			continue
		if str(u.get("faction", "")) == "red":
			out["red"] = int(out["red"]) + int(u.get("soldier_count", 0))
		elif str(u.get("faction", "")) == "blue":
			out["blue"] = int(out["blue"]) + int(u.get("soldier_count", 0))
	return out
