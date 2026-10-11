class_name SimController
extends RefCounted

## Simulation Playground v0.1 — deterministic, headless episode controller.
##
## ARCHITECTURE: Godot remains the sole owner of world truth, legality,
## pathfinding, occupancy, movement, combat, morale, supply, fog, mutation,
## mission outcome and deterministic execution. This controller owns NO game
## rules: it wires the SAME authoritative objects the live battle uses and
## only bypasses presentation (rendering, tweens, timers, audio, UI, input).
##
## Authoritative path reused (verified against step2r_battlefield_shell.gd):
##   BLUE move   : Step7BattleCommandService.execute_move_intent
##                 -> execute_player_move_path
##                 -> Step3UnitManager.execute_player_stepwise_move
##                 (shell line ~2648 uses the same service + manager call)
##   BLUE attack : Step7BattleCommandService.execute_attack_intent with
##                 Step6DecisionLayer.attacker_bonus_vs modifiers
##                 -> Step3UnitManager.execute_attack
##                 -> CombatCalculator.calculate_combat
##                 (shell lines ~2954-2955, identical call shape)
##   RED attack  : Step6DecisionLayer.attacker_bonus_vs
##                 -> Step3UnitManager.execute_attack
##                 (shell lines ~2123-2124, identical call shape)
##   RED move    : Step3Pathfinding.find_route (GREEN_ONLY policy)
##                 -> Step3UnitManager.execute_move
##                 (shell lines ~2171-2191, identical call shape)
##   Turn cycle  : Step6.end_turn_charges -> UnitManager.end_turn ->
##                 Step6.begin_player_turn -> Fog.recompute
##                 (shell finish_enemy_phase, same order, no timers/banners)
##   After combat: Step6.after_combat + Fog.mark_combat_engaged
##                 (shell _s6_after_combat + _fog_mark_engaged)
##
## NO presentation calls exist in this file: no await, no tweens, no timers,
## no sound buses, no Input, no renderer, no tree access.

const HexCellCls = preload("res://scripts/core/hex_cell.gd")
const HexGridCls = preload("res://scripts/core/hex_grid.gd")
const Step3UnitManagerCls = preload("res://scripts/step3/step3_unit_manager.gd")
const Step3PathfindingCls = preload("res://scripts/step3/step3_pathfinding.gd")
const Step3ConfigCls = preload("res://scripts/core/step3_config.gd")
const FogCls = preload("res://scripts/step5/fog_of_war.gd")
const Step6DecisionLayerCls = preload("res://scripts/step6/step6_decision_layer.gd")
const CommandServiceCls = preload("res://scripts/step7/step7_battle_command_service.gd")
const ProjectorCls = preload("res://scripts/step7/step7_observation_projector.gd")
const TruthCls = preload("res://scripts/step7/step7_world_truth.gd")
const BlueKnowledgeCls = preload("res://scripts/step7/step7_blue_knowledge_service.gd")
const RedKnowledgeCls = preload("res://scripts/step7/step7_red_knowledge_service.gd")
const RulesFingerprintCls = preload("res://scripts/sim/sim_rules_fingerprint.gd")

const KNOWLEDGE_PROJECTION_VERSION := "knowledge_projection_v1"
const SIM_VERSION := "sim_playground_v0.1"

## Minimal shell stand-in for Step7BattleCommandService / Step7WorldTruth.
## Exposes the same members the live shell provides (river/stronghold cells,
## fog-backed visibility sets, player-known occupancy) backed by the REAL
## Fog + UnitManager instances. Owns no rules.
class SimShellShim:
	extends Node
	var _river_cells: Dictionary = {}
	var _stronghold_cells: Dictionary = {}
	var unit_manager: RefCounted = null
	var hex_grid: Node = null
	var fog: RefCounted = null

	func _fog_visible_enemy_id_set() -> Dictionary:
		var out: Dictionary = {}
		if fog == null or unit_manager == null:
			return out
		for u in (unit_manager as RefCounted).get_all_units():
			if str(u.get("faction", "")) != "red":
				continue
			var eid: String = str(u.get("id", ""))
			if (fog as RefCounted).is_enemy_visible(u):
				out[eid] = true
		return out

	func _fog_is_enemy_visible(enemy_id: String) -> bool:
		if fog == null or unit_manager == null:
			return true
		var e: Dictionary = (unit_manager as RefCounted).get_unit_by_id(enemy_id)
		if e.is_empty():
			return false
		return (fog as RefCounted).is_enemy_visible(e)

	func _player_known_occupied() -> Dictionary:
		if unit_manager == null:
			return {}
		if (unit_manager as RefCounted).has_method("get_player_known_occupied"):
			return (unit_manager as RefCounted).get_player_known_occupied(_fog_visible_enemy_id_set())
		return (unit_manager as RefCounted).get_occupied_dict()


const VALID_OBJECTIVES := ["destroy_all_red", "capture_capital", "survive_turns", "hold_hq"]
const VALID_CLASSES := ["infantry", "spearman", "archer", "cavalry", "scout", "siege", "conscript", "hq"]

var _scenario: Dictionary = {}
var _seed: int = 0
var _rng := RandomNumberGenerator.new()
var _grid: Node = null
var _cell_data: Dictionary = {}
var _river_cells: Dictionary = {}
var _stronghold_cells: Dictionary = {}
var _manager: RefCounted = null
var _fog: RefCounted = null
var _step6: RefCounted = null
var _service: RefCounted = null
var _projector: RefCounted = null
var _truth: RefCounted = null
var _blue_svc: RefCounted = null
var _red_svc: RefCounted = null
var _shim: Node = null
var _rules: Dictionary = {}
var _action_history: Array = []
var _action_seq: int = 0
var _initial_fingerprint: String = ""
var _initial_snapshot: Dictionary = {}
var _loaded: bool = false


func is_loaded() -> bool:
	return _loaded


func get_service() -> RefCounted:
	return _service


func get_manager() -> RefCounted:
	return _manager


func scenario_id() -> String:
	return str(_scenario.get("scenario_id", ""))


func episode_seed() -> int:
	return _seed


func rules_fingerprint() -> Dictionary:
	return _rules


## Step1 additive getters (no behavior change): expose map bounds, truth
## version and projector for the shared observation layer.
func map_bounds() -> Dictionary:
	var b: Dictionary = ((_scenario.get("map", {}) as Dictionary).get("bounds", {}) as Dictionary).duplicate(true)
	if not b.has("min_vertical") or not b.has("max_vertical"):
		var min_v: int = 999999
		var max_v: int = -999999
		if not _cell_data.is_empty():
			for key in _cell_data.keys():
				var cell = _cell_data[key]
				var cq: int = int(cell.q)
				var cr: int = int(cell.r)
				var v: int = 2 * cr + cq
				if v < min_v: min_v = v
				if v > max_v: max_v = v
		elif b.has("q_min") and b.has("q_max") and b.has("r_min") and b.has("r_max"):
			var q_min := int(b.get("q_min", -40))
			var q_max := int(b.get("q_max", 40))
			var r_min := int(b.get("r_min", -40))
			var r_max := int(b.get("r_max", 40))
			for q in range(q_min, q_max + 1):
				for r in range(r_min, r_max + 1):
					var v: int = 2 * r + q
					if v < min_v: min_v = v
					if v > max_v: max_v = v
		else:
			min_v = -80
			max_v = 80
		b["min_vertical"] = min_v
		b["max_vertical"] = max_v
	return b


func truth_version() -> int:
	if _truth != null:
		return int((_truth as RefCounted).get_version())
	return -1


func truth_fingerprint() -> String:
	if _truth != null:
		return str((_truth as RefCounted).fingerprint())
	return ""


func get_projector() -> RefCounted:
	return _projector


func get_step6() -> RefCounted:
	return _step6


# ------------------------------------------------------------------
# Scenario load / reset
# ------------------------------------------------------------------

func load_scenario(scn: Dictionary) -> Dictionary:
	_teardown()
	var err := _validate_scenario(scn)
	if err != "":
		return {"ok": false, "error": err}
	_scenario = scn.duplicate(true)
	_seed = int(scn.get("seed", 0))
	_rng.seed = _seed
	_build_map()
	var units_err := _build_authorities()
	if units_err != "":
		_teardown()
		return {"ok": false, "error": units_err}
	_rules = RulesFingerprintCls.compute()
	_refresh_observation("init")
	_action_history = []
	_action_seq = 0
	_initial_fingerprint = fingerprint()
	_initial_snapshot = export_state()
	_loaded = true
	return {
		"ok": true,
		"scenario_id": scenario_id(),
		"scenario_version": str(_scenario.get("scenario_version", "")),
		"seed": _seed,
		"initial_fingerprint": _initial_fingerprint,
		"rules_fingerprint": str(_rules.get("fingerprint", "")),
		"unit_count": (_manager as RefCounted).get_all_units_including_garrisoned().size(),
	}


func reset_episode() -> Dictionary:
	if _scenario.is_empty():
		return {"ok": false, "error": "No scenario loaded."}
	var scn: Dictionary = _scenario.duplicate(true)
	var res := load_scenario(scn)
	if bool(res.get("ok", false)):
		res["restored_initial_fingerprint"] = (_initial_fingerprint == fingerprint())
	return res


func _teardown() -> void:
	if _manager != null and _manager.has_signal("unit_destroyed") and _manager.is_connected("unit_destroyed", _on_unit_destroyed):
		_manager.disconnect("unit_destroyed", _on_unit_destroyed)
	_grid = null
	_cell_data = {}
	_river_cells = {}
	_stronghold_cells = {}
	_manager = null
	_fog = null
	_step6 = null
	_service = null
	_projector = null
	_truth = null
	_blue_svc = null
	_red_svc = null
	if _shim != null and is_instance_valid(_shim):
		if (_shim as Node).is_inside_tree():
			(_shim as Node).queue_free()
		else:
			(_shim as Node).free()
		_shim = null
	_action_history = []
	_action_seq = 0
	_initial_fingerprint = ""
	_initial_snapshot = {}
	_loaded = false


func _validate_scenario(scn: Dictionary) -> String:
	if scn.is_empty():
		return "Scenario is empty."
	if str(scn.get("scenario_id", "")) == "":
		return "scenario_id is required."
	var contract: Dictionary = scn.get("mission_contract", {})
	if not contract.has("primary_objective") or not str(contract.get("primary_objective", "")) in VALID_OBJECTIVES:
		return "mission_contract.primary_objective must be one of %s." % str(VALID_OBJECTIVES)
	if int(contract.get("turn_limit", 0)) <= 0:
		return "mission_contract.turn_limit must be a positive int."
	var forces: Array = scn.get("forces", [])
	if forces.is_empty():
		return "forces must list at least one unit."
	var seen: Dictionary = {}
	var has_blue_hq := false
	var bounds: Dictionary = scn.get("map", {}).get("bounds", {})
	for f in forces:
		if not f is Dictionary:
			return "Each force entry must be a Dictionary."
		var uid: String = str((f as Dictionary).get("id", ""))
		if uid == "" or seen.has(uid):
			return "Force ids must be unique and non-empty."
		seen[uid] = true
		if not str((f as Dictionary).get("class", "")) in VALID_CLASSES:
			return "Force %s has unknown class." % uid
		if not str((f as Dictionary).get("faction", "")) in ["blue", "red"]:
			return "Force %s faction must be blue or red." % uid
		if int((f as Dictionary).get("soldiers", 0)) <= 0:
			return "Force %s needs soldiers > 0." % uid
		if not bounds.is_empty():
			var q: int = int((f as Dictionary).get("q", 0))
			var r: int = int((f as Dictionary).get("r", 0))
			if q < int(bounds.get("q_min", q)) or q > int(bounds.get("q_max", q)) or r < int(bounds.get("r_min", r)) or r > int(bounds.get("r_max", r)):
				return "Force %s is outside map bounds." % uid
		if str((f as Dictionary).get("class", "")) == "hq" and str((f as Dictionary).get("faction", "")) == "blue":
			has_blue_hq = true
	return ""


func _build_map() -> void:
	var map_def: Dictionary = _scenario.get("map", {})
	var bounds: Dictionary = map_def.get("bounds", {"q_min": -30, "q_max": -20, "r_min": -5, "r_max": 5})
	var default_terrain: int = int(map_def.get("default_terrain", 0))
	var overrides: Dictionary = map_def.get("terrain_overrides", {})
	_grid = HexGridCls.new()
	_cell_data = {}
	for q in range(int(bounds.get("q_min", -30)), int(bounds.get("q_max", -20)) + 1):
		for r in range(int(bounds.get("r_min", -5)), int(bounds.get("r_max", 5)) + 1):
			var key := "%d,%d" % [q, r]
			var terrain: int = int(overrides.get(key, default_terrain))
			_cell_data[key] = HexCellCls.new(q, r, terrain)
	(_grid as Node).set("cell_data", _cell_data)
	_river_cells = {}
	for item in map_def.get("river_cells", []):
		if item is Array and (item as Array).size() == 2:
			_river_cells["%d,%d" % [int((item as Array)[0]), int((item as Array)[1])]] = true
	_stronghold_cells = {}
	for h in Step3UnitManagerCls.DEFAULT_FORTRESS_FOOTPRINT:
		_stronghold_cells["%d,%d" % [h.x, h.y]] = true
	for h in Step3UnitManagerCls.DEFAULT_CAPITAL_FOOTPRINT:
		_stronghold_cells["%d,%d" % [h.x, h.y]] = true


func _build_authorities() -> String:
	var renderer_units: Array = []
	for f in (_scenario.get("forces", []) as Array):
		var soldiers: int = int((f as Dictionary).get("soldiers", 100))
		renderer_units.append({
			"id": str((f as Dictionary).get("id", "")),
			"class": str((f as Dictionary).get("class", "infantry")),
			"faction": str((f as Dictionary).get("faction", "blue")),
			"q": int((f as Dictionary).get("q", 0)),
			"r": int((f as Dictionary).get("r", 0)),
			"soldier_count": soldiers,
			"max_count": int((f as Dictionary).get("max_count", soldiers)),
			"form_factor": str((f as Dictionary).get("form_factor", "form_a")),
		})
	_manager = Step3UnitManagerCls.new()
	(_manager as RefCounted).initialize_from_renderer_units(renderer_units)
	_fog = FogCls.new()
	var objectives: Array = []
	objectives.append_array(Step3UnitManagerCls.DEFAULT_FORTRESS_FOOTPRINT)
	objectives.append_array(Step3UnitManagerCls.DEFAULT_CAPITAL_FOOTPRINT)
	(_fog as RefCounted).set_objective_hexes(objectives)
	_step6 = null
	_shim = SimShellShim.new()
	(_shim as Node).set("_river_cells", _river_cells)
	(_shim as Node).set("_stronghold_cells", _stronghold_cells)
	(_shim as Node).set("unit_manager", _manager)
	(_shim as Node).set("hex_grid", _grid)
	(_shim as Node).set("fog", _fog)
	_service = CommandServiceCls.new()
	(_service as RefCounted).configure(_shim, _manager, _grid, map_bounds())
	if (_manager as RefCounted).has_method("set_map_bounds"):
		(_manager as RefCounted).set_map_bounds(map_bounds())
	_projector = ProjectorCls.new()
	(_projector as RefCounted).configure(
		_manager, _fog, _cell_data, null, (_manager as RefCounted).get_all_strongholds())
	(_service as RefCounted).set("projector", _projector)
	_truth = TruthCls.new()
	if not bool((_truth as RefCounted).configure(_shim)):
		return "Step7WorldTruth refused shim configuration."
	_blue_svc = BlueKnowledgeCls.new()
	(_blue_svc as RefCounted).configure(_projector)
	_red_svc = RedKnowledgeCls.new()
	(_red_svc as RefCounted).configure(_projector)
	(_manager as RefCounted).unit_destroyed.connect(_on_unit_destroyed)
	return ""


func _on_unit_destroyed(unit_id: String, _coord: Vector2i) -> void:
	if _step6 != null and unit_id == str((_step6 as RefCounted).get_hq_id()):
		(_step6 as RefCounted).note_hq_destroyed()


# ------------------------------------------------------------------
# Authoritative actions (same paths as production; see file header)
# ------------------------------------------------------------------

## Canonical battle-terminal refusal. Returns {} while the battle is live;
## otherwise a failure dict (success:false + ok:false shapes) carrying code
## BATTLE_ALREADY_TERMINAL and the terminal battle record. Terminal state
## freezes ALL authoritative mutation: no moves, attacks, holds, rests,
## fortifies, or turn advances.
func _terminal_refusal() -> Dictionary:
	if not _loaded:
		return {}
	var b := evaluate_battle()
	if not bool(b.get("terminal", false)):
		return {}
	var w := str(b.get("winner", ""))
	var reason := str(b.get("reason", ""))
	var turn := int(b.get("turn", 0))
	var detail := "Battle already terminal (%s)." % reason
	if w == "blue":
		detail = "Battle already terminal: RED HQ destroyed — BLUE victory (turn %d)." % turn
	elif w == "red":
		detail = "Battle already terminal: BLUE HQ destroyed — RED victory (turn %d)." % turn
	elif reason == "turn_limit_reached_without_decision":
		detail = "Battle already terminal: turn limit reached without decision (turn %d)." % turn
	return {"success": false, "ok": false, "error": detail,
		"code": "BATTLE_ALREADY_TERMINAL", "terminal": b}


func do_move(unit_id: String, q: int, r: int, side: String = "blue", march_mode: String = "auto") -> Dictionary:
	if not _loaded:
		return {"ok": false, "error": "No scenario loaded."}
	var term := _terminal_refusal()
	if not term.is_empty():
		return term
	var dest := Vector2i(q, r)
	var res: Dictionary
	if side == "blue":
		res = (_service as RefCounted).execute_move_intent(unit_id, dest, "blue", march_mode)
	else:
		res = _red_move(unit_id, dest)
	_record("move", {"unit_id": unit_id, "to": [q, r], "side": side, "march_mode": march_mode}, res)
	if bool(res.get("success", false)):
		_refresh_observation("sim_move")
	return res


func _red_move(unit_id: String, dest: Vector2i) -> Dictionary:
	# Production RED AI shape (shell _process_simple_enemy_turn): GREEN_ONLY
	# route from current truth, then UnitManager.execute_move.
	var u: Dictionary = (_manager as RefCounted).get_unit_by_id(unit_id)
	if u.is_empty():
		return {"success": false, "error": "Unit not found"}
	var route: Variant = Step3PathfindingCls.find_route(
		Vector2i(int(u.get("q", 0)), int(u.get("r", 0))), dest,
		str(u.get("class", "infantry")), float(u.get("base_mp", 2.0)),
		float(u.get("remaining_mp", 2.0)), Step3ConfigCls.MarchPolicy.GREEN_ONLY,
		_cell_data, (_manager as RefCounted).get_occupied_dict(),
		_river_cells, "red", _stronghold_cells,
		float(u.get("turn_move_cost_spent", 0.0)),
		float(u.get("blue_limit", 2.0)), float(u.get("red_limit", 4.0)),
		float(u.get("black_limit", 4.4)), map_bounds())
	if route == null or not bool(route.found) or not bool(route.is_valid_destination):
		return {"success": false, "error": str(route.rejection_reason) if route != null else "No legal route."}
	var path: Array[Vector2i] = route.path
	return (_manager as RefCounted).execute_move(unit_id, path, float(route.cost), int(route.march_class), bool(route.crosses_river))


func do_attack(attacker_id: String, defender_id: String, side: String = "blue") -> Dictionary:
	if not _loaded:
		return {"ok": false, "error": "No scenario loaded."}
	var term := _terminal_refusal()
	if not term.is_empty():
		return term
	var mods: Dictionary = (_step6 as RefCounted).attacker_bonus_vs(_manager, attacker_id, defender_id) if _step6 != null else {}
	var res: Dictionary
	if side == "blue":
		res = (_service as RefCounted).execute_attack_intent(attacker_id, defender_id, "blue", mods)
	else:
		res = _red_attack(attacker_id, defender_id, mods)
	_record("attack", {"attacker_id": attacker_id, "defender_id": defender_id, "side": side}, res)
	if bool(res.get("success", false)):
		_after_combat_authority(res, attacker_id, defender_id)
		_refresh_observation("sim_attack")
	return res


func _red_attack(attacker_id: String, defender_id: String, mods: Dictionary) -> Dictionary:
	# Production RED AI shape (shell lines ~2123-2124): modifiers + direct
	# UnitManager.execute_attack. Legality is enforced inside execute_attack.
	var legal := false
	for candidate in (_manager as RefCounted).get_attackable_targets(attacker_id):
		if str(candidate.get("id", "")) == defender_id:
			legal = true
	if not legal:
		return {"success": false, "error": "Target is not a legal attack option."}
	return (_manager as RefCounted).execute_attack(attacker_id, defender_id, mods)


func do_hold(unit_id: String, side: String = "blue") -> Dictionary:
	if not _loaded:
		return {"ok": false, "error": "No scenario loaded."}
	var term := _terminal_refusal()
	if not term.is_empty():
		return term
	var res: Dictionary = (_service as RefCounted).execute_hold_intent(unit_id, side)
	_record("hold", {"unit_id": unit_id, "side": side}, res)
	return res


func do_rest(unit_id: String) -> Dictionary:
	if not _loaded:
		return {"ok": false, "error": "No scenario loaded."}
	var term := _terminal_refusal()
	if not term.is_empty():
		return term
	var res: Dictionary = (_manager as RefCounted).rest_unit(unit_id)
	_record("rest", {"unit_id": unit_id}, res)
	return res


func do_fortify(unit_id: String) -> Dictionary:
	if not _loaded:
		return {"ok": false, "error": "No scenario loaded."}
	var term := _terminal_refusal()
	if not term.is_empty():
		return term
	var res: Dictionary = (_manager as RefCounted).fortify_unit(unit_id)
	_record("fortify", {"unit_id": unit_id}, res)
	return res


func sim_end_turn() -> Dictionary:
	if not _loaded:
		return {"ok": false, "error": "No scenario loaded."}
	var term := _terminal_refusal()
	if not term.is_empty():
		return term
	var prev_turn: int = (_manager as RefCounted).get_current_turn()
	var charges := {}
	var next_turn: int = (_manager as RefCounted).end_turn()
	var vis: Dictionary = (_shim as Node).call("_fog_visible_enemy_id_set")
	var report := {}
	if _step6 != null:
		charges = (_step6 as RefCounted).end_turn_charges(_manager, _cell_data, _stronghold_cells)
		report = (_step6 as RefCounted).begin_player_turn(
			_manager, _cell_data, _river_cells, _stronghold_cells, vis, _fog)
		_apply_rout_fog_notes(report)
	_refresh_observation("turn_begin")
	var res := {
		"ok": true, "previous_turn": prev_turn, "current_turn": next_turn,
		"charges": charges, "begin_turn_report": _sanitize(report),
		"battle_lost": bool((_step6 as RefCounted).is_battle_lost()) if _step6 != null else false,
	}
	_record("end_turn", {}, res)
	return res


func _after_combat_authority(res: Dictionary, atk_id: String, def_id: String) -> void:
	# Mirror of shell _s6_after_combat (authority only) + _fog_mark_engaged.
	for pid in [atk_id, def_id]:
		var pu: Dictionary = (_manager as RefCounted).get_unit_by_id(pid)
		if pu.is_empty():
			continue
		if str(pu.get("faction", "")) == "red":
			var mx: int = maxi(1, int(pu.get("max_count", pu.get("soldier_count", 1))))
			(_fog as RefCounted).mark_combat_engaged(pid, clampf(float(pu.get("soldier_count", 0)) / float(mx), 0.0, 1.0))
	if _step6 != null:
		var out: Dictionary = (_step6 as RefCounted).after_combat(_manager, atk_id, def_id, res)
		_apply_rout_fog_notes(out)
		if bool(out.get("battle_lost", false)):
			pass


func _apply_rout_fog_notes(report: Dictionary) -> void:
	# Mirror of shell rout/rallied handling (authority only): routed BLUE
	# formations lose command (no LOS, hidden position); rallied ones return.
	var turn: int = (_manager as RefCounted).get_current_turn()
	for key in ["routed_new", "routed"]:
		for rid in (report.get(key, []) as Array):
			var ru: Dictionary = (_manager as RefCounted).get_unit_by_id(str(rid))
			if ru.is_empty():
				continue
			if str(ru.get("faction", "")) == "blue":
				(_fog as RefCounted).note_friendly_command_loss(
					str(rid), int(ru.get("q", 0)), int(ru.get("r", 0)),
					str(ru.get("class", "")), turn)
			(_step6 as RefCounted).note_routed_witness(_manager, str(rid))
	for rid in (report.get("rallied", []) as Array):
		(_fog as RefCounted).clear_friendly_command_loss(str(rid))


func refresh_observation() -> void:
	_refresh_observation("external")


func attack_modifiers(attacker_id: String, defender_id: String) -> Dictionary:
	if _step6 == null:
		return {}
	return (_step6 as RefCounted).attacker_bonus_vs(_manager, attacker_id, defender_id)


func _refresh_observation(reason: String) -> void:
	if _manager == null or _fog == null:
		return
	var all_units: Array = (_manager as RefCounted).get_all_units()
	var friendlies: Array = []
	for u in all_units:
		if str(u.get("faction", "")) == "blue":
			friendlies.append(u)
	var turn: int = (_manager as RefCounted).get_current_turn()
	(_fog as RefCounted).recompute(friendlies, all_units, _cell_data, turn)
	if _projector != null:
		(_projector as RefCounted).capture_turn(turn)


func _record(kind: String, request: Dictionary, result: Dictionary) -> void:
	_action_seq += 1
	_action_history.append({
		"seq": _action_seq,
		"action": kind,
		"request": request,
		"turn": (_manager as RefCounted).get_current_turn() if _manager != null else 0,
		"success": bool(result.get("success", result.get("ok", false))),
		"state_version": int((_truth as RefCounted).get_version()) if _truth != null else -1,
	})
	if _truth != null:
		(_truth as RefCounted).notify_mutation("sim_%s" % kind)


# ------------------------------------------------------------------
# Fingerprint / snapshot / knowledge / truth
# ------------------------------------------------------------------

func fingerprint() -> String:
	if _manager == null:
		return "unloaded"
	var parts: Array = ["sim=%s" % SIM_VERSION, "t=%d" % (_manager as RefCounted).get_current_turn()]
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
	for sh in (_manager as RefCounted).get_all_strongholds():
		parts.append("sh:%s:%s:hp%d:br%s:gar%d" % [
			str(sh.structure_id), str(sh.owner),
			int(sh.fortification_hp), str(bool(sh.breached)),
			int(sh.get_garrison_count()),
		])
	return "|".join(parts)


func _sorted_units(include_garrisoned: bool) -> Array:
	var raw: Array = []
	if _manager == null:
		return raw
	if include_garrisoned and (_manager as RefCounted).has_method("get_all_units_including_garrisoned"):
		raw = (_manager as RefCounted).get_all_units_including_garrisoned()
	else:
		raw = (_manager as RefCounted).get_all_units()
	var out: Array = []
	for u in raw:
		if u is Dictionary:
			out.append((u as Dictionary).duplicate(true))
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a.get("id", "")) < str(b.get("id", "")))
	return out


func export_state() -> Dictionary:
	if not _loaded:
		return {"ok": false, "error": "No scenario loaded."}
	return {
		"ok": true,
		"scenario_id": scenario_id(),
		"turn": (_manager as RefCounted).get_current_turn(),
		"units": _sorted_units(true),
		"strongholds": _stronghold_facts(),
		"battle_lost": bool((_step6 as RefCounted).is_battle_lost() if _step6 != null else false),
		"fingerprint": fingerprint(),
	}


func build_knowledge(side: String) -> Dictionary:
	if not _loaded:
		return {"side": side, "error": "No scenario loaded."}
	_refresh_observation("knowledge_build")
	var turn: int = (_manager as RefCounted).get_current_turn()
	var ledger: Dictionary = {}
	if side == "red":
		ledger = (_red_svc as RefCounted).build(turn)
	else:
		ledger = (_blue_svc as RefCounted).build(turn)
	return {
		"side": side,
		"current_turn": turn,
		"scenario_id": scenario_id(),
		"knowledge_projection": KNOWLEDGE_PROJECTION_VERSION,
		"ledger": ledger,
		"objectives": _stronghold_facts(),
	}


func world_truth() -> Dictionary:
	if not _loaded:
		return {"error": "No scenario loaded."}
	return {
		"scenario_id": scenario_id(),
		"turn": (_manager as RefCounted).get_current_turn(),
		"units": _sorted_units(true),
		"strongholds": _stronghold_facts(),
		"central_stockpile": float((_step6 as RefCounted).get_central() if _step6 != null else 0.0),
		"fingerprint": fingerprint(),
	}


func _stronghold_facts() -> Array:
	var out: Array = []
	if _manager == null:
		return out
	var items: Array = (_manager as RefCounted).get_all_strongholds()
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


# ------------------------------------------------------------------
# Mission evaluation + episode result (facts only, no quality score)
# ------------------------------------------------------------------

## Authoritative battle outcome (BATTLE_TERMINAL_CONTRACT_V0).
## HQ-terminal rule (symmetric, universal across objectives):
##   - a side that fielded an HQ at scenario start and has no living HQ now
##     ends the battle immediately: BLUE HQ dead -> RED wins, RED HQ dead ->
##     BLUE wins. Start-awareness keeps HQ-less skirmish scenarios live.
## Evaluation order (defeat-first convention preserved; simultaneous HQ loss
## therefore resolves to a RED win):
##   1. battle_lost / BLUE HQ dead / BLUE annihilated -> defeat
##   2. RED HQ dead -> victory (reason red_hq_destroyed, all objectives)
##   3. per-objective victory (unchanged annihilation/capital/survival rules)
##   4. turn limit passed with no decision -> expired (no-verdict terminal)
func _side_hq_at_start(faction: String) -> bool:
	for f in (_scenario.get("forces", []) as Array):
		if f is Dictionary and str((f as Dictionary).get("class", "")) == "hq" \
				and str((f as Dictionary).get("faction", "")) == faction:
			return true
	return false


## Canonical battle projection over evaluate_mission. THE single battle-truth
## entry: terminal/winner/loser/reason/turn. Winner/loser use sim-native
## lowercase faction ids ("blue"/"red"); expired is terminal with no winner.
func evaluate_battle() -> Dictionary:
	var m := evaluate_mission()
	var status := str(m.get("mission_status", "ongoing"))
	var winner := ""
	var loser := ""
	if status == "victory":
		winner = "blue"
		loser = "red"
	elif status == "defeat":
		winner = "red"
		loser = "blue"
	return {"terminal": status != "ongoing", "winner": winner, "loser": loser,
		"reason": str(m.get("termination_reason", "")), "turn": int(m.get("turns_elapsed", 0)),
		"mission_status": status, "hq_state": str(m.get("hq_state", "")),
		"red_hq_state": str(m.get("red_hq_state", ""))}


func evaluate_mission() -> Dictionary:
	if not _loaded:
		return {"mission_status": "error", "error": "No scenario loaded."}
	var contract: Dictionary = _scenario.get("mission_contract", {})
	var objective: String = str(contract.get("primary_objective", ""))
	var turn_limit: int = int(contract.get("turn_limit", 0))
	var turn: int = (_manager as RefCounted).get_current_turn()
	var blue: Array = []
	var red: Array = []
	var blue_start_sol := 0
	for f in (_scenario.get("forces", []) as Array):
		if str((f as Dictionary).get("faction", "")) == "blue":
			blue_start_sol += int((f as Dictionary).get("soldiers", 0))
	for u in _sorted_units(true):
		if str(u.get("faction", "")) == "blue":
			blue.append(u)
		elif str(u.get("faction", "")) == "red":
			red.append(u)
	var blue_alive: Array = blue.filter(func(u: Dictionary) -> bool: return int(u.get("soldier_count", 0)) > 0)
	var red_alive: Array = red.filter(func(u: Dictionary) -> bool: return int(u.get("soldier_count", 0)) > 0)
	var blue_sol := 0
	var blue_morale := 0.0
	var hq_alive := false
	var hq_state := "missing"
	for u in blue_alive:
		blue_sol += int(u.get("soldier_count", 0))
		blue_morale += float(u.get("morale", 0.0))
		if str(u.get("class", "")) == "hq":
			hq_alive = true
			hq_state = "routed" if bool(u.get("routed", false)) else "active"
	var red_sol := 0
	var red_hq_alive := false
	var red_hq_state := "missing"
	for u in red_alive:
		red_sol += int(u.get("soldier_count", 0))
		if str(u.get("class", "")) == "hq":
			red_hq_alive = true
			red_hq_state = "routed" if bool(u.get("routed", false)) else "active"
	var blue_hq_required := _side_hq_at_start("blue")
	var red_hq_required := _side_hq_at_start("red")
	var blue_hq_dead: bool = blue_hq_required and not hq_alive
	var red_hq_dead: bool = red_hq_required and not red_hq_alive
	var battle_lost: bool = bool((_step6 as RefCounted).is_battle_lost()) if _step6 != null else false
	var capital := {}
	for sh in _stronghold_facts():
		if str((sh as Dictionary).get("structure_id", "")).begins_with("Capital"):
			capital = sh
	var status := "ongoing"
	var reason := "objective_incomplete"
	if battle_lost or blue_hq_dead or blue_alive.is_empty():
		status = "defeat"
		reason = "hq_destroyed" if (battle_lost or blue_hq_dead) else "blue_annihilated"
	elif red_hq_dead:
		status = "victory"
		reason = "red_hq_destroyed"
	else:
		match objective:
			"destroy_all_red":
				if red_alive.is_empty():
					status = "victory"
					reason = "all_red_destroyed"
			"capture_capital":
				if not capital.is_empty() and (bool(capital.get("breached", false)) or str(capital.get("owner", "")) == "blue"):
					status = "victory"
					reason = "capital_taken"
			"survive_turns", "hold_hq":
				if turn > turn_limit and hq_alive:
					status = "victory"
					reason = "turn_limit_survived"
	if status == "ongoing" and turn > turn_limit:
		status = "expired"
		reason = "turn_limit_reached_without_decision"
	return {
		"mission_status": status,
		"termination_reason": reason,
		"primary_objective": objective,
		"turn_limit": turn_limit,
		"turns_elapsed": turn,
		"blue_formations_alive": blue_alive.size(),
		"blue_soldiers_alive": blue_sol,
		"blue_soldiers_start": blue_start_sol,
		"blue_soldiers_lost": maxi(0, blue_start_sol - blue_sol),
		"red_formations_alive": red_alive.size(),
		"red_soldiers_alive": red_sol,
		"blue_average_morale": blue_morale / float(maxi(1, blue_alive.size())),
		"hq_state": hq_state,
		"red_hq_state": red_hq_state,
		"blue_hq_at_start": blue_hq_required,
		"red_hq_at_start": red_hq_required,
		"capital": capital,
		"objectives": _stronghold_facts(),
	}


func finish_episode(knowledge_side: String = "blue") -> Dictionary:
	var mission := evaluate_mission()
	var knowledge := build_knowledge(knowledge_side)
	var ledger: Dictionary = knowledge.get("ledger", {})
	var observed := 0
	if ledger.has("current_enemy_observations"):
		observed = (ledger.get("current_enemy_observations", []) as Array).size()
	elif ledger.has("observed_blue_forces"):
		observed = (ledger.get("observed_blue_forces", []) as Array).size()
	return {
		"sim_version": SIM_VERSION,
		"scenario_id": scenario_id(),
		"scenario_version": str(_scenario.get("scenario_version", "")),
		"mission_contract": (_scenario.get("mission_contract", {}) as Dictionary).duplicate(true),
		"seed": _seed,
		"rules_fingerprint": str(_rules.get("fingerprint", "")),
		"rules_source_tables": (_rules.get("source_tables", []) as Array).duplicate(),
		"knowledge_projection": KNOWLEDGE_PROJECTION_VERSION,
		"knowledge_side": knowledge_side,
		"mission": mission,
		"observed_information_count": observed,
		"final_fingerprint": fingerprint(),
		"initial_fingerprint": _initial_fingerprint,
		"actions_executed": _action_history.size(),
		"action_history": _action_history.duplicate(true),
		"truth_fingerprint": str((_truth as RefCounted).fingerprint()) if _truth != null else "",
		"world_state_version": int((_truth as RefCounted).get_version()) if _truth != null else -1,
	}


# ------------------------------------------------------------------
# JSON-safe sanitizer for machine-readable artifacts
# ------------------------------------------------------------------

static func _sanitize(value: Variant) -> Variant:
	if value is Vector2i:
		var v: Vector2i = value
		return [v.x, v.y]
	if value is Vector2:
		var w: Vector2 = value
		return [w.x, w.y]
	if value is Color:
		var c: Color = value
		return [c.r, c.g, c.b, c.a]
	if value is Dictionary:
		var out: Dictionary = {}
		for k in (value as Dictionary).keys():
			out[str(k)] = _sanitize((value as Dictionary)[k])
		return out
	if value is Array:
		var cells: Array = []
		for item in (value as Array):
			cells.append(_sanitize(item))
		return cells
	if value is Object:
		return str(value)
	return value


static func default_test_bounds() -> Dictionary:
	return {"q_min": -30, "q_max": -20, "r_min": -5, "r_max": 5}
