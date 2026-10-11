extends SceneTree
## MEASUREMENT ONLY: natural ground speed of each walk clip at clip speed 1,
## from the planted foot's backward slide relative to the hips (soldier height 1).
const Rig = preload("res://scripts/visual/civ3d/civ_soldier_rig.gd")
var ap: AnimationPlayer
var sk: Skeleton3D
var clips := ["sword_and_shield_walk", "sword_and_shield_walk_2"]
var ci := 0
var t := 0.0
var rows := []
func _initialize() -> void:
	var model: Node3D = load("res://assets/units/formation_v0/supplied_soldier.glb").instantiate()
	root.add_child(model)
	sk = model.find_children("*", "Skeleton3D", true, false)[0]
	ap = AnimationPlayer.new()
	model.add_child(ap)
	ap.root_node = NodePath("..")
	ap.add_animation_library("", load("res://assets/units/mocap_mixamo/soldier_mixamo_lib.res"))
	ap.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
func _foot(name: String) -> Vector3:
	var hips: Vector3 = sk.get_bone_global_pose(sk.find_bone(Rig.BONE["hips"])).origin
	return (sk.global_transform.basis * (sk.get_bone_global_pose(sk.find_bone(Rig.BONE[name])).origin - hips))
func _process(_d: float) -> bool:
	if t == 0.0:
		ap.play(clips[ci])
	ap.seek(t, true)
	var hp: Vector3 = sk.global_transform.basis * sk.get_bone_global_pose(sk.find_bone(Rig.BONE["hips"])).origin
	rows.append([t, _foot("l_foot"), _foot("r_foot"), hp])
	t += 1.0 / 120.0
	var length: float = ap.current_animation_length
	if t > length:
		# planted foot = the lower one; its horizontal velocity relative to the hips
		var sp := []
		for i in range(1, rows.size()):
			var lo := "l" if rows[i][1].y < rows[i][2].y else "r"
			var a: Vector3 = rows[i][1] if lo == "l" else rows[i][2]
			var b: Vector3 = rows[i - 1][1] if lo == "l" else rows[i - 1][2]
			var v := Vector2(a.x - b.x, a.z - b.z).length() * 120.0
			sp.append(v)
		sp.sort()
		var hipdz: float = (rows[rows.size() - 1][3] - rows[0][3]).length()
		print("%s len %.2f s  planted-foot speed median %.3f  p75 %.3f (x height/s)  hips root drift %.3f" % [clips[ci], length, sp[sp.size() / 2], sp[sp.size() * 3 / 4], hipdz])
		print("  sk scale ", sk.global_transform.basis.get_scale())
		ci += 1
		t = 0.0
		rows.clear()
		return ci >= clips.size()
	return false
