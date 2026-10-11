extends SceneTree

## DEV panel flow probe: simulates the exact button callbacks a human
## presses (preset -> EXECUTE, MOVE arm -> EXECUTE, CANCEL) against a
## freshly booted battle. No vision needed; asserts state transitions.

const OUT := "D:/Game development/Demon slayer/StrategyGame/evidence/step7_det_panel.json"

var failures: Array = []
var notes: Array = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var packed: PackedScene = load("res://scenes/step2r_battlefield_shell.tscn")
	var battle: Node = packed.instantiate()
	get_root().add_child(battle)
	for _i in range(20):
		await process_frame
	var integration: Node = battle.get_node_or_null("Step7Integration")
	for _i in range(120):
		if integration and bool(integration.get("ready_for_step7")):
			break
		await process_frame
	if integration == null:
		failures.append("integration missing")
		_write()
		quit(2)
		return
	var svc: RefCounted = integration.get("action_service")
	var truth: RefCounted = integration.get("truth")
	var overlay: Node = integration.get("overlay")
	_check(overlay != null, "preview overlay exists")
	_check(integration.get("_panel") != null, "DEV panel built")
	# Human flow 1: select a unit, type a hex, MOVE UNIT -> EXECUTE.
	# Runs first on a fresh turn while formations are still unacted.
	var um: RefCounted = integration.get("unit_manager")
	var moved_id := ""
	if um != null and um.has_method("select_unit"):
		var probe: Dictionary = svc.call("validate_action", {"action": "HOLD", "scope": {"type": "ALL_AVAILABLE"}, "direction": "", "target": {}, "posture": "NORMAL", "constraints": {}}, "blue")
		for a in probe.get("resolved_units", []):
			if a is Dictionary:
				moved_id = str((a as Dictionary).get("unit_id", ""))
				break
	var arm_ok := false
	if not moved_id.is_empty() and bool(um.call("select_unit", moved_id)):
		var before: Dictionary = truth.call("get_unit", moved_id)
		var cmd_svc: RefCounted = integration.get("command_service")
		var area: Dictionary = cmd_svc.call("reachable_area", moved_id, "blue", "auto")
		var origin := Vector2i(int(before.get("q", 0)), int(before.get("r", 0)))
		var dest := Vector2i(-9999, -9999)
		for e in area.get("reachable", []):
			if e is Dictionary:
				var cell := Vector2i(int((e as Dictionary).get("q", -9999)), int((e as Dictionary).get("r", -9999)))
				if cell != origin:
					dest = cell
					break
		if dest.x != -9999:
			(integration.get("_q_edit") as LineEdit).text = str(dest.x)
			(integration.get("_r_edit") as LineEdit).text = str(dest.y)
			integration.call("_on_arm_move")
			arm_ok = not str(integration.get("_preview_plan_id")).is_empty()
			if arm_ok:
				integration.call("_on_execute")
				var after: Dictionary = truth.call("get_unit", moved_id)
				arm_ok = Vector2i(int(after.get("q", -99)), int(after.get("r", -99))) == dest
	_check(arm_ok, "MOVE flow moves exactly the selected unit (id=%s)" % moved_id)
	# Human flow 2: click ADVANCE_ALL_NORTH -> CANCEL leaves world untouched.
	var adv: Dictionary = {}
	for row in svc.call("get_manual_presets"):
		if str((row as Dictionary).get("id", "")) == "ADVANCE_ALL_NORTH":
			adv = (row as Dictionary).get("command", {})
	integration.call("_on_preset", adv)
	_check(not str(integration.get("_preview_plan_id")).is_empty(), "preset arms a plan")
	_check(not (overlay.get("routes") as Array).is_empty(), "preset draws preview routes")
	var v1: int = truth.call("get_version")
	integration.call("_on_cancel")
	_check(str(integration.get("_preview_plan_id")).is_empty() and (overlay.get("routes") as Array).is_empty() and int(truth.call("get_version")) == v1, "CANCEL clears preview without mutation")
	# Human flow 3: arm again -> EXECUTE bumps the version.
	integration.call("_on_preset", adv)
	var v0: int = truth.call("get_version")
	integration.call("_on_execute")
	_check(str(integration.get("_preview_plan_id")).is_empty(), "execute clears armed plan")
	_check(int(truth.call("get_version")) == v0 + 1, "execute bumps state version")
	_write()
	print("DET_PANEL_" + ("PASS" if failures.is_empty() else "FAIL"))
	quit(0 if failures.is_empty() else 2)


func _check(cond: bool, name: String) -> void:
	if cond:
		notes.append("PASS " + name)
	else:
		failures.append(name)


func _write() -> void:
	DirAccess.make_dir_recursive_absolute((OUT as String).get_base_dir())
	var file := FileAccess.open(OUT, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify({"status": "PASS" if failures.is_empty() else "FAIL", "failures": failures, "notes": notes}, "  "))
