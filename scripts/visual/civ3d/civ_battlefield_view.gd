extends Node3D

## CIV3D PRESENTATION (VISUAL ONLY): the battle seen as a Civ-style lit 3D
## tile diorama through ONE continuous perspective camera.
##
##   * ground: a lit heightfield (CivTerrainField) - every hex at its logical
##     position, flat centres, slopes at the borders, painterly terrain colour,
##     faint hex grid, roads/rivers, sepia "old map" for remembered hexes
##   * scenery: the existing approved GLB families (FullDevMapTransplant) seated
##     on the terrain height, lit by one sun with shadows
##   * unexplored space: parchment cloud shroud (civ_shroud.gdshader)
##   * units: the approved PNG formation cards (badges come in a later step)
##   * camera: the shell's Camera2D stays the input authority (pan, drag, WASD,
##     wheel zoom, reset); this node maps its position/zoom to a perspective
##     camera whose pitch eases with zoom. Zoomed out IS the strategic view.
##
## Same contract as BattlefieldCloseupView: this node only READS the board
## (cell_data, unit renderer nodes, fog truth, stronghold specs) and draws it.
## Gameplay, unit movement and its timing are untouched; picking is an exact
## ray / heightfield hit returned through screen_to_world().

const HexUtilsCls = preload("res://scripts/core/hex_utils.gd")
const RulesV2Cls = preload("res://scripts/rules_v2/rules_v2.gd")
const PresentationOrientationCls = preload("res://scripts/core/presentation_orientation.gd")
const ModeControllerCls = preload("res://scripts/visual/presentation_mode_controller.gd")
const Registry = preload("res://scripts/visual/hex_native/approved_asset_registry.gd")
const SoldierVariants = preload("res://scripts/visual/civ3d/civ_soldier_variants.gd")
const SoldierShader = preload("res://scripts/visual/civ3d/civ_soldier.gdshader")
const BlobShader = preload("res://scripts/visual/civ3d/civ_blob.gdshader")
const BadgeScript = preload("res://scripts/visual/civ3d/civ_unit_badge.gd")
const Formation3D = preload("res://scripts/visual/civ3d/civ_formation3d.gd")
const Cavalry3D = preload("res://scripts/visual/civ3d/civ_cavalry3d.gd")
const BattleFx = preload("res://scripts/visual/civ3d/civ_battle_fx.gd")
const MoraleSystemCls = preload("res://scripts/combat/morale_system.gd")
const HudSkin = preload("res://scripts/visual/civ3d/civ_hud_skin.gd")
var _hud_skin: Node = null
const BaseShader = preload("res://scripts/visual/closeup25d/closeup_base.gdshader")
const TerrainField = preload("res://scripts/visual/civ3d/civ_terrain_field.gd")
const TerrainShader = preload("res://scripts/visual/civ3d/civ_terrain.gdshader")
const ShroudShader = preload("res://scripts/visual/civ3d/civ_shroud.gdshader")
const StrictTransplant = preload("res://scripts/visual/full_dev_map_transplant.gd")

## Same presentation scale as the closeup (hex circumradius 4.5 units), so the
## approved GLB families keep their authored size.
const HEXR: float = 4.5
const S: float = HEXR / 24.0
const PLAY_R: int = 40
const OUTER_R: int = 85
const GRID_N: int = 171

## Camera. Zoom is the Camera2D zoom; at every zoom one screen px at the focus
## equals 1 / zoom world px horizontally, so drag-panning stays under the cursor.
const ZOOM_MIN: float = 1.6   # max zoom-out (user, 2026-11-04: kept at the framing of the reference screenshot)
const ZOOM_MAX: float = 4.0
const ZOOM_HOME: float = 1.6
const FOV: float = 30.0
const PITCH_FAR: float = 47.0   # flatter than the old 64, not as flat as 36 (user, 2026-11-04)
const PITCH_NEAR: float = 35.0   # was 40
const EDGE_SCROLL_PX: float = 6.0
const EDGE_SCROLL_SPEED: float = 900.0

const SHROUD_Y: float = 11.0
const CARD_BODY_H: float = 6.6

const OVERLAY_ORIGIN := Vector2(-1488.0, -1728.0)
const OVERLAY_SIZE := Vector2(2976.0, 3456.0)
const OVERLAY_SCALE: float = 0.75

var fwd: Vector3 = _forward3()

static func _forward3() -> Vector3:
	var f: Vector2 = PresentationOrientationCls.friendly_forward_world()
	return Vector3(f.x, 0.0, f.y)

var shell: Node = null
var cam2d: Camera2D = null
var cam: Camera3D = null
var sun: DirectionalLight3D = null
var strict_transplant: Node3D = null
## Set by PresentationModeController.
var mode_controller: Node = null

var terrain: RefCounted = null
var mat_ground: ShaderMaterial
var mat_shroud: ShaderMaterial
var mat_base: Dictionary = {}
var _hex_ring: ArrayMesh
var _cell_img: Image
var _cell_tex: ImageTexture
var _cell_dirty: bool = false
var _unit_cells: Dictionary = {}
var _fow_sig: int = -1
var _vis_fog: RefCounted = null    # fog recomputed from where the formations visually stand
var _vis_sig: int = -1
var _fow_cur: Dictionary = {}      # "q,r" -> shown state 0..1
var _fow_tgt: Dictionary = {}
var _ghosts: Dictionary = {}       # enemy id -> {"root": Node3D, "turn": int, "hex": Vector2i}: last known position of a lost contact
var _ghost_dead: Dictionary = {}   # enemy id -> record turn of a ghost whose hex was seen again (do not respawn that record)
var _ghost_mat: StandardMaterial3D = null
var _ghost_t: float = 0.0
var _tree_index: Dictionary = {}     # "q,r" (game hex) -> [{"node": Node3D, "base": Vector3, "cur": float}] forest / tree props of the baked map
var _tree_built: bool = false
var _fow_ever: Dictionary = {}     # cells the view has already shown as remembered (never darker than 0.5 again)
var _fow_timer: float = 0.0
var _units: Dictionary = {}
var _overlay_vp: SubViewport = null
var _lod_proxy := Camera3D.new() # ortho-size stand-in for the GLB LOD switches
var _lod_far_proxy := Camera3D.new() # always "far": batches keep their reduced LOD
var _saved_msaa: int = 0
var _cam_sig: Vector4 = Vector4.INF
var _time: float = 0.0
var _active: bool = false
var _hq_last: Vector2 = Vector2.INF

func _init() -> void:
	name = "CivBattlefieldView"

# ======================================================================= setup

func setup(p_shell: Node) -> void:
	shell = p_shell
	cam2d = shell.get("camera") as Camera2D
	var t0: int = Time.get_ticks_msec()
	var cells: Dictionary = shell.get("hex_grid").get("cell_data")
	terrain = TerrainField.new()
	terrain.call("setup", cells, S, PLAY_R)
	_build_cell_texture(cells)
	var bf_id: String = str((shell.get("_battlefield") as Dictionary).get("id", ""))
	var baked_path: String = "res://data/baked_maps/%s.scn" % bf_id
	var baked: Node3D = null
	if not bf_id.is_empty() and FileAccess.file_exists(baked_path):
		# Designed (map editor) map: the editor's own board + objects; flat ground, units seat at y=0.
		var bps: PackedScene = load(baked_path) as PackedScene
		baked = bps.instantiate() as Node3D if bps != null else null
	if baked != null:
		terrain.set("flat", true)
		# Transparent plane carries grid, hover/selection and the 2D gameplay overlay over the baked scene.
		mat_ground = ShaderMaterial.new()
		mat_ground.shader = load("res://scripts/visual/civ3d/civ_designed_overlay.gdshader") as Shader
		mat_ground.render_priority = 1
		mat_ground.set_shader_parameter("cell_tex", _cell_tex)
		mat_ground.set_shader_parameter("hex_px", 1.0 / S)
		var plane := PlaneMesh.new()
		plane.size = OVERLAY_SIZE * S
		var pmi := MeshInstance3D.new()
		pmi.name = "DesignedOverlayPlane"
		pmi.mesh = plane
		pmi.material_override = mat_ground
		pmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		pmi.position = Vector3((OVERLAY_ORIGIN.x + OVERLAY_SIZE.x * 0.5) * S, 0.14, (OVERLAY_ORIGIN.y + OVERLAY_SIZE.y * 0.5) * S)
		add_child(pmi)
		baked.name = "EditorMapBake"
		add_child(baked)
		print("[Civ3D] designed map scene %s" % baked_path)
	else:
		_build_ground()
	var t1: int = Time.get_ticks_msec()
	_cache_path = _scenery_cache_path()
	if baked != null:
		strict_transplant = Node3D.new()
		strict_transplant.name = "FullDevMapTransplant"
		add_child(strict_transplant)
		_strategy_swapped = true
		_cache_loaded = true
	elif FileAccess.file_exists(_cache_path):
		# reduced scenery saved by an earlier run of this exact layout
		var ps: PackedScene = load(_cache_path) as PackedScene
		strict_transplant = ps.instantiate() as Node3D if ps != null else null
	if strict_transplant != null:
		add_child(strict_transplant)
		_strategy_swapped = true
		_cache_loaded = true
	else:
		strict_transplant = StrictTransplant.new()
		add_child(strict_transplant)
		strict_transplant.setup(shell, S, {"ground": false, "lit": true, "height_fn": Callable(self, "_hex_seat_height"), "forest_variant_cap": 1})
		_hide_hex_decals(strict_transplant) # before shadows: the decals are the shadowless meshes
		_enable_shadows(strict_transplant)
		_setup_forest_lod()
	var t2: int = Time.get_ticks_msec()
	print("[Civ3D] scenery %s" % ("from cache " + _cache_path if _cache_loaded else "built from source assets"))
	_build_shroud()
	mat_shroud.set_shader_parameter("explored_blur", 1.0 if baked != null else 0.0)   # designed maps: Civ-style half blur
	_build_lighting()
	_build_camera()
	_build_overlay_viewport()
	_hex_ring = _make_hex_ring(0.95 * HEXR, 0.885 * HEXR)
	_build_base_materials()
	visible = false
	_overlay_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	print("[Civ3D] built in %d ms (terrain %d ms, scenery %d ms)" % [Time.get_ticks_msec() - t0, t1 - t0, t2 - t1])

func _exit_tree() -> void:
	if _active:
		apply_active(false)
	_lod_proxy.free()
	_lod_far_proxy.free()

## Seat height of a scenery family: the hex's flat plateau height.
func _hex_seat_height(q: int, r: int) -> float:
	return float(terrain.call("height_at", HexUtilsCls.hex_to_pixel(q, r)))

static func axial_dist(q: int, r: int) -> int:
	return (absi(q) + absi(r) + absi(q + r)) / 2

func _build_cell_texture(cells: Dictionary) -> void:
	_cell_img = Image.create(GRID_N, GRID_N, false, Image.FORMAT_RGBA8)
	for q in range(-OUTER_R, OUTER_R + 1):
		for r in range(-OUTER_R, OUTER_R + 1):
			var d: int = axial_dist(q, r)
			var t: int = -1
			if d <= PLAY_R:
				var c: Variant = cells.get("%d,%d" % [q, r])
				t = int(c.terrain) if c != null else 0
			elif d <= OUTER_R:
				t = 13
			var playable: int = 255 if d <= PLAY_R else 0
			_cell_img.set_pixel(q + OUTER_R, r + OUTER_R, Color8(maxi(t, 0), 255, 0, playable))
	_cell_tex = ImageTexture.create_from_image(_cell_img)

func _build_ground() -> void:
	mat_ground = ShaderMaterial.new()
	mat_ground.shader = TerrainShader
	mat_ground.set_shader_parameter("cell_tex", _cell_tex)
	mat_ground.set_shader_parameter("hex_px", 1.0 / S)
	var root := Node3D.new()
	root.name = "Ground"
	add_child(root)
	var tris: int = terrain.call("build_mesh", root, mat_ground)
	print("[Civ3D] ground %d triangles in %d chunks" % [tris, root.get_child_count()])

func _build_shroud() -> void:
	mat_shroud = ShaderMaterial.new()
	mat_shroud.shader = ShroudShader
	mat_shroud.render_priority = 20 # after scenery transparents (rice water), before units
	mat_shroud.set_shader_parameter("cell_tex", _cell_tex)
	mat_shroud.set_shader_parameter("hex_px", 1.0 / S)
	var plane := PlaneMesh.new()
	plane.size = Vector2(3200.0, 3200.0)
	var mi := MeshInstance3D.new()
	mi.name = "Shroud"
	mi.mesh = plane
	mi.material_override = mat_shroud
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.position.y = SHROUD_Y
	add_child(mi)

## ---- Performance: tree reduction ------------------------------------------
## Measured (tools/scenery_budget_probe.gd): the source trees are 75k-190k
## triangles each (LOD0), 7k-17k (LOD1), 0.6k-3k (LOD2); the forest alone was
## 6.8 billion triangles map-wide. From the strategy camera a tree is a few
## dozen pixels, so every tree draws a baked strategy LOD (<key>_lod3.glb,
## tools/make_tree_lod3_blender.py, ~25 % of LOD2) and forests keep 65 % of
## their trees, merged into regional MultiMeshes. LOD0 / LOD1 are never drawn.
const Lib = preload("res://scripts/visual/map_composition_v0/map_composition_library.gd")
const TREE_LOD3_DIR := "res://assets/map_composition_v0/forest_runtime_pilot/"
const FOREST_DENSITY: float = 0.65
const FOREST_CELL: float = 64.0 # 3D units (~6 hexes) per merged forest MultiMesh
## Shadows are dropped at strategic distance (invisible there, costly).
const SHADOW_OFF_DIST: float = 700.0
## Heavy scenery meshes (the AI-generated source assets) are swapped once for
## offline-reduced versions: tools/export_scenery_meshes.gd lists every unique
## mesh this view draws, tools/reduce_scenery_blender.py reduces it; the
## original surface materials are kept.
const STRATEGY_LOD_DIR := "res://assets/map_composition_v0/strategy_lod/"
var _strategy_swapped := false

func _swap_strategy_meshes() -> void:
	var mf := FileAccess.open(STRATEGY_LOD_DIR + "manifest.json", FileAccess.READ)
	if mf == null:
		return
	var manifest: Dictionary = JSON.parse_string(mf.get_as_text())
	var cache := {}
	var stats := [0, 0, 0] # swapped nodes, tris before, tris after
	_swap_walk(strict_transplant, manifest, cache, stats)
	print("[Civ3D] strategy meshes: %d nodes swapped, %d -> %d triangles" % stats)

func _swap_walk(n: Node, manifest: Dictionary, cache: Dictionary, stats: Array) -> void:
	var m: Mesh = null
	var count := 1
	if n is MultiMeshInstance3D and (n as MultiMeshInstance3D).multimesh:
		m = (n as MultiMeshInstance3D).multimesh.mesh
		count = (n as MultiMeshInstance3D).multimesh.instance_count
	elif n is MeshInstance3D:
		m = (n as MeshInstance3D).mesh
	if m != null:
		var key := "%s|%d|%d" % [m.resource_name, Lib.mesh_triangles(m), m.get_surface_count()]
		if manifest.has(key):
			var low: Mesh = _reduced_mesh(m, String(manifest[key]["file"]), cache)
			if low != null:
				stats[0] += 1
				stats[1] += Lib.mesh_triangles(m) * count
				stats[2] += Lib.mesh_triangles(low) * count
				if n is MultiMeshInstance3D:
					(n as MultiMeshInstance3D).multimesh.mesh = low
				else:
					(n as MeshInstance3D).mesh = low
	for c in n.get_children():
		_swap_walk(c, manifest, cache, stats)

func _reduced_mesh(orig: Mesh, file: String, cache: Dictionary) -> Mesh:
	if cache.has(file):
		return cache[file]
	var low: Mesh = null
	var doc := GLTFDocument.new()
	var st := GLTFState.new()
	if doc.append_from_file(ProjectSettings.globalize_path(STRATEGY_LOD_DIR + "out/" + file), st) == OK:
		var scene: Node = doc.generate_scene(st)
		var mis: Array = scene.find_children("*", "MeshInstance3D", true, false)
		if not mis.is_empty():
			low = (mis[0] as MeshInstance3D).mesh
			if low.get_surface_count() == orig.get_surface_count():
				for s in range(low.get_surface_count()):
					low.surface_set_material(s, orig.surface_get_material(s))
			else:
				low = null # material layout changed: keep the original
		scene.free()
	cache[file] = low
	return low

## ---- Scenery cache: build + reduce once, then load the result -------------
## The finished scenery (reduced meshes, merged forest) is saved as one scene,
## keyed by the live layout, so later runs skip the source assets entirely.
## Bump SCENERY_CACHE_VERSION whenever the scenery pipeline changes.
const SCENERY_CACHE_VERSION := "v5"
const SCENERY_CACHE_DIR := "user://civ3d_cache/"
var _cache_path := ""
var _cache_loaded := false

func _scenery_cache_path() -> String:
	var sig: String = StrictTransplant.layout_snapshot(shell) + "|" + SCENERY_CACHE_VERSION
	return SCENERY_CACHE_DIR + "scenery_%s.scn" % sig.sha256_text().substr(0, 16)

func _save_scenery_cache() -> void:
	if _cache_loaded or strict_transplant == null:
		return
	var t0 := Time.get_ticks_msec()
	_own_for_pack(strict_transplant, strict_transplant)
	var ps := PackedScene.new()
	if ps.pack(strict_transplant) != OK:
		push_warning("[Civ3D] scenery cache: pack failed")
		return
	DirAccess.make_dir_recursive_absolute(SCENERY_CACHE_DIR)
	var err := ResourceSaver.save(ps, _cache_path)
	print("[Civ3D] scenery cache saved %s (err %d, %d ms)" % [_cache_path, err, Time.get_ticks_msec() - t0])

static func _own_for_pack(n: Node, owner_node: Node) -> void:
	for c in n.get_children():
		if c is Node3D and not (c as Node3D).visible:
			continue # hidden source geometry: no LOD system revives it in a cached load
		c.owner = owner_node
		c.scene_file_path = "" # inline instanced GLB scenes into the cache
		_own_for_pack(c, owner_node)

## Beyond this camera distance unit animation pauses (badges carry the read).
const UNIT_ANIM_FAR: float = 520.0
const UNIT_ANIM_NEAR: float = 220.0
var _units_far := false


func _setup_forest_lod() -> void:
	var pilot: Object = strict_transplant.get("_tree_pilot")
	if pilot == null:
		return
	# Merge every hex chunk's LOD2 trees into regional MultiMeshes (one per tree
	# mesh part per FOREST_CELL square): ~20x fewer draw calls than per-hex.
	var swap := _tree_lod3_swap(pilot)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var groups: Dictionary = {} # key -> {mesh, mat, xforms}
	var chunks_n := 0
	var kept := 0
	for chunk in pilot.get("chunks"):
		chunks_n += 1
		for node in chunk[2]:
			var mmi: MultiMeshInstance3D = node
			var mm: MultiMesh = mmi.multimesh
			var gx: Transform3D = mmi.global_transform
			for i in range(mm.instance_count):
				if rng.randf() > FOREST_DENSITY:
					continue
				var t: Transform3D = gx * mm.get_instance_transform(i)
				var cell := Vector2i(floori(t.origin.x / FOREST_CELL), floori(t.origin.z / FOREST_CELL))
				var key := "%d|%d|%d,%d" % [mm.mesh.get_instance_id(), mmi.material_override.get_instance_id() if mmi.material_override else 0, cell.x, cell.y]
				if not groups.has(key):
					groups[key] = {"mesh": swap.get(mm.mesh, mm.mesh), "mat": mmi.material_override, "xf": []}
				(groups[key]["xf"] as Array).append(t)
				kept += 1
		for lod in range(3):
			for node in chunk[lod]:
				# detach now: the deferred cache save runs before queue_free lands
				# (v1 caches baked every LOD0 tree in: 6 billion triangles)
				var nd: Node = node
				if nd.get_parent() != null:
					nd.get_parent().remove_child(nd)
				nd.queue_free()
	var root := Node3D.new()
	root.name = "ForestMerged"
	# lives under the (scaled) transplant so the scenery caches as one scene;
	# the inverse keeps the merged instances in world space
	strict_transplant.add_child(root)
	root.transform = strict_transplant.transform.affine_inverse()
	for key in groups.keys():
		var g: Dictionary = groups[key]
		var xf: Array = g["xf"]
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = g["mesh"]
		mm.instance_count = xf.size()
		for i in range(xf.size()):
			mm.set_instance_transform(i, xf[i])
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.material_override = g["mat"]
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		root.add_child(mmi)
	# the pilot must never switch LODs again
	pilot.set("chunks", [])
	print("[Civ3D] forest: %d hex chunks -> %d regional MultiMeshes, %d trees (strategy LOD3 %d meshes, density %.0f%%)" % [chunks_n, groups.size(), kept, swap.size(), FOREST_DENSITY * 100.0])

## LOD2 template mesh -> baked LOD3 mesh (matched by mesh name inside each tree).
func _tree_lod3_swap(pilot: Object) -> Dictionary:
	var swap := {}
	var templates: Dictionary = pilot.get("_templates")
	for tkey in Lib.TREES:
		var entries: Array = templates.get("%s:2" % tkey, [])
		var path := ProjectSettings.globalize_path(TREE_LOD3_DIR + String(tkey) + "_lod3.glb")
		if entries.is_empty() or not FileAccess.file_exists(path):
			continue
		var doc := GLTFDocument.new()
		var st := GLTFState.new()
		if doc.append_from_file(path, st) != OK:
			continue
		var scene: Node = doc.generate_scene(st)
		var by_name := {}
		for mi in scene.find_children("*", "MeshInstance3D", true, false):
			by_name[String((mi as MeshInstance3D).mesh.resource_name)] = (mi as MeshInstance3D).mesh
			by_name[String(mi.name)] = (mi as MeshInstance3D).mesh
		for e in entries:
			var m: Mesh = e["mesh"]
			# "<key>_lod2_Mesh_N" pairs with "<key>_lod3_Mesh_N"
			var low: Mesh = by_name.get(String(m.resource_name).replace("_lod2_", "_lod3_"), null)
			if low != null:
				swap[m] = low
		scene.free()
	return swap

## The compositions lay flat hexagon decals (yards, forest floor, field
## patches) a little smaller than the grid hex: a hex inside every hex. The
## terrain shader already paints the ground, so they are hidden (user request).
static func _hide_hex_decals(node: Node) -> void:
	# matched by shape: a flat 6-triangle hexagon (Godot renames all but the
	# first "HexDecal" in a composition, so the name alone misses most)
	if node is MeshInstance3D:
		var m: Mesh = (node as MeshInstance3D).mesh
		var flat: bool = (node as MeshInstance3D).cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		if flat and m is ArrayMesh and m.get_surface_count() == 1 and (m as ArrayMesh).surface_get_array_len(0) == 18:
			(node as MeshInstance3D).visible = false
	for child in node.get_children():
		_hide_hex_decals(child)

static func _enable_shadows(node: Node) -> void:
	if node is GeometryInstance3D:
		(node as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	for child in node.get_children():
		_enable_shadows(child)

# ------------------------------------------------------------- light / camera

func _build_lighting() -> void:
	sun = DirectionalLight3D.new()
	sun.name = "Sun"
	# Light from behind the camera, upper left: the viewer sees the lit side of
	# every figure and tree, shadows fall up-screen and to the right.
	var right: Vector3 = fwd.cross(Vector3.UP).normalized()
	var dir: Vector3 = (right * 0.55 + fwd * 0.40 + Vector3.DOWN).normalized()
	sun.transform = Transform3D(Basis.looking_at(dir, Vector3.UP), Vector3.ZERO)
	sun.light_color = Color(1.0, 0.95, 0.86)
	sun.light_energy = 1.35
	sun.shadow_enabled = true
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS # 4 doubled shadow draw calls
	sun.directional_shadow_blend_splits = true
	sun.shadow_bias = 0.04
	sun.shadow_normal_bias = 1.2
	sun.shadow_blur = 1.2
	add_child(sun)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.70, 0.63, 0.49)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.78, 0.80, 0.86)
	env.ambient_light_energy = 0.62
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_exposure = 0.92
	env.ssao_enabled = true
	env.ssao_radius = 1.6
	env.ssao_intensity = 1.6
	env.fog_enabled = true
	env.fog_light_color = Color(0.74, 0.72, 0.64)
	env.fog_density = 0.00012
	env.fog_aerial_perspective = 0.25
	env.adjustment_enabled = true
	env.adjustment_saturation = 0.95
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

func _build_camera() -> void:
	cam = Camera3D.new()
	cam.name = "Camera3D"
	cam.fov = FOV
	add_child(cam)
	_lod_proxy.projection = Camera3D.PROJECTION_ORTHOGONAL
	_lod_far_proxy.projection = Camera3D.PROJECTION_ORTHOGONAL

func _update_camera() -> void:
	mat_ground.set_shader_parameter("select_pulse", 0.75 + 0.25 * sin(_time * 4.0))
	var f2: Vector2 = cam2d.global_position
	var z: float = clampf(cam2d.zoom.x, ZOOM_MIN, ZOOM_MAX)
	var vp: Vector2 = get_viewport().get_visible_rect().size
	var sig := Vector4(f2.x, f2.y, z, vp.x * 10000.0 + vp.y)
	if sig.is_equal_approx(_cam_sig):
		return
	_cam_sig = sig
	var t: float = clampf(log(z / ZOOM_MIN) / log(ZOOM_MAX / ZOOM_MIN), 0.0, 1.0)
	var pitch: float = deg_to_rad(lerpf(PITCH_FAR, PITCH_NEAR, t))
	var tan_h: float = tan(deg_to_rad(FOV * 0.5)) * vp.x / maxf(vp.y, 1.0)
	var dist: float = (vp.x / z * S * 0.5) / tan_h
	var focus := Vector3(f2.x * S, 0.0, f2.y * S)
	var pos: Vector3 = focus - fwd * cos(pitch) * dist + Vector3.UP * sin(pitch) * dist
	cam.near = maxf(0.5, dist * 0.04)
	cam.far = dist * 3.0 + 800.0
	cam.look_at_from_position(pos, focus, Vector3.UP)
	# shadows only around what the eye is on (they were doubling the scenery cost)
	sun.directional_shadow_max_distance = dist * 1.25
	sun.shadow_enabled = dist < SHADOW_OFF_DIST
	_lod_proxy.size = 2.0 * dist * tan(deg_to_rad(FOV * 0.5))
	if strict_transplant != null:
		# forest LOD is per chunk by distance (visibility ranges, set once); the
		# remaining batches keep their global swap
		# mountain-range / field batches stay on their reduced LOD at every zoom:
		# their close-up detail is invisible from the strategy camera
		_lod_far_proxy.size = 100000.0
		for key in ["_ground_batch", "_mountain_range_batch", "_agriculture_batch"]:
			var b: Object = strict_transplant.get(key)
			if b != null:
				b.call("update_for_camera", _lod_far_proxy)
		if not _strategy_swapped:
			_strategy_swapped = true
			_swap_strategy_meshes()
			call_deferred("_save_scenery_cache")
	_units_far = dist > UNIT_ANIM_FAR # applied per unit in _sync_units

func _edge_scroll(delta: float) -> void:
	if not get_window().has_focus() or cam2d == null:
		return
	var vp: Rect2 = get_viewport().get_visible_rect()
	var m: Vector2 = get_viewport().get_mouse_position()
	if not vp.has_point(m):
		return
	var d := Vector2.ZERO
	if m.x <= EDGE_SCROLL_PX: d.x -= 1.0
	elif m.x >= vp.size.x - EDGE_SCROLL_PX: d.x += 1.0
	if m.y <= EDGE_SCROLL_PX: d.y -= 1.0
	elif m.y >= vp.size.y - EDGE_SCROLL_PX: d.y += 1.0
	if d == Vector2.ZERO:
		return
	var z: float = maxf(cam2d.zoom.x, 0.01)
	var tp: Vector2 = cam2d.get("target_position")
	cam2d.set("target_position", tp + d.normalized().rotated(cam2d.rotation) * EDGE_SCROLL_SPEED * delta / z)
	cam2d.call("_clamp_bounds")

func _hq_world() -> Vector2:
	var ur: Node = shell.get("unit_renderer")
	var id: String = str(shell.get("_blue_hq_id"))
	if id != "" and ur and ur.has_method("get_unit_node"):
		var n: Node2D = ur.call("get_unit_node", id) as Node2D
		if n and is_instance_valid(n):
			_hq_last = n.position
			return _hq_last
	if _hq_last == Vector2.INF and ur:
		for u in (ur.call("get_all_units") as Array):
			if str(u.get("class", "")) == "hq" and str(u.get("faction", "")) == "blue":
				_hq_last = HexUtilsCls.hex_to_pixel(int(u.get("q", 0)), int(u.get("r", 0)))
	return _hq_last if _hq_last != Vector2.INF else Vector2.ZERO

# ----------------------------------------------------------- 2D layer handling

func on_world_node_added(n: Node) -> void:
	var ur: Node = shell.get("unit_renderer")
	if _active and n is Label and n.get_parent() == ur:
		call_deferred("_mirror_floating_text", n)

func _mirror_floating_text(lbl: Label) -> void:
	if not is_instance_valid(lbl):
		return
	var w: Vector2 = lbl.position + lbl.pivot_offset
	var l3 := Label3D.new()
	l3.text = lbl.text
	l3.modulate = lbl.get_theme_color("font_color")
	l3.outline_modulate = Color(0, 0, 0, 1)
	l3.font_size = 40
	l3.outline_size = 10
	l3.pixel_size = 0.00045
	l3.fixed_size = true
	l3.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l3.no_depth_test = true
	l3.render_priority = 5
	if lbl.text.begins_with("-"):   # only damage numbers are blows: turn skip / rest / build / fortify texts are not
		_combat_reaction(w)
	var p: Vector3 = _ground3(w) + Vector3(0, CARD_BODY_H * 1.4, 0)
	l3.position = p
	add_child(l3)
	var tw: Tween = create_tween().set_parallel(true)
	tw.tween_property(l3, "position", p + Vector3(0, 1.5, 0), 0.9).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tw.tween_property(l3, "modulate:a", 0.0, 0.6).set_delay(0.35)
	tw.chain().tween_callback(l3.queue_free)

## Floating combat text marks a unit taking a hit: its soldiers flinch and the
## adjacent enemy formations play an attack (presentation only).
## V2 요새화: the soldiers work in place (their strike clip, repeated) while the palisade goes up.
func _busy(uid: String, secs: float) -> void:
	if _units.has(uid):
		_units[uid]["busy_until"] = _time + secs

func v2_play_work(uid: String, times: int = 4) -> void:
	if not _units.has(uid):
		return
	var f3d: Node3D = _units[uid]["f3d"]
	if f3d == null:
		return
	_busy(uid, 0.8 * float(times) + 1.5)
	for k in range(times):
		get_tree().create_timer(0.8 * float(k)).timeout.connect(func():
			if is_instance_valid(f3d):
				f3d.call("play_attack", Vector3(0.0, 0.0, 0.2)))

## V2 요새화: trampled-dust bursts at the centre and round the ring, a beat apart, as the palisade goes up.
func v2_fortify_dust(uid: String, ring_r_px: float = 23.0) -> void:
	if not _units.has(uid):
		return
	var root_n: Node3D = _units[uid]["root"]
	if not is_instance_valid(root_n):
		return
	var size: float = float(FIGURE_H_DEFAULT) * S
	var c: Vector3 = root_n.position
	BattleFx.impact(self, c, size)
	for i in range(6):
		var a: float = deg_to_rad(30.0 + 60.0 * float(i))
		var p: Vector3 = c + Vector3(cos(a), 0.0, sin(a)) * ring_r_px * S * 0.85
		get_tree().create_timer(0.2 + 0.22 * float(i)).timeout.connect(func():
			if is_instance_valid(self):
				BattleFx.impact(self, p, size * 0.8))

## V2 휴식: the unit's men lie down and a stream of Z's rises over them while it rests.
var _v2_zzz: Dictionary = {}   # unit id -> Node3D emitter

func v2_set_resting(uid: String, on: bool) -> void:
	if not _units.has(uid):
		return
	var d: Dictionary = _units[uid]
	_busy(uid, 2.5)
	var f3d: Node3D = d["f3d"]
	if f3d != null and f3d.has_method("set_resting"):
		f3d.call("set_resting", on)
	if on and not _v2_zzz.has(uid):
		var em := Node3D.new()
		em.name = "ZZZ_" + uid
		(d["root"] as Node3D).add_child(em)
		em.position = Vector3(0.0, 1.0, 0.0)
		var tmr := Timer.new()
		tmr.wait_time = 0.75
		tmr.autostart = true
		em.add_child(tmr)
		var k := [0]
		tmr.timeout.connect(func():
			var glyph: String = ["Z", "z", "Z"][k[0] % 3]
			var size_k: float = [1.0, 0.7, 1.3][k[0] % 3]
			k[0] += 1
			var l3 := Label3D.new()
			l3.text = glyph
			l3.modulate = Color(0.78, 0.88, 1.0, 1.0)
			l3.outline_modulate = Color(0.05, 0.08, 0.2, 1.0)
			l3.font_size = int(64.0 * size_k)
			l3.outline_size = 14
			l3.pixel_size = 0.03
			l3.billboard = BaseMaterial3D.BILLBOARD_ENABLED
			l3.no_depth_test = true
			l3.render_priority = 6
			em.add_child(l3)
			l3.position = Vector3(0.25 * float(k[0] % 3), 0.0, 0.0)
			var tw := create_tween().set_parallel(true)
			tw.tween_property(l3, "position", l3.position + Vector3(0.9, 2.4, 0.0), 1.9)
			tw.tween_property(l3, "modulate:a", 0.0, 0.7).set_delay(1.0)
			tw.chain().tween_callback(l3.queue_free))
		_v2_zzz[uid] = em
	elif not on and _v2_zzz.has(uid):
		(_v2_zzz[uid] as Node).queue_free()
		_v2_zzz.erase(uid)

func _combat_reaction(w: Vector2) -> void:
	var hit_id := ""
	var best := 30.0
	for id in _units.keys():
		var d: Dictionary = _units[id]
		var lp: Vector2 = d.get("board_pos", d["last_pos"])
		if lp != Vector2.INF and lp.distance_to(w) < best:
			best = lp.distance_to(w)
			hit_id = id
	if hit_id == "":
		return
	var hd: Dictionary = _units[hit_id]
	var attacked := false
	for id in _units.keys():
		var d: Dictionary = _units[id]
		var reach: float = 100.0 if str(d.get("cls", "")) == "archer" else 60.0   # archers shoot from up to 2 hexes (V2)
		if id != hit_id and d["faction"] != hd["faction"] and d["f3d"] != null and (d.get("board_pos", d["last_pos"]) as Vector2).distance_to(hd.get("board_pos", hd["last_pos"])) < reach:
			# sortie / charge / volley toward the unit that was hit; it flinches
			# (and its casualties fall) when the blow actually lands
			var f3d: Node3D = d["f3d"]
			d["busy_until"] = _time + 5.0
			hd["busy_until"] = _time + 7.5
			var to_target: Vector3 = (hd["root"] as Node3D).position - (d["root"] as Node3D).position
			if f3d.has_signal("struck"):
				f3d.connect("struck", func(at_local: Vector3): _impact(hd, to_local(f3d.global_transform * at_local)), CONNECT_ONE_SHOT)
				attacked = true
			f3d.call("play_attack", to_target)
	if attacked:
		hd["hold_strength_until"] = _time + 7.0
	else:
		_impact(hd, (hd["root"] as Node3D).position)

## A blow lands on a unit: impact burst at the contact point, the men flinch,
## and the board's casualties are allowed to fall.
func _impact(hd: Dictionary, at: Vector3) -> void:
	hd["hold_strength_until"] = 0.0
	var root: Node3D = hd["root"]
	if not is_instance_valid(root) or not root.visible:
		return
	# three bursts along the contact front, a beat apart
	var size: float = float(FIGURE_H_DEFAULT) * S
	var across: Vector3 = fwd.cross(Vector3.UP).normalized()
	for k in range(3):
		var p: Vector3 = at + across * (float(k) - 1.0) * 1.6 * size * 0.5
		p.y = _ground3(Vector2(p.x, p.z) / S).y
		if k == 1:
			BattleFx.impact(self, p, size)
		else:
			get_tree().create_timer(0.08 + 0.1 * k).timeout.connect(func(): BattleFx.impact(self, p, size * 0.8))
	hd["busy_until"] = _time + 4.0
	if hd["f3d"] != null:
		(hd["f3d"] as Node3D).call("play_hit")

func _build_overlay_viewport() -> void:
	_overlay_vp = SubViewport.new()
	_overlay_vp.name = "CivOverlay"
	_overlay_vp.world_2d = get_viewport().world_2d
	_overlay_vp.transparent_bg = true
	_overlay_vp.disable_3d = true
	_overlay_vp.size = Vector2i(int(OVERLAY_SIZE.x * OVERLAY_SCALE), int(OVERLAY_SIZE.y * OVERLAY_SCALE))
	_overlay_vp.canvas_cull_mask = ModeControllerCls.LAYER_OVERLAY
	_overlay_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_overlay_vp.canvas_item_default_texture_filter = Viewport.DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_LINEAR
	_overlay_vp.canvas_transform = Transform2D(0.0, Vector2(OVERLAY_SCALE, OVERLAY_SCALE), 0.0, -OVERLAY_ORIGIN * OVERLAY_SCALE)
	add_child(_overlay_vp)
	mat_ground.set_shader_parameter("overlay_tex", _overlay_vp.get_texture())
	mat_ground.set_shader_parameter("overlay_origin", OVERLAY_ORIGIN)
	mat_ground.set_shader_parameter("overlay_size", OVERLAY_SIZE)

## Visible world rect for 2D overlay culling: the whole board.
func visible_world_rect() -> Rect2:
	return Rect2(OVERLAY_ORIGIN, OVERLAY_SIZE)

# ------------------------------------------------------------------------ units

func _ground3(w: Vector2) -> Vector3:
	return Vector3(w.x * S, float(terrain.call("height_at", w)), w.y * S)

func _make_hex_ring(r_out: float, r_in: float) -> ArrayMesh:
	var verts: Array[Vector2] = [
		Vector2(-24.0, 0.0), Vector2(-12.0, -21.0), Vector2(12.0, -21.0),
		Vector2(24.0, 0.0), Vector2(12.0, 21.0), Vector2(-12.0, 21.0),
	]
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for k in range(6):
		var p0: Vector2 = verts[k]
		var p1: Vector2 = verts[(k + 1) % 6]
		var o0 := Vector3(p0.x, 0.0, p0.y) * (r_out / 24.0)
		var o1 := Vector3(p1.x, 0.0, p1.y) * (r_out / 24.0)
		var i0 := Vector3(p0.x, 0.0, p0.y) * (r_in / 24.0)
		var i1 := Vector3(p1.x, 0.0, p1.y) * (r_in / 24.0)
		for v in [[Vector3.ZERO, 0.0], [i0, 0.0], [i1, 0.0],
				[i0, 1.0], [o0, 1.0], [o1, 1.0],
				[i0, 1.0], [o1, 1.0], [i1, 1.0]]:
			st.set_uv(Vector2(v[1], 0.0))
			st.add_vertex(v[0])
	return st.commit()

func _build_base_materials() -> void:
	for key in ["blue", "red", "blue_sel", "red_sel", "blue_hov", "red_hov"]:
		var m := ShaderMaterial.new()
		m.shader = BaseShader
		m.render_priority = 2
		var col: Color = Color(0.32, 0.58, 1.0) if key.begins_with("blue") else Color(1.0, 0.34, 0.24)
		# Outline only: the hex's own terrain must stay readable under a unit.
		m.set_shader_parameter("fill_alpha", 0.0)
		m.set_shader_parameter("rim_alpha", 0.8)
		if key.ends_with("_sel"):
			col = Color(1.0, 0.82, 0.35)
			m.set_shader_parameter("fill_alpha", 0.10)
		if key.ends_with("_hov"):
			m.set_shader_parameter("fill_alpha", 0.06)
		m.set_shader_parameter("base_color", col)
		mat_base[key] = m

## ---- Formations ------------------------------------------------------------
## One unit = one hex: its soldiers stand INSIDE the hex as separate figures in
## two ranks facing the enemy (screen-up), each an individual of the class
## (CivSoldierVariants). Offsets are world px in the screen-aligned frame
## (x = screen right, y = forward / away from the camera). The ranks hold the
## front two thirds of the hex; the back third stays open so the hex's own
## terrain (forest, mountain, village, fields) still reads under a unit.
const RANKS_INF: Array[Vector2] = [
	Vector2(-8.5, 1.5), Vector2(0.0, 2.0), Vector2(8.5, 1.5),
	Vector2(-13.0, -8.0), Vector2(-4.3, -8.5), Vector2(4.3, -8.0), Vector2(13.0, -8.5),
]
const RANKS_CAV: Array[Vector2] = [
	Vector2(-6.0, 1.5), Vector2(6.0, 2.0),
	Vector2(-11.5, -8.0), Vector2(0.0, -8.5), Vector2(11.5, -8.0),
]
const RANKS_SCOUT: Array[Vector2] = [Vector2(-6.0, 1.0), Vector2(-1.0, -8.5), Vector2(8.0, -7.0)]
const RANKS_SIEGE: Array[Vector2] = [Vector2(-8.0, -5.0), Vector2(8.0, -6.0)]
const RANKS_1: Array[Vector2] = [Vector2(0.0, -4.0)]
const RANK_SHIFT := Vector2.ZERO
## Figure height (world px) per class; cavalry / hq read larger.
const FIGURE_H := {"cavalry": 14.5, "hq": 20.0, "supply": 15.0, "siege": 13.5}
const FIGURE_H_DEFAULT: float = 12.5
const BADGE_Y_PAD: float = 0.5 # 3D units above the tallest figure

var _soldier_mats: Dictionary = {}
var _quad_feet: QuadMesh = null
var _blob_mesh: PlaneMesh = null
var _blob_mat: ShaderMaterial = null
var _badge_layer: CanvasLayer = null
## V2: screen-space nudge of a unit's badge so it sits beside the icon row of the artifacts on its hex.
var v2_badge_shift: Dictionary = {}

static func _ranks_for(cls: String) -> Array[Vector2]:
	match cls:
		"cavalry": return RANKS_CAV
		"scout", "scouts": return RANKS_SCOUT
		"siege": return RANKS_SIEGE
		"hq", "supply": return RANKS_1
	return RANKS_INF

func _soldier_mat(res: String) -> Dictionary:
	if _soldier_mats.has(res):
		return _soldier_mats[res]
	var src: Dictionary = SoldierVariants.source(res)
	var m := ShaderMaterial.new()
	m.shader = SoldierShader
	m.set_shader_parameter("tex", src["texture"])
	m.set_shader_parameter("regions", src["regions"])
	m.render_priority = 30 # after the shroud (20); units are only shown where visible
	var e := {"mat": m, "aspect": float(src["aspect"])}
	_soldier_mats[res] = e
	return e

func _ensure_formation_assets() -> void:
	if _quad_feet != null:
		return
	_quad_feet = QuadMesh.new()
	_quad_feet.size = Vector2.ONE
	_quad_feet.center_offset = Vector3(0.0, 0.5, 0.0)
	_blob_mesh = PlaneMesh.new()
	_blob_mesh.size = Vector2.ONE
	_blob_mat = ShaderMaterial.new()
	_blob_mat.shader = BlobShader
	_blob_mat.render_priority = 25
	_badge_layer = CanvasLayer.new()
	_badge_layer.name = "CivUnitBadges"
	_badge_layer.layer = 5 # above the world, under the HUD (30)
	_badge_layer.visible = _active
	add_child(_badge_layer)

func _make_unit(u: Dictionary) -> Dictionary:
	_ensure_formation_assets()
	var id: String = str(u.get("id", ""))
	var cls: String = str(u.get("class", "infantry"))
	var faction: String = str(u.get("faction", "blue"))
	var root := Node3D.new()
	root.name = "U_" + id
	add_child(root)
	var sm: Dictionary = _soldier_mat(Registry.unit(cls, faction))
	var ranks: Array[Vector2] = _ranks_for(cls)
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(id)
	var fig_h: float = float(FIGURE_H.get(cls, FIGURE_H_DEFAULT)) * S
	var soldiers: Array = []
	for i in range(ranks.size()):
		var jit := Vector2(rng.randf_range(-1.2, 1.2), rng.randf_range(-1.0, 1.0))
		soldiers.append({"off": ranks[i] + jit + RANK_SHIFT, "h": fig_h * rng.randf_range(0.95, 1.05), "vary": SoldierVariants.random_params(rng)})
	var f3d: Node3D = null
	if Cavalry3D.supports(cls):
		# mounted: rigged horse + rider (cavalry spear, general dao + 軍 banner)
		f3d = Cavalry3D.new()
	elif Formation3D.supports(cls):
		# lit 3D soldiers with mocap
		f3d = Formation3D.new()
	if f3d != null:
		# blue faces the enemy side (screen-up), red faces back
		root.add_child(f3d)
		f3d.call("setup", cls, faction, soldiers.size(), fig_h * 0.95, fwd if faction == "blue" else -fwd, hash(id))
		f3d.call("set_far", _units_far)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = _quad_feet
	mm.instance_count = soldiers.size()
	var figs := MultiMeshInstance3D.new()
	figs.visible = f3d == null
	figs.multimesh = mm
	figs.material_override = sm["mat"]
	figs.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	figs.extra_cull_margin = 4.0
	root.add_child(figs)
	var bm := MultiMesh.new()
	bm.transform_format = MultiMesh.TRANSFORM_3D
	bm.mesh = _blob_mesh
	bm.instance_count = soldiers.size()
	var blobs := MultiMeshInstance3D.new()
	blobs.visible = f3d == null # 3D soldiers cast real shadows
	blobs.multimesh = bm
	blobs.material_override = _blob_mat
	blobs.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(blobs)
	var base := MeshInstance3D.new()
	base.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	base.mesh = _hex_ring
	base.material_override = mat_base[faction]
	base.position.y = 0.06
	base.visible = false # user: no hex-inside-a-hex ring (the ground shader marks selection / hover)
	root.add_child(base)
	var badge: Control = BadgeScript.new()
	badge.set("unit_class", cls)
	badge.set("faction", faction)
	_badge_layer.add_child(badge)
	return {"root": root, "base": base, "badge": badge, "mm": mm, "bm": bm, "soldiers": soldiers,
		"aspect": float(sm["aspect"]), "top": -fig_h * 0.5, "faction": faction,
		"state": "", "placed_at": Vector2.INF, "f3d": f3d, "last_pos": Vector2.INF, "moving_until": 0.0, "cls": cls,
		"busy_until": _time + 1.5, "frozen": false}

## Re-seats every figure on the terrain under it (only when the unit moved).
func _place_formation(d: Dictionary, w: Vector2) -> void:
	if (d["placed_at"] as Vector2).is_equal_approx(w):
		return
	d["placed_at"] = w
	var f := Vector2(fwd.x, fwd.z).normalized()
	var right3: Vector3 = fwd.cross(Vector3.UP)
	var rt := Vector2(right3.x, right3.z).normalized() # screen right in world px
	var y0: float = float(terrain.call("height_at", w))
	var mm: MultiMesh = d["mm"]
	var bm: MultiMesh = d["bm"]
	var aspect: float = d["aspect"]
	var soldiers: Array = d["soldiers"]
	var pts: Array = []
	for i in range(soldiers.size()):
		var s: Dictionary = soldiers[i]
		var o: Vector2 = s["off"]
		var wp: Vector2 = w + rt * o.x + f * o.y
		var y: float = float(terrain.call("height_at", wp)) - y0
		var p := Vector3((wp.x - w.x) * S, y, (wp.y - w.y) * S)
		var h: float = s["h"]
		mm.set_instance_transform(i, Transform3D(Basis().scaled(Vector3(h * aspect, h, 1.0)), p))
		mm.set_instance_custom_data(i, s["vary"])
		bm.set_instance_transform(i, Transform3D(Basis().scaled(Vector3(h * 0.62, 1.0, h * 0.34)), p + Vector3(0.0, 0.07, 0.0)))
		pts.append(p)
	if d["f3d"] != null:
		(d["f3d"] as Node3D).call("place", pts)

## ---- Marching: the 3D troops follow the board at a walkable pace ----------
## The board moves a unit one hex in ~0.12 s (~65 units / s); legs manage
## ~1.5-3.5. The figures follow the board's path at march speed instead
## (feet planted); the board, picking and rules never wait for them. Very
## long backlogs snap (load, teleport-like jumps).
const MARCH_FOOT: float = 3.0      # units / s (a quick march, clip rate ~2)
const MARCH_FOOT_MAX: float = 3.7  # catching up on a long route (a jog)
const MARCH_HORSE: float = 5.5     # trot
const MARCH_HORSE_MAX: float = 8.5 # gallop
const MARCH_SNAP_HEXES: float = 9.0
var _frame_dt := 0.0

func _follow(d: Dictionary, target: Vector2) -> Vector2:
	if not d.has("shown") or _frame_dt <= 0.0:
		d["shown"] = target
		d["trail"] = []
		return target
	var trail: Array = d["trail"]
	var tail: Vector2 = trail.back() if not trail.is_empty() else d["shown"]
	if target.distance_to(tail) > 1.0:
		trail.append(target) # the board's path, sampled as it animates
	var shown: Vector2 = d["shown"]
	var backlog: float = 0.0
	var prev: Vector2 = shown
	for p in trail:
		backlog += prev.distance_to(p)
		prev = p
	var hex_px: float = HexUtilsCls.hex_to_pixel(1, 0).distance_to(HexUtilsCls.hex_to_pixel(0, 0))
	if backlog > MARCH_SNAP_HEXES * hex_px:
		trail.clear()
		d["shown"] = target
		return target
	var horse: bool = d["f3d"] != null and Cavalry3D.supports(str(d.get("cls", "")))
	var v: float = MARCH_HORSE if horse else MARCH_FOOT
	var vmax: float = MARCH_HORSE_MAX if horse else MARCH_FOOT_MAX
	v = lerpf(v, vmax, clampf((backlog / hex_px - 1.0) / 2.0, 0.0, 1.0)) # hurry on long routes
	var budget: float = v / S * _frame_dt
	while budget > 0.0 and not trail.is_empty():
		var nxt: Vector2 = trail[0]
		var dd: float = shown.distance_to(nxt)
		if dd <= budget:
			shown = nxt
			budget -= dd
			trail.pop_front()
		else:
			shown += (nxt - shown) / dd * budget
			budget = 0.0
	d["shown"] = shown
	return shown

## ---- V2 promotion: no death animation for the swap; a golden pillar of light, a rising ring and a salute instead ----
func v2_promote_begin(uid: String) -> void:
	if _units.has(uid):
		_units[uid]["promoting"] = true

func v2_promote_fx(uid: String, tries: int = 0) -> void:
	if not _units.has(uid) or bool((_units[uid] as Dictionary).get("promoting", false)):
		if tries < 20:
			get_tree().create_timer(0.1).timeout.connect(func(): v2_promote_fx(uid, tries + 1))
		return
	var d: Dictionary = _units[uid]
	var root_n: Node3D = d["root"]
	if not is_instance_valid(root_n):
		return
	var size: float = float(FIGURE_H_DEFAULT) * S
	var c: Vector3 = root_n.position
	var mat: StandardMaterial3D = BattleFx._billboard_mat(true)
	var pil := BattleFx._particles(40, 1.3, mat, size * 0.55)
	pil.direction = Vector3.UP
	pil.spread = 8.0
	pil.initial_velocity_min = size * 2.2
	pil.initial_velocity_max = size * 3.6
	pil.gravity = Vector3.ZERO
	pil.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	pil.emission_sphere_radius = size * 0.8
	pil.color_ramp = BattleFx._ramp(Color(1.0, 0.92, 0.55, 0.9), Color(1.0, 0.78, 0.3, 0.0))
	pil.position = c + Vector3(0.0, size * 0.1, 0.0)
	add_child(pil)
	pil.emitting = true
	pil.visible = false
	get_tree().create_timer(0.05).timeout.connect(func(): if is_instance_valid(pil): pil.visible = true)
	get_tree().create_timer(2.0).timeout.connect(func(): if is_instance_valid(pil): pil.queue_free())
	var ring := MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = size * 2.3
	tm.outer_radius = size * 2.55
	ring.mesh = tm
	var rm := StandardMaterial3D.new()
	rm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	rm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	rm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	rm.albedo_color = Color(1.0, 0.85, 0.4, 0.9)
	ring.material_override = rm
	ring.position = c + Vector3(0.0, size * 0.1, 0.0)
	ring.scale = Vector3(0.5, 1.0, 0.5)
	add_child(ring)
	var tw := create_tween().set_parallel(true)
	tw.tween_property(ring, "position:y", c.y + size * 4.0, 1.2).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_property(ring, "scale", Vector3(1.0, 1.0, 1.0), 1.2)
	tw.tween_property(rm, "albedo_color:a", 0.0, 1.2)
	tw.chain().tween_callback(ring.queue_free)
	root_n.scale = Vector3(0.82, 0.82, 0.82)
	create_tween().tween_property(root_n, "scale", Vector3.ONE, 0.5).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	d["busy_until"] = _time + 2.5
	if d["f3d"] != null:
		(d["f3d"] as Node3D).call("play_attack", Vector3(0.0, 0.0, 0.2))

## ---- Wading: a formation in a river hex sinks to the hips and throws up splashes ----
const WADE_DEPTH: float = 0.38     # x figure height the men sink

func _terrain_id_at_world(w: Vector2) -> int:
	var h: Vector2i = HexUtilsCls.pixel_to_hex(w)
	if abs(h.x) > OUTER_R or abs(h.y) > OUTER_R:
		return 0
	return _cell_img.get_pixel(h.x + OUTER_R, h.y + OUTER_R).r8

func _splash(pos: Vector3, size: float) -> void:
	var mat: StandardMaterial3D = BattleFx._billboard_mat(true)
	var sp := BattleFx._particles(16, 0.7, mat, size * 0.25)
	sp.direction = Vector3.UP
	sp.spread = 55.0
	sp.initial_velocity_min = size * 1.2
	sp.initial_velocity_max = size * 2.6
	sp.gravity = Vector3(0, -size * 7.0, 0)
	sp.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	sp.emission_sphere_radius = size * 0.9
	sp.color_ramp = BattleFx._ramp(Color(0.85, 0.95, 1.0, 0.85), Color(0.6, 0.8, 0.95, 0.0))
	sp.position = pos + Vector3(0.0, size * 0.1, 0.0)
	add_child(sp)
	sp.emitting = true
	sp.visible = false
	get_tree().create_timer(0.05).timeout.connect(func(): if is_instance_valid(sp): sp.visible = true)
	get_tree().create_timer(1.2).timeout.connect(func(): if is_instance_valid(sp): sp.queue_free())

func _sync_wading(d: Dictionary, delta: float) -> void:
	var f3d: Node3D = d["f3d"]
	if f3d == null:
		return
	var rn: Node3D = d["root"]
	var in_water: bool = _terrain_id_at_world(Vector2(rn.position.x / S, rn.position.z / S)) == 7
	var cls_h: float = float(FIGURE_H.get(str(d.get("cls", "")), FIGURE_H_DEFAULT)) * S
	var target: float = -cls_h * WADE_DEPTH if in_water else 0.0
	f3d.position.y = lerpf(f3d.position.y, target, clampf(delta * 8.0, 0.0, 1.0))
	if in_water and _time >= float(d.get("splash_at", 0.0)):
		d["splash_at"] = _time + 0.28
		var jitter := Vector3(randf_range(-1.0, 1.0), 0.0, randf_range(-1.0, 1.0)) * cls_h * 1.2
		_splash(rn.position + jitter, cls_h)

## Live 3D portrait for the unit card: a few figures of the class in a small own-world viewport (idle animation running).
func build_portrait(cls: String, faction: String, px: Vector2i) -> Control:
	_ensure_formation_assets()
	var cont := SubViewportContainer.new()
	cont.stretch = true
	cont.custom_minimum_size = Vector2(px)
	cont.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var vp := SubViewport.new()
	vp.size = px
	vp.own_world_3d = true
	vp.transparent_bg = true
	vp.msaa_3d = Viewport.MSAA_4X
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	cont.add_child(vp)
	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.62, 0.64, 0.7)
	env.ambient_light_energy = 0.9
	var we := WorldEnvironment.new()
	we.environment = env
	vp.add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-38.0, -28.0, 0.0)
	sun.light_energy = 1.25
	vp.add_child(sun)
	var fig_h: float = float(FIGURE_H.get(cls, FIGURE_H_DEFAULT)) * S
	var ranks: Array[Vector2] = _ranks_for(cls)
	var n: int = mini(ranks.size(), 3 if cls != "hq" else 1)
	var f3d: Node3D = null
	var look_dir := Vector3(0.0, 0.0, 1.0)
	if Cavalry3D.supports(cls):
		f3d = Cavalry3D.new()
		look_dir = Vector3(1.0, 0.0, 0.0)
	elif Formation3D.supports(cls):
		f3d = Formation3D.new()
	if f3d == null:
		cont.queue_free()
		return null
	vp.add_child(f3d)
	f3d.call("setup", cls, faction, n, fig_h * 0.95, look_dir, hash(cls))
	if f3d.has_method("set_far"):
		f3d.call("set_far", false)
	var pts: Array = []
	var cx: float = 0.0
	for i in range(n):
		cx += ranks[i].x
	cx /= float(maxi(1, n))
	for i in range(n):
		var o: Vector2 = ranks[i]
		pts.append(Vector3((o.x - cx) * S * 0.62, 0.0, (o.y + 4.0) * S * 0.62))
	f3d.call("place", pts)
	var cam := Camera3D.new()
	cam.fov = 30.0 if cls != "hq" else 34.0
	cam.transform = Transform3D(Basis(), Vector3(0.0, fig_h * 0.62, fig_h * (3.1 if cls != "hq" else 4.5))).looking_at(Vector3(0.0, fig_h * (0.40 if cls != "hq" else 1.23), 0.0), Vector3.UP)
	vp.add_child(cam)
	return cont

## Unit badges are drawn this much bigger than their design size (they may cover the formation a little).
var badge_mult: float = 1.0

func _sync_units() -> void:
	var ur: Node = shell.get("unit_renderer")
	if ur == null:
		return
	var list: Array = ur.call("get_all_units")
	var seen: Dictionary = {}
	var sel_id: String = str(ur.call("get_selected_unit_id")) if ur.has_method("get_selected_unit_id") else ""
	var hov_id: String = str(ur.call("get_hovered_unit_id")) if ur.has_method("get_hovered_unit_id") else ""
	var cells: Dictionary = {}
	var sel_hex := Vector2(9999, 9999)
	var z: float = cam2d.zoom.x
	var compact: bool = z < 0.85
	var badge_scale: float = clampf(0.62 + 0.38 * (z - 0.3) / 1.7, 0.62, 1.0) * badge_mult
	for u in list:
		var id: String = str(u.get("id", ""))
		var n2: Node2D = ur.call("get_unit_node", id) as Node2D
		if n2 == null or not is_instance_valid(n2):
			continue
		seen[id] = true
		if not _units.has(id):
			_units[id] = _make_unit(u)
		var d: Dictionary = _units[id]
		var vis: bool = n2.is_visible_in_tree() and n2.modulate.a > 0.05
		var root: Node3D = d["root"]
		var badge: Control = d["badge"]
		root.visible = vis
		if not vis:
			badge.visible = false
			continue
		d["board_pos"] = n2.position
		var w_shown: Vector2 = _follow(d, n2.position) if d["f3d"] != null else n2.position
		root.position = _ground3(w_shown)
		_place_formation(d, w_shown)
		if d["f3d"] != null:
			# animation LOD: off-screen or strategic-distance formations freeze
			var cam_d: float = cam.global_position.distance_to(root.position)
			var far: bool = cam_d > UNIT_ANIM_FAR or not cam.is_position_in_frustum(root.position + Vector3(0.0, 1.0, 0.0))
			if far != bool(d.get("far", false)):
				d["far"] = far
				(d["f3d"] as Node3D).call("set_far", far)
			# near: every frame; mid distance: 12 updates / s
			var rate: float = 0.0 if cam_d < UNIT_ANIM_NEAR else 12.0
			if rate != float(d.get("rate", -1.0)):
				d["rate"] = rate
				(d["f3d"] as Node3D).call("set_rate", rate)
			# walk while the board animates the unit's move; idle shortly after it stops
			if (d["last_pos"] as Vector2) != Vector2.INF and w_shown.distance_to(d["last_pos"]) > 0.05:
				d["moving_until"] = _time + 0.25
				var dt: float = maxf(_time - float(d.get("last_t", _time)), 0.001)
				if (d["f3d"] as Node3D).has_method("set_speed"):
					(d["f3d"] as Node3D).call("set_speed", w_shown.distance_to(d["last_pos"]) / dt)
			(d["f3d"] as Node3D).call("set_moving", _time < float(d["moving_until"]))
			_sync_wading(d, _frame_dt)
			# V2 designed maps: the men only animate while hovered / selected / walking / in a fight; otherwise they stand still
			if RulesV2Cls.enabled:
				var active: bool = id == sel_id or id == hov_id or _time < float(d["moving_until"]) + 0.9 or _time < float(d.get("busy_until", 0.0))
				if bool(d.get("frozen", false)) == active:
					d["frozen"] = not active
					if (d["f3d"] as Node3D).has_method("set_frozen"):
						(d["f3d"] as Node3D).call("set_frozen", not active)
			# face the march: toward the next point of the board's path; halted = the front
			var last_head: Vector3 = d.get("head", Vector3(9, 9, 9))
			var head := Vector3.ZERO
			var trail: Array = d.get("trail", [])
			if not trail.is_empty():
				head = last_head if last_head.length() < 2.0 else Vector3.ZERO
				for wp in trail:
					var to: Vector2 = (wp as Vector2) - w_shown
					if to.length() > 0.5:
						head = Vector3(to.x, 0.0, to.y).normalized()
						break
			if head.distance_to(last_head) > 0.08 and (d["f3d"] as Node3D).has_method("set_heading"):
				d["head"] = head
				(d["f3d"] as Node3D).call("set_heading", head)
			# idle activity follows morale in three steps (the game's own thresholds)
			var mor: float = float(u.get("morale", 100.0))
			var mlevel: int = 2 if mor >= MoraleSystemCls.STATE_STEADY else (1 if mor >= MoraleSystemCls.STATE_WAVERING else 0)
			if mlevel != int(d.get("morale_level", -1)) and (d["f3d"] as Node3D).has_method("set_morale"):
				d["morale_level"] = mlevel
				d["busy_until"] = _time + 2.0
				(d["f3d"] as Node3D).call("set_morale", mlevel)
			# figures standing = the board's strength (held while a blow is in the air)
			if _time >= float(d.get("hold_strength_until", 0.0)) and (d["f3d"] as Node3D).has_method("set_strength"):
				var mx: int = maxi(1, int(u.get("max_count", u.get("soldier_count", 1))))
				var frac: float = clampf(float(u.get("soldier_count", mx)) / float(mx), 0.0, 1.0)
				if not is_equal_approx(frac, float(d.get("strength", -1.0))):
					d["strength"] = frac
					d["busy_until"] = _time + 4.0
					(d["f3d"] as Node3D).call("set_strength", frac)
			d["last_t"] = _time
		d["last_pos"] = w_shown
		var faction: String = d["faction"]
		var state: String = faction
		var bstate: int = 0
		if id == sel_id:
			state = faction + "_sel"
			bstate = 2
		elif id == hov_id:
			state = faction + "_hov"
			bstate = 1
		if state != d["state"]:
			d["state"] = state
			(d["base"] as MeshInstance3D).material_override = mat_base[state]
		var top: Vector3 = root.position + Vector3(0.0, float(d["top"]), 0.0)
		if cam.is_position_behind(top):
			badge.visible = false
		else:
			badge.visible = true
			badge.scale = Vector2(badge_scale, badge_scale)
			badge.call("set_data", int(u.get("soldier_count", 0)), int(u.get("max_count", u.get("soldier_count", 1))), bstate, compact)
			_sync_morale_ring(id, d, badge, faction)
			badge.position = cam.unproject_position(top) - badge.pivot_offset + (v2_badge_shift.get(id, Vector2.ZERO) as Vector2)
		var q: int = int(u.get("q", 0))
		var r: int = int(u.get("r", 0))
		cells[Vector2i(q, r)] = 1 if faction == "blue" else 2
		if id == sel_id:
			sel_hex = Vector2(q, r)
	for id in _units.keys():
		if not seen.has(id):
			(_units[id]["badge"] as Control).queue_free()
			var gone: Node3D = _units[id]["root"]
			if bool((_units[id] as Dictionary).get("promoting", false)):
				gone.queue_free()   # promotion swap: the old formation just goes (no death animation)
			elif _units[id]["f3d"] != null and gone.visible:
				if (_units[id]["f3d"] as Node3D).has_method("set_frozen"):
					(_units[id]["f3d"] as Node3D).call("set_frozen", false)
				(_units[id]["f3d"] as Node3D).call("play_death")
				get_tree().create_timer(4.0).timeout.connect(gone.queue_free)
			else:
				gone.queue_free()
			_units.erase(id)
	mat_ground.set_shader_parameter("select_hex", sel_hex)
	var hov: Variant = shell.get("_current_hover_hex")
	mat_ground.set_shader_parameter("hover_hex", Vector2(hov.x, hov.y) if hov is Vector2i else Vector2(9999, 9999))
	if cells.hash() != _unit_cells.hash():
		for c in _unit_cells.keys():
			_set_cell_b(c, 0)
		for c in cells.keys():
			_set_cell_b(c, cells[c])
		_unit_cells = cells
		_cell_dirty = true

func _set_cell_b(c: Vector2i, v: int) -> void:
	if absi(c.x) > OUTER_R or absi(c.y) > OUTER_R:
		return
	var px: Color = _cell_img.get_pixel(c.x + OUTER_R, c.y + OUTER_R)
	px.b8 = v
	_cell_img.set_pixel(c.x + OUTER_R, c.y + OUTER_R, px)

## Fog follows the MARCH, not the order: the shell's fog is recomputed the moment a move is ordered (the unit is
## logically at its destination at once), so lighting the map from it reveals ground before the troop arrives.
## Instead a shadow fog is recomputed from where the formations are VISUALLY standing (their hex under the walking
## model), and the ground fades light/dark toward that state as they cross each hex.
## ---- Units stay readable in a forest: the trees of a hex that holds a (visible) formation or a ghost sink to a stubble. ----
const TREE_SQUASH: float = 0.18

func _build_tree_index() -> void:
	_tree_built = true
	var placed: Node = get_node_or_null("EditorMapBake/PlacedObjects")
	if placed == null:
		return
	for ch in placed.get_children():
		if not (ch is Node3D) or not ch.has_meta("visual_signature"):
			continue
		var parts: PackedStringArray = str(ch.get_meta("visual_signature")).split("|")
		if parts.size() < 4 or not (parts[0] == "forest" or parts[0] == "tree"):
			continue
		var key := "%d,%d" % [-int(parts[2]), -int(parts[3])]   # editor hex -> game hex (180 deg)
		if not _tree_index.has(key):
			_tree_index[key] = []
		(_tree_index[key] as Array).append({"node": ch, "base": (ch as Node3D).scale, "cur": 1.0})

func _sync_tree_clearing(delta: float) -> void:
	if not _tree_built:
		_build_tree_index()
	if _tree_index.is_empty():
		return
	var want: Dictionary = {}
	for id in _units:
		var rn: Node3D = (_units[id] as Dictionary)["root"]
		if is_instance_valid(rn) and rn.visible:
			var hx: Vector2i = HexUtilsCls.pixel_to_hex(Vector2(rn.position.x / S, rn.position.z / S))
			want["%d,%d" % [hx.x, hx.y]] = true
	for eid in _ghosts:
		var gh: Vector2i = (_ghosts[eid] as Dictionary)["hex"]
		want["%d,%d" % [gh.x, gh.y]] = true
	for key in _tree_index:
		var target: float = TREE_SQUASH if want.has(key) else 1.0
		for e in (_tree_index[key] as Array):
			var cur: float = float(e["cur"])
			if is_equal_approx(cur, target):
				continue
			cur = move_toward(cur, target, delta * 2.5)
			e["cur"] = cur
			var nd: Node3D = e["node"]
			if is_instance_valid(nd):
				var b: Vector3 = e["base"]
				nd.scale = Vector3(b.x, b.y * cur, b.z)

## Rules V2: morale ring on the own badges. Trend = what the supply zone will do to the morale at the next turn change.
func _sync_morale_ring(id: String, d: Dictionary, badge: Control, faction: String) -> void:
	if not RulesV2Cls.enabled or faction != "blue":
		badge.call("set_morale", 100.0, 0, false)
		badge.call("set_supply", 0, 4, false)
		return
	if str(d.get("cls", "")) == "hq":
		# the HQ shows its supply stock (bases it can still build), not morale
		var hum: Variant = shell.get("unit_manager")
		var stock_now: int = int(hum.supply_v2.stock.get("blue", 0)) if hum != null and hum.supply_v2 != null else 0
		d["s_cap"] = maxi(int(d.get("s_cap", 0)), stock_now)
		badge.call("set_morale", 100.0, 0, false)
		badge.call("set_supply", stock_now, int(d["s_cap"]), true)
		return
	badge.call("set_supply", 0, 4, false)
	if _time >= float(d.get("m_next", 0.0)):
		d["m_next"] = _time + 0.2
		var um: Variant = shell.get("unit_manager")
		var uu: Dictionary = um.get_unit_by_id(id) if um != null else {}
		if uu.is_empty() or um.supply_v2 == null:
			d["m_on"] = false
		else:
			var m: float = float(uu.get("morale", 100.0))
			# the hex the formation is VISUALLY standing on: the effect starts the moment the walking formation crosses the radius line
			var rn: Node3D = d["root"]
			var vh := Vector2i(int(uu["q"]), int(uu["r"]))
			if is_instance_valid(rn):
				vh = HexUtilsCls.pixel_to_hex(Vector2(rn.position.x / S, rn.position.z / S))
			var zone: String = um.supply_v2.zone_of(um._units, "blue", vh.x, vh.y)
			var trend: int = 0
			if zone == "near":
				trend = 1   # inside the blue (healing) radius it keeps charging, even at full morale
			elif zone == "normal":
				trend = 1 if m < 100.0 else 0
			elif m > 0.0:
				trend = -1
			d["m_val"] = m
			d["m_trend"] = trend
			d["m_on"] = str(uu.get("class", "")) != "supply"
	badge.call("set_morale", float(d.get("m_val", 100.0)), int(d.get("m_trend", 0)), bool(d.get("m_on", false)))

## ---- Lost contacts: the enemy's LAST KNOWN position, drawn with the real formation asset in ink-brown. ----
## It stays until its hex is seen again (the position is then updated: the ghost vanishes, and the real unit shows if it is there).
const GHOST_GONE_AT: float = 0.7   # shown fog state of the hex at which the ghost is considered "seen again"

func _ghost_material() -> StandardMaterial3D:
	if _ghost_mat == null:
		_ghost_mat = StandardMaterial3D.new()
		_ghost_mat.albedo_color = Color(0.50, 0.40, 0.28)
		_ghost_mat.roughness = 1.0
		_ghost_mat.metallic = 0.0
		_ghost_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return _ghost_mat

func _recolor_ghost(n: Node) -> void:
	if n is MeshInstance3D:
		(n as MeshInstance3D).material_override = _ghost_material()
	for c in n.get_children():
		_recolor_ghost(c)

func _make_ghost(eid: String, rec: Dictionary) -> Dictionary:
	_ensure_formation_assets()
	var cls: String = str(rec.get("class", "infantry"))
	var root := Node3D.new()
	root.name = "Ghost_" + eid
	add_child(root)
	var ranks: Array[Vector2] = _ranks_for(cls)
	var fig_h: float = float(FIGURE_H.get(cls, FIGURE_H_DEFAULT)) * S
	var f3d: Node3D = null
	if Cavalry3D.supports(cls):
		f3d = Cavalry3D.new()
	elif Formation3D.supports(cls):
		f3d = Formation3D.new()
	if f3d != null:
		root.add_child(f3d)
		f3d.call("setup", cls, "red", ranks.size(), fig_h * 0.95, -fwd, hash(eid))
		f3d.call("set_far", false)
		if f3d.has_method("set_moving"):
			f3d.call("set_moving", false)
		if f3d.has_method("set_frozen"):
			get_tree().create_timer(0.6).timeout.connect(func(): if is_instance_valid(f3d): f3d.call("set_frozen", true))
	var hx := Vector2i(int(rec.get("q", 0)), int(rec.get("r", 0)))
	root.position = _ground3(HexUtilsCls.hex_to_pixel(hx.x, hx.y))
	return {"root": root, "turn": int(rec.get("turn", 0)), "hex": hx}

func _sync_ghosts(delta: float) -> void:
	var fog: Variant = shell.get("_fog")
	if fog == null:
		return
	var stale: Dictionary = fog.stale_contacts
	# drop ghosts whose record is gone (the enemy was seen again) or whose hex is in sight now
	for eid in _ghosts.keys():
		var g: Dictionary = _ghosts[eid]
		var hx: Vector2i = g["hex"]
		var gone: bool = not stale.has(eid) or int((stale[eid] as Dictionary).get("turn", 0)) != int(g["turn"])
		if not gone and float(_fow_cur.get("%d,%d" % [hx.x, hx.y], 0.0)) >= GHOST_GONE_AT:
			gone = true
			_ghost_dead[eid] = int(g["turn"])
		if gone:
			(g["root"] as Node3D).queue_free()
			_ghosts.erase(eid)
	for eid in stale.keys():
		var rec: Dictionary = stale[eid]
		if _ghosts.has(eid) or int(_ghost_dead.get(eid, -1)) == int(rec.get("turn", 0)):
			continue
		var hx2 := Vector2i(int(rec.get("q", 0)), int(rec.get("r", 0)))
		if float(_fow_cur.get("%d,%d" % [hx2.x, hx2.y], 0.0)) >= GHOST_GONE_AT:
			continue   # its hex is already in sight: the last known position is simply wrong now
		_ghosts[eid] = _make_ghost(str(eid), rec)
	# formations build their meshes lazily: keep them in ink colour
	_ghost_t -= delta
	if _ghost_t <= 0.0:
		_ghost_t = 0.4
		for eid in _ghosts.keys():
			_recolor_ghost((_ghosts[eid] as Dictionary)["root"])

const FOW_FADE_SPEED: float = 3.0   # state units / s (0 unexplored, 0.5 explored, 1 visible)
const HEX_SPACING: float = 41.7     # world px between neighbouring hex centres

## Visibility is CONTINUOUS around the walking formation: a cell inside the shadow fog's line-of-sight set is lit by how far
## the formation really is from it (full inside the radius, fading to nothing half a hex beyond it; cells never lit before start from 0, remembered ones from 0.5), so the light glides with the
## march instead of switching hex by hex. Remembered ground stays at 0.5.
func _visual_fog_recalc(fog: Variant) -> void:
	var um: Variant = shell.get("unit_manager")
	var cell_data: Dictionary = shell.get("hex_grid").get("cell_data")
	if um == null:
		return
	if _vis_fog == null:
		_vis_fog = (load("res://scripts/step5/fog_of_war.gd") as Script).new()
		# one hex MORE than the real vision: a cell is lit by its continuous distance to the formation, so every cell that can
		# come into range must already be in the set (or it would switch on at full strength when the march flips hexes)
		_vis_fog.normal_vision = fog.normal_vision + 1
		_vis_fog.scout_vision = fog.scout_vision + 1
		_vis_fog.set_objective_hexes(fog.objective_hexes.keys())
		_fow_ever = (fog.explored as Dictionary).duplicate()
		RulesV2Cls.known = _fow_ever   # movement planning knows exactly what has been shown on screen (same dictionary)
		RulesV2Cls.known_on = true
	var friendlies: Array = []
	var marchers: Array = []     # [world px position, vision radius]
	var sig: int = 0
	for u in um.get_all_units():
		if str(u.get("faction", "")) != "blue" or int(u.get("soldier_count", 0)) <= 0 or bool(u.get("garrisoned", false)) or bool(u.get("routed", false)):
			continue
		var v: Dictionary = (u as Dictionary).duplicate()
		var id: String = str(u.get("id", ""))
		var wpos: Vector2 = HexUtilsCls.hex_to_pixel(int(u["q"]), int(u["r"]))
		if _units.has(id):
			var rn: Node3D = (_units[id] as Dictionary)["root"]
			if is_instance_valid(rn):
				wpos = Vector2(rn.position.x / S, rn.position.z / S)
				var hx: Vector2i = HexUtilsCls.pixel_to_hex(wpos)
				v["q"] = hx.x
				v["r"] = hx.y
		sig = sig * 31 + int(v["q"]) * 7919 + int(v["r"]) * 131 + int(v.get("soldier_count", 0))
		friendlies.append(v)
		marchers.append([wpos, float(fog.scout_vision if _vis_fog.is_scout_class(str(u.get("class", ""))) else fog.normal_vision)])
	if sig != _vis_sig:
		_vis_sig = sig
		_vis_fog.recompute(friendlies, [], cell_data, 0)
	var vis_los: Dictionary = _vis_fog.visible
	_fow_tgt.clear()
	for key in _fow_ever.keys():
		_fow_tgt[key] = 0.5
	for key in vis_los.keys():
		var parts: PackedStringArray = str(key).split(",")
		if parts.size() != 2:
			continue
		var cpx: Vector2 = HexUtilsCls.hex_to_pixel(int(parts[0]), int(parts[1]))
		var w: float = 0.0
		for m in marchers:
			var d: float = (m[0] as Vector2).distance_to(cpx) / HEX_SPACING
			w = maxf(w, clampf((float(m[1]) + 0.5 - d) / 0.5, 0.0, 1.0))
		if w > 0.0 or _fow_ever.has(key):
			_fow_tgt[key] = maxf(w, 0.5 if _fow_ever.has(key) else 0.0)

func _sync_fog_of_war(delta: float) -> void:
	var fog: Variant = shell.get("_fog")
	if fog == null:
		if _fow_sig != -2:   # no fog on this map: everything visible
			_fow_sig = -2
			for q in range(-PLAY_R, PLAY_R + 1):
				for r in range(-PLAY_R, PLAY_R + 1):
					if axial_dist(q, r) <= PLAY_R:
						var px0: Color = _cell_img.get_pixel(q + OUTER_R, r + OUTER_R)
						px0.g8 = 255
						_cell_img.set_pixel(q + OUTER_R, r + OUTER_R, px0)
			_cell_dirty = true
		return
	if _fow_sig == -1:   # (re)start: forget the shadow fog, begin from the shell's state
		_vis_fog = null
		_vis_sig = -1
		_fow_cur.clear()
		_fow_tgt.clear()
		_fow_ever.clear()
		_fow_sig = 0
		_fow_timer = 0.0
		for q in range(-PLAY_R, PLAY_R + 1):   # the texture starts "visible" everywhere: hide it all, the fade lights what is known
			for r in range(-PLAY_R, PLAY_R + 1):
				if axial_dist(q, r) <= PLAY_R:
					var px1: Color = _cell_img.get_pixel(q + OUTER_R, r + OUTER_R)
					px1.g8 = 0
					_cell_img.set_pixel(q + OUTER_R, r + OUTER_R, px1)
		_cell_dirty = true
	_visual_fog_recalc(fog)
	# fade every cell toward its target state; only cells that differ are touched
	var step: float = FOW_FADE_SPEED * delta
	var keys: Dictionary = {}
	for k in _fow_cur.keys():
		keys[k] = true
	for k in _fow_tgt.keys():
		keys[k] = true
	for k in keys.keys():
		var cur: float = float(_fow_cur.get(k, 0.0))
		var tgt: float = float(_fow_tgt.get(k, 0.0))
		if is_equal_approx(cur, tgt):
			continue
		cur = move_toward(cur, tgt, step)
		if cur >= 0.5:
			_fow_ever[k] = true
		if is_zero_approx(cur):
			_fow_cur.erase(k)
		else:
			_fow_cur[k] = cur
		var parts: PackedStringArray = str(k).split(",")
		if parts.size() != 2:
			continue
		var cx: int = int(parts[0]) + OUTER_R
		var cy: int = int(parts[1]) + OUTER_R
		if cx < 0 or cy < 0 or cx >= GRID_N or cy >= GRID_N:
			continue
		var px: Color = _cell_img.get_pixel(cx, cy)
		px.g8 = int(round(clampf(cur, 0.0, 1.0) * 255.0))
		_cell_img.set_pixel(cx, cy, px)
		_cell_dirty = true

# ---------------------------------------------------------------------- picking

const PICK_Y_MAX: float = 3.0
const PICK_Y_MIN: float = -0.8

## Exact pointer inverse: screen pixel -> battlefield world px, by marching the
## camera ray down to the heightfield.
func screen_to_world(screen_pos: Vector2) -> Vector2:
	if cam == null:
		return Vector2(1.0e7, 1.0e7)
	var o: Vector3 = cam.project_ray_origin(screen_pos)
	var dv: Vector3 = cam.project_ray_normal(screen_pos)
	if dv.y > -0.0001:
		return Vector2(1.0e7, 1.0e7)
	var t0: float = (PICK_Y_MAX - o.y) / dv.y
	var t1: float = (PICK_Y_MIN - o.y) / dv.y
	var steps: int = 40
	var prev: float = t0
	var hit: float = t1
	for i in range(1, steps + 1):
		var t: float = lerpf(t0, t1, float(i) / steps)
		var p: Vector3 = o + dv * t
		if p.y <= float(terrain.call("height_at", Vector2(p.x / S, p.z / S))):
			var a: float = prev
			var b: float = t
			for k in range(10):
				var m: float = (a + b) * 0.5
				var pm: Vector3 = o + dv * m
				if pm.y <= float(terrain.call("height_at", Vector2(pm.x / S, pm.z / S))):
					b = m
				else:
					a = m
			hit = b
			break
		prev = t
	var ph: Vector3 = o + dv * hit
	return Vector2(ph.x / S, ph.z / S)

func world_to_screen(w: Vector2) -> Vector2:
	return cam.unproject_position(_ground3(w))

# ------------------------------------------------------------------------ frame

func _process(delta: float) -> void:
	_time += delta
	_frame_dt = delta
	if cam2d == null or shell == null or not _active:
		return
	_edge_scroll(delta)
	_update_camera()
	_sync_units()
	_sync_fog_of_war(delta)
	_sync_ghosts(delta)
	_sync_tree_clearing(delta)
	if _cell_dirty:
		_cell_tex.update(_cell_img)
		_cell_dirty = false

func zoom_close() -> float:
	return ZOOM_MAX

func zoom_high() -> float:
	return ZOOM_MIN

func board_max_zoom() -> float:
	return ZOOM_MAX

func is_active() -> bool:
	return _active

## One continuous camera: there is no second mode to switch to.
func request_mode(_closeup: bool) -> void:
	pass

func apply_active(on: bool) -> void:
	_active = on
	visible = on
	if _badge_layer:
		_badge_layer.visible = on
	if on and _hud_skin == null:
		_hud_skin = HudSkin.new()
		add_child(_hud_skin)
		_hud_skin.call("setup", shell, self)
	elif _hud_skin != null:
		_hud_skin.call("set_active", on)
	var vp: Viewport = get_viewport()
	if on:
		_saved_msaa = vp.msaa_3d
		vp.msaa_3d = Viewport.MSAA_4X
		cam.make_current()
		if cam2d:
			cam2d.set("anchor_provider", Callable())
			cam2d.set("zoom_anchor_solver", Callable())
			cam2d.set("min_zoom", ZOOM_MIN)
			cam2d.set("max_zoom", ZOOM_MAX)
			var home: Vector2 = _hq_world() + Vector2(fwd.x, fwd.z) * 160.0
			cam2d.call("set_home_view", home, ZOOM_HOME)
			cam2d.call("set_zoom_level", ZOOM_HOME, true)
			cam2d.call("focus_on", home, true)
		_overlay_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		_fow_sig = -1
		_cam_sig = Vector4.INF
		_update_camera()
		_sync_units()
	else:
		vp.msaa_3d = _saved_msaa
		if cam:
			cam.clear_current(false)
		if _overlay_vp:
			_overlay_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
