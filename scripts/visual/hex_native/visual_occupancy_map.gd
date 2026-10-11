class_name VisualOccupancyMap
extends RefCounted

## VisualOccupancyMap — Production Multi-Cell Footprint Reservation & Spatial Ownership Engine
## Location: res://scripts/visual/hex_native/visual_occupancy_map.gd
##
## Enforces zero-overlap logical footprint reservations for multi-cell macro features:
##   - Mountains: High peaks (5-7 cells), rough mountains (3-5 cells), ridge passes, foothills.
##   - Forests: Macro clusters (2-4 cells) across 696 forest cells (~160-260 clusters).
##   - Structures: Fortress Hulao (3 cells), Capital Luoyang (3 cells), Villages (1-3 cells).
##   - Priority 1: Pass corridors (roads through mountains) with 0% mountain encroachment.
##   - Priority 2: Unit clearance zones (spawn hexes and active positions) with 0% forest canopy encroachment.
##   - Same-family 0% overlap rule: Mountain vs Mountain = 0%, Forest vs Forest = 0%, Structure vs Structure = 0%.
##
## Bounded visual slot contract: Base (1), Transitions (0-2), Route (0-1), River (0-1),
## Macro (0-1), Structure (0-1), Decoration (0-1), Tactical (Dynamic).

# ------------------------------------------------------------------
# Canonical 6 Hex Directions (Flat-top axial clockwise: E, NE, NW, W, SW, SE)
# ------------------------------------------------------------------
const DIRECTIONS: Array[Vector2i] = [
	Vector2i(1, 0),   # 0: East
	Vector2i(1, -1),  # 1: North-East
	Vector2i(0, -1),  # 2: North-West
	Vector2i(-1, 0),  # 3: West
	Vector2i(-1, 1),  # 4: South-West
	Vector2i(0, 1)    # 5: South-East
]

# ------------------------------------------------------------------
# 9-Bit Occupancy Flags for ultra-fast bitwise queries
# ------------------------------------------------------------------
enum OccupancyFlags {
	NONE = 0,
	BASE_CLAIMED = 1 << 0,        # 1: Ground base assigned
	ROUTE_CLAIMED = 1 << 1,       # 2: Road ribbon present
	RIVER_CLAIMED = 1 << 2,       # 4: River channel present
	MOUNTAIN_CLAIMED = 1 << 3,    # 8: Part of a mountain macro
	FOREST_CLAIMED = 1 << 4,      # 16: Part of a forest macro
	STRUCTURE_CLAIMED = 1 << 5,   # 32: Part of a structure (fortress, capital, village, bridge)
	PASS_CORRIDOR = 1 << 6,       # 64: Pass corridor (protected from mountain encroachment)
	UNIT_CLEARANCE = 1 << 7,      # 128: Unit clearance zone (protected from forest canopy)
	DECORATION_CLAIMED = 1 << 8   # 256: Decorative prop placed
}

# ------------------------------------------------------------------
# Inner Class: VisualOccupancyCell
# ------------------------------------------------------------------
class VisualOccupancyCell extends RefCounted:
	var coord: Vector2i = Vector2i.ZERO
	var base_claimed: bool = false
	var route_claimed: bool = false
	var river_claimed: bool = false
	var macro_family: String = ""       # "mountain", "forest", "structure"
	var macro_id: String = ""           # e.g. "high_peak_14_-12", "forest_cluster_5", "Fortress_Hulao"
	var macro_role: String = ""         # "high_peak", "rough_mountain", "interior_macro", "village"
	var macro_anchor: Vector2i = Vector2i(-999, -999)
	var structure_id: String = ""       # e.g. "Fortress_Hulao", "Capital_Luoyang", "village_-28_0"
	var transition_count: int = 0
	var decoration_count: int = 0
	var reserved_for_unit_clearance: bool = false
	var reserved_for_pass_corridor: bool = false
	var occupancy_flags: int = OccupancyFlags.NONE

	func _init(c: Vector2i = Vector2i.ZERO) -> void:
		coord = c

	func is_free(mask: int = 0) -> bool:
		if mask == 0:
			return macro_family == "" and structure_id == ""
		return (occupancy_flags & mask) == 0

	func to_dict() -> Dictionary:
		return {
			"coord": coord,
			"base_claimed": base_claimed,
			"route_claimed": route_claimed,
			"river_claimed": river_claimed,
			"macro_family": macro_family,
			"macro_id": macro_id,
			"macro_role": macro_role,
			"macro_anchor": macro_anchor,
			"structure_id": structure_id,
			"transition_count": transition_count,
			"decoration_count": decoration_count,
			"reserved_for_unit_clearance": reserved_for_unit_clearance,
			"reserved_for_pass_corridor": reserved_for_pass_corridor,
			"occupancy_flags": occupancy_flags
		}

# ------------------------------------------------------------------
# Spatial State & Fast Indexes
# ------------------------------------------------------------------
var _cells: Dictionary = {}                # Vector2i -> VisualOccupancyCell
var _macros: Dictionary = {}               # macro_id -> Dictionary { anchor, family, role, footprint }
var _structures: Dictionary = {}           # structure_id -> Array[Vector2i]
var _pass_corridors: Dictionary = {}       # Vector2i -> bool
var _unit_clearances: Dictionary = {}      # Vector2i -> bool
var _decorations: Dictionary = {}          # Vector2i -> String

# Statistics tracking
var _stats: Dictionary = {
	"total_cells": 0,
	"base_claimed_count": 0,
	"route_claimed_count": 0,
	"river_claimed_count": 0,
	"pass_corridor_cells": 0,
	"unit_clearance_cells": 0,
	"mountain_macro_count": 0,
	"mountain_cells_claimed": 0,
	"forest_macro_count": 0,
	"forest_cells_claimed": 0,
	"structure_count": 0,
	"structure_cells_claimed": 0,
	"transition_count": 0,
	"decoration_count": 0
}

# ------------------------------------------------------------------
# Lifecycle & Initialization
# ------------------------------------------------------------------
func initialize(playable_coords: Array) -> void:
	reset()
	for item in playable_coords:
		var c: Vector2i = item if item is Vector2i else Vector2i(item.x, item.y)
		_cells[c] = VisualOccupancyCell.new(c)
	_stats["total_cells"] = _cells.size()

func reset() -> void:
	_cells.clear()
	_macros.clear()
	_structures.clear()
	_pass_corridors.clear()
	_unit_clearances.clear()
	_decorations.clear()
	for k in _stats.keys():
		_stats[k] = 0

# ------------------------------------------------------------------
# PRIORITY 1: Pass Corridor Reservation (Roads through Mountains)
# ------------------------------------------------------------------
func reserve_pass_corridors(
	road_cells: Array[Vector2i],
	mountain_cells: Dictionary,
	expand_buffer: bool = true
) -> Array[Vector2i]:
	var reserved: Array[Vector2i] = []
	var pass_candidates: Dictionary = {}

	# 1. Identify road cells traversing or bordering mountains
	for rc in road_cells:
		if not _cells.has(rc):
			continue
		var borders_mountain: bool = false
		for dir in DIRECTIONS:
			var n: Vector2i = rc + dir
			if mountain_cells.has(n) or mountain_cells.has("%d,%d" % [n.x, n.y]):
				borders_mountain = true
				break
		if borders_mountain:
			pass_candidates[rc] = true

	# 2. Add canonical strategic pass choke coordinates
	# North Watch Pass (q: 9..11, r: -22)
	for q in range(9, 12):
		var c := Vector2i(q, -22)
		if _cells.has(c): pass_candidates[c] = true
	# Dragon Gate Pass (q: 13..15, r: -5)
	for q in range(13, 16):
		var c := Vector2i(q, -5)
		if _cells.has(c): pass_candidates[c] = true
	# Southern Defile (q: 17..19, r: 14)
	for q in range(17, 20):
		var c := Vector2i(q, 14)
		if _cells.has(c): pass_candidates[c] = true

	# 3. Mark and lock pass corridors
	for c in pass_candidates.keys():
		if _cells.has(c):
			var cell: VisualOccupancyCell = _cells[c]
			cell.reserved_for_pass_corridor = true
			cell.route_claimed = true
			cell.occupancy_flags |= OccupancyFlags.PASS_CORRIDOR | OccupancyFlags.ROUTE_CLAIMED
			_pass_corridors[c] = true
			reserved.append(c)

	# 4. 1-ring choke buffer for immediate road neighbors
	if expand_buffer:
		var buffer_additions: Array[Vector2i] = []
		for c in reserved:
			for dir in DIRECTIONS:
				var n: Vector2i = c + dir
				if _cells.has(n) and not _pass_corridors.has(n):
					var cell: VisualOccupancyCell = _cells[n]
					if cell.route_claimed or road_cells.has(n):
						cell.reserved_for_pass_corridor = true
						cell.occupancy_flags |= OccupancyFlags.PASS_CORRIDOR
						_pass_corridors[n] = true
						buffer_additions.append(n)
		reserved.append_array(buffer_additions)

	_stats["pass_corridor_cells"] = _pass_corridors.size()
	return reserved

# ------------------------------------------------------------------
# PRIORITY 2: Unit Clearance Reservation (Glades & Spawn Points)
# ------------------------------------------------------------------
func reserve_unit_clearance(
	unit_cells: Array[Vector2i],
	extra_glade_cells: Array[Vector2i] = []
) -> Array[Vector2i]:
	var reserved: Array[Vector2i] = []
	var all_clearance: Array[Vector2i] = []
	all_clearance.append_array(unit_cells)
	all_clearance.append_array(extra_glade_cells)

	# Canonical forest spawn coordinates (30-40% central radius visual clearance)
	const CANONICAL_SPAWN_HEXES: Array[Vector2i] = [
		Vector2i(-26, -6), Vector2i(-24, 6), Vector2i(-26, 4),
		Vector2i(-25, 5), Vector2i(-27, 5), Vector2i(-28, 6),
		Vector2i(24, -6), Vector2i(25, -6), Vector2i(26, -6),
		Vector2i(10, -21), Vector2i(9, -22), Vector2i(8, -20)
	]
	all_clearance.append_array(CANONICAL_SPAWN_HEXES)

	for c in all_clearance:
		if _cells.has(c) and not _unit_clearances.has(c):
			var cell: VisualOccupancyCell = _cells[c]
			cell.reserved_for_unit_clearance = true
			cell.occupancy_flags |= OccupancyFlags.UNIT_CLEARANCE
			_unit_clearances[c] = true
			reserved.append(c)

	_stats["unit_clearance_cells"] = _unit_clearances.size()
	return reserved

# ------------------------------------------------------------------
# Authoritative Structure & Settlement Reservations
# ------------------------------------------------------------------
func reserve_strongholds(stronghold_footprints: Dictionary) -> void:
	for sh_id in stronghold_footprints.keys():
		var fp: Array = stronghold_footprints[sh_id]
		var typed_fp: Array[Vector2i] = []
		for h in fp:
			if h is Vector2i:
				typed_fp.append(h)
		if typed_fp.size() > 0:
			claim_structure(typed_fp[0], typed_fp, str(sh_id))

func reserve_villages(village_anchors: Array[Vector2i], cell_data: Dictionary) -> void:
	# 18 village cells -> 1-3 cells footprint each along road
	for anchor in village_anchors:
		if not _cells.has(anchor):
			continue
		var fp: Array[Vector2i] = [anchor]
		for dir in DIRECTIONS:
			var n: Vector2i = anchor + dir
			if fp.size() >= 3:
				break
			if _cells.has(n) and _cells[n].is_free() and not _cells[n].reserved_for_pass_corridor:
				var nt: int = int(cell_data.get("%d,%d" % [n.x, n.y], {}).get("terrain", -1))
				if nt == 0: # Adjacent open plains along route
					fp.append(n)
		var v_id := "village_%d_%d" % [anchor.x, anchor.y]
		claim_structure(anchor, fp, v_id)

func reserve_routes(road_cells: Array[Vector2i]) -> void:
	for c in road_cells:
		if _cells.has(c):
			var cell: VisualOccupancyCell = _cells[c]
			cell.route_claimed = true
			cell.occupancy_flags |= OccupancyFlags.ROUTE_CLAIMED
			_stats["route_claimed_count"] += 1

func reserve_rivers(river_cells: Array[Vector2i]) -> void:
	for c in river_cells:
		if _cells.has(c):
			var cell: VisualOccupancyCell = _cells[c]
			cell.river_claimed = true
			cell.occupancy_flags |= OccupancyFlags.RIVER_CLAIMED
			_stats["river_claimed_count"] += 1

# ------------------------------------------------------------------
# Macro Feature Reservations & Same-Family 0% Overlap Rule
# ------------------------------------------------------------------
func can_claim_macro(anchor: Vector2i, footprint: Array[Vector2i], family: String) -> bool:
	if footprint.is_empty():
		return false
	if not _cells.has(anchor):
		return false

	var required_flag: int = 0
	if family == "mountain":
		required_flag = OccupancyFlags.MOUNTAIN_CLAIMED
	elif family == "forest":
		required_flag = OccupancyFlags.FOREST_CLAIMED
	elif family == "structure":
		required_flag = OccupancyFlags.STRUCTURE_CLAIMED

	for c in footprint:
		if not _cells.has(c):
			return false
		var cell: VisualOccupancyCell = _cells[c]

		# 1. Same-family 0% overlap rule
		if cell.macro_family == family:
			return false
		if (cell.occupancy_flags & required_flag) != 0:
			return false

		# 2. Priority 1: Mountain vs Pass Corridor (0% encroachment)
		if family == "mountain" and cell.reserved_for_pass_corridor:
			return false

		# 3. Priority 2: Forest vs Unit Clearance (0% encroachment)
		if family == "forest" and cell.reserved_for_unit_clearance:
			return false

		# 4. Structure protection: Strongholds and villages cannot be claimed by nature
		if cell.structure_id != "" and family != "structure":
			return false

		# 5. Cross-family mutual exclusion
		if family == "mountain" and cell.macro_family == "forest":
			return false
		if family == "forest" and cell.macro_family == "mountain":
			return false

	return true

func claim_macro(
	anchor: Vector2i,
	footprint: Array[Vector2i],
	family: String,
	id: String,
	role: String = ""
) -> bool:
	if not can_claim_macro(anchor, footprint, family):
		return false

	var flag: int = 0
	if family == "mountain":
		flag = OccupancyFlags.MOUNTAIN_CLAIMED
	elif family == "forest":
		flag = OccupancyFlags.FOREST_CLAIMED
	elif family == "structure":
		flag = OccupancyFlags.STRUCTURE_CLAIMED

	for c in footprint:
		var cell: VisualOccupancyCell = _cells[c]
		cell.macro_family = family
		cell.macro_id = id
		cell.macro_role = role
		cell.macro_anchor = anchor
		cell.occupancy_flags |= flag

	_macros[id] = {
		"anchor": anchor,
		"family": family,
		"id": id,
		"role": role,
		"footprint": footprint
	}

	if family == "mountain":
		_stats["mountain_macro_count"] += 1
		_stats["mountain_cells_claimed"] += footprint.size()
	elif family == "forest":
		_stats["forest_macro_count"] += 1
		_stats["forest_cells_claimed"] += footprint.size()

	return true

func release_macro(id: String) -> bool:
	if not _macros.has(id):
		return false
	var info: Dictionary = _macros[id]
	var family: String = info["family"]
	var fp: Array = info["footprint"]

	var flag: int = 0
	if family == "mountain": flag = OccupancyFlags.MOUNTAIN_CLAIMED
	elif family == "forest": flag = OccupancyFlags.FOREST_CLAIMED
	elif family == "structure": flag = OccupancyFlags.STRUCTURE_CLAIMED

	for c in fp:
		var coord: Vector2i = c as Vector2i
		if _cells.has(coord):
			var cell: VisualOccupancyCell = _cells[coord]
			if cell.macro_id == id:
				cell.macro_family = ""
				cell.macro_id = ""
				cell.macro_role = ""
				cell.macro_anchor = Vector2i(-999, -999)
				cell.occupancy_flags &= ~flag

	_macros.erase(id)
	return true

# ------------------------------------------------------------------
# Multi-Cell Candidate Footprint Discovery Helper
# ------------------------------------------------------------------
func build_candidate_footprint(
	anchor: Vector2i,
	target_terrain: int,
	min_cells: int,
	max_cells: int,
	cell_data: Dictionary,
	valid_neighbor_predicate: Callable = Callable()
) -> Array[Vector2i]:
	if not _cells.has(anchor):
		return []

	var family := ""
	if target_terrain == 1:
		family = "mountain"
	elif target_terrain == 2:
		family = "forest"

	var footprint: Array[Vector2i] = [anchor]
	var visited: Dictionary = { anchor: true }
	var queue: Array[Vector2i] = [anchor]

	while not queue.is_empty() and footprint.size() < max_cells:
		var curr: Vector2i = queue.pop_front()
		for dir in DIRECTIONS:
			var n: Vector2i = curr + dir
			if visited.has(n) or not _cells.has(n):
				continue
			visited[n] = true

			var nkey := "%d,%d" % [n.x, n.y]
			if not cell_data.has(nkey):
				continue
			var nt: int = int(cell_data[nkey].get("terrain", -1))
			if nt != target_terrain:
				continue

			var cell: VisualOccupancyCell = _cells[n]
			# Priority conflict checks
			if family == "mountain" and cell.reserved_for_pass_corridor:
				continue
			if family == "forest" and cell.reserved_for_unit_clearance:
				continue
			if cell.macro_family != "" or cell.structure_id != "":
				continue

			if valid_neighbor_predicate.is_valid():
				if not valid_neighbor_predicate.call(n):
					continue

			footprint.append(n)
			queue.append(n)
			if footprint.size() >= max_cells:
				break

	if footprint.size() < min_cells:
		return [] # Could not satisfy minimum footprint size

	return footprint

# ------------------------------------------------------------------
# Structure, Transition & Decoration Reservations
# ------------------------------------------------------------------
func can_claim_structure(anchor: Vector2i, footprint: Array[Vector2i]) -> bool:
	return can_claim_macro(anchor, footprint, "structure")

func claim_structure(anchor: Vector2i, footprint: Array[Vector2i], structure_id: String) -> bool:
	if not claim_macro(anchor, footprint, "structure", structure_id, "structure"):
		return false
	for c in footprint:
		_cells[c].structure_id = structure_id
	_structures[structure_id] = footprint
	_stats["structure_count"] += 1
	_stats["structure_cells_claimed"] += footprint.size()
	return true

func can_claim_transition(coord: Vector2i, max_transitions: int = 2) -> bool:
	if not _cells.has(coord):
		return false
	return _cells[coord].transition_count < max_transitions

func claim_transition(coord: Vector2i) -> bool:
	if not can_claim_transition(coord):
		return false
	_cells[coord].transition_count += 1
	_stats["transition_count"] += 1
	return true

func can_claim_decoration(coord: Vector2i) -> bool:
	if not _cells.has(coord):
		return false
	var cell: VisualOccupancyCell = _cells[coord]
	if cell.decoration_count > 0:
		return false
	# Do not place props on active route ribbons, rivers, or strongholds
	if cell.route_claimed or cell.river_claimed or cell.structure_id != "":
		return false
	return true

func claim_decoration(coord: Vector2i, decoration_id: String = "") -> bool:
	if not can_claim_decoration(coord):
		return false
	var cell: VisualOccupancyCell = _cells[coord]
	cell.decoration_count += 1
	cell.occupancy_flags |= OccupancyFlags.DECORATION_CLAIMED
	_decorations[coord] = decoration_id
	_stats["decoration_count"] += 1
	return true

func claim_base(coord: Vector2i) -> bool:
	if not _cells.has(coord):
		return false
	var cell: VisualOccupancyCell = _cells[coord]
	if cell.base_claimed:
		return false # Ground base: NEVER two base owners on one hex
	cell.base_claimed = true
	cell.occupancy_flags |= OccupancyFlags.BASE_CLAIMED
	_stats["base_claimed_count"] += 1
	return true

# ------------------------------------------------------------------
# Subsystem Query Methods
# ------------------------------------------------------------------
func get_cell(coord: Vector2i) -> VisualOccupancyCell:
	return _cells.get(coord, null)

func has_cell(coord: Vector2i) -> bool:
	return _cells.has(coord)

func is_cell_free(coord: Vector2i, mask: int = 0) -> bool:
	if not _cells.has(coord):
		return false
	return _cells[coord].is_free(mask)

func is_pass_corridor(coord: Vector2i) -> bool:
	return _pass_corridors.has(coord)

func is_unit_clearance(coord: Vector2i) -> bool:
	return _unit_clearances.has(coord)

func get_macro_family(coord: Vector2i) -> String:
	var cell: VisualOccupancyCell = _cells.get(coord, null)
	return cell.macro_family if cell else ""

func get_macro_id(coord: Vector2i) -> String:
	var cell: VisualOccupancyCell = _cells.get(coord, null)
	return cell.macro_id if cell else ""

func get_macro_anchor(coord: Vector2i) -> Vector2i:
	var cell: VisualOccupancyCell = _cells.get(coord, null)
	return cell.macro_anchor if cell else Vector2i(-999, -999)

func get_footprint_for_macro(id: String) -> Array[Vector2i]:
	if _macros.has(id):
		var fp: Array = _macros[id]["footprint"]
		var typed_fp: Array[Vector2i] = []
		for c in fp: typed_fp.append(c as Vector2i)
		return typed_fp
	return []

func get_footprint_for_structure(id: String) -> Array[Vector2i]:
	return _structures.get(id, [])

# ------------------------------------------------------------------
# Descriptors Synchronization
# ------------------------------------------------------------------
func sync_to_descriptor(desc: RefCounted) -> void:
	if desc == null:
		return
	var coord: Vector2i = desc.get("coord") if desc.get("coord") != null else Vector2i(-999, -999)
	if not _cells.has(coord):
		return
	var cell: VisualOccupancyCell = _cells[coord]
	desc.set("unit_clearance_required", cell.reserved_for_unit_clearance)
	desc.set("pass_corridor", cell.reserved_for_pass_corridor)
	desc.set("occupancy_flags", cell.occupancy_flags)
	if cell.macro_id != "":
		desc.set("macro_feature_id", cell.macro_id)

func sync_all_to_descriptors(descriptors: Dictionary) -> void:
	for coord in descriptors.keys():
		var desc: RefCounted = descriptors[coord] as RefCounted
		sync_to_descriptor(desc)

# ------------------------------------------------------------------
# Validation & Diagnostic Audit
# ------------------------------------------------------------------
func validate_zero_overlap() -> Dictionary:
	var violations: Array[Dictionary] = []
	var mountain_claimed: Dictionary = {}
	var forest_claimed: Dictionary = {}
	var structure_claimed: Dictionary = {}

	for id in _macros.keys():
		var macro_info: Dictionary = _macros[id]
		var family: String = macro_info["family"]
		var fp: Array = macro_info["footprint"]

		for c in fp:
			var coord: Vector2i = c as Vector2i

			# Check Mountain invariants
			if family == "mountain":
				if mountain_claimed.has(coord):
					violations.append({
						"type": "MOUNTAIN_VS_MOUNTAIN_OVERLAP",
						"cell": coord,
						"macro_a": mountain_claimed[coord],
						"macro_b": id
					})
				else:
					mountain_claimed[coord] = id

				if _pass_corridors.has(coord):
					violations.append({
						"type": "MOUNTAIN_ENCROACHMENT_PASS_CORRIDOR",
						"cell": coord,
						"macro": id
					})

			# Check Forest invariants
			elif family == "forest":
				if forest_claimed.has(coord):
					violations.append({
						"type": "FOREST_VS_FOREST_OVERLAP",
						"cell": coord,
						"macro_a": forest_claimed[coord],
						"macro_b": id
					})
				else:
					forest_claimed[coord] = id

				if _unit_clearances.has(coord):
					violations.append({
						"type": "FOREST_ENCROACHMENT_UNIT_CLEARANCE",
						"cell": coord,
						"macro": id
					})

	# Check Structure invariants
	for sh_id in _structures.keys():
		var fp: Array = _structures[sh_id]
		for c in fp:
			var coord: Vector2i = c as Vector2i
			if structure_claimed.has(coord):
				violations.append({
					"type": "STRUCTURE_VS_STRUCTURE_OVERLAP",
					"cell": coord,
					"struct_a": structure_claimed[coord],
					"struct_b": sh_id
				})
			else:
				structure_claimed[coord] = sh_id

	return {
		"valid": violations.is_empty(),
		"violation_count": violations.size(),
		"violations": violations
	}

func get_statistics() -> Dictionary:
	return _stats.duplicate()
