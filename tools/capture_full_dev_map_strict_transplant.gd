extends SceneTree

const OUT := "res://evidence/full_dev_map_strict_transplant/"
const PLAN := [
	["01_full_map_overview", Vector2(0, 0), 0.30],
	["02_full_map_second", Vector2(0, 0), 0.30],
	["03_forest", Vector2(-27, -5), 1.30],
	["04_village_agriculture", Vector2(-24, 12), 1.80],
	["05_fortress", Vector2(-4, 2), 2.50],
	["06_capital", Vector2(14, -5), 2.50],
	["07_mountains", Vector2(11, -14), 1.80],
	["08_mountain_range", Vector2(17, -23), 0.80],
	["09_gameplay_distance", Vector2(-4, 2), 1.15],
]
var shell: Node
var view: Node
var layer: Node
var index := -1
var frames := 0
var shots: Array = []
var fps_time := 0.0
var fps_frames := 0
var menu_frames := 0
var finishing := false

func _initialize() -> void:
	change_scene_to_file("res://scenes/title_screen.tscn")

func _process(delta: float) -> bool:
	if finishing:
		return false
	if current_scene != null and current_scene.scene_file_path == "res://scenes/title_screen.tscn":
		var collection: Node = current_scene.get("_map_collection")
		collection.call("open")
		menu_frames += 1
		if menu_frames == 8:
			RenderingServer.frame_post_draw.connect(func():
				root.get_texture().get_image().save_png(OUT + "00_dev_menu_entry.png")
				collection.find_child("OpenExistingProductionLayout", true, false).emit_signal("pressed")
			, CONNECT_ONE_SHOT)
		return false
	if index == -1:
		if current_scene == null:
			return false
		shell = current_scene
		view = shell.get("_view3d")
		if view == null or not bool(view.call("is_active")):
			return false
		layer = view.get("strict_transplant")
		if layer == null or not bool(layer.get("built")):
			return false
		index = 0
		apply_shot()
		return false
	frames += 1
	if frames < 8:
		return false
	if index < PLAN.size():
		RenderingServer.frame_post_draw.connect(save_shot, CONNECT_ONE_SHOT)
		frames = -1000000
		return false
	fps_time += delta
	fps_frames += 1
	if fps_frames < 30:
		return false
	var report: Dictionary = layer.get("report").duplicate(true)
	report["shots"] = shots
	report["rough_fps"] = float(fps_frames) / fps_time
	report["scene"] = current_scene.scene_file_path
	report["launch_route"] = "Title -> DEV Map Collection -> existing production layout button"
	report["sandbox"] = shell.get("is_step0_sandbox")
	report["shadows_on_whole_view"] = layer.shadow_count(view)
	report["layout_sha256_after_capture"] = layer.layout_snapshot(shell).sha256_text()
	var f := FileAccess.open(OUT + "receipt.json", FileAccess.WRITE)
	f.store_string(JSON.stringify(report, "  "))
	f.close()
	var rows := FileAccess.open(OUT + "placements.json", FileAccess.WRITE)
	rows.store_string(JSON.stringify(layer.get("records"), "  "))
	rows.close()
	print("[StrictCapture] COMPLETE " + JSON.stringify(report))
	finishing = true
	call_deferred("finish_cleanly")
	return false

func apply_shot() -> void:
	var entry: Array = PLAN[index]
	var q: Vector2 = entry[1]
	var p := Vector2(q.x * 36.0, q.y * 42.0 + q.x * 21.0)
	var camera: Node = shell.get("camera")
	camera.call("set_zoom_level", float(entry[2]), true)
	camera.call("focus_on", p, true)
	view.set("_cam_sig", Vector4.INF)
	view.call("_update_camera")
	# Second framing uses the very same live scene from the opposite side.
	if index == 1:
		view.set("fwd", -view.get("fwd"))
		view.set("_cam_sig", Vector4.INF)
		view.call("_update_camera")
	elif index == 2:
		view.set("fwd", -view.get("fwd"))
		view.set("_cam_sig", Vector4.INF)
		view.call("_update_camera")
	frames = 0
	print("[StrictCapture] " + entry[0])

func save_shot() -> void:
	var path: String = OUT + PLAN[index][0] + ".png"
	var img := root.get_texture().get_image()
	var err := img.save_png(path)
	var max_error := 0.0
	var in_frame := 0
	var cells: Dictionary = shell.get("hex_grid").get("cell_data")
	for c in cells.values():
		var w := Vector2(float(c.q) * 36.0, float(c.r) * 42.0 + float(c.q) * 21.0)
		var screen: Vector2 = view.call("world_to_screen", w)
		var back: Vector2 = view.call("screen_to_world", screen)
		max_error = maxf(max_error, back.distance_to(w))
		if Rect2(Vector2.ZERO, Vector2(img.get_size())).has_point(screen):
			in_frame += 1
	shots.append({"path": path, "saved": err == OK, "width": img.get_width(), "height": img.get_height(), "hex_centers_in_frame": in_frame, "max_picking_roundtrip_world_px": max_error})
	index += 1
	frames = 0
	if index < PLAN.size():
		apply_shot()


func finish_cleanly() -> void:
	current_scene.queue_free()
	await process_frame
	await process_frame
	quit()
