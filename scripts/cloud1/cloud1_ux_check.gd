extends SceneTree

## Research-console UX validation (UX1-UX12, headless).
##
## Usage (Windows):
##   Godot_v4.2.2-stable_win64_console.exe --headless --path "D:\Game development\Demon slayer\StrategyGame" -s res://scripts/cloud1/cloud1_ux_check.gd
##
## Mounts the real DEV sandbox scene and drives the Tactical Research Console
## through its public API only (no direct state writes, no execution -- pure
## UI operations). Merges a "ux_gate" section into verification.json without
## touching other keys. Exit 0 = all pass.

const InspectorCls = preload("res://scripts/cloud1/cloud1_inspector.gd")

const VERIFY_PATH := "D:/Game development/.workflow/deliverables/CLOUD-GENERAL-STEP-01/verification.json"

var _gates: Dictionary = {}


func _init() -> void:
	_run()


func _record(gate: String, status: String, evidence: Dictionary) -> void:
	_gates[gate] = {"status": status, "evidence": evidence}
	print("[CLOUD1X][%s] %s" % [gate, status.to_upper()])


func _exit_code() -> int:
	for key in _gates.keys():
		if str((_gates[key] as Dictionary).get("status", "")) != "pass":
			return 1
	return 0


func _run() -> void:
	var packed: PackedScene = load("res://scenes/cloud1_battle_test.tscn")
	if packed == null:
		_record("ux1_resizable_dock", "fail", {"error": "Test scene failed to load."})
		_write_and_quit(1)
		return
	var inst: Node = packed.instantiate()
	root.add_child(inst)
	var mount: Node = inst.get_node_or_null("Cloud1LiveMount")
	var ready := false
	for _i in range(3600):
		await process_frame
		if mount != null and bool(mount.get("mount_ready")):
			ready = true
			break
	if not ready:
		_record("ux1_resizable_dock", "fail", {"error": "Mount never became ready."})
		_write_and_quit(1)
		return
	var dock: Control = mount.get("dock") as Control
	var bridge: RefCounted = mount.get("bridge") as RefCounted
	var shell: Node = mount.get("shell") as Node
	var mgr: RefCounted = bridge.get_manager()
	var w0: float = dock.call("get_dock_width")
	# UX1 -- resizable dock with drag handle, clamps, immediate effect.
	var gutter: Control = dock.get("_gutter") as Control
	var ux1_ev := {
		"gutter_present": gutter != null,
		"gutter_stops_mouse": gutter != null and gutter.mouse_filter == Control.MOUSE_FILTER_STOP,
		"resize_cursor": gutter != null and gutter.mouse_default_cursor_shape == Control.CURSOR_HSPLIT,
		"default_width": w0,
	}
	dock.call("set_dock_width", 200.0)
	var w_min: float = dock.call("get_dock_width")
	dock.call("set_dock_width", 5000.0)
	var w_max: float = dock.call("get_dock_width")
	dock.call("set_dock_width", 460.0)
	var w_set: float = dock.call("get_dock_width")
	ux1_ev["clamped_minimum"] = w_min
	ux1_ev["clamped_maximum"] = w_max
	ux1_ev["set_width"] = w_set
	var ux1_ok: bool = bool(ux1_ev["gutter_present"]) and bool(ux1_ev["gutter_stops_mouse"]) \
		and bool(ux1_ev["resize_cursor"]) and w_min >= 320.0 \
		and w_max <= 1300.0 and absf(w_set - 460.0) < 1.0
	_record("ux1_resizable_dock", "pass" if ux1_ok else "fail", ux1_ev)
	# UX2 -- tabs separated, SITUATION default, RAW parity.
	var tabs: TabContainer = dock.get("_tabs") as TabContainer
	var titles: Array = []
	for i in range(tabs.get_tab_count()):
		titles.append(tabs.get_tab_title(i))
	var sit: RichTextLabel = dock.get("_sit_view") as RichTextLabel
	var raw: TextEdit = dock.get("_raw_view") as TextEdit
	var obs: Dictionary = dock.get("_obs") as Dictionary
	var parsed: Variant = JSON.parse_string(raw.text)
	var raw_ok: bool = parsed is Dictionary and str((parsed as Dictionary).get("snapshot_id", "")) == str(obs.get("snapshot_id", ""))
	var ux2_ok: bool = titles == ["SITUATION", "RAW", "RESULT", "ROSTER SETUP"] and tabs.get_current_tab() == 0 \
		and sit.text.length() > 500 and sit.text.find("FRIENDLY") != -1 and raw_ok
	_record("ux2_tabbed_diagnostics", "pass" if ux2_ok else "fail", {
		"tab_titles": titles,
		"default_tab": (dock as Node).call("get_tab"),
		"situation_chars": sit.text.length(),
		"raw_matches_snapshot": raw_ok,
	})
	# UX3 -- builder + action bar visible without scrolling diagnostics, and the
	# retired movement-policy widget stays hidden (Step 1 action x scope x target).
	var need_visible := ["_cmd_summary", "_action_opt", "_target_type_opt",
		"_stance_opt", "_btn_preview", "_btn_execute", "_btn_cancel",
		"_btn_refresh", "_btn_reset", "_prev_summary"]
	var hidden: Array = []
	for path in need_visible:
		var c: Control = dock.get(path) as Control
		if c == null or not c.is_visible_in_tree():
			hidden.append(path)
	var policy_cell: Control = dock.get("_policy_cell") as Control
	var policy_hidden: bool = policy_cell != null and not policy_cell.is_visible_in_tree()
	var ux3_ok: bool = hidden.is_empty() and policy_hidden
	_record("ux3_builder_primary", "pass" if ux3_ok else "fail", {
		"hidden_or_missing": hidden,
		"policy_widget_hidden": policy_hidden,
		"command_summary": (dock.get("_cmd_summary") as Label).text.left(120),
	})
	# Draft a known command, then preview through the dock.
	dock.call("set_action", "ADVANCE")
	dock.call("set_scope", "ALL_COMBAT")
	dock.call("set_target", "DIRECTION", "FORWARD")
	dock.call("set_policy", "STANDARD")
	var draft_key: String = dock.call("get_draft_key")
	# UX4 -- preview summary immediately readable.
	var plan: Dictionary = dock.call("preview_command")
	var summ: Dictionary = InspectorCls.preview_summary(plan)
	var prev_label: String = (dock.get("_prev_summary") as Label).text
	var ux4_ok: bool = bool(plan.get("ok", false)) and int(summ.get("planned", 0)) > 0 \
		and prev_label.find("Resolved") != -1 and prev_label.find("Planned") != -1
	_record("ux4_preview_summary", "pass" if ux4_ok else "fail", {
		"resolved": int(summ.get("resolved", -1)),
		"planned": int(summ.get("planned", -1)),
		"moves": int(summ.get("moves", -1)),
		"failed": int(summ.get("failed", -1)),
		"builder_summary": prev_label.left(120),
	})
	# UX5 -- structured scannable rows with unit metadata.
	var res_list: ItemList = dock.get("_res_list") as ItemList
	var expected_rows: int = (plan.get("planned", []) as Array).size() + (plan.get("failed", []) as Array).size()
	var meta_ok := true
	for i in range(res_list.item_count):
		if str(res_list.get_item_metadata(i)).is_empty():
			meta_ok = false
	var ux5_ok: bool = res_list.item_count == expected_rows and expected_rows > 0 and meta_ok
	_record("ux5_result_rows", "pass" if ux5_ok else "fail", {
		"row_count": res_list.item_count,
		"expected": expected_rows,
		"every_row_has_unit_id": meta_ok,
		"sample": res_list.get_item_text(0).left(80) if res_list.item_count > 0 else "",
	})
	# UX6 -- action bar reachable at normal and narrow widths.
	var bar_ids := ["_btn_refresh", "_btn_preview", "_btn_execute", "_btn_cancel", "_btn_reset"]
	var bar_ok := true
	for b in bar_ids:
		if not ((dock.get(b) as Control).is_visible_in_tree()):
			bar_ok = false
	dock.call("set_dock_width", 340.0)
	await process_frame
	await process_frame
	var narrow_ok := true
	for b2 in bar_ids:
		if not ((dock.get(b2) as Control).is_visible_in_tree()):
			narrow_ok = false
	var bar_rect: Rect2 = (dock.get("_btn_preview") as Control).get_parent().get_global_rect()
	dock.call("set_dock_width", 560.0)
	var ux6_ok: bool = bar_ok and narrow_ok and bar_rect.size.x > 200.0
	_record("ux6_action_bar_reachable", "pass" if ux6_ok else "fail", {
		"all_visible_normal": bar_ok,
		"all_visible_narrow_340": narrow_ok,
		"bar_width": bar_rect.size.x,
	})
	# UX10 -- pure view ops preserve tactical state (before UX7 invalidates).
	var fp0: String = bridge.fingerprint()
	var sel0 := ""
	if mgr.has_method("is_unit_selected") and bool(mgr.is_unit_selected()):
		sel0 = str(mgr.get_selected_unit_id())
	dock.call("set_tab", "RAW")
	dock.call("set_tab", "RESULT")
	dock.call("set_tab", "SITUATION")
	dock.call("set_dock_width", 420.0)
	(dock as Node).call("_on_collapse_toggle")
	(dock as Node).call("_on_collapse_toggle")
	await process_frame
	var fp1: String = bridge.fingerprint()
	var sel1 := ""
	if mgr.has_method("is_unit_selected") and bool(mgr.is_unit_selected()):
		sel1 = str(mgr.get_selected_unit_id())
	var ux10_ok: bool = fp0 == fp1 and sel0 == sel1 \
		and String(dock.call("get_draft_key")) == draft_key \
		and bool(dock.call("is_preview_valid")) \
		and String((dock as Node).call("get_tab")) == "SITUATION"
	_record("ux10_state_preservation", "pass" if ux10_ok else "fail", {
		"fingerprint_stable": fp0 == fp1,
		"draft_stable": String(dock.call("get_draft_key")) == draft_key,
		"selection_stable": sel0 == sel1,
		"preview_still_valid": bool(dock.call("is_preview_valid")),
	})
	dock.call("set_dock_width", 560.0)
	# UX7 -- command change invalidates stale Execute; re-preview restores.
	var exec_btn: Button = dock.get("_btn_execute") as Button
	var enabled_after_preview: bool = not exec_btn.disabled
	dock.call("set_action", "HOLD")
	var disabled_after_change: bool = exec_btn.disabled
	var stale: bool = not bool(dock.call("is_preview_valid"))
	dock.call("set_action", "ADVANCE")
	dock.call("set_scope", "ALL_COMBAT")
	dock.call("set_target", "DIRECTION", "FORWARD")
	var plan2: Dictionary = dock.call("preview_command")
	var re_enabled: bool = not exec_btn.disabled and bool(plan2.get("ok", false))
	var ux7_ok: bool = enabled_after_preview and disabled_after_change and stale and re_enabled
	_record("ux7_execute_safety", "pass" if ux7_ok else "fail", {
		"execute_enabled_after_preview": enabled_after_preview,
		"disabled_after_command_change": disabled_after_change,
		"preview_marked_stale": stale,
		"re_preview_restores_execute": re_enabled,
	})
	# UX8 -- legacy left panel toggle (DEV sandbox only, no behavior change).
	var hud: CanvasLayer = shell.get("hud_layer") as CanvasLayer
	var left_dock: Control = hud.get_node_or_null("LeftDock") as Control
	var initial_left: bool = left_dock != null and left_dock.visible
	var orders_intact := true
	dock.call("set_legacy_visible", false)
	var hidden_ok: bool = left_dock != null and not left_dock.visible
	if left_dock != null:
		orders_intact = left_dock.get_child_count() > 0
	dock.call("set_legacy_visible", true)
	var shown_ok: bool = left_dock != null and left_dock.visible
	dock.call("set_legacy_visible", initial_left)
	var ux8_ok: bool = hidden_ok and shown_ok and orders_intact
	_record("ux8_legacy_toggle", "pass" if ux8_ok else "fail", {
		"initial_visible": initial_left,
		"hide_works": hidden_ok,
		"restore_works": shown_ok,
		"legacy_children_intact": orders_intact,
	})
	# UX9 -- map focus hides everything, restores cleanly with width kept.
	var w_before: float = dock.call("get_dock_width")
	dock.call("set_map_focus", true)
	var restore_btn: Button = dock.get("_restore_btn") as Button
	var focus_ok: bool = not dock.visible and restore_btn != null and restore_btn.visible
	var shown_during_focus: bool = restore_btn != null and restore_btn.visible
	dock.call("set_map_focus", false)
	var w_after: float = dock.call("get_dock_width")
	var ux9_ok: bool = focus_ok and dock.visible and (restore_btn == null or not restore_btn.visible) \
		and absf(w_before - w_after) < 1.0
	_record("ux9_map_focus", "pass" if ux9_ok else "fail", {
		"docked_hidden_in_focus": focus_ok,
		"restore_tab_shown": shown_during_focus,
		"width_preserved": absf(w_before - w_after) < 1.0,
		"clean_restore": dock.visible,
	})
	# UX11 -- dock interactions never leak into map input or state.
	var gutter2: Control = dock.get("_gutter") as Control
	var center: Vector2 = dock.get_global_rect().get_center()
	var excluded: bool = bool(shell.call("_is_click_over_hud", center))
	var sel2 := ""
	if mgr.has_method("is_unit_selected") and bool(mgr.is_unit_selected()):
		sel2 = str(mgr.get_selected_unit_id())
	var ux11_ok: bool = gutter2.mouse_filter == Control.MOUSE_FILTER_STOP and excluded \
		and sel2 == sel0 and bridge.fingerprint() == fp0
	_record("ux11_input_safety", "pass" if ux11_ok else "fail", {
		"gutter_consumes_mouse": gutter2.mouse_filter == Control.MOUSE_FILTER_STOP,
		"dock_clicks_excluded_from_map": excluded,
		"selection_unchanged": sel2 == sel0,
		"state_unchanged_by_ui_ops": bridge.fingerprint() == fp0,
	})
	# UX12 -- prior gates still green + all scripts parse.
	var scripts := [
		"res://scripts/cloud1/cloud1_observation.gd",
		"res://scripts/cloud1/cloud1_action_table.gd",
		"res://scripts/cloud1/cloud1_compiler.gd",
		"res://scripts/cloud1/cloud1_inspector.gd",
		"res://scripts/cloud1/cloud1_panel.gd",
		"res://scripts/cloud1/cloud1_live_bridge.gd",
		"res://scripts/cloud1/cloud1_live_executor.gd",
		"res://scripts/cloud1/cloud1_preview_overlay.gd",
		"res://scripts/cloud1/cloud1_dock.gd",
		"res://scripts/cloud1/cloud1_live_mount.gd",
		"res://scripts/cloud1/cloud1_entry.gd",
		"res://scripts/cloud1/cloud1_h_entry.gd",
		"res://scripts/cloud1/cloud1_title_entry_check.gd",
		"res://scripts/cloud1/cloud1_ux_check.gd",
		"res://scripts/ui/title_screen.gd",
	]
	var failed: Array = []
	for path in scripts:
		if load(path) == null:
			failed.append(path)
	var stored := {"backend": "", "human_gate": "", "title_gate": ""}
	if FileAccess.file_exists(VERIFY_PATH):
		var f := FileAccess.open(VERIFY_PATH, FileAccess.READ)
		if f != null:
			var doc: Variant = JSON.parse_string(f.get_as_text())
			if doc is Dictionary:
				stored["backend"] = str((doc as Dictionary).get("overall", ""))
				stored["human_gate"] = str(((doc as Dictionary).get("human_gate", {}) as Dictionary).get("overall", ""))
				stored["title_gate"] = str(((doc as Dictionary).get("title_gate", {}) as Dictionary).get("overall", ""))
	var ux12_ok: bool = failed.is_empty() and stored["backend"] == "pass" \
		and stored["human_gate"] == "pass" and stored["title_gate"] == "pass"
	_record("ux12_no_regression", "pass" if ux12_ok else "fail", {
		"scripts_parsed": scripts.size() - failed.size(),
		"scripts_total": scripts.size(),
		"stored_verdicts": stored,
		"failed": failed,
	})
	_write_and_quit(_exit_code())


func _write_and_quit(code: int) -> void:
	var doc: Dictionary = {}
	if FileAccess.file_exists(VERIFY_PATH):
		var f := FileAccess.open(VERIFY_PATH, FileAccess.READ)
		if f != null:
			var parsed: Variant = JSON.parse_string(f.get_as_text())
			if parsed is Dictionary:
				doc = parsed
	doc["ux_gate"] = {
		"console": "Tactical Research Console",
		"godot_version": Engine.get_version_info(),
		"gates": _gates,
		"overall": "pass" if _exit_code() == 0 else "fail",
	}
	var w := FileAccess.open(VERIFY_PATH, FileAccess.WRITE)
	if w != null:
		w.store_string(JSON.stringify(doc, "  "))
		print("[CLOUD1X] verification.json merged (ux_gate %s)" % ("pass" if _exit_code() == 0 else "fail"))
	print("[CLOUD1X] gates complete  exit %d" % code)
	quit(code)
