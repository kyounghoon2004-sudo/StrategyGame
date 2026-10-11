extends RefCounted

## CIV3D horse gaits (VISUAL ONLY) for assets/units/cavalry_v0/horse_rigged.glb
## (tools/rig_horse_blender.py). The horse faces +Z, its left is +X, Y up.
##
## Every joint motion is a swing S defined in HORSE-MODEL space (legs flex
## about the lateral X axis; -X rotation swings a leg FORWARD). It becomes the
## bone's local pose with  local = parent_rest^-1 * S * rest,  so Blender's
## bone rolls never matter. S is RELATIVE to the parent's motion (a joint's own
## flexion), so a leg chain lists per-joint increments.
##
## Clips: idle (4 s), walk (4-beat), trot (diagonal pairs), gallop (transverse).

## [cycle s, upper swing deg, lower flex deg, hoof flex deg, duty, phases LF RF LH RH,
##  body bob, body pitch deg, pitch / bob harmonics (1 or 2), neck nod deg]
const GAITS := {
	"walk": [1.1, 18.0, 38.0, 40.0, 0.62, [0.25, 0.75, 0.0, 0.5], 0.006, 2.0, 2, 6.0],
	"trot": [0.66, 24.0, 58.0, 55.0, 0.45, [0.0, 0.5, 0.5, 0.0], 0.016, 2.5, 2, 4.0],
	"gallop": [0.5, 30.0, 52.0, 45.0, 0.38, [0.40, 0.52, 0.0, 0.12], 0.024, 5.0, 1, 10.0],
}
const LEGS := [["f", "L"], ["f", "R"], ["h", "L"], ["h", "R"]]
## Ground speed of each gait at clip rate 1, in model units / s: how far a
## planted foot is pushed back over its stance (tools/probe_stance_dir.gd;
## horse 0.37 / 1.03 / 2.05, dog 0.38 / 1.08 / 2.14).
const GAIT_SPEED := {"walk": 0.37, "trot": 1.05, "gallop": 2.1}
const KEYS_PER_CYCLE := 24

static var _libs: Dictionary = {}

## Library for this skeleton (rest data is read from it). `sk_path` is the
## Skeleton3D path relative to the AnimationPlayer's root node.
static func library(sk: Skeleton3D, sk_path: String) -> AnimationLibrary:
	if _libs.has(sk_path):
		return _libs[sk_path]
	var lib := AnimationLibrary.new()
	for g in GAITS.keys():
		lib.add_animation(g, _gait(sk, sk_path, g))
	lib.add_animation("idle", _idle(sk, sk_path))
	_libs[sk_path] = lib
	return lib

static func _local(sk: Skeleton3D, bone: String, s: Quaternion) -> Quaternion:
	var i := sk.find_bone(bone)
	var p := sk.get_bone_parent(i)
	var g := Quaternion(sk.get_bone_global_rest(i).basis.orthonormalized())
	var gp := Quaternion(sk.get_bone_global_rest(p).basis.orthonormalized()) if p >= 0 else Quaternion.IDENTITY
	return (gp.inverse() * s * g).normalized()

static func _rx(deg: float) -> Quaternion:
	return Quaternion(Vector3.RIGHT, deg_to_rad(deg))

static func _new_clip(sk: Skeleton3D, sk_path: String, length: float, bones: Array) -> Array:
	var a := Animation.new()
	a.length = length
	a.loop_mode = Animation.LOOP_LINEAR
	var tracks := {}
	for b in bones:
		var t := a.add_track(Animation.TYPE_ROTATION_3D)
		a.track_set_path(t, NodePath("%s:%s" % [sk_path, b]))
		tracks[b] = t
	var pt := a.add_track(Animation.TYPE_POSITION_3D)
	a.track_set_path(pt, NodePath("%s:root" % sk_path))
	tracks["@root_pos"] = pt
	return [a, tracks]

static func _gait(sk: Skeleton3D, sk_path: String, gait: String) -> Animation:
	var g: Array = GAITS[gait]
	var cycle: float = g[0]
	var bones: Array = ["hips", "neck1", "head", "tail1", "tail2"]
	for leg in LEGS:
		var pre: String = leg[0]
		var side: String = leg[1]
		if pre == "f":
			bones.append_array(["f_upper." + side, "f_fore." + side, "f_cannon." + side, "f_hoof." + side])
		else:
			bones.append_array(["h_thigh." + side, "h_gaskin." + side, "h_cannon." + side, "h_hoof." + side])
	var made: Array = _new_clip(sk, sk_path, cycle, bones)
	var a: Animation = made[0]
	var tr: Dictionary = made[1]
	var root_rest: Vector3 = sk.get_bone_rest(sk.find_bone("root")).origin
	for k in range(KEYS_PER_CYCLE + 1):
		var u: float = float(k) / KEYS_PER_CYCLE
		var t: float = u * cycle
		var h: float = float(g[8])
		var pitch: float = float(g[7]) * sin(TAU * u * h)
		var bob: float = float(g[6]) * cos(TAU * u * h)
		a.rotation_track_insert_key(tr["hips"], t, _local(sk, "hips", _rx(pitch)))
		a.rotation_track_insert_key(tr["neck1"], t, _local(sk, "neck1", _rx(-pitch * 0.8 + float(g[9]) * sin(TAU * u * h + 0.6))))
		a.rotation_track_insert_key(tr["head"], t, _local(sk, "head", _rx(float(g[9]) * 0.4 * sin(TAU * u * h + 1.2))))
		# +X swings the hanging tail back and up (it streams behind at speed)
		var tail_lift: float = 30.0 if gait == "gallop" else (12.0 if gait == "trot" else 0.0)
		var sway := Quaternion(Vector3.UP, deg_to_rad(8.0 * sin(TAU * u)))
		a.rotation_track_insert_key(tr["tail1"], t, _local(sk, "tail1", sway * _rx(tail_lift)))
		a.rotation_track_insert_key(tr["tail2"], t, _local(sk, "tail2", Quaternion(Vector3.UP, deg_to_rad(12.0 * sin(TAU * u - 0.8))) * _rx(tail_lift * 0.6)))
		a.position_track_insert_key(tr["@root_pos"], t, root_rest + Vector3(0.0, bob, 0.0))
		for li in range(4):
			var pre: String = LEGS[li][0]
			var side: String = LEGS[li][1]
			# phases are footfall times: a later phase lands later in the cycle
			var p: float = fposmod(u - float(g[5][li]), 1.0)
			var duty: float = g[4]
			var A: float = g[1]
			var swing_deg: float
			var lift: float = 0.0
			if p < duty:
				swing_deg = A * (1.0 - 2.0 * p / duty) # planted: forward -> back
			else:
				var q: float = (p - duty) / (1.0 - duty)
				swing_deg = -A + 2.0 * A * (0.5 - 0.5 * cos(PI * q)) # in the air: back -> forward
				lift = sin(PI * q)
			var F: float = g[2] * lift
			var H: float = g[3] * lift
			if pre == "f":
				a.rotation_track_insert_key(tr["f_upper." + side], t, _local(sk, "f_upper." + side, _rx(-swing_deg)))
				# elbow brings the forearm a little forward, the knee folds the cannon back
				a.rotation_track_insert_key(tr["f_fore." + side], t, _local(sk, "f_fore." + side, _rx(-0.3 * F)))
				a.rotation_track_insert_key(tr["f_cannon." + side], t, _local(sk, "f_cannon." + side, _rx(F)))
				a.rotation_track_insert_key(tr["f_hoof." + side], t, _local(sk, "f_hoof." + side, _rx(0.6 * H)))
			else:
				var thigh: float = -swing_deg * 0.8
				a.rotation_track_insert_key(tr["h_thigh." + side], t, _local(sk, "h_thigh." + side, _rx(thigh)))
				# stifle swings the gaskin forward, the hock folds the cannon back
				a.rotation_track_insert_key(tr["h_gaskin." + side], t, _local(sk, "h_gaskin." + side, _rx(-0.5 * F)))
				a.rotation_track_insert_key(tr["h_cannon." + side], t, _local(sk, "h_cannon." + side, _rx(0.9 * F)))
				a.rotation_track_insert_key(tr["h_hoof." + side], t, _local(sk, "h_hoof." + side, _rx(0.6 * H)))
	return a

## Standing: breathing, a slow head drop and lift, tail swish, weight shift.
static func _idle(sk: Skeleton3D, sk_path: String) -> Animation:
	var length := 4.0
	var legs: Array = []
	for leg in LEGS:
		if leg[0] == "f":
			legs.append_array(["f_upper." + leg[1], "f_fore." + leg[1], "f_cannon." + leg[1], "f_hoof." + leg[1]])
		else:
			legs.append_array(["h_thigh." + leg[1], "h_gaskin." + leg[1], "h_cannon." + leg[1], "h_hoof." + leg[1]])
	var made: Array = _new_clip(sk, sk_path, length, ["hips", "spine", "neck1", "head", "tail1", "tail2"] + legs)
	var a: Animation = made[0]
	var tr: Dictionary = made[1]
	var root_rest: Vector3 = sk.get_bone_rest(sk.find_bone("root")).origin
	# legs straight and planted: without these keys a gait's last stride pose
	# lingered when the animal stopped (feet hanging in the air)
	for b in legs:
		a.rotation_track_insert_key(tr[b], 0.0, _local(sk, b, Quaternion.IDENTITY))
		a.rotation_track_insert_key(tr[b], length, _local(sk, b, Quaternion.IDENTITY))
	for k in range(33):
		var u: float = k / 32.0
		var t: float = u * length
		a.rotation_track_insert_key(tr["hips"], t, _local(sk, "hips", Quaternion(Vector3.BACK, deg_to_rad(1.2 * sin(TAU * u)))))
		a.rotation_track_insert_key(tr["spine"], t, _local(sk, "spine", _rx(0.8 * sin(TAU * u * 2.0))))
		a.rotation_track_insert_key(tr["neck1"], t, _local(sk, "neck1", _rx(10.0 * (0.5 - 0.5 * cos(TAU * u))) * Quaternion(Vector3.UP, deg_to_rad(4.0 * sin(TAU * u)))))
		a.rotation_track_insert_key(tr["head"], t, _local(sk, "head", _rx(4.0 * sin(TAU * u + 0.5))))
		a.rotation_track_insert_key(tr["tail1"], t, _local(sk, "tail1", Quaternion(Vector3.UP, deg_to_rad(10.0 * sin(TAU * u * 2.0)))))
		a.rotation_track_insert_key(tr["tail2"], t, _local(sk, "tail2", Quaternion(Vector3.UP, deg_to_rad(16.0 * sin(TAU * u * 2.0 - 0.9)))))
		a.position_track_insert_key(tr["@root_pos"], t, root_rest + Vector3(0.0, 0.002 * sin(TAU * u * 2.0), 0.0))
	return a
