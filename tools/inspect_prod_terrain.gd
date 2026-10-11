extends SceneTree

var _shell: Node = null
var _done := false

func _initialize() -> void:
	var shell_scn: PackedScene = load("res://scenes/step2r_battlefield_shell.tscn")
	_shell = shell_scn.instantiate()
	root.add_child(_shell)

func _process(_delta: float) -> bool:
	if _done:
		return false
	var hg: Node = _shell.get_node_or_null("HexGrid")
	if hg == null:
		return false
	var cells: Dictionary = hg.get("cell_data")
	if cells.is_empty():
		return false
	
	_done = true
	var river_cells: Dictionary = _shell.get("_river_cells")
	var stronghold_cells: Dictionary = _shell.get("_stronghold_cells")
	var stronghold_specs: Array = _shell.call("stronghold_visual_specs")

	var terrain_summary: Dictionary = {}
	for k in cells.keys():
		var c = cells[k]
		var t = int(c.terrain)
		terrain_summary[t] = int(terrain_summary.get(t, 0)) + 1

	print("--- PRODUCTION BATTLEFIELD MAP AUDIT ---")
	print("TOTAL_CELLS: ", cells.size())
	print("TERRAIN_SUMMARY: ", JSON.stringify(terrain_summary))
	print("RIVER_CELLS: ", river_cells.size())
	print("STRONGHOLD_CELLS: ", stronghold_cells.size())
	print("STRONGHOLD_SPECS: ", JSON.stringify(stronghold_specs))

	_shell.queue_free()
	quit(0)
	return true
