class_name Cloud1Compiler
extends RefCounted

## CLOUD-GENERAL STEP 1C --Operational Command Compiler (deterministic).
##
##   OperationalCommand -> scope resolution -> intent expansion
##   -> legal per-unit plan -> EXISTING authoritative execution path
##
## The compiler owns NO game truth and duplicates NO rules. All legality,
## pathfinding, occupancy, movement and attack validation run inside
## Step7BattleCommandService + Step3UnitManager + Step3Pathfinding, reached
## exclusively through SimController.do_move / do_hold / do_attack (which
## delegate to that exact service) and service.reachable_area / preview_attack
## for intent expansion. Destination SCORING among already-legal hexes is the
## only Step1-local math (intent interpretation, inspectable below).
##
## Banned here (audited in Gate 6): find_route, calculate_combat,
## execute_player_stepwise_move, get_attackable_targets-as-legality,
## or any second occupancy/legality table.
##
## STEP 2: plan()/execute() take an acting side ("blue" default, "red" for
## Cloud orders). Same resolution, same intent expansion, same authoritative
## execution paths — only the acting side and the relative-direction frame
## (FORWARD/BACKWARD/LEFT/RIGHT) change. Absolute compass is map-relative.

const ScopeAlgebraCls = preload("res://scripts/step7/step7_scope_algebra.gd")
const HexUtilsCls = preload("res://scripts/core/hex_utils.gd")
const ClustersCls = preload("res://scripts/step7/step7_formation_clusters.gd")
const ObsCls = preload("res://scripts/cloud1/cloud1_observation.gd")
const TableCls = preload("res://scripts/cloud1/cloud1_action_table.gd")

const RECON_CLASSES := ["SCOUT", "CAVALRY"]
const FLANK_CLASSES := ["CAVALRY", "INFANTRY", "SPEARMAN", "SCOUT", "ARCHER"]


## Dry-run: no state mutation. Returns CompilationResult (plan phase).
##
## exec_ctx (GROUP_RETARGET_CONTRACT_V1, optional): mission-aware execution
## context attached by Cloud2MissionManager.red_turn to each order. When
## present AND non-empty, an ATTACK row whose preview fails is revalidated:
## a target that died earlier in the same RED batch becomes an explicit
## cancellation (HARD) or a scored-list retarget (SOFT/NONE) instead of a
## misleading ILLEGAL_ATTACK. Empty ctx (all decision-time dry-runs and all
## pre-existing callers) keeps byte-identical legacy behavior.
static func plan(sim: RefCounted, cmd: Dictionary, selected_unit_id: String = "", side: String = "blue", exec_ctx: Dictionary = {}) -> Dictionary:
	var acting := side.strip_edges().to_lower()
	if acting != "red":
		acting = "blue"
	var SIDE := acting.to_upper()
	var structural := TableCls.validate_command(cmd)
	if not bool(structural.get("ok", false)):
		return {
			"ok": false, "command": cmd, "snapshot_id": "",
			"resolved_units": [], "planned": [], "candidate_count": 0,
			"failed": [], "cancelled": [], "unexplained_count": 0,
			"code": str(structural.get("code", "INVALID_COMMAND")),
			"detail": str(structural.get("detail", "Rejected.")),
		}
	var obs := ObsCls.build(sim, acting)
	if not bool(obs.get("ok", false)):
		return {
			"ok": false, "command": cmd, "snapshot_id": "",
			"resolved_units": [], "planned": [], "candidate_count": 0,
			"failed": [], "cancelled": [], "unexplained_count": 0,
			"code": "NO_OBSERVATION", "detail": str(obs.get("error", "Observation unavailable.")),
		}
	var action := str(cmd.get("action", "")).strip_edges().to_upper()
	var eff_action := _effective_action(action)
	var mgr: RefCounted = sim.get_manager()
	var svc: RefCounted = sim.get_service()
	var scope: Dictionary = cmd.get("scope", {})
	var bounds: Dictionary = sim.map_bounds() if sim.has_method("map_bounds") else {}
	var resolution := _resolve_scope(scope, mgr, selected_unit_id, bounds, acting)
	var candidates: Array = resolution.get("units", [])
	var missing: Array = resolution.get("missing", [])
	var failed: Array = []
	for mid in missing:
		failed.append({"unit_id": str(mid), "code": "UNIT_NOT_FOUND", "detail": "Formation is not available to %s." % SIDE})
	if candidates.is_empty() and failed.is_empty():
		failed.append({"unit_id": "", "code": "NO_VALID_UNITS", "detail": "No friendly formation matched the scope."})
		return {
			"ok": false, "command": cmd, "snapshot_id": str(obs.get("snapshot_id", "")),
			"resolved_units": [], "planned": [], "candidate_count": 0,
			"scope_frozen": {"op": "UNITS", "unit_ids": []},
			"failed": failed, "cancelled": [], "unexplained_count": 0, "code": "NO_VALID_UNITS",
			"detail": "No friendly formation matched the scope.",
		}
	# BATTLE_TERMINAL_CONTRACT_V0: a terminal battle cancels the whole command
	# cleanly (no ILLEGAL_ATTACK / TARGET_UNREACHABLE / INVALID). One cancel
	# row per resolved candidate; scope-miss rows keep their failure shape.
	var bterm := _sim_battle_terminal(sim)
	if bool(bterm.get("terminal", false)):
		var trows: Array = []
		for u_val in candidates:
			var tu: Dictionary = u_val
			trows.append(_terminal_cancel_row(str(tu.get("id", "")),
				str(tu.get("class", "infantry")).to_upper(), eff_action, exec_ctx, bterm))
		return {
			"ok": false, "command": cmd, "snapshot_id": str(obs.get("snapshot_id", "")),
			"effective_action": eff_action,
			"mapping_note": _mapping_note(action),
			"stance_note": TableCls.STANCE_DEFERRED_NOTE,
			"resolved_units": _ids(candidates),
			"scope_frozen": {"op": "UNITS", "unit_ids": _ids(candidates)},
			"planned": [], "failed": failed, "cancelled": trows,
			"candidate_count": candidates.size() + missing.size(),
			"unexplained_count": 0, "code": "BATTLE_ALREADY_TERMINAL",
			"detail": _terminal_detail(bterm),
			"terminal": bterm,
		}
	var policy := str(cmd.get("movement_policy", "STANDARD")).strip_edges().to_upper()
	if policy.is_empty():
		policy = "STANDARD"
	var march_mode := _march_mode_for(policy)
	_order_candidates(candidates, cmd, eff_action)
	var target_points: Variant = _target_points(cmd, eff_action, sim, obs, acting)
	if target_points == null:
		for u_val in candidates:
			var uid := str((u_val as Dictionary).get("id", ""))
			failed.append({"unit_id": uid, "code": "TARGET_NOT_FOUND", "detail": "Target cannot be resolved from %s-authorized knowledge." % SIDE})
		return {
			"ok": false, "command": cmd, "snapshot_id": str(obs.get("snapshot_id", "")),
			"resolved_units": _ids(candidates), "planned": [], "candidate_count": candidates.size() + missing.size(),
			"failed": failed, "cancelled": [], "unexplained_count": 0, "code": "TARGET_NOT_FOUND",
			"detail": "Target cannot be resolved from %s-authorized knowledge." % SIDE,
		}
	var planned: Array = []
	var cancelled: Array = []
	var reservations := {}
	for u_val in candidates:
		var u: Dictionary = u_val
		var uid := str(u.get("id", ""))
		var uclass := str(u.get("class", "infantry")).to_upper()
		var origin := Vector2i(int(u.get("q", 0)), int(u.get("r", 0)))
		if bool(u.get("action_ended", false)):
			failed.append({"unit_id": uid, "class": uclass, "code": "ALREADY_ACTED", "detail": "Formation has already ended its turn."})
			continue
		if bool(u.get("garrisoned", false)) or bool(u.get("routed", false)):
			failed.append({"unit_id": uid, "class": uclass, "code": "UNAVAILABLE", "detail": "Formation is garrisoned or routed."})
			continue
		if eff_action == "RECON" and not uclass in RECON_CLASSES:
			failed.append({"unit_id": uid, "class": uclass, "code": "ACTION_NOT_SUPPORTED_FOR_CLASS", "detail": "RECON is restricted to SCOUT/CAVALRY."})
			continue
		if eff_action == "FLANK" and not uclass in FLANK_CLASSES:
			failed.append({"unit_id": uid, "class": uclass, "code": "ACTION_NOT_SUPPORTED_FOR_CLASS", "detail": "Formation class cannot perform FLANK."})
			continue
		match eff_action:
			"HOLD":
				planned.append({"unit_id": uid, "action": "HOLD", "class": uclass, "from": [origin.x, origin.y], "to": [origin.x, origin.y]})
				reservations["%d,%d" % [origin.x, origin.y]] = uid
			"ATTACK":
				var tgt: Dictionary = cmd.get("target", {})
				var want := str(tgt.get("unit_id", tgt.get("value", ""))).strip_edges().to_upper()
				var preview: Dictionary = svc.preview_attack(uid, want, acting)
				if bool(preview.get("ok", false)):
					planned.append({"unit_id": uid, "action": "ATTACK", "class": uclass, "target_unit_id": want, "from": [origin.x, origin.y]})
				elif exec_ctx.is_empty():
					failed.append({"unit_id": uid, "class": uclass, "code": "ILLEGAL_ATTACK", "detail": str(preview.get("error", "Target is not a legal attack option."))})
				else:
					var disp := _revalidate_attack(mgr, svc, uid, uclass, want, acting, exec_ctx, {}, origin)
					match str(disp.get("verdict", "LEGACY_FAIL")):
						"EXECUTE":
							planned.append(disp.get("planned_row", {}))
						"CANCELLED":
							cancelled.append(disp.get("cancel_row", {}))
						_:
							failed.append({"unit_id": uid, "class": uclass, "code": "ILLEGAL_ATTACK", "detail": str(preview.get("error", "Target is not a legal attack option."))})
			_:
				var dest := _destination_for(uid, origin, eff_action, cmd, target_points, sim, march_mode, policy, reservations, acting)
				if dest.x != -999:
					reservations["%d,%d" % [dest.x, dest.y]] = uid
					planned.append({"unit_id": uid, "action": "MOVE", "class": uclass, "from": [origin.x, origin.y], "to": [dest.x, dest.y], "march_mode": march_mode.to_lower(), "via_action": eff_action})
				else:
					failed.append({"unit_id": uid, "class": uclass, "code": "NO_LEGAL_DESTINATION", "detail": _no_progress_detail(eff_action, cmd)})
	var ok := not planned.is_empty()
	return {
		"ok": ok,
		"command": cmd,
		"snapshot_id": str(obs.get("snapshot_id", "")),
		"effective_action": eff_action,
		"mapping_note": _mapping_note(action),
		"stance_note": TableCls.STANCE_DEFERRED_NOTE,
		"resolved_units": _ids(candidates),
		"scope_frozen": {"op": "UNITS", "unit_ids": _ids(candidates)},
		"planned": planned,
		"failed": failed,
		"cancelled": cancelled,
		"candidate_count": candidates.size() + missing.size(),
		"unexplained_count": 0,
		"code": "" if ok else "NO_VALID_UNITS",
		"detail": "" if ok else "No eligible formation produced a legal action.",
	}


## Full cycle: plan (dry-run) then execute each planned entry through the
## existing authoritative execution path. Returns CompilationResult + execution.
##
## exec_ctx (GROUP_RETARGET_CONTRACT_V1, optional): when non-empty, every
## planned ATTACK is revalidated with a fresh authoritative preview
## immediately before its state mutation (earlier siblings in this same call
## may have killed the target). Same-batch staleness becomes an explicit
## cancellation (HARD / mission-complete) or a scored-list retarget
## (SOFT/NONE); pre-batch invalidity keeps the legacy failure. Empty ctx
## keeps the legacy loop untouched.
static func execute(sim: RefCounted, cmd: Dictionary, selected_unit_id: String = "", side: String = "blue", exec_ctx: Dictionary = {}) -> Dictionary:
	var acting := side.strip_edges().to_lower()
	if acting != "red":
		acting = "blue"
	var draft := plan(sim, cmd, selected_unit_id, acting, exec_ctx)
	if not bool(draft.get("ok", false)):
		draft["executed_units"] = []
		draft["execution_failed"] = (draft.get("failed", []) as Array).duplicate(true)
		draft["cancelled_units"] = (draft.get("cancelled", []) as Array).duplicate(true)
		if not (draft.get("cancelled_units", []) as Array).is_empty() and (draft.get("execution_failed", []) as Array).is_empty():
			draft["execution_status"] = "CANCELLED"
		else:
			draft["execution_status"] = "REJECTED"
		return draft
	var executed: Array = []
	var exec_failed: Array = []
	var cancelled: Array = (draft.get("cancelled", []) as Array).duplicate(true)
	var killed := {}
	var mgr: RefCounted = null
	var svc: RefCounted = null
	if not exec_ctx.is_empty():
		mgr = sim.get_manager()
		svc = sim.get_service()
	var planned_rows: Array = (draft.get("planned", []) as Array)
	var row_idx := 0
	for p_val in planned_rows:
		var p: Dictionary = p_val
		# BATTLE_TERMINAL_CONTRACT_V0: an earlier sibling may have ended the
		# battle (HQ kill). This row and every remaining row cancel cleanly;
		# the loop stops with zero further state mutation.
		var bterm := _sim_battle_terminal(sim)
		if bool(bterm.get("terminal", false)):
			for rj in range(row_idx, planned_rows.size()):
				var rp: Dictionary = planned_rows[rj]
				cancelled.append(_terminal_cancel_row(str(rp.get("unit_id", "")),
					str(rp.get("class", "infantry")).to_upper(),
					str(rp.get("action", "")), exec_ctx, bterm))
			break
		row_idx += 1
		var uid := str(p.get("unit_id", ""))
		var kind := str(p.get("action", ""))
		var res := {}
		if kind == "HOLD":
			res = sim.do_hold(uid, acting)
			if bool(res.get("success", false)):
				executed.append({"unit_id": uid, "action": "HOLD"})
			else:
				exec_failed.append({"unit_id": uid, "code": "UNIT_NOT_READY", "detail": str(res.get("error", "Formation cannot hold now."))})
		elif kind == "ATTACK":
			var want := str(p.get("target_unit_id", ""))
			var fresh_ok := true
			if not exec_ctx.is_empty():
				var fresh: Dictionary = svc.preview_attack(uid, want, acting)
				fresh_ok = bool(fresh.get("ok", false))
			if fresh_ok:
				res = sim.do_attack(uid, want, acting)
				if bool(res.get("success", false)):
					var erow := {"unit_id": uid, "action": "ATTACK", "target_unit_id": want}
					_carry_retarget_telemetry(erow, p)
					executed.append(erow)
					if not exec_ctx.is_empty() and not _target_truth_alive(mgr, want):
						killed[want] = true
				else:
					exec_failed.append({"unit_id": uid, "code": "TARGET_UNREACHABLE", "detail": str(res.get("error", "Target is not a legal attack option."))})
			else:
				var uclass := str(p.get("class", "infantry")).to_upper()
				var from_arr: Array = p.get("from", [])
				var origin := Vector2i(int(from_arr[0]), int(from_arr[1])) if from_arr.size() >= 2 else Vector2i(0, 0)
				var disp := _revalidate_attack(mgr, svc, uid, uclass, want, acting, exec_ctx, killed, origin)
				match str(disp.get("verdict", "LEGACY_FAIL")):
					"EXECUTE":
						var new_t := str((disp.get("planned_row", {}) as Dictionary).get("target_unit_id", ""))
						res = sim.do_attack(uid, new_t, acting)
						if bool(res.get("success", false)):
							var erow2 := {"unit_id": uid, "action": "ATTACK", "target_unit_id": new_t}
							_carry_retarget_telemetry(erow2, disp.get("planned_row", {}))
							executed.append(erow2)
							if not _target_truth_alive(mgr, new_t):
								killed[new_t] = true
						else:
							exec_failed.append({"unit_id": uid, "code": "TARGET_UNREACHABLE", "detail": str(res.get("error", "Target is not a legal attack option."))})
					"CANCELLED":
						cancelled.append(disp.get("cancel_row", {}))
					_:
						exec_failed.append({"unit_id": uid, "code": "TARGET_UNREACHABLE", "detail": "Target is not a legal attack option."})
		else:
			var to_arr: Array = p.get("to", [])
			res = sim.do_move(uid, int(to_arr[0]), int(to_arr[1]), acting, str(p.get("march_mode", "auto")))
			if bool(res.get("success", false)):
				executed.append({"unit_id": uid, "action": "MOVE", "from": p.get("from", []), "to": p.get("to", []), "via_action": str(p.get("via_action", ""))})
			else:
				exec_failed.append({"unit_id": uid, "code": _exec_code(str(res.get("error", ""))), "detail": str(res.get("error", "Destination cannot currently be completed."))})
	var status := "EXECUTED"
	if executed.is_empty():
		if exec_failed.is_empty() and not cancelled.is_empty():
			status = "CANCELLED"
		else:
			status = "FAILED"
	elif not exec_failed.is_empty():
		status = "PARTIAL"
	draft["executed_units"] = executed
	draft["execution_failed"] = exec_failed
	draft["cancelled_units"] = cancelled
	draft["plan_failed"] = (draft.get("failed", []) as Array).duplicate(true)
	draft["execution_status"] = status
	draft["post_fingerprint"] = sim.fingerprint()
	return draft


# --- internals ----------------------------------------------------------

## BATTLE_TERMINAL_CONTRACT_V0: canonical battle read. Sims without the
## battle evaluator (live bridges pre-date it) report non-terminal; the live
## service layer refuses those rows instead (see live executor mapping).
static func _sim_battle_terminal(sim: RefCounted) -> Dictionary:
	if sim == null or not sim.has_method("evaluate_battle"):
		return {}
	return sim.evaluate_battle()


static func _terminal_detail(bterm: Dictionary) -> String:
	var w := str(bterm.get("winner", ""))
	var reason := str(bterm.get("reason", ""))
	var turn := int(bterm.get("turn", 0))
	if w == "blue":
		return "Battle ended at turn %d: RED HQ destroyed — BLUE victory (%s). Action void, not erroneous." % [turn, reason]
	if w == "red":
		return "Battle ended at turn %d: BLUE HQ destroyed — RED victory (%s). Action void, not erroneous." % [turn, reason]
	return "Battle ended at turn %d (%s). Action void, not erroneous." % [turn, reason]


static func _terminal_cancel_row(uid: String, uclass: String, action: String,
	exec_ctx: Dictionary, bterm: Dictionary) -> Dictionary:
	return {"unit_id": uid, "class": uclass, "action": action,
		"code": "BATTLE_ALREADY_TERMINAL",
		"cancel_reason": "BATTLE_ALREADY_TERMINAL",
		"detail": _terminal_detail(bterm),
		"mission_id": str(exec_ctx.get("mission_id", "")),
		"original_target_id": "", "final_target_id": "",
		"target_alive_at_issue": false, "target_alive_at_execution": false,
		"designation_policy": str(exec_ctx.get("designation_policy", "NONE")),
		"revalidation_result": "CANCELLED_BATTLE_TERMINAL",
		"terminal": {"winner": str(bterm.get("winner", "")),
			"reason": str(bterm.get("reason", "")),
			"turn": int(bterm.get("turn", 0))}}


## GROUP_RETARGET_CONTRACT_V1 disposition for one stale ATTACK row (shared by
## plan-time and execution-loop revalidation; called only when the fresh
## authoritative preview already failed and exec_ctx is non-empty).
##
## Verdicts:
##   LEGACY_FAIL: not same-batch staleness (invalid before the batch, or the
##     ATTACKER is unready) — caller emits the legacy ILLEGAL_ATTACK /
##     TARGET_UNREACHABLE failure untouched.
##   CANCELLED: the target legitimately died earlier in this same RED batch;
##     the command is void, not erroneous. cancel_row carries the full
##     telemetry (original/alive/policy/reason).
##   EXECUTE: SOFT/NONE policy with a still-legal scored fallback; planned_row
##     is a normal ATTACK planned row against the fallback plus retarget
##     telemetry. The fallback comes ONLY from the decision-time scored list
##     (exec_ctx.unit_targets, best first, produced by the production target
##     resolver at decide time) — never nearest-enemy, never random, never
##     rescored here.
static func _revalidate_attack(mgr: RefCounted, svc: RefCounted, uid: String,
	uclass: String, want: String, acting: String, exec_ctx: Dictionary,
	killed: Dictionary, origin: Vector2i) -> Dictionary:
	if exec_ctx.is_empty() or want.is_empty():
		return {"verdict": "LEGACY_FAIL"}
	# Attacker-side unreadiness is a real failure, never a target-staleness
	# cancel: do not mislabel a spent/gone attacker as a resolved target.
	var atk: Dictionary = mgr.get_unit_by_id(uid)
	if atk.is_empty() or int(atk.get("soldier_count", 0)) <= 0 \
		or bool(atk.get("action_ended", false)) or bool(atk.get("has_attacked", false)) \
		or bool(atk.get("garrisoned", false)) or bool(atk.get("routed", false)):
		return {"verdict": "LEGACY_FAIL"}
	var alive_now := _target_truth_alive(mgr, want)
	var decision_alive: Array = exec_ctx.get("decision_alive", [])
	var alive_at_issue := decision_alive.has(want)
	# Same-batch test: killed earlier in THIS execute() call (authoritative),
	# or alive at decision time and truth-dead now (only RED acts during a
	# RED batch, so an earlier sibling killed it).
	var same_batch := killed.has(want) or (alive_at_issue and not alive_now)
	if not same_batch:
		return {"verdict": "LEGACY_FAIL"}
	var policy := str(exec_ctx.get("designation_policy", "HARD")).strip_edges().to_upper()
	if policy.is_empty():
		policy = "HARD"
	var complete_on: Array = exec_ctx.get("objective_complete_on", [])
	var mid := str(exec_ctx.get("mission_id", "?"))
	if complete_on.has(want):
		return {"verdict": "CANCELLED", "cancel_row": {
			"unit_id": uid, "class": uclass, "code": "TARGET_ALREADY_RESOLVED",
			"cancel_reason": "MISSION_OBJECTIVE_COMPLETE",
			"detail": "Target %s is already destroyed; its destruction satisfies mission %s success." % [want, mid],
			"mission_id": mid, "original_target_id": want, "final_target_id": "",
			"target_alive_at_issue": alive_at_issue, "target_alive_at_execution": alive_now,
			"designation_policy": policy, "revalidation_result": "CANCELLED_SAME_BATCH"}}
	if policy == "HARD":
		return {"verdict": "CANCELLED", "cancel_row": {
			"unit_id": uid, "class": uclass, "code": "TARGET_ALREADY_RESOLVED",
			"cancel_reason": "HARD_DESIGNATION_HONORED",
			"detail": "Designated target %s is already destroyed; hard designation forbids substitution." % want,
			"mission_id": mid, "original_target_id": want, "final_target_id": "",
			"target_alive_at_issue": alive_at_issue, "target_alive_at_execution": alive_now,
			"designation_policy": policy, "revalidation_result": "CANCELLED_SAME_BATCH"}}
	# SOFT/NONE: bounded re-resolution along the frozen decision-time scored
	# list (best first). Each candidate is gated by the same authoritative
	# preview; nothing is rescored and no new target is invented.
	var scored: Array = (exec_ctx.get("unit_targets", {}) as Dictionary).get(uid, [])
	for tid_val in scored:
		var tid := str(tid_val).strip_edges().to_upper()
		if tid.is_empty() or tid == want:
			continue
		var re: Dictionary = svc.preview_attack(uid, tid, acting)
		if bool(re.get("ok", false)):
			return {"verdict": "EXECUTE", "planned_row": {
				"unit_id": uid, "action": "ATTACK", "class": uclass,
				"target_unit_id": tid, "from": [origin.x, origin.y],
				"original_target_id": want, "retarget_reason": "SCORED_FALLBACK_TARGET",
				"designation_policy": policy, "mission_id": mid,
				"target_alive_at_issue": alive_at_issue, "target_alive_at_execution": alive_now,
				"revalidation_result": "RETARGETED_SAME_BATCH"}}
	return {"verdict": "CANCELLED", "cancel_row": {
		"unit_id": uid, "class": uclass, "code": "TARGET_ALREADY_RESOLVED",
		"cancel_reason": "NO_SCORED_FALLBACK_LEGAL",
		"detail": "Target %s is already destroyed; no other scored target is still legal." % want,
		"mission_id": mid, "original_target_id": want, "final_target_id": "",
		"target_alive_at_issue": alive_at_issue, "target_alive_at_execution": alive_now,
		"designation_policy": policy, "revalidation_result": "CANCELLED_SAME_BATCH"}}


## Authoritative aliveness read (manager truth, not RED belief): missing or
## zero-soldier rows are dead.
static func _target_truth_alive(mgr: RefCounted, tid: String) -> bool:
	if mgr == null or tid.is_empty():
		return false
	var u: Dictionary = mgr.get_unit_by_id(tid)
	if u.is_empty():
		return false
	return int(u.get("soldier_count", 0)) > 0


## Copies retarget/cancel telemetry keys from a planned row onto its executed
## row (additive keys only; legacy executed-row keys untouched).
static func _carry_retarget_telemetry(erow: Dictionary, prow: Dictionary) -> void:
	for k in ["original_target_id", "retarget_reason", "designation_policy",
		"mission_id", "target_alive_at_issue", "target_alive_at_execution",
		"revalidation_result"]:
		if (prow as Dictionary).has(k):
			erow[k] = (prow as Dictionary)[k]


static func _effective_action(action: String) -> String:
	match action:
		"PRESSURE":
			return "ADVANCE"
		"PURSUE", "CONCENTRATE", "REPOSITION", "WITHDRAW":
			return "REPOSITION"
		"RESERVE":
			return "HOLD"
	return action


static func _mapping_note(action: String) -> String:
	match action:
		"PRESSURE":
			return "PRESSURE compiled as ADVANCE (ASSERTIVE forward presence)."
		"PURSUE":
			return "PURSUE compiled as REPOSITION toward the visible enemy formation."
		"CONCENTRATE":
			return "CONCENTRATE compiled as REPOSITION toward ZONE(CENTER)."
		"RESERVE":
			return "RESERVE compiled as HOLD in place."
	return ""


static func _march_mode_for(policy: String) -> String:
	match policy:
		"MINIMAL", "LIMITED":
			return "GREEN_ONLY"
		"EXTENDED", "MAXIMUM":
			return "RED_ALLOWED"
	return "AUTO"


static func _resolve_scope(scope: Dictionary, mgr: RefCounted, selected_unit_id: String, bounds: Dictionary = {}, side: String = "blue") -> Dictionary:
	var pool: Array = ScopeAlgebraCls.live_side(mgr, side)
	var by_id := {}
	for u_val in pool:
		by_id[str((u_val as Dictionary).get("id", "")).to_upper()] = u_val

	# If scope is an AST (has "op")
	var op := str(scope.get("op", "")).strip_edges().to_upper()
	if not op.is_empty():
		var selected_u: Dictionary = by_id.get(selected_unit_id.strip_edges().to_upper(), {})
		var bound_expr: Dictionary = ScopeAlgebraCls.bind_selected(scope, selected_unit_id)
		var deps: Dictionary = {
			"unit_manager": mgr,
			"selected_unit": selected_u,
			"bounds": bounds,
			"side": side,
		}
		
		var res: Dictionary = ScopeAlgebraCls.resolve(bound_expr, deps)
		if bool(res.get("ok", false)):
			var u_list: Array = []
			for uid in (res.get("unit_ids", []) as Array):
				if by_id.has(str(uid)):
					u_list.append(by_id[str(uid)])
			return {"units": u_list, "missing": [], "frozen_expr": res.get("frozen_expr", bound_expr)}

	var kind := str(scope.get("kind", "")).strip_edges().to_upper()
	match kind:
		"ALL_FRIENDLY", "ALL_COMBAT":
			var out: Array = []
			for u_val in pool:
				if kind == "ALL_COMBAT" and not str((u_val as Dictionary).get("class", "")).to_upper() in TableCls.COMBAT_CLASSES:
					continue
				out.append(u_val)
			return {"units": out, "missing": []}
		"CLASS":
			var want := str(scope.get("class", "")).strip_edges().to_upper()
			var out2: Array = []
			for u_val in pool:
				if str((u_val as Dictionary).get("class", "")).to_upper() == want:
					out2.append(u_val)
			return {"units": out2, "missing": []}
		"REGION":
			var want_r := str(scope.get("region", "")).strip_edges().to_upper()
			var out_r: Array = []
			for u_val in pool:
				var q := int((u_val as Dictionary).get("q", 0))
				var r := int((u_val as Dictionary).get("r", 0))
				if ScopeAlgebraCls.is_in_region(q, r, want_r, bounds):
					out_r.append(u_val)
			return {"units": out_r, "missing": []}
		"FORMATION":
			var want_f := str(scope.get("formation", "")).strip_edges().to_upper()
			var out3: Array = []
			for u_val in pool:
				var f := ClustersCls.cluster_of_unit(u_val, side)
				if f.is_empty():
					f = "FIELD"
				if f.strip_edges().to_upper() == want_f or (want_f == "FIELD"):
					out3.append(u_val)
			return {"units": out3, "missing": []}
		"SELECTED":
			var uid := selected_unit_id.strip_edges().to_upper()
			if uid.is_empty():
				return {"units": [], "missing": []}
			if by_id.has(uid):
				return {"units": [by_id[uid]], "missing": []}
			return {"units": [], "missing": [uid]}
		"UNITS":
			var out4: Array = []
			var missing: Array = []
			var id_list: Array = []
			if scope.has("unit_ids") and scope["unit_ids"] is Array:
				id_list = scope["unit_ids"]
			elif scope.has("units") and scope["units"] is Array:
				id_list = scope["units"]
			for id_val in id_list:
				var key := str(id_val).strip_edges().to_upper()
				if by_id.has(key):
					out4.append(by_id[key])
				else:
					missing.append(key)
			return {"units": out4, "missing": missing}
	return {"units": [], "missing": []}


static func _ids(units: Array) -> Array:
	var out: Array = []
	for u_val in units:
		out.append(str((u_val as Dictionary).get("id", "")))
	out.sort()
	return out


static func _order_candidates(candidates: Array, cmd: Dictionary, eff_action: String) -> void:
	var target: Dictionary = cmd.get("target", {})
	var axis := _axis_for(cmd, eff_action)
	if eff_action in ["REPOSITION"] and not _target_points_hint(target).is_empty():
		return
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var sa := _axis_score(Vector2i(int(a.get("q", 0)), int(a.get("r", 0))), axis)
		var sb := _axis_score(Vector2i(int(b.get("q", 0)), int(b.get("r", 0))), axis)
		if sa == sb:
			return str(a.get("id", "")) < str(b.get("id", ""))
		return sa > sb
	)


static func _axis_for(cmd: Dictionary, eff_action: String) -> String:
	var target: Dictionary = cmd.get("target", {})
	var ttype := str(target.get("type", target.get("kind", ""))).strip_edges().to_upper()
	if ttype == "DIRECTION":
		var d := str(target.get("direction", target.get("value", "FORWARD"))).strip_edges().to_upper()
		if d == "BACKWARD":
			return "BACK"
		return d
	match eff_action:
		"RETREAT":
			return "BACK"
	return "FORWARD"


## Resolve target geometry to destination points (authorized knowledge only).
## Returns Array[Vector2i], [] means "no target needed" (HOLD/ATTACK/direction
## moves), null means "target required but unresolvable" (honest failure).
static func _target_points(cmd: Dictionary, eff_action: String, sim: RefCounted, obs: Dictionary, side: String = "blue") -> Variant:
	var action := str(cmd.get("action", "")).strip_edges().to_upper()
	var target: Dictionary = cmd.get("target", {})
	var ttype := str(target.get("type", target.get("kind", ""))).strip_edges().to_upper()
	if eff_action in ["HOLD", "ATTACK"]:
		return []
	if eff_action in ["ADVANCE", "RECON"]:
		return []
	if eff_action == "FLANK":
		# FLANK geometry is lateral+forward; a FORMATION target names the
		# operational object (visible enemy only) without changing the axis
		# rule. Visibility enforced here from acting-side-authorized contacts.
		if ttype == "FORMATION":
			var want_f := str(target.get("unit_id", target.get("value", ""))).strip_edges().to_upper()
			for e_val in (obs.get("known_enemy_units", []) as Array):
				var ef: Dictionary = e_val
				if str(ef.get("unit_id", "")).strip_edges().to_upper() == want_f and str(ef.get("contact_state", "")) == "current_visible":
					return [Vector2i(int(ef.get("q", 0)), int(ef.get("r", 0)))]
			return null
		return []
	match action:
		"PURSUE":
			if ttype == "FORMATION":
				var want := str(target.get("unit_id", target.get("value", ""))).strip_edges().to_upper()
				for e_val in (obs.get("known_enemy_units", []) as Array):
					var e2: Dictionary = e_val
					if str(e2.get("unit_id", "")).strip_edges().to_upper() == want and str(e2.get("contact_state", "")) == "current_visible":
						return [Vector2i(int(e2.get("q", 0)), int(e2.get("r", 0)))]
				return null
			return _objective_points(obs)
		"CONCENTRATE":
			return [_zone_point(sim, "CENTER", side)]
		"WITHDRAW", "REPOSITION":
			match ttype:
				"HEX":
					var hex := Vector2i(int(target.get("q", 0)), int(target.get("r", 0)))
					if target.has("value") and target["value"] is Vector2i:
						hex = target["value"]
					if not _hex_within_map_bounds(sim, hex):
						return null
					return [hex]
				"FORMATION":
					var want2 := str(target.get("unit_id", target.get("value", ""))).strip_edges().to_upper()
					var mgr: RefCounted = sim.get_manager()
					var u: Dictionary = mgr.get_unit_by_id(want2)
					if u.is_empty():
						u = mgr.get_unit_by_id(want2.to_lower())
					if u.is_empty():
						for e_val in (obs.get("known_enemy_units", []) as Array):
							var e3: Dictionary = e_val
							if str(e3.get("unit_id", "")).strip_edges().to_upper() == want2 and str(e3.get("contact_state", "")) == "current_visible":
								return [Vector2i(int(e3.get("q", 0)), int(e3.get("r", 0)))]
						return null
					if str(u.get("faction", "")) != side:
						return null
					return [Vector2i(int(u.get("q", 0)), int(u.get("r", 0)))]
				"ZONE":
					return [_zone_point(sim, str(target.get("zone", target.get("value", "CENTER"))), side)]
				"OBJECTIVE":
					return _objective_points(obs)
	return []


static func _target_points_hint(target: Dictionary) -> Array:
	if str(target.get("type", "")).strip_edges().to_upper() in ["HEX", "FORMATION", "ZONE", "OBJECTIVE"]:
		return [true]
	return []


## Scenario board authority for explicit coordinates: a HEX target outside the
## scenario rect is unresolvable (honest TARGET_NOT_FOUND), never clamped.
static func _hex_within_map_bounds(sim: RefCounted, hex: Vector2i) -> bool:
	if not sim.has_method("map_bounds"):
		return true
	var mb: Dictionary = sim.map_bounds()
	if mb.is_empty():
		return true
	return hex.x >= int(mb.get("q_min", hex.x)) and hex.x <= int(mb.get("q_max", hex.x)) \
		and hex.y >= int(mb.get("r_min", hex.y)) and hex.y <= int(mb.get("r_max", hex.y))


static func _zone_point(sim: RefCounted, zone: String, side: String = "blue") -> Vector2i:
	var z := zone.strip_edges().to_upper()
	if z == "HQ":
		var mgr: RefCounted = sim.get_manager()
		for u_val in mgr.get_all_units_including_garrisoned():
			if u_val is Dictionary and str((u_val as Dictionary).get("faction", "")) == side and str((u_val as Dictionary).get("class", "")).to_lower() == "hq":
				return Vector2i(int((u_val as Dictionary).get("q", 0)), int((u_val as Dictionary).get("r", 0)))
		# No live HQ: fall back to the acting side's rear quarter (BLUE west,
		# RED east). Deterministic; reached only when the HQ is gone.
		return Vector2i(27, 0) if side == "red" else Vector2i(-27, 0)
	var bounds: Dictionary = sim.map_bounds()
	if bounds.is_empty():
		return Vector2i(0, 0)
	return Vector2i(
		(int(bounds.get("q_min", -30)) + int(bounds.get("q_max", -20))) / 2,
		(int(bounds.get("r_min", -5)) + int(bounds.get("r_max", 5))) / 2)


static func _objective_points(obs: Dictionary) -> Variant:
	var best: Variant = null
	var best_id := ""
	for e_val in (obs.get("known_enemy_units", []) as Array):
		var e2: Dictionary = e_val
		if str(e2.get("contact_state", "")) != "current_visible":
			continue
		if best == null or str(e2.get("unit_id", "")) < best_id:
			best = Vector2i(int(e2.get("q", 0)), int(e2.get("r", 0)))
			best_id = str(e2.get("unit_id", ""))
	if best == null:
		return null
	return [best]


static func _destination_for(uid: String, origin: Vector2i, eff_action: String, cmd: Dictionary, target_points: Array, sim: RefCounted, march_mode: String, policy: String, reservations: Dictionary, side: String = "blue") -> Vector3i:
	var svc: RefCounted = sim.get_service()
	var area: Dictionary = svc.reachable_area(uid, side, march_mode.to_lower())
	if not bool(area.get("ok", false)):
		return Vector3i(-999, -999, 0)
	var reachable: Array = area.get("reachable", [])
	if reachable.is_empty():
		return Vector3i(-999, -999, 0)
	var scored: Array = []
	# STEP 2: REPOSITION-family verbs with a DIRECTION target (WITHDRAW
	# BACKWARD, REPOSITION LEFT, ...) score by side-relative axis progress,
	# like ADVANCE. Point-targeted forms (HEX/FORMATION/ZONE/OBJECTIVE)
	# keep minimizing distance to the resolved point. Previously a
	# DIRECTION target fell through to cheapest-hex; no Step-1 caller or
	# gate used that shape, so nothing depended on it.
	var point_targeted := eff_action == "REPOSITION" and not _target_points_hint(cmd.get("target", {})).is_empty()
	if eff_action == "REPOSITION" and point_targeted:
		for entry_val in reachable:
			if not entry_val is Dictionary:
				continue
			var entry: Dictionary = entry_val
			var coord := Vector2i(int(entry.get("q", -999)), int(entry.get("r", -999)))
			if coord.x == -999 or coord == origin:
				continue
			if reservations.has("%d,%d" % [coord.x, coord.y]):
				continue
			var dist := 1 << 30
			for tp in target_points:
				if tp is Vector2i:
					dist = mini(dist, HexUtilsCls.hex_distance_axial(coord, tp))
			scored.append({"coord": coord, "key": dist, "cost": float(entry.get("cost", 1.0))})
		if scored.is_empty():
			return Vector3i(-999, -999, 0)
		scored.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			if int(a["key"]) != int(b["key"]):
				return int(a["key"]) < int(b["key"])
			if float(a["cost"]) != float(b["cost"]):
				return float(a["cost"]) < float(b["cost"])
			var ca: Vector2i = a["coord"]
			var cb: Vector2i = b["coord"]
			return "%d,%d" % [ca.x, ca.y] < "%d,%d" % [cb.x, cb.y]
		)
	else:
		var axis := _axis_for(cmd, eff_action)
		# FLANK with a named visible enemy object: keep the lateral+forward
		# geometry rule, biased toward the object (minimize distance to it
		# among hexes that still make forward progress). Pure intent scoring
		# over already-legal hexes; legality stays in the service.
		var flank_point := Vector2i(-999, -999)
		if eff_action == "FLANK" and not target_points.is_empty() and target_points[0] is Vector2i:
			flank_point = target_points[0]
		var origin_score := _axis_score(origin, axis, side)
		for entry_val in reachable:
			if not entry_val is Dictionary:
				continue
			var entry2: Dictionary = entry_val
			var coord2 := Vector2i(int(entry2.get("q", -999)), int(entry2.get("r", -999)))
			if coord2.x == -999 or coord2 == origin:
				continue
			if reservations.has("%d,%d" % [coord2.x, coord2.y]):
				continue
			var progress := _axis_score(coord2, axis, side) - origin_score
			if progress <= 0.0:
				continue
			var dist_to_object := 0
			if flank_point.x != -999:
				dist_to_object = HexUtilsCls.hex_distance_axial(coord2, flank_point)
			scored.append({"coord": coord2, "key": progress, "cost": float(entry2.get("cost", 1.0)), "obj": dist_to_object, "flank": flank_point.x != -999})
		if scored.is_empty():
			return Vector3i(-999, -999, 0)
		var minimal := policy == "MINIMAL"
		var maximal_cost := policy == "MAXIMUM"
		scored.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			if bool(a.get("flank", false)) and bool(b.get("flank", false)) and int(a.get("obj", 0)) != int(b.get("obj", 0)):
				return int(a.get("obj", 0)) < int(b.get("obj", 0))
			if float(a["key"]) != float(b["key"]):
				return float(a["key"]) < float(b["key"]) if minimal else float(a["key"]) > float(b["key"])
			if float(a["cost"]) != float(b["cost"]):
				return float(a["cost"]) > float(b["cost"]) if maximal_cost else float(a["cost"]) < float(b["cost"])
			var ca2: Vector2i = a["coord"]
			var cb2: Vector2i = b["coord"]
			return "%d,%d" % [ca2.x, ca2.y] < "%d,%d" % [cb2.x, cb2.y]
		)
	var best_c: Vector2i = scored[0]["coord"]
	return Vector3i(best_c.x, best_c.y, 0)


## Battlefield direction semantics (logical axial coordinates; BLUE FORWARD
## is EAST/+q; camera orientation never enters). Mirrors the production
## planner axis model so Step1 intent means the same thing everywhere.
##
## STEP 2 side-relative frame: absolute NORTH/SOUTH/EAST/WEST are
## map-relative for both sides. Relative FORWARD/BACKWARD/LEFT/RIGHT
## resolve against the acting faction's facing. RED faces -q (180 degrees
## from BLUE), so RED FORWARD = -q, RED BACK = +q, and RED LEFT/RIGHT are
## the negated mirror of BLUE RIGHT/LEFT (a 180-degree facing swaps hands).
static func _axis_score(coord: Vector2i, axis: String, side: String = "blue") -> float:
	var q := float(coord.x)
	var r := float(coord.y)
	var axial_y := q + 2.0 * r
	if side == "red":
		match axis:
			"NORTH":
				return -axial_y
			"SOUTH":
				return axial_y
			"EAST":
				return q
			"WEST":
				return -q
			"FORWARD":
				return -q
			"BACK":
				return q
			"RIGHT":
				return axial_y - 1.5 * q
			"LEFT":
				return -axial_y - 1.5 * q
		return -q
	match axis:
		"NORTH":
			return -axial_y
		"SOUTH":
			return axial_y
		"EAST", "FORWARD":
			return q
		"WEST", "BACK":
			return -q
		"RIGHT":
			return axial_y + 1.5 * q
		"LEFT":
			return -axial_y + 1.5 * q
	return q


static func _no_progress_detail(eff_action: String, cmd: Dictionary) -> String:
	var target: Dictionary = cmd.get("target", {})
	if str(target.get("type", "")).strip_edges().to_upper() == "DIRECTION":
		return "No unblocked legal destination makes progress toward %s." % str(target.get("direction", "?")).to_upper()
	return "No unblocked legal destination found toward the target."


static func _exec_code(err: String) -> String:
	var lower := err.to_lower()
	if lower.contains("ccupied"):
		return "OCCUPIED"
	if lower.contains("budget") or lower.contains("march"):
		return "INSUFFICIENT_MOVEMENT"
	return "TARGET_UNREACHABLE"
