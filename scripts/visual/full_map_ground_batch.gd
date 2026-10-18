class_name FullMapGroundBatch
extends RefCounted

## Batches the existing imported ground tiles without changing their geometry,
## materials, vertex colors, placement or per-tile transform. Separate world
## chunks let Godot cull ground outside the camera instead of treating all
## 4,921 tiles as one visible MultiMesh.
const Builder = preload("res://scripts/visual/map_composition_v0/map_composition_builder.gd")
const CHUNK_SIZE := 256.0
const GRASS_DERIVATIVE_DIR := "res://assets/map_composition_v0/runtime_derivatives/ground/"
const GRASS_CLOSE_SIZE := 100.0
const GRASS_HYSTERESIS := 0.08

var _templates: Dictionary = {}
var _groups: Dictionary = {}
var _tile_count := 0
var _mesh_nodes: Array[Dictionary] = []
var _using_grass_lod1 := false
var _grass_lod1_meshes := 0

func add_tile(tile_key: String, world_position: Vector3, placement_scale: Vector3 = Vector3.ONE) -> void:
	if not _templates.has(tile_key):
		_templates[tile_key] = _make_template(tile_key)
	var parts: Array = _templates[tile_key]
	var chunk_x := floori(world_position.x / CHUNK_SIZE)
	var chunk_z := floori(world_position.z / CHUNK_SIZE)
	var placement := Transform3D(Basis.IDENTITY.scaled(placement_scale), world_position)
	for part_index in range(parts.size()):
		var group_key := "%s|%d|%d|%d" % [tile_key, chunk_x, chunk_z, part_index]
		if not _groups.has(group_key):
			_groups[group_key] = {
				"tile_key": tile_key,
				"part_index": part_index,
				"chunk_x": chunk_x,
				"chunk_z": chunk_z,
				"transforms": [],
			}
		var group: Dictionary = _groups[group_key]
		var transforms: Array = group["transforms"]
		transforms.append(placement * (parts[part_index] as Dictionary)["transform"])
	_tile_count += 1

func finish(parent: Node3D) -> Dictionary:
	var batches := 0
	var part_instances := 0
	var keys: Array = _groups.keys()
	keys.sort()
	for group_key in keys:
		var group: Dictionary = _groups[group_key]
		var part: Dictionary = (_templates[group["tile_key"]] as Array)[group["part_index"]]
		var transforms: Array = group["transforms"]
		if transforms.is_empty():
			continue
		var multi := MultiMesh.new()
		multi.transform_format = MultiMesh.TRANSFORM_3D
		multi.mesh = part["mesh"]
		multi.instance_count = transforms.size()
		for i in range(transforms.size()):
			multi.set_instance_transform(i, transforms[i])
		var node := MultiMeshInstance3D.new()
		node.name = "Ground_%s_%d_%d_part%d" % [
			group["tile_key"], group["chunk_x"], group["chunk_z"], group["part_index"]
		]
		node.multimesh = multi
		node.material_override = part["material_override"]
		node.material_overlay = part["material_overlay"]
		node.layers = part["layers"]
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		parent.add_child(node)
		var lod1_mesh: Mesh = part.get("lod1_mesh")
		_mesh_nodes.append({"multimesh": multi, "source_mesh": part["mesh"], "lod1_mesh": lod1_mesh, "node": node})
		if lod1_mesh != null:
			_grass_lod1_meshes += 1
		batches += 1
		part_instances += transforms.size()
	var result := {
		"ground_tiles": _tile_count,
		"ground_batch_nodes": batches,
		"ground_mesh_part_instances": part_instances,
		"chunk_size_world": CHUNK_SIZE,
		"grass_lod1_mesh_parts": _grass_lod1_meshes,
		"grass_lod_state": "source_close",
	}
	_groups.clear()
	return result

func update_for_camera(camera: Camera3D) -> void:
	if camera == null:
		return
	var wanted_lod1 := _using_grass_lod1
	if _using_grass_lod1:
		if camera.size < GRASS_CLOSE_SIZE * (1.0 - GRASS_HYSTERESIS):
			wanted_lod1 = false
	elif camera.size > GRASS_CLOSE_SIZE * (1.0 + GRASS_HYSTERESIS):
		wanted_lod1 = true
	if wanted_lod1 == _using_grass_lod1:
		return
	for entry in _mesh_nodes:
		var lod1_mesh: Mesh = entry["lod1_mesh"]
		if lod1_mesh == null:
			continue
		var multi: MultiMesh = entry["multimesh"]
		multi.mesh = lod1_mesh if wanted_lod1 else entry["source_mesh"]
	_using_grass_lod1 = wanted_lod1

## Grass tufts on / off (the grass parts are the ones with a grass LOD derivative). Off = bare tile meshes,
## used by tutorial boards while the whole board is in view.
var grass_visible := true

func set_grass_visible(on: bool) -> void:
	if on == grass_visible:
		return
	grass_visible = on
	for entry in _mesh_nodes:
		if entry["lod1_mesh"] != null and entry.has("node"):
			(entry["node"] as Node3D).visible = on

func get_lod_stats() -> Dictionary:
	return {
		"grass_lod1_mesh_parts": _grass_lod1_meshes,
		"grass_lod_state": "lod1_reduced" if _using_grass_lod1 else "source_close",
		"grass_close_camera_size": GRASS_CLOSE_SIZE,
	}

func _make_template(tile_key: String) -> Array:
	var tile: Node3D = Builder.build_tile(tile_key, Builder.TILE_Y_FACTOR)
	var parts: Array = []
	_collect(tile, Transform3D.IDENTITY, true, parts, tile_key)
	tile.free()
	assert(not parts.is_empty(), "Ground tile has no visible mesh: " + tile_key)
	return parts

func _collect(node: Node, parent_transform: Transform3D, parent_visible: bool, parts: Array, tile_key: String) -> void:
	var transform := parent_transform
	var visible := parent_visible
	if node is Node3D:
		var spatial := node as Node3D
		transform = parent_transform * spatial.transform
		visible = parent_visible and spatial.visible
	if node is MeshInstance3D and visible:
		var source := node as MeshInstance3D
		if source.mesh != null:
			var lod1_mesh: Mesh
			if String(source.name).begins_with("root_grass_islands_"):
				var derivative_path := GRASS_DERIVATIVE_DIR + tile_key + "_lod1.res"
				assert(ResourceLoader.exists(derivative_path), "Missing grass LOD derivative: " + derivative_path)
				lod1_mesh = ResourceLoader.load(derivative_path) as Mesh
				assert(lod1_mesh != null, "Grass LOD derivative is not a Mesh: " + derivative_path)
				assert(lod1_mesh.get_surface_count() == source.mesh.get_surface_count(), "Grass LOD surface count mismatch: " + derivative_path)
				for surface in range(source.mesh.get_surface_count()):
					var source_material := source.mesh.surface_get_material(surface)
					var lod1_material := lod1_mesh.surface_get_material(surface)
					assert((source_material == null) == (lod1_material == null), "Grass LOD material presence mismatch: " + derivative_path)
					if source_material != null:
						assert(source_material.get_class() == lod1_material.get_class() and source_material.resource_name == lod1_material.resource_name, "Grass LOD material mismatch: " + derivative_path)
			parts.append({
				"mesh": _mesh_with_overrides(source),
				"lod1_mesh": lod1_mesh,
				"transform": transform,
				"material_override": source.material_override,
				"material_overlay": source.material_overlay,
				"layers": source.layers,
			})
	for child in node.get_children():
		_collect(child, transform, visible, parts, tile_key)

func _mesh_with_overrides(source: MeshInstance3D) -> Mesh:
	# Imported tile meshes normally store materials on each surface. If an
	# imported scene overrides one, bake that override into a copy of its mesh
	# so the MultiMesh still draws the same material on the same surface.
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
