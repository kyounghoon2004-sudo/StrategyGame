extends SceneTree
## M1: units walk onto the village hex like any hex; unit + structure coexist; hits split.
## godot --headless --path . --script res://tools/rules_v2/test_village_walk.gd

var fails := 0

func check(name: String, ok: bool, extra: String = "") -> void:
	print(("PASS " if ok else "FAIL ") + name + ((" | " + extra) if extra != "" else ""))
	if not ok:
		fails += 1

func _init() -> void:
	var shell: Node = (load("res://scenes/step2r_battlefield_shell.tscn") as PackedScene).instantiate()
	shell.set("battlefield_id", "EDITOR_M1")
	root.add_child(shell)
	await process_frame
	await process_frame
	var um = shell.get("unit_manager")
	var hall := Vector2i(-6, -7)
	var sh = um.get_stronghold_at_coord(hall)
	check("village structure exists", sh != null)
	check("village not blocking path (shell cells empty)", (shell.get("_stronghold_cells") as Dictionary).is_empty())
	var g: Dictionary = um._units["B_GUARD"]
	check("guard stands on hall as ordinary unit", not bool(g.get("garrisoned", false)) and Vector2i(int(g["q"]), int(g["r"])) == hall)
	# a second unit walks onto the hall hex (adjacent hex first)
	var u: Dictionary = um._units["B_SPEA_4"]
	g["q"] = -2; g["r"] = -9   # guard steps far away
	um._occupied_map.erase("%d,%d" % [hall.x, hall.y])
	u["q"] = -5; u["r"] = -8
	var path: Array[Vector2i] = [Vector2i(-5, -8), hall]
	var res: Dictionary = um.execute_move("B_SPEA_4", path, 1.0, 0, false)
	check("move onto structure hex succeeds", res.get("success", false), str(res.get("error", "")))
	check("unit and structure both exist on hex", um.get_stronghold_at_coord(hall) != null and Vector2i(int(u["q"]), int(u["r"])) == hall)
	# click flow: select the unit standing in the village, click an outside hex, confirm -> it walks out
	var HexU = load("res://scripts/core/hex_utils.gd")
	um.select_unit("B_SPEA_4")
	var out_hex := Vector2i(-6, -6)   # adjacent: 1 MP is left after stepping in (V2 has no over-run)
	shell.call("_handle_hex_click", out_hex, HexU.hex_to_pixel(out_hex.x, out_hex.y))
	check("click outside hex previews a route (no panel)", (shell.get("_preview_target_hex") as Vector2i) == out_hex, str(shell.get("_preview_target_hex")))
	shell.call("_execute_confirmed_move")
	var guard := 0
	while bool(shell.get("_is_animating_movement")) and guard < 600:
		await process_frame
		guard += 1
	check("unit walked out of the village", Vector2i(int(u["q"]), int(u["r"])) != hall, "%d,%d" % [int(u["q"]), int(u["r"])])
	# and back in by plain click
	um.end_turn()   # next turn: MP restored
	um.select_unit("B_SPEA_4")
	shell.call("_handle_hex_click", hall, HexU.hex_to_pixel(hall.x, hall.y))
	check("click on village hex previews a move (not a panel)", (shell.get("_preview_target_hex") as Vector2i) == hall, str(shell.get("_preview_target_hex")))
	shell.call("_execute_confirmed_move")
	guard = 0
	while bool(shell.get("_is_animating_movement")) and guard < 600:
		await process_frame
		guard += 1
	check("unit walked back in", Vector2i(int(u["q"]), int(u["r"])) == hall, "%d,%d" % [int(u["q"]), int(u["r"])])
	# the V2 action bar must swallow clicks (they used to fall through and deselect the unit)
	um.select_unit("B_HQ")
	for i in 40:
		await process_frame
	var vp = shell.get("_v2_panel")
	check("action bar is visible for the selected unit", vp != null and vp.is_visible_in_tree())
	check("click on the action bar is treated as HUD, not map", vp != null and bool(shell.call("_is_click_over_hud", vp.get_global_rect().get_center())))
	# supply: edge bases exist from the start, but no line until the first base is built
	var sv0 = um.supply_v2
	check("two edge bases exist from the start", (sv0.fixed["blue"]["entries"] as Array).size() == 2)
	check("edge bases connect before anything is built (2026-11-01 rule)", sv0.fixed_paths("blue").size() == 2 and sv0.nodes.is_empty())
	var ov = load("res://scripts/rules_v2/v2_overlay.gd")
	check("longer line is thinner", ov.link_width(2, 8) > ov.link_width(5, 8) and ov.link_width(5, 8) > ov.link_width(8, 8), "%.1f %.1f %.1f" % [ov.link_width(2, 8), ov.link_width(5, 8), ov.link_width(8, 8)])
	# real mouse click on the 건설 button of the action bar (HQ selected)
	var build_btn: Button = null
	for b in vp.find_children("*", "Button", true, false):
		if str((b as Button).text).begins_with("건설"):
			build_btn = b
	check("build button exists for the HQ", build_btn != null and not build_btn.disabled)
	if build_btn != null:
		var nodes0: int = um.supply_v2.nodes.size()
		var c: Vector2 = build_btn.get_global_rect().get_center()
		var wc: Vector2 = c   # pushed in viewport (canvas) coordinates: the headless window is only 64x64
		var ev := InputEventMouseButton.new()
		ev.position = wc
		ev.global_position = wc
		ev.button_index = MOUSE_BUTTON_LEFT
		ev.pressed = true
		root.get_viewport().push_input(ev, true)
		await process_frame
		var ev2 := ev.duplicate() as InputEventMouseButton
		ev2.pressed = false
		root.get_viewport().push_input(ev2, true)
		await process_frame
		check("clicking 건설 builds a base and ends the HQ action", um.supply_v2.nodes.size() == nodes0 + 1 and bool(um._units["B_HQ"]["action_ended"]), "nodes %d->%d" % [nodes0, um.supply_v2.nodes.size()])
		check("HQ stays selected-visible state consistent (no deselect)", um.is_unit_selected())
		var fp: Array = sv0.fixed_paths("blue")
		var an: Dictionary = sv0.anchor_of("blue")
		check("after the first base both edge bases connect to it", fp.size() == 2 and fp[0][fp[0].size() - 1] == Vector2i(int(an["q"]), int(an["r"])) and fp[1][fp[1].size() - 1] == Vector2i(int(an["q"]), int(an["r"])) and fp[0][0] == sv0.fixed["blue"]["entries"][0])
	# real clicks on 휴식 (needs the healing radius) and 턴 스킵
	for pair in [["B_CONS_2", "휴식"], ["B_CONS_3", "턴 스킵"]]:
		var sid: String = pair[0]
		um._units[sid]["supply_zone"] = "near"
		um.select_unit(sid)
		for i in 30:
			await process_frame
		var btn: Button = null
		for b in vp.find_children("*", "Button", true, false):
			if str((b as Button).text).begins_with(pair[1]):
				btn = b
		check("%s button enabled for %s" % [pair[1], sid], btn != null and not btn.disabled)
		if btn != null:
			var cc: Vector2 = btn.get_global_rect().get_center()
			var d1 := InputEventMouseButton.new()
			d1.position = cc
			d1.global_position = cc
			d1.button_index = MOUSE_BUTTON_LEFT
			d1.pressed = true
			root.get_viewport().push_input(d1, true)
			await process_frame
			var d2 := d1.duplicate() as InputEventMouseButton
			d2.pressed = false
			root.get_viewport().push_input(d2, true)
			await process_frame
			check("clicking %s ends %s's action" % [pair[1], sid], bool(um._units[sid]["action_ended"]))
	# real click on 요새화 for an untouched infantry-type unit
	um.select_unit("B_CONS_1")
	for i in 30:
		await process_frame
	var fbtn: Button = null
	for b in vp.find_children("*", "Button", true, false):
		if str((b as Button).text).begins_with("요새화"):
			fbtn = b
	check("요새화 button exists and is enabled", fbtn != null and not fbtn.disabled, str(fbtn.text if fbtn else "none") + " / " + str(um.v2_fortify_block("B_CONS_1")))
	if fbtn != null:
		var fc: Vector2 = fbtn.get_global_rect().get_center()
		var f1 := InputEventMouseButton.new()
		f1.position = fc
		f1.global_position = fc
		f1.button_index = MOUSE_BUTTON_LEFT
		f1.pressed = true
		root.get_viewport().push_input(f1, true)
		await process_frame
		var f2 := f1.duplicate() as InputEventMouseButton
		f2.pressed = false
		root.get_viewport().push_input(f2, true)
		await process_frame
		check("clicking 요새화 builds the palisade", int(um._units["B_CONS_1"].get("fort_hp", 0)) == 120 and bool(um._units["B_CONS_1"]["fort_used"]), "fort_hp %d" % int(um._units["B_CONS_1"].get("fort_hp", 0)))
	# red attacks the unit standing on the village: damage splits
	var atk: Dictionary = um._units["R_CONS_1"]
	atk["q"] = -6; atk["r"] = -6
	var hp0: int = int(u["soldier_count"])
	var wall0: int = int(sh.fortification_hp)
	var r: Dictionary = um.execute_attack("R_CONS_1", "B_SPEA_4")
	check("attack on unit in village resolves", r.get("success", false), str(r.get("error", "")))
	check("wall AND unit both damaged", int(sh.fortification_hp) < wall0 and int(u["soldier_count"]) < hp0, "wall %d->%d hp %d->%d" % [wall0, int(sh.fortification_hp), hp0, int(u["soldier_count"])])
	# capture: wall at 0 and a red unit on the hex at turn end flips the owner
	sh.fortification_hp = 0
	u["q"] = -3; u["r"] = -3
	atk["q"] = hall.x; atk["r"] = hall.y
	um.end_turn()
	check("owner flips when wall is 0 and enemy occupies", str(sh.owner) == "red", str(sh.owner))
	# fixed edge bases are far apart and on the board edge
	var fx: Dictionary = um.supply_v2.fixed["blue"]
	var e0: Vector2i = fx["entries"][0]
	var e1: Vector2i = fx["entries"][1]
	check("fixed bases on the edge", max(abs(e0.x), max(abs(e0.y), abs(e0.x + e0.y))) == 20 and max(abs(e1.x), max(abs(e1.y), abs(e1.x + e1.y))) == 20)
	check("fixed bases far apart", um.supply_v2.dist(e0.x, e0.y, e1.x, e1.y) >= 8, "dist %d entries %s" % [um.supply_v2.dist(e0.x, e0.y, e1.x, e1.y), str(fx["entries"])])
	print("=== village walk test: %d failure(s) ===" % fails)
	quit(1 if fails > 0 else 0)
