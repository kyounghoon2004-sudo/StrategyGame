extends SceneTree

## Verify _on_preset_execute: one-click preview+execute through the real handler.

const OUT := "D:/Game development/Demon slayer/StrategyGame/evidence/step7_exec_button.json"

var _finished: Dictionary = {}
var _got_finish := false


func _init() -> void:
	call_deferred("_run")


func _on_finish(res: Dictionary) -> void:
	_finished = res
	_got_finish = true


func _run() -> void:
	var out := {}
	var packed: PackedScene = load("res://scenes/step2r_battlefield_shell.tscn")
	var battle: Node = packed.instantiate()
	get_root().add_child(battle)
	for _i in range(20):
		await process_frame
	var integration: Node = battle.get_node_or_null("Step7Integration")
	for _i in range(180):
		if integration and bool(integration.get("ready_for_step7")):
			break
		await process_frame
	if integration == null:
		out = {"status": "FAIL", "reason": "integration missing"}
		_write(out)
		quit(2)
		return
	var svc: RefCounted = integration.get("action_service")
	var cav := {}
	for row in svc.call("get_manual_presets"):
		if row is Dictionary and str((row as Dictionary).get("id", "")) == "ADVANCE_CAVALRY_RIGHT":
			cav = (row as Dictionary).get("command", {})
	svc.connect("execution_finished", Callable(self, "_on_finish"))
	integration.call("_on_preset_execute", cav)
	var frames := 0
	while not _got_finish and frames < 6000:
		await process_frame
		frames += 1
	out["finished"] = _got_finish
	if _got_finish:
		out["status_line"] = str(_finished.get("execution_status", "?"))
		out["executed"] = (_finished.get("executed_units", []) as Array).size()
		out["unexplained"] = int(_finished.get("unexplained_count", -1))
		out["version_after"] = int(_finished.get("resulting_state_version", -1))
	out["status"] = "PASS" if _got_finish and str(_finished.get("execution_status", "")) == "EXECUTED" and (_finished.get("executed_units", []) as Array).size() == 4 else "FAIL"
	_write(out)
	print("EXECBTN_" + str(out["status"]))
	quit(0 if str(out["status"]) == "PASS" else 2)


func _write(out: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute((OUT as String).get_base_dir())
	var file := FileAccess.open(OUT, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(out, "  "))
