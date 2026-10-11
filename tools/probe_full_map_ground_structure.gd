extends SceneTree

## Structural-only LOD census on the live production battlefield. Does not
## sample or report frame time.
const OUT := "res://evidence/full_map_ground_optimization/candidate50_structure.json"
const CLOSE_ZOOM := 6.0

var shell: Node
var view: Node
var layer: Node
var ground: Node3D
var menu_frame := 0
var start_ms := 0

func _initialize() -> void:
	start_ms = Time.get_ticks_msec()
	change_scene_to_file("res://scenes/title_screen.tscn")

func _process(_delta: float) -> bool:
	if Time.get_ticks_msec() - start_ms > 600000:
		push_error("Ground structural probe timed out")
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
	if shell != null or current_scene == null:
		return false
	shell = current_scene
	view = shell.get("_view3d")
	if view == null or not bool(view.call("is_active")):
		shell = null
		return false
	layer = view.get("strict_transplant")
	if layer == null or not bool(layer.get("built")):
		return false
	ground = layer.get_node_or_null("GroundAllPlayableHexes") as Node3D
	if ground == null:
		push_error("Live production ground root missing")
		quit(1)
		return true
	var camera: Node = shell.get("camera")
	camera.set_process(false)
	camera.set_process_input(false)
	camera.set_process_unhandled_input(false)
	var layout_hash: String = layer.get("report").get("layout_sha256_after", "")
	var placement_hash: String = layer.get("report").get("placement_sha256", "")
	var full_layout_before: String = layer.call("layout_snapshot", shell)
	camera.call("set_zoom_level", 1.15, true)
	camera.call("focus_on", Vector2(-144.0, 0.0), true)
	view.set("_cam_sig", Vector4.INF)
	view.call("_update_camera")
	var lod1_size: float = view.get("cam").size
	var lod1_census := _ground_census(ground)
	var lod1_state: Dictionary = layer.get("report").get("ground_runtime_lod", {}).duplicate(true)
	camera.call("set_zoom_level", CLOSE_ZOOM, true)
	view.set("_cam_sig", Vector4.INF)
	view.call("_update_camera")
	var close_size: float = view.get("cam").size
	var close_census := _ground_census(ground)
	var close_state: Dictionary = layer.get("report").get("ground_runtime_lod", {}).duplicate(true)
	var full_layout_after: String = layer.call("layout_snapshot", shell)
	var report := {
		"stage": "candidate50_structure_only",
		"playable_hexes": layer.get("report").get("playable_hexes", 0),
		"ground_hexes": layer.get("report").get("ground_hexes", 0),
		"remaining_old_ground_hexes": layer.get("report").get("remaining_old_ground_hexes", -1),
		"layout_sha256": layout_hash,
		"placement_sha256": placement_hash,
		"layout_unchanged": full_layout_before == full_layout_after,
		"shadows_on": layer.call("shadow_count", view),
		"lod1_camera_size": lod1_size,
		"lod1_state": lod1_state,
		"lod1_ground_census": lod1_census,
		"close_camera_size": close_size,
		"close_state": close_state,
		"close_ground_census": close_census,
	}
	var file := FileAccess.open(OUT, FileAccess.WRITE)
	if file == null:
		push_error("Could not write ground structural receipt")
		quit(1)
		return true
	file.store_string(JSON.stringify(report, "  "))
	file.close()
	print("[ground_structure] " + JSON.stringify(report))
	quit(0)
	return true

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
			for surface in range(mesh.get_surface_count()):
				var primitive: int = mesh.surface_get_primitive_type(surface)
				var type_name := str(primitive)
				counts["primitive_types"][type_name] = int(counts["primitive_types"].get(type_name, 0)) + 1
				if primitive == Mesh.PRIMITIVE_TRIANGLES:
					var arrays: Array = mesh.surface_get_arrays(surface)
					var index_value: Variant = arrays[Mesh.ARRAY_INDEX]
					var index_array := PackedInt32Array()
					if index_value is PackedInt32Array:
						index_array = index_value
					var count := index_array.size() if not index_array.is_empty() else (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
					per_mesh["triangles"] += count / 3
				var material: Material = mesh.surface_get_material(surface)
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
