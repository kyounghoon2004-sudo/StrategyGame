class_name UtilityRulesetView
extends RefCounted

## GENERALIZED_UTILITY_AI_V0 — narrow ruleset adapter (Track A side).
##
## Reads the CURRENT authoritative balance tables at decision time and exposes
## them as a plain Dictionary the policy consumes. Contains ZERO copied balance
## numbers: every entry is a live reference (CombatCalculator.BASE_STATS,
## Step3Config.CLASS_BASE_MOVEMENT / terrain costs) or derived from the live
## observation roster. A future balance patch automatically changes this view,
## so the same policy reacts without code edits.
##
## `observation["ruleset_override"]` (optional, test-only) simulates a future
## ruleset with repo-valid ranges, e.g.:
##   {"class_stats": {"archer": {"range": 2}, "cavalry": {"base_mp": 4.0}}}
## Both sides receive the SAME overlay in tests — never a secret asymmetry.
## Track B EpisodeSpec should own this field canonically (see artifacts doc).

const CombatCalculatorCls = preload("res://scripts/combat/combat_calculator.gd")
const Step3ConfigCls = preload("res://scripts/core/step3_config.gd")


## Build the ruleset view for one decision. Pure function of (observation).
## Never reads world truth: only public rule tables + side-authorized roster.
static func build(observation: Dictionary) -> Dictionary:
	var override: Dictionary = observation.get("ruleset_override", {})
	var class_overlay: Dictionary = override.get("class_stats", {})
	var movement_overlay: Dictionary = override.get("base_mp", {})
	var classes := _known_classes(observation)
	var table: Dictionary = {}
	for cls in classes:
		table[cls] = _class_row(cls, class_overlay, movement_overlay)
	# Always include the canonical roster even if unobserved, so mobility
	# ranking never collapses when the enemy composition is unknown.
	for cls in ["infantry", "archer", "cavalry", "spear", "spearman", "scout", "siege", "conscript", "hq", "supply"]:
		var key := CombatCalculatorCls.normalize_class_name(cls)
		if not table.has(key):
			table[key] = _class_row(key, class_overlay, movement_overlay)
	var mobility := _mobility_order(table)
	var map_info := _map_info(observation)
	var force := _force_scale(observation)
	return {
		"schema": "utility_ruleset_v0",
		"class_table": table,
		"episode_id": observation.get("episode_id", ""),
		"matchup": override.get("matchup", CombatCalculatorCls.MATCHUP_TABLE),
		"terrain_standard": override.get("terrain_standard", Step3ConfigCls.TERRAIN_COSTS_STANDARD),
		"terrain_scout": override.get("terrain_scout", Step3ConfigCls.TERRAIN_COSTS_SCOUT),
		"mobility_order": mobility,  # fastest-first class names, rules-derived
		"map": map_info,
		"force": force,
		"turn_limit": _turn_limit(observation),
		"turn": _turn_of(observation),
		"overlay_active": not class_overlay.is_empty(),
		"fingerprint": _fingerprint(table),
	}


static func get_range(ruleset: Dictionary, unit_class: String) -> int:
	var key := CombatCalculatorCls.normalize_class_name(unit_class)
	var row: Dictionary = (ruleset.get("class_table", {}) as Dictionary).get(key, {})
	return maxi(1, int(row.get("range", 1)))


static func get_base_mp(ruleset: Dictionary, unit_class: String) -> float:
	var key := CombatCalculatorCls.normalize_class_name(unit_class)
	var row: Dictionary = (ruleset.get("class_table", {}) as Dictionary).get(key, {})
	return maxf(1.0, float(row.get("base_mp", 2.0)))


static func get_attack(ruleset: Dictionary, unit_class: String) -> float:
	var key := CombatCalculatorCls.normalize_class_name(unit_class)
	var row: Dictionary = (ruleset.get("class_table", {}) as Dictionary).get(key, {})
	return maxf(1.0, float(row.get("attack", 10.0)))


static func get_defense(ruleset: Dictionary, unit_class: String) -> float:
	var key := CombatCalculatorCls.normalize_class_name(unit_class)
	var row: Dictionary = (ruleset.get("class_table", {}) as Dictionary).get(key, {})
	return maxf(1.0, float(row.get("defense", 10.0)))


## March allowance for threat projection, derived from the CURRENT mobility
## table (rounded base MP, bounded). Replaces the fixed "cav/scout=3 else 2".
static func march_allowance(ruleset: Dictionary, unit_class: String) -> int:
	return clampi(int(round(get_base_mp(ruleset, unit_class))), 1, 4)


## Normalized hex distance in [0,1] against the CURRENT map diameter.
## Replaces fixed-divisor progress terms ("/4.0", "/5.0").
static func norm_distance(ruleset: Dictionary, hex_dist: int) -> float:
	var diameter := maxi(1, int((ruleset.get("map", {}) as Dictionary).get("diameter", 20)))
	return clampf(float(hex_dist) / float(diameter), 0.0, 1.0)


static func _known_classes(observation: Dictionary) -> Array:
	var out: Array = []
	var seen: Dictionary = {}
	for key in ["friendly_units", "known_enemy_units", "stale_enemy_units"]:
		var rows: Array = observation.get(key, [])
		if not rows is Array:
			continue
		for raw in rows:
			if not raw is Dictionary:
				continue
			var cls := CombatCalculatorCls.normalize_class_name(str((raw as Dictionary).get("class", "")))
			if cls.is_empty() or cls == "unknown" or seen.has(cls):
				continue
			seen[cls] = true
			out.append(cls)
	out.sort()
	return out


static func _class_row(cls: String, overlay: Dictionary, movement_overlay: Dictionary = {}) -> Dictionary:
	var key := CombatCalculatorCls.normalize_class_name(cls)
	var stats: Dictionary = CombatCalculatorCls.BASE_STATS.get(key, {"attack": 10.0, "defense": 10.0, "range": 1})
	var row := {
		"attack": float(stats.get("attack", 10.0)),
		"defense": float(stats.get("defense", 10.0)),
		"range": maxi(1, int(stats.get("range", 1))),
		"base_mp": maxf(1.0, Step3ConfigCls.get_base_movement(key)),
	}
	if overlay.has(key) and (overlay[key] is Dictionary):
		for field in ["attack", "defense", "range", "base_mp"]:
			if (overlay[key] as Dictionary).has(field):
				row[field] = (overlay[key] as Dictionary)[field]
		row["range"] = maxi(1, int(row["range"]))
		row["base_mp"] = maxf(1.0, float(row["base_mp"]))
	if movement_overlay.has(key):
		row["base_mp"] = maxf(1.0, float(movement_overlay[key]))
	return row


static func _mobility_order(table: Dictionary) -> Array:
	var keys: Array = table.keys()
	keys.sort_custom(func(a: String, b: String) -> bool:
		var ma := float((table[a] as Dictionary).get("base_mp", 2.0))
		var mb := float((table[b] as Dictionary).get("base_mp", 2.0))
		if is_equal_approx(ma, mb):
			return a < b
		return ma > mb)
	return keys


static func _map_info(observation: Dictionary) -> Dictionary:
	var bounds: Dictionary = observation.get("map_bounds", {})
	if bounds.is_empty():
		bounds = (observation.get("board", {}) as Dictionary).get("dimensions", {})
	var q_min := int(bounds.get("q_min", -10))
	var q_max := int(bounds.get("q_max", 10))
	var r_min := int(bounds.get("r_min", -10))
	var r_max := int(bounds.get("r_max", 10))
	if q_max < q_min:
		var t := q_min
		q_min = q_max
		q_max = t
	if r_max < r_min:
		var t2 := r_min
		r_min = r_max
		r_max = t2
	var q_span := maxi(1, q_max - q_min + 1)
	var r_span := maxi(1, r_max - r_min + 1)
	# Axial-cube diameter proxy: max corner-to-corner cube distance.
	var corners := [Vector2i(q_min, r_min), Vector2i(q_min, r_max), Vector2i(q_max, r_min), Vector2i(q_max, r_max)]
	var diameter := 1
	for i in range(corners.size()):
		for j in range(i + 1, corners.size()):
			diameter = maxi(diameter, _hex_distance(corners[i], corners[j]))
	return {"q_min": q_min, "q_max": q_max, "r_min": r_min, "r_max": r_max,
		"q_span": q_span, "r_span": r_span,
		"area": q_span * r_span, "diameter": diameter}


static func _force_scale(observation: Dictionary) -> Dictionary:
	var friends: Array = observation.get("friendly_units", [])
	var enemies: Array = observation.get("known_enemy_units", [])
	var f_strengths: Array = []
	var by_class: Dictionary = {}
	var total_f := 0.0
	for raw in friends:
		if not raw is Dictionary:
			continue
		var s := maxf(1.0, float((raw as Dictionary).get("soldiers", 0)))
		if s <= 0.0:
			continue
		total_f += s
		f_strengths.append(s)
		var cls := CombatCalculatorCls.normalize_class_name(str((raw as Dictionary).get("class", "")))
		if not (by_class as Dictionary).has(cls):
			by_class[cls] = []
		(by_class[cls] as Array).append(s)
	f_strengths.sort()
	var median_f: float = float(f_strengths[f_strengths.size() / 2]) if not f_strengths.is_empty() else 300.0
	var class_median: Dictionary = {}
	for cls in by_class.keys():
		var arr: Array = by_class[cls]
		arr.sort()
		class_median[cls] = arr[arr.size() / 2]
	var e_total := 0.0
	var e_strengths: Array = []
	for raw in enemies:
		if not raw is Dictionary:
			continue
		var s := _enemy_estimate(raw)
		e_total += s
		e_strengths.append(s)
	e_strengths.sort()
	var median_e: float = float(e_strengths[e_strengths.size() / 2]) if not e_strengths.is_empty() else 0.0
	return {"friendly_total": total_f, "friendly_count": f_strengths.size(),
		"friendly_median": median_f, "class_median": class_median,
		"visible_enemy_total": e_total, "visible_enemy_count": e_strengths.size(),
		"visible_enemy_median": median_e}


static func _enemy_estimate(u: Dictionary) -> float:
	if u.has("soldiers"):
		return maxf(1.0, float(u["soldiers"]))
	var raw := str(u.get("troop_estimate", ""))
	if raw.is_valid_int():
		return maxf(1.0, float(raw.to_int()))
	return 0.0  # unknown band contributes nothing (fog ignorance != strength)


static func _turn_limit(observation: Dictionary) -> int:
	for key in ["turn_limit", "turnLimit"]:
		if observation.has(key):
			return maxi(1, int(observation.get(key, 0)))
	var mission: Dictionary = observation.get("mission", {})
	if mission.has("turn_limit"):
		return maxi(1, int(mission.get("turn_limit", 0)))
	var contract: Dictionary = observation.get("mission_contract", {})
	if contract.has("turn_limit"):
		return maxi(1, int(contract.get("turn_limit", 0)))
	return 60  # repo-default compact scenario horizon (documented fallback)


static func _turn_of(observation: Dictionary) -> int:
	if observation.has("turn"):
		return int(observation.get("turn", 0))
	return int(observation.get("current_turn", 0))


static func _hex_distance(a: Vector2i, b: Vector2i) -> int:
	return maxi(abs(a.x - b.x), maxi(abs(a.y - b.y), abs((a.x + a.y) - (b.x + b.y))))


static func _fingerprint(table: Dictionary) -> String:
	var parts: Array = []
	var keys: Array = table.keys()
	keys.sort()
	for k in keys:
		var row: Dictionary = table[k]
		parts.append("%s:%.2f/%.2f/r%d/mp%.2f" % [k, float(row.get("attack", 0.0)),
			float(row.get("defense", 0.0)), int(row.get("range", 1)), float(row.get("base_mp", 0.0))])
	return "%016x" % hash("|".join(parts))
