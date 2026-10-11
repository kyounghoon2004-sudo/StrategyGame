class_name HexRiverAutotiler
extends RefCounted

## HexRiverAutotiler — PHASE I. Topology-driven river classification + channel geometry.
## RiverRole ints match HexVisualDescriptor.RiverRole:
## 0 NONE, 1 STRAIGHT, 2 BEND, 3 CONFLUENCE, 4 FORD, 5 BRIDGE_CROSSING.
## River width: 28-42% of hex flat width (48px -> half-width ~8).

const EDGE_MIDPOINTS: Array[Vector2] = [
	Vector2(18.0, 10.5), Vector2(18.0, -10.5), Vector2(0.0, -21.0),
	Vector2(-18.0, -10.5), Vector2(-18.0, 10.5), Vector2(0.0, 21.0),
]
const RIVER_HALF_WIDTH: float = 8.0
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

## Classify one descriptor. Road overlap -> bridge crossing; shallow flag -> ford.
static func river_role_for(d) -> int:
	if not bool(d.river_present):
		return 0
	if bool(d.road_present):
		return 5
	var mask: int = int(d.river_neighbor_mask)
	var n: int = count_bits(mask)
	if n >= 3:
		return 3
	if n == 2:
		var dirs: Array[int] = active_dirs(mask)
		if OPPOSITE[dirs[0]] == dirs[1]:
			return 1
		return 2
	if n == 1:
		return 2
	# isolated water cell: ford-like still water
	return 4

## Build per-cell water channel polygons. One polygon per river cell.
static func build_channels(descriptors: Dictionary) -> Array:
	var out: Array = []
	for coord in descriptors.keys():
		var d = descriptors[coord]
		if int(d.river_role) == 0:
			continue
		var center: Vector2 = d.world_pos
		var dirs: Array[int] = active_dirs(int(d.river_neighbor_mask))
		# A river cell owns one channel junction plus one contained edge stub
		# per connected side. Independent polygons keep bends/forks clean and
		# guarantee exact edge-to-edge continuation without a self-crossing fan.
		out.append({"coord": coord, "role": int(d.river_role), "poly": _disc(center, RIVER_HALF_WIDTH * 0.96)})
		for dd in dirs:
			var e: Vector2 = center + EDGE_MIDPOINTS[dd]
			out.append({"coord": coord, "role": int(d.river_role), "poly": _stub(center, e)})
	return out

static func _stub(a: Vector2, b: Vector2) -> PackedVector2Array:
	var d: Vector2 = (b - a)
	if d.length() < 0.001:
		return PackedVector2Array([a])
	var n: Vector2 = Vector2(-d.y, d.x).normalized() * RIVER_HALF_WIDTH
	return PackedVector2Array([a + n, b + n, b - n, a - n])

static func _strip(e1: Vector2, c: Vector2, e2: Vector2) -> PackedVector2Array:
	var out := PackedVector2Array()
	out.append_array(_stub(c, e1))
	out.append_array(_stub(c, e2))
	out.append(c)
	return out

static func _disc(c: Vector2, r: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in range(10):
		var a: float = TAU * float(i) / 10.0
		pts.append(c + Vector2(cos(a), sin(a)) * r)
	return pts
