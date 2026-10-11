extends SceneTree
# STEP-04R11 Verification Suite
# Tests Blue MP cycling, Forced March skipping, Fortify Turn 1 & Turn 2 skip/dismantle, and Wait action.

const Step3UnitManagerCls = preload("res://scripts/step3/step3_unit_manager.gd")
const Step3ConfigCls = preload("res://scripts/core/step3_config.gd")

var _frame: int = 0
var _started: bool = false

func _initialize() -> void:
	root.size = Vector2i(1920, 1080)
	root.content_scale_size = Vector2i(1920, 1080)

func _process(_delta: float) -> bool:
	_frame += 1
	if _frame >= 2 and not _started:
		_started = true
		_run_tests()
	return false

func _run_tests() -> void:
	print("\n==================================================")
	print("STEP-04R11 VERIFICATION SUITE START")
	print("==================================================")
	var all_pass: bool = true

	var manager = Step3UnitManagerCls.new()
	var test_units: Array = [
		{"id": "B_INF_1", "class": "infantry", "faction": "blue", "q": 0, "r": 0, "soldier_count": 100, "max_count": 100, "base_mp": 2.0},
		{"id": "B_SPE_1", "class": "spear", "faction": "blue", "q": 2, "r": 0, "soldier_count": 100, "max_count": 100, "base_mp": 2.0},
		{"id": "B_CAV_1", "class": "cavalry", "faction": "blue", "q": -2, "r": 0, "soldier_count": 100, "max_count": 100, "base_mp": 3.0},
		{"id": "R_INF_1", "class": "infantry", "faction": "red", "q": 10, "r": 10, "soldier_count": 100, "max_count": 100, "base_mp": 2.0},
	]
	manager.initialize_from_renderer_units(test_units)

	# ----------------------------------------------------
	# TEST 1: Blue MP Cycling ("MP가 남아있으면 그 턴 스킵이 아니라 다시 돌아와야해")
	# ----------------------------------------------------
	print("\n--- TEST 1: Blue MP Cycling ---")
	var t1_pass: bool = true
	var active_units: Array = manager.get_units_able_to_move_in_stable_order()
	if active_units.size() != 3:
		print("FAIL: Expected 3 active blue units, got %d" % active_units.size())
		t1_pass = false
	
	# Select B_INF_1 and test resolve_unit_via_next
	var res_inf1: Dictionary = manager.resolve_unit_via_next("B_INF_1")
	# Must NOT be resolved because it still has full Blue MP!
	if res_inf1.get("resolved", true) != false:
		print("FAIL: B_INF_1 with full MP was incorrectly resolved!")
		t1_pass = false
	var inf1_data: Dictionary = manager.get_unit_by_id("B_INF_1")
	if bool(inf1_data.get("action_ended", false)):
		print("FAIL: B_INF_1 was marked action_ended on NEXT!")
		t1_pass = false
	
	# Verify B_INF_1 is still in active move units queue
	var active_after: Array = manager.get_units_able_to_move_in_stable_order()
	var ids_after: Array = active_after.map(func(u): return u["id"])
	if not ids_after.has("B_INF_1"):
		print("FAIL: B_INF_1 dropped out of active units queue! %s" % str(ids_after))
		t1_pass = false
	else:
		print("PASS: B_INF_1 with Blue MP remaining cycles back in queue")
	
	if not t1_pass: all_pass = false

	# ----------------------------------------------------
	# TEST 2: Forced March (Red MP) Skipping ("다시 선택이 불가능한건 강행군 만")
	# ----------------------------------------------------
	print("\n--- TEST 2: Forced March (Red MP) Skipping ---")
	var t2_pass: bool = true
	# Spend full 2.0 Blue MP on B_INF_1
	var u_inf: Dictionary = manager._units["B_INF_1"]
	u_inf["turn_move_cost_spent"] = 2.0
	u_inf["has_moved"] = true
	# Now only Red MP remains
	var can_blue: bool = manager.can_unit_move_blue("B_INF_1")
	if can_blue:
		print("FAIL: B_INF_1 can_unit_move_blue returned true after spending full blue limit!")
		t2_pass = false
	
	# Resolve via NEXT should now mark GUARD / resolved
	var res_inf_done: Dictionary = manager.resolve_unit_via_next("B_INF_1")
	if not res_inf_done.get("resolved", false):
		print("FAIL: B_INF_1 with blue MP exhausted was not resolved!")
		t2_pass = false
	
	var active_after_move: Array = manager.get_units_able_to_move_in_stable_order()
	var ids_after_move: Array = active_after_move.map(func(u): return u["id"])
	if ids_after_move.has("B_INF_1"):
		print("FAIL: B_INF_1 still in active move queue after Blue MP exhausted!")
		t2_pass = false
	else:
		print("PASS: B_INF_1 with Blue MP exhausted is skipped from queue")
	
	if not t2_pass: all_pass = false

	# ----------------------------------------------------
	# TEST 3: Fortify in Turn 1 Ends Turn ("if 요새화 = 1 turn after 요새화, skip turn")
	# ----------------------------------------------------
	print("\n--- TEST 3: Fortify in Turn 1 Ends Turn ---")
	var t3_pass: bool = true
	var fort_res: Dictionary = manager.fortify_unit("B_SPE_1")
	if not fort_res.get("success", false):
		print("FAIL: fortify_unit failed: %s" % str(fort_res))
		t3_pass = false
	var spe_t1: Dictionary = manager.get_unit_by_id("B_SPE_1")
	if not bool(spe_t1.get("field_fortified", false)):
		print("FAIL: B_SPE_1 field_fortified is not true!")
		t3_pass = false
	if not bool(spe_t1.get("action_ended", false)):
		print("FAIL: B_SPE_1 action_ended is not true on fortify turn!")
		t3_pass = false
	
	var active_t1: Array = manager.get_units_able_to_move_in_stable_order()
	var ids_t1: Array = active_t1.map(func(u): return u["id"])
	if ids_t1.has("B_SPE_1"):
		print("FAIL: Fortified unit B_SPE_1 still in active move queue in Turn 1!")
		t3_pass = false
	else:
		print("PASS: Fortified unit B_SPE_1 ends action and is skipped in Turn 1")
	
	if not t3_pass: all_pass = false

	# ----------------------------------------------------
	# TEST 4: Turn 2 Fortified Unit Skips Automatic Action (No Forced Action / Blockage)
	# ----------------------------------------------------
	print("\n--- TEST 4: Turn 2 Fortified Unit Skips Automatic Move ---")
	var t4_pass: bool = true
	manager.end_turn()
	if manager.get_current_turn() != 2:
		print("FAIL: Expected Turn 2, got %d" % manager.get_current_turn())
		t4_pass = false
	
	var spe_t2: Dictionary = manager.get_unit_by_id("B_SPE_1")
	if not bool(spe_t2.get("field_fortified", false)):
		print("FAIL: B_SPE_1 lost field_fortified on turn transition!")
		t4_pass = false
	
	# Fortified unit must NOT be forced to move! It is skipped from active move queue!
	var can_move_fort: bool = manager.can_unit_move_blue("B_SPE_1")
	if can_move_fort:
		print("FAIL: Fortified unit B_SPE_1 reported can_unit_move_blue == true!")
		t4_pass = false
	
	# If we wait/resolve other units, does B_SPE_1 block turn end?
	manager.wait_unit("B_INF_1")
	manager.wait_unit("B_CAV_1")
	var unres_t2: Array = manager.get_unresolved_friendly_field_units_in_stable_order()
	if not unres_t2.is_empty():
		print("FAIL: Fortified unit B_SPE_1 blocked turn end! Unresolved: %s" % str(unres_t2.map(func(u): return u["id"])))
		t4_pass = false
	else:
		print("PASS: Fortified unit B_SPE_1 holds position and does NOT block turn end")
	
	if not t4_pass: all_pass = false

	# ----------------------------------------------------
	# TEST 5: Dismantle Fortification & Move on Same Turn
	# ----------------------------------------------------
	print("\n--- TEST 5: Dismantle Fortification & Move on Same Turn ---")
	var t5_pass: bool = true
	var can_dism: bool = manager.can_dismantle_fortification("B_SPE_1")
	if not can_dism:
		print("FAIL: can_dismantle_fortification returned false for B_SPE_1!")
		t5_pass = false
	
	var dis_res: Dictionary = manager.dismantle_fortification("B_SPE_1")
	if not dis_res.get("success", false):
		print("FAIL: dismantle_fortification failed: %s" % str(dis_res))
		t5_pass = false
	
	var spe_after_dis: Dictionary = manager.get_unit_by_id("B_SPE_1")
	if bool(spe_after_dis.get("field_fortified", false)):
		print("FAIL: B_SPE_1 still fortified after dismantle!")
		t5_pass = false
	if float(dis_res.get("cost", 1.0)) > 0.0:
		print("FAIL: Dismantle cost is not 0.0 MP (got %.1f)!" % float(dis_res.get("cost", 1.0)))
		t5_pass = false
	if float(spe_after_dis.get("remaining_mp", 0.0)) < 2.0:
		print("FAIL: B_SPE_1 remaining_mp is less than 2.0 (got %.1f)!" % float(spe_after_dis.get("remaining_mp", 0.0)))
		t5_pass = false
	
	# Now B_SPE_1 can move in the same turn!
	if not manager.can_unit_move_blue("B_SPE_1"):
		print("FAIL: B_SPE_1 cannot move after dismantling fortification!")
		t5_pass = false
	
	var path: Array[Vector2i] = [Vector2i(2, 0), Vector2i(3, 0)]
	var move_res: Dictionary = manager.execute_move("B_SPE_1", path, 1.0, Step3ConfigCls.MarchClass.GREEN, false)
	if not move_res.get("success", false):
		print("FAIL: execute_move failed for dismantled unit on same turn: %s" % str(move_res))
		t5_pass = false
	else:
		print("PASS: Fortification dismantled and unit moved in the same turn successfully!")
	
	if not t5_pass: all_pass = false

	# ----------------------------------------------------
	# TEST 6: Stand Ground / Wait Action (대기)
	# ----------------------------------------------------
	print("\n--- TEST 6: Stand Ground / Wait (대기) ---")
	var t6_pass: bool = true
	manager.end_turn() # Turn 3
	var cav_t3: Dictionary = manager.get_unit_by_id("B_CAV_1")
	var wait_res: Dictionary = manager.wait_unit("B_CAV_1")
	if not wait_res.get("success", false):
		print("FAIL: wait_unit failed: %s" % str(wait_res))
		t6_pass = false
	var cav_after_wait: Dictionary = manager.get_unit_by_id("B_CAV_1")
	if not bool(cav_after_wait.get("action_ended", false)):
		print("FAIL: B_CAV_1 action_ended is not true after wait!")
		t6_pass = false
	if not bool(cav_after_wait.get("defense_ready", false)):
		print("FAIL: B_CAV_1 defense_ready is not true after wait!")
		t6_pass = false
	if manager.can_unit_move_blue("B_CAV_1"):
		print("FAIL: B_CAV_1 still can move after wait!")
		t6_pass = false
	else:
		print("PASS: Wait (대기) ends action, sets defense_ready, and drops unit from move queue")
	
	if not t6_pass: all_pass = false

	print("\n==================================================")
	if all_pass:
		print(">>> ALL STEP-04R11 TESTS PASSED <<<")
		print("==================================================")
		quit(0)
	else:
		print(">>> SOME STEP-04R11 TESTS FAILED <<<")
		print("==================================================")
		quit(1)
