extends SceneTree

## ZOMBIE-UNIT deterministic regression (tool-only).
## Real authoritative path: SimController scenario -> Step3UnitManager
## (fortify_unit, execute_attack -> CombatCalculator.calculate_combat ->
## casualty application -> destroy_unit). variance fixed 1.0, no RNG.
##
## For defender strength N in [400,100,30,12,5,2] (fortified and not), a
## fresh healthy 400-infantry attacker (fresh attacker every hit, so attacker
## losses never confound) hits until the defender is destroyed. Records hits
## to kill, and per-hit casualties / fortification damage.
## INVARIANT (zombie check): with the defender otherwise identical, a WEAKER
## defender must never need MORE hits to kill than a stronger one, and every
## valid hit must reduce (fortification HP + soldiers) by >= the unfortified
## damage it would have taken... simplified to: hits_to_kill must be
## non-increasing as N decreases, and the defender must be removed from the
## manager (sim state) when soldier_count reaches 0.
## Prints ZOMBIE_* lines; exit 0 = invariant holds, 1 = zombie reproduced.

const SimControllerCls = preload("res://scripts/sim/sim_controller.gd")
const MAX_HITS := 200


func _init() -> void:
	call_deferred("_run")


func _case(n: int, fortified: bool) -> Dictionary:
	var forces: Array = [
		{"id": "B_INF_1", "class": "infantry", "faction": "blue", "q": 0, "r": 0, "soldiers": n},
		{"id": "B_HQ_1", "class": "hq", "faction": "blue", "q": -6, "r": 0, "soldiers": 300},
		{"id": "R_HQ_1", "class": "hq", "faction": "red", "q": 6, "r": 0, "soldiers": 300},
	]
	for i in range(MAX_HITS):
		forces.append({"id": "R_INF_%d" % (i + 1), "class": "infantry", "faction": "red",
			"q": 1 + (i % 40), "r": -8 + int(i / 40), "soldiers": 400})
	var sim: RefCounted = SimControllerCls.new()
	sim.load_scenario({"scenario_id": "zombie_%d_%s" % [n, str(fortified)], "scenario_version": "1.0.0", "seed": 1,
		"mission_contract": {"primary_objective": "destroy_all_red", "turn_limit": 99},
		"map": {"bounds": {"q_min": -10, "q_max": 45, "r_min": -10, "r_max": 10}, "default_terrain": 0,
			"terrain_overrides": {}, "river_cells": []},
		"forces": forces, "start_turn": 1})
	var mgr = sim.get_manager()
	if fortified:
		var fr: Dictionary = mgr.fortify_unit("B_INF_1")
		if not bool(fr.get("success", false)):
			return {"error": "fortify failed: %s" % str(fr)}
	var hits := 0
	var trace: Array = []
	var units: Dictionary = mgr.get("_units")
	while hits < MAX_HITS and units.has("B_INF_1"):
		var aid := "R_INF_%d" % (hits + 1)
		# place the fresh attacker adjacent to the defender (teleport = test setup only)
		(units[aid] as Dictionary)["q"] = 1
		(units[aid] as Dictionary)["r"] = 0
		var before: Dictionary = (units["B_INF_1"] as Dictionary).duplicate()
		var res: Dictionary = mgr.execute_attack(aid, "B_INF_1", {}, 1.0)
		if not bool(res.get("success", true)) and res.has("error"):
			return {"error": "attack failed: %s" % str(res.get("error"))}
		(units[aid] as Dictionary)["q"] = 30 + hits
		(units[aid] as Dictionary)["r"] = 9
		hits += 1
		var after: Dictionary = units.get("B_INF_1", {})
		trace.append({"hit": hits, "soldiers": int(before.get("soldier_count", 0)),
			"fort_hp": int(before.get("field_fortification_hp", 0)),
			"casualties": int(before.get("soldier_count", 0)) - int(after.get("soldier_count", 0)),
			"fort_dmg": int(before.get("field_fortification_hp", 0)) - int(after.get("field_fortification_hp", 0))})
	return {"n": n, "fortified": fortified, "hits_to_kill": hits if not units.has("B_INF_1") else -1,
		"removed_from_state": not units.has("B_INF_1"), "trace_head": trace.slice(0, 3), "trace_tail": trace.slice(max(0, trace.size() - 2))}


func _run() -> void:
	var zombie := false
	for fortified in [false, true]:
		var prev := -1
		for n in [400, 100, 30, 12, 5, 2]:
			var r := _case(n, fortified)
			if r.has("error"):
				print("ZOMBIE_ERROR %s" % str(r["error"]))
				quit(2)
				return
			print("ZOMBIE_CASE fortified=%s n=%d hits_to_kill=%d removed=%s head=%s tail=%s" % [
				str(fortified), n, int(r["hits_to_kill"]), str(r["removed_from_state"]),
				JSON.stringify(r["trace_head"]), JSON.stringify(r["trace_tail"])])
			var h := int(r["hits_to_kill"])
			if h < 0 or (prev >= 0 and h > prev) or not bool(r["removed_from_state"]):
				zombie = true
				print("ZOMBIE_VIOLATION fortified=%s n=%d hits=%d > stronger-unit hits=%d" % [str(fortified), n, h, prev])
			prev = h
	print("ZOMBIE_RESULT %s" % ("REPRODUCED" if zombie else "CLEAN"))
	quit(1 if zombie else 0)
