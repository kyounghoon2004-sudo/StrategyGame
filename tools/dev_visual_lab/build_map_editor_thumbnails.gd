extends SceneTree
## Render thumbnails from the same local GLBs used by the map editor.
const Paths = preload("res://tools/dev_visual_lab/visual_output_paths.gd")
const Lib = preload("res://scripts/visual/map_composition_v0/map_composition_library.gd")
const BUILDINGS := ["building_small_house","building_medium_house","building_workshop","building_granary","building_hall","building_gate","building_farm_granary"]
var preview: SubViewport
var world: Node3D
var models: Node3D
var camera: Camera3D
var floor_node: MeshInstance3D
var output_dir: String

func _initialize() -> void:
	output_dir = Paths.output("map-editor-thumbnails")
	DirAccess.make_dir_recursive_absolute(output_dir)
	call_deferred("run")

func load_model(path: String) -> Node3D:
	var doc := GLTFDocument.new(); var state := GLTFState.new()
	if doc.append_from_file(path,state) != OK: push_error("THUMBNAIL_MISSING " + path); return null
	return doc.generate_scene(state) as Node3D

func get_bounds(node: Node, parent_xf: Transform3D, result: Dictionary) -> void:
	var xf := parent_xf
	if node is Node3D: xf = parent_xf * node.transform
	if node is MeshInstance3D and node.mesh != null:
		var box: AABB = node.mesh.get_aabb()
		for i in range(8):
			var p := xf * box.get_endpoint(i)
			result.min = Vector3(minf(result.min.x,p.x),minf(result.min.y,p.y),minf(result.min.z,p.z))
			result.max = Vector3(maxf(result.max.x,p.x),maxf(result.max.y,p.y),maxf(result.max.z,p.z))
	for child in node.get_children(): get_bounds(child,xf,result)

func forest(variant: String) -> Node3D:
	var group := Node3D.new()
	var offsets := [Vector2(-10,-3),Vector2(-5,-8),Vector2(2,-9),Vector2(9,-5),Vector2(-9,4),Vector2(-3,0),Vector2(4,-2),Vector2(10,3),Vector2(-5,8),Vector2(2,7),Vector2(6,5)]
	for i in range(offsets.size()):
		var key := "tall_pine" if variant == "pine" or i%2 == 0 else "broadleaf"
		var model := load_model(Paths.output("full-map-lab/optimized/" + key + "_mid.glb"))
		if model == null: group.free(); return null
		var bounds: Dictionary = Lib.bounds(key); var extent: Vector3 = bounds.max-bounds.min
		var scale_factor := 8.0/maxf(extent.x,extent.z)
		model.scale = Vector3.ONE*scale_factor
		model.position = Vector3(offsets[i].x,-float(bounds.min.y)*scale_factor,offsets[i].y)
		model.rotation.y = float(posmod(i*5,12))*PI/6.0
		group.add_child(model)
	return group

func run() -> void:
	preview = SubViewport.new(); preview.size = Vector2i(256,192)
	preview.transparent_bg = false; preview.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	preview.own_world_3d = true; root.add_child(preview)
	world = Node3D.new(); preview.add_child(world)
	var environment := WorldEnvironment.new(); environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR; environment.environment.background_color = Color("253a39")
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR; environment.environment.ambient_light_color = Color("dce4ce"); environment.environment.ambient_light_energy = 0.8; world.add_child(environment)
	var light := DirectionalLight3D.new(); light.rotation_degrees = Vector3(-48,-32,0); light.light_color = Color("fff0ce"); light.light_energy = 1.05; world.add_child(light)
	camera = Camera3D.new(); camera.projection = Camera3D.PROJECTION_ORTHOGONAL; camera.far = 5000; world.add_child(camera); camera.make_current()
	models = Node3D.new(); world.add_child(models)
	floor_node = MeshInstance3D.new(); var plane := PlaneMesh.new(); plane.size = Vector2(1,1); floor_node.mesh = plane
	var ground := StandardMaterial3D.new(); ground.albedo_color = Color("85965b"); ground.roughness = 1.0; floor_node.material_override = ground; world.add_child(floor_node)
	var catalog_path := Paths.output("scenery-scale-massif/massif25/catalog.json")
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(catalog_path))
	if not data is Dictionary or not data.get("catalog") is Array: push_error("No catalog"); quit(2); return
	var items: Array = []
	for v in ["mixed","pine"]: items.append({"kind":"forest","variant":v})
	for v in data.catalog: items.append({"kind":"mountain","variant":str(v.id)})
	for i in range(1,5): items.append({"kind":"castle","variant":"castle_v%d" % i})
	for v in BUILDINGS: items.append({"kind":"building","variant":v})
	var written := 0
	for item in items:
		var kind: String = item.kind; var variant: String = item.variant
		var model: Node3D
		match kind:
			"forest": model = forest(variant)
			"mountain": model = load_model(Paths.output("scenery-scale-massif/massif25/exports/"+variant+"_lod0.glb")); if model != null: model.scale = Vector3.ONE*0.75
			"castle": model = load_model(Paths.output("scenery-scale-massif/castle4/exports/"+variant+"_lod0.glb"))
			"building": model = load_model(Paths.output("scenery-scale-massif/buildings/exports/"+variant+"_lod0.glb"))
		if model == null: continue
		models.add_child(model)
		for m in model.find_children("*","MeshInstance3D",true,false): m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var box := {"min":Vector3(1e9,1e9,1e9),"max":Vector3(-1e9,-1e9,-1e9)}
		get_bounds(model,Transform3D.IDENTITY,box)
		var size: Vector3 = box.max-box.min
		var middle: Vector3 = (box.min+box.max)*0.5
		var span := maxf(size.x,maxf(size.y,size.z))
		if span <= 0.0 or span > 100000: model.free(); continue
		var plane_size := maxf(size.x,size.z)*1.35
		(floor_node.mesh as PlaneMesh).size = Vector2(plane_size,plane_size)
		floor_node.position = Vector3(middle.x,box.min.y-0.2,middle.z)
		camera.size = maxf(size.x*1.12, maxf(size.z*1.12,size.y*1.7))
		camera.position = middle + Vector3(1.0,1.25,1.35).normalized()*span*2.5
		camera.look_at(middle)
		for i in range(3): await process_frame
		await RenderingServer.frame_post_draw
		var file := output_dir.path_join(kind+"__"+variant+".png")
		if preview.get_texture().get_image().save_png(file) == OK: written += 1
		model.free()
	print("THUMBNAILS_WRITTEN ",written,"/",items.size()," ",output_dir)
	quit(0 if written == items.size() else 2)
