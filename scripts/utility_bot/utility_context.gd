class_name UtilityContext
extends RefCounted

## GENERALIZED_UTILITY_AI_V0 — relative/contextual decision quantities.
##
## Builds the per-decision UtilityContext the policy consumes, plus optional
## per-candidate `utility_features` enrichment the frozen V0 scorer already
## honors (its enrichment loop overwrites fixed-assumption terms). Every
## quantity is relative to the CURRENT ruleset view / CURRENT pool:
## no fixed army size, composition, movement table, range, or map scale.
##
## Context fields (also the Track B EpisodeSpec request — see artifacts doc):
##   force_ratio_local .... (friends+self at dest) / max(1, enemies at dest)
##   cohesion ............. friends at dest / friendly_median (was /550)
##   travel_cost_norm ..... candidate cost / max pool cost (was cost/20)
##   dist_objective_norm .. hex dist / map diameter (was /4, /5)
##   standoff ............. dest inside CURRENT class range band (was 2..4 archer)
##   hq_risk .............. reply strength / max(1, HQ garrison)
##   reserve_fraction ..... unacted friends / all friends
##   objective_pressure ... turn_fraction weighted by enemy contact
##   composition .......... class share of CURRENT roster
##   mobility ............. unit base_mp / army median base_mp (was CAV-fastest)

const RulesetViewCls = preload("res://scripts/utility_bot/utility_ruleset_view.gd")


static func build(observation: Dictionary, candidates: Array, ruleset: Dictionary) -> Dictionary:
	var friends: Array = observation.get("friendly_units", [])
	var enemies: Array = observation.get("known_enemy_units", [])
	var own_by_id: Dictionary = {}
	var own_hq: Dictionary = {}
	for raw in friends:
		if raw is Dictionary:
			own_by_id[str((raw as Dictionary).get("unit_id", ""))] = raw
			if _norm_cls(str((raw as Dictionary).get("class", ""))) == "hq":
				own_hq = raw
	var turn := int(ruleset.get("turn", 0))
	var limit := maxi(1, int(ruleset.get("turn_limit", 60)))
	var unacted := 0
	for raw in friends:
		if raw is Dictionary and not bool((raw as Dictionary).get("action_ended", false)):
			unacted += 1
	var max_cost := 0.01
	for raw in candidates:
		if raw is Dictionary:
			max_cost = maxf(max_cost, float((raw as Dictionary).get("cost", 0.0)))
	var comp: Dictionary = {}
	for raw in friends:
		if raw is Dictionary:
			var cls := _norm_cls(str((raw as Dictionary).get("class", "")))
			comp[cls] = float(comp.get(cls, 0.0)) + 1.0
	var total := maxf(1.0, float(friends.size()))
	for k in comp.keys():
		comp[k] = float(comp[k]) / total
	return {
		"schema": "utility_context_v0",
		"ruleset": ruleset,
		"turn_fraction": clampf(float(turn) / float(limit), 0.0, 1.0),
		"reserve_fraction": clampf(float(unacted) / maxf(1.0, float(friends.size())), 0.0, 1.0),
		"composition": comp,
		"max_pool_cost": max_cost,
		"contact": not enemies.is_empty(),
		"objective_pressure": clampf(float(turn) / float(limit), 0.0, 1.0) * (1.0 if enemies.is_empty() else 1.35),
		"own_hq": own_hq,
		"friendly_by_id": own_by_id,
	}


## Enrich every candidate with ruleset-relative utility_features. The frozen
## V0 scorer applies these verbatim (clamped), which corrects its fixed
## assumptions without touching frozen code. Keys not in V0's FEATURE_NAMES
## plus terminal flags are ignored by V0 and used by the generalized policy.
static func enrich_candidates(candidates: Array, observation: Dictionary, ruleset: Dictionary, ctx: Dictionary) -> Array:
	var out: Array = []
	var friends: Array = observation.get("friendly_units", [])
	var visible: Array = observation.get("known_enemy_units", [])
	var median := maxf(60.0, float((ruleset.get("force", {}) as Dictionary).get("friendly_median", 300.0)))
	var max_cost := maxf(0.01, float(ctx.get("max_pool_cost", 1.0)))
	for raw in candidates:
		if not raw is Dictionary:
			continue
		var c: Dictionary = (raw as Dictionary).duplicate(true)
		var kind := str(c.get("action_type", "")).to_upper()
		var uid := str(c.get("unit_id", ""))
		var own: Dictionary = (ctx.get("friendly_by_id", {}) as Dictionary).get(uid, {})
		var feat: Dictionary = c.get("utility_features", {})
		if not feat is Dictionary:
			feat = {}
		else:
			feat = (feat as Dictionary).duplicate(true)
		if kind == "MOVE":
			var dest := _array_point(c.get("destination", []))
			var origin := _point(own)
			var cls := _norm_cls(str(own.get("class", "")))
			var friends_at := _nearby_count(dest, friends, uid, _sense_radius(ruleset))
			var enemies_at := _nearby_count(dest, visible, "", _sense_radius(ruleset))
			feat["cohesion"] = clampf(float(friends_at) / maxf(1.0, median), 0.0, 1.0)
			var ratio := (float(friends_at) + maxf(50.0, float(own.get("soldiers", 0)))) / maxf(50.0, float(enemies_at))
			feat["force_ratio"] = clampf((ratio - 1.0) / 2.0, -1.0, 1.0) if enemies_at > 0 else 0.0
			feat["position"] = 0.15 - clampf(float(c.get("cost", 0.0)) / max_cost, 0.0, 0.25) * 1.0
			# Standoff: destination inside the CURRENT range band of this class.
			var band := RulesetViewCls.get_range(ruleset, cls)
			var near := _nearest_distance(dest, visible)
			feat["standoff"] = 0.42 if (near >= maxi(2, band - 1) and near <= band + 1) else 0.0
			# Normalized objective progress (replaces /4.0, /5.0 fixed divisors).
			var enemy_hq := _find_hq(visible)
			if not enemy_hq.is_empty():
				var diameter := maxi(1, int((ruleset.get("map", {}) as Dictionary).get("diameter", 20)))
				var progress := float(_hex_distance(origin, _point(enemy_hq)) - _hex_distance(dest, _point(enemy_hq))) / float(diameter)
				feat["objective"] = clampf(progress * 5.0, -0.6, 0.6)
				feat["pressure"] = clampf(progress * 4.0, -0.6, 0.6)
			feat["mobility"] = clampf(RulesetViewCls.get_base_mp(ruleset, cls) / maxf(1.0, _army_median_mp(ruleset)), 0.5, 2.0)
			feat["terrain_access"] = _terrain_access(ruleset, c, cls)
		elif kind == "ATTACK" or kind == "ASSAULT":
			var target := _find_unit(visible, str(c.get("target_id", c.get("garrison_target_id", ""))))
			if not target.is_empty():
				var tcls := _norm_cls(str(target.get("class", "")))
				feat["counter_threat"] = 0.6 if tcls in ["archer", "siege", "hq"] else 0.22
				# Current-rules matchup edge from live attack/defense values.
				var edge := RulesetViewCls.get_attack(ruleset, str(own.get("class", ""))) / maxf(1.0, RulesetViewCls.get_defense(ruleset, tcls))
				feat["matchup_edge"] = clampf((edge - 1.0) * 1.5, -0.6, 0.6)
		c["utility_features"] = feat
		out.append(c)
	return out


## Sense radius scales with the CURRENT map (diameter/8, clamped 2..4).
## Replaces every fixed radius-2/3 neighborhood in V0/V1/V2 scoring.
static func _sense_radius(ruleset: Dictionary) -> int:
	var diameter := maxi(1, int((ruleset.get("map", {}) as Dictionary).get("diameter", 20)))
	return clampi(int(round(float(diameter) / 8.0)), 2, 4)


static func _army_median_mp(ruleset: Dictionary) -> float:
	var table: Dictionary = ruleset.get("class_table", {})
	var mps: Array = []
	for k in table.keys():
		mps.append(float((table[k] as Dictionary).get("base_mp", 2.0)))
	if mps.is_empty():
		return 2.0
	mps.sort()
	return maxf(1.0, mps[mps.size() / 2])


static func _terrain_access(ruleset: Dictionary, c: Dictionary, cls: String) -> float:
	# Destination terrain tag vs CURRENT passability: mountain/forest/swamp
	# tags cost more for slow classes; unknown tags are neutral (never invented).
	var tag := str(c.get("terrain", "?")).to_upper()
	var mp := RulesetViewCls.get_base_mp(ruleset, cls)
	if tag in ["MTN", "SWA", "FOR"]:
		return clampf((mp - 2.0) * 0.25, -0.5, 0.5)
	if tag in ["RD", "PLN"]:
		return 0.15
	return 0.0


static func _norm_cls(c: String) -> String:
	var n := c.strip_edges().to_lower()
	if n == "archers":
		return "archer"
	if n == "spearman" or n == "spearmen":
		return "spear"
	if n == "scouts":
		return "scout"
	if n == "conscripts":
		return "conscript"
	return n


static func _point(u: Dictionary) -> Vector2i:
	return Vector2i(int(u.get("q", 0)), int(u.get("r", 0)))


static func _array_point(v: Variant) -> Vector2i:
	if v is Array and (v as Array).size() >= 2:
		return Vector2i(int((v as Array)[0]), int((v as Array)[1]))
	return Vector2i.ZERO


static func _hex_distance(a: Vector2i, b: Vector2i) -> int:
	return maxi(abs(a.x - b.x), maxi(abs(a.y - b.y), abs((a.x + a.y) - (b.x + b.y))))


static func _nearest_distance(p: Vector2i, units: Array) -> int:
	var best := 999
	for raw in units:
		if raw is Dictionary:
			best = mini(best, _hex_distance(p, _point(raw)))
	return best


static func _nearby_count(p: Vector2i, units: Array, exclude_id: String, radius: int) -> float:
	var total := 0.0
	for raw in units:
		if not raw is Dictionary:
			continue
		var u: Dictionary = raw
		if str(u.get("unit_id", "")) == exclude_id:
			continue
		if _hex_distance(p, _point(u)) <= radius:
			total += maxf(1.0, float(u.get("soldiers", _troop_est(u))))
	return total


static func _troop_est(u: Dictionary) -> float:
	if u.has("soldiers"):
		return maxf(1.0, float(u["soldiers"]))
	var raw := str(u.get("troop_estimate", ""))
	if raw.is_valid_int():
		return maxf(1.0, float(raw.to_int()))
	return 300.0


static func _find_unit(units: Array, uid: String) -> Dictionary:
	for raw in units:
		if raw is Dictionary and str((raw as Dictionary).get("unit_id", "")) == uid:
			return raw
	return {}


static func _find_hq(units: Array) -> Dictionary:
	for raw in units:
		if raw is Dictionary and _norm_cls(str((raw as Dictionary).get("class", ""))) == "hq":
			return raw
	return {}
