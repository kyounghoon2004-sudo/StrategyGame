extends SceneTree
## Presentation-only full landscape. Owns a DEV document, never a battlefield.
const Lib = preload("res://scripts/visual/map_composition_v0/map_composition_library.gd")
const Foot = preload("res://scripts/visual/civ3d/civ_formation3d.gd")
const Mount = preload("res://scripts/visual/civ3d/civ_cavalry3d.gd")
const VERSION := 1
var out := ""
var seed_value := 20261018
var density := 0.68
var meander := 23.0
var document: Array = []
var history: Array = []
var terrain_noise := FastNoiseLite.new()
var moisture := FastNoiseLite.new()
var stage: Node3D
var land: Node3D
var props: Node3D
var actors: Node3D
var camera: Camera3D
var target := Vector3(0, 0, 0)
var yaw := 0.12
var orbit := 0.94
var optimized := true
var active_lod := "far"
var templates := {}
var material: StandardMaterial3D
var ui: Control
var status: Label
var info: Label
var density_input: HSlider
var river_input: HSlider
var seed_input: SpinBox
var mode_input: OptionButton
var current_meshes := []
var selected := -1
var dragging := false
var rotating := false
var last_mouse := Vector2.ZERO
var ring: MeshInstance3D
var units_enabled := true
var frame_samples: Array = []
var capture_mode := false
var build_ms := 0.0
var counts := {}
var tick := 0.0
var stats := {}
var cover_keys := {}

func _initialize() -> void:
	out = OS.get_environment("SG_FULL_MAP_OUT")
	if out == "":
		push_error("Set SG_FULL_MAP_OUT to the full-map-lab output folder")
		quit(2)
		return
	root.title = "StrategyGame | DEV Landscape Workshop"
	root.size = Vector2i(1920,1080)
	root.min_size = Vector2i(1100,700)
	capture_mode = "--capture" in OS.get_cmdline_user_args()
	optimized = not "--raw" in OS.get_cmdline_user_args()
	call_deferred("boot")

func boot() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	root.msaa_3d = Viewport.MSAA_2X
	stage = Node3D.new()
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
	material = StandardMaterial3D.new()
	material.vertex_color_use_as_albedo = true
	material.roughness = 1.0
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	camera = Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 285
	camera.far = 2000
	stage.add_child(camera)
	camera.make_current()
	land = Node3D.new()
	stage.add_child(land)
	props = Node3D.new()
	stage.add_child(props)
	actors = Node3D.new()
	stage.add_child(actors)
	var ringmesh := CylinderMesh.new()
	ringmesh.top_radius = 5
	ringmesh.bottom_radius = 5
	ringmesh.height = 0.12
	ringmesh.radial_segments = 32
	ring = MeshInstance3D.new()
	ring.mesh = ringmesh
	var gold := StandardMaterial3D.new()
	gold.albedo_color = Color("e8c46e")
	ring.material_override = gold
	ring.visible = false
	stage.add_child(ring)
	make_ui()
	generate()
	make_actors()
	update_camera()
	if capture_mode: await capture_suite()

func make_ui() -> void:
	var layer := CanvasLayer.new()
	root.add_child(layer)
	ui = PanelContainer.new()
	ui.position = Vector2(22,22)
	ui.custom_minimum_size = Vector2(335,0)
	var box := StyleBoxFlat.new()
	box.bg_color = Color(0.055,0.085,0.09,0.93)
	box.border_color = Color("9a936a")
	box.set_border_width_all(1)
	box.set_content_margin_all(16)
	ui.add_theme_stylebox_override("panel",box)
	layer.add_child(ui)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation",10)
	ui.add_child(column)
	var label := Label.new()
	label.text = "LANDSCAPE WORKSHOP\nDEV  /  RIVER VALLEY"
	label.add_theme_font_size_override("font_size",21)
	column.add_child(label)
	var help := Label.new()
	help.text = "Wheel: zoom   RMB: orbit\nWASD: pan   Home: full map\nLMB: select / drag   R: rotate\nDelete: remove   Ctrl+Z: undo"
	column.add_child(help)
	seed_input = SpinBox.new()
	seed_input.min_value = 1
	seed_input.max_value = 2147483647
	seed_input.value = seed_value
	column.add_child(seed_input)
	for pair in [["FOREST COVER",density],["RIVER MEANDER",meander / 50.0]]:
		var caption := Label.new()
		caption.text = pair[0]
		column.add_child(caption)
		var slider := HSlider.new()
		slider.min_value = 0.1
		slider.max_value = 1.0
		slider.step = 0.02
		slider.value = pair[1]
		column.add_child(slider)
		if density_input == null: density_input = slider
		else: river_input = slider
	var regenerate := Button.new()
	regenerate.text = "GENERATE / REPLACE LAYOUT"
	regenerate.pressed.connect(func():
		history.append(document.duplicate(true))
		seed_value = int(seed_input.value)
		density = density_input.value
		meander = river_input.value * 50.0
		generate())
	column.add_child(regenerate)
	mode_input = OptionButton.new()
	mode_input.add_item("Optimized: chunked instances + LOD")
	mode_input.add_item("Original assets: same placements")
	mode_input.select(0 if optimized else 1)
	mode_input.item_selected.connect(func(i): optimized = i == 0; rebuild_props())
	column.add_child(mode_input)
	for text in ["SAVE DOCUMENT", "LOAD DOCUMENT", "SCREENSHOT"]:
		var b := Button.new()
		b.text = text
		column.add_child(b)
		if text == "SAVE DOCUMENT": b.pressed.connect(save_document)
		elif text == "LOAD DOCUMENT": b.pressed.connect(load_document)
		else: b.pressed.connect(func(): save_picture("manual"))
	info = Label.new()
	info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	info.custom_minimum_size.x = 300
	column.add_child(info)
	status = Label.new()
	status.add_theme_color_override("font_color",Color("d8c99c"))
	column.add_child(status)

func river_x(z: float) -> float:
	return 24.0 + sin(z * 0.022 + seed_value % 7 * 0.13) * meander + sin(z * 0.054) * 4.0

func river_width(z: float) -> float:
	return 10.0 + 11.0 * exp(-pow((z - 100.0) / 30.0,2))

func height_at(x: float, z: float) -> float:
	var noise: float = terrain_noise.get_noise_2d(x,z)
	var dist: float = absf(x - river_x(z))
	var bank: float = smoothstep(river_width(z)*0.5,river_width(z)*0.5+15.0,dist)
	return lerpf(-0.6,1.1 + noise * 3.5 + 3.0*exp(-pow((z+95)/32.0,2)),bank)

func place(key: String, x: float, z: float, width: float, angle: float = 0.0, role: String = "") -> void:
	document.append({"id":document.size(),"key":key,"p":[x,height_at(x,z),z],"width":width,"yaw":angle,"role":role})

func road_z(x: float) -> float:
	return 30.0 + sin(x * 0.016)*13.0

func generate() -> void:
	var start := Time.get_ticks_msec()
	terrain_noise.seed = seed_value
	terrain_noise.frequency = 0.015
	moisture.seed = seed_value + 974
	moisture.frequency = 0.022
	document.clear()
	selected = -1
	ring.visible = false
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	# A connected ridge, rather than isolated mountain tokens.
	var mountains: Array = Lib.MOUNTAINS.keys()
	for i in range(16):
		var x: float = -165.0 + i*22.0
		var z: float = -106.0 + sin(i*0.53)*11.0
		if absf(x-river_x(z))<27: continue
		place(mountains[i%mountains.size()],x,z,rng.randf_range(34,47),rng.randf_range(-0.15,0.15),"ridge")
	# Village blocks share street frontage, scale and material family.
	var homes := ["small_house","medium_house","small_house","workshop","granary"]
	for row in range(4):
		for col in range(7):
			var x: float = -122.0+col*12.0
			var z: float = 9.0+row*14.0
			if row == 2: z += 8
			place(homes[(row*3+col)%homes.size()],x,z,8.5+rng.randf()*1.0,PI if row<2 else 0.0,"village")
	place("hall",-86,46,15,0,"village_center")
	place("gate",-75,road_z(-75),12,PI*0.5,"village_gate")
	# Farms occupy the settled lowland, with clear access aisles.
	for row in range(3):
		for col in range(4):
			var key: String = "dry_field" if (row+col)%3 else "rice_field"
			place(key,-140+col*24,84+row*16,21,0,"farm")
	place("farm_granary",-45,92,11,0,"farm")
	place("irrigation",-34,110,21,0,"irrigation")
	place("terraced_field",-122,-42,28,0,"terraces")
	place("terraced_field",-88,-42,28,0,"terraces")
	# Fortress gate faces the east branch road; towers repeat a single module.
	place("stronghold",116,-38,36,0,"fortress")
	place("gatehouse",113,-7,17,0,"fortress_gate")
	place("hill_fort",-132,-72,26,0.2,"outpost")
	for x in [88.0,140.0]:
		for z in [-62.0,-10.0]: place("watchtower",x,z,8,0,"fortress_corner")
	for x in [96.0,112.0,128.0]:
		place("stone_wall",x,-68,16,0,"fortress_wall")
	for x in [82.0,146.0]:
		for z in [-52.0,-36.0,-20.0]: place("palisade",x,z,16,PI*0.5,"fortress_wall")
	# Stratified jitter grid: moisture/altitude, clearance and two biome palettes.
	var used_trees := {}
	for iz in range(31):
		for ix in range(42):
			var x: float = -170.0+ix*8.2+rng.randf_range(-2.5,2.5)
			var z: float = -118.0+iz*8.1+rng.randf_range(-2.5,2.5)
			if z < -78 or z>130: continue
			if absf(x-river_x(z)) < river_width(z)*0.5+7: continue
			if absf(z-road_z(x))<8 or (absf(x-112)<10 and z>-18 and z<50): continue
			if x>-153 and x<-30 and z>-56: continue
			if x>72 and x<156 and z>-78 and z<7: continue
			var wet: float = moisture.get_noise_2d(x,z)
			if wet < (0.35-density*0.72) or rng.randf()>0.83: continue
			var choices := ["broadleaf","sapling","cypress"] if z>30 else ["tall_pine","conifer","compact_pine","wind_pine"]
			var key: String = choices[rng.randi()%choices.size()]
			if wet < -0.1 and rng.randf()<0.1: key = "dead_tree"
			place(key,x,z,rng.randf_range(6.0,10.0),rng.randf_range(0,TAU),"forest")
			used_trees[key] = true
	# Every compatible tree family has a deliberate edge habitat.
	for key in Lib.TREES:
		if not used_trees.has(key): place(key,-161+used_trees.size()*10,-62,8,0,"forest_edge"); used_trees[key] = true
	build_terrain()
	rebuild_props()
	build_ms = Time.get_ticks_msec()-start
	info.text = "Seed %d | %d placed props\nDrag edits are saved in a DEV document.\nGeneration replaces edits; Save first.\nNo battlefield / balance data." % [seed_value,document.size()]

func terrain_color(x: float,z: float) -> Color:
	var dist: float = absf(x-river_x(z))
	var wet: float = moisture.get_noise_2d(x,z)
	var c := Color("899565").lerp(Color("687e53"),clampf(wet+0.4,0,1))
	if z < -75: c = c.lerp(Color("a39b7b"),0.6)
	if x>-155 and x<-28 and z>70: c = Color("a59a68")
	if x>-144 and x<-30 and z>-2 and z<78: c = c.lerp(Color("b4a17a"),0.8)
	if dist<river_width(z)*0.5+5: c = Color("b3a57c")
	if absf(z-road_z(x))<3.8 or (absf(x-112)<3.5 and z>-10 and z<road_z(x)):
		c = Color("c4ae7f")
	return c

func build_terrain() -> void:
	for n in land.get_children(): n.free()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for iz in range(70):
		for ix in range(90):
			var x: float = -180.0+ix*4
			var z: float = -140.0+iz*4
			var points := [Vector2(x,z),Vector2(x,z+4),Vector2(x+4,z),Vector2(x+4,z),Vector2(x,z+4),Vector2(x+4,z+4)]
			for p in points:
				st.set_color(terrain_color(p.x,p.y))
				st.add_vertex(Vector3(p.x,height_at(p.x,p.y),p.y))
	st.generate_normals()
	var mesh := MeshInstance3D.new()
	mesh.mesh = st.commit()
	mesh.material_override = material
	land.add_child(mesh)
	# A single connected water surface, with matching banks in terrain colors.
	var water := SurfaceTool.new()
	water.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(140):
		var z: float = -140+i*2
		var a := Vector3(river_x(z)-river_width(z)*0.5,0.0,z)
		var b := Vector3(river_x(z)+river_width(z)*0.5,0.0,z)
		var c := Vector3(river_x(z+2)-river_width(z+2)*0.5,0.0,z+2)
		var d := Vector3(river_x(z+2)+river_width(z+2)*0.5,0.0,z+2)
		for p in [a,c,b,b,c,d]:
			water.set_color(Color("719b9c").lightened(0.035*sin(z*0.12)))
			water.set_normal(Vector3.UP)
			water.add_vertex(p)
	var w := MeshInstance3D.new()
	w.mesh = water.commit()
	w.material_override = material
	land.add_child(w)
	# Map base silhouette, no repeated high-poly tile slabs.
	var base := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(360,7,280)
	base.mesh = bm
	base.position.y = -4.6
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color("605c47")
	base.material_override = mat
	land.add_child(base)
	# Crossing is built from existing water/bridge scenes; duplicated river plates omitted.
	for pair in [["wooden_bridge",road_z(river_x(40))],["stone_bridge",-62.0],["shallow_ford",92.0]]:
		var wrap := Node3D.new()
		var key: String = pair[0]
		var raw := Lib.instance_grounded(key)
		var b: Dictionary = Lib.bounds(key)
		var width: float = maxf(float(b["half_xz"].x)*2,float(b["half_xz"].y)*2)
		wrap.scale = Vector3.ONE * (24.0/maxf(width,0.01))
		wrap.add_child(raw)
		wrap.position = Vector3(river_x(pair[1]),0.1,pair[1])
		land.add_child(wrap)

func template_for(key: String,lod: String) -> Mesh:
	var cache_key := key+":"+lod
	if templates.has(cache_key): return templates[cache_key]
	var d := GLTFDocument.new()
	var state := GLTFState.new()
	var path := out.path_join("optimized").path_join(key+"_"+lod+".glb")
	var err := d.append_from_file(path,state)
	if err != OK: push_error("Derivative failed: "+path); return null
	var loaded: Node3D = d.generate_scene(state)
	var stack: Array = [loaded]
	var mesh: Mesh
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is MeshInstance3D: mesh = node.mesh; break
		stack.append_array(node.get_children())
	loaded.free()
	templates[cache_key] = mesh
	return mesh

func placement_transform(item: Dictionary, bb: AABB) -> Transform3D:
	var width: float = maxf(bb.size.x,bb.size.z)
	var scale_factor: float = float(item["width"])/maxf(width,0.001)
	var basis := Basis(Vector3.UP,float(item["yaw"])).scaled(Vector3.ONE*scale_factor)
	var offset := Vector3(bb.get_center().x,bb.position.y,bb.get_center().z)
	var p: Array = item["p"]
	return Transform3D(basis,Vector3(p[0],p[1],p[2])-basis*offset)

func rebuild_props() -> void:
	for n in props.get_children(): n.free()
	counts.clear()
	cover_keys.clear()
	var groups := {}
	for item in document:
		var key: String = item["key"]
		cover_keys[key] = true
		counts[key] = int(counts.get(key,0))+1
		if optimized:
			var p: Array = item["p"]
			var cell := Vector2i(floori(float(p[0])/64),floori(float(p[2])/64))
			var group := "%s:%d:%d" % [key,cell.x,cell.y]
			if not groups.has(group): groups[group] = {"key":key,"items":[],"center":Vector3(cell.x*64+32,0,cell.y*64+32)}
			groups[group]["items"].append(item)
		else:
			var node := Lib.scene_for(key).instantiate() as Node3D
			var b: Dictionary = Lib.bounds(key)
			var bb := AABB(b["min"],b["max"]-b["min"])
			node.transform = placement_transform(item,bb)
			props.add_child(node)
	current_meshes.clear()
	if optimized:
		for group in groups.values():
			var key: String = group["key"]
			var lods := {}
			for lod in ["near","mid","far"]:
				var mesh := template_for(key,lod)
				if mesh == null: continue
				var mm := MultiMesh.new()
				mm.transform_format = MultiMesh.TRANSFORM_3D
				mm.mesh = mesh
				mm.instance_count = group["items"].size()
				# Every LOD uses the SAME source bounds: simplified extrema cannot change scale/pivot.
				var b: Dictionary = Lib.bounds(key)
				var bb := AABB(b["min"],b["max"]-b["min"])
				for i in range(mm.instance_count): mm.set_instance_transform(i,placement_transform(group["items"][i],bb))
				var instance := MultiMeshInstance3D.new()
				instance.multimesh = mm
				instance.material_override = material
				instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				props.add_child(instance)
				lods[lod] = instance
			current_meshes.append({"center":group["center"],"lods":lods})
	update_lod()

func update_lod() -> void:
	active_lod = "far" if camera.size>170 else ("mid" if camera.size>65 else "near")
	for group in current_meshes:
		var distance: float = target.distance_to(group["center"])
		var wanted: String = active_lod if distance<camera.size*1.1 else "far"
		for lod in group["lods"]: group["lods"][lod].visible = lod == wanted
	for node in actors.get_children(): node.process_mode = Node.PROCESS_MODE_INHERIT if camera.size<80 else Node.PROCESS_MODE_DISABLED

func make_actors() -> void:
	for i in range(7):
		var node: Node3D = Foot.new() if i<5 else Mount.new()
		actors.add_child(node)
		var key: String = ["infantry","spearman","archer","conscript","scout","cavalry","hq"][i]
		var count: int = 3 if i<6 else 1
		node.call("setup",key,"blue",count,2.4,Vector3(0,0,1),seed_value+i)
		var points: Array = []
		for j in range(count): points.append(Vector3((j-1)*2.1,0,0))
		node.call("place",points)
		var x: float = -29.0+i*11
		var z: float = 50+sin(i)*4
		node.position = Vector3(x,height_at(x,z),z)

func update_camera() -> void:
	var direction := Vector3(sin(yaw)*cos(orbit),sin(orbit),cos(yaw)*cos(orbit))
	camera.position = target+direction*550
	camera.look_at(target)
	update_lod()

func map_point(pos: Vector2) -> Vector3:
	var origin := camera.project_ray_origin(pos)
	var dir := camera.project_ray_normal(pos)
	var t: float = -origin.y/dir.y
	var p: Vector3 = origin+dir*t
	for i in range(4):
		t = (height_at(p.x,p.z)-origin.y)/dir.y
		p = origin+dir*t
	return p

func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.pressed and ui.get_global_rect().has_point(event.position): return
		if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed: camera.size = maxf(24,camera.size*0.86); update_camera()
		if event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed: camera.size = minf(450,camera.size/0.86); update_camera()
		if event.button_index == MOUSE_BUTTON_RIGHT: rotating = event.pressed
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				var p := map_point(event.position)
				selected = -1
				var closest := 16.0
				for i in range(document.size()):
					var a: Array = document[i]["p"]
					var dist: float = Vector2(a[0]-p.x,a[2]-p.z).length()
					if dist<minf(closest,float(document[i]["width"])*0.65): closest = dist; selected = i
				if selected>=0:
					history.append(document.duplicate(true))
					dragging = true
					ring.visible = true
					ring.position = p+Vector3.UP*0.3
					info.text = "Selected: "+String(document[selected]["key"])+"\nDrag to move; R rotate; Delete remove."
			elif dragging:
				dragging = false
				rebuild_props()
	if event is InputEventMouseMotion:
		if rotating: yaw -= event.relative.x*0.006; orbit = clampf(orbit+event.relative.y*0.004,0.35,1.42); update_camera()
		if dragging and selected>=0:
			var p := map_point(event.position)
			document[selected]["p"] = [p.x,p.y,p.z]
			ring.position = p+Vector3.UP*0.3
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_HOME: target = Vector3.ZERO; camera.size = 285; update_camera()
		if event.keycode == KEY_R and selected>=0: history.append(document.duplicate(true)); document[selected]["yaw"] += PI/6; rebuild_props()
		if event.keycode == KEY_DELETE and selected>=0: history.append(document.duplicate(true)); document.remove_at(selected); selected = -1; ring.visible = false; rebuild_props()
		if event.keycode == KEY_Z and event.ctrl_pressed and not history.is_empty(): document = history.pop_back(); selected = -1; ring.visible = false; rebuild_props()

func _process(delta: float) -> bool:
	if camera == null: return false
	var movement := Vector3.ZERO
	if Input.is_key_pressed(KEY_W): movement.z -= 1
	if Input.is_key_pressed(KEY_S): movement.z += 1
	if Input.is_key_pressed(KEY_A): movement.x -= 1
	if Input.is_key_pressed(KEY_D): movement.x += 1
	if movement != Vector3.ZERO: target += movement.rotated(Vector3.UP,yaw)*delta*camera.size*0.6; update_camera()
	tick += delta
	if tick>0.4:
		tick = 0
		status.text = "%s  /  %s\n%.1f ms | %d draws | %.2f M tris" % ["OPTIMIZED" if optimized else "ORIGINAL",active_lod,delta*1000,int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)/1000000]
	return false

func save_document() -> void:
	var f := FileAccess.open(out.path_join("edited-map.json"),FileAccess.WRITE)
	f.store_string(JSON.stringify({"schema_version":VERSION,"generator":"river_valley_dev_v1","seed":seed_value,"density":density,"meander":meander,"placements":document},"\t"))
	info.text = "Saved: edited-map.json\nSeed + parameters + exact edited transforms."

func load_document() -> void:
	var path := out.path_join("edited-map.json")
	if not FileAccess.file_exists(path): info.text = "No saved document yet."; return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not parsed is Dictionary or parsed.get("schema_version",0)!=VERSION: info.text = "Unsupported map document."; return
	history.append(document.duplicate(true))
	seed_value = int(parsed["seed"])
	density = float(parsed["density"])
	meander = float(parsed["meander"])
	document = parsed["placements"]
	seed_input.value = seed_value
	density_input.value = density
	river_input.value = meander/50
	terrain_noise.seed = seed_value
	moisture.seed = seed_value+974
	build_terrain()
	rebuild_props()
	info.text = "Loaded edited-map.json"

func wait_frames(n: int) -> void:
	for i in range(n): await process_frame

func save_picture(name: String) -> void:
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(out.path_join(name+".png"))

func measure(name: String) -> Dictionary:
	await wait_frames(40)
	var frame_ms: Array = []
	var draws: Array = []
	var triangles: Array = []
	for i in range(120):
		var start := Time.get_ticks_usec()
		await process_frame
		frame_ms.append((Time.get_ticks_usec()-start)/1000.0)
		draws.append(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
		triangles.append(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
	frame_ms.sort()
	var result := {"mode":name,"samples":frame_ms.size(),"frame_ms_median":frame_ms[60],"frame_ms_p95":frame_ms[114],"draw_calls_mean":sum_values(draws)/draws.size(),"triangles_mean":sum_values(triangles)/triangles.size(),"camera_size":camera.size,"viewport":[root.size.x,root.size.y],"renderer":ProjectSettings.get_setting("rendering/renderer/rendering_method", "unknown"),"adapter":RenderingServer.get_video_adapter_name(),"vsync":false,"shadows":false,"debug_build":OS.is_debug_build(),"gpu_time_ms":null,"note":"Whole-frame wall time on local standalone Godot; GPU timing not independently captured."}
	return result

func sum_values(a: Array) -> float:
	var result := 0.0
	for value in a: result += value
	return result

func capture_suite() -> void:
	ui.visible = false
	var mode := "optimized" if optimized else "original"
	stats["overview"] = await measure(mode)
	await save_picture(mode+"_overview")
	if optimized:
		target = Vector3(-73,0,40)
		camera.size = 85
		update_camera()
		stats["village"] = await measure(mode)
		await save_picture("optimized_village")
		target = Vector3(112,2,-38)
		camera.size = 100
		update_camera()
		await wait_frames(12)
		await save_picture("optimized_fortress")
		target = Vector3(-60,4,-95)
		camera.size = 115
		update_camera()
		await wait_frames(12)
		await save_picture("optimized_ridge")
		target = Vector3(-10,0,50)
		camera.size = 55
		update_camera()
		await wait_frames(12)
		await save_picture("optimized_units")
		save_document()
	var f := FileAccess.open(out.path_join(mode+"-receipt.json"),FileAccess.WRITE)
	f.store_string(JSON.stringify({"stats":stats,"seed":seed_value,"density":density,"meander":meander,"placements":document.size(),"counts":counts,"used_prop_keys":cover_keys.keys(),"generate_ms":build_ms,"scope":"DEV presentation only; no tutorial or mission loaded; input parameter validation and UI tests separate."},"\t"))
	print("[FullMapLab] CAPTURE_COMPLETE ",mode)
	quit()
