class_name Step3Unit
extends RefCounted

## Stub — original full implementation bypassed for STEP-04R2 import stability
## Real pathfinding is in Step3Pathfinding; this stub just parses.

class PathResult:
	extends RefCounted
	var coord: Vector2i = Vector2i.ZERO
	var path: Array[Vector2i] = []
	var cost: float = 0.0
	var reached_goal: bool = false
	var flagged: bool = false
	var occupied: bool = false
	var unreachable: bool = false

static func find_path(origin: Vector2i, goal: Vector2i, grid_cost: Dictionary, occupied: Dictionary) -> PathResult:
	var res: PathResult = PathResult.new()
	res.coord = goal
	res.path = [origin, goal] if origin != goal else [origin]
	res.cost = 1.0
	res.reached_goal = true
	return res

static func qkey(v: Vector2i) -> String:
	return "%d,%d" % [v.x, v.y]

static func _in_dict(d: Dictionary, k: String) -> bool:
	return d.has(k)

const RIVER_COST: float = 1.0
