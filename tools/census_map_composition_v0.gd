extends SceneTree
## MAP COMPOSITION V0 — asset/triangle census (headless).
## Loads the review scene, walks every MeshInstance3D and produces a cost
## breakdown by FAMILY (forest/village/city/farm/mountain/tile/ground/decals)
## and by ASSET KEY (tree/building/fort/agri/mountain piece), plus mesh-sharing
## and LOD facts. CPU-only: safe to run with --headless (dummy renderer).
##
## Run:
##   Godot_console.exe --headless --path "<proj>" -s res://tools/census_map_composition_v0.gd

const OUT_DIR := "D:/Game development/Demon slayer/StrategyGame/evidence/map_composition_v0"

const TREE_KEYS := [
	"tall_pine", "wind_pine", "conifer", "compact_pine",
	"dead_tree", "broadleaf", "cypress", "sapling",
]

var _built := false


func _initialize() -> void:
	change_scene_to_file("res://scenes/review/map_composition_v0.tscn")


func _process(_delta: float) -> bool:
	var cs: Node = current_scene
	if cs == null or cs.get("built") == null or not bool(cs.get("built")):
		return false
	if _built:
		return false
	_built = true
	_run(cs)
	quit(0)
	return true


static func _mesh_lods(m: Mesh) -> int:
	# ArrayMesh-only; defensive (method exists in 4.2).
	var n := 0
	if m is ArrayMesh:
		var am := m as ArrayMesh
		for s in range(am.get_surface_count()):
			n = maxi(n, am.surface_get_lod_count(s))
	return n


static func _lod_sizes(m: Mesh, surface: int) -> Array:
	var out: Array = []
	if m is ArrayMesh:
		var am := m as ArrayMesh
		for l in range(am.surface_get_lod_count(surface)):
			out.append(am.surface_get_lod_size(surface, l))
	return out


static func _rid_of(m: Mesh) -> String:
	if m == null:
		return "null"
	return str(m.get_instance_id())


## Walk ancestors to find the asset wrap ("P_<key>") and the hex holder
## ("Hex_<family>_<q>_<r>"), plus special roots (Tile_*, Backdrop, ...).
static func _classify(n: Node) -> Dictionary:
	var wrap_key := ""
	var family := "ground"
	var hex := ""
	var anc: Node = n
	while anc != null:
		var nm := String(anc.name)
		if wrap_key == "" and nm.begins_with("P_"):
			wrap_key = nm.substr(2)
		if nm.begins_with("Hex_"):
			hex = nm
			var parts := nm.split("_")
			if parts.size() >= 2:
				family = String(parts[1])
			break
		if nm.begins_with("Tile_"):
			# tile GLBs sit directly under Hex_* holders; family already set
			family = "tile"
			break
		if nm == "Backdrop":
			family = "backdrop"
			break
		anc = anc.get_parent()
	# Asset keys of GLB pieces are known vocabulary; fences/decals are not.
	if wrap_key != "" and not family in ["forest", "village", "city", "farm", "mountain"]:
		family = "misc"
	return {"key": wrap_key, "family": family, "hex": hex}


static func _is_tree_key(k: String) -> bool:
	return k in TREE_KEYS


func _run(cs: Node) -> void:
	var fams: Dictionary = {}          # family -> stats
	var keys: Dictionary = {}          # key -> stats
	var meshes_seen: Dictionary = {}   # instance-id -> {tris, lods, surfaces, uses}
	var total_tris := 0
	var total_mi := 0
	var dc := 0                        # potential draw calls = surfaces per instance

	var stack: Array = [cs]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D:
			var mi := n as MeshInstance3D
			if mi.mesh != null:
				total_mi += 1
				var id := _rid_of(mi.mesh)
				if not meshes_seen.has(id):
					var lod_total := 0
					var lod_min := 1 << 30
					for s in range(mi.mesh.get_surface_count()):
						var lt := _mesh_lods(mi.mesh)
						lod_total = lt
						var sizes := _lod_sizes(mi.mesh, s)
						for sz in sizes:
							lod_min = mini(lod_min, int(sz))
					meshes_seen[id] = {
						"tris": Lib_mesh_triangles(mi.mesh),
						"surfaces": mi.mesh.get_surface_count(),
						"lods": lod_total,
						"lod_min_tris": (lod_min if lod_min < (1 << 30) else 0),
						"uses": 0,
					}
				meshes_seen[id]["uses"] = int(meshes_seen[id]["uses"]) + 1
				var tris: int = meshes_seen[id]["tris"]
				var surfaces: int = meshes_seen[id]["surfaces"]
				dc += surfaces
				total_tris += tris
				var cls := _classify(mi)
				var fam: String = cls["family"]
				if not fams.has(fam):
					fams[fam] = {"mesh_instances": 0, "triangles": 0, "draw_calls": 0, "keys": {}}
				fams[fam]["mesh_instances"] += 1
				fams[fam]["triangles"] += tris
				fams[fam]["draw_calls"] += surfaces
				var k: String = cls["key"]
				if k == "":
					k = "_" + fam + "_builtin"
				if not keys.has(k):
					keys[k] = {"family": fam, "instances": 0, "triangles_each": meshes_seen[id]["tris"],
						"triangles_total": 0, "draw_calls": 0, "is_tree": _is_tree_key(k)}
				keys[k]["instances"] += 1
				keys[k]["triangles_total"] += tris
				keys[k]["draw_calls"] += surfaces
		for ch in n.get_children():
			stack.append(ch)

	# node census
	var nodes := 0
	var stack2: Array = [cs]
	while not stack2.is_empty():
		var n2: Node = stack2.pop_back()
		nodes += 1
		for ch in n2.get_children():
			stack2.append(ch)

	# mesh-sharing facts
	var shared_meshes := meshes_seen.size()
	var mesh_instances_per_unique: Array = []
	for id in meshes_seen:
		mesh_instances_per_unique.append(int(meshes_seen[id].get("uses", 0)))

	var report := {
		"nodes": nodes,
		"mesh_instances": total_mi,
		"unique_meshes": shared_meshes,
		"potential_draw_calls": dc,
		"triangles_total": total_tris,
		"families": fams,
		"keys": keys,
		"meshes": meshes_seen,
	}
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	var f := FileAccess.open(OUT_DIR + "/census_v0.json", FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(report, "  "))
		f.close()

	print("[census] nodes=%d mesh_instances=%d unique_meshes=%d potential_dc=%d triangles=%d" % [
		nodes, total_mi, shared_meshes, dc, total_tris])
	var fam_names := fams.keys()
	fam_names.sort_custom(func(a, b): return int(fams[a]["triangles"]) > int(fams[b]["triangles"]))
	for fam in fam_names:
		print("[census] FAM %-9s mi=%5d tris=%11d dc=%5d" % [
			fam, int(fams[fam]["mesh_instances"]), int(fams[fam]["triangles"]), int(fams[fam]["draw_calls"])])
	var key_names := keys.keys()
	key_names.sort_custom(func(a, b): return int(keys[a]["triangles_total"]) > int(keys[b]["triangles_total"]))
	for k in key_names:
		print("[census] KEY %-16s fam=%-9s inst=%5d tris_each=%7d total=%11d dc=%5d tree=%s" % [
			k, keys[k]["family"], int(keys[k]["instances"]), int(keys[k]["triangles_each"]),
			int(keys[k]["triangles_total"]), int(keys[k]["draw_calls"]), keys[k]["is_tree"]])
	var print_lods := 0
	for id in meshes_seen:
		if int(meshes_seen[id]["lods"]) > 1 and print_lods < 12:
			print("[census] MESH tris=%7d surf=%d lods=%d minlod=%d" % [
				int(meshes_seen[id]["tris"]), int(meshes_seen[id]["surfaces"]),
				int(meshes_seen[id]["lods"]), int(meshes_seen[id]["lod_min_tris"])])
			print_lods += 1
	print("[census] wrote %s/census_v0.json" % OUT_DIR)


static func Lib_mesh_triangles(m: Mesh) -> int:
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
