extends SceneTree
## Uniform LOD0 / scale renders from the finished, freshly reloaded GLBs.
const OUT := "C:/Users/User/Documents/Codex/2026-10-18/strategygame-godot-4-2-2-repo/outputs/mountain-range-25"
const KIT := "C:/Users/User/Documents/Codex/2026-10-18/strategygame-godot-4-2-2-repo/outputs/threejs-hex-terrain-kit"
func _initialize() -> void:
	root.size = Vector2i(1920,1080)
	call_deferred("run")
func run() -> void:
	var stage := Node3D.new()
	root.add_child(stage)
	var we := WorldEnvironment.new()
	we.environment = Environment.new()
	we.environment.background_mode = Environment.BG_COLOR
	we.environment.background_color = Color("263c43")
	we.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	we.environment.ambient_light_color = Color("dce4ce")
	we.environment.ambient_light_energy = 0.65
	stage.add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-48,-32,0)
	sun.light_color = Color("fff0ce")
	sun.light_energy = 1.05
	sun.shadow_enabled = false
	stage.add_child(sun)
	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 490
	camera.far = 2000
	stage.add_child(camera)
	camera.make_current()
	var catalog: Array = JSON.parse_string(FileAccess.get_file_as_string(KIT.path_join("range25/catalog.json")))["catalog"]
	var results: Array = []
	for entry in catalog:
		var document := GLTFDocument.new()
		var state := GLTFState.new()
		var path := OUT.path_join("exports/"+str(entry["id"])+".glb")
		assert(document.append_from_file(path,state)==OK)
		var model := document.generate_scene(state) as Node3D
		model.scale = Vector3.ONE*0.75
		stage.add_child(model)
		var lo: Array = entry["bounds"]["min"]
		var hi: Array = entry["bounds"]["max"]
		var focus := (Vector3(lo[0],lo[1],lo[2])+Vector3(hi[0],hi[1],hi[2]))*0.375
		var direction := Vector3(sin(0.12)*cos(0.78),sin(0.78),cos(0.12)*cos(0.78))
		camera.position = focus+direction*550
		camera.look_at(focus)
		for i in range(4): await process_frame
		await RenderingServer.frame_post_draw
		var error := root.get_texture().get_image().save_png(OUT.path_join("images/"+str(entry["id"])+"_comparison.png"))
		results.append({"id":entry["id"],"file_sha256":FileAccess.get_sha256(path),"screenshot_error":error})
		model.free()
	var f := FileAccess.open(OUT.path_join("contact-render-receipt.json"),FileAccess.WRITE)
	f.store_string(JSON.stringify({"engine":Engine.get_version_info(),"camera_size":490,"lod":0,"footprint_scale":0.75,"viewport":[1920,1080],"same_lighting_as_hex_map":true,"entries":results},"\t"))
	f.close()
	print("[Range25Contact] rendered ",results.size()," finished GLBs at common scale / LOD0")
	quit()
