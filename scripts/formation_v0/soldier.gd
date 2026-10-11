extends Node3D
## Presentation-only wrapper. The supplied GLB geometry/materials are untouched.
const MODEL_HEIGHT := 1.0007815957069397
const MODEL_FLOOR := -0.49999183416366577
const WORLD_HEIGHT := 1.65
const ATTACK_DURATION := 0.76
static var _shared_clip: Animation
var imported_model: Node3D
var skeleton: Skeleton3D
var player: AnimationPlayer
var visual_motion: Node3D
var attack_phase := 0.0:
	set(value):
		attack_phase = value
		_apply_attack_pose()

func _ready() -> void:
	visual_motion = Node3D.new();visual_motion.name = "VisualMotion";add_child(visual_motion)
	var facing := Node3D.new();facing.name = "GroundedModel"
	# Raw toes and face point -Z; use an outer wrapper to face formation +Z.
	facing.rotation.y = PI
	facing.scale = Vector3.ONE * (WORLD_HEIGHT / MODEL_HEIGHT)
	facing.position.y = -MODEL_FLOOR * WORLD_HEIGHT / MODEL_HEIGHT
	visual_motion.add_child(facing)
	imported_model = preload("res://assets/units/formation_v0/supplied_soldier.glb").instantiate()
	facing.add_child(imported_model)
	_find_skeleton(imported_model)
	assert(skeleton != null and skeleton.get_bone_count() == 24)
	# Anatomical roles inferred from actual source joint positions and parentage.
	for name in ["joint_13","joint_18","joint_21","joint_4","joint_2"]:
		assert(skeleton.find_bone(name) >= 0)
	player = AnimationPlayer.new();player.name = "AttackPlayer";add_child(player)
	player.root_node = NodePath("..")
	var library := AnimationLibrary.new();library.add_animation("attack",shared_attack_clip())
	player.add_animation_library("",library)
	player.animation_finished.connect(_on_attack_finished)
	_apply_attack_pose()

func _find_skeleton(node: Node) -> void:
	if node is Skeleton3D: skeleton = node
	for child in node.get_children(): _find_skeleton(child)

static func shared_attack_clip() -> Animation:
	if _shared_clip != null:return _shared_clip
	var clip := Animation.new();clip.resource_name = "Formation_Attack_V0";clip.length = ATTACK_DURATION
	var track := clip.add_track(Animation.TYPE_VALUE)
	clip.track_set_path(track,NodePath(".:attack_phase"))
	clip.value_track_set_update_mode(track,Animation.UPDATE_CONTINUOUS)
	for key in [[0.0,0.0],[0.12,-0.16],[0.26,0.28],[0.40,1.0],[0.54,0.46],[0.76,0.0]]:
		clip.track_insert_key(track,key[0],key[1])
	_shared_clip = clip
	return clip

func _apply_attack_pose() -> void:
	if skeleton == null or visual_motion == null: return
	visual_motion.position.z = attack_phase * 0.18
	for pair in [["joint_13",-12.0],["joint_18",100.0],["joint_21",-5.0],["joint_4",65.0],["joint_2",15.0]]:
		var index := skeleton.find_bone(pair[0])
		skeleton.set_bone_pose_rotation(index,Quaternion(Vector3.RIGHT,deg_to_rad(pair[1])*attack_phase))
	# Let Skeleton3D send its deferred pose update to the renderer.

func attack() -> void:
	player.play("attack")

func seek_attack(seconds: float) -> void:
	player.play("attack");player.seek(clampf(seconds,0,ATTACK_DURATION),true);player.pause()

func reset_idle() -> void:
	player.stop();attack_phase = 0.0

func _on_attack_finished(_name: StringName) -> void:
	reset_idle()

func is_idle() -> bool:
	return abs(attack_phase) < 0.00001 and visual_motion.position.length() < 0.00001
