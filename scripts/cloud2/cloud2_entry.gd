extends SceneTree

## CLOUD-GENERAL STEP 2 — headless Human-vs-Cloud verification runner.
##
## Usage (Windows):
##   Godot_v4.2.2-stable_win64_console.exe --headless --path "D:\Game development\Demon slayer\StrategyGame" -s res://scripts/cloud2/cloud2_entry.gd
##
## Exit code 0 = all gates pass, 1 = any gate fails. Writes verification.json
## into CLOUD-GENERAL-STEP-02 (Step-1 deliverables are never touched).
##
## Part 1 (sim-level, fast): RED canonical observation, side-relative
## semantics, human/cloud parity, sequential multi-order, partial failure,
## semantic gate, adapter serialization, response contract, plan memory,
## packet shape, no-mutation, no-RL scan, secret hygiene.
## Part 2 (live scenes): RED full information, mock-adapter Cloud turn via
## the real shell turn loop, STEP/PAUSE mechanics, failure safety, Step-1
## sandbox intact, Step-1 suite rollup.
##
## No live network is ever attempted: cloud model calls run through the
## adapter's mock fixtures. LIVE CLOUD leg is honestly reported BLOCKED.

const SimControllerCls = preload("res://scripts/sim/sim_controller.gd")
const ObsCls = preload("res://scripts/cloud1/cloud1_observation.gd")
const TableCls = preload("res://scripts/cloud1/cloud1_action_table.gd")
const CompilerCls = preload("res://scripts/cloud1/cloud1_compiler.gd")
const ScopeAlgebraCls = preload("res://scripts/step7/step7_scope_algebra.gd")
const ConfigCls = preload("res://scripts/cloud2/cloud2_config.gd")
const AdapterCls = preload("res://scripts/cloud2/cloud2_adapter.gd")
const PacketCls = preload("res://scripts/cloud2/cloud2_turn_packet.gd")
const TurnControllerCls = preload("res://scripts/cloud2/cloud2_turn_controller.gd")
const ResponseCls = preload("res://scripts/cloud2/cloud2_response.gd")
const PlanCls = preload("res://scripts/cloud2/cloud2_plan_memory.gd")
const LoggerCls = preload("res://scripts/cloud2/cloud2_logger.gd")

const DELIVER_DIR := "D:/Game development/.workflow/deliverables/CLOUD-GENERAL-STEP-02"
const VERIFY_PATH := "D:/Game development/.workflow/deliverables/CLOUD-GENERAL-STEP-02/verification.json"
const STEP1_VERIFY := "D:/Game development/.workflow/deliverables/CLOUD-GENERAL-STEP-01/verification.json"
const CLOUD2_SCENE := "res://scenes/cloud2_battle_test.tscn"
const CLOUD1_SCENE := "res://scenes/cloud1_battle_test.tscn"

## Canary key material: looks secret-shaped, is never a real credential, is
## fed through config/adapter/logger paths and then asserted ABSENT from
## every artifact, preview, packet, and log.
const CANARY := "C2_CANARY_KEY_9f8e7d6c5b4a3f2e1d0c"

const BANNED_ML := ["qwen", "sft", "ppo", "lora", "reinforce", "reward_model",
	"self_play", "self-play", "distill", "league_training", "finetune",
	"fine_tune", "training_dataset", "policy_gradient"]
const CLOUD2_FILES := [
	"res://scripts/cloud2/cloud2_config.gd",
	"res://scripts/cloud2/cloud2_adapter.gd",
	"res://scripts/cloud2/cloud2_turn_packet.gd",
	"res://scripts/cloud2/cloud2_response.gd",
	"res://scripts/cloud2/cloud2_plan_memory.gd",
	"res://scripts/cloud2/cloud2_logger.gd",
	"res://scripts/cloud2/cloud2_turn_controller.gd",
	"res://scripts/cloud2/cloud2_panel.gd",
	"res://scripts/cloud2/cloud2_mount.gd",
	"res://scripts/cloud2/cloud2_entry.gd",
	"res://scripts/cloud2/cloud2_mission.gd",
	"res://scripts/cloud2/cloud2_general_plan.gd",
	"res://scripts/cloud2/cloud2_general_packet.gd",
	"res://scripts/cloud2/cloud2_general_response.gd",
	"res://scripts/cloud2/cloud2_opportunity.gd",
	"res://scripts/cloud2/cloud2_utility.gd",
	"res://scripts/cloud2/cloud2_mission_controller.gd",
	"res://scripts/cloud2/cloud2_mission_manager.gd",
	"res://scripts/cloud2/cloud2_battle_memory.gd",
	"res://scripts/cloud2/cloud2_general_trace.gd",
	"res://scripts/cloud2/cloud2_hier_entry.gd",
	"res://scripts/cloud2/cloud2_class_option.gd",
	"res://scripts/cloud2/cloud2_class_option_solver.gd",
	"res://scripts/cloud2/cloud2_opt_entry.gd",
	"res://scripts/cloud2/cloud2_float_frame.gd",
	"res://scripts/cloud2/cloud2_model_view.gd",
	"res://scripts/cloud2/cloud2_coord_menu.gd",
	"res://scripts/cloud2/cloud2_coord_response.gd",
	"res://scripts/cloud2/cloud2_coord_entry.gd",
	"res://scenes/cloud2_battle_test.tscn",
]
## Step-1 files Step 2 minimally extends (baseline ML-token counts verified
## by sweep: only title_screen.gd carries one pre-existing "qwen" comment).
const EDITED_FILES := [
	"res://scripts/cloud1/cloud1_observation.gd",
	"res://scripts/cloud1/cloud1_compiler.gd",
	"res://scripts/cloud1/cloud1_live_executor.gd",
	"res://scripts/cloud1/cloud1_dock.gd",
	"res://scripts/step2r/step2r_battlefield_shell.gd",
	"res://scripts/ui/title_screen.gd",
	"res://scripts/step7/step7_scope_algebra.gd",
	"res://scripts/step7/step7_formation_clusters.gd",
	"res://scripts/step7/step7_observation_projector.gd",
]
const EDITED_NARROW := ["sft", "ppo", "lora", "reinforce", "reward_model",
	"self_play", "self-play", "distill", "league_training", "finetune",
	"fine_tune", "training_dataset", "policy_gradient"]

var _gates: Dictionary = {}


func _init() -> void:
	_run()


func _record(gate: String, status: String, evidence: Dictionary) -> void:
	_gates[gate] = {"status": status, "evidence": evidence}
	print("[CLOUD2][%s] %s" % [gate, status.to_upper()])


func _exit_code() -> int:
	for key in _gates.keys():
		var st := str((_gates[key] as Dictionary).get("status", ""))
		if st != "pass" and st != "blocked":
			return 1
	return 0


func _scenario() -> Dictionary:
	return {
		"scenario_id": "cloud_step2_red_probe",
		"scenario_version": "1.0.0",
		"seed": 11,
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
			{"id": "R_HQ_1", "class": "hq", "faction": "red", "q": -20, "r": 0, "soldiers": 300},
			{"id": "R_INF_1", "class": "infantry", "faction": "red", "q": -23, "r": 0, "soldiers": 477},
			{"id": "R_CAV_1", "class": "cavalry", "faction": "red", "q": -22, "r": -2, "soldiers": 320},
			{"id": "R_ARC_1", "class": "archer", "faction": "red", "q": -21, "r": 1, "soldiers": 290},
		],
		"start_turn": 1,
	}


func _fresh_sim() -> RefCounted:
	var sim: RefCounted = SimControllerCls.new()
	var res: Dictionary = sim.load_scenario(_scenario())
	if not bool(res.get("ok", false)):
		print("[CLOUD2] FATAL scenario load failed: %s" % JSON.stringify(res))
	return sim


func _run() -> void:
	_s1_red_observation()
	_s2_side_semantics()
	_s3_parity()
	_s4_sequential()
	_s5_partial_failure()
	_s6_semantic_gate()
	_s7_adapter()
	_s8_response()
	_s9_plan_memory()
	_s10_packet()
	_s11_no_mutation()
	_s12_no_rl()
	_s13_secret_hygiene()
	_s20_response_envelope()
	await _live_part()
	_s19_rollup()
	_write_and_quit(_exit_code())


# --- S1: RED canonical observation -------------------------------------------

func _s1_red_observation() -> void:
	var sim := _fresh_sim()
	var obs: Dictionary = ObsCls.build(sim, "red")
	var blue: Dictionary = ObsCls.build(sim, "blue")
	var ev := {}
	var ok := bool(obs.get("ok", false))
	ev["red_ok"] = ok
	ev["side"] = str(obs.get("side", "?"))
	ev["acting_side"] = str((obs.get("parity", {}) as Dictionary).get("acting_side", "?"))
	ev["schema_same_as_blue"] = str(obs.get("schema_version", "")) == str(blue.get("schema_version", ""))
	ev["snapshot_red"] = str(obs.get("snapshot_id", "")).contains("_RED_")
	ev["snapshot_blue_intact"] = str(blue.get("snapshot_id", "")).contains("_BLUE_")
	var friendlies: Array = obs.get("friendly_units", [])
	var enemies: Array = obs.get("known_enemy_units", [])
	ev["friendly_count"] = friendlies.size()
	ev["enemy_count"] = enemies.size()
	var f_ids: Array = []
	var f_sides := {}
	for u_val in friendlies:
		var u: Dictionary = u_val
		f_ids.append(str(u.get("unit_id", "")))
		f_sides[str(u.get("side", ""))] = true
	f_ids.sort()
	ev["friendly_ids"] = f_ids
	ev["friendly_sides"] = f_sides.keys()
	var e_ids: Array = []
	var e_sides := {}
	var e_keys := {}
	for e_val in enemies:
		var e2: Dictionary = e_val
		e_ids.append(str(e2.get("unit_id", "")))
		e_sides[str(e2.get("side", ""))] = true
		for k in e2.keys():
			e_keys[str(k)] = true
	e_ids.sort()
	ev["enemy_ids"] = e_ids
	ev["enemy_sides"] = e_sides.keys()
	ev["enemy_entry_keys"] = e_keys.keys()
	var mission: Dictionary = obs.get("mission", {})
	ev["mission_objective"] = str(mission.get("objective", ""))
	var rules: Dictionary = obs.get("rules", {})
	ev["turn_note"] = str((rules.get("turn", {}) as Dictionary).get("note", ""))
	var enemy_text := JSON.stringify(enemies)
	var leaks: Array = []
	for f in ["soldier_count", "max_count", "morale", "remaining_mp", "base_mp", "local_supply", "world_truth"]:
		if enemy_text.find("\"" + f + "\"") != -1:
			leaks.append(f)
	ev["enemy_vital_leaks"] = leaks
	var f_seen := {}
	for u_val in friendlies:
		f_seen[str((u_val as Dictionary).get("unit_id", ""))] = true
	ok = ok and ev["side"] == "RED" and ev["acting_side"] == "RED" \
		and bool(ev["schema_same_as_blue"]) and bool(ev["snapshot_red"]) \
		and bool(ev["snapshot_blue_intact"]) and f_ids == ["R_ARC_1", "R_CAV_1", "R_HQ_1", "R_INF_1"] \
		and f_sides.keys() == ["RED"] and e_sides.keys() == ["BLUE"] \
		and not enemies.is_empty() and leaks.is_empty() \
		and str(mission.get("objective", "")).contains("BLUE") \
		and str(mission.get("objective", "")).find("RED field") == -1
	for eid in e_ids:
		if not str(eid).begins_with("B_"):
			ok = false
	_record("s1_red_observation_canonical", "pass" if ok else "fail", ev)


# --- S2: side-relative spatial semantics --------------------------------------

func _s2_side_semantics() -> void:
	var ev := {}
	# White-box: axis antisymmetry over a coordinate grid.
	var cells := [Vector2i(-25, 0), Vector2i(-23, 0), Vector2i(0, 0), Vector2i(15, -9), Vector2i(-14, 6)]
	var anti_ok := true
	for c in cells:
		var bf: float = CompilerCls._axis_score(c, "FORWARD", "blue")
		var rf: float = CompilerCls._axis_score(c, "FORWARD", "red")
		var bb: float = CompilerCls._axis_score(c, "BACK", "blue")
		var rb: float = CompilerCls._axis_score(c, "BACK", "red")
		var bl: float = CompilerCls._axis_score(c, "LEFT", "blue")
		var rl: float = CompilerCls._axis_score(c, "LEFT", "red")
		var br: float = CompilerCls._axis_score(c, "RIGHT", "blue")
		var rr: float = CompilerCls._axis_score(c, "RIGHT", "red")
		if not is_equal_approx(rf, -bf) or not is_equal_approx(rb, -bb):
			anti_ok = false
		if not is_equal_approx(rl, -br) or not is_equal_approx(rr, -bl):
			anti_ok = false
		for a in ["NORTH", "SOUTH", "EAST", "WEST"]:
			if not is_equal_approx(CompilerCls._axis_score(c, a, "blue"), CompilerCls._axis_score(c, a, "red")):
				anti_ok = false
	ev["axis_antisymmetric"] = anti_ok
	ev["blue_forward_is_plus_q"] = CompilerCls._axis_score(Vector2i(1, 0), "FORWARD", "blue") > CompilerCls._axis_score(Vector2i(0, 0), "FORWARD", "blue")
	ev["red_forward_is_minus_q"] = CompilerCls._axis_score(Vector2i(-1, 0), "FORWARD", "red") > CompilerCls._axis_score(Vector2i(0, 0), "FORWARD", "red")
	# Plan-level: mirrored ADVANCE FORWARD moves toward each other.
	var s_b := _fresh_sim()
	var pb: Dictionary = CompilerCls.plan(s_b, TableCls.make_command("ADVANCE", TableCls.scope_class("INFANTRY"), TableCls.target_direction("FORWARD")), "", "blue")
	var s_r := _fresh_sim()
	var pr: Dictionary = CompilerCls.plan(s_r, TableCls.make_command("ADVANCE", TableCls.scope_class("INFANTRY"), TableCls.target_direction("FORWARD")), "", "red")
	var b_move := _first_move_delta(pb)
	var r_move := _first_move_delta(pr)
	ev["blue_plan_ok"] = bool(pb.get("ok", false))
	ev["red_plan_ok"] = bool(pr.get("ok", false))
	ev["blue_advance_delta"] = b_move
	ev["red_advance_delta"] = r_move
	ev["advances_toward_each_other"] = int(b_move.get("dq", 0)) > 0 and int(r_move.get("dq", 0)) < 0
	# WITHDRAW BACKWARD mirrors the other way.
	var s_b2 := _fresh_sim()
	var wb: Dictionary = CompilerCls.plan(s_b2, TableCls.make_command("WITHDRAW", TableCls.scope_class("INFANTRY"), TableCls.target_direction("BACKWARD")), "", "blue")
	var s_r2 := _fresh_sim()
	var wr: Dictionary = CompilerCls.plan(s_r2, TableCls.make_command("WITHDRAW", TableCls.scope_class("INFANTRY"), TableCls.target_direction("BACKWARD")), "", "red")
	var b_wd := _first_move_delta(wb)
	var r_wd := _first_move_delta(wr)
	ev["blue_withdraw_delta"] = b_wd
	ev["red_withdraw_delta"] = r_wd
	ev["withdraws_mirror"] = int(b_wd.get("dq", 0)) < 0 and int(r_wd.get("dq", 0)) > 0
	var ok := anti_ok and bool(ev["blue_forward_is_plus_q"]) and bool(ev["red_forward_is_minus_q"]) \
		and bool(pb.get("ok", false)) and bool(pr.get("ok", false)) \
		and bool(ev["advances_toward_each_other"]) and bool(wb.get("ok", false)) and bool(wr.get("ok", false)) \
		and bool(ev["withdraws_mirror"])
	_record("s2_side_relative_semantics", "pass" if ok else "fail", ev)


func _first_move_delta(plan: Dictionary) -> Dictionary:
	for p_val in (plan.get("planned", []) as Array):
		var p: Dictionary = p_val
		if str(p.get("action", "")) == "MOVE":
			var f: Array = p.get("from", [0, 0])
			var t: Array = p.get("to", [0, 0])
			return {"unit_id": str(p.get("unit_id", "")), "dq": int(t[0]) - int(f[0]), "dr": int(t[1]) - int(f[1])}
	return {"unit_id": "", "dq": 0, "dr": 0}


# --- S3: human/cloud parity ----------------------------------------------------

func _s3_parity() -> void:
	var ev := {}
	var ast := {"op": "INTERSECT", "args": [{"op": "CLASS", "class": "INFANTRY"}, {"op": "REGION", "region": "CENTER"}]}
	var ok := true
	for side in ["blue", "red"]:
		var cmd_a := TableCls.make_command("ADVANCE", ast, TableCls.target_direction("FORWARD"), "BALANCED")
		var wire := JSON.stringify(cmd_a)
		var parsed: Variant = JSON.parse_string(wire)
		var chk := ResponseCls.check_order(parsed, {"acting_side": side.to_upper()})
		ev["check_ok_" + side] = bool(chk.get("ok", false))
		var s_a := _fresh_sim()
		var plan_a: Dictionary = CompilerCls.plan(s_a, cmd_a, "", side)
		var s_b := _fresh_sim()
		var plan_b: Dictionary = CompilerCls.plan(s_b, chk.get("order", {}), "", side)
		var same_cmd := JSON.stringify(cmd_a) == JSON.stringify(chk.get("order", {}))
		var same_res := JSON.stringify(plan_a.get("resolved_units", [])) == JSON.stringify(plan_b.get("resolved_units", []))
		var same_plan := JSON.stringify(plan_a.get("planned", [])) == JSON.stringify(plan_b.get("planned", []))
		ev["same_command_" + side] = same_cmd
		ev["same_resolved_" + side] = same_res
		ev["same_planned_" + side] = same_plan
		ev["resolved_" + side] = plan_a.get("resolved_units", [])
		ev["plan_ok_" + side] = bool(plan_a.get("ok", false)) and bool(plan_b.get("ok", false))
		ok = ok and bool(chk.get("ok", false)) and same_cmd and same_res and same_plan \
			and bool(plan_a.get("ok", false)) and not (plan_a.get("resolved_units", []) as Array).is_empty()
	_record("s3_human_cloud_parity", "pass" if ok else "fail", ev)


# --- S4: sequential multi-order with revalidation ---------------------------------

func _s4_sequential() -> void:
	var sim := _fresh_sim()
	var ev := {}
	# Order 1 moves R_INF_1 adjacent to B_INF_1 (GREEN move keeps the action open).
	var o1 := TableCls.make_command("ADVANCE", TableCls.scope_units(["R_INF_1"]), TableCls.target_direction("FORWARD"))
	var r1: Dictionary = CompilerCls.execute(sim, o1, "", "red")
	ev["order1_status"] = str(r1.get("execution_status", "?"))
	ev["order1_executed"] = (r1.get("executed_units", []) as Array).size()
	var after1: Dictionary = sim.get_manager().get_unit_by_id("R_INF_1")
	ev["r_inf_1_after"] = [int(after1.get("q", 0)), int(after1.get("r", 0))]
	# Contrast: on a FRESH sim (pre-order-1 state) the same ATTACK is illegal
	# (2 hexes away). After order 1 it must plan clean — proving order 2 was
	# compiled against NEW state, not a stale upfront batch.
	var o2 := TableCls.make_command("ATTACK", TableCls.scope_units(["R_INF_1"]), TableCls.target_formation("B_INF_1"))
	var fresh := _fresh_sim()
	var p0: Dictionary = CompilerCls.plan(fresh, o2, "", "red")
	var codes0: Array = []
	for f0_val in (p0.get("failed", []) as Array):
		codes0.append(str((f0_val as Dictionary).get("code", "")))
	ev["order2_fresh_plan_ok"] = bool(p0.get("ok", false))
	ev["order2_fresh_codes"] = codes0
	var p2: Dictionary = CompilerCls.plan(sim, o2, "", "red")
	ev["order2_live_plan_ok"] = bool(p2.get("ok", false))
	var blue_before: int = int(sim.get_manager().get_unit_by_id("B_INF_1").get("soldier_count", 0))
	var r2: Dictionary = CompilerCls.execute(sim, o2, "", "red")
	var blue_after: int = int(sim.get_manager().get_unit_by_id("B_INF_1").get("soldier_count", 0))
	ev["order2_status"] = str(r2.get("execution_status", "?"))
	ev["blue_damage"] = blue_before - blue_after
	# Order 3: the turn continues after a live attack.
	var o3 := TableCls.make_command("HOLD", TableCls.scope_units(["R_CAV_1"]))
	var r3: Dictionary = CompilerCls.execute(sim, o3, "", "red")
	ev["order3_status"] = str(r3.get("execution_status", "?"))
	var ok := str(r1.get("execution_status", "")) == "EXECUTED" \
		and int(after1.get("q", 0)) < -23 \
		and not bool(p0.get("ok", false)) and codes0 == ["ILLEGAL_ATTACK"] \
		and bool(p2.get("ok", false)) and str(r2.get("execution_status", "")) == "EXECUTED" \
		and blue_after < blue_before \
		and str(r3.get("execution_status", "")) == "EXECUTED"
	_record("s4_sequential_multi_order", "pass" if ok else "fail", ev)


# --- S5: partial failure ----------------------------------------------------------

func _s5_partial_failure() -> void:
	var sim := _fresh_sim()
	var ev := {}
	var text := JSON.stringify({
		"plan": {"objective": "probe", "intent": "probe", "reconsider_if": "never"},
		"orders": [
			TableCls.make_command("PRESSURE", TableCls.scope_all_combat(), TableCls.target_direction("FORWARD")),
			TableCls.make_command("HOLD", TableCls.scope_class("INFANTRY")),
		],
	})
	var parsed := ResponseCls.parse(text, {"acting_side": "RED"})
	var orders: Array = parsed.get("orders", [])
	ev["parsed_ok"] = bool(parsed.get("ok", false))
	ev["order_count"] = orders.size()
	var codes: Array = []
	for o_val in orders:
		codes.append(str((o_val as Dictionary).get("code", "OK")))
	ev["order_codes"] = codes
	# Reject-and-continue: execute only the valid order.
	var executed := 0
	for o_val in orders:
		var o: Dictionary = o_val
		if not bool(o.get("ok", false)):
			continue
		var res: Dictionary = CompilerCls.execute(sim, o.get("order", {}), "", "red")
		executed += (res.get("executed_units", []) as Array).size()
	ev["executed_after_reject"] = executed
	var held: Dictionary = sim.get_manager().get_unit_by_id("R_INF_1")
	ev["r_inf_1_held"] = bool(held.get("action_ended", false))
	var ok := not bool(parsed.get("ok", false)) and codes == ["ACTION_DEFERRED", ""] \
		and executed == 1 and bool(held.get("action_ended", false))
	_record("s5_partial_failure", "pass" if ok else "fail", ev)


# --- S6: semantic gate -----------------------------------------------------------------

func _s6_semantic_gate() -> void:
	var ev := {}
	var ctx := {"acting_side": "RED"}
	var cases: Array = [
		[{"action": "FLY", "scope": {"kind": "ALL_COMBAT"}, "target": {"type": "DIRECTION", "direction": "FORWARD"}}, "UNKNOWN_ACTION"],
		[TableCls.make_command("PRESSURE", TableCls.scope_all_combat(), TableCls.target_direction("FORWARD")), "ACTION_DEFERRED"],
		[TableCls.make_command("ADVANCE", {"kind": "CLASS", "class": "BOGUS"}, TableCls.target_direction("FORWARD")), "INVALID_SCOPE"],
		[TableCls.make_command("ADVANCE", {"kind": "REGION", "region": "NOWHERE"}, TableCls.target_direction("FORWARD")), "INVALID_SCOPE"],
		[TableCls.make_command("ADVANCE", {"op": "CLASS", "class": "BOGUS"}, TableCls.target_direction("FORWARD")), "INVALID_SCOPE"],
		[TableCls.make_command("ATTACK", TableCls.scope_class("INFANTRY"), TableCls.target_direction("FORWARD")), "INVALID_TARGET"],
		[TableCls.make_command("ADVANCE", TableCls.scope_all_combat(), TableCls.target_direction("UP")), "INVALID_DIRECTION"],
		[TableCls.make_command("HOLD", TableCls.scope_selected()), "SELECTED_REJECTED"],
		[TableCls.make_command("HOLD", {"op": "SELECTED"}), "SELECTED_REJECTED"],
		[TableCls.make_command("HOLD", TableCls.scope_units(["B_INF_1"])), "SIDE_MISMATCH"],
		[TableCls.make_command("HOLD", {"op": "UNIT", "unit_id": "B_INF_1"}), "SIDE_MISMATCH"],
		[TableCls.make_command("ATTACK", TableCls.scope_units(["R_INF_1"]), TableCls.target_formation("R_CAV_1")), "SIDE_MISMATCH"],
	]
	var results: Array = []
	var ok := true
	for c in cases:
		var chk := ResponseCls.check_order((c as Array)[0], ctx)
		var want := str((c as Array)[1])
		var got := str(chk.get("code", "OK"))
		var pass_case := (not bool(chk.get("ok", false))) and got == want
		results.append({"want": want, "got": got, "pass": pass_case})
		ok = ok and pass_case
	# Order-level side echo + snapshot echo.
	var echo := TableCls.make_command("HOLD", TableCls.scope_all_friendly())
	echo["acting_side"] = "BLUE"
	var chk_echo := ResponseCls.check_order(echo, ctx)
	ok = ok and (not bool(chk_echo.get("ok", false))) and str(chk_echo.get("code", "")) == "SIDE_MISMATCH"
	ev["side_echo_rejected"] = str(chk_echo.get("code", ""))
	var stale := ResponseCls.parse(JSON.stringify({"orders": [TableCls.make_command("HOLD", TableCls.scope_all_friendly())], "snapshot_id": "WRONG"}), {"acting_side": "RED", "snapshot_id": "RIGHT"})
	ok = ok and (not bool(stale.get("ok", false))) and str(stale.get("code", "")) == "STALE_SNAPSHOT"
	ev["stale_rejected"] = str(stale.get("code", ""))
	var many: Array = []
	for i in range(ResponseCls.MAX_ORDERS + 1):
		many.append(TableCls.make_command("HOLD", TableCls.scope_all_friendly()))
	var chk_many := ResponseCls.parse(JSON.stringify({"orders": many}), ctx)
	ok = ok and (not bool(chk_many.get("ok", false))) and str(chk_many.get("code", "")) == "TOO_MANY_ORDERS"
	var chk_empty := ResponseCls.parse(JSON.stringify({"orders": []}), ctx)
	ok = ok and str(chk_empty.get("code", "")) == "EMPTY_ORDERS"
	var chk_garbage := ResponseCls.parse("not json at all", ctx)
	ok = ok and str(chk_garbage.get("code", "")) == "INVALID_JSON"
	var chk_blank := ResponseCls.parse("   ", ctx)
	ok = ok and str(chk_blank.get("code", "")) == "INVALID_JSON"
	# Valid control passes through with a canonical shape.
	var ctrl := ResponseCls.check_order(TableCls.make_command("ADVANCE", TableCls.scope_class("CAVALRY"), TableCls.target_direction("FORWARD")), ctx)
	ok = ok and bool(ctrl.get("ok", false))
	var cc: Dictionary = ctrl.get("order", {})
	ev["canonical_keys"] = cc.keys()
	ok = ok and cc.keys().has("stance")
	ev["cases"] = results
	_record("s6_semantic_gate", "pass" if ok else "fail", ev)


# --- S7: adapter serialization ----------------------------------------------------------

func _s7_adapter() -> void:
	var ev := {}
	var msgs: Array = [{"role": "system", "content": "sys"}, {"role": "user", "content": "hello"}]
	var ob := AdapterCls.build_openai_body("m1", msgs, 7, 0.2)
	ev["openai_keys"] = ob.keys()
	var ab := AdapterCls.build_anthropic_body("m2", msgs, 7, 0.0)
	ev["anthropic_keys"] = ab.keys()
	var ok := str((ob.get("response_format", {}) as Dictionary).get("type", "")) == "json_object" \
		and int(ob.get("max_tokens", 0)) == 7 and (ob.get("messages", []) as Array).size() == 2 \
		and str(ab.get("system", "")) == "sys" and (ab.get("messages", []) as Array).size() == 1 \
		and str(((ab.get("messages", []) as Array)[0] as Dictionary).get("role", "")) == "user"
	var want_json := JSON.stringify({"orders": []})
	var oc := AdapterCls.extract_openai_content({"choices": [{"message": {"content": want_json}}]})
	var ac := AdapterCls.extract_anthropic_content({"content": [{"type": "text", "text": "hi"}]})
	ev["extract_openai"] = oc
	ev["extract_anthropic"] = ac
	ok = ok and oc == want_json and ac == "hi"
	ok = ok and AdapterCls.extract_openai_content({}) == "" and AdapterCls.extract_anthropic_content({}) == ""
	for row in [[401, "UNAUTHORIZED"], [403, "UNAUTHORIZED"], [429, "RATE_LIMITED"], [404, "MODEL_MISSING"], [408, "TIMEOUT"], [500, "PROVIDER_ERROR"], [400, "HTTP_ERROR"], [200, "OK"]]:
		var cls := AdapterCls.classify_status(int((row as Array)[0]))
		if str(cls.get("code", "")) != str((row as Array)[1]):
			ok = false
	ev["status_map_ok"] = ok
	# No-secret preview + single-HTTP-owner scan.
	var cfg: ConfigCls = ConfigCls.new()
	cfg.provider_id = "openai"
	cfg.model = "m"
	cfg.endpoint = "https://x.local/v1/chat/completions"
	cfg.set_api_key("  " + CANARY + "\r\n")
	ev["key_trimmed"] = cfg.api_key == CANARY
	var prev := AdapterCls.request_preview(cfg, {"a": 1}, "sys")
	var prev_text := JSON.stringify(prev)
	ev["preview_has_key_flag"] = bool(prev.get("has_key", false))
	ev["preview_key_redacted"] = str(prev.get("key", "")) != CANARY and str(prev.get("key", "")).begins_with("****")
	ev["preview_leaks_canary"] = prev_text.find(CANARY) != -1
	ok = ok and bool(prev.get("has_key", false)) and prev_text.find(CANARY) == -1
	var http_owners: Array = []
	for path in CLOUD2_FILES:
		if not path.ends_with(".gd") or path.get_file() in ["cloud2_entry.gd", "cloud2_hier_entry.gd"]:
			continue # runners name HTTPRequest only to run ownership scans
		var text := _read_text(path)
		if text.find("HTTPRequest") != -1:
			http_owners.append(path)
	ev["http_owners"] = http_owners
	ok = ok and http_owners == ["res://scripts/cloud2/cloud2_adapter.gd"]
	_record("s7_adapter_serialization", "pass" if ok else "fail", ev)


# --- S8: response contract -----------------------------------------------------------------

func _s8_response() -> void:
	var ev := {}
	var long := ""
	for i in range(600):
		long += "x"
	var doc := {
		"plan": {"objective": "take center", "intent": "advance guards", "reconsider_if": "hq threatened"},
		"orders": [
			TableCls.make_command("ADVANCE", TableCls.scope_class("CAVALRY"), TableCls.target_direction("FORWARD")),
			TableCls.make_command("HOLD", TableCls.scope_class("HQ")),
		],
		"rationale": {"objective": long, "observations": "o", "risk": "r", "intent": "i", "reconsider_if": "c"},
	}
	var parsed := ResponseCls.parse(JSON.stringify(doc), {"acting_side": "RED"})
	ev["ok"] = bool(parsed.get("ok", false))
	ev["order_count"] = int(parsed.get("order_count", 0))
	ev["rationale_clipped"] = str((parsed.get("rationale", {}) as Dictionary).get("objective", "")).length()
	var fenced := ResponseCls.parse("```json\n" + JSON.stringify(doc) + "\n```", {"acting_side": "RED"})
	ev["fenced_ok"] = bool(fenced.get("ok", false))
	var summary := ResponseCls.render_summary(parsed)
	ev["summary_head"] = summary.left(80)
	var ok := bool(parsed.get("ok", false)) and int(parsed.get("order_count", 0)) == 2 \
		and str((parsed.get("rationale", {}) as Dictionary).get("objective", "")).length() == ResponseCls.MAX_TEXT \
		and bool(fenced.get("ok", false)) and summary.contains("CLOUD RESPONSE")
	_record("s8_response_contract", "pass" if ok else "fail", ev)


# --- S9: plan memory --------------------------------------------------------------------------

func _s9_plan_memory() -> void:
	var ev := {}
	var mem: PlanCls = PlanCls.new()
	var long := ""
	for i in range(400):
		long += "y"
	mem.update_from_plan({"objective": long, "intent": "i", "reconsider_if": "c"}, 3)
	mem.note_result(long + long)
	var pkt := mem.to_packet()
	ev["keys"] = pkt.keys()
	ev["objective_len"] = str(pkt.get("objective", "")).length()
	ev["last_result_len"] = str(pkt.get("last_result", "")).length()
	ev["has_plan"] = bool(pkt.get("has_plan", false))
	ev["turn"] = int(pkt.get("turn", 0))
	var pkt_text := JSON.stringify(pkt)
	var truth_leak := pkt_text.find("soldier_count") != -1 or pkt_text.find("remaining_mp") != -1 or pkt_text.find("B_INF") != -1
	ev["truth_leak"] = truth_leak
	var ok := str(pkt.get("objective", "")).length() == PlanCls.MAX_FIELD \
		and str(pkt.get("last_result", "")).length() == PlanCls.MAX_FIELD \
		and bool(pkt.get("has_plan", false)) and int(pkt.get("turn", 0)) == 3 and not truth_leak
	mem.reset()
	ok = ok and not bool(mem.to_packet().get("has_plan", true))
	_record("s9_plan_memory_compact", "pass" if ok else "fail", ev)


# --- S10: packet shape ------------------------------------------------------------------------------

func _s10_packet() -> void:
	var sim := _fresh_sim()
	var ev := {}
	var obs: Dictionary = ObsCls.build(sim, "red")
	var catalog := TableCls.build_catalog(obs)
	var mem: PlanCls = PlanCls.new()
	mem.update_from_plan({"objective": "o", "intent": "i", "reconsider_if": "c"}, 1)
	var packet := PacketCls.build(obs, catalog, mem.to_packet(), {"turn": 0, "status": "NONE"})
	var shape := PacketCls.validate_shape(packet)
	ev["shape_ok"] = bool(shape.get("ok", false))
	ev["acting_side"] = str(packet.get("acting_side", ""))
	ev["has_system_prompt"] = PacketCls.SYSTEM_PROMPT.contains("RED field general") and PacketCls.SYSTEM_PROMPT.contains("Godot owns legality")
	var sc: Dictionary = packet.get("scope_contract", {})
	var tc: Dictionary = packet.get("target_contract", {})
	ev["scope_classes_live"] = (sc.get("classes", []) as Array) == TableCls.KNOWN_CLASSES
	ev["target_dirs_live"] = (tc.get("directions", []) as Array) == TableCls.DIRECTIONS
	ev["orientation_red"] = str(((packet.get("battlefield", {}) as Dictionary).get("orientation", {}) as Dictionary).get("red_forward", ""))
	var ptext := JSON.stringify(packet)
	ev["secret_keys_present"] = ptext.find("api_key") != -1 or ptext.find("Authorization") != -1 or ptext.find(CANARY) != -1
	ev["world_truth_present"] = ptext.find("world_truth") != -1 or ptext.find("\"plan\":") != -1
	var ekeys := {}
	for e_val in (packet.get("enemy_units", []) as Array):
		for k in (e_val as Dictionary).keys():
			ekeys[str(k)] = true
	ev["enemy_keys"] = ekeys.keys()
	var want_keys := ["unit_id", "side", "class", "q", "r", "region", "contact_state", "troop_estimate", "last_seen_turn"]
	var keys_ok := ekeys.keys().size() == want_keys.size()
	for k in want_keys:
		keys_ok = keys_ok and ekeys.has(k)
	var ok := bool(shape.get("ok", false)) and str(packet.get("acting_side", "")) == "RED" \
		and bool(ev["has_system_prompt"]) and bool(ev["scope_classes_live"]) and bool(ev["target_dirs_live"]) \
		and str(ev["orientation_red"]).contains("-q") and not bool(ev["secret_keys_present"]) \
		and not bool(ev["world_truth_present"]) and keys_ok
	_record("s10_packet_shape", "pass" if ok else "fail", ev)


# --- S11: no direct mutation ---------------------------------------------------------------------

func _s11_no_mutation() -> void:
	var sim := _fresh_sim()
	var ev := {}
	var fp0 := str(sim.fingerprint())
	var obs: Dictionary = ObsCls.build(sim, "red")
	var catalog := TableCls.build_catalog(obs)
	var mem: PlanCls = PlanCls.new()
	var packet := PacketCls.build(obs, catalog, mem.to_packet(), {})
	var parsed := ResponseCls.parse(JSON.stringify({"orders": [TableCls.make_command("ADVANCE", TableCls.scope_all_combat(), TableCls.target_direction("FORWARD"))]}), {"acting_side": "RED"})
	var plan: Dictionary = CompilerCls.plan(sim, TableCls.make_command("ADVANCE", TableCls.scope_all_combat(), TableCls.target_direction("FORWARD")), "", "red")
	ev["parsed_ok"] = bool(parsed.get("ok", false))
	ev["plan_ok"] = bool(plan.get("ok", false))
	var fp1 := str(sim.fingerprint())
	ev["fingerprint_stable"] = fp0 == fp1
	# Response/packet layers own no mutating calls (static scan).
	var mutating := ["do_move", "do_attack", "do_hold", "execute_move", "execute_attack", "notify_mutation", ".fingerprint("]
	var hits: Array = []
	for path in ["res://scripts/cloud2/cloud2_response.gd", "res://scripts/cloud2/cloud2_turn_packet.gd", "res://scripts/cloud2/cloud2_plan_memory.gd"]:
		var text := _read_text(path)
		for tok in mutating:
			if text.find(tok) != -1:
				hits.append("%s:%s" % [path.get_file(), tok])
	ev["mutating_tokens"] = hits
	var ok := fp0 == fp1 and hits.is_empty() and bool(parsed.get("ok", false)) and bool(plan.get("ok", false))
	_record("s11_no_direct_mutation", "pass" if ok else "fail", ev)


# --- S12: no RL/SFT/Qwen code -----------------------------------------------------------------------

func _s12_no_rl() -> void:
	var ev := {}
	var hits: Array = []
	for path in CLOUD2_FILES:
		if path.get_file() == "cloud2_entry.gd":
			continue # this runner holds the banned-token list itself
		var text := _read_text(path).to_lower()
		for tok in BANNED_ML:
			if _has_token(text, tok):
				hits.append("%s:%s" % [path.get_file(), tok])
	ev["cloud2_hits"] = hits
	ev["entry_excluded_note"] = "cloud2_entry.gd excluded: it literally contains BANNED_ML to run this scan"
	var ehits: Array = []
	for epath in EDITED_FILES:
		var text2 := _read_text(epath).to_lower()
		for tok in EDITED_NARROW:
			if _has_token(text2, tok):
				ehits.append("%s:%s" % [epath.get_file(), tok])
	ev["edited_hits"] = ehits
	# title_screen.gd baseline carries 4 "qwen" lines (1 comment + 3
	# pre-existing Ollama default-model strings); the Step-2 CLOUD2 block
	# must add zero.
	var title_text := _read_text("res://scripts/ui/title_screen.gd")
	var title_qwen := 0
	for line in title_text.to_lower().split("\n"):
		if line.find("qwen") != -1:
			title_qwen += 1
	ev["title_qwen_lines"] = title_qwen
	var c2block := _marked_block(title_text, "# CLOUD2-DEV-ENTRY-BEGIN", "# CLOUD2-DEV-ENTRY-END")
	ev["c2_block_qwen"] = c2block.to_lower().find("qwen") != -1
	ev["c2_block_present"] = not c2block.is_empty()
	# Step-2 paths add no second engine: cloud2 must not carry engine math tokens.
	var engine_toks := ["find_route", "calculate_combat", "execute_player_stepwise_move", "execute_attack(", "execute_move("]
	var eng_hits: Array = []
	for path in CLOUD2_FILES:
		if not path.ends_with(".gd") or path.get_file() == "cloud2_entry.gd":
			continue # this runner lists the tokens only to run this scan
		var text3 := _read_text(path)
		for tok in engine_toks:
			if text3.find(tok) != -1:
				eng_hits.append("%s:%s" % [path.get_file(), tok])
	ev["engine_token_hits"] = eng_hits
	var ok := hits.is_empty() and ehits.is_empty() and title_qwen == 4 and not c2block.is_empty() and c2block.to_lower().find("qwen") == -1 and eng_hits.is_empty()
	_record("s12_no_rl_code", "pass" if ok else "fail", ev)


func _has_token(hay_lower: String, tok: String) -> bool:
	# Word-ish match without RegEx cost: pad with sentinels and require a
	# non-identifier char on both sides.
	var pad := "#" + hay_lower + "#"
	var needle := tok.to_lower()
	var at := pad.find(needle)
	while at != -1:
		var before := pad.substr(at - 1, 1)
		var after := pad.substr(at + needle.length(), 1)
		if not _is_ident(before) and not _is_ident(after):
			return true
		at = pad.find(needle, at + 1)
	return false


func _marked_block(src: String, bbegin: String, bend: String) -> String:
	var a := src.find(bbegin)
	var b := src.find(bend)
	if a == -1 or b == -1 or b <= a:
		return ""
	return src.substr(a, b - a)


func _is_ident(ch: String) -> bool:
	if ch.is_empty():
		return false
	var c := ch.unicode_at(0)
	return (c >= 48 and c <= 57) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or c == 95


# --- S13: secret hygiene --------------------------------------------------------------------------------

func _s13_secret_hygiene() -> void:
	var ev := {}
	var cfg: ConfigCls = ConfigCls.new()
	cfg.provider_id = "openai"
	cfg.model = "m"
	cfg.endpoint = "https://x.local/v1"
	cfg.set_api_key(CANARY)
	var safe := cfg.to_safe_dict()
	var safe_text := JSON.stringify(safe)
	ev["safe_has_key_flag"] = bool(safe.get("has_key", false))
	ev["safe_leaks"] = safe_text.find(CANARY) != -1
	var rec := {"turn": 1, "api_key": CANARY, "nested": {"authorization": "Bearer " + CANARY, "ok": 1}}
	var scrubbed: Dictionary = LoggerCls.scrub(rec)
	var scrub_text := JSON.stringify(scrubbed)
	ev["scrub_leaks"] = scrub_text.find(CANARY) != -1
	ev["scrub_keeps_data"] = int((scrubbed.get("nested", {}) as Dictionary).get("ok", 0)) == 1
	var logged := LoggerCls.log_turn({"timestamp": "t", "battle_id": "b", "turn": 1, "acting_side": "RED", "api_key": CANARY, "status": "PROBE"})
	ev["log_ok"] = bool(logged.get("ok", false))
	var log_text := _read_text(str(logged.get("path", "")))
	ev["log_leaks"] = log_text.find(CANARY) != -1
	var ok := bool(safe.get("has_key", false)) and safe_text.find(CANARY) == -1 \
		and scrub_text.find(CANARY) == -1 and int((scrubbed.get("nested", {}) as Dictionary).get("ok", 0)) == 1 \
		and bool(logged.get("ok", false)) and log_text.find(CANARY) == -1
	_record("s13_secret_hygiene", "pass" if ok else "fail", ev)


func _read_text(res_path: String) -> String:
	if res_path.is_empty() or not FileAccess.file_exists(res_path):
		return ""
	var f := FileAccess.open(res_path, FileAccess.READ)
	if f == null:
		return ""
	var t := f.get_as_text()
	f.close()
	return t


# --- S20: realistic response envelopes (cold fix) -----------------------------------

var _sig_turn := {}
var _sig_chat := {}


func _on_test_turn(request_id: String, result: Dictionary) -> void:
	_sig_turn = {"request_id": request_id, "result": (result as Dictionary).duplicate(true)}


func _on_test_chat(request_id: String, result: Dictionary) -> void:
	_sig_chat = {"request_id": request_id, "result": (result as Dictionary).duplicate(true)}


## Drive the REAL _on_request_completed with a realistic raw HTTP body
## (no network): proves the live handler classifies what mocks bypass.
func _drive_adapter(ad: AdapterCls, req_id: String, is_chat: bool, body_text: String) -> void:
	ad._active_request_id = req_id
	ad._active_t0_msec = Time.get_ticks_msec()
	ad._active_provider = "opencode"
	ad._active_model = "deepseek-v4.1-flash"
	ad._active_transport = "openai_chat"
	ad._active_is_test = false
	ad._active_is_chat = is_chat
	ad._active_key = ""
	ad._on_request_completed(HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(), body_text.to_utf8_buffer())


func _s20_response_envelope() -> void:
	var ev := {}
	var ok := true
	var chat := ConfigCls.TRANSPORT_OPENAI
	var final_json := JSON.stringify({
		"plan": {"objective": "probe the BLUE line", "intent": "advance guards", "reconsider_if": "hq threatened"},
		"orders": [TableCls.make_command("ADVANCE", TableCls.scope_class("INFANTRY"), TableCls.target_direction("FORWARD"))],
	})
	# A. normal chat completion: content = valid final JSON.
	var body_a := JSON.stringify({"id": "chatcmpl-s20a", "object": "chat.completion",
		"model": "deepseek-v4.1-flash",
		"choices": [{"index": 0, "message": {"role": "assistant", "content": final_json}, "finish_reason": "stop"}]})
	var ja := AdapterCls.classify_http_body(chat, 200, body_a)
	ev["a_ok"] = bool(ja.get("ok", false))
	ev["a_content_exact"] = str(ja.get("content_text", "")) == final_json
	ev["a_finish"] = str(ja.get("finish_reason", ""))
	var parsed_a := ResponseCls.parse(str(ja.get("content_text", "")), {"acting_side": "RED"})
	ev["a_parses_to_orders"] = bool(parsed_a.get("ok", false)) and int(parsed_a.get("order_count", 0)) == 1
	ok = ok and bool(ja.get("ok", false)) and str(ja.get("content_text", "")) == final_json \
		and str(ja.get("finish_reason", "")) == "stop" and bool(parsed_a.get("ok", false))
	# B. reasoning present, content empty, finish length: the live failure.
	var marker := "S20_PRIVATE_WORKING_NOTES_7f3a"
	var body_b := JSON.stringify({"id": "chatcmpl-s20b",
		"choices": [{"index": 0, "message": {"role": "assistant", "content": "",
			"reasoning_content": marker + " the model thought here at length"}, "finish_reason": "length"}]})
	var jb := AdapterCls.classify_http_body(chat, 200, body_b)
	var env_b: Dictionary = jb.get("envelope", {})
	ev["b_code"] = str(jb.get("code", ""))
	ev["b_content_empty"] = str(jb.get("content_text", "")) == ""
	ev["b_reasoning_seen"] = bool(env_b.get("reasoning_present", false))
	ev["b_reasoning_chars"] = int(env_b.get("reasoning_chars", 0))
	var env_b_text := JSON.stringify(env_b) + str(jb.get("detail", ""))
	ev["b_no_private_text"] = env_b_text.find(marker) == -1
	ev["b_shim_never_reasoning"] = AdapterCls.extract_openai_content(JSON.parse_string(body_b)) == ""
	ok = ok and str(jb.get("code", "")) == "REASONING_BUDGET_EXHAUSTED" \
		and str(jb.get("content_text", "")) == "" and bool(env_b.get("reasoning_present", false)) \
		and int(env_b.get("reasoning_chars", 0)) > 0 and env_b_text.find(marker) == -1 \
		and AdapterCls.extract_openai_content(JSON.parse_string(body_b)) == ""
	# C. reasoning present WITH valid final JSON: content wins, reasoning ignored.
	var body_c := JSON.stringify({"choices": [{"message": {"role": "assistant",
		"content": final_json, "reasoning_content": marker}, "finish_reason": "stop"}]})
	var jc := AdapterCls.classify_http_body(chat, 200, body_c)
	ev["c_ok"] = bool(jc.get("ok", false))
	ev["c_content_only"] = str(jc.get("content_text", "")) == final_json
	ok = ok and bool(jc.get("ok", false)) and str(jc.get("content_text", "")) == final_json
	# D. content null: empty final, never stringified "<null>".
	var body_d := JSON.stringify({"choices": [{"message": {"role": "assistant", "content": null}, "finish_reason": "stop"}]})
	var jd := AdapterCls.classify_http_body(chat, 200, body_d)
	ev["d_code"] = str(jd.get("code", ""))
	ev["d_content_blank"] = str(jd.get("content_text", "")) == ""
	ok = ok and str(jd.get("code", "")) == "EMPTY_MODEL_CONTENT" and str(jd.get("content_text", "")) == ""
	# E. content as text-block array: documented text blocks join; other types skipped.
	var blocks_e: Array = []
	blocks_e.append({"type": "text", "text": "{\"orders\": "})
	blocks_e.append({"type": "image_url", "image_url": {"url": "http://x/y.png"}})
	blocks_e.append({"type": "output_text", "text": "[]}"})
	var body_e := JSON.stringify({"choices": [{"message": {"role": "assistant", "content": blocks_e}, "finish_reason": "stop"}]})
	var je := AdapterCls.classify_http_body(chat, 200, body_e)
	ev["e_ok"] = bool(je.get("ok", false))
	ev["e_joined"] = str(je.get("content_text", ""))
	ok = ok and bool(je.get("ok", false)) and str(je.get("content_text", "")) == "{\"orders\": []}"
	var body_e2 := JSON.stringify({"choices": [{"message": {"content": {"oops": 1}}, "finish_reason": "stop"}]})
	var je2 := AdapterCls.classify_http_body(chat, 200, body_e2)
	ev["e2_code"] = str(je2.get("code", ""))
	ok = ok and str(je2.get("code", "")) == "UNSUPPORTED_RESPONSE_SHAPE"
	# F. SSE-looking body vs plain garbage.
	var jf := AdapterCls.classify_http_body(chat, 200, "event: message\ndata: {\"x\":1}\n\ndata: [DONE]\n")
	ev["f_code"] = str(jf.get("code", ""))
	var jf2 := AdapterCls.classify_http_body(chat, 200, "<html>502 Bad Gateway</html>")
	ev["f2_code"] = str(jf2.get("code", ""))
	ev["f2_sse"] = bool((jf2.get("envelope", {}) as Dictionary).get("sse_suspected", true))
	ok = ok and str(jf.get("code", "")) == "STREAMING_RESPONSE_DETECTED" \
		and str(jf2.get("code", "")) == "NON_JSON_ENVELOPE" \
		and not bool((jf2.get("envelope", {}) as Dictionary).get("sse_suspected", true))
	# G. tool calls with no final text.
	var body_g := JSON.stringify({"choices": [{"message": {"role": "assistant", "content": "",
		"tool_calls": [{"id": "t1", "type": "function", "function": {"name": "probe", "arguments": "{}"}}]},
		"finish_reason": "tool_calls"}]})
	var jg := AdapterCls.classify_http_body(chat, 200, body_g)
	ev["g_code"] = str(jg.get("code", ""))
	ok = ok and str(jg.get("code", "")) == "TOOL_CALLS_NO_TEXT"
	# H. refusal, and content-filter finish.
	var body_h := JSON.stringify({"choices": [{"message": {"role": "assistant", "content": "",
		"refusal": "I cannot help with that."}, "finish_reason": "stop"}]})
	var jh := AdapterCls.classify_http_body(chat, 200, body_h)
	ev["h_code"] = str(jh.get("code", ""))
	var jh2 := AdapterCls.classify_http_body(chat, 200, JSON.stringify(
		{"choices": [{"message": {"content": ""}, "finish_reason": "content_filter"}]}))
	ev["h2_code"] = str(jh2.get("code", ""))
	ok = ok and str(jh.get("code", "")) == "MODEL_REFUSAL" and str(jh2.get("code", "")) == "MODEL_REFUSAL"
	# I. malformed shapes + length-without-reasoning + oversize body.
	var ji := AdapterCls.classify_http_body(chat, 200, JSON.stringify({"id": "x"}))
	ev["i_code"] = str(ji.get("code", ""))
	var jk := AdapterCls.classify_http_body(chat, 200, JSON.stringify(
		{"choices": [{"message": {"content": ""}, "finish_reason": "length"}]}))
	ev["k_code"] = str(jk.get("code", ""))
	var big := "x"
	while big.length() <= AdapterCls.BODY_SIZE_LIMIT:
		big += big
	var jj := AdapterCls.classify_http_body(chat, 200, big)
	ev["j_code"] = str(jj.get("code", ""))
	ev["j_chars"] = big.length()
	ok = ok and str(ji.get("code", "")) == "UNSUPPORTED_RESPONSE_SHAPE" \
		and str(jk.get("code", "")) == "FINISH_LENGTH_NO_FINAL" \
		and str(jj.get("code", "")) == "RESPONSE_TOO_LARGE"
	# L/M. sibling transports share the typed contract.
	var jl := AdapterCls.classify_http_body(ConfigCls.TRANSPORT_ANTHROPIC, 200, JSON.stringify(
		{"stop_reason": "end_turn", "content": [{"type": "text", "text": "hi"}]}))
	var jl2 := AdapterCls.classify_http_body(ConfigCls.TRANSPORT_ANTHROPIC, 200, JSON.stringify(
		{"stop_reason": "max_tokens", "content": []}))
	var jm := AdapterCls.classify_http_body(ConfigCls.TRANSPORT_RESPONSES, 200, JSON.stringify(
		{"status": "completed", "output_text": "hi"}))
	ev["l_ok"] = bool(jl.get("ok", false))
	ev["l2_code"] = str(jl2.get("code", ""))
	ev["m_ok"] = bool(jm.get("ok", false))
	ok = ok and bool(jl.get("ok", false)) and str(jl2.get("code", "")) == "FINISH_LENGTH_NO_FINAL" \
		and bool(jm.get("ok", false))
	# N. key material in a malformed body is redacted from diagnostics.
	var jn := AdapterCls.classify_http_body(chat, 200, "data: key=" + CANARY + "\n", CANARY)
	var prefix_n := str(jn.get("body_prefix", ""))
	ev["n_code"] = str(jn.get("code", ""))
	ev["n_redacted"] = prefix_n.find(CANARY) == -1
	ok = ok and prefix_n.find(CANARY) == -1
	# Budgets + retry policy pins.
	ev["turn_budget"] = AdapterCls.TURN_MAX_TOKENS
	ev["retry_budget"] = AdapterCls.TURN_RETRY_MAX_TOKENS
	ok = ok and AdapterCls.TURN_MAX_TOKENS == 4096 and AdapterCls.TURN_RETRY_MAX_TOKENS == 8192
	var pol_ok := TurnControllerCls.should_auto_retry({"ok": false, "code": "REASONING_BUDGET_EXHAUSTED"}, 0) \
		and TurnControllerCls.should_auto_retry({"ok": false, "code": "FINISH_LENGTH_NO_FINAL"}, 0)
	for bad in ["TIMEOUT", "UNAUTHORIZED", "MODEL_REFUSAL", "EMPTY_MODEL_CONTENT",
			"TOOL_CALLS_NO_TEXT", "NON_JSON_ENVELOPE", "SIDE_MISMATCH", "STALE_SNAPSHOT", "INVALID_REQUEST"]:
		pol_ok = pol_ok and not TurnControllerCls.should_auto_retry({"ok": false, "code": bad}, 0)
	pol_ok = pol_ok and not TurnControllerCls.should_auto_retry({"ok": false, "code": "REASONING_BUDGET_EXHAUSTED"}, 1) \
		and not TurnControllerCls.should_auto_retry({"ok": true}, 0)
	ev["retry_policy_ok"] = pol_ok
	ok = ok and pol_ok
	# Prompt: one exact valid example + final-first + static contract.
	ev["prompt_has_contract"] = PacketCls.SYSTEM_PROMPT.contains("STATIC CONTRACT")
	ev["prompt_has_final_first"] = PacketCls.SYSTEM_PROMPT.contains("FINAL RESPONSE RULES")
	ev["prompt_has_example"] = PacketCls.SYSTEM_PROMPT.contains(PacketCls.VALID_EXAMPLE)
	var ex := ResponseCls.parse(PacketCls.VALID_EXAMPLE, {"acting_side": "RED"})
	ev["example_ok"] = bool(ex.get("ok", false))
	ev["example_orders"] = int(ex.get("order_count", 0))
	ok = ok and bool(ex.get("ok", false)) and int(ex.get("order_count", 0)) == 1 \
		and PacketCls.SYSTEM_PROMPT.contains("STATIC CONTRACT") \
		and PacketCls.SYSTEM_PROMPT.contains("FINAL RESPONSE RULES")
	# Packet: compacted catalog keeps dynamics, drops repeated statics.
	var sim := _fresh_sim()
	var obs: Dictionary = ObsCls.build(sim, "red")
	var catalog := TableCls.build_catalog(obs)
	var slim := PacketCls.compact_catalog(catalog)
	var slim_ok := slim.size() == catalog.size()
	var dropped := true
	for row_val in slim:
		var row: Dictionary = row_val
		if row.has("movement_policies") or row.has("stances") or row.has("stance_note"):
			dropped = false
		if not row.has("action_family") or not row.has("allowed_scopes") \
				or not row.has("allowed_targets") or not row.has("executable"):
			slim_ok = false
	var raw_chars := JSON.stringify(catalog).length()
	var slim_chars := JSON.stringify(slim).length()
	ev["catalog_raw_chars"] = raw_chars
	ev["catalog_slim_chars"] = slim_chars
	ev["catalog_saved"] = raw_chars - slim_chars
	ok = ok and slim_ok and dropped and slim_chars < raw_chars and (raw_chars - slim_chars) > 1500
	var mem: PlanCls = PlanCls.new()
	mem.update_from_plan({"objective": "o", "intent": "i", "reconsider_if": "c"}, 1)
	var packet := PacketCls.build(obs, catalog, mem.to_packet(), {"turn": 0, "status": "NONE"})
	var packet_chars := JSON.stringify(packet).length()
	ev["packet_chars"] = packet_chars
	ev["packet_baseline_pre_fix"] = 10967 # measured pre-fix on this exact scenario+seed
	ok = ok and packet_chars < 10967 and packet_chars < 9500
	# Live drives through the real handler: turn ok, turn exhausted, chat prose.
	var ad := AdapterCls.new()
	root.add_child(ad)
	ad.turn_finished.connect(_on_test_turn)
	ad.chat_finished.connect(_on_test_chat)
	_sig_turn = {}
	_drive_adapter(ad, "s20a", false, body_a)
	var ra: Dictionary = (_sig_turn.get("result", {}) as Dictionary).duplicate(true)
	ev["drive_a_ok"] = bool(ra.get("ok", false))
	ev["drive_a_content"] = str(ra.get("content_text", "")) == final_json
	ev["drive_a_env"] = str((ra.get("envelope", {}) as Dictionary).get("finish_reason", ""))
	_sig_turn = {}
	_drive_adapter(ad, "s20b", false, body_b)
	var rb: Dictionary = (_sig_turn.get("result", {}) as Dictionary).duplicate(true)
	ev["drive_b_code"] = str(rb.get("code", ""))
	ev["drive_b_no_text"] = str(rb.get("content_text", "-missing-")) == "-missing-"
	_sig_chat = {}
	_drive_adapter(ad, "s20chat", true, JSON.stringify({"choices": [
		{"message": {"role": "assistant", "content": "Hello, commander."}, "finish_reason": "stop"}]}))
	var rc: Dictionary = (_sig_chat.get("result", {}) as Dictionary).duplicate(true)
	ev["drive_chat_ok"] = bool(rc.get("ok", false))
	ev["drive_chat_text"] = str(rc.get("content_text", ""))
	ok = ok and bool(ra.get("ok", false)) and str(ra.get("content_text", "")) == final_json \
		and str((ra.get("envelope", {}) as Dictionary).get("finish_reason", "")) == "stop" \
		and str(rb.get("code", "")) == "REASONING_BUDGET_EXHAUSTED" \
		and bool(rc.get("ok", false)) and str(rc.get("content_text", "")) == "Hello, commander."
	# request_turn accepts the retry budget override (mock dispatch leg).
	ad.turn_finished.disconnect(_on_test_turn)
	ad.chat_finished.disconnect(_on_test_chat)
	var cfg: ConfigCls = ConfigCls.new()
	cfg.provider_id = "openai"
	cfg.model = "m"
	cfg.endpoint = "https://x.local/v1/chat/completions"
	cfg.set_api_key(CANARY)
	cfg.mark_test_result(true, "CONNECTED", "s20 override probe")
	ad.mock_mode = true
	var started := ad.request_turn("s20r", {"p": 1}, cfg, "sys", AdapterCls.TURN_RETRY_MAX_TOKENS)
	ev["override_started"] = bool(started.get("ok", false))
	ok = ok and bool(started.get("ok", false))
	_record("s20_response_envelope", "pass" if ok else "fail", ev)


# --- Part 2: live scenes ---------------------------------------------------------------

var _live2: Node = null
var _live1: Node = null
var _sig_phase := {}


func _on_test_phase(result: Dictionary) -> void:
	_sig_phase = result.duplicate(true)


func _mock_config(mount: Node) -> void:
	var cfg: ConfigCls = mount.get("cloud_config") as ConfigCls
	cfg.provider_id = "openai"
	cfg.model = "mock-fixture"
	cfg.endpoint = "https://mock.local/v1/chat/completions"
	cfg.set_api_key(CANARY) # mock never networks; canary proves hygiene
	cfg.mark_test_result(true, "CONNECTED", "mock test harness")
	var ad: Node = mount.get("cloud_adapter") as Node
	ad.set("mock_mode", true)


func _mock_fixture_turn() -> Dictionary:
	return {"ok": true, "latency_ms": 7, "content_text": JSON.stringify({
		"plan": {"objective": "probe the BLUE line", "intent": "advance guards, hold rear", "reconsider_if": "hq threatened"},
		"orders": [
			TableCls.make_command("ADVANCE", TableCls.scope_class("CAVALRY"), TableCls.target_direction("FORWARD")),
			TableCls.make_command("ADVANCE", TableCls.scope_class("INFANTRY"), TableCls.target_direction("FORWARD")),
			TableCls.make_command("HOLD", TableCls.scope_all_friendly()),
		],
		"rationale": {"objective": "probe", "observations": "flat field", "risk": "low", "intent": "advance", "reconsider_if": "x"},
	})}


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


func _wait_state(controller: Node, phases: Array, budget: int) -> Dictionary:
	var frames := 0
	while frames < budget:
		await process_frame
		frames += 1
		var st: Dictionary = controller.call("get_state")
		if str(st.get("phase", "")) in phases:
			return st
	return {}


func _live_part() -> void:
	var packed: PackedScene = load(CLOUD2_SCENE)
	if packed == null:
		_record("s14_live_red_full_info", "fail", {"error": "cloud2 scene failed to load"})
		_record("s15_live_cloud_turn", "fail", {"error": "cloud2 scene failed to load"})
		_record("s16_live_step_pause", "fail", {"error": "cloud2 scene failed to load"})
		_record("s17_live_failure_safety", "fail", {"error": "cloud2 scene failed to load"})
		_record("s18_live_step1_intact", "fail", {"error": "cloud2 scene failed to load"})
		return
	_live2 = packed.instantiate()
	root.add_child(_live2)
	var mount: Node = _live2.get_node_or_null("Cloud2LiveMount")
	var booted := await _wait_mount(mount, 3600)
	if not booted or mount == null:
		var err := {"error": "mount timeout", "mount_error": str(mount.get("mount_error")) if mount != null else "no mount node"}
		_record("s14_live_red_full_info", "fail", err)
		_record("s15_live_cloud_turn", "fail", err)
		_record("s16_live_step_pause", "fail", err)
		_record("s17_live_failure_safety", "fail", err)
		_live2.queue_free()
		await _live_s18()
		return
	await _live_s14(mount)
	await _live_s15(mount)
	await _live_s16(mount)
	await _live_s17(mount)
	_live2.queue_free()
	for i in range(10):
		await process_frame
	await _live_s18()


func _live_s14(mount: Node) -> void:
	var ev := {}
	var shell: Node = mount.get("shell") as Node
	var bridge: RefCounted = mount.get("bridge") as RefCounted
	var dock: Node = mount.get("dock") as Node
	ev["red_mode"] = str(shell.call("red_controller_mode"))
	ev["controller_bound"] = shell.get("cloud_red_controller") == mount.get("cloud_controller")
	ev["fog_null"] = shell.get("_fog") == null
	ev["sandbox_scene"] = bool(shell.get("is_step0_sandbox"))
	var obs: Dictionary = ObsCls.build(bridge, "red")
	ev["obs_ok"] = bool(obs.get("ok", false))
	var friendlies: Array = obs.get("friendly_units", [])
	var enemies: Array = obs.get("known_enemy_units", [])
	ev["friendly_count"] = friendlies.size()
	ev["enemy_count"] = enemies.size()
	var cur := 0
	var stale := 0
	for e_val in enemies:
		if str((e_val as Dictionary).get("contact_state", "")) == "current_visible":
			cur += 1
		else:
			stale += 1
	ev["enemy_current"] = cur
	ev["enemy_stale"] = stale
	ev["snapshot"] = str(obs.get("snapshot_id", ""))
	ev["cloud_tab"] = dock.call("get_cloud_panel") != null
	var ok: bool = str(shell.call("red_controller_mode")) == "CLOUD" \
		and shell.get("cloud_red_controller") == mount.get("cloud_controller") \
		and shell.get("_fog") == null and bool(shell.get("is_step0_sandbox")) \
		and bool(obs.get("ok", false)) and friendlies.size() == 10 and enemies.size() == 10 \
		and cur == 10 and stale == 0 and dock.call("get_cloud_panel") != null
	_record("s14_live_red_full_info", "pass" if ok else "fail", ev)


func _live_s15(mount: Node) -> void:
	var ev := {}
	_mock_config(mount)
	var ad: Node = mount.get("cloud_adapter") as Node
	(ad.get("mock_queue") as Array).append(_mock_fixture_turn())
	var controller: Node = mount.get("cloud_controller") as Node
	controller.call("set_mode", "AUTO")
	controller.call("set_control_mode", "LEGACY_DIRECT") # benchmark path under test here
	var shell: Node = mount.get("shell") as Node
	var bridge: RefCounted = mount.get("bridge") as RefCounted
	var mgr: RefCounted = shell.get("unit_manager") as RefCounted
	var t0 := int(mgr.get_current_turn())
	var cav0: Dictionary = mgr.get_unit_by_id("R_CAV_1")
	ev["turn_before"] = t0
	_sig_phase = {}
	controller.connect("phase_finished", _on_test_phase)
	shell.call("end_player_phase")
	var done := await _wait_turn(shell, t0 + 1, 20000)
	ev["turn_done"] = done
	ev["turn_after"] = int(mgr.get_current_turn())
	ev["phase_back_to_player"] = int(shell.get("_turn_phase")) == 0
	ev["enemy_routine_runs"] = int(shell.call("enemy_routine_runs"))
	ev["controller_result"] = _sig_phase
	var cav1: Dictionary = mgr.get_unit_by_id("R_CAV_1")
	ev["cav_moved"] = [int(cav0.get("q", 0)), int(cav0.get("r", 0)), int(cav1.get("q", 0)), int(cav1.get("r", 0))]
	var view: Dictionary = controller.call("get_last_view")
	ev["view_keys"] = view.keys()
	ev["view_status"] = str(view.get("status", ""))
	ev["view_executed"] = int(view.get("executed_count", -1))
	ev["view_orders"] = int(view.get("order_count", -1))
	var log_path := str(_sig_phase.get("log_path", ""))
	ev["log_path"] = log_path
	var log_ok := false
	var log_leak := true
	var log_keys: Array = []
	if not log_path.is_empty() and FileAccess.file_exists(log_path):
		var lt := _read_text(log_path)
		log_leak = lt.find(CANARY) != -1
		var parsed: Variant = JSON.parse_string(lt)
		if parsed is Dictionary:
			log_keys = (parsed as Dictionary).keys()
			log_ok = true
			for k in LoggerCls.required_keys():
				if not (parsed as Dictionary).has(k):
					log_ok = false
	ev["log_ok"] = log_ok
	ev["log_keys"] = log_keys
	ev["log_leaks_canary"] = log_leak
	# Inspector pipeline completeness (Phase O surface).
	var need := ["model", "turn", "latency_ms", "snapshot_id", "plan", "orders", "pre_fingerprint", "post_fingerprint", "status", "summary"]
	var view_ok := true
	for k in need:
		if not view.has(k):
			view_ok = false
	ev["view_pipeline_ok"] = view_ok
	# BLUE authority intact after the Cloud turn (ownership returned).
	var bplan: Dictionary = CompilerCls.plan(bridge, TableCls.make_command("HOLD", TableCls.scope_all_friendly()), "", "blue")
	ev["blue_plan_ok"] = bool(bplan.get("ok", false))
	var ex: Node = mount.get("executor") as Node
	ev["executor_free"] = not bool(ex.call("is_busy")) and not bool(ex.call("is_external_busy"))
	controller.disconnect("phase_finished", _on_test_phase)
	var cav_moved: bool = int(cav0.get("q", 0)) != int(cav1.get("q", 0)) or int(cav0.get("r", 0)) != int(cav1.get("r", 0))
	var ok := done and int(mgr.get_current_turn()) == t0 + 1 and int(shell.get("_turn_phase")) == 0 \
		and int(shell.call("enemy_routine_runs")) == 0 \
		and str(_sig_phase.get("status", "")) in ["EXECUTED", "PARTIAL"] \
		and int(view.get("executed_count", 0)) > 0 and int(view.get("order_count", 0)) == 3 \
		and log_ok and not log_leak and view_ok and cav_moved \
		and bool(bplan.get("ok", false)) and not bool(ex.call("is_busy")) and not bool(ex.call("is_external_busy"))
	_record("s15_live_cloud_turn", "pass" if ok else "fail", ev)


func _live_s16(mount: Node) -> void:
	var ev := {}
	var controller: Node = mount.get("cloud_controller") as Node
	var ad: Node = mount.get("cloud_adapter") as Node
	var mgr16: RefCounted = (mount.get("shell") as Node).get("unit_manager") as RefCounted
	# STEP mechanics.
	controller.call("set_mode", "STEP")
	controller.call("set_control_mode", "LEGACY_DIRECT") # benchmark path under test here
	(ad.get("mock_queue") as Array).append(_mock_fixture_turn())
	_sig_phase = {}
	controller.connect("phase_finished", _on_test_phase)
	controller.call("run_red_phase")
	var st := await _wait_state(controller, ["WAITING_STEP"], 3000)
	ev["step_waited"] = not st.is_empty()
	ev["step_phase_active"] = bool(controller.call("is_phase_active"))
	controller.call("request_step")
	var frames := 0
	while _sig_phase.is_empty() and frames < 20000:
		await process_frame
		frames += 1
	ev["step_result"] = str(_sig_phase.get("status", "TIMEOUT"))
	# Fresh action budget for the second mechanics probe: STEP and PAUSE each
	# run a full turn's worth of orders, and these direct phase calls do not
	# advance the game turn themselves.
	mgr16.end_turn()
	ev["budget_refreshed_turn"] = int(mgr16.get_current_turn())
	# PAUSE mechanics.
	controller.call("set_mode", "AUTO")
	controller.call("set_paused", true)
	(ad.get("mock_queue") as Array).append(_mock_fixture_turn())
	_sig_phase = {}
	controller.call("run_red_phase")
	var pst := await _wait_state(controller, ["PAUSED"], 3000)
	ev["pause_reached"] = not pst.is_empty()
	ev["pause_note"] = str(pst.get("note", ""))
	var qsize: int = (ad.get("mock_queue") as Array).size()
	ev["model_not_called_while_paused"] = qsize == 1
	controller.call("set_paused", false)
	frames = 0
	while _sig_phase.is_empty() and frames < 20000:
		await process_frame
		frames += 1
	ev["resume_result"] = str(_sig_phase.get("status", "TIMEOUT"))
	controller.disconnect("phase_finished", _on_test_phase)
	var ok := not st.is_empty() and bool(controller.call("is_phase_active")) == false \
		and str(ev["step_result"]) in ["EXECUTED", "PARTIAL"] \
		and not pst.is_empty() and qsize == 1 \
		and str(ev["resume_result"]) in ["EXECUTED", "PARTIAL"]
	_record("s16_live_step_pause", "pass" if ok else "fail", ev)


func _live_s17(mount: Node) -> void:
	var ev := {}
	var controller: Node = mount.get("cloud_controller") as Node
	var ad: Node = mount.get("cloud_adapter") as Node
	var bridge: RefCounted = mount.get("bridge") as RefCounted
	var shell: Node = mount.get("shell") as Node
	var mgr: RefCounted = shell.get("unit_manager") as RefCounted
	controller.call("set_mode", "AUTO")
	controller.call("set_control_mode", "LEGACY_DIRECT") # benchmark path under test here
	controller.call("set_paused", false)
	(ad.get("mock_queue") as Array).append({"ok": false, "code": "TIMEOUT", "detail": "Mock timeout.", "http_status": 0, "latency_ms": 61})
	var pre_fp := str(bridge.fingerprint())
	var t0 := int(mgr.get_current_turn())
	_sig_phase = {}
	controller.connect("phase_finished", _on_test_phase)
	controller.call("run_red_phase")
	var frames := 0
	var failed := false
	while frames < 10000:
		await process_frame
		frames += 1
		var st: Dictionary = controller.call("get_state")
		if str(st.get("phase", "")).begins_with("FAILED"):
			failed = true
			ev["failed_phase"] = str(st.get("phase", ""))
			break
	ev["failed_reached"] = failed
	var mid_fp := str(bridge.fingerprint())
	ev["state_safe_at_failure"] = mid_fp == pre_fp
	controller.call("decide_skip")
	frames = 0
	while _sig_phase.is_empty() and frames < 10000:
		await process_frame
		frames += 1
	ev["skip_result"] = str(_sig_phase.get("status", "TIMEOUT"))
	ev["turn_unchanged"] = int(mgr.get_current_turn()) == t0
	ev["fingerprint_still_safe"] = str(bridge.fingerprint()) == pre_fp
	controller.disconnect("phase_finished", _on_test_phase)
	var ok := failed and mid_fp == pre_fp and str(_sig_phase.get("status", "")) == "SKIPPED" \
		and int(mgr.get_current_turn()) == t0 and str(bridge.fingerprint()) == pre_fp
	_record("s17_live_failure_safety", "pass" if ok else "fail", ev)


func _live_s18() -> void:
	var ev := {}
	var packed: PackedScene = load(CLOUD1_SCENE)
	if packed == null:
		_record("s18_live_step1_intact", "fail", {"error": "cloud1 scene failed to load"})
		return
	_live1 = packed.instantiate()
	root.add_child(_live1)
	var mount: Node = _live1.get_node_or_null("Cloud1LiveMount")
	var booted := await _wait_mount(mount, 3600)
	if not booted or mount == null:
		_record("s18_live_step1_intact", "fail", {"error": "mount timeout"})
		return
	var shell: Node = mount.get("shell") as Node
	var dock: Node = mount.get("dock") as Node
	var bridge: RefCounted = mount.get("bridge") as RefCounted
	ev["red_mode"] = str(shell.call("red_controller_mode"))
	ev["controller_null"] = shell.get("cloud_red_controller") == null
	ev["cloud_tab_absent"] = dock.call("get_cloud_panel") == null
	ev["tab"] = str(dock.call("get_tab"))
	var obs: Dictionary = ObsCls.build(bridge, "blue")
	ev["blue_snapshot"] = str(obs.get("snapshot_id", ""))
	var mgr: RefCounted = shell.get("unit_manager") as RefCounted
	var t0 := int(mgr.get_current_turn())
	shell.call("end_player_phase")
	var done := await _wait_turn(shell, t0 + 1, 20000)
	ev["turn_done"] = done
	ev["enemy_routine_runs"] = int(shell.call("enemy_routine_runs"))
	_live1.queue_free()
	var ok := str(shell.call("red_controller_mode")) == "DETERMINISTIC" \
		and shell.get("cloud_red_controller") == null \
		and dock.call("get_cloud_panel") == null \
		and str(obs.get("snapshot_id", "")).contains("_BLUE_") \
		and done and int(shell.call("enemy_routine_runs")) == 1
	_record("s18_live_step1_intact", "pass" if ok else "fail", ev)


# --- S19: Step-1 rollup -------------------------------------------------------------------------------

func _s19_rollup() -> void:
	var ev := {}
	if not FileAccess.file_exists(STEP1_VERIFY):
		_record("s19_step1_rollup", "fail", {"error": "STEP-01 verification.json missing"})
		return
	var f := FileAccess.open(STEP1_VERIFY, FileAccess.READ)
	var doc: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	var ok := doc is Dictionary
	ev["mtime"] = int(FileAccess.get_modified_time(STEP1_VERIFY))
	if not ok:
		_record("s19_step1_rollup", "fail", ev)
		return
	var d: Dictionary = doc
	var gates: Dictionary = d.get("gates", {})
	var g_all := true
	var g_names: Array = []
	for k in gates.keys():
		g_names.append(k)
		if str((gates[k] as Dictionary).get("status", "")) != "pass":
			g_all = false
	g_names.sort()
	ev["backend_gates"] = {"count": g_names.size(), "all_pass": g_all, "overall": str(d.get("overall", ""))}
	var ca: Dictionary = d.get("contract_audit", {})
	ev["contract_audit"] = {"overall": str(ca.get("overall", "")), "passed": int(ca.get("passed_count", -1)), "failed": int(ca.get("failed_count", -1))}
	var hg: Dictionary = d.get("human_gate", {})
	var h_all := _sub_all_pass(hg)
	ev["human_gate"] = {"overall": str(hg.get("overall", "")), "all_pass": h_all}
	var tg: Dictionary = d.get("title_gate", {})
	var t_all := _sub_all_pass(tg)
	ev["title_gate"] = {"overall": str(tg.get("overall", "")), "all_pass": t_all}
	var ug: Dictionary = d.get("ux_gate", {})
	var u_all := _sub_all_pass(ug)
	ev["ux_gate"] = {"overall": str(ug.get("overall", "")), "all_pass": u_all}
	var da: Dictionary = d.get("dev_contract_audit", {})
	ev["dev_contract_audit"] = {"overall": str(da.get("overall", "")), "passed": int(da.get("passed", -1)), "failed": int(da.get("failed", -1))}
	ok = g_all and str(d.get("overall", "")) == "pass" and g_names.size() == 9 \
		and str(ca.get("overall", "")) == "pass" and int(ca.get("failed_count", -1)) == 0 \
		and str(hg.get("overall", "")) == "pass" and h_all \
		and str(tg.get("overall", "")) == "pass" and t_all \
		and str(ug.get("overall", "")) == "pass" and u_all \
		and str(da.get("overall", "")) == "pass" and int(da.get("passed", -1)) == 70 and int(da.get("failed", -1)) == 0
	_record("s19_step1_rollup", "pass" if ok else "fail", ev)


func _sub_all_pass(section: Dictionary) -> bool:
	var sub: Dictionary = section.get("gates", {})
	if sub.is_empty():
		return false
	for k in sub.keys():
		if str((sub[k] as Dictionary).get("status", "")) != "pass":
			return false
	return true


# --- artifacts -------------------------------------------------------------------------------

func _s2_matrix() -> Dictionary:
	var g := func(id: String) -> String: return str((_gates.get(id, {}) as Dictionary).get("status", "missing"))
	return {
		"S2-01": {"verdict": g.call("s14_live_red_full_info"), "via": "s14 separate CLOUD2 scene mounts with CLOUD tab"},
		"S2-02": {"verdict": g.call("s18_live_step1_intact"), "via": "s18 Step-1 scene intact"},
		"S2-03": {"verdict": g.call("s15_live_cloud_turn"), "via": "s15 routine counter 0 in CLOUD (+s18 counter 1 in Step-1)"},
		"S2-04": {"verdict": g.call("s14_live_red_full_info"), "via": "s1+s14 RED canonical observation"},
		"S2-05": {"verdict": g.call("s10_packet_shape"), "via": "s1+s10+s13 no WorldTruth leakage"},
		"S2-06": {"verdict": g.call("s7_adapter_serialization"), "via": "s7 single HTTP owner: adapter"},
		"S2-07": {"verdict": g.call("s13_secret_hygiene"), "via": "s7+s13+s15 canary absent everywhere"},
		"S2-08": {"verdict": g.call("s6_semantic_gate"), "via": "s6+s8 structured validation"},
		"S2-09": {"verdict": g.call("s3_human_cloud_parity"), "via": "s3 scope algebra reused (same ids)"},
		"S2-10": {"verdict": g.call("s3_human_cloud_parity"), "via": "s3 same OperationalCommand contract"},
		"S2-11": {"verdict": g.call("s3_human_cloud_parity"), "via": "s3 parity"},
		"S2-12": {"verdict": g.call("s2_side_relative_semantics"), "via": "s2 relative frame"},
		"S2-13": {"verdict": g.call("s15_live_cloud_turn"), "via": "s4+s15 ordered multi-order"},
		"S2-14": {"verdict": g.call("s4_sequential_multi_order"), "via": "s4 revalidation contrast"},
		"S2-15": {"verdict": g.call("s5_partial_failure"), "via": "s5+s6 reject-and-continue"},
		"S2-16": {"verdict": g.call("s17_live_failure_safety"), "via": "s17 timeout safety"},
		"S2-17": {"verdict": g.call("s11_no_direct_mutation"), "via": "s11+s17 no direct mutation"},
		"S2-18": {"verdict": g.call("s12_no_rl_code"), "via": "s12 engine-token scan + s4/s15 service execution"},
		"S2-19": {"verdict": g.call("s12_no_rl_code"), "via": "s12 engine-token scan + s4 live damage"},
		"S2-20": {"verdict": g.call("s9_plan_memory_compact"), "via": "s9 compact/advisory"},
		"S2-21": {"verdict": g.call("s15_live_cloud_turn"), "via": "s15 inspector pipeline keys"},
		"S2-22": {"verdict": g.call("s16_live_step_pause"), "via": "s15 AUTO + s16 STEP/PAUSE"},
		"S2-23": {"verdict": g.call("s15_live_cloud_turn"), "via": "s15 turn advanced, ownership returned"},
		"S2-24": {"verdict": g.call("s15_live_cloud_turn"), "via": "s15 structured log keys"},
		"S2-25": {"verdict": g.call("s19_step1_rollup"), "via": "s19 Step-0 contract green"},
		"S2-26": {"verdict": g.call("s19_step1_rollup"), "via": "s19 Step-1 suites green"},
		"S2-27": {"verdict": g.call("s19_step1_rollup"), "via": "s19 production isolation green"},
		"S2-28": {"verdict": g.call("s12_no_rl_code"), "via": "s12 no RL/SFT/Qwen"},
		"S2-29": {"verdict": "blocked", "via": "no live network attempted; mock fixtures only (USER API KEY REQUIRED)"},
		"S2-30": {"verdict": g.call("s14_live_red_full_info"), "via": "s14+s15 launchable for user evaluation"},
	}


func _write_and_quit(code: int) -> void:
	DirAccess.make_dir_recursive_absolute(DELIVER_DIR)
	var matrix := _s2_matrix()
	var fails: Array = []
	for k in matrix.keys():
		if str((matrix[k] as Dictionary).get("verdict", "")) == "fail":
			fails.append(k)
	var doc := {
		"contract": "CLOUD-GENERAL-STEP-02",
		"schema_version": ObsCls.SCHEMA_VERSION,
		"packet_version": PacketCls.PACKET_VERSION,
		"godot_version": Engine.get_version_info(),
		"gates": _gates,
		"s2_matrix": matrix,
		"s2_failed": fails,
		"harness": "pass" if code == 0 else "fail",
		"live_cloud": "BLOCKED — USER API KEY REQUIRED (mock fixtures only; no live network attempted)",
		"human_tactical_acceptance": "PENDING",
	}
	var f := FileAccess.open(VERIFY_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(doc, "  "))
		print("[CLOUD2] verification.json written to %s" % VERIFY_PATH)
	else:
		print("[CLOUD2] ERROR: could not write %s" % VERIFY_PATH)
	print("[CLOUD2] gates complete --exit %d" % code)
	quit(code)
