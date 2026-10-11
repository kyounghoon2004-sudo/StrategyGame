extends SceneTree
func _init():
	var Lib = load("res://scripts/visual/map_composition_v0/map_composition_library.gd")
	var inst: Node3D = Lib.instance_centered("tile_open_grassland")
	var stack: Array = [inst]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		print("node=", n.name, " class=", n.get_class())
		if n is MeshInstance3D:
			var mi: MeshInstance3D = n
			print("  MESH FOUND: ", mi.mesh, " surfs=", mi.mesh.get_surface_count())
			if mi.mesh.get_surface_count() > 0:
				print("  SURF MAT: ", mi.mesh.surface_get_material(0))
		for c in n.get_children():
			stack.append(c)
	quit(0)
