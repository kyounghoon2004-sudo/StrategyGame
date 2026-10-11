extends SceneTree
func _initialize() -> void:
	var model = load("res://assets/units/formation_v0/supplied_soldier.glb").instantiate()
	root.add_child(model)
	inspect(model)
	quit()
func inspect(node: Node) -> void:
	if node is Skeleton3D:
		print("SKELETON rest_only=",node.show_rest_only)
		for i in range(node.get_bone_count()):print(i," ",node.get_bone_name(i)," enabled=",node.is_bone_enabled(i))
	if node is MeshInstance3D:
		print("MESH skeleton=",node.skeleton," skin=",node.skin)
		if node.skin:
			for i in range(node.skin.get_bind_count()):print("BIND ",i," ",node.skin.get_bind_name(i)," ",node.skin.get_bind_bone(i))
	for c in node.get_children():inspect(c)
