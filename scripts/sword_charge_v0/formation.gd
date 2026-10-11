extends Node3D
## This node is the immutable logical anchor. Only VisualFormation moves.
const SOLDIER = preload("res://scenes/sword_charge_v0/soldier.tscn")
const ROWS := 4
const COLS := 5
const COL_SPACING := .82
const ROW_SPACING := .94
const CHARGE := 1.10
const STRIKE := .72
const HOLD := .14
const TURN := .12
const RETURN := 1.10
const TOTAL := CHARGE+STRIKE+HOLD+TURN+RETURN+TURN
var visual: Node3D
var soldiers: Array[Node3D] = []
var home := Transform3D.IDENTITY
var anchor := Transform3D.IDENTITY
var phase := "IDLE"
var active := false
var paused := false
var elapsed := 0.0
var target_direction := Vector3.FORWARD
var attack_yaw := 0.0
var home_yaw := 0.0
var travel := 0.0
var completed_cycles := 0
var max_anchor_drift := 0.0
var max_reset_drift := 0.0
@export var logical_hex := Vector2i.ZERO
@export var initial_facing := 0.0

func _ready() -> void:
	anchor = transform
	visual = Node3D.new();visual.name = "VisualFormation";add_child(visual)
	visual.rotation.y = initial_facing
	home = visual.transform;home_yaw = initial_facing
	for row in range(ROWS):
		for col in range(COLS):
			var i := row*COLS+col
			var soldier = SOLDIER.instantiate();soldier.name = "SwordSoldier_%02d" % (i+1)
			soldier.position = Vector3((col-2)*COL_SPACING+sin(i*2.41)*.018,0,(row-1.5)*ROW_SPACING+cos(i*1.71)*.014)
			soldier.step_offset = float((i*7)%11)*.043
			soldier.attack_offset = float((i*3)%5)*.010
			visual.add_child(soldier);soldiers.append(soldier)
	set_meta("logical_hex",logical_hex);set_meta("visual_only_excursion",true)
	assert(soldiers.size() == 20)

func attack_visual(target_world: Vector3) -> bool:
	if active:return false
	var delta := to_local(target_world)-home.origin;delta.y = 0
	if delta.length() < .001:return false
	target_direction = delta.normalized()
	attack_yaw = atan2(target_direction.x,target_direction.z)
	# Leave bodies apart at engagement. Front-rank sword reach spans the gap.
	travel = maxf(0,delta.length()-ROW_SPACING*3.0-1.08)
	active = true;elapsed = 0;paused = false
	sample_sequence(0.0)
	return true

func _process(dt: float) -> void:
	max_anchor_drift = maxf(max_anchor_drift,transform.origin.distance_to(anchor.origin))
	assert(transform == anchor)
	if active and not paused:
		elapsed += dt
		sample_sequence(elapsed)

func sample_sequence(t: float) -> void:
	var strike_end := CHARGE+STRIKE
	var hold_end := strike_end+HOLD
	var turn_end := hold_end+TURN
	var return_end := turn_end+RETURN
	var motion := "idle"
	var motion_t := 0.0
	var motion_strength := 1.0
	if t < CHARGE:
		phase = "CHARGE";motion = "march";motion_t = t
		motion_strength = smoothstep(0.0,.12,t)*(1.0-smoothstep(CHARGE-.12,CHARGE,t))
		var u := clampf(t/CHARGE,0,1)
		visual.position = home.origin+target_direction*travel*smoothstep(0.0,1.0,u)
		visual.rotation.y = lerp_angle(home_yaw,attack_yaw,smoothstep(0.0,.16,t))
	elif t < strike_end:
		phase = "SWORD STRIKE";motion = "sword_cut";motion_t = t-CHARGE
		visual.position = home.origin+target_direction*travel;visual.rotation.y = attack_yaw
	elif t < hold_end:
		phase = "RECOVER";visual.position = home.origin+target_direction*travel;visual.rotation.y = attack_yaw
	elif t < turn_end:
		phase = "TURN HOME";visual.rotation.y = lerp_angle(attack_yaw,attack_yaw+PI,(t-hold_end)/TURN)
	elif t < return_end:
		phase = "RETURN";motion = "march";motion_t = t-turn_end
		motion_strength = smoothstep(0.0,.12,motion_t)*(1.0-smoothstep(RETURN-.12,RETURN,motion_t))
		visual.rotation.y = attack_yaw+PI
		visual.position = home.origin+target_direction*travel*(1.0-smoothstep(0.0,1.0,(t-turn_end)/RETURN))
	elif t < TOTAL:
		phase = "RESET FACING";visual.position = home.origin
		visual.rotation.y = lerp_angle(attack_yaw+PI,home_yaw,(t-return_end)/TURN)
	else:
		visual.transform = home
		phase = "IDLE"
		if active:completed_cycles += 1
		active = false
		max_reset_drift = maxf(max_reset_drift,visual.position.distance_to(home.origin))
		assert(visual.transform == home)
	for soldier in soldiers:
		var local_t: float = motion_t+soldier.step_offset if motion == "march" else maxf(0,motion_t-soldier.attack_offset) if motion == "sword_cut" else 0.0
		soldier.set_motion(motion,local_t,motion_strength)

func at_home() -> bool:
	return visual.transform == home and transform == anchor and not active
