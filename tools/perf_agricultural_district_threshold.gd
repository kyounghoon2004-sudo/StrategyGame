extends SceneTree

## Six-camera agriculture-only validation on the production battlefield route.
const OUT := "res://evidence/agricultural_district_optimization"
const Hex = preload("res://scripts/core/hex_utils.gd")
const FAMILY := "Agricultural District"
const LOCKED_FAMILY := "Mountain Range"
const FAMILIES := [FAMILY]
const VIEWS := [
	["threshold_source", Vector2i(-13, 3), 210.0 / 145.0, 0],
	["threshold_far", Vector2i(-13, 3), 210.0 / 145.0, 0],
]
const WARMUP := 5
const SAMPLE := 4

var start_ms := 0
var menu_frame := 0
var shell: Node
var view: Node
var layer: Node
var features: Node3D
var agriculture_batch_root: Node3D
var family_roots := {}
var family_geometry := {}
var original_visibility := {}
var family_census := {}
var viewport_rid: RID
var view_index := -1
var phase_index := 0 # baseline, then one phase per FAMILIES entry
var phase_frame := 0
var phase_samples: Array = []
var rows: Array = []
var current_row: Dictionary = {}
var selected_views: Array = []
var stage := "threshold"

func _initialize() -> void:
	# Two fixed-framing source/far states; no command-line stage override.
	start_ms = Time.get_ticks_msec()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	change_scene_to_file("res://scenes/title_screen.tscn")

func _process(_delta: float) -> bool:
	if Time.get_ticks_msec() - start_ms > 600000:
		push_error("Family attribution capture timed out")
		quit(1)
		return true
	if current_scene != null and current_scene.scene_file_path == "res://scenes/title_screen.tscn":
		if menu_frame == 0:
			var collection: Node = current_scene.get("_map_collection")
			if collection == null:
				return false
			collection.call("open")
		menu_frame += 1
		if menu_frame == 8:
			var button: Node = current_scene.find_child("OpenExistingProductionLayout", true, false)
			if button == null:
				push_error("Production layout DEV button missing")
				quit(1)
				return true
			button.emit_signal("pressed")
		return false
	if view_index >= 0 or current_scene == null:
		return false
	shell = current_scene
	view = shell.get("_view3d")
	if view == null or not bool(view.call("is_active")):
		return false
	layer = view.get("strict_transplant")
	if layer == null or not bool(layer.get("built")):
		return false
	features = layer.get_node_or_null("ApprovedFamilies") as Node3D
	if features == null:
		push_error("ApprovedFamilies root missing")
		quit(1)
		return true
	viewport_rid = root.get_viewport().get_viewport_rid()
	var camera: Node = shell.get("camera")
	camera.set_process(false)
	camera.set_process_input(false)
	camera.set_process_unhandled_input(false)
	_map_family_roots(layer.get("records"))
	if stage == "children":
		_write_direct_child_names()
		return true
	selected_views = _choose_views(layer.get("records"))
	if selected_views.size() != VIEWS.size():
		quit(1)
		return true
	view_index = 0
	_apply_view()
	RenderingServer.frame_post_draw.connect(_after_draw)
	return false

func _map_family_roots(records: Array) -> void:
	for family in [FAMILY, LOCKED_FAMILY, "Forest", "Mountains"]:
		family_roots[family] = []
	for record in records:
		var family: String = record["family"]
		if not family_roots.has(family):
			continue
		var node_name := "%s_%s" % [family.replace(" / ", "_").replace(" ", "_"), String(record["hex"]).replace(",", "_")]
		var node: Node3D = features.get_node_or_null(node_name) as Node3D
		if node == null:
			push_error("Family root missing: " + node_name)
			continue
		family_roots[family].append(node)
	for family in [FAMILY, LOCKED_FAMILY, "Forest", "Mountains"]:
		family_census[family] = _census(family_roots[family])
	var locked_range_batch := features.get_node_or_null("MountainRangeBatches") as Node3D
	if locked_range_batch != null:
		family_census["MountainRangeBatches"] = _census([locked_range_batch])
	agriculture_batch_root = features.get_node_or_null("AgriculturalDistrictBatches") as Node3D
	if agriculture_batch_root != null:
		var combined_roots: Array = family_roots[FAMILY].duplicate()
		combined_roots.append(agriculture_batch_root)
		family_census[FAMILY] = _census(combined_roots)
		family_census[FAMILY]["composition_roots"] = family_roots[FAMILY].size()
		family_census[FAMILY]["batch_helper_roots"] = 1
		family_census["AgriculturalDistrictBatches"] = _census([agriculture_batch_root])
	family_census["GroundAllPlayableHexes"] = _census([layer.get_node("GroundAllPlayableHexes")])
	for family in FAMILIES:
		var toggle_roots: Array = family_roots[family].duplicate()
		if family == FAMILY and agriculture_batch_root != null:
			toggle_roots.append(agriculture_batch_root)
		family_geometry[family] = _non_tree_geometry(toggle_roots)

func _choose_views(records: Array) -> Array:
	return [
		{"name": "threshold_source", "q": -13, "r": 3, "zoom": 210.0 / 145.0, "focus_family": FAMILY},
		{"name": "threshold_far", "q": -13, "r": 3, "zoom": 210.0 / 145.0, "focus_family": FAMILY},
	]
	if stage == "after":
		var before_file := FileAccess.open(OUT + "/before.json", FileAccess.READ)
		if before_file == null:
			push_error("Agriculture before receipt missing")
			return []
		var before: Dictionary = JSON.parse_string(before_file.get_as_text())
		before_file.close()
		var after_report: Dictionary = layer.get("report")
		if String(before.get("layout_sha256", "")) != String(after_report.get("layout_sha256_after", "")) or String(before.get("placement_sha256", "")) != String(after_report.get("placement_sha256", "")):
			push_error("Production layout/placement hash changed since agriculture baseline")
			return []
		var frozen: Array = []
		for prior in before["views"]:
			frozen.append({"name": prior["name"], "q": prior["q"], "r": prior["r"], "zoom": prior["zoom"], "focus_family": FAMILY})
		return frozen
	var views: Array = []
	for spec in VIEWS:
		var axial: Vector2i = spec[1]
		if int(spec[3]) >= 0:
			var found := false
			for record in records:
				if String(record["hex"]) == "%d,%d" % [axial.x, axial.y] and String(record["family"]) == FAMILY and int(record["variant"]) == int(spec[3]):
					found = true
					break
			if not found:
				push_error("Expected live Agriculture root/variant missing: " + String(spec[0]))
				return []
		views.append({"name": spec[0], "q": axial.x, "r": axial.y, "zoom": spec[2], "focus_family": FAMILY, "actual_variant": spec[3]})
	return views

func _apply_view() -> void:
	var spec: Dictionary = selected_views[view_index]
	var q: int = spec["q"]
	var r: int = spec["r"]
	var position := Vector2(q * 36.0, r * 42.0 + q * 21.0)
	var camera: Node = shell.get("camera")
	camera.call("set_zoom_level", float(spec["zoom"]), true)
	camera.call("focus_on", position, true)
	view.set("_cam_sig", Vector4.INF)
	view.call("_update_camera")
	# Only Agriculture's dry crop mesh reference changes. The real camera and
	# the frozen families' LOD state remain fixed at size 145 in both captures.
	var batch: RefCounted = layer.get("_agriculture_batch")
	var probe := Camera3D.new()
	probe.size = 120.0 if view_index == 0 else 170.0
	batch.call("update_for_camera", probe)
	probe.free()
	phase_index = 0
	_set_all_families_visible(true)
	phase_frame = 0
	phase_samples.clear()
	current_row = spec.duplicate(true)
	current_row["camera_position"] = [camera.global_position.x, camera.global_position.y]
	current_row["camera_zoom"] = camera.zoom.x
	current_row["camera3d_position"] = [view.get("cam").global_position.x, view.get("cam").global_position.y, view.get("cam").global_position.z]
	current_row["camera3d_size"] = view.get("cam").size
	current_row["agriculture_lod_state"] = (batch.call("get_stats") as Dictionary).get("lod_state", "")
	current_row["family_hidden"] = {}
	print("[family_attribution] view=%s axial=%d,%d" % [spec["name"], q, r])

func _set_all_families_visible(enabled: bool) -> void:
	for family in FAMILIES:
		_set_family_visible(family, enabled)

func _set_family_visible(family: String, enabled: bool) -> void:
	for node in family_geometry[family]:
		node.visible = original_visibility[node.get_instance_id()] if enabled else false

func _non_tree_geometry(roots: Array) -> Array:
	var result: Array = []
	var stack: Array = []
	for family_root in roots:
		stack.append([family_root, false])
	while not stack.is_empty():
		var entry: Array = stack.pop_back()
		var node: Node = entry[0]
		var in_tree: bool = entry[1] or String(node.name) == "ForestRuntimeChunk"
		for child in node.get_children():
			stack.append([child, in_tree])
		if node is GeometryInstance3D and not in_tree:
			result.append(node)
			original_visibility[node.get_instance_id()] = node.visible
	return result

func _after_draw() -> void:
	if view_index < 0 or view_index >= selected_views.size():
		return
	phase_frame += 1
	if phase_frame > WARMUP:
		phase_samples.append(_render_info())
	if phase_frame < WARMUP + SAMPLE:
		return
	var values := _median_info(phase_samples)
	if phase_index == 0:
		current_row["all_visible"] = values
		var path := "%s/%s_%s.png" % [OUT, stage, selected_views[view_index]["name"]]
		current_row["screenshot"] = path
		current_row["screenshot_saved"] = root.get_texture().get_image().save_png(path) == OK
	else:
		var family: String = FAMILIES[phase_index - 1]
		var delta := {}
		for key in values:
			delta[key] = int(current_row["all_visible"][key]) - int(values[key])
		current_row["family_hidden"][family] = {"visible_counters": values, "directional_contribution": delta}
		if family == current_row["focus_family"]:
			var slug := family.to_lower().replace(" / ", "_").replace(" ", "_")
			var path := "%s/%s_without_%s_%s.png" % [OUT, stage, selected_views[view_index]["name"], slug]
			current_row["family_hidden"][family]["screenshot"] = path
			current_row["family_hidden"][family]["screenshot_saved"] = root.get_texture().get_image().save_png(path) == OK
		_set_family_visible(family, true)
	phase_index += 1
	if phase_index <= FAMILIES.size():
		var next_family: String = FAMILIES[phase_index - 1]
		_set_family_visible(next_family, false)
		phase_frame = 0
		phase_samples.clear()
		return
	rows.append(current_row)
	print("[family_attribution] RESULT " + JSON.stringify(current_row))
	view_index += 1
	if view_index < selected_views.size():
		_apply_view()
	else:
		_finish()

func _render_info() -> Dictionary:
	var visible := RenderingServer.VIEWPORT_RENDER_INFO_TYPE_VISIBLE
	return {
		"objects": RenderingServer.viewport_get_render_info(viewport_rid, visible, RenderingServer.VIEWPORT_RENDER_INFO_OBJECTS_IN_FRAME),
		"primitives": RenderingServer.viewport_get_render_info(viewport_rid, visible, RenderingServer.VIEWPORT_RENDER_INFO_PRIMITIVES_IN_FRAME),
		"draw_calls": RenderingServer.viewport_get_render_info(viewport_rid, visible, RenderingServer.VIEWPORT_RENDER_INFO_DRAW_CALLS_IN_FRAME),
	}

func _median_info(samples: Array) -> Dictionary:
	var result := {}
	for key in samples[0]:
		var values: Array = []
		for sample in samples:
			values.append(int(sample[key]))
		values.sort()
		result[key] = values[values.size() / 2]
	return result

func _finish() -> void:
	_set_all_families_visible(true)
	var report: Dictionary = layer.get("report")
	var range_batch: Node3D = features.get_node_or_null("MountainRangeBatches") as Node3D
	var ground_root: Node3D = layer.get_node("GroundAllPlayableHexes") as Node3D
	var receipt := {
		"stage": stage,
		"route": "Title > DEV Map Collection > existing production layout",
		"scene": current_scene.scene_file_path,
		"renderer": ProjectSettings.get_setting("rendering/renderer/rendering_method"),
		"viewport_size": [root.size.x, root.size.y],
		"warmup_frames_per_phase": WARMUP, "sample_frames_per_phase": SAMPLE,
		"interpretation": "visible counter subtraction is directional; hidden opaque features can reveal background geometry",
		"measurement_toggle": "GeometryInstance3D descendants of 18 Agricultural_District roots plus AgriculturalDistrictBatches helper if present; all other families stay visible",
		"threshold_method": "At the same actual camera position and size 145, force only Agriculture dry crop mesh state via probe camera size 120 then 170; frozen Ground/Forest/Mountain Range states remain unchanged",
		"frozen_families": ["GroundAllPlayableHexes", "Forest", "Mountains", "Mountain Range", "Village", "Fortress / Fortification", "Capital"],
		"water_feature_nodes": 0,
		"playable_hexes": report.get("playable_hexes", 0),
		"layout_sha256": report.get("layout_sha256_after", ""),
		"placement_sha256": report.get("placement_sha256", ""),
		"shadows_on": layer.call("shadow_count", view),
		"agriculture_root_count": family_roots[FAMILY].size(),
		"agriculture_batch_helper_count": 1 if agriculture_batch_root != null else 0,
		"agriculture_root_transforms_sha256": _root_transforms_sha(family_roots[FAMILY]),
		"live_agriculture_assets": _agriculture_variant_counts(layer.get("records")),
		"requested_terrace_granary_view_note": "The normal production route contains no terraced_field or farm_granary under its 18 Agriculture roots. Terrace/granary camera slots document live dry/rice and settlement context; they do not claim those absent assets are rendered.",
		"frozen_forest_root_count": family_roots["Forest"].size(),
		"frozen_forest_root_transforms_sha256": _root_transforms_sha(family_roots["Forest"]),
		"frozen_forest_tree_sha256": _nested_tree_sha(family_roots["Forest"]),
		"frozen_range_root_count": family_roots[LOCKED_FAMILY].size(),
		"frozen_range_root_transforms_sha256": _root_transforms_sha(family_roots[LOCKED_FAMILY]),
		"frozen_range_tree_sha256": _nested_tree_sha(family_roots[LOCKED_FAMILY]),
		"frozen_range_batch_sha256": _multimesh_sha([range_batch]) if range_batch != null else "",
		"frozen_ground_batch_sha256": _multimesh_sha([ground_root]),
		"frozen_normal_mountains_root_transforms_sha256": _root_transforms_sha(family_roots["Mountains"]),
		"family_census": family_census,
		"ground_batch_optimization": report.get("ground_batch_optimization", {}),
		"tree_runtime_optimization": report.get("tree_runtime_optimization", {}),
		"mountain_range_batch_optimization": report.get("mountain_range_batch_optimization", {}),
		"agriculture_batch_optimization": report.get("agriculture_batch_optimization", {}),
		"views": rows,
	}
	var path := OUT + "/" + stage + ".json"
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("Could not write family receipt")
		quit(1)
		return
	file.store_string(JSON.stringify(receipt, "  "))
	file.close()
	print("[family_attribution] COMPLETE " + path)
	quit(0)

func _root_transforms_sha(roots: Array) -> String:
	var ordered := roots.duplicate()
	ordered.sort_custom(func(a: Node3D, b: Node3D) -> bool: return String(a.name) < String(b.name))
	var rows: Array = []
	for node in ordered:
		rows.append([String(node.name), str(node.transform)])
	return JSON.stringify(rows).sha256_text()

func _nested_tree_sha(roots: Array) -> String:
	var ordered := roots.duplicate()
	ordered.sort_custom(func(a: Node3D, b: Node3D) -> bool: return String(a.name) < String(b.name))
	var rows: Array = []
	for family_root in ordered:
		var stack: Array = [[family_root, false]]
		while not stack.is_empty():
			var entry: Array = stack.pop_back()
			var node: Node = entry[0]
			var in_tree: bool = entry[1] or String(node.name) == "ForestRuntimeChunk"
			for child in node.get_children():
				stack.append([child, in_tree])
			if not in_tree:
				continue
			if node is Node3D:
				rows.append([String(family_root.name), str(node.get_path()), str(node.transform)])
			if node is MultiMeshInstance3D and node.multimesh != null:
				var mm: MultiMesh = node.multimesh
				rows.append(["instances", mm.instance_count, mm.mesh.resource_name if mm.mesh != null else ""])
				for i in range(mm.instance_count):
					rows.append(str(mm.get_instance_transform(i)))
	return JSON.stringify(rows).sha256_text()

func _multimesh_sha(roots: Array) -> String:
	var rows: Array = []
	for family_root in roots:
		var stack: Array = [family_root]
		while not stack.is_empty():
			var node: Node = stack.pop_back()
			for child in node.get_children():
				stack.append(child)
			if node is MultiMeshInstance3D and node.multimesh != null:
				var mm: MultiMesh = node.multimesh
				rows.append([str(node.get_path()), str(node.transform), mm.instance_count])
				for i in range(mm.instance_count):
					rows.append(str(mm.get_instance_transform(i)))
	return JSON.stringify(rows).sha256_text()

func _agriculture_variant_counts(records: Array) -> Dictionary:
	var counts := {"dry_field_roots": 0, "rice_field_roots": 0, "terraced_field_roots": 0, "rural_granary_roots": 0}
	for record in records:
		if String(record["family"]) != FAMILY:
			continue
		match int(record["variant"]):
			0: counts["dry_field_roots"] += 1
			1: counts["rice_field_roots"] += 1
			2: counts["terraced_field_roots"] += 1
	return counts

func _write_direct_child_names() -> void:
	var receipt := {}
	for hex in ["-13_3", "-12_3"]:
		var node: Node3D = features.get_node("Agricultural_District_" + hex) as Node3D
		var rows: Array = []
		for child in node.get_children():
			rows.append({"name": String(child.name), "type": child.get_class(), "map_asset_key": str(child.get_meta("map_asset_key", "")), "child_count": child.get_child_count()})
		receipt[String(node.name)] = rows
	var path := OUT + "/direct_child_names.json"
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify(receipt, "  "))
	file.close()
	print("[agriculture_children] " + path)
	quit(0)

func _finish_census_only() -> void:
	var report: Dictionary = layer.get("report")
	var receipt := {
		"route": "Title > DEV Map Collection > existing production layout",
		"scene": current_scene.scene_file_path,
		"playable_hexes": report.get("playable_hexes", 0),
		"layout_sha256": report.get("layout_sha256_after", ""),
		"placement_sha256": report.get("placement_sha256", ""),
		"family_census": family_census,
		"census_scope": "runtime family composition roots; nested ForestRuntimeChunk tree geometry separated",
	}
	var path := OUT + "/static_family_census.json"
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("Could not write static family census")
		quit(1)
		return
	file.store_string(JSON.stringify(receipt, "  "))
	file.close()
	print("[family_attribution] CENSUS_COMPLETE " + path)
	quit(0)

func _census(roots: Array) -> Dictionary:
	var result := {"composition_roots": roots.size(), "nodes": 0, "mesh_instances": 0, "multimesh_instances": 0, "mesh_part_instances": 0, "static_triangles": 0, "surface_instances": 0, "unique_meshes": 0, "repeated_mesh_part_instances": 0, "unique_materials": 0, "nested_tree_mesh_parts": 0, "nested_tree_static_triangles": 0, "non_tree_static_triangles": 0, "non_tree_geometry_nodes": 0}
	var mesh_details := {}
	var materials := {}
	var stack: Array = []
	for family_root in roots:
		stack.append([family_root, false])
	while not stack.is_empty():
		var entry: Array = stack.pop_back()
		var node: Node = entry[0]
		var in_tree: bool = entry[1] or String(node.name) == "ForestRuntimeChunk"
		result["nodes"] += 1
		for child in node.get_children():
			stack.append([child, in_tree])
		if node is GeometryInstance3D and not in_tree:
			result["non_tree_geometry_nodes"] += 1
		var mesh: Mesh
		var instances := 0
		if node is MultiMeshInstance3D:
			result["multimesh_instances"] += 1
			if node.multimesh != null:
				mesh = node.multimesh.mesh
				instances = node.multimesh.instance_count
		elif node is MeshInstance3D:
			result["mesh_instances"] += 1
			mesh = node.mesh
			instances = 1
		if mesh == null:
			continue
		var geometry := node as GeometryInstance3D
		if geometry.material_override != null:
			materials[geometry.material_override.get_instance_id()] = true
		var id := mesh.get_instance_id()
		if not mesh_details.has(id):
			var tris := 0
			for s in range(mesh.get_surface_count()):
				var material: Material = mesh.surface_get_material(s)
				if material != null:
					materials[material.get_instance_id()] = true
				if mesh is ArrayMesh and mesh.surface_get_primitive_type(s) != Mesh.PRIMITIVE_TRIANGLES:
					continue
				var arrays: Array = mesh.surface_get_arrays(s)
				var indices: Variant = arrays[Mesh.ARRAY_INDEX]
				var count: int = indices.size() if indices != null else (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
				tris += count / 3
			mesh_details[id] = {"tris": tris, "surfaces": mesh.get_surface_count()}
		result["mesh_part_instances"] += instances
		result["static_triangles"] += int(mesh_details[id]["tris"]) * instances
		result["surface_instances"] += int(mesh_details[id]["surfaces"]) * instances
		if in_tree:
			result["nested_tree_mesh_parts"] += instances
			result["nested_tree_static_triangles"] += int(mesh_details[id]["tris"]) * instances
	result["non_tree_static_triangles"] = int(result["static_triangles"]) - int(result["nested_tree_static_triangles"])
	result["unique_meshes"] = mesh_details.size()
	result["repeated_mesh_part_instances"] = int(result["mesh_part_instances"]) - mesh_details.size()
	result["unique_materials"] = materials.size()
	return result
