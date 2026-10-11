extends SceneTree

## Title-screen DEV entry check (G1-G7, headless).
##
## Usage (Windows):
##   Godot_v4.2.2-stable_win64_console.exe --headless --path "D:\Game development\Demon slayer\StrategyGame" -s res://scripts/cloud1/cloud1_title_entry_check.gd
##
## Boots the real title screen, proves the production menu is intact, clicks
## the DEV entry, proves the Step 1 sandbox loads and mounts, then merges a
## "title_gate" section into verification.json without touching other keys.
## Exit 0 = all pass. Adds no Cloud/Qwen/RL code (scene loads only).

const TITLE_SCENE := "res://scenes/title_screen.tscn"
const SANDBOX_SCENE := "res://scenes/cloud1_battle_test.tscn"
const VERIFY_PATH := "D:/Game development/.workflow/deliverables/CLOUD-GENERAL-STEP-01/verification.json"

var _gates: Dictionary = {}


func _init() -> void:
	_run()


func _record(gate: String, status: String, evidence: Dictionary) -> void:
	_gates[gate] = {"status": status, "evidence": evidence}
	print("[CLOUD1T][%s] %s" % [gate, status.to_upper()])


func _exit_code() -> int:
	for key in _gates.keys():
		if str((_gates[key] as Dictionary).get("status", "")) != "pass":
			return 1
	return 0


func _run() -> void:
	var packed: PackedScene = load(TITLE_SCENE)
	if packed == null:
		_record("g1_title_boots", "fail", {"error": "title scene failed to load"})
		_write_and_quit(1)
		return
	var title: Node = packed.instantiate()
	root.add_child(title)
	for _i in range(60):
		await process_frame
	# G1 -- title boots normally.
	var g1_ok := is_instance_valid(title) and title.is_inside_tree()
	_record("g1_title_boots", "pass" if g1_ok else "fail", {
		"scene": TITLE_SCENE,
		"in_tree": title.is_inside_tree() if is_instance_valid(title) else false,
	})
	if not g1_ok:
		_write_and_quit(1)
		return
	# G2 -- production buttons intact and wired.
	var expected := {
		"BtnCampaign": "campaign",
		"BtnBattle": "battle",
		"BtnSLM": "slm",
		"BtnQuit": "quit",
	}
	var btn_ev := {}
	var g2_ok := true
	for bname in expected.keys():
		var b: Node = title.get_node_or_null("VBox/Buttons/%s" % bname)
		var present := b != null and b is Button
		var wired := present and (b as Button).pressed.get_connections().size() > 0
		var label := str((b as Button).text) if present else ""
		btn_ev[bname] = {"present": present, "wired": wired, "text": label}
		if not (present and wired):
			g2_ok = false
	var src := _read_text("res://scripts/ui/title_screen.gd")
	var has_campaign_target := src.find("res://scenes/main.tscn") != -1
	var has_battle_target := src.find("res://scenes/step2r_battlefield_shell.tscn") != -1
	if not (has_campaign_target and has_battle_target):
		g2_ok = false
	btn_ev["script_targets"] = {"main_tscn": has_campaign_target, "step2r_tscn": has_battle_target}
	_record("g2_production_menu_intact", "pass" if g2_ok else "fail", btn_ev)
	# G3 -- DEV entry visible and visually distinct.
	var dev: Node = title.get_node_or_null("VBox/Buttons/BtnCloud1Sandbox")
	var dev_ok := dev != null and dev is Button and (dev as Button).is_visible_in_tree()
	var dev_text := str((dev as Button).text) if dev != null else ""
	var distinct := false
	var dev_ev := {"present": dev != null, "text": dev_text}
	if dev_ok and dev_text == "DEV: Cloud General Sandbox":
		distinct = (dev as Button).has_theme_color_override("font_color") and (dev as Button).has_theme_stylebox_override("normal")
		var sec: Node = title.get_node_or_null("VBox/Buttons/DevSectionLabel")
		dev_ev["section_label"] = sec != null and str((sec as Label).text) == "DEV / RESEARCH"
		dev_ev["distinct_style"] = distinct
		dev_ev["tooltip"] = str((dev as Button).tooltip_text)
		dev_ok = dev_ok and distinct and bool(dev_ev["section_label"])
	else:
		dev_ok = false
	_record("g3_dev_entry_visible", "pass" if dev_ok else "fail", dev_ev)
	if not dev_ok:
		_write_and_quit(1)
		return
	# G4 -- clicking DEV loads the sandbox scene.
	(dev as Button).pressed.emit()
	var loaded := false
	for _i in range(120):
		await process_frame
		if current_scene != null and str(current_scene.scene_file_path) == SANDBOX_SCENE:
			loaded = true
			break
	_record("g4_dev_loads_sandbox", "pass" if loaded else "fail", {
		"target": SANDBOX_SCENE,
		"current_scene": str(current_scene.scene_file_path) if current_scene != null else "<none>",
	})
	if not loaded:
		_write_and_quit(1)
		return
	# G5 -- shared interface mounts after the DEV launch.
	var mount: Node = current_scene.get_node_or_null("Cloud1LiveMount")
	var dock_visible := false
	var mount_ready := false
	for _i in range(3600):
		await process_frame
		if mount != null and bool(mount.get("mount_ready")):
			mount_ready = true
			break
	if mount_ready:
		var dock: Node = mount.get("dock") as Node
		dock_visible = dock != null and (dock as Control).is_visible_in_tree()
	_record("g5_shared_interface_mounts", "pass" if (mount_ready and dock_visible) else "fail", {
		"mount_ready": mount_ready,
		"mount_error": str(mount.get("mount_error")) if mount != null else "no mount node",
		"dock_visible": dock_visible,
	})
	# G6 -- backend regression (parse + last backend verdict still pass).
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
		"res://scripts/ui/title_screen.gd",
	]
	var failed: Array = []
	for path in scripts:
		if load(path) == null:
			failed.append(path)
	var backend_ok := false
	if FileAccess.file_exists(VERIFY_PATH):
		var f := FileAccess.open(VERIFY_PATH, FileAccess.READ)
		if f != null:
			var doc: Variant = JSON.parse_string(f.get_as_text())
			if doc is Dictionary:
				backend_ok = str((doc as Dictionary).get("overall", "")) == "pass"
	var g6_ok := failed.is_empty() and backend_ok
	_record("g6_no_backend_regression", "pass" if g6_ok else "fail", {
		"scripts_parsed": scripts.size() - failed.size(),
		"scripts_total": scripts.size(),
		"backend_verification_still_pass": backend_ok,
		"failed": failed,
	})
	# G7 -- no Cloud/Qwen/RL code in the DEV addition; title .tscn untouched.
	var block := _marked_block(src)
	var banned := ["http", "ollama", "openai", "anthropic", "gemini", "qwen", "api_key", "websocket", "reinforcement", "preload(", "load("]
	var hits: Array = []
	for token in banned:
		if block.find(token) != -1:
			hits.append(token)
	var tscn_text := _read_text("res://scenes/title_screen.tscn")
	var tscn_untouched := tscn_text.find("BtnCloud1Sandbox") == -1 and tscn_text.find("cloud1") == -1
	var g7_ok := block.length() > 0 and hits.is_empty() and tscn_untouched
	_record("g7_no_cloud_code_added", "pass" if g7_ok else "fail", {
		"dev_block_chars": block.length(),
		"banned_tokens_found": hits,
		"title_tscn_untouched": tscn_untouched,
		"mechanism": "get_tree().change_scene_to_file (existing navigation)",
	})
	_write_and_quit(_exit_code())


func _read_text(res_path: String) -> String:
	var f := FileAccess.open(res_path, FileAccess.READ)
	if f == null:
		return ""
	return f.get_as_text()


func _marked_block(src: String) -> String:
	var a := src.find("# CLOUD1-DEV-ENTRY-BEGIN")
	var b := src.find("# CLOUD1-DEV-ENTRY-END")
	if a == -1 or b == -1 or b <= a:
		return ""
	return src.substr(a, b - a)


func _write_and_quit(code: int) -> void:
	var doc: Dictionary = {}
	if FileAccess.file_exists(VERIFY_PATH):
		var f := FileAccess.open(VERIFY_PATH, FileAccess.READ)
		if f != null:
			var parsed: Variant = JSON.parse_string(f.get_as_text())
			if parsed is Dictionary:
				doc = parsed
	doc["title_gate"] = {
		"dev_entry": "DEV: Cloud General Sandbox",
		"target_scene": SANDBOX_SCENE,
		"godot_version": Engine.get_version_info(),
		"gates": _gates,
		"overall": "pass" if _exit_code() == 0 else "fail",
	}
	var w := FileAccess.open(VERIFY_PATH, FileAccess.WRITE)
	if w != null:
		w.store_string(JSON.stringify(doc, "  "))
		print("[CLOUD1T] verification.json merged (title_gate %s)" % ("pass" if _exit_code() == 0 else "fail"))
	print("[CLOUD1T] gates complete  exit %d" % code)
	quit(code)
