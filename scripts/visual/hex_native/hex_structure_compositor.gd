class_name HexStructureCompositor
extends RefCounted

## HexStructureCompositor — PHASE M/N/O/P. Bridges, strongholds, settlements,
## sparse props. All derive from authoritative gameplay locations. Footprints
## reserved before render. StructureRole: 0 NONE, 1 FORTRESS, 2 CAPITAL,
## 3 HAMLET/VILLAGE, 4 BRIDGE. Decoration budget ~1 per 8-16 cells.
##
## ONE CITY / STRONGHOLD / VILLAGE = ONE HEX (visual contract): every structure
## draws exactly one upright sprite standing inside its anchor hex. A
## multi-hex LOGICAL footprint (gameplay) stays reserved ground, never art.

const DIRECTIONS: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(1, -1), Vector2i(0, -1),
	Vector2i(-1, 0), Vector2i(-1, 1), Vector2i(0, 1),
]


const Registry = preload("res://scripts/visual/hex_native/approved_asset_registry.gd")
const PresentationOrientationCls = preload("res://scripts/core/presentation_orientation.gd")
const VisualContract = preload("res://scripts/visual/visual_contract.gd")
const Route = preload("res://scripts/visual/hex_native/hex_route_autotiler.gd")

static func _hash2(q: int, r: int, salt: int) -> int:
	return absi((q * 73856093) ^ (r * 19349663) ^ (salt * 83492791))

## Reserve + tag structure roles on descriptors. Returns plan Array.
## `stronghold_specs` comes from the shell (stronghold_visual_specs()): the one
## source of stronghold locations for both HIGH and CLOSEUP.
static func plan_structures(descriptors: Dictionary, occupancy, cell_data: Dictionary, stronghold_specs: Array = []) -> Array:
	var plan: Array = []
	# 1. strongholds (authoritative logical footprints; art on the anchor)
	for spec in stronghold_specs:
		_reserve_stronghold(descriptors, occupancy, spec["footprint"], str(spec["id"]), int(spec["role"]), plan)
	# 2. bridges: road-river crossings. Same-cell road+river first, then
	# explicit crossing edges: a road cell flanked by river on opposite
	# sides (or vice versa) is a crossing even when terrain encodes one
	# family. Presentation-only; gameplay truth untouched.
	for coord in descriptors.keys():
		var d = descriptors[coord]
		if bool(d.road_present) and bool(d.river_present):
			_tag_bridge(descriptors, occupancy, coord, plan)
	for coord in descriptors.keys():
		var d2 = descriptors[coord]
		if int(d2.structure_role) == 4:
			continue
		if (bool(d2.road_present) and _has_opposite(int(d2.river_neighbor_mask))) or (bool(d2.river_present) and _has_opposite(int(d2.road_neighbor_mask))):
			_tag_bridge(descriptors, occupancy, coord, plan)
	# 3. villages: one terrain-5 cell = one village = one hex. (The old
	# neighbour "granary" spill made a plains hex look occupied.)
	for coord in descriptors.keys():
		var d = descriptors[coord]
		if int(d.terrain_type) == 5:
			var fp: Array[Vector2i] = [coord]
			d.structure_role = 3
			d.structure_id = "village_%d_%d" % [coord.x, coord.y]
			if occupancy != null:
				_claim_simple(occupancy, coord, d.structure_id)
			plan.append({"id": d.structure_id, "anchor": coord, "role": 3, "footprint": fp})
	# 4. Sparse prop sprites are intentionally retired. They were the source of
	# repeated rock/shrub blotches that visually competed with cell ownership.
	# Structure roles remain authoritative; terrain cells now use only their
	# approved cell-owned family layer.
	return plan

static func build_nodes(plan: Array, descriptors: Dictionary) -> Array[Node2D]:
	var nodes: Array[Node2D] = []
	for item in plan:
		var anchor: Vector2i = item.anchor
		if not descriptors.has(anchor):
			continue
		var d = descriptors[anchor]
		var role: int = int(item.role)
		var group := Node2D.new()
		group.name = "Approved_" + str(item.id)
		group.z_index = 5
		group.set_meta("logical_footprint", item.footprint)
		if role in [1,2]:
			_build_fort(group, item, descriptors)
		elif role == 4:
			var path: String = Registry.path_for("fort", "timber_bridge_medium_A")
			var sp: Sprite2D = Registry.sprite(path, d.world_pos, 38.0, 20.0)
			# Horizontal source deck, rotated to the exact flat-top road edge vector.
			sp.offset = -Registry.bounds(path).size * 0.5
			sp.rotation = _bridge_angle(d)
			sp.name = "BridgeDeck"
			sp.set_meta("road_axis_radians", sp.rotation)
			group.add_child(sp)
		elif role == 3:
			var path: String = Registry.path_for("settlement", "village_cluster_" + Registry.variant(anchor))
			var village: Sprite2D = Registry.sprite(path, d.world_pos + _upright_offset(Vector2(0,12)), 34.0, 30.0)
			village.rotation = PresentationOrientationCls.upright_rotation()
			village.set_meta("upright_base_y", village.scale.y)
			village.scale.y *= PresentationOrientationCls.upright_stretch
			village.name = "Village"
			group.add_child(village)
		nodes.append(group)
	return nodes

## Friendly-side yaw: buildings stand upright about their ground contact, and
## the contact offset keeps its SCREEN meaning (below hex center). The bridge
## deck is ground-plane art and intentionally keeps rotating with the world.
## yaw 0 -> offset / rotation unchanged.
static func _upright_offset(offset: Vector2) -> Vector2:
	return PresentationOrientationCls.upright_position(offset, Vector2.ZERO)

static func _build_fort(group: Node2D, item: Dictionary, descriptors: Dictionary) -> void:
	# ONE dominant keep filling the anchor hex (VisualContract
	# STRONGHOLD_ART_WIDTH x MAX_HEIGHT; both castle stems, keep 0.809 and
	# hall 1.183 aspect, stay inside the hexagon at ground line +15). The other logical footprint cells stay open
	# ground, so the art reads as a single stronghold on a single hex at every
	# zoom (the old multi-hex "close castle" crossfade is retired).
	var anchor: Vector2i = item.anchor
	if not descriptors.has(anchor):
		return
	var pos: Vector2 = descriptors[anchor].world_pos
	var stem: String = "command_hall_A" if int(item.role) == 2 else "fortress_keep_A"
	var primary: Sprite2D = Registry.sprite(Registry.path_for("fort", stem), pos + _upright_offset(Vector2(0, 15)), VisualContract.STRONGHOLD_ART_WIDTH, VisualContract.STRONGHOLD_ART_MAX_HEIGHT)
	primary.rotation = PresentationOrientationCls.upright_rotation()
	primary.set_meta("upright_base_y", primary.scale.y)
	primary.scale.y *= PresentationOrientationCls.upright_stretch
	primary.name = "Module_%d_%d_%s" % [anchor.x, anchor.y, stem]
	group.add_child(primary)

static func _reserve_stronghold(descriptors: Dictionary, occupancy, fp: Array, sh_id: String, role: int, plan: Array) -> void:
	var typed: Array[Vector2i] = []
	for h in fp:
		typed.append(h)
	if occupancy != null:
		if occupancy.has_method("claim_structure"):
			occupancy.claim_structure(typed[0], typed, sh_id)
		else:
			_claim_simple(occupancy, typed[0], sh_id)
	for c in typed:
		if descriptors.has(c):
			descriptors[c].structure_role = role
			descriptors[c].structure_id = sh_id
	plan.append({"id": sh_id, "anchor": typed[0], "role": role, "footprint": typed})

static func _has_opposite(mask: int) -> bool:
	for i in range(3):
		if (mask & (1 << i)) != 0 and (mask & (1 << (i + 3))) != 0:
			return true
	return false

static func _tag_bridge(descriptors: Dictionary, occupancy, coord: Vector2i, plan: Array) -> void:
	var d = descriptors[coord]
	d.structure_role = 4
	d.structure_id = "bridge_%d_%d" % [coord.x, coord.y]
	var bfp: Array[Vector2i] = [coord]
	if occupancy != null and occupancy.has_method("claim_structure"):
		occupancy.claim_structure(coord, bfp, d.structure_id)
	elif occupancy != null:
		_claim_simple(occupancy, coord, d.structure_id)
	plan.append({"id": d.structure_id, "anchor": coord, "role": 4, "footprint": [coord]})

static func _claim_simple(occupancy, coord: Vector2i, sid: String) -> void:
	if occupancy == null:
		return
	if occupancy.has_method("claim_structure"):
		return
	# fallback for occupancy maps exposing _cells dict
	if "_cells" in occupancy and occupancy._cells.has(coord):
		occupancy._cells[coord].structure_id = sid

## Road topology uses actual pixel edge midpoints, not nominal 60-degree angles.
static func _bridge_angle(d) -> float:
	var mask: int = int(d.road_neighbor_mask)
	for i in range(3):
		if (mask & (1 << i)) != 0 and (mask & (1 << (i+3))) != 0:
			return Route.EDGE_MIDPOINTS[i].angle()
	for i in range(6):
		if (mask & (1 << i)) != 0:
			return Route.EDGE_MIDPOINTS[i].angle()
	return 0.0
