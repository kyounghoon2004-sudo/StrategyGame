extends SceneTree

## Launch with SYMLOC_BRAIN_PROVIDER=ollama and SYMLOC_BRAIN_ENDPOINT pointing
## at utility_bot_brain_stub.py. Exercises real Cloud2 parsing and shell handoff.
const BattleScene = preload("res://scenes/brain_utility_battle_test.tscn")
const OUT_PATH := "res://artifacts/utility_bot_v0/brain_scene_smoke.json"
const TIMEOUT_MS := 60000


func _initialize() -> void:
	OS.set_environment("UTILITY_BOT_SEED", "42")
	call_deferred("_run")


func _run() -> void:
	var scene := BattleScene.instantiate()
	root.add_child(scene)
	current_scene = scene
	var deadline := Time.get_ticks_msec() + TIMEOUT_MS
	var mount: Node = scene.get_node_or_null("BrainUtilityMount")
	var shell: Node = scene.get_node_or_null("Battle")
	while Time.get_ticks_msec() < deadline:
		if mount != null and bool(mount.get("mount_ready")) and shell != null:
			var utility := mount.get("utility_controller") as Node
			var phase: Dictionary = utility.get("last_phase_result") as Dictionary if utility != null else {}
			if int(phase.get("actions", 0)) > 0 and int((shell.get("unit_manager") as RefCounted).call("get_current_turn")) >= 2:
				break
		if mount != null and not str(mount.get("mount_error")).is_empty():
			break
		await process_frame
	var utility := mount.get("utility_controller") as Node if mount != null else null
	var brain := mount.get("brain_controller") as Node if mount != null else null
	var phase: Dictionary = utility.get("last_phase_result") as Dictionary if utility != null else {}
	var turn := int((shell.get("unit_manager") as RefCounted).call("get_current_turn")) if shell != null and shell.get("unit_manager") != null else 0
	var brain_plan_bound := bool((brain.get("_manager") as RefCounted).call("vp_has_plan")) if brain != null and brain.get("_manager") != null else false
	var expect_valid := OS.get_environment("UTILITY_BRAIN_STUB_EXPECT_VALID") == "1"
	var passed := mount != null and bool(mount.get("mount_ready")) and turn >= 2 \
		and bool(phase.get("ok", false)) and int(phase.get("actions", 0)) > 0 \
		and brain != null and str(brain.get_script().resource_path).ends_with("brain_utility_blue_controller.gd")
	if expect_valid:
		passed = passed and brain_plan_bound
	var record := {"pass": passed, "mount_ready": bool(mount.get("mount_ready")) if mount != null else false,
		"mount_error": str(mount.get("mount_error")) if mount != null else "missing_mount",
		"turn": turn, "red_phase": phase,
		"expect_valid": expect_valid, "brain_plan_bound": brain_plan_bound,
		"blue_controller_script": str(brain.get_script().resource_path) if brain != null else ""}
	var file := FileAccess.open(OUT_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(record, "\t") + "\n")
		file.close()
	print("UTILITY_BRAIN_SCENE_SMOKE " + JSON.stringify(record))
	quit(0 if passed else 1)
