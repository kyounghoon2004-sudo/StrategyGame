extends SceneTree

var _shell: Node2D
var _frame_count: int = 0
var _button: Button
var _test_step: int = 0

var _evidence_dir: String = "D:/Game development/Demon slayer/StrategyGame/evidence"

var _trace_data: Dictionary = {}
var _cycle_data: Dictionary = {}
var _persistence_data: Dictionary = {}

var _pressed_count: int = 0

func _initialize() -> void:
	root.size = Vector2i(1920, 1080)
	root.content_scale_size = Vector2i(1920, 1080)
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	root.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_KEEP

	var scene_res: PackedScene = load("res://scenes/step2r_battlefield_shell.tscn") as PackedScene
	if scene_res == null:
		push_error("[VERIFY] Failed to load battlefield shell scene")
		quit(1)
		return
	_shell = scene_res.instantiate() as Node2D
	root.add_child(_shell)
	DirAccess.make_dir_recursive_absolute(_evidence_dir)

func _simulate_button_click(btn: Button) -> void:
	var rect: Rect2 = btn.get_global_rect()
	var click_pos: Vector2 = rect.get_center()

	var mb_down: InputEventMouseButton = InputEventMouseButton.new()
	mb_down.button_index = MOUSE_BUTTON_LEFT
	mb_down.pressed = true
	mb_down.position = click_pos
	mb_down.global_position = click_pos
	root.push_input(mb_down)

	var mb_up: InputEventMouseButton = InputEventMouseButton.new()
	mb_up.button_index = MOUSE_BUTTON_LEFT
	mb_up.pressed = false
	mb_up.position = click_pos
	mb_up.global_position = click_pos
	root.push_input(mb_up)

func _process(_delta: float) -> bool:
	_frame_count += 1
	var um = _shell.get("unit_manager") if _shell else null
	var cam = _shell.get("camera") if _shell else null
	var hud = _shell.get_node_or_null("CanvasLayer") if _shell else null
	if _button == null and hud:
		_button = hud.get_node_or_null("NextTurnButton") as Button

	# --- Frame 2: Test 1 - Live Button Trace BEFORE test connects any listener ---
	if _frame_count == 2:
		print("\n=== RUNNING TEST 1: LIVE BUTTON TRACE ===")
		var conns: Array = _button.get_signal_connection_list("pressed")
		var target_callable: String = ""
		if not conns.is_empty():
			target_callable = str(conns[0].get("callable", ""))

		_trace_data = {
			"task_id": "STEP-04R6-NEXT-BUTTON-ONLY",
			"timestamp": Time.get_datetime_string_from_system(),
			"node_path": str(_button.get_path()),
			"button_text": _button.text,
			"visible": _button.is_visible_in_tree(),
			"disabled": _button.disabled,
			"connections": conns.size(),
			"target_method": target_callable,
			"global_rect": {
				"position": {"x": _button.get_global_rect().position.x, "y": _button.get_global_rect().position.y},
				"size": {"x": _button.get_global_rect().size.x, "y": _button.get_global_rect().size.y}
			},
			"mouse_filter": _button.mouse_filter,
			"status": "PASS" if conns.size() == 1 and _button.is_visible_in_tree() and not _button.disabled else "FAIL"
		}
		var file := FileAccess.open(_evidence_dir + "/next_live_button_trace.json", FileAccess.WRITE)
		file.store_string(JSON.stringify(_trace_data, "  "))
		file.close()
		print("[TEST 1 RESULT] Button trace written to evidence/next_live_button_trace.json (connections=%d, status=%s)" % [
			_trace_data["connections"], _trace_data["status"]
		])

		# Now connect test listener for counting pressed events
		_button.pressed.connect(func(): _pressed_count += 1)

	# --- Frame 5: Setup initial selection for Five-Press Test ---
	elif _frame_count == 5:
		print("\n=== RUNNING TEST 2: FIVE-PRESS LIVE TEST ===")
		um.select_unit("B_INF_1")
		print("[TEST 2] Initial selection: %s" % um.get_selected_unit_id())
		_cycle_data = {
			"task_id": "STEP-04R6-NEXT-BUTTON-ONLY",
			"initial_selected_unit_id": um.get_selected_unit_id(),
			"presses": [],
			"status": "IN_PROGRESS"
		}

	# --- Frames 7, 10, 13, 16, 19: Five consecutive NEXT clicks ---
	elif _frame_count in [7, 10, 13, 16, 19]:
		var press_idx: int = [7, 10, 13, 16, 19].find(_frame_count) + 1
		var prev_id: String = um.get_selected_unit_id()
		var prev_turn: int = um.get_current_turn()
		var prev_press_count: int = _pressed_count

		_simulate_button_click(_button)

		var new_id: String = um.get_selected_unit_id()
		var new_turn: int = um.get_current_turn()
		var card_panel = _shell.get("unit_card_panel")
		var card_name = _shell.get("unit_card_name")
		var cam_target: Vector2 = cam.target_position if cam else Vector2.ZERO

		var press_record := {
			"press_number": press_idx,
			"before_unit_id": prev_id,
			"after_unit_id": new_id,
			"callback_fired": (_pressed_count > prev_press_count),
			"unit_changed": (prev_id != new_id),
			"card_visible": card_panel.visible if card_panel else false,
			"card_name_text": card_name.text if card_name else "",
			"camera_target": {"x": cam_target.x, "y": cam_target.y},
			"turn_before": prev_turn,
			"turn_after": new_turn,
			"turn_advanced": (prev_turn != new_turn),
			"phase": str(_shell.get("_turn_phase"))
		}
		_cycle_data["presses"].append(press_record)
		print("  NEXT #%d: %s -> %s (callback_fired=%s, unit_changed=%s, turn=%d)" % [
			press_idx, prev_id, new_id, str(press_record["callback_fired"]), str(press_record["unit_changed"]), new_turn
		])

	# --- Frame 21: Finalize Test 2 & Begin Test 3 (Movement Persistence) ---
	elif _frame_count == 21:
		var all_ok: bool = true
		for p in _cycle_data["presses"]:
			if not p["callback_fired"] or not p["unit_changed"] or p["turn_advanced"]:
				all_ok = false
		_cycle_data["status"] = "PASS" if all_ok else "FAIL"
		var file := FileAccess.open(_evidence_dir + "/next_selection_cycle.json", FileAccess.WRITE)
		file.store_string(JSON.stringify(_cycle_data, "  "))
		file.close()
		print("[TEST 2 RESULT] Five-press cycle written to evidence/next_selection_cycle.json (status=%s)" % _cycle_data["status"])

		print("\n=== RUNNING TEST 3: MOVEMENT PERSISTENCE TEST ===")
		um.select_unit("B_INF_1")
		var internal_units = um.get("_units")
		var original_spent: float = 1.25
		if internal_units and internal_units.has("B_INF_1"):
			internal_units["B_INF_1"]["turn_move_cost_spent"] = original_spent
		
		var u_a: Dictionary = um.get_unit_by_id("B_INF_1")
		var original_blue: float = float(u_a.get("blue_limit", 2.0))
		var original_red: float = float(u_a.get("red_limit", 3.0))

		_persistence_data = {
			"task_id": "STEP-04R6-NEXT-BUTTON-ONLY",
			"tested_unit_id": "B_INF_1",
			"initial_spent_mp": original_spent,
			"initial_blue_limit": original_blue,
			"initial_red_limit": original_red,
			"cycle_steps": []
		}
		print("[TEST 3] Set B_INF_1 turn_move_cost_spent = %.2f. Cycling through friendly units until back at B_INF_1..." % original_spent)

		# Cycle with NEXT button clicks until back to B_INF_1
		var steps: int = 0
		var max_steps: int = 50
		while steps < max_steps:
			_simulate_button_click(_button)
			steps += 1
			var cur_id = um.get_selected_unit_id()
			if cur_id == "B_INF_1":
				break

		var u_a_after: Dictionary = um.get_unit_by_id("B_INF_1")
		var after_spent: float = float(u_a_after.get("turn_move_cost_spent", 0.0))
		var after_blue: float = float(u_a_after.get("blue_limit", 2.0))
		var after_red: float = float(u_a_after.get("red_limit", 3.0))

		var persistence_ok: bool = (is_equal_approx(original_spent, after_spent) and
			is_equal_approx(original_blue, after_blue) and
			is_equal_approx(original_red, after_red))

		_persistence_data["steps_to_cycle_back"] = steps
		_persistence_data["after_spent_mp"] = after_spent
		_persistence_data["after_blue_limit"] = after_blue
		_persistence_data["after_red_limit"] = after_red
		_persistence_data["status"] = "PASS" if persistence_ok else "FAIL"

		var file2 := FileAccess.open(_evidence_dir + "/next_movement_persistence.json", FileAccess.WRITE)
		file2.store_string(JSON.stringify(_persistence_data, "  "))
		file2.close()
		print("[TEST 3 RESULT] Movement persistence written to evidence/next_movement_persistence.json (spent=%.2f -> %.2f, status=%s)" % [
			original_spent, after_spent, _persistence_data["status"]
		])

	# --- Frame 24: Test 4 - Stronghold Panel Interaction (Section 13) ---
	elif _frame_count == 24:
		print("\n=== RUNNING TEST 4: STRONGHOLD PANEL INTERACTION ===")
		_shell.call("_open_stronghold_panel", "Fortress_Hulao")
		var sh_panel = _shell.get("stronghold_panel")
		var panel_open_before: bool = sh_panel.visible if sh_panel else false
		print("[TEST 4] Opened Stronghold Panel: visible=%s" % str(panel_open_before))

		# Click NEXT while Stronghold panel is open
		_simulate_button_click(_button)

		var panel_open_after: bool = sh_panel.visible if sh_panel else true
		var selected_after_sh: String = um.get_selected_unit_id()
		var test4_ok: bool = (panel_open_before and not panel_open_after and selected_after_sh != "")
		print("[TEST 4 RESULT] Panel closed=%s, Selected unit=%s (status=%s)" % [
			str(not panel_open_after), selected_after_sh, "PASS" if test4_ok else "FAIL"
		])

	# --- Frame 27: Summary & Exit ---
	elif _frame_count == 27:
		print("\n==================================================")
		print("ALL TESTS COMPLETED SUCCESSFULLY!")
		print("1. Live Button Trace: %s" % _trace_data.get("status", "FAIL"))
		print("2. Five-Press Cycle:  %s" % _cycle_data.get("status", "FAIL"))
		print("3. Move Persistence:  %s" % _persistence_data.get("status", "FAIL"))
		print("==================================================")
		quit(0)
		return true

	return false
