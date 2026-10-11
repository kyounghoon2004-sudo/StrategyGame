extends Node3D
## The supplied animation is baked from Haruki; no procedural pose replacement.
const MODEL = preload("res://assets/units/haruki_v0/haruki_oxblood.scn")
const HEIGHT := 6.372538447380066
const SCALE := 1.65/HEIGHT
const CLIP := "A_Haruki_Attack_08_ThumbAxisPass"
var model: Node3D
var player: AnimationPlayer
var skeleton: Skeleton3D
var elapsed := 0.0
var running := false
var delay := 0.0

func _ready() -> void:
	model = MODEL.instantiate();model.name = "HarukiImported"
	model.scale = Vector3.ONE*SCALE
	model.position.y = .037142157554626465*SCALE
	add_child(model);find_nodes(model)
	assert(player != null and skeleton != null and skeleton.get_bone_count() == 71)
	assert(player.has_animation(CLIP))
	pose_at(0.0)

func find_nodes(node: Node) -> void:
	if node is AnimationPlayer:player = node
	if node is Skeleton3D:skeleton = node
	for child in node.get_children():find_nodes(child)

func pose_at(t: float) -> void:
	player.play(CLIP);player.seek(clampf(t,0,player.get_animation(CLIP).length),true);player.pause()

func attack(offset: float = 0) -> void:
	elapsed = -offset;running = true

func _process(dt: float) -> void:
	if not running:return
	elapsed += dt
	if elapsed < 0:return
	pose_at(elapsed)
	if elapsed > player.get_animation(CLIP).length+.20:
		pose_at(0);running = false

func idle() -> void:
	running = false;pose_at(0)
