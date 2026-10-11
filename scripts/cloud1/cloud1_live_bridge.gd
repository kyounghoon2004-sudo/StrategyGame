class_name Cloud1LiveBridge
extends RefCounted

## CLOUD STEP 1B — Live battle bridge (additive adapter, owns NO state).
##
## Adapts the LIVE Step2R battlefield authorities to the SimController
## interface consumed by Cloud1Observation / Cloud1ActionTable /
## Cloud1Compiler. Every read delegates to the live objects; every mutation
## goes through the live shell / Step7BattleCommandService paths (via
## Cloud1LiveExecutor, never direct manager writes from the dock).
##
## No duplicate simulation: get_manager() returns the shell's own
## Step3UnitManager instance, get_service() the live command service.

const RulesFingerprintCls = preload("res://scripts/sim/sim_rules_fingerprint.gd")
const EpisodeRuntimeCls = preload("res://scripts/episodes/episode_runtime.gd")

const SCENARIO_ID := "live_step2r_battle"
const KNOWLEDGE_PROJECTION_VERSION := "knowledge_projection_v1"

var _shell: Node = null
var _det: Node = null


func bind(shell_ref: Node, det_ref: Node) -> bool:
	_shell = shell_ref
	_det = det_ref
	return is_loaded()


func is_loaded() -> bool:
	if _shell == null or _det == null:
		return false
	if not bool(_det.get("ready_for_step7")):
		return false
	return get_manager() != null and get_service() != null


func get_shell() -> Node:
	return _shell


func get_det() -> Node:
	return _det


func get_manager() -> RefCounted:
	if _shell == null:
		return null
	return _shell.get("unit_manager") as RefCounted


func get_service() -> RefCounted:
	if _det == null:
		return null
	return _det.get("command_service") as RefCounted


func get_truth() -> RefCounted:
	if _det == null:
		return null
	return _det.get("truth") as RefCounted


func get_projector() -> RefCounted:
	if _det == null:
		return null
	return _det.get("projector") as RefCounted


func get_step6() -> RefCounted:
	if _shell == null:
		return null
	return _shell.get("_step6") as RefCounted


func scenario_id() -> String:
	return SCENARIO_ID


func rules_fingerprint() -> Dictionary:
	return RulesFingerprintCls.compute()


## Live map bounds derived from the real grid (no invented numbers).
func map_bounds() -> Dictionary:
	if _shell != null and _shell.has_method("map_bounds"):
		return _shell.call("map_bounds")
	var mgr := get_manager()
	if _shell != null:
		var grid: Node = _shell.get("hex_grid") as Node
		if grid != null:
			var cells: Dictionary = grid.get("cell_data") as Dictionary
			if not cells.is_empty():
				var qmin := 1 << 30
				var qmax := -(1 << 30)
				var rmin := 1 << 30
				var rmax := -(1 << 30)
				for key in cells.keys():
					var parts := str(key).split(",")
					if parts.size() != 2 or not parts[0].is_valid_int() or not parts[1].is_valid_int():
						continue
					qmin = mini(qmin, int(parts[0]))
					qmax = maxi(qmax, int(parts[0]))
					rmin = mini(rmin, int(parts[1]))
					rmax = maxi(rmax, int(parts[1]))
				return {"q_min": qmin, "q_max": qmax, "r_min": rmin, "r_max": rmax}
	return {
		"q_min": -40, "q_max": 40,
		"r_min": -40, "r_max": 40,
		"min_vertical": -80, "max_vertical": 80,
		"radius": 40, "cell_count": 4921
	}


func truth_version() -> int:
	var t := get_truth()
	if t != null:
		return int(t.get_version())
	return -1


func truth_fingerprint() -> String:
	var t := get_truth()
	if t != null:
		return str(t.fingerprint())
	return ""


func notify_mutation(reason: String) -> void:
	var t := get_truth()
	if t != null:
		t.notify_mutation(reason)


func build_knowledge(side: String) -> Dictionary:
	var mgr := get_manager()
	var turn := 1
	if mgr != null and mgr.has_method("get_current_turn"):
		turn = int(mgr.get_current_turn())
	var ledger := {"side": "blue"}
	var blue_svc: RefCounted = _det.get("blue_service") as RefCounted if _det != null else null
	if side == "red":
		var red_svc: RefCounted = _det.get("red_service") as RefCounted if _det != null else null
		if red_svc != null:
			ledger = red_svc.build(turn)
	elif blue_svc != null:
		ledger = blue_svc.build(turn)
	return {
		"side": side,
		"current_turn": turn,
		"scenario_id": SCENARIO_ID,
		"knowledge_projection": KNOWLEDGE_PROJECTION_VERSION,
		"ledger": ledger,
		"objectives": _stronghold_facts(),
	}


func world_truth() -> Dictionary:
	var mgr := get_manager()
	if mgr == null:
		return {"error": "Live battle unavailable."}
	return {
		"scenario_id": SCENARIO_ID,
		"turn": int(mgr.get_current_turn()),
		"units": _sorted_units(true),
		"strongholds": _stronghold_facts(),
		"fingerprint": fingerprint(),
	}


## Deterministic tactical fingerprint over LIVE state (same field shape as
## SimController.fingerprint so H-gates can compare like-for-like).
func fingerprint() -> String:
	var mgr := get_manager()
	if mgr == null:
		return "unloaded"
	var parts: Array = ["live=step2r", "t=%d" % int(mgr.get_current_turn())]
	for u in _sorted_units(true):
		parts.append("%s:%d,%d:mp%.3f:ae%s:sol%d:mor%.3f:fat%.3f:rt%s:gar%s" % [
			str(u.get("id", "?")),
			int(u.get("q", 0)), int(u.get("r", 0)),
			float(u.get("remaining_mp", 0.0)),
			str(bool(u.get("action_ended", false))),
			int(u.get("soldier_count", 0)),
			float(u.get("morale", 0.0)),
			float(u.get("fatigue", 0.0)),
			str(bool(u.get("routed", false))),
			str(bool(u.get("garrisoned", false))),
		])
	for sh in _stronghold_facts():
		parts.append("sh:%s:%s:hp%d:br%s:gar%d" % [
			str(sh.get("structure_id", "?")), str(sh.get("owner", "?")),
			int(sh.get("fortification_hp", 0)), str(bool(sh.get("breached", false))),
			int(sh.get("garrison_count", 0)),
		])
	return "|".join(parts)


func _sorted_units(include_garrisoned: bool) -> Array:
	var mgr := get_manager()
	var raw: Array = []
	if mgr == null:
		return raw
	if include_garrisoned and mgr.has_method("get_all_units_including_garrisoned"):
		raw = mgr.get_all_units_including_garrisoned()
	else:
		raw = mgr.get_all_units()
	var out: Array = []
	for u in raw:
		if u is Dictionary:
			out.append((u as Dictionary).duplicate(true))
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a.get("id", "")) < str(b.get("id", "")))
	return out


func _stronghold_facts() -> Array:
	var out: Array = []
	var mgr := get_manager()
	if mgr == null or not mgr.has_method("get_all_strongholds"):
		return out
	var items: Array = mgr.get_all_strongholds()
	items.sort_custom(func(a: Variant, b: Variant) -> bool: return str(a.structure_id) < str(b.structure_id))
	for sh in items:
		out.append({
			"structure_id": str(sh.structure_id),
			"owner": str(sh.owner),
			"fortification_hp": int(sh.fortification_hp),
			"fortification_hp_max": int(sh.fortification_hp_max),
			"breached": bool(sh.breached),
			"garrison_count": int(sh.get_garrison_count()),
			"garrison_roster": sh.get_garrison_roster(),
			"anchor": [int(sh.get_anchor().x), int(sh.get_anchor().y)],
		})
	return out


func _central() -> float:
	var s6 := get_step6()
	if s6 != null and s6.has_method("get_central"):
		return float(s6.get_central())
	return 0.0


## Live dev-battle mission judgment (fixed contract; reads live state only).
## Mirrors SimController.evaluate_mission semantics for the live roster:
## defeat when the HQ falls / battle lost, victory when no RED field units
## remain, otherwise ongoing. Turn limit is open-ended (0) in the dev battle.
func evaluate_mission() -> Dictionary:
	var mgr := get_manager()
	if mgr == null:
		return {"mission_status": "error", "error": "Live battle unavailable."}
	if not EpisodeRuntimeCls.episode_id().is_empty():
		var blue_hq_alive := false
		var red_hq_alive := false
		for u in _sorted_units(true):
			if str(u.get("class", "")) == "hq" and int(u.get("soldier_count", 0)) > 0:
				if str(u.get("faction", "")) == "blue": blue_hq_alive = true
				if str(u.get("faction", "")) == "red": red_hq_alive = true
		var blue_lost := bool(_shell.get("_battle_lost")) or not blue_hq_alive
		var blue_won := bool(_shell.get("_battle_won")) or not red_hq_alive
		return {
			"mission_status": "defeat" if blue_lost else ("victory" if blue_won else "ongoing"),
			"termination_reason": "BLUE_HQ_DESTROYED" if blue_lost else ("RED_HQ_DESTROYED" if blue_won else "objective_incomplete"),
			"primary_objective": "destroy_red_hq", "turn_limit": 0,
			"turns_elapsed": int(mgr.get_current_turn()),
			"hq_state": "active" if blue_hq_alive else "missing",
			"objectives": _stronghold_facts(),
		}
	var turn := int(mgr.get_current_turn())
	var blue_alive := 0
	var red_alive := 0
	var hq_alive := false
	for u in _sorted_units(true):
		if int(u.get("soldier_count", 0)) <= 0:
			continue
		if str(u.get("faction", "")) == "blue":
			blue_alive += 1
			if str(u.get("class", "")) == "hq":
				hq_alive = true
		elif str(u.get("faction", "")) == "red" and not bool(u.get("garrisoned", false)):
			red_alive += 1
	var lost := hq_alive == false or blue_alive == 0
	if _shell != null and bool(_shell.get("_battle_lost")):
		lost = true
	var status := "ongoing"
	var reason := "objective_incomplete"
	if lost:
		status = "defeat"
		reason = "hq_destroyed" if not hq_alive else "blue_annihilated"
	elif red_alive == 0:
		status = "victory"
		reason = "all_red_destroyed"
	return {
		"mission_status": status,
		"termination_reason": reason,
		"primary_objective": "destroy_all_red",
		"turn_limit": 0,
		"turns_elapsed": turn,
		"blue_formations_alive": blue_alive,
		"red_formations_alive": red_alive,
		"hq_state": "active" if hq_alive else "missing",
		"objectives": _stronghold_facts(),
	}
