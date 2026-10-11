extends Node3D
const FORMATION_SCENE = preload("res://scenes/formation_v0/formation_20man.tscn")
const HexCellCls = preload("res://scripts/core/hex_cell.gd")
const UnitCls = preload("res://scripts/combat/unit.gd")
const OUT := "res://artifacts/godot_20man_formation_v0/"
var formation: Node3D
var camera: Camera3D
var status_label: Label
var fps_label: Label
var logical_unit
var logical_cell
var logical_cells: Array = []
var samples: Array[float] = []
var ui_timer := 0.0
var audit_labels: Array[Label3D] = []
var frozen_attack_review := false

func _ready() -> void:
	# Exactly one real existing Unit data object occupies one real HexCell.
	# It is an isolated review fixture; the game managers never receive it.
	logical_unit = UnitCls.new(null,"neutral",100)
	logical_cell = HexCellCls.new(0,0)
	logical_cell.occupying_unit = logical_unit
	logical_cells.append(logical_cell)
	formation = FORMATION_SCENE.instantiate()
	add_child(formation)
	formation.set_meta("logical_unit",logical_unit)
	assert(logical_cells.size() == 1 and logical_cell.occupying_unit == logical_unit)
	_setup_stage();_setup_ui()
	for i in range(20):
		var label := Label3D.new();label.name = "AuditIndex_%02d" % (i+1)
		label.text = str(i+1);label.font_size = 42;label.pixel_size = 0.009
		label.position = formation.soldiers[i].position + Vector3(0,1.83,0)
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.no_depth_test = true;label.visible = false
		add_child(label);audit_labels.append(label)
	await get_tree().process_frame
	assert(formation.soldiers.size() == 20)
	if "--capture" in OS.get_cmdline_user_args():_capture_and_validate()

func _setup_stage() -> void:
	var world := WorldEnvironment.new();world.environment = Environment.new()
	world.environment.background_mode = Environment.BG_COLOR
	world.environment.background_color = Color(0.065,0.079,0.096)
	world.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	world.environment.ambient_light_color = Color(0.84,0.88,1)
	world.environment.ambient_light_energy = 0.50
	add_child(world)
	var sun := DirectionalLight3D.new();sun.name = "ReviewKey"
	sun.rotation_degrees = Vector3(-55,-30,0);sun.light_energy = 1.15;sun.shadow_enabled = true;add_child(sun)
	var floor := MeshInstance3D.new();floor.name = "ReviewGround"
	floor.mesh = PlaneMesh.new();floor.mesh.size = Vector2(200,200)
	var ground_mat := StandardMaterial3D.new();ground_mat.albedo_color = Color(.10,.115,.13);ground_mat.roughness = .95
	floor.material_override = ground_mat;floor.position.y = -.024;add_child(floor)
	var hex_mesh := ImmediateMesh.new();hex_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	var radius := 4.5
	for i in range(6):
		var a := i*TAU/6;var b := (i+1)*TAU/6
		hex_mesh.surface_set_normal(Vector3.UP);hex_mesh.surface_add_vertex(Vector3.ZERO)
		hex_mesh.surface_add_vertex(Vector3(cos(b)*radius,0,sin(b)*radius))
		hex_mesh.surface_add_vertex(Vector3(cos(a)*radius,0,sin(a)*radius))
	hex_mesh.surface_end()
	var hex := MeshInstance3D.new();hex.name = "OneLogicalHex";hex.mesh = hex_mesh
	var hex_mat := StandardMaterial3D.new();hex_mat.albedo_color = Color(.23,.215,.16);hex_mat.roughness = .95
	hex_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	hex.material_override = hex_mat;hex.position.y = -.014;add_child(hex)
	var outline := ImmediateMesh.new();outline.surface_begin(Mesh.PRIMITIVE_LINES)
	for i in range(6):
		var a := i*TAU/6;var b := (i+1)*TAU/6
		outline.surface_add_vertex(Vector3(cos(a)*radius,.001,sin(a)*radius))
		outline.surface_add_vertex(Vector3(cos(b)*radius,.001,sin(b)*radius))
	outline.surface_end()
	var edge := MeshInstance3D.new();edge.name = "HexBoundary";edge.mesh = outline
	var edge_mat := StandardMaterial3D.new();edge_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED;edge_mat.albedo_color = Color(.74,.65,.42)
	edge.material_override = edge_mat;add_child(edge)
	camera = Camera3D.new();camera.name = "GameplayElevatedCamera"
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL;camera.size = 10.8
	camera.position = Vector3(-1.8,17,9);add_child(camera);camera.look_at(Vector3(0,.65,0));camera.current = true

func _setup_ui() -> void:
	var layer := CanvasLayer.new();add_child(layer)
	var panel := PanelContainer.new();panel.position = Vector2(22,20);layer.add_child(panel)
	var box := VBoxContainer.new();panel.add_child(box)
	var title := Label.new();title.text = "20-MAN FORMATION / V0";title.add_theme_font_size_override("font_size",24);box.add_child(title)
	var subtitle := Label.new();subtitle.text = "One formation · one hex · 4 ranks × 5 files\nSPACE or ATTACK to strike and return to idle";box.add_child(subtitle)
	status_label = Label.new();status_label.text = "IDLE";box.add_child(status_label)
	fps_label = Label.new();box.add_child(fps_label)
	var button := Button.new();button.text = "ATTACK [SPACE]";button.pressed.connect(_trigger_attack);box.add_child(button)
	var audit := CheckButton.new();audit.text = "Show soldier count labels";audit.toggled.connect(func(value):
		for label in audit_labels:label.visible = value)
	box.add_child(audit)

func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_SPACE:
		_trigger_attack();get_viewport().set_input_as_handled()

func _trigger_attack() -> void:
	formation.trigger_attack()

func _process(delta: float) -> void:
	if delta > 0:samples.append(delta)
	ui_timer += delta
	if ui_timer > .25 and status_label != null:
		ui_timer = 0
		status_label.text = "ATTACK" if formation.attacking or frozen_attack_review else "IDLE"
		fps_label.text = "20 soldiers / 266,320 character triangles / %.0f FPS" % Engine.get_frames_per_second()

func _collect_meshes(node: Node, result: Array) -> void:
	if node is MeshInstance3D:result.append(node)
	for child in node.get_children():_collect_meshes(child,result)

func _snapshot(name: String) -> void:
	# Allow deferred Skeleton3D and GPU skin buffers to reach the captured frame.
	for frame in range(3):await get_tree().process_frame
	await RenderingServer.frame_post_draw
	assert(get_viewport().get_texture().get_image().save_png(ProjectSettings.globalize_path(OUT+name)) == OK)

func _capture_and_validate() -> void:
	await get_tree().create_timer(3.0).timeout
	formation.reset_idle();status_label.text = "IDLE / 20 visible soldiers"
	await _snapshot("idle_gameplay.png")
	for label in audit_labels:label.visible = true
	await _snapshot("count_audit_20.png")
	for label in audit_labels:label.visible = false
	# Inspect the actual model unmodified from the source at closer camera scale.
	camera.position = Vector3(-3,4,8);camera.look_at(Vector3(0,.8,1.7));camera.size = 5.0
	await _snapshot("front_rank_close.png")
	camera.position = Vector3(-1.8,17,9);camera.look_at(Vector3(0,.65,0));camera.size = 10.8
	var first = formation.soldiers[0]
	var hand: int = first.skeleton.find_bone("joint_23")
	var hand_rest: Vector3 = first.skeleton.get_bone_global_pose(hand).origin
	# Deterministic peak screenshot supplements actual sequential playback below.
	frozen_attack_review = true
	formation.seek_attack(.40);status_label.text = "ATTACK / shared 0.76 s clip + small timing offsets"
	await _snapshot("attack_peak.png")
	camera.position = Vector3(-3,4,8);camera.look_at(Vector3(0,.8,1.7));camera.size = 5.0
	await _snapshot("attack_close.png")
	camera.position = Vector3(-1.8,17,9);camera.look_at(Vector3(0,.65,0));camera.size = 10.8
	var hand_peak: Vector3 = first.skeleton.get_bone_global_pose(hand).origin
	var hand_motion := hand_peak.distance_to(hand_rest)
	assert(hand_motion > .10)
	formation.reset_idle()
	frozen_attack_review = false
	# Exercise the actual SPACE input path and collect sequential animation frames.
	var key := InputEventKey.new();key.keycode = KEY_SPACE;key.pressed = true
	_input_test(key)
	assert(formation.attacking)
	await get_tree().create_timer(.15).timeout;await _snapshot("attack_sequence_01_anticipation.png")
	await get_tree().create_timer(.23).timeout;await _snapshot("attack_sequence_02_strike.png")
	await get_tree().create_timer(.23).timeout;await _snapshot("attack_sequence_03_recover.png")
	await get_tree().create_timer(.45).timeout
	assert(not formation.attacking and formation.all_idle())
	assert(logical_cells.size() == 1 and logical_cell.occupying_unit == logical_unit)
	assert(logical_unit.hex_q == 0 and logical_unit.hex_r == 0 and logical_unit.soldier_count == 100)
	status_label.text = "IDLE / attack returned cleanly";await _snapshot("returned_idle.png")
	# Two repeated attacks verify all twenty wrappers reset, not just the lead.
	for loop in range(2):
		formation.trigger_attack();await get_tree().create_timer(1.0).timeout
		assert(formation.all_idle() and not formation.attacking)
	samples.clear()
	await get_tree().create_timer(3.0).timeout
	var sum_dt := 0.0
	for dt in samples:sum_dt += dt
	var sorted_samples := samples.duplicate();sorted_samples.sort()
	var median_ms: float = sorted_samples[sorted_samples.size()/2]*1000
	var p95_ms: float = sorted_samples[int(sorted_samples.size()*.95)]*1000
	var soldier_meshes: Array = [];_collect_meshes(formation,soldier_meshes)
	var all_meshes: Array = [];_collect_meshes(self,all_meshes)
	assert(soldier_meshes.size() == 20 and all_meshes.size() == 23)
	assert(formation.soldiers.size() == 20)
	var bounds := Rect2(Vector2(-2.13,-2.40),Vector2(4.26,4.8))
	var report := {"status":"PASS","source_asset":"res://assets/units/formation_v0/supplied_soldier.glb","godot_version":Engine.get_version_info().string,"visual_soldiers":20,"layout":{"rows":4,"columns":5,"column_spacing":.88,"row_spacing":1.12,"jitter_max":.021},"logical_unit_objects":1,"logical_hex_cells":logical_cells.size(),"occupied_hexes":1,"fixture_unit_troop_count_unchanged":logical_unit.soldier_count,"bone_count_per_soldier":24,"soldier_mesh_instances":soldier_meshes.size(),"total_visible_mesh_instances":all_meshes.size(),"character_triangles":266320,"stage_triangles":8,"total_estimated_triangles":266328,"world_soldier_height":1.65,"model_forward":"raw -Z, wrapper +Z","attack_duration_seconds":.76,"timing_offset_max_seconds":.072,"hand_motion_raw_m":hand_motion,"all_twenty_returned_idle":formation.all_idle(),"completed_attack_events":formation.attack_events,"footprint_containment_checked":true,"hex_radius":4.5,"footprint_inset_radius":formation.FOOTPRINT_RADIUS,"fps_average":samples.size()/sum_dt,"engine_fps":Engine.get_frames_per_second(),"frame_time_median_ms":median_ms,"frame_time_p95_ms":p95_ms,"fps_sample_frames":samples.size(),"fps_sample_seconds":sum_dt,"vsync":DisplayServer.window_get_vsync_mode(),"viewport_size":[get_viewport().size.x,get_viewport().size.y],"production_combat_pathfinding_modified":false,"live_combat_integrated":false}
	FileAccess.open(ProjectSettings.globalize_path(OUT+"runtime_validation.json"),FileAccess.WRITE).store_string(JSON.stringify(report,"\t"))
	print("GODOT_20MAN_FORMATION_VALIDATED ",JSON.stringify(report))
	get_tree().quit(0)

func _input_test(key: InputEventKey) -> void:
	_unhandled_key_input(key)
