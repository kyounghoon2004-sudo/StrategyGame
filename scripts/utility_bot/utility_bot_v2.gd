class_name UtilityBotV2
extends "res://scripts/utility_bot/utility_bot.gd"

## Utility Bot V2 — ADVANCED full-turn tactical policy.
##
## Side-authorized like V0/V1: the caller supplies Godot's current legal
## candidates and executes the returned ORIGINAL candidate unchanged. This
## class never reads world truth, invents an action, simulates combat, or
## reimplements rules. Combat facts come only from the authoritative preview
## fields the adapter attaches; spatial threat estimates are bounded planning
## heuristics derived from observed positions and the public class range table
## (CombatCalculator.get_attack_range), never from hidden state.
##
## V2 strength comes from planning, not aggression:
##   * short-lived tactical intents (1–3 turns, revisable, never hard-coded)
##   * full-turn coherent plan over the pooled legal set with reservation
##     accounting so fights get the force they need and no more
##   * one bounded enemy-response ply (exposure / focus-fire / counterattack)
##   * explicit sacrifice and trade evaluation
##   * tempo bias and endgame conversion (being safe forever != winning)
##   * match-local, bounded opponent tendency evidence (reset per match)

const CombatCalculatorCls = preload("res://scripts/combat/combat_calculator.gd")

const INTENT_TYPES := ["ELIMINATE_HIGH_VALUE", "CONVERT_ADVANTAGE", "PRESSURE_HQ",
	"BREAK_SCREEN", "DEFEND_HQ", "SCREEN_WITHDRAW", "EXPLOIT_FLANK"]
const INTENT_TTL_RANGE := Vector2(1, 3)
const V2_TOP_K := 5
const VERSION := "V2"
# ---- V2.1 bounded conversion mode (V2.1_CONVERSION) ----
# 173 of 200 held-out games timed out with V2 idling next to the objective
# (t40+ draw mix: 17% WAIT / 25% END_TURN / 14% ATTACK vs 47% ATTACK in
# wins). Root cause: counter/exposure/retreat prices attacking near the
# enemy fortress line below idling. The conversion window fires ONLY on
# visible evidence, then (a) applies a bounded conservatism floor so risk
# prices stop dominating the attack band, (b) waives the weakened-retreat
# penalty that pulls attack bands below idle, (c) taxes dead-time actions,
# (d) pushes the objective lunge. Hard loss safeguards stay absolute:
# preservation fallback (m126), fort-siege response (m161/167), and an
# unmoved hq_emergency that kills any active window instantly.
const CONV_TURN_MIN := 20
const CONV_CLOCK_TURN := 34
const CONV_SIEGE_TURN := 40
const CONV_STREAK_COMMIT := 2
const CONV_COMMIT_TURNS := 6
const CONV_FORCE_RATIO := 2.0
const CONV_CLOCK_RATIO := 0.9
const CONV_HQ_MARGIN := 0.75	# danger below this fraction of the kill-line is not a conversion veto
const CONV_MORALE_MIN := 35.0
const CONV_DEADTIME_TAX := 2.6
const CONV_RISK_DISCOUNT := 0.72
const CONV_RETREAT_FREE := 3.0
const CONV_RATIONALE := "conversion_mode: committed force >= 2x visible enemy, HQ safe, clock pressure"

var _v2_params: Dictionary = {}
var _intent: Dictionary = {}
var _candidate_intents: Array = []
var _plan: Array = []
var _plan_turn := -1
var _commitments: Dictionary = {}
var _replan_reason := "match_start"
var _tendencies: Dictionary = {}
var _tendency_turn := -1
var _acted_this_turn: Dictionary = {}
var _visited_this_turn: Dictionary = {}
var _recent_destinations: Dictionary = {}
var _convert_sticky := false
var _damage_dealt: Dictionary = {}
var _enemy_high: Dictionary = {}
var _hunt_anchor := Vector2i.ZERO
var _hunt_set := false
var _hunt_anchor_turn := -1
var _turn_high_water := 0
var _hunt_hq_known := false
var _morale_proxy: Dictionary = {}
var _own_count: Dictionary = {}
# V2.1 conversion-mode state (reset per match).
var _conv_evidence_turns := 0
var _conv_active_turns_left := 0
var _conv_streak := 0
var _conv_trace: Array = []
var _conv_activations := 0
var _conv_successes := 0
var _conv_recorded_success := false
var _conv_offers_last := 0
# Turn-level evidence aggregates (fog-honest: authorized pools only).
var _turn_offers_turn := -1
var _turn_offers_count := 0
var _turn_offers_assault := false


func configure(seed: int, archetype_override: String = "") -> void:
	super.configure(seed, archetype_override)
	# Match-level bounded V2 parameters drawn from the SAME seeded stream, so
	# same seed + same world => identical profile and identical replay.
	_v2_params = {
		"planning_horizon": float(_rng.randi_range(int(INTENT_TTL_RANGE.x), int(INTENT_TTL_RANGE.y))),
		"sacrifice_tolerance": snappedf(_rng.randf_range(0.15, 0.9), 0.001),
		"tempo_bias": snappedf(_rng.randf_range(0.35, 1.0), 0.001),
		# response_conservatism: the frozen population-spec band. The planner
		# LOW floor (0.25) applies ONLY inside conversion windows.
		"response_conservatism": snappedf(_rng.randf_range(0.25, 0.95), 0.001),
		"response_conservatism_low": 0.25,
		"concentration_preference": snappedf(_rng.randf_range(0.4, 1.0), 0.001),
		"hq_conversion_pressure": snappedf(_rng.randf_range(0.4, 1.0), 0.001),
	}
	_intent = {}
	_candidate_intents = []
	_plan = []
	_plan_turn = -1
	_commitments = {}
	_replan_reason = "match_start"
	_acted_this_turn = {}
	_visited_this_turn = {}
	_recent_destinations = {}
	_convert_sticky = false
	_damage_dealt = {}
	_enemy_high = {}
	_hunt_anchor = Vector2i.ZERO
	_hunt_set = false
	_hunt_anchor_turn = -1
	_turn_high_water = 0
	_hunt_hq_known = false
	_morale_proxy = {}
	_own_count = {}
	_reset_tendencies()
	_conv_evidence_turns = 0
	_conv_active_turns_left = 0
	_conv_streak = 0
	_conv_trace = []
	_conv_activations = 0
	_conv_successes = 0
	_conv_recorded_success = false
	_conv_offers_last = 0
	_turn_offers_turn = -1
	_turn_offers_count = 0
	_turn_offers_assault = false


func profile() -> Dictionary:
	var p: Dictionary = super.profile()
	p["version"] = VERSION
	p["planning_horizon"] = _v2_params.get("planning_horizon", 1.0)
	p["sacrifice_tolerance"] = _v2_params.get("sacrifice_tolerance", 0.5)
	p["tempo_bias"] = _v2_params.get("tempo_bias", 0.6)
	p["response_conservatism"] = _v2_params.get("response_conservatism", 0.6)
	p["concentration_preference"] = _v2_params.get("concentration_preference", 0.7)
	p["hq_conversion_pressure"] = _v2_params.get("hq_conversion_pressure", 0.7)
	return p


func last_decision() -> Dictionary:
	return _last.duplicate(true)


## V2 selection: full-turn plan with per-action revalidation. Returns an
## original candidate from the supplied pool — never a synthesized action.
func select_action(observation: Dictionary, candidates: Array) -> Dictionary:
	if not _configured:
		return {"ok": false, "code": "NOT_CONFIGURED", "detail": "Call configure once at match start."}
	if candidates.is_empty():
		return {"ok": false, "code": "NO_LEGAL_ACTIONS", "detail": "The caller supplied no legal candidates."}
	var turn := _turn_of(observation)
	var ctx: Dictionary = _context(observation)
	_update_tendencies(ctx, observation, turn)
	# V2.1: aggregate turn-level offensive evidence across every legal pool
	# this turn has exposed (fog-honest — authorized candidates only, no
	# hidden-state reads). The ASSAULT flag feeds the siege door: it is
	# POSITION evidence (the pool only contains assaults at enemy walls),
	# so it is non-circular. Raw attack-offer counts are NOT gate evidence:
	# a passively idling army generates zero offers, so an offer-count gate
	# can never fire in exactly the standoff states conversion exists for.
	if turn != _turn_offers_turn:
		_turn_offers_turn = turn
		_turn_offers_count = 0
		_turn_offers_assault = false
	for raw_offer in candidates:
		if not raw_offer is Dictionary:
			continue
		var offer: Dictionary = raw_offer
		var k_offer := str(offer.get("action_type", "")).to_upper()
		if k_offer == "ATTACK" or k_offer == "ASSAULT":
			_turn_offers_count += 1
			if k_offer == "ASSAULT":
				_turn_offers_assault = true
	_conv_offers_last = _turn_offers_count
	if turn != _plan_turn:
		_commitments = {}
		_plan = []
		_acted_this_turn = {}
		_visited_this_turn = {}
		if _plan_turn >= 0:
			_replan_reason = "new_turn_%d" % turn
		_plan_turn = turn
	var eval := _battlefield_eval(ctx, observation, turn)
	eval["hunt"] = _endgame_hunt(ctx, observation)
	_refresh_intent(ctx, observation, eval, turn)
	var intent: Dictionary = _intent if not _intent.is_empty() else _default_intent(eval)
	# ---- pass 1: composite scoring of every legal candidate ----
	var ranked: Array = []
	for raw in candidates:
		if not raw is Dictionary:
			continue
		var c: Dictionary = raw
		var scored := _score_candidate(c, ctx, observation, eval, intent)
		ranked.append({"candidate": c, "candidate_id": str(c.get("candidate_id", "")),
			"score": float(scored.get("score", 0.0)), "terms": scored.get("terms", {}),
			"features": scored.get("features", {})})
	if ranked.is_empty():
		return {"ok": false, "code": "NO_VALID_CANDIDATES", "detail": "No dictionary candidates supplied."}
	ranked.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if is_equal_approx(float(a["score"]), float(b["score"])):
			return str(a["candidate_id"]) < str(b["candidate_id"])
		return float(a["score"]) > float(b["score"]))
	# ---- full-turn plan: coherent per-unit allocation over the ranked pool ----
	_form_plan(ranked, ctx, eval, intent)
	var plan_by_id: Dictionary = {}
	for entry_val in _plan:
		var entry: Dictionary = entry_val
		plan_by_id[str(entry.get("candidate_id", ""))] = entry
	var plan_bonus := 0.9 + 1.4 * float(_v2_params.get("concentration_preference", 0.7))
	for row_val in ranked:
		var row: Dictionary = row_val
		var pid := str(row["candidate_id"])
		if plan_by_id.has(pid):
			row["score"] = float(row["score"]) + plan_bonus
			(row["terms"] as Dictionary)["plan_bonus"] = plan_bonus
	ranked.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if is_equal_approx(float(a["score"]), float(b["score"])):
			return str(a["candidate_id"]) < str(b["candidate_id"])
		return float(a["score"]) > float(b["score"]))
	# ---- bounded seeded selection over the plan-boosted ranking ----
	var temperature := _temperature
	if str(eval.get("phase", "parity")) == "behind":
		temperature *= 1.35  # behind: higher-variance lines are acceptable
	var best := float((ranked[0] as Dictionary)["score"])
	var choices: Array = []
	var total := 0.0
	for i in range(mini(V2_TOP_K, ranked.size())):
		var row: Dictionary = ranked[i]
		var gap := best - float(row["score"])
		if gap > maxf(1.1, 2.2 * temperature):
			break
		var mass := exp(-gap / maxf(0.05, temperature))
		row["probability_mass"] = mass
		choices.append(row)
		total += mass
	if choices.is_empty():
		choices.append(ranked[0])
		total = 1.0
	var roll := _rng.randf() * total
	var selected: Dictionary = choices[0]
	for row_val in choices:
		var row: Dictionary = row_val
		roll -= float(row["probability_mass"])
		if roll <= 0.0:
			selected = row
			break
	_decision_index += 1
	var action: Dictionary = selected["candidate"]
	var kind := str(action.get("action_type", "")).to_upper()
	var target_id := str(action.get("target_id", ""))
	var acting_uid := str(action.get("unit_id", ""))
	_acted_this_turn[acting_uid] = int(_acted_this_turn.get(acting_uid, 0)) + 1
	if kind == "MOVE":
		var seen: Array = _visited_this_turn.get(acting_uid, [])
		seen.append(str(action.get("destination", [])))
		_visited_this_turn[acting_uid] = seen
		# Cross-turn memory: shuffling between the same two hexes is a stall.
		var recent: Array = _recent_destinations.get(acting_uid, [])
		recent.append(str(action.get("destination", [])))
		while recent.size() > 3:
			recent.pop_front()
		_recent_destinations[acting_uid] = recent
	if kind == "ATTACK" or kind == "ASSAULT":
		var target: Dictionary = (ctx["visible_by_id"] as Dictionary).get(target_id, {})
		var est := _estimated_soldiers(target) if not target.is_empty() else 300.0
		var mid := 0.5 * (maxf(0.0, float(action.get("expected_enemy_casualties_min", 0.0))) \
			+ maxf(0.0, float(action.get("expected_enemy_casualties_max", 0.0))))
		# Reservation accounting: later calls in this turn see what this
		# attack already commits, so no fight over-allocates.
		var key := target_id if not target_id.is_empty() else str(action.get("stronghold_id", "?"))
		_commitments[key] = minf(est, float(_commitments.get(key, 0.0)) + mid)
		if kind == "ATTACK" and not target_id.is_empty():
			_damage_dealt[target_id] = float(_damage_dealt.get(target_id, 0.0)) + mid
		# V2.1: a wall assault or a >= 20-casualty strike while converting
		# marks the activation effective.
		if _conv_active_turns_left > 0 and (kind == "ASSAULT" or mid >= 20.0):
			_conv_recorded_success = true
	# Remove the consumed plan entry; replan on the next call if it changed.
	var new_plan: Array = []
	for entry_val in _plan:
		if str((entry_val as Dictionary).get("candidate_id", "")) != str(selected["candidate_id"]):
			new_plan.append(entry_val)
	_plan = new_plan
	var alternatives: Array = []
	for row_val in ranked.slice(0, mini(5, ranked.size())):
		var row: Dictionary = row_val
		alternatives.append({"candidate_id": str(row["candidate_id"]), "score": float(row["score"])})
	var rationale := _utility_rationale(selected, intent, eval)
	_last = {"ok": true, "candidate": action.duplicate(true),
		"candidate_id": str(action.get("candidate_id", "")),
		"action_type": kind,
		"score": float(selected["score"]),
		"features": (selected.get("features", {}) as Dictionary).duplicate(true),
		"alternatives": alternatives, "decision_index": _decision_index,
		"archetype": _archetype, "seed": _seed, "version": VERSION,
		"planning": {
			"intent": intent.duplicate(true),
			"candidate_intents": _candidate_intents.duplicate(true),
			"force_allocation": _plan.duplicate(true),
			"predicted_enemy_response": _predicted_response(action, ctx, eval),
			"chosen_turn_sequence": _plan_ids(),
			"replan_reason": _replan_reason,
			"utility_rationale": rationale,
			"phase": str(eval.get("phase", "parity")),
			"material_lead": float(eval.get("lead", 0.0)),
		"commitments": _commitments.duplicate(true),
		"conversion_mode": {
			"active": bool(eval.get("conv_active", false)),
			"streak": int(eval.get("conv_streak", 0)),
			"reason": str(eval.get("conv_reason", "")),
			"trace_tail": _conv_trace.duplicate(true),
		},
	}}
	_replan_reason = ""
	return _last.duplicate(true)


# ------------------------------------------------------------------
# Battlefield evaluation (authorized view only)
# ------------------------------------------------------------------

func _battlefield_eval(ctx: Dictionary, obs: Dictionary, turn: int) -> Dictionary:
	var own_strength := 0.0
	var own_field := 0
	var own_weak := 0
	var own_hq_strength := 0.0
	var own_hq: Dictionary = ctx["own_hq"]
	for raw in (ctx["friendly_list"] as Array):
		if not raw is Dictionary:
			continue
		var u: Dictionary = raw
		if int(u.get("soldiers", 0)) <= 0:
			continue
		var s := _estimated_soldiers(u)
		own_strength += s
		own_field += 1
		if _soldier_fraction(u) < 0.45:
			own_weak += 1
		if str(u.get("class", "")).to_lower() == "hq":
			own_hq_strength = s
	var enemy_strength := 0.0
	var enemy_visible_strength := 0.0
	var enemy_field := 0
	var enemy_weak := 0
	var enemy_hq_strength := 0.0
	for raw in (ctx["visible"] as Array):
		if not raw is Dictionary:
			continue
		var e: Dictionary = raw
		var s := _estimated_soldiers(e)
		enemy_strength += s
		enemy_visible_strength += s
		enemy_field += 1
		if _soldier_fraction(e) < 0.45:
			enemy_weak += 1
		if str(e.get("class", "")).to_lower() == "hq":
			enemy_hq_strength = s
	# Stale contacts are legitimate last-known evidence at reduced weight.
	for raw in (ctx["stale"] as Array):
		if raw is Dictionary:
			enemy_strength += 0.45 * _estimated_soldiers(raw)
	var enemy_hq: Dictionary = ctx["enemy_hq"]
	var enemy_hq_dist := 999
	if not enemy_hq.is_empty():
		enemy_hq_dist = _hex_distance(_point(own_hq) if not own_hq.is_empty() else Vector2i.ZERO, _point(enemy_hq))
	elif not own_hq.is_empty():
		# Public mirror-sector inference (same fairness rule as V1): the enemy
		# HQ sector is the opposite side of the board from our own HQ.
		enemy_hq_dist = _hex_distance(_point(own_hq), _mirror_point(_point(own_hq), obs))
	var total := maxf(1.0, own_strength + enemy_strength)
	# Fog ignorance is NOT a material lead: with no enemy evidence at all the
	# situation is unknown, not won.
	var has_enemy_evidence := enemy_strength > 0.0
	var lead := (own_strength - enemy_strength) / total if has_enemy_evidence else 0.0
	var contact := not (ctx["visible"] as Array).is_empty()
	var phase := "parity"
	if has_enemy_evidence and lead > 0.16:
		phase = "ahead"
	elif has_enemy_evidence and lead < -0.22:
		phase = "behind"
	var hq_threatened := bool(ctx["hq_threatened"])
	# V2 emergency gate: an enemy that can actually hit the HQ NOW (its own
	# attack range, not the march allowance). A patrolling enemy two hexes
	# out must not freeze the whole army in permanent defense.
	var immediate_hq_danger := 0.0
	if not own_hq.is_empty():
		var hq_point2 := _point(own_hq)
		for raw2 in (ctx["visible"] as Array):
			if not raw2 is Dictionary:
				continue
			var e2: Dictionary = raw2
			var cls2 := str(e2.get("class", "")).to_lower()
			var strike := int(CombatCalculatorCls.get_attack_range(cls2)) if not cls2.is_empty() else 1
			if _hex_distance(hq_point2, _point(e2)) <= strike:
				immediate_hq_danger += _estimated_soldiers(e2)
	# Harassment gate: a lone kiter camping the HQ's attack range cannot
	# actually KILL a fortified HQ (its counters shred small attackers), but
	# treating every lurker as an emergency froze the whole army into
	# permanent interception — the exact oscillation that loses on the clock.
	# Emergency is real only when the force in striking range could plausibly
	# take the HQ down (roughly matching or exceeding its garrison).
	var own_hq_garrison := 0.0
	if not own_hq.is_empty():
		own_hq_garrison = _estimated_soldiers(own_hq)
	if immediate_hq_danger > 0.0 and immediate_hq_danger >= 1.1 * maxf(120.0, own_hq_garrison):
		phase = "hq_emergency"
		hq_threatened = true
	elif immediate_hq_danger > 0.0:
		hq_threatened = true
	# All-in escalation: a 5-turn contact stall means chips are futile and
	# the clock is the only winner. V2 breaks the equilibrium deliberately.
	var stalled := int(_tendencies.get("stall_turns", 0)) >= 5 and contact
	# ---- V2.1 conversion gate: visible evidence only, no omniscience ----
	# Three doors into the same 6-turn window (all vetoed by HQ danger).
	# Evidence principle (learned from the 0-activation failure): gate terms
	# must be STRUCTURAL battlefield facts, never byproducts of V2's own
	# passivity — an idling standoff army produces no attack offers, so
	# offer-count evidence self-blocks the exact states conversion exists
	# for. Intactness, morale, force ratio, and wall contact are independent
	# of what V2 did last turn.
	# STRONG (t >= 20): intact army >= 2x enemy strength (stale ghosts
	# included, so this understates a true lead), no weak units, whole field
	# above the comfortable morale bar.
	var strong_gate := turn >= CONV_TURN_MIN and own_field >= 3 and own_weak == 0 \
		and _conv_field_morale_ok(ctx, CONV_MORALE_MIN) and enemy_strength > 0.0 \
		and own_strength >= CONV_FORCE_RATIO * enemy_strength
	# CLOCK (t >= 34): the timeout is now the scoring floor, so a failed
	# push costs only a draw — commit at near-parity (>= 0.9x CURRENTLY
	# VISIBLE enemy), tolerating one worn unit. Visible-only is deliberate:
	# stale last-known contacts are frequently already dead, and counting
	# ghosts permanently deflates the lead estimate — an army that won the
	# attrition war never sees itself as ahead and never converts. The
	# morale floor is the hard rout-safety line (per-unit rout_guard still
	# governs action choices): a long REST cycle keeps some unit below the
	# comfortable bar at all times, which must not veto the whole window.
	var clock_gate := turn >= CONV_CLOCK_TURN and own_field >= 3 and own_weak <= 1 \
		and _conv_field_morale_ok(ctx, 25.0) and enemy_visible_strength > 0.0 \
		and own_strength >= CONV_CLOCK_RATIO * enemy_visible_strength
	# SIEGE door (t >= 40): an ASSAULT offer in the turn's pooled legal set
	# is direct visible proof the army stands at the enemy walls — position
	# evidence, non-circular. After t=40 a failed siege costs only what
	# idling costs (a draw), and wall damage is permanent — commit the siege
	# while the morale floor keeps it rout-safe. The fort garrison inflates
	# any force-ratio estimate, so this door keys on position, not numbers.
	var siege_gate := turn >= CONV_SIEGE_TURN and own_field >= 3 \
		and _conv_field_morale_ok(ctx, 25.0) and _turn_offers_assault
	var gate_open := (strong_gate or clock_gate or siege_gate) \
		and phase != "hq_emergency" \
		and immediate_hq_danger < CONV_HQ_MARGIN * maxf(120.0, own_hq_garrison)
	if OS.get_environment("V21_DEBUG") == "1" and turn >= 20:
		print("[V21_GATE] t=%d phase=%s danger=%.0f garrison=%.0f field=%d weak=%d offers=%d own=%.0f enemy=%.0f strong=%s clock=%s siege=%s morale_ok=%s" % [
			turn, phase, immediate_hq_danger, own_hq_garrison, own_field, own_weak,
			_conv_offers_last, own_strength, enemy_strength,
			strong_gate, clock_gate, siege_gate, _conv_field_morale_ok(ctx, CONV_MORALE_MIN)])
	var conv_reason := "gate_closed"
	if gate_open:
		_conv_evidence_turns += 1
		conv_reason = "evidence_%d" % _conv_evidence_turns
	elif _conv_active_turns_left > 0 and phase != "hq_emergency" and not hq_threatened:
		_conv_evidence_turns = 0
	else:
		_conv_evidence_turns = 0
		if _conv_active_turns_left > 0:
			_conv_active_turns_left = 0  # HQ danger kills an active window
			conv_reason = "hq_danger_abort"
	var conv_active := false
	if _conv_active_turns_left > 0:
		conv_active = true
		conv_reason = "active"
		_conv_active_turns_left -= 1
		if _conv_active_turns_left == 0:
			if _conv_recorded_success:
				_conv_successes += 1
			_conv_recorded_success = false
			conv_reason = "window_closed"
	elif gate_open and _conv_evidence_turns >= CONV_STREAK_COMMIT:
		conv_active = true
		conv_reason = CONV_RATIONALE
		_conv_active_turns_left = CONV_COMMIT_TURNS - 1
		_conv_activations += 1
		_conv_trace.append({"t": turn, "lead": snappedf(lead, 0.01), "reason": CONV_RATIONALE})
	_conv_streak = _conv_evidence_turns
	var result := {"own_strength": own_strength, "enemy_strength": enemy_strength,
		"own_field": own_field, "enemy_field": enemy_field,
		"own_weak": own_weak, "enemy_weak": enemy_weak,
		"own_hq_strength": own_hq_strength, "enemy_hq_strength": enemy_hq_strength,
		"enemy_hq_dist": enemy_hq_dist, "enemy_hq_known": not enemy_hq.is_empty(),
		"lead": clampf(lead, -1.0, 1.0), "phase": phase, "contact": contact,
		"turn": turn, "hq_threatened": hq_threatened, "stalled": stalled}
	result["conv_active"] = conv_active
	result["conv_streak"] = _conv_streak
	result["conv_reason"] = conv_reason
	return result


# ------------------------------------------------------------------
# Tactical intents (short-lived, revisable; never fixed openings)
# ------------------------------------------------------------------

func _default_intent(eval: Dictionary) -> Dictionary:
	return {"type": "PRESSURE_HQ", "locus": _mirror_point(Vector2i.ZERO, {}),
		"focus_target_id": "", "formed_turn": int(eval.get("turn", 0)), "ttl": 1,
		"score": 0.0, "note": "fallback_intent"}


func _refresh_intent(ctx: Dictionary, obs: Dictionary, eval: Dictionary, turn: int) -> void:
	if not _intent.is_empty():
		var valid := true
		var reason := ""
		if turn >= int(_intent.get("formed_turn", 0)) + int(_intent.get("ttl", 1)):
			valid = false
			reason = "intent_ttl_expired"
		var focus := str(_intent.get("focus_target_id", ""))
		if valid and not focus.is_empty() \
				and not (ctx["visible_by_id"] as Dictionary).has(focus):
			valid = false
			reason = "focus_target_gone"
		if valid and bool(_intent.get("requires_enemy_hq_known", false)) and not bool(eval.get("enemy_hq_known", false)):
			valid = false
			reason = "enemy_hq_contact_lost"
		if valid and str(_intent.get("type", "")) != "DEFEND_HQ" and bool(eval.get("hq_threatened", false)):
			valid = false
			reason = "hq_emergency_override"
		if valid:
			var scores := _score_intents(ctx, obs, eval)
			var best_alt := -1000.0
			for row_val in scores:
				var row: Dictionary = row_val
				if str(row.get("type", "")) != str(_intent.get("type", "")):
					best_alt = maxf(best_alt, float(row.get("score", 0.0)))
			if best_alt > float(_intent.get("score", 0.0)) + 2.5:
				valid = false
				reason = "expected_value_shifted"
		if not valid:
			_intent = {}
			_replan_reason = reason
	if _intent.is_empty():
		var scores := _score_intents(ctx, obs, eval)
		_candidate_intents = []
		for row_val in scores:
			_candidate_intents.append({"type": (row_val as Dictionary).get("type", ""),
				"score": snappedf(float((row_val as Dictionary).get("score", 0.0)), 0.01)})
		if _candidate_intents.size() > 4:
			_candidate_intents = _candidate_intents.slice(0, 4)
		if not scores.is_empty():
			var chosen: Dictionary = (scores[0] as Dictionary)
			_intent = {"type": str(chosen.get("type", "PRESSURE_HQ")),
				"locus": chosen.get("locus", Vector2i.ZERO),
				"focus_target_id": str(chosen.get("focus_target_id", "")),
				"formed_turn": turn,
				"ttl": int(_v2_params.get("planning_horizon", 1.0)),
				"score": float(chosen.get("score", 0.0)),
				"requires_enemy_hq_known": bool(chosen.get("requires_enemy_hq_known", false)),
				"note": str(chosen.get("note", ""))}
			if _replan_reason.is_empty():
				_replan_reason = "intent_formed:%s" % str(_intent["type"])
		else:
			_intent = _default_intent(eval)


func _score_intents(ctx: Dictionary, obs: Dictionary, eval: Dictionary) -> Array:
	var out: Array = []
	var archetype: String = _archetype
	var tempo := float(_v2_params.get("tempo_bias", 0.6))
	var sacrifice := float(_v2_params.get("sacrifice_tolerance", 0.5))
	var concentration := float(_v2_params.get("concentration_preference", 0.7))
	var conversion := float(_v2_params.get("hq_conversion_pressure", 0.7))
	var lead := float(eval.get("lead", 0.0))
	var turn := int(eval.get("turn", 0))
	var own_hq: Dictionary = ctx["own_hq"]
	var enemy_hq: Dictionary = ctx["enemy_hq"]
	var visible: Array = ctx["visible"]
	# 1) eliminate an exposed high-value enemy
	var pick: Dictionary = {}
	var pick_value := 0.0
	for raw in visible:
		if not raw is Dictionary:
			continue
		var e: Dictionary = raw
		var cls := str(e.get("class", "")).to_lower()
		var danger := 1.45 if cls in ["siege", "archer"] else (1.2 if cls == "cavalry" else (2.4 if cls == "hq" else 1.0))
		var exposure := _reply_ratio(_point(e), _estimated_soldiers(e), ctx)
		var value := danger * _estimated_soldiers(e) * (1.25 - 0.6 * clampf(exposure, 0.0, 1.0))
		if _enemy_fraction(e) < 0.6:
			value *= 1.35
		if value > pick_value:
			pick_value = value
			pick = e
	if not pick.is_empty():
		out.append({"type": "ELIMINATE_HIGH_VALUE", "locus": _point(pick),
			"focus_target_id": str(pick.get("unit_id", "")),
			"score": 3.2 + 0.004 * pick_value + 1.6 * sacrifice + 1.2 * concentration \
				+ (1.2 if archetype in ["OPPORTUNIST", "ATTRITION"] else 0.0),
			"note": "focus %s" % str(pick.get("unit_id", ""))})
	# Route doctrine: the terminal path goes through the enemy's remaining
	# strength. With a visible enemy HQ the lane is the HQ itself; otherwise
	# with contact the army converges on the screen and fights through it;
	# with no contact at all, the public mirror-sector sweep applies.
	var approach: Vector2i = _mirror_point(_point(own_hq) if not own_hq.is_empty() else Vector2i.ZERO, obs)
	if not enemy_hq.is_empty():
		approach = _point(enemy_hq)
	else:
		# --- terminal sector reasoning without a live HQ contact ---
		# Freshest last-known HQ row (legitimate stale fog information, same
		# authority as V0's exploration target).
		var fresh_hq: Dictionary = {}
		var fresh_age := 999
		for raw in (ctx["stale"] as Array):
			if not raw is Dictionary:
				continue
			var s_row: Dictionary = raw
			if str(s_row.get("class", "")).to_lower() != "hq":
				continue
			var age := turn - int(s_row.get("last_seen_turn", 0))
			if age < fresh_age:
				fresh_age = age
				fresh_hq = s_row
		var hq_trace := Vector2i.ZERO
		var have_trace := false
		if not fresh_hq.is_empty():
			hq_trace = _point(fresh_hq)
			have_trace = true
		# Flee-path prediction: a hunted HQ runs from our center of mass.
		# Chase where it is GOING so fast units cut it off at the edge.
		var predicted := hq_trace
		if have_trace:
			var center_of_mass := Vector2i.ZERO
			var cm_count := 0
			for fr_val in (ctx["friendly_list"] as Array):
				if fr_val is Dictionary and str((fr_val as Dictionary).get("class", "")).to_lower() != "hq" 						and int((fr_val as Dictionary).get("soldiers", 0)) > 0:
					center_of_mass += _point(fr_val)
					cm_count += 1
			if cm_count > 0:
				center_of_mass = Vector2i(roundi(float(center_of_mass.x) / cm_count), roundi(float(center_of_mass.y) / cm_count))
				var flee := hq_trace - center_of_mass
				var dir := Vector2i(0, 0)
				if abs(flee.x) >= abs(flee.y):
					dir = Vector2i(1 if flee.x > 0 else -1, 0)
				else:
					dir = Vector2i(0, 1 if flee.y > 0 else -1)
				predicted = hq_trace + dir * mini(3, fresh_age + 2)
			var pbounds: Dictionary = obs.get("map_bounds", {})
			if pbounds.is_empty():
				pbounds = (obs.get("board", {}) as Dictionary).get("dimensions", {})
			if not pbounds.is_empty():
				predicted = Vector2i(clampi(predicted.x, int(pbounds.get("q_min", -99)), int(pbounds.get("q_max", 99))),
					clampi(predicted.y, int(pbounds.get("r_min", -99)), int(pbounds.get("r_max", 99))))
			var own_anchor := _point(own_hq) if not own_hq.is_empty() else Vector2i.ZERO
			if _hex_distance(own_anchor, predicted) > _hex_distance(own_anchor, hq_trace):
				predicted = hq_trace  # never predict it fleeing THROUGH us
		# Conversion state: ahead on material, or the enemy is already down to
		# an HQ and at most one escort (nothing left to "defend" against).
		# STICKY: once conversion starts it survives light lead erosion from
		# harassers — a toggle that flips off every time the kite scratches a
		# unit makes the endgame march never commit and the clock always wins.
		var lead_now := float(eval.get("lead", 0.0))
		var converting := str(eval.get("phase", "parity")) == "ahead" or int(eval.get("enemy_field", 9)) <= 2 			or bool(eval.get("stalled", false))
		if converting:
			_convert_sticky = true
		elif _convert_sticky and (lead_now > 0.05 or int(eval.get("enemy_field", 9)) <= 2):
			converting = true
		if lead_now <= 0.05 and int(eval.get("enemy_field", 9)) > 2:
			_convert_sticky = false
		if str(eval.get("phase", "parity")) == "hq_emergency":
			converting = false
			_convert_sticky = false
		if converting:
			# ARMY terminal sector, best evidence first:
		#   1. FRESH HQ trace (<= 6 turns): sweep the corner nearest it —
			#      a kiting HQ is bounded by the board edge.
			#   2. Enemy army last-known centroid: V1 keeps its units near its
				#      HQ, so where the force was last seen is where the HQ is.
			#      This also catches a besieger that crossed to OUR home.
			#   3. Mirror-sector corner sweep (zero evidence fallback).
			var pb: Dictionary = obs.get("map_bounds", {})
			if pb.is_empty():
				pb = (obs.get("board", {}) as Dictionary).get("dimensions", {})
			var corner := Vector2i.ZERO
			var have_target := false
			if have_trace and fresh_age <= 6 and not pb.is_empty():
				var corners := [Vector2i(int(pb.get("q_min", 0)), int(pb.get("r_min", 0))),
					Vector2i(int(pb.get("q_min", 0)), int(pb.get("r_max", 0))),
					Vector2i(int(pb.get("q_max", 0)), int(pb.get("r_min", 0))),
					Vector2i(int(pb.get("q_max", 0)), int(pb.get("r_max", 0)))]
				var best_d := 1 << 30
				for c_val in corners:
					var c_pt: Vector2i = c_val
					var cd := _hex_distance(hq_trace, c_pt)
					if cd < best_d:
						best_d = cd
						corner = c_pt
					have_target = true
			if not have_target:
				var sp_sum := Vector2i.ZERO
				var sp_count := 0
				for raw in (ctx["stale"] as Array):
					if raw is Dictionary:
						sp_sum += _point(raw)
						sp_count += 1
				if sp_count > 0:
					corner = Vector2i(roundi(float(sp_sum.x) / sp_count), roundi(float(sp_sum.y) / sp_count))
					have_target = true
			if not have_target:
				var own_pt := _point(own_hq) if not own_hq.is_empty() else Vector2i.ZERO
				var mirror_base := _mirror_point(own_pt, obs)
				var sq := 1 if mirror_base.x >= own_pt.x else -1
				var sr := 1 if mirror_base.y >= own_pt.y else -1
				if not pb.is_empty():
					var q_target := int(pb.get("q_max", mirror_base.x)) if sq > 0 else int(pb.get("q_min", mirror_base.x))
					var r_target := int(pb.get("r_max", mirror_base.y)) if sr > 0 else int(pb.get("r_min", mirror_base.y))
					corner = Vector2i(q_target, r_target)
				else:
					corner = mirror_base
			approach = corner
			eval["sweep_mode"] = have_trace and fresh_age <= 6
			if bool(eval["sweep_mode"]):
				eval["sweep_corner"] = corner
			# HUNTERS: the 2 fastest units chase the best available trace —
			# speed lets them exploit freshness the slow front cannot.
			eval["pursuit_point"] = predicted if (have_trace and fresh_age <= 8) else corner
		elif have_trace and fresh_age <= 5:
			approach = predicted
			eval["pursuit_point"] = predicted
		elif bool(eval.get("contact", false)):
			var approach_cluster := _enemy_cluster_centroid(visible)
			if bool(approach_cluster.get("found", false)):
				approach = approach_cluster.get("point", approach)
			eval["pursuit_point"] = approach
		else:
			eval["pursuit_point"] = approach
	# 2) convert a material advantage into terminal pressure
	if lead > 0.15 or (bool(eval.get("enemy_hq_known", false)) and float(eval.get("enemy_hq_dist", 999)) <= 5):
		out.append({"type": "CONVERT_ADVANTAGE",
			"locus": approach,
			"focus_target_id": "", "requires_enemy_hq_known": false,
			"score": 3.0 + 3.4 * lead + 2.2 * conversion + 1.3 * tempo \
				+ (1.1 if archetype in ["AGGRESSIVE", "OPPORTUNIST"] else 0.0),
			"note": "lead %.2f" % lead})
	# 3) open the HQ approach (known HQ, the blocking screen, or the sweep)
	out.append({"type": "PRESSURE_HQ",
		"locus": approach,
		"focus_target_id": "",
		"requires_enemy_hq_known": not enemy_hq.is_empty(),
		"score": 2.2 + 1.8 * tempo + 1.2 * conversion + 0.8 * maxf(0.0, lead) \
			+ (0.9 if not enemy_hq.is_empty() else 0.0) \
			+ (1.0 if archetype in ["AGGRESSIVE", "MANEUVER"] else 0.0),
		"note": "hq lane" if enemy_hq.is_empty() else "hq approach"})
	# 4) break the enemy screen / finish the broken formation. When the
	# enemy is visibly broken this IS the terminal path — annihilate the
	# remaining resistance instead of marching past it.
	var cluster := _enemy_cluster_centroid(visible)
	if bool(cluster.get("found", false)):
		var screen_score := 2.4 + 1.6 * concentration + 1.0 * maxf(0.0, lead) \
			+ (1.1 if archetype in ["ATTRITION", "COUNTERPUNCH"] else 0.0)
		var broken := float(eval.get("enemy_strength", 0.0)) > 0.0 \
			and (float(eval.get("enemy_strength", 0.0)) < 0.7 * float(eval.get("own_strength", 1.0)) \
				or int(eval.get("enemy_field", 0)) < int(eval.get("own_field", 1)))
		if broken:
			screen_score += 3.4  # annihilate the remainder: no recovery, no stall
		out.append({"type": "BREAK_SCREEN", "locus": cluster.get("point", Vector2i.ZERO),
			"focus_target_id": str(cluster.get("weakest_id", "")),
			"score": screen_score,
			"note": "cluster %d" % int(cluster.get("count", 0))})
	# 5) defend the HQ approach. An enemy that can actually strike our HQ
	# next turn is a hard emergency: interception dominates everything.
	var hq_threat_id := ""
	var hq_threat_danger := 0.0
	var hq_threat_sum := 0.0
	if not own_hq.is_empty():
		var hq_point := _point(own_hq)
		for raw in visible:
			if not raw is Dictionary:
				continue
			var e: Dictionary = raw
			var e_cls := str(e.get("class", "")).to_lower()
			var reach := _enemy_reach(e)
			var d := _hex_distance(hq_point, _point(e))
			if d <= reach:
				# Closer = more dangerous. Proximity-weighted strength.
				var danger := _estimated_soldiers(e) * float(reach - d + 1) / float(maxi(1, reach))
				hq_threat_sum += danger
				if danger > hq_threat_danger:
					hq_threat_danger = danger
					hq_threat_id = str(e.get("unit_id", ""))
		var emergency := not hq_threat_id.is_empty()
		if emergency or bool(eval.get("hq_threatened", false)) or (lead < -0.25 and turn > 4):
			var defend_score := 3.6 + 2.4 * float(_v2_params.get("response_conservatism", 0.6)) \
				+ (2.6 if bool(eval.get("hq_threatened", false)) else 0.0) \
				+ (5.5 if emergency else 0.0) \
				+ (1.2 if archetype in ["DEFENSIVE", "COUNTERPUNCH"] else 0.0)
			# A winning position must keep converting. Only a hard emergency —
			# an enemy actually within strike reach of our HQ — pulls a winning
			# army off the offensive.
			if float(eval.get("lead", 0.0)) > 0.22 and not emergency:
				defend_score -= 3.5
				# Hysteresis: light harassment cannot kill a fortified, resting HQ
				# (V1's own siege needed ~20 turns with two units). If the total
				# proximity-weighted threat is small relative to the HQ's garrison
				# strength, the HQ holds the line alone and the field army KEEPS
				# CONVERTING. Abandoning the sweep for every chip attack is how
				# winning positions time out against a kiting enemy.
				var hq_strength := float(eval.get("own_hq_strength", 0.0))
				if hq_strength > 0.0 and hq_threat_sum <= hq_strength * (1.1 + float(_v2_params.get("response_conservatism", 0.6))):
					defend_score -= 7.0
			out.append({"type": "DEFEND_HQ",
				"locus": _point(own_hq),
				"focus_target_id": hq_threat_id,
				"score": defend_score,
				"note": "hq screen" if not emergency else "hq intercept %s" % hq_threat_id})
	# 6) disengage a damaged group while screening
	if int(eval.get("own_weak", 0)) > 0 and (lead < 0.1 or bool(eval.get("hq_threatened", false))):
		var retreat_point := _mirror_point(_point(own_hq) if not own_hq.is_empty() else Vector2i.ZERO, obs)
		out.append({"type": "SCREEN_WITHDRAW", "locus": retreat_point, "focus_target_id": "",
			"score": 2.0 + 1.8 * float(_v2_params.get("response_conservatism", 0.6)) \
				+ 1.1 * float(eval.get("own_weak", 0)) \
				+ (1.2 if archetype in ["DEFENSIVE", "ATTRITION"] else 0.0),
			"note": "preserve %d" % int(eval.get("own_weak", 0))})
	# 7) exploit the weak flank (opponent's match-local tendency is weak
	# evidence). The flank is a LANES choice around the enemy side of the
	# board — it must never point units at the back map edge.
	var weak_flank := _weak_flank_point(ctx, obs, eval)
	if weak_flank.get("found", false):
		out.append({"type": "EXPLOIT_FLANK", "locus": weak_flank.get("point", Vector2i.ZERO),
			"focus_target_id": "",
			"score": 1.9 + 1.3 * tempo + 0.9 * float(weak_flank.get("evidence", 0.0)) \
				+ (1.3 if archetype in ["MANEUVER", "OPPORTUNIST"] else 0.0),
			"note": "flank bias %.2f" % float(weak_flank.get("evidence", 0.0))})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if is_equal_approx(float(a["score"]), float(b["score"])):
			return str(a["type"]) < str(b["type"])
		return float(a["score"]) > float(b["score"]))
	return out


# ------------------------------------------------------------------
# Force allocation (plan + reservation accounting)
# ------------------------------------------------------------------

func _form_plan(ranked: Array, ctx: Dictionary, eval: Dictionary, intent: Dictionary) -> void:
	_plan = []
	var planned_units: Dictionary = {}
	var remaining_need: Dictionary = {}
	var locus: Vector2i = intent.get("locus", Vector2i.ZERO)
	# Priority order: terminal/focus attacks, then attacks that finish a kill,
	# then intent-aligned advances, then everything else.
	var attacks: Array = []
	var moves: Array = []
	var others: Array = []
	for row_val in ranked:
		var row: Dictionary = row_val
		if float(row["score"]) <= -9000.0 or float(row["score"]) >= 9000.0:
			_plan.append({"candidate_id": str(row["candidate_id"]),
				"unit_id": str((row["candidate"] as Dictionary).get("unit_id", "")),
				"role": "TERMINAL", "target_id": str((row["candidate"] as Dictionary).get("target_id", ""))})
			planned_units[str((row["candidate"] as Dictionary).get("unit_id", ""))] = true
			continue
		var kind := str((row["candidate"] as Dictionary).get("action_type", "")).to_upper()
		if kind == "ATTACK" or kind == "ASSAULT":
			attacks.append(row)
		elif kind == "MOVE":
			moves.append(row)
		else:
			others.append(row)
	for row_val in attacks:
		var row: Dictionary = row_val
		var c: Dictionary = row["candidate"]
		var uid := str(c.get("unit_id", ""))
		if planned_units.has(uid):
			continue
		var tid := str(c.get("target_id", ""))
		var key := tid if not tid.is_empty() else str(c.get("stronghold_id", "?"))
		var target: Dictionary = (ctx["visible_by_id"] as Dictionary).get(tid, {})
		var est := _estimated_soldiers(target) if not target.is_empty() else 300.0
		var committed := float(_commitments.get(key, 0.0)) + float(remaining_need.get(key, 0.0))
		if committed >= est and key != str(_intent.get("focus_target_id", "")) and not bool(c.get("guaranteed_enemy_hq_kill", false)):
			continue  # already saturated by prior commitment — send help elsewhere
		var mid := 0.5 * (maxf(0.0, float(c.get("expected_enemy_casualties_min", 0.0))) \
			+ maxf(0.0, float(c.get("expected_enemy_casualties_max", 0.0))))
		_plan.append({"candidate_id": str(row["candidate_id"]), "unit_id": uid,
			"role": "ATTACK", "target_id": tid})
		planned_units[uid] = true
		remaining_need[key] = committed + mid
	for row_val in moves:
		var row: Dictionary = row_val
		var c: Dictionary = row["candidate"]
		var uid := str(c.get("unit_id", ""))
		if planned_units.has(uid):
			continue
		var dest := _array_point(c.get("destination", []))
		var own: Dictionary = (ctx["friendly"] as Dictionary).get(uid, {})
		var progress := -999
		if not own.is_empty():
			progress = _hex_distance(_point(own), locus) - _hex_distance(dest, locus)
		var role := "ADVANCE"
		var screening := str(_intent.get("type", "")) in ["DEFEND_HQ", "SCREEN_WITHDRAW"]
		if screening:
			role = "SCREEN"
		# Never plan a lateral or backward shuffle: unspent moves in the plan
		# should be real advances (or real screen closes), not dithering.
		if not screening and progress <= 0:
			continue
		_plan.append({"candidate_id": str(row["candidate_id"]), "unit_id": uid,
			"role": role, "target_id": "", "progress": progress})
		planned_units[uid] = true
	for row_val in others:
		var row: Dictionary = row_val
		var c: Dictionary = row["candidate"]
		var uid := str(c.get("unit_id", ""))
		if planned_units.has(uid):
			continue
		var kind := str(c.get("action_type", "")).to_upper()
		if kind == "END_TURN" or kind == "WAIT":
			continue
		# Deliberate passivity (REST/FORTIFY/DISMANTLE) is never part of an
		# offensive plan, so it earns NO plan bonus — otherwise holding scores
		# above advancing and the army stalls in a winning position.
		_plan.append({"candidate_id": str(row["candidate_id"]), "unit_id": uid,
			"role": "PASSIVE", "target_id": ""})
		planned_units[uid] = true
		break


func _plan_ids() -> Array:
	var out: Array = []
	for entry_val in _plan:
		out.append(str((entry_val as Dictionary).get("candidate_id", "")))
	return out


# ------------------------------------------------------------------
# Per-candidate composite scoring
# ------------------------------------------------------------------

func _score_candidate(c: Dictionary, ctx: Dictionary, obs: Dictionary, eval: Dictionary, intent: Dictionary) -> Dictionary:
	var kind := str(c.get("action_type", "")).to_upper()
	var uid := str(c.get("unit_id", ""))
	var own: Dictionary = (ctx["friendly"] as Dictionary).get(uid, {})
	var own_strength := _estimated_soldiers(own) if not own.is_empty() else 300.0
	var features := _features(c, ctx, obs)
	var base := _score(features)
	# Terminal truth dominates everything and is never scaled or traded away.
	if absf(base) >= 9000.0:
		return {"score": base, "features": features, "terms": {"terminal": base}}
	var score := 0.35 * base  # frozen V0 prior, deliberately weighted down
	var terms: Dictionary = {"v0_prior": snappedf(0.35 * base, 0.01)}
	var concentration := float(_v2_params.get("concentration_preference", 0.7))
	var sacrifice := float(_v2_params.get("sacrifice_tolerance", 0.5))
	# V2.1: conservatism is the seeded population value for ordinary play;
	# a bounded LOW floor applies ONLY inside conversion windows
	# (V2.1_CONVERSION). Outside windows the planner is byte-identical to V2.
	var conservatism := float(_v2_params.get("response_conservatism", 0.6))
	if bool(eval.get("conv_active", false)):
		conservatism = minf(conservatism, 0.30)
	var tempo := float(_v2_params.get("tempo_bias", 0.6))
	var conversion := float(_v2_params.get("hq_conversion_pressure", 0.7))
	var phase := str(eval.get("phase", "parity"))
	# Winning = material lead OR a broken enemy formation, and only with real
	# enemy evidence. Winning means convert, not reshuffle: safe-forever play
	# is not winning — but neither is marching into fog on ignorance.
	var winning := phase == "ahead" \
		or (float(eval.get("enemy_strength", 0.0)) > 0.0 \
			and float(eval.get("enemy_strength", 0.0)) < 0.6 * float(eval.get("own_strength", 1.0)) \
			and int(eval.get("enemy_field", 0)) > 0) \
		or (int(eval.get("enemy_field", 0)) > 0 \
			and int(eval.get("enemy_field", 0)) <= int(eval.get("own_field", 1)) - 2)
	if phase == "hq_emergency":
		winning = false
	if bool(eval.get("stalled", false)):
		# A confirmed stalemate is a losing trajectory: the clock decides.
		winning = true
	var locus: Vector2i = intent.get("locus", Vector2i.ZERO)
	# Force allocation at action level: a unit that already acted this turn
	# yields to untouched units unless the action is decisive.
	var acted := int(_acted_this_turn.get(uid, 0))
	if acted > 0 and kind != "ATTACK" and kind != "ASSAULT":
		# Move->strike sequences are excellent play; only filler actions on an
		# already-busy unit yield to untouched units.
		var spread := 0.8 * float(acted)
		score -= spread
		terms["unit_spread"] = -snappedf(spread, 0.01)
	var is_hq_unit := str(own.get("class", "")).to_lower() == "hq"
	if kind == "ATTACK" or kind == "ASSAULT":
		# Wall assault is the ONLY path to a garrisoned enemy: previewed
		# troop casualties stay zero until the wall breaks, so generic
		# scoring reads it as a futile chip. It is the opposite — permanent
		# structural progress toward the terminal condition. Besieging the
		# fortress outranks every positional consideration.
		if kind == "ASSAULT":
			score += 9.0
			terms["wall_assault"] = 9.0
			var tgt_row: Dictionary = (ctx["visible_by_id"] as Dictionary).get(str(c.get("target_id", "")), {})
			if str(tgt_row.get("class", "")).to_lower() == "hq":
				score += 4.0
				terms["wall_assault_hq"] = 4.0
		var tid := str(c.get("target_id", ""))
		var target: Dictionary = (ctx["visible_by_id"] as Dictionary).get(tid, {})
		if target.is_empty() and kind == "ATTACK":
			score -= 8.0
			terms["no_visible_target"] = -8.0
		var est := _effective_est(tid, target) if not target.is_empty() else 300.0
		var min_e := maxf(0.0, float(c.get("expected_enemy_casualties_min", 0.0)))
		var max_e := maxf(min_e, float(c.get("expected_enemy_casualties_max", 0.0)))
		var mid_e := 0.5 * (min_e + max_e)
		var min_f := maxf(0.0, float(c.get("expected_friendly_casualties_min", 0.0)))
		var max_f := maxf(min_f, float(c.get("expected_friendly_casualties_max", 0.0)))
		var mid_f := 0.5 * (min_f + max_f)
		var tclass := str(target.get("class", "")).to_lower() if not target.is_empty() else "stronghold"
		var danger := 1.45 if tclass in ["siege", "archer"] else (1.2 if tclass == "cavalry" else (2.4 if tclass == "hq" else 1.0))
		var key := tid if not tid.is_empty() else str(c.get("stronghold_id", "?"))
		var committed := float(_commitments.get(key, 0.0))
		var needed := maxf(0.0, est - committed)
		# Kill / focus-fire value with explicit diminishing returns.
		var kill := 0.0
		if needed <= 0.0:
			kill = 0.0
		elif min_e >= needed:
			kill = 1.0
		else:
			kill = clampf(mid_e / maxf(1.0, needed), 0.0, 1.0)
		# Engaging is baseline good play — but only if the attack DOES something.
		# Chipping 1% off a fortress unit turn after turn is not play; futile
		# chips score near WAIT so the unit finds a better use.
		var damage_fraction := mid_e / maxf(100.0, est)
		var futile := kill < 0.05 and damage_fraction < 0.06 and tclass != "hq" and kind != "ASSAULT"
		var engage_base := 0.4 if futile else (3.2 if mid_f <= 0.5 else 2.2)
		score += engage_base
		terms["engage"] = snappedf(engage_base, 0.01)
		if futile:
			terms["futile_chip"] = -1.8
		var kill_value := 9.0 * kill * danger * (0.6 + 0.4 * concentration)
		score += kill_value
		terms["kill_value"] = snappedf(kill_value, 0.01)
		var damage_value := 7.5 * clampf(mid_e / maxf(100.0, est), 0.0, 1.0) * danger
		score += damage_value
		terms["damage_value"] = snappedf(damage_value, 0.01)
		# Free damage: strikes the preview says draw no casualties of our own
		# (ranged fire above all). Troop losses NEVER heal, and every turn of
		# unanswered fire is permanent material gain — the side that shoots
		# every turn wins the attrition race inside the turn limit.
		var free_damage := mid_f <= 0.5 and mid_e > 0.0
		if free_damage and tclass != "hq" and not futile:
			score += 4.5
			terms["free_damage"] = 4.5
		# Favorable trade: the preview already encodes class matchups. Reward
		# strikes that deal clearly more than they take (cavalry or infantry
		# into archers); the attrition/counter terms punish the reverse.
		if not free_damage and mid_e >= mid_f + 40.0 and tclass != "hq":
			score += 1.8
			terms["favorable_trade"] = 1.8
		# Pursue broken groups: finishing a weakened unit removes a whole
		# future attack from the board.
		if not target.is_empty() and est / maxf(1.0, _class_baseline(tclass)) < 0.55:
			var finish := 2.2 * kill + 1.2
			score += finish
			terms["finish_weakened"] = snappedf(finish, 0.01)
		# Concentrate on the weakest target in range: kills compound, chips
		# evaporate against REST healing. Every attacker leans toward the
		# lowest-remaining-strength enemy it can actually hurt.
		if not target.is_empty() and tclass != "hq":
			var weak_bias := 3.0 * (1.0 - clampf(est / maxf(1.0, _class_baseline(tclass)), 0.0, 1.0))
			if bool(eval.get("stalled", false)):
				weak_bias *= 2.0  # kills are the only exit from the stall
			score += weak_bias
			terms["weakened_target"] = snappedf(weak_bias, 0.01)
		if tid == str(intent.get("focus_target_id", "")) and not tid.is_empty():
			score += 2.2 + 1.8 * concentration
			terms["focus_alignment"] = 2.2 + 1.8 * concentration
		# Threat removal: a unit that can strike our HQ is the most urgent
		# target on the board — killing it protects the terminal condition.
		if not (ctx["own_hq"] as Dictionary).is_empty() and not target.is_empty():
			var hq_point := _point(ctx["own_hq"])
			if _hex_distance(_point(target), hq_point) <= _enemy_reach(target):
				var guard := 3.4 + 2.2 * conservatism
				if phase == "hq_emergency":
					guard += 3.0 * clampf(damage_fraction * 8.0, 0.0, 1.0)  # real damage or nothing
				score += guard
				terms["hq_intercept"] = snappedf(guard, 0.01)
		# In a hard emergency, finishing the attacker beats everything but the
		# terminal win itself — but ONLY in proportion to the damage actually
		# dealt. Flat bonuses turned futile chips into the highest-scored
		# actions on the board and lost the damage race.
		if phase == "hq_emergency" and tid == str(intent.get("focus_target_id", "")) and not tid.is_empty():
			var focus_now := 5.0 * kill + 4.0 * damage_fraction
			score += focus_now
			terms["emergency_focus"] = snappedf(focus_now, 0.01)
		# Commitment economics: earlier friendly attacks this turn shrink what
		# is still needed. A saturated target needs NO more raw damage, but the
		# finishing blow is still valuable insurance (combat variance) — the
		# old flat overkill penalty suppressed every same-turn kill and let
		# REST healing erase all chip damage. Focus-fire must COMPOUND.
		if needed <= 0.0:
			var over := 1.2 if tclass != "hq" else 0.3
			score -= over
			terms["overkill"] = -over
			if mid_e >= 20.0:
				var insurance := 2.8
				score += insurance
				terms["kill_insurance"] = insurance
		elif committed > 0.0 and mid_e >= needed:
			var finishing := 2.8
			score += finishing
			terms["finishing_blow"] = finishing
		elif mid_e > needed * 1.6 and tclass != "hq":
			var waste := 0.4 * (mid_e - needed * 1.6) / maxf(1.0, needed)
			score -= waste
			terms["surplus_commitment"] = -snappedf(waste, 0.01)
		# Trade / sacrifice evaluation: survival is not the objective.
		var suicide := min_f >= own_strength
		var expected_death := max_f >= own_strength
		var gain := mid_e + (600.0 if tclass == "hq" else 0.0)
		# The HQ is the terminal loss condition. It trades shots only to score
		# a real kill; otherwise it fortifies and lets field units fight.
		if is_hq_unit and kill < 0.5:
			# The HQ NEVER joins a grinding melee. Its attack is weak, its
			# defense is the game, and counterattacks on it are how V1 wins.
			# Only a genuine kill chance justifies an HQ swing.
			var hq_reckless := 14.0
			score -= hq_reckless
			terms["hq_reckless_attack"] = -hq_reckless
		if suicide:
			var justified := (tclass == "hq" and kill >= 0.5) \
				or (kill >= 0.9 and gain >= own_strength * (1.25 - sacrifice)) \
				or (_soldier_fraction(own) < 0.35 and gain >= own_strength * (0.85 - 0.5 * sacrifice))
			if justified:
				var reward := 3.0 + 3.5 * sacrifice + (2.5 if tclass == "hq" else 0.0)
				score += reward
				terms["calculated_sacrifice"] = snappedf(reward, 0.01)
			else:
				score -= 30.0
				terms["pointless_suicide"] = -30.0
		elif expected_death:
			var risk_cost := (4.5 - 3.2 * sacrifice) * clampf(max_f / maxf(50.0, own_strength), 0.0, 1.0)
			if kill >= 0.9 and danger >= 1.2:
				risk_cost *= 0.35
			if tclass == "hq":
				risk_cost *= 0.4
			score -= risk_cost
			terms["exposure_cost"] = -snappedf(risk_cost, 0.01)
		else:
			var attr := 1.6 * clampf(mid_f / maxf(50.0, own_strength), 0.0, 1.0)
			score -= attr
			terms["attrition"] = -snappedf(attr, 0.01)
		# Rout discipline: a badly shocked unit that keeps brawling will roll
		# off the legal pool entirely (rout is permanent in this ruleset). It
		# swings only for real kills or the terminal siege; otherwise resting
		# or disengaging scores higher.
		var self_morale := _own_morale(uid)
		# V2.1 (m161/167): the ASSAULTING garrison-breakers are the real siege —
		# rout_guard must never suppress fire at wall assaulters (our own ASSAULT
		# in return, or ATTACKs on enemies pressed against our own walls) while
		# our own fort is under breach.
		var at_own_walls := false
		if not target.is_empty() and not (ctx["own_hq"] as Dictionary).is_empty() \
				and _hex_distance(_point(target), _point(ctx["own_hq"])) <= 2:
			at_own_walls = true
		if self_morale < 45.0 and tclass != "hq" and kill < 0.6 \
				and not (kind == "ASSAULT" and str(c.get("garrison_target_id", "")) != "") \
				and not at_own_walls:
			var rout_guard := 2.4 + 2.6 * clampf((45.0 - self_morale) / 45.0, 0.0, 1.0)
			score -= rout_guard
			terms["rout_guard"] = -snappedf(rout_guard, 0.01)
		# Bleeding attack: chipping a strong defender we cannot kill, while it
		# will hit back hard and its side REST-heals the damage away, is a net
		# loss. This is exactly how an even fight becomes a lost attrition
		# race. Hold, group, and strike when the ledger says the kill is on.
		if not free_damage and kill < 0.25 and mid_e < 0.25 * est and tclass != "hq" \
				and _reply_strength(_point(own), own_strength, ctx) > 0.9 * own_strength:
			var bleed := 1.2
			score -= bleed
			terms["bleeding_attack"] = -bleed
		if tclass == "hq":
			var hq_bonus := 2.0 + 3.0 * conversion + 1.5 * clampf(kill, 0.0, 1.0)
			if bool(eval.get("conv_active", false)):
				# Committed conversion: the fortress IS the objective. Late in the
				# window the clock, not comfort, is the binding constraint.
				hq_bonus += 2.0 + 2.0 * clampf((float(int(eval.get("turn", 0))) - 40.0) / 18.0, 0.0, 1.0)
			score += hq_bonus
			terms["hq_pressure"] = snappedf(hq_bonus, 0.01)
		# One-ply enemy response: firing keeps us in place — who can hit back?
		# Positional risk applies to every action from this hex alike, so it is
		# weighted lightly here; large exposure still dominates via focus risk.
		# A confirmed stall is an order to SHOOT, not to march: with permanent
		# casualties the "futile chip" equilibrium is a myth — attrition decides.
		if bool(eval.get("stalled", false)) and tclass != "hq":
			score += 3.5
			terms["stall_breaker"] = 3.5
		# Endgame hunt: striking the enemy HQ is the whole plan once the clock
		# is the real enemy — even a trade into its screen buys conversion.
		if bool((eval.get("hunt", {}) as Dictionary).get("active", false)) and tclass == "hq":
			score += 5.0
			terms["hunt_assault"] = 5.0
			if not target.is_empty() and _hex_distance(_point(target), (eval["hunt"] as Dictionary)["point"]) <= 3:
				score += 2.0
				terms["hunt_screen_clear"] = 2.0
			elif not target.is_empty():
				# Hunting away from the anchor pulls the line apart; fire at the
				# besieged sector instead of chasing kites across the board.
				score -= 2.5
				terms["hunt_offaxis_fire"] = -2.5
		# Siege clock: late in the hunt, ANY fire into the anchor sector is
		# conversion pressure — the fortress garrison cannot out-heal a siege.
		if bool((eval.get("hunt", {}) as Dictionary).get("active", false)) and tclass != "hq" \
				and not target.is_empty() \
				and _hex_distance(_point(target), (eval["hunt"] as Dictionary)["point"]) <= 3:
			var urg := 1.5 + 4.0 * clampf((float(int(eval.get("turn", 0))) - 38.0) / 18.0, 0.0, 1.0)
			score += urg
			terms["hunt_siege"] = snappedf(urg, 0.01)
		var reply := _reply_strength(_point(own), own_strength, ctx)
		var reply_ratio := reply / maxf(100.0, own_strength)
		var counter := conservatism * 1.1 * clampf(reply_ratio, 0.0, 2.0)
		if bool(eval.get("conv_active", false)):
			counter *= CONV_RISK_DISCOUNT  # committed line: bounded risk discount
		if not free_damage:
			score -= counter
			terms["counterattack_risk"] = -snappedf(counter, 0.01)
		# Firing from the line adds no exposure of its own — the real danger of
		# standing in reach is already priced by counter/attrition/suicide terms
		# above. This penalty on every ATTACK from a contested hex is what
		# benched a whole army while the enemy archer took free shots for forty
		# straight turns.
		if not free_damage and reply >= own_strength and not (tclass == "hq" and kill >= 0.5):
			var ffe := 6.0 * conservatism
			if bool(eval.get("conv_active", false)):
				ffe *= CONV_RISK_DISCOUNT
			score -= ffe
			terms["focus_fire_exposure"] = -snappedf(ffe, 0.01)
	elif kind == "MOVE":
		var dest := _array_point(c.get("destination", []))
		var origin := _point(own)
		# Sweep lanes: converging on one corner hex lets a kiter dodge in the
		# adjacent fog forever. Each searcher patrols its own lane along the
		# enemy edge so the front pins the kite against the board boundary.
		var effective_locus := locus
		if bool(eval.get("sweep_mode", false)):
			effective_locus = _sweep_point(uid, eval.get("sweep_corner", locus), obs, ctx["own_hq"])
		# Dedicated pursuit detachment: the 2 fastest units keep hunting the
		# enemy HQ sector even when the rest of the army turns to defend.
		# Without a conversion detachment the whole army oscillates between
		# the kiting HQ and the harassers — and catches neither.
		if (ctx["enemy_hq"] as Dictionary).is_empty() and eval.has("pursuit_point") \
				and uid in _hunter_units(ctx) \
				and (str(eval.get("phase", "parity")) == "ahead" \
					or int(eval.get("enemy_field", 9)) <= 2):
			# With the enemy HQ unlocated and at most an HQ+escort left, there
			# is nothing meaningful to defend — a screen cannot win the game,
			# only the hunt can. Parity against a kite is still a hunt.
			effective_locus = eval["pursuit_point"]
		# Sticky conversion locks the whole field army onto the sweep lanes.
		# Chasing the kiting escort with the main body is exactly the stall
		# the corner sweep exists to end; only a genuine HQ emergency lifts it.
		if _convert_sticky and str(eval.get("phase", "parity")) != "hq_emergency" \
				and (ctx["enemy_hq"] as Dictionary).is_empty():
			if bool(eval.get("sweep_mode", false)):
				effective_locus = _sweep_point(uid, eval.get("sweep_corner", locus), obs, ctx["own_hq"])
			elif eval.has("pursuit_point"):
				effective_locus = eval["pursuit_point"]
		# The HQ is the terminal loss condition — it anchors unless it must flee.
		if str(own.get("class", "")).to_lower() == "hq":
			var hq_danger := _reply_strength(origin, own_strength, ctx)
			if hq_danger < own_strength:
				var anchor_pen := 12.0
				score -= anchor_pen
				terms["hq_anchor"] = -anchor_pen
				return {"score": score, "features": features, "terms": terms}
			var flee := clampf(float(_hex_distance(origin, effective_locus) - _hex_distance(dest, effective_locus)), -3.0, 3.0) * -1.5
			score += flee
			terms["hq_flee"] = snappedf(flee, 0.01)
			return {"score": score, "features": features, "terms": terms}
		# Endgame hunt overrides everything short of an HQ emergency: past
		# mid-game, convergence on the enemy HQ sector beats maneuvering —
		# the clock is the real enemy, not the remnants.
		if bool((eval.get("hunt", {}) as Dictionary).get("active", false)) \
				and str(eval.get("phase", "parity")) != "hq_emergency" \
				and str(own.get("class", "")).to_lower() != "hq":
			var hunt_point: Vector2i = (eval["hunt"] as Dictionary)["point"]
			# Converged on a static anchor with no enemy in sight: stack-camping
			# one hex lets a faster HQ kite the whole mass forever. Units on the
			# anchor fan out into sweep lanes around the corner so the front
			# pins the kite against the board edge and forces contact.
			if (ctx["visible"] as Array).is_empty() \
					and _hex_distance(origin, hunt_point) <= 1:
				hunt_point = _sweep_point(uid, hunt_point, obs, ctx["own_hq"])
			effective_locus = hunt_point
			var hunt_progress := _hex_distance(origin, hunt_point) - _hex_distance(dest, hunt_point)
			var hunt_gain := (3.2 + 2.4 * tempo) * clampf(float(hunt_progress), 0.0, 2.0)
			score += hunt_gain
			terms["hunt_push"] = snappedf(hunt_gain, 0.01)
		# Anti-oscillation: revisiting a hex this turn (or ping-ponging between
		# two hexes across turns) is wasted motion.
		var visited: Array = _visited_this_turn.get(uid, [])
		if str(dest) in visited:
			var revisit := 3.5
			score -= revisit
			terms["revisit"] = -revisit
		var recent: Array = _recent_destinations.get(uid, [])
		if recent.size() >= 2 and str(dest) == str(recent[recent.size() - 2]):
			var pingpong := 2.6
			score -= pingpong
			terms["pingpong"] = -pingpong
		var progress := _hex_distance(origin, effective_locus) - _hex_distance(dest, effective_locus)
		var objective := clampf(float(progress), -2.0, 2.0) * (1.4 + 1.3 * tempo)
		score += objective
		terms["intent_progress"] = snappedf(objective, 0.01)
		# Conversion: pushing the terminal objective outranks safety when the
		# enemy formation is already broken.
		if winning and progress > 0:
			var push_scale := 1.6 + 2.4 * conversion
			if bool(eval.get("stalled", false)):
				push_scale *= 1.25  # stall-breaking is fire-led; marching only supports it
			var convert_push := minf(push_scale * clampf(float(progress), 0.0, 2.0), 6.0)
			score += convert_push
			terms["conversion_push"] = snappedf(convert_push, 0.01)
		# V2.1 preservation fallback (m126): a field army ground down to <= 2
		# units facing >= 1.6x its remaining strength must go home, not drag
		# the HQ's last screen into a losing push.
		var field_units := 0
		var field_strength := 0.0
		for raw_f in (ctx["friendly_list"] as Array):
			if not raw_f is Dictionary:
				continue
			var uf: Dictionary = raw_f
			if int(uf.get("soldiers", 0)) <= 0 or str(uf.get("class", "")).to_lower() == "hq":
				continue
			field_units += 1
			field_strength += _estimated_soldiers(uf)
		if not is_hq_unit and field_units <= 2 \
				and float(eval.get("enemy_strength", 0.0)) >= 1.6 * maxf(1.0, field_strength) \
				and str(eval.get("phase", "parity")) != "hq_emergency":
			var home: Dictionary = ctx["own_hq"]
			var fallback := 6.0 if _hex_distance(dest, _point(home)) < _hex_distance(origin, _point(home)) else -5.0
			score += fallback
			terms["preservation_fallback"] = snappedf(fallback, 0.01)
		# V2.1 objective lunge: inside a committed window, closing distance to
		# the objective outranks lateral maneuver — the anti-"28% MOVE going
		# nowhere" term. Urgency scales with the remaining clock: at t50+ the
		# push must beat clump/formation glue (~+20) or the army stalls two
		# hexes short of the fortress and draws (m3 failure mode).
		if bool(eval.get("conv_active", false)) and not is_hq_unit:
			var conv_locus: Vector2i = (eval["hunt"] as Dictionary).get("point", locus)
			var lunge_scale := 2.2 + 3.0 * clampf((float(int(eval.get("turn", 0))) - 40.0) / 18.0, 0.0, 1.0)
			var lunge := lunge_scale * clampf(float(_hex_distance(origin, conv_locus) - _hex_distance(dest, conv_locus)), -1.0, 1.0)
			score += lunge
			terms["conv_lunge"] = snappedf(lunge, 0.01)
		# Local superiority accounting at the destination.
		var friends := _nearby_strength(dest, ctx["friendly_list"], uid, 2)
		var enemies := _nearby_strength(dest, ctx["visible"], "", 2)
		var margin := (friends + own_strength) - enemies
		if enemies > 0.0:
			var superiority := clampf(margin / maxf(100.0, enemies), -1.5, 1.5) * (1.2 + 1.1 * concentration)
			score += superiority
			terms["local_superiority"] = snappedf(superiority, 0.01)
		# One-ply enemy response at the destination — moderated by local
		# support. Exposure alone must not bench an army while its HQ burns:
		# standing off is also fatal when the terminal condition is under fire.
		var reply := _reply_strength(dest, own_strength, ctx)
		var support := _nearby_strength(dest, ctx["friendly_list"], uid, 3)
		# Local initiative: closed fronts stall into clock draws. A unit that
		# is ALREADY engaged (replies to its CURRENT hex too) moves through
		# contested space with confidence instead of paying full exposure —
		# with a weaker local position it must break contact and regroup,
		# with even or better it presses the fight.
		var current_reply := _reply_strength(origin, own_strength, ctx)
		var current_support := _nearby_strength(origin, ctx["friendly_list"], uid, 3)
		var net_current := maxf(0.0, current_reply - 0.7 * current_support)
		var local_initiative := net_current >= 100.0
		if local_initiative:
			reply = maxf(reply, net_current * 0.55)
		var net_reply := maxf(0.0, reply - 0.7 * support)
		var reply_ratio := net_reply / maxf(100.0, own_strength)
		var emergency_discount := 0.45 if phase == "hq_emergency" else 1.0
		# A materially winning army accepts contact risk: it needs conversions,
		# not safety. Loss-averse pushing is how winning positions time out.
		var winning_discount := 0.55 if winning else 1.0
		if bool(eval.get("stalled", false)):
			winning_discount = 0.3  # all-in: the equilibrium IS the loss
		if bool((eval.get("hunt", {}) as Dictionary).get("active", false)):
			winning_discount = minf(winning_discount, 0.35)  # hunting accepts contact
		var exposure := conservatism * 2.2 * clampf(reply_ratio, 0.0, 2.0) * emergency_discount * winning_discount
		score -= exposure
		terms["exposure"] = -snappedf(exposure, 0.01)
		if net_reply >= own_strength and not (local_initiative and enemies <= net_current):
			var focus_risk := 4.5 * conservatism * emergency_discount
			if phase == "ahead" and str(intent.get("type", "")) in ["CONVERT_ADVANTAGE", "PRESSURE_HQ"]:
				focus_risk *= 0.55  # conversion pressure accepts some risk
			if sacrifice > 0.6 and _soldier_fraction(own) < 0.35:
				focus_risk *= 0.6
			score -= focus_risk
			terms["focus_fire_exposure"] = -snappedf(focus_risk, 0.01)
		# Interception: in an HQ emergency, closing on the attacker is worth
		# real risk — losing the HQ is immediate defeat.
		if phase == "hq_emergency" and not (ctx["visible_by_id"] as Dictionary).is_empty():
			var threat_id := str(intent.get("focus_target_id", ""))
			var threat: Dictionary = (ctx["visible_by_id"] as Dictionary).get(threat_id, {})
			if not threat.is_empty():
				var strike := int(CombatCalculatorCls.get_attack_range(str(own.get("class", "")).to_lower()))
				var march := 2 if str(own.get("class", "")).to_lower() not in ["cavalry", "scout"] else 3
				var can_hit_now := _hex_distance(dest, _point(threat)) <= strike
				var can_hit_next := _hex_distance(dest, _point(threat)) <= strike + march
				# Break contact: a locally weaker engaged unit withdrawing from
				# enemy reach rescues itself instead of dying for nothing.
				if can_hit_now:
					var intercept := 4.2 + 2.0 * conservatism
					score += intercept
					terms["intercept_close"] = snappedf(intercept, 0.01)
				elif can_hit_next:
					var approach := 2.4 + 1.2 * conservatism
					score += approach
					terms["intercept_approach"] = snappedf(approach, 0.01)
		# Weakened units pull back while the fight is live; once the enemy is
		# broken, damaged units pressing the objective is worth the risk.
		var near_old := _nearest_distance(origin, ctx["visible"])
		var near_new := _nearest_distance(dest, ctx["visible"])
		var contact_now := near_old <= 1 and near_old < 999
		if _soldier_fraction(own) < 0.35 and not winning:
			if near_new < near_old:
				var retreat := (3.2 - 2.2 * sacrifice) * (0.6 + 0.8 * conservatism)
				# V2.1: inside a conversion window a bounded retreat penalty is
				# waived (commitment persistence); full preservation outside.
				if bool(eval.get("conv_active", false)) and retreat < CONV_RETREAT_FREE:
					retreat = 0.0
				score -= retreat
				terms["weakened_retreat"] = -snappedf(retreat, 0.01)
			elif near_new > near_old:
				score += 1.4
				terms["weakened_retreat"] = 1.4
		elif contact_now and near_new > near_old and net_current < 100.0:
			# Break contact: a locally weaker engaged unit withdrawing from
			# enemy reach rescues itself instead of dying for nothing.
			var break_bonus := 2.6
			score += break_bonus
			terms["break_contact"] = break_bonus
		# Screening role during defensive intents keeps guards near the locus.
		if str(_intent.get("type", "")) in ["DEFEND_HQ", "SCREEN_WITHDRAW"]:
			var anchor := _hex_distance(dest, locus)
			var anchor_term := clampf(float(_hex_distance(origin, locus) - anchor), -2.0, 2.0) * 1.1
			score += anchor_term
			terms["screen_anchor"] = snappedf(anchor_term, 0.01)
			# A unit already holding the line must not jitter between hexes at
			# the same distance from the locus. Holding is the assignment.
			if _hex_distance(origin, locus) <= 1 and anchor_term <= 0.0 					and not bool(eval.get("stalled", false)):
				var hold_line := 2.2
				score -= hold_line
				terms["hold_the_line"] = -hold_line
		# Tempo: ahead means convert, not reshuffle. Moves that gain nothing
		# toward the objective while ahead are dead time.
		if (phase == "ahead" or winning) and progress <= 0:
			var drag := 1.4 * tempo
			score -= drag
			terms["tempo_drag"] = -snappedf(drag, 0.01)
	elif kind == "WAIT" or kind == "END_TURN":
		var idle := 1.2 + 1.4 * tempo
		if phase == "ahead":
			idle += 1.0
		if bool((eval.get("hunt", {}) as Dictionary).get("active", false)) \
				and str(eval.get("phase", "parity")) != "hq_emergency" \
				and str(own.get("class", "")).to_lower() != "hq":
			idle += 2.2  # the hunt does not pause; idle units are wasted clock
		if bool(eval.get("conv_active", false)) and not is_hq_unit \
				and str(eval.get("phase", "parity")) != "hq_emergency":
			idle += CONV_DEADTIME_TAX  # conversion: idling IS the draw condition
		score -= idle
		terms["idle_cost"] = -snappedf(idle, 0.01)
	elif kind == "FORTIFY" or kind == "ENTER_GARRISON":
		var hold := 0.8 * conservatism
		if bool(eval.get("hq_threatened", false)):
			hold += 1.6
		if bool(eval.get("conv_active", false)) and not is_hq_unit:
			hold -= CONV_DEADTIME_TAX  # shovels are dead tempo mid-conversion
		if is_hq_unit:
			# Mirrors the surviving human/V1 pattern: a fortified HQ shrugs off
			# the opening rush while field units win the fight.
			hold += 5.5 + 2.0 * conservatism
		elif winning:
			# Digging in while winning is dead tempo: the terminal path needs
			# marching, not shovels.
			hold -= 2.6
		if kind == "ENTER_GARRISON" and not is_hq_unit:
			# Self-removal trap: garrisoned FIELD units permanently vanish from
			# the legal pool (wall defenders take no orders). An army that
			# shelters behind its own walls can never win — only draw or die.
			# Only a true HQ emergency justifies trading a field unit for a wall.
			var trap := 8.0
			if str(eval.get("phase", "parity")) == "hq_emergency":
				trap = -2.0  # a garrisoned wall block is real defense then
			score -= trap
			terms["garrison_self_removal"] = -float(trap)
		score += hold
		terms["hold_value"] = snappedf(hold, 0.01)
	elif kind == "REST":
		# Morale is the invisible third resource: combat shock is permanent
		# until a REST recovers it (+12/turn), and a shocked unit that keeps
		# fighting eventually routs off the legal pool without a single troop
		# death. Resting a shocked unit outranks almost any field action;
		# resting a healthy one is pure waste.
		var mor := _own_morale(uid)
		var rest_danger := _reply_strength(_point(own), own_strength, ctx)
		if mor < 70.0:
			# Morale scales combat power directly (0.40+0.60*m/100): a unit at
			# morale 60 hits like 0.76 of itself. The enemy rests back to full
			# strength every few turns; fighting while shocked loses every
			# "even" damage race. Repairing outranks almost anything.
			var morale_fix := 2.8 + 4.2 * clampf((70.0 - mor) / 70.0, 0.0, 1.0)
			if rest_danger >= 1.5 * own_strength:
				morale_fix *= 0.35  # true kill box — rotate first
			score += morale_fix
			terms["morale_rest"] = snappedf(morale_fix, 0.01)
		elif _soldier_fraction(own) < 0.7 and not bool(eval.get("hq_threatened", false)) \
				and not winning:
			# Recovery is for quiet sectors only. A winning army does not heal
			# while the enemy still holds the field.
			var recovery := 1.1 * conservatism
			score += recovery
			terms["recovery"] = snappedf(recovery, 0.01)
		else:
			var waste := 1.8 if not winning else 3.2
			score -= waste
			terms["recovery"] = -float(waste)
	elif kind == "FORTIFY":
		if winning and not is_hq_unit:
			var dig_in := 2.6
			score -= dig_in
			terms["tempo_dig_in"] = -dig_in
	elif kind == "DISMANTLE":
		score += 0.4
		terms["utility"] = 0.4
	return {"score": score, "features": features, "terms": terms}


# ------------------------------------------------------------------
# Threat / influence map + bounded one-ply enemy response
# ------------------------------------------------------------------

## Estimated next-turn strike reach of an OBSERVED enemy: the public class
## range table plus a bounded march allowance. Planning heuristic only —
## it never creates actions or reads hidden state.
func _enemy_reach(e: Dictionary) -> int:
	var cls := str(e.get("class", "")).to_lower()
	var strike := 1
	if not cls.is_empty():
		strike = int(CombatCalculatorCls.get_attack_range(cls))
	var march := 3 if cls in ["cavalry", "scout"] else 2
	return strike + march


## Enemy strength that could plausibly strike `p` next turn (visible contacts
## at full weight, stale last-known contacts at decaying weight).
func _reply_strength(p: Vector2i, own_strength: float, ctx: Dictionary) -> float:
	var total := 0.0
	for raw in (ctx["visible"] as Array):
		if not raw is Dictionary:
			continue
		var e: Dictionary = raw
		var reach := _enemy_reach(e)
		var d := _hex_distance(p, _point(e))
		if d <= reach:
			total += _estimated_soldiers(e) * clampf(float(reach - d + 1) / float(reach), 0.2, 1.0)
	for raw in (ctx["stale"] as Array):
		if not raw is Dictionary:
			continue
		var e: Dictionary = raw
		var reach := _enemy_reach(e) + 1
		var d := _hex_distance(p, _point(e))
		if d <= reach:
			var age := maxi(0, int(_tendencies.get("turn", 0)) - int(e.get("last_seen_turn", 0)))
			total += 0.5 * _estimated_soldiers(e) * clampf(0.7 - 0.08 * float(age), 0.15, 0.7)
	return total


func _reply_ratio(p: Vector2i, own_strength: float, ctx: Dictionary) -> float:
	return _reply_strength(p, own_strength, ctx) / maxf(100.0, own_strength)


func _predicted_response(action: Dictionary, ctx: Dictionary, eval: Dictionary) -> Dictionary:
	var kind := str(action.get("action_type", "")).to_upper()
	var uid := str(action.get("unit_id", ""))
	var own: Dictionary = (ctx["friendly"] as Dictionary).get(uid, {})
	var pos := _point(own)
	if kind == "MOVE":
		pos = _array_point(action.get("destination", []))
	var own_strength := _estimated_soldiers(own) if not own.is_empty() else 300.0
	var reply := _reply_strength(pos, own_strength, ctx)
	var watchers := 0
	for raw in (ctx["visible"] as Array):
		if raw is Dictionary and _hex_distance(pos, _point(raw)) <= _enemy_reach(raw):
			watchers += 1
	var note := "safe" if reply < 0.4 * own_strength else ("contested" if reply < own_strength else "focus-fire danger")
	return {"position": [pos.x, pos.y], "reply_strength": snappedf(reply, 1.0),
		"threatening_enemies": watchers, "own_strength": snappedf(own_strength, 1.0),
		"assessment": note}


# ------------------------------------------------------------------
# Match-local opponent tendency memory (bounded, reset per match)
# ------------------------------------------------------------------

func _reset_tendencies() -> void:
	_tendencies = {"turn": -1, "flank_pressure": {"north": 0, "south": 0, "east": 0, "west": 0},
		"aggression_turns": 0, "turns_observed": 0, "exposed_ranged_events": 0,
		"best_enemy_strength": 1e12, "stall_turns": 0}


func _update_tendencies(ctx: Dictionary, obs: Dictionary, turn: int) -> void:
	if turn == _tendency_turn:
		return
	_tendency_turn = turn
	_tendencies["turn"] = turn
	_tendencies["turns_observed"] = int(_tendencies.get("turns_observed", 0)) + 1
	var own_hq: Dictionary = ctx["own_hq"]
	var anchor := _point(own_hq) if not own_hq.is_empty() else Vector2i.ZERO
	var flanks: Dictionary = _tendencies.get("flank_pressure", {})
	var near_hq := false
	for raw in (ctx["visible"] as Array):
		if not raw is Dictionary:
			continue
		var e: Dictionary = raw
		var p := _point(e)
		var dq := p.x - anchor.x
		var dr := p.y - anchor.y
		if abs(dq) >= abs(dr):
			var key := "east" if dq > 0 else "west"
			flanks[key] = int(flanks.get(key, 0)) + 1
		else:
			var key := "north" if dr < 0 else "south"
			flanks[key] = int(flanks.get(key, 0)) + 1
		if str(e.get("class", "")).to_lower() in ["archer", "siege"] and _hex_distance(p, anchor) <= 3:
			_tendencies["exposed_ranged_events"] = int(_tendencies.get("exposed_ranged_events", 0)) + 1
		if _hex_distance(p, anchor) <= 4:
			near_hq = true
	if near_hq:
		_tendencies["aggression_turns"] = int(_tendencies.get("aggression_turns", 0)) + 1
	_tendencies["flank_pressure"] = flanks
	_track_own_morale(ctx)
	# Stall detection (authorized view only): while in contact, if the
	# LOWEST total visible enemy strength has not improved for 5+ turns,
	# chips are being healed faster than they land — the passive equilibrium
	# that runs out the clock. Real kills permanently drop the total and
	# reset the counter; healing oscillations do not beat the best-seen low.
	var enemy_total := 0.0
	for raw in (ctx["visible"] as Array):
		if raw is Dictionary:
			enemy_total += _estimated_soldiers(raw)
	for raw in (ctx["visible"] as Array):
		if not raw is Dictionary:
			continue
		var e_row: Dictionary = raw
		var eid := str(e_row.get("unit_id", ""))
		if eid.is_empty():
			continue
		var band := _estimated_soldiers(e_row)
		var high := float(_enemy_high.get(eid, band))
		_enemy_high[eid] = maxf(high, band)
	if not (ctx["visible"] as Array).is_empty():
		var best := float(_tendencies.get("best_enemy_strength", 1e12))
		if enemy_total < best - 30.0:
			best = enemy_total
			_tendencies["stall_turns"] = 0
		else:
			_tendencies["stall_turns"] = int(_tendencies.get("stall_turns", 0)) + 1
		_tendencies["best_enemy_strength"] = best
	else:
		_tendencies["stall_turns"] = 0
		_tendencies["best_enemy_strength"] = 1e12


## Morale discipline proxy. Observations carry exact own troop counts but no
## morale field; combat shock is casualty-proportional, so the loss history
## of each OWN unit reconstructs a legal morale estimate (no hidden truth).
## Units that keep fighting while shocked roll rout checks below the line
## and vanish from the legal pool permanently — the reason an army that
## never rests disappears from the endgame while a resting one never does.
func _track_own_morale(ctx: Dictionary) -> void:
	for raw in (ctx["friendly_list"] as Array):
		if not raw is Dictionary:
			continue
		var u: Dictionary = raw
		var uid := str(u.get("unit_id", ""))
		if uid.is_empty():
			continue
		var count := float(u.get("soldiers", 0.0))
		var prev := float(_own_count.get(uid, -1.0))
		if prev < 0.0:
			_own_count[uid] = count
			if not _morale_proxy.has(uid):
				_morale_proxy[uid] = 100.0
			continue
		if count < prev:
			var loss_prop := (prev - count) / maxf(1.0, prev)
			var shock := clampf(loss_prop * 35.0 + 3.0, 0.0, 38.0)
			_morale_proxy[uid] = clampf(float(_morale_proxy.get(uid, 100.0)) - shock, 0.0, 100.0)
		_own_count[uid] = count


func _own_morale(uid: String) -> float:
	return float(_morale_proxy.get(uid, 100.0))


## Weak tactical evidence only: the flank the opponent has NOT been pressing.
## The result is a lateral offset around the ENEMY side of the board, so the
## intent always drives toward the enemy, never toward the back edge.
## The result is a lateral offset around the ENEMY side of the board, so the
## intent always drives toward the enemy, never toward the back edge.
func _weak_flank_point(ctx: Dictionary, obs: Dictionary, eval: Dictionary) -> Dictionary:
	var flanks: Dictionary = _tendencies.get("flank_pressure", {})
	var observed := 0
	for key_val in flanks.keys():
		observed += int(flanks[key_val])
	if observed < 4:
		return {"found": false}
	var own_hq: Dictionary = ctx["own_hq"]
	var anchor := _point(own_hq) if not own_hq.is_empty() else Vector2i.ZERO
	var enemy_hq: Dictionary = ctx["enemy_hq"]
	var base := _point(enemy_hq) if not enemy_hq.is_empty() else _mirror_point(anchor, obs)
	var best_key := ""
	var best_count := 1 << 30
	for key_val in flanks.keys():
		var key := str(key_val)
		var count := int(flanks[key])
		if count < best_count:
			best_count = count
			best_key = key
	# Small lateral lane offset only: the approach stays on the enemy side.
	var offsets := {"north": Vector2i(0, -3), "south": Vector2i(0, 3),
		"east": Vector2i(3, 0), "west": Vector2i(-3, 0)}
	if not offsets.has(best_key):
		return {"found": false}
	var point: Vector2i = base + (offsets[best_key] as Vector2i)
	var bounds: Dictionary = obs.get("map_bounds", {})
	if bounds.is_empty():
		bounds = (obs.get("board", {}) as Dictionary).get("dimensions", {})
	if not bounds.is_empty():
		point = Vector2i(clampi(point.x, int(bounds.get("q_min", -99)), int(bounds.get("q_max", 99))),
			clampi(point.y, int(bounds.get("r_min", -99)), int(bounds.get("r_max", 99))))
	var evidence := clampf(float(observed - best_count) / float(observed), 0.0, 1.0)
	return {"found": true, "point": point, "evidence": evidence}


# ------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------

## Public class baselines (roster sizes used by the research maps). Used ONLY
## to interpret observed troop bands — no hidden truth is involved.
const CLASS_BASELINE := {"infantry": 450.0, "archer": 220.0, "cavalry": 280.0,
	"hq": 300.0, "siege": 220.0, "scout": 220.0, "supply": 200.0}


func _class_baseline(cls: String) -> float:
	return float(CLASS_BASELINE.get(cls, 300.0))


## Fraction of an OBSERVED enemy unit's likely strength, derived from the
## authorized troop estimate against the class baseline. Enemy rows carry no
## condition band, so weakness must be inferred from the estimate itself.
func _enemy_fraction(e: Dictionary) -> float:
	var base := _class_baseline(str(e.get("class", "")).to_lower())
	if base <= 0.0:
		return 1.0
	return clampf(_estimated_soldiers(e) / base, 0.05, 1.0)


## Up to 2 field units for terminal pursuit: cavalry/scout preferred, then
## lowest id. Deterministic; recomputed per call from the authorized view.
func _hunter_units(ctx: Dictionary) -> Array:
	var field: Array = []
	for fr_val in (ctx["friendly_list"] as Array):
		if fr_val is Dictionary:
			var u: Dictionary = fr_val
			if str(u.get("class", "")).to_lower() != "hq" and int(u.get("soldiers", 0)) > 0:
				field.append(u)
	field.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var a_fast := str(a.get("class", "")).to_lower() in ["cavalry", "scout"]
		var b_fast := str(b.get("class", "")).to_lower() in ["cavalry", "scout"]
		if a_fast != b_fast:
			return a_fast
		return str(a.get("unit_id", "")) < str(b.get("unit_id", "")))
	var out: Array = []
	for u_val in field:
		if out.size() >= 2:
			break
		out.append(str((u_val as Dictionary).get("unit_id", "")))
	return out


## Sweep-lane anchor for one searcher: offsets the unit's personal patrol
## point along the enemy edge so the sweep front spreads instead of stacking.
func _sweep_point(uid: String, corner: Vector2i, obs: Dictionary, own_hq: Dictionary) -> Vector2i:
	var bounds: Dictionary = obs.get("map_bounds", {})
	if bounds.is_empty():
		bounds = (obs.get("board", {}) as Dictionary).get("dimensions", {})
	var lane_id := 0
	var u_hash := 0
	for ch_val in uid.to_utf32_buffer():
		u_hash = u_hash * 31 + int(ch_val)
	if u_hash < 0:
		u_hash = -u_hash
	lane_id = u_hash % 5
	var span := 4
	if not bounds.is_empty():
		span = maxi(2, mini(absi(corner.x), absi(corner.y)) - 1)
	var lanes := [Vector2i(0, 0), Vector2i(0, -span), Vector2i(0, span), Vector2i(-span, 0), Vector2i(span, 0)]
	var point: Vector2i = corner + (lanes[lane_id] as Vector2i)
	if not bounds.is_empty():
		point = Vector2i(clampi(point.x, int(bounds.get("q_min", -99)), int(bounds.get("q_max", 99))),
			clampi(point.y, int(bounds.get("r_min", -99)), int(bounds.get("r_max", 99))))
	return point


## Effective strength estimate for an observed enemy: authorized band
## high-water minus the damage our own previewed attacks have already dealt.
## Troop bands are coarse, so chips stay invisible in the band text; this
## makes sustained pressure compound into real kill intent (own action
## record + authoritative previews only — no hidden truth).
func _effective_est(tid: String, target: Dictionary) -> float:
	var band := _estimated_soldiers(target)
	var high := float(_enemy_high.get(tid, band))
	if band > high:
		high = band
		_enemy_high[tid] = high
	var dealt := float(_damage_dealt.get(tid, 0.0))
	# A dropped band IS evidence of damage even without our own ledger.
	return clampf(minf(band, high) - dealt, 30.0, high)


func _turn_of(obs: Dictionary) -> int:
	if obs.has("turn"):
		return int(obs.get("turn", 0))
	return int(obs.get("current_turn", 0))


func _mirror_point(anchor: Vector2i, obs: Dictionary) -> Vector2i:
	var bounds: Dictionary = obs.get("map_bounds", {}) if obs != null else {}
	if bounds.is_empty() and obs != null:
		bounds = (obs.get("board", {}) as Dictionary).get("dimensions", {})
	if bounds.is_empty():
		return Vector2i(-anchor.x, -anchor.y)
	var q := int(bounds.get("q_min", -10)) + int(bounds.get("q_max", 10)) - anchor.x
	var r := int(bounds.get("r_min", -10)) + int(bounds.get("r_max", 10)) - anchor.y
	return Vector2i(q, r)


# ------------------------------------------------------------------
# Endgame hunt: past mid-game the only winning move is to converge the
# whole army on the enemy HQ sector and burst it down. Kiting remnants
# and tradeable screens cannot stop a converging group inside the clock;
# marching piecemeal with an unknown deadline is how draws happen. The
# anchor is sticky: the visible enemy HQ overrides, then the live enemy
# cluster centroid, then stale contacts, then mirror-sector inference.
# ------------------------------------------------------------------

## V2.1: conversion-mode morale gate — every alive field unit must be above
## the given morale floor (own-ledger evidence only; rout is at 20). The
## strong door uses the comfortable bar; the clock door uses the rout-safety
## floor because a REST cycle keeps some unit below the comfortable bar.
func _conv_field_morale_ok(ctx: Dictionary, min_morale: float) -> bool:
	for raw in (ctx["friendly_list"] as Array):
		if not raw is Dictionary:
			continue
		var u: Dictionary = raw
		if int(u.get("soldiers", 0)) <= 0:
			continue
		if str(u.get("class", "")).to_lower() == "hq":
			continue
		if _own_morale(str(u.get("unit_id", ""))) < min_morale:
			return false
	return true


func _endgame_hunt(ctx: Dictionary, obs: Dictionary) -> Dictionary:
	var turn := int(_tendencies.get("turn", 0))
	if turn > _turn_high_water:
		_turn_high_water = turn
	if _turn_high_water < 19:
		return {"active": false}
	var enemy_hq: Dictionary = ctx["enemy_hq"]
	if not enemy_hq.is_empty():
		# Authoritative sighting: the anchor IS the enemy HQ position, and the
		# last-seen point stays sticky afterwards — a kiting HQ cannot be
		# chased faster than we can re-sight it, and letting non-HQ evidence
		# (harasser centroids, stale contacts) steal the anchor turns the hunt
		# into an oscillation between the corner and our own side.
		_hunt_hq_known = true
		_hunt_anchor = _point(enemy_hq)
		_hunt_set = true
		_hunt_anchor_turn = turn
		return {"active": true, "point": _hunt_anchor, "anchor_turn": _hunt_anchor_turn}
	if _hunt_hq_known and _hunt_set:
		# Frozen last-known HQ sector until a new sighting corrects it.
		return {"active": true, "point": _hunt_anchor, "anchor_turn": _hunt_anchor_turn}
	# Never seen the HQ: the spawn-symmetric mirror sector of our own HQ is
	# the strongest public inference (same fairness rule as V1) — harassing
	# centroids mark FIELD units, not the enemy base, and chasing them turns
	# the hunt into an oscillation that never reaches the fortress.
	var fresh := Vector2i.ZERO
	var own_hq2: Dictionary = ctx["own_hq"]
	var have := false
	if not own_hq2.is_empty():
		fresh = _mirror_point(_point(own_hq2), obs)
		have = true
	else:
		var centroid: Dictionary = _enemy_cluster_centroid(ctx["visible"])
		if bool(centroid.get("found", false)):
			fresh = centroid["point"]
			have = true
		else:
			for raw in (ctx["stale"] as Array):
				if raw is Dictionary:
					fresh = _point(raw)
					have = true
					break
	if not _hunt_set:
		_hunt_anchor = fresh
		_hunt_set = true
		_hunt_anchor_turn = turn
	else:
		var drift := _hex_distance(fresh, _hunt_anchor)
		if drift > 3:
			_hunt_anchor = fresh
			_hunt_anchor_turn = turn
	return {"active": true, "point": _hunt_anchor, "anchor_turn": _hunt_anchor_turn}


func _enemy_cluster_centroid(visible: Array) -> Dictionary:
	if visible.is_empty():
		return {"found": false}
	var best_count := 0
	var best_point := Vector2i.ZERO
	var weakest_id := ""
	var weakest := 1e12
	for raw in visible:
		if not raw is Dictionary:
			continue
		var center: Dictionary = raw
		var cp := _point(center)
		var count := 0
		var sx := 0
		var sy := 0
		for other_val in visible:
			if not other_val is Dictionary:
				continue
			var other: Dictionary = other_val
			if _hex_distance(cp, _point(other)) <= 3:
				count += 1
				sx += _point(other).x
				sy += _point(other).y
				var s := _estimated_soldiers(other)
				if s < weakest:
					weakest = s
					weakest_id = str(other.get("unit_id", ""))
		if count > best_count:
			best_count = count
			best_point = Vector2i(roundi(float(sx) / float(count)), roundi(float(sy) / float(count)))
	if best_count == 0:
		return {"found": false}
	return {"found": true, "point": best_point, "count": best_count, "weakest_id": weakest_id}


func _utility_rationale(selected: Dictionary, intent: Dictionary, eval: Dictionary) -> String:
	var terms: Dictionary = selected.get("terms", {})
	var parts: Array = []
	parts.append("intent=%s" % str(intent.get("type", "")))
	parts.append("phase=%s" % str(eval.get("phase", "parity")))
	var names: Array = []
	for key_val in terms.keys():
		names.append(str(key_val))
	names.sort()
	for key in names:
		parts.append("%s=%.2f" % [key, float(terms[key])])
	return " | ".join(parts)
