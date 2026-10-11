extends RefCounted

## CIV3D battle effects (VISUAL ONLY): the impact burst where a blow or a
## volley lands, and the arrows archers loose. Muted to the painterly palette:
## trampled dust plus a brief pale spark, no gore.

static var _dust_mat: StandardMaterial3D = null
static var _spark_mat: StandardMaterial3D = null
static var _arrow_mesh: Mesh = null

static func _billboard_mat(additive: bool) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD if additive else BaseMaterial3D.BLEND_MODE_MIX
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	m.vertex_color_use_as_albedo = true
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	# soft round puff, not a square
	var g := Gradient.new()
	g.set_color(0, Color(1, 1, 1, 1))
	g.set_color(1, Color(1, 1, 1, 0))
	g.add_point(0.45, Color(1, 1, 1, 0.55))
	var tex := GradientTexture2D.new()
	tex.gradient = g
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(0.5, 0.0)
	tex.width = 64
	tex.height = 64
	m.albedo_texture = tex
	return m

## Impact at `pos` (parent space); `size` ~ a figure's height.
static func impact(parent: Node3D, pos: Vector3, size: float) -> void:
	if _dust_mat == null:
		_dust_mat = _billboard_mat(false)
		_spark_mat = _billboard_mat(true)
	var dust := _particles(30, 1.0, _dust_mat, size * 0.42)
	dust.direction = Vector3.UP
	dust.spread = 70.0
	dust.initial_velocity_min = size * 0.6
	dust.initial_velocity_max = size * 1.5
	dust.gravity = Vector3(0, -size * 0.9, 0)
	dust.damping_min = size * 0.8
	dust.damping_max = size * 1.4
	dust.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	dust.emission_sphere_radius = size * 0.45
	dust.scale_amount_min = 0.7
	dust.scale_amount_max = 1.5
	dust.scale_amount_curve = _curve([0.4, 1.0, 1.3])
	dust.color_ramp = _ramp(Color(0.72, 0.64, 0.50, 0.75), Color(0.66, 0.60, 0.50, 0.0))
	dust.position = pos + Vector3(0, size * 0.15, 0)
	parent.add_child(dust)
	var spark := _particles(18, 0.3, _spark_mat, size * 0.09)
	spark.direction = Vector3.UP
	spark.spread = 85.0
	spark.initial_velocity_min = size * 2.0
	spark.initial_velocity_max = size * 4.0
	spark.gravity = Vector3(0, -size * 6.0, 0)
	spark.color_ramp = _ramp(Color(1.0, 0.92, 0.70, 1.0), Color(1.0, 0.55, 0.25, 0.0))
	spark.position = pos + Vector3(0, size * 0.55, 0)
	parent.add_child(spark)
	for p in [dust, spark]:
		var cp: CPUParticles3D = p
		cp.emitting = true
		var tree: SceneTree = parent.get_tree()
		if tree != null:
			# the first frame draws an uninitialised (black) particle at the emitter:
			# stay hidden until the simulation has run
			cp.visible = false
			tree.create_timer(0.05).timeout.connect(func(): if is_instance_valid(cp): cp.visible = true)
			tree.create_timer(1.6).timeout.connect(cp.queue_free)

static func _particles(n: int, life: float, mat: Material, quad: float) -> CPUParticles3D:
	var p := CPUParticles3D.new()
	p.amount = n
	p.lifetime = life
	p.one_shot = true
	p.explosiveness = 0.92
	p.randomness = 0.4
	p.local_coords = false
	var q := QuadMesh.new()
	q.size = Vector2(quad, quad)
	q.material = mat
	p.mesh = q
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return p

static func _ramp(a: Color, b: Color) -> Gradient:
	var g := Gradient.new()
	g.set_color(0, a)
	g.set_color(1, b)
	return g

static func _curve(vals: Array) -> Curve:
	var c := Curve.new()
	c.max_value = 2.0
	for i in range(vals.size()):
		c.add_point(Vector2(float(i) / float(vals.size() - 1), vals[i]))
	return c

# --------------------------------------------------------------------- arrows
## One arrow's flight from `from` to `to` (parent space) on a ballistic arc.
## It points along its velocity, sticks where it lands and fades out.
static func arrow(parent: Node3D, from: Vector3, to: Vector3, flight: float, length: float) -> void:
	var a := ArrowFlight.new()
	a.mesh = _arrow(length)
	a.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	a.from = from
	a.to = to
	a.flight = flight
	a.apex = from.distance_to(to) * 0.28
	a.k = length
	parent.add_child(a)
	a.position = from

static func _arrow(length: float) -> Mesh:
	if _arrow_mesh != null:
		return _arrow_mesh
	# shaft along -Z (head first), fletching at the tail: a few thin boxes
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var shaft := Color(0.55, 0.42, 0.26)
	var head := Color(0.30, 0.30, 0.32)
	var fletch := Color(0.88, 0.86, 0.80)
	_box(st, Vector3(0, 0, 0), Vector3(0.012, 0.012, 0.5), shaft)
	_box(st, Vector3(0, 0, -0.52), Vector3(0.022, 0.022, 0.05), head)
	_box(st, Vector3(0, 0, 0.44), Vector3(0.05, 0.004, 0.08), fletch)
	_box(st, Vector3(0, 0, 0.44), Vector3(0.004, 0.05, 0.08), fletch)
	st.generate_normals()
	var m := st.commit()
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.9
	m.surface_set_material(0, mat)
	_arrow_mesh = m
	return m

static func _box(st: SurfaceTool, c: Vector3, h: Vector3, col: Color) -> void:
	var v := []
	for i in range(8):
		v.append(c + Vector3(h.x * (1 if i & 1 else -1), h.y * (1 if i & 2 else -1), h.z * (1 if i & 4 else -1)))
	for f in [[0, 1, 3, 2], [4, 6, 7, 5], [0, 4, 5, 1], [2, 3, 7, 6], [0, 2, 6, 4], [1, 5, 7, 3]]:
		for k in [0, 1, 2, 0, 2, 3]:
			st.set_color(col)
			st.add_vertex(v[f[k]])

class ArrowFlight extends MeshInstance3D:
	var from := Vector3.ZERO
	var to := Vector3.ZERO
	var flight := 1.0
	var apex := 2.0
	var t := 0.0
	var landed := false
	var k := 1.0 # mesh scale (the model arrow is ~1.1 long)

	func _pos(u: float) -> Vector3:
		return from.lerp(to, u) + Vector3.UP * apex * 4.0 * u * (1.0 - u)

	func _process(delta: float) -> void:
		t += delta
		if landed:
			if t > 2.4:
				transparency = minf(1.0, (t - 2.4) / 0.6)
			if t > 3.0:
				queue_free()
			return
		var u: float = minf(1.0, t / flight)
		var p: Vector3 = _pos(u)
		var ahead: Vector3 = _pos(minf(1.0, u + 0.02)) - _pos(maxf(0.0, u - 0.02))
		position = p
		if ahead.length() > 0.0001:
			basis = Basis.looking_at(ahead.normalized(), Vector3.UP) * Basis.from_scale(Vector3.ONE * k)
		if u >= 1.0:
			landed = true
			t = 0.0
			position = p - ahead.normalized() * 0.15 * k # head buried in the ground
