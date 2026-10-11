class_name Step7ActionService
extends RefCounted

## Stable deterministic action API (Step 7 reset).
##
##   get_world_state_version / get_action_schema / get_manual_presets
##   validate_action / plan_action / preview_action
##   execute_plan / cancel_plan / get_action_result
##
## Player UI, the DEV panel, and every future caller (NL router, Advisor,
## Enemy General, RL policy, Runtime MCP) go through THIS service.
## None may own separate movement rules. Zero inference. Zero gameplay MCP.

const CommandScript = preload("res://scripts/step7/step7_action_command.gd")
const BattleIRScript = preload("res://scripts/step7/step7_battle_ir.gd")
const PlannerScript = preload("res://scripts/step7/step7_operation_planner.gd")

## Planner-native reasons mapped to stable public codes.
const REASON_TO_CODE := {
	"ALREADY_ACTED": "UNIT_NOT_READY",
	"UNAVAILABLE": "UNIT_NOT_READY",
	"NO_MATCHING_FORMATION": "NO_VALID_UNITS",
	"ILLEGAL_ATTACK": "TARGET_UNREACHABLE",
	"NO_LEGAL_PROGRESS": "NO_LEGAL_DESTINATION",
}

var _truth: RefCounted = null
var _command_service: RefCounted = null
var _unit_manager: RefCounted = null
var _move_executor: Callable = Callable()
var _plans: Dictionary = {}
var _results: Dictionary = {}
var _action_seq := 0
var _active_execution: Dictionary = {}

signal execution_started(snapshot: Dictionary)
signal execution_progress(progress: Dictionary)
signal execution_finished(result: Dictionary)


func configure(world_truth: RefCounted, command_service: RefCounted, unit_manager: RefCounted, move_executor: Callable = Callable()) -> void:
	_truth = world_truth
	_command_service = command_service
	_unit_manager = unit_manager
	_move_executor = move_executor


func is_ready() -> bool:
	return _truth != null and _command_service != null and _unit_manager != null


func is_executing() -> bool:
	return not _active_execution.is_empty()


func get_world_state_version() -> int:
	return int(_truth.get_version()) if _truth else -1


func get_action_schema() -> Dictionary:
	return {
		"actions": CommandScript.VALID_ACTIONS,
		"scope_types": CommandScript.VALID_SCOPE_TYPES,
		"classes": CommandScript.VALID_CLASSES,
		"directions": CommandScript.VALID_DIRECTIONS,
		"postures": CommandScript.VALID_POSTURES,
		"error_codes": CommandScript.ERROR_CODES,
		"command_form": {"action": "String", "scope": "Dictionary", "direction": "String", "target": "Dictionary", "posture": "String", "constraints": "Dictionary"},
		"target_form": {"type": "HEX", "q": "int", "r": "int"},
	}


func get_manual_presets() -> Array:
	var out: Array = []
	for key in (CommandScript.presets() as Dictionary).keys():
		var row: Dictionary = (CommandScript.presets() as Dictionary)[key]
		out.append({"id": str(key), "label": str(row.get("label", key)), "group": str(row.get("group", "GENERAL")), "command": (row.get("command", {}) as Dictionary).duplicate(true), "template": bool(row.get("template", false)), "binding": str(row.get("binding", ""))})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a.get("id", "")) < str(b.get("id", "")))
	return out


func validate_action(command: Dictionary, side: String = "blue") -> Dictionary:
	return _build(command, side, false)


func plan_action(command: Dictionary, side: String = "blue") -> Dictionary:
	return _build(command, side, true)


func preview_action(command: Dictionary, side: String = "blue") -> Dictionary:
	var result := _build(command, side, true)
	if not bool(result.get("ok", false)):
		return result
	result["routes"] = _routes_for(result.get("resolved_units", []), side)
	return result


func cancel_plan(plan_id: String) -> Dictionary:
	if _plans.has(plan_id):
		_plans.erase(plan_id)
		return {"ok": true, "plan_id": plan_id, "execution_status": "CANCELLED"}
	return {"ok": false, "code": "UNKNOWN_ACTION", "detail": "No stored plan for that id."}


func get_action_result(action_id: String) -> Dictionary:
	if _results.has(action_id):
		return (_results[action_id] as Dictionary).duplicate(true)
	return {"ok": false, "code": "UNKNOWN_ACTION", "detail": "No stored result for that action id."}


## Execute a stored plan. A multi-formation command becomes a deterministic,
## callback-driven queue. Each entry is replanned against the world that exists
## after the prior formation's presentation callback has finalized.
func execute_plan(plan_id: String) -> Dictionary:
	if is_executing():
		return {
			"ok": false,
			"code": "EXECUTION_IN_PROGRESS",
			"detail": "Another action plan is still executing.",
			"execution_status": "IN_PROGRESS",
		}
	if not _plans.has(plan_id):
		return {"ok": false, "code": "UNKNOWN_ACTION", "detail": "No stored plan for that id."}
	var stored: Dictionary = (_plans[plan_id] as Dictionary).duplicate(true)
	var check := str(_truth.check_plan(stored)) if _truth else "INVALID"
	var replanned := false
	if check == "INVALID":
		var invalid_result := _fail_execute(stored, "INVALID", "Stored plan is malformed.")
		_results[str(stored.get("action_id", plan_id))] = invalid_result.duplicate(true)
		return invalid_result
	if check == "REPLAN_REQUIRED":
		var rebuilt := _build(stored["command"], str(stored.get("side", "blue")), true)
		if not bool(rebuilt.get("ok", false)) or (rebuilt.get("resolved_units", []) as Array).is_empty():
			_plans.erase(plan_id)
			var stale_result := _fail_execute(stored, "STALE_STATE", "World changed and no legal replan exists.")
			_results[str(stored.get("action_id", plan_id))] = stale_result.duplicate(true)
			return stale_result
		replanned = true
		stored = (_plans[rebuilt["plan_id"]] as Dictionary).duplicate(true)
		_plans.erase(plan_id)
		plan_id = str(rebuilt["plan_id"])
	var previous_version := get_world_state_version()
	var queue: Array = (stored.get("candidate_units", []) as Array).duplicate(true)
	if queue.is_empty():
		for action_val in stored.get("actions", []):
			if not action_val is Dictionary:
				continue
			var action: Dictionary = action_val as Dictionary
			queue.append({
				"unit_id": str(action.get("unit_id", "")),
				"class": str(action.get("class", "")),
				"start": (action.get("from", []) as Array).duplicate(true),
				"initially_planned": true,
			})
	if queue.is_empty():
		var empty_result := _fail_execute(stored, "NO_VALID_UNITS", "No candidate formation is available to execute.")
		_results[str(stored.get("action_id", plan_id))] = empty_result.duplicate(true)
		_plans.erase(plan_id)
		return empty_result
	var action_id := str(stored.get("action_id", plan_id))
	var queue_order := _queue_ids(queue)
	var initial_result := {
		"ok": true,
		"action_id": action_id,
		"execution_status": "IN_PROGRESS",
		"previous_state_version": previous_version,
		"resulting_state_version": get_world_state_version(),
		"executed_units": [],
		"failed_units": [],
		"rejected_units": [],
		"candidate_units": queue.duplicate(true),
		"candidate_count": queue.size(),
		"queue_order": queue_order,
		"unexplained_count": queue.size(),
		"replanned": replanned,
		"per_entry_revalidation": true,
	}
	_active_execution = {
		"action_id": action_id,
		"command": (stored.get("command", {}) as Dictionary).duplicate(true),
		"side": str(stored.get("side", "blue")),
		"queue": queue,
		"queue_order": queue_order,
		"candidate_units": queue.duplicate(true),
		"candidate_count": queue.size(),
		"previous_state_version": previous_version,
		"replanned": replanned,
		"executed_units": [],
		"failed_units": [],
		"awaiting_unit_id": "",
		"awaiting_action": {},
		"awaiting_candidate": {},
	}
	_results[action_id] = initial_result.duplicate(true)
	_plans.erase(plan_id)
	execution_started.emit(initial_result.duplicate(true))
	call_deferred("_begin_next_queue_entry")
	return initial_result


# --- Internals ------------------------------------------------------------

func _fail_execute(stored: Dictionary, code: String, detail: String) -> Dictionary:
	return {
		"ok": false,
		"action_id": str(stored.get("action_id", "")),
		"execution_status": "REJECTED_STALE" if code == "STALE_STATE" else "REJECTED",
		"previous_state_version": get_world_state_version(),
		"resulting_state_version": get_world_state_version(),
		"executed_units": [],
		"failed_units": [{"code": code, "detail": detail}],
		"rejected_units": [{"code": code, "detail": detail}],
		"candidate_units": (stored.get("candidate_units", []) as Array).duplicate(true),
	}


## Shared build path for validate/plan/preview. When `store` is true the
## plan is kept with its OCC record (version + fingerprint + turn).
func _build(command: Dictionary, side: String, store: bool) -> Dictionary:
	var structural := CommandScript.validate_structure(command)
	if not bool(structural.get("ok", false)):
		return {
			"ok": false,
			"command": command,
			"state_version": get_world_state_version(),
			"resolved_units": [],
			"rejected_units": [],
			"plan_status": "NO_PLAN",
			"validation_errors": [{"code": str(structural.get("code", "INVALID_SCOPE")), "detail": str(structural.get("detail", ""))}],
			"warnings": [],
		}
	var ir := CommandScript.to_battle_ir(command)
	var checked: Dictionary = BattleIRScript.validate(ir)
	if not bool(checked.get("ok", false)):
		return {
			"ok": false,
			"command": command,
			"state_version": get_world_state_version(),
			"resolved_units": [],
			"rejected_units": [],
			"plan_status": "NO_PLAN",
			"validation_errors": [{"code": "INVALID_SCOPE", "detail": str(checked.get("detail", "Rejected."))}],
			"warnings": [],
		}
	var plan: Dictionary = PlannerScript.plan(checked["ir"], side, _command_service, _unit_manager)
	var resolved: Array = []
	for a_val in plan.get("actions", []):
		if a_val is Dictionary:
			resolved.append(a_val)
	var rejected: Array = []
	for r_val in plan.get("unavailable", []):
		if r_val is Dictionary:
			var row: Dictionary = r_val
			var reason := str(row.get("reason", ""))
			rejected.append({
				"unit_id": str(row.get("unit_id", "")),
				"code": _public_code(reason),
				"detail": str(row.get("detail", "Not available.")),
			})
	var initial_actions: Dictionary = {}
	for a_val in resolved:
		if a_val is Dictionary:
			initial_actions[str((a_val as Dictionary).get("unit_id", ""))] = true
	var initial_rejections: Dictionary = {}
	for r_val in rejected:
		if r_val is Dictionary:
			initial_rejections[str((r_val as Dictionary).get("unit_id", ""))] = str((r_val as Dictionary).get("code", ""))
	var candidates: Array = []
	for candidate_val in plan.get("candidate_units", []):
		if not candidate_val is Dictionary:
			continue
		var candidate: Dictionary = (candidate_val as Dictionary).duplicate(true)
		var candidate_id := str(candidate.get("unit_id", ""))
		candidate["initially_planned"] = initial_actions.has(candidate_id)
		candidate["initial_code"] = str(initial_rejections.get(candidate_id, ""))
		candidates.append(candidate)
	var ok := not resolved.is_empty()
	var result := {
		"ok": ok,
		"command": command,
		"state_version": get_world_state_version(),
		"resolved_units": resolved,
		"rejected_units": rejected,
		"candidate_units": candidates,
		"plan_status": "READY" if ok else "NO_PLAN",
		"validation_errors": [] if ok else [{"code": "NO_VALID_UNITS", "detail": "No eligible formation produced a legal action."}],
		"warnings": [],
	}
	if store and ok:
		_action_seq += 1
		var action_id := "ACT%d_T%d" % [_action_seq, int(_truth.get_turn()) if _truth else 0]
		result["action_id"] = action_id
		result["plan_id"] = action_id
		_plans[action_id] = {
			"action_id": action_id,
			"command": command.duplicate(true),
			"side": side,
			"state_version": get_world_state_version(),
			"fingerprint": str(_truth.fingerprint()) if _truth else "",
			"turn": int(_truth.get_turn()) if _truth else 0,
			"actions": resolved,
			"candidate_units": candidates,
		}
	return result


func _public_code(reason: String) -> String:
	if reason in REASON_TO_CODE:
		return str(REASON_TO_CODE[reason])
	if reason in CommandScript.ERROR_CODES:
		return reason
	return "NO_LEGAL_DESTINATION"


## Fresh route data per resolved action for preview rendering.
func _routes_for(resolved: Array, side: String) -> Array:
	var out: Array = []
	for a_val in resolved:
		if not a_val is Dictionary:
			continue
		var a: Dictionary = a_val
		if str(a.get("action", "")) == "MOVE" and (a.get("to", []) as Array).size() == 2:
			var dest := Vector2i(int((a["to"] as Array)[0]), int((a["to"] as Array)[1]))
			var preview: Dictionary = _command_service.preview_move(str(a.get("unit_id", "")), dest, side, str(a.get("march_mode", "auto")))
			out.append({
				"unit_id": str(a.get("unit_id", "")),
				"legal": bool(preview.get("legal", false)),
				"from": a.get("from", []),
				"to": a.get("to", []),
				"path_cells": preview.get("path_cells", []),
				"cost": float(preview.get("cost", 0.0)),
			})
		else:
			out.append({"unit_id": str(a.get("unit_id", "")), "legal": true, "from": a.get("from", []), "to": a.get("to", []), "path_cells": [], "cost": 0.0})
	return out


## Queue one original scope candidate. The original plan remains useful as a
## preview, but this entry gets a new UNIT_ID plan after every earlier mutation.
func _begin_next_queue_entry() -> void:
	if not is_executing():
		return
	var queue: Array = _active_execution.get("queue", []) as Array
	if queue.is_empty():
		_finalize_active_execution()
		return
	var candidate_val: Variant = queue.pop_front()
	_active_execution["queue"] = queue
	if not candidate_val is Dictionary:
		_record_queue_row({"unit_id": "", "code": "NO_VALID_UNITS", "detail": "Queue entry is malformed."}, false)
		_emit_queue_progress("", "REJECTED", _active_execution.get("failed_units", []) as Array)
		call_deferred("_begin_next_queue_entry")
		return
	var candidate: Dictionary = candidate_val as Dictionary
	var uid := str(candidate.get("unit_id", ""))
	if uid.is_empty():
		var malformed := _annotate_queue_row({"unit_id": "", "code": "NO_VALID_UNITS", "detail": "Queue entry has no formation id."}, candidate)
		_record_queue_row(malformed, false)
		_emit_queue_progress(uid, "REJECTED", malformed)
		call_deferred("_begin_next_queue_entry")
		return
	var entry_command := _entry_command(_active_execution.get("command", {}) as Dictionary, uid)
	var fresh: Dictionary = _build(entry_command, str(_active_execution.get("side", "blue")), false)
	var fresh_actions: Array = fresh.get("resolved_units", []) as Array
	if not bool(fresh.get("ok", false)) or fresh_actions.is_empty() or not fresh_actions[0] is Dictionary:
		var rejection := _fresh_rejection_row(fresh, candidate)
		_record_queue_row(rejection, false)
		_emit_queue_progress(uid, "REJECTED", rejection)
		call_deferred("_begin_next_queue_entry")
		return
	var action: Dictionary = fresh_actions[0] as Dictionary
	if str(action.get("action", "")) == "MOVE":
		_begin_queued_move(action, candidate, str(_active_execution.get("side", "blue")))
		return
	_complete_queued_nonmove(action, candidate, str(_active_execution.get("side", "blue")))


func _entry_command(command: Dictionary, unit_id: String) -> Dictionary:
	var out := command.duplicate(true)
	out["scope"] = CommandScript.scope_unit(unit_id)
	return out


func _begin_queued_move(action: Dictionary, candidate: Dictionary, side: String) -> void:
	var uid := str(action.get("unit_id", ""))
	var to_arr: Array = action.get("to", []) as Array
	if to_arr.size() != 2:
		var invalid_target := _annotate_queue_row({"unit_id": uid, "code": "TARGET_UNREACHABLE", "detail": "Destination cannot currently be completed."}, candidate)
		_record_queue_row(invalid_target, false)
		_emit_queue_progress(uid, "REJECTED", invalid_target)
		call_deferred("_begin_next_queue_entry")
		return
	var destination := Vector2i(int(to_arr[0]), int(to_arr[1]))
	if not _move_executor.is_valid():
		# This fallback is retained only for a host without the shell presentation
		# adapter. The live Step 7 integration always supplies that adapter.
		var route: Variant = _command_service.preview_move_route(uid, destination, side, str(action.get("march_mode", "auto")))
		var fallback: Dictionary = {}
		if route != null and bool(route.found) and bool(route.is_valid_destination):
			fallback = _command_service.execute_player_move_path(uid, route.path)
		_complete_queued_move(action, candidate, fallback)
		return
	_active_execution["awaiting_unit_id"] = uid
	_active_execution["awaiting_action"] = action.duplicate(true)
	_active_execution["awaiting_candidate"] = candidate.duplicate(true)
	var launch_val: Variant = _move_executor.call(
		uid,
		destination,
		str(action.get("march_mode", "auto")),
		Callable(self, "_on_queued_move_presentation_completed").bind(uid)
	)
	# A renderer that has vanished can invoke the completion callback inline.
	# In that case it already recorded this entry and scheduled the next one.
	if not is_executing() or str(_active_execution.get("awaiting_unit_id", "")) != uid:
		return
	if not launch_val is Dictionary:
		_clear_awaiting_move()
		_complete_queued_move(action, candidate, {})
		return
	var launch: Dictionary = launch_val as Dictionary
	if not bool(launch.get("success", false)) or not bool(launch.get("moved", false)):
		_clear_awaiting_move()
		_complete_queued_move(action, candidate, launch)
		return
	# The normal shell path is animating now. Its callback is the only route to
	# the next queue entry, so a frame is rendered for every Tween segment.


func _on_queued_move_presentation_completed(res: Dictionary, expected_unit_id: String) -> void:
	if not is_executing() or str(_active_execution.get("awaiting_unit_id", "")) != expected_unit_id:
		return
	var action: Dictionary = _active_execution.get("awaiting_action", {}) as Dictionary
	var candidate: Dictionary = _active_execution.get("awaiting_candidate", {}) as Dictionary
	_clear_awaiting_move()
	_complete_queued_move(action, candidate, res)


func _clear_awaiting_move() -> void:
	_active_execution["awaiting_unit_id"] = ""
	_active_execution["awaiting_action"] = {}
	_active_execution["awaiting_candidate"] = {}


func _complete_queued_move(action: Dictionary, candidate: Dictionary, res: Dictionary) -> void:
	var uid := str(action.get("unit_id", candidate.get("unit_id", "")))
	if bool(res.get("success", false)) and bool(res.get("moved", false)):
		var success_row := _annotate_queue_row({
			"unit_id": uid,
			"action": "MOVE",
			"from": _coord_array(res.get("from", action.get("from", []))),
			"to": _coord_array(res.get("to", action.get("to", []))),
			"traversed_path": _path_arrays(res.get("traversed_path", [])),
		}, candidate)
		_record_queue_row(success_row, true)
		if _truth:
			_truth.notify_mutation("queue_move_completed")
		_emit_queue_progress(uid, "EXECUTED", success_row)
	else:
		var failure_row := _annotate_queue_row({
			"unit_id": uid,
			"code": "TARGET_UNREACHABLE",
			"detail": "Movement made no legal progress." if bool(res.get("success", false)) else "Destination cannot currently be completed.",
			"from": _coord_array(action.get("from", [])),
		}, candidate)
		_record_queue_row(failure_row, false)
		_emit_queue_progress(uid, "REJECTED", failure_row)
	call_deferred("_begin_next_queue_entry")


func _complete_queued_nonmove(action: Dictionary, candidate: Dictionary, side: String) -> void:
	var outcome := _execute_action(action, side)
	var uid := str(action.get("unit_id", candidate.get("unit_id", "")))
	var row: Dictionary = outcome.get("row", {}) as Dictionary
	row = _annotate_queue_row(row, candidate)
	if bool(outcome.get("ok", false)):
		_record_queue_row(row, true)
		if _truth:
			_truth.notify_mutation("queue_action_completed")
		_emit_queue_progress(uid, "EXECUTED", row)
	else:
		_record_queue_row(row, false)
		_emit_queue_progress(uid, "REJECTED", row)
	call_deferred("_begin_next_queue_entry")


func _fresh_rejection_row(fresh: Dictionary, candidate: Dictionary) -> Dictionary:
	var row: Dictionary = {}
	var rejected: Array = fresh.get("rejected_units", []) as Array
	if not rejected.is_empty() and rejected[0] is Dictionary:
		row = (rejected[0] as Dictionary).duplicate(true)
	else:
		var validation: Array = fresh.get("validation_errors", []) as Array
		if not validation.is_empty() and validation[0] is Dictionary:
			row = (validation[0] as Dictionary).duplicate(true)
	if row.is_empty():
		row = {"unit_id": str(candidate.get("unit_id", "")), "code": "NO_LEGAL_DESTINATION", "detail": "No legal action is available now."}
	return _annotate_queue_row(row, candidate)


func _annotate_queue_row(row: Dictionary, candidate: Dictionary) -> Dictionary:
	var out := row.duplicate(true)
	if not out.has("unit_id") or str(out.get("unit_id", "")).is_empty():
		out["unit_id"] = str(candidate.get("unit_id", ""))
	if not out.has("class"):
		out["class"] = str(candidate.get("class", ""))
	if not out.has("start"):
		out["start"] = (candidate.get("start", []) as Array).duplicate(true)
	out["queued"] = true
	out["attempted"] = true
	return out


func _record_queue_row(row: Dictionary, succeeded: bool) -> void:
	var key := "executed_units" if succeeded else "failed_units"
	var rows: Array = _active_execution.get(key, []) as Array
	rows.append(row.duplicate(true))
	_active_execution[key] = rows


func _emit_queue_progress(unit_id: String, status: String, row: Variant) -> void:
	if not is_executing():
		return
	var executed: Array = _active_execution.get("executed_units", []) as Array
	var failed: Array = _active_execution.get("failed_units", []) as Array
	var remaining: Array = _active_execution.get("queue", []) as Array
	execution_progress.emit({
		"action_id": str(_active_execution.get("action_id", "")),
		"unit_id": unit_id,
		"status": status,
		"row": row,
		"completed_count": executed.size() + failed.size(),
		"candidate_count": int(_active_execution.get("candidate_count", 0)),
		"remaining_count": remaining.size(),
		"state_version": get_world_state_version(),
	})


func _finalize_active_execution() -> void:
	if not is_executing():
		return
	var active := _active_execution.duplicate(true)
	var executed: Array = active.get("executed_units", []) as Array
	var failed: Array = active.get("failed_units", []) as Array
	var candidate_count := int(active.get("candidate_count", 0))
	var status := "FAILED"
	if not executed.is_empty():
		status = "PARTIAL" if not failed.is_empty() else "EXECUTED"
	var result := {
		"ok": not executed.is_empty(),
		"action_id": str(active.get("action_id", "")),
		"execution_status": status,
		"previous_state_version": int(active.get("previous_state_version", get_world_state_version())),
		"resulting_state_version": get_world_state_version(),
		"executed_units": executed,
		"failed_units": failed,
		"rejected_units": failed.duplicate(true),
		"candidate_units": (active.get("candidate_units", []) as Array).duplicate(true),
		"candidate_count": candidate_count,
		"queue_order": (active.get("queue_order", []) as Array).duplicate(true),
		"unexplained_count": maxi(0, candidate_count - executed.size() - failed.size()),
		"replanned": bool(active.get("replanned", false)),
		"per_entry_revalidation": true,
	}
	_results[str(active.get("action_id", ""))] = result.duplicate(true)
	_active_execution = {}
	execution_finished.emit(result.duplicate(true))


func _queue_ids(queue: Array) -> Array:
	var ids: Array = []
	for candidate_val in queue:
		if candidate_val is Dictionary:
			ids.append(str((candidate_val as Dictionary).get("unit_id", "")))
	return ids


func _coord_array(value: Variant) -> Array:
	if value is Vector2i:
		var coord: Vector2i = value
		return [coord.x, coord.y]
	if value is Array and (value as Array).size() >= 2:
		return [int((value as Array)[0]), int((value as Array)[1])]
	return []


func _path_arrays(value: Variant) -> Array:
	var out: Array = []
	if not value is Array:
		return out
	for coord_val in value:
		var coord := _coord_array(coord_val)
		if coord.size() == 2:
			out.append(coord)
	return out


## Execute ONE planned action against FRESH state. Routes are recomputed
## here, never trusted from plan-time coordinates.
func _execute_action(a: Dictionary, side: String) -> Dictionary:
	var uid := str(a.get("unit_id", ""))
	var kind := str(a.get("action", ""))
	if side != "blue":
		return {"ok": false, "row": {"unit_id": uid, "code": "NOT_IMPLEMENTED", "detail": "Only BLUE execution is wired in this milestone."}}
	match kind:
		"MOVE":
			# MOVE is intentionally handled only by _begin_queued_move(), which
			# owns the shell presentation callback before the queue can advance.
			return {"ok": false, "row": {"unit_id": uid, "code": "NOT_IMPLEMENTED", "detail": "Internal movement must use the queued presentation path."}}
		"HOLD":
			var held: Dictionary = _command_service.execute_hold_intent(uid, side)
			if bool(held.get("success", false)):
				return {"ok": true, "row": {"unit_id": uid, "action": "HOLD"}}
			return {"ok": false, "row": {"unit_id": uid, "code": "UNIT_NOT_READY", "detail": "Formation cannot hold now."}}
		"ATTACK":
			var fought: Dictionary = _command_service.execute_attack_intent(uid, str(a.get("target_unit_id", "")), side)
			if bool(fought.get("success", false)):
				return {"ok": true, "row": {"unit_id": uid, "action": "ATTACK", "target_unit_id": str(a.get("target_unit_id", ""))}}
			return {"ok": false, "row": {"unit_id": uid, "code": "TARGET_UNREACHABLE", "detail": "Target is not a legal attack option."}}
	return {"ok": false, "row": {"unit_id": uid, "code": "UNKNOWN_ACTION", "detail": "Unsupported planned action."}}
