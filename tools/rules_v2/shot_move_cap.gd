extends SceneTree
## Windowed capture: V2 move cap. Far click does nothing; in-reach click previews a route inside the white outline.
## godot --path . --script res://tools/rules_v2/shot_move_cap.gd -- <out_dir> [unit_id]

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var out := args[0] if args.size() > 0 else "user://"
	var uid := args[1] if args.size() > 1 else "B_M1_MILITIA_1"
	var shell: Node = (load("res://scenes/step2r_battlefield_shell.tscn") as PackedScene).instantiate()
	shell.set("battlefield_id", "EDITOR_M1")
	shell.set("no_fog", true)
	root.add_child(shell)
	for i in 120:
		await process_frame
	var um = shell.get("unit_manager")
	var HexU = load("res://scripts/core/hex_utils.gd")
	um.call("select_unit", uid)
	for i in 30:
		await process_frame
	var u: Dictionary = um._units[uid]
	var origin := Vector2i(int(u["q"]), int(u["r"]))
	var env = shell.get("_current_envelope")
	var near_hex := Vector2i(-999, -999)
	var best := -1.0
	for c in env.reachable_data:
		var cost: float = float(env.reachable_data[c]["cost"])
		if cost > best:
			best = cost
			near_hex = c
	print("[SHOT] unit ", uid, " base_mp ", u.get("base_mp"), " reach hexes ", env.reachable_data.size(), " farthest cost ", best, " -> ", near_hex)
	var far_hex := Vector2i(-999, -999)
	for dq in range(-6, 7):
		for dr in range(-6, 7):
			var h := origin + Vector2i(dq, dr)
			if max(abs(dq), abs(dr), abs(dq + dr)) == 5 and not env.reachable_data.has(h) and um._occupied_map.has("%d,%d" % [h.x, h.y]) == false:
				far_hex = h
	shell.call("_handle_hex_click", far_hex, HexU.hex_to_pixel(far_hex.x, far_hex.y))
	for i in 20:
		await process_frame
	print("[SHOT] far click -> preview ", shell.get("_preview_target_hex"), " selected=", um.is_unit_selected())
	root.get_viewport().get_texture().get_image().save_png(out.path_join("move_cap_far_click.png"))
	shell.call("_handle_hex_click", near_hex, HexU.hex_to_pixel(near_hex.x, near_hex.y))
	for i in 30:
		await process_frame
	print("[SHOT] near click -> preview ", shell.get("_preview_target_hex"))
	root.get_viewport().get_texture().get_image().save_png(out.path_join("move_cap_in_reach.png"))
	quit(0)
