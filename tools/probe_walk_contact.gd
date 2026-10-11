extends SceneTree
## MEASUREMENT ONLY: soldier walk clips' ground speed at rate 1 from foot
## CONTACT (foot within 1.5 % of its lowest height): the planted foot's signed
## forward slide relative to the hips (model looks down -Z: walking forward
## pushes the planted foot toward +Z). Soldier height = 1.
const Rig = preload("res://scripts/visual/civ3d/civ_soldier_rig.gd")
var done := false
func _process(_d: float) -> bool:
	if done:
		return true
	done = true
	var model: Node3D = load("res://assets/units/formation_v0/supplied_soldier.glb").instantiate()
	root.add_child(model)
	var sk: Skeleton3D = model.find_children("*", "Skeleton3D", true, false)[0]
	var ap := AnimationPlayer.new()
	model.add_child(ap)
	ap.root_node = NodePath("..")
	ap.add_animation_library("", load("res://assets/units/mocap_mixamo/soldier_mixamo_lib.res"))
	ap.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	for clip in ["sword_and_shield_walk", "sword_and_shield_walk_2"]:
		ap.play(clip)
		var length: float = ap.current_animation_length
		var dt := 1.0 / 240.0
		var res := []
		for foot in ["l_foot", "r_foot"]:
			var ys := []
			var zs := []
			var t := 0.0
			while t < length:
				ap.seek(t, true)
				var g: Transform3D = model.global_transform.affine_inverse() * sk.global_transform
				var f: Vector3 = (g * sk.get_bone_global_pose(sk.find_bone(Rig.BONE[foot]))).origin
				var hp: Vector3 = (g * sk.get_bone_global_pose(sk.find_bone(Rig.BONE["hips"]))).origin
				ys.append(f.y)
				zs.append(f.z - hp.z)
				t += dt
			var lo: float = ys.min()
			var hi: float = ys.max()
			var v := []
			for i in range(1, ys.size()):
				if ys[i] < lo + 0.12 * (hi - lo):
					v.append((zs[i] - zs[i - 1]) / dt)
			v.sort()
			res.append(v[v.size() / 2])
		print("CONTACT %s %.3f %.3f  (x height/s, + = walks forward)" % [clip, res[0], res[1]])
	return true
