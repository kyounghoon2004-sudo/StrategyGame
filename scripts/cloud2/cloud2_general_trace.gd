class_name Cloud2GeneralTrace
extends RefCounted

## CLOUD-GENERAL MISSION HIERARCHY — General telemetry (passive store).
##
## Records what the hierarchy decided/did; never consulted for any
## decision. Tracks the benchmark that justifies this architecture:
## General calls per battle, turns executed with zero network, controller
## decisions, replan triggers, and staged/stale plan dispositions.
##
## Static process-lifetime state (same pattern as Cloud2TurnTrace): the
## panel reads snapshots; the mission manager writes events.

static var _general_calls := 0
static var _general_latency_ms: Array = []
static var _turns_without_llm := 0
static var _turns_with_llm := 0
static var _controller_decisions := 0
static var _replan_triggers := {}
static var _plans_applied := 0
static var _plans_staged := 0
static var _plans_stale := 0
static var _plans_kept := 0
static var _plans_rejected := 0
static var _last_review := {}
static var _revision := 0
## VICTORY PLAN V0 (additive): strategic-scale call counters.
static var _vp_calls := 0
static var _vp_decisions := {}
static var _vp_transitions := 0
static var _vp_last := {}
## SYMMETRIC V1 (additive): per-side completed-phase counters.
static var _red_turns := 0
static var _blue_turns := 0


static func reset() -> void:
	_general_calls = 0
	_general_latency_ms = []
	_turns_without_llm = 0
	_turns_with_llm = 0
	_controller_decisions = 0
	_replan_triggers = {}
	_plans_applied = 0
	_plans_staged = 0
	_plans_stale = 0
	_plans_kept = 0
	_plans_rejected = 0
	_last_review = {}
	_revision = 0
	_vp_calls = 0
	_vp_decisions = {}
	_vp_transitions = 0
	_vp_last = {}
	_red_turns = 0
	_blue_turns = 0


static func note_general_call(latency_ms: int, trigger: String, turn: int) -> void:
	_general_calls += 1
	_general_latency_ms.append(maxi(0, latency_ms))
	if _general_latency_ms.size() > 64:
		_general_latency_ms = _general_latency_ms.slice(_general_latency_ms.size() - 64)
	_replan_triggers[trigger] = int(_replan_triggers.get(trigger, 0)) + 1
	_last_review = {"turn": turn, "trigger": trigger, "latency_ms": latency_ms,
		"disposition": "PENDING", "plan_version": 0, "snapshot": "", "code": ""}
	_revision += 1


static func note_general_disposition(disposition: String, plan_version: int = 0, snapshot: String = "", code: String = "") -> void:
	_last_review["disposition"] = disposition
	_last_review["plan_version"] = plan_version
	_last_review["snapshot"] = snapshot
	_last_review["code"] = code
	match disposition:
		"APPLIED":
			_plans_applied += 1
		"STAGED":
			_plans_staged += 1
		"KEPT":
			_plans_kept += 1
		"STALE":
			_plans_stale += 1
		"REJECTED":
			_plans_rejected += 1
	_revision += 1


## Counts COMPLETED RED phases only (skipped/failed phases are not
## turns executed; their General calls still count under general_calls).
static func note_red_turn(used_llm: bool, decisions: int) -> void:
	note_side_turn("red", used_llm, decisions)


## SYMMETRIC V1: side-parameterized turn counter. Both sides share this
## telemetry; per-side counts stay visible in the snapshot.
static func note_side_turn(side: String, used_llm: bool, decisions: int) -> void:
	if used_llm:
		_turns_with_llm += 1
	else:
		_turns_without_llm += 1
	_controller_decisions += decisions
	var s := side.strip_edges().to_lower()
	if s == "blue":
		_blue_turns += 1
	else:
		_red_turns += 1
	_revision += 1


static func average_latency_ms() -> int:
	if _general_latency_ms.is_empty():
		return 0
	var total := 0
	for v in _general_latency_ms:
		total += int(v)
	return total / _general_latency_ms.size()


static func calls_per_10_turns() -> float:
	var turns := _turns_with_llm + _turns_without_llm
	if turns == 0:
		return 0.0
	return snappedf(float(_general_calls) * 10.0 / float(turns), 0.01)


static func note_victory_call(latency_ms: int, trigger: String, turn: int, decision: String) -> void:
	_vp_calls += 1
	_vp_decisions[decision] = int(_vp_decisions.get(decision, 0)) + 1
	if decision == "ADVANCE_PHASE":
		_vp_transitions += 1
	_vp_last = {"turn": turn, "trigger": trigger, "latency_ms": latency_ms, "decision": decision}
	_revision += 1


static func revision() -> int:
	return _revision


static func snapshot() -> Dictionary:
	return {
		"general_calls": _general_calls,
		"general_calls_per_10_turns": calls_per_10_turns(),
		"average_general_latency_ms": average_latency_ms(),
		"turns_with_llm": _turns_with_llm,
		"turns_without_llm": _turns_without_llm,
		"red_turns": _red_turns,
		"blue_turns": _blue_turns,
		"controller_decisions": _controller_decisions,
		"replan_triggers": _replan_triggers.duplicate(true),
		"plans_applied": _plans_applied,
		"plans_staged": _plans_staged,
		"plans_kept": _plans_kept,
		"plans_stale": _plans_stale,
		"plans_rejected": _plans_rejected,
		"last_review": _last_review.duplicate(true),
		"revision": _revision,
		"victory": {
			"calls": _vp_calls,
			"decisions": _vp_decisions.duplicate(true),
			"transitions": _vp_transitions,
			"last": _vp_last.duplicate(true),
		},
	}


static func render_summary() -> String:
	var s := snapshot()
	return "GENERAL calls=%d (%.2f/10t) avg_lat=%dms | RED turns llm=%d nolllm=%d | decisions=%d | plans applied=%d staged=%d stale=%d rejected=%d" % [
		int(s["general_calls"]), float(s["general_calls_per_10_turns"]),
		int(s["average_general_latency_ms"]),
		int(s["turns_with_llm"]), int(s["turns_without_llm"]),
		int(s["controller_decisions"]),
		int(s["plans_applied"]), int(s["plans_staged"]),
		int(s["plans_stale"]), int(s["plans_rejected"])]
