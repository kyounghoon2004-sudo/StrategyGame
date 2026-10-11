extends SceneTree
func _initialize() -> void:
	var path := "res://assets/units/haruki_v0/haruki_oxblood.glb"
	assert(FileAccess.file_exists(path))
	var document := GLTFDocument.new()
	var state := GLTFState.new()
	assert(document.append_from_file(path,state) == OK)
	var scene := document.generate_scene(state,60.0)
	assert(scene != null)
	var packed := PackedScene.new()
	assert(packed.pack(scene) == OK)
	assert(ResourceSaver.save(packed,"res://assets/units/haruki_v0/haruki_oxblood.scn",ResourceSaver.FLAG_COMPRESS) == OK)
	inspect(scene)
	scene.free()
	print("HARUKI_NATIVE_IMPORT_OK")
	quit()
func inspect(node: Node) -> void:
	if node is Skeleton3D:print("BONES ",node.get_bone_count())
	if node is AnimationPlayer:print("ANIMATIONS ",node.get_animation_list()," length ",node.get_animation(node.get_animation_list()[0]).length)
	for child in node.get_children():inspect(child)
