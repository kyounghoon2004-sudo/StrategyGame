extends SceneTree
## MEASUREMENT ONLY: cavalry charge path direction vs unit facing.
func _initialize() -> void:
	var C = load("res://scripts/visual/civ3d/civ_cavalry3d.gd")
	var c: Node3D = C.new()
	root.add_child(c)
	c.call("setup", "cavalry", "blue", 6, 2.0, Vector3(0, 0, -1), 3)
	var pts := []
	for i in range(6):
		pts.append(Vector3((i % 3) * 1.5 - 1.5, 0, (i / 3) * 1.5))
	c.call("place", pts)
	c.call("play_attack")
	print("dir ", c.get("_charge_dir"), " facing ", c.get("_facing"))
	var m: Dictionary = c.get("_mounts")[0]
	var path: PackedVector3Array = m["charge"]["path"]
	for i in [0, 4, 8, 15, 16, 20, 29, 40, 52, 56]:
		if i < path.size():
			print(i, " ", path[i])
	print("yaw0 ", m["yaw0"], " holder yaw ", (m["holder"] as Node3D).rotation.y)
	quit()
