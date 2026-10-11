extends SceneTree

## Offline import parity check for the six range-only LOD GLBs.
## Loads resources and writes an evidence receipt; does not open the battlefield.
const Lib = preload("res://scripts/visual/map_composition_v0/map_composition_library.gd")
const Batch = preload("res://scripts/visual/full_map_mountain_range_batch.gd")
const KEYS := ["low_foothill", "long_ridge", "sharp_peak", "twin_saddle", "cliff_escarpment", "layered_massif"]
const OUT := "res://evidence/mountain_range_optimization/lod_import_validation.json"

func _initialize() -> void:
	var report := {"assets": {}, "all_six_loaded": false, "mesh_part_templates": 0}
	var total_parts := 0
	for key in KEYS:
		var source_root := Lib.instance_grounded(key)
		var path := "res://assets/map_composition_v0/runtime_derivatives/mountain_range/" + String(Lib.MOUNTAINS[key]).trim_suffix(".glb") + "_lod1.glb"
		assert(ResourceLoader.exists(path), "Missing imported derivative resource: " + path)
		var packed := ResourceLoader.load(path) as PackedScene
		assert(packed != null, "Derivative failed to load as PackedScene: " + path)
		var lod_root := packed.instantiate() as Node3D
		assert(lod_root != null, "Derivative root must be Node3D: " + path)
		lod_root.transform = source_root.transform
		Lib._prep_node(lod_root)
		var source_nodes: Dictionary = {}
		var lod_nodes: Dictionary = {}
		_collect(source_root, Transform3D.IDENTITY, source_nodes)
		_collect(lod_root, Transform3D.IDENTITY, lod_nodes)
		assert(source_nodes.size() == 5, "%s source expected 5 mesh parts, got %d" % [key, source_nodes.size()])
		assert(lod_nodes.size() == 5, "%s derivative expected 5 mesh parts, got %d" % [key, lod_nodes.size()])
		var names: Array = source_nodes.keys()
		names.sort()
		var source_triangles := 0
		var lod_triangles := 0
		var assets_parts := []
		for part_name in names:
			assert(lod_nodes.has(part_name), "%s derivative missing named mesh part %s" % [key, part_name])
			var src: Dictionary = source_nodes[part_name]
			var lod: Dictionary = lod_nodes[part_name]
			var src_mesh: Mesh = src["node"].mesh
			var lod_mesh: Mesh = lod["node"].mesh
			assert(src_mesh.get_surface_count() == lod_mesh.get_surface_count(), "%s %s surface count mismatch" % [key, part_name])
			assert(src["transform"] == lod["transform"], "%s %s transform mismatch" % [key, part_name])
			var src_tris := Lib.mesh_triangles(src_mesh)
			var lod_tris := Lib.mesh_triangles(lod_mesh)
			source_triangles += src_tris
			lod_triangles += lod_tris
			assets_parts.append({"name": part_name, "surfaces": src_mesh.get_surface_count(), "source_triangles": src_tris, "lod1_triangles": lod_tris})
		report["assets"][key] = {
			"path": path,
			"mesh_parts": assets_parts,
			"mesh_part_count": names.size(),
			"source_triangles": source_triangles,
			"lod1_triangles": lod_triangles,
			"triangle_reduction_fraction": 1.0 - float(lod_triangles) / float(maxi(source_triangles, 1)),
		}
		total_parts += names.size()
		lod_root.free()
		source_root.free()
	assert(total_parts == 30, "Expected 30 imported range LOD part templates, got %d" % total_parts)
	report["all_six_loaded"] = true
	report["mesh_part_templates"] = total_parts
	var file := FileAccess.open(OUT, FileAccess.WRITE)
	assert(file != null, "Could not write import validation receipt")
	file.store_string(JSON.stringify(report, "\t"))
	file.close()
	print("[RangeLODImportValidation] " + JSON.stringify(report))
	quit(0)

func _collect(node: Node, parent_xf: Transform3D, output: Dictionary) -> void:
	var xf := parent_xf
	if node is Node3D:
		xf = parent_xf * (node as Node3D).transform
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		if mi.mesh != null:
			var name := String(mi.name)
			assert(not output.has(name), "Duplicate mesh part node name: " + name)
			output[name] = {"node": mi, "transform": xf}
	for child in node.get_children():
		_collect(child, xf, output)
