extends SceneTree

## SLICE 1 (RED): canonical movement grammar, driven ONLY through live
## service objects (this headless console hangs on bare static/script calls
## from the main-loop script; instance calls on live objects work reliably).
## Commands are plain Dictionaries; svc.validate_action is the oracle.
## Expected: FAIL before implementation (UNKNOWN_ACTION / INVALID_SCOPE).

const OUT := "D:/Game development/Demon slayer/StrategyGame/evidence/step7_slice1_grammar.json"

var failures: Array = []
var notes: Array = []


func _init() -> void:
	call_deferred("_run")


func _check(cond: bool, name: String) -> void:
	if cond:
		notes.append("PASS " + name)
	else:
		failures.append(name)


func _cmd(action: String, scope: Dictionary, direction: String = "", target: Dictionary = {}) -> Dictionary:
	return {"action": action, "scope": scope, "direction": direction, "target": target, "posture": "NORMAL", "constraints": {}}


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

	# New verbs over CLASS scope (fresh turn: all eligible, so structural
	# acceptance is visible as absence of UNKNOWN_ACTION/INVALID_SCOPE).
	for verb in ["REPOSITION", "WITHDRAW", "REGROUP", "PROTECT", "SCREEN"]:
		var r: Dictionary = svc.call("validate_action", _cmd(verb, {"type": "CLASS", "class": "INFANTRY"}, "EAST", {"type": "HEX", "q": 0, "r": 0}), "blue")
		_check(_struct_ok(r), "verb %s structurally accepted (got %s)" % [verb, _codes(r)])

	# Relative directions on an existing verb.
	for dir in ["FORWARD", "BACK"]:
		var r: Dictionary = svc.call("validate_action", _cmd("ADVANCE", {"type": "ALL_AVAILABLE"}, dir), "blue")
		_check(_struct_ok(r), "direction %s structurally accepted (got %s)" % [dir, _codes(r)])

	# Entity targets on REPOSITION (blank-turn so failures are structural).
	var t_hex: Dictionary = svc.call("validate_action", _cmd("REPOSITION", {"type": "CLASS", "class": "CAVALRY"}, "", {"type": "HEX", "q": 4, "r": -2}), "blue")
	_check(_struct_ok(t_hex), "HEX target accepted (got %s)" % _codes(t_hex))
	var t_form: Dictionary = svc.call("validate_action", _cmd("REPOSITION", {"type": "CLASS", "class": "CAVALRY"}, "", {"type": "FORMATION", "unit_id": "B_HQ_1"}), "blue")
	_check(_struct_ok(t_form), "FORMATION target accepted (got %s)" % _codes(t_form))
	var t_hq: Dictionary = svc.call("validate_action", _cmd("REGROUP", {"type": "ALL_AVAILABLE"}, "", {"type": "HQ"}), "blue")
	_check(_struct_ok(t_hq), "HQ target accepted (got %s)" % _codes(t_hq))
	var t_sup: Dictionary = svc.call("validate_action", _cmd("PROTECT", {"type": "CLASS", "class": "INFANTRY"}, "", {"type": "SUPPLY", "unit_id": "B_SUP_1"}), "blue")
	_check(_struct_ok(t_sup), "SUPPLY target accepted (got %s)" % _codes(t_sup))
	var t_str: Dictionary = svc.call("validate_action", _cmd("REPOSITION", {"type": "CLASS", "class": "INFANTRY"}, "", {"type": "STRONGHOLD", "id": "Capital_Luoyang"}), "blue")
	_check(_struct_ok(t_str), "STRONGHOLD target accepted (got %s)" % _codes(t_str))
	var t_cen: Dictionary = svc.call("validate_action", _cmd("REPOSITION", {"type": "CLASS", "class": "ARCHER"}, "", {"type": "CENTER"}), "blue")
	_check(_struct_ok(t_cen), "CENTER target accepted (got %s)" % _codes(t_cen))

	# Negative controls must stay rejected.
	var bad_hex: Dictionary = svc.call("validate_action", _cmd("REPOSITION", {"type": "CLASS", "class": "CAVALRY"}, "", {"type": "HEX"}), "blue")
	_check(not _struct_ok(bad_hex), "HEX without q/r rejected")
	var bad_form: Dictionary = svc.call("validate_action", _cmd("REPOSITION", {"type": "CLASS", "class": "CAVALRY"}, "", {"type": "FORMATION"}), "blue")
	_check(not _struct_ok(bad_form), "FORMATION without unit_id rejected")
	var bad_verb: Dictionary = svc.call("validate_action", _cmd("CHARGE", {"type": "ALL_AVAILABLE"}, "NORTH"), "blue")
	_check(not _struct_ok(bad_verb), "unknown verb rejected")

	_write()
	print("SLICE1_" + ("PASS" if failures.is_empty() else "FAIL") + " (%d/%d)" % [notes.size(), notes.size() + failures.size()])
	quit(0 if failures.is_empty() else 2)


## Structural acceptance = no structural validation error. Planner-level
## outcomes (NO_VALID_UNITS etc.) still count as structurally accepted.
func _struct_ok(r: Dictionary) -> bool:
	for e in r.get("validation_errors", []):
		if e is Dictionary:
			var code := str((e as Dictionary).get("code", ""))
			if code in ["UNKNOWN_ACTION", "INVALID_SCOPE", "INVALID_TARGET", "TARGET_NOT_FOUND", "INVALID_DIRECTION"]:
				return false
	return true


func _codes(r: Dictionary) -> String:
	var out: Array = []
	for e in r.get("validation_errors", []):
		if e is Dictionary:
			out.append(str((e as Dictionary).get("code", "?")))
	return ",".join(out)


func _write() -> void:
	DirAccess.make_dir_recursive_absolute((OUT as String).get_base_dir())
	var file := FileAccess.open(OUT, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify({"status": "PASS" if failures.is_empty() else "FAIL", "failures": failures, "notes": notes}, "  "))
