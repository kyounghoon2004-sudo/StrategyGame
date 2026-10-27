extends "res://tools/dev_visual_lab/hex_mountain_context.gd"
## All 25 variants coexist on ONE contiguous R40 scenery/benchmark map.
const WORLD_OUT := "C:/Users/User/Documents/Codex/2026-10-18/strategygame-godot-4-2-2-repo/outputs/all-ranges-world"
const ASSET_OUT := "C:/Users/User/Documents/Codex/2026-10-18/strategygame-godot-4-2-2-repo/outputs/mountain-range-25"
var world_data: Dictionary
var world_catalog: Array
var world_ranges: Array = []
var shared_rocks: RefCounted
var lock_detail := false
var bookmarks: OptionButton
var benchmark_running := false
var last_lod_counts := [0,0,0]
var world_build_ms := 0
var report_label: Label

func boot() -> void:
	lock_detail = "--all-lod0" in OS.get_cmdline_user_args()
	world_data = JSON.parse_string(FileAccess.get_file_as_string(WORLD_OUT.path_join("world-map.json")))
	world_catalog = JSON.parse_string(FileAccess.get_file_as_string(KIT_PATH.path_join("range25/catalog.json")))["catalog"]
	await super.boot()
	root.title = "StrategyGame | All 25 Ranges - R40 World"
	if not capture_mode:
		show_world()
		await wait_frames(15)
		await save_picture("interactive")

func make_ui() -> void:
	super.make_ui()
	var column: VBoxContainer = info.get_parent()
	for child in column.get_children(): child.visible = false
	var title := Label.new()
	title.text = "25종 모두 · 하나의 월드\nR40 / 4,921 HEXES"
	title.add_theme_font_size_override("font_size",22)
	column.add_child(title)
	var help := Label.new()
	help.text = "휠: 확대/축소 · 우클릭: 회전\nWASD: 이동 · Home: 전체 맵\n25종 상주 / 선택은 카메라 이동만"
	column.add_child(help)
	var overview := Button.new()
	overview.text = "전체 월드 보기"
	overview.pressed.connect(show_world)
	column.add_child(overview)
	bookmarks = OptionButton.new()
	bookmarks.add_item("산맥으로 카메라 이동…")
	for item in world_catalog: bookmarks.add_item(str(item["shapeLabel"])+" · "+str(item["sizeLabel"]))
	bookmarks.item_selected.connect(func(i):
		if i>0: focus_range(i-1))
	column.add_child(bookmarks)
	var detail := Button.new()
	detail.text = "부하 비교: 모든 산맥 LOD0 고정"
	detail.toggle_mode = true
	detail.button_pressed = lock_detail
	detail.toggled.connect(func(enabled): lock_detail = enabled; update_lod())
	column.add_child(detail)
	var benchmark := Button.new()
	benchmark.text = "고정 3시점 기준값 측정 / 저장"
	benchmark.pressed.connect(func():
		if not benchmark_running: run_baseline(false))
	column.add_child(benchmark)
	report_label = Label.new()
	report_label.text = "측정값은 baseline*.json에 저장됩니다.\n프레임 비교는 같은 모드·카메라로."
	report_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(report_label)
	info.visible = true
	status.visible = true
	column.move_child(info,column.get_child_count()-1)
	column.move_child(status,column.get_child_count()-1)

func generate() -> void:
	var started := Time.get_ticks_msec()
	cells = world_data["cells"].duplicate(true)
	source_cells = JSON.parse_string(FileAccess.get_file_as_string(out.path_join("edited-hex-map.json")))["cells"]
	seed_value = 20261018
	density = 0.86
	meander = 23
	terrain_noise.seed = seed_value
	terrain_noise.frequency = 0.018
	moisture.seed = seed_value+974
	moisture.frequency = 0.032
	tile_lookup.clear()
	for i in range(cells.size()): tile_lookup[hex_key(cells[i]["q"],cells[i]["r"])] = i
	recompose()
	world_build_ms = Time.get_ticks_msec()-started
	info.text = "4,921헥스 · 25종 동시 배치\n신규 산 340칸 / 바위 %d개\n환경 소품 %d개 / 유닛 없음\n시드 20261019 · 원본 중심 113칸 유지" % [total_rocks(),document.size()]
	print("[AllRangesWorld] ready ",world_ranges.size()," ranges, ",cells.size()," hexes, ",document.size()," props, ",world_build_ms," ms")

func add_prop(cell: Dictionary,key: String,local: Vector2,width: float,angle: float = 0) -> void:
	# Keep the reviewed core density. Expanded woodlands use the same trees
	# with a fixed sparse stream, instead of multiplying the small-map density.
	if Lib.TREES.has(key) and (absi(int(cell["q"]))>6 or absi(int(cell["r"]))>5):
		var token := "%d,%d|%d,%d" % [cell["q"],cell["r"],roundi(local.x*10),roundi(local.y*10)]
		if posmod(token.hash(),3)!=0: return
	super.add_prop(cell,key,local,width,angle)

func build_terrain() -> void:
	build_board_only()
	if not world_ranges.is_empty(): return
	shared_rocks = RockDressing.new()
	shared_rocks.load_variants()
	for placement in world_data["ranges"]:
		var item: Dictionary = world_catalog[int(placement["catalogIndex"])]
		var group := Node3D.new()
		group.name = str(item["id"])
		group.scale = Vector3.ONE*(R/24.0)
		group.rotation.y = -float(placement["rotationSteps"])*PI/3.0
		group.position = center(placement["offset"][0],placement["offset"][1])+Vector3.UP*0.055
		stage.add_child(group)
		var lods: Array[Node3D] = []
		var rock_count := 0
		for lod in range(3):
			var document := GLTFDocument.new()
			var state := GLTFState.new()
			var path: String = ASSET_OUT.path_join(str(placement["source"])) if lod==0 else KIT_PATH.path_join("range25/"+str(item["files"][lod]["file"]))
			if lod==0: assert(FileAccess.get_sha256(path)==str(placement["source_sha256"]),"Asset changed: record a new candidate manifest")
			assert(document.append_from_file(path,state)==OK)
			var model := document.generate_scene(state) as Node3D
			group.add_child(model)
			if lod==0: rock_count = batch_existing_rocks(model)
			var meshes := model.find_children("*","MeshInstance3D",true,false)
			assert(meshes.size()==int(item["hexCount"]),"Expected exactly one mountain mesh per owned hex")
			for mesh in meshes: mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			model.visible = lod==2
			lods.append(model)
		var bounds := {"min":Vector3(INF,INF,INF),"max":Vector3(-INF,-INF,-INF)}
		Lib._accumulate_aabb(lods[0],Transform3D.IDENTITY,bounds)
		var c: Array = placement["centroid"]
		world_ranges.append({"id":item["id"],"group":group,"lods":lods,"lod":2,"rocks":rock_count,"hexes":item["hexCount"],"focus":center(roundi(c[0]),roundi(c[1])),"span":(bounds["max"]-bounds["min"]).length()*(R/24.0)})
		if world_ranges.size()%5==0: print("[AllRangesWorld] imported ",world_ranges.size(),"/25 ranges")

func batch_existing_rocks(model: Node3D) -> int:
	var groups: Array = [[],[],[],[]]
	var inverse := model.global_transform.affine_inverse()
	var count := 0
	for node in model.find_children("*","MeshInstance3D",true,false):
		var mesh: Mesh = node.mesh
		var triangles := Lib.mesh_triangles(mesh)
		if triangles>32: continue
		var which := -1
		var error := INF
		for i in range(shared_rocks.variants.size()):
			var prototype: Mesh = shared_rocks.variants[i]
			var distance := prototype.get_aabb().size.distance_to(mesh.get_aabb().size)
			if distance<error: error = distance; which = i
		assert(which>=0 and error<0.001,"Unknown rock prototype; do not silently remove it")
		groups[which].append(inverse*node.global_transform)
		count += 1
		node.get_parent().remove_child(node)
		node.free()
	for i in range(4):
		if groups[i].is_empty(): continue
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = shared_rocks.variants[i]
		mm.instance_count = groups[i].size()
		for n in range(mm.instance_count): mm.set_instance_transform(n,groups[i][n])
		var node := MultiMeshInstance3D.new()
		node.multimesh = mm
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		model.add_child(node)
	return count

func total_rocks() -> int:
	var total := 0
	for item in world_ranges: total += int(item["rocks"])
	return total

func update_camera() -> void:
	if camera==null: return
	var direction := Vector3(sin(yaw)*cos(orbit),sin(orbit),cos(yaw)*cos(orbit))
	camera.near = 0.1
	camera.far = 12000
	camera.position = target+direction*5000
	camera.look_at(target)
	update_lod()

func update_lod() -> void:
	super.update_lod()
	last_lod_counts = [0,0,0]
	for item in world_ranges:
		var distance: float = target.distance_to(item["focus"])
		var desired := 0 if lock_detail else (2 if camera.size>450 or distance>camera.size*0.85 else (1 if camera.size>150 else 0))
		if desired!=int(item["lod"]):
			for i in range(3): item["lods"][i].visible = i==desired
			item["lod"] = desired
		last_lod_counts[desired] += 1

func show_world() -> void:
	target = Vector3.ZERO
	yaw = 0.12
	orbit = 1.05
	camera.size = 2400
	update_camera()

func focus_range(index: int) -> void:
	target = world_ranges[index]["focus"]
	yaw = 0.12
	orbit = 0.78
	camera.size = clampf(float(world_ranges[index]["span"])*0.7,110,520)
	update_camera()

func _input(event: InputEvent) -> void:
	if camera==null or benchmark_running: return
	if event is InputEventMouseButton:
		if ui.get_global_rect().has_point(event.position): return
		if event.pressed and event.button_index==MOUSE_BUTTON_WHEEL_UP: camera.size = maxf(40,camera.size*0.86); update_camera()
		if event.pressed and event.button_index==MOUSE_BUTTON_WHEEL_DOWN: camera.size = minf(2800,camera.size/0.86); update_camera()
		if event.button_index==MOUSE_BUTTON_RIGHT: rotating = event.pressed
	if event is InputEventMouseMotion and rotating:
		yaw -= event.relative.x*0.006
		orbit = clampf(orbit+event.relative.y*0.004,0.35,1.42)
		update_camera()
	if event is InputEventKey and event.pressed and event.keycode==KEY_HOME: show_world()

func handle_hex_input(_event: InputEvent) -> void:
	pass # Read-only fixed visual workload; no accidental painting or dragging.

func _process(delta: float) -> bool:
	if benchmark_running: return false # Freeze keyboard pan during fixed shots.
	return super._process(delta)

func save_picture(name: String) -> void:
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(WORLD_OUT.path_join(("lod0-" if lock_detail else "")+name+".png"))

func capture_suite() -> void:
	await run_baseline(true)

func run_baseline(exit_after: bool) -> void:
	benchmark_running = true
	var restore_target := target
	var restore_size := camera.size
	var restore_yaw := yaw
	var restore_orbit := orbit
	ui.visible = false
	var rid := root.get_viewport_rid()
	var gpu_supported := RenderingServer.has_method("viewport_set_measure_render_time")
	if gpu_supported: RenderingServer.call("viewport_set_measure_render_time",rid,true)
	var rows: Array = []
	for shot in ["overview","central_valley","long_range"]:
		if shot=="overview": show_world()
		elif shot=="central_valley": target = center(0,1); camera.size = 430; yaw = 0.12; orbit = 0.85; update_camera()
		else: focus_range(24)
		await wait_frames(45)
		var samples: Array = []
		var render_cpu: Array = []
		var render_gpu: Array = []
		var draws: Array = []
		var primitives: Array = []
		for i in range(120):
			var started := Time.get_ticks_usec()
			await process_frame
			samples.append((Time.get_ticks_usec()-started)/1000.0)
			draws.append(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
			primitives.append(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
			if gpu_supported:
				render_cpu.append(RenderingServer.call("viewport_get_measured_render_time_cpu",rid))
				render_gpu.append(RenderingServer.call("viewport_get_measured_render_time_gpu",rid))
		samples.sort()
		await save_picture(shot)
		rows.append({"shot":shot,"camera":{"target":[target.x,target.y,target.z],"size":camera.size,"yaw":yaw,"orbit":orbit},"samples":120,"wall_frame_median_ms":samples[60],"wall_frame_p95_ms":samples[114],"render_cpu_mean_ms":sum_values(render_cpu)/120 if not render_cpu.is_empty() else null,"render_gpu_mean_ms":sum_values(render_gpu)/120 if not render_gpu.is_empty() and sum_values(render_gpu)>0 else null,"draw_calls_mean":sum_values(draws)/120,"primitives_mean":sum_values(primitives)/120,"resident_ranges":world_ranges.size(),"ranges_per_lod":last_lod_counts.duplicate(),"lod0_locked":lock_detail})
		print("[AllRangesWorld] measured ",shot," median_ms=",samples[60])
	var core_ok := true
	for original in source_cells:
		var current: Dictionary = cells[tile_lookup[hex_key(original["q"],original["r"])]]
		if current!=original: core_ok = false
	var f := FileAccess.open(WORLD_OUT.path_join("baseline-lod0.json" if lock_detail else "baseline.json"),FileAccess.WRITE)
	f.store_string(JSON.stringify({"engine":Engine.get_version_info(),"gpu":RenderingServer.get_video_adapter_name(),"layout_sha256":FileAccess.get_sha256(WORLD_OUT.path_join("world-map.json")),"viewport":[root.size.x,root.size.y],"hexes":cells.size(),"ranges":world_ranges.size(),"new_mountain_hexes":340,"rocks":total_rocks(),"props":document.size(),"logical_counts":world_data["counts"],"build_ms":world_build_ms,"original_core_unchanged":core_ok,"unique_cells":tile_lookup.size()==cells.size(),"timestamps_supported":gpu_supported,"debug_build":OS.is_debug_build(),"vsync":false,"shots":rows,"limits":"Scenery-only DEV workload, no units/AI/combat. Background applications not isolated. Baseline observations, no optimization speedup claimed."},"\t"))
	f.close()
	ui.visible = true
	benchmark_running = false
	target = restore_target; camera.size = restore_size; yaw = restore_yaw; orbit = restore_orbit
	update_camera()
	if report_label!=null: report_label.text = "측정 완료: %s\n고정 시점 3개 × 120프레임" % ["baseline-lod0.json" if lock_detail else "baseline.json"]
	if exit_after: quit(0 if world_ranges.size()==25 and cells.size()==4921 and core_ok else 2)
