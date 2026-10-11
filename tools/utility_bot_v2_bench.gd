extends SceneTree

## Utility Bot V2 strength gate: V2 (candidate) vs FROZEN V1, paired side
## swaps, real terminal games through the authoritative SimController.
##
## Pair layout (per pair index):
##   Game A (even match id): V2 RED  vs V1 BLUE
##   Game B (odd  match id): V1 RED  vs V2 BLUE
##
## Usage (development sample):
##   Godot_v4.2.2-stable_win64_console.exe --headless --path . \
##     --script res://tools/utility_bot_v2_bench.gd -- \
##     --matches=20 --max-actions=800 --seed-base=1100 --shard=0 --shards=1 \
##     --out-dir=.../artifacts/utility_bot_v2/dev_sample
## Usage (final held-out, sharded):
##   ... --matches=50 --seed-base=11000 --shard=0 --shards=4 --out-dir=.../final_held_out/shard0
## Merge shards into one report:
##   ... --merge-from=.../final_held_out --out-dir=.../final_held_out

const SimControllerCls = preload("res://scripts/sim/sim_controller.gd")
const DirectEnumeratorCls = preload("res://scripts/sim/direct_legal_enumerator.gd")
const UtilityBotCls = preload("res://scripts/utility_bot/utility_bot.gd")
const UtilityBotV1Cls = preload("res://scripts/utility_bot/utility_bot_v1.gd")
const UtilityBotV2Cls = preload("res://scripts/utility_bot/utility_bot_v2.gd")
const ScenariosCls = preload("res://scripts/cloud2/cloud2_debug_scenarios.gd")

const ARCHETYPES := ["AGGRESSIVE", "DEFENSIVE", "MANEUVER", "ATTRITION", "OPPORTUNIST", "COUNTERPUNCH"]
const SCENARIOS := ["DEV_COMPACT_CENTER", "DEV_COMPACT_NORTH", "DEV_COMPACT_SOUTH"]
const DEFAULT_OUT := "D:/Game development/Demon slayer/StrategyGame/artifacts/utility_bot_v2"
const V2_ROLE := "v2"
const V1_ROLE := "v1"

var _matches := 200
var _max_actions := 800
var _seed_base := 11000
var _start_index := 0
var _shard := 0
var _shards := 1
var _merge_from := ""
var _out_dir := DEFAULT_OUT
var _results: Array = []
var _traces: Array = []
var _planning_traces: Array = []
var _all_action_types: Dictionary = {}
var _all_archetypes: Dictionary = {}
var _invalid_count := 0
var _oob_count := 0
var _legal_selection_failures := 0
var _fog_leak_failures := 0
var _rationality_failures := 0


func _init() -> void:
	_parse_args()
	if not _merge_from.is_empty():
		_merge_shards()
		return
	print("[UTILITY_V2_BENCH] config matches=%d max_actions=%d seed_base=%d shard=%d/%d out_dir=%s" % [
		_matches, _max_actions, _seed_base, _shard, _shards, _out_dir])
	var started := Time.get_ticks_msec()
	var fixtures := _run_contract_fixtures()
	var population := _run_population_probe()
	var determinism := _run_determinism_probe()
	for offset in range(_matches):
		var i := _start_index + offset
		if i % _shards != _shard:
			continue
		var row := _run_match(i)
		_results.append(row)
		if _traces.size() < 3:
			_traces.append({"match_id": row.get("match_id", i), "trace": row.get("trace", [])})
		var planning: Array = row.get("planning_trace", [])
		if not planning.is_empty() and _planning_traces.size() < 6:
			_planning_traces.append({"match_id": row.get("match_id", i), "profile": row.get("v2_profile", {}),
				"planning": planning})
		print("[UTILITY_V2_BENCH] match %d v2_role=%s winner=%s turns=%s actions=%d reason=%s" % [
			i, str(row.get("v2_side", "")), str(row.get("winner", "")), str(row.get("turns", 0)),
			int(row.get("actions", 0)), str(row.get("terminal_reason", ""))])
	# Reproducibility: replay one completed match with identical seeds.
	var repro := {"pass": true, "detail": "not_replayed"}
	if not _results.is_empty():
		var first: Dictionary = _results[0]
		var replay := _run_match(int(first.get("match_id", 0)))
		repro = {"pass": str(replay.get("trace_digest", "")) == str(first.get("trace_digest", "")),
			"match_id": first.get("match_id", 0),
			"trace_digest_a": first.get("trace_digest", ""), "trace_digest_b": replay.get("trace_digest", "")}
	var summary := _summarize(fixtures, population, determinism, repro, Time.get_ticks_msec() - started)
	var shard_tag := "" if _shards == 1 else "_shard%d" % _shard
	_write_json(_out_dir.path_join("raw_matches%s.json" % shard_tag), {"matches": _results})
	_write_json(_out_dir.path_join("sample_decision_traces%s.json" % shard_tag), {"samples": _traces})
	_write_json(_out_dir.path_join("planning_traces%s.json" % shard_tag), {"samples": _planning_traces})
	_write_json(_out_dir.path_join("BENCHMARK%s.json" % shard_tag), summary)
	print(JSON.stringify(summary, "  "))
	quit(0 if bool(summary.get("pass", false)) else 1)


func _parse_args() -> void:
	var args := OS.get_cmdline_user_args()
	args.append_array(OS.get_cmdline_args())
	for raw in args:
		var arg := str(raw).strip_edges().trim_prefix("--")
		if arg.begins_with("matches="):
			_matches = clampi(int(arg.get_slice("=", 1)), 2, 400)
		elif arg.begins_with("max-actions="):
			_max_actions = clampi(int(arg.get_slice("=", 1)), 20, 10000)
		elif arg.begins_with("seed-base="):
			_seed_base = clampi(int(arg.get_slice("=", 1)), 0, 20000)
		elif arg.begins_with("start-index="):
			_start_index = clampi(int(arg.get_slice("=", 1)), 0, 9999)
		elif arg.begins_with("shard="):
			_shard = maxi(0, int(arg.get_slice("=", 1)))
		elif arg.begins_with("shards="):
			_shards = maxi(1, int(arg.get_slice("=", 1)))
		elif arg.begins_with("merge-from="):
			_merge_from = arg.get_slice("=", 1).trim_prefix("\"").trim_suffix("\"")
		elif arg.begins_with("out-dir="):
			_out_dir = arg.get_slice("=", 1).trim_prefix("\"").trim_suffix("\"")


# ------------------------------------------------------------------
# Contract fixtures: fog authority, terminal symmetry, legality
# ------------------------------------------------------------------

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
	var no_leaks := _candidate_targets_visible(blue_candidates, blue_visible) \
		and _candidate_targets_visible(red_candidates, red_visible)
	var hidden_id_absent := _flatten(blue_obs).find("R_INF_1") == -1 \
		and _flatten(red_obs).find("B_INF_1") == -1
	# V2 policy contract: hidden contacts never influence any V2 decision.
	var v2_leak_ok := true
	var v2_bot: RefCounted = UtilityBotV2Cls.new()
	v2_bot.call("configure", 4242)
	var v2_decision: Dictionary = v2_bot.call("select_action", red_obs,
		[{"candidate_id": "WAIT|probe", "unit_id": "probe", "action_type": "WAIT"}])
	if _flatten(v2_decision).find("B_INF_1") != -1:
		v2_leak_ok = false
	return {"pass": hq_ok and no_leaks and hidden_id_absent and v2_leak_ok,
		"hq_terminal_symmetry": hq_ok, "red_hq_result": red_dead, "blue_hq_result": blue_dead,
		"candidate_target_visibility": no_leaks,
		"hidden_contact_absent_from_authorized_observations": hidden_id_absent,
		"v2_decision_contains_no_hidden_contacts": v2_leak_ok}


# ------------------------------------------------------------------
# Population + determinism probes (V2)
# ------------------------------------------------------------------

func _run_population_probe() -> Dictionary:
	var profile_signatures: Dictionary = {}
	var choices: Dictionary = {}
	var rational := true
	var own_hq_preview_safe := true
	var terminal_dominant := true
	var v2_param_count := 0
	for i in range(48):
		var bot: RefCounted = UtilityBotV2Cls.new()
		bot.call("configure", _seed_base + 1000 + i)
		var profile: Dictionary = bot.call("profile")
		var signature := JSON.stringify(profile)
		profile_signatures[signature] = true
		if float(profile.get("sacrifice_tolerance", -1.0)) >= 0.0:
			v2_param_count += 1
		var obs := {"side": "blue", "turn": 3, "friendly_units": [
			{"unit_id": "M", "class": "infantry", "q": 0, "r": 0, "soldiers": 450}],
			"known_enemy_units": [
			{"unit_id": "E", "class": "infantry", "q": 1, "r": 0, "soldiers": 200, "contact_state": "current_visible"},
			{"unit_id": "HQ", "class": "hq", "q": 2, "r": 0, "soldiers": 1, "contact_state": "current_visible"},
			{"unit_id": "E2", "class": "archer", "q": 1, "r": 1, "soldiers": 200, "contact_state": "current_visible"}],
			"map_bounds": {"q_min": -12, "q_max": 12, "r_min": -10, "r_max": 10}}
		var terminal_candidates := [
			{"candidate_id": "SAFE_MOVE", "unit_id": "M", "action_type": "MOVE", "destination": [1, 2]},
			{"candidate_id": "OWN_HQ_LOSS", "unit_id": "M", "action_type": "MOVE", "destination": [0, 0], "utility_features": {"own_hq_loss": 1.0}},
			{"candidate_id": "ENEMY_HQ_KILL", "unit_id": "M", "action_type": "ATTACK", "target_id": "HQ", "utility_features": {"enemy_hq_kill": 1.0}}]
		var terminal_decision: Dictionary = bot.call("select_action", obs, terminal_candidates)
		if not bool(terminal_decision.get("ok", false)) or str(terminal_decision.get("candidate_id", "")) != "ENEMY_HQ_KILL":
			terminal_dominant = false
		var decision: Dictionary = bot.call("select_action", obs, [
			{"candidate_id": "ATTACK|M|E", "unit_id": "M", "action_type": "ATTACK", "target_id": "E",
				"expected_enemy_casualties_max": 45.0, "expected_friendly_casualties_max": 3.0},
			{"candidate_id": "ATTACK|M|E2", "unit_id": "M", "action_type": "ATTACK", "target_id": "E2",
				"expected_enemy_casualties_max": 45.0, "expected_friendly_casualties_max": 3.0}])
		if not bool(decision.get("ok", false)):
			rational = false
		choices[str(decision.get("candidate_id", "ERROR"))] = int(choices.get(str(decision.get("candidate_id", "ERROR")), 0)) + 1
		if decision.get("planning", {}) is Dictionary and (decision.get("planning", {}) as Dictionary).is_empty():
			rational = false
		var hq_obs := {"side": "blue", "turn": 4, "friendly_units": [
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
	return {"pass": profile_signatures.size() >= 40 and choices.size() >= 2 and rational \
		and own_hq_preview_safe and terminal_dominant and v2_param_count == 48,
		"sampled_profiles": 48, "unique_profiles": profile_signatures.size(),
		"terminal_win_dominates": terminal_dominant,
		"certain_own_hq_preview_loss_avoided": own_hq_preview_safe,
		"nonterminal_seeded_choice_diversity": choices.size() >= 2,
		"planning_trace_present": rational,
		"v2_advanced_parameters_present": v2_param_count == 48,
		"distinct_selected_actions": choices.size(), "selected_choices": choices}


func _run_determinism_probe() -> Dictionary:
	var same := true
	var trace_a: Array = []
	var trace_b: Array = []
	var intent_a := ""
	var intent_b := ""
	for replay in range(2):
		var bot: RefCounted = UtilityBotV2Cls.new()
		bot.call("configure", _seed_base + 4000)
		var obs := {"side": "blue", "turn": 1, "friendly_units": [
			{"unit_id": "M", "class": "infantry", "q": 0, "r": 0, "soldiers": 400},
			{"unit_id": "N", "class": "archer", "q": -1, "r": 0, "soldiers": 220}],
			"known_enemy_units": [{"unit_id": "E", "class": "cavalry", "q": 3, "r": 0, "soldiers": 280,
				"contact_state": "current_visible"}],
			"map_bounds": {"q_min": -12, "q_max": 12, "r_min": -10, "r_max": 10}}
		var cands := [
			{"candidate_id": "WAIT", "unit_id": "M", "action_type": "WAIT"},
			{"candidate_id": "MOVE", "unit_id": "M", "action_type": "MOVE", "destination": [1, 0]},
			{"candidate_id": "MOVE2", "unit_id": "M", "action_type": "MOVE", "destination": [0, 1]},
			{"candidate_id": "ATTACK", "unit_id": "N", "action_type": "ATTACK", "target_id": "E",
				"expected_enemy_casualties_min": 20, "expected_enemy_casualties_max": 60,
				"expected_friendly_casualties_min": 0, "expected_friendly_casualties_max": 15}]
		for _i in range(12):
			var decision: Dictionary = bot.call("select_action", obs, cands)
			if replay == 0:
				trace_a.append(str(decision.get("candidate_id", "")))
				intent_a = str((decision.get("planning", {}) as Dictionary).get("intent", {}).get("type", ""))
			else:
				trace_b.append(str(decision.get("candidate_id", "")))
				intent_b = str((decision.get("planning", {}) as Dictionary).get("intent", {}).get("type", ""))
	same = trace_a == trace_b and intent_a == intent_b
	return {"pass": same, "same_seed_same_world_trace": same, "trace": trace_a,
		"intent_sequence_reproducible": intent_a == intent_b, "intent": intent_a}


# ------------------------------------------------------------------
# One paired match: V2 vs frozen V1 through SimController
# ------------------------------------------------------------------

func _run_match(index: int) -> Dictionary:
	var pair_index := int(index / 2)
	var scenario_id: String = SCENARIOS[pair_index % SCENARIOS.size()]
	var scenario_seed := _seed_base + 500 + pair_index
	var v2_is_blue := index % 2 == 1  # Game A: V2 RED; Game B: V2 BLUE
	var sim: RefCounted = _load_scenario(scenario_id, scenario_seed, false)
	if sim == null:
		return {"match_id": index, "pass": false, "error": "load_failed"}
	var v2_seed := _seed_base + pair_index * 2 + (1 if v2_is_blue else 0)
	var v1_seed := _seed_base + pair_index * 2 + (0 if v2_is_blue else 1)
	var v2_bot: RefCounted = UtilityBotV2Cls.new()
	var v1_bot: RefCounted = UtilityBotV1Cls.new()
	var v2_arch: String = ARCHETYPES[pair_index % ARCHETYPES.size()]
	var v1_arch: String = ARCHETYPES[(pair_index + 3) % ARCHETYPES.size()]
	v2_bot.call("configure", v2_seed, v2_arch)
	v1_bot.call("configure", v1_seed, v1_arch)
	var profile_v2: Dictionary = v2_bot.call("profile")
	var profile_v1: Dictionary = v1_bot.call("profile")
	_all_archetypes[v2_arch] = int(_all_archetypes.get(v2_arch, 0)) + 1
	_all_archetypes[v1_arch] = int(_all_archetypes.get(v1_arch, 0)) + 1
	var enumerator: RefCounted = DirectEnumeratorCls.new()
	enumerator.configure(sim)
	var side := "blue"
	var actions := 0
	var action_types: Dictionary = {}
	var side_actions := {"blue": 0, "red": 0}
	var side_action_types := {"blue": {}, "red": {}}
	var trace: Array = []
	var planning_trace: Array = []
	var errors: Array = []
	var initial_turn := int(sim.evaluate_battle().get("turn", 0))
	var max_turn := int((sim.get("_scenario") as Dictionary).get("mission_contract", {}).get("turn_limit", 60))
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
		var is_v2_side := (side == "blue") == v2_is_blue
		if OS.get_environment("V2_DEBUG_POOL") == "1" and side == ("blue" if v2_is_blue else "red") \
				and int(terminal.get("turn", 0)) >= 55:
			var ids: Array = []
			for ce_val in enriched:
				ids.append(str((ce_val as Dictionary).get("candidate_id", "")))
			print("[V2_POOL] t=%d side=%s n=%d %s" % [int(terminal.get("turn", 0)), side, ids.size(), str(ids)])
		var bot: RefCounted = v2_bot if is_v2_side else v1_bot
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
		if not alternatives.is_empty():
			var active_profile: Dictionary = profile_v2 if is_v2_side else profile_v1
			var top_score := float((alternatives[0] as Dictionary).get("score", decision.get("score", 0.0)))
			var chosen_score := float(decision.get("score", 0.0))
			if chosen_score < top_score - maxf(1.61, 3.0 * float(active_profile.get("temperature", 0.6))):
				_rationality_failures += 1
				errors.append("choice_outside_bounded_top_set")
		var kind := str(selected.get("action_type", "")).to_upper()
		if kind == "MOVE":
			var destination: Array = selected.get("destination", [])
			var bounds: Dictionary = sim.map_bounds()
			if destination.size() < 2 or int(destination[0]) < int(bounds.get("q_min", -9999)) \
					or int(destination[0]) > int(bounds.get("q_max", 9999)) \
					or int(destination[1]) < int(bounds.get("r_min", -9999)) \
					or int(destination[1]) > int(bounds.get("r_max", 9999)):
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
		if trace.size() < 450:
			trace.append({"side": side, "policy": V2_ROLE if is_v2_side else V1_ROLE,
				"turn": int(terminal.get("turn", 0)), "candidate_id": selected_id,
				"action_type": kind, "score": float(decision.get("score", 0.0))})
		if is_v2_side and decision.get("planning", {}) is Dictionary \
				and not (decision.get("planning", {}) as Dictionary).is_empty():
			# Sliding window: keep the first moves and the decisive final phase.
			planning_trace.append({"turn": int(terminal.get("turn", 0)), "candidate_id": selected_id,
				"action_type": kind, "score": float(decision.get("score", 0.0)),
				"alternatives": decision.get("alternatives", []),
				"planning": decision.get("planning", {})})
			if planning_trace.size() > 60:
				planning_trace = planning_trace.slice(planning_trace.size() - 60)
		if kind == "END_TURN":
			side = "red" if side == "blue" else "blue"
		var after: Dictionary = sim.evaluate_battle()
		if int(after.get("turn", 0)) > max_turn + 1:
			errors.append("turn_limit_overshoot")
			break
	var final: Dictionary = sim.evaluate_battle()
	var survivors := {"blue": 0, "red": 0}
	var surviving_troops := {"blue": 0, "red": 0}
	var hq_alive := {"blue": false, "red": false}
	for unit_val in sim.export_state().get("units", []):
		var unit: Dictionary = unit_val
		var faction := str(unit.get("faction", "")).to_lower()
		if faction in ["blue", "red"]:
			survivors[faction] = int(survivors[faction]) + (1 if int(unit.get("soldier_count", 0)) > 0 else 0)
			surviving_troops[faction] = int(surviving_troops[faction]) + int(unit.get("soldier_count", unit.get("soldiers", 0)))
			if str(unit.get("class", "")).to_lower() == "hq" and int(unit.get("soldier_count", 0)) > 0:
				hq_alive[faction] = true
	var terminal := bool(final.get("terminal", false))
	var v2_side_name := "blue" if v2_is_blue else "red"
	return {"match_id": index, "pair_id": pair_index, "scenario_id": scenario_id,
		"scenario_seed": scenario_seed, "v2_side": v2_side_name, "side_swapped": v2_is_blue,
		"v2_profile": profile_v2, "v1_profile": profile_v1,
		"winner": str(final.get("winner", "")), "terminal_reason": str(final.get("reason", "")),
		"terminal": terminal, "turns": int(final.get("turn", 0)) - initial_turn,
		"actions": actions, "actions_by_side": side_actions, "action_types": action_types,
		"survivors": survivors, "surviving_troops": surviving_troops,
		"casualties": {"blue": 1250 - int(surviving_troops["blue"]), "red": 1250 - int(surviving_troops["red"])},
		"hq_alive": hq_alive,
		"action_types_by_side": side_action_types, "trace_digest": _trace_digest(trace), "errors": errors,
		"pass": terminal and side_actions["blue"] > 0 and side_actions["red"] > 0 and errors.is_empty(),
		"trace": trace, "planning_trace": planning_trace}


# ------------------------------------------------------------------
# Scenario plumbing (identical shapes to utility_bot_v1_bench.gd)
# ------------------------------------------------------------------

func _load_scenario(scenario_id: String, seed: int, swap_sides: bool) -> RefCounted:
	var scenario: Dictionary
	if scenario_id.begins_with("DEV_COMPACT_"):
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
		push_error("UtilityBotV2 scenario load failed: " + str(loaded))
		return null
	return sim


func _compact_dev_scenario(scenario_id: String, seed: int) -> Dictionary:
	var r_offset := 0
	if scenario_id.ends_with("NORTH"):
		r_offset = -2
	elif scenario_id.ends_with("SOUTH"):
		r_offset = 2
	return {
		"scenario_id": scenario_id.to_lower(), "scenario_version": "utility_bot_v2_bench",
		"seed": seed, "mission_contract": {"primary_objective": "destroy_all_red", "turn_limit": 60},
		"map": {"bounds": {"q_min": -12, "q_max": 12, "r_min": -10, "r_max": 10},
			"default_terrain": 0, "terrain_overrides": {}, "river_cells": []},
		"forces": [
			{"id": "B_HQ_1", "class": "hq", "faction": "blue", "q": -3, "r": r_offset, "soldiers": 300},
			{"id": "B_INF_1", "class": "infantry", "faction": "blue", "q": -2, "r": r_offset, "soldiers": 450},
			{"id": "B_ARC_1", "class": "archer", "faction": "blue", "q": -3, "r": r_offset - 1, "soldiers": 220},
			{"id": "B_CAV_1", "class": "cavalry", "faction": "blue", "q": -2, "r": r_offset + 2, "soldiers": 280},
			{"id": "R_HQ_1", "class": "hq", "faction": "red", "q": 3, "r": r_offset, "soldiers": 300},
			{"id": "R_INF_1", "class": "infantry", "faction": "red", "q": 2, "r": r_offset, "soldiers": 450},
			{"id": "R_ARC_1", "class": "archer", "faction": "red", "q": 3, "r": r_offset + 1, "soldiers": 220},
			{"id": "R_CAV_1", "class": "cavalry", "faction": "red", "q": 2, "r": r_offset - 2, "soldiers": 280},
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
		if kind == "ASSAULT" and str(c.get("garrison_target_id", "")) != "" \
				and not visible_ids.has(str(c.get("garrison_target_id", ""))):
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


# ------------------------------------------------------------------
# Summary / report
# ------------------------------------------------------------------

func _summarize(fixtures: Dictionary, population: Dictionary, determinism: Dictionary,
		repro: Dictionary, elapsed_ms: int) -> Dictionary:
	var v2_wins := 0
	var v1_wins := 0
	var draws := 0
	var v2_by_side := {"blue": {"win": 0, "loss": 0, "draw": 0}, "red": {"win": 0, "loss": 0, "draw": 0}}
	var v2_arch_record: Dictionary = {}
	var total_casualties := {"blue": 0, "red": 0}
	var v2_casualty_diff := 0
	var hq_outcomes := {"blue_alive": 0, "red_alive": 0, "v2_hq_alive": 0, "v1_hq_alive": 0}
	var reasons: Dictionary = {}
	var side_action_types: Dictionary = {"blue": {}, "red": {}}
	var opening_actions: Dictionary = {}
	var trace_digests: Dictionary = {}
	var actions := 0
	var turns := 0.0
	var timeout_draws := 0
	var all_errors: Array = []
	var passed := true
	for row_val in _results:
		var row: Dictionary = row_val
		var winner := str(row.get("winner", ""))
		var v2_side := str(row.get("v2_side", ""))
		if v2_side not in ["blue", "red"]:
			continue
		var outcome := "draw" if winner not in ["blue", "red"] else ("win" if winner == v2_side else "loss")
		var side_record: Dictionary = v2_by_side[v2_side]
		side_record[outcome] = int(side_record[outcome]) + 1
		if outcome == "win":
			v2_wins += 1
		elif outcome == "loss":
			v1_wins += 1
		else:
			draws += 1
			if str(row.get("terminal_reason", "")) == "turn_limit_reached_without_decision":
				timeout_draws += 1
		var arch := str((row.get("v2_profile", {}) as Dictionary).get("archetype", "?"))
		if not v2_arch_record.has(arch):
			v2_arch_record[arch] = {"win": 0, "loss": 0, "draw": 0}
		(v2_arch_record[arch] as Dictionary)[outcome] = int((v2_arch_record[arch] as Dictionary)[outcome]) + 1
		for side_name in ["blue", "red"]:
			total_casualties[side_name] = int(total_casualties[side_name]) + int((row.get("casualties", {}) as Dictionary).get(side_name, 0))
			hq_outcomes[side_name + "_alive"] = int(hq_outcomes[side_name + "_alive"]) + (1 if bool((row.get("hq_alive", {}) as Dictionary).get(side_name, false)) else 0)
		var v2_cas := int((row.get("casualties", {}) as Dictionary).get(v2_side, 0))
		var v1_side := "red" if v2_side == "blue" else "blue"
		var v1_cas := int((row.get("casualties", {}) as Dictionary).get(v1_side, 0))
		v2_casualty_diff += v1_cas - v2_cas
		hq_outcomes["v2_hq_alive"] = int(hq_outcomes["v2_hq_alive"]) + (1 if bool((row.get("hq_alive", {}) as Dictionary).get(v2_side, false)) else 0)
		hq_outcomes["v1_hq_alive"] = int(hq_outcomes["v1_hq_alive"]) + (1 if bool((row.get("hq_alive", {}) as Dictionary).get(v1_side, false)) else 0)
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
	var total := maxi(1, _results.size())
	var match_score := float(v2_wins + 0.5 * draws) / float(total)
	var score_blue := (float(v2_by_side["blue"]["win"]) + 0.5 * float(v2_by_side["blue"]["draw"])) / float(maxi(1, int(_results.size() / 2)))
	var score_red := (float(v2_by_side["red"]["win"]) + 0.5 * float(v2_by_side["red"]["draw"])) / float(maxi(1, int(_results.size() / 2)))
	var archetype_ok := true
	for arch_key in v2_arch_record.keys():
		var rec: Dictionary = v2_arch_record[arch_key]
		if int(rec.get("win", 0)) + int(rec.get("draw", 0)) == 0:
			archetype_ok = false  # a single archetype collapsing entirely is a red flag
	var draw_rate := float(draws) / float(total)
	passed = passed and bool(fixtures.get("pass", false)) and bool(population.get("pass", false)) \
		and bool(determinism.get("pass", false)) and bool(repro.get("pass", false)) \
		and _invalid_count == 0 and _oob_count == 0 \
		and _legal_selection_failures == 0 and _fog_leak_failures == 0 and _rationality_failures == 0 \
		and match_score >= 0.65 and score_blue > 0.5 and score_red > 0.5 \
		and draw_rate < 0.5 and archetype_ok
	var diversity := {"unique_opening_action_ids": opening_actions.size(),
		"unique_action_trace_digests": trace_digests.size(),
		"action_type_entropy_bits": _action_entropy(_all_action_types)}
	return {"version": "utility_bot_v2_benchmark_v1", "pass": passed,
		"evaluation_phase": "final_held_out" if (_seed_base >= 10000 and _matches >= 100) else "development_sample",
		"comparison": "V2 (candidate) vs frozen V1", "pair_layout": {
			"game_a": "V2 RED vs V1 BLUE", "game_b": "V1 RED vs V2 BLUE"},
		"match_count": _results.size(), "target_games": _matches,
		"v2_wins": v2_wins, "v1_wins": v1_wins, "draws": draws,
		"v2_match_score": match_score, "score_formula": "win=1 draw=0.5 loss=0",
		"v2_by_side": v2_by_side, "v2_side_scores": {"blue": score_blue, "red": score_red},
		"v2_archetype_breakdown": v2_arch_record,
		"casualties": total_casualties,
		"casualty_differential_v1_minus_v2": v2_casualty_diff,
		"hq_outcomes": hq_outcomes,
		"average_battle_length_actions": float(actions) / float(total),
		"average_battle_length_turns": turns / float(total),
		"illegal_action_count": _invalid_count, "out_of_bounds_count": _oob_count,
		"non_enumerated_selection_count": _legal_selection_failures,
		"hidden_candidate_target_count": _fog_leak_failures,
		"bounded_choice_rationality_failures": _rationality_failures,
		"timeout_draw_count": timeout_draws,
		"timeout_or_draw_rate": draw_rate,
		"terminal_reason_distribution": reasons, "action_type_distribution": _all_action_types,
		"action_type_distribution_by_side": side_action_types,
		"archetype_distribution": _all_archetypes,
		"side_swaps": int(_results.size() / 2),
		"seed_policy": {"development_seed_base": 1100, "final_held_out_seed_base": 11000,
			"this_run_seed_base": _seed_base,
			"note": "Final evaluation seeds are never used during V2 tuning."},
		"reproducibility": repro, "determinism": determinism,
		"population_diversity": population,
		"actual_match_behavioral_diversity": diversity,
		"contract_fixtures": fixtures, "match_errors": all_errors,
		"elapsed_ms": elapsed_ms,
		"runtime_note": "Headless verification runs through SimController and its authoritative Godot manager/service; V1 is the frozen policy class, unmodified."}


func _merge_shards() -> void:
	var dir := DirAccess.open(_merge_from)
	if dir == null:
		push_error("merge-from unreadable: " + _merge_from)
		quit(1)
		return
	var merged: Array = []
	var shard_summaries: Array = []
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if not dir.current_is_dir():
			if fname.begins_with("raw_matches") and fname.ends_with(".json"):
				var f := FileAccess.open(_merge_from.path_join(fname), FileAccess.READ)
				if f != null:
					var parsed: Variant = JSON.parse_string(f.get_as_text())
					f.close()
					if parsed is Dictionary:
						merged.append_array((parsed as Dictionary).get("matches", []))
			elif fname.begins_with("BENCHMARK") and fname.ends_with(".json"):
				var f2 := FileAccess.open(_merge_from.path_join(fname), FileAccess.READ)
				if f2 != null:
					var parsed2: Variant = JSON.parse_string(f2.get_as_text())
					f2.close()
					if parsed2 is Dictionary:
						shard_summaries.append(parsed2)
		fname = dir.get_next()
	dir.list_dir_end()
	merged.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.get("match_id", 0)) < int(b.get("match_id", 0)))
	_results = merged
	# Rebuild aggregates from raw rows so the merged report is self-consistent.
	var fixtures := {}
	var population := {}
	var determinism := {}
	var repro := {}
	var have_fixtures := false
	for s_val in shard_summaries:
		var s: Dictionary = s_val
		if not have_fixtures and not (s.get("contract_fixtures", {}) as Dictionary).is_empty():
			fixtures = s.get("contract_fixtures", {})
			population = s.get("population_diversity", {})
			determinism = s.get("determinism", {})
			repro = s.get("reproducibility", {})
			have_fixtures = true
		_invalid_count += int(s.get("illegal_action_count", 0))
		_oob_count += int(s.get("out_of_bounds_count", 0))
		_legal_selection_failures += int(s.get("non_enumerated_selection_count", 0))
		_fog_leak_failures += int(s.get("hidden_candidate_target_count", 0))
		_rationality_failures += int(s.get("bounded_choice_rationality_failures", 0))
	for row_val in _results:
		var row: Dictionary = row_val
		var kinds: Dictionary = row.get("action_types", {})
		for kind_val in kinds.keys():
			_all_action_types[str(kind_val)] = int(_all_action_types.get(str(kind_val), 0)) + int(kinds[kind_val])
		var v2p: Dictionary = row.get("v2_profile", {})
		var arch := str(v2p.get("archetype", "?"))
		_all_archetypes[arch] = int(_all_archetypes.get(arch, 0)) + 1
	var summary := _summarize(fixtures, population, determinism, repro, 0)
	summary["evaluation_phase"] = "final_held_out_merged"
	summary["merged_shards"] = shard_summaries.size()
	summary["match_count"] = _results.size()
	_write_json(_out_dir.path_join("BENCHMARK_MERGED.json"), summary)
	print(JSON.stringify(summary, "  "))
	quit(0 if bool(summary.get("pass", false)) else 1)


func _write_json(path: String, data: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(_out_dir)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("Unable to write UtilityBotV2 benchmark: " + path)
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
