class_name HexVisualGrammar
extends RefCounted

## HexVisualGrammar — PHASE B/D/F/J orchestrator.
## Builds exactly one HexVisualDescriptor per playable cell from
## authoritative gameplay truth. Compute-once, cache, update only on
## world-state change. Never mutates gameplay.

const DescCls = preload("res://scripts/visual/hex_native/hex_visual_descriptor.gd")
const NeighborCls = preload("res://scripts/visual/hex_native/hex_neighbor_classifier.gd")
const BaseMeshCls = preload("res://scripts/visual/hex_native/hex_base_terrain_mesh.gd")
const RouteCls = preload("res://scripts/visual/hex_native/hex_route_autotiler.gd")
const RiverCls = preload("res://scripts/visual/hex_native/hex_river_autotiler.gd")

const DIRECTIONS: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(1, -1), Vector2i(0, -1),
	Vector2i(-1, 0), Vector2i(-1, 1), Vector2i(0, 1),
]

static func _cell_terrain(cell) -> int:
	if cell == null:
		return 0
	if cell is Object and cell.get("terrain") != null:
		return int(cell.get("terrain"))
	if cell is Dictionary:
		return int(cell.get("terrain", 0))
	return 0

static func _cell_coords(cell, fallback_key: String) -> Vector2i:
	if cell is Object and cell.get("q") != null:
		return Vector2i(int(cell.get("q")), int(cell.get("r")))
	if cell is Dictionary and cell.has("q"):
		return Vector2i(int(cell["q"]), int(cell["r"]))
	var parts: PackedStringArray = fallback_key.split(",")
	if parts.size() == 2:
		return Vector2i(int(parts[0]), int(parts[1]))
	return Vector2i.ZERO

## Deterministic visual hash: hash(q, r, role, seed). Stable across launches.
static func visual_hash(q: int, r: int, role: int, seed: int = 1337) -> int:
	var h: int = seed
	h = (h * 73856093) ^ (q * 19349663)
	h = (h * 83492791) ^ (r * 2971215073)
	h = (h * ulton(31)) ^ (role * 83492791 + 17)
	return absi(h)

static func ulton(v: int) -> int:
	return v if v != 0 else 1

## Main entry: cell_data "q,r" -> HexCell-or-Dict; river/stronghold dicts "q,r"->true;
## unit_coords Array[Vector2i]; fog RefCounted-or-null with explored/visible dicts.
## Returns Dictionary Vector2i -> HexVisualDescriptor.
static func build_descriptors(cell_data: Dictionary, river_cells: Dictionary, stronghold_cells: Dictionary, unit_coords: Array = [], fog = null, tutorial_ground_variation: bool = false) -> Dictionary:
	var descriptors: Dictionary = {}
	var unit_set: Dictionary = {}
	for u in unit_coords:
		var uc: Vector2i = u if u is Vector2i else Vector2i(int(u.x), int(u.y))
		unit_set[uc] = true
	# PASS 1: create descriptors, copy gameplay truth
	for key in cell_data.keys():
		var cell = cell_data[key]
		var coord: Vector2i = _cell_coords(cell, str(key))
		var t: int = _cell_terrain(cell)
		var skey: String = "%d,%d" % [coord.x, coord.y]
		var is_river: bool = t == 7 or river_cells.has(skey) or river_cells.has(coord)
		var is_road: bool = t == 6 or t == 5 or t == 4 or t == 9 or t == 11
		var is_sh: bool = t == 4 or t == 9 or t == 11 or stronghold_cells.has(skey) or stronghold_cells.has(coord)
		var is_unit: bool = unit_set.has(coord)
		var fog_state: int = 2
		if fog != null:
			var vis: bool = false
			var exp: bool = false
			if fog.get("visible") != null:
				var vd: Dictionary = fog.get("visible")
				vis = vd.has(skey) or vd.has(coord)
			if fog.get("explored") != null:
				var ed: Dictionary = fog.get("explored")
				exp = ed.has(skey) or ed.has(coord)
			fog_state = 2 if vis else (1 if exp else 0)
		var d = DescCls.new(coord)
		d.copy_gameplay_state(t, is_road, is_river, is_sh, is_unit, fog_state)
		descriptors[coord] = d
	# PASS 2: neighbor masks + constraints
	for coord in descriptors.keys():
		var d = descriptors[coord]
		NeighborCls.compute_masks_for_descriptor(d, descriptors, river_cells, stronghold_cells)
	for coord in descriptors.keys():
		NeighborCls.classify_constraints(descriptors[coord], descriptors)
	# PASS 3: connected components (forest=2, mountain=1) + edge depth
	_compute_components(descriptors, 2)
	_compute_components(descriptors, 1)
	# PASS 4: slot assignment (base, route, river, transitions)
	for coord in descriptors.keys():
		var d = descriptors[coord]
		d.base_role = BaseMeshCls.classify_base_role(d, descriptors)
		d.route_role = RouteCls.route_role_for(d)
		d.river_role = RiverCls.river_role_for(d)
		_assign_transitions(d, descriptors)
	if tutorial_ground_variation:
		BaseMeshCls.apply_tutorial_ground_variation(descriptors)
	return descriptors

static func _compute_components(descriptors: Dictionary, target_terrain: int) -> void:
	var visited: Dictionary = {}
	var comp_id: int = 0
	for coord in descriptors.keys():
		if visited.has(coord):
			continue
		var d = descriptors[coord]
		if int(d.terrain_type) != target_terrain:
			continue
		comp_id += 1
		var queue: Array[Vector2i] = [coord]
		var members: Array[Vector2i] = []
		visited[coord] = true
		while not queue.is_empty():
			var cur: Vector2i = queue.pop_back()
			members.append(cur)
			for dir in DIRECTIONS:
				var n: Vector2i = cur + dir
				if visited.has(n) or not descriptors.has(n):
					continue
				if int(descriptors[n].terrain_type) != target_terrain:
					continue
				visited[n] = true
				queue.append(n)
		# edge depth via BFS from boundary
		var depth: Dictionary = {}
		var frontier: Array[Vector2i] = []
		for m in members:
			var is_edge: bool = false
			for dir in DIRECTIONS:
				var n: Vector2i = m + dir
				if not descriptors.has(n) or int(descriptors[n].terrain_type) != target_terrain:
					is_edge = true
					break
			if is_edge:
				depth[m] = 0
				frontier.append(m)
		var head: int = 0
		while head < frontier.size():
			var cur: Vector2i = frontier[head]
			head += 1
			for dir in DIRECTIONS:
				var n: Vector2i = cur + dir
				if not descriptors.has(n) or depth.has(n):
					continue
				if int(descriptors[n].terrain_type) != target_terrain:
					continue
				depth[n] = int(depth[cur]) + 1
				frontier.append(n)
		for m in members:
			descriptors[m].terrain_component_id = comp_id if int(descriptors[m].terrain_type) == target_terrain else descriptors[m].terrain_component_id
			if depth.has(m):
				# keep max depth signal for the target family; store mountain/forest depth generically
				descriptors[m].component_edge_depth = maxi(descriptors[m].component_edge_depth, int(depth[m]))

static func _assign_transitions(d, descriptors: Dictionary) -> void:
	# Directional boundary-only transitions, max 2 per cell.
	var t: int = int(d.terrain_type)
	for dir_idx in range(6):
		if d.transition_roles.size() >= 2:
			break
		var bit: int = 1 << dir_idx
		if (int(d.terrain_neighbor_mask) & bit) == 0:
			continue
		var n: Vector2i = d.coord + DIRECTIONS[dir_idx]
		if not descriptors.has(n):
			continue
		var nt: int = int(descriptors[n].terrain_type)
		if nt == t:
			continue
		var role: int = _transition_role_for(t, nt)
		if role != 0:
			d.add_transition(role, dir_idx)

static func _transition_role_for(t: int, nt: int) -> int:
	# TransitionRole enum in descriptor: 1 rocky skirt, 2 scree, 3 rubble,
	# 4 pass rubble, 5 pine skirt, 6 cliff debris, 7 ridge foot.
	var pair: String = "%d>%d" % [t, nt]
	match pair:
		"0>1", "1>0":
			return 1
		"0>2", "2>0":
			return 5
		"2>1", "1>2":
			return 5
		"1>6", "6>1", "0>6", "6>0":
			return 4
		"0>7", "7>0", "0>3", "3>0":
			return 6
		"1>3", "3>1":
			return 3
		_:
			return 2 if (t == 1 or nt == 1) else 1
