class_name LayaController
extends "res://scripts/cloud2/cloud2_turn_controller.gd"

## LAYA LIVE V0 — RED Hands controller (Laya per-unit sequential authority).
##
## Subclasses the production Cloud2TurnController and inherits the ENTIRE
## General layer untouched: provider/fallback General planning, mission
## hierarchy, event/periodic reviews, staged-plan adoption, plan memory,
## trace, and logging. The ONLY replaced step is tactical execution:
## _execute_orders runs the Laya per-unit loop instead of the deterministic
## six-slot solver's orders (which are still computed by red_turn for plan
## maintenance, then explicitly discarded and logged as bypassed).
##
## Loop (per RED phase), ONE unit at a time:
##   terminal? -> canonical NEXT unresolved RED unit (ascending id,
##   next-after-current with wrap) -> enumerate ALL legal actions for THAT
##   unit only -> 0: resolve per game semantics; 1: forced single action
##   (no model call); 2+: POST /decide -> fresh-revalidate -> execute via
##   live RED authorities + presentation -> terminal? -> SAME unit again
##   while unresolved, else advance the canonical queue.
## Laya chooses WHAT the current unit does; it NEVER chooses unit order and
## NEVER sees other units' actions. No END_TURN is ever offered (the human
## contract has no early end-turn); the phase ends when no unresolved RED
## field unit remains.
##
## Failures are EXPLICIT: any Laya error routes to the deterministic
## HOLD fallback with a "LAYA ERROR -> FALLBACK" flag (counted, logged,
## HUD-visible). Silent fallback never happens.

signal laya_decision(info: Dictionary)

## VictoryPlanCls is inherited from Cloud2TurnController (no re-preload).
const LYEnumCls = preload("res://scripts/laya/laya_enumerator.gd")
const LYLaunchCls = preload("res://scripts/laya/laya_launcher.gd")
const LYRulesCls = preload("res://scripts/laya/laya_rules.gd")
const LYHttpCls = preload("res://scripts/laya/laya_http.gd")
const LYCoordCls = preload("res://scripts/laya/laya_coordinator.gd")
const HexUtilsCls = preload("res://scripts/core/hex_utils.gd")
const ScopeAlgebraCls = preload("res://scripts/step7/step7_scope_algebra.gd")

const LY_MAX_STEPS := 150
const LY_MAX_CONSECUTIVE_STALE := 5
const LY_MAX_ZERO_ACTION_PER_UNIT := 3
const LY_DECIDE_BASE_TIMEOUT_MS := 30000
const LY_DECIDE_PER_CANDIDATE_MS := 1000
const LY_DECIDE_MAX_TIMEOUT_MS := 120000
const LY_READY_POLL_SEC := 0.5

var _ly_decisions := 0
var _ly_forced := 0
var _ly_fallbacks := 0
var _ly_stales := 0
var _ly_moves := 0
var _ly_attacks := 0
var _ly_waits := 0
var _ly_other := 0
var _ly_exec_failures := 0
var _ly_squeezed := 0
var _ly_state_truncated := 0
var _ly_lat_ms: Array = []
var _ly_pool_sizes: Array = []
var _ly_units_acted: Array = []
var _ly_last := {}
var _ly_log: Array = []
var _ly_fallback_active := false
var _ly_fallback_reason := ""
var _ly_turns := 0
## Liberation V1: per-mission-group blackboards (this RED phase only) +
## coordinator run trace + injectable POST seam (tests stub the worker).
var _ly_blackboards := {}
var _ly_coordinator_runs: Array = []
var _ly_post_override: Callable = Callable()


func red_controller_mode() -> String:
	return "LAYA"


## Laya failure policy: never block on a human decision; an explicit
## HOLD-ALL fallback resolves the phase (counted + flagged, never silent).
func _wait_for_decision() -> String:
	_ly_fallbacks += 1
	_ly_fallback_active = true
	_ly_fallback_reason = "auto_hold_on_failure"
	print("[Laya] _wait_for_decision auto-HOLD (explicit fallback #%d)" % _ly_fallbacks)
	return "hold"


func laya_stats() -> Dictionary:
	var lat_sorted: Array = _ly_lat_ms.duplicate()
	lat_sorted.sort()
	var pools_sorted: Array = _ly_pool_sizes.duplicate()
	pools_sorted.sort()
	return {
		"authority": "LAYA_LIVE",
		"side": _SIDE(),
		"red_turns": _ly_turns,
		"side_turns": _ly_turns,
		"decision_count": _ly_decisions,
		"forced_count": _ly_forced,
		"units_acted": _ly_units_acted.duplicate(),
		"fallback_count": _ly_fallbacks,
		"fallback_active": _ly_fallback_active,
		"fallback_reason": _ly_fallback_reason,
		"stale_count": _ly_stales,
		"moves": _ly_moves,
		"attacks": _ly_attacks,
		"waits": _ly_waits,
		"other": _ly_other,
		"exec_failures": _ly_exec_failures,
		"squeezed_decisions": _ly_squeezed,
		"state_truncated_decisions": _ly_state_truncated,
		"latency_ms": lat_sorted,
		"pool_sizes": pools_sorted,
		"last": _ly_last.duplicate(true),
		"service": LYLaunchCls.status_snapshot(),
		"coordinator_runs": _ly_coordinator_runs.duplicate(true),
		"tactics": laya_tactics_view(),
	}


## Liberation V1 DEV view: per-mission blackboard snapshots + coordinator
## runs. Read-only, bounded, safe to poll from the tactics panel.
func laya_tactics_view() -> Dictionary:
	var boards := {}
	for mid in _ly_blackboards.keys():
		var bb: LayaBlackboard = _ly_blackboards[mid]
		if bb != null:
			boards[str(mid)] = bb.snapshot()
	return {"blackboards": boards, "coordinator_runs": _ly_coordinator_runs.duplicate(true)}


func _ly_note_decision(info: Dictionary) -> void:
	_ly_last = info.duplicate(true)
	_ly_log.append(info.duplicate(true))
	if _ly_log.size() > 60:
		_ly_log.pop_front()
	laya_decision.emit(info.duplicate(true))


## Blocking bounded localhost POST (worker). Tests override via
## _ly_post_override(host, port, path, body, timeout_ms) -> {ok, body/error}.
func _ly_post(path: String, body: String, timeout_ms: int) -> Dictionary:
	if _ly_post_override.is_valid():
		return (_ly_post_override.call(LYLaunchCls.active_host(), LYLaunchCls.active_port(),
			path, body, timeout_ms) as Dictionary)
	return LYHttpCls.post_json(LYLaunchCls.active_host(), LYLaunchCls.active_port(),
		path, body, timeout_ms)


## THE override: Laya per-unit execution replaces six-slot orders.
func _execute_orders(obs: Dictionary, packet: Dictionary, parsed: Dictionary, model_res: Dictionary, pre_fp: String, turn: int, attempt: int, auto_retries: int = 0) -> Dictionary:
	var bypassed := int(parsed.get("order_count", 0))
	print("[Laya] %s_EXECUTION begin turn=%d six_slot_orders_bypassed=%d" % [_SIDE(), turn, bypassed])
	_set_state("EXECUTING", "Laya %s Hands deciding (turn %d; %d six-slot order(s) bypassed)." % [_SIDE(), turn, bypassed])
	TraceCls.set_stage("EXECUTING", "Laya %s Hands deciding (turn %d)." % [_SIDE(), turn])
	_ly_turns += 1
	_ly_fallback_active = false
	_ly_fallback_reason = ""

	var ready := await _await_laya_ready(turn)
	if not bool(ready.get("ok", false)):
		_ly_fallbacks += 1
		_ly_fallback_active = true
		_ly_fallback_reason = str(ready.get("error", "laya_unavailable"))
		_ly_note_decision({"event": "LAYA_ERROR_FALLBACK", "turn": turn,
			"reason": _ly_fallback_reason})
		_combat_log("LAYA ERROR -> DETERMINISTIC FALLBACK ACTIVE (%s)" % _ly_fallback_reason)
		var held := await _end_hold_all("laya:" + _ly_fallback_reason)
		_last_view["laya"] = _laya_telemetry(turn)
		held["laya"] = _laya_telemetry(turn)
		return held

	var en := LYEnumCls.new()
	en.set_side(_side)
	var cerr: String = en.configure(_bridge.get_manager(), _bridge.get_service(),
		_bridge.get_projector(), _bridge.get_shell().get("hex_grid"),
		_bridge.map_bounds(), Callable(_bridge.get_shell(), "_battle_over"),
		_bridge.get_shell().get("_river_cells"), _bridge.get_shell().get("_stronghold_cells"))
	if cerr != "":
		_ly_fallbacks += 1
		_ly_fallback_active = true
		_ly_fallback_reason = "enumerator_not_ready:" + cerr
		_ly_note_decision({"event": "LAYA_ERROR_FALLBACK", "turn": turn,
			"reason": _ly_fallback_reason})
		_combat_log("LAYA ERROR -> DETERMINISTIC FALLBACK ACTIVE (%s)" % _ly_fallback_reason)
		var held2 := await _end_hold_all("laya:" + _ly_fallback_reason)
		_last_view["laya"] = _laya_telemetry(turn)
		held2["laya"] = _laya_telemetry(turn)
		return held2

	var plan: Dictionary = _manager.get_plan() if _manager != null else {}
	if _manager != null and _manager.vp_has_plan():
		_manager.vp_note_laya_context(int(_manager.vp_get_plan().get("revision", 0)))
	var unit_mission := _unit_mission_map(plan)
	_ly_blackboards = _ly_build_blackboards(plan, unit_mission)
	for mid in _ly_blackboards.keys():
		_ly_coordinate_group(str(mid), obs, plan, turn, en)
	var order_views: Array = []
	var trace_views: Array = []
	TraceCls.set_orders(trace_views)
	var executed_count := 0
	var failed_count := 0
	var stale_streak := 0
	var cap_hit := false
	var end_turn_seen := false
	var steps := 0
	var after_id := ""
	var zero_action := {}
	while steps < LY_MAX_STEPS:
		if _shell_battle_over():
			break
		var cur: Dictionary = en.next_unresolved_unit(after_id)
		if cur.is_empty():
			end_turn_seen = true
			order_views.append({"index": order_views.size() + 1, "status": "END_TURN",
				"order": {"action": "END_TURN"}, "mission_id": "",
				"laya_mission_id": "", "executed": [], "failed": [],
				"candidate_count": 0})
			break
		var uid: String = str(cur.get("id", ""))
		if not _ly_units_acted.has(uid):
			_ly_units_acted.append(uid)
		await _pause_point("Before Laya unit %s (turn %d)." % [uid, turn])
		# Same-unit repeat: keep deciding for THIS unit while unresolved.
		var unit_done := false
		while not unit_done:
			if _shell_battle_over():
				break
			if bool(en.is_unit_id_resolved(uid)):
				break
			var pool: Dictionary = en.enumerate_for_unit(uid)
			if bool(pool.get("terminal", false)):
				break
			if bool(pool.get("resolved", true)):
				break
			var cands: Array = pool.get("candidates", [])
			if cands.is_empty():
				var zc := int(zero_action.get(uid, 0)) + 1
				zero_action[uid] = zc
				_ly_note_decision({"event": "LAYA_ZERO_ACTION_RESOLVE", "turn": turn,
					"unit_id": uid, "count": zc})
				print("[Laya] LAYA_ZERO_ACTION_RESOLVE %s (count %d)" % [uid, zc])
				_resolve_zero_action_unit(uid)
				if zc >= LY_MAX_ZERO_ACTION_PER_UNIT or bool(en.is_unit_id_resolved(uid)):
					unit_done = true
				continue
			steps += 1
			if steps > LY_MAX_STEPS:
				break
			_ly_pool_sizes.append(cands.size())
			if cands.size() == 1:
				var forced: Dictionary = cands[0]
				_ly_note_decision({"event": "FORCED_SINGLE_LEGAL_ACTION", "turn": turn,
					"step": steps, "unit_id": uid,
					"selected": str(forced.get("candidate_id", "")),
					"candidate_ids": [str(forced.get("candidate_id", ""))],
					"candidate_count": 1, "scores_available": false,
					"mission_id": str((unit_mission as Dictionary).get("mission_id", "")),
					"action_type": str(forced.get("action_type", ""))})
				print("[Laya] FORCED_SINGLE_LEGAL_ACTION %s" % str(forced.get("candidate_id", "")))
				var frev: Dictionary = en.revalidate(forced)
				if not bool(frev.get("ok", false)):
					failed_count += 1
					_ly_exec_failures += 1
					_ly_note_decision({"event": "FORCED_STALE", "turn": turn, "step": steps,
						"unit_id": uid, "code": str(frev.get("code", "?"))})
					print("[Laya] FORCED_STALE %s code=%s — explicit fallback" % [uid, str(frev.get("code", "?"))])
					break
				var fex: Dictionary = await _laya_execute(forced)
				if str(fex.get("code", "")) == "BATTLE_ALREADY_TERMINAL":
					break
				_ly_note_unit_action(uid, forced, fex, steps, unit_mission)
				_ly_forced += 1
				if bool(fex.get("success", false)):
					executed_count += 1
					_count_action(str(forced.get("action_type", "")))
				else:
					failed_count += 1
					_ly_exec_failures += 1
				_append_exec_view(order_views, trace_views, forced, unit_mission, fex,
					1, "", 0.0, 0.0, true)
				_combat_log("[Laya] %s (forced single)" % str(forced.get("candidate_id", "")))
				_update_shell_turn_label(turn, steps, uid, str(forced.get("candidate_id", "")), 1, 0.0, true)
				if _shell_battle_over():
					break
				await get_tree().process_frame
				continue
			# 2+ candidates: ask Laya.
			_set_state("EXECUTING", "Laya scoring %d legal action(s) for %s (turn %d, step %d)." % [cands.size(), uid, turn, steps])
			var req := _build_decide_request(obs, plan, unit_mission, uid, cands, turn,
				_ly_tactical_for(uid, unit_mission))
			var timeout_ms := mini(LY_DECIDE_MAX_TIMEOUT_MS,
				LY_DECIDE_BASE_TIMEOUT_MS + LY_DECIDE_PER_CANDIDATE_MS * cands.size())
			var t0 := Time.get_ticks_msec()
			var res := _ly_post("/decide", JSON.stringify(req), timeout_ms)
			var client_ms := float(Time.get_ticks_msec() - t0)
			if not bool(res.get("ok", false)):
				failed_count += 1
				_ly_exec_failures += 1
				_ly_note_decision({"event": "DECIDE_TRANSPORT_ERROR", "turn": turn, "step": steps,
					"unit_id": uid, "candidate_count": cands.size(), "error": str(res.get("error", "?"))})
				print("[Laya] DECIDE_TRANSPORT_ERROR %s — explicit fallback" % str(res.get("error", "?")))
				break
			var body: Variant = JSON.parse_string(str(res.get("body", "")))
			if not body is Dictionary or not bool((body as Dictionary).get("ok", false)):
				failed_count += 1
				_ly_exec_failures += 1
				var code := str((body as Dictionary).get("error", {}).get("code", "BAD_DECIDE_BODY")) if body is Dictionary else "BAD_DECIDE_BODY"
				_ly_note_decision({"event": "DECIDE_ERROR", "turn": turn, "step": steps,
					"unit_id": uid, "candidate_count": cands.size(), "error": code})
				print("[Laya] DECIDE_ERROR %s — explicit fallback" % code)
				break
			var scored: Dictionary = body
			var winner_id := str(scored.get("selected_candidate_id", ""))
			var winner := _find_candidate(cands, winner_id)
			_ly_decisions += 1
			_ly_lat_ms.append(client_ms)
			var serv_ms := float((scored.get("latency_ms", {}) as Dictionary).get("total", 0.0))
			var tok: Dictionary = scored.get("token_usage", {})
			if bool(tok.get("option_squeeze", false)):
				_ly_squeezed += 1
			if bool(tok.get("state_truncated", false)):
				_ly_state_truncated += 1
			if winner.is_empty():
				failed_count += 1
				_ly_exec_failures += 1
				_ly_note_decision({"event": "WINNER_NOT_IN_POOL", "turn": turn, "step": steps,
					"unit_id": uid, "selected": winner_id, "candidate_count": cands.size()})
				print("[Laya] WINNER_NOT_IN_POOL %s — explicit fallback" % winner_id)
				break
			# Fresh revalidation against CURRENT truth (read-only previews/gates).
			var rev: Dictionary = en.revalidate(winner)
			if not bool(rev.get("ok", false)):
				stale_streak += 1
				_ly_stales += 1
				_ly_note_decision({"event": "STALE_LAYA_SELECTION", "turn": turn, "step": steps,
					"unit_id": uid, "selected": winner_id, "code": str(rev.get("code", "?")),
					"streak": stale_streak})
				print("[Laya] STALE_LAYA_SELECTION %s code=%s (re-enumerate+rescore SAME unit)" % [winner_id, str(rev.get("code", "?"))])
				if stale_streak >= LY_MAX_CONSECUTIVE_STALE:
					print("[Laya] stale streak exhausted — explicit fallback")
					break
				continue
			stale_streak = 0
			var ex: Dictionary = await _laya_execute(winner)
			if str(ex.get("code", "")) == "BATTLE_ALREADY_TERMINAL":
				break
			_ly_note_unit_action(uid, winner, ex, steps, unit_mission)
			if bool(ex.get("success", false)):
				executed_count += 1
				_count_action(str(winner.get("action_type", "")))
			else:
				failed_count += 1
				_ly_exec_failures += 1
			_append_exec_view(order_views, trace_views, winner, unit_mission, ex,
				cands.size(), winner_id, client_ms, serv_ms, false)
			# SELFPLAY V1: trajectory enrichment (additive signal payload only;
			# no behavior change). Candidate ids + model ranking ride the
			# already-emitted DECISION event so recorders need no extra hooks.
			var _sp_cids: Array = []
			for _sp_c in cands:
				if _sp_c is Dictionary:
					_sp_cids.append(str((_sp_c as Dictionary).get("candidate_id", "?")))
			_ly_note_decision({"event": "DECISION", "turn": turn, "step": steps,
				"unit_id": uid, "selected": winner_id, "candidate_count": cands.size(),
				"candidate_ids": _sp_cids,
				"top5": (scored.get("top5", []) as Array).duplicate(true),
				"scores_available": true,
				"mission_id": str((unit_mission as Dictionary).get("mission_id", "")),
				"action_type": str(winner.get("action_type", "")),
				"exec_code": str(ex.get("code", "")),
				"latency_ms": client_ms, "server_ms": serv_ms,
				"confidence": scored.get("confidence"),
				"squeeze": bool(tok.get("option_squeeze", false)),
				"executed": bool(ex.get("success", false))})
			_combat_log("[Laya] %s (unit=%s pool=%d, %.0fms)" % [winner_id, uid, cands.size(), client_ms])
			_update_shell_turn_label(turn, steps, uid, winner_id, cands.size(), client_ms, false)
			if _shell_battle_over():
				break
			await get_tree().process_frame
		after_id = uid
		if _shell_battle_over():
			break
		if failed_count > 0:
			break
	if steps >= LY_MAX_STEPS and not _shell_battle_over():
		cap_hit = true
		print("[Laya] STEP_CAP %d hit — holding remaining units (explicit)" % LY_MAX_STEPS)
	if cap_hit or failed_count > 0:
		var held_rows: Array = await _hold_remaining(unit_mission, order_views.size() + 1)
		for hv in held_rows:
			order_views.append(hv)
			trace_views.append(hv)
		TraceCls.set_orders(trace_views)
		if failed_count > 0 or cap_hit:
			_ly_fallbacks += 1
			_ly_fallback_active = true
			_ly_fallback_reason = "step_cap_hold" if cap_hit else "mid_loop_error_hold"
			_combat_log("LAYA %s -> HOLD REMAINING (explicit)" % ("STEP CAP" if cap_hit else "ERROR"))
	return _finish_laya(obs, packet, parsed, model_res, pre_fp, turn, attempt,
		auto_retries, order_views, executed_count, failed_count, bypassed,
		end_turn_seen, cap_hit)


## Zero-action resolution per authoritative game semantics: the unit is
## unresolved yet offers nothing (should be unreachable — WAIT always
## exists for non-acted units — but must terminate, never spin). Prefer the
## manager's NEXT auto-resolve; fall back to an explicit HOLD.
func _resolve_zero_action_unit(uid: String) -> void:
	var mgr: RefCounted = _bridge.get_manager()
	if mgr.has_method("resolve_unit_via_next"):
		var res: Variant = mgr.call("resolve_unit_via_next", uid)
		if res is Dictionary and bool((res as Dictionary).get("resolved", false)):
			return
	var svc: RefCounted = _bridge.get_service()
	svc.execute_hold_intent(uid, _side)


## Wait for model READY (bounded). The battle may start while the worker
## loads; the RED phase honestly waits here with visible status.
func _await_laya_ready(turn: int) -> Dictionary:
	if LYLaunchCls.is_ready():
		return {"ok": true}
	if LYLaunchCls.is_disabled():
		return {"ok": false, "error": str(LYLaunchCls.status_snapshot().get("last_error", "DISABLED"))}
	if not LYLaunchCls.boot_in_progress():
		var sp := LYLaunchCls.spawn_owned_or_fixed()
		if not bool(sp.get("ok", false)):
			return {"ok": false, "error": str(sp.get("error", "SPAWN_FAILED"))}
		if str(sp.get("status", "")) == "READY":
			return {"ok": true}
	var deadline := Time.get_ticks_msec() + LYLaunchCls.startup_timeout_ms()
	var frames := 0
	while Time.get_ticks_msec() < deadline:
		if LYLaunchCls.is_ready():
			return {"ok": true}
		if LYLaunchCls.is_disabled():
			return {"ok": false, "error": str(LYLaunchCls.status_snapshot().get("last_error", "DISABLED"))}
		if not LYLaunchCls.boot_in_progress():
			return {"ok": false, "error": "BOOT_ABORTED"}
		if LYLaunchCls.fixed_url_mode():
			var ep: Dictionary = LYLaunchCls.fixed_endpoint()
			var res := LYHttpCls.get_json(str(ep.get("host", "127.0.0.1")),
				int(ep.get("port", 11442)), "/health", 4000)
			if bool(res.get("ok", false)):
				var h: Variant = JSON.parse_string(str(res.get("body", "")))
				if h is Dictionary:
					var v: Dictionary = LYLaunchCls.verify_health_dict(h)
					if bool(v.get("ok", false)):
						LYLaunchCls.adopt_fixed_health(v.get("identity", {}),
							(h as Dictionary).get("load", {}),
							str(ep.get("host", "")), int(ep.get("port", 11442)))
						return {"ok": true}
					LYLaunchCls.mark_disabled("FIXED_IDENTITY_MISMATCH: %s" % str(v.get("error", "?")))
					return {"ok": false, "error": "FIXED_IDENTITY_MISMATCH"}
		else:
			if not LYLaunchCls.owned_pid_alive():
				LYLaunchCls.mark_disabled("WORKER_DIED_DURING_BOOT")
				return {"ok": false, "error": "WORKER_DIED_DURING_BOOT"}
			var snap: Dictionary = LYLaunchCls.status_snapshot()
			var res2 := LYHttpCls.get_json(str(snap.get("host", "127.0.0.1")),
				int(snap.get("port", 11442)), "/health", 4000)
			if bool(res2.get("ok", false)):
				var h2: Variant = JSON.parse_string(str(res2.get("body", "")))
				if h2 is Dictionary:
					var v2: Dictionary = LYLaunchCls.verify_health_dict(h2)
					if bool(v2.get("ok", false)):
						LYLaunchCls.mark_ready(v2.get("identity", {}), (h2 as Dictionary).get("load", {}))
						return {"ok": true}
					LYLaunchCls.mark_disabled(str(v2.get("error", "HEALTH_MISMATCH")))
					return {"ok": false, "error": str(v2.get("error", "HEALTH_MISMATCH"))}
		frames += 1
		if frames % 2 == 0:
			_set_state("EXECUTING", "Laya loading model… (turn %d, %ds)" % [turn, frames / 2])
		await get_tree().create_timer(LY_READY_POLL_SEC).timeout
	LYLaunchCls.on_boot_timeout()
	return {"ok": false, "error": "STARTUP_TIMEOUT"}


## Liberation V1: one blackboard per mission group (this RED phase).
func _ly_build_blackboards(plan: Dictionary, _unit_mission: Dictionary) -> Dictionary:
	var out := {}
	for m_val in (plan.get("missions", []) as Array):
		if not m_val is Dictionary:
			continue
		var m: Dictionary = m_val
		var mid := str(m.get("mission_id", ""))
		if mid.is_empty() or out.has(mid):
			continue
		out[mid] = LayaBlackboard.create(m, m.get("assigned_units", []))
	return out


## Liberation V1: group coordination before units act. Generates feasible
## group plans from CURRENT legality, asks Laya to rank (one call), adopts
## the winner as ADVISORY context. Any failure degrades to uncoordinated
## per-unit decisions (explicitly flagged, never blocking).
func _ly_coordinate_group(mid: String, obs: Dictionary, plan: Dictionary, turn: int, en: RefCounted) -> Dictionary:
	var t0 := Time.get_ticks_msec()
	var bb: LayaBlackboard = _ly_blackboards.get(mid)
	if bb == null:
		return {"coordinated": false, "reason": "NO_BLACKBOARD"}
	var units: Array = (bb.group_units as Array).duplicate()
	if units.size() < 2:
		return {"coordinated": false, "reason": "SINGLE_UNIT"}
	var bounds: Dictionary = _bridge.map_bounds()
	var region_of := func(dest: Array) -> String:
		return str(ScopeAlgebraCls.get_region_for_coord(int(dest[0]), int(dest[1]), bounds))
	var pools := {}
	for uid in units:
		var pool: Dictionary = (en as RefCounted).call("enumerate_for_unit", str(uid))
		pools[str(uid)] = pool.get("candidates", [])
	var cands: Array = LYCoordCls.generate(mid, units, pools, region_of)
	if cands.is_empty():
		_ly_note_coordinator(mid, turn, 0, "", false, "NO_CANDIDATES", t0)
		return {"coordinated": false, "reason": "NO_CANDIDATES"}
	if cands.size() == 1:
		_ly_adopt_group_plan(bb, cands[0], cands, true, "")
		_ly_note_coordinator(mid, turn, 1, str((cands[0] as Dictionary).get("candidate_id", "")), true, "", t0)
		return {"coordinated": true, "forced": true, "candidates": 1}
	var req := _ly_build_group_request(obs, plan, mid, units, turn, bb, cands)
	var timeout_ms := mini(LY_DECIDE_MAX_TIMEOUT_MS,
		LY_DECIDE_BASE_TIMEOUT_MS + LY_DECIDE_PER_CANDIDATE_MS * cands.size())
	var res := _ly_post("/decide_group", JSON.stringify(req), timeout_ms)
	if not bool(res.get("ok", false)):
		_ly_note_coordinator(mid, turn, cands.size(), "", false,
			"TRANSPORT: %s" % str(res.get("error", "?")), t0)
		return {"coordinated": false, "reason": "TRANSPORT"}
	var doc: Variant = JSON.parse_string(str(res.get("body", "")))
	if not doc is Dictionary or not bool((doc as Dictionary).get("ok", false)):
		_ly_note_coordinator(mid, turn, cands.size(), "", false, "WORKER_REJECT", t0)
		return {"coordinated": false, "reason": "WORKER_REJECT"}
	var sel := str((doc as Dictionary).get("selected_candidate_id", ""))
	var winner := _find_candidate(cands, sel)
	if winner.is_empty():
		winner = cands[0] # unknown selection: deterministic fallback, flagged.
		_ly_adopt_group_plan(bb, winner, cands, true, "SELECTION_FALLBACK")
		_ly_note_coordinator(mid, turn, cands.size(), str(winner.get("candidate_id", "")), true,
			"SELECTION_FALLBACK", t0)
		return {"coordinated": true, "forced": true, "fallback": true}
	_ly_adopt_group_plan(bb, winner, cands, false, "")
	_ly_note_coordinator(mid, turn, cands.size(), sel, false, "", t0)
	return {"coordinated": true, "candidates": cands.size(), "selected": sel}


func _ly_adopt_group_plan(bb: LayaBlackboard, winner: Dictionary, _cands: Array, forced: bool, flag: String) -> void:
	var assigns: Dictionary = (winner.get("assignments", {}) as Dictionary).duplicate(true)
	bb.set_group_plan({"candidate_id": str(winner.get("candidate_id", "")),
		"text": str(winner.get("option_text", "")), "assignments": assigns,
		"forced": forced, "flag": flag})
	var focus: Array = []
	for uid in assigns.keys():
		var a: Dictionary = assigns[uid]
		if str(a.get("kind", "")) in ["ATTACK", "ASSAULT"] and not str(a.get("target", "")).is_empty():
			if not str(a.get("target", "")) in focus:
				focus.append(str(a.get("target", "")))
	if not focus.is_empty():
		bb.note_focus(focus)
	bb.note_risks(_ly_group_risks(bb))
	_ly_note_decision({"event": "COORDINATOR_PLAN", "mission_id": bb.mission_id,
		"candidate_id": str(winner.get("candidate_id", "")), "forced": forced,
		"flag": flag, "text": str(winner.get("option_text", "")).left(220)})


## Factual nearby-enemy rows for the blackboard: id/class/distance/band.
## No judgment words; the model infers threat from facts.
func _ly_group_risks(bb: LayaBlackboard) -> Array:
	var rows: Array = []
	var mgr: RefCounted = _bridge.get_manager()
	var knowledge: Dictionary = _bridge.build_knowledge(_side)
	var foes: Array = ((knowledge.get("ledger", {}) as Dictionary).get(_ly_foe_ledger_key(), []) as Array)
	if foes.is_empty():
		return rows
	for uid in (bb.group_units as Array):
		var u: Dictionary = (mgr as RefCounted).call("get_unit_by_id", str(uid))
		if u.is_empty():
			continue
		var org := Vector2i(int(u.get("q", 0)), int(u.get("r", 0)))
		var scored: Array = []
		for f_val in foes:
			if not f_val is Dictionary:
				continue
			var f: Dictionary = f_val
			var d := HexUtilsCls.hex_distance_axial(org, Vector2i(int(f.get("q", 0)), int(f.get("r", 0))))
			scored.append({"d": d, "f": f})
		scored.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			if int(a.get("d", 0)) != int(b.get("d", 0)):
				return int(a.get("d", 0)) < int(b.get("d", 0))
			return str((a.get("f", {}) as Dictionary).get("id", "")) < str((b.get("f", {}) as Dictionary).get("id", "")))
		for s in scored.slice(0, 2):
			var f: Dictionary = s["f"]
			rows.append("%s %s %dhex of %s [%s]" % [str(f.get("id", "?")),
				str(f.get("class", "?")), int(s["d"]), str(uid),
				str(f.get("troop_text", f.get("troop_estimate", "?")))])
		if rows.size() >= 6:
			break
	return rows.slice(0, 6)


func _ly_build_group_request(obs: Dictionary, plan: Dictionary, mid: String,
	units: Array, turn: int, bb: LayaBlackboard, cands: Array) -> Dictionary:
	var mymission := _mission_of(plan, _ly_invert_for(mid, units), str(units[0]))
	var mgr: RefCounted = _bridge.get_manager()
	var gunits: Array = []
	for uid in units:
		gunits.append((mgr as RefCounted).call("get_unit_by_id", str(uid)))
	var knowledge: Dictionary = _bridge.build_knowledge(_side)
	var foes: Array = []
	for f_val in ((knowledge.get("ledger", {}) as Dictionary).get(_ly_foe_ledger_key(), []) as Array):
		if f_val is Dictionary:
			var f: Dictionary = f_val
			foes.append({"id": str(f.get("id", "")), "class": str(f.get("class", "")),
				"q": int(f.get("q", 0)), "r": int(f.get("r", 0)),
				"troop_text": str(f.get("troop_text", f.get("troop_estimate", "?")))})
		if foes.size() >= 8:
			break
	var slim: Array = []
	for c_val in cands:
		var c: Dictionary = c_val
		slim.append({"candidate_id": str(c.get("candidate_id", "")),
			"option_text": str(c.get("option_text", ""))})
	return {
		"schema_version": LYLaunchCls.GROUP_REQUEST_VERSION,
		"battle_id": str(obs.get("battle_id", "")),
		"turn": turn,
		"side": _side,
		"mission_id": mid,
		"mission": {
			"mission_id": mid,
			"task": str(mymission.get("task", "")),
			"intent": str(mymission.get("intent", "")),
			"coordination_intent": str(mymission.get("coordination_intent", "")),
			"priority": str(mymission.get("priority", "")),
			"force_roles": (mymission.get("force_roles", {}) as Dictionary).duplicate(true),
			"constraints_nl": (mymission.get("constraints_nl", []) as Array).duplicate(true),
			"target_preferences": (mymission.get("target_preferences", {}) as Dictionary).duplicate(true),
		},
		"group_units": gunits,
		"blackboard": str((bb.serialize_for_laya() as Dictionary).get("text", "")),
		"known_foes": foes,
		"recent_events": ((obs.get("recent_events", []) as Array).duplicate(true)).slice(-4),
		"candidates": slim,
	}


## Tiny adapter: _mission_of wants a unit->mission map; build one for the group.
func _ly_invert_for(mid: String, units: Array) -> Dictionary:
	var out := {}
	for uid in units:
		out[str(uid)] = mid
	return out


## Liberation V1: tactical block for one unit's decide request (its
## mission group's serialized blackboard + adopted group plan, or {}).
func _ly_tactical_for(uid: String, unit_mission: Dictionary) -> Dictionary:
	var mid := str(unit_mission.get(uid, ""))
	if mid.is_empty() or not _ly_blackboards.has(mid):
		return {}
	var bb: LayaBlackboard = _ly_blackboards[mid]
	var ser := bb.serialize_for_laya()
	return {"mission_id": mid, "text": str(ser.get("text", "")),
		"group_plan": (bb.group_plan as Dictionary).duplicate(true)}


## Liberation V1: record one executed action on its mission blackboard,
## then invalidate stale commitments from FRESH live state.
func _ly_note_unit_action(uid: String, cand: Dictionary, ex: Dictionary, step: int,
	unit_mission: Dictionary) -> void:
	var mid := str(unit_mission.get(uid, ""))
	if mid.is_empty() or not _ly_blackboards.has(mid):
		return
	var bb: LayaBlackboard = _ly_blackboards[mid]
	bb.note_commitment(uid, cand, _ly_commit_effect(uid, cand), step)
	if bool(ex.get("success", false)):
		bb.note_execution_done(uid, _ly_commit_effect(uid, cand))
	else:
		bb.note_execution_failed(uid, str(ex.get("code", ex.get("error", "?"))))
	var mgr: RefCounted = _bridge.get_manager()
	var red_alive: Array = []
	var blue_alive: Array = []
	for u_val in ((mgr as RefCounted).call("get_all_units") as Array):
		if not u_val is Dictionary:
			continue
		var u: Dictionary = u_val
		if str(u.get("faction", "")) == "red":
			red_alive.append(str(u.get("id", "")))
		elif str(u.get("faction", "")) == "blue":
			blue_alive.append(str(u.get("id", "")))
	bb.invalidate_stale(red_alive, blue_alive, _side)


## Factual one-line effect of an executed candidate (no judgment).
func _ly_commit_effect(uid: String, cand: Dictionary) -> String:
	var t := str(cand.get("action_type", ""))
	if t == "ATTACK":
		return "%s attacks %s" % [uid, str(cand.get("target_id", "?"))]
	if t == "MOVE":
		var d: Array = cand.get("destination", [])
		if d.size() == 2:
			return "%s moves to %d,%d" % [uid, int(d[0]), int(d[1])]
		return "%s moves" % uid
	if t == "ASSAULT":
		return "%s assaults %s" % [uid, str(cand.get("stronghold_id", "?"))]
	if t == "WAIT":
		return "%s holds" % uid
	if t == "REST":
		return "%s rests" % uid
	if t == "FORTIFY":
		return "%s fortifies" % uid
	return "%s %s" % [uid, t]


func _ly_note_coordinator(mid: String, turn: int, count: int, selected: String,
	forced: bool, error: String, t0: int) -> void:
	var row := {"mission_id": mid, "turn": turn, "candidates": count,
		"selected": selected, "forced": forced, "error": error,
		"ms": Time.get_ticks_msec() - t0}
	_ly_coordinator_runs.append(row)
	_ly_note_decision({"event": "COORDINATOR_RUN", "mission_id": mid, "turn": turn,
		"candidates": count, "selected": selected, "forced": forced, "error": error})


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


func _mission_of(plan: Dictionary, unit_mission: Dictionary, uid: String) -> Dictionary:
	var mid := str(unit_mission.get(uid, ""))
	if mid.is_empty():
		return {}
	for m_val in (plan.get("missions", []) as Array):
		if m_val is Dictionary and str((m_val as Dictionary).get("mission_id", "")) == mid:
			return m_val
	return {}


## SYMMETRIC V1: side-local projector ledger keys. RED and BLUE ledgers
## use mirrored key names (projector.build_red/blue_knowledge).
func _ly_foe_ledger_key() -> String:
	return "current_enemy_observations" if _side == "blue" else "observed_blue_forces"


func _ly_foe_stale_ledger_key() -> String:
	return "last_known_enemy_contacts" if _side == "blue" else "last_known_blue_contacts"


## Mission-target coordinate from SIDE-AUTHORIZED positions only (own units:
## exact; foe units: observed/last-known ledger; REGION/other: none).
## Returns [] when the target has no single authorized coordinate.
func _mission_target_coord(mission: Dictionary, ledger: Dictionary) -> Array:
	var obj: Dictionary = mission.get("objective", {})
	if obj.is_empty():
		return []
	if str(obj.get("kind", "")) != "UNIT":
		return []
	var tid := str(obj.get("unit_id", ""))
	if tid.is_empty():
		return []
	var mgr: RefCounted = _bridge.get_manager()
	var tu: Dictionary = mgr.get_unit_by_id(tid)
	if not tu.is_empty() and str(tu.get("faction", "")) == _side:
		return [int(tu.get("q", 0)), int(tu.get("r", 0))]
	for e_val in (ledger.get(_ly_foe_ledger_key(), []) as Array):
		var e: Dictionary = e_val
		if str(e.get("id", "")) == tid:
			return [int(e.get("q", 0)), int(e.get("r", 0))]
	for s_val in (ledger.get(_ly_foe_stale_ledger_key(), []) as Array):
		var s: Dictionary = s_val
		if str(s.get("id", "")) == tid:
			return [int(s.get("q", 0)), int(s.get("r", 0))]
	return []


## Foe troop estimate from the side ledger (banded text, never truth).
func _ledger_troop_text(ledger: Dictionary, tid: String) -> String:
	for e_val in (ledger.get(_ly_foe_ledger_key(), []) as Array):
		var e: Dictionary = e_val
		if str(e.get("id", "")) == tid:
			return str(e.get("troop_text", e.get("troop_estimate", "?")))
	return "?"


func _find_candidate(cands: Array, cid: String) -> Dictionary:
	for c_val in cands:
		if str((c_val as Dictionary).get("candidate_id", "")) == cid:
			return c_val
	return {}


## VICTORY PLAN V0 (additive): compact active-phase context for this
## unit's decision. {} when no VictoryPlan is bound (legacy path).
func _victory_context_for_unit(mymission: Dictionary) -> Dictionary:
	if _manager == null or not _manager.vp_has_plan():
		return {}
	return VictoryPlanCls.victory_context_for_laya(_manager.vp_get_plan(), mymission)


## Compact versioned local contract: ONE unit + its full legal set +
## authorized state + commander context + runtime rules. No hidden foe
## truth: knowledge comes from the side projector ledger, events from the
## side observation, target coords from authorized positions.
func _build_decide_request(obs: Dictionary, plan: Dictionary,
	unit_mission: Dictionary, uid: String, cands: Array, turn: int,
	tactical: Dictionary = {}) -> Dictionary:
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
			"intent": str(m.get("intent", "")),
			"coordination_intent": str(m.get("coordination_intent", "")),
		})
	var concept: Dictionary = (plan.get("concept", {}) as Dictionary).duplicate(true)
	var doctrine: Dictionary = (plan.get("doctrine", {}) as Dictionary).duplicate(true)
	var knowledge: Dictionary = _bridge.build_knowledge(_side)
	var ledger: Dictionary = (knowledge.get("ledger", {}) as Dictionary).duplicate(true)
	var events: Array = ((obs.get("recent_events", []) as Array).duplicate(true)).slice(-5)
	var unit: Dictionary = (_bridge.get_manager() as RefCounted).call("get_unit_by_id", uid)
	var mymission: Dictionary = _mission_of(plan, unit_mission, uid)
	var tcoord: Array = _mission_target_coord(mymission, ledger)
	var opts: Array = []
	var troop_of := func(tid: String) -> String: return _ledger_troop_text(ledger, tid)
	var uclass := str(unit.get("class", ""))
	for c_val in cands:
		var c: Dictionary = (c_val as Dictionary).duplicate(true)
		# Liberation V1 matchup fact: class-vs-class table multiplier only
		# (no hidden morale/troops). Same deterministic table combat uses.
		if str(c.get("action_type", "")) == "ATTACK":
			c["matchup_mult"] = CombatCalculator.get_matchup_mult(uclass, str(c.get("target_class", "")))
		c["option_text"] = format_option_text(c, unit, tcoord, troop_of)
		opts.append(c)
	var req := {
		"schema_version": LYLaunchCls.REQUEST_VERSION,
		"battle_id": str(obs.get("battle_id", "")),
		"turn": turn,
		"side": _side,
		"unit_id": uid,
		"authorized_state": {
			"unit": unit,
			"unit_mission": mymission,
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
			"victory": _victory_context_for_unit(mymission),
		},
		"runtime_rules": LYRulesCls.runtime_rules(),
		"candidates": opts,
	}
	if not tactical.is_empty():
		req["tactical"] = tactical
	return req


## Compact factual option text (lossless compaction: same facts, fewer
## tokens). Identity first so SDK head-budget squeeze keeps the most
## distinguishing facts. NO tactical judgments — raw properties only.
## Static + pure (troop lookup injected) so sim probes build byte-identical
## option text through this single source of truth.
static func format_option_text(c: Dictionary, unit: Dictionary, tcoord: Array, troop_of: Callable) -> String:
	var t: String = str(c.get("action_type", ""))
	match t:
		"MOVE":
			var d: Array = c.get("destination", [0, 0])
			var dest := Vector2i(int(d[0]), int(d[1]))
			var org := Vector2i(int(unit.get("q", 0)), int(unit.get("r", 0)))
			var seg := "M %d,%d %s" % [dest.x, dest.y, str(c.get("direction", "?"))]
			if tcoord.size() == 2:
				var tc := Vector2i(int(tcoord[0]), int(tcoord[1]))
				var db := HexUtilsCls.hex_distance_axial(org, tc)
				var da := HexUtilsCls.hex_distance_axial(dest, tc)
				seg += " %d>%d" % [db, da]
			seg += " %s" % str(c.get("terrain", "?"))
			return seg
		"ATTACK":
			var tid := str(c.get("target_id", ""))
			var troops := str(troop_of.call(tid)) if troop_of.is_valid() else "?"
			var seg_atk := "ATK %s %s %d,%d %s" % [tid, str(c.get("target_class", "?")),
				int(c.get("target_q", 0)), int(c.get("target_r", 0)), troops]
			if c.has("matchup_mult"):
				seg_atk += " x%.2f" % float(c.get("matchup_mult", 1.0))
			return seg_atk
		"ASSAULT":
			var gid := str(c.get("garrison_target_id", ""))
			if gid.is_empty():
				return "ASLT %s" % str(c.get("stronghold_id", "?"))
			return "ASLT %s %s" % [str(c.get("stronghold_id", "?")), gid]
		"WAIT":
			return "WAIT hold"
		"REST":
			return "REST recover"
		"FORTIFY":
			return "FORT build"
		"DISMANTLE":
			return "DISM rm"
		"ENTER_GARRISON":
			return "GAR %s" % str(c.get("stronghold_id", "?"))
	return t + " " + str(c.get("candidate_id", "?"))


func _append_exec_view(order_views: Array, trace_views: Array, winner: Dictionary,
	unit_mission: Dictionary, ex: Dictionary, cand_count: int,
	selected_id: String, client_ms: float, serv_ms: float, forced: bool) -> void:
	var view := {
		"index": order_views.size() + 1,
		"status": "EXECUTED" if bool(ex.get("success", false)) else "FAILED",
		"order": winner.duplicate(true),
		"mission_id": "",
		"laya_mission_id": str(unit_mission.get(str(winner.get("unit_id", "")), "")),
		"executed": [{"unit_id": str(winner.get("unit_id", "")),
			"action": str(winner.get("action_type", "")),
			"detail": ex}] if bool(ex.get("success", false)) else [],
		"failed": [] if bool(ex.get("success", false)) else [{"unit_id": str(winner.get("unit_id", "")),
			"action": str(winner.get("action_type", "")),
			"code": str(ex.get("code", "EXEC_FAILED")),
			"detail": str(ex.get("error", ""))}],
		"candidate_count": cand_count,
		"selected": selected_id,
		"forced": forced,
		"latency_ms": client_ms,
		"server_ms": serv_ms,
	}
	order_views.append(view)
	trace_views.append(view)
	TraceCls.set_orders(trace_views)


## SYMMETRIC V1: side-aware mutation + fog-reason labels.
func _ly_mut(reason: String) -> String:
	return "laya_live_%s_%s" % [_side, reason]


func _ly_fog_reason(enemy_reason: String) -> String:
	if _side == "blue":
		return "player_" + enemy_reason.trim_prefix("enemy_")
	return enemy_reason


## Execute ONE revalidated candidate through the live side authorities
## (the exact branches the live executor's side path uses), plus the same
## renderer/fog/Step6 presentation. Returns the authority result dict.
func _laya_execute(cand: Dictionary) -> Dictionary:
	var t: String = str(cand.get("action_type", ""))
	var uid: String = str(cand.get("unit_id", ""))
	var shell := _bridge.get_shell() as Node
	var mgr: RefCounted = _bridge.get_manager()
	var svc: RefCounted = _bridge.get_service()
	match t:
		"MOVE":
			var d: Array = cand.get("destination", [0, 0])
			var res: Dictionary = svc.execute_move_intent(uid, Vector2i(int(d[0]), int(d[1])), _side, "green")
			if str(res.get("code", "")) == "BATTLE_ALREADY_TERMINAL":
				return {"success": false, "code": "BATTLE_ALREADY_TERMINAL"}
			if bool(res.get("success", false)):
				var renderer: Node = shell.get("unit_renderer") as Node
				if renderer != null and renderer.has_method("update_unit_position"):
					renderer.call("update_unit_position", uid, int(d[0]), int(d[1]))
				if shell.has_method("_fog_recalc"):
					shell.call("_fog_recalc", _ly_fog_reason("enemy_move"))
				if shell.has_method("_show_combat_log"):
					shell.call("_show_combat_log", "[%s] 이동 — Laya %s MOVE" % [uid, _SIDE()])
				_bridge.notify_mutation(_ly_mut("move"))
			return res
		"ATTACK":
			var target := str(cand.get("target_id", ""))
			var s6: RefCounted = _bridge.get_step6()
			var mods: Dictionary = s6.attacker_bonus_vs(mgr, uid, target) if s6 != null else {}
			var res2: Dictionary = svc.execute_attack_intent(uid, target, _side, mods)
			if str(res2.get("code", "")) == "BATTLE_ALREADY_TERMINAL":
				return {"success": false, "code": "BATTLE_ALREADY_TERMINAL"}
			if bool(res2.get("success", false)):
				await _run_laya_attack_presentation(uid, target, res2)
				_bridge.notify_mutation(_ly_mut("attack"))
			return res2
		"ASSAULT":
			var res3: Dictionary = mgr.execute_stronghold_assault(uid,
				str(cand.get("stronghold_id", "")), str(cand.get("garrison_target_id", "")), {})
			if str(res3.get("code", "")) == "BATTLE_ALREADY_TERMINAL":
				return {"success": false, "code": "BATTLE_ALREADY_TERMINAL"}
			if bool(res3.get("success", false)):
				if shell.has_method("_fog_recalc"):
					shell.call("_fog_recalc", _ly_fog_reason("enemy_attack"))
				if shell.has_method("_show_combat_log"):
					shell.call("_show_combat_log", "[%s] 강습 -> [%s] — Laya %s ASSAULT" % [uid, str(cand.get("stronghold_id", "")), _SIDE()])
				_bridge.notify_mutation(_ly_mut("assault"))
			return res3
		"WAIT":
			var res4: Dictionary = svc.execute_hold_intent(uid, _side)
			if str(res4.get("code", "")) == "BATTLE_ALREADY_TERMINAL":
				return {"success": false, "code": "BATTLE_ALREADY_TERMINAL"}
			if bool(res4.get("success", false)):
				var r4: Node = shell.get("unit_renderer") as Node
				if r4 != null and r4.has_method("set_unit_dimmed"):
					r4.call("set_unit_dimmed", uid, true)
				if shell.has_method("_show_combat_log"):
					shell.call("_show_combat_log", "[%s] 대기 — Laya %s HOLD" % [uid, _SIDE()])
				_bridge.notify_mutation(_ly_mut("hold"))
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
					shell.call("_show_combat_log", "[%s] 휴식 — Laya %s REST" % [uid, _SIDE()])
				_bridge.notify_mutation(_ly_mut("rest"))
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
					shell.call("_show_combat_log", "[%s] 요새화 — Laya %s FORTIFY" % [uid, _SIDE()])
				_bridge.notify_mutation(_ly_mut("fortify"))
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
					shell.call("_show_combat_log", "[%s] 요새화 해제 — Laya %s DISMANTLE" % [uid, _SIDE()])
				_bridge.notify_mutation(_ly_mut("dismantle"))
			return res7
		"ENTER_GARRISON":
			var res8: Dictionary = mgr.garrison_enter(uid, str(cand.get("stronghold_id", "")))
			if bool(res8.get("success", false)):
				var r8: Node = shell.get("unit_renderer") as Node
				if r8 != null and r8.has_method("remove_unit"):
					r8.call("remove_unit", uid)
				if shell.has_method("_show_combat_log"):
					shell.call("_show_combat_log", "[%s] 주둔 진입 — Laya %s GARRISON" % [uid, _SIDE()])
				_bridge.notify_mutation(_ly_mut("garrison"))
			return res8
	return {"success": false, "code": "UNKNOWN_ACTION", "error": "Unknown action type: " + t}


## Same visual + fog + Step6 finalization the live executor performs for
## RED attacks (authority already mutated above).
func _run_laya_attack_presentation(uid: String, target: String, res: Dictionary) -> void:
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
	if shell.has_method("_fog_mark_engaged") and _side == "red":
		shell.call("_fog_mark_engaged", uid)
	shell.set("_fog_recent_combat", true)
	if shell.has_method("_fog_recalc"):
		shell.call("_fog_recalc", _ly_fog_reason("enemy_attack"))
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
		if str(u.get("faction", "")) != _side:
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
		var res: Dictionary = svc.execute_hold_intent(uid, _side)
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
			"laya_mission_id": str(unit_mission.get(uid, "")),
			"executed": [{"unit_id": uid, "action": "WAIT", "detail": res}] if ok else [],
			"failed": [] if ok else [{"unit_id": uid, "action": "WAIT",
				"code": str(res.get("error", "HOLD_FAILED"))}],
		})
	return views


func _finish_laya(obs: Dictionary, packet: Dictionary, parsed: Dictionary,
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
	var result_note := "t%d: Laya %d decision(s), %d forced, %d executed, %d failed, six-slot bypassed=%d (%s%s)" % [
		turn, _ly_decisions, _ly_forced, executed_count, failed_count, bypassed, status,
		", END_TURN" if end_turn_seen else ""]
	print("[Laya] %s_EXECUTION done executed=%d failed=%d status=%s" % [_SIDE(), executed_count, failed_count, status])
	_plan.note_result(result_note)
	_prev_summary = {"turn": turn, "status": status, "executed_count": executed_count,
		"failed_count": failed_count, "note": result_note}
	var record := {
		"timestamp": Time.get_datetime_string_from_system(),
		"battle_id": str(obs.get("battle_id", "")),
		"turn": turn, "attempt": attempt,
		"acting_side": _SIDE(),
		"hands": "LAYA_LIVE",
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
		"laya": _laya_telemetry(turn),
	}
	var logged := LoggerCls.log_turn(record)
	record["log_path"] = str(logged.get("path", ""))
	_last_view = {
		"model": _config.model, "provider": _config.provider_id,
		"hands": "LAYA_LIVE",
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
		"laya": _laya_telemetry(turn),
	}
	_set_state("DONE", result_note)
	TraceCls.set_stage("COMPLETE", result_note)
	TraceCls.end_turn(status, result_note)
	return {
		"ok": true, "status": status, "turn": turn, "attempt": attempt,
		"hands": "LAYA_LIVE",
		"order_count": order_views.size(), "executed_count": executed_count,
		"failed_count": failed_count,
		"six_slot_bypassed": bypassed,
		"snapshot_id": str(obs.get("snapshot_id", "")),
		"pre_fingerprint": pre_fp, "post_fingerprint": post_fp,
		"log_path": str(logged.get("path", "")),
		"summary": result_note,
		"laya": _laya_telemetry(turn),
	}


func _laya_telemetry(turn: int) -> Dictionary:
	return {
		"turn": turn, "decisions": _ly_decisions, "forced": _ly_forced,
		"units_acted": _ly_units_acted.duplicate(),
		"fallbacks": _ly_fallbacks,
		"fallback_active": _ly_fallback_active, "fallback_reason": _ly_fallback_reason,
		"stales": _ly_stales, "moves": _ly_moves, "attacks": _ly_attacks,
		"waits": _ly_waits, "other": _ly_other, "exec_failures": _ly_exec_failures,
		"squeezed": _ly_squeezed, "state_truncated": _ly_state_truncated,
		"latency_ms": _ly_lat_ms.duplicate(), "pool_sizes": _ly_pool_sizes.duplicate(),
		"last": _ly_last.duplicate(true),
	}


func _shell_battle_over() -> bool:
	var shell := _bridge.get_shell() as Node
	return shell != null and bool(shell.call("_battle_over"))


func _combat_log(text: String) -> void:
	var shell := _bridge.get_shell() as Node
	if shell != null and shell.has_method("_show_combat_log"):
		shell.call("_show_combat_log", text)


func _update_shell_turn_label(turn: int, step: int, uid: String, winner: String, pool: int, ms: float, forced: bool) -> void:
	var shell := _bridge.get_shell() as Node
	if shell == null:
		return
	var lbl := shell.get("turn_label") as Label
	if lbl != null:
		var sidetag := "(적군)" if _side == "red" else "(아군)"
		if forced:
			lbl.text = "제 %d 턴 %s — LAYA %s: %s [forced]" % [turn, sidetag, uid, winner]
		else:
			lbl.text = "제 %d 턴 %s — LAYA %s #%d: %s [pool=%d, %.0fms]" % [turn, sidetag, uid, step, winner, pool, ms]


func _count_action(t: String) -> void:
	match t:
		"MOVE":
			_ly_moves += 1
		"ATTACK":
			_ly_attacks += 1
		"WAIT":
			_ly_waits += 1
		_:
			_ly_other += 1
