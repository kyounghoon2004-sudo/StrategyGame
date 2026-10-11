class_name Cloud2MissionManager
extends RefCounted

## CLOUD-GENERAL MISSION HIERARCHY ??mission ownership + review policy.
##
## Owns the StrategicPlan across RED turns: reconciliation against Godot
## truth, per-mission controller turns, status transitions, contingency
## evaluation (no LLM round trip), the bounded factual event stream, the
## opponent model, and the General review policy (event-triggered +
## periodic horizon). It never calls an LLM itself ??it REPORTS review
## requests; the turn controller performs the Cloud exchange.
##
## Godot state always wins: reconcile() runs on every RED turn before any
## decision, and loaded/staged plans are adopted only when fresh.

const MissionCls = preload("res://scripts/cloud2/cloud2_mission.gd")
const PlanCls = preload("res://scripts/cloud2/cloud2_general_plan.gd")
const PacketCls = preload("res://scripts/cloud2/cloud2_general_packet.gd")
const ContextPackCls = preload("res://scripts/cloud2/cloud2_brain_context.gd")
const CoordMenuCls = preload("res://scripts/cloud2/cloud2_coord_menu.gd")
const OpportunityCls = preload("res://scripts/cloud2/cloud2_opportunity.gd")
const ControllerCls = preload("res://scripts/cloud2/cloud2_mission_controller.gd")
const SolverCls = preload("res://scripts/cloud2/cloud2_class_option_solver.gd")
const MemoryCls = preload("res://scripts/cloud2/cloud2_battle_memory.gd")
const TraceCls = preload("res://scripts/cloud2/cloud2_general_trace.gd")
## VICTORY PLAN V0 (additive): persistent multi-phase strategic memory.
const VictoryPlanCls = preload("res://scripts/cloud2/cloud2_victory_plan.gd")
## BRAIN→HAND A contract mode flag lives with the authoring contract.
const AuthoringCls = preload("res://scripts/cloud2/cloud2_victory_authoring.gd")
const HAND_A_AWAITING := "AWAITING_HAND_A"
## JEV shadow observer (SHADOW ONLY): read-only telemetry, zero authority.
const JevShadowCls = preload("res://scripts/cloud2/cloud2_jev_shadow.gd")

## A staged General plan goes stale when the battle drifts this far past
## the review base, or when the RED roster / HQ posture changed meanwhile.
const STALE_TURN_DRIFT := 2
const MAX_EVENTS := 64
const MAX_EVENTS_PER_PACKET := 24

var _plan := {}
var _coordination := {}
var _battle_id := ""
var _events: Array = []
var _prev := {}
var _force_baseline := {}
var _battle_baseline := 0
var _seen_enemies := {}
var _memory_loaded := false
var _seed_base := 0
var _seed_bound := false
## Authoritative BLUE->RED combat events wait here until one safe General
## review consumes the frozen batch. Newer events survive an older in-flight
## batch by monotonically increasing event_id.
var _next_wake_event_id := 1
var _pending_wake_events: Array = []
var _active_wake_batch := {}
var _last_wake_review := {}
## VICTORY PLAN V0 state (additive; empty until a VictoryPlan binds).
var _vp := {}
var _vp_revisions: Array = []
var _vp_audit: Array = []
var _vp_call_seq := 0
var _vp_lineage_seq := 0
## STRATEGIC REPLAN (context pack only, env BRAIN_STRATEGIC_REPLAN_TURNS=N > 0): turn of the last forced
## strategic replan request. Every N turns the Brain writes a fresh multi-phase plan (installed as
## EMERGENCY_REPLAN) instead of only patching missions of an exhausted plan.
var _vp_last_strategic_turn := 0


static func strategic_replan_every() -> int:
	var v := OS.get_environment("BRAIN_STRATEGIC_REPLAN_TURNS").strip_edges()
	return int(v) if v.is_valid_int() else 0


func vp_note_strategic(turn: int) -> void:
	_vp_last_strategic_turn = turn
var _vp_reserve_released := {}
## Frozen prefetch snapshot the opening plan was authored from (repair V1).
var _vp_initial_snapshot := ""
## SYMMETRIC V1: owning side of this manager ("red" default = legacy).
## The turn controller propagates its side here at setup/set_side time.
var _side := "red"


func reset_battle() -> void:
	_plan = {}
	_coordination = {}
	_battle_id = ""
	_events = []
	_prev = {}
	_force_baseline = {}
	_battle_baseline = 0
	_seen_enemies = {}
	_memory_loaded = false
	_seed_base = 0
	_seed_bound = false
	_next_wake_event_id = 1
	_pending_wake_events = []
	_active_wake_batch = {}
	_last_wake_review = {}
	_vp = {}
	_vp_revisions = []
	_vp_audit = []
	_vp_call_seq = 0
	_vp_lineage_seq = 0
	_vp_reserve_released = {}
	_vp_initial_snapshot = ""


func battle_id() -> String:
	return _battle_id


## SYMMETRIC V1: side binding + helpers. Unknown values coerce to red.
func set_side(s: String) -> void:
	var want := s.strip_edges().to_lower()
	_side = "blue" if want == "blue" else "red"


func get_side() -> String:
	return _side


func _foe() -> String:
	return "red" if _side == "blue" else "blue"


func _SIDE() -> String:
	return _side.to_upper()


## SYMMETRIC V1: disk-memory namespace. RED keeps the bare battle id
## (Human-vs-Cloud paths byte-identical); BLUE gets a suffixed sibling
## so both managers never overwrite each other's persisted plans.
func _mem_id() -> String:
	if _side == "blue":
		return "%s__blue" % _battle_id
	return _battle_id


func get_plan() -> Dictionary:
	return _plan.duplicate(true)


## FAST COORDINATOR support. The menu is obs-derived (stateless); the
## coordination record binds an adopted plan to the Cloud's choice IDs so a
## later ADJUST review can overlay deltas deterministically. Stored beside
## the plan (canonical plan dicts carry no coordinator metadata).
func build_coord_menu(obs: Dictionary) -> Dictionary:
	return CoordMenuCls.build_menu(obs)


func bind_coordination(meta: Dictionary) -> void:
	_coordination = (meta as Dictionary).duplicate(true)


func get_coordination() -> Dictionary:
	return _coordination.duplicate(true)


## KEEP review: the plan stands; only the review clock (and optionally fresh
## hypotheses) advances. No version bump, no mission churn.
func confirm_plan(turn: int, hypotheses: Array = [], has_hypotheses: bool = false) -> Dictionary:
	if not PlanCls.has_plan(_plan):
		return {"ok": false, "code": "COORD_NO_PLAN", "detail": "No plan to keep.", "version": 0}
	_plan["last_review_turn"] = turn
	if has_hypotheses:
		_plan["opponent_hypotheses"] = hypotheses.duplicate(true)
	_add_event(turn, "PLAN_REVIEWED", {"version": int(_plan.get("plan_version", 0)), "decision": "KEEP"})
	return {"ok": true, "code": "", "detail": "", "version": int(_plan.get("plan_version", 0))}


func get_events() -> Array:
	return _events.duplicate(true)


## Capture only a real, successful authoritative FOE attack against OWN.
## (RED manager: BLUE attacking RED; BLUE manager: RED attacking BLUE.)
## The result is emitted by Step3UnitManager after combat mutation; no
## proximity inference or tactical interpretation occurs here.
func record_authoritative_combat_event(result: Dictionary, obs: Dictionary) -> Dictionary:
	if not bool(result.get("success", false)):
		return {"recorded": false, "reason": "COMBAT_NOT_SUCCESSFUL"}
	var attacker_faction := str(result.get("attacker_faction", "")).to_lower()
	var defender_faction := str(result.get("defender_faction", "")).to_lower()
	if attacker_faction != _foe() or defender_faction != _side:
		if _side == "red":
			return {"recorded": false, "reason": "NOT_BLUE_ATTACKING_RED"}
		return {"recorded": false, "reason": "NOT_RED_ATTACKING_BLUE"}
	var bid := str(obs.get("battle_id", "")).strip_edges()
	if not bid.is_empty() and bid != _battle_id:
		reset_battle()
		_battle_id = bid
	var turn := int(result.get("turn", obs.get("turn", 0)))
	var defender_id := str(result.get("defender_id", "")).strip_edges().to_upper()
	var detail := {
		"phase": str(result.get("phase", "BLUE")).to_upper(),
		"attacker_id": str(result.get("attacker_id", "")).strip_edges().to_upper(),
		"defender_id": defender_id,
		"attacker_class": str(result.get("attacker_class", "")).to_upper(),
		"defender_class": str(result.get("defender_class", "")).to_upper(),
		"attacker_coord": (result.get("attacker_coord", []) as Array).duplicate(true),
		"defender_coord": (result.get("defender_coord", []) as Array).duplicate(true),
		"attacker_casualties": int(result.get("attacker_casualties", 0)),
		"defender_casualties": int(result.get("defender_casualties", 0)),
		"attacker_remaining_troops": int(result.get("attacker_remaining_troops", 0)),
		"defender_remaining_troops": int(result.get("defender_remaining_troops", 0)),
		"destroyed": bool(result.get("defender_destroyed", false)),
		"mission_id": _mission_for_unit(defender_id),
	}
	var added: Array = []
	added.append(_queue_wake_event(turn, "FRIENDLY_UNIT_ATTACKED", detail))
	if bool(result.get("defender_destroyed", false)):
		added.append(_queue_wake_event(turn, "FRIENDLY_UNIT_DESTROYED", detail))
	return {"recorded": true, "events": added, "pending_event_count": _pending_wake_events.size(),
		"review_pending": true}


func wakeup_view() -> Dictionary:
	var pending_kinds: Array = []
	for e_val in _pending_wake_events:
		if e_val is Dictionary:
			pending_kinds.append(str((e_val as Dictionary).get("kind", "")))
	return {
		"review_pending": not _pending_wake_events.is_empty(),
		"pending_event_count": _pending_wake_events.size(),
		"pending_event_kinds": pending_kinds,
		"pending_events": _pending_wake_events.duplicate(true),
		"active_batch": _active_wake_batch.duplicate(true),
		"last_review": _last_wake_review.duplicate(true),
	}


## Exact factual delta for an event-driven review. Periodic/manual reviews
## retain their existing broader events-since-review context.
func events_for_review(review: Dictionary) -> Array:
	var cutoff := int(review.get("event_batch_id", 0))
	if cutoff <= 0:
		return events_since_review()
	var out: Array = []
	for e_val in _pending_wake_events:
		if e_val is Dictionary and int((e_val as Dictionary).get("event_id", 0)) <= cutoff:
			out.append((e_val as Dictionary).duplicate(true))
	return out


func note_review_started(review: Dictionary) -> void:
	var cutoff := int(review.get("event_batch_id", 0))
	if cutoff <= 0:
		return
	_active_wake_batch = {
		"event_batch_id": cutoff,
		"event_count": int(review.get("event_count", 0)),
		"trigger": str(review.get("trigger", "")),
		"turn": int(review.get("turn", 0)),
		"status": "IN_FLIGHT",
	}
	_last_wake_review = _active_wake_batch.duplicate(true)


func note_review_staged(review: Dictionary, decision: String) -> void:
	if int(review.get("event_batch_id", 0)) <= 0:
		return
	_active_wake_batch["status"] = "STAGED"
	_active_wake_batch["decision"] = decision
	_last_wake_review = _active_wake_batch.duplicate(true)


func note_review_failed(review: Dictionary, code: String) -> void:
	if int(review.get("event_batch_id", 0)) <= 0:
		return
	_last_wake_review = {
		"event_batch_id": int(review.get("event_batch_id", 0)),
		"event_count": int(review.get("event_count", 0)),
		"trigger": str(review.get("trigger", "")),
		"turn": int(review.get("turn", 0)),
		"status": "FAILED",
		"result": code,
	}
	_active_wake_batch = {}


## Acknowledge only the frozen cutoff. Events arriving during the request
## have larger ids and remain pending for the next safe review window.
func acknowledge_review_events(review: Dictionary, decision: String, plan_version: int, result: String) -> Dictionary:
	var cutoff := int(review.get("event_batch_id", 0))
	if cutoff <= 0:
		return {"acknowledged": 0, "remaining": _pending_wake_events.size()}
	var kept: Array = []
	var acknowledged := 0
	for e_val in _pending_wake_events:
		if e_val is Dictionary and int((e_val as Dictionary).get("event_id", 0)) <= cutoff:
			acknowledged += 1
		else:
			kept.append(e_val)
	_pending_wake_events = kept
	_last_wake_review = {
		"event_batch_id": cutoff,
		"event_count": int(review.get("event_count", acknowledged)),
		"trigger": str(review.get("trigger", "")),
		"turn": int(review.get("turn", 0)),
		"status": result,
		"decision": decision,
		"plan_version": plan_version,
	}
	_active_wake_batch = {}
	return {"acknowledged": acknowledged, "remaining": _pending_wake_events.size()}


func note_review_stale(review: Dictionary, reason: String) -> void:
	if int(review.get("event_batch_id", 0)) <= 0:
		return
	_last_wake_review = {
		"event_batch_id": int(review.get("event_batch_id", 0)),
		"event_count": int(review.get("event_count", 0)),
		"trigger": str(review.get("trigger", "")),
		"turn": int(review.get("turn", 0)),
		"status": "STALE",
		"result": reason,
	}
	_active_wake_batch = {}


func seed_base() -> int:
	return _seed_base


## One hierarchy RED turn (no network inside): reconcile, evaluate, decide.
## Legacy entry: forces RED semantics for this call however the instance is
## bound, so every existing harness/test keeps exact RED behavior.
func red_turn(sim: RefCounted, obs: Dictionary) -> Dictionary:
	var keep := _side
	_side = "red"
	var out := side_turn(sim, obs)
	_side = keep
	return out


## SYMMETRIC V1: one hierarchy side turn using the bound side.
## Returns {orders, traces, statuses, review, events_added, corrections,
## mission_count, decisions}.
func side_turn(sim: RefCounted, obs: Dictionary) -> Dictionary:
	var turn := int(obs.get("turn", 0))
	var snapshot := str(obs.get("snapshot_id", ""))
	var bid := str(obs.get("battle_id", ""))
	if bid != _battle_id:
		reset_battle()
		_battle_id = bid
	if not _seed_bound:
		_seed_base = _derive_seed(sim, bid)
		_seed_bound = true
	if not _memory_loaded:
		_memory_loaded = true
		_load_memory(obs, turn)
	if not PlanCls.has_plan(_plan):
		_plan = PlanCls.default_plan(obs, turn)
		_capture_baselines(obs)
		_add_event(turn, "PLAN_APPLIED", {"version": 1, "source": "local_fallback"})
	var rec := PlanCls.reconcile(_plan, obs)
	_plan = rec.get("plan", {})
	var corrections: Array = rec.get("corrections", [])
	if VictoryPlanCls.has_plan(_vp):
		var vrec := VictoryPlanCls.reconcile(_vp, obs)
		_vp = vrec.get("plan", {})
		corrections.append_array(vrec.get("corrections", []))
	_note_seen_enemies(obs)
	_diff_events(obs, turn)
	_evaluate_mission_conditions(obs, turn)
	var fired := _evaluate_contingencies(obs, turn)
	# Coverage runs AFTER conditions/contingencies so forces freed by a
	# completion ??or still waiting on a trigger ??are classified correctly
	# for THIS turn instead of idling until the next one.
	_cover_unassigned(obs, turn)
	_capture_missing_baselines(obs)
	var bounds: Dictionary = sim.map_bounds() if sim != null and sim.has_method("map_bounds") else {}
	var orders: Array = []
	var traces: Array = []
	var statuses: Array = []
	var decisions := 0
	for m_val in PlanCls.active_missions(_plan):
		var m: Dictionary = m_val
		var st := str(m.get("status", ""))
		if st == "WAITING_TRIGGER":
			continue
		if st == "ASSIGNED":
			var ar := str(m.get("status_reason", ""))
			_set_status(m, "ACTIVE", ar if ar.begins_with("CONTINGENCY") else "TURN_START", turn)
		var ctrl := ControllerCls.new()
		ctrl.setup(m, _plan.get("doctrine", {}), _seed_base)
		var urgency := 0.5 if _trigger_true("HQ_THREATENED", {}, obs, m) else 0.0
		var dctx := {"turn": turn, "snapshot_id": snapshot,
			"turns_active": turn - int(m.get("activated_turn", turn)), "urgency": urgency, "bounds": bounds,
			"main_effort": str((_plan.get("concept", {}) as Dictionary).get("main_effort", ""))}
		var res: Dictionary = ctrl.decide(sim, obs, dctx, _side)
		# JEV SHADOW (no authority): observes the decided tables, proposes via
		# the local worker, logs telemetry. Returns immediately when disabled.
		JevShadowCls.observe(sim, obs, m, _plan.get("doctrine", {}), dctx,
			res.get("trace", {}), _seed_base)
		decisions += 1
		traces.append(res.get("trace", {}))
		var hint := str(res.get("status_hint", "ACTIVE"))
		if hint == "BLOCKED":
			_set_status(m, "BLOCKED", str(res.get("reason", "NO_PROGRESS_ACTION")), turn)
		elif st == "BLOCKED" and hint == "ACTIVE":
			_set_status(m, "ACTIVE", "RESUMED", turn)
		statuses.append(_status_row(m))
		var res_orders: Array = res.get("orders", [])
		if res_orders.is_empty() and not (res.get("command", {}) as Dictionary).is_empty():
			res_orders = [{"command": res.get("command", {}), "units": res.get("ready_units", [])}]
		for o_val in res_orders:
			if o_val is Dictionary and not ((o_val as Dictionary).get("command", {}) as Dictionary).is_empty():
				var o_units: Array = ((o_val as Dictionary).get("units", []) as Array).duplicate(true)
				orders.append({"mission_id": str(m.get("mission_id", "?")),
					"order": (o_val as Dictionary).get("command", {}),
					"exec_ctx": _exec_ctx_for_order(m, obs, res.get("trace", {}), o_units)})
	for m2_val in (_plan.get("missions", []) as Array):
		var m2: Dictionary = m2_val
		if str(m2.get("status", "")) == "WAITING_TRIGGER" or MissionCls.is_terminal(str(m2.get("status", ""))):
			statuses.append(_status_row(m2))
	if VictoryPlanCls.has_plan(_vp):
		_vp_mirror_execution()
		_vp_evaluate_branches(obs, turn)
		_vp_evaluate_reserve(obs, turn)
	var review := review_due(obs, turn)
	_add_event(turn, "RED_TURN" if _side == "red" else "BLUE_TURN", {"snapshot": snapshot.left(48), "orders": orders.size(),
		"decisions": decisions, "contingencies_fired": fired.size(),
		"review_requested": bool(review.get("requested", false))})
	_persist(obs, turn)
	return {"orders": orders, "traces": traces, "statuses": statuses, "review": review,
		"events_added": fired.size(), "corrections": corrections,
		"mission_count": (_plan.get("missions", []) as Array).size(), "decisions": decisions}


## GROUP_RETARGET_CONTRACT_V1 execution context, attached to every order.
## Plain data only (JSON-safe): the compiler's execution-time revalidation
## reads it to distinguish same-batch target death (cancel / scored retarget)
## from pre-batch invalidity (legacy explicit failure). Consumers that do not
## know this key ignore it; decision-time code never reads it.
func _exec_ctx_for_order(mission: Dictionary, obs: Dictionary, trace: Dictionary, units: Array) -> Dictionary:
	var mid := str(mission.get("mission_id", "?"))
	var dstate: Dictionary = SolverCls.designation_state(mission, obs)
	var alive: Array = []
	for e_val in (obs.get("known_enemy_units", []) as Array):
		if e_val is Dictionary and str((e_val as Dictionary).get("contact_state", "")) == "current_visible":
			alive.append(str((e_val as Dictionary).get("unit_id", "")).strip_edges().to_upper())
	alive.sort()
	var tables := {}
	for t_val in (trace.get("units", []) as Array):
		if t_val is Dictionary:
			tables[str((t_val as Dictionary).get("unit_id", ""))] = t_val
	var scored := {}
	for uid in units:
		var t: Dictionary = tables.get(str(uid), {})
		var seq: Array = []
		# target_scores arrive best-first from the production resolver; the
		# order is preserved exactly (no rescoring at execution time).
		for s_val in (t.get("target_scores", []) as Array):
			if s_val is Dictionary:
				seq.append(str((s_val as Dictionary).get("target_id", "")).strip_edges().to_upper())
		scored[str(uid)] = seq
	var complete_on: Array = []
	for c_val in (mission.get("success_conditions", []) as Array):
		if c_val is Dictionary and str((c_val as Dictionary).get("trigger", "")) == "TARGET_DESTROYED":
			var tid := str(((c_val as Dictionary).get("params", {}) as Dictionary).get("unit_id", "")).strip_edges().to_upper()
			if not tid.is_empty():
				complete_on.append(tid)
	return {"mission_id": mid, "task": str(mission.get("task", "?")),
		"mission_target_id": str(dstate.get("id", "")),
		"designation_policy": str(dstate.get("policy", "NONE")),
		"decision_alive": alive, "unit_targets": scored,
		"objective_complete_on": complete_on}


## Fold execution results back into mission statuses (post-executor).
## exec_rows: [{unit_id, ...}] units that acted this turn.
func post_turn(exec_rows: Array, turn: int) -> void:
	var acted := {}
	for r_val in exec_rows:
		if r_val is Dictionary:
			acted[str((r_val as Dictionary).get("unit_id", "")).strip_edges().to_upper()] = true
	for m_val in (_plan.get("missions", []) as Array):
		if not m_val is Dictionary:
			continue
		var m: Dictionary = m_val
		if MissionCls.is_terminal(str(m.get("status", ""))):
			continue
		var hit := false
		for u in (m.get("assigned_units", []) as Array):
			if acted.has(str(u).strip_edges().to_upper()):
				hit = true
				break
		if hit:
			m["progress_turn"] = turn
			if str(m.get("status", "")) == "ACTIVE":
				_set_status(m, "PROGRESSING", "FORCE_ACTED", turn)


## Adopt a validated General plan (fresh or staged). Assigns a monotonic
## local version, binds the battle id (so the next red_turn keeps ??not
## resets ??this plan), and stamps activation turns on the missions.
func apply_plan(plan: Dictionary, turn: int, snapshot: String, battle_id: String = "") -> Dictionary:
	var checked := PlanCls.validate_plan(plan, {"turn": turn, "snapshot_id": snapshot,
		"plan_version": int(_plan.get("plan_version", 0)) + 1})
	if not bool(checked.get("ok", false)):
		return {"ok": false, "code": str(checked.get("code", "PLAN_INVALID")),
			"detail": str(checked.get("detail", "")), "version": 0}
	if not battle_id.strip_edges().is_empty():
		_battle_id = battle_id.strip_edges()
		_memory_loaded = true # an explicit plan binds this battle; skip disk adoption
	var adopted: Dictionary = checked.get("plan", {})
	adopted["supersedes_version"] = int(_plan.get("plan_version", 0))
	adopted["plan_version"] = int(_plan.get("plan_version", 0)) + 1
	adopted["last_review_turn"] = turn
	adopted["based_on_snapshot"] = snapshot
	for m_val in (adopted.get("missions", []) as Array):
		if m_val is Dictionary:
			(m_val as Dictionary)["activated_turn"] = turn
			if str((m_val as Dictionary).get("status", "")) == "ASSIGNED":
				pass # first red_turn flips ASSIGNED -> ACTIVE
	_plan = adopted
	_force_baseline = {}
	_add_event(turn, "PLAN_APPLIED", {"version": int(_plan.get("plan_version", 0)),
		"source": str(_plan.get("source", "general")), "missions": (_plan.get("missions", []) as Array).size()})
	return {"ok": true, "code": "", "detail": "", "version": int(_plan.get("plan_version", 0))}


## Staleness gate for a staged General plan. stale when the battle moved
## materially past the review base: turn drift, RED roster change, or HQ
## posture flip. Never executes a stale plan blindly.
func staged_staleness(staged: Dictionary, review_base: Dictionary, obs: Dictionary) -> Dictionary:
	var turn := int(obs.get("turn", 0))
	var base_turn := int(review_base.get("turn", turn))
	if turn - base_turn > STALE_TURN_DRIFT:
		return {"stale": true, "reason": "TURN_DRIFT_%d" % (turn - base_turn)}
	var live := {}
	for u_val in (obs.get("friendly_units", []) as Array):
		if u_val is Dictionary:
			live[str((u_val as Dictionary).get("unit_id", "")).strip_edges().to_upper()] = true
	var base_ids: Array = (review_base.get("red_ids", []) as Array) + (review_base.get("blue_ids", []) as Array)
	for uid in base_ids:
		if not live.has(str(uid)):
			return {"stale": true, "reason": "ROSTER_CHANGED_%s_LOST" % str(uid)}
	var hq_now := bool(OpportunityCls.hq_threatened(obs).get("threatened", false))
	if hq_now != bool(review_base.get("hq_threatened", false)):
		return {"stale": true, "reason": "HQ_POSTURE_FLIPPED"}
	if str(staged.get("based_on_snapshot", "")) != str(review_base.get("snapshot_id", "")) \
		and not str(staged.get("based_on_snapshot", "")).is_empty():
		return {"stale": true, "reason": "SNAPSHOT_ECHO_MISMATCH"}
	return {"stale": false, "reason": ""}


static func review_base_from_obs(obs: Dictionary, side: String = "red") -> Dictionary:
	var ids: Array = []
	for u_val in (obs.get("friendly_units", []) as Array):
		if u_val is Dictionary:
			ids.append(str((u_val as Dictionary).get("unit_id", "")).strip_edges().to_upper())
	ids.sort()
	if side.strip_edges().to_lower() == "blue":
		return {"snapshot_id": str(obs.get("snapshot_id", "")), "turn": int(obs.get("turn", 0)),
			"blue_ids": ids, "hq_threatened": bool(OpportunityCls.hq_threatened(obs).get("threatened", false))}
	return {"snapshot_id": str(obs.get("snapshot_id", "")), "turn": int(obs.get("turn", 0)),
		"red_ids": ids, "hq_threatened": bool(OpportunityCls.hq_threatened(obs).get("threatened", false))}


## General review packet for the current situation + trigger.
func build_review_packet(obs: Dictionary, trigger: Dictionary) -> Dictionary:
	var since: Array = []
	var last_rev := int(_plan.get("last_review_turn", 0))
	for e_val in _events:
		if e_val is Dictionary and int((e_val as Dictionary).get("turn", 0)) >= last_rev:
			since.append(e_val)
		if since.size() >= MAX_EVENTS_PER_PACKET:
			break
	return PacketCls.build(obs, _plan, since, trigger, _side)


func events_since_review() -> Array:
	var last_rev := int(_plan.get("last_review_turn", 0))
	var out: Array = []
	for e_val in _events:
		if e_val is Dictionary and int((e_val as Dictionary).get("turn", 0)) >= last_rev:
			out.append(e_val)
	return out


## Review policy: plan review_conditions + blocked/completed missions +
## periodic horizon. Returns {requested, trigger, reason}.
func review_due(obs: Dictionary, turn: int) -> Dictionary:
	# BATTLE_TERMINAL_CONTRACT_V0: terminal battle outranks every lifecycle
	# state ??no General review, no fallback replan, no mission-failure review.
	var mstatus := str((obs.get("mission", {}) as Dictionary).get("status", ""))
	if mstatus == "victory" or mstatus == "defeat" or mstatus == "expired":
		return {"requested": false, "trigger": "BATTLE_TERMINAL",
			"reason": "Battle terminal (%s); no strategic review." % mstatus,
			"mission_status": mstatus}
	if not PlanCls.has_plan(_plan):
		return {"requested": true, "trigger": "NO_PLAN", "reason": "No strategic plan exists."}
	# A frozen event batch already being reviewed (or staged for adoption) is
	# not another request. New arrivals remain buffered behind its cutoff.
	if not _active_wake_batch.is_empty():
		return {"requested": false, "trigger": "REVIEW_IN_FLIGHT",
			"reason": "A significant-event batch is already under review.",
			"event_count": _pending_wake_events.size(),
			"event_batch_id": int(_active_wake_batch.get("event_batch_id", 0))}
	if ContextPackCls.enabled() and VictoryPlanCls.has_plan(_vp) and strategic_replan_every() > 0 			and turn - _vp_last_strategic_turn >= strategic_replan_every():
		return {"requested": true, "trigger": "STRATEGIC_REPLAN", "turn": turn,
			"reason": "Strategic replan due (every %d turns): write a fresh multi-phase plan from the current situation." % strategic_replan_every()}
	if not _pending_wake_events.is_empty():
		var trigger := "FRIENDLY_UNIT_ATTACKED"
		var cutoff := 0
		var kinds: Array = []
		for e_val in _pending_wake_events:
			if not e_val is Dictionary:
				continue
			var e: Dictionary = e_val
			cutoff = maxi(cutoff, int(e.get("event_id", 0)))
			var kind := str(e.get("kind", ""))
			kinds.append(kind)
			if kind == "FRIENDLY_UNIT_DESTROYED":
				trigger = kind
		var ev_review := {"requested": true, "trigger": trigger,
			"reason": "%d authoritative %s->%s combat event(s) buffered." % [_pending_wake_events.size(), _foe().to_upper(), _SIDE()],
			"turn": turn, "event_count": _pending_wake_events.size(),
			"event_batch_id": cutoff, "trigger_events": kinds}
		# CONTEXTUAL BRAIN (context pack only): one review per turn window, so an
		# event batch used to hide a due phase transition (PHASE_SUCCESS etc.) for
		# as long as combat continued. Carry it in the same review instead.
		if ContextPackCls.enabled() and VictoryPlanCls.has_plan(_vp):
			var due := vp_transition_review(obs, turn)
			if bool(due.get("requested", false)):
				ev_review["also_due"] = [{"trigger": str(due.get("trigger", "")), "reason": str(due.get("reason", ""))}]
				ev_review["reason"] = str(ev_review["reason"]) + " ALSO DUE: " + str(due.get("reason", ""))
		return ev_review
	if VictoryPlanCls.has_plan(_vp):
		var vp_review := vp_transition_review(obs, turn)
		if bool(vp_review.get("requested", false)):
			return vp_review
	for c_val in (_plan.get("review_conditions", []) as Array):
		if c_val is Dictionary and _trigger_true(str((c_val as Dictionary).get("trigger", "")),
			(c_val as Dictionary).get("params", {}), obs, {}):
			return {"requested": true, "trigger": str((c_val as Dictionary).get("trigger", "")),
				"reason": "Plan review condition fired."}
	for m_val in (_plan.get("missions", []) as Array):
		if not m_val is Dictionary:
			continue
		var st := str((m_val as Dictionary).get("status", ""))
		if st == "BLOCKED":
			return {"requested": true, "trigger": "MISSION_BLOCKED",
				"reason": "%s blocked (%s)." % [str((m_val as Dictionary).get("mission_id", "?")), str((m_val as Dictionary).get("status_reason", ""))]}
		if st == "SUCCESS" and int((m_val as Dictionary).get("status_turn", 0)) == turn:
			return {"requested": true, "trigger": "MISSION_COMPLETE",
				"reason": "%s completed." % str((m_val as Dictionary).get("mission_id", "?"))}
		## MISSION_FAILED (lifecycle handoff): a mission that just transitioned to a
		## terminal failure state requests exactly one strategic review, in the turn
		## of the transition. status_turn pins the request to the transition turn, so
		## later turns in the same failed state never re-request (no event storm).
		if (st == "FAILED" or st == "ABORTED") and int((m_val as Dictionary).get("status_turn", -1)) == turn:
			return {"requested": true, "trigger": "MISSION_FAILED",
				"reason": "%s %s (%s) ??strategic reassignment needed for its force." % [str((m_val as Dictionary).get("mission_id", "?")), st.to_lower(), str((m_val as Dictionary).get("status_reason", ""))],
				"failed_mission": str((m_val as Dictionary).get("mission_id", "?")),
				"failed_reason": str((m_val as Dictionary).get("status_reason", ""))}
	var horizon := int(_plan.get("review_horizon_turns", 4))
	if turn - int(_plan.get("last_review_turn", 0)) >= horizon:
		return {"requested": true, "trigger": "PERIODIC_HORIZON",
			"reason": "Review horizon reached (%d turns)." % horizon}
	if bool(OpportunityCls.hq_threatened(obs).get("threatened", false)):
		return {"requested": true, "trigger": "HQ_THREATENED", "reason": "%s HQ threatened." % _SIDE()}
	return {"requested": false, "trigger": "", "reason": ""}


## Trigger evaluation against authoritative observation + mission context.
func _trigger_true(name: String, params: Dictionary, obs: Dictionary, mission: Dictionary) -> bool:
	var turn := int(obs.get("turn", 0))
	match name.strip_edges().to_upper():
		"ALWAYS":
			return true
		"NEVER":
			return false
		"MISSION_BLOCKED":
			var want := str(params.get("mission_id", "")).strip_edges().to_upper()
			for m_val in (_plan.get("missions", []) as Array):
				if m_val is Dictionary and str((m_val as Dictionary).get("status", "")) == "BLOCKED":
					if want.is_empty() or str((m_val as Dictionary).get("mission_id", "")) == want:
						return true
			return false
		"MISSION_COMPLETE":
			var want2 := str(params.get("mission_id", "")).strip_edges().to_upper()
			for m2_val in (_plan.get("missions", []) as Array):
				if m2_val is Dictionary and str((m2_val as Dictionary).get("status", "")) == "SUCCESS":
					if want2.is_empty() or str((m2_val as Dictionary).get("mission_id", "")) == want2:
						return true
			return false
		"FORCE_STRENGTH_BELOW":
			var frac := float(params.get("fraction", 0.5))
			var mid := str(params.get("mission_id", "")).strip_edges().to_upper()
			if mid.is_empty() and not mission.is_empty():
				mid = str(mission.get("mission_id", ""))
			if mid.is_empty():
				var total := _red_soldiers(obs)
				return _battle_baseline > 0 and float(total) < float(_battle_baseline) * frac
			var base := float(_force_baseline.get(mid, 0.0))
			if base <= 0.0:
				return false
			return float(_mission_soldiers(obs, mid)) < base * frac
		"ENEMY_COMMITMENT_HIGH":
			var region := str(params.get("region", "CENTER"))
			var threshold := int(params.get("threshold", OpportunityCls.COMMITMENT_HIGH_COUNT))
			return OpportunityCls.enemy_commitment(obs, region) >= threshold
		"ENEMY_CLASS_DETECTED":
			var cls := str(params.get("class", ""))
			if cls.is_empty():
				return false
			return not OpportunityCls.enemy_class_detected(obs, cls, str(params.get("region", "ANY"))).is_empty()
		"HQ_THREATENED":
			return bool(OpportunityCls.hq_threatened(obs).get("threatened", false))
		"LOCAL_ADVANTAGE_HIGH":
			var region2 := str(params.get("region", "ANY"))
			var ratio := float(params.get("ratio", OpportunityCls.ADVANTAGE_HIGH_RATIO))
			return OpportunityCls.local_advantage_high(OpportunityCls.region_posture(obs, region2), ratio)
		"OBJECTIVE_EXPOSED":
			return not OpportunityCls.exposed_objectives(obs).is_empty()
		"TURNS_ELAPSED":
			var need := int(params.get("turns", 1))
			var since := int(params.get("since", mission.get("activated_turn", turn) if not mission.is_empty() else turn))
			return turn - since >= need
		"TARGET_DESTROYED":
			var tid := str(params.get("unit_id", "")).strip_edges().to_upper()
			if tid.is_empty() or not _seen_enemies.has(tid):
				return false
			for e_val in (obs.get("known_enemy_units", []) as Array):
				if e_val is Dictionary and str((e_val as Dictionary).get("unit_id", "")).strip_edges().to_upper() == tid:
					return false
			return true
		"REGION_OCCUPIED":
			var region3 := str(params.get("region", "CENTER")).strip_edges().to_upper()
			var side := str(params.get("side", _SIDE())).strip_edges().to_upper()
			if side != _SIDE():
				for e2_val in (obs.get("known_enemy_units", []) as Array):
					if e2_val is Dictionary and str((e2_val as Dictionary).get("contact_state", "")) == "current_visible" \
						and str((e2_val as Dictionary).get("region", "")).strip_edges().to_upper() == region3:
						return true
				return false
			for u_val in (obs.get("friendly_units", []) as Array):
				if u_val is Dictionary and str((u_val as Dictionary).get("region", "")).strip_edges().to_upper() == region3:
					return true
			return false
		"REGION_REACHED":
			var region4 := str(params.get("region", mission.get("area", "CENTER"))).strip_edges().to_upper()
			var mid4 := str(params.get("mission_id", mission.get("mission_id", ""))).strip_edges().to_upper()
			var m4 := PlanCls.mission_by_id(_plan, mid4) if not mid4.is_empty() else mission
			if m4.is_empty():
				return false
			var ids := {}
			for u2 in (m4.get("assigned_units", []) as Array):
				ids[str(u2).strip_edges().to_upper()] = true
			for u3_val in (obs.get("friendly_units", []) as Array):
				if u3_val is Dictionary and ids.has(str((u3_val as Dictionary).get("unit_id", "")).strip_edges().to_upper()) \
					and str((u3_val as Dictionary).get("region", "")).strip_edges().to_upper() == region4:
					return true
			return false
	return false


func _evaluate_mission_conditions(obs: Dictionary, turn: int) -> void:
	for m_val in (_plan.get("missions", []) as Array):
		if not m_val is Dictionary:
			continue
		var m: Dictionary = m_val
		if MissionCls.is_terminal(str(m.get("status", ""))):
			continue
		if str(m.get("status", "")) == "WAITING_TRIGGER":
			continue
		for c_val in (m.get("abort_conditions", []) as Array):
			if c_val is Dictionary and _trigger_true(str((c_val as Dictionary).get("trigger", "")),
				(c_val as Dictionary).get("params", {}), obs, m):
				_set_status(m, "ABORTED", str((c_val as Dictionary).get("trigger", "")), turn)
				break
		if MissionCls.is_terminal(str(m.get("status", ""))):
			continue
		for c2_val in (m.get("success_conditions", []) as Array):
			if c2_val is Dictionary and _trigger_true(str((c2_val as Dictionary).get("trigger", "")),
				(c2_val as Dictionary).get("params", {}), obs, m):
				_set_status(m, "SUCCESS", str((c2_val as Dictionary).get("trigger", "")), turn)
				break


## Contingency pass: Godot evaluates General-defined triggers; firing a
## contingency needs no LLM round trip. Returns fired contingency ids.
func _evaluate_contingencies(obs: Dictionary, turn: int) -> Array:
	var fired: Array = []
	for c_val in (_plan.get("contingencies", []) as Array):
		if not c_val is Dictionary:
			continue
		var c: Dictionary = c_val
		if bool(c.get("consumed", false)):
			continue
		if not _trigger_true(str(c.get("trigger", "")), c.get("params", {}), obs, {}):
			continue
		c["consumed"] = true
		var action := str(c.get("action", ""))
		var mid := str(c.get("mission_id", ""))
		if action == "ACTIVATE_MISSION" and not mid.is_empty():
			var m := PlanCls.mission_by_id(_plan, mid)
			if not m.is_empty() and str(m.get("status", "")) == "WAITING_TRIGGER":
				_set_status(m, "ASSIGNED", "CONTINGENCY_%s" % str(c.get("contingency_id", "?")), turn)
				m["activated_turn"] = turn
		elif action == "ABORT_MISSION" and not mid.is_empty():
			var m2 := PlanCls.mission_by_id(_plan, mid)
			if not m2.is_empty() and not MissionCls.is_terminal(str(m2.get("status", ""))):
				_set_status(m2, "ABORTED", "CONTINGENCY_%s" % str(c.get("contingency_id", "?")), turn)
		fired.append(str(c.get("contingency_id", "?")))
		_add_event(turn, "CONTINGENCY_FIRED", {"contingency_id": str(c.get("contingency_id", "?")),
			"trigger": str(c.get("trigger", "")), "action": action, "mission_id": mid})
	return fired


## Coverage safety net: ready RED formations left unassigned by every
## live General mission are gathered into a local HOLD mission (M00) so
## no formation idles silently. General missions are never touched; M00
## membership is recomputed from live assignments every RED turn.
func _cover_unassigned(obs: Dictionary, turn: int) -> void:
	# Unalloc contract: allocation is Hand A's job. Never fold unassigned
	# formations into M00 here and never invent an allocation; just record
	# (once per plan revision) that the accepted plan waits for Hand A.
	if AuthoringCls.unalloc_mode():
		_note_hand_a_waiting(turn)
		return
	var assigned := {}
	for m_val in (_plan.get("missions", []) as Array):
		if not m_val is Dictionary:
			continue
		var m: Dictionary = m_val
		if str(m.get("mission_id", "")) == "M00" or MissionCls.is_terminal(str(m.get("status", ""))):
			continue
		for u in (m.get("assigned_units", []) as Array):
			assigned[str(u).strip_edges().to_upper()] = true
	var uncovered: Array = []
	for u_val in (obs.get("friendly_units", []) as Array):
		if not u_val is Dictionary:
			continue
		if str((u_val as Dictionary).get("status", "")) != "ready":
			continue
		var uid := str((u_val as Dictionary).get("unit_id", "")).strip_edges().to_upper()
		if not assigned.has(uid):
			uncovered.append(uid)
	uncovered.sort()
	## MISSION-LIFECYCLE handoff provenance: when a terminal (failed/aborted)
	## General mission's force lands in the M00 coverage net, record WHY on the
	## plan as a bounded, read-side fact for the next review packet / telemetry.
	## Not mission-dict fields ??validation would reject unknown keys ??and never
	## derived from anything the General writes (no spoofing surface).
	var provenance: Array = (_plan.get("fallback_provenance", []) as Array).duplicate(true)
	var prov_changed := false
	for uid in uncovered:
		var src_mid := ""
		var src_reason := ""
		var src_status := ""
		var src_task := ""
		var src_target := ""
		var src_turn := 0
		for m_val in (_plan.get("missions", []) as Array):
			if not m_val is Dictionary:
				continue
			var tm: Dictionary = m_val
			if not MissionCls.is_terminal(str(tm.get("status", ""))):
				continue
			var tids: Array = (tm.get("assigned_units", []) as Array)
			if str(uid) in tids:
				var obj: Dictionary = (tm.get("objective", {}) as Dictionary)
				src_mid = str(tm.get("mission_id", ""))
				src_reason = str(tm.get("status_reason", ""))
				src_status = str(tm.get("status", ""))
				src_task = str(tm.get("task", ""))
				src_target = str(obj.get("unit_id", obj.get("region", obj.get("zone", ""))))
				src_turn = int(tm.get("status_turn", 0))
				break
		if src_mid.is_empty():
			continue
		var known := false
		for p_val in provenance:
			if p_val is Dictionary and str((p_val as Dictionary).get("unit_id", "")) == str(uid):
				known = true
				break
		if known:
			continue
		provenance.append({"unit_id": str(uid),
			"fallback_reason": "MISSION_%s" % src_status,
			"source_mission_id": src_mid,
			"source_task": src_task,
			"source_target": src_target,
			"source_reason": src_reason,
			"source_turn": src_turn,
			"awaiting_strategic_reassignment": true})
		prov_changed = true
	if prov_changed:
		while provenance.size() > MAX_EVENTS:
			provenance.pop_front()
		_plan["fallback_provenance"] = provenance
	var cover := PlanCls.mission_by_id(_plan, "M00")
	if uncovered.is_empty():
		if not cover.is_empty() and not MissionCls.is_terminal(str(cover.get("status", ""))):
			_set_status(cover, "SUCCESS", "COVERAGE_COMPLETE", turn)
		return
	if cover.is_empty() or MissionCls.is_terminal(str(cover.get("status", ""))):
		var fresh := MissionCls.default_mission("M00", "HOLD")
		fresh["area"] = "ANY"
		fresh["status"] = "ACTIVE"
		fresh["status_reason"] = "COVERAGE_NET"
		fresh["status_turn"] = turn
		fresh["activated_turn"] = turn
		(_plan.get("missions", []) as Array).append(fresh)
		cover = PlanCls.mission_by_id(_plan, "M00")
	cover["assigned_units"] = uncovered
	if str(cover.get("status", "")) == "ASSIGNED":
		_set_status(cover, "ACTIVE", "COVERAGE_NET", turn)
	_add_event(turn, "COVERAGE_HOLD", {"units": uncovered})


func _set_status(m: Dictionary, status: String, reason: String, turn: int) -> void:
	var old := str(m.get("status", ""))
	if old == status:
		return
	m["status"] = status
	m["status_reason"] = reason
	m["status_turn"] = turn
	_add_event(turn, "MISSION_STATUS", {"mission_id": str(m.get("mission_id", "?")),
		"from": old, "to": status, "reason": reason})


func _status_row(m: Dictionary) -> Dictionary:
	return {"mission_id": str(m.get("mission_id", "?")), "task": str(m.get("task", "?")),
		"area": str(m.get("area", "?")), "status": str(m.get("status", "?")),
		"reason": str(m.get("status_reason", "")), "turn": int(m.get("status_turn", 0)),
		"units": (m.get("assigned_units", []) as Array).duplicate(true)}


func _derive_seed(sim: RefCounted, bid: String) -> int:
	if sim != null and sim.has_method("episode_seed"):
		return int(abs(int(sim.episode_seed()))) % 2147483647
	return int(abs(hash(bid))) % 2147483647


func _red_soldiers(obs: Dictionary) -> int:
	var total := 0
	for u_val in (obs.get("friendly_units", []) as Array):
		if u_val is Dictionary:
			total += int((u_val as Dictionary).get("soldiers", 0))
	return total


func _mission_soldiers(obs: Dictionary, mission_id: String) -> int:
	var m := PlanCls.mission_by_id(_plan, mission_id)
	if m.is_empty():
		return 0
	var ids := {}
	for u in (m.get("assigned_units", []) as Array):
		ids[str(u).strip_edges().to_upper()] = true
	var total := 0
	for u_val in (obs.get("friendly_units", []) as Array):
		if u_val is Dictionary and ids.has(str((u_val as Dictionary).get("unit_id", "")).strip_edges().to_upper()):
			total += int((u_val as Dictionary).get("soldiers", 0))
	return total


func _capture_baselines(obs: Dictionary) -> void:
	_battle_baseline = _red_soldiers(obs)
	_capture_missing_baselines(obs)


func _capture_missing_baselines(obs: Dictionary) -> void:
	for m_val in (_plan.get("missions", []) as Array):
		if not m_val is Dictionary:
			continue
		var mid := str((m_val as Dictionary).get("mission_id", ""))
		if not _force_baseline.has(mid):
			_force_baseline[mid] = float(_mission_soldiers(obs, mid))


func _note_seen_enemies(obs: Dictionary) -> void:
	for e_val in (obs.get("known_enemy_units", []) as Array):
		if e_val is Dictionary:
			_seen_enemies[str((e_val as Dictionary).get("unit_id", "")).strip_edges().to_upper()] = true


## Bounded factual event stream: diffs of authoritative state + mission
## transitions + passthrough of the observation's recent events. Facts
## only ??no interpretation is stored here.
func _diff_events(obs: Dictionary, turn: int) -> void:
	var own_now := {}
	for u_val in (obs.get("friendly_units", []) as Array):
		if u_val is Dictionary:
			own_now[str((u_val as Dictionary).get("unit_id", ""))] = {
				"region": str((u_val as Dictionary).get("region", "")),
				"soldiers": int((u_val as Dictionary).get("soldiers", 0)),
				"class": str((u_val as Dictionary).get("class", "")),
			}
	var own_prev: Dictionary = _prev.get(_side, _prev.get("red", {}))
	for uid in own_prev.keys():
		if not own_now.has(uid):
			_add_event(turn, "UNIT_LOST", {"side": _SIDE(), "unit_id": uid,
				"class": str((own_prev[uid] as Dictionary).get("class", "?"))})
	for uid2 in own_now.keys():
		if own_prev.has(uid2):
			var ro: String = str((own_prev[uid2] as Dictionary).get("region", ""))
			var rn: String = str((own_now[uid2] as Dictionary).get("region", ""))
			if ro != rn:
				_add_event(turn, "REGION_ENTERED", {"side": _SIDE(), "unit_id": uid2,
					"from": ro, "to": rn})
	var foe_now := {}
	for e_val in (obs.get("known_enemy_units", []) as Array):
		if e_val is Dictionary and str((e_val as Dictionary).get("contact_state", "")) == "current_visible":
			foe_now[str((e_val as Dictionary).get("unit_id", ""))] = {
				"region": str((e_val as Dictionary).get("region", "")),
				"class": str((e_val as Dictionary).get("class", "")),
			}
	var foe_prev: Dictionary = _prev.get(_foe(), _prev.get("blue", {}))
	for b2 in foe_now.keys():
		if foe_prev.has(b2):
			var bo: String = str((foe_prev[b2] as Dictionary).get("region", ""))
			var bn: String = str((foe_now[b2] as Dictionary).get("region", ""))
			if bo != bn:
				_add_event(turn, "REGION_ENTERED", {"side": _foe().to_upper(), "unit_id": b2,
					"from": bo, "to": bn})
		else:
			_add_event(turn, "CONTACT_NEW", {"side": _foe().to_upper(), "unit_id": b2,
				"region": str((foe_now[b2] as Dictionary).get("region", "")),
				"class": str((foe_now[b2] as Dictionary).get("class", "?"))})
	var hq_now := bool(OpportunityCls.hq_threatened(obs).get("threatened", false))
	if hq_now != bool(_prev.get("hq_threatened", false)):
		_add_event(turn, "HQ_THREAT", {"threatened": hq_now})
	_prev = {_side: own_now, _foe(): foe_now, "hq_threatened": hq_now}
	var recent: Array = obs.get("recent_events", [])
	for i in range(maxi(0, recent.size() - 4), recent.size()):
		if (recent[i] as Variant) is Dictionary:
			var raw: Dictionary = recent[i]
			# The authoritative combat_resolved signal owns foe->own wake events.
			# Do not duplicate the same attack as an untyped OBS_EVENT here.
			if str(raw.get("type", "")) == "battle" \
				and str(raw.get("attacker_faction", "")).to_lower() == _foe() \
				and str(raw.get("defender_faction", "")).to_lower() == _side:
				continue
			_add_event(turn, "OBS_EVENT", {"event": raw.duplicate(true)})


func _add_event(turn: int, kind: String, detail: Dictionary) -> void:
	_events.append({"turn": turn, "kind": kind, "detail": detail})
	if _events.size() > MAX_EVENTS:
		_events = _events.slice(_events.size() - MAX_EVENTS)


func _queue_wake_event(turn: int, kind: String, detail: Dictionary) -> Dictionary:
	var event_id := _next_wake_event_id
	_next_wake_event_id += 1
	var factual := detail.duplicate(true)
	factual["event_id"] = event_id
	var row := {"turn": turn, "kind": kind, "event_id": event_id, "detail": factual}
	_events.append(row)
	if _events.size() > MAX_EVENTS:
		_events = _events.slice(_events.size() - MAX_EVENTS)
	_pending_wake_events.append(row.duplicate(true))
	return row.duplicate(true)


func _mission_for_unit(unit_id: String) -> String:
	var want := unit_id.strip_edges().to_upper()
	if want.is_empty():
		return ""
	for m_val in (_plan.get("missions", []) as Array):
		if not m_val is Dictionary:
			continue
		for assigned in ((m_val as Dictionary).get("assigned_units", []) as Array):
			if str(assigned).strip_edges().to_upper() == want:
				return str((m_val as Dictionary).get("mission_id", ""))
	return ""


func _load_memory(obs: Dictionary, turn: int) -> void:
	# SELFPLAY V1: headless matches must never adopt Brain memory persisted
	# by an earlier battle (cross-match contamination). Env-only; production
	# loads as before when unset.
	if OS.get_environment("SELFPLAY_FRESH_BRAIN").strip_edges() == "1":
		return
	var loaded := MemoryCls.load_plan(_mem_id())
	if not bool(loaded.get("ok", false)):
		return
	var plan: Dictionary = loaded.get("plan", {})
	if str(plan.get("based_on_snapshot", "")) == str(obs.get("snapshot_id", "")) \
		and int(plan.get("last_review_turn", -1)) == turn:
		_plan = plan
		_events = MemoryCls.load_events(_mem_id())
		if _events.size() > MAX_EVENTS:
			_events = _events.slice(_events.size() - MAX_EVENTS)
		_add_event(turn, "MEMORY_ADOPTED", {"version": int(plan.get("plan_version", 0))})
	else:
		_add_event(turn, "MEMORY_STALE", {"version": int(plan.get("plan_version", 0)),
			"reason": "Snapshot does not match live state; Godot truth wins."})
	_vp_load_memory(obs, turn)


func _persist(obs: Dictionary, turn: int) -> void:
	var vis_count := (obs.get("known_enemy_units", []) as Array).filter(
		func(x: Variant) -> bool: return (x as Dictionary).get("contact_state", "") == "current_visible").size()
	var summary := {
		"turn": turn,
		"snapshot_id": str(obs.get("snapshot_id", "")),
		"side": _SIDE(),
		"plan_version": int(_plan.get("plan_version", 0)),
		"plan_source": str(_plan.get("source", "?")),
		"mission_statuses": _status_rows_all(),
		"telemetry": TraceCls.snapshot(),
	}
	if _side == "blue":
		summary["blue_formations"] = (obs.get("friendly_units", []) as Array).size()
		summary["red_visible"] = vis_count
	else:
		summary["red_formations"] = (obs.get("friendly_units", []) as Array).size()
		summary["blue_visible"] = vis_count
	MemoryCls.save_all(_mem_id(), (obs.get("mission", {}) as Dictionary).duplicate(true),
		_plan, (_plan.get("opponent_hypotheses", []) as Array).duplicate(true), summary, _events)
	if VictoryPlanCls.has_plan(_vp):
		MemoryCls.save_victory(_mem_id(), _vp, _vp_revisions, _vp_audit)


func _status_rows_all() -> Array:
	var out: Array = []
	for m_val in (_plan.get("missions", []) as Array):
		if m_val is Dictionary:
			out.append(_status_row(m_val))
	return out


## Live mission statuses for observability (post-execution state).
func status_rows() -> Array:
	return _status_rows_all()


## Godot-observed evidence appended to a stored hypothesis (bounded).
## Hypotheses themselves only change via General reviews.
func note_evidence(hypothesis: String, evidence: String) -> void:
	var want := hypothesis.strip_edges().to_upper()
	for h_val in (_plan.get("opponent_hypotheses", []) as Array):
		if h_val is Dictionary and str((h_val as Dictionary).get("hypothesis", "")) == want:
			var ev: Array = (h_val as Dictionary).get("evidence", [])
			ev.append(evidence.left(160))
			while ev.size() > 6:
				ev.pop_front()
			(h_val as Dictionary)["evidence"] = ev
			return


static func render_statuses(statuses: Array) -> String:
	var lines: Array = []
	for s_val in statuses:
		var s: Dictionary = s_val
		lines.append("%s %s %s [%s] %s (%s)" % [
			str(s.get("mission_id", "?")), str(s.get("task", "?")), str(s.get("area", "?")),
			str(s.get("status", "?")), ",".join(s.get("units", [])), str(s.get("reason", "-"))])
	return "\n".join(lines)


# --- VICTORY PLAN V0 (additive) --------------------------------------------
## Persistent multi-phase strategic memory. The VictoryPlan (_vp) is the
## canonical long-horizon scheme; the execution layer (_plan, StrategicPlan
## shape) is DERIVED from the active phase only via VictoryPlanCls.
## derive_execution. Every General invocation is audited (vp_audit_record)
## and every adopted revision is appended to _vp_revisions (history is
## never rewritten).

func vp_has_plan() -> bool:
	return VictoryPlanCls.has_plan(_vp)


func vp_get_plan() -> Dictionary:
	return _vp.duplicate(true)


func vp_get_revisions() -> Array:
	return _vp_revisions.duplicate(true)


func vp_get_audit() -> Array:
	return _vp_audit.duplicate(true)


func vp_audit_tail(n: int = 6) -> Array:
	if _vp_audit.is_empty():
		return []
	return _vp_audit.slice(maxi(0, _vp_audit.size() - n)).duplicate(true)


func vp_last_call() -> Dictionary:
	if _vp_audit.is_empty():
		return {}
	return (_vp_audit[_vp_audit.size() - 1] as Dictionary).duplicate(true)


func vp_last_revision() -> Dictionary:
	if _vp_revisions.is_empty():
		return {}
	return (_vp_revisions[_vp_revisions.size() - 1] as Dictionary).get("meta", {})


func vp_active_phase() -> Dictionary:
	return VictoryPlanCls.active_phase(_vp)


func vp_revision_tail(n: int = 6) -> Array:
	var out: Array = []
	for r_val in _vp_revisions.slice(maxi(0, _vp_revisions.size() - n)):
		if r_val is Dictionary:
			var m: Dictionary = (r_val as Dictionary).get("meta", {})
			out.append({"revision": int(m.get("revision", 0)), "turn": int(m.get("turn", 0)),
				"decision": str(m.get("decision", "?")), "trigger": str(m.get("trigger", "?")),
				"reason": str(m.get("reason", ""))})
	return out


func vp_next_call_id() -> String:
	_vp_call_seq += 1
	return "VP_C%03d" % _vp_call_seq


func vp_note_initial_snapshot(snapshot_id: String) -> void:
	_vp_initial_snapshot = snapshot_id.strip_edges()


func vp_get_initial_snapshot() -> String:
	return _vp_initial_snapshot


func _vp_next_lineage_id() -> String:
	_vp_lineage_seq += 1
	return "VL%d" % _vp_lineage_seq


## Adopt a validated VICTORY_INITIAL body as VictoryPlan v1. Godot assigns
## identity (victory_plan_id / lineage / revision); the first phase becomes
## ACTIVE. Any legacy execution plan is superseded by derivation.
func vp_apply_initial(validated: Dictionary, turn: int, snapshot: String, battle_id: String, source: String) -> Dictionary:
	if not battle_id.strip_edges().is_empty():
		_battle_id = battle_id.strip_edges()
		_memory_loaded = true
	var vp: Dictionary = (validated as Dictionary).duplicate(true)
	vp["victory_plan_id"] = "VP_%s_T%d" % [_safe_battle_tag(_battle_id), turn]
	vp["lineage_id"] = _vp_next_lineage_id()
	vp["revision"] = 1
	vp["parent_revision"] = 0
	vp["created_turn"] = turn
	vp["last_revised_turn"] = turn
	vp["last_review_turn"] = turn
	vp["source"] = source.strip_edges().left(32) if not source.strip_edges().is_empty() else "general"
	var first := true
	for p_val in (vp.get("phases", []) as Array):
		if not p_val is Dictionary:
			continue
		var ph: Dictionary = p_val
		if first:
			ph["status"] = "ACTIVE"
			ph["status_turn"] = turn
			ph["status_reason"] = "INITIAL_PLAN"
			vp["current_phase_id"] = str(ph.get("phase_id", ""))
			first = false
		else:
			ph["status"] = "PLANNED"
			ph["status_turn"] = 0
			ph["status_reason"] = ""
		for m_val in (ph.get("missions", []) as Array):
			if m_val is Dictionary:
				(m_val as Dictionary)["activated_turn"] = turn
	_vp = vp
	_vp_reserve_released = {}
	var mission: Dictionary = (_plan.get("mission", {}) as Dictionary).duplicate(true)
	_plan = VictoryPlanCls.derive_execution(_vp, {}, mission, turn, snapshot)
	_force_baseline = {}
	_capture_baselines_for_vp(turn)
	_vp_revisions.append({"meta": VictoryPlanCls.revision_record(0, 1, turn, "INITIAL_PLAN",
		"VictoryPlan created.", "INITIAL", {"changed": ["plan created with %d phase(s)" % (_vp.get("phases", []) as Array).size()],
		"unchanged": [], "mission_changes": []}, "", str(_vp.get("current_phase_id", ""))),
		"plan": _vp.duplicate(true)})
	_add_event(turn, "VP_APPLIED", {"revision": 1, "phases": (_vp.get("phases", []) as Array).size(),
		"active": str(_vp.get("current_phase_id", "")), "source": str(_vp.get("source", "general"))})
	_note_hand_a_waiting(turn)
	return {"ok": true, "code": "", "detail": "", "revision": 1, "phase": str(_vp.get("current_phase_id", ""))}


## Wrap a legacy execution plan as a single-phase VictoryPlan (migration:
## victory mode enabled mid-battle, or a plan predates the VP layer).
func vp_adopt_legacy(turn: int, reason: String) -> Dictionary:
	if VictoryPlanCls.has_plan(_vp):
		return {"ok": false, "code": "VP_EXISTS", "detail": "A VictoryPlan is already bound.", "revision": 0}
	if not PlanCls.has_plan(_plan):
		return {"ok": false, "code": "VP_NO_LEGACY", "detail": "No legacy plan to adopt.", "revision": 0}
	var concept: Dictionary = _plan.get("concept", {})
	var missions: Array = []
	for m_val in (_plan.get("missions", []) as Array):
		if m_val is Dictionary:
			missions.append((m_val as Dictionary).duplicate(true))
	var body := {
		"final_objective": str(concept.get("objective", "WIN THE BATTLE (inherited posture).")),
		"desired_end_state": "Inherited from legacy operational plan.",
		"doctrine": (_plan.get("doctrine", {}) as Dictionary).duplicate(true),
		"review_horizon_turns": int(_plan.get("review_horizon_turns", 4)),
		"phases": [{
			"phase_id": "P1", "name": "INHERITED POSTURE",
			"purpose": "Carry the pre-VictoryPlan operational posture as phase one.",
			"missions": missions, "commander_intent": str(concept.get("intent", "")),
		}],
		"source": "legacy_adopted",
	}
	var checked := VictoryPlanCls.validate_plan(body, {"turn": turn})
	if not bool(checked.get("ok", false)):
		return {"ok": false, "code": str(checked.get("code", "VP_INVALID")), "detail": str(checked.get("detail", "")), "revision": 0}
	var res := vp_apply_initial(checked.get("plan", {}), turn, str(_plan.get("based_on_snapshot", "")), _battle_id, "legacy_adopted")
	if bool(res.get("ok", false)):
		_add_event(turn, "VP_LEGACY_ADOPTED", {"reason": reason.left(160)})
	return res


func _safe_battle_tag(bid: String) -> String:
	var out := ""
	for i in range(bid.length()):
		var c := bid[i]
		if (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or (c >= "0" and c <= "9"):
			out += c.to_upper()
	if out.is_empty():
		out = "BATTLE"
	return out.left(12)


func _capture_baselines_for_vp(_turn: int) -> void:
	# Force baselines key on mission_id; derived missions keep their ids,
	# so the standard capture (called from red_turn) applies unchanged.
	pass


## Compute a parsed VICTORY_REVIEW decision WITHOUT mutating state, so
## background reviews can validate + stage before the staleness gate.
## parsed: Cloud2VictoryResponse.parse_review "review" dict. obs is used
## for ADVANCE disposition (evaluated success/failure). Returns {ok, code,
## detail, action, new_vp (ADVANCE/AMEND/EMERGENCY), meta}.
func vp_compute_review(parsed: Dictionary, obs: Dictionary, turn: int) -> Dictionary:
	if not VictoryPlanCls.has_plan(_vp):
		return {"ok": false, "code": "VP_NO_PLAN", "detail": "No VictoryPlan under review.", "action": ""}
	var decision := str(parsed.get("decision", ""))
	var reason := str(parsed.get("reason", ""))
	if decision == "KEEP":
		return {"ok": true, "code": "", "detail": "", "action": "KEEP",
			"meta": {"decision": "KEEP", "reason": reason,
				"hypotheses": (parsed.get("hypotheses", []) as Array).duplicate(true),
				"has_hypotheses": bool(parsed.get("has_hypotheses", false))}}
	if decision == "ADVANCE_PHASE":
		return _vp_compute_advance(parsed, obs, turn)
	if decision == "AMEND_PLAN":
		var amended := VictoryPlanCls.amend_phases(_vp, parsed.get("phases", []), turn, reason)
		if not bool(amended.get("ok", false)):
			return {"ok": false, "code": str(amended.get("code", "VP_AMEND")), "detail": str(amended.get("detail", "")), "action": ""}
		var new_vp: Dictionary = amended.get("plan", {})
		if bool(parsed.get("has_hypotheses", false)):
			new_vp["opponent_hypotheses"] = (parsed.get("hypotheses", []) as Array).duplicate(true)
		return {"ok": true, "code": "", "detail": "", "action": "AMEND",
			"new_vp": new_vp, "meta": {"decision": "AMEND_PLAN", "reason": reason}}
	if decision == "EMERGENCY_REPLAN":
		var body: Dictionary = parsed.get("plan_body", {})
		if body.is_empty():
			return {"ok": false, "code": "VP_BODY", "detail": "EMERGENCY_REPLAN needs a full plan body.", "action": ""}
		var replanned := VictoryPlanCls.emergency_replan(_vp, body, _vp_next_lineage_id(), turn, reason)
		if not bool(replanned.get("ok", false)):
			_vp_lineage_seq -= 1
			return {"ok": false, "code": str(replanned.get("code", "VP_REPLAN")), "detail": str(replanned.get("detail", "")), "action": ""}
		return {"ok": true, "code": "", "detail": "", "action": "EMERGENCY",
			"new_vp": replanned.get("plan", {}), "meta": {"decision": "EMERGENCY_REPLAN", "reason": reason}}
	return {"ok": false, "code": "VP_DECISION", "detail": "Unknown decision '%s'." % decision, "action": ""}


func _vp_compute_advance(parsed: Dictionary, obs: Dictionary, turn: int) -> Dictionary:
	var cur := VictoryPlanCls.active_phase(_vp)
	if cur.is_empty():
		return {"ok": false, "code": "VP_NO_ACTIVE", "detail": "No active phase to advance from.", "action": ""}
	var reason := str(parsed.get("reason", ""))
	var succ_hit := _vp_first_true(cur.get("success_conditions", []), obs, {})
	var fail_hit := _vp_first_true(cur.get("failure_conditions", []), obs, {})
	var tr: Dictionary = cur.get("transition", {})
	var disp := "COMPLETED"
	var gate_action := ""
	if not succ_hit.is_empty():
		gate_action = str((tr.get("on_success", {}) as Dictionary).get("action", "ADVANCE"))
		if gate_action == "HOLD_FOR_REVIEW":
			return {"ok": false, "code": "VP_HOLD", "detail": "Phase %s transition holds for review on success; amend instead." % str(cur.get("phase_id", "?")), "action": ""}
	elif not fail_hit.is_empty():
		disp = "FAILED"
		gate_action = str((tr.get("on_failure", {}) as Dictionary).get("action", "HOLD_FOR_REVIEW"))
		if gate_action != "ADVANCE_ANYWAY":
			return {"ok": false, "code": "VP_HOLD", "detail": "Phase %s failure transition is %s; amend or replan instead." % [str(cur.get("phase_id", "?")), gate_action], "action": ""}
	# else: no evaluated condition fired ??General override, audited below.
	var adv := VictoryPlanCls.advance_phase(_vp, str(parsed.get("next_phase_id", "")), disp, turn,
		reason if not reason.is_empty() else ("SUCCESS_%s" % succ_hit if not succ_hit.is_empty() else ("FAILURE_%s" % fail_hit if not fail_hit.is_empty() else "GENERAL_OVERRIDE")))
	if not bool(adv.get("ok", false)):
		return {"ok": false, "code": str(adv.get("code", "VP_ADVANCE")), "detail": str(adv.get("detail", "")), "action": ""}
	var new_vp: Dictionary = adv.get("plan", {})
	if bool(parsed.get("has_hypotheses", false)):
		new_vp["opponent_hypotheses"] = (parsed.get("hypotheses", []) as Array).duplicate(true)
	return {"ok": true, "code": "", "detail": "", "action": "ADVANCE", "new_vp": new_vp,
		"meta": {"decision": "ADVANCE_PHASE", "reason": reason, "from_phase": str(adv.get("from_phase", "")),
			"to_phase": str(adv.get("to_phase", "")), "disposition": disp,
			"success_hit": succ_hit, "failure_hit": fail_hit,
			"override": succ_hit.is_empty() and fail_hit.is_empty()}}


func _vp_first_true(conds: Array, obs: Dictionary, mission: Dictionary) -> String:
	for c_val in conds:
		if c_val is Dictionary and _trigger_true(str((c_val as Dictionary).get("trigger", "")),
				(c_val as Dictionary).get("params", {}), obs, mission):
			return str((c_val as Dictionary).get("trigger", "?"))
	return ""


## Commit a computed review: KEEP advances the review clock; ADVANCE /
## AMEND / EMERGENCY adopt the new revision, append history, re-derive
## the execution layer, and record the semantic diff. Returns {ok, code,
## detail, revision, decision, diff, phase}.
func vp_commit_review(computed: Dictionary, mission_contract: Dictionary, turn: int, snapshot: String, trigger: String) -> Dictionary:
	if not bool(computed.get("ok", false)):
		return {"ok": false, "code": str(computed.get("code", "VP_COMPUTE")), "detail": str(computed.get("detail", "")), "revision": 0}
	var action := str(computed.get("action", ""))
	var meta: Dictionary = computed.get("meta", {})
	if action == "KEEP":
		_vp["last_review_turn"] = turn
		if bool(meta.get("has_hypotheses", false)):
			_plan["opponent_hypotheses"] = (meta.get("hypotheses", []) as Array).duplicate(true)
			_vp["opponent_hypotheses"] = (meta.get("hypotheses", []) as Array).duplicate(true)
		_add_event(turn, "VP_REVIEWED", {"revision": int(_vp.get("revision", 0)), "decision": "KEEP", "trigger": trigger})
		return {"ok": true, "code": "", "detail": "", "revision": int(_vp.get("revision", 0)),
			"decision": "KEEP", "diff": {"changed": [], "unchanged": ["entire plan (KEEP)"], "mission_changes": []},
			"phase": str(_vp.get("current_phase_id", ""))}
	var new_vp: Dictionary = computed.get("new_vp", {})
	var diff := VictoryPlanCls.semantic_diff(_vp, new_vp)
	var phase_before := str(_vp.get("current_phase_id", ""))
	_vp = new_vp
	_plan = VictoryPlanCls.derive_execution(_vp, _plan, mission_contract, turn, snapshot)
	_force_baseline = {}
	_vp_revisions.append({"meta": VictoryPlanCls.revision_record(int(_vp.get("parent_revision", 0)),
		int(_vp.get("revision", 0)), turn, trigger, str(meta.get("reason", "")), str(meta.get("decision", action)),
		diff, phase_before, str(_vp.get("current_phase_id", ""))), "plan": _vp.duplicate(true)})
	if _vp_revisions.size() > VictoryPlanCls.MAX_REVISIONS:
		_vp_revisions = _vp_revisions.slice(_vp_revisions.size() - VictoryPlanCls.MAX_REVISIONS)
	_add_event(turn, "VP_REVISION", {"revision": int(_vp.get("revision", 0)), "decision": str(meta.get("decision", action)),
		"trigger": trigger, "phase": str(_vp.get("current_phase_id", "")), "changed": (diff.get("changed", []) as Array).size()})
	return {"ok": true, "code": "", "detail": "", "revision": int(_vp.get("revision", 0)),
		"decision": str(meta.get("decision", action)), "diff": diff, "phase": str(_vp.get("current_phase_id", ""))}


## Adopt a staged background revision at the RED phase boundary. The staged
## parent must still match the live revision (a concurrent blocking review
## invalidates the stage ??it is discarded, never force-applied).
func vp_adopt_staged(staged: Dictionary, meta: Dictionary, mission_contract: Dictionary, turn: int, snapshot: String, trigger: String) -> Dictionary:
	if not VictoryPlanCls.has_plan(_vp):
		return {"ok": false, "code": "VP_NO_PLAN", "detail": "No live VictoryPlan; staged revision discarded.", "revision": 0}
	var checked := VictoryPlanCls.validate_plan(staged.get("new_vp", {}), {"turn": turn, "snapshot_id": snapshot})
	if not bool(checked.get("ok", false)):
		return {"ok": false, "code": str(checked.get("code", "VP_STAGED")), "detail": "Staged plan failed revalidation: " + str(checked.get("detail", "")), "revision": 0}
	if int((checked.get("plan", {}) as Dictionary).get("parent_revision", -1)) != int(_vp.get("revision", -2)):
		return {"ok": false, "code": "VP_STALE_PARENT",
			"detail": "Staged parent v%d != live v%d; discarded." % [int((checked.get("plan", {}) as Dictionary).get("parent_revision", -1)), int(_vp.get("revision", -2))], "revision": 0}
	return vp_commit_review({"ok": true, "action": str(meta.get("action", "AMEND")),
		"new_vp": checked.get("plan", {}), "meta": meta}, mission_contract, turn, snapshot, trigger)


## Active-phase progress for review packets and the dev panel: live mission
## rows plus every phase/plan condition WITH its evaluated truth value.
func vp_phase_progress(obs: Dictionary) -> Dictionary:
	var cur := VictoryPlanCls.active_phase(_vp)
	if cur.is_empty():
		return {}
	var turn := int(obs.get("turn", 0))
	var missions: Array = []
	for m_val in (_plan.get("missions", []) as Array):
		if m_val is Dictionary:
			var m: Dictionary = m_val
			missions.append({"mission_id": str(m.get("mission_id", "?")), "task": str(m.get("task", "?")),
				"area": str(m.get("area", "?")), "status": str(m.get("status", "?")),
				"status_reason": str(m.get("status_reason", "")),
				"units": (m.get("assigned_units", []) as Array).duplicate(true)})
	var cond_state := func(conds: Array) -> Array:
		var rows: Array = []
		for c_val in conds:
			if c_val is Dictionary:
				rows.append({"trigger": str((c_val as Dictionary).get("trigger", "?")),
					"params": ((c_val as Dictionary).get("params", {}) as Dictionary).duplicate(true),
					"satisfied": _trigger_true(str((c_val as Dictionary).get("trigger", "")),
						(c_val as Dictionary).get("params", {}), obs, {})})
		return rows
	var branches: Array = []
	for b_val in (_vp.get("branches", []) as Array):
		if b_val is Dictionary:
			var b: Dictionary = b_val
			var bc: Dictionary = b.get("condition", {})
			branches.append({"branch_id": str(b.get("branch_id", "?")), "status": str(b.get("status", "?")),
				"satisfied": _trigger_true(str(bc.get("trigger", "NEVER")), bc.get("params", {}), obs, {})})
	var rp: Dictionary = cur.get("reserve_policy", {})
	return {
		"phase": cur.duplicate(true),
		"turns_active": turn - int(cur.get("status_turn", turn)),
		"missions": missions,
		"entry": cond_state.call(cur.get("entry_conditions", [])),
		"success": cond_state.call(cur.get("success_conditions", [])),
		"failure": cond_state.call(cur.get("failure_conditions", [])),
		"abort": cond_state.call(cur.get("abort_conditions", [])),
		"plan_abort": cond_state.call(_vp.get("plan_abort_conditions", [])),
		"branches": branches,
		"reserve": {"hold": (rp.get("hold", []) as Array).duplicate(true),
			"released_turn": int(_vp_reserve_released.get(str(cur.get("phase_id", "")), 0))},
	}


## VP transition/abort review policy (checked before legacy mission checks
## when a VictoryPlan is bound). Conditions propose reviews; they never
## mutate the plan ??the General decides.
func vp_transition_review(obs: Dictionary, turn: int) -> Dictionary:
	var cur := VictoryPlanCls.active_phase(_vp)
	if cur.is_empty():
		return {"requested": false, "trigger": "", "reason": ""}
	var pid := str(cur.get("phase_id", "?"))
	var pname := str(cur.get("name", ""))
	var hit := _vp_first_true(_vp.get("plan_abort_conditions", []), obs, {})
	if not hit.is_empty():
		return {"requested": true, "trigger": "VICTORY_ABORT",
			"reason": "Plan abort condition %s fired; strategic concept may be unviable." % hit}
	var ahit := _vp_first_true(cur.get("abort_conditions", []), obs, {})
	if not ahit.is_empty():
		return {"requested": true, "trigger": "PHASE_ABORT",
			"reason": "%s %s abort condition %s fired." % [pid, pname, ahit]}
	var fhit := _vp_first_true(cur.get("failure_conditions", []), obs, {})
	if not fhit.is_empty():
		return {"requested": true, "trigger": "PHASE_FAILED",
			"reason": "%s %s failure condition %s fired." % [pid, pname, fhit]}
	var shit := _vp_first_true(cur.get("success_conditions", []), obs, {})
	if not shit.is_empty():
		return {"requested": true, "trigger": "PHASE_SUCCESS",
			"reason": "%s %s success condition %s satisfied." % [pid, pname, shit]}
	for e_val in _events:
		if e_val is Dictionary and int((e_val as Dictionary).get("turn", -1)) == turn:
			var kind := str((e_val as Dictionary).get("kind", ""))
			if kind == "VP_BRANCH_FIRED":
				var d: Dictionary = (e_val as Dictionary).get("detail", {})
				return {"requested": true, "trigger": "BRANCH_CONDITION",
					"reason": "Branch %s fired (%s); contingency response needed." % [str(d.get("branch_id", "?")), str(d.get("if_text", ""))]}
			if kind == "VP_RESERVE_DUE":
				return {"requested": true, "trigger": "RESERVE_RELEASE",
					"reason": "Reserve release condition fired for %s; release decision needed." % pid}
	return {"requested": false, "trigger": "", "reason": ""}


## Branch pass: ARMED branches whose condition holds become TRIGGERED
## (once ??TRIGGERED branches never refire) and log a factual event that
## vp_transition_review turns into a BRANCH_CONDITION review.
func _vp_evaluate_branches(obs: Dictionary, turn: int) -> void:
	for b_val in (_vp.get("branches", []) as Array):
		if not b_val is Dictionary:
			continue
		var b: Dictionary = b_val
		if str(b.get("status", "")) != "ARMED":
			continue
		var bc: Dictionary = b.get("condition", {})
		if _trigger_true(str(bc.get("trigger", "NEVER")), bc.get("params", {}), obs, {}):
			b["status"] = "TRIGGERED"
			_add_event(turn, "VP_BRANCH_FIRED", {"branch_id": str(b.get("branch_id", "?")),
				"if_text": str(b.get("if_text", "")).left(160),
				"then": str((b.get("then", {}) as Dictionary).get("action", "?"))})


## Reserve pass: when the active phase release_when fires (once per phase),
## log VP_RESERVE_DUE so the General review decides the actual release.
func _vp_evaluate_reserve(obs: Dictionary, turn: int) -> void:
	var cur := VictoryPlanCls.active_phase(_vp)
	if cur.is_empty():
		return
	var pid := str(cur.get("phase_id", ""))
	if int(_vp_reserve_released.get(pid, 0)) > 0:
		return
	var rp: Dictionary = cur.get("reserve_policy", {})
	if ((rp.get("hold", []) as Array).is_empty() and ((rp.get("release_when", []) as Array).is_empty())):
		return
	if not _vp_first_true(rp.get("release_when", []), obs, {}).is_empty():
		_vp_reserve_released[pid] = turn
		_add_event(turn, "VP_RESERVE_DUE", {"phase_id": pid,
			"hold": (rp.get("hold", []) as Array).duplicate(true)})


## Mirror live execution statuses back into the stored active-phase
## missions, so the VictoryPlan (packets, panel, history) reflects the
## missions the controllers actually ran ??not stale ASSIGNED copies.
func _vp_mirror_execution() -> void:
	var cur := VictoryPlanCls.active_phase(_vp)
	if cur.is_empty():
		return
	var live := {}
	for m_val in (_plan.get("missions", []) as Array):
		if m_val is Dictionary:
			live[str((m_val as Dictionary).get("mission_id", ""))] = m_val
	for sm_val in (cur.get("missions", []) as Array):
		if not sm_val is Dictionary:
			continue
		var sm: Dictionary = sm_val
		var lm: Dictionary = live.get(str(sm.get("mission_id", "")), {})
		if lm.is_empty():
			continue
		sm["status"] = str(lm.get("status", "ASSIGNED"))
		sm["status_reason"] = str(lm.get("status_reason", ""))
		sm["status_turn"] = int(lm.get("status_turn", 0))
		sm["progress_turn"] = int(lm.get("progress_turn", 0))


## Append one General-invocation audit row (append-only, battle-local).
## row: {call_id, turn, battle_id, snapshot_id, backend, trigger, why,
## request_type, latency_ms, http_status, provider_outcome, decision,
## outcome, revision_before/after, phase_before/after, validation {ok,
## code, detail}, change_summary [], mission_changes [], laya_notified}.
## No secrets are ever stored (backend names provider/model only).
func vp_audit_record(row: Dictionary) -> void:
	var r := {
		"call_id": str(row.get("call_id", vp_next_call_id())),
		"turn": int(row.get("turn", 0)),
		"side": str(row.get("side", _SIDE())),
		"battle_id": str(row.get("battle_id", _battle_id)),
		"snapshot_id": str(row.get("snapshot_id", "")).left(64),
		"backend": str(row.get("backend", "?")).left(96),
		"trigger": str(row.get("trigger", "?")),
		"why": str(row.get("why", "")).left(280),
		"request_type": str(row.get("request_type", "?")),
		"latency_ms": int(row.get("latency_ms", 0)),
		"http_status": str(row.get("http_status", "?")),
		"finish_reason": str(row.get("finish_reason", "")),
		"final_chars": int(row.get("final_chars", 0)),
		"reasoning_present": bool(row.get("reasoning_present", false)),
		"reasoning_chars": int(row.get("reasoning_chars", 0)),
		"usage": (row.get("usage", {}) as Dictionary).duplicate(true),
		"output_budget": int(row.get("output_budget", 0)),
		"retry_of": str(row.get("retry_of", "")),
		"contract": str(row.get("contract", "")),
		"prefetch": bool(row.get("prefetch", false)),
		"provider_outcome": str(row.get("provider_outcome", "?")).left(160),
		"provider_message": str(row.get("provider_message", "")).left(280),
		"decision": str(row.get("decision", "-")),
		"outcome": str(row.get("outcome", "?")),
		"revision_before": int(row.get("revision_before", 0)),
		"revision_after": int(row.get("revision_after", 0)),
		"phase_before": str(row.get("phase_before", "-")),
		"phase_after": str(row.get("phase_after", "-")),
		"validation": {
			"ok": bool((row.get("validation", {}) as Dictionary).get("ok", false)),
			"code": str((row.get("validation", {}) as Dictionary).get("code", "")),
			"detail": str((row.get("validation", {}) as Dictionary).get("detail", "")).left(280),
		},
		"change_summary": (row.get("change_summary", []) as Array).duplicate(true),
		"mission_changes": (row.get("mission_changes", []) as Array).duplicate(true),
		"laya_notified": bool(row.get("laya_notified", false)),
	}
	_vp_audit.append(r)
	if _vp_audit.size() > VictoryPlanCls.MAX_AUDIT:
		_vp_audit = _vp_audit.slice(_vp_audit.size() - VictoryPlanCls.MAX_AUDIT)


## Patch one audit row by call_id (staged adoption, Laya notification).
func vp_audit_update(call_id: String, patch: Dictionary) -> void:
	for r_val in _vp_audit:
		if r_val is Dictionary and str((r_val as Dictionary).get("call_id", "")) == call_id:
			var r: Dictionary = r_val
			for k in patch.keys():
				if r.has(k):
					r[k] = patch[k]
			return


## Mark audit rows at/before a Laya-served revision as received by Hands.
func vp_note_laya_context(revision: int) -> void:
	for r_val in _vp_audit:
		if r_val is Dictionary and int((r_val as Dictionary).get("revision_after", 0)) <= revision:
			(r_val as Dictionary)["laya_notified"] = true


## Victory review packet for the current situation + trigger.
func build_victory_review_packet(obs: Dictionary, trigger: Dictionary) -> Dictionary:
	var progress := vp_phase_progress(obs)
	var statuses: Array = (progress.get("missions", []) as Array).duplicate(true)
	var hyps: Array = (_plan.get("opponent_hypotheses", []) as Array).duplicate(true)
	var since: Array = []
	var last_rev := int(_vp.get("last_review_turn", 0))
	for e_val in _events:
		if e_val is Dictionary and int((e_val as Dictionary).get("turn", 0)) >= last_rev:
			since.append(e_val)
		if since.size() >= MAX_EVENTS_PER_PACKET:
			break
	return PacketCls.build_victory_review(obs, _vp, progress, statuses, hyps, since, trigger, vp_revision_tail(4), _side)


func _vp_load_memory(obs: Dictionary, turn: int) -> void:
	if VictoryPlanCls.has_plan(_vp):
		return
	# SELFPLAY V1: see _load_memory (defense in depth for direct callers).
	if OS.get_environment("SELFPLAY_FRESH_BRAIN").strip_edges() == "1":
		return
	var loaded := MemoryCls.load_victory(_mem_id())
	if not bool(loaded.get("ok", false)):
		return
	var vp: Dictionary = loaded.get("vp", {})
	var phases_ok := true
	if str(vp.get("victory_plan_id", "")).is_empty():
		phases_ok = false
	# Same authority rule as StrategicPlan memory: adopt only when the
	# stored review clock matches the live turn; otherwise Godot truth wins
	# and the next RED turn requests a fresh review.
	if phases_ok and int(vp.get("last_review_turn", -1)) == turn:
		_vp = vp
		_vp_revisions = loaded.get("revisions", [])
		_vp_audit = loaded.get("audit", [])
		_vp_call_seq = _vp_audit.size()
		_add_event(turn, "VP_MEMORY_ADOPTED", {"revision": int(vp.get("revision", 0))})
	else:
		_add_event(turn, "VP_MEMORY_STALE", {"revision": int(vp.get("revision", 0)),
			"reason": "Stored review clock does not match live turn; Godot truth wins."})


# ------------------------------------------------------------------
# HAND A SEAM (Brain→Hand A contract, frozen v1). Hand A is NOT
# implemented: this is the single read point where it will take the
# accepted UNALLOCATED missions of the active phase and return an
# allocation. Nothing here assigns units.
# ------------------------------------------------------------------

## Pending allocation request for Hand A. state:
##   LEGACY_V1        contract mode off (Brain allocates; seam unused)
##   NO_PLAN          no VictoryPlan adopted yet
##   AWAITING_HAND_A  plan accepted, active-phase missions carry no units
##   ALLOCATED        active-phase missions already carry units
func hand_a_pending_allocation() -> Dictionary:
	if not AuthoringCls.unalloc_mode():
		return {"state": "LEGACY_V1", "missions": []}
	if not VictoryPlanCls.has_plan(_vp):
		return {"state": "NO_PLAN", "missions": []}
	var ph := VictoryPlanCls.active_phase(_vp)
	var missions: Array = []
	var any_units := false
	for m_val in (ph.get("missions", []) as Array):
		if not m_val is Dictionary:
			continue
		var m: Dictionary = m_val
		if not (m.get("assigned_units", []) as Array).is_empty():
			any_units = true
		var tp: Dictionary = m.get("target_preferences", {}) as Dictionary if m.get("target_preferences") is Dictionary else {}
		missions.append({
			"mission_id": str(m.get("mission_id", "")),
			"task": str(m.get("task", "")),
			"area": str(m.get("area", "")),
			"area_frame": "RELATIVE_TO_OWN_HQ",
			"intent": str(m.get("intent", "")),
			"priority": str(m.get("priority", "")),
			"objective": (m.get("objective", {}) as Dictionary).duplicate(true),
			"engagement": (m.get("engagement", {}) as Dictionary).duplicate(true),
			"constraints": (m.get("constraints", {}) as Dictionary).duplicate(true),
			"limits": (m.get("constraints_nl", []) as Array).duplicate(),
			"effects": (m.get("desired_effects", []) as Array).duplicate(),
			"prefer": {"classes": (tp.get("classes", []) as Array).duplicate(), "areas": (tp.get("areas", []) as Array).duplicate()},
			"success_conditions": (m.get("success_conditions", []) as Array).duplicate(true),
			"abort_conditions": (m.get("abort_conditions", []) as Array).duplicate(true),
		})
	return {
		"state": "ALLOCATED" if any_units else HAND_A_AWAITING,
		"contract": AuthoringCls.CONTRACT_UNALLOC,
		"plan_revision": int(_vp.get("revision", 0)),
		"phase_id": str(ph.get("phase_id", "")),
		"phase_intent": str(ph.get("commander_intent", "")),
		"objective": str(_vp.get("final_objective", "")),
		"missions": missions,
	}


var _hand_a_noted_rev := -1


func _note_hand_a_waiting(turn: int) -> void:
	var req := hand_a_pending_allocation()
	if str(req.get("state", "")) != HAND_A_AWAITING:
		return
	var rev := int(req.get("plan_revision", 0))
	if rev == _hand_a_noted_rev:
		return
	_hand_a_noted_rev = rev
	var ids: Array = []
	for m in (req.get("missions", []) as Array):
		ids.append("%s:%s/%s" % [str(m.get("mission_id", "")), str(m.get("task", "")), str(m.get("area", ""))])
	_add_event(turn, "HAND_A_AWAITING_ALLOCATION", {"revision": rev, "phase": str(req.get("phase_id", "")), "missions": ids})
	print("[HandA] PLAN_ACCEPTED_UNALLOCATED rev=%d phase=%s missions=%s -> AWAITING_HAND_A (no units assigned; Hand A not connected)" % [
		rev, str(req.get("phase_id", "")), ",".join(ids)])
