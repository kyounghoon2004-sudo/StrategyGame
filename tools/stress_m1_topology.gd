@tool
extends SceneTree

## Empirical Adversarial Stress Harness for Milestone 1 (M1)
## Author: teamwork_preview_challenger_m1_1 (Adversarial Challenger)
## Objectives:
##   Track 1: Outer boundary edges (R=40 hexes) & off-map mask correctness
##   Track 2: Isolated vs Saturated neighbor masks (0x00 vs 0x3F) & 64-bitmask exhaustive verification
##   Track 3: Connected component separation & integrity across real & synthetic topologies
##   Track 4: Multi-source BFS edge depth monotony & analytical gradient descent
##   Track 5: VisualOccupancyMap priority invariants & 0% overlap adversarial stress
##   Track 6: Timing budgets, memory stability & repeated execution stress

const HexVisualDescriptorCls = preload("res://scripts/visual/hex_native/hex_visual_descriptor.gd")
const HexNeighborClassifierCls = preload("res://scripts/visual/hex_native/hex_neighbor_classifier.gd")
const VisualOccupancyMapCls = preload("res://scripts/visual/hex_native/visual_occupancy_map.gd")
const HexBaseTerrainMeshCls = preload("res://scripts/visual/hex_native/hex_base_terrain_mesh.gd")
const WorldBoundaryCls = preload("res://scripts/step2r/step2r_world_boundary.gd")

var failure_count: int = 0
var check_count: int = 0

func _assert_true(condition: bool, msg: String) -> void:
	check_count += 1
	if not condition:
		failure_count += 1
		print("  [ASSERTION FAILED] %s" % msg)

func _assert_eq(actual, expected, msg: String) -> void:
	check_count += 1
	if actual != expected:
		failure_count += 1
		print("  [ASSERTION FAILED] %s (Expected: %s, Got: %s)" % [msg, str(expected), str(actual)])

func _init() -> void:
	print("======================================================================")
	print("  STARTING EMPIRICAL ADVERSARIAL STRESS TEST: MILESTONE 1 (M1)")
	print("======================================================================")
	var global_start: int = Time.get_ticks_msec()
	var mem_start: int = OS.get_static_memory_usage()

	# Build authoritative baseline map data
	var shell = load("res://scripts/step2r/step2r_battlefield_shell.gd").new()
	shell._build_river_path()
	var river_cells: Dictionary = shell._river_cells

	var stronghold_cells: Dictionary = {}
	for h in shell.FORTRESS_FOOTPRINT:
		stronghold_cells["%d,%d" % [h.x, h.y]] = true
	for h in shell.CAPITAL_FOOTPRINT:
		stronghold_cells["%d,%d" % [h.x, h.y]] = true

	var descriptors: Dictionary = {}
	var playable_coords: Array[Vector2i] = []
	var cell_data: Dictionary = {}

	for q in range(-40, 41):
		for r in range(-40, 41):
			var coord := Vector2i(q, r)
			if WorldBoundaryCls.is_playable_hex(coord):
				playable_coords.append(coord)
				var t: int = shell._get_terrain_for_cell(q, r)
				var is_road: bool = (t == 6)
				var is_river: bool = river_cells.has("%d,%d" % [q, r]) or (t == 7)
				var is_sh: bool = stronghold_cells.has("%d,%d" % [q, r])
				var desc = HexVisualDescriptorCls.new(coord)
				desc.copy_gameplay_state(t, is_road, is_river, is_sh, false, 2)
				descriptors[coord] = desc
				cell_data["%d,%d" % [q, r]] = { "terrain": t }

	_assert_eq(descriptors.size(), 4921, "Playable cell count must be exactly 4,921")

	# Compute masks for all descriptors
	for coord in descriptors.keys():
		var desc: HexVisualDescriptorCls = descriptors[coord]
		HexNeighborClassifierCls.compute_masks_for_descriptor(desc, descriptors, river_cells, stronghold_cells)
		HexNeighborClassifierCls.classify_constraints(desc, descriptors)
		desc.base_role = HexNeighborClassifierCls.classify_base_role(desc)
		desc.route_role = HexNeighborClassifierCls.classify_route_role(desc)
		desc.river_role = HexNeighborClassifierCls.classify_river_role(desc)

	# Run all 6 Adversarial Tracks
	_track_1_outer_boundary_edges(descriptors)
	_track_2_isolated_vs_saturated_masks(descriptors, river_cells, stronghold_cells)
	_track_3_connected_component_integrity(descriptors)
	_track_4_multi_source_bfs_depth_monotony(descriptors)
	_track_5_visual_occupancy_adversarial_stress(descriptors, playable_coords, cell_data)
	_track_6_timing_and_stress_scaling(descriptors, river_cells, stronghold_cells)

	var global_elapsed: int = Time.get_ticks_msec() - global_start
	var mem_delta: int = OS.get_static_memory_usage() - mem_start

	print("\n======================================================================")
	print("  ADVERSARIAL STRESS TEST SUMMARY")
	print("=======================================================================")
	print("  Total Checks Executed : %d" % check_count)
	print("  Total Failures        : %d" % failure_count)
	print("  Total Execution Time  : %d ms" % global_elapsed)
	print("  Memory Delta          : %d bytes (%.2f KB)" % [mem_delta, float(mem_delta) / 1024.0])

	if failure_count == 0:
		print("  >>> VERDICT: APPROVE (All adversarial assertions satisfied) <<<")
		quit(0)
	else:
		print("  >>> VERDICT: REJECT (%d failure(s) found) <<<" % failure_count)
		quit(1)

# ==============================================================================
# TRACK 1: Outer Boundary Edges (R=40 Hexes)
# ==============================================================================
func _track_1_outer_boundary_edges(descriptors: Dictionary) -> void:
	print("\n--- [TRACK 1] Testing Outer Boundary Edges (R=40 Hexes) ---")
	var perimeter_cells: Array[Vector2i] = []
	var interior_cells: Array[Vector2i] = []
	var corner_cells: Array[Vector2i] = []
	var edge_cells: Array[Vector2i] = []
	var total_offmap_edges: int = 0

	for coord in descriptors.keys():
		var d: int = HexNeighborClassifierCls.axial_distance_from_origin(coord)
		if d == 40:
			perimeter_cells.append(coord)
			var offmap_dirs: Array[int] = []
			for dir_idx in range(6):
				var n_coord: Vector2i = coord + HexNeighborClassifierCls.DIRECTIONS[dir_idx]
				if not descriptors.has(n_coord):
					offmap_dirs.append(dir_idx)
			total_offmap_edges += offmap_dirs.size()
			if offmap_dirs.size() == 3:
				corner_cells.append(coord)
			elif offmap_dirs.size() == 2:
				edge_cells.append(coord)
			else:
				_assert_true(false, "Perimeter cell %s has unexpected off-map neighbor count: %d" % [coord, offmap_dirs.size()])
		elif d < 40:
			interior_cells.append(coord)
		else:
			_assert_true(false, "Cell %s has distance > 40 in playable descriptors!" % coord)

	_assert_eq(perimeter_cells.size(), 240, "Perimeter cell count at R=40 must be exactly 240 (6 * 40)")
	_assert_eq(corner_cells.size(), 6, "There must be exactly 6 corner cells on R=40 hex boundary")
	_assert_eq(edge_cells.size(), 234, "There must be exactly 234 edge cells on R=40 hex boundary (6 * 39)")
	_assert_eq(interior_cells.size(), 4681, "Interior cells must be exactly 4681 (4921 - 240)")
	_assert_eq(total_offmap_edges, 486, "Total off-map boundary edges must be exactly 486 (6*3 + 234*2)")

	# Verify boundary masks for all perimeter cells
	var boundary_bit_errors: int = 0
	for coord in perimeter_cells:
		var desc: HexVisualDescriptorCls = descriptors[coord]
		var b_mask: int = desc.terrain_boundary_mask
		var s_mask: int = desc.same_terrain_neighbor_mask
		for dir_idx in range(6):
			var n_coord: Vector2i = coord + HexNeighborClassifierCls.DIRECTIONS[dir_idx]
			var bit: int = (1 << dir_idx)
			if not descriptors.has(n_coord):
				# Must have boundary bit set
				if (b_mask & bit) == 0:
					boundary_bit_errors += 1
				# Must NEVER have same-terrain bit set
				if (s_mask & bit) != 0:
					boundary_bit_errors += 1
				# Feature masks must NEVER have off-map bits set
				if (desc.road_neighbor_mask & bit) != 0 or (desc.river_neighbor_mask & bit) != 0:
					boundary_bit_errors += 1
				if (desc.forest_neighbor_mask & bit) != 0 or (desc.mountain_neighbor_mask & bit) != 0:
					boundary_bit_errors += 1

	_assert_eq(boundary_bit_errors, 0, "Off-map boundary bits must be strictly set in boundary_mask and 0 in all other masks")

	# Verify all interior cells have 0 off-map neighbors
	var interior_offmap_errors: int = 0
	for coord in interior_cells:
		for dir_idx in range(6):
			var n_coord: Vector2i = coord + HexNeighborClassifierCls.DIRECTIONS[dir_idx]
			if not descriptors.has(n_coord):
				interior_offmap_errors += 1
	_assert_eq(interior_offmap_errors, 0, "Interior cells (distance < 40) must have 0 off-map neighbors")

	# Passive border mesh edge verification
	var border_instance: MeshInstance2D = HexBaseTerrainMeshCls.build_passive_borders(descriptors)
	var am: ArrayMesh = border_instance.mesh as ArrayMesh
	var border_arrays: Array = am.surface_get_arrays(0)
	var verts: PackedVector2Array = border_arrays[Mesh.ARRAY_VERTEX]
	var edge_count: int = verts.size() / 2

	_assert_eq(verts.size(), 30012, "Border mesh vertices must be exactly 30,012")
	_assert_eq(edge_count, 15006, "Unique deduplicated edge count must be exactly 15,006")

	# Check for zero-length edges or invalid vertices
	var invalid_edges: int = 0
	var horizontal_edges: int = 0
	var slanted_edges: int = 0
	for i in range(edge_count):
		var p1: Vector2 = verts[i * 2]
		var p2: Vector2 = verts[i * 2 + 1]
		var edge_len: float = p1.distance_to(p2)
		# Canonical flat-top hex metrics (W=48, H=42):
		# Top/Bottom horizontal edges (V1->V2, V4->V5): length = 24.0 px
		# Slanted edges (V0->V1, V2->V3, V3->V4, V5->V0): length = sqrt(12^2 + 21^2) ~ 24.186774 px
		if abs(edge_len - 24.0) < 0.01:
			horizontal_edges += 1
		elif abs(edge_len - 24.186774) < 0.01:
			slanted_edges += 1
		else:
			invalid_edges += 1
	_assert_eq(invalid_edges, 0, "All 15,006 border segments must match canonical hex geometry (24.0px or 24.1868px)")
	_assert_eq(horizontal_edges, 5002, "Horizontal border edges must be exactly 5,002 (15006 / 3)")
	_assert_eq(slanted_edges, 10004, "Slanted border edges must be exactly 10,004 (2 * 15006 / 3)")

	print("  [PASS] Track 1: Outer boundary edges (486 off-map edges, 240 perimeter hexes, 15,006 unique border lines) verified.")

# ==============================================================================
# TRACK 2: Isolated vs Saturated Neighbor Masks (0x00 vs 0x3F) & 64-Bitmask Suite
# ==============================================================================
func _track_2_isolated_vs_saturated_masks(descriptors: Dictionary, river_cells: Dictionary, stronghold_cells: Dictionary) -> void:
	print("\n--- [TRACK 2] Testing Isolated vs Saturated Masks & 64 Bitmask Combinations ---")

	# Test all 64 bit patterns (0..63)
	for mask in range(64):
		var bit_count: int = HexNeighborClassifierCls.count_bits(mask)
		var active_dirs: Array[int] = HexNeighborClassifierCls.get_active_dirs(mask)
		_assert_eq(active_dirs.size(), bit_count, "get_active_dirs size must equal count_bits for mask %d" % mask)

		# Check that get_bit matches bitmask
		for d in range(6):
			var expected_bit: bool = (mask & (1 << d)) != 0
			_assert_eq(HexNeighborClassifierCls.get_bit(mask, d), expected_bit, "get_bit(%d, %d) mismatch" % [mask, d])

		# Route role classification verification for all 64 masks
		var dummy_desc = HexVisualDescriptorCls.new(Vector2i(0, 0))
		dummy_desc.road_present = true
		dummy_desc.road_neighbor_mask = mask
		var route_role: int = HexNeighborClassifierCls.classify_route_role(dummy_desc)

		if bit_count == 0:
			_assert_eq(route_role, HexVisualDescriptorCls.RouteRole.NONE, "Mask 0x00 route role must be NONE")
		elif bit_count == 1:
			_assert_eq(route_role, HexVisualDescriptorCls.RouteRole.DEAD_END, "1-bit mask %d route role must be DEAD_END" % mask)
		elif bit_count == 2:
			var d0: int = active_dirs[0]
			var d1: int = active_dirs[1]
			var diff: int = d1 - d0
			if diff == 3:
				_assert_eq(route_role, HexVisualDescriptorCls.RouteRole.STRAIGHT, "Opposite 2-bit mask %d must be STRAIGHT" % mask)
			elif diff == 1 or diff == 5:
				_assert_eq(route_role, HexVisualDescriptorCls.RouteRole.BEND_SHARP, "Adjacent 2-bit mask %d must be BEND_SHARP" % mask)
			else:
				_assert_eq(route_role, HexVisualDescriptorCls.RouteRole.BEND_WIDE, "120-deg 2-bit mask %d must be BEND_WIDE" % mask)
		elif bit_count == 3:
			_assert_eq(route_role, HexVisualDescriptorCls.RouteRole.FORK_3, "3-bit mask %d must be FORK_3" % mask)
		else:
			_assert_eq(route_role, HexVisualDescriptorCls.RouteRole.JUNCTION_4_PLUS, "%d-bit mask %d must be JUNCTION_4_PLUS" % [bit_count, mask])

	# Synthetic 7-cell cluster tests: Center at (0,0) with 6 neighbors
	var synthetic_descs: Dictionary = {}
	var center := Vector2i(0, 0)
	synthetic_descs[center] = HexVisualDescriptorCls.new(center)
	for d in range(6):
		var n := center + HexNeighborClassifierCls.DIRECTIONS[d]
		synthetic_descs[n] = HexVisualDescriptorCls.new(n)

	# Case A: Isolated Forest (Center=Forest, Neighbors=Plains)
	synthetic_descs[center].terrain_type = 2
	for d in range(6):
		var n := center + HexNeighborClassifierCls.DIRECTIONS[d]
		synthetic_descs[n].terrain_type = 0
	HexNeighborClassifierCls.compute_masks_for_descriptor(synthetic_descs[center], synthetic_descs)
	_assert_eq(synthetic_descs[center].forest_neighbor_mask, 0x00, "Isolated forest mask must be 0x00")
	_assert_eq(synthetic_descs[center].same_terrain_neighbor_mask, 0x00, "Isolated forest same_terrain must be 0x00")
	_assert_eq(synthetic_descs[center].terrain_boundary_mask, 0x3F, "Isolated forest boundary mask must be 0x3F (63)")

	# Case B: Saturated Forest (Center=Forest, Neighbors=Forest)
	for d in range(6):
		var n := center + HexNeighborClassifierCls.DIRECTIONS[d]
		synthetic_descs[n].terrain_type = 2
	HexNeighborClassifierCls.compute_masks_for_descriptor(synthetic_descs[center], synthetic_descs)
	_assert_eq(synthetic_descs[center].forest_neighbor_mask, 0x3F, "Saturated forest mask must be 0x3F")
	_assert_eq(synthetic_descs[center].same_terrain_neighbor_mask, 0x3F, "Saturated forest same_terrain must be 0x3F")
	_assert_eq(synthetic_descs[center].terrain_boundary_mask, 0x00, "Saturated forest boundary mask must be 0x00")

	# Case C: Isolated Mountain (Center=Mountain, Neighbors=Plains)
	synthetic_descs[center].terrain_type = 1
	for d in range(6):
		var n := center + HexNeighborClassifierCls.DIRECTIONS[d]
		synthetic_descs[n].terrain_type = 0
	HexNeighborClassifierCls.compute_masks_for_descriptor(synthetic_descs[center], synthetic_descs)
	_assert_eq(synthetic_descs[center].mountain_neighbor_mask, 0x00, "Isolated mountain mask must be 0x00")
	_assert_eq(synthetic_descs[center].same_terrain_neighbor_mask, 0x00, "Isolated mountain same_terrain must be 0x00")
	_assert_eq(synthetic_descs[center].terrain_boundary_mask, 0x3F, "Isolated mountain boundary mask must be 0x3F")

	# Case D: Saturated Mountain (Center=Mountain, Neighbors=Mountain)
	for d in range(6):
		var n := center + HexNeighborClassifierCls.DIRECTIONS[d]
		synthetic_descs[n].terrain_type = 1
	HexNeighborClassifierCls.compute_masks_for_descriptor(synthetic_descs[center], synthetic_descs)
	_assert_eq(synthetic_descs[center].mountain_neighbor_mask, 0x3F, "Saturated mountain mask must be 0x3F")
	_assert_eq(synthetic_descs[center].same_terrain_neighbor_mask, 0x3F, "Saturated mountain same_terrain must be 0x3F")
	_assert_eq(synthetic_descs[center].terrain_boundary_mask, 0x00, "Saturated mountain boundary mask must be 0x00")

	# Case E: Isolated Road (Center=Road, Neighbors=Plains)
	synthetic_descs[center].terrain_type = 6
	synthetic_descs[center].road_present = true
	for d in range(6):
		var n := center + HexNeighborClassifierCls.DIRECTIONS[d]
		synthetic_descs[n].terrain_type = 0
		synthetic_descs[n].road_present = false
	HexNeighborClassifierCls.compute_masks_for_descriptor(synthetic_descs[center], synthetic_descs)
	_assert_eq(synthetic_descs[center].road_neighbor_mask, 0x00, "Isolated road mask must be 0x00")
	_assert_eq(HexNeighborClassifierCls.classify_route_role(synthetic_descs[center]), HexVisualDescriptorCls.RouteRole.NONE, "Isolated road role must be NONE")

	# Case F: Saturated Road (Center=Road, Neighbors=Road)
	for d in range(6):
		var n := center + HexNeighborClassifierCls.DIRECTIONS[d]
		synthetic_descs[n].terrain_type = 6
		synthetic_descs[n].road_present = true
	HexNeighborClassifierCls.compute_masks_for_descriptor(synthetic_descs[center], synthetic_descs)
	_assert_eq(synthetic_descs[center].road_neighbor_mask, 0x3F, "Saturated road mask must be 0x3F")
	_assert_eq(HexNeighborClassifierCls.classify_route_role(synthetic_descs[center]), HexVisualDescriptorCls.RouteRole.JUNCTION_4_PLUS, "Saturated road role must be JUNCTION_4_PLUS")

	print("  [PASS] Track 2: Isolated vs saturated masks (0x00 vs 0x3F) and all 64 bitmask permutations verified.")

# ==============================================================================
# TRACK 3: Connected Component Separation & Integrity
# ==============================================================================
func _track_3_connected_component_integrity(descriptors: Dictionary) -> void:
	print("\n--- [TRACK 3] Testing Connected Component Separation & Integrity ---")
	var mtn_comps = HexNeighborClassifierCls.compute_connected_components(descriptors, 1)
	var forest_comps = HexNeighborClassifierCls.compute_connected_components(descriptors, 2)

	_assert_eq(mtn_comps.size(), 5, "Mountain components count must be exactly 5")
	_assert_eq(forest_comps.size(), 4, "Forest components count must be exactly 4")

	# Verify Mountain components are strictly disjoint and non-adjacent
	var total_mtn_cells: int = 0
	for i in range(mtn_comps.size()):
		var comp_a: Array = mtn_comps[i]
		total_mtn_cells += comp_a.size()
		var set_a: Dictionary = {}
		for c in comp_a: set_a[c] = true

		# Verify all cells in comp_a have comp_id == i + 1
		for c in comp_a:
			_assert_eq(descriptors[c].terrain_component_id, i + 1, "Mountain cell comp_id mismatch")

		# Check pairwise disjointness and non-adjacency with other mountain components
		for j in range(i + 1, mtn_comps.size()):
			var comp_b: Array = mtn_comps[j]
			for c_b in comp_b:
				_assert_true(not set_a.has(c_b), "Mountain component %d and %d share cell %s!" % [i, j, c_b])
				for d in range(6):
					var adj_c: Vector2i = c_b + HexNeighborClassifierCls.DIRECTIONS[d]
					_assert_true(not set_a.has(adj_c), "Mountain component %d and %d are adjacent at %s - %s!" % [i, j, c_b, adj_c])

	_assert_eq(total_mtn_cells, 546, "Total mountain cells across all 5 components must equal 546")

	# Verify Forest components are strictly disjoint and non-adjacent
	var total_forest_cells: int = 0
	for i in range(forest_comps.size()):
		var comp_a: Array = forest_comps[i]
		total_forest_cells += comp_a.size()
		var set_a: Dictionary = {}
		for c in comp_a: set_a[c] = true

		# Check pairwise disjointness and non-adjacency
		for j in range(i + 1, forest_comps.size()):
			var comp_b: Array = forest_comps[j]
			for c_b in comp_b:
				_assert_true(not set_a.has(c_b), "Forest component %d and %d share cell %s!" % [i, j, c_b])
				for d in range(6):
					var adj_c: Vector2i = c_b + HexNeighborClassifierCls.DIRECTIONS[d]
					_assert_true(not set_a.has(adj_c), "Forest component %d and %d are adjacent at %s - %s!" % [i, j, c_b, adj_c])

	_assert_eq(total_forest_cells, 696, "Total forest cells across all 4 components must equal 696")

	# Adversarial Synthetic Topologies
	# 1. Ten isolated 1-cell islands separated by plains
	var island_descs: Dictionary = {}
	for idx in range(10):
		var origin := Vector2i(idx * 5, 0) # 5 cells apart
		var desc = HexVisualDescriptorCls.new(origin)
		desc.terrain_type = 1
		island_descs[origin] = desc
		# Surrounding buffer of plains
		for d in range(6):
			var n := origin + HexNeighborClassifierCls.DIRECTIONS[d]
			var n_desc = HexVisualDescriptorCls.new(n)
			n_desc.terrain_type = 0
			island_descs[n] = n_desc

	var island_comps = HexNeighborClassifierCls.compute_connected_components(island_descs, 1)
	_assert_eq(island_comps.size(), 10, "10 separated 1-cell islands must produce exactly 10 components")
	for comp in island_comps:
		_assert_eq(comp.size(), 1, "Each island component must have size 1")
		_assert_eq(island_descs[comp[0]].component_edge_depth, 0, "1-cell island edge depth must be 0")

	# 2. Donut topology (ring of 6 cells around a hole at 0,0)
	var donut_descs: Dictionary = {}
	var hole := Vector2i(0, 0)
	var hole_desc = HexVisualDescriptorCls.new(hole)
	hole_desc.terrain_type = 0 # Plains (hole)
	donut_descs[hole] = hole_desc
	for d in range(6):
		var ring_cell := hole + HexNeighborClassifierCls.DIRECTIONS[d]
		var desc = HexVisualDescriptorCls.new(ring_cell)
		desc.terrain_type = 1 # Mountain ring
		donut_descs[ring_cell] = desc
		# Add outer ring of plains
		for od in range(6):
			var outer_cell := ring_cell + HexNeighborClassifierCls.DIRECTIONS[od]
			if not donut_descs.has(outer_cell):
				var o_desc = HexVisualDescriptorCls.new(outer_cell)
				o_desc.terrain_type = 0
				donut_descs[outer_cell] = o_desc

	var donut_comps = HexNeighborClassifierCls.compute_connected_components(donut_descs, 1)
	_assert_eq(donut_comps.size(), 1, "Donut ring must produce exactly 1 connected component")
	_assert_eq(donut_comps[0].size(), 6, "Donut ring component size must be 6")
	for c in donut_comps[0]:
		_assert_eq(donut_descs[c].component_edge_depth, 0, "Every cell in 1-wide donut ring must have edge depth 0")

	# 3. 50-cell 1-wide serpentine snake
	var snake_descs: Dictionary = {}
	var current := Vector2i(-20, -20)
	for s_idx in range(50):
		var desc = HexVisualDescriptorCls.new(current)
		desc.terrain_type = 2 # Forest
		snake_descs[current] = desc
		current = current + HexNeighborClassifierCls.DIRECTIONS[0] # East

	var snake_comps = HexNeighborClassifierCls.compute_connected_components(snake_descs, 2)
	_assert_eq(snake_comps.size(), 1, "Snake path must produce exactly 1 component")
	_assert_eq(snake_comps[0].size(), 50, "Snake path component size must be 50")
	for c in snake_comps[0]:
		_assert_eq(snake_descs[c].component_edge_depth, 0, "Every cell in 1-wide snake must have edge depth 0")

	print("  [PASS] Track 3: Connected component separation (real map + synthetic islands/donut/snake) verified.")

# ==============================================================================
# TRACK 4: Multi-Source BFS Depth Monotony & Monotonic Gradient Verification
# ==============================================================================
func _track_4_multi_source_bfs_depth_monotony(descriptors: Dictionary) -> void:
	print("\n--- [TRACK 4] Testing Multi-Source BFS Depth Monotony & Analytical Gradients ---")
	var mtn_comps = HexNeighborClassifierCls.compute_connected_components(descriptors, 1)
	var forest_comps = HexNeighborClassifierCls.compute_connected_components(descriptors, 2)

	var all_comps = []
	all_comps.append_array(mtn_comps)
	all_comps.append_array(forest_comps)

	var non_monotonic_errors: int = 0
	var gradient_jump_errors: int = 0
	var boundary_definition_errors: int = 0
	var interior_definition_errors: int = 0
	var descent_path_errors: int = 0

	for comp in all_comps:
		var comp_set: Dictionary = {}
		for c in comp: comp_set[c] = true

		for c in comp:
			var d: int = descriptors[c].component_edge_depth

			# Check boundary condition (depth == 0 <==> has exterior neighbor)
			var has_exterior: bool = false
			for dir_idx in range(6):
				var n: Vector2i = c + HexNeighborClassifierCls.DIRECTIONS[dir_idx]
				if not comp_set.has(n):
					has_exterior = true
					break

			if d == 0 and not has_exterior:
				boundary_definition_errors += 1
			if d > 0 and has_exterior:
				interior_definition_errors += 1

			# Check gradient jump bound: |depth(c) - depth(n)| <= 1 for all adjacent in comp
			var has_descent_neighbor: bool = false
			for dir_idx in range(6):
				var n: Vector2i = c + HexNeighborClassifierCls.DIRECTIONS[dir_idx]
				if comp_set.has(n):
					var nd: int = descriptors[n].component_edge_depth
					if abs(d - nd) > 1:
						gradient_jump_errors += 1
					if nd == d - 1:
						has_descent_neighbor = true

			# If depth > 0, must have at least one neighbor with depth - 1
			if d > 0 and not has_descent_neighbor:
				non_monotonic_errors += 1

			# Full Monotonic Gradient Descent Path Check
			var walk_curr: Vector2i = c
			var walk_depth: int = d
			var steps: int = 0
			while walk_depth > 0 and steps <= d:
				var found_next: bool = false
				for dir_idx in range(6):
					var n: Vector2i = walk_curr + HexNeighborClassifierCls.DIRECTIONS[dir_idx]
					if comp_set.has(n) and descriptors[n].component_edge_depth == walk_depth - 1:
						walk_curr = n
						walk_depth -= 1
						found_next = true
						break
				steps += 1
				if not found_next:
					break
			if walk_depth != 0 or steps != d:
				descent_path_errors += 1

	_assert_eq(boundary_definition_errors, 0, "Depth 0 cells must strictly have exterior neighbors")
	_assert_eq(interior_definition_errors, 0, "Depth > 0 cells must strictly have 0 exterior neighbors")
	_assert_eq(gradient_jump_errors, 0, "Adjacent component cells must have depth difference <= 1 (Lipschitz-1 bound)")
	_assert_eq(non_monotonic_errors, 0, "Every cell with depth D > 0 must have at least one neighbor with depth D - 1")
	_assert_eq(descent_path_errors, 0, "Every cell must have a strictly monotonic descent path of length D to Depth 0")

	# Analytical Ground Truth Test: Solid Regular Hexagon of Radius 7 (169 cells)
	var solid_descs: Dictionary = {}
	var solid_coords: Array[Vector2i] = []
	for q in range(-10, 11):
		for r in range(-10, 11):
			var c := Vector2i(q, r)
			var dist: int = HexNeighborClassifierCls.axial_distance_from_origin(c)
			var desc = HexVisualDescriptorCls.new(c)
			if dist <= 7:
				desc.terrain_type = 1
				solid_coords.append(c)
			else:
				desc.terrain_type = 0
			solid_descs[c] = desc

	var solid_comps = HexNeighborClassifierCls.compute_connected_components(solid_descs, 1)
	_assert_eq(solid_comps.size(), 1, "Solid radius-7 hexagon must produce exactly 1 component")
	_assert_eq(solid_comps[0].size(), 169, "Solid radius-7 hexagon must contain exactly 169 cells (3*49 + 3*7 + 1)")

	var analytical_mismatches: int = 0
	var depth_distribution: Dictionary = {}
	for c in solid_coords:
		var dist: int = HexNeighborClassifierCls.axial_distance_from_origin(c)
		var expected_depth: int = 7 - dist
		var actual_depth: int = solid_descs[c].component_edge_depth
		depth_distribution[actual_depth] = depth_distribution.get(actual_depth, 0) + 1
		if actual_depth != expected_depth:
			analytical_mismatches += 1

	_assert_eq(analytical_mismatches, 0, "All 169 cells in solid R=7 hexagon must match analytical depth (7 - dist)")
	_assert_eq(depth_distribution.get(0, 0), 42, "Depth 0 ring must have exactly 42 cells")
	_assert_eq(depth_distribution.get(1, 0), 36, "Depth 1 ring must have exactly 36 cells")
	_assert_eq(depth_distribution.get(2, 0), 30, "Depth 2 ring must have exactly 30 cells")
	_assert_eq(depth_distribution.get(3, 0), 24, "Depth 3 ring must have exactly 24 cells")
	_assert_eq(depth_distribution.get(4, 0), 18, "Depth 4 ring must have exactly 18 cells")
	_assert_eq(depth_distribution.get(5, 0), 12, "Depth 5 ring must have exactly 12 cells")
	_assert_eq(depth_distribution.get(6, 0), 6, "Depth 6 ring must have exactly 6 cells")
	_assert_eq(depth_distribution.get(7, 0), 1, "Depth 7 core must have exactly 1 cell")

	print("  [PASS] Track 4: Multi-source BFS depth monotony (Lipschitz-1 bound, strict descent, analytical R=7 exact match) verified.")

# ==============================================================================
# TRACK 5: VisualOccupancyMap Priority Invariants & Overlap Stress
# ==============================================================================
func _track_5_visual_occupancy_adversarial_stress(descriptors: Dictionary, playable_coords: Array, cell_data: Dictionary) -> void:
	print("\n--- [TRACK 5] Testing VisualOccupancyMap Priority Invariants & Overlap Stress ---")
	var occ = VisualOccupancyMapCls.new()
	occ.initialize(playable_coords)

	# 1. Reserve Pass Corridors (Priority 1)
	var road_cells: Array[Vector2i] = []
	for coord in descriptors.keys():
		if descriptors[coord].road_present:
			road_cells.append(coord)
	var mtn_comps = HexNeighborClassifierCls.compute_connected_components(descriptors, 1)
	var mtn_cells: Dictionary = {}
	for comp in mtn_comps:
		for c in comp: mtn_cells[c] = true

	var pass_cells = occ.reserve_pass_corridors(road_cells, mtn_cells, true)
	_assert_true(pass_cells.size() >= 50, "Pass corridor count must be >= 50 cells")

	# Stress Test Priority 1: Multi-candidate mountain encroachment
	var pass_test_cells: Array[Vector2i] = [Vector2i(10, -22), Vector2i(14, -5), Vector2i(18, 14)]
	for pc in pass_test_cells:
		_assert_true(occ.is_pass_corridor(pc), "Cell %s must be recognized as pass corridor" % pc)
		var r1 = occ.claim_macro(pc, [pc], "mountain", "bad_mtn_anchor")
		_assert_true(not r1, "Mountain anchor on pass corridor %s must be rejected" % pc)
		var neighbor_outside = pc + HexNeighborClassifierCls.DIRECTIONS[0]
		var r2 = occ.claim_macro(neighbor_outside, [neighbor_outside, pc], "mountain", "bad_mtn_fp")
		_assert_true(not r2, "Mountain footprint touching pass corridor %s must be rejected" % pc)

	# 2. Reserve Unit Clearance (Priority 2)
	var clearance_cells = occ.reserve_unit_clearance([])
	_assert_true(clearance_cells.size() >= 12, "Unit clearance count must be >= 12 cells")

	# Stress Test Priority 2: Multi-candidate forest canopy encroachment
	var glade_test_cells: Array[Vector2i] = [Vector2i(-26, -6), Vector2i(24, -6), Vector2i(10, -21)]
	for gc in glade_test_cells:
		_assert_true(occ.is_unit_clearance(gc), "Cell %s must be recognized as unit clearance" % gc)
		var r1 = occ.claim_macro(gc, [gc], "forest", "bad_forest_anchor")
		_assert_true(not r1, "Forest anchor on unit clearance %s must be rejected" % gc)
		var neighbor_outside = gc + HexNeighborClassifierCls.DIRECTIONS[1]
		var r2 = occ.claim_macro(neighbor_outside, [neighbor_outside, gc], "forest", "bad_forest_fp")
		_assert_true(not r2, "Forest footprint touching unit clearance %s must be rejected" % gc)

	# 3. Same-Family Overlap Rejection Stress: 20 sequential overlapping claims
	var valid_anchor: Vector2i = mtn_comps[0][0]
	var valid_fp: Array[Vector2i] = [valid_anchor]
	for d in range(6):
		var n: Vector2i = valid_anchor + HexNeighborClassifierCls.DIRECTIONS[d]
		if mtn_cells.has(n) and not occ.is_pass_corridor(n):
			valid_fp.append(n)
			if valid_fp.size() >= 4: break

	var claim_initial = occ.claim_macro(valid_anchor, valid_fp, "mountain", "primary_mountain")
	_assert_true(claim_initial, "Primary mountain macro claim must succeed")

	for overlap_idx in range(20):
		var test_id := "overlapping_mtn_%d" % overlap_idx
		var shared_cell: Vector2i = valid_fp[overlap_idx % valid_fp.size()]
		var test_fp: Array[Vector2i] = [shared_cell, shared_cell + HexNeighborClassifierCls.DIRECTIONS[0]]
		var claim_res = occ.claim_macro(shared_cell, test_fp, "mountain", test_id)
		_assert_true(not claim_res, "Overlapping mountain macro %s must be rejected" % test_id)

	# 4. Release and Reclaim
	var release_ok = occ.release_macro("primary_mountain")
	_assert_true(release_ok, "Release macro must succeed")
	for c in valid_fp:
		_assert_true(occ.is_cell_free(c, VisualOccupancyMapCls.OccupancyFlags.MOUNTAIN_CLAIMED), "Cell %s must be free after release" % c)

	# 5. Base claiming invariant (claim_base can only succeed once)
	var sample_c: Vector2i = Vector2i(0, 0)
	var base_claim_1 = occ.claim_base(sample_c)
	var base_claim_2 = occ.claim_base(sample_c)
	_assert_true(base_claim_1, "First claim_base must succeed")
	_assert_true(not base_claim_2, "Second claim_base on same hex must fail (0 duplicate base owners)")

	# 6. Audit diagnostic detection under deliberately corrupt state
	occ._macros["corrupt_hack"] = {
		"anchor": valid_anchor,
		"family": "mountain",
		"id": "corrupt_hack",
		"role": "peak",
		"footprint": [valid_anchor]
	}
	occ._macros["corrupt_hack_2"] = {
		"anchor": valid_anchor,
		"family": "mountain",
		"id": "corrupt_hack_2",
		"role": "peak",
		"footprint": [valid_anchor]
	}
	var corrupt_audit = occ.validate_zero_overlap()
	_assert_true(not corrupt_audit["valid"], "validate_zero_overlap must catch deliberate corruption")
	_assert_true(corrupt_audit["violation_count"] >= 1, "Violation count must be >= 1 for corrupt state")

	# Clean up corruption
	occ._macros.erase("corrupt_hack")
	occ._macros.erase("corrupt_hack_2")
	var clean_audit = occ.validate_zero_overlap()
	_assert_true(clean_audit["valid"], "Clean state must have 0 violations")
	_assert_eq(clean_audit["violation_count"], 0, "Clean audit violation count must be 0")

	print("  [PASS] Track 5: VisualOccupancyMap priority protection, same-family overlap rejection, and corruption audit verified.")

# ==============================================================================
# TRACK 6: Timing, Budgets & Stress Scaling
# ==============================================================================
func _track_6_timing_and_stress_scaling(descriptors: Dictionary, river_cells: Dictionary, stronghold_cells: Dictionary) -> void:
	print("\n--- [TRACK 6] Testing Execution Timing Budgets & Repeated Stress Scaling ---")

	# 1. Mask computation budget (< 50 ms)
	var t0: int = Time.get_ticks_msec()
	for coord in descriptors.keys():
		var desc: HexVisualDescriptorCls = descriptors[coord]
		HexNeighborClassifierCls.compute_masks_for_descriptor(desc, descriptors, river_cells, stronghold_cells)
	var t_mask: int = Time.get_ticks_msec() - t0
	print("  -> 4,921 cell mask computation time: %d ms (Budget: < 50 ms)" % t_mask)
	_assert_true(t_mask < 50, "Mask computation time %d ms exceeded 50 ms budget" % t_mask)

	# 2. Connected component & BFS edge depth budget (< 50 ms)
	var t1: int = Time.get_ticks_msec()
	var mtn_comps = HexNeighborClassifierCls.compute_connected_components(descriptors, 1)
	var forest_comps = HexNeighborClassifierCls.compute_connected_components(descriptors, 2)
	var t_comps: int = Time.get_ticks_msec() - t1
	print("  -> Connected components + BFS depths time: %d ms (Budget: < 50 ms)" % t_comps)
	_assert_true(t_comps < 50, "Connected components + BFS time %d ms exceeded 50 ms budget" % t_comps)

	# 3. Batched base terrain mesh budget (< 100 ms)
	var t2: int = Time.get_ticks_msec()
	var terrain_meshes = HexBaseTerrainMeshCls.build_base_terrain(descriptors)
	var t_mesh: int = Time.get_ticks_msec() - t2
	print("  -> Batched base terrain mesh time: %d ms (Budget: < 100 ms)" % t_mesh)
	_assert_true(t_mesh < 100, "Base terrain mesh time %d ms exceeded 100 ms budget" % t_mesh)

	# 4. Passive borders budget (< 50 ms)
	var t3: int = Time.get_ticks_msec()
	var border_instance = HexBaseTerrainMeshCls.build_passive_borders(descriptors)
	var t_border: int = Time.get_ticks_msec() - t3
	print("  -> Passive borders build time: %d ms (Budget: < 50 ms)" % t_border)
	_assert_true(t_border < 50, "Passive borders time %d ms exceeded 50 ms budget" % t_border)

	# 5. Repeated execution stress (5 full cycles of mask + BFS to detect drift or memory bloat)
	var t_rep_start: int = Time.get_ticks_msec()
	for cycle in range(5):
		for coord in descriptors.keys():
			var desc: HexVisualDescriptorCls = descriptors[coord]
			HexNeighborClassifierCls.compute_masks_for_descriptor(desc, descriptors, river_cells, stronghold_cells)
		HexNeighborClassifierCls.compute_connected_components(descriptors, 1)
		HexNeighborClassifierCls.compute_connected_components(descriptors, 2)
	var t_rep_total: int = Time.get_ticks_msec() - t_rep_start
	var avg_cycle_time: float = float(t_rep_total) / 5.0
	print("  -> 5x Stress Loop average cycle time: %.2f ms (Total: %d ms)" % [avg_cycle_time, t_rep_total])
	_assert_true(avg_cycle_time < 90.0, "Stress loop average cycle time %.2f ms exceeded 90 ms budget" % avg_cycle_time)

	print("  [PASS] Track 6: Performance timing budgets and repeated stress loop verified.")
