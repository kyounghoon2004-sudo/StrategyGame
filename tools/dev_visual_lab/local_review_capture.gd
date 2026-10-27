extends "res://tools/dev_visual_lab/scaled_scenery_world.gd"
## Short, native-rendered intake check; leaves the candidate interactive.
func boot() -> void:
	await super.boot()
	# Exercise the same M-key handler and verify all three exhibition LODs exist.
	var key := InputEventKey.new()
	key.keycode = KEY_M
	key.pressed = true
	_input(key)
	assert(in_exhibition and target == EXHIBITION_ORIGIN)
	_input(key)
	assert(not in_exhibition)
	lock_detail = false
	camera.size = 600.0
	update_lod()
	for item in exhibition_massifs:
		assert(item["lods"].size() == 3)
		assert(item["lods"][2].visible)
	lock_detail = true
	update_lod()
	for item in exhibition_massifs: assert(item["lods"][0].visible)
	print("[LocalReview] M-key handler and 25 massif LOD transitions passed.")
	var review_dir := OS.get_environment("SG_VISUAL_REVIEW_OUT")
	if review_dir.is_empty():
		return
	DirAccess.make_dir_recursive_absolute(review_dir)
	var saved_target := target
	var saved_size := camera.size
	var saved_yaw := yaw
	var saved_orbit := orbit
	var saved_ui := ui.visible
	ui.visible = false
	root.size = Vector2i(1600, 900)
	DisplayServer.window_set_size(Vector2i(1600, 900))
	lock_detail = true
	active_kit_lod = 0
	if unit_manager != null: unit_manager.forced_detail = 0
	var shots := [
		{"name":"candidate-castle-hq.png", "target":center(4,3).lerp(center(4,4),0.45), "size":80.0, "yaw":0.12, "orbit":0.72},
		{"name":"candidate-village.png", "target":center(-3,1).lerp(center(-2,1),0.40), "size":80.0, "yaw":0.12, "orbit":0.72},
		{"name":"candidate-exhibition.png", "target":EXHIBITION_ORIGIN+Vector3(250,20,100), "size":2150.0, "yaw":0.12, "orbit":0.85},
		{"name":"candidate-junction.png", "target":Vector3(162,0,-124.70765686), "size":55.0, "yaw":0.12, "orbit":0.72}
	]
	for shot in shots:
		target = shot["target"]
		camera.size = shot["size"]
		yaw = shot["yaw"]
		orbit = shot["orbit"]
		update_camera()
		update_lod()
		await wait_frames(8)
		await RenderingServer.frame_post_draw
		var image := root.get_texture().get_image()
		var result := image.save_png(review_dir.path_join(shot["name"]))
		print("[LocalReview] capture ", shot["name"], " result=", result)
	print("[LocalReview] castles=", scaled_castles_root.get_child_count(), " buildings=", buildings_ready, " massifs=", exhibition_massifs.size(), " units=", unit_manager.entries.size(), " road_report=", road_builder.report)
	target = saved_target
	camera.size = saved_size
	yaw = saved_yaw
	orbit = saved_orbit
	lock_detail = false
	if unit_manager != null: unit_manager.forced_detail = -1
	ui.visible = saved_ui
	update_camera()
	update_lod()
	print("[LocalReview] Interactive candidate ready.")
