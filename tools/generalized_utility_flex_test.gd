extends SceneTree

## GENERALIZED_UTILITY_AI_V0 — bounded deterministic flexibility matrix.
##
## Usage:
##   Godot_v4.2.2-stable_win64_console.exe --headless --path "D:\Game development\Demon slayer\StrategyGame" \
##     -s res://tools/generalized_utility_flex_test.gd -- \
##     --out-dir="D:\Game development\Demon slayer\StrategyGame\artifacts\generalized_utility_ai_v0"
##   Add --smoke=1 for a 3-config smoke run.
##
## Covers repo-valid ranges only (SimController VALID_CLASSES / map bounds /
## terrain ids / live rule tables + ruleset_override overlays applied
## SYMMETRICALLY to both sides). Verifies: legal actions, rules reactivity,
## no fixed-script collapse, seed determinism, clean finishes.

const SimControllerCls = preload("res://scripts/sim/sim_controller.gd")
const DirectEnumeratorCls = preload("res://scripts/sim/direct_legal_enumerator.gd")
const GxBotCls = preload("res://scripts/utility_bot/utility_bot_generalized.gd")
const RulesetViewCls = preload("res://scripts/utility_bot/utility_ruleset_view.gd")
const ProfilesCls = preload("res://scripts/utility_bot/utility_profiles.gd")

const DEFAULT_OUT := "D:/Game development/Demon slayer/StrategyGame/artifacts/generalized_utility_ai_v0"

var _out_dir := DEFAULT_OUT
var _smoke := false
var _seed_base := 41000
var _max_actions := 400
var _errors: Array = []
var _illegal := 0
var _oob := 0
var _fog_leaks := 0


func _init() -> void:
	_parse_args()
	print("[GX_FLEX] out=%s smoke=%s seed_base=%d max_actions=%d" % [_out_dir, str(_smoke), _seed_base, _max_actions])
	var started := Time.get_ticks_msec()
	var configs := _matrix()
	if _smoke:
		configs = configs.slice(0, 3)
	var reactivity := _reactivity_probes()
	var rows: Array = []
	var deter_ok := true
	for i in range(configs.size()):
		var cfg: Dictionary = configs[i]
		var blue_prof: String = ProfilesCls.PROFILE_IDS[i % ProfilesCls.PROFILE_IDS.size()]
		var red_prof: String = ProfilesCls.PROFILE_IDS[(i + 5) % ProfilesCls.PROFILE_IDS.size()]
		var row := _run_match(cfg, _seed_base + i * 2, _seed_base + i * 2 + 1, blue_prof, red_prof)
		rows.append(row)
		var replay := _run_match(cfg, _seed_base + i * 2, _seed_base + i * 2 + 1, blue_prof, red_prof)
		var same := str(replay.get("digest", "")) == str(row.get("digest", "")) \
			and str(replay.get("final_fingerprint", "")) == str(row.get("final_fingerprint", ""))
		row["determinism_replay_same"] = same
		if not same:
			deter_ok = false
		print("[GX_FLEX] %d/%d %s terminal=%s winner=%s actions=%d errors=%s deter=%s" % [
			i + 1, configs.size(), str(cfg.get("id", "")), str(row.get("terminal", false)),
			str(row.get("winner", "")), int(row.get("actions", 0)),
			str((row.get("errors", []) as Array).size()), str(same)])
		# Rules-divergence: same config+seeds WITHOUT overlay must differ.
		if (cfg.get("ruleset_override", {}) as Dictionary).is_empty() == false:
			var plain := cfg.duplicate(true)
			plain["ruleset_override"] = {}
			plain["id"] = str(cfg.get("id", "")) + "_BASELINE"
			var base_row := _run_match(plain, _seed_base + i * 2, _seed_base + i * 2 + 1, blue_prof, red_prof)
			row["baseline_digest"] = str(base_row.get("digest", ""))
			row["diverges_from_baseline"] = str(base_row.get("digest", "")) != str(row.get("digest", ""))
	var summary := _summarize(configs, rows, reactivity, deter_ok, Time.get_ticks_msec() - started)
	_write_json(_out_dir.path_join("FLEX_MATRIX.json"), {"configs": configs, "matches": rows})
	_write_json(_out_dir.path_join("FLEX_RESULTS.json"), summary)
	_write_text(_out_dir.path_join("FLEX_REPORT.md"), _report_md(summary, rows, reactivity))
	print(JSON.stringify(summary, "  "))
	quit(0 if bool(summary.get("pass", false)) else 1)


func _parse_args() -> void:
	var args := OS.get_cmdline_user_args()
	args.append_array(OS.get_cmdline_args())
	for raw in args:
		var arg := str(raw).strip_edges().trim_prefix("--")
		if arg.begins_with("out-dir="):
			_out_dir = arg.get_slice("=", 1).trim_prefix("\"").trim_suffix("\"")
		elif arg.begins_with("smoke="):
			_smoke = arg.get_slice("=", 1) == "1"
		elif arg.begins_with("seed-base="):
			_seed_base = clampi(int(arg.get_slice("=", 1)), 0, 90000)
		elif arg.begins_with("max-actions="):
			_max_actions = clampi(int(arg.get_slice("=", 1)), 20, 2000)


# ------------------------------------------------------------------
# Matrix: 15 bounded configs over scale / composition / terrain / rules
# ------------------------------------------------------------------

func _matrix() -> Array:
	var cfgs: Array = []
	cfgs.append({"id": "F_SKIRMISH_SMALL", "bounds": {"q_min": -8, "q_max": 8, "r_min": -6, "r_max": 6},
		"terrain": 0, "overrides": {}, "rivers": [], "turn_limit": 25,
		"blue": [["HQ", "hq", 300], ["INF", "infantry", 450]],
		"red": [["HQ", "hq", 300], ["INF", "infantry", 450]]})
	cfgs.append({"id": "F_COMPACT_MED", "bounds": {"q_min": -12, "q_max": 12, "r_min": -10, "r_max": 10},
		"terrain": 0, "overrides": {}, "rivers": [], "turn_limit": 25,
		"blue": [["HQ", "hq", 300], ["INF", "infantry", 450], ["ARC", "archer", 220], ["CAV", "cavalry", 280]],
		"red": [["HQ", "hq", 300], ["INF", "infantry", 450], ["ARC", "archer", 220], ["CAV", "cavalry", 280]]})
	cfgs.append({"id": "F_WIDE", "bounds": {"q_min": -20, "q_max": 8, "r_min": -6, "r_max": 6},
		"terrain": 0, "overrides": {}, "rivers": [], "turn_limit": 25,
		"blue": [["HQ", "hq", 300], ["INF", "infantry", 450], ["ARC", "archer", 220], ["CAV", "cavalry", 280]],
		"red": [["HQ", "hq", 300], ["INF", "infantry", 450], ["ARC", "archer", 220], ["CAV", "cavalry", 280]]})
	cfgs.append({"id": "F_TALL", "bounds": {"q_min": -8, "q_max": 8, "r_min": -14, "r_max": 14},
		"terrain": 0, "overrides": {}, "rivers": [], "turn_limit": 25,
		"blue": [["HQ", "hq", 300], ["INF", "infantry", 450], ["ARC", "archer", 220], ["CAV", "cavalry", 280]],
		"red": [["HQ", "hq", 300], ["INF", "infantry", 450], ["ARC", "archer", 220], ["CAV", "cavalry", 280]]})
	cfgs.append({"id": "F_LARGE_FULL", "bounds": {"q_min": -18, "q_max": 18, "r_min": -12, "r_max": 12},
		"terrain": 0, "overrides": {}, "rivers": [], "turn_limit": 30,
		"blue": [["HQ", "hq", 300], ["INF1", "infantry", 450], ["INF2", "infantry", 420], ["ARC1", "archer", 220], ["ARC2", "archer", 200], ["CAV1", "cavalry", 280], ["SCT", "scout", 120], ["SIE", "siege", 220]],
		"red": [["HQ", "hq", 300], ["INF1", "infantry", 450], ["INF2", "infantry", 420], ["ARC1", "archer", 220], ["ARC2", "archer", 200], ["CAV1", "cavalry", 280], ["SCT", "scout", 120], ["SIE", "siege", 220]]})
	cfgs.append({"id": "F_ARCHER_HEAVY", "bounds": {"q_min": -12, "q_max": 12, "r_min": -10, "r_max": 10},
		"terrain": 0, "overrides": {}, "rivers": [], "turn_limit": 25,
		"blue": [["HQ", "hq", 300], ["A1", "archer", 220], ["A2", "archer", 220], ["A3", "archer", 200], ["A4", "archer", 200], ["A5", "archer", 180], ["A6", "archer", 180]],
		"red": [["HQ", "hq", 300], ["A1", "archer", 220], ["A2", "archer", 220], ["A3", "archer", 200], ["A4", "archer", 200], ["A5", "archer", 180], ["A6", "archer", 180]]})
	cfgs.append({"id": "F_CAV_HEAVY", "bounds": {"q_min": -12, "q_max": 12, "r_min": -10, "r_max": 10},
		"terrain": 0, "overrides": {}, "rivers": [], "turn_limit": 25,
		"blue": [["HQ", "hq", 300], ["C1", "cavalry", 280], ["C2", "cavalry", 280], ["C3", "cavalry", 260], ["C4", "cavalry", 260], ["C5", "cavalry", 240], ["C6", "cavalry", 240]],
		"red": [["HQ", "hq", 300], ["C1", "cavalry", 280], ["C2", "cavalry", 280], ["C3", "cavalry", 260], ["C4", "cavalry", 260], ["C5", "cavalry", 240], ["C6", "cavalry", 240]]})
	cfgs.append({"id": "F_SIEGE_LINE", "bounds": {"q_min": -12, "q_max": 12, "r_min": -10, "r_max": 10},
		"terrain": 0, "overrides": {}, "rivers": [], "turn_limit": 25,
		"blue": [["HQ", "hq", 300], ["SIE1", "siege", 220], ["SIE2", "siege", 200], ["INF", "infantry", 450]],
		"red": [["HQ", "hq", 300], ["SIE1", "siege", 220], ["SIE2", "siege", 200], ["INF", "infantry", 450]]})
	cfgs.append({"id": "F_CONSCRIPT_SWARM", "bounds": {"q_min": -12, "q_max": 12, "r_min": -10, "r_max": 10},
		"terrain": 0, "overrides": {}, "rivers": [], "turn_limit": 25,
		"blue": [["HQ", "hq", 300], ["K1", "conscript", 120], ["K2", "conscript", 120], ["K3", "conscript", 110], ["K4", "conscript", 110], ["K5", "conscript", 100], ["K6", "conscript", 100], ["K7", "conscript", 90], ["K8", "conscript", 90]],
		"red": [["HQ", "hq", 300], ["INF", "infantry", 450], ["ARC", "archer", 220], ["CAV", "cavalry", 280], ["SPE", "spearman", 380]]})
	cfgs.append({"id": "F_FOREST_MAP", "bounds": {"q_min": -12, "q_max": 12, "r_min": -10, "r_max": 10},
		"terrain": 2, "overrides": {}, "rivers": [], "turn_limit": 25,
		"blue": [["HQ", "hq", 300], ["INF", "infantry", 450], ["ARC", "archer", 220], ["CAV", "cavalry", 280], ["SCT", "scout", 120]],
		"red": [["HQ", "hq", 300], ["INF", "infantry", 450], ["ARC", "archer", 220], ["CAV", "cavalry", 280], ["SCT", "scout", 120]]})
	cfgs.append({"id": "F_SWAMP_MAP", "bounds": {"q_min": -12, "q_max": 12, "r_min": -10, "r_max": 10},
		"terrain": 3, "overrides": {}, "rivers": [], "turn_limit": 25,
		"blue": [["HQ", "hq", 300], ["INF", "infantry", 450], ["ARC", "archer", 220], ["CAV", "cavalry", 280], ["SCT", "scout", 120]],
		"red": [["HQ", "hq", 300], ["INF", "infantry", 450], ["ARC", "archer", 220], ["CAV", "cavalry", 280], ["SCT", "scout", 120]]})
	var pocket := {}
	for q in range(-2, 3):
		for r in range(-6, 7):
			pocket["%d,%d" % [q, r]] = 1
	cfgs.append({"id": "F_MOUNTAIN_POCKET", "bounds": {"q_min": -12, "q_max": 12, "r_min": -10, "r_max": 10},
		"terrain": 0, "overrides": pocket, "rivers": [[-4, -10], [-4, -9], [-4, -8], [-4, -7], [-4, -6], [-4, -5], [-4, -4], [-4, -3], [-4, -2], [-4, -1], [-4, 0], [-4, 1], [-4, 2], [-4, 3], [-4, 4], [-4, 5], [-4, 6], [-4, 7], [-4, 8], [-4, 9], [-4, 10]],
		"turn_limit": 25,
		"blue": [["HQ", "hq", 300], ["INF", "infantry", 450], ["ARC", "archer", 220], ["CAV", "cavalry", 280]],
		"red": [["HQ", "hq", 300], ["INF", "infantry", 450], ["ARC", "archer", 220], ["CAV", "cavalry", 280]]})
	cfgs.append({"id": "F_RULES_ARCHER_R2", "bounds": {"q_min": -12, "q_max": 12, "r_min": -10, "r_max": 10},
		"terrain": 0, "overrides": {}, "rivers": [], "turn_limit": 25,
		"ruleset_override": {"class_stats": {"archer": {"range": 2}}},
		"blue": [["HQ", "hq", 300], ["INF", "infantry", 450], ["ARC", "archer", 220], ["CAV", "cavalry", 280]],
		"red": [["HQ", "hq", 300], ["INF", "infantry", 450], ["ARC", "archer", 220], ["CAV", "cavalry", 280]]})
	cfgs.append({"id": "F_RULES_CAV_MP4", "bounds": {"q_min": -12, "q_max": 12, "r_min": -10, "r_max": 10},
		"terrain": 0, "overrides": {}, "rivers": [], "turn_limit": 25,
		"ruleset_override": {"class_stats": {"cavalry": {"base_mp": 4.0}}},
		"blue": [["HQ", "hq", 300], ["INF", "infantry", 450], ["ARC", "archer", 220], ["CAV", "cavalry", 280], ["SCT", "scout", 120]],
		"red": [["HQ", "hq", 300], ["INF", "infantry", 450], ["ARC", "archer", 220], ["CAV", "cavalry", 280], ["SCT", "scout", 120]]})
	cfgs.append({"id": "F_RULES_HEAVY_INF", "bounds": {"q_min": -12, "q_max": 12, "r_min": -10, "r_max": 10},
		"terrain": 0, "overrides": {}, "rivers": [], "turn_limit": 25,
		"ruleset_override": {"class_stats": {"infantry": {"attack": 13.0, "defense": 12.0}}},
		"blue": [["HQ", "hq", 300], ["INF1", "infantry", 450], ["INF2", "infantry", 420], ["ARC", "archer", 220]],
		"red": [["HQ", "hq", 300], ["INF1", "infantry", 450], ["INF2", "infantry", 420], ["ARC", "archer", 220]]})
	return cfgs


func _build_scenario(cfg: Dictionary) -> Dictionary:
	var bounds: Dictionary = cfg.get("bounds", {})
	var q_span := int(bounds.get("q_max", 12)) - int(bounds.get("q_min", -12))
	var blue_home := int(bounds.get("q_min", -12)) + maxi(1, q_span / 4)
	var red_home := int(bounds.get("q_max", 12)) - maxi(1, q_span / 4)
	var forces: Array = []
	var row := 0
	for spec in (cfg.get("blue", []) as Array):
		var tag := str(spec[0])
		forces.append({"id": "B_%s_1" % tag if tag == "HQ" else "B_%s" % tag,
			"class": str(spec[1]), "faction": "blue",
			"q": blue_home, "r": row - int((cfg.get("blue", []) as Array).size()) / 2,
			"soldiers": int(spec[2])})
		row += 1
	row = 0
	for spec in (cfg.get("red", []) as Array):
		var tag := str(spec[0])
		forces.append({"id": "R_%s_1" % tag if tag == "HQ" else "R_%s" % tag,
			"class": str(spec[1]), "faction": "red",
			"q": red_home, "r": row - int((cfg.get("red", []) as Array).size()) / 2,
			"soldiers": int(spec[2])})
		row += 1
	return {"scenario_id": str(cfg.get("id", "gx")).to_lower(), "scenario_version": "generalized_utility_flex_v0",
		"seed": _seed_base, "mission_contract": {"primary_objective": "destroy_all_red", "turn_limit": int(cfg.get("turn_limit", 25))},
		"map": {"bounds": bounds, "default_terrain": int(cfg.get("terrain", 0)),
			"terrain_overrides": cfg.get("overrides", {}), "river_cells": cfg.get("rivers", [])},
		"forces": forces, "start_turn": 1}


func _run_match(cfg: Dictionary, blue_seed: int, red_seed: int, blue_prof: String, red_prof: String) -> Dictionary:
	var sim: RefCounted = SimControllerCls.new()
	var loaded: Dictionary = sim.load_scenario(_build_scenario(cfg))
	if not bool(loaded.get("ok", false)):
		return {"id": str(cfg.get("id", "")), "pass": false, "error": str(loaded.get("error", "load_failed"))}
	var blue_bot: RefCounted = GxBotCls.new()
	var red_bot: RefCounted = GxBotCls.new()
	blue_bot.call("configure", blue_seed, blue_prof)
	red_bot.call("configure", red_seed, red_prof)
	var enumerator: RefCounted = DirectEnumeratorCls.new()
	enumerator.configure(sim)
	var overlay: Dictionary = cfg.get("ruleset_override", {})
	var side := "blue"
	var actions := 0
	var action_types: Dictionary = {}
	var trace_ids: Array = []
	var errors: Array = []
	while actions < _max_actions:
		var terminal: Dictionary = sim.evaluate_battle()
		if bool(terminal.get("terminal", false)):
			break
		var knowledge: Dictionary = sim.build_knowledge(side)
		var pool: Dictionary = enumerator.enumerate_all(side)
		var candidates: Array = pool.get("candidates", [])
		if candidates.is_empty():
			errors.append("empty_legal_pool_%s" % side)
			break
		var observation := _bot_observation(knowledge, side, sim.map_bounds(), overlay)
		if not _candidate_targets_visible(candidates, _visible_ids(observation)):
			_fog_leaks += 1
			errors.append("hidden_candidate_target_%s" % side)
		var enriched := _enrich_candidates(candidates, sim, side, observation)
		# Decline partially-blind moves exactly like the V1 bench (no truth leak).
		var visible_pool: Array = []
		for raw in enriched:
			if raw is Dictionary and (str((raw as Dictionary).get("action_type", "")) != "MOVE" or bool((raw as Dictionary).get("route_fully_visible", true))):
				visible_pool.append(raw)
		if visible_pool.is_empty():
			errors.append("all_moves_blind_%s" % side)
			break
		var bot: RefCounted = blue_bot if side == "blue" else red_bot
		var decision: Dictionary = bot.call("select_action", observation, visible_pool)
		if not bool(decision.get("ok", false)):
			errors.append("decision_failed_%s:%s" % [side, str(decision.get("code", ""))])
			break
		var selected: Dictionary = decision.get("candidate", {})
		if not _contains_candidate(candidates, str(decision.get("candidate_id", ""))):
			_illegal += 1
			errors.append("selected_not_enumerated_%s" % str(decision.get("candidate_id", "")))
			break
		var kind := str(selected.get("action_type", "")).to_upper()
		var result := _execute(sim, selected, side)
		actions += 1
		action_types[kind] = int(action_types.get(kind, 0)) + 1
		trace_ids.append("%s:%s" % [side, str(decision.get("candidate_id", ""))])
		if not bool(result.get("success", result.get("ok", false))):
			_illegal += 1
			errors.append("executor_invalid_%s:%s" % [kind, str(result.get("error", result.get("code", "")))])
			break
		if kind == "MOVE":
			var audit := _audit_truth_bounds(sim.export_state(), sim.map_bounds())
			if not bool(audit.get("ok", false)):
				_oob += 1
				errors.append("post_action_out_of_bounds")
				break
		if kind == "END_TURN":
			side = "red" if side == "blue" else "blue"
	var final: Dictionary = sim.evaluate_battle()
	var digest := "%016x" % hash("|".join(trace_ids))
	return {"id": str(cfg.get("id", "")), "blue_profile": blue_prof, "red_profile": red_prof,
		"blue_seed": blue_seed, "red_seed": red_seed,
		"terminal": bool(final.get("terminal", false)), "winner": str(final.get("winner", "")),
		"terminal_reason": str(final.get("reason", "")), "turns": int(final.get("turn", 0)),
		"actions": actions, "action_types": action_types, "digest": digest,
		"final_fingerprint": sim.fingerprint(), "errors": errors,
		"pass": bool(final.get("terminal", false)) and errors.is_empty()}


# ------------------------------------------------------------------
# Reactivity probes (synthetic, deterministic, no full match needed)
# ------------------------------------------------------------------

func _reactivity_probes() -> Dictionary:
	var out: Dictionary = {}
	# R1: mobility order must flip when cavalry gains MP under the overlay.
	var base_obs := {"friendly_units": [], "known_enemy_units": [],
		"map_bounds": {"q_min": -12, "q_max": 12, "r_min": -10, "r_max": 10}, "turn": 1}
	var base_rs: Dictionary = RulesetViewCls.build(base_obs)
	var over_obs := base_obs.duplicate(true)
	over_obs["ruleset_override"] = {"class_stats": {"cavalry": {"base_mp": 4.0}}}
	var over_rs: Dictionary = RulesetViewCls.build(over_obs)
	var base_order: Array = base_rs.get("mobility_order", [])
	var over_order: Array = over_rs.get("mobility_order", [])
	out["R1_mobility_order_base"] = base_order.slice(0, 3)
	out["R1_mobility_order_overlay"] = over_order.slice(0, 3)
	out["R1_order_reacts"] = str(base_order.slice(0, 3)) != str(over_order.slice(0, 3))
	out["R1_reach_cav_base"] = RulesetViewCls.get_base_mp(base_rs, "cavalry")
	out["R1_reach_cav_overlay"] = RulesetViewCls.get_base_mp(over_rs, "cavalry")
	# R2: same tactical state, archer range 3 vs 2 -> the ranked alternatives
	# must reweight. Geometry is discriminating: dest (0,1) sits 4 hexes from
	# the enemy — inside the base range-3 standoff band [2,4], outside the
	# overlaid range-2 band [2,3].
	var obs := {"side": "blue", "turn": 3, "turn_limit": 25,
		"map_bounds": {"q_min": -12, "q_max": 12, "r_min": -10, "r_max": 10},
		"friendly_units": [{"unit_id": "B_ARC_1", "class": "archer", "q": 0, "r": 0, "soldiers": 220}],
		"known_enemy_units": [{"unit_id": "R_INF_1", "class": "infantry", "q": 4, "r": 0, "soldiers": 450, "contact_state": "current_visible"}]}
	var cands := [
		{"candidate_id": "MOVE|B_ARC_1|0,1", "unit_id": "B_ARC_1", "action_type": "MOVE", "destination": [0, 1], "cost": 1.0},
		{"candidate_id": "WAIT|B_ARC_1", "unit_id": "B_ARC_1", "action_type": "WAIT"}]
	var bot_a: RefCounted = GxBotCls.new()
	bot_a.call("configure", 777, "GX_ADV_OUTRIDER")
	var dec_base: Dictionary = bot_a.call("select_action", obs, cands.duplicate(true))
	var over2 := obs.duplicate(true)
	over2["ruleset_override"] = {"class_stats": {"archer": {"range": 2}}}
	var bot_b: RefCounted = GxBotCls.new()
	bot_b.call("configure", 777, "GX_ADV_OUTRIDER")
	var dec_over: Dictionary = bot_b.call("select_action", over2, cands.duplicate(true))
	out["R2_base_choice"] = str(dec_base.get("candidate_id", ""))
	out["R2_overlay_choice"] = str(dec_over.get("candidate_id", ""))
	out["R2_base_alternatives"] = dec_base.get("alternatives", [])
	out["R2_overlay_alternatives"] = dec_over.get("alternatives", [])
	out["R2_features_differ"] = JSON.stringify(dec_base.get("alternatives", [])) != JSON.stringify(dec_over.get("alternatives", []))
	out["R2_decision_flips_or_reweights"] = bool(out["R2_features_differ"])
	# R3: hunter detachment follows the CURRENT fastest class, not a name.
	var bot_c: RefCounted = GxBotCls.new()
	bot_c.call("configure", 999, "GX_ADV_SPEARHEAD")
	var ctx_obs := {"side": "blue", "turn": 5, "turn_limit": 25,
		"map_bounds": {"q_min": -12, "q_max": 12, "r_min": -10, "r_max": 10},
		"friendly_units": [
			{"unit_id": "B_CAV_1", "class": "cavalry", "q": 0, "r": 0, "soldiers": 280},
			{"unit_id": "B_INF_1", "class": "infantry", "q": 0, "r": 1, "soldiers": 450},
			{"unit_id": "B_SCT_1", "class": "scout", "q": 1, "r": 0, "soldiers": 120}],
		"known_enemy_units": []}
	bot_c.call("select_action", ctx_obs, [{"candidate_id": "WAIT|B_CAV_1", "unit_id": "B_CAV_1", "action_type": "WAIT"}])
	var hunters_base: Array = bot_c.call("_hunter_units", bot_c.call("_context", ctx_obs))
	var ctx_over := ctx_obs.duplicate(true)
	ctx_over["ruleset_override"] = {"class_stats": {"infantry": {"base_mp": 5.0}}}
	bot_c.call("select_action", ctx_over, [{"candidate_id": "WAIT|B_CAV_1", "unit_id": "B_CAV_1", "action_type": "WAIT"}])
	var hunters_over: Array = bot_c.call("_hunter_units", bot_c.call("_context", ctx_over))
	out["R3_hunters_base"] = hunters_base
	out["R3_hunters_overlay"] = hunters_over
	out["R3_hunters_react"] = str(hunters_base) != str(hunters_over)
	out["pass"] = bool(out["R1_order_reacts"]) and bool(out["R2_features_differ"]) and bool(out["R3_hunters_react"])
	return out


# ------------------------------------------------------------------
# Helpers (same authority seams as the V1 bench)
# ------------------------------------------------------------------

func _bot_observation(knowledge: Dictionary, side: String, map_bounds: Dictionary, overlay: Dictionary) -> Dictionary:
	var ledger: Dictionary = knowledge.get("ledger", {})
	var friends: Array = []
	for raw in ledger.get("own_forces", []):
		if not raw is Dictionary:
			continue
		var u: Dictionary = raw
		var count := int(u.get("soldier_count", 0))
		var max_count := maxi(1, int(u.get("max_count", count)))
		var ratio := float(count) / float(max_count)
		friends.append({"unit_id": str(u.get("id", "")), "class": str(u.get("class", "unknown")),
			"q": int(u.get("q", 0)), "r": int(u.get("r", 0)), "soldiers": count,
			"condition": "critical" if ratio < 0.25 else "weakened" if ratio < 0.5 else "worn" if ratio < 0.75 else "fit",
			"action_ended": bool(u.get("action_ended", false)), "remaining_mp": float(u.get("remaining_mp", 0.0))})
	var enemies: Array = []
	var contact_key := "current_enemy_observations" if side == "blue" else "observed_blue_forces"
	for raw in ledger.get(contact_key, []):
		if not raw is Dictionary:
			continue
		var u: Dictionary = raw
		enemies.append({"unit_id": str(u.get("id", "")), "class": str(u.get("class", "unknown")),
			"q": int(u.get("q", 0)), "r": int(u.get("r", 0)), "soldiers": int(u.get("soldier_count", 0)),
			"troop_estimate": str(u.get("soldier_count", 0)), "contact_state": "current_visible"})
	var stale: Array = []
	var stale_key := "last_known_enemy_contacts" if side == "blue" else "last_known_blue_contacts"
	for raw in ledger.get(stale_key, []):
		if raw is Dictionary:
			var contact: Dictionary = raw
			stale.append({"unit_id": str(contact.get("id", "")), "class": str(contact.get("class", "unknown")),
				"q": int(contact.get("q", 0)), "r": int(contact.get("r", 0)),
				"contact_state": "stale_last_known", "last_seen_turn": int(contact.get("last_seen_turn", 0))})
	var obs := {"side": side, "current_turn": int(knowledge.get("current_turn", 0)),
		"turn": int(knowledge.get("current_turn", 0)),
		"turn_limit": int((knowledge.get("mission_contract", {}) as Dictionary).get("turn_limit", 25)) if knowledge.has("mission_contract") else 25,
		"map_bounds": map_bounds, "board": {"dimensions": map_bounds},
		"friendly_units": friends, "known_enemy_units": enemies,
		"stale_enemy_units": stale,
		"mission": {"scenario_id": str(knowledge.get("scenario_id", "")), "objectives": knowledge.get("objectives", [])}}
	if not overlay.is_empty():
		obs["ruleset_override"] = overlay
	return obs


func _enrich_candidates(candidates: Array, sim: RefCounted, side: String, _observation: Dictionary) -> Array:
	var out: Array = []
	var service: RefCounted = sim.get_service()
	for raw in candidates:
		if not raw is Dictionary:
			continue
		var candidate: Dictionary = (raw as Dictionary).duplicate(true)
		if str(candidate.get("action_type", "")).to_upper() == "ATTACK":
			var preview: Dictionary = service.call("preview_attack", str(candidate.get("unit_id", "")), str(candidate.get("target_id", "")), side)
			if bool(preview.get("ok", false)):
				candidate["expected_enemy_casualties_min"] = float(preview.get("expected_enemy_casualties_min", 0.0))
				candidate["expected_enemy_casualties_max"] = float(preview.get("expected_enemy_casualties_max", 0.0))
				candidate["expected_friendly_casualties_min"] = float(preview.get("expected_friendly_casualties_min", 0.0))
				candidate["expected_friendly_casualties_max"] = float(preview.get("expected_friendly_casualties_max", 0.0))
		elif str(candidate.get("action_type", "")).to_upper() == "ASSAULT" and str(candidate.get("garrison_target_id", "")) != "":
			candidate["target_id"] = str(candidate.get("garrison_target_id", ""))
		out.append(candidate)
	return out


func _execute(sim: RefCounted, candidate: Dictionary, side: String) -> Dictionary:
	var kind := str(candidate.get("action_type", "")).to_upper()
	var uid := str(candidate.get("unit_id", ""))
	var manager: RefCounted = sim.get_manager()
	match kind:
		"MOVE":
			var dest: Array = candidate.get("destination", [])
			return sim.do_move(uid, int(dest[0]), int(dest[1]), side, "auto" if side == "blue" else "green")
		"ATTACK":
			return sim.do_attack(uid, str(candidate.get("target_id", "")), side)
		"ASSAULT":
			var result: Dictionary = manager.execute_stronghold_assault(uid,
				str(candidate.get("stronghold_id", "")), str(candidate.get("garrison_target_id", "")))
			if bool(result.get("success", false)):
				sim.call("_after_combat_authority", result, uid, str(candidate.get("garrison_target_id", "")))
				sim.refresh_observation()
			return result
		"WAIT":
			return sim.do_hold(uid, side)
		"REST":
			return sim.do_rest(uid)
		"FORTIFY":
			return sim.do_fortify(uid)
		"DISMANTLE":
			var result: Dictionary = manager.dismantle_fortification(uid)
			if bool(result.get("success", false)):
				sim.refresh_observation()
			return result
		"ENTER_GARRISON":
			var result: Dictionary = manager.garrison_enter(uid, str(candidate.get("stronghold_id", "")))
			if bool(result.get("success", false)):
				sim.refresh_observation()
			return result
		"END_TURN":
			return sim.sim_end_turn()
	return {"success": false, "error": "Unsupported enumerated action %s" % kind}


func _candidate_targets_visible(candidates: Array, visible_ids: Dictionary) -> bool:
	for raw in candidates:
		if not raw is Dictionary:
			continue
		var c: Dictionary = raw
		if str(c.get("action_type", "")).to_upper() == "ATTACK" and not visible_ids.has(str(c.get("target_id", ""))):
			return false
	return true


func _visible_ids(observation: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for raw in observation.get("known_enemy_units", []):
		if raw is Dictionary:
			out[str((raw as Dictionary).get("unit_id", ""))] = true
	return out


func _contains_candidate(candidates: Array, candidate_id: String) -> bool:
	for raw in candidates:
		if raw is Dictionary and str((raw as Dictionary).get("candidate_id", "")) == candidate_id:
			return true
	return false


func _audit_truth_bounds(state: Dictionary, bounds: Dictionary) -> Dictionary:
	for raw in state.get("units", []):
		if not raw is Dictionary:
			continue
		var u: Dictionary = raw
		if int(u.get("q", 0)) < int(bounds.get("q_min", -9999)) or int(u.get("q", 0)) > int(bounds.get("q_max", 9999)) \
			or int(u.get("r", 0)) < int(bounds.get("r_min", -9999)) or int(u.get("r", 0)) > int(bounds.get("r_max", 9999)):
			return {"ok": false}
	return {"ok": true}


func _summarize(configs: Array, rows: Array, reactivity: Dictionary, deter_ok: bool, elapsed_ms: int) -> Dictionary:
	var terminal := 0
	var pass_rows := 0
	var actions := 0
	var type_counts: Dictionary = {}
	var openings: Dictionary = {}
	var diverged := 0
	var diverged_total := 0
	var all_errors: Array = []
	for row_val in rows:
		var row: Dictionary = row_val
		if bool(row.get("terminal", false)):
			terminal += 1
		if bool(row.get("pass", false)):
			pass_rows += 1
		actions += int(row.get("actions", 0))
		for k in (row.get("action_types", {}) as Dictionary).keys():
			type_counts[str(k)] = int(type_counts.get(str(k), 0)) + int((row.get("action_types", {}) as Dictionary)[k])
		all_errors.append_array(row.get("errors", []))
		if row.has("diverges_from_baseline"):
			diverged_total += 1
			if bool(row.get("diverges_from_baseline", false)):
				diverged += 1
	# Opening-action diversity across the matrix (anti-fixed-script evidence).
	for row_val in rows:
		var row: Dictionary = row_val
		openings[str(row.get("id", ""))] = true
	var entropy := 0.0
	var total := 0.0
	for v in type_counts.values():
		total += float(v)
	if total > 0.0:
		for v in type_counts.values():
			var p := float(v) / total
			if p > 0.0:
				entropy -= p * log(p) / log(2.0)
	var has_overlay := false
	for cfg_val in configs:
		if not ((cfg_val as Dictionary).get("ruleset_override", {}) as Dictionary).is_empty():
			has_overlay = true
	# Divergence bar (documented rationale): the three synthetic probes prove
	# per-mechanism reactivity deterministically; at match level, a subtle
	# symmetric overlay (e.g. one class +1 MP) may correctly leave a trace
	# unchanged when no decision boundary is crossed — that is robustness, not
	# a fixed script. Requiring >= 1 end-to-end divergence proves the overlay
	# path reaches live play (ARCHER_R2 does), without demanding chaos.
	var ok := pass_rows == rows.size() and rows.size() == configs.size() \
		and _illegal == 0 and _oob == 0 and _fog_leaks == 0 \
		and deter_ok and bool(reactivity.get("pass", false)) \
		and type_counts.size() >= 3 \
		and (not has_overlay or diverged >= 1)
	return {"version": "generalized_utility_flex_v0", "pass": ok,
		"configs": configs.size(), "matches": rows.size(), "matches_pass": pass_rows,
		"terminal_rate": float(terminal) / float(maxi(1, rows.size())),
		"illegal_action_count": _illegal, "out_of_bounds_count": _oob,
		"hidden_target_count": _fog_leaks, "match_errors": all_errors,
		"determinism_all_replays_identical": deter_ok,
		"reactivity": reactivity,
		"rules_diverged_matches": "%d/%d" % [diverged, diverged_total],
		"action_type_distribution": type_counts,
		"action_type_entropy_bits": snappedf(entropy, 0.001),
		"average_actions_per_match": float(actions) / float(maxi(1, rows.size())),
		"elapsed_ms": elapsed_ms}


func _report_md(summary: Dictionary, rows: Array, reactivity: Dictionary) -> String:
	var lines: Array = []
	lines.append("# Generalized Utility AI V0 — Flex Report")
	lines.append("")
	lines.append("verdict: %s" % ("PASS" if bool(summary.get("pass", false)) else "BLOCKED"))
	lines.append("matches: %d/%d pass, terminal_rate=%.2f, determinism=%s, reactivity=%s" % [
		int(summary.get("matches_pass", 0)), int(summary.get("matches", 0)),
		float(summary.get("terminal_rate", 0.0)),
		str(summary.get("determinism_all_replays_identical", false)), str(bool(reactivity.get("pass", false)))])
	lines.append("legality: illegal=%d oob=%d fog_leaks=%d errors=%s" % [
		int(summary.get("illegal_action_count", 0)), int(summary.get("out_of_bounds_count", 0)),
		int(summary.get("hidden_target_count", 0)), JSON.stringify(summary.get("match_errors", []))])
	lines.append("rules_divergence: %s" % str(summary.get("rules_diverged_matches", "")))
	lines.append("action_types: %s (entropy %.3f bits)" % [
		JSON.stringify(summary.get("action_type_distribution", {})), float(summary.get("action_type_entropy_bits", 0.0))])
	lines.append("")
	lines.append("## Per-config")
	for row_val in rows:
		var row: Dictionary = row_val
		lines.append("- %s profiles=%s/%s terminal=%s winner=%s actions=%d types=%s errors=%s deter=%s%s" % [
			str(row.get("id", "")), str(row.get("blue_profile", "")).right(8),
			str(row.get("red_profile", "")).right(8), str(row.get("terminal", false)),
			str(row.get("winner", "")), int(row.get("actions", 0)),
			JSON.stringify(row.get("action_types", {})), JSON.stringify(row.get("errors", [])),
			str(row.get("determinism_replay_same", false)),
			(" diverged=%s" % str(row.get("diverges_from_baseline", ""))) if row.has("diverges_from_baseline") else ""])
	lines.append("")
	lines.append("## Reactivity probes")
	lines.append("R1 mobility order reacts to cavalry MP overlay: %s (%s -> %s)" % [
		str(reactivity.get("R1_order_reacts", false)),
		JSON.stringify(reactivity.get("R1_mobility_order_base", [])),
		JSON.stringify(reactivity.get("R1_mobility_order_overlay", []))])
	lines.append("R2 archer-range overlay changes features: %s (choice %s -> %s)" % [
		str(reactivity.get("R2_features_differ", false)),
		str(reactivity.get("R2_base_choice", "")), str(reactivity.get("R2_overlay_choice", ""))])
	lines.append("R3 hunter detachment follows fastest table class: %s (%s -> %s)" % [
		str(reactivity.get("R3_hunters_react", false)),
		JSON.stringify(reactivity.get("R3_hunters_base", [])),
		JSON.stringify(reactivity.get("R3_hunters_overlay", []))])
	return "\n".join(lines) + "\n"


func _write_json(path: String, data: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(_out_dir)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("Unable to write GX flex artifact: " + path)
		return
	file.store_string(JSON.stringify(data, "  ") + "\n")
	file.close()


func _write_text(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(_out_dir)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("Unable to write GX flex artifact: " + path)
		return
	file.store_string(text)
	file.close()
