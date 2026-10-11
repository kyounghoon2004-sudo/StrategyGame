extends SceneTree

## DEV check: open a watch match windowed and save a screenshot of the opening view to CAM_OUT (.png).

const WatchCls = preload("res://scripts/cloud_pipeline/watch_llm_vs_utility.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	WatchCls.start_match(self, "mild", 1, "BASIC", "BULWARK")
	var until := Time.get_ticks_msec() + 7000
	while Time.get_ticks_msec() < until:
		await process_frame
	var c := current_scene.get_node("Battle").get("camera") as Camera2D
	print("[cam] zoom=%.3f pos=%s rot=%.2f persp=%s" % [c.zoom.x, str(c.global_position), c.rotation, str(current_scene.get_node("Battle").get("present_perspective"))])
	root.get_texture().get_image().save_png(OS.get_environment("CAM_OUT"))
	quit(0)
