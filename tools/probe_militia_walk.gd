extends SceneTree
## MEASUREMENT ONLY: during a sortie, log each soldier's clip, clip speed,
## ground speed and foot heights (are the feet stepping or gliding?).
const Rig = preload("res://scripts/visual/civ3d/civ_soldier_rig.gd")
var f: Node3D
var n := 0
var last := {}
func _initialize() -> void:
	f = load("res://scripts/visual/civ3d/civ_formation3d.gd").new()
	root.add_child(f)
	f.call("setup", OS.get_environment("CLS") if OS.get_environment("CLS") != "" else "conscript", "blue", 4, 2.23, Vector3(0, 0, -1), 5)
	f.call("place", [Vector3(-1, 0, 0), Vector3(1, 0, 0), Vector3(-1, 0, 1.5), Vector3(1, 0, 1.5)])
	f.call("set_strength", 1.0)
func _process(dt: float) -> bool:
	n += 1
	if n == 5:
		f.call("play_attack", Vector3(0, 0, -7.9))
	if n > 5 and n % 6 == 0:
		var s: Dictionary = f.get("_soldiers")[int(OS.get_environment("MEMBER")) if OS.get_environment("MEMBER") != "" else 0]
		var ap: AnimationPlayer = s["ap"]
		var h: Node3D = s["holder"]
		var sk: Skeleton3D = h.find_children("*", "Skeleton3D", true, false)[0]
		var dog: bool = bool(s.get("dog", false))
		var lf: float = (sk.global_transform * sk.get_bone_global_pose(sk.find_bone("f_hoof.L" if dog else Rig.BONE["l_foot"]))).origin.y
		var rf: float = (sk.global_transform * sk.get_bone_global_pose(sk.find_bone("f_hoof.R" if dog else Rig.BONE["r_foot"]))).origin.y
		var v: float = h.position.distance_to(last.get("p", h.position)) / (dt * 6.0)
		last["p"] = h.position
		print("t %.2f  %-26s spd %.2f  ground %.2f u/s  lfoot %.3f rfoot %.3f" % [n * dt, ap.current_animation, ap.speed_scale, v, lf, rf])
	return n > 260
