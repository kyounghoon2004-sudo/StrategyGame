extends SceneTree

## Merged-right-dock + live-selection correction probe.
## Drives the REAL in-engine click path (shell._handle_hex_click with exact
## world coordinates) for cases A-E/H, design-space rect proof for F/G.
##
## Explicit limit: the OS-mouse -> world transform
## (camera.get_global_mouse_position) cannot run in a 64px dummy headless
## viewport (warp_mouse is a no-op there), so real pushed-button picking is
## not possible headless. Everything downstream of the world-space click —
## stronghold gate, unit pick, select_unit, canonical poll, evaluator,
## window, preview, canonical execution — runs for real here. The bypassed
## transform is untouched engine code (Camera2D), not Advisor code.

const OUT := "D:/Game development/Demon slayer/StrategyGame/evidence/step7_advisor_leftdock.json"
const HexUtils = preload("res://scripts/core/hex_utils.gd")

var failures: Array = []
var passed := 0


func _check(cond: bool, label: String) -> void:
	if cond:
		passed += 1
	else:
		failures.append(label)


func _init() -> void:
	call_deferred("_run")


func _click_unit(shell: Node, um, unit_id: String) -> void:
	var u: Dictionary = (um as Object).call("get_unit_by_id", unit_id)
	var coord := Vector2i(int(u.get("q", 0)), int(u.get("r", 0)))
	var wpos: Vector2 = HexUtils.hex_to_pixel(coord.x, coord.y)
	_shell.call("_handle_hex_click", coord, wpos)


var _shell: Node = null


func _run() -> void:
	var packed: PackedScene = load("res://scenes/step2r_battlefield_shell.tscn")
	_shell = packed.instantiate()
	get_root().add_child(_shell)
	for _i in range(20):
		await process_frame
	var integration: Node = _shell.get_node_or_null("Step7Integration")
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

	var um = _shell.get("unit_manager")
	var adapter: Node = integration.get("_advisor_adapter")
	var awin = integration.get("_advisor_window")
	var atoggle = integration.get("_advisor_toggle_btn")

	# --- Boot: advisor open on the right, orders on the left ---------------
	_check((awin as Control).visible, "advisor section starts open")
	_check((atoggle as Button).visible, "advisor toggle visible")
	_check(bool(awin.get("embedded")), "advisor embedded in right dock")
	var orders_w = integration.get("_orders_panel")
	_check(bool(orders_w.get("embedded")), "orders embedded in left dock")
	_check(not ((awin as Control).get_parent() == (orders_w as Control).get_parent()), "advisor+orders in separate docks")
	var dock = integration.get("_right_dock")
	var ldock = integration.get("_left_dock")
	_check(int((dock as Control).anchor_left) == 1 and int((dock as Control).anchor_right) == 1, "dock anchored RIGHT")
	_check(int((dock as Control).offset_left) == -344 and int((dock as Control).offset_right) == -8, "dock x offsets -344..-8")
	_check(int((ldock as Control).anchor_left) == 0 and int((ldock as Control).anchor_right) == 0, "orders dock anchored LEFT")
	_check(int((ldock as Control).offset_left) == 8 and int((ldock as Control).offset_right) == 344, "orders dock x offsets 8..344")
	_check(int((ldock as Control).offset_top) == 92, "orders dock clears top-left UI")
	_check(int((atoggle as Button).offset_left) == 24 and int((atoggle as Button).offset_top) == 56, "advisor toggle top-left")

	# --- A. open advisor: click cavalry -> six slots ------------------------
	# (Advisor starts open; select-while-open path.)
	_click_unit(_shell, um, "B_CAV_2")
	for _i in range(8):
		await process_frame
	_check(str((um as Object).call("get_selected_unit_id")) == "B_CAV_2", "A: real click handler selects B_CAV_2")
	_check(str(adapter.call("current_unit_id")) == "B_CAV_2", "A: open advisor shows B_CAV_2")
	_check((awin.get("_card_btns") as Dictionary).size() == 6, "A: six slots")
	_check(str((awin as Object).get("_sub_lbl").text).find("B_CAV_2") >= 0, "A: identity visible")
	_check(str((awin as Object).get("_scope_lbl").text).find("작전 구역") >= 0, "A: cluster visible")

	# --- A2. close, select another, reopen -> pulls current -----------------
	integration.call("_on_advisor_toggle")
	for _i in range(3):
		await process_frame
	_check(not (awin as Control).visible, "A2: advisor closes")
	_click_unit(_shell, um, "B_CAV_3")
	for _i in range(5):
		await process_frame
	_check(str(adapter.call("current_unit_id")).is_empty(), "A2: close clears advisor state")
	integration.call("_on_advisor_toggle")
	for _i in range(5):
		await process_frame
	_check((awin as Control).visible, "A2: advisor reopens")
	_check(str(adapter.call("current_unit_id")) == "B_CAV_3", "A2: open-after-select pulls B_CAV_3")
	_check((awin.get("_card_btns") as Dictionary).size() == 6, "A2: six slots")

	# --- C. cavalry A -> cavalry B: no stale package -----------------------
	_click_unit(_shell, um, "B_CAV_4")
	for _i in range(8):
		await process_frame
	var pkg_c: Dictionary = adapter.call("current_package")
	_check(str(pkg_c.get("unit_id", "")) == "B_CAV_4", "C: package tracks B_CAV_4 (no stale A)")
	_check(int(adapter.call("picked_slot")) == -1, "C: no stale pick")

	# --- Card select -> preview -> switch replaces -------------------------
	var slot_a := -1
	for o_val in (pkg_c.get("options", []) as Array):
		var o: Dictionary = o_val
		if str(o.get("status", "")) != "UNAVAILABLE" and o.has("destination"):
			slot_a = int(o.get("slot", 0))
			break
	var overlay = integration.get("overlay")
	if slot_a > 0:
		adapter.call("select_option", slot_a)
		_check(not (overlay.get("routes") as Array).is_empty(), "preview appears on card select")
		var routes_a: Array = (overlay.get("routes") as Array).duplicate(true)
		var slot_b := -1
		for o_val in (pkg_c.get("options", []) as Array):
			var o2: Dictionary = o_val
			var s := int(o2.get("slot", 0))
			if s != slot_a and str(o2.get("status", "")) != "UNAVAILABLE" and o2.has("destination"):
				slot_b = s
				break
		if slot_b > 0:
			adapter.call("select_option", slot_b)
			_check(str((overlay.get("routes") as Array)) != str(routes_a), "switching cards replaces preview")
		adapter.call("cancel")
		_check((overlay.get("routes") as Array).is_empty(), "cancel clears preview")
	else:
		_check(false, "no available option on B_CAV_4 to preview")

	# --- H. execute -> canonical move -> refresh ---------------------------
	var exec_ok := false
	if slot_a > 0:
		adapter.call("select_option", slot_a)
		var opt: Dictionary = adapter.call("_option_for_slot", slot_a)
		var dest: Dictionary = opt.get("destination", {})
		var want := Vector2i(int(dest.get("q", -9999)), int(dest.get("r", -9999)))
		adapter.call("execute_selected")
		var svc = integration.get("action_service")
		var truth = integration.get("truth")
		for _i in range(900):
			if not bool(svc.call("is_executing")):
				break
			await process_frame
		var after: Dictionary = truth.call("get_unit", "B_CAV_4")
		exec_ok = Vector2i(int(after.get("q", -9998)), int(after.get("r", -9998))) == want
	_check(exec_ok, "H: execute moves B_CAV_4 via canonical path")
	for _i in range(5):
		await process_frame
	_check(int(adapter.call("picked_slot")) == -1, "H: post-move refresh clears pick")

	# --- D. cavalry -> infantry --------------------------------------------
	_click_unit(_shell, um, "B_INF_1")
	for _i in range(8):
		await process_frame
	_check(str((awin as Object).get("_brief_lbl").text).find("준비되지 않았습니다") >= 0, "D: unsupported-class message")
	_check((awin.get("_card_btns") as Dictionary).is_empty(), "D: zero cavalry cards")

	# --- E. deselect -> neutral ----------------------------------------------
	(um as Object).call("deselect")
	for _i in range(8):
		await process_frame
	_check(str((awin as Object).get("_brief_lbl").text).find("선택하시면") >= 0, "E: neutral on deselect")

	# --- F+G. design-space proof at 1920x1080 -------------------------------
	# Orders dock owns the left strip (clearing top-left debug/toggle and
	# the bottom-left unit card); advisor dock owns the right strip above
	# the NEXT/hint strip; gameplay popups sharing the strip open ABOVE it.
	var ldock_r := Rect2(8, 92, 344 - 8, (1080 - 300) - 92)
	var unitcard_r := Rect2(24, 1080 - 295, 400, 235)
	var debug_r := Rect2(24, 16, 356, 32)
	_check(not ldock_r.intersects(unitcard_r), "F: orders dock clears unit card")
	_check(not ldock_r.intersects(debug_r), "F: orders dock clears debug panel")
	_check(not ldock_r.has_point(Vector2(960, 540)), "F: orders dock leaves center free")
	var dock_r := Rect2(1920 - 344, 64, 336, 1080 - 64 - 120)
	_check(int((dock as Control).offset_top) == 64, "F: dock clears top HUD")
	_check(int((dock as Control).offset_bottom) == -120, "F: dock reserves NEXT/hint strip")
	_check(not dock_r.has_point(Vector2(960, 540)), "G: battlefield center outside dock")
	_check((dock as Control).mouse_filter == Control.MOUSE_FILTER_STOP, "G: dock consumes only its own rect")
	_check(dock_r.get_area() < 1920.0 * 1080.0 * 0.20, "G: no full-width invisible catcher")
	_check((atoggle as Button).get_global_rect().get_area() < 200.0 * 100.0, "G: toggle is a small affordance")
	var hud: CanvasLayer = _shell.get_node_or_null("CanvasLayer")
	var dock_idx := (dock as Control).get_index()
	_check(dock_idx > (hud.get_node_or_null("BottomHintPanel") as Control).get_index(), "G: dock above hint bar (footer clickable)")
	var popup_missing := ""
	var popup_covered := ""
	for pn in ["NextTurnButton", "RouteCardPanel", "AttackCardPanel", "StrongholdPanel",
		"EnemyIntelPanel", "TraderRoutePanel", "ReconReportPanel", "CombatLogPanel",
		"PhaseBannerPanel", "TurnPanel"]:
		var p := hud.get_node_or_null(pn) as Control
		if p == null:
			popup_missing += pn + " "
		elif not (p.get_index() > dock_idx):
			popup_covered += pn + " "
	_check(popup_missing.is_empty(), "G: all popup panels exist" + (" (missing: " + popup_missing + ")" if not popup_missing.is_empty() else ""))
	_check(popup_covered.is_empty(), "G: popups open above the dock" + (" (covered: " + popup_covered + ")" if not popup_covered.is_empty() else ""))

	_write()
	quit(0 if failures.is_empty() else 1)


func _write() -> void:
	var f := FileAccess.open(OUT, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({"passed": passed, "failures": failures}, "  "))
		f.close()
	print("[LeftDockProbe] passed=%d failures=%d" % [passed, failures.size()])
	for x in failures:
		print("[LeftDockProbe] FAIL: %s" % str(x))
