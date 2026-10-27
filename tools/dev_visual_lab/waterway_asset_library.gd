extends "res://tools/dev_visual_lab/mountain_line_library.gd"
## The existing asset library, with an interactive river entry and free camera.
const Waterway = preload("res://tools/dev_visual_lab/source_waterway.gd")
var river_index := -1
var river: RefCounted
var view_target := Vector3(0,1,0)
var view_yaw := 0.35
var view_pitch := 0.65
var orbit_drag := false
var pan_drag := false

func boot() -> void:
	river_index = entries.size()
	entries.append({"id":"continuous_rock_banks","kind":"composition","family":"waterway","role":"interactive_waterway","path":"물길 · 이어지는 돌 강둑 + 움직이는 물결"})
	await super.boot()
	root.title = "StrategyGame | Asset Library - Interactive"
	root.size = Vector2i(1440,960)
	viewport.size = Vector2i(1280,800)
	preview_rect.custom_minimum_size = Vector2(1280,800)
	preview_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var column := picker.get_parent()
	for child in column.get_children():
		if child is Label and child!=title:
			child.text = "Wheel: zoom | Right drag: orbit | Middle drag: pan | Home: reset | Left/Right: asset | Esc: close"
	var button := Button.new()
	button.text = "물길: 돌 강둑과 물결 보기"
	button.pressed.connect(select_asset.bind(river_index))
	column.add_child(button)
	column.move_child(button,picker.get_index()+1)
	select_asset(river_index)
	print("[InteractiveAssetLibrary] ready: river, zoom, orbit, pan; capture=",capture)
	if "--verify-controls" in OS.get_cmdline_user_args(): await verify_controls()

func composition(item: Dictionary) -> Node3D:
	if item.get("family","")!="waterway": return super.composition(item)
	river = Waterway.new()
	var world: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("C:/Users/User/Documents/Codex/2026-10-18/strategygame-godot-4-2-2-repo/outputs/all-ranges-world/world-map.json"))
	var selected: Array = []
	for cell in world["cells"]:
		if cell["kind"]=="river" and int(cell["r"])>=12 and int(cell["r"])<=22: selected.append(cell)
	var model := Node3D.new()
	river.create_channel(selected,func(q,r): return Vector3(27.0*q,0,sqrt(3.0)*18.0*(r+q*0.5)),model,false)
	return model

func set_camera() -> void:
	if camera==null: return
	view_target = Vector3(0,1,0)
	view_yaw = 0.35; view_pitch = 0.65
	camera.size = 12.0
	update_view()

func update_view() -> void:
	camera.position = view_target+Vector3(sin(view_yaw)*cos(view_pitch),sin(view_pitch),cos(view_yaw)*cos(view_pitch))*40.0
	camera.look_at(view_target,Vector3.UP)

func apply_view_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index==MOUSE_BUTTON_RIGHT: orbit_drag = event.pressed
		if event.button_index==MOUSE_BUTTON_MIDDLE: pan_drag = event.pressed
		if event.pressed and event.button_index==MOUSE_BUTTON_WHEEL_UP: camera.size = maxf(0.4,camera.size/1.15)
		if event.pressed and event.button_index==MOUSE_BUTTON_WHEEL_DOWN: camera.size = minf(100.0,camera.size*1.15)
	elif event is InputEventMouseMotion:
		if orbit_drag:
			view_yaw -= event.relative.x*0.008
			view_pitch = clampf(view_pitch+event.relative.y*0.008,0.12,1.48)
		if pan_drag:
			view_target += (-camera.global_basis.x*event.relative.x+camera.global_basis.y*event.relative.y)*camera.size/800.0
		update_view()
	elif event is InputEventKey and event.pressed and event.keycode==KEY_HOME: set_camera()

func _process(delta: float) -> bool:
	var result := super._process(delta)
	if river!=null: river.advance_flow(delta)
	return result

func verify_controls() -> void:
	await wait_frames(5)
	var before := camera.size
	var wheel := InputEventMouseButton.new()
	wheel.button_index = MOUSE_BUTTON_WHEEL_UP; wheel.pressed = true
	apply_view_input(wheel)
	assert(camera.size<before)
	orbit_drag = true
	var motion := InputEventMouseMotion.new(); motion.relative = Vector2(35,10)
	apply_view_input(motion); orbit_drag = false
	assert(not is_equal_approx(view_yaw,0.35))
	pan_drag = true; apply_view_input(motion); pan_drag = false
	assert(view_target.distance_to(Vector3(0,1,0))>0.01)
	set_camera()
	await wait_frames(3)
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(Waterway.OUT.path_join("interactive-library.png"))
	print("[InteractiveAssetLibrary] PASS zoom/orbit/pan/reset; loaded=",info.get("loaded",false))
	# Stays open for the user after verifying the actual camera handlers.

func _initialize() -> void:
	super._initialize()
	root.connect("window_input",apply_view_input)
