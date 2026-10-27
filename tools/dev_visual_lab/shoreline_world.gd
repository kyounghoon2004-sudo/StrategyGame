extends "res://tools/dev_visual_lab/settlement_farm_world.gd"
## Latest modular settlements + contextual riparian coverage on the same map.
const Shoreline = preload("res://tools/dev_visual_lab/river_shoreline.gd")
const SHORE_DIR := "C:/Users/User/Documents/Codex/2026-10-18/strategygame-godot-4-2-2-repo/outputs/river-shoreline"

func before_mode() -> bool:
	return "--shore-before" in OS.get_cmdline_user_args()

func make_waterway() -> RefCounted:
	if before_mode(): return Waterway.new()
	return Shoreline.new()

func build_terrain() -> void:
	super.build_terrain()
	# Deck breadth is local Z; local X remains the bank-to-bank span.
	# Scale the two bridge assemblies coherently, retaining their source meshes.
	for assembly in land.get_children():
		if not assembly is Node3D or assembly.has_meta("bridge_breadth_adjusted"): continue
		for mesh in assembly.find_children("*","MeshInstance3D",true,false):
			var part := String(mesh.name)
			if part.begins_with("WoodenBridge_") or part.begins_with("StoneReinforcedBridge_"):
				assembly.scale.z *= 1.20
				assembly.set_meta("bridge_breadth_adjusted",true)
				print("[ShorelineWorld] Bridge deck breadth +20%: ",part)
				break

func boot() -> void:
	DirAccess.make_dir_recursive_absolute(SHORE_DIR)
	await super.boot()
	root.title = "StrategyGame | Full Asset Library - Connected River Shores"
	if not capture_mode:
		focus_crossing()
		await wait_frames(6)
		print("[ShorelineWorld] interactive ready: 25 ranges, ",hex_assemblies.size()," village/farm assemblies; zoom/orbit/pan enabled")

func update_lod() -> void:
	super.update_lod()
	if waterway!=null and waterway.has_method("set_detail"): waterway.set_detail(camera.size)

func save_picture(name: String) -> void:
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(SHORE_DIR.path_join(("before-" if before_mode() else "after-")+name+".png"))

func save_render_png(name: String) -> void:
	await save_picture(name)

func capture_suite() -> void:
	DirAccess.make_dir_recursive_absolute(SHORE_DIR)
	ui.visible = false
	lock_detail = true
	active_kit_lod = 0
	benchmark_running = true
	freeze_flow = true
	waterway.set_flow_time(5.0)
	var rid := root.get_viewport_rid()
	var gpu_supported := RenderingServer.has_method("viewport_set_measure_render_time")
	if gpu_supported: RenderingServer.call("viewport_set_measure_render_time",rid,true)
	var rows := []
	for shot in ["district-near","district-mid","northern-bend","crossing","world-overview"]:
		match shot:
			"district-near": focus_district1_near()
			"district-mid": focus_district1_mid()
			"northern-bend": focus_northern_bend()
			"crossing": focus_crossing()
			_: show_world()
		await wait_frames(30)
		var wall: Array[float] = []
		var gpu: Array[float] = []
		var cpu: Array[float] = []
		var draws: Array[float] = []
		var tris: Array[float] = []
		var last := Time.get_ticks_usec()
		for i in range(90):
			await process_frame
			var now := Time.get_ticks_usec()
			wall.append(float(now-last)/1000.0); last = now
			draws.append(float(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)))
			tris.append(float(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)))
			if gpu_supported:
				gpu.append(float(RenderingServer.call("viewport_get_measured_render_time_gpu",rid)))
				cpu.append(float(RenderingServer.call("viewport_get_measured_render_time_cpu",rid)))
		wall.sort()
		await save_picture(shot)
		rows.append({"shot":shot,"camera_size":camera.size,"samples":90,"wall_median_ms":wall[45],"wall_p95_ms":wall[85],"gpu_mean_ms":sum_values(gpu)/90.0 if not gpu.is_empty() else null,"render_cpu_mean_ms":sum_values(cpu)/90.0 if not cpu.is_empty() else null,"draw_calls_mean":sum_values(draws)/90.0,"primitives_mean":sum_values(tris)/90.0})
	var valid: bool = cells==world_data["cells"] and world_ranges.size()==25 and hex_assemblies.size()==143
	var report := {"mode":"before" if before_mode() else "after","engine":Engine.get_version_info(),"gpu":RenderingServer.get_video_adapter_name(),"viewport":[root.size.x,root.size.y],"layout_sha256":FileAccess.get_sha256(WORLD_OUT.path_join("world-map.json")),"logical_layout_unchanged":cells==world_data["cells"],"resident_ranges":world_ranges.size(),"village_farm_assemblies":hex_assemblies.size(),"water":water_report,"shots":rows,"limits":"Uncapped Godot debug Forward+ scenery-only workload; all mountain/settlement LOD0 locked, no combat; background applications not isolated. GPU and wall observations are not a release-build FPS guarantee."}
	var path := SHORE_DIR.path_join("before-report.json" if before_mode() else "after-report.json")
	var f := FileAccess.open(path,FileAccess.WRITE)
	f.store_string(JSON.stringify(report,"\t")); f.close()
	print("[ShorelineWorld] capture complete; invariants=",valid," output=",path)
	quit(0 if valid else 2)
