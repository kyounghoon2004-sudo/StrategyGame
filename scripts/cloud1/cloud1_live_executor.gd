class_name Cloud1LiveExecutor
extends Node

## CLOUD STEP 1B — Live sequential executor (additive; no backend changes).
##
## The headless Cloud1Compiler.execute runs synchronously, but the LIVE shell
## animates moves (one Tween at a time: _is_animating_movement blocks the next
## move). This executor therefore takes the compiler's DRY-RUN plan
## (Cloud1Compiler.plan — same intent expansion, same snapshot) and walks the
## planned rows one-by-one through the EXACT live paths the human click flow
## uses:
##   MOVE   -> shell.execute_step7_move (authority + Tween + shell finalization)
##   HOLD   -> command_service.execute_hold_intent + live hold visuals
##   ATTACK -> command_service.execute_attack_intent (+Step6 mods) + live
##             renderer feedback + _fog_mark_engaged + _fog_recalc + _s6_after_combat
## No direct manager writes, no bypasses. Cooperative cancel between rows.
##
## STEP 2: execute() takes an acting side ("blue" default). RED rows run the
## SAME live authorities through the RED branch the deterministic enemy
## routine itself uses (service execute_move_intent/execute_attack_intent
## with side "red" + renderer position/attack presentation). BLUE rows are
## untouched. An external soft-lock (set_external_busy) lets the Cloud turn
## controller hold the executor across think/validate gaps.

signal unit_finished(row: Dictionary, succeeded: bool)
signal execution_finished(result: Dictionary)

const CompilerCls = preload("res://scripts/cloud1/cloud1_compiler.gd")

var _bridge: RefCounted = null
var _busy := false
var _cancel := false
var _external_busy := false
var _external_reason := ""
var _side := "blue"
var _cmd: Dictionary = {}
var _snapshot_id := ""
var _plan_failed: Array = []
var _planned: Array = []
var _resolved: Array = []
var _candidate_count := 0
var _executed: Array = []
var _exec_failed: Array = []
var _exec_cancelled: Array = []
var _awaiting_uid := ""


func bind(bridge: RefCounted) -> void:
	_bridge = bridge


func is_busy() -> bool:
	return _busy


## Soft-lock held by the Step 2 Cloud turn controller across think/validate
## gaps (when no rows are running yet). execute() refuses while held, so a
## human BLUE order cannot interleave a RED Cloud phase. Default off.
func set_external_busy(v: bool, reason: String = "") -> void:
	_external_busy = v
	_external_reason = reason


func is_external_busy() -> bool:
	return _external_busy


func cancel() -> void:
	_cancel = true


## Starts execution. Returns {accepted} immediately; the per-unit chain runs
## asynchronously and reports through unit_finished / execution_finished.
func execute(cmd: Dictionary, selected_unit_id: String = "", side: String = "blue") -> Dictionary:
	if _busy:
		return {"accepted": false, "code": "EXECUTION_IN_PROGRESS", "detail": "Another command is still executing."}
	if _external_busy:
		var why := _external_reason if not _external_reason.is_empty() else "A Cloud phase holds the executor."
		return {"accepted": false, "code": "EXECUTION_IN_PROGRESS", "detail": why}
	if _bridge == null or not _bridge.is_loaded():
		return {"accepted": false, "code": "NO_LIVE_STATE", "detail": "Live battle is not ready."}
	_side = side.strip_edges().to_lower()
	if _side != "red":
		_side = "blue"
	var draft: Dictionary = CompilerCls.plan(_bridge, cmd, selected_unit_id, _side)
	if not bool(draft.get("ok", false)):
		return {"accepted": false, "code": str(draft.get("code", "NO_VALID_UNITS")), "detail": str(draft.get("detail", "Rejected.")), "plan": draft}
	_busy = true
	_cancel = false
	_cmd = cmd
	_snapshot_id = str(draft.get("snapshot_id", ""))
	_plan_failed = (draft.get("failed", []) as Array).duplicate(true)
	_planned = (draft.get("planned", []) as Array).duplicate(true)
	_resolved = (draft.get("resolved_units", []) as Array).duplicate(true)
	_candidate_count = int(draft.get("candidate_count", 0))
	_executed = []
	_exec_failed = []
	_exec_cancelled = []
	call_deferred("_step_next")
	return {"accepted": true, "planned_count": _planned.size(), "snapshot_id": _snapshot_id}


func _step_next() -> void:
	if not _busy:
		return
	if _cancel or _planned.is_empty():
		_finish()
		return
	var row: Dictionary = _planned.pop_front()
	var kind := str(row.get("action", ""))
	if kind == "HOLD":
		_do_hold_row(row)
	elif kind == "ATTACK":
		_do_attack_row(row)
	else:
		_do_move_row(row)


func _mgr() -> RefCounted:
	return _bridge.get_manager() if _bridge != null else null


func _svc() -> RefCounted:
	return _bridge.get_service() if _bridge != null else null


func _shell() -> Node:
	return _bridge.get_shell() as Node if _bridge != null else null


func _do_hold_row(row: Dictionary) -> void:
	var uid := str(row.get("unit_id", ""))
	var svc := _svc()
	var res: Dictionary = svc.execute_hold_intent(uid, _side) if svc != null else {"success": false}
	if bool(res.get("success", false)):
		var shell := _shell()
		if shell != null:
			var renderer: Node = shell.get("unit_renderer") as Node
			if renderer != null and renderer.has_method("set_unit_dimmed"):
				renderer.call("set_unit_dimmed", uid, true)
			if shell.has_method("_show_combat_log"):
				shell.call("_show_combat_log", "[%s] 대기 — Shared Interface HOLD" % uid)
		_bridge.notify_mutation("cloud1_live_hold")
		_record(true, {"unit_id": uid, "action": "HOLD"})
	elif _record_terminal(uid, "HOLD", res):
		pass
	else:
		_record(false, {"unit_id": uid, "code": "UNIT_NOT_READY", "detail": str(res.get("error", "Formation cannot hold now."))})
	call_deferred("_step_next")


func _do_move_row(row: Dictionary) -> void:
	var uid := str(row.get("unit_id", ""))
	var to_arr: Array = row.get("to", [])
	var shell := _shell()
	if to_arr.size() != 2 or shell == null:
		_record(false, {"unit_id": uid, "code": "TARGET_UNREACHABLE", "detail": "Destination cannot currently be completed."})
		call_deferred("_step_next")
		return
	var dest := Vector2i(int(to_arr[0]), int(to_arr[1]))
	if _side == "red":
		_do_red_move_row(row, uid, dest, shell)
		return
	var res: Dictionary = shell.call("execute_step7_move", uid, dest, str(row.get("march_mode", "auto")), Callable(self, "_on_move_presented").bind(uid, row))
	if not bool(res.get("success", false)):
		if not _record_terminal(uid, "MOVE", res):
			_record(false, {"unit_id": uid, "code": _exec_code(str(res.get("error", ""))), "detail": str(res.get("error", "Destination cannot currently be completed."))})
		call_deferred("_step_next")
		return
	if not bool(res.get("moved", false)):
		# Authority ran and finalized synchronously (immediate contact stop).
		_bridge.notify_mutation("cloud1_live_move_stop")
		_record(true, {"unit_id": uid, "action": "MOVE", "from": row.get("from", []), "to": row.get("to", []), "via_action": str(row.get("via_action", "")), "note": "stopped_by_contact"})
		call_deferred("_step_next")
		return
	_awaiting_uid = uid
	# The shell's animation callback advances the chain.


## RED live move: the exact authority + presentation branch the deterministic
## enemy routine uses (service move intent for side "red", then renderer
## position sync + fog recalc). Synchronous, like the enemy routine.
func _do_red_move_row(row: Dictionary, uid: String, dest: Vector2i, shell: Node) -> void:
	var svc := _svc()
	if svc == null:
		_record(false, {"unit_id": uid, "code": "TARGET_UNREACHABLE", "detail": "Live battle unavailable."})
		call_deferred("_step_next")
		return
	var res: Dictionary = svc.execute_move_intent(uid, dest, "red", str(row.get("march_mode", "auto")))
	if not bool(res.get("success", false)):
		if not _record_terminal(uid, "MOVE", res):
			_record(false, {"unit_id": uid, "code": _exec_code(str(res.get("error", ""))), "detail": str(res.get("error", "Destination cannot currently be completed."))})
		call_deferred("_step_next")
		return
	var renderer: Node = shell.get("unit_renderer") as Node
	if renderer != null and renderer.has_method("update_unit_position"):
		renderer.call("update_unit_position", uid, dest.x, dest.y)
	if shell.has_method("_fog_recalc"):
		shell.call("_fog_recalc", "enemy_move")
	if shell.has_method("_show_combat_log"):
		shell.call("_show_combat_log", "[%s] 이동 — Cloud RED MOVE" % uid)
	_bridge.notify_mutation("cloud2_live_red_move")
	_record(true, {"unit_id": uid, "action": "MOVE", "from": row.get("from", []), "to": row.get("to", []), "via_action": str(row.get("via_action", ""))})
	call_deferred("_step_next")


func _on_move_presented(res: Dictionary, uid: String, row: Dictionary) -> void:
	if not _busy or _awaiting_uid != uid:
		return
	_awaiting_uid = ""
	if bool(res.get("success", false)) and bool(res.get("moved", false)):
		_bridge.notify_mutation("cloud1_live_move")
		_record(true, {"unit_id": uid, "action": "MOVE", "from": row.get("from", []), "to": row.get("to", []), "via_action": str(row.get("via_action", ""))})
	else:
		_record(false, {"unit_id": uid, "code": _exec_code(str(res.get("error", ""))), "detail": "Movement made no legal progress." if bool(res.get("success", false)) else str(res.get("error", "Destination cannot currently be completed."))})
	call_deferred("_step_next")


func _do_attack_row(row: Dictionary) -> void:
	var uid := str(row.get("unit_id", ""))
	var target := str(row.get("target_unit_id", ""))
	var shell := _shell()
	var svc := _svc()
	var mgr := _mgr()
	if shell == null or svc == null or mgr == null:
		_record(false, {"unit_id": uid, "code": "TARGET_UNREACHABLE", "detail": "Live battle unavailable."})
		call_deferred("_step_next")
		return
	var s6: RefCounted = _bridge.get_step6()
	var mods: Dictionary = s6.attacker_bonus_vs(mgr, uid, target) if s6 != null else {}
	var res: Dictionary = svc.execute_attack_intent(uid, target, _side, mods)
	if not bool(res.get("success", false)):
		if not _record_terminal(uid, "ATTACK", res):
			_record(false, {"unit_id": uid, "code": "TARGET_UNREACHABLE", "detail": str(res.get("error", "Target is not a legal attack option."))})
		call_deferred("_step_next")
		return
	_run_attack_presentation(uid, target, res, _side)


## Same visual + fog + Step6 finalization the click flow performs, sequenced
## so group attacks remain readable. Authority already mutated above.
## RED rows mirror the enemy routine's fog calls (mark the RED attacker).
func _run_attack_presentation(uid: String, target: String, res: Dictionary, side: String = "blue") -> void:
	var shell := _shell()
	var mgr := _mgr()
	var atk: Dictionary = mgr.get_unit_by_id(uid)
	var enemy: Dictionary = mgr.get_unit_by_id(target)
	var atk_coord := Vector2i(int(atk.get("q", 0)), int(atk.get("r", 0)))
	var def_coord := Vector2i(int(enemy.get("q", atk_coord.x)), int(enemy.get("r", atk_coord.y)))
	shell.set("_is_animating_combat", true)
	var renderer: Node = shell.get("unit_renderer") as Node
	if renderer != null:
		if renderer.has_method("animate_unit_attack"):
			renderer.call("animate_unit_attack", uid, def_coord)
		var am: Node = shell.get_node_or_null("/root/AudioManager")
		if am != null and am.has_method("play_sfx"):
			am.call("play_sfx", "sword" if str(res.get("attacker_class", "")) == "cavalry" else "spear_brace")
	await get_tree().create_timer(0.15).timeout
	if not _busy:
		shell.set("_is_animating_combat", false)
		return
	if renderer != null:
		var def_cas := int(res.get("defender_casualties", 0))
		if def_cas > 0 and renderer.has_method("animate_unit_hit"):
			renderer.call("animate_unit_hit", target, def_cas)
		if renderer.has_method("update_unit_health"):
			renderer.call("update_unit_health", target, int(res.get("defender_remaining_troops", 0)))
		if bool(res.get("defender_destroyed", false)) and renderer.has_method("remove_unit"):
			renderer.call("remove_unit", target)
		var atk_cas := int(res.get("attacker_casualties", 0))
		if atk_cas > 0 and renderer.has_method("animate_unit_hit"):
			renderer.call("animate_unit_hit", uid, atk_cas)
		if renderer.has_method("update_unit_health"):
			renderer.call("update_unit_health", uid, int(res.get("attacker_remaining_troops", 0)))
		if bool(res.get("attacker_destroyed", false)) and renderer.has_method("remove_unit"):
			renderer.call("remove_unit", uid)
		elif bool(res.get("attacker_action_ended", true)) and renderer.has_method("set_unit_dimmed"):
			renderer.call("set_unit_dimmed", uid, true)
	if shell.has_method("_fog_mark_engaged"):
		shell.call("_fog_mark_engaged", uid if side == "red" else target)
	shell.set("_fog_recent_combat", true)
	if shell.has_method("_fog_recalc"):
		shell.call("_fog_recalc", "enemy_attack" if side == "red" else "player_attack")
	if shell.has_method("_s6_after_combat"):
		shell.call("_s6_after_combat", res, uid, target, atk_coord, def_coord)
	if shell.has_method("_show_combat_log"):
		shell.call("_show_combat_log", "[%s] 공격 -> [%s] 적 손실 -%d" % [uid, target, int(res.get("defender_casualties", 0))])
	shell.set("_is_animating_combat", false)
	_bridge.notify_mutation("cloud1_live_attack")
	_record(true, {"unit_id": uid, "action": "ATTACK", "target_unit_id": target})
	call_deferred("_step_next")


func _record(succeeded: bool, row: Dictionary) -> void:
	if succeeded:
		_executed.append(row)
	else:
		_exec_failed.append(row)
	unit_finished.emit(row.duplicate(true), succeeded)


## BATTLE_TERMINAL_CONTRACT_V0: service refusals carrying
## BATTLE_ALREADY_TERMINAL become clean cancels (void, not erroneous) and
## drain every remaining planned row the same way. Returns true when the
## refusal was terminal (caller must stop the chain).
func _record_terminal(uid: String, action: String, res: Dictionary) -> bool:
	if str(res.get("code", "")) != "BATTLE_ALREADY_TERMINAL":
		return false
	_exec_cancelled.append({"unit_id": uid, "action": action,
		"code": "BATTLE_ALREADY_TERMINAL",
		"cancel_reason": "BATTLE_ALREADY_TERMINAL",
		"detail": str(res.get("error", "Battle already terminal."))})
	for prow in _planned:
		_exec_cancelled.append({"unit_id": str((prow as Dictionary).get("unit_id", "")),
			"action": str((prow as Dictionary).get("action", "")),
			"code": "BATTLE_ALREADY_TERMINAL",
			"cancel_reason": "BATTLE_ALREADY_TERMINAL",
			"detail": "Battle already terminal."})
	_planned = []
	unit_finished.emit({"unit_id": uid, "action": action,
		"code": "BATTLE_ALREADY_TERMINAL"}, false)
	return true


func _finish() -> void:
	_busy = false
	_awaiting_uid = ""
	var status := "FAILED"
	if not _executed.is_empty():
		status = "PARTIAL" if (not _exec_failed.is_empty() or not _plan_failed.is_empty() or not _exec_cancelled.is_empty() or _cancel) else "EXECUTED"
	if _cancel and _executed.is_empty() and _exec_failed.is_empty():
		status = "CANCELLED"
	if not _exec_cancelled.is_empty() and _executed.is_empty() and _exec_failed.is_empty():
		status = "CANCELLED"
	var result := {
		"ok": not _executed.is_empty(),
		"command": _cmd,
		"acting_side": _side.to_upper(),
		"snapshot_id": _snapshot_id,
		"resolved_units": _resolved.duplicate(true),
		"planned_count": _resolved.size(),
		"executed_units": _executed.duplicate(true),
		"execution_failed": _exec_failed.duplicate(true),
		"cancelled_units": _exec_cancelled.duplicate(true),
		"plan_failed": _plan_failed.duplicate(true),
		"candidate_count": _candidate_count,
		"unexplained_count": 0,
		"execution_status": status,
		"cancelled": _cancel,
		"post_fingerprint": _bridge.fingerprint() if _bridge != null else "",
	}
	_planned = []
	execution_finished.emit(result)


func _exec_code(err: String) -> String:
	var lower := err.to_lower()
	if lower.contains("ccupied"):
		return "OCCUPIED"
	if lower.contains("budget") or lower.contains("march") or lower.contains("progress"):
		return "INSUFFICIENT_MOVEMENT"
	return "TARGET_UNREACHABLE"
