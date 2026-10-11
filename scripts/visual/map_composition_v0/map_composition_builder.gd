class_name MapCompositionBuilder
extends RefCounted

## MAP COMPOSITION V0 — deterministic per-hex composition builder (presentation only).
##
## ONE LOGICAL HEX = ONE COMPOSITION (diorama) of MANY SMALL assets.
##  * FOREST A/B/C — different density, mixture, silhouette and spacing
##  * VILLAGE A/B/C — different layouts of the same small-structure vocabulary
##
## Containment contract (mirrors HexForestCompositor): every instance must sit
## inside the inset (s = 0.90) flat-top hex (corner radius 24 px, W48/H42).
## Placement uses a circle fit; the builder then MEASURES the exact bounding
## rectangle corner violations for the evidence report (expected 0).
##
## Nothing here owns gameplay state; nothing writes back to the grid.

const Lib = preload("res://scripts/visual/map_composition_v0/map_composition_library.gd")

## ---- Hex containment (flat-top, world px; matches HexUtils + visual contract) --
const HEX_R := 24.0                      # corner (west/east) radius
const INSET := 0.90                      # s_inset, as the approved forest grammar
const Z_MAX := 21.0 * INSET              # 18.9  (top/bottom half-flat bound)
const C_PLANE := 168.0 * INSET           # 151.2 (slanted half-plane constant)
const PLANE_NORM := 8.06225774829        # |normal| of the 7x ± 4z planes
## Mountain range bound: mountains may deliberately OVERLAP and pass the hex
## edge to connect with neighbouring ranges (user direction). They are measured
## against this relaxed bound (range-2 broad bases overhang deeply by design)
## instead of the strict inset so the evidence number still catches gross overshoots.
const Z_MAX_M := 33.0
const C_PLANE_M := 350.0

static func min_margin(p: Vector2, z_max: float = Z_MAX, c_plane: float = C_PLANE) -> float:
	## Signed distance to the nearest inset-hex edge (positive = inside).
	var d1: float = z_max + p.y
	var d2: float = z_max - p.y
	var d3: float = (c_plane - 7.0 * p.x + 4.0 * p.y) / PLANE_NORM
	var d4: float = (c_plane - 7.0 * p.x - 4.0 * p.y) / PLANE_NORM
	var d5: float = (c_plane + 7.0 * p.x - 4.0 * p.y) / PLANE_NORM
	var d6: float = (c_plane + 7.0 * p.x + 4.0 * p.y) / PLANE_NORM
	return minf(minf(minf(d1, d2), minf(d3, d4)), minf(d5, d6))

static func corner_violation(center: Vector2, yaw: float, half: Vector2, z_max: float = Z_MAX, c_plane: float = C_PLANE) -> float:
	## Exact worst corner penetration of the rotated footprint rect (px, 0 = none).
	## Mountains pass their relaxed range bound (Z_MAX_M / C_PLANE_M).
	var worst := 0.0
	var cs := cos(yaw)
	var sn := sin(yaw)
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			var lx: float = half.x * sx
			var lz: float = half.y * sz
			# Godot rotation.y convention: local +X -> (cos, -sin), +Z -> (sin, cos) in (x, z)
			var c := Vector2(lx * cs + lz * sn, -lx * sn + lz * cs) + center
			worst = maxf(worst, -min_margin(c, z_max, c_plane))
	return worst

## ---- Shared materials ---------------------------------------------------------

static var _mat_cache: Dictionary = {}

static func _flat_mat(col: Color) -> StandardMaterial3D:
	var key := "flat:" + col.to_html(false)
	if not _mat_cache.has(key):
		var m := StandardMaterial3D.new()
		m.albedo_color = col
		m.roughness = 1.0
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
		m.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
		_mat_cache[key] = m
	return _mat_cache[key]

static func _solid_mat(col: Color) -> StandardMaterial3D:
	var key := "solid:" + col.to_html(false)
	if not _mat_cache.has(key):
		var m := StandardMaterial3D.new()
		m.albedo_color = col
		m.roughness = 0.95
		_mat_cache[key] = m
	return _mat_cache[key]

## ---- Ground decals ------------------------------------------------------------

static func _flat_vc_mat() -> StandardMaterial3D:
	if not _mat_cache.has("flatvc"):
		var m := StandardMaterial3D.new()
		m.albedo_color = Color.WHITE
		m.vertex_color_use_as_albedo = true
		m.roughness = 1.0
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
		_mat_cache["flatvc"] = m
	return _mat_cache["flatvc"]

## Flat hexagon disc whose per-vertex color samples Lib.ground_tint at WORLD
## coordinates (same function as the backdrop → continuous across tiles).
static func hex_disc_tinted(parent: Node3D, r: float, y: float, base: Color, hex_world_center: Vector2) -> MeshInstance3D:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var n := Vector3.UP
	var cv := Vector3(0.0, y, 0.0)
	for i in range(6):
		var a0: float = deg_to_rad(60.0 * i)
		var a1: float = deg_to_rad(60.0 * (i + 1))
		var p0 := Vector3(cos(a0) * r, y, sin(a0) * r)
		var p1 := Vector3(cos(a1) * r, y, sin(a1) * r)
		for v in [cv, p0, p1]:
			st.set_color(base * Lib.ground_tint(hex_world_center.x + v.x, hex_world_center.y + v.z))
			st.set_normal(n)
			st.add_vertex(v)
	var mi := MeshInstance3D.new()
	mi.name = "HexDecalTinted"
	mi.mesh = st.commit()
	mi.material_override = _flat_vc_mat()
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)
	return mi

static func _hex_disc(parent: Node3D, r: float, y: float, col: Color) -> MeshInstance3D:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var n := Vector3.UP
	var c := Vector3(0.0, y, 0.0)
	for i in range(6):
		var a0: float = deg_to_rad(60.0 * i)
		var a1: float = deg_to_rad(60.0 * (i + 1))
		var p0 := Vector3(cos(a0) * r, y, sin(a0) * r)
		var p1 := Vector3(cos(a1) * r, y, sin(a1) * r)
		for v in [c, p0, p1]:
			st.set_normal(n)
			st.add_vertex(v)
	var mesh := st.commit()
	var mi := MeshInstance3D.new()
	mi.name = "HexDecal"
	mi.mesh = mesh
	mi.material_override = _flat_mat(col)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)
	return mi

static func _ribbon(parent: Node3D, pts: PackedVector2Array, width: float, col: Color, y: float) -> void:
	if pts.size() < 2:
		return
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var n := Vector3.UP
	var left: Array = []
	var right: Array = []
	for i in range(pts.size()):
		var dir: Vector2
		if i == 0:
			dir = (pts[1] - pts[0]).normalized()
		elif i == pts.size() - 1:
			dir = (pts[i] - pts[i - 1]).normalized()
		else:
			dir = ((pts[i + 1] - pts[i]).normalized() + (pts[i] - pts[i - 1]).normalized()).normalized()
		var perp := Vector2(dir.y, -dir.x) * (width * 0.5)
		left.append(pts[i] + perp)
		right.append(pts[i] - perp)
	for i in range(pts.size() - 1):
		var l0: Vector2 = left[i]
		var l1: Vector2 = left[i + 1]
		var r0: Vector2 = right[i]
		var r1: Vector2 = right[i + 1]
		for tri in [[l0, r0, l1], [r0, r1, l1]]:
			for p in tri:
				st.set_normal(n)
				st.add_vertex(Vector3(p.x, y, p.y))
	var mesh := st.commit()
	var mi := MeshInstance3D.new()
	mi.name = "Ribbon"
	mi.mesh = mesh
	mi.material_override = _flat_mat(col)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)

## ---- Fences (presentation scaffolding; no fence source exists in the runs) -----

static func _fence(parent: Node3D, a: Vector2, b: Vector2) -> void:
	var len := a.distance_to(b)
	if len < 0.5:
		return
	var posts := int(maxf(2.0, roundf(len / 1.15) + 1.0))
	var post_mesh := BoxMesh.new()
	post_mesh.size = Vector3(0.13, 0.55, 0.13)
	var post_mat := _solid_mat(Lib.COL_WOOD)
	var yaw := atan2(b.y - a.y, b.x - a.x)
	for i in range(posts):
		var t: float = float(i) / float(posts - 1)
		var p := a.lerp(b, t)
		var mi := MeshInstance3D.new()
		mi.mesh = post_mesh
		mi.material_override = post_mat
		mi.position = Vector3(p.x, 0.275, p.y)
		parent.add_child(mi)
	for hy in [0.34, 0.47]:
		var rail := BoxMesh.new()
		rail.size = Vector3(len, 0.085, 0.065)
		var mi := MeshInstance3D.new()
		mi.mesh = rail
		mi.material_override = _solid_mat(Lib.COL_WOOD_LIGHT)
		mi.position = Vector3((a.x + b.x) * 0.5, hy, (a.y + b.y) * 0.5)
		mi.rotation.y = -yaw
		parent.add_child(mi)

## ---- Instance helpers ---------------------------------------------------------

static func _add_asset(parent: Node3D, key: String, pos: Vector2, yaw_deg: float, s: float, y_var: float, stats: Dictionary, z_max: float = Z_MAX, c_plane: float = C_PLANE, pos_y: float = 0.0) -> Node3D:
	var wrap := Node3D.new()
	wrap.name = "P_" + key
	if Lib.TREES.has(key):
		# Instance names are not a reliable identifier when repeated tree keys
		# become siblings; runtime batching reads this explicit presentation tag.
		wrap.set_meta("map_asset_key", key)
	wrap.position = Vector3(pos.x, pos_y, pos.y)
	wrap.rotation.y = deg_to_rad(yaw_deg)
	wrap.scale = Vector3(s, s * y_var, s)
	var inst := Lib.instance_grounded(key)
	wrap.add_child(inst)
	parent.add_child(wrap)
	stats["placed"][key] = int(stats["placed"].get(key, 0)) + 1
	stats["triangles"] = int(stats["triangles"]) + int(Lib.triangles(key))
	var b: Dictionary = Lib.bounds(key)
	var half: Vector2 = b["half_xz"]
	stats["max_violation"] = maxf(float(stats["max_violation"]), corner_violation(pos, deg_to_rad(yaw_deg), half * s, z_max, c_plane))
	return wrap

## Collects every vertex of every mesh under `node` into `out`, transformed by
## the accumulated local transforms starting at `xf` (composition-local space).
static func _collect_world_verts(node: Node, xf: Transform3D, out: PackedVector3Array) -> void:
	var t: Transform3D = xf
	if node is Node3D:
		t = xf * (node as Node3D).transform
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		if mi.mesh != null:
			for si in range(mi.mesh.get_surface_count()):
				var arrays: Array = mi.mesh.surface_get_arrays(si)
				if arrays.is_empty() or arrays[Mesh.ARRAY_VERTEX] == null:
					continue
				var vp: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
				for v in vp:
					out.append(t * v)
	for ch in node.get_children():
		_collect_world_verts(ch, t, out)

## Approximate surface height of the collected piece vertices at XZ point p:
## average y of vertices within 1.2 units, else the nearest vertex's y.
static func _sample_surface_y(verts: PackedVector3Array, p: Vector2) -> float:
	var best := 1.0e9
	var best_y := 0.0
	var acc := 0.0
	var accn := 0
	for v in verts:
		var dx: float = v.x - p.x
		var dz: float = v.z - p.y
		var d2: float = dx * dx + dz * dz
		if d2 < best:
			best = d2
			best_y = v.y
		if d2 < 1.44:
			acc += v.y
			accn += 1
	if accn > 0 and best <= 1.44:
		return acc / float(accn)
	return best_y

## Ground TILE (ground_tiles family): a textured hex tile scaled to the review
## hex footprint (W48/H42), placed with its designed surface at y≈0 — its slab
## extends below and replaces the flat tinted plate for that hex.
## `y_factor` flattens the tile's vertical detail: SETTLEMENT and FARM tiles are
## pressed flat (lawn-height ground — user: the grass is too tall in villages /
## fortresses / farm districts) while wild forest tiles keep their full height.
const TILE_Y_FACTOR := 0.35

static func build_tile(key: String, y_factor: float = 1.0) -> Node3D:
	var root := Node3D.new()
	root.name = "Tile_" + key
	var b: Dictionary = Lib.bounds(key)
	var half: Vector2 = b["half_xz"]
	var sx: float = HEX_HALF_W / half.x
	var sz: float = HEX_HALF_H / half.y
	root.scale = Vector3(sx, sx * y_factor, sz)
	root.add_child(Lib.instance_centered(key))
	return root

const HEX_HALF_W := 24.0
const HEX_HALF_H := 21.0

static func _weighted_pick(rng: RandomNumberGenerator, weights: Dictionary) -> String:
	var total := 0.0
	for k in weights:
		total += float(weights[k])
	var v := rng.randf() * total
	for k in weights:
		v -= float(weights[k])
		if v <= 0.0:
			return k
	return weights.keys()[weights.size() - 1]

## ---- FOREST -------------------------------------------------------------------

const FOREST_SPECS: Array = [
	{ # A — dense pine mass; MANY SMALL trees; single tight blob; highest density
		"name": "FOREST A",
		"count": 150, "min_dist": 1.05,
		"scale": [0.48, 0.68], "y_var": [0.88, 1.22],
		"mixture": {"tall_pine": 2, "wind_pine": 3, "conifer": 1, "compact_pine": 12, "dead_tree": 2},
		"blobs": [{"c": Vector2(0.0, 0.0), "r": 17.5}],
		"floors": 7, "floor_r": [13.0, 16.5],
	},
	{ # B — mixed broadleaf wood; many small trees; two lobes; middle density
		"name": "FOREST B",
		"count": 95, "min_dist": 1.35,
		"scale": [0.48, 0.66], "y_var": [0.90, 1.20],
		"mixture": {"broadleaf": 2, "wind_pine": 3, "compact_pine": 6, "sapling": 2, "dead_tree": 3, "cypress": 2},
		"blobs": [{"c": Vector2(-4.5, -3.5), "r": 16.5}, {"c": Vector2(7.5, 6.5), "r": 11.0}],
		"floors": 5, "floor_r": [11.5, 15.0],
	},
	{ # C — cypress copse with clearings; three clumps; loosest of the three
		"name": "FOREST C",
		"count": 64, "min_dist": 1.7,
		"scale": [0.50, 0.68], "y_var": [0.95, 1.28],
		"mixture": {"cypress": 5, "sapling": 2, "dead_tree": 3, "compact_pine": 3},
		"blobs": [{"c": Vector2(4.0, -5.0), "r": 11.5}, {"c": Vector2(-6.5, 3.5), "r": 11.5}, {"c": Vector2(3.5, 8.0), "r": 10.0}],
		"floors": 4, "floor_r": [10.0, 13.5],
	},
]

static func build_forest(variant: int, seed: int) -> Dictionary:
	var spec: Dictionary = FOREST_SPECS[variant]
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var root := Node3D.new()
	root.name = "Composition_" + String(spec["name"]).replace(" ", "_")
	var stats := {"name": spec["name"], "placed": {}, "triangles": 0, "max_violation": 0.0, "skipped": 0, "spec": {"count": spec["count"], "min_dist": spec["min_dist"], "scale": spec["scale"]}}

	# understory floors first (blob-local)
	var floors: int = int(spec["floors"])
	var blob_list: Array = spec["blobs"]
	for i in range(floors):
		var blob: Dictionary = blob_list[i % blob_list.size()]
		var c: Vector2 = blob["c"] + Vector2(rng.randf_range(-2.6, 2.6), rng.randf_range(-2.6, 2.6))
		var r: float = rng.randf_range(float(spec["floor_r"][0]), float(spec["floor_r"][1]))
		var col: Color = Lib.COL_FOREST_FLOOR if (i % 2 == 0) else Lib.COL_FOREST_FLOOR_ALT
		_hex_disc(root, r, 0.018 + 0.004 * float(i), col)

	# trees
	var accepted: Array = []
	var keys: Array = spec["mixture"].keys()
	for t in range(int(spec["count"])):
		var key: String = _weighted_pick(rng, spec["mixture"])
		var s: float = rng.randf_range(spec["scale"][0], spec["scale"][1])
		var yv: float = rng.randf_range(spec["y_var"][0], spec["y_var"][1])
		var circ: float = float(Lib.bounds(key)["circ_r"]) * s
		var placed := false
		for attempt in range(80):
			var blob: Dictionary = _pick_blob(rng, blob_list)
			var c2: Vector2 = blob["c"]
			var ang := rng.randf() * TAU
			var rad: float = sqrt(rng.randf()) * float(blob["r"])
			var pos := c2 + Vector2(cos(ang), sin(ang)) * rad
			if min_margin(pos) < circ:
				continue
			var clash := false
			for other in accepted:
				if pos.distance_to(other) < float(spec["min_dist"]):
					clash = true
					break
			if clash:
				continue
			_add_asset(root, key, pos, rng.randf_range(0.0, 360.0), s, yv, stats)
			accepted.append(pos)
			placed = true
			break
		if not placed:
			stats["skipped"] = int(stats["skipped"]) + 1
	return {"root": root, "stats": stats}

static func _pick_blob(rng: RandomNumberGenerator, blobs: Array) -> Dictionary:
	var total := 0.0
	for b in blobs:
		total += float(b["r"]) * float(b["r"])
	var v := rng.randf() * total
	for b in blobs:
		v -= float(b["r"]) * float(b["r"])
		if v <= 0.0:
			return b
	return blobs[blobs.size() - 1]

## ---- VILLAGE ------------------------------------------------------------------

## Curated layouts (hand-placed, deterministic) — different compositions, not
## rotations of one plan. "structures" keep their yaw; "trees" get a random yaw.
const VILLAGE_SPECS: Array = [
	{ # VILLAGE A — farmstead row: six small houses + granary + two sheds along a road + field
		"name": "VILLAGE A",
		"structures": [
			{"key": "small_house", "pos": Vector2(-9.0, -3.0), "yaw": 15.0, "s": 0.62},
			{"key": "small_house", "pos": Vector2(-0.5, 3.2), "yaw": 195.0, "s": 0.66},
			{"key": "small_house", "pos": Vector2(8.2, -2.4), "yaw": 95.0, "s": 0.58},
			{"key": "small_house", "pos": Vector2(-11.6, 6.2), "yaw": 330.0, "s": 0.56},
			{"key": "granary", "pos": Vector2(0.4, -8.6), "yaw": 0.0, "s": 0.51},
			{"key": "workshop", "pos": Vector2(5.8, -9.8), "yaw": 20.0, "s": 0.5},
			{"key": "small_house", "pos": Vector2(14.2, 3.2), "yaw": 260.0, "s": 0.54},
			{"key": "small_house", "pos": Vector2(-13.6, -2.0), "yaw": 80.0, "s": 0.52},
			{"key": "granary", "pos": Vector2(-5.6, 11.4), "yaw": 0.0, "s": 0.48},
			{"key": "workshop", "pos": Vector2(-9.8, 9.4), "yaw": 340.0, "s": 0.48},
			{"key": "small_house", "pos": Vector2(15.6, -4.6), "yaw": 110.0, "s": 0.5},
			{"key": "small_house", "pos": Vector2(-14.6, 7.8), "yaw": 300.0, "s": 0.5},
		],
		"trees": [
			{"key": "sapling", "pos": Vector2(-7.6, 8.2), "s": 0.6},
			{"key": "sapling", "pos": Vector2(10.4, 6.2), "s": 0.54},
			{"key": "dead_tree", "pos": Vector2(11.6, -8.0), "s": 0.6},
			{"key": "compact_pine", "pos": Vector2(-12.4, -7.6), "s": 0.51},
			{"key": "sapling", "pos": Vector2(-2.8, 10.6), "s": 0.57},
			{"key": "sapling", "pos": Vector2(6.0, 12.4), "s": 0.57},
			{"key": "compact_pine", "pos": Vector2(-15.0, 3.4), "s": 0.51},
			{"key": "sapling", "pos": Vector2(0.8, -12.8), "s": 0.57},
			{"key": "sapling", "pos": Vector2(-16.4, -6.6), "s": 0.54},
			{"key": "sapling", "pos": Vector2(15.55, 7.55), "s": 0.54},
			{"key": "dead_tree", "pos": Vector2(13.4, -11.4), "s": 0.57},
			{"key": "sapling", "pos": Vector2(-9.0, -14.6), "s": 0.54},
		],
		"agriculture": [
			{"key": "rice_field", "pos": Vector2(10.5, -11.5), "yaw": 20.0, "s": 0.44},
			{"key": "farm_granary", "pos": Vector2(-9.75, -10.0), "yaw": 200.0, "s": 0.55},
		],
		"fences": [
			[Vector2(-5.5, 7.4), Vector2(4.5, 7.4)],
			[Vector2(-5.5, 7.4), Vector2(-5.5, 2.2)],
			[Vector2(3.2, 11.8), Vector2(11.8, 11.8)],
			[Vector2(11.8, 11.8), Vector2(11.8, 5.6)],
			[Vector2(-14.2, 11.8), Vector2(-7.8, 11.8)],
		],
		"road": {"pts": [Vector2(16.2, 9.45), Vector2(10.4, 5.2), Vector2(4.6, 2.0), Vector2(-0.2, 0.6)], "width": 1.9},
		"field": {"center": Vector2(7.5, 8.6), "r": 4.8},
		"yard_r": 15.5,
	},
	{ # VILLAGE B — courtyard cluster: two family houses + three small houses + hall + workshop + granary + field
		"name": "VILLAGE B",
		"structures": [
			{"key": "medium_house", "pos": Vector2(-8.0, -4.5), "yaw": 80.0, "s": 0.58},
			{"key": "medium_house", "pos": Vector2(6.8, -5.2), "yaw": 265.0, "s": 0.56},
			{"key": "small_house", "pos": Vector2(-2.2, 9.2), "yaw": 0.0, "s": 0.61},
			{"key": "small_house", "pos": Vector2(-1.8, -9.6), "yaw": 250.0, "s": 0.58},
			{"key": "hall", "pos": Vector2(8.6, 5.0), "yaw": 195.0, "s": 0.49},
			{"key": "workshop", "pos": Vector2(-9.4, 4.6), "yaw": 20.0, "s": 0.56},
			{"key": "granary", "pos": Vector2(10.2, -5.4), "yaw": 80.0, "s": 0.48},
			{"key": "small_house", "pos": Vector2(5.2, 10.6), "yaw": 220.0, "s": 0.56},
			{"key": "small_house", "pos": Vector2(-6.4, -11.4), "yaw": 40.0, "s": 0.54},
			{"key": "granary", "pos": Vector2(11.6, 2.6), "yaw": 350.0, "s": 0.46},
			{"key": "workshop", "pos": Vector2(-11.0, -1.0), "yaw": 120.0, "s": 0.5},
			{"key": "small_house", "pos": Vector2(15.0, 4.8), "yaw": 290.0, "s": 0.5},
			{"key": "small_house", "pos": Vector2(-14.2, 6.8), "yaw": 240.0, "s": 0.5},
		],
		"trees": [
			{"key": "sapling", "pos": Vector2(1.8, 0.2), "s": 0.65},
			{"key": "sapling", "pos": Vector2(11.2, -9.2), "s": 0.62},
			{"key": "dead_tree", "pos": Vector2(-13.0, -8.6), "s": 0.62},
			{"key": "sapling", "pos": Vector2(-6.6, 11.0), "s": 0.57},
			{"key": "sapling", "pos": Vector2(1.6, 4.0), "s": 0.62},
			{"key": "sapling", "pos": Vector2(-9.0, 10.2), "s": 0.57},
			{"key": "dead_tree", "pos": Vector2(14.2, -7.4), "s": 0.6},
			{"key": "sapling", "pos": Vector2(15.4, -4.2), "s": 0.54},
			{"key": "sapling", "pos": Vector2(-15.8, -5.4), "s": 0.54},
			{"key": "sapling", "pos": Vector2(3.0, -15.0), "s": 0.54},
			{"key": "sapling", "pos": Vector2(-2.6, 15.4), "s": 0.54},
		],
		"agriculture": [
			{"key": "rice_field", "pos": Vector2(-11.5, -11.5), "yaw": 340.0, "s": 0.42},
			{"key": "farm_granary", "pos": Vector2(8.5, -12.25), "yaw": 160.0, "s": 0.55},
		],
		"fences": [
			[Vector2(-13.0, -8.8), Vector2(-13.0, 2.6)],
			[Vector2(13.2, 8.6), Vector2(13.2, -2.0)],
			[Vector2(-3.6, 12.8), Vector2(4.4, 12.8)],
		],
		"road": {"pts": [Vector2(-16.2, 9.45), Vector2(-9.8, 5.6), Vector2(-4.2, 2.4), Vector2(0.0, 1.0)], "width": 1.9},
		"field": {"center": Vector2(10.2, 10.0), "r": 3.2},
		"yard_r": 15.5,
	},
	{ # VILLAGE C — dispersed hamlet: four small houses + two workshops + granary, path, scattered trees
		"name": "VILLAGE C",
		"structures": [
			{"key": "small_house", "pos": Vector2(-10.0, -6.0), "yaw": 30.0, "s": 0.56},
			{"key": "small_house", "pos": Vector2(9.2, 3.4), "yaw": 120.0, "s": 0.54},
			{"key": "small_house", "pos": Vector2(-7.2, 2.6), "yaw": 100.0, "s": 0.54},
			{"key": "workshop", "pos": Vector2(-3.2, 9.0), "yaw": 350.0, "s": 0.54},
			{"key": "workshop", "pos": Vector2(7.0, 11.2), "yaw": 300.0, "s": 0.5},
			{"key": "granary", "pos": Vector2(2.4, -7.2), "yaw": 300.0, "s": 0.46},
			{"key": "small_house", "pos": Vector2(12.4, 8.0), "yaw": 210.0, "s": 0.52},
			{"key": "small_house", "pos": Vector2(-12.6, -3.4), "yaw": 60.0, "s": 0.52},
			{"key": "workshop", "pos": Vector2(4.8, -13.0), "yaw": 320.0, "s": 0.48},
			{"key": "granary", "pos": Vector2(-11.4, -10.2), "yaw": 0.0, "s": 0.46},
			{"key": "small_house", "pos": Vector2(15.2, 4.6), "yaw": 150.0, "s": 0.5},
			{"key": "small_house", "pos": Vector2(-15.0, 7.6), "yaw": 280.0, "s": 0.5},
		],
		"trees": [
			{"key": "sapling", "pos": Vector2(-4.6, -0.8), "s": 0.6},
			{"key": "sapling", "pos": Vector2(4.8, 8.2), "s": 0.65},
			{"key": "sapling", "pos": Vector2(-12.2, 4.8), "s": 0.57},
			{"key": "sapling", "pos": Vector2(13.0, -4.6), "s": 0.57},
			{"key": "sapling", "pos": Vector2(0.4, 12.6), "s": 0.54},
			{"key": "broadleaf", "pos": Vector2(6.6, -10.6), "s": 0.48},
			{"key": "dead_tree", "pos": Vector2(-7.8, -11.2), "s": 0.6},
			{"key": "sapling", "pos": Vector2(15.0, -0.4), "s": 0.54},
			{"key": "compact_pine", "pos": Vector2(-2.2, -3.6), "s": 0.48},
			{"key": "dead_tree", "pos": Vector2(9.8, 12.0), "s": 0.57},
			{"key": "sapling", "pos": Vector2(16.2, -6.8), "s": 0.54},
			{"key": "sapling", "pos": Vector2(-14.6, -8.4), "s": 0.54},
			{"key": "sapling", "pos": Vector2(11.8, 13.6), "s": 0.54},
			{"key": "sapling", "pos": Vector2(-6.2, 15.0), "s": 0.54},
		],
		"agriculture": [
			{"key": "rice_field", "pos": Vector2(10.5, -1.5), "yaw": 120.0, "s": 0.45},
			{"key": "farm_granary", "pos": Vector2(-4.75, -12.5), "yaw": 30.0, "s": 0.55},
		],
		"fences": [
			[Vector2(-12.8, -1.6), Vector2(-7.4, -1.6)],
			[Vector2(3.4, -10.8), Vector2(8.6, -10.8)],
		],
		"road": {"pts": [Vector2(0.0, -18.9), Vector2(-0.8, -9.0), Vector2(0.8, -2.2), Vector2(5.0, 1.2), Vector2(8.6, 2.6)], "width": 1.5},
		"field": {"center": Vector2(11.0, -11.6), "r": 3.8},
		"yard_r": 15.0,
	},
]

static func build_village(variant: int, seed: int) -> Dictionary:
	var spec: Dictionary = VILLAGE_SPECS[variant]
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var root := Node3D.new()
	root.name = "Composition_" + String(spec["name"]).replace(" ", "_")
	var stats := {"name": spec["name"], "placed": {}, "triangles": 0, "max_violation": 0.0, "skipped": 0, "spec": {"structures": (spec["structures"] as Array).size(), "trees": (spec["trees"] as Array).size(), "agriculture": (spec.get("agriculture", []) as Array).size()}}

	# yard + field decals
	_hex_disc(root, float(spec["yard_r"]), 0.012, Lib.COL_VILLAGE_YARD)
	if spec["field"] != null:
		var f: Dictionary = spec["field"]
		var fc: Vector2 = f["center"]
		var fr: float = float(f["r"])
		_hex_disc(root, fr, 0.020, Lib.COL_FIELD)
		var strips := 4
		for i in range(strips):
			var xo: float = -fr * 0.5 + fr * 1.0 * float(i) / float(strips - 1)
			var strip := BoxMesh.new()
			strip.size = Vector3(0.40, 0.012, fr * 1.0)
			var mi := MeshInstance3D.new()
			mi.mesh = strip
			mi.material_override = _solid_mat(Lib.COL_FIELD_EDGE)
			mi.position = Vector3(fc.x + xo, 0.028, fc.y)
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			root.add_child(mi)

	# road (edge enters at the inset hex boundary)
	var road: Dictionary = spec["road"]
	_ribbon(root, PackedVector2Array(road["pts"]), float(road["width"]) * 1.6, Lib.COL_ROAD_EDGE, 0.026)
	_ribbon(root, PackedVector2Array(road["pts"]), float(road["width"]), Lib.COL_ROAD, 0.034)

	# structures + agriculture pieces (curated yaw, overlap-relaxed) + trees (random yaw)
	var entries: Array = []
	for st in spec["structures"]:
		var key := String(st["key"])
		var sb: Dictionary = Lib.bounds(key)
		var half := Vector2((sb["max"].x - sb["min"].x) * 0.5, (sb["max"].z - sb["min"].z) * 0.5) * float(st["s"])
		entries.append({"key": key, "pos": st["pos"], "yaw": float(st["yaw"]), "s": float(st["s"]), "half": half})
	for ag in spec.get("agriculture", []):
		var akey := String(ag["key"])
		var ab: Dictionary = Lib.bounds(akey)
		var ahalf := Vector2((ab["max"].x - ab["min"].x) * 0.5, (ab["max"].z - ab["min"].z) * 0.5) * float(ag["s"])
		entries.append({"key": akey, "pos": ag["pos"], "yaw": float(ag["yaw"]), "s": float(ag["s"]), "half": ahalf, "fixed": true})
	stats["overlaps"] = _relax_structures(entries, 9999.0)
	for e in entries:
		_add_asset(root, String(e["key"]), e["pos"], float(e["yaw"]), float(e["s"]), 1.0, stats)
	for tr in spec["trees"]:
		_add_asset(root, String(tr["key"]), tr["pos"], rng.randf_range(0.0, 360.0), float(tr["s"]), 1.0, stats)

	# fences
	for run in spec["fences"]:
		_fence(root, run[0], run[1])

	return {"root": root, "stats": stats}

## ---- FARM ---------------------------------------------------------------------

## Standalone agriculture hexes — ONE crop type per hex (same kinds grouped, so
## each tile reads like real farmland): many SMALL field pieces packed on a
## hex-shaped grid (rows 5/4/4/3/3 at 6.5 spacing, per-piece yaw/scale jitter).
const FARM_SPECS: Array = [
	{ # FARM A — dry crop fields only
		"name": "FARM A",
		"key": "dry_field",
		"yard_r": 17.8,
	},
	{ # FARM B — irrigated rice paddies only
		"name": "FARM B",
		"key": "rice_field",
		"yard_r": 17.8,
	},
	{ # FARM C — terraced fields only
		"name": "FARM C",
		"key": "terraced_field",
		"yard_r": 17.8,
	},
]

## Hex-shaped dense fill: rows z = 0/±6.5/±13 with 5/4/3 pieces, x spaced 6.5.
## Scale ≤ 0.52 keeps every ~12-unit field slab inside its 6.5 cell (no overlap,
## corner margins ≥ ~2.2 against the inset hex).
static func build_farm(variant: int, seed: int) -> Dictionary:
	var spec: Dictionary = FARM_SPECS[variant]
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var root := Node3D.new()
	root.name = "Composition_" + String(spec["name"]).replace(" ", "_")
	var stats := {"name": spec["name"], "placed": {}, "triangles": 0, "max_violation": 0.0, "skipped": 0, "spec": {"key": spec["key"], "grid": "5/4/4/3/3 @6.5"}}

	_hex_disc(root, float(spec["yard_r"]), 0.012, Lib.COL_FARM_YARD)

	var rows: Array = [
		{"z": 0.0, "xs": [-13.0, -6.5, 0.0, 6.5, 13.0]},
		{"z": 6.5, "xs": [-9.75, -3.25, 3.25, 9.75]},
		{"z": -6.5, "xs": [-9.75, -3.25, 3.25, 9.75]},
		{"z": 13.0, "xs": [-6.5, 0.0, 6.5]},
		{"z": -13.0, "xs": [-6.5, 0.0, 6.5]},
	]
	for row in rows:
		for x in row["xs"]:
			var s: float = rng.randf_range(0.46, 0.52)
			var yaw: float = 90.0 * float(rng.randi_range(0, 3))
			_add_asset(root, String(spec["key"]), Vector2(x, float(row["z"])), yaw, s, 1.0, stats)

	return {"root": root, "stats": stats}

## ---- MOUNTAIN -----------------------------------------------------------------

## Standalone mountain hexes — LOW mixed ranges (the cleanroom archetypes ship
## tree-free; trees / streams / low walls are added here as decoration). Piece
## scales are capped so nothing towers (max ~5.6) and slabs never overlap.
const MOUNTAIN_SPECS: Array = [
	{ # MOUNTAIN A — range start: dominant peak (~29 tall) + flanks; SE mass overhangs toward B
		"name": "MOUNTAIN A",
		"pieces": [
			{"key": "sharp_peak", "pos": Vector2(0.0, 0.0), "yaw": 0.0, "s": 3.2, "y": 1.45},
			{"key": "cliff_escarpment", "pos": Vector2(-10.0, 7.0), "yaw": 0.0, "s": 1.5, "y": 1.15},
			{"key": "low_foothill", "pos": Vector2(-11.0, -8.0), "yaw": 90.0, "s": 1.4, "y": 1.1},
			{"key": "long_ridge", "pos": Vector2(8.0, 8.0), "yaw": 0.0, "s": 1.5, "y": 1.2},
			{"key": "low_foothill", "pos": Vector2(16.0, 4.0), "yaw": 0.0, "s": 1.55, "y": 1.1},
		],
		"trees": [
			{"key": "sapling", "pos": Vector2(-19.0, -2.0), "s": 0.50},
			{"key": "compact_pine", "pos": Vector2(18.0, 3.0), "s": 0.48},
			{"key": "sapling", "pos": Vector2(3.0, -17.5), "s": 0.50},
			{"key": "dead_tree", "pos": Vector2(-2.0, 17.5), "s": 0.46},
			{"key": "sapling", "pos": Vector2(4.0, -13.5), "s": 0.52},
		],
		"stream": null,
		"walls": [],
		"yard_r": 17.8,
	},
	{ # MOUNTAIN B — central ridge chain: dominant peak (~28) + ridge + connectors both ways
		"name": "MOUNTAIN B",
		"pieces": [
			{"key": "sharp_peak", "pos": Vector2(-2.0, 1.0), "yaw": 0.0, "s": 3.2, "y": 1.4},
			{"key": "long_ridge", "pos": Vector2(11.0, -8.0), "yaw": 0.0, "s": 1.6, "y": 1.3},
			{"key": "twin_saddle", "pos": Vector2(6.0, 10.0), "yaw": 0.0, "s": 1.5, "y": 1.1},
			{"key": "low_foothill", "pos": Vector2(-15.0, -5.0), "yaw": 0.0, "s": 1.6, "y": 1.1},
			{"key": "cliff_escarpment", "pos": Vector2(14.5, 6.0), "yaw": 0.0, "s": 1.55, "y": 1.1},
		],
		"trees": [
			{"key": "sapling", "pos": Vector2(-20.0, -1.0), "s": 0.50},
			{"key": "sapling", "pos": Vector2(10.0, -17.0), "s": 0.50},
			{"key": "compact_pine", "pos": Vector2(17.0, 5.0), "s": 0.48},
			{"key": "dead_tree", "pos": Vector2(0.0, -17.0), "s": 0.46},
		],
		"stream": null,
		"walls": [],
		"yard_r": 17.8,
	},
	{ # MOUNTAIN C — massif heart (~26) + peak + connectors toward B and D
		"name": "MOUNTAIN C",
		"pieces": [
			{"key": "layered_massif", "pos": Vector2(-1.0, 0.0), "yaw": 0.0, "s": 3.1, "y": 1.45},
			{"key": "sharp_peak", "pos": Vector2(11.0, 9.0), "yaw": 0.0, "s": 1.7, "y": 1.2},
			{"key": "low_foothill", "pos": Vector2(-15.0, -5.5), "yaw": 0.0, "s": 1.6, "y": 1.1},
			{"key": "cliff_escarpment", "pos": Vector2(-13.0, 10.0), "yaw": 0.0, "s": 1.5, "y": 1.1},
			{"key": "twin_saddle", "pos": Vector2(9.0, -10.0), "yaw": 90.0, "s": 1.5, "y": 1.1},
		],
		"trees": [
			{"key": "sapling", "pos": Vector2(-19.5, 0.0), "s": 0.50},
			{"key": "compact_pine", "pos": Vector2(19.0, -1.0), "s": 0.48},
			{"key": "sapling", "pos": Vector2(17.5, 4.0), "s": 0.48},
		],
		"stream": null,
		"walls": [],
		"yard_r": 17.8,
	},
	{ # MOUNTAIN D — range end: dominant massif (~26) + peak; NW overhang toward C
		"name": "MOUNTAIN D",
		"pieces": [
			{"key": "layered_massif", "pos": Vector2(2.0, 0.0), "yaw": 0.0, "s": 3.1, "y": 1.45},
			{"key": "sharp_peak", "pos": Vector2(-11.0, 8.0), "yaw": 0.0, "s": 1.65, "y": 1.2},
			{"key": "long_ridge", "pos": Vector2(6.0, 11.0), "yaw": 0.0, "s": 1.6, "y": 1.25},
			{"key": "low_foothill", "pos": Vector2(-14.5, -6.5), "yaw": 0.0, "s": 1.6, "y": 1.1},
			{"key": "cliff_escarpment", "pos": Vector2(13.0, -7.0), "yaw": 0.0, "s": 1.5, "y": 1.1},
		],
		"trees": [
			{"key": "sapling", "pos": Vector2(19.0, -0.5), "s": 0.50},
			{"key": "compact_pine", "pos": Vector2(-17.0, 3.5), "s": 0.48},
			{"key": "sapling", "pos": Vector2(-20.0, -1.0), "s": 0.50},
		],
		"stream": null,
		"walls": [],
		"yard_r": 17.8,
	},
	{ # MOUNTAIN E — mountain + agriculture combo (terrace farm at the mountain foot)
		"name": "MOUNTAIN E",
		"pieces": [
			{"key": "vegetated_mountain", "pos": Vector2(-2.0, -4.0), "yaw": 0.0, "s": 1.05},
			{"key": "terraced_field", "pos": Vector2(7.5, 3.0), "yaw": 0.0, "s": 0.60},
			{"key": "terraced_field", "pos": Vector2(-1.5, 9.5), "yaw": 90.0, "s": 0.55},
			{"key": "rice_field", "pos": Vector2(-8.5, 6.0), "yaw": 0.0, "s": 0.55},
			{"key": "low_foothill", "pos": Vector2(8.5, 13.0), "yaw": 0.0, "s": 1.05},
		],
		"trees": [
			{"key": "sapling", "pos": Vector2(-12.0, -3.0), "s": 0.50},
			{"key": "compact_pine", "pos": Vector2(-11.5, 1.5), "s": 0.46},
			{"key": "sapling", "pos": Vector2(10.5, -8.0), "s": 0.50},
			{"key": "sapling", "pos": Vector2(12.5, 2.0), "s": 0.46},
			{"key": "dead_tree", "pos": Vector2(-4.0, 12.5), "s": 0.48},
		],
		"stream": {"pts": [Vector2(-11.5, 10.5), Vector2(-6.5, 13.8), Vector2(1.0, 15.5)], "width": 0.45},
		"walls": [
			{"pos": Vector2(3.9, 2.0), "yaw": 90.0, "s": 0.30},
			{"pos": Vector2(0.0, 6.1), "yaw": 0.0, "s": 0.30},
		],
		"yard_r": 17.8,
	},
	{ # MOUNTAIN F — range2 UNIQUE: ONE dominant rounded head + two small foot bumps (single mass) + tree cover
		"name": "MOUNTAIN F",
		"pieces": [
			{"key": "low_foothill", "pos": Vector2(-0.5, -0.5), "yaw": 0.0, "s": 4.2, "y": 1.5},
			{"key": "low_foothill", "pos": Vector2(7.0, 4.0), "yaw": 20.0, "s": 2.3, "y": 1.3},
			{"key": "low_foothill", "pos": Vector2(-8.0, 5.0), "yaw": 40.0, "s": 2.1, "y": 1.3},
		],
		"trees": [],
		"cover": {"density": 0.085, "min_dist": 0.95, "mixture": {"compact_pine": 8, "cypress": 3, "dead_tree": 2}, "scale": [0.68, 0.92]},
		"stream": null,
		"walls": [],
		"yard_r": 17.8,
	},
	{ # MOUNTAIN G — range2 UNIQUE: LOW scattered field of six small domes (clearly lower) + tree cover
		"name": "MOUNTAIN G",
		"pieces": [
			{"key": "low_foothill", "pos": Vector2(0.0, 1.0), "yaw": 0.0, "s": 2.4, "y": 1.2},
			{"key": "low_foothill", "pos": Vector2(-7.0, -3.0), "yaw": 25.0, "s": 2.5, "y": 1.2},
			{"key": "low_foothill", "pos": Vector2(6.0, 4.0), "yaw": 35.0, "s": 2.2, "y": 1.2},
			{"key": "low_foothill", "pos": Vector2(-2.0, -6.0), "yaw": 10.0, "s": 2.2, "y": 1.15},
			{"key": "low_foothill", "pos": Vector2(4.0, -4.0), "yaw": 45.0, "s": 2.1, "y": 1.15},
			{"key": "low_foothill", "pos": Vector2(9.0, 6.0), "yaw": 0.0, "s": 2.0, "y": 1.15},
		],
		"trees": [],
		"cover": {"density": 0.085, "min_dist": 0.95, "mixture": {"compact_pine": 8, "cypress": 3, "dead_tree": 2}, "scale": [0.68, 0.92]},
		"stream": null,
		"walls": [],
		"yard_r": 17.8,
	},
	{ # MOUNTAIN H — range2 UNIQUE: TWIN mounds (two large domes side by side) + two small bumps + tree cover
		"name": "MOUNTAIN H",
		"pieces": [
			{"key": "low_foothill", "pos": Vector2(-6.0, -3.0), "yaw": 0.0, "s": 3.7, "y": 1.5},
			{"key": "low_foothill", "pos": Vector2(6.0, 3.0), "yaw": 0.0, "s": 3.7, "y": 1.5},
			{"key": "low_foothill", "pos": Vector2(12.0, 7.0), "yaw": 0.0, "s": 2.1, "y": 1.3},
			{"key": "low_foothill", "pos": Vector2(0.0, 8.0), "yaw": 0.0, "s": 2.0, "y": 1.3},
		],
		"trees": [],
		"cover": {"density": 0.085, "min_dist": 0.95, "mixture": {"compact_pine": 8, "cypress": 3, "dead_tree": 2}, "scale": [0.68, 0.92]},
		"stream": null,
		"walls": [],
		"yard_r": 17.8,
	},
	{ # MOUNTAIN I — range2 UNIQUE: asymmetric big mass + offset SE shoulder step + smalls + tree cover
		"name": "MOUNTAIN I",
		"pieces": [
			{"key": "low_foothill", "pos": Vector2(0.0, 0.0), "yaw": 0.0, "s": 4.0, "y": 1.5},
			{"key": "low_foothill", "pos": Vector2(9.0, 4.5), "yaw": 15.0, "s": 2.9, "y": 1.4},
			{"key": "low_foothill", "pos": Vector2(-8.0, -4.0), "yaw": 40.0, "s": 2.3, "y": 1.3},
			{"key": "low_foothill", "pos": Vector2(-3.0, 7.0), "yaw": 0.0, "s": 2.0, "y": 1.3},
		],
		"trees": [],
		"cover": {"density": 0.085, "min_dist": 0.95, "mixture": {"compact_pine": 8, "cypress": 3, "dead_tree": 2}, "scale": [0.68, 0.92]},
		"stream": null,
		"walls": [],
		"yard_r": 17.8,
	},
]

static func build_mountain(variant: int, seed: int) -> Dictionary:
	var spec: Dictionary = MOUNTAIN_SPECS[variant]
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var root := Node3D.new()
	root.name = "Composition_" + String(spec["name"]).replace(" ", "_")
	var stats := {"name": spec["name"], "placed": {}, "triangles": 0, "max_violation": 0.0, "skipped": 0, "spec": {"pieces": (spec["pieces"] as Array).size()}}

	_hex_disc(root, float(spec["yard_r"]), 0.012, Lib.COL_MOUNTAIN_YARD)
	_hex_ring(root, 22.7, 23.7, 0.035, Lib.COL_MOUNTAIN_BORDER)
	if spec.get("stream", null) != null:
		var st: Dictionary = spec["stream"]
		_ribbon(root, PackedVector2Array(st["pts"]), float(st["width"]) * 1.6, Lib.COL_WATER_EDGE, 0.026)
		_ribbon(root, PackedVector2Array(st["pts"]), float(st["width"]), Lib.COL_WATER, 0.034)
	var dome_verts := PackedVector3Array()
	for p in spec["pieces"]:
		var wrap := _add_asset(root, String(p["key"]), p["pos"], float(p["yaw"]), float(p["s"]), float(p.get("y", 1.0)), stats, Z_MAX_M, C_PLANE_M)
		_collect_world_verts(wrap, Transform3D.IDENTITY, dome_verts)
	# COVER TREES: scatter small trees over the dome surfaces so the big rounded
	# masses read as tree-covered hills (user direction: the bare green polygons
	# should not be visible). Each tree's Y is sampled from the dome vertices at
	# its XZ, so trees sit ON the slopes (never buried inside the mass).
	if spec.get("cover", null) != null and not dome_verts.is_empty():
		var cover: Dictionary = spec["cover"]
		var mix: Dictionary = cover["mixture"]
		var sc: Array = cover["scale"]
		var density: float = float(cover["density"])
		var min_d: float = float(cover["min_dist"])
		var made := 0
		for p2 in spec["pieces"]:
			var ps: float = float(p2["s"])
			var bb: Dictionary = Lib.bounds(String(p2["key"]))
			var r_eff: float = minf(float(bb["half_xz"].x), float(bb["half_xz"].y)) * ps * 0.95
			var k: int = int(round(PI * r_eff * r_eff * density))
			# CLUMPED scatter: spawn 2-5 trees around each cluster centre — reads
			# as a natural forest patch and covers more surface per tree.
			var clusters: int = int(maxf(1.0, round(float(k) / 3.4)))
			var centres: Array = []
			var guard := 0
			while centres.size() < clusters and guard < clusters * 14:
				guard += 1
				var ang: float = rng.randf() * TAU
				var rad: float = sqrt(rng.randf()) * r_eff
				var cp: Vector2 = (p2["pos"] as Vector2) + Vector2(cos(ang), sin(ang)) * rad
				var okd := true
				for q in centres:
					if (cp - (q as Vector2)).length() < min_d * 2.2:
						okd = false
						break
				if okd:
					centres.append(cp)
			for cpt in centres:
				var n_in: int = 2 + int(rng.randf() * 4.0)
				for i3 in range(n_in):
					var a2: float = rng.randf() * TAU
					var r2: float = sqrt(rng.randf()) * 1.5
					var tp: Vector2 = (cpt as Vector2) + Vector2(cos(a2), sin(a2)) * r2
					var sy: float = _sample_surface_y(dome_verts, tp)
					var tkey: String = _weighted_pick(rng, mix)
					var ts: float = rng.randf_range(float(sc[0]), float(sc[1]))
					_add_asset(root, tkey, tp, rng.randf_range(0.0, 360.0), ts, 1.0, stats, Z_MAX_M, C_PLANE_M, maxf(sy - 0.3, -0.45))
					made += 1
		stats["spec"]["cover_trees"] = made
	for w in spec.get("walls", []):
		_add_asset(root, "stone_wall", w["pos"], float(w["yaw"]), float(w["s"]), 1.0, stats)
	for tr in spec.get("trees", []):
		_add_asset(root, String(tr["key"]), tr["pos"], rng.randf_range(0.0, 360.0), float(tr["s"]), 1.0, stats)

	return {"root": root, "stats": stats}

## Thin hexagonal border line following the hex outline (mountain hexes — the
## range deliberately passes over it toward neighbouring hexes).
static func _hex_ring(parent: Node3D, r_in: float, r_out: float, y: float, color: Color) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(6):
		var a0: float = deg_to_rad(60.0 * float(i))
		var a1: float = deg_to_rad(60.0 * float(i + 1))
		var p0i := Vector3(cos(a0) * r_in, y, sin(a0) * r_in)
		var p1i := Vector3(cos(a1) * r_in, y, sin(a1) * r_in)
		var p0o := Vector3(cos(a0) * r_out, y, sin(a0) * r_out)
		var p1o := Vector3(cos(a1) * r_out, y, sin(a1) * r_out)
		st.set_normal(Vector3.UP)
		st.set_color(color)
		st.add_vertex(p0i)
		st.set_normal(Vector3.UP)
		st.set_color(color)
		st.add_vertex(p0o)
		st.set_normal(Vector3.UP)
		st.set_color(color)
		st.add_vertex(p1o)
		st.set_normal(Vector3.UP)
		st.set_color(color)
		st.add_vertex(p0i)
		st.set_normal(Vector3.UP)
		st.set_color(color)
		st.add_vertex(p1o)
		st.set_normal(Vector3.UP)
		st.set_color(color)
		st.add_vertex(p1i)
	var mi := MeshInstance3D.new()
	mi.name = "HexBorder"
	mi.mesh = st.commit()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 1.0
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)

## ---- CITY ---------------------------------------------------------------------

## Wall rings: straight fortification segments placed on a hexagonal ring that
## is PARALLEL to the tile's own hexagon (side normals at the tile-edge angles),
## so walls, gate and roads line up with the grid without ever crossing it.
const CITY_SPECS: Array = [
	{ # CITY A — stone walled town: 18-slot ring (3 segments per side); TWO centred gates (S+N), enlarged tall gatehouse
		"name": "CITY A",
		"wall": {"key": "stone_wall", "scale": 0.86},
		"gates": [90.0, 270.0],
		"gate_scale": 1.40,
		"gate_inset": 1.0,
		"ring_r": 19.1,
		"segments_per_side": 3,
		"keep": null,
		"structures": [
			{"key": "hall", "pos": Vector2(0.0, -1.5), "yaw": 0.0, "s": 0.62},
			{"key": "medium_house", "pos": Vector2(3.0, -0.8), "yaw": 90.0, "s": 0.56},
			{"key": "small_house", "pos": Vector2(-3.4, -2.8), "yaw": 200.0, "s": 0.58},
			{"key": "granary", "pos": Vector2(-3.2, 0.4), "yaw": 0.0, "s": 0.52},
			{"key": "workshop", "pos": Vector2(2.4, -3.8), "yaw": 300.0, "s": 0.52},
		],
		"inner_walls": [
			{"angle": 210.0, "offset": 0.0, "s": 0.60, "ring_r": 6.2},
			{"angle": 330.0, "offset": 0.0, "s": 0.60, "ring_r": 6.2},
		],
		"inner_towers": [
			{"pos": Vector2(12.0, 1.0), "yaw": 0.0, "s": 0.85},
			{"pos": Vector2(-12.0, 1.0), "yaw": 0.0, "s": 0.85},
		],
		"fill": {"count": 20, "ring_band": [9.5, 13.5], "inner_band": [4.5, 9.0], "ring_share": 0.62, "scales": [0.48, 0.68], "mix": {"small_house": 6, "medium_house": 4, "granary": 4, "workshop": 4}},
		"roads": [
			{"pts": [Vector2(0.0, 14.2), Vector2(0.0, 5.5)], "width": 1.6},
			{"pts": [Vector2(0.0, -14.2), Vector2(0.0, -5.8)], "width": 1.6},
		],
		"field": null,
		"yard_r": 17.5,
	},
	{ # CITY B — wooden palisade burg: closed 18-slot ring, NO main gate (per direction)
		"name": "CITY B",
		"wall": {"key": "palisade", "scale": 0.86},
		"gates": [],
		"gate_scale": 0.85,
		"ring_r": 18.7,
		"segments_per_side": 3,
		"keep": null,
		"structures": [
			{"key": "workshop", "pos": Vector2(-1.5, -1.5), "yaw": 30.0, "s": 0.60},
			{"key": "granary", "pos": Vector2(2.0, -2.5), "yaw": 260.0, "s": 0.55},
			{"key": "small_house", "pos": Vector2(-3.5, 1.5), "yaw": 120.0, "s": 0.60},
		],
		"inner_walls": [],
		"inner_towers": [
			{"pos": Vector2(0.5, 6.5), "yaw": 0.0, "s": 0.85},
			{"pos": Vector2(-6.5, -7.6), "yaw": 0.0, "s": 0.85},
		],
		"fill": {"count": 18, "ring_band": [9.0, 13.0], "inner_band": [4.5, 8.5], "ring_share": 0.65, "scales": [0.48, 0.66], "mix": {"small_house": 5, "workshop": 5, "granary": 4, "medium_house": 2}},
		"roads": [],
		"field": null,
		"yard_r": 17.0,
	},
	{ # CITY C — Osaka-style castle: towering pyramid keep at the centre, open grounds, NO inner wall
		"name": "CITY C",
		"wall": {"key": "stone_wall", "scale": 0.86},
		"gates": [90.0, 270.0],
		"gate_scale": 1.40,
		"gate_inset": 1.0,
		"ring_r": 19.1,
		"segments_per_side": 3,
		"keep": {"key": "stronghold", "pos": Vector2(0.0, -1.0), "yaw": 15.0, "s": 1.7, "y": 1.25},
		"joint_towers": false,
		"corner_towers": false,
		"structures": [],
		"inner_walls": [],
		"inner_towers": [],
		"fill": {"count": 0, "ring_band": [12.5, 14.5], "inner_band": [12.5, 14.5], "ring_share": 1.0, "scales": [0.48, 0.62], "mix": {"small_house": 4, "granary": 3, "workshop": 3}},
		"roads": [
			{"pts": [Vector2(0.0, 14.2), Vector2(0.0, 9.0)], "width": 1.6},
			{"pts": [Vector2(0.0, -14.2), Vector2(0.0, -10.6)], "width": 1.6},
		],
		"field": null,
		"yard_r": 17.5,
	},
]

## Places one fortification segment on the hexagonal ring side facing `angle_deg`.
## `ring_r` is the ring's circumradius; `tangent_offset` slides the segment along
## the side (used for the 2-segments-per-side ring so junctions overlap).
static func _ring_segment(parent: Node3D, key: String, s: float, ring_r: float, angle_deg: float, stats: Dictionary, tangent_offset: float = 0.0, radial_offset: float = 0.0) -> void:
	var a := deg_to_rad(angle_deg)
	var n := Vector2(cos(a), sin(a))
	var center := n * (ring_r * 0.8660254)
	var tangent := Vector2(-sin(a), cos(a))
	center += tangent * tangent_offset + n * radial_offset
	var yaw := rad_to_deg(atan2(-tangent.y, tangent.x))
	_add_asset(parent, key, center, yaw, s, 1.0, stats)

## Places one complete hexagonal ring: `segments_per_side` slots per side, the
## gatehouse centred in the MIDDLE slot of every gate side, plus optional
## junction/corner watchtowers. `ring` keys:
##   key, scale, ring_r, segments_per_side, gates, gate_scale,
##   joint_towers (bool), joint_tower_scale, joint_tower_inset,
##   corner_towers (bool), corner_tower_scale
static func _ring(parent: Node3D, ring: Dictionary, stats: Dictionary) -> void:
	var key: String = String(ring["key"])
	var s: float = float(ring["scale"])
	var ring_r: float = float(ring["ring_r"])
	var per_side: int = int(ring.get("segments_per_side", 1))
	var gates: Array = ring.get("gates", [])
	var gate_scale: float = float(ring.get("gate_scale", 0.9))
	var mid_slot: int = (per_side - 1) / 2
	for i in range(6):
		var theta: float = 30.0 + 60.0 * float(i)
		var is_gate: bool = false
		for g in gates:
			if absf(theta - float(g)) < 1.0:
				is_gate = true
				break
		for slot in range(per_side):
			var off: float = (float(slot) - float(per_side - 1) * 0.5) * (ring_r / float(per_side))
			if is_gate and per_side % 2 == 1 and slot == mid_slot:
				_ring_segment(parent, "gatehouse", gate_scale, ring_r, theta, stats, off, -float(ring.get("gate_inset", 0.0)))
			else:
				_ring_segment(parent, key, s, ring_r, theta, stats, off)
	# junction towers between the slots of each side (offsets ring_r/6 — the slot
	# boundaries for segments_per_side = 3)
	if bool(ring.get("joint_towers", false)):
		var jt_scale: float = float(ring.get("joint_tower_scale", 0.85))
		var jt_inset: float = float(ring.get("joint_tower_inset", 0.6))
		for i in range(6):
			var theta2: float = 30.0 + 60.0 * float(i)
			var a2 := deg_to_rad(theta2)
			var n2 := Vector2(cos(a2), sin(a2))
			var t2 := Vector2(-sin(a2), cos(a2))
			var mid2: Vector2 = n2 * (ring_r * 0.8660254)
			for sgn in [-1.0, 1.0]:
				var jpos: Vector2 = mid2 + t2 * (sgn * ring_r / 6.0) - n2 * jt_inset
				_add_asset(parent, "watchtower", jpos, theta2, jt_scale, 1.0, stats)
	# corner towers at the six ring vertices
	if bool(ring.get("corner_towers", false)):
		var ct_scale: float = float(ring.get("corner_tower_scale", 0.65))
		for k in range(6):
			var vang: float = 60.0 * float(k)
			var vpos: Vector2 = Vector2(cos(deg_to_rad(vang)), sin(deg_to_rad(vang))) * (ring_r - 0.9)
			_add_asset(parent, "watchtower", vpos, vang, ct_scale, 1.0, stats)

## OBB vs OBB overlap in the XZ plane (separating-axis). Returns
## {hit, depth, axis}; axis points from A toward B.
static func _obb_overlap(pa: Vector2, ya: float, ha: Vector2, pb: Vector2, yb: float, hb: Vector2) -> Dictionary:
	var exa := Vector2(cos(ya), -sin(ya))
	var eza := Vector2(sin(ya), cos(ya))
	var exb := Vector2(cos(yb), -sin(yb))
	var ezb := Vector2(sin(yb), cos(yb))
	var d := pb - pa
	var best := INF
	var best_axis := Vector2.ZERO
	for axis in [exa, eza, exb, ezb]:
		var ra: float = absf(axis.dot(exa)) * ha.x + absf(axis.dot(eza)) * ha.y
		var rb: float = absf(axis.dot(exb)) * hb.x + absf(axis.dot(ezb)) * hb.y
		var overlap: float = ra + rb - absf(d.dot(axis))
		if overlap <= 0.0:
			return {"hit": false, "depth": 0.0, "axis": Vector2.ZERO}
		if overlap < best:
			best = overlap
			best_axis = axis if d.dot(axis) >= 0.0 else -axis
	return {"hit": true, "depth": best, "axis": best_axis}

static func _relax_structures(entries: Array, inner_apothem: float) -> int:
	## Exact clamp against the 6 inner wall planes (rect support projection) +
	## pairwise OBB separation; deterministic, presentation-only.
	for it in range(60):
		for e in entries:
			if bool(e.get("fixed", false)):
				continue
			var pos: Vector2 = e["pos"]
			var yaw: float = deg_to_rad(float(e["yaw"]))
			var half: Vector2 = e["half"]
			var ex := Vector2(cos(yaw), -sin(yaw))
			var ez := Vector2(sin(yaw), cos(yaw))
			for i in range(6):
				var ang: float = deg_to_rad(30.0 + 60.0 * float(i))
				var n := Vector2(cos(ang), sin(ang))
				var sup: float = absf(n.dot(ex)) * half.x + absf(n.dot(ez)) * half.y
				var d: float = pos.dot(n) + sup
				if d > inner_apothem:
					pos -= n * (d - inner_apothem)
			e["pos"] = pos
		for i in range(entries.size()):
			for j in range(i + 1, entries.size()):
				var a: Dictionary = entries[i]
				var b: Dictionary = entries[j]
				var ov := _obb_overlap(a["pos"], deg_to_rad(float(a["yaw"])), a["half"], b["pos"], deg_to_rad(float(b["yaw"])), b["half"])
				if ov["hit"]:
					var push: Vector2 = ov["axis"] * (float(ov["depth"]) * 0.42)
					var a_fixed: bool = bool(a.get("fixed", false))
					var b_fixed: bool = bool(b.get("fixed", false))
					if a_fixed and b_fixed:
						pass
					elif a_fixed:
						b["pos"] = (b["pos"] as Vector2) + push * 2.0
					elif b_fixed:
						a["pos"] = (a["pos"] as Vector2) - push * 2.0
					else:
						a["pos"] = (a["pos"] as Vector2) - push
						b["pos"] = (b["pos"] as Vector2) + push
	var residual := 0
	for i in range(entries.size()):
		for j in range(i + 1, entries.size()):
			var a: Dictionary = entries[i]
			var b: Dictionary = entries[j]
			var ov := _obb_overlap(a["pos"], deg_to_rad(float(a["yaw"])), a["half"], b["pos"], deg_to_rad(float(b["yaw"])), b["half"])
			if ov["hit"] and float(ov["depth"]) > 0.10:
				residual += 1
				print("[relax] residual overlap: ", a["key"], "@", a["pos"], " vs ", b["key"], "@", b["pos"], " depth=", snappedf(float(ov["depth"]), 0.001))
	return residual

static func _field_patch(parent: Node3D, f: Dictionary) -> void:
	var fc: Vector2 = f["center"]
	var fr: float = float(f["r"])
	_hex_disc(parent, fr, 0.020, Lib.COL_FIELD)
	var strips := 4
	for i in range(strips):
		var xo: float = -fr * 0.5 + fr * 1.0 * float(i) / float(strips - 1)
		var strip := BoxMesh.new()
		strip.size = Vector3(0.40, 0.012, fr * 1.0)
		var mi := MeshInstance3D.new()
		mi.mesh = strip
		mi.material_override = _solid_mat(Lib.COL_FIELD_EDGE)
		mi.position = Vector3(fc.x + xo, 0.028, fc.y)
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		parent.add_child(mi)

static func build_city(variant: int, seed: int) -> Dictionary:
	var spec: Dictionary = CITY_SPECS[variant]
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var root := Node3D.new()
	root.name = "Composition_" + String(spec["name"]).replace(" ", "_")
	var stats := {"name": spec["name"], "placed": {}, "triangles": 0, "max_violation": 0.0, "skipped": 0, "overlaps": 0, "spec": {"structures": (spec["structures"] as Array).size(), "walls": 6 * int(spec.get("segments_per_side", 1)) - (spec.get("gates", []) as Array).size()}}

	_hex_disc(root, float(spec["yard_r"]), 0.012, Lib.COL_VILLAGE_YARD)
	if spec["field"] != null:
		_field_patch(root, spec["field"])

	var roads: Array = spec.get("roads", [])
	var road_polys: Array = []
	for rd in roads:
		var rp := PackedVector2Array(rd["pts"])
		road_polys.append(rp)
		_ribbon(root, rp, float(rd["width"]) * 1.6, Lib.COL_ROAD_EDGE, 0.026)
		_ribbon(root, rp, float(rd["width"]), Lib.COL_ROAD, 0.034)

	# outer wall ring (ring helper below): every hex side is divided into
	# `segments_per_side` slots; gate sides carry the gatehouse in the MIDDLE
	# slot (centred main gate). An optional inner castle ring comes from the spec.
	var wall: Dictionary = spec["wall"]
	var wb: Dictionary = Lib.bounds(String(wall["key"]))
	var per_side: int = int(spec.get("segments_per_side", 1))
	var ring_r: float = float(spec.get("ring_r", 0.0))
	if ring_r <= 0.0:
		ring_r = (wb["max"].x - wb["min"].x) * float(wall["scale"]) * float(spec.get("fill", 0.90))
	var w_depth: float = wb["max"].z - wb["min"].z
	var inner_clear: float = ring_r * 0.8660254 - w_depth * float(wall["scale"]) * 0.5 - 0.15
	var outer_ring := {
		"key": String(wall["key"]), "scale": float(wall["scale"]), "ring_r": ring_r,
		"segments_per_side": per_side, "gates": spec.get("gates", []),
		"gate_scale": float(spec.get("gate_scale", 0.9)),
		"gate_inset": float(spec.get("gate_inset", 0.0)),
		"joint_towers": bool(spec.get("joint_towers", true)), "joint_tower_scale": float(spec.get("joint_tower_scale", 0.85)),
		"joint_tower_inset": 0.6,
		"corner_towers": bool(spec.get("corner_towers", true)), "corner_tower_scale": float(spec.get("joint_tower_scale", 0.85)),
	}
	_ring(root, outer_ring, stats)
	if spec.get("inner_ring", null) != null:
		_ring(root, spec["inner_ring"], stats)

	# interior: keep + structures + inner wall arc + inner watchtowers + procedural
	# courtyard fill, all relaxed together (exact wall-plane clamp + OBB separation)
	var entries: Array = []
	if spec.get("keep", null) != null:
		var k: Dictionary = spec["keep"]
		var kk: String = String(k.get("key", "hill_fort"))
		var kb: Dictionary = Lib.bounds(kk)
		var kh := Vector2((kb["max"].x - kb["min"].x) * 0.5, (kb["max"].z - kb["min"].z) * 0.5) * float(k["s"])
		entries.append({"key": kk, "pos": k["pos"], "yaw": float(k["yaw"]), "s": float(k["s"]), "y": float(k.get("y", 1.0)), "half": kh, "circ": sqrt(kh.x * kh.x + kh.y * kh.y)})
	for st in spec["structures"]:
		var key := String(st["key"])
		var sb: Dictionary = Lib.bounds(key)
		var half := Vector2((sb["max"].x - sb["min"].x) * 0.5, (sb["max"].z - sb["min"].z) * 0.5) * float(st["s"])
		entries.append({"key": key, "pos": st["pos"], "yaw": float(st["yaw"]), "s": float(st["s"]), "half": half, "circ": sqrt(half.x * half.x + half.y * half.y)})
	for iw in spec.get("inner_walls", []):
		var ia: float = deg_to_rad(float(iw["angle"]))
		var i_center: Vector2 = Vector2(cos(ia), sin(ia)) * (float(iw["ring_r"]) * 0.8660254)
		i_center += Vector2(-sin(ia), cos(ia)) * float(iw.get("offset", 0.0))
		var ib: Dictionary = Lib.bounds("stone_wall")
		var ih := Vector2((ib["max"].x - ib["min"].x) * 0.5, (ib["max"].z - ib["min"].z) * 0.5) * float(iw["s"])
		entries.append({"key": "stone_wall", "pos": i_center, "yaw": rad_to_deg(atan2(-cos(ia), -sin(ia))), "s": float(iw["s"]), "half": ih, "circ": sqrt(ih.x * ih.x + ih.y * ih.y)})
	for it in spec.get("inner_towers", []):
		var tb: Dictionary = Lib.bounds("watchtower")
		var th := Vector2((tb["max"].x - tb["min"].x) * 0.5, (tb["max"].z - tb["min"].z) * 0.5) * float(it["s"])
		entries.append({"key": "watchtower", "pos": it["pos"], "yaw": float(it["yaw"]), "s": float(it["s"]), "half": th, "circ": sqrt(th.x * th.x + th.y * th.y)})
	# procedural courtyard fill (deterministic, seeded): buildings line the walls
	# (ring band) plus a looser inner band; the gate corridor stays clear
	var fill: Dictionary = spec.get("fill", {})
	for i in range(int(fill.get("count", 0))):
		var f_key: String = _weighted_pick(rng, fill["mix"])
		var f_s: float = rng.randf_range(float(fill["scales"][0]), float(fill["scales"][1]))
		var f_pos := Vector2.ZERO
		var ok := false
		for attempt in range(10):
			var use_ring: bool = rng.randf() < float(fill.get("ring_share", 0.6))
			var band: Array = fill["ring_band"] if use_ring else fill["inner_band"]
			var f_r: float = rng.randf_range(float(band[0]), float(band[1]))
			var f_a: float = rng.randf() * TAU
			f_pos = Vector2(cos(f_a), sin(f_a)) * f_r
			var min_road := 1e9
			for rp2 in road_polys:
				min_road = minf(min_road, _dist_to_polyline(f_pos, rp2))
			if min_road >= 2.1:
				ok = true
				break
		if not ok:
			continue
		var f_yaw: float = rng.randf_range(0.0, 360.0)
		var fb: Dictionary = Lib.bounds(f_key)
		var fh := Vector2((fb["max"].x - fb["min"].x) * 0.5, (fb["max"].z - fb["min"].z) * 0.5) * f_s
		entries.append({"key": f_key, "pos": f_pos, "yaw": f_yaw, "s": f_s, "half": fh, "circ": sqrt(fh.x * fh.x + fh.y * fh.y)})
	stats["overlaps"] = _relax_structures(entries, inner_clear)
	for e in entries:
		_add_asset(root, String(e["key"]), e["pos"], float(e["yaw"]), float(e["s"]), float(e.get("y", 1.0)), stats)

	return {"root": root, "stats": stats}

## Shortest distance from a point to a polyline (used to keep gate corridors clear).
static func _dist_to_polyline(p: Vector2, pts: PackedVector2Array) -> float:
	var best := 1e9
	for i in range(pts.size() - 1):
		var a: Vector2 = pts[i]
		var b: Vector2 = pts[i + 1]
		var ab: Vector2 = b - a
		var t: float = clampf((p - a).dot(ab) / maxf(ab.length_squared(), 0.0001), 0.0, 1.0)
		best = minf(best, p.distance_to(a + ab * t))
	return best

## ---- RIVER / WATER CROSSING ---------------------------------------------------
static func build_river(key: String, yaw_deg: float = 0.0) -> Dictionary:
	var root := Node3D.new()
	root.name = "Composition_River_" + key
	var b: Dictionary = Lib.bounds(key)
	var half: Vector2 = b["half_xz"]
	var sx: float = HEX_HALF_W / half.x
	var sz: float = HEX_HALF_H / half.y
	var wrap := Node3D.new()
	wrap.name = "RiverMesh"
	wrap.rotation.y = deg_to_rad(yaw_deg)
	wrap.scale = Vector3(sx, sx * 0.90, sz)
	wrap.add_child(Lib.instance_centered(key))
	root.add_child(wrap)
	var stats := {
		"name": "River " + key,
		"placed": {key: 1},
		"triangles": Lib.triangles(key),
		"max_violation": 0.0,
		"skipped": 0,
		"overlaps": 0,
	}
	return {"root": root, "stats": stats}

## ---- OPEN PLAIN ---------------------------------------------------------------
static func build_plain(variant: int, seed: int) -> Dictionary:
	var root := Node3D.new()
	root.name = "Composition_Plain_%d" % variant
	var stats := {"name": "Plain %d" % variant, "placed": {}, "triangles": 0, "max_violation": 0.0, "skipped": 0, "overlaps": 0}
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	if variant == 0:
		pass
	elif variant == 1:
		var p := Vector2(rng.randf_range(-8.0, 8.0), rng.randf_range(-6.0, 6.0))
		var tree_key := "wind_pine" if rng.randf() < 0.5 else "broadleaf"
		_add_asset(root, tree_key, p, rng.randf_range(0.0, 360.0), rng.randf_range(0.48, 0.65), 1.0, stats)
	elif variant == 2:
		for i in range(rng.randi_range(2, 3)):
			var p := Vector2(rng.randf_range(-10.0, 10.0), rng.randf_range(-8.0, 8.0))
			var k := "sapling" if rng.randf() < 0.6 else "dead_tree"
			_add_asset(root, k, p, rng.randf_range(0.0, 360.0), rng.randf_range(0.45, 0.60), 1.0, stats)
	elif variant == 3:
		var p := Vector2(rng.randf_range(-7.0, 7.0), rng.randf_range(-6.0, 6.0))
		_add_asset(root, "compact_pine", p, rng.randf_range(0.0, 360.0), 0.52, 1.0, stats)
	return {"root": root, "stats": stats}
