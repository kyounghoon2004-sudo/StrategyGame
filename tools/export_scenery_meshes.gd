extends SceneTree

## Exports every unique heavy scenery mesh actually drawn by the CIV3D view to
## its own GLB + a manifest, for offline reduction (tools/reduce_scenery_blender.py).
## Visual pipeline only; source assets are never modified.
##   Godot --path <project> --script res://tools/export_scenery_meshes.gd

const Lib = preload("res://scripts/visual/map_composition_v0/map_composition_library.gd")
const OUT_DIR := "res://assets/map_composition_v0/strategy_lod/src/"
const MANIFEST := "res://assets/map_composition_v0/strategy_lod/manifest.json"
const MIN_TRIS := 1500

var menu_frames := 0
var done := false

static func mesh_key(m: Mesh) -> String:
	return "%s|%d|%d" % [m.resource_name, Lib.mesh_triangles(m), m.get_surface_count()]

func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
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
	var uses: Dictionary = {} # key -> [mesh, instances]
	_collect(view.get("strict_transplant"), uses)
	var manifest: Dictionary = {}
	var i := 0
	for key in uses.keys():
		var m: Mesh = uses[key][0]
		var tris: int = Lib.mesh_triangles(m)
		if tris < MIN_TRIS:
			continue
		var file := "m%03d.glb" % i
		i += 1
		var root := Node3D.new()
		var mi := MeshInstance3D.new()
		mi.name = "M"
		mi.mesh = m
		root.add_child(mi)
		var doc := GLTFDocument.new()
		var st := GLTFState.new()
		doc.append_from_scene(root, st)
		doc.write_to_filesystem(st, ProjectSettings.globalize_path(OUT_DIR + file))
		root.free()
		manifest[key] = {"file": file, "tris": tris, "instances": uses[key][1], "surfaces": m.get_surface_count()}
		print("[Export] %s %8d tris x%-5d %s" % [file, tris, uses[key][1], key])
	var f := FileAccess.open(MANIFEST, FileAccess.WRITE)
	f.store_string(JSON.stringify(manifest, "  "))
	f.close()
	print("[Export] %d meshes" % manifest.size())
	quit()
	return false

func _collect(n: Node, uses: Dictionary) -> void:
	var m: Mesh = null
	var count := 1
	if n is MultiMeshInstance3D and (n as MultiMeshInstance3D).multimesh:
		m = (n as MultiMeshInstance3D).multimesh.mesh
		count = (n as MultiMeshInstance3D).multimesh.instance_count
	elif n is MeshInstance3D:
		m = (n as MeshInstance3D).mesh
	if m != null and count > 0:
		var k := mesh_key(m)
		if not uses.has(k):
			uses[k] = [m, 0]
		uses[k][1] += count
	for c in n.get_children():
		_collect(c, uses)
