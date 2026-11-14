extends RefCounted
## The map editor's board, ported from the asset library's ground (natural_ground_world.gd over
## base_ground_world.gd, hex_map_lab.gd cell colours): same seed, same three noise layers, same five ground
## variants and neighbour rules, the continuous world-space colour sampler (R_BLEND 30.5, 19-hex neighbourhood,
## forest floor), 37-vertex hexes, darkened outline ring, drop skirts and base-ground-kit detail multimeshes.
## Only the inputs differ: kinds come from what is placed in the editor, overrides from the 바닥 tool (doc.ground).
const Paths = preload("res://tools/dev_visual_lab/visual_output_paths.gd")
const R := 18.0
const SQRT3 := 1.7320508075688772
const R_BLEND := 30.5
const R_BLEND_SQ := 930.25
const SEED := 20261019
const DIRS := [Vector2i(1,0), Vector2i(1,-1), Vector2i(0,-1), Vector2i(-1,0), Vector2i(-1,1), Vector2i(0,1)]
const VARIANTS := {
	"base_grassland": {"grass": "82975b", "accent": "768c50", "soil": "988864"},
	"grass_clump": {"grass": "6a8447", "accent": "5d773d", "soil": "897c5d"},
	"dry_grassland": {"grass": "a2955b", "accent": "b0a163", "soil": "859358"},
	"earth_plain": {"grass": "86945a", "accent": "9e8c67", "soil": "ab9870"},
	"pebble_grassland": {"grass": "7c8c57", "accent": "8e897a", "soil": "999383"},
}
const VARIANT_LABELS := {"base_grassland": "초원", "grass_clump": "풀 무성한 땅", "dry_grassland": "마른 풀밭",
	"earth_plain": "흙 평지", "pebble_grassland": "자갈 풀밭"}
const LOD0_MAX := 185.0       # base_ground_config lod_thresholds
const LOD1_MAX := 340.0

var macro := FastNoiseLite.new()
var meso := FastNoiseLite.new()
var micro := FastNoiseLite.new()
var terrain := FastNoiseLite.new()
var palettes := {}
var variant_map := {}
var kind_map := {}
var sampler := {}
var neighborhood: Array[Vector2i] = []
var rings: Array = []
var detail_meshes := {}
var details_lod0: Array = []
var details_lod1: Array = []
var material: StandardMaterial3D


func _init() -> void:
	macro.seed = SEED; macro.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH; macro.frequency = 0.0087
	meso.seed = SEED + 101; meso.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH; meso.frequency = 0.0278
	micro.seed = SEED + 202; micro.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH; micro.frequency = 0.0833
	terrain.seed = SEED; terrain.frequency = 0.018
	for k in VARIANTS.keys():
		palettes[k] = {"grass": Color(VARIANTS[k]["grass"]), "accent": Color(VARIANTS[k]["accent"]), "soil": Color(VARIANTS[k]["soil"])}
	for dq in range(-2, 3):
		for dr in range(-2, 3):
			if (absi(dq) + absi(dr) + absi(dq + dr)) / 2 <= 2: neighborhood.append(Vector2i(dq, dr))
	for r_frac in [0.0, 0.38, 0.72, 1.0]:
		if r_frac == 0.0: rings.append([Vector3.ZERO]); continue
		var ring: Array = []
		for side in range(6):
			var ca := Vector3(cos(float(side) * PI / 3.0) * R, 0, sin(float(side) * PI / 3.0) * R)
			var cb := Vector3(cos(float(side + 1) * PI / 3.0) * R, 0, sin(float(side + 1) * PI / 3.0) * R)
			for step in range(2): ring.append(ca.lerp(cb, float(step) / 2.0) * r_frac)
		rings.append(ring)
	material = StandardMaterial3D.new()
	material.vertex_color_use_as_albedo = true; material.roughness = 1.0; material.cull_mode = BaseMaterial3D.CULL_DISABLED
	for fam in ["grass_clump", "dry_tuft", "pebble_cluster"]:
		detail_meshes[fam] = [_load_detail(fam, 0), _load_detail(fam, 1)]


static func center(q: int, r: int) -> Vector3:
	return Vector3(1.5 * R * q, 0, SQRT3 * R * (r + q * 0.5))


func _load_detail(fam: String, lod: int) -> Mesh:
	var path := Paths.output("base-ground-kit/exports/ground_detail_%s_lod%d.glb" % [fam, lod])
	if not FileAccess.file_exists(path): return null
	var doc := GLTFDocument.new(); var st := GLTFState.new()
	if doc.append_from_file(path, st) != OK: return null
	var sc := doc.generate_scene(st) as Node3D
	var mesh: Mesh = null
	var mi := sc.find_children("*", "MeshInstance3D", true, false)
	if not mi.is_empty(): mesh = (mi[0] as MeshInstance3D).mesh
	sc.free()
	return mesh


## Static geometry per radius (every hex uses the 37-vertex layout; flat kinds just get one colour) and per-hex
## colour caches, so a change only resamples hexes within 4 of it: variants look 2 hexes out and the colour
## sampler 2 more. Visual result identical to building everything from scratch.
var _radius := -1
var _cells: Array[Vector2i] = []
var _cell_index := {}
var _g_verts := PackedVector3Array(); var _g_norms := PackedVector3Array(); var _g_idx := PackedInt32Array(); var _g_cols := PackedColorArray()
var _o_verts := PackedVector3Array(); var _o_norms := PackedVector3Array(); var _o_idx := PackedInt32Array(); var _o_cols := PackedColorArray()
var _prev_kinds := {}
var _prev_over := {}
## Hexes whose ground colour was resampled by the last build (everything when last_full).
var last_dirty := {}
var last_full := true
const PER_CELL_G := 24 + 37   # skirt quads + interior
const PER_CELL_O := 24


func _build_geometry(radius: int) -> void:
	_radius = radius
	_cells.clear(); _cell_index.clear()
	for q in range(-radius, radius + 1):
		for r in range(-radius, radius + 1):
			if maxi(absi(q), maxi(absi(r), absi(q + r))) > radius: continue
			_cell_index[Vector2i(q, r)] = _cells.size(); _cells.append(Vector2i(q, r))
	_g_verts.clear(); _g_norms.clear(); _g_idx.clear(); _o_verts.clear(); _o_norms.clear(); _o_idx.clear()
	var skirt := Color("514c3c").srgb_to_linear()
	for coord in _cells:
		var c := center(coord.x, coord.y)
		var gb := _g_verts.size(); var ob := _o_verts.size()
		for side in range(6):
			var a := float(side) * PI / 3.0; var b := float(side + 1) * PI / 3.0
			var p := Vector3(cos(a) * R, 0, sin(a) * R); var q := Vector3(cos(b) * R, 0, sin(b) * R)
			for v in [p, q, p * 0.994, q * 0.994]:
				_o_verts.append(c + v + Vector3.UP * 0.035); _o_norms.append(Vector3.UP)
			for i in [2, 0, 1, 2, 1, 3]: _o_idx.append(ob + side * 4 + i)
			var n := Vector3(cos(a + PI / 6.0), 0, sin(a + PI / 6.0))
			for v in [p, p - Vector3.UP * 3.0, q, q - Vector3.UP * 3.0]:
				_g_verts.append(c + v); _g_norms.append(n)
			for i in [0, 1, 2, 2, 1, 3]: _g_idx.append(gb + side * 4 + i)
		var vb := gb + 24
		_g_verts.append(c); _g_norms.append(Vector3.UP)
		for m in range(1, 4):
			for i in range(12):
				_g_verts.append(c + rings[m][i]); _g_norms.append(Vector3.UP)
		for i in range(12):
			_g_idx.append(vb); _g_idx.append(vb + 1 + i); _g_idx.append(vb + 1 + (i + 1) % 12)
		for m in range(1, 3):
			var bm := vb + 1 + (m - 1) * 12; var bn := vb + 1 + m * 12
			for i in range(12):
				var nx := (i + 1) % 12
				for idx in [bm + i, bn + nx, bm + nx, bm + i, bn + i, bn + nx]: _g_idx.append(idx)
	_g_cols.resize(_g_verts.size()); _o_cols.resize(_o_verts.size())
	for i in range(_g_cols.size()): _g_cols[i] = skirt
	_prev_kinds = {}; _prev_over = {}


## kinds: {Vector2i: "plain"|"forest"|"mountain"|"river"|"village"|"farm"|"castle"} (missing = plain)
## overrides: {"q,r": variant} painted with the 바닥 tool. Returns the board node (ground + outline + details).
func build(radius: int, kinds: Dictionary, overrides: Dictionary) -> Node3D:
	var full := radius != _radius
	if full: _build_geometry(radius)
	kind_map.clear()
	for c in _cells: kind_map[c] = str(kinds.get(c, "plain"))
	var changed: Array[Vector2i] = []
	if not full:
		for c in _cells:
			var key := "%d,%d" % [c.x, c.y]
			if str(_prev_kinds.get(c, "plain")) != kind_map[c] or str(_prev_over.get(key, "")) != str(overrides.get(key, "")):
				changed.append(c)
	_prev_kinds = kind_map.duplicate(); _prev_over = overrides.duplicate()
	_resolve_variants(_cells, overrides)
	_init_sampler(_cells)
	var dirty: Array = []
	last_full = full
	if full: dirty = _cells
	elif not changed.is_empty():
		var seen := {}
		for ch in changed:
			for dq in range(-4, 5):
				for dr in range(-4, 5):
					if (absi(dq) + absi(dr) + absi(dq + dr)) / 2 > 4: continue
					var c2 := ch + Vector2i(dq, dr)
					if _cell_index.has(c2) and not seen.has(c2): seen[c2] = true; dirty.append(c2)
	last_dirty = {}
	for coord in dirty: last_dirty[coord] = true
	for coord in dirty:
		var ci: int = _cell_index[coord]
		var c := center(coord.x, coord.y)
		var kind: String = kind_map[coord]
		var edge_col := _outline_color(coord, kind, c)
		for k in range(PER_CELL_O): _o_cols[ci * PER_CELL_O + k] = edge_col
		var vb := ci * PER_CELL_G + 24
		if kind in ["plain", "forest", "mountain"]:
			_g_cols[vb] = sample(c.x, c.z)
			var k2 := 1
			for m in range(1, 4):
				for i in range(12):
					var pt: Vector3 = c + rings[m][i]
					_g_cols[vb + k2] = sample(pt.x, pt.z); k2 += 1
		else:
			var col := _cell_color(kind, c)
			for k3 in range(37): _g_cols[vb + k3] = col
	var root := Node3D.new(); root.name = "NaturalGroundBoard"
	for set in [[_g_verts, _g_norms, _g_cols, _g_idx], [_o_verts, _o_norms, _o_cols, _o_idx]]:
		var arrays := []; arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = set[0]; arrays[Mesh.ARRAY_NORMAL] = set[1]; arrays[Mesh.ARRAY_COLOR] = set[2]; arrays[Mesh.ARRAY_INDEX] = set[3]
		var mesh := ArrayMesh.new(); mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var mi := MeshInstance3D.new(); mi.mesh = mesh; mi.material_override = material
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(mi)
	root.add_child(_details(_cells))
	return root


func _resolve_variants(cells: Array[Vector2i], overrides: Dictionary) -> void:
	variant_map.clear()
	var off2: Array[Vector2i] = []
	for dq in range(-2, 3):
		for dr in range(-2, 3):
			var d := (absi(dq) + absi(dr) + absi(dq + dr)) / 2
			if d >= 1 and d <= 2: off2.append(Vector2i(dq, dr))
	for coord in cells:
		var key := "%d,%d" % [coord.x, coord.y]
		if overrides.has(key) and palettes.has(str(overrides[key])):
			variant_map[coord] = str(overrides[key]); continue
		var kind: String = kind_map[coord]
		if kind != "plain":
			variant_map[coord] = "base_grassland"; continue
		var mw := 0; var sw := 0; var rw := 0
		for off in off2:
			var nk: String = kind_map.get(coord + off, "")
			var w := 2 if (absi(off.x) + absi(off.y) + absi(off.x + off.y)) / 2 == 1 else 1
			if nk == "mountain": mw += w
			elif nk in ["village", "farm", "castle"]: sw += w
			elif nk == "river": rw += w
		var v := "base_grassland"
		if mw > 0 and mw >= sw and mw >= rw: v = "pebble_grassland"
		elif sw > 0 and sw >= rw: v = "earth_plain"
		elif rw > 0: v = "grass_clump"
		else:
			var c := center(coord.x, coord.y)
			v = "dry_grassland" if macro.get_noise_2d(c.x, c.z) > 0.06 else "base_grassland"
		variant_map[coord] = v


func _init_sampler(cells: Array[Vector2i]) -> void:
	sampler.clear()
	for coord in cells:
		var kind: String = kind_map[coord]
		var pal: Dictionary
		if kind == "plain" or kind == "forest":
			pal = palettes.get(variant_map.get(coord, "base_grassland"), palettes["base_grassland"])
		elif kind == "mountain":
			var vn: String = variant_map.get(coord, "pebble_grassland")
			if vn == "base_grassland": vn = "pebble_grassland"
			pal = palettes.get(vn, palettes["pebble_grassland"])
		elif kind in ["village", "farm", "castle"]:
			pal = {"grass": Color("86945a"), "accent": Color("9e8c67"), "soil": Color("ab9870")}
		elif kind == "river":
			pal = {"grass": Color("80935a"), "accent": Color("71874d"), "soil": Color("9b916e")}
		else:
			pal = palettes["base_grassland"]
		sampler[coord] = {"center": center(coord.x, coord.y), "palette": pal, "forest": kind == "forest"}


func _axial(wx: float, wz: float) -> Vector2i:
	var x := wx / (1.5 * R); var z := wz / (SQRT3 * R) - 0.5 * x; var y := -x - z
	var rx := roundi(x); var ry := roundi(y); var rz := roundi(z)
	var xd := absf(float(rx) - x); var yd := absf(float(ry) - y); var zd := absf(float(rz) - z)
	if xd > yd and xd > zd: rx = -ry - rz
	elif yd > zd: ry = -rx - rz
	else: rz = -rx - ry
	return Vector2i(rx, rz)


## natural_ground_world.sample_natural_ground_color, unchanged. Linear colour.
func sample(wx: float, wz: float) -> Color:
	var ma := macro.get_noise_2d(wx, wz); var me := meso.get_noise_2d(wx, wz); var mi := micro.get_noise_2d(wx, wz)
	var patch_t := smoothstep(-0.15, 0.25, me + ma * 0.45)
	var soil_spot := smoothstep(0.22, 0.52, me * 0.65 + mi * 0.55)
	var total := 0.0; var sum := Color(0, 0, 0, 0); var forest_w := 0.0
	var base := _axial(wx, wz)
	for off in neighborhood:
		var coord := base + off
		if not sampler.has(coord): continue
		var data: Dictionary = sampler[coord]
		var cp: Vector3 = data["center"]
		var dx := wx - cp.x; var dz := wz - cp.z; var d2 := dx * dx + dz * dz
		if d2 < R_BLEND_SQ:
			var w := 1.0 - sqrt(d2) / R_BLEND; w = w * w
			var pal: Dictionary = data["palette"]
			sum += (pal["grass"] as Color).lerp(pal["accent"], patch_t).lerp(pal["soil"], soil_spot) * w
			total += w
		if data["forest"] and d2 < 380.25:
			var fw := clampf(1.0 - sqrt(d2) / 19.5, 0.0, 1.0); forest_w += fw * fw
	var c_base: Color = sum / total if total > 0.0001 else (palettes["base_grassland"]["grass"] as Color)
	var f := clampf(forest_w, 0.0, 1.0)
	if f > 0.001:
		var floor_col := Color("596c41").lerp(Color("7a694b"), smoothstep(-0.2, 0.3, me + mi * 0.4)).lerp(Color("625740"), smoothstep(0.1, 0.45, me * 0.7 - mi * 0.3))
		c_base = c_base.lerp(floor_col, f * 0.88).darkened(0.16 * f)
	return c_base.lightened(ma * 0.04).srgb_to_linear()


func _outline_color(coord: Vector2i, kind: String, c: Vector3) -> Color:
	if kind in ["forest", "mountain", "plain"]:
		return sample(c.x, c.z).linear_to_srgb().darkened(0.24).srgb_to_linear()
	return _cell_color(kind, c).linear_to_srgb().darkened(0.25).srgb_to_linear()


func _cell_color(kind: String, c: Vector3) -> Color:
	var col := Color("899b65")
	match kind:
		"forest": col = Color("65764b")
		"mountain": col = Color("9b9681")
		"castle", "village": col = Color("b4a281")
		"farm": col = Color("a2a06c")
		"river": col = Color("7b9b94")
	return col.lightened(terrain.get_noise_2d(c.x, c.z) * 0.05).srgb_to_linear()


## base_ground_world.scatter_ground_detail_accents, unchanged rules (plain hexes not next to river or settlement).
func _details(cells: Array[Vector2i]) -> Node3D:
	var holder := Node3D.new(); holder.name = "GroundDetails"
	details_lod0.clear(); details_lod1.clear()
	var lists := {"grass_clump": [], "dry_tuft": [], "pebble_cluster": []}
	for coord in cells:
		if kind_map[coord] != "plain": continue
		var near := false
		for d in DIRS:
			if str(kind_map.get(coord + d, "")) in ["river", "village", "farm", "castle"]: near = true; break
		if near: continue
		var rng := RandomNumberGenerator.new(); rng.seed = int((coord.x * 73856093) ^ (coord.y * 19349663) ^ SEED)
		var c := center(coord.x, coord.y)
		var v: String = variant_map.get(coord, "base_grassland")
		for _i in range(rng.randi_range(4, 7)):
			var fam: String
			match v:
				"dry_grassland": fam = "dry_tuft" if rng.randf() < 0.75 else "grass_clump"
				"pebble_grassland":
					var roll := rng.randf()
					fam = "pebble_cluster" if roll < 0.65 else ("grass_clump" if roll < 0.90 else "dry_tuft")
				"grass_clump": fam = "grass_clump" if rng.randf() < 0.85 else "dry_tuft"
				"earth_plain": fam = "dry_tuft" if rng.randf() < 0.50 else "grass_clump"
				_:
					var roll2 := rng.randf()
					fam = "grass_clump" if roll2 < 0.70 else ("dry_tuft" if roll2 < 0.90 else "pebble_cluster")
			var rad := rng.randf_range(3.0, 13.5); var ang := rng.randf() * TAU
			var pos := c + Vector3(cos(ang) * rad, 0.02, sin(ang) * rad)
			var rot := rng.randf() * TAU; var s := rng.randf_range(0.65, 0.95)
			lists[fam].append(Transform3D(Basis(Vector3.UP, rot).scaled(Vector3.ONE * s), pos))
	var accent := StandardMaterial3D.new()
	accent.vertex_color_use_as_albedo = true; accent.roughness = 0.9; accent.cull_mode = BaseMaterial3D.CULL_DISABLED
	for fam in lists.keys():
		for lod in range(2):
			var mesh: Mesh = detail_meshes[fam][lod]
			var t_list: Array = lists[fam]
			if mesh == null or t_list.is_empty(): continue
			var mm := MultiMesh.new(); mm.transform_format = MultiMesh.TRANSFORM_3D; mm.mesh = mesh; mm.instance_count = t_list.size()
			for i in range(t_list.size()): mm.set_instance_transform(i, t_list[i])
			var mmi := MultiMeshInstance3D.new(); mmi.multimesh = mm; mmi.material_override = accent
			mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			holder.add_child(mmi)
			(details_lod0 if lod == 0 else details_lod1).append(mmi)
	return holder


## base_ground_world.update_lod: full details up close, simplified at mid zoom, hidden far out.
func update_lod(camera_size: float) -> void:
	for m in details_lod0:
		if is_instance_valid(m): m.visible = camera_size <= LOD0_MAX
	for m in details_lod1:
		if is_instance_valid(m): m.visible = camera_size > LOD0_MAX and camera_size <= LOD1_MAX


## natural_ground_world._adapt_single_mountain_mesh, connected-range branch: the mountain's lower apron takes the
## ground colour under it (with a gentle slope shade), its rim is seated flush on the board, and only the high
## limestone / steep rock keeps the model's own colour. `mi` must be in the tree (world position matters).
func adapt_mountain_mesh(mi: MeshInstance3D) -> ArrayMesh:
	var orig: Mesh = mi.get_meta("original_mesh") if mi.has_meta("original_mesh") else mi.mesh
	if not mi.has_meta("original_mesh"): mi.set_meta("original_mesh", orig)
	if orig == null or orig.get_surface_count() == 0: return null
	var xf: Transform3D = mi.global_transform
	var inv_xf := xf.affine_inverse()
	var up_loc := (inv_xf.basis * Vector3.UP).normalized()
	var out := ArrayMesh.new()
	for si in range(orig.get_surface_count()):
		var arrays := orig.surface_get_arrays(si)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
		if colors.is_empty(): colors.resize(verts.size()); colors.fill(Color("848f5b"))
		if normals.is_empty(): normals.resize(verts.size()); normals.fill(Vector3.UP)
		for k in range(verts.size()):
			var wp: Vector3 = xf * verts[k]
			var wn: Vector3 = (xf.basis * normals[k]).normalized()
			var h := wp.y
			var c_rock: Color = colors[k]
			var ground_col := sample(wp.x, wp.z)
			var green_diff := c_rock.g - c_rock.r
			var is_limestone := smoothstep(0.005, -0.025, green_diff) * smoothstep(0.41, 0.47, c_rock.b)
			var is_steep := smoothstep(0.72, 0.42, wn.y) * smoothstep(0.38, 0.45, c_rock.b)
			var rock_mask := clampf(smoothstep(2.8, 4.8, h) * maxf(is_limestone, is_steep), 0.0, 1.0)
			if h <= 2.8: rock_mask = 0.0
			if h <= 0.18:
				wp.y = lerpf(wp.y, 0.025, smoothstep(0.18, 0.0, h))
				verts[k] = inv_xf * wp
			if h <= 2.4 and rock_mask < 0.3:
				normals[k] = normals[k].lerp(up_loc, (1.0 - smoothstep(0.0, 2.4, h)) * (1.0 - rock_mask)).normalized()
			var slope_shade := clampf((1.0 - wn.y) * 0.18 * smoothstep(0.8, 2.8, h), 0.0, 0.12)
			colors[k] = ground_col.darkened(slope_shade).lerp(c_rock, rock_mask)
		arrays[Mesh.ARRAY_VERTEX] = verts; arrays[Mesh.ARRAY_NORMAL] = normals; arrays[Mesh.ARRAY_COLOR] = colors
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return out
