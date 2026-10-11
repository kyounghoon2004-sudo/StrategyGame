extends SceneTree

## Inspect a saved CIV3D scenery cache (MEASUREMENT ONLY): triangles drawn per
## top-level group, counting only visible geometry.
##   Godot --headless --path <project> --script res://tools/inspect_scenery_cache.gd

var by_mesh := {}
const Lib = preload("res://scripts/visual/map_composition_v0/map_composition_library.gd")

func _initialize() -> void:
	var dir := DirAccess.open("user://civ3d_cache/")
	for f in dir.get_files():
		var ps: PackedScene = load("user://civ3d_cache/" + f)
		var root: Node = ps.instantiate()
		print("== ", f)
		for c in root.get_children():
			var acc := [0, 0, 0, 0] # nodes, tris, hidden nodes, vis-range nodes
			_walk(c, true, acc)
			print("  %-40s nodes %6d  tris %12d  hidden %5d  visrange %5d" % [c.name, acc[0], acc[1], acc[2], acc[3]])
		var keys := by_mesh.keys()
		keys.sort_custom(func(a, b): return by_mesh[a][1] > by_mesh[b][1])
		for k in keys.slice(0, 25):
			print("    %-60s nodes %5d tris %12d  e.g. %s" % [k, by_mesh[k][0], by_mesh[k][1], by_mesh[k][2]])
		root.free()
	quit()

func _walk(n: Node, vis: bool, acc: Array) -> void:
	if n is Node3D and not (n as Node3D).visible:
		vis = false
	var m: Mesh = null
	var count := 1
	if n is MultiMeshInstance3D and (n as MultiMeshInstance3D).multimesh:
		m = (n as MultiMeshInstance3D).multimesh.mesh
		count = (n as MultiMeshInstance3D).multimesh.instance_count
	elif n is MeshInstance3D:
		m = (n as MeshInstance3D).mesh
	if m != null:
		if not vis:
			acc[2] += 1
		else:
			acc[0] += 1
			acc[1] += Lib.mesh_triangles(m) * count
			var k := "%s|%d|%s" % [m.resource_name, Lib.mesh_triangles(m), n.get_class()]
			if not by_mesh.has(k):
				by_mesh[k] = [0, 0, str(n.get_parent().name) + "/" + str(n.name)]
			by_mesh[k][0] += 1
			by_mesh[k][1] += Lib.mesh_triangles(m) * count
			if (n as GeometryInstance3D).visibility_range_end > 0.0:
				acc[3] += 1
	for c in n.get_children():
		_walk(c, vis, acc)
