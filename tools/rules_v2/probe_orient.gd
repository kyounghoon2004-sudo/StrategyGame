extends SceneTree
func _init() -> void:
	var shell: Node = (load("res://scenes/step2r_battlefield_shell.tscn") as PackedScene).instantiate()
	shell.set("battlefield_id", "EDITOR_M1")
	root.add_child(shell)
	for i in 60: await process_frame
	var r = shell.get("unit_renderer")
	r.call("spawn_unit", "T_QPOS", "infantry", "blue", 12, 0, 50, "form_a")
	r.call("spawn_unit", "T_QNEG", "infantry", "red", -12, 0, 50, "form_a")
	r.call("spawn_unit", "T_RPOS", "cavalry", "blue", 0, 12, 50, "form_a")
	r.call("spawn_unit", "T_RNEG", "cavalry", "red", 0, -12, 50, "form_a")
	r.call("spawn_unit", "T_HALL", "archer", "blue", 6, 7, 50, "form_a")
	for i in 120: await process_frame
	root.get_viewport().get_texture().get_image().save_png(OS.get_cmdline_user_args()[0])
	quit(0)
