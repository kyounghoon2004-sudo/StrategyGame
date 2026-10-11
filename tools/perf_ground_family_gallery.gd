extends SceneTree

## Source-family review only. These eight GLB tile families are instanced in an
## isolated viewport; the two unused families are not added to production cells.
const Builder = preload("res://scripts/visual/map_composition_v0/map_composition_builder.gd")
const OUT := "res://evidence/full_map_ground_optimization"
const KEYS := [
	"tile_open_grassland", "tile_dry_earth", "tile_scrub", "tile_rocky_ground",
	"tile_packed_dirt", "tile_worn_crossing", "tile_cultivated_edge", "tile_wet_lowland",
]
const PRODUCTION_KEYS := [
	"tile_open_grassland", "tile_scrub", "tile_rocky_ground",
	"tile_packed_dirt", "tile_cultivated_edge", "tile_wet_lowland",
]

var viewport: SubViewport
var frame := 0
var tiles: Array = []

func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	call_deferred("_build_gallery")

func _build_gallery() -> void:
	viewport = SubViewport.new()
	viewport.name = "GroundFamilyReview"
	viewport.size = Vector2i(1920, 1080)
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.transparent_bg = false
	viewport.own_world_3d = true
	root.add_child(viewport)
	var world := Node3D.new()
	world.name = "EightTileSourceGallery"
	viewport.add_child(world)
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.10, 0.12, 0.14)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(1, 1, 1)
	environment.ambient_light_energy = 0.8
	var world_environment := WorldEnvironment.new()
	world_environment.environment = environment
	world.add_child(world_environment)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-55, -35, 0)
	light.light_energy = 1.1
	light.shadow_enabled = false
	world.add_child(light)
	for i in range(KEYS.size()):
		var key: String = KEYS[i]
		var tile: Node3D = Builder.build_tile(key, Builder.TILE_Y_FACTOR)
		var column := i % 4
		var row := i / 4
		tile.position = Vector3((column - 1.5) * 62.0, 0.0, (row - 0.5) * 72.0)
		world.add_child(tile)
		_disable_shadows(tile)
		var caption := Label3D.new()
		caption.text = key.trim_prefix("tile_").replace("_", " ")
		caption.font_size = 32
		caption.pixel_size = 0.035
		caption.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		caption.no_depth_test = true
		caption.position = tile.position + Vector3(0, 1, 28)
		world.add_child(caption)
		var stats := _tile_census(tile)
		stats["key"] = key
		stats["used_in_current_production_layout"] = PRODUCTION_KEYS.has(key)
		stats["grid_column"] = column
		stats["grid_row"] = row
		tiles.append(stats)
	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 190.0
	world.add_child(camera)
	camera.position = Vector3(0, 240, 180)
	camera.look_at(Vector3.ZERO, Vector3.UP)
	camera.current = true
	print("[ground_gallery] camera=%s world=%s" % [str(viewport.get_camera_3d()), str(viewport.world_3d)])
	RenderingServer.frame_post_draw.connect(_after_draw)

func _process(_delta: float) -> bool:
	frame += 1
	if frame > 120:
		push_error("Gallery viewport did not produce capture")
		quit(1)
	return false

func _after_draw() -> void:
	if frame < 12:
		return
	RenderingServer.frame_post_draw.disconnect(_after_draw)
	var image: Image = viewport.get_texture().get_image()
	var image_path := OUT + "/baseline_eight_tile_source_gallery.png"
	var image_error := image.save_png(image_path)
	var report := {
		"purpose": "isolated authored source-family review; production terrain assignments unchanged",
		"source_asset_master_untouched": true,
		"production_tile_keys": PRODUCTION_KEYS,
		"not_assigned_in_current_production_layout": ["tile_dry_earth", "tile_worn_crossing"],
		"camera_projection": "orthographic", "camera_size": 190.0,
		"camera_position": [0, 240, 180], "viewport_size": [1920, 1080],
		"tile_y_factor": Builder.TILE_Y_FACTOR,
		"tiles_row_major": tiles,
		"image": image_path, "image_saved": image_error == OK,
	}
	var path := OUT + "/baseline_eight_tile_source_gallery.json"
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("Could not write gallery receipt: " + path)
		quit(1)
		return
	file.store_string(JSON.stringify(report, "  "))
	file.close()
	print("[ground_gallery] COMPLETE " + path)
	quit(0)

func _tile_census(tile: Node3D) -> Dictionary:
	var result := {"mesh_parts": 0, "surfaces": 0, "triangles": 0, "unique_materials": 0, "parts": []}
	var materials := {}
	var stack := [tile]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child in node.get_children():
			stack.append(child)
		if not node is MeshInstance3D:
			continue
		var mesh: Mesh = node.mesh
		if mesh == null:
			continue
		result["mesh_parts"] += 1
		result["surfaces"] += mesh.get_surface_count()
		var part := {"node": String(node.name), "mesh": mesh.resource_name, "triangles": 0, "surfaces": []}
		for s in range(mesh.get_surface_count()):
			var surface := {"index": s, "triangles": 0, "indexed": false, "vertex_colors": false, "normals": false}
			if mesh.surface_get_primitive_type(s) == Mesh.PRIMITIVE_TRIANGLES:
				var arrays: Array = mesh.surface_get_arrays(s)
				var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
				var count := indices.size() if not indices.is_empty() else (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
				result["triangles"] += count / 3
				part["triangles"] += count / 3
				surface["triangles"] = count / 3
				surface["indexed"] = not indices.is_empty()
				surface["vertex_colors"] = arrays[Mesh.ARRAY_COLOR] is PackedColorArray and not arrays[Mesh.ARRAY_COLOR].is_empty()
				surface["normals"] = arrays[Mesh.ARRAY_NORMAL] is PackedVector3Array and not arrays[Mesh.ARRAY_NORMAL].is_empty()
				if String(node.name).begins_with("root_grass_islands_"):
					surface["vertex_count"] = (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
					surface["index_count"] = indices.size()
					surface["components_by_indices"] = _index_components(indices, surface["vertex_count"])
					surface["components_by_position"] = _position_components(indices, arrays[Mesh.ARRAY_VERTEX])
			var material: Material = node.get_surface_override_material(s)
			if material == null:
				material = mesh.surface_get_material(s)
			if material != null:
				materials[material.get_instance_id()] = true
				surface["material"] = material.resource_name
			part["surfaces"].append(surface)
		result["parts"].append(part)
	result["unique_materials"] = materials.size()
	return result

func _index_components(indices: PackedInt32Array, vertex_count: int) -> Dictionary:
	var parents := PackedInt32Array()
	parents.resize(vertex_count)
	for v in range(vertex_count):
		parents[v] = v
	for i in range(0, indices.size(), 3):
		var a := indices[i]
		for j in range(1, 3):
			var b := indices[i + j]
			while parents[a] != a:
				a = parents[a]
			while parents[b] != b:
				b = parents[b]
			if a != b:
				parents[b] = a
	var components := {}
	for i in range(0, indices.size(), 3):
		var root_vertex := indices[i]
		while parents[root_vertex] != root_vertex:
			root_vertex = parents[root_vertex]
		components[root_vertex] = int(components.get(root_vertex, 0)) + 1
	var histogram := {}
	for count in components.values():
		var key := str(count)
		histogram[key] = int(histogram.get(key, 0)) + 1
	return {"count": components.size(), "triangles_per_component": histogram}

func _position_components(indices: PackedInt32Array, vertices: PackedVector3Array) -> Dictionary:
	var triangle_count := indices.size() / 3
	var parents := PackedInt32Array()
	parents.resize(triangle_count)
	for t in range(triangle_count):
		parents[t] = t
	var first_at_position := {}
	for t in range(triangle_count):
		for corner in range(3):
			var p: Vector3 = vertices[indices[t * 3 + corner]]
			var key := Vector3i(roundi(p.x * 10000.0), roundi(p.y * 10000.0), roundi(p.z * 10000.0))
			if not first_at_position.has(key):
				first_at_position[key] = t
				continue
			var a := t
			var b: int = first_at_position[key]
			while parents[a] != a:
				a = parents[a]
			while parents[b] != b:
				b = parents[b]
			if a != b:
				parents[b] = a
	var components := {}
	for t in range(triangle_count):
		var root_triangle := t
		while parents[root_triangle] != root_triangle:
			root_triangle = parents[root_triangle]
		components[root_triangle] = int(components.get(root_triangle, 0)) + 1
	var histogram := {}
	var largest := 0
	for count in components.values():
		var key := str(count)
		histogram[key] = int(histogram.get(key, 0)) + 1
		largest = maxi(largest, count)
	return {"count": components.size(), "largest": largest, "triangles_per_component": histogram}

func _disable_shadows(node: Node) -> void:
	if node is GeometryInstance3D:
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for child in node.get_children():
		_disable_shadows(child)
