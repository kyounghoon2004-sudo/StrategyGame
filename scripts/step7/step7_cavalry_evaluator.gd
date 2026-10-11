class_name Step7CavalryEvaluator
extends RefCounted

## Shared tactical evaluator (all combat classes): ONE expensive pass, SIX
## cheap heads. File/class names stay stable (scene + probe compatibility);
## the doctrine is data-driven per unit class via Step7UnitDoctrines.
## Candidate generation + routes: canonical BattleCommandService.
## Knowledge: BlueKnowledge dict + projector.known_occupancy("blue") ONLY.
## Never mutates state. Never reads WorldTruth hidden units.

const DoctrineScript = preload("res://scripts/step7/step7_cavalry_doctrine.gd")
const DoctrinesScript = preload("res://scripts/step7/step7_unit_doctrines.gd")
const FeaturesScript = preload("res://scripts/step7/step7_cavalry_features.gd")
const ClustersScript = preload("res://scripts/step7/step7_formation_clusters.gd")

var _cache_key := ""
var _cache_vectors: Array = []
var _cache_meta := {}


static func intent_axis(intent: Dictionary) -> String:
	var action := str(intent.get("action", "ADVANCE")).to_upper()
	var direction := str(intent.get("direction", "FORWARD")).to_upper()
	if action == "FLANK":
		return "RIGHT" if direction in ["RIGHT", "FORWARD", ""] else "LEFT"
	return "FORWARD"


func evaluate(unit_id: String, intent: Dictionary, command_service: RefCounted,
		blue_knowledge: Dictionary, cell_data: Dictionary, known_occupied: Dictionary,
		state_version: int, fingerprint: String, cluster_context: Dictionary = {}) -> Dictionary:
	var t0 := Time.get_ticks_usec()
	var axis := intent_axis(intent)
	var cache_ms := 0.0
	var ctx_bit := "%s>%s|%s>%s" % [str(cluster_context.get("requested_cluster", "")),
		str(cluster_context.get("target_cluster", "")),
		str(cluster_context.get("requested_sector", "")),
		str(cluster_context.get("target_sector", ""))]
	var t_reach := Time.get_ticks_usec()
	var unit: Dictionary = command_service.call("get_unit", unit_id)
	var unit_class := str(unit.get("class", "")).to_upper()
	var doctrine := DoctrinesScript.for_class(unit_class)
	if unit.is_empty() or doctrine.is_empty():
		return {"ok": false, "error": "NO_DOCTRINE",
			"detail": "No tactical doctrine for class '%s'." % unit_class,
			"unit_class": unit_class}
	var key := "%s|%s|%s|%s|%s" % [fingerprint, unit_id, axis,
		str(doctrine.get("version", "?")), ctx_bit]
	var cache_hit := key == _cache_key and not _cache_vectors.is_empty()
	var area: Dictionary = command_service.call("reachable_area", unit_id, "blue", "auto")
	if not bool(area.get("ok", false)):
		return _empty_options(unit_id, intent, axis, state_version, fingerprint, "No reachable area.")
	var budget := maxf(float(unit.get("remaining_mp", 3.0)), 0.5)
	var reach_list: Array = area.get("reachable", [])
	var reach_ms := float(Time.get_ticks_usec() - t_reach) / 1000.0

	# Routes once per candidate (canonical preview; also what execution will use).
	var t_route := Time.get_ticks_usec()
	var entries: Array = []
	for row_val in reach_list:
		var row: Dictionary = row_val
		var dest := Vector2i(int(row.get("q", 0)), int(row.get("r", 0)))
		var route: Variant = command_service.call("preview_move_route", unit_id, dest, "blue", "auto")
		if route == null or not bool(route.found) or not bool(route.is_valid_destination):
			continue
		entries.append({"q": dest.x, "r": dest.y, "cost": float(route.cost), "path": route.path})
	var route_ms := float(Time.get_ticks_usec() - t_route) / 1000.0

	var t_feat := Time.get_ticks_usec()
	var vectors: Array = []
	if cache_hit:
		vectors = _cache_vectors
		cache_ms = 0.0
	else:
		var bk_cache: Dictionary = FeaturesScript.build_cache(blue_knowledge, cell_data)
		var combat := {"counter_classes": DoctrinesScript.counter_classes(unit_class),
			"access_mode": DoctrinesScript.access_mode(unit_class)}
		vectors = FeaturesScript.extract(unit, entries, cell_data, known_occupied,
			bk_cache, axis, budget, cluster_context, unit_class.to_lower(), combat)
		_cache_key = key
		_cache_vectors = vectors
		_cache_meta = {"contacts": (bk_cache.get("contacts", []) as Array).size()}
	var feat_ms := float(Time.get_ticks_usec() - t_feat) / 1000.0

	# Six cheap heads (doctrine-driven).
	var t_heads := Time.get_ticks_usec()
	var slots: Array = []
	var best_intent := 0.001
	for v in vectors:
		best_intent = maxf(best_intent, float((v["features"] as Dictionary).get("INTENT_PROGRESS", 0.0)))
	for profile in (DoctrinesScript.PROFILES as Array):
		slots.append(_score_profile(doctrine, str(profile), vectors, best_intent, axis))
	var heads_ms := float(Time.get_ticks_usec() - t_heads) / 1000.0

	var t_pack := Time.get_ticks_usec()
	var dup_groups: Array = _dup_groups(slots)
	var risk_fn := func(v: Dictionary) -> Dictionary: return _risk(v)
	for s in slots:
		var sd: Dictionary = s
		if sd.has("_vec"):
			sd["risk"] = risk_fn.call(sd["_vec"])
			sd.erase("_vec")
	var pack_ms := float(Time.get_ticks_usec() - t_pack) / 1000.0
	var total_ms := float(Time.get_ticks_usec() - t0) / 1000.0

	return {"ok": true, "unit_id": unit_id, "unit_class": unit_class,
		"doctrine": str(doctrine.get("version", "?")),
		"intent": {"action": str(intent.get("action", "ADVANCE")).to_upper(),
			"direction": str(intent.get("direction", "FORWARD")).to_upper(), "axis": axis},
		"cluster_context": {"requested_cluster": str(cluster_context.get("requested_cluster", "")).to_upper(),
			"target_cluster": str(cluster_context.get("target_cluster", "")).to_upper()},
		"state_version": state_version, "fingerprint": fingerprint,
		"options": slots, "duplicate_destination_groups": dup_groups,
		"candidate_count": vectors.size(),
		"feature_count": (doctrine.get("features", []) as Array).size(),
		"latency": {"battlefield_cache_ms": cache_ms, "reachability_ms": reach_ms,
			"route_resolution_ms": route_ms,
			"feature_extraction_ms": feat_ms, "six_profile_scoring_ms": heads_ms,
			"option_packaging_ms": pack_ms, "total_ms": total_ms},
		"cache_hit": cache_hit,
		"known_contacts_used": int(_cache_meta.get("contacts", 0))}


## Cluster entry: resolve FORMATION_CLUSTER_CLASS to live formations of the
## requested class (default CAVALRY preserves every legacy caller), evaluate
## ONE representative formation through the six-profile heads, and return
## the package. Representative = furthest along FORWARD axis, id tie-break
## (deterministic). Full N-formation group optimization is DEFERRED —
## execution reuses the deterministic sequential replanning path per unit.
func evaluate_cluster(cluster: String, intent: Dictionary, command_service: RefCounted,
		unit_manager: RefCounted, blue_knowledge: Dictionary, cell_data: Dictionary,
		known_occupied: Dictionary, state_version: int, fingerprint: String,
		target_cluster: String = "", unit_class: String = "CAVALRY") -> Dictionary:
	var c := cluster.strip_edges().to_upper()
	var members := ClustersScript.resolve_cluster_class(c, unit_class, "blue", unit_manager)
	if members.is_empty():
		var empty := _empty_options("", intent, intent_axis(intent), state_version, fingerprint, "empty scope: no BLUE %s in %s" % [unit_class.to_lower(), c])
		empty["cluster"] = c
		empty["member_ids"] = []
		empty["representative"] = ""
		return empty
	var rep := _representative(members)
	var ctx := {"requested_cluster": c}
	if not target_cluster.strip_edges().is_empty():
		ctx["target_cluster"] = target_cluster.strip_edges().to_upper()
	var res := evaluate(rep, intent, command_service, blue_knowledge, cell_data,
		known_occupied, state_version, fingerprint, ctx)
	res["cluster"] = c
	res["member_ids"] = _sorted_ids(members)
	res["representative"] = rep
	return res


## Macro wing entry: union of the wing's clusters (LEFT = all L*, CENTER = C,
## RIGHT = all R*). Same representative rule; scope purity holds by union.
func evaluate_wing(wing: String, intent: Dictionary, command_service: RefCounted,
		unit_manager: RefCounted, blue_knowledge: Dictionary, cell_data: Dictionary,
		known_occupied: Dictionary, state_version: int, fingerprint: String,
		target_cluster: String = "", unit_class: String = "CAVALRY") -> Dictionary:
	var w := wing.strip_edges().to_upper()
	var members := ClustersScript.resolve_wing_class(w, unit_class, "blue", unit_manager)
	if members.is_empty():
		var empty := _empty_options("", intent, intent_axis(intent), state_version, fingerprint, "empty scope: no BLUE %s in wing %s" % [unit_class.to_lower(), w])
		empty["wing"] = w
		empty["member_ids"] = []
		empty["representative"] = ""
		return empty
	var rep := _representative(members)
	var ctx := {"requested_wing": w}
	if not target_cluster.strip_edges().is_empty():
		ctx["target_cluster"] = target_cluster.strip_edges().to_upper()
	var res := evaluate(rep, intent, command_service, blue_knowledge, cell_data,
		known_occupied, state_version, fingerprint, ctx)
	res["wing"] = w
	res["member_ids"] = _sorted_ids(members)
	res["representative"] = rep
	return res


## LEGACY shim: fixed-sector pilot entry. Maps LEFT_WING/CENTER/RIGHT_WING to
## the macro-wing evaluator above. New callers: evaluate_cluster().
func evaluate_sector(sector: String, intent: Dictionary, command_service: RefCounted,
		unit_manager: RefCounted, blue_knowledge: Dictionary, cell_data: Dictionary,
		known_occupied: Dictionary, state_version: int, fingerprint: String,
		target_sector: String = "") -> Dictionary:
	var s := sector.strip_edges().to_upper()
	var res := evaluate_wing(s.replace("_WING", ""), intent, command_service,
		unit_manager, blue_knowledge, cell_data, known_occupied,
		state_version, fingerprint)
	res["sector"] = s
	return res


static func _sorted_ids(members: Array) -> Array:
	var ids: Array = []
	for m in members:
		ids.append(str((m as Dictionary).get("id", "")))
	ids.sort()
	return ids


static func _representative(members: Array) -> String:
	var rep := str((members[0] as Dictionary).get("id", ""))
	var best_q := -(1 << 30)
	for m in members:
		var md: Dictionary = m
		var q := int(md.get("q", 0))
		var mid := str(md.get("id", ""))
		if q > best_q or (q == best_q and mid < rep):
			best_q = q
			rep = mid
	return rep


func _score_profile(doctrine: Dictionary, profile: String, vectors: Array,
		best_intent: float, axis: String) -> Dictionary:
	var floor_frac: float = float((doctrine.get("min_intent", {}) as Dictionary).get(profile, 0.2))
	var caps: Dictionary = doctrine.get("caps", {})
	var deep: Dictionary = doctrine.get("deep", {})
	var scored: Array = []
	for v in vectors:
		var f: Dictionary = v["features"]
		var contrib: Array = []
		var neg_ct := 0.0
		var pos_ma := 0.0
		var u := 0.0
		for feat in (doctrine.get("features", []) as Array):
			var w := DoctrinesScript.final_weight(doctrine, str(feat), profile)
			var raw := clampf(float(f.get(feat, 0.0)), 0.0, 1.0)
			var c := w * raw
			if feat in ["MATCHUP_OPPORTUNITY", "ARCHER_ACCESS"]:
				pos_ma += maxf(c, 0.0)
			if feat in ["COUNTER_RISK", "THREAT_EXPOSURE"]:
				neg_ct += minf(c, 0.0)
			contrib.append({"feature": feat, "raw": raw, "weight": w, "contribution": c})
		# Correlation caps (§4): scale back over-counted pairs.
		var ma_scale := 1.0
		if pos_ma > float(caps.get("matchup_archer", 2.5)):
			ma_scale = float(caps.get("matchup_archer", 2.5)) / pos_ma
		for c in contrib:
			if str(c["feature"]) in ["MATCHUP_OPPORTUNITY", "ARCHER_ACCESS"]:
				c["contribution"] = float(c["contribution"]) * ma_scale
		var ct_scale := 1.0
		if -neg_ct > float(caps.get("counter_threat", 3.0)):
			ct_scale = float(caps.get("counter_threat", 3.0)) / -neg_ct
		for c in contrib:
			if str(c["feature"]) in ["COUNTER_RISK", "THREAT_EXPOSURE"]:
				c["contribution"] = float(c["contribution"]) * ct_scale
		for c in contrib:
			u += float(c["contribution"])
		# DEEP vetoes (high-risk, never suicidal; doctrine-calibrated).
		var veto := ""
		if profile == "DEEP":
			if float(f.get("MOBILITY_FUTURE", 0.0)) < float(deep.get("min_mobility", 0.15)) and float(f.get("RETREAT_SAFETY", 0.0)) < float(deep.get("min_retreat", 0.1)):
				veto = "dead-end: no mobility and no retreat"
			elif float(f.get("COUNTER_RISK", 0.0)) > float(deep.get("max_counter", 0.85)):
				veto = "catastrophic known spearman counter-risk"
			elif float(f.get("TERRAIN_MOBILITY", 0.0)) <= 0.01:
				veto = "mobility trap terrain"
		scored.append({"vec": v, "utility": u, "contrib": contrib, "veto": veto})
	# Eligible = clears intent floor + no veto.
	var elig: Array = []
	for s in scored:
		var ip := float((s["vec"]["features"] as Dictionary).get("INTENT_PROGRESS", 0.0))
		if ip + 1e-9 >= best_intent * floor_frac and str(s["veto"]).is_empty():
			elig.append(s)
	var primary: String = str((doctrine.get("primary", {}) as Dictionary).get(profile, "INTENT_PROGRESS"))
	elig.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if abs(float(a["utility"]) - float(b["utility"])) > 1e-9:
			return float(a["utility"]) > float(b["utility"])
		var fa := float((a["vec"]["features"] as Dictionary).get(primary, 0.0))
		var fb := float((b["vec"]["features"] as Dictionary).get(primary, 0.0))
		if abs(fa - fb) > 1e-9:
			return fa > fb
		if abs(float(a["vec"]["cost"]) - float(b["vec"]["cost"])) > 1e-9:
			return float(a["vec"]["cost"]) < float(b["vec"]["cost"])
		if int(a["vec"]["q"]) == int(b["vec"]["q"]):
			return int(a["vec"]["r"]) < int(b["vec"]["r"])
		return int(a["vec"]["q"]) < int(b["vec"]["q"]))
	var status := "AVAILABLE"
	var reason := ""
	var pick: Variant = null
	if elig.is_empty():
		if vectors.is_empty():
			status = "UNAVAILABLE"
			reason = "no legal candidates"
		elif profile == "DEEP":
			status = "UNAVAILABLE"
			reason = "no legal deep-maneuver candidate clears vetoes/intent floor"
		else:
			status = "UNAVAILABLE"
			reason = "no legal candidate satisfies the intent/profile contract"
	else:
		pick = elig[0]
		reason = _degraded_reason(profile, pick)
		if not reason.is_empty():
			status = "DEGRADED"
	var slot := {"slot": DoctrinesScript.PROFILES.find(profile) + 1, "profile": profile,
		"status": status, "reason": reason}
	if pick != null:
		var pv: Dictionary = pick["vec"]
		var f: Dictionary = pv["features"]
		var pos: Array = []
		var neg: Array = []
		var sorted_c: Array = (pick["contrib"] as Array).duplicate()
		sorted_c.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return abs(float(a["contribution"])) > abs(float(b["contribution"])))
		for c in sorted_c:
			if float(c["contribution"]) > 0.01 and pos.size() < 3:
				pos.append("%s +%.2f" % [str(c["feature"]), float(c["contribution"])])
			elif float(c["contribution"]) < -0.01 and neg.size() < 3:
				neg.append("%s %.2f" % [str(c["feature"]), float(c["contribution"])])
		slot["destination"] = {"q": int(pv["q"]), "r": int(pv["r"])}
		slot["route"] = {"cost": float(pv["cost"]), "path": _path_to_arr(pv["path"])}
		slot["utility"] = float(pick["utility"])
		slot["top_positive"] = pos
		slot["top_negative"] = neg
		slot["contributions"] = pick["contrib"]
		slot["provenance"] = {"known_ids": pv.get("known_ids", []),
			"stale_ids": pv.get("stale_ids", []),
			"objective_fallback": bool(pv.get("objective_fallback", true))}
		slot["_vec"] = {"q": int(pv["q"]), "r": int(pv["r"]), "features": f}
	return slot


func _degraded_reason(profile: String, pick: Dictionary) -> String:
	var f: Dictionary = pick["vec"]["features"]
	match profile:
		"SAFE":
			if float(f.get("COUNTER_RISK", 0.0)) > 0.6:
				return "safest legal option still faces known counter-risk"
			if float(f.get("RETREAT_SAFETY", 0.0)) < 0.3:
				return "limited disengagement geometry"
		"SUPPORTED":
			if float(f.get("ISOLATION_RISK", 0.0)) > 0.6:
				return "all advancing options pull away from support"
		"PRESSURE":
			if (pick["vec"] as Dictionary).get("known_ids", []).is_empty():
				return "no favorable target; using positional pressure"
		"DEEP":
			if float(f.get("RETREAT_SAFETY", 0.0)) < 0.3 or float(f.get("ISOLATION_RISK", 0.0)) > 0.6:
				return "deep maneuver accepted with weak exit/support"
		"MAXIMUM":
			if float(f.get("TERRAIN_MOBILITY", 1.0)) < 0.4:
				return "maximal progress crosses poor cavalry ground"
	return ""


func _risk(v: Dictionary) -> Dictionary:
	var f: Dictionary = v.get("features", {})
	return {"overall": clampf((float(f.get("COUNTER_RISK", 0.0)) + float(f.get("THREAT_EXPOSURE", 0.0)) + float(f.get("ISOLATION_RISK", 0.0))) / 3.0, 0.0, 1.0),
		"pressure": float(f.get("PRESSURE_VALUE", 0.0)),
		"support": float(f.get("FORMATION_SUPPORT", 0.0)),
		"mobility": float(f.get("MOBILITY_FUTURE", 0.0)),
		"intent_progress": float(f.get("INTENT_PROGRESS", 0.0)),
		"information": float(f.get("INFORMATION_GAIN", 0.0)),
		"screen": float(f.get("SCREEN_PROTECTION", 0.0)),
		"denial": float(f.get("CAVALRY_DENIAL", 0.0))}


func _dup_groups(slots: Array) -> Array:
	var by_hex := {}
	for s in slots:
		if not (s as Dictionary).has("destination"):
			continue
		var d: Dictionary = (s as Dictionary)["destination"]
		var k := "%d,%d" % [int(d.get("q", 0)), int(d.get("r", 0))]
		if not by_hex.has(k):
			by_hex[k] = []
		(by_hex[k] as Array).append(str((s as Dictionary).get("profile", "?")))
	var groups: Array = []
	for k in by_hex.keys():
		if (by_hex[k] as Array).size() > 1:
			groups.append({"destination": k, "profiles": by_hex[k]})
	return groups


func _path_to_arr(path: Array) -> Array:
	var a: Array = []
	for p in path:
		if p is Vector2i:
			a.append([int(p.x), int(p.y)])
	return a


func _empty_options(unit_id: String, intent: Dictionary, axis: String, sv: int, fp: String, why: String) -> Dictionary:
	var slots: Array = []
	for pi in range(DoctrinesScript.PROFILES.size()):
		slots.append({"slot": pi + 1, "profile": str(DoctrinesScript.PROFILES[pi]),
			"status": "UNAVAILABLE", "reason": why})
	return {"ok": true, "unit_id": unit_id,
		"intent": {"action": str(intent.get("action", "ADVANCE")).to_upper(),
			"direction": str(intent.get("direction", "FORWARD")).to_upper(), "axis": axis},
		"state_version": sv, "fingerprint": fp, "options": slots,
		"duplicate_destination_groups": [], "candidate_count": 0,
		"feature_count": 0,
		"latency": {"battlefield_cache_ms": 0.0, "reachability_ms": 0.0,
			"route_resolution_ms": 0.0,
			"feature_extraction_ms": 0.0, "six_profile_scoring_ms": 0.0,
			"option_packaging_ms": 0.0, "total_ms": 0.0},
		"cache_hit": false, "known_contacts_used": 0}
