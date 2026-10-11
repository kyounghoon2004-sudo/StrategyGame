extends SceneTree

## SLICE 2 (RED): planner target resolution + per-action class policy.
## Driven only through live service objects with plain-dict commands.
## Expected: FAIL before implementation.

const OUT := "D:/Game development/Demon slayer/StrategyGame/evidence/step7_slice2_planner.json"

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


func _classes(resolved: Array) -> Array:
	var out := {}
	for a in resolved:
		if a is Dictionary:
			out[str((a as Dictionary).get("class", "?"))] = true
	return out.keys()


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
	var blue_svc: RefCounted = integration.get("blue_service")

	# 1. REPOSITION cavalry toward an explicit HEX.
	var repo: Dictionary = svc.call("preview_action", _cmd("REPOSITION", {"type": "CLASS", "class": "CAVALRY"}, "", {"type": "HEX", "q": 4, "r": -2}), "blue")
	_check(bool(repo.get("ok", false)) and _classes(repo.get("resolved_units", [])) == ["CAVALRY"], "REPOSITION cavalry resolves cavalry-only toward HEX")

	# 2. REGROUP whole force toward HQ.
	var reg: Dictionary = svc.call("preview_action", _cmd("REGROUP", {"type": "ALL_AVAILABLE"}, "", {"type": "HQ"}), "blue")
	_check(bool(reg.get("ok", false)) and not (reg.get("resolved_units", []) as Array).is_empty(), "REGROUP ALL toward HQ resolves")

	# 3. PROTECT named supply with infantry only.
	var pro: Dictionary = svc.call("preview_action", _cmd("PROTECT", {"type": "CLASS", "class": "INFANTRY"}, "", {"type": "SUPPLY", "unit_id": "B_SUP_1"}), "blue")
	_check(bool(pro.get("ok", false)) and _classes(pro.get("resolved_units", [])) == ["INFANTRY"], "PROTECT supply resolves infantry-only")

	# 4. SCREEN HQ: adaptive to fog reality at turn 1.
	var blue_k: Dictionary = blue_svc.call("build", int(truth.call("get_turn")))
	var visible: Array = blue_k.get("current_enemy_observations", [])
	var stale: Array = blue_k.get("last_known_enemy_contacts", [])
	var scr: Dictionary = svc.call("preview_action", _cmd("SCREEN", {"type": "CLASS", "class": "INFANTRY"}, "", {"type": "HQ"}), "blue")
	if visible.is_empty() and stale.is_empty():
		_check(not bool(scr.get("ok", false)), "SCREEN with no visible threat rejects structurally")
	else:
		_check(bool(scr.get("ok", false)) and _classes(scr.get("resolved_units", [])) == ["INFANTRY"], "SCREEN HQ resolves infantry-only vs visible threat")

	# 5. WITHDRAW conscripts toward HQ.
	var wdr: Dictionary = svc.call("preview_action", _cmd("WITHDRAW", {"type": "CLASS", "class": "CONSCRIPT"}, "", {"type": "HQ"}), "blue")
	_check(bool(wdr.get("ok", false)) and _classes(wdr.get("resolved_units", [])) == ["CONSCRIPT"], "WITHDRAW conscripts toward HQ")

	# 6. RECON_ALL: only recon-capable classes; HQ explicitly unsupported.
	var rec: Dictionary = svc.call("preview_action", _cmd("RECON", {"type": "ALL_AVAILABLE"}, "NORTH"), "blue")
	var rclasses: Array = _classes(rec.get("resolved_units", []))
	var r_ok := true
	for c in rclasses:
		if not str(c) in ["SCOUT", "CAVALRY"]:
			r_ok = false
	_check(r_ok and not rclasses.is_empty(), "RECON_ALL resolves only SCOUT/CAVALRY (got %s)" % str(rclasses))
	_check(_rej_has(rec, "B_HQ_1", "ACTION_NOT_SUPPORTED_FOR_CLASS"), "RECON_ALL marks HQ ACTION_NOT_SUPPORTED_FOR_CLASS")

	# 7. FLANK excludes siege.
	var fl: Dictionary = svc.call("preview_action", _cmd("FLANK", {"type": "CLASS", "class": "SIEGE"}, "RIGHT"), "blue")
	_check(_rej_has(fl, "B_SIG_1", "ACTION_NOT_SUPPORTED_FOR_CLASS") or _rej_has(fl, "B_SIG_2", "ACTION_NOT_SUPPORTED_FOR_CLASS"), "FLANK marks siege ACTION_NOT_SUPPORTED_FOR_CLASS")

	# 8. Unknown targets reject with TARGET_NOT_FOUND, nothing resolves.
	var unk: Dictionary = svc.call("preview_action", _cmd("REPOSITION", {"type": "CLASS", "class": "INFANTRY"}, "", {"type": "STRONGHOLD", "id": "NO_SUCH_PLACE"}), "blue")
	_check(not bool(unk.get("ok", false)) and _any_rej_code(unk, "TARGET_NOT_FOUND"), "unknown stronghold rejects TARGET_NOT_FOUND")
	var unk2: Dictionary = svc.call("preview_action", _cmd("REPOSITION", {"type": "CLASS", "class": "INFANTRY"}, "", {"type": "FORMATION", "unit_id": "B_NOPE_9"}), "blue")
	_check(not bool(unk2.get("ok", false)) and _any_rej_code(unk2, "TARGET_NOT_FOUND"), "unknown formation rejects TARGET_NOT_FOUND")

	_write()
	print("SLICE2_" + ("PASS" if failures.is_empty() else "FAIL") + " (%d/%d)" % [notes.size(), notes.size() + failures.size()])
	quit(0 if failures.is_empty() else 2)


func _rej_has(res: Dictionary, uid: String, code: String) -> bool:
	for r in res.get("rejected_units", []):
		if r is Dictionary and str((r as Dictionary).get("unit_id", "")) == uid and str((r as Dictionary).get("code", "")) == code:
			return true
	return false


func _any_rej_code(res: Dictionary, code: String) -> bool:
	for r in res.get("rejected_units", []):
		if r is Dictionary and str((r as Dictionary).get("code", "")) == code:
			return true
	for e in res.get("validation_errors", []):
		if e is Dictionary and str((e as Dictionary).get("code", "")) == code:
			return true
	return false


func _write() -> void:
	DirAccess.make_dir_recursive_absolute((OUT as String).get_base_dir())
	var file := FileAccess.open(OUT, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify({"status": "PASS" if failures.is_empty() else "FAIL", "failures": failures, "notes": notes}, "  "))
