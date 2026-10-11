extends SceneTree
## MAP COMPOSITION V0 — per-asset anatomy probe (headless).
## Instantiates every GLB asset standalone and reports exact structure:
## total triangles, mesh node count, per-mesh tris, surface count, LOD count,
## and whether mesh resources are SHARED between two instantiate() calls.
## CPU-only: safe with --headless (dummy RS may log mesh_lod query errors — harmless).
##
## Run:
##   Godot_console.exe --headless --path "<proj>" -s res://tools/probe_assets_map_composition_v0.gd

const Lib = preload("res://scripts/visual/map_composition_v0/map_composition_library.gd")
const OUT := "D:/Game development/Demon slayer/StrategyGame/evidence/map_composition_v0/asset_anatomy.json"


func _initialize() -> void:
	print("[asset] probe start")
	var groups := {
		"trees": Lib.TREES, "buildings": Lib.BUILDINGS, "forts": Lib.FORTS,
		"agri": Lib.AGRI, "mountains": Lib.MOUNTAINS, "tiles": Lib.TILES,
	}
	print("[asset] groups built: ", groups.keys())
	var report := {}
	for group in groups:
		var table: Dictionary = groups[group]
		var out := {}
		for key in table:
			print("[asset] loading ", group, "/", key)
			var ps: PackedScene = Lib.scene_for(key)
			print("[asset] loaded ", key)
			var a := ps.instantiate() as Node
			var b := ps.instantiate() as Node
			var res := _probe(a, b)
			out[key] = res
			print("[asset] %-9s %-16s nodes=%3d meshes=%3d surfaces=%3d tris=%8d shared=%s" % [
				group, key, res["nodes"], res["mesh_nodes"], res["surfaces"], res["tris"],
				res["meshes_shared"]])
			a.free()
			b.free()
		report[group] = out
	DirAccess.make_dir_recursive_absolute(OUT.get_base_dir())
	var f := FileAccess.open(OUT, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(report, "  "))
		f.close()
	quit(0)


func _probe(a: Node, b: Node) -> Dictionary:
	var meshes_a: Array = []
	var meshes_b: Array = []
	_collect_meshes(a, meshes_a)
	_collect_meshes(b, meshes_b)
	var tris := 0
	var surfaces := 0
	var per_mesh: Array = []
	for mi in meshes_a:
		var t := _tris(mi.mesh)
		tris += t
		surfaces += mi.mesh.get_surface_count()
		var lods: Array = []  # NOT queried headless: surface_get_lod_count deadlocks on dummy RS in _initialize; see windowed probe
		per_mesh.append({"name": String(mi.name), "tris": t, "lods": lods})
	var shared := true
	if meshes_a.size() == meshes_b.size():
		for i in range(meshes_a.size()):
			if meshes_a[i].mesh != meshes_b[i].mesh:
				shared = false
				break
	else:
		shared = false
	return {
		"nodes": _count_nodes(a),
		"mesh_nodes": meshes_a.size(),
		"surfaces": surfaces,
		"tris": tris,
		"meshes_shared": shared,
		"per_mesh": per_mesh,
	}


func _collect_meshes(n: Node, out: Array) -> void:
	if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
		out.append(n)
	for ch in n.get_children():
		_collect_meshes(ch, out)


func _count_nodes(n: Node) -> int:
	var c := 1
	for ch in n.get_children():
		c += _count_nodes(ch)
	return c


func _tris(m: Mesh) -> int:
	var tri := 0
	if m is ArrayMesh:
		for s in range(m.get_surface_count()):
			var il: int = m.surface_get_array_index_len(s)
			var al: int = m.surface_get_array_len(s)
			tri += int(il if il > 0 else al) / 3
	elif m is PrimitiveMesh:
		var arr: Array = (m as PrimitiveMesh).get_mesh_arrays()
		if arr.size() > Mesh.ARRAY_VERTEX and arr[Mesh.ARRAY_VERTEX] is PackedVector3Array:
			tri += (arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3
	return tri
