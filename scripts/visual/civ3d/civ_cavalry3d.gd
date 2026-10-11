extends Node3D

## CIV3D mounted formation (VISUAL ONLY): cavalry (spear) and the general (dao
## + 軍 command banner). Each mount = the rigged horse (civ_horse_rig.gd gaits)
## + the supplied soldier riding on the horse's "saddle" bone. The rider's upper
## body plays the retargeted Mixamo clips; his pelvis and legs are held in a
## riding seat every frame after the clip is applied. Same API as
## civ_formation3d.gd: setup / place / set_moving / set_speed / play_*.

const Rig = preload("res://scripts/visual/civ3d/civ_soldier_rig.gd")
const HorseRig = preload("res://scripts/visual/civ3d/civ_horse_rig.gd")
const SOLDIER := preload("res://assets/units/formation_v0/supplied_soldier.glb")
const MOCAP := preload("res://assets/units/mocap_mixamo/soldier_mixamo_lib.res")
const SkinShader = preload("res://scripts/visual/civ3d/civ_soldier3d.gdshader")
const HORSE_GLB := "res://assets/units/cavalry_v0/horse_rigged.glb"

const IDLE := ["sword_and_shield_idle", "sword_and_shield_idle_2", "sword_and_shield_idle_3", "sword_and_shield_idle_4"]
const ATTACK := {"spear": ["Upward_Thrust"], "dao": ["sword_and_shield_slash", "sword_and_shield_slash_3", "sword_and_shield_attack_2"]}
const HIT := ["sword_and_shield_impact", "sword_and_shield_impact_2"]
const DEATH := ["sword_and_shield_death", "sword_and_shield_death_2"]
const BLEND: float = 0.2
## Riding seat (soldier rig euler degrees; +X swings a leg forward, +Z spreads
## the right leg out / -Z the left).
const SEAT := {
	"joint_7": Vector3(78, 0, 24), "joint_6": Vector3(-82, 0, 0), "joint_5": Vector3(14, 0, 0),
	"joint_17": Vector3(78, 0, -24), "joint_16": Vector3(-82, 0, 0), "joint_19": Vector3(14, 0, 0),
}
## Couched-lance charge (spear riders): the spear points forward at hip height
## (hand frame -Z = forward when the arm hangs), the rider leans in, the left
## hand holds the reins. No swing: the horse gallops and the point leads.
const COUCH := {
	"joint_4": Vector3(10, 0, -14), "joint_2": Vector3(-2, 0, 0), "joint_1": Vector3(-12, 0, 0),
	"joint_18": Vector3(34, 0, 14), "joint_21": Vector3(48, 0, 0),
	"joint_13": Vector3(-10, 0, 0), "joint_10": Vector3(-8, 0, 0), "joint_9": Vector3(-4, 0, 0),
}
## The general (and his horse) stand out at this scale against line cavalry.
const GENERAL_SCALE: float = 1.3
## Horse size relative to the rider (model units: soldier 1.0 tall, horse 0.9).
const HORSE_SCALE_OF_MAN: float = 1.25
## Rider pelvis above the saddle point (rider model units).
const SEAT_LIFT: float = 0.02
## Mounted units face straight down the march axis (user: no diagonal).
const PROFILE_YAW: float = 0.0
## Riders fan out on the charge: the gap between mounts grows by this factor
## at the far end of the run.
const CH_SPREAD: float = 1.0

static var _horse_proto: Node3D = null
static var _mats: Dictionary = {}

var _mounts: Array = [] # {holder, horse_ap, rider_ap, rider_sk, rng, idle}
var _weapon := "spear"
var _moving := false
var _gait := "idle"
var _speed := 0.0
var _dead := false
var _charge_t := 0.0
var _facing := Vector3(0, 0, -1)
## The lance strikes home (local point): the view flinches the target there.
signal struck(at_local: Vector3)

static func supports(cls: String) -> bool:
	return cls in ["cavalry", "hq"]

static func _horse() -> Node3D:
	if _horse_proto == null:
		var doc := GLTFDocument.new()
		var st := GLTFState.new()
		doc.append_from_file(ProjectSettings.globalize_path(HORSE_GLB), st)
		_horse_proto = doc.generate_scene(st)
	return _horse_proto

func setup(cls: String, faction: String, count: int, height: float, facing: Vector3, seed_value: int) -> void:
	_weapon = "dao" if cls == "hq" else "spear"
	for n in MOCAP.get_animation_list():
		var a: Animation = MOCAP.get_animation(n)
		a.loop_mode = Animation.LOOP_LINEAR if n in IDLE else Animation.LOOP_NONE
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var man: float = height * 0.86 # same human size as the foot soldiers
	if cls == "hq":
		man *= GENERAL_SCALE # the general reads larger than his troops
	var yaw: float = atan2(facing.x, facing.z) + PROFILE_YAW # the horse looks down +Z
	_facing = Vector3(facing.x, 0.0, facing.z).normalized()
	for i in range(count):
		var holder := Node3D.new()
		holder.rotation.y = yaw + rng.randf_range(-0.1, 0.1)
		add_child(holder)
		var horse: Node3D = _horse().duplicate()
		var kh: float = man * HORSE_SCALE_OF_MAN * rng.randf_range(0.97, 1.03)
		horse.scale = Vector3.ONE * kh
		horse.position.y = 0.45 * kh # hooves at y = -0.45
		holder.add_child(horse)
		var hsk: Skeleton3D = _find(horse)
		_dye(horse, faction, rng)
		var hap := AnimationPlayer.new()
		horse.add_child(hap)
		hap.root_node = NodePath("..")
		hap.add_animation_library("", HorseRig.library(hsk, str(horse.get_path_to(hsk))))
		hap.speed_scale = rng.randf_range(0.92, 1.08)
		hap.play("idle")
		hap.seek(rng.randf() * 4.0, true)
		# rider on the saddle bone, expressed in the horse's model frame
		var att := BoneAttachment3D.new()
		att.bone_name = "saddle"
		hsk.add_child(att)
		var frame := Node3D.new()
		frame.transform = Transform3D(hsk.get_bone_global_rest(hsk.find_bone("saddle")).basis.orthonormalized().inverse(), Vector3.ZERO)
		att.add_child(frame)
		var rider: Node3D = SOLDIER.instantiate()
		var kr: float = 1.0 / HORSE_SCALE_OF_MAN
		rider.scale = Vector3.ONE * kr
		rider.rotation.y = PI # the soldier looks down -Z, the horse down +Z
		rider.position.y = (SEAT_LIFT - 0.008) * kr
		frame.add_child(rider)
		var rsk: Skeleton3D = _find(rider)
		_dye(rider, faction, rng)
		var weapon: MeshInstance3D = _attach(rsk, Rig.BONE["r_hand"], _weapon)
		if cls == "hq":
			_banner(rsk, faction)
		var rap := AnimationPlayer.new()
		rider.add_child(rap)
		rap.root_node = NodePath("..")
		rap.add_animation_library("", MOCAP)
		rap.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
		var idle: String = IDLE[rng.randi() % IDLE.size()]
		rap.play(idle)
		rap.seek(rng.randf() * rap.current_animation_length, true)
		rap.animation_finished.connect(_on_finished.bind(i))
		_mounts.append({"k": kh, "yaw_home": holder.rotation.y, "holder": holder, "horse_ap": hap, "rider_ap": rap, "rider_sk": rsk, "rng": rng, "idle": idle, "seated": true, "weapon": weapon})

var _far := false

## Distance LOD from the view: far away horses and riders freeze and stop
## casting shadows.
func set_far(far: bool) -> void:
	_far = far
	if far and _charge_t > 0.0:
		_end_charge()
	for m in _mounts:
		(m["horse_ap"] as AnimationPlayer).active = not far
		for mi in _meshes(m["holder"]):
			(mi as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF if far else GeometryInstance3D.SHADOW_CASTING_SETTING_ON

## Animation rate LOD from the view: 0 = every frame, else updates per second.
var _rate := 0.0
var _acc := 0.0

func set_rate(hz: float) -> void:
	if is_equal_approx(hz, _rate):
		return
	_rate = hz
	_acc = randf() / maxf(hz, 1.0)
	for m in _mounts:
		(m["horse_ap"] as AnimationPlayer).callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL if hz > 0.0 else AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_IDLE

func _process(delta: float) -> void:
	if _far:
		return
	_acc += delta
	if _rate > 0.0 and _acc < 1.0 / _rate:
		return
	var step := _acc
	_acc = 0.0
	for m in _mounts:
		if _rate > 0.0:
			(m["horse_ap"] as AnimationPlayer).advance(step)
		var ap: AnimationPlayer = m["rider_ap"]
		ap.advance(step)
		if m["seated"]:
			_seat(m["rider_sk"])
			if _weapon == "spear":
				# lance: carried upright, lowered smoothly for the charge, raised after
				var w: float = float(m.get("lance", 0.0))
				w = move_toward(w, 1.0 if bool(m.get("couched", false)) else 0.0, step * LANCE_RATE)
				m["lance"] = w
				_couch(m["rider_sk"], w)
				_hold_spear(m, w)
	if _charge_t > 0.0:
		_advance_charge(step)
	elif _turning:
		_turn(step)

## The spear is always set relative to the horse, whatever the rider's idle
## clip does to his shoulder (the grip stays in the fist): carried upright,
## tipped a little forward; couched it leads dead ahead, slightly down.
const COUCH_PITCH_DEG: float = -5.0
const CARRY_PITCH_DEG: float = 78.0
const LANCE_RATE: float = 2.2 # carry <-> couch blend per second

func _hold_spear(m: Dictionary, couch: float) -> void:
	var w: Node3D = m["weapon"]
	var holder: Node3D = m["holder"]
	var fwd: Vector3 = holder.global_transform.basis.z # the horse looks down +Z
	var flat := Vector3(fwd.x, 0.0, fwd.z).normalized()
	var e: float = couch * couch * (3.0 - 2.0 * couch)
	var pitch: float = deg_to_rad(lerpf(CARRY_PITCH_DEG, COUCH_PITCH_DEG, e))
	var dir: Vector3 = (flat * cos(pitch) + Vector3.UP * sin(pitch)).normalized()
	var up: Vector3 = Vector3.UP if absf(dir.y) < 0.95 else -flat
	var s: Vector3 = w.global_transform.basis.get_scale()
	w.global_transform = Transform3D(Basis.looking_at(dir, up) * Basis.from_scale(s), w.global_transform.origin)

func _seat(sk: Skeleton3D) -> void:
	var hips := sk.find_bone("joint_12")
	sk.set_bone_pose_position(hips, sk.get_bone_rest(hips).origin)
	sk.set_bone_pose_rotation(hips, Quaternion.IDENTITY)
	for b in SEAT.keys():
		sk.set_bone_pose_rotation(sk.find_bone(b), Quaternion.from_euler((SEAT[b] as Vector3) * (PI / 180.0)))

## Couch arm pose blended over the clip's pose by `w` (0 = clip, 1 = couched).
func _couch(sk: Skeleton3D, w: float) -> void:
	if w <= 0.001:
		return
	for b in COUCH.keys():
		var bi: int = sk.find_bone(b)
		var q := Quaternion.from_euler((COUCH[b] as Vector3) * (PI / 180.0))
		sk.set_bone_pose_rotation(bi, sk.get_bone_pose_rotation(bi).slerp(q, w))

func place(points: Array) -> void:
	for i in range(mini(points.size(), _mounts.size())):
		_mounts[i]["home"] = points[i]
		if not _mounts[i].has("charge"):
			(_mounts[i]["holder"] as Node3D).position = points[i]

func set_moving(m: bool) -> void:
	if m == _moving or _dead:
		return
	_moving = m
	_apply_gait()

## Board speed in world px / s while moving: walk / trot / gallop.
func set_speed(px_per_s: float) -> void:
	_speed = px_per_s
	_apply_gait()

func _apply_gait() -> void:
	if _charge_t > 0.0:
		return # the charge owns the gait until it ends
	var g := "idle"
	if _moving:
		# march speeds from the view (world px / s): trot on the march, gallop catching up
		g = "walk" if _speed < 16.0 else ("trot" if _speed < 38.0 else "gallop")
	var changed: bool = g != _gait
	_gait = g
	var rate: Vector2 = Formation.IDLE_RATE_BY_MORALE[_morale_level]
	for m in _mounts:
		var hap: AnimationPlayer = m["horse_ap"]
		if changed:
			hap.play(g, 0.3)
			if g == "idle": # a standing horse fidgets less as morale sinks
				hap.speed_scale = (m["rng"] as RandomNumberGenerator).randf_range(rate.x, rate.y)
		if g != "idle": # hooves planted: the gait's rate follows the march speed
			hap.speed_scale = _gait_rate(m, g, _speed * 0.1875)

## Clip rate that makes gait g cover v units / s with the hooves planted.
func _gait_rate(m: Dictionary, g: String, v: float) -> float:
	var natural: float = float(HorseRig.GAIT_SPEED.get(g, 1.0)) * float(m.get("k", 1.0))
	return clampf(v / maxf(natural, 0.01), 0.5, 2.6)

## Morale level from the board (0 low, 1 wavering, 2 steady): riders and their
## standing horses get calmer (same clip / rate tables as the foot formations).
const Formation = preload("res://scripts/visual/civ3d/civ_formation3d.gd")
var _morale_level := 2

func set_morale(level: int) -> void:
	level = clampi(level, 0, 2)
	if level == _morale_level:
		return
	_morale_level = level
	var pool: Array = Formation.IDLE_BY_MORALE[level]
	var rate: Vector2 = Formation.IDLE_RATE_BY_MORALE[level]
	for m in _mounts:
		if bool(m.get("down", false)):
			continue
		var rng: RandomNumberGenerator = m["rng"]
		m["idle"] = pool[rng.randi() % pool.size()]
		var rap: AnimationPlayer = m["rider_ap"]
		if rap.current_animation in IDLE:
			rap.play(m["idle"], BLEND)
		rap.speed_scale = rng.randf_range(rate.x, rate.y)
		if _gait == "idle":
			(m["horse_ap"] as AnimationPlayer).speed_scale = rng.randf_range(rate.x, rate.y)

## Marching: horses face where they are going (local direction from the view;
## ZERO = halted, wheel back to the front). Turns are smooth.
var _march_dir := Vector3.ZERO
var _turning := false

func set_heading(dir: Vector3) -> void:
	_march_dir = Vector3(dir.x, 0.0, dir.z)
	_turning = true

func _turn(dt: float) -> void:
	var k: float = 1.0 - exp(-dt * 4.0)
	var marching: bool = _march_dir.length() > 0.1
	var settled := true
	for m in _mounts:
		var h: Node3D = m["holder"]
		var target: float = atan2(_march_dir.x, _march_dir.z) if marching else float(m["yaw_home"]) # the horse looks down +Z
		h.rotation.y = lerp_angle(h.rotation.y, target, k)
		if absf(angle_difference(h.rotation.y, target)) > 0.01:
			settled = false
	if settled and not marching:
		_turning = false

## `target` = vector to the enemy (world space, from this unit); zero = straight ahead.
func play_attack(target: Vector3 = Vector3.ZERO) -> void:
	if _weapon == "spear":
		_start_charge(target)
		return
	_one_shot(ATTACK[_weapon], 0.25)

# ---------------------------------------------------------------- charge
## Couched-lance charge along one smooth path per rider (one of several shapes
## picked at random): ease into a gallop straight at the enemy, ride through
## the strike point, peel off outward in a U-turn, gallop back past home, U-turn
## again and ease to a stop on home facing the front. The heading always
## follows the path; the lance lowers smoothly for the run and comes back up
## to the carry after it (no swing). Presentation offset only: the unit's hex
## never changes.
const Sortie = preload("res://scripts/visual/civ3d/civ_sortie.gd")
const CHARGE_VARIANTS := ["straight", "wedge", "sweep_left", "sweep_right", "staggered"]
const CH_LEN_MAX: float = 6.0
const CH_CONTACT_GAP: float = 4.4 # lances meet the enemy front rank, horses don't ride through it
const CH_SPEED: float = 8.5      # gallop, units / s
const CH_ACCEL: float = 0.7      # s to reach the gallop from a stand
const CH_DECEL: float = 1.1      # s to pull up on home
const CH_TURN_R: float = 1.6     # U-turn radius
const CH_BEHIND: float = 1.2     # how far behind home the return U-turn runs
const CH_YAW_RATE: float = 9.0   # heading smoothing (1/s)
var _charge_clock := 0.0
var _charge_end := 0.0
var _charge_dir := Vector3.FORWARD
var _charge_perp := Vector3.RIGHT
var _charge_len := 7.0
var _struck_sent := false
var charge_variant := ""

func _start_charge(target: Vector3) -> void:
	if _dead or _mounts.is_empty() or _charge_t > 0.0:
		return
	var rng: RandomNumberGenerator = _mounts[0]["rng"]
	var v: Vector3 = _facing * 7.9 # no target: straight at the front (already local)
	if target.length() > 0.1:
		v = global_transform.basis.inverse() * target if is_inside_tree() else target
	v.y = 0.0
	_charge_len = clampf(v.length() - CH_CONTACT_GAP, 2.5, CH_LEN_MAX)
	_charge_dir = v.normalized()
	_charge_perp = Vector3.UP.cross(_charge_dir).normalized()
	charge_variant = CHARGE_VARIANTS[rng.randi() % CHARGE_VARIANTS.size()]
	var front: Vector3 = _facing
	var front_perp: Vector3 = Vector3.UP.cross(front).normalized()
	var mean := Vector3.ZERO
	for m in _mounts:
		mean += m.get("home", (m["holder"] as Node3D).position)
	mean /= float(_mounts.size())
	_charge_end = 0.0
	_struck_sent = false
	for m in _mounts:
		var home: Vector3 = m.get("home", (m["holder"] as Node3D).position)
		m["home"] = home
		m.erase("charge")
		if bool(m.get("down", false)):
			continue # an unhorsed rider's mount stays put
		var off: float = (home - mean).dot(_charge_perp)
		var side: float = signf(off) if absf(off) > 0.05 else (1.0 if rng.randf() < 0.5 else -1.0)
		var delay := 0.0
		var reach := 1.0
		var lat: float = off * CH_SPREAD
		var bow := 0.0 # sideways bulge of the outbound run
		match charge_variant:
			"wedge":
				var lead: bool = absf(off) < 0.6
				delay = 0.0 if lead else rng.randf_range(0.15, 0.3)
				reach = 1.05 if lead else 0.9
				lat += 0.0 if lead else side * 0.15 * _charge_len
			"sweep_left", "sweep_right":
				bow = (1.0 if charge_variant == "sweep_left" else -1.0) * 0.3 * _charge_len
				delay = rng.randf_range(0.0, 0.15)
			"staggered":
				delay = rng.randf_range(0.0, 0.45)
				reach = rng.randf_range(0.8, 1.1)
				lat += rng.randf_range(-0.08, 0.08) * _charge_len
		var my_reach: float = _charge_len * reach
		var strike: Vector3 = home + _charge_dir * my_reach + _charge_perp * lat
		var path := Sortie.out_path(home, _charge_dir, _charge_perp, my_reach, lat, bow)
		var d_strike: float = Sortie.cumulative(path)[path.size() - 1]
		var behind: float = CH_BEHIND * rng.randf_range(0.8, 1.6) # riders don't pull up in lockstep
		var back := Sortie.back_path(strike, _charge_dir, _charge_perp, home, front, front_perp, CH_TURN_R, side, behind, CH_TURN_R * 0.3)
		path.append_array(back.slice(1))
		var cum := Sortie.cumulative(path)
		var length: float = cum[cum.size() - 1]
		var dur: float = Sortie.duration(length, CH_SPEED, CH_ACCEL, CH_DECEL)
		m["charge"] = {"delay": delay, "path": path, "cum": cum, "len": length, "dur": dur, "d_strike": d_strike, "slow": false}
		_charge_end = maxf(_charge_end, delay + dur)
	if _charge_end <= 0.0:
		return
	_charge_clock = 0.0
	_charge_t = _charge_end
	_gait = "gallop"
	for m in _mounts:
		if m.has("charge"):
			(m["horse_ap"] as AnimationPlayer).play("gallop", 0.6) # long blend: eases out of the stand

func _advance_charge(step: float) -> void:
	_charge_clock += step
	var k: float = 1.0 - exp(-step * CH_YAW_RATE)
	for m in _mounts:
		m["couched"] = false
		if not m.has("charge"):
			continue
		var p: Dictionary = m["charge"]
		var holder: Node3D = m["holder"]
		var t: float = _charge_clock - float(p["delay"])
		if t <= 0.0:
			continue
		var length: float = p["len"]
		var d: float = Sortie.dist_at(t, length, CH_SPEED, CH_ACCEL, CH_DECEL)
		var at: Array = Sortie.at(p["path"], p["cum"], d)
		holder.position = at[0]
		# hooves planted: gallop / trot clip rate follows the actual speed
		var hap_c: AnimationPlayer = m["horse_ap"]
		hap_c.speed_scale = _gait_rate(m, String(hap_c.current_animation), Sortie.speed_at(t, length, CH_SPEED, CH_ACCEL, CH_DECEL))
		var tan: Vector3 = at[1]
		if tan.length() > 0.5:
			holder.rotation.y = lerp_angle(holder.rotation.y, atan2(tan.x, tan.z), k)
		# lance down from the start through the strike and the first U-turn
		m["couched"] = d < float(p["d_strike"]) + CH_TURN_R * 2.0
		if not _struck_sent and d >= float(p["d_strike"]):
			_struck_sent = true
			struck.emit(holder.position + _charge_dir * 1.5)
		# pull up: gallop -> trot as the rider nears home (idle once stopped)
		var left: float = length - d
		if not bool(p["slow"]) and left < CH_SPEED * CH_DECEL * 0.6:
			p["slow"] = true
			(m["horse_ap"] as AnimationPlayer).play("trot", 0.5)
	_charge_t = _charge_end - _charge_clock
	if _charge_t <= 0.0:
		_end_charge()

func _end_charge() -> void:
	_charge_t = 0.0
	for m in _mounts:
		m.erase("charge")
		if m.has("home"):
			(m["holder"] as Node3D).position = m["home"]
		(m["holder"] as Node3D).rotation.y = m["yaw_home"]
		m["couched"] = false
	if not _struck_sent:
		_struck_sent = true
		struck.emit(_facing * 7.9)
	_gait = ""
	_apply_gait()

## Unit strength (soldier_count / max_count, read from the board): riders are
## unhorsed, front first, until the mounts left match it; the horse stands.
var _strength_set := false

func set_strength(frac: float) -> void:
	if _dead:
		return
	var n: int = _mounts.size()
	var want: int = n if frac >= 0.999 else clampi(roundi(float(n) * frac), 1 if frac > 0.0 else 0, n)
	var alive: Array = []
	for i in range(n):
		if not bool(_mounts[i].get("down", false)):
			alive.append(i)
	var instant: bool = not _strength_set
	_strength_set = true
	if alive.size() <= want:
		return
	var keyed: Array = []
	for i in alive:
		keyed.append([(_mounts[i].get("home", Vector3.ZERO) as Vector3).dot(_facing) + randf_range(-0.6, 0.6), i])
	keyed.sort_custom(func(a, b): return a[0] > b[0])
	for j in range(alive.size() - want):
		var m: Dictionary = _mounts[keyed[j][1]]
		m["down"] = true
		m["seated"] = false
		m["couched"] = false
		var ap: AnimationPlayer = m["rider_ap"]
		var rng: RandomNumberGenerator = m["rng"]
		ap.play(DEATH[rng.randi() % DEATH.size()], 0.0 if instant else 0.15)
		if instant:
			ap.seek(ap.current_animation_length - 0.01, true)
		(m["horse_ap"] as AnimationPlayer).play("idle", 0.3)

func play_hit() -> void:
	_one_shot(HIT, 0.15)

func play_death() -> void:
	_dead = true
	for m in _mounts:
		m["seated"] = false # the rider falls; the horse stands
		(m["horse_ap"] as AnimationPlayer).play("idle", 0.3)
	_one_shot(DEATH, 0.3)

func _one_shot(pool: Array, stagger: float) -> void:
	for m in _mounts:
		if bool(m.get("down", false)):
			continue # unhorsed riders stay down
		var rng: RandomNumberGenerator = m["rng"]
		var clip: String = pool[rng.randi() % pool.size()]
		var ap: AnimationPlayer = m["rider_ap"]
		if not is_inside_tree():
			ap.play(clip, BLEND)
			continue
		var tree: SceneTree = get_tree()
		tree.create_timer(rng.randf_range(0.0, stagger)).timeout.connect(func():
			if is_instance_valid(ap) and ap.is_inside_tree() and (_dead or not bool(m.get("down", false))):
				ap.play(clip, BLEND))

func _on_finished(_anim: StringName, i: int) -> void:
	if _dead or bool(_mounts[i].get("down", false)):
		return
	var m: Dictionary = _mounts[i]
	(m["rider_ap"] as AnimationPlayer).play(m["idle"], BLEND)

func _attach(sk: Skeleton3D, bone: String, kind: String) -> MeshInstance3D:
	var att := BoneAttachment3D.new()
	att.bone_name = bone
	sk.add_child(att)
	var w := MeshInstance3D.new()
	w.mesh = Rig.weapon_mesh(kind)
	att.add_child(w)
	return w

## The general's 軍 command banner on a pole at his back.
func _banner(sk: Skeleton3D, faction: String) -> void:
	var att := BoneAttachment3D.new()
	att.bone_name = Rig.BONE["chest"]
	sk.add_child(att)
	var pole := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.008
	cyl.bottom_radius = 0.008
	cyl.height = 0.85
	pole.mesh = cyl
	var wood := StandardMaterial3D.new()
	wood.albedo_color = Color(0.32, 0.22, 0.12)
	pole.material_override = wood
	pole.position = Vector3(0.0, 0.28, 0.07) # behind the back (the soldier faces -Z)
	att.add_child(pole)
	var flag := MeshInstance3D.new()
	var q := QuadMesh.new()
	q.size = Vector2(0.24, 0.3)
	flag.mesh = q
	# gold command banner (both sides; the general's seal colour is on his badge)
	var cloth := StandardMaterial3D.new()
	cloth.albedo_color = Color(0.86, 0.68, 0.26)
	cloth.metallic = 0.55
	cloth.roughness = 0.38
	cloth.cull_mode = BaseMaterial3D.CULL_DISABLED
	flag.material_override = cloth
	flag.position = Vector3(0.0, 0.28, 0.0) # hangs beside the pole top
	flag.rotation.y = PI * 0.5
	pole.add_child(flag)
	# gilded finial on the pole top
	var tip := MeshInstance3D.new()
	var sph := SphereMesh.new()
	sph.radius = 0.018
	sph.height = 0.036
	tip.mesh = sph
	var gold := StandardMaterial3D.new()
	gold.albedo_color = Color(0.92, 0.74, 0.30)
	gold.metallic = 0.8
	gold.roughness = 0.3
	tip.material_override = gold
	tip.position = Vector3(0.0, 0.44, 0.0)
	pole.add_child(tip)
	for side in [1.0, -1.0]:
		var glyph := Label3D.new()
		glyph.text = "軍"
		glyph.font_size = 96
		glyph.pixel_size = 0.0016
		glyph.modulate = Color(0.45, 0.07, 0.05) # crimson character on gold
		glyph.outline_size = 0
		glyph.position = Vector3(0.0, 0.0, 0.003 * side)
		glyph.rotation.y = 0.0 if side > 0 else PI
		flag.add_child(glyph)

func _dye(model: Node, faction: String, rng: RandomNumberGenerator) -> void:
	for mi in _meshes(model):
		# per surface: the horse carries two (body + the separate head piece)
		for si in range(mi.mesh.get_surface_count()):
			var src: Material = mi.mesh.surface_get_material(si)
			if not (src is BaseMaterial3D):
				continue
			var key: String = faction + str(src.get_instance_id())
			if not _mats.has(key):
				var m := ShaderMaterial.new()
				m.shader = SkinShader
				m.set_shader_parameter("albedo_tex", (src as BaseMaterial3D).albedo_texture)
				m.set_shader_parameter("faction_hue", 0.6 if faction == "blue" else 0.0)
				_mats[key] = m
			mi.set_surface_override_material(si, _mats[key])
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		mi.set_instance_shader_parameter("cloth_v", rng.randf_range(0.82, 1.1))
		mi.set_instance_shader_parameter("skin_v", rng.randf_range(0.85, 1.05))

static func _meshes(n: Node, out: Array = []) -> Array:
	if n is MeshInstance3D:
		out.append(n)
	for c in n.get_children():
		_meshes(c, out)
	return out

static func _find(n: Node) -> Skeleton3D:
	if n is Skeleton3D:
		return n
	for c in n.get_children():
		var s := _find(c)
		if s:
			return s
	return null
