extends SceneTree
## Captures the 요새화 palisade: before, mid-build and finished, plus a 휴식 marker.
## godot --path . --script res://tools/rules_v2/shot_fort.gd -- <out_dir>

func _init() -> void:
	var out := OS.get_cmdline_user_args()[0]
	var shell: Node = (load("res://scenes/step2r_battlefield_shell.tscn") as PackedScene).instantiate()
	shell.set("battlefield_id", "EDITOR_M1")
	shell.set("no_fog", true)
	root.add_child(shell)
	for i in 140:
		await process_frame
	var um = shell.get("unit_manager")
	um.call("select_unit", "B_CONS_3")
	await process_frame
	print("[FORT] fortify B_CONS_3: ", um.v2_fortify("B_CONS_3"))
	um._units["B_CONS_1"]["supply_zone"] = "near"
	print("[FORT] rest B_CONS_2: ", um.rest_unit("B_CONS_2").get("success"))
	for i in 25:
		await process_frame
	root.get_viewport().get_texture().get_image().save_png(out.path_join("fort_building.png"))
	for i in 140:
		await process_frame
	root.get_viewport().get_texture().get_image().save_png(out.path_join("fort_done.png"))
	var cam = shell.get("camera")
	var HexU = load("res://scripts/core/hex_utils.gd")
	var uq: Dictionary = um._units["B_CONS_3"]
	cam.set("anchor_provider", Callable())
	cam.call("set_zoom_level", 3.2, true)
	cam.call("focus_on", HexU.hex_to_pixel(int(uq["q"]), int(uq["r"])), true)
	for i in 90:
		await process_frame
	root.get_viewport().get_texture().get_image().save_png(out.path_join("fort_closeup.png"))
	print("[FORT] saved")
	um._units["B_CONS_3"]["fort_hp"] = 50
	um.v2_fort_changed.emit("B_CONS_3", 50)
	for i in 80:
		await process_frame
	root.get_viewport().get_texture().get_image().save_png(out.path_join("fort_damaged.png"))
	quit(0)
