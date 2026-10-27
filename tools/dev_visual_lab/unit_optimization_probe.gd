extends SceneTree
## Reproducible DEV-only unit workload. Never instantiates a battlefield.
const Foot = preload("res://scripts/visual/civ3d/civ_formation3d.gd")
const Mount = preload("res://scripts/visual/civ3d/civ_cavalry3d.gd")
const OUT := "C:/Users/User/Documents/Codex/2026-10-18/strategygame-godot-4-2-2-repo/outputs/unit-import-optimization"
const KINDS := ["infantry","spearman","archer","conscript","scout","cavalry","hq"]
var stage: Node3D
var units: Array = []
var camera: Camera3D
var optimized := false
var results: Array = []
var vp: RID

func _initialize() -> void:
	optimized = "--optimized" in OS.get_cmdline_user_args()
	call_deferred("boot")

func boot() -> void:
	seed(20261019)
	root.size = Vector2i(1600,900)
	root.title = "StrategyGame | Unit optimization measurement"
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	root.msaa_3d = Viewport.MSAA_2X
	stage = Node3D.new(); root.add_child(stage)
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color("35464a")
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_energy = 0.65
	stage.add_child(environment)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50,-35,0); sun.light_energy = 1.05
	sun.shadow_enabled = false; stage.add_child(sun)
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new(); plane.size = Vector2(180,180)
	ground.mesh = plane
	var mat := StandardMaterial3D.new(); mat.albedo_color = Color("798451"); mat.roughness = 1.0
	ground.material_override = mat; ground.position.y = -0.05; stage.add_child(ground)
	camera = Camera3D.new(); camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.far = 2000; stage.add_child(camera); camera.make_current()
	var adapter: Script = load("res://tools/dev_visual_lab/unit_lod_formation.gd") if optimized else null
	for row in range(4):
		for column in range(KINDS.size()):
			var kind: String = KINDS[column]
			var node: Node3D = adapter.new() if optimized else (Mount.new() if kind in ["cavalry","hq"] else Foot.new())
			stage.add_child(node)
			node.position = Vector3((float(column)-3.0)*14.0,0,(float(row)-1.5)*18.0)
			var count := 1 if kind=="hq" else (3 if kind=="cavalry" else 9)
			node.call("setup",kind,"blue" if row%2==0 else "red",count,2.2,Vector3(0,0,1),20261019+row*7+column)
			var formation: Array = []
			for i in range(count): formation.append(Vector3((float(i%3)-1.0)*2.3,0,(float(i/3)-1.0)*2.8))
			if count==1: formation = [Vector3.ZERO]
			node.call("place",formation)
			units.append(node)
	if optimized:
		for i in range(10): await process_frame
		for unit in units: unit.call("prewarm_proxy")
		adapter.call("release_source_prototypes")
	vp = root.get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(vp,true)
	DirAccess.make_dir_recursive_absolute(OUT)
	for scenario in [["near",0,80.0],["mid",1,160.0],["far",2,300.0]]:
		camera.size = float(scenario[2]); camera.position = Vector3(70,100,130); camera.look_at(Vector3.ZERO)
		if optimized:
			for unit in units: unit.call("set_detail",int(scenario[1]))
		await measure(str(scenario[0]))
	var file := FileAccess.open(OUT.path_join("optimized-metrics.json" if optimized else "baseline-metrics.json"),FileAccess.WRITE)
	file.store_string(JSON.stringify({"engine":Engine.get_version_info(),"gpu":RenderingServer.get_video_adapter_name(),"resolution":[1600,900],"formations":28,"figure_slots":196,"seed":20261019,"vsync":false,"shadow_light":false,"build":"Godot 4.2.2 desktop debug runtime, not a release benchmark","rows":results},"\t")); file.close()
	for unit in units:
		if unit.has_method("cleanup"): unit.call("cleanup")
		unit.free()
	units.clear()
	if optimized: adapter.call("clear_caches")
	else:
		if Foot._dog_proto!=null: Foot._dog_proto.free(); Foot._dog_proto = null
		if Mount._horse_proto!=null: Mount._horse_proto.free(); Mount._horse_proto = null
	await process_frame
	quit()

func measure(view: String) -> void:
	for i in range(45): await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(OUT.path_join(("optimized-" if optimized else "baseline-")+view+".png"))
	var wall: Array[float] = []
	var gpu := 0.0; var cpu := 0.0; var draws := 0.0; var triangles := 0.0; var process := 0.0
	var last := Time.get_ticks_usec()
	for i in range(120):
		await process_frame
		var now := Time.get_ticks_usec(); wall.append(float(now-last)/1000.0); last = now
		gpu += RenderingServer.viewport_get_measured_render_time_gpu(vp)
		cpu += RenderingServer.viewport_get_measured_render_time_cpu(vp)
		process += Performance.get_monitor(Performance.TIME_PROCESS)*1000.0
		draws += Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
		triangles += Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
	wall.sort()
	var row := {"view":view,"wall_p50_ms":wall[60],"wall_p95_ms":wall[114],"gpu_ms":gpu/120.0,"render_cpu_ms":cpu/120.0,"legacy_time_process_ms_includes_startup":process/120.0,"draw_calls":draws/120.0,"triangles":triangles/120.0}
	row["video_memory_bytes"] = Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED)
	results.append(row); print("[UnitProbe] ",JSON.stringify(row))
