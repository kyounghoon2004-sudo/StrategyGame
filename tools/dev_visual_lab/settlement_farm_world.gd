extends "res://tools/dev_visual_lab/waterway_world.gd"

## StrategyGame | Modular Village & Farmland Kit Integration
## Extends waterway_world.gd: preserves all 25 mountain ranges, animated rivers,
## bridges, and terrain while replacing legacy farm/village dioramas with
## the new 60-part modular kit (DEV scale R=18, shared materials, distance LOD).

const KIT_DIR := "C:/Users/User/Documents/Codex/2026-10-18/strategygame-godot-4-2-2-repo/outputs/village-farmland-kit"
const EXPORTS_DIR := KIT_DIR + "/exports"
const RENDERS_DIR := KIT_DIR + "/renders"
const EVIDENCE_DIR := KIT_DIR + "/evidence"
const CONFIG_DIR := KIT_DIR + "/config"

# Cache for loaded modular kit meshes: kit_mesh_cache[part_id][lod] -> Array of { "mesh": Mesh, "transform": Transform3D, "material": Material }
var kit_mesh_cache: Dictionary = {}
var kit_materials: Dictionary = {}
var hex_overrides: Dictionary = {}
var settlement_farm_node: Node3D
var hex_assemblies: Array = []
var active_kit_lod := -1 # -1 = dynamic, 0/1/2 = forced
var legacy_mode := false
var validation_metrics: Dictionary = {}

# Farmland & village spatial constants
const FARM_PATCH_RADIUS := 18.0
const ALLEY_CLEAR_RADIUS := 6.5

func _initialize() -> void:
	super._initialize()

func boot() -> void:
	print("[SettlementFarmWorld] Booting modular village & farmland system...")
	DirAccess.make_dir_recursive_absolute(RENDERS_DIR)
	DirAccess.make_dir_recursive_absolute(EVIDENCE_DIR)
	DirAccess.make_dir_recursive_absolute(CONFIG_DIR)

	load_hex_overrides()
	load_all_modular_glbs()

	var args := OS.get_cmdline_user_args()
	if "--lod=0" in args or "--all-lod0" in args: active_kit_lod = 0
	elif "--lod=1" in args: active_kit_lod = 1
	elif "--lod=2" in args: active_kit_lod = 2
	legacy_mode = "--legacy" in args or "--before" in args

	await super.boot()
	root.title = "StrategyGame | Modular Village & Farmland Kit (DEV R=18)"

	if not capture_mode:
		# Jump to District 1: Near by default
		focus_district1_near()
		await wait_frames(15)
		await save_render_png("interactive_start")

func load_hex_overrides() -> void:
	var path := CONFIG_DIR.path_join("hex_overrides.json")
	if FileAccess.file_exists(path):
		var text := FileAccess.get_file_as_string(path)
		var json: Variant = JSON.parse_string(text)
		if json is Dictionary and json.has("overrides"):
			hex_overrides = json["overrides"]
			print("[SettlementFarmWorld] Loaded ", hex_overrides.size(), " hex overrides.")

func load_all_modular_glbs() -> void:
	var started := Time.get_ticks_msec()
	kit_mesh_cache.clear()
	var parts := [
		"farm_patch_dry", "farm_patch_rice", "farm_patch_terrace",
		"farm_edge_dike", "farm_channel_straight", "farm_channel_bend60",
		"farm_channel_bend120", "farm_channel_tee", "farm_channel_end_sluice",
		"village_courtyard_apron", "village_wall_segment", "village_wall_corner",
		"village_courtyard_props",
		"building_small_house", "building_medium_house", "building_workshop",
		"building_granary", "building_hall", "building_gate", "building_farm_granary"
	]

	var loaded_count := 0
	for part_id in parts:
		kit_mesh_cache[part_id] = [null, null, null]
		for lod in range(3):
			var filename := "%s_lod%d.glb" % [part_id, lod]
			var filepath := EXPORTS_DIR.path_join(filename)
			if not FileAccess.file_exists(filepath):
				push_warning("Missing GLB file: " + filepath)
				continue

			var doc := GLTFDocument.new()
			var state := GLTFState.new()
			var err := doc.append_from_file(filepath, state)
			if err != OK:
				push_error("Failed to append GLTF: " + filepath)
				continue

			var root_node := doc.generate_scene(state) as Node3D
			if root_node == null: continue

			var extracted_items: Array = []
			extract_mesh_items(root_node, Transform3D.IDENTITY, extracted_items)
			kit_mesh_cache[part_id][lod] = extracted_items
			root_node.free()
			loaded_count += 1

	var elapsed := Time.get_ticks_msec() - started
	print("[SettlementFarmWorld] Loaded %d / 60 modular kit GLBs in %d ms." % [loaded_count, elapsed])

func extract_mesh_items(node: Node, parent_xform: Transform3D, out_items: Array) -> void:
	var local_xform := Transform3D.IDENTITY
	if node is Node3D:
		local_xform = parent_xform * (node as Node3D).transform

	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		if mi.mesh != null:
			# Configure material for rich vertex colors and accurate shading
			var mat: Material = mi.material_override
			if mat == null and mi.mesh.get_surface_count() > 0:
				mat = mi.mesh.surface_get_material(0)

			if mat is StandardMaterial3D:
				var sm := mat as StandardMaterial3D
				sm.vertex_color_use_as_albedo = true
				sm.roughness = 0.88
				sm.cull_mode = BaseMaterial3D.CULL_DISABLED

			out_items.append({
				"mesh": mi.mesh,
				"transform": local_xform,
				"material": mat
			})

	for child in node.get_children():
		extract_mesh_items(child, local_xform, out_items)

func instantiate_kit_part(part_id: String, lod: int, parent: Node3D, local_pos: Vector3, yaw_rad: float, uniform_scale: float = 1.0) -> Node3D:
	if not kit_mesh_cache.has(part_id): return null
	var lod_items: Array = kit_mesh_cache[part_id][lod]
	if lod_items == null or lod_items.is_empty():
		# Fallback to LOD 0 if current LOD missing
		lod_items = kit_mesh_cache[part_id][0]
		if lod_items == null or lod_items.is_empty(): return null

	var container := Node3D.new()
	container.name = "%s_lod%d" % [part_id, lod]
	container.position = local_pos
	container.rotation.y = yaw_rad
	container.scale = Vector3.ONE * uniform_scale

	for item in lod_items:
		var mi := MeshInstance3D.new()
		mi.mesh = item["mesh"]
		mi.transform = item["transform"]
		if item["material"] != null:
			mi.material_override = item["material"]
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		container.add_child(mi)

	parent.add_child(container)
	return container

# ----------------------------------------------------------------------------------
# Terrain & Scenery Override
# ----------------------------------------------------------------------------------

func add_prop(cell: Dictionary, key: String, local: Vector2, width: float, angle: float = 0.0) -> void:
	if not legacy_mode:
		var kind: String = cell.get("kind", "")
		if kind == "village" or kind == "farm":
			return
	super.add_prop(cell, key, local, width, angle)

func ribbon(st: SurfaceTool, a: Vector3, b: Vector3, width: float, color: Color, y: float) -> void:
	# User explicit instruction: "도로는 나중에 추가할거야" (Roads will be added later)
	# Suppress all road ribbons (width 2.4) in modular mode
	if not legacy_mode and is_equal_approx(width, 2.4):
		return
	super.ribbon(st, a, b, width, color, y)

func build_terrain() -> void:
	super.build_terrain()
	if not legacy_mode:
		build_modular_settlements_and_farms()

func build_modular_settlements_and_farms() -> void:
	if settlement_farm_node != null and is_instance_valid(settlement_farm_node):
		settlement_farm_node.queue_free()
	settlement_farm_node = Node3D.new()
	settlement_farm_node.name = "ModularSettlementsAndFarms"
	stage.add_child(settlement_farm_node)

	hex_assemblies.clear()
	var village_count := 0
	var farm_count := 0

	for cell in cells:
		var kind: String = cell["kind"]
		if kind == "farm":
			build_farm_hex(cell)
			farm_count += 1
		elif kind == "village":
			build_village_hex(cell)
			village_count += 1

	print("[SettlementFarmWorld] Built modular assemblies: %d villages, %d farms." % [village_count, farm_count])
	update_lod()

# ----------------------------------------------------------------------------------
# Farmland Hex Modular Composition
# ----------------------------------------------------------------------------------

func build_farm_hex(cell: Dictionary) -> void:
	var q := int(cell["q"])
	var r := int(cell["r"])
	var c := center(q, r)
	var override_key := "%d,%d" % [q, r]
	var ovr: Dictionary = hex_overrides.get(override_key, {})

	# Determine farm type
	var farm_type := String(ovr.get("farm_type", ""))
	var terrace_dir := -1
	var river_mask := 0
	var farm_border_mask := 0
	var has_mountain_adj := false
	var has_water_adj := false

	# Inspect 6 axial neighbours: DIRS = [[1,0],[1,-1],[0,-1],[-1,0],[-1,1],[0,1]]
	for d in range(6):
		var dir_vec: Vector2i = DIRS[d]
		var nq: int = q + dir_vec.x
		var nr: int = r + dir_vec.y
		var nkey := hex_key(nq, nr)
		if tile_lookup.has(nkey):
			var nkind: String = cells[tile_lookup[nkey]]["kind"]
			if nkind == "mountain":
				has_mountain_adj = true
				if terrace_dir < 0: terrace_dir = d
			elif nkind == "river" or nkind == "water":
				has_water_adj = true
				river_mask |= (1 << d)
			elif nkind == "farm" or nkind == "village":
				farm_border_mask |= (1 << d)

	if farm_type == "":
		if has_mountain_adj:
			farm_type = "terraced_field"
		elif has_water_adj or is_lowland_basin(q, r):
			farm_type = "rice_field"
		else:
			farm_type = "dry_field"

	# Hex assembly container with 3 LOD children
	var hex_root := Node3D.new()
	hex_root.name = "farm_%d_%d" % [q, r]
	hex_root.position = c
	settlement_farm_node.add_child(hex_root)

	var lod_nodes := [Node3D.new(), Node3D.new(), Node3D.new()]
	for lod in range(3):
		lod_nodes[lod].name = "lod%d" % lod
		hex_root.add_child(lod_nodes[lod])

	# 1. Base Farmland Patch
	var patch_yaw := 0.0
	var patch_id := "farm_patch_dry"

	if farm_type == "terraced_field":
		patch_id = "farm_patch_terrace"
		# Rotate so high terrace steps climb towards the mountain neighbour
		patch_yaw = -float(terrace_dir if terrace_dir >= 0 else 0) * (PI / 3.0)
	elif farm_type == "rice_field":
		patch_id = "farm_patch_rice"
		patch_yaw = 0.0
	else:
		patch_id = "farm_patch_dry"
		# Continuous crop ridge alignment across connected clusters
		var cluster_dir := posmod(q + r * 2, 3)
		patch_yaw = -float(cluster_dir) * (PI / 3.0)

	for lod in range(3):
		instantiate_kit_part(patch_id, lod, lod_nodes[lod], Vector3.ZERO, patch_yaw)

	# 2. Shared Boundary Earthen Dikes (farm_edge_dike)
	# Place only on shared edges where d < 3 and adjacent cells have different farm types (or village border)
	for d in range(3):
		var dir_vec: Vector2i = DIRS[d]
		var nq: int = q + dir_vec.x
		var nr: int = r + dir_vec.y
		var nkey := hex_key(nq, nr)
		if tile_lookup.has(nkey):
			var nkind: String = cells[tile_lookup[nkey]]["kind"]
			var should_place_dike := false
			if nkind == "village":
				should_place_dike = true
			elif nkind == "farm":
				var n_farm_type := determine_farm_type(nq, nr)
				if n_farm_type != farm_type:
					should_place_dike = true

			if should_place_dike:
				var dike_yaw := -float(d) * (PI / 3.0)
				for lod in range(3):
					instantiate_kit_part("farm_edge_dike", lod, lod_nodes[lod], Vector3.ZERO, dike_yaw)

	# 3. Modular Irrigation Channels (on rice fields and river-bordering farms)
	if farm_type == "rice_field" or (farm_type == "dry_field" and has_water_adj):
		var channel_id := "farm_channel_straight"
		var channel_yaw := 0.0

		if has_water_adj:
			# Terminal wooden sluice gate facing the river edge
			channel_id = "farm_channel_end_sluice"
			var riv_edge := 0
			for d in range(6):
				if (river_mask & (1 << d)) != 0: riv_edge = d; break
			channel_yaw = -float(riv_edge) * (PI / 3.0)
		else:
			# Internal network channels
			var pattern := posmod(q * 7 + r * 13, 3)
			if pattern == 0:
				channel_id = "farm_channel_straight"
				channel_yaw = -float(posmod(q, 3)) * (PI / 3.0)
			elif pattern == 1:
				channel_id = "farm_channel_bend60"
				channel_yaw = -float(posmod(r, 6)) * (PI / 3.0)
			else:
				channel_id = "farm_channel_tee"
				channel_yaw = 0.0

		for lod in range(3):
			instantiate_kit_part(channel_id, lod, lod_nodes[lod], Vector3.ZERO, channel_yaw)

	# 4. Sparing Granary on outer farm margins (only ~25% of outer-edge farm hexes)
	var is_outer_farm := farm_border_mask != 0b111111
	var seed_val := posmod(q * 17 + r * 31, 4)
	if is_outer_farm and seed_val == 0:
		var unblocked_dir := 0
		for d in range(6):
			if (farm_border_mask & (1 << d)) == 0 and (river_mask & (1 << d)) == 0:
				unblocked_dir = d; break
		var granary_angle := float(unblocked_dir) * (PI / 3.0) + PI / 6.0
		var granary_pos := Vector3(cos(granary_angle) * 11.2, 0.0, sin(granary_angle) * 11.2)
		for lod in range(3):
			instantiate_kit_part("building_farm_granary", lod, lod_nodes[lod], granary_pos, granary_angle + PI, 0.85)

	hex_assemblies.append({
		"kind": "farm",
		"coord": Vector2i(q, r),
		"centroid": c,
		"root": hex_root,
		"lod_nodes": lod_nodes,
		"current_lod": -1
	})

func is_lowland_basin(q: int, r: int) -> bool:
	# Deterministic ~42% lowland basin cluster near rivers
	for dq in range(-2, 3):
		for dr in range(-2, 3):
			if absi(dq + dr) <= 2:
				var key := hex_key(q + dq, r + dr)
				if tile_lookup.has(key) and cells[tile_lookup[key]]["kind"] == "river":
					return posmod(q * 11 + r * 23, 100) < 42
	return false

func determine_farm_type(q: int, r: int) -> String:
	var override_key := "%d,%d" % [q, r]
	var ovr: Dictionary = hex_overrides.get(override_key, {})
	var ft := String(ovr.get("farm_type", ""))
	if ft != "": return ft
	var has_mtn := false
	var has_wtr := false
	for d in range(6):
		var nkey := hex_key(q + DIRS[d].x, r + DIRS[d].y)
		if tile_lookup.has(nkey):
			var nk: String = cells[tile_lookup[nkey]]["kind"]
			if nk == "mountain": has_mtn = true
			elif nk == "river" or nk == "water": has_wtr = true
	if has_mtn: return "terraced_field"
	if has_wtr or is_lowland_basin(q, r): return "rice_field"
	return "dry_field"

# ----------------------------------------------------------------------------------
# Village Hex Modular Composition
# ----------------------------------------------------------------------------------

func build_village_hex(cell: Dictionary) -> void:
	var q := int(cell["q"])
	var r := int(cell["r"])
	var c := center(q, r)
	var variant := int(cell["variant"])
	var override_key := "%d,%d" % [q, r]
	var ovr: Dictionary = hex_overrides.get(override_key, {})

	# 1. Entrance direction pointing towards adjacent farm/plain
	var valid_entrance_dirs: Array[int] = []
	for d in range(6):
		var dir_vec: Vector2i = DIRS[d]
		var nkey := hex_key(q + dir_vec.x, r + dir_vec.y)
		if tile_lookup.has(nkey):
			var nkind: String = cells[tile_lookup[nkey]]["kind"]
			if nkind == "farm" or nkind == "plain":
				valid_entrance_dirs.append(d)

	var entrance_dir := 0
	if not valid_entrance_dirs.is_empty():
		entrance_dir = valid_entrance_dirs[posmod(q * 7 + r * 13, valid_entrance_dirs.size())]
	else:
		entrance_dir = posmod(q + r, 6)

	if ovr.has("entrance_dir"):
		entrance_dir = int(ovr["entrance_dir"])

	var entrance_angle := float(entrance_dir) * (PI / 3.0)
	var entrance_yaw := -entrance_angle

	# 2. Spatial Archetype (0: courtyard_plaza, 1: market_street, 2: alley_hamlet, 3: walled_compound)
	var archetype := posmod(q * 31 + r * 17 + variant, 4)
	if ovr.has("archetype"):
		archetype = int(ovr["archetype"])

	# Hex root container
	var hex_root := Node3D.new()
	hex_root.name = "village_%d_%d" % [q, r]
	hex_root.position = c
	settlement_farm_node.add_child(hex_root)

	var lod_nodes := [Node3D.new(), Node3D.new(), Node3D.new()]
	for lod in range(3):
		lod_nodes[lod].name = "lod%d" % lod
		hex_root.add_child(lod_nodes[lod])

	# 3. Shared Courtyard Ground Apron (village_courtyard_apron)
	for lod in range(3):
		instantiate_kit_part("village_courtyard_apron", lod, lod_nodes[lod], Vector3.ZERO, entrance_yaw)

	# 4. Entrance Gate and Flanking Walls (continuous straight wall strictly inside village hex)
	var gate_dist := 12.4
	var edge_normal := Vector3(cos(entrance_angle), 0.0, sin(entrance_angle))
	var edge_tangent := Vector3(-sin(entrance_angle), 0.0, cos(entrance_angle))
	var gate_pos := edge_normal * gate_dist
	var gate_yaw := entrance_yaw + PI * 0.5
	var wall_yaw := entrance_yaw + PI * 0.5

	# Gate
	for lod in range(3):
		instantiate_kit_part("building_gate", lod, lod_nodes[lod], gate_pos, gate_yaw, 1.0)

	# Flanking Perimeter Walls (village_wall_segment at ±4.8m, village_wall_corner at ±8.2m)
	var wall_left_pos := gate_pos + edge_tangent * 4.8
	var wall_right_pos := gate_pos - edge_tangent * 4.8

	for lod in range(3):
		instantiate_kit_part("village_wall_segment", lod, lod_nodes[lod], wall_left_pos, wall_yaw, 1.0)
		instantiate_kit_part("village_wall_segment", lod, lod_nodes[lod], wall_right_pos, wall_yaw, 1.0)
		instantiate_kit_part("village_wall_corner", lod, lod_nodes[lod], gate_pos + edge_tangent * 8.2, wall_yaw, 1.0)
		instantiate_kit_part("village_wall_corner", lod, lod_nodes[lod], gate_pos - edge_tangent * 8.2, wall_yaw, 1.0)

	# 5. Courtyard Props Focal Spot (village_courtyard_props)
	var props_pos := Vector3.ZERO
	if archetype == 1: # market street
		props_pos = Vector3(cos(entrance_angle) * 3.5, 0, sin(entrance_angle) * 3.5)
	else:
		props_pos = Vector3(-cos(entrance_angle) * 1.5, 0, -sin(entrance_angle) * 1.5)

	for lod in range(3):
		instantiate_kit_part("village_courtyard_props", lod, lod_nodes[lod], props_pos, entrance_yaw)

	# 6. Building Arrangements by Archetype (Reserving clear alley width >= 6.4)
	# Buildings: hall, workshop, granary, medium_house, small_house
	var bld_specs: Array = []
	var alley_dir_vec := Vector3(cos(entrance_angle), 0, sin(entrance_angle))
	var alley_perp_vec := Vector3(-sin(entrance_angle), 0, cos(entrance_angle))

	match archetype:
		0: # courtyard_plaza: U-shaped court around central hall and well
			bld_specs = [
				{"id": "building_hall", "pos": -alley_dir_vec * 7.5, "yaw": entrance_yaw, "scale": 1.05},
				{"id": "building_workshop", "pos": -alley_dir_vec * 2.0 + alley_perp_vec * 6.5, "yaw": entrance_yaw - PI * 0.5, "scale": 0.95},
				{"id": "building_granary", "pos": -alley_dir_vec * 2.0 - alley_perp_vec * 6.5, "yaw": entrance_yaw + PI * 0.5, "scale": 0.95},
				{"id": "building_medium_house", "pos": alley_dir_vec * 4.2 + alley_perp_vec * 6.8, "yaw": entrance_yaw - PI * 0.45, "scale": 0.92},
				{"id": "building_small_house", "pos": alley_dir_vec * 4.2 - alley_perp_vec * 6.8, "yaw": entrance_yaw + PI * 0.45, "scale": 0.92}
			]
		1: # market_street: two staggered rows flanking a wide avenue
			bld_specs = [
				{"id": "building_hall", "pos": -alley_dir_vec * 8.5, "yaw": entrance_yaw, "scale": 1.05},
				{"id": "building_workshop", "pos": alley_perp_vec * 6.8, "yaw": entrance_yaw - PI * 0.5, "scale": 0.95},
				{"id": "building_granary", "pos": -alley_dir_vec * 4.5 - alley_perp_vec * 6.2, "yaw": entrance_yaw + PI * 0.5, "scale": 0.92},
				{"id": "building_medium_house", "pos": alley_dir_vec * 4.0 - alley_perp_vec * 6.6, "yaw": entrance_yaw + PI * 0.5, "scale": 0.95},
				{"id": "building_small_house", "pos": -alley_dir_vec * 4.5 + alley_perp_vec * 6.2, "yaw": entrance_yaw - PI * 0.5, "scale": 0.90},
				{"id": "building_small_house", "pos": alley_dir_vec * 5.0 + alley_perp_vec * 6.8, "yaw": entrance_yaw - PI * 0.5, "scale": 0.88}
			]
		2: # alley_hamlet: organic compounds with side yards
			bld_specs = [
				{"id": "building_hall", "pos": -alley_dir_vec * 6.8 - alley_perp_vec * 3.5, "yaw": entrance_yaw + 0.35, "scale": 1.0},
				{"id": "building_granary", "pos": -alley_dir_vec * 7.5 + alley_perp_vec * 4.5, "yaw": entrance_yaw - 0.4, "scale": 0.90},
				{"id": "building_workshop", "pos": -alley_perp_vec * 6.5, "yaw": entrance_yaw + PI * 0.5, "scale": 0.92},
				{"id": "building_medium_house", "pos": alley_dir_vec * 3.5 + alley_perp_vec * 6.2, "yaw": entrance_yaw - PI * 0.5, "scale": 0.95},
				{"id": "building_small_house", "pos": alley_dir_vec * 4.2 - alley_perp_vec * 6.5, "yaw": entrance_yaw + PI * 0.5, "scale": 0.90}
			]
		3: # walled_compound: semi-enclosed defensive ward with corner walls
			bld_specs = [
				{"id": "building_hall", "pos": -alley_dir_vec * 7.8, "yaw": entrance_yaw, "scale": 1.05},
				{"id": "building_workshop", "pos": -alley_dir_vec * 3.0 + alley_perp_vec * 6.5, "yaw": entrance_yaw - PI * 0.5, "scale": 0.95},
				{"id": "building_granary", "pos": -alley_dir_vec * 3.0 - alley_perp_vec * 6.5, "yaw": entrance_yaw + PI * 0.5, "scale": 0.95},
				{"id": "building_medium_house", "pos": alley_dir_vec * 3.8 + alley_perp_vec * 6.5, "yaw": entrance_yaw - PI * 0.5, "scale": 0.92},
				{"id": "building_small_house", "pos": alley_dir_vec * 3.8 - alley_perp_vec * 6.5, "yaw": entrance_yaw + PI * 0.5, "scale": 0.92}
			]

	for bld in bldspecs_array(bld_specs):
		for lod in range(3):
			instantiate_kit_part(bld["id"], lod, lod_nodes[lod], bld["pos"], bld["yaw"], bld.get("scale", 1.0))

	hex_assemblies.append({
		"kind": "village",
		"coord": Vector2i(q, r),
		"centroid": c,
		"root": hex_root,
		"lod_nodes": lod_nodes,
		"current_lod": -1
	})

func bldspecs_array(arr: Array) -> Array:
	return arr

# ----------------------------------------------------------------------------------
# Distance-Based LOD & Input Controls
# ----------------------------------------------------------------------------------

func update_lod() -> void:
	super.update_lod()
	if hex_assemblies.is_empty(): return

	for hex in hex_assemblies:
		var desired_lod := 0
		if active_kit_lod >= 0:
			desired_lod = active_kit_lod
		else:
			var dist: float = camera.position.distance_to(hex["centroid"])
			if dist < 260.0: desired_lod = 0
			elif dist < 560.0: desired_lod = 1
			else: desired_lod = 2

		if desired_lod != hex["current_lod"]:
			hex["lod_nodes"][0].visible = (desired_lod == 0)
			hex["lod_nodes"][1].visible = (desired_lod == 1)
			hex["lod_nodes"][2].visible = (desired_lod == 2)
			hex["current_lod"] = desired_lod

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_F1: active_kit_lod = 0; update_lod(); print("[LOD] Forced LOD0")
			KEY_F2: active_kit_lod = 1; update_lod(); print("[LOD] Forced LOD1")
			KEY_F3: active_kit_lod = 2; update_lod(); print("[LOD] Forced LOD2")
			KEY_F4: active_kit_lod = -1; update_lod(); print("[LOD] Dynamic Distance LOD")
			KEY_1: focus_district1_near()
			KEY_2: focus_district1_mid()
			KEY_3: focus_district1_far()
			KEY_4: focus_village_near()
			KEY_5: focus_farms_near()
			KEY_6: focus_district2_mid()
			KEY_7: show_world()
			KEY_8: focus_crossing()
			KEY_9: focus_northern_bend()
	super._input(event)

func make_ui() -> void:
	super.make_ui()
	var column: VBoxContainer = info.get_parent()

	var sep := HSeparator.new()
	column.add_child(sep)

	var vtitle := Label.new()
	vtitle.text = "마을·농작지 부품화 시스템\n[F1:LOD0 | F2:LOD1 | F3:LOD2 | F4:Auto]"
	vtitle.add_theme_font_size_override("font_size", 14)
	column.add_child(vtitle)

	var b_dist1 := Button.new()
	b_dist1.text = "1. 대표 구역 (마을+농작+강+산): 근접"
	b_dist1.pressed.connect(focus_district1_near)
	column.add_child(b_dist1)

	var b_dist1_mid := Button.new()
	b_dist1_mid.text = "2. 대표 구역: 중거리"
	b_dist1_mid.pressed.connect(focus_district1_mid)
	column.add_child(b_dist1_mid)

	var b_dist1_far := Button.new()
	b_dist1_far.text = "3. 대표 구역: 원거리"
	b_dist1_far.pressed.connect(focus_district1_far)
	column.add_child(b_dist1_far)

	var b_village := Button.new()
	b_village.text = "4. 마을 클로즈업 (공용 마당·성벽)"
	b_village.pressed.connect(focus_village_near)
	column.add_child(b_village)

	var b_farm := Button.new()
	b_farm.text = "5. 농경지·논둑·수로 클로즈업"
	b_farm.pressed.connect(focus_farms_near)
	column.add_child(b_farm)

	var b_dist2 := Button.new()
	b_dist2.text = "6. 제2 구역: 중거리"
	b_dist2.pressed.connect(focus_district2_mid)
	column.add_child(b_dist2)

# ----------------------------------------------------------------------------------
# Camera Bookmarks
# ----------------------------------------------------------------------------------

func focus_district1_near() -> void:
	# District 1: q=1, r=14 (Village + Farmland + River + Mountain all in one frame)
	target = center(1, 14)
	camera.size = 110.0
	yaw = 0.18
	orbit = 0.72
	update_camera()

func focus_district1_mid() -> void:
	target = center(1, 14)
	camera.size = 230.0
	yaw = 0.18
	orbit = 0.72
	update_camera()

func focus_district1_far() -> void:
	target = center(1, 14)
	camera.size = 460.0
	yaw = 0.18
	orbit = 0.72
	update_camera()

func focus_village_near() -> void:
	# Close-up on core village courtyard and alley
	target = center(-3, 1)
	camera.size = 75.0
	yaw = 0.22
	orbit = 0.68
	update_camera()

func focus_farms_near() -> void:
	# Close-up on rice paddy & dry field expanse
	target = center(-4, 1)
	camera.size = 85.0
	yaw = 0.15
	orbit = 0.65
	update_camera()

func focus_district2_mid() -> void:
	# District 2: q=-7, r=-6
	target = center(-7, -6)
	camera.size = 220.0
	yaw = 0.15
	orbit = 0.72
	update_camera()

func focus_crossing() -> void:
	target = center(0, 0)
	camera.size = 140.0
	yaw = 0.12
	orbit = 0.78
	update_camera()

func focus_northern_bend() -> void:
	target = center(2, 17)
	camera.size = 160.0
	yaw = 0.12
	orbit = 0.78
	update_camera()

func save_render_png(name: String) -> void:
	await RenderingServer.frame_post_draw
	var img := root.get_texture().get_image()
	var path := RENDERS_DIR.path_join(name + ".png")
	img.save_png(path)
	print("[SettlementFarmWorld] Saved render: ", path)

# ----------------------------------------------------------------------------------
# Capture & Validation Suite (Same-Camera Before vs After)
# ----------------------------------------------------------------------------------

func capture_suite() -> void:
	print("[SettlementFarmWorld] Starting automated verification & capture suite...")
	ui.visible = false
	lock_detail = true

	var shots := [
		{"name": "district-after-near", "fn": Callable(self, "focus_district1_near"), "lod": 0},
		{"name": "district-after-mid",  "fn": Callable(self, "focus_district1_mid"),  "lod": 1},
		{"name": "district-after-far",  "fn": Callable(self, "focus_district1_far"),  "lod": 2},
		{"name": "village-after-near",  "fn": Callable(self, "focus_village_near"),   "lod": 0},
		{"name": "farms-after-near",    "fn": Callable(self, "focus_farms_near"),     "lod": 0},
		{"name": "district2-after-mid", "fn": Callable(self, "focus_district2_mid"),  "lod": 1},
		{"name": "full-map-after-overview", "fn": Callable(self, "show_world"),        "lod": 2}
	]

	var metrics_report: Dictionary = {
		"timestamp": Time.get_datetime_string_from_system(),
		"engine": Engine.get_version_info(),
		"gpu": RenderingServer.get_video_adapter_name(),
		"contract": {
			"hexScale": "DEV flat-top R=18.0",
			"totalHexes": cells.size(),
			"villageHexes": 23,
			"farmHexes": 120
		},
		"renders": {}
	}

	# 1. Run After Captures (Modular Kit)
	print("\n--- Capturing AFTER (Modular Village & Farmland Kit) ---")
	legacy_mode = false
	if settlement_farm_node != null: settlement_farm_node.visible = true

	for shot in shots:
		active_kit_lod = shot["lod"]
		shot["fn"].call()
		await wait_frames(10)
		await RenderingServer.frame_post_draw

		var perf := record_performance_snapshot()
		var render_name: String = shot["name"]
		await save_render_png(render_name)

		metrics_report["renders"][render_name] = perf
		print("Captured AFTER: ", render_name, " | Tris: ", perf.get("primitives", 0), " | DrawCalls: ", perf.get("draw_calls", 0))

	# 2. Toggle to Legacy Mode and Run Before Captures (Same cameras!)
	print("\n--- Capturing BEFORE (Legacy DEV Baseline) ---")
	legacy_mode = true
	if settlement_farm_node != null: settlement_farm_node.visible = false
	# Rebuild props in legacy mode
	recompose()
	await wait_frames(15)

	var before_shots := [
		{"name": "district-before-near", "fn": Callable(self, "focus_district1_near")},
		{"name": "district-before-mid",  "fn": Callable(self, "focus_district1_mid")},
		{"name": "district-before-far",  "fn": Callable(self, "focus_district1_far")},
		{"name": "village-before-near",  "fn": Callable(self, "focus_village_near")},
		{"name": "farms-before-near",    "fn": Callable(self, "focus_farms_near")}
	]

	for shot in before_shots:
		shot["fn"].call()
		await wait_frames(10)
		await RenderingServer.frame_post_draw

		var perf := record_performance_snapshot()
		await save_render_png(shot["name"])
		metrics_report["renders"][shot["name"]] = perf
		print("Captured BEFORE: ", shot["name"], " | Tris: ", perf.get("primitives", 0), " | DrawCalls: ", perf.get("draw_calls", 0))

	# 3. Write validation evidence JSON
	var evidence_file := EVIDENCE_DIR.path_join("godot-world-validation.json")
	var f := FileAccess.open(evidence_file, FileAccess.WRITE)
	f.store_string(JSON.stringify(metrics_report, "\t"))
	f.close()
	print("\n[SettlementFarmWorld] Evidence saved to: ", evidence_file)

	quit(0)

func record_performance_snapshot() -> Dictionary:
	return {
		"primitives": Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME),
		"draw_calls": Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
		"objects": Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME),
		"vram_mb": Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / (1024.0 * 1024.0),
		"fps": Performance.get_monitor(Performance.TIME_FPS),
		"process_time_ms": Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	}
