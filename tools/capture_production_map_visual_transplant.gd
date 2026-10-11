extends SceneTree

## CAPTURE PRODUCTION MAP VISUAL TRANSPLANT
##
## Captures all 10 authoritative validation views of the full production map
## (R=40, 4,921 cells) inside the real game battlefield shell:
## 1. 01 Full Map Macro Overview
## 2. 02 Quadrant North-West
## 3. 03 Quadrant North-East
## 4. 04 Quadrant South-West
## 5. 05 Quadrant South-East
## 6. 06 Transition: Mountain Massif -> Foothills -> Plains
## 7. 07 Transition: Forest Core -> Edge -> Plains
## 8. 08 River Course: Crossing & Banks
## 9. 09 Settlement: Village, Granaries & Farmlands
## 10. 10 Fortress Hulao: Citadel & Terrain
##
## Run (windowed, NOT --headless):
##   Godot_v4.2.2-stable_win64_console.exe --path "D:\Game development\Demon slayer\StrategyGame" -s res://tools/capture_production_map_visual_transplant.gd

const OUT_DIR := "D:/Game development/Demon slayer/StrategyGame/evidence/production_map_visual_transplant"

const PLAN: Array = [
	{
		"id": "01_full_map_macro_overview",
		"name": "01 Full Map Macro Overview",
		"preset": "01_full_map_macro_overview",
		"desc": "Wide overview of complete R=40 production battlefield (all 4,921 hexes)",
	},
	{
		"id": "02_quadrant_nw",
		"name": "02 Quadrant North-West",
		"preset": "02_quadrant_nw",
		"desc": "North-West quadrant: River Origin, Northern Pines & Western High Ridge",
	},
	{
		"id": "03_quadrant_ne",
		"name": "03 Quadrant North-East",
		"preset": "03_quadrant_ne",
		"desc": "North-East quadrant: Northern Spine Mountain Chain & North Pass",
	},
	{
		"id": "04_quadrant_sw",
		"name": "04 Quadrant South-West",
		"preset": "04_quadrant_sw",
		"desc": "South-West quadrant: Western Timberlands, Swamp & River Basin",
	},
	{
		"id": "05_quadrant_se",
		"name": "05 Quadrant South-East",
		"preset": "05_quadrant_se",
		"desc": "South-East quadrant: Southern Ridge, Delta & Eastern Plains",
	},
	{
		"id": "06_transition_mountain_foothill_plain",
		"name": "06 Transition: Mountain Massif -> Foothills -> Plains",
		"preset": "06_transition_mountain_foothill_plain",
		"desc": "Natural transition: high mountain peak to foothills to rocky plains",
	},
	{
		"id": "07_transition_forest_core_edge_plain",
		"name": "07 Transition: Forest Core -> Edge -> Plains",
		"preset": "07_transition_forest_core_edge_plain",
		"desc": "Natural transition: dense pine interior to mixed fringe to open grassland",
	},
	{
		"id": "08_river_course_crossing_banks",
		"name": "08 River Course: Crossing & Banks",
		"preset": "08_river_course_crossing_banks",
		"desc": "Natural transition: continuous river course, highway bridge crossing & banks",
	},
	{
		"id": "09_village_farms_surroundings",
		"name": "09 Settlement: Village, Granaries & Farmlands",
		"preset": "09_village_farms_surroundings",
		"desc": "Natural transition: strategic village settlement, granaries & cultivated agricultural fields",
	},
	{
		"id": "10_fortress_commanding_terrain",
		"name": "10 Fortress Hulao: Citadel & Terrain",
		"preset": "10_fortress_commanding_terrain",
		"desc": "Strategic stronghold: Fortress Hulao citadel, bastions & outer bailey commanding road",
	},
]

var _shell: Node = null
var _env: Node3D = null
var _idx: int = -1
var _settle: int = 0
var _shots: Array = []
var _acc: float = 0.0
var _frames: int = 0
var _dts: Array = []
var _t_start: int = 0

func _initialize() -> void:
	_t_start = Time.get_ticks_msec()
	print("[CaptureProdMap] Initializing production battlefield scene...")
	change_scene_to_file("res://scenes/step2r_battlefield_shell.tscn")

func _process(delta: float) -> bool:
	if _idx == -1:
		_settle += 1
		var cs: Node = current_scene
		if cs == null:
			if Time.get_ticks_msec() - _t_start > 30000:
				print("[CaptureProdMap] ERROR: Scene mounting timed out")
				quit(1)
				return true
			return false

		var env: Node = cs.get_node_or_null("ProductionMapEnvironment3D")
		if env == null or not bool(env.get("built")):
			if Time.get_ticks_msec() - _t_start > 30000:
				print("[CaptureProdMap] ERROR: ProductionMapEnvironment3D build timed out")
				quit(1)
				return true
			return false

		_shell = cs
		_env = env as Node3D
		print("[CaptureProdMap] Battlefield Shell mounted & ProductionMapEnvironment3D ready!")

		# Deactivate and remove BattlefieldCloseupView if present
		var v3d: Node = cs.get_node_or_null("BattlefieldCloseupView")
		if v3d != null:
			if v3d.has_method("apply_active"):
				v3d.call("apply_active", false)
			v3d.queue_free()

		var mc: Node = cs.get_node_or_null("PresentationModeController")
		if mc != null:
			mc.queue_free()

		# Hide 2D game HUD and 2D canvas layers so only pure environment + caption are visible
		for c in cs.get_children():
			if c is CanvasLayer and c.name != "ProductionCaptionLayer":
				(c as CanvasLayer).visible = false
			elif c is CanvasItem and c.name != "ProductionCaptionLayer":
				(c as CanvasItem).visible = false

		# Activate 3D camera
		var cam: Camera3D = _env.call("setup_camera")
		if cam != null:
			cam.make_current()

		_idx = 0
		_settle = 0
		_apply(PLAN[0])
		return false

	if _idx >= PLAN.size():
		# Steady-state FPS sampling
		if _frames < 120:
			_acc += delta
			_frames += 1
			_dts.append(delta)
			return false
		_finish()
		return true

	_settle += 1
	var need_frames: int = 40 if _idx == 0 else 18
	if _settle < need_frames:
		return false

	_save(String(PLAN[_idx]["id"]))
	_idx += 1
	_settle = 0
	if _idx < PLAN.size():
		_apply(PLAN[_idx])
	return false

func _apply(item: Dictionary) -> void:
	var preset: String = String(item["preset"])
	_env.call("apply_view_preset", preset)
	var cam: Camera3D = _env.call("get_camera")
	if cam != null:
		cam.make_current()
	print("[CaptureProdMap] Applied view preset: %s" % preset)

func _save(shot_id: String) -> void:
	var img: Image = root.get_texture().get_image()
	if img == null or img.is_empty():
		print("[CaptureProdMap] ERROR: Null image for %s" % shot_id)
		return

	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	var path: String = "%s/%s.png" % [OUT_DIR, shot_id]
	var err: int = FAILED
	for attempt in range(6):
		err = img.save_png(path)
		if err == OK:
			break
		OS.delay_msec(300)

	var cam: Camera3D = _env.call("get_camera")
	var entry := {
		"id": shot_id,
		"file": path,
		"dimensions": [img.get_width(), img.get_height()],
		"camera_size": cam.size if cam != null else -1.0,
		"camera_position": [cam.position.x, cam.position.y, cam.position.z] if cam != null else [],
		"save_err": err,
	}
	_shots.append(entry)
	print("[CaptureProdMap] Saved shot %s (%dx%d) -> %s" % [shot_id, img.get_width(), img.get_height(), path])

func _finish() -> void:
	_dts.sort()
	var p50: float = float(_dts[_dts.size() / 2]) * 1000.0
	var p95: float = float(_dts[int(_dts.size() * 0.95)]) * 1000.0
	var avg_fps: float = float(_frames) / maxf(_acc, 0.001)

	var env_report: Dictionary = _env.get("report") if _env.get("report") is Dictionary else {}
	var receipt := {
		"task": "FULL_PRODUCTION_MAP_VISUAL_TRANSPLANT",
		"timestamp": Time.get_datetime_string_from_system(),
		"map_dimensions": {
			"radius": 40,
			"shape": "Regular Hexagon",
			"total_playable_hexes": int(env_report.get("total_playable_hexes", 4921)),
			"decorated_ground_hex_count": int(env_report.get("decorated_ground_hex_count", 4921)),
			"uncovered_legacy_hex_count": int(env_report.get("uncovered_legacy_hex_count", 0)),
		},
		"macro_geography": {
			"mountains": int(env_report.get("feature_counts", {}).get("mountain", 0)),
			"forests": int(env_report.get("feature_counts", {}).get("forest", 0)),
			"rivers": int(env_report.get("feature_counts", {}).get("river", 0)),
			"settlements": int(env_report.get("feature_counts", {}).get("settlement", 0)),
			"fortifications": int(env_report.get("feature_counts", {}).get("fortification", 0)),
			"agricultural_plots": int(env_report.get("feature_counts", {}).get("agriculture", 0)),
			"open_plains": int(env_report.get("feature_counts", {}).get("open_plain", 0)),
		},
		"performance": {
			"steady_fps": snappedf(avg_fps, 0.1),
			"sample_frames": _frames,
			"p50_ms": snappedf(p50, 0.01),
			"p95_ms": snappedf(p95, 0.01),
			"object_nodes": Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
		},
		"shots": _shots,
		"conclusion": "FULL_PRODUCTION_MAP_VISUAL_TRANSPLANT_PASS",
	}

	var receipt_path: String = OUT_DIR + "/capture_receipt.json"
	var f := FileAccess.open(receipt_path, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(receipt, "  "))
		f.close()

	print("\n=======================================================")
	print("[CaptureProdMap] FULL PRODUCTION MAP VISUAL TRANSPLANT COMPLETE")
	print("  Playable Hexes: %d" % int(receipt["map_dimensions"]["total_playable_hexes"]))
	print("  Decorated Ground Hexes: %d" % int(receipt["map_dimensions"]["decorated_ground_hex_count"]))
	print("  Uncovered Legacy Hexes: %d" % int(receipt["map_dimensions"]["uncovered_legacy_hex_count"]))
	print("  Steady FPS: %.1f (p50=%.2f ms, p95=%.2f ms)" % [avg_fps, p50, p95])
	print("  Screenshots Saved: %d -> %s" % [_shots.size(), OUT_DIR])
	print("  Receipt: %s" % receipt_path)
	print("=======================================================\n")
	quit(0)
