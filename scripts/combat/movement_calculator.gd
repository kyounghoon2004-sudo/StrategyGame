class_name MovementCalculator
extends RefCounted

## 이동력 계산 및 도달 가능 헥스 탐색.
## 병과 기본 이동력 + 지형 비용 + 규모 페널티 + 징집병 비율 페널티.
## 도로 비용 0 무한 이동 버그 수정: 최소 0.5(float) 또는 1로 보정, Dijkstra로 최단비용 탐색.

# Preloads for parse-order safety
const _HexCellGD = preload("res://scripts/core/hex_cell.gd")
const _HexUtilsGD = preload("res://scripts/core/hex_utils.gd")

# ---- 지형별 이동 비용 (1헥스당 소모 이동력) ----
# NOTE: Use int literals 0..6 to avoid global HexCell parse-order dependency.
const TERRAIN_COST := {
	0:    1.0,  # PLAINS
	1: 2.0,  # MOUNTAINS
	2:    2.0,  # FOREST
	3:     3.0,  # SWAMP
	4:  1.0,  # FORTRESS
	5:   1.0,  # VILLAGE
	6:      1.0,   # was 0 → fixed to 1.0
}

# ---- 군 규모 페널티 공식 ----
const SIZE_THRESHOLD := 200
const SIZE_PER_300 := 1
const SIZE_DIVISOR := 300
const CONSCRIPT_COST_PER_400 := 1

static func get_movement_points(unit_type, soldier_count: int) -> int:
	var base: int = int(unit_type.get("base_movement")) if unit_type else 2
	var size_penalty: int = 0
	if soldier_count > SIZE_THRESHOLD:
		size_penalty = int(floor(float(soldier_count - SIZE_THRESHOLD) / float(SIZE_DIVISOR)))
	var conscript_penalty: int = 0
	var is_conscript: bool = bool(unit_type.get("is_conscript")) if unit_type else false
	if is_conscript:
		conscript_penalty = int(floor(soldier_count / 400.0)) * CONSCRIPT_COST_PER_400
	var total_penalty: int = size_penalty + conscript_penalty
	return maxi(1, base - total_penalty)

static func get_movement_points_from_unit(unit) -> int:
	if unit == null:
		return 1
	return get_movement_points(unit.get("unit_type"), int(unit.get("soldier_count")))

static func get_terrain_cost(terrain: int) -> float:
	var c: float = float(TERRAIN_COST.get(terrain, 1.0))
	return maxf(c, 0.5)

# ---- 도달 가능 헥스 (Dijkstra, float budget) ----
## grid: Dictionary — 키 "%d,%d" (q,r), 값: HexCell
## 반환: Array[Vector2i] — 도달 가능한 헥스의 axial 좌표 목록 (시작 헥스 포함)
static func get_reachable_hexes(unit, grid: Dictionary) -> Array[Vector2i]:
	if unit == null:
		return []
	var start := Vector2i(int(unit.get("hex_q")), int(unit.get("hex_r")))
	var budget: float = float(unit.get_movement_points()) if unit.has_method("get_movement_points") else float(get_movement_points_from_unit(unit))
	if budget <= 0:
		return [start]

	# Dijkstra: best_cost[hex_key] = minimal cost from start
	var best_cost: Dictionary = {}
	var start_key: String = "%d,%d" % [start.x, start.y]
	best_cost[start_key] = 0.0
	# priority queue as sorted array (grid <300, fine)
	var frontier: Array[Dictionary] = [{"pos": start, "cost": 0.0}]
	var result: Array[Vector2i] = [start]

	while not frontier.is_empty():
		# pop lowest cost
		var best_idx: int = 0
		var best_c: float = float(frontier[0]["cost"])
		for i in range(1, frontier.size()):
			var c: float = float(frontier[i]["cost"])
			if c < best_c:
				best_c = c
				best_idx = i
		var cur: Dictionary = frontier[best_idx]
		frontier.remove_at(best_idx)
		var cur_pos: Vector2i = cur["pos"]
		var cur_cost: float = float(cur["cost"])
		# stale entry check
		var cur_key: String = "%d,%d" % [cur_pos.x, cur_pos.y]
		if cur_cost > float(best_cost.get(cur_key, 9999.0)) + 0.001:
			continue
		var neighbors: Array = []
		# Use preload for parse-order safety
		neighbors = _HexUtilsGD.get_all_neighbors_offset(cur_pos.x, cur_pos.y)
		for n in neighbors:
			var nq: int = int(n.x)
			var nr: int = int(n.y)
			var key: String = "%d,%d" % [nq, nr]
			var cell = grid.get(key)
			if cell == null:
				continue
			var utype = unit.get("unit_type")
			var can_enter: bool = true
			if utype and utype.has_method("can_enter"):
				can_enter = bool(utype.can_enter(cell.get("terrain") if cell.has_method("get") else cell.terrain))
			if not can_enter:
				continue
			var step_cost: float = get_terrain_cost(int(cell.get("terrain")) if cell else 0)
			var new_cost: float = cur_cost + step_cost
			if new_cost > budget + 0.001:
				continue
			var prev_best: float = float(best_cost.get(key, 9999.0))
			if new_cost + 0.001 < prev_best:
				best_cost[key] = new_cost
				var nv := Vector2i(nq, nr)
				if nv not in result:
					result.append(nv)
				frontier.append({"pos": nv, "cost": new_cost})
	return result
