extends SceneTree

const SimControllerCls = preload("res://scripts/sim/sim_controller.gd")
const ObsCls = preload("res://scripts/cloud1/cloud1_observation.gd")
const AdapterCls = preload("res://scripts/cloud2/cloud2_adapter.gd")
const ConfigCls = preload("res://scripts/cloud2/cloud2_config.gd")
const TacticalPlanCls = preload("res://scripts/cloud2/cloud2_plan_memory.gd")
const TurnControllerCls = preload("res://scripts/cloud2/cloud2_turn_controller.gd")
const ManagerCls = preload("res://scripts/cloud2/cloud2_mission_manager.gd")


class ExecutorStub extends Node:
	signal execution_finished(result: Dictionary)
	var busy := false
	func set_external_busy(v: bool, _reason: String = "") -> void:
		busy = v


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var text := FileAccess.get_file_as_string(args[0])
	var sim: RefCounted = SimControllerCls.new()
	sim.load_scenario({
		"scenario_id": "probe", "scenario_version": "1.0.0", "seed": 29,
		"mission_contract": {"primary_objective": "x", "turn_limit": 12},
		"map": {"bounds": {"q_min": -34, "q_max": -14, "r_min": -8, "r_max": 8},
			"default_terrain": 0, "terrain_overrides": {}, "river_cells": []},
		"forces": [{"id": "R_INF_1", "class": "infantry", "faction": "red", "q": -29, "r": -6, "soldiers": 450}],
		"start_turn": 1})
	var adapter := AdapterCls.new()
	var executor := ExecutorStub.new()
	var controller := TurnControllerCls.new()
	get_root().add_child(adapter)
	get_root().add_child(executor)
	get_root().add_child(controller)
	var cfg := ConfigCls.new()
	cfg.provider_id = "openai"
	cfg.model = "mock"
	cfg.endpoint = "https://mock.local/v1/chat/completions"
	cfg.set_api_key("probe")
	cfg.mark_test_result(true, "CONNECTED", "probe")
	adapter.mock_mode = true
	adapter.mock_queue.append({"ok": true, "latency_ms": 5, "content_text": text})
	controller.setup(sim, executor, adapter, cfg, TacticalPlanCls.new())
	controller.set_side("red")
	controller.set_control_mode("MISSION_HIERARCHY")
	var obs: Dictionary = ObsCls.build(sim, "red")
	controller._vp_init_fire(obs, {"trigger": "INITIAL_PLAN", "reason": "probe", "turn": 1}, 1)
	var last := {}
	for i in range(1200):
		last = controller.victory_poll_initial()
		if str(last.get("status", "")) in ["READY", "FAILED"]:
			break
		await process_frame
	print("PROBE status=", str(last.get("status", "")))
	var hist: Array = controller.get_general_history()
	print("PROBE hist_n=", hist.size())
	if hist.size() > 0:
		print("PROBE hist_keys=", (hist[hist.size() - 1] as Dictionary).keys())
		print("PROBE hist_last=", JSON.stringify(hist[hist.size() - 1]).left(600))
	var mgr = controller.get("_manager")
	print("PROBE has_plan=", mgr.vp_has_plan())
	var vp: Dictionary = mgr.vp_get_plan()
	print("PROBE vp_keys=", vp.keys())
	var phases: Array = vp.get("phases", [])
	print("PROBE n_phases=", phases.size())
	if phases.size() > 0:
		var p0: Dictionary = phases[0]
		print("PROBE p0_keys=", p0.keys())
		var ms: Array = p0.get("missions", [])
		print("PROBE n_missions=", ms.size())
		if ms.size() > 0:
			print("PROBE m0_keys=", (ms[0] as Dictionary).keys())
			print("PROBE m0=", JSON.stringify(ms[0]).left(500))
	print("PROBE status_dict=", JSON.stringify(controller.victory_initial_status()).left(300))
	quit(0)
