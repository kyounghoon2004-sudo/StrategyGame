extends SceneTree

func _init() -> void:
	print("====================================================")
	print("[TEST-STEP06R3] Starting Step-06R3 Logistics & Trader NPC Verification")
	print("====================================================")
	
	var all_passed: bool = true
	
	# TEST 1: Step6Config Constants and Urgency Mapping
	print("\n--- TEST 1: Step6Config Constants & Urgency ---")
	var cfg = preload("res://scripts/step6/step6_config.gd")
	if cfg.SUPPLY_DAYS_HEALTHY != 5.0 or cfg.SUPPLY_DAYS_WARNING != 3.0 or cfg.SUPPLY_DAYS_CRITICAL != 1.0:
		printerr("FAIL: Config urgency thresholds incorrect")
		all_passed = false
	else:
		print("PASS: Urgency thresholds (5.0, 3.0, 1.0) correct")
		
	var lbl_healthy = cfg.supply_days_urgency_label(6.0)
	var lbl_warning = cfg.supply_days_urgency_label(4.0)
	var lbl_critical = cfg.supply_days_urgency_label(2.0)
	var lbl_empty = cfg.supply_days_urgency_label(0.0)
	if lbl_healthy != "양호" or lbl_warning != "경고" or lbl_critical != "위험" or lbl_empty != "고갈":
		printerr("FAIL: Urgency labels incorrect: %s, %s, %s, %s" % [lbl_healthy, lbl_warning, lbl_critical, lbl_empty])
		all_passed = false
	else:
		print("PASS: Urgency labels mapped correctly (6d->양호, 4d->경고, 2d->위험, 0d->고갈)")
		
	if cfg.ROUTE_STRATEGY_FASTEST != "fastest" or cfg.ROUTE_STRATEGY_ROAD != "road" or cfg.ROUTE_STRATEGY_SAFE != "safe":
		printerr("FAIL: Route strategy constants incorrect")
		all_passed = false
	else:
		print("PASS: Route strategy constants correct (fastest, road, safe)")
		
	# TEST 2: Step6SupplyOverlay Layering and Methods
	print("\n--- TEST 2: Step6SupplyOverlay Layering & Settler-Lens ---")
	var overlay_cls = preload("res://scripts/step6/step6_supply_overlay.gd")
	var overlay: Node2D = overlay_cls.new()
	overlay._ready()
	if overlay.z_index != 22:
		printerr("FAIL: Overlay Z-index is %d, expected 22" % overlay.z_index)
		all_passed = false
	else:
		print("PASS: Overlay Z-index is strictly 22 (mountain layer fix preserved)")
		
	var sample_costs: Dictionary = {
		"-25,0": 0.0,
		"-24,0": 1.0,
		"-23,0": 2.5,
		"-22,0": 4.5
	}
	overlay.call("add_coverage_with_costs", sample_costs, 5.0)
	var cov_data: Dictionary = overlay.get("_coverage_data")
	if cov_data.size() != 4:
		printerr("FAIL: _coverage_data count incorrect: %d" % cov_data.size())
		all_passed = false
	else:
		print("PASS: Settler-lens multi-tier reach populated 4 hexes with tiers")
		
	var sample_routes: Array = [{
		"id": "B_SUP_1",
		"path": [Vector2i(-25, 0), Vector2i(-24, 0), Vector2i(-23, 0), Vector2i(-22, 0)],
		"radius": 2
	}]
	overlay.call("set_active_routes", sample_routes)
	var routes_arr: Array = overlay.get("_routes")
	if routes_arr.size() != 1:
		printerr("FAIL: set_active_routes failed")
		all_passed = false
	else:
		print("PASS: set_active_routes populated active route and 2-hex corridor")
		
	overlay.call("preview_candidate_route", [Vector2i(0, 0), Vector2i(1, 0)])
	var prev_dict: Dictionary = overlay.get("_preview_route")
	if prev_dict.is_empty():
		printerr("FAIL: preview_candidate_route failed")
		all_passed = false
	else:
		print("PASS: preview_candidate_route stored candidate path and corridor")
		
	overlay.call("clear_all")
	if not (overlay.get("_coverage_data") as Dictionary).is_empty() or not (overlay.get("_routes") as Array).is_empty():
		printerr("FAIL: clear_all failed to reset overlay")
		all_passed = false
	else:
		print("PASS: clear_all cleanly reset all overlay layers")
	overlay.free()

	# TEST 3: Step6DecisionLayer Trader Route Management & Macro A*
	print("\n--- TEST 3: Step6DecisionLayer Trader Route System ---")
	var unit_mgr_cls = preload("res://scripts/step3/step3_unit_manager.gd")
	var unit_mgr = unit_mgr_cls.new()
	var test_units: Array = [
		{"id": "B_HQ_1", "class": "hq", "faction": "blue", "q": -26, "r": 0, "soldier_count": 300, "max_count": 300, "local_supply": 2000.0, "supply_state": 0},
		{"id": "B_SUP_1", "class": "supply", "faction": "blue", "q": -25, "r": 0, "soldier_count": 40, "max_count": 40, "convoy_cargo": 40.0, "is_convoy": true},
		{"id": "B_INF_1", "class": "infantry", "faction": "blue", "q": -22, "r": 0, "soldier_count": 400, "max_count": 400, "local_supply": 100.0, "supply_state": 0}
	]
	unit_mgr.initialize_from_renderer_units(test_units)
	
	var dec_layer_cls = preload("res://scripts/step6/step6_decision_layer.gd")
	var dec = dec_layer_cls.new()
	var init_res = dec.initialize(unit_mgr, Vector2i(-12, 2))
	if not bool(init_res.get("success", false)):
		printerr("FAIL: Step6DecisionLayer initialize failed: %s" % str(init_res.get("error", "")))
		all_passed = false
	else:
		print("PASS: Step6DecisionLayer initialized with HQ and convoys")
		
	# Macro route computation
	var macro_res = dec.compute_macro_route(Vector2i(-25, 0), Vector2i(-12, 2), "road", {}, {}, {})
	if not bool(macro_res.get("found", false)) or (macro_res.get("path", []) as Array).is_empty():
		printerr("FAIL: compute_macro_route failed to find path")
		all_passed = false
	else:
		print("PASS: compute_macro_route found road path with %d hexes" % (macro_res.get("path", []) as Array).size())
		
	# Viable destinations
	var dests = dec.get_viable_destinations("B_SUP_1", unit_mgr, "road")
	if dests.is_empty():
		printerr("FAIL: get_viable_destinations returned empty list")
		all_passed = false
	else:
		print("PASS: get_viable_destinations returned %d destinations" % dests.size())
		
	# Route assignment
	var path_arr: Array[Vector2i] = []
	for p in (macro_res.get("path", []) as Array):
		path_arr.append(p as Vector2i)
	var assign_res = dec.assign_route("B_SUP_1", Vector2i(-25, 0), "DEPOT", Vector2i(-12, 2), path_arr, "road")
	if not bool(assign_res.get("success", false)):
		printerr("FAIL: assign_route failed: %s" % str(assign_res.get("reason", "")))
		all_passed = false
	else:
		print("PASS: assign_route assigned route successfully")
		
	var cur_route = dec.get_assigned_route("B_SUP_1")
	if cur_route.is_empty() or not bool(cur_route.get("active", false)):
		printerr("FAIL: get_assigned_route did not return active route")
		all_passed = false
	else:
		print("PASS: get_assigned_route returns active route targeting %s" % str(cur_route.get("dest_node_id", "")))
		
	# Advance supply routes
	var prev_pos: Vector2i = Vector2i(-25, 0)
	var adv_res = dec.advance_supply_routes(unit_mgr, {}, {}, {})
	var moved = adv_res
	if moved.is_empty():
		printerr("FAIL: advance_supply_routes did not move assigned convoy")
		all_passed = false
	else:
		var new_pos = (moved[0] as Dictionary).get("traversed", [])
		print("PASS: advance_supply_routes moved B_SUP_1 along route (%d hexes traversed)" % new_pos.size())
		
	# Convoy Raid handling in after_combat
	var raid_res = dec.after_combat(unit_mgr, "R_CAV_1", "B_SUP_1", {"defender_destroyed": false, "defender_casualties": 5})
	if not bool(raid_res.get("convoy_raided", false)):
		printerr("FAIL: after_combat did not detect convoy raid")
		all_passed = false
	else:
		print("PASS: after_combat correctly handled convoy raid (cargo depleted: %.0f)" % float(raid_res.get("cargo_lost", 0.0)))
		
	# Cancel route
	var cancel_res = dec.cancel_route("B_SUP_1")
	if not bool(cancel_res.get("success", false)):
		printerr("FAIL: cancel_route failed")
		all_passed = false
	else:
		print("PASS: cancel_route canceled route successfully")
		
	# TEST 4: Full Battlefield Shell Scene Load & Dual Map Lens
	print("\n--- TEST 4: Playable Battlefield Shell Scene Load & UI ---")
	var shell_scene = load("res://scenes/step2r_battlefield_shell.tscn")
	if shell_scene == null:
		printerr("FAIL: Could not load step2r_battlefield_shell.tscn")
		all_passed = false
	else:
		var shell = shell_scene.instantiate()
		root.add_child(shell)
		
		# Verify Mode Toggle Button text
		if shell._btn_map_mode == null:
			printerr("FAIL: _btn_map_mode is null")
			all_passed = false
		else:
			print("PASS: _btn_map_mode exists with text: '%s'" % shell._btn_map_mode.text)
			if not "[TAB]" in shell._btn_map_mode.text:
				printerr("FAIL: _btn_map_mode text does not contain '[TAB]'")
				all_passed = false
			else:
				print("PASS: _btn_map_mode displays '[TAB]' shortcut")
				
		# Verify Trader Panel exists and is initially hidden
		if shell._trader_panel == null:
			printerr("FAIL: _trader_panel is null")
			all_passed = false
		else:
			print("PASS: _trader_panel exists (initial visible=%s)" % str(shell._trader_panel.visible))
			if shell._trader_panel.visible:
				printerr("FAIL: _trader_panel should start hidden")
				all_passed = false
			else:
				print("PASS: _trader_panel correctly starts hidden")
				
		# Test Toggle Map Mode
		print("Testing Map Mode Toggle...")
		shell._toggle_map_mode()
		if shell._map_mode != cfg.MAP_MODE_LOGISTICS:
			printerr("FAIL: Map mode did not switch to LOGISTICS (mode=%d)" % shell._map_mode)
			all_passed = false
		else:
			print("PASS: Map mode switched to LOGISTICS, button text: '%s'" % shell._btn_map_mode.text)
			
		shell._toggle_map_mode()
		if shell._map_mode != cfg.MAP_MODE_BATTLE:
			printerr("FAIL: Map mode did not switch back to BATTLE (mode=%d)" % shell._map_mode)
			all_passed = false
		else:
			print("PASS: Map mode switched back to BATTLE, button text: '%s'" % shell._btn_map_mode.text)
			
		# Test Selecting Supply Unit -> opens Trader Panel & suppresses tactical envelopes
		print("Testing Supply Unit Selection...")
		shell.unit_manager.select_unit("B_SUP_1")
		if not shell._trader_panel.visible:
			printerr("FAIL: Selecting B_SUP_1 did not open _trader_panel")
			all_passed = false
		else:
			print("PASS: Selecting B_SUP_1 opened _trader_panel")
			
		if shell._policy_container and shell._policy_container.visible:
			printerr("FAIL: _policy_container is visible for Supply NPC")
			all_passed = false
		else:
			print("PASS: Tactical _policy_container suppressed for Supply NPC")
			
		if shell._unit_action_container and shell._unit_action_container.visible:
			printerr("FAIL: _unit_action_container is visible for Supply NPC")
			all_passed = false
		else:
			print("PASS: Tactical action commands (REST/WAIT/FORTIFY) suppressed for Supply NPC")
			
		if shell._current_envelope != null:
			printerr("FAIL: Tactical envelope calculated for Supply NPC")
			all_passed = false
		else:
			print("PASS: Tactical march envelope correctly suppressed for Supply NPC")
			
		# Test Selecting Non-Supply Combat Unit -> closes Trader Panel
		print("Testing Combat Unit Selection...")
		shell.unit_manager.select_unit("B_INF_1")
		if shell._trader_panel.visible:
			printerr("FAIL: Selecting combat unit B_INF_1 did not close _trader_panel")
			all_passed = false
		else:
			print("PASS: Selecting combat unit closed _trader_panel")
			
		# Clean up scene
		shell.queue_free()

	print("\n====================================================")
	if all_passed:
		print(">>> ALL VERIFICATION TESTS PASSED SUCCESSFULLY! <<<")
		print("====================================================")
		quit(0)
	else:
		printerr(">>> SOME VERIFICATION TESTS FAILED! <<<")
		print("====================================================")
		quit(1)
