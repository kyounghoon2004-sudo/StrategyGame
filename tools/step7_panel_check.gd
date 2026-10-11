extends SceneTree

## STEP 7 panel-structure probe (§34-36, §40): the new responsive collapsible
## browser verified through the real boot path (not source inspection).
## Checks anchors, scroll, categories, footer, selection, transactional state.
## Evidence: evidence/step7_panel_50.json

const AC = preload("res://scripts/step7/step7_action_command.gd")
const OUT := "D:/Game development/Demon slayer/StrategyGame/evidence/step7_panel_50.json"

var failures: Array = []
var notes: Array = []


func _init() -> void:
	call_deferred("_run")


func _check(cond: bool, name: String) -> void:
	if cond:
		notes.append("PASS " + name)
	else:
		failures.append(name)


func _status(integration: Node, key: String) -> String:
	var labels: Dictionary = integration.get("_status_labels")
	if labels.has(key):
		return str((labels[key] as Label).text)
	return ""


func _run() -> void:
	var packed: PackedScene = load("res://scenes/step2r_battlefield_shell.tscn")
	var battle: Node = packed.instantiate()
	get_root().add_child(battle)
	for _i in range(20):
		await process_frame
	var integration: Node = battle.get_node_or_null("Step7Integration")
	for _i in range(180):
		if integration and bool(integration.get("ready_for_step7")):
			break
		await process_frame
	if integration == null or not bool(integration.get("ready_for_step7")):
		failures.append("integration not ready")
		_write()
		quit(2)
		return
	var panel: PanelContainer = integration.get("_panel")
	_check(panel != null, "DevActionPanel built")
	_check(panel.anchor_left == 1.0 and panel.anchor_right == 1.0 and panel.anchor_top == 0.0 and panel.anchor_bottom == 1.0, "panel docks full-height right edge (anchors 1,1,0,1)")
	_check(int(panel.offset_left) == -336 and int(panel.offset_right) == -8 and int(panel.offset_top) == 64 and int(panel.offset_bottom) == -8, "panel offsets pin inside viewport")
	var scroll: ScrollContainer = integration.get("_cat_scroll")
	_check(scroll != null and scroll.horizontal_scroll_mode == ScrollContainer.SCROLL_MODE_DISABLED, "single vertical ScrollContainer, no horizontal scroll")
	_check((integration.get("_browser_box") as VBoxContainer).size_flags_vertical == Control.SIZE_EXPAND_FILL, "browser region expands; footer stays fixed")
	var headers: Dictionary = integration.get("_cat_header")
	var bodies: Dictionary = integration.get("_cat_body")
	_check(headers.size() == 9 and bodies.size() == 9, "9 collapsible categories (8 groups + CUSTOM, got %d)" % headers.size())
	_check((bodies["GENERAL"] as VBoxContainer).visible, "GENERAL starts expanded")
	var collapsed_ok := true
	for g in ["CAVALRY", "SCOUT", "INFANTRY", "SPEARMAN", "ARCHER", "SIEGE", "EXACT UNIT", "CUSTOM"]:
		if (bodies[g] as VBoxContainer).visible:
			collapsed_ok = false
	_check(collapsed_ok, "all other categories start collapsed (compact footprint)")
	_check((integration.get("_preset_buttons") as Dictionary).size() == 50, "50 preset rows reachable (%d)" % (integration.get("_preset_buttons") as Dictionary).size())
	_check(str((headers["CAVALRY"] as Button).text).begins_with("▸"), "collapsed header shows ▸")
	_check(str((headers["GENERAL"] as Button).text).begins_with("▾"), "expanded header shows ▾")
	# Category toggle never triggers an action.
	_check(str(integration.get("_preview_plan_id")) == "", "no plan armed before interaction")
	integration.call("_on_category_toggle", "CAVALRY")
	_check((bodies["CAVALRY"] as VBoxContainer).visible and str((headers["CAVALRY"] as Button).text).begins_with("▾"), "CAVALRY opens independently")
	_check(str(integration.get("_preview_plan_id")) == "", "opening a category arms no plan")
	integration.call("_on_category_toggle", "INFANTRY")
	_check((bodies["CAVALRY"] as VBoxContainer).visible and (bodies["INFANTRY"] as VBoxContainer).visible, "multiple categories stay open independently")
	integration.call("_on_category_toggle", "CAVALRY")
	_check(not (bodies["CAVALRY"] as VBoxContainer).visible, "CAVALRY closes independently")
	# Row click = preview/arm only, through the shared footer.
	integration.call("_on_preset_id", "ADVANCE_CAVALRY_RIGHT")
	await process_frame
	_check(str(integration.get("_selected_preset_id")) == "ADVANCE_CAVALRY_RIGHT", "selected action identified in footer")
	_check(str(integration.get("_preview_plan_id")) != "", "row click arms preview plan (no auto-execute)")
	_check(_status(integration, "validation") == "Validation: VALID", "footer shows VALID (got '%s')" % _status(integration, "validation"))
	_check((_status(integration, "plan") as String).begins_with("Plan: READY"), "footer shows READY plan")
	var gold := (integration.get("_preset_buttons") as Dictionary)["ADVANCE_CAVALRY_RIGHT"] as Button
	_check(gold.modulate != Color.WHITE, "selected row visually highlighted")
	# Transactional state: new selection clears the old plan coherently.
	var old_plan := str(integration.get("_preview_plan_id"))
	integration.call("_on_preset_id", "HOLD_ALL")
	await process_frame
	_check(str(integration.get("_preview_plan_id")) != old_plan and _status(integration, "action") == "Action: HOLD ALL", "new selection replaces old transient plan state")
	# Template without map selection rejects with isolated guidance.
	(integration.get("unit_manager") as RefCounted).call("deselect")
	integration.call("_on_preset_id", "HOLD_SELECTED_UNIT")
	_check((_status(integration, "validation") as String).contains("select a friendly formation"), "template w/o selection: isolated INVALID guidance")
	integration.call("_on_cancel")
	_check(_status(integration, "plan") == "Plan: CANCELLED", "cancel clears armed preview")
	# Browser collapse keeps the footer usable.
	integration.call("_on_browser_toggle")
	_check(not (integration.get("_browser_box") as VBoxContainer).visible and (integration.get("_footer_box") as VBoxContainer).visible, "browser collapses to header; footer stays usable")
	integration.call("_on_browser_toggle")
	_check((integration.get("_browser_box") as VBoxContainer).visible, "browser reopens")
	var footer: VBoxContainer = integration.get("_footer_box")
	var exec_found := false
	var cancel_found := false
	for c in footer.get_children():
		if c is HBoxContainer:
			for b in (c as HBoxContainer).get_children():
				if b is Button and (b as Button).text == "[EXECUTE]":
					exec_found = true
				if b is Button and (b as Button).text == "[CANCEL]":
					cancel_found = true
	_check(exec_found and cancel_found, "one shared [EXECUTE]/[CANCEL] footer (no per-row EXEC buttons)")
	var stray_exec := false
	var indent_ok := true
	_walk_buttons(panel, func(b: Button) -> void:
		if (b as Button).text == "EXEC":
			stray_exec = true)
	for pid in (integration.get("_preset_buttons") as Dictionary).keys():
		var b: Button = (integration.get("_preset_buttons") as Dictionary)[pid]
		if not (b as Button).text.begins_with("    "):
			indent_ok = false
	_check(not stray_exec and indent_ok, "action rows are single compact buttons")
	_write()
	print("PANEL_" + ("PASS" if failures.is_empty() else "FAIL") + " (%d/%d)" % [notes.size(), notes.size() + failures.size()])
	quit(0 if failures.is_empty() else 2)


func _walk_buttons(n: Node, fn: Callable) -> void:
	if n is Button:
		fn.call(n)
	for ch in n.get_children():
		_walk_buttons(ch, fn)


func _write() -> void:
	DirAccess.make_dir_recursive_absolute((OUT as String).get_base_dir())
	var file := FileAccess.open(OUT, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify({"status": "PASS" if failures.is_empty() else "FAIL", "failures": failures, "notes": notes}, "  "))
