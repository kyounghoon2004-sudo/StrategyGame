class_name HexNeighborClassifier
extends RefCounted

## HexNeighborClassifier — Production Hex Topology & Neighborhood Analysis Engine.
## Provides flat-top axial metrics, canonical direction indexing (0..5: E, NE, NW, W, SW, SE),
## fast cached 6-bit topology neighbor mask generation, connected component labeling,
## multi-source BFS edge depth classification, and role classification for all 4,921 cells.

const HexVisualDescriptorCls = preload("res://scripts/visual/hex_native/hex_visual_descriptor.gd")

# ==============================================================================
# CANONICAL FLAT-TOP AXIAL METRICS & DIRECTIONS
# ==============================================================================

const HEX_RADIUS: int = 40
const PLAYABLE_HEX_COUNT: int = 4921

const TILE_W: int = 48
const TILE_H: int = 42
const COL_STEP: int = 36          # TILE_W * 0.75
const ROW_STEP: int = 42          # TILE_H
const ODD_Q_Y_OFFSET: int = 21    # TILE_H * 0.5

## Canonical 6 directions clockwise from East (Flat-top axial)
## Index 0: E  (1, 0)   -> pixel (+36, +21)
## Index 1: NE (1, -1)  -> pixel (+36, -21)
## Index 2: NW (0, -1)  -> pixel (0, -42)
## Index 3: W  (-1, 0)  -> pixel (-36, -21)
## Index 4: SW (-1, 1)  -> pixel (-36, +21)
## Index 5: SE (0, 1)   -> pixel (0, +42)
const DIRECTIONS: Array[Vector2i] = [
	Vector2i(1, 0),   # 0: East
	Vector2i(1, -1),  # 1: North-East
	Vector2i(0, -1),  # 2: North-West
	Vector2i(-1, 0),  # 3: West
	Vector2i(-1, 1),  # 4: South-West
	Vector2i(0, 1)    # 5: South-East
]

const DIR_OPPOSITES: Array[int] = [3, 4, 5, 0, 1, 2]
const DIR_NAMES: Array[String] = ["E", "NE", "NW", "W", "SW", "SE"]

## Relative midpoints for each of the 6 hex edges (Center at Vector2.ZERO)
const EDGE_MIDPOINTS: Array[Vector2] = [
	Vector2(18.0, 10.5),   # 0: E
	Vector2(18.0, -10.5),  # 1: NE
	Vector2(0.0, -21.0),   # 2: NW (flat-top edge)
	Vector2(-18.0, -10.5), # 3: W
	Vector2(-18.0, 10.5),  # 4: SW
	Vector2(0.0, 21.0)     # 5: SE (flat-bottom edge)
]

## Known unit spawn coordinates in forest requiring guaranteed glade visual clearance
const SPAWN_HEXES_IN_FOREST: Dictionary = {
	"-26,-6": true, "-24,6": true, "-26,4": true,
	"-25,5": true, "-27,5": true, "-28,6": true,
	"24,-6": true, "25,-6": true, "26,-6": true,
	"10,-21": true, "9,-22": true, "8,-20": true
}

# ==============================================================================
# SPATIAL & METRIC HELPERS
# ==============================================================================

static func hex_to_pixel(q: int, r: int) -> Vector2:
	return Vector2(
		float(q * COL_STEP),
		float(r * ROW_STEP + q * ODD_Q_Y_OFFSET)
	)

static func axial_distance(a: Vector2i, b: Vector2i) -> int:
	var s_a: int = -a.x - a.y
	var s_b: int = -b.x - b.y
	return maxi(maxi(absi(a.x - b.x), absi(a.y - b.y)), absi(s_a - s_b))

static func axial_distance_from_origin(coord: Vector2i) -> int:
	var s: int = -coord.x - coord.y
	return maxi(maxi(absi(coord.x), absi(coord.y)), absi(s))

static func is_playable(coord: Vector2i) -> bool:
	return axial_distance_from_origin(coord) <= HEX_RADIUS

static func get_neighbor_coord(coord: Vector2i, dir_idx: int) -> Vector2i:
	return coord + DIRECTIONS[dir_idx % 6]

static func get_edge_midpoint(coord: Vector2i, dir_idx: int) -> Vector2:
	return hex_to_pixel(coord.x, coord.y) + EDGE_MIDPOINTS[dir_idx % 6]

# ==============================================================================
# BITMASK HELPER UTILITIES (6-BIT TOPOLOGY)
# ==============================================================================

static func get_bit(mask: int, dir_idx: int) -> bool:
	return (mask & (1 << (dir_idx % 6))) != 0

static func set_bit(mask: int, dir_idx: int) -> int:
	return mask | (1 << (dir_idx % 6))

static func count_bits(mask: int) -> int:
	var c: int = 0
	for i in range(6):
		if (mask & (1 << i)) != 0:
			c += 1
	return c

static func get_active_dirs(mask: int) -> Array[int]:
	var dirs: Array[int] = []
	for i in range(6):
		if (mask & (1 << i)) != 0:
			dirs.append(i)
	return dirs

# ==============================================================================
# 5 TOPOLOGY NEIGHBOR MASKS GENERATION
# ==============================================================================

## Computes the 5 cached 6-bit topology neighbor masks for a descriptor
static func compute_masks_for_descriptor(
	desc: HexVisualDescriptorCls,
	descriptors: Dictionary,
	river_cells: Dictionary = {},
	stronghold_cells: Dictionary = {}
) -> void:
	var coord: Vector2i = desc.coord
	var my_terrain: int = desc.terrain_type

	var road_mask: int = 0
	var river_mask: int = 0
	var forest_mask: int = 0
	var mountain_mask: int = 0
	var same_terrain_mask: int = 0
	var boundary_mask: int = 0

	for dir_idx in range(6):
		var n_coord: Vector2i = coord + DIRECTIONS[dir_idx]
		var bit: int = (1 << dir_idx)

		if not descriptors.has(n_coord):
			# Off-map neighbor is always a boundary
			boundary_mask |= bit
			continue

		var n_desc: HexVisualDescriptorCls = descriptors[n_coord]
		var nt: int = n_desc.terrain_type
		var n_key: String = "%d,%d" % [n_coord.x, n_coord.y]

		# 1. Road Mask (road, village, fortress, capital, registered stronghold, or road_present)
		if nt == 6 or nt == 5 or nt == 4 or nt == 9 or nt == 11 or n_desc.road_present or stronghold_cells.has(n_key):
			road_mask |= bit

		# 2. River Mask (river tile, river_present, or registered river cell)
		if nt == 7 or river_cells.has(n_key) or n_desc.river_present:
			river_mask |= bit

		# 3. Forest Mask
		if nt == 2:
			forest_mask |= bit

		# 4. Mountain Mask
		if nt == 1:
			mountain_mask |= bit

		# 5. Boundary & Same-Terrain Mask
		if nt == my_terrain:
			same_terrain_mask |= bit
		else:
			boundary_mask |= bit

	desc.road_neighbor_mask = road_mask
	desc.river_neighbor_mask = river_mask
	desc.forest_neighbor_mask = forest_mask
	desc.mountain_neighbor_mask = mountain_mask
	desc.same_terrain_neighbor_mask = same_terrain_mask
	desc.terrain_neighbor_mask = boundary_mask
	desc.terrain_boundary_mask = boundary_mask

# ==============================================================================
# PASS CORRIDOR & UNIT CLEARANCE CLASSIFICATION
# ==============================================================================

static func classify_constraints(desc: HexVisualDescriptorCls, descriptors: Dictionary) -> void:
	# Unit clearance for designated forest spawn glades
	if SPAWN_HEXES_IN_FOREST.has(desc.get_key()):
		desc.unit_clearance_required = true
		desc.set_flag(HexVisualDescriptorCls.OccupancyFlags.UNIT_CLEARANCE_REQUIRED)

	# Pass corridor: road cell bordering or traversing mountain cells
	if desc.road_present and desc.mountain_neighbor_mask > 0:
		desc.pass_corridor = true
		desc.set_flag(HexVisualDescriptorCls.OccupancyFlags.PASS_CORRIDOR)
		# Propagate pass corridor status to immediate connected road neighbors
		for dir_idx in get_active_dirs(desc.road_neighbor_mask):
			var n_coord: Vector2i = desc.coord + DIRECTIONS[dir_idx]
			if descriptors.has(n_coord):
				var n_desc: HexVisualDescriptorCls = descriptors[n_coord]
				if n_desc.road_present:
					n_desc.pass_corridor = true
					n_desc.set_flag(HexVisualDescriptorCls.OccupancyFlags.PASS_CORRIDOR)

# ==============================================================================
# CONNECTED COMPONENT LABELING & MULTI-SOURCE BFS EDGE DEPTH
# ==============================================================================

## Computes connected components and assigns component IDs and edge depths
## for all cells matching target_terrain. Returns Array[Array[Vector2i]].
static func compute_connected_components(
	descriptors: Dictionary,
	target_terrain: int
) -> Array:
	var visited: Dictionary = {}
	var components: Array = []
	var comp_id: int = 1

	# Pass 1: BFS Connected Component Discovery
	for coord in descriptors.keys():
		var desc: HexVisualDescriptorCls = descriptors[coord]
		if visited.has(coord) or desc.terrain_type != target_terrain:
			continue

		var comp: Array[Vector2i] = []
		var queue: Array[Vector2i] = [coord]
		visited[coord] = true

		while not queue.is_empty():
			var curr: Vector2i = queue.pop_front()
			comp.append(curr)

			for dir_idx in range(6):
				var n_coord: Vector2i = curr + DIRECTIONS[dir_idx]
				if descriptors.has(n_coord) and not visited.has(n_coord):
					var n_desc: HexVisualDescriptorCls = descriptors[n_coord]
					if n_desc.terrain_type == target_terrain:
						visited[n_coord] = true
						queue.append(n_coord)

		# Assign component ID
		for c in comp:
			descriptors[c].terrain_component_id = comp_id

		components.append(comp)
		comp_id += 1

	# Pass 2: Multi-source BFS for Component Edge Depth
	for comp in components:
		_compute_component_edge_depths(comp, descriptors)

	return components

static func _compute_component_edge_depths(
	component: Array,
	descriptors: Dictionary
) -> void:
	var comp_set: Dictionary = {}
	for c in component:
		comp_set[c] = true

	var depth_map: Dictionary = {}
	var frontier: Array[Vector2i] = []

	# Step 1: Find all Depth 0 boundary cells
	# A cell is Depth 0 if any of its 6 neighbor directions points outside the component
	for c in component:
		var is_boundary: bool = false
		for dir_idx in range(6):
			var n_coord: Vector2i = c + DIRECTIONS[dir_idx]
			if not comp_set.has(n_coord):
				is_boundary = true
				break
		if is_boundary:
			depth_map[c] = 0
			frontier.append(c)

	# Step 2: Multi-source BFS outward from boundary inward to core
	var current_depth: int = 1
	while not frontier.is_empty():
		var next_frontier: Array[Vector2i] = []
		for curr in frontier:
			for dir_idx in range(6):
				var n_coord: Vector2i = curr + DIRECTIONS[dir_idx]
				if comp_set.has(n_coord) and not depth_map.has(n_coord):
					depth_map[n_coord] = current_depth
					next_frontier.append(n_coord)
		frontier = next_frontier
		current_depth += 1

	# Step 3: Write depths into descriptors
	for c in component:
		descriptors[c].component_edge_depth = depth_map.get(c, 0)

# ==============================================================================
# BASE TERRAIN & ROUTE ROLE RESOLUTION
# ==============================================================================

## Resolves the singular base role for a cell according to geographic rules
static func classify_base_role(desc: HexVisualDescriptorCls) -> int:
	var t: int = desc.terrain_type

	# 0. River channel base
	if t == 7 or desc.river_present:
		return HexVisualDescriptorCls.BaseRole.RIVER_CHANNEL

	# 1. Mountain pass compacted corridor
	if desc.pass_corridor:
		return HexVisualDescriptorCls.BaseRole.PASS_FLOOR

	# 2. Road foundation
	if desc.road_present:
		return HexVisualDescriptorCls.BaseRole.PLAIN_WORN if desc.stronghold_present else HexVisualDescriptorCls.BaseRole.PLAIN_PARCHMENT

	# 3. Foothill adjacent plains
	if t == 0 and desc.mountain_neighbor_mask > 0:
		return HexVisualDescriptorCls.BaseRole.FOOTHILL_GROUND

	# 4. Worn battlefield around strongholds
	if desc.stronghold_present:
		return HexVisualDescriptorCls.BaseRole.PLAIN_WORN

	# 5. Lowlands / Wetlands / Marshes
	if t == 3 or desc.river_neighbor_mask > 0:
		return HexVisualDescriptorCls.BaseRole.LOWLAND_GREEN

	# 6. Mountain ground
	if t == 1:
		return HexVisualDescriptorCls.BaseRole.PLAIN_LOESS

	# 7. Forest ground
	if t == 2:
		return HexVisualDescriptorCls.BaseRole.PLAIN_FADED_GRASS

	# 8. Open Plains — North vs South geographic banding
	return HexVisualDescriptorCls.BaseRole.PLAIN_FADED_GRASS if desc.coord.y > 3 else HexVisualDescriptorCls.BaseRole.PLAIN_LOESS

## Resolves route topology role from road_neighbor_mask
static func classify_route_role(desc: HexVisualDescriptorCls) -> int:
	if not desc.road_present:
		return HexVisualDescriptorCls.RouteRole.NONE

	var mask: int = desc.road_neighbor_mask
	var bit_count: int = count_bits(mask)

	match bit_count:
		0: return HexVisualDescriptorCls.RouteRole.NONE
		1: return HexVisualDescriptorCls.RouteRole.DEAD_END
		2:
			var dirs: Array[int] = get_active_dirs(mask)
			var d0: int = dirs[0]
			var d1: int = dirs[1]
			# Opposite check: diff == 3
			if (d1 - d0) == 3:
				return HexVisualDescriptorCls.RouteRole.STRAIGHT
			elif (d1 - d0) == 1 or (d1 - d0) == 5:
				return HexVisualDescriptorCls.RouteRole.BEND_SHARP
			else:
				return HexVisualDescriptorCls.RouteRole.BEND_WIDE
		3: return HexVisualDescriptorCls.RouteRole.FORK_3
		_: return HexVisualDescriptorCls.RouteRole.JUNCTION_4_PLUS

## Resolves river topology role from river_neighbor_mask
static func classify_river_role(desc: HexVisualDescriptorCls) -> int:
	if not desc.river_present:
		return HexVisualDescriptorCls.RiverRole.NONE

	if desc.road_present and desc.river_present:
		return HexVisualDescriptorCls.RiverRole.BRIDGE_CROSSING

	var bit_count: int = count_bits(desc.river_neighbor_mask)
	if bit_count <= 2:
		var dirs: Array[int] = get_active_dirs(desc.river_neighbor_mask)
		if dirs.size() == 2 and (dirs[1] - dirs[0]) == 3:
			return HexVisualDescriptorCls.RiverRole.STRAIGHT
		return HexVisualDescriptorCls.RiverRole.BEND
	else:
		return HexVisualDescriptorCls.RiverRole.CONFLUENCE
