extends SceneTree

## CIV3D march capture (VISUAL CHECK ONLY): plays the board's own move
## animation (unit renderer animate_unit_move, presentation only; no game
## state changes) for one blue infantry and one cavalry unit over a few hexes,
## and saves frames of the 3D troops marching after it at walking pace.
##   Godot --fixed-fps 30 --path <project> --script res://tools/capture_civ3d_march.gd

const OUT := "res://evidence/civ3d_march/"
const Hex = preload("res://scripts/core/hex_utils.gd")
const CASES := [["scout", 300], ["infantry", 300], ["cavalry", 210]]

var shell: Node
var view: Node
var menu_frames := 0
var ci := -1
var frames := 0
var seq_left := 0
var uid := ""
var path: Array[Vector2i] = []

func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	change_scene_to_file("res://scenes/title_screen.tscn")

func _process(_d: float) -> bool:
	if current_scene != null and current_scene.scene_file_path == "res://scenes/title_screen.tscn":
		menu_frames += 1
		if menu_frames == 8:
			var collection: Node = current_scene.get("_map_collection")
			collection.call("open")
			collection.find_child("OpenExistingProductionLayout", true, false).emit_signal("pressed")
		return false
	if ci == -1:
		if current_scene == null:
			return false
		shell = current_scene
		view = shell.get("_view3d")
		if view == null or not bool(view.call("is_active")):
			return false
		ci = 0
		_begin()
		return false
	if seq_left > 0:
		return false
	frames += 1
	if frames == 15:
		_frame_camera()
	if frames == 40:
		shell.get("unit_renderer").call("animate_unit_move", uid, path)
		seq_left = int(CASES[ci][1])
		RenderingServer.frame_post_draw.connect(_save)
	return false

func _begin() -> void:
	var cls: String = CASES[ci][0]
	var ur: Node = shell.get("unit_renderer")
	var occupied := {}
	var start := Vector2i.ZERO
	uid = ""
	for u in ur.call("get_all_units"):
		var h := Vector2i(int(u.get("q", 0)), int(u.get("r", 0)))
		occupied[h] = true
		if uid == "" and str(u.get("faction", "")) == "blue" and str(u.get("class", "")) == cls:
			uid = str(u.get("id", ""))
			start = h
	# walk up to three free hexes in whichever direction is open
	var fog: Variant = shell.get("_fog")
	path = [start]
	for dir in [Vector2i(0, -1), Vector2i(1, -1), Vector2i(-1, 0), Vector2i(1, 0), Vector2i(-1, 1), Vector2i(0, 1)]:
		var p: Array[Vector2i] = [start]
		for k in range(1, 4):
			var h: Vector2i = start + dir * k
			if occupied.has(h) or (fog != null and int(fog.call("get_fog_state", h.x, h.y)) != 2):
				break
			p.append(h)
		if p.size() > path.size():
			path = p
	print("[March] ", cls, " ", uid, " path ", path)
	_frame_camera()
	frames = 0

func _frame_camera() -> void:
	var cam: Node = shell.get("camera")
	var a: Vector2 = Hex.hex_to_pixel(path[0].x, path[0].y)
	var b: Vector2 = Hex.hex_to_pixel(path[path.size() - 1].x, path[path.size() - 1].y)
	cam.call("set_zoom_level", 3.2, true)
	cam.call("focus_on", (a + b) * 0.5, true)

func _save() -> void:
	var cls: String = CASES[ci][0]
	var img := root.get_texture().get_image()
	var a: Vector2 = Hex.hex_to_pixel(path[0].x, path[0].y)
	var b: Vector2 = Hex.hex_to_pixel(path[path.size() - 1].x, path[path.size() - 1].y)
	var mid: Vector3 = view.call("_ground3", (a + b) * 0.5)
	var c: Vector2 = (view.get("cam") as Camera3D).unproject_position(mid)
	var x: int = clampi(int(c.x) - 400, 0, img.get_width() - 800)
	var y: int = clampi(int(c.y) - 300, 0, img.get_height() - 600)
	img.get_region(Rect2i(x, y, 800, 600)).save_png(OUT + "%s_%03d.png" % [cls, int(CASES[ci][1]) - seq_left])
	seq_left -= 1
	if OS.get_environment("MARCH_DEBUG") != "" and seq_left % 15 == 0:
		var d: Dictionary = view.get("_units")[uid]
		var f: Node3D = d["f3d"]
		var h: Node3D = f.get("_soldiers")[0]["holder"] if f.get("_soldiers") != null else f.get("_mounts")[0]["holder"]
		var mdl_fwd: Vector3 = -h.global_transform.basis.z if f.get("_soldiers") != null else h.global_transform.basis.z
		print("[MarchDbg] shown ", d.get("shown"), " head ", d.get("head"), " trail ", (d.get("trail", []) as Array).size(), " model fwd ", mdl_fwd)
	if seq_left > 0:
		return
	RenderingServer.frame_post_draw.disconnect(_save)
	ci += 1
	if ci >= CASES.size():
		print("[March] COMPLETE")
		quit()
		return
	_begin()
