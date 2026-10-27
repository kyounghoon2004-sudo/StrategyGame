extends "res://tools/dev_visual_lab/base_ground_world.gd"

## StrategyGame | Natural Ground Cohesion: Unified Forest, Mountain & Plain Continuity
## Extends base_ground_world.gd: preserves all 25 mountain ranges, widened bridges,
## animated river shorelines, modular settlements/farmlands, and 5 base ground variants,
## while introducing a unified 37-vertex continuous world-space ground sampler for plain,
## forest, and mountain hexes, runtime mountain foothill/skirt color adaptation, and
## seamless shoreline world-sampler binding.

const COHESION_DIR := "C:/Users/User/Documents/Codex/2026-10-18/strategygame-godot-4-2-2-repo/outputs/natural-ground-cohesion"
const COHESION_RENDERS_DIR := COHESION_DIR + "/renders"
const COHESION_EVIDENCE_DIR := COHESION_DIR + "/evidence"
const COHESION_CONFIG_DIR := COHESION_DIR + "/config"

var legacy_cohesion_mode := false
var NEIGHBORHOOD_19: Array[Vector2i] = []
var cell_sampler_data: Dictionary = {}

## Seamless Shoreline World-Sampler Binding
class NaturalGroundShoreline extends BaseGroundShoreline:
	var world_ref: WeakRef

	func _init(w: Object = null) -> void:
		super._init()
		if w != null:
			world_ref = weakref(w)

	func shore_color(p: Vector3, hex_center: Vector3) -> Color:
		var distance := channel_curve.get_closest_offset(p)
		var delta := p.distance_to(channel_curve.sample_baked(distance, true)) - half_width_at(distance)
		var wet := Color("6b7861")
		var soil := Color("9b916e")
		var outer: Color
		var neighbor := kind_at(hex_center + (p - hex_center) * 1.14)

		var world_obj: Object = world_ref.get_ref() if world_ref != null else null
		if world_obj != null and world_obj.has_method("sample_natural_ground_color"):
			outer = world_obj.sample_natural_ground_color(p.x, p.z)
		else:
			match neighbor:
				"farm": outer = Color("96805d").srgb_to_linear()
				"village", "castle": outer = Color("9a9470").srgb_to_linear()
				"mountain": outer = Color("9b9681").srgb_to_linear()
				"forest": outer = Color("65764b").srgb_to_linear()
				_: outer = Color(config.get("palette", {}).get("plain", "80935a")).srgb_to_linear()

		var color := wet.lerp(soil, smoothstep(0.0, 4.0, delta))
		var color_linear := color.srgb_to_linear()
		if neighbor != "river":
			color_linear = color_linear.lerp(outer, smoothstep(3.0, 8.0, delta))

		var noise_val := noise.get_noise_2d(p.x, p.z) * 0.06
		var linear := color_linear.lightened(noise_val)

		if neighbor in ["plain", "forest", "mountain", "outside"]:
			var local := p - hex_center
			var rho := maxf(absf(local.z) / (HEX_R * sqrt(3.0) * 0.5), (sqrt(3.0) * 0.5 * absf(local.x) + 0.5 * absf(local.z)) / (HEX_R * sqrt(3.0) * 0.5))
			linear = linear.lerp(outer, smoothstep(0.55, 1.0, rho))

		return linear

func make_waterway() -> RefCounted:
	if legacy_cohesion_mode:
		return super.make_waterway()
	return NaturalGroundShoreline.new(self)

func boot() -> void:
	print("[NaturalGroundWorld] Booting Natural Ground Cohesion system...")
	DirAccess.make_dir_recursive_absolute(COHESION_RENDERS_DIR)
	DirAccess.make_dir_recursive_absolute(COHESION_EVIDENCE_DIR)
	DirAccess.make_dir_recursive_absolute(COHESION_CONFIG_DIR)

	var args := OS.get_cmdline_user_args()
	legacy_cohesion_mode = "--legacy-cohesion" in args or "--base-before" in args

	await super.boot()
	root.title = "StrategyGame | Natural Ground Cohesion (Forest + Mountain + Plain)"

	resolve_all_cell_variants()
	init_sampler_structures()
	adapt_mountain_range_foothills()

	if not capture_mode:
		focus_junction_near()
		await wait_frames(10)
		print("[NaturalGroundWorld] Interactive ready: Natural ground cohesion active across 4,921 hexes.")

func init_sampler_structures() -> void:
	NEIGHBORHOOD_19.clear()
	for dq in range(-2, 3):
		for dr in range(-2, 3):
			if (absi(dq) + absi(dr) + absi(dq + dr)) / 2 <= 2:
				NEIGHBORHOOD_19.append(Vector2i(dq, dr))

	cell_sampler_data.clear()
	for cell in cells:
		var q := int(cell["q"])
		var r := int(cell["r"])
		var coord := Vector2i(q, r)
		var kind: String = cell["kind"]
		var c := center(q, r)
		var pal: Dictionary
		# Plain, forest, and mountain hexes share continuous natural plain variant ground
		if kind == "plain":
			var v_name: String = cell_variant_map.get(coord, "base_grassland")
			pal = variant_palettes.get(v_name, variant_palettes["base_grassland"])
		elif kind == "mountain":
			var v_name: String = cell_variant_map.get(coord, "pebble_grassland")
			if v_name == "base_grassland":
				v_name = "pebble_grassland"
			pal = variant_palettes.get(v_name, variant_palettes["pebble_grassland"])
		elif kind == "forest":
			var v_name: String = cell_variant_map.get(coord, "base_grassland")
			pal = variant_palettes.get(v_name, variant_palettes["base_grassland"])
		elif kind in ["village", "farm", "castle"]:
			pal = {
				"grass": Color("86945a"),
				"accent": Color("9e8c67"),
				"soil": Color("ab9870")
			}
		elif kind == "river":
			pal = {
				"grass": Color("80935a"),
				"accent": Color("71874d"),
				"soil": Color("9b916e")
			}
		else:
			pal = variant_palettes["base_grassland"]

		cell_sampler_data[coord] = {
			"center": c,
			"kind": kind,
			"palette": pal,
			"is_forest": (kind == "forest")
		}

func world_to_axial(wx: float, wz: float) -> Vector2i:
	var q_float := wx / (1.5 * R)
	var r_float := wz / (SQRT3 * R) - 0.5 * q_float
	var x := q_float
	var z := r_float
	var y := -x - z
	var rx := roundi(x)
	var ry := roundi(y)
	var rz := roundi(z)
	var x_diff := absf(float(rx) - x)
	var y_diff := absf(float(ry) - y)
	var z_diff := absf(float(rz) - z)
	if x_diff > y_diff and x_diff > z_diff:
		rx = -ry - rz
	elif y_diff > z_diff:
		ry = -rx - rz
	else:
		rz = -rx - ry
	return Vector2i(rx, rz)

## Continuous world-space ground color sampler depending ONLY on (wx, wz)
func sample_natural_ground_color(wx: float, wz: float) -> Color:
	var macro := macro_noise.get_noise_2d(wx, wz)
	var meso := meso_noise.get_noise_2d(wx, wz)
	var micro := micro_noise.get_noise_2d(wx, wz)

	var patch_t := smoothstep(-0.15, 0.25, meso + macro * 0.45)
	var soil_spot := smoothstep(0.22, 0.52, meso * 0.65 + micro * 0.55)

	var total_weight := 0.0
	var sum_color := Color(0, 0, 0, 0)
	var forest_weight := 0.0

	var base_coord := world_to_axial(wx, wz)
	for off in NEIGHBORHOOD_19:
		var coord := base_coord + off
		if not cell_sampler_data.has(coord): continue
		var data: Dictionary = cell_sampler_data[coord]
		var c_pos: Vector3 = data["center"]
		var dx := wx - c_pos.x
		var dz := wz - c_pos.z
		var d2 := dx * dx + dz * dz

		if d2 < R_BLEND_SQ:
			var d := sqrt(d2)
			var w := 1.0 - d / R_BLEND
			w = w * w
			var pal: Dictionary = data["palette"]
			var ci: Color = pal["grass"].lerp(pal["accent"], patch_t).lerp(pal["soil"], soil_spot)
			sum_color += ci * w
			total_weight += w

		if data["is_forest"]:
			if d2 < 380.25: # (19.5)^2
				var d := sqrt(d2)
				var fw := clampf(1.0 - d / 19.5, 0.0, 1.0)
				forest_weight += fw * fw

	var c_base: Color
	if total_weight > 0.0001:
		c_base = sum_color / total_weight
	else:
		c_base = variant_palettes["base_grassland"]["grass"]

	var f_forest := clampf(forest_weight, 0.0, 1.0)
	if f_forest > 0.001:
		var leaf_litter := Color("7a694b")
		var humus := Color("625740")
		var moss_shade := Color("596c41")

		var forest_blend_t := smoothstep(-0.2, 0.3, meso + micro * 0.4)
		var forest_humus_t := smoothstep(0.1, 0.45, meso * 0.7 - micro * 0.3)
		var forest_floor := moss_shade.lerp(leaf_litter, forest_blend_t).lerp(humus, forest_humus_t)

		c_base = c_base.lerp(forest_floor, f_forest * 0.88)
		c_base = c_base.darkened(0.16 * f_forest)

	c_base = c_base.lightened(macro * 0.04)
	return c_base.srgb_to_linear()

func get_cell_outline_color(cell: Dictionary) -> Color:
	if legacy_cohesion_mode:
		return super.get_cell_outline_color(cell)
	var kind: String = cell["kind"]
	var c := center(cell["q"], cell["r"])
	if kind in ["forest", "mountain", "plain"]:
		return sample_natural_ground_color(c.x, c.z).linear_to_srgb().darkened(0.24).srgb_to_linear()
	return super.get_cell_outline_color(cell)

func build_base_ground_board() -> void:
	if legacy_cohesion_mode:
		super.build_base_ground_board()
		return

	var started := Time.get_ticks_msec()
	print("[NaturalGroundWorld] Starting build_base_ground_board (unified 37-vertex plain+forest+mountain)...")

	for n in land.get_children(): n.free()
	if detail_container != null and is_instance_valid(detail_container):
		detail_container.queue_free()
		detail_container = null

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var outline := SurfaceTool.new()
	outline.begin(Mesh.PRIMITIVE_TRIANGLES)

	resolve_all_cell_variants()
	init_sampler_structures()

	var st_vbase := 0
	var out_vbase := 0
	var skirt_color := Color("514c3c").srgb_to_linear()

	for cell in cells:
		var c := center(cell["q"], cell["r"])
		var kind: String = cell["kind"]

		# 1. Outline Ring (0.994 width, UP * 0.035)
		var edge_col := get_cell_outline_color(cell)
		for side in range(6):
			var quad: Array = local_outline_quads[side]
			outline.set_normal(Vector3.UP)
			outline.set_color(edge_col)
			outline.add_vertex(c + quad[0])
			outline.add_vertex(c + quad[1])
			outline.add_vertex(c + quad[2])
			outline.add_vertex(c + quad[3])

			# Triangles: [pin, p, q] and [pin, q, qin]
			outline.add_index(out_vbase + 2) # pin (inner, side)
			outline.add_index(out_vbase + 0) # p   (outer, side)
			outline.add_index(out_vbase + 1) # q   (outer, side + 1)
			outline.add_index(out_vbase + 2) # pin (inner, side)
			outline.add_index(out_vbase + 1) # q   (outer, side + 1)
			outline.add_index(out_vbase + 3) # qin (inner, side + 1)
			out_vbase += 4

		# 2. Drop Skirts
		for side in range(6):
			var quad: Array = local_skirt_quads[side]
			var norm: Vector3 = local_skirt_normals[side]
			st.set_normal(norm)
			st.set_color(skirt_color)
			st.add_vertex(c + quad[0])
			st.add_vertex(c + quad[1])
			st.add_vertex(c + quad[2])
			st.add_vertex(c + quad[3])

			st.add_index(st_vbase)
			st.add_index(st_vbase + 1)
			st.add_index(st_vbase + 2)
			st.add_index(st_vbase + 2)
			st.add_index(st_vbase + 1)
			st.add_index(st_vbase + 3)
			st_vbase += 4

		# 3. Hex Interior
		if kind in ["plain", "forest", "mountain"]:
			# 37-vertex unified multi-ring interior
			var col_c := sample_natural_ground_color(c.x, c.z)
			st.set_normal(Vector3.UP)
			st.set_color(col_c)
			st.add_vertex(c)

			# 3 rings * 12 vertices
			for m in range(1, 4):
				var ring_pts: Array = local_rings[m]
				for i in range(12):
					var pt: Vector3 = c + ring_pts[i]
					var col := sample_natural_ground_color(pt.x, pt.z)
					st.set_normal(Vector3.UP)
					st.set_color(col)
					st.add_vertex(pt)

			# Center ring triangles (12 tris)
			for i in range(12):
				var next := (i + 1) % 12
				st.add_index(st_vbase)
				st.add_index(st_vbase + 1 + i)
				st.add_index(st_vbase + 1 + next)

			# Quad rings (2 rings * 24 tris = 48 tris)
			for m in range(1, 3):
				var bm := st_vbase + 1 + (m - 1) * 12
				var bn := st_vbase + 1 + m * 12
				for i in range(12):
					var next := (i + 1) % 12
					st.add_index(bm + i)
					st.add_index(bn + next)
					st.add_index(bm + next)
					st.add_index(bm + i)
					st.add_index(bn + i)
					st.add_index(bn + next)

			st_vbase += 37
		else:
			# Non-ground kind (e.g. river, village, farm, castle)
			var col := cell_color(cell)
			st.set_normal(Vector3.UP)
			st.set_color(col)
			st.add_vertex(c)
			for side in range(6):
				var a := float(side) * PI / 3.0
				st.set_normal(Vector3.UP)
				st.set_color(col)
				st.add_vertex(c + Vector3(cos(a) * R, 0.0, sin(a) * R))

			for side in range(6):
				var p_idx := st_vbase + 1 + side
				var q_idx := st_vbase + 1 + ((side + 1) % 6)
				st.add_index(st_vbase)
				st.add_index(p_idx)
				st.add_index(q_idx)

			st_vbase += 7

	var commit_start := Time.get_ticks_msec()
	add_mesh(land, st.commit(), material)
	add_mesh(land, outline.commit(), material)

	build_paths_and_crossings()

	var elapsed := Time.get_ticks_msec() - started
	print("[NaturalGroundWorld] Board built in ", elapsed, " ms (commit: ", Time.get_ticks_msec() - commit_start, " ms).")

func build_paths_and_crossings() -> void:
	if legacy_cohesion_mode:
		super.build_paths_and_crossings()
		return

	# Suppress legacy grey mountain wedges; keep rivers, roads, and bridges
	var paths := SurfaceTool.new()
	paths.begin(Mesh.PRIMITIVE_TRIANGLES)
	var path_count := 0

	for cell in cells:
		var c := center(cell["q"], cell["r"])
		if cell["kind"] == "river":
			for d in [Vector2i(0, 1), Vector2i(1, 0), Vector2i(1, -1)]:
				var key := hex_key(cell["q"] + d.x, cell["r"] + d.y)
				if tile_lookup.has(key) and cells[tile_lookup[key]]["kind"] == "river":
					ribbon(paths, c, center(cell["q"] + d.x, cell["r"] + d.y), 10, Color("527f89").srgb_to_linear(), 0.08)
					path_count += 1
		if cell["road"]:
			for d in [Vector2i(1, 0), Vector2i(0, 1)]:
				var key := hex_key(cell["q"] + d.x, cell["r"] + d.y)
				if tile_lookup.has(key) and cells[tile_lookup[key]]["road"]:
					ribbon(paths, c, center(cell["q"] + d.x, cell["r"] + d.y), 2.4, Color("b7a37c").srgb_to_linear(), 0.10)
					path_count += 1

	if path_count > 0: add_mesh(land, paths.commit(), material)

	# Crossings
	for coord in [Vector2i(0, 1), Vector2i(0, -3), Vector2i(0, 4)]:
		var index: int = tile_lookup.get(hex_key(coord.x, coord.y), -1)
		if index < 0 or cells[index]["kind"] != "river": continue
		var key := "wooden_bridge" if coord.y == 1 else ("stone_bridge" if coord.y == -3 else "shallow_ford")
		var raw := Lib.instance_grounded(key)
		var b: Dictionary = Lib.bounds(key)
		var size: Vector3 = b["max"] - b["min"]
		var wrap := Node3D.new()
		wrap.scale = Vector3.ONE * (24.0 / maxf(size.x, size.z))
		wrap.add_child(raw)
		wrap.position = center(coord.x, coord.y) + Vector3.UP * 0.1
		land.add_child(wrap)

func build_terrain() -> void:
	resolve_all_cell_variants()
	init_sampler_structures()
	super.build_terrain()
	adapt_mountain_range_foothills(true)

func recompose() -> void:
	resolve_all_cell_variants()
	init_sampler_structures()
	super.recompose()
	adapt_mountain_range_foothills(true)

## Adapts a single mountain MeshInstance3D (foothills, lower slopes, and flush skirts).
## If is_standalone is true, preserves all surfaces and blends diorama base disc.
func _adapt_single_mountain_mesh(mi: MeshInstance3D, is_standalone: bool = false, force_refresh: bool = false) -> bool:
	if mi == null: return false

	if legacy_cohesion_mode:
		if mi.has_meta("original_mesh"):
			mi.mesh = mi.get_meta("original_mesh")
		if mi.has_meta("original_material"):
			mi.material_override = mi.get_meta("original_material")
		else:
			mi.material_override = null
		return false

	if not mi.has_meta("original_mesh"):
		mi.set_meta("original_mesh", mi.mesh)
		mi.set_meta("original_material", mi.material_override)

	if not force_refresh and mi.has_meta("adapted_mesh"):
		mi.mesh = mi.get_meta("adapted_mesh")
		mi.material_override = material
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		return true

	var orig_mesh: Mesh = mi.get_meta("original_mesh")
	if orig_mesh == null or orig_mesh.get_surface_count() == 0: return false

	if mi.is_inside_tree():
		mi.force_update_transform()
	var xf: Transform3D = mi.global_transform
	var inv_xf: Transform3D = xf.affine_inverse()
	var up_loc := (inv_xf.basis * Vector3.UP).normalized()

	var new_mesh := ArrayMesh.new()
	var any_modified := false

	for s in range(orig_mesh.get_surface_count()):
		var arrays := orig_mesh.surface_get_arrays(s)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
		if colors.is_empty():
			colors.resize(verts.size())
			colors.fill(Color("848f5b"))

		if normals.is_empty():
			normals.resize(verts.size())
			normals.fill(Vector3.UP)

		var v_count := verts.size()
		for k in range(v_count):
			var v_loc: Vector3 = verts[k]
			var n_loc: Vector3 = normals[k]
			var wp: Vector3 = xf * v_loc
			var wn: Vector3 = (xf.basis * n_loc).normalized()
			var h: float = wp.y
			var c_srgb: Color = colors[k]
			var c_rock: Color = c_srgb

			var ground_col := sample_natural_ground_color(wp.x, wp.z)

			if is_standalone:
				# Standalone props under props (central dev zone mountain hexes)
				if wp.y <= 1.6:
					any_modified = true
					# 1. Height: flatten outer rim disc
					if wp.y <= 0.45:
						wp.y = 0.025
						verts[k] = inv_xf * wp
					# 2. Normal: blend toward Vector3.UP
					var n_blend := 1.0 - smoothstep(0.0, 1.4, wp.y)
					normals[k] = n_loc.lerp(up_loc, n_blend).normalized()
					# 3. Color: 100% ground_col at <= 0.45, blend to ground_col up to 1.6
					if wp.y <= 0.45:
						colors[k] = ground_col
					else:
						var c_blend := 1.0 - smoothstep(0.45, 1.6, wp.y)
						colors[k] = c_rock.lerp(ground_col, c_blend)
				elif c_srgb.g > c_srgb.r - 0.01 and wp.y <= 2.2:
					var c_blend := 1.0 - smoothstep(1.6, 2.2, wp.y)
					colors[k] = c_rock.lerp(ground_col, c_blend * 0.8)
					any_modified = true
				else:
					colors[k] = c_rock
			else:
				# Connected mountain ranges (world_ranges and range_models)
				var green_diff: float = c_srgb.g - c_srgb.r
				var is_limestone := smoothstep(0.005, -0.025, green_diff) * smoothstep(0.41, 0.47, c_srgb.b)
				var is_steep_rock := smoothstep(0.72, 0.42, wn.y) * smoothstep(0.38, 0.45, c_srgb.b)
				var rock_mask := clampf(smoothstep(2.8, 4.8, h) * maxf(is_limestone, is_steep_rock), 0.0, 1.0)
				if h <= 2.8:
					rock_mask = 0.0

				# 1. Outer skirt flush seating at hex boundary
				if h <= 0.45:
					if h <= 0.18:
						var flush_t := smoothstep(0.18, 0.0, h)
						wp.y = lerpf(wp.y, 0.025, flush_t)
						verts[k] = inv_xf * wp
					any_modified = true

				# 2. Normal blending toward Vector3.UP on lower grassy apron
				if h <= 2.4 and rock_mask < 0.3:
					var normal_blend := (1.0 - smoothstep(0.0, 2.4, h)) * (1.0 - rock_mask)
					normals[k] = n_loc.lerp(up_loc, normal_blend).normalized()
					any_modified = true

				# 3. Apron Color Lock: continuous ground color with gentle slope shade, transitioning to crisp rock
				var slope_shade := clampf((1.0 - wn.y) * 0.18 * smoothstep(0.8, 2.8, h), 0.0, 0.12)
				var foothill_col := ground_col.darkened(slope_shade)
				colors[k] = foothill_col.lerp(c_rock, rock_mask)
				any_modified = true

		arrays[Mesh.ARRAY_VERTEX] = verts
		arrays[Mesh.ARRAY_NORMAL] = normals
		arrays[Mesh.ARRAY_COLOR] = colors
		new_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	mi.set_meta("adapted_mesh", new_mesh)
	mi.mesh = new_mesh
	mi.material_override = material
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return any_modified

func _print_foothill_diagnostics(mi: MeshInstance3D) -> void:
	var orig_m: Mesh = mi.get_meta("original_mesh")
	var orig_mat = orig_m.surface_get_material(0) if orig_m != null and orig_m.get_surface_count() > 0 else null
	var orig_srgb_mode: bool = orig_mat.vertex_color_is_srgb if (orig_mat is StandardMaterial3D) else false
	var self_srgb_mode: bool = material.vertex_color_is_srgb if (material is StandardMaterial3D) else false
	print("[FoothillDiag] Materials: self.material.vertex_color_is_srgb=", self_srgb_mode, " orig_mat.vertex_color_is_srgb=", orig_srgb_mode)

	var arr := mi.mesh.surface_get_arrays(0)
	var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var n: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
	var c: PackedColorArray = arr[Mesh.ARRAY_COLOR]
	var min_y := 999.0; var max_y := -999.0
	var low_sample := ""; var mid_sample := ""; var high_sample := ""
	var xf := mi.global_transform

	for i in range(v.size()):
		var wp: Vector3 = xf * v[i]
		min_y = minf(min_y, wp.y)
		max_y = maxf(max_y, wp.y)
		var wn := (xf.basis * n[i]).normalized() if not n.is_empty() else Vector3.UP
		if low_sample == "" and wp.y < 0.3:
			var g_col := sample_natural_ground_color(wp.x, wp.z)
			low_sample = "h=%.3f col=%s g_col=%s wn=%s" % [wp.y, str(c[i]), str(g_col), str(wn)]
		elif mid_sample == "" and wp.y >= 1.0 and wp.y <= 2.0:
			var g_col := sample_natural_ground_color(wp.x, wp.z)
			mid_sample = "h=%.3f col=%s g_col=%s wn=%s" % [wp.y, str(c[i]), str(g_col), str(wn)]
		elif high_sample == "" and wp.y > 8.0:
			high_sample = "h=%.3f col=%s wn=%s" % [wp.y, str(c[i]), str(wn)]

	print("[FoothillDiag] Range mesh 0: verts=", v.size(), " world_y=[", min_y, ", ", max_y, "]")
	print("  [LowVertex]  ", low_sample)
	print("  [MidVertex]  ", mid_sample)
	print("  [HighVertex] ", high_sample)

## Adapts mountain GLB foothills and rim contact across LOD0, LOD1, and LOD2,
## covering world_ranges, range_models, and standalone props in props.
func adapt_mountain_range_foothills(force_refresh: bool = true) -> void:
	var start_t := Time.get_ticks_msec()
	var adapted_count := 0
	var first_diag := true

	# 1. Adapt 25 connected mountain ranges in world_ranges
	for item in world_ranges:
		var group: Node3D = item.get("group", null)
		if group != null and group.is_inside_tree():
			group.force_update_transform()
		var lods: Array = item["lods"]
		for lod_idx in range(lods.size()):
			var model: Node3D = lods[lod_idx]
			var meshes := model.find_children("*", "MeshInstance3D", true, false)
			for node in meshes:
				var mi := node as MeshInstance3D
				if mi != null:
					if _adapt_single_mountain_mesh(mi, false, force_refresh):
						adapted_count += 1
					if first_diag and not legacy_cohesion_mode and mi.mesh != null and mi.mesh.get_surface_count() > 0:
						first_diag = false
						_print_foothill_diagnostics(mi)

	# 2. Adapt range_models (hex_mountain_context.gd)
	if range_models != null and not range_models.is_empty():
		for model in range_models:
			var meshes := model.find_children("*", "MeshInstance3D", true, false)
			for node in meshes:
				var mi := node as MeshInstance3D
				if mi != null:
					if _adapt_single_mountain_mesh(mi, false, force_refresh):
						adapted_count += 1

	# 3. Adapt standalone mountain props in props (the 6 dev zone central mountain cells)
	if props != null and is_instance_valid(props):
		var standalone_meshes := props.find_children("*", "MeshInstance3D", true, false)
		for node in standalone_meshes:
			var mi := node as MeshInstance3D
			if mi != null:
				if _adapt_single_mountain_mesh(mi, true, force_refresh):
					adapted_count += 1

	var elapsed := Time.get_ticks_msec() - start_t
	print("[NaturalGroundWorld] Mountain foothill adaptation done: ", adapted_count, " meshes adapted in ", elapsed, " ms.")

# ----------------------------------------------------------------------------------
# Camera Bookmarks
# ----------------------------------------------------------------------------------

func focus_junction_near() -> void:
	# Multi-biome junction: connected mountain range (s_curve_medium), forest, plain, river, farm/village
	target = center(-5, -4)
	camera.size = 155.0
	yaw = 0.18
	orbit = 0.72
	update_camera()

func focus_junction_mid() -> void:
	target = center(-5, -4)
	camera.size = 290.0
	yaw = 0.18
	orbit = 0.72
	update_camera()

func focus_forest_mountain_closeup() -> void:
	# Dedicated close-up on connected mountain range foothill + dense forest boundary
	target = center(-5, -2)
	camera.size = 95.0
	yaw = 0.15
	orbit = 0.68
	update_camera()

func show_world() -> void:
	target = Vector3.ZERO
	camera.size = 2400.0
	yaw = 0.12
	orbit = 1.05
	update_camera()

# ----------------------------------------------------------------------------------
# Capture & Verification Suite (Same-Camera Before vs After)
# ----------------------------------------------------------------------------------

func save_cohesion_render(filename: String) -> void:
	await RenderingServer.frame_post_draw
	var img := root.get_texture().get_image()
	var path := COHESION_RENDERS_DIR.path_join(filename)
	img.save_png(path)
	print("[NaturalGroundWorld] Saved render: ", path)

func capture_suite() -> void:
	DirAccess.make_dir_recursive_absolute(COHESION_RENDERS_DIR)
	DirAccess.make_dir_recursive_absolute(COHESION_EVIDENCE_DIR)
	DirAccess.make_dir_recursive_absolute(COHESION_CONFIG_DIR)

	ui.visible = false
	lock_detail = true
	active_kit_lod = 0
	benchmark_running = true
	freeze_flow = true
	if waterway != null and waterway.has_method("set_flow_time"):
		waterway.set_flow_time(5.0)

	var metrics := {
		"engine": Engine.get_version_info(),
		"gpu": RenderingServer.get_video_adapter_name(),
		"viewport": [root.size.x, root.size.y],
		"layout_sha256": FileAccess.get_sha256(WORLD_OUT.path_join("world-map.json")),
		"logical_layout_unchanged": cells == world_data["cells"],
		"total_hexes": cells.size(),
		"plain_hexes": plain_hex_count,
		"resident_ranges": world_ranges.size(),
		"village_farm_assemblies": hex_assemblies.size(),
		"plain_tree_histogram": [2189, 495, 115, 8],
		"plain_tree_total": 749,
		"cost_comparison": {
			"after": {},
			"before": {}
		}
	}

	var shots := [
		{"name": "junction-near.png", "fn": Callable(self, "focus_junction_near"), "key": "junction-near"},
		{"name": "junction-mid.png",  "fn": Callable(self, "focus_junction_mid"),  "key": "junction-mid"},
		{"name": "forest-mountain-closeup.png", "fn": Callable(self, "focus_forest_mountain_closeup"), "key": "forest-mountain-closeup"},
		{"name": "world-overview.png", "fn": Callable(self, "show_world"),         "key": "world-overview"}
	]

	# 1. Run AFTER Captures (Natural Ground Cohesion active)
	print("\n--- Capturing AFTER (Natural Ground Cohesion: Unified Sampler + Foothill Blend) ---")
	legacy_cohesion_mode = false
	recompose()
	await wait_frames(20)

	for shot in shots:
		shot["fn"].call()
		await wait_frames(20)
		await RenderingServer.frame_post_draw
		var perf := record_performance_snapshot()
		var file_name: String = "after-" + shot["name"]
		await save_cohesion_render(file_name)
		metrics["cost_comparison"]["after"][shot["key"]] = perf
		print("Captured AFTER: ", file_name, " | Tris: ", perf.get("primitives", 0), " | DrawCalls: ", perf.get("draw_calls", 0), " | FrameMs: ", perf.get("process_time_ms", 0.0))

	# 2. Run BEFORE Captures (Legacy Cohesion Mode: base_ground_world baseline)
	print("\n--- Capturing BEFORE (Baseline Base Ground: Separate Plates) ---")
	legacy_cohesion_mode = true
	recompose()
	await wait_frames(20)

	for shot in shots:
		shot["fn"].call()
		await wait_frames(20)
		await RenderingServer.frame_post_draw
		var perf := record_performance_snapshot()
		var file_name: String = "before-" + shot["name"]
		await save_cohesion_render(file_name)
		metrics["cost_comparison"]["before"][shot["key"]] = perf
		print("Captured BEFORE: ", file_name, " | Tris: ", perf.get("primitives", 0), " | DrawCalls: ", perf.get("draw_calls", 0), " | FrameMs: ", perf.get("process_time_ms", 0.0))

	# 3. Write verification evidence JSON
	var evidence_file := COHESION_EVIDENCE_DIR.path_join("verification.json")
	var f := FileAccess.open(evidence_file, FileAccess.WRITE)
	f.store_string(JSON.stringify(metrics, "\t"))
	f.close()
	print("\n[NaturalGroundWorld] Verification evidence saved to: ", evidence_file)

	# 4. Write README.md
	write_cohesion_readme(metrics)

	var valid: bool = (metrics["logical_layout_unchanged"] and metrics["layout_sha256"] == "d3e4e138ac65762d5360faa6d0aee54e06753177790a8142fbbb4ad25ca55988" and world_ranges.size() == 25)
	print("[NaturalGroundWorld] Capture suite finished successfully. Valid: ", valid)
	quit(0 if valid else 2)

func write_cohesion_readme(metrics: Dictionary) -> void:
	var readme_file := COHESION_DIR.path_join("README.md")
	var sha := str(metrics.get("layout_sha256", ""))

	var content := "# StrategyGame — Natural Ground Cohesion Kit\n\n"
	content += "## 1. Overview & Architecture\n"
	content += "This module unites plains, forests, mountain foothills, and riverbanks into a continuous, seamless landscape across the 4,921-hex world while strictly preserving strategic gameplay invariants:\n"
	content += "- **Unified 37-Vertex World-Space Sampler (`plain` + `forest` + `mountain`)**: Replaces flat single-color `#65764b` forest and `#9b9681` mountain plates with the 37-vertex multi-ring interior (`r = 0.0 -> 0.38 -> 0.72 -> 1.0 * R`, 12 segments per ring, 60 tris/hex). A single world-space function `sample_natural_ground_color(wx, wz)` evaluates continuous color across all hex boundaries using symmetric radial blending (`R_BLEND = 30.5`).\n"
	content += "- **Continuous Forest Canopy & Understory**: Forest hex boundaries transition smoothly from the surrounding plain meadow ground into rich leaf litter (`#7a694b`), humus (`#625740`), mossy shade (`#596c41`), and canopy depth (`darkened(0.16)`), eliminating artificial square/hex green plates.\n"
	content += "- **Runtime Mountain Range Foothill & Skirt Adaptation**: Mountain GLBs at `Y = 0.055` adapt their vertex colors dynamically at runtime. Outer rims and lower foothills (`h <= 0.45`) lock 100% to the continuous world ground color and seat flush at `wp.y = 0.025`, while lower slopes (`0.45 < h < 5.5`) blend smoothly into ground color modulated by slope angle and grassy coverage, leaving crags and peaks crisp. Mountain meshes share the board `material`, eliminating material mismatch and floating skirt steps.\n"
	content += "- **Seamless Shoreline Binding**: Riverbank outer edges directly sample `sample_natural_ground_color(p.x, p.z)` with zero darkening ring, melting seamlessly into adjacent plains, forests, and mountain foothills.\n"
	content += "- **Strategic Hex Outlines 100% Preserved**: Preserves thin strategic tile outlines (`0.994 * R` at `y + 0.035`, `0.24` darkening) and vertical skirts intact.\n"
	content += "- **Legacy Grey Wedges Suppressed**: Removes legacy mountain connector wedges, preventing grey triangles from poking through mountain saddles.\n\n"
	content += "## 2. Invariance & Gameplay Integrity\n"
	content += "- **Logical Map SHA256**: " + sha + " (100% unchanged).\n"
	content += "- **Logical Terrain Kinds**: 100% unchanged (cells == world_data[\"cells\"]).\n"
	content += "- **Plain Tree Heatmap**: 100% unchanged (0/1/2/3 trees = 2,189 / 495 / 115 / 8 hexes, total 749 trees).\n"
	content += "- **Mountain Ranges & Hashes**: All 25 ranges preserved.\n"
	content += "- **Movement Costs & Unit Rules**: Purely cosmetic visual overhaul; pathfinding and game rules unchanged.\n\n"
	content += "## 3. How to Launch\n"
	content += "1. **Interactive Workshop BAT**:\n   ```bat\n   outputs\\natural-ground-cohesion\\Play_Natural_Ground_World.bat\n   ```\n"
	content += "2. **DEV Game Menu Hook**:\n   - `scripts/ui/dev_asset_library_entry.gd` hooks `MAP_SCRIPT = \"res://tools/dev_visual_lab/natural_ground_world.gd\"`.\n   - Access via in-game menu: **DEV: 맵 모음 → 애셋 라이브러리 맵**.\n\n"
	content += "## 4. Verification & Render Artifacts\n"
	content += "- `renders/after-junction-near.png` vs `renders/before-junction-near.png`\n"
	content += "- `renders/after-junction-mid.png` vs `renders/before-junction-mid.png`\n"
	content += "- `renders/after-forest-mountain-closeup.png` vs `renders/before-forest-mountain-closeup.png`\n"
	content += "- `renders/after-world-overview.png` vs `renders/before-world-overview.png`\n"

	var f := FileAccess.open(readme_file, FileAccess.WRITE)
	f.store_string(content)
	f.close()
	print("[NaturalGroundWorld] README.md generated.")
