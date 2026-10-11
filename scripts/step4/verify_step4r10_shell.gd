extends SceneTree
# Shell-level R10 verification — checks battlefield shell integration

const HexUtilsCls = preload("res://scripts/core/hex_utils.gd")
const Step3ConfigCls = preload("res://scripts/core/step3_config.gd")
const Step3PathfindingCls = preload("res://scripts/step3/step3_pathfinding.gd")

var _shell: Node2D
var _frame: int = 0
var _started: bool = false
var _evidence_dir: String = "D:/Game development/Demon slayer/StrategyGame/evidence"

func _initialize() -> void:
	root.size = Vector2i(1920,1080)
	root.content_scale_size = Vector2i(1920,1080)
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	var scene_res: PackedScene = load("res://scenes/step2r_battlefield_shell.tscn") as PackedScene
	if scene_res == null:
		push_error("Failed to load shell")
		quit(1)
		return
	_shell = scene_res.instantiate() as Node2D
	root.add_child(_shell)
	DirAccess.make_dir_recursive_absolute(_evidence_dir)

func _process(_delta: float) -> bool:
	_frame += 1
	if _frame >= 6 and not _started:
		_started = true
		_run_suite()
	return false

func _run_suite() -> void:
	print("\n==================================================")
	print("STEP-04R10 SHELL VERIFICATION START")
	print("==================================================")
	var um = _shell.get("unit_manager") as Step3UnitManager
	var ur = _shell.get("unit_renderer") as Node
	var btn: Button = _shell.get("next_turn_button") as Button
	var cam = _shell.get("camera")
	await create_timer(0.5).timeout

	var results: Dictionary = {}
	var all_pass: bool = true

	# Pre-check counts
	var initial_unresolved: Array = _shell.call("get_unresolved_friendly_field_units_in_stable_order")
	var initial_cnt: int = initial_unresolved.size()
	print("[SHELL] initial unresolved = %d" % initial_cnt)
	var initial_live: Array = _shell.call("get_live_friendly_field_units_in_stable_order")
	print("[SHELL] live friendly = %d" % initial_live.size())

	# TEST 1: untouched NEXT cycles, never END TURN
	print("\n--- SHELL TEST 1: untouched NEXT cycles ---")
	var visited: Array[String] = []
	var never_end: bool = true
	var never_resolved_loss: bool = true
	var first_id: String = str(initial_unresolved[0]["id"]) if not initial_unresolved.is_empty() else ""
	var starts_as_next: bool = ("NEXT" in btn.text)
	for i in range(45):
		var unresolved_before: Array = _shell.call("get_unresolved_friendly_field_units_in_stable_order")
		if unresolved_before.is_empty():
			never_end = false
			break
		if "END TURN" in btn.text:
			never_end = false
			break
		_shell.call("select_next_friendly_field_unit")
		await create_timer(0.04).timeout
		var sel_after: String = um.get_selected_unit_id()
		visited.append(sel_after)
		var unresolved_after: Array = _shell.call("get_unresolved_friendly_field_units_in_stable_order")
		if unresolved_after.size() != initial_cnt:
			print("[SHELL-T1] unresolved changed %d -> %d after press %d (expected no change for untouched)" % [initial_cnt, unresolved_after.size(), i])
			never_resolved_loss = false
			# For untouched, should NOT change; but after our patch, untouched NEXT should NOT resolve, so this should remain same.
			# If it changed, test fails.
			break
	var first_count: int = 0
	for v in visited:
		if v == first_id:
			first_count += 1
	var cycled_back: bool = first_count >= 2
	var final_unresolved: Array = _shell.call("get_unresolved_friendly_field_units_in_stable_order")
	var end_not_available: bool = not final_unresolved.is_empty() and ("END TURN" not in btn.text)
	var t1_pass: bool = starts_as_next and never_end and never_resolved_loss and cycled_back and end_not_available
	results["T1_untouched_cycle"] = "PASS" if t1_pass else "FAIL"
	if not t1_pass: all_pass = false
	_save_json("R10_SHELL_T1_untouched.json", {
		"test": "untouched_cycle",
		"initial_cnt": initial_cnt,
		"first_id": first_id,
		"first_reappeared": first_count,
		"cycled_back": cycled_back,
		"never_end": never_end,
		"never_resolved_loss": never_resolved_loss,
		"final_unresolved": final_unresolved.size(),
		"starts_as_next": starts_as_next,
		"status": "PASS" if t1_pass else "FAIL"
	})
	print("[SHELL-T1] %s first=%s appeared %d times" % ["PASS" if t1_pass else "FAIL", first_id, first_count])
	# Reset selection
	um.deselect()
	await create_timer(0.1).timeout

	# TEST 2: BLUE move then NEXT resolves as GUARD
	print("\n--- SHELL TEST 2: BLUE move then NEXT ---")
	var target_id: String = "B_INF_1"
	var u_target: Dictionary = um.get_unit_by_id(target_id)
	var found_target: bool = not u_target.is_empty() and str(u_target.get("faction",""))=="blue"
	var t2_pass: bool = false
	var move_ok: bool = false
	var spent_before: float = 0.0
	var spent_after: float = 0.0
	if found_target:
		spent_before = float(u_target.get("turn_move_cost_spent", 0))
		var cur_coord: Vector2i = Vector2i(int(u_target["q"]), int(u_target["r"]))
		var cell_data: Dictionary = _shell.get("hex_grid").get("cell_data") if _shell.get("hex_grid") else {}
		var occupied: Dictionary = um.get_occupied_dict()
		var env: Variant = Step3PathfindingCls.calculate_envelope(cur_coord, str(u_target["class"]), float(u_target["base_mp"]), float(u_target["remaining_mp"]), Step3ConfigCls.MarchPolicy.GREEN_ONLY, cell_data, occupied, _shell.get("_river_cells"), "blue", _shell.get("_stronghold_cells"))
		var dest: Vector2i = Vector2i(-999,-999)
		var chosen_cost: float = 1.0
		var march_class: int = Step3ConfigCls.MarchClass.GREEN
		if not env.green_hexes.is_empty():
			for h in env.green_hexes:
				if h != cur_coord and HexUtilsCls.hex_distance_axial(cur_coord, h)==1:
					var route: Variant = Step3PathfindingCls.find_route(cur_coord, h, str(u_target["class"]), float(u_target["base_mp"]), float(u_target["remaining_mp"]), Step3ConfigCls.MarchPolicy.GREEN_ONLY, cell_data, occupied, _shell.get("_river_cells"), "blue", _shell.get("_stronghold_cells"))
					if route.found and route.cost <= 1.2:
						dest = h
						chosen_cost = route.cost
						march_class = route.march_class
						break
			if dest.x == -999:
				dest = env.green_hexes[0]
		if dest.x != -999:
			var path: Array[Vector2i] = [cur_coord, dest]
			var res: Dictionary = um.execute_move(target_id, path, chosen_cost, march_class, false)
			move_ok = bool(res.get("success", false))
			ur.call("update_unit_position", target_id, dest.x, dest.y)
			var updated: Dictionary = um.get_unit_by_id(target_id)
			spent_after = float(updated.get("turn_move_cost_spent", -1))
			var is_unresolved_after: bool = not um.is_unit_turn_resolved(target_id)
			# Now call shell NEXT which should resolve via GUARD
			# Select the moved unit first to make it current
			um.select_unit(target_id)
			await create_timer(0.05).timeout
			_shell.call("select_next_friendly_field_unit")
			await create_timer(0.1).timeout
			var is_resolved_now: bool = um.is_unit_turn_resolved(target_id)
			var defense: bool = bool(um.get_unit_by_id(target_id).get("defense_ready", false))
			var unguarded: bool = bool(um.get_unit_by_id(target_id).get("unguarded", false))
			var remaining: float = float(um.get_unit_by_id(target_id).get("remaining_mp", 99))
			# Check that target no longer in unresolved
			var unresolved_now: Array = _shell.call("get_unresolved_friendly_field_units_in_stable_order")
			var still_unresolved: bool = false
			for uu in unresolved_now:
				if str(uu["id"]) == target_id:
					still_unresolved = true
					break
			t2_pass = move_ok and is_unresolved_after and is_resolved_now and defense and not unguarded and remaining < 0.01 and not still_unresolved
			_save_json("R10_SHELL_T2_blue_next.json", {
				"test": "blue_move_then_next",
				"target": target_id,
				"move_ok": move_ok,
				"dest": "%d,%d" % [dest.x, dest.y],
				"spent_before": spent_before,
				"spent_after_move": spent_after,
				"is_unresolved_after_move": is_unresolved_after,
				"is_resolved_after_next": is_resolved_now,
				"defense_after": defense,
				"unguarded_after": unguarded,
				"remaining_after": remaining,
				"still_unresolved": still_unresolved,
				"status": "PASS" if t2_pass else "FAIL"
			})
			results["T2_blue_next"] = "PASS" if t2_pass else "FAIL"
			if not t2_pass: all_pass = false
			print("[SHELL-T2] %s move_ok=%s defense=%s resolved=%s still_unresolved=%s" % ["PASS" if t2_pass else "FAIL", str(move_ok), str(defense), str(is_resolved_now), str(still_unresolved)])
		else:
			_save_json("R10_SHELL_T2_blue_next.json", {"status":"FAIL","reason":"no dest"})
			results["T2_blue_next"] = "FAIL"
			all_pass = false
	else:
		_save_json("R10_SHELL_T2_blue_next.json", {"status":"FAIL","reason":"target not found"})
		results["T2_blue_next"] = "FAIL"
		all_pass = false

	# TEST 3: REST only before MP, ZZZ marker
	print("\n--- SHELL TEST 3: REST ---")
	var t3_pass: bool = false
	var rest_id: String = ""
	# Find untouched unit still
	var unres: Array = _shell.call("get_unresolved_friendly_field_units_in_stable_order")
	for u in unres:
		var uid: String = str(u["id"])
		if um.can_unit_rest(uid):
			rest_id = uid
			break
	var can_rest_before: bool = rest_id != "" and um.can_unit_rest(rest_id)
	var rest_res: Dictionary = {}
	var rest_ok: bool = false
	var marker_after: bool = false
	var unguarded_after_rest: bool = true
	if can_rest_before:
		rest_res = um.rest_unit(rest_id)
		rest_ok = bool(rest_res.get("success", false))
		if rest_ok:
			ur.call("set_unit_resting", rest_id, true)
			ur.call("set_unit_dimmed", rest_id, true)
			marker_after = ur.call("is_unit_resting", rest_id) if ur.has_method("is_unit_resting") else false
			unguarded_after_rest = bool(um.get_unit_by_id(rest_id).get("unguarded", true))
			# Check after moving, rest unavailable
			var can_after_move: bool = um.can_unit_rest("B_CAV_1") if not rest_id.is_empty() else false
			# Already moved B_INF_1, try rest on it
			var can_rest_moved: bool = um.can_unit_rest(target_id)
			t3_pass = rest_ok and marker_after and not unguarded_after_rest and not can_rest_moved
		_save_json("R10_SHELL_T3_rest.json", {
			"test": "rest",
			"rest_id": rest_id,
			"can_before": can_rest_before,
			"rest_success": rest_ok,
			"marker_visible": marker_after,
			"unguarded_after": unguarded_after_rest,
			"can_rest_moved": um.can_unit_rest(target_id),
			"status": "PASS" if t3_pass else "FAIL"
		})
		results["T3_rest"] = "PASS" if t3_pass else "FAIL"
		if not t3_pass: all_pass = false
		print("[SHELL-T3] %s rest_id=%s marker=%s unguarded=%s" % ["PASS" if t3_pass else "FAIL", rest_id, str(marker_after), str(unguarded_after_rest)])
	else:
		_save_json("R10_SHELL_T3_rest.json", {"status":"FAIL","reason":"no restable"})
		results["T3_rest"] = "FAIL"
		all_pass = false
		print("[SHELL-T3] FAIL no restable")

	# TEST 4: FORTIFY and persistence
	print("\n--- SHELL TEST 4: FORTIFY ---")
	var t4_pass: bool = false
	var fort_id: String = ""
	for u in _shell.call("get_unresolved_friendly_field_units_in_stable_order"):
		var uid: String = str(u["id"])
		if um.can_unit_fortify(uid):
			fort_id = uid
			break
	var can_fort_before: bool = fort_id != "" and um.can_unit_fortify(fort_id)
	var fort_ok: bool = false
	var fort_hp: int = 0
	if can_fort_before:
		var fres: Dictionary = um.fortify_unit(fort_id)
		fort_ok = bool(fres.get("success", false))
		if fort_ok:
			ur.call("set_unit_fortified", fort_id, true)
			ur.call("set_unit_dimmed", fort_id, true)
			fort_hp = int(um.get_unit_by_id(fort_id).get("field_fortification_hp", 0))
			var marker_fort: bool = ur.call("is_unit_fortified", fort_id) if ur.has_method("is_unit_fortified") else false
			# Try fortify after move should fail
			var can_fort_moved: bool = um.can_unit_fortify(target_id)
			t4_pass = fort_ok and marker_fort and fort_hp==180 and not can_fort_moved
		_save_json("R10_SHELL_T4_fortify.json", {
			"test": "fortify",
			"fort_id": fort_id,
			"can_before": can_fort_before,
			"fort_success": fort_ok,
			"hp": fort_hp,
			"marker": ur.call("is_unit_fortified", fort_id) if fort_id!="" else false,
			"status": "PASS" if t4_pass else "FAIL"
		})
		results["T4_fortify"] = "PASS" if t4_pass else "FAIL"
		if not t4_pass: all_pass = false
		print("[SHELL-T4] %s fort_id=%s hp=%d" % ["PASS" if t4_pass else "FAIL", fort_id, fort_hp])
	else:
		_save_json("R10_SHELL_T4_fortify.json", {"status":"FAIL","reason":"no fortifiable"})
		results["T4_fortify"] = "FAIL"
		all_pass = false
		print("[SHELL-T4] FAIL no fortifiable")

	# TEST 5: Persistence across turn
	print("\n--- SHELL TEST 5: Persistence ---")
	var t5_pass: bool = false
	if fort_id != "" and t4_pass:
		var hp_before: int = int(um.get_unit_by_id(fort_id).get("field_fortification_hp", 0))
		var fort_before: bool = bool(um.get_unit_by_id(fort_id).get("field_fortified", false))
		# Advance turn via manager end_turn (simulates enemy phase finish)
		# But shell has enemy phase logic; we use manager directly and trigger shell handler
		var prev_turn: int = um.get_current_turn()
		var new_turn: int = um.end_turn()
		# Notify shell
		_shell.call("_on_unit_manager_turn_advanced", new_turn)
		await create_timer(0.1).timeout
		var fort_after: bool = bool(um.get_unit_by_id(fort_id).get("field_fortified", false))
		var hp_after: int = int(um.get_unit_by_id(fort_id).get("field_fortification_hp", 0))
		var marker_still: bool = ur.call("is_unit_fortified", fort_id) if ur.has_method("is_unit_fortified") else false
		t5_pass = fort_before and fort_after and hp_before==hp_after and hp_after>0 and marker_still
		_save_json("R10_SHELL_T5_persist.json", {
			"test": "persistence",
			"fort_before": fort_before,
			"hp_before": hp_before,
			"fort_after": fort_after,
			"hp_after": hp_after,
			"marker_still": marker_still,
			"new_turn": new_turn,
			"status": "PASS" if t5_pass else "FAIL"
		})
		results["T5_persist"] = "PASS" if t5_pass else "FAIL"
		if not t5_pass: all_pass = false
		print("[SHELL-T5] %s hp %d->%d marker=%s" % ["PASS" if t5_pass else "FAIL", hp_before, hp_after, str(marker_still)])
	else:
		_save_json("R10_SHELL_T5_persist.json", {"status":"FAIL","reason":"no fort_id"})
		results["T5_persist"] = "FAIL"
		all_pass = false

	# TEST 6: Dismantle
	print("\n--- SHELL TEST 6: Dismantle ---")
	var t6_pass: bool = false
	if fort_id != "" and t5_pass:
		# Fortified unit at new turn should have dismantle available
		var can_dismantle: bool = um.has_method("can_dismantle_fortification") and um.can_dismantle_fortification(fort_id)
		var dismantle_ok: bool = false
		var spent_after_dism: float = 0
		var remaining_after_dism: float = 0
		var fort_after_dism: bool = true
		if can_dismantle:
			var dres: Dictionary = um.dismantle_fortification(fort_id)
			dismantle_ok = bool(dres.get("success", false))
			spent_after_dism = float(um.get_unit_by_id(fort_id).get("turn_move_cost_spent", -1))
			remaining_after_dism = float(um.get_unit_by_id(fort_id).get("remaining_mp", -1))
			fort_after_dism = bool(um.get_unit_by_id(fort_id).get("field_fortified", false))
			ur.call("set_unit_fortified", fort_id, false)
			ur.call("set_unit_dimmed", fort_id, false)
			# Recalc envelope
			_shell.call("_on_unit_selection_changed", um.get_unit_by_id(fort_id))
			# Now try move with remaining
			var u_dism: Dictionary = um.get_unit_by_id(fort_id)
			var cur: Vector2i = Vector2i(int(u_dism["q"]), int(u_dism["r"]))
			var cell_data2: Dictionary = _shell.get("hex_grid").get("cell_data") if _shell.get("hex_grid") else {}
			var occupied2: Dictionary = um.get_occupied_dict()
			var env2: Variant = Step3PathfindingCls.calculate_envelope(cur, str(u_dism["class"]), float(u_dism["base_mp"]), float(u_dism["remaining_mp"]), Step3ConfigCls.MarchPolicy.GREEN_ONLY, cell_data2, occupied2, _shell.get("_river_cells"), "blue", _shell.get("_stronghold_cells"))
			var move_ok_dism: bool = false
			var dest2: Vector2i = Vector2i(-999,-999)
			if not env2.green_hexes.is_empty():
				for h in env2.green_hexes:
					if h != cur:
						dest2 = h
						break
				if dest2.x != -999:
					var path2: Array[Vector2i] = [cur, dest2]
					var route2: Variant = Step3PathfindingCls.find_route(cur, dest2, str(u_dism["class"]), float(u_dism["base_mp"]), float(u_dism["remaining_mp"]), Step3ConfigCls.MarchPolicy.GREEN_ONLY, cell_data2, occupied2, _shell.get("_river_cells"), "blue", _shell.get("_stronghold_cells"))
					if route2.found:
						var moveres: Dictionary = um.execute_move(fort_id, path2, route2.cost, route2.march_class, route2.crosses_river)
						move_ok_dism = bool(moveres.get("success", false))
						if move_ok_dism:
							ur.call("update_unit_position", fort_id, dest2.x, dest2.y)
			t6_pass = can_dismantle and dismantle_ok and abs(spent_after_dism-1.0)<0.01 and remaining_after_dism>0.5 and not fort_after_dism and move_ok_dism
			_save_json("R10_SHELL_T6_dismantle.json", {
				"test": "dismantle",
				"can_dismantle": can_dismantle,
				"dismantle_ok": dismantle_ok,
				"spent_after": spent_after_dism,
				"remaining_after": remaining_after_dism,
				"fort_after": fort_after_dism,
				"move_after_ok": move_ok_dism,
				"status": "PASS" if t6_pass else "FAIL"
			})
		else:
			_save_json("R10_SHELL_T6_dismantle.json", {"status":"FAIL","reason":"cannot dismantle","can":can_dismantle})
		results["T6_dismantle"] = "PASS" if t6_pass else "FAIL"
		if not t6_pass: all_pass = false
		print("[SHELL-T6] %s can=%s dismantle_ok=%s spent=%.1f remaining=%.1f fort_after=%s" % ["PASS" if t6_pass else "FAIL", str(can_dismantle), str(dismantle_ok), spent_after_dism, remaining_after_dism, str(fort_after_dism)])
	else:
		_save_json("R10_SHELL_T6_dismantle.json", {"status":"FAIL","reason":"no fort persist"})
		results["T6_dismantle"] = "FAIL"
		all_pass = false

	# TEST 7: END TURN condition and enemy phase
	print("\n--- SHELL TEST 7: END TURN & Enemy Phase ---")
	var t7_pass: bool = false
	# After previous tests, some units resolved, some not (untouched remain). END TURN should NOT be available yet if any unresolved remains.
	var unres_mid: Array = _shell.call("get_unresolved_friendly_field_units_in_stable_order")
	var mid_cnt: int = unres_mid.size()
	var btn_is_next: bool = ("NEXT" in btn.text)
	# Now resolve all remaining via appropriate means (rest/fortify or blue then next)
	var remaining_all: Array = _shell.call("get_unresolved_friendly_field_units_in_stable_order")
	for uu in remaining_all.duplicate():
		var uid: String = str(uu["id"])
		if um.is_unit_turn_resolved(uid):
			continue
		if um.can_unit_rest(uid):
			um.rest_unit(uid)
			ur.call("set_unit_resting", uid, true)
			ur.call("set_unit_dimmed", uid, true)
		elif um.can_unit_fortify(uid):
			um.fortify_unit(uid)
			ur.call("set_unit_fortified", uid, true)
			ur.call("set_unit_dimmed", uid, true)
		else:
			var cur_u: Dictionary = um.get_unit_by_id(uid)
			# If already has BLUE movement, resolve directly as GUARD (forfeit remaining)
			if bool(cur_u.get("has_moved", false)) and float(cur_u.get("turn_move_cost_spent", 0.0)) > 0.001:
				um.resolve_unit_via_next(uid)
				ur.call("set_unit_dimmed", uid, true)
			else:
				var cur = Vector2i(int(uu["q"]), int(uu["r"]))
				var cell_data: Dictionary = _shell.get("hex_grid").get("cell_data") if _shell.get("hex_grid") else {}
				var occupied: Dictionary = um.get_occupied_dict()
				var env: Variant = Step3PathfindingCls.calculate_envelope(cur, str(uu["class"]), float(uu["base_mp"]), float(uu["remaining_mp"]), Step3ConfigCls.MarchPolicy.GREEN_ONLY, cell_data, occupied, _shell.get("_river_cells"), "blue", _shell.get("_stronghold_cells"))
				if not env.green_hexes.is_empty():
					var dest: Vector2i = env.green_hexes[0]
					if dest != cur:
						var route: Variant = Step3PathfindingCls.find_route(cur, dest, str(uu["class"]), float(uu["base_mp"]), float(uu["remaining_mp"]), Step3ConfigCls.MarchPolicy.GREEN_ONLY, cell_data, occupied, _shell.get("_river_cells"), "blue", _shell.get("_stronghold_cells"))
						if route.found:
							um.execute_move(uid, route.path, route.cost, route.march_class, false)
							ur.call("update_unit_position", uid, dest.x, dest.y)
							um.resolve_unit_via_next(uid)
							ur.call("set_unit_dimmed", uid, true)
	await create_timer(0.1).timeout
	_shell.call("_update_next_button_state")
	await create_timer(0.05).timeout
	var unres_final: Array = _shell.call("get_unresolved_friendly_field_units_in_stable_order")
	var end_available: bool = unres_final.is_empty() and ("END TURN" in btn.text)
	# Now actually trigger END TURN and check enemy phase completes
	var turn_before: int = um.get_current_turn()
	var phase_before: int = int(_shell.get("_turn_phase"))
	_shell.call("end_player_turn")
	# end_player_turn does await enemy processing (attacks+moves). Wait longer for full resolution (~3s)
	await create_timer(3.0).timeout
	var turn_after: int = um.get_current_turn()
	var phase_after: int = int(_shell.get("_turn_phase"))
	var btn_after: String = btn.text
	var turn_advanced: bool = turn_after == turn_before + 1
	var phase_back_to_player: bool = phase_after == 0
	var btn_back_to_next: bool = ("NEXT" in btn_after)
	t7_pass = mid_cnt > 0 and btn_is_next and end_available and turn_advanced and phase_back_to_player
	_save_json("R10_SHELL_T7_endturn.json", {
		"test": "endturn_enemy",
		"mid_unresolved": mid_cnt,
		"btn_is_next_mid": btn_is_next,
		"end_available_after_resolve": end_available,
		"turn_before": turn_before,
		"turn_after": turn_after,
		"phase_before": phase_before,
		"phase_after": phase_after,
		"btn_after": btn_after,
		"status": "PASS" if t7_pass else "FAIL"
	})
	results["T7_endturn"] = "PASS" if t7_pass else "FAIL"
	if not t7_pass: all_pass = false
	print("[SHELL-T7] %s mid_unresolved=%d end_available=%s turn %d->%d phase %d->%d" % ["PASS" if t7_pass else "FAIL", mid_cnt, str(end_available), turn_before, turn_after, phase_before, phase_after])

	# Summary
	var summary: Dictionary = {
		"task_id": "STEP-04R10-GUARD-REST-FORTIFY-TURN-SEMANTICS-SHELL",
		"all_pass": all_pass,
		"results": results,
		"overall": "PASS" if all_pass else "FAIL"
	}
	_save_json("R10_SHELL_SUMMARY.json", summary)
	print("\n==================================================")
	print("R10 SHELL SUMMARY: %s" % summary["overall"])
	for k in results.keys():
		print("  %s: %s" % [k, results[k]])
	print("==================================================")
	quit(0 if all_pass else 1)

func _save_json(fname: String, data: Dictionary) -> void:
	var path: String = _evidence_dir + "/" + fname
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(data, "\t"))
		f.close()
		print("[SAVE] %s" % path)
