extends Node3D
const SCALE := 1.65/1.0007815957069397
const SOURCE = preload("res://assets/units/formation_v0/supplied_soldier.glb")
const SWORD = preload("res://assets/units/sword_charge_v0/straight_sword.tscn")
const MOTIONS = preload("res://assets/units/sword_charge_v0/sword_motion_library.tres")
var skeleton: Skeleton3D
var player: AnimationPlayer
var model: Node3D
var socket: BoneAttachment3D
var sword: Node3D
var current_clip := ""
var motion_time := 0.0
var step_offset := 0.0
var attack_offset := 0.0

func _ready() -> void:
	model = Node3D.new();model.name = "Model"
	model.scale = Vector3.ONE*SCALE;model.rotation.y = PI
	model.position.y = .49999183416366577*SCALE;add_child(model)
	var body = SOURCE.instantiate();body.name = "GLB";model.add_child(body)
	skeleton = find_skeleton(body)
	assert(skeleton != null and skeleton.find_bone("joint_0") >= 0)
	# +X arm in source anatomy is the right arm: joint_4 -> 2 -> 1 -> 0.
	socket = BoneAttachment3D.new();socket.name = "RightHandSocket";socket.bone_name = "joint_0"
	skeleton.add_child(socket)
	sword = SWORD.instantiate();sword.name = "SharedStraightSword"
	sword.scale = Vector3.ONE/SCALE
	sword.rotation_degrees.x = -110
	sword.position = Vector3(0,-.004,-.005)
	socket.add_child(sword)
	player = AnimationPlayer.new();player.name = "SwordMotionPlayer";add_child(player)
	player.root_node = NodePath("..")
	player.add_animation_library("",MOTIONS)
	set_motion("idle",0.0)

func find_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:return node
	for child in node.get_children():
		var result := find_skeleton(child)
		if result:return result
	return null

func set_motion(clip: String, time: float, strength: float = 1.0) -> void:
	if current_clip != clip:player.play(clip);current_clip = clip
	motion_time = time
	var t := fposmod(time,.60) if clip == "march" else clampf(time,0.0,.68) if clip == "sword_cut" else fposmod(time,1.0)
	player.seek(t,true);player.pause()
	if clip == "march" and strength < 1.0:
		var idle: Animation = MOTIONS.get_animation("idle")
		for track in range(idle.get_track_count()):
			var bone := skeleton.find_bone(str(idle.track_get_path(track).get_subname(0)))
			var ready: Quaternion = idle.rotation_track_interpolate(track,0.0)
			skeleton.set_bone_pose_rotation(bone,ready.slerp(skeleton.get_bone_pose_rotation(bone),strength))
	# Small local bob accompanies the leg cycle; no soldier root motion.
	model.position.y = .49999183416366577*SCALE + (.035*strength*absf(sin(t*TAU/.60)) if clip == "march" else 0.0)

func grip_error() -> float:
	var hand := skeleton.get_bone_global_pose(skeleton.find_bone("joint_0")).origin
	return sword.global_position.distance_to(skeleton.to_global(hand))

func tip_world() -> Vector3:
	return sword.to_global(Vector3(0,.91,0))
