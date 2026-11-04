extends SceneTree
## The ring trend follows the hex the formation is VISUALLY on (leaving the radius shows the drain at once).
func _init() -> void:
	var shell: Node = (load("res://scenes/step2r_battlefield_shell.tscn") as PackedScene).instantiate()
	shell.set("battlefield_id", "EDITOR_M1")
	shell.set("no_fog", true)
	root.add_child(shell)
	for i in 150:
		await process_frame
	var um = shell.get("unit_manager")
	var view = shell.get("_view3d")
	var id := "B_SCOUT_2"
	var u: Dictionary = um._units[id]
	var o := Vector2i(int(u["q"]), int(u["r"]))
	var env_dest := Vector2i(-999, -999)
	var best_dest_zone := ""
	um.call("select_unit", id)
	await process_frame
	var env = shell.get("_current_envelope")
	var HexU = load("res://scripts/core/hex_utils.gd")
	var start_zone: String = um.supply_v2.zone_of(um._units, "blue", o.x, o.y)
	for c in env.reachable_data:
		var z: String = um.supply_v2.zone_of(um._units, "blue", c.x, c.y)
		if z != start_zone:
			env_dest = c
			best_dest_zone = z
			break
	print("[T] start ", o, " zone ", start_zone, " -> dest ", env_dest, " zone ", best_dest_zone)
	shell.call("_handle_hex_click", env_dest, HexU.hex_to_pixel(env_dest.x, env_dest.y))
	shell.call("_execute_confirmed_move")
	var first_change := -1
	var arrive := -1
	var last_tr: int = int(view._units[id].get("m_trend", 99))
	var tr0: int = last_tr
	for f in 900:
		await process_frame
		var tr: int = int(view._units[id].get("m_trend", 99))
		if tr != last_tr and first_change < 0:
			first_change = f
			print("[T] trend changed ", last_tr, " -> ", tr, " at frame ", f, " logical hex ", Vector2i(int(u["q"]), int(u["r"])), " animating ", shell.get("_is_animating_movement"))
		last_tr = tr
		if not bool(shell.get("_is_animating_movement")) and arrive < 0 and f > 5:
			arrive = f
	print("[T] first trend change frame ", first_change, " movement finished frame ", arrive, " (start trend ", tr0, ")")
	quit(0)
