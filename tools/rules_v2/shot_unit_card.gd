extends SceneTree
## Capture the unit card (portrait + diagram) for a few unit classes.
## godot --audio-driver Dummy --path . --script res://tools/rules_v2/shot_unit_card.gd -- <out_dir>
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
	var picks := {"B_HQ": "hq"}
	for id in picks:
		if not um._units.has(id):
			print("[C] missing ", id)
			continue
		um._units[id]["xp"] = 25
		um._units[id]["morale"] = 55.0
		um.call("select_unit", id)
		await create_timer(2.2).timeout
		root.get_viewport().get_texture().get_image().save_png(out.path_join("card_%s.png" % picks[id]))
		print("[C] shot ", id)
	um.call("select_unit", "B_CONS_2")
	await create_timer(1.0).timeout
	var panel = shell.get("_v2_panel")
	um._units["B_CONS_2"]["xp"] = 45
	panel._card._toggle_promo()
	await create_timer(0.5).timeout
	panel._card._promo_tree.hovered = "infantry"
	await create_timer(1.2).timeout
	print("[C] promo win ", panel._card._promo_win, " visible ", panel._card._promo_win.visible if panel._card._promo_win else "-", " pos ", panel._card._promo_win.global_position if panel._card._promo_win else "-", " size ", panel._card._promo_win.size if panel._card._promo_win else "-")
	root.get_viewport().get_texture().get_image().save_png(out.path_join("card_promo.png"))
	quit(0)
