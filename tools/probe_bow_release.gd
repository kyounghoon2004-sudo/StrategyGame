extends SceneTree
## MEASUREMENT ONLY: hand separation over the Shooting_Arrow clip (release = sharp drop after full draw).
const Rig = preload("res://scripts/visual/civ3d/civ_soldier_rig.gd")
var ap: AnimationPlayer
var sk: Skeleton3D
var t := 0.0
var started := false
func _initialize() -> void:
	var model: Node3D = load("res://assets/units/formation_v0/supplied_soldier.glb").instantiate()
	root.add_child(model)
	sk = model.find_children("*", "Skeleton3D", true, false)[0]
	ap = AnimationPlayer.new()
	model.add_child(ap)
	ap.root_node = NodePath("..")
	ap.add_animation_library("", load("res://assets/units/mocap_mixamo/soldier_mixamo_lib.res"))
	ap.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
func _process(_d: float) -> bool:
	if not started:
		ap.play("Shooting_Arrow")
		started = true
	ap.seek(t, true)
	var r: Vector3 = sk.get_bone_global_pose(sk.find_bone(Rig.BONE["r_hand"])).origin
	var l: Vector3 = sk.get_bone_global_pose(sk.find_bone(Rig.BONE["l_hand"])).origin
	print("T %.2f %.3f" % [t, r.distance_to(l)])
	t += 0.05
	return t > 10.0
