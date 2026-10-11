class_name Step2RWorldBoundary
extends RefCounted

## Step2R World Boundary Contract — STEP-02R10 HEXAGONAL STRATEGIC FIELD
## Canonical: Regular Hexagonal Playable Envelope (Radius R=40, 4,921 cells).
## Coordinate System: Logical axial (q, r) with cube x=q, z=r, y=-q-r.
## Center: (0, 0). Distance from center: max(|q|, |r|, |-q-r|).
## Playable: distance <= 40 (exact 4,921 cells).
## Outer Mountain Field: distance 41..85, visually continuous dark mountain hexes.

const HEX_RADIUS: int = 40
const PLAYABLE_HEX_COUNT: int = 4921
const OUTER_HEX_RADIUS: int = 85

# Legacy compatibility aliases
const GRID_Q: int = 81
const GRID_R: int = 81

# Outer mountain extent aliases
const OUTER_EXTENT_LEFT: int = 45
const OUTER_EXTENT_RIGHT: int = 45
const OUTER_EXTENT_TOP: int = 45
const OUTER_EXTENT_BOTTOM: int = 45

# Transition blending: 1 hex ring (distance == 41) between playable and dark outer mountains
const TRANSITION_RING_THICKNESS: int = 1

# Pixel geometry flat-top odd-q / axial: COL_STEP = 36, ROW_STEP = 42, ODD_Q_Y_OFFSET = 21
const TILE_W: int = 48
const TILE_H: int = 42
const COL_STEP: int = 36
const ROW_STEP: int = 42
const ODD_Q_Y_OFFSET: int = 21

# Zoom contract: overview recalibrated for R=40 (~3402px tall) in 1920x1080
const OVERVIEW_MIN_ZOOM: float = 0.30
const NORMAL_MIN_ZOOM: float = 0.85
const DEFAULT_ZOOM: float = 1.15
const MAX_ZOOM: float = 1.85

const OUTER_RENDER_METHOD: String = "batched_hex_renderer_visible_region"
const TEXTURE_SOURCE_USED: String = "res://assets/step2r/tiles/terrain_mountains.png -> derived res://assets/step2r/terrain_mountains_impassable_dark_a/b/c/transition_48.png (brightness 60-76% family, saturation 0.82-0.92)"
const OUTER_MOUNTAIN_VARIANT_COUNT: int = 4
const VISUAL_SHELL_TYPE: String = "regular_hexagonal_envelope_impassable_mountain_field"
const CANONICAL_VISION_STATEMENT: String = "The battlefield is a mathematically regular hexagon of radius 40 (4,921 cells), framed by a continuous dark impassable mountain hex field."

enum WorldRegion {
	PLAYABLE = 0,
	IMPASSABLE_MOUNTAIN = 1,
	OUTSIDE_WORLD = 2,
}

# Legacy aliases
const NATURAL_BARRIER = WorldRegion.IMPASSABLE_MOUNTAIN
const OUTER_SCENIC_WORLD = WorldRegion.OUTSIDE_WORLD

# ------------------------------------------------------------------
# Hex distance & axial coordinate helpers
# ------------------------------------------------------------------
static func axial_distance_from_origin(coord: Vector2i) -> int:
	var s: int = -coord.x - coord.y
	return maxi(maxi(absi(coord.x), absi(coord.y)), absi(s))

static func hex_distance_axial(a: Vector2i, b: Vector2i) -> int:
	var s_a: int = -a.x - a.y
	var s_b: int = -b.x - b.y
	return maxi(maxi(absi(a.x - b.x), absi(a.y - b.y)), absi(s_a - s_b))

# ------------------------------------------------------------------
# Hex coordinate classification — canonical gameplay validity
# ------------------------------------------------------------------
static func is_playable_hex(coord: Vector2i) -> bool:
	return axial_distance_from_origin(coord) <= HEX_RADIUS

static func is_impassable_mountain_hex(coord: Vector2i) -> bool:
	var d: int = axial_distance_from_origin(coord)
	return d > HEX_RADIUS and d <= OUTER_HEX_RADIUS

static func is_outside_world(coord: Vector2i) -> bool:
	return axial_distance_from_origin(coord) > OUTER_HEX_RADIUS

static func is_boundary_hex(coord: Vector2i) -> bool:
	return is_impassable_mountain_hex(coord)

static func classify_hex(coord: Vector2i) -> int:
	if is_playable_hex(coord):
		return WorldRegion.PLAYABLE
	if is_impassable_mountain_hex(coord):
		return WorldRegion.IMPASSABLE_MOUNTAIN
	return WorldRegion.OUTSIDE_WORLD

static func is_transition_ring_hex(coord: Vector2i) -> bool:
	return axial_distance_from_origin(coord) == HEX_RADIUS + 1

static func get_six_extreme_coordinates() -> Array[Vector2i]:
	return [
		Vector2i(HEX_RADIUS, 0),
		Vector2i(0, HEX_RADIUS),
		Vector2i(-HEX_RADIUS, HEX_RADIUS),
		Vector2i(-HEX_RADIUS, 0),
		Vector2i(0, -HEX_RADIUS),
		Vector2i(HEX_RADIUS, -HEX_RADIUS)
	]

# ------------------------------------------------------------------
# Pixel geometry & Authoritative conversions
# ------------------------------------------------------------------
static func hex_to_pixel(q: int, r: int) -> Vector2:
	var x: float = float(q * COL_STEP)
	var y: float = float(r * ROW_STEP + q * ODD_Q_Y_OFFSET)
	return Vector2(x, y)

static func axial_to_world(coord: Vector2i) -> Vector2:
	return hex_to_pixel(coord.x, coord.y)

static func world_to_axial(world_pos: Vector2) -> Vector2i:
	var qf: float = world_pos.x / float(COL_STEP)
	var rf: float = (world_pos.y - qf * float(ODD_Q_Y_OFFSET)) / float(ROW_STEP)
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

# ------------------------------------------------------------------
# World bounds
# ------------------------------------------------------------------
static func get_playable_world_bounds() -> Dictionary:
	var min_world: Vector2 = Vector2(-float(HEX_RADIUS * COL_STEP) - float(TILE_W) * 0.5, -float(HEX_RADIUS * ROW_STEP) - float(TILE_H) * 0.5)
	var max_world: Vector2 = Vector2(float(HEX_RADIUS * COL_STEP) + float(TILE_W) * 0.5, float(HEX_RADIUS * ROW_STEP) + float(TILE_H) * 0.5)
	return {
		"min": min_world,
		"max": max_world,
		"center": Vector2.ZERO,
		"size": max_world - min_world
	}

static func get_outer_world_bounds() -> Dictionary:
	var min_world: Vector2 = Vector2(-float(OUTER_HEX_RADIUS * COL_STEP) - float(TILE_W) * 0.5, -float(OUTER_HEX_RADIUS * ROW_STEP) - float(TILE_H) * 0.5)
	var max_world: Vector2 = Vector2(float(OUTER_HEX_RADIUS * COL_STEP) + float(TILE_W) * 0.5, float(OUTER_HEX_RADIUS * ROW_STEP) + float(TILE_H) * 0.5)
	return {
		"min": min_world,
		"max": max_world,
		"center": Vector2.ZERO,
		"size": max_world - min_world
	}

static func get_boundary_world_bounds() -> Dictionary:
	return get_outer_world_bounds()

static func get_scenic_world_bounds() -> Dictionary:
	return get_outer_world_bounds()

static func get_scenic_outer_extents() -> Dictionary:
	var play: Dictionary = get_playable_world_bounds()
	var outer: Dictionary = get_outer_world_bounds()
	var p_min: Vector2 = play["min"] as Vector2
	var p_max: Vector2 = play["max"] as Vector2
	var o_min: Vector2 = outer["min"] as Vector2
	var o_max: Vector2 = outer["max"] as Vector2
	return {
		"left": int(p_min.x - o_min.x),
		"right": int(o_max.x - p_max.x),
		"top": int(p_min.y - o_min.y),
		"bottom": int(o_max.y - p_max.y)
	}

static func get_camera_world_bounds() -> Dictionary:
	var play: Dictionary = get_playable_world_bounds()
	var p_min: Vector2 = play["min"] as Vector2
	var p_max: Vector2 = play["max"] as Vector2
	var margin: Vector2 = Vector2(540.0, 420.0)
	var c_min: Vector2 = p_min - margin
	var c_max: Vector2 = p_max + margin
	return {
		"min": c_min,
		"max": c_max,
		"center": Vector2.ZERO,
		"size": c_max - c_min
	}

# ------------------------------------------------------------------
# World-position classification (for mouse picking / blocking)
# ------------------------------------------------------------------
static func classify_world_pos(world_pos: Vector2) -> int:
	var coord: Vector2i = world_to_axial(world_pos)
	return classify_hex(coord)

static func is_playable_world_pos(world_pos: Vector2) -> bool:
	return is_playable_hex(world_to_axial(world_pos))

static func is_boundary_world_pos(world_pos: Vector2) -> bool:
	return is_impassable_mountain_hex(world_to_axial(world_pos))

static func is_impassable_world_pos(world_pos: Vector2) -> bool:
	return is_boundary_world_pos(world_pos)

# ------------------------------------------------------------------
# Contract dictionary for JSON export
# ------------------------------------------------------------------
static func build_contract() -> Dictionary:
	var play: Dictionary = get_playable_world_bounds()
	var outer: Dictionary = get_outer_world_bounds()
	var cam: Dictionary = get_camera_world_bounds()
	var ext: Dictionary = get_scenic_outer_extents()
	return {
		"canonical_vision_statement": CANONICAL_VISION_STATEMENT,
		"shape": "regular_hexagon",
		"radius": HEX_RADIUS,
		"expected_cell_count": PLAYABLE_HEX_COUNT,
		"actual_cell_count": PLAYABLE_HEX_COUNT,
		"coordinate_system": "axial_cube_centered",
		"center_coordinate": {"q": 0, "r": 0},
		"max_hex_distance_from_center": HEX_RADIUS,
		"six_extreme_coordinates": [
			{"q": 40, "r": 0},
			{"q": 0, "r": 40},
			{"q": -40, "r": 40},
			{"q": -40, "r": 0},
			{"q": 0, "r": -40},
			{"q": 40, "r": -40}
		],
		"playable_world_bounds": {
			"min": {"x": (play["min"] as Vector2).x, "y": (play["min"] as Vector2).y},
			"max": {"x": (play["max"] as Vector2).x, "y": (play["max"] as Vector2).y},
			"center": {"x": (play["center"] as Vector2).x, "y": (play["center"] as Vector2).y},
			"size": {"x": (play["size"] as Vector2).x, "y": (play["size"] as Vector2).y}
		},
		"outer_world_bounds": {
			"min": {"x": (outer["min"] as Vector2).x, "y": (outer["min"] as Vector2).y},
			"max": {"x": (outer["max"] as Vector2).x, "y": (outer["max"] as Vector2).y},
			"center": {"x": (outer["center"] as Vector2).x, "y": (outer["center"] as Vector2).y},
			"size": {"x": (outer["size"] as Vector2).x, "y": (outer["size"] as Vector2).y}
		},
		"camera_world_bounds": {
			"min": {"x": (cam["min"] as Vector2).x, "y": (cam["min"] as Vector2).y},
			"max": {"x": (cam["max"] as Vector2).x, "y": (cam["max"] as Vector2).y},
			"center": {"x": (cam["center"] as Vector2).x, "y": (cam["center"] as Vector2).y},
			"size": {"x": (cam["size"] as Vector2).x, "y": (cam["size"] as Vector2).y}
		},
		"scenic_outer_extents": ext,
		"outer_render_method": OUTER_RENDER_METHOD,
		"outer_mountain_asset_source": TEXTURE_SOURCE_USED,
		"outer_mountain_variant_count": OUTER_MOUNTAIN_VARIANT_COUNT,
		"transition_ring_thickness": TRANSITION_RING_THICKNESS,
		"overview_min_zoom": OVERVIEW_MIN_ZOOM,
		"default_zoom": DEFAULT_ZOOM,
		"max_zoom": MAX_ZOOM,
		"visual_shell_type": VISUAL_SHELL_TYPE,
		"tile_geometry": {
			"tile_w": TILE_W,
			"tile_h": TILE_H,
			"col_step": COL_STEP,
			"row_step": ROW_STEP,
			"odd_q_y_offset": ODD_Q_Y_OFFSET
		},
		"zoom_ranges": {
			"overview": "%.2f-0.84" % OVERVIEW_MIN_ZOOM,
			"tactical": "0.85-1.40",
			"close": "1.40-%.2f" % MAX_ZOOM
		},
		"valid_gameplay_cells": PLAYABLE_HEX_COUNT,
		"note": "STEP-02R10 Hexagonal Strategic Field Expansion — Radius 40 regular hexagon, 4,921 cells, mask-based validity, dark impassable outer mountain field."
	}

static func build_legacy_contract_alias() -> Dictionary:
	return build_contract()
