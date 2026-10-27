extends "res://tools/dev_visual_lab/source_waterway.gd"
## Continuous water + full-hex riparian ground; original map ownership unchanged.
const SHORE_OUT := "C:/Users/User/Documents/Codex/2026-10-18/strategygame-godot-4-2-2-repo/outputs/river-shoreline"
const HEX_R := 18.0
var config: Dictionary
var cell_map := {}
var bridge_stations: Array[float] = []
var bridge_points: Array[Vector3] = []
var detail_batches: Array[Dictionary] = []
var shore_report := {}
var ground_colors := {}
var rejected_bank_instances := 0

func inside_hex(p: Vector3,c: Vector3,radius: float) -> bool:
	var x := absf(p.x-c.x)
	var z := absf(p.z-c.z)
	return z<=radius*sqrt(3.0)*0.5 and sqrt(3.0)*0.5*x+0.5*z<=radius*sqrt(3.0)*0.5

func bank_instance_allowed(placement: Transform3D,mesh: Mesh) -> bool:
	var bounds := mesh.get_aabb()
	for corner in range(8):
		var p: Vector3 = placement*bounds.get_endpoint(corner)
		var coord := coord_at(p)
		if cell_map.get(coord,"") in ["farm","village","castle"]:
			var c := Vector3(27.0*coord.x,0,sqrt(3.0)*HEX_R*(coord.y+coord.x*0.5))
			if inside_hex(p,c,16.8):
				rejected_bank_instances += 1
				return false
	return true
var noise := FastNoiseLite.new()

func _init() -> void:
	config = JSON.parse_string(FileAccess.get_file_as_string(SHORE_OUT.path_join("shoreline-config.json")))
	export_directory = SHORE_OUT.path_join("exports")
	noise.seed = int(config["seed"])
	noise.frequency = 0.085

func coord_at(p: Vector3) -> Vector2i:
	var q := p.x/27.0
	var r := p.z/(sqrt(3.0)*HEX_R)-q*0.5
	var y := -q-r
	var iq := roundi(q)
	var ir := roundi(r)
	var iy := roundi(y)
	var dq := absf(float(iq)-q)
	var dr := absf(float(ir)-r)
	var dy := absf(float(iy)-y)
	if dq>dr and dq>dy: iq = -iy-ir
	elif dr>dy: ir = -iq-iy
	return Vector2i(iq,ir)

func kind_at(p: Vector3) -> String:
	return str(cell_map.get(coord_at(p),"outside"))

func curve_frame(distance: float) -> Array:
	var p := channel_curve.sample_baked(distance,true)
	var direction := (channel_curve.sample_baked(minf(channel_length,distance+0.5),true)-channel_curve.sample_baked(maxf(0,distance-0.5),true)).normalized()
	return [p,Vector3(-direction.z,0,direction.x).normalized()]

func half_width_at(distance: float) -> float:
	if channel_curve==null: return 7.0
	if bridge_stations.is_empty():
		for p in bridge_points: bridge_stations.append(channel_curve.get_closest_offset(p))
	var half: float = float(config["width_center"])*0.5+sin(distance*0.023)*0.65+sin(distance*0.051+1.3)*0.32
	var frame := curve_frame(distance)
	var p: Vector3 = frame[0]
	var across: Vector3 = frame[1]
	# Reserve bank footing before crop/building tiles. No gameplay collision edit.
	for side in [-1.0,1.0]:
		var cap := half
		while cap>7.5 and kind_at(p+across*float(side)*(cap+1.8)) in ["farm","village","castle"]:
			cap -= 0.25
		half = minf(half,cap)
	for station in bridge_stations:
		half = lerpf(7.0,half,smoothstep(12.0,26.0,absf(distance-station)))
	return half

func bank_style_at(distance: float,side: float) -> Dictionary:
	var frame := curve_frame(distance)
	var neighbor := kind_at(frame[0]+frame[1]*side*18.5)
	var height := [0.85,1.95]
	var width := [2.5,3.4]
	if neighbor in ["farm","village","castle"]:
		height = [0.65,1.35]; width = [2.0,2.7]
	elif neighbor=="mountain":
		height = [1.5,2.8]; width = [3.1,4.0]
	for station in bridge_stations:
		if absf(distance-station)<12.0: height = [0.5,0.9]; width = [1.8,2.4]
	return {"width":width,"height":height,"depth":[6.0,8.0],"step":[3.8,4.8],"shoulder_chance":0.12}

func create_channel(cells: Array,centres: Callable,parent: Node3D,export_asset: bool = true) -> Dictionary:
	cell_map.clear()
	for cell in cells: cell_map[Vector2i(cell["q"],cell["r"])] = cell["kind"]
	for r in [1,-3,4]:
		if cell_map.get(Vector2i(0,r),"")=="river": bridge_points.append(centres.call(0,r))
	var report := super.create_channel(cells,centres,parent,export_asset)
	shore_report = build_shore_ground(cells,centres,parent,export_asset)
	shore_report["decoration"] = scatter_details(cells,centres,parent)
	report["shoreline"] = shore_report
	report["method"] = "Variable-width continuous strip; lower source-rock banks and full river-owned hex ground transitioning to neighboring terrain. Seeded opaque instanced reeds/pebbles."
	report["bridge_stations"] = bridge_stations
	report["banks"]["rejected_protected_footprints"] = rejected_bank_instances
	return report

func shore_color(p: Vector3,hex_center: Vector3) -> Color:
	var distance := channel_curve.get_closest_offset(p)
	var delta := p.distance_to(channel_curve.sample_baked(distance,true))-half_width_at(distance)
	var wet := Color("6b7861")
	var soil := Color("9b916e")
	var outer: Color
	var neighbor := kind_at(hex_center+(p-hex_center)*1.14)
	match neighbor:
		"farm": outer = Color("96805d")
		"village","castle": outer = Color("9a9470")
		"mountain": outer = Color("9b9681")
		"forest": outer = Color("65764b")
		_: outer = Color("899b65")
	var color := wet.lerp(soil,smoothstep(0.0,4.0,delta))
	if neighbor!="river": color = color.lerp(outer,smoothstep(3.0,8.0,delta))
	var linear := color.lightened(noise.get_noise_2d(p.x,p.z)*0.06).srgb_to_linear()
	# Match the existing board's darker ambient-lit ground at the shared edge,
	# without changing the old board normals or the new kit's lit farm surfaces.
	if neighbor in ["plain","forest","mountain","outside"]:
		var local := p-hex_center
		var rho := maxf(absf(local.z)/(HEX_R*sqrt(3.0)*0.5),(sqrt(3.0)*0.5*absf(local.x)+0.5*absf(local.z))/(HEX_R*sqrt(3.0)*0.5))
		var edge := outer.srgb_to_linear()*float(config["neighbor_edge_shade"])
		edge.a = 1.0
		linear = linear.lerp(edge,smoothstep(0.68,1.0,rho))
	return linear

func shore_vertex(tool: SurfaceTool,p: Vector3,hex_center: Vector3) -> void:
	var key := Vector2(p.x,p.z)
	if not ground_colors.has(key): ground_colors[key] = shore_color(p,hex_center)
	tool.set_color(ground_colors[key])
	tool.set_normal(Vector3.UP)
	tool.add_vertex(Vector3(p.x,0.065,p.z))

func build_shore_ground(cells: Array,centres: Callable,parent: Node3D,export_asset: bool) -> Dictionary:
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	var triangles := 0
	var river_hexes := 0
	# Identical shared boundaries, no independent jitter at hex seams.
	for cell in cells:
		if cell["kind"]!="river": continue
		river_hexes += 1
		var c: Vector3 = centres.call(cell["q"],cell["r"])
		var last_ring: Array[Vector3] = []
		for ring in range(1,5):
			var current: Array[Vector3] = []
			for side in range(6):
				var a := Vector3(cos(float(side)*PI/3.0),0,sin(float(side)*PI/3.0))*HEX_R
				var b := Vector3(cos(float(side+1)*PI/3.0),0,sin(float(side+1)*PI/3.0))*HEX_R
				for step in range(3): current.append(c+a.lerp(b,float(step)/3.0)*float(ring)/4.0)
			for i in range(18):
				var next := (i+1)%18
				if ring==1:
					for p in [c,current[i],current[next]]: shore_vertex(tool,p,c)
					triangles += 1
				else:
					for p in [last_ring[i],current[i],current[next],last_ring[i],current[next],last_ring[next]]: shore_vertex(tool,p,c)
					triangles += 2
			last_ring = current
	tool.index()
	var mesh := tool.commit()
	var material := StandardMaterial3D.new()
	material.vertex_color_use_as_albedo = true
	material.roughness = 1.0
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	var node := MeshInstance3D.new()
	node.name = "FullHexRiparianGround"
	node.mesh = mesh
	node.material_override = material
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(node)
	if export_asset:
		var document := GLTFDocument.new()
		var state := GLTFState.new()
		var wrapper := Node3D.new()
		wrapper.add_child(node.duplicate())
		assert(document.append_from_scene(wrapper,state)==OK)
		var path := export_directory.path_join("full_hex_shore_ground.glb")
		assert(document.write_to_filesystem(state,path)==OK)
		wrapper.free()
		var reader := GLTFDocument.new()
		var reload_state := GLTFState.new()
		assert(reader.append_from_file(path,reload_state)==OK)
		var reloaded := reader.generate_scene(reload_state)
		assert(reloaded!=null)
		reloaded.free()
	return {"river_hexes":river_hexes,"hex_radius":HEX_R,"coverage":"Entire owned river hex, identical shared edge vertices; no logical map edits","triangles":triangles,"opaque_surfaces":1,"ground_y":0.065,"export_reload":export_asset}

func make_reed_mesh() -> Mesh:
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	for blade in range(5):
		var angle := float(blade)*TAU/5.0
		var axis := Vector3(cos(angle),0,sin(angle))
		var side := Vector3(-axis.z,0,axis.x)*0.07
		var base := axis*0.18
		var mid := axis*0.34+Vector3.UP*(0.65+float(blade%2)*0.18)
		var tip := axis*0.58+Vector3.UP*(1.1+float(blade%3)*0.15)
		for p in [base-side,base+side,mid-side,mid-side,base+side,mid+side,mid-side,mid+side,tip]:
			tool.set_color(Color("7e8c4d").lerp(Color("b8aa72"),clampf(p.y/1.8,0,1)).srgb_to_linear())
			tool.set_normal(Vector3.UP)
			tool.add_vertex(p)
	tool.index()
	var mesh := tool.commit()
	var material := StandardMaterial3D.new()
	material.vertex_color_use_as_albedo = true
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.roughness = 1.0
	mesh.surface_set_material(0,material)
	return mesh

func scatter_details(cells: Array,centres: Callable,parent: Node3D) -> Dictionary:
	var meshes: Array[Mesh] = bank_meshes.duplicate()
	meshes.append(make_reed_mesh())
	var groups := {}
	var pebbles := 0
	var reeds := 0
	var rejected_bridge := 0
	var rejected_occupied := 0
	var placement_keys: Array[String] = []
	for cell in cells:
		if cell["kind"]!="river": continue
		var rng := RandomNumberGenerator.new()
		rng.seed = int(config["seed"])+int(cell["q"])*92821+int(cell["r"])*68917
		var c: Vector3 = centres.call(cell["q"],cell["r"])
		var accepted := 0
		for attempt in range(40):
			if accepted>=int(config["details_per_hex"]): break
			var p := c+Vector3(rng.randf_range(-17,17),0,rng.randf_range(-15,15))
			if coord_at(p)!=Vector2i(cell["q"],cell["r"]): continue
			var protected := false
			for bridge in bridge_points:
				if p.distance_to(bridge)<14.0: protected = true
			if protected: rejected_bridge += 1; continue
			var distance := channel_curve.get_closest_offset(p)
			var foot := channel_curve.sample_baked(distance,true)
			var gap := p.distance_to(foot)-half_width_at(distance)
			if gap<2.9 or gap>8.5: continue
			# Stay clear of farm/village ownership even at wide bends.
			if kind_at(p)!="river": rejected_occupied += 1; continue
			var theme := kind_at(c+(p-c)*1.3)
			var reed_chance := 0.65 if theme=="forest" else (0.12 if theme in ["farm","village","mountain"] else 0.45)
			var id := 8 if rng.randf()<reed_chance else rng.randi_range(0,7)
			var scale := Vector3.ONE
			if id==8:
				scale = Vector3.ONE*rng.randf_range(0.65,1.3)
				reeds += 1
			else:
				var size := meshes[id].get_aabb().size
				scale = Vector3(rng.randf_range(0.6,1.3)/size.x,rng.randf_range(0.22,0.55)/size.y,rng.randf_range(0.6,1.3)/size.z)
				pebbles += 1
			p.y = 0.065
			var basis := Basis(Vector3.UP,rng.randf()*TAU)*Basis.from_scale(scale)
			var key := Vector3i(floori(p.x/90.0),floori(p.z/90.0),id)
			if not groups.has(key): groups[key] = []
			groups[key].append(Transform3D(basis,p))
			placement_keys.append("%d,%d:%d:%.5f,%.5f:%.5f,%.5f,%.5f" % [cell["q"],cell["r"],id,p.x,p.z,scale.x,scale.y,scale.z])
			accepted += 1
	for key in groups:
		var transforms: Array = groups[key]
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = meshes[key.z]
		mm.instance_count = transforms.size()
		for i in range(transforms.size()): mm.set_instance_transform(i,transforms[i])
		var node := MultiMeshInstance3D.new()
		node.name = "ShoreDetail_%d_%d_%d" % [key.x,key.y,key.z]
		node.multimesh = mm
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		parent.add_child(node)
		detail_batches.append({"node":node,"reed":key.z==8})
	placement_keys.sort()
	return {"pebbles":pebbles,"reeds":reeds,"batches":groups.size(),"rejected_near_bridges":rejected_bridge,"rejected_occupied":rejected_occupied,"seed":config["seed"],"placement_sha256":JSON.stringify(placement_keys).sha256_text(),"placement":"Seeded per hex; only river-owned ground, outside water and bank footing; crossing exclusion 14 units","reed_triangles_each":15,"pebble_triangles_each":22,"transparent_layers":0}

func set_detail(camera_size: float) -> void:
	for item in detail_batches:
		item["node"].visible = camera_size<(260.0 if item["reed"] else 500.0)
