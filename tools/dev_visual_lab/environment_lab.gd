extends SceneTree
## Full environment audit on an isolated DEV stage. No battlefield is loaded.
const Lib = preload("res://scripts/visual/map_composition_v0/map_composition_library.gd")
const Builder = preload("res://scripts/visual/map_composition_v0/map_composition_builder.gd")
var out := ""
var entries: Array = []
var index := 0
var capture := false
var viewport: SubViewport
var stage: Node3D
var holder: Node3D
var camera: Camera3D
var raster_root: Control
var preview_rect: TextureRect
var title: Label
var picker: OptionButton
var far_view := false
var records: Array = []
var info: Dictionary = {}
var keys: Dictionary = {}

func _initialize() -> void:
	out = OS.get_environment("SG_ENV_LAB_OUT")
	if out == "":
		push_error("Set SG_ENV_LAB_OUT to the directory containing catalogue.json")
		quit(2)
		return
	var f := FileAccess.open(out.path_join("catalogue.json"), FileAccess.READ)
	if f == null: quit(2); return
	entries = JSON.parse_string(f.get_as_text())["entries"]
	capture = "--capture" in OS.get_cmdline_user_args() or "--capture-raster" in OS.get_cmdline_user_args()
	root.title = "StrategyGame - DEV Environment Asset Lab"
	call_deferred("boot")

func boot() -> void:
	for pair in [["forest", Builder.FOREST_SPECS.size()], ["village", Builder.VILLAGE_SPECS.size()], ["farm", Builder.FARM_SPECS.size()], ["mountain", Builder.MOUNTAIN_SPECS.size()], ["city", Builder.CITY_SPECS.size()], ["plain", 4]]:
		for v in range(int(pair[1])):
			entries.append({"id": "composition_%s_%d" % [pair[0], v], "kind": "composition", "family": pair[0], "variant": v, "path": "Builder.build_%s(%d, 20261018)" % [pair[0], v], "role": "composition"})
	for key in Lib.WATER:
		entries.append({"id": "composition_water_" + key, "kind": "composition", "family": "river", "key": key, "variant": 0, "path": "Builder.build_river(" + key + ")", "role": "composition"})
	viewport = SubViewport.new()
	viewport.size = Vector2i(640, 480)
	viewport.own_world_3d = true
	viewport.msaa_3d = Viewport.MSAA_2X
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	stage = Node3D.new()
	viewport.add_child(stage)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color("b6b6a8")
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color("f0eadc")
	env.environment.ambient_light_energy = 0.7
	stage.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, -35, 0)
	sun.light_energy = 1.1
	sun.shadow_enabled = false
	stage.add_child(sun)
	camera = Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	stage.add_child(camera)
	camera.make_current()
	var floor_mesh := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(120, 120)
	floor_mesh.mesh = plane
	floor_mesh.position.y = -0.02
	var floor_material := StandardMaterial3D.new()
	floor_material.albedo_color = Color("777e69")
	floor_material.roughness = 1.0
	floor_mesh.material_override = floor_material
	stage.add_child(floor_mesh)
	raster_root = Control.new()
	raster_root.size = Vector2(640,480)
	viewport.add_child(raster_root)
	var ui := CanvasLayer.new()
	root.add_child(ui)
	var panel := VBoxContainer.new()
	panel.position = Vector2(20,20)
	panel.size = Vector2(1100, 900)
	ui.add_child(panel)
	title = Label.new()
	title.add_theme_font_size_override("font_size",22)
	panel.add_child(title)
	picker = OptionButton.new()
	for item in entries: picker.add_item(item["path"])
	picker.item_selected.connect(select_asset)
	panel.add_child(picker)
	var help := Label.new()
	help.text = "DEV ONLY | No maps | Left/Right: asset | F: far/near | Esc: exit\nNormalized to fit. Source dimensions are in the receipt. Shadows off. Vertex colors enabled as in the asset library."
	panel.add_child(help)
	var preview := TextureRect.new()
	preview_rect = preview
	preview.texture = viewport.get_texture()
	preview.custom_minimum_size = Vector2(960,720)
	preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	panel.add_child(preview)
	select_asset(0)
	if "--smoke" in OS.get_cmdline_user_args():
		await wait_frames(8)
		call_deferred("finish")
	elif capture: await capture_all()

func composition(item: Dictionary) -> Node3D:
	var pair: Dictionary
	var family: String = item["family"]
	if family == "river": pair = Builder.build_river(item["key"], 0.0)
	else:
		var v: int = item["variant"]
		match family:
			"forest": pair = Builder.build_forest(v, 20261018)
			"village": pair = Builder.build_village(v, 20261018)
			"farm": pair = Builder.build_farm(v, 20261018)
			"mountain": pair = Builder.build_mountain(v, 20261018)
			"city": pair = Builder.build_city(v, 20261018)
			"plain": pair = Builder.build_plain(v, 20261018)
	info["composition_stats"] = pair["stats"]
	var node := Node3D.new()
	var tile_key := "tile_scrub" if family == "forest" else "tile_rocky_ground" if family == "mountain" else "tile_packed_dirt" if family in ["city", "village"] else "tile_wet_lowland" if family == "river" else "tile_open_grassland"
	node.add_child(Builder.build_tile(tile_key))
	node.add_child(pair["root"])
	return node

func select_asset(which: int) -> void:
	if holder != null:
		stage.remove_child(holder)
		holder.free()
	for child in raster_root.get_children():
		raster_root.remove_child(child)
		child.free()
	index = posmod(which, entries.size())
	var item: Dictionary = entries[index]
	info = {"id": item["id"], "path": item["path"], "kind": item["kind"], "role": item["role"], "loaded": false}
	far_view = false
	holder = Node3D.new()
	stage.add_child(holder)
	raster_root.visible = item["kind"] == "raster"
	if item["kind"] == "raster":
		var image := Image.load_from_file(ProjectSettings.globalize_path("res://" + item["path"]))
		if image != null and not image.is_empty():
			info["image_size"] = [image.get_width(), image.get_height()]
			var background := ColorRect.new()
			background.color = Color("474d43")
			background.size = Vector2(640,480)
			raster_root.add_child(background)
			var tex := TextureRect.new()
			var used := image.get_used_rect()
			info["alpha_used_rect"] = [used.position.x, used.position.y, used.size.x, used.size.y]
			var atlas := AtlasTexture.new()
			atlas.atlas = ImageTexture.create_from_image(image)
			atlas.region = Rect2(used) if used.has_area() else Rect2(Vector2.ZERO, Vector2(image.get_size()))
			tex.texture = atlas
			tex.position = Vector2(16,16)
			tex.size = Vector2(608,448)
			tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			tex.size = Vector2(608,448)
			tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			raster_root.add_child(tex)
			info["loaded"] = true
	else:
		var model: Node3D
		if item["kind"] == "composition": model = composition(item)
		else:
			var resource: Resource = load("res://" + item["path"])
			if resource is PackedScene: model = resource.instantiate() as Node3D
			elif resource is Mesh:
				var mesh_node := MeshInstance3D.new()
				mesh_node.mesh = resource
				model = mesh_node
		if model != null:
			holder.add_child(model)
			info["raw_materials"] = material_info(model)
			Lib._prep_node(model)
			info["mesh_triangles_base"] = Lib._count_triangles(model)
			info["structure"] = structure_info(model)
			var bounds := {"min": Vector3(1e9,1e9,1e9), "max": Vector3(-1e9,-1e9,-1e9)}
			Lib._accumulate_aabb(model, Transform3D.IDENTITY, bounds)
			var size: Vector3 = bounds["max"] - bounds["min"]
			info["original_aabb_min"] = [bounds["min"].x,bounds["min"].y,bounds["min"].z]
			info["original_aabb_size"] = [size.x,size.y,size.z]
			var k := 9.0 / maxf(maxf(size.x,size.y),maxf(size.z,0.001))
			info["preview_scale"] = k
			var center: Vector3 = (bounds["max"] + bounds["min"]) * 0.5
			model.position -= Vector3(center.x, bounds["min"].y, center.z)
			holder.scale = Vector3.ONE * k
			info["loaded"] = true
	set_camera()
	camera.make_current()
	title.text = "%d / %d  %s" % [index + 1, entries.size(), item["path"]]
	picker.select(index)

func set_camera() -> void:
	camera.size = 34.0 if far_view else 14.0
	camera.position = Vector3(12,12,18)
	camera.look_at(Vector3(0,2.2,0))

func structure_info(node: Node) -> Dictionary:
	var result := {"mesh_nodes":0,"surfaces":0,"hidden_mesh_nodes":0,"multimesh_nodes":0}
	var pending: Array[Node] = [node]
	while not pending.is_empty():
		var n: Node = pending.pop_back()
		if n is MeshInstance3D:
			result.mesh_nodes += 1
			if n.mesh != null: result.surfaces += n.mesh.get_surface_count()
			if not n.is_visible_in_tree(): result.hidden_mesh_nodes += 1
		if n is MultiMeshInstance3D: result.multimesh_nodes += 1
		for child in n.get_children(): pending.append(child)
	return result

func material_info(node: Node) -> Array:
	var result: Array = []
	var seen: Dictionary = {}
	var pending: Array[Node] = [node]
	while not pending.is_empty():
		var n: Node = pending.pop_back()
		if n is MeshInstance3D and n.mesh != null:
			for s in range(n.mesh.get_surface_count()):
				var mat: Material = n.get_active_material(s)
				if mat == null or seen.has(mat.get_instance_id()): continue
				seen[mat.get_instance_id()] = true
				var row := {"class":mat.get_class(),"name":mat.resource_name}
				if mat is BaseMaterial3D:
					row["vertex_colors"] = mat.vertex_color_use_as_albedo
					row["shading_mode"] = mat.shading_mode
					row["transparency"] = mat.transparency
					row["roughness"] = mat.roughness
					row["metallic"] = mat.metallic
				result.append(row)
		for child in n.get_children(): pending.append(child)
	return result

func pressed(key: int) -> bool:
	var down := Input.is_key_pressed(key)
	var old: bool = keys.get(key,false)
	keys[key] = down
	return down and not old

func _process(_delta: float) -> bool:
	if viewport == null or capture: return false
	if pressed(KEY_ESCAPE): call_deferred("finish")
	if pressed(KEY_RIGHT): select_asset(index + 1)
	if pressed(KEY_LEFT): select_asset(index - 1)
	if pressed(KEY_F): far_view = not far_view; set_camera()
	return false

func wait_frames(count: int) -> void:
	for i in range(count): await process_frame

func snapshot(suffix: String) -> String:
	await RenderingServer.frame_post_draw
	var filename: String = entries[index]["id"] + "_" + suffix + ".png"
	var error := viewport.get_texture().get_image().save_png(out.path_join("previews").path_join(filename))
	if error != OK: push_error("Failed preview " + filename)
	return "previews/" + filename if error == OK else ""

func capture_all() -> void:
	DirAccess.make_dir_recursive_absolute(out.path_join("previews"))
	for which in range(entries.size()):
		if "--capture-raster" in OS.get_cmdline_user_args() and entries[which]["kind"] != "raster": continue
		if which != 0: select_asset(which)
		await wait_frames(4)
		if info["loaded"]:
			info["near"] = await snapshot("near")
			info["near_draw_calls"] = viewport.get_render_info(Viewport.RENDER_INFO_TYPE_VISIBLE, Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME)
			info["near_primitives"] = viewport.get_render_info(Viewport.RENDER_INFO_TYPE_VISIBLE, Viewport.RENDER_INFO_PRIMITIVES_IN_FRAME)
			if entries[index]["kind"] != "raster":
				far_view = true
				set_camera()
				await wait_frames(2)
				info["far"] = await snapshot("far")
		records.append(info.duplicate(true))
		if which % 20 == 0:
			save_receipt()
			print("[DevEnvironmentLab] ",which+1," / ",entries.size()," ",entries[index]["path"])
	save_receipt()
	print("[DevEnvironmentLab] COMPLETE ",records.size())
	call_deferred("finish")

func save_receipt() -> void:
	var f := FileAccess.open(out.path_join("raster-receipt.json" if "--capture-raster" in OS.get_cmdline_user_args() else "runtime-receipt.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify({"engine":Engine.get_version_info(),"gpu":RenderingServer.get_video_adapter_name(),"preview_resolution":[640,480],"shadow_policy":"off", "scale_policy":"fit largest bound to 9 units; camera sizes 14/34; not shared original world scale", "entries":records},"  "))
	f.close()

func finish() -> void:
	if preview_rect != null: preview_rect.texture = null
	if viewport != null:
		viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
		viewport.queue_free()
	await process_frame
	await process_frame
	quit()



