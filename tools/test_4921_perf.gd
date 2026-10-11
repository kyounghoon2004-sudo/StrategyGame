extends SceneTree

const Lib = preload("res://scripts/visual/map_composition_v0/map_composition_library.gd")
const Builder = preload("res://scripts/visual/map_composition_v0/map_composition_builder.gd")
const HexUtils = preload("res://scripts/core/hex_utils.gd")

var _root3d: Node3D
var _cam: Camera3D
var _frames := 0
var _fps_samples: Array = []
var _t0 := 0

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

func _initialize() -> void:
	_t0 = Time.get_ticks_msec()
	_root3d = Node3D.new()
	_root3d.name = "TestFullDressingScene"
	root.add_child(_root3d)

	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color("d9d5cb")
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color("f2ecde")
	env.ambient_light_energy = 0.95
	var we := WorldEnvironment.new()
	we.environment = env
	_root3d.add_child(we)

	var sun := DirectionalLight3D.new()
	sun.light_color = Color("faf1dd")
	sun.light_energy = 1.35
	sun.shadow_enabled = false
	_root3d.add_child(sun)

	_cam = Camera3D.new()
	_cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	_cam.size = 2800.0
	_cam.position = Vector3(0.0, 1500.0, 1000.0)
	_cam.rotation_degrees = Vector3(-60.0, 0.0, 0.0)
	_cam.current = true
	_root3d.add_child(_cam)

	# Load shell to get authentic production map cell_data
	var shell_scn: PackedScene = load("res://scenes/step2r_battlefield_shell.tscn")
	var shell: Node = shell_scn.instantiate()
	root.add_child(shell)
	var cells: Dictionary = shell.get("hex_grid").get("cell_data")
	var river_cells: Dictionary = shell.get("_river_cells")
	var stronghold_cells: Dictionary = shell.get("_stronghold_cells")
	var stronghold_specs: Array = shell.call("stronghold_visual_specs")

	var tile_transforms: Dictionary = {}
	for k in TILE_KEYS:
		tile_transforms[k] = []

	var decorated_ground_count := 0
	var feature_count := 0
	var feature_breakdown: Dictionary = {
		"mountain": 0, "forest": 0, "river": 0, "village": 0,
		"fortification": 0, "agriculture": 0, "plain": 0
	}

	var features_parent := Node3D.new()
	features_parent.name = "FeatureCompositions"
	_root3d.add_child(features_parent)

	for key in cells.keys():
		var cell: Variant = cells[key]
		var q: int = int(cell.q)
		var r: int = int(cell.r)
		var t: int = int(cell.terrain)
		var px: Vector2 = HexUtils.hex_to_pixel(q, r)
		var seed_val: int = 20261002 + q * 1013 + r * 337

		# 1. Determine Tile Key & Placement
		var tile_key: String = "tile_open_grassland"
		match t:
			1: # Mountain
				tile_key = "tile_rocky_ground"
			2: # Forest
				tile_key = "tile_scrub" if (q + r) % 2 == 0 else "tile_open_grassland"
			3: # Swamp
				tile_key = "tile_wet_lowland"
			5: # Village
				tile_key = "tile_packed_dirt"
			6: # Road
				tile_key = "tile_worn_crossing" if river_cells.has(key) else "tile_dry_earth"
			7: # River
				tile_key = "tile_wet_lowland"
			9: # Fortress Hulao
				tile_key = "tile_rocky_ground"
			11: # Capital Luoyang
				tile_key = "tile_packed_dirt"
			_: # Plains
				if (q * 7 + r * 13) % 5 == 0:
					tile_key = "tile_dry_earth"
				elif (q * 3 + r * 11) % 4 == 0:
					tile_key = "tile_scrub"
				else:
					tile_key = "tile_open_grassland"

		var b: Dictionary = Lib.bounds(tile_key)
		var half: Vector2 = b["half_xz"]
		var sx: float = Builder.HEX_HALF_W / half.x
		var sz: float = Builder.HEX_HALF_H / half.y
		var c: Vector3 = b["center"]

		var xform := Transform3D()
		xform = xform.scaled(Vector3(sx, sx, sz))
		xform.origin = Vector3(px.x, 0.0, px.y) + Vector3(-c.x * sx, 0.0, -c.z * sz)
		tile_transforms[tile_key].append(xform)
		decorated_ground_count += 1

		# 2. Determine 3D Composition
		var built_comp: Node3D = null
		if t == 1: # Mountain
			var m_var: int = absi(q * 3 + r * 7) % 9
			var pair: Dictionary = Builder.build_mountain(m_var, seed_val)
			built_comp = pair["root"]
			feature_breakdown["mountain"] += 1
		elif t == 2: # Forest
			var f_var: int = absi(q * 5 + r * 11) % 3
			var pair: Dictionary = Builder.build_forest(f_var, seed_val)
			built_comp = pair["root"]
			feature_breakdown["forest"] += 1
		elif t == 7 or river_cells.has(key): # River
			var r_key: String = "main_river"
			var yaw: float = 0.0
			if t == 6: # Bridge
				r_key = "wooden_bridge" if (q + r) % 2 == 0 else "stone_bridge"
			elif absi(r) > 20:
				r_key = "narrow_stream" if (q + r) % 2 == 0 else "main_river"
			elif (q + r) % 5 == 0:
				r_key = "shallow_ford"
			var pair: Dictionary = Builder.build_river(r_key, yaw)
			built_comp = pair["root"]
			feature_breakdown["river"] += 1
		elif t == 5: # Village
			var v_var: int = absi(q + r) % 3
			var pair: Dictionary = Builder.build_village(v_var, seed_val)
			built_comp = pair["root"]
			feature_breakdown["village"] += 1
			# Also add an adjacent farm if appropriate
		elif t == 9: # Fortress Hulao
			var pair: Dictionary = Builder.build_city(1 if key == "-4,2" else (2 if key == "-3,2" else 0), seed_val)
			built_comp = pair["root"]
			feature_breakdown["fortification"] += 1
		elif t == 11: # Capital Luoyang
			var pair: Dictionary = Builder.build_city(2 if key == "14,-5" else (1 if key == "15,-5" else 0), seed_val)
			built_comp = pair["root"]
			feature_breakdown["fortification"] += 1
		elif t == 0: # Plains
			# Occasional farm near villages or roads, sparse vegetation on plains
			var is_near_village: bool = false
			for vd in [Vector2i(1,0), Vector2i(-1,0), Vector2i(0,1), Vector2i(0,-1)]:
				if cells.has("%d,%d" % [q + vd.x, r + vd.y]) and int(cells["%d,%d" % [q + vd.x, r + vd.y]].terrain) == 5:
					is_near_village = true
					break
			if is_near_village and (q + r) % 2 == 0:
				var pair: Dictionary = Builder.build_farm(absi(q) % 2, seed_val)
				built_comp = pair["root"]
				feature_breakdown["agriculture"] += 1
			elif (q * 17 + r * 31) % 19 == 0: # Sparse plain variation
				var pair: Dictionary = Builder.build_plain(absi(q * 7 + r * 13) % 4, seed_val)
				built_comp = pair["root"]
				feature_breakdown["plain"] += 1

		if built_comp != null:
			built_comp.position = Vector3(px.x, 0.0, px.y)
			features_parent.add_child(built_comp)
			feature_count += 1

	# Create MultiMesh for tiles
	for k in TILE_KEYS:
		var xfs: Array = tile_transforms[k]
		if xfs.is_empty():
			continue
		var ps: PackedScene = Lib.scene_for(k)
		var tmp_inst: Node3D = ps.instantiate() as Node3D
		var mesh: Mesh = null
		var mat: Material = null
		if tmp_inst is MeshInstance3D:
			mesh = (tmp_inst as MeshInstance3D).mesh
			mat = (tmp_inst as MeshInstance3D).get_surface_override_material(0)
		else:
			for ch in tmp_inst.get_children():
				if ch is MeshInstance3D:
					mesh = (ch as MeshInstance3D).mesh
					mat = (ch as MeshInstance3D).get_surface_override_material(0)
					break
		tmp_inst.free()

		if mesh != null:
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.mesh = mesh
			mm.instance_count = xfs.size()
			for i in range(xfs.size()):
				mm.set_instance_transform(i, xfs[i])
			var mmi := MultiMeshInstance3D.new()
			mmi.name = "MMI_" + k
			mmi.multimesh = mm
			mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			if mat != null:
				mmi.material_override = mat
			_root3d.add_child(mmi)

	var dt: int = Time.get_ticks_msec() - _t0
	print("[FullDressingPerf] Built %d tiles + %d 3D feature compositions in %d ms" % [
		decorated_ground_count, feature_count, dt
	])
	print("[FullDressingPerf] Breakdown: ", JSON.stringify(feature_breakdown))
	shell.queue_free()

func _process(delta: float) -> bool:
	_frames += 1
	if _frames > 30:
		_fps_samples.append(1.0 / maxf(0.0001, delta))
	if _frames >= 120:
		var sum_fps := 0.0
		for f in _fps_samples:
			sum_fps += f
		var avg_fps: float = sum_fps / float(_fps_samples.size())
		print("[FullDressingPerf] FULL 4921 MAP AVERAGE FPS: ", "%.2f" % avg_fps)
		_root3d.queue_free()
		quit(0)
		return true
	return false
