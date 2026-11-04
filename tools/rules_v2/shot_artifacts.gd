extends SceneTree
## Captures the unified icons / base models, and the hover-only gauges + supply lines.
## godot --path . --script res://tools/rules_v2/shot_artifacts.gd -- <out_dir>

func _init() -> void:
	var out := OS.get_cmdline_user_args()[0]
	var shell: Node = (load("res://scenes/step2r_battlefield_shell.tscn") as PackedScene).instantiate()
	shell.set("battlefield_id", "EDITOR_M1")
	shell.set("no_fog", true)
	root.add_child(shell)
	for i in 150:
		await process_frame
	var um = shell.get("unit_manager")
	var art = shell.get("_v2_artifacts")
	print("[ART] layer=", art != null)
	# the HQ builds two bases, a unit stands in the (damaged) village
	print("[ART] build: ", um.v2_build_base("B_HQ").get("success"))
	um._units["B_HQ"]["action_ended"] = false
	um._units["B_HQ"]["r"] = int(um._units["B_HQ"]["r"]) + 3
	print("[ART] build 2: ", um.v2_build_base("B_HQ").get("success"))
	um._units["B_HQ"]["r"] = int(um._units["B_HQ"]["r"]) - 3
	var sh = um.get_stronghold_at_coord(Vector2i(-6, -7))
	sh.fortification_hp = 190
	um._units["B_SPEA_4"]["q"] = -6
	um._units["B_SPEA_4"]["r"] = -7
	var cam = shell.get("camera")
	var HexU = load("res://scripts/core/hex_utils.gd")
	cam.set("anchor_provider", Callable())
	cam.call("set_zoom_level", 2.4, true)
	cam.call("focus_on", HexU.hex_to_pixel(-6, -9), true)
	for i in 80:
		await process_frame
	root.get_viewport().get_texture().get_image().save_png(out.path_join("art_idle.png"))
	# hover the first base (no click): its HP gauge and supply chain appear
	var first: Dictionary = um.supply_v2.nodes[0]
	art.force_hover = Vector2i(int(first["q"]), int(first["r"]))
	for i in 40:
		await process_frame
	root.get_viewport().get_texture().get_image().save_png(out.path_join("art_hover.png"))
	art.force_hover = Vector2i(-999, -999)
	art.click_hex(Vector2i(-6, -7))   # pin the village
	for i in 40:
		await process_frame
	root.get_viewport().get_texture().get_image().save_png(out.path_join("art_pinned_village.png"))
	print("[ART] saved")
	quit(0)
