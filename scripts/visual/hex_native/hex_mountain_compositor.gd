class_name HexMountainCompositor
extends RefCounted

## HexMountainCompositor — per-cell mountain grammar.
## A massif is assembled from one contained role contribution per mountain
## hex. The old multi-cell billboard placement path is intentionally retired.

const DIRECTIONS: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(1, -1), Vector2i(0, -1),
	Vector2i(-1, 0), Vector2i(-1, 1), Vector2i(0, 1),
]
const LayerCls = preload("res://scripts/visual/hex_native/approved_owned_terrain_layer.gd")
const PresentationOrientationCls = preload("res://scripts/core/presentation_orientation.gd")
const DressingCls = preload("res://scripts/visual/hex_native/hex_dressing_compositor.gd")
const QuadLayerScript = preload("res://scripts/visual/hex_native/hex_quad_layer.gd")
## Terrain language v2 (canonical battlefield QA): in the perspective (HIGH)
## presentation mountains are small house-style relief cards from ONE atlas,
## drawn as ONE MultiMesh through the shared upright billboard material, so
## they stand at their natural aspect (pitch, stretch and lean from the same
## per-vertex maths as the trees). The SF3D diorama sprites drew as squashed,
## sheared slabs there. FLAT presentation keeps the approved layer.
const RELIEF_PNG := "res://assets/terrain/relief_v1/relief_atlas.png"
const RELIEF_JSON := "res://assets/terrain/relief_v1/relief_atlas.json"
const RELIEF_BY_ROLE := {1: ["peak_0", "peak_1", "peak_2"], 2: ["twin_0", "twin_1", "peak_1"], 3: ["ridge_0", "ridge_1", "ridge_2"], 4: ["knoll_0", "ridge_1", "knoll_1"], 5: ["knoll_0", "knoll_1"], 6: ["crag_0", "crag_1"], 7: ["crag_1", "crag_0"], 8: ["ridge_2", "ridge_0"]}
static var _relief_tex: Texture2D = null
static var _relief_meta: Dictionary = {}

static func _hash2(q: int, r: int, salt: int) -> int:
	return absi((q * 73856093) ^ (r * 19349663) ^ (salt * 83492791))

static func _bitcount(mask: int) -> int:
	var count: int = 0
	for i in range(6):
		if (mask & (1 << i)) != 0:
			count += 1
	return count

static func _has_opposite(mask: int) -> bool:
	for i in range(3):
		if (mask & (1 << i)) != 0 and (mask & (1 << (i + 3))) != 0:
			return true
	return false

static func _adjacent_to_pass(coord: Vector2i, descriptors: Dictionary) -> bool:
	if descriptors.has(coord) and bool(descriptors[coord].pass_corridor):
		return true
	for direction in DIRECTIONS:
		var neighbor: Vector2i = coord + direction
		if descriptors.has(neighbor) and bool(descriptors[neighbor].pass_corridor):
			return true
	return false

static func _role_for(coord: Vector2i, d, descriptors: Dictionary) -> int:
	# Role IDs are presentation-only: 1 peak, 2 upper ridge, 3 shoulder,
	# 4 foothill, 5 scree, 6 pass wall, 7 cliff lip, 8 broken rock.
	if _adjacent_to_pass(coord, descriptors) or int(d.road_neighbor_mask) != 0:
		return 6
	var neighbors: int = _bitcount(int(d.mountain_neighbor_mask))
	var hash_value: int = _hash2(coord.x, coord.y, 211)
	if int(d.component_edge_depth) >= 2 and hash_value % 5 == 0:
		return 1
	if neighbors >= 4:
		return 2
	if _has_opposite(int(d.mountain_neighbor_mask)):
		return 3
	if neighbors <= 1:
		return 5 if hash_value % 3 == 0 else 4
	if hash_value % 4 == 0:
		return 7
	return 4

## Returns one descriptor-backed role entry for every mountain cell.
## `footprint` remains a one-item array for compatibility with reports and
## occupancy diagnostics; it is no longer used for visual scaling or spill.
static func plan_macros(descriptors: Dictionary, occupancy, _cell_data: Dictionary) -> Array:
	var entries: Array = []
	var cells: Array[Vector2i] = []
	for coord in descriptors.keys():
		if int(descriptors[coord].terrain_type) == 1:
			cells.append(coord)
	cells.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		if a.x != b.x:
			return a.x < b.x
		return a.y < b.y
	)

	var sequence: int = 0
	for coord in cells:
		var d = descriptors[coord]
		var role: int = _role_for(coord, d, descriptors)
		var id: String = "mountain_cell_%d_%d_%d" % [coord.x, coord.y, sequence]
		sequence += 1
		var footprint: Array[Vector2i] = [coord]
		# Keep the occupancy record truthful without making it responsible for
		# drawing. A blocked reservation must not erase the owning terrain cell.
		if occupancy != null and occupancy.can_claim_macro(coord, footprint, "mountain"):
			occupancy.claim_macro(coord, footprint, "mountain", id, _role_name(role))
		d.macro_feature_role = role
		d.macro_feature_id = id
		d.macro_anchor = coord
		entries.append({"id": id, "anchor": coord, "role": role, "footprint": footprint})
	return entries

static func build_nodes(entries: Array, descriptors: Dictionary) -> Array[Node2D]:
	var nodes: Array[Node2D] = []
	if entries.is_empty():
		return nodes
	if PresentationOrientationCls.perspective_active and _load_relief():
		nodes.append(_relief_layer(entries, descriptors))
		return nodes
	var layer: Node2D = LayerCls.new()
	layer.name = "MountainOwnedCells"
	layer.z_index = 4
	layer.call("configure", 0, entries, descriptors)
	nodes.append(layer)
	return nodes

static func _load_relief() -> bool:
	if _relief_tex != null and not _relief_meta.is_empty():
		return true
	if not ResourceLoader.exists(RELIEF_PNG):
		return false
	_relief_tex = load(RELIEF_PNG) as Texture2D
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(RELIEF_JSON))
	_relief_meta = parsed if parsed is Dictionary else {}
	return _relief_tex != null and not _relief_meta.is_empty()

static func _relief_info(name: String) -> Dictionary:
	var sp: Dictionary = _relief_meta["sprites"][name]
	var reg: Array = sp["region"]
	var asz := Vector2(float(_relief_meta["size"][0]), float(_relief_meta["size"][1]))
	return {
		"world_size": Vector2(float(sp["world_size"][0]), float(sp["world_size"][1])),
		"region_uv": Color(float(reg[0]) / asz.x, float(reg[1]) / asz.y, float(reg[2]) / asz.x, float(reg[3]) / asz.y),
	}

## One relief card per mountain hex, standing on the hex (contact just below
## the centre on screen, card <= 40 px wide: one hex, never a neighbour's).
static func _relief_layer(entries: Array, descriptors: Dictionary) -> Node2D:
	var items: Array = []
	for entry in entries:
		var coord: Vector2i = entry.anchor
		var d = descriptors[coord]
		var names: Array = RELIEF_BY_ROLE.get(int(entry.role), RELIEF_BY_ROLE[8])
		var h: int = _hash2(coord.x, coord.y, 57)
		var name: String = str(names[h % names.size()])
		var anchor: Vector2 = d.world_pos + PresentationOrientationCls.upright_vector(Vector2(0.0, 7.0), 1.0)
		items.append({"name": name, "info": _relief_info(name), "anchor": anchor, "scale": 1.0,
			"flip": (h / 7) % 2 == 1, "owner": coord, "depth": PresentationOrientationCls.screen_depth(anchor)})
	items.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["depth"] < b["depth"])
	var mi: MultiMeshInstance2D = QuadLayerScript.new()
	mi.name = "MountainRelief"
	mi.z_index = 4
	mi.texture = _relief_tex
	mi.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	mi.material = DressingCls.billboard_material(true)
	mi.set_meta("presentation_only", true)
	mi.set_meta("approved_resource", RELIEF_PNG)
	mi.call("configure", items, true, descriptors)
	return mi

static func _role_name(role: int) -> String:
	match role:
		1:
			return "peak_cell"
		2:
			return "upper_ridge_cell"
		3:
			return "ridge_shoulder_cell"
		4:
			return "foothill_cell"
		5:
			return "scree_cell"
		6:
			return "pass_wall_cell"
		7:
			return "cliff_lip_cell"
		_:
			return "broken_rock_cell"
