extends SceneTree

const Lib = preload("res://scripts/visual/map_composition_v0/map_composition_library.gd")


func _initialize() -> void:
	print("[t] start")
	var ps: PackedScene = Lib.scene_for("tall_pine")
	var inst := ps.instantiate() as Node
	print("[t] inst children=", inst.get_child_count())
	var meshes: Array = []
	_collect(inst, meshes)
	print("[t] meshes=", meshes.size())
	var m: Mesh = meshes[0].mesh
	print("[t] surf count=", m.get_surface_count())
	print("[t] idx len=", m.surface_get_array_index_len(0))
	print("[t] arr len=", m.surface_get_array_len(0))
	if m is ArrayMesh:
		var am := m as ArrayMesh
		print("[t] is ArrayMesh, calling surface_get_lod_count(0)...")
		print("[t] lod count=", am.surface_get_lod_count(0))
	inst.free()
	print("[t] done")
	quit(0)


func _collect(n: Node, out: Array) -> void:
	if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
		out.append(n)
	for ch in n.get_children():
		_collect(ch, out)
