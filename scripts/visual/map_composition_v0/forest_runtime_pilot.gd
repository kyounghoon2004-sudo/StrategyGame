class_name ForestRuntimePilot
extends RefCounted

## Forest hexes only. One cullable chunk per hex, one MultiMesh per tree
## variant/submesh/LOD. Source GLBs remain immutable.

const Lib = preload("res://scripts/visual/map_composition_v0/map_composition_library.gd")
const DERIV_DIR := "res://assets/map_composition_v0/forest_runtime_pilot/"
const NEAR_SIZE := 100.0
const FAR_SIZE := 150.0

var chunks: Array = []
var active_lod := -1
var stats := {"trees": 0, "source_meshes": 0, "multimesh_nodes_per_lod": [0, 0, 0], "chunks": 0}
var _templates: Dictionary = {}


func convert_hex(composition: Node3D) -> void:
	var wraps: Array = []
	for child in composition.get_children():
		if child is Node3D and _tree_key_for_node(child) != "":
			wraps.append(child)
	if wraps.is_empty():
		return
	var by_key := {}
	for wrap in wraps:
		var key := _tree_key_for_node(wrap)
		if not by_key.has(key):
			by_key[key] = []
		by_key[key].append(wrap.transform)
		stats["trees"] = int(stats["trees"]) + 1
		stats["source_meshes"] = int(stats["source_meshes"]) + (1 if key == "dead_tree" else 2)
	var chunk := Node3D.new()
	chunk.name = "ForestRuntimeChunk"
	composition.add_child(chunk)
	var lod_nodes := [[], [], []]
	for key in by_key:
		var transforms: Array = by_key[key]
		for lod in range(3):
			var templates: Array = _templates_for(String(key), lod)
			for part in range(templates.size()):
				var entry: Dictionary = templates[part]
				var mm := MultiMesh.new()
				mm.transform_format = MultiMesh.TRANSFORM_3D
				mm.mesh = entry["mesh"]
				mm.instance_count = transforms.size()
				for i in range(transforms.size()):
					mm.set_instance_transform(i, transforms[i] * entry["transform"])
				var node := MultiMeshInstance3D.new()
				node.name = "MM_%s_%d_LOD%d" % [key, part, lod]
				node.multimesh = mm
				node.material_override = entry["material_override"]
				node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				node.visible = lod == 0
				chunk.add_child(node)
				lod_nodes[lod].append(node)
				stats["multimesh_nodes_per_lod"][lod] += 1
	for wrap in wraps:
		composition.remove_child(wrap)
		wrap.free()
	chunks.append(lod_nodes)
	stats["chunks"] = chunks.size()


func _tree_key(node_name: String) -> String:
	# Godot appends a numeric suffix when sibling placement names repeat.
	for key in Lib.TREES:
		var prefix := "P_" + String(key)
		if node_name == prefix:
			return String(key)
		if node_name.begins_with(prefix) and node_name.substr(prefix.length()).is_valid_int():
			return String(key)
	return ""


func _tree_key_for_node(node: Node) -> String:
	# Node names may be auto-disambiguated for repeated siblings. Metadata is
	# the stable identifier; name parsing remains as a compatibility fallback.
	if node.has_meta("map_asset_key"):
		var asset_key := String(node.get_meta("map_asset_key"))
		if Lib.TREES.has(asset_key):
			return asset_key
	if node is Node3D and String(node.name).begins_with("P_"):
		return _tree_key(String(node.name))
	return ""


func update_for_camera(camera: Camera3D) -> void:
	if camera == null:
		return
	var size := camera.size
	var wanted := 0 if size < NEAR_SIZE else (1 if size < FAR_SIZE else 2)
	# Hysteresis avoids flicker when the zoom hovers around a boundary.
	if active_lod == 0 and size < NEAR_SIZE * 1.08:
		wanted = 0
	elif active_lod == 1:
		if size > NEAR_SIZE * 0.92 and size < FAR_SIZE * 1.08:
			wanted = 1
	elif active_lod == 2 and size > FAR_SIZE * 0.92:
		wanted = 2
	if wanted == active_lod:
		return
	for group in chunks:
		for lod in range(3):
			for node in group[lod]:
				node.visible = lod == wanted
	active_lod = wanted


func _templates_for(key: String, lod: int) -> Array:
	var cache_key := "%s:%d" % [key, lod]
	if _templates.has(cache_key):
		return _templates[cache_key]
	var root: Node3D
	if lod == 0:
		root = Lib.instance_grounded(key)
	else:
		var path := DERIV_DIR + key + ("_lod1.glb" if lod == 1 else "_lod2.glb")
		var document := GLTFDocument.new()
		var state := GLTFState.new()
		var err := document.append_from_file(ProjectSettings.globalize_path(path), state)
		assert(err == OK, "Missing or invalid forest LOD derivative: " + path)
		root = document.generate_scene(state) as Node3D
		var b: Dictionary = Lib.bounds(key)
		var c: Vector3 = b["center"]
		root.position = Vector3(-c.x, -b["min_y"], -c.z)
		Lib._prep_node(root)
	var entries: Array = []
	_collect(root, Transform3D.IDENTITY, entries)
	root.free()
	_templates[cache_key] = entries
	return entries


func _collect(node: Node, parent_xf: Transform3D, entries: Array) -> void:
	var xf := parent_xf
	if node is Node3D:
		xf = parent_xf * (node as Node3D).transform
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		if mi.mesh != null:
			entries.append({"mesh": mi.mesh, "transform": xf,
				"material_override": mi.material_override})
	for child in node.get_children():
		_collect(child, xf, entries)
