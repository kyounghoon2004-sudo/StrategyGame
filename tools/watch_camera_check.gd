extends SceneTree

## DEV check: does the watch scene keep the user's camera view across a match reload in the same window?
## Windowed (perspective presentation is off in headless). Writes JSON to CAM_OUT.

const WatchCls = preload("res://scripts/cloud_pipeline/watch_llm_vs_utility.gd")


func _initialize() -> void:
	call_deferred("_run")


func _cam() -> Camera2D:
	return current_scene.get_node("Battle").get("camera") as Camera2D if current_scene != null else null


func _snap(tag: String) -> Dictionary:
	var c := _cam()
	return {"tag": tag, "pos": [c.global_position.x, c.global_position.y], "zoom": c.zoom.x,
		"target_zoom": float(c.get("target_zoom")), "pan_offset": [c.get("pan_offset").x, c.get("pan_offset").y],
		"min_zoom": float(c.get("min_zoom")), "widest_ok": absf(c.zoom.x - float(c.get("min_zoom"))) < 0.001}


func _wait(s: float) -> void:
	var until := Time.get_ticks_msec() + int(s * 1000)
	while Time.get_ticks_msec() < until:
		await process_frame


func _run() -> void:
	var rows: Array = []
	WatchCls.start_match(self, "mild", 1, "BASIC", "BULWARK")
	await _wait(4.0)
	rows.append(_snap("match1_default"))
	var c := _cam()
	c.call("set_zoom_level", float(c.get("min_zoom")) * 1.05, true)
	c.call("focus_on", c.global_position + Vector2(300, -200), true)
	await _wait(1.0)
	rows.append(_snap("match1_user_set"))
	WatchCls.start_match(self, "mild", 2, "BASIC", "BULWARK")
	for t in [0.1, 1.0, 4.0, 8.0]:
		await _wait(t)
		rows.append(_snap("match2_after_%.1fs" % t))
	var f := FileAccess.open(OS.get_environment("CAM_OUT"), FileAccess.WRITE)
	f.store_string(JSON.stringify(rows, "  "))
	f.close()
	for ch in root.get_children():
		ch.queue_free()
	await _wait(10.0)
	quit(0)
