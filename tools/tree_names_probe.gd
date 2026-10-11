extends SceneTree
## Mesh / node names of a tree LOD2 template vs its baked LOD3 (MEASUREMENT ONLY).
const Pilot = preload("res://scripts/visual/map_composition_v0/forest_runtime_pilot.gd")
func _initialize() -> void:
	var p: RefCounted = Pilot.new()
	for e in p.call("_templates_for", "conifer", 2):
		print("[Names] lod2 mesh resource_name='%s' surfaces=%d" % [e["mesh"].resource_name, e["mesh"].get_surface_count()])
	var doc := GLTFDocument.new()
	var st := GLTFState.new()
	doc.append_from_file(ProjectSettings.globalize_path("res://assets/map_composition_v0/forest_runtime_pilot/conifer_lod3.glb"), st)
	var sc: Node = doc.generate_scene(st)
	for mi in sc.find_children("*", "MeshInstance3D", true, false):
		print("[Names] lod3 node='%s' mesh='%s'" % [mi.name, (mi as MeshInstance3D).mesh.resource_name])
	quit()
