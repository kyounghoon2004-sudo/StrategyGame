extends SceneTree

## Project-only, reproducible whole-blade grass reduction. Source GLBs stay
## untouched; this writes one grass-only ArrayMesh resource per authored tile.
const Builder = preload("res://scripts/visual/map_composition_v0/map_composition_builder.gd")
const Lib = preload("res://scripts/visual/map_composition_v0/map_composition_library.gd")
const OUT := "res://assets/map_composition_v0/runtime_derivatives/ground_50pct"
const FRACTION := 0.50
const GRID := 12
const POSITION_QUANTIZE := 10000.0
const SOURCE_INVENTORY := "res://evidence/full_map_ground_optimization/source_hashes_before.json"
const KEYS := [
	"tile_open_grassland", "tile_dry_earth", "tile_scrub", "tile_rocky_ground",
	"tile_packed_dirt", "tile_worn_crossing", "tile_cultivated_edge", "tile_wet_lowland",
]

var receipts: Array = []

func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	call_deferred("_generate")

func _generate() -> void:
	var source_inventory := _verify_source_inventory()
	if source_inventory.is_empty():
		quit(1)
		return
	for key in KEYS:
		var result := _generate_one(key)
		if result.is_empty():
			quit(1)
			return
		receipts.append(result)
		print("[ground_derivative] " + JSON.stringify(result))
	var receipt := {
		"method": "deterministic 12x12-cell selection of complete quantized-position grass components",
		"target_grass_triangle_fraction": FRACTION,
		"position_quantization_per_source_unit": POSITION_QUANTIZE,
		"source_originals_untouched": true,
		"project_only": true,
		"source_inventory": SOURCE_INVENTORY,
		"source_inventory_sha256": FileAccess.get_sha256(SOURCE_INVENTORY),
		"master_source_js_sha256": source_inventory["master_source_js_sha256"],
		"imported_source_glb_sha256": source_inventory["imported_source_glb_sha256"],
		"tile_derivatives": receipts,
	}
	var path := OUT + "/manifest.json"
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("Cannot write ground derivative manifest")
		quit(1)
		return
	file.store_string(JSON.stringify(receipt, "  "))
	file.close()
	print("[ground_derivative] COMPLETE " + path)
	quit(0)

func _verify_source_inventory() -> Dictionary:
	var file := FileAccess.open(SOURCE_INVENTORY, FileAccess.READ)
	if file == null:
		push_error("Missing pre-derivative source hash inventory: " + SOURCE_INVENTORY)
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if not parsed is Dictionary:
		push_error("Invalid pre-derivative source hash inventory")
		return {}
	var source_js := {}
	for item in parsed.get("master_source_js", []):
		var path := String(item.get("path", ""))
		var expected := String(item.get("sha256", ""))
		if path.is_empty() or FileAccess.get_sha256(path) != expected:
			push_error("Master source JS hash differs from frozen inventory: " + path)
			return {}
		source_js[path] = expected
	var source_glbs := {}
	for item in parsed.get("imported_tile_glbs", []):
		var path := String(item.get("path", ""))
		var expected := String(item.get("sha256", ""))
		if path.is_empty() or FileAccess.get_sha256(path) != expected:
			push_error("Imported source GLB hash differs from frozen inventory: " + path)
			return {}
		source_glbs[String(item.get("library_key", ""))] = expected
	return {"master_source_js_sha256": source_js, "imported_source_glb_sha256": source_glbs}

func _generate_one(key: String) -> Dictionary:
	var source_path: String = Lib.TILE_DIR + String(Lib.TILES[key])
	var source_sha := FileAccess.get_sha256(source_path)
	var tile: Node3D = Builder.build_tile(key, Builder.TILE_Y_FACTOR)
	var grass: MeshInstance3D = _find_grass(tile)
	if grass == null or grass.mesh == null or grass.mesh.get_surface_count() != 1:
		push_error("Expected one grass mesh/surface: " + key)
		tile.free()
		return {}
	var source: Mesh = grass.mesh
	if source.surface_get_primitive_type(0) != Mesh.PRIMITIVE_TRIANGLES:
		push_error("Unexpected grass primitive: " + key)
		tile.free()
		return {}
	var arrays: Array = source.surface_get_arrays(0)
	var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var tangents: PackedFloat32Array = arrays[Mesh.ARRAY_TANGENT]
	var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	if positions.is_empty() or normals.size() != positions.size() or tangents.size() != positions.size() * 4 or colors.size() != positions.size() or indices.is_empty() or indices.size() % 3 != 0:
		push_error("Grass position/normal/color/index contract failed: " + key)
		tile.free()
		return {}
	for channel in range(Mesh.ARRAY_MAX):
		if arrays[channel] != null and arrays[channel].size() > 0:
			print("[ground_derivative] source channel tile=%s index=%d type=%s size=%d" % [key, channel, type_string(typeof(arrays[channel])), arrays[channel].size()])
		if channel == Mesh.ARRAY_VERTEX or channel == Mesh.ARRAY_NORMAL or channel == Mesh.ARRAY_TANGENT or channel == Mesh.ARRAY_COLOR or channel == Mesh.ARRAY_INDEX:
			continue
		if arrays[channel] != null and arrays[channel].size() > 0:
			push_error("Unsupported nonempty grass attribute channel %d: %s" % [channel, key])
			tile.free()
			return {}
	var components: Array = _components(indices, positions)
	var histogram := {}
	var source_tris := indices.size() / 3
	var total_component_tris := 0
	for component in components:
		var n: int = component["triangles"].size()
		var label := str(n)
		histogram[label] = int(histogram.get(label, 0)) + 1
		total_component_tris += n
	if total_component_tris != source_tris or not _validated_component_histogram(histogram):
		push_error("Whole-blade/tuft component distribution changed: %s %s" % [key, JSON.stringify(histogram)])
		tile.free()
		return {}
	var selected: Array = _select_components(key, components)
	var selected_triangles := 0
	var selected_histogram := {}
	var output_arrays := []
	output_arrays.resize(Mesh.ARRAY_MAX)
	var output_positions := PackedVector3Array()
	var output_normals := PackedVector3Array()
	var output_tangents := PackedFloat32Array()
	var output_colors := PackedColorArray()
	for component in selected:
		var triangle_ids: Array = component["triangles"]
		selected_triangles += triangle_ids.size()
		var label := str(triangle_ids.size())
		selected_histogram[label] = int(selected_histogram.get(label, 0)) + 1
		for triangle_id in triangle_ids:
			for corner in range(3):
				var source_vertex: int = indices[int(triangle_id) * 3 + corner]
				output_positions.append(positions[source_vertex])
				output_normals.append(normals[source_vertex])
				for tangent_component in range(4):
					output_tangents.append(tangents[source_vertex * 4 + tangent_component])
				output_colors.append(colors[source_vertex])
	output_arrays[Mesh.ARRAY_VERTEX] = output_positions
	output_arrays[Mesh.ARRAY_NORMAL] = output_normals
	output_arrays[Mesh.ARRAY_TANGENT] = output_tangents
	output_arrays[Mesh.ARRAY_COLOR] = output_colors
	var derivative := ArrayMesh.new()
	derivative.resource_name = "ground_grass_lod1_" + key
	derivative.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, output_arrays)
	var source_material: Material = source.surface_get_material(0)
	derivative.surface_set_material(0, source_material)
	var geometry_hash := HashingContext.new()
	geometry_hash.start(HashingContext.HASH_SHA256)
	geometry_hash.update(output_positions.to_byte_array())
	geometry_hash.update(output_normals.to_byte_array())
	geometry_hash.update(output_tangents.to_byte_array())
	geometry_hash.update(output_colors.to_byte_array())
	geometry_hash.update(source_material.get_class().to_utf8_buffer())
	geometry_hash.update(source_material.resource_name.to_utf8_buffer())
	var geometry_sha := geometry_hash.finish().hex_encode()
	var destination := "%s/%s_lod1.res" % [OUT, key]
	var save_error := ResourceSaver.save(derivative, destination)
	if save_error != OK:
		push_error("Could not save ground derivative: %s error=%d" % [destination, save_error])
		tile.free()
		return {}
	var reloaded: ArrayMesh = ResourceLoader.load(destination, "ArrayMesh", ResourceLoader.CACHE_MODE_IGNORE) as ArrayMesh
	if reloaded == null or reloaded.get_surface_count() != 1:
		push_error("Could not reload ground derivative: " + destination)
		tile.free()
		return {}
	var reloaded_arrays: Array = reloaded.surface_get_arrays(0)
	var output_material: Material = reloaded.surface_get_material(0)
	var checks := {
		"surface_count_equal": reloaded.get_surface_count() == source.get_surface_count(),
		"material_class_equal": output_material != null and source_material != null and output_material.get_class() == source_material.get_class(),
		"material_name_equal": output_material != null and source_material != null and output_material.resource_name == source_material.resource_name,
		"positions_present": (reloaded_arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() == selected_triangles * 3,
		"normals_present": (reloaded_arrays[Mesh.ARRAY_NORMAL] as PackedVector3Array).size() == selected_triangles * 3,
		"tangents_present": (reloaded_arrays[Mesh.ARRAY_TANGENT] as PackedFloat32Array).size() == selected_triangles * 12,
		"vertex_colors_present": (reloaded_arrays[Mesh.ARRAY_COLOR] as PackedColorArray).size() == selected_triangles * 3,
		"whole_components_only": true,
	}
	for value in checks.values():
		if not value:
			push_error("Derivative reload validation failed: %s %s" % [key, JSON.stringify(checks)])
			tile.free()
			return {}
	var result := {
		"tile_key": key, "source_glb": source_path, "source_sha256": source_sha,
		"grass_node": String(grass.name), "source_mesh_name": source.resource_name,
		"derivative": destination, "derivative_sha256": FileAccess.get_sha256(destination),
		"derivative_geometry_sha256": geometry_sha,
		"source_grass_triangles": source_tris, "derivative_grass_triangles": selected_triangles,
		"retained_fraction": float(selected_triangles) / float(source_tris),
		"source_components": components.size(), "selected_components": selected.size(),
		"source_component_triangles_histogram": histogram,
		"selected_component_triangles_histogram": selected_histogram,
		"source_surface_count": source.get_surface_count(), "derivative_surface_count": reloaded.get_surface_count(),
		"source_material_class": source_material.get_class(), "source_material_name": source_material.resource_name,
		"material_override_present": grass.material_override != null,
		"source_attributes": ["position", "normal", "tangent", "vertex_color", "index"],
		"derivative_attributes": ["position", "normal", "tangent", "vertex_color"],
		"validation": checks,
	}
	tile.free()
	return result

func _find_grass(node: Node) -> MeshInstance3D:
	if node is MeshInstance3D and String(node.name).begins_with("root_grass_islands_"):
		return node as MeshInstance3D
	for child in node.get_children():
		var found := _find_grass(child)
		if found != null:
			return found
	return null

func _components(indices: PackedInt32Array, positions: PackedVector3Array) -> Array:
	var triangle_count := indices.size() / 3
	var parents := PackedInt32Array()
	parents.resize(triangle_count)
	for t in range(triangle_count):
		parents[t] = t
	var first_at_position := {}
	for t in range(triangle_count):
		for corner in range(3):
			var p: Vector3 = positions[indices[t * 3 + corner]]
			var key := Vector3i(roundi(p.x * POSITION_QUANTIZE), roundi(p.y * POSITION_QUANTIZE), roundi(p.z * POSITION_QUANTIZE))
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
	var by_root := {}
	for t in range(triangle_count):
		var root_triangle := t
		while parents[root_triangle] != root_triangle:
			root_triangle = parents[root_triangle]
		if not by_root.has(root_triangle):
			by_root[root_triangle] = {"triangles": [], "sum": Vector3.ZERO, "vertices": 0}
		var component: Dictionary = by_root[root_triangle]
		component["triangles"].append(t)
		for corner in range(3):
			component["sum"] += positions[indices[t * 3 + corner]]
		component["vertices"] += 3
	var components: Array = by_root.values()
	for component in components:
		component["center"] = component["sum"] / float(component["vertices"])
		component.erase("sum")
		component.erase("vertices")
	return components

func _validated_component_histogram(histogram: Dictionary) -> bool:
	for key in histogram:
		if key != "6" and key != "18" and key != "4":
			return false
	return int(histogram.get("4", 0)) <= 1

func _select_components(key: String, components: Array) -> Array:
	var min_x := INF
	var max_x := -INF
	var min_z := INF
	var max_z := -INF
	for component in components:
		var center: Vector3 = component["center"]
		min_x = minf(min_x, center.x)
		max_x = maxf(max_x, center.x)
		min_z = minf(min_z, center.z)
		max_z = maxf(max_z, center.z)
	var cells := {}
	for component in components:
		var center: Vector3 = component["center"]
		var cx := clampi(floori((center.x - min_x) / maxf(0.000001, max_x - min_x) * GRID), 0, GRID - 1)
		var cz := clampi(floori((center.z - min_z) / maxf(0.000001, max_z - min_z) * GRID), 0, GRID - 1)
		var cell := Vector2i(cx, cz)
		if not cells.has(cell):
			cells[cell] = []
		var hash_input := "%s|%d|%d|%d|%d|%d|%d" % [key, cx, cz, roundi(center.x * POSITION_QUANTIZE), roundi(center.y * POSITION_QUANTIZE), roundi(center.z * POSITION_QUANTIZE), component["triangles"].size()]
		component["sort_key"] = hash_input.sha256_text()
		cells[cell].append(component)
	var selected: Array = []
	var cell_keys: Array = cells.keys()
	cell_keys.sort()
	for cell in cell_keys:
		var bucket: Array = cells[cell]
		bucket.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["sort_key"] < b["sort_key"])
		var cell_triangles := 0
		for component in bucket:
			cell_triangles += component["triangles"].size()
		var target := ceili(cell_triangles * FRACTION)
		var kept := 0
		for component in bucket:
			if kept >= target:
				break
			selected.append(component)
			kept += component["triangles"].size()
	return selected
