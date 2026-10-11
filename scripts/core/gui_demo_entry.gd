## gui_demo_entry.gd — deterministic visual capture entry
## Loads the production BattleMap scene and keeps it open for CUA inspection.
extends SceneTree

var _map: Node
var _frames: int = 0
var _prepared: bool = false

func _initialize() -> void:
	var scene: PackedScene = load("res://scenes/battle_map.tscn") as PackedScene
	if scene == null:
		push_error("[GuiDemo] battle_map.tscn 로드 실패")
		return
	_map = scene.instantiate()
	root.add_child(_map)
	print("[GuiDemo] BattleMap visual demo ready")

func _process(_delta: float) -> bool:
	_frames += 1
	if not _prepared and _frames >= 12 and _map != null and is_instance_valid(_map):
		_prepared = true
		if _map.has_method("_enter_deploy_phase"):
			_map.call("_enter_deploy_phase")
		var units: Array = _map.get("player_units") as Array
		if not units.is_empty():
			var unit: Variant = units[0]
			var unit_hex: Vector2i = Vector2i(int(unit.get("hex_q")), int(unit.get("hex_r")))
			if _map.has_method("_select_unit"):
				_map.call("_select_unit", unit, unit_hex)
	if _prepared and _map != null and is_instance_valid(_map):
		var interview: Node = _map.get("interview_panel") as Node
		if interview != null and interview.visible and interview.has_method("hide_interview"):
			interview.call("hide_interview")
	return false
