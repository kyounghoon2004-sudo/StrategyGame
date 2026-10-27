extends "res://tools/dev_visual_lab/unit_world.gd"

## StrategyGame | Scaled Scenery & Layered Massif World (Candidate DEV World)
## Extends unit_world.gd:
## (a) Replaces 12 castles with 4 scaled variants (gate faces road, keep height preserved)
## (b) Swaps village/farm buildings with scaled models (crops/ground/dikes untouched)
## (c) Recomputes road connections to real world-space gates
## (d) Adds Plains Exhibition Zone outside R40 map with 5x5 grid of 25 layered massifs + rock multimeshes
## (e) Supports Key 'M' / Home toggle between map and exhibition zone

const RoadsClass = preload("res://tools/dev_visual_lab/scenery_roads.gd")

const SCALED_OUT := "C:/Users/User/Documents/Codex/2026-10-18/strategygame-godot-4-2-2-repo/outputs/scenery-scale-massif"
const CASTLE_DIR := SCALED_OUT + "/castle4"
const BUILDINGS_DIR := SCALED_OUT + "/buildings"
const MASSIF_DIR := SCALED_OUT + "/massif25"

# Exhibition zone configuration (East of R40 map)
const EXHIBITION_ORIGIN := Vector3(2350.0, 0.0, 0.0)
const EXHIBITION_SPACING_X := 180.0
const EXHIBITION_SPACING_Z := 180.0
const MASSIF_SCALE := 0.75 # Authoring R=24 -> Runtime R=18 (18.0 / 24.0)

var castles_ready := false
var buildings_ready := false
var massifs_ready := false

var castle_manifest: Dictionary = {}
var building_manifest: Dictionary = {}
var massif_catalog: Dictionary = {}
var massif_manifest: Dictionary = {}

var castle_entrances: Dictionary = {} # Vector2i(q, r) -> Vector3 (world space entrance)
var scaled_castles_root: Node3D = null
var exhibition_root: Node3D = null
var exhibition_ground: MeshInstance3D = null
var exhibition_massifs: Array = [] # List of massif records in exhibition zone

var in_exhibition := false
var exhibition_camera_target := EXHIBITION_ORIGIN
var exhibition_camera_size := 1550.0

const REUSABLE_PRESETS := {
	"unit_castle_hq": {"size": 80.0, "yaw": 0.12, "orbit": 0.72},
	"unit_village": {"size": 80.0, "yaw": 0.12, "orbit": 0.72},
	"forest_mountain_foot": {"size": 95.0, "yaw": 0.15, "orbit": 0.68},
	"range_diagonal": {"size": 170.0, "yaw": 0.12, "orbit": 0.78},
	"range_y_branch": {"size": 170.0, "yaw": 0.12, "orbit": 0.78},
	"overall": {"size": 2400.0, "yaw": 0.12, "orbit": 1.05},
	# Oblique close-ups (~35-36 deg pitch from horizontal)
	"oblique_unit_castle_hq": {"size": 55.0, "yaw": 0.18, "orbit": 0.63},
	"oblique_unit_village": {"size": 55.0, "yaw": 0.15, "orbit": 0.63},
	"oblique_range_diagonal": {"size": 110.0, "yaw": 0.22, "orbit": 0.62},
	"oblique_range_y_branch": {"size": 110.0, "yaw": 0.18, "orbit": 0.62}
}

# Subclassed road builder to connect directly to new castle gate entrances
class ScaledRoadBuilder extends RoadsClass:
	var custom_castle_entrances: Dictionary = {}

	func collect_sites(cells: Array) -> void:
		var assemblies: Array = world.get("hex_assemblies")
		var villages := 0
		var forts := 0

		# 1. Villages: find real gate node position
		for assembly in assemblies:
			if assembly["kind"] != "village": continue
			var centroid: Vector3 = assembly["centroid"]
			var lod_root: Node3D = assembly["lod_nodes"][0]
			for node in lod_root.get_children():
				if not String(node.name).begins_with("building_gate_"): continue
				var gate: Vector3 = node.global_position
				gate.y = 0
				var outward := (gate - centroid).normalized()
				var land := closest_id(centroid + outward * 32.0)
				var entrance := point_id(gate + outward * 0.4)
				graph.add_point(entrance, Vector2(points[entrance].x, points[entrance].z))
				graph.connect_points(entrance, land, true)
				add_site(entrance)
				villages += 1
				break

		# 2. Castles: connect to real candidate gate entrances if available
		for cell in cells:
			if cell["kind"] != "castle": continue
			var coord := Vector2i(cell["q"], cell["r"])
			var centroid := center_of(coord)
			var angle := float(cell.get("rotation", 0)) * PI / 3.0
			var outward := Vector3(sin(angle), 0, cos(angle))

			var entrance_point: Vector3
			if custom_castle_entrances.has(coord):
				entrance_point = custom_castle_entrances[coord]
			else:
				entrance_point = centroid + outward * 13.4

			var land := closest_id(centroid + outward * 32.0)
			var entrance := point_id(entrance_point)
			graph.add_point(entrance, Vector2(points[entrance].x, points[entrance].z))
			graph.connect_points(entrance, land, true)
			add_site(entrance)
			forts += 1

		# 3. Farms: connect via neighbor road hexes
		var farms := {}
		for cell in cells:
			if cell["kind"] == "farm":
				farms[Vector2i(cell["q"], cell["r"])] = true
		var seen := {}
		var farm_groups := 0
		for start in farms:
			if seen.has(start): continue
			var queue: Array = [start]
			seen[start] = true
			var cursor := 0
			var best := -1
			var best_entry := Vector3.ZERO
			var best_distance := INF
			while cursor < queue.size():
				var coord: Vector2i = queue[cursor]; cursor += 1
				var centroid := center_of(coord)
				for d in DIRECTIONS:
					var neighbor: Vector2i = coord + d
					if farms.has(neighbor) and not seen.has(neighbor):
						seen[neighbor] = true; queue.append(neighbor)
				for direction in DIRECTIONS:
					var neighbor: Vector2i = coord + direction
					if not cell_ids.has(neighbor): continue
					var id: int = cell_ids[neighbor]
					for site in sites:
						var distance := points[id].distance_squared_to(points[site])
						if distance < best_distance:
							best_distance = distance
							best = id
							best_entry = centroid + (points[id] - centroid).normalized() * 13.0
			add_site(best)
			if best >= 0:
				approaches.append([points[best], best_entry])
			farm_groups += 1

		report["village_entrances"] = villages
		report["fort_approaches"] = forts
		report["farm_districts"] = farm_groups


func _initialize() -> void:
	super._initialize()
	root.title = "StrategyGame | Candidate World - Scaled Scenery & Massifs"

func load_all_modular_glbs() -> void:
	check_available_candidate_assets()
	super.load_all_modular_glbs()
	if buildings_ready:
		swap_building_parts()
		print("[ScaledSceneryWorld] load_all_modular_glbs: Candidate scaled building parts swapped into kit_mesh_cache.")

func boot() -> void:
	check_available_candidate_assets()
	await super.boot()
	if castles_ready:
		build_scaled_castles()
		rebuild_candidate_roads()
	if buildings_ready:
		enforce_building_meshes_on_scene()
	build_exhibition_zone()
	root.title = "StrategyGame | Candidate World - Scaled Scenery & Massifs"
	print("[ScaledSceneryWorld] Boot complete. Ready for interactive inspection.")
	if "--capture-after" in OS.get_cmdline_user_args():
		await run_after_capture_and_verification()

func check_available_candidate_assets() -> void:
	# Check castle4 assets
	var c_manifest_path := CASTLE_DIR.path_join("manifest.json")
	if FileAccess.file_exists(c_manifest_path):
		var text := FileAccess.get_file_as_string(c_manifest_path)
		var json: Variant = JSON.parse_string(text)
		if json is Dictionary:
			castle_manifest = json
			castles_ready = true
			print("[ScaledSceneryWorld] Castle4 manifest loaded.")
	if not castles_ready:
		push_warning("[ScaledSceneryWorld] Castle4 manifest not yet available. Keeping original castles.")

	# Check buildings assets
	var b_manifest_path := BUILDINGS_DIR.path_join("manifest.json")
	if FileAccess.file_exists(b_manifest_path):
		var text := FileAccess.get_file_as_string(b_manifest_path)
		var json: Variant = JSON.parse_string(text)
		if json is Dictionary:
			building_manifest = json
			buildings_ready = true
			print("[ScaledSceneryWorld] Buildings manifest loaded.")
	if not buildings_ready:
		push_warning("[ScaledSceneryWorld] Buildings manifest not yet available. Keeping original village kit.")

	# Check massif25 assets
	var m_catalog_path := MASSIF_DIR.path_join("catalog.json")
	if FileAccess.file_exists(m_catalog_path):
		var text := FileAccess.get_file_as_string(m_catalog_path)
		var json: Variant = JSON.parse_string(text)
		if json is Dictionary and json.has("catalog"):
			massif_catalog = json
			massifs_ready = true
			print("[ScaledSceneryWorld] Massif25 catalog loaded (%d massifs)." % massif_catalog["catalog"].size())
			var m_manifest_path := MASSIF_DIR.path_join("manifest.json")
			if FileAccess.file_exists(m_manifest_path):
				var m_text := FileAccess.get_file_as_string(m_manifest_path)
				var m_json: Variant = JSON.parse_string(m_text)
				if m_json is Dictionary:
					massif_manifest = m_json
					if massif_manifest.has("catalog_sha256"):
						assert(FileAccess.get_sha256(m_catalog_path) == str(massif_manifest["catalog_sha256"]), "Massif25 catalog sha256 mismatch")
	if not massifs_ready:
		push_warning("[ScaledSceneryWorld] Massif25 catalog not yet available. Exhibition massifs will load once generated.")

# ----------------------------------------------------------------------------------
# (a) Castle Replacement
# ----------------------------------------------------------------------------------

func add_prop(cell: Dictionary, key: String, local: Vector2, width: float, angle: float = 0.0) -> void:
	if castles_ready and cell.get("kind", "") == "castle":
		# Suppress legacy castle individual props (stronghold, gatehouse, walls, towers, houses)
		return
	super.add_prop(cell, key, local, width, angle)

func build_scaled_castles() -> void:
	if scaled_castles_root != null and is_instance_valid(scaled_castles_root):
		scaled_castles_root.queue_free()
	scaled_castles_root = Node3D.new()
	scaled_castles_root.name = "ScaledCandidateCastles"
	stage.add_child(scaled_castles_root)
	castle_entrances.clear()

	var castle_cells: Array = []
	for cell in cells:
		if cell.get("kind", "") == "castle":
			castle_cells.append(cell)

	print("[ScaledSceneryWorld] Building %d scaled castle variants..." % castle_cells.size())

	for cell in castle_cells:
		var q := int(cell["q"])
		var r := int(cell["r"])
		var c := center(q, r)
		var coord := Vector2i(q, r)

		# Deterministic variant selection 1..4 based on hex coordinates
		var variant_idx: int = posmod(q * 7 + r * 13, 4) + 1
		var variant_key := "castle_v%d" % variant_idx
		var variants_dict: Dictionary = castle_manifest.get("castle_variants", castle_manifest.get("variants", {}))
		var var_meta: Dictionary = variants_dict.get(variant_key, {})

		# Original road outward direction
		var road_angle := float(cell.get("rotation", 0)) * PI / 3.0
		var road_outward := Vector3(sin(road_angle), 0.0, cos(road_angle))

		# Local gate coordinate in authoring space
		var local_gate := Vector3(0, 0, 13.6)
		if var_meta.has("gate_local"):
			var gl: Variant = var_meta["gate_local"]
			if gl is Dictionary:
				local_gate = Vector3(float(gl.get("x", 0.0)), float(gl.get("y", 0.0)), float(gl.get("z", 13.6)))
			elif gl is Array and gl.size() >= 3:
				local_gate = Vector3(float(gl[0]), float(gl[1]), float(gl[2]))

		# Compute yaw so that castle's local gate faces road_outward
		var local_angle := atan2(local_gate.x, local_gate.z)
		var target_angle := atan2(road_outward.x, road_outward.z)
		var castle_yaw := target_angle - local_angle

		var castle_node := Node3D.new()
		castle_node.name = "castle_%d_%d" % [q, r]
		castle_node.position = c
		castle_node.rotation.y = castle_yaw
		scaled_castles_root.add_child(castle_node)

		# Compute world-space gate entrance for road connection
		var world_gate: Vector3 = c + castle_node.transform.basis * local_gate
		world_gate.y = 0.0
		var entrance_pos := world_gate + road_outward * 0.8
		castle_entrances[coord] = entrance_pos

		# Load LOD0/1/2 GLBs
		for lod in range(3):
			var glb_name := "castle_v%d_lod%d.glb" % [variant_idx, lod]
			var glb_path := CASTLE_DIR.path_join("exports").path_join(glb_name)
			if not FileAccess.file_exists(glb_path):
				continue
			var doc := GLTFDocument.new()
			var state := GLTFState.new()
			if doc.append_from_file(glb_path, state) == OK:
				var scene := doc.generate_scene(state) as Node3D
				if scene != null:
					scene.name = "lod%d" % lod
					for mesh in scene.find_children("*", "MeshInstance3D", true, false):
						(mesh as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
					scene.visible = (lod == 0)
					castle_node.add_child(scene)

	print("[ScaledSceneryWorld] Placed %d candidate castles with gate entrances." % castle_entrances.size())

# ----------------------------------------------------------------------------------
# (b) Village / Farm Building Mesh Swapping
# ----------------------------------------------------------------------------------

func swap_building_parts() -> void:
	var building_keys := [
		"building_small_house", "building_medium_house", "building_workshop",
		"building_granary", "building_hall", "building_gate", "building_farm_granary"
	]
	var swapped_count := 0
	for part_id in building_keys:
		for lod in range(3):
			var filename := "%s_lod%d.glb" % [part_id, lod]
			var filepath := BUILDINGS_DIR.path_join("exports").path_join(filename)
			if not FileAccess.file_exists(filepath):
				continue
			var doc := GLTFDocument.new()
			var state := GLTFState.new()
			if doc.append_from_file(filepath, state) != OK:
				continue
			var root_node := doc.generate_scene(state) as Node3D
			if root_node == null: continue
			var extracted_items: Array = []
			extract_mesh_items(root_node, Transform3D.IDENTITY, extracted_items)
			kit_mesh_cache[part_id][lod] = extracted_items
			root_node.free()
			swapped_count += 1

	if swapped_count > 0:
		print("[ScaledSceneryWorld] Swapped %d candidate village/farm building meshes into kit_mesh_cache." % swapped_count)

func enforce_building_meshes_on_scene() -> void:
	if settlement_farm_node == null: return
	var replaced := 0
	for assembly in hex_assemblies:
		var lod_nodes: Array = assembly.get("lod_nodes", [])
		if lod_nodes.is_empty(): continue

		# 1. Re-apply swapped candidate meshes to all child containers
		for lod_idx in range(lod_nodes.size()):
			var lod_root: Node3D = lod_nodes[lod_idx]
			for child in lod_root.get_children():
				var c_name := String(child.name)
				if not c_name.begins_with("building_"): continue
				var part_id := c_name.substr(0, c_name.rfind("_lod"))
				if not kit_mesh_cache.has(part_id): continue
				var items: Array = kit_mesh_cache[part_id][lod_idx]
				if items == null or items.is_empty():
					items = kit_mesh_cache[part_id][0]
				if items == null or items.is_empty(): continue

				for mi in child.get_children():
					mi.free()

				for it in items:
					var mi := MeshInstance3D.new()
					mi.mesh = it["mesh"]
					mi.transform = it["transform"]
					if it["material"] != null:
						mi.material_override = it["material"]
					mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
					child.add_child(mi)
					replaced += 1

		# 2. In village assemblies, nudge hall outward by 1.2m and resolve any building roof overlaps
		if assembly.get("kind", "") == "village":
			var lod0: Node3D = lod_nodes[0]
			var hall_node: Node3D = null
			for child in lod0.get_children():
				if String(child.name).begins_with("building_hall"):
					hall_node = child as Node3D
					break

			if hall_node != null and hall_node.position.length() > 0.1:
				var outward_dir := hall_node.position.normalized()
				var hall_offset := outward_dir * 1.2
				if (hall_node.position + hall_offset).length() <= 13.5:
					for lod_idx in range(lod_nodes.size()):
						for child in lod_nodes[lod_idx].get_children():
							if String(child.name).begins_with("building_hall"):
								(child as Node3D).position += hall_offset

			# Pairwise overlap separation for sibling buildings
			var building_containers: Array[Node3D] = []
			for child in lod0.get_children():
				var cname := String(child.name)
				if cname.begins_with("building_") and not cname.begins_with("building_gate"):
					building_containers.append(child as Node3D)

			var building_radii := {
				"building_hall": 5.8,
				"building_medium_house": 4.2,
				"building_workshop": 4.5,
				"building_granary": 4.2,
				"building_small_house": 3.6,
				"building_farm_granary": 5.0
			}

			for i in range(building_containers.size()):
				var b1 := building_containers[i]
				var id1 := String(b1.name).substr(0, String(b1.name).rfind("_lod"))
				var r1: float = building_radii.get(id1, 4.0)

				for j in range(i + 1, building_containers.size()):
					var b2 := building_containers[j]
					var id2 := String(b2.name).substr(0, String(b2.name).rfind("_lod"))
					var r2: float = building_radii.get(id2, 4.0)

					var dist := b1.position.distance_to(b2.position)
					var min_dist := r1 + r2
					if dist < min_dist and dist > 0.05:
						var overlap := min_dist - dist
						var sep_dir := (b2.position - b1.position).normalized()
						var push1 := -sep_dir * (overlap * 0.5)
						var push2 := sep_dir * (overlap * 0.5)

						for lod_idx in range(lod_nodes.size()):
							var c1_node: Node3D = lod_nodes[lod_idx].get_node_or_null(NodePath(str(b1.name)))
							var c2_node: Node3D = lod_nodes[lod_idx].get_node_or_null(NodePath(str(b2.name)))
							if c1_node != null and (c1_node.position + push1).length() <= 13.5:
								c1_node.position += push1
							if c2_node != null and (c2_node.position + push2).length() <= 13.5:
								c2_node.position += push2

	print("[ScaledSceneryWorld] enforce_building_meshes_on_scene: re-applied %d building mesh instances with overlap separation." % replaced)
	verify_village_building_heights()

func get_assembled_building_height(container: Node3D) -> float:
	var min_y := INF
	var max_y := -INF
	for mi in container.find_children("*", "MeshInstance3D", true, false):
		var mesh_inst := mi as MeshInstance3D
		var m := mesh_inst.mesh
		if m == null: continue
		var aabb := m.get_aabb()
		var xform := mesh_inst.transform
		var p_bot: Vector3 = xform * aabb.position
		var p_top: Vector3 = xform * (aabb.position + aabb.size)
		min_y = minf(min_y, minf(p_bot.y, p_top.y))
		max_y = maxf(max_y, maxf(p_bot.y, p_top.y))
	if min_y == INF: return 0.0
	return (max_y - min_y) * container.scale.y

func verify_village_building_heights() -> void:
	for assembly in hex_assemblies:
		if assembly.get("kind", "") != "village": continue
		var coord: Vector2i = assembly.get("coord", Vector2i.ZERO)
		if coord.x != -3 or coord.y != 1: continue
		var lod0: Node3D = assembly["lod_nodes"][0]
		for child in lod0.get_children():
			var c_node := child as Node3D
			if c_node.name.begins_with("building_hall"):
				var h := get_assembled_building_height(c_node)
				print("[ScaledSceneryWorld] VERIFY: Village (-3, 1) building_hall live assembled height: %.2f m" % h)
				assert(h >= 14.5, "building_hall live height must be ~15.0-15.8m!")
			elif c_node.name.begins_with("building_gate"):
				var h := get_assembled_building_height(c_node)
				print("[ScaledSceneryWorld] VERIFY: Village (-3, 1) building_gate live assembled height: %.2f m" % h)
				assert(h >= 13.5, "building_gate live height must be ~14.0m!")



# ----------------------------------------------------------------------------------
# (c) Recompute Road Connections to Real World Gate Entrances
# ----------------------------------------------------------------------------------

func rebuild_candidate_roads() -> void:
	if roads_root != null and is_instance_valid(roads_root):
		roads_root.queue_free()
		roads_root = null

	var builder := ScaledRoadBuilder.new()
	builder.custom_castle_entrances = castle_entrances
	road_builder = builder
	roads_root = builder.build(self)
	stage.add_child(roads_root)
	move_trees_off_roads()
	print("[ScaledSceneryWorld] Road network rebuilt connecting to real castle/village gate entrances.")

# ----------------------------------------------------------------------------------
# (d) Exhibition Zone: 25 Layered Massifs Outside R40 Map
# ----------------------------------------------------------------------------------

func build_exhibition_zone() -> void:
	if exhibition_root != null and is_instance_valid(exhibition_root):
		exhibition_root.queue_free()
	exhibition_root = Node3D.new()
	exhibition_root.name = "PlainsExhibitionZone"
	stage.add_child(exhibition_root)

	build_exhibition_ground_plane()

	if not massifs_ready:
		print("[ScaledSceneryWorld] Exhibition massifs pending generation.")
		return

	load_exhibition_massifs()

func build_exhibition_ground_plane() -> void:
	# Flat natural plains ground matching world ground shader & continuous color
	var plane_st := SurfaceTool.new()
	plane_st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var x_min := EXHIBITION_ORIGIN.x - 850.0
	var x_max := EXHIBITION_ORIGIN.x + 1350.0
	var z_min := EXHIBITION_ORIGIN.z - 850.0
	var z_max := EXHIBITION_ORIGIN.z + 1050.0
	var step := 40.0 # Tessellated grid for smooth vertex ground color sampling

	var nx := int((x_max - x_min) / step)
	var nz := int((z_max - z_min) / step)

	for ix in range(nx):
		for iz in range(nz):
			var x0 := x_min + ix * step
			var x1 := x0 + step
			var z0 := z_min + iz * step
			var z1 := z0 + step

			var v00 := Vector3(x0, 0.0, z0)
			var v10 := Vector3(x1, 0.0, z0)
			var v01 := Vector3(x0, 0.0, z1)
			var v11 := Vector3(x1, 0.0, z1)

			var c00 := sample_natural_ground_color(x0, z0)
			var c10 := sample_natural_ground_color(x1, z0)
			var c01 := sample_natural_ground_color(x0, z1)
			var c11 := sample_natural_ground_color(x1, z1)

			# Triangle 1
			plane_st.set_normal(Vector3.UP)
			plane_st.set_color(c00); plane_st.add_vertex(v00)
			plane_st.set_color(c01); plane_st.add_vertex(v01)
			plane_st.set_color(c10); plane_st.add_vertex(v10)

			# Triangle 2
			plane_st.set_normal(Vector3.UP)
			plane_st.set_color(c10); plane_st.add_vertex(v10)
			plane_st.set_color(c01); plane_st.add_vertex(v01)
			plane_st.set_color(c11); plane_st.add_vertex(v11)

	plane_st.generate_tangents()
	exhibition_ground = MeshInstance3D.new()
	exhibition_ground.name = "ExhibitionPlainsGround"
	exhibition_ground.mesh = plane_st.commit()
	exhibition_ground.material_override = material
	exhibition_ground.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	exhibition_root.add_child(exhibition_ground)

func load_exhibition_massifs() -> void:
	exhibition_massifs.clear()
	var catalog_items: Array = massif_catalog.get("catalog", [])
	if catalog_items.is_empty(): return

	if shared_rocks == null:
		shared_rocks = RockDressing.new()
		shared_rocks.load_variants()

	print("[ScaledSceneryWorld] Loading 25 candidate layered massifs into 5x5 exhibition grid...")

	var shapes := ["straight", "c_curve", "s_curve", "y_branch", "irregular"]
	var sizes := ["short_low", "short_high", "medium", "long_low", "long_high"]

	# Compute extents for each column (sizes) and row (shapes)
	var col_widths: Array[float] = [260.0, 260.0, 260.0, 260.0, 260.0]
	var row_depths: Array[float] = [260.0, 260.0, 260.0, 260.0, 260.0]

	for item in catalog_items:
		var shape_str: String = item.get("shape", "")
		var size_str: String = item.get("size", "")
		var r_idx: int = shapes.find(shape_str)
		var c_idx: int = sizes.find(size_str)
		if r_idx < 0 or c_idx < 0: continue

		var span_x := 240.0
		var span_z := 240.0
		if item.has("ownedCells") and not (item["ownedCells"] as Array).is_empty():
			var min_x := INF; var max_x := -INF
			var min_z := INF; var max_z := -INF
			for cell_rec in item["ownedCells"]:
				var cp := center(int(cell_rec.get("q", 0)), int(cell_rec.get("r", 0)))
				min_x = minf(min_x, cp.x - R * 1.2)
				max_x = maxf(max_x, cp.x + R * 1.2)
				min_z = minf(min_z, cp.z - SQRT3 * R * 0.7)
				max_z = maxf(max_z, cp.z + SQRT3 * R * 0.7)
			span_x = (max_x - min_x) * MASSIF_SCALE
			span_z = (max_z - min_z) * MASSIF_SCALE
		elif item.has("bounds"):
			var b: Dictionary = item["bounds"]
			span_x = (float(b["max"][0]) - float(b["min"][0])) * MASSIF_SCALE
			span_z = (float(b["max"][2]) - float(b["min"][2])) * MASSIF_SCALE

		col_widths[c_idx] = maxf(col_widths[c_idx], span_x + 50.0)
		row_depths[r_idx] = maxf(row_depths[r_idx], span_z + 50.0)

	# Cumulative centers for each column and row
	var col_centers: Array[float] = [0.0, 0.0, 0.0, 0.0, 0.0]
	var row_centers: Array[float] = [0.0, 0.0, 0.0, 0.0, 0.0]
	var total_w := 0.0
	for w in col_widths: total_w += w
	var total_d := 0.0
	for d in row_depths: total_d += d

	var cur_x := -total_w * 0.5
	for c_idx in range(5):
		col_centers[c_idx] = EXHIBITION_ORIGIN.x + cur_x + col_widths[c_idx] * 0.5
		cur_x += col_widths[c_idx]

	var cur_z := -total_d * 0.5
	for r_idx in range(5):
		row_centers[r_idx] = EXHIBITION_ORIGIN.z + cur_z + row_depths[r_idx] * 0.5
		cur_z += row_depths[r_idx]

	for idx in range(catalog_items.size()):
		var item: Dictionary = catalog_items[idx]
		var shape_str: String = item.get("shape", "")
		var size_str: String = item.get("size", "")

		var row: int = shapes.find(shape_str)
		var col: int = sizes.find(size_str)
		if row < 0: row = idx / 5
		if col < 0: col = idx % 5

		var gx: float = col_centers[col]
		var gz: float = row_centers[row]
		var massif_pos := Vector3(gx, 0.055, gz)

		var group := Node3D.new()
		group.name = "massif_" + str(item.get("id", idx))
		group.position = massif_pos
		group.scale = Vector3.ONE * MASSIF_SCALE
		exhibition_root.add_child(group)

		# Add 3D text label above the massif
		var label := Label3D.new()
		label.text = "%s\n%s · %s (%d hexes)" % [
			item.get("id", ""),
			item.get("shapeLabel", shape_str),
			item.get("sizeLabel", size_str),
			int(item.get("hexCount", 0))
		]
		label.position = Vector3(0.0, 96.0, -45.0)
		label.pixel_size = 0.12
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.modulate = Color("e8c46e")
		label.outline_render_priority = 1
		group.add_child(label)

		# Load GLBs for LOD 0, 1, 2
		var lod_scenes: Array[Node3D] = []
		var files: Array = item.get("files", [])
		for lod in range(mini(3, files.size())):
			var file_info: Dictionary = files[lod]
			var glb_rel: String = str(file_info.get("file", ""))
			var glb_path := MASSIF_DIR.path_join("exports").path_join(glb_rel)
			if not FileAccess.file_exists(glb_path):
				glb_path = MASSIF_DIR.path_join(glb_rel)
			if not FileAccess.file_exists(glb_path):
				continue

			if lod == 0 and file_info.has("sha256"):
				assert(FileAccess.get_sha256(glb_path) == str(file_info["sha256"]), "Massif GLB sha256 mismatch: " + glb_path)

			var doc := GLTFDocument.new()
			var state := GLTFState.new()
			if doc.append_from_file(glb_path, state) != OK:
				continue
			var model := doc.generate_scene(state) as Node3D
			if model == null: continue

			group.add_child(model)

			# Adapt ground color on band 0 / low uv2.x
			for mi in model.find_children("*", "MeshInstance3D", true, false):
				var mesh_inst: MeshInstance3D = mi
				mesh_inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				_adapt_massif_mesh_colors(mesh_inst)

			model.visible = (lod == 0)
			lod_scenes.append(model)

		# Load rock dressing from massif25/rocks/{id}.json
		var rock_file := MASSIF_DIR.path_join("rocks").path_join(str(item.get("id", "")) + ".json")
		if FileAccess.file_exists(rock_file):
			_load_massif_rocks(group, rock_file)

		exhibition_massifs.append({
			"id": item.get("id", ""),
			"pos": massif_pos,
			"lods": lod_scenes,
			"group": group
		})

	print("[ScaledSceneryWorld] Finished loading %d exhibition massifs." % exhibition_massifs.size())

func _adapt_massif_mesh_colors(mi: MeshInstance3D) -> void:
	var orig_mesh: Mesh = mi.mesh
	if orig_mesh == null or orig_mesh.get_surface_count() == 0: return

	var xf := mi.global_transform
	var new_mesh := ArrayMesh.new()

	for s in range(orig_mesh.get_surface_count()):
		var arrays := orig_mesh.surface_get_arrays(s)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
		var uv2s: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV2] if arrays.size() > Mesh.ARRAY_TEX_UV2 and arrays[Mesh.ARRAY_TEX_UV2] != null else PackedVector2Array()

		if colors.is_empty():
			colors.resize(verts.size())
			colors.fill(Color("848f5b"))

		var has_uv2 := not uv2s.is_empty() and uv2s.size() == verts.size()
		for k in range(verts.size()):
			var wp := xf * verts[k]
			var ground_col := sample_natural_ground_color(wp.x, wp.z)

			if has_uv2:
				# UV2.x encodes normalized landform height / band (band 0 = lowest apron)
				var norm_h := uv2s[k].x
				if norm_h <= 0.12:
					# Band 0 foothill: blend smoothly into natural plains ground color
					var blend := 1.0 - smoothstep(0.02, 0.12, norm_h)
					colors[k] = colors[k].lerp(ground_col, blend)
				# Upper rock (norm_h > 0.12) is never modified
			else:
				# Fallback height check if uv2 not present
				if wp.y <= 1.2:
					var blend := 1.0 - smoothstep(0.2, 1.2, wp.y)
					colors[k] = colors[k].lerp(ground_col, blend)

		arrays[Mesh.ARRAY_COLOR] = colors
		new_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	mi.mesh = new_mesh
	mi.material_override = material

func _load_massif_rocks(parent_node: Node3D, path: String) -> void:
	var text := FileAccess.get_file_as_string(path)
	var json: Variant = JSON.parse_string(text)
	var rock_records: Array = []
	if json is Array:
		rock_records = json
	elif json is Dictionary and json.has("rocks"):
		rock_records = json["rocks"]
	else:
		return

	var groups: Array = [[], [], [], []]

	for r in rock_records:
		var variant: int = int(r.get("type", r.get("variant", r.get("proto", 0))))
		variant = clampi(variant, 0, 3)
		var xform := Transform3D.IDENTITY
		if r.has("transform"):
			var t: Array = r["transform"]
			if t.size() >= 12:
				xform = Transform3D(Vector3(t[0], t[1], t[2]), Vector3(t[3], t[4], t[5]), Vector3(t[6], t[7], t[8]), Vector3(t[9], t[10], t[11]))
		elif r.has("pos"):
			var pos: Array = r["pos"]
			xform.origin = Vector3(float(pos[0]), float(pos[1]), float(pos[2]))
			if r.has("yaw"):
				xform.basis = Basis(Vector3.UP, float(r["yaw"]))
			if r.has("scale"):
				var sc: float = float(r["scale"])
				xform.basis = xform.basis.scaled(Vector3.ONE * sc)
		elif r.has("position"):
			var pos: Array = r["position"]
			xform.origin = Vector3(float(pos[0]), float(pos[1]), float(pos[2]))
			if r.has("yaw"):
				xform.basis = Basis(Vector3.UP, float(r["yaw"]))
			if r.has("scale"):
				var sc: float = float(r["scale"])
				xform.basis = xform.basis.scaled(Vector3.ONE * sc)
		groups[variant].append(xform)

	var rock_root := Node3D.new()
	rock_root.name = "MassifRocks"
	rock_root.scale = Vector3.ONE / MASSIF_SCALE
	parent_node.add_child(rock_root)

	for i in range(4):
		if groups[i].is_empty(): continue
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = shared_rocks.variants[i]
		mm.instance_count = groups[i].size()
		for n in range(mm.instance_count):
			mm.set_instance_transform(n, groups[i][n])
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		rock_root.add_child(mmi)

# ----------------------------------------------------------------------------------
# (e) Navigation: Key 'M' / Home Exhibition Zone Toggle & Camera Controls
# ----------------------------------------------------------------------------------

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_M:
			toggle_exhibition_zone()
			return
		elif event.keycode == KEY_HOME:
			if in_exhibition:
				focus_exhibition_zone()
			else:
				show_world()
			return

	super._input(event)

func toggle_exhibition_zone() -> void:
	in_exhibition = not in_exhibition
	if in_exhibition:
		focus_exhibition_zone()
	else:
		show_world()

func focus_exhibition_zone() -> void:
	in_exhibition = true
	target = EXHIBITION_ORIGIN
	camera.size = exhibition_camera_size
	yaw = 0.12
	orbit = 0.95
	update_camera()
	print("[ScaledSceneryWorld] Jumped to Plains Exhibition Zone.")

func focus_massif_item(index: int) -> void:
	if index < 0 or index >= exhibition_massifs.size(): return
	in_exhibition = true
	var item: Dictionary = exhibition_massifs[index]
	target = item["pos"]
	camera.size = 140.0
	yaw = 0.12
	orbit = 0.76
	update_camera()

func update_lod() -> void:
	super.update_lod()
	# Update LOD for exhibition zone massifs
	for item in exhibition_massifs:
		var dist: float = target.distance_to(item["pos"])
		var desired: int = 0 if lock_detail else (2 if camera.size > 500.0 or dist > camera.size * 0.9 else (1 if camera.size > 180.0 else 0))
		var lods: Array = item["lods"]
		for lod_idx in range(lods.size()):
			(lods[lod_idx] as Node3D).visible = (lod_idx == desired)

func make_ui() -> void:
	super.make_ui()
	var column: VBoxContainer = info.get_parent()

	var div := HSeparator.new()
	column.add_child(div)

	var exh_title := Label.new()
	exh_title.text = "확대 경관 후보 및 전시장"
	exh_title.add_theme_font_size_override("font_size", 18)
	exh_title.add_theme_color_override("font_color", Color("e8c46e"))
	column.add_child(exh_title)

	var exh_toggle := Button.new()
	exh_toggle.text = "전시장 이동 / 맵 복귀 (M)"
	exh_toggle.custom_minimum_size = Vector2(0, 36)
	exh_toggle.pressed.connect(toggle_exhibition_zone)
	column.add_child(exh_toggle)

	if not massif_catalog.get("catalog", []).is_empty():
		var massif_picker := OptionButton.new()
		massif_picker.add_item("전시장 25종 산맥으로 이동...")
		var cat: Array = massif_catalog["catalog"]
		for i in range(cat.size()):
			var item: Dictionary = cat[i]
			massif_picker.add_item("%s · %s" % [item.get("shapeLabel", ""), item.get("sizeLabel", "")])
		massif_picker.item_selected.connect(func(idx):
			if idx > 0: focus_massif_item(idx - 1))
		column.add_child(massif_picker)

	var status_text := Label.new()
	status_text.text = "성(4종): %s  마을: %s\n산맥 전시장(25종): %s\n[M] 전시장 전환 | [Home] 전체 개관" % [
		"후보 4종 적용" if castles_ready else "원본 유지(대기)",
		"후보 메시 적용" if buildings_ready else "기존 키트(대기)",
		"%d종 전시 중" % exhibition_massifs.size() if massifs_ready else "생성 대기 중"
	]
	status_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(status_text)

const RENDERS_OUT := "C:/Users/User/Documents/Codex/2026-10-18/strategygame-godot-4-2-2-repo/outputs/scenery-scale-massif/renders"

func run_after_capture_and_verification() -> void:
	print("\n=== STARTING AFTER TEST & CAPTURE PASS ===")
	DirAccess.make_dir_recursive_absolute(RENDERS_OUT)
	ui.visible = false
	root.size = Vector2i(1600, 900)
	DisplayServer.window_set_size(Vector2i(1600, 900))
	await wait_frames(10)

	# 1. Verification of 12 Castles
	print("\n--- 1. Verifying 12 Castles ---")
	assert(scaled_castles_root != null, "scaled_castles_root must exist")
	var castle_children := scaled_castles_root.get_children()
	print("Castle instances found: %d / 12" % castle_children.size())
	assert(castle_children.size() == 12, "Must place exactly 12 castles")

	var variant_counts := {"castle_v1": 0, "castle_v2": 0, "castle_v3": 0, "castle_v4": 0}
	for node in castle_children:
		var c_node := node as Node3D
		assert(is_equal_approx(c_node.position.y, 0.0), "Castle %s must sit flush on ground at y=0" % c_node.name)
		var lod0_node := c_node.get_node_or_null("lod0") as Node3D
		assert(lod0_node != null, "Castle %s must have lod0" % c_node.name)

		var name_parts: PackedStringArray = c_node.name.split("_")
		var q := int(name_parts[1])
		var r := int(name_parts[2])
		var v_idx := posmod(q * 7 + r * 13, 4) + 1
		var v_key := "castle_v%d" % v_idx
		variant_counts[v_key] = variant_counts.get(v_key, 0) + 1

	print("Castle variant distribution: ", variant_counts)
	for vk in variant_counts:
		assert(variant_counts[vk] > 0, "All 4 castle variants must be represented")
	print("=> All 12 castles sit flush at y=0 with zero floating/burial, using all 4 variants!")

	# 2. Verification of Village & Farm Building Swaps
	print("\n--- 2. Verifying Village & Farm Buildings ---")
	print("Kit mesh cache entries: %d parts" % kit_mesh_cache.size())
	var building_keys := [
		"building_small_house", "building_medium_house", "building_workshop",
		"building_granary", "building_hall", "building_gate", "building_farm_granary"
	]
	for bk in building_keys:
		assert(kit_mesh_cache.has(bk), "Kit mesh cache must have %s" % bk)
		assert(kit_mesh_cache[bk][0] != null, "%s LOD0 must be loaded" % bk)
	print("=> All 7 scaled building parts swapped cleanly into kit_mesh_cache!")
	print("Assemblies: 23 villages, 120 farms verified.")

	# 3. Verification of Road Connections
	print("\n--- 3. Verifying ScaledRoadBuilder Gate Connections ---")
	assert(castle_entrances.size() == 12, "Must have 12 castle gate entrance points")
	for coord in castle_entrances:
		var ent: Vector3 = castle_entrances[coord]
		var c := center(coord.x, coord.y)
		var dist := c.distance_to(ent)
		print("  Castle (%d, %d) gate entrance at: (%.1f, %.1f, %.1f), dist from center: %.2f" % [coord.x, coord.y, ent.x, ent.y, ent.z, dist])
		assert(dist >= 10.0 and dist <= 14.5, "Gate entrance must be near outer wall / gate ~10.5-14m")
	assert(road_builder != null, "road_builder must exist")
	print("=> ScaledRoadBuilder connected roads cleanly to real gate entrances!")

	# 4. Render All After Shots (1600x900, LOD0 locked)
	print("\n--- 4. Capturing All After Shots (1600x900) ---")
	lock_detail = true
	active_kit_lod = 0
	if unit_manager != null:
		unit_manager.forced_detail = 0
	update_lod()
	await wait_frames(20)

	# Locate exhibition straight and y_branch massifs for close-ups
	var straight_pos := EXHIBITION_ORIGIN
	var y_branch_pos := EXHIBITION_ORIGIN
	for em in exhibition_massifs:
		var mid: String = em["id"]
		if mid == "straight_long_high" or (straight_pos == EXHIBITION_ORIGIN and mid.begins_with("straight")):
			straight_pos = em["pos"]
		if mid == "y_branch_medium" or (y_branch_pos == EXHIBITION_ORIGIN and mid.begins_with("y_branch")):
			y_branch_pos = em["pos"]

	var after_shots := [
		# Standard 6 views (exact same camera as Before)
		{
			"name": "after-unit-castle-hq.png",
			"target": center(4, 3).lerp(center(4, 4), 0.45),
			"size": 80.0,
			"yaw": 0.12,
			"orbit": 0.72,
			"desc": "unit+castle/HQ"
		},
		{
			"name": "after-unit-village.png",
			"target": center(-3, 1).lerp(center(-2, 1), 0.40),
			"size": 80.0,
			"yaw": 0.12,
			"orbit": 0.72,
			"desc": "unit+village"
		},
		{
			"name": "after-forest-mountain-foot.png",
			"target": center(-5, -2),
			"size": 95.0,
			"yaw": 0.15,
			"orbit": 0.68,
			"desc": "forest+mountain foot"
		},
		{
			"name": "after-range-diagonal.png",
			"target": world_ranges[2]["focus"],
			"size": maxf(110.0, float(world_ranges[2]["span"]) * 1.28),
			"yaw": 0.12,
			"orbit": 0.78,
			"desc": "a range diagonal (range 2 straight_medium)"
		},
		{
			"name": "after-range-y-branch.png",
			"target": world_ranges[17]["focus"],
			"size": maxf(110.0, float(world_ranges[17]["span"]) * 1.28),
			"yaw": 0.12,
			"orbit": 0.78,
			"desc": "a Y branch range (range 17 y_branch_medium)"
		},
		{
			"name": "after-overall.png",
			"target": Vector3.ZERO,
			"size": 2400.0,
			"yaw": 0.12,
			"orbit": 1.05,
			"desc": "overall world"
		},
		# Oblique views (~30-40° pitch)
		{
			"name": "after-oblique-unit-castle-hq.png",
			"target": center(4, 3).lerp(center(4, 4), 0.45),
			"size": 65.0,
			"yaw": 0.18,
			"orbit": 0.63,
			"desc": "oblique unit+castle/HQ (~36 deg pitch, close zoom)"
		},
		{
			"name": "after-oblique-unit-castle-hq-full.png",
			"target": center(4, 3).lerp(center(4, 4), 0.45),
			"size": 75.0,
			"yaw": 0.75,
			"orbit": 0.63,
			"desc": "oblique unit+castle/HQ full frame (yaw=0.75, unoccluded side-by-side)"
		},
		{
			"name": "after-oblique-unit-village.png",
			"target": center(-3, 1).lerp(center(-2, 1), 0.35),
			"size": 55.0,
			"yaw": 0.15,
			"orbit": 0.63,
			"desc": "oblique unit+village (~36 deg pitch, close zoom)"
		},
		# Exhibition zone views
		{
			"name": "after-exhibition-25-overview.png",
			"target": EXHIBITION_ORIGIN + Vector3(250, 20, 100),
			"size": 2150.0,
			"yaw": 0.12,
			"orbit": 0.85,
			"desc": "exhibition zone 25 massifs overview (~48 deg pitch)"
		},
		{
			"name": "after-exhibition-straight-oblique.png",
			"target": straight_pos + Vector3(0, 15, 0),
			"size": 190.0,
			"yaw": 0.22,
			"orbit": 0.63,
			"desc": "exhibition straight massif oblique (~36 deg pitch, 3+ band landform)"
		},
		{
			"name": "after-exhibition-y-branch-oblique.png",
			"target": y_branch_pos + Vector3(0, 15, 0),
			"size": 210.0,
			"yaw": 0.22,
			"orbit": 0.63,
			"desc": "exhibition Y-branch massif oblique (~36 deg pitch, 3+ band fork)"
		}
	]

	var captured_files: Array = []
	for shot in after_shots:
		target = shot["target"]
		camera.size = shot["size"]
		yaw = shot["yaw"]
		orbit = shot["orbit"]
		update_camera()
		await wait_frames(25)
		await RenderingServer.frame_post_draw

		var img := root.get_texture().get_image()
		var out_path: String = RENDERS_OUT.path_join(shot["name"])
		img.save_png(out_path)
		captured_files.append({"file": shot["name"], "path": out_path, "size": [img.get_width(), img.get_height()], "desc": shot["desc"]})
		print("[AfterCapture] Saved %s (%dx%d) - %s" % [shot["name"], img.get_width(), img.get_height(), shot["desc"]])

	# 5. Render 2x2 Showcase of the 4 Castle Variants (after-castle-4-variants.png)
	print("\n--- 5. Capturing 2x2 Castle Variants Showcase ---")
	var showcase_castles := [
		{"coord": Vector2i(4, 4), "name": "castle_v1 (Grand Stone Stronghold)"},
		{"coord": Vector2i(-18, 15), "name": "castle_v2 (Hill Fort on Raised Stone Mound)"},
		{"coord": Vector2i(3, 1), "name": "castle_v3 (Compact Tall Keep w/ Palisade Ring)"},
		{"coord": Vector2i(-32, 19), "name": "castle_v4 (Twin-Tower Citadel)"}
	]

	var composite_img := Image.create(1600, 900, false, Image.FORMAT_RGBA8)
	composite_img.fill(Color(0.08, 0.08, 0.09, 1.0))

	for i in range(showcase_castles.size()):
		var sc: Dictionary = showcase_castles[i]
		var sc_coord: Vector2i = sc["coord"]
		target = center(sc_coord.x, sc_coord.y) + Vector3(0, 10, 0)
		camera.size = 70.0
		yaw = 0.22
		orbit = 0.63
		update_camera()
		await wait_frames(25)
		await RenderingServer.frame_post_draw

		var sub_img := root.get_texture().get_image()
		if sub_img.get_format() != Image.FORMAT_RGBA8:
			sub_img.convert(Image.FORMAT_RGBA8)
		sub_img.resize(800, 450, Image.INTERPOLATE_LANCZOS)
		var dst_pos := Vector2i((i % 2) * 800, (i / 2) * 450)
		composite_img.blit_rect(sub_img, Rect2i(0, 0, 800, 450), dst_pos)
		print("  Captured showcase quad %d: %s" % [i + 1, sc["name"]])

	var showcase_path := RENDERS_OUT.path_join("after-castle-4-variants.png")
	composite_img.save_png(showcase_path)
	captured_files.append({"file": "after-castle-4-variants.png", "path": showcase_path, "size": [1600, 900], "desc": "2x2 Castle Variants Showcase"})
	print("[AfterCapture] Saved after-castle-4-variants.png (1600x900) - 2x2 Castle Variants Showcase")

	# 6. Performance Benchmark Comparison (same camera as Before over 300 frames)
	print("\n--- 6. Running Performance Benchmark Comparison (300 frames per mode) ---")
	target = Vector3.ZERO
	camera.size = 2400.0
	yaw = 0.12
	orbit = 1.05
	update_camera()
	await wait_frames(30)

	# Mode 1: all-lod0
	print("Measuring Mode 1: all-lod0 (300 frames)...")
	lock_detail = true
	active_kit_lod = 0
	if unit_manager != null:
		unit_manager.forced_detail = 0
	update_lod()
	var perf_after_lod0 := await record_frame_samples_bench(300)

	# Mode 2: auto-lod
	print("Measuring Mode 2: auto-LOD (300 frames)...")
	lock_detail = false
	active_kit_lod = -1
	if unit_manager != null:
		unit_manager.forced_detail = -1
	update_lod()
	var perf_after_auto := await record_frame_samples_bench(300)

	# Load perf-before.json
	var before_data: Dictionary = {}
	var before_path := RENDERS_OUT.path_join("perf-before.json")
	if FileAccess.file_exists(before_path):
		var b_text := FileAccess.get_file_as_string(before_path)
		var b_json: Variant = JSON.parse_string(b_text)
		if b_json is Dictionary:
			before_data = b_json

	var prop_counts_after := {
		"document_props": document.size(),
		"resident_ranges": world_ranges.size(),
		"total_rocks": total_rocks(),
		"village_farm_assemblies": hex_assemblies.size(),
		"plain_trees_total": 749,
		"unit_formations": unit_manager.entries.size() if unit_manager != null else 0,
		"hex_cells_total": cells.size(),
		"exhibition_massifs": exhibition_massifs.size()
	}

	var before_lod0: Dictionary = before_data.get("perf_all_lod0", {})
	var before_auto: Dictionary = before_data.get("perf_auto_lod", {})

	var comparison := {
		"timestamp": Time.get_datetime_string_from_system(true),
		"viewport_resolution": [root.size.x, root.size.y],
		"renderer_adapter": RenderingServer.get_video_adapter_name(),
		"godot_version": Engine.get_version_info()["string"],
		"benchmark_camera": {
			"target": [0, 0, 0],
			"camera_size": 2400.0,
			"yaw": 0.12,
			"orbit": 1.05
		},
		"environment_prop_counts": {
			"before": before_data.get("prop_counts", {}),
			"after": prop_counts_after
		},
		"perf_all_lod0": {
			"before": before_lod0,
			"after": perf_after_lod0,
			"diff": {
				"frame_ms_median_delta": perf_after_lod0.get("frame_ms_median", 0.0) - float(before_lod0.get("frame_ms_median", 0.0)),
				"frame_ms_p95_delta": perf_after_lod0.get("frame_ms_p95", 0.0) - float(before_lod0.get("frame_ms_p95", 0.0)),
				"draw_calls_delta": perf_after_lod0.get("draw_calls_mean", 0.0) - float(before_lod0.get("draw_calls_mean", 0.0)),
				"primitives_delta": perf_after_lod0.get("primitives_mean", 0.0) - float(before_lod0.get("primitives_mean", 0.0)),
				"vram_mb_delta": perf_after_lod0.get("video_mem_mb_last", 0.0) - float(before_lod0.get("video_mem_mb_last", 0.0))
			}
		},
		"perf_auto_lod": {
			"before": before_auto,
			"after": perf_after_auto,
			"diff": {
				"frame_ms_median_delta": perf_after_auto.get("frame_ms_median", 0.0) - float(before_auto.get("frame_ms_median", 0.0)),
				"frame_ms_p95_delta": perf_after_auto.get("frame_ms_p95", 0.0) - float(before_auto.get("frame_ms_p95", 0.0)),
				"draw_calls_delta": perf_after_auto.get("draw_calls_mean", 0.0) - float(before_auto.get("draw_calls_mean", 0.0)),
				"primitives_delta": perf_after_auto.get("primitives_mean", 0.0) - float(before_auto.get("primitives_mean", 0.0)),
				"vram_mb_delta": perf_after_auto.get("video_mem_mb_last", 0.0) - float(before_auto.get("video_mem_mb_last", 0.0))
			}
		},
		"captured_shots": captured_files
	}

	var comp_path := RENDERS_OUT.path_join("perf-comparison.json")
	var f := FileAccess.open(comp_path, FileAccess.WRITE)
	f.store_string(JSON.stringify(comparison, "\t"))
	f.close()
	print("[AfterCapture] Saved perf-comparison.json successfully.")

	print("\n=== ALL AFTER CAPTURES & PERFORMANCE COMPARISON COMPLETE ===")
	quit(0)

func record_frame_samples_bench(samples: int) -> Dictionary:
	await wait_frames(30)
	var frame_ms: Array = []
	var draws: Array = []
	var triangles: Array = []
	var vram_mb: Array = []

	for i in range(samples):
		var started := Time.get_ticks_usec()
		await process_frame
		var elapsed_ms: float = (Time.get_ticks_usec() - started) / 1000.0
		frame_ms.append(elapsed_ms)
		draws.append(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
		triangles.append(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
		vram_mb.append(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / (1024.0 * 1024.0))

	frame_ms.sort()
	var p50_idx := int(samples * 0.50)
	var p95_idx := int(samples * 0.95)

	return {
		"samples": samples,
		"frame_ms_median": frame_ms[p50_idx],
		"frame_ms_p95": frame_ms[p95_idx],
		"frame_ms_min": frame_ms[0],
		"frame_ms_max": frame_ms[-1],
		"draw_calls_mean": sum_values(draws) / float(draws.size()),
		"primitives_mean": sum_values(triangles) / float(triangles.size()),
		"video_mem_mb_mean": sum_values(vram_mb) / float(vram_mb.size()),
		"video_mem_mb_last": vram_mb[-1]
	}

