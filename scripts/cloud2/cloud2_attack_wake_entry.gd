extends SceneTree

## ATTACK-WAKE-SEQUENTIAL — deterministic forensic/regression runner.
##
## Phase A deliberately compares two paths from identical fixtures:
##   1. the option selected by the MissionController;
##   2. the resolved canonical attack-slot command on a fresh simulation.
## This isolates selection from enumeration, masking, resolution, compilation,
## execution, and authoritative combat mutation without touching live policy.

const SimControllerCls = preload("res://scripts/sim/sim_controller.gd")
const ObsCls = preload("res://scripts/cloud1/cloud1_observation.gd")
const CompilerCls = preload("res://scripts/cloud1/cloud1_compiler.gd")
const MissionCls = preload("res://scripts/cloud2/cloud2_mission.gd")
const PlanCls = preload("res://scripts/cloud2/cloud2_general_plan.gd")
const MissionControllerCls = preload("res://scripts/cloud2/cloud2_mission_controller.gd")
const OpportunityCls = preload("res://scripts/cloud2/cloud2_opportunity.gd")

const OUT_DIR := "D:/Game development/.workflow/deliverables/ATTACK-WAKE-SEQUENTIAL"
const OUT_PATH := OUT_DIR + "/verification_attack_wake.json"

var _cases: Array = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_cases.append(_run_attack_case("CASE_1_INFANTRY_CONTACT", "R_INF_1", "infantry",
		Vector2i(-24, 0), "B_INF_1", "infantry", Vector2i(-25, 0),
		"ATTACK_CONTACT", {"kind": "NONE"}))
	_cases.append(_run_attack_case("CASE_2_ARCHER_RANGE", "R_ARC_1", "archer",
		Vector2i(-24, 0), "B_INF_1", "infantry", Vector2i(-26, 0),
		"FIRE_PRIORITY_TARGET", {"kind": "NONE"}))
	_cases.append(_run_attack_case("CASE_3_SPEARMAN_CAVALRY", "R_SPE_1", "spearman",
		Vector2i(-24, 0), "B_CAV_1", "cavalry", Vector2i(-25, 0),
		"ATTACK_CAVALRY", {"kind": "FORMATION_CLASS", "class": "CAVALRY"}))
	_cases.append(_run_attack_case("CASE_4_CAVALRY_ARCHER", "R_CAV_1", "cavalry",
		Vector2i(-24, 0), "B_ARC_1", "archer", Vector2i(-25, 0),
		"EXPLOIT_REAR_OR_RANGED", {"kind": "FORMATION_CLASS", "class": "ARCHER"}))
	var selected_attacks := 0
	var direct_attacks := 0
	for c_val in _cases:
		var c: Dictionary = c_val
		if bool(c.get("selected_attack_mutated", false)):
			selected_attacks += 1
		if bool(c.get("direct_attack_mutated", false)):
			direct_attacks += 1
		print("[ATTACK-FORENSIC][%s] selected=%s attack_score=%.3f direct_mutated=%s" % [
			str(c.get("case", "?")), str(c.get("selected_option", "?")),
			float(c.get("attack_score", 0.0)), str(bool(c.get("direct_attack_mutated", false)))])
	var report := {
		"suite": "ATTACK_WAKE_SEQUENTIAL",
		"phase": "A_FORENSIC",
		"cases": _cases,
		"summary": {
			"selected_attacks": selected_attacks,
			"direct_attacks": direct_attacks,
			"attack_case_count": _cases.size(),
			"phase_a_pass": selected_attacks == _cases.size() and direct_attacks == _cases.size(),
		},
	}
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	var f := FileAccess.open(OUT_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(report, "\t"))
		f.close()
	print("[ATTACK-FORENSIC] %s selected attacks; %s direct attacks; %s" % [
		selected_attacks, direct_attacks, OUT_PATH])
	quit(0 if bool((report.get("summary", {}) as Dictionary).get("phase_a_pass", false)) else 1)


func _run_attack_case(case_name: String, red_id: String, red_class: String,
	red_pos: Vector2i, blue_id: String, blue_class: String, blue_pos: Vector2i,
	attack_option_id: String, objective: Dictionary) -> Dictionary:
	var forces := _forces(red_id, red_class, red_pos, blue_id, blue_class, blue_pos)
	var sim := _fresh_sim(case_name, forces)
	var obs := _obs(sim)
	var mission := _mission(red_id, objective)
	var ctrl := MissionControllerCls.new()
	ctrl.setup(mission, PlanCls.default_doctrine(), 11)
	var authoritative: Array = sim.get_manager().get_attackable_targets(red_id)
	var enumerated: Array = OpportunityCls.legal_attacks(sim, [red_id], obs)
	var filtered: Array = ctrl._filtered_attacks(enumerated, obs)
	var decision: Dictionary = ctrl.decide(sim, obs, _ctx(sim, obs))
	var table := _unit_table(decision, red_id)
	var attack_opt := _option_by_id(table, attack_option_id)
	var selected_cmd: Dictionary = (table.get("resolved_command", {}) as Dictionary).duplicate(true)
	var selected_dry: Dictionary = CompilerCls.plan(sim, selected_cmd, "", "red") if not selected_cmd.is_empty() else {}
	var selected_before := _soldiers(sim, blue_id)
	var selected_exec: Dictionary = CompilerCls.execute(sim, selected_cmd, "", "red") if not selected_cmd.is_empty() else {}
	var selected_after := _soldiers(sim, blue_id)

	# Recreate the identical world so downstream attack proof is not affected by
	# the selected command consuming movement/action state.
	var direct_sim := _fresh_sim(case_name + "_DIRECT", forces)
	var direct_obs := _obs(direct_sim)
	var direct_ctrl := MissionControllerCls.new()
	direct_ctrl.setup(mission, PlanCls.default_doctrine(), 11)
	var direct_decision: Dictionary = direct_ctrl.decide(direct_sim, direct_obs, _ctx(direct_sim, direct_obs))
	var direct_table := _unit_table(direct_decision, red_id)
	var direct_opt := _option_by_id(direct_table, attack_option_id)
	var attack_cmd: Dictionary = (direct_opt.get("resolved_command", {}) as Dictionary).duplicate(true)
	var attack_dry: Dictionary = CompilerCls.plan(direct_sim, attack_cmd, "", "red") if not attack_cmd.is_empty() else {}
	var direct_before := _soldiers(direct_sim, blue_id)
	var direct_exec: Dictionary = CompilerCls.execute(direct_sim, attack_cmd, "", "red") if not attack_cmd.is_empty() else {}
	var direct_after := _soldiers(direct_sim, blue_id)

	return {
		"case": case_name,
		"unit_id": red_id,
		"class": red_class.to_upper(),
		"position": [red_pos.x, red_pos.y],
		"mission_id": "M01",
		"mission_task": "ATTACK",
		"mission_area": "ANY",
		"visible_enemies": _visible_enemy_rows(obs),
		"authoritative_attackable_targets": _target_rows(authoritative),
		"enumerated_attacks": enumerated,
		"mission_filter_result": filtered,
		"legal_attack_targets": _attack_target_ids(filtered, red_id),
		"attack_slot": int(attack_opt.get("slot", -1)),
		"attack_option_id": attack_option_id,
		"attack_slot_generated": not attack_opt.is_empty(),
		"attack_masked": bool(attack_opt.get("masked", true)),
		"mask_reason": str(attack_opt.get("mask_reason", "MISSING")),
		"target_selection_result": str(attack_opt.get("resolved_target", "")),
		"attack_score": float(attack_opt.get("final_score", 0.0)),
		"attack_score_parts": (attack_opt.get("parts", {}) as Dictionary).duplicate(true),
		"other_option_scores": _option_scores(table),
		"selected_option": str(table.get("selected_id", "")),
		"selected_slot": int(table.get("selected_slot", -1)),
		"resolved_command": selected_cmd,
		"compiler_result": _compiler_summary(selected_dry),
		"execution_result": _execution_summary(selected_exec),
		"combat_result": {"target": blue_id, "soldiers_before": selected_before,
			"soldiers_after": selected_after, "mutated": selected_after < selected_before},
		"selected_attack_mutated": str(selected_cmd.get("action", "")) == "ATTACK" and selected_after < selected_before,
		"direct_attack_command": attack_cmd,
		"direct_compiler_result": _compiler_summary(attack_dry),
		"direct_execution_result": _execution_summary(direct_exec),
		"direct_combat_result": {"target": blue_id, "soldiers_before": direct_before,
			"soldiers_after": direct_after, "mutated": direct_after < direct_before},
		"direct_attack_mutated": str(attack_cmd.get("action", "")) == "ATTACK" and direct_after < direct_before,
	}


func _forces(red_id: String, red_class: String, red_pos: Vector2i,
	blue_id: String, blue_class: String, blue_pos: Vector2i) -> Array:
	return [
		{"id": blue_id, "class": blue_class, "faction": "blue", "q": blue_pos.x,
			"r": blue_pos.y, "soldiers": 360},
		{"id": red_id, "class": red_class, "faction": "red", "q": red_pos.x,
			"r": red_pos.y, "soldiers": 420},
	]


func _fresh_sim(case_name: String, forces: Array) -> RefCounted:
	var sim: RefCounted = SimControllerCls.new()
	sim.load_scenario({
		"scenario_id": "attack_wake_%s" % case_name.to_lower(),
		"scenario_version": "1.0.0",
		"seed": 11,
		"mission_contract": {"primary_objective": "destroy_all_red", "turn_limit": 12},
		"map": {"bounds": {"q_min": -34, "q_max": -14, "r_min": -8, "r_max": 8},
			"default_terrain": 0, "terrain_overrides": {}, "river_cells": []},
		"forces": forces,
		"start_turn": 1,
	})
	return sim


func _obs(sim: RefCounted) -> Dictionary:
	return ObsCls.build(sim, "red")


func _mission(red_id: String, objective: Dictionary) -> Dictionary:
	var m := MissionCls.default_mission("M01", "ATTACK")
	m["area"] = "ANY"
	m["assigned_units"] = [red_id]
	m["objective"] = objective.duplicate(true)
	m["engagement"] = {"policy": "ATTACK_IF_ADVANTAGEOUS"}
	return m


func _ctx(sim: RefCounted, obs: Dictionary) -> Dictionary:
	return {"turn": 1, "snapshot_id": str(obs.get("snapshot_id", "")),
		"turns_active": 0, "urgency": 0.0, "bounds": sim.map_bounds(),
		"main_effort": "CENTER"}


func _unit_table(decision: Dictionary, unit_id: String) -> Dictionary:
	for t_val in ((decision.get("trace", {}) as Dictionary).get("units", []) as Array):
		if t_val is Dictionary and str((t_val as Dictionary).get("unit_id", "")) == unit_id:
			return t_val
	return {}


func _option_by_id(table: Dictionary, option_id: String) -> Dictionary:
	for o_val in (table.get("options", []) as Array):
		if o_val is Dictionary and str((o_val as Dictionary).get("option_id", "")) == option_id:
			return o_val
	return {}


func _option_scores(table: Dictionary) -> Array:
	var out: Array = []
	for o_val in (table.get("options", []) as Array):
		var o: Dictionary = o_val
		out.append({"slot": int(o.get("slot", -1)), "option_id": str(o.get("option_id", "")),
			"kind": str(o.get("kind", "")), "masked": bool(o.get("masked", false)),
			"mask_reason": str(o.get("mask_reason", "")), "score": float(o.get("final_score", 0.0)),
			"target": str(o.get("resolved_target", "")), "command_action": str((o.get("resolved_command", {}) as Dictionary).get("action", ""))})
	return out


func _visible_enemy_rows(obs: Dictionary) -> Array:
	var out: Array = []
	for e_val in (obs.get("known_enemy_units", []) as Array):
		if e_val is Dictionary and str((e_val as Dictionary).get("contact_state", "")) == "current_visible":
			var e: Dictionary = e_val
			out.append({"unit_id": str(e.get("unit_id", "")), "class": str(e.get("class", "")),
				"q": int(e.get("q", 0)), "r": int(e.get("r", 0)), "region": str(e.get("region", ""))})
	return out


func _target_rows(rows: Array) -> Array:
	var out: Array = []
	for t_val in rows:
		if t_val is Dictionary:
			var t: Dictionary = t_val
			out.append({"id": str(t.get("id", "")), "class": str(t.get("class", "")),
				"distance": int(t.get("distance", -1))})
	return out


func _attack_target_ids(rows: Array, unit_id: String) -> Array:
	var out: Array = []
	for a_val in rows:
		if a_val is Dictionary and str((a_val as Dictionary).get("attacker_id", "")) == unit_id:
			out.append(str((a_val as Dictionary).get("target_id", "")))
	return out


func _compiler_summary(result: Dictionary) -> Dictionary:
	return {"ok": bool(result.get("ok", false)), "code": str(result.get("code", "")),
		"planned": (result.get("planned", []) as Array).duplicate(true),
		"failed": (result.get("failed", []) as Array).duplicate(true)}


func _execution_summary(result: Dictionary) -> Dictionary:
	return {"status": str(result.get("execution_status", "")),
		"executed_units": (result.get("executed_units", []) as Array).duplicate(true),
		"execution_failed": (result.get("execution_failed", []) as Array).duplicate(true)}


func _soldiers(sim: RefCounted, unit_id: String) -> int:
	var u: Dictionary = sim.get_manager().get_unit_by_id(unit_id)
	return int(u.get("soldier_count", 0)) if not u.is_empty() else 0
