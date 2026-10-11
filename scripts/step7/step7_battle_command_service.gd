class_name Step7BattleCommandService
extends RefCounted

## The single authoritative command seam for humans and agents.
## Semantic adapters may propose intents, but this service is the only Step 7
## entry point that calls the existing UnitManager/pathfinding/combat rules.
## It never mutates a renderer and never accepts raw model-authored paths as
## authoritative: a legal route is recomputed from the current state.

const HexUtilsScript = preload("res://scripts/core/hex_utils.gd")
const Step3ConfigScript = preload("res://scripts/core/step3_config.gd")
const Step3PathfindingScript = preload("res://scripts/step3/step3_pathfinding.gd")

var projector: RefCounted
var _shell: Node
var _unit_manager: RefCounted
var _hex_grid: Node
var _map_bounds: Dictionary = {}

func configure(shell_ref: Node, manager_ref: RefCounted, grid_ref: Node, map_bounds: Dictionary = {}) -> void:
	_shell = shell_ref
	_unit_manager = manager_ref
	_hex_grid = grid_ref
	_map_bounds = map_bounds.duplicate(true) if not map_bounds.is_empty() else {}

func is_ready() -> bool:
	return _shell != null and _unit_manager != null and _hex_grid != null

func get_unit(unit_id: String) -> Dictionary:
	if _unit_manager == null or not _unit_manager.has_method("get_unit_by_id"):
		return {}
	return _unit_manager.get_unit_by_id(unit_id)

func preview_move_route(unit_id: String, destination: Vector2i, side: String = "blue", march_mode: String = "auto") -> Variant:
	var unit := get_unit(unit_id)
	if unit.is_empty() or bool(unit.get("action_ended", false)) or bool(unit.get("garrisoned", false)):
		return null
	if str(unit.get("faction", "")) != side:
		return null
	var cell_data: Dictionary = _hex_grid.get("cell_data") as Dictionary if _hex_grid else {}
	var occupied := _occupied_for(side)
	var policy := _policy_for(side, march_mode)
	var base_mp := float(unit.get("base_mp", 2.0))
	var remaining_mp := float(unit.get("remaining_mp", base_mp))
	var spent := float(unit.get("turn_move_cost_spent", 0.0))
	var blue_limit := float(unit.get("blue_limit", Step3ConfigScript.get_blue_limit(base_mp)))
	var red_limit := float(unit.get("red_limit", Step3ConfigScript.get_red_limit(base_mp)))
	var black_limit := float(unit.get("black_limit", Step3ConfigScript.get_black_limit(base_mp)))
	return Step3PathfindingScript.find_route(
		Vector2i(int(unit.get("q", 0)), int(unit.get("r", 0))),
		destination,
		str(unit.get("class", "infantry")),
		base_mp,
		remaining_mp,
		policy,
		cell_data,
		occupied,
		_river_cells(),
		side,
		_stronghold_cells(),
		spent,
		blue_limit,
		red_limit,
		black_limit,
		_map_bounds
	)

func preview_move(unit_id: String, destination: Vector2i, side: String = "blue", march_mode: String = "auto") -> Dictionary:
	var route: Variant = preview_move_route(unit_id, destination, side, march_mode)
	return _route_to_dict(route)

func reachable_area(unit_id: String, side: String = "blue", march_mode: String = "auto") -> Dictionary:
	var unit := get_unit(unit_id)
	if unit.is_empty() or str(unit.get("faction", "")) != side:
		return {"ok": false, "error": "Formation is not available to this side."}
	if bool(unit.get("action_ended", false)) or bool(unit.get("garrisoned", false)):
		return {"ok": false, "error": "Formation cannot move now."}
	var cell_data: Dictionary = _hex_grid.get("cell_data") as Dictionary if _hex_grid else {}
	var base_mp := float(unit.get("base_mp", 2.0))
	var env: Variant = Step3PathfindingScript.calculate_envelope(
		Vector2i(int(unit.get("q", 0)), int(unit.get("r", 0))),
		str(unit.get("class", "infantry")),
		base_mp,
		float(unit.get("remaining_mp", base_mp)),
		_policy_for(side, march_mode),
		cell_data,
		_occupied_for(side),
		_river_cells(),
		side,
		_stronghold_cells(),
		float(unit.get("turn_move_cost_spent", 0.0)),
		float(unit.get("blue_limit", Step3ConfigScript.get_blue_limit(base_mp))),
		float(unit.get("red_limit", Step3ConfigScript.get_red_limit(base_mp))),
		float(unit.get("black_limit", Step3ConfigScript.get_black_limit(base_mp))),
		_map_bounds
	)
	if env == null:
		return {"ok": false, "error": "No reachable area is available."}
	var entries: Array = []
	for value in env.reachable_data.values():
		if not value is Dictionary:
			continue
		var row: Dictionary = value as Dictionary
		var coord: Vector2i = row.get("coord", Vector2i.ZERO)
		entries.append({
			"q": coord.x,
			"r": coord.y,
			"cost": float(row.get("cost", 0.0)),
			"march_class": int(row.get("march_class", Step3ConfigScript.MarchClass.GREEN)),
			"crosses_river": bool(row.get("crosses_river", false))
		})
	entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if float(a.get("cost", 0.0)) == float(b.get("cost", 0.0)):
			return "%d,%d" % [int(a.get("q", 0)), int(a.get("r", 0))] < "%d,%d" % [int(b.get("q", 0)), int(b.get("r", 0))]
		return float(a.get("cost", 0.0)) < float(b.get("cost", 0.0))
	)
	return {"ok": true, "unit_id": unit_id, "origin": [int(unit.get("q", 0)), int(unit.get("r", 0))], "reachable": entries.slice(0, 96)}

func preview_attack(attacker_id: String, defender_id: String, side: String = "blue") -> Dictionary:
	var attacker := get_unit(attacker_id)
	var defender := get_unit(defender_id)
	if attacker.is_empty() or defender.is_empty():
		return {"ok": false, "error": "Formation not found."}
	if str(attacker.get("faction", "")) != side:
		return {"ok": false, "error": "Attacker is not controlled by this side."}
	if projector and not projector.is_contact_visible(side, defender_id):
		return {"ok": false, "error": "Target is not currently observed."}
	if side == "blue" and _shell and _shell.has_method("_fog_is_enemy_visible") and not bool(_shell.call("_fog_is_enemy_visible", defender_id)):
		return {"ok": false, "error": "Target is not currently observed."}
	var legal := false
	for candidate in _unit_manager.get_attackable_targets(attacker_id):
		if str(candidate.get("id", "")) == defender_id:
			legal = true
	if not legal or bool(attacker.get("routed", false)):
		return {"ok": false, "error": "Target is not a legal attack option."}
	if not _unit_manager.has_method("preview_attack"):
		return {"ok": false, "error": "Attack preview is unavailable."}
	var result: Dictionary = _unit_manager.preview_attack(attacker_id, defender_id)
	result["ok"] = not result.is_empty() and not result.has("error")
	return result

## Human GUI movement and Step7 movement both enter here. The shell remains
## responsible for animation and fog presentation; UnitManager remains state
## authority.
func execute_player_move_path(unit_id: String, path: Array[Vector2i]) -> Dictionary:
	if _unit_manager == null or not _unit_manager.has_method("execute_player_stepwise_move"):
		return {"success": false, "error": "Authoritative move service unavailable."}
	var unit := get_unit(unit_id)
	if unit.is_empty() or str(unit.get("faction", "")) != "blue":
		return {"success": false, "error": "Blue formation not found."}
	var visible_ids: Dictionary = {}
	if _shell and _shell.has_method("_fog_visible_enemy_id_set"):
		visible_ids = _shell.call("_fog_visible_enemy_id_set") as Dictionary
	var cell_data: Dictionary = _hex_grid.get("cell_data") as Dictionary if _hex_grid else {}
	return _unit_manager.execute_player_stepwise_move(unit_id, path, visible_ids, cell_data, _river_cells())

## BATTLE_TERMINAL_CONTRACT_V0: the live shell reports battle-over; the sim
## shim has no such method (SimController guards the sim path instead).
func _live_battle_over() -> bool:
	return _shell != null and _shell.has_method("_battle_over") and bool(_shell.call("_battle_over"))


func _live_terminal_refusal() -> Dictionary:
	return {"success": false, "error": "Battle already terminal.",
		"code": "BATTLE_ALREADY_TERMINAL"}


func execute_move_intent(unit_id: String, destination: Vector2i, side: String = "red", march_mode: String = "green") -> Dictionary:
	if _live_battle_over():
		return _live_terminal_refusal()
	var route: Variant = preview_move_route(unit_id, destination, side, march_mode)
	if route == null or not bool(route.found) or not bool(route.is_valid_destination):
		return {"success": false, "error": str(route.rejection_reason) if route != null else "No legal route.", "route": _route_to_dict(route)}
	var path: Array[Vector2i] = route.path
	if side == "blue":
		return execute_player_move_path(unit_id, path)
	if _unit_manager == null or not _unit_manager.has_method("execute_move"):
		return {"success": false, "error": "Authoritative move service unavailable."}
	var result: Dictionary = _unit_manager.execute_move(unit_id, path, float(route.cost), int(route.march_class), bool(route.crosses_river))
	result["route"] = _route_to_dict(route)
	return result

func execute_attack_intent(attacker_id: String, defender_id: String, side: String = "red", modifiers: Dictionary = {}) -> Dictionary:
	if _live_battle_over():
		return _live_terminal_refusal()
	var preview := preview_attack(attacker_id, defender_id, side)
	if not bool(preview.get("ok", false)):
		return preview
	if _unit_manager == null or not _unit_manager.has_method("execute_attack"):
		return {"success": false, "error": "Authoritative combat service unavailable."}
	return _unit_manager.execute_attack(attacker_id, defender_id, modifiers)

func propose_move(unit_id: String, destination_or_region: Variant, side: String = "blue", march_mode: String = "auto") -> Dictionary:
	var unit := get_unit(unit_id)
	if unit.is_empty() or str(unit.get("faction", "")) != side:
		return {"ok": false, "error": "Formation is not available to this side."}
	var destination := _resolve_destination(unit_id, destination_or_region, side, march_mode)
	if destination.x == -999:
		return {"ok": false, "error": "No legal destination was found in that region."}
	var preview := preview_move(unit_id, destination, side, march_mode)
	if not bool(preview.get("legal", false)):
		return {"ok": false, "error": str(preview.get("rejection_reason", "Destination is not reachable.")), "preview": preview}
	return {
		"ok": true,
		"proposal_type": "move",
		"unit_id": unit_id,
		"side": side,
		"destination": [destination.x, destination.y],
		"march_mode": march_mode,
		"preview": preview,
		"requires_approval": side == "blue"
	}

func propose_attack(attacker_id: String, defender_id: String, side: String = "blue") -> Dictionary:
	var preview := preview_attack(attacker_id, defender_id, side)
	if not bool(preview.get("ok", false)):
		return preview
	return {"ok": true, "proposal_type": "attack", "attacker_id": attacker_id, "defender_id": defender_id, "side": side, "preview": preview, "requires_approval": side == "blue"}

func propose_noncombat(kind: String, unit_id: String, side: String, extra: Dictionary = {}) -> Dictionary:
	var unit := get_unit(unit_id)
	if unit.is_empty() or str(unit.get("faction", "")) != side:
		return {"ok": false, "error": "Formation is not available to this side."}
	var proposal := {"ok": true, "proposal_type": kind, "unit_id": unit_id, "side": side, "requires_approval": side == "blue"}
	for key in extra.keys():
		proposal[key] = extra[key]
	return proposal

func _resolve_destination(unit_id: String, value: Variant, side: String, march_mode: String) -> Vector2i:
	if value is Array and (value as Array).size() >= 2 and _is_number((value as Array)[0]) and _is_number((value as Array)[1]):
		return Vector2i(int((value as Array)[0]), int((value as Array)[1]))
	var region := str(value).to_lower()
	var area := reachable_area(unit_id, side, march_mode)
	if not bool(area.get("ok", false)):
		return Vector2i(-999, -999)
	var candidates: Array = area.get("reachable", []) as Array
	if candidates.is_empty():
		return Vector2i(-999, -999)
	var selected: Dictionary = candidates[0] as Dictionary
	for candidate_value in candidates:
		if not candidate_value is Dictionary:
			continue
		var candidate: Dictionary = candidate_value as Dictionary
		var better := false
		if region.contains("south") or region.contains("남"):
			better = int(candidate.get("r", 0)) > int(selected.get("r", 0)) or (int(candidate.get("r", 0)) == int(selected.get("r", 0)) and int(candidate.get("q", 0)) < int(selected.get("q", 0)))
		elif region.contains("north") or region.contains("북"):
			better = int(candidate.get("r", 0)) < int(selected.get("r", 0)) or (int(candidate.get("r", 0)) == int(selected.get("r", 0)) and int(candidate.get("q", 0)) < int(selected.get("q", 0)))
		elif region.contains("east") or region.contains("동"):
			better = int(candidate.get("q", 0)) > int(selected.get("q", 0))
		elif region.contains("west") or region.contains("서"):
			better = int(candidate.get("q", 0)) < int(selected.get("q", 0))
		elif region.contains("hq") or region.contains("본진"):
			better = HexUtilsScript.hex_distance_axial(Vector2i(int(candidate.get("q", 0)), int(candidate.get("r", 0))), Vector2i(-12, 2)) < HexUtilsScript.hex_distance_axial(Vector2i(int(selected.get("q", 0)), int(selected.get("r", 0))), Vector2i(-12, 2))
		else:
			better = float(candidate.get("cost", 0.0)) < float(selected.get("cost", 0.0))
		if better:
			selected = candidate
	return Vector2i(int(selected.get("q", -999)), int(selected.get("r", -999)))

func _route_to_dict(route: Variant) -> Dictionary:
	if route == null:
		return {"legal": false, "rejection_reason": "No route result."}
	var path_cells: Array = []
	for coord in route.path:
		path_cells.append([coord.x, coord.y])
	return {
		"ok": bool(route.found) and bool(route.is_valid_destination),
		"legal": bool(route.found) and bool(route.is_valid_destination),
		"origin": [route.origin.x, route.origin.y],
		"destination": [route.destination.x, route.destination.y],
		"path_cells": path_cells,
		"cost": float(route.cost),
		"march_class": int(route.march_class),
		"crosses_river": bool(route.crosses_river),
		"food_cost": float(route.food_cost),
		"morale_penalty": float(route.morale_penalty),
		"rejection_reason": str(route.rejection_reason)
	}

func _occupied_for(side: String) -> Dictionary:
	if side == "red" and projector:
		return projector.known_occupancy(side)
	if side == "blue" and _shell and _shell.has_method("_player_known_occupied"):
		return _shell.call("_player_known_occupied") as Dictionary
	if _unit_manager and _unit_manager.has_method("get_occupied_dict"):
		return _unit_manager.get_occupied_dict()
	return {}

func _policy_for(side: String, march_mode: String) -> int:
	if side == "blue" and _unit_manager and _unit_manager.has_method("get_policy") and march_mode == "auto":
		return int(_unit_manager.get_policy())
	if march_mode.to_lower() == "red" or march_mode.to_lower() == "red_allowed":
		return Step3ConfigScript.MarchPolicy.RED_ALLOWED
	if march_mode.to_lower() == "black" or march_mode.to_lower() == "black_allowed":
		return Step3ConfigScript.MarchPolicy.RED_ALLOWED
	return Step3ConfigScript.MarchPolicy.GREEN_ONLY

func _river_cells() -> Dictionary:
	return _shell.get("_river_cells") as Dictionary if _shell else {}

func _stronghold_cells() -> Dictionary:
	return _shell.get("_stronghold_cells") as Dictionary if _shell else {}

func _is_number(value: Variant) -> bool:
	if value is int or value is float:
		return true
	if value is String:
		return (value as String).is_valid_int() or (value as String).is_valid_float()
	return false

func execute_hold_intent(unit_id: String, side: String) -> Dictionary:
	if _live_battle_over():
		return _live_terminal_refusal()
	var unit := get_unit(unit_id)
	if unit.is_empty() or str(unit.get("faction", "")) != side or bool(unit.get("action_ended", false)):
		return {"success": false, "error": "Formation cannot hold now."}
	return _unit_manager.wait_unit(unit_id)
