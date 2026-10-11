class_name Step3Pathfinding
extends RefCounted

## STEP-03 Weighted Hex Pathfinding & March Envelope Engine
## Implements Dijkstra/A* accounting for:
##   - Exact Radius-40 / 4,921 playable mask
##   - Weighted terrain costs (Road 0.5, Plain 1.0, Forest/Marsh 2.0, Mountain 3.0)
##   - Scout terrain specialization (Forest 1.0, Mountain 1.0)
##   - River crossing detection -> Automatic RED classification
##   - One-unit-per-hex enforcement & occupancy blocking
##   - 3-tier march envelopes (Green / Orange / Red)
##   - Player march policy ceiling filtering

const HexUtilsCls = preload("res://scripts/core/hex_utils.gd")
const Step2RWorldBoundaryCls = preload("res://scripts/step2r/step2r_world_boundary.gd")
const Step3ConfigCls = preload("res://scripts/core/step3_config.gd")

# ------------------------------------------------------------------
# Result structures
# ------------------------------------------------------------------
class EnvelopeResult:
	extends RefCounted
	var origin: Vector2i = Vector2i.ZERO
	var green_hexes: Array[Vector2i] = []
	var orange_hexes: Array[Vector2i] = []
	var red_hexes: Array[Vector2i] = []
	var reachable_data: Dictionary = {} # Vector2i -> Dictionary of details
	var calculation_time_ms: float = 0.0

class RouteInfo:
	extends RefCounted
	var found: bool = false
	var origin: Vector2i = Vector2i.ZERO
	var destination: Vector2i = Vector2i.ZERO
	var path: Array[Vector2i] = []
	var cost: float = 0.0
	var march_class: int = Step3ConfigCls.MarchClass.GREEN
	var crosses_river: bool = false
	var food_cost: float = 0.0 # retired globally (SUP-FINAL): canonical moves have zero food cost
	var morale_penalty: float = 0.0
	var is_valid_destination: bool = false
	var rejection_reason: String = ""

# ------------------------------------------------------------------
# Scenario bounds provide a cheap rectangular envelope; cell_data remains the
# exact playable mask inside that envelope (including compact axial hex maps).
# ------------------------------------------------------------------
## True when coord lies inside the scenario's rectangular envelope. An empty
## bounds dict disables this extra envelope; cell_data still defines playability.
static func scenario_in_bounds(coord: Vector2i, scenario_bounds: Dictionary) -> bool:
	if scenario_bounds.is_empty():
		return true
	return coord.x >= int(scenario_bounds.get("q_min", coord.x)) \
		and coord.x <= int(scenario_bounds.get("q_max", coord.x)) \
		and coord.y >= int(scenario_bounds.get("r_min", coord.y)) \
		and coord.y <= int(scenario_bounds.get("r_max", coord.y))

# ------------------------------------------------------------------
# Envelope calculation (Dijkstra expansion up to RED budget limit)
# ------------------------------------------------------------------
static func calculate_envelope(
	origin: Vector2i,
	unit_class: String,
	base_mp: float,
	remaining_mp: float,
	policy: int,
	cell_data: Dictionary,
	occupied_units: Dictionary, # "q,r" -> Dictionary (unit data)
	river_cells: Dictionary,
	friendly_faction: String = "blue",
	stronghold_cells: Dictionary = {},
	turn_move_cost_spent: float = -1.0,
	p_blue_limit: float = -1.0,
	p_red_limit: float = -1.0,
	p_black_limit: float = -1.0,
	scenario_bounds: Dictionary = {}
) -> EnvelopeResult:
	var start_time: int = Time.get_ticks_usec()
	var result: EnvelopeResult = EnvelopeResult.new()
	result.origin = origin

	if not Step2RWorldBoundaryCls.is_playable_hex(origin):
		return result
	var origin_key: String = "%d,%d" % [origin.x, origin.y]
	if not cell_data.has(origin_key):
		return result

	var blue_lim: float = p_blue_limit if p_blue_limit > 0.0 else Step3ConfigCls.get_blue_limit(base_mp)
	var red_lim: float = p_red_limit if p_red_limit > 0.0 else Step3ConfigCls.get_red_limit(base_mp)
	var black_lim: float = p_black_limit if p_black_limit > 0.0 else Step3ConfigCls.get_black_limit(base_mp)
	var spent: float = turn_move_cost_spent if turn_move_cost_spent >= 0.0 else maxf(0.0, blue_lim - remaining_mp)

	var max_budget: float = Step3ConfigCls.get_max_additional_budget(spent, blue_lim, red_lim, black_lim, policy)
	if max_budget <= 0.001:
		# No movement budget available under current policy
		return result
	
	# Priority queue simulation for Dijkstra:
	# Store: [cost, river_flag, coord]
	# Open set dictionary: "q,r" -> cost
	var g_score: Dictionary = {}
	var river_flag: Dictionary = {} # "q,r" -> bool
	var came_from: Dictionary = {} # "q,r" -> Vector2i
	
	g_score[origin_key] = 0.0
	river_flag[origin_key] = false
	
	# Open set array of Vector2i
	var open_set: Array[Vector2i] = [origin]
	
	while not open_set.is_empty():
		# Find node with lowest g_score
		var best_idx: int = 0
		var best_cost: float = float(g_score.get("%d,%d" % [open_set[0].x, open_set[0].y], 1e9))
		for i in range(1, open_set.size()):
			var c: float = float(g_score.get("%d,%d" % [open_set[i].x, open_set[i].y], 1e9))
			if c < best_cost:
				best_cost = c
				best_idx = i
		
		var current: Vector2i = open_set[best_idx]
		open_set.remove_at(best_idx)
		var current_key: String = "%d,%d" % [current.x, current.y]
		var current_g: float = float(g_score[current_key])
		var current_river: bool = bool(river_flag.get(current_key, false))
		
		if current_g > max_budget:
			continue
		
		var neighbors: Array[Vector2i] = HexUtilsCls.get_all_neighbors(current.x, current.y)
		for n in neighbors:
			if not Step2RWorldBoundaryCls.is_playable_hex(n):
				continue
			if not scenario_bounds.is_empty() and not scenario_in_bounds(n, scenario_bounds):
				continue

			var n_key: String = "%d,%d" % [n.x, n.y]
			if not cell_data.has(n_key):
				continue
			# §25 Pathfinding must not route through intact fortress/city interiors
			if stronghold_cells.has(n_key):
				continue
			var cell: Variant = cell_data[n_key]
			if cell == null:
				continue
			var terrain_type: int = int(cell.terrain)
			
			# Impassable check (Wall / impassable)
			if Step3ConfigCls.is_impassable(terrain_type):
				continue
			
			# STEP-05R3 §6: player-known occupancy blocks traversal — route AROUND it.
			# occupied_units carries ONLY player-known blockers (friendly hexes +
			# currently-visible enemies; see get_player_known_occupied). Every such
			# hex is a hard planning obstacle: the shortest legal route detours,
			# and Blue/Red/Black classify the real detour cost — never the
			# straight-line hex distance. Hidden enemies are already omitted by
			# the caller, so unknown space never deflects the plan (§7); stale
			# last-known markers are fog memory, not occupancy, so they never
			# block either (§8). Origin is exempt (the mover's own hex).
			if occupied_units.has(n_key) and n_key != origin_key:
				continue
			
			# Traversal cost
			var step_cost: float = Step3ConfigCls.get_terrain_cost(terrain_type, unit_class)
			var tent_g: float = current_g + step_cost
			
			if tent_g > max_budget:
				continue
			
			# River crossing detection:
			# If current or neighbor is river, entering it crosses a river boundary
			var step_crosses_river: bool = current_river or river_cells.has(n_key) or river_cells.has(current_key) or terrain_type == 7
			
			var existing_g: float = float(g_score.get(n_key, 1e9))
			if tent_g < existing_g - 0.0001:
				g_score[n_key] = tent_g
				river_flag[n_key] = step_crosses_river
				came_from[n_key] = current
				if n not in open_set:
					open_set.append(n)
	
	# Process reached nodes into envelope categories
	for k in g_score.keys():
		var parts: PackedStringArray = k.split(",")
		var coord: Vector2i = Vector2i(int(parts[0]), int(parts[1]))
		if coord == origin:
			continue
		
		# Destination cannot be occupied by friendly or enemy
		if occupied_units.has(k):
			continue
		
		var cost: float = float(g_score[k])
		var has_river: bool = bool(river_flag.get(k, false))
		var march_class: int = Step3ConfigCls.classify_march_by_cumulative_cost(spent + cost, blue_lim, red_lim, has_river)
		
		# Policy filtering
		if not Step3ConfigCls.is_policy_allowed(policy, march_class):
			continue
		
		# Reconstruct path
		var path: Array[Vector2i] = _reconstruct_path(origin, coord, came_from)
		
		var detail: Dictionary = {
			"coord": coord,
			"cost": cost,
			"march_class": march_class,
			"crosses_river": has_river,
			"path": path,
			"food_cost": 0.0, # retired globally (SUP-FINAL)
			"morale_penalty": Step3ConfigCls.get_morale_penalty(march_class)
		}
		result.reachable_data[coord] = detail
		
		match march_class:
			Step3ConfigCls.MarchClass.GREEN:
				result.green_hexes.append(coord)
			Step3ConfigCls.MarchClass.ORANGE:
				result.orange_hexes.append(coord)
			Step3ConfigCls.MarchClass.RED:
				result.red_hexes.append(coord)
	
	var elapsed_us: int = Time.get_ticks_usec() - start_time
	result.calculation_time_ms = float(elapsed_us) / 1000.0
	return result

# ------------------------------------------------------------------
# Authoritative single route search (A* / Dijkstra)
# ------------------------------------------------------------------
static func find_route(
	origin: Vector2i,
	destination: Vector2i,
	unit_class: String,
	base_mp: float,
	remaining_mp: float,
	policy: int,
	cell_data: Dictionary,
	occupied_units: Dictionary,
	river_cells: Dictionary,
	friendly_faction: String = "blue",
	stronghold_cells: Dictionary = {},
	turn_move_cost_spent: float = -1.0,
	p_blue_limit: float = -1.0,
	p_red_limit: float = -1.0,
	p_black_limit: float = -1.0,
	scenario_bounds: Dictionary = {}
) -> RouteInfo:
	var info: RouteInfo = RouteInfo.new()
	info.origin = origin
	info.destination = destination
	
	if origin == destination:
		info.found = true
		info.path = [origin]
		info.cost = 0.0
		info.march_class = Step3ConfigCls.MarchClass.GREEN
		info.is_valid_destination = false
		info.rejection_reason = "Origin is destination"
		return info
	
	if not Step2RWorldBoundaryCls.is_playable_hex(destination):
		info.found = false
		info.rejection_reason = "Destination outside playable map"
		return info

	if not scenario_bounds.is_empty() and not scenario_in_bounds(destination, scenario_bounds):
		info.found = false
		info.rejection_reason = "Destination outside scenario bounds"
		return info

	var dest_key: String = "%d,%d" % [destination.x, destination.y]
	if not cell_data.has(dest_key) or cell_data[dest_key] == null:
		info.found = false
		info.rejection_reason = "Destination outside playable map"
		return info
	if occupied_units.has(dest_key):
		info.found = false
		info.rejection_reason = "Destination is occupied"
		return info
	if stronghold_cells.has(dest_key):
		info.found = false
		info.rejection_reason = "Destination inside stronghold footprint — use garrison entry"
		return info
	
	var dest_cell: Variant = cell_data.get(dest_key, null)
	if dest_cell != null and Step3ConfigCls.is_impassable(int(dest_cell.terrain)):
		info.found = false
		info.rejection_reason = "Destination is impassable"
		return info
	
	# Run envelope search
	var env: EnvelopeResult = calculate_envelope(
		origin, unit_class, base_mp, remaining_mp, policy,
		cell_data, occupied_units, river_cells, friendly_faction, stronghold_cells,
		turn_move_cost_spent, p_blue_limit, p_red_limit, p_black_limit, scenario_bounds
	)
	
	if env.reachable_data.has(destination):
		var d: Dictionary = env.reachable_data[destination]
		info.found = true
		info.path = d["path"]
		info.cost = d["cost"]
		info.march_class = d["march_class"]
		info.crosses_river = d["crosses_river"]
		info.food_cost = d["food_cost"]
		info.morale_penalty = d["morale_penalty"]
		info.is_valid_destination = true
		return info
	
	# If not reached under current policy, check if reachable under RED allowed to give helpful rejection reason
	if policy != Step3ConfigCls.MarchPolicy.RED_ALLOWED:
		var env_all: EnvelopeResult = calculate_envelope(
			origin, unit_class, base_mp, remaining_mp, Step3ConfigCls.MarchPolicy.RED_ALLOWED,
			cell_data, occupied_units, river_cells, friendly_faction, stronghold_cells,
			turn_move_cost_spent, p_blue_limit, p_red_limit, p_black_limit, scenario_bounds
		)
		if env_all.reachable_data.has(destination):
			var d_all: Dictionary = env_all.reachable_data[destination]
			info.found = false
			info.rejection_reason = "Requires %s march (forbidden by current policy)" % Step3ConfigCls.get_march_label(d_all["march_class"])
			return info

	info.found = false
	info.rejection_reason = "Destination not reachable within current policy budget"
	return info

# ------------------------------------------------------------------
# Helper to reconstruct path from came_from map
# ------------------------------------------------------------------
static func _reconstruct_path(origin: Vector2i, target: Vector2i, came_from: Dictionary) -> Array[Vector2i]:
	var path: Array[Vector2i] = [target]
	var cur: Vector2i = target
	var cur_key: String = "%d,%d" % [cur.x, cur.y]
	
	while came_from.has(cur_key):
		var prev: Vector2i = came_from[cur_key]
		path.push_front(prev)
		if prev == origin:
			break
		cur = prev
		cur_key = "%d,%d" % [cur.x, cur.y]
	
	return path
