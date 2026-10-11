class_name Cloud1Observation
extends RefCounted

## CLOUD-GENERAL STEP 1A — SharedBattleObservation (single canonical source).
##
## Godot-owned structured tactical representation. The human inspector UI,
## the future Cloud-model serialized context, and debug output ALL originate
## from the Dictionary returned by build(). No parallel human/AI pipelines.
##
## Reads ONLY acting-side-authorized state:
##   friendly truth (own units) + fog-projected enemy contacts (visible/stale)
##   + observable events + live rule semantics. NEVER WorldTruth hidden state.
## Owns no game truth, duplicates no balance numbers (all rule values are
## live reads from Step3Config / CombatCalculator at build time).

const Step3ConfigCls = preload("res://scripts/core/step3_config.gd")
const EpisodeRuntimeCls = preload("res://scripts/episodes/episode_runtime.gd")
const CombatCalculatorCls = preload("res://scripts/combat/combat_calculator.gd")
const ClustersCls = preload("res://scripts/step7/step7_formation_clusters.gd")
const TableCls = preload("res://scripts/cloud1/cloud1_action_table.gd")
const ScopeAlgebraCls = preload("res://scripts/step7/step7_scope_algebra.gd")

const SCHEMA_VERSION := "cloud_step0_step1_v2"
const BATTLE_ID := "cloud_step1_neutral_skirmish"
const COORD_SYSTEM := "axial_flat_top"
const NEUTRAL_TERRAIN := true

const CORE_CLASSES := ["infantry", "archer", "cavalry", "spearman", "scout", "siege", "conscript", "hq"]
const MATCHUP_PROBE_PAIRS := [
	["cavalry", "archer"], ["archer", "spearman"], ["spearman", "cavalry"],
	["infantry", "archer"], ["infantry", "cavalry"], ["infantry", "spearman"],
	["siege", "infantry"], ["scout", "infantry"], ["conscript", "infantry"],
]


## Build the canonical observation for one acting side ("blue" default).
## Step 2 adds "red": the SAME builder with faction-relative framing —
## own units as FRIENDLY, the other side as ENEMY, same schema version.
## BLUE output is byte-identical to Step 1; RED mirrors it (labels, ledger
## keys, mission/rules framing, snapshot id, fingerprint prefixes).
## sim: SimController or Cloud1LiveBridge (same interface). opts: {map_bounds}.
static func build(sim: RefCounted, side: String = "blue") -> Dictionary:
	var s := side.to_lower()
	if s != "blue" and s != "red":
		return {"ok": false, "error": "Unknown side '%s' (want blue/red)." % side}
	if sim == null or not sim.is_loaded():
		return {"ok": false, "error": "No scenario loaded."}
	var mgr: RefCounted = sim.get_manager()
	var turn: int = int(mgr.get_current_turn())
	var bounds: Dictionary = sim.map_bounds()
	if bounds.is_empty():
		bounds = {"q_min": -30, "q_max": -20, "r_min": -5, "r_max": 5}
	var S := s.to_upper()
	var knowledge: Dictionary = sim.build_knowledge(s)
	var ledger: Dictionary = knowledge.get("ledger", {})
	var mission: Dictionary = sim.evaluate_mission()
	var mission_type := str(mission.get("primary_objective", "destroy_all_red"))
	var mission_status := str(mission.get("mission_status", "ongoing"))
	if not EpisodeRuntimeCls.episode_id().is_empty() and s == "red":
		mission_type = "destroy_blue_hq"
		if mission_status == "victory": mission_status = "defeat"
		elif mission_status == "defeat": mission_status = "victory"
	_ensure_clusters(mgr, turn, s)
	var friendlies := _friendly_units(mgr, bounds, s)
	var enemies := _known_enemies(ledger, bounds, s)
	var events := _recent_events(mgr)
	var rules := _rules_semantics(s)
	var catalog_families: Array = TableCls.family_ids()
	var state_version: int = sim.truth_version()
	var core := {
		"episode_context": EpisodeRuntimeCls.public_context(),
		"schema_version": SCHEMA_VERSION,
		"battle_id": BATTLE_ID,
		"scenario_id": sim.scenario_id(),
		"turn": turn,
		"phase": "ENGAGE",
		"side": S,
		"mission": {
			"type": mission_type,
			"objective": _objective_text(mission_type, s),
			"status": mission_status,
			"turn_limit": int(mission.get("turn_limit", 0)),
			"turns_elapsed": int(mission.get("turns_elapsed", turn)),
		},
		"board": {
			"coordinate_system": COORD_SYSTEM,
			"dimensions": {
				"q_min": int(bounds.get("q_min", -30)), "q_max": int(bounds.get("q_max", -20)),
				"r_min": int(bounds.get("r_min", -5)), "r_max": int(bounds.get("r_max", 5)),
			},
			"neutral_terrain": NEUTRAL_TERRAIN,
		},
		"friendly_units": friendlies,
		"known_enemy_units": enemies,
		"recent_events": events,
		"rules": rules,
		"available_action_families": catalog_families,
	}
	var fp := fingerprint_of(core, state_version, s)
	var snapshot_id := "step1_%s_t%d_%s_v%d_%s" % [BATTLE_ID, turn, S, state_version, fp.left(12)]
	var obs := {
		"ok": true,
		"episode_context": EpisodeRuntimeCls.public_context(),
		"schema_version": SCHEMA_VERSION,
		"snapshot_id": snapshot_id,
		"battle_id": BATTLE_ID,
		"scenario_id": sim.scenario_id(),
		"turn": turn,
		"phase": "ENGAGE",
		"side": S,
		"mission": core["mission"],
		"board": core["board"],
		"friendly_units": friendlies,
		"known_enemy_units": enemies,
		"recent_events": events,
		"rules": rules,
		"available_action_families": catalog_families,
		"parity": {
			"snapshot_id": snapshot_id,
			"state_version": state_version,
			"fingerprint": fp,
			"acting_side": S,
			"generated_at_turn": turn,
		},
	}
	return obs


static func _objective_text(primary: String, side: String = "blue") -> String:
	# BATTLE_TERMINAL_CONTRACT_V0: every objective carries the universal
	# HQ-terminal rule (own HQ loss = defeat, enemy HQ kill = victory).
	if side == "red":
		match primary:
			"destroy_blue_hq":
				return "Destroy the BLUE HQ. Losing the RED HQ loses at once."
			"destroy_red_hq":
				return "Destroy the BLUE HQ. Losing the RED HQ loses at once."
			"destroy_all_red":
				return "Destroy all BLUE field formations. Destroying the BLUE HQ wins at once; losing the RED HQ loses at once."
			"capture_capital":
				return "Defend the RED capital stronghold. Losing the RED HQ loses at once; destroying the BLUE HQ wins at once."
			"survive_turns", "hold_hq":
				return "Destroy the BLUE HQ before the turn limit. Losing the RED HQ loses at once."
		return "Complete the contracted objective. Losing the RED HQ loses at once; destroying the BLUE HQ wins at once."
	match primary:
		"destroy_red_hq":
			return "Destroy the RED HQ. Losing the BLUE HQ loses at once."
		"destroy_all_red":
			return "Destroy all RED field formations. Destroying the RED HQ wins at once; losing the BLUE HQ loses at once."
		"capture_capital":
			return "Breach or capture the RED capital stronghold. Destroying the RED HQ wins at once; losing the BLUE HQ loses at once."
		"survive_turns", "hold_hq":
			return "Keep the BLUE HQ alive past the turn limit; destroying the RED HQ wins at once."
	return "Complete the contracted objective. Losing the BLUE HQ loses at once; destroying the RED HQ wins at once."


static func _ensure_clusters(mgr: RefCounted, turn: int, side: String = "blue") -> void:
	var own: Array = []
	for u in mgr.get_all_units_including_garrisoned():
		if u is Dictionary and str((u as Dictionary).get("faction", "")) == side and int((u as Dictionary).get("soldier_count", 0)) > 0:
			own.append(u)
	if own.is_empty():
		return
	ClustersCls.refresh_side(own, side, turn)


static func _friendly_units(mgr: RefCounted, bounds: Dictionary = {}, side: String = "blue") -> Array:
	var out: Array = []
	var raw: Array = mgr.get_all_units_including_garrisoned()
	for u_val in raw:
		if not u_val is Dictionary:
			continue
		var u: Dictionary = u_val
		if str(u.get("faction", "")) != side:
			continue
		if int(u.get("soldier_count", 0)) <= 0:
			continue
		var acted := bool(u.get("action_ended", false))
		var status := "ready"
		if bool(u.get("routed", false)):
			status = "routed"
		elif bool(u.get("garrisoned", false)):
			status = "garrisoned"
		elif acted:
			status = "acted"
		var atk_targets: Array = mgr.get_attackable_targets(str(u.get("id", "")))
		var formation := ClustersCls.cluster_of_unit(u, side)
		if formation.is_empty():
			formation = "FIELD"
		var u_q := int(u.get("q", 0))
		var u_r := int(u.get("r", 0))
		var u_region := ScopeAlgebraCls.get_region_for_coord(u_q, u_r, bounds)
		out.append({
			"unit_id": str(u.get("id", "")),
			"side": side.to_upper(),
			"class": str(u.get("class", "infantry")).to_lower(),
			"q": u_q,
			"r": u_r,
			"region": u_region,
			"status": status,
			"has_acted": acted,
			"remaining_mp": snappedf(float(u.get("remaining_mp", 0.0)), 0.01),
			"base_mp": snappedf(float(u.get("base_mp", 0.0)), 0.01),
			"can_attack": not atk_targets.is_empty() and not acted and status == "ready",
			"attack_options": int(atk_targets.size()),
			"formation": formation,
			"soldiers": int(u.get("soldier_count", 0)),
			"condition": _condition_band(int(u.get("soldier_count", 0)), maxi(1, int(u.get("max_count", 1)))),
			"morale_band": _morale_band(float(u.get("morale", 100.0))),
		})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a.get("unit_id", "")) < str(b.get("unit_id", "")))
	return out


static func _known_enemies(ledger: Dictionary, bounds: Dictionary = {}, side: String = "blue") -> Array:
	# The RED ledger names its contact lists differently
	# (observed_blue_forces / last_known_blue_contacts); both shapes carry
	# the same canonical fields, so one reader covers both acting sides.
	var cur_key := "current_enemy_observations"
	var stale_key := "last_known_enemy_contacts"
	var foe := "RED"
	if side == "red":
		cur_key = "observed_blue_forces"
		stale_key = "last_known_blue_contacts"
		foe = "BLUE"
	var out: Array = []
	var seen_ids := {}
	for c_val in (ledger.get(cur_key, []) as Array):
		if not c_val is Dictionary:
			continue
		var c: Dictionary = c_val
		var uid := str(c.get("id", ""))
		if seen_ids.has(uid):
			continue
		seen_ids[uid] = true
		var cq := int(c.get("q", 0))
		var cr := int(c.get("r", 0))
		out.append({
			"unit_id": uid,
			"side": foe,
			"class": str(c.get("class", "unknown")).to_lower(),
			"q": cq,
			"r": cr,
			"region": ScopeAlgebraCls.get_region_for_coord(cq, cr, bounds),
			"contact_state": "current_visible",
			"troop_estimate": str(c.get("troop_text", "unknown")),
			"last_seen_turn": int(c.get("contact_turn", 0)),
		})
	for s_val in (ledger.get(stale_key, []) as Array):
		if not s_val is Dictionary:
			continue
		var s2: Dictionary = s_val
		var suid := str(s2.get("id", ""))
		if seen_ids.has(suid):
			continue
		seen_ids[suid] = true
		var sq := int(s2.get("q", 0))
		var sr := int(s2.get("r", 0))
		out.append({
			"unit_id": suid,
			"side": foe,
			"class": str(s2.get("class", "unknown")).to_lower(),
			"q": sq,
			"r": sr,
			"region": ScopeAlgebraCls.get_region_for_coord(sq, sr, bounds),
			"contact_state": "stale_last_known",
			"troop_estimate": str(s2.get("troop_text", "unknown")),
			"last_seen_turn": int(s2.get("last_seen_turn", 0)),
		})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a.get("unit_id", "")) < str(b.get("unit_id", "")))
	return out


static func _recent_events(mgr: RefCounted) -> Array:
	var out: Array = []
	if not mgr.has_method("get_observable_events"):
		return out
	var all: Array = mgr.get_observable_events()
	var start := maxi(0, all.size() - 8)
	for i in range(start, all.size()):
		var e: Variant = all[i]
		if e is Dictionary:
			var row := (e as Dictionary).duplicate(true)
			out.append(_sanitize(row))
	return out


## Rule semantics: every number is a LIVE read (no copied constants).
static func _rules_semantics(side: String = "blue") -> Dictionary:
	var move_by_class := {}
	for c in CORE_CLASSES:
		move_by_class[c] = snappedf(Step3ConfigCls.get_base_movement(c), 0.01)
	var range_by_class := {}
	for c2 in CORE_CLASSES:
		range_by_class[c2] = CombatCalculatorCls.get_attack_range(c2)
	var advantages: Array = []
	for pair in MATCHUP_PROBE_PAIRS:
		var m := CombatCalculatorCls.get_matchup_mult(str(pair[0]), str(pair[1]))
		if m > 1.01:
			advantages.append("%s>%s" % [str(pair[0]), str(pair[1])])
		elif m < 0.99:
			advantages.append("%s>%s" % [str(pair[1]), str(pair[0])])
	advantages.sort()
	return {
		"movement": {
			"note": "Base march points per class on neutral plains. Godot pathfinding decides legal destinations.",
			"base_mp_by_class": move_by_class,
		},
		"attack": {
			"note": "Range and matchup values are in the episode context and live rules below.",
			"range_by_class": range_by_class,
			"matchup_advantage": advantages,
		},
		"turn": {
			"note": "Each BLUE formation acts once per turn (move or attack or hold). END TURN refreshes movement and the enemy routine runs." if side != "red" else "Each RED formation acts once per turn (move or attack or hold). END TURN refreshes movement and the opposing phase runs.",
		},
		"mission": {
			"note": "BLUE loses if its HQ is destroyed or all BLUE formations fall. Victory follows the contracted objective." if side != "red" else "RED loses if its HQ is destroyed or all RED formations fall. Victory follows the contracted objective.",
		},
	}


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


## Deterministic tactical fingerprint over the canonical core (no wall-clock).
static func fingerprint_of(core: Dictionary, state_version: int, side: String = "blue") -> String:
	var pf := "R:" if side == "red" else "B:"
	var pe := "B:" if side == "red" else "R:"
	var parts: Array = [str(core.get("schema_version", "")), "t=%d" % int(core.get("turn", 0)), "v=%d" % state_version]
	var episode: Dictionary = core.get("episode_context", {})
	if not episode.is_empty():
		parts.append("episode=" + str(episode.get("episode_id", "")))
	for u_val in (core.get("friendly_units", []) as Array):
		var u: Dictionary = u_val
		parts.append(pf + "%s:%d,%d:%s:mp%s:acted%s:sol%d:%s" % [
			str(u.get("unit_id", "?")), int(u.get("q", 0)), int(u.get("r", 0)),
			str(u.get("region", "")),
			str(u.get("remaining_mp", "?")), str(u.get("has_acted", "?")),
			int(u.get("soldiers", 0)), str(u.get("status", "?")),
		])
	for e_val in (core.get("known_enemy_units", []) as Array):
		var e2: Dictionary = e_val
		parts.append(pe + "%s:%d,%d:%s:%s" % [
			str(e2.get("unit_id", "?")), int(e2.get("q", 0)), int(e2.get("r", 0)),
			str(e2.get("region", "")),
			str(e2.get("contact_state", "?")),
		])
	var mission: Dictionary = core.get("mission", {})
	parts.append("mission=%s:%s" % [str(mission.get("type", "?")), str(mission.get("status", "?"))])
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(("|".join(parts)).to_utf8_buffer())
	return ctx.finish().hex_encode()


## Deterministic compact JSON (fixed field order; sorted unit arrays).
static func to_json(obs: Dictionary, pretty: bool = false) -> String:
	var ordered := {
		"schema_version": str(obs.get("schema_version", SCHEMA_VERSION)),
		"snapshot_id": str(obs.get("snapshot_id", "")),
		"battle_id": str(obs.get("battle_id", BATTLE_ID)),
		"scenario_id": str(obs.get("scenario_id", "")),
		"turn": int(obs.get("turn", 0)),
		"phase": str(obs.get("phase", "ENGAGE")),
		"side": str(obs.get("side", "BLUE")),
		"episode_context": obs.get("episode_context", {}),
		"mission": obs.get("mission", {}),
		"board": obs.get("board", {}),
		"friendly_units": obs.get("friendly_units", []),
		"known_enemy_units": obs.get("known_enemy_units", []),
		"recent_events": obs.get("recent_events", []),
		"rules": obs.get("rules", {}),
		"available_action_families": obs.get("available_action_families", []),
		"parity": obs.get("parity", {}),
	}
	return JSON.stringify(ordered, "  " if pretty else "")


static func _sanitize(value: Variant) -> Variant:
	if value is Vector2i:
		var v: Vector2i = value
		return [v.x, v.y]
	if value is Vector2:
		var w: Vector2 = value
		return [w.x, w.y]
	if value is Color:
		var c: Color = value
		return [c.r, c.g, c.b, c.a]
	if value is Dictionary:
		var out: Dictionary = {}
		for k in (value as Dictionary).keys():
			out[str(k)] = _sanitize((value as Dictionary)[k])
		return out
	if value is Array:
		var cells: Array = []
		for item in (value as Array):
			cells.append(_sanitize(item))
		return cells
	if value is Object:
		return str(value)
	return value
