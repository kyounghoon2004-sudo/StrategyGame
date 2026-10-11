extends SceneTree

## Structural ground census and same-camera contribution capture for the live
## production layout. No game resources or scene state are saved.
## Run windowed: godot --path <project> -s res://tools/perf_full_map_ground.gd
const OUT := "res://evidence/full_map_ground_optimization"
const VIEW_SPECS := [
	["open_grass", "tile_open_grassland", 0],
	["scrub_rough", "tile_scrub", 2],
	["rocky", "tile_rocky_ground", 1],
	["packed_trail", "tile_packed_dirt", 6],
	["cultivated", "tile_cultivated_edge", 0],
	["wet_lowland", "tile_wet_lowland", 3],
	["gameplay_overview", "", -1],
	["true_close", "tile_open_grassland", 0],
]
const WARMUP := 5
const SAMPLE := 4

var shell: Node
var view: Node
var layer: Node
var ground: Node3D
var menu_frame := 0
var start_ms := 0
var view_index := -1
var phase := 0 # 0: ground visible; 1: ground hidden
var phase_frame := 0
var phase_samples: Array = []
var views: Array = []
var selected: Array = []
var census: Dictionary = {}
var viewport_rid: RID

func _initialize() -> void:
	start_ms = Time.get_ticks_msec()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	change_scene_to_file("res://scenes/title_screen.tscn")

func _process(_delta: float) -> bool:
	if Time.get_ticks_msec() - start_ms > 600000:
		push_error("Ground capture timed out")
		quit(1)
		return true
	if current_scene != null and current_scene.scene_file_path == "res://scenes/title_screen.tscn":
		if menu_frame == 0:
			var collection: Node = current_scene.get("_map_collection")
			if collection == null:
				return false
			collection.call("open")
		menu_frame += 1
		if menu_frame == 8:
			var button: Node = current_scene.find_child("OpenExistingProductionLayout", true, false)
			if button == null:
				push_error("Production layout DEV button missing")
				quit(1)
				return true
			button.emit_signal("pressed")
		return false
	if view_index >= 0 or current_scene == null:
		return false
	shell = current_scene
	view = shell.get("_view3d")
	if view == null or not bool(view.call("is_active")):
		return false
	layer = view.get("strict_transplant")
	if layer == null or not bool(layer.get("built")):
		return false
	ground = layer.get_node_or_null("GroundAllPlayableHexes") as Node3D
	if ground == null:
		push_error("Live production ground root missing")
		quit(1)
		return true
	viewport_rid = root.get_viewport().get_viewport_rid()
	var camera: Node = shell.get("camera")
	camera.set_process(false)
	camera.set_process_input(false)
	camera.set_process_unhandled_input(false)
	census = _ground_census(ground)
	selected = _choose_views(layer.get("records"))
	view_index = 0
	_apply_view()
	RenderingServer.frame_post_draw.connect(_after_draw)
	return false

func _choose_views(records: Array) -> Array:
	var picks: Array = []
	for spec in VIEW_SPECS:
		var name: String = spec[0]
		if name == "gameplay_overview":
			picks.append({"name": name, "q": -4, "r": 2, "zoom": 1.15, "tile": "mixed"})
			continue
		if name == "true_close":
			picks.append({"name": name, "q": 0, "r": 0, "zoom": 6.0, "tile": "tile_open_grassland", "terrain": 0})
			continue
		var best: Dictionary = {}
		var best_distance := 2147483647
		for record in records:
			if String(record["tile"]) != spec[1] or int(record["terrain"]) != spec[2]:
				continue
			var pair := String(record["hex"]).split(",")
			var q := int(pair[0])
			var r := int(pair[1])
			var distance := maxi(absi(q), maxi(absi(r), absi(q + r)))
			if distance < best_distance:
				best_distance = distance
				best = {"name": name, "q": q, "r": r, "zoom": 1.8, "tile": spec[1], "terrain": spec[2]}
		if best.is_empty():
			push_error("No live production tile for view " + name)
			quit(1)
			return []
		picks.append(best)
	return picks

func _apply_view() -> void:
	var spec: Dictionary = selected[view_index]
	var q: int = spec["q"]
	var r: int = spec["r"]
	var position := Vector2(q * 36.0, r * 42.0 + q * 21.0)
	var camera: Node = shell.get("camera")
	camera.call("set_zoom_level", float(spec["zoom"]), true)
	camera.call("focus_on", position, true)
	view.set("_cam_sig", Vector4.INF)
	view.call("_update_camera")
	phase = 0
	ground.visible = true
	phase_frame = 0
	phase_samples.clear()
	print("[ground_capture] view=%s axial=%d,%d" % [spec["name"], q, r])

func _after_draw() -> void:
	if view_index < 0 or view_index >= selected.size():
		return
	phase_frame += 1
	if phase_frame > WARMUP:
		phase_samples.append(_render_info())
	if phase_frame < WARMUP + SAMPLE:
		return
	var spec: Dictionary = selected[view_index]
	var path := "%s/candidate50_%s_%s.png" % [OUT, spec["name"], "ground_on" if phase == 0 else "ground_off"]
	var image: Image = root.get_texture().get_image()
	var image_error := image.save_png(path)
	var row: Dictionary
	if phase == 0:
		row = spec.duplicate(true)
		row["camera_position"] = [shell.get("camera").global_position.x, shell.get("camera").global_position.y]
		row["camera_zoom"] = shell.get("camera").zoom.x
		row["camera3d_position"] = [view.get("cam").global_position.x, view.get("cam").global_position.y, view.get("cam").global_position.z]
		row["camera3d_size"] = view.get("cam").size
		row["ground_runtime_lod"] = layer.get("report").get("ground_runtime_lod", {}).duplicate(true)
		row["ground_census"] = _ground_census(ground)
		row["ground_on"] = _median_info(phase_samples)
		row["ground_on_image"] = path
		row["ground_on_image_saved"] = image_error == OK
		views.append(row)
		phase = 1
		ground.visible = false
		phase_frame = 0
		phase_samples.clear()
		return
	row = views[views.size() - 1]
	row["ground_off"] = _median_info(phase_samples)
	row["ground_off_image"] = path
	row["ground_off_image_saved"] = image_error == OK
	var diff := {}
	for key in row["ground_on"]:
		diff[key] = int(row["ground_on"][key]) - int(row["ground_off"][key])
	row["ground_contribution"] = diff
	print("[ground_capture] RESULT " + JSON.stringify(row))
	view_index += 1
	if view_index < selected.size():
		_apply_view()
	else:
		_finish()

func _render_info() -> Dictionary:
	var visible := RenderingServer.VIEWPORT_RENDER_INFO_TYPE_VISIBLE
	return {
		"objects": RenderingServer.viewport_get_render_info(viewport_rid, visible, RenderingServer.VIEWPORT_RENDER_INFO_OBJECTS_IN_FRAME),
		"primitives": RenderingServer.viewport_get_render_info(viewport_rid, visible, RenderingServer.VIEWPORT_RENDER_INFO_PRIMITIVES_IN_FRAME),
		"draw_calls": RenderingServer.viewport_get_render_info(viewport_rid, visible, RenderingServer.VIEWPORT_RENDER_INFO_DRAW_CALLS_IN_FRAME),
	}

func _median_info(samples: Array) -> Dictionary:
	var result := {}
	for key in samples[0]:
		var values: Array = []
		for sample in samples:
			values.append(int(sample[key]))
		values.sort()
		result[key] = values[values.size() / 2]
	return result

func _finish() -> void:
	ground.visible = true
	var report: Dictionary = layer.get("report")
	var receipt := {
		"stage": "candidate50", "route": "Title > DEV Map Collection > existing production layout",
		"scene": current_scene.scene_file_path,
		"renderer": ProjectSettings.get_setting("rendering/renderer/rendering_method"),
		"viewport_size": [root.size.x, root.size.y],
		"warmup_frames_per_phase": WARMUP, "sample_frames_per_phase": SAMPLE,
		"playable_hexes": report.get("playable_hexes", 0),
		"ground_hexes": report.get("ground_hexes", 0),
		"layout_sha256": report.get("layout_sha256_after", ""),
		"placement_sha256": report.get("placement_sha256", ""),
		"shadows_on": layer.call("shadow_count", view),
		"ground_census": census, "views": views,
	}
	var path := OUT + "/candidate50.json"
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("Could not write receipt: " + path)
		quit(1)
		return
	file.store_string(JSON.stringify(receipt, "  "))
	file.close()
	print("[ground_capture] COMPLETE " + path)
	quit(0)

func _ground_census(root_node: Node) -> Dictionary:
	var counts := {"ground_nodes": 0, "multimesh_nodes": 0, "mesh_instances": 0, "mesh_part_instances": 0, "triangles": 0, "surface_instances": 0, "unique_meshes": 0, "unique_materials": 0, "tile_counts": {}, "primitive_types": {}}
	var meshes := {}
	var materials := {}
	var mesh_details := {}
	var stack := [root_node]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		counts["ground_nodes"] += 1
		for child in node.get_children():
			stack.append(child)
		var mesh: Mesh
		var instances := 0
		var override_material: Material
		if node is MultiMeshInstance3D:
			counts["multimesh_nodes"] += 1
			var mm: MultiMesh = node.multimesh
			if mm == null or mm.mesh == null:
				continue
			mesh = mm.mesh
			instances = mm.instance_count
			override_material = node.material_override
		elif node is MeshInstance3D:
			counts["mesh_instances"] += 1
			mesh = node.mesh
			instances = 1
			override_material = node.material_override
		else:
			continue
		if mesh == null:
			continue
		counts["mesh_part_instances"] += instances
		var id := mesh.get_instance_id()
		if not meshes.has(id):
			meshes[id] = true
			var per_mesh := {"triangles": 0, "surfaces": mesh.get_surface_count()}
			for s in range(mesh.get_surface_count()):
				var primitive: int = mesh.surface_get_primitive_type(s)
				var type_name := str(primitive)
				counts["primitive_types"][type_name] = int(counts["primitive_types"].get(type_name, 0)) + 1
				if primitive == Mesh.PRIMITIVE_TRIANGLES:
					var arrays: Array = mesh.surface_get_arrays(s)
					var index_value: Variant = arrays[Mesh.ARRAY_INDEX]
					var indices := PackedInt32Array()
					if index_value is PackedInt32Array:
						indices = index_value
					var count := indices.size() if not indices.is_empty() else (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
					per_mesh["triangles"] += count / 3
				var material: Material = mesh.surface_get_material(s)
				if material != null:
					materials[material.get_instance_id()] = true
			mesh_details[id] = per_mesh
		counts["triangles"] += int(mesh_details[id]["triangles"]) * instances
		counts["surface_instances"] += int(mesh_details[id]["surfaces"]) * instances
		if override_material != null:
			materials[override_material.get_instance_id()] = true
	counts["unique_meshes"] = meshes.size()
	counts["unique_materials"] = materials.size()
	for record in layer.get("records"):
		var tile := String(record["tile"])
		counts["tile_counts"][tile] = int(counts["tile_counts"].get(tile, 0)) + 1
	return counts
