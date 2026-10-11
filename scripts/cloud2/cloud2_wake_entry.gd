extends SceneTree

## ATTACK-WAKE-SEQUENTIAL Phase B deterministic regression runner.
## Uses authoritative Step3 combat results. Network calls are replaced only
## at the provider boundary by the existing deferred mock adapter; coordinator
## parsing, staging, staleness, adoption, event batching, and UI renderers are
## the production implementations.

const SimControllerCls = preload("res://scripts/sim/sim_controller.gd")
const ObsCls = preload("res://scripts/cloud1/cloud1_observation.gd")
const MissionManagerCls = preload("res://scripts/cloud2/cloud2_mission_manager.gd")
const GeneralPlanCls = preload("res://scripts/cloud2/cloud2_general_plan.gd")
const CoordMenuCls = preload("res://scripts/cloud2/cloud2_coord_menu.gd")
const AdapterCls = preload("res://scripts/cloud2/cloud2_adapter.gd")
const ConfigCls = preload("res://scripts/cloud2/cloud2_config.gd")
const TacticalPlanCls = preload("res://scripts/cloud2/cloud2_plan_memory.gd")
const TurnControllerCls = preload("res://scripts/cloud2/cloud2_turn_controller.gd")
const PanelCls = preload("res://scripts/cloud2/cloud2_panel.gd")
const ModelViewCls = preload("res://scripts/cloud2/cloud2_model_view.gd")

const OUT_DIR := "D:/Game development/.workflow/deliverables/ATTACK-WAKE-SEQUENTIAL"
const OUT_PATH := OUT_DIR + "/verification_wake.json"
const CANARY := "wake_fixture_canary_not_a_real_key"


class ExecutorStub extends Node:
	signal execution_finished(result: Dictionary)
	var busy := false
	func set_external_busy(v: bool, _reason: String = "") -> void:
		busy = v


var _results: Array = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_authoritative_capture_and_pending()
	var keep_batch: Dictionary = await _controller_review_fixture("KEEP", 3)
	_record("WAKE-03", bool(keep_batch.get("ok", false)), keep_batch)
	_test_destroyed()
	_test_blocked()
	_test_calm_and_horizon()
	_record("WAKE-08", bool(keep_batch.get("keep_ok", false)), keep_batch)
	var adjusted: Dictionary = await _controller_review_fixture("ADJUST", 1)
	_record("WAKE-09", bool(adjusted.get("adjust_ok", false)), adjusted)
	var replanned: Dictionary = await _controller_review_fixture("REPLAN", 1)
	_record("WAKE-10", bool(replanned.get("replan_ok", false)), replanned)
	_test_stale()
	_test_in_flight_arrivals()
	var pass_count := 0
	for r_val in _results:
		if str((r_val as Dictionary).get("status", "")) == "pass":
			pass_count += 1
	var report := {
		"suite": "ATTACK_WAKE_SEQUENTIAL_PHASE_B",
		"results": _results,
		"summary": {"passed": pass_count, "total": _results.size(),
			"phase_b_pass": pass_count == 12 and _results.size() == 12},
	}
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	var f := FileAccess.open(OUT_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(report, "\t"))
		f.close()
	print("[WAKE-VERIFY] %d/%d pass -> %s" % [pass_count, _results.size(), OUT_PATH])
	quit(0 if bool((report.get("summary", {}) as Dictionary).get("phase_b_pass", false)) else 1)


func _test_authoritative_capture_and_pending() -> void:
	var sim := _fresh_sim("capture", _pair_forces(1, 420))
	var obs0 := _obs(sim)
	var mgr := _manager_with_plan(obs0)
	var combat: Dictionary = sim.do_attack("B_INF_1", "R_INF_1", "blue")
	var captured: Dictionary = mgr.record_authoritative_combat_event(combat, _obs(sim))
	var events: Array = mgr.get_events()
	var attack_events := events.filter(func(e: Variant) -> bool:
		return e is Dictionary and str((e as Dictionary).get("kind", "")) == "FRIENDLY_UNIT_ATTACKED")
	var evidence := {"combat": _combat_fact(combat), "capture": captured,
		"event_kinds": _event_kinds(events), "wakeup": mgr.wakeup_view()}
	_record("WAKE-01", bool(combat.get("success", false)) and attack_events.size() == 1, evidence)
	var due: Dictionary = mgr.review_due(_obs(sim), 1)
	evidence["review"] = due
	_record("WAKE-02", bool(due.get("requested", false))
		and str(due.get("trigger", "")) == "FRIENDLY_UNIT_ATTACKED"
		and bool((mgr.wakeup_view() as Dictionary).get("review_pending", false)), evidence)


func _test_destroyed() -> void:
	var sim := _fresh_sim("destroyed", _pair_forces(1, 1, 900))
	var obs0 := _obs(sim)
	var mgr := _manager_with_plan(obs0)
	var combat: Dictionary = sim.do_attack("B_INF_1", "R_INF_1", "blue")
	mgr.record_authoritative_combat_event(combat, _obs(sim))
	var due: Dictionary = mgr.review_due(_obs(sim), 1)
	var kinds := _event_kinds(mgr.get_events())
	_record("WAKE-04", bool(combat.get("defender_destroyed", false))
		and "FRIENDLY_UNIT_DESTROYED" in kinds
		and bool(due.get("requested", false)),
		{"combat": _combat_fact(combat), "event_kinds": kinds, "review": due})


func _test_blocked() -> void:
	var forces := [
		{"id": "B_HQ_1", "class": "hq", "faction": "blue", "q": -30, "r": -2, "soldiers": 300},
		{"id": "B_INF_1", "class": "infantry", "faction": "blue", "q": -29, "r": 0, "soldiers": 450},
		{"id": "B_ARC_1", "class": "archer", "faction": "blue", "q": -30, "r": 0, "soldiers": 260},
		{"id": "R_INF_1", "class": "infantry", "faction": "red", "q": -24, "r": 0, "soldiers": 477},
		{"id": "R_INF_2", "class": "infantry", "faction": "red", "q": -23, "r": 0, "soldiers": 400},
		{"id": "R_INF_3", "class": "infantry", "faction": "red", "q": -25, "r": 0, "soldiers": 400},
		{"id": "R_INF_4", "class": "infantry", "faction": "red", "q": -24, "r": 1, "soldiers": 400},
		{"id": "R_INF_5", "class": "infantry", "faction": "red", "q": -24, "r": -1, "soldiers": 400},
		{"id": "R_INF_6", "class": "infantry", "faction": "red", "q": -23, "r": -1, "soldiers": 400},
		{"id": "R_INF_7", "class": "infantry", "faction": "red", "q": -25, "r": 1, "soldiers": 400},
	]
	var sim := _fresh_sim("blocked", forces)
	var obs := _obs(sim)
	var mgr := MissionManagerCls.new()
	var plan := GeneralPlanCls.default_plan(obs, 1)
	plan["missions"] = [
		{"mission_id": "M01", "task": "ADVANCE", "area": "CENTER", "assigned_units": ["R_INF_1"],
			"objective": {"kind": "NONE"}, "engagement": {"policy": "ATTACK_IF_ADVANTAGEOUS"},
			"constraints": {"preserve_force": false, "max_overextension": 3},
			"success_conditions": [], "abort_conditions": [], "report_conditions": []},
		{"mission_id": "M02", "task": "HOLD", "area": "ANY",
			"assigned_units": ["R_INF_2", "R_INF_3", "R_INF_4", "R_INF_5", "R_INF_6", "R_INF_7"]},
	]
	plan["review_conditions"] = []
	plan["review_horizon_turns"] = 9
	var applied := mgr.apply_plan(plan, 1, str(obs.get("snapshot_id", "")), str(obs.get("battle_id", "")))
	var decided: Dictionary = mgr.red_turn(sim, obs)
	var review: Dictionary = decided.get("review", {})
	_record("WAKE-05", bool(applied.get("ok", false))
		and bool(review.get("requested", false))
		and str(review.get("trigger", "")) == "MISSION_BLOCKED",
		{"review": review, "statuses": decided.get("statuses", [])})


func _test_calm_and_horizon() -> void:
	var sim := _fresh_sim("calm", _pair_forces(1, 420))
	var obs := _obs(sim)
	var mgr := _manager_with_plan(obs, 4)
	var calm: Dictionary = mgr.review_due(obs, 1)
	_record("WAKE-06", not bool(calm.get("requested", true)), {"review": calm})
	var late := obs.duplicate(true)
	late["turn"] = 5
	var due: Dictionary = mgr.review_due(late, 5)
	_record("WAKE-07", bool(due.get("requested", false))
		and str(due.get("trigger", "")) == "PERIODIC_HORIZON", {"review": due})


func _test_stale() -> void:
	var sim := _fresh_sim("stale", _pair_forces(1, 420))
	var obs := _obs(sim)
	var mgr := _manager_with_plan(obs)
	var base := MissionManagerCls.review_base_from_obs(obs)
	var late := obs.duplicate(true)
	late["turn"] = int(obs.get("turn", 1)) + 3
	var check: Dictionary = mgr.staged_staleness(mgr.get_plan(), base, late)
	_record("WAKE-11", bool(check.get("stale", false))
		and str(check.get("reason", "")).begins_with("TURN_DRIFT_"), {"staleness": check})


func _test_in_flight_arrivals() -> void:
	var sim := _fresh_sim("inflight", _pair_forces(2, 420))
	var obs0 := _obs(sim)
	var mgr := _manager_with_plan(obs0)
	var first: Dictionary = sim.do_attack("B_INF_1", "R_INF_1", "blue")
	mgr.record_authoritative_combat_event(first, _obs(sim))
	var batch: Dictionary = mgr.review_due(_obs(sim), 1)
	mgr.note_review_started(batch)
	var second: Dictionary = sim.do_attack("B_INF_2", "R_INF_2", "blue")
	mgr.record_authoritative_combat_event(second, _obs(sim))
	var during: Dictionary = mgr.review_due(_obs(sim), 1)
	var ack: Dictionary = mgr.acknowledge_review_events(batch, "KEEP", 1, "KEPT")
	var next: Dictionary = mgr.review_due(_obs(sim), 1)
	_record("WAKE-12", not bool(during.get("requested", true))
		and str(during.get("trigger", "")) == "REVIEW_IN_FLIGHT"
		and int(ack.get("remaining", 0)) == 1
		and bool(next.get("requested", false)),
		{"first_batch": batch, "during": during, "ack": ack, "next": next})


## End-to-end event review through the existing deferred adapter, coordinator
## parser, plan expansion, staging, and pre-execution adoption gate.
func _controller_review_fixture(decision: String, attack_count: int) -> Dictionary:
	var sim := _fresh_sim("controller_%s" % decision.to_lower(), _pair_forces(attack_count, 420))
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
	cfg.mark_test_result(true, "CONNECTED", "wake fixture")
	adapter.mock_mode = true
	controller.setup(sim, executor, adapter, cfg, TacticalPlanCls.new())
	controller.set_control_mode("MISSION_HIERARCHY")
	var obs0 := _obs(sim)
	var mgr: RefCounted = controller.get("_manager") as RefCounted
	var plan := GeneralPlanCls.default_plan(obs0, 1)
	plan["review_conditions"] = []
	plan["review_horizon_turns"] = 9
	var applied: Dictionary = mgr.apply_plan(plan, 1, str(obs0.get("snapshot_id", "")), str(obs0.get("battle_id", "")))
	var menu: Dictionary = mgr.build_coord_menu(obs0)
	var baseline := _default_choices(menu)
	mgr.bind_coordination({"choices": baseline.duplicate(true), "menu_snapshot": str(menu.get("snapshot_id", "")), "turn": 1, "warnings": []})
	for i in range(1, attack_count + 1):
		sim.do_attack("B_INF_%d" % i, "R_INF_%d" % i, "blue")
	var wake_before: Dictionary = mgr.wakeup_view()
	var review_before: Dictionary = mgr.review_due(_obs(sim), 1)
	adapter.mock_queue.append(_review_fixture(decision, menu, baseline))
	var service: Dictionary = await controller._service_event_review_before_red(_obs(sim), 1, true)
	var wake_after: Dictionary = mgr.wakeup_view()
	var plan_after: Dictionary = mgr.get_plan()
	var history: Array = controller.get_general_history()
	var packet: Dictionary = controller.get_general_view().get("last_general_packet", {})
	var packet_events: Array = packet.get("events_since_review", [])
	var last_wake: Dictionary = wake_after.get("last_review", {})
	var summary_text := ModelViewCls.render_summary(history[0]) if history.size() == 1 else ""
	var lab_text := PanelCls.render_general_view(controller.get_general_view())
	var evidence := {
		"decision": decision,
		"initial_apply": applied,
		"review_before": review_before,
		"wake_before": wake_before,
		"service": {"called": bool(service.get("called", false)), "review": service.get("review", {})},
		"history_count": history.size(),
		"mock_queue_remaining": adapter.mock_queue.size(),
		"packet_event_count": packet_events.size(),
		"packet_event_kinds": _event_kinds(packet_events),
		"plan_version_before": int(plan.get("plan_version", 0)),
		"plan_version_after": int(plan_after.get("plan_version", 0)),
		"wake_after": wake_after,
		"model_view_has_provenance": summary_text.contains("event_count") and summary_text.contains("events"),
		"general_lab_has_wake": lab_text.contains("Wake: pending="),
	}
	var common_ok := bool(service.get("called", false)) and history.size() == 1 \
		and adapter.mock_queue.is_empty() and packet_events.size() == attack_count \
		and not bool(wake_after.get("review_pending", true)) \
		and str(last_wake.get("decision", "")) == decision \
		and bool(evidence.get("model_view_has_provenance", false)) \
		and bool(evidence.get("general_lab_has_wake", false))
	evidence["ok"] = common_ok
	evidence["keep_ok"] = common_ok and decision == "KEEP" \
		and int(plan_after.get("plan_version", 0)) == int(plan.get("plan_version", 0)) \
		and str(last_wake.get("status", "")) == "KEPT"
	evidence["adjust_ok"] = common_ok and decision == "ADJUST" \
		and int(plan_after.get("plan_version", 0)) == int(plan.get("plan_version", 0)) + 1 \
		and str(last_wake.get("status", "")) == "ADOPTED"
	evidence["replan_ok"] = common_ok and decision == "REPLAN" \
		and int(plan_after.get("plan_version", 0)) == int(plan.get("plan_version", 0)) + 1 \
		and str(last_wake.get("status", "")) == "ADOPTED"
	controller.queue_free()
	executor.queue_free()
	adapter.queue_free()
	await process_frame
	return evidence


func _review_fixture(decision: String, menu: Dictionary, baseline: Dictionary) -> Dictionary:
	if decision == "KEEP":
		return {"ok": true, "latency_ms": 5, "content_text": JSON.stringify({"decision": "KEEP"})}
	if decision == "ADJUST":
		var change := {}
		for g_val in (menu.get("groups", []) as Array):
			if not g_val is Dictionary:
				continue
			var g: Dictionary = g_val
			var gid := str(g.get("id", ""))
			for o_val in (g.get("options", []) as Array):
				if o_val is Dictionary and str((o_val as Dictionary).get("id", "")) != str(baseline.get(gid, "")):
					change = {"group": gid, "choice": str((o_val as Dictionary).get("id", ""))}
					break
			if not change.is_empty():
				break
		return {"ok": true, "latency_ms": 5,
			"content_text": JSON.stringify({"decision": "ADJUST", "changes": [change]})}
	var assignments: Array = []
	for gid in baseline.keys():
		assignments.append({"group": str(gid), "choice": str(baseline[gid])})
	return {"ok": true, "latency_ms": 5, "content_text": JSON.stringify({
		"decision": "REPLAN", "concept": "FIX_AND_FLANK", "main_effort": "CENTER",
		"doctrine_profile": {"aggression": "STANDARD", "tempo": "STANDARD", "risk": "BALANCED",
			"reserve": "STANDARD", "pursuit": "STANDARD"},
		"assignments": assignments, "review_horizon": 4})}


func _default_choices(menu: Dictionary) -> Dictionary:
	var out := {}
	for g_val in (menu.get("groups", []) as Array):
		if g_val is Dictionary:
			out[str((g_val as Dictionary).get("id", ""))] = CoordMenuCls.default_choice_id(g_val)
	return out


func _manager_with_plan(obs: Dictionary, horizon: int = 9) -> RefCounted:
	var mgr := MissionManagerCls.new()
	var plan := GeneralPlanCls.default_plan(obs, 1)
	plan["review_conditions"] = []
	plan["review_horizon_turns"] = horizon
	mgr.apply_plan(plan, 1, str(obs.get("snapshot_id", "")), str(obs.get("battle_id", "")))
	return mgr


func _pair_forces(count: int, red_soldiers: int, blue_soldiers: int = 360) -> Array:
	var out: Array = []
	for i in range(1, count + 1):
		var r := -6 + (i - 1) * 5
		out.append({"id": "B_INF_%d" % i, "class": "infantry", "faction": "blue",
			"q": -30, "r": r, "soldiers": blue_soldiers})
		out.append({"id": "R_INF_%d" % i, "class": "infantry", "faction": "red",
			"q": -29, "r": r, "soldiers": red_soldiers})
	return out


func _fresh_sim(label: String, forces: Array) -> RefCounted:
	var sim: RefCounted = SimControllerCls.new()
	sim.load_scenario({
		"scenario_id": "wake_%s" % label,
		"scenario_version": "1.0.0",
		"seed": 29,
		"mission_contract": {"primary_objective": "destroy_all_red", "turn_limit": 12},
		"map": {"bounds": {"q_min": -34, "q_max": -14, "r_min": -8, "r_max": 8},
			"default_terrain": 0, "terrain_overrides": {}, "river_cells": []},
		"forces": forces,
		"start_turn": 1,
	})
	return sim


func _obs(sim: RefCounted) -> Dictionary:
	return ObsCls.build(sim, "red")


func _event_kinds(events: Array) -> Array:
	var out: Array = []
	for e_val in events:
		if e_val is Dictionary:
			out.append(str((e_val as Dictionary).get("kind", "")))
	return out


func _combat_fact(result: Dictionary) -> Dictionary:
	return {"success": bool(result.get("success", false)),
		"attacker_id": str(result.get("attacker_id", "")),
		"defender_id": str(result.get("defender_id", "")),
		"attacker_faction": str(result.get("attacker_faction", "")),
		"defender_faction": str(result.get("defender_faction", "")),
		"defender_casualties": int(result.get("defender_casualties", 0)),
		"defender_destroyed": bool(result.get("defender_destroyed", false))}


func _record(id: String, passed: bool, evidence: Dictionary) -> void:
	_results.append({"id": id, "status": "pass" if passed else "fail", "evidence": evidence})
	print("[WAKE-VERIFY][%s] %s" % [id, "PASS" if passed else "FAIL"])
