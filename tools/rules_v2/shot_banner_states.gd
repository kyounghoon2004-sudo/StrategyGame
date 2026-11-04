extends SceneTree
## Banner states: full HP (hidden ring), damaged (grey ring), enemy-held (red plate, blue seal).
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
	var HexU = load("res://scripts/core/hex_utils.gd")
	var sh = um.get_all_strongholds()[0]
	var hex: Vector2i = sh.anchor_hex
	var u: Dictionary = um._units.get("B_GUARD", {})
	if not u.is_empty():   # move the garrison off so the banner stands alone
		um._occupied_map.erase("%d,%d" % [int(u["q"]), int(u["r"])])
		u["q"] = hex.x + 1
		u["r"] = hex.y - 1
		um._occupied_map["%d,%d" % [hex.x + 1, hex.y - 1]] = "B_GUARD"
		shell.get("unit_renderer").call("update_unit_position", "B_GUARD", hex.x + 1, hex.y - 1)
	shell.get("camera").call("focus_on", HexU.hex_to_pixel(hex.x, hex.y), true)
	shell.get("camera").call("set_zoom_level", 2.2, true)
	await create_timer(3.0).timeout
	root.get_viewport().get_texture().get_image().save_png(out.path_join("banner_full.png"))
	sh.fortification_hp = int(sh.fortification_hp_max * 0.55)
	await create_timer(1.0).timeout
	root.get_viewport().get_texture().get_image().save_png(out.path_join("banner_damaged.png"))
	var art = shell.get("_v2_artifacts")
	art.force_hover = hex
	await create_timer(1.2).timeout
	root.get_viewport().get_texture().get_image().save_png(out.path_join("banner_hover.png"))
	art.force_hover = Vector2i(-999, -999)
	await create_timer(1.0).timeout
	sh.owner = "red"
	await create_timer(1.0).timeout
	root.get_viewport().get_texture().get_image().save_png(out.path_join("banner_captured.png"))
	print("[B] hex ", hex, " screen ", shell.get("_view3d").world_to_screen(HexU.hex_to_pixel(hex.x, hex.y)))
	quit(0)
