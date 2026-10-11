extends SceneTree

## TARGET-COHERENCE repair gate probe (SYSTEM_DEBUG visibility, read/write sim
## ONLY through the normal stack: manager.red_turn -> response gate ->
## compiler.execute -> sim_end_turn; BLUE via the same rules as the harness).
##
## Modes (--mode=trace|battle_coop|battle_hq|invalidation|determinism):
##   trace: t1 controlled per-unit target classification (menu vs designated).
##   battle_coop/battle_hq: multi-turn designated-plan battles with traces.
##   invalidation: run until designated T dies; record mission/sibling behavior.
##   determinism: battle_coop twice; compare fingerprints + executed signatures.
##
## Usage:
##   Godot console --headless --path <StrategyGame> -s res://tools/bvh_target_probe.gd -- --mode=trace --out-dir="<abs dir>"

const SimControllerCls = preload("res://scripts/sim/sim_controller.gd")
const ObsCls = preload("res://scripts/cloud1/cloud1_observation.gd")
const TableCls = preload("res://scripts/cloud1/cloud1_action_table.gd")
const CompilerCls = preload("res://scripts/cloud1/cloud1_compiler.gd")
const ScenariosCls = preload("res://scripts/cloud2/cloud2_debug_scenarios.gd")
const CoordMenuCls = preload("res://scripts/cloud2/cloud2_coord_menu.gd")
const MissionCls = preload("res://scripts/cloud2/cloud2_mission.gd")
const PlanCls = preload("res://scripts/cloud2/cloud2_general_plan.gd")
const ManagerCls = preload("res://scripts/cloud2/cloud2_mission_manager.gd")
const ControllerCls = preload("res://scripts/cloud2/cloud2_mission_controller.gd")
const OpportunityCls = preload("res://scripts/cloud2/cloud2_opportunity.gd")
const ResponseCls = preload("res://scripts/cloud2/cloud2_response.gd")

var _out_dir := ""
var _mode := "trace"
var _tag := "before"


func _init() -> void:
	_parse_args()
	if _out_dir.is_empty():
		print("[TProbe] FATAL: need --out-dir=<abs dir>")
		quit(4)
		return
	var res := {}
	match _mode:
		"trace":
			res = _mode_trace()
		"battle_coop":
			res = {"battle": _run_designated_battle("COOP_BASELINE", _coop_plan(), "stationary", 6)}
		"battle_hq":
			res = {"battle": _run_designated_battle("HQ_CRITICAL", _hq_plan(), "aggressive", 8)}
		"invalidation":
			res = _mode_invalidation()
		"determinism":
			res = _mode_determinism()
		_:
			print("[TProbe] FATAL: unknown mode %s" % _mode)
			quit(4)
			return
	_write("%s_%s.json" % [_tag, _mode] if _mode != "trace" else "%s_trace.json" % _tag, res)
	print("[TProbe] mode=%s ok=%s" % [_mode, str(bool(res.get("ok", true)))])
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


func _write(name: String, data: Dictionary) -> void:
	var path := _out_dir.rstrip("/") + "/" + name
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		print("[TProbe] FATAL: cannot write %s" % path)
		return
	f.store_string(JSON.stringify(data, "  "))
	f.close()
	print("[TProbe] wrote %s" % path)


func _load(scenario_id: String) -> Dictionary:
	var built: Dictionary = ScenariosCls.build(scenario_id)
	if not bool(built.get("ok", false)):
		return {"ok": false}
	var sim: RefCounted = SimControllerCls.new()
	var loaded: Dictionary = sim.load_scenario(built.get("scenario", {}))
	if not bool(loaded.get("ok", false)):
		return {"ok": false}
	return {"ok": true, "sim": sim}


## Custom test geometry (scenario construction for the probe only; the
## tactical stack itself is never bypassed): cavalry adjacent to a healthy
## designated target, isolating the FLANK engagement filter.
func _load_adjacent() -> Dictionary:
	var built: Dictionary = ScenariosCls.build("HQ_CRITICAL")
	if not bool(built.get("ok", false)):
		return {"ok": false}
	var scn: Dictionary = (built.get("scenario", {}) as Dictionary).duplicate(true)
	var forces: Array = (scn.get("forces", []) as Array).duplicate(true)
	for f_val in forces:
		if f_val is Dictionary and str((f_val as Dictionary).get("id", "")) == "R_CAV_1":
			(f_val as Dictionary)["q"] = -22
			(f_val as Dictionary)["r"] = -2
	scn["forces"] = forces
	var sim: RefCounted = SimControllerCls.new()
	var loaded: Dictionary = sim.load_scenario(scn)
	if not bool(loaded.get("ok", false)):
		return {"ok": false}
	return {"ok": true, "sim": sim}


func _obs_of(sim: RefCounted) -> Dictionary:
	return ObsCls.build(sim, "red")


func _std_doctrine_profile() -> Dictionary:
	return {"aggression": "STANDARD", "tempo": "STANDARD", "risk": "BALANCED", "reserve": "STANDARD", "pursuit": "STANDARD"}


func _expand_menu(obs: Dictionary, assignments: Array) -> Dictionary:
	var menu: Dictionary = CoordMenuCls.build_menu(obs)
	var sel := {"concept": "FIX_AND_FLANK", "main_effort": "CENTER", "doctrine": _std_doctrine_profile(),
		"assignments": assignments, "horizon": 4, "hypotheses": []}
	return CoordMenuCls.expand_initial(menu, sel, int(obs.get("turn", 1)),
		str(obs.get("snapshot_id", "")), (obs.get("mission", {}) as Dictionary).duplicate(true), [])


func _mission_dict(mid: String, task: String, area: String, units: Array, objective: Dictionary, policy: String, success: Array = [], abort: Array = []) -> Dictionary:
	var m := MissionCls.default_mission(mid, task)
	m["area"] = area
	m["assigned_units"] = units.duplicate(true)
	m["objective"] = objective.duplicate(true)
	m["engagement"] = {"policy": policy}
	m["success_conditions"] = success.duplicate(true)
	m["abort_conditions"] = abort.duplicate(true)
	m["report_conditions"] = []
	return m


func _plan_dict(missions: Array, obs: Dictionary) -> Dictionary:
	return {
		"plan_version": 1, "based_on_snapshot": str(obs.get("snapshot_id", "")),
		"created_turn": int(obs.get("turn", 1)), "last_review_turn": int(obs.get("turn", 1)),
		"mission": (obs.get("mission", {}) as Dictionary).duplicate(true),
		"concept": {"objective": "probe", "intent": "probe", "main_effort": "CENTER", "risk_posture": "BALANCED"},
		"doctrine": CoordMenuCls.doctrine_to_numeric(_std_doctrine_profile()),
		"missions": missions, "contingencies": [], "opponent_hypotheses": [],
		"review_conditions": [{"trigger": "MISSION_BLOCKED", "params": {}}],
		"review_horizon_turns": 4, "source": "probe_forced",
	}


func _coop_plan() -> Array:
	return [
		_mission_dict("M01", "FIX", "CENTER", ["R_ARC_1", "R_INF_1", "R_INF_2", "R_SPE_1"],
			{"kind": "ENEMY_FORMATION", "unit_id": "B_INF_1"}, "ATTACK_DESIGNATED_ONLY",
			[{"trigger": "TARGET_DESTROYED", "params": {"unit_id": "B_INF_1"}}], ["FORCE_STRENGTH_BELOW"]),
		_mission_dict("M02", "FLANK", "CENTER", ["R_CAV_1", "R_SCT_1"],
			{"kind": "ENEMY_FORMATION", "unit_id": "B_INF_1"}, "PURSUE_WEAKENED",
			[{"trigger": "TARGET_DESTROYED", "params": {"unit_id": "B_INF_1"}}], ["FORCE_STRENGTH_BELOW"]),
		_mission_dict("M03", "HOLD", "ANY", ["R_HQ_1"],
			{"kind": "ZONE", "zone": "HQ"}, "HOLD_FIRE", ["MISSION_COMPLETE"], ["FORCE_STRENGTH_BELOW"]),
	]


func _hq_plan() -> Array:
	return [
		_mission_dict("M01", "FIX", "CENTER", ["R_ARC_1", "R_INF_1", "R_INF_2", "R_SPE_1"],
			{"kind": "ENEMY_FORMATION", "unit_id": "B_CAV_1"}, "ATTACK_DESIGNATED_ONLY",
			[{"trigger": "TARGET_DESTROYED", "params": {"unit_id": "B_CAV_1"}}], ["FORCE_STRENGTH_BELOW"]),
		_mission_dict("M02", "ATTACK", "CENTER", ["R_CAV_1", "R_SCT_1"],
			{"kind": "ENEMY_FORMATION", "unit_id": "B_CAV_1"}, "ATTACK_DESIGNATED_ONLY",
			[{"trigger": "TARGET_DESTROYED", "params": {"unit_id": "B_CAV_1"}}], ["FORCE_STRENGTH_BELOW"]),
		_mission_dict("M03", "HOLD", "ANY", ["R_HQ_1"],
			{"kind": "ZONE", "zone": "HQ"}, "HOLD_FIRE", ["MISSION_COMPLETE"], ["FORCE_STRENGTH_BELOW"]),
	]


func _t_visible(obs: Dictionary, tid: String) -> bool:
	for e_val in (obs.get("known_enemy_units", []) as Array):
		if e_val is Dictionary and str((e_val as Dictionary).get("unit_id", "")) == tid \
			and str((e_val as Dictionary).get("contact_state", "")) == "current_visible":
			return true
	return false


func _t_legal_rows(sim: RefCounted, obs: Dictionary, uid: String) -> Array:
	return OpportunityCls.legal_attacks(sim, [uid], obs)


func _classify(t: Dictionary, m: Dictionary, obs: Dictionary, sim: RefCounted) -> Dictionary:
	var obj: Dictionary = m.get("objective", {})
	var tid := str(obj.get("unit_id", "")) if str(obj.get("kind", "")) == "ENEMY_FORMATION" else ""
	if tid.is_empty():
		return {"class": "TARGET_UNREPRESENTABLE", "reason": "mission carries no ENEMY_FORMATION designation"}
	var vis := _t_visible(obs, tid)
	var rows := _t_legal_rows(sim, obs, str(t.get("unit_id", "?")))
	var legal := false
	for r_val in rows:
		if str((r_val as Dictionary).get("target_id", "")) == tid:
			legal = true
			break
	var sel := str(t.get("selected_id", "?"))
	var kind := ""
	for o_val in (t.get("options", []) as Array):
		if int((o_val as Dictionary).get("slot", -2)) == int(t.get("selected_slot", -1)):
			kind = str((o_val as Dictionary).get("kind", ""))
	var rt := str(t.get("resolved_target", ""))
	if kind == "ATTACK":
		if rt == tid:
			return {"class": "TARGET_PRESERVED", "reason": "attack resolves to designated T", "t_visible": vis, "t_legal": legal}
		return {"class": "TARGET_SUBSTITUTED", "reason": "attack resolves to %s, designated %s" % [rt, tid], "t_visible": vis, "t_legal": legal}
	if not vis:
		return {"class": "TARGET_DROPPED", "reason": "T not currently visible; non-attack selected (%s)" % sel, "t_visible": false, "t_legal": legal}
	if not legal:
		return {"class": "TARGET_DROPPED", "reason": "T valid but no legal row for this unit; non-attack selected (%s)" % sel, "t_visible": true, "t_legal": false}
	return {"class": "TARGET_DROPPED", "reason": "T valid+legal but non-attack selected (%s)" % sel, "t_visible": true, "t_legal": true}


func _decide_snapshot(sim: RefCounted, obs: Dictionary, plan: Dictionary) -> Dictionary:
	var bounds: Dictionary = sim.map_bounds() if sim.has_method("map_bounds") else {}
	var hq := bool(OpportunityCls.hq_threatened(obs).get("threatened", false))
	var turn := int(obs.get("turn", 1))
	var snap := str(obs.get("snapshot_id", ""))
	var doctrine: Dictionary = (plan.get("doctrine", {}) as Dictionary).duplicate(true)
	var out := {"hq_threatened": hq, "missions": []}
	for m_val in (plan.get("missions", []) as Array):
		var m: Dictionary = (m_val as Dictionary).duplicate(true)
		m["status"] = "ACTIVE"
		var ctrl := ControllerCls.new()
		ctrl.setup(m, doctrine, 11)
		var dctx := {"turn": turn, "snapshot_id": snap, "turns_active": 0,
			"urgency": 0.5 if hq else 0.0, "bounds": bounds, "main_effort": "CENTER"}
		var res: Dictionary = ctrl.decide(sim, obs, dctx)
		var trace: Dictionary = res.get("trace", {})
		var units: Array = []
		for t_val in (trace.get("units", []) as Array):
			var t: Dictionary = t_val
			var slots: Array = []
			for o_val in (t.get("options", []) as Array):
				var o: Dictionary = o_val
				slots.append({"slot": int(o.get("slot", -1)), "id": str(o.get("option_id", "?")),
					"kind": str(o.get("kind", "?")), "masked": bool(o.get("masked", false)),
					"mask": str(o.get("mask_reason", "")), "final": snappedf(float(o.get("final_score", 0.0)), 0.01),
					"tgt": str(o.get("resolved_target", "")), "dest": o.get("resolved_destination", []),
					"m_tgt": str(o.get("mission_target_id", "")), "dpol": str(o.get("designation_policy", "NONE")),
					"match": o.get("target_match", null), "reason": str(o.get("target_substitution_reason", "")),
					"dry": str(o.get("dry_code", ""))})
			units.append({"unit_id": str(t.get("unit_id", "?")), "class": str(t.get("unit_class", "?")),
				"selected": str(t.get("selected_id", "?")), "kind": _sel_kind(t),
				"resolved_target": str(t.get("resolved_target", "")),
				"resolved_destination": t.get("resolved_destination", []),
				"command": t.get("resolved_command", {}), "target_scores": t.get("target_scores", []),
				"m_tgt": str(t.get("mission_target_id", "")), "dpol": str(t.get("designation_policy", "NONE")),
				"match": t.get("target_match", null), "reason": str(t.get("target_substitution_reason", "")),
				"slots": slots, "target_class": _classify(t, m, obs, sim)})
		out["missions"].append({"mission_id": str(m.get("mission_id", "?")), "task": str(m.get("task", "?")),
			"area": str(m.get("area", "?")), "units": m.get("assigned_units", []),
			"objective": m.get("objective", {}), "engagement": m.get("engagement", {}),
			"status_hint": str(res.get("status_hint", "?")), "unit_tables": units})
	return out


func _sel_kind(t: Dictionary) -> String:
	for o_val in (t.get("options", []) as Array):
		if int((o_val as Dictionary).get("slot", -2)) == int(t.get("selected_slot", -1)):
			return str((o_val as Dictionary).get("kind", ""))
	return ""


func _mode_trace() -> Dictionary:
	var out := {"ok": true, "cases": {}}
	var l := _load("HQ_CRITICAL")
	if not bool(l.get("ok", false)):
		return {"ok": false}
	var obs: Dictionary = _obs_of(l["sim"])
	# Case 1: menu baseline (no designation possible).
	var e := _expand_menu(obs, [
		{"group": "G1", "choice": "G1_FIX_CENTER"},
		{"group": "G2", "choice": "G2_ATTACK_CENTER"},
		{"group": "G3", "choice": "G3_HOLD_ANY"}])
	out["cases"]["menu_baseline_hq"] = {"expand_ok": bool(e.get("ok", false)),
		"decided": _decide_snapshot(l["sim"], obs, e.get("plan", {}))} if bool(e.get("ok", false)) else {"expand_ok": false}
	# Case 2: designated-hard FIX on B_CAV_1.
	var p2: Dictionary = _plan_dict([
		_mission_dict("M01", "FIX", "CENTER", ["R_ARC_1", "R_INF_1", "R_INF_2", "R_SPE_1"],
			{"kind": "ENEMY_FORMATION", "unit_id": "B_CAV_1"}, "ATTACK_DESIGNATED_ONLY"),
		_mission_dict("M02", "ATTACK", "CENTER", ["R_CAV_1", "R_SCT_1"],
			{"kind": "REGION", "region": "CENTER"}, "ATTACK_IF_ADVANTAGEOUS"),
		_mission_dict("M03", "HOLD", "ANY", ["R_HQ_1"], {"kind": "ZONE", "zone": "HQ"}, "HOLD_FIRE"),
	], obs)
	var v2: Dictionary = PlanCls.validate_plan(p2, {"turn": 1, "snapshot_id": str(obs.get("snapshot_id", "")), "plan_version": 1})
	out["cases"]["desig_hard_fix"] = {"plan_valid": bool(v2.get("ok", false)),
		"decided": _decide_snapshot(l["sim"], obs, v2.get("plan", {}))}
	# Case 3: designated-soft FIX on B_CAV_1.
	var p3: Dictionary = _plan_dict([
		_mission_dict("M01", "FIX", "CENTER", ["R_ARC_1", "R_INF_1", "R_INF_2", "R_SPE_1"],
			{"kind": "ENEMY_FORMATION", "unit_id": "B_CAV_1"}, "ATTACK_IF_ADVANTAGEOUS"),
		_mission_dict("M02", "ATTACK", "CENTER", ["R_CAV_1", "R_SCT_1"],
			{"kind": "REGION", "region": "CENTER"}, "ATTACK_IF_ADVANTAGEOUS"),
		_mission_dict("M03", "HOLD", "ANY", ["R_HQ_1"], {"kind": "ZONE", "zone": "HQ"}, "HOLD_FIRE"),
	], obs)
	var v3: Dictionary = PlanCls.validate_plan(p3, {"turn": 1, "snapshot_id": str(obs.get("snapshot_id", "")), "plan_version": 1})
	out["cases"]["desig_soft_fix"] = {"plan_valid": bool(v3.get("ok", false)),
		"decided": _decide_snapshot(l["sim"], obs, v3.get("plan", {}))}
	# Case 4: designated FLANK (menu-template policy) on B_CAV_1.
	var p4: Dictionary = _plan_dict([
		_mission_dict("M01", "FIX", "CENTER", ["R_ARC_1", "R_INF_1", "R_INF_2", "R_SPE_1"],
			{"kind": "REGION", "region": "CENTER"}, "ATTACK_IF_ADVANTAGEOUS"),
		_mission_dict("M02", "FLANK", "CENTER", ["R_CAV_1", "R_SCT_1"],
			{"kind": "ENEMY_FORMATION", "unit_id": "B_CAV_1"}, "PURSUE_WEAKENED"),
		_mission_dict("M03", "HOLD", "ANY", ["R_HQ_1"], {"kind": "ZONE", "zone": "HQ"}, "HOLD_FIRE"),
	], obs)
	var v4: Dictionary = PlanCls.validate_plan(p4, {"turn": 1, "snapshot_id": str(obs.get("snapshot_id", "")), "plan_version": 1})
	out["cases"]["desig_flank"] = {"plan_valid": bool(v4.get("ok", false)),
		"decided": _decide_snapshot(l["sim"], obs, v4.get("plan", {}))}
	# Case 5: designated-hard ATTACK M02 on B_CAV_1.
	var p5: Dictionary = _plan_dict([
		_mission_dict("M01", "FIX", "CENTER", ["R_ARC_1", "R_INF_1", "R_INF_2", "R_SPE_1"],
			{"kind": "REGION", "region": "CENTER"}, "ATTACK_IF_ADVANTAGEOUS"),
		_mission_dict("M02", "ATTACK", "CENTER", ["R_CAV_1", "R_SCT_1"],
			{"kind": "ENEMY_FORMATION", "unit_id": "B_CAV_1"}, "ATTACK_DESIGNATED_ONLY"),
		_mission_dict("M03", "HOLD", "ANY", ["R_HQ_1"], {"kind": "ZONE", "zone": "HQ"}, "HOLD_FIRE"),
	], obs)
	var v5: Dictionary = PlanCls.validate_plan(p5, {"turn": 1, "snapshot_id": str(obs.get("snapshot_id", "")), "plan_version": 1})
	out["cases"]["desig_hard_attack"] = {"plan_valid": bool(v5.get("ok", false)),
		"decided": _decide_snapshot(l["sim"], obs, v5.get("plan", {}))}
	# Case 6: FLANK + designated healthy ADJACENT target (filter isolation).
	var la := _load_adjacent()
	if bool(la.get("ok", false)):
		var obsa: Dictionary = _obs_of(la["sim"])
		var p6: Dictionary = _plan_dict([
			_mission_dict("M01", "FIX", "CENTER", ["R_ARC_1", "R_INF_1", "R_INF_2", "R_SPE_1"],
				{"kind": "REGION", "region": "CENTER"}, "ATTACK_IF_ADVANTAGEOUS"),
			_mission_dict("M02", "FLANK", "CENTER", ["R_CAV_1", "R_SCT_1"],
				{"kind": "ENEMY_FORMATION", "unit_id": "B_INF_1"}, "PURSUE_WEAKENED"),
			_mission_dict("M03", "HOLD", "ANY", ["R_HQ_1"], {"kind": "ZONE", "zone": "HQ"}, "HOLD_FIRE"),
		], obsa)
		var v6: Dictionary = PlanCls.validate_plan(p6, {"turn": 1, "snapshot_id": str(obsa.get("snapshot_id", "")), "plan_version": 1})
		var rows_all: Array = OpportunityCls.legal_attacks(la["sim"], ["R_CAV_1"], obsa)
		out["cases"]["desig_flank_adjacent"] = {"plan_valid": bool(v6.get("ok", false)),
			"cav_legal_rows_unfiltered": rows_all,
			"decided": _decide_snapshot(la["sim"], obsa, v6.get("plan", {}))}
	return out


func _blue_phase(sim: RefCounted, policy: String) -> Array:
	var acts: Array = []
	if policy == "stationary":
		return acts
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
		elif policy == "aggressive":
			var targets: Array = mgr.get_attackable_targets(uid)
			if targets.is_empty():
				cmd = TableCls.make_command("ADVANCE", TableCls.scope_units([uid]), TableCls.target_direction("EAST"))
			else:
				var tids: Array = []
				for t_val in targets:
					tids.append(str((t_val as Dictionary).get("id", "")))
				tids.sort()
				cmd = TableCls.make_command("ATTACK", TableCls.scope_units([uid]), TableCls.target_formation(tids[0]))
		else:
			cmd = TableCls.make_command("ADVANCE", TableCls.scope_units([uid]), TableCls.target_direction("EAST"))
		var ex: Dictionary = CompilerCls.execute(sim, cmd, "", "blue")
		acts.append({"unit_id": uid, "command": cmd, "status": str(ex.get("execution_status", "?")),
			"executed": ex.get("executed_units", [])})
	return acts


func _run_designated_battle(scenario_id: String, missions: Array, blue_policy: String, max_turns: int) -> Dictionary:
	var l := _load(scenario_id)
	if not bool(l.get("ok", false)):
		return {"ok": false, "detail": "load failed"}
	var sim: RefCounted = l["sim"]
	var mgr := ManagerCls.new()
	var obs0: Dictionary = _obs_of(sim)
	var plan: Dictionary = _plan_dict(missions, obs0)
	var applied: Dictionary = mgr.apply_plan(plan, 1, str(obs0.get("snapshot_id", "")), str(obs0.get("battle_id", "")))
	if not bool(applied.get("ok", false)):
		return {"ok": false, "detail": "apply failed: %s %s" % [str(applied.get("code", "")), str(applied.get("detail", ""))]}
	var turns: Array = []
	for t in range(1, max_turns + 1):
		var obs: Dictionary = _obs_of(sim)
		if not bool(obs.get("ok", false)):
			break
		var turn := int(obs.get("turn", t))
		var decided: Dictionary = mgr.red_turn(sim, obs)
		var trow := {"turn": turn, "snapshot_id": str(obs.get("snapshot_id", "")),
			"orders": [], "executed_units": 0, "gate_rejected": 0, "exec_invalid": 0,
			"unit_rows": [], "mission_statuses": [], "blue": []}
		var acted: Array = []
		for o_val in (decided.get("orders", []) as Array):
			var mid := str((o_val as Dictionary).get("mission_id", "?"))
			var order: Dictionary = (o_val as Dictionary).get("order", {})
			var gate: Dictionary = ResponseCls.check_order(order, {"acting_side": "RED"})
			var orow := {"mission_id": mid, "gate_ok": bool(gate.get("ok", false)),
				"gate_code": str(gate.get("code", "")), "exec_status": "GATE_REJECTED",
				"executed": [], "failed": []}
			if bool(gate.get("ok", false)):
				var ex: Dictionary = CompilerCls.execute(sim, order, "", "red")
				orow["exec_status"] = str(ex.get("execution_status", "?"))
				orow["executed"] = ex.get("executed_units", [])
				orow["failed"] = ex.get("execution_failed", [])
				for e_val in (ex.get("executed_units", []) as Array):
					acted.append({"unit_id": str((e_val as Dictionary).get("unit_id", ""))})
					trow["executed_units"] = int(trow["executed_units"]) + 1
				for f_val in (ex.get("execution_failed", []) as Array):
					if str((f_val as Dictionary).get("code", "")) == "TARGET_UNREACHABLE":
						trow["exec_invalid"] = int(trow["exec_invalid"]) + 1
			else:
				trow["gate_rejected"] = int(trow["gate_rejected"]) + 1
			(trow["orders"] as Array).append(orow)
		mgr.post_turn(acted, turn)
		if mgr.has_method("status_rows"):
			trow["mission_statuses"] = mgr.status_rows()
		for tr_val in (decided.get("traces", []) as Array):
			var tr: Dictionary = tr_val
			for u_val in (tr.get("units", []) as Array):
				var u: Dictionary = u_val
				var mrow := _mission_row(mgr.get_plan(), str(u.get("mission_id", "?")))
				trow["unit_rows"].append({"unit_id": str(u.get("unit_id", "?")),
					"mission_id": str(u.get("mission_id", "?")),
					"mission_target_type": str((mrow.get("objective", {}) as Dictionary).get("kind", "")),
					"mission_target_id": str((mrow.get("objective", {}) as Dictionary).get("unit_id", "")),
					"policy": str((mrow.get("engagement", {}) as Dictionary).get("policy", "")),
					"selected": str(u.get("selected_id", "?")), "kind": _sel_kind(u),
					"resolved_target": str(u.get("resolved_target", "")),
					"resolved_destination": u.get("resolved_destination", []),
					"command": u.get("resolved_command", {}),
					"target_scores": u.get("target_scores", []),
					"dpol": str(u.get("designation_policy", "NONE")),
					"match": u.get("target_match", null),
					"reason": str(u.get("target_substitution_reason", "")),
					"target_class": _classify(u, mrow, obs, sim)})
		trow["blue"] = _blue_phase(sim, blue_policy)
		trow["fingerprint_post"] = str(sim.fingerprint())
		trow["truth"] = _truth_rows(sim)
		turns.append(trow)
		if _decisive(sim):
			break
		sim.sim_end_turn()
	return {"ok": true, "scenario": scenario_id, "turns": turns,
		"final_strength": _side_strength(sim)}


func _mission_row(plan: Dictionary, mid: String) -> Dictionary:
	for m_val in (plan.get("missions", []) as Array):
		if m_val is Dictionary and str((m_val as Dictionary).get("mission_id", "")) == mid:
			return m_val
	return {}


func _truth_rows(sim: RefCounted) -> Array:
	var rows: Array = []
	for u_val in sim.get_manager().get_all_units_including_garrisoned():
		var u: Dictionary = u_val
		rows.append({"id": str(u.get("id", "")), "faction": str(u.get("faction", "")),
			"class": str(u.get("class", "")), "q": int(u.get("q", 0)), "r": int(u.get("r", 0)),
			"soldiers": int(u.get("soldier_count", 0))})
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a.get("id", "")) < str(b.get("id", "")))
	return rows


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


func _mode_invalidation() -> Dictionary:
	var b: Dictionary = _run_designated_battle("HQ_CRITICAL", _hq_plan(), "aggressive", 8)
	if not bool(b.get("ok", false)):
		return {"ok": false}
	var t_dead_turn := 0
	for t_val in (b.get("turns", []) as Array):
		var t: Dictionary = t_val
		var alive := false
		for r_val in (t.get("truth", []) as Array):
			if str((r_val as Dictionary).get("id", "")) == "B_CAV_1" and int((r_val as Dictionary).get("soldiers", 0)) > 0:
				alive = true
		if not alive:
			t_dead_turn = int(t.get("turn", 0))
			break
	return {"ok": true, "b_cav_1_dead_after_turn": t_dead_turn, "battle": b}


func _mode_determinism() -> Dictionary:
	var a: Dictionary = _run_designated_battle("COOP_BASELINE", _coop_plan(), "stationary", 6)
	var b2: Dictionary = _run_designated_battle("COOP_BASELINE", _coop_plan(), "stationary", 6)
	var fa: Array = []
	var fb: Array = []
	var sa: Array = []
	var sb: Array = []
	for t_val in (a.get("turns", []) as Array):
		fa.append(str((t_val as Dictionary).get("fingerprint_post", "")))
		sa.append(_exec_sig(t_val))
	for t2_val in (b2.get("turns", []) as Array):
		fb.append(str((t2_val as Dictionary).get("fingerprint_post", "")))
		sb.append(_exec_sig(t2_val))
	return {"ok": true, "fingerprints_a": fa, "fingerprints_b": fb,
		"fingerprints_match": fa == fb, "exec_match": sa == sb}


func _exec_sig(t_val: Dictionary) -> String:
	var parts: Array = []
	for o_val in ((t_val as Dictionary).get("orders", []) as Array):
		var o: Dictionary = o_val
		for e_val in (o.get("executed", []) as Array):
			var e: Dictionary = e_val
			parts.append("%s:%s:%s:%s" % [str(e.get("unit_id", "")), str(e.get("action", "")),
				str(e.get("target_unit_id", "")), JSON.stringify(e.get("to", []))])
		for f_val in (o.get("failed", []) as Array):
			parts.append("FAIL:%s:%s" % [str((f_val as Dictionary).get("unit_id", "")), str((f_val as Dictionary).get("code", ""))])
	parts.sort()
	return "|".join(parts)
