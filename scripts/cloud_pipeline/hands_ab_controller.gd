extends "res://scripts/laya/laya_controller.gd"

## CLOUD FULL PIPELINE V0 — RED Hands = frozen Hand A + frozen Hand B.
##
## Inherits the whole General layer (Cloud2TurnController: VictoryPlan,
## unalloc_v1 missions, reviews, staging, memory) and the Laya per-unit
## execution loop (Godot-legal enumeration -> worker choice -> fresh
## revalidation -> live-authority execution). Replaced pieces only:
##   * Hand A: once per RED turn (re-run within the turn only if the adopted
##     plan revision / phase changed), every ready non-HQ RED formation gets
##     {mission, role, direction, depth, engagement} from the frozen Hand A
##     checkpoint via POST /hand_a. The allocation is RUNTIME STATE of this
##     controller only; it is never written into the VictoryPlan, the derived
##     mission plan, packets or memory (the Brain contract stays unallocated).
##   * Hand B: each /decide carries the unit's Hand A order; the frozen Hand B
##     checkpoint picks one candidate from the Godot-enumerated legal set.
##   * No base-Laya group coordinator / blackboards (not part of this contract).
## Any BRAIN / HAND_A / HAND_B / worker failure is an explicit, visible HOLD
## and is counted as a pipeline integration failure, never as learned play.

const HA_TIMEOUT_MS := 120000

var _ha_alloc := {}          # unit_id -> mission_id (runtime only)
var _ha_orders := {}         # unit_id -> {mission_id, task, role, relative_direction, depth, engagement, brain_intent}
var _ha_key := ""            # "turn|revision|phase" of the live allocation
var _ha_calls := 0
var _ha_lat_ms: Array = []
var _ha_last := {}
var _ha_coverage := {"ready": 0, "assigned": 0}
var _pipe_failures: Array = []   # [{layer, code, turn, detail}]
var _pipe_learned_turns := 0
var _hq_holds := 0


func red_controller_mode() -> String:
	return "CLOUD+HAND_AB"


## CONTEXTUAL BRAIN review feedback (sent only with BRAIN_CONTEXT_PACK=v0): per
## unit, the live Hand A order and the Hand B actions it executed in the last
## REVIEW_FEEDBACK_TURNS turns. Positions ride in the packet's compact_state.
const REVIEW_FEEDBACK_TURNS := 3
const REVIEW_FEEDBACK_PER_UNIT := 4


func _review_mission_units() -> Dictionary:
	var out := {}
	var ids: Array = _ha_alloc.keys()
	ids.sort()
	for uid in ids:
		var mid := str(_ha_alloc[uid])
		var rows: Array = out.get(mid, [])
		rows.append(str(uid))
		out[mid] = rows
	return out


func _review_force_feedback(turn: int) -> Dictionary:
	var recent := {}
	for d_val in _ly_log:
		var d: Dictionary = d_val
		if str(d.get("event", "")) != "DECISION" or int(d.get("turn", 0)) < turn - REVIEW_FEEDBACK_TURNS:
			continue
		var parts := str(d.get("selected", "")).split("|")
		var txt := "t%d %s" % [int(d.get("turn", 0)), parts[0]]
		if parts.size() >= 3:
			txt += " " + parts[2]
		if not bool(d.get("executed", false)):
			txt += " (failed)"
		var uid := str(d.get("unit_id", ""))
		var rows: Array = recent.get(uid, [])
		rows.append(txt)
		recent[uid] = rows.slice(maxi(0, rows.size() - REVIEW_FEEDBACK_PER_UNIT))
	var units: Array = []
	var ids: Array = _ha_orders.keys()
	for uid in recent.keys():
		if not ids.has(uid):
			ids.append(uid)
	ids.sort()
	for uid in ids:
		var o: Dictionary = _ha_orders.get(uid, {})
		units.append({"unit_id": str(uid), "mission_id": str(o.get("mission_id", "")), "task": str(o.get("task", "")),
			"role": str(o.get("role", "")), "engagement": str(o.get("engagement", "")),
			"recent_actions": recent.get(uid, [])})
	if units.is_empty():
		return {}
	return {"note": "Per friendly unit: its current Hand A order (mission, task, role, engagement) and the Hand B actions it executed in the last %d turns (MOVE q,r / ATTACK target / WAIT). Positions now: compact_state.friendly_units." % REVIEW_FEEDBACK_TURNS,
		"units": units}


func _pipe_fail(layer: String, code: String, turn: int, detail: String = "") -> void:
	var row := {"layer": layer, "code": code, "turn": turn, "detail": detail.left(300)}
	_pipe_failures.append(row)
	print("[HandsAB] PIPELINE_FAILURE layer=%s code=%s turn=%d %s" % [layer, code, turn, detail.left(200)])
	_combat_log("PIPELINE FAILURE [%s] %s — explicit HOLD (not learned play)" % [layer, code])


## Base-Laya failure events surface here; tag them with their layer.
func _ly_note_decision(info: Dictionary) -> void:
	var ev := str(info.get("event", ""))
	var turn := int(info.get("turn", 0))
	match ev:
		"DECIDE_TRANSPORT_ERROR", "DECIDE_ERROR", "WINNER_NOT_IN_POOL":
			_pipe_fail("HAND_B", ev, turn, str(info.get("error", info.get("selected", ""))))
		"FORCED_STALE":
			_pipe_fail("GODOT", ev, turn, str(info.get("code", "")))
		"LAYA_ERROR_FALLBACK":
			_pipe_fail("HANDS_WORKER", ev, turn, str(info.get("reason", "")))
	super._ly_note_decision(info)


## A rejected Brain response is a visible BRAIN-layer pipeline failure.
func _strict_latch(kind: String, code: String, detail: String, turn: int, call_id: String = "") -> void:
	if StrictCls.is_brain_contract_code(code):
		_pipe_fail("BRAIN", "%s_%s" % [kind, code], turn, detail)
	super._strict_latch(kind, code, detail, turn, call_id)


## Blackboards / group coordinator belong to the base-Laya contract.
func _ly_build_blackboards(_plan_d: Dictionary, _um: Dictionary) -> Dictionary:
	return {}


## Unit -> mission comes from Hand A's runtime allocation, not the plan.
func _unit_mission_map(_plan_d: Dictionary) -> Dictionary:
	return _ha_alloc.duplicate()


func _execute_orders(obs: Dictionary, packet: Dictionary, parsed: Dictionary, model_res: Dictionary, pre_fp: String, turn: int, attempt: int, auto_retries: int = 0) -> Dictionary:
	var req: Dictionary = _manager.hand_a_pending_allocation() if _manager != null else {}
	var st := str(req.get("state", ""))
	if st != MissionManagerCls.HAND_A_AWAITING:
		# LEGACY_V1 = contract mode off; NO_PLAN = no adopted Brain plan;
		# ALLOCATED = someone wrote units into the Brain contract (forbidden).
		_pipe_fail("BRAIN", "HAND_A_SEAM_" + st, turn, "hand_a_pending_allocation state=%s" % st)
		return await _pipe_hold(turn, "brain:" + st)
	var key := "%d|%d|%s" % [turn, int(req.get("plan_revision", 0)), str(req.get("phase_id", ""))]
	if key != _ha_key:
		var got := await _run_hand_a(req, turn)
		if not bool(got.get("ok", false)):
			_pipe_fail("HAND_A", str(got.get("code", "HAND_A_ERROR")), turn, str(got.get("detail", "")))
			return await _pipe_hold(turn, "hand_a:" + str(got.get("code", "")))
		_ha_key = key
	_hold_hq_outside_contract(turn)
	var fb_before := _ly_fallbacks
	var fail_before := _pipe_failures.size()
	var out: Dictionary = await super._execute_orders(obs, packet, parsed, model_res, pre_fp, turn, attempt, auto_retries)
	if _ly_fallbacks == fb_before and _pipe_failures.size() == fail_before:
		_pipe_learned_turns += 1
	out["hand_ab"] = hand_ab_view()
	return out


## The HQ is outside both learned contracts (Hand A allocates non-HQ
## formations; Hand B was never trained on HQ rows), so no model may choose
## for it. Godot holds it through the live authority, visibly and counted
## separately (neither a learned decision nor a pipeline failure).
func _hold_hq_outside_contract(turn: int) -> void:
	var svc: RefCounted = _bridge.get_service()
	var shell := _bridge.get_shell() as Node
	for u_val in (_bridge.get_manager() as RefCounted).call("get_all_units"):
		var u: Dictionary = u_val
		if str(u.get("faction", "")) != _side or str(u.get("class", "")) != "hq" or bool(u.get("action_ended", false)):
			continue
		var uid := str(u.get("id", ""))
		var res: Dictionary = svc.execute_hold_intent(uid, _side)
		if bool(res.get("success", false)):
			_hq_holds += 1
			var r: Node = shell.get("unit_renderer") as Node
			if r != null and r.has_method("set_unit_dimmed"):
				r.call("set_unit_dimmed", uid, true)
		print("[HandsAB] HQ_OUTSIDE_LEARNED_CONTRACT turn=%d %s hold ok=%s" % [turn, uid, str(bool(res.get("success", false)))])
		_ly_note_decision({"event": "HQ_OUTSIDE_LEARNED_CONTRACT", "turn": turn, "unit_id": uid,
			"executed": bool(res.get("success", false))})


func _pipe_hold(turn: int, reason: String) -> Dictionary:
	_ly_turns += 1
	_ly_fallbacks += 1
	_ly_fallback_active = true
	_ly_fallback_reason = reason
	var held := await _end_hold_all("pipeline:" + reason)
	held["hand_ab"] = hand_ab_view()
	_last_view["hand_ab"] = hand_ab_view()
	return held


## Ready = alive, on the field, not HQ / convoy / garrisoned / routed.
func _ready_field_units(own_ids: Dictionary) -> Array:
	var out: Array = []
	for u_val in (_bridge.get_manager() as RefCounted).call("get_all_units"):
		var u: Dictionary = u_val
		if str(u.get("faction", "")) != _side or str(u.get("class", "")) == "hq":
			continue
		if int(u.get("soldier_count", 0)) <= 0 or bool(u.get("garrisoned", false)) or bool(u.get("routed", false)):
			continue
		if bool(u.get("is_convoy", false)) or str(u.get("class", "")) == "supply":
			continue
		var uid := str(u.get("id", ""))
		if own_ids.has(uid):
			out.append(uid)
	out.sort()
	return out


func _run_hand_a(req: Dictionary, turn: int) -> Dictionary:
	var ready := await _await_laya_ready(turn)
	if not bool(ready.get("ok", false)):
		return {"ok": false, "code": "WORKER_NOT_READY", "detail": str(ready.get("error", ""))}
	# Side-local observation, same projection as the Hand A training extractor.
	var knowledge: Dictionary = _bridge.build_knowledge(_side)
	var led: Dictionary = knowledge.get("ledger", {})
	var obs_a := {
		"own_forces": (led.get("own_forces", []) as Array).duplicate(true),
		"visible_enemies": (led.get(_ly_foe_ledger_key(), []) as Array).duplicate(true),
		"last_known_contacts": (led.get(_ly_foe_stale_ledger_key(), []) as Array).duplicate(true),
		"visible_hexes": int(led.get("visible_hexes", 0)),
	}
	var own_ids := {}
	for o in (obs_a["own_forces"] as Array):
		own_ids[str((o as Dictionary).get("id", ""))] = true
	var units := _ready_field_units(own_ids)
	var missions: Array = []
	var mission_ids := {}
	for m_val in (req.get("missions", []) as Array):
		var m: Dictionary = m_val
		var obj: Dictionary = m.get("objective", {})
		var tclass := ""
		if str(obj.get("kind", "")) == "FORMATION_CLASS":
			tclass = str(obj.get("class", ""))
		elif str(obj.get("kind", "")) == "ENEMY_FORMATION":
			tclass = _authorized_foe_class(led, str(obj.get("unit_id", "")))
		missions.append({"mission_id": str(m.get("mission_id", "")), "task": str(m.get("task", "")),
			"area": str(m.get("area", "ANY")), "intent": str(m.get("intent", "")),
			"priority": str(m.get("priority", "")), "target_class": tclass,
			"preserve": bool((m.get("constraints", {}) as Dictionary).get("preserve_force", false))})
		mission_ids[str(m.get("mission_id", ""))] = m
	if missions.is_empty():
		return {"ok": false, "code": "NO_MISSIONS", "detail": "active phase has no missions"}
	if units.is_empty():
		_ha_alloc = {}
		_ha_orders = {}
		_ha_coverage = {"ready": 0, "assigned": 0}
		return {"ok": true}
	var body := {"side": _side, "turn": turn, "bounds": _bridge.map_bounds(), "observation": obs_a,
		"missions": missions, "unit_ids": units}
	_set_state("EXECUTING", "Hand A allocating %d formation(s) to %d mission(s) (turn %d)." % [units.size(), missions.size(), turn])
	var t0 := Time.get_ticks_msec()
	var res := _ly_post("/hand_a", JSON.stringify(body), HA_TIMEOUT_MS)
	var ms := float(Time.get_ticks_msec() - t0)
	if not bool(res.get("ok", false)):
		return {"ok": false, "code": "TRANSPORT", "detail": str(res.get("error", "?"))}
	var doc: Variant = JSON.parse_string(str(res.get("body", "")))
	if not doc is Dictionary or not bool((doc as Dictionary).get("ok", false)):
		var err: Dictionary = (doc as Dictionary).get("error", {}) if doc is Dictionary else {}
		return {"ok": false, "code": str(err.get("code", "BAD_BODY")), "detail": str(err.get("detail", ""))}
	var alloc := {}
	var orders := {}
	for row_val in ((doc as Dictionary).get("units", []) as Array):
		var row: Dictionary = row_val
		var uid := str(row.get("unit_id", ""))
		var mid := str(row.get("mission_assignment", ""))
		if not mission_ids.has(mid):
			return {"ok": false, "code": "UNKNOWN_MISSION", "detail": "%s -> %s" % [uid, mid]}
		var m: Dictionary = mission_ids[mid]
		alloc[uid] = mid
		orders[uid] = {"mission_id": mid, "task": str(m.get("task", "")),
			"role": str(row.get("role", "")), "relative_direction": str(row.get("relative_direction", "")),
			"depth": str(row.get("depth", "")), "engagement": str(row.get("engagement", "")),
			"brain_intent": str(m.get("intent", ""))}
	var missing: Array = []
	for uid in units:
		if not alloc.has(uid):
			missing.append(uid)
	if not missing.is_empty() or alloc.size() != units.size():
		return {"ok": false, "code": "COVERAGE", "detail": "missing=%s got=%d want=%d" % [str(missing), alloc.size(), units.size()]}
	_ha_alloc = alloc
	_ha_orders = orders
	_ha_calls += 1
	_ha_lat_ms.append(ms)
	_ha_coverage = {"ready": units.size(), "assigned": alloc.size()}
	var per_m := {}
	for uid in alloc.keys():
		var mid2 := str(alloc[uid])
		if not per_m.has(mid2):
			per_m[mid2] = []
		(per_m[mid2] as Array).append("%s:%s/%s/%s/%s" % [uid, str(orders[uid]["role"]),
			str(orders[uid]["relative_direction"]), str(orders[uid]["depth"]), str(orders[uid]["engagement"])])
	_ha_last = {"turn": turn, "plan_revision": int(req.get("plan_revision", 0)), "phase_id": str(req.get("phase_id", "")),
		"latency_ms": ms, "missions": per_m,
		"brain_missions_rendered": ((doc as Dictionary).get("brain_missions", []) as Array).duplicate(true),
		"device": (doc as Dictionary).get("device", {})}
	print("[HandsAB] HAND_A turn=%d rev=%d phase=%s units=%d/%d lat=%.0fms alloc=%s" % [turn,
		int(req.get("plan_revision", 0)), str(req.get("phase_id", "")), alloc.size(), units.size(), ms, JSON.stringify(per_m)])
	_ly_note_decision({"event": "HAND_A_ALLOCATION", "turn": turn, "units": alloc.size(), "latency_ms": ms, "missions": per_m})
	return {"ok": true}


## Foe class only from the side's authorized ledger (never truth).
func _authorized_foe_class(led: Dictionary, tid: String) -> String:
	for k in [_ly_foe_ledger_key(), _ly_foe_stale_ledger_key()]:
		for e_val in (led.get(k, []) as Array):
			if str((e_val as Dictionary).get("id", "")) == tid:
				return str((e_val as Dictionary).get("class", ""))
	return ""


func _build_decide_request(obs: Dictionary, plan_d: Dictionary, unit_mission: Dictionary, uid: String, cands: Array, turn: int, tactical: Dictionary = {}) -> Dictionary:
	var req := super._build_decide_request(obs, plan_d, unit_mission, uid, cands, turn, tactical)
	var o: Dictionary = _ha_orders.get(uid, {})
	req["hand_a_order"] = {"task": str(o.get("task", "")), "relative_direction": str(o.get("relative_direction", "")),
		"brain_intent": str(o.get("brain_intent", "")), "mission_id": str(o.get("mission_id", "")),
		"role": str(o.get("role", "")), "depth": str(o.get("depth", "")), "engagement": str(o.get("engagement", ""))}
	req["bounds"] = _bridge.map_bounds()
	return req


func hand_ab_view() -> Dictionary:
	return {
		"hand_a_calls": _ha_calls, "hand_a_latency_ms": _ha_lat_ms.duplicate(),
		"hand_a_coverage": _ha_coverage.duplicate(), "hand_a_last": _ha_last.duplicate(true),
		"hand_a_orders": _ha_orders.duplicate(true),
		"pipeline_failures": _pipe_failures.duplicate(true),
		"pipeline_failure_count": _pipe_failures.size(),
		"learned_turns": _pipe_learned_turns,
		"hq_holds_outside_contract": _hq_holds,
	}


func laya_stats() -> Dictionary:
	var s := super.laya_stats()
	s["authority"] = "HAND_AB_LIVE"
	s["hand_ab"] = hand_ab_view()
	return s
