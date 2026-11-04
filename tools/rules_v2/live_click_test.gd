extends SceneTree
## Windowed end-to-end: real clicks on the action bar. Checks 턴 스킵 raises no dust,
## 휴식 lays the men down with a ZZZ stream, and a village hex refuses 요새화.
## godot --path . --script res://tools/rules_v2/live_click_test.gd -- <out_dir>

var fails := 0

func check(name: String, ok: bool, extra: String = "") -> void:
	print(("PASS " if ok else "FAIL ") + name + ((" | " + extra) if extra != "" else ""))
	if not ok:
		fails += 1

func _click(btn: Button) -> void:
	var c: Vector2 = btn.get_global_rect().get_center()
	var a := InputEventMouseButton.new()
	a.position = c
	a.global_position = c
	a.button_index = MOUSE_BUTTON_LEFT
	a.pressed = true
	root.get_viewport().push_input(a, true)
	await process_frame
	var b := a.duplicate() as InputEventMouseButton
	b.pressed = false
	root.get_viewport().push_input(b, true)
	await process_frame

func _find(panel: Node, prefix: String) -> Button:
	for b in panel.find_children("*", "Button", true, false):
		if str((b as Button).text).begins_with(prefix):
			return b
	return null

func _particles(n: Node) -> int:
	var c := 0
	for ch in n.get_children():
		if ch is CPUParticles3D or ch is GPUParticles3D:
			c += 1
		c += _particles(ch)
	return c

func _init() -> void:
	var out := OS.get_cmdline_user_args()[0]
	var shell: Node = (load("res://scenes/step2r_battlefield_shell.tscn") as PackedScene).instantiate()
	shell.set("battlefield_id", "EDITOR_M1")
	shell.set("no_fog", true)
	root.add_child(shell)
	for i in 150:
		await process_frame
	var um = shell.get("unit_manager")
	var panel = shell.get("_v2_panel")
	var view = shell.get("_view3d")
	# 턴 스킵 -> no dust / no hit reaction
	um.select_unit("B_CONS_3")
	for i in 20:
		await process_frame
	var p0: int = _particles(view)
	await _click(_find(panel, "턴 스킵"))
	for i in 30:
		await process_frame
	check("턴 스킵 ends the action", bool(um._units["B_CONS_3"]["action_ended"]))
	check("턴 스킵 raises no dust", _particles(view) == p0, "particles %d -> %d" % [p0, _particles(view)])
	# 휴식 -> lying men + ZZZ
	um.select_unit("B_CONS_2")
	for i in 20:
		await process_frame
	await _click(_find(panel, "휴식"))
	for i in 90:
		await process_frame
	var f3d = view._units["B_CONS_2"]["f3d"]
	check("휴식: unit flagged defenseless", bool(um._units["B_CONS_2"]["rested_this_turn"]))
	check("휴식: men are lying down", f3d != null and bool(f3d.get("_resting")))
	check("휴식: ZZZ emitter running", view._v2_zzz.has("B_CONS_2"))
	check("휴식: no dust either", _particles(view) == p0, "particles %d" % _particles(view))
	# 요새화 -> trampled dust while the palisade rises (liked: keep it)
	um.select_unit("B_CONS_1")
	for i in 20:
		await process_frame
	var pf: int = _particles(view)
	await _click(_find(panel, "요새화"))
	var peak: int = _particles(view)
	for i in 60:
		await process_frame
		peak = maxi(peak, _particles(view))
	check("요새화 raises dust bursts", peak > pf, "particles %d -> peak %d" % [pf, peak])
	var HexU0 = load("res://scripts/core/hex_utils.gd")
	var cam0 = shell.get("camera")
	var fq: Dictionary = um._units["B_CONS_1"]
	cam0.set("anchor_provider", Callable())
	cam0.call("set_zoom_level", 3.4, true)
	cam0.call("focus_on", HexU0.hex_to_pixel(int(fq["q"]), int(fq["r"])), true)
	for i in 14:
		await process_frame
	root.get_viewport().get_texture().get_image().save_png(out.path_join("fort_dust.png"))
	# unified icons: structure + base + occupier share ONE row on the village hex; gauges only on reveal
	var art = shell.get("_v2_artifacts")
	check("artifact layer is attached", art != null)
	um.supply_v2.stock["blue"] = 5
	um.supply_v2.nodes.clear()
	var hq: Dictionary = um._units["B_HQ"]
	var hq_old := Vector2i(int(hq["q"]), int(hq["r"]))
	hq["q"] = -6
	hq["r"] = -7
	hq["action_ended"] = false
	check("HQ builds a base on the village hex", um.v2_build_base("B_HQ").get("success", false))
	for i in 40:
		await process_frame
	var cl: Dictionary = art._clusters.get("-6,-7", {})
	var kinds: int = str(cl.get("sig", "")).count("|")
	check("village hex shows structure + base side by side (no occupier disc any more)", kinds == 2 and not str(cl.get("sig", "")).contains("occupier"), str(cl.get("sig", "")))
	var tex: Texture2D = (cl["ctrl"] as TextureRect).texture
	check("icon row is wide (one texture, several icons)", tex != null and tex.get_width() >= 2 * 48)
	# the unit standing in the village: its badge is pushed beside the icon row, not under it
	for i in 30:
		await process_frame
	var shift: Dictionary = view.get("v2_badge_shift")
	check("the unit's own badge moves sideways next to the icons", shift.size() > 0 and (shift.values()[0] as Vector2).x > 20.0, str(shift))
	var trc: TextureRect = cl["ctrl"]
	var badge_x: float = 0.0
	for uid2 in shift:
		var bb: Control = view._units[uid2]["badge"]
		badge_x = bb.position.x + bb.pivot_offset.x * bb.scale.x
	check("icon row ends before the unit badge starts (no overlap)", trc.position.x + trc.size.x <= badge_x + 2.0, "row %.0f..%.0f badge centre %.0f" % [trc.position.x, trc.position.x + trc.size.x, badge_x])
	# a unit that is only LOGICALLY on the village hex (still walking in) must not merge with the icons yet
	var gd: Dictionary = um._units["B_GUARD"]
	var mv: Dictionary = um._units["B_SPEA_4"]
	var mv_old := Vector2i(int(mv["q"]), int(mv["r"]))
	gd["q"] = -2
	gd["r"] = -9
	mv["q"] = -6
	mv["r"] = -7
	for i in 40:
		await process_frame
	var sh2: Dictionary = view.get("v2_badge_shift")
	check("unit still walking in: no merge with the village icon yet", not sh2.has("B_SPEA_4"), str(sh2))
	shell.get("unit_renderer").call("update_unit_position", "B_SPEA_4", -6, -7)   # it starts walking in
	var waited := 0
	var merged_at := -1
	while waited < 900:
		await process_frame
		waited += 1
		sh2 = view.get("v2_badge_shift")
		if sh2.has("B_SPEA_4"):
			merged_at = waited
			break
	print("[MERGE] merged after %d frames" % merged_at)
	for i in 40:
		await process_frame
	sh2 = view.get("v2_badge_shift")
	check("on arrival the icon and the unit badge sit side by side", sh2.has("B_SPEA_4") and (sh2["B_SPEA_4"] as Vector2).x > 20.0, str(sh2))
	mv["q"] = mv_old.x
	mv["r"] = mv_old.y
	gd["q"] = -6
	gd["r"] = -7
	shell.get("unit_renderer").call("update_unit_position", "B_SPEA_4", mv_old.x, mv_old.y)
	for i in 30:
		await process_frame
	check("nothing revealed by default", not art.is_revealed(Vector2i(-6, -7)) or um.is_unit_selected())
	um.deselect()
	art._pin = Vector2i(-999, -999)
	art.force_hover = Vector2i(-6, -7)
	await process_frame
	await process_frame
	check("hover reveals", art.is_revealed(Vector2i(-6, -7)))
	art.force_hover = Vector2i(-999, -999)
	await process_frame
	check("hover off hides again", not art.is_revealed(Vector2i(-6, -7)))
	art.click_hex(Vector2i(-6, -7))
	check("click pins", art.is_revealed(Vector2i(-6, -7)))
	art.click_hex(Vector2i(-6, -7))
	check("second click unpins", not art.is_revealed(Vector2i(-6, -7)))
	art.click_hex(Vector2i(-6, -7))
	art.click_hex(Vector2i(0, 0))
	check("click on an empty hex unpins", not art.is_revealed(Vector2i(-6, -7)))
	hq["q"] = hq_old.x
	hq["r"] = hq_old.y
	# village: no fortify
	um._units["B_SPEA_4"]["q"] = -6
	um._units["B_SPEA_4"]["r"] = -7
	check("요새화 refused on the village hex", um.v2_fortify_block("B_SPEA_4") != "", um.v2_fortify_block("B_SPEA_4"))
	var HexU = load("res://scripts/core/hex_utils.gd")
	var cam = shell.get("camera")
	var rq: Dictionary = um._units["B_CONS_2"]
	cam.set("anchor_provider", Callable())
	cam.call("set_zoom_level", 3.4, true)
	cam.call("focus_on", HexU.hex_to_pixel(int(rq["q"]), int(rq["r"])), true)
	for i in 70:
		await process_frame
	root.get_viewport().get_texture().get_image().save_png(out.path_join("rest_zzz.png"))
	print("=== live click test: %d failure(s) ===" % fails)
	quit(1 if fails > 0 else 0)
