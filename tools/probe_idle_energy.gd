extends SceneTree
## MEASUREMENT ONLY: motion energy of each idle clip (mean joint angular speed,
## deg / s) to sort them from calm to lively.
var lib: AnimationLibrary
func _initialize() -> void:
	var model: Node3D = load("res://assets/units/formation_v0/supplied_soldier.glb").instantiate()
	root.add_child(model)
	var sk: Skeleton3D = model.find_children("*", "Skeleton3D", true, false)[0]
	var ap := AnimationPlayer.new()
	model.add_child(ap)
	ap.root_node = NodePath("..")
	lib = load("res://assets/units/mocap_mixamo/soldier_mixamo_lib.res")
	ap.add_animation_library("", lib)
	ap.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	for clip in ["sword_and_shield_idle", "sword_and_shield_idle_2", "sword_and_shield_idle_3", "sword_and_shield_idle_4"]:
		ap.play(clip)
		var length: float = ap.current_animation_length
		var prev := []
		var total := 0.0
		var n := 0
		var t := 0.0
		while t < length:
			ap.seek(t, true)
			var cur := []
			for b in range(sk.get_bone_count()):
				cur.append(sk.get_bone_pose_rotation(b))
			if not prev.is_empty():
				for b in range(cur.size()):
					total += rad_to_deg((prev[b] as Quaternion).angle_to(cur[b])) / 0.05
					n += 1
			prev = cur
			t += 0.05
		print("%-26s %.2f s  energy %.1f deg/s" % [clip, length, total / maxf(1, n)])
	quit()
