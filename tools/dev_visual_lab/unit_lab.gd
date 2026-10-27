extends SceneTree
## Isolated visual DEV stage. Never loads a battlefield or writes gameplay/assets.
const Foot = preload("res://scripts/visual/civ3d/civ_formation3d.gd")
const Mount = preload("res://scripts/visual/civ3d/civ_cavalry3d.gd")
const CASES := [
	["infantry", "CIV3D Infantry / 9", "foot", "infantry", 9],
	["spearman", "CIV3D Spearmen / 9", "foot", "spearman", 9],
	["archer", "CIV3D Archers / 9", "foot", "archer", 9],
	["conscript", "CIV3D Militia / 9", "foot", "conscript", 9],
	["scout", "CIV3D Scouts / 6 humans + 3 dogs", "foot", "scout", 9],
	["cavalry", "CIV3D Cavalry / 3 riders + horses", "mount", "cavalry", 3],
	["hq", "CIV3D Mounted Commander / 1", "mount", "hq", 1],
	["formation20", "Native formation / 20", "scene", "res://scenes/formation_v0/formation_20man.tscn", 20],
	["sword20", "Sword charge formation / 20", "scene", "res://scenes/sword_charge_v0/attacker_20man.tscn", 20],
]
var stage: Node3D
var model: Node3D
var camera: Camera3D
var title: Label
var status: Label
var picker: OptionButton
var index := 0
var far_view := false
var marching := false
var capturing := false
var out := ""
var records: Array = []
var last_keys: Dictionary = {}

func _initialize() -> void:
	root.size = Vector2i(1600, 900)
	root.title = "StrategyGame - DEV Unit Asset Lab (isolated)"
	out = OS.get_environment("SG_DEV_LAB_OUT")
	if out == "": out = ProjectSettings.globalize_path("res://artifacts/dev_visual_lab")
	capturing = "--capture" in OS.get_cmdline_user_args()
	call_deferred("boot")

func boot() -> void:
	stage = Node3D.new()
	root.add_child(stage)
	var world := WorldEnvironment.new()
	world.environment = Environment.new()
	world.environment.background_mode = Environment.BG_COLOR
	world.environment.background_color = Color("b9b8ad")
	world.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	world.environment.ambient_light_color = Color("eee9dd")
	world.environment.ambient_light_energy = 0.65
	stage.add_child(world)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, -35, 0)
	sun.light_energy = 1.15
	sun.shadow_enabled = true
	stage.add_child(sun)
	var floor_node := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(160, 160)
	floor_node.mesh = plane
	var material := StandardMaterial3D.new()
	material.albedo_color = Color("797d68")
	material.roughness = 1.0
	floor_node.material_override = material
	floor_node.position.y = -0.06
	stage.add_child(floor_node)
	camera = Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	stage.add_child(camera)
	camera.make_current()
	root.msaa_3d = Viewport.MSAA_2X
	var ui := CanvasLayer.new()
	root.add_child(ui)
	var panel := PanelContainer.new()
	panel.position = Vector2(18, 18)
	ui.add_child(panel)
	var box := VBoxContainer.new()
	panel.add_child(box)
	title = Label.new()
	title.add_theme_font_size_override("font_size", 24)
	box.add_child(title)
	picker = OptionButton.new()
	for item in CASES: picker.add_item(item[1])
	picker.item_selected.connect(select_case)
	box.add_child(picker)
	var help := Label.new()
	help.text = "DEV ONLY | No maps / combat state\nLeft / Right: asset | Space: attack | M: march | H: hit | F: near / far | Esc: exit"
	box.add_child(help)
	status = Label.new()
	box.add_child(status)
	select_case(0)
	if capturing: await capture_all()

func select_case(which: int) -> void:
	if model != null:
		stage.remove_child(model)
		model.free()
	index = posmod(which, CASES.size())
	var item: Array = CASES[index]
	model = Foot.new() if item[2] == "foot" else Mount.new() if item[2] == "mount" else (load(item[3]) as PackedScene).instantiate()
	stage.add_child(model)
	if item[2] in ["foot", "mount"]:
		model.call("setup", item[3], "blue", int(item[4]), 1.65, Vector3(0, 0, 1), 20261018)
		var points: Array = []
		var cols := 3
		var rows := ceili(float(item[4]) / cols)
		for i in range(int(item[4])):
			points.append(Vector3((float(i % cols) - 1.0) * 1.35, 0, (float(i / cols) - (rows - 1) * 0.5) * 1.65))
		if int(item[4]) == 1: points = [Vector3.ZERO]
		model.call("place", points)
	marching = false
	far_view = false
	set_camera()
	picker.select(index)
	title.text = "%02d / %02d  %s" % [index + 1, CASES.size(), item[1]]
	print("[DevUnitLab] loaded ", item[0])

func set_camera() -> void:
	camera.size = 28.0 if far_view else (4.4 if int(CASES[index][4]) == 1 else 10.5)
	camera.position = Vector3(9, 12, 18) if far_view else Vector3(7, 5, 10)
	camera.look_at(Vector3(0, 0.8, 0))

func attack() -> bool:
	if model.has_method("play_attack"): model.call("play_attack"); return true
	if model.has_method("trigger_attack"): model.call("trigger_attack"); return true
	if model.has_method("attack_visual"): model.call("attack_visual", Vector3(0, 0, 7.8)); return true
	if model.has_method("attack"): model.call("attack"); return true
	return false

func pressed(key: int) -> bool:
	var down := Input.is_key_pressed(key)
	var before: bool = last_keys.get(key, false)
	last_keys[key] = down
	return down and not before

func _process(_delta: float) -> bool:
	if model == null: return false
	if not capturing:
		if pressed(KEY_ESCAPE): call_deferred("finish")
		if pressed(KEY_RIGHT): select_case(index + 1)
		if pressed(KEY_LEFT): select_case(index - 1)
		if pressed(KEY_F): far_view = not far_view; set_camera()
		if pressed(KEY_SPACE): attack()
		if pressed(KEY_H) and model.has_method("play_hit"): model.call("play_hit")
		if pressed(KEY_M) and model.has_method("set_moving"):
			marching = not marching
			model.call("set_moving", marching)
			model.call("set_speed", 1.2 if marching else 0.0)
	status.text = "%d FPS | %d draw calls | %s primitives | camera %.1f" % [Engine.get_frames_per_second(), Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME), str(int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))), camera.size]
	return false

func wait_frames(count: int) -> void:
	for i in range(count): await process_frame

func save_image(suffix: String) -> String:
	await RenderingServer.frame_post_draw
	var path := out.path_join(String(CASES[index][0]) + "_" + suffix + ".png")
	var err := root.get_texture().get_image().save_png(path)
	assert(err == OK, "Cannot save " + path)
	return path

func node_stats(node: Node) -> Dictionary:
	var result := {"mesh_nodes": 0, "skeletons": 0, "bones": 0, "animation_players": 0, "clips": []}
	var pending: Array[Node] = [node]
	while not pending.is_empty():
		var n: Node = pending.pop_back()
		if n is MeshInstance3D: result.mesh_nodes += 1
		if n is Skeleton3D: result.skeletons += 1; result.bones += n.get_bone_count()
		if n is AnimationPlayer:
			result.animation_players += 1
			for clip in n.get_animation_list():
				if clip not in result.clips: result.clips.append(clip)
		for child in n.get_children(): pending.append(child)
	return result

func capture_all() -> void:
	DirAccess.make_dir_recursive_absolute(out)
	for which in range(CASES.size()):
		if which != 0: select_case(which)
		await wait_frames(25)
		var row: Dictionary = {"id": CASES[index][0], "name": CASES[index][1], "count": CASES[index][4], "structure": node_stats(model)}
		row["near"] = await save_image("near")
		var samples: Array = []
		var last := Time.get_ticks_usec()
		for frame in range(60):
			await process_frame
			var now := Time.get_ticks_usec()
			samples.append({"wall_ms": (now - last) / 1000.0, "draw_calls": Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME), "primitives": Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)})
			last = now
		row["near_samples"] = samples
		row["pose_before"] = pose_signature(model)
		var anchor_before := model.transform
		row["attack_invoked"] = attack()
		await create_timer(0.45).timeout
		row["attack"] = await save_image("attack")
		row["pose_after"] = pose_signature(model)
		row["bone_pose_changed"] = row["pose_before"] != row["pose_after"]
		row["root_anchor_unchanged"] = model.transform.is_equal_approx(anchor_before)
		far_view = true
		set_camera()
		await wait_frames(15)
		row["far"] = await save_image("far")
		row["far_draw_calls"] = Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
		row["far_primitives"] = Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
		records.append(row)
		print("[DevUnitLab] captured ", row.id)
	var f := FileAccess.open(out.path_join("runtime-receipt.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify({"engine": Engine.get_version_info(), "gpu": RenderingServer.get_video_adapter_name(), "resolution": [int(root.get_texture().get_width()), int(root.get_texture().get_height())], "note": "Independent DEV stage, full detail at both camera sizes; timings are uncontrolled observations, not battle performance.", "cases": records}, "  "))
	f.close()
	call_deferred("finish")

func pose_signature(node: Node) -> String:
	var poses: Array = []
	var pending: Array[Node] = [node]
	while not pending.is_empty():
		var n: Node = pending.pop_back()
		if n is Skeleton3D:
			for bone in range(n.get_bone_count()):
				poses.append([str(n.get_bone_pose_position(bone)), str(n.get_bone_pose_rotation(bone))])
		for child in n.get_children(): pending.append(child)
	return JSON.stringify(poses).sha256_text()

func finish() -> void:
	if stage != null: stage.queue_free()
	if Foot._dog_proto != null:
		Foot._dog_proto.free()
		Foot._dog_proto = null
	if Mount._horse_proto != null:
		Mount._horse_proto.free()
		Mount._horse_proto = null
	await process_frame
	await process_frame
	quit()

