extends SceneTree

## GROUP RETARGET repair gate probe (SYSTEM_DEBUG visibility, read/write sim
## ONLY through the normal stack: manager.red_turn -> response gate ->
## compiler.execute -> sim_end_turn; forced designated plans are the test
## vehicle, same as the target-coherence gate).
##
## Modes (--mode=waste|matrix|coop|determinism):
##   waste:  mission-path single RED turn on kill-geometry; group order
##           execution plus a split-replay attribution instrument.
##   matrix: controlled cases A..G (HARD survive/early/mid, SOFT, mission-
##           complete, invalid-before-batch, different-targets).
##   coop:   multi-turn designated coop battle with stale-failure accounting.
##   determinism: matrix + coop twice; compare fingerprints + exec signatures.
##
## Flags: --tag=before|after --ctx=off|on --out-dir="<abs dir>"
##   ctx=off issues legacy 4-arg compiler.execute calls (BEFORE code).
##   ctx=on  threads each order's manager-attached exec_ctx (AFTER code).
##
## Usage:
##   Godot console --headless --path <StrategyGame> -s res://tools/grr_retarget_probe.gd -- --mode=matrix --tag=before --ctx=off --out-dir="<abs dir>"

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
var _mode := "waste"
var _tag := "before"
var _use_ctx := false


func _init() -> void:
	_parse_args()
	if _out_dir.is_empty():
		print("[GRR] FATAL: need --out-dir=<abs dir>")
		quit(4)
		return
	var res := {}
	match _mode:
		"waste":
			res = _mode_waste()
		"matrix":
			res = _mode_matrix()
		"coop":
			res = {"battle": _run_coop_battle()}
		"determinism":
			res = _mode_determinism()
		_:
			print("[GRR] FATAL: unknown mode %s" % _mode)
			quit(4)
			return
	_write("%s_%s.json" % [_tag, _mode], res)
	print("[GRR] mode=%s ctx=%s ok=%s" % [_mode, "on" if _use_ctx else "off", str(bool(res.get("ok", true)))])
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
		elif a.begins_with("--ctx="):
			_use_ctx = a.get_slice("=", 1).strip_edges().to_lower() == "on"


func _write(name: String, data: Dictionary) -> void:
	var path := _out_dir.rstrip("/") + "/" + name
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		print("[GRR] FATAL: cannot write %s" % path)
		return
	f.store_string(JSON.stringify(data, "  "))
	f.close()
	print("[GRR] wrote %s" % path)


func _load(scenario_id: String) -> Dictionary:
	var built: Dictionary = ScenariosCls.build(scenario_id)
	if not bool(built.get("ok", false)):
		return {"ok": false}
	var sim: RefCounted = SimControllerCls.new()
	var loaded: Dictionary = sim.load_scenario(built.get("scenario", {}))
	if not bool(loaded.get("ok", false)):
		return {"ok": false}
	return {"ok": true, "sim": sim}


## Matrix geometry: T adjacent to a 3-RED fixing group; U/V fallback
## neighbors for SOFT retarget; T2 cell for the different-targets case.
## force_patch: [{id, q, r, soldiers}] applied onto COOP_BASELINE.
func _load_matrix(patch: Array) -> Dictionary:
	var built: Dictionary = ScenariosCls.build("COOP_BASELINE")
	if not bool(built.get("ok", false)):
		return {"ok": false}
	var scn: Dictionary = (built.get("scenario", {}) as Dictionary).duplicate(true)
	var forces: Array = (scn.get("forces", []) as Array).duplicate(true)
	for p_val in patch:
		var p: Dictionary = p_val
		for f_val in forces:
			if f_val is Dictionary and str((f_val as Dictionary).get("id", "")) == str(p.get("id", "")):
				if p.has("q"):
					(f_val as Dictionary)["q"] = int(p.get("q", 0))
				if p.has("r"):
					(f_val as Dictionary)["r"] = int(p.get("r", 0))
				if p.has("soldiers"):
					(f_val as Dictionary)["soldiers"] = int(p.get("soldiers", 0))
	scn["forces"] = forces
	var sim: RefCounted = SimControllerCls.new()
	var loaded: Dictionary = sim.load_scenario(scn)
	if not bool(loaded.get("ok", false)):
		return {"ok": false}
	return {"ok": true, "sim": sim}


## Fixing group: R_INF_1/R_INF_2/R_CAV_1 (all own a general ATTACK slot;
## the spearman's only ATTACK slot is anti-cavalry, so it cannot sibling on
## an infantry T). T=B_INF_1. U/V are per-sibling SOFT fallbacks.
## Kill-index determinism (combat: 60% cap, min-1 casualty): T=1 dies on the
## 1st hit, T=2 on the 2nd, T=450 survives a 3-sibling order.
func _base_patch() -> Array:
	return [
		{"id": "B_INF_1", "q": -24, "r": -1},
		{"id": "R_INF_1", "q": -23, "r": -1},
		{"id": "R_INF_2", "q": -24, "r": 0},
		{"id": "R_CAV_1", "q": -25, "r": -1},
		{"id": "B_INF_2", "q": -23, "r": 0},
		{"id": "B_SPE_1", "q": -25, "r": 0},
	]


func _obs_of(sim: RefCounted) -> Dictionary:
	return ObsCls.build(sim, "red")


## Deterministic attrition injection (probe harness only; mirrors the
## lifecycle gate's white-box pattern on engine-owned unit dicts).
func _weaken(sim: RefCounted, uid: String, soldiers: int) -> void:
	var units: Dictionary = (sim.get_manager() as Object)._units
	if units.has(uid):
		(units[uid] as Dictionary)["soldier_count"] = soldiers


func _std_doctrine_profile() -> Dictionary:
	return {"aggression": "STANDARD", "tempo": "STANDARD", "risk": "BALANCED", "reserve": "STANDARD", "pursuit": "STANDARD"}


func _mission_dict(mid: String, task: String, area: String, units: Array, objective: Dictionary, policy: String, success: Array = []) -> Dictionary:
	var m := MissionCls.default_mission(mid, task)
	m["area"] = area
	m["assigned_units"] = units.duplicate(true)
	m["objective"] = objective.duplicate(true)
	m["engagement"] = {"policy": policy}
	m["success_conditions"] = success.duplicate(true)
	m["abort_conditions"] = []
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


func _rest_units() -> Array:
	return ["R_SPE_1", "R_ARC_1", "R_SCT_1", "R_HQ_1"]


func _soldiers_of(sim: RefCounted, uid: String) -> int:
	var u: Dictionary = sim.get_manager().get_unit_by_id(uid)
	if u.is_empty():
		return 0
	return int(u.get("soldier_count", 0))


func _alive_map(sim: RefCounted, ids: Array) -> Dictionary:
	var out := {}
	for uid in ids:
		out[str(uid)] = _soldiers_of(sim, str(uid)) > 0
	return out


## One production-path order execution: response gate then compiler.
## Threads the manager-attached exec_ctx only when --ctx=on (AFTER code).
func _execute_order(sim: RefCounted, o: Dictionary) -> Dictionary:
	var order: Dictionary = (o.get("order", {}) as Dictionary).duplicate(true)
	var gate: Dictionary = ResponseCls.check_order(order, {"acting_side": "RED"})
	var row := {"mission_id": str(o.get("mission_id", "?")), "command": order,
		"gate_ok": bool(gate.get("ok", false)), "gate_code": str(gate.get("code", "")),
		"ctx_attached": o.has("exec_ctx"), "ctx_used": false}
	if not bool(gate.get("ok", false)):
		row["exec_status"] = "GATE_REJECTED"
		row["executed"] = []
		row["failed"] = []
		row["cancelled"] = []
		return row
	var ex: Dictionary
	if _use_ctx and o.has("exec_ctx"):
		row["ctx_used"] = true
		# Dynamic dispatch: BEFORE compiler code has no 5th parameter and
		# GDScript parse-checks static-call arity, so callv keeps one probe
		# binary working for both BEFORE (never taken) and AFTER runs.
		ex = Callable(CompilerCls, "execute").callv([sim, order, "", "red",
			(o.get("exec_ctx", {}) as Dictionary).duplicate(true)])
	else:
		ex = CompilerCls.execute(sim, order, "", "red")
	row["exec_status"] = str(ex.get("execution_status", "?"))
	row["executed"] = ex.get("executed_units", [])
	row["failed"] = ex.get("execution_failed", [])
	row["cancelled"] = ex.get("cancelled_units", [])
	row["plan_failed"] = ex.get("plan_failed", ex.get("failed", []))
	return row


## Per-unit decision diagnostic: legal rows, selection, scored list.
func _decision_diag(sim: RefCounted, obs: Dictionary, decided: Dictionary) -> Array:
	var out: Array = []
	for tr_val in (decided.get("traces", []) as Array):
		var tr: Dictionary = tr_val
		for u_val in (tr.get("units", []) as Array):
			var u: Dictionary = u_val
			var uid := str(u.get("unit_id", "?"))
			var legal: Array = []
			for r_val in OpportunityCls.legal_attacks(sim, [uid], obs):
				legal.append("%s(k=%.2f,l=%.2f)" % [str((r_val as Dictionary).get("target_id", "?")),
					float((r_val as Dictionary).get("kill_fraction", 0.0)),
					float((r_val as Dictionary).get("loss_fraction", 0.0))])
			var scores: Array = []
			for s_val in (u.get("target_scores", []) as Array):
				scores.append("%s:%.1f" % [str((s_val as Dictionary).get("target_id", "?")),
					float((s_val as Dictionary).get("score", 0.0))])
			out.append({"unit_id": uid, "mission_id": str(u.get("mission_id", "?")),
				"selected": str(u.get("selected_id", "?")), "kind": _sel_kind(u),
				"resolved_target": str(u.get("resolved_target", "")),
				"dpol": str(u.get("designation_policy", "NONE")),
				"m_tgt": str(u.get("mission_target_id", "")),
				"match": u.get("target_match", null),
				"legal_rows": legal, "target_scores": scores})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a.get("unit_id", "")) < str(b.get("unit_id", "")))
	return out


func _sel_kind(t: Dictionary) -> String:
	for o_val in (t.get("options", []) as Array):
		if int((o_val as Dictionary).get("slot", -2)) == int(t.get("selected_slot", -1)):
			return str((o_val as Dictionary).get("kind", ""))
	return ""


func _trace_of(decided: Dictionary, mid: String) -> Dictionary:
	for tr_val in (decided.get("traces", []) as Array):
		if str((tr_val as Dictionary).get("mission_id", "")) == mid:
			return tr_val
	return {}


## Matrix case specs. T=B_INF_1 unless noted. soldiers patch T's HP.
func _matrix_specs() -> Array:
	return [
		{"id": "A_HARD_SURVIVES", "t_hp": 450, "policy": "ATTACK_DESIGNATED_ONLY",
			"task": "FIX", "success": [], "patch_extra": [], "missions_extra": [],
			"watch": ["B_INF_1"]},
		{"id": "B_HARD_DIES_EARLY", "t_hp": 1, "policy": "ATTACK_DESIGNATED_ONLY",
			"task": "FIX", "success": [], "patch_extra": [], "missions_extra": [],
			"watch": ["B_INF_1"]},
		{"id": "C_HARD_DIES_MID", "t_hp": 2, "policy": "ATTACK_DESIGNATED_ONLY",
			"task": "FIX", "success": [], "patch_extra": [], "missions_extra": [],
			"watch": ["B_INF_1"]},
		{"id": "D_SOFT_DIES_EARLY", "t_hp": 1, "policy": "ATTACK_IF_ADVANTAGEOUS",
			"task": "FIX", "success": [], "patch_extra": [], "missions_extra": [],
			"watch": ["B_INF_1", "B_INF_2", "B_SPE_1"]},
		{"id": "E_MISSION_COMPLETE", "t_hp": 1, "policy": "ATTACK_DESIGNATED_ONLY",
			"task": "FIX", "success": [{"trigger": "TARGET_DESTROYED", "params": {"unit_id": "B_INF_1"}}],
			"patch_extra": [], "missions_extra": [], "watch": ["B_INF_1"],
			"second_turn": true},
		{"id": "G_DIFFERENT_TARGETS", "t_hp": 1, "policy": "ATTACK_DESIGNATED_ONLY",
			"task": "FIX", "success": [],
			"patch_extra": [{"id": "B_INF_2", "q": -26, "r": 1, "soldiers": 450}, {"id": "R_INF_2", "q": -25, "r": 1}],
			"missions_extra": [],
			"watch": ["B_INF_1", "B_INF_2"],
			"m01_units": ["R_INF_1", "R_CAV_1"], "m01_target": "B_INF_1",
			"m02": {"mid": "M02", "task": "FIX", "units": ["R_INF_2"], "target": "B_INF_2",
				"policy": "ATTACK_DESIGNATED_ONLY"}},
	]


func _run_matrix_case(spec: Dictionary) -> Dictionary:
	var case_id := str(spec.get("id", "?"))
	var patch := _base_patch()
	patch.append({"id": "B_INF_1", "soldiers": int(spec.get("t_hp", 450))})
	for p_val in (spec.get("patch_extra", []) as Array):
		patch.append(p_val)
	var l := _load_matrix(patch)
	if not bool(l.get("ok", false)):
		return {"case": case_id, "ok": false, "detail": "load failed"}
	var sim: RefCounted = l["sim"]
	var mgr := ManagerCls.new()
	var obs0: Dictionary = _obs_of(sim)
	var m01_units: Array = (spec.get("m01_units", ["R_INF_1", "R_INF_2", "R_CAV_1"]) as Array).duplicate(true)
	var m01_target := str(spec.get("m01_target", "B_INF_1"))
	var missions := [
		_mission_dict("M01", str(spec.get("task", "FIX")), "CENTER", m01_units,
			{"kind": "ENEMY_FORMATION", "unit_id": m01_target}, str(spec.get("policy", "ATTACK_DESIGNATED_ONLY")),
			(spec.get("success", []) as Array).duplicate(true)),
	]
	if (spec.get("m02", {}) as Dictionary).is_empty():
		missions.append(_mission_dict("M03", "HOLD", "ANY", _rest_units(), {"kind": "ZONE", "zone": "HQ"}, "HOLD_FIRE"))
	else:
		var m2: Dictionary = spec.get("m02", {})
		missions.append(_mission_dict(str(m2.get("mid", "M02")), str(m2.get("task", "FIX")), "CENTER",
			(m2.get("units", []) as Array).duplicate(true),
			{"kind": "ENEMY_FORMATION", "unit_id": str(m2.get("target", ""))}, str(m2.get("policy", "ATTACK_DESIGNATED_ONLY"))))
		var rest3 := ["R_SPE_1", "R_ARC_1", "R_SCT_1", "R_HQ_1"]
		missions.append(_mission_dict("M03", "HOLD", "ANY", rest3, {"kind": "ZONE", "zone": "HQ"}, "HOLD_FIRE"))
	var plan: Dictionary = _plan_dict(missions, obs0)
	var applied: Dictionary = mgr.apply_plan(plan, 1, str(obs0.get("snapshot_id", "")), str(obs0.get("battle_id", "")))
	if not bool(applied.get("ok", false)):
		return {"case": case_id, "ok": false, "detail": "apply failed"}
	var obs: Dictionary = _obs_of(sim)
	var decided: Dictionary = mgr.red_turn(sim, obs)
	var out := {"case": case_id, "ok": true, "t_hp_start": int(spec.get("t_hp", 450)),
		"policy": str(spec.get("policy", "")), "task": str(spec.get("task", "")),
		"decisions": _decision_diag(sim, obs, decided), "orders": [],
		"statuses_t1": decided.get("statuses", []), "review_t1": decided.get("review", {})}
	var watch: Array = (spec.get("watch", []) as Array).duplicate(true)
	var exec_index := 0
	var acted: Array = []
	for o_val in (decided.get("orders", []) as Array):
		var o: Dictionary = o_val
		var orow := {"order_index": (out["orders"] as Array).size(),
			"truth_before": _alive_map(sim, watch)}
		for wid in watch:
			(orow["truth_before"] as Dictionary)[str(wid) + "_soldiers"] = _soldiers_of(sim, str(wid))
		var ex := _execute_order(sim, o)
		orow.merge(ex)
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
		orow["truth_after"] = _alive_map(sim, watch)
		for wid2 in watch:
			(orow["truth_after"] as Dictionary)[str(wid2) + "_soldiers"] = _soldiers_of(sim, str(wid2))
		(out["orders"] as Array).append(orow)
	mgr.post_turn(acted, 1)
	out["truth_final"] = _truth_rows(sim)
	out["fingerprint"] = str(sim.fingerprint())
	if bool(spec.get("second_turn", false)):
		sim.sim_end_turn()
		var obs2: Dictionary = _obs_of(sim)
		var decided2: Dictionary = mgr.red_turn(sim, obs2)
		out["statuses_t2"] = decided2.get("statuses", [])
		out["review_t2"] = decided2.get("review", {})
	return out


## Case F: target invalid BEFORE the batch. Direct forced orders (the mission
## path would never emit these); invalid-before-batch must stay explicit.
## F1: T out of range / no legal row at all. F2: T already dead before the
## batch, decision-time obs built AFTER death (T absent).
func _run_case_f() -> Dictionary:
	var out := {"case": "F_INVALID_BEFORE_BATCH", "ok": true, "sub": []}
	var l := _load("COOP_BASELINE")
	if not bool(l.get("ok", false)):
		return {"case": "F_INVALID_BEFORE_BATCH", "ok": false}
	var sim: RefCounted = l["sim"]
	# F1: R_INF_1 attacks B_INF_1 from base geometry (out of range).
	var o1 := {"mission_id": "M01", "order": TableCls.make_command("ATTACK",
		TableCls.scope_units(["R_INF_1"]), TableCls.target_formation("B_INF_1"))}
	if _use_ctx:
		o1["exec_ctx"] = {"mission_id": "M01", "task": "FIX", "mission_target_id": "B_INF_1",
			"designation_policy": "HARD", "decision_alive": [], "unit_targets": {}, "objective_complete_on": []}
	var r1 := _execute_order(sim, o1)
	r1["sub"] = "F1_OUT_OF_RANGE"
	r1["t_soldiers"] = _soldiers_of(sim, "B_INF_1")
	(out["sub"] as Array).append(r1)
	# F2: pre-kill T with a direct order (no ctx), then attack the corpse
	# with a ctx whose decision obs postdates the death.
	var l2 := _load_matrix(_base_patch())
	if not bool(l2.get("ok", false)):
		return {"case": "F_INVALID_BEFORE_BATCH", "ok": false}
	var sim2: RefCounted = l2["sim"]
	_weaken(sim2, "B_INF_1", 1)
	var pre := TableCls.make_command("ATTACK", TableCls.scope_units(["R_INF_1"]), TableCls.target_formation("B_INF_1"))
	var pre_ex: Dictionary = CompilerCls.execute(sim2, pre, "", "red")
	var obs_after: Dictionary = _obs_of(sim2)
	var alive_after: Array = []
	for e_val in (obs_after.get("known_enemy_units", []) as Array):
		if e_val is Dictionary and str((e_val as Dictionary).get("contact_state", "")) == "current_visible":
			alive_after.append(str((e_val as Dictionary).get("unit_id", "")))
	var o2 := {"mission_id": "M01", "order": TableCls.make_command("ATTACK",
		TableCls.scope_units(["R_INF_2"]), TableCls.target_formation("B_INF_1"))}
	if _use_ctx:
		o2["exec_ctx"] = {"mission_id": "M01", "task": "FIX", "mission_target_id": "B_INF_1",
			"designation_policy": "HARD", "decision_alive": alive_after,
			"unit_targets": {"R_INF_2": ["B_INF_1"]}, "objective_complete_on": []}
	var r2 := _execute_order(sim2, o2)
	r2["sub"] = "F2_DEAD_BEFORE_BATCH"
	r2["pre_kill_status"] = str(pre_ex.get("execution_status", "?"))
	r2["t_in_decision_alive"] = alive_after.has("B_INF_1")
	r2["t_soldiers"] = _soldiers_of(sim2, "B_INF_1")
	(out["sub"] as Array).append(r2)
	out["fingerprint"] = str(sim.fingerprint()) + "|" + str(sim2.fingerprint())
	return out


## Waste mode: mission-path kill turn (case-B geometry) on the production
## group-order path, plus a split-replay attribution instrument proving
## per-sibling alive_before/after around the kill.
func _mode_waste() -> Dictionary:
	var out := {"ok": true, "ctx": "on" if _use_ctx else "off"}
	var spec := {"id": "B_HARD_DIES_EARLY", "t_hp": 1, "policy": "ATTACK_DESIGNATED_ONLY",
		"task": "FIX", "success": [], "patch_extra": [], "watch": ["B_INF_1"]}
	out["group_path"] = _run_matrix_case(spec)
	out["split_replay"] = _split_replay(spec)
	return out


func _split_replay(spec: Dictionary) -> Dictionary:
	var patch := _base_patch()
	patch.append({"id": "B_INF_1", "soldiers": int(spec.get("t_hp", 30))})
	var l := _load_matrix(patch)
	if not bool(l.get("ok", false)):
		return {"ok": false}
	var sim: RefCounted = l["sim"]
	var rows: Array = []
	var idx := 0
	for uid in ["R_INF_1", "R_INF_2", "R_CAV_1"]:
		var before := _soldiers_of(sim, "B_INF_1")
		var cmd := TableCls.make_command("ATTACK", TableCls.scope_units([uid]), TableCls.target_formation("B_INF_1"))
		var ex: Dictionary = CompilerCls.execute(sim, cmd, "", "red")
		var after := _soldiers_of(sim, "B_INF_1")
		var status := str(ex.get("execution_status", "?"))
		var code := ""
		for f_val in (ex.get("execution_failed", []) as Array):
			code = str((f_val as Dictionary).get("code", ""))
		rows.append({"execution_index": idx, "unit_id": uid,
			"target_alive_before": before > 0, "t_soldiers_before": before,
			"exec_status": status, "fail_code": code,
			"target_alive_after": after > 0, "t_soldiers_after": after})
		idx += 1
	return {"ok": true, "siblings": rows, "fingerprint": str(sim.fingerprint())}


func _coop_plan() -> Array:
	return [
		_mission_dict("M01", "FIX", "CENTER", ["R_ARC_1", "R_INF_1", "R_INF_2", "R_SPE_1"],
			{"kind": "ENEMY_FORMATION", "unit_id": "B_INF_1"}, "ATTACK_DESIGNATED_ONLY",
			[{"trigger": "TARGET_DESTROYED", "params": {"unit_id": "B_INF_1"}}]),
		_mission_dict("M02", "FLANK", "CENTER", ["R_CAV_1", "R_SCT_1"],
			{"kind": "ENEMY_FORMATION", "unit_id": "B_INF_1"}, "PURSUE_WEAKENED",
			[{"trigger": "TARGET_DESTROYED", "params": {"unit_id": "B_INF_1"}}]),
		_mission_dict("M03", "HOLD", "ANY", ["R_HQ_1"],
			{"kind": "ZONE", "zone": "HQ"}, "HOLD_FIRE"),
	]


func _run_coop_battle() -> Dictionary:
	var l := _load("COOP_BASELINE")
	if not bool(l.get("ok", false)):
		return {"ok": false, "detail": "load failed"}
	var sim: RefCounted = l["sim"]
	var mgr := ManagerCls.new()
	var obs0: Dictionary = _obs_of(sim)
	var applied: Dictionary = mgr.apply_plan(_plan_dict(_coop_plan(), obs0), 1,
		str(obs0.get("snapshot_id", "")), str(obs0.get("battle_id", "")))
	if not bool(applied.get("ok", false)):
		return {"ok": false, "detail": "apply failed"}
	var turns: Array = []
	var exec_index := 0
	for t in range(1, 7):
		var obs: Dictionary = _obs_of(sim)
		if not bool(obs.get("ok", false)):
			break
		var turn := int(obs.get("turn", t))
		var decided: Dictionary = mgr.red_turn(sim, obs)
		var trow := {"turn": turn, "snapshot_id": str(obs.get("snapshot_id", "")),
			"orders": [], "executed_units": 0, "failed_units": 0, "cancelled_units": 0,
			"retargeted_units": 0, "gate_rejected": 0, "stale_codes": {},
			"b_inf_1_soldiers": _soldiers_of(sim, "B_INF_1")}
		var acted: Array = []
		for o_val in (decided.get("orders", []) as Array):
			var ex := _execute_order(sim, o_val)
			for e_val in (ex.get("executed", []) as Array):
				(e_val as Dictionary)["execution_index"] = exec_index
				exec_index += 1
				acted.append({"unit_id": str((e_val as Dictionary).get("unit_id", ""))})
				trow["executed_units"] = int(trow["executed_units"]) + 1
				if (e_val as Dictionary).has("original_target_id"):
					trow["retargeted_units"] = int(trow["retargeted_units"]) + 1
			for f_val in (ex.get("failed", []) as Array):
				(f_val as Dictionary)["execution_index"] = exec_index
				exec_index += 1
				trow["failed_units"] = int(trow["failed_units"]) + 1
				var code := str((f_val as Dictionary).get("code", "?"))
				(trow["stale_codes"] as Dictionary)[code] = int((trow["stale_codes"] as Dictionary).get(code, 0)) + 1
			for c_val in (ex.get("cancelled", []) as Array):
				(c_val as Dictionary)["execution_index"] = exec_index
				exec_index += 1
				trow["cancelled_units"] = int(trow["cancelled_units"]) + 1
			if str(ex.get("exec_status", "")) == "GATE_REJECTED":
				trow["gate_rejected"] = int(trow["gate_rejected"]) + 1
			(trow["orders"] as Array).append(ex)
		mgr.post_turn(acted, turn)
		trow["mission_statuses"] = mgr.get_plan().get("missions", [])
		trow["fingerprint_post"] = str(sim.fingerprint())
		trow["truth"] = _truth_rows(sim)
		turns.append(trow)
		if _decisive(sim):
			break
		sim.sim_end_turn()
	return {"ok": true, "scenario": "COOP_BASELINE", "turns": turns,
		"final_strength": _side_strength(sim)}


func _mode_matrix() -> Dictionary:
	var out := {"ok": true, "ctx": "on" if _use_ctx else "off", "cases": []}
	for spec in _matrix_specs():
		(out["cases"] as Array).append(_run_matrix_case(spec))
	(out["cases"] as Array).append(_run_case_f())
	return out


func _mode_determinism() -> Dictionary:
	var m1 := _mode_matrix()
	var m2 := _mode_matrix()
	var c1 := _run_coop_battle()
	var c2 := _run_coop_battle()
	return {"ok": true, "ctx": "on" if _use_ctx else "off",
		"matrix_sig_a": _matrix_sig(m1), "matrix_sig_b": _matrix_sig(m2),
		"matrix_match": _matrix_sig(m1) == _matrix_sig(m2),
		"coop_fp_a": _coop_fp(c1), "coop_fp_b": _coop_fp(c2),
		"coop_fp_match": _coop_fp(c1) == _coop_fp(c2),
		"coop_sig_a": _coop_sig(c1), "coop_sig_b": _coop_sig(c2),
		"coop_sig_match": _coop_sig(c1) == _coop_sig(c2)}


func _matrix_sig(m: Dictionary) -> Array:
	var sigs: Array = []
	for c_val in (m.get("cases", []) as Array):
		var c: Dictionary = c_val
		if c.has("sub"):
			var parts: Array = []
			for s_val in (c.get("sub", []) as Array):
				parts.append("%s:%s:%s" % [str((s_val as Dictionary).get("sub", "?")),
					str((s_val as Dictionary).get("exec_status", "?")),
					JSON.stringify((s_val as Dictionary).get("failed", []))])
			sigs.append("%s|%s" % [str(c.get("case", "?")), "|".join(parts)])
			continue
		var bits: Array = []
		for o_val in (c.get("orders", []) as Array):
			var o: Dictionary = o_val
			for e_val in (o.get("executed", []) as Array):
				var e: Dictionary = e_val
				bits.append("%s:%s:%s>%s" % [str(e.get("unit_id", "")), str(e.get("action", "")),
					str(e.get("original_target_id", e.get("target_unit_id", ""))), str(e.get("target_unit_id", ""))])
			for f_val in (o.get("failed", []) as Array):
				bits.append("FAIL:%s:%s" % [str((f_val as Dictionary).get("unit_id", "")), str((f_val as Dictionary).get("code", ""))])
			for x_val in (o.get("cancelled", []) as Array):
				bits.append("CANCEL:%s:%s" % [str((x_val as Dictionary).get("unit_id", "")), str((x_val as Dictionary).get("cancel_reason", "?"))])
		bits.sort()
		sigs.append("%s|%s|%s" % [str(c.get("case", "?")), str(c.get("fingerprint", "")), "|".join(bits)])
	return sigs


func _coop_fp(c: Dictionary) -> Array:
	var out: Array = []
	for t_val in (c.get("turns", []) as Array):
		out.append(str((t_val as Dictionary).get("fingerprint_post", "")))
	return out


func _coop_sig(c: Dictionary) -> Array:
	var out: Array = []
	for t_val in (c.get("turns", []) as Array):
		var bits: Array = []
		for o_val in ((t_val as Dictionary).get("orders", []) as Array):
			var o: Dictionary = o_val
			for e_val in (o.get("executed", []) as Array):
				var e: Dictionary = e_val
				bits.append("%s:%s:%s>%s" % [str(e.get("unit_id", "")), str(e.get("action", "")),
					str(e.get("original_target_id", e.get("target_unit_id", ""))), str(e.get("target_unit_id", ""))])
			for f_val in (o.get("failed", []) as Array):
				bits.append("FAIL:%s:%s" % [str((f_val as Dictionary).get("unit_id", "")), str((f_val as Dictionary).get("code", ""))])
			for x_val in (o.get("cancelled", []) as Array):
				bits.append("CANCEL:%s:%s" % [str((x_val as Dictionary).get("unit_id", "")), str((x_val as Dictionary).get("cancel_reason", "?"))])
		bits.sort()
		out.append("|".join(bits))
	return out


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
