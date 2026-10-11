extends SceneTree

## Narrow regression gate for the class-scope INVALID report.
## A. CLASS preset with blank Q/R must NOT fail on Q/R (via real _on_preset).
## B. MOVE arm with blank Q/R MUST fail input validation AND arm no plan.
## C. CLASS:CAVALRY must resolve only cavalry.
## D. ALL_AVAILABLE control must stay VALID.
## E. A failed MOVE arm must not leave a stale READY plan armed (transactional panel).

const OUT := "D:/Game development/Demon slayer/StrategyGame/evidence/step7_class_scope_regression.json"

var failures: Array = []
var notes: Array = []


func _init() -> void:
	call_deferred("_run")


func _check(cond: bool, name: String) -> void:
	if cond:
		notes.append("PASS " + name)
	else:
		failures.append(name)


func _run() -> void:
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
		failures.append("integration missing")
		_write()
		quit(2)
		return
	var svc: RefCounted = integration.get("action_service")
	var um: RefCounted = integration.get("unit_manager")
	var labels: Dictionary = integration.get("_status_labels")
	var CmdScript = load("res://scripts/step7/step7_action_command.gd")
	var presets: Dictionary = CmdScript.presets()
	var cav_cmd: Dictionary = (presets["ADVANCE_CAVALRY_RIGHT"] as Dictionary)["command"]

	# A: blank Q/R + cavalry preset through the real button callback.
	(integration.get("_q_edit") as LineEdit).text = ""
	(integration.get("_r_edit") as LineEdit).text = ""
	integration.call("_on_preset", cav_cmd)
	_check((labels["validation"] as Label).text.begins_with("Validation: VALID"), "A preset with blank Q/R validates (got: %s)" % (labels["validation"] as Label).text.left(60))
	_check(not str(integration.get("_preview_plan_id")).is_empty(), "A preset with blank Q/R arms a plan")

	# C: cavalry scope purity through the real service.
	var cav: Dictionary = svc.call("preview_action", cav_cmd, "blue")
	var classes := {}
	for a in cav.get("resolved_units", []):
		if a is Dictionary:
			classes[str((a as Dictionary).get("class", "?"))] = true
	_check(bool(cav.get("ok", false)) and classes.keys() == ["CAVALRY"], "C cavalry resolves only cavalry (got: %s)" % str(classes.keys()))
	var cand_ok := true
	for c in cav.get("candidate_units", []):
		if c is Dictionary and str((c as Dictionary).get("class", "")) != "CAVALRY":
			cand_ok = false
	_check(cand_ok, "C cavalry candidates contain no non-cavalry")

	# D: ALL_AVAILABLE control.
	var all_cmd: Dictionary = (presets["ADVANCE_ALL_NORTH"] as Dictionary)["command"]
	var all_prev: Dictionary = svc.call("preview_action", all_cmd, "blue")
	_check(bool(all_prev.get("ok", false)) and not (all_prev.get("resolved_units", []) as Array).is_empty(), "D ALL_AVAILABLE stays VALID")

	# B + E: select a unit, blank Q/R, MOVE arm must fail AND clear stale plan.
	um.call("select_unit", "B_CAV_1")
	(integration.get("_q_edit") as LineEdit).text = ""
	(integration.get("_r_edit") as LineEdit).text = ""
	integration.call("_on_arm_move")
	_check((labels["validation"] as Label).text.contains("Q and R must be integers"), "B blank Q/R MOVE fails input validation")
	_check(str(integration.get("_preview_plan_id")).is_empty(), "E failed MOVE arm leaves no stale plan armed")
	_check((labels["action"] as Label).text.contains("MOVE"), "E failed MOVE arm owns the action label (got: %s)" % (labels["action"] as Label).text.left(60))
	_check((labels["plan"] as Label).text.contains("NO_PLAN"), "E failed MOVE arm shows NO_PLAN")

	_write()
	print("DET_CLASSREGRESSION_" + ("PASS" if failures.is_empty() else "FAIL"))
	quit(0 if failures.is_empty() else 2)


func _write() -> void:
	DirAccess.make_dir_recursive_absolute((OUT as String).get_base_dir())
	var file := FileAccess.open(OUT, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify({"status": "PASS" if failures.is_empty() else "FAIL", "failures": failures, "notes": notes}, "  "))
