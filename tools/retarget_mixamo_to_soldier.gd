extends SceneTree

## Retargets the Mixamo clips (assets/units/mocap_mixamo/mixamo_clips.glb, X Bot
## rig) onto assets/units/formation_v0/supplied_soldier.glb and saves an
## AnimationLibrary. Visual pipeline only.
##
## Method (model space, target = soldier, which faces -Z with identity rests):
##   delta(B, t) = G_src(B, t) * G_src_rest(B)^-1           (source motion)
##   A(b)        = arc(dir_tgt_rest(b) -> dir_src_rest(B))  (T-pose match)
##   G_tgt(b, t) = delta(B, t) * A(b);  local = G_tgt(parent)^-1 * G_tgt(b)
## Hips translation is the source hips offset scaled by the hip-height ratio.
##   Godot --headless --path <project> --script res://tools/retarget_mixamo_to_soldier.gd

const SRC := "res://assets/units/mocap_mixamo/mixamo_clips.glb"
const TGT := "res://assets/units/formation_v0/supplied_soldier.glb"
const OUT := "res://assets/units/mocap_mixamo/soldier_mixamo_lib.res"
const FPS := 30.0
## Clips whose horizontal hips drift is removed (loop in place).
const IN_PLACE := ["sword_and_shield_walk", "sword_and_shield_walk_2"]

## target joint -> [mixamo bone, mixamo child for direction | "", target child | ""]
const MAP := {
	"joint_12": ["Hips", "Spine", "joint_13"],
	"joint_13": ["Spine", "Spine1", "joint_10"],
	"joint_10": ["Spine1", "Spine2", "joint_9"],
	"joint_9": ["Spine2", "Neck", "joint_14"],
	"joint_14": ["Neck", "Head", "joint_11"],
	"joint_11": ["Head", "", ""],
	"joint_8": ["RightShoulder", "RightArm", "joint_4"],
	"joint_4": ["RightArm", "RightForeArm", "joint_2"],
	"joint_2": ["RightForeArm", "RightHand", "joint_1"],
	"joint_1": ["RightHand", "RightHandMiddle1", "joint_0"],
	"joint_15": ["LeftShoulder", "LeftArm", "joint_18"],
	"joint_18": ["LeftArm", "LeftForeArm", "joint_21"],
	"joint_21": ["LeftForeArm", "LeftHand", "joint_22"],
	"joint_22": ["LeftHand", "LeftHandMiddle1", "joint_23"],
	"joint_7": ["RightUpLeg", "RightLeg", "joint_6"],
	"joint_6": ["RightLeg", "RightFoot", "joint_5"],
	"joint_5": ["RightFoot", "RightToeBase", "joint_3"],
	"joint_3": ["RightToeBase", "", ""],
	"joint_17": ["LeftUpLeg", "LeftLeg", "joint_16"],
	"joint_16": ["LeftLeg", "LeftFoot", "joint_19"],
	"joint_19": ["LeftFoot", "LeftToeBase", "joint_20"],
	"joint_20": ["LeftToeBase", "", ""],
}

var ssk: Skeleton3D
var tsk: Skeleton3D
var sidx: Dictionary = {}
var s_xf: Transform3D # source skeleton -> model (incl. facing flip)

var _frames := 0

func _process(_d: float) -> bool:
	# run once the scene is in the tree and the AnimationPlayer is ready
	_frames += 1
	if _frames == 3:
		_run()
	return false

func _run() -> void:
	var doc := GLTFDocument.new()
	var st := GLTFState.new()
	var err := doc.append_from_file(ProjectSettings.globalize_path(SRC), st)
	assert(err == OK, "cannot read " + SRC)
	var src_root: Node = doc.generate_scene(st)
	ssk = _find_sk(src_root)
	var ap: AnimationPlayer = _find_ap(src_root)
	var tgt_root: Node3D = load(TGT).instantiate()
	tsk = _find_sk(tgt_root)
	root.add_child(src_root)
	for i in range(ssk.get_bone_count()):
		var n: String = ssk.get_bone_name(i)
		var short: String = n.get_slice(":", 1) if n.contains(":") else (n.substr(10) if n.begins_with("mixamorig_") else n)
		sidx[short] = i
	# source skeleton space -> model space: node transforms up to the scene root
	var x := Transform3D.IDENTITY
	var p: Node = ssk
	while p != null and p != src_root:
		if p is Node3D:
			x = (p as Node3D).transform * x
		p = p.get_parent()
	x.basis = x.basis.orthonormalized()
	x.origin = Vector3.ZERO
	var rx: float = (x * ssk.get_bone_global_rest(sidx["RightUpLeg"]).origin).x
	var lx: float = (x * ssk.get_bone_global_rest(sidx["LeftUpLeg"]).origin).x
	if rx < lx: # source's right is -X: it faces +Z; turn it to face -Z like the soldier
		x = Transform3D(Basis(Vector3.UP, PI), Vector3.ZERO) * x
	s_xf = x
	print("[Retarget] source bones ", ssk.get_bone_count(), " facing flip ", rx < lx)
	# T-pose match per target bone
	var A: Dictionary = {}
	for tb in MAP.keys():
		var m: Array = MAP[tb]
		if m[1] == "" or m[2] == "":
			continue
		var dt: Vector3 = (tsk.get_bone_global_rest(tsk.find_bone(m[2])).origin - tsk.get_bone_global_rest(tsk.find_bone(tb)).origin).normalized()
		var ds: Vector3 = (_src_rest(m[1]).origin - _src_rest(m[0]).origin).normalized()
		A[tb] = Quaternion(dt, ds)
	# leaf bones inherit their parent's match
	for tb in MAP.keys():
		if not A.has(tb):
			A[tb] = A.get(tsk.get_bone_name(tsk.get_bone_parent(tsk.find_bone(tb))), Quaternion.IDENTITY)
	var t_hip_h: float = tsk.get_bone_global_rest(tsk.find_bone("joint_12")).origin.y - minf(tsk.get_bone_global_rest(tsk.find_bone("joint_3")).origin.y, tsk.get_bone_global_rest(tsk.find_bone("joint_5")).origin.y)
	var s_hip_h: float = _src_rest("Hips").origin.y - minf(_src_rest("RightToeBase").origin.y, _src_rest("RightFoot").origin.y)
	var hscale: float = t_hip_h / s_hip_h
	var sk_path: String = str(tgt_root.get_path_to(tsk))
	var lib := AnimationLibrary.new()
	for anim_name in ap.get_animation_list():
		var src_anim: Animation = ap.get_animation(anim_name)
		# sanity: the source arm must move during the clip
		ap.play(anim_name); ap.seek(0.0, true); ap.advance(0.0)
		var r0: Quaternion = Quaternion(_src_pose("RightArm").basis.orthonormalized())
		ap.seek(src_anim.length * 0.5, true); ap.advance(0.0)
		var r1: Quaternion = Quaternion(_src_pose("RightArm").basis.orthonormalized())
		print("[Retarget] check ", anim_name, " right-arm motion deg ", rad_to_deg(r0.angle_to(r1)), " vs rest ", rad_to_deg(r0.angle_to(Quaternion(_src_rest("RightArm").basis.orthonormalized()))))
		var clip := _retarget(ap, anim_name, src_anim.length, A, hscale, sk_path)
		lib.add_animation(anim_name, clip)
		print("[Retarget] ", anim_name, " %.2fs" % src_anim.length)
	var e := ResourceSaver.save(lib, OUT)
	print("[Retarget] saved ", OUT, " err=", e, " skeleton path ", sk_path)
	tgt_root.free()
	quit()

func _initialize() -> void:
	pass

func _src_rest(bone: String) -> Transform3D:
	return s_xf * ssk.get_bone_global_rest(sidx[bone])

func _src_pose(bone: String) -> Transform3D:
	return s_xf * ssk.get_bone_global_pose(sidx[bone])

func _retarget(ap: AnimationPlayer, anim_name: String, length: float, A: Dictionary, hscale: float, sk_path: String) -> Animation:
	var a := Animation.new()
	a.length = length
	var tracks: Dictionary = {}
	for i in range(tsk.get_bone_count()):
		var t := a.add_track(Animation.TYPE_ROTATION_3D)
		a.track_set_path(t, NodePath("%s:%s" % [sk_path, tsk.get_bone_name(i)]))
		tracks[i] = t
	var hp := a.add_track(Animation.TYPE_POSITION_3D)
	a.track_set_path(hp, NodePath("%s:joint_12" % sk_path))
	ap.play(anim_name)
	var n: int = int(round(length * FPS))
	var hip_rest: Vector3 = _src_rest("Hips").origin
	var t_hip_local: Vector3 = tsk.get_bone_rest(tsk.find_bone("joint_12")).origin
	var hips: Array = []
	for f in range(n + 1):
		var t: float = minf(f / FPS, length)
		ap.seek(t, true)
		ap.advance(0.0)
		var G: Dictionary = {}
		for i in range(tsk.get_bone_count()):
			var tb: String = tsk.get_bone_name(i)
			var parent: int = tsk.get_bone_parent(i)
			var gp: Quaternion = G.get(parent, Quaternion.IDENTITY)
			var g: Quaternion
			if MAP.has(tb):
				var sb: String = MAP[tb][0]
				var delta: Quaternion = Quaternion(_src_pose(sb).basis.orthonormalized()) * Quaternion(_src_rest(sb).basis.orthonormalized()).inverse()
				g = (delta * (A[tb] as Quaternion)).normalized()
			else:
				g = gp
			G[i] = g
			a.rotation_track_insert_key(tracks[i], t, (gp.inverse() * g).normalized())
		hips.append([t, (_src_pose("Hips").origin - hip_rest) * hscale])
	# Every clip ends where it started (lunges mid-clip stay); walks lose all drift.
	if hips.size() > 1:
		var d0: Vector3 = hips[0][1]
		var d1: Vector3 = hips[hips.size() - 1][1]
		for k in range(hips.size()):
			var u: float = float(k) / float(hips.size() - 1)
			var drift: Vector3 = d0.lerp(d1, u)
			hips[k][1] = hips[k][1] - Vector3(drift.x, 0.0, drift.z)
	for h in hips:
		a.position_track_insert_key(hp, h[0], t_hip_local + h[1])
	ap.stop()
	return a

func _find_sk(n: Node) -> Skeleton3D:
	if n is Skeleton3D:
		return n
	for c in n.get_children():
		var s := _find_sk(c)
		if s:
			return s
	return null

func _find_ap(n: Node) -> AnimationPlayer:
	if n is AnimationPlayer:
		return n
	for c in n.get_children():
		var s := _find_ap(c)
		if s:
			return s
	return null
