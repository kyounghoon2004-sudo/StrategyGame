extends SceneTree
func _init() -> void:
	call_deferred("_run")
func _run() -> void:
	var sc: Node = (load("res://scenes/step2r_battlefield_shell.tscn") as PackedScene).instantiate()
	sc.set("is_step0_sandbox", true)
	root.add_child(sc)
	for i in range(240):
		await process_frame
	print("BOUNDS ", JSON.stringify(sc.call("map_bounds")))
	var um = sc.get("unit_manager")
	for u in um.get_all_units():
		if str(u.get("class", "")) == "hq":
			print("HQ ", u.get("id"), " ", u.get("q"), ",", u.get("r"))
	quit(0)
