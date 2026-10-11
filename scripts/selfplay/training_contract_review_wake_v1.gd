extends SceneTree

## TRAINING_CONTRACT_REVIEW_WAKE_V1 — headless verification harness.
##
## Usage:
##   godot --headless --path <project> --script res://scripts/selfplay/training_contract_review_wake_v1.gd \
##     -- --run-dir=res://artifacts/training_contract_review_wake_v1/raw --gates=parse,wake,strict,control,nostrict,reward
##
## Gates:
##   parse .... production parser verdicts (malformed / unknown trigger /
##              real Qwen3-8B shootout generations). No scene, no network.
##   wake ..... review-wake matrix through the real controller service +
##              mock adapter: non-event triggers fire, event batches still
##              fire, one window fires once, calm stays silent.
##   strict ... TRAINING_STRICT_CONTRACT=1: invalid INITIAL/REVIEW latch a
##              fault with zero repair, poll maps to terminal LOSS -3, the
##              hierarchy phase short-circuits with zero fallback.
##   control .. strict ON + production-valid INITIAL: READY, adopted, no
##              fault, game continues.
##   nostrict . strict OFF: malformed-then-valid INITIAL repairs through
##              the 1+1 bound, no fault latched.
##   reward ... WIN +5 / LOSS -3 / DRAW -2 pinned, strict terminal mapping
##              for both offender sides, code taxonomy checks.
##
## NO TRAINING: fixtures + mock adapter only. Zero provider calls.

const SimControllerCls = preload("res://scripts/sim/sim_controller.gd")
const ObsCls = preload("res://scripts/cloud1/cloud1_observation.gd")
const GeneralPlanCls = preload("res://scripts/cloud2/cloud2_general_plan.gd")
const CoordMenuCls = preload("res://scripts/cloud2/cloud2_coord_menu.gd")
const AdapterCls = preload("res://scripts/cloud2/cloud2_adapter.gd")
const ConfigCls = preload("res://scripts/cloud2/cloud2_config.gd")
const SessionCls = preload("res://scripts/cloud2/cloud2_session.gd")
const TacticalPlanCls = preload("res://scripts/cloud2/cloud2_plan_memory.gd")
const TurnControllerCls = preload("res://scripts/cloud2/cloud2_turn_controller.gd")
const VictoryRespCls = preload("res://scripts/cloud2/cloud2_victory_response.gd")
const AuthoringCls = preload("res://scripts/cloud2/cloud2_victory_authoring.gd")
const OpportunityCls = preload("res://scripts/cloud2/cloud2_opportunity.gd")
const MatchCls = preload("res://scripts/symloc/symloc_match.gd")
const SelfplayMatchCls = preload("res://scripts/selfplay/selfplay_match.gd")
const StrictCls = preload("res://scripts/selfplay/training_strict.gd")

const CANARY := "tcrw_fixture_canary_not_a_real_key"
const QWEN_A2000 := "res://artifacts/brain_shootout_qwen3_8b_v1/raw/gen_bf16_prod_nonthinking_A_s2000_final.txt"
const QWEN_A1001 := "res://artifacts/brain_shootout_qwen3_8b_v1/raw/gen_bf16_official_nonthinking_A_s1001_final.txt"
const QWEN_A2000_ROSTER := ["R_ARC_1", "R_INF_1", "R_INF_2", "R_CAV_1", "R_CAV_2"]
const QWEN_A1001_ROSTER := ["R_INF_1", "R_INF_2", "R_SCT_1", "R_SPE_2", "R_HQ_1", "R_CAV_1", "R_SPE_1", "R_ARC_1"]
const SYNTH_ROSTER := ["R_INF_1", "R_INF_2", "R_CAV_1"]
const MALFORMED_TEXT := '{"objective": "Broken plan", "phases": [{"id": "P1", "name": "X"'
const KEEP_TEXT := '{"decision": "KEEP", "reason": "TCRW fixture keep."}'


class ExecutorStub extends Node:
	signal execution_finished(result: Dictionary)
	var busy := false
	func set_external_busy(v: bool, _reason: String = "") -> void:
		busy = v


class StrictStub extends RefCounted:
	var fault := {}
	var side := "red"
	func strict_fault() -> Dictionary:
		return fault.duplicate(true)
	func get_side() -> String:
		return side


class UtilityFallbackStub extends Node:
	signal phase_finished(result: Dictionary)
	var calls := 0
	var completed := false
	func run_side_phase() -> void:
		calls += 1
		await get_tree().process_frame
		await get_tree().process_frame
		completed = true
		phase_finished.emit({"ok": true, "status": "UTILITY_BOT", "actions": 1})


var _gates := {}
var _evidence := {}
var _run_dir := ""
var _wanted := ["parse", "wake", "strict", "control", "nostrict", "reward"]
var _valid_text := ""
var _valid_tag := ""
var _strict_env_prev := ""


func _init() -> void:
	var all: Array = []
	all.append_array(OS.get_cmdline_user_args())
	all.append_array(OS.get_cmdline_args())
	for a in all:
		var s := str(a).strip_edges()
		if s.begins_with("--run-dir="):
			_run_dir = s.get_slice("=", 1).strip_edges()
		elif s.begins_with("--gates="):
			_wanted = s.get_slice("=", 1).strip_edges().split(",")
	_strict_env_prev = OS.get_environment("TRAINING_STRICT_CONTRACT")
	_run_async()


func _record(gate: String, ok: bool, evidence: Dictionary) -> void:
	_gates[gate] = ok
	_evidence[gate] = evidence
	print("[TCRW][%s] %s %s" % [gate, "PASS" if ok else "FAIL", JSON.stringify(evidence)])


func _run_async() -> void:
	await process_frame
	if "parse" in _wanted:
		_test_parse()
	if "wake" in _wanted:
		await _test_wake()
	if "strict" in _wanted:
		await _test_strict()
	if "control" in _wanted:
		await _test_control()
	if "nostrict" in _wanted:
		await _test_nostrict()
	if "reward" in _wanted:
		_test_reward()
	if "utility_fallback" in _wanted:
		await _test_utility_fallback()
	OS.set_environment("TRAINING_STRICT_CONTRACT", _strict_env_prev)
	_write_and_quit()


func _write_and_quit() -> void:
	var fails := 0
	for g in _gates.keys():
		if not bool(_gates[g]):
			fails += 1
	if not _run_dir.is_empty():
		var d := DirAccess.open("res://")
		if d != null:
			d.make_dir_recursive(_run_dir)
		var f := FileAccess.open(_run_dir + "/gates_tcrw.json", FileAccess.WRITE)
		if f != null:
			f.store_string(JSON.stringify({"gates": _gates, "evidence": _evidence}, "  "))
			f.close()
			print("[TCRW] evidence -> %s/gates_tcrw.json" % _run_dir)
	print("[TCRW] GATES exit=%d" % fails)
	quit(fails)


func _set_strict(on: bool) -> void:
	OS.set_environment("TRAINING_STRICT_CONTRACT", "1" if on else "")


# ------------------------------------------------------------------
# parse: production parser verdicts (no scene, no network)
# ------------------------------------------------------------------

func _read_text(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	return f.get_as_text()


func _test_parse() -> void:
	# P1: malformed JSON (brace imbalance, the observed failure mode).
	var bad: Dictionary = VictoryRespCls.parse_initial(MALFORMED_TEXT,
		{"turn": 1, "snapshot_id": "", "roster": []})
	_record("P1_parse_malformed", not bool(bad.get("ok", true)) \
		and str(bad.get("code", "")) == "VP_INVALID_JSON",
		{"code": str(bad.get("code", "")), "detail": str(bad.get("detail", "")).left(160)})
	# P2: syntactically valid doc with an unknown trigger.
	var bogus: Dictionary = VictoryRespCls.parse_initial(JSON.stringify(_bogus_doc()),
		{"turn": 1, "snapshot_id": "", "roster": SYNTH_ROSTER})
	_record("P2_parse_unknown_trigger", not bool(bogus.get("ok", true)) \
		and str(bogus.get("code", "")) == "VA_COND",
		{"code": str(bogus.get("code", "")), "detail": str(bogus.get("detail", "")).left(200)})
	# P3: real Qwen3-8B shootout generations through the same parser.
	# The first text that parses qualifies as the valid control input.
	var t2000 := _read_text(QWEN_A2000)
	var t1001 := _read_text(QWEN_A1001)
	var p2000: Dictionary = VictoryRespCls.parse_initial(t2000,
		{"turn": 1, "snapshot_id": "", "roster": QWEN_A2000_ROSTER})
	var p1001: Dictionary = VictoryRespCls.parse_initial(t1001,
		{"turn": 1, "snapshot_id": "", "roster": QWEN_A1001_ROSTER})
	_valid_text = ""
	_valid_tag = ""
	if bool(p2000.get("ok", false)):
		_valid_text = t2000
		_valid_tag = "qwen_a2000"
	elif bool(p1001.get("ok", false)):
		_valid_text = t1001
		_valid_tag = "qwen_a1001"
	else:
		_valid_text = JSON.stringify(_synthetic_valid_doc())
		_valid_tag = "synthetic"
	_record("P3_parse_qwen_qualify", not _valid_text.is_empty(),
		{"a2000_ok": bool(p2000.get("ok", false)), "a2000_code": str(p2000.get("code", "")),
			"a1001_ok": bool(p1001.get("ok", false)), "a1001_code": str(p1001.get("code", "")),
			"selected": _valid_tag, "chars": _valid_text.length()})
	# P4: REVIEW parser sanity (malformed vs KEEP).
	var rbad: Dictionary = VictoryRespCls.parse_review(MALFORMED_TEXT, {"turn": 2, "snapshot_id": ""})
	var rkeep: Dictionary = VictoryRespCls.parse_review(KEEP_TEXT, {"turn": 2, "snapshot_id": ""})
	_record("P4_parse_review_shapes", not bool(rbad.get("ok", true)) \
		and str(rbad.get("code", "")) == "VP_INVALID_JSON" \
		and bool(rkeep.get("ok", false)) \
		and str((rkeep.get("review", {}) as Dictionary).get("decision", "")) == "KEEP",
		{"bad_code": str(rbad.get("code", "")),
			"keep_decision": str((rkeep.get("review", {}) as Dictionary).get("decision", ""))})


# ------------------------------------------------------------------
# fixtures (mock adapter only; zero provider calls)
# ------------------------------------------------------------------

func _pair_forces(count: int, red_soldiers: int, blue_soldiers: int = 360) -> Array:
	var out: Array = []
	for i in range(1, count + 1):
		var r := -6 + (i - 1) * 5
		out.append({"id": "B_INF_%d" % i, "class": "infantry", "faction": "blue",
			"q": -30, "r": r, "soldiers": blue_soldiers})
		out.append({"id": "R_INF_%d" % i, "class": "infantry", "faction": "red",
			"q": -29, "r": r, "soldiers": red_soldiers})
	return out


func _qwen2000_forces() -> Array:
	return [
		{"id": "B_INF_1", "class": "infantry", "faction": "blue", "q": -30, "r": -6, "soldiers": 360},
		{"id": "B_INF_2", "class": "infantry", "faction": "blue", "q": -30, "r": -1, "soldiers": 360},
		{"id": "R_ARC_1", "class": "archer", "faction": "red", "q": -29, "r": -6, "soldiers": 260},
		{"id": "R_INF_1", "class": "infantry", "faction": "red", "q": -29, "r": -5, "soldiers": 450},
		{"id": "R_INF_2", "class": "infantry", "faction": "red", "q": -29, "r": -4, "soldiers": 450},
		{"id": "R_CAV_1", "class": "cavalry", "faction": "red", "q": -29, "r": -3, "soldiers": 300},
		{"id": "R_CAV_2", "class": "cavalry", "faction": "red", "q": -29, "r": -2, "soldiers": 300},
	]


func _qwen1001_forces() -> Array:
	return [
		{"id": "B_INF_1", "class": "infantry", "faction": "blue", "q": -30, "r": -6, "soldiers": 360},
		{"id": "B_ARC_1", "class": "archer", "faction": "blue", "q": -30, "r": -5, "soldiers": 260},
		{"id": "B_CAV_1", "class": "cavalry", "faction": "blue", "q": -30, "r": -4, "soldiers": 300},
		{"id": "R_INF_1", "class": "infantry", "faction": "red", "q": -29, "r": -6, "soldiers": 450},
		{"id": "R_INF_2", "class": "infantry", "faction": "red", "q": -29, "r": -5, "soldiers": 450},
		{"id": "R_SCT_1", "class": "scout", "faction": "red", "q": -29, "r": -4, "soldiers": 120},
		{"id": "R_SPE_1", "class": "spearman", "faction": "red", "q": -29, "r": -3, "soldiers": 400},
		{"id": "R_SPE_2", "class": "spearman", "faction": "red", "q": -29, "r": -2, "soldiers": 400},
		{"id": "R_HQ_1", "class": "hq", "faction": "red", "q": -29, "r": -1, "soldiers": 300},
		{"id": "R_CAV_1", "class": "cavalry", "faction": "red", "q": -29, "r": 0, "soldiers": 300},
		{"id": "R_ARC_1", "class": "archer", "faction": "red", "q": -29, "r": 1, "soldiers": 260},
	]


func _synthetic_forces() -> Array:
	return [
		{"id": "B_INF_1", "class": "infantry", "faction": "blue", "q": -30, "r": -6, "soldiers": 360},
		{"id": "R_INF_1", "class": "infantry", "faction": "red", "q": -29, "r": -6, "soldiers": 450},
		{"id": "R_INF_2", "class": "infantry", "faction": "red", "q": -29, "r": -5, "soldiers": 450},
		{"id": "R_CAV_1", "class": "cavalry", "faction": "red", "q": -29, "r": -4, "soldiers": 300},
	]


func _blocked_forces() -> Array:
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


func _hq_forces() -> Array:
	return [
		{"id": "B_INF_1", "class": "infantry", "faction": "blue", "q": -28, "r": 0, "soldiers": 450},
		{"id": "B_INF_2", "class": "infantry", "faction": "blue", "q": -27, "r": 2, "soldiers": 450},
		{"id": "R_HQ_1", "class": "hq", "faction": "red", "q": -29, "r": 0, "soldiers": 300},
		{"id": "R_INF_1", "class": "infantry", "faction": "red", "q": -28, "r": 1, "soldiers": 450},
		{"id": "R_INF_2", "class": "infantry", "faction": "red", "q": -29, "r": 1, "soldiers": 450},
	]


func _fresh_sim(label: String, forces: Array) -> RefCounted:
	var sim: RefCounted = SimControllerCls.new()
	sim.load_scenario({
		"scenario_id": "tcrw_%s" % label,
		"scenario_version": "1.0.0",
		"seed": 29,
		"mission_contract": {"primary_objective": "destroy_all_red", "turn_limit": 12},
		"map": {"bounds": {"q_min": -34, "q_max": -14, "r_min": -8, "r_max": 8},
			"default_terrain": 0, "terrain_overrides": {}, "river_cells": []},
		"forces": forces,
		"start_turn": 1,
	})
	return sim


func _make_controller(label: String, forces: Array, side: String = "red") -> Dictionary:
	var sim := _fresh_sim(label, forces)
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
	cfg.mark_test_result(true, "CONNECTED", "tcrw fixture")
	adapter.mock_mode = true
	controller.setup(sim, executor, adapter, cfg, TacticalPlanCls.new())
	controller.set_side(side)
	controller.set_control_mode("MISSION_HIERARCHY")
	return {"sim": sim, "adapter": adapter, "executor": executor,
		"controller": controller, "cfg": cfg}


func _free_fixture(f: Dictionary) -> void:
	(f["controller"] as Node).queue_free()
	(f["executor"] as Node).queue_free()
	(f["adapter"] as Node).queue_free()
	await process_frame


func _mock_ok(text: String) -> Dictionary:
	return {"ok": true, "latency_ms": 5, "content_text": text}


func _bind_legacy_plan(f: Dictionary, horizon: int) -> Dictionary:
	var obs := ObsCls.build(f["sim"], str(f["controller"].get_side()))
	var mgr = f["controller"].get("_manager")
	var plan := GeneralPlanCls.default_plan(obs, 1)
	plan["review_conditions"] = []
	plan["review_horizon_turns"] = horizon
	var applied: Dictionary = mgr.apply_plan(plan, 1, str(obs.get("snapshot_id", "")), str(obs.get("battle_id", "")))
	var menu: Dictionary = mgr.build_coord_menu(obs)
	var baseline := {}
	for g_val in (menu.get("groups", []) as Array):
		if g_val is Dictionary:
			baseline[str((g_val as Dictionary).get("id", ""))] = CoordMenuCls.default_choice_id(g_val)
	mgr.bind_coordination({"choices": baseline, "menu_snapshot": str(menu.get("snapshot_id", "")),
		"turn": 1, "warnings": []})
	return {"obs": obs, "applied": applied, "menu": menu}


func _bind_vp(f: Dictionary, doc: Dictionary, roster: Array, turn: int) -> Dictionary:
	var authored: Dictionary = AuthoringCls.author_initial(doc, {"turn": turn, "roster": roster})
	if not bool(authored.get("ok", false)):
		return {"ok": false, "stage": "author", "code": str(authored.get("code", "")),
			"detail": str(authored.get("detail", ""))}
	var mgr = f["controller"].get("_manager")
	var obs := ObsCls.build(f["sim"], str(f["controller"].get_side()))
	var applied: Dictionary = mgr.vp_apply_initial(authored.get("plan", {}), turn,
		str(obs.get("snapshot_id", "")), str(obs.get("battle_id", "")), "tcrw/fixture")
	if not bool(applied.get("ok", false)):
		return {"ok": false, "stage": "apply", "code": str(applied.get("code", "")),
			"detail": str(applied.get("detail", ""))}
	return {"ok": true, "obs": obs}


func _fire_initial(f: Dictionary, turn: int) -> Dictionary:
	var obs := ObsCls.build(f["sim"], str(f["controller"].get_side()))
	var fired: Dictionary = f["controller"]._vp_init_fire(obs,
		{"trigger": "INITIAL_PLAN", "reason": "TCRW fixture.", "turn": turn}, turn)
	return {"fired": fired, "obs": obs}


func _settle_initial(f: Dictionary, max_frames: int = 900) -> Dictionary:
	var last := {}
	for i in range(max_frames):
		last = f["controller"].victory_poll_initial()
		var st := str(last.get("status", ""))
		if st == "READY" or st == "FAILED":
			return last
		await process_frame
	return {"status": "TIMEOUT", "last": last}


func _synthetic_valid_doc() -> Dictionary:
	var p1 := {"id": "P1", "name": "FIX CENTER", "purpose": "Pin the enemy center in place.",
		"intent": "Fix center; watch flanks.", "groups": {"CenterFix": ["R_INF_1", "R_INF_2"]},
		"missions": [{"task": "FIX", "area": "CENTER", "units": ["R_INF_1", "R_INF_2"],
			"vs": "INFANTRY", "preserve": true,
			"win": [{"when": "TURNS_ELAPSED", "turns": 3, "since": 1}], "stop": ["HQ_THREATENED"]}],
		"win": [{"when": "TURNS_ELAPSED", "turns": 3, "since": 1}],
		"lose": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.4}],
		"abort": ["HQ_THREATENED"], "next": "P2", "on_fail": "HOLD",
		"reserve": ["R_CAV_1"], "release": [{"when": "TURNS_ELAPSED", "turns": 3, "since": 1}],
		"exploit": "Pursue if center breaks."}
	var p2 := {"id": "P2", "name": "BREAKTHROUGH", "purpose": "Break the weakened line.",
		"intent": "Commit reserve; break through.", "groups": {"Reserve": ["R_CAV_1"]},
		"missions": [{"task": "ATTACK", "area": "CENTER", "units": ["R_CAV_1"], "vs": "INFANTRY"}],
		"win": [{"when": "TURNS_ELAPSED", "turns": 6, "since": 1}], "next": "END"}
	return {"objective": "Destroy the enemy HQ.", "end_state": "Enemy HQ destroyed.",
		"cadence": 4, "doctrine": [0.6, 0.5, 0.6, 0.6, 0.7, 0.2], "phases": [p1, p2]}


func _bogus_doc() -> Dictionary:
	var doc := _synthetic_valid_doc()
	var p1: Dictionary = (doc.get("phases", []) as Array)[0]
	p1["win"] = [{"when": "BOGUS_TRIGGER_XYZ", "turns": 3, "since": 1}]
	return doc


func _valid_forces() -> Array:
	if _valid_tag == "qwen_a1001":
		return _qwen1001_forces()
	if _valid_tag == "synthetic":
		return _synthetic_forces()
	return _qwen2000_forces()


# ------------------------------------------------------------------
# wake: review-wake matrix (strict OFF)
# ------------------------------------------------------------------

func _test_wake() -> void:
	var prev := OS.get_environment("TRAINING_STRICT_CONTRACT")
	OS.set_environment("TRAINING_STRICT_CONTRACT", "")
	await _wake_periodic()
	await _wake_blocked()
	await _wake_hq()
	await _wake_event_control()
	await _wake_no_dup()
	await _wake_calm()
	await _wake_vp_transition()
	_wake_window_helper()
	await _wake_cross_trigger()
	OS.set_environment("TRAINING_STRICT_CONTRACT", prev)


func _wake_periodic() -> void:
	var f := _make_controller("w1", _pair_forces(2, 420))
	var bound := _bind_legacy_plan(f, 4)
	var mgr = f["controller"].get("_manager")
	var late := (bound["obs"] as Dictionary).duplicate(true)
	late["turn"] = 5
	var due: Dictionary = mgr.review_due(late, 5)
	var no_batch := int(due.get("event_batch_id", 0)) <= 0
	f["adapter"].mock_queue.append(_mock_ok(KEEP_TEXT))
	var svc: Dictionary = await f["controller"]._service_event_review_before_red(late, 5, true)
	var hist: Array = f["controller"].get_general_history()
	_record("W1_wake_periodic", bool(bound["applied"].get("ok", false)) \
		and bool(due.get("requested", false)) \
		and str(due.get("trigger", "")) == "PERIODIC_HORIZON" and no_batch \
		and bool(svc.get("called", false)) and hist.size() == 1 \
		and (f["adapter"].mock_queue as Array).is_empty(),
		{"trigger": str(due.get("trigger", "")), "batch": int(due.get("event_batch_id", 0)),
			"called": bool(svc.get("called", false)), "history": hist.size()})
	await _free_fixture(f)


func _wake_blocked() -> void:
	var f := _make_controller("w2", _blocked_forces())
	var obs := ObsCls.build(f["sim"], "red")
	var mgr = f["controller"].get("_manager")
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
	mgr.apply_plan(plan, 1, str(obs.get("snapshot_id", "")), str(obs.get("battle_id", "")))
	var menu: Dictionary = mgr.build_coord_menu(obs)
	var baseline := {}
	for g_val in (menu.get("groups", []) as Array):
		if g_val is Dictionary:
			baseline[str((g_val as Dictionary).get("id", ""))] = CoordMenuCls.default_choice_id(g_val)
	mgr.bind_coordination({"choices": baseline, "menu_snapshot": str(menu.get("snapshot_id", "")),
		"turn": 1, "warnings": []})
	var decided: Dictionary = mgr.red_turn(f["sim"], obs)
	var due: Dictionary = decided.get("review", {})
	var no_batch := int(due.get("event_batch_id", 0)) <= 0
	f["adapter"].mock_queue.append(_mock_ok(KEEP_TEXT))
	var svc: Dictionary = await f["controller"]._service_event_review_before_red(
		ObsCls.build(f["sim"], "red"), 1, true)
	var hist: Array = f["controller"].get_general_history()
	_record("W2_wake_mission_blocked", str(due.get("trigger", "")) == "MISSION_BLOCKED" \
		and bool(due.get("requested", false)) and no_batch \
		and bool(svc.get("called", false)) and hist.size() == 1,
		{"trigger": str(due.get("trigger", "")), "batch": int(due.get("event_batch_id", 0)),
			"called": bool(svc.get("called", false)), "history": hist.size()})
	await _free_fixture(f)


func _wake_hq() -> void:
	var f := _make_controller("w3", _hq_forces())
	var bound := _bind_legacy_plan(f, 9)
	var mgr = f["controller"].get("_manager")
	var obs := ObsCls.build(f["sim"], "red")
	var hq: Dictionary = OpportunityCls.hq_threatened(obs)
	var due: Dictionary = mgr.review_due(obs, 1)
	var no_batch := int(due.get("event_batch_id", 0)) <= 0
	f["adapter"].mock_queue.append(_mock_ok(KEEP_TEXT))
	var svc: Dictionary = await f["controller"]._service_event_review_before_red(obs, 1, true)
	var hist: Array = f["controller"].get_general_history()
	_record("W3_wake_hq_threatened", bool(hq.get("threatened", false)) \
		and bool(due.get("requested", false)) \
		and str(due.get("trigger", "")) == "HQ_THREATENED" and no_batch \
		and bool(svc.get("called", false)) and hist.size() == 1,
		{"hq": hq, "trigger": str(due.get("trigger", "")),
			"called": bool(svc.get("called", false)), "history": hist.size()})
	await _free_fixture(f)


func _wake_event_control() -> void:
	var f := _make_controller("w4", _pair_forces(2, 420))
	var bound := _bind_legacy_plan(f, 9)
	var mgr = f["controller"].get("_manager")
	var combat: Dictionary = f["sim"].do_attack("B_INF_1", "R_INF_1", "blue")
	mgr.record_authoritative_combat_event(combat, ObsCls.build(f["sim"], "red"))
	var obs := ObsCls.build(f["sim"], "red")
	var due: Dictionary = mgr.review_due(obs, 1)
	f["adapter"].mock_queue.append(_mock_ok(KEEP_TEXT))
	var svc: Dictionary = await f["controller"]._service_event_review_before_red(obs, 1, true)
	var hist: Array = f["controller"].get_general_history()
	var wake: Dictionary = mgr.wakeup_view()
	_record("W4_wake_event_batch", bool(combat.get("success", false)) \
		and bool(due.get("requested", false)) \
		and int(due.get("event_batch_id", 0)) > 0 \
		and bool(svc.get("called", false)) and hist.size() == 1 \
		and not bool(wake.get("review_pending", true)),
		{"trigger": str(due.get("trigger", "")), "batch": int(due.get("event_batch_id", 0)),
			"called": bool(svc.get("called", false)), "pending_after": bool(wake.get("review_pending", true))})
	await _free_fixture(f)


func _wake_no_dup() -> void:
	var f := _make_controller("w5", _pair_forces(2, 420))
	var bound := _bind_legacy_plan(f, 4)
	var mgr = f["controller"].get("_manager")
	var late := (bound["obs"] as Dictionary).duplicate(true)
	late["turn"] = 5
	f["adapter"].mock_queue.append(_mock_ok(KEEP_TEXT))
	var first: Dictionary = await f["controller"]._service_event_review_before_red(late, 5, true)
	f["adapter"].mock_queue.append(_mock_ok(KEEP_TEXT))
	var second: Dictionary = await f["controller"]._service_event_review_before_red(late, 5, true)
	var hist: Array = f["controller"].get_general_history()
	_record("W5_wake_no_duplicate", bool(first.get("called", false)) \
		and not bool(second.get("called", true)) and hist.size() == 1,
		{"first": bool(first.get("called", false)), "second": bool(second.get("called", false)),
			"history": hist.size()})
	await _free_fixture(f)


func _wake_calm() -> void:
	var f := _make_controller("w6", _pair_forces(2, 420))
	var bound := _bind_legacy_plan(f, 4)
	var mgr = f["controller"].get("_manager")
	var obs := ObsCls.build(f["sim"], "red")
	var due: Dictionary = mgr.review_due(obs, 1)
	var svc: Dictionary = await f["controller"]._service_event_review_before_red(obs, 1, true)
	var hist: Array = f["controller"].get_general_history()
	_record("W6_wake_calm_silent", not bool(due.get("requested", true)) \
		and not bool(svc.get("called", true)) and hist.is_empty(),
		{"requested": bool(due.get("requested", false)),
			"called": bool(svc.get("called", false)), "history": hist.size()})
	await _free_fixture(f)


func _wake_vp_transition() -> void:
	var f := _make_controller("w7", _synthetic_forces())
	var bound := _bind_vp(f, _synthetic_valid_doc(), SYNTH_ROSTER, 1)
	var mgr = f["controller"].get("_manager")
	var late := (bound.get("obs", {}) as Dictionary).duplicate(true)
	late["turn"] = 5
	var due: Dictionary = mgr.review_due(late, 5) if bool(bound.get("ok", false)) else {}
	var no_batch := int(due.get("event_batch_id", 0)) <= 0
	f["adapter"].mock_queue.append(_mock_ok(KEEP_TEXT))
	var svc := {"called": false}
	if bool(bound.get("ok", false)):
		svc = await f["controller"]._service_event_review_before_red(late, 5, true)
	var hist: Array = f["controller"].get_general_history()
	_record("W7_wake_vp_transition", bool(bound.get("ok", false)) \
		and bool(due.get("requested", false)) \
		and str(due.get("trigger", "")) == "PHASE_SUCCESS" and no_batch \
		and bool(svc.get("called", false)) and hist.size() == 1,
		{"bind": bound.get("ok", false), "trigger": str(due.get("trigger", "")),
			"called": bool(svc.get("called", false)), "history": hist.size()})
	await _free_fixture(f)


func _wake_window_helper() -> void:
	var same := TurnControllerCls.review_window_already_serviced("B#5", "B#5")
	var diff := TurnControllerCls.review_window_already_serviced("B#5", "B#6")
	var empty := TurnControllerCls.review_window_already_serviced("", "B#5")
	_record("W8_window_dedup_rule", same and not diff and not empty,
		{"same": same, "diff": diff, "empty": empty})


func _wake_cross_trigger() -> void:
	# Event batch consumed at turn 1 must not eat a persistent mission
	# trigger: MISSION_BLOCKED still wakes the next window.
	var f := _make_controller("w9", _blocked_forces())
	var obs := ObsCls.build(f["sim"], "red")
	var mgr = f["controller"].get("_manager")
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
	mgr.apply_plan(plan, 1, str(obs.get("snapshot_id", "")), str(obs.get("battle_id", "")))
	var menu: Dictionary = mgr.build_coord_menu(obs)
	var baseline := {}
	for g_val in (menu.get("groups", []) as Array):
		if g_val is Dictionary:
			baseline[str((g_val as Dictionary).get("id", ""))] = CoordMenuCls.default_choice_id(g_val)
	mgr.bind_coordination({"choices": baseline, "menu_snapshot": str(menu.get("snapshot_id", "")),
		"turn": 1, "warnings": []})
	mgr.red_turn(f["sim"], obs)
	# Synthetic capture through the REAL record path (W4 already proves a
	# live do_attack capture; the blocked fixture's forces are out of
	# attack range, and this case tests trigger sequencing, not ballistics).
	var combat := {"success": true, "attacker_faction": "blue", "defender_faction": "red",
		"attacker_id": "B_INF_1", "defender_id": "R_INF_2", "turn": 1}
	mgr.record_authoritative_combat_event(combat, ObsCls.build(f["sim"], "red"))
	var obs1 := ObsCls.build(f["sim"], "red")
	var due1: Dictionary = mgr.review_due(obs1, 1)
	f["adapter"].mock_queue.append(_mock_ok(KEEP_TEXT))
	var svc1: Dictionary = await f["controller"]._service_event_review_before_red(obs1, 1, true)
	var pending_after: Dictionary = mgr.wakeup_view()
	var svc2: Dictionary = await f["controller"]._service_event_review_before_red(obs1, 1, true)
	var obs2 := ObsCls.build(f["sim"], "red").duplicate(true)
	obs2["turn"] = 2
	var due2: Dictionary = mgr.review_due(obs2, 2)
	f["adapter"].mock_queue.append(_mock_ok(KEEP_TEXT))
	var svc3: Dictionary = await f["controller"]._service_event_review_before_red(obs2, 2, true)
	var hist: Array = f["controller"].get_general_history()
	_record("W9_wake_cross_trigger", bool(due1.get("requested", false)) \
		and int(due1.get("event_batch_id", 0)) > 0 \
		and bool(svc1.get("called", false)) \
		and not bool(pending_after.get("review_pending", true)) \
		and not bool(svc2.get("called", true)) \
		and str(due2.get("trigger", "")) == "MISSION_BLOCKED" \
		and int(due2.get("event_batch_id", 0)) <= 0 \
		and bool(svc3.get("called", false)) and hist.size() == 2,
		{"due1": str(due1.get("trigger", "")), "svc1": bool(svc1.get("called", false)),
			"svc2_same_window": bool(svc2.get("called", false)),
			"due2": str(due2.get("trigger", "")), "svc3": bool(svc3.get("called", false)),
			"history": hist.size()})
	await _free_fixture(f)


# ------------------------------------------------------------------
# strict: TRAINING_STRICT_CONTRACT=1 (zero repair, terminal LOSS -3)
# ------------------------------------------------------------------

func _test_strict() -> void:
	var prev := OS.get_environment("TRAINING_STRICT_CONTRACT")
	OS.set_environment("TRAINING_STRICT_CONTRACT", "1")
	await _strict_malformed_initial()
	await _strict_validator_initial()
	await _strict_review_invalid()
	await _strict_review_keep()
	await _strict_hierarchy_shortcircuit()
	await _strict_poll()
	OS.set_environment("TRAINING_STRICT_CONTRACT", prev)


func _strict_terminal_evidence(offender: String, fault: Dictionary) -> Dictionary:
	var term: Dictionary = StrictCls.terminal_for_offender(offender, fault)
	var out: Dictionary = MatchCls.outcomes_for_winner(str(term.get("winner", "DRAW")))
	return {"winner": str(term.get("winner", "")), "reason": str(term.get("reason", "")),
		"outcome_offender": str(out.get("outcome_red", "")) if offender == "RED" else str(out.get("outcome_blue", "")),
		"reward_offender": int(out.get("reward_red", 0)) if offender == "RED" else int(out.get("reward_blue", 0)),
		"reward_winner": int(out.get("reward_blue", 0)) if offender == "RED" else int(out.get("reward_red", 0))}


func _strict_malformed_initial() -> void:
	var f := _make_controller("s1", _synthetic_forces())
	f["adapter"].mock_queue.append(_mock_ok(MALFORMED_TEXT))
	var fire := _fire_initial(f, 1)
	var done := await _settle_initial(f)
	var st: Dictionary = f["controller"].victory_initial_status()
	var hist: Array = f["controller"].get_general_history()
	var fault: Dictionary = f["controller"].strict_fault()
	var ev := _strict_terminal_evidence("RED", fault)
	ev["status"] = str(done.get("status", ""))
	ev["retries"] = int(st.get("retries", -1))
	ev["history"] = hist.size()
	ev["fault_code"] = str(fault.get("code", ""))
	ev["fault_kind"] = str(fault.get("kind", ""))
	ev["queue_left"] = (f["adapter"].mock_queue as Array).size()
	_record("S1_strict_malformed_initial", bool(fire["fired"].get("ok", false)) \
		and str(done.get("status", "")) == "FAILED" \
		and int(st.get("retries", -1)) == 0 and hist.size() == 1 \
		and str(fault.get("code", "")) == "VP_INVALID_JSON" \
		and str(fault.get("kind", "")) == "INITIAL" \
		and str(ev["winner"]) == "BLUE" and str(ev["outcome_offender"]) == "LOSS" \
		and int(ev["reward_offender"]) == -3 and int(ev["reward_winner"]) == 5 \
		and str(ev["reason"]) == "BRAIN_CONTRACT_FAILURE_RED_VP_INVALID_JSON",
		ev)
	await _free_fixture(f)


func _strict_validator_initial() -> void:
	var f := _make_controller("s2", _synthetic_forces())
	f["adapter"].mock_queue.append(_mock_ok(JSON.stringify(_bogus_doc())))
	var fire := _fire_initial(f, 1)
	var done := await _settle_initial(f)
	var st: Dictionary = f["controller"].victory_initial_status()
	var hist: Array = f["controller"].get_general_history()
	var fault: Dictionary = f["controller"].strict_fault()
	var ev := _strict_terminal_evidence("RED", fault)
	ev["status"] = str(done.get("status", ""))
	ev["retries"] = int(st.get("retries", -1))
	ev["history"] = hist.size()
	ev["fault_code"] = str(fault.get("code", ""))
	_record("S2_strict_validator_initial", bool(fire["fired"].get("ok", false)) \
		and str(done.get("status", "")) == "FAILED" \
		and int(st.get("retries", -1)) == 0 and hist.size() == 1 \
		and str(fault.get("code", "")) == "VA_COND" \
		and str(ev["winner"]) == "BLUE" and str(ev["outcome_offender"]) == "LOSS" \
		and int(ev["reward_offender"]) == -3 and int(ev["reward_winner"]) == 5 \
		and str(ev["reason"]) == "BRAIN_CONTRACT_FAILURE_RED_VA_COND",
		ev)
	await _free_fixture(f)


func _strict_review_invalid() -> void:
	var f := _make_controller("s3", _synthetic_forces())
	var bound := _bind_vp(f, _synthetic_valid_doc(), SYNTH_ROSTER, 1)
	f["adapter"].mock_queue.append(_mock_ok(MALFORMED_TEXT))
	var obs := ObsCls.build(f["sim"], "red")
	var res := {"ok": true}
	if bool(bound.get("ok", false)):
		res = await f["controller"]._victory_blocking_review(obs,
			{"trigger": "PERIODIC_HORIZON", "reason": "TCRW fixture.", "turn": 2}, 2)
	var fault: Dictionary = f["controller"].strict_fault()
	var ev := _strict_terminal_evidence("RED", fault)
	ev["bind"] = bool(bound.get("ok", false))
	ev["review_ok"] = bool(res.get("ok", true))
	ev["review_code"] = str(res.get("code", ""))
	ev["fault_code"] = str(fault.get("code", ""))
	ev["fault_kind"] = str(fault.get("kind", ""))
	_record("S3_strict_review_invalid", bool(bound.get("ok", false)) \
		and not bool(res.get("ok", true)) \
		and str(fault.get("code", "")) == "VP_INVALID_JSON" \
		and str(fault.get("kind", "")) == "REVIEW" \
		and str(ev["winner"]) == "BLUE" and int(ev["reward_offender"]) == -3,
		ev)
	await _free_fixture(f)


func _strict_review_keep() -> void:
	var f := _make_controller("s3b", _synthetic_forces())
	var bound := _bind_vp(f, _synthetic_valid_doc(), SYNTH_ROSTER, 1)
	f["adapter"].mock_queue.append(_mock_ok(KEEP_TEXT))
	var obs := ObsCls.build(f["sim"], "red")
	var res := {"ok": false}
	if bool(bound.get("ok", false)):
		res = await f["controller"]._victory_blocking_review(obs,
			{"trigger": "PERIODIC_HORIZON", "reason": "TCRW fixture.", "turn": 2}, 2)
	var fault: Dictionary = f["controller"].strict_fault()
	var mgr = f["controller"].get("_manager")
	_record("S3b_strict_review_keep", bool(bound.get("ok", false)) \
		and bool(res.get("ok", false)) and fault.is_empty() \
		and bool(mgr.vp_has_plan()),
		{"review_ok": bool(res.get("ok", false)), "fault_empty": fault.is_empty(),
			"has_plan": bool(mgr.vp_has_plan())})
	await _free_fixture(f)


func _strict_hierarchy_shortcircuit() -> void:
	var f := _make_controller("s6", _synthetic_forces())
	var gate: Dictionary = SessionCls.resolve_for_use(f["cfg"])
	f["adapter"].mock_queue.append(_mock_ok(MALFORMED_TEXT))
	var res := {"ok": true, "code": "GATE_BLOCKED"}
	if bool(gate.get("ok", false)):
		res = await f["controller"]._run_hierarchy_inner()
	var fault: Dictionary = f["controller"].strict_fault()
	var mgr = f["controller"].get("_manager")
	var hist: Array = f["controller"].get_general_history()
	var st: Dictionary = f["controller"].victory_initial_status()
	_record("S6_strict_hierarchy_shortcircuit", bool(gate.get("ok", false)) \
		and not bool(res.get("ok", true)) \
		and str(res.get("code", "")) == "STRICT_BRAIN_CONTRACT_FAILURE" \
		and str(fault.get("code", "")) == "VP_INVALID_JSON" \
		and not bool(mgr.vp_has_plan()) \
		and not GeneralPlanCls.has_plan(mgr.get_plan()) \
		and hist.size() == 1 and int(st.get("retries", -1)) == 0,
		{"gate": bool(gate.get("ok", false)), "code": str(res.get("code", "")),
			"fault": str(fault.get("code", "")), "vp_plan": bool(mgr.vp_has_plan()),
			"legacy_plan": GeneralPlanCls.has_plan(mgr.get_plan()),
			"history": hist.size(), "retries": int(st.get("retries", -1))})
	await _free_fixture(f)


func _strict_poll() -> void:
	# Poll selection with doubles + one real faulted controller.
	var f := _make_controller("sp", _synthetic_forces())
	f["adapter"].mock_queue.append(_mock_ok(MALFORMED_TEXT))
	_fire_initial(f, 1)
	await _settle_initial(f)
	var clean := StrictStub.new()
	var fault_red := StrictStub.new()
	fault_red.side = "red"
	fault_red.fault = {"side": "RED", "kind": "INITIAL", "code": "VP_INVALID_JSON",
		"detail": "d", "turn": 3, "call": "c"}
	var fault_blue := StrictStub.new()
	fault_blue.side = "blue"
	fault_blue.fault = {"side": "BLUE", "kind": "REVIEW", "code": "VA_COND",
		"detail": "d", "turn": 4, "call": "c"}
	var t_none: Dictionary = StrictCls.poll_strict_terminal(clean, clean)
	var t_red: Dictionary = StrictCls.poll_strict_terminal(fault_red, clean)
	var t_blue: Dictionary = StrictCls.poll_strict_terminal(clean, fault_blue)
	var t_real: Dictionary = StrictCls.poll_strict_terminal(f["controller"], clean)
	OS.set_environment("TRAINING_STRICT_CONTRACT", "")
	var t_off: Dictionary = StrictCls.poll_strict_terminal(fault_red, fault_blue)
	OS.set_environment("TRAINING_STRICT_CONTRACT", "1")
	_record("S7_strict_poll", t_none.is_empty() \
		and str(t_red.get("winner", "")) == "BLUE" \
		and str(t_red.get("reason", "")) == "BRAIN_CONTRACT_FAILURE_RED_VP_INVALID_JSON" \
		and str(t_blue.get("winner", "")) == "RED" \
		and str(t_blue.get("reason", "")) == "BRAIN_CONTRACT_FAILURE_BLUE_VA_COND" \
		and str(t_real.get("winner", "")) == "BLUE" \
		and str(t_real.get("reason", "")) == "BRAIN_CONTRACT_FAILURE_RED_VP_INVALID_JSON" \
		and t_off.is_empty(),
		{"none_empty": t_none.is_empty(), "red": t_red.get("reason", ""),
			"blue": t_blue.get("reason", ""), "real": t_real.get("reason", ""),
			"off_empty": t_off.is_empty()})
	await _free_fixture(f)


# ------------------------------------------------------------------
# control: strict ON + production-valid INITIAL (game continues)
# ------------------------------------------------------------------

func _test_control() -> void:
	var prev := OS.get_environment("TRAINING_STRICT_CONTRACT")
	OS.set_environment("TRAINING_STRICT_CONTRACT", "1")
	if _valid_text.is_empty():
		_test_parse()
	var f := _make_controller("c4", _valid_forces())
	f["adapter"].mock_queue.append(_mock_ok(_valid_text))
	var fire := _fire_initial(f, 1)
	var done := await _settle_initial(f)
	var st: Dictionary = f["controller"].victory_initial_status()
	var hist: Array = f["controller"].get_general_history()
	var fault: Dictionary = f["controller"].strict_fault()
	var consumed := {"ok": false}
	if str(done.get("status", "")) == "READY":
		consumed = f["controller"].victory_consume_initial(fire["obs"], 1)
	var mgr = f["controller"].get("_manager")
	var plan: Dictionary = mgr.get_plan()
	var due: Dictionary = mgr.review_due(ObsCls.build(f["sim"], "red"), 1)
	var term: Dictionary = StrictCls.poll_strict_terminal(f["controller"], StrictStub.new())
	_record("C4_strict_valid_control", str(done.get("status", "")) == "READY" \
		and bool(consumed.get("ok", false)) and bool(mgr.vp_has_plan()) \
		and fault.is_empty() and term.is_empty() \
		and (plan.get("missions", []) as Array).size() > 0 \
		and not bool(due.get("requested", true)) \
		and hist.size() == 1 and int(st.get("retries", -1)) == 0,
		{"tag": _valid_tag, "status": str(done.get("status", "")),
			"consumed": bool(consumed.get("ok", false)), "has_plan": bool(mgr.vp_has_plan()),
			"fault_empty": fault.is_empty(), "terminal_empty": term.is_empty(),
			"missions": (plan.get("missions", []) as Array).size(),
			"review_requested": bool(due.get("requested", false)),
			"history": hist.size(), "retries": int(st.get("retries", -1))})
	await _free_fixture(f)
	OS.set_environment("TRAINING_STRICT_CONTRACT", prev)


# ------------------------------------------------------------------
# nostrict: strict OFF preserves repair (1+1 bound)
# ------------------------------------------------------------------

func _test_nostrict() -> void:
	var prev := OS.get_environment("TRAINING_STRICT_CONTRACT")
	OS.set_environment("TRAINING_STRICT_CONTRACT", "")
	if _valid_text.is_empty():
		_test_parse()
	var f := _make_controller("n5", _valid_forces())
	f["adapter"].mock_queue.append(_mock_ok(MALFORMED_TEXT))
	f["adapter"].mock_queue.append(_mock_ok(_valid_text))
	var fire := _fire_initial(f, 1)
	var done := await _settle_initial(f)
	var st: Dictionary = f["controller"].victory_initial_status()
	var hist: Array = f["controller"].get_general_history()
	var fault: Dictionary = f["controller"].strict_fault()
	var consumed := {"ok": false}
	if str(done.get("status", "")) == "READY":
		consumed = f["controller"].victory_consume_initial(fire["obs"], 1)
	var mgr = f["controller"].get("_manager")
	_record("N5_nostrict_repair_preserved", bool(fire["fired"].get("ok", false)) \
		and str(done.get("status", "")) == "READY" \
		and int(st.get("retries", -1)) == 1 and hist.size() == 2 \
		and fault.is_empty() and bool(consumed.get("ok", false)) \
		and bool(mgr.vp_has_plan()) \
		and (f["adapter"].mock_queue as Array).is_empty(),
		{"status": str(done.get("status", "")), "retries": int(st.get("retries", -1)),
			"history": hist.size(), "fault_empty": fault.is_empty(),
			"consumed": bool(consumed.get("ok", false))})
	await _free_fixture(f)
	OS.set_environment("TRAINING_STRICT_CONTRACT", prev)


## Optional fallback gate uses the real production INITIAL/REVIEW parser and
## mock Brain completion bytes. The stub stands in only for bounded bot action.
func _test_utility_fallback() -> void:
	var old_strict := OS.get_environment("TRAINING_STRICT_CONTRACT")
	var old_flag := OS.get_environment("UTILITY_BOT_BRAIN_FALLBACK")
	OS.set_environment("TRAINING_STRICT_CONTRACT", "")
	OS.set_environment("UTILITY_BOT_BRAIN_FALLBACK", "1")
	var initial := _make_controller("uf_initial", _synthetic_forces())
	var bot_initial := UtilityFallbackStub.new()
	get_root().add_child(bot_initial)
	initial["controller"].set_utility_bot_fallback_controller(bot_initial)
	initial["adapter"].mock_queue.append(_mock_ok(MALFORMED_TEXT))
	var initial_fire := _fire_initial(initial, 1)
	var initial_done := await _settle_initial(initial)
	var initial_pending: Dictionary = initial["controller"].utility_bot_fallback_status()
	var initial_fallback: Dictionary = await initial["controller"]._utility_fallback_run(1)
	var initial_rearmed: Dictionary = initial["controller"].victory_initial_status()
	_record("UF1_invalid_initial_single_turn", bool(initial_fire["fired"].get("ok", false)) \
		and str(initial_done.get("status", "")) == "FAILED" \
		and str((initial_pending.get("pending", {}) as Dictionary).get("code", "")) == "VP_INVALID_JSON" \
		and bot_initial.calls == 1 and bot_initial.completed and bool(initial_fallback.get("ok", false)) \
		and str(initial_rearmed.get("state", "")) == "NOT_STARTED" \
		and initial["controller"].get_general_history().size() == 1 \
		and initial["controller"].strict_fault().is_empty(),
		{"parsed": initial_done.get("status", ""), "pending": initial_pending.get("pending", {}),
			"bot_calls": bot_initial.calls, "bot_completed": bot_initial.completed, "rearmed": initial_rearmed.get("state", ""),
			"brain_history": initial["controller"].get_general_history().size()})
	bot_initial.queue_free()
	await _free_fixture(initial)
	var review := _make_controller("uf_review", _synthetic_forces())
	var bot_review := UtilityFallbackStub.new()
	get_root().add_child(bot_review)
	review["controller"].set_utility_bot_fallback_controller(bot_review)
	var bound := _bind_vp(review, _synthetic_valid_doc(), SYNTH_ROSTER, 1)
	review["adapter"].mock_queue.append(_mock_ok(MALFORMED_TEXT))
	var obs := ObsCls.build(review["sim"], "red")
	var rejected: Dictionary = await review["controller"]._victory_blocking_review(obs,
		{"trigger": "PERIODIC_HORIZON", "reason": "Utility fallback probe.", "turn": 2}, 2)
	var review_pending: Dictionary = review["controller"].utility_bot_fallback_status()
	var review_fallback: Dictionary = await review["controller"]._utility_fallback_run(2)
	_record("UF2_invalid_review_single_turn", bool(bound.get("ok", false)) \
		and str(rejected.get("code", "")) == "VP_INVALID_JSON" \
		and str((review_pending.get("pending", {}) as Dictionary).get("kind", "")) == "REVIEW" \
		and bot_review.calls == 1 and bot_review.completed and bool(review_fallback.get("ok", false)) \
		and (review["controller"].get("_manager") as RefCounted).vp_has_plan() \
		and review["controller"].strict_fault().is_empty(),
		{"parse_code": rejected.get("code", ""), "pending": review_pending.get("pending", {}),
			"bot_calls": bot_review.calls, "bot_completed": bot_review.completed,
			"plan_retained": (review["controller"].get("_manager") as RefCounted).vp_has_plan()})
	bot_review.queue_free()
	await _free_fixture(review)
	OS.set_environment("TRAINING_STRICT_CONTRACT", "1")
	var strict := _make_controller("uf_strict", _synthetic_forces())
	var bot_strict := UtilityFallbackStub.new()
	get_root().add_child(bot_strict)
	strict["controller"].set_utility_bot_fallback_controller(bot_strict)
	strict["adapter"].mock_queue.append(_mock_ok(MALFORMED_TEXT))
	_fire_initial(strict, 1)
	var strict_done := await _settle_initial(strict)
	var strict_pending: Dictionary = strict["controller"].utility_bot_fallback_status()
	_record("UF3_strict_bypasses_fallback", str(strict_done.get("status", "")) == "FAILED" \
		and str(strict["controller"].strict_fault().get("code", "")) == "VP_INVALID_JSON" \
		and (strict_pending.get("pending", {}) as Dictionary).is_empty() and bot_strict.calls == 0,
		{"parsed": strict_done.get("status", ""), "strict_fault": strict["controller"].strict_fault(),
			"pending": strict_pending.get("pending", {}), "bot_calls": bot_strict.calls})
	bot_strict.queue_free()
	await _free_fixture(strict)
	OS.set_environment("TRAINING_STRICT_CONTRACT", old_strict)
	OS.set_environment("UTILITY_BOT_BRAIN_FALLBACK", old_flag)


# ------------------------------------------------------------------
# reward: contract pinned (pure static checks)
# ------------------------------------------------------------------

func _test_reward() -> void:
	var r := MatchCls.outcomes_for_winner("RED")
	var b := MatchCls.outcomes_for_winner("BLUE")
	var dr := MatchCls.outcomes_for_winner("DRAW")
	var sr := SelfplayMatchCls.outcomes_for_winner("RED")
	var sb := SelfplayMatchCls.outcomes_for_winner("BLUE")
	var sdr := SelfplayMatchCls.outcomes_for_winner("DRAW")
	_record("R1_reward_contract", int(r.get("reward_red", 0)) == 5 \
		and int(r.get("reward_blue", 0)) == -3 and str(r.get("outcome_red", "")) == "WIN" \
		and int(b.get("reward_red", 0)) == -3 and int(b.get("reward_blue", 0)) == 5 \
		and str(b.get("outcome_blue", "")) == "WIN" \
		and int(dr.get("reward_red", 0)) == -2 and int(dr.get("reward_blue", 0)) == -2 \
		and MatchCls.REWARD_WIN == 5 and MatchCls.REWARD_LOSS == -3 and MatchCls.REWARD_DRAW == -2 \
		and int(sr.get("reward_red", 0)) == 5 and int(sb.get("reward_blue", 0)) == 5 \
		and int(sdr.get("reward_red", 0)) == -2,
		{"red": r, "blue": b, "draw": dr})
	var fr := {"side": "RED", "kind": "INITIAL", "code": "VP_INVALID_JSON",
		"detail": "d", "turn": 2, "call": "c"}
	var fb := {"side": "BLUE", "kind": "REVIEW", "code": "VA_COND",
		"detail": "d", "turn": 3, "call": "c"}
	var tr: Dictionary = StrictCls.terminal_for_offender("RED", fr)
	var tb: Dictionary = StrictCls.terminal_for_offender("BLUE", fb)
	var or_: Dictionary = MatchCls.outcomes_for_winner(str(tr.get("winner", "")))
	var ob: Dictionary = MatchCls.outcomes_for_winner(str(tb.get("winner", "")))
	_record("R2_strict_reward_mapping", bool(tr.get("over", false)) \
		and str(tr.get("winner", "")) == "BLUE" \
		and str(tr.get("reason", "")) == "BRAIN_CONTRACT_FAILURE_RED_VP_INVALID_JSON" \
		and int(tr.get("turn", 0)) == 2 \
		and str(or_.get("outcome_red", "")) == "LOSS" and int(or_.get("reward_red", 0)) == -3 \
		and int(or_.get("reward_blue", 0)) == 5 \
		and str(tb.get("winner", "")) == "RED" \
		and str(tb.get("reason", "")) == "BRAIN_CONTRACT_FAILURE_BLUE_VA_COND" \
		and str(ob.get("outcome_blue", "")) == "LOSS" and int(ob.get("reward_blue", 0)) == -3 \
		and int(ob.get("reward_red", 0)) == 5,
		{"red_offender": tr, "blue_offender": tb})
	# R2b: the strict terminal reason flows through the EXISTING match
	# record builder unchanged (same shape the mount finalizes).
	var mr: Dictionary = MatchCls.build_result("BLUE",
		"BRAIN_CONTRACT_FAILURE_RED_VP_INVALID_JSON", 3,
		{"scenario": "tcrw", "red_brain": "m", "blue_brain": "m"})
	_record("R2b_strict_match_record", str(mr.get("winner", "")) == "BLUE" \
		and str(mr.get("reason", "")) == "BRAIN_CONTRACT_FAILURE_RED_VP_INVALID_JSON" \
		and str(mr.get("outcome_red", "")) == "LOSS" and int(mr.get("reward_red", 0)) == -3 \
		and int(mr.get("reward_blue", 0)) == 5 and int(mr.get("turns", 0)) == 3,
		{"winner": str(mr.get("winner", "")), "reason": str(mr.get("reason", "")),
			"reward_red": int(mr.get("reward_red", 0)), "reward_blue": int(mr.get("reward_blue", 0))})
	var tax := StrictCls.is_brain_contract_code("VP_INVALID_JSON") \
		and StrictCls.is_brain_contract_code("VA_COND") \
		and StrictCls.is_brain_contract_code("COORD_INVALID_SCHEMA") \
		and StrictCls.is_brain_contract_code("PLAN_INVALID") \
		and not StrictCls.is_brain_contract_code("TIMEOUT") \
		and not StrictCls.is_brain_contract_code("TIMEOUT_WAIT") \
		and not StrictCls.is_brain_contract_code("PROVIDER_ERROR") \
		and not StrictCls.is_brain_contract_code("START_FAILED_X") \
		and not StrictCls.is_brain_contract_code("COORD_EMPTY_MENU") \
		and not StrictCls.is_brain_contract_code("")
	var env_prev := OS.get_environment("TRAINING_STRICT_CONTRACT")
	OS.set_environment("TRAINING_STRICT_CONTRACT", "")
	var off := StrictCls.strict_enabled()
	OS.set_environment("TRAINING_STRICT_CONTRACT", "1")
	var on := StrictCls.strict_enabled()
	OS.set_environment("TRAINING_STRICT_CONTRACT", env_prev)
	_record("R3_strict_scope_taxonomy", tax and not off and on,
		{"taxonomy": tax, "default_off": not off, "explicit_on": on})
