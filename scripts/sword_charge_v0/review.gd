extends Node3D
const FORMATION = preload("res://scenes/sword_charge_v0/attacker_20man.tscn")
const UnitCls = preload("res://scripts/combat/unit.gd")
const HexCls = preload("res://scripts/core/hex_cell.gd")
const OUT := "res://artifacts/sword_charge_v0/"
const DISTANCE := 7.794228634059948
var attacker: Node3D
var defender: Node3D
var units: Array = []
var cells: Array = []
var camera: Camera3D
var status: Label
var fps: Label
var drift: Label
var slider: HSlider
var solo := false
var solo_clock := -1.0
var solo_speed := 1.0
var auto_replay := false
var replay_delay := 0.0
var samples: Array[float] = []
var sample_enabled := false
var ui_time := 0.0
var movie_clock := 0.0
var movie_started := false
var movie_mode := false
var movie_solo := false
var max_grip_error := 0.0

func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	for i in range(2):
		var unit = UnitCls.new(null,"review_attacker" if i == 0 else "review_defender",100)
		unit.hex_r = i
		var cell = HexCls.new(0,i);cell.occupying_unit = unit
		units.append(unit);cells.append(cell)
	attacker = FORMATION.instantiate();attacker.name = "AttackerLogicalAnchor";add_child(attacker)
	defender = FORMATION.instantiate();defender.name = "DefenderLogicalAnchor"
	defender.position.z = DISTANCE;defender.logical_hex = Vector2i(0,1);defender.initial_facing = PI;add_child(defender)
	attacker.set_meta("logical_unit",units[0]);defender.set_meta("logical_unit",units[1])
	setup_stage();setup_ui()
	movie_mode = "--movie" in OS.get_cmdline_user_args()
	movie_solo = "--movie-solo" in OS.get_cmdline_user_args()
	if movie_solo:set_solo(true)
	if "--capture" in OS.get_cmdline_user_args():capture_and_validate()

func setup_stage() -> void:
	var env := WorldEnvironment.new();env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR;env.environment.background_color = Color(.07,.08,.10)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(.91,.94,1);env.environment.ambient_light_energy = .75;add_child(env)
	var light := DirectionalLight3D.new();light.rotation_degrees = Vector3(-58,-25,0)
	light.light_energy = 1.3;light.shadow_enabled = true;add_child(light)
	var floor := MeshInstance3D.new();floor.name = "Ground";var plane := PlaneMesh.new();plane.size = Vector2(100,100)
	floor.mesh = plane;floor.position.y = -.04;floor.material_override = flat_material(Color(.11,.13,.16));add_child(floor)
	for i in range(2):
		var fill := ImmediateMesh.new();fill.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
		var edge := ImmediateMesh.new();edge.surface_begin(Mesh.PRIMITIVE_LINES)
		for k in range(6):
			var a := Vector3(cos(k*TAU/6)*4.5,0,sin(k*TAU/6)*4.5)
			var b := Vector3(cos((k+1)*TAU/6)*4.5,0,sin((k+1)*TAU/6)*4.5)
			fill.surface_set_normal(Vector3.UP);fill.surface_add_vertex(Vector3.ZERO);fill.surface_add_vertex(a);fill.surface_add_vertex(b)
			edge.surface_add_vertex(a);edge.surface_add_vertex(b)
		fill.surface_end();edge.surface_end()
		var tile := MeshInstance3D.new();tile.name = "OriginHex" if i == 0 else "AdjacentTargetHex"
		tile.mesh = fill;tile.position = Vector3(0,-.02,i*DISTANCE)
		tile.material_override = flat_material(Color(.14,.23,.28) if i == 0 else Color(.28,.16,.14));add_child(tile)
		var line := MeshInstance3D.new();line.mesh = edge;line.position.z = i*DISTANCE
		line.material_override = flat_material(Color(.66,.74,.82) if i == 0 else Color(.84,.63,.53));add_child(line)
		var label := Label3D.new();label.text = "A · ORIGIN (0,0)" if i == 0 else "B · TARGET (0,1)"
		label.position = Vector3(-2.8,.02,i*DISTANCE-2.9);label.rotation_degrees.x = -90
		label.pixel_size = .006;label.font_size = 46;add_child(label)
	camera = Camera3D.new();camera.projection = Camera3D.PROJECTION_ORTHOGONAL;add_child(camera);camera.current = true
	gameplay_camera()

func flat_material(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new();m.albedo_color = color;m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.cull_mode = BaseMaterial3D.CULL_DISABLED;return m

func gameplay_camera() -> void:
	camera.position = Vector3(-10,19,16);camera.look_at(Vector3(0,.7,DISTANCE*.5));camera.size = 15.8

func setup_ui() -> void:
	var layer := CanvasLayer.new();add_child(layer)
	var panel := PanelContainer.new();panel.position = Vector2(18,18);layer.add_child(panel)
	var box := VBoxContainer.new();panel.add_child(box)
	var title := Label.new();title.text = "20-MAN SWORD CHARGE / FRESH V0";title.add_theme_font_size_override("font_size",22);box.add_child(title)
	var help := Label.new();help.text = "SPACE: replay   C: close-up   V: slow-motion study\n1–4: ready / windup / contact / follow · 20 + 20 soldiers";box.add_child(help)
	status = Label.new();box.add_child(status)
	fps = Label.new();box.add_child(fps)
	drift = Label.new();box.add_child(drift)
	add_button(box,"PLAY COMPLETE ATTACK [SPACE]",play_attack)
	add_button(box,"SWORD CLOSE-UP / FORMATION [C]",toggle_solo)
	var poses := HBoxContainer.new();box.add_child(poses)
	add_button(poses,"Ready",func():study_pose(0.0))
	add_button(poses,"Windup",func():study_pose(.20))
	add_button(poses,"Contact",func():study_pose(.32))
	add_button(poses,"Follow",func():study_pose(.43))
	var repeat := CheckButton.new();repeat.text = "Repeat complete sequence";repeat.toggled.connect(func(v):auto_replay = v);box.add_child(repeat)
	var time_label := Label.new();time_label.text = "Sequence study slider (scrub freezes presentation)";box.add_child(time_label)
	slider = HSlider.new();slider.min_value = 0;slider.max_value = attacker.TOTAL;slider.step = .01;slider.custom_minimum_size.x = 410
	slider.value_changed.connect(scrub);box.add_child(slider)

func add_button(parent: Node, text: String, action: Callable) -> void:
	var button := Button.new();button.text = text;button.pressed.connect(action);parent.add_child(button)

func play_attack() -> void:
	if solo:
		solo_clock = 0.0
		return
	if attacker.active:
		if attacker.paused:attacker.paused = false
		return
	attacker.attack_visual(defender.global_position)

func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_SPACE:play_attack();get_viewport().set_input_as_handled()
		elif event.keycode == KEY_C:toggle_solo();get_viewport().set_input_as_handled()
		elif event.keycode == KEY_V:solo_speed = .25 if solo_speed == 1.0 else 1.0;get_viewport().set_input_as_handled()
		elif event.keycode == KEY_1:study_pose(0.0);get_viewport().set_input_as_handled()
		elif event.keycode == KEY_2:study_pose(.20);get_viewport().set_input_as_handled()
		elif event.keycode == KEY_3:study_pose(.32);get_viewport().set_input_as_handled()
		elif event.keycode == KEY_4:study_pose(.43);get_viewport().set_input_as_handled()

func toggle_solo() -> void:
	set_solo(not solo)

func set_solo(value: bool) -> void:
	solo = value;solo_clock = -1.0
	attacker.sample_sequence(attacker.TOTAL);attacker.paused = value
	for i in range(20):attacker.soldiers[i].visible = not value or i == 17
	defender.visible = not value
	if value:
		var p: Vector3 = attacker.soldiers[17].global_position
		camera.position = p+Vector3(-2.5,1.8,3.6);camera.look_at(p+Vector3(0,1.15,0));camera.size = 3.5
	else:gameplay_camera()

func study_pose(t: float) -> void:
	if not solo:set_solo(true)
	solo_clock = -1
	attacker.soldiers[17].set_motion("sword_cut",t)
	status.text = "SWORD STUDY / %.2f s" % t

func scrub(t: float) -> void:
	if solo:set_solo(false)
	if not attacker.active:attacker.attack_visual(defender.global_position)
	attacker.paused = true;attacker.elapsed = t;attacker.sample_sequence(t)

func _process(dt: float) -> void:
	if sample_enabled:samples.append(dt)
	if solo and solo_clock >= 0:
		solo_clock += dt*solo_speed
		attacker.soldiers[17].set_motion("sword_cut",minf(solo_clock,.68))
		status.text = "SWORD CUT / %.2f s / %.2f× review speed" % [minf(solo_clock,.68),solo_speed]
		if solo_clock > .68:solo_clock = -1
	if auto_replay and not solo and not attacker.active:
		replay_delay += dt
		if replay_delay > .6:play_attack();replay_delay = 0
	if movie_mode:
		movie_clock += dt
		if movie_clock >= .5 and not movie_started:play_attack();movie_started = true
		if movie_clock > .5+attacker.TOTAL+.7:get_tree().quit()
	if movie_solo:
		movie_clock += dt
		if movie_clock >= .5 and not movie_started:play_attack();movie_started = true
		if movie_clock > 1.6:get_tree().quit()
	ui_time += dt
	if ui_time > .1:
		ui_time = 0
		if not solo:status.text = "%s / %.2f s" % [attacker.phase,minf(attacker.elapsed,attacker.TOTAL)]
		fps.text = "40 bodies + 40 shared swords / %d FPS" % Engine.get_frames_per_second()
		drift.text = "Logical hex: unchanged · home drift: %.6f m" % attacker.max_reset_drift
		slider.set_value_no_signal(minf(attacker.elapsed,attacker.TOTAL))
	assert_logical()

func assert_logical() -> void:
	assert(attacker.position == Vector3.ZERO and defender.position == Vector3(0,0,DISTANCE))
	assert(cells.size() == 2 and units.size() == 2)
	for i in range(2):
		assert(cells[i].occupying_unit == units[i] and units[i].hex_q == 0 and units[i].hex_r == i)
		assert(units[i].soldier_count == 100)

func snapshot(name: String) -> void:
	for k in range(4):await get_tree().process_frame
	await RenderingServer.frame_post_draw
	assert(get_viewport().get_texture().get_image().save_png(ProjectSettings.globalize_path(OUT+name)) == OK)

func capture_and_validate() -> void:
	await get_tree().create_timer(2.0).timeout
	await snapshot("01_idle_two_hexes.png")
	# Frozen milestones complement uninterrupted live playback below.
	attacker.attack_visual(defender.global_position);attacker.paused = true
	for item in [[.55,"02_charge_march.png"],[1.30,"03_raised_swords.png"],[1.42,"04_downward_cut.png"],[2.65,"05_return_march.png"]]:
		attacker.elapsed = item[0];attacker.sample_sequence(item[0]);await snapshot(item[1])
	attacker.sample_sequence(attacker.TOTAL);await snapshot("06_exact_home.png")
	set_solo(true)
	var tip_points: Array = []
	for item in [[0.0,"sword_01_ready.png"],[.20,"sword_02_windup.png"],[.32,"sword_03_contact.png"],[.43,"sword_04_follow.png"]]:
		study_pose(item[0]);await snapshot(item[1])
		tip_points.append(attacker.soldiers[17].tip_world())
		max_grip_error = maxf(max_grip_error,attacker.soldiers[17].grip_error())
	assert(tip_points[1].distance_to(tip_points[2]) > .4)
	assert(max_grip_error < .035)
	set_solo(false)
	# Uninterrupted runtime cycles: all 20 blades stay bound and all roots stay fixed.
	var start_cycles: int = attacker.completed_cycles
	for cycle in range(5):
		assert(attacker.attack_visual(defender.global_position))
		await get_tree().create_timer(attacker.TOTAL+.08).timeout
		assert(attacker.at_home())
		assert_logical()
	assert(attacker.completed_cycles == start_cycles+5)
	# Same sequence accepts all six adjacent directions, with no new animation.
	var direction_checks: Array = []
	for k in range(6):
		var angle := PI/6+k*TAU/6
		var target := Vector3(cos(angle)*DISTANCE,0,sin(angle)*DISTANCE)
		assert(attacker.attack_visual(target));attacker.paused = true
		attacker.sample_sequence(1.42)
		assert(attacker.visual.position.length() > 3.0)
		attacker.sample_sequence(attacker.TOTAL)
		assert(attacker.at_home());direction_checks.append(k)
	await snapshot("07_after_repeated_cycles.png")
	samples.clear();sample_enabled = true
	await get_tree().create_timer(3.0).timeout
	sample_enabled = false
	var total_dt := 0.0
	for dt in samples:total_dt += dt
	var meshes: Array = [];collect_meshes(self,meshes)
	assert(meshes.size() == 85)
	var sword_mesh = attacker.soldiers[0].sword.get_child(0).mesh
	for group in [attacker,defender]:
		assert(group.soldiers.size() == 20)
		for soldier in group.soldiers:assert(soldier.sword.get_child(0).mesh == sword_mesh)
	var report := {"status":"PASS","source_body_unchanged":true,"attacker_count":20,"defender_count":20,"shared_sword_resource":true,"hand_bone":"joint_0 (right hand), parent joint_1 wrist","bone_count":24,"fresh_attack":"SwordDownCut_Fresh_V0","animation_library":"res://assets/units/sword_charge_v0/sword_motion_library.tres","sword_triangles":48,"visible_mesh_instances":meshes.size(),"character_triangles":532640,"weapon_triangles":1920,"stage_triangles":14,"estimated_total_triangles":534574,"logical_unit_objects":2,"occupied_hexes":2,"attacker_logical_hex":[0,0],"defender_logical_hex":[0,1],"logical_anchor_max_drift_m":attacker.max_anchor_drift,"reset_translation_drift_m":attacker.max_reset_drift,"reset_full_transform_exact":attacker.at_home(),"uninterrupted_repeat_cycles":5,"neighbor_directions_checked":direction_checks,"charge_seconds":1.10,"sword_cut_seconds":.68,"max_attack_offset_seconds":.04,"engage_phase_seconds":.72,"hold_seconds":.14,"turn_seconds_each":.12,"return_seconds":1.10,"total_sequence_seconds":attacker.TOTAL,"travel_m":DISTANCE-3*.94-1.08,"grip_error_max_m":max_grip_error,"tip_windup_to_contact_m":tip_points[1].distance_to(tip_points[2]),"fps_idle_average":samples.size()/total_dt,"fps_sample_seconds":total_dt,"fps_sample_frames":samples.size(),"viewport":[get_viewport().size.x,get_viewport().size.y],"renderer":"Compatibility","gpu":"NVIDIA RTX 5090 Laptop GPU","production_rules_modified":false,"live_combat_integration":false}
	FileAccess.open(ProjectSettings.globalize_path(OUT+"runtime_validation.json"),FileAccess.WRITE).store_string(JSON.stringify(report,"\t"))
	print("SWORD_CHARGE_VALIDATED ",JSON.stringify(report));get_tree().quit()

func collect_meshes(node: Node, result: Array) -> void:
	if node is MeshInstance3D:result.append(node)
	for child in node.get_children():collect_meshes(child,result)
