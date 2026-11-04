extends SceneTree
## Captures the HQ selection framing: morale heatmap + desaturated surroundings + the supply
## lines that now exist before any base is built.
## godot --path . --script res://tools/rules_v2/shot_hq_focus.gd -- <out_dir> [battlefield_id]

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var out := args[0] if args.size() > 0 else "user://"
	var bf := args[1] if args.size() > 1 else "EDITOR_M1"
	var shell: Node = (load("res://scenes/step2r_battlefield_shell.tscn") as PackedScene).instantiate()
	shell.set("battlefield_id", bf)
	shell.set("no_fog", OS.get_environment("SHOT_FOG") != "1")
	root.add_child(shell)
	for i in 150:
		await process_frame
	var um = shell.get("unit_manager")
	if not load("res://scripts/rules_v2/rules_v2.gd").enabled:
		print("[SHOT] not a V2 map")
		quit(1)
		return
	print("[SHOT] supply paths before any base: ", um.supply_v2.fixed_paths("blue").size())
	if OS.get_environment("SHOT_FOG") == "1":
		# seed "seen before, not seen now" ground so the explored blur can be captured
		var fog = shell.get("_fog")
		if fog != null:
			for q in range(-12 if OS.get_environment("SHOT_ALL") != "1" else -20, -4 if OS.get_environment("SHOT_ALL") != "1" else 21):
				for r in range(-8 if OS.get_environment("SHOT_ALL") != "1" else -20, 0 if OS.get_environment("SHOT_ALL") != "1" else 21):
					var k2 := "%d,%d" % [q, r]
					fog.explored[k2] = true
					fog.visible.erase(k2)
			shell.call("_apply_fog_terrain")
			for _si in 40:   # seed settle: let the 3D shroud/cell texture catch up
				await process_frame
			print("[SHOT] seeded explored cells: ", fog.explored.size(), " visible: ", fog.visible.size())
	_phase(shell, 12.075)
	for i in 3:
		await process_frame
	root.get_viewport().get_texture().get_image().save_png(out.path_join("%s_hq_passive.png" % bf))
	print("[SHOT] saved passive pulse (no selection)")
	var units_all: Dictionary = um.get("_units")
	var pick := ""
	for id in units_all.keys():
		var uu: Dictionary = units_all[id]
		if str(uu.get("faction", "")) == "blue" and str(uu.get("class", "")) != "hq" and int(uu.get("soldier_count", 0)) > 0:
			pick = str(id)
			break
	if pick != "":
		um.call("select_unit", pick)
		for i in 20:
			await process_frame
		root.get_viewport().get_texture().get_image().save_png(out.path_join("%s_unit_ring.png" % bf))
		print("[SHOT] saved unit ring ", pick)
	um.call("select_unit", "B_HQ")
	var _ov = shell.get_node_or_null("V2Overlay")
	for i in 70:
		await process_frame
	_phase(shell, 12.075)
	for i in 2:
		await process_frame
	root.get_viewport().get_texture().get_image().save_png(out.path_join("%s_hq_focus.png" % bf))
	_phase(shell, 12.075)   # 5th pulse -> orange range ring
	for i in 3:
		await process_frame
	root.get_viewport().get_texture().get_image().save_png(out.path_join("%s_hq_orange.png" % bf))
	print("[SHOT] saved orange range ring")
	print("[SHOT] saved hq focus")
	# zoomed-in capture: the bands must stay on the board hexes at any zoom
	var v = shell.get("_view3d")
	if v != null:
		var c2d = v.get("cam2d")
		if c2d != null:
			c2d.call("set_zoom_level", 1.75, true)
	for i in 60:
		await process_frame
	_phase(shell, 12.075)
	for i in 2:
		await process_frame
	root.get_viewport().get_texture().get_image().save_png(out.path_join("%s_hq_zoom.png" % bf))
	print("[SHOT] saved zoom")
	# build one base so the tapered chain and the heatmap can be compared
	print("[SHOT] build: ", um.v2_build_base("B_HQ").get("success"))
	for i in 50:
		await process_frame
	root.get_viewport().get_texture().get_image().save_png(out.path_join("%s_hq_focus_base.png" % bf))
	print("[SHOT] saved hq focus (base built)")
	quit(0)


## Puts the pulse at a known phase so a capture shows the crest mid-flight.
func _phase(shell: Node, t: float) -> void:
	var ov = shell.get_node_or_null("V2Overlay")
	if ov == null:
		return
	var fc = ov.get("_focus")
	if fc != null:
		fc.set("_t", t)
