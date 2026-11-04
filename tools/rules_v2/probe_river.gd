extends SceneTree
func _init() -> void:
	var shell: Node = (load("res://scenes/step2r_battlefield_shell.tscn") as PackedScene).instantiate()
	shell.set("battlefield_id", "EDITOR_M1")
	root.add_child(shell)
	for i in 120:
		await process_frame
	var um = shell.get("unit_manager")
	var V2 = load("res://scripts/rules_v2/rules_v2.gd")
	var cells: Dictionary = shell.get("hex_grid").get("cell_data")
	var neb := [Vector2i(1, 0), Vector2i(1, -1), Vector2i(0, -1), Vector2i(-1, 0), Vector2i(-1, 1), Vector2i(0, 1)]
	var id := "B_CONS_2"
	var u: Dictionary = um._units[id]
	var pick := Vector2i(-999, -999)
	for k in cells.keys():
		if int(cells[k].terrain) != 7:
			continue
		var p: PackedStringArray = k.split(",")
		var w := Vector2i(int(p[0]), int(p[1]))
		for d in neb:
			var a: Vector2i = w + d
			var ka := "%d,%d" % [a.x, a.y]
			if cells.has(ka) and int(cells[ka].terrain) == 0 and not um._occupied_map.has(ka):
				pick = a
				break
		if pick.x != -999:
			break
	um._occupied_map.erase("%d,%d" % [int(u["q"]), int(u["r"])])
	u["q"] = pick.x
	u["r"] = pick.y
	u["remaining_mp"] = float(u["base_mp"])
	u["turn_move_cost_spent"] = 0.0
	um._occupied_map["%d,%d" % [pick.x, pick.y]] = id
	print("[R] V2 ", V2.enabled, " known_on ", V2.known_on, " unit at ", pick, " base_mp ", u["base_mp"])
	shell.get("unit_renderer").call("update_unit_position", id, pick.x, pick.y)
	shell.call("_fog_recalc", "probe")
	um.call("select_unit", id)
	await create_timer(8.0).timeout
	print("[R] known size ", V2.known.size(), " known_on ", V2.known_on)
	var env = shell.get("_current_envelope")
	var rivers := 0
	var landing := 0
	for c in env.reachable_data:
		var t := int(cells["%d,%d" % [c.x, c.y]].terrain)
		if t == 7:
			rivers += 1
			print("[R] REACHABLE RIVER HEX ", c)
	print("[R] reach ", env.reachable_data.size(), " river hexes among them ", rivers, " green ", env.green_hexes.size())
	quit(0)
