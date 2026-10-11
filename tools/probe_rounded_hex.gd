extends SceneTree
## Throwaway probe: renders ONE mountain hex (MOUNTAIN H, variant 7) in complete
## isolation (no neighbouring hexes), three viewing angles, to inspect the actual
## piece shapes without range-1 background contamination.

const Builder = preload("res://scripts/visual/map_composition_v0/map_composition_builder.gd")
const OUT_DIR := "C:/Users/kyoun/AppData/Local/Temp"

var _t := 0
var _shot := 0
var _cam: Camera3D
var _views: Array = []


func _initialize() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.95, 0.95, 0.965)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(1, 1, 1)
	env.ambient_light_energy = 0.6
	var we := WorldEnvironment.new()
	we.environment = env
	root.add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-42, -125, 0)
	sun.light_energy = 0.95
	root.add_child(sun)
	var ground := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(400, 400)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.74, 0.76, 0.63)
	pm.material = mat
	ground.mesh = pm
	root.add_child(ground)
	_cam = Camera3D.new()
	root.add_child(_cam)
	_cam.current = true
	_cam.fov = 45.0
	var built: Dictionary = Builder.build_mountain(7, 777)
	var hex_root: Node3D = built["root"]
	root.add_child(hex_root)
	# three views: low oblique (SE), medium oblique (S), high oblique (E)
	_views = [
		[Vector3(30.0, 10.0, 34.0), Vector3(0.0, 6.0, 0.0)],
		[Vector3(0.0, 20.0, 48.0), Vector3(0.0, 6.0, 0.0)],
		[Vector3(46.0, 26.0, -6.0), Vector3(0.0, 6.0, 0.0)],
	]
	_set_view(0)


func _set_view(i: int) -> void:
	_cam.position = _views[i][0]
	_cam.look_at(_views[i][1], Vector3.UP)


func _process(_delta: float) -> bool:
	_t += 1
	if _t < 30:
		return false
	var img: Image = root.get_texture().get_image()
	var path: String = "%s/probe_mtn_h_%d.png" % [OUT_DIR, _shot]
	var err: int = img.save_png(path)
	print("[probe] saved %s err=%d size=%s" % [path, err, str(img.get_size())])
	_shot += 1
	if _shot >= 3:
		quit(0)
		return true
	_set_view(_shot)
	_t = 0
	return false
