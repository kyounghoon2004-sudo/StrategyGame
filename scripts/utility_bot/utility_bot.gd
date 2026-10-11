class_name UtilityBot
extends RefCounted

## Side-authorized, one-action utility policy. The caller supplies Godot's
## current legal candidates and executes the returned candidate unchanged.
## This class never reads world truth, invents an action, or simulates combat.

const ARCHETYPES := ["AGGRESSIVE", "DEFENSIVE", "MANEUVER", "ATTRITION", "OPPORTUNIST", "COUNTERPUNCH"]
const FEATURE_NAMES := ["pressure", "damage", "preservation", "hq_safety", "force_ratio",
	"position", "cohesion", "isolation", "objective", "flank", "standoff",
	"weakened", "threat_removal", "tempo"]
const BASE_WEIGHTS := {
	"pressure": 1.25, "damage": 2.6, "preservation": 1.8, "hq_safety": 3.8,
	"force_ratio": 1.2, "position": 0.8, "cohesion": 0.9, "isolation": 1.25,
	"objective": 1.0, "flank": 0.8, "standoff": 0.7, "weakened": 1.3,
	"threat_removal": 1.2, "tempo": 0.7,
}
const ARCHETYPE_MULTIPLIERS := {
	"AGGRESSIVE": {"pressure": 1.55, "damage": 1.3, "tempo": 1.45, "preservation": 0.78, "isolation": 0.8},
	"DEFENSIVE": {"hq_safety": 1.6, "cohesion": 1.45, "preservation": 1.45, "isolation": 1.4, "pressure": 0.72},
	"MANEUVER": {"position": 1.65, "flank": 1.7, "pressure": 1.12, "cohesion": 1.2},
	"ATTRITION": {"damage": 1.4, "preservation": 1.32, "standoff": 1.45, "weakened": 1.25},
	"OPPORTUNIST": {"damage": 1.25, "threat_removal": 1.5, "weakened": 1.5, "flank": 1.35},
	"COUNTERPUNCH": {"hq_safety": 1.45, "threat_removal": 1.55, "force_ratio": 1.4, "pressure": 0.85},
}
const TERMINAL_WIN_SCORE := 10000.0
const TERMINAL_LOSS_SCORE := -10000.0
const TOP_K := 6

var _seed := 0
var _archetype := "AGGRESSIVE"
var _weights: Dictionary = {}
var _temperature := 0.6
var _risk := 0.5
var _rng := RandomNumberGenerator.new()
var _configured := false
var _last: Dictionary = {}
var _decision_index := 0


func configure(seed: int, archetype_override: String = "") -> void:
	_seed = seed
	_rng.seed = seed
	var requested := archetype_override.strip_edges().to_upper()
	_archetype = requested if requested in ARCHETYPES else ARCHETYPES[_rng.randi_range(0, ARCHETYPES.size() - 1)]
	_weights = {}
	var prior: Dictionary = ARCHETYPE_MULTIPLIERS[_archetype]
	for name in FEATURE_NAMES:
		var key := str(name)
		# Broad but bounded match-level variation; no action-level resampling.
		var multiplier := _rng.randf_range(0.73, 1.27)
		_weights[key] = snappedf(float(BASE_WEIGHTS[key]) * float(prior.get(key, 1.0)) * multiplier, 0.001)
	_temperature = snappedf(_rng.randf_range(0.38, 0.9), 0.001)
	_risk = snappedf(_rng.randf_range(0.25, 0.75), 0.001)
	_configured = true
	_decision_index = 0
	_last = {}


func profile() -> Dictionary:
	return {"archetype": _archetype, "seed": _seed, "weights": _weights.duplicate(true),
		"temperature": _temperature, "risk": _risk}


func last_decision() -> Dictionary:
	return _last.duplicate(true)


## Returns an original legal candidate, never a synthesized action. Candidate
## enrichment is optional: authoritative combat preview fields and/or a
## `utility_features` Dictionary of normalized [-1,1] feature values.
func select_action(observation: Dictionary, candidates: Array) -> Dictionary:
	if not _configured:
		return {"ok": false, "code": "NOT_CONFIGURED", "detail": "Call configure once at match start."}
	if candidates.is_empty():
		return {"ok": false, "code": "NO_LEGAL_ACTIONS", "detail": "The caller supplied no legal candidates."}
	var context := _context(observation)
	var ranked: Array = []
	for raw in candidates:
		if not raw is Dictionary:
			continue
		var candidate: Dictionary = raw
		var features := _features(candidate, context, observation)
		var score := _score(features)
		ranked.append({"candidate": candidate, "score": score, "features": features,
			"candidate_id": str(candidate.get("candidate_id", ""))})
	if ranked.is_empty():
		return {"ok": false, "code": "NO_VALID_CANDIDATES", "detail": "No dictionary candidates supplied."}
	ranked.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if is_equal_approx(float(a["score"]), float(b["score"])):
			return str(a["candidate_id"]) < str(b["candidate_id"])
		return float(a["score"]) > float(b["score"])
	)
	var best := float((ranked[0] as Dictionary)["score"])
	var choices: Array = []
	var total := 0.0
	for i in range(mini(TOP_K, ranked.size())):
		var row: Dictionary = ranked[i]
		var delta := best - float(row["score"])
		# Limit both candidate count and utility gap. Catastrophic or plainly
		# inferior actions cannot win a stochastic draw.
		if delta > maxf(1.6, 3.0 * _temperature):
			break
		var mass := exp(-delta / _temperature)
		row["probability_mass"] = mass
		choices.append(row)
		total += mass
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
	var alternatives: Array = []
	for row_val in ranked.slice(0, mini(5, ranked.size())):
		var row: Dictionary = row_val
		alternatives.append({"candidate_id": str(row["candidate_id"]), "score": float(row["score"])})
	_last = {"ok": true, "candidate": action.duplicate(true),
		"candidate_id": str(action.get("candidate_id", "")),
		"action_type": str(action.get("action_type", "")),
		"score": float(selected["score"]), "features": (selected["features"] as Dictionary).duplicate(true),
		"alternatives": alternatives, "decision_index": _decision_index,
		"archetype": _archetype, "seed": _seed}
	return _last.duplicate(true)


func _score(features: Dictionary) -> float:
	if float(features.get("own_hq_loss", 0.0)) > 0.5:
		return TERMINAL_LOSS_SCORE
	if float(features.get("enemy_hq_kill", 0.0)) > 0.5:
		return TERMINAL_WIN_SCORE
	var score := 0.0
	for name in FEATURE_NAMES:
		var key := str(name)
		var weight := float(_weights[key])
		# Independent match-level risk draw affects the cost of casualties and
		# exposure without overriding terminal truth or archetype priorities.
		if key == "preservation" or key == "isolation":
			weight *= lerpf(1.45, 0.7, _risk)
		score += weight * clampf(float(features.get(key, 0.0)), -1.0, 1.0)
	return score


func _features(c: Dictionary, ctx: Dictionary, obs: Dictionary) -> Dictionary:
	var f: Dictionary = {}
	for name in FEATURE_NAMES:
		f[str(name)] = 0.0
	f["enemy_hq_kill"] = 0.0
	f["own_hq_loss"] = 0.0
	var kind := str(c.get("action_type", "")).to_upper()
	var uid := str(c.get("unit_id", ""))
	var own: Dictionary = (ctx["friendly"] as Dictionary).get(uid, {})
	var soldier_fraction := _soldier_fraction(own)
	var own_pos := _point(own)
	var visible: Array = ctx["visible"]
	var stale: Array = ctx["stale"]
	var enemy_hq: Dictionary = ctx["enemy_hq"]
	var own_hq: Dictionary = ctx["own_hq"]
	var dest := _array_point(c.get("destination", [])) if kind == "MOVE" else own_pos
	var near_old := _nearest_distance(own_pos, visible)
	var near_new := _nearest_distance(dest, visible)
	var local_friend := _nearby_strength(dest, ctx["friendly_list"], uid, 3)
	var local_enemy := _nearby_strength(dest, visible, "", 3)
	var ratio := (local_friend + maxf(50.0, float(own.get("soldiers", 0)))) / maxf(50.0, local_enemy)
	f["force_ratio"] = clampf((ratio - 1.0) / 2.0, -1.0, 1.0) if local_enemy > 0.0 else 0.0
	f["cohesion"] = clampf(local_friend / 550.0, 0.0, 1.0) if kind == "MOVE" else 0.0
	f["isolation"] = -clampf((local_enemy - local_friend) / maxf(100.0, float(own.get("soldiers", 100))), 0.0, 1.0) if kind == "MOVE" else 0.0
	if kind == "ATTACK" or kind == "ASSAULT":
		var target: Dictionary = (ctx["visible_by_id"] as Dictionary).get(str(c.get("target_id", "")), {})
		var enemy_loss := maxf(0.0, float(c.get("expected_enemy_casualties_max", 0.0)))
		var friendly_loss := maxf(0.0, float(c.get("expected_friendly_casualties_max", 0.0)))
		# Only the authoritative preview's *minimum* self-casualty bound
		# establishes certain terminal HQ loss. A maximum is merely risk.
		if str(own.get("class", "")).to_lower() == "hq" \
				and float(c.get("expected_friendly_casualties_min", 0.0)) >= float(own.get("soldiers", 1)):
			f["own_hq_loss"] = 1.0
		var target_soldiers := _estimated_soldiers(target)
		f["damage"] = clampf(enemy_loss / maxf(100.0, target_soldiers), 0.0, 1.0)
		f["preservation"] = -clampf(friendly_loss / maxf(100.0, float(own.get("soldiers", 100))), 0.0, 1.0)
		f["tempo"] = 0.38
		f["pressure"] = 0.38
		f["weakened"] = 0.45 * (1.0 - soldier_fraction) * -1.0
		if not target.is_empty():
			var target_class := str(target.get("class", "")).to_lower()
			f["threat_removal"] = 0.6 if target_class in ["archer", "siege", "hq"] else 0.22
			if target_class == "hq":
				f["hq_safety"] = 0.35
				# A max-casualty preview is only upside, not a terminal truth.
				# The adapter may mark a guaranteed kill using the authoritative
				# minimum casualty preview and confirmed defender troop count.
				if bool(c.get("guaranteed_enemy_hq_kill", false)):
					f["enemy_hq_kill"] = 1.0
			if not own_hq.is_empty() and _hex_distance(_point(target), _point(own_hq)) <= 3:
				f["hq_safety"] = 0.55
	elif kind == "MOVE":
		f["tempo"] = 0.27
		if near_old < 999 and near_new < 999:
			f["pressure"] = clampf(float(near_old - near_new) / 4.0, -0.7, 0.7)
			if near_new <= 1 and ratio < 0.8:
				f["isolation"] = -1.0
		elif not own.is_empty():
			# In fog, advance toward a side-authorized last-known contact or
			# a public map exploration point. The latter is inferred solely
			# from board bounds and our own HQ, never enemy world truth.
			var exploration: Dictionary = _exploration_target(own_pos, stale, ctx, obs)
			if bool(exploration.get("found", false)):
				var explore_point: Vector2i = exploration["point"]
				var progress := _hex_distance(own_pos, explore_point) - _hex_distance(dest, explore_point)
				var confidence := float(exploration.get("confidence", 0.0))
				f["objective"] = clampf(float(progress) * confidence * 0.55, -0.7, 0.7)
				f["pressure"] = clampf(float(progress) * confidence * 0.42, -0.6, 0.6)
				if progress <= 0:
					f["tempo"] = -0.12
		if not enemy_hq.is_empty():
			var hq_progress := _hex_distance(own_pos, _point(enemy_hq)) - _hex_distance(dest, _point(enemy_hq))
			f["objective"] = clampf(float(hq_progress) / 5.0, -0.6, 0.6)
		if not own_hq.is_empty():
			var hq_dist := _hex_distance(dest, _point(own_hq))
			if bool(ctx["hq_threatened"]):
				f["hq_safety"] = clampf(float(_hex_distance(own_pos, _point(own_hq)) - hq_dist) / 4.0, -0.8, 0.8)
		if soldier_fraction < 0.35 and near_new < near_old:
			f["weakened"] = -0.8
		elif soldier_fraction < 0.35 and near_new > near_old:
			f["weakened"] = 0.55
		var cost := float(c.get("cost", 0.0))
		f["position"] = 0.15 - clampf(cost / 20.0, 0.0, 0.25)
		if near_new >= 2 and near_new <= 4 and str(own.get("class", "")).to_lower() in ["archer", "siege"]:
			f["standoff"] = 0.42
		if str(own.get("class", "")).to_lower() == "hq":
			# The HQ itself is no reconnaissance asset. A safe HQ should
			# remain anchored while field units explore and screen it.
			f["objective"] = 0.0
			f["pressure"] = 0.0
			f["tempo"] = -0.5
			f["hq_safety"] = -1.0
			if bool(ctx["hq_threatened"]) and near_new > near_old:
				f["hq_safety"] = 0.55
	elif kind == "WAIT" or kind == "END_TURN":
		f["tempo"] = -0.55
		f["pressure"] = -0.3
		if bool(ctx["hq_threatened"]) and uid == str(own_hq.get("unit_id", "")):
			f["hq_safety"] = -0.5
	elif kind == "FORTIFY" or kind == "ENTER_GARRISON" or kind == "REST":
		f["preservation"] = 0.35
		f["hq_safety"] = 0.4 if bool(ctx["hq_threatened"]) else 0.0
		f["tempo"] = -0.18
	elif kind == "DISMANTLE":
		f["tempo"] = 0.1
	# Adapter-computed, side-authorized features may add terrain, flank,
	# objective and authoritative HQ consequence facts. Never inspect any
	# unknown observation field or hidden contact here.
	var enriched: Dictionary = c.get("utility_features", {}) if c.get("utility_features", {}) is Dictionary else {}
	for key_val in enriched.keys():
		var key := str(key_val)
		if key in FEATURE_NAMES or key == "enemy_hq_kill" or key == "own_hq_loss":
			f[key] = clampf(float(enriched[key]), -1.0, 1.0)
	return f


func _context(obs: Dictionary) -> Dictionary:
	var friends: Array = obs.get("friendly_units", []) if obs.get("friendly_units", []) is Array else []
	var enemies: Array = obs.get("known_enemy_units", []) if obs.get("known_enemy_units", []) is Array else []
	var stale_rows: Array = obs.get("stale_enemy_units", []) if obs.get("stale_enemy_units", []) is Array else []
	var own_by_id: Dictionary = {}
	var own_hq: Dictionary = {}
	for raw in friends:
		if not raw is Dictionary:
			continue
		var u: Dictionary = raw
		own_by_id[str(u.get("unit_id", ""))] = u
		if str(u.get("class", "")).to_lower() == "hq":
			own_hq = u
	var visible: Array = []
	var stale: Array = []
	var by_id: Dictionary = {}
	var enemy_hq: Dictionary = {}
	for raw in enemies:
		if not raw is Dictionary:
			continue
		var u: Dictionary = raw
		if str(u.get("contact_state", "")) == "stale_last_known":
			stale.append(u)
			continue
		if str(u.get("contact_state", "")) != "current_visible":
			continue
		visible.append(u)
		by_id[str(u.get("unit_id", ""))] = u
		if str(u.get("class", "")).to_lower() == "hq":
			enemy_hq = u
	for raw in stale_rows:
		if not raw is Dictionary:
			continue
		var u: Dictionary = raw
		if by_id.has(str(u.get("unit_id", ""))):
			continue
		stale.append(u)
	var threatened := false
	if not own_hq.is_empty():
		for raw in visible:
			if _hex_distance(_point(raw), _point(own_hq)) <= 4:
				threatened = true
				break
	return {"friendly": own_by_id, "friendly_list": friends, "visible": visible, "stale": stale,
		"visible_by_id": by_id, "own_hq": own_hq, "enemy_hq": enemy_hq,
		"hq_threatened": threatened}


## Side-authorized exploration target. Fresh last-known contacts take
## precedence, but their influence decays with age; they never count as
## current threats, legal attack targets, or known HQ positions. If no
## contact exists, a public board point beyond the center from our own HQ
## gives field units a useful direction while preserving fog fairness.
func _exploration_target(origin: Vector2i, stale: Array, ctx: Dictionary, obs: Dictionary) -> Dictionary:
	var best: Dictionary = {}
	var best_distance := 1 << 30
	for raw in stale:
		if not raw is Dictionary:
			continue
		var contact: Dictionary = raw
		var distance := _hex_distance(origin, _point(contact))
		if distance < best_distance:
			best_distance = distance
			best = contact
	if not best.is_empty():
		var age := maxi(0, int(obs.get("turn", obs.get("current_turn", 0))) - int(best.get("last_seen_turn", 0)))
		return {"found": true, "point": _point(best),
			"confidence": clampf(0.72 - float(age) * 0.08, 0.18, 0.72)}
	var dimensions: Dictionary = {}
	var board: Dictionary = obs.get("board", {}) if obs.get("board", {}) is Dictionary else {}
	if board.get("dimensions", {}) is Dictionary:
		dimensions = board.get("dimensions", {})
	if dimensions.is_empty() and obs.get("map_bounds", {}) is Dictionary:
		dimensions = obs.get("map_bounds", {})
	if not dimensions.has("q_min") or not dimensions.has("q_max") \
		or not dimensions.has("r_min") or not dimensions.has("r_max"):
		return {"found": false}
	var q_min := int(dimensions["q_min"])
	var q_max := int(dimensions["q_max"])
	var r_min := int(dimensions["r_min"])
	var r_max := int(dimensions["r_max"])
	if q_max < q_min or r_max < r_min:
		return {"found": false}
	var center := Vector2i(roundi(0.5 * float(q_min + q_max)), roundi(0.5 * float(r_min + r_max)))
	var own_hq: Dictionary = ctx["own_hq"]
	var anchor := _point(own_hq) if not own_hq.is_empty() else origin
	var target := Vector2i(clampi(roundi(float(center.x) + 0.35 * float(center.x - anchor.x)), q_min, q_max),
		clampi(roundi(float(center.y) + 0.35 * float(center.y - anchor.y)), r_min, r_max))
	return {"found": true, "point": target, "confidence": 0.8}


func _point(u: Dictionary) -> Vector2i:
	return Vector2i(int(u.get("q", 0)), int(u.get("r", 0)))


func _array_point(v: Variant) -> Vector2i:
	if v is Array and (v as Array).size() >= 2:
		return Vector2i(int((v as Array)[0]), int((v as Array)[1]))
	return Vector2i.ZERO


func _hex_distance(a: Vector2i, b: Vector2i) -> int:
	return maxi(abs(a.x - b.x), maxi(abs(a.y - b.y), abs((a.x + a.y) - (b.x + b.y))))


func _nearest_distance(p: Vector2i, units: Array) -> int:
	var best := 999
	for raw in units:
		if raw is Dictionary:
			best = mini(best, _hex_distance(p, _point(raw)))
	return best


func _estimated_soldiers(u: Dictionary) -> float:
	if u.has("soldiers"):
		return maxf(1.0, float(u["soldiers"]))
	var raw := str(u.get("troop_estimate", ""))
	if raw.is_valid_int():
		return maxf(1.0, float(raw.to_int()))
	return 300.0


func _soldier_fraction(u: Dictionary) -> float:
	var band := str(u.get("condition", "")).to_lower()
	if band == "critical":
		return 0.2
	if band == "weakened" or band == "low":
		return 0.45
	if band == "worn" or band == "medium":
		return 0.7
	return 1.0


func _nearby_strength(p: Vector2i, units: Array, exclude_id: String, radius: int) -> float:
	var total := 0.0
	for raw in units:
		if not raw is Dictionary:
			continue
		var u: Dictionary = raw
		if str(u.get("unit_id", "")) == exclude_id:
			continue
		if _hex_distance(p, _point(u)) <= radius:
			total += _estimated_soldiers(u)
	return total
