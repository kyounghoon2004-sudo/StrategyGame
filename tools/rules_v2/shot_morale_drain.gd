extends SceneTree
## Draining ring: two units outside the supply radius (morale 100 and 60); 4 frames 0.12 s apart.
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
	var HexU = load("res://scripts/core/hex_utils.gd")
	var cells: Dictionary = shell.get("hex_grid").get("cell_data")
	var spots := []
	for k in cells.keys():
		var p: PackedStringArray = k.split(",")
		var h := Vector2i(int(p[0]), int(p[1]))
		if int(cells[k].terrain) == 0 and h.y < -8 and h.y > -13 and h.x > -4 and h.x < 4 and not um._occupied_map.has(k) and um.supply_v2.zone_of(um._units, "blue", h.x, h.y) == "out":
			spots.append(h)
	var ids := ["B_SCOUT_1", "B_SCOUT_2"]
	var vals := [100.0, 60.0]
	var used := []
	for i in 2:
		var h: Vector2i = spots[i * 3]
		var u: Dictionary = um._units[ids[i]]
		um._occupied_map.erase("%d,%d" % [int(u["q"]), int(u["r"])])
		u["q"] = h.x
		u["r"] = h.y
		u["morale"] = vals[i]
		um._occupied_map["%d,%d" % [h.x, h.y]] = ids[i]
		shell.get("unit_renderer").call("update_unit_position", ids[i], h.x, h.y)
		used.append(h)
	var mid: Vector2 = (HexU.hex_to_pixel(used[0].x, used[0].y) + HexU.hex_to_pixel(used[1].x, used[1].y)) * 0.5
	shell.get("camera").call("focus_on", mid, true)
	shell.get("camera").call("set_zoom_level", 2.2, true)
	await create_timer(7.0).timeout
	for n in 4:
		root.get_viewport().get_texture().get_image().save_png(out.path_join("morale_drain_%d.png" % n))
		print("[D] frame ", n, " trends ", view._units["B_SCOUT_1"].get("m_trend"), " ", view._units["B_SCOUT_2"].get("m_trend"))
		await create_timer(0.12).timeout
	for i in 2:
		var b: Control = view._units[ids[i]]["badge"]
		print("[D] badge ", ids[i], " at ", b.position + b.pivot_offset)
	quit(0)
