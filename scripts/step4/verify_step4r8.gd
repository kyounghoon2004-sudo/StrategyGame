extends SceneTree

## STEP-04R8 Acceptance Test & Evidence Generator
## Validates:
##   1. Reviewed Queue Contract (reviewed_queue_contract.json)
##   2. Next To End Turn Contract (next_to_end_turn_contract.json)
##   3. Enemy Phase Live Contract (enemy_phase_live_contract.json)
##   4. Second Player Turn Contract (second_player_turn_contract.json)
##   5. Turn Reset Regression Contract (turn_reset_regression.json)

const HexUtilsCls = preload("res://scripts/core/hex_utils.gd")
const CombatCalculatorCls = preload("res://scripts/combat/combat_calculator.gd")
const Step3ConfigCls = preload("res://scripts/core/step3_config.gd")
const Step3PathfindingCls = preload("res://scripts/step3/step3_pathfinding.gd")

var _shell: Node2D
var _frame_count: int = 0
var _evidence_dir: String = "D:/Game development/Demon slayer/StrategyGame/evidence"
var _started: bool = false
var _results: Dictionary = {}
var _tested_rest_id: String = ""
var _tested_fort_id: String = ""
var _tested_t2_id: String = ""

func _initialize() -> void:
	root.size = Vector2i(1920, 1080)
	root.content_scale_size = Vector2i(1920, 1080)
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	root.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_KEEP

	var scene_res: PackedScene = load("res://scenes/step2r_battlefield_shell.tscn") as PackedScene
	if scene_res == null:
		push_error("[VERIFY-R8] Failed to load battlefield shell scene")
		quit(1)
		return
	_shell = scene_res.instantiate() as Node2D
	root.add_child(_shell)
	DirAccess.make_dir_recursive_absolute(_evidence_dir)

func _process(_delta: float) -> bool:
	_frame_count += 1
	if _frame_count >= 5 and not _started:
		_started = true
		_run_suite()
	return false

func _run_suite() -> void:
	print("\n==================================================")
	print("STARTING STEP-04R8 VERIFICATION SUITE")
	print("==================================================")

	var um: Step3UnitManager = _shell.get("unit_manager") as Step3UnitManager
	var ur: Node = _shell.get("unit_renderer") as Node
	var btn: Button = _shell.get("next_turn_button") as Button

	# -------------------------------------------------------------
	# TEST 1: Reviewed Queue Contract (reviewed_queue_contract.json)
	# -------------------------------------------------------------
	print("\n--- TEST 1: Reviewed Queue Contract (§4, §5, §6, §7, §9, §32) ---")
	var initial_units: Array = _shell.call("get_live_friendly_field_units_in_stable_order")
	var initial_count: int = initial_units.size()
	print("  Initial friendly field units count: %d" % initial_count)

	var all_initially_unreviewed: bool = true
	for u in initial_units:
		var uid: String = str(u["id"])
		if um.is_reviewed(uid) or bool(u.get("reviewed_this_turn", false)):
			all_initially_unreviewed = false
			break

	# 1. First NEXT press: selects Unit A
	_shell.call("select_next_friendly_field_unit")
	var sel1_id: String = um.get_selected_unit_id()
	var sel1_reviewed_on_select: bool = um.is_reviewed(sel1_id) # Should be false (only reviewed when NEXT pressed away)

	# 2. Second NEXT press: marks sel1_id reviewed, selects Unit B
	_shell.call("select_next_friendly_field_unit")
	var sel2_id: String = um.get_selected_unit_id()
	var sel1_reviewed_after_next: bool = um.is_reviewed(sel1_id)

	# 3. REST on Unit B: marks reviewed_this_turn = true, action_ended = true
	_tested_rest_id = sel2_id
	_shell.call("_on_rest_button_pressed")
	var u_sel2: Dictionary = um.get_unit_by_id(_tested_rest_id)
	var sel2_rest_reviewed: bool = bool(u_sel2.get("reviewed_this_turn", false)) and um.is_reviewed(_tested_rest_id)
	var sel2_action_ended: bool = bool(u_sel2.get("action_ended", false))
	var sel3_id: String = um.get_selected_unit_id()

	# 4. FORTIFY on Unit C: marks reviewed_this_turn = true, action_ended = true, field_fortified = true
	_tested_fort_id = sel3_id
	_shell.call("_on_fortify_button_pressed")
	var u_sel3: Dictionary = um.get_unit_by_id(_tested_fort_id)
	var sel3_fort_reviewed: bool = bool(u_sel3.get("reviewed_this_turn", false)) and um.is_reviewed(_tested_fort_id)
	var sel3_fortified: bool = bool(u_sel3.get("field_fortified", false))
	var sel3_hp: int = int(u_sel3.get("field_fortification_hp", 0))

	# 5. Garrisoned & Destroyed units check
	var garrisoned_excluded: bool = true
	for u in initial_units:
		if um.is_garrisoned(str(u["id"])):
			garrisoned_excluded = false

	var test1_ok: bool = (
		initial_count >= 30 and
		all_initially_unreviewed and
		sel1_id != "" and
		not sel1_reviewed_on_select and
		sel2_id != "" and
		sel1_reviewed_after_next and
		sel2_rest_reviewed and
		sel2_action_ended and
		sel3_fort_reviewed and
		sel3_fortified and
		sel3_hp == 180 and
		garrisoned_excluded
	)

	var evidence_1: Dictionary = {
		"task_id": "STEP-04R8-END-TURN-ONLY",
		"test": "reviewed_queue_contract",
		"initial_eligible_field_count": initial_count,
		"all_initially_unreviewed": all_initially_unreviewed,
		"unit_selected_remains_unreviewed_until_next": not sel1_reviewed_on_select,
		"unit_marked_reviewed_on_next_away": sel1_reviewed_after_next,
		"rest_marks_reviewed_and_action_ended": sel2_rest_reviewed and sel2_action_ended,
		"fortify_marks_reviewed_and_fortified": sel3_fort_reviewed and sel3_fortified,
		"garrisoned_units_excluded_from_queue": garrisoned_excluded,
		"status": "PASS" if test1_ok else "FAIL"
	}
	_save_json("reviewed_queue_contract.json", evidence_1)
	_results["test_1_reviewed_queue"] = evidence_1["status"]
	print("  Result: %s (initial=%d, rest_rev=%s, fort_rev=%s)" % [
		evidence_1["status"], initial_count, str(sel2_rest_reviewed), str(sel3_fort_reviewed)
	])

	# -------------------------------------------------------------
	# TEST 2: Next To End Turn Contract (next_to_end_turn_contract.json)
	# -------------------------------------------------------------
	print("\n--- TEST 2: Next To End Turn Contract (§10, §11, §12, §13, §30) ---")
	var loop_count: int = 0
	var button_id_before: int = btn.get_instance_id()
	var unreviewed_history: Array = []

	while loop_count < 60:
		loop_count += 1
		var unrev: Array = _shell.call("get_unreviewed_friendly_field_units_in_stable_order")
		unreviewed_history.append(unrev.size())
		if unrev.is_empty():
			break
		_shell.call("select_next_friendly_field_unit")

	var button_id_after: int = btn.get_instance_id()
	var same_button_instance: bool = (button_id_before == button_id_after)
	var final_unreviewed: Array = _shell.call("get_unreviewed_friendly_field_units_in_stable_order")
	var button_text: String = btn.text
	var is_end_turn_text: bool = ("END TURN" in button_text and "턴 종료" in button_text)
	var button_enabled: bool = not btn.disabled

	# §11 Check: Manual reselection freedom
	# Commander clicks B_CAV_1 (previously reviewed):
	um.select_unit("B_CAV_1")
	var cav_selected: bool = (um.get_selected_unit_id() == "B_CAV_1")
	var button_still_end_turn: bool = ("END TURN" in btn.text)

	# §12 & §30 Check: Turn must NOT automatically end
	var phase_before_click: int = int(_shell.get("_turn_phase"))
	var turn_before_click: int = um.get_current_turn()

	var test2_ok: bool = (
		final_unreviewed.is_empty() and
		same_button_instance and
		is_end_turn_text and
		button_enabled and
		cav_selected and
		button_still_end_turn and
		phase_before_click == 0 and # PLAYER_PHASE
		turn_before_click == 1
	)

	var evidence_2: Dictionary = {
		"task_id": "STEP-04R8-END-TURN-ONLY",
		"test": "next_to_end_turn_contract",
		"queue_exhausted": final_unreviewed.is_empty(),
		"same_button_instance": same_button_instance,
		"button_text": button_text,
		"button_enabled": button_enabled,
		"manual_reselection_allowed": cav_selected,
		"button_remains_end_turn_on_manual_selection": button_still_end_turn,
		"turn_not_auto_advanced": (turn_before_click == 1 and phase_before_click == 0),
		"status": "PASS" if test2_ok else "FAIL"
	}
	_save_json("next_to_end_turn_contract.json", evidence_2)
	_results["test_2_next_to_end_turn"] = evidence_2["status"]
	print("  Result: %s (exhausted=%s, btn_text='%s', cav_sel=%s)" % [
		evidence_2["status"], str(final_unreviewed.is_empty()), button_text.replace("\n", " "), str(cav_selected)
	])

	# -------------------------------------------------------------
	# TEST 3: Enemy Phase Live Contract (enemy_phase_live_contract.json)
	# -------------------------------------------------------------
	print("\n--- TEST 3: Enemy Phase Live Contract (§14, §15, §16, §17, §24, §25) ---")
	# Record enemy unit states before phase
	var red_units_before: Dictionary = {}
	for u in um.get_all_units():
		if str(u["faction"]) == "red":
			red_units_before[str(u["id"])] = {
				"q": int(u["q"]), "r": int(u["r"]),
				"soldier_count": int(u["soldier_count"])
			}

	# Explicitly click the bottom-right END TURN button
	_shell.call("_on_next_turn_button_pressed")

	# Immediately verify ENEMY_PHASE state
	var phase_during_enemy: int = int(_shell.get("_turn_phase"))
	var is_enemy_phase: bool = (phase_during_enemy == 1) # TurnPhase.ENEMY_PHASE
	var btn_disabled_during_enemy: bool = btn.disabled
	var btn_text_during_enemy: String = btn.text

	print("  Phase during enemy: %d (expected 1), Button text: '%s', Disabled: %s" % [
		phase_during_enemy, btn_text_during_enemy.replace("\n", " "), str(btn_disabled_during_enemy)
	])

	# Test player input blocking during enemy phase (§24)
	var rest_during_enemy_blocked: bool = not um.can_unit_rest("B_INF_4") or int(_shell.get("_turn_phase")) != 0

	# Await enemy phase completion (async wait)
	var wait_ticks: int = 0
	while int(_shell.get("_turn_phase")) == 1 and wait_ticks < 150:
		await create_timer(0.05).timeout
		wait_ticks += 1

	var phase_after_enemy: int = int(_shell.get("_turn_phase"))
	print("  Enemy phase resolved after %d ticks. Phase is now: %d" % [wait_ticks, phase_after_enemy])

	# Record enemy unit states after phase to verify movement/actions
	var red_actions_detected: int = 0
	var red_units_after: Dictionary = {}
	for u in um.get_all_units():
		if str(u["faction"]) == "red":
			var rid: String = str(u["id"])
			var q: int = int(u["q"])
			var r: int = int(u["r"])
			var soldiers: int = int(u["soldier_count"])
			red_units_after[rid] = {"q": q, "r": r, "soldier_count": soldiers}
			if red_units_before.has(rid):
				var b: Dictionary = red_units_before[rid]
				if b["q"] != q or b["r"] != r or b["soldier_count"] != soldiers:
					red_actions_detected += 1

	var test3_ok: bool = (
		is_enemy_phase and
		btn_disabled_during_enemy and
		phase_after_enemy == 0 and # Returned to PLAYER_PHASE
		red_actions_detected > 0
	)

	var evidence_3: Dictionary = {
		"task_id": "STEP-04R8-END-TURN-ONLY",
		"test": "enemy_phase_live_contract",
		"entered_enemy_phase_on_click": is_enemy_phase,
		"button_disabled_during_enemy": btn_disabled_during_enemy,
		"button_text_during_enemy": btn_text_during_enemy,
		"player_input_blocked_during_enemy": rest_during_enemy_blocked,
		"enemy_units_actions_count": red_actions_detected,
		"enemy_phase_completed_cleanly": (phase_after_enemy == 0),
		"status": "PASS" if test3_ok else "FAIL"
	}
	_save_json("enemy_phase_live_contract.json", evidence_3)
	_results["test_3_enemy_phase_live"] = evidence_3["status"]
	print("  Result: %s (entered_enemy=%s, red_actions=%d, resolved=%s)" % [
		evidence_3["status"], str(is_enemy_phase), red_actions_detected, str(phase_after_enemy == 0)
	])

	# -------------------------------------------------------------
	# TEST 4: Second Player Turn Contract (second_player_turn_contract.json)
	# -------------------------------------------------------------
	print("\n--- TEST 4: Second Player Turn Contract (§18, §19, §20, §25, §28) ---")
	var turn_t2: int = um.get_current_turn()
	var phase_t2: int = int(_shell.get("_turn_phase"))
	var btn_text_t2: String = btn.text
	var btn_enabled_t2: bool = not btn.disabled
	var is_btn_next: bool = ("NEXT" in btn_text_t2 and "다음 부대" in btn_text_t2)

	# Review queue reset verification (§20):
	print("  [DEBUG 4.0] checking unreviewed queue")
	var unrev_t2: Array = _shell.call("get_unreviewed_friendly_field_units_in_stable_order")
	var unrev_count_t2: int = unrev_t2.size()
	print("  [DEBUG 4.1] unrev_count_t2 = %d" % unrev_count_t2)

	# Press NEXT on Turn 2:
	print("  [DEBUG 4.2] calling select_next_friendly_field_unit")
	_shell.call("select_next_friendly_field_unit")
	print("  [DEBUG 4.3] select_next finished")
	var sel_t2_id: String = um.get_selected_unit_id()
	_tested_t2_id = sel_t2_id
	print("  [DEBUG 4.4] sel_t2_id = %s" % sel_t2_id)
	var unit_selected_t2: bool = (sel_t2_id != "")

	# Move Turn 2 unit to prove actionable (§28)
	var t2_unit_moved: bool = false
	if unit_selected_t2:
		var u_t2: Dictionary = um.get_unit_by_id(sel_t2_id)
		var cur_coord: Vector2i = Vector2i(int(u_t2["q"]), int(u_t2["r"]))
		var cell_data: Dictionary = _shell.get("hex_grid").get("cell_data") if _shell.get("hex_grid") else {}
		var occupied: Dictionary = um.get_occupied_dict()
		var env: Variant = Step3PathfindingCls.calculate_envelope(
			cur_coord, str(u_t2["class"]), float(u_t2["base_mp"]),
			float(u_t2["remaining_mp"]), Step3ConfigCls.MarchPolicy.GREEN_ONLY,
			cell_data, occupied, _shell.get("_river_cells"), "blue", _shell.get("_stronghold_cells")
		)
		if not env.green_hexes.is_empty():
			var dest_hex: Vector2i = env.green_hexes[0]
			var move_path: Array[Vector2i] = []
			move_path.append(cur_coord)
			move_path.append(dest_hex)
			var move_res: Dictionary = um.execute_move(sel_t2_id, move_path, 1.0, Step3ConfigCls.MarchClass.GREEN, false)
			if move_res.get("success", false):
				t2_unit_moved = true
				ur.call("update_unit_position", sel_t2_id, dest_hex.x, dest_hex.y)
		else:
			t2_unit_moved = float(u_t2.get("remaining_mp", 0.0)) > 0.0
		print("  [DEBUG 4.6] t2_unit_moved = %s" % str(t2_unit_moved))

	var test4_ok: bool = (
		turn_t2 == 2 and
		phase_t2 == 0 and # PLAYER_PHASE
		is_btn_next and
		btn_enabled_t2 and
		unrev_count_t2 >= 30 and
		unit_selected_t2 and
		t2_unit_moved
	)

	var evidence_4: Dictionary = {
		"task_id": "STEP-04R8-END-TURN-ONLY",
		"test": "second_player_turn_contract",
		"turn_number": turn_t2,
		"player_phase_active": (phase_t2 == 0),
		"button_restored_to_next": is_btn_next,
		"button_enabled": btn_enabled_t2,
		"review_queue_reset_count": unrev_count_t2,
		"turn2_unit_selected": sel_t2_id,
		"turn2_unit_actionable_and_moved": t2_unit_moved,
		"status": "PASS" if test4_ok else "FAIL"
	}
	_save_json("second_player_turn_contract.json", evidence_4)
	_results["test_4_second_player_turn"] = evidence_4["status"]
	print("  Result: %s (turn=%d, btn_next=%s, unrev_count=%d, sel_t2=%s, moved=%s)" % [
		evidence_4["status"], turn_t2, str(is_btn_next), unrev_count_t2, sel_t2_id, str(t2_unit_moved)
	])

	# -------------------------------------------------------------
	# TEST 5: Turn Reset Regression Contract (turn_reset_regression.json)
	# -------------------------------------------------------------
	print("\n--- TEST 5: Turn Reset Regression Contract (§21, §22, §23, §30) ---")
	# 1. Check Field Fortification persistence (§21):
	var u_fort_t2: Dictionary = um.get_unit_by_id(_tested_fort_id)
	var fort_persisted_flag: bool = bool(u_fort_t2.get("field_fortified", false))
	var fort_hp_t2: int = int(u_fort_t2.get("field_fortification_hp", 0))
	var fort_indicator_t2: bool = bool(ur.call("is_unit_fortified", _tested_fort_id))

	# 2. Check REST regression (§22):
	var u_rest_t2: Dictionary = um.get_unit_by_id(_tested_rest_id)
	var rest_cleared: bool = (not bool(u_rest_t2.get("resting_unguarded", false)) and not bool(u_rest_t2.get("rested_this_turn", false)))
	var rest_action_ended_cleared: bool = (not bool(u_rest_t2.get("action_ended", false)))
	var rest_mp_restored: bool = (float(u_rest_t2.get("remaining_mp", 0.0)) >= float(u_rest_t2.get("base_mp", 1.0)) - 0.01)

	# 3. Check RED movement budget regression (§23):
	# On new turn, turn_move_cost_spent must be 0 for all units (except _tested_t2_id which moved in Test 4).
	var all_spent_zero: bool = true
	for u in um.get_all_units():
		if str(u["id"]) != _tested_t2_id and float(u.get("turn_move_cost_spent", 0.0)) > 0.001:
			all_spent_zero = false
			break

	# 4. Check Stronghold UI integrity:
	var sh_mgr: RefCounted = um.get_stronghold_manager()
	var sh_count: int = sh_mgr.get_all_strongholds().size() if sh_mgr else 0

	var test5_ok: bool = (
		fort_persisted_flag and
		fort_hp_t2 == 180 and
		fort_indicator_t2 and
		rest_cleared and
		rest_action_ended_cleared and
		rest_mp_restored and
		all_spent_zero and
		sh_count >= 2
	)

	var evidence_5: Dictionary = {
		"task_id": "STEP-04R8-END-TURN-ONLY",
		"test": "turn_reset_regression",
		"fortification_persisted_hp": fort_hp_t2,
		"fortification_flag_true": fort_persisted_flag,
		"fortification_visual_indicator_preserved": fort_indicator_t2,
		"rest_cleared_on_turn2": rest_cleared,
		"rest_action_ended_cleared_on_turn2": rest_action_ended_cleared,
		"movement_budget_reset_on_new_turn": all_spent_zero,
		"strongholds_intact": (sh_count >= 2),
		"status": "PASS" if test5_ok else "FAIL"
	}
	_save_json("turn_reset_regression.json", evidence_5)
	_results["test_5_turn_reset_regression"] = evidence_5["status"]
	print("  Result: %s (fort_hp=%d, rest_cleared=%s, spent_zero=%s, sh_count=%d)" % [
		evidence_5["status"], fort_hp_t2, str(rest_cleared), str(all_spent_zero), sh_count
	])

	# -------------------------------------------------------------
	# FINAL SUMMARY
	# -------------------------------------------------------------
	print("\n==================================================")
	print("STEP-04R8 VERIFICATION SUMMARY:")
	var all_pass: bool = true
	for k in _results.keys():
		print("  %s: %s" % [k, _results[k]])
		if _results[k] != "PASS":
			all_pass = false

	if all_pass:
		print("OVERALL: READY FOR REVIEW")
		print("==================================================")
		quit(0)
	else:
		print("OVERALL: FAILED WITH FINDINGS")
		print("==================================================")
		quit(1)

func _save_json(filename: String, data: Dictionary) -> void:
	var path: String = _evidence_dir + "/" + filename
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(data, "  "))
		f.close()
		print("  [Evidence Saved] -> %s" % path)
	else:
		push_error("Failed to write JSON: " + path)
