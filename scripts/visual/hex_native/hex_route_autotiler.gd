class_name HexRouteAutotiler
extends RefCounted

## HexRouteAutotiler — PHASE H. Topology-driven road classification + ribbon geometry.
## RouteRole ints match HexVisualDescriptor.RouteRole:
## 0 NONE, 1 DEAD_END, 2 STRAIGHT, 3 BEND_SHARP, 4 BEND_WIDE,
## 5 FORK_3, 6 JUNCTION_4_PLUS, 7 PASS_APPROACH, 8 BRIDGE_APPROACH.
## Road width: 18-26% of hex flat width (48px -> ~10px half-width 5).

const EDGE_MIDPOINTS: Array[Vector2] = [
	Vector2(18.0, 10.5), Vector2(18.0, -10.5), Vector2(0.0, -21.0),
	Vector2(-18.0, -10.5), Vector2(-18.0, 10.5), Vector2(0.0, 21.0),
]
const ROAD_HALF_WIDTH: float = 5.0
const OPPOSITE: Array[int] = [3, 4, 5, 0, 1, 2]

static func count_bits(mask: int) -> int:
	var c: int = 0
	for i in range(6):
		if (mask & (1 << i)) != 0:
			c += 1
	return c

static func active_dirs(mask: int) -> Array[int]:
	var out: Array[int] = []
	for i in range(6):
		if (mask & (1 << i)) != 0:
			out.append(i)
	return out

## Classify one descriptor. Bridge flag when road cell touches river channel.
static func route_role_for(d) -> int:
	if not bool(d.road_present):
		return 0
	if bool(d.pass_corridor):
		return 7
	var mask: int = int(d.road_neighbor_mask)
	# Bridge approach: road cell adjacent to river water
	if int(d.river_neighbor_mask) != 0 or bool(d.river_present):
		var rm: int = int(d.river_neighbor_mask)
		if rm != 0 or bool(d.river_present):
			# only when road actually crosses water adjacency
			pass
	if bool(d.river_present) and mask != 0:
		return 8
	var n: int = count_bits(mask)
	if n <= 0:
		return 0
	if n == 1:
		return 1
	if n == 2:
		var dirs: Array[int] = active_dirs(mask)
		var a: int = dirs[0]
		var b: int = dirs[1]
		if OPPOSITE[a] == b:
			return 2
		var diff: int = absi(a - b)
		diff = mini(diff, 6 - diff)
		if diff == 1:
			return 3
		return 4
	if n == 3:
		return 5
	return 6

## Build per-cell road ribbon polygons (center -> connected edge midpoints).
## Returns Array of Dictionaries {coord, role, poly: PackedVector2Array}.
static func build_ribbons(descriptors: Dictionary) -> Array:
	var out: Array = []
	for coord in descriptors.keys():
		var d = descriptors[coord]
		if int(d.route_role) == 0:
			continue
		var center: Vector2 = d.world_pos
		var dirs: Array[int] = active_dirs(int(d.road_neighbor_mask))
		if dirs.is_empty():
			continue
		# Every road cell is one local corridor owner. A small rounded junction
		# and independent edge stubs avoid self-intersecting ribbon polygons at
		# bends/forks while preserving exact edge topology.
		out.append({"coord": coord, "role": int(d.route_role), "poly": _junction(center)})
		for dd in dirs:
			var e: Vector2 = center + EDGE_MIDPOINTS[dd]
			out.append({"coord": coord, "role": int(d.route_role), "poly": _stub(center, e)})
	return out

static func _stub(a: Vector2, b: Vector2) -> PackedVector2Array:
	var d: Vector2 = (b - a)
	if d.length() < 0.001:
		return PackedVector2Array([a])
	var n: Vector2 = Vector2(-d.y, d.x).normalized() * ROAD_HALF_WIDTH
	return PackedVector2Array([a + n, b + n, b - n, a - n])

static func _strip(e1: Vector2, c: Vector2, e2: Vector2) -> PackedVector2Array:
	var p1: PackedVector2Array = _stub(c, e1)
	var p2: PackedVector2Array = _stub(c, e2)
	# mitered join: union as single fan around center
	var out := PackedVector2Array()
	out.append_array(p1)
	out.append_array(p2)
	out.append(c)
	return out

static func _junction(c: Vector2) -> PackedVector2Array:
	var pts := PackedVector2Array()
	var r: float = ROAD_HALF_WIDTH * 1.6
	for i in range(8):
		var a: float = TAU * float(i) / 8.0
		pts.append(c + Vector2(cos(a), sin(a)) * r)
	return pts
