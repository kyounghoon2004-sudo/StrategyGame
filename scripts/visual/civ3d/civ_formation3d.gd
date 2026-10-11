extends Node3D

## CIV3D 3D formation (VISUAL ONLY): one unit's soldiers as lit, shadow-casting
## 3D figures (assets/units/formation_v0/supplied_soldier.glb) driven by the
## retargeted Mixamo library. Each soldier picks his own idle clip, phase,
## speed and cloth / skin shade, so the ranks never move in lockstep.
## The view tells it what is happening (moving, attack, hit, death); it never
## reads or writes gameplay.

const Rig = preload("res://scripts/visual/civ3d/civ_soldier_rig.gd")
const SOLDIER := preload("res://assets/units/formation_v0/supplied_soldier.glb")
const MOCAP := preload("res://assets/units/mocap_mixamo/soldier_mixamo_lib.res")
const SkinShader = preload("res://scripts/visual/civ3d/civ_soldier3d.gdshader")

## class -> [right hand, left hand]
const LOADOUT := {
	"infantry": ["dao", "shield"], "conscript": ["mixed", "hat"], "conscripts": ["mixed", "hat"],
	"spearman": ["spear", ""], "spearmen": ["spear", ""], "spear": ["spear", ""],
	"archer": ["bow", ""], "archers": ["bow", ""],
	# scouts: militia kit (straw hat, drab cloth, spear or dao) plus scout dogs
	"scout": ["mixed", "hat"], "scouts": ["mixed", "hat"],
}
## Scout dog (assets/units/scout_v0/dog_rigged.glb, tools/rig_dog_blender.py):
## rigged like the horse, so the horse gait generator drives it. Every third
## member of a scout unit is a dog.
const DogRig = preload("res://scripts/visual/civ3d/civ_horse_rig.gd")
const DOG_GLB := "res://assets/units/scout_v0/dog_rigged.glb"
const DOG_SCALE_OF_MAN: float = 0.8  # model scale per figure height (a big war dog, readable from above)
const DOG_WALK_BELOW: float = 0.6    # below this speed (x model scale per s) the dog walks
static var _dog_proto: Node3D = null
## Idle activity by morale level (0 = low, 1 = wavering, 2 = steady): clips from
## lively to still (measured motion energy: idle_2 26, idle_3 23.5, idle 18,
## idle_4 3.9 deg/s) and their playback rate.
const IDLE_BY_MORALE := [["sword_and_shield_idle_4"], ["sword_and_shield_idle", "sword_and_shield_idle_4"],
	["sword_and_shield_idle_2", "sword_and_shield_idle_3", "sword_and_shield_idle"]]
const IDLE_RATE_BY_MORALE := [Vector2(0.6, 0.7), Vector2(0.8, 0.9), Vector2(0.95, 1.15)]
var _morale_level := 2
const IDLE := ["sword_and_shield_idle", "sword_and_shield_idle_2", "sword_and_shield_idle_3", "sword_and_shield_idle_4"]
## walk_2 is a BACKWARDS walk (measured: its planted foot moves the other way,
## tools/probe_walk_contact.gd): it is the backing-off clip, never a march.
const WALK := ["sword_and_shield_walk"]
const BACK_WALK := "sword_and_shield_walk_2"
const ATTACK := {
	"dao": ["sword_and_shield_slash", "sword_and_shield_slash_3", "sword_and_shield_attack_2", "sword_and_shield_attack_4", "sword_and_shield_slash_5"],
	"spear": ["Upward_Thrust"],
	"bow": ["Shooting_Arrow"],
	"": ["sword_and_shield_attack_3"],
}
const HIT := ["sword_and_shield_impact", "sword_and_shield_impact_2", "sword_and_shield_impact_3"]
const DEATH := ["sword_and_shield_death", "sword_and_shield_death_2"]
const BLEND: float = 0.18
## The arrow clip loops several shots; one volley is this long.
const VOLLEY_TIME: float = 3.2

static var _lib_ready := false
static var _mats: Dictionary = {}

var _soldiers: Array = [] # {holder, ap, rng}
var _weapon: String = "dao"
var _moving := false
var _dead := false
var _facing := Vector3(0, 0, -1)
## The blow or the volley lands (local point): the view flinches the target
## and shows the impact there.
signal struck(at_local: Vector3)

const Sortie = preload("res://scripts/visual/civ3d/civ_sortie.gd")
const Fx = preload("res://scripts/visual/civ3d/civ_battle_fx.gd")
## Melee sortie: the line spreads, jogs past its hex edge toward the target,
## strikes, U-turns, jogs back past home and U-turns onto it facing the front
## (presentation offset only; the unit's hex never changes).
const HEX_STEP: float = 7.9       # 3D units between hex centres
const REACH_MAX: float = 4.0
const CONTACT_GAP: float = 4.9    # stop this short of the enemy centre: face to face with its front rank
const SPREAD: float = 0.55        # extra gap between men at the strike point (x home gap)
const JOG_CLIP_SPEED: float = 2.0 # upper limit of the walk clip's rate (a jog)
const JOG_SPEED: float = 1.2      # outbound ground speed, x figure height per s
const BACK_SPEED: float = 0.7     # backing off, x figure height per s
## Measured ground speed of each walk clip at rate 1 (x figure height per s,
## tools/probe_walk_stride.gd): clip rate = ground speed / this, feet planted.
const WALK_STRIDE := {"sword_and_shield_walk": 0.66, "sword_and_shield_walk_2": 0.52}
const JOG_ACC: float = 0.45
const JOG_DEC: float = 0.55
const STRIKE_DWELL: float = 1.15  # s at the strike point
const TURN_R: float = 0.6         # U-turn radius (units)
const BEHIND: float = 0.9         # return U-turn runs this far behind home
const YAW_RATE: float = 10.0
## Bow: the arrow leaves the string this far into Shooting_Arrow (measured:
## tools/probe_bow_release.gd); it flies this long.
const BOW_RELEASE: float = 2.3
const ARROW_FLIGHT: float = 1.15
var _height := 2.2
var _sortie := false
var _sortie_clock := 0.0
var _sortie_end := 0.0
var _struck_sent := false

static func supports(cls: String) -> bool:
	return LOADOUT.has(cls)

static func _prepare_library() -> void:
	if _lib_ready:
		return
	for n in MOCAP.get_animation_list():
		var a: Animation = MOCAP.get_animation(n)
		a.loop_mode = Animation.LOOP_LINEAR if (n in IDLE or n in WALK or n == BACK_WALK) else Animation.LOOP_NONE
	_lib_ready = true

## count soldiers, `height` in 3D units, facing = world direction they look.
func setup(cls: String, faction: String, count: int, height: float, facing: Vector3, seed_value: int) -> void:
	_prepare_library()
	var kit: Array = LOADOUT.get(cls, ["dao", ""])
	_weapon = kit[0]
	_height = height
	var yaw: float = atan2(-facing.x, -facing.z) # the model looks down -Z
	_facing = Vector3(facing.x, 0.0, facing.z).normalized()
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var scouts: bool = cls in ["scout", "scouts"]
	for i in range(count):
		var holder := Node3D.new()
		holder.rotation.y = yaw + rng.randf_range(-0.12, 0.12)
		add_child(holder)
		if scouts and i % 3 == 2:
			_add_dog(i, holder, height, rng)
			continue
		var model: Node3D = SOLDIER.instantiate()
		var h: float = height * rng.randf_range(0.95, 1.05)
		model.scale = Vector3.ONE * h
		model.position.y = 0.5 * h # model feet sit at y = -0.5
		holder.add_child(model)
		var sk: Skeleton3D = _find(model)
		var militia: bool = kit[1] == "hat"
		_skin(model, faction, rng, 0.85 if militia else 0.0)
		# militia carry whatever they own: a spear or a dao, man by man
		var w: String = kit[0]
		if w == "mixed":
			w = "spear" if rng.randf() < 0.55 else "dao"
		if w == "bow":
			_attach(sk, Rig.BONE["l_hand"], "bow") # the bow is held in the left fist
		elif w != "":
			_attach(sk, Rig.BONE["r_hand"], w)
		if kit[1] == "shield":
			_attach(sk, Rig.BONE["l_wrist"], "shield")
		elif militia:
			_attach(sk, Rig.BONE["head"], "hat")
		var ap := AnimationPlayer.new()
		model.add_child(ap)
		ap.root_node = NodePath("..")
		ap.add_animation_library("", MOCAP)
		ap.speed_scale = rng.randf_range(0.9, 1.1)
		ap.animation_finished.connect(_on_finished.bind(i))
		var pool: Array = IDLE_BY_MORALE[_morale_level]
		_soldiers.append({"holder": holder, "ap": ap, "rng": rng, "idle": pool[rng.randi() % pool.size()], "w": w, "yaw_home": holder.rotation.y})
		_idle(i, true)

func _add_dog(i: int, holder: Node3D, height: float, rng: RandomNumberGenerator) -> void:
	if _dog_proto == null:
		var doc := GLTFDocument.new()
		var st := GLTFState.new()
		doc.append_from_file(ProjectSettings.globalize_path(DOG_GLB), st)
		_dog_proto = doc.generate_scene(st)
	holder.rotation.y += PI # the dog looks down +Z, the men down -Z
	var model: Node3D = _dog_proto.duplicate()
	var k: float = height * DOG_SCALE_OF_MAN * rng.randf_range(0.92, 1.06)
	model.scale = Vector3.ONE * k
	model.position.y = 0.44 * k # paws at y = -0.44
	holder.add_child(model)
	for mi in _meshes(model):
		(mi as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	var sk: Skeleton3D = _find(model)
	var ap := AnimationPlayer.new()
	model.add_child(ap)
	ap.root_node = NodePath("..")
	ap.add_animation_library("", DogRig.library(sk, str(model.get_path_to(sk))))
	_soldiers.append({"holder": holder, "ap": ap, "rng": rng, "idle": "idle", "w": "dog", "dog": true, "k": k, "yaw_home": holder.rotation.y})
	_idle(i, true)

func _is_dog(i: int) -> bool:
	return bool(_soldiers[i].get("dog", false))

## Yaw that makes member i look along `dir` (men look down -Z, dogs down +Z).
func _yaw_for(i: int, dir: Vector3) -> float:
	return atan2(-dir.x, -dir.z) + (PI if _is_dog(i) else 0.0)

func _walk_clip(i: int) -> String:
	return "trot" if _is_dog(i) else WALK[i % WALK.size()]

## Ground speed of member i's walk / trot at clip rate 1 (units / s).
func _stride(i: int) -> float:
	if _is_dog(i):
		return float(DogRig.GAIT_SPEED["trot"]) * float(_soldiers[i]["k"])
	return float(WALK_STRIDE.get(WALK[i % WALK.size()], 0.62)) * _height

## Morale level from the board (0 low, 1 wavering, 2 steady): idles get calmer.
func set_morale(level: int) -> void:
	level = clampi(level, 0, 2)
	if level == _morale_level:
		return
	_morale_level = level
	for i in range(_soldiers.size()):
		var s: Dictionary = _soldiers[i]
		if not _is_dog(i):
			var pool: Array = IDLE_BY_MORALE[level]
			s["idle"] = pool[(s["rng"] as RandomNumberGenerator).randi() % pool.size()]
		if not _moving and not s.has("sortie") and not bool(s.get("down", false)):
			_idle(i, false)

## Local positions (relative to this node) of each soldier's feet.
func place(points: Array) -> void:
	for i in range(mini(points.size(), _soldiers.size())):
		_soldiers[i]["home"] = points[i]
		if not _soldiers[i].has("sortie"): # a sortie owns the position until home
			(_soldiers[i]["holder"] as Node3D).position = points[i]

## Animation rate LOD from the view: 0 = every frame, else updates per second
## (manual advance, phase-staggered so formations do not all tick together).
var _rate := 0.0
var _acc := 0.0

func set_rate(hz: float) -> void:
	if is_equal_approx(hz, _rate):
		return
	_rate = hz
	_acc = randf() / maxf(hz, 1.0)
	for s in _soldiers:
		(s["ap"] as AnimationPlayer).callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL if hz > 0.0 else AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_IDLE

func _process(delta: float) -> void:
	if _sortie:
		_advance_sortie(delta)
	if _turning:
		_turn(delta)
	if _rate <= 0.0:
		return
	_acc += delta
	if _acc < 1.0 / _rate:
		return
	for s in _soldiers:
		var ap: AnimationPlayer = s["ap"]
		if ap.active:
			ap.advance(_acc)
	_acc = 0.0

## Distance LOD from the view: far away the figures freeze in their current
## pose and stop casting shadows (the badge carries the read).
func set_far(far: bool) -> void:
	for s in _soldiers:
		(s["ap"] as AnimationPlayer).active = not far
		for mi in _meshes(s["holder"]):
			(mi as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF if far else GeometryInstance3D.SHADOW_CASTING_SETTING_ON

func set_moving(m: bool) -> void:
	if m == _moving or _dead:
		return
	_moving = m
	for i in range(_soldiers.size()):
		if bool(_soldiers[i].get("down", false)) or _soldiers[i].has("sortie"):
			continue
		if m:
			var ap: AnimationPlayer = _soldiers[i]["ap"]
			ap.play(_walk_clip(i), BLEND)
			ap.seek(randf() * 0.4)
		else:
			_idle(i, false)

## Board speed in world px / s while moving: the walk clip runs at the rate
## that matches it (feet planted, no gliding), up to a jog.
const PX_TO_UNITS: float = 0.1875          # the view's world px -> 3D units

func set_speed(px_per_s: float) -> void:
	for i in range(_soldiers.size()):
		var s: Dictionary = _soldiers[i]
		if _moving and not s.has("sortie") and not bool(s.get("down", false)):
			var stride: float = _stride(i)
			(s["ap"] as AnimationPlayer).speed_scale = clampf(px_per_s * PX_TO_UNITS / stride, 0.8, JOG_CLIP_SPEED * 1.25)

## Marching: the men face where they are going (local direction from the
## view; ZERO = halted, face the front again). Turns are smooth.
var _march_dir := Vector3.ZERO
var _turning := false

func set_heading(dir: Vector3) -> void:
	_march_dir = Vector3(dir.x, 0.0, dir.z)
	_turning = true

func _turn(dt: float) -> void:
	var k: float = 1.0 - exp(-dt * 6.0)
	var marching: bool = _march_dir.length() > 0.1
	var settled := true
	for i in range(_soldiers.size()):
		var s: Dictionary = _soldiers[i]
		if bool(s.get("down", false)) or s.has("sortie"):
			continue
		var h: Node3D = s["holder"]
		var target: float = _yaw_for(i, _march_dir) if marching else float(s["yaw_home"])
		h.rotation.y = lerp_angle(h.rotation.y, target, k)
		if absf(angle_difference(h.rotation.y, target)) > 0.01:
			settled = false
	if settled and not marching:
		_turning = false

## `target` = vector to the enemy (world space, from this unit); zero = straight ahead.
## Melee men sortie out and back; archers turn, loose one volley and turn back.
func play_attack(target: Vector3 = Vector3.ZERO) -> void:
	if _dead or _sortie:
		return
	var v: Vector3 = _facing * HEX_STEP
	if target.length() > 0.1:
		v = global_transform.basis.inverse() * target if is_inside_tree() else target
	v.y = 0.0
	if not is_inside_tree():
		_one_shot([], 0.0) # not on the board yet: strike in place
		return
	var archers: Array = []
	var melee: Array = []
	for i in range(_soldiers.size()):
		var s: Dictionary = _soldiers[i]
		if bool(s.get("down", false)):
			continue
		if s["w"] == "bow":
			archers.append(i)
		else:
			melee.append(i)
	_struck_sent = false
	_sortie_clock = 0.0
	_sortie_end = 0.0
	if not archers.is_empty():
		_start_volley(archers, v)
	if not melee.is_empty():
		_start_sortie(melee, v)
	_sortie = true

func _start_volley(idx: Array, v: Vector3) -> void:
	var aim: float = atan2(-v.x, -v.z)
	for i in idx:
		var s: Dictionary = _soldiers[i]
		var rng: RandomNumberGenerator = s["rng"]
		var delay: float = rng.randf_range(0.0, 0.35)
		var flight: float = ARROW_FLIGHT * rng.randf_range(0.9, 1.1)
		# where this arrow comes down: somewhere on the target hex
		var r: float = sqrt(rng.randf()) * 2.6
		var th: float = rng.randf() * TAU
		s["sortie"] = {"kind": "bow", "delay": delay, "phase": 0, "aim": aim, "yaw_home": (s["holder"] as Node3D).rotation.y,
			"to": v + Vector3(cos(th) * r, 0.0, sin(th) * r), "flight": flight, "fired": false, "land": INF}
		_sortie_end = maxf(_sortie_end, delay + VOLLEY_TIME + 0.8)
		_sortie_end = maxf(_sortie_end, delay + BOW_RELEASE + flight + 0.1)

func _start_sortie(idx: Array, v: Vector3) -> void:
	var reach: float = clampf(v.length() - CONTACT_GAP, 1.5, REACH_MAX)
	var f: Vector3 = v.normalized()
	var l: Vector3 = Vector3.UP.cross(f).normalized()
	var front: Vector3 = _facing
	var front_l: Vector3 = Vector3.UP.cross(front).normalized()
	var vj: float = JOG_SPEED * _height
	var mean := Vector3.ZERO
	for i in idx:
		mean += _home(i)
	mean /= float(idx.size())
	for i in idx:
		var s: Dictionary = _soldiers[i]
		var rng: RandomNumberGenerator = s["rng"]
		var home: Vector3 = _home(i)
		var off: float = (home - mean).dot(l)
		var side: float = signf(off) if absf(off) > 0.1 else (1.0 if rng.randf() < 0.5 else -1.0)
		var lat: float = off * SPREAD + rng.randf_range(-0.3, 0.3)
		var my_reach: float = reach * rng.randf_range(0.9, 1.05)
		var strike: Vector3 = home + f * my_reach + l * lat
		var out := Sortie.out_path(home, f, l, my_reach, lat, 0.0)
		# backing off: the same line in reverse, still facing the enemy
		var back := out.duplicate()
		back.reverse()
		var cum_o := Sortie.cumulative(out)
		var cum_b := Sortie.cumulative(back)
		var len_o: float = cum_o[cum_o.size() - 1]
		var len_b: float = cum_b[cum_b.size() - 1]
		var sp := {"kind": "melee", "delay": rng.randf_range(0.0, 0.3), "phase": 0, "f": f,
			"out": out, "cum_o": cum_o, "len_o": len_o, "t_out": Sortie.duration(len_o, vj, JOG_ACC, JOG_DEC),
			"back": back, "cum_b": cum_b, "len_b": len_b, "t_back": Sortie.duration(len_b, BACK_SPEED * _height, JOG_ACC, JOG_DEC)}
		s["sortie"] = sp
		_sortie_end = maxf(_sortie_end, float(sp["delay"]) + float(sp["t_out"]) + STRIKE_DWELL + float(sp["t_back"]))

func _home(i: int) -> Vector3:
	var s: Dictionary = _soldiers[i]
	return s.get("home", (s["holder"] as Node3D).position)

func _advance_sortie(dt: float) -> void:
	_sortie_clock += dt
	var k: float = 1.0 - exp(-dt * YAW_RATE)
	var vj: float = JOG_SPEED * _height
	for i in range(_soldiers.size()):
		var s: Dictionary = _soldiers[i]
		if not s.has("sortie") or bool(s.get("down", false)):
			continue
		var sp: Dictionary = s["sortie"]
		var holder: Node3D = s["holder"]
		var ap: AnimationPlayer = s["ap"]
		var t: float = _sortie_clock - float(sp["delay"])
		if t < 0.0:
			continue
		if sp["kind"] == "bow":
			_advance_archer(i, s, sp, t, k)
			continue
		var t1: float = sp["t_out"]
		var t2: float = t1 + STRIKE_DWELL
		var t3: float = t2 + float(sp["t_back"])
		if t < t1 or (t >= t2 and t < t3):
			var outbound: bool = t < t1
			var tl: float = t if outbound else t - t2
			var length: float = sp["len_o"] if outbound else sp["len_b"]
			var v: float = vj if outbound else BACK_SPEED * _height
			var d: float = Sortie.dist_at(tl, length, v, JOG_ACC, JOG_DEC)
			var at: Array = Sortie.at(sp["out"] if outbound else sp["back"], sp["cum_o"] if outbound else sp["cum_b"], d)
			holder.position = at[0]
			var tan: Vector3 = at[1]
			var f_back: Vector3 = sp["f"]
			var dog: bool = _is_dog(i)
			if outbound or dog:
				# dogs trot back facing the way they go (they do not back off)
				holder.rotation.y = lerp_angle(holder.rotation.y, _yaw_for(i, tan), k)
			else:
				# backing off: keep facing the enemy, settle onto the front at home
				var face: Vector3 = f_back.lerp(_facing, clampf(d / maxf(length, 0.01) * 1.5 - 0.5, 0.0, 1.0))
				holder.rotation.y = lerp_angle(holder.rotation.y, _yaw_for(i, face), k)
			var clip: String = _walk_clip(i) if (outbound or dog) else BACK_WALK
			if dog and v < DOG_WALK_BELOW * float(_soldiers[i]["k"]):
				clip = "walk" # slow going: a trot this slow floats
			var want: int = 1 if outbound else 3
			if int(sp["phase"]) != want:
				sp["phase"] = want
				ap.play(clip, BLEND) # backing off: the backwards-walk clip, played forward
			var v_now: float = Sortie.speed_at(tl, length, v, JOG_ACC, JOG_DEC)
			var stride: float = DogRig.GAIT_SPEED[clip] * float(_soldiers[i]["k"]) if dog else float(WALK_STRIDE.get(clip, 0.62)) * _height
			ap.speed_scale = clampf(v_now / stride, 0.3, JOG_CLIP_SPEED * 1.25)
		elif t < t2:
			var f: Vector3 = sp["f"]
			holder.rotation.y = lerp_angle(holder.rotation.y, _yaw_for(i, f), k)
			if int(sp["phase"]) != 2 and _is_dog(i):
				sp["phase"] = 2
				ap.speed_scale = 1.3
				ap.play("idle", 0.2) # the dog holds at the line, alert
			elif int(sp["phase"]) != 2:
				sp["phase"] = 2
				var own: Array = ATTACK.get(s["w"], ATTACK["dao"])
				ap.speed_scale = (s["rng"] as RandomNumberGenerator).randf_range(1.0, 1.15)
				ap.play(own[(s["rng"] as RandomNumberGenerator).randi() % own.size()], 0.12)
			if not _struck_sent and t - t1 > 0.35:
				_struck_sent = true
				struck.emit(holder.position + f * 1.2)
		else:
			holder.position = _home(i)
			s.erase("sortie")
			ap.speed_scale = (s["rng"] as RandomNumberGenerator).randf_range(0.9, 1.1)
			_settle(i)
	if _sortie_clock >= _sortie_end:
		_end_sortie()

func _advance_archer(i: int, s: Dictionary, sp: Dictionary, t: float, k: float) -> void:
	var holder: Node3D = s["holder"]
	var ap: AnimationPlayer = s["ap"]
	var aiming: bool = t < VOLLEY_TIME
	holder.rotation.y = lerp_angle(holder.rotation.y, float(sp["aim"]) if aiming else float(sp["yaw_home"]), k * 0.6)
	if int(sp["phase"]) == 0:
		sp["phase"] = 1
		ap.speed_scale = 1.0 # the release time is measured at clip speed 1
		ap.play("Shooting_Arrow", BLEND)
	if not bool(sp["fired"]) and t >= BOW_RELEASE:
		sp["fired"] = true
		var dir: Vector3 = (sp["to"] as Vector3 - holder.position).normalized()
		var from: Vector3 = holder.position + Vector3(0.0, 0.78 * _height, 0.0) + dir * 0.25 * _height
		Fx.arrow(self, from, sp["to"], sp["flight"], _height * 0.7)
		sp["land"] = _sortie_clock + float(sp["flight"])
	if not _struck_sent and _sortie_clock >= float(sp["land"]):
		_struck_sent = true
		struck.emit(sp["to"])
	if int(sp["phase"]) == 1 and t >= VOLLEY_TIME:
		sp["phase"] = 2
		ap.speed_scale = (s["rng"] as RandomNumberGenerator).randf_range(0.9, 1.1)
		_settle(i)
	if t >= VOLLEY_TIME + 0.8 and _sortie_clock >= float(sp["land"]):
		holder.rotation.y = sp["yaw_home"]
		s.erase("sortie")

func _end_sortie() -> void:
	_sortie = false
	for i in range(_soldiers.size()):
		var s: Dictionary = _soldiers[i]
		if s.has("sortie"):
			if s["sortie"]["kind"] == "bow":
				(s["holder"] as Node3D).rotation.y = s["sortie"]["yaw_home"]
			s.erase("sortie")
			if not bool(s.get("down", false)):
				(s["holder"] as Node3D).position = _home(i)
				_settle(i)
	if not _struck_sent:
		_struck_sent = true
		struck.emit(_facing * HEX_STEP)

## Back to the ranks: walk if the unit is marching, else idle.
func _settle(i: int) -> void:
	if bool(_soldiers[i].get("down", false)):
		return
	if _moving:
		(_soldiers[i]["ap"] as AnimationPlayer).play(_walk_clip(i), BLEND)
	else:
		_idle(i, false)

## Unit strength (soldier_count / max_count, read from the board): men fall,
## front rank first, until the figures left match it; they stay down. The
## first call only lays out the dead (no animation).
var _strength_set := false

func set_strength(frac: float) -> void:
	if _dead:
		return
	var n: int = _soldiers.size()
	var want: int = n if frac >= 0.999 else clampi(roundi(float(n) * frac), 1 if frac > 0.0 else 0, n)
	var alive: Array = []
	for i in range(n):
		if not bool(_soldiers[i].get("down", false)):
			alive.append(i)
	var instant: bool = not _strength_set
	_strength_set = true
	if alive.size() > want:
		# front rank first (furthest along the facing), a little shuffled
		var keyed: Array = []
		for i in alive:
			# front rank first, men before dogs
			keyed.append([_home(i).dot(_facing) + randf_range(-0.6, 0.6) - (100.0 if _is_dog(i) else 0.0), i])
		keyed.sort_custom(func(a, b): return a[0] > b[0])
		for j in range(alive.size() - want):
			_fall(keyed[j][1], instant)
	elif alive.size() < want:
		for i in range(n):
			if alive.size() >= want:
				break
			if bool(_soldiers[i].get("down", false)):
				_soldiers[i]["down"] = false
				(_soldiers[i]["holder"] as Node3D).position = _home(i)
				(_soldiers[i]["holder"] as Node3D).rotation.z = 0.0
				(_soldiers[i]["ap"] as AnimationPlayer).active = true
				_settle(i)
				alive.append(i)

func _fall(i: int, instant: bool) -> void:
	var s: Dictionary = _soldiers[i]
	s["down"] = true
	s.erase("sortie")
	if _is_dog(i):
		# no death clip for the dog: it slumps onto its side and lies still
		var h: Node3D = s["holder"]
		(s["ap"] as AnimationPlayer).active = false
		if instant or not is_inside_tree():
			h.rotation.z = 1.45
		else:
			create_tween().tween_property(h, "rotation:z", 1.45, 0.5).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		return
	var ap: AnimationPlayer = s["ap"]
	var clip: String = DEATH[(s["rng"] as RandomNumberGenerator).randi() % DEATH.size()]
	ap.speed_scale = 1.0
	ap.play(clip, 0.0 if instant else BLEND)
	if instant:
		ap.seek(ap.current_animation_length - 0.01, true)

func play_hit() -> void:
	_one_shot(HIT, 0.15)

func play_death() -> void:
	_dead = true
	_sortie = false
	for s in _soldiers:
		s.erase("sortie")
	for i in range(_soldiers.size()):
		if _is_dog(i) and not bool(_soldiers[i].get("down", false)):
			_fall(i, false)
	_one_shot(DEATH, 0.3)

func _one_shot(pool: Array, stagger: float) -> void:
	for i in range(_soldiers.size()):
		var s: Dictionary = _soldiers[i]
		if bool(s.get("down", false)) or s.has("sortie") or bool(s.get("dog", false)):
			continue # the fallen stay down; a sortie owns its clips; dogs have none of these clips
		var own: Array = pool if not pool.is_empty() else ATTACK.get(s["w"], ATTACK["dao"])
		var clip: String = own[(s["rng"] as RandomNumberGenerator).randi() % own.size()]
		var ap: AnimationPlayer = s["ap"]
		var delay: float = (s["rng"] as RandomNumberGenerator).randf_range(0.0, stagger)
		var idx := i
		if not is_inside_tree():
			ap.play(clip, BLEND)
			continue
		var tree: SceneTree = get_tree()
		tree.create_timer(delay).timeout.connect(func():
			if not is_instance_valid(ap) or not ap.is_inside_tree():
				return
			if bool(s.get("down", false)) or s.has("sortie"):
				return # fell (or sortied) since this was scheduled: keep that clip
			ap.play(clip, BLEND)
			if clip == "Shooting_Arrow":
				# one volley, then back to the ranks
				tree.create_timer(VOLLEY_TIME).timeout.connect(func():
					if is_instance_valid(ap) and ap.is_inside_tree() and ap.current_animation == "Shooting_Arrow" and not _dead:
						_on_finished(&"", idx)))

func _on_finished(_anim: StringName, i: int) -> void:
	if _dead or bool(_soldiers[i].get("down", false)) or _soldiers[i].has("sortie"):
		return # the fallen stay down; the sortie owns the clips until home
	_settle(i)

func _idle(i: int, random_phase: bool) -> void:
	var s: Dictionary = _soldiers[i]
	var ap: AnimationPlayer = s["ap"]
	ap.play(s["idle"], 0.0 if random_phase else BLEND)
	var rate: Vector2 = IDLE_RATE_BY_MORALE[_morale_level]
	ap.speed_scale = (s["rng"] as RandomNumberGenerator).randf_range(rate.x, rate.y)
	if random_phase:
		ap.seek((s["rng"] as RandomNumberGenerator).randf() * ap.current_animation_length, true)

func _attach(sk: Skeleton3D, bone: String, kind: String) -> void:
	var att := BoneAttachment3D.new()
	att.bone_name = bone
	sk.add_child(att)
	var w := MeshInstance3D.new()
	w.mesh = Rig.weapon_mesh(kind)
	w.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	att.add_child(w)

func _skin(model: Node, faction: String, rng: RandomNumberGenerator, drab: float = 0.0) -> void:
	for mi in _meshes(model):
		var src: Material = mi.mesh.surface_get_material(0)
		var key: String = faction + str(src.get_instance_id()) + ("|drab" if drab > 0.0 else "")
		if not _mats.has(key):
			var m := ShaderMaterial.new()
			m.shader = SkinShader
			m.set_shader_parameter("albedo_tex", (src as BaseMaterial3D).albedo_texture if src is BaseMaterial3D else null)
			m.set_shader_parameter("faction_hue", 0.6 if faction == "blue" else 0.0)
			m.set_shader_parameter("drab", drab)
			_mats[key] = m
		mi.material_override = _mats[key]
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		mi.set_instance_shader_parameter("cloth_v", rng.randf_range(0.78, 1.12))
		mi.set_instance_shader_parameter("skin_v", rng.randf_range(0.8, 1.08))

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
