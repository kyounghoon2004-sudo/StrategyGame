extends SceneTree

## CLOUD STEP 1B — In-game human-gate runner (H1-H8, headless).
##
## Usage (Windows):
##   Godot_v4.2.2-stable_win64_console.exe --headless --path "D:\Game development\Demon slayer\StrategyGame" -s res://scripts/cloud1/cloud1_h_entry.gd
##
## Instances the real playable test scene (live Step2R battle + mounted
## shared interface), drives Preview/Execute against the LIVE state, and
## merges a "human_gate" section into verification.json WITHOUT touching the
## backend gates. Exit 0 = all H-gates pass.

const ObsCls = preload("res://scripts/cloud1/cloud1_observation.gd")
const TableCls = preload("res://scripts/cloud1/cloud1_action_table.gd")
const CompilerCls = preload("res://scripts/cloud1/cloud1_compiler.gd")
const InspectorCls = preload("res://scripts/cloud1/cloud1_inspector.gd")

const VERIFY_PATH := "D:/Game development/.workflow/deliverables/CLOUD-GENERAL-STEP-01/verification.json"
const BACKEND_VERIFY_PATH := "D:/Game development/.workflow/deliverables/CLOUD-GENERAL-STEP-01/verification.json"

var _gates: Dictionary = {}
var _exec_done := false
var _exec_result: Dictionary = {}
var _move_done := false
var _move_res: Dictionary = {}


func _initialize() -> void:
	_run()


func _record(gate: String, status: String, evidence: Dictionary) -> void:
	_gates[gate] = {"status": status, "evidence": evidence}
	print("[CLOUD1H][%s] %s" % [gate, status.to_upper()])


func _exit_code() -> int:
	for key in _gates.keys():
		if str((_gates[key] as Dictionary).get("status", "")) != "pass":
			return 1
	return 0


func _run() -> void:
	var packed: PackedScene = load("res://scenes/cloud1_battle_test.tscn")
	if packed == null:
		_record("h1_panel_mounts", "fail", {"error": "Test scene failed to load."})
		_write_and_quit(1)
		return
	var inst: Node = packed.instantiate()
	root.add_child(inst)
	var mount: Node = inst.get_node_or_null("Cloud1LiveMount")
	print("[CLOUD1H] inst instantiated, mount=%s" % [str(mount)])
	var ok_wait := false
	for _i in range(3600):
		await process_frame
		if mount != null and bool(mount.get("mount_ready")):
			ok_wait = true
			break
	# H1 — panel mounts without errors.
	var dock: Node = mount.get("dock") if mount != null else null
	var bridge: RefCounted = mount.get("bridge") as RefCounted if mount != null else null
	var h1_ok := ok_wait and dock != null and dock is Control and (dock as Control).is_visible_in_tree()
	_record("h1_panel_mounts", "pass" if h1_ok else "fail", {
		"mount_ready": ok_wait,
		"mount_error": str(mount.get("mount_error")) if mount != null else "no mount node",
		"dock_visible": dock != null and (dock as Control).is_visible_in_tree() if dock != null else false,
		"test_scene": "res://scenes/cloud1_battle_test.tscn",
	})
	if not h1_ok:
		_write_and_quit(1)
		return
	var shell: Node = mount.get("shell") as Node
	var mgr: RefCounted = bridge.get_manager()
	# H2 — same live state (identity + field equality, no duplicate sim).
	var same_object: bool = mgr == (shell.get("unit_manager") as RefCounted)
	var obs: Dictionary = ObsCls.build(bridge)
	var fp_pre := str((obs.get("parity", {}) as Dictionary).get("fingerprint", ""))
	var hq_pos_live := Vector2i(-999, -999)
	var hq_pos_obs := Vector2i(-999, -999)
	var live_hq: Dictionary = mgr.get_unit_by_id("B_HQ_1")
	if not live_hq.is_empty():
		hq_pos_live = Vector2i(int(live_hq.get("q", 0)), int(live_hq.get("r", 0)))
	for u_val in (obs.get("friendly_units", []) as Array):
		if str((u_val as Dictionary).get("unit_id", "")) == "B_HQ_1":
			hq_pos_obs = Vector2i(int((u_val as Dictionary).get("q", 0)), int((u_val as Dictionary).get("r", 0)))
	var turn_equal := int(obs.get("turn", -1)) == int(mgr.get_current_turn())
	var truth_match: bool = bridge.truth_version() == int((mount.get("det") as Node).get("truth").get_version())
	var h2_ok: bool = same_object and hq_pos_live == hq_pos_obs and hq_pos_live.x != -999 and turn_equal and truth_match
	_record("h2_same_live_state", "pass" if h2_ok else "fail", {
		"bridge_manager_is_shell_manager": same_object,
		"hq_live": [hq_pos_live.x, hq_pos_live.y],
		"hq_observed": [hq_pos_obs.x, hq_pos_obs.y],
		"turn_equal": turn_equal,
		"truth_version_match": truth_match,
		"friendly_count": (obs.get("friendly_units", []) as Array).size(),
		"known_enemy_count": (obs.get("known_enemy_units", []) as Array).size(),
	})
	# H3 — live preview of a generalized group command.
	var cmd_adv := TableCls.make_command("ADVANCE", TableCls.scope_all_combat(), TableCls.target_direction("FORWARD"), "STANDARD", "BALANCED")
	var plan: Dictionary = CompilerCls.plan(bridge, cmd_adv)
	var h3_ok := bool(plan.get("ok", false)) and not (plan.get("resolved_units", []) as Array).is_empty() and not (plan.get("planned", []) as Array).is_empty()
	_record("h3_live_preview", "pass" if h3_ok else "fail", {
		"command": cmd_adv,
		"snapshot_id": str(plan.get("snapshot_id", "")),
		"resolved_count": (plan.get("resolved_units", []) as Array).size(),
		"planned_count": (plan.get("planned", []) as Array).size(),
		"rejected_count": (plan.get("failed", []) as Array).size(),
		"sample_planned": (plan.get("planned", []) as Array).slice(0, 3),
	})
	# H4a — live execution through the authoritative path (HOLD, synchronous rows).
	var executor: Node = mount.get("executor") as Node
	executor.execution_finished.connect(_on_exec_finished)
	var cmd_hold := TableCls.make_command("HOLD", TableCls.scope_class("INFANTRY"))
	var acc: Dictionary = executor.execute(cmd_hold)
	_exec_done = false
	for _i in range(1800):
		await process_frame
		if _exec_done:
			break
	var acted := 0
	for u_val in mgr.get_all_units_including_garrisoned():
		if u_val is Dictionary and str((u_val as Dictionary).get("class", "")) == "infantry" and str((u_val as Dictionary).get("faction", "")) == "blue" and bool((u_val as Dictionary).get("action_ended", false)):
			acted += 1
	var h4a_ok := bool(acc.get("accepted", false)) and _exec_done and str(_exec_result.get("execution_status", "")) in ["EXECUTED", "PARTIAL"] and acted > 0
	# H4b — one animated live MOVE through shell.execute_step7_move.
	var mover_id := ""
	for u_val in (obs.get("friendly_units", []) as Array):
		var ucls := str((u_val as Dictionary).get("class", "")).to_lower()
		if ucls in ["cavalry", "scout", "infantry", "spearman"] and str((u_val as Dictionary).get("status", "")) == "ready":
			mover_id = str((u_val as Dictionary).get("unit_id", ""))
			break
	var move_ev := {"moved": false}
	if not mover_id.is_empty():
		var cmd_single_adv := TableCls.make_command("ADVANCE", TableCls.scope_units([mover_id]), TableCls.target_direction("FORWARD"))
		var splan: Dictionary = CompilerCls.plan(bridge, cmd_single_adv)
		var dest := Vector2i(-999, -999)
		var mm := "auto"
		for p_val in (splan.get("planned", []) as Array):
			if str((p_val as Dictionary).get("unit_id", "")) == mover_id and str((p_val as Dictionary).get("action", "")) == "MOVE":
				var t: Array = (p_val as Dictionary).get("to", [])
				dest = Vector2i(int(t[0]), int(t[1]))
				mm = str((p_val as Dictionary).get("march_mode", "auto"))
		if dest.x != -999:
			var before: Dictionary = mgr.get_unit_by_id(mover_id)
			var bq := int(before.get("q", 0))
			var br := int(before.get("r", 0))
			_move_done = false
			shell.call("execute_step7_move", mover_id, dest, mm, Callable(self, "_on_test_move"))
			for _i in range(1800):
				await process_frame
				if _move_done:
					break
			var after: Dictionary = mgr.get_unit_by_id(mover_id)
			move_ev = {"moved": _move_done and bool(_move_res.get("success", false)) and (int(after.get("q", -999)) != bq or int(after.get("r", -999)) != br), "from": [bq, br], "to": [int(after.get("q", -999)), int(after.get("r", -999))]}
	_record("h4_live_execution", "pass" if (h4a_ok and bool(move_ev.get("moved", false))) else "fail", {
		"hold_command": cmd_hold,
		"hold_accepted": bool(acc.get("accepted", false)),
		"hold_status": str(_exec_result.get("execution_status", "?")),
		"hold_executed": (_exec_result.get("executed_units", []) as Array).size(),
		"infantry_acted_after_hold": acted,
		"unit_move": move_ev,
		"mover_id": mover_id,
	})
	# H5 — observation refreshes to the new state.
	var obs2: Dictionary = ObsCls.build(bridge)
	var fp_post := str((obs2.get("parity", {}) as Dictionary).get("fingerprint", ""))
	var h5_ok := fp_pre != fp_post and int(obs2.get("turn", -1)) == int(mgr.get_current_turn())
	_record("h5_observation_refresh", "pass" if h5_ok else "fail", {
		"fingerprint_before": fp_pre,
		"fingerprint_after": fp_post,
		"changed": fp_pre != fp_post,
	})
	# H6 — SELECTED scope on a battlefield-selected unit.
	var sel_ok := false
	var sel_ev := {}
	if not mover_id.is_empty() and bool(mgr.select_unit(mover_id)):
		var cmd_wd := TableCls.make_command("WITHDRAW", TableCls.scope_selected(), TableCls.target_zone("HQ"))
		var splan2: Dictionary = CompilerCls.plan(bridge, cmd_wd, str(mgr.get_selected_unit_id()))
		sel_ok = (splan2.get("resolved_units", []) as Array) == [mover_id] and not (splan2.get("planned", []) as Array).is_empty()
		sel_ev = {"selected": mover_id, "resolved": splan2.get("resolved_units", []), "planned_count": (splan2.get("planned", []) as Array).size()}
		mgr.deselect()
	_record("h6_selection", "pass" if sel_ok else "fail", sel_ev)
	# H7 — input coexistence via the shell's own HUD-exclusion rule.
	var h7_ok := false
	var h7_ev := {}
	if shell.has_method("_is_click_over_hud") and dock is Control:
		var dock_center: Vector2 = (dock as Control).get_global_rect().get_center()
		var over_dock: bool = shell.call("_is_click_over_hud", dock_center)
		var open_points: Array = []
		for px in [200.0, 450.0, 700.0, 950.0]:
			for py in [400.0, 550.0, 700.0]:
				if not bool(shell.call("_is_click_over_hud", Vector2(px, py))):
					open_points.append([px, py])
		h7_ok = over_dock and not open_points.is_empty()
		h7_ev = {"click_over_dock_excluded": over_dock, "open_map_points": open_points.slice(0, 4)}
	_record("h7_input_coexistence", "pass" if h7_ok else "fail", h7_ev)
	# H8 — regression: backend files parse, sim getters intact, backend gates green.
	var h8_ok := _h8_regression()
	_write_and_quit(_exit_code())


func _on_exec_finished(result: Dictionary) -> void:
	_exec_result = result
	_exec_done = true


func _on_test_move(res: Dictionary) -> void:
	_move_res = res
	_move_done = true


func _h8_regression() -> bool:
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
	]
	var failed: Array = []
	for path in scripts:
		if load(path) == null:
			failed.append(path)
	var sim_script: Script = load("res://scripts/sim/sim_controller.gd")
	var probe: RefCounted = sim_script.new()
	var getters_ok := probe.has_method("map_bounds") and probe.has_method("truth_version") and probe.has_method("truth_fingerprint") and probe.has_method("get_projector") and probe.has_method("get_step6")
	var backend_ok := false
	if FileAccess.file_exists(BACKEND_VERIFY_PATH):
		var f := FileAccess.open(BACKEND_VERIFY_PATH, FileAccess.READ)
		if f != null:
			var doc: Variant = JSON.parse_string(f.get_as_text())
			if doc is Dictionary:
				backend_ok = str((doc as Dictionary).get("overall", "")) == "pass"
	var ok := failed.is_empty() and getters_ok and backend_ok
	_record("h8_regression", "pass" if ok else "fail", {
		"cloud1_scripts_parsed": scripts.size() - failed.size(),
		"cloud1_scripts_total": scripts.size(),
		"sim_additive_getters_present": getters_ok,
		"backend_verification_still_pass": backend_ok,
		"failed": failed,
	})
	return ok


func _write_and_quit(code: int) -> void:
	var doc: Dictionary = {}
	if FileAccess.file_exists(VERIFY_PATH):
		var f := FileAccess.open(VERIFY_PATH, FileAccess.READ)
		if f != null:
			var parsed: Variant = JSON.parse_string(f.get_as_text())
			if parsed is Dictionary:
				doc = parsed
	doc["human_gate"] = {
		"test_scene": "res://scenes/cloud1_battle_test.tscn",
		"godot_version": Engine.get_version_info(),
		"gates": _gates,
		"overall": "pass" if _exit_code() == 0 else "fail",
	}
	DirAccess.make_dir_recursive_absolute("D:/Game development/.workflow/deliverables/CLOUD-GENERAL-STEP-01")
	var w := FileAccess.open(VERIFY_PATH, FileAccess.WRITE)
	if w != null:
		w.store_string(JSON.stringify(doc, "  "))
		print("[CLOUD1H] verification.json merged (human_gate %s)" % ("pass" if _exit_code() == 0 else "fail"))
	print("[CLOUD1H] gates complete — exit %d" % code)
	quit(code)
