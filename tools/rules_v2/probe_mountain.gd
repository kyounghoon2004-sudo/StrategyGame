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
	var mts := []
	for k in cells.keys():
		if int(cells[k].terrain) == 1:
			mts.append(k)
	print("[P] mountain cells: ", mts.size(), " enabled ", V2.enabled, " known_on ", V2.known_on, " known ", V2.known.size())
	var id := "B_SCOUT_1"
	var u: Dictionary = um._units[id]
	var view = shell.get("_view3d")
	# put the scout beside the first mountain cluster that is far from the start, like a player marching into unseen ground
	var pick := Vector2i(-999, -999)
	for k in mts:
		var p0: PackedStringArray = k.split(",")
		var h0 := Vector2i(int(p0[0]), int(p0[1]))
		if h0.y > 0 and not um._occupied_map.has("%d,%d" % [h0.x, h0.y - 1]) and int(cells["%d,%d" % [h0.x, h0.y - 1]].terrain) == 0:
			pick = h0 + Vector2i(0, -1)
			break
	um._occupied_map.erase("%d,%d" % [int(u["q"]), int(u["r"])])
	u["q"] = pick.x
	u["r"] = pick.y
	um._occupied_map["%d,%d" % [pick.x, pick.y]] = id
	shell.get("unit_renderer").call("update_unit_position", id, pick.x, pick.y)
	shell.call("_fog_recalc", "probe")
	um.call("select_unit", id)
	await create_timer(6.0).timeout
	var env = shell.get("_current_envelope")
	print("[P] scout at ", pick, " reach ", env.reachable_data.size())
	for k in mts:
		var p: PackedStringArray = k.split(",")
		var h := Vector2i(int(p[0]), int(p[1]))
		if max(abs(h.x - pick.x), abs(h.y - pick.y), abs(h.x + h.y - pick.x - pick.y)) <= 5:
			print("[P] mountain ", h, " logical-known ", V2.known.has(k), " in reach ", env.reachable_data.has(h), " view state ", snappedf(float(view._fow_cur.get(k, 0.0)), 0.01))
	quit(0)
