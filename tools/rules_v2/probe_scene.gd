extends SceneTree
func _init() -> void:
	var ps := load("res://data/baked_maps/EDITOR_M1.scn") as PackedScene
	var n := ps.instantiate()
	print("[S] root ", n.name, " children ", n.get_child_count())
	for c in n.get_children():
		print("[S]  ", c.name, " ", c.get_class(), " kids ", c.get_child_count(), " scale ", c.scale if c is Node3D else "-")
		var k := 0
		for g in c.get_children():
			if k < 6:
				var meta := []
				for m in g.get_meta_list():
					meta.append("%s=%s" % [m, str(g.get_meta(m))])
				print("[S]     ", g.name, " ", g.get_class(), " pos ", g.position if g is Node3D else "-", " kids ", g.get_child_count(), " meta ", meta)
			k += 1
	n.free()
	quit(0)
