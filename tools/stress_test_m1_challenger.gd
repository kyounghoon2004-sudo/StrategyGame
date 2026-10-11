@tool
extends SceneTree

## ==============================================================================
## stress_test_m1_challenger.gd — Empirical Adversarial Stress Test Harness for M1
## Critic & Challenger: teamwork_preview_challenger_m1_2
## ==============================================================================
## Adversarially stress-tests:
##   1. Pass Corridor Encroachment: 100% rejection across all strategic passes & buffers
##   2. Unit Clearance Glade Encroachment: 100% rejection across all canonical spawn glades
##   3. Same-Family 0% Overlap Rule: 5,000+ pseudo-random colliding multi-cell footprints
##   4. Cross-Family & Structural Collision Invariants
##   5. HexBaseTerrainMesh 100% Cell Coverage (all 4,921 cells, 0 missing, 0 duplicate)
##   6. HexPassiveBorderMesh Deduplication (0 duplicate segments, exact edge geometry)
## ==============================================================================

const HexVisualDescriptorCls = preload("res://scripts/visual/hex_native/hex_visual_descriptor.gd")
const HexNeighborClassifierCls = preload("res://scripts/visual/hex_native/hex_neighbor_classifier.gd")
const VisualOccupancyMapCls = preload("res://scripts/visual/hex_native/visual_occupancy_map.gd")
const HexBaseTerrainMeshCls = preload("res://scripts/visual/hex_native/hex_base_terrain_mesh.gd")
const WorldBoundaryCls = preload("res://scripts/step2r/step2r_world_boundary.gd")

var _total_tests: int = 0
var _passed_tests: int = 0
var _failed_tests: int = 0
var _failures: Array[String] = []

func _assert(condition: bool, test_name: String, error_msg: String = "") -> void:
	_total_tests += 1
	if condition:
		_passed_tests += 1
		print("  [PASS] %s" % test_name)
	else:
		_failed_tests += 1
		var full_msg = "[FAIL] %s: %s" % [test_name, error_msg]
		_failures.append(full_msg)
		printerr("  %s" % full_msg)

func _init() -> void:
	print("======================================================================")
	print("  STARTING EMPIRICAL ADVERSARIAL CHALLENGE HARNESS (M1)")
	print("  Role: teamwork_preview_challenger_m1_2 (Critic / Empirical Challenger)")
	print("======================================================================")
	var t_start: int = Time.get_ticks_msec()

	# ------------------------------------------------------------------
	# 0. BASELINE SETUP & CONTEXT INITIALIZATION
	# ------------------------------------------------------------------
	print("\n--- [PHASE 0] Initializing Authoritative Battlefield Context ---")
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
	var mountain_coords: Array[Vector2i] = []
	var forest_coords: Array[Vector2i] = []
	var road_coords: Array[Vector2i] = []

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
				var fog: int = 2

				var desc = HexVisualDescriptorCls.new(coord)
				desc.copy_gameplay_state(t, is_road, is_river, is_sh, is_unit, fog)
				descriptors[coord] = desc
				cell_data["%d,%d" % [q, r]] = { "terrain": t }

				if desc.road_present: road_coords.append(coord)
				if t == 1: mountain_coords.append(coord)
				if t == 2: forest_coords.append(coord)

	# Compute masks and components
	for coord in descriptors.keys():
		var desc: HexVisualDescriptorCls = descriptors[coord]
		HexNeighborClassifierCls.compute_masks_for_descriptor(desc, descriptors, river_cells, stronghold_cells)
		HexNeighborClassifierCls.classify_constraints(desc, descriptors)
		desc.base_role = HexNeighborClassifierCls.classify_base_role(desc)
		desc.route_role = HexNeighborClassifierCls.classify_route_role(desc)
		desc.river_role = HexNeighborClassifierCls.classify_river_role(desc)

	var mtn_components = HexNeighborClassifierCls.compute_connected_components(descriptors, 1)
	var forest_components = HexNeighborClassifierCls.compute_connected_components(descriptors, 2)

	_assert(descriptors.size() == 4921, "Setup: Exactly 4,921 playable descriptors", "Found %d" % descriptors.size())
	_assert(mountain_coords.size() == 546, "Setup: Exactly 546 mountain cells", "Found %d" % mountain_coords.size())
	_assert(forest_coords.size() == 696, "Setup: Exactly 696 forest cells", "Found %d" % forest_coords.size())

	# Initialize VisualOccupancyMap
	var occ = VisualOccupancyMapCls.new()
	occ.initialize(playable_coords)

	var mountain_dict: Dictionary = {}
	for mc in mountain_coords: mountain_dict[mc] = true

	# Reserve routes and pass corridors
	occ.reserve_routes(road_coords)
	var pass_corridors = occ.reserve_pass_corridors(road_coords, mountain_dict, true)
	var unit_clearances = occ.reserve_unit_clearance([])
	occ.reserve_strongholds({
		"Fortress_Hulao": shell.FORTRESS_FOOTPRINT,
		"Capital_Luoyang": shell.CAPITAL_FOOTPRINT
	})

	print("  Authoritative state: %d pass corridors, %d unit clearance glades reserved." % [
		pass_corridors.size(), unit_clearances.size()
	])

	# ------------------------------------------------------------------
	# 1. ADVERSARIAL ATTACK 1: Pass Corridor Encroachment Attacks
	# ------------------------------------------------------------------
	print("\n--- [ATTACK 1] Stress-Testing Mountain Pass Corridor Encroachment ---")
	var pass_attack_count: int = 0
	var pass_rejected_count: int = 0
	var pass_accepted_count: int = 0

	# Test 1A: Direct single-cell and multi-cell encroachment on every reserved pass cell
	for pc in pass_corridors:
		# Single cell
		pass_attack_count += 1
		if not occ.can_claim_macro(pc, [pc], "mountain"):
			pass_rejected_count += 1
		else:
			pass_accepted_count += 1
			printerr("SECURITY BREACH: Pass corridor cell %s accepted single mountain claim!" % [pc])

		# Multi-cell centered on pass cell
		var fp_multi: Array[Vector2i] = [pc]
		for dir in HexNeighborClassifierCls.DIRECTIONS:
			fp_multi.append(pc + dir)
		pass_attack_count += 1
		if not occ.can_claim_macro(pc, fp_multi, "mountain"):
			pass_rejected_count += 1
		else:
			pass_accepted_count += 1
			printerr("SECURITY BREACH: Pass corridor cell %s accepted multi mountain claim!" % [pc])

	# Test 1B: Strategic Passes explicit focus (Dragon Gate, North Watch, Southern Defile)
	var strategic_pass_foci: Array[Vector2i] = [
		Vector2i(14, -5), Vector2i(13, -5), Vector2i(15, -5), # Dragon Gate
		Vector2i(10, -22), Vector2i(9, -22), Vector2i(11, -22), # North Watch
		Vector2i(18, 14), Vector2i(17, 14), Vector2i(19, 14)   # Southern Defile
	]
	for spc in strategic_pass_foci:
		_assert(occ.is_pass_corridor(spc), "Strategic pass focus %s is reserved" % [spc])
		# Try claiming from an outside mountain anchor into the strategic pass
		for dir in HexNeighborClassifierCls.DIRECTIONS:
			var ext_anchor: Vector2i = spc + dir
			var encroaching_fp: Array[Vector2i] = [ext_anchor, spc]
			pass_attack_count += 1
			if not occ.can_claim_macro(ext_anchor, encroaching_fp, "mountain"):
				pass_rejected_count += 1
			else:
				pass_accepted_count += 1
				printerr("SECURITY BREACH: Encroachment from %s into strategic pass %s accepted!" % [ext_anchor, spc])

	# Test 1C: Pseudo-random fuzzing targeting pass corridors
	var rng := RandomNumberGenerator.new()
	rng.seed = 987654
	for i in range(1000):
		var target_pass: Vector2i = pass_corridors[rng.randi() % pass_corridors.size()]
		var fp_size: int = rng.randi_range(2, 7)
		var rand_fp: Array[Vector2i] = [target_pass]
		var curr := target_pass
		for s in range(fp_size - 1):
			var dir_idx := rng.randi() % 6
			curr = curr + HexNeighborClassifierCls.DIRECTIONS[dir_idx]
			if not rand_fp.has(curr):
				rand_fp.append(curr)
		pass_attack_count += 1
		if not occ.can_claim_macro(target_pass, rand_fp, "mountain"):
			pass_rejected_count += 1
		else:
			pass_accepted_count += 1
			printerr("SECURITY BREACH: Fuzzed mountain macro accepted on pass corridor!")

	_assert(pass_accepted_count == 0, "Pass Corridor Encroachment: 0 accepted intrusions", "Accepted %d intrusions" % pass_accepted_count)
	_assert(pass_rejected_count == pass_attack_count, "Pass Corridor Encroachment: 100%% rejected (%d/%d)" % [pass_rejected_count, pass_attack_count])

	# ------------------------------------------------------------------
	# 2. ADVERSARIAL ATTACK 2: Unit Clearance Glade Encroachment Attacks
	# ------------------------------------------------------------------
	print("\n--- [ATTACK 2] Stress-Testing Unit Clearance Glade Encroachment ---")
	var glade_attack_count: int = 0
	var glade_rejected_count: int = 0
	var glade_accepted_count: int = 0

	for gc in unit_clearances:
		# Single cell forest claim
		glade_attack_count += 1
		if not occ.can_claim_macro(gc, [gc], "forest"):
			glade_rejected_count += 1
		else:
			glade_accepted_count += 1
			printerr("SECURITY BREACH: Glade cell %s accepted forest claim!" % [gc])

		# Multi-cell forest claim anchored at glade
		var fp_glade: Array[Vector2i] = [gc]
		for dir in HexNeighborClassifierCls.DIRECTIONS:
			fp_glade.append(gc + dir)
		glade_attack_count += 1
		if not occ.can_claim_macro(gc, fp_glade, "forest"):
			glade_rejected_count += 1
		else:
			glade_accepted_count += 1
			printerr("SECURITY BREACH: Glade cell %s accepted multi forest claim!" % [gc])

		# Outside anchor encroaching into glade
		for dir in HexNeighborClassifierCls.DIRECTIONS:
			var ext_anchor: Vector2i = gc + dir
			var encroaching_fp: Array[Vector2i] = [ext_anchor, gc]
			glade_attack_count += 1
			if not occ.can_claim_macro(ext_anchor, encroaching_fp, "forest"):
				glade_rejected_count += 1
			else:
				glade_accepted_count += 1
				printerr("SECURITY BREACH: Outside anchor %s encroaching into glade %s accepted!" % [ext_anchor, gc])

	# Fuzzing unit clearance with 1,000 forest candidates
	for i in range(1000):
		var target_glade: Vector2i = unit_clearances[rng.randi() % unit_clearances.size()]
		var fp_size: int = rng.randi_range(2, 5)
		var rand_fp: Array[Vector2i] = [target_glade]
		var curr := target_glade
		for s in range(fp_size - 1):
			var dir_idx := rng.randi() % 6
			curr = curr + HexNeighborClassifierCls.DIRECTIONS[dir_idx]
			if not rand_fp.has(curr):
				rand_fp.append(curr)
		glade_attack_count += 1
		if not occ.can_claim_macro(target_glade, rand_fp, "forest"):
			glade_rejected_count += 1
		else:
			glade_accepted_count += 1
			printerr("SECURITY BREACH: Fuzzed forest macro accepted on unit clearance glade!")

	_assert(glade_accepted_count == 0, "Unit Clearance Encroachment: 0 accepted intrusions", "Accepted %d intrusions" % glade_accepted_count)
	_assert(glade_rejected_count == glade_attack_count, "Unit Clearance Encroachment: 100%% rejected (%d/%d)" % [glade_rejected_count, glade_attack_count])

	# ------------------------------------------------------------------
	# 3. ADVERSARIAL ATTACK 3: Same-Family 0% Overlap Rule & Mass Collision Stress
	# ------------------------------------------------------------------
	print("\n--- [ATTACK 3] Stress-Testing Same-Family 0% Overlap Rule & Massive Footprint Collisions ---")
	# Seed initial legitimate macros
	var registered_mountains: Array[Dictionary] = []
	var registered_forests: Array[Dictionary] = []

	# Register initial mountain macros
	for comp_idx in range(mtn_components.size()):
		var comp = mtn_components[comp_idx]
		for cell_idx in range(0, comp.size(), 8):
			var anchor: Vector2i = comp[cell_idx]
			var fp: Array[Vector2i] = occ.build_candidate_footprint(anchor, 1, 3, 5, cell_data)
			if fp.size() >= 3:
				var m_id := "adv_mtn_%d_%d" % [anchor.x, anchor.y]
				if occ.claim_macro(anchor, fp, "mountain", m_id, "rough_mountain"):
					registered_mountains.append({ "id": m_id, "anchor": anchor, "footprint": fp })

	# Register initial forest macros
	for comp_idx in range(forest_components.size()):
		var comp = forest_components[comp_idx]
		for cell_idx in range(0, comp.size(), 6):
			var anchor: Vector2i = comp[cell_idx]
			var fp: Array[Vector2i] = occ.build_candidate_footprint(anchor, 2, 2, 4, cell_data)
			if fp.size() >= 2:
				var f_id := "adv_forest_%d_%d" % [anchor.x, anchor.y]
				if occ.claim_macro(anchor, fp, "forest", f_id, "forest_interior"):
					registered_forests.append({ "id": f_id, "anchor": anchor, "footprint": fp })

	print("  Base state established: %d mountain macros, %d forest macros registered." % [
		registered_mountains.size(), registered_forests.size()
	])
	_assert(registered_mountains.size() > 0, "Initial mountain macros successfully registered", "Count: %d" % registered_mountains.size())
	_assert(registered_forests.size() > 0, "Initial forest macros successfully registered", "Count: %d" % registered_forests.size())

	# Initial zero-overlap audit
	var audit_init = occ.validate_zero_overlap()
	_assert(audit_init["valid"] and audit_init["violation_count"] == 0, "Initial state zero-overlap audit clean", "Violations: %s" % str(audit_init["violations"]))

	# Attack 3A: Exact duplicate same-family macro registrations
	var dup_rejected: int = 0
	var dup_total: int = 0
	for m in registered_mountains:
		dup_total += 1
		var fp: Array[Vector2i] = m["footprint"]
		# Attempt registering exact duplicate footprint with new ID
		var new_id: String = "duplicate_" + str(m["id"])
		if not occ.claim_macro(m["anchor"], fp, "mountain", new_id, "high_peak"):
			dup_rejected += 1
		else:
			printerr("SECURITY BREACH: Duplicate mountain registration accepted for %s!" % [m["id"]])

	for f in registered_forests:
		dup_total += 1
		var fp: Array[Vector2i] = f["footprint"]
		var new_id: String = "duplicate_" + str(f["id"])
		if not occ.claim_macro(f["anchor"], fp, "forest", new_id, "forest_edge"):
			dup_rejected += 1
		else:
			printerr("SECURITY BREACH: Duplicate forest registration accepted for %s!" % [f["id"]])

	_assert(dup_rejected == dup_total, "Duplicate Same-Family Registration: 100%% rejected (%d/%d)" % [dup_rejected, dup_total])

	# Attack 3B: Partial Overlap Collisions (1-cell, 2-cell overlaps)
	var partial_rejected: int = 0
	var partial_total: int = 0
	for m in registered_mountains:
		var fp: Array[Vector2i] = m["footprint"]
		for shared_cell in fp:
			# Construct a candidate that shares exactly `shared_cell`
			var candidate_fp: Array[Vector2i] = [shared_cell]
			for dir in HexNeighborClassifierCls.DIRECTIONS:
				var cand_n = shared_cell + dir
				if not candidate_fp.has(cand_n) and WorldBoundaryCls.is_playable_hex(cand_n):
					candidate_fp.append(cand_n)
					if candidate_fp.size() >= 3: break
			partial_total += 1
			if not occ.can_claim_macro(candidate_fp[0], candidate_fp, "mountain"):
				partial_rejected += 1
			else:
				printerr("SECURITY BREACH: Partial mountain overlap accepted sharing cell %s!" % [shared_cell])

	for f in registered_forests:
		var fp: Array[Vector2i] = f["footprint"]
		for shared_cell in fp:
			var candidate_fp: Array[Vector2i] = [shared_cell]
			for dir in HexNeighborClassifierCls.DIRECTIONS:
				var cand_n = shared_cell + dir
				if not candidate_fp.has(cand_n) and WorldBoundaryCls.is_playable_hex(cand_n):
					candidate_fp.append(cand_n)
					if candidate_fp.size() >= 2: break
			partial_total += 1
			if not occ.can_claim_macro(candidate_fp[0], candidate_fp, "forest"):
				partial_rejected += 1
			else:
				printerr("SECURITY BREACH: Partial forest overlap accepted sharing cell %s!" % [shared_cell])

	_assert(partial_rejected == partial_total, "Partial Overlap Collisions: 100%% rejected (%d/%d)" % [partial_rejected, partial_total])

	# Attack 3C: Massive 5,000 Pseudo-Random Conflicting Footprints Stress Test
	print("  Running 5,000 pseudo-random conflicting multi-cell footprint registrations...")
	var rand_attempts: int = 5000
	var rand_claimed_success: int = 0
	var rand_rejected_count: int = 0
	var zero_overlap_violation_found: bool = false

	rng.seed = 55443322
	for i in range(rand_attempts):
		var anchor: Vector2i = playable_coords[rng.randi() % playable_coords.size()]
		var fp_size: int = rng.randi_range(2, 6)
		var rand_fp: Array[Vector2i] = [anchor]
		var curr := anchor
		for s in range(fp_size - 1):
			var dir_idx := rng.randi() % 6
			curr = curr + HexNeighborClassifierCls.DIRECTIONS[dir_idx]
			if not rand_fp.has(curr):
				rand_fp.append(curr)

		var family: String = "mountain" if (i % 2 == 0) else "forest"
		var test_id := "random_macro_%d" % i

		var can_claim: bool = occ.can_claim_macro(anchor, rand_fp, family)
		if can_claim:
			var claimed: bool = occ.claim_macro(anchor, rand_fp, family, test_id)
			if claimed:
				rand_claimed_success += 1
			else:
				_assert(false, "Inconsistency: can_claim_macro was true but claim_macro failed!")
		else:
			# Verify that claim_macro also rejects
			var claimed: bool = occ.claim_macro(anchor, rand_fp, family, test_id)
			if claimed:
				printerr("SECURITY CRITICAL: can_claim_macro returned false but claim_macro SUCCEEDED!")
				zero_overlap_violation_found = true
			rand_rejected_count += 1

	print("  -> 5,000 stress attempts: %d rejected, %d legally placed." % [rand_rejected_count, rand_claimed_success])
	_assert(not zero_overlap_violation_found, "Consistency between can_claim_macro and claim_macro maintained")

	# Audit the resulting occupancy map for ANY violation
	var final_audit = occ.validate_zero_overlap()
	_assert(final_audit["valid"], "Zero-overlap audit valid after 5,000 stress attempts", "Violations found: %s" % str(final_audit["violations"]))
	_assert(final_audit["violation_count"] == 0, "Zero violations detected in audit", "Count: %d" % final_audit["violation_count"])

	# ------------------------------------------------------------------
	# 4. ADVERSARIAL ATTACK 4: Edge Cases, Structures, and Boundary Constraints
	# ------------------------------------------------------------------
	print("\n--- [ATTACK 4] Stress-Testing Edge Cases, Structures, and Boundary Invariants ---")

	# 4A: Structure Protection (Nature cannot claim Fortress or Capital)
	var hulao_anchor := Vector2i(-4, 2)
	_assert(not occ.can_claim_macro(hulao_anchor, [hulao_anchor], "mountain"), "Structure Protection: Mountain cannot claim Fortress Hulao")
	_assert(not occ.can_claim_macro(hulao_anchor, [hulao_anchor], "forest"), "Structure Protection: Forest cannot claim Fortress Hulao")
	var luoyang_anchor := Vector2i(14, -5) # Note: Luoyang is also Dragon Gate pass corridor!
	_assert(not occ.can_claim_macro(luoyang_anchor, [luoyang_anchor], "mountain"), "Structure Protection: Mountain cannot claim Capital Luoyang")

	# 4B: Out-of-bounds footprint rejection
	var oob_fp: Array[Vector2i] = [Vector2i(45, 45), Vector2i(46, 45)]
	_assert(not occ.can_claim_macro(oob_fp[0], oob_fp, "mountain"), "Boundary: Out-of-bounds footprint rejected")

	# 4C: Empty footprint rejection
	_assert(not occ.can_claim_macro(Vector2i(0, 0), [], "mountain"), "Boundary: Empty footprint rejected")

	# 4D: Ground Base Single Owner Rule (0% double base)
	var double_base_violations: int = 0
	for coord in playable_coords:
		occ.claim_base(coord)
	for coord in playable_coords:
		var second_claim: bool = occ.claim_base(coord)
		if second_claim:
			double_base_violations += 1
	_assert(double_base_violations == 0, "Ground Base: 100%% rejection of second base claim (0%% double base)")

	# 4E: Transition limit (max 2)
	var test_c := Vector2i(0, 0)
	var t1 = occ.claim_transition(test_c)
	var t2 = occ.claim_transition(test_c)
	var t3 = occ.claim_transition(test_c)
	_assert(t1 and t2 and not t3, "Transition Slot: Exactly 2 transitions allowed, 3rd rejected")

	# 4F: Decoration slot constraints (no props on road/river/structure)
	var road_c = road_coords[0]
	_assert(not occ.can_claim_decoration(road_c), "Decoration Slot: Cannot place prop on road ribbon")
	var deco_c = Vector2i(2, 2)
	if not occ.has_cell(deco_c) or occ.get_cell(deco_c).route_claimed:
		deco_c = Vector2i(3, 3)
	var d1 = occ.claim_decoration(deco_c, "prop_1")
	var d2 = occ.claim_decoration(deco_c, "prop_2")
	_assert(d1 and not d2, "Decoration Slot: Max 1 decoration per cell, 2nd rejected")

	# ------------------------------------------------------------------
	# 5. ADVERSARIAL ATTACK 5: HexBaseTerrainMesh 100% Cell Coverage Stress Test
	# ------------------------------------------------------------------
	print("\n--- [ATTACK 5] Stress-Testing HexBaseTerrainMesh 100% Cell Coverage ---")
	var terrain_meshes: Array[MeshInstance2D] = HexBaseTerrainMeshCls.build_base_terrain(descriptors)
	_assert(terrain_meshes.size() >= 7 and terrain_meshes.size() <= 9, "Base Terrain: 7..9 batched surface meshes created", "Got %d" % terrain_meshes.size())

	var covered_cells: Dictionary = {}
	var duplicate_cells: Array[Vector2i] = []
	var nan_or_inf_verts: int = 0
	var uv_distortion_count: int = 0
	var total_mesh_vertices: int = 0
	var total_mesh_indices: int = 0

	for mi in terrain_meshes:
		_assert(mi != null and mi.mesh != null, "MeshInstance2D and ArrayMesh valid for %s" % mi.name)
		var am: ArrayMesh = mi.mesh as ArrayMesh
		_assert(am.get_surface_count() == 1, "ArrayMesh has exactly 1 surface")

		var arrays: Array = am.surface_get_arrays(0)
		var verts: PackedVector2Array = arrays[Mesh.ARRAY_VERTEX]
		var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]

		total_mesh_vertices += verts.size()
		total_mesh_indices += indices.size()

		var cell_count_in_mesh: int = verts.size() / 7
		_assert(verts.size() % 7 == 0, "Vertex count (%d) is exact multiple of 7" % verts.size())
		_assert(indices.size() % 18 == 0, "Index count (%d) is exact multiple of 18" % indices.size())

		for h_i in range(cell_count_in_mesh):
			var base_v: int = h_i * 7
			var center: Vector2 = verts[base_v]

			# Check for NaN / Inf
			if is_nan(center.x) or is_nan(center.y) or is_inf(center.x) or is_inf(center.y):
				nan_or_inf_verts += 1

			# Reverse project center to axial (q, r)
			# world_pos = Vector2(q * 36, r * 42 + q * 21)
			# q = round(x / 36)
			# r = round((y - q * 21) / 42)
			var q: int = int(round(center.x / 36.0))
			var r: int = int(round((center.y - float(q * 21)) / 42.0))
			var coord := Vector2i(q, r)

			if covered_cells.has(coord):
				duplicate_cells.append(coord)
			else:
				covered_cells[coord] = true

			# Verify UV projection for all 7 vertices of this cell
			for v_k in range(7):
				var v_pos: Vector2 = verts[base_v + v_k]
				var expected_uv: Vector2 = v_pos / 1024.0
				var actual_uv: Vector2 = uvs[base_v + v_k]
				if (actual_uv - expected_uv).length() > 0.0001:
					uv_distortion_count += 1

	# Verification checks
	_assert(nan_or_inf_verts == 0, "Geometry: 0 NaN or Inf vertices found")
	_assert(uv_distortion_count == 0, "UV Projection: 0 UV distortions across all vertices")
	_assert(duplicate_cells.size() == 0, "Coverage: Exactly 0 duplicate cells across surfaces", "Duplicates: %d" % duplicate_cells.size())
	_assert(covered_cells.size() == 4921, "Coverage: Exactly 4,921 cells covered (100%%)", "Covered: %d / 4921" % covered_cells.size())

	# Find any missing cells
	var missing_cells: Array[Vector2i] = []
	for coord in playable_coords:
		if not covered_cells.has(coord):
			missing_cells.append(coord)
	_assert(missing_cells.size() == 0, "Coverage: Exactly 0 missing cells", "Missing %d cells: %s" % [missing_cells.size(), str(missing_cells)])

	_assert(total_mesh_vertices == 4921 * 7, "Vertex Total: Exactly 34,447 vertices (4,921 * 7)", "Got %d" % total_mesh_vertices)
	_assert(total_mesh_indices == 4921 * 18, "Index Total: Exactly 88,578 indices (4,921 * 18)", "Got %d" % total_mesh_indices)

	# ------------------------------------------------------------------
	# 6. ADVERSARIAL ATTACK 6: HexPassiveBorderMesh Deduplication & Segment Exactness
	# ------------------------------------------------------------------
	print("\n--- [ATTACK 6] Stress-Testing HexPassiveBorderMesh Deduplication ---")
	var border_instance: MeshInstance2D = HexBaseTerrainMeshCls.build_passive_borders(descriptors)
	_assert(border_instance != null and border_instance.mesh != null, "Passive Borders: MeshInstance2D built successfully")
	_assert(border_instance.z_index == 1, "Passive Borders: z_index is exactly 1")
	_assert(border_instance.modulate.a >= 0.14 and border_instance.modulate.a <= 0.24, "Passive Borders: alpha in 0.14..0.24 range (actual: %f)" % border_instance.modulate.a)

	var border_am: ArrayMesh = border_instance.mesh as ArrayMesh
	var border_arrays: Array = border_am.surface_get_arrays(0)
	var border_verts: PackedVector2Array = border_arrays[Mesh.ARRAY_VERTEX]

	_assert(border_verts.size() % 2 == 0, "Border vertices count is even (%d)" % border_verts.size())
	var total_border_segments: int = border_verts.size() / 2

	# Hash and deduplicate segments
	var unique_segments: Dictionary = {}
	var duplicate_segment_count: int = 0
	var invalid_edge_lengths: int = 0

	for s_i in range(total_border_segments):
		var p1: Vector2 = border_verts[s_i * 2]
		var p2: Vector2 = border_verts[s_i * 2 + 1]

		# Verify edge length matches hex metrics
		# Canonical outer vertices have edge lengths:
		# horizontal flat top/bottom: 24.0 px
		# slanted edges: sqrt(12^2 + 21^2) = sqrt(585) ≈ 24.18677 px
		var edge_len: float = (p2 - p1).length()
		if abs(edge_len - 24.0) > 0.3:
			invalid_edge_lengths += 1

		# Canonicalize segment order (p_min, p_max)
		var p_min: Vector2 = p1
		var p_max: Vector2 = p2
		if p1.x > p2.x or (abs(p1.x - p2.x) < 0.001 and p1.y > p2.y):
			p_min = p2
			p_max = p1

		var key := "%.2f,%.2f_%.2f,%.2f" % [p_min.x, p_min.y, p_max.x, p_max.y]
		if unique_segments.has(key):
			duplicate_segment_count += 1
		else:
			unique_segments[key] = true

	print("  -> Total border line segments: %d, Unique segments: %d, Duplicates: %d" % [
		total_border_segments, unique_segments.size(), duplicate_segment_count
	])
	_assert(duplicate_segment_count == 0, "Passive Borders: Exactly 0 duplicate line segments", "Found %d duplicates" % duplicate_segment_count)
	_assert(unique_segments.size() == total_border_segments, "Passive Borders: 100%% segment uniqueness (%d/%d)" % [unique_segments.size(), total_border_segments])
	_assert(total_border_segments >= 14500 and total_border_segments <= 15200, "Passive Borders: Segment count within expected Euler bounds 14,500..15,200", "Count: %d" % total_border_segments)
	_assert(invalid_edge_lengths == 0, "Passive Borders: 0 invalid edge lengths (all match 24.0..24.2 px hex metrics)")

	# ------------------------------------------------------------------
	# 7. ADVERSARIAL ATTACK 7: White-Box Edge Case Deep Dive
	# ------------------------------------------------------------------
	print("\n--- [ATTACK 7] White-Box Boundary & Robustness Stress Testing ---")
	var occ_deep = VisualOccupancyMapCls.new()
	occ_deep.initialize(playable_coords)
	occ_deep.reserve_routes(road_coords)
	occ_deep.reserve_pass_corridors(road_coords, mountain_dict, true)
	occ_deep.reserve_unit_clearance([])

	# Test 7A: Nature macro vs Nature macro cross-family mutual exclusion
	var free_nature_cell: Vector2i = Vector2i(-15, -15) # Open plain
	_assert(occ_deep.is_cell_free(free_nature_cell), "Cell %s is initially free" % free_nature_cell)
	var claim_mtn = occ_deep.claim_macro(free_nature_cell, [free_nature_cell], "mountain", "nature_mtn")
	_assert(claim_mtn, "Mountain claimed on free cell")
	var claim_forest_on_mtn = occ_deep.claim_macro(free_nature_cell, [free_nature_cell], "forest", "nature_forest")
	_assert(not claim_forest_on_mtn, "Forest cannot claim over existing mountain macro (cross-nature exclusion)")

	# Test 7B: Structure claim on existing mountain macro
	var claim_struct_on_mtn = occ_deep.can_claim_structure(free_nature_cell, [free_nature_cell])
	print("  -> White-box probe: Can structure claim over existing mountain macro? Result: %s" % claim_struct_on_mtn)

	# Test 7C: Internal duplicate coordinates within candidate footprint
	var free_c2 := Vector2i(-16, -15)
	var dup_coord_fp: Array[Vector2i] = [free_c2, free_c2]
	var can_claim_internal_dup = occ_deep.can_claim_macro(free_c2, dup_coord_fp, "mountain")
	print("  -> White-box probe: Can footprint with internal duplicate coords [C, C] claim? Result: %s" % can_claim_internal_dup)
	if can_claim_internal_dup:
		occ_deep.claim_macro(free_c2, dup_coord_fp, "mountain", "internal_dup_test")
		var dup_audit = occ_deep.validate_zero_overlap()
		_assert(not dup_audit["valid"], "validate_zero_overlap catches internal duplicate coords violation", "Audit valid: %s" % dup_audit["valid"])
		occ_deep.release_macro("internal_dup_test")

	# Test 7D: Duplicate macro ID on disjoint coordinates
	var free_c3 := Vector2i(-17, -15)
	var free_c4 := Vector2i(-18, -15)
	var claim_id1 = occ_deep.claim_macro(free_c3, [free_c3], "mountain", "duplicate_id_test")
	_assert(claim_id1, "First macro with ID duplicate_id_test claimed")
	var claim_id2 = occ_deep.claim_macro(free_c4, [free_c4], "mountain", "duplicate_id_test")
	print("  -> White-box probe: Does claim_macro permit re-using existing ID on disjoint cells? Result: %s" % claim_id2)

	# Test 7E: Macro Release and Re-claim cycle
	var free_c5 := Vector2i(-19, -15)
	var claim_c5 = occ_deep.claim_macro(free_c5, [free_c5], "forest", "cycle_test")
	_assert(claim_c5, "Macro cycle_test claimed")
	_assert(not occ_deep.is_cell_free(free_c5), "Cell is occupied")
	var released = occ_deep.release_macro("cycle_test")
	_assert(released, "Macro cycle_test successfully released")
	_assert(occ_deep.is_cell_free(free_c5), "Cell is free after release")
	var reclaim = occ_deep.claim_macro(free_c5, [free_c5], "mountain", "cycle_test_reclaimed")
	_assert(reclaim, "Cell can be successfully re-claimed after release")

	# ------------------------------------------------------------------
	# SUMMARY & VERDICT
	# ------------------------------------------------------------------
	var t_elapsed: int = Time.get_ticks_msec() - t_start
	print("\n======================================================================")
	print("  ADVERSARIAL STRESS TEST SUMMARY")
	print("======================================================================")
	print("  Total Invariants Tested: %d" % _total_tests)
	print("  Passed: %d" % _passed_tests)
	print("  Failed: %d" % _failed_tests)
	print("  Execution Time: %d ms" % t_elapsed)

	if _failed_tests > 0:
		print("\n  FAILURES ENCOUNTERED:")
		for f in _failures:
			printerr("    - %s" % f)
		print("\n  VERDICT: REJECT")
		quit(1)
	else:
		print("\n  ALL ADVERSARIAL STRESS INVARIANTS PASSED PERFECTLY!")
		print("  VERDICT: APPROVE")
		quit(0)
