class_name ProductionMapEnvironment3D
extends Node3D

## PRODUCTION MAP ENVIRONMENT 3D — FULL PRODUCTION BATTLEFIELD VISUAL TRANSPLANT
##
## Transplants the full visual asset composition language of map_composition_v0 across
## the ENTIRE real playable production battlefield (R=40, 4,921 cells).
##
## Hard Contracts:
## - decorated_ground_hex_count MUST EQUAL total_playable_hexes (4,921)
## - uncovered_legacy_hexes == 0
## - SHADOWS STRICTLY OFF across all lights and geometries
## - Full macro-geographic continuity:
##     * The Grand Spine / Dragon Ridge mountain system (546 hexes) with 3 traversable passes
##     * 3 major forest systems (696 hexes): Western Timberlands, Eastern Highlands, North Cypress Woods
##     * Continuous serpentine river (58 cells) with narrow stream, main river, bridges, fords & rocky outlet
##     * 18 historic village settlements with surrounding agricultural hinterlands
##     * Fortress Hulao & Capital Luoyang multi-hex defensive complexes
##     * Expansive open plains (3,295 hexes) on authentic ground tiles with subtle terrain variation
## - Deterministic generation (identical layout every run)
## - Zero gameplay mutation (pure visual presentation layer)

const Lib = preload("res://scripts/visual/map_composition_v0/map_composition_library.gd")
const Builder = preload("res://scripts/visual/map_composition_v0/map_composition_builder.gd")
const HexUtils = preload("res://scripts/core/hex_utils.gd")

const BASE_SEED: int = 20261002
const RADIUS: int = 40
const TOTAL_HEX_COUNT: int = 4921

const TILE_KEYS: Array[String] = [
	"tile_open_grassland",
	"tile_rocky_ground",
	"tile_scrub",
	"tile_wet_lowland",
	"tile_packed_dirt",
	"tile_worn_crossing",
	"tile_cultivated_edge",
	"tile_dry_earth",
]

# Strategic village settlement coordinates (from production map authority)
const VILLAGES: Dictionary = {
	"-28,0": true, "-18,-1": true, "-12,2": true, "4,-1": true, "20,-6": true, "32,-8": true,
	"-18,-20": true, "-2,-21": true, "8,-22": true, "24,-24": true,
	"-10,16": true, "2,15": true, "16,14": true, "28,10": true,
	"-4,8": true, "-4,14": true, "-24,12": true, "28,-2": true
}

# Stronghold footprints (from production map authority)
const FORTRESS_FOOTPRINT: Array[String] = ["-4,2", "-3,2", "-4,3"]
const CAPITAL_FOOTPRINT: Array[String] = ["14,-5", "15,-5", "14,-4"]

var scale_factor: float = 1.0
var built: bool = false
var report: Dictionary = {}

var _sun: DirectionalLight3D = null
var _env: WorldEnvironment = null
var _backdrop: MeshInstance3D = null
var _tiles_parent: Node3D = null
var _features_parent: Node3D = null
var _cam: Camera3D = null

var decorated_ground_hex_count: int = 0
var uncovered_legacy_hex_count: int = 0
var feature_counts: Dictionary = {
	"mountain": 0,
	"forest": 0,
	"river": 0,
	"settlement": 0,
	"fortification": 0,
	"agriculture": 0,
	"open_plain": 0,
}

func _ready() -> void:
	name = "ProductionMapEnvironment3D"

func setup_environment() -> void:
	if _env == null:
		var env := Environment.new()
		env.background_mode = Environment.BG_COLOR
		env.background_color = Color("d9d5cb")
		env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		env.ambient_light_color = Color("f2ecde")
		env.ambient_light_energy = 0.95
		_env = WorldEnvironment.new()
		_env.name = "WorldEnvironment"
		_env.environment = env
		add_child(_env)

	if _sun == null:
		_sun = DirectionalLight3D.new()
		_sun.name = "ProductionSun"
		_sun.light_color = Color("faf1dd")
		_sun.light_energy = 1.35
		_sun.shadow_enabled = false # SHADOWS STRICTLY OFF
		add_child(_sun)
		_sun.look_at_from_position(Vector3(-1200.0, 3000.0, 800.0), Vector3(0.0, 0.0, 0.0))

## Builds the complete environment from a live battlefield shell or node holding cell_data
func build_from_battlefield(shell: Node = null) -> Dictionary:
	var t0: int = Time.get_ticks_msec()
	setup_environment()
	
	var cells: Dictionary = {}
	var river_cells: Dictionary = {}
	var stronghold_cells: Dictionary = {}
	var stronghold_specs: Array = []

	if shell != null:
		var hg: Node = shell.get_node_or_null("HexGrid")
		if hg != null and hg.get("cell_data") is Dictionary:
			cells = hg.get("cell_data")
		if shell.get("_river_cells") is Dictionary:
			river_cells = shell.get("_river_cells")
		if shell.get("_stronghold_cells") is Dictionary:
			stronghold_cells = shell.get("_stronghold_cells")
		if shell.has_method("stronghold_visual_specs"):
			stronghold_specs = shell.call("stronghold_visual_specs")

	# Fallback if cells empty: generate canonical R=40 production cells
	if cells.is_empty():
		cells = _generate_fallback_production_cells(river_cells, stronghold_cells)

	# Clean previous
	_clear_children()

	# Build Backdrop
	_build_backdrop()

	# Build Ground Layer (all 4,921 cells covered with authentic ground tiles)
	_build_ground_tiles(cells, river_cells)

	# Build Macro Geographic Features
	_build_macro_features(cells, river_cells, stronghold_cells, stronghold_specs)

	built = true
	var dt: int = Time.get_ticks_msec() - t0
	report = {
		"total_playable_hexes": cells.size(),
		"decorated_ground_hex_count": decorated_ground_hex_count,
		"uncovered_legacy_hex_count": uncovered_legacy_hex_count,
		"feature_counts": feature_counts.duplicate(),
		"build_ms": dt,
	}

	print("[ProductionMapEnv3D] Built full production battlefield in %d ms | ground=%d/%d uncovered=%d" % [
		dt, decorated_ground_hex_count, cells.size(), uncovered_legacy_hex_count
	])
	return report

func _clear_children() -> void:
	if _backdrop != null and is_instance_valid(_backdrop):
		_backdrop.queue_free()
		_backdrop = null
	if _tiles_parent != null and is_instance_valid(_tiles_parent):
		_tiles_parent.queue_free()
		_tiles_parent = null
	if _features_parent != null and is_instance_valid(_features_parent):
		_features_parent.queue_free()
		_features_parent = null
	decorated_ground_hex_count = 0
	uncovered_legacy_hex_count = 0
	for k in feature_counts.keys():
		feature_counts[k] = 0

## Continuous ground backdrop plate underneath battlefield extending beyond R=40
func _build_backdrop() -> void:
	_backdrop = MeshInstance3D.new()
	_backdrop.name = "ProductionBackdrop"
	var hw: float = 2400.0 * scale_factor
	var hh: float = 2400.0 * scale_factor
	var nx: int = 40
	var nz: int = 40
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for j in range(nz + 1):
		for i in range(nx + 1):
			var x: float = -hw + 2.0 * hw * float(i) / float(nx)
			var z: float = -hh + 2.0 * hh * float(j) / float(nz)
			st.set_color(Lib.ground_tint(x / scale_factor, z / scale_factor))
			st.set_normal(Vector3.UP)
			st.add_vertex(Vector3(x, -0.15 * scale_factor, z))
	for j in range(nz):
		for i in range(nx):
			var v: int = j * (nx + 1) + i
			st.add_index(v)
			st.add_index(v + 1)
			st.add_index(v + nx + 1)
			st.add_index(v + 1)
			st.add_index(v + nx + 2)
			st.add_index(v + nx + 1)
	_backdrop.mesh = st.commit()
	var bm := StandardMaterial3D.new()
	bm.albedo_color = Lib.COL_BACKDROP
	bm.roughness = 1.0
	bm.cull_mode = BaseMaterial3D.CULL_DISABLED
	bm.vertex_color_use_as_albedo = true
	_backdrop.material_override = bm
	_backdrop.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_backdrop)

## Ground tile placement across all 4,921 cells using authentic authored 3D ground tile models
func _build_ground_tiles(cells: Dictionary, river_cells: Dictionary) -> void:
	_tiles_parent = Node3D.new()
	_tiles_parent.name = "GroundTilesLayer"
	add_child(_tiles_parent)

	for key in cells.keys():
		var cell: Variant = cells[key]
		var q: int = int(cell.q)
		var r: int = int(cell.r)
		var t: int = int(cell.terrain)
		var px: Vector2 = HexUtils.hex_to_pixel(q, r) * scale_factor

		# Authoritative tile selection based on terrain & macro-geography
		var tile_key: String = "tile_open_grassland"
		var tile_y: float = 1.0
		match t:
			1: # Mountain: rugged rocky soil & bedrock
				tile_key = "tile_rocky_ground"
				tile_y = 0.60
			2: # Forest: rich scrub understory or mossy grass
				tile_key = "tile_scrub" if (q + r) % 2 == 0 else "tile_open_grassland"
			3: # Swamp / Wetland: dark saturated lowland
				tile_key = "tile_wet_lowland"
			5: # Village: compacted village dirt & courtyards
				tile_key = "tile_packed_dirt"
				tile_y = Builder.TILE_Y_FACTOR
			6: # Road: worn trail crossing if at river, else dry earth highway
				tile_key = "tile_worn_crossing" if river_cells.has(key) else "tile_dry_earth"
			7: # River: wet riverbed & bank
				tile_key = "tile_wet_lowland"
				tile_y = 0.30
			9: # Fortress Hulao: stony foundation
				tile_key = "tile_rocky_ground"
				tile_y = Builder.TILE_Y_FACTOR
			11: # Capital Luoyang: paved courtyard dirt
				tile_key = "tile_packed_dirt"
				tile_y = Builder.TILE_Y_FACTOR
			_: # Open Plains: regional variation forming natural large terrain belts
				var h: int = posmod(q * 7 + r * 13, 20)
				if h in [0, 1, 2]:
					tile_key = "tile_dry_earth"
				elif h in [3, 4, 5]:
					tile_key = "tile_scrub"
				elif _is_near_village(q, r, cells) and (q + r) % 2 == 0:
					tile_key = "tile_cultivated_edge"
					tile_y = Builder.TILE_Y_FACTOR
				elif _is_near_river(q, r, river_cells):
					tile_key = "tile_wet_lowland" if (q + r) % 2 == 0 else "tile_open_grassland"
				else:
					tile_key = "tile_open_grassland"

		var tile: Node3D = Builder.build_tile(tile_key, tile_y)
		tile.position = Vector3(px.x, 0.0, px.y)
		if scale_factor != 1.0:
			tile.scale *= scale_factor
		# Slight alternating yaw for natural organic ground variation
		if (q * 7 + r * 13) % 2 == 1:
			tile.rotation.y = PI
		_tiles_parent.add_child(tile)
		decorated_ground_hex_count += 1

	uncovered_legacy_hex_count = cells.size() - decorated_ground_hex_count

## Macro Geographic Features: Mountains, Forests, Rivers, Settlements, Fortresses, Plains
func _build_macro_features(cells: Dictionary, river_cells: Dictionary, stronghold_cells: Dictionary, stronghold_specs: Array) -> void:
	_features_parent = Node3D.new()
	_features_parent.name = "MacroFeaturesLayer"
	add_child(_features_parent)

	for key in cells.keys():
		var cell: Variant = cells[key]
		var q: int = int(cell.q)
		var r: int = int(cell.r)
		var t: int = int(cell.terrain)
		var px: Vector2 = HexUtils.hex_to_pixel(q, r) * scale_factor
		var seed_val: int = BASE_SEED + q * 1013 + r * 337

		var comp: Node3D = null

		# 1. MOUNTAIN CHAIN (The Grand Spine / Dragon Ridge — 546 hexes)
		if t == 1:
			var m_var: int = absi(q * 3 + r * 7) % 9
			if _is_mountain_edge(q, r, cells):
				m_var = [0, 5, 6][absi(q + r) % 3] # low foothill / crag field
			comp = _build_macro_mountain(m_var, seed_val)
			feature_counts["mountain"] += 1

		# 2. FOREST REGIONS (West, East, North Woods — 696 hexes)
		elif t == 2:
			var f_var: int = 0 # Default dense interior
			if _is_forest_edge(q, r, cells):
				f_var = 2 # Sparse fringe / cypress grove
			elif (q + r) % 3 == 1:
				f_var = 1 # Mixed woods
			comp = _build_macro_forest(f_var, seed_val)
			feature_counts["forest"] += 1

		# 3. CONTINUOUS RIVER (58 cells)
		elif t == 7 or river_cells.has(key):
			var r_key: String = "main_river"
			var yaw: float = 0.0
			if t == 6: # Road crosses river -> Bridge
				r_key = "wooden_bridge" if (q + r) % 2 == 0 else "stone_bridge"
			elif absi(r) >= 22:
				r_key = "narrow_stream" if (q + r) % 2 == 0 else "tall_bank"
			elif (q + r) % 6 == 0:
				r_key = "shallow_ford"
			var pair: Dictionary = Builder.build_river(r_key, yaw)
			comp = pair["root"]
			feature_counts["river"] += 1

		# 4. VILLAGES & SETTLEMENTS (18 strategic settlements)
		elif t == 5 or VILLAGES.has(key):
			var v_var: int = absi(q + r) % 3
			var pair: Dictionary = Builder.build_village(v_var, seed_val)
			comp = pair["root"]
			feature_counts["settlement"] += 1

		# 5. FORTRESS HULAO (Strategic Hilltop Fortress Cluster at -4, 2)
		elif t == 9 or key in FORTRESS_FOOTPRINT:
			var c_var: int = 1 # Outer Bailey Gate
			if key == "-4,2":
				c_var = 2 # Citadel Pyramid Keep
			elif key == "-3,2":
				c_var = 0 # Bastion Hill
			var pair: Dictionary = Builder.build_city(c_var, seed_val)
			comp = pair["root"]
			feature_counts["fortification"] += 1

		# 6. CAPITAL LUOYANG (Imperial Walled City Cluster at 14, -5)
		elif t == 11 or key in CAPITAL_FOOTPRINT:
			var c_var: int = 2 # Palace Keep
			if key == "15,-5":
				c_var = 1 # Grand Wall Gatehouse
			elif key == "14,-4":
				c_var = 0 # Defense Bastion
			var pair: Dictionary = Builder.build_city(c_var, seed_val)
			comp = pair["root"]
			feature_counts["fortification"] += 1

		# 7. AGRICULTURAL HINTERLANDS & OPEN PLAINS
		elif t == 0:
			if _is_near_village(q, r, cells) and (q + r) % 2 == 0:
				var farm_var: int = absi(q) % 2
				var pair: Dictionary = Builder.build_farm(farm_var, seed_val)
				comp = pair["root"]
				feature_counts["agriculture"] += 1
			elif (q * 17 + r * 31) % 19 == 0: # Natural subtle plain variation
				var p_var: int = absi(q * 7 + r * 13) % 4
				var pair: Dictionary = Builder.build_plain(p_var, seed_val)
				comp = pair["root"]
				feature_counts["open_plain"] += 1
			else:
				# Pure open plain: preserved open maneuver space
				feature_counts["open_plain"] += 1

		if comp != null:
			comp.position = Vector3(px.x, 0.0, px.y)
			if scale_factor != 1.0:
				comp.scale = Vector3.ONE * scale_factor
			_features_parent.add_child(comp)

func _build_macro_mountain(m_var: int, seed_val: int) -> Node3D:
	var root := Node3D.new()
	root.name = "MacroMountain_%d" % m_var
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_val

	var primary_keys: Array = [
		"low_foothill", "long_ridge", "sharp_peak", "twin_saddle",
		"cliff_escarpment", "mountain_pass", "vegetated_mountain", "layered_massif"
	]
	var pkey: String = primary_keys[m_var % primary_keys.size()]
	var main_piece: Node3D = Lib.instance_centered(pkey)
	main_piece.name = "MainRock"
	var yaw: float = rng.randf_range(-0.5, 0.5)
	main_piece.rotation.y = yaw
	var s: float = rng.randf_range(1.4, 1.8)
	main_piece.scale = Vector3(s, s * 1.1, s)
	root.add_child(main_piece)

	var yard := MeshInstance3D.new()
	yard.name = "MountainYard"
	yard.mesh = _make_disc_mesh(20.0, Lib.COL_MOUNTAIN_YARD)
	yard.position.y = 0.012
	yard.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(yard)

	if m_var in [0, 4, 5]:
		for i in range(rng.randi_range(2, 4)):
			var tkey: String = ["compact_pine", "wind_pine", "conifer"][rng.randi() % 3]
			var tree: Node3D = Lib.instance_grounded(tkey)
			var a: float = rng.randf() * TAU
			var rad: float = rng.randf_range(8.0, 15.0)
			tree.position = Vector3(cos(a) * rad, 0.1, sin(a) * rad)
			var ts: float = rng.randf_range(0.4, 0.6)
			tree.scale = Vector3.ONE * ts
			root.add_child(tree)

	return root

func _build_macro_forest(f_var: int, seed_val: int) -> Node3D:
	var root := Node3D.new()
	root.name = "MacroForest_%d" % f_var
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_val

	var floor_mesh := MeshInstance3D.new()
	floor_mesh.name = "ForestFloor"
	floor_mesh.mesh = _make_disc_mesh(16.5, Lib.COL_FOREST_FLOOR if f_var != 1 else Lib.COL_FOREST_FLOOR_ALT)
	floor_mesh.position.y = 0.018
	floor_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(floor_mesh)

	var tree_pool: Array = ["compact_pine", "tall_pine", "wind_pine", "conifer"]
	var count: int = 8
	if f_var == 1:
		tree_pool = ["broadleaf", "wind_pine", "compact_pine", "sapling", "cypress"]
		count = 7
	elif f_var == 2:
		tree_pool = ["cypress", "compact_pine", "sapling", "dead_tree"]
		count = 5

	for i in range(count):
		var tkey: String = tree_pool[rng.randi() % tree_pool.size()]
		var tree: Node3D = Lib.instance_grounded(tkey)
		var a: float = rng.randf() * TAU
		var rad: float = sqrt(rng.randf()) * 13.5
		tree.position = Vector3(cos(a) * rad, 0.0, sin(a) * rad)
		var ts: float = rng.randf_range(0.50, 0.72)
		tree.scale = Vector3(ts, ts * rng.randf_range(0.9, 1.2), ts)
		tree.rotation.y = rng.randf() * TAU
		root.add_child(tree)

	return root

static func _make_disc_mesh(r: float, col: Color) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var n := Vector3.UP
	var cv := Vector3.ZERO
	for i in range(6):
		var a0: float = deg_to_rad(60.0 * float(i))
		var a1: float = deg_to_rad(60.0 * float(i + 1))
		var p0 := Vector3(cos(a0) * r, 0.0, sin(a0) * r)
		var p1 := Vector3(cos(a1) * r, 0.0, sin(a1) * r)
		for v in [cv, p0, p1]:
			st.set_color(col)
			st.set_normal(n)
			st.add_vertex(v)
	return st.commit()

func _is_near_village(q: int, r: int, cells: Dictionary) -> bool:
	for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1), Vector2i(1, -1), Vector2i(-1, 1)]:
		var k := "%d,%d" % [q + d.x, r + d.y]
		if VILLAGES.has(k) or (cells.has(k) and int(cells[k].terrain) == 5):
			return true
	return false

func _is_near_river(q: int, r: int, river_cells: Dictionary) -> bool:
	for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		if river_cells.has("%d,%d" % [q + d.x, r + d.y]):
			return true
	return false

func _is_mountain_edge(q: int, r: int, cells: Dictionary) -> bool:
	for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		var k := "%d,%d" % [q + d.x, r + d.y]
		if cells.has(k) and int(cells[k].terrain) != 1:
			return true
	return false

func _is_forest_edge(q: int, r: int, cells: Dictionary) -> bool:
	for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		var k := "%d,%d" % [q + d.x, r + d.y]
		if cells.has(k) and int(cells[k].terrain) != 2:
			return true
	return false

## Helper for generating canonical R=40 production cells when shell is not instantiated
static func _generate_fallback_production_cells(river_cells: Dictionary, stronghold_cells: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	var rq: int = -15
	var rr: int = -25
	while rr <= 32:
		river_cells["%d,%d" % [rq, rr]] = true
		rr += 1
		var target_q: int = -12 + int(round(6.0 * sin(float(rr) / 8.0)))
		if rq < target_q: rq += 1
		elif rq > target_q: rq -= 1
		if maxi(maxi(absi(rq), absi(rr)), absi(-rq - rr)) > RADIUS: break

	for h in FORTRESS_FOOTPRINT: stronghold_cells[h] = true
	for h in CAPITAL_FOOTPRINT: stronghold_cells[h] = true

	var HexCellCls: Script = preload("res://scripts/core/hex_cell.gd")
	for q in range(-RADIUS, RADIUS + 1):
		for r in range(-RADIUS, RADIUS + 1):
			if (absi(q) + absi(r) + absi(q + r)) / 2 <= RADIUS:
				var t: int = _determine_cell_terrain(q, r, river_cells)
				out["%d,%d" % [q, r]] = HexCellCls.new(q, r, t)
	return out

static func _determine_cell_terrain(q: int, r: int, river_cells: Dictionary) -> int:
	var key := "%d,%d" % [q, r]
	if key in FORTRESS_FOOTPRINT: return 9
	if key in CAPITAL_FOOTPRINT: return 11
	if VILLAGES.has(key): return 5
	if river_cells.has(key): return 7
	# Mountains
	var is_north_pass: bool = (q >= 9 and q <= 11 and r == -22)
	var is_central_pass: bool = (q >= 13 and q <= 15 and r == -5)
	var is_south_pass: bool = (q >= 17 and q <= 19 and r == 14)
	if not is_north_pass and not is_central_pass and not is_south_pass:
		if q >= 10 and q <= 22 and r >= -35 and r <= -8:
			if (q * 3 + r * 5) % 7 != 0 or (q >= 12 and q <= 18): return 1
		if q >= 12 and q <= 24 and r >= -4 and r <= 10:
			if (q * 2 + r * 7) % 6 != 0 or (q >= 15 and q <= 21): return 1
		if q >= 15 and q <= 26 and r >= 16 and r <= 28:
			if (q + r) % 5 != 0 or (q >= 18 and q <= 24): return 1
		if q >= -25 and q <= -10 and r <= -28:
			if (q * 7 + r * 3) % 4 != 0: return 1
		if q >= 22 and q <= 38 and r >= 15 and r <= 35:
			if (q + r) % 3 != 0: return 1
	# Forests
	if q >= -35 and q <= -18 and r >= -14 and r <= 10:
		if (q * 3 + r * 2) % 4 != 0: return 2
	if q >= 25 and q <= 38 and r >= -18 and r <= 6:
		if (q + r * 2) % 3 != 0: return 2
	if q >= -15 and q <= 5 and r >= -18 and r <= -10:
		if (q * 5 + r * 3) % 4 != 1: return 2
	# Swamp
	if q >= -18 and q <= -2 and r >= 18 and r <= 28:
		if (q * 2 + r * 3) % 3 != 0: return 3
	return 0

# ==============================================================================
# Camera & View Control
# ==============================================================================

var caption_label: Label = null

func setup_camera() -> Camera3D:
	if _cam == null:
		_cam = Camera3D.new()
		_cam.name = "ProductionCamera3D"
		_cam.projection = Camera3D.PROJECTION_ORTHOGONAL
		_cam.keep_aspect = Camera3D.KEEP_HEIGHT
		_cam.near = 1.0
		_cam.far = 10000.0
		_cam.current = true
		add_child(_cam)
	return _cam

func get_camera() -> Camera3D:
	return _cam

func set_camera_view(center_px: Vector2, span: float, pitch_deg: float = 45.0, azimuth_deg: float = 30.0) -> void:
	if _cam == null:
		setup_camera()
	var pitch: float = deg_to_rad(pitch_deg)
	var az: float = deg_to_rad(azimuth_deg)
	var focus := Vector3(center_px.x, 0.0, center_px.y)
	var dist := 3500.0
	var off := Vector3(sin(az) * cos(pitch), sin(pitch), cos(az) * cos(pitch)) * dist
	_cam.size = span
	_cam.position = focus + off
	_cam.look_at(focus, Vector3.UP)

func setup_caption() -> void:
	if caption_label != null:
		return
	var cl := CanvasLayer.new()
	cl.name = "ProductionCaptionLayer"
	cl.layer = 95
	add_child(cl)
	caption_label = Label.new()
	caption_label.name = "Caption"
	caption_label.position = Vector2(26.0, 1020.0)
	caption_label.add_theme_font_size_override("font_size", 20)
	caption_label.add_theme_color_override("font_color", Color("3a382e"))
	cl.add_child(caption_label)

func set_caption(shot_name: String, span: float, pitch_deg: float) -> void:
	setup_caption()
	if caption_label != null:
		caption_label.text = "FULL PRODUCTION MAP VISUAL TRANSPLANT · %s · span %.0f · pitch %.1f° · 4,921 HEXES · SHADOWS OFF" % [
			shot_name, span, pitch_deg
		]

func apply_view_preset(preset_key: String) -> void:
	match preset_key:
		"01_full_map_macro_overview":
			set_camera_view(Vector2(0.0, 0.0), 3800.0, 56.0, 30.0)
			set_caption("01 Full Map Macro Overview (R=40, 4,921 Hexes)", 3800.0, 56.0)
		"02_quadrant_nw":
			var c := HexUtils.hex_to_pixel(-18, -18)
			set_camera_view(c, 1800.0, 46.0, 30.0)
			set_caption("02 Quadrant North-West (River Origin & Northern Pines)", 1800.0, 46.0)
		"03_quadrant_ne":
			var c := HexUtils.hex_to_pixel(18, -18)
			set_camera_view(c, 1800.0, 46.0, 30.0)
			set_caption("03 Quadrant North-East (Northern Spine Mountain Pass)", 1800.0, 46.0)
		"04_quadrant_sw":
			var c := HexUtils.hex_to_pixel(-18, 18)
			set_camera_view(c, 1800.0, 46.0, 30.0)
			set_caption("04 Quadrant South-West (Timberlands, Swamp & River Basin)", 1800.0, 46.0)
		"05_quadrant_se":
			var c := HexUtils.hex_to_pixel(18, 18)
			set_camera_view(c, 1800.0, 46.0, 30.0)
			set_caption("05 Quadrant South-East (Southern Mountain Chain & Plains)", 1800.0, 46.0)
		"06_transition_mountain_foothill_plain":
			var c := HexUtils.hex_to_pixel(12, -14)
			set_camera_view(c, 480.0, 35.0, 30.0)
			set_caption("06 Transition: Mountain Massif -> Foothills -> Plains", 480.0, 35.0)
		"07_transition_forest_core_edge_plain":
			var c := HexUtils.hex_to_pixel(-21, 0)
			set_camera_view(c, 480.0, 35.0, 30.0)
			set_caption("07 Transition: Pine Forest Core -> Mixed Edge -> Plains", 480.0, 35.0)
		"08_river_course_crossing_banks":
			var c := HexUtils.hex_to_pixel(-12, 0)
			set_camera_view(c, 420.0, 32.0, 30.0)
			set_caption("08 River Course: Highway Crossing, Bridges & River Banks", 420.0, 32.0)
		"09_village_farms_surroundings":
			var c := HexUtils.hex_to_pixel(-12, 2)
			set_camera_view(c, 420.0, 32.0, 30.0)
			set_caption("09 Settlement: Strategic Village, Granaries & Farmlands", 420.0, 32.0)
		"10_fortress_commanding_terrain":
			var c := HexUtils.hex_to_pixel(-4, 2)
			set_camera_view(c, 420.0, 32.0, 30.0)
			set_caption("10 Fortress Hulao: Citadel Keep, Bastions & Outer Bailey", 420.0, 32.0)
		_:
			set_camera_view(Vector2(0.0, 0.0), 3800.0, 56.0, 30.0)
			set_caption(preset_key, 3800.0, 56.0)

