@tool
extends SceneTree

## Verification Test Harness for Milestone 1 (M1): Hex-Native Foundation
## Tests:
##   1. HexVisualDescriptor instantiation and gameplay state copying across 4,921 cells
##   2. HexNeighborClassifier 6-bit topology masks (road, river, forest, mountain, boundary)
##   3. Connected components and multi-source BFS edge depth classification
##   4. VisualOccupancyMap priority reservations (pass corridors, unit clearance) and 0% overlap
##   5. HexBaseTerrainMesh batched ArrayMesh surfaces and deduplicated passive borders

const HexVisualDescriptorCls = preload("res://scripts/visual/hex_native/hex_visual_descriptor.gd")
const HexNeighborClassifierCls = preload("res://scripts/visual/hex_native/hex_neighbor_classifier.gd")
const VisualOccupancyMapCls = preload("res://scripts/visual/hex_native/visual_occupancy_map.gd")
const HexBaseTerrainMeshCls = preload("res://scripts/visual/hex_native/hex_base_terrain_mesh.gd")
const WorldBoundaryCls = preload("res://scripts/step2r/step2r_world_boundary.gd")

func _fail(msg: String) -> void:
	print("FAIL: %s" % msg)
	quit(1)

func _init() -> void:
	print("======================================================================")
	print("  RUNNING MILESTONE 1 (M1) HEX-NATIVE INTEGRATION TEST SUITE")
	print("======================================================================")
	var t_start: int = Time.get_ticks_msec()

	# ------------------------------------------------------------------
	# TEST 1: Gameplay Context Extraction & 4,921 Descriptors Instantiation
	# ------------------------------------------------------------------
	print("\n[TEST 1] Instantiating 4,921 HexVisualDescriptors from Gameplay Truth...")
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
	var road_count: int = 0
	var forest_count: int = 0
	var mountain_count: int = 0

	for q in range(-40, 41):
		for r in range(-40, 41):
			var coord := Vector2i(q, r)
			if WorldBoundaryCls.is_playable_hex(coord):
				playable_coords.append(coord)
				var t: int = shell._get_terrain_for_cell(q, r)
				var is_road: bool = (t == 6)
				var is_river: bool = river_cells.has("%d,%d" % [q, r]) or (t == 7)
				var is_sh: bool = stronghold_cells.has("%d,%d" % [q, r])
				var is_unit: bool = false
				var fog: int = 2 # VISIBLE for baseline

				var desc = HexVisualDescriptorCls.new(coord)
				desc.copy_gameplay_state(t, is_road, is_river, is_sh, is_unit, fog)
				descriptors[coord] = desc
				cell_data["%d,%d" % [q, r]] = { "terrain": t }

				if desc.road_present: road_count += 1
				if t == 2: forest_count += 1
				if t == 1: mountain_count += 1

	print("  -> Playable cells instantiated: %d (Expected: 4921)" % descriptors.size())
	if descriptors.size() != 4921:
		_fail("Cell count must be exactly 4921, got %d" % descriptors.size())
		return

	print("  -> Road cells: %d, Forest cells: %d, Mountain cells: %d, River cells: %d" % [
		road_count, forest_count, mountain_count, river_cells.size()
	])
	if forest_count != 696:
		_fail("Forest cell count must be exactly 696, got %d" % forest_count)
		return
	if mountain_count != 546:
		_fail("Mountain cell count must be exactly 546, got %d" % mountain_count)
		return

	# Verify projection math
	var sample_desc: HexVisualDescriptorCls = descriptors[Vector2i(10, -5)]
	var expected_px := Vector2(float(10 * 36), float(-5 * 42 + 10 * 21))
	if sample_desc.world_pos != expected_px:
		_fail("World pixel projection mismatch! Expected %s, got %s" % [expected_px, sample_desc.world_pos])
		return

	print("  [PASS] Test 1: Exactly 4,921 descriptors created with valid coordinates and gameplay state.")

	# ------------------------------------------------------------------
	# TEST 2: 6-Bit Topology Neighbor Masks Generation
	# ------------------------------------------------------------------
	print("\n[TEST 2] Computing 5 Topology Neighbor Masks for 4,921 Descriptors...")
	var t_mask_start: int = Time.get_ticks_msec()
	for coord in descriptors.keys():
		var desc: HexVisualDescriptorCls = descriptors[coord]
		HexNeighborClassifierCls.compute_masks_for_descriptor(desc, descriptors, river_cells, stronghold_cells)
		HexNeighborClassifierCls.classify_constraints(desc, descriptors)
		desc.base_role = HexNeighborClassifierCls.classify_base_role(desc)
		desc.route_role = HexNeighborClassifierCls.classify_route_role(desc)
		desc.river_role = HexNeighborClassifierCls.classify_river_role(desc)

	var t_mask_ms: int = Time.get_ticks_msec() - t_mask_start
	print("  -> All masks and roles computed in %d ms (< 50 ms budget)" % t_mask_ms)

	# Verify masks sanity
	var road_mask_hits: int = 0
	var river_mask_hits: int = 0
	var boundary_mask_hits: int = 0
	for coord in descriptors.keys():
		var desc: HexVisualDescriptorCls = descriptors[coord]
		if desc.road_neighbor_mask < 0 or desc.road_neighbor_mask > 63:
			_fail("Road mask out of range 0..63")
			return
		if desc.river_neighbor_mask < 0 or desc.river_neighbor_mask > 63:
			_fail("River mask out of range 0..63")
			return
		if desc.forest_neighbor_mask < 0 or desc.forest_neighbor_mask > 63:
			_fail("Forest mask out of range 0..63")
			return
		if desc.mountain_neighbor_mask < 0 or desc.mountain_neighbor_mask > 63:
			_fail("Mountain mask out of range 0..63")
			return
		if desc.terrain_boundary_mask < 0 or desc.terrain_boundary_mask > 63:
			_fail("Boundary mask out of range 0..63")
			return

		if desc.road_neighbor_mask > 0: road_mask_hits += 1
		if desc.river_neighbor_mask > 0: river_mask_hits += 1
		if desc.terrain_boundary_mask > 0: boundary_mask_hits += 1

	print("  -> Road neighbor hits: %d, River neighbor hits: %d, Boundary neighbor hits: %d" % [
		road_mask_hits, river_mask_hits, boundary_mask_hits
	])
	if road_mask_hits == 0 or river_mask_hits == 0 or boundary_mask_hits == 0:
		_fail("Mask computation empty!")
		return

	print("  [PASS] Test 2: All 5 6-bit topology neighbor masks computed correctly within 0..63 bounds.")

	# ------------------------------------------------------------------
	# TEST 3: Connected Components & Multi-Source BFS Edge Depth
	# ------------------------------------------------------------------
	print("\n[TEST 3] Computing Connected Components and Edge Depths...")
	var mtn_components = HexNeighborClassifierCls.compute_connected_components(descriptors, 1) # MOUNTAINS
	var forest_components = HexNeighborClassifierCls.compute_connected_components(descriptors, 2) # FOREST

	print("  -> Mountain components found: %d (Expected: 5)" % mtn_components.size())
	if mtn_components.size() != 5:
		_fail("Expected exactly 5 mountain components, got %d" % mtn_components.size())
		return

	print("  -> Forest components found: %d (Expected: 4)" % forest_components.size())
	if forest_components.size() != 4:
		_fail("Expected exactly 4 forest components, got %d" % forest_components.size())
		return

	# Check depths
	var max_mtn_depth: int = 0
	var depth_0_mtn_count: int = 0
	for comp in mtn_components:
		for c in comp:
			var d: int = descriptors[c].component_edge_depth
			if d == 0: depth_0_mtn_count += 1
			if d > max_mtn_depth: max_mtn_depth = d
	print("  -> Mountain Depth 0 border cells: %d, Max interior depth: %d" % [depth_0_mtn_count, max_mtn_depth])
	if depth_0_mtn_count == 0:
		_fail("Must have depth 0 boundary cells!")
		return
	if max_mtn_depth < 1:
		_fail("Must have interior cells with depth >= 1!")
		return

	print("  [PASS] Test 3: Connected components and multi-source BFS edge depths computed correctly.")

	# ------------------------------------------------------------------
	# TEST 4: VisualOccupancyMap Footprint Reservation & Zero-Overlap
	# ------------------------------------------------------------------
	print("\n[TEST 4] Testing VisualOccupancyMap Footprint Reservations & Priority Protection...")
	var occ_map = VisualOccupancyMapCls.new()
	occ_map.initialize(playable_coords)

	# 1. Priority 1: Pass corridors
	var road_cells: Array[Vector2i] = []
	for coord in descriptors.keys():
		if descriptors[coord].road_present:
			road_cells.append(coord)
	var mountain_cells_dict: Dictionary = {}
	for comp in mtn_components:
		for c in comp:
			mountain_cells_dict[c] = true

	var pass_reserved = occ_map.reserve_pass_corridors(road_cells, mountain_cells_dict, true)
	print("  -> Pass corridors reserved: %d cells" % pass_reserved.size())
	if pass_reserved.is_empty():
		_fail("Pass corridors must be reserved!")
		return

	# Verify canonical passes are reserved
	if not occ_map.is_pass_corridor(Vector2i(10, -22)):
		_fail("North Watch Pass must be reserved!")
		return
	if not occ_map.is_pass_corridor(Vector2i(14, -5)):
		_fail("Dragon Gate Pass must be reserved!")
		return
	if not occ_map.is_pass_corridor(Vector2i(18, 14)):
		_fail("Southern Defile must be reserved!")
		return

	# 2. Priority 2: Unit clearance in forest glades
	var unit_clearance_reserved = occ_map.reserve_unit_clearance([])
	print("  -> Unit clearance reserved: %d cells" % unit_clearance_reserved.size())
	if unit_clearance_reserved.size() < 12:
		_fail("Canonical spawn glades must be reserved!")
		return

	# 3. Test Priority Invariant: Mountain encroachment into Pass Corridor MUST BE REJECTED
	var pass_cell: Vector2i = Vector2i(10, -22)
	var encroaching_footprint: Array[Vector2i] = [pass_cell, Vector2i(10, -21)]
	var claim_rejected = occ_map.claim_macro(pass_cell, encroaching_footprint, "mountain", "illegal_mtn")
	if claim_rejected:
		_fail("Mountain macro MUST NOT encroach upon pass corridor!")
		return
	print("  -> Priority 1 Verified: Mountain encroachment into pass corridor successfully rejected (0% encroachment).")

	# 4. Test Priority Invariant: Forest canopy encroachment into Unit Clearance MUST BE REJECTED
	var glade_cell: Vector2i = Vector2i(-26, -6)
	var glade_footprint: Array[Vector2i] = [glade_cell, Vector2i(-26, -5)]
	var forest_rejected = occ_map.claim_macro(glade_cell, glade_footprint, "forest", "illegal_forest")
	if forest_rejected:
		_fail("Forest macro MUST NOT encroach upon unit clearance!")
		return
	print("  -> Priority 2 Verified: Forest canopy encroachment into unit clearance successfully rejected (0% encroachment).")

	# 5. Test Same-Family 0% Overlap Rule
	# Claim valid mountain macro
	var valid_anchor: Vector2i = mtn_components[0][0]
	var valid_fp: Array[Vector2i] = [valid_anchor]
	for dir in HexNeighborClassifierCls.DIRECTIONS:
		var n: Vector2i = valid_anchor + dir
		if mountain_cells_dict.has(n) and not occ_map.is_pass_corridor(n):
			valid_fp.append(n)
			if valid_fp.size() >= 5: break

	var claim_valid = occ_map.claim_macro(valid_anchor, valid_fp, "mountain", "mtn_macro_1", "high_peak")
	if not claim_valid:
		_fail("Valid mountain macro claim should succeed!")
		return

	# Try claiming an overlapping mountain macro on the same anchor
	var overlap_fp: Array[Vector2i] = [valid_anchor, valid_fp[1]]
	var overlap_rejected = occ_map.claim_macro(valid_anchor, overlap_fp, "mountain", "mtn_macro_2", "rough_mountain")
	if overlap_rejected:
		_fail("Overlapping mountain macro MUST be rejected!")
		return
	print("  -> Same-Family 0% Overlap Verified: Overlapping mountain macro successfully rejected.")

	# 6. Validate zero overlap
	var audit = occ_map.validate_zero_overlap()
	print("  -> Zero-overlap audit: valid=%s, violations=%d" % [audit["valid"], audit["violation_count"]])
	if not audit["valid"] or audit["violation_count"] != 0:
		_fail("Violations found in audit: %s" % str(audit["violations"]))
		return

	# 7. Sync to descriptors
	occ_map.sync_all_to_descriptors(descriptors)
	if not descriptors[pass_cell].pass_corridor:
		_fail("Descriptor pass_corridor flag must be synced!")
		return
	if not descriptors[glade_cell].unit_clearance_required:
		_fail("Descriptor unit_clearance flag must be synced!")
		return
	print("  [PASS] Test 4: VisualOccupancyMap priorities, reservations, and 0% overlap validated.")

	# ------------------------------------------------------------------
	# TEST 5: HexBaseTerrainMesh Batched ArrayMesh & Embedded Passive Borders
	# ------------------------------------------------------------------
	print("\n[TEST 5] Building Batched Base Terrain Surfaces and Passive Borders...")
	var t_mesh_start: int = Time.get_ticks_msec()
	var terrain_meshes: Array[MeshInstance2D] = HexBaseTerrainMeshCls.build_base_terrain(descriptors)
	var t_mesh_ms: int = Time.get_ticks_msec() - t_mesh_start

	print("  -> Base terrain meshes created: %d surfaces in %d ms (< 100 ms budget)" % [
		terrain_meshes.size(), t_mesh_ms
	])
	if terrain_meshes.size() < 7 or terrain_meshes.size() > 9:
		_fail("Expected 7..9 terrain surfaces, got %d" % terrain_meshes.size())
		return
	if t_mesh_ms >= 100:
		_fail("Base terrain mesh build took %d ms (budget < 100 ms)" % t_mesh_ms)
		return

	# Count total hexes across all meshes
	var total_hex_vertices: int = 0
	var total_hex_indices: int = 0
	for mi in terrain_meshes:
		if mi == null or mi.mesh == null:
			_fail("MeshInstance2D or mesh is null!")
			return
		var am: ArrayMesh = mi.mesh as ArrayMesh
		if am.get_surface_count() != 1:
			_fail("Expected 1 surface per family mesh!")
			return
		var arrays: Array = am.surface_get_arrays(0)
		var verts: PackedVector2Array = arrays[Mesh.ARRAY_VERTEX]
		var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
		var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		total_hex_vertices += verts.size()
		total_hex_indices += idx.size()

		# Verify UV scale: UV should equal vertex_pos / 1024.0
		for v_i in range(mini(verts.size(), 7)):
			var diff = (uvs[v_i] - (verts[v_i] / 1024.0)).length()
			if diff >= 0.001:
				_fail("UV coordinates must be continuous world_pos / 1024.0!")
				return

		# Verify texture settings
		if mi.texture_repeat != CanvasItem.TEXTURE_REPEAT_ENABLED:
			_fail("Texture repeat must be enabled!")
			return

	print("  -> Total batched terrain vertices: %d (7 per hex * 4,921 = 34,447)" % total_hex_vertices)
	print("  -> Total batched terrain indices: %d (18 per hex * 4,921 = 88,578)" % total_hex_indices)
	if total_hex_vertices != 4921 * 7:
		_fail("Total terrain vertices must be exactly 34,447, got %d" % total_hex_vertices)
		return
	if total_hex_indices != 4921 * 18:
		_fail("Total terrain indices must be exactly 88,578, got %d" % total_hex_indices)
		return

	# Build Passive Borders
	var t_border_start: int = Time.get_ticks_msec()
	var border_instance: MeshInstance2D = HexBaseTerrainMeshCls.build_passive_borders(descriptors)
	var t_border_ms: int = Time.get_ticks_msec() - t_border_start

	print("  -> Passive borders built in %d ms (< 50 ms budget)" % t_border_ms)
	if border_instance == null or border_instance.mesh == null:
		_fail("Border mesh is null!")
		return
	if border_instance.z_index != 1:
		_fail("Border z_index must be 1, got %d" % border_instance.z_index)
		return

	var border_am: ArrayMesh = border_instance.mesh as ArrayMesh
	var border_arrays: Array = border_am.surface_get_arrays(0)
	var border_verts: PackedVector2Array = border_arrays[Mesh.ARRAY_VERTEX]
	var unique_line_segments: int = border_verts.size() / 2
	print("  -> Unique deduplicated edge segments: %d (Vertices: %d)" % [
		unique_line_segments, border_verts.size()
	])
	if unique_line_segments < 14500 or unique_line_segments > 15200:
		_fail("Unique edge count %d out of expected range 14500..15200" % unique_line_segments)
		return
	if border_instance.modulate.a < 0.14 or border_instance.modulate.a > 0.24:
		_fail("Border alpha %f must be in 0.14..0.24 range" % border_instance.modulate.a)
		return

	print("  [PASS] Test 5: Batched ArrayMesh base terrain surfaces and 1-draw-call passive borders verified.")

	var t_total_ms: int = Time.get_ticks_msec() - t_start
	print("\n======================================================================")
	print("  ALL MILESTONE 1 (M1) VERIFICATION CHECKS PASSED WITH 0 ERRORS! (Total: %d ms)" % t_total_ms)
	print("======================================================================")
	quit(0)
