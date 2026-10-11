class_name FullMapMountainRangeBatch
extends RefCounted

## Presentation-only batching for the connected Mountain Range family.
## Source GLBs stay immutable. Trees, normal Mountains, per-hex yard meshes,
## gameplay state and all composition transforms stay outside this batcher.
const Lib = preload("res://scripts/visual/map_composition_v0/map_composition_library.gd")
const RANGE_ASSET_KEYS := [
	"low_foothill", "long_ridge", "sharp_peak", "twin_saddle",
	"cliff_escarpment", "layered_massif",
]
const DERIVATIVE_DIR := "res://assets/map_composition_v0/runtime_derivatives/mountain_range/"
const CHUNK_SIZE := 64.0
const CLOSE_CAMERA_SIZE := 100.0
const HYSTERESIS := 0.08

var _groups: Dictionary = {}
var _mesh_nodes: Array[Dictionary] = []
var _templates: Dictionary = {}
var _range_roots := 0
var _asset_wrappers := 0
var _source_mesh_parts := 0
var _lod_mesh_parts := 0
var _lod_template_asset_keys := 0
var _lod_template_mesh_parts := 0
var _source_triangles := 0
var _lod_triangles := 0
var _active_lod1 := false


## Collect only the six non-tree GLB assets present in Mountain Range variants
## B/C/D. The composition remains in place for its yard/ring and ForestPilot.
func add_hex(composition: Node3D) -> void:
	if not String(composition.name).begins_with("Mountain_Range_"):
		return
	var candidates: Array[Node] = []
	for child in composition.get_children():
		if child is Node3D and RANGE_ASSET_KEYS.has(_asset_key(String(child.name))):
			candidates.append(child)
	if candidates.is_empty():
		return
	_range_roots += 1
	for wrapper in candidates:
		var key := _asset_key(String(wrapper.name))
		_asset_wrappers += 1
		var template: Array = _template_for(key)
		var root_xf := composition.transform * (wrapper as Node3D).transform
		for part_index in range(template.size()):
			var part: Dictionary = template[part_index]
			var local_xf: Transform3D = part["transform"]
			var instance_xf := root_xf * local_xf
			var chunk_x := floori(instance_xf.origin.x / CHUNK_SIZE)
			var chunk_z := floori(instance_xf.origin.z / CHUNK_SIZE)
			var group_key := "%s|%d|%d|%d|%d|%d" % [
				key, part_index, chunk_x, chunk_z,
				int(part["material_override_id"]), int(part["material_overlay_id"]),
			]
			if not _groups.has(group_key):
				_groups[group_key] = {
					"asset_key": key,
					"part_index": part_index,
					"chunk_x": chunk_x,
					"chunk_z": chunk_z,
					"source_mesh": part["source_mesh"],
					"lod1_mesh": part["lod1_mesh"],
					"material_override": part["material_override"],
					"material_overlay": part["material_overlay"],
					"layers": part["layers"],
					"transforms": [],
				}
			var group: Dictionary = _groups[group_key]
			(group["transforms"] as Array).append(instance_xf)
		# Remove only the source mountain asset wrapper after capturing its exact
		# transform. Sibling trees and procedural meshes remain under composition.
		composition.remove_child(wrapper)
		wrapper.free()


## Emit one cullable MultiMesh per source part and spatial chunk. Each instance
## retains the authored per-asset transform; LOD only swaps its Mesh reference.
func finish(parent: Node3D, allow_partial_assets: bool = false) -> Dictionary:
	var batch_root := Node3D.new()
	batch_root.name = "MountainRangeBatches"
	batch_root.set_meta("map_family", "Mountain Range")
	parent.add_child(batch_root)
	var keys: Array = _groups.keys()
	keys.sort()
	var batch_count := 0
	var instance_count := 0
	for group_key in keys:
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
		node.name = "Range_%s_%d_%d_%d" % [
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
			"lod1_mesh": group["lod1_mesh"],
		})
		batch_count += 1
		instance_count += transforms.size()
		_source_triangles += Lib.mesh_triangles(group["source_mesh"]) * transforms.size()
		if group["lod1_mesh"] != null:
			_lod_mesh_parts += 1
			_lod_triangles += Lib.mesh_triangles(group["lod1_mesh"]) * transforms.size()
		else:
			_lod_triangles += Lib.mesh_triangles(group["source_mesh"]) * transforms.size()
		_source_mesh_parts += 1
	if not allow_partial_assets:
		assert(_lod_template_asset_keys == RANGE_ASSET_KEYS.size(), "Expected all six Mountain Range LOD assets, got %d" % _lod_template_asset_keys)
		assert(_lod_template_mesh_parts == RANGE_ASSET_KEYS.size() * 5, "Expected 30 Mountain Range LOD mesh-part templates, got %d" % _lod_template_mesh_parts)
	_groups.clear()
	return {
		"range_roots": _range_roots,
		"asset_wrappers_batched": _asset_wrappers,
		"source_mesh_part_batches": batch_count,
		"source_mesh_part_instances": instance_count,
		"lod1_mesh_part_batches": _lod_mesh_parts,
		"lod1_template_asset_keys": _lod_template_asset_keys,
		"lod1_template_mesh_parts": _lod_template_mesh_parts,
		"source_triangles": _source_triangles,
		"lod1_triangles": _lod_triangles,
		"chunk_size_world": CHUNK_SIZE,
		"tree_geometry_batched": false,
		"normal_mountains_touched": false,
		"lod_state": "source_close",
	}


func update_for_camera(camera: Camera3D) -> void:
	if camera == null:
		return
	var wanted_lod1 := _active_lod1
	if _active_lod1:
		if camera.size < CLOSE_CAMERA_SIZE * (1.0 - HYSTERESIS):
			wanted_lod1 = false
	elif camera.size > CLOSE_CAMERA_SIZE * (1.0 + HYSTERESIS):
		wanted_lod1 = true
	if wanted_lod1 == _active_lod1:
		return
	for entry in _mesh_nodes:
		var lod1_mesh: Mesh = entry["lod1_mesh"]
		if lod1_mesh == null:
			continue
		var multi: MultiMesh = entry["multimesh"]
		multi.mesh = lod1_mesh if wanted_lod1 else entry["source_mesh"]
	_active_lod1 = wanted_lod1


func get_stats() -> Dictionary:
	return {
		"range_roots": _range_roots,
		"asset_wrappers_batched": _asset_wrappers,
		"source_mesh_part_batches": _mesh_nodes.size(),
		"lod1_mesh_part_batches": _lod_mesh_parts,
		"lod1_template_asset_keys": _lod_template_asset_keys,
		"lod1_template_mesh_parts": _lod_template_mesh_parts,
		"source_triangles": _source_triangles,
		"lod1_triangles": _lod_triangles,
		"lod_state": "lod1_reduced" if _active_lod1 else "source_close",
		"close_camera_size": CLOSE_CAMERA_SIZE,
		"chunk_size_world": CHUNK_SIZE,
	}


func _asset_key(node_name: String) -> String:
	# Packed-scene siblings can receive numeric suffixes; recognize exact key
	# prefixes while restricting matches to the explicit Mountain Range key set.
	for key in RANGE_ASSET_KEYS:
		var prefix: String = "P_" + String(key)
		if node_name == prefix:
			return key
		if node_name.begins_with(prefix) and node_name.substr(prefix.length()).is_valid_int():
			return key
	return ""


func _template_for(key: String) -> Array:
	if _templates.has(key):
		return _templates[key]
	var source_root := Lib.instance_grounded(key)
	var derivative_path := DERIVATIVE_DIR + _source_glb_name(key).trim_suffix(".glb") + "_lod1.glb"
	assert(ResourceLoader.exists(derivative_path), "Mountain Range LOD derivative not imported or missing: " + derivative_path)
	var packed := ResourceLoader.load(derivative_path) as PackedScene
	assert(packed != null, "Mountain Range LOD is not an imported PackedScene: " + derivative_path)
	var lod_root := packed.instantiate() as Node3D
	assert(lod_root != null, "Mountain Range LOD root is not Node3D: " + derivative_path)
	# Reuse source root alignment so simplified geometry never changes placement.
	lod_root.transform = source_root.transform
	Lib._prep_node(lod_root)
	var source_nodes: Dictionary = {}
	var lod_nodes: Dictionary = {}
	_collect_mesh_nodes(source_root, Transform3D.IDENTITY, source_root, source_nodes)
	_collect_mesh_nodes(lod_root, Transform3D.IDENTITY, lod_root, lod_nodes)
	assert(not source_nodes.is_empty(), "Mountain Range asset has no source meshes: " + key)
	assert(source_nodes.keys().size() == lod_nodes.keys().size(), "Mountain Range LOD mesh node count mismatch: " + key)
	assert(source_nodes.keys().size() == 5, "Expected five source mesh parts for Mountain Range key: " + key)
	var entries: Array = []
	var paths: Array = source_nodes.keys()
	paths.sort()
	for path in paths:
		var source_entry: Dictionary = source_nodes[path]
		var source_node: MeshInstance3D = source_entry["node"]
		var source_mesh := _mesh_with_overrides(source_node)
		var lod_mesh: Mesh
		assert(lod_nodes.has(path), "Mountain Range LOD node name mismatch: " + key + " " + String(path))
		var lod_node: MeshInstance3D = (lod_nodes[path] as Dictionary)["node"]
		lod_mesh = _mesh_with_source_materials(source_node, lod_node, key, String(path))
		assert(lod_mesh != null, "Mountain Range LOD mesh is missing: " + key + " " + String(path))
		entries.append({
			"source_mesh": source_mesh,
			"lod1_mesh": lod_mesh,
			"transform": source_entry["transform"],
			"material_override": source_node.material_override,
			"material_overlay": source_node.material_overlay,
			"material_override_id": source_node.material_override.get_instance_id() if source_node.material_override != null else 0,
			"material_overlay_id": source_node.material_overlay.get_instance_id() if source_node.material_overlay != null else 0,
			"layers": source_node.layers,
		})
	lod_root.free()
	source_root.free()
	_templates[key] = entries
	_lod_template_asset_keys += 1
	_lod_template_mesh_parts += entries.size()
	return entries


func _collect_mesh_nodes(node: Node, parent_xf: Transform3D, _root: Node3D, output: Dictionary) -> void:
	var xf := parent_xf
	if node is Node3D:
		xf = parent_xf * (node as Node3D).transform
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		if mi.mesh != null:
			var part_name := String(mi.name)
			assert(not output.has(part_name), "Mountain asset has duplicate mesh part name: " + part_name)
			output[part_name] = {"node": mi, "transform": xf}
	for child in node.get_children():
		_collect_mesh_nodes(child, xf, _root, output)


func _mesh_with_source_materials(source: MeshInstance3D, lod: MeshInstance3D, key: String, node_path: String) -> Mesh:
	assert(lod.mesh != null, "Mountain Range LOD node has no mesh: " + key + " " + node_path)
	assert(source.mesh.get_surface_count() == lod.mesh.get_surface_count(), "Mountain Range LOD surface count mismatch: " + key + " " + node_path)
	var copy := lod.mesh.duplicate(true) as Mesh
	if copy is ArrayMesh:
		for surface in range(source.mesh.get_surface_count()):
			var material: Material = source.get_surface_override_material(surface)
			if material == null:
				material = source.mesh.surface_get_material(surface)
			(copy as ArrayMesh).surface_set_material(surface, material)
	return copy


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


func _source_glb_name(key: String) -> String:
	return String(Lib.MOUNTAINS[key])
