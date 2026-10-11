extends SceneTree

## CLASS-OPTION OPT RUNNER (DEV research): OPT-01..20 for the
## pre-deterministic six-option class algorithm. Sim-level except where
## noted; zero network. Writes CLASS-OPTION-MODEL-VIEW/verification_opt.json
## and exits 0 only when every gate passes.

const SimControllerCls = preload("res://scripts/sim/sim_controller.gd")
const ObsCls = preload("res://scripts/cloud1/cloud1_observation.gd")
const TableCls = preload("res://scripts/cloud1/cloud1_action_table.gd")
const CompilerCls = preload("res://scripts/cloud1/cloud1_compiler.gd")
const OpportunityCls = preload("res://scripts/cloud2/cloud2_opportunity.gd")
const UtilityCls = preload("res://scripts/cloud2/cloud2_utility.gd")
const MissionCls = preload("res://scripts/cloud2/cloud2_mission.gd")
const MissionControllerCls = preload("res://scripts/cloud2/cloud2_mission_controller.gd")
const MissionManagerCls = preload("res://scripts/cloud2/cloud2_mission_manager.gd")
const PlanCls = preload("res://scripts/cloud2/cloud2_general_plan.gd")
const OptionCls = preload("res://scripts/cloud2/cloud2_class_option.gd")
const SolverCls = preload("res://scripts/cloud2/cloud2_class_option_solver.gd")

const VERIFY_PATH := "D:/Game development/.workflow/deliverables/CLASS-OPTION-MODEL-VIEW/verification_opt.json"

var _records: Array = []


func _init() -> void:
	_run()


func _run() -> void:
	DirAccess.make_dir_recursive_absolute("D:/Game development/.workflow/deliverables/CLASS-OPTION-MODEL-VIEW")
	_opt_01_six_slots()
	_opt_02_slot_order()
	_opt_03_schema()
	_opt_04_masks_preserved()
	_opt_05_mask_reasons()
	_opt_06_mission_compatibility()
	_opt_07_doctrine_scores_only()
	_opt_08_infantry()
	_opt_09_archer()
	_opt_10_spearman()
	_opt_11_cavalry()
	_opt_12_scout()
	_opt_13_hq()
	_opt_14_target_resolution()
	_opt_15_movement_resolution()
	_opt_16_sequential_revalidation()
	_opt_17_compiler_authoritative()
	_opt_18_executor_authoritative()
	_opt_19_deterministic()
	_opt_20_hier_invariants()
	_write_and_quit()


func _record(tag: String, verdict: String, evidence: Dictionary) -> void:
	_records.append({"gate": tag, "verdict": verdict, "evidence": evidence})
	print("[OPT][%s] %s" % [tag, verdict.to_upper()])


func _exit_code() -> int:
	for r in _records:
		if str(r.get("verdict", "")) != "pass":
			return 1
	return 0


func _write_and_quit() -> void:
	var code := _exit_code()
	var passed := 0
	for r in _records:
		if str(r.get("verdict", "")) == "pass":
			passed += 1
	var payload := {"suite": "CLASS_OPTION_OPT", "exit_code": code,
		"passed": passed, "total": _records.size(), "gates": _records}
	var f := FileAccess.open(VERIFY_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(payload, "\t"))
		f.close()
	print("[OPT] verification.json %s (%d/%d pass)" % [VERIFY_PATH, passed, _records.size()])
	quit(code)


# --- fixtures ---

func _fresh_sim(forces: Array) -> RefCounted:
	var sim: RefCounted = SimControllerCls.new()
	sim.load_scenario({
		"scenario_id": "class_opt", "scenario_version": "1.0.0", "seed": 11,
		"mission_contract": {"primary_objective": "destroy_all_red", "turn_limit": 12},
		"map": {"bounds": {"q_min": -34, "q_max": -14, "r_min": -8, "r_max": 8},
			"default_terrain": 0, "terrain_overrides": {}, "river_cells": []},
		"forces": forces, "start_turn": 1})
	return sim


func _obs(sim: RefCounted) -> Dictionary:
	return ObsCls.build(sim, "red")


func _red_all_classes() -> Array:
	return [
		{"id": "R_INF_1", "class": "infantry", "faction": "red", "q": -24, "r": 0, "soldiers": 477},
		{"id": "R_ARC_1", "class": "archer", "faction": "red", "q": -22, "r": 0, "soldiers": 290},
		{"id": "R_SPE_1", "class": "spearman", "faction": "red", "q": -24, "r": 2, "soldiers": 340},
		{"id": "R_CAV_1", "class": "cavalry", "faction": "red", "q": -26, "r": 1, "soldiers": 320},
		{"id": "R_SCT_1", "class": "scout", "faction": "red", "q": -23, "r": 3, "soldiers": 120},
		{"id": "R_HQ_1", "class": "hq", "faction": "red", "q": -20, "r": 0, "soldiers": 200},
	]


func _forces_contact() -> Array:
	return [
		{"id": "B_HQ_1", "class": "hq", "faction": "blue", "q": -30, "r": 0, "soldiers": 300},
		{"id": "B_INF_1", "class": "infantry", "faction": "blue", "q": -25, "r": 0, "soldiers": 450},
		{"id": "B_CAV_1", "class": "cavalry", "faction": "blue", "q": -25, "r": 2, "soldiers": 330},
		{"id": "B_ARC_1", "class": "archer", "faction": "blue", "q": -27, "r": 0, "soldiers": 260},
	] + _red_all_classes()


func _forces_open() -> Array:
	return [
		{"id": "B_HQ_1", "class": "hq", "faction": "blue", "q": -33, "r": 0, "soldiers": 300},
		{"id": "B_INF_1", "class": "infantry", "faction": "blue", "q": -32, "r": 0, "soldiers": 450},
		{"id": "B_ARC_1", "class": "archer", "faction": "blue", "q": -33, "r": -1, "soldiers": 260},
	] + _red_all_classes()


func _forces_surround() -> Array:
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


func _mission(task: String, units: Array, area: String = "ANY") -> Dictionary:
	var m := MissionCls.default_mission("M01", task)
	m["area"] = area
	m["assigned_units"] = units
	m["objective"] = {"kind": "NONE"}
	return m


func _decide(sim: RefCounted, obs: Dictionary, m: Dictionary, doctrine: Dictionary = {}, seed_base: int = 11) -> Dictionary:
	var ctrl := MissionControllerCls.new()
	ctrl.setup(m, doctrine if not doctrine.is_empty() else PlanCls.default_doctrine(), seed_base)
	return ctrl.decide(sim, obs, {"turn": 1, "snapshot_id": str(obs.get("snapshot_id", "")),
		"turns_active": 0, "urgency": 0.0, "bounds": sim.map_bounds()})


func _tables(res: Dictionary) -> Array:
	return (res.get("trace", {}) as Dictionary).get("units", [])


func _table_for(res: Dictionary, uid: String) -> Dictionary:
	for t_val in _tables(res):
		if str((t_val as Dictionary).get("unit_id", "")) == uid:
			return t_val
	return {}


func _opt(t: Dictionary, slot: int) -> Dictionary:
	for o_val in (t.get("options", []) as Array):
		if int((o_val as Dictionary).get("slot", -1)) == slot:
			return o_val
	return {}


# --- OPT-01..03: six slots, stable order, stable schema ---

func _opt_01_six_slots() -> void:
	var ev := {}
	var sim := _fresh_sim(_forces_contact())
	var obs := _obs(sim)
	var res := _decide(sim, obs, _mission("FIX", ["R_INF_1", "R_ARC_1", "R_SPE_1", "R_CAV_1", "R_SCT_1", "R_HQ_1"], "CENTER"))
	var tabs := _tables(res)
	ev["tables"] = tabs.size()
	var ok := tabs.size() == 6
	for t_val in tabs:
		var n := ((t_val as Dictionary).get("options", []) as Array).size()
		ev[str((t_val as Dictionary).get("unit_id", "?"))] = n
		ok = ok and n == 6
	_record("opt_01_six_slots", "pass" if ok else "fail", ev)


func _opt_02_slot_order() -> void:
	var ev := {}
	var sim := _fresh_sim(_forces_contact())
	var obs := _obs(sim)
	var res := _decide(sim, obs, _mission("FIX", ["R_INF_1", "R_ARC_1", "R_SPE_1", "R_CAV_1", "R_SCT_1", "R_HQ_1"], "CENTER"))
	var ok := true
	for t_val in _tables(res):
		var t: Dictionary = t_val
		var want: Array = OptionCls.slots_for_class(str(t.get("unit_class", "")))
		var got: Array = []
		for i in range(6):
			got.append(str(_opt(t, i).get("option_id", "?")))
		ev[str(t.get("unit_id", "?"))] = got
		ok = ok and got == want
	_record("opt_02_slot_order", "pass" if ok else "fail", ev)


func _opt_03_schema() -> void:
	var ev := {}
	var sim := _fresh_sim(_forces_contact())
	var obs := _obs(sim)
	var res := _decide(sim, obs, _mission("FIX", ["R_INF_1", "R_ARC_1", "R_SPE_1", "R_CAV_1", "R_SCT_1", "R_HQ_1"], "CENTER"))
	var ok := true
	var checked := 0
	for t_val in _tables(res):
		for o_val in ((t_val as Dictionary).get("options", []) as Array):
			var o: Dictionary = o_val
			checked += 1
			ok = ok and bool(OptionCls.validate_option_schema(o).get("ok", false))
			if not bool(o.get("masked", false)):
				var s := float(o.get("base_score", 0.0)) + float(o.get("mission_score", 0.0)) \
					+ float(o.get("state_score", 0.0)) + float(o.get("doctrine_score", 0.0)) \
					+ float(o.get("risk_score", 0.0))
				ok = ok and absf(s - float(o.get("final_score", 0.0))) < 0.01
	ev["checked"] = checked
	_record("opt_03_schema", "pass" if ok else "fail", ev)


# --- OPT-04..07: masks, reasons, mission voice, doctrine voice ---

func _opt_04_masks_preserved() -> void:
	var ev := {}
	var sim := _fresh_sim(_forces_open())
	var obs := _obs(sim)
	var m := _mission("RESERVE", ["R_CAV_1"])
	(m.get("engagement", {}) as Dictionary)["policy"] = "HOLD_FIRE"
	var res := _decide(sim, obs, m)
	var t := _table_for(res, "R_CAV_1")
	var n := (t.get("options", []) as Array).size()
	var masked := 0
	for o_val in (t.get("options", []) as Array):
		if bool((o_val as Dictionary).get("masked", false)):
			masked += 1
	ev["slots"] = n
	ev["masked"] = masked
	ev["selected"] = str(t.get("selected_id", "?"))
	var ok := n == 6 and masked >= 4 and not str(t.get("selected_id", "?")).is_empty()
	_record("opt_04_masks_preserved", "pass" if ok else "fail", ev)


func _opt_05_mask_reasons() -> void:
	var ev := {}
	var reasons := {}
	# NO_VALID_TARGET: FIX archer, open field, no contact.
	var sim := _fresh_sim(_forces_open())
	var obs := _obs(sim)
	var r1 := _decide(sim, obs, _mission("FIX", ["R_ARC_1"], "CENTER"))
	var t1 := _table_for(r1, "R_ARC_1")
	ev["fire"] = str(_opt(t1, 0).get("mask_reason", "unmasked"))
	# MISSION_CONFLICT: RESERVE cavalry flanks.
	var m2 := _mission("RESERVE", ["R_CAV_1"])
	var r2 := _decide(sim, obs, m2)
	var t2 := _table_for(r2, "R_CAV_1")
	ev["flank_l"] = str(_opt(t2, 1).get("mask_reason", "unmasked"))
	# OBJECTIVE_UNAVAILABLE: PRESS_OBJECTIVE with NONE objective (FIX above).
	ev["press"] = "n/a"
	var simc := _fresh_sim(_forces_contact())
	var obsc := _obs(simc)
	var r3 := _decide(simc, obsc, _mission("FIX", ["R_INF_1"], "CENTER"))
	ev["press"] = str(_opt(_table_for(r3, "R_INF_1"), 4).get("mask_reason", "unmasked"))
	# ALREADY_SATISFIED: KITE with no adjacent threat (archer on a RECON
	# task, where WITHDRAW-kind options are mission-legal), and spearman
	# PROTECT_HQ with the HQ unthreatened.
	var m1b := _mission("RECON", ["R_ARC_1"], "SOUTH")
	var r1b := _decide(sim, obs, m1b)
	ev["kite"] = str(_opt(_table_for(r1b, "R_ARC_1"), 4).get("mask_reason", "unmasked"))
	var r1c := _decide(sim, obs, _mission("FIX", ["R_SPE_1"], "CENTER"))
	ev["prothq"] = str(_opt(_table_for(r1c, "R_SPE_1"), 4).get("mask_reason", "unmasked"))
	# COMPILER_REJECTED or NO_LEGAL_MOVE: surrounded infantry (ADVANCE).
	var sims := _fresh_sim(_forces_surround())
	var obss := _obs(sims)
	var r4 := _decide(sims, obss, _mission("ADVANCE", ["R_INF_1"], "CENTER"))
	ev["surrounded_adv"] = str(_opt(_table_for(r4, "R_INF_1"), 1).get("mask_reason", "unmasked"))
	# WAITING_TRIGGER: dormant mission attacks.
	var m5 := _mission("ATTACK", ["R_INF_1"])
	m5["status"] = "WAITING_TRIGGER"
	var r5 := _decide(simc, obsc, m5)
	ev["waiting_atk"] = str(_opt(_table_for(r5, "R_INF_1"), 0).get("mask_reason", "unmasked"))
	for k in ev.keys():
		reasons[str(ev[k])] = true
	ev["distinct"] = reasons.keys()
	var want := {"NO_VALID_TARGET": true, "MISSION_CONFLICT": true,
		"OBJECTIVE_UNAVAILABLE": true, "ALREADY_SATISFIED": true,
		"WAITING_TRIGGER": true}
	var ok := str(ev["fire"]) == "NO_VALID_TARGET" \
		and str(ev["flank_l"]) == "MISSION_CONFLICT" \
		and str(ev["press"]) == "OBJECTIVE_UNAVAILABLE" \
		and str(ev["kite"]) == "ALREADY_SATISFIED" \
		and str(ev["prothq"]) == "ALREADY_SATISFIED" \
		and (str(ev["surrounded_adv"]) == "COMPILER_REJECTED" or str(ev["surrounded_adv"]) == "NO_LEGAL_MOVE") \
		and str(ev["waiting_atk"]) == "WAITING_TRIGGER"
	for rk in reasons.keys():
		ok = ok and (OptionCls.MASK_REASONS.has(rk) or rk == "unmasked")
	_record("opt_05_mask_reasons", "pass" if ok else "fail", ev)


func _opt_06_mission_compatibility() -> void:
	var ev := {}
	var sim := _fresh_sim(_forces_contact())
	var obs := _obs(sim)
	# RESERVE cavalry: charge/flank suppressed or masked, disengage never conflicted.
	var r := _decide(sim, obs, _mission("RESERVE", ["R_CAV_1"]))
	var t := _table_for(r, "R_CAV_1")
	ev["charge"] = str(_opt(t, 0).get("mask_reason", "unmasked"))
	ev["flank_l"] = str(_opt(t, 1).get("mask_reason", "unmasked"))
	ev["flank_r"] = str(_opt(t, 2).get("mask_reason", "unmasked"))
	ev["disengage"] = str(_opt(t, 5).get("mask_reason", "unmasked"))
	# WITHDRAW infantry: attack masked as mission conflict.
	var r2 := _decide(sim, obs, _mission("WITHDRAW", ["R_INF_1"]))
	ev["w_atk"] = str(_opt(_table_for(r2, "R_INF_1"), 0).get("mask_reason", "unmasked"))
	# ATTACK infantry: attack available (contact) with signature bonus.
	var r3 := _decide(sim, obs, _mission("ATTACK", ["R_INF_1"]))
	var atk := _opt(_table_for(r3, "R_INF_1"), 0)
	ev["a_atk_masked"] = bool(atk.get("masked", true))
	ev["a_atk_mission"] = float(atk.get("mission_score", -1.0))
	var ok := str(ev["flank_l"]) == "MISSION_CONFLICT" \
		and str(ev["flank_r"]) == "MISSION_CONFLICT" \
		and str(ev["disengage"]) != "MISSION_CONFLICT" \
		and str(ev["w_atk"]) == "MISSION_CONFLICT" \
		and not bool(ev["a_atk_masked"]) \
		and float(ev["a_atk_mission"]) == 8.0
	_record("opt_06_mission_compatibility", "pass" if ok else "fail", ev)


func _opt_07_doctrine_scores_only() -> void:
	var ev := {}
	var sim := _fresh_sim(_forces_contact())
	var obs := _obs(sim)
	var calm := PlanCls.default_doctrine()
	calm["aggression"] = 0.0
	calm["tempo"] = 0.0
	var bold := PlanCls.default_doctrine()
	bold["aggression"] = 1.0
	bold["tempo"] = 1.0
	var m := _mission("FIX", ["R_INF_1", "R_ARC_1", "R_CAV_1"], "CENTER")
	var ra := _decide(sim, obs, m, calm)
	var rb := _decide(sim, obs, m, bold)
	var masks_same := true
	var score_moved := false
	for uid in ["R_INF_1", "R_ARC_1", "R_CAV_1"]:
		var ta := _table_for(ra, uid)
		var tb := _table_for(rb, uid)
		for i in range(6):
			var oa := _opt(ta, i)
			var ob := _opt(tb, i)
			masks_same = masks_same and bool(oa.get("masked", false)) == bool(ob.get("masked", false))
			if absf(float(oa.get("final_score", 0.0)) - float(ob.get("final_score", 0.0))) > 0.01:
				score_moved = true
	ev["masks_same"] = masks_same
	ev["score_moved"] = score_moved
	var ok := masks_same and score_moved
	_record("opt_07_doctrine_scores_only", "pass" if ok else "fail", ev)


# --- OPT-08..13: per-class matrices + signature behavior ---

func _opt_08_infantry() -> void:
	var ev := {}
	var sim := _fresh_sim(_forces_contact())
	var obs := _obs(sim)
	var res := _decide(sim, obs, _mission("FIX", ["R_INF_1"], "CENTER"))
	var t := _table_for(res, "R_INF_1")
	var ids: Array = []
	for i in range(6):
		ids.append(str(_opt(t, i).get("option_id", "?")))
	ev["matrix"] = ids
	ev["attack_masked"] = bool(_opt(t, 0).get("masked", true))
	ev["attack_target"] = str(_opt(t, 0).get("resolved_target", ""))
	var ok := ids == (OptionCls.MATRIX["INFANTRY"] as Array) \
		and not bool(ev["attack_masked"]) \
		and not str(ev["attack_target"]).is_empty()
	_record("opt_08_infantry", "pass" if ok else "fail", ev)


func _opt_09_archer() -> void:
	var ev := {}
	var sim := _fresh_sim(_forces_contact())
	var obs := _obs(sim)
	var res := _decide(sim, obs, _mission("FIX", ["R_ARC_1"], "CENTER"))
	var t := _table_for(res, "R_ARC_1")
	var ids: Array = []
	for i in range(6):
		ids.append(str(_opt(t, i).get("option_id", "?")))
	ev["matrix"] = ids
	ev["fire_masked"] = bool(_opt(t, 0).get("masked", true))
	var simo := _fresh_sim(_forces_open())
	var reso := _decide(simo, _obs(simo), _mission("FIX", ["R_ARC_1"], "CENTER"))
	ev["fire_open"] = str(_opt(_table_for(reso, "R_ARC_1"), 0).get("mask_reason", "unmasked"))
	var ok := ids == (OptionCls.MATRIX["ARCHER"] as Array) \
		and not bool(ev["fire_masked"]) \
		and str(ev["fire_open"]) == "NO_VALID_TARGET"
	_record("opt_09_archer", "pass" if ok else "fail", ev)


func _opt_10_spearman() -> void:
	var ev := {}
	var sim := _fresh_sim(_forces_contact())
	var obs := _obs(sim)
	var res := _decide(sim, obs, _mission("FIX", ["R_SPE_1"], "CENTER"))
	var t := _table_for(res, "R_SPE_1")
	var ids: Array = []
	for i in range(6):
		ids.append(str(_opt(t, i).get("option_id", "?")))
	ev["matrix"] = ids
	ev["atkcav_masked"] = bool(_opt(t, 0).get("masked", true))
	ev["atkcav_target"] = str(_opt(t, 0).get("resolved_target", ""))
	# Without cavalry contact the cavalry-hunter masks honestly.
	var simo := _fresh_sim(_forces_open())
	var reso := _decide(simo, _obs(simo), _mission("FIX", ["R_SPE_1"], "CENTER"))
	ev["atkcav_open"] = str(_opt(_table_for(reso, "R_SPE_1"), 0).get("mask_reason", "unmasked"))
	var ok := ids == (OptionCls.MATRIX["SPEARMAN"] as Array) \
		and not bool(ev["atkcav_masked"]) \
		and str(ev["atkcav_target"]) == "B_CAV_1" \
		and str(ev["atkcav_open"]) == "NO_VALID_TARGET"
	_record("opt_10_spearman", "pass" if ok else "fail", ev)


func _opt_11_cavalry() -> void:
	var ev := {}
	var sim := _fresh_sim(_forces_open())
	var obs := _obs(sim)
	var res := _decide(sim, obs, _mission("FLANK", ["R_CAV_1"], "SOUTH"))
	var t := _table_for(res, "R_CAV_1")
	var ids: Array = []
	for i in range(6):
		ids.append(str(_opt(t, i).get("option_id", "?")))
	ev["matrix"] = ids
	var fl: Dictionary = _opt(t, 1).get("resolved_command", {})
	ev["flank_l_action"] = str(fl.get("action", "?"))
	ev["flank_l_dir"] = str((fl.get("target", {}) as Dictionary).get("direction", "?"))
	ev["selected"] = str(t.get("selected_id", "?"))
	var ok := ids == (OptionCls.MATRIX["CAVALRY"] as Array) \
		and str(ev["flank_l_action"]) == "FLANK" \
		and str(ev["flank_l_dir"]) == "LEFT"
	_record("opt_11_cavalry", "pass" if ok else "fail", ev)


func _opt_12_scout() -> void:
	var ev := {}
	var sim := _fresh_sim(_forces_open())
	var obs := _obs(sim)
	var res := _decide(sim, obs, _mission("RECON", ["R_SCT_1"], "SOUTH"))
	var t := _table_for(res, "R_SCT_1")
	var ids: Array = []
	for i in range(6):
		ids.append(str(_opt(t, i).get("option_id", "?")))
	ev["matrix"] = ids
	var rf: Dictionary = _opt(t, 0).get("resolved_command", {})
	ev["recon_action"] = str(rf.get("action", "?"))
	ev["selected"] = str(t.get("selected_id", "?"))
	var ok := ids == (OptionCls.MATRIX["SCOUT"] as Array) \
		and str(ev["recon_action"]) == "RECON" \
		and str(t.get("selected_id", "")).begins_with("RECON_")
	_record("opt_12_scout", "pass" if ok else "fail", ev)


func _opt_13_hq() -> void:
	var ev := {}
	var sim := _fresh_sim(_forces_open())
	var obs := _obs(sim)
	var res := _decide(sim, obs, _mission("HOLD", ["R_HQ_1"]))
	var t := _table_for(res, "R_HQ_1")
	var ids: Array = []
	for i in range(6):
		ids.append(str(_opt(t, i).get("option_id", "?")))
	ev["matrix"] = ids
	ev["hold_masked"] = bool(_opt(t, 0).get("masked", true))
	ev["follow"] = str(_opt(t, 1).get("mask_reason", "unmasked"))
	ev["reloc_l"] = str(_opt(t, 2).get("mask_reason", "unmasked"))
	ev["reloc_c"] = str(_opt(t, 4).get("mask_reason", "unmasked"))
	ev["withdraw"] = str(_opt(t, 5).get("mask_reason", "unmasked"))
	ev["selected"] = str(t.get("selected_id", "?"))
	var ok := ids == (OptionCls.MATRIX["HQ"] as Array) \
		and not bool(ev["hold_masked"]) \
		and str(ev["follow"]) == "MISSION_CONFLICT" \
		and str(ev["reloc_l"]) == "ALREADY_SATISFIED" \
		and str(ev["reloc_c"]) == "ALREADY_SATISFIED" \
		and str(ev["withdraw"]) == "ALREADY_SATISFIED" \
		and str(t.get("selected_id", "?")) == "HOLD_REAR"
	_record("opt_13_hq", "pass" if ok else "fail", ev)


# --- OPT-14..16: resolution + sequential revalidation ---

func _opt_14_target_resolution() -> void:
	var ev := {}
	var sim := _fresh_sim(_forces_contact())
	var obs := _obs(sim)
	var res := _decide(sim, obs, _mission("FIX", ["R_INF_1", "R_ARC_1", "R_SPE_1"], "CENTER"))
	var legal := {}
	for a_val in OpportunityCls.legal_attacks(sim, ["R_INF_1", "R_ARC_1", "R_SPE_1"], obs):
		legal[str((a_val as Dictionary).get("attacker_id", "")) + ">" + str((a_val as Dictionary).get("target_id", ""))] = true
	var ok := true
	var checked := 0
	for t_val in _tables(res):
		var t: Dictionary = t_val
		for o_val in (t.get("options", []) as Array):
			var o: Dictionary = o_val
			if str(o.get("kind", "")) != "ATTACK" or bool(o.get("masked", false)):
				continue
			checked += 1
			var key := str(t.get("unit_id", "?")) + ">" + str(o.get("resolved_target", ""))
			ok = ok and legal.has(key)
			var scores: Array = o.get("target_scores", [])
			ok = ok and not scores.is_empty()
			for i in range(scores.size() - 1):
				ok = ok and float((scores[i] as Dictionary).get("score", 0.0)) >= float((scores[i + 1] as Dictionary).get("score", 0.0))
	ev["checked"] = checked
	ok = ok and checked >= 2
	_record("opt_14_target_resolution", "pass" if ok else "fail", ev)


func _opt_15_movement_resolution() -> void:
	var ev := {}
	var sim := _fresh_sim(_forces_open())
	var obs := _obs(sim)
	var res := _decide(sim, obs, _mission("FIX", ["R_INF_1", "R_ARC_1", "R_SPE_1", "R_CAV_1", "R_SCT_1"], "CENTER"))
	var ok := true
	var checked := 0
	for t_val in _tables(res):
		var t: Dictionary = t_val
		var cmd: Dictionary = t.get("resolved_command", {})
		if cmd.is_empty():
			continue
		checked += 1
		ok = ok and bool(TableCls.validate_command(cmd).get("ok", false))
		ok = ok and bool(CompilerCls.plan(sim, cmd, "", "red").get("ok", false))
		var act := str(cmd.get("action", ""))
		var dest: Array = t.get("resolved_destination", [])
		if act == "HOLD":
			ok = ok and dest.is_empty()
		elif act == "ATTACK":
			ok = ok and not str(t.get("resolved_target", "")).is_empty()
		else:
			var area: Dictionary = OpportunityCls.reachable(sim, str(t.get("unit_id", "")))
			var inside := false
			for h_val in (area.get("reachable", []) as Array):
				var hq := 9999
				var hr := 9999
				if h_val is Dictionary:
					hq = int((h_val as Dictionary).get("q", 9999))
					hr = int((h_val as Dictionary).get("r", 9999))
				elif h_val is Array and (h_val as Array).size() >= 2:
					hq = int((h_val as Array)[0])
					hr = int((h_val as Array)[1])
				if dest.size() >= 2 and hq == int(dest[0]) and hr == int(dest[1]):
					inside = true
			ok = ok and inside
	ev["checked"] = checked
	ok = ok and checked == 5
	_record("opt_15_movement_resolution", "pass" if ok else "fail", ev)


func _opt_16_sequential_revalidation() -> void:
	var ev := {}
	var sim := _fresh_sim(_forces_open())
	var obs := _obs(sim)
	var mgr := MissionManagerCls.new()
	var plan := PlanCls.default_plan(obs, 1)
	plan["based_on_snapshot"] = str(obs.get("snapshot_id", ""))
	var applied := mgr.apply_plan(plan, 1, str(obs.get("snapshot_id", "")), str(obs.get("battle_id", "")))
	ev["applied"] = bool(applied.get("ok", false))
	var d1: Dictionary = mgr.red_turn(sim, obs)
	var orders1: Array = d1.get("orders", [])
	ev["orders1"] = orders1.size()
	for o_val in orders1:
		var octx: Dictionary = (o_val as Dictionary).get("exec_ctx", {})
		if not octx.is_empty():
			CompilerCls.execute(sim, (o_val as Dictionary).get("order", {}), "", "red", octx)
		else:
			CompilerCls.execute(sim, (o_val as Dictionary).get("order", {}), "", "red")
	var obs2 := _obs(sim)
	var acted := 0
	for u_val in (obs2.get("friendly_units", []) as Array):
		if str((u_val as Dictionary).get("status", "")) != "ready":
			acted += 1
	ev["acted"] = acted
	var d2: Dictionary = mgr.red_turn(sim, obs2)
	var replan_ok := true
	for o2_val in (d2.get("orders", []) as Array):
		replan_ok = replan_ok and bool(CompilerCls.plan(sim, (o2_val as Dictionary).get("order", {}), "", "red").get("ok", false))
	ev["orders2"] = (d2.get("orders", []) as Array).size()
	ev["replan_ok"] = replan_ok
	var ok := bool(ev["applied"]) and orders1.size() >= 1 and acted >= 1 and replan_ok
	_record("opt_16_sequential_revalidation", "pass" if ok else "fail", ev)


# --- OPT-17..19: compiler / executor authority + determinism ---

func _opt_17_compiler_authoritative() -> void:
	var ev := {}
	var sim := _fresh_sim(_forces_contact())
	var obs := _obs(sim)
	var res := _decide(sim, obs, _mission("FIX", ["R_INF_1", "R_ARC_1", "R_CAV_1"], "CENTER"))
	var ok := true
	var n := 0
	for o_val in (res.get("orders", []) as Array):
		var cmd: Dictionary = (o_val as Dictionary).get("command", {})
		n += 1
		ok = ok and bool(TableCls.validate_command(cmd).get("ok", false))
		ok = ok and bool(CompilerCls.plan(sim, cmd, "", "red").get("ok", false))
	# A tampered order (phantom target) must fail the compiler.
	var bad := {"action": "ATTACK", "scope": TableCls.scope_units(["R_INF_1"]),
		"target": TableCls.target_formation("B_NOPE"), "stance": "BALANCED"}
	ev["tampered_ok"] = bool(CompilerCls.plan(sim, bad, "", "red").get("ok", false))
	ok = ok and not bool(ev["tampered_ok"])
	# No selected option is ever masked.
	for t_val in _tables(res):
		var t: Dictionary = t_val
		if bool(t.get("fallback", false)):
			continue
		var sel := _opt(t, int(t.get("selected_slot", -99)))
		ok = ok and not sel.is_empty() and not bool(sel.get("masked", true))
	ev["orders"] = n
	ok = ok and n >= 1
	_record("opt_17_compiler_authoritative", "pass" if ok else "fail", ev)


func _opt_18_executor_authoritative() -> void:
	var ev := {}
	var sim := _fresh_sim(_forces_open())
	var obs := _obs(sim)
	var fp0 := str(sim.fingerprint())
	_decide(sim, obs, _mission("FIX", ["R_INF_1", "R_ARC_1", "R_CAV_1"], "CENTER"))
	var fp1 := str(sim.fingerprint())
	ev["decide_pure"] = fp0 == fp1
	var res := _decide(sim, obs, _mission("FIX", ["R_INF_1", "R_ARC_1", "R_CAV_1"], "CENTER"))
	var moved := 0
	for o_val in (res.get("orders", []) as Array):
		var ex: Dictionary = CompilerCls.execute(sim, (o_val as Dictionary).get("command", {}), "", "red")
		moved += ((ex.get("executed_units", []) as Array).size())
	var fp2 := str(sim.fingerprint())
	ev["executed"] = moved
	ev["mutated"] = fp0 != fp2
	var ok := bool(ev["decide_pure"]) and moved >= 1 and bool(ev["mutated"])
	_record("opt_18_executor_authoritative", "pass" if ok else "fail", ev)


func _opt_19_deterministic() -> void:
	var ev := {}
	var sim := _fresh_sim(_forces_contact())
	var obs := _obs(sim)
	var m := _mission("FIX", ["R_INF_1", "R_ARC_1", "R_SPE_1", "R_CAV_1", "R_SCT_1"], "CENTER")
	var a := _decide(sim, obs, m)
	var b := _decide(sim, obs, m)
	var ja := JSON.stringify(a)
	var jb := JSON.stringify(b)
	ev["bytes"] = ja.length()
	ev["identical"] = ja == jb
	var ok := ja == jb and ja.length() > 1000
	_record("opt_19_deterministic", "pass" if ok else "fail", ev)


# --- OPT-20: HIER controller-facing invariants still hold ---

func _opt_20_hier_invariants() -> void:
	var ev := {}
	# h4 shape: FIX decides a dry-ok command, ACTIVE.
	var sim := _fresh_sim(_forces_contact())
	var obs := _obs(sim)
	var m4 := _mission("FIX", ["R_INF_1", "R_ARC_1"], "CENTER")
	var r4 := _decide(sim, obs, m4)
	var cmd4: Dictionary = r4.get("command", {})
	ev["h4"] = [not cmd4.is_empty(), str(r4.get("status_hint", "?")),
		bool(CompilerCls.plan(sim, cmd4, "", "red").get("ok", false))]
	# h6 shape (six-option architecture): RESERVE + HOLD_FIRE cavalry IN
	# CONTACT disengages to reserve (never attacks); unexposed it holds.
	var m6 := _mission("RESERVE", ["R_CAV_1"])
	(m6.get("engagement", {}) as Dictionary)["policy"] = "HOLD_FIRE"
	var r6 := _decide(sim, obs, m6)
	ev["h6_action"] = str((r6.get("command", {}) as Dictionary).get("action", "?"))
	var atk_rows := 0
	for c_val in ((r6.get("trace", {}) as Dictionary).get("candidates", []) as Array):
		if str((c_val as Dictionary).get("kind", "")) == "ATTACK":
			atk_rows += 1
	ev["h6_attack_rows"] = atk_rows
	var simo := _fresh_sim(_forces_open())
	var r6b := _decide(simo, _obs(simo), m6)
	ev["h6b_action"] = str((r6b.get("command", {}) as Dictionary).get("action", "?"))
	# h7 shape: surrounded ADVANCE blocks + mission review fires.
	var sims := _fresh_sim(_forces_surround())
	var obss := _obs(sims)
	var mgr := MissionManagerCls.new()
	var plan := {
		"plan_version": 1, "based_on_snapshot": str(obss.get("snapshot_id", "")),
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
	mgr.apply_plan(plan, 1, str(obss.get("snapshot_id", "")), str(obss.get("battle_id", "")))
	var d7: Dictionary = mgr.red_turn(sims, obss)
	var m1 := ""
	for s_val in (d7.get("statuses", []) as Array):
		if str((s_val as Dictionary).get("mission_id", "")) == "M01":
			m1 = str((s_val as Dictionary).get("status", ""))
	ev["h7_m01"] = m1
	ev["h7_review"] = str((d7.get("review", {}) as Dictionary).get("trigger", ""))
	# h18 shape: FLANK cavalry executes.
	var mf := _mission("FLANK", ["R_CAV_1"])
	mf["objective"] = {"kind": "ENEMY_FORMATION", "unit_id": "B_INF_1"}
	var rf := _decide(sim, obs, mf)
	var cmdf: Dictionary = rf.get("command", {})
	var gate_ok := bool(TableCls.validate_command(cmdf).get("ok", false))
	var dry_ok := bool(CompilerCls.plan(sim, cmdf, "", "red").get("ok", false))
	var ex: Dictionary = CompilerCls.execute(sim, cmdf, "", "red")
	ev["h18"] = [gate_ok, dry_ok, str(ex.get("execution_status", "?")),
		(ex.get("executed_units", []) as Array).size()]
	var ok := bool(ev["h4"][0]) and str(ev["h4"][1]) == "ACTIVE" and bool(ev["h4"][2]) \
		and str(ev["h6_action"]) == "WITHDRAW" and int(ev["h6_attack_rows"]) == 0 \
		and str(ev["h6b_action"]) == "HOLD" \
		and str(ev["h7_m01"]) == "BLOCKED" and str(ev["h7_review"]) == "MISSION_BLOCKED" \
		and bool((ev["h18"] as Array)[0]) and bool((ev["h18"] as Array)[1]) \
		and str((ev["h18"] as Array)[2]) in ["EXECUTED", "PARTIAL"] \
		and int((ev["h18"] as Array)[3]) >= 1
	_record("opt_20_hier_invariants", "pass" if ok else "fail", ev)
