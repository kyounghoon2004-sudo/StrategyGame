extends SceneTree

## Windowed, repeatable measurement of the live full production terrain route.
## Usage: godot --path <project> -s res://tools/perf_full_map_opt.gd -- baseline|candidate
## Optional: warmup=20 frames=60 (same values must be used for both stages).
const OUT := "res://evidence/full_map_optimization"
const VIEWS := [
	["overview", Vector2(0, 0), 0.30],
	["gameplay", Vector2(-4, 2), 1.15],
	["forest", Vector2(-27, -5), 1.30],
	["mountain", Vector2(11, -14), 1.80],
]

var stage := "baseline"
var warmup := 20
var frames := 60
var shell: Node
var view: Node
var layer: Node
var index := -1
var view_frame := 0
var menu_frame := 0
var samples: Array = []
var rows: Array = []
var start_ms := 0
var gpu_rid: RID
var scene_stats: Dictionary = {}
var last_draw_us := 0

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg == "baseline" or arg == "candidate" or arg == "candidate2" or arg == "candidate3" or arg == "candidate4" or arg == "candidate5":
			stage = arg
		elif arg.begins_with("warmup="):
			warmup = maxi(1, int(arg.substr(7)))
		elif arg.begins_with("frames="):
			frames = maxi(1, int(arg.substr(7)))
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	start_ms = Time.get_ticks_msec()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	change_scene_to_file("res://scenes/title_screen.tscn")

func _process(delta: float) -> bool:
	if Time.get_ticks_msec() - start_ms > 600000:
		push_error("Full map performance capture timed out")
		quit(1)
		return true
	if current_scene != null and current_scene.scene_file_path == "res://scenes/title_screen.tscn":
		if menu_frame == 0:
			var collection: Node = current_scene.get("_map_collection")
			if collection == null:
				return false
			collection.call("open")
		menu_frame += 1
		if menu_frame == 8:
			var button: Node = current_scene.find_child("OpenExistingProductionLayout", true, false)
			if button == null:
				push_error("Production layout DEV button missing")
				quit(1)
				return true
			button.emit_signal("pressed")
		return false
	if index < 0:
		if current_scene == null:
			return false
		shell = current_scene
		view = shell.get("_view3d")
		if view == null or not bool(view.call("is_active")):
			return false
		layer = view.get("strict_transplant")
		if layer == null or not bool(layer.get("built")):
			return false
		gpu_rid = root.get_viewport().get_viewport_rid()
		RenderingServer.viewport_set_measure_render_time(gpu_rid, true)
		scene_stats = _count_nodes(layer)
		# Freeze interactive camera smoothing/pan/zoom for a reproducible view.
		var camera: Node = shell.get("camera")
		camera.set_process(false)
		camera.set_process_input(false)
		camera.set_process_unhandled_input(false)
		index = 0
		_apply_view()
		RenderingServer.frame_post_draw.connect(_after_draw)
		return false
	return false

func _after_draw() -> void:
	if index < 0 or index >= VIEWS.size():
		return
	var now_us := Time.get_ticks_usec()
	view_frame += 1
	if view_frame > warmup and view_frame <= warmup + frames and last_draw_us > 0:
		samples.append(_sample(float(now_us - last_draw_us) / 1000000.0))
	last_draw_us = now_us
	if view_frame >= warmup + frames:
		_complete_view()

func _apply_view() -> void:
	var entry: Array = VIEWS[index]
	var axial: Vector2 = entry[1]
	var position := Vector2(axial.x * 36.0, axial.y * 42.0 + axial.x * 21.0)
	var camera: Node = shell.get("camera")
	camera.call("set_zoom_level", float(entry[2]), true)
	camera.call("focus_on", position, true)
	view.set("_cam_sig", Vector4.INF)
	view.call("_update_camera")
	view_frame = 0
	last_draw_us = 0
	samples.clear()
	print("[perf_full_map] stage=%s view=%s" % [stage, entry[0]])

func _sample(delta: float) -> Dictionary:
	var visible := RenderingServer.VIEWPORT_RENDER_INFO_TYPE_VISIBLE
	var shadow := RenderingServer.VIEWPORT_RENDER_INFO_TYPE_SHADOW
	return {
		"frame_ms": delta * 1000.0,
		"process_ms": float(Performance.get_monitor(Performance.TIME_PROCESS)) * 1000.0,
		"render_cpu_ms": RenderingServer.viewport_get_measured_render_time_cpu(gpu_rid),
		"render_gpu_ms": RenderingServer.viewport_get_measured_render_time_gpu(gpu_rid),
		"objects": RenderingServer.viewport_get_render_info(gpu_rid, visible, RenderingServer.VIEWPORT_RENDER_INFO_OBJECTS_IN_FRAME),
		"primitives": RenderingServer.viewport_get_render_info(gpu_rid, visible, RenderingServer.VIEWPORT_RENDER_INFO_PRIMITIVES_IN_FRAME),
		"draw_calls": RenderingServer.viewport_get_render_info(gpu_rid, visible, RenderingServer.VIEWPORT_RENDER_INFO_DRAW_CALLS_IN_FRAME),
		"shadow_objects": RenderingServer.viewport_get_render_info(gpu_rid, shadow, RenderingServer.VIEWPORT_RENDER_INFO_OBJECTS_IN_FRAME),
		"shadow_primitives": RenderingServer.viewport_get_render_info(gpu_rid, shadow, RenderingServer.VIEWPORT_RENDER_INFO_PRIMITIVES_IN_FRAME),
		"shadow_draw_calls": RenderingServer.viewport_get_render_info(gpu_rid, shadow, RenderingServer.VIEWPORT_RENDER_INFO_DRAW_CALLS_IN_FRAME),
	}

func _complete_view() -> void:
	var entry: Array = VIEWS[index]
	var name: String = entry[0]
	var image: Image = root.get_texture().get_image()
	var path := "%s/%s_%s.png" % [OUT, stage, name]
	var image_error := image.save_png(path)
	var camera: Node = shell.get("camera")
	var sums: Dictionary = {}
	for key in samples[0].keys():
		var vals: Array = []
		for s in samples:
			vals.append(float(s[key]))
		vals.sort()
		var total := 0.0
		for v in vals:
			total += v
		sums[key] = {"mean": total / vals.size(), "p50": vals[vals.size() / 2], "p95": vals[mini(vals.size() - 1, int(vals.size() * 0.95))]}
	var frame_mean: float = sums["frame_ms"]["mean"]
	var row := {
		"view": name, "axial": [entry[1].x, entry[1].y], "zoom": entry[2],
		"camera_position": [camera.global_position.x, camera.global_position.y],
		"camera_zoom_effective": camera.zoom.x,
		"camera_zoom_target": camera.get("target_zoom"),
		"camera3d_position": [view.get("cam").global_position.x, view.get("cam").global_position.y, view.get("cam").global_position.z],
		"camera3d_size": view.get("cam").size,
		"camera3d_forward": [-view.get("cam").global_transform.basis.z.x, -view.get("cam").global_transform.basis.z.y, -view.get("cam").global_transform.basis.z.z],
		"view_forward": [view.get("fwd").x, view.get("fwd").y, view.get("fwd").z],
		"sample_frames": samples.size(), "fps": 1000.0 / frame_mean,
		"metrics": sums, "screenshot": path, "screenshot_saved": image_error == OK,
		"screenshot_dimensions": [image.get_width(), image.get_height()],
	}
	rows.append(row)
	print("[perf_full_map] RESULT " + JSON.stringify(row))
	index += 1
	if index < VIEWS.size():
		_apply_view()
	else:
		_finish()

func _finish() -> void:
	var report: Dictionary = layer.get("report")
	var receipt := {
		"stage": stage, "scene": current_scene.scene_file_path,
		"route": "Title > DEV Map Collection > existing production layout",
		"renderer": ProjectSettings.get_setting("rendering/renderer/rendering_method"),
		"vsync": "disabled", "warmup_frames_per_view": warmup,
		"sample_frames_per_view": frames,
		"viewport_size": [root.size.x, root.size.y],
		"scene_counts": scene_stats,
		"engine_nodes": int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		"video_mem_bytes": int(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED)),
		"static_mem_bytes": int(Performance.get_monitor(Performance.MEMORY_STATIC)),
		"layout_sha256": report.get("layout_sha256_after", ""),
		"placement_sha256": report.get("placement_sha256", ""),
		"playable_hexes": report.get("playable_hexes", 0),
		"ground_batch_optimization": report.get("ground_batch_optimization", {}),
		"tree_runtime_optimization": report.get("tree_runtime_optimization", {}),
		"shadows_on": layer.call("shadow_count", view),
		"views": rows,
	}
	var path := "%s/%s.json" % [OUT, stage]
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("Could not write receipt: " + path)
		quit(1)
		return
	file.store_string(JSON.stringify(receipt, "  "))
	file.close()
	print("[perf_full_map] COMPLETE " + path)
	quit(0)

func _count_nodes(node: Node) -> Dictionary:
	var counts := {"nodes": 1, "mesh_instances": 0, "multimesh_instances": 0, "lights": 0}
	if node is MeshInstance3D:
		counts["mesh_instances"] += 1
	if node is MultiMeshInstance3D:
		counts["multimesh_instances"] += 1
	if node is Light3D:
		counts["lights"] += 1
	for child in node.get_children():
		var sub: Dictionary = _count_nodes(child)
		for key in counts:
			counts[key] += sub[key]
	return counts
