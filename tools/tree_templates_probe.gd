extends SceneTree
## Lists the forest pilot's unique tree template meshes per LOD (MEASUREMENT ONLY).
const Pilot = preload("res://scripts/visual/map_composition_v0/forest_runtime_pilot.gd")
const Lib = preload("res://scripts/visual/map_composition_v0/map_composition_library.gd")
func _initialize() -> void:
	var p: RefCounted = Pilot.new()
	for key in Lib.TREES:
		for lod in range(3):
			var ents: Array = p.call("_templates_for", String(key), lod)
			var t := 0
			for e in ents:
				t += Lib.mesh_triangles(e["mesh"])
			print("[Trees] %-24s LOD%d parts %d tris %d" % [key, lod, ents.size(), t])
	quit()
