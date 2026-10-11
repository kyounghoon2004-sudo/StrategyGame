extends SceneTree

## Orthographic side / front / top views of a GLB with a 0.05-unit grid, for
## placing rig landmarks by eye. Visual pipeline only.
##   Godot --path <project> --resolution 1500x1000 --script res://tools/ortho_views_glb.gd -- <abs glb> <out prefix> <view: side|front|top>

var frames := 0
var out := ""

func _initialize() -> void:
	var a := OS.get_cmdline_user_args()
	var doc := GLTFDocument.new()
	var st := GLTFState.new()
	doc.append_from_file(a[0], st)
	var model: Node3D = doc.generate_scene(st)
	out = a[1]
	var view: String = a[2]
	var w := Node3D.new()
	root.add_child(w)
	w.add_child(model)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.92, 0.92, 0.9)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(1, 1, 1)
	env.environment.ambient_light_energy = 0.7
	w.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-40, 30, 0)
	w.add_child(sun)
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = 1.1
	w.add_child(cam)
	var grid := ImmediateMesh.new()
	var gm := StandardMaterial3D.new()
	gm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	gm.vertex_color_use_as_albedo = true
	gm.no_depth_test = true
	grid.surface_begin(Mesh.PRIMITIVE_LINES, gm)
	for i in range(-12, 13):
		var v := i * 0.05
		var col := Color(1, 0, 0, 1) if i == 0 else (Color(0.2, 0.2, 0.9, 1) if i % 2 == 0 else Color(0.6, 0.6, 0.6, 1))
		match view:
			"side": # look along -X: screen right = -Z ... use +Z right
				grid.surface_set_color(col); grid.surface_add_vertex(Vector3(0.6, v, -0.6)); grid.surface_set_color(col); grid.surface_add_vertex(Vector3(0.6, v, 0.6))
				grid.surface_set_color(col); grid.surface_add_vertex(Vector3(0.6, -0.6, v)); grid.surface_set_color(col); grid.surface_add_vertex(Vector3(0.6, 0.6, v))
			"front":
				grid.surface_set_color(col); grid.surface_add_vertex(Vector3(-0.6, v, 0.6)); grid.surface_set_color(col); grid.surface_add_vertex(Vector3(0.6, v, 0.6))
				grid.surface_set_color(col); grid.surface_add_vertex(Vector3(v, -0.6, 0.6)); grid.surface_set_color(col); grid.surface_add_vertex(Vector3(v, 0.6, 0.6))
			_:
				grid.surface_set_color(col); grid.surface_add_vertex(Vector3(-0.6, 0.6, v)); grid.surface_set_color(col); grid.surface_add_vertex(Vector3(0.6, 0.6, v))
				grid.surface_set_color(col); grid.surface_add_vertex(Vector3(v, 0.6, -0.6)); grid.surface_set_color(col); grid.surface_add_vertex(Vector3(v, 0.6, 0.6))
	grid.surface_end()
	var gi := MeshInstance3D.new()
	gi.mesh = grid
	w.add_child(gi)
	match view:
		"side":
			cam.look_at_from_position(Vector3(3, 0, 0), Vector3.ZERO, Vector3.UP) # +Z on screen LEFT
		"front":
			cam.look_at_from_position(Vector3(0, 0, 3), Vector3.ZERO, Vector3.UP)
		_:
			cam.look_at_from_position(Vector3(0, 3, 0), Vector3.ZERO, Vector3.FORWARD)
	cam.make_current()

func _process(_d: float) -> bool:
	frames += 1
	if frames == 8:
		root.get_texture().get_image().save_png(out)
		quit()
	return false
