extends SceneTree

## MOVE+ATTACK same-turn legality repro (tool-only). Authoritative SimController
## truth: a melee unit N hexes from a visible enemy moves adjacent, then we
## read the two gates each path uses before offering ATTACK:
##   human (shell):  selection -> get_attackable_targets (blocked only by action_ended)
##   Laya:           enumerator stops re-asking a unit once
##                   is_unit_data_turn_resolved(u) is true, then
##                   ATTACK candidates = get_attackable_targets
## and finally executes the attack. Prints MA_* lines.

const SimControllerCls = preload("res://scripts/sim/sim_controller.gd")
const EnumCls = preload("res://scripts/laya/laya_enumerator.gd")


func _init() -> void:
	call_deferred("_run")


func _case(cls: String, dist: int, side: String) -> Dictionary:
	var me := "B_X_1" if side == "blue" else "R_X_1"
	var foe := "R_T_1" if side == "blue" else "B_T_1"
	var sign := 1 if side == "blue" else -1
	var forces: Array = [
		{"id": me, "class": cls, "faction": side, "q": 0, "r": 0, "soldiers": 300},
		{"id": foe, "class": "infantry", "faction": "red" if side == "blue" else "blue", "q": sign * dist, "r": 0, "soldiers": 300},
		{"id": "B_HQ_1", "class": "hq", "faction": "blue", "q": -12, "r": 6, "soldiers": 300},
		{"id": "R_HQ_1", "class": "hq", "faction": "red", "q": 12, "r": 6, "soldiers": 300},
	]
	var sim: RefCounted = SimControllerCls.new()
	var ld: Dictionary = sim.load_scenario({"scenario_id": "ma_%s_%d_%s" % [cls, dist, side], "scenario_version": "1.0.0", "seed": 1,
		"mission_contract": {"primary_objective": "destroy_all_red", "turn_limit": 9},
		"map": {"bounds": {"q_min": -14, "q_max": 14, "r_min": -8, "r_max": 8}, "default_terrain": 0,
			"terrain_overrides": {}, "river_cells": []},
		"forces": forces, "start_turn": 1})
	var mgr = sim.get_manager()
	var u0: Dictionary = mgr.get_unit_by_id(me)
	var before_targets := (mgr.get_attackable_targets(me) as Array).size()
	var mv: Dictionary = sim.do_move(me, sign * (dist - 1), 0, side)
	var u1: Dictionary = mgr.get_unit_by_id(me)
	var resolved := bool(mgr.is_unit_data_turn_resolved(u1))
	var targets := (mgr.get_attackable_targets(me) as Array).size()
	# Real Laya enumerator on the same truth (grid stub carries the sim's cell data).
	var gs := GDScript.new()
	gs.source_code = "extends Node
var cell_data := {}
"
	gs.reload()
	var grid := Node.new()
	grid.set_script(gs)
	grid.set("cell_data", sim.get("_cell_data"))
	var en = EnumCls.new()
	en.set_side(side)
	var cerr: String = en.configure(mgr, sim.get_service(), sim.get_projector(), grid, sim.map_bounds(), func() -> bool: return false)
	var pool: Dictionary = en.enumerate_for_unit(me)
	var kinds: Array = []
	for c in (pool.get("candidates", []) as Array):
		kinds.append(str((c as Dictionary).get("action_type", "")))
	var enum_attack := kinds.has("ATTACK")
	var atk: Dictionary = sim.do_attack(me, foe, side)
	var u2: Dictionary = mgr.get_unit_by_id(me)
	var enum_after_resolved := bool(en.is_unit_id_resolved(me))
	grid.free()
	return {"cls": cls, "dist": dist, "side": side, "load_ok": bool(ld.get("ok", true)),
		"base_mp": float(u0.get("base_mp", 0)), "targets_before": before_targets,
		"move_ok": bool(mv.get("success", mv.get("ok", false))), "pos": [int(u1.get("q", 0)), int(u1.get("r", 0))],
		"spent": float(u1.get("turn_move_cost_spent", 0)), "blue_limit": float(u1.get("blue_limit", 0)),
		"action_ended": bool(u1.get("action_ended", false)),
		"human_attack_offered": targets > 0 and not bool(u1.get("action_ended", false)),
		"laya_reasks_unit": not resolved, "laya_attack_offered": (not resolved) and targets > 0,
		"attack_exec": bool(atk.get("success", false)), "attack_err": str(atk.get("error", "")),
		"def_casualties": int(atk.get("defender_casualties", -1)),
		"enum_cfg_err": cerr, "enum_resolved": bool(pool.get("resolved", true)), "enum_kinds": kinds,
		"enum_attack_offered": enum_attack, "resolved_after_attack": enum_after_resolved}


func _run() -> void:
	var gap := false
	for side in ["blue", "red"]:
		for cls in ["infantry", "cavalry", "spearman"]:
			for dist in [2, 3]:
				var r := _case(cls, dist, side)
				print("MA_CASE %s" % JSON.stringify(r))
				if r["move_ok"] and r["attack_exec"] and not r["enum_attack_offered"]:
					gap = true
	print("MA_RESULT %s" % ("LAYA_GAP" if gap else "NO_GAP"))
	quit(0)
