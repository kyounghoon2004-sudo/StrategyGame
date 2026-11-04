extends SceneTree
## Windowed captures of the designed M1 under V2 rules (before / after the first supply base):
## godot --path . --script res://tools/rules_v2/shot_m1.gd -- <out_dir> [battlefield_id] [nofog]

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var out := args[0] if args.size() > 0 else "user://"
	var bf := args[1] if args.size() > 1 else "EDITOR_M1"
	var shell: Node = (load("res://scenes/step2r_battlefield_shell.tscn") as PackedScene).instantiate()
	shell.set("battlefield_id", bf)
	if args.size() > 2 and args[2] == "nofog":
		shell.set("no_fog", true)
	root.add_child(shell)
	for i in 120:
		await process_frame
	var um = shell.get("unit_manager")
	if not load("res://scripts/rules_v2/rules_v2.gd").enabled:
		quit(1)
		return
	var hq: Dictionary = um._units["B_HQ"]
	um.call("select_unit", "B_HQ")
	for i in 40:
		await process_frame
	root.get_viewport().get_texture().get_image().save_png(out.path_join("%s_before.png" % bf))
	print("[SHOT] before saved; first build: ", um.v2_build_base("B_HQ").get("success"))
	# the HQ marches a few hexes toward the enemy and builds a second base (links to the first)
	hq["r"] = int(hq["r"]) + 4
	hq["action_ended"] = false
	print("[SHOT] second build: ", um.v2_build_base("B_HQ").get("success"))
	hq["r"] = int(hq["r"]) - 4
	for i in 60:
		await process_frame
	root.get_viewport().get_texture().get_image().save_png(out.path_join("%s_v2.png" % bf))
	print("[SHOT] saved")
	quit(0)
