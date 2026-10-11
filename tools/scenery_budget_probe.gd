extends SceneTree

## Static triangle budget of the CIV3D scenery (MEASUREMENT ONLY): triangles x
## instances per family / node kind / LOD, to find what actually costs.
##   Godot --path <project> --script res://tools/scenery_budget_probe.gd

const Lib = preload("res://scripts/visual/map_composition_v0/map_composition_library.gd")
var menu_frames := 0
var done := false

func _initialize() -> void:
	change_scene_to_file("res://scenes/title_screen.tscn")

func _process(_d: float) -> bool:
	if done:
		return false
	if current_scene != null and current_scene.scene_file_path == "res://scenes/title_screen.tscn":
		menu_frames += 1
		if menu_frames == 8:
			var collection: Node = current_scene.get("_map_collection")
			collection.call("open")
			collection.find_child("OpenExistingProductionLayout", true, false).emit_signal("pressed")
		return false
	if current_scene == null:
		return false
	var view: Node = current_scene.get("_view3d")
	if view == null or not bool(view.call("is_active")):
		return false
	done = true
	var tr: Node = view.get("strict_transplant")
	var by: Dictionary = {}
	_walk(tr, "", by)
	var forest: Node = view.get_node_or_null("ForestMerged")
	if forest:
		_walk(forest, "ForestMerged", by)
	# per mesh resource (asset part): what to reduce first
	var per_mesh: Dictionary = {}
	_walk_mesh(view, per_mesh)
	var mk := per_mesh.keys()
	mk.sort_custom(func(a, b): return per_mesh[a][0] > per_mesh[b][0])
	for k in mk.slice(0, 40):
		print("[Mesh] %12d tris  x%-6d  %6d tris/inst  %s" % [per_mesh[k][0], per_mesh[k][1], per_mesh[k][2], k])
	var keys := by.keys()
	keys.sort_custom(func(a, b): return by[a][0] > by[b][0])
	var total := 0
	for k in keys:
		total += int(by[k][0])
	print("[Budget] TOTAL scenery triangles (all LODs counted where visible flag on): ", total)
	for k in keys.slice(0, 30):
		print("[Budget] %12d tris  %6d nodes  %s" % [by[k][0], by[k][1], k])
	quit()
	return false

func _walk(n: Node, family: String, by: Dictionary) -> void:
	var fam := family
	if n.get_parent() != null and n.get_parent().name == "ApprovedFamilies":
		fam = String(n.name).get_slice("_", 0)
	if n is MultiMeshInstance3D:
		var mmi := n as MultiMeshInstance3D
		if mmi.multimesh and mmi.multimesh.mesh:
			var lod := ""
			var nm := String(n.name)
			if nm.contains("LOD"):
				lod = nm.substr(nm.find("LOD"), 4)
			var key := "%s | MultiMesh %s %s" % [fam, lod, "(hidden)" if not mmi.visible else ""]
			_add(by, key, Lib.mesh_triangles(mmi.multimesh.mesh) * mmi.multimesh.instance_count)
	elif n is MeshInstance3D:
		var mi := n as MeshInstance3D
		if mi.mesh:
			_add(by, "%s | MeshInstance %s" % [fam, "(hidden)" if not mi.is_visible_in_tree() else ""], Lib.mesh_triangles(mi.mesh))
	for c in n.get_children():
		_walk(c, fam, by)

func _walk_mesh(n: Node, out: Dictionary) -> void:
	var mesh: Mesh = null
	var count := 1
	if n is MultiMeshInstance3D and (n as MultiMeshInstance3D).visible and (n as MultiMeshInstance3D).multimesh:
		var mm := (n as MultiMeshInstance3D).multimesh
		mesh = mm.mesh
		count = mm.visible_instance_count if mm.visible_instance_count >= 0 else mm.instance_count
	elif n is MeshInstance3D and (n as MeshInstance3D).is_visible_in_tree():
		mesh = (n as MeshInstance3D).mesh
	if mesh != null and count > 0 and not (n is MeshInstance3D and (n as MeshInstance3D).skin != null):
		var k := "%s [%s]" % [mesh.resource_name, n.get_parent().name if n.get_parent() else ""]
		k = mesh.resource_name if mesh.resource_name != "" else k
		var t := Lib.mesh_triangles(mesh)
		if not out.has(k):
			out[k] = [0, 0, t]
		out[k][0] += t * count
		out[k][1] += count
	for c in n.get_children():
		_walk_mesh(c, out)

func _add(by: Dictionary, k: String, tris: int) -> void:
	if not by.has(k):
		by[k] = [0, 0]
	by[k][0] += tris
	by[k][1] += 1
