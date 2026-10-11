class_name HexUtils
extends RefCounted

## HexUtils — Flat-top odd-q offset + axial/cube utilities
## Art-guide: 48×42 flat-top, col_step=36 (TILE_W*0.75), row_step=42, odd-q y_offset=21
## Internal grid storage is offset (q=col, r=row). Axial helpers provided for distance/path.

# ---- Visual tile geometry (art_guide) ----
const TILE_W: int = 48
const TILE_H: int = 42
const COL_STEP: int = 36          # TILE_W * 0.75
const ROW_STEP: int = 42          # TILE_H
const ODD_Q_Y_OFFSET: int = 21    # TILE_H * 0.5

# ---- Legacy axial size (for axial math compatibility) ----
const HEX_SIZE: float = 24.0
const HEX_WIDTH: float = 2.0 * HEX_SIZE
const HEX_HEIGHT: float = 1.7320508 * HEX_SIZE

# Axial directions clockwise from east (flat-top axial)
const DIRECTIONS: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(1, -1), Vector2i(0, -1),
	Vector2i(-1, 0), Vector2i(-1, 1), Vector2i(0, 1)
]
# Odd-q offset neighbor tables (flat-top)
const DIRS_EVEN: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(0, -1), Vector2i(-1, -1),
	Vector2i(-1, 0), Vector2i(-1, 1), Vector2i(0, 1)
]
const DIRS_ODD: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(1, -1), Vector2i(0, -1),
	Vector2i(-1, 0), Vector2i(0, 1), Vector2i(1, 1)
]

# ------------------------------------------------------------------
# Offset <-> Axial conversions
# ------------------------------------------------------------------
static func offset_to_axial(off: Vector2i) -> Vector2i:
	var col: int = off.x
	var row: int = off.y
	var q: int = col
	var r: int = row - (col - (col & 1)) / 2
	return Vector2i(q, r)

static func axial_to_offset(ax: Vector2i) -> Vector2i:
	var q: int = ax.x
	var r: int = ax.y
	var col: int = q
	var row: int = r + (q - (q & 1)) / 2
	return Vector2i(col, row)

# ------------------------------------------------------------------
# Neighbors
# ------------------------------------------------------------------
static func get_neighbor(q: int, r: int, direction: int) -> Vector2i:
	return Vector2i(q, r) + DIRECTIONS[direction % 6]

static func get_all_neighbors(q: int, r: int) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	for dir: Vector2i in DIRECTIONS:
		result.append(Vector2i(q, r) + dir)
	return result

## Parity-aware offset neighbors (use when q=col, r=row offset)
static func get_all_neighbors_offset(q: int, r: int) -> Array[Vector2i]:
	var dirs: Array[Vector2i] = DIRS_ODD if (q & 1) == 1 else DIRS_EVEN
	var result: Array[Vector2i] = []
	for d in dirs:
		result.append(Vector2i(q, r) + d)
	return result

# ------------------------------------------------------------------
# Pixel conversions — authoritative axial / flat-top
# ------------------------------------------------------------------
## Axial (q,r) -> world pixel (hex center)
static func hex_to_pixel(q: int, r: int) -> Vector2:
	var x: float = float(q * COL_STEP)
	var y: float = float(r * ROW_STEP + q * ODD_Q_Y_OFFSET)
	return Vector2(x, y)

static func axial_to_world(coord: Vector2i) -> Vector2:
	return hex_to_pixel(coord.x, coord.y)

## World pixel -> Axial (q,r)
static func world_to_axial(point: Vector2) -> Vector2i:
	var qf: float = point.x / float(COL_STEP)
	var rf: float = (point.y - qf * float(ODD_Q_Y_OFFSET)) / float(ROW_STEP)
	var sf: float = -qf - rf
	var rq: int = roundi(qf)
	var rr: int = roundi(rf)
	var rs: int = roundi(sf)
	var q_diff: float = abs(float(rq) - qf)
	var r_diff: float = abs(float(rr) - rf)
	var s_diff: float = abs(float(rs) - sf)
	if q_diff > r_diff and q_diff > s_diff:
		rq = -rr - rs
	elif r_diff > s_diff:
		rr = -rq - rs
	else:
		rs = -rq - rr
	return Vector2i(rq, rr)

static func pixel_to_hex(point: Vector2) -> Vector2i:
	return world_to_axial(point)

## Alias for axial input
static func hex_to_pixel_axial(q: int, r: int) -> Vector2:
	return hex_to_pixel(q, r)

static func pixel_to_hex_fractional(point: Vector2) -> Vector2:
	var qf: float = point.x / float(COL_STEP)
	var rf: float = (point.y - qf * float(ODD_Q_Y_OFFSET)) / float(ROW_STEP)
	return Vector2(qf, rf)

static func hex_round(frac: Vector2) -> Vector2i:
	var q: float = frac.x
	var r: float = frac.y
	var s: float = -q - r
	var rq: int = roundi(q)
	var rr: int = roundi(r)
	var rs: int = roundi(s)
	var q_diff: float = abs(float(rq) - q)
	var r_diff: float = abs(float(rr) - r)
	var s_diff: float = abs(float(rs) - s)
	if q_diff > r_diff and q_diff > s_diff:
		rq = -rr - rs
	elif r_diff > s_diff:
		rr = -rq - rs
	return Vector2i(rq, rr)

# ------------------------------------------------------------------
# Distance — offset-aware (via axial cube)
# ------------------------------------------------------------------
static func hex_distance(a: Vector2i, b: Vector2i) -> int:
	var a_ax: Vector2i = offset_to_axial(a)
	var b_ax: Vector2i = offset_to_axial(b)
	var a_s: int = -a_ax.x - a_ax.y
	var b_s: int = -b_ax.x - b_ax.y
	return maxi(maxi(absi(a_ax.x - b_ax.x), absi(a_ax.y - b_ax.y)), absi(a_s - b_s))

## Axial distance helper (when inputs already axial)
static func hex_distance_axial(a: Vector2i, b: Vector2i) -> int:
	var a_s: int = -a.x - a.y
	var b_s: int = -b.x - b.y
	return maxi(maxi(absi(a.x - b.x), absi(a.y - b.y)), absi(a_s - b_s))

# ------------------------------------------------------------------
# A* pathfinding — offset grid, parity-aware neighbors, float costs
# ------------------------------------------------------------------
static func find_path(
	grid: Dictionary, start: Vector2i, goal: Vector2i,
	can_enter_callable: Callable = Callable(),
	cost_callable: Callable = Callable()
) -> Array[Vector2i]:
	if start == goal:
		return [start]
	# A* open set as array (grid is small <300, linear scan fine)
	var open_set: Array[Vector2i] = [start]
	var came_from: Dictionary = {}
	var g_score: Dictionary = {}
	var f_score: Dictionary = {}
	var start_key: String = "%d,%d" % [start.x, start.y]
	g_score[start_key] = 0.0
	f_score[start_key] = float(hex_distance(start, goal))

	while not open_set.is_empty():
		var current: Vector2i = open_set[0]
		var current_f: float = f_score.get("%d,%d" % [current.x, current.y], 999999.0)
		for node: Vector2i in open_set:
			var node_f: float = f_score.get("%d,%d" % [node.x, node.y], 999999.0)
			if node_f < current_f:
				current = node
				current_f = node_f
		if current == goal:
			var path: Array[Vector2i] = [current]
			var cur: Vector2i = current
			while came_from.has("%d,%d" % [cur.x, cur.y]):
				cur = came_from["%d,%d" % [cur.x, cur.y]]
				path.push_front(cur)
			return path
		open_set.erase(current)
		var current_key: String = "%d,%d" % [current.x, current.y]
		var current_g: float = g_score.get(current_key, 999999.0)
		# Parity-aware neighbors
		var neighbors: Array[Vector2i] = get_all_neighbors_offset(current.x, current.y)
		for neighbor: Vector2i in neighbors:
			var nkey: String = "%d,%d" % [neighbor.x, neighbor.y]
			if not grid.has(nkey):
				continue
			if can_enter_callable.is_valid():
				var cell: Variant = grid[nkey]
				if not can_enter_callable.call(cell.terrain):
					continue
			var move_cost: float = 1.0
			if cost_callable.is_valid():
				var ncell: Variant = grid[nkey]
				move_cost = float(cost_callable.call(ncell.terrain))
			else:
				var ncell2: Variant = grid[nkey]
				move_cost = float(ncell2.get_movement_cost())
			# Clamp minimum 0.5 to avoid zero loops (road fix)
			if move_cost < 0.5:
				move_cost = 0.5
			var tentative_g: float = current_g + move_cost
			var existing_g: float = g_score.get(nkey, 999999.0)
			if tentative_g < existing_g - 0.001:
				came_from[nkey] = current
				g_score[nkey] = tentative_g
				f_score[nkey] = tentative_g + float(hex_distance(neighbor, goal))
				if neighbor not in open_set:
					open_set.append(neighbor)
	return []

static func hexes_in_range(center: Vector2i, radius: int) -> Array[Vector2i]:
	# Offset-correct: brute hex_distance check
	var results: Array[Vector2i] = []
	for q in range(center.x - radius, center.x + radius + 1):
		for r in range(center.y - radius, center.y + radius + 1):
			var cand := Vector2i(q, r)
			if hex_distance(center, cand) <= radius:
				results.append(cand)
	return results
