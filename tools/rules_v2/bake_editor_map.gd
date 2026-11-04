extends "res://tools/dev_visual_lab/map_editor.gd"
## Bakes a saved DEV map exactly as the map editor draws it (board + all objects) into a
## PackedScene the game's 3D view loads instead of rebuilding scenery from terrain codes.
## SG_* env vars as for the editor; then:
##   godot --path . --script res://tools/rules_v2/bake_editor_map.gd -- <map.json> <out.scn> [--skip-hills]
## --skip-hills drops the hill groups (V2 maps remove hills: RULES_V2_SPEC "hill -> plains"), so the
## baked scenery matches the walkable terrain instead of showing ridges the game lets you walk through.

# editor world -> civ3d world (x: 0.25, z: 42*S/(sqrt3*18)), see civ_battlefield_view S=HEXR/24
const SX := 0.25
const SZ := 0.2526

func boot() -> void:
	super()
	var flags: Array = []
	var positional: Array = []
	for a in OS.get_cmdline_user_args():
		if str(a).begins_with("--"):
			flags.append(str(a))
		else:
			positional.append(str(a))
	if positional.size() < 2:
		push_error("usage: -- <map.json> <out.scn> [--skip-hills]"); quit(2); return
	perform_action("load", positional[0])
	for i in 30:
		await process_frame
	if "--skip-hills" in flags:
		var dropped := 0
		for child in placed_root.get_children():
			if str(child.get_meta("visual_signature", "")).begins_with("hill|"):
				placed_root.remove_child(child)
				child.queue_free()
				dropped += 1
		print("[Bake] hills skipped=", dropped)
	var container := Node3D.new()
	container.name = "EditorMapBake"
	container.scale = Vector3(SX, SX, SZ)
	container.rotation.y = PI   # game map = editor map rotated 180 deg (blue at the bottom)
	stage.remove_child(board_root)
	stage.remove_child(placed_root)
	container.add_child(board_root)
	container.add_child(placed_root)
	_own(container, container)
	var ps := PackedScene.new()
	var perr := ps.pack(container)
	var serr := ResourceSaver.save(ps, positional[1])
	print("[Bake] objects=", doc.objects.size(), " pack=", perr, " save=", serr, " -> ", positional[1])
	quit(0 if perr == OK and serr == OK else 1)

static func _own(n: Node, owner_node: Node) -> void:
	for c in n.get_children():
		c.owner = owner_node
		c.scene_file_path = ""
		_own(c, owner_node)
