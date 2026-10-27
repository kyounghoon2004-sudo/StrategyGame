extends "res://tools/dev_visual_lab/unit_world.gd"

## Automated capture and performance baseline runner for scenery scale candidate comparison.
## Fixed resolution 1600x900, fixed lighting and camera presets.

const CAPTURE_OUT := "C:/Users/User/Documents/Codex/2026-10-18/strategygame-godot-4-2-2-repo/outputs/scenery-scale-massif/renders"

func _initialize() -> void:
	super._initialize()
	root.size = Vector2i(1600, 900)
	root.min_size = Vector2i(1600, 900)

func boot() -> void:
	await super.boot()
	if not capture_mode:
		await run_scaled_capture()

func capture_suite() -> void:
	ensure_roads()
	if not units_ready:
		await setup_units()
	await run_scaled_capture()

func run_scaled_capture() -> void:
	print("[ScaledSceneryCapture] Starting capture & perf baseline suite...")
	DirAccess.make_dir_recursive_absolute(CAPTURE_OUT)
	ui.visible = false
	root.size = Vector2i(1600, 900)
	DisplayServer.window_set_size(Vector2i(1600, 900))
	await wait_frames(10)

	# 1. Capture 6 fixed Before images with highest visual fidelity (LOD0 locked)
	print("[ScaledSceneryCapture] Locking LOD0 for screenshot captures...")
	lock_detail = true
	active_kit_lod = 0
	if unit_manager != null:
		unit_manager.forced_detail = 0
	update_lod()
	await wait_frames(20)

	var shots: Array = [
		{
			"name": "before-unit-castle-hq.png",
			"target": center(4, 3).lerp(center(4, 4), 0.45),
			"size": 80.0,
			"yaw": 0.12,
			"orbit": 0.72,
			"desc": "unit+castle/HQ"
		},
		{
			"name": "before-unit-village.png",
			"target": center(-3, 1).lerp(center(-2, 1), 0.40),
			"size": 80.0,
			"yaw": 0.12,
			"orbit": 0.72,
			"desc": "unit+village"
		},
		{
			"name": "before-forest-mountain-foot.png",
			"target": center(-5, -2),
			"size": 95.0,
			"yaw": 0.15,
			"orbit": 0.68,
			"desc": "forest+mountain foot"
		},
		{
			"name": "before-range-diagonal.png",
			"target": world_ranges[2]["focus"],
			"size": maxf(110.0, float(world_ranges[2]["span"]) * 1.28),
			"yaw": 0.12,
			"orbit": 0.78,
			"desc": "a range diagonal (range 2 straight_medium)"
		},
		{
			"name": "before-range-y-branch.png",
			"target": world_ranges[17]["focus"],
			"size": maxf(110.0, float(world_ranges[17]["span"]) * 1.28),
			"yaw": 0.12,
			"orbit": 0.78,
			"desc": "a Y branch range (range 17 y_branch_medium)"
		},
		{
			"name": "before-overall.png",
			"target": Vector3.ZERO,
			"size": 2400.0,
			"yaw": 0.12,
			"orbit": 1.05,
			"desc": "overall world"
		},
		{
			"name": "before-oblique-unit-castle-hq.png",
			"target": center(4, 3).lerp(center(4, 4), 0.45),
			"size": 55.0,
			"yaw": 0.18,
			"orbit": 0.63,
			"desc": "oblique unit+castle/HQ (~36 deg pitch, close zoom)"
		},
		{
			"name": "before-oblique-unit-village.png",
			"target": center(-3, 1).lerp(center(-2, 1), 0.35),
			"size": 55.0,
			"yaw": 0.15,
			"orbit": 0.63,
			"desc": "oblique unit+village (~36 deg pitch, close zoom)"
		},
		{
			"name": "before-oblique-range-diagonal.png",
			"target": world_ranges[2]["focus"],
			"size": 110.0,
			"yaw": 0.22,
			"orbit": 0.62,
			"desc": "oblique range diagonal (~35.5 deg pitch, close zoom)"
		},
		{
			"name": "before-oblique-range-y-branch.png",
			"target": world_ranges[17]["focus"],
			"size": 110.0,
			"yaw": 0.18,
			"orbit": 0.62,
			"desc": "oblique Y branch range (~35.5 deg pitch, close zoom)"
		},
		{
			"name": "before-oblique-unit-castle-hq-full.png",
			"target": center(4, 3).lerp(center(4, 4), 0.45),
			"size": 75.0,
			"yaw": 0.75,
			"orbit": 0.63,
			"desc": "oblique unit+castle/HQ full frame (~36 deg pitch, yaw=0.72, unoccluded)"
		}
	]

	var captured_files: Array = []
	for shot in shots:
		target = shot["target"]
		camera.size = shot["size"]
		yaw = shot["yaw"]
		orbit = shot["orbit"]
		update_camera()
		await wait_frames(20)
		await RenderingServer.frame_post_draw

		var img := root.get_texture().get_image()
		var out_path: String = CAPTURE_OUT.path_join(shot["name"])
		img.save_png(out_path)
		captured_files.append({"file": shot["name"], "path": out_path, "size": [img.get_width(), img.get_height()], "desc": shot["desc"]})
		print("[ScaledSceneryCapture] Saved %s (%dx%d) - %s" % [shot["name"], img.get_width(), img.get_height(), shot["desc"]])

	# 2. Performance benchmark on fixed representative camera (overall map overview, seeing entire world)
	print("\n[ScaledSceneryCapture] Running performance measurement (300 frames per mode)...")
	target = Vector3.ZERO
	camera.size = 2400.0
	yaw = 0.12
	orbit = 1.05
	update_camera()
	await wait_frames(30)

	# (a) Performance with --all-lod0 (locked LOD0)
	print("Measuring Mode 1: all-lod0 (300 frames)...")
	lock_detail = true
	active_kit_lod = 0
	if unit_manager != null:
		unit_manager.forced_detail = 0
	update_lod()
	var perf_all_lod0 := await record_frame_samples(300)

	# (b) Performance with auto LOD
	print("Measuring Mode 2: auto-LOD (300 frames)...")
	lock_detail = false
	active_kit_lod = -1
	if unit_manager != null:
		unit_manager.forced_detail = -1
	update_lod()
	var perf_auto_lod := await record_frame_samples(300)

	var trees_map := plain_tree_heatmap()
	var plain_trees_total := 0
	for count in trees_map.values():
		plain_trees_total += int(count)

	var prop_counts := {
		"document_props": document.size(),
		"resident_ranges": world_ranges.size(),
		"total_rocks": total_rocks(),
		"village_farm_assemblies": hex_assemblies.size(),
		"plain_trees_total": plain_trees_total,
		"unit_formations": unit_manager.entries.size() if unit_manager != null else 0,
		"hex_cells_total": cells.size()
	}

	var perf_report := {
		"timestamp": Time.get_datetime_string_from_system(true),
		"viewport_resolution": [root.size.x, root.size.y],
		"renderer_adapter": RenderingServer.get_video_adapter_name(),
		"godot_version": Engine.get_version_info()["string"],
		"benchmark_camera": {
			"target": [target.x, target.y, target.z],
			"camera_size": camera.size,
			"yaw": yaw,
			"orbit": orbit
		},
		"prop_counts": prop_counts,
		"perf_all_lod0": perf_all_lod0,
		"perf_auto_lod": perf_auto_lod,
		"captured_shots": captured_files
	}

	var perf_path := CAPTURE_OUT.path_join("perf-before.json")
	var f := FileAccess.open(perf_path, FileAccess.WRITE)
	f.store_string(JSON.stringify(perf_report, "\t"))
	f.close()
	print("[ScaledSceneryCapture] Performance record saved to: ", perf_path)
	print("[ScaledSceneryCapture] all-lod0: p50=%.2f ms, p95=%.2f ms, draws=%.1f, tris=%.0f, vram=%.1f MB" % [
		perf_all_lod0["frame_ms_median"], perf_all_lod0["frame_ms_p95"], perf_all_lod0["draw_calls_mean"], perf_all_lod0["primitives_mean"], perf_all_lod0["video_mem_mb_last"]
	])
	print("[ScaledSceneryCapture] auto-lod:  p50=%.2f ms, p95=%.2f ms, draws=%.1f, tris=%.0f, vram=%.1f MB" % [
		perf_auto_lod["frame_ms_median"], perf_auto_lod["frame_ms_p95"], perf_auto_lod["draw_calls_mean"], perf_auto_lod["primitives_mean"], perf_auto_lod["video_mem_mb_last"]
	])
	print("[ScaledSceneryCapture] ALL BEFORE CAPTURES AND BENCHMARK COMPLETE.")

	quit(0)

func record_frame_samples(samples: int) -> Dictionary:
	await wait_frames(30) # Warm up
	var frame_ms: Array = []
	var draws: Array = []
	var triangles: Array = []
	var vram_mb: Array = []

	for i in range(samples):
		var started := Time.get_ticks_usec()
		await process_frame
		var elapsed_ms: float = (Time.get_ticks_usec() - started) / 1000.0
		frame_ms.append(elapsed_ms)
		draws.append(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
		triangles.append(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
		vram_mb.append(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / (1024.0 * 1024.0))

	frame_ms.sort()
	var p50_idx := int(samples * 0.50)
	var p95_idx := int(samples * 0.95)

	return {
		"samples": samples,
		"frame_ms_median": frame_ms[p50_idx],
		"frame_ms_p95": frame_ms[p95_idx],
		"frame_ms_min": frame_ms[0],
		"frame_ms_max": frame_ms[-1],
		"draw_calls_mean": sum_values(draws) / float(draws.size()),
		"primitives_mean": sum_values(triangles) / float(triangles.size()),
		"video_mem_mb_mean": sum_values(vram_mb) / float(vram_mb.size()),
		"video_mem_mb_last": vram_mb[-1]
	}
