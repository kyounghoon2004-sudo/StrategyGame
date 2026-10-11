extends SceneTree

## CONTRACT_SFT_V1 harness — production prompt capture + production validation.
## Tool-only (no production changes). Two modes:
##
##   prompts:  {mode:"prompts", scenarios:[spec]} -> [{scenario_id, side,
##             messages:[system,user], roster, snapshot_id}]
##             messages are EXACTLY what Cloud2Adapter.request_turn sends for
##             the INITIAL call: system = VictoryResponse.initial_prompt_for,
##             user = JSON.stringify(GeneralPacket.build_victory_initial(obs)).
##
##   validate: {mode:"validate", items:[{id, text, scenario:spec}]} ->
##             per item the REAL production INITIAL path (same as
##             tools/rl_proof_episode.gd, minus the battle): TurnController
##             MISSION_HIERARCHY + mock adapter carrying the exact text,
##             TRAINING_STRICT_CONTRACT=1 -> _vp_init_fire -> poll -> consume
##             -> strict fault latch. No repair, no retry, no fallback.
##             Also reports the static parse diagnostics (extract_json /
##             parse_initial) for the failure breakdown.
##
## spec: {scenario_id, side:"red"|"blue", red_forces:[unit], blue_forces:[unit],
##        primary_objective, turn_limit, bounds:{q_min,q_max,r_min,r_max}}
##        optional (CONTEXTUAL BRAIN V0 probes; absent = byte-identical):
##        default_terrain, terrain_overrides {"q,r": id}, river_cells,
##        rule_deltas {class_stats|base_mp|matchup|terrain_*: partial} merged
##        onto EpisodeSpec.base_rules() and installed in EpisodeRuntime, so
##        the engine AND the context pack read the same rules.
## Usage: godot --headless --path <project> -s res://tools/contract_sft_harness.gd -- <in> <out>

const SimControllerCls = preload("res://scripts/sim/sim_controller.gd")
const ObsCls = preload("res://scripts/cloud1/cloud1_observation.gd")
const AdapterCls = preload("res://scripts/cloud2/cloud2_adapter.gd")
const ConfigCls = preload("res://scripts/cloud2/cloud2_config.gd")
const TacticalPlanCls = preload("res://scripts/cloud2/cloud2_plan_memory.gd")
const TurnControllerCls = preload("res://scripts/cloud2/cloud2_turn_controller.gd")
const PacketCls = preload("res://scripts/cloud2/cloud2_general_packet.gd")
const VictoryResponseCls = preload("res://scripts/cloud2/cloud2_victory_response.gd")
const ResponseCls = preload("res://scripts/cloud2/cloud2_response.gd")
const BrainContextCls = preload("res://scripts/cloud2/cloud2_brain_context.gd")
const EpisodeSpecCls = preload("res://scripts/episodes/episode_spec.gd")
const EpisodeRuntimeCls = preload("res://scripts/episodes/episode_runtime.gd")

const CANARY := "contract_sft_v1_fixture_canary_not_a_real_key"
const MAX_SETTLE_FRAMES := 1200


class ExecutorStub extends Node:
	signal execution_finished(result: Dictionary)
	var busy := false
	func set_external_busy(v: bool, _reason: String = "") -> void:
		busy = v


func _init() -> void:
	call_deferred("_run")


func _sim_for(spec: Dictionary) -> RefCounted:
	var forces: Array = []
	for u in (spec.get("red_forces", []) as Array):
		forces.append((u as Dictionary).duplicate(true))
	for u in (spec.get("blue_forces", []) as Array):
		forces.append((u as Dictionary).duplicate(true))
	var sim: RefCounted = SimControllerCls.new()
	sim.load_scenario({
		"scenario_id": str(spec.get("scenario_id", "contract_sft")),
		"scenario_version": "1.0.0",
		"seed": int(spec.get("seed", 29)),
		"mission_contract": {"primary_objective": str(spec.get("primary_objective", "destroy_all_red")),
			"turn_limit": int(spec.get("turn_limit", 12))},
		"map": {"bounds": spec.get("bounds", {"q_min": -20, "q_max": 20, "r_min": -10, "r_max": 10}),
			"default_terrain": int(spec.get("default_terrain", 0)),
			"terrain_overrides": spec.get("terrain_overrides", {}), "river_cells": spec.get("river_cells", [])},
		"forces": forces,
		"start_turn": 1,
	})
	return sim


func _side(spec: Dictionary) -> String:
	return "blue" if str(spec.get("side", "red")).to_lower() == "blue" else "red"


## Probe rule deltas -> full episode rules installed for this spec only.
func _install_rules(spec: Dictionary) -> void:
	EpisodeRuntimeCls.clear()
	if not spec.has("rule_deltas"):
		return
	var rules := EpisodeSpecCls.base_rules()
	var deltas: Dictionary = spec["rule_deltas"]
	for table in deltas.keys():
		for k in (deltas[table] as Dictionary).keys():
			var v: Variant = deltas[table][k]
			if v is Dictionary:
				for f in (v as Dictionary).keys():
					rules[table][k][f] = v[f]
			else:
				rules[table][k] = v
	var meta: Dictionary = spec.get("episode_meta", {})  # optional real provenance (S0 corpus)
	EpisodeRuntimeCls.install({"episode_id": str(meta.get("episode_id", "probe_" + str(spec.get("scenario_id", "")))),
		"family": str(meta.get("family", "probe")), "split": str(meta.get("split", "probe")),
		"map": {"id": ""}, "rules": rules, "objective": {}})


## The sim's own terrain (rect bounds, default + overrides) for the context pack.
func _terrain_of(spec: Dictionary) -> Dictionary:
	var b: Dictionary = spec.get("bounds", {"q_min": -20, "q_max": 20, "r_min": -10, "r_max": 10})
	var ov: Dictionary = spec.get("terrain_overrides", {})
	var out := {}
	for q in range(int(b["q_min"]), int(b["q_max"]) + 1):
		for r in range(int(b["r_min"]), int(b["r_max"]) + 1):
			var k := "%d,%d" % [q, r]
			out[k] = int(ov.get(k, int(spec.get("default_terrain", 0))))
	return out


func _prompt_one(spec: Dictionary) -> Dictionary:
	var side := _side(spec)
	_install_rules(spec)
	var sim := _sim_for(spec)
	var obs: Dictionary = ObsCls.build(sim, side)
	if not bool(obs.get("ok", false)):
		EpisodeRuntimeCls.clear()
		return {"scenario_id": str(spec.get("scenario_id", "")), "side": side.to_upper(),
			"error": str(obs.get("error", "obs build failed"))}
	var packet: Dictionary = PacketCls.build_victory_initial(obs, side)
	if packet.has("context"):
		packet["context"] = BrainContextCls.build(obs, side, _terrain_of(spec))
	EpisodeRuntimeCls.clear()
	var roster: Array = []
	for u in (obs.get("friendly_units", []) as Array):
		roster.append(str((u as Dictionary).get("unit_id", "")))
	return {"scenario_id": str(spec.get("scenario_id", "")), "side": side.to_upper(),
		"snapshot_id": str(obs.get("snapshot_id", "")), "roster": roster,
		"n_known_enemies": (obs.get("known_enemy_units", []) as Array).size(),
		"messages": [
			{"role": "system", "content": VictoryResponseCls.initial_prompt_for(side)},
			{"role": "user", "content": JSON.stringify(packet)},
		]}


func _validate_one(item: Dictionary) -> Dictionary:
	var spec: Dictionary = item.get("scenario", {})
	var side := _side(spec)
	var text := str(item.get("text", ""))
	var rec := {"id": str(item.get("id", "")), "side": side.to_upper(),
		"completion_chars": text.length()}
	var sim := _sim_for(spec)
	var adapter := AdapterCls.new()
	var executor := ExecutorStub.new()
	var controller := TurnControllerCls.new()
	get_root().add_child(adapter)
	get_root().add_child(executor)
	get_root().add_child(controller)
	var cfg := ConfigCls.new()
	cfg.provider_id = "openai"
	cfg.model = "mock-fixture"
	cfg.endpoint = "https://mock.local/v1/chat/completions"
	cfg.set_api_key(CANARY)
	cfg.mark_test_result(true, "CONNECTED", "contract sft fixture")
	adapter.mock_mode = true
	adapter.mock_queue.append({"ok": true, "latency_ms": 5, "content_text": text})
	controller.setup(sim, executor, adapter, cfg, TacticalPlanCls.new())
	controller.set_side(side)
	controller.set_control_mode("MISSION_HIERARCHY")
	var obs: Dictionary = ObsCls.build(sim, side)
	var roster: Array = []
	for u in (obs.get("friendly_units", []) as Array):
		roster.append(str((u as Dictionary).get("unit_id", "")))
	# Static diagnostics (not the verdict): extraction + production parser.
	var extracted := ResponseCls.extract_json(text)
	rec["extract_nonempty"] = not extracted.is_empty()
	var parsed: Dictionary = VictoryResponseCls.parse_initial(text,
		{"turn": 1, "snapshot_id": str(obs.get("snapshot_id", "")), "roster": roster})
	rec["parse_ok"] = bool(parsed.get("ok", false))
	rec["parse_code"] = str(parsed.get("code", ""))
	rec["parse_detail"] = str(parsed.get("detail", "")).left(220)
	# Authoritative production path.
	var fired: Dictionary = controller._vp_init_fire(obs,
		{"trigger": "INITIAL_PLAN", "reason": "contract sft validation.", "turn": 1}, 1)
	rec["fire_ok"] = bool(fired.get("ok", false))
	var done := {}
	for i in range(MAX_SETTLE_FRAMES):
		done = controller.victory_poll_initial()
		var st := str(done.get("status", ""))
		if st == "READY" or st == "FAILED":
			break
		await process_frame
	rec["status"] = str(done.get("status", "TIMEOUT"))
	var ist: Dictionary = controller.victory_initial_status()
	var hist: Array = controller.get_general_history()
	rec["general_calls"] = hist.size()
	rec["retries"] = int(ist.get("retries", -1))
	rec["validator_code"] = ""
	rec["validator_detail"] = ""
	if hist.size() > 0:
		var last_h: Dictionary = hist[hist.size() - 1]
		rec["validator_code"] = str(last_h.get("code", ""))
		rec["validator_detail"] = str(last_h.get("detail", "")).left(220)
	rec["consume"] = {}
	if rec["status"] == "READY":
		rec["consume"] = controller.victory_consume_initial(obs, 1)
	var fault: Dictionary = controller.strict_fault()
	rec["fault"] = str(fault.get("code", ""))
	rec["fault_detail"] = str(fault.get("detail", "")).left(220)
	var mgr = controller.get("_manager")
	rec["plan_adopted"] = bool(mgr.vp_has_plan()) if mgr != null else false
	rec["phase_count"] = ((mgr.vp_get_plan() as Dictionary).get("phases", []) as Array).size() if mgr != null and rec["plan_adopted"] else 0
	rec["queue_left"] = (adapter.mock_queue as Array).size()
	rec["production_pass"] = rec["status"] == "READY" and rec["fault"] == "" \
		and bool((rec["consume"] as Dictionary).get("ok", false)) and rec["plan_adopted"] \
		and rec["general_calls"] == 1 and rec["retries"] == 0 and rec["queue_left"] == 0
	controller.queue_free()
	executor.queue_free()
	adapter.queue_free()
	await process_frame
	return rec


func _run() -> void:
	var prev := OS.get_environment("TRAINING_STRICT_CONTRACT")
	OS.set_environment("TRAINING_STRICT_CONTRACT", "1")
	var args := OS.get_cmdline_user_args()
	if args.size() < 2:
		printerr("[ContractSFT] need: -- <in_json> <out_json>")
		quit(2)
		return
	var req: Variant = JSON.parse_string(FileAccess.get_file_as_string(args[0]))
	if not (req is Dictionary):
		printerr("[ContractSFT] bad input JSON")
		quit(2)
		return
	var out: Array = []
	var mode := str((req as Dictionary).get("mode", ""))
	if mode == "prompts":
		for spec in ((req as Dictionary).get("scenarios", []) as Array):
			out.append(_prompt_one(spec))
	elif mode == "validate":
		for item in ((req as Dictionary).get("items", []) as Array):
			out.append(await _validate_one(item))
	else:
		printerr("[ContractSFT] unknown mode %s" % mode)
		quit(2)
		return
	OS.set_environment("TRAINING_STRICT_CONTRACT", prev)
	var f := FileAccess.open(args[1], FileAccess.WRITE)
	f.store_string(JSON.stringify({"mode": mode, "results": out}, "\t"))
	f.close()
	print("[ContractSFT] mode=%s n=%d" % [mode, out.size()])
	quit(0)
