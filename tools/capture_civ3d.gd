extends SceneTree

## CIV3D capture (VISUAL ONLY): boots the default production map through the
## title -> DEV map collection route, waits for the CivBattlefieldView and
## saves framed screenshots + a picking round-trip receipt.
##   Godot_v4.2.2-stable_win64_console.exe --path <project> --script res://tools/capture_civ3d.gd

var OUT := "res://evidence/civ3d_phase1/" if OS.get_environment("SG_VIEW") != "closeup" else "res://evidence/civ3d_phase1_closeup_ab/"
## [name, axial focus (q, r) or null for the home view, zoom]
const PLAN := [
	["01_home", null, 1.1],
	["02_overview", Vector2(0, 0), 0.30],
	["03_mid", Vector2(-10, 2), 0.7],
	["04_forest_close", Vector2(-27, -5), 2.2],
	["05_village_farms", Vector2(-24, 12), 3.0],
	["06_fortress", Vector2(-4, 2), 2.5],
	["07_mountains", Vector2(11, -14), 1.6],
	["08_closest", Vector2(-20, 0), 4.0],
]
var shell: Node
var view: Node
var index := -1
var frames := 0
var shots: Array = []
var fps_time := 0.0
var fps_frames := 0
var menu_frames := 0
var finishing := false
var shot_time := 0.0

func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	change_scene_to_file("res://scenes/title_screen.tscn")

func _process(delta: float) -> bool:
	if finishing:
		return false
	if current_scene != null and current_scene.scene_file_path == "res://scenes/title_screen.tscn":
		menu_frames += 1
		if menu_frames == 8:
			var collection: Node = current_scene.get("_map_collection")
			collection.call("open")
			collection.find_child("OpenExistingProductionLayout", true, false).emit_signal("pressed")
		return false
	if index == -1:
		if current_scene == null:
			return false
		shell = current_scene
		view = shell.get("_view3d")
		if view == null or not bool(view.call("is_active")):
			return false
		print("[Civ3DCapture] view = ", view.name)
		index = 0
		apply_shot()
		return false
	frames += 1
	if frames == 6:
		shot_time = 0.0
	elif frames > 6:
		shot_time += delta
	if frames < 26:
		return false
	if index < PLAN.size():
		RenderingServer.frame_post_draw.connect(save_shot, CONNECT_ONE_SHOT)
		frames = -1000000
		return false
	fps_time += delta
	fps_frames += 1
	if fps_frames < 60:
		return false
	var report := {"view": str(view.name), "shots": shots, "rough_fps": float(fps_frames) / fps_time,
		"renderer": ProjectSettings.get_setting("rendering/renderer/rendering_method")}
	var f := FileAccess.open(OUT + "receipt.json", FileAccess.WRITE)
	f.store_string(JSON.stringify(report, "  "))
	f.close()
	print("[Civ3DCapture] COMPLETE " + JSON.stringify(report))
	finishing = true
	call_deferred("finish_cleanly")
	return false

func apply_shot() -> void:
	var entry: Array = PLAN[index]
	var camera: Node = shell.get("camera")
	if entry[1] == null:
		camera.call("reset_view")
		camera.call("set_zoom_level", float(entry[2]), true)
		camera.set("global_position", camera.get("target_position"))
	else:
		var q: Vector2 = entry[1]
		camera.call("set_zoom_level", float(entry[2]), true)
		camera.call("focus_on", Vector2(q.x * 36.0, q.y * 42.0 + q.x * 21.0), true)
	frames = 0
	print("[Civ3DCapture] " + entry[0])

func save_shot() -> void:
	var path: String = OUT + PLAN[index][0] + ".png"
	var img := root.get_texture().get_image()
	var err := img.save_png(path)
	var max_error := 0.0
	var checked := 0
	var cells: Dictionary = shell.get("hex_grid").get("cell_data")
	var rect := Rect2(Vector2(40, 40), Vector2(img.get_size()) - Vector2(80, 80))
	for c in cells.values():
		var w := Vector2(float(c.q) * 36.0, float(c.r) * 42.0 + float(c.q) * 21.0)
		var screen: Vector2 = view.call("world_to_screen", w)
		if not rect.has_point(screen):
			continue
		checked += 1
		if checked % 7 != 0:
			continue
		var back: Vector2 = view.call("screen_to_world", screen)
		max_error = maxf(max_error, back.distance_to(w))
	shots.append({"path": path, "saved": err == OK, "hexes_in_frame": checked, "max_picking_roundtrip_world_px": max_error, "fps": 19.0 / maxf(shot_time, 0.001)})
	index += 1
	frames = 0
	if index < PLAN.size():
		apply_shot()

func finish_cleanly() -> void:
	current_scene.queue_free()
	await process_frame
	await process_frame
	quit()
