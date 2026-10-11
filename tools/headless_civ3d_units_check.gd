extends SceneTree
## Headless (CPU only) smoke check: builds every CIV3D 3D formation class and
## fires each reaction once. No rendering, no GPU.
const F3D = preload("res://scripts/visual/civ3d/civ_formation3d.gd")
const CAV = preload("res://scripts/visual/civ3d/civ_cavalry3d.gd")
var t := 0
func _initialize() -> void:
	var x := 0.0
	for cls in ["infantry", "spearman", "archer", "conscript"]:
		var f: Node3D = F3D.new(); root.add_child(f)
		f.call("setup", cls, "blue", 7, 2.2, Vector3(0, 0, -1), hash(cls))
		f.position.x = x; x += 5.0
		f.call("play_attack")
		print("[Check] ", cls, " ok, soldiers ", f.get_child_count())
	for cls in ["cavalry", "hq"]:
		var c: Node3D = CAV.new(); root.add_child(c)
		c.call("setup", cls, "red", 2, 2.6, Vector3(0, 0, 1), hash(cls))
		c.call("play_attack")
		print("[Check] ", cls, " ok")
func _process(_d: float) -> bool:
	t += 1
	if t == 120:
		print("[Check] ran 120 frames")
		quit()
	return false
