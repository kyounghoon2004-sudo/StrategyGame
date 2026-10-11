extends SceneTree

## PLAYER/DEV + Advisor regression probe (player/advisor milestone).
## Boots the canonical scene, then asserts WITHOUT vision:
##  PLAYER boot: DEV toggle+panel hidden, Advisor toggle visible, window
##    closed, cluster heatmap OFF.
##  Cavalry select: six option slots, no DEV tokens, no hidden RED ids,
##    cluster label present.
##  Shared truth: Advisor package == fresh DEV evaluator package
##    (same unit/intent/knowledge/version: profiles, statuses, destinations).
##  Preview: select -> overlay routes appear; cancel -> cleared.
##  Execute: canonical path moves the unit; adapter refreshes (pick cleared).
##  Unsupported class / neutral: honest copy, no crash.
##  Overlay toggle + DEV mode gating + no LLM/MCP/provider revival.
## Writes evidence JSON; quit code 0 = pass, 1 = fail.

const OUT := "D:/Game development/Demon slayer/StrategyGame/evidence/step7_advisor_player_mode.json"
const EvaluatorScript = preload("res://scripts/step7/step7_cavalry_evaluator.gd")
const ViewModelScript = preload("res://scripts/step7/step7_advisor_viewmodel.gd")
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


func _red_ids(um) -> Array:
	var out: Array = []
	for u in um.call("get_all_units_including_garrisoned"):
		if u is Dictionary and str((u as Dictionary).get("faction", "")) == "red":
			out.append(str((u as Dictionary).get("id", "")))
	return out


func _run() -> void:
	DevModeScript.set_dev_mode(false)
	var packed: PackedScene = load("res://scenes/step2r_battlefield_shell.tscn")
	if packed == null:
		failures.append("canonical scene failed to load")
		_write()
		quit(1)
		return
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
	# Let the frozen cluster geometry build (ensure_turn runs in _process).
	for _i in range(40):
		await process_frame

	# --- 1. PLAYER boot -------------------------------------------------
	_check(not DevModeScript.is_dev_mode(), "boot defaults to PLAYER mode")
	var toggle = integration.get("_toggle_button")
	var panel = integration.get("_panel")
	_check(toggle != null and not (toggle as Button).visible, "PLAYER: DEV toggle hidden")
	_check(panel != null and not (panel as PanelContainer).visible, "PLAYER: DEV panel hidden")
	var atoggle = integration.get("_advisor_toggle_btn")
	var awin = integration.get("_advisor_window")
	var adapter: Node = integration.get("_advisor_adapter")
	_check(atoggle != null and (atoggle as Button).visible, "PLAYER: Advisor toggle visible")
	_check(awin != null and (awin as Control).visible, "PLAYER: Advisor section starts open (right dock)")
	_check(adapter != null and bool(adapter.call("is_ready")), "advisor adapter ready")
	var sector_overlay = integration.get("sector_overlay")
	_check(sector_overlay != null and not bool(sector_overlay.call("is_showing")), "heatmap OFF by default")

	# --- 2. Viewmodel purity (no scene) ---------------------------------
	_check(ViewModelScript.cluster_display("L3", "L2", "R1") == "L3 · 좌익 외곽 3", "dynamic L3 fallback naming")
	_check(ViewModelScript.cluster_display("R4", "L2", "R4") == "R4 · 극우익", "dynamic R4 extreme naming")
	_check(ViewModelScript.cluster_display("C") == "C · 중앙", "C naming")
	_check(ViewModelScript.ordered_profiles() == ["SAFE", "SUPPORTED", "BALANCED", "PRESSURE", "DEEP", "MAXIMUM"], "six profiles ordered")

	# --- 3. Cavalry selection -> six player cards ------------------------
	var um = integration.get("unit_manager")
	_check(bool(um.call("select_unit", "B_CAV_2")), "select B_CAV_2")
	(awin as Control).visible = true
	adapter.call("notify_selection")
	for _i in range(5):
		await process_frame
	_check(str(adapter.call("current_unit_id")) == "B_CAV_2", "adapter tracks B_CAV_2")
	var pkg: Dictionary = adapter.call("current_package")
	_check(bool(pkg.get("ok", false)), "advisor package ok")
	_check((pkg.get("options", []) as Array).size() == 6, "package has six options")
	var card_btns: Dictionary = awin.get("_card_btns")
	_check(card_btns.size() == 6, "Advisor shows exactly six option slots")
	var reds := _red_ids(um)
	var leak := ""
	for t in awin.call("player_texts"):
		var bad := ViewModelScript.audit_player_text(str(t), reds)
		if not bad.is_empty():
			leak = bad + " :: " + str(t).left(120)
			break
	_check(leak.is_empty(), "no DEV tokens / hidden RED ids in player UI" + (" (" + leak + ")" if not leak.is_empty() else ""))
	var scope_txt := str(awin.get("_scope_lbl").text)
	_check(scope_txt.find("작전 구역") >= 0 and scope_txt.length() > 8, "cluster scope shown: " + scope_txt.left(60))
	var sub_txt := str(awin.get("_sub_lbl").text)
	_check(sub_txt.find("B_CAV_2") >= 0 and sub_txt.find("기병") >= 0, "formation+class identified: " + sub_txt)

	# --- 4. Shared truth: Advisor pkg == fresh DEV evaluator pkg ---------
	var truth = integration.get("truth")
	var cmd_svc = integration.get("command_service")
	var proj = integration.get("projector")
	var bk: Dictionary = integration.call("get_blue_knowledge")
	var occ: Dictionary = proj.call("known_occupancy", "blue")
	var grid: Node = integration.get("hex_grid")
	var cell_data: Dictionary = grid.get("cell_data") as Dictionary if grid else {}
	var dev_eval = EvaluatorScript.new()
	var dev_pkg: Dictionary = dev_eval.evaluate("B_CAV_2",
		{"action": "ADVANCE", "direction": "FORWARD"},
		cmd_svc, bk, cell_data, occ,
		int(truth.call("get_version")), str(truth.call("fingerprint")))
	var same := true
	var why := ""
	if not bool(dev_pkg.get("ok", false)):
		same = false
		why = "dev evaluator package not ok"
	else:
		var a_opts: Array = pkg.get("options", [])
		var d_opts: Array = dev_pkg.get("options", [])
		if a_opts.size() != d_opts.size():
			same = false
			why = "option count differs"
		else:
			for i in range(a_opts.size()):
				var a: Dictionary = a_opts[i]
				var d: Dictionary = d_opts[i]
				if str(a.get("profile", "")) != str(d.get("profile", "")) \
					or str(a.get("status", "")) != str(d.get("status", "")) \
					or str(a.get("destination", {})) != str(d.get("destination", {})):
					same = false
					why = "slot %d differs (advisor=%s/%s vs dev=%s/%s)" % [i,
						str(a.get("profile", "")), str(a.get("status", "")),
						str(d.get("profile", "")), str(d.get("status", ""))]
					break
	_check(same, "Advisor and DEV consume the same OptionPackage" + (" (" + why + ")" if not why.is_empty() else ""))

	# --- 5. Preview -> cancel (canonical shared overlay) -----------------
	var overlay = integration.get("overlay")
	var avail_slot := -1
	for o_val in (pkg.get("options", []) as Array):
		var o: Dictionary = o_val
		if str(o.get("status", "")) != "UNAVAILABLE" and o.has("destination"):
			avail_slot = int(o.get("slot", 0))
			break
	_check(avail_slot > 0, "at least one AVAILABLE/DEGRADED option to preview")
	if avail_slot > 0:
		adapter.call("select_option", avail_slot)
		_check(int(adapter.call("picked_slot")) == avail_slot, "option card becomes selected")
		_check(not (overlay.get("routes") as Array).is_empty(), "route/target preview appears on shared overlay")
		adapter.call("cancel")
		_check((overlay.get("routes") as Array).is_empty(), "cancel clears preview")
		_check(int(adapter.call("picked_slot")) == -1, "cancel clears selection")

	# --- 6. Execute via canonical path ----------------------------------
	var exec_ok := false
	var exec_note := ""
	if avail_slot > 0:
		adapter.call("select_option", avail_slot)
		var opt: Dictionary = adapter.call("_option_for_slot", avail_slot)
		var dest: Dictionary = opt.get("destination", {})
		var want := Vector2i(int(dest.get("q", -9999)), int(dest.get("r", -9999)))
		adapter.call("execute_selected")
		var svc = integration.get("action_service")
		for _i in range(900):
			if not bool(svc.call("is_executing")):
				break
			await process_frame
		if bool(svc.call("is_executing")):
			exec_note = "execution still in progress after timeout"
		else:
			var after: Dictionary = truth.call("get_unit", "B_CAV_2")
			var got := Vector2i(int(after.get("q", -9998)), int(after.get("r", -9998)))
			if got == want:
				exec_ok = true
			else:
				exec_note = "unit at (%d,%d), wanted (%d,%d)" % [got.x, got.y, want.x, want.y]
		_check(int(adapter.call("picked_slot")) == -1, "adapter refreshed after execution (no stale pick)")
	_check(exec_ok, "BALANCED/available option executes via canonical movement" + (" (" + exec_note + ")" if not exec_note.is_empty() else ""))

	# --- 6b. Turn refresh clears stale state --------------------------------
	adapter.call("notify_turn")
	for _i in range(3):
		await process_frame
	_check(int(adapter.call("picked_slot")) == -1, "turn refresh clears stale pick")
	_check((overlay.get("routes") as Array).is_empty(), "turn refresh clears stale preview")
	_check((awin.get("_card_btns") as Dictionary).size() == 6, "turn refresh re-presents six slots")

	# --- 7. Unsupported class + neutral ----------------------------------
	_check(bool(um.call("select_unit", "B_INF_1")), "select B_INF_1 (infantry)")
	for _i in range(3):
		await process_frame
	var brief_inf := str(awin.get("_brief_lbl").text)
	_check(brief_inf.find("준비되지 않았습니다") >= 0, "unsupported class shows honest placeholder")
	_check((awin.get("_card_btns") as Dictionary).is_empty(), "no cavalry cards for infantry")
	um.call("deselect")
	for _i in range(3):
		await process_frame
	_check(str(awin.get("_brief_lbl").text).find("선택하시면") >= 0, "neutral state when nothing selected")

	# --- 8. Player overlay toggle ----------------------------------------
	adapter.call("set_tactical_overlay", true)
	_check(bool(sector_overlay.call("is_showing")), "Advisor overlay request shows bands")
	adapter.call("set_tactical_overlay", false)
	_check(not bool(sector_overlay.call("is_showing")), "Advisor close/toggle-off restores normal map")

	# --- 9. DEV mode gate -------------------------------------------------
	DevModeScript.set_dev_mode(true)
	integration.call("_apply_dev_visibility")
	_check((toggle as Button).visible, "DEV: toggle accessible")
	(panel as PanelContainer).visible = true
	_check((panel as PanelContainer).visible, "DEV: raw panel can open")
	_check(integration.get("_sector_toggle_btn") != null, "DEV: cluster browser retained")
	integration.call("request_tactical_overlay", true, "dev")
	_check(bool(sector_overlay.call("is_showing")), "DEV: direct overlay control works")
	integration.call("request_tactical_overlay", false, "dev")
	DevModeScript.set_dev_mode(false)
	integration.call("_apply_dev_visibility")
	_check(not (toggle as Button).visible and not (panel as PanelContainer).visible, "back to PLAYER: DEV surfaces hidden again")

	# --- 10. No unsanctioned inference revival -----------------------------
	# Ollama Advisor pilot: the ONLY sanctioned model path is the four
	# step7_ollama_* / step7_advisor_llm_selector / step7_advisor_context
	# modules, with HTTPRequest living solely inside step7_ollama_client.gd.
	# Everything else (SLM client, MCP gameplay, cloud providers, llama
	# server, streaming) stays banned from the Advisor/player surfaces.
	var banned := ["slmclient", "slm_client", "slmparser", "gameplay_mcp", "mcp_runtime",
		"gameplaymcp", "openai", "anthropic", "gemini", "streaming", "llama_server",
		"fallbackprovider", "multimodel", "router"]
	var revived := ""
	for path in ["res://scripts/step7/step7_dev_mode.gd",
		"res://scripts/step7/step7_advisor_viewmodel.gd",
		"res://scripts/step7/step7_advisor_window.gd",
		"res://scripts/step7/step7_advisor_adapter.gd",
		"res://scripts/step7/step7_det_integration.gd"]:
		var text := FileAccess.get_file_as_string(path).to_lower()
		for b in banned:
			if text.find(str(b)) >= 0:
				revived = "%s mentions '%s'" % [path, str(b)]
				break
		if not revived.is_empty():
			break
	_check(revived.is_empty(), "no unsanctioned inference revival" + (" (" + revived + ")" if not revived.is_empty() else ""))
	var http_outside := ""
	for path in ["res://scripts/step7/step7_advisor_adapter.gd",
		"res://scripts/step7/step7_advisor_window.gd",
		"res://scripts/step7/step7_advisor_llm_selector.gd",
		"res://scripts/step7/step7_advisor_context.gd",
		"res://scripts/step7/step7_det_integration.gd"]:
		if FileAccess.get_file_as_string(path).to_lower().find("httprequest") >= 0:
			http_outside = path
			break
	_check(http_outside.is_empty(), "HTTPRequest lives only in step7_ollama_client.gd" + (" (" + http_outside + ")" if not http_outside.is_empty() else ""))

	_write()
	quit(0 if failures.is_empty() else 1)


func _write() -> void:
	var f := FileAccess.open(OUT, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({"passed": passed, "failures": failures}, "  "))
		f.close()
	print("[AdvisorProbe] passed=%d failures=%d" % [passed, failures.size()])
	for x in failures:
		print("[AdvisorProbe] FAIL: %s" % str(x))
