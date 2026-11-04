extends SceneTree
## Plays M1 headless with a passive blue (end-turn only) and the default red AI.
## godot --headless --path . --script res://tools/rules_v2/run_m1_headless.gd

func _init() -> void:
	var packed: PackedScene = load("res://scenes/step2r_battlefield_shell.tscn")
	var shell: Node = packed.instantiate()
	var bf := "M1"
	if OS.get_cmdline_user_args().size() > 0:
		bf = OS.get_cmdline_user_args()[0]
	shell.set("battlefield_id", bf)
	root.add_child(shell)
	await process_frame
	await process_frame
	var um = shell.get("unit_manager")
	print("[RUN] units=%d v2=%s" % [um.get_all_units().size(), str(load("res://scripts/rules_v2/rules_v2.gd").enabled)])
	if load("res://scripts/rules_v2/rules_v2.gd").enabled:
		print("[RUN] base: ", um.v2_place_base("blue").get("success"))
	var rounds := 8
	if OS.get_cmdline_user_args().size() > 1:
		rounds = int(OS.get_cmdline_user_args()[1])
	for round in rounds:
		if shell.call("_battle_over"):
			break
		shell.call("end_player_phase")
		var guard := 0
		while int(shell.get("_turn_phase")) != 0 and guard < 600:
			await process_frame
			guard += 1
		_dump(um, round + 1)
	print("[RUN] over=%s won=%s lost=%s" % [str(shell.call("_battle_over")), str(shell.get("_battle_won")), str(shell.get("_battle_lost"))])
	quit(0)

func _dump(um, rnd: int) -> void:
	var parts: Array = []
	for u in um.get_all_units():
		parts.append("%s:%d/%d m%.0f %s" % [u["id"], int(u["soldier_count"]), int(u.get("max_count", 0)), float(u["morale"]), str(u.get("supply_zone", "-"))])
	print("[RUN] round %d | %s" % [rnd, " | ".join(parts)])
