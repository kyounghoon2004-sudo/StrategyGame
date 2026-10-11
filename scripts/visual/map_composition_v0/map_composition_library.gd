class_name MapCompositionLibrary
extends RefCounted

## MAP COMPOSITION V0 — presentation-only asset library (FOREST + VILLAGE).
##
## Sources (imported GLB, see IMPORT_RECEIPT.json for sha256 + origins):
##   trees        — ThreeJSBenchmarks/tree_cleanroom_20260930_01  (PASS 8 checkpoint)
##   buildings    — ThreeJSBenchmarks/buildings_cleanroom_20260930_01 (manual finish PASS 7)
##   fortifications — ThreeJSBenchmarks/fortifications_cleanroom_20260930_01 (manual finish PASS 4)
##   agriculture  — ThreeJSBenchmarks/agriculture_cleanroom_20261001_01 (PASS 5, no trees)
##   mountains    — ThreeJSBenchmarks/mountains_cleanroom_20261001_01 (PASS 4, 8 archetypes, tree-free)
## Exported with the runs' own --export tool; GLTFLoader reload parity verified there.
##
## This library only LOADS and MEASURES assets; it never edits them.
## Asset measurement (bounds) drives hex containment and ground contact.

const TREE_DIR := "res://assets/map_composition_v0/source_glb/trees/"
const BUILDING_DIR := "res://assets/map_composition_v0/source_glb/buildings/"
const FORT_DIR := "res://assets/map_composition_v0/source_glb/fortifications/"
const AGRI_DIR := "res://assets/map_composition_v0/source_glb/agriculture/"
const MOUNTAIN_DIR := "res://assets/map_composition_v0/source_glb/mountains/"
const TILE_DIR := "res://assets/map_composition_v0/source_glb/tiles/"
const WATER_DIR := "res://assets/map_composition_v0/source_glb/water/"

## key -> file. Keys are used by the composition builder specs.
const TREES := {
	"tall_pine": "01-tall-straight-pine.glb",
	"wind_pine": "02-windswept-mountain-pine.glb",
	"conifer": "03-broad-layered-conifer.glb",
	"compact_pine": "04-compact-hill-pine.glb",
	"dead_tree": "05-sparse-dead-tree.glb",
	"broadleaf": "06-broadleaf-deciduous-tree.glb",
	"cypress": "07-tall-cypress-like-tree.glb",
	"sapling": "08-sapling-cluster.glb",
}
const BUILDINGS := {
	"small_house": "01-small-peasant-house.glb",
	"medium_house": "02-medium-family-house.glb",
	"granary": "03-raised-granary.glb",
	"workshop": "04-workshop-utility.glb",
	"hall": "05-communal-hall.glb",
	"gate": "06-walled-village-gate.glb",
}
const FORTS := {
	"palisade": "01-wooden-palisade-wall.glb",
	"stone_wall": "02-stone-earth-defensive-wall.glb",
	"gatehouse": "03-layered-gatehouse.glb",
	"watchtower": "04-timber-watchtower.glb",
	"hill_fort": "05-hill-frontier-fort.glb",
	"stronghold": "06-major-stronghold.glb",
}
const AGRI := {
	"dry_field": "01-drycropfield.glb",
	"rice_field": "02-irrigatedricefield.glb",
	"terraced_field": "03-terracedfield.glb",
	"farm_granary": "04-ruralgranary.glb",
	"irrigation": "05-irrigationboundarysystem.glb",
}
const MOUNTAINS := {
	"low_foothill": "01-lowfoothill.glb",
	"long_ridge": "02-longmountainridge.glb",
	"sharp_peak": "03-sharprockypeak.glb",
	"twin_saddle": "04-twinpeaksaddle.glb",
	"cliff_escarpment": "05-cliffescarpment.glb",
	"mountain_pass": "06-notchedmountainpass.glb",
	"vegetated_mountain": "07-vegetatedmountain.glb",
	"layered_massif": "08-layeredmountainmassif.glb",
}
const TILES := {
	"tile_open_grassland": "01-open-grassland.glb",
	"tile_dry_earth": "02-dry-earth-dusty-plain.glb",
	"tile_scrub": "03-scrub-rough-grass.glb",
	"tile_rocky_ground": "04-rocky-ground.glb",
	"tile_packed_dirt": "05-packed-dirt-trail.glb",
	"tile_worn_crossing": "06-worn-crossing-tracked-ground.glb",
	"tile_cultivated_edge": "07-cultivated-edge-field-ground.glb",
	"tile_wet_lowland": "08-wet-muddy-lowland.glb",
}
const WATER := {
	"narrow_stream": "01-narrowstream.scn",
	"main_river": "02-mainriver.scn",
	"shallow_ford": "03-shallowford.scn",
	"wooden_bridge": "04-woodenbridge.scn",
	"stone_bridge": "05-stonereinforcedbridge.scn",
	"tall_bank": "06-tallrockriverbank.scn",
}

## Palette sampled from the runs' own source (buildings.js P table / trees.js palettes).
const COL_WOOD := Color("514030")
const COL_WOOD_LIGHT := Color("806341")
const COL_ROAD := Color("ab9a70")
const COL_ROAD_EDGE := Color("8f7f5c")
const COL_FIELD := Color("a9905a")
const COL_FIELD_EDGE := Color("8d774a")
const COL_FOREST_FLOOR := Color("4c5238")
const COL_FOREST_FLOOR_ALT := Color("575d3d")
const COL_VILLAGE_YARD := Color("b0a686")
const COL_SEAM := Color("a49c88")
const COL_BACKDROP := Color("d2cec2")
const COL_FOREST_PLATE := Color("a9ac8d")
const COL_VILLAGE_PLATE := Color("b1a88c")
const COL_FARM_YARD := Color("b2a67f")
const COL_FARM_PLATE := Color("b1a780")
const COL_MOUNTAIN_YARD := Color("a8a094")
const COL_MOUNTAIN_PLATE := Color("a49c8f")
const COL_MOUNTAIN_BORDER := Color("6b6152")
const COL_WATER := Color("7fa8ab")
const COL_WATER_EDGE := Color("5f8a8e")

static var _scenes: Dictionary = {}
static var _bounds: Dictionary = {}
static var _materials_prepped: Dictionary = {}

## Large-scale, low-frequency ground tone (VISUAL ONLY). Crosses hex borders:
## adjacent tiles sample the same function, so ground variation reads as one
## landscape instead of flat per-tile fills.
static func ground_tint(x: float, z: float) -> Color:
	var n1: float = sin(x * 0.022 + 1.7) * cos(z * 0.026 - 0.6)
	var n2: float = sin(x * 0.052 - 2.1) * sin(z * 0.047 + 1.2)
	var n3: float = sin(x * 0.011 + z * 0.009 + 0.4)
	var f: float = 1.0 + 0.050 * n1 + 0.028 * n2 + 0.030 * n3
	return Color(f, f + 0.008 * n2 - 0.004 * n3, f - 0.016 * n1 - 0.008 * n3, 1.0)

static func scene_for(key: String) -> PackedScene:
	if _scenes.has(key):
		return _scenes[key]
	var path: String = ""
	if TREES.has(key):
		path = TREE_DIR + String(TREES[key])
	elif BUILDINGS.has(key):
		path = BUILDING_DIR + String(BUILDINGS[key])
	elif FORTS.has(key):
		path = FORT_DIR + String(FORTS[key])
	elif AGRI.has(key):
		path = AGRI_DIR + String(AGRI[key])
	elif MOUNTAINS.has(key):
		path = MOUNTAIN_DIR + String(MOUNTAINS[key])
	elif TILES.has(key):
		path = TILE_DIR + String(TILES[key])
	elif WATER.has(key):
		path = WATER_DIR + String(WATER[key])
	assert(path != "", "Unknown composition asset key: " + key)
	var ps: PackedScene = load(path) as PackedScene
	assert(ps != null, "Failed to load composition GLB: " + path)
	_scenes[key] = ps
	_prepare_materials(ps)
	return ps

## Measures the TRUE world AABB of the asset (identity transform) once per key.
## Returns {min: Vector3, max: Vector3, half_xz: Vector2, circ_r: float, min_y: float}.
static func bounds(key: String) -> Dictionary:
	if _bounds.has(key):
		return _bounds[key]
	var inst: Node3D = scene_for(key).instantiate() as Node3D
	var acc := {"min": Vector3(1e9, 1e9, 1e9), "max": Vector3(-1e9, -1e9, -1e9)}
	_accumulate_aabb(inst, Transform3D.IDENTITY, acc)
	inst.free()
	var mn: Vector3 = acc["min"]
	var mx: Vector3 = acc["max"]
	var half := Vector2((mx.x - mn.x) * 0.5, (mx.z - mn.z) * 0.5)
	var d := {
		"min": mn, "max": mx,
		"center": (mn + mx) * 0.5,
		"half_xz": half,
		"circ_r": sqrt(half.x * half.x + half.y * half.y),
		"min_y": mn.y,
	}
	_bounds[key] = d
	return d

static func _accumulate_aabb(node: Node, xf: Transform3D, acc: Dictionary) -> void:
	var t: Transform3D = xf
	if node is Node3D:
		t = xf * (node as Node3D).transform
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		if mi.mesh != null:
			var bb: AABB = mi.mesh.get_aabb()
			for i in range(8):
				var c: Vector3 = bb.get_endpoint(i)
				var p: Vector3 = t * c
				var mn: Vector3 = acc["min"]
				acc["min"] = Vector3(minf(mn.x, p.x), minf(mn.y, p.y), minf(mn.z, p.z))
				var mx: Vector3 = acc["max"]
				acc["max"] = Vector3(maxf(mx.x, p.x), maxf(mx.y, p.y), maxf(mx.z, p.z))
	for child in node.get_children():
		_accumulate_aabb(child, t, acc)

## Instance one asset centred in XZ (bounds centre at origin) with its base at y=0.
static func instance_grounded(key: String) -> Node3D:
	var ps := scene_for(key)
	var inst: Node3D = ps.instantiate() as Node3D
	var b: Dictionary = bounds(key)
	var c: Vector3 = b["center"]
	inst.position = Vector3(-c.x, -b["min_y"], -c.z)
	return inst

## Instance one asset centred in XZ but keeping its DESIGN height (origin stays
## at the asset's nominal surface level — used for ground tiles, whose slab
## deliberately extends below y=0).
static func instance_centered(key: String) -> Node3D:
	var ps := scene_for(key)
	var inst: Node3D = ps.instantiate() as Node3D
	var b: Dictionary = bounds(key)
	var c: Vector3 = b["center"]
	inst.position = Vector3(-c.x, 0.0, -c.z)
	return inst

## Ensures imported materials use vertex colors as albedo (the runs author with
## vertexColors:true MeshStandardMaterial). Idempotent, in-memory only.
static func _prepare_materials(ps: PackedScene) -> void:
	var root := ps.instantiate()
	_prep_node(root)
	root.free()

static func _prep_node(node: Node) -> void:
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		if mi.mesh != null:
			for s in range(mi.mesh.get_surface_count()):
				var m: Material = mi.mesh.surface_get_material(s)
				if m is BaseMaterial3D:
					var bm := m as BaseMaterial3D
					if not bm.vertex_color_use_as_albedo:
						bm.vertex_color_use_as_albedo = true
	for child in node.get_children():
		_prep_node(child)

## Total triangles of one asset (for the composition budget report).
static var _tri_cache: Dictionary = {}

static func triangles(key: String) -> int:
	if _tri_cache.has(key):
		return int(_tri_cache[key])
	var ps := scene_for(key)
	var inst := ps.instantiate()
	var n := _count_triangles(inst)
	inst.free()
	_tri_cache[key] = n
	return n

## Triangle count for any Mesh (ArrayMesh surfaces or PrimitiveMesh).
static func mesh_triangles(m: Mesh) -> int:
	var tri := 0
	if m is ArrayMesh:
		for s in range(m.get_surface_count()):
			var il: int = m.surface_get_array_index_len(s)
			var al: int = m.surface_get_array_len(s)
			tri += int(il if il > 0 else al) / 3
	elif m is PrimitiveMesh:
		var arr: Array = (m as PrimitiveMesh).get_mesh_arrays()
		if arr.size() > Mesh.ARRAY_VERTEX and arr[Mesh.ARRAY_VERTEX] is PackedVector3Array:
			tri += (arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3
	return tri

static func _count_triangles(node: Node) -> int:
	var n := 0
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		if mi.mesh != null:
			n += mesh_triangles(mi.mesh)
	for child in node.get_children():
		n += _count_triangles(child)
	return n
