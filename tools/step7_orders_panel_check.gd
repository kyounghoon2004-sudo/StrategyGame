extends SceneTree

## Orders-panel (game-like DEV browser successor) regression probe.
## PLAYER boot visibility, 50 Korean presets, preview/execute/cancel via
## the canonical path, template gating, DEV mutual-exclusivity, text audit.

const OUT := "D:/Game development/Demon slayer/StrategyGame/evidence/step7_orders_panel.json"
const OrdersPanelScript = preload("res://scripts/step7/step7_orders_panel.gd")
const DevModeScript = preload("res://scripts/step7/step7_dev_mode.gd")

var failures: Array = []
var passed := 0


func _check(cond: bool, label: String) -> void:
	if cond:
		passed += 1
	else:
		failures.append(label)


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	DevModeScript.set_dev_mode(false)
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
		failures.append("Step7Integration not ready")
		_write()
		quit(1)
		return
	for _i in range(40):
		await process_frame

	var orders = integration.get("_orders_panel")
	var toggle = integration.get("_toggle_button")
	var panel = integration.get("_panel")
	var um = integration.get("unit_manager")
	var svc = integration.get("action_service")
	var truth = integration.get("truth")
	var overlay = integration.get("overlay")

	# --- 1. PLAYER boot --------------------------------------------------
	_check(orders != null and (orders as Control).visible, "PLAYER: orders panel visible")
	_check(toggle != null and not (toggle as Button).visible, "PLAYER: DEV toggle hidden")
	_check(panel != null and not (panel as PanelContainer).visible, "PLAYER: DEV panel hidden")
	_check((orders.get("_preset_btns") as Dictionary).size() == 50, "50 order buttons (got %d)" % (orders.get("_preset_btns") as Dictionary).size())

	# --- 2. Text audit ----------------------------------------------------
	var leak := ""
	for t in orders.call("player_texts"):
		var bad := OrdersPanelScript.audit_player_text(str(t))
		if not bad.is_empty():
			leak = bad
			break
	_check(leak.is_empty(), "no DEV tokens in orders UI" + (" (" + leak + ")" if not leak.is_empty() else ""))

	# --- 3. Arm whole-army order -> preview -------------------------------
	orders.call("arm_preset", "ADVANCE_ALL_FORWARD")
	_check(bool(orders.call("has_plan")), "ADVANCE_ALL_FORWARD arms a plan")
	_check(not (overlay.get("routes") as Array).is_empty(), "army order draws preview routes")
	_check(str((orders.get("_state_label") as Label).text).find("실행 가능") >= 0, "READY shown in Korean")
	# Dock-hide cancels the armed plan (DEV round-trip while armed).
	DevModeScript.set_dev_mode(true)
	integration.call("_apply_dev_visibility")
	integration.call("_on_dev_panel_toggle")
	_check(not (integration.get("_right_dock") as Control).visible, "DEV: dock hides for raw panel")
	_check(not (integration.get("_left_dock") as Control).visible, "DEV: orders dock hides too")
	_check(not bool(orders.call("has_plan")), "DEV: dock hide cancels armed plan")
	integration.call("_on_dev_panel_toggle")
	_check((integration.get("_right_dock") as Control).visible, "DEV: dock returns")
	DevModeScript.set_dev_mode(false)
	integration.call("_apply_dev_visibility")
	var v0: int = truth.call("get_version")
	orders.call("cancel_current")
	_check(not bool(orders.call("has_plan")), "cancel disarms")
	_check(int(truth.call("get_version")) == v0, "cancel mutates nothing")

	# --- 4. Template without selection -> Korean hint ----------------------
	(um as Object).call("deselect")
	for _i in range(3):
		await process_frame
	(orders.get("_q_edit") as LineEdit).text = "0"
	(orders.get("_r_edit") as LineEdit).text = "0"
	orders.call("arm_preset", "MOVE_SELECTED_UNIT_TO_HEX")
	_check(not bool(orders.call("has_plan")), "no plan without selection")
	_check(str((orders.get("_state_label") as Label).text).find("선택하십시오") >= 0, "selection hint in Korean")

	# --- 5. Template with selection -> single-unit execute -----------------
	(um as Object).call("select_unit", "B_INF_1")
	var cmd_svc = integration.get("command_service")
	var before: Dictionary = truth.call("get_unit", "B_INF_1")
	var origin := Vector2i(int(before.get("q", 0)), int(before.get("r", 0)))
	var area: Dictionary = cmd_svc.call("reachable_area", "B_INF_1", "blue", "auto")
	var dest := Vector2i(-9999, -9999)
	for e in area.get("reachable", []):
		if e is Dictionary:
			var cell := Vector2i(int((e as Dictionary).get("q", -9999)), int((e as Dictionary).get("r", -9999)))
			if cell != origin:
				dest = cell
				break
	_check(dest.x != -9999, "reachable destination exists for B_INF_1")
	(orders.get("_q_edit") as LineEdit).text = str(dest.x)
	(orders.get("_r_edit") as LineEdit).text = str(dest.y)
	orders.call("arm_preset", "MOVE_SELECTED_UNIT_TO_HEX")
	_check(bool(orders.call("has_plan")), "exact-unit order arms a plan")
	orders.call("_on_execute_btn")
	for _i in range(900):
		if not bool(svc.call("is_executing")):
			break
		await process_frame
	var after: Dictionary = truth.call("get_unit", "B_INF_1")
	_check(Vector2i(int(after.get("q", -9998)), int(after.get("r", -9998))) == dest, "B_INF_1 moved via orders panel")

	# --- 6. HOLD_ALL executes + bumps version ------------------------------
	var v1: int = truth.call("get_version")
	orders.call("arm_preset", "HOLD_ALL")
	_check(bool(orders.call("has_plan")), "HOLD_ALL arms a plan")
	orders.call("_on_execute_btn")
	for _i in range(900):
		if not bool(svc.call("is_executing")):
			break
		await process_frame
	# Version bumps once per executed formation (37 HOLDs -> +37), so assert growth.
	_check(int(truth.call("get_version")) > v1, "execute advances state version")

	# --- 7. DEV mutual-exclusivity (dock level) ------------------------------
	DevModeScript.set_dev_mode(true)
	integration.call("_apply_dev_visibility")
	_check((toggle as Button).visible, "DEV: toggle accessible")
	_check((integration.get("_right_dock") as Control).visible, "DEV: advisor dock stays until dev panel opens")
	_check((integration.get("_left_dock") as Control).visible, "DEV: orders dock stays until dev panel opens")
	integration.call("_on_dev_panel_toggle")
	_check((panel as PanelContainer).visible, "DEV: raw panel opens")
	_check(not (integration.get("_right_dock") as Control).visible, "DEV: advisor dock hides")
	_check(not (integration.get("_left_dock") as Control).visible, "DEV: orders dock hides")
	integration.call("_on_dev_panel_toggle")
	_check(not (panel as PanelContainer).visible, "DEV: raw panel closes")
	_check((integration.get("_right_dock") as Control).visible, "DEV: advisor dock returns")
	_check((integration.get("_left_dock") as Control).visible, "DEV: orders dock returns")
	DevModeScript.set_dev_mode(false)
	integration.call("_apply_dev_visibility")
	_check(not (toggle as Button).visible and (orders as Control).visible, "back to PLAYER layout")

	# --- 8. No LLM/MCP/provider revival --------------------------------------
	var banned := ["slmclient", "slm_client", "gameplay_mcp", "mcp_runtime",
		"httpclient", "httprequest", "ollama", "openai", "llama_server"]
	var text := FileAccess.get_file_as_string("res://scripts/step7/step7_orders_panel.gd").to_lower()
	var revived := ""
	for b in banned:
		if text.find(str(b)) >= 0:
			revived = str(b)
			break
	_check(revived.is_empty(), "no LLM/MCP/provider revival" + (" (" + revived + ")" if not revived.is_empty() else ""))

	_write()
	quit(0 if failures.is_empty() else 1)


func _write() -> void:
	var f := FileAccess.open(OUT, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({"passed": passed, "failures": failures}, "  "))
		f.close()
	print("[OrdersProbe] passed=%d failures=%d" % [passed, failures.size()])
	for x in failures:
		print("[OrdersProbe] FAIL: %s" % str(x))
