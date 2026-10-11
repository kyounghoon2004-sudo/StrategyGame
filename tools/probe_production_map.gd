extends SceneTree

func _init() -> void:
	print("--- PROBING PRODUCTION BATTLEFIELD MAP ---")
	
	# Probe 1: Step2RBattlefieldShell
	var shell_scn: PackedScene = load("res://scenes/step2r_battlefield_shell.tscn")
	if shell_scn != null:
		var shell: Node = shell_scn.instantiate()
		root.add_child(shell)
		var hg: Node = shell.get_node_or_null("HexGrid")
		if hg != null:
			var cells: Dictionary = hg.get("cell_data")
			print("[Step2R] cell_data count = ", cells.size())
			var terrain_counts: Dictionary = {}
			for c in cells.values():
				var t: int = int(c.terrain)
				terrain_counts[t] = terrain_counts.get(t, 0) + 1
			print("[Step2R] terrain counts: ", terrain_counts)
			print("[Step2R] river cells count: ", shell.get("_river_cells").size())
			print("[Step2R] stronghold specs: ", shell.call("stronghold_visual_specs"))
		shell.queue_free()

	# Probe 2: BattleMap (legacy / campaign)
	var battle_scn: PackedScene = load("res://scenes/battle_map.tscn")
	if battle_scn != null:
		var bm: Node = battle_scn.instantiate()
		root.add_child(bm)
		var hg2: Node = bm.get_node_or_null("HexGrid")
		if hg2 != null:
			var cells2: Dictionary = hg2.get("cell_data")
			print("[BattleMap] cell_data count = ", cells2.size())
			var terrain_counts2: Dictionary = {}
			for c in cells2.values():
				var t: int = int(c.terrain)
				terrain_counts2[t] = terrain_counts2.get(t, 0) + 1
			print("[BattleMap] terrain counts: ", terrain_counts2)
		bm.queue_free()

	quit(0)
