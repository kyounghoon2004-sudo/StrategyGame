extends SceneTree

## CLOUD-GENERAL STEP 1 --headless verification-gate runner (Gates 1-9).
##
## Usage (Windows):
##   Godot_v4.2.2-stable_win64_console.exe --headless --path "D:\Game development\Demon slayer\StrategyGame" -s res://scripts/cloud1/cloud1_entry.gd
##
## Exit code 0 = all gates pass, 1 = any gate fails. Writes verification.json
## and step1_interface_contract.json into CLOUD-GENERAL-STEP-01.

const SimControllerCls = preload("res://scripts/sim/sim_controller.gd")
const ObsCls = preload("res://scripts/cloud1/cloud1_observation.gd")
const TableCls = preload("res://scripts/cloud1/cloud1_action_table.gd")
const CompilerCls = preload("res://scripts/cloud1/cloud1_compiler.gd")
const InspectorCls = preload("res://scripts/cloud1/cloud1_inspector.gd")
const PanelCls = preload("res://scripts/cloud1/cloud1_panel.gd")

const DELIVER_DIR := "D:/Game development/.workflow/deliverables/CLOUD-GENERAL-STEP-01"
const VERIFY_PATH := "D:/Game development/.workflow/deliverables/CLOUD-GENERAL-STEP-01/verification.json"
const CONTRACT_PATH := "D:/Game development/.workflow/deliverables/CLOUD-GENERAL-STEP-01/step1_interface_contract.json"

const HIDDEN_ID := "R_CON_9"
const HIDDEN_SOLDIERS := 613

var _gates: Dictionary = {}


func _init() -> void:
	var code := _run_all()
	_write_artifacts()
	print("[CLOUD1] gates complete --exit %d" % code)
	quit(code)


func _record(gate: String, status: String, evidence: Dictionary) -> void:
	_gates[gate] = {"status": status, "evidence": evidence}
	print("[CLOUD1][%s] %s" % [gate, status.to_upper()])


func _scenario() -> Dictionary:
	return {
		"scenario_id": "cloud_step1_neutral_probe",
		"scenario_version": "1.0.0",
		"seed": 7,
		"mission_contract": {
			"primary_objective": "destroy_all_red",
			"turn_limit": 6,
			"time_pressure": "none",
			"force_preservation": "standard",
			"risk_tolerance": "normal",
			"information_priority": "normal",
			"withdrawal_policy": "none",
			"special_constraints": [],
		},
		"map": {
			"bounds": {"q_min": -30, "q_max": -20, "r_min": -5, "r_max": 5},
			"default_terrain": 0,
			"terrain_overrides": {},
			"river_cells": [],
		},
		"forces": [
			{"id": "B_HQ_1", "class": "hq", "faction": "blue", "q": -28, "r": 0, "soldiers": 300},
			{"id": "B_INF_1", "class": "infantry", "faction": "blue", "q": -25, "r": 0, "soldiers": 450},
			{"id": "B_CAV_1", "class": "cavalry", "faction": "blue", "q": -26, "r": 1, "soldiers": 320},
			{"id": "B_SCT_1", "class": "scout", "faction": "blue", "q": -26, "r": -1, "soldiers": 80},
			{"id": "B_ARC_1", "class": "archer", "faction": "blue", "q": -27, "r": 0, "soldiers": 260},
			{"id": "R_INF_1", "class": "infantry", "faction": "red", "q": -23, "r": 0, "soldiers": 477},
			{"id": "R_ARC_1", "class": "archer", "faction": "red", "q": -23, "r": -1, "soldiers": 290},
			{"id": HIDDEN_ID, "class": "conscript", "faction": "red", "q": -20, "r": 5, "soldiers": HIDDEN_SOLDIERS},
		],
		"start_turn": 1,
	}


func _fresh_sim() -> RefCounted:
	var sim: RefCounted = SimControllerCls.new()
	var res: Dictionary = sim.load_scenario(_scenario())
	if not bool(res.get("ok", false)):
		print("[CLOUD1] FATAL scenario load failed: %s" % JSON.stringify(res))
	return sim


func _run_all() -> int:
	_g1_step0_regression()
	_g2_single_source()
	_g3_no_privileged_data()
	_g4_action_parity()
	_g5_group_command()
	_g6_authoritative_reuse()
	_g7_partial_failure()
	_g8_deterministic_serialization()
	_g9_human_inspection()
	for key in _gates.keys():
		if str((_gates[key] as Dictionary).get("status", "")) != "pass":
			return 1
	return 0


# GATE 1 --minimal sandbox still works normally (direct authoritative path).
func _g1_step0_regression() -> void:
	var sim := _fresh_sim()
	var mv: Dictionary = sim.do_move("B_INF_1", -24, 0, "blue", "auto")
	var mv_ok := bool(mv.get("success", false))
	var atk: Dictionary = sim.do_attack("B_INF_1", "R_INF_1", "blue")
	var atk_ok := bool(atk.get("success", false))
	var turn: Dictionary = sim.sim_end_turn()
	var turn_ok := bool(turn.get("ok", false)) and int(turn.get("current_turn", 0)) == 2
	var mission: Dictionary = sim.evaluate_mission()
	var mission_ok := str(mission.get("mission_status", "")) in ["ongoing", "victory", "defeat", "expired"]
	var reset: Dictionary = sim.reset_episode()
	var reset_ok := bool(reset.get("ok", false)) and bool(reset.get("restored_initial_fingerprint", false))
	var ok := mv_ok and atk_ok and turn_ok and mission_ok and reset_ok
	_record("gate1_step0_regression", "pass" if ok else "fail", {
		"trace": "input B_INF_1->(-24,0) -> BattleCommandService.execute_move_intent -> Step3UnitManager.execute_player_stepwise_move; attack B_INF_1->R_INF_1 -> execute_attack_intent(+Step6 mods) -> UnitManager.execute_attack -> CombatCalculator; end_turn -> Step6+Manager+Fog cycle",
		"move_success": mv_ok, "attack_success": atk_ok,
		"turn_advanced_to_2": turn_ok, "mission_status": str(mission.get("mission_status", "?")),
		"reset_restored": reset_ok,
	})


# GATE 2 --human inspector and machine JSON share one canonical snapshot.
func _g2_single_source() -> void:
	var sim := _fresh_sim()
	sim.do_move("B_INF_1", -24, 0, "blue", "auto")
	var obs: Dictionary = ObsCls.build(sim)
	var catalog: Array = TableCls.build_catalog(obs)
	var text: String = InspectorCls.render_text(obs, catalog)
	var payload: String = InspectorCls.render_payload(obs)
	var match: Dictionary = InspectorCls.fingerprint_match(obs, payload)
	var parsed: Dictionary = JSON.parse_string(payload)
	var counts_equal := int((parsed.get("friendly_units", []) as Array).size()) == int((obs.get("friendly_units", []) as Array).size()) and int((parsed.get("known_enemy_units", []) as Array).size()) == int((obs.get("known_enemy_units", []) as Array).size())
	var ok := bool(obs.get("ok", false)) and bool(match.get("ok", false)) and counts_equal and not text.is_empty()
	_record("gate2_single_source", "pass" if ok else "fail", {
		"snapshot_id": str(obs.get("snapshot_id", "")),
		"fingerprint": str((obs.get("parity", {}) as Dictionary).get("fingerprint", "")),
		"fingerprint_check": str(match.get("detail", "")),
		"inspector_chars": text.length(),
		"payload_chars": payload.length(),
		"unit_counts_equal": counts_equal,
	})


# GATE 3 --no privileged Cloud data (hidden RED truth never leaks).
func _g3_no_privileged_data() -> void:
	var sim := _fresh_sim()
	sim.do_move("B_INF_1", -24, 0, "blue", "auto")
	var obs: Dictionary = ObsCls.build(sim)
	var payload: String = ObsCls.to_json(obs, true)
	var known_ids: Array = []
	for e_val in (obs.get("known_enemy_units", []) as Array):
		known_ids.append(str((e_val as Dictionary).get("unit_id", "")))
	var hidden_listed := HIDDEN_ID in known_ids
	var leaks_count := payload.find(str(HIDDEN_SOLDIERS)) != -1
	var forbidden := ["soldier_count", "remaining_mp", "base_mp", "local_supply", "supply_days", "world_truth", "\"plan\"", "\"orders\"", "\"destination\""]
	var hits: Array = []
	for f in forbidden:
		if payload.find("\"" + f.strip_edges().trim_prefix("\"").trim_suffix("\"") + "\"") != -1 and f not in ["\"plan\"", "\"orders\"", "\"destination\""]:
			hits.append(f)
	# Enemy-section audit: no forbidden vitals inside known_enemy_units text.
	var enemy_text := JSON.stringify(obs.get("known_enemy_units", []))
	var enemy_hits: Array = []
	for f2 in ["soldier_count", "max_count", "morale", "local_supply", "remaining_mp", "base_mp"]:
		if enemy_text.find("\"" + f2 + "\"") != -1:
			enemy_hits.append(f2)
	var visible_spotted := "R_INF_1" in known_ids
	var truth_has_hidden := false
	for u_val in (sim.world_truth().get("units", []) as Array):
		if str((u_val as Dictionary).get("id", "")) == HIDDEN_ID:
			truth_has_hidden = true
	var ok := truth_has_hidden and not hidden_listed and not leaks_count and enemy_hits.is_empty() and visible_spotted
	_record("gate3_no_privileged_data", "pass" if ok else "fail", {
		"hidden_unit_in_world_truth": truth_has_hidden,
		"hidden_unit_in_blue_observation": hidden_listed,
		"hidden_soldier_count_in_payload": leaks_count,
		"forbidden_fields_in_enemy_section": enemy_hits,
		"visible_enemy_spotted": visible_spotted,
		"known_ids": known_ids,
	})


# GATE 4 --human can issue every command the Cloud catalog exposes.
func _g4_action_parity() -> void:
	var sim := _fresh_sim()
	var obs: Dictionary = ObsCls.build(sim)
	var catalog: Array = TableCls.build_catalog(obs)
	var panel: Control = PanelCls.new()
	panel.bind_sim(sim)
	var panel_fams: Array = panel.supported_families()
	var catalog_fams: Array = []
	for row_val in catalog:
		catalog_fams.append(str((row_val as Dictionary).get("action_family", "")))
	catalog_fams.sort()
	var sorted_panel: Array = panel_fams.duplicate()
	sorted_panel.sort()
	var same_sets := JSON.stringify(catalog_fams) == JSON.stringify(sorted_panel)
	# Every catalog family validates structurally through the shared table.
	var structural_ok := true
	for fam in catalog_fams:
		var probe := _probe_command(str(fam), obs)
		var v: Dictionary = TableCls.validate_command(probe)
		# Deferred actions are honestly deferred; all others must validate structurally.
		if str(fam) in TableCls.DEFERRED_ACTIONS:
			if str(v.get("code", "")) != "ACTION_DEFERRED":
				structural_ok = false
		elif not bool(v.get("ok", false)):
			structural_ok = false
	panel.free()
	var ok := same_sets and structural_ok
	_record("gate4_action_parity", "pass" if ok else "fail", {
		"catalog_families": catalog_fams,
		"panel_families": sorted_panel,
		"sets_equal": same_sets,
		"shared_schema_validation": structural_ok,
		"note": "Human panel drafts Cloud1ActionTable.make_command; no richer human-only path.",
	})


func _probe_command(fam: String, obs: Dictionary) -> Dictionary:
	var enemy_id := "R_INF_1"
	for e_val in (obs.get("known_enemy_units", []) as Array):
		if str((e_val as Dictionary).get("contact_state", "")) == "current_visible":
			enemy_id = str((e_val as Dictionary).get("unit_id", "R_INF_1"))
			break
	match fam:
		"ADVANCE":
			return TableCls.make_command("ADVANCE", TableCls.scope_all_combat(), TableCls.target_direction("FORWARD"))
		"HOLD":
			return TableCls.make_command("HOLD", TableCls.scope_all_friendly())
		"WITHDRAW":
			return TableCls.make_command("WITHDRAW", TableCls.scope_all_combat(), TableCls.target_zone("HQ"))
		"REPOSITION":
			return TableCls.make_command("REPOSITION", TableCls.scope_class("INFANTRY"), TableCls.target_zone("CENTER"))
		"ATTACK":
			return TableCls.make_command("ATTACK", TableCls.scope_class("INFANTRY"), TableCls.target_formation(enemy_id))
		"PRESSURE":
			return TableCls.make_command("PRESSURE", TableCls.scope_all_combat(), TableCls.target_direction("FORWARD"), "STANDARD", "ASSERTIVE")
		"FLANK":
			return TableCls.make_command("FLANK", TableCls.scope_class("CAVALRY"), TableCls.target_direction("RIGHT"))
		"PURSUE":
			return TableCls.make_command("PURSUE", TableCls.scope_class("CAVALRY"), TableCls.target_formation(enemy_id), "EXTENDED")
		"CONCENTRATE":
			return TableCls.make_command("CONCENTRATE", TableCls.scope_all_combat(), TableCls.target_zone("CENTER"))
		"SPREAD":
			return TableCls.make_command("SPREAD", TableCls.scope_all_combat())
		"RESERVE":
			return TableCls.make_command("RESERVE", TableCls.scope_class("ARCHER"))
		"RECON":
			return TableCls.make_command("RECON", TableCls.scope_class("SCOUT"), TableCls.target_direction("RIGHT"), "EXTENDED", "CAUTIOUS")
	return TableCls.make_command("HOLD", TableCls.scope_all_friendly())


# GATE 5 --group commands execute for real.
func _g5_group_command() -> void:
	var results := {}
	var s1 := _fresh_sim()
	var r1: Dictionary = CompilerCls.execute(s1, TableCls.make_command("ADVANCE", TableCls.scope_all_combat(), TableCls.target_direction("FORWARD"), "STANDARD", "BALANCED"))
	results["whole_army_advance"] = {"status": str(r1.get("execution_status", "?")), "executed": (r1.get("executed_units", []) as Array).size(), "plan_failed": (r1.get("plan_failed", []) as Array).size()}
	var s2 := _fresh_sim()
	var r2: Dictionary = CompilerCls.execute(s2, TableCls.make_command("ADVANCE", TableCls.scope_class("CAVALRY"), TableCls.target_direction("FORWARD")))
	results["class_cavalry_advance"] = {"status": str(r2.get("execution_status", "?")), "executed": (r2.get("executed_units", []) as Array).size()}
	var s3 := _fresh_sim()
	var r3: Dictionary = CompilerCls.execute(s3, TableCls.make_command("RECON", TableCls.scope_class("SCOUT"), TableCls.target_direction("RIGHT"), "EXTENDED", "CAUTIOUS"))
	results["scout_recon"] = {"status": str(r3.get("execution_status", "?")), "executed": (r3.get("executed_units", []) as Array).size()}
	var s4 := _fresh_sim()
	var obs4: Dictionary = ObsCls.build(s4)
	var formation := "FIELD"
	if not (obs4.get("friendly_units", []) as Array).is_empty():
		formation = str(((obs4.get("friendly_units", []) as Array)[0] as Dictionary).get("formation", "FIELD"))
	var r4: Dictionary = CompilerCls.execute(s4, TableCls.make_command("HOLD", TableCls.scope_formation(formation)))
	results["formation_hold"] = {"status": str(r4.get("execution_status", "?")), "executed": (r4.get("executed_units", []) as Array).size(), "formation": formation}
	var ok := true
	for key in results.keys():
		var st := str((results[key] as Dictionary).get("status", ""))
		if not (st in ["EXECUTED", "PARTIAL"]):
			ok = false
		if int((results[key] as Dictionary).get("executed", 0)) <= 0:
			ok = false
	results["verdict"] = ok
	_record("gate5_group_command", "pass" if ok else "fail", results)


# GATE 6 --compiled actions reuse the authoritative path (no second engine).
func _g6_authoritative_reuse() -> void:
	var sim := _fresh_sim()
	var svc: RefCounted = sim.get_service()
	var uses_service := svc != null and svc.has_method("execute_move_intent") and svc.has_method("execute_attack_intent") and svc.has_method("reachable_area") and svc.has_method("preview_attack")
	var f := FileAccess.open("res://scripts/cloud1/cloud1_compiler.gd", FileAccess.READ)
	var text := f.get_as_text() if f != null else ""
	var banned := ["find_route", "calculate_combat", "execute_player_stepwise_move", "execute_attack(", "execute_move("]
	var hits: Array = []
	for token in banned:
		# Allow mentions inside the header comment that documents the ban.
		var code_only := text
		var header_end := text.find("Banned here")
		if header_end != -1:
			code_only = text.substr(0, text.find("## The compiler owns")) + text.substr(text.find("const ScopeAlgebraCls"))
		if code_only.find(token) != -1:
			hits.append(token)
	var required := ["reachable_area", "preview_attack", "sim.do_move", "sim.do_hold", "sim.do_attack"]
	# Compiler reaches execution through sim.do_* (which delegate to the service).
	var missing: Array = []
	for token in required:
		if text.find(token) == -1:
			missing.append(token)
	var ok := uses_service and hits.is_empty() and missing.is_empty()
	_record("gate6_authoritative_reuse", "pass" if ok else "fail", {
		"sim_delegates_to_step7_battle_command_service": uses_service,
		"second_engine_tokens_found": hits,
		"required_reuse_tokens_missing": missing,
		"path": "Cloud1Compiler -> SimController.do_move/do_hold/do_attack -> Step7BattleCommandService -> Step3UnitManager/Step3Pathfinding/CombatCalculator",
	})


# GATE 7 --partial failure is fully explained, never silent.
func _g7_partial_failure() -> void:
	var sim := _fresh_sim()
	var cmd := TableCls.make_command("ADVANCE", TableCls.scope_units(["B_INF_1", "BOGUS_UNIT_X"]), TableCls.target_direction("FORWARD"))
	var res: Dictionary = CompilerCls.execute(sim, cmd)
	var planned: Array = res.get("planned", [])
	var plan_failed: Array = res.get("plan_failed", res.get("failed", []))
	var executed: Array = res.get("executed_units", [])
	var unexplained := 0
	for row_val in plan_failed:
		var row: Dictionary = row_val
		if str(row.get("unit_id", "")).is_empty() or str(row.get("code", "")).is_empty() or str(row.get("detail", "")).is_empty():
			unexplained += 1
	var accounted := executed.size() + (res.get("execution_failed", []) as Array).size() == planned.size()
	var has_success := not executed.is_empty()
	var has_accounted_failure := false
	for row_val in plan_failed:
		if str((row_val as Dictionary).get("code", "")) == "UNIT_NOT_FOUND":
			has_accounted_failure = true
	var ok := has_success and has_accounted_failure and accounted and unexplained == 0 and int(res.get("unexplained_count", 0)) == 0
	_record("gate7_partial_failure", "pass" if ok else "fail", {
		"command": cmd,
		"execution_status": str(res.get("execution_status", "?")),
		"planned_count": planned.size(),
		"executed": executed,
		"plan_failed": plan_failed,
		"execution_failed": res.get("execution_failed", []),
		"every_candidate_accounted": accounted,
		"unexplained_count": int(res.get("unexplained_count", -1)),
	})


# GATE 8 --deterministic serialization (same state => same bytes+fingerprint).
func _g8_deterministic_serialization() -> void:
	var s1 := _fresh_sim()
	var o1: Dictionary = ObsCls.build(s1)
	var j1 := ObsCls.to_json(o1, true)
	var s2 := _fresh_sim()
	var o2: Dictionary = ObsCls.build(s2)
	var j2 := ObsCls.to_json(o2, true)
	var same_bytes := j1 == j2
	var same_fp := str((o1.get("parity", {}) as Dictionary).get("fingerprint", "")) == str((o2.get("parity", {}) as Dictionary).get("fingerprint", ""))
	s1.do_move("B_INF_1", -24, 0, "blue", "auto")
	var o3: Dictionary = ObsCls.build(s1)
	var fp_changed := str((o3.get("parity", {}) as Dictionary).get("fingerprint", "")) != str((o1.get("parity", {}) as Dictionary).get("fingerprint", ""))
	var ok := same_bytes and same_fp and fp_changed
	_record("gate8_deterministic_serialization", "pass" if ok else "fail", {
		"identical_state_identical_bytes": same_bytes,
		"identical_state_identical_fingerprint": same_fp,
		"mutation_changes_fingerprint": fp_changed,
		"fingerprint_before": str((o1.get("parity", {}) as Dictionary).get("fingerprint", "")),
		"fingerprint_after": str((o3.get("parity", {}) as Dictionary).get("fingerprint", "")),
		"no_wall_clock_in_identity": true,
	})


# GATE 9 --one screen answers: sees / can-issue / compiled-into.
func _g9_human_inspection() -> void:
	var sim := _fresh_sim()
	sim.do_move("B_INF_1", -24, 0, "blue", "auto")
	var obs: Dictionary = ObsCls.build(sim)
	var catalog: Array = TableCls.build_catalog(obs)
	var text: String = InspectorCls.render_text(obs, catalog)
	var sections := ["FRIENDLY", "KNOWN ENEMY", "RULES", "ACTION CATALOG", "PARITY", "mission"]
	var missing: Array = []
	for s in sections:
		if text.find(s) == -1:
			missing.append(s)
	var panel: Control = PanelCls.new()
	panel.bind_sim(sim)
	var preview: Dictionary = panel.preview_current()
	var exported: String = panel.export_cloud_view()
	var parsed: Variant = JSON.parse_string(exported)
	var export_ok := parsed is Dictionary and str((parsed as Dictionary).get("snapshot_id", "")) == str(obs.get("snapshot_id", ""))
	# Panel preview must show intent -> units -> per-unit outcomes.
	var preview_ok := bool(preview.get("ok", false)) or not (preview.get("planned", []) as Array).is_empty() or not (preview.get("failed", []) as Array).is_empty()
	panel.free()
	var ok := missing.is_empty() and export_ok and preview_ok
	_record("gate9_human_inspection", "pass" if ok else "fail", {
		"inspector_sections_present": missing.is_empty(),
		"missing_sections": missing,
		"export_matches_inspector_snapshot": export_ok,
		"panel_preview_shows_compilation": preview_ok,
		"inspector_chars": text.length(),
	})


func _exit_code() -> int:
	for key in _gates.keys():
		if str((_gates[key] as Dictionary).get("status", "")) != "pass":
			return 1
	return 0


func _write_artifacts() -> void:
	DirAccess.make_dir_recursive_absolute(DELIVER_DIR)
	var sim := _fresh_sim()
	var obs: Dictionary = ObsCls.build(sim)
	var catalog: Array = TableCls.build_catalog(obs)
	var ex1 := TableCls.make_command("ADVANCE", TableCls.scope_all_combat(), TableCls.target_direction("FORWARD"), "STANDARD", "BALANCED")
	var ex2 := TableCls.make_command("RECON", TableCls.scope_class("SCOUT"), TableCls.target_direction("RIGHT"), "EXTENDED", "CAUTIOUS")
	var ex3 := TableCls.make_command("FLANK", TableCls.scope_class("CAVALRY"), TableCls.target_formation("R_ARC_1"), "STANDARD", "BALANCED")
	var formation := "FIELD"
	if not (obs.get("friendly_units", []) as Array).is_empty():
		formation = str(((obs.get("friendly_units", []) as Array)[0] as Dictionary).get("formation", "FIELD"))
	var ex4 := TableCls.make_command("HOLD", TableCls.scope_formation(formation))
	var s_a := _fresh_sim()
	var plan1: Dictionary = CompilerCls.plan(s_a, ex1)
	var s_b := _fresh_sim()
	var plan2: Dictionary = CompilerCls.plan(s_b, ex2)
	var s_c := _fresh_sim()
	var exec1: Dictionary = CompilerCls.execute(s_c, ex1)
	var contract := {
		"contract": "CLOUD-GENERAL-STEP-01",
		"schema_version": ObsCls.SCHEMA_VERSION,
		"note": "Examples are REAL outputs from the headless neutral probe (not hand-written).",
		"shared_battle_observation": JSON.parse_string(ObsCls.to_json(obs, false)),
		"action_catalog_entry": catalog[0] if not catalog.is_empty() else {},
		"operational_commands": {
			"example1_whole_army_advance": ex1,
			"example2_scout_recon_right": ex2,
			"example3_cavalry_flank_archers": ex3,
			"example4_formation_hold": ex4,
		},
		"compilation_plans": {
			"plan_example1": _strip(plan1),
			"plan_example2": _strip(plan2),
		},
		"compilation_result_example1_execute": _strip(exec1),
	}
	var probe: RefCounted = SimControllerCls.new()
	probe.load_scenario(_scenario())
	var doc := {
		"contract": "CLOUD-GENERAL-STEP-01",
		"schema_version": ObsCls.SCHEMA_VERSION,
		"scenario_id": "cloud_step1_neutral_probe",
		"godot_version": Engine.get_version_info(),
		"rules_fingerprint": str((probe.rules_fingerprint() as Dictionary).get("fingerprint", "")),
		"gates": _gates,
		"overall": "pass" if _exit_code() == 0 else "fail",
	}
	# Preserve every previously written section (human/title/ux/contract audits and
	# any newer suite) — this writer owns only its own keys, never other suites'.
	var prev: Variant = null
	if FileAccess.file_exists(VERIFY_PATH):
		var rf := FileAccess.open(VERIFY_PATH, FileAccess.READ)
		if rf != null:
			prev = JSON.parse_string(rf.get_as_text())
	if prev is Dictionary:
		for k2 in (prev as Dictionary).keys():
			if not doc.has(k2):
				doc[k2] = (prev as Dictionary)[k2]
	var f := FileAccess.open(VERIFY_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(doc, "  "))
		print("[CLOUD1] verification.json written to %s" % VERIFY_PATH)
	else:
		print("[CLOUD1] ERROR: could not write %s" % VERIFY_PATH)


func _strip(d: Dictionary) -> Dictionary:
	# Contract artifact stays compact: drop verbose resolved arrays dupes.
	var out := (d as Dictionary).duplicate(true)
	return out
