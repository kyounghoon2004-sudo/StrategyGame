extends SceneTree

const BattleScene = preload("res://scenes/utility_bot_battle_test.tscn")
const OUT_PATH := "res://artifacts/utility_bot_v1/live_phase_smoke.json"
const TIMEOUT_MS := 45000


func _initialize() -> void:
	OS.set_environment("UTILITY_BOT_SEED", "42")
	root.set_meta("utility_bot_dev_difficulty", "V1")
	call_deferred("_run")


func _run() -> void:
	var scene := BattleScene.instantiate()
	root.add_child(scene)
	current_scene = scene
	var deadline := Time.get_ticks_msec() + TIMEOUT_MS
	var shell: Node
	var mount: Node
	var controller: Node
	while Time.get_ticks_msec() < deadline:
		shell = scene.get_node_or_null("Battle")
		mount = scene.get_node_or_null("UtilityBotMount")
		controller = mount.get_node_or_null("UtilityBotLiveController") if mount != null else null
		if controller != null and bool(controller.get("mount_ready")):
			break
		await process_frame
	var record: Dictionary = {"seed": 42, "status": "FAILED", "error": "mount_timeout"}
	if controller != null and bool(controller.get("mount_ready")) and shell != null:
		var legal_enum: RefCounted = controller.get("enumerator") as RefCounted
		var unresolved: Array = legal_enum.call("unresolved_units")
		var first_id := str((unresolved[0] as Dictionary).get("id", "")) if not unresolved.is_empty() else ""
		var first_pool: Dictionary = legal_enum.call("enumerate_for_unit", first_id) if not first_id.is_empty() else {}
		print("UTILITY_LIVE_PHASE_READY red_unresolved=%d first=%s candidates=%d error=%s" % [unresolved.size(), first_id, (first_pool.get("candidates", []) as Array).size(), str(first_pool.get("error", ""))])
		# Launch the normal authoritative handoff, then wait for its coroutine.
		shell.call("end_player_phase")
		var saw_busy := false
		while Time.get_ticks_msec() < deadline:
			var phase_result_now: Dictionary = controller.get("last_phase_result") as Dictionary
			saw_busy = saw_busy or bool(controller.get("_busy"))
			if saw_busy and not bool(controller.get("_busy")) \
					and int(phase_result_now.get("actions", 0)) > 0:
				break
			await process_frame
		var phase_result: Dictionary = controller.get("last_phase_result") as Dictionary
		record = {
			"seed": 42,
			"status": "PASS" if bool(phase_result.get("ok", false)) and int(phase_result.get("actions", 0)) > 0 else "FAIL",
			"phase_result": phase_result,
			"turn": int((shell.get("unit_manager") as RefCounted).call("get_current_turn")),
			"turn_phase": int(shell.get("_turn_phase")),
			"red_controller_mode": str(shell.call("red_controller_mode")),
			"enemy_routine_runs": int(shell.call("enemy_routine_runs")),
		}
	var absolute_path := ProjectSettings.globalize_path(OUT_PATH)
	DirAccess.make_dir_recursive_absolute(absolute_path.get_base_dir())
	var file := FileAccess.open(OUT_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(record, "\t") + "\n")
		file.close()
	print("UTILITY_LIVE_PHASE_SMOKE " + JSON.stringify(record))
	quit(0 if str(record.get("status", "")) == "PASS" else 1)
