class_name UtilityBotGeneralized
extends "res://scripts/utility_bot/utility_bot_v2.gd"

## GENERALIZED_UTILITY_AI_V0 — deterministic ruleset-aware Utility policy.
##
## Same contract as V0/V1/V2: side-authorized, caller-supplied candidates only,
## returns an ORIGINAL candidate unchanged. Never reads world truth, never
## invents actions, never simulates combat. Combat facts come only from the
## authoritative preview fields the adapter attaches.
##
## What "generalized" means here: every fixed rules assumption in V0/V1/V2 is
## replaced by a CURRENT-ruleset derivation (UtilityRulesetView, built per
## decision from live CombatCalculator/Step3Config tables + live roster):
##
##   FIXED (V0/V1/V2) ......................... GENERALIZED
##   CLASS_BASELINE {inf:450,arc:220,...} ..... live per-class median strength
##   "cavalry/scout fastest" (march 3 else 2) . Step3Config base_mp ranking
##   hunter = cavalry/scout preferred ......... fastest-by-current-table, then id
##   standoff 2..4 for archer/siege ........... CURRENT range band of the class
##   HQ threatened radius <= 4 ................ max visible enemy reach + 1
##   cohesion /550, superiority /450 .......... / live friendly median
##   force-ratio floor 50.0 ................... median-derived floor
##   progress /4.0, /5.0 ...................... / map-diameter fractions
##   travel cost /20.0 ........................ / max pool cost
##   CONV turns 20/34/40, hunt turn 19 ........ turn_limit fractions
##   sense radius fixed 2/3 ................... diameter/8 clamped 2..4
##   threat list [siege,archer,cavalry] ....... top-half attack classes, live
##   fallback estimate 300 .................... live friendly median, else 300
##
## Planning depth preserves the V0/V1/V2 tiers without crippling:
##   depth 0 (BASIC) ...... V0 one-action scoring, generalized features
##   depth 1 (INTER) ...... V1 tactical + pair synergy, generalized
##   depth 2 (ADVANCED) ... V2 full-turn plan + intents, generalized helpers

const RulesetViewCls = preload("res://scripts/utility_bot/utility_ruleset_view.gd")
const ProfilesCls = preload("res://scripts/utility_bot/utility_profiles.gd")
const UContextCls = preload("res://scripts/utility_bot/utility_context.gd")

const VERSION_GX := "GX"
const TERMINAL_GATE := 9000.0

var _profile_id := "GX_ADV_SPEARHEAD"
var _depth := 2
var _doctrine: Dictionary = {}
var _ruleset: Dictionary = {}
var _ruleset_key := ""
var _dyn_baseline: Dictionary = {}
var _pool_max_cost := 20.0
var _gx_top_k := 5
var _gx_lookahead := 18


func configure(seed: int, profile_or_archetype: String = "") -> void:
	var requested := profile_or_archetype.strip_edges().to_upper()
	# Draw order is fixed: super consumes archetype/weights/temp/risk/V2
	# params first, then the profile layer draws its bounded jitter from the
	# SAME stream. Same seed + same profile => identical replay.
	if ProfilesCls.is_profile_id(requested):
		_profile_id = requested
		super.configure(seed, ProfilesCls.archetype_of(requested))
	elif requested in ARCHETYPES:
		# Legacy archetype compat: ADVANCED depth, requested prior.
		_profile_id = "GX_ADV_SPEARHEAD"
		super.configure(seed, requested)
		_archetype = requested
		_depth = 2
		_doctrine = _doctrine_for_archetype(requested)
		_apply_doctrine_jitter()
		return
	else:
		var pick: Array = ProfilesCls.PROFILE_IDS.duplicate()
		# Seeded pre-draw: use a throwaway stream so the main stream order
		# stays identical regardless of profile count.
		var pre := RandomNumberGenerator.new()
		pre.seed = seed * 31 + 7
		_profile_id = pick[pre.randi_range(0, pick.size() - 1)]
		super.configure(seed, ProfilesCls.archetype_of(_profile_id))
	_depth = int(ProfilesCls.DEPTH_BY_TIER.get(ProfilesCls.tier_of(_profile_id), 2))
	_doctrine = ProfilesCls.doctrine_of(_profile_id)
	_apply_doctrine_jitter()


func profile() -> Dictionary:
	var p: Dictionary = super.profile()
	p["version"] = VERSION_GX
	p["profile_id"] = _profile_id
	p["tier"] = ProfilesCls.tier_of(_profile_id)
	p["style"] = ProfilesCls.style_of(_profile_id)
	p["planning_depth"] = _depth
	p["doctrine"] = _doctrine.duplicate(true)
	p["ruleset_fingerprint"] = str(_ruleset.get("fingerprint", ""))
	return p


func _apply_doctrine_jitter() -> void:
	var ag := float(_doctrine.get("aggression", 0.6))
	var ca := float(_doctrine.get("caution", 0.5))
	var co := float(_doctrine.get("concentration", 0.6))
	var oc := float(_doctrine.get("objective_commitment", 0.6))
	var cal: Dictionary = ProfilesCls.calibration_of(_profile_id)
	_temperature = snappedf(_rng.randf_range(float(cal.get("temp_lo", 0.4)), float(cal.get("temp_hi", 0.8))), 0.001)
	_gx_top_k = int(cal.get("top_k", 5))
	_risk = snappedf(clampf(0.5 * _risk + 0.5 * (1.0 - ca), 0.15, 0.85), 0.001)
	_v2_params["sacrifice_tolerance"] = snappedf(clampf(0.5 * float(_v2_params.get("sacrifice_tolerance", 0.5)) + 0.5 * (0.15 + 0.75 * ag), 0.1, 0.95), 0.001)
	_v2_params["tempo_bias"] = snappedf(clampf(0.5 * float(_v2_params.get("tempo_bias", 0.6)) + 0.5 * (0.35 + 0.65 * oc), 0.3, 1.0), 0.001)
	_v2_params["response_conservatism"] = snappedf(clampf(0.5 * float(_v2_params.get("response_conservatism", 0.6)) + 0.5 * (0.25 + 0.70 * ca), 0.2, 0.95), 0.001)
	_v2_params["concentration_preference"] = snappedf(clampf(0.5 * float(_v2_params.get("concentration_preference", 0.7)) + 0.5 * (0.4 + 0.6 * co), 0.3, 1.0), 0.001)
	_v2_params["hq_conversion_pressure"] = snappedf(clampf(0.5 * float(_v2_params.get("hq_conversion_pressure", 0.7)) + 0.5 * (0.4 + 0.6 * oc), 0.3, 1.0), 0.001)


func _doctrine_for_archetype(a: String) -> Dictionary:
	for p in ProfilesCls.PROFILE_IDS:
		if ProfilesCls.archetype_of(p) == a:
			return ProfilesCls.doctrine_of(p)
	return ProfilesCls.doctrine_of("GX_ADV_SPEARHEAD")


# ------------------------------------------------------------------
# Per-decision ruleset plumbing (cached by turn; deterministic)
# ------------------------------------------------------------------

func _rs(observation: Dictionary) -> Dictionary:
	# Cache key covers turn + ruleset overlay + map: the same turn can expose
	# different overlays/rosters across calls (probes, re-seeds), and a stale
	# view would silently ignore a changed ruleset.
	var bounds: Dictionary = observation.get("map_bounds", {})
	if bounds.is_empty():
		bounds = (observation.get("board", {}) as Dictionary).get("dimensions", {})
	var key := "%d|%s|%s" % [_turn_of(observation),
		JSON.stringify(observation.get("ruleset_override", {})),
		JSON.stringify(bounds)]
	if _ruleset.is_empty() or _ruleset_key != key:
		_ruleset = RulesetViewCls.build(observation)
		_ruleset_key = key
	return _ruleset


func _turn_limit_of(observation: Dictionary) -> int:
	return maxi(1, int(_rs(observation).get("turn_limit", 60)))


func _rebuild_baselines(ctx: Dictionary, observation: Dictionary) -> void:
	# Rebuilt every decision: the roster (casualties, contact set) changes
	# intra-turn, and baselines must track the CURRENT army, not the
	# turn-opening one. Pure function of (ctx, observation): deterministic.
	_dyn_baseline = {}
	var rs := _rs(observation)
	var median := maxf(60.0, float((rs.get("force", {}) as Dictionary).get("friendly_median", 300.0)))
	var per_class: Dictionary = {}
	for raw in (ctx.get("friendly_list", []) as Array):
		if not raw is Dictionary:
			continue
		var u: Dictionary = raw
		var cls := _norm_cls(str(u.get("class", "")))
		if not per_class.has(cls):
			per_class[cls] = []
		(per_class[cls] as Array).append(maxf(1.0, float(u.get("soldiers", median))))
	for raw in (ctx.get("visible", []) as Array):
		if not raw is Dictionary:
			continue
		var e: Dictionary = raw
		var cls := _norm_cls(str(e.get("class", "")))
		if not per_class.has(cls):
			per_class[cls] = []
		(per_class[cls] as Array).append(_estimated_soldiers(e))
	for cls in per_class.keys():
		var arr: Array = per_class[cls]
		arr.sort()
		_dyn_baseline[cls] = arr[arr.size() / 2]
	_dyn_baseline["_median"] = median


func _norm_cls(c: String) -> String:
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


func _median_strength() -> float:
	return maxf(60.0, float(_dyn_baseline.get("_median", 300.0)))


func _sense_radius() -> int:
	var diameter := maxi(1, int((_ruleset.get("map", {}) as Dictionary).get("diameter", 20)))
	return clampi(int(round(float(diameter) / 8.0)), 2, 4)


func _ratio_floor() -> float:
	return maxf(25.0, _median_strength() * 0.2)


func _diameter() -> int:
	return maxi(4, int((_ruleset.get("map", {}) as Dictionary).get("diameter", 20)))


func _high_threat_class(tcls: String) -> bool:
	# Top-half CURRENT attack values count as high-threat (replaces the
	# fixed [siege, archer, cavalry] danger list).
	var table: Dictionary = _ruleset.get("class_table", {})
	var atks: Array = []
	for k in table.keys():
		atks.append(float((table[k] as Dictionary).get("attack", 10.0)))
	if atks.is_empty():
		return tcls in ["siege", "archer", "cavalry"]
	atks.sort()
	var cutoff: float = atks[atks.size() / 2]
	return RulesetViewCls.get_attack(_ruleset, tcls) >= cutoff and tcls != "hq"


# ------------------------------------------------------------------
# Generalized selection entry (depth-switched; V0/V1/V2 tiers preserved)
# ------------------------------------------------------------------

func select_action(observation: Dictionary, candidates: Array) -> Dictionary:
	if not _configured:
		return {"ok": false, "code": "NOT_CONFIGURED", "detail": "Call configure once at match start."}
	if candidates.is_empty():
		return {"ok": false, "code": "NO_LEGAL_ACTIONS", "detail": "The caller supplied no legal candidates."}
	var rs := _rs(observation)
	var ctx := _context(observation)
	_rebuild_baselines(ctx, observation)
	var enriched := UContextCls.enrich_candidates(candidates, observation, rs, UContextCls.build(observation, candidates, rs))
	_pool_max_cost = 0.01
	for raw in enriched:
		if raw is Dictionary:
			_pool_max_cost = maxf(_pool_max_cost, float((raw as Dictionary).get("cost", 0.0)))
	if _depth <= 0:
		return _select_v0(ctx, observation, enriched)
	if _depth == 1:
		return _select_v1(ctx, observation, enriched)
	return super.select_action(observation, enriched)


func _select_v0(ctx: Dictionary, obs: Dictionary, candidates: Array) -> Dictionary:
	var ranked: Array = []
	for raw in candidates:
		if not raw is Dictionary:
			continue
		var candidate: Dictionary = raw
		var features := _features(candidate, ctx, obs)
		ranked.append({"candidate": candidate, "score": _score(features),
			"features": features, "candidate_id": str(candidate.get("candidate_id", ""))})
	if ranked.is_empty():
		return {"ok": false, "code": "NO_VALID_CANDIDATES"}
	ranked.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if is_equal_approx(float(a["score"]), float(b["score"])):
			return str(a["candidate_id"]) < str(b["candidate_id"])
		return float(a["score"]) > float(b["score"]))
	var best := float((ranked[0] as Dictionary)["score"])
	var choices: Array = []
	var total := 0.0
	for i in range(mini(_gx_top_k, ranked.size())):
		var row: Dictionary = ranked[i]
		if best - float(row["score"]) > maxf(1.6, 3.0 * _temperature):
			break
		var mass := exp(-(best - float(row["score"])) / _temperature)
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
	return _record_v0(selected, ranked)


func _select_v1(ctx: Dictionary, obs: Dictionary, candidates: Array) -> Dictionary:
	var attack_by_target: Dictionary = {}
	for raw in candidates:
		if not raw is Dictionary:
			continue
		var c: Dictionary = raw
		if str(c.get("action_type", "")).to_upper() in ["ATTACK", "ASSAULT"]:
			var target := str(c.get("target_id", ""))
			if not target.is_empty():
				if not attack_by_target.has(target):
					attack_by_target[target] = []
				(attack_by_target[target] as Array).append(c)
	var ranked: Array = []
	for raw in candidates:
		if not raw is Dictionary:
			continue
		var c: Dictionary = raw
		var features := _features(c, ctx, obs)
		var score := _score(features)
		if absf(score) < TERMINAL_GATE:
			score += _tactical_score(c, ctx, obs, attack_by_target)
		ranked.append({"candidate": c, "candidate_id": str(c.get("candidate_id", "")),
			"score": score, "features": features})
	if ranked.is_empty():
		return {"ok": false, "code": "NO_VALID_CANDIDATES"}
	ranked.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if is_equal_approx(float(a["score"]), float(b["score"])):
			return str(a["candidate_id"]) < str(b["candidate_id"])
		return float(a["score"]) > float(b["score"]))
	var width: int = mini(_gx_lookahead, ranked.size())
	for i in range(width):
		var row: Dictionary = ranked[i]
		if absf(float(row["score"])) >= TERMINAL_GATE:
			continue
		var first: Dictionary = row["candidate"]
		var best_follow := 0.0
		for j in range(width):
			var second: Dictionary = ranked[j]["candidate"]
			if str(first.get("unit_id", "")) == str(second.get("unit_id", "")):
				continue
			best_follow = maxf(best_follow, _pair_synergy(first, second, ctx))
		row["score"] = float(row["score"]) + best_follow
	ranked.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if is_equal_approx(float(a["score"]), float(b["score"])):
			return str(a["candidate_id"]) < str(b["candidate_id"])
		return float(a["score"]) > float(b["score"]))
	var best := float(ranked[0]["score"])
	var choices: Array = []
	var total := 0.0
	for i in range(mini(_gx_top_k, ranked.size())):
		var row: Dictionary = ranked[i]
		if best - float(row["score"]) > maxf(1.25, 2.4 * _temperature):
			break
		choices.append(row)
		total += exp(-(best - float(row["score"])) / _temperature)
	var roll := _rng.randf() * total
	var selected: Dictionary = choices[0]
	for row_val in choices:
		var row: Dictionary = row_val
		roll -= exp(-(best - float(row["score"])) / _temperature)
		if roll <= 0.0:
			selected = row
			break
	return _record_v0(selected, ranked)


func _record_v0(selected: Dictionary, ranked: Array) -> Dictionary:
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
		"archetype": _archetype, "seed": _seed, "version": VERSION_GX,
		"profile_id": _profile_id}
	return _last.duplicate(true)


# ------------------------------------------------------------------
# Generalized V0 feature model (fixed divisors/ranges replaced)
# ------------------------------------------------------------------

func _features(c: Dictionary, ctx: Dictionary, obs: Dictionary) -> Dictionary:
	var rs := _rs(obs)
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
	var sr := _sense_radius()
	var median := _median_strength()
	var floor_v := _ratio_floor()
	var diameter := float(_diameter())
	var local_friend := _nearby_strength(dest, ctx["friendly_list"], uid, sr)
	var local_enemy := _nearby_strength(dest, visible, "", sr)
	var ratio := (local_friend + maxf(floor_v, float(own.get("soldiers", 0)))) / maxf(floor_v, local_enemy)
	f["force_ratio"] = clampf((ratio - 1.0) / 2.0, -1.0, 1.0) if local_enemy > 0.0 else 0.0
	f["cohesion"] = clampf(local_friend / median, 0.0, 1.0) if kind == "MOVE" else 0.0
	f["isolation"] = -clampf((local_enemy - local_friend) / maxf(floor_v, float(own.get("soldiers", 100))), 0.0, 1.0) if kind == "MOVE" else 0.0
	if kind == "ATTACK" or kind == "ASSAULT":
		var target: Dictionary = (ctx["visible_by_id"] as Dictionary).get(str(c.get("target_id", "")), {})
		var enemy_loss := maxf(0.0, float(c.get("expected_enemy_casualties_max", 0.0)))
		var friendly_loss := maxf(0.0, float(c.get("expected_friendly_casualties_max", 0.0)))
		if str(own.get("class", "")).to_lower() == "hq" \
				and float(c.get("expected_friendly_casualties_min", 0.0)) >= float(own.get("soldiers", 1)):
			f["own_hq_loss"] = 1.0
		var target_soldiers := _estimated_soldiers(target)
		f["damage"] = clampf(enemy_loss / maxf(floor_v, target_soldiers), 0.0, 1.0)
		f["preservation"] = -clampf(friendly_loss / maxf(floor_v, float(own.get("soldiers", 100))), 0.0, 1.0)
		f["tempo"] = 0.38
		f["pressure"] = 0.38
		f["weakened"] = 0.45 * (1.0 - soldier_fraction) * -1.0
		if not target.is_empty():
			var target_class := _norm_cls(str(target.get("class", "")))
			f["threat_removal"] = 0.6 if target_class in ["archer", "siege", "hq"] or _high_threat_class(target_class) else 0.22
			if target_class == "hq":
				f["hq_safety"] = 0.35
				if bool(c.get("guaranteed_enemy_hq_kill", false)):
					f["enemy_hq_kill"] = 1.0
			if not own_hq.is_empty() and _hex_distance(_point(target), _point(own_hq)) <= _sense_radius() + 1:
				f["hq_safety"] = 0.55
	elif kind == "MOVE":
		f["tempo"] = 0.27
		var step := maxf(2.0, diameter * 0.15)
		if near_old < 999 and near_new < 999:
			f["pressure"] = clampf(float(near_old - near_new) / step, -0.7, 0.7)
			if near_new <= 1 and ratio < 0.8:
				f["isolation"] = -1.0
		elif not own.is_empty():
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
			var hq_progress := float(_hex_distance(own_pos, _point(enemy_hq)) - _hex_distance(dest, _point(enemy_hq))) / maxf(2.0, diameter * 0.2)
			f["objective"] = clampf(hq_progress, -0.6, 0.6)
		if not own_hq.is_empty():
			var hq_dist := _hex_distance(dest, _point(own_hq))
			if bool(ctx["hq_threatened"]):
				f["hq_safety"] = clampf(float(_hex_distance(own_pos, _point(own_hq)) - hq_dist) / step, -0.8, 0.8)
		if soldier_fraction < 0.35 and near_new < near_old:
			f["weakened"] = -0.8
		elif soldier_fraction < 0.35 and near_new > near_old:
			f["weakened"] = 0.55
		f["position"] = 0.15 - clampf(float(c.get("cost", 0.0)) / maxf(0.01, _pool_max_cost), 0.0, 0.25)
		var own_cls := _norm_cls(str(own.get("class", "")))
		var band := RulesetViewCls.get_range(rs, own_cls)
		if band > 1 and near_new >= maxi(2, band - 1) and near_new <= band + 1:
			f["standoff"] = 0.42
		if own_cls == "hq":
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
	var enriched: Dictionary = c.get("utility_features", {}) if c.get("utility_features", {}) is Dictionary else {}
	for key_val in enriched.keys():
		var key := str(key_val)
		if key in FEATURE_NAMES or key == "enemy_hq_kill" or key == "own_hq_loss":
			f[key] = clampf(float(enriched[key]), -1.0, 1.0)
	return f


func _estimated_soldiers(u: Dictionary) -> float:
	if u.has("soldiers"):
		return maxf(1.0, float(u["soldiers"]))
	var raw := str(u.get("troop_estimate", ""))
	if raw.is_valid_int():
		return maxf(1.0, float(raw.to_int()))
	return _median_strength()


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


# ------------------------------------------------------------------
# Generalized side-authorized context (threat radius from live reach)
# ------------------------------------------------------------------

func _context(obs: Dictionary) -> Dictionary:
	var rs := _rs(obs)
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
		if _norm_cls(str(u.get("class", ""))) == "hq":
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
		if _norm_cls(str(u.get("class", ""))) == "hq":
			enemy_hq = u
	for raw in stale_rows:
		if not raw is Dictionary:
			continue
		var u: Dictionary = raw
		if by_id.has(str(u.get("unit_id", ""))):
			continue
		stale.append(u)
	# Threat radius from CURRENT enemy reach (replaces fixed <= 4).
	var threat_radius := 2
	for raw in visible:
		if raw is Dictionary:
			threat_radius = maxi(threat_radius, mini(6, _enemy_reach(raw) + 1))
	var threatened := false
	if not own_hq.is_empty():
		for raw in visible:
			if _hex_distance(_point(raw), _point(own_hq)) <= threat_radius:
				threatened = true
				break
	return {"friendly": own_by_id, "friendly_list": friends, "visible": visible, "stale": stale,
		"visible_by_id": by_id, "own_hq": own_hq, "enemy_hq": enemy_hq,
		"hq_threatened": threatened, "ruleset": rs}


# ------------------------------------------------------------------
# Generalized V1 tactical layer (fixed ranges/divisors replaced)
# ------------------------------------------------------------------

func _tactical_score(c: Dictionary, ctx: Dictionary, obs: Dictionary, attacks: Dictionary) -> float:
	var rs := _rs(obs)
	var kind := str(c.get("action_type", "")).to_upper()
	var uid := str(c.get("unit_id", ""))
	var own: Dictionary = (ctx["friendly"] as Dictionary).get(uid, {})
	var own_cls := _norm_cls(str(own.get("class", "")))
	var sr := _sense_radius()
	var median := _median_strength()
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
		var tcls := _norm_cls(str(target.get("class", "")))
		var danger := 1.45 if (tcls in ["siege", "archer"] or _high_threat_class(tcls)) else 1.0
		var score := 3.0 + danger * (3.2 * kill_chance + 2.4 * clampf(mid_loss / maxf(median * 0.35, estimated), 0.0, 1.0))
		if tcls == "hq":
			score += 6.0
		score -= 2.2 * clampf(own_loss / maxf(median * 0.35, float(own.get("soldiers", 100))), 0.0, 1.0)
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
		var nearby_friends := _nearby_strength(dest, ctx["friendly_list"], uid, sr)
		var nearby_enemies := _nearby_strength(dest, ctx["visible"], "", sr)
		var score := clampf(nearby_friends / median, 0.0, 1.0) * 0.55
		if not (ctx["visible"] as Array).is_empty():
			score -= 0.7
		if nearby_enemies > nearby_friends + float(own.get("soldiers", 0)):
			score -= 2.5
		var strike := RulesetViewCls.get_range(rs, own_cls)
		if strike > 1 and near_enemy <= strike - 1:
			score -= 2.0
		if _soldier_fraction(own) < 0.4 and near_enemy <= 2:
			score -= 1.8
		if own_cls != "hq":
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
		var uid := str(first.get("unit_id", ""))
		var own: Dictionary = (ctx["friendly"] as Dictionary).get(uid, {})
		var strike := RulesetViewCls.get_range(_ruleset, _norm_cls(str(own.get("class", ""))))
		if not target.is_empty() and _hex_distance(_array_point(first.get("destination", [])), _point(target)) <= maxi(2, strike + 1):
			return 0.65
	return 0.0


# ------------------------------------------------------------------
# Generalized V2 helpers (rules-coupled spots only; rest inherited)
# ------------------------------------------------------------------

func _class_baseline(_cls: String) -> float:
	# Live per-class median; falls back to the army median, never to a
	# frozen roster table. Rebuilt per decision in _rebuild_baselines.
	var key := _norm_cls(_cls)
	if _dyn_baseline.has(key):
		return maxf(60.0, float(_dyn_baseline[key]))
	return _median_strength()


func _enemy_reach(e: Dictionary) -> int:
	var cls := _norm_cls(str(e.get("class", "")))
	var strike := RulesetViewCls.get_range(_ruleset, cls)
	var march := RulesetViewCls.march_allowance(_ruleset, cls)
	return strike + march


func _hunter_units(ctx: Dictionary) -> Array:
	# Fastest by CURRENT mobility table, then lowest id. No class-name check.
	var field: Array = []
	for fr_val in (ctx["friendly_list"] as Array):
		if fr_val is Dictionary:
			var u: Dictionary = fr_val
			if _norm_cls(str(u.get("class", ""))) != "hq" and int(u.get("soldiers", 0)) > 0:
				field.append(u)
	field.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var ma := RulesetViewCls.get_base_mp(_ruleset, _norm_cls(str(a.get("class", ""))))
		var mb := RulesetViewCls.get_base_mp(_ruleset, _norm_cls(str(b.get("class", ""))))
		if not is_equal_approx(ma, mb):
			return ma > mb
		return str(a.get("unit_id", "")) < str(b.get("unit_id", "")))
	var out: Array = []
	for u_val in field:
		if out.size() >= 2:
			break
		out.append(str((u_val as Dictionary).get("unit_id", "")))
	return out


# ------------------------------------------------------------------
# Generalized V2 battlefield eval: turn gates as turn_limit fractions
# (CONV 20/34/40 -> 0.33/0.57/0.67 of the CURRENT limit).
# ------------------------------------------------------------------

func _battlefield_eval(ctx: Dictionary, obs: Dictionary, turn: int) -> Dictionary:
	var limit := _turn_limit_of(obs)
	var conv_turn_min := maxi(4, int(float(limit) * 0.33))
	var conv_clock_turn := maxi(8, int(float(limit) * 0.57))
	var conv_siege_turn := maxi(10, int(float(limit) * 0.67))
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
		if _norm_cls(str(u.get("class", ""))) == "hq":
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
		if _norm_cls(str(e.get("class", ""))) == "hq":
			enemy_hq_strength = s
	for raw in (ctx["stale"] as Array):
		if raw is Dictionary:
			enemy_strength += 0.45 * _estimated_soldiers(raw)
	var enemy_hq: Dictionary = ctx["enemy_hq"]
	var enemy_hq_dist := 999
	if not enemy_hq.is_empty():
		enemy_hq_dist = _hex_distance(_point(own_hq) if not own_hq.is_empty() else Vector2i.ZERO, _point(enemy_hq))
	elif not own_hq.is_empty():
		enemy_hq_dist = _hex_distance(_point(own_hq), _mirror_point(_point(own_hq), obs))
	var total := maxf(1.0, own_strength + enemy_strength)
	var has_enemy_evidence := enemy_strength > 0.0
	var lead := (own_strength - enemy_strength) / total if has_enemy_evidence else 0.0
	var contact := not (ctx["visible"] as Array).is_empty()
	var phase := "parity"
	if has_enemy_evidence and lead > 0.16:
		phase = "ahead"
	elif has_enemy_evidence and lead < -0.22:
		phase = "behind"
	var hq_threatened := bool(ctx["hq_threatened"])
	var immediate_hq_danger := 0.0
	if not own_hq.is_empty():
		var hq_point2 := _point(own_hq)
		for raw2 in (ctx["visible"] as Array):
			if not raw2 is Dictionary:
				continue
			var e2: Dictionary = raw2
			var strike := RulesetViewCls.get_range(_ruleset, _norm_cls(str(e2.get("class", ""))))
			if _hex_distance(hq_point2, _point(e2)) <= strike:
				immediate_hq_danger += _estimated_soldiers(e2)
	var own_hq_garrison := 0.0
	if not own_hq.is_empty():
		own_hq_garrison = _estimated_soldiers(own_hq)
	if immediate_hq_danger > 0.0 and immediate_hq_danger >= 1.1 * maxf(120.0, own_hq_garrison):
		phase = "hq_emergency"
		hq_threatened = true
	elif immediate_hq_danger > 0.0:
		hq_threatened = true
	var stalled := int(_tendencies.get("stall_turns", 0)) >= 5 and contact
	var strong_gate := turn >= conv_turn_min and own_field >= 3 and own_weak == 0 \
		and _conv_field_morale_ok(ctx, CONV_MORALE_MIN) and enemy_strength > 0.0 \
		and own_strength >= CONV_FORCE_RATIO * enemy_strength
	var clock_gate := turn >= conv_clock_turn and own_field >= 3 and own_weak <= 1 \
		and _conv_field_morale_ok(ctx, 25.0) and enemy_visible_strength > 0.0 \
		and own_strength >= CONV_CLOCK_RATIO * enemy_visible_strength
	var siege_gate := turn >= conv_siege_turn and own_field >= 3 \
		and _conv_field_morale_ok(ctx, 25.0) and _turn_offers_assault
	var gate_open := (strong_gate or clock_gate or siege_gate) \
		and phase != "hq_emergency" \
		and immediate_hq_danger < CONV_HQ_MARGIN * maxf(120.0, own_hq_garrison)
	var conv_reason := "gate_closed"
	if gate_open:
		_conv_evidence_turns += 1
		conv_reason = "evidence_%d" % _conv_evidence_turns
	elif _conv_active_turns_left > 0 and phase != "hq_emergency" and not hq_threatened:
		_conv_evidence_turns = 0
	else:
		_conv_evidence_turns = 0
		if _conv_active_turns_left > 0:
			_conv_active_turns_left = 0
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
		"turn": turn, "hq_threatened": hq_threatened, "stalled": stalled,
		"turn_limit": limit}
	result["conv_active"] = conv_active
	result["conv_streak"] = _conv_streak
	result["conv_reason"] = conv_reason
	return result


# ------------------------------------------------------------------
# Generalized V2 per-candidate scoring: intercept march from live table.
# Only the rules-coupled intercept block differs from V2; the remaining
# ledger economics are already preview-relative and are inherited
# through a targeted pre/post adjustment instead of a full copy:
# ------------------------------------------------------------------

func _own_march(own: Dictionary) -> int:
	return RulesetViewCls.march_allowance(_ruleset, _norm_cls(str(own.get("class", ""))))


func _score_candidate(c: Dictionary, ctx: Dictionary, obs: Dictionary, eval: Dictionary, intent: Dictionary) -> Dictionary:
	# Temporarily nothing to patch inline: the inherited V2 ledger is fully
	# preview-relative. The one hardcoded spot (intercept march 2/3 by class
	# name) is corrected here by re-scoring the intercept terms when present.
	var out: Dictionary = super._score_candidate(c, ctx, obs, eval, intent)
	var kind := str(c.get("action_type", "")).to_upper()
	if kind != "MOVE":
		return out
	var uid := str(c.get("unit_id", ""))
	var own: Dictionary = (ctx["friendly"] as Dictionary).get(uid, {})
	if own.is_empty():
		return out
	var terms: Dictionary = out.get("terms", {})
	if not (terms.has("intercept_close") or terms.has("intercept_approach")):
		return out
	# Recompute the intercept bonus with the CURRENT strike+march reach. The
	# inherited block used fixed march 2 (3 for cavalry/scout); the corrected
	# values keep the same magnitudes, only the reach predicate changes.
	var dest := _array_point(c.get("destination", []))
	var threat_id := str(intent.get("focus_target_id", ""))
	var threat: Dictionary = (ctx["visible_by_id"] as Dictionary).get(threat_id, {})
	if threat.is_empty():
		return out
	var strike := RulesetViewCls.get_range(_ruleset, _norm_cls(str(own.get("class", ""))))
	var march := _own_march(own)
	var can_hit_now := _hex_distance(dest, _point(threat)) <= strike
	var can_hit_next := _hex_distance(dest, _point(threat)) <= strike + march
	var conservatism := 0.6
	if terms.has("intercept_close") and not can_hit_now:
		out["score"] = float(out["score"]) - float(terms["intercept_close"])
		(terms as Dictionary).erase("intercept_close")
		if can_hit_next:
			var approach := 2.4 + 1.2 * conservatism
			out["score"] = float(out["score"]) + approach
			(terms as Dictionary)["intercept_approach"] = snappedf(approach, 0.01)
	elif terms.has("intercept_approach") and not can_hit_next:
		out["score"] = float(out["score"]) - float(terms["intercept_approach"])
		(terms as Dictionary).erase("intercept_approach")
		if can_hit_now:
			var intercept := 4.2 + 2.0 * conservatism
			out["score"] = float(out["score"]) + intercept
			(terms as Dictionary)["intercept_close"] = snappedf(intercept, 0.01)
	return out


# ------------------------------------------------------------------
# Generalized endgame hunt: activation as a turn_limit fraction.
# ------------------------------------------------------------------

func _endgame_hunt(ctx: Dictionary, obs: Dictionary) -> Dictionary:
	var limit := _turn_limit_of(obs)
	var hunt_start := maxi(6, int(float(limit) * 0.32))
	var turn := int(_tendencies.get("turn", 0))
	if turn > _turn_high_water:
		_turn_high_water = turn
	if _turn_high_water < hunt_start:
		return {"active": false}
	var enemy_hq: Dictionary = ctx["enemy_hq"]
	if not enemy_hq.is_empty():
		_hunt_hq_known = true
		_hunt_anchor = _point(enemy_hq)
		_hunt_set = true
		_hunt_anchor_turn = turn
		return {"active": true, "point": _hunt_anchor, "anchor_turn": _hunt_anchor_turn}
	if _hunt_hq_known and _hunt_set:
		return {"active": true, "point": _hunt_anchor, "anchor_turn": _hunt_anchor_turn}
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
	return {"active": have, "point": _hunt_anchor, "anchor_turn": _hunt_anchor_turn}
