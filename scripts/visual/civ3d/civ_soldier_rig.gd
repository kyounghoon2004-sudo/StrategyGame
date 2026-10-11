extends RefCounted

## CIV3D soldier rig (VISUAL ONLY): code-authored animation clips and weapons
## for assets/units/formation_v0/supplied_soldier.glb.
##
## The rig has 24 joints with IDENTITY rest orientation (axes = model axes),
## the model faces -Z and the character's right is +X. Rotations below are
## Euler degrees (X, Y, Z) applied on top of the rest pose:
##   +X on a limb pointing down swings it FORWARD; on the spine it leans BACK
##   +Z on the right arm raises it outward (left arm: -Z)
##   +Y turns to the character's left
## Model height is 1.0 (feet at y = -0.5).

const BONE := {
	"hips": "joint_12", "spine": "joint_13", "spine2": "joint_10", "chest": "joint_9",
	"neck": "joint_14", "head": "joint_11",
	"r_clav": "joint_8", "r_up": "joint_4", "r_low": "joint_2", "r_wrist": "joint_1", "r_hand": "joint_0",
	"l_clav": "joint_15", "l_up": "joint_18", "l_low": "joint_21", "l_wrist": "joint_22", "l_hand": "joint_23",
	"r_thigh": "joint_7", "r_shin": "joint_6", "r_foot": "joint_5", "r_toe": "joint_3",
	"l_thigh": "joint_17", "l_shin": "joint_16", "l_foot": "joint_19", "l_toe": "joint_20",
}

## Ready stance shared by every clip: arms off the A-pose, weapon hand bent
## forward, knees soft.
const STANCE := {
	"r_up": Vector3(10, 0, -16), "r_low": Vector3(40, -10, 0), "r_wrist": Vector3(-8, 0, 0),
	"l_up": Vector3(6, 0, 18), "l_low": Vector3(26, 8, 0),
	"r_thigh": Vector3(4, 0, 2), "r_shin": Vector3(-7, 0, 0), "r_foot": Vector3(3, 0, 0),
	"l_thigh": Vector3(4, 0, -2), "l_shin": Vector3(-7, 0, 0), "l_foot": Vector3(3, 0, 0),
	"spine": Vector3(-2, 0, 0),
}
const STANCE_SPEAR := {
	"r_up": Vector3(16, 0, -12), "r_low": Vector3(66, -12, 0), "r_wrist": Vector3(6, 0, 0),
	"l_up": Vector3(6, 0, 18), "l_low": Vector3(26, 8, 0),
	"r_thigh": Vector3(4, 0, 2), "r_shin": Vector3(-7, 0, 0), "r_foot": Vector3(3, 0, 0),
	"l_thigh": Vector3(4, 0, -2), "l_shin": Vector3(-7, 0, 0), "l_foot": Vector3(3, 0, 0),
	"spine": Vector3(-2, 0, 0),
}
const HIPS_Y_STANCE: float = -0.006 # knees soft

static var _libs: Dictionary = {}

static func stance_for(weapon: String) -> Dictionary:
	return STANCE_SPEAR if weapon == "spear" else STANCE

## AnimationLibrary with "idle", "march", "attack" for a weapon kind
## ("dao" | "spear"). Tracks target "Skeleton3D:<bone>" relative to the node
## the AnimationPlayer's root_node points at.
static func library(weapon: String, skeleton_path: String) -> AnimationLibrary:
	var key := weapon + "|" + skeleton_path
	if _libs.has(key):
		return _libs[key]
	var lib := AnimationLibrary.new()
	var base: Dictionary = stance_for(weapon)
	lib.add_animation("idle", _clip("idle", 2.4, true, skeleton_path, base, _idle_keys()))
	lib.add_animation("march", _clip("march", 0.9, true, skeleton_path, base, _march_keys()))
	lib.add_animation("attack", _clip("attack", 1.0, false, skeleton_path, base, _spear_attack_keys() if weapon == "spear" else _dao_attack_keys()))
	_libs[key] = lib
	return lib

## keys: Array of [time, {bone: euler_deg offset added to the stance}, hips_offset Vector3]
static func _clip(clip_name: String, length: float, loop: bool, sk: String, base: Dictionary, keys: Array) -> Animation:
	var a := Animation.new()
	a.resource_name = clip_name
	a.length = length
	a.loop_mode = Animation.LOOP_LINEAR if loop else Animation.LOOP_NONE
	var bones: Dictionary = {}
	for b in base.keys():
		bones[b] = true
	for k in keys:
		for b in (k[1] as Dictionary).keys():
			bones[b] = true
	for b in bones.keys():
		var t := a.add_track(Animation.TYPE_ROTATION_3D)
		a.track_set_path(t, NodePath("%s:%s" % [sk, BONE[b]]))
		a.track_set_interpolation_type(t, Animation.INTERPOLATION_CUBIC)
		for k in keys:
			var e: Vector3 = base.get(b, Vector3.ZERO) + (k[1] as Dictionary).get(b, Vector3.ZERO)
			a.rotation_track_insert_key(t, k[0], Quaternion.from_euler(e * (PI / 180.0)))
	var hp := a.add_track(Animation.TYPE_POSITION_3D)
	a.track_set_path(hp, NodePath("%s:%s" % [sk, BONE["hips"]]))
	a.track_set_interpolation_type(hp, Animation.INTERPOLATION_CUBIC)
	for k in keys:
		var off: Vector3 = k[2] if k.size() > 2 else Vector3.ZERO
		a.position_track_insert_key(hp, k[0], Vector3(0.0, 0.008, -0.013) + Vector3(0, HIPS_Y_STANCE, 0) + off)
	return a

static func _idle_keys() -> Array:
	# breathing, a slow weight shift and a glance; loop closes on key 0
	return [
		[0.0, {"chest": Vector3(0, 0, 0), "head": Vector3(0, 0, 0), "hips": Vector3(0, 0, 0)}, Vector3.ZERO],
		[0.6, {"chest": Vector3(-1.5, 0, 0), "head": Vector3(1, 4, 0), "hips": Vector3(0, 0, 1.2), "spine": Vector3(0, 0, -1.2)}, Vector3(0.003, 0.002, 0)],
		[1.2, {"chest": Vector3(0, 0, 0), "head": Vector3(0, 6, 0), "hips": Vector3(0, 0, 0)}, Vector3.ZERO],
		[1.8, {"chest": Vector3(-1.5, 0, 0), "head": Vector3(1, 2, 0), "hips": Vector3(0, 0, -1.2), "spine": Vector3(0, 0, 1.2)}, Vector3(-0.003, 0.002, 0)],
		[2.4, {"chest": Vector3(0, 0, 0), "head": Vector3(0, 0, 0), "hips": Vector3(0, 0, 0)}, Vector3.ZERO],
	]

static func _march_keys() -> Array:
	# one full stride: right foot contact at 0, left at 0.45
	var L := 0.9
	var contact_r := {"r_thigh": Vector3(24, 0, 0), "r_shin": Vector3(-4, 0, 0), "r_foot": Vector3(-14, 0, 0),
		"l_thigh": Vector3(-20, 0, 0), "l_shin": Vector3(-10, 0, 0), "l_foot": Vector3(18, 0, 0),
		"l_up": Vector3(20, 0, 0), "r_up": Vector3(-6, 0, 0), "hips": Vector3(0, -6, 0), "chest": Vector3(0, 8, 0), "spine": Vector3(-5, 0, 0)}
	var pass_r := {"r_thigh": Vector3(2, 0, 0), "r_shin": Vector3(-6, 0, 0), "r_foot": Vector3(2, 0, 0),
		"l_thigh": Vector3(18, 0, 0), "l_shin": Vector3(-48, 0, 0), "l_foot": Vector3(10, 0, 0),
		"l_up": Vector3(0, 0, 0), "r_up": Vector3(0, 0, 0), "hips": Vector3(0, 0, 0), "chest": Vector3(0, 0, 0), "spine": Vector3(-5, 0, 0)}
	var contact_l := _mirror(contact_r)
	# arms swing opposite to the legs; the weapon arm (right) only a little
	contact_l["l_up"] = Vector3(-18, 0, 0)
	contact_l["r_up"] = Vector3(6, 0, 0)
	var pass_l := _mirror(pass_r)
	return [
		[0.0, contact_r, Vector3(0, -0.012, 0)],
		[L * 0.25, pass_r, Vector3(0, 0.006, 0)],
		[L * 0.5, contact_l, Vector3(0, -0.012, 0)],
		[L * 0.75, pass_l, Vector3(0, 0.006, 0)],
		[L, contact_r, Vector3(0, -0.012, 0)],
	]

## Swap left/right limbs and mirror Y / Z turns.
static func _mirror(p: Dictionary) -> Dictionary:
	var out := {}
	for b in p.keys():
		var e: Vector3 = p[b]
		var mb: String = b
		if b.begins_with("r_"):
			mb = "l_" + b.substr(2)
		elif b.begins_with("l_"):
			mb = "r_" + b.substr(2)
		out[mb] = Vector3(e.x, -e.y, -e.z)
	return out

static func _dao_attack_keys() -> Array:
	var ready := {}
	var windup := {"r_up": Vector3(150, 0, 14), "r_low": Vector3(50, 10, 0), "r_wrist": Vector3(40, 0, 0),
		"chest": Vector3(4, 22, 0), "spine": Vector3(0, 10, 0), "l_up": Vector3(25, 0, -10),
		"r_thigh": Vector3(-8, 0, 0), "l_thigh": Vector3(14, 0, 0), "l_shin": Vector3(-14, 0, 0)}
	var strike := {"r_up": Vector3(45, 0, 10), "r_low": Vector3(-30, 0, 0), "r_wrist": Vector3(-25, 0, 0),
		"chest": Vector3(-12, -20, 0), "spine": Vector3(-8, -8, 0), "l_up": Vector3(-25, 0, -15),
		"r_thigh": Vector3(-14, 0, 0), "r_shin": Vector3(-10, 0, 0), "l_thigh": Vector3(30, 0, 0), "l_shin": Vector3(-26, 0, 0), "l_foot": Vector3(-8, 0, 0)}
	var follow := {"r_up": Vector3(10, 0, -18), "r_low": Vector3(-10, 0, 0), "chest": Vector3(-10, -26, 0), "spine": Vector3(-6, -10, 0),
		"l_up": Vector3(-20, 0, -15), "l_thigh": Vector3(26, 0, 0), "l_shin": Vector3(-22, 0, 0), "r_thigh": Vector3(-12, 0, 0)}
	return [
		[0.0, ready, Vector3.ZERO],
		[0.32, windup, Vector3(0, 0.004, 0.01)],
		[0.44, strike, Vector3(0, -0.018, -0.05)],
		[0.56, follow, Vector3(0, -0.016, -0.055)],
		[1.0, ready, Vector3.ZERO],
	]

static func _spear_attack_keys() -> Array:
	var ready := {}
	var draw := {"r_up": Vector3(-28, 0, 10), "r_low": Vector3(26, 0, 0), "r_wrist": Vector3(-62, 0, 0), "l_up": Vector3(48, 0, -6), "l_low": Vector3(30, 0, 0),
		"chest": Vector3(4, 16, 0), "spine": Vector3(2, 6, 0), "r_thigh": Vector3(-6, 0, 0), "l_thigh": Vector3(12, 0, 0), "l_shin": Vector3(-12, 0, 0)}
	var thrust := {"r_up": Vector3(56, 0, 0), "r_low": Vector3(-50, 0, 0), "r_wrist": Vector3(-78, 0, 0), "l_up": Vector3(70, 0, 4), "l_low": Vector3(-10, 0, 0),
		"chest": Vector3(-14, -12, 0), "spine": Vector3(-8, -4, 0),
		"r_thigh": Vector3(-16, 0, 0), "r_shin": Vector3(-8, 0, 0), "l_thigh": Vector3(34, 0, 0), "l_shin": Vector3(-30, 0, 0), "l_foot": Vector3(-6, 0, 0)}
	return [
		[0.0, ready, Vector3.ZERO],
		[0.34, draw, Vector3(0, 0.0, 0.03)],
		[0.48, thrust, Vector3(0, -0.02, -0.07)],
		[0.62, thrust, Vector3(0, -0.02, -0.07)],
		[1.0, ready, Vector3.ZERO],
	]

# ------------------------------------------------------------------ weapons

static var _weapon_meshes: Dictionary = {}

## Weapon mesh in the RIGHT HAND bone's frame (model units, height 1.0).
static func weapon_mesh(kind: String) -> Mesh:
	if _weapon_meshes.has(kind):
		return _weapon_meshes[kind]
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var wood := Color(0.36, 0.24, 0.13)
	var iron := Color(0.62, 0.64, 0.66)
	var cloth := Color(0.62, 0.12, 0.10)
	match kind:
		"spear":
			# shaft through the fist, butt near the ground, leaf blade + tassel on top
			# along the fist's forward axis (-Z): a forearm bent ~90 deg stands it upright
			var dir := Vector3.FORWARD
			_cyl(st, -dir * 0.45, dir * 0.66, 0.012, wood)
			_blade(st, dir * 0.66, dir * 0.82, 0.04, iron)
			_cyl(st, dir * 0.62, dir * 0.645, 0.022, cloth)
		"shield":
			# round lacquered shield on the LEFT wrist: face normal along the wrist's -X
			# (back of the forearm in the Mixamo guard), centred a little toward the elbow
			var c := Vector3(-0.025, 0.05, 0.0)
			_disc(st, c, Vector3.LEFT, 0.15, 0.016, Color(0.30, 0.16, 0.09), Color(0.55, 0.13, 0.10))
			_disc(st, c + Vector3.LEFT * 0.012, Vector3.LEFT, 0.035, 0.02, iron, iron)
		"hat":
			# militia straw hat (conical, wide brim) on the HEAD joint
			var straw := Color(0.70, 0.60, 0.36)
			var apex := Vector3(0.0, 0.19, 0.0)
			var ring: Array = []
			for i in range(14):
				var a := TAU * i / 14.0
				ring.append(Vector3(cos(a) * 0.11, 0.115, sin(a) * 0.11))
			for i in range(14):
				var p0: Vector3 = ring[i]
				var p1: Vector3 = ring[(i + 1) % 14]
				for p in [apex, p0, p1, apex, p1, p0]:
					st.set_color(straw.darkened(0.12 if i % 2 == 0 else 0.0))
					st.add_vertex(p)
		"bow":
			# recurved bow in the LEFT hand, string straight
			var up := Vector3(0.0, 0.0, -1.0)
			var prev := Vector3.ZERO
			for i in range(9):
				var u := (i / 8.0) * 2.0 - 1.0
				var p := up * u * 0.42 + Vector3(0.0, -0.09 * (1.0 - u * u), 0.0)
				if i > 0:
					_cyl(st, prev, p, 0.008, wood)
				prev = p
			_cyl(st, up * -0.42, up * 0.42, 0.002, Color(0.85, 0.82, 0.7))
		_: # dao: grip in the fist, guard, a slightly curved single-edged blade
			var d := Vector3(0.0, 0.12, -1.0).normalized() # continues the forearm, edge slightly up
			_cyl(st, -d * 0.06, d * 0.04, 0.012, wood)
			_box(st, d * 0.045, Vector3(0.05, 0.016, 0.016), iron)
			_blade(st, d * 0.05, d * 0.46 + Vector3(0, 0.05, 0), 0.042, iron)
	st.generate_normals()
	var m := st.commit()
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.6
	mat.metallic = 0.2
	# double-sided: hand-built faces must not vanish when the wrist turns them away
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.surface_set_material(0, mat)
	_weapon_meshes[kind] = m
	return m

static func _cyl(st: SurfaceTool, a: Vector3, b: Vector3, r: float, col: Color) -> void:
	var ax := (b - a).normalized()
	var u := ax.cross(Vector3.RIGHT if absf(ax.x) < 0.9 else Vector3.UP).normalized()
	var v := ax.cross(u)
	var n := 6
	for i in range(n):
		var a0 := TAU * i / n
		var a1 := TAU * (i + 1) / n
		var o0 := (u * cos(a0) + v * sin(a0)) * r
		var o1 := (u * cos(a1) + v * sin(a1)) * r
		for p in [a + o0, b + o0, b + o1, a + o0, b + o1, a + o1]:
			st.set_color(col)
			st.add_vertex(p)

static func _blade(st: SurfaceTool, a: Vector3, b: Vector3, w: float, col: Color) -> void:
	var ax := (b - a).normalized()
	var side := ax.cross(Vector3.FORWARD if absf(ax.z) < 0.9 else Vector3.UP).normalized() * w * 0.5
	var thick := ax.cross(side).normalized() * 0.003
	var mid := a.lerp(b, 0.3)
	for f in [1.0, -1.0]:
		for tri in [[a, mid + side, b], [a, b, mid - side]]:
			for p in tri:
				st.set_color(col)
				st.add_vertex(p + thick * f)

static func _disc(st: SurfaceTool, c: Vector3, n: Vector3, r: float, thick: float, rim_col: Color, face_col: Color) -> void:
	var u := n.cross(Vector3.UP if absf(n.y) < 0.9 else Vector3.RIGHT).normalized()
	var v := n.cross(u)
	var seg := 16
	var front := c + n * thick * 0.5
	var back := c - n * thick * 0.5
	for i in range(seg):
		var a0 := TAU * i / seg
		var a1 := TAU * (i + 1) / seg
		var o0 := (u * cos(a0) + v * sin(a0)) * r
		var o1 := (u * cos(a1) + v * sin(a1)) * r
		for p in [front, front + o0, front + o1]:
			st.set_color(face_col); st.add_vertex(p)
		for p in [back, back + o1, back + o0]:
			st.set_color(rim_col); st.add_vertex(p)
		for p in [front + o0, back + o0, back + o1, front + o0, back + o1, front + o1]:
			st.set_color(rim_col); st.add_vertex(p)

static func _box(st: SurfaceTool, c: Vector3, s: Vector3, col: Color) -> void:
	var bm := BoxMesh.new()
	bm.size = s
	var arr: Array = bm.get_mesh_arrays()
	var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
	for i in idx:
		st.set_color(col)
		st.add_vertex(verts[i] + c)
