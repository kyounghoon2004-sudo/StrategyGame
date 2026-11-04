extends SceneTree
## Fog must follow the marching formation, not the order. godot --path . --script res://tools/rules_v2/test_fog_follow.gd

var fails := 0
func check(name: String, ok: bool, extra: String = "") -> void:
	print(("PASS " if ok else "FAIL ") + name + ((" | " + extra) if extra != "" else ""))
	if not ok: fails += 1

func _init() -> void:
	var shell: Node = (load("res://scenes/step2r_battlefield_shell.tscn") as PackedScene).instantiate()
	shell.set("battlefield_id", "EDITOR_M1")
	root.add_child(shell)
	for i in 150:
		await process_frame
	var um = shell.get("unit_manager")
	var view = shell.get("_view3d")
	var fog = shell.get("_fog")
	var HexU = load("res://scripts/core/hex_utils.gd")
	var id := "B_SCOUT_1"
	var u: Dictionary = um._units[id]
	um.call("select_unit", id)
	for i in 20:
		await process_frame
	var o := Vector2i(int(u["q"]), int(u["r"]))
	var env = shell.get("_current_envelope")
	var dest := Vector2i(-999, -999)
	var best := -1
	for c in env.reachable_data:
		var d: int = max(abs(c.x - o.x), abs(c.y - o.y), abs(c.x + c.y - o.x - o.y))
		if d > best:
			best = d
			dest = c
	# a hex that only becomes visible once the scout stands near the destination
	var far := Vector2i(-999, -999)
	for dq in range(-4, 5):
		for dr in range(-4, 5):
			var h := dest + Vector2i(dq, dr)
			var dd: int = max(abs(h.x - o.x), abs(h.y - o.y), abs(h.x + h.y - o.x - o.y))
			if max(abs(dq), abs(dr), abs(dq + dr)) == 3 and dd > 5 and fog.get_fog_state(h.x, h.y) == 0:
				far = h
	var sim = load("res://scripts/step5/fog_of_war.gd").new()
	sim.normal_vision = fog.normal_vision
	sim.scout_vision = fog.scout_vision
	var fr: Array = []
	var cu: Dictionary = u.duplicate()
	cu["q"] = dest.x
	cu["r"] = dest.y
	fr.append(cu)
	sim.recompute(fr, [], shell.get("hex_grid").get("cell_data"), 0)
	far = Vector2i(-999, -999)
	for k in sim.visible.keys():
		var pp: PackedStringArray = str(k).split(",")
		var h := Vector2i(int(pp[0]), int(pp[1]))
		var dd2: int = max(abs(h.x - o.x), abs(h.y - o.y), abs(h.x + h.y - o.x - o.y))
		if dd2 > 5 and fog.get_fog_state(h.x, h.y) == 0:
			far = h
	print("[T] scout ", o, " -> ", dest, " dist ", best, " probe hex ", far)
	check("probe hex is unexplored before the move", fog.get_fog_state(far.x, far.y) == 0)
	shell.call("_handle_hex_click", dest, HexU.hex_to_pixel(dest.x, dest.y))
	shell.call("_execute_confirmed_move")
	for i in 3:
		await process_frame
	print("[T] after confirm unit at ", Vector2i(int(u["q"]), int(u["r"])), " preview ", shell.get("_preview_target_hex"), " visible hexes ", fog.visible.size(), " view tgt size ", view._fow_tgt.size())
	var key := "%d,%d" % [far.x, far.y]
	var S := 0.1875
	var dp: Vector2 = HexU.hex_to_pixel(dest.x, dest.y)
	var f_logic := -1
	var f_view := -1
	var d_at_logic := -1.0
	var d_at_view := -1.0
	for f in 2400:
		await process_frame
		var rn: Node3D = view._units[id]["root"]
		var dist: float = Vector2(rn.position.x - dp.x * S, rn.position.z - dp.y * S).length()
		if f_logic < 0 and fog.get_fog_state(far.x, far.y) >= 1:
			f_logic = f
			d_at_logic = dist
		if f % 300 == 0:
			print("[T] f=", f, " dist ", snappedf(dist, 0.01), " tgt ", view._fow_tgt.get(key, 0.0), " tgt size ", view._fow_tgt.size(), " vis_fog ", view._vis_fog != null)
		if f_view < 0 and float(view._fow_tgt.get(key, 0.0)) > 0.99:
			f_view = f
			d_at_view = dist
		if f_view >= 0 and f_logic >= 0 and f > f_view + 20:
			break
	print("[T] logical fog lit at frame ", f_logic, " (formation ", snappedf(d_at_logic, 0.01), " from the hex centre); view lit at frame ", f_view, " (", snappedf(d_at_view, 0.01), " away)")
	check("both eventually light the probe hex", f_logic >= 0 and f_view >= 0)
	check("view never lights before the logical fog", f_view >= f_logic)
	check("view lights only once the formation steps into the hex", d_at_view >= 0.0 and d_at_view <= 4.2, str(d_at_view))
	check("the formation was still walking when the logical fog lit (the old bug)", d_at_logic > 1.2, str(d_at_logic))
	print("=== fog follow test: %d failure(s) ===" % fails)
	quit(1 if fails > 0 else 0)
