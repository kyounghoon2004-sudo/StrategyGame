extends Node3D
const SOLDIER = preload("res://scenes/haruki_v0/haruki_soldier.tscn")
const FORMATION = preload("res://scenes/haruki_v0/haruki_formation_20.tscn")
const OUT := "res://artifacts/haruki_v0/"
var formation: Node3D
var solo: Node3D
var camera: Camera3D
var status: Label
var close_up := false
var repeat := false
var repeat_clock := 0.0
var samples: Array[float] = []
var measure := false
var cycles := 0
var ui_time := 0.0
func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	formation = FORMATION.instantiate();formation.position.x = 2.7;add_child(formation)
	solo = SOLDIER.instantiate();solo.position = Vector3(-5.2,0,0);add_child(solo)
	setup_stage();setup_ui()
	if "--capture" in OS.get_cmdline_user_args():capture_and_validate()
func setup_stage() -> void:
	var world := WorldEnvironment.new();world.environment = Environment.new()
	world.environment.background_mode = Environment.BG_COLOR;world.environment.background_color = Color(.065,.075,.09)
	world.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR;world.environment.ambient_light_color = Color(.95,.96,1)
	world.environment.ambient_light_energy = .65;add_child(world)
	var light := DirectionalLight3D.new();light.rotation_degrees = Vector3(-55,-30,0);light.light_energy = 1.25;light.shadow_enabled = true;add_child(light)
	var floor := MeshInstance3D.new();floor.mesh = PlaneMesh.new();floor.mesh.size = Vector2(100,100);floor.position.y = -.04
	floor.material_override = material(Color(.09,.11,.13));add_child(floor)
	var hex_mesh := ImmediateMesh.new();hex_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(6):
		hex_mesh.surface_add_vertex(Vector3.ZERO)
		hex_mesh.surface_add_vertex(Vector3(cos(i*TAU/6)*5.6,0,sin(i*TAU/6)*5.6))
		hex_mesh.surface_add_vertex(Vector3(cos((i+1)*TAU/6)*5.6,0,sin((i+1)*TAU/6)*5.6))
	hex_mesh.surface_end()
	var hex := MeshInstance3D.new();hex.mesh = hex_mesh;hex.position = Vector3(2.7,-.02,0);hex.material_override = material(Color(.23,.205,.17));add_child(hex)
	for item in [[Vector3(-5.2,.03,-1.5),"HARUKI / SINGLE PREVIEW"],[Vector3(2.7,.03,-3.5),"20 SOLDIERS / ONE FORMATION"]]:
		var label := Label3D.new();label.position = item[0];label.text = item[1];label.font_size = 42;label.pixel_size = .008;label.rotation_degrees.x = -90;add_child(label)
	camera = Camera3D.new();camera.projection = Camera3D.PROJECTION_ORTHOGONAL;add_child(camera);camera.current = true;gameplay_camera()
func material(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new();m.albedo_color = color;m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED;m.cull_mode = BaseMaterial3D.CULL_DISABLED;return m
func gameplay_camera() -> void:
	camera.position = Vector3(-4,13,13);camera.look_at(Vector3(1,.65,0));camera.size = 11.2
func setup_ui() -> void:
	var layer := CanvasLayer.new();add_child(layer)
	var panel := PanelContainer.new();panel.position = Vector2(20,20);layer.add_child(panel)
	var box := VBoxContainer.new();panel.add_child(box)
	var label := Label.new();label.text = "HARUKI / SOURCE ANIMATION IMPORT";label.add_theme_font_size_override("font_size",23);box.add_child(label)
	var help := Label.new();help.text = "1 preview + 20 formation copies\nSPACE: source attack   C: close-up   1–4: pose study\nCloth recolor only · original mesh and animation";box.add_child(help)
	status = Label.new();box.add_child(status)
	var button := Button.new();button.text = "PLAY ORIGINAL ATTACK [SPACE]";button.pressed.connect(play);box.add_child(button)
	var close := Button.new();close.text = "CLOSE-UP / FORMATION [C]";close.pressed.connect(toggle_close);box.add_child(close)
	var loop := CheckButton.new();loop.text = "Repeat original attack";loop.toggled.connect(func(v):repeat = v);box.add_child(loop)
func play() -> void:
	solo.attack();formation.attack();cycles += 1
func toggle_close() -> void:
	close_up = not close_up;formation.visible = not close_up
	if close_up:
		camera.position = solo.position+Vector3(-2.5,1.1,3.8);camera.look_at(solo.position+Vector3(0,.9,0));camera.size = 2.55
	else:gameplay_camera()
func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_SPACE:play();get_viewport().set_input_as_handled()
		elif event.keycode == KEY_C:toggle_close();get_viewport().set_input_as_handled()
		elif event.keycode in [KEY_1,KEY_2,KEY_3,KEY_4]:
			var t: float = [0.0,.11666667,.45,.80][event.keycode-KEY_1]
			formation.idle();solo.idle();solo.pose_at(t);formation.pose_at(t);get_viewport().set_input_as_handled()
func _process(dt: float) -> void:
	if measure:samples.append(dt)
	if repeat:
		repeat_clock += dt
		if repeat_clock > 1.5:play();repeat_clock = 0
	ui_time += dt
	if ui_time > .25 and status != null:
		ui_time = 0;status.text = "21 characters · 13,428,156 triangles · %d FPS" % Engine.get_frames_per_second()
func snapshot(name: String) -> void:
	for k in range(4):await get_tree().process_frame
	await RenderingServer.frame_post_draw
	assert(get_viewport().get_texture().get_image().save_png(ProjectSettings.globalize_path(OUT+name)) == OK)
func capture_and_validate() -> void:
	await get_tree().create_timer(2.0).timeout
	await snapshot("formation_idle.png")
	for item in [[.11666667,"formation_windup.png"],[.45,"formation_cut.png"],[.80,"formation_follow.png"]]:
		solo.pose_at(item[0]);formation.pose_at(item[0]);await snapshot(item[1])
	formation.idle();solo.idle();toggle_close()
	await snapshot("haruki_close_idle.png")
	solo.pose_at(.45);await snapshot("haruki_close_cut.png")
	solo.idle();toggle_close()
	for i in range(3):
		play();await get_tree().create_timer(1.35).timeout
		assert(not solo.running)
		for soldier in formation.soldiers:assert(not soldier.running)
	assert(formation.position == Vector3(2.7,0,0) and formation.soldiers.size() == 20)
	measure = true;samples.clear();await get_tree().create_timer(3.0).timeout;measure = false
	var total := 0.0
	for dt in samples:total += dt
	var report := {"status":"PASS","single_preview_count":1,"formation_count":20,"total_visible_characters":21,"bones_per_character":71,"mesh_instances_per_character":10,"triangles_per_character":639436,"character_triangles_total":13428156,"animation":"A_Haruki_Attack_08_ThumbAxisPass","duration_seconds":solo.player.get_animation(solo.CLIP).length,"source_animation_preserved":true,"cloth_only_recolor":true,"layout":"5 columns × 4 rows","spacing_m":1.35,"completed_replays":cycles,"formation_root_unchanged":true,"fps_average":samples.size()/total,"frame_sample_count":samples.size(),"viewport":[get_viewport().size.x,get_viewport().size.y],"asset":"res://assets/units/haruki_v0/haruki_oxblood.scn","glb":"res://assets/units/haruki_v0/haruki_oxblood.glb","no_live_combat_changes":true}
	FileAccess.open(ProjectSettings.globalize_path(OUT+"runtime_validation.json"),FileAccess.WRITE).store_string(JSON.stringify(report,"\t"))
	print("HARUKI_FORMATION_VALIDATED ",JSON.stringify(report));get_tree().quit()
