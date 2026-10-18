extends Node3D

## Visual-only adapter of the LIVE production terrain to the existing asset kit.
## No fallback map, copied region coordinates, physics, or gameplay writes.
const Builder = preload("res://scripts/visual/map_composition_v0/map_composition_builder.gd")
const Lib = preload("res://scripts/visual/map_composition_v0/map_composition_library.gd")
const ForestPilot = preload("res://scripts/visual/map_composition_v0/forest_runtime_pilot.gd")
const GroundBatch = preload("res://scripts/visual/full_map_ground_batch.gd")
const MountainRangeBatch = preload("res://scripts/visual/full_map_mountain_range_batch.gd")
const AgricultureBatch = preload("res://scripts/visual/full_map_agriculture_batch.gd")
const Hex = preload("res://scripts/core/hex_utils.gd")
const HexBaseMesh = preload("res://scripts/visual/hex_native/hex_base_terrain_mesh.gd")
const SEED := 20261003
# One flat, batched hex layer fills the source GLBs' beveled seams. Keeping the
# source meshes at unit scale makes their visible hexes match the live grid.
const TUTORIAL_GROUND_BACKFILL_Y := -0.08
const TUTORIAL_GROUND_BACKFILL_COLOR := Color(0.46, 0.47, 0.35)
const TUTORIAL_HEX_EDGE_Y := 0.015
const TUTORIAL_HEX_EDGE_WIDTH := 0.55
const TUTORIAL_HEX_EDGE_COLOR := Color(0.16, 0.15, 0.12, 0.34)
var built := false
var report: Dictionary = {}
var records: Array = []
var _tree_pilot: RefCounted
var _ground_batch: RefCounted
var _mountain_range_batch: RefCounted
var _agriculture_batch: RefCounted

static func layout_snapshot(shell: Node) -> String:
	var cells: Dictionary = shell.get("hex_grid").get("cell_data")
	var keys: Array = cells.keys()
	keys.sort()
	var rows: Array = []
	for k in keys:
		var c: Variant = cells[k]
		rows.append([k, int(c.q), int(c.r), int(c.terrain)])
	return JSON.stringify([rows, shell.get("_river_cells"), shell.get("_stronghold_cells"), shell.call("stronghold_visual_specs")])

static func neighbors(q: int, r: int, terrain: int, cells: Dictionary) -> int:
	var n := 0
	for d in Hex.DIRECTIONS:
		var key := "%d,%d" % [q + d.x, r + d.y]
		if cells.has(key) and int(cells[key].terrain) == terrain:
			n += 1
	return n

## Distribute existing plain-ground GLBs without identical adjacent tutorial
## tiles. Cell keys are sorted in setup(), making this greedy choice stable.
static func _tutorial_plain_tile(q: int, r: int, assigned: Dictionary, seed_value: int) -> String:
	var choices: Array[String] = ["tile_open_grassland", "tile_dry_earth", "tile_scrub"]
	var start: int = posmod(absi((q * 73856093) ^ (r * 19349663) ^ seed_value), choices.size())
	for offset in range(choices.size()):
		var candidate: String = choices[(start + offset) % choices.size()]
		var blocked := false
		for direction: Vector2i in Hex.DIRECTIONS:
			var neighbor_key := "%d,%d" % [q + direction.x, r + direction.y]
			if str(assigned.get(neighbor_key, "")) == candidate:
				blocked = true
				break
		if not blocked:
			assigned["%d,%d" % [q, r]] = candidate
			return candidate
	var fallback: String = choices[start]
	assigned["%d,%d" % [q, r]] = fallback
	return fallback

## options (CIV3D view): ground=false skips the flat tile layer, lit=true keeps
## shadows and adds no sun, height_fn(q, r) -> 3D units seats each family,
## forest_variant_cap = 1 never uses the sparse forest composition.
func setup(shell: Node, presentation_scale: float, options: Dictionary = {}) -> void:
	var civ_ground: bool = bool(options.get("ground", true))
	var civ_lit: bool = bool(options.get("lit", false))
	var height_fn: Callable = options.get("height_fn", Callable())
	name = "FullDevMapTransplant"
	scale = Vector3.ONE * presentation_scale
	var before := layout_snapshot(shell)
	var cells: Dictionary = shell.get("hex_grid").get("cell_data")
	var tutorial_map: bool = bool((shell.get("_battlefield") as Dictionary).get("tutorial", false))
	assert(not cells.is_empty(), "Transplant requires live authoritative cells")
	var anchors: Dictionary = {}
	for spec in shell.call("stronghold_visual_specs"):
		anchors["%d,%d" % [spec["anchor"].x, spec["anchor"].y]] = spec["role"]
	var counts: Dictionary = {}
	var terrain_counts: Dictionary = {}
	var assets: Dictionary = {}
	var tutorial_plain_tiles: Dictionary = {}
	var tutorial_ground_cells: Array[Dictionary] = []
	_tree_pilot = ForestPilot.new()
	_ground_batch = GroundBatch.new()
	_mountain_range_batch = MountainRangeBatch.new()
	_agriculture_batch = AgricultureBatch.new()
	var ground := Node3D.new()
	ground.name = "GroundAllPlayableHexes"
	add_child(ground)
	var features := Node3D.new()
	features.name = "ApprovedFamilies"
	add_child(features)
	var keys: Array = cells.keys()
	keys.sort()
	for key in keys:
		var cell: Variant = cells[key]
		var q: int = cell.q
		var r: int = cell.r
		var t: int = cell.terrain
		var seed_value: int = SEED + q * 1013 + r * 337
		var p: Vector2 = Hex.hex_to_pixel(q, r)
		var family := "Open Ground"
		var tile_key := "tile_open_grassland"
		var variant := -1
		var pair: Dictionary = {}
		var mountain_neighbors := neighbors(q, r, 1, cells)
		var forest_neighbors := neighbors(q, r, 2, cells)
		var near_settlement := neighbors(q, r, 5, cells) > 0 or neighbors(q, r, 11, cells) > 0
		match t:
			1:
				tile_key = "tile_rocky_ground"
				family = "Mountain Range" if mountain_neighbors >= 4 else "Mountains"
				# Reuse authored connected ridge/peak/massif compositions A-D.
				variant = 1 + posmod(q + 2 * r, 3) if mountain_neighbors >= 4 else 0
				pair = Builder.build_mountain(variant, seed_value)
			2:
				tile_key = "tile_scrub"
				family = "Forest"
				variant = 0 if forest_neighbors >= 5 else (1 if forest_neighbors >= 3 else 2)
				variant = mini(variant, int(options.get("forest_variant_cap", 2)))
				if tutorial_map:
					variant = 2  # tutorial boards: the sparse grove everywhere (192 forest hexes on M1 cost ~16 fps dense)
				pair = Builder.build_forest(variant, seed_value)
			3, 7:
				# Preserve existing wet terrain as ground; no extra landmark family.
				tile_key = "tile_wet_lowland"
			5:
				tile_key = "tile_packed_dirt"
				family = "Village"
				variant = posmod(q + r, 3)
				pair = Builder.build_village(variant, seed_value)
			6:
				tile_key = "tile_worn_crossing" if tutorial_map and neighbors(q, r, 6, cells) >= 3 else "tile_packed_dirt"
			9:
				tile_key = "tile_rocky_ground"
				family = "Fortress / Fortification"
				variant = 0 if anchors.has(key) else 1
				pair = Builder.build_city(variant, seed_value)
			11:
				tile_key = "tile_packed_dirt"
				family = "Capital"
				variant = 2 if anchors.has(key) else 0
				pair = Builder.build_city(variant, seed_value)
			0:
				# Tutorial maps: settlements stay on their own V hexes only (no farmstead compositions with
				# granaries/houses spilling onto the plain hexes around a village).
				if near_settlement and tutorial_map:
					tile_key = "tile_cultivated_edge"
				elif near_settlement:
					family = "Agricultural District"
					tile_key = "tile_cultivated_edge"
					variant = posmod(q + r, 2)
					pair = Builder.build_farm(variant, seed_value)
				elif tutorial_map:
					tile_key = _tutorial_plain_tile(q, r, tutorial_plain_tiles, seed_value)
		if civ_ground:
			_ground_batch.call("add_tile", tile_key, Vector3(p.x, -0.10, p.y))
		if tutorial_map:
			tutorial_ground_cells.append({"coord": Vector2i(q, r), "center": p, "tile": tile_key})
		if not pair.is_empty():
			var comp: Node3D = pair["root"]
			comp.name = "%s_%s" % [family.replace(" / ", "_").replace(" ", "_"), String(key).replace(",", "_")]
			comp.position = Vector3(p.x, float(height_fn.call(q, r)) / presentation_scale if height_fn.is_valid() else 0.0, p.y)
			features.add_child(comp)
			# Batch only the repeated dry/rice field assets inside Agriculture roots.
			# The helper leaves yard discs and every other family untouched.
			_agriculture_batch.call("add_hex", comp)
			# Batch only non-tree meshes from connected Mountain Range hexes. The
			# range helper leaves yard/ring meshes and tree wrappers untouched.
			_mountain_range_batch.call("add_hex", comp)
			# Preserve exact source tree transforms at LOD0 while batching the
			# static trees per hex; distant views use the authored runtime LODs.
			_tree_pilot.call("convert_hex", comp)
			for asset in pair["stats"]["placed"]:
				assets[asset] = int(assets.get(asset, 0)) + int(pair["stats"]["placed"][asset])
		counts[family] = int(counts.get(family, 0)) + 1
		terrain_counts[str(t)] = int(terrain_counts.get(str(t), 0)) + 1
		records.append({"hex": key, "terrain": t, "family": family, "variant": variant, "seed": seed_value, "tile": tile_key})
		if records.size() % 500 == 0:
			print("[StrictTransplant] %d/%d cells" % [records.size(), cells.size()])
	var mountain_range_batch_stats: Dictionary = _mountain_range_batch.call("finish", features, tutorial_map)
	var agriculture_batch_stats: Dictionary = _agriculture_batch.call("finish", features, tutorial_map)
	var ground_batch_stats: Dictionary = _ground_batch.call("finish", ground)
	if tutorial_map:
		var zmin := INF
		var zmax := -INF
		for item in tutorial_ground_cells:
			zmin = minf(zmin, (item["center"] as Vector2).y)
			zmax = maxf(zmax, (item["center"] as Vector2).y)
		_board_depth = maxf(1.0, (zmax - zmin) * presentation_scale)
		_build_tutorial_ground_backfill(ground, tutorial_ground_cells)
		_build_tutorial_hex_edges(ground, tutorial_ground_cells)
	if not civ_lit:
		var sun := DirectionalLight3D.new()
		sun.name = "ShadowlessSun"
		sun.rotation_degrees = Vector3(-55, -35, 0)
		sun.light_energy = 1.1
		sun.shadow_enabled = false
		add_child(sun)
		disable_shadows(self)
	var after := layout_snapshot(shell)
	var ground_hexes := int(ground_batch_stats.get("ground_tiles", 0))
	var ground_tile_counts: Dictionary = {}
	for record in records:
		var ground_tile: String = str(record.get("tile", ""))
		ground_tile_counts[ground_tile] = int(ground_tile_counts.get(ground_tile, 0)) + 1
	report = {"tutorial_map": tutorial_map, "playable_hexes": cells.size(), "ground_hexes": ground_hexes, "remaining_old_ground_hexes": cells.size() - ground_hexes, "ground_fill_scale": Vector3.ONE, "tutorial_ground_backfill_hexes": tutorial_ground_cells.size(), "ground_tile_counts": ground_tile_counts, "ground_batch_optimization": ground_batch_stats, "ground_runtime_lod": _ground_batch.call("get_lod_stats"), "mountain_range_batch_optimization": mountain_range_batch_stats, "agriculture_batch_optimization": agriculture_batch_stats, "family_hex_counts": counts, "terrain_counts": terrain_counts, "asset_instances": assets, "tree_runtime_optimization": _tree_pilot.get("stats"), "layout_sha256_before": before.sha256_text(), "layout_sha256_after": after.sha256_text(), "layout_unchanged": before == after, "placement_sha256": JSON.stringify(records).sha256_text(), "seed": SEED, "shadows_on": shadow_count(self)}
	assert(before == after, "Visual adapter mutated map authority")
	built = true
	print("[StrictTransplant] " + JSON.stringify(report))

func _build_tutorial_ground_backfill(parent: Node3D, cells: Array[Dictionary]) -> void:
	if cells.is_empty():
		return
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for item in cells:
		var center: Vector2 = item["center"]
		var center_vertex := Vector3(center.x, TUTORIAL_GROUND_BACKFILL_Y, center.y)
		for i in range(6):
			var p0 := _tutorial_hex_vertex(center, (i + 1) % 6)
			var p1 := _tutorial_hex_vertex(center, i)
			for point in [center_vertex, p0, p1]:
				st.set_normal(Vector3.UP)
				st.set_color(TUTORIAL_GROUND_BACKFILL_COLOR)
				st.add_vertex(point)
	var backfill := MeshInstance3D.new()
	backfill.name = "TutorialHexGapBackfill"
	backfill.mesh = st.commit()
	backfill.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.vertex_color_use_as_albedo = true
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.roughness = 1.0
	backfill.material_override = material
	parent.add_child(backfill)

static func _tutorial_hex_vertex(center: Vector2, vertex_index: int) -> Vector3:
	var offset: Vector2 = HexBaseMesh.CANONICAL_VERTICES[vertex_index]
	return Vector3(center.x + offset.x, TUTORIAL_GROUND_BACKFILL_Y, center.y + offset.y)

func _build_tutorial_hex_edges(parent: Node3D, cells: Array[Dictionary]) -> void:
	if cells.is_empty():
		return
	var cell_coords: Dictionary = {}
	for item in cells:
		cell_coords[item["coord"]] = true
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var half_width: float = TUTORIAL_HEX_EDGE_WIDTH * 0.5
	for item in cells:
		var coord: Vector2i = item["coord"]
		var center: Vector2 = item["center"]
		for dir_index in range(6):
			var neighbor: Vector2i = coord + HexBaseMesh.DIRECTIONS[dir_index]
			if cell_coords.has(neighbor) and (coord.x > neighbor.x or (coord.x == neighbor.x and coord.y > neighbor.y)):
				continue # shared edges are drawn once, with matching endpoints
			var edge_vertices: Vector2i = HexBaseMesh.DIR_EDGE_VERTICES[dir_index]
			var a: Vector2 = center + HexBaseMesh.CANONICAL_VERTICES[edge_vertices.x]
			var b: Vector2 = center + HexBaseMesh.CANONICAL_VERTICES[edge_vertices.y]
			var tangent: Vector2 = (b - a).normalized()
			var extension: Vector2 = tangent * half_width
			var side: Vector2 = Vector2(-tangent.y, tangent.x) * half_width
			var p0: Vector2 = a - extension + side
			var p1: Vector2 = b + extension + side
			var p2: Vector2 = a - extension - side
			var p3: Vector2 = b + extension - side
			for point in [p0, p1, p2, p1, p3, p2]:
				st.set_normal(Vector3.UP)
				st.add_vertex(Vector3(point.x, TUTORIAL_HEX_EDGE_Y, point.y))
	var edge_mesh := MeshInstance3D.new()
	edge_mesh.name = "TutorialSharedHexEdges"
	edge_mesh.mesh = st.commit()
	edge_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var material := StandardMaterial3D.new()
	material.albedo_color = TUTORIAL_HEX_EDGE_COLOR
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.roughness = 1.0
	edge_mesh.material_override = material
	parent.add_child(edge_mesh)

## Tutorial boards are framed with a far smaller orthographic size than the radius-40 map the forest LOD
## thresholds were tuned for, so they always picked LOD0 (~47M triangles on M1, ~22 fps). At the tutorial
## framing the far LOD reads the same on screen; the trees get a proxy camera at that size.
const TUTORIAL_TREE_LOD_SIZE := 200.0
const TUTORIAL_GRASS_VIEW_FRAC := 0.45
var _board_depth := 1.0e9  # extent of the board's hex centres along z (3D units), set in setup
var _tree_lod_proxy: Camera3D = null

func update_lod_for_camera(camera: Camera3D) -> void:
	if _tree_pilot != null:
		var tree_cam: Camera3D = camera
		if camera != null and bool(report.get("tutorial_map", false)):
			if _tree_lod_proxy == null:
				_tree_lod_proxy = Camera3D.new()
				_tree_lod_proxy.projection = Camera3D.PROJECTION_ORTHOGONAL
			_tree_lod_proxy.size = maxf(camera.size, TUTORIAL_TREE_LOD_SIZE)
			tree_cam = _tree_lod_proxy
		_tree_pilot.call("update_for_camera", tree_cam)
	if _ground_batch != null:
		# Tutorial boards (diameter 40, 1261 hexes): the far grass LOD at every zoom, like the trees.
		_ground_batch.call("update_for_camera", _tree_lod_proxy if bool(report.get("tutorial_map", false)) and _tree_lod_proxy != null else camera)
		if bool(report.get("tutorial_map", false)) and camera != null:
			# Whole board in view (camera taller than ~45% of the board): bare tiles, no grass tufts.
			_ground_batch.call("set_grass_visible", camera.size <= TUTORIAL_GRASS_VIEW_FRAC * _board_depth)
		if not report.is_empty():
			report["ground_runtime_lod"] = _ground_batch.call("get_lod_stats")
	if _mountain_range_batch != null:
		_mountain_range_batch.call("update_for_camera", camera)
		if not report.is_empty():
			report["mountain_range_runtime_lod"] = _mountain_range_batch.call("get_stats")
	if _agriculture_batch != null:
		_agriculture_batch.call("update_for_camera", camera)
		if not report.is_empty():
			report["agriculture_runtime_lod"] = _agriculture_batch.call("get_stats")

static func disable_shadows(node: Node) -> void:
	if node is GeometryInstance3D:
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if node is Light3D:
		node.shadow_enabled = false
	for child in node.get_children():
		disable_shadows(child)

static func shadow_count(node: Node) -> int:
	var count := 0
	if node is GeometryInstance3D and node.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
		count += 1
	if node is Light3D and node.shadow_enabled:
		count += 1
	for child in node.get_children():
		count += shadow_count(child)
	return count

func _exit_tree() -> void:
	if _tree_lod_proxy != null:
		_tree_lod_proxy.free()
		_tree_lod_proxy = null
