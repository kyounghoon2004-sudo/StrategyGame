extends SceneTree

## CLOUD-GENERAL MISSION HIERARCHY — headless HIER-gate runner.
##
## Exit code 0 = all gates pass, 1 = any gate fails. Writes
## verification_hier.json into CLOUD-GENERAL-STEP-02.
##
## Part 1 (sim, no network): plan/mission schemas, General contract,
## controller decisions, utility/doctrine/seeding, contingencies, staleness,
## hypotheses, events, memory, review policy, telemetry, static no-LLM and
## background-purity scans, secret hygiene. Part 2 (live cloud2 scene with
## mock-adapter General fixtures): initial plan through the real transport,
## multi-turn zero-network execution, background review staging, compat
## mode, and memory files. LIVE CLOUD legs are honestly reported BLOCKED.

const SimControllerCls = preload("res://scripts/sim/sim_controller.gd")
const ObsCls = preload("res://scripts/cloud1/cloud1_observation.gd")
const TableCls = preload("res://scripts/cloud1/cloud1_action_table.gd")
const CompilerCls = preload("res://scripts/cloud1/cloud1_compiler.gd")
const ResponseCls = preload("res://scripts/cloud2/cloud2_response.gd")
const MissionCls = preload("res://scripts/cloud2/cloud2_mission.gd")
const PlanCls = preload("res://scripts/cloud2/cloud2_general_plan.gd")
const GeneralPacketCls = preload("res://scripts/cloud2/cloud2_general_packet.gd")
const GeneralResponseCls = preload("res://scripts/cloud2/cloud2_general_response.gd")
const CoordMenuCls = preload("res://scripts/cloud2/cloud2_coord_menu.gd")
const OpportunityCls = preload("res://scripts/cloud2/cloud2_opportunity.gd")
const UtilityCls = preload("res://scripts/cloud2/cloud2_utility.gd")
const MissionControllerCls = preload("res://scripts/cloud2/cloud2_mission_controller.gd")
const MissionManagerCls = preload("res://scripts/cloud2/cloud2_mission_manager.gd")
const MemoryCls = preload("res://scripts/cloud2/cloud2_battle_memory.gd")
const GeneralTraceCls = preload("res://scripts/cloud2/cloud2_general_trace.gd")
const TurnPacketCls = preload("res://scripts/cloud2/cloud2_turn_packet.gd")
const PanelCls = preload("res://scripts/cloud2/cloud2_panel.gd")
const SessionCls = preload("res://scripts/cloud2/cloud2_session.gd")

const DELIVER_DIR := "D:/Game development/.workflow/deliverables/CLOUD-GENERAL-STEP-02"
const VERIFY_PATH := "D:/Game development/.workflow/deliverables/CLOUD-GENERAL-STEP-02/verification_hier.json"
const CLOUD2_SCENE := "res://scenes/cloud2_battle_test.tscn"

const CANARY := "C2_CANARY_KEY_9f8e7d6c5b4a3f2e1d0c"

var _gates: Dictionary = {}
var _live: Node = null
var _sig_phase := {}


func _init() -> void:
	_run()


func _record(gate: String, status: String, evidence: Dictionary) -> void:
	_gates[gate] = {"status": status, "evidence": evidence}
	print("[CLOUDHIER][%s] %s" % [gate, status.to_upper()])


func _exit_code() -> int:
	for key in _gates.keys():
		var st := str((_gates[key] as Dictionary).get("status", ""))
		if st != "pass" and st != "blocked":
			return 1
	return 0


func _base_forces() -> Array:
	return [
		{"id": "B_HQ_1", "class": "hq", "faction": "blue", "q": -28, "r": 0, "soldiers": 300},
		{"id": "B_INF_1", "class": "infantry", "faction": "blue", "q": -25, "r": 0, "soldiers": 450},
		{"id": "B_ARC_1", "class": "archer", "faction": "blue", "q": -27, "r": 0, "soldiers": 260},
		{"id": "R_INF_1", "class": "infantry", "faction": "red", "q": -24, "r": 0, "soldiers": 477},
		{"id": "R_CAV_1", "class": "cavalry", "faction": "red", "q": -26, "r": 1, "soldiers": 320},
		{"id": "R_ARC_1", "class": "archer", "faction": "red", "q": -22, "r": 0, "soldiers": 290},
	]


func _scenario(forces: Array) -> Dictionary:
	return {
		"scenario_id": "cloud_hier_probe",
		"scenario_version": "1.0.0",
		"seed": 11,
		"mission_contract": {"primary_objective": "destroy_all_red", "turn_limit": 6},
		"map": {
			"bounds": {"q_min": -30, "q_max": -20, "r_min": -5, "r_max": 5},
			"default_terrain": 0,
			"terrain_overrides": {},
			"river_cells": [],
		},
		"forces": forces,
		"start_turn": 1,
	}


func _fresh_sim(forces: Array) -> RefCounted:
	var sim: RefCounted = SimControllerCls.new()
	var res: Dictionary = sim.load_scenario(_scenario(forces))
	if not bool(res.get("ok", false)):
		print("[CLOUDHIER] FATAL scenario load failed: %s" % JSON.stringify(res))
	return sim


func _obs(sim: RefCounted) -> Dictionary:
	return ObsCls.build(sim, "red")


func _run() -> void:
	GeneralTraceCls.reset()
	_h1_plan_schema()
	_h2_general_contract()
	_h3_mission_tasks()
	_h4_fix_center()
	_h5_attack_local()
	_h6_reserve_holds()
	_h7_blocked_review()
	_h8_contingency()
	_h9_stale()
	_h10_hypotheses()
	_h11_events()
	_h12_memory()
	_h13_context_delta()
	_h14_review_policy()
	_h15_controller_no_llm()
	_h16_doctrine_utility()
	_h17_telemetry()
	_h18_flank_cav()
	_h19_background_purity()
	_h20_secret_hygiene()
	_h25_coverage()
	_h26_estimate_posture()
	_h27_packet_versioning()
	await _live_part()
	_write_and_quit(_exit_code())


# --- H1: strategic plan schema -------------------------------------------------

func _h1_plan_schema() -> void:
	var ev := {}
	var sim := _fresh_sim(_base_forces())
	var obs := _obs(sim)
	var plan := PlanCls.default_plan(obs, 1)
	ev["default_missions"] = (plan.get("missions", []) as Array).size()
	ev["default_source"] = str(plan.get("source", ""))
	var checked := PlanCls.validate_plan(plan, {"turn": 1, "snapshot_id": str(obs.get("snapshot_id", ""))})
	ev["validates"] = bool(checked.get("ok", false))
	var bad_doctrine := plan.duplicate(true)
	bad_doctrine["doctrine"] = {"aggression": 9.9, "risk_tolerance": -3.0}
	var clamped := PlanCls.validate_plan(bad_doctrine, {"turn": 1})
	var dd: Dictionary = (clamped.get("plan", {}) as Dictionary).get("doctrine", {})
	ev["clamped"] = [float(dd.get("aggression", -1.0)), float(dd.get("risk_tolerance", -1.0))]
	var empty := PlanCls.validate_plan({"missions": []}, {})
	ev["empty_rejected"] = str(empty.get("code", ""))
	var m1 := MissionCls.default_mission("M01", "FIX")
	var dup := plan.duplicate(true)
	dup["missions"] = [m1, MissionCls.default_mission("M01", "HOLD")]
	ev["dup_rejected"] = str(PlanCls.validate_plan(dup, {}).get("code", ""))
	var ok := (plan.get("missions", []) as Array).size() >= 2 \
		and bool(checked.get("ok", false)) \
		and float(dd.get("aggression", -1.0)) == 1.0 and float(dd.get("risk_tolerance", -1.0)) == 0.0 \
		and str(empty.get("code", "")) == "PLAN_EMPTY" \
		and str(PlanCls.validate_plan(dup, {}).get("code", "")) == "PLAN_DUP_MISSION"
	_record("h1_plan_schema", "pass" if ok else "fail", ev)


# --- H2: General output contract -----------------------------------------------

func _general_fixture(missions: Array) -> Dictionary:
	return {
		"concept": {"objective": "Fix center, scout flanks", "intent": "Pressure while observing", "main_effort": "CENTER", "risk_posture": "BALANCED"},
		"doctrine": {"aggression": 0.6, "risk_tolerance": 0.5, "tempo": 0.5, "pursuit": 0.4, "reserve_discipline": 0.6, "deception": 0.2},
		"missions": missions,
		"contingencies": [],
		"opponent_hypotheses": [{"hypothesis": "CENTER_BREAKTHROUGH", "confidence": 0.52, "evidence": ["infantry massed center"]}],
		"review_conditions": ["MISSION_BLOCKED"],
		"review_horizon_turns": 4,
	}


func _h2_general_contract() -> void:
	var ev := {}
	var missions := [
		{"mission_id": "M01", "task": "FIX", "area": "CENTER", "assigned_units": ["R_INF_1", "R_ARC_1"],
			"objective": {"kind": "REGION", "region": "CENTER"}, "engagement": {"policy": "ATTACK_IF_ADVANTAGEOUS"},
			"constraints": {"preserve_force": false, "max_overextension": 3}},
		{"mission_id": "M02", "task": "RECON", "area": "ANY", "assigned_units": ["R_CAV_1"]},
	]
	var good := GeneralResponseCls.parse(JSON.stringify(_general_fixture(missions)),
		{"turn": 1, "snapshot_id": "snap_1", "plan_version": 1})
	ev["good_ok"] = bool(good.get("ok", false))
	ev["good_missions"] = ((good.get("plan", {}) as Dictionary).get("missions", []) as Array).size()
	ev["echo_ok"] = GeneralResponseCls.parse(JSON.stringify({"concept": {}, "doctrine": {}, "missions": missions, "snapshot_id": "snap_1"}),
		{"turn": 1, "snapshot_id": "snap_1"}).get("ok", false)
	var stale := GeneralResponseCls.parse(JSON.stringify({"concept": {}, "doctrine": {}, "missions": missions, "snapshot_id": "snap_old"}),
		{"turn": 1, "snapshot_id": "snap_1"})
	ev["stale_code"] = str(stale.get("code", ""))
	var bad_task := GeneralResponseCls.parse(JSON.stringify(_general_fixture(
		[{"mission_id": "M01", "task": "TELEPORT", "assigned_units": ["R_INF_1"]}])))
	ev["bad_task_code"] = str(bad_task.get("code", ""))
	var bad_trig := _general_fixture(missions)
	bad_trig["review_conditions"] = ["INVADE_MOON"]
	ev["bad_trigger_code"] = str(GeneralResponseCls.parse(JSON.stringify(bad_trig)).get("code", ""))
	ev["empty_code"] = str(GeneralResponseCls.parse("").get("code", ""))
	ev["garbage_code"] = str(GeneralResponseCls.parse("not json at all").get("code", ""))
	# The General outputs StrategicPlan only: a tactical orders-shaped reply
	# (legacy direct-control semantics) must reject, never parse as a plan.
	var tactical := GeneralResponseCls.parse(JSON.stringify({
		"plan": {"objective": "o", "intent": "i", "reconsider_if": "r"},
		"orders": [TableCls.make_command("HOLD", TableCls.scope_all_friendly())]}))
	ev["tactical_code"] = str(tactical.get("code", ""))
	var ok := bool(good.get("ok", false)) \
		and ((good.get("plan", {}) as Dictionary).get("missions", []) as Array).size() == 2 \
		and bool(GeneralResponseCls.parse(JSON.stringify({"concept": {}, "doctrine": {}, "missions": missions, "snapshot_id": "snap_1"}),
			{"turn": 1, "snapshot_id": "snap_1"}).get("ok", false)) \
		and str(stale.get("code", "")) == "STALE_SNAPSHOT" \
		and str(bad_task.get("code", "")) == "MISSION_TASK" \
		and str(GeneralResponseCls.parse(JSON.stringify(bad_trig)).get("code", "")) == "MISSION_CONDITION" \
		and str(GeneralResponseCls.parse("").get("code", "")) == "INVALID_JSON" \
		and str(GeneralResponseCls.parse("not json at all").get("code", "")) == "INVALID_JSON" \
		and str(tactical.get("code", "")) == "INVALID_SCHEMA"
	_record("h2_general_contract", "pass" if ok else "fail", ev)


# --- H3: mission task coverage ---------------------------------------------------

func _h3_mission_tasks() -> void:
	var ev := {}
	var validated: Array = []
	for t in MissionCls.TASKS:
		var m := MissionCls.default_mission("MX", str(t))
		m["assigned_units"] = ["R_INF_1"]
		validated.append(str(t) if bool(MissionCls.validate_mission(m).get("ok", false)) else "FAIL:" + str(t))
	ev["tasks"] = validated
	ev["statuses"] = MissionCls.STATUSES
	var wait := MissionCls.default_mission("MW", "RESERVE")
	wait["assigned_units"] = ["R_CAV_1"]
	wait["status"] = "WAITING_TRIGGER"
	ev["waiting_ok"] = str(MissionCls.validate_mission(wait).get("mission", {}).get("status", ""))
	var ok := validated.size() == 8 and not " ".join(validated).contains("FAIL") \
		and MissionCls.STATUSES.size() == 8 \
		and str(MissionCls.validate_mission(wait).get("mission", {}).get("status", "")) == "WAITING_TRIGGER"
	_record("h3_mission_tasks", "pass" if ok else "fail", ev)


# --- H4: scenario A — FIX center -------------------------------------------------

func _h4_fix_center() -> void:
	var ev := {}
	var sim := _fresh_sim(_base_forces())
	var obs := _obs(sim)
	var fp0 := str(sim.fingerprint())
	var m := MissionCls.default_mission("M01", "FIX")
	m["area"] = "CENTER"
	m["assigned_units"] = ["R_INF_1", "R_CAV_1"]
	m["objective"] = {"kind": "REGION", "region": "CENTER"}
	var ctrl := MissionControllerCls.new()
	ctrl.setup(m, PlanCls.default_doctrine(), 11)
	var res: Dictionary = ctrl.decide(sim, obs, {"turn": 1, "snapshot_id": str(obs.get("snapshot_id", "")),
		"turns_active": 0, "urgency": 0.0, "bounds": sim.map_bounds()})
	var fp1 := str(sim.fingerprint())
	ev["fingerprint_stable"] = fp0 == fp1
	var cmd: Dictionary = res.get("command", {})
	ev["action"] = str(cmd.get("action", ""))
	ev["status_hint"] = str(res.get("status_hint", ""))
	var gate := ResponseCls.check_order(cmd, {"acting_side": "RED"})
	ev["gate_ok"] = bool(gate.get("ok", false))
	var dry: Dictionary = CompilerCls.plan(sim, cmd, "", "red") if not cmd.is_empty() else {}
	ev["dry_ok"] = bool(dry.get("ok", false))
	ev["candidates"] = ((res.get("trace", {}) as Dictionary).get("candidates", []) as Array).size()
	var ok := fp0 == fp1 and not cmd.is_empty() and bool(gate.get("ok", false)) \
		and bool(dry.get("ok", false)) and str(res.get("status_hint", "")) == "ACTIVE"
	_record("h4_fix_center", "pass" if ok else "fail", ev)


# --- H5: local ATTACK opportunity -------------------------------------------------

func _h5_attack_local() -> void:
	var ev := {}
	var sim := _fresh_sim(_base_forces())
	var obs := _obs(sim)
	var m := MissionCls.default_mission("M01", "ATTACK")
	m["assigned_units"] = ["R_INF_1"]
	var ctrl := MissionControllerCls.new()
	ctrl.setup(m, PlanCls.default_doctrine(), 11)
	var res: Dictionary = ctrl.decide(sim, obs, {"turn": 1, "snapshot_id": str(obs.get("snapshot_id", "")),
		"turns_active": 1, "urgency": 0.0, "bounds": sim.map_bounds()})
	# Six-option architecture: attack opportunities surface as unmasked,
	# dry-run ATTACK options inside the acting unit's six slots.
	var feasible_attacks: Array = []
	for t_val in ((res.get("trace", {}) as Dictionary).get("units", []) as Array):
		for o_val in ((t_val as Dictionary).get("options", []) as Array):
			var o: Dictionary = o_val
			if str(o.get("kind", "")) == "ATTACK" and not bool(o.get("masked", true)) and bool(o.get("dry_ok", false)):
				feasible_attacks.append("%s:%s>%s" % [str((t_val as Dictionary).get("unit_id", "?")),
					str(o.get("option_id", "?")), str(o.get("resolved_target", "?"))])
	ev["feasible_attacks"] = feasible_attacks
	# Mechanically: overwhelming attack features must win selection outright.
	var atk := UtilityCls.score_candidate("ATTACK",
		{"kill": 1.0, "loss": 0.0, "matchup_edge": 1.0, "pressure": 1.0, "designated": 1.0,
			"class_match": 1.0, "advantage": 1.0, "preserve": 0.0, "overextension": 0.0},
		{"aggression": 1.0}, UtilityCls.default_weights())
	var hold := UtilityCls.score_candidate("HOLD",
		{"defense": 0.0, "mission_fit": 0.0, "opportunity": 1.0},
		{"reserve_discipline": 0.0, "tempo": 1.0}, UtilityCls.default_weights())
	ev["scores"] = [float(atk.get("score", 0.0)), float(hold.get("score", 0.0))]
	var pick := UtilityCls.pick_best([{"score": float(atk.get("score", 0.0))}, {"score": float(hold.get("score", 0.0))}], 1234)
	ev["pick"] = [int(pick.get("index", -1)), bool(pick.get("rolled", true))]
	var ok := not feasible_attacks.is_empty() \
		and float(atk.get("score", 0.0)) > float(hold.get("score", 0.0)) \
		and int(pick.get("index", -1)) == 0 and not bool(pick.get("rolled", true))
	_record("h5_attack_local", "pass" if ok else "fail", ev)


# --- H6: scenario C — RESERVE holds -------------------------------------------------

func _h6_reserve_holds() -> void:
	var ev := {}
	var sim := _fresh_sim(_base_forces())
	var obs := _obs(sim)
	var m := MissionCls.default_mission("M03", "RESERVE")
	m["assigned_units"] = ["R_INF_1"]
	m["engagement"] = {"policy": "HOLD_FIRE"}
	var ctrl := MissionControllerCls.new()
	ctrl.setup(m, PlanCls.default_doctrine(), 11)
	var res: Dictionary = ctrl.decide(sim, obs, {"turn": 1, "snapshot_id": str(obs.get("snapshot_id", "")),
		"turns_active": 0, "urgency": 0.0, "bounds": sim.map_bounds()})
	var cmd: Dictionary = res.get("command", {})
	ev["action"] = str(cmd.get("action", ""))
	var attack_rows := 0
	for c_val in ((res.get("trace", {}) as Dictionary).get("candidates", []) as Array):
		if str((c_val as Dictionary).get("kind", "")) == "ATTACK":
			attack_rows += 1
	ev["attack_rows"] = attack_rows
	var ok := str(cmd.get("action", "")) == "HOLD" and attack_rows == 0
	_record("h6_reserve_holds", "pass" if ok else "fail", ev)


# --- H7: scenario D — BLOCKED mission requests review --------------------------------

func _surround_forces() -> Array:
	return [
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


func _h7_blocked_review() -> void:
	var ev := {}
	var sim := _fresh_sim(_surround_forces())
	var obs := _obs(sim)
	var mgr := MissionManagerCls.new()
	var plan := {
		"plan_version": 1, "based_on_snapshot": str(obs.get("snapshot_id", "")),
		"created_turn": 1, "last_review_turn": 1,
		"mission": {"type": "probe", "objective": "probe"},
		"concept": {"objective": "o", "intent": "i", "main_effort": "CENTER", "risk_posture": "BALANCED"},
		"doctrine": PlanCls.default_doctrine(),
		"missions": [
			{"mission_id": "M01", "task": "ADVANCE", "area": "CENTER", "assigned_units": ["R_INF_1"],
				"objective": {"kind": "NONE"}, "engagement": {"policy": "ATTACK_IF_ADVANTAGEOUS"},
				"constraints": {"preserve_force": false, "max_overextension": 3},
				"success_conditions": [], "abort_conditions": [], "report_conditions": []},
			{"mission_id": "M02", "task": "HOLD", "area": "ANY",
				"assigned_units": ["R_INF_2", "R_INF_3", "R_INF_4", "R_INF_5", "R_INF_6", "R_INF_7"]},
		],
		"contingencies": [], "opponent_hypotheses": [], "review_conditions": [],
		"review_horizon_turns": 9, "source": "general",
	}
	var applied := mgr.apply_plan(plan, 1, str(obs.get("snapshot_id", "")), str(obs.get("battle_id", "")))
	ev["applied"] = bool(applied.get("ok", false))
	var decided: Dictionary = mgr.red_turn(sim, obs)
	var statuses: Array = decided.get("statuses", [])
	ev["statuses"] = MissionManagerCls.render_statuses(statuses)
	var m1 := {}
	for s_val in statuses:
		if str((s_val as Dictionary).get("mission_id", "")) == "M01":
			m1 = s_val
	ev["m1"] = m1
	var review: Dictionary = decided.get("review", {})
	ev["review"] = review
	var ok := bool(applied.get("ok", false)) and str(m1.get("status", "")) == "BLOCKED" \
		and bool(review.get("requested", false)) and str(review.get("trigger", "")) == "MISSION_BLOCKED"
	_record("h7_blocked_review", "pass" if ok else "fail", ev)


# --- H8: scenario E — contingency without LLM ----------------------------------------

func _h8_contingency() -> void:
	var ev := {}
	var sim := _fresh_sim(_base_forces())
	var obs := _obs(sim)
	var mgr := MissionManagerCls.new()
	var plan := {
		"plan_version": 1, "based_on_snapshot": str(obs.get("snapshot_id", "")),
		"created_turn": 1, "last_review_turn": 1,
		"mission": {"type": "probe", "objective": "probe"},
		"concept": {"objective": "o", "intent": "i", "main_effort": "CENTER", "risk_posture": "BALANCED"},
		"doctrine": PlanCls.default_doctrine(),
		"missions": [
			{"mission_id": "M01", "task": "FIX", "area": "CENTER", "assigned_units": ["R_INF_1"]},
			{"mission_id": "M02", "task": "FLANK", "area": "SOUTH", "assigned_units": ["R_CAV_1"], "status": "WAITING_TRIGGER"},
		],
		"contingencies": [
			{"contingency_id": "C1", "trigger": "ENEMY_COMMITMENT_HIGH",
				"params": {"region": "CENTER", "threshold": 1},
				"action": "ACTIVATE_MISSION", "mission_id": "M02", "note": "flank on commitment"},
		],
		"opponent_hypotheses": [], "review_conditions": [],
		"review_horizon_turns": 9, "source": "general",
	}
	mgr.apply_plan(plan, 1, str(obs.get("snapshot_id", "")), str(obs.get("battle_id", "")))
	var decided: Dictionary = mgr.red_turn(sim, obs)
	var m2 := {}
	for s_val in (decided.get("statuses", []) as Array):
		if str((s_val as Dictionary).get("mission_id", "")) == "M02":
			m2 = s_val
	ev["m2"] = m2
	ev["contingency"] = (mgr.get_plan().get("contingencies", []) as Array)
	var ok := str(m2.get("status", "")) in ["ASSIGNED", "ACTIVE", "PROGRESSING"] \
		and bool((mgr.get_plan().get("contingencies", []) as Array)[0].get("consumed", false)) \
		and str(m2.get("reason", "")).begins_with("CONTINGENCY_C1")
	_record("h8_contingency", "pass" if ok else "fail", ev)


# --- H9: scenario F — stale plan protection -----------------------------------------

func _h9_stale() -> void:
	var ev := {}
	var sim := _fresh_sim(_base_forces())
	var obs := _obs(sim)
	var mgr := MissionManagerCls.new()
	var base := MissionManagerCls.review_base_from_obs(obs)
	var staged := PlanCls.default_plan(obs, 1)
	staged["based_on_snapshot"] = str(base.get("snapshot_id", ""))
	ev["fresh"] = mgr.staged_staleness(staged, base, obs)
	var drifted := obs.duplicate(true)
	drifted["turn"] = int(obs.get("turn", 0)) + 3
	ev["drifted"] = mgr.staged_staleness(staged, base, drifted)
	var ghost_base := base.duplicate(true)
	ghost_base["red_ids"] = (base.get("red_ids", []) as Array).duplicate(true) + ["R_GHOST_1"]
	ev["ghost"] = mgr.staged_staleness(staged, ghost_base, obs)
	var applied := mgr.apply_plan(PlanCls.default_plan(obs, 1), 1, str(obs.get("snapshot_id", "")), str(obs.get("battle_id", "")))
	ev["apply_version"] = int(applied.get("version", 0))
	var ok := not bool((mgr.staged_staleness(staged, base, obs) as Dictionary).get("stale", true)) \
		and str((mgr.staged_staleness(staged, base, drifted) as Dictionary).get("reason", "")).begins_with("TURN_DRIFT") \
		and str((mgr.staged_staleness(staged, ghost_base, obs) as Dictionary).get("reason", "")).begins_with("ROSTER_CHANGED") \
		and bool(applied.get("ok", false)) and int(applied.get("version", 0)) == 1
	_record("h9_stale", "pass" if ok else "fail", ev)


# --- H10: opponent hypotheses --------------------------------------------------------

func _h10_hypotheses() -> void:
	var ev := {}
	var sim := _fresh_sim(_base_forces())
	var obs := _obs(sim)
	var mgr := MissionManagerCls.new()
	var plan := PlanCls.default_plan(obs, 1)
	plan["opponent_hypotheses"] = [
		{"hypothesis": "CENTER_BREAKTHROUGH", "confidence": 0.52, "evidence": ["massed center"]},
		{"hypothesis": "SOUTH_FLANK", "confidence": 0.31, "evidence": []},
	]
	mgr.apply_plan(plan, 1, str(obs.get("snapshot_id", "")), str(obs.get("battle_id", "")))
	mgr.note_evidence("CENTER_BREAKTHROUGH", "infantry advanced")
	mgr.note_evidence("CENTER_BREAKTHROUGH", "second wave observed")
	var hyps := (mgr.get_plan().get("opponent_hypotheses", []) as Array)
	ev["hypotheses"] = hyps
	var ok := hyps.size() == 2 \
		and float((hyps[0] as Dictionary).get("confidence", 0.0)) > float((hyps[1] as Dictionary).get("confidence", 0.0)) \
		and ((hyps[0] as Dictionary).get("evidence", []) as Array).size() == 3
	_record("h10_hypotheses", "pass" if ok else "fail", ev)


# --- H11: bounded factual event stream -------------------------------------------------

func _h11_events() -> void:
	var ev := {}
	var sim := _fresh_sim(_base_forces())
	var obs := _obs(sim)
	var mgr := MissionManagerCls.new()
	var decided: Dictionary = mgr.red_turn(sim, obs)
	var events := mgr.get_events()
	ev["event_count"] = events.size()
	var kinds := {}
	for e_val in events:
		kinds[str((e_val as Dictionary).get("kind", "?"))] = true
	ev["kinds"] = kinds.keys()
	ev["orders"] = (decided.get("orders", []) as Array).size()
	var ok := events.size() > 0 and events.size() <= 64 \
		and kinds.has("RED_TURN") and (decided.get("orders", []) as Array).size() >= 1
	_record("h11_events", "pass" if ok else "fail", ev)


# --- H12: battle memory + Godot-wins -----------------------------------------------------

func _h12_memory() -> void:
	var ev := {}
	var sim := _fresh_sim(_base_forces())
	var obs := _obs(sim)
	var bid := str(obs.get("battle_id", ""))
	var plan := PlanCls.default_plan(obs, 1)
	var missions: Array = plan.get("missions", [])
	(missions[0] as Dictionary)["assigned_units"] = ((missions[0] as Dictionary).get("assigned_units", []) as Array) + ["R_GHOST_1"]
	var ghost_only := MissionCls.default_mission("MG", "HOLD")
	ghost_only["assigned_units"] = ["R_GHOST_2"]
	missions.append(ghost_only)
	var rec := PlanCls.reconcile(plan, obs)
	ev["corrections"] = rec.get("corrections", [])
	var mg_status := ""
	for m_val in (((rec.get("plan", {}) as Dictionary).get("missions", [])) as Array):
		if str((m_val as Dictionary).get("mission_id", "")) == "MG":
			mg_status = str((m_val as Dictionary).get("status", ""))
	ev["ghost_status"] = mg_status
	var saved := MemoryCls.save_all(bid, (obs.get("mission", {}) as Dictionary).duplicate(true),
		rec.get("plan", {}), [], {"turn": 1}, [{"turn": 1, "kind": "PROBE", "detail": {}}])
	ev["saved"] = saved
	var loaded := MemoryCls.load_plan(bid)
	ev["loaded"] = bool(loaded.get("ok", false))
	var ok := (rec.get("corrections", []) as Array).size() >= 2 and mg_status == "ABORTED" \
		and bool(saved.get("ok", false)) and bool(loaded.get("ok", false))
	_record("h12_memory", "pass" if ok else "fail", ev)


# --- H13: context uses summary + delta ----------------------------------------------------

func _h13_context_delta() -> void:
	var ev := {}
	var sim := _fresh_sim(_base_forces())
	var obs := _obs(sim)
	var mgr := MissionManagerCls.new()
	mgr.red_turn(sim, obs)
	var gpacket := mgr.build_review_packet(obs, {"trigger": "MANUAL", "reason": "probe", "turn": 1})
	var shape := GeneralPacketCls.validate_shape(gpacket)
	ev["shape_ok"] = bool(shape.get("ok", false))
	var gtext := JSON.stringify(gpacket)
	var mem: RefCounted = load("res://scripts/cloud2/cloud2_plan_memory.gd").new()
	var catalog := TableCls.build_catalog(obs)
	var tactical := TurnPacketCls.build(obs, catalog, mem.to_packet(), {})
	var ttext := JSON.stringify(tactical)
	ev["general_chars"] = gtext.length()
	ev["tactical_chars"] = ttext.length()
	ev["events_capped"] = (gpacket.get("events_since_review", []) as Array).size()
	var ok := bool(shape.get("ok", false)) \
		and gpacket.has("current_plan") and gpacket.has("compact_state") \
		and not gpacket.has("turn_history") and not gpacket.has("orders_history") \
		and (gpacket.get("events_since_review", []) as Array).size() <= 24 \
		and gtext.length() < ttext.length()
	_record("h13_context_delta", "pass" if ok else "fail", ev)


# --- H14: review policy ---------------------------------------------------------------------

func _h14_review_policy() -> void:
	var ev := {}
	var sim := _fresh_sim(_base_forces())
	var obs := _obs(sim)
	var mgr := MissionManagerCls.new()
	ev["no_plan"] = mgr.review_due(obs, 1)
	mgr.red_turn(sim, obs) # adopts local fallback, last_review_turn=1
	var calm := obs.duplicate(true)
	calm["turn"] = 2
	ev["calm"] = mgr.review_due(calm, 2)
	var late := obs.duplicate(true)
	late["turn"] = 6
	ev["late"] = mgr.review_due(late, 6)
	var ok := bool((ev["no_plan"] as Dictionary).get("requested", false)) \
		and str((ev["no_plan"] as Dictionary).get("trigger", "")) == "NO_PLAN" \
		and not bool((ev["calm"] as Dictionary).get("requested", true)) \
		and str((ev["late"] as Dictionary).get("trigger", "")) == "PERIODIC_HORIZON"
	_record("h14_review_policy", "pass" if ok else "fail", ev)


# --- H15: controller calls no LLM --------------------------------------------------------------

func _h15_controller_no_llm() -> void:
	var ev := {}
	var toks := ["HTTPRequest", "request_turn", "request_chat", "api_key", "API_KEY", "Authorization"]
	var hits: Array = []
	for path in ["res://scripts/cloud2/cloud2_mission_controller.gd",
		"res://scripts/cloud2/cloud2_mission_manager.gd",
		"res://scripts/cloud2/cloud2_utility.gd",
		"res://scripts/cloud2/cloud2_opportunity.gd",
		"res://scripts/cloud2/cloud2_class_option.gd",
		"res://scripts/cloud2/cloud2_class_option_solver.gd"]:
		var text := _read_text(path)
		for tok in toks:
			if text.find(tok) != -1:
				hits.append("%s:%s" % [path.get_file(), tok])
	ev["hits"] = hits
	_record("h15_controller_no_llm", "pass" if hits.is_empty() else "fail", ev)


# --- H16: doctrine influence + seeded reproducibility --------------------------------------------

func _h16_doctrine_utility() -> void:
	var ev := {}
	var feat := {"kill": 0.4, "loss": 0.2, "matchup_edge": 0.3, "pressure": 0.5, "designated": 0.0,
		"class_match": 0.0, "advantage": 0.5, "preserve": 0.0, "overextension": 0.0}
	var w := UtilityCls.default_weights()
	var calm := UtilityCls.score_candidate("ATTACK", feat, {"aggression": 0.0}, w)
	var bold := UtilityCls.score_candidate("ATTACK", feat, {"aggression": 1.0}, w)
	ev["scores"] = [float(calm.get("score", 0.0)), float(bold.get("score", 0.0))]
	var scored := [{"score": 82.0}, {"score": 79.0}, {"score": 27.0}]
	var p1 := UtilityCls.pick_best(scored, 424242)
	var p2 := UtilityCls.pick_best(scored, 424242)
	var far := UtilityCls.pick_best([{"score": 91.0}, {"score": 20.0}], 424242)
	ev["picks"] = [int(p1.get("index", -9)), int(p2.get("index", -9)), bool(p1.get("rolled", false)), bool(far.get("rolled", true))]
	var seed_a := MissionControllerCls.tie_seed(11, "snap", "M01", 3)
	var seed_b := MissionControllerCls.tie_seed(11, "snap", "M01", 3)
	ev["seeds"] = [seed_a, seed_b]
	var ok := float(bold.get("score", 0.0)) > float(calm.get("score", 0.0)) \
		and int(p1.get("index", -1)) == int(p2.get("index", -1)) \
		and int(p1.get("index", -1)) in [0, 1] and bool(p1.get("rolled", false)) \
		and not bool(far.get("rolled", true)) and int(far.get("index", -1)) == 0 \
		and seed_a == seed_b
	_record("h16_doctrine_utility", "pass" if ok else "fail", ev)


# --- H17: telemetry ------------------------------------------------------------------------

func _h17_telemetry() -> void:
	var ev := {}
	GeneralTraceCls.reset()
	GeneralTraceCls.note_general_call(1200, "INITIAL_PLAN", 1)
	GeneralTraceCls.note_general_disposition("APPLIED", 1, "snap")
	GeneralTraceCls.note_red_turn(true, 3)
	GeneralTraceCls.note_red_turn(false, 3)
	GeneralTraceCls.note_red_turn(false, 2)
	var s := GeneralTraceCls.snapshot()
	ev["snapshot"] = s
	var ok := int(s["general_calls"]) == 1 and int(s["average_general_latency_ms"]) == 1200 \
		and int(s["turns_without_llm"]) == 2 and int(s["turns_with_llm"]) == 1 \
		and int(s["controller_decisions"]) == 8 and int(s["plans_applied"]) == 1 \
		and absf(float(s["general_calls_per_10_turns"]) - 3.33) < 0.001
	_record("h17_telemetry", "pass" if ok else "fail", ev)
	GeneralTraceCls.reset()


# --- H18: scenario B — cavalry flank ----------------------------------------------------------

func _h18_flank_cav() -> void:
	var ev := {}
	var sim := _fresh_sim(_base_forces())
	var obs := _obs(sim)
	var m := MissionCls.default_mission("M02", "FLANK")
	m["area"] = "SOUTH"
	m["assigned_units"] = ["R_CAV_1"]
	m["objective"] = {"kind": "ENEMY_FORMATION", "unit_id": "B_INF_1"}
	var ctrl := MissionControllerCls.new()
	ctrl.setup(m, PlanCls.default_doctrine(), 11)
	var res: Dictionary = ctrl.decide(sim, obs, {"turn": 1, "snapshot_id": str(obs.get("snapshot_id", "")),
		"turns_active": 0, "urgency": 0.0, "bounds": sim.map_bounds()})
	var cmd: Dictionary = res.get("command", {})
	ev["action"] = str(cmd.get("action", ""))
	ev["chosen"] = str((res.get("trace", {}) as Dictionary).get("chosen", ""))
	var gate := ResponseCls.check_order(cmd, {"acting_side": "RED"})
	var full: Dictionary = CompilerCls.execute(sim, (gate.get("order", {}) as Dictionary), "", "red") if bool(gate.get("ok", false)) else {}
	ev["exec_status"] = str(full.get("execution_status", ""))
	ev["executed"] = (full.get("executed_units", []) as Array).size()
	var ok := bool(gate.get("ok", false)) and str(full.get("execution_status", "")) in ["EXECUTED", "PARTIAL"] \
		and (full.get("executed_units", []) as Array).size() >= 1
	_record("h18_flank_cav", "pass" if ok else "fail", ev)


# --- H19: background review cannot mutate ----------------------------------------------------------

func _h19_background_purity() -> void:
	var ev := {}
	var text := _read_text("res://scripts/cloud2/cloud2_turn_controller.gd")
	var fire := _fn_body(text, "func _fire_background_review(")
	var collect := _fn_body(text, "func _collect_background_review(")
	var decide := _fn_body(text, "func _collect_background_decision(")
	ev["fire_chars"] = fire.length()
	ev["collect_chars"] = collect.length()
	ev["decide_chars"] = decide.length()
	var mutating := ["apply_plan", ".execute(", "post_turn(", "do_move", "do_attack", "do_hold", "notify_mutation"]
	var hits: Array = []
	for tok in mutating:
		if fire.find(tok) != -1:
			hits.append("fire:" + tok)
		if collect.find(tok) != -1:
			hits.append("collect:" + tok)
		if decide.find(tok) != -1:
			hits.append("decide:" + tok)
	ev["hits"] = hits
	ev["collect_stages"] = collect.find("_staged_plan = ") != -1 or decide.find("_staged_plan = ") != -1
	var ok := hits.is_empty() and not fire.is_empty() and not collect.is_empty() \
		and not decide.is_empty() and bool(ev["collect_stages"])
	_record("h19_background_purity", "pass" if ok else "fail", ev)


func _fn_body(text: String, marker: String) -> String:
	var a := text.find(marker)
	if a == -1:
		return ""
	var next := text.find("\nfunc ", a + 1)
	if next == -1:
		return text.substr(a)
	return text.substr(a, next - a)


# --- H20: secret hygiene for new paths --------------------------------------------------------------

func _h20_secret_hygiene() -> void:
	var ev := {}
	var sim := _fresh_sim(_base_forces())
	var obs := _obs(sim)
	var mgr := MissionManagerCls.new()
	mgr.red_turn(sim, obs)
	var packet := mgr.build_review_packet(obs, {"trigger": "MANUAL", "reason": "probe", "turn": 1})
	var ptext := JSON.stringify(packet)
	ev["packet_leaks"] = ptext.find(CANARY) != -1
	var plan := mgr.get_plan()
	plan["api_key"] = CANARY # hostile/echoed model field: the scrub backstop must drop the KEY
	var saved := MemoryCls.save_all(str(obs.get("battle_id", "")), {}, plan, [], {"turn": 1}, [])
	ev["saved"] = bool(saved.get("ok", false))
	var ftext := _read_text("%s/strategic_plan.json" % MemoryCls.battle_dir(str(obs.get("battle_id", ""))))
	ev["file_leaks"] = ftext.find(CANARY) != -1
	var ok := ptext.find(CANARY) == -1 and bool(saved.get("ok", false)) and ftext.find(CANARY) == -1
	_record("h20_secret_hygiene", "pass" if ok else "fail", ev)


# --- H25: coverage net for unassigned formations ----------------------------------------

func _h25_coverage() -> void:
	var ev := {}
	var sim := _fresh_sim(_base_forces())
	var obs := _obs(sim)
	var mgr := MissionManagerCls.new()
	var m1 := MissionCls.default_mission("M01", "FIX")
	m1["area"] = "CENTER"
	m1["assigned_units"] = ["R_INF_1"]
	var plan := PlanCls.default_plan(obs, 1)
	plan["missions"] = [m1]
	mgr.apply_plan(plan, 1, str(obs.get("snapshot_id", "")), str(obs.get("battle_id", "")))
	var decided: Dictionary = mgr.red_turn(sim, obs)
	var m00 := PlanCls.mission_by_id(mgr.get_plan(), "M00")
	ev["m00_units"] = m00.get("assigned_units", [])
	ev["m00_status"] = str(m00.get("status", ""))
	var mids: Array = []
	for o_val in (decided.get("orders", []) as Array):
		mids.append(str((o_val as Dictionary).get("mission_id", "?")))
	ev["order_missions"] = mids
	var kinds := {}
	for e_val in mgr.get_events():
		kinds[str((e_val as Dictionary).get("kind", "?"))] = true
	ev["coverage_event"] = kinds.has("COVERAGE_HOLD")
	var ok := str(m00.get("status", "")) == "ACTIVE" \
		and (m00.get("assigned_units", []) as Array) == ["R_ARC_1", "R_CAV_1"] \
		and mids.has("M00") and kinds.has("COVERAGE_HOLD")
	_record("h25_coverage", "pass" if ok else "fail", ev)


func _read_text(res_path: String) -> String:
	if res_path.is_empty() or not FileAccess.file_exists(res_path):
		return ""
	var f := FileAccess.open(res_path, FileAccess.READ)
	if f == null:
		return ""
	var t := f.get_as_text()
	f.close()
	return t


# --- H26: estimate parsing + honest posture ---------------------------------------------------

func _h26_estimate_posture() -> void:
	var ev := {}
	var friendlies := [{"unit_id": "R_INF_1", "status": "ready", "soldiers": 1000, "region": "CENTER"}]
	var obs := {
		"friendly_units": friendlies,
		"known_enemy_units": [
			{"unit_id": "B_A", "contact_state": "current_visible", "region": "CENTER", "troop_estimate": "약 400~500"},
			{"unit_id": "B_B", "contact_state": "current_visible", "region": "CENTER", "troop_estimate": "약 450명"},
			{"unit_id": "B_C", "contact_state": "current_visible", "region": "CENTER", "troop_estimate": "약 1,200명"},
		],
	}
	var p := OpportunityCls.region_posture(obs, "CENTER")
	ev["posture"] = p
	var unk := {"friendly_units": friendlies, "known_enemy_units": [
		{"unit_id": "B_X", "contact_state": "current_visible", "region": "CENTER", "troop_estimate": "병력: ???"}]}
	var p2 := OpportunityCls.region_posture(unk, "CENTER")
	ev["unknown"] = p2
	var empty := {"friendly_units": friendlies, "known_enemy_units": []}
	var p3 := OpportunityCls.region_posture(empty, "CENTER")
	var ok := int(p.get("blue_soldiers_estimate", -1)) == 2100 \
		and absf(float(p.get("advantage_ratio", 0.0)) - 1000.0 / 2100.0) < 0.001 \
		and int(p2.get("blue_soldiers_estimate", -1)) == 0 \
		and float(p2.get("advantage_ratio", -1.0)) == 0.0 \
		and float(p3.get("advantage_ratio", -1.0)) == 0.0 \
		and not OpportunityCls.local_advantage_high(p2) \
		and not OpportunityCls.local_advantage_high(p3)
	_record("h26_estimate_posture", "pass" if ok else "fail", ev)


# --- H27: packet vocabulary/rules + plan supersedes ---------------------------------------------------

func _h27_packet_versioning() -> void:
	var ev := {}
	var sim := _fresh_sim(_base_forces())
	var obs := _obs(sim)
	var mgr := MissionManagerCls.new()
	var gp := mgr.build_review_packet(obs, {"trigger": "MANUAL", "reason": "probe", "turn": 1})
	var shape := GeneralPacketCls.validate_shape(gp)
	var vocab: Dictionary = gp.get("vocabulary", {})
	var rules: Dictionary = gp.get("rules", {})
	ev["shape_ok"] = bool(shape.get("ok", false))
	ev["tasks"] = (vocab.get("tasks", []) as Array)
	ev["role"] = str(rules.get("role", ""))
	var a1 := mgr.apply_plan(PlanCls.default_plan(obs, 1), 1, str(obs.get("snapshot_id", "")), str(obs.get("battle_id", "")))
	var pv2 := PlanCls.default_plan(obs, 2)
	(pv2.get("concept", {}) as Dictionary)["objective"] = "v2 concept"
	var a2 := mgr.apply_plan(pv2, 2, str(obs.get("snapshot_id", "")), str(obs.get("battle_id", "")))
	var plan := mgr.get_plan()
	ev["v1"] = int(a1.get("version", -1))
	ev["v2"] = int(plan.get("plan_version", -1))
	ev["sup"] = int(plan.get("supersedes_version", -1))
	var ok := bool(shape.get("ok", false)) \
		and (vocab.get("tasks", []) as Array).has("FIX") \
		and (vocab.get("tasks", []) as Array).has("RECON") \
		and (vocab.get("triggers", []) as Array).has("MISSION_BLOCKED") \
		and str(rules.get("role", "")) == "strategic-plan-only" \
		and bool(rules.get("unit_orders_forbidden", false)) \
		and bool(a1.get("ok", false)) and bool(a2.get("ok", false)) \
		and int(plan.get("plan_version", 0)) == 2 \
		and int(plan.get("supersedes_version", 0)) == 1
	_record("h27_packet_versioning", "pass" if ok else "fail", ev)


# --- live part ------------------------------------------------------------------


func _on_test_phase(result: Dictionary) -> void:
	_sig_phase = result.duplicate(true)


func _mock_config(mount: Node) -> void:
	var cfg = mount.get("cloud_config")
	cfg.provider_id = "openai"
	cfg.model = "mock-fixture"
	cfg.endpoint = "https://mock.local/v1/chat/completions"
	cfg.set_api_key(CANARY) # mock never networks; canary proves hygiene
	cfg.mark_test_result(true, "CONNECTED", "mock test harness")
	var ad: Node = mount.get("cloud_adapter") as Node
	ad.set("mock_mode", true)


func _mock_fixture_general(missions: Array) -> Dictionary:
	return {"ok": true, "latency_ms": 9, "content_text": JSON.stringify(_general_fixture(missions))}


## Coordinator INITIAL fixture: first menu option per group (resolved from
## the frozen menu, so group/choice IDs always exist).
func _mock_fixture_coord_initial(menu: Dictionary) -> Dictionary:
	var asn: Array = []
	for g_val in (menu.get("groups", []) as Array):
		if g_val is Dictionary:
			var g: Dictionary = g_val
			var opts: Array = g.get("options", []) as Array
			if not opts.is_empty() and opts[0] is Dictionary:
				asn.append({"group": str(g.get("id", "")), "choice": str((opts[0] as Dictionary).get("id", ""))})
	return {"ok": true, "latency_ms": 9, "content_text": JSON.stringify({"concept": "FIX_AND_FLANK", "main_effort": "CENTER",
		"doctrine_profile": {"aggression": "STANDARD", "tempo": "STANDARD", "risk": "BALANCED", "reserve": "STANDARD", "pursuit": "STANDARD"},
		"assignments": asn, "review_horizon": 4})}


## Coordinator REPLAN fixture: every group to its RESERVE option. RESERVE
## ids are region-independent, so the fixture stays valid against the
## post-turn menu even after formations change regions.
func _mock_fixture_coord_replan(menu: Dictionary) -> Dictionary:
	var asn: Array = []
	for g_val in (menu.get("groups", []) as Array):
		if g_val is Dictionary:
			var g: Dictionary = g_val
			asn.append({"group": str(g.get("id", "")), "choice": CoordMenuCls.default_choice_id(g)})
	return {"ok": true, "latency_ms": 9, "content_text": JSON.stringify({"decision": "REPLAN", "concept": "FIX_AND_FLANK", "main_effort": "CENTER",
		"doctrine_profile": {"aggression": "STANDARD", "tempo": "STANDARD", "risk": "BALANCED", "reserve": "STANDARD", "pursuit": "STANDARD"},
		"assignments": asn, "review_horizon": 4})}


func _mock_fixture_tactical() -> Dictionary:
	return {"ok": true, "latency_ms": 7, "content_text": JSON.stringify({
		"plan": {"objective": "probe", "intent": "advance", "reconsider_if": "x"},
		"orders": [TableCls.make_command("HOLD", TableCls.scope_all_friendly())],
		"rationale": {"objective": "probe", "observations": "flat", "risk": "low", "intent": "hold", "reconsider_if": "x"},
	})}


func _missions_for_obs(obs: Dictionary) -> Array:
	var fix: Array = []
	var recon: Array = []
	var hold: Array = []
	for u_val in (obs.get("friendly_units", []) as Array):
		if not u_val is Dictionary:
			continue
		var u: Dictionary = u_val
		if str(u.get("status", "")) != "ready":
			continue
		var uid := str(u.get("unit_id", ""))
		match str(u.get("class", "")).to_upper():
			"SCOUT", "CAVALRY":
				recon.append(uid)
			"HQ":
				hold.append(uid)
			_:
				fix.append(uid)
	fix.sort()
	recon.sort()
	hold.sort()
	var out: Array = []
	if not fix.is_empty():
		out.append({"mission_id": "M01", "task": "FIX", "area": "CENTER", "assigned_units": fix,
			"objective": {"kind": "REGION", "region": "CENTER"}})
	if not recon.is_empty():
		out.append({"mission_id": "M02", "task": "RECON", "area": "ANY", "assigned_units": recon})
	if not hold.is_empty():
		out.append({"mission_id": "M03", "task": "HOLD", "area": "ANY", "assigned_units": hold,
			"engagement": {"policy": "HOLD_FIRE"}})
	return out


func _wait_mount(mount: Node, budget: int) -> bool:
	var frames := 0
	while frames < budget:
		await process_frame
		frames += 1
		if mount != null and bool(mount.get("mount_ready")):
			return true
	return false


func _wait_turn(shell: Node, want_turn: int, budget: int) -> bool:
	var frames := 0
	while frames < budget:
		await process_frame
		frames += 1
		var mgr: RefCounted = shell.get("unit_manager") as RefCounted
		if mgr != null and int(mgr.get_current_turn()) >= want_turn and int(shell.get("_turn_phase")) == 0:
			return true
	return false


func _wait_phase_frames(budget: int) -> bool:
	var frames := 0
	while _sig_phase.is_empty() and frames < budget:
		await process_frame
		frames += 1
	return not _sig_phase.is_empty()


func _live_part() -> void:
	GeneralTraceCls.reset()
	var packed: PackedScene = load(CLOUD2_SCENE)
	if packed == null:
		for g in ["h21_live_hierarchy", "h22_live_background", "h23_live_compat", "h24_live_memory"]:
			_record(g, "fail", {"error": "cloud2 scene failed to load"})
		return
	_live = packed.instantiate()
	root.add_child(_live)
	var mount: Node = _live.get_node_or_null("Cloud2LiveMount")
	var booted := await _wait_mount(mount, 3600)
	if not booted or mount == null:
		var err := {"error": "mount timeout", "mount_error": str(mount.get("mount_error")) if mount != null else "no mount node"}
		for g2 in ["h21_live_hierarchy", "h22_live_background", "h23_live_compat", "h24_live_memory"]:
			_record(g2, "fail", err)
		_live.queue_free()
		return
	await _live_h21(mount)
	await _live_h22(mount)
	await _live_h23(mount)
	await _live_h24(mount)
	_live.queue_free()
	await _live_h28()


## H21: hierarchy over live turns — 1 initial General plan, then local turns.
func _live_h21(mount: Node) -> void:
	var ev := {}
	_mock_config(mount)
	var controller: Node = mount.get("cloud_controller") as Node
	controller.call("set_control_mode", "MISSION_HIERARCHY")
	controller.call("set_mode", "AUTO")
	var bridge: RefCounted = mount.get("bridge") as RefCounted
	var shell: Node = mount.get("shell") as Node
	var mgr: RefCounted = shell.get("unit_manager") as RefCounted
	var obs0: Dictionary = ObsCls.build(bridge, "red")
	var ad: Node = mount.get("cloud_adapter") as Node
	var menu0 := CoordMenuCls.build_menu(obs0)
	(ad.get("mock_queue") as Array).append(_mock_fixture_coord_initial(menu0))
	ev["menu_groups"] = (menu0.get("groups", []) as Array).size()
	var t0 := int(mgr.get_current_turn())
	_sig_phase = {}
	controller.connect("phase_finished", _on_test_phase)
	var turns: Array = []
	for i in range(3):
		_sig_phase = {}
		shell.call("end_player_phase")
		var done := await _wait_turn(shell, t0 + i + 1, 20000)
		turns.append({"done": done, "status": str(_sig_phase.get("status", "TIMEOUT")),
			"orders": int(_sig_phase.get("order_count", -1)),
			"executed": int(_sig_phase.get("executed_count", -1)),
			"used_llm": bool((_sig_phase.get("general", {}) as Dictionary).get("used_llm", false))})
	ev["turns"] = turns
	var view: Dictionary = controller.call("get_general_view")
	var tel: Dictionary = view.get("telemetry", {})
	ev["telemetry"] = tel
	ev["statuses"] = view.get("statuses", [])
	ev["routine_runs"] = int(shell.call("enemy_routine_runs"))
	ev["lab_chars"] = PanelCls.render_general_view(view).length()
	controller.disconnect("phase_finished", _on_test_phase)
	var executed_total := 0
	var all_done := true
	for t_val in turns:
		all_done = all_done and bool((t_val as Dictionary).get("done", false))
		executed_total += int((t_val as Dictionary).get("executed", 0))
	var ok := all_done and int(shell.call("enemy_routine_runs")) == 0 \
		and int(tel.get("general_calls", -1)) == 1 \
		and int(tel.get("turns_without_llm", -1)) >= 2 \
		and executed_total > 0 \
		and (view.get("statuses", []) as Array).size() >= 1 \
		and PanelCls.render_general_view(view).length() > 100
	_record("h21_live_hierarchy", "pass" if ok else "fail", ev)


## H22: background review stages during the human turn, applies next RED.
func _live_h22(mount: Node) -> void:
	var ev := {}
	var controller: Node = mount.get("cloud_controller") as Node
	var bridge: RefCounted = mount.get("bridge") as RefCounted
	var shell: Node = mount.get("shell") as Node
	var mgr: RefCounted = shell.get("unit_manager") as RefCounted
	var ad: Node = mount.get("cloud_adapter") as Node
	controller.call("request_general_review")
	var obs0: Dictionary = ObsCls.build(bridge, "red")
	var menu0b := CoordMenuCls.build_menu(obs0)
	(ad.get("mock_queue") as Array).append(_mock_fixture_coord_replan(menu0b))
	ev["review_menu_groups"] = (menu0b.get("groups", []) as Array).size()
	var t0 := int(mgr.get_current_turn())
	_sig_phase = {}
	controller.connect("phase_finished", _on_test_phase)
	shell.call("end_player_phase")
	var done := await _wait_turn(shell, t0 + 1, 20000)
	ev["turn_done"] = done
	var staged := false
	var v_while_staged := -1
	for i in range(600):
		await process_frame
		var gv: Dictionary = controller.call("get_general_view")
		if bool(gv.get("staged", false)):
			staged = true
			v_while_staged = int((gv.get("plan", {}) as Dictionary).get("plan_version", -1))
			break
	ev["staged"] = staged
	ev["version_while_staged"] = v_while_staged
	var t1 := int(mgr.get_current_turn())
	shell.call("end_player_phase")
	var done2 := await _wait_turn(shell, t1 + 1, 20000)
	ev["turn2_done"] = done2
	var gv2: Dictionary = controller.call("get_general_view")
	ev["version_after"] = int((gv2.get("plan", {}) as Dictionary).get("plan_version", -1))
	ev["staged_after"] = bool(gv2.get("staged", true))
	ev["concept_after"] = str((gv2.get("plan", {}) as Dictionary).get("concept", {}).get("objective", ""))
	controller.disconnect("phase_finished", _on_test_phase)
	var ok := done and staged and v_while_staged == 1 and done2 \
		and int((gv2.get("plan", {}) as Dictionary).get("plan_version", -1)) == 2 \
		and not bool(gv2.get("staged", true)) \
		and str((gv2.get("plan", {}) as Dictionary).get("concept", {}).get("objective", "")) == str((CoordMenuCls.CONCEPTS["FIX_AND_FLANK"] as Dictionary).get("objective", ""))
	_record("h22_live_background", "pass" if ok else "fail", ev)


## H23: LEGACY_DIRECT benchmark path still works mid-session.
func _live_h23(mount: Node) -> void:
	var ev := {}
	var controller: Node = mount.get("cloud_controller") as Node
	var shell: Node = mount.get("shell") as Node
	var mgr: RefCounted = shell.get("unit_manager") as RefCounted
	var ad: Node = mount.get("cloud_adapter") as Node
	controller.call("set_control_mode", "LEGACY_DIRECT")
	mgr.end_turn() # fresh action budgets (direct phase calls advance no turn)
	(ad.get("mock_queue") as Array).append(_mock_fixture_tactical())
	_sig_phase = {}
	controller.connect("phase_finished", _on_test_phase)
	controller.call("run_red_phase")
	var done := await _wait_phase_frames(20000)
	ev["done"] = done
	ev["status"] = str(_sig_phase.get("status", "TIMEOUT"))
	ev["orders"] = int(_sig_phase.get("order_count", -1))
	controller.disconnect("phase_finished", _on_test_phase)
	controller.call("set_control_mode", "MISSION_HIERARCHY")
	var ok := done and str(_sig_phase.get("status", "")) in ["EXECUTED", "PARTIAL"] \
		and int(_sig_phase.get("order_count", 0)) == 1
	_record("h23_live_compat", "pass" if ok else "fail", ev)


## H24: battle memory files persist across live turns.
func _live_h24(mount: Node) -> void:
	var ev := {}
	var bridge: RefCounted = mount.get("bridge") as RefCounted
	var obs: Dictionary = ObsCls.build(bridge, "red")
	var dir := MemoryCls.battle_dir(str(obs.get("battle_id", "")))
	ev["dir"] = dir
	var have: Array = []
	for n in ["mission.json", "strategic_plan.json", "opponent_model.json", "battle_summary.json", "event_log.jsonl"]:
		if FileAccess.file_exists("%s/%s" % [dir, n]):
			have.append(n)
	ev["files"] = have
	_record("h24_live_memory", "pass" if have.size() == 5 else "fail", ev)


## H28: fresh battle — (a) a General TIMEOUT keeps its precise code through
## the SKIP decision (inspector + summary still name TIMEOUT); (b) the same
## battle then plays one pure-deterministic RED turn that maneuvers (RECON
## advances, MOVEs execute, zero network).
func _live_h28() -> void:
	var ev := {}
	var packed: PackedScene = load(CLOUD2_SCENE)
	var live2: Node = packed.instantiate()
	root.add_child(live2)
	var mount: Node = live2.get_node_or_null("Cloud2LiveMount")
	var booted := await _wait_mount(mount, 3600)
	if not booted or mount == null:
		_record("h28_live_timeout_carry_maneuver", "fail", {"error": "mount timeout"})
		live2.queue_free()
		return
	_mock_config(mount)
	var controller: Node = mount.get("cloud_controller") as Node
	var shell: Node = mount.get("shell") as Node
	var mgr: RefCounted = shell.get("unit_manager") as RefCounted
	var ad: Node = mount.get("cloud_adapter") as Node
	controller.call("set_control_mode", "MISSION_HIERARCHY")
	controller.call("set_mode", "AUTO")
	(ad.get("mock_queue") as Array).append({"ok": false, "code": "TIMEOUT",
		"detail": "Mock timeout.", "http_status": 0, "latency_ms": 61})
	_sig_phase = {}
	controller.connect("phase_finished", _on_test_phase)
	controller.call("run_red_phase")
	var frames := 0
	var failed := ""
	while frames < 10000:
		await process_frame
		frames += 1
		var ph := str((controller.call("get_state") as Dictionary).get("phase", ""))
		if ph.begins_with("FAILED_"):
			failed = ph
			break
	ev["failed_phase"] = failed
	controller.call("decide_skip")
	frames = 0
	while _sig_phase.is_empty() and frames < 10000:
		await process_frame
		frames += 1
	controller.disconnect("phase_finished", _on_test_phase)
	var lv: Dictionary = controller.call("get_last_view")
	var fcode := str((lv.get("failure", {}) as Dictionary).get("code", ""))
	ev["carried_code"] = fcode
	ev["summary"] = str(lv.get("summary", ""))
	SessionCls.clear()
	var cfg = mount.get("cloud_config")
	cfg.set_provider("")
	cfg.set_model("")
	cfg.set_endpoint("")
	cfg.set_api_key("")
	cfg.mark_test_result(false, "DISCONNECTED", "")
	ad.set("mock_mode", false)
	var t0 := int(mgr.get_current_turn())
	_sig_phase = {}
	controller.connect("phase_finished", _on_test_phase)
	shell.call("end_player_phase")
	var done := await _wait_turn(shell, t0 + 1, 20000)
	controller.disconnect("phase_finished", _on_test_phase)
	var moves := 0
	for o_val in ((controller.call("get_last_view") as Dictionary).get("orders", []) as Array):
		for e_val in ((o_val as Dictionary).get("executed", []) as Array):
			if str((e_val as Dictionary).get("action", "")) == "MOVE":
				moves += 1
	ev["maneuver_done"] = done
	ev["moves"] = moves
	# Six-option architecture: assert KIND-level congruence of the M02
	# unit selections. Same-score options (RECON_* vs SHADOW, FLANK_* vs
	# SCREEN) break by seed, so the gate locks employment kind (the
	# scout advances, the cavalry advances or attacks) plus movement.
	var scout_kind := ""
	var cav_kind := ""
	for t_val in ((controller.call("get_general_view") as Dictionary).get("traces", []) as Array):
		if str((t_val as Dictionary).get("mission_id", "")) != "M02":
			continue
		for u_val in ((t_val as Dictionary).get("units", []) as Array):
			var uid := str((u_val as Dictionary).get("unit_id", ""))
			if uid != "R_SCT_1" and uid != "R_CAV_1":
				continue
			var sel := int((u_val as Dictionary).get("selected_slot", -99))
			for o_val in ((u_val as Dictionary).get("options", []) as Array):
				if int((o_val as Dictionary).get("slot", -100)) == sel:
					if uid == "R_SCT_1":
						scout_kind = str((o_val as Dictionary).get("kind", "?"))
					else:
						cav_kind = str((o_val as Dictionary).get("kind", "?"))
	ev["m02_scout_kind"] = scout_kind
	ev["m02_cav_kind"] = cav_kind
	live2.queue_free()
	var ok := failed == "FAILED_TIMEOUT" and fcode == "TIMEOUT" \
		and str(lv.get("summary", "")).contains("TIMEOUT") \
		and done and moves >= 1 and scout_kind == "ADVANCE" \
		and (cav_kind == "ADVANCE" or cav_kind == "ATTACK")
	_record("h28_live_timeout_carry_maneuver", "pass" if ok else "fail", ev)


func _write_and_quit(code: int) -> void:
	var d := DirAccess.open("D:/Game development")
	if d != null:
		d.make_dir_recursive(".workflow/deliverables/CLOUD-GENERAL-STEP-02")
	var summary := {"pass": 0, "fail": 0, "blocked": 0}
	for key in _gates.keys():
		var st := str((_gates[key] as Dictionary).get("status", ""))
		if summary.has(st):
			summary[st] = int(summary[st]) + 1
	var doc := {"contract": "CLOUD-GENERAL-HIER", "gates": _gates, "summary": summary}
	var f := FileAccess.open(VERIFY_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(doc, "  "))
		f.close()
		print("[CLOUDHIER] verification_hier.json written to %s" % VERIFY_PATH)
	else:
		print("[CLOUDHIER] FAILED to write %s" % VERIFY_PATH)
	quit(mini(code, 1) if f != null else 1)
