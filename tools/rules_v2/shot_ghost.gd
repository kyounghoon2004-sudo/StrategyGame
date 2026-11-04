extends SceneTree
## Capture: a lost contact stays as an ink-brown 3D ghost at its last known hex (no text marker).
## godot --path . --script res://tools/rules_v2/shot_ghost.gd -- <out_dir>
func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var out := args[0] if args.size() > 0 else "user://"
	var shell: Node = (load("res://scenes/step2r_battlefield_shell.tscn") as PackedScene).instantiate()
	shell.set("battlefield_id", "EDITOR_M1")
	root.add_child(shell)
	for i in 150:
		await process_frame
	var um = shell.get("unit_manager")
	var view = shell.get("_view3d")
	var HexU = load("res://scripts/core/hex_utils.gd")
	var fog = shell.get("_fog")
	var rid := ""
	for k in um._units.keys():
		if str(um._units[k]["faction"]) == "red" and str(um._units[k]["class"]) != "hq":
			rid = str(k)
			break
	var blue: Dictionary = um._units["B_SCOUT_1"]
	var red: Dictionary = um._units[rid]
	var home := Vector2i(int(red["q"]), int(red["r"]))
	var bq := Vector2i(int(blue["q"]), int(blue["r"]))
	var far_pos := bq + Vector2i(0, 8)
	var seen_at := far_pos + Vector2i(0, 2)
	var ur = shell.get("unit_renderer")
	um._occupied_map.erase("%d,%d" % [home.x, home.y])
	red["q"] = seen_at.x
	red["r"] = seen_at.y
	um._occupied_map["%d,%d" % [seen_at.x, seen_at.y]] = rid
	ur.call("update_unit_position", rid, seen_at.x, seen_at.y)
	um._occupied_map.erase("%d,%d" % [bq.x, bq.y])
	blue["q"] = far_pos.x
	blue["r"] = far_pos.y
	um._occupied_map["%d,%d" % [far_pos.x, far_pos.y]] = "B_SCOUT_1"
	ur.call("update_unit_position", "B_SCOUT_1", far_pos.x, far_pos.y)
	shell.call("_fog_recalc", "test")
	await create_timer(1.5).timeout
	print("[G] seen: ", fog.is_enemy_visible(red))
	um._occupied_map.erase("%d,%d" % [seen_at.x, seen_at.y])
	red["q"] = home.x
	red["r"] = home.y
	um._occupied_map["%d,%d" % [home.x, home.y]] = rid
	ur.call("update_unit_position", rid, home.x, home.y)
	var back := bq
	um._occupied_map.erase("%d,%d" % [far_pos.x, far_pos.y])
	blue["q"] = back.x
	blue["r"] = back.y
	um._occupied_map["%d,%d" % [back.x, back.y]] = "B_SCOUT_1"
	ur.call("update_unit_position", "B_SCOUT_1", back.x, back.y)
	shell.call("_fog_recalc", "test2")
	await create_timer(3.0).timeout
	print("[G] stale ", fog.stale_contacts.keys(), " ghosts ", view._ghosts.keys(), " 2D markers ", shell.get("_stale_markers").size())
	var cam = shell.get("camera")
	cam.call("focus_on", HexU.hex_to_pixel(seen_at.x, seen_at.y), true)
	await create_timer(2.0).timeout
	print("[G] camera zoom ", cam.zoom, " pos ", cam.global_position, " target ", HexU.hex_to_pixel(seen_at.x, seen_at.y))
	print("[G] ghost on screen at ", view.world_to_screen(HexU.hex_to_pixel(seen_at.x, seen_at.y)))
	await create_timer(1.5).timeout
	root.get_viewport().get_texture().get_image().save_png(out.path_join("ghost_lost_contact.png"))
	um._occupied_map.erase("%d,%d" % [back.x, back.y])
	blue["q"] = far_pos.x
	blue["r"] = far_pos.y
	um._occupied_map["%d,%d" % [far_pos.x, far_pos.y]] = "B_SCOUT_1"
	ur.call("update_unit_position", "B_SCOUT_1", far_pos.x, far_pos.y)
	shell.call("_fog_recalc", "test3")
	await create_timer(12.0).timeout
	print("[G] after the spot is seen again, ghosts ", view._ghosts.keys())
	root.get_viewport().get_texture().get_image().save_png(out.path_join("ghost_seen_again.png"))
	quit(0)
