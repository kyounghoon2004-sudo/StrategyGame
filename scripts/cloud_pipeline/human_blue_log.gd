extends Node
## Human BLUE (2026-10-11, WATCH_BLUE_MODE=HUMAN): the Brain's "history" reads the opponent's action_log, so the
## human's moves and attacks are logged here in the controllers' own format (turn, side, unit, do, from/to, target,
## dealt/took, destroyed). Fog is off in the play mode, so every action is seen by the foe.

var action_log: Array = []
var _um: Object = null


func setup(unit_manager: Object) -> void:
	_um = unit_manager
	unit_manager.connect("unit_moved", _on_moved)
	unit_manager.connect("combat_resolved", _on_combat)


func _on_moved(unit_id: String, from_coord: Vector2i, to_coord: Vector2i, _march_class: int) -> void:
	if not unit_id.begins_with("B_"):
		return
	action_log.append({"turn": int(_um.call("get_current_turn")), "side": "BLUE", "unit": unit_id, "do": "MOVE",
		"from": [from_coord.x, from_coord.y], "to": [to_coord.x, to_coord.y], "seen_by_foe": true})


func _on_combat(res: Dictionary) -> void:
	if str(res.get("attacker_faction", "")) != "blue":
		return
	action_log.append({"turn": int(res.get("turn", 0)), "side": "BLUE", "unit": str(res.get("attacker_id", "")),
		"do": "ATTACK", "seen_by_foe": true, "target": str(res.get("defender_id", "")),
		"dealt": int(res.get("defender_casualties", 0)), "took": int(res.get("attacker_casualties", 0)),
		"fieldworks": int(res.get("field_fortification_damage", 0)),
		"destroyed": bool(res.get("defender_destroyed", false)),
		"attacker_destroyed": bool(res.get("attacker_destroyed", false))})
