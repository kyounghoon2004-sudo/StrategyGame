extends SceneTree

## Movement regression matrix (slice 4). One fresh boot, three phases:
## A. every catalog preset is structurally valid; CLASS presets resolve
##    only their class; the original 7 commands are byte-identical.
## B. cavalry executes 4/4 with unique final hexes, version 0 -> 4.
## C. HOLD_ALL executes the rest; same-turn cavalry is UNIT_NOT_READY;
##    stale/unknown plan ids behave.

const OUT := "D:/Game development/Demon slayer/StrategyGame/evidence/step7_movement_matrix.json"

var failures: Array = []
var notes: Array = []
var _finished: Dictionary = {}
var _got_finish := false


func _init() -> void:
	call_deferred("_run")


func _check(cond: bool, name: String) -> void:
	if cond:
		notes.append("PASS " + name)
	else:
		failures.append(name)


func _on_finish(res: Dictionary) -> void:
	_finished = res
	_got_finish = true


func _struct_ok(r: Dictionary) -> bool:
	for e in r.get("validation_errors", []):
		if e is Dictionary and str((e as Dictionary).get("code", "")) in ["UNKNOWN_ACTION", "INVALID_SCOPE", "INVALID_TARGET", "TARGET_NOT_FOUND", "INVALID_DIRECTION"]:
			return false
	return true


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
	var truth: RefCounted = integration.get("truth")
	var um: RefCounted = integration.get("unit_manager")

	# ---- Phase A: catalog validity + purity + original-7 frozen ----
	var presets: Array = svc.call("get_manual_presets")
	# Catalog size follows the canonical PRESET_ORDER (grew 38 -> 50 as
	# verbs/classes were added); the frozen original-7 rows below guard
	# meaning, this guards accidental loss.
	var AC = load("res://scripts/step7/step7_action_command.gd")
	_check(presets.size() == (AC.PRESET_ORDER as Array).size(),
		"catalog matches canonical order (%d, got %d)" % [(AC.PRESET_ORDER as Array).size(), presets.size()])
	var by_id := {}
	for row in presets:
		if row is Dictionary:
			by_id[str((row as Dictionary).get("id", ""))] = row
	var expected7 := {
		"ADVANCE_ALL_NORTH": {"action": "ADVANCE", "scope": {"type": "ALL_AVAILABLE"}, "direction": "NORTH"},
		"ADVANCE_CAVALRY_RIGHT": {"action": "ADVANCE", "scope": {"type": "CLASS", "class": "CAVALRY"}, "direction": "RIGHT"},
		"FLANK_CAVALRY_RIGHT": {"action": "FLANK", "scope": {"type": "CLASS", "class": "CAVALRY"}, "direction": "RIGHT"},
		"RECON_SCOUT_NORTH": {"action": "RECON", "scope": {"type": "CLASS", "class": "SCOUT"}, "direction": "NORTH"},
		"HOLD_ALL": {"action": "HOLD", "scope": {"type": "ALL_AVAILABLE"}, "direction": ""},
		"RETREAT_ALL": {"action": "RETREAT", "scope": {"type": "ALL_AVAILABLE"}, "direction": "WEST"},
		"RETREAT_INFANTRY": {"action": "RETREAT", "scope": {"type": "CLASS", "class": "INFANTRY"}, "direction": "WEST"},
	}
	for pid in expected7.keys():
		_check(by_id.has(pid), "original preset present: %s" % pid)
		if by_id.has(pid):
			var got: Dictionary = (by_id[pid] as Dictionary).get("command", {})
			var exp: Dictionary = expected7[pid]
			_check(str(got.get("action", "")) == str(exp.get("action", "")) and str(got.get("direction", "")) == str(exp.get("direction", "")) and (got.get("scope", {}) as Dictionary) == (exp.get("scope", {}) as Dictionary), "original preset frozen: %s" % pid)
	var struct_bad: Array = []
	var purity_bad: Array = []
	for row in presets:
		if not (row is Dictionary):
			continue
		var pid := str((row as Dictionary).get("id", "?"))
		var cmd: Dictionary = (row as Dictionary).get("command", {})
		var r: Dictionary = svc.call("validate_action", cmd, "blue")
		if not _struct_ok(r):
			struct_bad.append(pid)
			continue
		var scope: Dictionary = cmd.get("scope", {})
		if str(scope.get("type", "")) == "CLASS":
			var want := str(scope.get("class", ""))
			for a in r.get("resolved_units", []):
				if a is Dictionary and str((a as Dictionary).get("class", "")) != want:
					purity_bad.append("%s resolved %s" % [pid, str((a as Dictionary).get("unit_id", "?"))])
	_check(struct_bad.is_empty(), "all presets structurally valid (bad: %s)" % str(struct_bad))
	_check(purity_bad.is_empty(), "CLASS presets resolve only their class (bad: %s)" % str(purity_bad))

	# ---- Phase B: cavalry executes with unique finals, 0 -> 4 ----
	var cav_cmd: Dictionary = (by_id["ADVANCE_CAVALRY_RIGHT"] as Dictionary).get("command", {})
	var before := {}
	for u_val in um.call("get_all_units_including_garrisoned"):
		if u_val is Dictionary:
			before[str((u_val as Dictionary).get("id", ""))] = [int((u_val as Dictionary).get("q", 0)), int((u_val as Dictionary).get("r", 0))]
	integration.call("_on_preset", cav_cmd)
	var plan_id := str(integration.get("_preview_plan_id"))
	_check(not plan_id.is_empty(), "cavalry preset arms a plan")
	svc.connect("execution_finished", Callable(self, "_on_finish"))
	_got_finish = false
	integration.call("_on_execute")
	var frames := 0
	while not _got_finish and frames < 6000:
		await process_frame
		frames += 1
	_check(_got_finish, "cavalry execution finished")
	if _got_finish:
		_check(str(_finished.get("execution_status", "")) == "EXECUTED", "cavalry EXECUTED")
		_check(int(_finished.get("unexplained_count", -1)) == 0, "cavalry unexplained == 0")
		var finals := {}
		var dup := false
		var noncav_moved := false
		for u_val in um.call("get_all_units_including_garrisoned"):
			if u_val is Dictionary:
				var u: Dictionary = u_val
				var key := "%d,%d" % [int(u.get("q", 0)), int(u.get("r", 0))]
				if str(u.get("faction", "")) == "blue" and not bool(u.get("garrisoned", false)):
					if finals.has(key):
						dup = true
					finals[key] = true
				var old: Array = before.get(str(u.get("id", "")), [])
				var now := [int(u.get("q", 0)), int(u.get("r", 0))]
				if not old.is_empty() and old != now and not str(u.get("id", "")).begins_with("B_CAV"):
					noncav_moved = true
		_check(not dup, "no duplicate blue final hexes")
		_check(not noncav_moved, "no non-cavalry moved")
		_check(int(_finished.get("resulting_state_version", -1)) == 4, "version 0 -> 4 (got %s)" % str(_finished.get("resulting_state_version", "?")))

	# ---- Phase C: HOLD_ALL the rest; same-turn cavalry rejected; plan ids ----
	_got_finish = false
	var hold_cmd: Dictionary = (by_id["HOLD_ALL"] as Dictionary).get("command", {})
	integration.call("_on_preset", hold_cmd)
	integration.call("_on_execute")
	frames = 0
	while not _got_finish and frames < 12000:
		await process_frame
		frames += 1
	_check(_got_finish and int(_finished.get("unexplained_count", -1)) == 0, "HOLD_ALL completes with unexplained == 0")
	var cav2: Dictionary = svc.call("preview_action", cav_cmd, "blue")
	var all_notready := true
	for r in cav2.get("rejected_units", []):
		if r is Dictionary and str((r as Dictionary).get("code", "")) != "UNIT_NOT_READY":
			all_notready = false
	_check(not bool(cav2.get("ok", false)) and all_notready, "same-turn cavalry all UNIT_NOT_READY")
	var unk: Dictionary = svc.call("execute_plan", "NO_SUCH_PLAN")
	_check(not bool(unk.get("ok", false)), "unknown plan id rejected")
	var c: Dictionary = svc.call("preview_action", hold_cmd, "blue")
	var cpid := str(c.get("plan_id", ""))
	if not cpid.is_empty():
		var cancelled: Dictionary = svc.call("cancel_plan", cpid)
		_check(bool(cancelled.get("ok", false)), "cancel_plan clears an armed plan")

	_write()
	print("MATRIX_" + ("PASS" if failures.is_empty() else "FAIL") + " (%d/%d)" % [notes.size(), notes.size() + failures.size()])
	quit(0 if failures.is_empty() else 2)


func _write() -> void:
	DirAccess.make_dir_recursive_absolute((OUT as String).get_base_dir())
	var file := FileAccess.open(OUT, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify({"status": "PASS" if failures.is_empty() else "FAIL", "failures": failures, "notes": notes}, "  "))
