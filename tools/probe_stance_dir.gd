extends SceneTree
## MEASUREMENT ONLY: foot position (model space) at the start and end of one
## leg's stance in each gait. A forward-moving animal plants the foot ahead
## (+Z) and pushes it back (-Z): z_end < z_start.
const HorseRig = preload("res://scripts/visual/civ3d/civ_horse_rig.gd")
var done := false
func _process(_d: float) -> bool:
	if done:
		return true
	done = true
	for glb in ["res://assets/units/cavalry_v0/horse_rigged.glb", "res://assets/units/scout_v0/dog_rigged.glb"]:
		var doc := GLTFDocument.new()
		var st := GLTFState.new()
		doc.append_from_file(ProjectSettings.globalize_path(glb), st)
		var m: Node3D = doc.generate_scene(st)
		root.add_child(m)
		var sk: Skeleton3D = m.find_children("*", "Skeleton3D", true, false)[0]
		var ap := AnimationPlayer.new()
		m.add_child(ap)
		ap.root_node = NodePath("..")
		ap.add_animation_library("", HorseRig.library(sk, str(m.get_path_to(sk))))
		ap.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
		for g in ["walk", "trot", "gallop"]:
			var gd: Array = HorseRig.GAITS[g]
			ap.play(g)
			var tot := 0.0
			for li in [0, 2]: # LF, LH
				var bone: String = ["f_hoof.L", "f_hoof.R", "h_hoof.L", "h_hoof.R"][li]
				var off: float = gd[5][li]
				var duty: float = gd[4]
				var zs := []
				for p in [0.02, duty * 0.5, duty - 0.02]:
					ap.seek(fposmod(p + off, 1.0) * float(gd[0]), true)
					zs.append((m.global_transform.affine_inverse() * sk.global_transform * sk.get_bone_global_pose(sk.find_bone(bone))).origin)
				print("%s %-6s %-9s stance start z %.3f  mid z %.3f  end z %.3f   (y %.3f %.3f %.3f)" % [glb.get_file(), g, bone, zs[0].z, zs[1].z, zs[2].z, zs[0].y, zs[1].y, zs[2].y])
				tot += (zs[0].z - zs[2].z) / ((duty - 0.04) * float(gd[0]))
			print("NATURAL %s %s %.3f model units / s" % [glb.get_file(), g, tot / 2.0])
	return true
