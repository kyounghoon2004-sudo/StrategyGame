class_name HexForestCompositor
extends RefCounted

## HexForestCompositor — contained per-cell woodland grammar.
## Each forest cell receives one bounded, multi-tier composition.
## Every sprite is strictly contained inside the inset hex polygon (s_inset = 0.90)
## with zero overflow across cell boundaries into adjacent hexes.

const Registry = preload("res://scripts/visual/hex_native/approved_asset_registry.gd")
const LayerCls = preload("res://scripts/visual/hex_native/approved_owned_terrain_layer.gd")

# Canonical flat-top hexagon vertices (W=48, H=42, Center at origin)
const CANONICAL_VERTICES: Array[Vector2] = [
	Vector2(-24.0, 0.0),    # V0: West
	Vector2(-12.0, -21.0),  # V1: North-West
	Vector2(12.0, -21.0),   # V2: North-East
	Vector2(24.0, 0.0),     # V3: East
	Vector2(12.0, 21.0),    # V4: South-East
	Vector2(-12.0, 21.0)    # V5: South-West
]

# Canonical Directions clockwise from East:
# Index 0: E  (1, 0)   -> pixel (+36, +21)
# Index 1: NE (1, -1)  -> pixel (+36, -21)
# Index 2: NW (0, -1)  -> pixel (0, -42)
# Index 3: W  (-1, 0)  -> pixel (-36, -21)
# Index 4: SW (-1, 1)  -> pixel (-36, +21)
# Index 5: SE (0, 1)   -> pixel (0, +42)
const DIRECTIONS: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(1, -1), Vector2i(0, -1),
	Vector2i(-1, 0), Vector2i(-1, 1), Vector2i(0, 1),
]

# Midpoint vectors for the 6 hex edges (from center Vector2.ZERO)
const EDGE_MIDPOINTS: Array[Vector2] = [
	Vector2(18.0, 10.5),   # 0: E
	Vector2(18.0, -10.5),  # 1: NE
	Vector2(0.0, -21.0),   # 2: NW (flat-top edge)
	Vector2(-18.0, -10.5), # 3: W
	Vector2(-18.0, 10.5),  # 4: SW
	Vector2(0.0, 21.0)     # 5: SE (flat-bottom edge)
]

# Inset scale factor for safe vegetation containment
# Leaves a ~2.0 px safety margin inside the true hex boundary
const INSET_SCALE: float = 0.90
const FLOOR_SCALE: float = 0.82
const INNER_FLOOR_SCALE: float = 0.50

static func _hash2(q: int, r: int, salt: int) -> int:
	return absi((q * 73856093) ^ (r * 19349663) ^ (salt * 83492791))

static func _bitcount(mask: int) -> int:
	var count: int = 0
	for i in range(6):
		if (mask & (1 << i)) != 0:
			count += 1
	return count

# ==============================================================================
# ANALYTICAL HEX CONTAINMENT SOLVER
# ==============================================================================

## Computes the exact closed-form maximum allowable scale for a sprite placed
## at `contact` such that its 2D bounding box is strictly within the inset hex.
## The flat-top hexagon is defined by 6 half-planes:
## 1. Top: y >= -y_max
## 2. Bottom: y <= y_max
## 3. Top-Right: 7x - 4y <= C
## 4. Bottom-Right: 7x + 4y <= C
## 5. Bottom-Left: -7x + 4y <= C
## 6. Top-Left: -7x - 4y <= C
static func compute_max_scale(contact: Vector2, w_left: float, w_right: float, h_top: float, h_bottom: float, s_inset: float = INSET_SCALE) -> float:
	var y_max: float = 21.0 * s_inset
	var c: float = 168.0 * s_inset
	var cx: float = contact.x
	var cy: float = contact.y
	var max_f: float = 999.0

	# 1. Top bound: cy - h_top * f >= -y_max => h_top * f <= y_max + cy
	if h_top > 0.001:
		max_f = minf(max_f, (y_max + cy) / h_top)

	# 2. Bottom bound: cy + h_bottom * f <= y_max => h_bottom * f <= y_max - cy
	if h_bottom > 0.001:
		max_f = minf(max_f, (y_max - cy) / h_bottom)

	# 3. Top-Right: 7*(cx + w_right*f) - 4*(cy - h_top*f) <= c
	var denom3: float = 7.0 * w_right + 4.0 * h_top
	if denom3 > 0.001:
		var num3: float = c - (7.0 * cx - 4.0 * cy)
		max_f = minf(max_f, num3 / denom3)

	# 4. Bottom-Right: 7*(cx + w_right*f) + 4*(cy + h_bottom*f) <= c
	var denom4: float = 7.0 * w_right + 4.0 * h_bottom
	if denom4 > 0.001:
		var num4: float = c - (7.0 * cx + 4.0 * cy)
		max_f = minf(max_f, num4 / denom4)

	# 5. Bottom-Left: -7*(cx - w_left*f) + 4*(cy + h_bottom*f) <= c
	var denom5: float = 7.0 * w_left + 4.0 * h_bottom
	if denom5 > 0.001:
		var num5: float = c - (-7.0 * cx + 4.0 * cy)
		max_f = minf(max_f, num5 / denom5)

	# 6. Top-Left: -7*(cx - w_left*f) - 4*(cy - h_top*f) <= c
	var denom6: float = 7.0 * w_left + 4.0 * h_top
	if denom6 > 0.001:
		var num6: float = c - (-7.0 * cx - 4.0 * cy)
		max_f = minf(max_f, num6 / denom6)

	return maxf(0.0, max_f)

## Computes safe placement rect, scale and final contact for an asset.
static func compute_safe_placement(path: String, local_contact: Vector2, desired_height: float, flip: bool = false, s_inset: float = INSET_SCALE) -> Dictionary:
	var b: Rect2 = Registry.bounds(path)
	var m: Dictionary = Registry.metadata(path)
	var bottom: Array = m.get("bottom_contact", [b.position.x + b.size.x * 0.5, b.position.y + b.size.y])

	var raw_w_left: float = float(bottom[0]) - b.position.x
	var raw_w_right: float = b.size.x - raw_w_left
	var w_left: float = raw_w_right if flip else raw_w_left
	var w_right: float = raw_w_left if flip else raw_w_right

	var h_top: float = float(bottom[1]) - b.position.y
	var h_bottom: float = maxf(0.0, b.size.y - h_top)

	var cur_contact: Vector2 = local_contact
	var max_scale: float = compute_max_scale(cur_contact, w_left, w_right, h_top, h_bottom, s_inset)

	# If anchor is too close to edge to give even half desired height, adjust inward towards center
	if max_scale * b.size.y < desired_height * 0.50:
		cur_contact = local_contact * 0.65
		max_scale = compute_max_scale(cur_contact, w_left, w_right, h_top, h_bottom, s_inset)

	var desired_scale: float = desired_height / b.size.y
	var final_scale: float = minf(desired_scale, max_scale)

	if final_scale <= 0.015:
		return {}

	var size: Vector2 = b.size * final_scale
	var top_left: Vector2 = cur_contact - Vector2(w_left * final_scale, h_top * final_scale)

	return {
		"local_rect": Rect2(top_left, size),
		"local_contact": cur_contact,
		"scale": final_scale,
		"resource": path,
		"flip": flip
	}

# ==============================================================================
# ROLE CLASSIFICATION
# ==============================================================================

static func classify_role(d) -> int:
	if bool(d.unit_clearance_required) or bool(d.unit_present):
		return 11 # glade / unit-clearance cell
	if bool(d.road_present) or int(d.road_neighbor_mask) != 0:
		return 8 # roadside woodland, pulled back from corridor
	if int(d.mountain_neighbor_mask) != 0:
		return 9 # foothill forest
	if int(d.river_neighbor_mask) != 0 or bool(d.river_present):
		return 10 # bamboo / riverbank grove
	var forest_neighbors: int = _bitcount(int(d.forest_neighbor_mask))
	if forest_neighbors <= 1:
		return 5 # isolated copse
	if forest_neighbors >= 4:
		return 7 # dense interior cell
	return 6 # edge / mixed woodland cell

static func _role_name(role: int) -> String:
	match role:
		5: return "isolated_copse_cell"
		6: return "woodland_edge_cell"
		7: return "woodland_interior_cell"
		8: return "roadside_woodland_cell"
		9: return "foothill_forest_cell"
		10: return "river_grove_cell"
		11: return "glade_cell"
		_: return "woodland_edge_cell"

# ==============================================================================
# MULTI-TIER COMPOSITION RECIPES
# ==============================================================================

## Plans the multi-sprite composition and understory ground polygon for a forest hex.
static func plan_cell_composition(coord: Vector2i, role: int, d, descriptors: Dictionary) -> Dictionary:
	var center: Vector2 = d.world_pos
	var h: int = _hash2(coord.x, coord.y, 77)

	# 1. Hex-owned understory forest floor polygon (inset s = 0.82 outer, s = 0.50 inner)
	# Subordinate, low-contrast, muted earthy loam shadow (alpha 0.15-0.20)
	var floor_poly := PackedVector2Array()
	var inner_floor_poly := PackedVector2Array()
	for v in CANONICAL_VERTICES:
		floor_poly.append(center + v * FLOOR_SCALE)
		inner_floor_poly.append(center + v * INNER_FLOOR_SCALE)

	var shade: float = (float(h % 7) - 3.0) * 0.010
	var floor_color := Color(
		clampf(0.18 + shade, 0.12, 0.24),
		clampf(0.17 + shade, 0.11, 0.23),
		clampf(0.14 + shade * 0.5, 0.09, 0.19),
		0.18
	)
	var inner_color := Color(
		clampf(0.14 + shade, 0.08, 0.18),
		clampf(0.13 + shade, 0.07, 0.17),
		clampf(0.11 + shade * 0.5, 0.06, 0.15),
		0.10
	)
	if role == 10: # River grove / bamboo: cool damp silt loam
		floor_color = Color(0.16 + shade * 0.5, 0.18 + shade, 0.14, 0.20)
		inner_color = Color(0.12 + shade * 0.5, 0.14 + shade, 0.11, 0.10)
	elif role == 9: # Foothill: slate-tinted pine loam
		floor_color = Color(0.16 + shade * 0.5, 0.16 + shade, 0.15, 0.20)
		inner_color = Color(0.12 + shade * 0.5, 0.12 + shade, 0.11, 0.10)
	elif role == 11: # Glade: warm dry turf shadow
		floor_color = Color(0.20 + shade, 0.20 + shade, 0.16, 0.15)
		inner_color = Color(0.15 + shade, 0.15 + shade, 0.12, 0.08)

	var raw_sprites: Array = []
	# Global canopy growth: trees fill the hex (containment solver clamps to inset).
	# Glade cells (role 11) stay small to keep the unit pocket clear.
	var grow: float = 1.0 if role == 11 else 2.0
	# Canopy may touch the true hex edge (no cross-hex bleed); glade stays inset.
	var inset: float = 0.90 if role == 11 else 1.0
	var push_sprite = func(stem: String, l_contact: Vector2, d_height: float, flip: bool = false):
		var path: String = Registry.vegetation_path(stem)
		var res: Dictionary = compute_safe_placement(path, l_contact, d_height * grow, flip, inset)
		if not res.is_empty():
			var l_rect: Rect2 = res["local_rect"]
			raw_sprites.append({
				"path": path,
				"rect": Rect2(center + l_rect.position, l_rect.size),
				"contact_y": center.y + res["local_contact"].y,
				"flip": res["flip"],
				"owner": coord
			})

	# Direction vector calculation for setbacks and edge transitions
	var road_mask: int = int(d.road_neighbor_mask)
	var mtn_mask: int = int(d.mountain_neighbor_mask)
	var river_mask: int = int(d.river_neighbor_mask)
	var forest_mask: int = int(d.forest_neighbor_mask)

	match role:
		7: # DENSE INTERIOR FOREST (17 visual elements across Ground, Rear, Core, Flanks, and Front)
			# Layer B: Real Ground Vegetation & Floor Fill (4 real grass & shrub assets replacing flat green fill)
			var g_stem1: String = "grass_clump_A" if ((h / 3) % 2 == 0) else "dry_shrub_A"
			push_sprite.call(g_stem1, Vector2(-5.0 + float((h / 7) % 3 - 1) * 0.5, -1.0), 8.5, ((h / 11) % 2 == 0))

			var g_stem2: String = "grass_clump_B" if ((h / 5) % 2 == 0) else "dry_shrub_B"
			push_sprite.call(g_stem2, Vector2(5.0 + float((h / 13) % 3 - 1) * 0.5, -1.0), 8.5, ((h / 17) % 2 == 0))

			var g_stem3: String = "grass_clump_A" if ((h / 19) % 2 == 0) else "grass_clump_B"
			push_sprite.call(g_stem3, Vector2(float((h / 23) % 3 - 1) * 0.8, 3.0), 8.0, ((h / 29) % 2 == 0))

			var g_stem4: String = "dry_shrub_A" if ((h / 31) % 2 == 0) else "grass_clump_A"
			push_sprite.call(g_stem4, Vector2(float((h / 37) % 3 - 1) * 0.8, -7.0), 7.5, ((h / 41) % 2 == 0))

			# Layer C: Back Canopy Wall (3 trees spanning upper hex)
			var rear_l_stems := ["pine_B", "deciduous_sparse_A", "pine_A", "sparse_pine_cluster_A", "foothill_pine_cluster_A"]
			var r_l_stem: String = rear_l_stems[(h / 5) % rear_l_stems.size()]
			push_sprite.call(r_l_stem, Vector2(-7.5 + float((h / 7) % 5 - 2) * 0.4, 1.0), 19.5 + float((h / 11) % 3) * 0.6, ((h / 13) % 2 == 0))

			var rear_r_stems := ["pine_small_A", "deciduous_sparse_A", "pine_C", "sparse_pine_cluster_B", "foothill_pine_cluster_B"]
			var r_r_stem: String = rear_r_stems[(h / 17) % rear_r_stems.size()]
			push_sprite.call(r_r_stem, Vector2(7.5 + float((h / 19) % 5 - 2) * 0.4, 1.0), 19.0 + float((h / 23) % 3) * 0.6, ((h / 29) % 2 == 0))

			var rear_c_stems := ["pine_small_A", "deciduous_sparse_A", "bamboo_cluster_A", "pine_B", "bamboo_grove_A"]
			var r_c_stem: String = rear_c_stems[(h / 31) % rear_c_stems.size()]
			push_sprite.call(r_c_stem, Vector2(float((h / 37) % 3 - 1) * 1.5, -2.5), 16.5 + float((h / 41) % 3) * 0.5, ((h / 43) % 2 == 0))

			# Layer D: Core Canopy Mass (3 dominant trees forming dense continuous canopy mass)
			var core_stems := ["deciduous_A", "deciduous_B", "pine_A", "pine_C", "mixed_woodland_A", "pine_old_twisted_A"]
			var core_stem: String = core_stems[h % core_stems.size()]
			var core_h: float = 26.5 + float(h % 4) * 0.6
			var core_contact := Vector2(float(h % 5 - 2) * 0.6, 6.5 + float((h / 3) % 3) * 0.5)
			push_sprite.call(core_stem, core_contact, core_h, ((h / 2) % 2 == 0))

			var core_sec_stems := ["deciduous_B", "pine_A", "mixed_woodland_B", "deciduous_A", "bamboo_grove_B"]
			var core_sec_stem: String = core_sec_stems[(h / 4) % core_sec_stems.size()]
			push_sprite.call(core_sec_stem, Vector2(-4.0 + float((h / 6) % 3 - 1) * 0.6, 5.0), 23.5 + float((h / 8) % 3) * 0.6, ((h / 9) % 2 == 0))

			var core_ter_stems := ["pine_C", "deciduous_A", "pine_old_twisted_A", "mixed_woodland_A"]
			var core_ter_stem: String = core_ter_stems[(h / 10) % core_ter_stems.size()]
			push_sprite.call(core_ter_stem, Vector2(4.0 + float((h / 12) % 3 - 1) * 0.6, 5.5), 23.0 + float((h / 14) % 3) * 0.6, ((h / 15) % 2 == 0))

			# Layer E: Mid / Flank Fillers (2 trees packing side gaps)
			var flank_l_stems := ["pine_small_A", "deciduous_sparse_A", "bamboo_edge_A", "dry_shrub_B"]
			push_sprite.call(flank_l_stems[(h / 47) % flank_l_stems.size()], Vector2(-11.0, 3.5), 15.0, ((h / 53) % 2 == 0))

			var flank_r_stems := ["pine_old_twisted_A", "pine_small_A", "bamboo_cluster_B", "forest_edge_A"]
			push_sprite.call(flank_r_stems[(h / 59) % flank_r_stems.size()], Vector2(11.0, 3.5), 15.0, ((h / 61) % 2 == 0))

			# Layer F: Front Fringe & Understory Occlusion (5 shrubs & grasses covering trunks and lower bound)
			var shrub_e1: String = "dry_shrub_A" if ((h / 67) % 2 == 0) else "grass_clump_A"
			push_sprite.call(shrub_e1, Vector2(-11.5, 12.0), 8.0, false)
			push_sprite.call("dry_shrub_B", Vector2(-5.5, 14.5), 8.5, true)
			var shrub_e3: String = "grass_clump_B" if ((h / 73) % 2 == 0) else "dry_shrub_A"
			push_sprite.call(shrub_e3, Vector2(0.0, 15.5), 8.5, false)
			var shrub_e4: String = "dry_shrub_B" if ((h / 79) % 2 == 0) else "grass_clump_A"
			push_sprite.call(shrub_e4, Vector2(5.5, 14.5), 8.5, true)
			var shrub_e5: String = "dry_shrub_A" if ((h / 71) % 2 == 0) else "grass_clump_B"
			push_sprite.call(shrub_e5, Vector2(11.5, 12.0), 8.0, true)

		6: # WOODLAND EDGE (14 visual elements, real grass/shrub floor + inward dense mass)
			var v_open := Vector2.ZERO
			for i in range(6):
				if (forest_mask & (1 << i)) == 0:
					v_open += EDGE_MIDPOINTS[i]
			var v_retreat := Vector2.ZERO
			if v_open.length() > 0.01:
				v_retreat = -v_open.normalized() * 3.5

			# Layer B: Real Ground Vegetation (3 grass & shrub assets occupying floor)
			var eg_stem1: String = "grass_clump_A" if (h % 2 == 0) else "dry_shrub_A"
			push_sprite.call(eg_stem1, Vector2(-4.5, -0.5) + v_retreat * 0.6, 8.5, true)
			var eg_stem2: String = "grass_clump_B" if ((h / 3) % 2 == 0) else "dry_shrub_B"
			push_sprite.call(eg_stem2, Vector2(4.5, -0.5) + v_retreat * 0.6, 8.5, false)
			var eg_stem3: String = "grass_clump_A" if ((h / 5) % 2 == 0) else "grass_clump_B"
			push_sprite.call(eg_stem3, Vector2(0.0, 3.0) + v_retreat * 0.6, 8.0, true)

			# Layer C: Rear trees on inward side (2 trees)
			var s_stem1: String = "pine_small_A" if (h % 2 == 0) else "deciduous_sparse_A"
			push_sprite.call(s_stem1, Vector2(-7.5, 0.5) + v_retreat * 0.7, 18.0, true)
			var s_stem2: String = "deciduous_sparse_A" if (h % 2 == 0) else "pine_B"
			push_sprite.call(s_stem2, Vector2(7.5, 0.5) + v_retreat * 0.7, 18.0, false)

			# Layer D: Core trees on inward side (2 trees)
			var edge_stems := ["deciduous_A", "deciduous_B", "pine_B", "mixed_woodland_B", "forest_edge_A", "forest_edge_B"]
			var edge_main: String = edge_stems[h % edge_stems.size()]
			push_sprite.call(edge_main, Vector2(0.0, 6.0) + v_retreat, 25.5 + float(h % 3) * 0.6, (h % 2 == 0))

			var edge_sec_stems := ["deciduous_B", "pine_A", "roadside_tree_patch_A", "mixed_woodland_A"]
			var edge_sec: String = edge_sec_stems[(h / 3) % edge_sec_stems.size()]
			push_sprite.call(edge_sec, Vector2(-3.5 if (h % 2 == 0) else 3.5, 4.5) + v_retreat * 0.8, 21.5, ((h / 5) % 2 == 0))

			# Layer E: Mid flank support trees (2 trees)
			var flank_stem_e: String = "pine_old_twisted_A" if ((h / 7) % 2 == 0) else "deciduous_sparse_A"
			push_sprite.call(flank_stem_e, Vector2(-10.5, 3.5) + v_retreat * 0.7, 14.5, (h % 2 == 0))
			var flank_stem_e2: String = "pine_small_A" if ((h / 11) % 2 == 0) else "forest_edge_B"
			push_sprite.call(flank_stem_e2, Vector2(10.5, 3.5) + v_retreat * 0.7, 14.5, ((h / 13) % 2 == 0))

			# Layer F: Outward boundary shrubs & grass clumps (5 elements)
			push_sprite.call("dry_shrub_A", Vector2(-11.0, 12.0) + v_retreat * 0.4, 8.0, false)
			push_sprite.call("dry_shrub_B", Vector2(-4.0, 14.0) + v_retreat * 0.4, 8.5, true)
			push_sprite.call("grass_clump_A", Vector2(4.0, 14.0) + v_retreat * 0.4, 8.5, false)
			push_sprite.call("grass_clump_B", Vector2(11.0, 12.0) + v_retreat * 0.4, 8.0, true)
			push_sprite.call("dry_shrub_B", Vector2(0.0, 15.0) + v_retreat * 0.4, 8.0, false)

		8: # ROADSIDE WOODLAND (12 visual elements, corridor setback + opposite half packed with real assets)
			var v_road := Vector2.ZERO
			for i in range(6):
				if (road_mask & (1 << i)) != 0:
					v_road += EDGE_MIDPOINTS[i]
			var v_setback := Vector2.ZERO
			if v_road.length() > 0.01:
				v_setback = -v_road.normalized() * 5.5
			elif bool(d.road_present):
				v_setback = Vector2(-5.5, 0.0)

			# Layer B: Real Ground Vegetation (2 assets away from corridor)
			push_sprite.call("grass_clump_A", Vector2(-4.0, 0.0) + v_setback * 0.7, 8.0, false)
			push_sprite.call("grass_clump_B", Vector2(4.0, 0.0) + v_setback * 0.7, 8.0, true)

			# Layer C: Rear trees
			push_sprite.call("pine_small_A", Vector2(-6.5, 0.5) + v_setback * 0.8, 17.0, false)
			push_sprite.call("deciduous_sparse_A", Vector2(6.5, 0.5) + v_setback * 0.8, 17.0, true)

			# Layer D: Core trees
			var road_stems := ["roadside_tree_patch_A", "deciduous_A", "deciduous_B", "pine_C"]
			var road_main: String = road_stems[h % road_stems.size()]
			push_sprite.call(road_main, Vector2(0.0, 5.5) + v_setback, 24.5 + float(h % 3) * 0.6, (h % 2 == 0))

			var road_sec_stems := ["deciduous_B", "pine_old_twisted_A", "deciduous_A"]
			var road_sec: String = road_sec_stems[(h / 3) % road_sec_stems.size()]
			push_sprite.call(road_sec, Vector2(-3.0 if (h % 2 == 0) else 3.0, 4.0) + v_setback * 0.8, 20.5, ((h / 5) % 2 == 0))

			# Layer E: Flank support
			var flank_x_r: float = 9.5 if (h % 2 == 0) else -9.5
			push_sprite.call("pine_old_twisted_A" if ((h / 7) % 2 == 0) else "deciduous_sparse_A", Vector2(flank_x_r, 3.5) + v_setback * 0.8, 14.5, false)

			# Layer F: Front understory (5 shrubs/grasses)
			push_sprite.call("dry_shrub_A", Vector2(-9.5, 12.0) + v_setback * 0.5, 8.0, false)
			push_sprite.call("dry_shrub_B", Vector2(-2.5, 14.0) + v_setback * 0.5, 8.5, true)
			push_sprite.call("grass_clump_A", Vector2(4.5, 14.0) + v_setback * 0.5, 8.5, false)
			push_sprite.call("grass_clump_B", Vector2(10.0, 12.0) + v_setback * 0.5, 8.0, true)
			push_sprite.call("dry_shrub_A", Vector2(1.0, 15.0) + v_setback * 0.5, 7.5, false)

		9: # FOOTHILL FOREST (14 visual elements, pine dominant, rugged understory)
			var v_mtn := Vector2.ZERO
			for i in range(6):
				if (mtn_mask & (1 << i)) != 0:
					v_mtn += EDGE_MIDPOINTS[i]
			var v_setback := Vector2.ZERO
			if v_mtn.length() > 0.01:
				v_setback = -v_mtn.normalized() * 3.0

			# Layer B: Real Ground Vegetation (3 rugged shrubs / tufts)
			push_sprite.call("dry_shrub_A", Vector2(-4.5, -0.5) + v_setback * 0.7, 8.0, false)
			push_sprite.call("grass_clump_A", Vector2(4.5, -0.5) + v_setback * 0.7, 8.0, true)
			push_sprite.call("dry_shrub_B", Vector2(0.0, 2.5) + v_setback * 0.7, 8.0, false)

			# Layer C: Rear pine canopy (3 trees)
			var pine_secs := ["pine_B", "sparse_pine_cluster_A", "sparse_pine_cluster_B", "pine_C"]
			push_sprite.call(pine_secs[h % pine_secs.size()], Vector2(-7.5, 0.5) + v_setback * 0.8, 18.5, true)
			push_sprite.call("pine_C", Vector2(7.5, 0.5) + v_setback * 0.8, 18.5, false)
			push_sprite.call("pine_small_A", Vector2(0.0, -2.5) + v_setback * 0.8, 16.0, true)

			# Layer D: Core pine canopy (2 hero trees)
			var pine_mains := ["foothill_pine_cluster_A", "foothill_pine_cluster_B", "pine_A", "pine_C"]
			var pine_main: String = pine_mains[h % pine_mains.size()]
			push_sprite.call(pine_main, Vector2(0.0, 6.0) + v_setback, 26.0 + float(h % 3) * 0.7, (h % 2 == 0))
			push_sprite.call("pine_old_twisted_A", Vector2(-4.0, 5.0) + v_setback * 0.8, 22.0, true)

			# Layer E: Flank pines (2 trees)
			push_sprite.call("pine_old_twisted_A", Vector2(-10.5, 3.5) + v_setback * 0.8, 15.0, false)
			push_sprite.call("pine_small_A", Vector2(10.5, 3.5) + v_setback * 0.8, 15.0, true)

			# Layer F: Front understory (4 elements)
			push_sprite.call("dry_shrub_A", Vector2(-11.0, 12.0), 8.0, false)
			push_sprite.call("dry_shrub_B", Vector2(-4.0, 14.0), 8.5, true)
			push_sprite.call("grass_clump_A", Vector2(4.0, 14.0), 8.5, false)
			push_sprite.call("dry_shrub_A", Vector2(11.0, 12.0), 8.0, true)

		10: # RIVER GROVE / BAMBOO FOREST (14 visual elements, East Asian bamboo & moist undergrowth)
			var v_river := Vector2.ZERO
			for i in range(6):
				if (river_mask & (1 << i)) != 0:
					v_river += EDGE_MIDPOINTS[i]
			var v_setback := Vector2.ZERO
			if v_river.length() > 0.01:
				v_setback = -v_river.normalized() * 3.5
			elif bool(d.river_present):
				v_setback = Vector2(0.0, 4.0)

			# Layer B: Real Ground Vegetation (3 moist grass / bamboo tufts)
			push_sprite.call("grass_clump_A", Vector2(-4.5, -0.5) + v_setback * 0.7, 8.0, false)
			push_sprite.call("grass_clump_B", Vector2(4.5, -0.5) + v_setback * 0.7, 8.0, true)
			push_sprite.call("bamboo_edge_A", Vector2(0.0, 2.5) + v_setback * 0.7, 8.0, false)

			# Layer C: Rear bamboo / greenery (3 trees)
			push_sprite.call("bamboo_cluster_A", Vector2(-7.5, 0.5) + v_setback * 0.8, 18.0, true)
			push_sprite.call("bamboo_cluster_B", Vector2(7.5, 0.5) + v_setback * 0.8, 18.0, false)
			push_sprite.call("deciduous_sparse_A", Vector2(0.0, -2.5) + v_setback * 0.8, 16.0, true)

			# Layer D: Core bamboo mass (2 trees)
			var bamboo_mains := ["bamboo_grove_A", "bamboo_grove_B", "bamboo_cluster_A", "deciduous_A"]
			var b_main: String = bamboo_mains[h % bamboo_mains.size()]
			push_sprite.call(b_main, Vector2(0.0, 5.5) + v_setback, 25.5 + float(h % 3) * 0.7, (h % 2 == 0))
			push_sprite.call("bamboo_cluster_B", Vector2(4.0, 4.5) + v_setback * 0.8, 21.5, true)

			# Layer E: Flank bamboo (2 trees)
			push_sprite.call("bamboo_edge_A", Vector2(-10.5, 3.5) + v_setback * 0.8, 15.0, false)
			push_sprite.call("bamboo_cluster_A", Vector2(10.5, 3.5) + v_setback * 0.8, 15.0, true)

			# Layer F: Moist fringe understory (4 elements)
			push_sprite.call("grass_clump_A", Vector2(-10.5, 12.0), 8.0, false)
			push_sprite.call("grass_clump_B", Vector2(-3.0, 14.0), 8.5, true)
			push_sprite.call("dry_shrub_B", Vector2(4.0, 14.0), 8.5, false)
			push_sprite.call("grass_clump_A", Vector2(10.5, 12.0), 8.0, true)

		11: # GLADE / UNIT-CLEARANCE CELL (11 visual elements, center open, rim carpeted with real grass & shrubs)
			# Central pocket (r < 7.5 px) strictly clear for unit badge visibility
			# Layer B: Mid-Rim Grass Clumps (2 grass clumps on outer perimeter)
			push_sprite.call("grass_clump_A", Vector2(-7.5, 4.0), 8.0, false)
			push_sprite.call("grass_clump_B", Vector2(7.5, 4.0), 8.0, true)

			# Layer C: Rear rim (2 trees)
			push_sprite.call("pine_small_A", Vector2(-10.0, -1.5), 16.0, false)
			push_sprite.call("deciduous_sparse_A", Vector2(10.0, -1.5), 16.0, true)

			# Layer D: Flank rim (2 trees)
			push_sprite.call("pine_old_twisted_A", Vector2(-12.0, 4.0), 15.0, false)
			push_sprite.call("bamboo_cluster_A", Vector2(12.0, 4.0), 15.0, true)

			# Layer E: North rim (1 element)
			push_sprite.call("dry_shrub_A", Vector2(0.0, -8.5), 8.5, false)

			# Layer F: Front rim (4 elements)
			push_sprite.call("dry_shrub_B", Vector2(-11.5, 11.5), 8.5, true)
			push_sprite.call("grass_clump_A", Vector2(-5.0, 14.5), 8.5, false)
			push_sprite.call("grass_clump_B", Vector2(5.0, 14.5), 8.5, true)
			push_sprite.call("dry_shrub_A", Vector2(11.5, 11.5), 8.5, false)

		_: # 5 or default: ISOLATED COPSE (13 visual elements)
			# Layer B: Real Ground Vegetation (3 grass & shrub assets)
			push_sprite.call("grass_clump_A", Vector2(-4.0, -0.5), 8.0, false)
			push_sprite.call("grass_clump_B", Vector2(4.0, -0.5), 8.0, true)
			push_sprite.call("dry_shrub_B", Vector2(0.0, 2.5), 8.0, false)

			# Layer C: Rear (2 trees)
			push_sprite.call("pine_small_A", Vector2(-7.5, 0.5), 17.5, true)
			push_sprite.call("deciduous_sparse_A", Vector2(7.5, 0.5), 17.5, false)

			# Layer D: Core (2 trees)
			var copse_mains := ["pine_old_twisted_A", "deciduous_B", "mixed_woodland_A"]
			push_sprite.call(copse_mains[h % copse_mains.size()], Vector2(0.0, 5.5), 25.5, (h % 2 == 0))
			push_sprite.call("deciduous_A", Vector2(-3.5, 4.5), 21.0, true)

			# Layer E: Flank (2 trees)
			push_sprite.call("dry_shrub_B", Vector2(-10.5, 3.5), 14.5, false)
			push_sprite.call("pine_small_A", Vector2(10.5, 3.5), 14.5, true)

			# Layer F: Front (4 shrubs/grasses)
			push_sprite.call("dry_shrub_A", Vector2(-10.5, 12.0), 8.0, false)
			push_sprite.call("dry_shrub_B", Vector2(-3.5, 14.0), 8.5, true)
			push_sprite.call("grass_clump_A", Vector2(3.5, 14.0), 8.5, false)
			push_sprite.call("grass_clump_B", Vector2(10.5, 12.0), 8.0, true)

	return {
		"understory": {
			"poly": floor_poly,
			"color": floor_color,
			"inner_poly": inner_floor_poly,
			"inner_color": inner_color
		},
		"sprites": raw_sprites
	}

# ==============================================================================
# MACRO PLANNING & LAYER BUILDING
# ==============================================================================

## Returns exactly one local role entry for every forest cell.
static func plan_macros(descriptors: Dictionary, occupancy, _cell_data: Dictionary) -> Array:
	var entries: Array = []
	var cells: Array[Vector2i] = []
	for coord in descriptors.keys():
		if int(descriptors[coord].terrain_type) == 2:
			cells.append(coord)
	cells.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		if a.x != b.x:
			return a.x < b.x
		return a.y < b.y
	)

	var sequence: int = 0
	for coord in cells:
		var d = descriptors[coord]
		var role: int = classify_role(d)
		var id: String = "forest_cell_%d_%d_%d" % [coord.x, coord.y, sequence]
		sequence += 1
		var footprint: Array[Vector2i] = [coord]
		if occupancy != null and occupancy.can_claim_macro(coord, footprint, "forest"):
			occupancy.claim_macro(coord, footprint, "forest", id, _role_name(role))
		d.macro_feature_role = role
		d.macro_feature_id = id
		d.macro_anchor = coord
		entries.append({"id": id, "anchor": coord, "role": role, "footprint": footprint})
	return entries

static func build_nodes(entries: Array, descriptors: Dictionary) -> Array[Node2D]:
	var nodes: Array[Node2D] = []
	if entries.is_empty():
		return nodes
	var layer: Node2D = LayerCls.new()
	layer.name = "ForestOwnedCells"
	layer.z_index = 4
	layer.call("configure", 1, entries, descriptors)
	nodes.append(layer)
	return nodes

