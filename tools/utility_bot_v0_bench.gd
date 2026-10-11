extends SceneTree

## Bounded UtilityBot-vs-UtilityBot verification and population smoke.
##
## Usage:
##   Godot_v4.2.2-stable_win64_console.exe --headless --path "D:\Game development\Demon slayer\StrategyGame" -s res://tools/utility_bot_v0_bench.gd -- --matches=30 --out-dir="D:\Game development\Demon slayer\StrategyGame\artifacts\utility_bot_v0"
##   Add --matches=1 --max-actions=100 for a tiny smoke run.

const SimControllerCls = preload("res://scripts/sim/sim_controller.gd")
const DirectEnumeratorCls = preload("res://scripts/sim/direct_legal_enumerator.gd")
const UtilityBotCls = preload("res://scripts/utility_bot/utility_bot.gd")
const ScenariosCls = preload("res://scripts/cloud2/cloud2_debug_scenarios.gd")

const ARCHETYPES := ["AGGRESSIVE", "DEFENSIVE", "MANEUVER", "ATTRITION", "OPPORTUNIST", "COUNTERPUNCH"]
const SCENARIOS := ["DEV_COMPACT_CENTER", "DEV_COMPACT_NORTH", "DEV_COMPACT_SOUTH"]
const DEFAULT_OUT := "D:/Game development/Demon slayer/StrategyGame/artifacts/utility_bot_v0"

var _matches := 30
var _max_actions := 240
var _seed_base := 100
var _start_index := 0
var _out_dir := DEFAULT_OUT
var _results: Array = []
var _traces: Array = []
var _all_action_types: Dictionary = {}
var _all_archetypes: Dictionary = {}
var _invalid_count := 0
var _oob_count := 0
var _legal_selection_failures := 0
var _fog_leak_failures := 0
var _rationality_failures := 0


func _init() -> void:
	_parse_args()
	print("[UTILITY_BENCH] config matches=%d max_actions=%d seed_base=%d out_dir=%s" % [_matches, _max_actions, _seed_base, _out_dir])
	var started := Time.get_ticks_msec()
	var fixtures := _run_contract_fixtures()
	var population := _run_population_probe()
	var determinism := _run_determinism_probe()
	for offset in range(_matches):
		var i := _start_index + offset
		var row := _run_match(i)
		_results.append(row)
		if offset < 3:
			_traces.append({"match_id": row.get("match_id", i), "trace": row.get("trace", [])})
			print("[UTILITY_BENCH] match %d/%d winner=%s actions=%d reason=%s" % [offset + 1, _matches,
				str(row.get("winner", "")), int(row.get("actions", 0)), str(row.get("terminal_reason", ""))])
	var summary := _summarize(fixtures, population, determinism, Time.get_ticks_msec() - started)
	_write_json(_out_dir.path_join("raw_matches.json"), {"matches": _results})
	_write_json(_out_dir.path_join("sample_decision_traces.json"), {"samples": _traces})
	_write_json(_out_dir.path_join("BENCHMARK.json"), summary)
	print(JSON.stringify(summary, "  "))
	quit(0 if bool(summary.get("pass", false)) else 1)


func _parse_args() -> void:
	var args := OS.get_cmdline_user_args()
	args.append_array(OS.get_cmdline_args())
	for raw in args:
		var arg := str(raw).strip_edges().trim_prefix("--")
		if arg.begins_with("matches="):
			_matches = clampi(int(arg.get_slice("=", 1)), 1, 50)
		elif arg.begins_with("max-actions="):
			_max_actions = clampi(int(arg.get_slice("=", 1)), 20, 10000)
		elif arg.begins_with("seed-base="):
			_seed_base = clampi(int(arg.get_slice("=", 1)), 0, 4000)
		elif arg.begins_with("start-index="):
			_start_index = clampi(int(arg.get_slice("=", 1)), 0, 9999)
		elif arg.begins_with("out-dir="):
			_out_dir = arg.get_slice("=", 1).trim_prefix("\"").trim_suffix("\"")


func _run_contract_fixtures() -> Dictionary:
	var red_hq_case := _load_scenario("HQ_SAFE", 5, false)
	var blue_hq_case := _load_scenario("HQ_SAFE", 5, false)
	if red_hq_case == null or blue_hq_case == null:
		return {"pass": false, "error": "fixture scenario failed to load"}
	red_hq_case.get_manager().destroy_unit("R_HQ_1")
	blue_hq_case.get_manager().destroy_unit("B_HQ_1")
	var red_dead: Dictionary = red_hq_case.evaluate_battle()
	var blue_dead: Dictionary = blue_hq_case.evaluate_battle()
	var hq_ok := str(red_dead.get("winner", "")) == "blue" and str(red_dead.get("reason", "")) == "red_hq_destroyed" \
		and str(blue_dead.get("winner", "")) == "red" and str(blue_dead.get("reason", "")) in ["hq_destroyed", "blue_hq_destroyed"]
	var fog := _load_scenario("HQ_SAFE", 6, false)
	if fog == null:
		return {"pass": false, "error": "fog fixture failed to load"}
	var blue_pool := DirectEnumeratorCls.new()
	var red_pool := DirectEnumeratorCls.new()
	blue_pool.configure(fog)
	red_pool.configure(fog)
	var blue_candidates: Array = blue_pool.enumerate_all("blue").get("candidates", [])
	var red_candidates: Array = red_pool.enumerate_all("red").get("candidates", [])
	var blue_obs := _bot_observation(fog.build_knowledge("blue"), "blue", fog.map_bounds())
	var red_obs := _bot_observation(fog.build_knowledge("red"), "red", fog.map_bounds())
	var blue_visible := _visible_ids(blue_obs)
	var red_visible := _visible_ids(red_obs)
	var no_leaks := _candidate_targets_visible(blue_candidates, blue_visible) and _candidate_targets_visible(red_candidates, red_visible)
	var hidden_id_absent := _flatten(blue_obs).find("R_INF_1") == -1 and _flatten(red_obs).find("B_INF_1") == -1
	var symmetric_a: RefCounted = _load_scenario("SYMMETRY_PROBE", 77, false)
	var symmetric_b: RefCounted = _load_scenario("SYMMETRY_PROBE", 77, true)
	var side_symmetry_ok := false
	var side_symmetry_evidence := {}
	if symmetric_a != null and symmetric_b != null:
		# Match the two authorized movement envelopes for this structural test.
		# The normal BLUE UI can select extended march; production RED uses its
		# GREEN_ONLY route. This fixture compares faction projection/legality
		# while holding that user-selectable movement policy constant.
		symmetric_a.get_manager().set_policy(0)
		symmetric_b.get_manager().set_policy(0)
		var ea: RefCounted = DirectEnumeratorCls.new()
		var eb: RefCounted = DirectEnumeratorCls.new()
		ea.configure(symmetric_a)
		eb.configure(symmetric_b)
		var a_blue := _candidate_type_counts(ea.enumerate_all("blue").get("candidates", []))
		var a_red := _candidate_type_counts(ea.enumerate_all("red").get("candidates", []))
		var b_blue := _candidate_type_counts(eb.enumerate_all("blue").get("candidates", []))
		var b_red := _candidate_type_counts(eb.enumerate_all("red").get("candidates", []))
		# Rest/fortify are intentionally BLUE-authorized by current manager
		# rules. Compare the side-neutral combat/phase capabilities and retain
		# full counts as evidence of known rule asymmetry.
		side_symmetry_ok = _has_symmetric_base_pool(a_blue, b_red) and _has_symmetric_base_pool(a_red, b_blue)
		side_symmetry_evidence = {"original_blue": a_blue, "original_red": a_red,
			"swapped_blue": b_blue, "swapped_red": b_red}
	return {"pass": hq_ok and no_leaks and hidden_id_absent and side_symmetry_ok,
		"hq_terminal_symmetry": hq_ok, "red_hq_result": red_dead,
		"blue_hq_result": blue_dead, "candidate_target_visibility": no_leaks,
		"hidden_contact_absent_from_authorized_observations": hidden_id_absent,
		"red_blue_enumerator_symmetry": side_symmetry_ok,
		"side_symmetry_candidate_type_counts": side_symmetry_evidence}


func _has_symmetric_base_pool(a: Dictionary, b: Dictionary) -> bool:
	for key in ["ATTACK", "MOVE", "WAIT", "END_TURN"]:
		if int(a.get(key, 0)) <= 0 or int(b.get(key, 0)) <= 0:
			return false
	if int(a.get("ATTACK", 0)) != int(b.get("ATTACK", 0)):
		return false
	return true


func _candidate_type_counts(candidates: Array) -> Dictionary:
	var out: Dictionary = {}
	for raw in candidates:
		if raw is Dictionary:
			var kind := str((raw as Dictionary).get("action_type", ""))
			out[kind] = int(out.get(kind, 0)) + 1
	return out


func _run_population_probe() -> Dictionary:
	var profile_signatures: Dictionary = {}
	var choices: Dictionary = {}
	var synthetic := [
		{"candidate_id": "MOVE|M|1,0", "unit_id": "M", "action_type": "MOVE", "destination": [1, 0], "utility_features": {"position": 0.18, "objective": 0.18, "pressure": 0.18, "cohesion": 0.18}},
		{"candidate_id": "ATTACK|M|E", "unit_id": "M", "action_type": "ATTACK", "target_id": "E", "expected_enemy_casualties_max": 45.0, "expected_friendly_casualties_max": 3.0},
		{"candidate_id": "REST|M", "unit_id": "M", "action_type": "REST", "utility_features": {"preservation": 0.3}}
	]
	var rational := true
	var own_hq_preview_safe := true
	for i in range(48):
		var bot: RefCounted = UtilityBotCls.new()
		bot.call("configure", _seed_base + 1000 + i)
		var profile: Dictionary = bot.call("profile")
		var signature := JSON.stringify(profile)
		profile_signatures[signature] = true
		var obs := {"side": "blue", "friendly_units": [{"unit_id": "M", "class": "infantry", "q": 0, "r": 0, "soldiers": 450}],
			"known_enemy_units": [{"unit_id": "E", "class": "infantry", "q": 1, "r": 0, "soldiers": 200, "contact_state": "current_visible"},
			{"unit_id": "HQ", "class": "hq", "q": 2, "r": 0, "soldiers": 1, "contact_state": "current_visible"}]}
		var terminal_candidates := [
			{"candidate_id": "SAFE_MOVE", "unit_id": "M", "action_type": "MOVE", "destination": [1, 0]},
			{"candidate_id": "OWN_HQ_LOSS", "unit_id": "M", "action_type": "MOVE", "destination": [0, 0], "utility_features": {"own_hq_loss": 1.0}},
			{"candidate_id": "ENEMY_HQ_KILL", "unit_id": "M", "action_type": "ATTACK", "target_id": "HQ", "utility_features": {"enemy_hq_kill": 1.0}}
		]
		var terminal_decision: Dictionary = bot.call("select_action", obs, terminal_candidates)
		if not bool(terminal_decision.get("ok", false)) or str(terminal_decision.get("candidate_id", "")) != "ENEMY_HQ_KILL":
			rational = false
		var decision: Dictionary = bot.call("select_action", obs, synthetic)
		if not bool(decision.get("ok", false)):
			rational = false
		choices[str(decision.get("candidate_id", "ERROR"))] = int(choices.get(str(decision.get("candidate_id", "ERROR")), 0)) + 1
		var hq_obs := {"side": "blue", "friendly_units": [
			{"unit_id": "OWN_HQ", "class": "hq", "q": 0, "r": 0, "soldiers": 100}],
			"known_enemy_units": [{"unit_id": "E", "class": "infantry", "q": 1, "r": 0,
				"soldiers": 400, "contact_state": "current_visible"}]}
		var hq_choice: Dictionary = bot.call("select_action", hq_obs, [
			{"candidate_id": "HQ_ATTACK_CERTAIN_LOSS", "unit_id": "OWN_HQ", "action_type": "ATTACK",
				"target_id": "E", "expected_enemy_casualties_max": 200,
				"expected_friendly_casualties_min": 100, "expected_friendly_casualties_max": 100},
			{"candidate_id": "HQ_WAIT", "unit_id": "OWN_HQ", "action_type": "WAIT"}])
		if str(hq_choice.get("candidate_id", "")) != "HQ_WAIT":
			own_hq_preview_safe = false
	return {"pass": profile_signatures.size() >= 40 and choices.size() >= 2 and rational and own_hq_preview_safe,
		"sampled_profiles": 48, "unique_profiles": profile_signatures.size(),
		"terminal_win_dominates_and_own_hq_loss_is_avoided": rational,
		"certain_own_hq_preview_loss_avoided": own_hq_preview_safe,
		"nonterminal_seeded_choice_diversity": choices.size() >= 2,
		"distinct_selected_actions": choices.size(), "selected_choices": choices}


func _run_determinism_probe() -> Dictionary:
	var bot_a: RefCounted = UtilityBotCls.new()
	var bot_b: RefCounted = UtilityBotCls.new()
	bot_a.call("configure", _seed_base + 4000)
	bot_b.call("configure", _seed_base + 4000)
	var obs := {"side": "blue", "friendly_units": [{"unit_id": "M", "class": "infantry", "q": 0, "r": 0, "soldiers": 400}], "known_enemy_units": []}
	var cands := [{"candidate_id": "WAIT", "unit_id": "M", "action_type": "WAIT"},
		{"candidate_id": "MOVE", "unit_id": "M", "action_type": "MOVE", "destination": [1, 0]}]
	var same := true
	var trace_a: Array = []
	var trace_b: Array = []
	for _i in range(12):
		var a: Dictionary = bot_a.call("select_action", obs, cands)
		var b: Dictionary = bot_b.call("select_action", obs, cands)
		trace_a.append(str(a.get("candidate_id", "")))
		trace_b.append(str(b.get("candidate_id", "")))
		same = same and trace_a.back() == trace_b.back()
	return {"pass": same, "same_seed_same_world_trace": same, "trace": trace_a}


func _run_match(index: int) -> Dictionary:
	var scenario_id: String = SCENARIOS[index % SCENARIOS.size()]
	var scenario_seed := _seed_base + 500 + index
	var swap := index % 2 == 1
	var sim: RefCounted = _load_scenario(scenario_id, scenario_seed, swap)
	if sim == null:
		return {"match_id": index, "pass": false, "error": "load_failed"}
	var blue_seed := _seed_base + index * 2
	var red_seed := _seed_base + index * 2 + 1
	var blue_bot: RefCounted = UtilityBotCls.new()
	var red_bot: RefCounted = UtilityBotCls.new()
	var blue_arch: String = ARCHETYPES[index % ARCHETYPES.size()]
	var red_arch: String = ARCHETYPES[(int(index / 3) + index + 1) % ARCHETYPES.size()]
	blue_bot.call("configure", blue_seed, blue_arch)
	red_bot.call("configure", red_seed, red_arch)
	var profile_blue: Dictionary = blue_bot.call("profile")
	var profile_red: Dictionary = red_bot.call("profile")
	_all_archetypes[blue_arch] = int(_all_archetypes.get(blue_arch, 0)) + 1
	_all_archetypes[red_arch] = int(_all_archetypes.get(red_arch, 0)) + 1
	var enumerator: RefCounted = DirectEnumeratorCls.new()
	enumerator.configure(sim)
	var side := "blue"
	var actions := 0
	var action_types: Dictionary = {}
	var side_actions := {"blue": 0, "red": 0}
	var side_action_types := {"blue": {}, "red": {}}
	var trace: Array = []
	var errors: Array = []
	var initial_turn := int(sim.evaluate_battle().get("turn", 0))
	var max_turn := int((sim.get("_scenario") as Dictionary).get("mission_contract", {}).get("turn_limit", 40))
	while actions < _max_actions:
		var terminal: Dictionary = sim.evaluate_battle()
		if bool(terminal.get("terminal", false)):
			break
		var knowledge: Dictionary = sim.build_knowledge(side)
		var candidates: Array = enumerator.enumerate_all(side).get("candidates", [])
		if candidates.is_empty():
			errors.append("empty_legal_pool_%s" % side)
			break
		var observation := _bot_observation(knowledge, side, sim.map_bounds())
		if not _candidate_targets_visible(candidates, _visible_ids(observation)):
			_fog_leak_failures += 1
			errors.append("hidden_candidate_target_%s" % side)
		var enriched := _enrich_candidates(candidates, sim, side, observation)
		var bot: RefCounted = blue_bot if side == "blue" else red_bot
		var decision: Dictionary = bot.call("select_action", observation, enriched)
		if not bool(decision.get("ok", false)):
			errors.append("decision_failed_%s:%s" % [side, str(decision.get("code", ""))])
			break
		var selected: Dictionary = decision.get("candidate", {})
		var selected_id := str(decision.get("candidate_id", ""))
		if not _contains_candidate(candidates, selected_id):
			_legal_selection_failures += 1
			errors.append("selected_not_enumerated_%s" % selected_id)
		var alternatives: Array = decision.get("alternatives", [])
		var profile: Dictionary = bot.call("profile")
		if not alternatives.is_empty():
			var top_score := float((alternatives[0] as Dictionary).get("score", decision.get("score", 0.0)))
			var chosen_score := float(decision.get("score", 0.0))
			if chosen_score < top_score - maxf(1.61, 3.0 * float(profile.get("temperature", 0.6))):
				_rationality_failures += 1
				errors.append("choice_outside_bounded_top_set")
		var kind := str(selected.get("action_type", "")).to_upper()
		if kind == "MOVE":
			var destination: Array = selected.get("destination", [])
			var bounds: Dictionary = sim.map_bounds()
			if destination.size() < 2 or int(destination[0]) < int(bounds.get("q_min", -9999)) or int(destination[0]) > int(bounds.get("q_max", 9999)) or int(destination[1]) < int(bounds.get("r_min", -9999)) or int(destination[1]) > int(bounds.get("r_max", 9999)):
				_oob_count += 1
				errors.append("out_of_bounds_move")
		var result := _execute(sim, selected, side)
		actions += 1
		side_actions[side] = int(side_actions.get(side, 0)) + 1
		_all_action_types[kind] = int(_all_action_types.get(kind, 0)) + 1
		action_types[kind] = int(action_types.get(kind, 0)) + 1
		var side_hist: Dictionary = side_action_types[side]
		side_hist[kind] = int(side_hist.get(kind, 0)) + 1
		side_action_types[side] = side_hist
		var ok := bool(result.get("success", result.get("ok", false)))
		if not ok:
			_invalid_count += 1
			errors.append("executor_invalid_%s:%s" % [kind, str(result.get("error", result.get("code", "")))])
		elif kind == "MOVE":
			var audit := _audit_truth_bounds(sim.export_state(), sim.map_bounds())
			if not bool(audit.get("ok", false)):
				_oob_count += 1
				errors.append("post_action_out_of_bounds")
		if trace.size() < 160:
			trace.append({"side": side, "turn": int(terminal.get("turn", 0)), "candidate_id": selected_id,
				"action_type": kind, "score": float(decision.get("score", 0.0)),
				"features": decision.get("features", {}), "alternatives": alternatives,
				"profile_seed": profile.get("seed", 0)})
		if kind == "END_TURN":
			side = "red" if side == "blue" else "blue"
		var after: Dictionary = sim.evaluate_battle()
		if int(after.get("turn", 0)) > max_turn + 1:
			errors.append("turn_limit_overshoot")
			break
	var final: Dictionary = sim.evaluate_battle()
	var terminal := bool(final.get("terminal", false))
	return {"match_id": index, "scenario_id": scenario_id, "scenario_seed": scenario_seed,
		"side_swapped": swap, "blue_profile": profile_blue, "red_profile": profile_red,
		"winner": str(final.get("winner", "")), "terminal_reason": str(final.get("reason", "")),
		"terminal": terminal, "turns": int(final.get("turn", 0)) - initial_turn,
		"actions": actions, "actions_by_side": side_actions, "action_types": action_types,
		"action_types_by_side": side_action_types, "trace_digest": _trace_digest(trace), "errors": errors,
		"pass": terminal and side_actions["blue"] > 0 and side_actions["red"] > 0 and errors.is_empty(), "trace": trace}


func _load_scenario(scenario_id: String, seed: int, swap_sides: bool) -> RefCounted:
	var scenario: Dictionary
	if scenario_id == "SYMMETRY_PROBE":
		scenario = _symmetry_scenario(seed)
	elif scenario_id.begins_with("DEV_COMPACT_"):
		scenario = _compact_dev_scenario(scenario_id, seed)
	else:
		var built: Dictionary = ScenariosCls.build(scenario_id)
		if not bool(built.get("ok", false)):
			return null
		scenario = built.get("scenario", {}).duplicate(true)
		scenario["seed"] = seed
	if swap_sides:
		for force_val in scenario.get("forces", []):
			if not force_val is Dictionary:
				continue
			var force: Dictionary = force_val
			if str(force.get("faction", "")) == "blue":
				force["faction"] = "red"
			elif str(force.get("faction", "")) == "red":
				force["faction"] = "blue"
	var sim: RefCounted = SimControllerCls.new()
	var loaded: Dictionary = sim.load_scenario(scenario)
	if not bool(loaded.get("ok", false)):
		push_error("UtilityBot scenario load failed: " + str(loaded))
		return null
	return sim


func _symmetry_scenario(seed: int) -> Dictionary:
	return {"scenario_id": "utility_bot_side_symmetry", "scenario_version": "utility_bot_v0_bench",
		"seed": seed, "mission_contract": {"primary_objective": "destroy_all_red", "turn_limit": 10},
		"map": {"bounds": {"q_min": -18, "q_max": 18, "r_min": -12, "r_max": 12},
			"default_terrain": 0, "terrain_overrides": {}, "river_cells": []},
		"forces": [
			{"id": "B_HQ_1", "class": "hq", "faction": "blue", "q": -15, "r": 0, "soldiers": 300},
			{"id": "B_INF_1", "class": "infantry", "faction": "blue", "q": -1, "r": 0, "soldiers": 450},
			{"id": "R_HQ_1", "class": "hq", "faction": "red", "q": 15, "r": 0, "soldiers": 300},
			{"id": "R_INF_1", "class": "infantry", "faction": "red", "q": 0, "r": 0, "soldiers": 450}
		], "start_turn": 1}


func _compact_dev_scenario(scenario_id: String, seed: int) -> Dictionary:
	var r_offset := 0
	if scenario_id.ends_with("NORTH"):
		r_offset = -2
	elif scenario_id.ends_with("SOUTH"):
		r_offset = 2
	return {
		"scenario_id": scenario_id.to_lower(), "scenario_version": "utility_bot_v0_bench",
		"seed": seed, "mission_contract": {"primary_objective": "destroy_all_red", "turn_limit": 12},
		"map": {"bounds": {"q_min": -18, "q_max": 18, "r_min": -12, "r_max": 12},
			"default_terrain": 0, "terrain_overrides": {}, "river_cells": []},
		"forces": [
			{"id": "B_HQ_1", "class": "hq", "faction": "blue", "q": -11, "r": r_offset, "soldiers": 300},
			{"id": "B_INF_1", "class": "infantry", "faction": "blue", "q": -4, "r": r_offset, "soldiers": 450},
			{"id": "B_ARC_1", "class": "archer", "faction": "blue", "q": -5, "r": r_offset - 1, "soldiers": 220},
			{"id": "B_CAV_1", "class": "cavalry", "faction": "blue", "q": -4, "r": r_offset + 2, "soldiers": 280},
			{"id": "R_HQ_1", "class": "hq", "faction": "red", "q": 11, "r": r_offset, "soldiers": 300},
			{"id": "R_INF_1", "class": "infantry", "faction": "red", "q": 4, "r": r_offset, "soldiers": 450},
			{"id": "R_ARC_1", "class": "archer", "faction": "red", "q": 5, "r": r_offset + 1, "soldiers": 220},
			{"id": "R_CAV_1", "class": "cavalry", "faction": "red", "q": 4, "r": r_offset - 2, "soldiers": 280},
		], "start_turn": 1,
	}


func _bot_observation(knowledge: Dictionary, side: String, map_bounds: Dictionary) -> Dictionary:
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
		var text := str(u.get("troop_text", ""))
		enemies.append({"unit_id": str(u.get("id", "")), "class": str(u.get("class", "unknown")),
			"q": int(u.get("q", 0)), "r": int(u.get("r", 0)), "troop_estimate": text,
			"contact_state": "current_visible"})
	var stale: Array = []
	var stale_key := "last_known_enemy_contacts" if side == "blue" else "last_known_blue_contacts"
	for raw in ledger.get(stale_key, []):
		if raw is Dictionary:
			var contact: Dictionary = raw
			stale.append({"unit_id": str(contact.get("id", "")), "class": str(contact.get("class", "unknown")),
				"q": int(contact.get("q", 0)), "r": int(contact.get("r", 0)),
				"contact_state": "stale_last_known", "last_seen_turn": int(contact.get("last_seen_turn", 0))})
	return {"side": side, "current_turn": int(knowledge.get("current_turn", 0)),
		"map_bounds": map_bounds,
		"friendly_units": friends, "known_enemy_units": enemies,
		"stale_enemy_units": stale,
		"mission": {"scenario_id": str(knowledge.get("scenario_id", "")), "objectives": knowledge.get("objectives", [])}}


func _enrich_candidates(candidates: Array, sim: RefCounted, side: String, observation: Dictionary) -> Array:
	var out: Array = []
	var service: RefCounted = sim.get_service()
	for raw in candidates:
		if not raw is Dictionary:
			continue
		var candidate: Dictionary = (raw as Dictionary).duplicate(true)
		var kind := str(candidate.get("action_type", "")).to_upper()
		# The complete legal pool may contain routes across unseen hexes.
		# Declining those moves prevents a concealed occupier from causing an
		# executor INVALID without learning its position from world truth.
		if kind == "MOVE" and not bool(candidate.get("route_fully_visible", false)):
			continue
		if kind == "ATTACK":
			var preview: Dictionary = service.call("preview_attack", str(candidate.get("unit_id", "")), str(candidate.get("target_id", "")), side)
			if bool(preview.get("ok", false)):
				candidate["expected_enemy_casualties_min"] = float(preview.get("expected_enemy_casualties_min", 0.0))
				candidate["expected_enemy_casualties_max"] = float(preview.get("expected_enemy_casualties_max", 0.0))
				candidate["expected_friendly_casualties_min"] = float(preview.get("expected_friendly_casualties_min", 0.0))
				candidate["expected_friendly_casualties_max"] = float(preview.get("expected_friendly_casualties_max", 0.0))
				if str(_observed_class(observation, str(candidate.get("target_id", "")))).to_lower() == "hq" \
						and float(candidate["expected_enemy_casualties_min"]) >= float(preview.get("defender_troops", 1)):
					candidate["guaranteed_enemy_hq_kill"] = true
				candidate["kill_fraction"] = 1.0 if float(candidate["expected_enemy_casualties_max"]) >= float(_observed_count(observation, str(candidate.get("target_id", "")))) else 0.0
		elif kind == "ASSAULT" and str(candidate.get("garrison_target_id", "")) != "":
			candidate["target_id"] = str(candidate.get("garrison_target_id", ""))
		out.append(candidate)
	return out


func _observed_class(observation: Dictionary, unit_id: String) -> String:
	for raw in observation.get("known_enemy_units", []):
		if raw is Dictionary and str((raw as Dictionary).get("unit_id", "")) == unit_id \
				and str((raw as Dictionary).get("contact_state", "")) == "current_visible":
			return str((raw as Dictionary).get("class", ""))
	return ""



func _observed_count(observation: Dictionary, unit_id: String) -> int:
	for raw in observation.get("known_enemy_units", []):
		if raw is Dictionary and str((raw as Dictionary).get("unit_id", "")) == unit_id:
			var text := str((raw as Dictionary).get("troop_estimate", ""))
			return text.to_int() if text.is_valid_int() else 300
	return 300


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
		var kind := str(c.get("action_type", "")).to_upper()
		if kind == "ATTACK" and not visible_ids.has(str(c.get("target_id", ""))):
			return false
		if kind == "ASSAULT" and str(c.get("garrison_target_id", "")) != "" and not visible_ids.has(str(c.get("garrison_target_id", ""))):
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
			return {"ok": false, "unit_id": str(u.get("id", "")), "q": u.get("q", 0), "r": u.get("r", 0)}
	return {"ok": true}


func _summarize(fixtures: Dictionary, population: Dictionary, determinism: Dictionary, elapsed_ms: int) -> Dictionary:
	var wins := {"blue": 0, "red": 0, "draw": 0}
	var reasons: Dictionary = {}
	var side_action_types: Dictionary = {"blue": {}, "red": {}}
	var opening_actions: Dictionary = {}
	var trace_digests: Dictionary = {}
	var actions := 0
	var turns := 0.0
	var all_errors: Array = []
	var passed := true
	for row_val in _results:
		var row: Dictionary = row_val
		var winner := str(row.get("winner", ""))
		wins[winner if winner in ["blue", "red"] else "draw"] = int(wins.get(winner if winner in ["blue", "red"] else "draw", 0)) + 1
		var reason := str(row.get("terminal_reason", ""))
		reasons[reason] = int(reasons.get(reason, 0)) + 1
		var trace: Array = row.get("trace", [])
		if not trace.is_empty():
			var opening := str((trace[0] as Dictionary).get("candidate_id", ""))
			opening_actions[opening] = true
		trace_digests[str(row.get("trace_digest", ""))] = true
		actions += int(row.get("actions", 0))
		var by_side: Dictionary = row.get("action_types_by_side", {})
		for side_name in ["blue", "red"]:
			var side_hist: Dictionary = by_side.get(side_name, {})
			for kind_val in side_hist.keys():
				var kind := str(kind_val)
				var aggregate: Dictionary = side_action_types[side_name]
				aggregate[kind] = int(aggregate.get(kind, 0)) + int(side_hist[kind_val])
				side_action_types[side_name] = aggregate
		turns += float(row.get("turns", 0))
		all_errors.append_array(row.get("errors", []))
		passed = passed and bool(row.get("pass", false))
	var matches_ok := _results.size() == _matches and _matches >= 1 and _matches <= 50
	passed = passed and matches_ok and bool(fixtures.get("pass", false)) and bool(population.get("pass", false)) \
		and bool(determinism.get("pass", false)) and _invalid_count == 0 and _oob_count == 0 \
		and _legal_selection_failures == 0 and _fog_leak_failures == 0 and _rationality_failures == 0
	var diversity := {"unique_opening_action_ids": opening_actions.size(), "unique_action_trace_digests": trace_digests.size(),
		"action_type_entropy_bits": _action_entropy(_all_action_types)}
	return {"version": "utility_bot_v0_benchmark_v1", "pass": passed,
		"match_count": _results.size(), "wins_losses_draws": wins,
		"average_battle_length_actions": float(actions) / float(maxi(1, _results.size())),
		"average_battle_length_turns": turns / float(maxi(1, _results.size())),
		"illegal_action_count": _invalid_count, "out_of_bounds_count": _oob_count,
		"non_enumerated_selection_count": _legal_selection_failures,
		"hidden_candidate_target_count": _fog_leak_failures,
		"bounded_choice_rationality_failures": _rationality_failures,
		"terminal_reason_distribution": reasons, "action_type_distribution": _all_action_types,
		"action_type_distribution_by_side": side_action_types,
		"archetype_distribution": _all_archetypes,
		"side_swaps": int(_matches / 2), "bot_seed_ranges": {"development": [_seed_base + _start_index * 2, _seed_base + (_start_index + _matches) * 2 - 1], "held_out_reserved": [10000, 19999]},
		"determinism": determinism, "population_diversity": population,
		"actual_match_behavioral_diversity": diversity,
		"contract_fixtures": fixtures, "match_errors": all_errors,
		"side_rule_asymmetry_note": "The current UnitManager only permits rest/fortify candidates for BLUE; exact action-pool equality is not a game contract. The symmetry fixture checks both sides retain MOVE/ATTACK/WAIT/END_TURN, with equal attack candidates under a faction swap.",
		"elapsed_ms": elapsed_ms,
		"runtime_note": "Headless verification runs through SimController and its authoritative Godot manager/service; no Python simulation or learned model is involved."}


func _write_json(path: String, data: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(_out_dir)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("Unable to write UtilityBot benchmark: " + path)
		return
	file.store_string(JSON.stringify(data, "  ") + "\n")
	file.close()


func _flatten(value: Variant) -> String:
	return JSON.stringify(value)


func _trace_digest(trace: Array) -> String:
	return "%016x" % hash(JSON.stringify(trace))


func _action_entropy(counts: Dictionary) -> float:
	var total := 0.0
	for value in counts.values():
		total += float(value)
	if total <= 0.0:
		return 0.0
	var entropy := 0.0
	for value in counts.values():
		var p := float(value) / total
		if p > 0.0:
			entropy -= p * log(p) / log(2.0)
	return snappedf(entropy, 0.001)
