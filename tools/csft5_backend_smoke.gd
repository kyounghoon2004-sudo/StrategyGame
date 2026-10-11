extends SceneTree

## CSFT5 REAL-BACKEND SMOKE (tool-only; no production changes).
##
## One real INITIAL General call through the production path with the REAL
## HTTP adapter (mock_mode OFF) against the local CSFT5 Brain server:
##   Cloud2Adapter.test_connection (real probe) -> TurnController
##   MISSION_HIERARCHY -> _vp_init_fire (production packet + production
##   system prompt) -> HTTP POST -> Cloud2VictoryResponse parse/authoring/
##   canonical validation -> victory_consume_initial (adoption).
## TRAINING_STRICT_CONTRACT=1: no repair, no retry, no fallback.
##
## Usage: godot --headless --path <project> -s res://tools/csft5_backend_smoke.gd -- <out_json> [endpoint]

const SimControllerCls = preload("res://scripts/sim/sim_controller.gd")
const ObsCls = preload("res://scripts/cloud1/cloud1_observation.gd")
const AdapterCls = preload("res://scripts/cloud2/cloud2_adapter.gd")
const ConfigCls = preload("res://scripts/cloud2/cloud2_config.gd")
const TacticalPlanCls = preload("res://scripts/cloud2/cloud2_plan_memory.gd")
const TurnControllerCls = preload("res://scripts/cloud2/cloud2_turn_controller.gd")

class ExecutorStub extends Node:
	signal execution_finished(result: Dictionary)
	var busy := false
	func set_external_busy(v: bool, _reason: String = "") -> void:
		busy = v


func _init() -> void:
	call_deferred("_run")


func _forces() -> Array:
	# Deliberately a roster WITHOUT cavalry (the known R_CAV_1 lure case).
	return [
		{"id": "R_HQ_1", "class": "hq", "faction": "red", "q": 6, "r": 0, "soldiers": 300},
		{"id": "R_INF_1", "class": "infantry", "faction": "red", "q": 3, "r": -1, "soldiers": 450},
		{"id": "R_INF_2", "class": "infantry", "faction": "red", "q": 3, "r": 1, "soldiers": 430},
		{"id": "R_ARC_1", "class": "archer", "faction": "red", "q": 4, "r": 0, "soldiers": 240},
		{"id": "R_SPE_1", "class": "spearman", "faction": "red", "q": 3, "r": 3, "soldiers": 380},
		{"id": "B_HQ_1", "class": "hq", "faction": "blue", "q": -8, "r": 0, "soldiers": 300},
		{"id": "B_INF_1", "class": "infantry", "faction": "blue", "q": 1, "r": 0, "soldiers": 420},
		{"id": "B_CAV_1", "class": "cavalry", "faction": "blue", "q": -3, "r": 4, "soldiers": 280},
	]


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var out_path := args[0] if args.size() > 0 else "user://csft5_smoke.json"
	var endpoint := args[1] if args.size() > 1 else "http://127.0.0.1:8096/v1/chat/completions"
	OS.set_environment("TRAINING_STRICT_CONTRACT", "1")
	var rec := {"endpoint": endpoint, "strict": true, "mock_mode": false}
	var sim: RefCounted = SimControllerCls.new()
	var lr: Dictionary = sim.load_scenario({"scenario_id": "csft5_smoke", "scenario_version": "1.0.0", "seed": 7,
		"mission_contract": {"primary_objective": "destroy_all_red", "turn_limit": 12},
		"map": {"bounds": {"q_min": -12, "q_max": 12, "r_min": -8, "r_max": 8}, "default_terrain": 0,
			"terrain_overrides": {}, "river_cells": []},
		"forces": _forces(), "start_turn": 1})
	rec["scenario_load"] = lr
	var adapter := AdapterCls.new()
	var executor := ExecutorStub.new()
	var controller := TurnControllerCls.new()
	get_root().add_child(adapter)
	get_root().add_child(executor)
	get_root().add_child(controller)
	await process_frame
	var cfg := ConfigCls.new()
	cfg.set_provider("ollama")
	cfg.set_endpoint(endpoint)
	cfg.set_model("csft5")
	cfg.timeout_sec = 300.0
	adapter.mock_mode = false
	# Real connection probe through the production adapter.
	var probe := {}
	adapter.test_finished.connect(func(r: Dictionary) -> void: probe.merge(r, true))
	var started: Dictionary = adapter.test_connection(cfg)
	rec["probe_started"] = started
	var p0 := Time.get_ticks_msec()
	while probe.is_empty() and Time.get_ticks_msec() - p0 < 60000:
		await process_frame
	rec["probe"] = probe
	cfg.mark_test_result(bool(probe.get("ok", false)), "CONNECTED" if bool(probe.get("ok", false)) else "ERROR", "smoke probe")
	rec["validate_for_start"] = cfg.validate_for_start()
	controller.setup(sim, executor, adapter, cfg, TacticalPlanCls.new())
	controller.set_side("red")
	controller.set_control_mode("MISSION_HIERARCHY")
	var obs: Dictionary = ObsCls.build(sim, "red")
	rec["snapshot_id"] = str(obs.get("snapshot_id", ""))
	rec["roster"] = (obs.get("friendly_units", []) as Array).map(func(u): return str((u as Dictionary).get("unit_id", "")))
	var t0 := Time.get_ticks_msec()
	rec["fire"] = controller._vp_init_fire(obs, {"trigger": "INITIAL_PLAN", "reason": "CSFT5 backend smoke.", "turn": 1}, 1)
	var done := {}
	while Time.get_ticks_msec() - t0 < 360000:
		done = controller.victory_poll_initial()
		var st := str(done.get("status", ""))
		if st == "READY" or st == "FAILED":
			break
		await process_frame
	rec["wall_ms"] = Time.get_ticks_msec() - t0
	rec["status"] = str(done.get("status", "TIMEOUT"))
	rec["initial_status"] = controller.victory_initial_status()
	var hist: Array = controller.get_general_history()
	rec["general_calls"] = hist.size()
	if hist.size() > 0:
		var h: Dictionary = hist[hist.size() - 1]
		rec["validator_code"] = str(h.get("code", ""))
		rec["validator_detail"] = str(h.get("detail", "")).left(300)
	rec["consume"] = controller.victory_consume_initial(obs, 1) if rec["status"] == "READY" else {}
	rec["strict_fault"] = controller.strict_fault()
	var mgr = controller.get("_manager")
	rec["plan_adopted"] = bool(mgr.vp_has_plan()) if mgr != null else false
	if rec["plan_adopted"]:
		var vp: Dictionary = mgr.vp_get_plan()
		rec["current_phase_id"] = str(vp.get("current_phase_id", ""))
		rec["phase_ids"] = (vp.get("phases", []) as Array).map(func(p): return str((p as Dictionary).get("phase_id", "")))
	rec["production_pass"] = rec["status"] == "READY" and (rec["strict_fault"] as Dictionary).is_empty() \
		and rec["plan_adopted"] and int(rec.get("general_calls", 0)) == 1
	var f := FileAccess.open(out_path, FileAccess.WRITE)
	f.store_string(JSON.stringify(rec, "\t"))
	f.close()
	print("[CSFT5Smoke] status=%s pass=%s code=%s" % [rec["status"], str(rec["production_pass"]), str(rec.get("validator_code", ""))])
	controller.queue_free()
	executor.queue_free()
	adapter.queue_free()
	await process_frame
	quit(0)
