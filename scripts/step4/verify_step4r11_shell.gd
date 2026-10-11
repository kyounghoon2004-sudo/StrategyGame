extends SceneTree
# STEP-04R11 Shell Verification Suite
# Tests full battlefield shell integration:
# 1. Blue MP cycling in UI (unit comes back on NEXT)
# 2. Fortify ends Turn 1
# 3. Turn 2 starts with fortification preserved and does not force action
# 4. Dismantle button appears on Turn 2
# 5. Dismantle fortification enables movement in same turn and succeeds
# 6. Wait (대기) button ends unit action cleanly

const BattlefieldShellScene = preload("res://scenes/step2r_battlefield_shell.tscn")
const Step3ConfigCls = preload("res://scripts/core/step3_config.gd")

var _shell: Node = null
var _frame: int = 0
var _started: bool = false

func _initialize() -> void:
	root.size = Vector2i(1920, 1080)
	root.content_scale_size = Vector2i(1920, 1080)
	_shell = BattlefieldShellScene.instantiate()
	root.add_child(_shell)

func _process(_delta: float) -> bool:
	_frame += 1
	if _frame >= 5 and not _started:
		_started = true
		_run_shell_tests()
	return false

func _run_shell_tests() -> void:
	print("\n==================================================")
	print("STEP-04R11 SHELL VERIFICATION START")
	print("==================================================")
	var all_pass: bool = true

	var um: Node = _shell.get("unit_manager")
	var ur: Node = _shell.get("unit_renderer")
	var btn: Button = _shell.get("next_turn_button")

	# ----------------------------------------------------
	# SHELL TEST 1: Blue MP Cycling in Shell NEXT
	# ----------------------------------------------------
	print("\n--- SHELL TEST 1: Blue MP Cycling in Shell NEXT ---")
	var t1_pass: bool = true
	_shell.call("select_next_friendly_field_unit")
	var u1_id: String = um.call("get_selected_unit_id")
	var u1: Dictionary = um.call("get_unit_by_id", u1_id)
	var u1_spent: float = float(u1.get("turn_move_cost_spent", 0.0))
	var u1_base: float = float(u1.get("base_mp", 2.0))
	
	# Cycle through units until u1 comes back
	var cycle_count: int = 0
	var found_again: bool = false
	var active_size: int = um.call("get_units_able_to_move_in_stable_order").size()
	for i in range(active_size + 5):
		_shell.call("select_next_friendly_field_unit")
		var cur_id: String = um.call("get_selected_unit_id")
		if cur_id == u1_id:
			found_again = true
			break
		cycle_count += 1
	
	if not found_again:
		print("FAIL: Unit %s did NOT cycle back around in NEXT loop!" % u1_id)
		t1_pass = false
	else:
		print("PASS: Unit %s cycled back around after %d steps" % [u1_id, cycle_count])
	
	# Verify u1 still has its MP
	var u1_again: Dictionary = um.call("get_unit_by_id", u1_id)
	if bool(u1_again.get("action_ended", false)):
		print("FAIL: Unit %s was marked action_ended on cycling!" % u1_id)
		t1_pass = false
	
	if not t1_pass: all_pass = false

	# ----------------------------------------------------
	# SHELL TEST 2: Fortify on Turn 1 & Skip from NEXT
	# ----------------------------------------------------
	print("\n--- SHELL TEST 2: Fortify on Turn 1 & Skip from NEXT ---")
	var t2_pass: bool = true
	var fort_target_id: String = u1_id
	um.call("select_unit", fort_target_id)
	_shell.call("_on_fortify_button_pressed")
	
	var fort_u: Dictionary = um.call("get_unit_by_id", fort_target_id)
	if not bool(fort_u.get("field_fortified", false)):
		print("FAIL: Unit %s is not field_fortified after fortify button!" % fort_target_id)
		t2_pass = false
	if not bool(fort_u.get("action_ended", false)):
		print("FAIL: Unit %s action_ended is not true on fortify!" % fort_target_id)
		t2_pass = false
	
	# Verify fort_target_id is no longer in active move queue
	var active_units: Array = um.call("get_units_able_to_move_in_stable_order")
	var active_ids: Array = active_units.map(func(u): return u["id"])
	if active_ids.has(fort_target_id):
		print("FAIL: Fortified unit %s still in active move queue!" % fort_target_id)
		t2_pass = false
	else:
		print("PASS: Fortified unit %s skipped from move queue in Turn 1" % fort_target_id)
	
	if not t2_pass: all_pass = false

	# ----------------------------------------------------
	# SHELL TEST 3: Turn 2 Fortification Preserved & Not Forced to Move
	# ----------------------------------------------------
	print("\n--- SHELL TEST 3: Turn 2 Fortification Preserved & Not Forced to Move ---")
	var t3_pass: bool = true
	# Advance turn to Turn 2
	_shell.call("end_player_phase")
	await create_timer(0.5).timeout
	
	var cur_turn: int = _shell.get("_current_turn")
	if cur_turn != 2:
		print("FAIL: Expected Turn 2, got %d" % cur_turn)
		t3_pass = false
	
	var fort_t2: Dictionary = um.call("get_unit_by_id", fort_target_id)
	if not bool(fort_t2.get("field_fortified", false)):
		print("FAIL: Fortification not preserved on Turn 2!")
		t3_pass = false
	
	# Fortified unit must NOT be in active move queue
	var active_t2: Array = um.call("get_units_able_to_move_in_stable_order")
	var active_t2_ids: Array = active_t2.map(func(u): return u["id"])
	if active_t2_ids.has(fort_target_id):
		print("FAIL: Fortified unit %s is in active move queue on Turn 2 (forces action)!" % fort_target_id)
		t3_pass = false
	else:
		print("PASS: Fortified unit %s is holding position on Turn 2 and NOT in mandatory move queue" % fort_target_id)
	
	if not t3_pass: all_pass = false

	# ----------------------------------------------------
	# SHELL TEST 4: Dismantle Button Appears & Enables Move in Same Turn
	# ----------------------------------------------------
	print("\n--- SHELL TEST 4: Dismantle Button Appears & Enables Move in Same Turn ---")
	var t4_pass: bool = true
	# Select fortified unit
	um.call("select_unit", fort_target_id)
	var btn_dismantle: Button = _shell.get("_btn_dismantle")
	var btn_fortify: Button = _shell.get("_btn_fortify")
	var btn_rest: Button = _shell.get("_btn_rest")
	var btn_wait: Button = _shell.get("_btn_wait")
	
	if not btn_dismantle or not btn_dismantle.visible:
		print("FAIL: _btn_dismantle is not visible for fortified unit!")
		t4_pass = false
	if btn_dismantle and btn_dismantle.disabled:
		print("FAIL: _btn_dismantle is disabled!")
		t4_pass = false
	if btn_fortify and btn_fortify.visible:
		print("FAIL: _btn_fortify is visible while already fortified!")
		t4_pass = false
	
	# Click dismantle button
	_shell.call("_on_dismantle_button_pressed")
	
	var u_after_dism: Dictionary = um.call("get_unit_by_id", fort_target_id)
	if bool(u_after_dism.get("field_fortified", false)):
		print("FAIL: Unit still fortified after dismantle button!")
		t4_pass = false
	if float(u_after_dism.get("remaining_mp", 0.0)) < 2.0:
		print("FAIL: Unit remaining_mp < 2.0 after free dismantle (got %.1f)!" % float(u_after_dism.get("remaining_mp", 0.0)))
		t4_pass = false
	
	# Move unit on same turn
	var cur_q: int = int(u_after_dism["q"])
	var cur_r: int = int(u_after_dism["r"])
	var dest: Vector2i = Vector2i(cur_q + 1, cur_r)
	var move_path: Array[Vector2i] = [Vector2i(cur_q, cur_r), dest]
	var move_res: Dictionary = um.call("execute_move", fort_target_id, move_path, 1.0, Step3ConfigCls.MarchClass.GREEN, false)
	if not move_res.get("success", false):
		print("FAIL: Movement in same turn after dismantle failed: %s" % str(move_res))
		t4_pass = false
	else:
		print("PASS: Dismantled fortification and moved in same turn successfully!")
	
	if not t4_pass: all_pass = false

	# ----------------------------------------------------
	# SHELL TEST 5: Wait (대기) Button Functionality
	# ----------------------------------------------------
	print("\n--- SHELL TEST 5: Wait (대기) Button Functionality ---")
	var t5_pass: bool = true
	_shell.call("select_next_friendly_field_unit")
	var wait_target_id: String = um.call("get_selected_unit_id")
	if wait_target_id == "":
		print("FAIL: No unit selected for wait test!")
		t5_pass = false
	else:
		_shell.call("_on_wait_button_pressed")
		var waited_u: Dictionary = um.call("get_unit_by_id", wait_target_id)
		if not bool(waited_u.get("action_ended", false)):
			print("FAIL: Waited unit action_ended is not true!")
			t5_pass = false
		if not bool(waited_u.get("defense_ready", false)):
			print("FAIL: Waited unit defense_ready is not true!")
			t5_pass = false
		else:
			print("PASS: Wait (대기) button ended action for unit %s" % wait_target_id)
	
	if not t5_pass: all_pass = false

	print("\n==================================================")
	if all_pass:
		print(">>> ALL STEP-04R11 SHELL TESTS PASSED <<<")
		print("==================================================")
		quit(0)
	else:
		print(">>> SOME STEP-04R11 SHELL TESTS FAILED <<<")
		print("==================================================")
		quit(1)
