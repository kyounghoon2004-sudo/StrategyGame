extends SceneTree
func _init() -> void:
	var shell: Node = (load("res://scenes/step2r_battlefield_shell.tscn") as PackedScene).instantiate()
	shell.set("battlefield_id", "EDITOR_M1")
	root.add_child(shell)
	for i in 150:
		await process_frame
	await create_timer(4.0).timeout
	var um = shell.get("unit_manager")
	var V2 = load("res://scripts/rules_v2/rules_v2.gd")
	var cells: Dictionary = shell.get("hex_grid").get("cell_data")
	print("[R] known ", V2.known.size(), " on ", V2.known_on)
	for id in um._units.keys():
		var u: Dictionary = um._units[id]
		if str(u["faction"]) != "blue":
			continue
		um.call("select_unit", id)
		await process_frame
		var env = shell.get("_current_envelope")
		if env == null:
			continue
		for c in env.reachable_data:
			var k := "%d,%d" % [c.x, c.y]
			if int(cells[k].terrain) == 7:
				print("[R] ", id, " can stand on river ", c, " known ", V2.known.has(k))
		um.call("deselect")
	print("[R] done")
	quit(0)
