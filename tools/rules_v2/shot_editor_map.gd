extends "res://tools/dev_visual_lab/map_editor.gd"
## Capture a DEV map as the map editor draws it (windowed):
## SG_MAP_EDITOR_OPEN=<map id> godot --path . --script res://tools/rules_v2/shot_editor_map.gd -- <out.png> [camera_size]

func boot() -> void:
	super()
	for i in 20:
		await process_frame
	var args := OS.get_cmdline_user_args()
	if args.size() > 1:
		camera.size = float(args[1]); update_camera()
	for i in 20:
		await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(args[0])
	print("[SHOT] saved ", args[0], " objects=", doc.objects.size(), " radius=", doc.get("radius"))
	quit()
