extends SceneTree

## Deterministic action smoke (Step 7 reset). No model, no network, no MCP.
## Boots the canonical battle, drives ONLY the deterministic ActionService,
## and checks A-I plus the seven manual presets. Report: evidence file below.

const OUT := "D:/Game development/Demon slayer/StrategyGame/evidence/step7_det_smoke.json"

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
	for _i in range(120):
		if integration and bool(integration.get("ready_for_step7")):
			break
		await process_frame
	if integration == null or not bool(integration.get("ready_for_step7")):
		failures.append("I: Step7DetIntegration not ready")
		_write({"status": "FAIL", "failures": failures, "notes": notes})
		quit(2)
		return
	var svc: RefCounted = integration.get("action_service")
	var truth: RefCounted = integration.get("truth")
	if svc == null or truth == null:
		failures.append("I: action service/world truth missing")
		_write({"status": "FAIL", "failures": failures, "notes": notes})
		quit(2)
		return
	# I: no inference nodes under the integration (no HTTPRequest anywhere below it).
	var http_found := _count_http(integration)
	_check(http_found == 0, "I: zero HTTPRequest nodes (model call count = 0)")
	# A: schema accepts ADVANCE + ALL_AVAILABLE + NORTH.
	var adv_all := _cmd("ADVANCE", {"type": "ALL_AVAILABLE"}, "NORTH")
	var va: Dictionary = svc.call("validate_action", adv_all, "blue")
	_check(bool(va.get("ok", false)) and str(va.get("plan_status", "")) == "READY", "A: ADVANCE+ALL+NORTH validates READY")
	# B: CLASS:CAVALRY resolves only cavalry.
	var cav: Dictionary = svc.call("validate_action", _cmd("ADVANCE", {"type": "CLASS", "class": "CAVALRY"}, "RIGHT"), "blue")
	_check(_only_class(cav, "CAVALRY"), "B: CLASS:CAVALRY resolves only cavalry")
	# C: CLASS:SCOUT resolves only scouts.
	var sct: Dictionary = svc.call("validate_action", _cmd("RECON", {"type": "CLASS", "class": "SCOUT"}, "NORTH"), "blue")
	_check(_only_class(sct, "SCOUT"), "C: CLASS:SCOUT resolves only scouts")
	# Preset sweep (§29): all seven preview without crashing; record counts.
	var preset_counts := {}
	for row in svc.call("get_manual_presets"):
		var pid := str((row as Dictionary).get("id", "?"))
		var pr: Dictionary = svc.call("preview_action", (row as Dictionary).get("command", {}), "blue")
		preset_counts[pid] = {"ok": bool(pr.get("ok", false)), "resolved": ((pr.get("resolved_units", []) as Array).size()), "rejected": ((pr.get("rejected_units", []) as Array).size())}
		_check(pr.has("plan_status"), "preset preview structured: " + pid)
	notes.append("PRESETS " + JSON.stringify(preset_counts))
	# D: UNIT_ID binds exactly one requested unit (MOVE to a reachable neighbor).
	var blue_id := _first_blue_unit(svc, integration)
	var d_ok := false
	var move_cmd := {}
	if not blue_id.is_empty():
		var dest: Vector2i = _reachable_neighbor(integration, blue_id)
		if dest.x != -9999:
			move_cmd = _cmd("MOVE", {"type": "UNIT_ID", "unit_id": blue_id}, "", {"type": "HEX", "q": dest.x, "r": dest.y})
			var vd: Dictionary = svc.call("validate_action", move_cmd, "blue")
			var res: Array = vd.get("resolved_units", [])
			d_ok = bool(vd.get("ok", false)) and res.size() == 1 and str((res[0] as Dictionary).get("unit_id", "")) == blue_id
	_check(d_ok, "D: UNIT_ID binds exactly one requested unit")
	# E: illegal target returns structured failure.
	var bad: Dictionary = svc.call("validate_action", _cmd("MOVE", {"type": "UNIT_ID", "unit_id": blue_id if not blue_id.is_empty() else "B_INF_1"}, "", {"type": "HEX", "q": 999, "r": 999}), "blue")
	_check(not bool(bad.get("ok", false)) and not (bad.get("validation_errors", []) as Array).is_empty(), "E: illegal target fails structured")
	# F: plan stores state_version.
	var stored: Dictionary = svc.call("plan_action", adv_all, "blue")
	_check(not str(stored.get("plan_id", "")).is_empty() and int(stored.get("state_version", -1)) >= 0, "F: plan stores state_version")
	# G: mutate after planning -> stale plan cannot execute blindly.
	var g_ok := false
	if not blue_id.is_empty() and not move_cmd.is_empty():
		var p1: Dictionary = svc.call("plan_action", move_cmd, "blue")
		var pid1 := str(p1.get("plan_id", ""))
		if not pid1.is_empty():
			var cmd_svc: RefCounted = integration.get("command_service")
			var other: Vector2i = _reachable_neighbor(integration, blue_id, Vector2i(int(move_cmd["target"]["q"]), int(move_cmd["target"]["r"])))
			if other.x != -9999:
				var route: Variant = cmd_svc.call("preview_move_route", blue_id, other, "blue", "auto")
				if route != null and bool(route.found) and bool(route.is_valid_destination):
					cmd_svc.call("execute_player_move_path", blue_id, route.path)
					var ex: Dictionary = svc.call("execute_plan", pid1)
					# Either a fresh replan executes, or the stale plan is
					# refused. Blind execution of stale coordinates fails.
					g_ok = bool(ex.get("replanned", false)) or str(ex.get("execution_status", "")) == "REJECTED_STALE"
	_check(g_ok, "G: stale plan replanned, never executed blind")
	# Cancel path (before HOLD ends every formation's turn).
	var cplan: Dictionary = svc.call("plan_action", adv_all, "blue")
	var cancelled: Dictionary = svc.call("cancel_plan", str(cplan.get("plan_id", "")))
	_check(bool(cancelled.get("ok", false)), "cancel_plan works")
	# HOLD_ALL executes and bumps the version.
	var v0: int = svc.call("get_world_state_version")
	var hold_plan: Dictionary = svc.call("plan_action", _cmd("HOLD", {"type": "ALL_AVAILABLE"}, ""), "blue")
	var hold_ex: Dictionary = svc.call("execute_plan", str(hold_plan.get("plan_id", "")))
	_check(str(hold_ex.get("execution_status", "")) == "EXECUTED" and int(hold_ex.get("resulting_state_version", -1)) == v0 + 1, "HOLD_ALL executes, version+1")
	# H: BLUE projection cannot retrieve hidden RED exact state.
	var h_ok := _leak_check(integration)
	_check(h_ok, "H: hidden RED exact state absent from BLUE knowledge")
	# I: boot reached here with the deterministic host only.
	_check(integration.get("command_service") != null, "I: boots with deterministic service, no old infra")
	var report := {"status": "PASS" if failures.is_empty() else "FAIL", "failures": failures, "notes": notes}
	_write(report)
	print("DET_SMOKE_" + str(report["status"]))
	quit(0 if failures.is_empty() else 2)


func _cmd(action: String, scope: Dictionary, direction: String = "", target: Dictionary = {}) -> Dictionary:
	return {"action": action, "scope": scope, "direction": direction, "target": target, "posture": "NORMAL", "constraints": {}}


func _only_class(result: Dictionary, cls: String) -> bool:
	var resolved: Array = result.get("resolved_units", [])
	if resolved.is_empty():
		return false
	for a in resolved:
		if a is Dictionary and str((a as Dictionary).get("class", "")) != cls:
			return false
	return true


func _first_blue_unit(svc: RefCounted, integration: Node) -> String:
	var adv: Dictionary = svc.call("validate_action", _cmd("ADVANCE", {"type": "ALL_AVAILABLE"}, "NORTH"), "blue")
	for a in adv.get("resolved_units", []):
		if a is Dictionary:
			return str((a as Dictionary).get("unit_id", ""))
	return ""


func _reachable_neighbor(integration: Node, unit_id: String, avoid: Vector2i = Vector2i(-9999, -9999)) -> Vector2i:
	var cmd_svc: RefCounted = integration.get("command_service")
	if cmd_svc == null:
		return Vector2i(-9999, -9999)
	var origin := Vector2i(-9999, -9999)
	var truth: RefCounted = integration.get("truth")
	if truth != null:
		var u: Dictionary = truth.call("get_unit", unit_id)
		origin = Vector2i(int(u.get("q", -9999)), int(u.get("r", -9999)))
	var area: Dictionary = cmd_svc.call("reachable_area", unit_id, "blue", "auto")
	for e in area.get("reachable", []):
		if e is Dictionary:
			var cell := Vector2i(int((e as Dictionary).get("q", -9999)), int((e as Dictionary).get("r", -9999)))
			if cell != avoid and cell != origin:
				return cell
	return Vector2i(-9999, -9999)


func _leak_check(integration: Node) -> bool:
	var projector: RefCounted = integration.get("projector")
	var truth: RefCounted = integration.get("truth")
	if projector == null or truth == null:
		return false
	var hidden_id := ""
	for u in truth.call("snapshot_units"):
		if u is Dictionary and str((u as Dictionary).get("faction", "")) == "red" and int((u as Dictionary).get("soldier_count", 0)) > 0:
			if not bool(projector.call("is_contact_visible", "blue", str((u as Dictionary).get("id", "")))):
				hidden_id = str((u as Dictionary).get("id", ""))
				break
	if hidden_id.is_empty():
		notes.append("H: no hidden RED unit at boot (all visible); boundary check vacuous")
		return true
	var knowledge: Dictionary = integration.call("get_blue_knowledge")
	var flat := JSON.stringify(knowledge)
	# Quote-wrapped match: unit IDs are JSON strings, so "R_INF_1" must not
	# match a visible "R_INF_13" by substring.
	if flat.contains("\"" + hidden_id + "\""):
		notes.append("H LEAK: hidden " + hidden_id + " present in BLUE knowledge")
		return false
	# Attempt a BLUE plan and confirm rejected details leak nothing.
	var svc: RefCounted = integration.get("action_service")
	var adv: Dictionary = svc.call("validate_action", _cmd("ADVANCE", {"type": "ALL_AVAILABLE"}, "NORTH"), "blue")
	if JSON.stringify(adv).contains("\"" + hidden_id + "\""):
		notes.append("H LEAK: hidden " + hidden_id + " present in plan output")
		return false
	notes.append("H: hidden unit " + hidden_id + " in WorldTruth, absent from BLUE knowledge")
	return true


func _count_http(node: Node) -> int:
	var n := 0
	if node is HTTPRequest:
		n += 1
	for child in node.get_children():
		n += _count_http(child)
	return n


func _write(value: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute((OUT as String).get_base_dir())
	var file := FileAccess.open(OUT, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(value, "  "))
