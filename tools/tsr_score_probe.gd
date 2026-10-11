extends SceneTree

## TACTICAL-SCORING repair gate probe (SYSTEM_DEBUG visibility; sim access ONLY
## through the normal stack: manager.red_turn -> response gate -> compiler).
##
## Modes:
##   scores      — deterministic score matrix for the FIX/FLANK/HOLD cases.
##   micro_fix   — FIX PRESSURE micro battle (turns adjacent, attacks, holds, damage).
##   micro_flank — FLANK EXPLOIT micro battle (moves, geometry turn, strike turn).
##   determinism — repeat-run fingerprint + executed-signature comparison.
##   blast       — selection blast radius: menu-baseline replay BEFORE vs AFTER code.
##
## Usage:
##   Godot_console --headless --path StrategyGame -s res://tools/tsr_score_probe.gd -- \
##     --mode=scores|micro_fix|micro_flank|determinism|blast --tag=before|after \
##     --out-dir="<abs dir>" [--cases=cs1,cs2,...]

const SimControllerCls = preload("res://scripts/sim/sim_controller.gd")
const ObsCls = preload("res://scripts/cloud1/cloud1_observation.gd")
const TableCls = preload("res://scripts/cloud1/cloud1_action_table.gd")
const CompilerCls = preload("res://scripts/cloud1/cloud1_compiler.gd")
const ScenariosCls = preload("res://scripts/cloud2/cloud2_debug_scenarios.gd")
const MissionCls = preload("res://scripts/cloud2/cloud2_mission.gd")
const PlanCls = preload("res://scripts/cloud2/cloud2_general_plan.gd")
const ManagerCls = preload("res://scripts/cloud2/cloud2_mission_manager.gd")
const ControllerCls = preload("res://scripts/cloud2/cloud2_mission_controller.gd")
const OpportunityCls = preload("res://scripts/cloud2/cloud2_opportunity.gd")
const ResponseCls = preload("res://scripts/cloud2/cloud2_response.gd")
const SolverCls = preload("res://scripts/cloud2/cloud2_class_option_solver.gd")
const HexUtilsCls = preload("res://scripts/core/hex_utils.gd")

## Flank geometry thresholds (recorded in outputs for reproducibility).
const FLANK_BEARING_THRESHOLD := 0.55
const FLANK_FRONTAL_BEARING := 0.15

var _out_dir := ""
var _mode := "scores"
var _tag := "before"
var _cases := ""

## FIX-APPROACH gate cases (fix_approach_scoring_v0).
const APPROACH_CASES := ["FIX_NEAR_HEALTHY", "FIX_FAR_HEALTHY", "FIX_NEAR_WEAK",
	"HOLD_MISSION_CONTROL", "FIX_TARGET_INVALID", "FIX_ALREADY_CONTACT"]

func _init() -> void:
	_parse_args()
	if _out_dir.is_empty():
		print("[TSR] FATAL: need --out-dir=<abs dir>")
		quit(4)
		return
	var res := {}
	match _mode:
		"scores":
			res = _mode_scores()
		"approach":
			res = _mode_scores(APPROACH_CASES)
		"micro_fix":
			res = _mode_micro_fix()
		"micro_flank":
			res = _mode_micro_flank()
		"micro_approach":
			res = _mode_micro_approach()
		"determinism":
			res = _mode_determinism()
		"blast":
			res = _mode_blast()
		_:
			print("[TSR] FATAL: unknown mode %s" % _mode)
			quit(4)
			return
	_write("%s_%s.json" % [_tag, _mode], res)
	print("[TSR] mode=%s tag=%s ok=%s" % [_mode, _tag, str(bool(res.get("ok", true)))])
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
		elif a.begins_with("--cases="):
			_cases = a.get_slice("=", 1).strip_edges()

func _write(name: String, data: Dictionary) -> void:
	var path := _out_dir.rstrip("/") + "/" + name
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		print("[TSR] FATAL: cannot write %s" % path)
		return
	f.store_string(JSON.stringify(data, "  "))
	f.close()
	print("[TSR] wrote %s" % path)

# ---------------- scenario loaders (probe-only geometry, normal stack) --------

func _load(scenario_id: String) -> Dictionary:
	var built: Dictionary = ScenariosCls.build(scenario_id)
	if not bool(built.get("ok", false)):
		return {"ok": false}
	var sim: RefCounted = SimControllerCls.new()
	if not bool((sim.load_scenario(built.get("scenario", {})) as Dictionary).get("ok", false)):
		return {"ok": false}
	return {"ok": true, "sim": sim}

## Custom geometry loader: identical base forces, probe-only moves/weakenings.
## variants: [[unit_id, q, r], ...] and [[unit_id, soldiers], ...]
func _load_custom(moves: Array, weakens: Array) -> Dictionary:
	var built: Dictionary = ScenariosCls.build("HQ_SAFE")
	if not bool(built.get("ok", false)):
		return {"ok": false}
	var scn: Dictionary = (built.get("scenario", {}) as Dictionary).duplicate(true)
	var forces: Array = (scn.get("forces", []) as Array).duplicate(true)
	for mv_val in moves:
		var mv: Array = mv_val
		for f_val in forces:
			if f_val is Dictionary and str((f_val as Dictionary).get("id", "")) == str(mv[0]):
				(f_val as Dictionary)["q"] = int(mv[1])
				(f_val as Dictionary)["r"] = int(mv[2])
	for wk_val in weakens:
		var wk: Array = wk_val
		for f2_val in forces:
			if f2_val is Dictionary and str((f2_val as Dictionary).get("id", "")) == str(wk[0]):
				(f2_val as Dictionary)["soldiers"] = int(wk[1])
	scn["forces"] = forces
	var sim: RefCounted = SimControllerCls.new()
	if not bool((sim.load_scenario(scn) as Dictionary).get("ok", false)):
		return {"ok": false}
	return {"ok": true, "sim": sim}

func _obs_of(sim: RefCounted) -> Dictionary:
	return ObsCls.build(sim, "red")

func _doctrine() -> Dictionary:
	return {"aggression": 0.5, "tempo": 0.5, "risk_tolerance": 0.5,
		"reserve_discipline": 0.6, "pursuit": 0.5}

func _mission_dict(mid: String, task: String, area: String, units: Array, objective: Dictionary, policy: String, preserve := false) -> Dictionary:
	var m := MissionCls.default_mission(mid, task)
	m["area"] = area
	m["assigned_units"] = units.duplicate(true)
	m["objective"] = objective.duplicate(true)
	m["engagement"] = {"policy": policy}
	m["success_conditions"] = []
	m["abort_conditions"] = []
	m["report_conditions"] = []
	if preserve:
		m["constraints"] = {"preserve_force": true, "max_overextension": 9}
	return m

func _plan_dict(missions: Array, obs: Dictionary) -> Dictionary:
	return {
		"plan_version": 1, "based_on_snapshot": str(obs.get("snapshot_id", "")),
		"created_turn": int(obs.get("turn", 1)), "last_review_turn": int(obs.get("turn", 1)),
		"mission": (obs.get("mission", {}) as Dictionary).duplicate(true),
		"concept": {"objective": "probe", "intent": "probe", "main_effort": "CENTER", "risk_posture": "BALANCED"},
		"doctrine": _doctrine(),
		"missions": missions, "contingencies": [], "opponent_hypotheses": [],
		"review_conditions": [{"trigger": "MISSION_BLOCKED", "params": {}}],
		"review_horizon_turns": 4, "source": "probe_forced",
	}

func _decide(sim: RefCounted, obs: Dictionary, missions: Array) -> Dictionary:
	var plan: Dictionary = _plan_dict(missions, obs)
	var bounds: Dictionary = sim.map_bounds() if sim.has_method("map_bounds") else {}
	var out := {"missions": []}
	for m_val in missions:
		var m: Dictionary = (m_val as Dictionary).duplicate(true)
		m["status"] = "ACTIVE"
		var ctrl := ControllerCls.new()
		ctrl.setup(m, _doctrine(), 11)
		var dctx := {"turn": int(obs.get("turn", 1)), "snapshot_id": str(obs.get("snapshot_id", "")),
			"turns_active": 0, "urgency": 0.0, "bounds": bounds, "main_effort": "CENTER"}
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
					"base": snappedf(float(o.get("base_score", 0.0)), 0.01),
					"mission": snappedf(float(o.get("mission_score", 0.0)), 0.01),
					"state": snappedf(float(o.get("state_score", 0.0)), 0.01),
					"doctrine": snappedf(float(o.get("doctrine_score", 0.0)), 0.01),
					"risk": snappedf(float(o.get("risk_score", 0.0)), 0.01),
					"tgt": str(o.get("resolved_target", "")), "dest": o.get("resolved_destination", []),
					"m_tgt": str(o.get("mission_target_id", "")), "dpol": str(o.get("designation_policy", "NONE")),
					"match": o.get("target_match", null), "reason": str(o.get("target_substitution_reason", "")),
					"dry": str(o.get("dry_code", ""))})
			units.append({"unit_id": str(t.get("unit_id", "?")), "class": str(t.get("unit_class", "?")),
				"selected": str(t.get("selected_id", "?")), "kind": _sel_kind(t),
				"flavor": str(t.get("mission_flavor", "")),
				"geometry": t.get("flank_geometry", {}),
				"resolved_target": str(t.get("resolved_target", "")),
				"resolved_destination": t.get("resolved_destination", []),
				"command": t.get("resolved_command", {}), "target_scores": t.get("target_scores", []),
				"m_tgt": str(t.get("mission_target_id", "")), "dpol": str(t.get("designation_policy", "NONE")),
				"match": t.get("target_match", null), "reason": str(t.get("target_substitution_reason", "")),
				"slots": slots})
		out["missions"].append({"mission_id": str(m.get("mission_id", "?")), "task": str(m.get("task", "?")),
			"area": str(m.get("area", "?")), "units": m.get("assigned_units", []),
			"objective": m.get("objective", {}), "engagement": m.get("engagement", {}),
			"status_hint": str(res.get("status_hint", "?")), "reason": str(res.get("reason", "")),
			"unit_tables": units})
	return out

func _sel_kind(t: Dictionary) -> String:
	for o_val in (t.get("options", []) as Array):
		if int((o_val as Dictionary).get("slot", -2)) == int(t.get("selected_slot", -1)):
			return str((o_val as Dictionary).get("kind", ""))
	return ""

# ---------------- geometry metrics (recorded in outputs) ----------------------

func _flank_geo(obs: Dictionary, uid: String, tid: String) -> Dictionary:
	var geo: Dictionary = SolverCls.flank_geometry(obs, _obs_unit(obs, uid), tid)
	geo["actor"] = uid
	geo["target"] = tid
	return geo

func _unit_pos(obs: Dictionary, uid: String) -> Vector2i:
	for u_val in (obs.get("friendly_units", []) as Array):
		if u_val is Dictionary and str((u_val as Dictionary).get("unit_id", "")) == uid:
			return Vector2i(int((u_val as Dictionary).get("q", 0)), int((u_val as Dictionary).get("r", 0)))
	for e_val in (obs.get("known_enemy_units", []) as Array):
		if e_val is Dictionary and str((e_val as Dictionary).get("unit_id", "")) == uid:
			return Vector2i(int((e_val as Dictionary).get("q", 0)), int((e_val as Dictionary).get("r", 0)))
	return Vector2i(-999, -999)

func _truth(sim: RefCounted) -> Dictionary:
	var out := {}
	for u_val in sim.get_manager().get_all_units_including_garrisoned():
		var u: Dictionary = u_val
		out[str(u.get("id", ""))] = {"q": int(u.get("q", 0)), "r": int(u.get("r", 0)),
			"soldiers": int(u.get("soldier_count", 0))}
	return out

# ---------------- MODE: scores -------------------------------------------------

## Score matrix cases. Names align with the gate contracts (FIX_A..D, FLANK
## cases from tactical_scoring_repair_v0; APPROACH_CASES from
## fix_approach_scoring_v0).
func _mode_scores(case_list: Array = ["FIX_A", "FIX_B", "FIX_C", "FIX_D", "FLANK_6", "FLANK_7", "FLANK_8", "FLANK_9", "FLANK_10"]) -> Dictionary:
	var want := {}
	if not _cases.is_empty():
		for c in _cases.split(","):
			want[str(c).strip_edges()] = true
	var cases := {}
	for case_name in case_list:
		if want.is_empty() or want.has(case_name):
			var row: Dictionary = _score_case(case_name)
			if not row.is_empty():
				cases[case_name] = row
	var all_ok := true
	for k in cases.keys():
		if not bool((cases[k] as Dictionary).get("loaded", false)):
			all_ok = false
	return {"ok": all_ok, "bearing_threshold": FLANK_BEARING_THRESHOLD, "cases": cases}

func _score_case(case_name: String) -> Dictionary:
	var missions: Array = []
	var sim: RefCounted = null
	match case_name:
		"FIX_A": # healthy FIX, adjacent (dist 1) designated T, hard designation
			var l := _load_custom([["B_INF_1", -22, -1], ["R_INF_1", -21, -1]], [])
			if not bool(l.get("ok", false)): return {}
			sim = l["sim"]
			missions = [_mission_dict("M01", "FIX", "CENTER", ["R_INF_1"], {"kind": "ENEMY_FORMATION", "unit_id": "B_INF_1"}, "ATTACK_DESIGNATED_ONLY")]
		"FIX_B": # weak (badly depleted) FIX, adjacent designated T, preserve_force
			var l2 := _load_custom([["B_INF_1", -22, -1], ["R_INF_1", -21, -1]], [["R_INF_1", 60]])
			if not bool(l2.get("ok", false)): return {}
			sim = l2["sim"]
			missions = [_mission_dict("M01", "FIX", "CENTER", ["R_INF_1"], {"kind": "ENEMY_FORMATION", "unit_id": "B_INF_1"}, "ATTACK_DESIGNATED_ONLY", true)]
		"FIX_C": # FIX: T visible at dist 2, melee cannot attack (no legal row)
			var l3 := _load_custom([["B_INF_1", -22, -1]], [])
			if not bool(l3.get("ok", false)): return {}
			sim = l3["sim"]
			missions = [_mission_dict("M01", "FIX", "CENTER", ["R_INF_1"], {"kind": "ENEMY_FORMATION", "unit_id": "B_INF_1"}, "ATTACK_DESIGNATED_ONLY")]
		"FIX_D": # explicit HOLD mission, adjacent enemy (mission semantic control)
			var l4 := _load_custom([["B_INF_1", -22, -1], ["R_INF_1", -21, -1]], [])
			if not bool(l4.get("ok", false)): return {}
			sim = l4["sim"]
			missions = [_mission_dict("M01", "HOLD", "CENTER", ["R_INF_1"], {"kind": "REGION", "region": "CENTER"}, "ATTACK_IF_ADVANTAGEOUS")]
		"FLANK_6": # FLANK far from designated T (visible via scout at dist 4)
			var l6 := _load_custom([["B_INF_1", -24, -1], ["R_SCT_1", -22, 1]], [])
			if not bool(l6.get("ok", false)): return {}
			sim = l6["sim"]
			missions = [_mission_dict("M01", "FLANK", "CENTER", ["R_CAV_1"], {"kind": "ENEMY_FORMATION", "unit_id": "B_INF_1"}, "ATTACK_DESIGNATED_ONLY")]
		"FLANK_7": # FLANK halfway, frontal geometry, no legal attack (dist 2)
			var l7 := _load_custom([["B_INF_1", -24, -1], ["R_SCT_1", -22, 1], ["R_CAV_1", -22, -3]], [])
			if not bool(l7.get("ok", false)): return {}
			sim = l7["sim"]
			missions = [_mission_dict("M01", "FLANK", "CENTER", ["R_CAV_1"], {"kind": "ENEMY_FORMATION", "unit_id": "B_INF_1"}, "ATTACK_DESIGNATED_ONLY")]
		"FLANK_8": # flank position achieved (rear, bearing 1.0), attack legal (dist 1)
			var l8 := _load_custom([["B_INF_1", -24, -1], ["R_SCT_1", -22, 1], ["R_CAV_1", -25, -1]], [])
			if not bool(l8.get("ok", false)): return {}
			sim = l8["sim"]
			missions = [_mission_dict("M01", "FLANK", "CENTER", ["R_CAV_1"], {"kind": "ENEMY_FORMATION", "unit_id": "B_INF_1"}, "ATTACK_DESIGNATED_ONLY")]
		"FLANK_9": # flank achieved + attack legal, target healthy, PURSUE_WEAKENED (residual filter)
			var l9 := _load_custom([["B_INF_1", -24, -1], ["R_SCT_1", -22, 1], ["R_CAV_1", -25, -1]], [])
			if not bool(l9.get("ok", false)): return {}
			sim = l9["sim"]
			missions = [_mission_dict("M01", "FLANK", "CENTER", ["R_CAV_1"], {"kind": "ENEMY_FORMATION", "unit_id": "B_INF_1"}, "PURSUE_WEAKENED")]
		"FLANK_10": # designated target invalidated (B_SPE_1 never visible; tempting B_INF_1 adjacent)
			var l10 := _load_custom([["B_INF_1", -22, -1], ["R_CAV_1", -21, -1]], [])
			if not bool(l10.get("ok", false)): return {}
			sim = l10["sim"]
			missions = [_mission_dict("M01", "FLANK", "CENTER", ["R_CAV_1"], {"kind": "ENEMY_FORMATION", "unit_id": "B_SPE_1"}, "ATTACK_DESIGNATED_ONLY")]
		"FIX_NEAR_HEALTHY": # FIX, healthy actor, T visible dist 2, no legal attack yet
			var la1 := _load_custom([["B_INF_1", -23, -1], ["R_SCT_1", -21, 1], ["R_INF_1", -21, -1]], [])
			if not bool(la1.get("ok", false)): return {}
			sim = la1["sim"]
			missions = [_mission_dict("M01", "FIX", "CENTER", ["R_INF_1"], {"kind": "ENEMY_FORMATION", "unit_id": "B_INF_1"}, "ATTACK_DESIGNATED_ONLY")]
		"FIX_FAR_HEALTHY": # FIX, healthy actor, T visible dist 4 (approach must not be distance-brittle)
			var la2 := _load_custom([["B_INF_1", -25, -1], ["R_SCT_1", -22, 0], ["R_INF_1", -21, -1]], [])
			if not bool(la2.get("ok", false)): return {}
			sim = la2["sim"]
			missions = [_mission_dict("M01", "FIX", "CENTER", ["R_INF_1"], {"kind": "ENEMY_FORMATION", "unit_id": "B_INF_1"}, "ATTACK_DESIGNATED_ONLY")]
		"FIX_NEAR_WEAK": # FIX, critical-condition actor, T visible dist 2 (preservation control)
			var la3 := _load_custom([["B_INF_1", -23, -1], ["R_SCT_1", -21, 1], ["R_INF_1", -21, -1]], [["R_INF_1", 60]])
			if not bool(la3.get("ok", false)): return {}
			sim = la3["sim"]
			missions = [_mission_dict("M01", "FIX", "CENTER", ["R_INF_1"], {"kind": "ENEMY_FORMATION", "unit_id": "B_INF_1"}, "ATTACK_DESIGNATED_ONLY", true)]
		"HOLD_MISSION_CONTROL": # actual HOLD mission, enemy nearby (defensive semantic control)
			var la4 := _load_custom([["B_INF_1", -23, -1], ["R_INF_1", -21, -1]], [])
			if not bool(la4.get("ok", false)): return {}
			sim = la4["sim"]
			missions = [_mission_dict("M01", "HOLD", "CENTER", ["R_INF_1"], {"kind": "REGION", "region": "CENTER"}, "ATTACK_IF_ADVANTAGEOUS")]
		"FIX_TARGET_INVALID": # FIX, designated T unobserved (explicit blocking control)
			var la5 := _load_custom([["B_INF_1", -23, -1], ["R_INF_1", -21, -1]], [])
			if not bool(la5.get("ok", false)): return {}
			sim = la5["sim"]
			missions = [_mission_dict("M01", "FIX", "CENTER", ["R_INF_1"], {"kind": "ENEMY_FORMATION", "unit_id": "B_SPE_1"}, "ATTACK_DESIGNATED_ONLY")]
		"FIX_ALREADY_CONTACT": # FIX, adjacent legal T (previous gate's contact pressure must hold)
			var la6 := _load_custom([["B_INF_1", -22, -1], ["R_INF_1", -21, -1]], [])
			if not bool(la6.get("ok", false)): return {}
			sim = la6["sim"]
			missions = [_mission_dict("M01", "FIX", "CENTER", ["R_INF_1"], {"kind": "ENEMY_FORMATION", "unit_id": "B_INF_1"}, "ATTACK_DESIGNATED_ONLY")]
	var obs: Dictionary = _obs_of(sim)
	var decided: Dictionary = _decide(sim, obs, missions)
	var rows_focus := OpportunityCls.legal_attacks(sim, _focus_units(case_name), obs)
	var designations := []
	for m_val in missions:
		designations.append(SolverCls.designation_state(m_val, obs))
	var geo := {}
	for fu_val in _focus_units(case_name):
		geo[str(fu_val)] = SolverCls.flank_geometry(obs, _obs_unit(obs, str(fu_val)), _designated_id(missions))
	return {"loaded": true, "case": case_name, "designation_states": designations,
		"focus_geometry": geo, "focus_legal_rows": rows_focus,
		"decided": decided}

func _focus_units(case_name: String) -> Array:
	return ["R_CAV_1"] if case_name.begins_with("FLANK") else ["R_INF_1"]

## FIX-APPROACH transition micro: healthy fixing infantry starts OUTSIDE
## attack range (dist 2), designated T visible; the battle must show
## approach -> contact -> pressure as one continuous FIX behavior.
func _mode_micro_approach() -> Dictionary:
	var l := _load_custom([["B_INF_1", -23, -1], ["R_SCT_1", -21, 1], ["R_INF_1", -21, -1]], [])
	if not bool(l.get("ok", false)):
		return {"ok": false}
	var missions := [
		_mission_dict("M01", "FIX", "CENTER", ["R_INF_1"], {"kind": "ENEMY_FORMATION", "unit_id": "B_INF_1"}, "ATTACK_DESIGNATED_ONLY"),
		_mission_dict("M02", "HOLD", "ANY", ["R_HQ_1"], {"kind": "ZONE", "zone": "HQ"}, "HOLD_FIRE"),
	]
	var battle: Dictionary = _run_battle_sim(l["sim"], missions, 6)
	battle["designated_target"] = "B_INF_1"
	battle["start_distance"] = 2
	return battle

func _obs_unit(obs: Dictionary, uid: String) -> Dictionary:
	for u_val in (obs.get("friendly_units", []) as Array):
		if u_val is Dictionary and str((u_val as Dictionary).get("unit_id", "")) == uid:
			return u_val
	return {}

func _designated_id(missions: Array) -> String:
	if missions.is_empty():
		return ""
	var obj: Dictionary = (missions[0] as Dictionary).get("objective", {})
	if str(obj.get("kind", "")) == "ENEMY_FORMATION":
		return str(obj.get("unit_id", ""))
	return ""

# ---------------- micro battles -----------------------------------------------

func _run_battle(scenario_id: String, missions: Array, max_turns: int) -> Dictionary:
	var l := _load(scenario_id)
	if not bool(l.get("ok", false)):
		return {"ok": false, "detail": "load failed"}
	return _run_battle_sim(l["sim"], missions, max_turns)

func _run_battle_sim(sim: RefCounted, missions: Array, max_turns: int) -> Dictionary:
	var mgr := ManagerCls.new()
	var obs0: Dictionary = _obs_of(sim)
	var plan: Dictionary = _plan_dict(missions, obs0)
	var applied: Dictionary = mgr.apply_plan(plan, 1, str(obs0.get("snapshot_id", "")), str(obs0.get("battle_id", "")))
	if not bool(applied.get("ok", false)):
		return {"ok": false, "detail": "apply failed: %s %s" % [str(applied.get("code", "")), str(applied.get("detail", ""))]}
	var turns: Array = []
	var prev_truth: Dictionary = _truth(sim)
	for t in range(1, max_turns + 1):
		var obs: Dictionary = _obs_of(sim)
		if not bool(obs.get("ok", false)):
			break
		var turn := int(obs.get("turn", t))
		var decided: Dictionary = mgr.red_turn(sim, obs)
		var trow := {"turn": turn, "orders": [], "gate_rejected": 0, "exec_invalid": 0, "unit_rows": [], "oob": 0}
		var acted: Array = []
		for o_val in (decided.get("orders", []) as Array):
			var mid := str((o_val as Dictionary).get("mission_id", "?"))
			var order: Dictionary = (o_val as Dictionary).get("order", {})
			var gate: Dictionary = ResponseCls.check_order(order, {"acting_side": "RED"})
			var orow := {"mission_id": mid, "gate_ok": bool(gate.get("ok", false)), "gate_code": str(gate.get("code", "")),
				"exec_status": "GATE_REJECTED", "executed": [], "failed": []}
			if bool(gate.get("ok", false)):
				var ex: Dictionary = CompilerCls.execute(sim, order, "", "red")
				orow["exec_status"] = str(ex.get("execution_status", "?"))
				orow["executed"] = ex.get("executed_units", [])
				orow["failed"] = ex.get("execution_failed", [])
				for e_val in (ex.get("executed_units", []) as Array):
					acted.append({"unit_id": str((e_val as Dictionary).get("unit_id", ""))})
				for f_val in (ex.get("execution_failed", []) as Array):
					if str((f_val as Dictionary).get("code", "")) == "TARGET_UNREACHABLE":
						trow["exec_invalid"] = int(trow["exec_invalid"]) + 1
			else:
				trow["gate_rejected"] = int(trow["gate_rejected"]) + 1
			(trow["orders"] as Array).append(orow)
		mgr.post_turn(acted, turn)
		var truth: Dictionary = _truth(sim)
		for tr_val in (decided.get("traces", []) as Array):
			var tr: Dictionary = tr_val
			for u_val in (tr.get("units", []) as Array):
				var u: Dictionary = u_val
				var uid := str(u.get("unit_id", "?"))
				var opt_rows: Array = []
				for o_val in (u.get("options", []) as Array):
					var o: Dictionary = o_val
					opt_rows.append({"id": str(o.get("option_id", "?")), "kind": str(o.get("kind", "?")),
						"masked": bool(o.get("masked", false)), "mask": str(o.get("mask_reason", "")),
						"final": snappedf(float(o.get("final_score", 0.0)), 0.01),
						"cond": str(o.get("conditioned_reason", "")),
						"dest": o.get("resolved_destination", [])})
				trow["unit_rows"].append({"unit_id": uid, "mission_id": str(u.get("mission_id", "?")),
					"selected": str(u.get("selected_id", "?")), "kind": _sel_kind(u),
					"resolved_target": str(u.get("resolved_target", "")),
					"resolved_destination": u.get("resolved_destination", []),
					"command": u.get("resolved_command", {}),
					"dpol": str(u.get("designation_policy", "NONE")),
					"match": u.get("target_match", null),
					"reason": str(u.get("target_substitution_reason", "")),
					"options": opt_rows,
					"pos_before": [int(prev_truth.get(uid, {"q": -999, "r": -999}).get("q", -999)), int(prev_truth.get(uid, {"q": -999, "r": -999}).get("r", -999))],
					"pos_after": [int(truth.get(uid, {"q": -999, "r": -999}).get("q", -999)), int(truth.get(uid, {"q": -999, "r": -999}).get("r", -999))],
					"geometry": _flank_geo(_obs_of(sim), uid, _designated_id(missions))})
		trow["fingerprint_post"] = str(sim.fingerprint())
		trow["truth"] = truth
		turns.append(trow)
		prev_truth = truth
		if _decisive(sim):
			break
		sim.sim_end_turn()
	return {"ok": true, "turns": turns, "final_strength": _side_strength(sim), "truth_final": _truth(sim)}

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

func _mode_micro_fix() -> Dictionary:
	# FIX PRESSURE micro: healthy FIX on adjacent-ish T with 3-melee line +
	# archer; prove pressure (attacks) instead of adjacent HOLD camping.
	var l := _load_custom([["B_INF_1", -23, -1]], [])
	if not bool(l.get("ok", false)):
		return {"ok": false}
	var missions := [
		_mission_dict("M01", "FIX", "CENTER", ["R_INF_1", "R_INF_2", "R_SPE_1", "R_ARC_1"], {"kind": "ENEMY_FORMATION", "unit_id": "B_INF_1"}, "ATTACK_DESIGNATED_ONLY"),
		_mission_dict("M02", "HOLD", "ANY", ["R_HQ_1"], {"kind": "ZONE", "zone": "HQ"}, "HOLD_FIRE"),
	]
	var battle: Dictionary = _run_battle_sim(l["sim"], missions, 8)
	battle["designated_target"] = "B_INF_1"
	return battle

func _mode_micro_flank() -> Dictionary:
	# FLANK EXPLOIT micro: cavalry far from T, PURSUE_WEAKENED (the exact
	# residual-evidence configuration), approach -> position -> strike.
	var l := _load("COOP_BASELINE")
	if not bool(l.get("ok", false)):
		return {"ok": false}
	var missions := [
		_mission_dict("M01", "FLANK", "CENTER", ["R_CAV_1"], {"kind": "ENEMY_FORMATION", "unit_id": "B_INF_1"}, "PURSUE_WEAKENED"),
		_mission_dict("M02", "HOLD", "ANY", ["R_HQ_1"], {"kind": "ZONE", "zone": "HQ"}, "HOLD_FIRE"),
	]
	var battle: Dictionary = _run_battle_sim(l["sim"], missions, 10)
	battle["designated_target"] = "B_INF_1"
	return battle

# ---------------- determinism --------------------------------------------------

func _mode_determinism() -> Dictionary:
	var a := _run_coop()
	var b := _run_coop()
	var fa: Array = []
	var fb: Array = []
	var sa: Array = []
	var sb: Array = []
	for t_val in (a.get("turns", []) as Array):
		fa.append(str((t_val as Dictionary).get("fingerprint_post", "")))
		sa.append(_exec_sig(t_val))
	for t2_val in (b.get("turns", []) as Array):
		fb.append(str((t2_val as Dictionary).get("fingerprint_post", "")))
		sb.append(_exec_sig(t2_val))
	return {"ok": true, "fingerprints_match": fa == fb, "exec_match": sa == sb,
		"fingerprints_a": fa, "fingerprints_b": fb}

func _run_coop() -> Dictionary:
	var l := _load("COOP_BASELINE")
	if not bool(l.get("ok", false)):
		return {"ok": false}
	var missions := [
		_mission_dict("M01", "FIX", "CENTER", ["R_ARC_1", "R_INF_1", "R_INF_2", "R_SPE_1"], {"kind": "ENEMY_FORMATION", "unit_id": "B_INF_1"}, "ATTACK_DESIGNATED_ONLY"),
		_mission_dict("M02", "FLANK", "CENTER", ["R_CAV_1", "R_SCT_1"], {"kind": "ENEMY_FORMATION", "unit_id": "B_INF_1"}, "PURSUE_WEAKENED"),
		_mission_dict("M03", "HOLD", "ANY", ["R_HQ_1"], {"kind": "ZONE", "zone": "HQ"}, "HOLD_FIRE"),
	]
	return _run_battle_sim(l["sim"], missions, 6)

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

# ---------------- blast radius -------------------------------------------------

func _mode_blast() -> Dictionary:
	var before_path := _out_dir.rstrip("/") + "/blast_before.json"
	var after_path := _out_dir.rstrip("/") + "/blast_after.json"
	var fresh := _mode_blast_capture()
	_write("blast_%s.json" % _tag, fresh)
	return {"ok": true, "tag": _tag, "path": _out_dir.rstrip("/") + "/blast_%s" % _tag, "data": fresh}

func _mode_blast_capture() -> Dictionary:
	# Menu-baseline replay (NO designation): General-path units must be
	# byte-stable across the scoring change.
	var l := _load("HQ_CRITICAL")
	if not bool(l.get("ok", false)):
		return {"ok": false}
	var sim: RefCounted = l["sim"]
	var obs: Dictionary = _obs_of(sim)
	var menu: Dictionary = ManagerCls.new().build_coord_menu(obs)
	var sel := {"concept": "HOLD_AND_SCREEN", "main_effort": "CENTER",
		"doctrine": {"aggression": "STANDARD", "tempo": "STANDARD", "risk": "BALANCED", "reserve": "STANDARD", "pursuit": "STANDARD"},
		"assignments": [], "horizon": 4, "hypotheses": []}
	var picked := {}
	for g_val in (menu.get("groups", []) as Array):
		var g: Dictionary = g_val
		var opts: Array = g.get("options", [])
		if not opts.is_empty() and opts[0] is Dictionary:
			picked[str(g.get("id", ""))] = str((opts[0] as Dictionary).get("id", "?"))
			(sel["assignments"] as Array).append({"group": str(g.get("id", "")), "choice": str((opts[0] as Dictionary).get("id", "?"))})
	var turn := 1
	var snap := str(obs.get("snapshot_id", ""))
	var mgr := ManagerCls.new()
	var applied: Dictionary = mgr.apply_plan(_plan_dict(_menu_missions(menu, picked), obs), turn, snap, "probe")
	if not bool(applied.get("ok", false)):
		return {"ok": false, "detail": "apply failed: %s" % str(applied.get("code", ""))}
	var rows: Array = []
	for t in range(1, 5):
		var obs_t: Dictionary = _obs_of(sim)
		var decided: Dictionary = mgr.red_turn(sim, obs_t)
		for tr_val in (decided.get("traces", []) as Array):
			var tr: Dictionary = tr_val
			for u_val in (tr.get("units", []) as Array):
				var u: Dictionary = u_val
				rows.append({"turn": int(obs_t.get("turn", t)), "unit_id": str(u.get("unit_id", "?")),
					"selected": str(u.get("selected_id", "?")), "tgt": str(u.get("resolved_target", "")),
					"cmd": JSON.stringify(u.get("resolved_command", {})), "match": u.get("target_match", null)})
		var acted: Array = []
		for o_val in (decided.get("orders", []) as Array):
			var order: Dictionary = (o_val as Dictionary).get("order", {})
			var gate: Dictionary = ResponseCls.check_order(order, {"acting_side": "RED"})
			if bool(gate.get("ok", false)):
				var ex: Dictionary = CompilerCls.execute(sim, order, "", "red")
				for e_val in (ex.get("executed_units", []) as Array):
					acted.append({"unit_id": str((e_val as Dictionary).get("unit_id", ""))})
		mgr.post_turn(acted, int(obs_t.get("turn", t)))
		if _decisive(sim):
			break
		sim.sim_end_turn()
	return {"ok": true, "decisions": rows}

func _menu_missions(menu: Dictionary, picked: Dictionary) -> Array:
	var missions: Array = []
	for g_val in (menu.get("groups", []) as Array):
		var g: Dictionary = g_val
		var grp := str(g.get("id", ""))
		var cho := str(picked.get(grp, ""))
		for o_val in (g.get("options", []) as Array):
			var o: Dictionary = o_val
			if str(o.get("id", "")) == cho:
				var mi: Dictionary = o.get("mission_template", o)
				if mi.has("task"):
					missions.append(_sanitize_template(mi, grp))
					break
	return missions

func _sanitize_template(t: Dictionary, grp: String) -> Dictionary:
	var m := MissionCls.default_mission(str(t.get("mission_id", grp)), str(t.get("task", "HOLD")))
	m["area"] = str(t.get("area", "ANY"))
	m["assigned_units"] = (t.get("assigned_units", []) as Array).duplicate(true)
	m["objective"] = (t.get("objective", {"kind": "NONE"}) as Dictionary).duplicate(true)
	m["engagement"] = (t.get("engagement", {"policy": "ATTACK_IF_ADVANTAGEOUS"}) as Dictionary).duplicate(true)
	m["success_conditions"] = (t.get("success_conditions", []) as Array).duplicate(true)
	m["abort_conditions"] = (t.get("abort_conditions", []) as Array).duplicate(true)
	m["report_conditions"] = (t.get("report_conditions", []) as Array).duplicate(true)
	return m
