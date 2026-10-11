class_name HexCell
extends RefCounted

## Data structure for a single hex on the map.

enum TerrainType {
	PLAINS,
	MOUNTAINS,
	FOREST,
	SWAMP,
	FORTRESS,
	VILLAGE,
	ROAD,
	RIVER,
	WALL,
	STRONGHOLD_FOOTPRINT,
	STRONGHOLD_WALL,
	CAPITAL_FOOTPRINT,
	CAPITAL_WALL,
	OUTER_MOUNTAIN
}

var q: int
var r: int
var terrain: TerrainType = TerrainType.PLAINS
var occupying_unit: Variant = null # Will hold reference to a Unit object
var is_visible: bool = false # For fog of war

func _init(_q: int, _r: int, _terrain: TerrainType = TerrainType.PLAINS) -> void:
	q = _q
	r = _r
	terrain = _terrain

func get_axial_coords() -> Vector2i:
	return Vector2i(q, r)

func get_movement_cost() -> int:
	match terrain:
		TerrainType.PLAINS: return 1
		TerrainType.MOUNTAINS: return 2
		TerrainType.FOREST: return 2
		TerrainType.SWAMP: return 3
		TerrainType.FORTRESS: return 1
		TerrainType.VILLAGE: return 1
		TerrainType.ROAD: return 1
		TerrainType.RIVER: return 3
		TerrainType.WALL: return 99
		TerrainType.STRONGHOLD_FOOTPRINT: return 99
		TerrainType.STRONGHOLD_WALL: return 99
		TerrainType.CAPITAL_FOOTPRINT: return 99
		TerrainType.CAPITAL_WALL: return 99
		TerrainType.OUTER_MOUNTAIN: return 99
		_: return 1

## Whether this terrain allows ambush.
func can_ambush() -> bool:
	return terrain == TerrainType.FOREST or terrain == TerrainType.SWAMP

## Human-readable name.
func get_terrain_name() -> String:
	match terrain:
		TerrainType.PLAINS: return "평야"
		TerrainType.MOUNTAINS: return "산지/구릉"
		TerrainType.FOREST: return "숲/삼림"
		TerrainType.SWAMP: return "습지/늪"
		TerrainType.FORTRESS: return "성벽/요새"
		TerrainType.VILLAGE: return "마을/도시"
		TerrainType.ROAD: return "도로/관도"
		TerrainType.RIVER: return "강/하천"
		TerrainType.WALL: return "방어성벽"
		TerrainType.STRONGHOLD_FOOTPRINT: return "요새 내부"
		TerrainType.STRONGHOLD_WALL: return "요새 성벽"
		TerrainType.CAPITAL_FOOTPRINT: return "도성 내부"
		TerrainType.CAPITAL_WALL: return "도성 성벽"
		TerrainType.OUTER_MOUNTAIN: return "외곽 험산"
		_: return "알 수 없음"
