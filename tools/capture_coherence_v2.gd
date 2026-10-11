extends SceneTree

const Hex = preload("res://scripts/core/hex_utils.gd")
var shell: Node
var output: String = "res://evidence/coherence_v2/candidate"

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--output="): output = arg.trim_prefix("--output=")
	root.size = Vector2i(1920, 1080)
	root.content_scale_size = root.size
	call_deferred("run")

func run() -> void:
	DirAccess.make_dir_recursive_absolute(output)
	shell = load("res://scenes/step2r_battlefield_shell.tscn").instantiate()
	if output.ends_with("baseline"): shell.set_script(load("res://evidence/coherence_v2/baseline/runtime/shell.gd"))
	root.add_child(shell)
	print("[Capture] shell added; awaiting frames")
	for warmup in range(60): await process_frame
	print("[Capture] warmup complete")
	var cells: Dictionary = shell.get_node("HexGrid").get("cell_data")
	assert(cells.size() == 4921)
	var fog: RefCounted = shell.get("_fog")
	var counts: Array[int] = [0, 0, 0]
	var explored: Vector2i = Vector2i.ZERO
	for key in cells:
		var parts: PackedStringArray = str(key).split(",")
		var h := Vector2i(int(parts[0]), int(parts[1]))
		var state: int = fog.get_fog_state(h.x, h.y)
		counts[state] += 1
		if state == 1: explored = h
	var shots: Array = [
		["01_macro", Vector2.ZERO, 0.30],
		["02_mountain_pass", Vector2(390, -680), 1.15],
		["03_central_approach", Hex.hex_to_pixel(0, 0), 1.15],
		["04_forest", Hex.hex_to_pixel(-22, 0), 1.15],
		["05_explored", Hex.hex_to_pixel(explored.x, explored.y), 1.65],
		["06_unexplored", Hex.hex_to_pixel(14, -20), 1.15],
		["07_readability", Hex.hex_to_pixel(-24, 6), 2.5],
		["08_river", Hex.hex_to_pixel(-4, 14), 1.15],
		["09_hex_stronghold", Vector2(-132,21), 3.02],
		["10_hex_capital", Vector2(516,105), 3.02]]
	var camera: Camera2D = shell.get_node("Camera2D")
	var frames: Array[float] = []
	var shot_manifest: Array[Dictionary] = []
	for shot in shots:
		shell.get_node("MountainVisualReview").set_hover_hex(Vector2i(-24,6) if shot[0] == "07_readability" else Vector2i(-999,-999))
		for layer in shell.find_children("*", "CanvasLayer", true, false):
			layer.visible = shot[0] == "07_readability"
		camera.set_process(false)
		camera.focus_on(shot[1], true)
		camera.set_zoom_level(shot[2], true)
		camera.force_update_scroll()
		shell.call("_on_camera_updated", camera.global_position, float(shot[2]))
		for node_name in ["PaintedTerrain", "MountainVisualReview"]:
			shell.get_node(node_name).queue_redraw()
		for settle in range(8): await process_frame
		await process_frame
		RenderingServer.force_draw(false)
		var img: Image = root.get_texture().get_image()
		assert(img != null and not img.is_empty())
		assert(img.save_png(output + "/" + shot[0] + ".png") == OK)
		shot_manifest.append({"file": shot[0] + ".png", "camera": [camera.global_position.x,camera.global_position.y], "zoom": shot[2], "hud_visible": shot[0] == "07_readability"})
		print("[CoherenceCapture] ", shot[0])
	var grammar: Node = shell.get_node("MountainVisualReview")
	var painted: Node = shell.get_node("PaintedTerrain")
	var landmark_checks: Array[Dictionary] = []
	for landmark in painted.get_children():
		if not landmark.has_meta("footprint"): continue
		var occupied: Array = landmark.get_meta("footprint")
		var size: Vector2 = landmark.get_meta("display_size")
		assert(occupied.size() == 1 or occupied.size() == 3)
		assert(landmark.get_child(0).material != null)
		landmark_checks.append({"occupied_hex_count":occupied.size(),"width":size.x,"height":size.y,"ground_mask_enabled":true,"roof_overhang_allowed":true})
	var fog_before: String = JSON.stringify([fog.visible, fog.explored])
	var units_before: String = JSON.stringify(shell.get("unit_manager").get_all_units_including_garrisoned())
	grammar.set_fog(fog)
	assert(JSON.stringify([fog.visible, fog.explored]) == fog_before)
	assert(JSON.stringify(shell.get("unit_manager").get_all_units_including_garrisoned()) == units_before)
	var transition_ms: Array[float] = []
	if not output.ends_with("baseline"):
		# Isolated presentation fixture; never mutate the real battle's fog dictionaries.
		var fixture: RefCounted = fog.get_script().new()
		fixture.visible = fog.visible.duplicate()
		fixture.explored = fog.explored.duplicate()
		fixture.objective_hexes = fog.objective_hexes.duplicate()
		var key: String = "-24,6"
		var field: Node = grammar.get("_terrain_field")
		var pixel: int = field.get("_pixel_ids")[key][0]
		fixture.visible.erase(key)
		fixture.explored[key] = true
		grammar.set_fog(fixture)
		assert(field.get("_fog_bytes")[pixel*4] == 87)
		transition_ms.append(field.get("fog_update_ms"))
		fixture.explored.erase(key)
		grammar.set_fog(fixture)
		assert(field.get("_fog_bytes")[pixel*4] == 255)
		transition_ms.append(field.get("fog_update_ms"))
		grammar.set_fog(fog)
		assert(field.get("_fog_bytes")[pixel*4] == 0)
		assert(JSON.stringify([fog.visible, fog.explored]) == fog_before)
	var occupancy: Dictionary = grammar.get("_occupancy")
	assert(occupancy.size() == 4921)
	for cell in occupancy.values(): assert(cell["base_claimed"])
	grammar.set_selected_hex(Vector2i(-24,6))
	painted.set_selected_hex(Vector2i(-24,6))
	for settle in range(4): await process_frame
	var redraws: Dictionary = {"count": 0}
	painted.draw.connect(func() -> void: redraws["count"] += 1)
	for i in range(90):
		var start: int = Time.get_ticks_usec()
		await process_frame
		frames.append(float(Time.get_ticks_usec() - start) / 1000.0)
	frames.sort()
	var report: Dictionary = {"cells": cells.size(), "fog_counts_unexplored_explored_visible": counts,
		"explored_shot_hex": [explored.x, explored.y], "explored_state": fog.get_fog_state(explored.x, explored.y),
		"unexplored_state": fog.get_fog_state(14, -20), "frame_ms_median": frames[45], "frame_ms_p95": frames[85],
		"grammar": grammar.get("_stats"), "shots": shot_manifest,
		"static_map_redraws_during_90_selected_frames": redraws["count"],
		"fog_and_units_unchanged_by_presentation": true,
		"ground_node_count": grammar.get_node("GroundLayer").get_child_count(),
		"draw_calls_last_frame": Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)}
	report["isolated_fog_transition_ms"] = transition_ms
	report["landmark_containment"] = landmark_checks
	if not output.ends_with("baseline"):
		var field: Node = grammar.get("_terrain_field")
		report["last_fog_rebuild_ms"] = field.get("fog_update_ms")
		assert(redraws["count"] == 0)
		assert(grammar.get_node("FogAtmosphericOverlay").get_child_count() == 1)
		assert(grammar.get_node("GroundLayer").get_child_count() == 1)
	var file := FileAccess.open(output + "/runtime.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "\t"))
	print("[CoherenceCapture] ", JSON.stringify(report))
	quit()
