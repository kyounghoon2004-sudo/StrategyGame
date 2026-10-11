class_name Step7AdvisorContext
extends RefCounted

## BLUE-authorized tactical context builder for the Ollama Advisor pilot.
##
## Reads ONLY player-authorized sources:
##   - the deterministic OptionPackage (Step7CavalryEvaluator output);
##   - BLUE Knowledge (own forces, currently-visible contacts, retained
##     stale/last-known contacts, logistics bands);
##   - adaptive formation cluster geometry (frozen bands, membership);
##   - mission/turn/intent facts already visible to the BLUE player.
##
## NEVER reads WorldTruth, RED hidden state, fog internals, or exact enemy
## vitals (troop counts, morale, supply, plans). The audit block in the
## returned context records exactly which enemy sources were used so DEV
## can verify the boundary per request.

const ClustersScript = preload("res://scripts/step7/step7_formation_clusters.gd")
const HexUtilsScript = preload("res://scripts/core/hex_utils.gd")

## Mirrors HexCell.TerrainType order (0..13). Local copy keeps this builder
## free of render/cell-object dependencies.
const TERRAIN_NAMES := [
	"plains", "mountains", "forest", "swamp", "fortress", "village",
	"road", "river", "wall", "stronghold_interior", "stronghold_wall",
	"capital_interior", "capital_wall", "outer_mountains",
]

const NEARBY_HEXES := 6

## Fields that must never appear in an LLM-bound enemy record. The builder
## never copies them; the auditor asserts their absence.
const ENEMY_FORBIDDEN_FIELDS := [
	"soldier_count", "max_count", "morale", "food", "fatigue",
	"local_supply", "supply_days", "remaining_mp", "base_mp",
	"plan", "orders", "destination", "target",
]


static func terrain_name_of(cell_data: Dictionary, q: int, r: int) -> String:
	var cell: Variant = cell_data.get("%d,%d" % [q, r], null)
	if cell == null:
		return "unknown"
	var t := -1
	if cell is Dictionary:
		t = int((cell as Dictionary).get("terrain", -1))
	elif "terrain" in cell:
		t = int(cell.get("terrain"))
	if t >= 0 and t < TERRAIN_NAMES.size():
		return str(TERRAIN_NAMES[t])
	return "unknown"


static func _condition_band(soldiers: int, max_count: int) -> String:
	var pct := float(soldiers) / float(maxi(1, max_count))
	if pct >= 0.75:
		return "healthy"
	if pct >= 0.4:
		return "weakened"
	return "critical"


static func _morale_band(morale: float) -> String:
	if morale >= 70.0:
		return "steady"
	if morale >= 40.0:
		return "shaken"
	return "fragile"


## Main entry. Returns {ok, context, audit} or {ok:false, error}.
## deps: {package, unit, blue_knowledge, cell_data, intent, state_version,
##        fingerprint, cluster_signature, request_id}
static func build(deps: Dictionary) -> Dictionary:
	var package: Dictionary = deps.get("package", {})
	var unit: Dictionary = deps.get("unit", {})
	var blue_knowledge: Dictionary = deps.get("blue_knowledge", {})
	if package.is_empty() or unit.is_empty():
		return {"ok": false, "error": "Missing option package or selected unit."}
	var options: Array = package.get("options", [])
	if options.is_empty():
		return {"ok": false, "error": "Option package has no options."}

	var intent: Dictionary = deps.get("intent", {"action": "ADVANCE", "direction": "FORWARD"})
	var cell_data: Dictionary = deps.get("cell_data", {})
	var request_id := str(deps.get("request_id", ""))
	var origin := Vector2i(int(unit.get("q", 0)), int(unit.get("r", 0)))

	var cluster := ClustersScript.cluster_of_unit(unit)
	var unit_class := str(unit.get("class", "cavalry")).to_upper()
	var mission := _mission_block(blue_knowledge, intent, unit_class)
	var formation := _formation_block(unit, origin, cluster, blue_knowledge, cell_data, unit_class)
	var friendlies := _friendly_block(unit, origin, blue_knowledge)
	var enemies := _enemy_block(blue_knowledge)
	var option_list := _options_block(options, cell_data)
	var identity := {
		"state_version": int(deps.get("state_version", -1)),
		"selected_unit_id": str(unit.get("id", "")),
		"selected_unit_position": [origin.x, origin.y],
		"cluster_signature": str(deps.get("cluster_signature", "")),
		"option_package_fingerprint": str(deps.get("fingerprint",
			package.get("fingerprint", ""))),
		"candidate_count": int(package.get("candidate_count", 0)),
		"known_contacts_used": int(package.get("known_contacts_used", 0)),
		"intent": {
			"action": str(intent.get("action", "ADVANCE")).to_upper(),
			"direction": str(intent.get("direction", "FORWARD")).to_upper(),
			"axis": str((package.get("intent", {}) as Dictionary).get("axis", "FORWARD")),
		},
		"request_id": request_id,
	}
	var audit := {
		"blue_sources": ["own_forces", "current_enemy_observations",
			"last_known_enemy_contacts", "option_package_provenance"],
		"current_visible_contacts": (enemies.get("current_visible", []) as Array).size(),
		"stale_contacts": (enemies.get("stale_last_known", []) as Array).size(),
		"hidden_fields_excluded": ENEMY_FORBIDDEN_FIELDS.duplicate(),
		"world_truth_read": false,
		"hidden_enemy_ids_exposed": [],
	}
	var supplied := _supplied_ids(unit, blue_knowledge, enemies, option_list, formation)
	var context := {
		"advisor": "seo_yuseon",
		"role": "tactical_advisor",
		"_supplied_ids": supplied,
		"mission": mission,
		"selected_formation": formation,
		"friendly_context": friendlies,
		"authorized_enemy_knowledge": enemies,
		"options": option_list,
		"state_identity": identity,
		"response_contract": {
			"recommended_option_id": "one of the supplied option ids (AVAILABLE or DEGRADED only)",
			"confidence": "number 0.0-1.0",
			"reason": "concise Korean rationale, references supplied facts only",
			"primary_risk": "principal risk in Korean",
			"alternative_option_id": "second choice id, or empty string",
			"alternative_reason": "why the alternative is worth considering, in Korean",
			"battlefield_assessment": "short overall assessment in Korean",
		},
	}
	return {"ok": true, "context": context, "audit": audit}


static func _mission_block(blue_knowledge: Dictionary, intent: Dictionary,
		unit_class: String = "CAVALRY") -> Dictionary:
	var logistics: Dictionary = blue_knowledge.get("logistics", {})
	var turn := int(blue_knowledge.get("current_turn", 1))
	return {
		"battle": "Hulao-Luoyang approach (Step 7 tactical pilot)",
		"strategic_objective": "BLUE advances east from Fortress_Hulao toward Capital_Luoyang.",
		"operational_objective": "Move the selected %s formation forward while preserving cohesion and retreat options." % unit_class.to_lower(),
		"current_intent": {
			"action": str(intent.get("action", "ADVANCE")).to_upper(),
			"direction": str(intent.get("direction", "FORWARD")).to_upper(),
			"note": "Choose HOW to realize this intent from the supplied options. Do not change the intent itself, but warn if it looks dangerous.",
		},
		"turn": turn,
		"army_condition": {
			"blue_formations": int(logistics.get("formation_count", 0)),
			"average_morale_band": _morale_band(float(logistics.get("average_morale", 100.0))),
			"portable_supply": snappedf(float(logistics.get("portable_supply", 0.0)), 0.1),
		},
	}


static func _formation_block(unit: Dictionary, origin: Vector2i, cluster: String,
		blue_knowledge: Dictionary, cell_data: Dictionary,
		unit_class: String = "CAVALRY") -> Dictionary:
	var soldiers := int(unit.get("soldier_count", 0))
	var max_count := maxi(1, int(unit.get("max_count", soldiers)))
	var same_cluster: Array = []
	var wing_count := 0
	var wing := ClustersScript.wing_of_cluster(cluster)
	for f_val in (blue_knowledge.get("own_forces", []) as Array):
		if not f_val is Dictionary:
			continue
		var f: Dictionary = f_val
		if str(f.get("id", "")) == str(unit.get("id", "")):
			continue
		var fpos := Vector2i(int(f.get("q", 0)), int(f.get("r", 0)))
		var fcluster := ClustersScript.cluster_of_hex(fpos.x, fpos.y)
		if fcluster == cluster and str(f.get("class", "")).to_upper() == unit_class.to_upper():
			same_cluster.append(str(f.get("id", "")))
		if not wing.is_empty() and ClustersScript.wing_of_cluster(fcluster) == wing:
			wing_count += 1
	same_cluster.sort()
	return {
		"id": str(unit.get("id", "")),
		"class": str(unit.get("class", "")),
		"position": [origin.x, origin.y],
		"terrain_here": terrain_name_of(cell_data, origin.x, origin.y),
		"cluster": cluster,
		"macro_wing": wing,
		"condition": _condition_band(soldiers, max_count),
		"morale": _morale_band(float(unit.get("morale", 100.0))),
		"supply_days": snappedf(float(unit.get("local_supply", 0.0)) / float(max_count) * 100.0, 0.1),
		"movement_remaining": snappedf(float(unit.get("remaining_mp", 0.0)), 0.1),
		"movement_base": snappedf(float(unit.get("base_mp", 0.0)), 0.1),
		"already_acted": bool(unit.get("action_ended", false)),
		"same_cluster_cavalry": same_cluster,
		"macro_wing_blue_formations": wing_count,
	}


static func _friendly_block(unit: Dictionary, origin: Vector2i,
		blue_knowledge: Dictionary) -> Dictionary:
	var own_id := str(unit.get("id", ""))
	var nearby: Array = []
	for f_val in (blue_knowledge.get("own_forces", []) as Array):
		if not f_val is Dictionary:
			continue
		var f: Dictionary = f_val
		var fid := str(f.get("id", ""))
		if fid == own_id:
			continue
		var fpos := Vector2i(int(f.get("q", 0)), int(f.get("r", 0)))
		var dist := HexUtilsScript.hex_distance_axial(origin, fpos)
		if dist > NEARBY_HEXES:
			continue
		nearby.append({
			"id": fid,
			"class": str(f.get("class", "unknown")),
			"position": [fpos.x, fpos.y],
			"hexes_away": dist,
			"cluster": ClustersScript.cluster_of_hex(fpos.x, fpos.y),
			"movement_remaining": snappedf(float(f.get("remaining_mp", 0.0)), 0.1),
			"condition": _condition_band(int(f.get("soldier_count", 0)),
				maxi(1, int(f.get("max_count", 1)))),
		})
	nearby.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if int(a["hexes_away"]) == int(b["hexes_away"]):
			return str(a["id"]) < str(b["id"])
		return int(a["hexes_away"]) < int(b["hexes_away"]))
	return {
		"nearby_window_hexes": NEARBY_HEXES,
		"nearby_blue_formations": nearby,
		"note": "Only BLUE formations within %d hexes are listed. Positions are current BLUE knowledge." % NEARBY_HEXES,
	}


## Enemy records carry ONLY projector-authorized fields. Exact vitals are
## never copied (see ENEMY_FORBIDDEN_FIELDS).
static func _enemy_block(blue_knowledge: Dictionary) -> Dictionary:
	var current: Array = []
	for c_val in (blue_knowledge.get("current_enemy_observations", []) as Array):
		if not c_val is Dictionary:
			continue
		var c: Dictionary = c_val
		current.append({
			"contact_id": str(c.get("id", "?")),
			"contact_state": "current_visible",
			"class": str(c.get("class", "unknown")),
			"position": [int(c.get("q", 0)), int(c.get("r", 0))],
			"troop_estimate": str(c.get("troop_text", "unknown")),
			"scout_observed": bool(c.get("scout_observed", false)),
			"combat_assessed": bool(c.get("combat_assessed", false)),
		})
	var stale: Array = []
	for s_val in (blue_knowledge.get("last_known_enemy_contacts", []) as Array):
		if not s_val is Dictionary:
			continue
		var s: Dictionary = s_val
		stale.append({
			"contact_id": str(s.get("id", "?")),
			"contact_state": "stale_last_known",
			"class": str(s.get("class", "unknown")),
			"last_seen_position": [int(s.get("q", 0)), int(s.get("r", 0))],
			"last_seen_turn": int(s.get("last_seen_turn", 0)),
			"troop_estimate_at_last_sighting": str(s.get("troop_text", "unknown")),
			"warning": "Position may be outdated. Do NOT treat as a current fact.",
		})
	current.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a["contact_id"]) < str(b["contact_id"]))
	stale.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a["contact_id"]) < str(b["contact_id"]))
	return {
		"current_visible": current,
		"stale_last_known": stale,
		"fog_rule": "Only the contacts above exist for you. Never invent enemy units, positions, or strengths. Stale contacts are uncertain by definition.",
	}


static func _options_block(options: Array, cell_data: Dictionary) -> Array:
	var out: Array = []
	for o_val in options:
		if not o_val is Dictionary:
			continue
		var o: Dictionary = o_val
		var dest: Dictionary = o.get("destination", {})
		var route: Dictionary = o.get("route", {})
		var path: Array = route.get("path", [])
		var risk: Dictionary = o.get("risk", {})
		var contribs: Array = []
		for c_val in (o.get("contributions", []) as Array):
			if not c_val is Dictionary:
				continue
			var c: Dictionary = c_val
			contribs.append({
				"feature": str(c.get("feature", "?")),
				"raw": snappedf(float(c.get("raw", 0.0)), 0.01),
				"weight": snappedf(float(c.get("weight", 0.0)), 0.01),
				"contribution": snappedf(float(c.get("contribution", 0.0)), 0.01),
			})
		var prov: Dictionary = o.get("provenance", {})
		out.append({
			"id": str(o.get("profile", "?")).to_upper(),
			"slot": int(o.get("slot", 0)),
			"status": str(o.get("status", "UNAVAILABLE")).to_upper(),
			"status_reason": str(o.get("reason", "")),
			"destination": {"q": int(dest.get("q", 0)), "r": int(dest.get("r", 0))} if not dest.is_empty() else {},
			"destination_terrain": terrain_name_of(cell_data,
				int(dest.get("q", 0)), int(dest.get("r", 0))) if not dest.is_empty() else "none",
			"route": {
				"cost": snappedf(float(route.get("cost", 0.0)), 0.01),
				"steps": path.size(),
				"path": path,
			} if not dest.is_empty() else {},
			"utility": snappedf(float(o.get("utility", 0.0)), 0.01),
			"risk": {
				"overall": snappedf(float(risk.get("overall", 0.0)), 0.01),
				"pressure": snappedf(float(risk.get("pressure", 0.0)), 0.01),
				"support": snappedf(float(risk.get("support", 0.0)), 0.01),
				"mobility": snappedf(float(risk.get("mobility", 0.0)), 0.01),
				"intent_progress": snappedf(float(risk.get("intent_progress", 0.0)), 0.01),
			} if not risk.is_empty() else {},
			"top_strengths": (o.get("top_positive", []) as Array).duplicate(),
			"top_concerns": (o.get("top_negative", []) as Array).duplicate(),
			"feature_contributions": contribs,
			"provenance": {
				"supporting_visible_contacts": (prov.get("known_ids", []) as Array).duplicate(),
				"supporting_stale_contacts": (prov.get("stale_ids", []) as Array).duplicate(),
				"objective_fallback_to_advance": bool(prov.get("objective_fallback", true)),
			},
		})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a["slot"]) < int(b["slot"]))
	return out


## Every BLUE-authorized id the model may name: full own roster (all
## player knowledge) + authorized contacts + provenance ids + formation.
static func _supplied_ids(unit: Dictionary, blue_knowledge: Dictionary,
		enemies: Dictionary, option_list: Array, formation: Dictionary) -> Array:
	var out: Array = []
	for f_val in (blue_knowledge.get("own_forces", []) as Array):
		if f_val is Dictionary:
			out.append(str((f_val as Dictionary).get("id", "")))
	for key in ["current_visible", "stale_last_known"]:
		for c_val in (enemies.get(key, []) as Array):
			if c_val is Dictionary:
				var cid := str((c_val as Dictionary).get("contact_id", ""))
				if not cid in out:
					out.append(cid)
	for o_val in option_list:
		if not o_val is Dictionary:
			continue
		var prov: Dictionary = (o_val as Dictionary).get("provenance", {})
		for key in ["supporting_visible_contacts", "supporting_stale_contacts"]:
			for id_val in (prov.get(key, []) as Array):
				if not str(id_val) in out:
					out.append(str(id_val))
	out.append(str(unit.get("id", "")))
	for fid in (formation.get("same_cluster_cavalry", []) as Array):
		if not str(fid) in out:
			out.append(str(fid))
	return out


## DEV audit: serialize the context and assert no forbidden enemy field
## name appears inside the enemy section. Returns "" when clean.
static func audit_enemy_section(context: Dictionary) -> String:
	var enemies: Dictionary = (context.get("authorized_enemy_knowledge", {}) as Dictionary)
	var text := JSON.stringify(enemies)
	for field in ENEMY_FORBIDDEN_FIELDS:
		if text.find("\"" + field + "\"") >= 0:
			return "forbidden enemy field '%s' present in LLM context" % field
	return ""


## All BLUE-authorized contact ids supplied to the model (for the
## hallucination screen: model text referencing other ids is flagged).
static func supplied_contact_ids(context: Dictionary) -> Array:
	var out: Array = []
	var enemies: Dictionary = (context.get("authorized_enemy_knowledge", {}) as Dictionary)
	for key in ["current_visible", "stale_last_known"]:
		for c_val in (enemies.get(key, []) as Array):
			if c_val is Dictionary:
				out.append(str((c_val as Dictionary).get("contact_id", "")))
	var options: Array = context.get("options", [])
	for o_val in options:
		if not o_val is Dictionary:
			continue
		var prov: Dictionary = (o_val as Dictionary).get("provenance", {})
		for key in ["supporting_visible_contacts", "supporting_stale_contacts"]:
			for id_val in (prov.get(key, []) as Array):
				if not str(id_val) in out:
					out.append(str(id_val))
	var form: Dictionary = context.get("selected_formation", {})
	out.append(str(form.get("id", "")))
	for fid in (form.get("same_cluster_cavalry", []) as Array):
		out.append(str(fid))
	for f_val in (((context.get("friendly_context", {}) as Dictionary).get("nearby_blue_formations", [])) as Array):
		if f_val is Dictionary:
			out.append(str((f_val as Dictionary).get("id", "")))
	# Preferred: the exact id set the builder authorized (includes the full
	# BLUE roster whether or not every formation fell in the nearby window).
	for sid in (context.get("_supplied_ids", []) as Array):
		if not str(sid) in out:
			out.append(str(sid))
	return out
