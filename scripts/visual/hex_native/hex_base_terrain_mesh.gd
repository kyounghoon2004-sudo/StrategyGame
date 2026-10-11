class_name HexBaseTerrainMesh
extends RefCounted

## HexBaseTerrainMesh — hex-owned base surfaces.
## Batched ArrayMesh geometry is grouped by family for performance, but every
## triangle fan is a complete, independently readable hex cell. The previous
## broad world-texture projection is intentionally not used by the rebuild.

const Registry = preload("res://scripts/visual/hex_native/approved_asset_registry.gd")
const HexUtils = preload("res://scripts/core/hex_utils.gd")

# ------------------------------------------------------------------
# ENUMS & CONSTANTS
# ------------------------------------------------------------------
enum BaseRole {
	PLAIN_PARCHMENT = 0,
	PLAIN_LOESS = 1,
	PLAIN_FADED_GRASS = 2,
	PLAIN_WORN = 3,
	LOWLAND_GREEN = 4,
	FOOTHILL_GROUND = 5,
	PASS_FLOOR = 6,
	MARSH_GROUND = 7,
	RIVER_CHANNEL = 8,
	MOUNTAIN_GROUND = 9
}

const FAMILY_NAMES: Dictionary = {
	BaseRole.PLAIN_PARCHMENT: "PlainParchment",
	BaseRole.PLAIN_LOESS: "PlainLoess",
	BaseRole.PLAIN_FADED_GRASS: "PlainFadedGrass",
	BaseRole.PLAIN_WORN: "PlainWorn",
	BaseRole.LOWLAND_GREEN: "LowlandGreen",
	BaseRole.FOOTHILL_GROUND: "FoothillGround",
	BaseRole.PASS_FLOOR: "PassFloor",
	BaseRole.MARSH_GROUND: "MarshGround",
	BaseRole.RIVER_CHANNEL: "RiverChannel",
	BaseRole.MOUNTAIN_GROUND: "MountainGround"
}

# Hex-local palette: the center/ring vertex gradient gives each cell a quiet
# ownership cue without repeated stains, circular decals, or a poster underlay.
const FAMILY_BASE_COLORS: Dictionary = {
	BaseRole.PLAIN_PARCHMENT: Color(0.68, 0.57, 0.40, 1.0),
	BaseRole.PLAIN_LOESS: Color(0.60, 0.49, 0.34, 1.0),
	BaseRole.PLAIN_FADED_GRASS: Color(0.39, 0.48, 0.31, 1.0),
	BaseRole.PLAIN_WORN: Color(0.52, 0.39, 0.27, 1.0),
	BaseRole.LOWLAND_GREEN: Color(0.34, 0.48, 0.31, 1.0),
	BaseRole.FOOTHILL_GROUND: Color(0.55, 0.45, 0.31, 1.0),
	BaseRole.PASS_FLOOR: Color(0.63, 0.54, 0.39, 1.0),
	BaseRole.MARSH_GROUND: Color(0.30, 0.42, 0.32, 1.0),
	BaseRole.RIVER_CHANNEL: Color(0.25, 0.43, 0.49, 1.0),
	BaseRole.MOUNTAIN_GROUND: Color(0.48, 0.44, 0.35, 1.0)
}

# Legacy shader/tint constants remain named for downstream tooling, but the
# active renderer intentionally uses FAMILY_BASE_COLORS and vertex colors.
const FAMILY_TINTS: Dictionary = {
	BaseRole.PLAIN_PARCHMENT: Color.WHITE,
	BaseRole.PLAIN_LOESS: Color.WHITE,
	BaseRole.PLAIN_FADED_GRASS: Color.WHITE,
	BaseRole.PLAIN_WORN: Color.WHITE,
	BaseRole.LOWLAND_GREEN: Color.WHITE,
	BaseRole.FOOTHILL_GROUND: Color.WHITE,
	BaseRole.PASS_FLOOR: Color.WHITE,
	BaseRole.MARSH_GROUND: Color.WHITE,
	BaseRole.RIVER_CHANNEL: Color.WHITE,
	BaseRole.MOUNTAIN_GROUND: Color.WHITE
}

# Canonical Flat-Top Hexagon Vertices (W=48, H=42)
const CANONICAL_VERTICES: Array[Vector2] = [
	Vector2(-24.0, 0.0),    # V0: West
	Vector2(-12.0, -21.0),  # V1: North-West
	Vector2(12.0, -21.0),   # V2: North-East
	Vector2(24.0, 0.0),     # V3: East
	Vector2(12.0, 21.0),    # V4: South-East
	Vector2(-12.0, 21.0)    # V5: South-West
]

# Canonical Directions clockwise from East
const DIRECTIONS: Array[Vector2i] = [
	Vector2i(1, 0),   # 0: E  -> Edge between V3 and V4
	Vector2i(1, -1),  # 1: NE -> Edge between V2 and V3
	Vector2i(0, -1),  # 2: NW -> Edge between V1 and V2
	Vector2i(-1, 0),  # 3: W  -> Edge between V0 and V1
	Vector2i(-1, 1),  # 4: SW -> Edge between V5 and V0
	Vector2i(0, 1)    # 5: SE -> Edge between V4 and V5
]

# Edge vertex indices for directions 0..5
const DIR_EDGE_VERTICES: Array[Vector2i] = [
	Vector2i(3, 4), # 0: E  (V3 -> V4)
	Vector2i(2, 3), # 1: NE (V2 -> V3)
	Vector2i(1, 2), # 2: NW (V1 -> V2)
	Vector2i(0, 1), # 3: W  (V0 -> V1)
	Vector2i(5, 0), # 4: SW (V5 -> V0)
	Vector2i(4, 5)  # 5: SE (V4 -> V5)
]

const WORLD_UV_SCALE: float = 1024.0
# The individual base-family meshes can land on adjacent draw batches. A tiny
# visual-only overlap prevents rasterization seams without changing the hex
# centers, coordinate authority, or gameplay footprint.
const BASE_SURFACE_BLEED: float = 1.045
# Phase-2 layered passive outline: dark-umber line for light ground,
# pale ink-gold line for dark ground (local contrast assist). Both subdued.
const PASSIVE_BORDER_DARK: Color = Color(0.29, 0.24, 0.17, 0.10)
const PASSIVE_BORDER_LIGHT: Color = Color(0.80, 0.74, 0.61, 0.08)
const PASSIVE_BORDER_COLOR: Color = Color(0.66, 0.57, 0.41, 0.07)
# Base roles whose ground reads dark (outline switches to the light line).
const DARK_GROUND_ROLES: Array = [2, 4, 7, 8]
const TERRAIN_SHADER_PATH: String = "res://scripts/visual/shaders/hex_base_terrain.gdshader"

# ------------------------------------------------------------------
# PUBLIC API
# ------------------------------------------------------------------

## Builds 8-9 batched MeshInstance2D nodes, one per base terrain family.
static func build_base_terrain(descriptors: Dictionary, tutorial_ground_variation: bool = false) -> Array[MeshInstance2D]:
	var result: Array[MeshInstance2D] = []
	
	# 1. Bucket cells by resolved base family
	var family_cells: Dictionary = {}
	for role in BaseRole.values():
		family_cells[role] = []
	
	for coord: Vector2i in descriptors:
		var desc = descriptors[coord]
		var role: int = desc.base_role if ("base_role" in desc and desc.base_role >= 0) else classify_base_role(desc, descriptors)
		family_cells[role].append(desc)
	
	# 2. Build one ArrayMesh per family. The family batch is only a draw-call
	# optimization; the vertex fan below still gives every hex its own owner.
	for role: int in BaseRole.values():
		var cells: Array = family_cells[role]
		if cells.is_empty():
			continue
		
		var mesh_instance: MeshInstance2D = _build_family_mesh_instance(role, cells, tutorial_ground_variation)
		if mesh_instance != null:
			result.append(mesh_instance)
	
	return result

## Compact tutorial fields need more than one broad production-scale grass
## patch. Reassign only ordinary open-ground cells into existing ground kits;
## roads, water, hills, forests, settlements, and fortifications keep their
## terrain-driven roles. This stays presentation-only and deterministic.
static func apply_tutorial_ground_variation(descriptors: Dictionary) -> void:
	for coord: Vector2i in descriptors:
		var desc = descriptors[coord]
		if int(desc.terrain_type) != 0:
			continue
		if int(desc.base_role) not in [BaseRole.PLAIN_LOESS, BaseRole.PLAIN_FADED_GRASS]:
			continue
		var patch: float = _patch(coord, 108.0)
		if patch < 0.30:
			desc.base_role = BaseRole.PLAIN_PARCHMENT
		elif patch < 0.68:
			desc.base_role = BaseRole.PLAIN_LOESS
		else:
			desc.base_role = BaseRole.PLAIN_FADED_GRASS

## Builds the two-tone passive border set (Z=1, PRIMITIVE_LINES):
## dark-umber on light ground, pale ink-gold on dark ground.
static func build_passive_borders(descriptors: Dictionary) -> Node2D:
	return build_passive_border_layer(descriptors, false)

## Builds one contrast layer of the passive outline. ghost=true returns the
## faint duplicate drawn above fog (Phase 8: outlines stay readable in fog).
static func build_passive_border_layer(descriptors: Dictionary, ghost: bool) -> Node2D:
	var dark_lines := PackedVector2Array()
	var light_lines := PackedVector2Array()

	for coord: Vector2i in descriptors:
		var desc = descriptors[coord]
		var role: int = int(desc.base_role) if ("base_role" in desc) else 0
		var use_light: bool = DARK_GROUND_ROLES.has(role)
		var world_center: Vector2 = desc.world_pos if ("world_pos" in desc) else HexUtils.hex_to_pixel(coord.x, coord.y)

		for dir_idx in range(6):
			var neighbor_coord: Vector2i = coord + DIRECTIONS[dir_idx]
			var neighbor_exists: bool = descriptors.has(neighbor_coord)

			if not neighbor_exists or (coord.x < neighbor_coord.x or (coord.x == neighbor_coord.x and coord.y < neighbor_coord.y)):
				var edge_verts: Vector2i = DIR_EDGE_VERTICES[dir_idx]
				var p1: Vector2 = world_center + CANONICAL_VERTICES[edge_verts.x]
				var p2: Vector2 = world_center + CANONICAL_VERTICES[edge_verts.y]
				if use_light:
					light_lines.append(p1)
					light_lines.append(p2)
				else:
					dark_lines.append(p1)
					dark_lines.append(p2)

	var wrap := Node2D.new()
	wrap.name = "PassiveHexBordersGhost" if ghost else "PassiveHexBorders"
	wrap.z_index = 1
	var dim := Color(1, 1, 1, 0.55) if ghost else Color(1, 1, 1, 1)
	_append_line_mesh(wrap, dark_lines, PASSIVE_BORDER_DARK * dim, "BordersDark")
	_append_line_mesh(wrap, light_lines, PASSIVE_BORDER_LIGHT * dim, "BordersLight")
	return wrap

static func _append_line_mesh(parent: Node, verts: PackedVector2Array, color: Color, mesh_name: String) -> void:
	if verts.is_empty():
		return
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts

	var array_mesh := ArrayMesh.new()
	array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays, [], {}, Mesh.ARRAY_FLAG_USE_2D_VERTICES)

	var border_instance := MeshInstance2D.new()
	border_instance.name = mesh_name
	border_instance.mesh = array_mesh
	border_instance.z_index = 0
	border_instance.modulate = color
	parent.add_child(border_instance)

# ------------------------------------------------------------------
# INTERNAL HELPERS
# ------------------------------------------------------------------

static func _build_family_mesh_instance(role: int, cells: Array, tutorial_ground_variation: bool) -> MeshInstance2D:
	var hex_count: int = cells.size()
	var verts := PackedVector2Array()
	var uvs := PackedVector2Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()

	# Pre-allocate arrays
	verts.resize(hex_count * 7)
	uvs.resize(hex_count * 7)
	colors.resize(hex_count * 7)
	indices.resize(hex_count * 18)

	for hex_idx in range(hex_count):
		var desc = cells[hex_idx]
		var center: Vector2 = desc.world_pos if ("world_pos" in desc) else HexUtils.hex_to_pixel(desc.coord.x, desc.coord.y)
		var base_vert_idx: int = hex_idx * 7
		# Phase-3 per-hex ownership: a restrained deterministic value variation
		# plus a center-to-ring falloff. No shared texture coordinates or stains.
		var hh: int = absi((desc.coord.x * 73856093) ^ (desc.coord.y * 19349663) ^ (role * 83492791 + 17))
		var v: float = 0.992 + float(hh % 5) * 0.004
		if tutorial_ground_variation:
			v = 0.96 + float(hh % 9) * 0.01
		var c_center := Color(v, v, v, 1.0)
		if tutorial_ground_variation:
			c_center = Color(v, v * (0.992 + float((hh / 9) % 3) * 0.008), v * (0.985 + float((hh / 27) % 3) * 0.01), 1.0)
		var c_ring := c_center
		var texture_turn: int = hh % 6 if tutorial_ground_variation else 0
		var texture_mirror: float = -1.0 if tutorial_ground_variation and (hh / 6) % 2 == 0 else 1.0

		# Center vertex (index 0)
		verts[base_vert_idx] = center
		uvs[base_vert_idx] = Vector2(0.5, 0.5)
		colors[base_vert_idx] = c_center

		# 6 Outer vertices (indices 1..6)
		for k in range(6):
			var local_vertex: Vector2 = CANONICAL_VERTICES[k]
			var uv_vertex := Vector2(local_vertex.x * texture_mirror, local_vertex.y).rotated(deg_to_rad(float(texture_turn) * 60.0))
			var p: Vector2 = center + local_vertex * (BASE_SURFACE_BLEED if tutorial_ground_variation else 1.0)
			verts[base_vert_idx + 1 + k] = p
			uvs[base_vert_idx + 1 + k] = Vector2(0.5, 0.5) + uv_vertex / Vector2(48.0, 42.0)
			colors[base_vert_idx + 1 + k] = c_ring
		
		# 6 Triangles connecting center to outer vertices:
		# (0, 1, 2), (0, 2, 3), (0, 3, 4), (0, 4, 5), (0, 5, 6), (0, 6, 1)
		var base_idx: int = hex_idx * 18
		for t in range(6):
			var next_t: int = (t + 1) % 6
			indices[base_idx + t * 3 + 0] = base_vert_idx
			indices[base_idx + t * 3 + 1] = base_vert_idx + 1 + t
			indices[base_idx + t * 3 + 2] = base_vert_idx + 1 + next_t
	
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	
	var array_mesh := ArrayMesh.new()
	array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, Mesh.ARRAY_FLAG_USE_2D_VERTICES)
	
	var instance := MeshInstance2D.new()
	instance.name = "BaseTerrain_%s" % FAMILY_NAMES.get(role, "Unknown")
	instance.mesh = array_mesh
	instance.z_index = 0
	instance.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	instance.texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
	
	var path: String = Registry.base_path(role)
	if not path.is_empty():
		instance.material = Registry.surface(path)
		instance.set_meta("approved_resource", path)
	else:
		# No approved open-water source exists in the manifests; channel color is support.
		instance.modulate = FAMILY_BASE_COLORS[role]

	return instance

## Classifies a cell into one of the 8-9 base families if not pre-assigned.
static func classify_base_role(desc, all_descriptors: Dictionary) -> int:
	var t: int = desc.terrain_type if ("terrain_type" in desc) else 0
	var coord: Vector2i = desc.coord
	var is_river: bool = desc.river_present if ("river_present" in desc) else (t == 7)
	var is_pass: bool = desc.pass_corridor if ("pass_corridor" in desc) else false
	var is_sh: bool = desc.stronghold_present if ("stronghold_present" in desc) else (t in [4, 5, 9, 10, 11, 12])
	
	# 1. River channel
	if t == 7 or is_river:
		return BaseRole.RIVER_CHANNEL
	
	# 2. Pass corridor
	if is_pass:
		return BaseRole.PASS_FLOOR
	
	# 3. Marsh / Swamp
	if t == 3:
		return BaseRole.MARSH_GROUND
	
	# 4. Worn Battlefield / Stronghold vicinity
	if is_sh or coord == Vector2i(-12, 2):
		return BaseRole.PLAIN_WORN
	
	# 5. Foothill adjacent plains
	if t == 0 and ("mountain_neighbor_mask" in desc and desc.mountain_neighbor_mask != 0):
		return BaseRole.FOOTHILL_GROUND
	
	# 6. Lowland green (river adjacent)
	if "river_neighbor_mask" in desc and desc.river_neighbor_mask != 0:
		return BaseRole.LOWLAND_GREEN
	
	# 7. Mountain ground foundation: rock, so massifs read as bands in HIGH
	if t == 1:
		return BaseRole.MOUNTAIN_GROUND
	
	# 8. Forest ground foundation
	if t == 2:
		return BaseRole.PLAIN_FADED_GRASS
	
	# 9. General open plains / roads
	if t == 6:
		return BaseRole.PLAIN_PARCHMENT
	
	# Open-ground variation: broad (~8-hex) patches of faded grass / drier
	# loess from a fixed hash field (no straight seam across the map).
	return BaseRole.PLAIN_LOESS if _patch(coord) > 0.62 else BaseRole.PLAIN_FADED_GRASS

## Deterministic low-frequency value field in [0, 1], sampled in WORLD space
## (~8 hexes per cell) so patches are round-ish, not axial parallelograms.
static func _patch(coord: Vector2i, patch_scale: float = 300.0) -> float:
	var wp: Vector2 = HexUtils.hex_to_pixel(coord.x, coord.y)
	var fx: float = wp.x / patch_scale
	var fy: float = wp.y / patch_scale
	var ix: int = floori(fx)
	var iy: int = floori(fy)
	var tx: float = smoothstep(0.0, 1.0, fx - float(ix))
	var ty: float = smoothstep(0.0, 1.0, fy - float(iy))
	var a: float = lerpf(_cell_hash(ix, iy), _cell_hash(ix + 1, iy), tx)
	var b: float = lerpf(_cell_hash(ix, iy + 1), _cell_hash(ix + 1, iy + 1), tx)
	return lerpf(a, b, ty)

static func _cell_hash(x: int, y: int) -> float:
	return float(absi((x * 73856093) ^ (y * 19349663) ^ 5381) % 1000) / 1000.0
