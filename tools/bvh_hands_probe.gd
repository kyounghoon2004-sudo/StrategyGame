extends SceneTree

## BRAIN-vs-HANDS diagnostic probe (HANDS phase, read-only).
##
## Calls the NORMAL tactical stack components directly — scenario builders,
## RED observation, coordinator menu expansion, mission validation, and
## Cloud2MissionController.decide() (which internally runs the six-option
## solver + compiler dry-runs). decide() never mutates battle state.
## Dumps per-unit six-slot tables (selection, masks, resolved targets,
## target scores) that battle.json does not persist.
##
## Usage:
##   Godot console --headless --path <StrategyGame> -s res://tools/bvh_hands_probe.gd -- --out-dir "<abs dir>"

const SimControllerCls = preload("res://scripts/sim/sim_controller.gd")
const ObsCls = preload("res://scripts/cloud1/cloud1_observation.gd")
const ScenariosCls = preload("res://scripts/cloud2/cloud2_debug_scenarios.gd")
const CoordMenuCls = preload("res://scripts/cloud2/cloud2_coord_menu.gd")
const MissionCls = preload("res://scripts/cloud2/cloud2_mission.gd")
const PlanCls = preload("res://scripts/cloud2/cloud2_general_plan.gd")
const ControllerCls = preload("res://scripts/cloud2/cloud2_mission_controller.gd")
const OpportunityCls = preload("res://scripts/cloud2/cloud2_opportunity.gd")
const UtilityCls = preload("res://scripts/cloud2/cloud2_utility.gd")

var _out_dir := ""


func _init() -> void:
	_parse_args()
	if _out_dir.is_empty():
		print("[Probe] FATAL: need --out-dir=<abs dir>")
		quit(4)
		return
	var results := {}
	results["hq_crit_menu_defense"] = _case_hq_menu_defense()
	results["hq_crit_designated"] = _case_hq_designated()
	results["hq_crit_designated_soft"] = _case_hq_designated_soft()
	results["hq_crit_doctrine"] = _case_hq_doctrine()
	results["coop_baseline_fix_flank"] = _case_coop()
	results["hq_threat_withdraw"] = _case_withdraw()
	_write("hands_probe_results.json", results)
	var fails := 0
	for k in results.keys():
		var r: Dictionary = results[k]
		print("[Probe] %s ok=%s detail=%s" % [str(k), str(bool(r.get("ok", false))), str(r.get("detail", ""))])
		if not bool(r.get("ok", false)):
			fails += 1
	quit(0 if fails == 0 else 1)


func _parse_args() -> void:
	var all: Array = []
	all.append_array(OS.get_cmdline_user_args())
	all.append_array(OS.get_cmdline_args())
	for a_val in all:
		var a := str(a_val).strip_edges()
		if a.begins_with("--out-dir="):
			_out_dir = a.get_slice("=", 1).strip_edges().trim_prefix("\"").trim_suffix("\"")


func _write(name: String, data: Dictionary) -> void:
	var path := _out_dir.rstrip("/") + "/" + name
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		print("[Probe] FATAL: cannot write %s" % path)
		return
	f.store_string(JSON.stringify(data, "  "))
	f.close()
	print("[Probe] wrote %s (%d bytes)" % [path, JSON.stringify(data).length()])


func _load(scenario_id: String) -> Dictionary:
	var built: Dictionary = ScenariosCls.build(scenario_id)
	if not bool(built.get("ok", false)):
		return {"ok": false, "detail": "build failed: %s" % str(built.get("code", "?"))}
	var sim: RefCounted = SimControllerCls.new()
	var loaded: Dictionary = sim.load_scenario(built.get("scenario", {}))
	if not bool(loaded.get("ok", false)):
		return {"ok": false, "detail": "load failed"}
	var obs: Dictionary = ObsCls.build(sim, "red")
	if not bool(obs.get("ok", false)):
		return {"ok": false, "detail": "obs failed"}
	return {"ok": true, "sim": sim, "obs": obs}


func _expand(obs: Dictionary, assignments: Array, doctrine_profile: Dictionary, concept: String, effort: String, horizon: int) -> Dictionary:
	var menu: Dictionary = CoordMenuCls.build_menu(obs)
	var sel := {"concept": concept, "main_effort": effort, "doctrine": doctrine_profile,
		"assignments": assignments, "horizon": horizon, "hypotheses": []}
	var turn := int(obs.get("turn", 1))
	var snap := str(obs.get("snapshot_id", ""))
	var mission: Dictionary = (obs.get("mission", {}) as Dictionary).duplicate(true)
	var expanded: Dictionary = CoordMenuCls.expand_initial(menu, sel, turn, snap, mission, [])
	if not bool(expanded.get("ok", false)):
		return {"ok": false, "detail": "%s %s" % [str(expanded.get("code", "")), str(expanded.get("detail", ""))]}
	return {"ok": true, "plan": expanded.get("plan", {}), "menu": menu, "choices": expanded.get("choices", {})}


func _std_doctrine() -> Dictionary:
	return {"aggression": "STANDARD", "tempo": "STANDARD", "risk": "BALANCED", "reserve": "STANDARD", "pursuit": "STANDARD"}


func _decide_all(sim: RefCounted, obs: Dictionary, plan: Dictionary) -> Dictionary:
	var bounds: Dictionary = sim.map_bounds() if sim.has_method("map_bounds") else {}
	var hq := bool(OpportunityCls.hq_threatened(obs).get("threatened", false))
	var turn := int(obs.get("turn", 1))
	var snap := str(obs.get("snapshot_id", ""))
	var effort := str((plan.get("concept", {}) as Dictionary).get("main_effort", "CENTER"))
	var doctrine: Dictionary = (plan.get("doctrine", {}) as Dictionary).duplicate(true)
	var out := {"hq_threatened": hq, "missions": []}
	for m_val in (plan.get("missions", []) as Array):
		var m: Dictionary = (m_val as Dictionary).duplicate(true)
		m["status"] = "ACTIVE"
		m["activated_turn"] = turn
		var ctrl := ControllerCls.new()
		ctrl.setup(m, doctrine, 11)
		var dctx := {"turn": turn, "snapshot_id": snap, "turns_active": 0,
			"urgency": 0.5 if hq else 0.0, "bounds": bounds, "main_effort": effort}
		var res: Dictionary = ctrl.decide(sim, obs, dctx)
		var trace: Dictionary = (res.get("trace", {}) as Dictionary).duplicate(true)
		var units: Array = []
		for t_val in (trace.get("units", []) as Array):
			var t: Dictionary = t_val
			var slots: Array = []
			for o_val in (t.get("options", []) as Array):
				var o: Dictionary = o_val
				slots.append({
					"slot": int(o.get("slot", -1)), "id": str(o.get("option_id", "?")),
					"kind": str(o.get("kind", "?")), "masked": bool(o.get("masked", false)),
					"mask": str(o.get("mask_reason", "")),
					"final": snappedf(float(o.get("final_score", 0.0)), 0.01),
					"base": snappedf(float(o.get("base_score", 0.0)), 0.01),
					"mission": snappedf(float(o.get("mission_score", 0.0)), 0.01),
					"tgt": str(o.get("resolved_target", "")),
					"dest": o.get("resolved_destination", []),
				})
			units.append({
				"unit_id": str(t.get("unit_id", "?")), "class": str(t.get("unit_class", "?")),
				"selected": str(t.get("selected_id", "?")), "selected_slot": int(t.get("selected_slot", -1)),
				"resolved_target": str(t.get("resolved_target", "")),
				"resolved_destination": t.get("resolved_destination", []),
				"command": t.get("resolved_command", {}),
				"compiler": str(t.get("compiler", "?")),
				"target_scores": t.get("target_scores", []),
				"slots": slots,
			})
		out["missions"].append({
			"mission_id": str(m.get("mission_id", "?")), "task": str(m.get("task", "?")),
			"area": str(m.get("area", "?")), "units": m.get("assigned_units", []),
			"objective": m.get("objective", {}), "engagement": m.get("engagement", {}),
			"status_hint": str(res.get("status_hint", "?")), "reason": str(res.get("reason", "?")),
			"chosen": str(trace.get("chosen", "?")), "orders": res.get("orders", []),
			"unit_tables": units,
		})
	return out


func _summarize(decided: Dictionary) -> Dictionary:
	var s := {}
	for m_val in (decided.get("missions", []) as Array):
		var m: Dictionary = m_val
		var rows := []
		for u_val in (m.get("unit_tables", []) as Array):
			var u: Dictionary = u_val
			rows.append("%s->%s tgt=%s" % [str(u.get("unit_id", "?")), str(u.get("selected", "?")), str(u.get("resolved_target", "-"))])
		s[str(m.get("mission_id", "?"))] = "; ".join(rows)
	return s


func _case_hq_menu_defense() -> Dictionary:
	var l := _load("HQ_CRITICAL")
	if not bool(l.get("ok", false)):
		return {"ok": false, "detail": str(l.get("detail", ""))}
	var e := _expand(l["obs"], [
		{"group": "G1", "choice": "G1_FIX_CENTER"},
		{"group": "G2", "choice": "G2_ATTACK_CENTER"},
		{"group": "G3", "choice": "G3_HOLD_ANY"},
	], _std_doctrine(), "ACTIVE_DEFENSE", "CENTER", 2)
	if not bool(e.get("ok", false)):
		return {"ok": false, "detail": str(e.get("detail", ""))}
	var decided := _decide_all(l["sim"], l["obs"], e["plan"])
	return {"ok": true, "detail": "menu-faithful FIX+ATTACK+HOLD on HQ_CRITICAL t1",
		"summary": _summarize(decided), "full": decided}


func _retarget_g2(plan: Dictionary, objective: Dictionary, policy: String) -> Dictionary:
	var p: Dictionary = plan.duplicate(true)
	for m_val in (p.get("missions", []) as Array):
		var m: Dictionary = m_val
		if str(m.get("mission_id", "")) == "M02":
			m["objective"] = objective.duplicate(true)
			m["engagement"] = {"policy": policy}
	return p


func _case_hq_designated() -> Dictionary:
	var l := _load("HQ_CRITICAL")
	if not bool(l.get("ok", false)):
		return {"ok": false, "detail": str(l.get("detail", ""))}
	var e := _expand(l["obs"], [
		{"group": "G1", "choice": "G1_FIX_CENTER"},
		{"group": "G2", "choice": "G2_ATTACK_CENTER"},
		{"group": "G3", "choice": "G3_HOLD_ANY"},
	], _std_doctrine(), "ACTIVE_DEFENSE", "CENTER", 2)
	if not bool(e.get("ok", false)):
		return {"ok": false, "detail": str(e.get("detail", ""))}
	var p: Dictionary = _retarget_g2(e["plan"],
		{"kind": "ENEMY_FORMATION", "unit_id": "B_CAV_1"}, "ATTACK_DESIGNATED_ONLY")
	var m2: Dictionary = (p.get("missions", []) as Array)[1]
	var mv: Dictionary = MissionCls.validate_mission(m2)
	var pv: Dictionary = PlanCls.validate_plan(p, {"turn": 1,
		"snapshot_id": str(l["obs"].get("snapshot_id", "")), "plan_version": 1})
	var decided := _decide_all(l["sim"], l["obs"], p)
	return {"ok": true, "detail": "G2 ATTACK + ENEMY_FORMATION B_CAV_1 + ATTACK_DESIGNATED_ONLY",
		"mission_valid": bool(mv.get("ok", false)), "mission_code": str(mv.get("code", "")),
		"plan_valid": bool(pv.get("ok", false)), "plan_code": str(pv.get("code", "")),
		"summary": _summarize(decided), "full": decided}


func _case_hq_designated_soft() -> Dictionary:
	var l := _load("HQ_CRITICAL")
	if not bool(l.get("ok", false)):
		return {"ok": false, "detail": str(l.get("detail", ""))}
	var e := _expand(l["obs"], [
		{"group": "G1", "choice": "G1_FIX_CENTER"},
		{"group": "G2", "choice": "G2_ATTACK_CENTER"},
		{"group": "G3", "choice": "G3_HOLD_ANY"},
	], _std_doctrine(), "ACTIVE_DEFENSE", "CENTER", 2)
	if not bool(e.get("ok", false)):
		return {"ok": false, "detail": str(e.get("detail", ""))}
	var p: Dictionary = _retarget_g2(e["plan"],
		{"kind": "ENEMY_FORMATION", "unit_id": "B_CAV_1"}, "ATTACK_IF_ADVANTAGEOUS")
	var decided := _decide_all(l["sim"], l["obs"], p)
	var p1: Dictionary = _retarget_g2(e["plan"],
		{"kind": "ENEMY_FORMATION", "unit_id": "B_CAV_1"}, "ATTACK_IF_ADVANTAGEOUS")
	for m_val in (p1.get("missions", []) as Array):
		if str((m_val as Dictionary).get("mission_id", "")) == "M01":
			(m_val as Dictionary)["objective"] = {"kind": "ENEMY_FORMATION", "unit_id": "B_CAV_1"}
	var decided_both := _decide_all(l["sim"], l["obs"], p1)
	return {"ok": true, "detail": "designated objective WITHOUT designated-only policy (soft bonus); plus M01+M02 both designating B_CAV_1",
		"summary_g2_only": _summarize(decided), "summary_both": _summarize(decided_both),
		"full_g2_only": decided, "full_both": decided_both}


func _case_hq_doctrine() -> Dictionary:
	var l := _load("HQ_CRITICAL")
	if not bool(l.get("ok", false)):
		return {"ok": false, "detail": str(l.get("detail", ""))}
	var asn := [
		{"group": "G1", "choice": "G1_FIX_CENTER"},
		{"group": "G2", "choice": "G2_ATTACK_CENTER"},
		{"group": "G3", "choice": "G3_HOLD_ANY"},
	]
	var cautious := {"aggression": "LOW", "tempo": "SLOW", "risk": "CAUTIOUS", "reserve": "STRICT", "pursuit": "LIMITED"}
	var bold := {"aggression": "HIGH", "tempo": "FAST", "risk": "BOLD", "reserve": "LOOSE", "pursuit": "STRONG"}
	var e_c := _expand(l["obs"], asn, cautious, "ACTIVE_DEFENSE", "CENTER", 2)
	var e_b := _expand(l["obs"], asn, bold, "ACTIVE_DEFENSE", "CENTER", 2)
	var e_s := _expand(l["obs"], asn, _std_doctrine(), "ACTIVE_DEFENSE", "CENTER", 2)
	if not (bool(e_c.get("ok", false)) and bool(e_b.get("ok", false)) and bool(e_s.get("ok", false))):
		return {"ok": false, "detail": "expansion failed"}
	var d_c := _decide_all(l["sim"], l["obs"], e_c["plan"])
	var d_b := _decide_all(l["sim"], l["obs"], e_b["plan"])
	var d_s := _decide_all(l["sim"], l["obs"], e_s["plan"])
	return {"ok": true, "detail": "same missions, cautious vs standard vs bold doctrine",
		"summary_cautious": _summarize(d_c), "summary_standard": _summarize(d_s),
		"summary_bold": _summarize(d_b),
		"full_cautious": d_c, "full_standard": d_s, "full_bold": d_b}


func _case_coop() -> Dictionary:
	var l := _load("COOP_BASELINE")
	if not bool(l.get("ok", false)):
		return {"ok": false, "detail": str(l.get("detail", ""))}
	var e := _expand(l["obs"], [
		{"group": "G1", "choice": "G1_FIX_CENTER"},
		{"group": "G2", "choice": "G2_FLANK_CENTER"},
		{"group": "G3", "choice": "G3_HOLD_ANY"},
	], _std_doctrine(), "FIX_AND_FLANK", "CENTER", 4)
	if not bool(e.get("ok", false)):
		return {"ok": false, "detail": str(e.get("detail", ""))}
	var decided := _decide_all(l["sim"], l["obs"], e["plan"])
	return {"ok": true, "detail": "menu-faithful FIX+FLANK+HOLD on COOP_BASELINE t1 (B_INF_1 forward, BLUE holds)",
		"summary": _summarize(decided), "full": decided}


func _case_withdraw() -> Dictionary:
	var l := _load("HQ_THREATENED")
	if not bool(l.get("ok", false)):
		return {"ok": false, "detail": str(l.get("detail", ""))}
	var e := _expand(l["obs"], [
		{"group": "G1", "choice": "G1_WITHDRAW_CENTER"},
		{"group": "G2", "choice": "G2_ATTACK_CENTER"},
		{"group": "G3", "choice": "G3_HOLD_ANY"},
	], _std_doctrine(), "DELAY_AND_COUNTER", "CENTER", 2)
	if not bool(e.get("ok", false)):
		return {"ok": false, "detail": str(e.get("detail", ""))}
	var decided := _decide_all(l["sim"], l["obs"], e["plan"])
	return {"ok": true, "detail": "G1 WITHDRAW task on HQ_THREATENED t1 (recall-to-HQ expressivity)",
		"summary": _summarize(decided), "full": decided}
