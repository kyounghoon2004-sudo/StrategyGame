class_name HexVisualDescriptor
extends RefCounted

## HexVisualDescriptor — Authoritative Presentation Unit for a Single Hex Cell.
## Represents one of the 4,921 playable cells on the radius-40 flat-top axial battlefield.
## Stores copied gameplay context, cached 6-bit topology neighbor masks, component metadata,
## bounded visual slot roles, and layout constraint flags.
## Visual presentation derives strictly from this descriptor; gameplay truth is never mutated.

# ==============================================================================
# ENUMS — BOUNDED VISUAL SLOTS & ROLES
# ==============================================================================

## Slot 1: Base Terrain Role (Exactly 1 per cell, 0 decal stacking)
enum BaseRole {
	PLAIN_PARCHMENT = 0,    # Neutral parchment earth ground
	PLAIN_LOESS = 1,        # Northern dry loess soil
	PLAIN_FADED_GRASS = 2,  # Southern faded grass plains
	PLAIN_WORN = 3,         # High-traffic battlefield ground around strongholds/camps
	LOWLAND_GREEN = 4,      # Lowland green, wetlands, marsh margins, river verges
	FOOTHILL_GROUND = 5,    # Ground bordering mountain foothills
	PASS_FLOOR = 6,         # Compacted gravel/earth floor through mountain passes
	MARSH_GROUND = 7,       # Saturated wetland / marsh
	RIVER_CHANNEL = 8,      # Riverbed channel under water surface
	MOUNTAIN_GROUND = 9     # Rock ground under mountain relief (terrain language v2)
}

## Slot 2: Edge Transition Role (0..2 per cell, directional boundary only)
enum TransitionRole {
	NONE = 0,
	FOOTHILL_SKIRT_ROCKY = 1, # Rocky foothill skirt bordering plains
	FOOTHILL_SCREE = 2,       # Scree and loose gravel wash
	MOUNTAIN_BASE_RUBBLE = 3, # Heavy mountain base rubble
	PASS_ENTRANCE_RUBBLE = 4, # Debris framing mountain pass mouth
	PINE_SKIRT_MOUNTAINSIDE = 5, # Pine skirt where mountain meets forest
	CLIFF_FOOT_DEBRIS = 6,    # Cliff foot gravel deposit
	RIDGE_FOOT_TRANSITION = 7 # Ridge base grounding transition
}

## Slot 3: Route Role (0..1 per cell, topology-derived)
enum RouteRole {
	NONE = 0,
	DEAD_END = 1,        # 1 connected neighbor
	STRAIGHT = 2,        # 2 opposite neighbors (e.g. E-W, NE-SW, NW-SE)
	BEND_SHARP = 3,      # 2 neighbors separated by 60 degrees (adjacent)
	BEND_WIDE = 4,       # 2 neighbors separated by 120 degrees
	FORK_3 = 5,          # 3 connected neighbors (T or Y junction)
	JUNCTION_4_PLUS = 6, # 4 or more connected neighbors
	PASS_APPROACH = 7,   # Road traversing mountain pass corridor
	BRIDGE_APPROACH = 8  # Road ribbon terminating cleanly into bridgehead
}

## Slot 4: River Role (0..1 per cell, topology-derived)
enum RiverRole {
	NONE = 0,
	STRAIGHT = 1,        # Continuous straight water channel
	BEND = 2,            # Continuous bending water channel
	CONFLUENCE = 3,      # 3+ incoming river branches
	FORD = 4,            # Shallow fordable river crossing
	BRIDGE_CROSSING = 5  # River channel spanned by a bridge structure
}

## Slot 5: Macro Feature Role (0..1 owner per cell, 0% same-family overlap)
enum MacroFeatureRole {
	NONE = 0,
	# Mountain Family
	HIGH_PEAK = 1,       # Major 5-7 cell mountain massif anchor
	ROUGH_SHOULDER = 2,  # 3-5 cell rough mountain shoulder
	RIDGE_PASS = 3,      # Pass-framing ridge mass
	LOW_FOOTHILL = 4,    # Outer 2-3 cell low foothill
	# Forest Family
	FOREST_ISOLATED = 5, # Small isolated copse (1-2 cells)
	FOREST_EDGE = 6,     # Outer perimeter woodland
	FOREST_INTERIOR = 7, # Deep interior mixed woodland (3-4 cell cluster)
	FOREST_ROADSIDE = 8, # Thinned roadside forest corridor
	FOREST_FOOTHILL = 9, # Foothill pine cluster
	FOREST_BAMBOO = 10,  # Bamboo grove near river/wetland
	FOREST_GLADE = 11    # Unit spawn glade (visual clearance preserved)
}

## Slot 6: Structure Role (0..1 owner per cell)
enum StructureRole {
	NONE = 0,
	STRONGHOLD_FORTRESS = 1, # Fortress Hulao 3-cell footprint
	STRONGHOLD_CAPITAL = 2,  # Capital Luoyang 3-cell footprint
	VILLAGE_HAMLET = 3,      # Rural settlement / hamlet cluster
	BRIDGE = 4               # Timber / stone bridge structure
}

## Slot 7: Decoration Role (Sparse budget: ~1 per 8-16 cells)
enum DecorationRole {
	NONE = 0,
	ROADSIDE_CAIRN = 1,   # Roadside cairn / marker
	MARKER_STONE = 2,     # Boundary marker stone
	BOULDER_CLUSTER = 3,  # Foothill boulder grouping
	STONE_OUTCROP = 4,    # Plains rock outcrop
	SCRUB_DRY_BUSH = 5    # Arid scrub / dry bush
}

## Slot 8: Occupancy & Constraint Bitflags
enum OccupancyFlags {
	NONE = 0,
	BASE_CLAIMED = 1 << 0,
	ROUTE_CLAIMED = 1 << 1,
	RIVER_CLAIMED = 1 << 2,
	MOUNTAIN_CLAIMED = 1 << 3,
	FOREST_CLAIMED = 1 << 4,
	STRUCTURE_CLAIMED = 1 << 5,
	PASS_CORRIDOR = 1 << 6,
	UNIT_CLEARANCE_REQUIRED = 1 << 7,
	DECORATION_CLAIMED = 1 << 8
}

# ==============================================================================
# PROPERTIES
# ==============================================================================

# Spatial Identification
var coord: Vector2i = Vector2i.ZERO
var world_pos: Vector2 = Vector2.ZERO

# Authoritative Context Copied From Gameplay Truth
var terrain_type: int = 0
var road_present: bool = false
var river_present: bool = false
var stronghold_present: bool = false
var unit_present: bool = false
var fog_state: int = 0 # 0=UNEXPLORED, 1=EXPLORED, 2=VISIBLE

# 5 Cached 6-Bit Topology Neighbor Masks (Bits 0..5 = E, NE, NW, W, SW, SE)
var road_neighbor_mask: int = 0
var river_neighbor_mask: int = 0
var forest_neighbor_mask: int = 0
var mountain_neighbor_mask: int = 0
var terrain_neighbor_mask: int = 0   # 1 if neighbor differs from this cell or off-map
var terrain_boundary_mask: int = 0   # Alias for terrain_neighbor_mask
var same_terrain_neighbor_mask: int = 0 # 1 if neighbor has identical terrain_type

# Connected Component Metadata
var terrain_component_id: int = 0
var component_edge_depth: int = 0 # 0 = border, 1+ = interior

# Visual Slot Assignments
var base_role: int = BaseRole.PLAIN_PARCHMENT
var transition_roles: Array[int] = [] # Max 2-3 roles
var transition_edge_dirs: Array[int] = [] # Corresponding edge directions (0..5)
var route_role: int = RouteRole.NONE
var river_role: int = RiverRole.NONE
var macro_feature_role: int = MacroFeatureRole.NONE
var macro_feature_id: String = ""
var macro_anchor: Vector2i = Vector2i(-999, -999)
var structure_role: int = StructureRole.NONE
var structure_id: String = ""
var decoration_role: int = DecorationRole.NONE

# Layout Constraints & Flags
var unit_clearance_required: bool = false
var pass_corridor: bool = false
var occupancy_flags: int = 0

# Interactive Tactical Feedback State
var is_hovered: bool = false
var is_selected: bool = false

# ==============================================================================
# METHODS
# ==============================================================================

func _init(p_coord: Vector2i = Vector2i.ZERO) -> void:
	coord = p_coord
	# Canonical flat-top axial projection: COL_STEP = 36, ROW_STEP = 42, ODD_Q_Y_OFFSET = 21
	var px: float = float(p_coord.x * 36)
	var py: float = float(p_coord.y * 42 + p_coord.x * 21)
	world_pos = Vector2(px, py)

## Returns the canonical string key ("q,r") matching gameplay dictionaries
func get_key() -> String:
	return "%d,%d" % [coord.x, coord.y]

## Copies authoritative gameplay state into this descriptor
func copy_gameplay_state(
	p_terrain: int,
	p_is_road: bool,
	p_is_river: bool,
	p_is_stronghold: bool,
	p_is_unit: bool,
	p_fog: int
) -> void:
	terrain_type = p_terrain
	road_present = p_is_road or (p_terrain == 6)
	river_present = p_is_river or (p_terrain == 7)
	stronghold_present = p_is_stronghold or (p_terrain == 4 or p_terrain == 9 or p_terrain == 11)
	unit_present = p_is_unit
	fog_state = p_fog

## Adds an edge transition if bounded budget (max 2, rarely 3) allows
func add_transition(role: int, edge_dir: int) -> bool:
	if transition_roles.size() >= 2:
		return false
	transition_roles.append(role)
	transition_edge_dirs.append(edge_dir)
	return true

## Checks if an occupancy flag is set
func has_flag(flag: int) -> bool:
	return (occupancy_flags & flag) != 0

## Sets an occupancy flag
func set_flag(flag: int) -> void:
	occupancy_flags |= flag

## Clears an occupancy flag
func clear_flag(flag: int) -> void:
	occupancy_flags &= ~flag

## Returns a summary dictionary for debugging and test verification
func to_dict() -> Dictionary:
	return {
		"coord": coord,
		"world_pos": world_pos,
		"terrain_type": terrain_type,
		"road_mask": road_neighbor_mask,
		"river_mask": river_neighbor_mask,
		"forest_mask": forest_neighbor_mask,
		"mountain_mask": mountain_neighbor_mask,
		"boundary_mask": terrain_boundary_mask,
		"terrain_neighbor_mask": terrain_neighbor_mask,
		"same_terrain_mask": same_terrain_neighbor_mask,
		"comp_id": terrain_component_id,
		"depth": component_edge_depth,
		"base_role": base_role,
		"route_role": route_role,
		"river_role": river_role,
		"macro_role": macro_feature_role,
		"macro_id": macro_feature_id,
		"structure_role": structure_role,
		"pass_corridor": pass_corridor,
		"unit_clearance": unit_clearance_required
	}
