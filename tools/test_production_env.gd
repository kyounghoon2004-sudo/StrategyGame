extends SceneTree

const ProdEnv = preload("res://scripts/visual/production_map_environment_3d.gd")

var _root3d: Node3D
var _env: Node3D
var _cam: Camera3D
var _frames := 0
var _fps_samples: Array = []

func _initialize() -> void:
	print("--- TESTING ProductionMapEnvironment3D WINDOWED STEADY STATE FPS ---")
	_root3d = Node3D.new()
	root.add_child(_root3d)

	_env = ProdEnv.new()
	_root3d.add_child(_env)

	# Camera for view
	_cam = Camera3D.new()
	_cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	_cam.size = 2800.0
	_cam.position = Vector3(0.0, 1500.0, 1000.0)
	_cam.rotation_degrees = Vector3(-60.0, 0.0, 0.0)
	_cam.current = true
	_root3d.add_child(_cam)

	var report: Dictionary = _env.call("build_from_battlefield", null)
	print("REPORT_DATA: " + JSON.stringify(report))

func _process(delta: float) -> bool:
	_frames += 1
	if _frames > 30:
		_fps_samples.append(1.0 / maxf(0.0001, delta))
	if _frames >= 90:
		var sum_fps := 0.0
		for f in _fps_samples:
			sum_fps += f
		var avg_fps: float = sum_fps / float(_fps_samples.size())
		print("STEADY_STATE_AVERAGE_FPS: ", "%.2f" % avg_fps)
		_root3d.queue_free()
		quit(0)
		return true
	return false
