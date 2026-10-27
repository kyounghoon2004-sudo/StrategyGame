extends SceneTree
var rows: Array = []
func _initialize() -> void:
	call_deferred("inspect_all")
func inspect_all() -> void:
	walk("res://assets/units")
	var lib: AnimationLibrary = load("res://assets/units/mocap_mixamo/soldier_mixamo_lib.res")
	var out := OS.get_environment("SG_DEV_LAB_OUT")
	if out == "": out = ProjectSettings.globalize_path("res://artifacts/dev_visual_lab")
	DirAccess.make_dir_recursive_absolute(out)
	var f := FileAccess.open(out.path_join("engine-import-receipt.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify({"unit_glbs": rows, "retargeted_clips": lib.get_animation_list(), "engine": Engine.get_version_info()}, "  "))
	f.close()
	print("[DevUnitImport] inspected ", rows.size(), " GLBs, retargeted clips ", lib.get_animation_list().size())
	quit()
func walk(path: String) -> void:
	for folder in DirAccess.get_directories_at(path): walk(path.path_join(folder))
	for file in DirAccess.get_files_at(path):
		if not file.ends_with(".glb"): continue
		var full := path.path_join(file)
		var scene: PackedScene = load(full)
		if scene == null:
			rows.append({"path": full, "loaded": false})
			continue
		var model := scene.instantiate()
		var row := {"path": full, "loaded": true, "meshes": 0, "skeleton_bones": [], "clips": []}
		var pending: Array[Node] = [model]
		while not pending.is_empty():
			var n: Node = pending.pop_back()
			if n is MeshInstance3D: row.meshes += 1
			if n is Skeleton3D: row.skeleton_bones.append(n.get_bone_count())
			if n is AnimationPlayer: row.clips.append_array(n.get_animation_list())
			for child in n.get_children(): pending.append(child)
		rows.append(row)
		model.free()

