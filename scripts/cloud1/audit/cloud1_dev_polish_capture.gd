extends SceneTree

## CLOUD1 DEV — STEP 1 VISUAL POLISH probe + capture (WINDOWED, real renderer).
##
## Boots the REAL DEV sandbox scene and verifies the presentation pass:
##   1. legacy left "작전 명령" panel hidden (reversible through the API)
##   2. chess-style board orientation: BLUE on the player-facing near side,
##      pointer -> hex mapping and world-space text still correct
##   3. console slimmer + translucent surfaces
##   4. console still functional: tabs / preview / execute / exact units /
##      roster reset, route overlay drawn on the rotated board
##
## Run (windowed, NOT --headless):
##   Godot_v4.2.2-stable_win64_console.exe --path "<proj>" \
##     -s res://scripts/cloud1/audit/cloud1_dev_polish_capture.gd

const WorldBoundaryCls = preload("res://scripts/step2r/step2r_world_boundary.gd")
const HexUtils = preload("res://scripts/core/hex_utils.gd")
const PresentationOrientationCls = preload("res://scripts/core/presentation_orientation.gd")
const SandboxRulesCls = preload("res://scripts/core/sandbox_rules.gd")
const Step2RUnitRendererCls = preload("res://scripts/step2r/step2r_unit_renderer.gd")

const OUT_DIR := "D:/Game development/Demon slayer/StrategyGame/evidence/cloud1_audit"
const OUT_JSON := OUT_DIR + "/cloud1_polish_visual.json"
const YAW_EPS := 0.0001

var _phase := 0
var _frame := 0
var _shots: Array = []
var _checks: Dictionary = {}
var _notes: Array = []
var _mount: Node = null
var _shell: Node = null
var _dock: Variant = null
var _bridge: Variant = null
var _executor: Variant = null
var _cam: Camera2D = null
var _failed: Array = []


func _initialize() -> void:
	change_scene_to_file("res://scenes/cloud1_battle_test.tscn")


func _record(key: String, ok: bool, evidence: Dictionary = {}) -> void:
	_checks[key] = {"ok": ok, "evidence": evidence}
	if not ok:
		_failed.append(key)
	print("[Polish][%s] %s %s" % ["PASS" if ok else "FAIL", key, JSON.stringify(evidence)])


func _process(_delta: float) -> bool:
	_frame += 1
	if _frame > 12000:
		_notes.append("global frame budget exceeded")
		_finish(1)
		return true
	match _phase:
		0:
			return _wait_for_mount()
		1:
			return _phase_default()
		2:
			return _phase_exact_units_execute()
		3:
			return _phase_roster_reset()
		5:
			return _phase_roster_restore()
		6:
			return _phase_closeups()
		4:
			return _phase_legacy_reversibility()
	return false


func _wait_for_mount() -> bool:
	var cs: Node = current_scene
	if cs == null or cs.get_node_or_null("Cloud1LiveMount") == null:
		if _frame > 1200:
			_notes.append("scene never mounted")
			_finish(1)
			return true
		return false
	_mount = cs.get_node_or_null("Cloud1LiveMount")
	if not bool(_mount.get("mount_ready")):
		if _frame > 6000:
			_notes.append("mount never ready")
			_finish(1)
			return true
		return false
	_shell = _mount.get("shell") as Node
	_dock = _mount.get("dock")
	_bridge = _mount.get("bridge")
	_executor = _mount.get("executor")
	_cam = _shell.get_node_or_null("Camera2D") as Camera2D
	_phase = 1
	_frame = 0
	return false


# --- PHASE 1: default entry presentation -------------------------------------

func _phase_default() -> bool:
	if _frame < 60:
		return false
	var hud: CanvasLayer = _shell.get("hud_layer") as CanvasLayer
	var left_dock: Control = hud.get_node_or_null("LeftDock") as Control
	var yaw: float = float(PresentationOrientationCls.yaw_rad)
	_record("sandbox_rules_active", bool(SandboxRulesCls.is_active()), {})
	_record("camera_rotated", _cam != null and absf(_cam.rotation - yaw) < YAW_EPS,
		{"camera_rotation": _cam.rotation if _cam != null else null, "expected": yaw})
	_record("legacy_left_panel_hidden", left_dock != null and not left_dock.visible,
		{"left_dock_present": left_dock != null, "left_dock_visible": left_dock.visible if left_dock != null else null,
		"dock_reports_legacy_visible": bool(_dock.call("is_legacy_visible"))})
	# The step7 advisor dock sits under this console; it must be hidden or the
	# console's translucency would show a dark slab instead of the battlefield.
	var advisor_dock: Control = hud.get_node_or_null("RightDock") as Control
	_record("advisor_dock_cleared_for_translucency", advisor_dock != null and not advisor_dock.visible,
		{"right_dock_present": advisor_dock != null, "right_dock_visible": advisor_dock.visible if advisor_dock != null else null})
	# Slimmer console: default width reduced (was 560) and capped at 52% of view.
	var w: float = float(_dock.call("get_dock_width"))
	var vw: float = float(root.get_visible_rect().size.x)
	_record("console_slimmer", w <= 480.0 and w >= 320.0 and (w / vw) <= 0.30,
		{"width": w, "viewport_w": vw, "fraction": snappedf(w / vw, 0.001), "previous_default": 560.0})
	# Translucent surfaces (alpha < 1.0, still dark enough to keep text legible).
	var panel_sb: StyleBox = (_dock as Control).get_theme_stylebox("panel")
	var tabs: TabContainer = _dock.get("_tabs") as TabContainer
	var tab_sb: StyleBox = tabs.get_theme_stylebox("panel")
	var bg_a: float = (panel_sb as StyleBoxFlat).bg_color.a if panel_sb is StyleBoxFlat else 1.0
	var tab_a: float = (tab_sb as StyleBoxFlat).bg_color.a if tab_sb is StyleBoxFlat else 1.0
	_record("console_translucent", bg_a <= 0.62 and tab_a <= 0.46 and bg_a > 0.4 and tab_a > 0.3,
		{"panel_alpha": bg_a, "tab_alpha": tab_a, "previous_panel_alpha": 0.96,
		"effective_tab_area_alpha": 1.0 - (1.0 - bg_a) * (1.0 - tab_a)})
	_check_board_composition()
	_check_camera_frame()
	_check_world_text_upright()
	_check_unit_visuals()
	_check_pointer_mapping()
	_save("polish_1_default_board")
	# Draft the whole-army advance and preview it (route overlay on rotated board).
	_dock.call("set_action", "ADVANCE")
	_dock.call("set_scope", "ALL_COMBAT")
	_dock.call("set_target", "DIRECTION", "FORWARD")
	var plan: Dictionary = _dock.call("preview_command")
	_record("preview_full_army", bool(plan.get("ok", false)) and (plan.get("planned", []) as Array).size() > 0,
		{"planned": (plan.get("planned", []) as Array).size(), "failed": (plan.get("failed", []) as Array).size(),
		"preview_valid": bool(_dock.call("is_preview_valid"))})
	_phase = 2
	_frame = 0
	return false


func _check_camera_frame() -> void:
	# Sandbox opening frame: board centre, wide chess-like view, yaw applied.
	var cam_target: Vector2 = _cam.get("target_position")
	_record("camera_frame_sandbox", absf(cam_target.x) < 1.0 and absf(cam_target.y) < 1.0
		and absf(_cam.zoom.x - 0.72) < 0.01 and not bool(_cam.ignore_rotation),
		{"target": [cam_target.x, cam_target.y], "zoom": _cam.zoom.x,
		"ignore_rotation": _cam.ignore_rotation, "expected_zoom": 0.72})


func _check_board_composition() -> void:
	# Chess-like composition: BLUE must sit closer to the player (bottom) than RED.
	var mgr: Variant = _bridge.get_manager()
	var canvas_xf: Transform2D = _shell.get_viewport().get_canvas_transform()
	var vp_size: Vector2 = root.get_visible_rect().size
	var blue_sum := 0.0
	var red_sum := 0.0
	var blue_n := 0
	var red_n := 0
	var off_screen: Array = []
	var blue_cells: Array = []
	var red_cells: Array = []
	for u_val in mgr.get_all_units_including_garrisoned():
		var u: Dictionary = u_val
		var cell := Vector2i(int(u.get("q", 0)), int(u.get("r", 0)))
		var sp: Vector2 = canvas_xf * HexUtils.hex_to_pixel(cell.x, cell.y)
		var inside: bool = sp.x >= 0.0 and sp.y >= 0.0 and sp.x <= vp_size.x and sp.y <= vp_size.y
		if not inside:
			off_screen.append({"id": str(u.get("id", "")), "screen": [snappedf(sp.x, 1.0), snappedf(sp.y, 1.0)]})
		if str(u.get("faction", "")) == "blue":
			blue_sum += sp.y
			blue_n += 1
			blue_cells.append(str(u.get("id", "")))
		else:
			red_sum += sp.y
			red_n += 1
			red_cells.append(str(u.get("id", "")))
	var blue_mean: float = blue_sum / maxf(1.0, float(blue_n))
	var red_mean: float = red_sum / maxf(1.0, float(red_n))
	_record("blue_is_near_side", blue_n > 0 and red_n > 0 and blue_mean > red_mean + 100.0,
		{"blue_units": blue_n, "red_units": red_n,
		"blue_mean_screen_y": snappedf(blue_mean, 1.0), "red_mean_screen_y": snappedf(red_mean, 1.0),
		"viewport_h": vp_size.y, "off_screen_units": off_screen})


func _check_world_text_upright() -> void:
	# Unit count labels must stay horizontal and keep sitting under the icon.
	var yaw: float = float(PresentationOrientationCls.yaw_rad)
	var rr: Node = _shell.get("unit_renderer") as Node
	var checked := 0
	var bad: Array = []
	var sample: Dictionary = {}
	for child in rr.get_children():
		var lab: Label = child.get_node_or_null("CountLabel") as Label
		if lab == null:
			continue
		checked += 1
		var unit_center: Vector2 = (child as Node2D).get_global_transform_with_canvas().origin
		var lab_center: Vector2 = lab.get_global_transform_with_canvas() * lab.pivot_offset
		var off: Vector2 = lab_center - unit_center
		var rot_ok: bool = absf(lab.rotation - yaw) < YAW_EPS
		var under_ok: bool = off.y > 2.0 and off.y < 40.0 and absf(off.x) <= 2.0
		if not (rot_ok and under_ok and lab.text != ""):
			bad.append({"unit": str(child.name), "label_rotation": lab.rotation, "screen_offset": [off.x, off.y], "text": lab.text})
		elif sample.is_empty():
			sample = {"unit": str(child.name), "text": lab.text, "label_rotation": lab.rotation,
				"screen_offset": [snappedf(off.x, 0.01), snappedf(off.y, 0.01)], "zoom": _cam.zoom.x}
	_record("unit_labels_upright", checked > 0 and bad.is_empty(),
		{"checked": checked, "bad": bad, "sample": sample})


func _check_pointer_mapping() -> void:
	# Click path: screen point -> camera.get_global_mouse_position() -> axial.
	# Round-trips must land on the SAME hex for the whole army after rotation.
	var canvas_xf: Transform2D = _shell.get_viewport().get_canvas_transform()
	var inv: Transform2D = canvas_xf.affine_inverse()
	var mgr: Variant = _bridge.get_manager()
	var mismatches: Array = []
	var tested := 0
	for u_val in mgr.get_all_units_including_garrisoned():
		var u: Dictionary = u_val
		var cell := Vector2i(int(u.get("q", 0)), int(u.get("r", 0)))
		var world: Vector2 = HexUtils.hex_to_pixel(cell.x, cell.y)
		var screen: Vector2 = canvas_xf * world
		var back: Vector2 = inv * screen
		var axial: Vector2i = WorldBoundaryCls.world_to_axial(back)
		tested += 1
		if axial != cell:
			mismatches.append({"id": str(u.get("id", "")), "expected": [cell.x, cell.y], "got": [axial.x, axial.y]})
	_record("pointer_to_hex_mapping", tested > 0 and mismatches.is_empty(),
		{"tested": tested, "mismatches": mismatches})


# --- PHASE 2: exact units + execute ------------------------------------------

func _phase_exact_units_execute() -> bool:
	if _frame == 8:
		_save("polish_2_route_overlay")
	if _frame < 12:
		return false
	if _frame == 12:
		_dock.call("set_scope", "EXACT UNITS", "B_INF_1,B_CAV_1")
		var checked: Array = _dock.get("_checked_unit_ids")
		_record("exact_units_selector", checked == ["B_CAV_1", "B_INF_1"] or checked == ["B_INF_1", "B_CAV_1"],
			{"checked_ids": checked})
		_dock.call("set_action", "ADVANCE")
		_dock.call("set_target", "DIRECTION", "FORWARD")
		var plan: Dictionary = _dock.call("preview_command")
		var n_planned: int = (plan.get("planned", []) as Array).size()
		var n_failed: int = (plan.get("failed", []) as Array).size()
		_record("preview_exact_units", bool(plan.get("ok", false)) and n_planned + n_failed == 2 and n_planned >= 1,
			{"planned": n_planned, "failed": n_failed, "resolved": (plan.get("resolved_units", []) as Array)})
		var res: Dictionary = _dock.call("execute_command")
		_record("execute_accepted", bool(res.get("accepted", false)),
			{"accepted": bool(res.get("accepted", false)), "planned_count": int(res.get("planned_count", 0))})
		return false
	if _frame == 14:
		_save("polish_3_execute_started")
		return false
	# Wait for the sequential executor to finish (unit-by-unit animation).
	if _executor != null and bool(_executor.call("is_busy")) and _frame < 8000:
		return false
	if _frame < 8300:
		return false
	var rows: Array = _dock.call("get_result_unit_ids")
	_record("execution_finished_with_rows", rows.size() > 0, {"result_rows": rows})
	_save("polish_4_after_execute")
	_phase = 3
	_frame = 0
	return false


# --- PHASE 3: roster reset keeps presentation intact -------------------------

func _phase_roster_reset() -> bool:
	if _frame == 4:
		_dock.call("set_tab", "ROSTER")
		return false
	if _frame == 12:
		_save("polish_5_roster_tab")
		return false
	if _frame < 16:
		return false
	if _frame == 16:
		_dock.call("_apply_roster_preset", {"infantry": 4, "archer": 1, "spearman": 1, "cavalry": 1, "scout": 1, "hq": 1},
			{"infantry": 4, "archer": 1, "spearman": 1, "cavalry": 1, "scout": 1, "hq": 1})
		_dock.call("_on_apply_roster_rebuild")
		return false
	if _frame < 40:
		return false
	var mgr: Variant = _bridge.get_manager()
	var blue := 0
	var red := 0
	for u_val in mgr.get_all_units():
		match str((u_val as Dictionary).get("faction", "")):
			"blue":
				blue += 1
			"red":
				red += 1
	var hud: CanvasLayer = _shell.get("hud_layer") as CanvasLayer
	var left_dock: Control = hud.get_node_or_null("LeftDock") as Control
	_record("roster_reset_after_rebuild", blue == 9 and red == 9,
		{"blue": blue, "red": red, "expected_each": 9})
	_record("legacy_stays_hidden_after_rebuild", left_dock != null and not left_dock.visible, {})
	_check_world_text_upright()
	_save("polish_6_roster_reset")
	# Restore the 10v10 default roster so the sandbox is left as entered.
	_dock.call("_apply_roster_preset", SandboxRulesCls.default_roster(), SandboxRulesCls.default_roster())
	_dock.call("_on_apply_roster_rebuild")
	_phase = 5
	_frame = 0
	return false


# --- PHASE 5: roster restore + framing stability ------------------------------

func _phase_roster_restore() -> bool:
	if _frame == 0:
		# The live executor legitimately moved the camera while presenting the
		# executed moves; re-centre to the sandbox opening frame before the
		# composition check so it measures the documented presentation, not the
		# post-execution follow-cam.
		if _cam.has_method("focus_on"):
			_cam.call("focus_on", HexUtils.hex_to_pixel(0, 0), true)
		if _cam.has_method("set_zoom_level"):
			_cam.call("set_zoom_level", 0.72, true)
		return false
	if _frame < 60:
		return false
	var mgr: Variant = _bridge.get_manager()
	var blue := 0
	var red := 0
	for u_val in mgr.get_all_units():
		match str((u_val as Dictionary).get("faction", "")):
			"blue":
				blue += 1
			"red":
				red += 1
	_record("roster_restored_default", blue == 10 and red == 10, {"blue": blue, "red": red})
	_check_camera_frame()
	_check_board_composition()
	_save("polish_7_roster_restored")
	_phase = 6
	_frame = 0
	return false


# --- PHASE 6: close-up captures + unit-visual orientation proofs --------------

func _phase_closeups() -> bool:
	if _frame == 2:
		_focus_group("blue", 1.60)
		return false
	if _frame == 40:
		_save("polish_10_closeup_blue")
		_check_unit_visuals()
		_focus_group("red", 1.60)
		return false
	if _frame == 80:
		_save("polish_11_closeup_red")
		_phase = 4
		_frame = 0
		return false
	return false


func _focus_group(faction: String, zoom_val: float) -> void:
	var mgr: Variant = _bridge.get_manager()
	var sum := Vector2.ZERO
	var n := 0
	for u_val in mgr.get_all_units_including_garrisoned():
		var u: Dictionary = u_val
		if str(u.get("faction", "")) != faction:
			continue
		sum += HexUtils.hex_to_pixel(int(u.get("q", 0)), int(u.get("r", 0)))
		n += 1
	if n > 0 and _cam.has_method("focus_on"):
		_cam.call("focus_on", sum / float(n), true)
	if _cam.has_method("set_zoom_level"):
		_cam.call("set_zoom_level", zoom_val, true)


func _check_unit_visuals() -> void:
	# STEP C: every unit VISUAL subnode must be upright on screen (canvas yaw
	# cancelled at the node) and keep its original screen offset from the unit
	# centre, while the CONTAINER keeps its canonical hex position and no rotation.
	var yaw: float = float(PresentationOrientationCls.yaw_rad)
	var rr: Node = _shell.get("unit_renderer") as Node
	var z: float = _cam.zoom.x
	var wants: Dictionary = {
		"FactionRing": Vector2(0, 5), "GroundShadow": Vector2(0, 6),
		"CharacterSprite": Vector2(0, 1), "CharacterOutline": Vector2(0, 1),
		"OverheadBadge": Step2RUnitRendererCls.calculate_badge_offset(z),
		"HPBar": Vector2(0, -26), "CountLabel": Vector2(0, 19),
	}
	var checked := 0
	var bad: Array = []
	var sample: Dictionary = {}
	for child in rr.get_children():
		if not (child is Node2D) or not (child as Node).has_node("OverheadBadge"):
			continue
		var node2 := child as Node2D
		checked += 1
		var q := int(node2.get_meta("q", 0))
		var r := int(node2.get_meta("r", 0))
		var pos_ok: bool = node2.position.distance_to(HexUtils.hex_to_pixel(q, r)) < 0.01
		var container_rot_ok: bool = absf(node2.rotation) < 0.0001
		if not (pos_ok and container_rot_ok):
			bad.append({"unit": str(node2.name), "container_pos": [node2.position.x, node2.position.y],
				"container_rot": node2.rotation, "hex": [q, r]})
			continue
		var unit_screen: Vector2 = node2.get_global_transform_with_canvas().origin
		for cname in wants.keys():
			var c: CanvasItem = node2.get_node_or_null(cname) as CanvasItem
			if c == null:
				bad.append({"unit": str(node2.name), "missing": cname})
				continue
			var xf: Transform2D = c.get_global_transform_with_canvas()
			var anchor: Vector2 = xf.origin
			if c is Control:
				anchor = xf * (c as Control).pivot_offset
			var off: Vector2 = anchor - unit_screen
			var want: Vector2 = (wants[cname] as Vector2) * z
			var screen_rot: float = xf.get_rotation()
			var upright: bool = absf(screen_rot) < 0.001
			var offset_ok: bool = absf(off.x - want.x) <= 1.5 and absf(off.y - want.y) <= 1.5
			var inherited: bool = absf(c.rotation - yaw) < 0.001 if not (c is Control) else absf((c as Control).rotation - yaw) < 0.001
			if not (upright and offset_ok and inherited):
				bad.append({"unit": str(node2.name), "node": cname, "screen_rotation_rad": screen_rot,
					"local_rotation": c.rotation, "screen_offset": [snappedf(off.x, 0.01), snappedf(off.y, 0.01)],
					"expected_offset": [snappedf(want.x, 0.01), snappedf(want.y, 0.01)]})
			elif sample.is_empty():
				sample = {"unit": str(node2.name), "node": cname, "local_rotation": c.rotation,
					"screen_rotation_rad": snappedf(screen_rot, 0.0001),
					"screen_offset": [snappedf(off.x, 0.01), snappedf(off.y, 0.01)],
					"expected_offset": [snappedf(want.x, 0.01), snappedf(want.y, 0.01)], "zoom": z}
	_record("unit_visuals_upright", checked > 0 and bad.is_empty(),
		{"units_checked": checked, "nodes_per_unit": wants.size(), "yaw": yaw, "zoom": z,
		"bad": bad.slice(0, 6), "bad_count": bad.size(), "sample": sample})


# --- PHASE 4: legacy panel is reversible, then final state -------------------

func _phase_legacy_reversibility() -> bool:
	if _frame == 2:
		_dock.call("set_legacy_visible", true)
		return false
	if _frame == 8:
		var hud: CanvasLayer = _shell.get("hud_layer") as CanvasLayer
		var left_dock: Control = hud.get_node_or_null("LeftDock") as Control
		_record("legacy_restorable_on_demand", left_dock != null and left_dock.visible,
			{"left_dock_visible": left_dock.visible if left_dock != null else null})
		_save("polish_8_legacy_restored_for_check")
		_dock.call("set_legacy_visible", false)
		return false
	if _frame < 16:
		return false
	_save("polish_9_final_state")
	_finish(0 if _failed.is_empty() else 1)
	return true


# --- reporting --------------------------------------------------------------

func _save(shot_name: String) -> void:
	var img: Image = root.get_texture().get_image()
	if img == null or img.is_empty():
		_notes.append("NULL image for %s (dummy renderer?)" % shot_name)
		return
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	var path: String = "%s/%s.png" % [OUT_DIR, shot_name]
	var err: int = img.save_png(path)
	if err != OK:
		_notes.append("SAVE FAILED %s err=%d" % [path, err])
		return
	_shots.append(shot_name)
	print("[Polish] saved %s" % path)


func _finish(code: int) -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	var doc := {
		"probe": "CLOUD1-DEV-STEP1-VISUAL-POLISH",
		"godot_version": Engine.get_version_info(),
		"window": DisplayServer.window_get_size(),
		"presentation_yaw": PresentationOrientationCls.yaw_rad,
		"camera_rotation": _cam.rotation if _cam != null else null,
		"camera_zoom": _cam.zoom.x if _cam != null else null,
		"dock_width": _dock.call("get_dock_width") if _dock != null else null,
		"shots": _shots,
		"checks": _checks,
		"failed": _failed,
		"notes": _notes,
		"overall": "pass" if _failed.is_empty() else "fail",
	}
	var f := FileAccess.open(OUT_JSON, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(doc, "  "))
	print("[Polish] checks=%d failed=%d -> %s (exit %d)" % [_checks.size(), _failed.size(), OUT_JSON, code])
	quit(code)
