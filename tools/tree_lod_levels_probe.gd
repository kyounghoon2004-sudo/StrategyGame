extends SceneTree
## Generated LOD levels per tree LOD2 template (MEASUREMENT ONLY).
const Pilot = preload("res://scripts/visual/map_composition_v0/forest_runtime_pilot.gd")
const Lib = preload("res://scripts/visual/map_composition_v0/map_composition_library.gd")
func _initialize() -> void:
	var p: RefCounted = Pilot.new()
	for key in ["conifer", "broadleaf", "tall_pine"]:
		for e in p.call("_templates_for", key, 2):
			var m: Mesh = e["mesh"]
			var im := ImporterMesh.new()
			for s in range(m.get_surface_count()):
				im.add_surface(m.surface_get_primitive_type(s), m.surface_get_arrays(s), [], {}, m.surface_get_material(s))
			im.generate_lods(25.0, 60.0, [])
			var base := (m.surface_get_arrays(0)[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3
			var lv := []
			for k in range(im.get_surface_lod_count(0)):
				lv.append(im.get_surface_lod_indices(0, k).size() / 3)
			print("[LODs] %s base %d -> %s" % [key, base, str(lv)])
	quit()
