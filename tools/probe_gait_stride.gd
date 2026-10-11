extends SceneTree
## MEASUREMENT ONLY: natural ground speed of each procedural gait (walk / trot /
## gallop) at rate 1, in model units / s, from the planted feet sliding back
## relative to the body (the median over the lowest-foot samples).
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
		var feet := ["f_hoof.L", "f_hoof.R", "h_hoof.L", "h_hoof.R"]
		for g in ["walk", "trot", "gallop"]:
			ap.play(g)
			var length: float = ap.current_animation_length
			var dt := 1.0 / 240.0
			var speeds := []
			var prev := {}
			var t := 0.0
			while t < length:
				ap.seek(t, true)
				var lowest := ""
				var ly := INF
				var cur := {}
				for f in feet:
					var p: Vector3 = (m.global_transform.affine_inverse() * sk.global_transform * sk.get_bone_global_pose(sk.find_bone(f))).origin
					cur[f] = p
					if p.y < ly:
						ly = p.y
						lowest = f
				if prev.has(lowest):
					speeds.append((cur[lowest].z - prev[lowest].z) / dt)
				prev = cur
				t += dt
			speeds.sort()
			print("%-55s %-7s planted-foot dz/dt %.3f (negative = feet push back = moves forward) (cycle %.2f s)" % [glb.get_file(), g, speeds[speeds.size() / 2], length])
	return true
