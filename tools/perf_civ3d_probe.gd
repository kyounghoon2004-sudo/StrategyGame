extends SceneTree

## CIV3D performance probe (MEASUREMENT ONLY): boots the default map, then
## toggles one presentation feature at a time and records frame time, script
## (process) time, GPU / CPU render time, draw calls and primitives.
##   Godot --path <project> --script res://tools/perf_civ3d_probe.gd

const OUT := "res://evidence/civ3d_perf/probe.json"
const CAMS := [["home", Vector2(-18, 0), 1.1], ["close", Vector2(-20, 0), 4.0], ["overview", Vector2(0, 0), 0.3]]
const CONFIGS := ["baseline", "no_shadows", "no_ssao_msaa", "no_overlay_vp", "no_scenery", "no_units3d", "no_2d_board_process", "all_off"]
const SETTLE := 20
const MEASURE := 60

var shell: Node
var view: Node
var menu_frames := 0
var ci := 0
var ki := 0
var frames := 0
var acc := {}
var results: Array = []
var vp_rid: RID

func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://evidence/civ3d_perf"))
	change_scene_to_file("res://scenes/title_screen.tscn")

func _process(delta: float) -> bool:
	if current_scene != null and current_scene.scene_file_path == "res://scenes/title_screen.tscn":
		menu_frames += 1
		if menu_frames == 8:
			var collection: Node = current_scene.get("_map_collection")
			collection.call("open")
			collection.find_child("OpenExistingProductionLayout", true, false).emit_signal("pressed")
		return false
	if view == null:
		if current_scene == null:
			return false
		shell = current_scene
		var v: Node = shell.get("_view3d")
		if v == null or not bool(v.call("is_active")):
			return false
		view = v
		vp_rid = root.get_viewport_rid()
		RenderingServer.viewport_set_measure_render_time(vp_rid, true)
		_apply()
		return false
	frames += 1
	if frames <= SETTLE:
		return false
	acc["dt"] = acc.get("dt", 0.0) + delta
	acc["proc"] = acc.get("proc", 0.0) + Performance.get_monitor(Performance.TIME_PROCESS)
	acc["gpu"] = acc.get("gpu", 0.0) + RenderingServer.viewport_get_measured_render_time_gpu(vp_rid)
	acc["cpu_r"] = acc.get("cpu_r", 0.0) + RenderingServer.viewport_get_measured_render_time_cpu(vp_rid)
	acc["draws"] = acc.get("draws", 0.0) + Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
	acc["prims"] = acc.get("prims", 0.0) + Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
	acc["objs"] = acc.get("objs", 0.0) + Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)
	if frames < SETTLE + MEASURE:
		return false
	var n := float(MEASURE)
	var row := {"cam": CAMS[ki][0], "config": CONFIGS[ci], "frame_ms": 1000.0 * acc["dt"] / n,
		"process_ms": 1000.0 * acc["proc"] / n, "gpu_ms": acc["gpu"] / n, "render_cpu_ms": acc["cpu_r"] / n,
		"draw_calls": acc["draws"] / n, "primitives": acc["prims"] / n, "objects": acc["objs"] / n}
	results.append(row)
	print("[Perf] %-8s %-20s frame %6.1f ms | process %6.1f | gpu %6.1f | render-cpu %6.1f | draws %6d | prims %9d" % [row["cam"], row["config"], row["frame_ms"], row["process_ms"], row["gpu_ms"], row["render_cpu_ms"], int(row["draw_calls"]), int(row["primitives"])])
	acc = {}
	frames = 0
	ci += 1
	if ci >= CONFIGS.size():
		ci = 0
		ki += 1
	if ki >= CAMS.size():
		var f := FileAccess.open(OUT, FileAccess.WRITE)
		f.store_string(JSON.stringify(results, "  "))
		f.close()
		quit()
		return false
	_apply()
	return false

func _apply() -> void:
	var c: String = CONFIGS[ci]
	var all_off := c == "all_off"
	# reset to baseline, then switch one thing off
	var sun: DirectionalLight3D = view.get("sun")
	sun.shadow_enabled = not (c == "no_shadows" or all_off)
	var env: Environment = _env()
	if env:
		env.ssao_enabled = not (c == "no_ssao_msaa" or all_off)
	root.msaa_3d = Viewport.MSAA_DISABLED if (c == "no_ssao_msaa" or all_off) else Viewport.MSAA_4X
	var ovp: SubViewport = view.get("_overlay_vp")
	ovp.render_target_update_mode = SubViewport.UPDATE_DISABLED if (c == "no_overlay_vp" or all_off) else SubViewport.UPDATE_ALWAYS
	var tr: Node3D = view.get("strict_transplant")
	tr.visible = not (c == "no_scenery" or all_off)
	var units: Dictionary = view.get("_units")
	for id in units.keys():
		var f3d: Node = units[id].get("f3d")
		if f3d != null:
			var off: bool = c == "no_units3d" or all_off
			(f3d as Node3D).visible = not off
			f3d.process_mode = Node.PROCESS_MODE_DISABLED if off else Node.PROCESS_MODE_INHERIT
			for ap in f3d.find_children("*", "AnimationPlayer", true, false):
				(ap as Node).process_mode = Node.PROCESS_MODE_DISABLED if off else Node.PROCESS_MODE_INHERIT
	for key in ["hex_grid", "hex_compositor", "unit_renderer", "stronghold_renderer"]:
		var n: Node = shell.get(key)
		if n != null and key != "unit_renderer":
			n.process_mode = Node.PROCESS_MODE_DISABLED if (c == "no_2d_board_process" or all_off) else Node.PROCESS_MODE_INHERIT
	var cam: Node = shell.get("camera")
	var q: Vector2 = CAMS[ki][1]
	cam.call("set_zoom_level", float(CAMS[ki][2]), true)
	cam.call("focus_on", Vector2(q.x * 36.0, q.y * 42.0 + q.x * 21.0), true)

func _env() -> Environment:
	for n in view.get_children():
		if n is WorldEnvironment:
			return (n as WorldEnvironment).environment
	return null
