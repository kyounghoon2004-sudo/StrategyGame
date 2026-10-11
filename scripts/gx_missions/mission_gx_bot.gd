extends "res://scripts/utility_bot/utility_bot_generalized.gd"

## GX MISSIONS v1 — mission-conditioned GX (extends the existing GX; no second architecture).
##
## With no `mission.family` in the observation every method falls through to UtilityBotGeneralized
## (byte-identical legacy behaviour). With a mission:
##   * MissionPolicy(family) supplies per-unit objective targets; they replace "enemy HQ" in the
##     objective / pressure features (V0 + V1 goal point) and drive the V2 intent loci;
##   * mission intents (TAKE_AREA, DEFEND_AREA, HOLD_FORTRESS, SIEGE_WALL, EXPLOIT_BREACH, FIELD_CONCENTRATE,
##     BUILD_BASE, CONTEST_SITE, RAID_BASE, PROTECT_SUPPLY, HQ_STRIKE) join the V2 intent set; the
##     HQ-race intents (config intents.drop_types) leave it;
##   * per-family multipliers scale existing V2 terms; additive mission terms apply at every tier;
##   * HQ opportunity layer: the HQ is a target only when reachable, killable and weakly guarded
##     (HQ_STRIKE); the endgame hunt toward the enemy HQ runs only while that window is open.
## Tiers BASIC/INTER/ADV and the 4 styles are untouched and apply on top of every family.

const PolicyCls = preload("res://scripts/gx_missions/mission_policy.gd")
const MissionCfgCls = preload("res://scripts/gx_missions/mission_config.gd")

var _mctx: Dictionary = {"on": false}
## Telemetry for the DEV harness / tests (read-only for callers).
var hq_strike_turns: Dictionary = {}
var hq_opportunity_max := 0.0
var intent_counts: Dictionary = {}


func _mission_on() -> bool:
	return bool(_mctx.get("on", false))


func select_action(observation: Dictionary, candidates: Array) -> Dictionary:
	_mctx = {"on": false}
	if not str((observation.get("mission", {}) as Dictionary).get("family", "")).is_empty() and _configured:
		var commit := float(_doctrine.get("objective_commitment", 0.6))
		_mctx = PolicyCls.evaluate(observation, _rs(observation), commit)
		var opp := float((_mctx.get("hq", {}) as Dictionary).get("opportunity", 0.0))
		hq_opportunity_max = maxf(hq_opportunity_max, opp)
		if bool((_mctx.get("hq", {}) as Dictionary).get("open", false)):
			hq_strike_turns[_turn_of(observation)] = snappedf(opp, 0.001)
	var out: Dictionary = super.select_action(observation, candidates)
	if _mission_on() and _depth >= 2 and not _intent.is_empty():
		var t := str(_intent.get("type", ""))
		intent_counts[t] = int(intent_counts.get(t, 0)) + 1
	return out


func _objective_unit(uid: String) -> Dictionary:
	var t: Variant = (_mctx.get("targets", {}) as Dictionary).get(uid, null)
	var hq: Dictionary = _mctx.get("hq", {})
	if bool(hq.get("open", false)) and uid in (hq.get("strike_set", []) as Array) and hq.get("enemy_hq_point", null) != null:
		t = hq["enemy_hq_point"]
	if t == null:
		return {}
	return {"unit_id": "__mission_objective__", "class": "objective", "q": (t as Vector2i).x, "r": (t as Vector2i).y,
		"contact_state": "objective"}


## ctx copy whose "enemy_hq" anchor is the unit's mission objective (or nothing): the inherited
## objective/goal terms then progress toward the mission target instead of the enemy HQ.
func _mission_ctx(ctx: Dictionary, uid: String) -> Dictionary:
	var c2 := ctx.duplicate()
	c2["enemy_hq"] = _objective_unit(uid)
	return c2


func _features(c: Dictionary, ctx: Dictionary, obs: Dictionary) -> Dictionary:
	if not _mission_on():
		return super._features(c, ctx, obs)
	var uid := str(c.get("unit_id", ""))
	var f: Dictionary = super._features(c, _mission_ctx(ctx, uid), obs)
	if str(c.get("action_type", "")).to_upper() == "MOVE":
		# Enrichment wrote enemy-HQ progress into objective/pressure: replace with mission progress.
		var own: Dictionary = (ctx["friendly"] as Dictionary).get(uid, {})
		var obj := _objective_unit(uid)
		var w := MissionCfgCls.section("weights")
		if not obj.is_empty() and not own.is_empty() and _norm_cls(str(own.get("class", ""))) != "hq":
			var p := _point(obj)
			var prog := float(_hex_distance(_point(own), p) - _hex_distance(_array_point(c.get("destination", [])), p))
			var v := clampf(prog * float(w["objective_feature_scale"]), -float(w["objective_feature"]), float(w["objective_feature"]))
			f["objective"] = v
			f["pressure"] = v
		else:
			f["objective"] = 0.0
			f["pressure"] = minf(0.0, float(f.get("pressure", 0.0)))
	if _depth < 2:
		var own2: Dictionary = (ctx["friendly"] as Dictionary).get(uid, {})
		f["_mission"] = float(PolicyCls.candidate_bonus(c, _mctx, own2, ctx["visible_by_id"])["score"])
	return f


func _score(features: Dictionary) -> float:
	var base: float = super._score(features)
	if absf(base) >= TERMINAL_GATE:
		return base
	return base + float(features.get("_mission", 0.0))


func _tactical_score(c: Dictionary, ctx: Dictionary, obs: Dictionary, attacks: Dictionary) -> float:
	if not _mission_on():
		return super._tactical_score(c, ctx, obs, attacks)
	return super._tactical_score(c, _mission_ctx(ctx, str(c.get("unit_id", ""))), obs, attacks)


func _score_candidate(c: Dictionary, ctx: Dictionary, obs: Dictionary, eval: Dictionary, intent: Dictionary) -> Dictionary:
	var out: Dictionary = super._score_candidate(c, ctx, obs, eval, intent)
	if not _mission_on() or absf(float(out.get("score", 0.0))) >= TERMINAL_GATE:
		return out
	var terms: Dictionary = out.get("terms", {})
	var score := float(out.get("score", 0.0))
	# Per-family multipliers on existing V2 terms (config family_multipliers.<F>.v2_<term>).
	for k in (_mctx.get("mult", {}) as Dictionary).keys():
		var key := str(k)
		if key.begins_with("v2_") and terms.has(key.substr(3)):
			var old := float(terms[key.substr(3)])
			var new_v := old * float(_mctx["mult"][key])
			score += new_v - old
			terms[key.substr(3)] = snappedf(new_v, 0.01)
	var own: Dictionary = (ctx["friendly"] as Dictionary).get(str(c.get("unit_id", "")), {})
	# OCCUPATION: the HQ is the base builder, so the V2 "HQ anchors in place" penalty is lifted while a site waits.
	if terms.has("hq_anchor") and str(_mctx.get("family", "")) == "M4" and _mctx.get("hq_target", null) != null:
		var relief := float(MissionCfgCls.section("weights")["hq_anchor_relief"])
		score += relief
		terms["m_hq_anchor_relief"] = relief
	var bonus: Dictionary = PolicyCls.candidate_bonus(c, _mctx, own, ctx["visible_by_id"])
	for k in (bonus["terms"] as Dictionary).keys():
		terms[k] = snappedf(float(bonus["terms"][k]), 0.01)
	score += float(bonus["score"])
	out["score"] = score
	out["terms"] = terms
	return out


func _score_intents(ctx: Dictionary, obs: Dictionary, eval: Dictionary) -> Array:
	var base: Array = super._score_intents(ctx, obs, eval)
	if not _mission_on():
		return base
	var drop: Array = MissionCfgCls.section("intents").get("drop_types", [])
	var fmul: Dictionary = (MissionCfgCls.section("intents").get("family_intent_multipliers", {}) as Dictionary) 		.get(str(_mctx.get("family", "")), {})
	var out: Array = []
	for row in base:
		var t := str((row as Dictionary).get("type", ""))
		if not t in drop:
			if fmul.has(t):
				row["score"] = float(row["score"]) * float(fmul[t])
			out.append(row)
	for row in (_mctx.get("intents", []) as Array):
		out.append((row as Dictionary).duplicate())
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if is_equal_approx(float(a["score"]), float(b["score"])):
			return str(a["type"]) < str(b["type"])
		return float(a["score"]) > float(b["score"]))
	return out


func _default_intent(eval: Dictionary) -> Dictionary:
	if not _mission_on() or (_mctx.get("intents", []) as Array).is_empty():
		return super._default_intent(eval)
	var row: Dictionary = (_mctx["intents"] as Array)[0]
	return {"type": str(row["type"]), "locus": row["locus"], "focus_target_id": "",
		"formed_turn": int(eval.get("turn", 0)), "ttl": 1, "score": float(row["score"]), "note": "mission_fallback"}


func _endgame_hunt(ctx: Dictionary, obs: Dictionary) -> Dictionary:
	if not _mission_on():
		return super._endgame_hunt(ctx, obs)
	var hq: Dictionary = _mctx.get("hq", {})
	if bool(hq.get("open", false)) and hq.get("enemy_hq_point", null) != null:
		return {"active": true, "point": hq["enemy_hq_point"], "anchor_turn": _turn_of(obs)}
	return {"active": false}


func profile() -> Dictionary:
	var p: Dictionary = super.profile()
	p["mission_gx"] = "GX_MISSIONS_V1"
	return p
