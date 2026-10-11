extends SceneTree
## Same-camera evidence for MAP_RENDER_OPTIMIZATION_V1.
## Usage: -s res://tools/capture_map_optimization_v1.gd -- baseline|candidate

const OUT_ROOT := "res://evidence/map_composition_v0/optimization_v1"
const PLAN := [
	{"name": "GAME", "rect": "ALL", "zoom": 1.15, "pitch": 0.0},
	{"name": "RANGE2", "rect": "RANGE2", "zoom": 1.6, "pitch": 0.0},
	{"name": "ALLP", "rect": "ALL", "zoom": 1.6, "pitch": 33.8},
	{"name": "FOREST", "rect": "FA", "zoom": 2.2, "pitch": 0.0},
	{"name": "VILLAGE", "rect": "VA", "zoom": 2.8, "pitch": 0.0},
]

var _label := "baseline"
var _index := -1
var _settle := 0
var _scene: Node
var _receipt: Array = []


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if not args.is_empty():
		_label = args[0]
	assert(_label == "baseline" or _label == "candidate")
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	change_scene_to_file("res://scenes/review/map_composition_v0.tscn")


func _process(_delta: float) -> bool:
	if _index < 0:
		var cs := current_scene
		if cs == null or cs.get("built") == null or not bool(cs.get("built")):
			return false
		_scene = cs
		_index = 0
		_apply()
		return false
	_settle += 1
	if _settle < 45:
		return false
	var img := root.get_texture().get_image()
	if img == null or img.is_empty():
		push_error("Cannot capture viewport image")
		quit(1)
		return true
	var out_dir := OUT_ROOT + "/" + _label
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out_dir))
	var path := out_dir + "/" + String(PLAN[_index]["name"]) + ".png"
	var err := img.save_png(path)
	if err != OK:
		push_error("Failed to save " + path)
		quit(1)
		return true
	var cam: Camera3D = _scene.get("cam")
	_receipt.append({
		"view": PLAN[_index]["name"], "path": path,
		"size": [img.get_width(), img.get_height()],
		"camera_position": [cam.position.x, cam.position.y, cam.position.z],
		"camera_rotation": [cam.rotation.x, cam.rotation.y, cam.rotation.z],
		"camera_size": cam.size,
	})
	print("[capture_opt_v1] saved " + path)
	_index += 1
	if _index >= PLAN.size():
		var receipt_path := out_dir + "/receipt.json"
		var file := FileAccess.open(receipt_path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify({"label": _label, "shots": _receipt}, "  "))
			file.close()
		quit(0)
		return true
	_apply()
	return false


func _apply() -> void:
	_settle = 0
	var view: Dictionary = PLAN[_index]
	_scene.call("set_view_zoom", view["zoom"], _scene.call("focus_rect", view["rect"]), 1.12, view["pitch"])
	_scene.call("set_caption", String(view["name"]), view["zoom"], view["pitch"])
