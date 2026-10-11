extends SceneTree

## Prints the supplied soldier's skeleton: index, name, parent, global rest
## position and the global rest axes. Inspection only.

func _initialize() -> void:
	var inst: Node = load("res://assets/units/formation_v0/supplied_soldier.glb").instantiate()
	var sk: Skeleton3D = _find(inst)
	print("skeleton path xf ", sk.transform)
	for i in range(sk.get_bone_count()):
		var g: Transform3D = sk.get_bone_global_rest(i)
		var l: Transform3D = sk.get_bone_rest(i)
		print("%2d %-9s parent=%2d pos=(%.3f, %.3f, %.3f) X=%s Y=%s Z=%s local=(%.3f, %.3f, %.3f)" % [
			i, sk.get_bone_name(i), sk.get_bone_parent(i), g.origin.x, g.origin.y, g.origin.z,
			_v(g.basis.x), _v(g.basis.y), _v(g.basis.z), l.origin.x, l.origin.y, l.origin.z])
	var meshes: Array = []
	_meshes(inst, meshes)
	for m in meshes:
		print("mesh ", m.name, " skin=", m.skin != null, " aabb=", m.get_aabb(), " xf=", m.transform)
	inst.free()
	quit()

func _v(v: Vector3) -> String:
	return "(%.2f,%.2f,%.2f)" % [v.x, v.y, v.z]

func _find(n: Node) -> Skeleton3D:
	if n is Skeleton3D:
		return n
	for c in n.get_children():
		var s := _find(c)
		if s:
			return s
	return null

func _meshes(n: Node, out: Array) -> void:
	if n is MeshInstance3D:
		out.append(n)
	for c in n.get_children():
		_meshes(c, out)
