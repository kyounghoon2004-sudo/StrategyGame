extends Node3D

## HC01 presentation dressing. Every placement reads the live battlefield's
## terrain or stronghold anchors; the children have no collision or authority.
const Lib = preload("res://scripts/visual/map_composition_v0/map_composition_library.gd")
const HexUtils = preload("res://scripts/core/hex_utils.gd")
const HEX_SCALE := 4.5 / 24.0
const RADIUS := 40

var _placed: Array[Dictionary] = []
var _counts: Dictionary = {}
var _last_focus := Vector2.INF

func setup(shell: Node, terrain: PackedInt32Array, grid_n: int, outer_r: int) -> void:
	name = "HC01_SourceGLBDressing"
	var cells: Dictionary = shell.get("hex_grid").get("cell_data")
	var units: Array = shell.get("unit_renderer").call("get_all_units")
	var occupied: Dictionary = {}
	for unit in units:
		occupied[Vector2i(int(unit.get("q", 0)), int(unit.get("r", 0)))] = true
	for q in range(-RADIUS, RADIUS + 1):
		for r in range(-RADIUS, RADIUS + 1):
			if (absi(q) + absi(r) + absi(q + r)) / 2 > RADIUS:
				continue
			var cell: Variant = cells.get("%d,%d" % [q, r])
			if cell == null:
				continue
			var t: int = int(cell.terrain)
			var h: int = posmod(q * 73856093 ^ r * 19349663, 997)
			match t:
				2: # Forest: spaced real tree models form readable groves.
					if h % 7 == 0 and not occupied.has(Vector2i(q, r)):
						var tree: String = ["compact_pine", "tall_pine", "broadleaf", "wind_pine", "cypress"][h % 5]
						_add(tree, q, r, 1.65, float(h % 360), Vector2(0.0, 1.3), 0.0)
				1: # Continuous ridge from separated GLB masses; pass cells stay clear.
					if h % 8 == 0 and not occupied.has(Vector2i(q, r)):
						var rock: String = ["low_foothill", "long_ridge", "sharp_peak", "vegetated_mountain"][h % 4]
						_add(rock, q, r, 4.8, float(h % 360), Vector2(0.0, 0.8), 0.0)
				5: # Small settlements preserve open courtyards for unit cards.
					_add("medium_house" if h % 2 == 0 else "hall", q, r, 2.45, float(h % 360), Vector2(-1.6, 1.2), 0.0)
					_add("small_house" if h % 2 == 0 else "granary", q, r, 1.55, float((h + 93) % 360), Vector2(1.7, 1.1), 0.0)
					_add_tile("tile_cultivated_edge", q, r)
				6: # Both authored bridges use the supplied crossing surface.
					if _has_water_neighbor(q, r, cells):
						_add_tile("tile_worn_crossing", q, r)
				0: # A few cultivated farms follow the settled corridor.
					if h % 41 == 0 and _near_village(q, r, cells) and not occupied.has(Vector2i(q, r)):
						_add("dry_field" if h % 2 == 0 else "terraced_field", q, r, 3.25, float(h % 360), Vector2.ZERO, 0.0)
						_add_tile("tile_cultivated_edge", q, r)
	for spec in shell.call("stronghold_visual_specs"):
		var anchor: Vector2i = spec["anchor"]
		_add("hill_fort" if int(spec["role"]) == 1 else "stronghold", anchor.x, anchor.y, 3.35, 0.0, Vector2(0.0, 1.05), 0.0)
		_add_tile("tile_rocky_ground", anchor.x, anchor.y)
	var sun := DirectionalLight3D.new()
	sun.name = "HC01_GLB_Sun"
	sun.rotation_degrees = Vector3(-50.0, -30.0, 0.0)
	sun.light_energy = 1.1
	sun.shadow_enabled = false
	add_child(sun)
	print("[HC01 GLB] placements=%d by_key=%s" % [_placed.size(), JSON.stringify(_counts)])

func _center(q: int, r: int) -> Vector3:
	var px: Vector2 = HexUtils.hex_to_pixel(q, r) * HEX_SCALE
	return Vector3(px.x, 0.0, px.y)

func _add(key: String, q: int, r: int, radius: float, yaw: float, offset: Vector2, y: float) -> void:
	var b: Dictionary = Lib.bounds(key)
	var scale_factor: float = radius / maxf(0.1, float(b["circ_r"]))
	var wrap := Node3D.new()
	wrap.name = "GLB_%s_%d_%d" % [key, q, r]
	wrap.position = _center(q, r) + Vector3(offset.x, y, offset.y)
	wrap.rotation.y = deg_to_rad(yaw)
	wrap.scale = Vector3.ONE * scale_factor
	wrap.add_child(Lib.instance_grounded(key))
	add_child(wrap)
	_track(wrap, q, r, key)

func _add_tile(key: String, q: int, r: int) -> void:
	var b: Dictionary = Lib.bounds(key)
	var half: Vector2 = b["half_xz"]
	var wrap := Node3D.new()
	wrap.name = "GLB_%s_%d_%d" % [key, q, r]
	wrap.position = _center(q, r) + Vector3(0.0, -0.055, 0.0)
	wrap.scale = Vector3(4.5 / maxf(0.1, half.x), 0.16, 3.94 / maxf(0.1, half.y))
	wrap.add_child(Lib.instance_centered(key))
	add_child(wrap)
	_track(wrap, q, r, key)

func _track(node: Node3D, q: int, r: int, key: String) -> void:
	_placed.append({"node": node, "q": q, "r": r})
	_counts[key] = int(_counts.get(key, 0)) + 1

func _has_water_neighbor(q: int, r: int, cells: Dictionary) -> bool:
	for n in [Vector2i(1, 0), Vector2i(1, -1), Vector2i(0, -1), Vector2i(-1, 0), Vector2i(-1, 1), Vector2i(0, 1)]:
		var c: Variant = cells.get("%d,%d" % [q + n.x, r + n.y])
		if c != null and int(c.terrain) == 7:
			return true
	return false

func _near_village(q: int, r: int, cells: Dictionary) -> bool:
	for dq in range(-3, 4):
		for dr in range(-3, 4):
			if (absi(dq) + absi(dr) + absi(dq + dr)) / 2 > 3:
				continue
			var c: Variant = cells.get("%d,%d" % [q + dq, r + dr])
			if c != null and int(c.terrain) == 5:
				return true
	return false

## Same live fog authority as the closeup ground and unit cards. Unexplored
## geography never reveals a model; remembered terrain stays visible as map
## knowledge, and the closeup horizon culls distant models.
func sync_visibility(fog: Variant, focus: Vector2, horizon: float) -> void:
	if focus == _last_focus and fog == null:
		return
	_last_focus = focus
	for item in _placed:
		var node: Node3D = item["node"]
		var known: bool = fog == null or int(fog.call("get_fog_state", int(item["q"]), int(item["r"]))) > 0
		var p := Vector2(node.position.x, node.position.z)
		node.visible = known and p.distance_to(focus) < horizon
