extends RefCounted

## Minimal normal-objective evaluator for tutorial missions. Universal HQ
## terminal results remain owned by Step2RBattlefieldShell.
static func evaluate_round(scenario: Dictionary, manager: Object, state: Dictionary, completed_round: int) -> Dictionary:
	var next := state.duplicate(true)
	next["last_round"] = completed_round
	var mission_id := str(scenario.get("mission_id", ""))
	var objectives: Array = scenario.get("objectives", [])
	if objectives.is_empty():
		return {"state": next, "result": ""}
	var objective: Dictionary = objectives[0]
	var target_id := str(objective.get("target_ref", ""))
	var result := ""
	match mission_id:
		"M1", "M2":
			var site: Variant = manager.call("get_stronghold_by_id", target_id)
			if site == null or str(site.owner) != "blue":
				result = "defeat"
			elif completed_round >= int(scenario.get("round_limit", 0)):
				result = "victory"
		"M3":
			var collapse: Dictionary = scenario.get("collapse_withdrawal", {})
			var targets: Array = collapse.get("target_unit_ids", [])
			var lost := 0
			for unit_id in targets:
				var live_unit: Dictionary = manager.call("get_unit_by_id", str(unit_id))
				if live_unit.is_empty() or bool(live_unit.get("routed", false)):
					lost += 1
			var threshold := float(collapse.get("loss_ratio", 1.0))
			if not targets.is_empty() and float(lost) / float(targets.size()) >= threshold:
				result = "victory"
			elif completed_round >= int(scenario.get("round_limit", 0)):
				result = "defeat"
		"M4":
			var sites: Array = scenario.get("control_sites", [])
			var held := 0
			for entry in sites:
				var site_id := str((entry as Dictionary).get("stronghold_id", ""))
				var stronghold: Variant = manager.call("get_stronghold_by_id", site_id)
				if stronghold != null and str(stronghold.owner) == "blue":
					held += 1
			var streak := int(next.get("full_control_streak", 0))
			streak = streak + 1 if not sites.is_empty() and held == sites.size() else 0
			next["full_control_streak"] = streak
			next["control_sites_blue"] = held
			if streak >= 3:
				result = "victory"
			elif completed_round >= int(scenario.get("round_limit", 0)):
				result = "victory" if held >= 2 else "defeat"
		"M5":
			var site5: Variant = manager.call("get_stronghold_by_id", target_id)
			if site5 != null and str(site5.owner) == "blue":
				result = "victory"
			elif completed_round >= int(scenario.get("round_limit", 0)):
				result = "defeat"
	next["result"] = result
	return {"state": next, "result": result}
