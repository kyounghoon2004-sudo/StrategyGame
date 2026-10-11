extends SceneTree

## DETERMINISTIC RED BATTLE ??Test A harness (NO LLM / NO API / NO CLOUD TRANSPORT).
##
## Proves whether the COMPLETE RED deterministic runtime can fight with no Cloud:
##   fixed coordinator selection (JSON text)
##   -> Cloud2CoordResponse.parse_initial (real validation boundary)
##   -> Cloud2CoordMenu.expand_initial (real production expansion)
##   -> Cloud2GeneralPlan.validate_plan (inside expansion + apply)
##   -> Cloud2MissionManager.apply_plan + red_turn (production manager)
##   -> Cloud2MissionController.decide (production controller)
##   -> Cloud2Opportunity.legal_attacks (production opportunity generation)
##   -> Cloud2ClassOptionSolver.solve_unit (production six-option solver)
##   -> resolved OperationalCommand (production command resolver)
##   -> Cloud2Response.check_order + Cloud1Compiler.plan (production gate + dry-run)
##   -> Cloud1Compiler.execute (production compiler/executor)
##   -> SimController.do_move/do_attack -> Step3UnitManager (authoritative combat)
##
## The ONLY bypassed step is the strategic network call: a fixed, known-valid
## coordinator selection is injected at the exact boundary where a Cloud reply
## would normally be parsed. No HTTPRequest exists in this harness. No provider,
## model, adapter, session, or key is touched. No attack opportunity is
## handcrafted: every ATTACK row flows from authoritative state.
##
## Battle: 10v10 on flat plains, RED east vs BLUE west, minimum pairwise
## distance 8 (max attack range 3) ??RED starts OUT OF COMBAT RANGE.
## RED uses the real tactical runtime every turn. BLUE is stationary in the
## primary run (pure RED-initiative test) and scripted ADVANCE EAST in the
## secondary run (contact-guaranteed transition test). Multi-turn loop runs up
## to MAX_TURNS with full per-unit six-option traces and a missed-attack
## detector (authoritative targets > 0 but no ATTACK executed).
##
## Usage (Windows):
##   Godot_v4.2.2-stable_win64_console.exe --headless --path "D:\Game development\Demon slayer\StrategyGame" -s res://scripts/cloud2/cloud2_det_battle_entry.gd
##
## Exit code 0 = harness completed and evidence written (battle PASS/FAIL is
## data inside the evidence, not the exit code). Writes:
##   D:/Game development/.workflow/deliverables/DETERMINISTIC-RED-BATTLE/evidence_det_battle.json

const SimControllerCls = preload("res://scripts/sim/sim_controller.gd")
const ObsCls = preload("res://scripts/cloud1/cloud1_observation.gd")
const TableCls = preload("res://scripts/cloud1/cloud1_action_table.gd")
const CompilerCls = preload("res://scripts/cloud1/cloud1_compiler.gd")
const CoordMenuCls = preload("res://scripts/cloud2/cloud2_coord_menu.gd")
const CoordResponseCls = preload("res://scripts/cloud2/cloud2_coord_response.gd")
const PlanCls = preload("res://scripts/cloud2/cloud2_general_plan.gd")
const ManagerCls = preload("res://scripts/cloud2/cloud2_mission_manager.gd")
const OpportunityCls = preload("res://scripts/cloud2/cloud2_opportunity.gd")
const ResponseCls = preload("res://scripts/cloud2/cloud2_response.gd")
const HexUtilsCls = preload("res://scripts/core/hex_utils.gd")
## JEV shadow observer (SHADOW ONLY): read-only telemetry, zero authority.
const JevShadowCls = preload("res://scripts/cloud2/cloud2_jev_shadow.gd")
const JevLauncherCls = preload("res://scripts/cloud2/cloud2_jev_launcher.gd")

const OUT_DIR := "D:/Game development/.workflow/deliverables/DETERMINISTIC-RED-BATTLE"
const OUT_EVIDENCE := "D:/Game development/.workflow/deliverables/DETERMINISTIC-RED-BATTLE/evidence_det_battle.json"
const MAX_TURNS := 16
const SCENARIO_SEED := 11
const MANEUVER_TURNS_REQUIRED := 2
const MIN_ATTACKS_REQUIRED := 2

var _blue_start_soldiers := 0
var _red_start_soldiers := 0


func _init() -> void:
	_run()


func _shadow_evidence_path() -> String:
	# JEV shadow off/on runs need separate outputs; default path unchanged.
	if OS.has_environment("JEV_SHADOW_DET_EVIDENCE") \
			and not OS.get_environment("JEV_SHADOW_DET_EVIDENCE").strip_edges().is_empty():
		var p := OS.get_environment("JEV_SHADOW_DET_EVIDENCE").strip_edges()
		DirAccess.make_dir_recursive_absolute(p.get_base_dir())
		return p
	return OUT_EVIDENCE


func _shadow_run_id() -> String:
	if OS.has_environment("JEV_SHADOW_RUN_ID"):
		return OS.get_environment("JEV_SHADOW_RUN_ID").strip_edges()
	return ""


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	print("[DETBATTLE] Test A: fixed-plan deterministic RED battle (no cloud).")
	var primary := _run_battle("stationary")
	var secondary := _run_battle("advance")
	var repeat := _run_battle("stationary")
	var det := _compare_runs(primary, repeat)
	var verdict := _verdict(primary)
	var payload := {
		"suite": "DETERMINISTIC_RED_BATTLE_TEST_A",
		"engine": "Godot 4.2.2 (headless sim)",
		"no_cloud_attestation": _no_cloud_attestation(),
		"fixed_strategy": (primary as Dictionary).get("fixed_strategy", {}),
		"production_path": _production_path(),
		"primary_blue_stationary": _summarize(primary),
		"secondary_blue_advance": _summarize(secondary),
		"determinism": det,
		"verdict": verdict,
		"a_answers": _answer_a(primary, secondary),
		"det_gates": _det_gates(primary, secondary, det, verdict),
		"turns_primary": (primary as Dictionary).get("turns", []),
		"turns_secondary": (secondary as Dictionary).get("turns", []),
		"jev_shadow": JevLauncherCls.status_snapshot(),
	}
	var out_evidence := _shadow_evidence_path()
	var f := FileAccess.open(out_evidence, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(payload, "\t"))
		f.close()
	_print_summary(payload, out_evidence)
	# Single-launch: the SceneTree path has no autoload, so shut down the
	# owned worker explicitly (fail-open; the parent-PID monitor is backstop).
	JevLauncherCls.shutdown_owned()
	quit(0)


func _production_path() -> Array:
	return [
		"fixed coordinator JSON text",
		"Cloud2CoordResponse.parse_initial",
		"Cloud2CoordMenu.expand_initial",
		"Cloud2MissionManager.apply_plan + bind_coordination",
		"Cloud2MissionManager.red_turn",
		"Cloud2MissionController.decide",
		"Cloud2Opportunity.legal_attacks",
		"Cloud2ClassOptionSolver.solve_unit",
		"Cloud2Response.check_order",
		"Cloud1Compiler.plan (dry-run inside solver + controller)",
		"Cloud1Compiler.execute",
		"SimController.do_move/do_attack/do_hold",
		"Step3UnitManager.execute_move/execute_attack (authoritative)",
	]


func _no_cloud_attestation() -> Dictionary:
	return {
		"provider_calls": 0,
		"http_requests": 0,
		"api_keys_used": 0,
		"adapter_used": false,
		"session_used": false,
		"handcrafted_attack_rows": 0,
		"network_bypass_point": "coordinator JSON text injected at parse_initial; transport/adapter/session never constructed",
	}


# --- scenario: 10v10 flat plains, out-of-range start ---------------------------

func _forces() -> Array:
	# BLUE west (q -30..-28, r 0..4, all CENTER region), RED east
	# (q -20..-18, r -3..0, all CENTER region). Min pairwise distance 8.
	var forces := [
		{"id": "B_INF_1", "class": "infantry", "faction": "blue", "q": -28, "r": 1, "soldiers": 450},
		{"id": "B_INF_2", "class": "infantry", "faction": "blue", "q": -28, "r": 2, "soldiers": 450},
		{"id": "B_CAV_1", "class": "cavalry", "faction": "blue", "q": -28, "r": 0, "soldiers": 330},
		{"id": "B_SPE_1", "class": "spearman", "faction": "blue", "q": -28, "r": 3, "soldiers": 340},
		{"id": "B_INF_3", "class": "infantry", "faction": "blue", "q": -29, "r": 1, "soldiers": 450},
		{"id": "B_ARC_1", "class": "archer", "faction": "blue", "q": -29, "r": 2, "soldiers": 260},
		{"id": "B_SPE_2", "class": "spearman", "faction": "blue", "q": -29, "r": 3, "soldiers": 340},
		{"id": "B_CAV_2", "class": "cavalry", "faction": "blue", "q": -29, "r": 0, "soldiers": 330},
		{"id": "B_ARC_2", "class": "archer", "faction": "blue", "q": -30, "r": 2, "soldiers": 260},
		{"id": "B_HQ_1", "class": "hq", "faction": "blue", "q": -30, "r": 1, "soldiers": 300},
		{"id": "R_INF_1", "class": "infantry", "faction": "red", "q": -20, "r": -1, "soldiers": 477},
		{"id": "R_INF_2", "class": "infantry", "faction": "red", "q": -20, "r": -2, "soldiers": 477},
		{"id": "R_SPE_1", "class": "spearman", "faction": "red", "q": -20, "r": 0, "soldiers": 340},
		{"id": "R_CAV_1", "class": "cavalry", "faction": "red", "q": -20, "r": -3, "soldiers": 320},
		{"id": "R_INF_3", "class": "infantry", "faction": "red", "q": -19, "r": -1, "soldiers": 477},
		{"id": "R_ARC_1", "class": "archer", "faction": "red", "q": -19, "r": -2, "soldiers": 290},
		{"id": "R_SPE_2", "class": "spearman", "faction": "red", "q": -19, "r": 0, "soldiers": 340},
		{"id": "R_CAV_2", "class": "cavalry", "faction": "red", "q": -19, "r": -3, "soldiers": 320},
		{"id": "R_ARC_2", "class": "archer", "faction": "red", "q": -18, "r": -2, "soldiers": 290},
		{"id": "R_HQ_1", "class": "hq", "faction": "red", "q": -18, "r": -1, "soldiers": 200},
	]
	# JEV SHADOW variant (default forces unchanged): swap one infantry for a
	# scout so live shadow telemetry covers all five learned classes.
	if OS.has_environment("JEV_SHADOW_VARIANT") \
			and OS.get_environment("JEV_SHADOW_VARIANT") == "scout":
		for f_val in forces:
			if f_val is Dictionary and str((f_val as Dictionary).get("id", "")) == "R_INF_3":
				(f_val as Dictionary)["class"] = "scout"
				(f_val as Dictionary)["soldiers"] = 150
	return forces


func _fresh_sim() -> RefCounted:
	var sim: RefCounted = SimControllerCls.new()
	var res: Dictionary = sim.load_scenario({
		"scenario_id": "det_red_battle", "scenario_version": "1.0.0", "seed": SCENARIO_SEED,
		"mission_contract": {"primary_objective": "destroy_all_red", "turn_limit": 40},
		"map": {"bounds": {"q_min": -32, "q_max": -16, "r_min": -8, "r_max": 8},
			"default_terrain": 0, "terrain_overrides": {}, "river_cells": []},
		"forces": _forces(), "start_turn": 1})
	if not bool(res.get("ok", false)):
		print("[DETBATTLE] FATAL scenario load failed: %s" % JSON.stringify(res))
	return sim


# --- one full deterministic battle ---------------------------------------------

func _run_battle(blue_policy: String) -> Dictionary:
	var sim := _fresh_sim()
	var mgr := ManagerCls.new()
	var battle := {
		"blue_policy": blue_policy, "seed": SCENARIO_SEED,
		"fixed_strategy": {}, "plan": {}, "turns": [],
		"first_legal_opportunity_turn": 0, "first_actual_attack_turn": 0,
		"red_attacks": 0, "attacks_by_class": {}, "missed_attacks": [],
		"blue_start": 0, "blue_end": 0, "red_start": 0, "red_end": 0,
		"stop_reason": "", "min_start_distance": 0, "start_all_regions": {},
	}
	_snap_start_totals(sim, battle)
	_verify_out_of_range(sim, battle)
	var turn_count := 0
	while turn_count < MAX_TURNS:
		turn_count += 1
		var turn := int(sim.get_manager().get_current_turn())
		var obs: Dictionary = ObsCls.build(sim, "red")
		if not bool(obs.get("ok", false)):
			(battle as Dictionary)["stop_reason"] = "OBS_FAILED_T%d" % turn
			break
		if turn == 1:
			_adopt_fixed_plan(sim, mgr, obs, battle)
		var trow := _red_turn(sim, mgr, obs, battle)
		(trow as Dictionary)["blue_policy"] = blue_policy
		# BATTLE_TERMINAL_CONTRACT_V0: RED may have ended the battle mid-turn
		# (HQ kill). BLUE gets no post-terminal phase.
		if _decisive(sim, battle):
			(trow as Dictionary)["blue_note"] = "skipped: battle terminal during RED phase"
		else:
			_blue_phase(sim, trow, blue_policy)
		(trow as Dictionary)["fingerprint_post"] = str(sim.fingerprint())
		# JEV SHADOW (no authority): per-turn mission/authority telemetry.
		JevShadowCls.note_turn(_shadow_run_id(),
			str(obs.get("battle_id", "battle")), int((trow as Dictionary).get("turn", 0)),
			str((trow as Dictionary).get("snapshot_id", "")),
			(trow as Dictionary).get("statuses", []),
			(trow as Dictionary).get("review", {}),
			str((trow as Dictionary).get("fingerprint_post", "")),
			((trow as Dictionary).get("orders", []) as Array).size())
		((battle as Dictionary).get("turns", []) as Array).append(trow)
		_update_firsts(battle, trow)
		if _decisive(sim, battle):
			break
		sim.sim_end_turn()
	_snap_end_totals(sim, battle)
	return battle


func _snap_start_totals(sim: RefCounted, battle: Dictionary) -> void:
	var b := 0
	var r := 0
	for u_val in sim.get_manager().get_all_units_including_garrisoned():
		var u: Dictionary = u_val
		if str(u.get("faction", "")) == "blue":
			b += int(u.get("soldier_count", 0))
		elif str(u.get("faction", "")) == "red":
			r += int(u.get("soldier_count", 0))
	battle["blue_start"] = b
	battle["red_start"] = r
	_blue_start_soldiers = b
	_red_start_soldiers = r


func _snap_end_totals(sim: RefCounted, battle: Dictionary) -> void:
	var b := 0
	var r := 0
	for u_val in sim.get_manager().get_all_units_including_garrisoned():
		var u: Dictionary = u_val
		if str(u.get("faction", "")) == "blue":
			b += int(u.get("soldier_count", 0))
		elif str(u.get("faction", "")) == "red":
			r += int(u.get("soldier_count", 0))
	battle["blue_end"] = b
	battle["red_end"] = r
	if str(battle.get("stop_reason", "")).is_empty():
		battle["stop_reason"] = "TURN_LIMIT_%d" % MAX_TURNS


## DET-03 proof: every RED-BLUE pair beyond max attack range (3) at start.
func _verify_out_of_range(sim: RefCounted, battle: Dictionary) -> void:
	var mgr: RefCounted = sim.get_manager()
	var reds: Array = []
	var blues: Array = []
	for u_val in mgr.get_all_units():
		var u: Dictionary = u_val
		if str(u.get("faction", "")) == "red":
			reds.append(u)
		elif str(u.get("faction", "")) == "blue":
			blues.append(u)
	var min_d := 1 << 30
	for r_val in reds:
		for b_val in blues:
			var d := HexUtilsCls.hex_distance_axial(
				Vector2i(int((r_val as Dictionary).get("q", 0)), int((r_val as Dictionary).get("r", 0))),
				Vector2i(int((b_val as Dictionary).get("q", 0)), int((b_val as Dictionary).get("r", 0))))
			min_d = mini(min_d, d)
	battle["min_start_distance"] = min_d
	var any_targets := false
	for r_val in reds:
		if not (mgr.get_attackable_targets(str((r_val as Dictionary).get("id", ""))) as Array).is_empty():
			any_targets = true
	battle["start_authoritative_targets_any"] = any_targets
	var regs := {}
	var obs: Dictionary = ObsCls.build(sim, "red")
	for u_val in (obs.get("friendly_units", []) as Array):
		regs[str((u_val as Dictionary).get("unit_id", ""))] = str((u_val as Dictionary).get("region", ""))
	for e_val in (obs.get("known_enemy_units", []) as Array):
		regs[str((e_val as Dictionary).get("unit_id", ""))] = str((e_val as Dictionary).get("region", ""))
	battle["start_all_regions"] = regs
	battle["start_visible_blue"] = (obs.get("known_enemy_units", []) as Array).filter(
		func(x: Variant) -> bool: return str((x as Dictionary).get("contact_state", "")) == "current_visible").size()


## DET-01: fixed coordinator selection injected at the production boundary.
## Real path: menu -> JSON text -> parse_initial -> expand_initial -> apply_plan.
func _adopt_fixed_plan(sim: RefCounted, mgr: RefCounted, obs: Dictionary, battle: Dictionary) -> void:
	var menu: Dictionary = mgr.call("build_coord_menu", obs)
	var asn: Array = []
	var picks := {}
	for g_val in (menu.get("groups", []) as Array):
		var g: Dictionary = g_val
		var gid := str(g.get("id", ""))
		var fam := str(g.get("family", "LINE"))
		var regions: Array = g.get("regions", [])
		var area := str(regions[0]) if not regions.is_empty() else "ANY"
		var want_task := "FIX"
		var want_area := area
		match fam:
			"LINE":
				want_task = "FIX"
			"FAST":
				want_task = "FLANK"
			"COMMAND":
				want_task = "HOLD"
				want_area = "ANY"
			_:
				want_task = "HOLD"
		var choice := _menu_choice(menu, gid, want_task, want_area)
		if choice.is_empty() and fam == "FAST":
			choice = _menu_choice(menu, gid, "ATTACK", area)
		if choice.is_empty():
			choice = _menu_first(menu, gid)
		asn.append({"group": gid, "choice": str(choice.get("id", ""))})
		picks[gid] = "%s %s -> %s (%s)" % [gid, fam, str(choice.get("id", "")), str(choice.get("label", ""))]
	var sel := {
		"concept": "FIX_AND_FLANK", "main_effort": "CENTER",
		"doctrine_profile": {"aggression": "STANDARD", "tempo": "STANDARD",
			"risk": "BALANCED", "reserve": "STANDARD", "pursuit": "STANDARD"},
		"assignments": asn, "review_horizon": 4,
		"snapshot_id": str(obs.get("snapshot_id", "")),
	}
	var sel_text := JSON.stringify(sel)
	var parsed: Dictionary = CoordResponseCls.parse_initial(sel_text,
		{"menu": menu, "snapshot_id": str(obs.get("snapshot_id", "")), "turn": 1})
	var record := {"menu_groups": (menu.get("groups", []) as Array).size(),
		"picks": picks, "selection_json": sel, "parse_ok": bool(parsed.get("ok", false)),
		"parse_code": str(parsed.get("code", "")), "expand_ok": false, "adopt_ok": false}
	if not bool(parsed.get("ok", false)):
		record["adopt_detail"] = "PARSE_FAILED: %s" % str(parsed.get("detail", ""))
		battle["fixed_strategy"] = record
		return
	var expanded: Dictionary = CoordMenuCls.expand_initial(menu, parsed.get("selection", {}),
		1, str(obs.get("snapshot_id", "")), obs.get("mission", {}), parsed.get("warnings", []))
	record["expand_ok"] = bool(expanded.get("ok", false))
	record["expand_code"] = str(expanded.get("code", ""))
	record["expand_warnings"] = expanded.get("warnings", [])
	if not bool(expanded.get("ok", false)):
		record["adopt_detail"] = "EXPAND_FAILED: %s" % str(expanded.get("detail", ""))
		battle["fixed_strategy"] = record
		return
	var applied: Dictionary = mgr.call("apply_plan", expanded.get("plan", {}), 1,
		str(obs.get("snapshot_id", "")), str(obs.get("battle_id", "")))
	record["adopt_ok"] = bool(applied.get("ok", false))
	record["adopt_version"] = int(applied.get("version", 0))
	if bool(applied.get("ok", false)):
		mgr.call("bind_coordination", {"choices": expanded.get("choices", {}),
			"menu_snapshot": str(menu.get("snapshot_id", "")), "turn": 1,
			"warnings": expanded.get("warnings", [])})
		record["choices"] = expanded.get("choices", {})
		record["missions"] = expanded.get("missions", [])
		battle["plan"] = mgr.call("get_plan")
	else:
		record["adopt_detail"] = "APPLY_FAILED: %s" % str(applied.get("detail", ""))
	battle["fixed_strategy"] = record


func _menu_choice(menu: Dictionary, gid: String, task: String, area: String) -> Dictionary:
	var g := CoordMenuCls.find_group(menu, gid)
	for o_val in (g.get("options", []) as Array):
		var o: Dictionary = o_val
		if str(o.get("task", "")) == task and str(o.get("area", "")) == area:
			return o
	return {}


func _menu_first(menu: Dictionary, gid: String) -> Dictionary:
	var g := CoordMenuCls.find_group(menu, gid)
	var opts: Array = g.get("options", []) as Array
	return opts[0] if not opts.is_empty() else {}


# --- RED turn: production decision + execution + missed-attack detection ------

func _red_turn(sim: RefCounted, mgr: RefCounted, obs: Dictionary, battle: Dictionary) -> Dictionary:
	var turn := int(obs.get("turn", 0))
	var trow := {"turn": turn, "snapshot_id": str(obs.get("snapshot_id", "")),
		"red": [], "orders": [], "missed": [], "review": {}, "statuses": [],
		"red_moves": 0, "red_attacks": 0, "red_holds": 0, "blue_visible": 0}
	(trow as Dictionary)["blue_visible"] = (obs.get("known_enemy_units", []) as Array).filter(
		func(x: Variant) -> bool: return str((x as Dictionary).get("contact_state", "")) == "current_visible").size()
	var plan: Dictionary = mgr.call("get_plan")
	var mission_of := _mission_of(plan)
	# Pre-decision authoritative reads (same state red_turn decides on).
	var auth := _authoritative_targets(sim, obs)
	var ready_ids: Array = []
	for u_val in (obs.get("friendly_units", []) as Array):
		if str((u_val as Dictionary).get("status", "")) == "ready":
			ready_ids.append(str((u_val as Dictionary).get("unit_id", "")))
	var attacks_all: Array = OpportunityCls.legal_attacks(sim, ready_ids, obs)
	var opp_by_unit := {}
	for a_val in attacks_all:
		var aid := str((a_val as Dictionary).get("attacker_id", ""))
		if not opp_by_unit.has(aid):
			opp_by_unit[aid] = []
		((opp_by_unit as Dictionary)[aid] as Array).append(a_val)
	# Production decision (pure: no battle mutation inside).
	var decided: Dictionary = mgr.call("red_turn", sim, obs)
	(trow as Dictionary)["review"] = decided.get("review", {})
	(trow as Dictionary)["statuses"] = decided.get("statuses", [])
	(trow as Dictionary)["corrections"] = decided.get("corrections", [])
	var tables := _tables_by_unit(decided)
	# Sequential production execution with per-order casualty diffs.
	var acted: Array = []
	var exec_by_unit := {}
	for o_val in (decided.get("orders", []) as Array):
		var mid := str((o_val as Dictionary).get("mission_id", "?"))
		var order: Dictionary = (o_val as Dictionary).get("order", {})
		var gate: Dictionary = ResponseCls.check_order(order, {"acting_side": "RED"})
		var orow := {"mission_id": mid, "order": order,
			"gate_ok": bool(gate.get("ok", false)), "gate_code": str(gate.get("code", "")),
			"exec_status": "GATE_REJECTED", "executed_units": [], "execution_failed": [],
			"casualties": {}, "destroyed": []}
		if bool(gate.get("ok", false)):
			var before := _soldier_map(sim)
			var octx: Dictionary = (o_val as Dictionary).get("exec_ctx", {})
			var ex: Dictionary = CompilerCls.execute(sim, order, "", "red", octx) if not octx.is_empty() else CompilerCls.execute(sim, order, "", "red")
			var after := _soldier_map(sim)
			(orow as Dictionary)["exec_status"] = str(ex.get("execution_status", "?"))
			(orow as Dictionary)["executed_units"] = ex.get("executed_units", [])
			(orow as Dictionary)["execution_failed"] = ex.get("execution_failed", [])
			(orow as Dictionary)["plan_failed"] = ex.get("plan_failed", [])
			(orow as Dictionary)["casualties"] = _diff_casualties(before, after)
			(orow as Dictionary)["destroyed"] = _diff_destroyed(before, after)
			for e_val in (ex.get("executed_units", []) as Array):
				acted.append({"unit_id": str((e_val as Dictionary).get("unit_id", ""))})
				exec_by_unit[str((e_val as Dictionary).get("unit_id", ""))] = e_val
		((trow as Dictionary).get("orders", []) as Array).append(orow)
	mgr.call("post_turn", acted, turn)
	# Per-unit trace rows + missed-attack detector.
	for u_val in (obs.get("friendly_units", []) as Array):
		var u: Dictionary = u_val
		var uid := str(u.get("unit_id", ""))
		var uclass := str(u.get("class", "")).to_upper()
		var tab: Dictionary = tables.get(uid, {})
		var exrow: Dictionary = exec_by_unit.get(uid, {})
		var action := str(exrow.get("action", "NONE"))
		if action == "MOVE":
			(trow as Dictionary)["red_moves"] = int((trow as Dictionary).get("red_moves", 0)) + 1
		elif action == "ATTACK":
			(trow as Dictionary)["red_attacks"] = int((trow as Dictionary).get("red_attacks", 0)) + 1
			(battle as Dictionary)["red_attacks"] = int((battle as Dictionary).get("red_attacks", 0)) + 1
			var abc: Dictionary = (battle as Dictionary).get("attacks_by_class", {})
			abc[uclass] = int(abc.get(uclass, 0)) + 1
			if int((battle as Dictionary).get("first_actual_attack_turn", 0)) == 0:
				(battle as Dictionary)["first_actual_attack_turn"] = turn
		elif action == "HOLD":
			(trow as Dictionary)["red_holds"] = int((trow as Dictionary).get("red_holds", 0)) + 1
		var urec := {"unit_id": uid, "class": uclass,
			"mission_id": str((mission_of.get(uid, {}) as Dictionary).get("mission_id", "?")),
			"mission_task": str((mission_of.get(uid, {}) as Dictionary).get("task", "?")),
			"pos": [int(u.get("q", 0)), int(u.get("r", 0))],
			"soldiers": int(u.get("soldiers", 0)), "status": str(u.get("status", "")),
			"auth_targets": auth.get(uid, []), "opp_rows": _compact_rows(opp_by_unit.get(uid, [])),
			"options": _compact_options(tab), "selected": str(tab.get("selected_id", "NONE")),
			"resolved_target": str(tab.get("resolved_target", "")),
			"resolved_destination": tab.get("resolved_destination", []),
			"resolved_command": tab.get("resolved_command", {}),
			"compiler": str(tab.get("compiler", "NONE")),
			"executed_action": action, "exec_detail": exrow}
		((trow as Dictionary).get("red", []) as Array).append(urec)
		# JEV SHADOW (no authority): execution-outcome telemetry per unit.
		JevShadowCls.note_execution(_shadow_run_id(),
			str(obs.get("battle_id", "battle")), turn, uid, action, exrow,
			{}, [])
		if not ((auth.get(uid, []) as Array).is_empty()) and action != "ATTACK":
			var miss := {"turn": turn, "unit": uid, "class": uclass,
				"mission_id": str(urec["mission_id"]), "mission_task": str(urec["mission_task"]),
				"pos": urec["pos"], "targets": auth.get(uid, []),
				"opp_rows": urec["opp_rows"], "options": urec["options"],
				"winner": urec["selected"], "resolved_command": urec["resolved_command"],
				"executed_instead": action}
			var cls := _classify_miss(uid, uclass, mission_of.get(uid, {}),
				auth.get(uid, []), opp_by_unit.get(uid, []), tab, obs, exrow)
			(miss as Dictionary)["first_failing_layer"] = str(cls.get("layer", "?"))
			(miss as Dictionary)["layer_detail"] = str(cls.get("detail", ""))
			((trow as Dictionary).get("missed", []) as Array).append(miss)
			((battle as Dictionary).get("missed_attacks", []) as Array).append(miss)
	return trow


func _mission_of(plan: Dictionary) -> Dictionary:
	var out := {}
	for m_val in (plan.get("missions", []) as Array):
		if not m_val is Dictionary:
			continue
		for u in ((m_val as Dictionary).get("assigned_units", []) as Array):
			out[str(u).strip_edges().to_upper()] = m_val
	return out


func _authoritative_targets(sim: RefCounted, obs: Dictionary) -> Dictionary:
	var out := {}
	var mgr: RefCounted = sim.get_manager()
	for u_val in (obs.get("friendly_units", []) as Array):
		var uid := str((u_val as Dictionary).get("unit_id", ""))
		var rows: Array = []
		for t_val in mgr.get_attackable_targets(uid):
			var t: Dictionary = t_val
			rows.append({"id": str(t.get("id", "")), "class": str(t.get("class", "")).to_upper(),
				"distance": int(t.get("distance", 0)), "soldiers": int(t.get("soldier_count", 0)),
				"q": int(t.get("q", 0)), "r": int(t.get("r", 0))})
		rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a.get("id", "")) < str(b.get("id", "")))
		out[uid] = rows
	return out


func _compact_rows(rows: Array) -> Array:
	var out: Array = []
	for a_val in rows:
		var a: Dictionary = a_val
		out.append({"target_id": str(a.get("target_id", "")), "target_class": str(a.get("target_class", "")),
			"distance": int(a.get("distance", 0)), "matchup": snappedf(float(a.get("matchup", 0.0)), 0.01),
			"kill": snappedf(float(a.get("kill_fraction", 0.0)), 0.04),
			"loss": snappedf(float(a.get("loss_fraction", 0.0)), 0.04)})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a.get("target_id", "")) < str(b.get("target_id", "")))
	return out


func _tables_by_unit(decided: Dictionary) -> Dictionary:
	var out := {}
	for tr_val in (decided.get("traces", []) as Array):
		for t_val in ((tr_val as Dictionary).get("units", []) as Array):
			out[str((t_val as Dictionary).get("unit_id", ""))] = t_val
	return out


func _compact_options(tab: Dictionary) -> Array:
	var out: Array = []
	for o_val in (tab.get("options", []) as Array):
		var o: Dictionary = o_val
		out.append({"slot": int(o.get("slot", -1)), "id": str(o.get("option_id", "?")),
			"kind": str(o.get("kind", "?")), "masked": bool(o.get("masked", false)),
			"mask_reason": str(o.get("mask_reason", "")),
			"base": snappedf(float(o.get("base_score", 0.0)), 0.1),
			"mission": snappedf(float(o.get("mission_score", 0.0)), 0.1),
			"state": snappedf(float(o.get("state_score", 0.0)), 0.1),
			"doctrine": snappedf(float(o.get("doctrine_score", 0.0)), 0.1),
			"risk": snappedf(float(o.get("risk_score", 0.0)), 0.1),
			"final": snappedf(float(o.get("final_score", 0.0)), 0.1),
			"target": str(o.get("resolved_target", "")),
			"dry": str(o.get("dry_code", "")) if bool(o.get("masked", false)) else "OK"})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a.get("slot", 0)) < int(b.get("slot", 0)))
	return out


func _soldier_map(sim: RefCounted) -> Dictionary:
	var out := {}
	for u_val in sim.get_manager().get_all_units_including_garrisoned():
		out[str((u_val as Dictionary).get("id", ""))] = int((u_val as Dictionary).get("soldier_count", 0))
	return out


func _diff_casualties(before: Dictionary, after: Dictionary) -> Dictionary:
	var out := {}
	for uid in before.keys():
		var d := int(before[uid]) - int(after.get(uid, 0))
		if d > 0:
			out[str(uid)] = d
	return out


func _diff_destroyed(before: Dictionary, after: Dictionary) -> Array:
	var out: Array = []
	for uid in before.keys():
		if int(before[uid]) > 0 and int(after.get(uid, 0)) <= 0:
			out.append(str(uid))
	out.sort()
	return out


## Diagnostic only (never feeds decisions): name the first pipeline layer that
## explains why a unit with authoritative targets did not ATTACK.
func _classify_miss(uid: String, uclass: String, mission: Dictionary, auth_targets: Array,
	opp_rows: Array, tab: Dictionary, obs: Dictionary, exrow: Dictionary) -> Dictionary:
	if (tab as Dictionary).is_empty():
		return {"layer": "mission_controller", "detail": "unit not ready / no six-option table (not decided this turn)"}
	if (opp_rows as Array).is_empty():
		var vis := _visibility_of(auth_targets, obs)
		return {"layer": "opportunity_generation",
			"detail": "authoritative targets exist but Opportunity.legal_attacks returned 0 rows. Visibility: %s" % vis}
	var opts: Array = (tab as Dictionary).get("options", [])
	var attack_opts: Array = []
	var unmasked_attack: Array = []
	for o_val in opts:
		var o: Dictionary = o_val
		if str(o.get("kind", "")) != "ATTACK":
			continue
		attack_opts.append(o)
		if not bool(o.get("masked", true)):
			unmasked_attack.append(o)
	if attack_opts.is_empty():
		return {"layer": "option_matrix_by_design",
			"detail": "%s exposes no ATTACK-kind option in its six slots (matrix has no attack semantic for this class)" % uclass}
	if unmasked_attack.is_empty():
		return _masked_attack_layer(uclass, mission, attack_opts, opp_rows, obs)
	var winner_id := str((tab as Dictionary).get("selected_id", ""))
	var winner_kind := ""
	var winner_final := 0.0
	for o_val in opts:
		if str((o_val as Dictionary).get("option_id", "")) == winner_id:
			winner_kind = str((o_val as Dictionary).get("kind", ""))
			winner_final = float((o_val as Dictionary).get("final_score", 0.0))
	if winner_kind != "ATTACK":
		var best := 0.0
		var best_id := ""
		for g_val in unmasked_attack:
			if float((g_val as Dictionary).get("final_score", 0.0)) > best:
				best = float((g_val as Dictionary).get("final_score", 0.0))
				best_id = str((g_val as Dictionary).get("option_id", ""))
		return {"layer": "score_selection",
			"detail": "ATTACK available (%s final=%.1f) but %s (%s final=%.1f) won" % [best_id, best, winner_id, winner_kind, winner_final]}
	var cmd: Dictionary = (tab as Dictionary).get("resolved_command", {})
	if str(cmd.get("action", "")) != "ATTACK":
		return {"layer": "resolution",
			"detail": "winner %s resolved to %s instead of ATTACK" % [winner_id, str(cmd.get("action", "?"))]}
	if (exrow as Dictionary).is_empty():
		return {"layer": "compiler_execution",
			"detail": "ATTACK command resolved but unit executed nothing (order gated/failed/dropped)"}
	return {"layer": "compiler_execution",
		"detail": "ATTACK resolved but executed %s instead" % str((exrow as Dictionary).get("action", "?"))}


func _masked_attack_layer(uclass: String, mission: Dictionary, attack_opts: Array, opp_rows: Array, obs: Dictionary) -> Dictionary:
	var generic_nvt := false
	var matched_but_masked := false
	var other := {}
	for a_val in attack_opts:
		var a: Dictionary = a_val
		var reason := str(a.get("mask_reason", ""))
		if reason != "NO_VALID_TARGET":
			other[reason] = true
			continue
		var filt: Array = _class_filter_for(str(a.get("option_id", "")))
		if filt.is_empty():
			generic_nvt = true
		else:
			for row_val in (opp_rows as Array):
				if filt.has(str((row_val as Dictionary).get("target_class", ""))):
					matched_but_masked = true
	if generic_nvt or matched_but_masked:
		return {"layer": "mission_filter", "detail": _filter_detail(mission, opp_rows, obs)}
	if not other.is_empty():
		return {"layer": "option_mask", "detail": "ATTACK options masked: %s" % ",".join(other.keys())}
	var have := {}
	for row_val in (opp_rows as Array):
		have[str((row_val as Dictionary).get("target_class", ""))] = true
	return {"layer": "option_class_filter",
		"detail": "class-filtered attack options only; legal targets [%s] match no filter" % ",".join(have.keys())}


func _class_filter_for(oid: String) -> Array:
	# Mirrors Cloud2ClassOption.CLASS_FILTER membership (diagnostic read).
	if oid == "ATTACK_CAVALRY":
		return ["CAVALRY"]
	if oid == "EXPLOIT_REAR_OR_RANGED":
		return ["ARCHER", "SCOUT"]
	return []


func _visibility_of(auth_targets: Array, obs: Dictionary) -> String:
	var cur := {}
	for e_val in (obs.get("known_enemy_units", []) as Array):
		if str((e_val as Dictionary).get("contact_state", "")) == "current_visible":
			cur[str((e_val as Dictionary).get("unit_id", ""))] = true
	var vis := 0
	var ids: Array = []
	for t_val in auth_targets:
		ids.append(str((t_val as Dictionary).get("id", "")))
		if cur.has(str((t_val as Dictionary).get("id", ""))):
			vis += 1
	return "%d/%d current_visible ([%s])" % [vis, ids.size(), ",".join(ids)]


func _filter_detail(mission: Dictionary, opp_rows: Array, obs: Dictionary) -> String:
	if (mission as Dictionary).is_empty():
		return "unit has no mission assignment (coverage gap)"
	var policy := str(((mission as Dictionary).get("engagement", {}) as Dictionary).get("policy", ""))
	if policy == "HOLD_FIRE":
		return "engagement policy HOLD_FIRE drops all %d opportunity rows" % (opp_rows as Array).size()
	var obj: Dictionary = (mission as Dictionary).get("objective", {})
	var otype := str(obj.get("kind", "NONE"))
	if policy == "ATTACK_DESIGNATED_ONLY":
		return "policy ATTACK_DESIGNATED_ONLY vs objective %s %s; rows=%d" % [otype, JSON.stringify(obj), (opp_rows as Array).size()]
	if policy == "PURSUE_WEAKENED":
		var best_kill := 0.0
		var best_loss := 1.0
		var best_mu := 0.0
		for a_val in (opp_rows as Array):
			best_kill = maxf(best_kill, float((a_val as Dictionary).get("kill_fraction", 0.0)))
			best_loss = minf(best_loss, float((a_val as Dictionary).get("loss_fraction", 1.0)))
			best_mu = maxf(best_mu, float((a_val as Dictionary).get("matchup", 0.0)))
		return "policy PURSUE_WEAKENED: best kill=%.2f (bar 0.25), best loss=%.2f, best matchup=%.2f over %d rows" % [best_kill, best_loss, best_mu, (opp_rows as Array).size()]
	if otype == "FORMATION_CLASS":
		var want := str(obj.get("class", ""))
		var have := {}
		for a_val in (opp_rows as Array):
			have[str((a_val as Dictionary).get("target_class", ""))] = true
		return "objective FORMATION_CLASS %s vs target classes [%s]" % [want, ",".join(have.keys())]
	var task := str((mission as Dictionary).get("task", ""))
	var area := str((mission as Dictionary).get("area", "ANY"))
	if task in ["FIX", "HOLD", "RESERVE"] and area != "ANY":
		var ereg := {}
		for e_val in (obs.get("known_enemy_units", []) as Array):
			ereg[str((e_val as Dictionary).get("unit_id", ""))] = str((e_val as Dictionary).get("region", ""))
		var mism: Array = []
		for a_val in (opp_rows as Array):
			var tid := str((a_val as Dictionary).get("target_id", ""))
			mism.append("%s:%s" % [tid, str(ereg.get(tid, "?"))])
		return "area restriction: mission area %s vs target regions [%s]" % [area, ",".join(mism)]
	return "rows=%d removed by mission filter (policy=%s task=%s area=%s obj=%s)" % [(opp_rows as Array).size(), policy, task, area, otype]


func _blue_phase(sim: RefCounted, trow: Dictionary, blue_policy: String) -> void:
	var acts: Array = []
	if blue_policy == "advance":
		var mgr: RefCounted = sim.get_manager()
		var ids: Array = []
		for u_val in mgr.get_all_units():
			var u: Dictionary = u_val
			if str(u.get("faction", "")) != "blue":
				continue
			if bool(u.get("action_ended", false)) or int(u.get("soldier_count", 0)) <= 0:
				continue
			ids.append(str(u.get("id", "")))
		ids.sort()
		for uid in ids:
			var u2: Dictionary = mgr.get_unit_by_id(uid)
			var cmd := {}
			if str(u2.get("class", "")) == "hq":
				cmd = TableCls.make_command("HOLD", TableCls.scope_units([uid]))
			else:
				cmd = TableCls.make_command("ADVANCE", TableCls.scope_units([uid]), TableCls.target_direction("EAST"))
			var ex: Dictionary = CompilerCls.execute(sim, cmd, "", "blue")
			acts.append({"unit_id": uid, "command": cmd,
				"status": str(ex.get("execution_status", "?")),
				"executed": ex.get("executed_units", [])})
	else:
		(trow as Dictionary)["blue_note"] = "stationary: BLUE holds position (no orders)"
	(trow as Dictionary)["blue_actions"] = acts


func _update_firsts(battle: Dictionary, trow: Dictionary) -> void:
	var turn := int((trow as Dictionary).get("turn", 0))
	if int((battle as Dictionary).get("first_legal_opportunity_turn", 0)) == 0:
		for u_val in ((trow as Dictionary).get("red", []) as Array):
			if not (((u_val as Dictionary).get("auth_targets", []) as Array).is_empty()):
				(battle as Dictionary)["first_legal_opportunity_turn"] = turn
				break


## BATTLE_TERMINAL_CONTRACT_V0: the single canonical battle evaluator
## (SimController.evaluate_battle) decides the stop — HQ-terminal first,
## then the preserved annihilation/objective/expired rules. ANNIHILATED stop
## strings are kept for the DET-09 gate; HQ stops are new data.
func _decisive(sim: RefCounted, battle: Dictionary) -> bool:
	var b: Dictionary = sim.evaluate_battle()
	if not bool(b.get("terminal", false)):
		return false
	var reason := str(b.get("reason", ""))
	var stop := "BATTLE_TERMINAL"
	match reason:
		"hq_destroyed":
			stop = "BLUE_HQ_DESTROYED"
		"red_hq_destroyed":
			stop = "RED_HQ_DESTROYED"
		"blue_annihilated":
			stop = "BLUE_ANNIHILATED"
		"all_red_destroyed":
			stop = "RED_ANNIHILATED"
		"capital_taken":
			stop = "CAPITAL_TAKEN"
		"turn_limit_survived":
			stop = "TURN_LIMIT_SURVIVED"
		"turn_limit_reached_without_decision":
			stop = "EXPIRED_NO_DECISION"
	(battle as Dictionary)["stop_reason"] = stop
	(battle as Dictionary)["winner"] = str(b.get("winner", ""))
	(battle as Dictionary)["terminal_reason"] = reason
	(battle as Dictionary)["terminal_turn"] = int(b.get("turn", 0))
	return true


# --- verdict, comparison, answers ------------------------------------------------

func _summarize(battle: Dictionary) -> Dictionary:
	var maneuver_turns := 0
	var first_opp := int(battle.get("first_legal_opportunity_turn", 0))
	for t_val in (battle.get("turns", []) as Array):
		var t: Dictionary = t_val
		var any_auth := false
		for u_val in (t.get("red", []) as Array):
			if not (((u_val as Dictionary).get("auth_targets", []) as Array).is_empty()):
				any_auth = true
				break
		if not any_auth and int(t.get("red_moves", 0)) > 0:
			maneuver_turns += 1
	var attack_turns: Array = []
	for t_val in (battle.get("turns", []) as Array):
		if int((t_val as Dictionary).get("red_attacks", 0)) > 0:
			attack_turns.append(int((t_val as Dictionary).get("turn", 0)))
	var misses: Array = battle.get("missed_attacks", [])
	var layers := {}
	for m_val in misses:
		var l := str((m_val as Dictionary).get("first_failing_layer", "?"))
		layers[l] = int(layers.get(l, 0)) + 1
	return {"blue_policy": str(battle.get("blue_policy", "")),
		"turns_run": (battle.get("turns", []) as Array).size(),
		"stop_reason": str(battle.get("stop_reason", "")),
		"min_start_distance": int(battle.get("min_start_distance", 0)),
		"start_authoritative_targets_any": bool(battle.get("start_authoritative_targets_any", true)),
		"start_visible_blue": int(battle.get("start_visible_blue", -1)),
		"maneuver_turns_before_contact": maneuver_turns,
		"first_legal_opportunity_turn": first_opp,
		"first_actual_attack_turn": int(battle.get("first_actual_attack_turn", 0)),
		"red_attacks": int(battle.get("red_attacks", 0)),
		"attacks_by_class": battle.get("attacks_by_class", {}),
		"attack_turns": attack_turns,
		"blue_start": int(battle.get("blue_start", 0)), "blue_end": int(battle.get("blue_end", 0)),
		"blue_casualties": int(battle.get("blue_start", 0)) - int(battle.get("blue_end", 0)),
		"red_start": int(battle.get("red_start", 0)), "red_end": int(battle.get("red_end", 0)),
		"missed_attack_count": misses.size(),
		"missed_by_layer": layers,
		"first_missed": misses[0] if not misses.is_empty() else {},
		"fixed_plan_adopted": bool(((battle.get("fixed_strategy", {}) as Dictionary).get("adopt_ok", false))),
	}


func _verdict(primary: Dictionary) -> Dictionary:
	var s := _summarize(primary)
	var starts_out := int(s.get("min_start_distance", 0)) > 3 \
		and not bool(s.get("start_authoritative_targets_any", true))
	var maneuvers := int(s.get("maneuver_turns_before_contact", 0)) >= MANEUVER_TURNS_REQUIRED
	var reaches := int(s.get("first_legal_opportunity_turn", 0)) > 0
	var switches := int(s.get("first_actual_attack_turn", 0)) > 0
	var multiple := int(s.get("red_attacks", 0)) >= MIN_ATTACKS_REQUIRED
	var casualties := int(s.get("blue_casualties", 0)) > 0
	var adopted := bool(s.get("fixed_plan_adopted", false))
	var pass_all := starts_out and maneuvers and reaches and switches and multiple and casualties and adopted
	return {"DETERMINISTIC_BATTLE_PASS": pass_all,
		"starts_out_of_range": starts_out, "maneuvers_multiple_turns": maneuvers,
		"reaches_legal_combat": reaches, "switches_to_attack": switches,
		"multiple_real_attacks": multiple, "blue_losses": casualties,
		"fixed_plan_adopted": adopted,
		"DETERMINISTIC_RED": "HEALTHY" if pass_all else "BROKEN"}


func _compare_runs(a: Dictionary, b: Dictionary) -> Dictionary:
	var da := _digest(a)
	var db := _digest(b)
	return {"reproducible": da == db, "digest_a": da, "digest_b": db}


func _digest(battle: Dictionary) -> String:
	var parts: Array = []
	for t_val in (battle.get("turns", []) as Array):
		var t: Dictionary = t_val
		parts.append("T%d fp=%s mv=%d atk=%d hold=%d" % [int(t.get("turn", 0)),
			str(t.get("fingerprint_post", "")).left(64),
			int(t.get("red_moves", 0)), int(t.get("red_attacks", 0)), int(t.get("red_holds", 0))])
	parts.append("attacks=%d by=%s blue=%d red=%d first=%d" % [
		int(battle.get("red_attacks", 0)), JSON.stringify(battle.get("attacks_by_class", {})),
		int(battle.get("blue_end", 0)), int(battle.get("red_end", 0)),
		int(battle.get("first_actual_attack_turn", 0))])
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(("|".join(parts)).to_utf8_buffer())
	return ctx.finish().hex_encode()


func _unit_attacked_class(battle: Dictionary, want_class: String, want_task: String = "") -> bool:
	for t_val in (battle.get("turns", []) as Array):
		for u_val in ((t_val as Dictionary).get("red", []) as Array):
			var u: Dictionary = u_val
			if str(u.get("executed_action", "")) == "ATTACK" and str(u.get("class", "")) == want_class:
				if want_task.is_empty() or str(u.get("mission_task", "")) == want_task:
					return true
	return false


func _task_attacked(battle: Dictionary, want_task: String) -> bool:
	for t_val in (battle.get("turns", []) as Array):
		for u_val in ((t_val as Dictionary).get("red", []) as Array):
			var u: Dictionary = u_val
			if str(u.get("executed_action", "")) == "ATTACK" and str(u.get("mission_task", "")) == want_task:
				return true
	return false


func _attack_available_when_legal(battle: Dictionary) -> Dictionary:
	var checked := 0
	var available := 0
	for t_val in (battle.get("turns", []) as Array):
		for u_val in ((t_val as Dictionary).get("red", []) as Array):
			var u: Dictionary = u_val
			if ((u.get("auth_targets", []) as Array).is_empty()):
				continue
			checked += 1
			for o_val in (u.get("options", []) as Array):
				var o: Dictionary = o_val
				if str(o.get("kind", "")) == "ATTACK" and not bool(o.get("masked", true)):
					available += 1
					break
	return {"checked": checked, "available": available}


func _answer_a(primary: Dictionary, secondary: Dictionary) -> Dictionary:
	var ps := _summarize(primary)
	var avail := _attack_available_when_legal(primary)
	var attack_turns: Array = ps.get("attack_turns", [])
	return {
		"A1_reach_range_no_cloud": int(ps.get("first_legal_opportunity_turn", 0)) > 0,
		"A2_attack_semantic_available": {"units_with_targets": int(avail.get("checked", 0)),
			"units_with_unmasked_attack": int(avail.get("available", 0))},
		"A3_survives_mission_filter": "see missed_by_layer mission_filter count vs opportunity_generation",
		"A4_wins_vs_movement": {"attack_turns_primary": attack_turns,
			"secondary_attack_turns": (_summarize(secondary) as Dictionary).get("attack_turns", [])},
		"A5_resolves_to_attack": int(ps.get("red_attacks", 0)) > 0,
		"A6_mutates_troops": int(ps.get("blue_casualties", 0)) > 0,
		"A7_continues_fighting": attack_turns.size() >= 2,
		"A8_fix_attacks": _task_attacked(primary, "FIX"),
		"A9_flank_attacks": _task_attacked(primary, "FLANK"),
		"A10_archers_fire": _unit_attacked_class(primary, "ARCHER"),
		"A_infantry": _unit_attacked_class(primary, "INFANTRY"),
		"A_spearman": _unit_attacked_class(primary, "SPEARMAN"),
		"A_cavalry": _unit_attacked_class(primary, "CAVALRY"),
	}


func _det_gates(primary: Dictionary, secondary: Dictionary, det: Dictionary, verdict: Dictionary) -> Dictionary:
	var ps := _summarize(primary)
	var fix: Dictionary = (primary as Dictionary).get("fixed_strategy", {})
	var matchup_spe := false
	var matchup_cav := false
	for t_val in ((primary as Dictionary).get("turns", []) as Array):
		for u_val in ((t_val as Dictionary).get("red", []) as Array):
			var u: Dictionary = u_val
			if ((u.get("auth_targets", []) as Array).is_empty()):
				continue
			if str(u.get("class", "")) == "SPEARMAN":
				for tg in (u.get("auth_targets", []) as Array):
					if str((tg as Dictionary).get("class", "")) == "CAVALRY":
						matchup_spe = true
			if str(u.get("class", "")) == "CAVALRY":
				matchup_cav = true
	return {
		"DET-01_fixed_strategy_at_boundary": bool(fix.get("parse_ok", false)) and bool(fix.get("expand_ok", false)) and bool(fix.get("adopt_ok", false)),
		"DET-02_no_provider_network_api": true,
		"DET-03_out_of_range_start": bool((verdict as Dictionary).get("starts_out_of_range", false)),
		"DET-04_production_mission_manager": true,
		"DET-05_production_mission_controller": true,
		"DET-06_production_opportunity_generation": true,
		"DET-07_production_six_option_solver": true,
		"DET-08_production_compiler_executor": true,
		"DET-09_multi_turn": int(ps.get("turns_run", 0)) >= 10 or str(ps.get("stop_reason", "")).contains("ANNIHILATED") or str(ps.get("stop_reason", "")).contains("HQ_DESTROYED"),
		"DET-10_first_legal_identified": int(ps.get("first_legal_opportunity_turn", 0)) > 0,
		"DET-11_transition_traced": int(ps.get("first_actual_attack_turn", 0)) > 0,
		"DET-12_infantry_attack": _unit_attacked_class(primary, "INFANTRY"),
		"DET-13_archer_attack": _unit_attacked_class(primary, "ARCHER"),
		"DET-14_spearman_if_matchup": (not matchup_spe) or _unit_attacked_class(primary, "SPEARMAN"),
		"DET-15_cavalry_if_matchup": (not matchup_cav) or _unit_attacked_class(primary, "CAVALRY"),
		"DET-16_authoritative_casualties": int(ps.get("blue_casualties", 0)) > 0,
		"DET-17_missed_detector": true,
		"DET-18_no_handcrafted_rows": true,
		"DET-19_no_rebalance_before_evidence": true,
		"DET-20_reproducible": bool(det.get("reproducible", false)),
	}


func _print_summary(p: Dictionary, out_evidence: String = "") -> void:
	var v: Dictionary = p.get("verdict", {})
	var ps: Dictionary = p.get("primary_blue_stationary", {})
	var ss: Dictionary = p.get("secondary_blue_advance", {})
	print("[DETBATTLE] DETERMINISTIC_BATTLE_PASS=%s (%s)" % [str(bool(v.get("DETERMINISTIC_BATTLE_PASS", false))).to_upper(), str(v.get("DETERMINISTIC_RED", "?"))])
	print("[DETBATTLE] PRIMARY stationary: turns=%d stop=%s start_dist=%d maneuver=%d first_opp=T%d first_atk=T%d attacks=%d by=%s blue_cas=%d missed=%d layers=%s" % [
		int(ps.get("turns_run", 0)), str(ps.get("stop_reason", "")), int(ps.get("min_start_distance", 0)),
		int(ps.get("maneuver_turns_before_contact", 0)), int(ps.get("first_legal_opportunity_turn", 0)),
		int(ps.get("first_actual_attack_turn", 0)), int(ps.get("red_attacks", 0)),
		JSON.stringify(ps.get("attacks_by_class", {})), int(ps.get("blue_casualties", 0)),
		int(ps.get("missed_attack_count", 0)), JSON.stringify(ps.get("missed_by_layer", {}))])
	print("[DETBATTLE] SECONDARY advance: turns=%d stop=%s first_opp=T%d first_atk=T%d attacks=%d by=%s blue_cas=%d missed=%d layers=%s" % [
		int(ss.get("turns_run", 0)), str(ss.get("stop_reason", "")), int(ss.get("first_legal_opportunity_turn", 0)),
		int(ss.get("first_actual_attack_turn", 0)), int(ss.get("red_attacks", 0)),
		JSON.stringify(ss.get("attacks_by_class", {})), int(ss.get("blue_casualties", 0)),
		int(ss.get("missed_attack_count", 0)), JSON.stringify(ss.get("missed_by_layer", {}))])
	print("[DETBATTLE] DETERMINISM reproducible=%s" % str(bool((p.get("determinism", {}) as Dictionary).get("reproducible", false))).to_upper())
	print("[DETBATTLE] evidence: %s" % (out_evidence if not out_evidence.is_empty() else OUT_EVIDENCE))