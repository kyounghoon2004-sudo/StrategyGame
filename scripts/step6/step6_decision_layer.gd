class_name Step6DecisionLayer
extends RefCounted

## STEP-06 Battle Decision Layer — HQ, supply, morale, retreat & rout (§2-§45).
## Turn/discrete-event brain. Owns: central stockpile, forward nodes, convoy
## manifests, HQ identity/loss, morale drift, rout/rally, capture rule.
## Unit truth stays in Step3UnitManager; this layer mutates ONLY via s6_* API
## (get_unit_by_id/get_all_units return duplicates and must never be written).

var HexUtilsCls: Script = preload("res://scripts/core/hex_utils.gd")
var Step3PathfindingCls: Script = preload("res://scripts/step3/step3_pathfinding.gd")
var Step3ConfigCls: Script = preload("res://scripts/core/step3_config.gd")
var WorldBoundaryCls: Script = preload("res://scripts/step2r/step2r_world_boundary.gd")
var S6: Script = preload("res://scripts/step6/step6_config.gd")
var SandboxRulesCls: Script = preload("res://scripts/core/sandbox_rules.gd")

var _central: float = 0.0
var _hq_id: String = ""
var _nodes: Dictionary = {}    # node_id -> {id,label,coord,kind,faction,stock,cap,infinite,sh_id}
var _convoys: Dictionary = {}  # unit_id -> {cargo, max_cargo, faction} (mobile supply hubs)
var _node_coverage_cache: Dictionary = {} # node_id -> {hexes: Array[Vector2i], costs: Dictionary}
var _battle_lost: bool = false
var _known_convoy: Dictionary = {} # enemy convoy id -> true (spotted-event spam guard)
var _pending_hungry: int = 0 # charged pre-reset, reported post-reset
var _init_done: bool = false

# ------------------------------------------------------------------
# Setup
# ------------------------------------------------------------------
func initialize(manager: RefCounted, depot_coord: Vector2i, depot_label: String = "전진 보급소") -> Dictionary:
	_central = S6.CENTRAL_STOCKPILE_START
	_nodes.clear()
	_convoys.clear()
	_node_coverage_cache.clear()
	_battle_lost = false
	_known_convoy.clear()
	_hq_id = ""
	for u in manager.get_all_units_including_garrisoned():
		if str(u.get("class", "")) == "hq" and str(u.get("faction", "")) == "blue":
			_hq_id = str(u.get("id", ""))
			break
	if _hq_id == "":
		return {"success": false, "error": "blue HQ not found — spawn class hq before initialize"}
	var hq: Dictionary = manager.get_unit_by_id(_hq_id)
	_add_node("HQ", "사령부 (HQ)", Vector2i(int(hq.get("q", 0)), int(hq.get("r", 0))), "hq", "blue", 0.0, 0.0, false)
	_add_node("DEPOT", depot_label, depot_coord, "depot", "blue", S6.DEPOT_START_STOCK, S6.NODE_STOCK_CAP, false)
	_refresh_stronghold_nodes(manager)
	_assign_convoys(manager)
	_init_done = true
	manager.log_observable_event({"type": "s6_init", "hq_id": _hq_id, "central": _central})
	return {"success": true, "hq_id": _hq_id, "central": _central, "nodes": _nodes.keys(), "convoys": _convoys.keys()}

func _add_node(id: String, label: String, coord: Vector2i, kind: String, faction: String, stock: float, cap: float, infinite: bool, sh_id: String = "") -> void:
	_nodes[id] = {"id": id, "label": label, "coord": coord, "kind": kind, "faction": faction, "stock": stock, "cap": cap, "infinite": infinite, "sh_id": sh_id}

func _refresh_stronghold_nodes(manager: RefCounted) -> void:
	# Drop stronghold nodes whose ownership changed away; add blue/red owned ones.
	var dead: Array = []
	for nid in _nodes.keys():
		var n: Dictionary = _nodes[nid]
		if str(n.get("kind", "")) != "stronghold":
			continue
		var sh: Variant = manager.get_stronghold_by_id(str(n.get("sh_id", "")))
		if sh == null or str(sh.owner) != str(n.get("faction", "")):
			dead.append(nid)
	for d in dead:
		_nodes.erase(d)
	for sh in manager.get_all_strongholds():
		var sid: String = str(sh.structure_id)
		var nid2: String = "SH_" + sid
		if _nodes.has(nid2):
			_nodes[nid2]["coord"] = sh.get_anchor()
			continue
		var own: String = str(sh.owner)
		if own != "blue" and own != "red":
			continue
		_add_node(nid2, "전진 거점 " + sid, sh.get_anchor(), "stronghold", own, 0.0, S6.NODE_STOCK_CAP, false, sid)
	# Red origin (capital anchor) is an infinite logistics source (provisional lite enemy sim).
	var cap: Variant = null
	for sh in manager.get_all_strongholds():
		if str(sh.structure_id).begins_with("Capital") or "Capital" in str(sh.structure_id):
			cap = sh
			break
	if cap != null and str(cap.owner) == "red":
		var onid: String = "RED_ORIGIN"
		if not _nodes.has(onid):
			_add_node(onid, "적 군량원", (cap as Variant).get_anchor(), "origin", "red", 1.0e9, 1.0e9, true)

func _assign_convoys(manager: RefCounted) -> void:
	# STEP-06R2: Register mobile supply hubs as dedicated, player-movable logistics units
	for u in manager.get_all_units():
		if str(u.get("class", "")) != "supply":
			continue
		var cid: String = str(u.get("id", ""))
		var fac: String = str(u.get("faction", ""))
		_convoys[cid] = {
			"cargo": S6.SUPPLY_UNIT_CARGO_CAPACITY,
			"max_cargo": S6.SUPPLY_UNIT_CARGO_CAPACITY,
			"faction": fac,
			"route": {}
		}
		manager.s6_set_field(cid, "convoy_cargo", S6.SUPPLY_UNIT_CARGO_CAPACITY)
		manager.s6_set_field(cid, "is_convoy", false)

# ------------------------------------------------------------------
# Fixed Node Coverage Computation (Dijkstra over terrain)
# ------------------------------------------------------------------
func get_node_budget(node_id: String) -> float:
	if not _nodes.has(node_id):
		return 0.0
	var n: Dictionary = _nodes[node_id]
	var kind: String = str(n.get("kind", ""))
	if kind == "hq":
		return S6.COVERAGE_HQ
	elif kind == "depot":
		return S6.COVERAGE_DEPOT
	elif kind == "origin":
		return S6.COVERAGE_CITY
	elif kind == "stronghold":
		var sh_id: String = str(n.get("sh_id", ""))
		if "Capital" in sh_id or "City" in sh_id:
			return S6.COVERAGE_CITY
		elif "Fortress" in sh_id:
			return S6.COVERAGE_FORTRESS
		elif "Village" in sh_id:
			return S6.COVERAGE_VILLAGE
		return S6.COVERAGE_DEPOT
	return S6.COVERAGE_DEPOT

func compute_node_coverage(node_id: String, cell_data: Dictionary, stronghold_cells: Dictionary) -> Dictionary:
	if not _nodes.has(node_id):
		return {"hexes": [], "costs": {}}
	if _node_coverage_cache.has(node_id):
		return _node_coverage_cache[node_id]
	var n: Dictionary = _nodes[node_id]
	var origin: Vector2i = n["coord"] as Vector2i
	var budget: float = get_node_budget(node_id)
	var fac: String = str(n.get("faction", ""))
	
	var g_score: Dictionary = {}
	var origin_key: String = "%d,%d" % [origin.x, origin.y]
	g_score[origin_key] = 0.0
	var max_bucket: int = roundi(budget * 2.0) + 1
	var buckets: Array = []
	for b in range(max_bucket + 2):
		buckets.append([])
	
	buckets[0].append(origin)
	var visited: Dictionary = {}
	visited[origin_key] = true
	var hex_list: Array[Vector2i] = [origin]
	
	for b in range(max_bucket + 1):
		var bucket: Array = buckets[b]
		while not bucket.is_empty():
			var current: Vector2i = bucket.pop_back()
			var current_key: String = "%d,%d" % [current.x, current.y]
			var current_g: float = float(g_score[current_key])
			if current_g >= budget:
				continue
				
			var neighbors: Array[Vector2i] = HexUtilsCls.get_all_neighbors(current.x, current.y)
			for nbr in neighbors:
				if not WorldBoundaryCls.is_playable_hex(nbr):
					continue
				var nbr_key: String = "%d,%d" % [nbr.x, nbr.y]
				# Opposing intact strongholds block logistics reach
				if stronghold_cells.has(nbr_key):
					var sh_fac: String = str(stronghold_cells[nbr_key])
					if sh_fac != "" and sh_fac != fac:
						continue
				var cell: Variant = cell_data.get(nbr_key, null)
				var terrain: int = 0
				if cell != null:
					terrain = int(cell.get("terrain")) if not (cell is Dictionary) else int((cell as Dictionary).get("terrain", 0))
				var step_cost: float = Step3ConfigCls.get_terrain_cost(terrain, "supply")
				var tent_g: float = current_g + step_cost
				if tent_g <= budget:
					if not g_score.has(nbr_key) or tent_g < float(g_score[nbr_key]):
						g_score[nbr_key] = tent_g
						var next_b: int = mini(max_bucket, roundi(tent_g * 2.0))
						buckets[next_b].append(nbr)
						if not visited.has(nbr_key):
							visited[nbr_key] = true
							hex_list.append(nbr)
							
	var res: Dictionary = {"hexes": hex_list, "costs": g_score}
	_node_coverage_cache[node_id] = res
	return res

func clear_coverage_cache() -> void:
	_node_coverage_cache.clear()

func _node_can_supply(n: Dictionary, fac: String) -> bool:
	if bool(n.get("infinite", false)):
		return true
	if str(n.get("kind", "")) == "hq":
		return fac == "blue" and _central > 0.0
	return float(n.get("stock", 0.0)) > 0.0 or str(n.get("kind", "")) == "stronghold"

func is_hex_covered(coord: Vector2i, faction: String, cell_data: Dictionary = {}, stronghold_cells: Dictionary = {}) -> Dictionary:
	var key: String = "%d,%d" % [coord.x, coord.y]
	for nid in _nodes.keys():
		var n: Dictionary = _nodes[nid]
		if str(n.get("faction", "")) != faction:
			continue
		if not _node_can_supply(n, faction):
			continue
		var cov: Dictionary = _node_coverage_cache.get(nid, {})
		if cov.is_empty() and not cell_data.is_empty():
			cov = compute_node_coverage(nid, cell_data, stronghold_cells)
		if cov.has("costs") and (cov["costs"] as Dictionary).has(key):
			return {"covered": true, "node_id": nid, "node_label": str(n.get("label", nid)), "cost": float(cov["costs"][key])}
	return {"covered": false, "node_id": "", "node_label": "", "cost": -1.0}

func is_unit_secure(u: Dictionary, cell_data: Dictionary = {}, stronghold_cells: Dictionary = {}) -> bool:
	var upos := Vector2i(int(u.get("q", 0)), int(u.get("r", 0)))
	var cov_info: Dictionary = is_hex_covered(upos, str(u.get("faction", "")), cell_data, stronghold_cells)
	return bool(cov_info.get("covered", false))

# ------------------------------------------------------------------
# Mobile Supply Hubs — Path-based Auto-Resupply & Refill
# ------------------------------------------------------------------
func apply_mobile_path_resupply(manager: RefCounted, supply_unit_id: String, path_coords: Array) -> Array:
	var supplied_list: Array = []
	if not _convoys.has(supply_unit_id):
		var su0: Dictionary = manager.get_unit_by_id(supply_unit_id)
		if not su0.is_empty() and str(su0.get("class", "")) == "supply":
			_convoys[supply_unit_id] = {
				"cargo": float(su0.get("convoy_cargo", S6.SUPPLY_UNIT_CARGO_CAPACITY)),
				"max_cargo": S6.SUPPLY_UNIT_CARGO_CAPACITY,
				"faction": str(su0.get("faction", "blue"))
			}
		else:
			return supplied_list
	var hub: Dictionary = _convoys[supply_unit_id]
	var cargo: float = float(hub.get("cargo", 0.0))
	if cargo <= 0.001:
		return supplied_list
	var fac: String = str(hub.get("faction", ""))
	
	# Collect service footprint (all hexes within 2 hexes of any path step)
	var service_hexes: Dictionary = {}
	var radius: int = S6.SUPPLY_UNIT_SERVICE_RADIUS
	for pt in path_coords:
		var p: Vector2i = pt as Vector2i
		for dq in range(-radius, radius + 1):
			for dr in range(maxi(-radius, -dq - radius), mini(radius, -dq + radius) + 1):
				var h := Vector2i(p.x + dq, p.y + dr)
				service_hexes["%d,%d" % [h.x, h.y]] = true
				
	for u in manager.get_all_units():
		if str(u.get("faction", "")) != fac:
			continue
		var cls: String = str(u.get("class", ""))
		if cls == "supply" or cls == "hq":
			continue
		if int(u.get("soldier_count", 0)) <= 0 or bool(u.get("routed", false)):
			continue
		var upos := Vector2i(int(u.get("q", 0)), int(u.get("r", 0)))
		if not service_hexes.has("%d,%d" % [upos.x, upos.y]):
			continue
			
		var cur: float = float(u.get("local_supply", 0.0))
		var mx: float = float(u.get("local_supply_max", 0.0))
		var need: float = mx - cur
		if need > 0.001 and cargo > 0.001:
			var give: float = minf(need, cargo)
			cargo -= give
			var uid: String = str(u.get("id", ""))
			manager.s6_adjust_supply(uid, give)
			manager.s6_set_field(uid, "consecutive_hungry", 0)
			_update_supply_state(manager, uid)
			supplied_list.append({"unit_id": uid, "amount": give, "coord": upos})
			manager.log_observable_event({"type": "mobile_hub_resupply", "hub_id": supply_unit_id, "unit_id": uid, "amount": give, "turn": manager.get_current_turn()})
			
	hub["cargo"] = cargo
	manager.s6_set_field(supply_unit_id, "convoy_cargo", cargo)
	return supplied_list

func check_mobile_hub_refill(manager: RefCounted, supply_unit_id: String, current_coord: Vector2i) -> float:
	if not _convoys.has(supply_unit_id):
		return 0.0
	var hub: Dictionary = _convoys[supply_unit_id]
	var fac: String = str(hub.get("faction", ""))
	return _check_hub_refill_at_nodes(current_coord, hub, fac, supply_unit_id, manager)

func _check_hub_refill_at_nodes(spos: Vector2i, hub: Dictionary, fac: String, cid: String, manager: RefCounted) -> float:
	var cur_cargo: float = float(hub.get("cargo", 0.0))
	var max_cargo: float = float(hub.get("max_cargo", S6.SUPPLY_UNIT_CARGO_CAPACITY))
	if cur_cargo >= max_cargo - 0.001:
		return 0.0
	for nid in _nodes.keys():
		var n: Dictionary = _nodes[nid]
		if str(n.get("faction", "")) != fac:
			continue
		var npos: Vector2i = n["coord"] as Vector2i
		if HexUtilsCls.hex_distance_axial(spos, npos) <= 1:
			var need: float = max_cargo - cur_cargo
			var take: float = 0.0
			if str(n.get("kind", "")) == "hq":
				if fac == "blue":
					take = minf(need, _central)
					_central -= take
			elif bool(n.get("infinite", false)):
				take = need
			else:
				take = minf(need, float(n.get("stock", 0.0)))
				n["stock"] = float(n.get("stock", 0.0)) - take
			if take > 0.001:
				hub["cargo"] = cur_cargo + take
				manager.s6_set_field(cid, "convoy_cargo", hub["cargo"])
				manager.log_observable_event({"type": "hub_refilled", "unit_id": cid, "node": nid, "amount": take, "turn": manager.get_current_turn()})
				return take
	return 0.0

# ------------------------------------------------------------------
# STEP-06R3: Trader-Style Macro Route Pathfinding & Assignment (§16-§21)
# ------------------------------------------------------------------
func compute_macro_route(
	origin: Vector2i,
	destination: Vector2i,
	strategy: String,
	cell_data: Dictionary,
	river_cells: Dictionary = {},
	stronghold_cells: Dictionary = {},
	fac: String = "blue",
	known_threats: Dictionary = {}
) -> Dictionary:
	if origin == destination:
		return {"found": true, "path": [origin], "cost": 0.0, "one_way_turns": 0, "round_trip_turns": 0}
	
	if not WorldBoundaryCls.is_playable_hex(destination):
		return {"found": false, "path": [], "cost": 0.0, "one_way_turns": 0, "round_trip_turns": 0}

	var g_score: Dictionary = {}
	var came_from: Dictionary = {}
	var open_set: Array[Vector2i] = [origin]
	var origin_k: String = "%d,%d" % [origin.x, origin.y]
	g_score[origin_k] = 0.0
	
	var is_road_priority: bool = (strategy == S6.ROUTE_STRATEGY_ROAD)
	var is_safe_route: bool = (strategy == S6.ROUTE_STRATEGY_SAFE)

	while not open_set.is_empty():
		var best_idx: int = 0
		var best_f: float = 1.0e9
		for i in range(open_set.size()):
			var c: Vector2i = open_set[i]
			var ck: String = "%d,%d" % [c.x, c.y]
			var g: float = float(g_score.get(ck, 1.0e9))
			var h: float = float(HexUtilsCls.hex_distance_axial(c, destination)) * 0.5
			var f: float = g + h
			if f < best_f:
				best_f = f
				best_idx = i
		
		var current: Vector2i = open_set[best_idx]
		if current == destination:
			break
		open_set.remove_at(best_idx)
		
		var current_k: String = "%d,%d" % [current.x, current.y]
		var current_g: float = float(g_score[current_k])
		
		var neighbors: Array[Vector2i] = HexUtilsCls.get_all_neighbors(current.x, current.y)
		for nbr in neighbors:
			if not WorldBoundaryCls.is_playable_hex(nbr):
				continue
			var nbr_k: String = "%d,%d" % [nbr.x, nbr.y]
			
			# Block foreign strongholds unless destination is that stronghold
			if nbr != destination and stronghold_cells.has(nbr_k):
				var sh_f: String = str(stronghold_cells[nbr_k])
				if sh_f != "" and sh_f != fac:
					continue
					
			var cell: Variant = cell_data.get(nbr_k, null)
			var terrain: int = int(cell.get("terrain", 0)) if (cell != null and not (cell is Dictionary)) else int((cell as Dictionary).get("terrain", 0)) if cell != null else 0
			if Step3ConfigCls.is_impassable(terrain) and nbr != destination:
				continue
				
			var step_c: float = Step3ConfigCls.get_terrain_cost(terrain, "supply")
			if is_road_priority:
				if terrain == 6: # Road discount
					step_c = 0.25
				else:
					step_c *= 1.40
			elif is_safe_route:
				for threat_k in known_threats.keys():
					var tpos: Vector2i = known_threats[threat_k] as Vector2i
					var td: int = HexUtilsCls.hex_distance_axial(nbr, tpos)
					if td <= 3:
						step_c += float(4 - td) * 3.0 # strong avoidance of nearby enemies
			if river_cells.has(nbr_k):
				step_c += 1.0
				
			var tent_g: float = current_g + step_c
			if not g_score.has(nbr_k) or tent_g < float(g_score[nbr_k]):
				g_score[nbr_k] = tent_g
				came_from[nbr_k] = current
				if not open_set.has(nbr):
					open_set.append(nbr)

	var dest_k: String = "%d,%d" % [destination.x, destination.y]
	if not came_from.has(dest_k):
		return {"found": false, "path": [], "cost": 0.0, "one_way_turns": 0, "round_trip_turns": 0}
		
	var path: Array[Vector2i] = [destination]
	var curr_back: Vector2i = destination
	while curr_back != origin:
		var pk: String = "%d,%d" % [curr_back.x, curr_back.y]
		curr_back = came_from[pk]
		path.append(curr_back)
	path.reverse()
	
	var total_cost: float = float(g_score.get(dest_k, 0.0))
	var one_way_turns: int = maxi(1, ceili(total_cost / S6.SUPPLY_UNIT_BASE_MP))
	var round_trip_turns: int = maxi(2, one_way_turns * 2)
	return {
		"found": true,
		"path": path,
		"cost": total_cost,
		"one_way_turns": one_way_turns,
		"round_trip_turns": round_trip_turns
	}

func get_viable_destinations(unit_id: String, arg2: Variant = {}, arg3: Variant = {}, stronghold_cells: Dictionary = {}, known_threats: Dictionary = {}) -> Array:
	var list: Array = []
	var u: Dictionary = _convoys.get(unit_id, {})
	var fac: String = str(u.get("faction", "blue"))
	var start_pos: Vector2i = Vector2i(-999, -999)
	if _convoys.has(unit_id) and (_convoys[unit_id] as Dictionary).has("origin_pos"):
		start_pos = _convoys[unit_id]["origin_pos"]
	elif _nodes.has("HQ"):
		start_pos = _nodes["HQ"]["coord"] as Vector2i
	
	var cell_data: Dictionary = {}
	var river_cells: Dictionary = {}
	var strategy: String = S6.ROUTE_STRATEGY_FASTEST
	if arg2 is Dictionary:
		cell_data = arg2 as Dictionary
		if arg3 is Dictionary:
			river_cells = arg3 as Dictionary
		elif arg3 is String:
			strategy = arg3 as String
	elif arg2 is RefCounted:
		if arg3 is String:
			strategy = arg3 as String

	for nid in _nodes.keys():
		var n: Dictionary = _nodes[nid]
		var npos: Vector2i = n["coord"] as Vector2i
		if npos == start_pos:
			continue
		var route_res: Dictionary = compute_macro_route(start_pos, npos, strategy, cell_data, river_cells, stronghold_cells, fac, known_threats)
		if bool(route_res.get("found", false)):
			var dist: int = HexUtilsCls.hex_distance_axial(start_pos, npos)
			list.append({
				"id": nid,
				"name": str(n.get("label", nid)),
				"label": str(n.get("label", nid)),
				"coord": npos,
				"kind": str(n.get("kind", "")),
				"turns": int(route_res.get("one_way_turns", 1)),
				"one_way_turns": int(route_res.get("one_way_turns", 1)),
				"round_trip_turns": int(route_res.get("round_trip_turns", 2)),
				"distance": dist,
				"path": route_res.get("path", []),
				"cost": float(route_res.get("cost", 0.0))
			})
	list.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.get("one_way_turns", 0)) < int(b.get("one_way_turns", 0))
	)
	return list

func assign_route(p1: Variant, p2: Variant, p3: Variant, p4: Variant, p5: Variant = "", p6: Variant = {}, river_cells: Dictionary = {}, stronghold_cells: Dictionary = {}, known_threats: Dictionary = {}) -> Dictionary:
	var manager: RefCounted = null
	var unit_id: String = ""
	var origin_id: String = "HQ"
	var dest_id: String = ""
	var strategy: String = S6.ROUTE_STRATEGY_ROAD
	var path: Array[Vector2i] = []
	var opos: Vector2i = Vector2i(-999, -999)
	var dpos: Vector2i = Vector2i(-999, -999)
	var origin_label: String = "본영"
	var dest_label: String = ""

	if p1 is RefCounted:
		manager = p1 as RefCounted
		unit_id = str(p2)
		origin_id = str(p3)
		dest_id = str(p4)
		strategy = str(p5)
		var cell_data: Dictionary = p6 if p6 is Dictionary else {}
		if _nodes.has(origin_id):
			opos = _nodes[origin_id]["coord"]
			origin_label = str(_nodes[origin_id].get("label", origin_id))
		if _nodes.has(dest_id):
			dpos = _nodes[dest_id]["coord"]
			dest_label = str(_nodes[dest_id].get("label", dest_id))
		var fac: String = str(_convoys.get(unit_id, {}).get("faction", "blue"))
		var r_res: Dictionary = compute_macro_route(opos, dpos, strategy, cell_data, river_cells, stronghold_cells, fac, known_threats)
		if not bool(r_res.get("found", false)):
			return {"success": false, "reason": "경로 없음", "error": "No valid route found to destination"}
		for p in (r_res.get("path", []) as Array):
			path.append(p as Vector2i)
	else:
		unit_id = str(p1)
		if p2 is Vector2i:
			opos = p2
		dest_id = str(p3)
		if p4 is Vector2i:
			dpos = p4
		if p5 is Array:
			for p in (p5 as Array):
				path.append(p as Vector2i)
		if p6 is String:
			strategy = p6 as String
		if _nodes.has(dest_id):
			dest_label = str(_nodes[dest_id].get("label", dest_id))
		else:
			dest_label = dest_id

	if not _convoys.has(unit_id):
		return {"success": false, "reason": "수송대 없음", "error": "Invalid convoy"}

	var one_way: int = maxi(1, int(ceil(float(path.size()) / 8.0)))
	var route_info: Dictionary = {
		"id": unit_id,
		"origin_id": origin_id,
		"origin_coord": opos,
		"origin_pos": opos,
		"origin_label": origin_label,
		"dest_node_id": dest_id,
		"dest_id": dest_id,
		"dest_coord": dpos,
		"dest_pos": dpos,
		"dest_label": dest_label,
		"strategy": strategy,
		"full_path": path,
		"path": path,
		"current_path": path.duplicate(),
		"progress_idx": 0,
		"heading_to_dest": true,
		"returning": false,
		"active": true,
		"one_way_turns": one_way,
		"round_trip_turns": one_way * 2,
		"status": "순환 운행 중 (목적지 향발)"
	}
	_convoys[unit_id]["route"] = route_info
	if manager != null and manager.has_method("s6_set_field"):
		manager.s6_set_field(unit_id, "has_assigned_route", true)
		manager.s6_set_field(unit_id, "route_dest_label", dest_label)
		manager.log_observable_event({
			"type": "supply_route_assigned",
			"unit_id": unit_id,
			"origin": origin_id,
			"destination": dest_id,
			"strategy": strategy,
			"one_way_turns": route_info["one_way_turns"],
			"turn": manager.get_current_turn()
		})
	return {"success": true, "route": route_info}

func cancel_route(p1: Variant, p2: Variant = null) -> Dictionary:
	var manager: RefCounted = null
	var unit_id: String = ""
	if p1 is RefCounted:
		manager = p1 as RefCounted
		unit_id = str(p2)
	else:
		unit_id = str(p1)
	if _convoys.has(unit_id):
		_convoys[unit_id]["route"] = {}
		if manager != null and manager.has_method("s6_set_field"):
			manager.s6_set_field(unit_id, "has_assigned_route", false)
			manager.s6_set_field(unit_id, "route_dest_label", "")
		return {"success": true}
	return {"success": false, "reason": "수송대 없음"}

func get_assigned_route(unit_id: String) -> Dictionary:
	if _convoys.has(unit_id):
		return (_convoys[unit_id] as Dictionary).get("route", {})
	return {}

func get_all_assigned_routes() -> Array:
	var out: Array = []
	for cid in _convoys.keys():
		var r: Dictionary = (_convoys[cid] as Dictionary).get("route", {})
		if not r.is_empty() and bool(r.get("active", false)):
			out.append(r)
	return out

func advance_supply_routes(manager: RefCounted, cell_data: Dictionary, river_cells: Dictionary = {}, stronghold_cells: Dictionary = {}, fog: RefCounted = null) -> Array:
	var moved_report: Array = []
	for cid in _convoys.keys():
		var hub: Dictionary = _convoys[cid]
		var route: Dictionary = hub.get("route", {})
		if route.is_empty():
			continue
		var u: Dictionary = manager.get_unit_by_id(cid)
		if u.is_empty() or int(u.get("soldier_count", 0)) <= 0:
			continue
			
		var cur_pos := Vector2i(int(u.get("q", 0)), int(u.get("r", 0)))
		var cur_path: Array = route.get("current_path", [])
		if cur_path.size() <= 1:
			var heading_dest: bool = bool(route.get("heading_to_dest", true))
			var full_p: Array = route.get("full_path", [])
			if heading_dest:
				route["heading_to_dest"] = false
				route["status"] = "회항 중 (출발지 복귀)"
				var rev_p: Array[Vector2i] = []
				for i in range(full_p.size() - 1, -1, -1):
					rev_p.append(full_p[i] as Vector2i)
				cur_path = rev_p
				route["current_path"] = cur_path
			else:
				route["heading_to_dest"] = true
				route["status"] = "보급 중 (목적지 향발)"
				check_mobile_hub_refill(manager, cid, cur_pos)
				cur_path = full_p.duplicate()
				route["current_path"] = cur_path
				
		var mp_budget: float = S6.SUPPLY_UNIT_BASE_MP
		var traversed: Array[Vector2i] = [cur_pos]
		var next_idx: int = 1
		
		while next_idx < cur_path.size() and mp_budget > 0.05:
			var step: Vector2i = cur_path[next_idx] as Vector2i
			var skey: String = "%d,%d" % [step.x, step.y]
			var cell: Variant = cell_data.get(skey, null)
			var terrain: int = int(cell.get("terrain", 0)) if (cell != null and not (cell is Dictionary)) else int((cell as Dictionary).get("terrain", 0)) if cell != null else 0
			var step_c: float = Step3ConfigCls.get_terrain_cost(terrain, "supply")
			if mp_budget < step_c - 0.001:
				break
			mp_budget -= step_c
			traversed.append(step)
			next_idx += 1
			
		if traversed.size() > 1:
			var final_coord: Vector2i = traversed[traversed.size() - 1]
			manager.execute_move(cid, traversed, S6.SUPPLY_UNIT_BASE_MP - mp_budget, Step3ConfigCls.MarchClass.GREEN, false)
			apply_mobile_path_resupply(manager, cid, traversed)
			var rem_p: Array[Vector2i] = []
			for i in range(traversed.size() - 1, cur_path.size()):
				rem_p.append(cur_path[i] as Vector2i)
			route["current_path"] = rem_p
			
			if fog != null:
				var vrad: int = S6.SUPPLY_ROUTE_VISION_RADIUS
				for tpos in traversed:
					for dq in range(-vrad, vrad + 1):
						for dr in range(maxi(-vrad, -dq - vrad), mini(vrad, -dq + vrad) + 1):
							var vk: String = "%d,%d" % [tpos.x + dq, tpos.y + dr]
							if cell_data.has(vk):
								fog.visible[vk] = true
								fog.explored[vk] = true
								
			moved_report.append({"id": cid, "traversed": traversed, "destination": route.get("dest_label", "")})
			
		if (route["current_path"] as Array).size() <= 1:
			var was_heading_dest: bool = bool(route.get("heading_to_dest", true))
			var fp: Array = route.get("full_path", [])
			if was_heading_dest:
				route["heading_to_dest"] = false
				route["status"] = "목적지 도착 (회항 준비)"
				var rp: Array[Vector2i] = []
				for i in range(fp.size() - 1, -1, -1):
					rp.append(fp[i] as Vector2i)
				route["current_path"] = rp
			else:
				route["heading_to_dest"] = true
				route["status"] = "본영 귀환 (보급 충전 완료)"
				var refilled_amt: float = check_mobile_hub_refill(manager, cid, cur_pos)
				route["current_path"] = fp.duplicate()
				
	return moved_report

# ------------------------------------------------------------------
# Per-turn update (called once at player-phase start, after end_turn)
# ------------------------------------------------------------------
func begin_player_turn(manager: RefCounted, cell_data: Dictionary, river_cells: Dictionary, stronghold_cells: Dictionary, visible_enemy_ids: Dictionary, fog: RefCounted = null) -> Dictionary:
	var report: Dictionary = {"convoys_moved": [], "convoys_spawned": [], "convoys_delivered": [], "convoys_recalled": [], "supplied": 0, "hungry": _pending_hungry, "routed_new": [], "rallied": [], "fled": [], "central": _central, "battle_lost": _battle_lost, "events": 0}
	_pending_hungry = 0
	if not _init_done:
		return report
	var turn: int = manager.get_current_turn()
	_refresh_stronghold_nodes(manager)
	# HQ node follows the HQ.
	if _hq_id != "" and _nodes.has("HQ"):
		var hq: Dictionary = manager.get_unit_by_id(_hq_id)
		if hq.is_empty() or int(hq.get("soldier_count", 0)) <= 0:
			_battle_lost = true
			report["battle_lost"] = true
			return report
		var old_hq_pos: Vector2i = _nodes["HQ"]["coord"] as Vector2i
		var new_hq_pos := Vector2i(int(hq.get("q", 0)), int(hq.get("r", 0)))
		if old_hq_pos != new_hq_pos:
			_nodes["HQ"]["coord"] = new_hq_pos
			_node_coverage_cache.erase("HQ")

	# Stationary mobile hubs sitting at/adjacent to fixed nodes auto-refill
	for cid in _convoys.keys():
		var hub: Dictionary = _convoys[cid]
		var su: Dictionary = manager.get_unit_by_id(cid)
		if su.is_empty():
			continue
		var spos := Vector2i(int(su.get("q", 0)), int(su.get("r", 0)))
		var fac: String = str(hub.get("faction", ""))
		_check_hub_refill_at_nodes(spos, hub, fac, cid, manager)

	# Autonomous Trader-style supply NPCs advance along assigned routes
	var advanced: Array = advance_supply_routes(manager, cell_data, river_cells, stronghold_cells, fog)
	report["convoys_moved"] = advanced

	_replenish_all(manager, cell_data, stronghold_cells, report)
	_morale_drift(manager, turn, report)
	_rout_and_rally(manager, cell_data, river_cells, stronghold_cells, turn, report)
	_spotted_events(manager, visible_enemy_ids, report)
	report["central"] = _central
	report["battle_lost"] = _battle_lost
	return report

# ------------------------------------------------------------------
# End-of-turn consumption
# ------------------------------------------------------------------
func end_turn_charges(manager: RefCounted, cell_data: Dictionary = {}, stronghold_cells: Dictionary = {}) -> Dictionary:
	for u in manager.get_all_units():
		var uid: String = str(u.get("id", ""))
		var cls: String = str(u.get("class", ""))
		if cls == "supply":
			continue # porters live off cargo abstraction; no hunger spiral
		var troops: int = int(u.get("soldier_count", 0))
		if troops <= 0:
			continue
		var maxt: int = maxi(1, int(u.get("max_count", troops)))
		if str(u.get("faction", "")) == "blue" and cls == "hq":
			_top_up_hq(manager, uid, u)
			continue
			
		var fac: String = str(u.get("faction", ""))
		var upos := Vector2i(int(u.get("q", 0)), int(u.get("r", 0)))
		var cov_info: Dictionary = is_hex_covered(upos, fac, cell_data, stronghold_cells)
		var is_covered: bool = bool(cov_info.get("covered", false))
		
		if is_covered:
			# Unit is securely supplied inside fixed node coverage envelope!
			var need_top: float = float(u.get("local_supply_max", 0.0)) - float(u.get("local_supply", 0.0))
			if need_top > 0.0:
				var nid: String = str(cov_info.get("node_id", ""))
				if _nodes.has(nid):
					var nd: Dictionary = _nodes[nid]
					if str(nd.get("kind", "")) == "hq" and fac == "blue":
						var draw: float = minf(need_top, _central)
						_central -= draw
						manager.s6_adjust_supply(uid, draw)
					elif bool(nd.get("infinite", false)):
						manager.s6_adjust_supply(uid, need_top)
					else:
						var draw: float = minf(need_top, float(nd.get("stock", 0.0)))
						nd["stock"] = float(nd.get("stock", 0.0)) - draw
						manager.s6_adjust_supply(uid, draw)
				else:
					manager.s6_adjust_supply(uid, need_top)
			if int(u.get("consecutive_hungry", 0)) > 0:
				manager.s6_set_field(uid, "consecutive_hungry", 0)
			manager.s6_add_fatigue(uid, -S6.SUPPLIED_FATIGUE_RECOVERY)
			_update_supply_state(manager, uid)
		else:
			# Outside coverage: consumes from local 5-day carried supply buffer!
			var need: float = float(troops) * S6.FOOD_PER_TROOP_PER_TURN
			if bool(u.get("unguarded", false)) and bool(u.get("has_moved", false)):
				need += float(maxt) * S6.FOOD_PER_TROOP_PER_TURN * S6.FORCED_MARCH_EXTRA_TURNS
			var adj: Dictionary = manager.s6_adjust_supply(uid, -need)
			if bool(adj.get("shortage", false)):
				manager.s6_set_field(uid, "consecutive_hungry", int(u.get("consecutive_hungry", 0)) + 1)
				var streak: int = int(manager.get_unit_by_id(uid).get("consecutive_hungry", 1))
				var shock: float = S6.HUNGER_MORALE_FIRST if streak <= 1 else S6.HUNGER_MORALE_ONGOING
				manager.s6_add_morale(uid, shock)
				manager.s6_add_fatigue(uid, S6.HUNGER_FATIGUE)
				_pending_hungry += 1
			else:
				if int(u.get("consecutive_hungry", 0)) > 0:
					manager.s6_set_field(uid, "consecutive_hungry", 0)
				manager.s6_add_fatigue(uid, -S6.SUPPLIED_FATIGUE_RECOVERY)
			_update_supply_state(manager, uid)
	var out: Dictionary = {"hungry": _pending_hungry}
	return out

func _replenish_all(manager: RefCounted, cell_data: Dictionary, stronghold_cells: Dictionary, report: Dictionary) -> void:
	for u in manager.get_all_units():
		var uid: String = str(u.get("id", ""))
		var cls: String = str(u.get("class", ""))
		if cls == "supply" or cls == "hq":
			continue
		if int(u.get("soldier_count", 0)) <= 0 or bool(u.get("routed", false)):
			continue
		var fac: String = str(u.get("faction", ""))
		var upos := Vector2i(int(u.get("q", 0)), int(u.get("r", 0)))
		var cur: float = float(u.get("local_supply", 0.0))
		var mx: float = float(u.get("local_supply_max", 0.0))
		if cur >= mx - 0.001:
			continue
		
		# 1. Check fixed node coverage
		var cov_info: Dictionary = is_hex_covered(upos, fac, cell_data, stronghold_cells)
		if bool(cov_info.get("covered", false)):
			var need: float = mx - cur
			var nid: String = str(cov_info.get("node_id", ""))
			var n: Dictionary = _nodes.get(nid, {})
			var draw: float = need
			if str(n.get("kind", "")) == "hq":
				if fac == "blue":
					draw = minf(need, _central)
					_central -= draw
			elif not bool(n.get("infinite", false)):
				draw = minf(need, float(n.get("stock", 0.0)))
				n["stock"] = float(n.get("stock", 0.0)) - draw
			if draw > 0.001:
				manager.s6_adjust_supply(uid, draw)
				report["supplied"] = int(report.get("supplied", 0)) + 1
			_update_supply_state(manager, uid)
			continue
			
		# 2. Check nearby friendly mobile supply hubs within 2 hexes
		for cid in _convoys.keys():
			var hub: Dictionary = _convoys[cid]
			if str(hub.get("faction", "")) != fac:
				continue
			if float(hub.get("cargo", 0.0)) <= 0.001:
				continue
			var su: Dictionary = manager.get_unit_by_id(cid)
			if su.is_empty():
				continue
			var spos := Vector2i(int(su.get("q", 0)), int(su.get("r", 0)))
			if HexUtilsCls.hex_distance_axial(upos, spos) <= S6.SUPPLY_UNIT_SERVICE_RADIUS:
				var need2: float = mx - cur
				var give: float = minf(need2, float(hub.get("cargo", 0.0)))
				hub["cargo"] = float(hub.get("cargo", 0.0)) - give
				manager.s6_set_field(cid, "convoy_cargo", hub["cargo"])
				manager.s6_adjust_supply(uid, give)
				report["supplied"] = int(report.get("supplied", 0)) + 1
				cur += give
				if cur >= mx - 0.001:
					break
		_update_supply_state(manager, uid)

func _top_up_hq(manager: RefCounted, uid: String, u: Dictionary) -> void:
	var cur: float = float(u.get("local_supply", 0.0))
	var mx: float = float(u.get("local_supply_max", 1.0))
	if _central > 0.0 and cur < mx:
		var take: float = minf(mx - cur, _central)
		_central -= take
		manager.s6_adjust_supply(uid, take)
	_update_supply_state(manager, uid)

func _update_supply_state(manager: RefCounted, uid: String) -> void:
	var u: Dictionary = manager.get_unit_by_id(uid)
	if u.is_empty():
		return
	var turns: float = S6.buffer_turns(float(u.get("local_supply", 0.0)), int(u.get("max_count", 1)))
	var st: int = S6.STATE_SHORT
	if turns >= S6.SMOOTH_TURNS:
		st = S6.STATE_SMOOTH
	elif turns >= S6.UNSTABLE_TURNS:
		st = S6.STATE_UNSTABLE
	elif turns > 0.0:
		st = S6.STATE_SHORT
	else:
		st = S6.STATE_CUT
	manager.s6_set_field(uid, "supply_state", st)

# ------------------------------------------------------------------
# Morale drift (§18-§19)
# ------------------------------------------------------------------
func _morale_drift(manager: RefCounted, turn: int, report: Dictionary) -> void:
	var units: Array = manager.get_all_units()
	var pos: Dictionary = {}
	var by_id: Dictionary = {}
	for u in units:
		var uid0: String = str(u.get("id", ""))
		pos[uid0] = Vector2i(int(u.get("q", 0)), int(u.get("r", 0)))
		by_id[uid0] = u
	for u in units:
		var uid: String = str(u.get("id", ""))
		if int(u.get("soldier_count", 0)) <= 0:
			continue
		var drift: float = 0.0
		# HQ command presence, continuous distance decay (§19, provisional axial).
		var hq_pos: Vector2i = _command_pos(str(u.get("faction", "")), manager)
		if hq_pos.x != -999:
			var d: float = float(HexUtilsCls.hex_distance_axial(pos[uid] as Vector2i, hq_pos))
			if d <= S6.HQ_NEAR_DIST:
				drift += S6.HQ_NEAR_BONUS
			elif d >= S6.HQ_FAR_DIST:
				drift += S6.HQ_FAR_PENALTY
			else:
				var t: float = (d - S6.HQ_NEAR_DIST) / maxf(1.0, S6.HQ_FAR_DIST - S6.HQ_NEAR_DIST)
				drift += lerpf(S6.HQ_NEAR_BONUS, S6.HQ_FAR_PENALTY, t)
		# Encirclement where detectable (§18).
		var adj: int = 0
		for oid in pos.keys():
			if oid == uid:
				continue
			var ou: Dictionary = by_id.get(oid, {})
			if ou.is_empty() or str(ou.get("faction", "")) == str(u.get("faction", "")):
				continue
			if int(ou.get("soldier_count", 0)) <= 0:
				continue
			if HexUtilsCls.hex_distance_axial(pos[uid] as Vector2i, pos[oid] as Vector2i) == 1:
				adj += 1
		if adj >= S6.ENCIRCLE_ADJACENT:
			drift += S6.ENCIRCLE_PENALTY
		drift = clampf(drift, S6.DRIFT_MIN, S6.DRIFT_MAX)
		if absf(drift) > 0.001:
			manager.s6_add_morale(uid, drift)

func _command_pos(faction: String, manager: RefCounted) -> Vector2i:
	if faction == "blue" and _hq_id != "":
		var hq: Dictionary = manager.get_unit_by_id(_hq_id)
		if not hq.is_empty():
			return Vector2i(int(hq.get("q", -999)), int(hq.get("r", -999)))
	if faction == "red" and _nodes.has("RED_ORIGIN"):
		return _nodes["RED_ORIGIN"]["coord"] as Vector2i
	return Vector2i(-999, -999)

# ------------------------------------------------------------------
# Rout & rally (§24-§25)
# ------------------------------------------------------------------
func seeded_roll(key: String) -> float:
	return float(abs(hash(key)) % 1000) / 1000.0

func _rout_and_rally(manager: RefCounted, cell_data: Dictionary, river_cells: Dictionary, stronghold_cells: Dictionary, turn: int, report: Dictionary) -> void:
	if not SandboxRulesCls.is_rout_allowed():
		return
	for u in manager.get_all_units():
		var uid: String = str(u.get("id", ""))
		if str(u.get("class", "")) == "supply":
			continue
		if int(u.get("soldier_count", 0)) <= 0:
			continue
		if bool(u.get("garrisoned", false)):
			continue
		var morale: float = float(u.get("morale", 100.0))
		if bool(u.get("routed", false)):
			_rally_or_flee(manager, uid, u, turn, cell_data, river_cells, stronghold_cells, report)
		elif morale < S6.ROUT_MORALE_LINE:
			var p: float = S6.ROUT_BASE_P + (S6.ROUT_MORALE_LINE - morale) * S6.ROUT_MORALE_SCALE
			if int(u.get("consecutive_hungry", 0)) > 0:
				p += S6.ROUT_HUNGRY_P
			p = minf(p, S6.ROUT_P_CAP)
			if seeded_roll("%s:%d:rout" % [uid, turn]) < p:
				manager.s6_set_routed(uid, true)
				manager.log_observable_event({"type": "rout", "unit_id": uid, "turn": turn, "morale": morale})
				(report["routed_new"] as Array).append(uid)

func _rally_or_flee(manager: RefCounted, uid: String, u: Dictionary, turn: int, cell_data: Dictionary, river_cells: Dictionary, stronghold_cells: Dictionary, report: Dictionary) -> void:
	var turns: int = int(u.get("rout_turns", 0)) + 1
	manager.s6_set_field(uid, "rout_turns", turns)
	var morale: float = float(u.get("morale", 0.0))
	var upos: Vector2i = Vector2i(int(u.get("q", 0)), int(u.get("r", 0)))
	var hq_pos: Vector2i = _command_pos(str(u.get("faction", "")), manager)
	var near_hq: bool = hq_pos.x != -999 and HexUtilsCls.hex_distance_axial(upos, hq_pos) <= S6.RALLY_NEAR_HQ
	var on_node: bool = false
	for nid in _nodes.keys():
		var n: Dictionary = _nodes[nid]
		if str(n.get("faction", "")) == str(u.get("faction", "")) and HexUtilsCls.hex_distance_axial(upos, n["coord"] as Vector2i) <= 1:
			on_node = true
			break
	if turns >= S6.RALLY_MIN_TURNS and (near_hq or on_node or morale >= S6.RALLY_MORALE_FLOOR):
		if seeded_roll("%s:%d:rally" % [uid, turn]) < S6.RALLY_BASE_P:
			manager.s6_set_routed(uid, false)
			manager.s6_add_morale(uid, maxf(0.0, S6.RALLY_MORALE_FLOOR - morale))
			manager.log_observable_event({"type": "rally", "unit_id": uid, "turn": turn})
			(report["rallied"] as Array).append(uid)
			return
	# Flee: green-budget hex maximizing distance from enemies, leaning to HQ.
	var nn: Vector2i = _flee_step(manager, uid, u, upos, hq_pos, cell_data, river_cells, stronghold_cells)
	if nn != upos:
		var mv: Dictionary = _manager_move(manager, uid, u, upos, nn, cell_data, river_cells, stronghold_cells, str(u.get("faction", "")))
		if bool(mv.get("success", false)):
			(report["fled"] as Array).append({"id": uid, "to": nn})
	manager.s6_set_field(uid, "action_ended", true)
	manager.s6_set_field(uid, "turn_resolved", true)
	manager.s6_set_field(uid, "reviewed_this_turn", true)

func _flee_step(manager: RefCounted, uid: String, u: Dictionary, origin: Vector2i, hq_pos: Vector2i, cell_data: Dictionary, river_cells: Dictionary, stronghold_cells: Dictionary) -> Vector2i:
	var base: float = float(u.get("base_mp", 2.0))
	var env: Variant = Step3PathfindingCls.calculate_envelope(origin, str(u.get("class", "infantry")), base, base, 0, cell_data, manager.get_occupied_dict(), river_cells, str(u.get("faction", "")), stronghold_cells, 0.0, base, base * 2.0, base * 2.2)
	if env.green_hexes.is_empty():
		return origin
	var foes: Array[Vector2i] = []
	for e in manager.get_all_units():
		if str(e.get("faction", "")) == str(u.get("faction", "")):
			continue
		if int(e.get("soldier_count", 0)) <= 0:
			continue
		foes.append(Vector2i(int(e.get("q", 0)), int(e.get("r", 0))))
	var best: Vector2i = origin
	var best_s: float = -1.0e9
	for h in env.green_hexes:
		var nd: int = 99
		for f in foes:
			nd = mini(nd, HexUtilsCls.hex_distance_axial(h, f))
		var hd: float = 0.0
		if hq_pos.x != -999:
			hd = float(HexUtilsCls.hex_distance_axial(h, hq_pos))
		var s: float = float(nd) * 2.0 - hd * 0.7
		if s > best_s:
			best_s = s
			best = h
	return best

func _manager_move(manager: RefCounted, uid: String, u: Dictionary, from_pos: Vector2i, to_pos: Vector2i, cell_data: Dictionary, river_cells: Dictionary, stronghold_cells: Dictionary, fac: String) -> Dictionary:
	var base: float = float(u.get("base_mp", 2.0))
	var route: Variant = Step3PathfindingCls.find_route(from_pos, to_pos, str(u.get("class", "infantry")), base, base, Step3ConfigCls.MarchPolicy.ORANGE_ALLOWED, cell_data, manager.get_occupied_dict(), river_cells, fac, stronghold_cells, 0.0, base, base * 2.0, base * 2.2)
	if route == null or not route.found or not route.is_valid_destination:
		return {"success": false}
	return manager.execute_move(uid, route.path, route.cost, route.march_class, route.crosses_river)

# ------------------------------------------------------------------
# Post-combat hook (called by shell after every field attack resolves)
# ------------------------------------------------------------------
func after_combat(manager: RefCounted, atk_id: String, def_id: String, res: Dictionary) -> Dictionary:
	var out: Dictionary = {"captured": false, "battle_lost": _battle_lost, "routed": [], "witnessed": 0}
	var turn: int = manager.get_current_turn()
	var atk: Dictionary = manager.get_unit_by_id(atk_id)
	var def_class: String = str(res.get("defender_class", ""))
	if def_class == "":
		var dd: Dictionary = manager.get_unit_by_id(def_id)
		def_class = str(dd.get("class", ""))
	# §28 captured/raided supply fills ONLY the attacker's local buffer. Supply NPC is disrupted (§24-§25).
	if def_class == "supply" and bool(res.get("defender_destroyed", false)) and not atk.is_empty():
		var mx: float = float(atk.get("local_supply_max", 0.0))
		var delta: float = mx - float(atk.get("local_supply", 0.0))
		if delta > 0.001:
			manager.s6_adjust_supply(atk_id, delta)
		manager.s6_add_morale(atk_id, 2.0)
		if _convoys.has(def_id):
			_convoys[def_id]["cargo"] = 0.0
			if (_convoys[def_id] as Dictionary).has("route"):
				(_convoys[def_id]["route"] as Dictionary)["status"] = "약탈당함 (보급선 차단)"
				(_convoys[def_id]["route"] as Dictionary)["current_path"] = []
		manager.log_observable_event({"type": "convoy_captured", "unit_id": atk_id, "convoy_id": def_id, "turn": turn})
		out["captured"] = true
	# §3 HQ destroyed in a valid attack = immediate battle loss.
	if def_id == _hq_id and bool(res.get("defender_destroyed", false)):
		_battle_lost = true
		out["battle_lost"] = true
	if atk_id == _hq_id and bool(res.get("attacker_destroyed", false)):
		_battle_lost = true
		out["battle_lost"] = true
	# Witness shock: nearby allies of a destroyed/routed victim waver (§18).
	var victim_gone: bool = bool(res.get("defender_destroyed", false))
	if victim_gone:
		out["witnessed"] = _apply_witness(manager, atk, str(res.get("defender_class", "")), def_id)
	# Immediate rout checks on survivors standing in the shock.
	var rout_checks: Array = [atk_id, def_id] if SandboxRulesCls.is_rout_allowed() else []
	for pid in rout_checks:
		var pu: Dictionary = manager.get_unit_by_id(pid)
		if pu.is_empty() or int(pu.get("soldier_count", 0)) <= 0:
			continue
		if bool(pu.get("routed", false)) or bool(pu.get("garrisoned", false)):
			continue
		if str(pu.get("class", "")) == "supply":
			continue
		var pm: float = float(pu.get("morale", 100.0))
		if pm >= S6.ROUT_MORALE_LINE:
			continue
		var cas: int = int(res.get("attacker_casualties" if pid == atk_id else "defender_casualties", 0))
		var rem: int = int(pu.get("soldier_count", 0))
		var loss_ratio: float = float(cas) / float(maxi(1, cas + rem))
		var p: float = minf(S6.ROUT_BASE_P + (S6.ROUT_MORALE_LINE - pm) * S6.ROUT_MORALE_SCALE + loss_ratio * 0.3, S6.ROUT_P_CAP)
		if seeded_roll("%s:%d:shock" % [pid, turn]) < p:
			manager.s6_set_routed(pid, true)
			manager.log_observable_event({"type": "rout", "unit_id": pid, "turn": turn, "morale": pm})
			(out["routed"] as Array).append(pid)
	return out

func _apply_witness(manager: RefCounted, atk: Dictionary, def_class: String, def_id: String) -> int:
	# Epicenter: attacker position (adjacent in all valid attacks).
	if atk.is_empty():
		return 0
	var epi: Vector2i = Vector2i(int(atk.get("q", -999)), int(atk.get("r", -999)))
	# Victim faction: opposite of attacker (convoys/HQ included via res class).
	var atk_fac: String = str(atk.get("faction", ""))
	var vic_fac: String = "red" if atk_fac == "blue" else "blue"
	var n: int = 0
	for u in manager.get_all_units():
		if str(u.get("faction", "")) != vic_fac:
			continue
		var uid: String = str(u.get("id", ""))
		if uid == def_id:
			continue
		if int(u.get("soldier_count", 0)) <= 0 or bool(u.get("garrisoned", false)):
			continue
		var d: int = HexUtilsCls.hex_distance_axial(epi, Vector2i(int(u.get("q", 0)), int(u.get("r", 0))))
		if d <= S6.WITNESS_ROUT_RADIUS:
			manager.s6_add_morale(uid, S6.WITNESS_DESTROY_SHOCK)
			n += 1
	return n

func note_routed_witness(manager: RefCounted, routed_id: String) -> int:
	var ru: Dictionary = manager.get_unit_by_id(routed_id)
	if ru.is_empty():
		return 0
	var epi: Vector2i = Vector2i(int(ru.get("q", -999)), int(ru.get("r", -999)))
	var fac: String = str(ru.get("faction", ""))
	var n: int = 0
	for u in manager.get_all_units():
		if str(u.get("faction", "")) != fac:
			continue
		var uid: String = str(u.get("id", ""))
		if uid == routed_id or bool(u.get("garrisoned", false)):
			continue
		if HexUtilsCls.hex_distance_axial(epi, Vector2i(int(u.get("q", 0)), int(u.get("r", 0)))) <= S6.WITNESS_ROUT_RADIUS:
			manager.s6_add_morale(uid, S6.WITNESS_ROUT_SHOCK)
			n += 1
	return n

func _spotted_events(manager: RefCounted, visible_enemy_ids: Dictionary, report: Dictionary) -> void:
	for u in manager.get_all_units():
		if str(u.get("faction", "")) == "blue" or str(u.get("class", "")) != "supply":
			continue
		var eid: String = str(u.get("id", ""))
		if not visible_enemy_ids.has(eid):
			continue
		if _known_convoy.has(eid):
			continue
		_known_convoy[eid] = true
		manager.log_observable_event({"type": "convoy_spotted", "unit_id": eid, "q": int(u.get("q", 0)), "r": int(u.get("r", 0)), "turn": manager.get_current_turn()})
		report["events"] = int(report.get("events", 0)) + 1

# ------------------------------------------------------------------
# Combat effectiveness modifiers (§16 cascade, §20 hybrid)
# ------------------------------------------------------------------
func combat_mods_for(manager: RefCounted, unit_id: String) -> Dictionary:
	var u: Dictionary = manager.get_unit_by_id(unit_id)
	var atk_b: float = 1.0
	var def_b: float = 1.0
	if u.is_empty():
		return {"attacker_bonus": atk_b, "defender_bonus": def_b}
	if float(u.get("local_supply", 1.0)) <= 0.0 and str(u.get("class", "")) != "supply":
		atk_b *= S6.STARVING_EFFECT_MULT
		def_b *= S6.STARVING_EFFECT_MULT
	if float(u.get("fatigue", 0.0)) >= S6.FATIGUE_EXHAUSTED:
		atk_b *= S6.EXHAUSTED_EFFECT_MULT
		def_b *= S6.EXHAUSTED_EFFECT_MULT
	return {"attacker_bonus": atk_b, "defender_bonus": def_b}

func attacker_bonus_vs(manager: RefCounted, atk_id: String, def_id: String) -> Dictionary:
	var m: Dictionary = combat_mods_for(manager, atk_id)
	var d: Dictionary = manager.get_unit_by_id(def_id)
	if not d.is_empty() and bool(d.get("routed", false)):
		m["attacker_bonus"] = float(m.get("attacker_bonus", 1.0)) * S6.ROUTED_DEFENSELESS_MULT
	return m

# ------------------------------------------------------------------
# Read helpers for shell UI
# ------------------------------------------------------------------
func get_central() -> float:
	return _central

func is_battle_lost() -> bool:
	return _battle_lost

func note_hq_destroyed() -> void:
	_battle_lost = true

func get_hq_id() -> String:
	return _hq_id

func get_nodes() -> Dictionary:
	return _nodes

func get_convoys() -> Dictionary:
	return _convoys

func convoy_info(cid: String) -> Dictionary:
	return _convoys.get(cid, {})

func node_of_convoy(cid: String) -> Dictionary:
	return {}

# STEP-06R2: link_of returns empty for backward compatibility
func link_of(unit_id: String) -> Dictionary:
	return {}

func customer_of_convoy(cid: String) -> Dictionary:
	return {}
