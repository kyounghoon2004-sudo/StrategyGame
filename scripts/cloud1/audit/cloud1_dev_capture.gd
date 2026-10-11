extends SceneTree

## CLOUD1 DEV — windowed presentation capture (headless renderer is dummy).
## Proves the DEV battlefield PRESENTATION matches the Step 0 contract:
## uniform neutral ground, zero terrain clutter, all RED units visible, no fog.
##
## Run (windowed, NOT --headless):
##   Godot_v4.2.2-stable_win64_console.exe --path "<proj>" \
##     -s res://scripts/cloud1/audit/cloud1_dev_capture.gd

const HexUtils = preload("res://scripts/core/hex_utils.gd")

var _shell: Node = null
var _cam: Camera2D = null
var _plan: Array = []
var _idx := -1
var _settle := 0
var _shots: Array = []
var _cool := -1
var _acc := 0.0
var _frames := 0
var _dts: Array = []


func _initialize() -> void:
	change_scene_to_file("res://scenes/cloud1_battle_test.tscn")


func _process(_delta: float) -> bool:
	if _idx == -1:
		_settle += 1
		var cs: Node = current_scene
		if cs == null or cs.get_node_or_null("Cloud1LiveMount") == null:
			if _settle > 600:
				print("[DevCapture] scene never mounted")
				quit(1)
				return true
			return false
		var mount: Node = cs.get_node_or_null("Cloud1LiveMount")
		if not bool(mount.get("mount_ready")):
			if _settle > 3000:
				print("[DevCapture] mount never ready")
				quit(1)
				return true
			return false
		if _settle < 40:
			return false
		_shell = mount.get("shell") as Node
		_cam = _shell.get_node_or_null("Camera2D") as Camera2D
		if _cam != null:
			_cam.set("position_smoothing", 100000.0)
			_cam.set("_has_bounds", false)
		_plan = [
			{"name": "dev_flat_macro", "at": Vector2i(0, 0), "zoom": 0.42},
			{"name": "dev_default_view", "at": Vector2i(-8, 0), "zoom": 1.15},
			{"name": "dev_blue_deployment", "at": Vector2i(-17, -5), "zoom": 1.60},
			{"name": "dev_red_deployment", "at": Vector2i(17, -5), "zoom": 1.60},
			{"name": "dev_center_ground_close", "at": Vector2i(0, 0), "zoom": 2.20},
		]
		print("[DevCapture] mounted; plan=%d shots" % _plan.size())
		_idx = 0
		_settle = 0
		_apply_view(_plan[_idx])
		return false
	if _idx >= _plan.size():
		if _cool == -1:
			_cool = 120
		if _cool > 0:
			_cool -= 1
			_acc += _delta
			_frames += 1
			_dts.append(_delta)
			return false
		if _frames > 0:
			_dts.sort()
			var p50: float = float(_dts[_dts.size() / 2]) * 1000.0
			var p95: float = float(_dts[int(_dts.size() * 0.95)]) * 1000.0
			print("[DevCapture] steady_fps=%.1f frames=%d p50=%.1fms p95=%.1fms" % [float(_frames) / maxf(_acc, 0.001), _frames, p50, p95])
		_report_state()
		print("[DevCapture] DONE %d shots" % _shots.size())
		quit(0)
		return true
	_settle += 1
	if _settle < 10:
		return false
	if _settle == 10:
		_apply_view(_plan[_idx])
		_settle += 1
		return false
	_save(str((_plan[_idx] as Dictionary)["name"]))
	_idx += 1
	_settle = 0
	if _idx < _plan.size():
		_apply_view(_plan[_idx])
	return false


func _apply_view(item: Dictionary) -> void:
	var at: Vector2i = item["at"]
	var z: float = float(item["zoom"])
	var wp: Vector2 = HexUtils.hex_to_pixel(at.x, at.y)
	if _cam != null and _cam.has_method("focus_on"):
		_cam.call("focus_on", wp, true)
		_cam.call("set_zoom_level", z, true)
	elif _cam != null:
		_cam.position = wp
		_cam.zoom = Vector2(z, z)


func _report_state() -> void:
	if _shell == null:
		return
	var mgr: Variant = _shell.get("unit_manager")
	var rr: Node = _shell.get("unit_renderer") as Node
	var red_visible := 0
	var red_total := 0
	var fog_state := "missing"
	if mgr != null:
		for u in mgr.get_all_units_including_garrisoned():
			if u is Dictionary and str((u as Dictionary).get("faction", "")) == "red":
				red_total += 1
				var node: Node = rr.call("get_unit_node", str((u as Dictionary).get("id", ""))) as Node
				if node != null and node is CanvasItem and (node as CanvasItem).visible:
					red_visible += 1
	if _shell.get("_fog") == null:
		fog_state = "null (DEV full information)"
	print("[DevCapture] red_units=%d visible=%d fog=%s" % [red_total, red_visible, fog_state])
	print("[DevCapture] perf nodes=%d fps=%d proc=%.2fms" % [
		Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
		int(Performance.get_monitor(Performance.TIME_FPS)),
		Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
	])


func _save(shot_name: String) -> void:
	var img: Image = root.get_texture().get_image()
	if img == null or img.is_empty():
		print("[DevCapture] NULL image for %s (dummy renderer?)" % shot_name)
		return
	var dir: String = "D:/Game development/Demon slayer/StrategyGame/evidence/cloud1_audit"
	DirAccess.make_dir_recursive_absolute(dir)
	var path: String = "%s/%s.png" % [dir, shot_name]
	var err: int = img.save_png(path)
	if err != OK:
		print("[DevCapture] SAVE FAILED %s err=%d" % [path, err])
		return
	_shots.append(shot_name)
	print("[DevCapture] saved %s" % path)
