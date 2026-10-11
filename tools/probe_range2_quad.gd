extends SceneTree
## Throwaway probe: renders the FOUR range-2 hex variants (F,G,H,I = variants
## 5,6,7,8) side by side in complete isolation (no other map content), two
## angles, to verify the four compositions are visibly DIFFERENT.

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
	pm.size = Vector2(600, 600)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.74, 0.76, 0.63)
	pm.material = mat
	ground.mesh = pm
	root.add_child(ground)
	_cam = Camera3D.new()
	root.add_child(_cam)
	_cam.current = true
	_cam.fov = 45.0
	var labels := ["F", "G", "H", "I"]
	for i in range(4):
		var built: Dictionary = Builder.build_mountain(5 + i, 777 + i * 1013)
		var hex_root: Node3D = built["root"]
		hex_root.position = Vector3((float(i) - 1.5) * 46.0, 0.0, 0.0)
		root.add_child(hex_root)
		print("[probe] placed %s at x=%.0f" % [labels[i], hex_root.position.x])
	_views = [
		[Vector3(-2.0, 42.0, 118.0), Vector3(-2.0, 2.0, 4.0)],
		[Vector3(-2.0, 104.0, 22.0), Vector3(-2.0, 0.0, 2.0)],
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
	var path: String = "%s/probe_range2_%d.png" % [OUT_DIR, _shot]
	var err: int = img.save_png(path)
	print("[probe] saved %s err=%d size=%s" % [path, err, str(img.get_size())])
	_shot += 1
	if _shot >= 2:
		quit(0)
		return true
	_set_view(_shot)
	_t = 0
	return false
