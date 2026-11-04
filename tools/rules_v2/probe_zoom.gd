extends SceneTree
func _init() -> void:
	var shell: Node = (load("res://scenes/step2r_battlefield_shell.tscn") as PackedScene).instantiate()
	shell.set("battlefield_id", "EDITOR_M1")
	shell.set("no_fog", true)
	root.add_child(shell)
	for i in 120:
		await process_frame
	var view = shell.get("_view3d")
	var cam = shell.get("camera")
	var HexU = load("res://scripts/core/hex_utils.gd")
	var um = shell.get("unit_manager")
	var hq: Dictionary = um._units["B_HQ"]
	var h1 := Vector2i(int(hq["q"]), int(hq["r"]))
	var h2 := Vector2i(-6, -7)
	print("[Z] HQ ", h1, " village ", h2)
	for z in [0.3, 0.5, 0.7, 0.9, 1.0, 1.1, 1.3]:
		cam.call("set_zoom_level", z, true)
		cam.call("focus_on", (HexU.hex_to_pixel(h1.x, h1.y) + HexU.hex_to_pixel(h2.x, h2.y)) * 0.5, true)
		await create_timer(0.6).timeout
		var a: Vector2 = view.world_to_screen(HexU.hex_to_pixel(h1.x, h1.y))
		var b: Vector2 = view.world_to_screen(HexU.hex_to_pixel(h2.x, h2.y))
		print("[Z] zoom ", z, " HQ-village screen dist ", snappedf(a.distance_to(b), 0.1))
	quit(0)
