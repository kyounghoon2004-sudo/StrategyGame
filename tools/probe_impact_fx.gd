extends SceneTree
## MEASUREMENT ONLY: render one impact burst over a plain plane and save frames
## (looking for dark particle artifacts).
const Fx = preload("res://scripts/visual/civ3d/civ_battle_fx.gd")
var n := 0
var world: Node3D
func _initialize() -> void:
	world = Node3D.new()
	root.add_child(world)
	var plane := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(20, 20)
	plane.mesh = pm
	world.add_child(plane)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-60, 30, 0)
	sun.shadow_enabled = true
	world.add_child(sun)
	var cam := Camera3D.new()
	world.add_child(cam)
	cam.look_at_from_position(Vector3(0, 7, 6), Vector3.ZERO, Vector3.UP)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.6, 0.7, 0.5)
	env.environment.ssao_enabled = true
	world.add_child(env)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://evidence/civ3d_spar/fxprobe"))
func _process(_d: float) -> bool:
	n += 1
	if n == 10:
		Fx.impact(world, Vector3.ZERO, 2.3)
	if n >= 10 and n <= 40 and n % 3 == 1:
		RenderingServer.frame_post_draw.connect(func(): root.get_texture().get_image().save_png("res://evidence/civ3d_spar/fxprobe/f%02d.png" % n), CONNECT_ONE_SHOT)
	return n > 45
