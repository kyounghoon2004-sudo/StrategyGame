extends SceneTree
## Capture: a unit standing in a forest hex stays readable (the trees of its hex sink).
func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var out := args[0] if args.size() > 0 else "user://"
	var shell: Node = (load("res://scenes/step2r_battlefield_shell.tscn") as PackedScene).instantiate()
	shell.set("battlefield_id", "EDITOR_M1")
	shell.set("no_fog", true)
	root.add_child(shell)
	for i in 150:
		await process_frame
	var um = shell.get("unit_manager")
	var view = shell.get("_view3d")
	var cells: Dictionary = shell.get("hex_grid").get("cell_data")
	var id := "B_SCOUT_1"
	var u: Dictionary = um._units[id]
	var forest := Vector2i(-999, -999)
	var best := 1 << 30
	for k in cells.keys():
		if int(cells[k].terrain) == 2:
			var p: PackedStringArray = k.split(",")
			var h := Vector2i(int(p[0]), int(p[1]))
			var d: int = max(abs(h.x - int(u["q"])), abs(h.y - int(u["r"])), abs(h.x + h.y - int(u["q"]) - int(u["r"])))
			if d < best and not um._occupied_map.has(k):
				best = d
				forest = h
	um._occupied_map.erase("%d,%d" % [int(u["q"]), int(u["r"])])
	u["q"] = forest.x
	u["r"] = forest.y
	um._occupied_map["%d,%d" % [forest.x, forest.y]] = id
	shell.get("unit_renderer").call("update_unit_position", id, forest.x, forest.y)
	await create_timer(6.0).timeout
	var HexU = load("res://scripts/core/hex_utils.gd")
	shell.get("camera").call("focus_on", HexU.hex_to_pixel(forest.x, forest.y), true)
	await create_timer(2.0).timeout
	var sq := 0
	for key in view._tree_index:
		for e in view._tree_index[key]:
			if float(e["cur"]) < 0.99:
				sq += 1
	print("[F] forest hex ", forest, " tree props squashed ", sq, " total hexes ", view._tree_index.size())
	root.get_viewport().get_texture().get_image().save_png(out.path_join("forest_unit.png"))
	quit(0)
