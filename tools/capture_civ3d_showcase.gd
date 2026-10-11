extends SceneTree

## CIV3D showcase capture (VISUAL CHECK ONLY): enters the default map like
## play_civ3d.gd, then saves stills (HUD + minimap, unit close-ups) and frame
## sequences for GIFs (everyone attacks; cavalry charge).
##   Godot --path <project> --script res://tools/capture_civ3d_showcase.gd

const OUT := "res://evidence/civ3d_showcase/"
const Hex = preload("res://scripts/core/hex_utils.gd")

var shell: Node
var view: Node
var menu_frames := 0
var steps: Array = []
var si := -1
var frames := 0
var seq_left := 0
var seq_name := ""
var seq_i := 0

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
	if si == -1:
		if current_scene == null:
			return false
		shell = current_scene
		view = shell.get("_view3d")
		if view == null or not bool(view.call("is_active")):
			return false
		_plan()
		si = 0
		_begin()
		return false
	if seq_left > 0:
		return false # frames are saved in frame_post_draw
	frames += 1
	if frames < int(steps[si].get("wait", 40)):
		return false
	var st: Dictionary = steps[si]
	if st["kind"] == "shot":
		RenderingServer.frame_post_draw.connect(_save_shot.bind(st["name"]), CONNECT_ONE_SHOT)
		frames = -100000
	else:
		if st.has("call"):
			_all(st["call"], st.get("cls", ""))
		seq_name = st["name"]
		seq_left = int(st["frames"])
		seq_i = 0
		RenderingServer.frame_post_draw.connect(_save_seq)
	return false

func _plan() -> void:
	var inf := _unit_pos(["infantry", "archer", "spearman", "conscript"])
	var cav := _unit_pos(["cavalry"])
	var hq := _unit_pos(["hq"])
	steps = [
		{"kind": "shot", "name": "01_home_hud", "focus": null, "zoom": 1.1, "wait": 70},
		{"kind": "shot", "name": "02_army_close", "focus": inf, "zoom": 3.4},
		{"kind": "seq", "name": "attack", "focus": inf, "zoom": 4.0, "frames": 90, "call": "play_attack"},
		{"kind": "shot", "name": "03_general_close", "focus": hq, "zoom": 3.6},
		{"kind": "shot", "name": "04_cavalry_close", "focus": cav, "zoom": 3.6},
		{"kind": "seq", "name": "charge", "focus": cav, "zoom": 4.0, "frames": 60, "call": "play_attack", "cls": "cavalry"},
		{"kind": "shot", "name": "05_overview_minimap", "focus": Vector2.ZERO, "zoom": 0.45},
	]

func _unit_pos(classes: Array) -> Vector2:
	var ur: Node = shell.get("unit_renderer")
	for u in ur.call("get_all_units"):
		if str(u.get("faction", "")) == "blue" and str(u.get("class", "")) in classes:
			return Hex.hex_to_pixel(int(u.get("q", 0)), int(u.get("r", 0)))
	return Vector2.ZERO

func _begin() -> void:
	var st: Dictionary = steps[si]
	var cam: Node = shell.get("camera")
	if st["focus"] == null:
		cam.call("reset_view")
		cam.call("set_zoom_level", float(st["zoom"]), true)
		cam.set("global_position", cam.get("target_position"))
	else:
		cam.call("set_zoom_level", float(st["zoom"]), true)
		cam.call("focus_on", st["focus"], true)
	frames = 0
	print("[Showcase] ", st["name"])

func _next() -> void:
	si += 1
	if si >= steps.size():
		print("[Showcase] COMPLETE")
		quit()
		return
	_begin()

func _save_shot(name: String) -> void:
	root.get_texture().get_image().save_png(OUT + name + ".png")
	_next()

func _save_seq() -> void:
	var img := root.get_texture().get_image()
	img = img.get_region(Rect2i(560, 240, 800, 600)) # centre of the screen, full resolution
	img.save_png(OUT + "%s_%03d.png" % [seq_name, seq_i])
	seq_i += 1
	seq_left -= 1
	if seq_left <= 0:
		RenderingServer.frame_post_draw.disconnect(_save_seq)
		_next()

func _all(method: String, cls: String) -> void:
	var units: Dictionary = view.get("_units")
	var ur: Node = shell.get("unit_renderer")
	var cls_of := {}
	for u in ur.call("get_all_units"):
		cls_of[str(u.get("id", ""))] = str(u.get("class", ""))
	for id in units.keys():
		if cls != "" and cls_of.get(id, "") != cls:
			continue
		var f: Node = units[id].get("f3d")
		if f != null and is_instance_valid(f):
			f.call(method)
