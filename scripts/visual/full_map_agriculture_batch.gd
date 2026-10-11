class_name FullMapAgricultureBatch
extends RefCounted

## Presentation-only batching for dry/rice field assets inside the live
## Agricultural District compositions. Source GLBs, yard discs, all field
## part meshes/materials, other families, and gameplay data remain untouched.
const Lib = preload("res://scripts/visual/map_composition_v0/map_composition_library.gd")
const FIELD_ASSET_KEYS := ["dry_field", "rice_field"]
const ROOT_PREFIX := "Agricultural_District_"
const DRY_FIELD_FAR_LOD_PATH := "res://assets/map_composition_v0/runtime_derivatives/agricultural_district/dry_field_far.glb"
const CHUNK_SIZE := 64.0
const FAR_CAMERA_SIZE := 145.0
const HYSTERESIS := 0.08

var _groups: Dictionary = {}
var _templates: Dictionary = {}
var _mesh_nodes: Array[Dictionary] = []
var _roots := 0
var _asset_wrappers := 0
var _source_triangles := 0
var _far_lod_triangles := 0
var _mesh_part_batches := 0
var _mesh_part_instances := 0
var _surface_instances := 0
var _far_lod_mesh_part_batches := 0
var _far_lod_template_mesh_parts := 0
var _active_far_lod := false


## Collect only dry/rice field wrappers from the 18 approved roots.
## Yard discs are procedural siblings and intentionally remain in place.
func add_hex(composition: Node3D) -> void:
	if not String(composition.name).begins_with(ROOT_PREFIX):
		return
	var candidates: Array[Node] = []
	for child in composition.get_children():
		if child is Node3D and not _asset_key_for_wrapper(child).is_empty():
			candidates.append(child)
	if candidates.is_empty():
		return
	_roots += 1
	for wrapper_node in candidates:
		var wrapper := wrapper_node as Node3D
		var key := _asset_key_for_wrapper(wrapper)
		_asset_wrappers += 1
		var template: Array = _template_for(key)
		var wrapper_xf: Transform3D = composition.transform * wrapper.transform
		for part_index in range(template.size()):
			var part: Dictionary = template[part_index]
			var instance_xf: Transform3D = wrapper_xf * part["transform"]
			var chunk_x := floori(instance_xf.origin.x / CHUNK_SIZE)
			var chunk_z := floori(instance_xf.origin.z / CHUNK_SIZE)
			var group_key := "%s|%d|%d|%d|%d|%d|%d" % [
				key, part_index, chunk_x, chunk_z,
				int(part["material_override_id"]),
				int(part["material_overlay_id"]),
				int(part["layers"]),
			]
			if not _groups.has(group_key):
				_groups[group_key] = {
					"asset_key": key,
					"part_index": part_index,
					"chunk_x": chunk_x,
					"chunk_z": chunk_z,
					"source_mesh": part["source_mesh"],
					"far_lod_mesh": part["far_lod_mesh"],
					"material_override": part["material_override"],
					"material_overlay": part["material_overlay"],
					"layers": part["layers"],
					"transforms": [],
				}
			var group: Dictionary = _groups[group_key]
			(group["transforms"] as Array).append(instance_xf)
		# Free only the source GLB wrapper after capturing its authored transform.
		composition.remove_child(wrapper)
		wrapper.free()


## Emit one cullable MultiMesh per source mesh part and spatial chunk.
func finish(parent: Node3D, allow_partial_roots: bool = false) -> Dictionary:
	var batch_root := Node3D.new()
	batch_root.name = "AgriculturalDistrictBatches"
	batch_root.set_meta("map_family", "Agricultural District")
	parent.add_child(batch_root)
	var group_keys: Array = _groups.keys()
	group_keys.sort()
	for group_key in group_keys:
		var group: Dictionary = _groups[group_key]
		var transforms: Array = group["transforms"]
		if transforms.is_empty():
			continue
		var multi := MultiMesh.new()
		multi.transform_format = MultiMesh.TRANSFORM_3D
		multi.mesh = group["source_mesh"]
		multi.instance_count = transforms.size()
		for i in range(transforms.size()):
			multi.set_instance_transform(i, transforms[i])
		var node := MultiMeshInstance3D.new()
		node.name = "Agriculture_%s_%d_%d_%d" % [
			group["asset_key"], group["chunk_x"], group["chunk_z"], group["part_index"],
		]
		node.multimesh = multi
		node.material_override = group["material_override"]
		node.material_overlay = group["material_overlay"]
		node.layers = group["layers"]
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		batch_root.add_child(node)
		_mesh_nodes.append({
			"multimesh": multi,
			"source_mesh": group["source_mesh"],
			"far_lod_mesh": group["far_lod_mesh"],
		})
		_mesh_part_batches += 1
		_mesh_part_instances += transforms.size()
		_source_triangles += Lib.mesh_triangles(group["source_mesh"]) * transforms.size()
		var far_mesh: Mesh = group["far_lod_mesh"] if group["far_lod_mesh"] != null else group["source_mesh"]
		_far_lod_triangles += Lib.mesh_triangles(far_mesh) * transforms.size()
		_surface_instances += group["source_mesh"].get_surface_count() * transforms.size()
		if group["far_lod_mesh"] != null:
			_far_lod_mesh_part_batches += 1
	_groups.clear()
	if not allow_partial_roots:
		assert(_roots == 18, "Expected 18 Agricultural District roots, got %d" % _roots)
		assert(_asset_wrappers == 342, "Expected 342 dry/rice field wrappers, got %d" % _asset_wrappers)
		assert(_far_lod_template_mesh_parts == 2, "Expected straw/grain LOD templates, got %d" % _far_lod_template_mesh_parts)
	return get_stats()


func get_stats() -> Dictionary:
	return {
		"agriculture_roots": _roots,
		"field_asset_wrappers_batched": _asset_wrappers,
		"source_mesh_part_batches": _mesh_part_batches,
		"source_mesh_part_instances": _mesh_part_instances,
		"source_surface_instances": _surface_instances,
		"source_asset_triangles": _source_triangles,
		"far_lod_asset_triangles": _far_lod_triangles,
		"far_lod_mesh_part_batches": _far_lod_mesh_part_batches,
		"far_lod_template_mesh_parts": _far_lod_template_mesh_parts,
		"chunk_size_world": CHUNK_SIZE,
		"far_lod_camera_size": FAR_CAMERA_SIZE,
		"field_keys": FIELD_ASSET_KEYS.duplicate(),
		"yard_discs_preserved": true,
		"source_meshes_materials_preserved": true,
		"other_families_touched": false,
		"lod_state": "far_lod" if _active_far_lod else "source_close",
	}


func update_for_camera(camera: Camera3D) -> void:
	if camera == null:
		return
	var wanted_far_lod := _active_far_lod
	if _active_far_lod:
		if camera.size < FAR_CAMERA_SIZE * (1.0 - HYSTERESIS):
			wanted_far_lod = false
	elif camera.size > FAR_CAMERA_SIZE * (1.0 + HYSTERESIS):
		wanted_far_lod = true
	if wanted_far_lod == _active_far_lod:
		return
	for entry in _mesh_nodes:
		var far_mesh: Mesh = entry["far_lod_mesh"]
		if far_mesh == null:
			continue
		var multi: MultiMesh = entry["multimesh"]
		multi.mesh = far_mesh if wanted_far_lod else entry["source_mesh"]
	_active_far_lod = wanted_far_lod


func _asset_key_for_wrapper(wrapper: Node) -> String:
	# Prefer an explicit asset tag when present. Repeated siblings may be auto-
	# renamed by Godot to @Node3D@N, so fall back to the stable imported mesh-part
	# names under the wrapped GLB scene instead of relying on wrapper names.
	if wrapper.has_meta("map_asset_key"):
		var tagged_key := String(wrapper.get_meta("map_asset_key"))
		if FIELD_ASSET_KEYS.has(tagged_key):
			return tagged_key
	if _contains_mesh_part_prefix(wrapper, "DryCropField_"):
		return "dry_field"
	if _contains_mesh_part_prefix(wrapper, "IrrigatedRiceField_"):
		return "rice_field"
	return ""


func _contains_mesh_part_prefix(node: Node, prefix: String) -> bool:
	if node is MeshInstance3D and String((node as MeshInstance3D).name).begins_with(prefix):
		return true
	for child in node.get_children():
		if _contains_mesh_part_prefix(child, prefix):
			return true
	return false


func _template_for(key: String) -> Array:
	if _templates.has(key):
		return _templates[key]
	var root := Lib.instance_grounded(key)
	Lib._prep_node(root)
	var mesh_nodes: Dictionary = {}
	_collect_mesh_nodes(root, Transform3D.IDENTITY, mesh_nodes)
	assert(not mesh_nodes.is_empty(), "Agriculture asset has no meshes: " + key)
	var mesh_nodes_by_name: Dictionary = {}
	for source_path in mesh_nodes:
		var source_entry: Dictionary = mesh_nodes[source_path]
		var source_node := source_entry["node"] as MeshInstance3D
		assert(not mesh_nodes_by_name.has(String(source_node.name)), "Duplicate Agriculture mesh-part name: " + String(source_node.name))
		mesh_nodes_by_name[String(source_node.name)] = source_entry
	var far_root: Node3D
	var far_nodes_by_name: Dictionary = {}
	if key == "dry_field":
		assert(ResourceLoader.exists(DRY_FIELD_FAR_LOD_PATH), "Dry-field far LOD is not imported: " + DRY_FIELD_FAR_LOD_PATH)
		var far_scene := ResourceLoader.load(DRY_FIELD_FAR_LOD_PATH) as PackedScene
		assert(far_scene != null, "Dry-field far LOD is not a PackedScene: " + DRY_FIELD_FAR_LOD_PATH)
		far_root = far_scene.instantiate() as Node3D
		assert(far_root != null, "Dry-field far LOD root is not Node3D")
		far_root.transform = root.transform
		Lib._prep_node(far_root)
		var far_nodes: Dictionary = {}
		_collect_mesh_nodes(far_root, Transform3D.IDENTITY, far_nodes)
		assert(mesh_nodes_by_name.size() == 10, "Expected 10 dry-field source parts, got %d" % mesh_nodes_by_name.size())
		assert(far_nodes.size() == mesh_nodes_by_name.size(), "Dry-field far LOD mesh-part count mismatch")
		for far_path in far_nodes:
			var far_entry: Dictionary = far_nodes[far_path]
			var far_node := far_entry["node"] as MeshInstance3D
			assert(not far_nodes_by_name.has(String(far_node.name)), "Duplicate dry-field far LOD part name: " + String(far_node.name))
			far_nodes_by_name[String(far_node.name)] = far_entry
		assert(far_nodes_by_name.size() == mesh_nodes_by_name.size(), "Dry-field far LOD named-part count mismatch")
		for part_name in mesh_nodes_by_name:
			assert(far_nodes_by_name.has(part_name), "Dry-field far LOD missing named part: " + String(part_name))
	var entries: Array = []
	var part_names: Array = mesh_nodes_by_name.keys()
	part_names.sort()
	for part_name in part_names:
		var source_entry: Dictionary = mesh_nodes_by_name[part_name]
		var source_node := source_entry["node"] as MeshInstance3D
		var source_mesh := _mesh_with_overrides(source_node)
		var far_lod_mesh: Mesh
		if key == "dry_field":
			var far_entry: Dictionary = far_nodes_by_name[part_name]
			var far_node := far_entry["node"] as MeshInstance3D
			assert(source_node.name == far_node.name, "Dry-field far LOD part name mismatch: " + String(part_name))
			assert(source_node.mesh.get_surface_count() == far_node.mesh.get_surface_count(), "Dry-field far LOD surface count mismatch: " + String(part_name))
			assert(source_entry["transform"].is_equal_approx(far_entry["transform"]), "Dry-field far LOD transform mismatch: " + String(part_name))
			if String(part_name) == "DryCropField_straw" or String(part_name) == "DryCropField_grain":
				far_lod_mesh = _mesh_with_source_materials(source_node, far_node, String(part_name))
				_far_lod_template_mesh_parts += 1
		entries.append({
			"source_mesh": source_mesh,
			"far_lod_mesh": far_lod_mesh,
			"transform": source_entry["transform"],
			"material_override": source_node.material_override,
			"material_overlay": source_node.material_overlay,
			"material_override_id": source_node.material_override.get_instance_id() if source_node.material_override != null else 0,
			"material_overlay_id": source_node.material_overlay.get_instance_id() if source_node.material_overlay != null else 0,
			"layers": source_node.layers,
		})
	if far_root != null:
		far_root.free()
	root.free()
	_templates[key] = entries
	return entries


func _collect_mesh_nodes(node: Node, parent_xf: Transform3D, output: Dictionary, path: String = "") -> void:
	var xf := parent_xf
	if node is Node3D:
		xf = parent_xf * (node as Node3D).transform
	var node_path := String(node.name) if path.is_empty() else path + "/" + String(node.name)
	if node is MeshInstance3D:
		var mesh_node := node as MeshInstance3D
		if mesh_node.mesh != null:
			assert(not output.has(node_path), "Duplicate Agriculture mesh path: " + node_path)
			output[node_path] = {"node": mesh_node, "transform": xf}
	for child in node.get_children():
		_collect_mesh_nodes(child, xf, output, node_path)


func _mesh_with_overrides(source: MeshInstance3D) -> Mesh:
	var needs_copy := false
	for surface in range(source.mesh.get_surface_count()):
		if source.get_surface_override_material(surface) != null:
			needs_copy = true
			break
	if not needs_copy:
		return source.mesh
	var copy := source.mesh.duplicate(true) as Mesh
	if copy is ArrayMesh:
		for surface in range(source.mesh.get_surface_count()):
			var override: Material = source.get_surface_override_material(surface)
			if override != null:
				(copy as ArrayMesh).surface_set_material(surface, override)
	return copy


func _mesh_with_source_materials(source: MeshInstance3D, far_lod: MeshInstance3D, part_name: String) -> Mesh:
	assert(far_lod.mesh != null, "Dry-field far LOD mesh is missing: " + part_name)
	assert(source.mesh.get_surface_count() == far_lod.mesh.get_surface_count(), "Dry-field LOD surface count mismatch: " + part_name)
	var copy := far_lod.mesh.duplicate(true) as Mesh
	assert(copy != null, "Could not duplicate dry-field far LOD mesh: " + part_name)
	if copy is ArrayMesh:
		for surface in range(source.mesh.get_surface_count()):
			var material: Material = source.get_surface_override_material(surface)
			if material == null:
				material = source.mesh.surface_get_material(surface)
			(copy as ArrayMesh).surface_set_material(surface, material)
	return copy
