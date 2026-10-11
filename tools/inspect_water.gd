extends SceneTree

func _initialize() -> void:
	const Lib = preload("res://scripts/visual/map_composition_v0/map_composition_library.gd")
	for k in Lib.WATER.keys():
		var scene: PackedScene = Lib.scene_for(k)
		var inst: Node = scene.instantiate()
		print("--- Water Asset: ", k, " ---")
		_dump_node(inst, "  ")
		inst.free()
	quit(0)

func _dump_node(node: Node, indent: String) -> void:
	var extra := ""
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		extra = " (Mesh: %s, surfaces: %d)" % [mi.mesh.get_class(), mi.mesh.get_surface_count() if mi.mesh else 0]
	print(indent, node.name, " [", node.get_class(), "]", extra)
	for ch in node.get_children():
		_dump_node(ch, indent + "  ")
