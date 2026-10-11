class_name Cloud2GeneralPacket
extends RefCounted

## CLOUD-GENERAL MISSION HIERARCHY — General review packet (pure builder).
##
## Context compression for the persistent Cloud General. A review packet is
## composed from MISSION + CURRENT STRATEGIC PLAN + OPPONENT HYPOTHESES +
## COMPACT STATE + SIGNIFICANT EVENTS SINCE LAST REVIEW — never a replay
## of full battle history. The General returns PLAN/DOCTRINE/MISSIONS/
## CONTINGENCIES/HYPOTHESES/REVIEW CONDITIONS (see Cloud2GeneralResponse),
## never per-turn unit orders.
##
## Sends NO secrets, NO hidden reasoning, NO World Truth beyond the RED
## authorized observation.
##
## The packet carries the mission/doctrine vocabulary and the rule contract
## as TYPED fields (not prose): the General names tasks/areas/triggers from
## these lists, and Godot validates every name on return.

const MissionCls = preload("res://scripts/cloud2/cloud2_mission.gd")

const PACKET_VERSION := "cloud2_general_packet_v1"

const GENERAL_SYSTEM_PROMPT := "You are the RED operational general in a deterministic turn-based hex battle.\n\nBATTLE OBJECTIVE (authoritative, terminal): your PRIMARY goal is to WIN THE BATTLE. Your HQ destroyed = IMMEDIATE DEFEAT: no further turns, orders, or reviews. Enemy HQ destroyed = IMMEDIATE VICTORY: the battle ends at once. SECONDARY: among plans that plausibly win, prefer the LOWEST expected friendly losses — preserve forces when it supports victory, never at the cost of defeat, never waste them pointlessly. Missions serve victory: complete them when useful and replan when they fail, but no mission outranks HQ survival or a decisive HQ kill.\n\nYou do NOT control units directly. Deterministic MissionControllers execute your missions using only legal local actions. Your job is the long-term operational plan.\n\nYou receive: the mission contract, your current strategic plan, opponent hypotheses, a COMPACT battlefield state, and significant events since your last review.\n\nReturn ONE JSON object only: {\"concept\": {...}, \"doctrine\": {...}, \"missions\": [...], \"contingencies\": [...], \"opponent_hypotheses\": [...], \"review_conditions\": [...], \"review_horizon_turns\": N}.\n\nRules:\n- missions: 1-8 entries. Each: {\"mission_id\": \"M01\", \"task\": HOLD|ADVANCE|FIX|ATTACK|FLANK|RECON|RESERVE|WITHDRAW, \"area\": NORTH|CENTER|SOUTH|WEST|EAST|ANY, \"assigned_units\": [RED unit ids from friendly_units], \"objective\": {\"kind\": NONE|FORMATION_CLASS|ENEMY_FORMATION|REGION|ZONE, ...}, \"engagement\": {\"policy\": ATTACK_IF_ADVANTAGEOUS|HOLD_FIRE|ATTACK_DESIGNATED_ONLY|PURSUE_WEAKENED}, \"constraints\": {\"preserve_force\": bool, \"max_overextension\": 0-9}, \"success_conditions\": [trigger names], \"abort_conditions\": [...], \"report_conditions\": [...]}.\n- doctrine: {\"aggression\": 0-1, \"risk_tolerance\": 0-1, \"tempo\": 0-1, \"pursuit\": 0-1, \"reserve_discipline\": 0-1, \"deception\": 0-1}.\n- contingencies: [{\"contingency_id\": \"C1\", \"trigger\": TRIGGER, \"params\": {...}, \"action\": ACTIVATE_MISSION|ABORT_MISSION|REQUEST_REVIEW, \"mission_id\": \"...\", \"note\": \"...\"}].\n- triggers: MISSION_BLOCKED, MISSION_COMPLETE, FORCE_STRENGTH_BELOW, ENEMY_COMMITMENT_HIGH, ENEMY_CLASS_DETECTED, HQ_THREATENED, LOCAL_ADVANTAGE_HIGH, OBJECTIVE_EXPOSED, TURNS_ELAPSED, TARGET_DESTROYED, REGION_OCCUPIED, REGION_REACHED.\n- opponent_hypotheses: up to 4 competing hypotheses with confidence 0-1 and short evidence strings.\n- review_conditions: triggers that should request your next review. review_horizon_turns: 1-12 periodic review cadence.\n- Assign every ready RED formation to exactly one mission. Do NOT invent units, coordinates, or rules. Keep text fields short. Be concise: no essay, no Markdown, no code fences."

## SYMMETRIC V1: BLUE mirror of GENERAL_SYSTEM_PROMPT. Same contract,
## same schema demands, side-relative framing only.
const GENERAL_SYSTEM_PROMPT_BLUE := "You are the BLUE operational general in a deterministic turn-based hex battle.\n\nBATTLE OBJECTIVE (authoritative, terminal): your PRIMARY goal is to WIN THE BATTLE. Your HQ destroyed = IMMEDIATE DEFEAT: no further turns, orders, or reviews. Enemy HQ destroyed = IMMEDIATE VICTORY: the battle ends at once. SECONDARY: among plans that plausibly win, prefer the LOWEST expected friendly losses — preserve forces when it supports victory, never at the cost of defeat, never waste them pointlessly. Missions serve victory: complete them when useful and replan when they fail, but no mission outranks HQ survival or a decisive HQ kill.\n\nYou do NOT control units directly. Deterministic MissionControllers execute your missions using only legal local actions. Your job is the long-term operational plan.\n\nYou receive: the mission contract, your current strategic plan, opponent hypotheses, a COMPACT battlefield state, and significant events since your last review.\n\nReturn ONE JSON object only: {\"concept\": {...}, \"doctrine\": {...}, \"missions\": [...], \"contingencies\": [...], \"opponent_hypotheses\": [...], \"review_conditions\": [...], \"review_horizon_turns\": N}.\n\nRules:\n- missions: 1-8 entries. Each: {\"mission_id\": \"M01\", \"task\": HOLD|ADVANCE|FIX|ATTACK|FLANK|RECON|RESERVE|WITHDRAW, \"area\": NORTH|CENTER|SOUTH|WEST|EAST|ANY, \"assigned_units\": [BLUE unit ids from friendly_units], \"objective\": {\"kind\": NONE|FORMATION_CLASS|ENEMY_FORMATION|REGION|ZONE, ...}, \"engagement\": {\"policy\": ATTACK_IF_ADVANTAGEOUS|HOLD_FIRE|ATTACK_DESIGNATED_ONLY|PURSUE_WEAKENED}, \"constraints\": {\"preserve_force\": bool, \"max_overextension\": 0-9}, \"success_conditions\": [trigger names], \"abort_conditions\": [...], \"report_conditions\": [...]}.\n- doctrine: {\"aggression\": 0-1, \"risk_tolerance\": 0-1, \"tempo\": 0-1, \"pursuit\": 0-1, \"reserve_discipline\": 0-1, \"deception\": 0-1}.\n- contingencies: [{\"contingency_id\": \"C1\", \"trigger\": TRIGGER, \"params\": {...}, \"action\": ACTIVATE_MISSION|ABORT_MISSION|REQUEST_REVIEW, \"mission_id\": \"...\", \"note\": \"...\"}].\n- triggers: MISSION_BLOCKED, MISSION_COMPLETE, FORCE_STRENGTH_BELOW, ENEMY_COMMITMENT_HIGH, ENEMY_CLASS_DETECTED, HQ_THREATENED, LOCAL_ADVANTAGE_HIGH, OBJECTIVE_EXPOSED, TURNS_ELAPSED, TARGET_DESTROYED, REGION_OCCUPIED, REGION_REACHED.\n- opponent_hypotheses: up to 4 competing hypotheses with confidence 0-1 and short evidence strings.\n- review_conditions: triggers that should request your next review. review_horizon_turns: 1-12 periodic review cadence.\n- Assign every ready BLUE formation to exactly one mission. Do NOT invent units, coordinates, or rules. Keep text fields short. Be concise: no essay, no Markdown, no code fences."


## Side selector for the General system prompt (default red = legacy).
static func general_prompt_for(side: String) -> String:
	if side.strip_edges().to_lower() == "blue":
		return GENERAL_SYSTEM_PROMPT_BLUE
	return GENERAL_SYSTEM_PROMPT

const MAX_EVENTS := 24


static func compact_state(obs: Dictionary, side: String = "red") -> Dictionary:
	var friendlies: Array = []
	for u_val in (obs.get("friendly_units", []) as Array):
		if not u_val is Dictionary:
			continue
		var u: Dictionary = u_val
		friendlies.append({
			"unit_id": str(u.get("unit_id", "")),
			"class": str(u.get("class", "")).to_upper(),
			"q": int(u.get("q", 0)),
			"r": int(u.get("r", 0)),
			"region": str(u.get("region", "")),
			"status": str(u.get("status", "")),
			"soldiers": int(u.get("soldiers", 0)),
			"condition": str(u.get("condition", "")),
			"can_attack": bool(u.get("can_attack", false)),
		})
	friendlies.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a.get("unit_id", "")) < str(b.get("unit_id", "")))
	var enemies: Array = []
	for e_val in (obs.get("known_enemy_units", []) as Array):
		if not e_val is Dictionary:
			continue
		var e2: Dictionary = e_val
		enemies.append({
			"unit_id": str(e2.get("unit_id", "")),
			"class": str(e2.get("class", "")).to_upper(),
			"q": int(e2.get("q", 0)),
			"r": int(e2.get("r", 0)),
			"region": str(e2.get("region", "")),
			"contact_state": str(e2.get("contact_state", "")),
			"troop_estimate": str(e2.get("troop_estimate", "")),
		})
	enemies.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a.get("unit_id", "")) < str(b.get("unit_id", "")))
	var parity: Dictionary = obs.get("parity", {})
	return {
		"turn": int(obs.get("turn", 0)),
		"snapshot_id": str(obs.get("snapshot_id", "")),
		"state_version": int(parity.get("state_version", -1)),
		"friendly_units": friendlies,
		"known_enemy_units": enemies,
		"force_summary": summarize_forces(friendlies, enemies, side),
	}


static func summarize_forces(friendlies: Array, enemies: Array, side: String = "red") -> Dictionary:
	var own_by_region := {}
	var foe_by_region := {}
	var own_soldiers := 0
	for u in friendlies:
		var r := str((u as Dictionary).get("region", "?"))
		own_by_region[r] = int(own_by_region.get(r, 0)) + 1
		own_soldiers += int((u as Dictionary).get("soldiers", 0))
	for e in enemies:
		if str((e as Dictionary).get("contact_state", "")) != "current_visible":
			continue
		var r2 := str((e as Dictionary).get("region", "?"))
		foe_by_region[r2] = int(foe_by_region.get(r2, 0)) + 1
	var vis_count := enemies.filter(func(x: Dictionary) -> bool: return str(x.get("contact_state", "")) == "current_visible").size()
	if side.strip_edges().to_lower() == "blue":
		return {
			"blue_formations": friendlies.size(),
			"blue_soldiers": own_soldiers,
			"blue_by_region": own_by_region,
			"red_visible": vis_count,
			"red_by_region": foe_by_region,
		}
	return {
		"red_formations": friendlies.size(),
		"red_soldiers": own_soldiers,
		"red_by_region": own_by_region,
		"blue_visible": vis_count,
		"blue_by_region": foe_by_region,
	}


## Build a General review packet.
## plan: current StrategicPlan ({} when none exists yet — initial review).
## events_since_review: bounded factual events (already capped by caller).
## review_trigger: {trigger, reason, turn} naming why this review fires.
static func build(obs: Dictionary, plan: Dictionary, events_since_review: Array, review_trigger: Dictionary, side: String = "red") -> Dictionary:
	var mission: Dictionary = (obs.get("mission", {}) as Dictionary).duplicate(true)
	var parity: Dictionary = obs.get("parity", {})
	var ev: Array = []
	for e_val in events_since_review:
		if e_val is Dictionary:
			ev.append((e_val as Dictionary).duplicate(true))
		if ev.size() >= MAX_EVENTS:
			break
	return {
		"packet_version": PACKET_VERSION,
		"snapshot_id": str(obs.get("snapshot_id", "")),
		"battle_id": str(obs.get("battle_id", "")),
		"scenario_id": str(obs.get("scenario_id", "")),
		"turn": int(obs.get("turn", 0)),
		"acting_side": _side_tag(side),
		"review": "initial_plan" if plan.is_empty() or int(plan.get("plan_version", 0)) == 0 else "plan_review",
		"review_trigger": review_trigger.duplicate(true),
		"mission": mission,
		"current_plan": plan.duplicate(true) if not plan.is_empty() else {},
		"opponent_hypotheses": (plan.get("opponent_hypotheses", []) as Array).duplicate(true) if not plan.is_empty() else [],
		"compact_state": compact_state(obs, side),
		"events_since_review": ev,
		"vocabulary": mission_vocabulary(),
		"rules": rule_contract(side),
		"battle_rules": battle_rules(),
		"state_version": int(parity.get("state_version", -1)),
	}


static func to_json(packet: Dictionary, pretty: bool = false) -> String:
	return JSON.stringify(packet, "  " if pretty else "")


## FAST COORDINATOR packets: the Cloud chooses IDs from a Godot-built menu
## instead of generating StrategicPlan JSON. Initial carries the menu +
## compact state; review adds the current plan summary, baseline choices,
## trigger, and bounded recent events.
const COORD_PACKET_VERSION := "cloud2_coord_packet_v1"


static func build_coord_initial(obs: Dictionary, menu: Dictionary, side: String = "red") -> Dictionary:
	var mission: Dictionary = (obs.get("mission", {}) as Dictionary).duplicate(true)
	var parity: Dictionary = obs.get("parity", {})
	return {
		"packet_version": COORD_PACKET_VERSION,
		"request": "INITIAL_COORDINATION",
		"snapshot_id": str(obs.get("snapshot_id", "")),
		"battle_id": str(obs.get("battle_id", "")),
		"scenario_id": str(obs.get("scenario_id", "")),
		"turn": int(obs.get("turn", 0)),
		"acting_side": _side_tag(side),
		"mission": {"type": str(mission.get("type", "")), "objective": str(mission.get("objective", ""))},
		"menu": menu.duplicate(true),
		"compact_state": compact_state(obs, side),
		"battle_rules": battle_rules(),
		"state_version": int(parity.get("state_version", -1)),
	}


static func build_coord_review(obs: Dictionary, menu: Dictionary, plan: Dictionary, trigger: Dictionary, events: Array, baseline: Dictionary, side: String = "red") -> Dictionary:
	var mission: Dictionary = (obs.get("mission", {}) as Dictionary).duplicate(true)
	var parity: Dictionary = obs.get("parity", {})
	var ev: Array = []
	for e_val in events:
		if e_val is Dictionary:
			ev.append((e_val as Dictionary).duplicate(true))
		if ev.size() >= 8:
			break
	return {
		"packet_version": COORD_PACKET_VERSION,
		"request": "REVIEW_COORDINATION",
		"snapshot_id": str(obs.get("snapshot_id", "")),
		"battle_id": str(obs.get("battle_id", "")),
		"scenario_id": str(obs.get("scenario_id", "")),
		"turn": int(obs.get("turn", 0)),
		"acting_side": _side_tag(side),
		"review_trigger": trigger.duplicate(true),
		"mission": {"type": str(mission.get("type", "")), "objective": str(mission.get("objective", ""))},
		"menu": menu.duplicate(true),
		"current_plan": plan_summary(plan),
		"has_baseline": not baseline.is_empty(),
		"baseline_choices": (baseline.get("choices", {}) as Dictionary).duplicate(true),
		"compact_state": compact_state(obs, side),
		"events_since_review": ev,
		"battle_rules": battle_rules(),
		"state_version": int(parity.get("state_version", -1)),
	}


## Compact current-plan summary for review packets (choices, not prose).
static func plan_summary(plan: Dictionary) -> Dictionary:
	var missions: Array = []
	for m_val in (plan.get("missions", []) as Array):
		if m_val is Dictionary:
			var m: Dictionary = m_val
			missions.append({"mission_id": str(m.get("mission_id", "")), "task": str(m.get("task", "")),
				"area": str(m.get("area", "")), "units": (m.get("assigned_units", []) as Array).duplicate(true),
				"status": str(m.get("status", ""))})
	return {"plan_version": int(plan.get("plan_version", 0)),
		"concept": (plan.get("concept", {}) as Dictionary).duplicate(true),
		"doctrine": (plan.get("doctrine", {}) as Dictionary).duplicate(true),
		"missions": missions,
		"review_horizon_turns": int(plan.get("review_horizon_turns", 4))}


## The closed vocabulary the General must use (same constants Godot
## validates against — the packet cannot drift from the validator).
static func mission_vocabulary() -> Dictionary:
	return {
		"tasks": MissionCls.TASKS.duplicate(),
		"areas": MissionCls.AREAS.duplicate(),
		"engagement_policies": MissionCls.ENGAGEMENT_POLICIES.duplicate(),
		"objective_kinds": MissionCls.OBJECTIVE_KINDS.duplicate(),
		"triggers": MissionCls.TRIGGERS.duplicate(),
		"contingency_actions": MissionCls.CONTINGENCY_ACTIONS.duplicate(),
		"doctrine_keys": ["aggression", "risk_tolerance", "tempo", "pursuit",
			"reserve_discipline", "deception"],
	}


## SYMMETRIC V1: canonical side tag for packets (RED default).
static func _side_tag(side: String) -> String:
	return "BLUE" if side.strip_edges().to_lower() == "blue" else "RED"


## The standing rule contract: what the General owns (plan/missions) and
## what Godot owns (legality, movement, combat, execution).
static func rule_contract(side: String = "red") -> Dictionary:
	return {
		"role": "strategic-plan-only",
		"side": _side_tag(side),
		"unit_orders_forbidden": true,
		"exact_hexes_forbidden": true,
		"execution": "deterministic-mission-controllers",
		"max_missions": MissionCls.MAX_MISSIONS,
		"assignment": "every-ready-formation-exactly-one-mission",
		"review_horizon_range": [1, 12],
		"battle_objective": battle_rules(),
	}


## The authoritative battle objective as TYPED fields (BATTLE_TERMINAL_CONTRACT_V0):
## HQ-terminal truth plus the win-first / minimize-losses-second hierarchy.
## Present in every General packet (initial + review, full + coord).
static func battle_rules() -> Dictionary:
	return {
		"primary": "WIN_THE_BATTLE",
		"own_hq_destroyed": "IMMEDIATE_DEFEAT",
		"enemy_hq_destroyed": "IMMEDIATE_VICTORY",
		"terminal_freeze": "no further turns, orders, movement, or reviews",
		"loss_principle": "MINIMIZE_FRIENDLY_LOSSES_AMONG_WINNING_PLANS",
		"mission_rank": "SUBORDINATE_TO_BATTLE_VICTORY",
	}


static func validate_shape(packet: Dictionary) -> Dictionary:
	for k in ["packet_version", "snapshot_id", "battle_id", "turn", "acting_side", "mission", "compact_state", "events_since_review", "vocabulary", "rules"]:
		if not packet.has(k):
			return {"ok": false, "code": "GENERAL_PACKET_SHAPE", "detail": "General packet misses '%s'." % k}
	if not str(packet.get("acting_side", "")) in ["RED", "BLUE"]:
		return {"ok": false, "code": "GENERAL_PACKET_SIDE", "detail": "General packets act as RED or BLUE."}
	return {"ok": true, "code": "", "detail": ""}


# --- VICTORY PLAN V0 packets (additive) ------------------------------------
## Long-horizon planning packets. The INITIAL packet asks for a COMPLETE
## multi-phase VictoryPlan; the REVIEW packet carries the canonical
## persistent plan + current phase + evaluated phase progress + the reason
## this review fired, and asks for KEEP / ADVANCE_PHASE / AMEND_PLAN /
## EMERGENCY_REPLAN. review_horizon_turns is REVIEW CADENCE in both (see
## REVIEW_CADENCE_NOTE) — the VictoryPlan itself spans the battle.

const VictoryAuthoringCls = preload("res://scripts/cloud2/cloud2_victory_authoring.gd")
const BrainContextCls = preload("res://scripts/cloud2/cloud2_brain_context.gd")

const VICTORY_INITIAL_VERSION := "cloud2_victory_initial_v1"
const VICTORY_REVIEW_VERSION := "cloud2_victory_review_v2"
const VICTORY_MAX_EVENTS := 12

const REVIEW_CADENCE_NOTE := "review_horizon_turns is REVIEW CADENCE (turns between your strategic re-validations, 1-12). It is NOT how far ahead you plan: the VictoryPlan itself spans the intended battle."


static func victory_vocabulary() -> Dictionary:
	var v := mission_vocabulary()
	v["phase_statuses"] = ["PLANNED", "ACTIVE", "COMPLETED", "FAILED", "ABORTED"]
	v["review_decisions"] = ["KEEP", "ADVANCE_PHASE", "AMEND_PLAN", "EMERGENCY_REPLAN"]
	v["transition_success_actions"] = ["ADVANCE", "COMPLETE_PLAN", "HOLD_FOR_REVIEW"]
	v["transition_failure_actions"] = ["HOLD_FOR_REVIEW", "ADVANCE_ANYWAY", "REQUEST_EMERGENCY"]
	v["branch_actions"] = ["REQUEST_REVIEW", "HOLD_PHASE", "RELEASE_RESERVE", "NOTE_ONLY"]
	v["condition_shape"] = {"trigger": "TRIGGER NAME", "params": "object (see trigger parameter notes in the prompt)"}
	v["authoring"] = {"contract": "victory_author_v1", "phases": "2..4", "missions_per_phase": "<=4",
		"conditions_per_list": "<=4", "branches": "<=3", "text_chars": "<=160 (objective <=200)",
		"condition_form": "bare TRIGGER name or {when: TRIGGER, flat params}"}
	return v


static func build_victory_initial(obs: Dictionary, side: String = "red") -> Dictionary:
	var mission: Dictionary = (obs.get("mission", {}) as Dictionary).duplicate(true)
	var parity: Dictionary = obs.get("parity", {})
	return _with_context(obs, side, {
		"packet_version": VICTORY_INITIAL_VERSION,
		"request": "VICTORY_INITIAL",
		"snapshot_id": str(obs.get("snapshot_id", "")),
		"battle_id": str(obs.get("battle_id", "")),
		"scenario_id": str(obs.get("scenario_id", "")),
		"turn": int(obs.get("turn", 0)),
		"acting_side": _side_tag(side),
		"mission": mission,
		"compact_state": compact_state(obs, side),
		"vocabulary": victory_vocabulary(),
		"rules": rule_contract(side),
		"battle_rules": battle_rules(),
		"review_cadence_note": REVIEW_CADENCE_NOTE,
		"state_version": int(parity.get("state_version", -1)),
	})


## progress: manager-computed active-phase progress (condition truth values
## included). statuses: live active-mission rows. rev_tail: [{revision,
## turn, decision, reason}] newest last (bounded by caller).
## V2 COMPACT: the model gets plan_authoring (re-serializable strategy) +
## plan_live (revision, statuses, evaluated truth) instead of the full
## canonical JSON — same decisions, roughly half the input.
static func build_victory_review(obs: Dictionary, vp: Dictionary, progress: Dictionary, statuses: Array, hypotheses: Array, events: Array, trigger: Dictionary, rev_tail: Array, side: String = "red") -> Dictionary:
	var mission: Dictionary = (obs.get("mission", {}) as Dictionary).duplicate(true)
	var parity: Dictionary = obs.get("parity", {})
	var ev: Array = []
	for e_val in events:
		if e_val is Dictionary:
			ev.append((e_val as Dictionary).duplicate(true))
		if ev.size() >= VICTORY_MAX_EVENTS:
			break
	var comp := VictoryAuthoringCls.compress_plan(vp)
	var live: Dictionary = (comp.get("live_skeleton", {}) as Dictionary).duplicate(true)
	live["mission_statuses"] = statuses.duplicate(true)
	live["turns_active"] = int(progress.get("turns_active", 0))
	live["evaluated"] = {
		"entry": _truth_rows(progress.get("entry", [])),
		"success": _truth_rows(progress.get("success", [])),
		"failure": _truth_rows(progress.get("failure", [])),
		"abort": _truth_rows(progress.get("abort", [])),
		"plan_abort": _truth_rows(progress.get("plan_abort", [])),
	}
	live["branches"] = (progress.get("branches", []) as Array).duplicate(true)
	live["reserve"] = (progress.get("reserve", {}) as Dictionary).duplicate(true)
	return _with_context(obs, side, {
		"packet_version": VICTORY_REVIEW_VERSION,
		"request": "VICTORY_REVIEW",
		"snapshot_id": str(obs.get("snapshot_id", "")),
		"battle_id": str(obs.get("battle_id", "")),
		"scenario_id": str(obs.get("scenario_id", "")),
		"turn": int(obs.get("turn", 0)),
		"acting_side": _side_tag(side),
		"review_trigger": trigger.duplicate(true),
		"mission": mission,
		"plan_authoring": comp.get("authoring", {}),
		"plan_live": live,
		"opponent_hypotheses": hypotheses.duplicate(true),
		"events_since_review": ev,
		"revision_tail": rev_tail.duplicate(true),
		"vocabulary": victory_vocabulary(),
		"rules": rule_contract(side),
		"battle_rules": battle_rules(),
		"review_cadence_note": REVIEW_CADENCE_NOTE,
		"state_version": int(parity.get("state_version", -1)),
	})


## CONTEXTUAL BRAIN V0 (env BRAIN_CONTEXT_PACK=v0): explicit rules / forces /
## map / mode block. Unset = packet unchanged.
static func _with_context(obs: Dictionary, side: String, packet: Dictionary) -> Dictionary:
	if BrainContextCls.enabled():
		packet["context"] = BrainContextCls.build(obs, side)
	return packet


static func _truth_rows(rows: Array) -> Array:
	var out: Array = []
	for r_val in rows:
		if r_val is Dictionary:
			var r: Dictionary = r_val
			out.append({"trigger": str(r.get("trigger", "?")),
				"satisfied": bool(r.get("satisfied", false))})
	return out
