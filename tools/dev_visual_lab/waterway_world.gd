extends "res://tools/dev_visual_lab/all_ranges_world.gd"
const Waterway = preload("res://tools/dev_visual_lab/source_waterway.gd")
var waterway: RefCounted
var water_report: Dictionary
var extraction: Array = []
var removed_legacy_water := 0
var freeze_flow := false

func _process(delta: float) -> bool:
	var result := super._process(delta)
	if waterway!=null and not freeze_flow: waterway.advance_flow(delta)
	return result

func boot() -> void:
	print("[WaterwayWorld] boot args=",OS.get_cmdline_user_args())
	DirAccess.make_dir_recursive_absolute(Waterway.OUT)
	await super.boot()
	root.title = "StrategyGame | Continuous Rock Banks + Animated Current"
	if not capture_mode:
		target = center(0,0); camera.size = 160; orbit = 0.78; update_camera()
		await wait_frames(12)
		await save_picture("interactive")

func make_ui() -> void:
	super.make_ui()
	var column: VBoxContainer = info.get_parent()
	for shot in [["강둑과 물결: 굽이",Vector2i(2,17),100.0],["강둑과 물결: 다리",Vector2i(0,0),130.0]]:
		var button := Button.new()
		button.text = shot[0]
		button.pressed.connect(func():
			target = center(shot[1].x,shot[1].y); camera.size = shot[2]
			yaw = 0.12; orbit = 0.78; update_camera())
		column.add_child(button)

func cell_color(cell: Dictionary) -> Color:
	if cell["kind"]!="river": return super.cell_color(cell)
	var as_ground := cell.duplicate()
	as_ground["kind"] = "plain"
	return super.cell_color(as_ground)

func ribbon(st: SurfaceTool,a: Vector3,b: Vector3,width: float,color: Color,y: float) -> void:
	if is_equal_approx(width,10.0) and is_equal_approx(y,0.08): return
	super.ribbon(st,a,b,width,color,y)

func build_terrain() -> void:
	print("[WaterwayWorld] building water banks")
	super.build_terrain()
	# Existing bridge shells stay. Remove their baked water sheets so there
	# is exactly one water surface authority under every crossing.
	for node in land.find_children("*","MeshInstance3D",true,false):
		var name := String(node.name).to_lower()
		if name.ends_with("_water") or name.ends_with("_foam") or name.ends_with("_flow"):
			node.visible = false
			removed_legacy_water += 1
	waterway = make_waterway()
	extraction = waterway.extract_all()
	water_report = waterway.create_channel(cells,Callable(self,"center"),land)
	print("[WaterwayWorld] extracted=",extraction.size()," legacy_sheets_hidden=",removed_legacy_water," continuous_triangles=",water_report["triangles"])

func make_waterway() -> RefCounted:
	return Waterway.new()

func save_picture(name: String) -> void:
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(Waterway.OUT.path_join(name+".png"))

func capture_suite() -> void:
	print("[WaterwayWorld] capture 225 animation frames")
	ui.visible = false
	lock_detail = true
	show_world()
	await wait_frames(12)
	await save_picture("world-overview")
	for shot in [["crossing",Vector2i(0,0),160.0],["northern-bend",Vector2i(2,17),165.0],["southern-bend",Vector2i(-2,-17),165.0]]:
		target = center(shot[1].x,shot[1].y)
		camera.size = shot[2]
		yaw = 0.12; orbit = 0.78; update_camera()
		await wait_frames(8)
		await save_picture(shot[0])
	# Deterministic native-rendered animation, same material as interactive view.
	freeze_flow = true
	target = center(2,17); camera.size = 100.0
	yaw = 0.12; orbit = 0.78; update_camera()
	DirAccess.make_dir_recursive_absolute(Waterway.OUT.path_join("animation"))
	for i in range(225):
		waterway.set_flow_time(float(i)*0.1)
		await wait_frames(2)
		await RenderingServer.frame_post_draw
		var image := root.get_texture().get_image()
		image.resize(960,540,Image.INTERPOLATE_BILINEAR)
		image.save_png(Waterway.OUT.path_join("animation/frame_%03d.png" % i))
	var f := FileAccess.open(Waterway.OUT.path_join("waterway-receipt.json"),FileAccess.WRITE)
	f.store_string(JSON.stringify({"engine":Engine.get_version_info(),"gpu":RenderingServer.get_video_adapter_name(),"layout_sha256":FileAccess.get_sha256(WORLD_OUT.path_join("world-map.json")),"logical_layout_unchanged":cells==world_data["cells"],"ranges_resident":world_ranges.size(),"legacy_water_meshes_hidden":removed_legacy_water,"extracted":extraction,"continuous_water":water_report,"scope":"Water-only first visual pass on unchanged DEV map; original assets and mission maps remain untouched"},"\t"))
	f.close()
	quit(0 if cells==world_data["cells"] and extraction.size()==6 and water_report.get("banks",{}).get("instances",0)>0 else 2)
