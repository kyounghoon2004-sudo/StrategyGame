class_name MapCompositionV0
extends Node3D

## MAP COMPOSITION V0 — FULL BATTLEFIELD VISUAL ASSET COMPOSITION TEST
##
## Richly dressed battlefield composed entirely from existing environment asset families:
## - Northern Mountain System: unbroken mountain chain, high peaks, ridges, passes & foothills
## - Dense Western & Eastern Forests: natural tree clusters spilling into plains
## - Continuous River: gorge stream -> main river -> wooden bridge -> shallow ford -> stone bridge -> rocky outlet
## - Prosperous Agricultural Village: communal hall, houses, granaries, workshops, farm plots & irrigation
## - Strategic Hilltop Fortress: citadel pyramid keep, stone outer bailey & forward bastion commanding river crossing
## - Expansive Open Plains: vast maneuver terrain on authentic ground tiles
##
## SHADOWS: STRICTLY DISABLED across all lights and geometries for composition testing.
## CAMERA: Uses presentation projection camera language (azimuth 30°, zoom 1.15 tactical / 0.42 macro).

const Builder = preload("res://scripts/visual/map_composition_v0/map_composition_builder.gd")
const Lib = preload("res://scripts/visual/map_composition_v0/map_composition_library.gd")
const ForestPilot = preload("res://scripts/visual/map_composition_v0/forest_runtime_pilot.gd")

const COL_BG := Color("d9d5cb")
const P_ZOOM := 1.15          # normal gameplay zoom
const ZOOM_MACRO := 0.42      # dev macro overview
const AZIMUTH_DEG := 30.0

const BASE_SEED := 20260930
const Q_STEP := 36.0
const R_STEP := 42.0
const ODD_Q_OFFSET := 21.0
const HEX_HALF := Vector2(24.0, 21.0)

## 80-Hex Complete Battlefield Geography (q=0..9, r=-2..5)
const HEXES: Array = [
	# ---- Row r = -2 (Northern Mountain Range: High Peaks, Massifs, Ridges) ----
	{"name": "Mountain NW Peaks", "family": "mountain", "variant": 2, "q": 0, "r": -2, "tile": "tile_rocky_ground"},
	{"name": "Mountain Massif A", "family": "mountain", "variant": 3, "q": 1, "r": -2, "tile": "tile_rocky_ground"},
	{"name": "Mountain Twin Peaks", "family": "mountain", "variant": 7, "q": 2, "r": -2, "tile": "tile_rocky_ground"},
	{"name": "Mountain Central Massif", "family": "mountain", "variant": 8, "q": 3, "r": -2, "tile": "tile_rocky_ground"},
	{"name": "Mountain High Ridge", "family": "mountain", "variant": 1, "q": 4, "r": -2, "tile": "tile_rocky_ground"},
	{"name": "Mountain Gorge Head", "family": "mountain", "variant": 0, "q": 5, "r": -2, "tile": "tile_rocky_ground"},
	{"name": "Mountain North Dome", "family": "mountain", "variant": 5, "q": 6, "r": -2, "tile": "tile_rocky_ground"},
	{"name": "Mountain Crag Field", "family": "mountain", "variant": 6, "q": 7, "r": -2, "tile": "tile_rocky_ground"},
	{"name": "Mountain NE Peak", "family": "mountain", "variant": 2, "q": 8, "r": -2, "tile": "tile_rocky_ground"},
	{"name": "Mountain NE Massif", "family": "mountain", "variant": 3, "q": 9, "r": -2, "tile": "tile_rocky_ground"},

	# ---- Row r = -1 (Foothills, Passes, River Origin Gorge) ----
	{"name": "Foothill West A", "family": "mountain", "variant": 5, "q": 0, "r": -1, "tile": "tile_rocky_ground"},
	{"name": "Foothill West B", "family": "mountain", "variant": 6, "q": 1, "r": -1, "tile": "tile_rocky_ground"},
	{"name": "Mountain Pass", "family": "mountain", "variant": 1, "q": 2, "r": -1, "tile": "tile_rocky_ground"},
	{"name": "Terraced Mountain", "family": "mountain", "variant": 4, "q": 3, "r": -1, "tile": "tile_cultivated_edge"},
	{"name": "Foothill Valley", "family": "mountain", "variant": 0, "q": 4, "r": -1, "tile": "tile_rocky_ground"},
	{"name": "River Gorge Stream", "family": "river", "river_key": "narrow_stream", "yaw": 0.0, "q": 5, "r": -1, "tile": "tile_wet_lowland"},
	{"name": "East Foothill A", "family": "mountain", "variant": 0, "q": 6, "r": -1, "tile": "tile_rocky_ground"},
	{"name": "East Foothill B", "family": "mountain", "variant": 6, "q": 7, "r": -1, "tile": "tile_rocky_ground"},
	{"name": "East Mountain Pines", "family": "forest", "variant": 0, "q": 8, "r": -1, "tile": "tile_scrub"},
	{"name": "East Corner Crag", "family": "mountain", "variant": 5, "q": 9, "r": -1, "tile": "tile_rocky_ground"},

	# ---- Row r = 0 (Upper Foothills, Upper Woods, Upper River Channel) ----
	{"name": "North Forest Pines", "family": "forest", "variant": 0, "q": 0, "r": 0, "tile": "tile_scrub"},
	{"name": "North Forest Woods", "family": "forest", "variant": 1, "q": 1, "r": 0, "tile": "tile_scrub"},
	{"name": "North Forest Edge", "family": "forest", "variant": 2, "q": 2, "r": 0, "tile": "tile_open_grassland"},
	{"name": "Foothill Meadow", "family": "plain", "variant": 2, "q": 3, "r": 0, "tile": "tile_scrub"},
	{"name": "Upper Meadow", "family": "plain", "variant": 1, "q": 4, "r": 0, "tile": "tile_open_grassland"},
	{"name": "Upper Main River", "family": "river", "river_key": "main_river", "yaw": 0.0, "q": 5, "r": 0, "tile": "tile_wet_lowland"},
	{"name": "River East Meadow", "family": "plain", "variant": 0, "q": 6, "r": 0, "tile": "tile_open_grassland"},
	{"name": "East Terrace Plain", "family": "plain", "variant": 2, "q": 7, "r": 0, "tile": "tile_scrub"},
	{"name": "East Woods A", "family": "forest", "variant": 1, "q": 8, "r": 0, "tile": "tile_scrub"},
	{"name": "East Woods B", "family": "forest", "variant": 0, "q": 9, "r": 0, "tile": "tile_scrub"},

	# ---- Row r = 1 (West Forest Flank, Village, Wooden Bridge, East Woods) ----
	{"name": "West Forest Deep", "family": "forest", "variant": 0, "q": 0, "r": 1, "tile": "tile_scrub"},
	{"name": "West Forest Mid", "family": "forest", "variant": 1, "q": 1, "r": 1, "tile": "tile_open_grassland"},
	{"name": "West Forest Fringe", "family": "forest", "variant": 2, "q": 2, "r": 1, "tile": "tile_open_grassland"},
	{"name": "Village North Hall", "family": "village", "variant": 0, "q": 3, "r": 1, "tile": "tile_packed_dirt"},
	{"name": "Village Gate Market", "family": "village", "variant": 1, "q": 4, "r": 1, "tile": "tile_packed_dirt"},
	{"name": "River Wooden Bridge", "family": "river", "river_key": "wooden_bridge", "yaw": 0.0, "q": 5, "r": 1, "tile": "tile_worn_crossing"},
	{"name": "Bridgehead East Trail", "family": "plain", "variant": 1, "q": 6, "r": 1, "tile": "tile_worn_crossing"},
	{"name": "East Bank Meadow", "family": "plain", "variant": 0, "q": 7, "r": 1, "tile": "tile_open_grassland"},
	{"name": "East Cypress Grove", "family": "forest", "variant": 2, "q": 8, "r": 1, "tile": "tile_open_grassland"},
	{"name": "East Ridge Timber", "family": "forest", "variant": 1, "q": 9, "r": 1, "tile": "tile_scrub"},

	# ---- Row r = 2 (Forest Fringe, Farmlands, Village Hamlet, River Ford) ----
	{"name": "West Woods South", "family": "forest", "variant": 1, "q": 0, "r": 2, "tile": "tile_open_grassland"},
	{"name": "West Plain Meadow", "family": "plain", "variant": 1, "q": 1, "r": 2, "tile": "tile_open_grassland"},
	{"name": "Dry Crop Fields", "family": "farm", "variant": 0, "q": 2, "r": 2, "tile": "tile_cultivated_edge"},
	{"name": "Village Hamlet South", "family": "village", "variant": 2, "q": 3, "r": 2, "tile": "tile_packed_dirt"},
	{"name": "Village Outskirts", "family": "plain", "variant": 3, "q": 4, "r": 2, "tile": "tile_dry_earth"},
	{"name": "West River Bank Flat", "family": "plain", "variant": 0, "q": 5, "r": 2, "tile": "tile_wet_lowland"},
	{"name": "River Shallow Ford", "family": "river", "river_key": "shallow_ford", "yaw": 30.0, "q": 6, "r": 2, "tile": "tile_worn_crossing"},
	{"name": "Ford East Approach", "family": "plain", "variant": 1, "q": 7, "r": 2, "tile": "tile_worn_crossing"},
	{"name": "East Flank Plain", "family": "plain", "variant": 0, "q": 8, "r": 2, "tile": "tile_open_grassland"},
	{"name": "East Hill Plain", "family": "plain", "variant": 2, "q": 9, "r": 2, "tile": "tile_scrub"},

	# ---- Row r = 3 (Wide West Plains, Rice Fields, River, Fortress Citadel & Bastion) ----
	{"name": "West Battle Plain A", "family": "plain", "variant": 0, "q": 0, "r": 3, "tile": "tile_open_grassland"},
	{"name": "West Battle Plain B", "family": "plain", "variant": 0, "q": 1, "r": 3, "tile": "tile_open_grassland"},
	{"name": "Central Plains West", "family": "plain", "variant": 0, "q": 2, "r": 3, "tile": "tile_open_grassland"},
	{"name": "Irrigated Rice Paddies", "family": "farm", "variant": 1, "q": 3, "r": 3, "tile": "tile_cultivated_edge"},
	{"name": "Plains Highway", "family": "plain", "variant": 1, "q": 4, "r": 3, "tile": "tile_dry_earth"},
	{"name": "River Approach Flat", "family": "plain", "variant": 0, "q": 5, "r": 3, "tile": "tile_worn_crossing"},
	{"name": "Mid Main River", "family": "river", "river_key": "main_river", "yaw": 0.0, "q": 6, "r": 3, "tile": "tile_wet_lowland"},
	{"name": "Fortress Citadel Keep", "family": "city", "variant": 2, "q": 7, "r": 3, "tile": "tile_packed_dirt"},
	{"name": "Fortress Bastion Hill", "family": "city", "variant": 0, "q": 8, "r": 3, "tile": "tile_rocky_ground"},
	{"name": "Fortress East Rear", "family": "plain", "variant": 2, "q": 9, "r": 3, "tile": "tile_rocky_ground"},

	# ---- Row r = 4 (South West Plains, Bridge Road, Stone Bridge, Fortress Outer Bailey) ----
	{"name": "South West Plain A", "family": "plain", "variant": 0, "q": 0, "r": 4, "tile": "tile_open_grassland"},
	{"name": "South West Plain B", "family": "plain", "variant": 0, "q": 1, "r": 4, "tile": "tile_open_grassland"},
	{"name": "South Central Plain A", "family": "plain", "variant": 0, "q": 2, "r": 4, "tile": "tile_open_grassland"},
	{"name": "South Central Plain B", "family": "plain", "variant": 0, "q": 3, "r": 4, "tile": "tile_open_grassland"},
	{"name": "Military Highway South", "family": "plain", "variant": 1, "q": 4, "r": 4, "tile": "tile_dry_earth"},
	{"name": "Bridge Causeway Approach", "family": "plain", "variant": 3, "q": 5, "r": 4, "tile": "tile_worn_crossing"},
	{"name": "Stone Reinforced Bridge", "family": "river", "river_key": "stone_bridge", "yaw": 0.0, "q": 6, "r": 4, "tile": "tile_worn_crossing"},
	{"name": "Fortress Outer Bailey Gate", "family": "city", "variant": 1, "q": 7, "r": 4, "tile": "tile_packed_dirt"},
	{"name": "Fortress East Gate Trail", "family": "plain", "variant": 1, "q": 8, "r": 4, "tile": "tile_worn_crossing"},
	{"name": "South East Plain Scrub", "family": "plain", "variant": 2, "q": 9, "r": 4, "tile": "tile_scrub"},

	# ---- Row r = 5 (Southern Border Plains, River Rocky Gorge Outlet) ----
	{"name": "South Border Plain A", "family": "plain", "variant": 0, "q": 0, "r": 5, "tile": "tile_open_grassland"},
	{"name": "South Border Plain B", "family": "plain", "variant": 0, "q": 1, "r": 5, "tile": "tile_open_grassland"},
	{"name": "South Border Plain C", "family": "plain", "variant": 0, "q": 2, "r": 5, "tile": "tile_open_grassland"},
	{"name": "South Border Plain D", "family": "plain", "variant": 0, "q": 3, "r": 5, "tile": "tile_open_grassland"},
	{"name": "South Border Plain E", "family": "plain", "variant": 0, "q": 4, "r": 5, "tile": "tile_open_grassland"},
	{"name": "South Border Scrub", "family": "plain", "variant": 2, "q": 5, "r": 5, "tile": "tile_scrub"},
	{"name": "River South Bank Meadow", "family": "plain", "variant": 0, "q": 6, "r": 5, "tile": "tile_wet_lowland"},
	{"name": "River Gorge Outlet Bank", "family": "river", "river_key": "tall_bank", "yaw": 30.0, "q": 7, "r": 5, "tile": "tile_wet_lowland"},
	{"name": "South Terrace Plain", "family": "plain", "variant": 2, "q": 8, "r": 5, "tile": "tile_rocky_ground"},
	{"name": "South Corner Terrace", "family": "plain", "variant": 0, "q": 9, "r": 5, "tile": "tile_open_grassland"},
]

var built := false
var report: Dictionary = {}
var cam: Camera3D
var _hex_records: Array = []
var _forest_pilot: ForestRuntimePilot = null

static func hex_center(q: int, r: int) -> Vector2:
	return Vector2(float(q) * Q_STEP, float(r) * R_STEP + float(q) * ODD_Q_OFFSET)

## Large-scale, low-frequency ground variation (visual only; crossed-hex scale).
static func _backdrop_grid(center: Vector2, hw: float, hh: float, nx: int, nz: int) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for j in range(nz + 1):
		for i in range(nx + 1):
			var x: float = center.x - hw + 2.0 * hw * float(i) / float(nx)
			var z: float = center.y - hh + 2.0 * hh * float(j) / float(nz)
			st.set_color(Lib.ground_tint(x, z))
			st.set_normal(Vector3.UP)
			st.add_vertex(Vector3(x, -0.06, z))
	for j in range(nz):
		for i in range(nx):
			var v: int = j * (nx + 1) + i
			st.add_index(v)
			st.add_index(v + 1)
			st.add_index(v + nx + 1)
			st.add_index(v + 1)
			st.add_index(v + nx + 2)
			st.add_index(v + nx + 1)
	return st.commit()

static func view_e_for_zoom(zoom: float) -> float:
	var a: float = log(0.5)
	var b: float = log(3.0)
	var x: float = clampf((log(maxf(zoom, 0.01)) - a) / (b - a), 0.0, 1.0)
	return 1.0 - (1.0 - x) * (1.0 - x)

static func pitch_for_zoom(zoom: float) -> float:
	var k: float = pow(view_e_for_zoom(zoom), 0.8)
	return lerpf(88.0, 17.0, k)

func _ready() -> void:
	name = "MapCompositionV0"
	if OS.get_cmdline_user_args().has("forest_lod=1"):
		_forest_pilot = ForestPilot.new()
	_build_environment()
	_build_ground()
	_build_compositions()
	_build_camera()
	_setup_caption()
	report = _compile_report()
	if _forest_pilot != null:
		print("[ForestPilot] " + JSON.stringify(_forest_pilot.stats))
	built = true
	print("[MapCompositionV0] built | hexes=%d nodes=%d meshes=%d triangles=%d max_violation=%.4f" % [
		_hex_records.size(), int(report["nodes"]), int(report["meshes"]),
		int(report["triangles"]), float(report["max_violation"])])

var caption_label: Label = null

func _setup_caption() -> void:
	var cl := CanvasLayer.new()
	cl.name = "CaptionLayer"
	cl.layer = 90
	add_child(cl)
	caption_label = Label.new()
	caption_label.name = "Caption"
	caption_label.position = Vector2(26.0, 1020.0)
	caption_label.add_theme_font_size_override("font_size", 20)
	caption_label.add_theme_color_override("font_color", Color("3a382e"))
	cl.add_child(caption_label)

func set_caption(shot: String, zoom: float, pitch_override: float = 0.0) -> void:
	if caption_label == null:
		return
	var pitch_txt: String = "%.1f°" % pitch_for_zoom(zoom)
	if pitch_override > 0.0:
		pitch_txt = "%.1f°" % pitch_override
	caption_label.text = "FULL MAP ASSET COMPOSITION TEST V0 · %s · zoom %.2f · pitch %s · 80 HEXES · SHADOWS OFF" % [shot, zoom, pitch_txt]

func _build_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = COL_BG
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color("f2ecde")
	env.ambient_light_energy = 0.95
	var we := WorldEnvironment.new()
	we.name = "WorldEnvironment"
	we.environment = env
	add_child(we)

	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.light_color = Color("faf1dd")
	sun.light_energy = 1.35
	sun.shadow_enabled = false   # SHADOWS STRICTLY OFF FOR THIS TEST
	add_child(sun)
	sun.look_at_from_position(Vector3(-8.0, 23.0, 7.0), Vector3(36.0, 0.0, 21.0))

	get_viewport().msaa_3d = Viewport.MSAA_2X

func _build_ground() -> void:
	# Backdrop plate under the entire battlefield
	var backdrop := MeshInstance3D.new()
	backdrop.name = "Backdrop"
	backdrop.mesh = _backdrop_grid(Vector2(162.0, 157.5), 650.0, 650.0, 32, 32)
	var bm := StandardMaterial3D.new()
	bm.albedo_color = Lib.COL_BACKDROP
	bm.roughness = 1.0
	bm.cull_mode = BaseMaterial3D.CULL_DISABLED
	bm.vertex_color_use_as_albedo = true
	backdrop.material_override = bm
	backdrop.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(backdrop)

	# Build EVERY single hex with its authored ground tile asset
	for rec in HEXES:
		var q: int = rec["q"]
		var r: int = rec["r"]
		var c2 := hex_center(q, r)
		var holder := Node3D.new()
		holder.name = "Hex_%s_%d_%d" % [rec["family"], q, r]
		holder.position = Vector3(c2.x, 0.0, c2.y)
		add_child(holder)

		var tile_family := String(rec["family"])
		var tile_y := 1.0
		if tile_family == "village" or tile_family == "city" or tile_family == "farm":
			tile_y = Builder.TILE_Y_FACTOR
		elif tile_family == "river":
			tile_y = 0.30
		elif tile_family == "mountain":
			tile_y = 0.60

		var tile := Builder.build_tile(String(rec["tile"]), tile_y)
		tile.name = "Tile"
		if (q * 7 + r * 13) % 2 == 1:
			tile.rotation.y = PI
		holder.add_child(tile)

func _build_compositions() -> void:
	for rec in HEXES:
		var q: int = rec["q"]
		var r: int = rec["r"]
		var holder := get_node(NodePath("Hex_%s_%d_%d" % [rec["family"], q, r])) as Node3D
		var seed: int = BASE_SEED + q * 1013 + r * 337
		var builtpair: Dictionary
		if rec["family"] == "forest":
			builtpair = Builder.build_forest(int(rec["variant"]), seed)
		elif rec["family"] == "village":
			builtpair = Builder.build_village(int(rec["variant"]), seed)
		elif rec["family"] == "farm":
			builtpair = Builder.build_farm(int(rec["variant"]), seed)
		elif rec["family"] == "mountain":
			builtpair = Builder.build_mountain(int(rec["variant"]), seed)
		elif rec["family"] == "river":
			builtpair = Builder.build_river(String(rec["river_key"]), float(rec.get("yaw", 0.0)))
		elif rec["family"] == "plain":
			builtpair = Builder.build_plain(int(rec["variant"]), seed)
		else:
			builtpair = Builder.build_city(int(rec["variant"]), seed)
		var comp: Node3D = builtpair["root"]
		comp.name = String(comp.name)
		holder.add_child(comp)
		if rec["family"] == "forest" and _forest_pilot != null:
			_forest_pilot.convert_hex(comp)
		var stats: Dictionary = builtpair["stats"]
		_hex_records.append({
			"name": rec["name"], "family": rec["family"], "variant": rec.get("variant", 0),
			"q": q, "r": r, "stats": stats,
		})

func _build_camera() -> void:
	cam = Camera3D.new()
	cam.name = "ReviewCamera"
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.keep_aspect = Camera3D.KEEP_HEIGHT
	cam.near = 1.0
	cam.far = 3500.0
	cam.current = true
	add_child(cam)
	set_view_zoom(P_ZOOM, focus_rect("BATTLEFIELD_CENTER"))

## ---- View helpers -------------------------------------------------------------

func focus_rect(key: String) -> Rect2:
	match key:
		"ALL":
			return Rect2(Vector2(-24.0, -105.0), Vector2(372.0, 525.0))
		"BATTLEFIELD_CENTER":
			# Tactical center: central plains, village, bridge crossing, and fortress approach
			var c := hex_center(5, 2)
			return Rect2(c - Vector2(110.0, 75.0), Vector2(220.0, 150.0))
		"FORTRESS":
			# Citadel (7,3), outer bailey (7,4), forward bastion (8,3)
			var c := hex_center(7, 3)
			return Rect2(c - Vector2(70.0, 55.0), Vector2(140.0, 110.0))
		"RIVER_CROSSING":
			# Stone bridge (6,4), wooden bridge (5,1), shallow ford (6,2)
			var c := hex_center(6, 3)
			return Rect2(c - Vector2(80.0, 70.0), Vector2(160.0, 140.0))
		"VILLAGE":
			# Village (3,1), (4,1), (3,2) and farmlands (2,2), (3,3)
			var c := hex_center(3, 2)
			return Rect2(c - Vector2(80.0, 70.0), Vector2(160.0, 140.0))
		"MOUNTAINS":
			# Northern mountain massif and pass
			var c := hex_center(4, -1)
			return Rect2(c - Vector2(140.0, 65.0), Vector2(280.0, 130.0))
		"FOREST":
			# Western dense forest cluster
			var c := hex_center(1, 1)
			return Rect2(c - Vector2(75.0, 75.0), Vector2(150.0, 150.0))
	return Rect2(Vector2(-24.0, -105.0), Vector2(372.0, 525.0))

func set_view_zoom(zoom: float, rect: Rect2, margin: float = 1.12, pitch_override: float = 0.0) -> void:
	var aspect: float = 16.0 / 9.0
	var vp := get_viewport()
	if vp != null:
		var sz := vp.get_visible_rect().size
		if sz.y > 0.0:
			aspect = sz.x / sz.y
	var fit: float = maxf(rect.size.x / aspect, rect.size.y) * margin
	var span: float = fit * (P_ZOOM / zoom)
	var pitch: float = deg_to_rad(pitch_override if pitch_override > 0.0 else pitch_for_zoom(zoom))
	var az: float = deg_to_rad(AZIMUTH_DEG)
	var focus := Vector3(rect.get_center().x, 0.0, rect.get_center().y)
	var dist := 1200.0
	var off := Vector3(sin(az) * cos(pitch), sin(pitch), cos(az) * cos(pitch)) * dist
	cam.size = span
	cam.position = focus + off
	cam.look_at(focus, Vector3.UP)
	if _forest_pilot != null:
		_forest_pilot.update_for_camera(cam)

## ---- Report -------------------------------------------------------------------

func _compile_report() -> Dictionary:
	var nodes := 0
	var meshes := 0
	var tris := 0
	var stack: Array = [self]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		nodes += 1
		if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
			meshes += 1
			tris += Lib.mesh_triangles((n as MeshInstance3D).mesh)
		for ch in n.get_children():
			stack.append(ch)
	var max_v := 0.0
	var hexes: Array = []
	for rec in _hex_records:
		var st: Dictionary = rec["stats"]
		max_v = maxf(max_v, float(st.get("max_violation", 0.0)))
		hexes.append({
			"name": rec["name"], "hex": [rec["q"], rec["r"]], "family": rec["family"],
			"placed": st.get("placed", {}), "triangles": st.get("triangles", 0),
			"max_violation": snappedf(float(st.get("max_violation", 0.0)), 0.0001),
			"skipped": st.get("skipped", 0),
			"overlaps": int(st.get("overlaps", 0)),
		})
	return {
		"scene": "map_composition_v0",
		"hex_count": _hex_records.size(),
		"hexes": hexes,
		"nodes": nodes,
		"meshes": meshes,
		"triangles": tris,
		"max_violation": snappedf(max_v, 0.0001),
		"zoom_normal": P_ZOOM,
		"zoom_dev_macro": ZOOM_MACRO,
		"shadows": "OFF",
	}
