@tool
extends SceneTree

const HexForestCompositorCls = preload("res://scripts/visual/hex_native/hex_forest_compositor.gd")
const Registry = preload("res://scripts/visual/hex_native/approved_asset_registry.gd")
const WorldBoundaryCls = preload("res://scripts/step2r/step2r_world_boundary.gd")

func _init() -> void:
	print("======================================================================")
	print("  FOREST HEX DENSITY & CONTAINMENT VERIFICATION HARNESS")
	print("======================================================================")
	var t0: int = Time.get_ticks_msec()

	# 1. Instantiate battlefield shell and extract cell data
	var shell = load("res://scripts/step2r/step2r_battlefield_shell.gd").new()
	shell._build_river_path()
	var river_cells: Dictionary = shell._river_cells

	var stronghold_cells: Dictionary = {}
	for h in shell.FORTRESS_FOOTPRINT:
		stronghold_cells["%d,%d" % [h.x, h.y]] = true
	for h in shell.CAPITAL_FOOTPRINT:
		stronghold_cells["%d,%d" % [h.x, h.y]] = true

	var GrammarCls = preload("res://scripts/visual/hex_native/hex_visual_grammar.gd")
	var cell_data: Dictionary = {}
	for q in range(-40, 41):
		for r in range(-40, 41):
			var coord := Vector2i(q, r)
			if WorldBoundaryCls.is_playable_hex(coord):
				cell_data[coord] = {
					"terrain": shell._get_terrain_for_cell(q, r)
				}

	var descriptors: Dictionary = GrammarCls.build_descriptors(cell_data, river_cells, stronghold_cells, [], null)
	
	# 2. Collect all forest cells
	var forest_coords: Array[Vector2i] = []
	for c in descriptors.keys():
		if int(descriptors[c].terrain_type) == 2:
			forest_coords.append(c)

	print("Total forest cells found: %d" % forest_coords.size())

	# 3. Track metrics
	var role_counts: Dictionary = {}
	var total_sprites: int = 0
	var total_overflows: int = 0
	var used_resources: Dictionary = {}
	var min_sprites_per_cell: int = 999
	var max_sprites_per_cell: int = 0
	var sprites_per_role: Dictionary = {}

	# Inset hex half-plane parameters
	var s_inset: float = HexForestCompositorCls.INSET_SCALE
	var y_max: float = 21.0 * s_inset
	var c_limit: float = 168.0 * s_inset

	var overflow_details: Array[String] = []

	for coord in forest_coords:
		var d = descriptors[coord]
		var role: int = HexForestCompositorCls.classify_role(d)
		role_counts[role] = int(role_counts.get(role, 0)) + 1

		var plan: Dictionary = HexForestCompositorCls.plan_cell_composition(coord, role, d, descriptors)
		var sprites: Array = plan.get("sprites", [])
		var count: int = sprites.size()
		total_sprites += count

		if count < min_sprites_per_cell:
			min_sprites_per_cell = count
		if count > max_sprites_per_cell:
			max_sprites_per_cell = count

		var role_arr: Array = sprites_per_role.get(role, [])
		role_arr.append(count)
		sprites_per_role[role] = role_arr

		var center: Vector2 = d.world_pos

		for sp in sprites:
			var res_path: String = sp["path"]
			used_resources[res_path] = int(used_resources.get(res_path, 0)) + 1

			# Test containment: rect in local coordinates relative to cell center
			var rect: Rect2 = sp["rect"]
			var local_rect := Rect2(rect.position - center, rect.size)

			var x1: float = local_rect.position.x
			var x2: float = local_rect.position.x + local_rect.size.x
			var y1: float = local_rect.position.y
			var y2: float = local_rect.position.y + local_rect.size.y

			# Check the 6 half-planes on all 4 corners
			# Allow tiny epsilon for floating point arithmetic
			var eps: float = 0.05

			var corners := [
				Vector2(x1, y1), # Top-Left
				Vector2(x2, y1), # Top-Right
				Vector2(x2, y2), # Bottom-Right
				Vector2(x1, y2)  # Bottom-Left
			]

			var sp_overflow: bool = false
			for pt in corners:
				if pt.y < -y_max - eps:
					sp_overflow = true
				if pt.y > y_max + eps:
					sp_overflow = true
				if 7.0 * pt.x - 4.0 * pt.y > c_limit + eps:
					sp_overflow = true
				if 7.0 * pt.x + 4.0 * pt.y > c_limit + eps:
					sp_overflow = true
				if -7.0 * pt.x + 4.0 * pt.y > c_limit + eps:
					sp_overflow = true
				if -7.0 * pt.x - 4.0 * pt.y > c_limit + eps:
					sp_overflow = true

			if sp_overflow:
				total_overflows += 1
				if overflow_details.size() < 10:
					overflow_details.append("Cell %s Role %d Asset %s bounds=[%.2f, %.2f, %.2f, %.2f]" % [str(coord), role, res_path.get_file(), x1, y1, x2, y2])

	var t_elapsed: int = Time.get_ticks_msec() - t0

	print("\n--- ROLE DISTRIBUTION ---")
	for r in [5, 6, 7, 8, 9, 10, 11]:
		var r_name: String = HexForestCompositorCls._role_name(r)
		var cnt: int = int(role_counts.get(r, 0))
		var avg_s: float = 0.0
		var arr: Array = sprites_per_role.get(r, [])
		if not arr.is_empty():
			var sum: int = 0
			for val in arr: sum += val
			avg_s = float(sum) / float(arr.size())
		print("  Role %2d (%-22s): %3d cells | avg %.1f sprites/cell" % [r, r_name, cnt, avg_s])

	print("\n--- SPRITE DENSITY METRICS ---")
	print("  Total Forest Sprites: %d across %d cells (average %.1f sprites/cell)" % [total_sprites, forest_coords.size(), float(total_sprites) / float(forest_coords.size())])
	print("  Min sprites in any cell: %d" % min_sprites_per_cell)
	print("  Max sprites in any cell: %d" % max_sprites_per_cell)

	print("\n--- CONTAINMENT & OVERFLOW AUDIT ---")
	print("  Total sprites evaluated for containment: %d" % total_sprites)
	print("  Total overflow violations: %d" % total_overflows)
	if total_overflows == 0:
		print("  >>> PERFECT CONTAINMENT: 100.0% of sprites strictly within inset hex (0.00% overflow)! <<<")
	else:
		print("  >>> VIOLATION DETAILS:")
		for d_str in overflow_details:
			print("      " + d_str)

	print("\n--- APPROVED ASSET USAGE AUDIT ---")
	print("  Unique approved vegetation assets rendered: %d / 26" % used_resources.size())
	for res in used_resources.keys():
		print("    - %-28s: %4d instances" % [res.get_file(), used_resources[res]])

	print("\n--- PERFORMANCE PROFILING ---")
	print("  Total composition evaluation time: %d ms for %d cells (%.2f ms/cell)" % [t_elapsed, forest_coords.size(), float(t_elapsed) / float(forest_coords.size())])

	var avg_sprites: float = float(total_sprites) / float(forest_coords.size())
	if total_overflows == 0 and avg_sprites >= 13.5 and min_sprites_per_cell >= 10 and used_resources.size() == 26:
		print("\n>>> ALL ACCEPTANCE CRITERIA MET SUCCESSFULLY! <<<")
		quit(0)
	else:
		print("\n>>> FAILURE: Some acceptance criteria were not met! (avg=%.2f, min=%d, assets=%d, overflows=%d)" % [avg_sprites, min_sprites_per_cell, used_resources.size(), total_overflows])
		quit(1)
