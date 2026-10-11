class_name UtilityBotV1
extends "res://scripts/utility_bot/utility_bot.gd"

## Side-authorized, bounded two-action tactical projection. The caller still
## owns enumeration, combat previews, revalidation, and all mutations.

const LOOKAHEAD_WIDTH := 18
const V1_TOP_K := 4


func profile() -> Dictionary:
	var p: Dictionary = super.profile()
	p["version"] = "V1"
	p["lookahead_actions"] = 2
	return p


func select_action(observation: Dictionary, candidates: Array) -> Dictionary:
	if not _configured:
		return {"ok": false, "code": "NOT_CONFIGURED"}
	if candidates.is_empty():
		return {"ok": false, "code": "NO_LEGAL_ACTIONS"}
	var ctx: Dictionary = _context(observation)
	var ranked: Array = []
	var attack_by_target: Dictionary = {}
	for raw in candidates:
		if not raw is Dictionary:
			continue
		var c: Dictionary = raw
		var kind := str(c.get("action_type", "")).to_upper()
		if kind == "ATTACK" or kind == "ASSAULT":
			var target := str(c.get("target_id", ""))
			if not target.is_empty():
				if not attack_by_target.has(target):
					attack_by_target[target] = []
				(attack_by_target[target] as Array).append(c)
	for raw in candidates:
		if not raw is Dictionary:
			continue
		var c: Dictionary = raw
		var features: Dictionary = _features(c, ctx, observation)
		var score := _score(features)
		if absf(score) < 9000.0:
			score += _tactical_score(c, ctx, observation, attack_by_target)
		ranked.append({"candidate": c, "candidate_id": str(c.get("candidate_id", "")),
			"score": score, "features": features})
	if ranked.is_empty():
		return {"ok": false, "code": "NO_VALID_CANDIDATES"}
	ranked.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if is_equal_approx(float(a["score"]), float(b["score"])):
			return str(a["candidate_id"]) < str(b["candidate_id"])
		return float(a["score"]) > float(b["score"]))
	# Project a second already legal friendly action. This is deliberately a
	# reservation estimate: no state is mutated and no combat is reimplemented.
	var width: int = mini(LOOKAHEAD_WIDTH, ranked.size())
	for i in range(width):
		var row: Dictionary = ranked[i]
		var first: Dictionary = row["candidate"]
		if absf(float(row["score"])) >= 9000.0:
			continue
		var best_follow := 0.0
		for j in range(width):
			var second: Dictionary = ranked[j]["candidate"]
			if str(first.get("unit_id", "")) == str(second.get("unit_id", "")):
				continue
			var follow := _pair_synergy(first, second, ctx)
			best_follow = maxf(best_follow, follow)
		row["score"] = float(row["score"]) + best_follow
	ranked.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if is_equal_approx(float(a["score"]), float(b["score"])):
			return str(a["candidate_id"]) < str(b["candidate_id"])
		return float(a["score"]) > float(b["score"]))
	var best := float(ranked[0]["score"])
	var choices: Array = []
	var total := 0.0
	for i in range(mini(V1_TOP_K, ranked.size())):
		var row: Dictionary = ranked[i]
		var gap := best - float(row["score"])
		if gap > maxf(1.25, 2.4 * _temperature):
			break
		var mass := exp(-gap / _temperature)
		choices.append(row)
		total += mass
	var roll := _rng.randf() * total
	var selected: Dictionary = choices[0]
	for row_val in choices:
		var row: Dictionary = row_val
		roll -= exp(-(best - float(row["score"])) / _temperature)
		if roll <= 0.0:
			selected = row
			break
	_decision_index += 1
	var action: Dictionary = selected["candidate"]
	var alternatives: Array = []
	for row_val in ranked.slice(0, mini(5, ranked.size())):
		var row: Dictionary = row_val
		alternatives.append({"candidate_id": row["candidate_id"], "score": row["score"]})
	_last = {"ok": true, "candidate": action.duplicate(true),
		"candidate_id": str(action.get("candidate_id", "")),
		"action_type": str(action.get("action_type", "")),
		"score": float(selected["score"]), "features": (selected["features"] as Dictionary).duplicate(true),
		"alternatives": alternatives, "decision_index": _decision_index,
		"archetype": _archetype, "seed": _seed, "version": "V1"}
	return _last.duplicate(true)


func _tactical_score(c: Dictionary, ctx: Dictionary, obs: Dictionary, attacks: Dictionary) -> float:
	var kind := str(c.get("action_type", "")).to_upper()
	var uid := str(c.get("unit_id", ""))
	var own: Dictionary = (ctx["friendly"] as Dictionary).get(uid, {})
	if kind == "ATTACK" or kind == "ASSAULT":
		var target_id := str(c.get("target_id", ""))
		if kind == "ASSAULT" and target_id.is_empty():
			return -3.5
		var target: Dictionary = (ctx["visible_by_id"] as Dictionary).get(target_id, {})
		var estimated := _estimated_soldiers(target)
		var min_loss := maxf(0.0, float(c.get("expected_enemy_casualties_min", 0.0)))
		var max_loss := maxf(min_loss, float(c.get("expected_enemy_casualties_max", 0.0)))
		var mid_loss := 0.5 * (min_loss + max_loss)
		var own_loss := 0.5 * (float(c.get("expected_friendly_casualties_min", 0.0)) + float(c.get("expected_friendly_casualties_max", 0.0)))
		var kill_chance := clampf((max_loss - estimated) / maxf(1.0, max_loss - min_loss), 0.0, 1.0)
		if min_loss >= estimated:
			kill_chance = 1.0
		var danger := 1.45 if str(target.get("class", "")).to_lower() in ["siege", "archer", "cavalry"] else 1.0
		var score := 3.0 + danger * (3.2 * kill_chance + 2.4 * clampf(mid_loss / maxf(100.0, estimated), 0.0, 1.0))
		if str(target.get("class", "")).to_lower() == "hq":
			score += 6.0
		score -= 2.2 * clampf(own_loss / maxf(100.0, float(own.get("soldiers", 100))), 0.0, 1.0)
		var partners: Array = attacks.get(target_id, [])
		var partner_damage := 0.0
		for other_val in partners:
			var other: Dictionary = other_val
			if str(other.get("unit_id", "")) != uid:
				partner_damage = maxf(partner_damage, float(other.get("expected_enemy_casualties_min", 0.0)))
		if mid_loss < estimated and mid_loss + partner_damage >= estimated:
			score += 2.2
		return score
	if kind == "MOVE":
		var dest := _array_point(c.get("destination", []))
		var origin := _point(own)
		var near_enemy := _nearest_distance(dest, ctx["visible"])
		var nearby_friends := _nearby_strength(dest, ctx["friendly_list"], uid, 2)
		var nearby_enemies := _nearby_strength(dest, ctx["visible"], "", 2)
		var score := clampf(nearby_friends / 450.0, 0.0, 1.0) * 0.55
		if not (ctx["visible"] as Array).is_empty():
			score -= 0.7
		if nearby_enemies > nearby_friends + float(own.get("soldiers", 0)):
			score -= 2.5
		if str(own.get("class", "")).to_lower() in ["archer", "siege"] and near_enemy <= 1:
			score -= 2.0
		if _soldier_fraction(own) < 0.4 and near_enemy <= 2:
			score -= 1.8
		# An authorized enemy HQ contact is an objective. With no contact,
		# sweep toward the opposite public board sector inferred from our HQ.
		# This gives the policy a way to finish after field forces are removed.
		if str(own.get("class", "")).to_lower() != "hq":
			var objective: Dictionary = ctx["enemy_hq"]
			var point := Vector2i.ZERO
			var has_point := false
			if not objective.is_empty():
				point = _point(objective)
				has_point = true
			else:
				var bounds: Dictionary = obs.get("map_bounds", {})
				if bounds.is_empty():
					bounds = (obs.get("board", {}) as Dictionary).get("dimensions", {})
				var own_hq: Dictionary = ctx["own_hq"]
				if not bounds.is_empty() and not own_hq.is_empty():
					point = Vector2i(int(bounds.get("q_min", -10)) + int(bounds.get("q_max", 10)) - int(own_hq.get("q", 0)),
						int(bounds.get("r_min", -10)) + int(bounds.get("r_max", 10)) - int(own_hq.get("r", 0)))
					has_point = true
			if has_point:
				var progress := _hex_distance(origin, point) - _hex_distance(dest, point)
				var goal_weight := 2.5 if not objective.is_empty() else (1.35 if not (ctx["visible"] as Array).is_empty() else 1.8)
				score += goal_weight * clampf(float(progress), -2.0, 2.0)
		return score
	if kind == "END_TURN" or kind == "WAIT":
		return -1.2
	return 0.0


func _pair_synergy(first: Dictionary, second: Dictionary, ctx: Dictionary) -> float:
	var a := str(first.get("action_type", "")).to_upper()
	var b := str(second.get("action_type", "")).to_upper()
	if a == "ATTACK" and b == "ATTACK" and str(first.get("target_id", "")) == str(second.get("target_id", "")):
		var target: Dictionary = (ctx["visible_by_id"] as Dictionary).get(str(first.get("target_id", "")), {})
		var needed := _estimated_soldiers(target)
		var combined := float(first.get("expected_enemy_casualties_min", 0.0)) + float(second.get("expected_enemy_casualties_min", 0.0))
		return 2.5 if combined >= needed else 0.7
	if a == "MOVE" and b == "ATTACK":
		var target: Dictionary = (ctx["visible_by_id"] as Dictionary).get(str(second.get("target_id", "")), {})
		if not target.is_empty() and _hex_distance(_array_point(first.get("destination", [])), _point(target)) <= 2:
			return 0.65
	return 0.0
