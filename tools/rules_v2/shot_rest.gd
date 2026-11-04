extends SceneTree
## Shows a unit outside the healing radius selected: the radius tint and the "휴식 불가" reason.
func _init() -> void:
	var out := OS.get_cmdline_user_args()[0]
	var shell: Node = (load("res://scenes/step2r_battlefield_shell.tscn") as PackedScene).instantiate()
	shell.set("battlefield_id", "EDITOR_M1")
	shell.set("no_fog", true)
	root.add_child(shell)
	for i in 150:
		await process_frame
	var um = shell.get("unit_manager")
	um.call("select_unit", "B_CONS_1")
	for i in 60:
		await process_frame
	print("[REST] why: ", um.v2_rest_block("B_CONS_1"))
	root.get_viewport().get_texture().get_image().save_png(out.path_join("rest_radius.png"))
	quit(0)
