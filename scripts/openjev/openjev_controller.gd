class_name OpenJevController
extends "res://scripts/cloud2/cloud2_turn_controller.gd"

## OPENJEV LIVE V0 — RED Hands controller (OpenJev direct legal-action authority).
##
## Subclasses the production Cloud2TurnController and inherits the ENTIRE
## General layer untouched: provider/fallback General planning, mission
## hierarchy, event/periodic reviews, staged-plan adoption, plan memory,
## trace, and logging. The ONLY replaced step is tactical execution:
## _execute_orders runs the OpenJev enumerate -> score -> revalidate ->
## execute loop instead of the deterministic six-slot solver's orders
## (which are still computed by red_turn for plan maintenance, then
## explicitly discarded and logged as bypassed).
##
## Loop (per RED phase):
##   terminal? -> enumerate ALL legal RED actions globally -> score ALL via
##   POST /score -> global argmax -> fresh-revalidate -> execute via live
##   RED authorities + presentation -> terminal? -> repeat.
## No unit preselector, no skill selector, no pruning. END_TURN fires only
## when the pool holds nothing else (human-equivalent condition).
##
## Failures are EXPLICIT: any OpenJev error routes to the deterministic
## HOLD-ALL fallback with an "OPENJEV ERROR -> FALLBACK" flag (counted,
## logged, HUD-visible). Silent fallback never happens.

signal openjev_decision(info: Dictionary)

const OJEnumCls = preload("res://scripts/openjev/openjev_enumerator.gd")
const OJLaunchCls = preload("res://scripts/openjev/openjev_launcher.gd")
const OJRulesCls = preload("res://scripts/openjev/openjev_rules.gd")
const OJHttpCls = preload("res://scripts/openjev/openjev_http.gd")

const OJ_MAX_STEPS := 150
const OJ_MAX_CONSECUTIVE_STALE := 5
const OJ_SCORE_BASE_TIMEOUT_MS := 60000
const OJ_SCORE_PER_CANDIDATE_MS := 2000
const OJ_SCORE_MAX_TIMEOUT_MS := 300000
const OJ_READY_POLL_SEC := 0.5

var _oj_decisions := 0
var _oj_fallbacks := 0
var _oj_stales := 0
var _oj_moves := 0
var _oj_attacks := 0
var _oj_waits := 0
var _oj_other := 0
var _oj_exec_failures := 0
var _oj_lat_ms: Array = []
var _oj_pool_sizes: Array = []
var _oj_last := {}
var _oj_log: Array = []
var _oj_fallback_active := false
var _oj_fallback_reason := ""
var _oj_turns := 0


func red_controller_mode() -> String:
	return "OPENJEV"


## OpenJev failure policy: never block on a human decision; an explicit
## HOLD-ALL fallback resolves the phase (counted + flagged, never silent).
func _wait_for_decision() -> String:
	_oj_fallbacks += 1
	_oj_fallback_active = true
	_oj_fallback_reason = "auto_hold_on_failure"
	print("[OpenJev] _wait_for_decision auto-HOLD (explicit fallback #%d)" % _oj_fallbacks)
	return "hold"


func openjev_stats() -> Dictionary:
	var lat_sorted: Array = _oj_lat_ms.duplicate()
	lat_sorted.sort()
	var pools_sorted: Array = _oj_pool_sizes.duplicate()
	pools_sorted.sort()
	return {
		"authority": "OPENJEV_LIVE",
		"red_turns": _oj_turns,
		"decision_count": _oj_decisions,
		"fallback_count": _oj_fallbacks,
		"fallback_active": _oj_fallback_active,
		"fallback_reason": _oj_fallback_reason,
		"stale_count": _oj_stales,
		"moves": _oj_moves,
		"attacks": _oj_attacks,
		"waits": _oj_waits,
		"other": _oj_other,
		"exec_failures": _oj_exec_failures,
		"latency_ms": lat_sorted,
		"pool_sizes": pools_sorted,
		"last": _oj_last.duplicate(true),
		"service": OJLaunchCls.status_snapshot(),
	}


func _oj_note_decision(info: Dictionary) -> void:
	_oj_last = info.duplicate(true)
	_oj_log.append(info.duplicate(true))
	if _oj_log.size() > 60:
		_oj_log.pop_front()
	openjev_decision.emit(info.duplicate(true))


## THE override: OpenJev direct-action execution replaces six-slot orders.
func _execute_orders(obs: Dictionary, packet: Dictionary, parsed: Dictionary, model_res: Dictionary, pre_fp: String, turn: int, attempt: int, auto_retries: int = 0) -> Dictionary:
	var bypassed := int(parsed.get("order_count", 0))
	print("[OpenJev] RED_EXECUTION begin turn=%d six_slot_orders_bypassed=%d" % [turn, bypassed])
	_set_state("EXECUTING", "OpenJev RED Hands deciding (turn %d; %d six-slot order(s) bypassed)." % [turn, bypassed])
	TraceCls.set_stage("EXECUTING", "OpenJev RED Hands deciding (turn %d)." % turn)
	_oj_turns += 1
	_oj_fallback_active = false
	_oj_fallback_reason = ""

	var ready := await _await_openjev_ready(turn)
	if not bool(ready.get("ok", false)):
		_oj_fallbacks += 1
		_oj_fallback_active = true
		_oj_fallback_reason = str(ready.get("error", "openjev_unavailable"))
		_oj_note_decision({"event": "OPENJEV_ERROR_FALLBACK", "turn": turn,
			"reason": _oj_fallback_reason})
		_combat_log("OPENJEV ERROR -> DETERMINISTIC FALLBACK ACTIVE (%s)" % _oj_fallback_reason)
		var held := await _end_hold_all("openjev:" + _oj_fallback_reason)
		_last_view["openjev"] = _openjev_telemetry(turn)
		held["openjev"] = _openjev_telemetry(turn)
		return held

	var en := OJEnumCls.new()
	var cerr: String = en.configure(_bridge.get_manager(), _bridge.get_service(),
		_bridge.get_projector(), _bridge.get_shell().get("hex_grid"),
		_bridge.map_bounds(), Callable(_bridge.get_shell(), "_battle_over"),
		_bridge.get_shell().get("_river_cells"), _bridge.get_shell().get("_stronghold_cells"))
	if cerr != "":
		_oj_fallbacks += 1
		_oj_fallback_active = true
		_oj_fallback_reason = "enumerator_not_ready:" + cerr
		_oj_note_decision({"event": "OPENJEV_ERROR_FALLBACK", "turn": turn,
			"reason": _oj_fallback_reason})
		_combat_log("OPENJEV ERROR -> DETERMINISTIC FALLBACK ACTIVE (%s)" % _oj_fallback_reason)
		var held2 := await _end_hold_all("openjev:" + _oj_fallback_reason)
		_last_view["openjev"] = _openjev_telemetry(turn)
		held2["openjev"] = _openjev_telemetry(turn)
		return held2

	var plan: Dictionary = _manager.get_plan() if _manager != null else {}
	var unit_mission := _unit_mission_map(plan)
	var order_views: Array = []
	var trace_views: Array = []
	TraceCls.set_orders(trace_views)
	var executed_count := 0
	var failed_count := 0
	var stale_streak := 0
	var cap_hit := false
	var end_turn_seen := false
	var steps := 0
	while steps < OJ_MAX_STEPS:
		if _shell_battle_over():
			break
		await _pause_point("Before OpenJev decision %d (turn %d)." % [steps + 1, turn])
		var pool: Dictionary = en.enumerate_all()
		if bool(pool.get("terminal", false)):
			break
		var cands: Array = pool.get("candidates", [])
		if cands.is_empty():
			break
		if cands.size() == 1 and str((cands[0] as Dictionary).get("action_type", "")) == "END_TURN":
			end_turn_seen = true
			order_views.append({"index": order_views.size() + 1, "status": "END_TURN",
				"order": {"action": "END_TURN"}, "mission_id": "",
				"openjev_mission_id": "", "executed": [], "failed": [],
				"candidate_count": 1})
			break
		steps += 1
		_oj_pool_sizes.append(cands.size())
		_set_state("EXECUTING", "OpenJev scoring %d legal action(s) (turn %d, step %d)." % [cands.size(), turn, steps])
		var req := _build_score_request(obs, plan, unit_mission, cands, turn)
		var timeout_ms := mini(OJ_SCORE_MAX_TIMEOUT_MS,
			OJ_SCORE_BASE_TIMEOUT_MS + OJ_SCORE_PER_CANDIDATE_MS * cands.size())
		var t0 := Time.get_ticks_msec()
		var res := OJHttpCls.post_json(OJLaunchCls.active_host(), OJLaunchCls.active_port(),
			"/score", JSON.stringify(req), timeout_ms)
		var client_ms := float(Time.get_ticks_msec() - t0)
		if not bool(res.get("ok", false)):
			failed_count += 1
			_oj_exec_failures += 1
			_oj_note_decision({"event": "SCORE_TRANSPORT_ERROR", "turn": turn, "step": steps,
				"candidate_count": cands.size(), "error": str(res.get("error", "?"))})
			print("[OpenJev] SCORE_TRANSPORT_ERROR %s — explicit fallback" % str(res.get("error", "?")))
			break
		var body: Variant = JSON.parse_string(str(res.get("body", "")))
		if not body is Dictionary or not bool((body as Dictionary).get("ok", false)):
			failed_count += 1
			_oj_exec_failures += 1
			var code := str((body as Dictionary).get("error", {}).get("code", "BAD_SCORE_BODY")) if body is Dictionary else "BAD_SCORE_BODY"
			_oj_note_decision({"event": "SCORE_ERROR", "turn": turn, "step": steps,
				"candidate_count": cands.size(), "error": code})
			print("[OpenJev] SCORE_ERROR %s — explicit fallback" % code)
			break
		var scored: Dictionary = body
		var winner_id := str(scored.get("selected_candidate_id", ""))
		var winner := _find_candidate(cands, winner_id)
		_oj_decisions += 1
		_oj_lat_ms.append(client_ms)
		var serv_ms := float((scored.get("latency_ms", {}) as Dictionary).get("total", 0.0))
		if winner.is_empty():
			failed_count += 1
			_oj_exec_failures += 1
			_oj_note_decision({"event": "WINNER_NOT_IN_POOL", "turn": turn, "step": steps,
				"selected": winner_id, "candidate_count": cands.size()})
			print("[OpenJev] WINNER_NOT_IN_POOL %s — explicit fallback" % winner_id)
			break
		# Fresh revalidation against CURRENT truth (read-only previews/gates).
		var rev: Dictionary = en.revalidate(winner)
		if not bool(rev.get("ok", false)):
			stale_streak += 1
			_oj_stales += 1
			_oj_note_decision({"event": "STALE_SELECTED_CANDIDATE", "turn": turn, "step": steps,
				"selected": winner_id, "code": str(rev.get("code", "?")),
				"streak": stale_streak})
			print("[OpenJev] STALE_SELECTED_CANDIDATE %s code=%s (re-enumerate+rescore)" % [winner_id, str(rev.get("code", "?"))])
			if stale_streak >= OJ_MAX_CONSECUTIVE_STALE:
				print("[OpenJev] stale streak exhausted — explicit fallback")
				break
			continue
		stale_streak = 0
		var ex: Dictionary = await _openjev_execute(winner)
		if str(ex.get("code", "")) == "BATTLE_ALREADY_TERMINAL":
			break
		if bool(ex.get("success", false)):
			executed_count += 1
			_count_action(str(winner.get("action_type", "")))
		else:
			failed_count += 1
			_oj_exec_failures += 1
		var view := {
			"index": order_views.size() + 1,
			"status": "EXECUTED" if bool(ex.get("success", false)) else "FAILED",
			"order": winner.duplicate(true),
			"mission_id": "",
			"openjev_mission_id": str(unit_mission.get(str(winner.get("unit_id", "")), "")),
			"executed": [{"unit_id": str(winner.get("unit_id", "")),
				"action": str(winner.get("action_type", "")),
				"detail": ex}] if bool(ex.get("success", false)) else [],
			"failed": [] if bool(ex.get("success", false)) else [{"unit_id": str(winner.get("unit_id", "")),
				"action": str(winner.get("action_type", "")),
				"code": str(ex.get("code", "EXEC_FAILED")),
				"detail": str(ex.get("error", ""))}],
			"candidate_count": cands.size(),
			"selected": winner_id,
			"top5": (scored.get("top5", []) as Array).duplicate(),
			"latency_ms": client_ms,
			"server_ms": serv_ms,
		}
		order_views.append(view)
		trace_views.append(view)
		TraceCls.set_orders(trace_views)
		_oj_note_decision({"event": "DECISION", "turn": turn, "step": steps,
			"selected": winner_id, "candidate_count": cands.size(),
			"latency_ms": client_ms, "server_ms": serv_ms,
			"executed": bool(ex.get("success", false))})
		_combat_log("[OpenJev] %s (pool=%d, %.1fs)" % [winner_id, cands.size(), client_ms / 1000.0])
		_update_shell_turn_label(turn, steps, winner_id, cands.size(), client_ms)
		if _shell_battle_over():
			break
		await get_tree().process_frame
	if steps >= OJ_MAX_STEPS and not _shell_battle_over():
		cap_hit = true
		print("[OpenJev] STEP_CAP %d hit — holding remaining units (explicit)" % OJ_MAX_STEPS)
	if cap_hit or failed_count > 0:
		var held_rows: Array = await _hold_remaining(unit_mission, order_views.size() + 1)
		for hv in held_rows:
			order_views.append(hv)
			trace_views.append(hv)
		TraceCls.set_orders(trace_views)
		if failed_count > 0 or cap_hit:
			_oj_fallbacks += 1
			_oj_fallback_active = true
			_oj_fallback_reason = "step_cap_hold" if cap_hit else "mid_loop_error_hold"
			_combat_log("OPENJEV %s -> HOLD REMAINING (explicit)" % ("STEP CAP" if cap_hit else "ERROR"))
	return _finish_openjev(obs, packet, parsed, model_res, pre_fp, turn, attempt,
		auto_retries, order_views, executed_count, failed_count, bypassed,
		end_turn_seen, cap_hit)


## Wait for model READY (bounded). The battle may start while the worker
## loads; the RED phase honestly waits here with visible status.
func _await_openjev_ready(turn: int) -> Dictionary:
	if OJLaunchCls.is_ready():
		return {"ok": true}
	if OJLaunchCls.is_disabled():
		return {"ok": false, "error": str(OJLaunchCls.status_snapshot().get("last_error", "DISABLED"))}
	if not OJLaunchCls.boot_in_progress():
		var sp := OJLaunchCls.spawn_owned_or_fixed()
		if not bool(sp.get("ok", false)):
			return {"ok": false, "error": str(sp.get("error", "SPAWN_FAILED"))}
		if str(sp.get("status", "")) == "READY":
			return {"ok": true}
	var deadline := Time.get_ticks_msec() + OJLaunchCls.startup_timeout_ms()
	var frames := 0
	while Time.get_ticks_msec() < deadline:
		if OJLaunchCls.is_ready():
			return {"ok": true}
		if OJLaunchCls.is_disabled():
			return {"ok": false, "error": str(OJLaunchCls.status_snapshot().get("last_error", "DISABLED"))}
		if not OJLaunchCls.boot_in_progress():
			return {"ok": false, "error": "BOOT_ABORTED"}
		if OJLaunchCls.fixed_url_mode():
			var ep: Dictionary = OJLaunchCls.fixed_endpoint()
			var res := OJHttpCls.get_json(str(ep.get("host", "127.0.0.1")),
				int(ep.get("port", 11441)), "/health", 4000)
			if bool(res.get("ok", false)):
				var h: Variant = JSON.parse_string(str(res.get("body", "")))
				if h is Dictionary:
					var v: Dictionary = OJLaunchCls.verify_health_dict(h)
					if bool(v.get("ok", false)):
						OJLaunchCls.adopt_fixed_health(v.get("identity", {}),
							(h as Dictionary).get("load", {}),
							str(ep.get("host", "")), int(ep.get("port", 11441)))
						return {"ok": true}
					OJLaunchCls.mark_disabled("FIXED_IDENTITY_MISMATCH: %s" % str(v.get("error", "?")))
					return {"ok": false, "error": "FIXED_IDENTITY_MISMATCH"}
		else:
			if not OJLaunchCls.owned_pid_alive():
				OJLaunchCls.mark_disabled("WORKER_DIED_DURING_BOOT")
				return {"ok": false, "error": "WORKER_DIED_DURING_BOOT"}
			var snap: Dictionary = OJLaunchCls.status_snapshot()
			var res2 := OJHttpCls.get_json(str(snap.get("host", "127.0.0.1")),
				int(snap.get("port", 11441)), "/health", 4000)
			if bool(res2.get("ok", false)):
				var h2: Variant = JSON.parse_string(str(res2.get("body", "")))
				if h2 is Dictionary:
					var v2: Dictionary = OJLaunchCls.verify_health_dict(h2)
					if bool(v2.get("ok", false)):
						OJLaunchCls.mark_ready(v2.get("identity", {}), (h2 as Dictionary).get("load", {}))
						return {"ok": true}
					OJLaunchCls.mark_disabled(str(v2.get("error", "HEALTH_MISMATCH")))
					return {"ok": false, "error": str(v2.get("error", "HEALTH_MISMATCH"))}
		frames += 1
		if frames % 2 == 0:
			_set_state("EXECUTING", "OpenJev loading model… (turn %d, %ds)" % [turn, frames / 2])
		await get_tree().create_timer(OJ_READY_POLL_SEC).timeout
	OJLaunchCls.on_boot_timeout()
	return {"ok": false, "error": "STARTUP_TIMEOUT"}


func _unit_mission_map(plan: Dictionary) -> Dictionary:
	var out := {}
	for m_val in (plan.get("missions", []) as Array):
		if not m_val is Dictionary:
			continue
		var m: Dictionary = m_val
		var mid := str(m.get("mission_id", ""))
		for uid in (m.get("assigned_units", []) as Array):
			out[str(uid)] = mid
	return out


func _find_candidate(cands: Array, cid: String) -> Dictionary:
	for c_val in cands:
		if str((c_val as Dictionary).get("candidate_id", "")) == cid:
			return c_val
	return {}


## Compact versioned local contract: authorized state + commander context
## + runtime rules + full candidate pool. No hidden BLUE truth: knowledge
## comes from the RED projector ledger, events from the RED observation.
func _build_score_request(obs: Dictionary, plan: Dictionary,
	unit_mission: Dictionary, cands: Array, turn: int) -> Dictionary:
	var missions: Array = []
	for m_val in (plan.get("missions", []) as Array):
		if not m_val is Dictionary:
			continue
		var m: Dictionary = m_val
		missions.append({
			"mission_id": str(m.get("mission_id", "")),
			"task": str(m.get("task", "")),
			"area": str(m.get("area", "")),
			"status": str(m.get("status", "")),
			"assigned_units": (m.get("assigned_units", []) as Array).duplicate(),
			"objective": (m.get("objective", {}) as Dictionary).duplicate(true),
		})
	var concept: Dictionary = (plan.get("concept", {}) as Dictionary).duplicate(true)
	var doctrine: Dictionary = (plan.get("doctrine", {}) as Dictionary).duplicate(true)
	var knowledge: Dictionary = _bridge.build_knowledge("red")
	var events: Array = ((obs.get("recent_events", []) as Array).duplicate(true)).slice(-5)
	return {
		"schema_version": OJLaunchCls.REQUEST_VERSION,
		"battle_id": str(obs.get("battle_id", "")),
		"turn": turn,
		"side": "red",
		"authorized_state": {
			"knowledge": knowledge,
			"mission": (obs.get("mission", {}) as Dictionary).duplicate(true),
			"recent_events": events,
		},
		"commander_context": {
			"plan_source": str(plan.get("source", "none")),
			"plan_version": int(plan.get("plan_version", 0)),
			"concept": concept,
			"doctrine": doctrine,
			"missions": missions,
			"unit_mission": unit_mission.duplicate(true),
		},
		"runtime_rules": OJRulesCls.runtime_rules(),
		"candidates": cands,
	}


## Execute ONE revalidated candidate through the live RED authorities
## (the exact branches the live executor's RED path uses), plus the same
## renderer/fog/Step6 presentation. Returns the authority result dict.
func _openjev_execute(cand: Dictionary) -> Dictionary:
	var t: String = str(cand.get("action_type", ""))
	var uid: String = str(cand.get("unit_id", ""))
	var shell := _bridge.get_shell() as Node
	var mgr: RefCounted = _bridge.get_manager()
	var svc: RefCounted = _bridge.get_service()
	match t:
		"MOVE":
			var d: Array = cand.get("destination", [0, 0])
			var res: Dictionary = svc.execute_move_intent(uid, Vector2i(int(d[0]), int(d[1])), "red", "green")
			if str(res.get("code", "")) == "BATTLE_ALREADY_TERMINAL":
				return {"success": false, "code": "BATTLE_ALREADY_TERMINAL"}
			if bool(res.get("success", false)):
				var renderer: Node = shell.get("unit_renderer") as Node
				if renderer != null and renderer.has_method("update_unit_position"):
					renderer.call("update_unit_position", uid, int(d[0]), int(d[1]))
				if shell.has_method("_fog_recalc"):
					shell.call("_fog_recalc", "enemy_move")
				if shell.has_method("_show_combat_log"):
					shell.call("_show_combat_log", "[%s] 이동 — OpenJev RED MOVE" % uid)
				_bridge.notify_mutation("openjev_live_red_move")
			return res
		"ATTACK":
			var target := str(cand.get("target_id", ""))
			var s6: RefCounted = _bridge.get_step6()
			var mods: Dictionary = s6.attacker_bonus_vs(mgr, uid, target) if s6 != null else {}
			var res2: Dictionary = svc.execute_attack_intent(uid, target, "red", mods)
			if str(res2.get("code", "")) == "BATTLE_ALREADY_TERMINAL":
				return {"success": false, "code": "BATTLE_ALREADY_TERMINAL"}
			if bool(res2.get("success", false)):
				await _run_openjev_attack_presentation(uid, target, res2)
				_bridge.notify_mutation("openjev_live_red_attack")
			return res2
		"ASSAULT":
			var res3: Dictionary = mgr.execute_stronghold_assault(uid,
				str(cand.get("stronghold_id", "")), str(cand.get("garrison_target_id", "")), {})
			if str(res3.get("code", "")) == "BATTLE_ALREADY_TERMINAL":
				return {"success": false, "code": "BATTLE_ALREADY_TERMINAL"}
			if bool(res3.get("success", false)):
				if shell.has_method("_fog_recalc"):
					shell.call("_fog_recalc", "enemy_attack")
				if shell.has_method("_show_combat_log"):
					shell.call("_show_combat_log", "[%s] 강습 -> [%s] — OpenJev RED ASSAULT" % [uid, str(cand.get("stronghold_id", ""))])
				_bridge.notify_mutation("openjev_live_red_assault")
			return res3
		"WAIT":
			var res4: Dictionary = svc.execute_hold_intent(uid, "red")
			if str(res4.get("code", "")) == "BATTLE_ALREADY_TERMINAL":
				return {"success": false, "code": "BATTLE_ALREADY_TERMINAL"}
			if bool(res4.get("success", false)):
				var r4: Node = shell.get("unit_renderer") as Node
				if r4 != null and r4.has_method("set_unit_dimmed"):
					r4.call("set_unit_dimmed", uid, true)
				if shell.has_method("_show_combat_log"):
					shell.call("_show_combat_log", "[%s] 대기 — OpenJev RED HOLD" % uid)
				_bridge.notify_mutation("openjev_live_red_hold")
			return res4
		"REST":
			if not bool(mgr.can_unit_rest(uid)):
				return {"success": false, "code": "REST_NOT_LEGAL", "error": "Rest gate refused."}
			var res5: Dictionary = mgr.rest_unit(uid)
			if bool(res5.get("success", false)):
				var r5: Node = shell.get("unit_renderer") as Node
				if r5 != null:
					if r5.has_method("set_unit_dimmed"):
						r5.call("set_unit_dimmed", uid, true)
					if r5.has_method("set_unit_resting"):
						r5.call("set_unit_resting", uid, true)
				if shell.has_method("_show_combat_log"):
					shell.call("_show_combat_log", "[%s] 휴식 — OpenJev RED REST" % uid)
				_bridge.notify_mutation("openjev_live_red_rest")
			return res5
		"FORTIFY":
			if not bool(mgr.can_unit_fortify(uid)):
				return {"success": false, "code": "FORTIFY_NOT_LEGAL", "error": "Fortify gate refused."}
			var res6: Dictionary = mgr.fortify_unit(uid)
			if bool(res6.get("success", false)):
				var r6: Node = shell.get("unit_renderer") as Node
				if r6 != null:
					if r6.has_method("set_unit_dimmed"):
						r6.call("set_unit_dimmed", uid, true)
					if r6.has_method("set_unit_fortified"):
						r6.call("set_unit_fortified", uid, true)
				if shell.has_method("_show_combat_log"):
					shell.call("_show_combat_log", "[%s] 요새화 — OpenJev RED FORTIFY" % uid)
				_bridge.notify_mutation("openjev_live_red_fortify")
			return res6
		"DISMANTLE":
			if not bool(mgr.can_dismantle_fortification(uid)):
				return {"success": false, "code": "DISMANTLE_NOT_LEGAL", "error": "Dismantle gate refused."}
			var res7: Dictionary = mgr.dismantle_fortification(uid)
			if bool(res7.get("success", false)):
				var r7: Node = shell.get("unit_renderer") as Node
				if r7 != null and r7.has_method("set_unit_fortified"):
					r7.call("set_unit_fortified", uid, false)
				if shell.has_method("_show_combat_log"):
					shell.call("_show_combat_log", "[%s] 요새화 해제 — OpenJev RED DISMANTLE" % uid)
				_bridge.notify_mutation("openjev_live_red_dismantle")
			return res7
		"ENTER_GARRISON":
			var res8: Dictionary = mgr.garrison_enter(uid, str(cand.get("stronghold_id", "")))
			if bool(res8.get("success", false)):
				var r8: Node = shell.get("unit_renderer") as Node
				if r8 != null and r8.has_method("remove_unit"):
					r8.call("remove_unit", uid)
				if shell.has_method("_show_combat_log"):
					shell.call("_show_combat_log", "[%s] 주둔 진입 — OpenJev RED GARRISON" % uid)
				_bridge.notify_mutation("openjev_live_red_garrison")
			return res8
	return {"success": false, "code": "UNKNOWN_ACTION", "error": "Unknown action type: " + t}


## Same visual + fog + Step6 finalization the live executor performs for
## RED attacks (authority already mutated above).
func _run_openjev_attack_presentation(uid: String, target: String, res: Dictionary) -> void:
	var shell := _bridge.get_shell() as Node
	var mgr: RefCounted = _bridge.get_manager()
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
		shell.call("_fog_mark_engaged", uid)
	shell.set("_fog_recent_combat", true)
	if shell.has_method("_fog_recalc"):
		shell.call("_fog_recalc", "enemy_attack")
	if shell.has_method("_s6_after_combat"):
		shell.call("_s6_after_combat", res, uid, target, atk_coord, def_coord)
	if shell.has_method("_show_combat_log"):
		shell.call("_show_combat_log", "[%s] 공격 -> [%s] 적 손실 -%d" % [uid, target, int(res.get("defender_casualties", 0))])
	shell.set("_is_animating_combat", false)


## Explicit HOLD-remaining (step cap / mid-loop error). Every HOLD runs the
## live authority; nothing is invented.
func _hold_remaining(unit_mission: Dictionary, start_index: int) -> Array:
	var views: Array = []
	var mgr: RefCounted = _bridge.get_manager()
	var svc: RefCounted = _bridge.get_service()
	var shell := _bridge.get_shell() as Node
	for u_val in mgr.get_all_units():
		var u: Dictionary = u_val
		if str(u.get("faction", "")) != "red":
			continue
		if int(u.get("soldier_count", 0)) <= 0:
			continue
		if bool(u.get("garrisoned", false)) or bool(u.get("routed", false)):
			continue
		if bool(u.get("is_convoy", false)) or str(u.get("class", "")) == "supply":
			continue
		if bool(u.get("action_ended", false)):
			continue
		if _shell_battle_over():
			break
		var uid := str(u.get("id", ""))
		var res: Dictionary = svc.execute_hold_intent(uid, "red")
		if str(res.get("code", "")) == "BATTLE_ALREADY_TERMINAL":
			break
		var ok := bool(res.get("success", false))
		if ok:
			var renderer: Node = shell.get("unit_renderer") as Node
			if renderer != null and renderer.has_method("set_unit_dimmed"):
				renderer.call("set_unit_dimmed", uid, true)
		views.append({
			"index": start_index + views.size(),
			"status": "HELD_FALLBACK" if ok else "FAILED",
			"order": {"candidate_id": "WAIT|%s" % uid, "unit_id": uid, "action_type": "WAIT"},
			"mission_id": "",
			"openjev_mission_id": str(unit_mission.get(uid, "")),
			"executed": [{"unit_id": uid, "action": "WAIT", "detail": res}] if ok else [],
			"failed": [] if ok else [{"unit_id": uid, "action": "WAIT",
				"code": str(res.get("error", "HOLD_FAILED"))}],
		})
	return views


func _finish_openjev(obs: Dictionary, packet: Dictionary, parsed: Dictionary,
	model_res: Dictionary, pre_fp: String, turn: int, attempt: int,
	auto_retries: int, order_views: Array, executed_count: int,
	failed_count: int, bypassed: int, end_turn_seen: bool,
	cap_hit: bool) -> Dictionary:
	var post_fp := str(_bridge.fingerprint())
	var status := "EXECUTED"
	if executed_count == 0:
		status = "FAILED" if failed_count > 0 else "EMPTY"
	elif failed_count > 0 or cap_hit:
		status = "PARTIAL"
	_plan.update_from_plan(parsed.get("plan", {}), turn)
	var result_note := "t%d: OpenJev %d decision(s), %d executed, %d failed, six-slot bypassed=%d (%s%s)" % [
		turn, _oj_decisions, executed_count, failed_count, bypassed, status,
		", END_TURN" if end_turn_seen else ""]
	print("[OpenJev] RED_EXECUTION done executed=%d failed=%d status=%s" % [executed_count, failed_count, status])
	_plan.note_result(result_note)
	_prev_summary = {"turn": turn, "status": status, "executed_count": executed_count,
		"failed_count": failed_count, "note": result_note}
	var record := {
		"timestamp": Time.get_datetime_string_from_system(),
		"battle_id": str(obs.get("battle_id", "")),
		"turn": turn, "attempt": attempt,
		"acting_side": "RED",
		"hands": "OPENJEV_LIVE",
		"snapshot_id": str(obs.get("snapshot_id", "")),
		"state_version": int((obs.get("parity", {}) as Dictionary).get("state_version", -1)),
		"observation_fingerprint": str((obs.get("parity", {}) as Dictionary).get("fingerprint", "")),
		"packet_version": str(packet.get("packet_version", "")),
		"provider": _config.provider_id,
		"model": _config.model,
		"latency_ms": int(model_res.get("latency_ms", 0)),
		"mock": bool(model_res.get("mock", false)),
		"auto_retries": auto_retries,
		"plan": parsed.get("plan", {}),
		"rationale": parsed.get("rationale", {}),
		"orders": order_views,
		"order_count": order_views.size(),
		"executed_count": executed_count,
		"failed_count": failed_count,
		"six_slot_bypassed": bypassed,
		"validation": {"ok": bool(parsed.get("ok", false)), "code": str(parsed.get("code", "")), "detail": str(parsed.get("detail", ""))},
		"executions": order_views,
		"pre_fingerprint": pre_fp,
		"post_fingerprint": post_fp,
		"status": status,
		"openjev": _openjev_telemetry(turn),
	}
	var logged := LoggerCls.log_turn(record)
	record["log_path"] = str(logged.get("path", ""))
	_last_view = {
		"model": _config.model, "provider": _config.provider_id,
		"hands": "OPENJEV_LIVE",
		"turn": turn, "attempt": attempt,
		"latency_ms": int(model_res.get("latency_ms", 0)),
		"mock": bool(model_res.get("mock", false)),
		"auto_retries": auto_retries,
		"snapshot_id": str(obs.get("snapshot_id", "")),
		"state_version": int((obs.get("parity", {}) as Dictionary).get("state_version", -1)),
		"plan": parsed.get("plan", {}),
		"rationale": parsed.get("rationale", {}),
		"orders": order_views,
		"order_count": order_views.size(),
		"executed_count": executed_count,
		"failed_count": failed_count,
		"six_slot_bypassed": bypassed,
		"pre_fingerprint": pre_fp,
		"post_fingerprint": post_fp,
		"status": status,
		"log_path": str(logged.get("path", "")),
		"summary": result_note,
		"openjev": _openjev_telemetry(turn),
	}
	_set_state("DONE", result_note)
	TraceCls.set_stage("COMPLETE", result_note)
	TraceCls.end_turn(status, result_note)
	return {
		"ok": true, "status": status, "turn": turn, "attempt": attempt,
		"hands": "OPENJEV_LIVE",
		"order_count": order_views.size(), "executed_count": executed_count,
		"failed_count": failed_count,
		"six_slot_bypassed": bypassed,
		"snapshot_id": str(obs.get("snapshot_id", "")),
		"pre_fingerprint": pre_fp, "post_fingerprint": post_fp,
		"log_path": str(logged.get("path", "")),
		"summary": result_note,
		"openjev": _openjev_telemetry(turn),
	}


func _openjev_telemetry(turn: int) -> Dictionary:
	return {
		"turn": turn, "decisions": _oj_decisions, "fallbacks": _oj_fallbacks,
		"fallback_active": _oj_fallback_active, "fallback_reason": _oj_fallback_reason,
		"stales": _oj_stales, "moves": _oj_moves, "attacks": _oj_attacks,
		"waits": _oj_waits, "other": _oj_other, "exec_failures": _oj_exec_failures,
		"latency_ms": _oj_lat_ms.duplicate(), "pool_sizes": _oj_pool_sizes.duplicate(),
		"last": _oj_last.duplicate(true),
	}


func _shell_battle_over() -> bool:
	var shell := _bridge.get_shell() as Node
	return shell != null and bool(shell.call("_battle_over"))


func _combat_log(text: String) -> void:
	var shell := _bridge.get_shell() as Node
	if shell != null and shell.has_method("_show_combat_log"):
		shell.call("_show_combat_log", text)


func _update_shell_turn_label(turn: int, step: int, winner: String, pool: int, ms: float) -> void:
	var shell := _bridge.get_shell() as Node
	if shell == null:
		return
	var lbl := shell.get("turn_label") as Label
	if lbl != null:
		lbl.text = "제 %d 턴 (적군) — OPENJEV #%d: %s [pool=%d, %.1fs]" % [turn, step, winner, pool, ms / 1000.0]


func _count_action(t: String) -> void:
	match t:
		"MOVE":
			_oj_moves += 1
		"ATTACK":
			_oj_attacks += 1
		"WAIT":
			_oj_waits += 1
		_:
			_oj_other += 1
