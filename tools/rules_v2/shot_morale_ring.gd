extends SceneTree
## Capture the morale ring: green (hover only), yellow weak (always), red broken (always); a rising / falling blinking arc.
## godot --audio-driver Dummy --path . --script res://tools/rules_v2/shot_morale_ring.gd -- <out_dir>
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
	var ids := ["B_CONS_2", "B_CONS_3", "B_SPEA_4", "B_GUARD", "B_HQ"]
	var vals := [55.0, 20.0, 90.0, 40.0, 100.0]
	# one far-out unit: scout at 100 / 80 / 40 outside the radius
	for sid in ["B_SCOUT_1", "B_SCOUT_2"]:
		um._units[sid]["morale"] = 100.0 if sid == "B_SCOUT_1" else 60.0
	for i in ids.size():
		if um._units.has(ids[i]):
			um._units[ids[i]]["morale"] = vals[i]
	um.supply_v2.stock["blue"] = 3
	var u: Dictionary = um._units["B_GUARD"]
	shell.get("camera").call("focus_on", HexU.hex_to_pixel(int(u["q"]), int(u["r"])), true)
	shell.get("camera").call("set_zoom_level", float(OS.get_environment("SHOT_ZOOM") if OS.get_environment("SHOT_ZOOM") != "" else "1.8"), true)
	await create_timer(1.5).timeout
	root.get_viewport().get_texture().get_image().save_png(out.path_join("morale_ring_a.png"))
	await create_timer(0.21).timeout
	root.get_viewport().get_texture().get_image().save_png(out.path_join("morale_ring_b.png"))
	var gb: Control = shell.get("_view3d")._units["B_HQ"]["badge"]
	print("[M] full-morale unit trend ", gb.morale_trend, " morale ", gb.morale)
	um.call("select_unit", "B_SPEA_4")
	await create_timer(1.0).timeout
	root.get_viewport().get_texture().get_image().save_png(out.path_join("morale_ring_sel.png"))
	var badges := {}
	for k in ids:
		var vd = shell.get("_view3d")._units.get(k)
		if vd != null:
			var b: Control = vd["badge"]
			badges[k] = [b.morale, b.morale_trend, b.morale_on, b._ring_shown()]
	var bsel: Control = shell.get("_view3d")._units["B_SPEA_4"]["badge"]
	print("[M] sel badge at ", bsel.position + bsel.pivot_offset, " grow ", bsel._grow)
	print("[M] ", badges)
	quit(0)
