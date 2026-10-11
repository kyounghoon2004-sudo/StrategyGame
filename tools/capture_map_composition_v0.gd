extends SceneTree

## MAP COMPOSITION V0 — windowed evidence capture (headless renderer is dummy).
## Renders the review scene at the live presentation zoom semantics and saves
## PNGs plus a JSON receipt under evidence/map_composition_v0/.
##
## Run (windowed, NOT --headless):
##   Godot_v4.2.2-stable_win64_console.exe --path "<proj>" \
##     -s res://tools/capture_map_composition_v0.gd

const OUT_DIR := "D:/Game development/Demon slayer/StrategyGame/evidence/map_composition_v0"

const PLAN: Array = [
	{"name": "01_gameplay_battlefield_center", "zoom": 1.15, "rect": "BATTLEFIELD_CENTER",
		"note": "Normal gameplay camera (zoom 1.15) — tactical center plain, village, river crossing and fortress"},
	{"name": "02_gameplay_fortress", "zoom": 1.15, "rect": "FORTRESS",
		"note": "Normal gameplay camera — Fortress Citadel Keep, Outer Bailey Gatehouse, Bastion Hill"},
	{"name": "03_gameplay_river_crossing", "zoom": 1.15, "rect": "RIVER_CROSSING",
		"note": "Normal gameplay camera — Stone Bridge & Shallow Ford river crossings"},
	{"name": "04_gameplay_village_and_farms", "zoom": 1.15, "rect": "VILLAGE",
		"note": "Normal gameplay camera — Village settlement cluster & agricultural fields"},
	{"name": "05_gameplay_mountain_system", "zoom": 1.15, "rect": "MOUNTAINS",
		"note": "Normal gameplay camera — Northern mountain chain, peaks, pass & foothills"},
	{"name": "06_gameplay_forest_clusters", "zoom": 1.15, "rect": "FOREST",
		"note": "Normal gameplay camera — Western dense forest clusters spilling to plains"},
	{"name": "07_wide_dev_macro_overview", "zoom": 0.42, "rect": "ALL",
		"note": "Wide overview (Cloud1 dev_flat_macro zoom 0.42) — entire 80-hex dressed battlefield"},
	{"name": "08_wide_tactical_overview", "zoom": 0.65, "rect": "ALL",
		"note": "Wide tactical overview (zoom 0.65) — full battlefield framed in 3/4 perspective"},
	{"name": "09_wide_gameplay_fit_battlefield", "zoom": 1.15, "rect": "ALL",
		"note": "Wide gameplay-perspective shot fitting entire battlefield at 33.8° 3/4 camera"},
]

var _scene: Node = null
var _idx := -1
var _settle := 0
var _shots: Array = []
var _acc := 0.0
var _frames := 0
var _dts: Array = []
var _t_start := 0


func _initialize() -> void:
	_t_start = Time.get_ticks_msec()
	change_scene_to_file("res://scenes/review/map_composition_v0.tscn")


func _process(_delta: float) -> bool:
	if _idx == -1:
		_settle += 1
		var cs: Node = current_scene
		if cs == null:
			if Time.get_ticks_msec() - _t_start > 600000:
				print("[MapCompCapture] scene never mounted")
				quit(1)
				return true
			return false
		if cs.get("built") == null or not bool(cs.get("built")):
			if Time.get_ticks_msec() - _t_start > 600000:
				print("[MapCompCapture] scene never built")
				quit(1)
				return true
			return false
		_scene = cs
		print("[MapCompCapture] scene built; plan=%d shots" % PLAN.size())
		_idx = 0
		_settle = 0
		_apply(PLAN[0])
		return false
	if _idx >= PLAN.size():
		# steady-state perf sample after the last shot
		if _frames < 120:
			_acc += _delta
			_frames += 1
			_dts.append(_delta)
			return false
		_finish()
		return true
	_settle += 1
	# first shot: allow shader compilation; later shots: shorter settle
	var need: int = 40 if _idx == 0 else 16
	if _settle < need:
		return false
	_save(String(PLAN[_idx]["name"]))
	_idx += 1
	_settle = 0
	if _idx < PLAN.size():
		_apply(PLAN[_idx])
	return false


func _apply(item: Dictionary) -> void:
	var pitch: float = float(item.get("pitch", 0.0))
	_scene.call("set_view_zoom", float(item["zoom"]), _scene.call("focus_rect", String(item["rect"])), 1.12, pitch)
	_scene.call("set_caption", String(item["name"]), float(item["zoom"]), pitch)


func _save(shot_name: String) -> void:
	var img: Image = root.get_texture().get_image()
	if img == null or img.is_empty():
		print("[MapCompCapture] NULL image for %s (dummy renderer?)" % shot_name)
		return
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	var path: String = "%s/%s.png" % [OUT_DIR, shot_name]
	var err: int = FAILED
	for attempt in range(6):
		err = img.save_png(path)
		if err == OK:
			break
		# transient Windows lock (AV/indexer/thumbnail); retry
		OS.delay_msec(400)
	var cam: Camera3D = _scene.get("cam") as Camera3D
	var entry := {
		"name": shot_name,
		"file": path,
		"size": [img.get_width(), img.get_height()],
		"camera_size": cam.size if cam != null else -1.0,
		"camera_position": [cam.position.x, cam.position.y, cam.position.z] if cam != null else [],
		"save_err": err,
	}
	_shots.append(entry)
	print("[MapCompCapture] saved %s (%dx%d)" % [path, img.get_width(), img.get_height()])


func _finish() -> void:
	_dts.sort()
	var p50: float = float(_dts[_dts.size() / 2]) * 1000.0
	var p95: float = float(_dts[int(_dts.size() * 0.95)]) * 1000.0
	var report: Variant = _scene.get("report")
	var receipt := {
		"scene": "map_composition_v0",
		"shots": _shots,
		"plan": PLAN,
		"perf": {
			"steady_fps": snappedf(float(_frames) / maxf(_acc, 0.001), 0.1),
			"frames": _frames,
			"p50_ms": snappedf(p50, 0.01),
			"p95_ms": snappedf(p95, 0.01),
			"object_nodes": Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
		},
		"report": report,
	}
	var path := OUT_DIR + "/capture_receipt.json"
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(receipt, "  "))
		f.close()
	print("[MapCompCapture] report = " + JSON.stringify(report, " "))
	print("[MapCompCapture] perf steady_fps=%.1f p50=%.2fms p95=%.2fms nodes=%d" % [
		float(_frames) / maxf(_acc, 0.001), p50, p95,
		Performance.get_monitor(Performance.OBJECT_NODE_COUNT)])
	print("[MapCompCapture] DONE %d shots | receipt=%s" % [_shots.size(), path])
	quit(0)
