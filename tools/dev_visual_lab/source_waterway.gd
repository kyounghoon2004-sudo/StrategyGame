extends RefCounted
## Water-only derivatives from existing GLBs; originals remain immutable.
const SOURCE_DIR := "res://assets/map_composition_v0/source_glb/water/"
const FILES := ["01-narrowstream.glb","02-mainriver.glb","03-shallowford.glb","04-woodenbridge.glb","05-stonereinforcedbridge.glb","06-tallrockriverbank.glb"]
const OUT := "C:/Users/User/Documents/Codex/2026-10-18/strategygame-godot-4-2-2-repo/outputs/waterway-lab"
var palette: Array[Color] = []
var extraction_report: Array = []
var surface_material: StandardMaterial3D
var source_flow: Mesh
var animated_material: ShaderMaterial
var flow_clock := 0.0
var banks_report: Dictionary = {}
var channel_curve: Curve3D
var channel_length := 0.0
var export_directory := OUT
var bank_meshes: Array[Mesh] = []

func half_width_at(_distance: float) -> float:
	return 7.0

func bank_style_at(_distance: float,_side: float) -> Dictionary:
	return {"width":[3.8,5.0],"height":[2.0,4.1],"depth":[6.0,8.0],"step":[3.2,4.0],"shoulder_chance":0.40}

func bank_instance_allowed(_placement: Transform3D,_mesh: Mesh) -> bool:
	return true

func load_source_palette() -> void:
	var document := GLTFDocument.new()
	var state := GLTFState.new()
	assert(document.append_from_file(ProjectSettings.globalize_path(SOURCE_DIR+FILES[1]),state)==OK)
	var mesh: Mesh = state.get_meshes()[0].get_mesh().get_mesh()
	source_flow = state.get_meshes()[2].get_mesh().get_mesh()
	var arrays := mesh.surface_get_arrays(0)
	var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
	var xmin := INF
	var xmax := -INF
	for i in range(positions.size()):
		if absf(positions[i].z)<0.35 and normals[i].y>0.8:
			xmin = minf(xmin,positions[i].x)
			xmax = maxf(xmax,positions[i].x)
	assert(xmax>xmin)
	for band in range(9):
		var sum := Color(0,0,0,0)
		var count := 0
		for i in range(positions.size()):
			if absf(positions[i].z)>0.35 or normals[i].y<0.8: continue
			var u := (positions[i].x-xmin)/(xmax-xmin)
			if absi(roundi(u*8)-band)>0: continue
			sum += colors[i]
			count += 1
		assert(count>0)
		var color := sum/float(count)
		color.a = 1.0
		palette.append(color)
	surface_material = StandardMaterial3D.new()
	surface_material.vertex_color_use_as_albedo = true
	surface_material.roughness = 0.63
	surface_material.metallic = 0.0
	surface_material.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
	surface_material.cull_mode = BaseMaterial3D.CULL_DISABLED

func extract_all() -> Array:
	DirAccess.make_dir_recursive_absolute(OUT.path_join("extracted"))
	for file in FILES:
		var document := GLTFDocument.new()
		var state := GLTFState.new()
		var original := ProjectSettings.globalize_path(SOURCE_DIR+file)
		assert(document.append_from_file(original,state)==OK)
		var source := document.generate_scene(state) as Node3D
		var clean := Node3D.new()
		clean.name = "WaterOnly_"+file.get_basename()
		var parts: Array = []
		var triangles := 0
		for node in source.find_children("*","MeshInstance3D",true,false):
			var name := String(node.name).to_lower()
			if not (name.ends_with("_water") or name.ends_with("_foam") or name.ends_with("_flow")): continue
			var copy := node.duplicate() as MeshInstance3D
			clean.add_child(copy)
			parts.append(String(node.name))
			for s in range(node.mesh.get_surface_count()):
				var arrays: Array = node.mesh.surface_get_arrays(s)
				triangles += (arrays[Mesh.ARRAY_INDEX].size() if not arrays[Mesh.ARRAY_INDEX].is_empty() else arrays[Mesh.ARRAY_VERTEX].size())/3
		assert(parts.size()==3)
		var output := OUT.path_join("extracted/water_only_"+file)
		var export_document := GLTFDocument.new()
		var export_state := GLTFState.new()
		assert(export_document.append_from_scene(clean,export_state)==OK)
		assert(export_document.write_to_filesystem(export_state,output)==OK)
		var reload_document := GLTFDocument.new()
		var reload_state := GLTFState.new()
		assert(reload_document.append_from_file(output,reload_state)==OK)
		var reload := reload_document.generate_scene(reload_state)
		assert(reload.find_children("*","MeshInstance3D",true,false).size()==3)
		extraction_report.append({"source":original,"source_sha256":FileAccess.get_sha256(original),"parts":parts,"triangles":triangles,"output":output,"output_sha256":FileAccess.get_sha256(output),"fresh_reload":true,"geometry":"Original water/foam/flow geometry and materials, no banks/rocks/trees/bridges"})
		reload.free(); clean.free(); source.free()
	return extraction_report

func ordered_trunk(cells: Array,centres: Callable) -> Dictionary:
	var lookup := {}
	var start := Vector2i.ZERO
	var end := Vector2i.ZERO
	var minz := INF
	var maxz := -INF
	for c in cells:
		if c["kind"]!="river": continue
		var key := Vector2i(c["q"],c["r"])
		lookup[key] = true
		var p: Vector3 = centres.call(key.x,key.y)
		if p.z<minz: minz = p.z; start = key
		if p.z>maxz: maxz = p.z; end = key
	var dirs := [Vector2i(1,0),Vector2i(0,1),Vector2i(-1,1),Vector2i(-1,0),Vector2i(0,-1),Vector2i(1,-1)]
	var parents := {start:null}
	var queue: Array = [start]
	var cursor := 0
	while cursor<queue.size():
		var key: Vector2i = queue[cursor]
		cursor += 1
		for d in dirs:
			var next: Vector2i = key+d
			if lookup.has(next) and not parents.has(next): parents[next] = key; queue.append(next)
	assert(parents.size()==lookup.size(),"River must be a single connected logical component")
	var path: Array[Vector3] = []
	var current: Variant = end
	while current!=null:
		path.push_front(centres.call(current.x,current.y))
		current = parents[current]
	return {"path":path,"river_cells":lookup.size(),"trunk_cells":path.size(),"connected":true}

func create_channel(cells: Array,centres: Callable,parent: Node3D,export_asset: bool = true) -> Dictionary:
	if palette.is_empty(): load_source_palette()
	var trunk := ordered_trunk(cells,centres)
	var points: Array[Vector3] = trunk["path"]
	points.push_front(points[0]+(points[0]-points[1]).normalized()*13.0)
	points.append(points[-1]+(points[-1]-points[-2]).normalized()*13.0)
	var curve := Curve3D.new()
	curve.bake_interval = 2.0
	for i in range(points.size()):
		var tangent := (points[mini(i+1,points.size()-1)]-points[maxi(i-1,0)])*0.18
		curve.add_point(points[i],-tangent,tangent)
	var length := curve.get_baked_length()
	channel_curve = curve
	channel_length = length
	var rows := ceili(length/2.0)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var width_min := INF
	var width_max := 0.0
	var row_points: Array = []
	for row in range(rows+1):
		var distance := length*float(row)/rows
		var half_width := half_width_at(distance)
		width_min = minf(width_min,half_width*2.0)
		width_max = maxf(width_max,half_width*2.0)
		var p := curve.sample_baked(distance,true)
		var ahead := curve.sample_baked(minf(distance+0.5,length),true)
		var behind := curve.sample_baked(maxf(distance-0.5,0),true)
		var direction := (ahead-behind).normalized()
		var perpendicular := Vector3(-direction.z,0,direction.x).normalized()
		var cross_section: Array[Vector3] = []
		for band in range(9):
			var u := float(band)/8.0
			var point := p+perpendicular*lerpf(-half_width,half_width,u)
			point.y = 0.16
			cross_section.append(point)
		row_points.append(cross_section)
	var triangles := 0
	for row in range(rows):
		for band in range(8):
			for v in [[row,band],[row+1,band],[row,band+1],[row,band+1],[row+1,band],[row+1,band+1]]:
				st.set_normal(Vector3.UP)
				st.set_color(palette[v[1]])
				st.set_uv(Vector2(float(v[1])/8.0,length*float(v[0])/rows))
				st.add_vertex(row_points[v[0]][v[1]])
			triangles += 2
	st.index()
	var mesh := st.commit()
	var node := MeshInstance3D.new()
	node.name = "SourceDerivedContinuousWaterOnly"
	node.mesh = mesh
	animated_material = ShaderMaterial.new()
	animated_material.shader = load("res://tools/dev_visual_lab/river_current.gdshader")
	node.material_override = animated_material
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(node)
	banks_report = create_rock_banks(curve,length,parent)
	var output := ""
	if export_asset:
		var document := GLTFDocument.new()
		var state := GLTFState.new()
		var export_root := Node3D.new()
		var exported := MeshInstance3D.new()
		exported.name = node.name
		exported.mesh = mesh
		exported.material_override = surface_material
		export_root.add_child(exported)
		assert(document.append_from_scene(export_root,state)==OK)
		DirAccess.make_dir_recursive_absolute(export_directory)
		output = export_directory.path_join("continuous_mainriver.glb")
		assert(document.write_to_filesystem(state,output)==OK)
		export_root.free()
		var reloader := GLTFDocument.new()
		var reload_state := GLTFState.new()
		assert(reloader.append_from_file(output,reload_state)==OK)
		var reloaded := reloader.generate_scene(reload_state)
		assert(reloaded!=null,"Continuous water GLB generated no scene")
		assert(reloaded.find_children("*","MeshInstance3D",true,false).size()>0 or reloaded is MeshInstance3D)
		reloaded.free()
	var positions: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var finite := true
	for point in positions:
		if not point.is_finite(): finite = false
	return {"source":SOURCE_DIR+FILES[1],"source_sha256":FileAccess.get_sha256(SOURCE_DIR+FILES[1]),"method":"New continuous strip topology fitted to unchanged river cells; 9-band colors sampled from MainRiver water. Existing MainRiver stone blocks reused along both banks; two sparse shader current strokes animate per 180 units. Not raw GLB concatenation.","river_cells":trunk["river_cells"],"trunk_cells":trunk["trunk_cells"],"connected":true,"finite":finite,"water_level":0.16,"width":half_width_at(length*0.5)*2.0,"width_min":width_min,"width_max":width_max,"length":length,"rows":rows+1,"triangles":triangles,"animated_current":{"strokes_per_180_units":2,"speed_units_per_second":8,"extra_draw_calls":0},"banks":banks_report,"surfaces":mesh.get_surface_count(),"draw_materials":1,"transparent_layers":0,"export":output,"export_sha256":FileAccess.get_sha256(output) if export_asset else "","fresh_reload":export_asset,"join_rule":"Water body shares each entire 9-vertex cross section; animated flow accents use that same opaque surface. No per-hex overlap planes.","palette_linear":palette.map(func(c): return [c.r,c.g,c.b])}


func advance_flow(delta: float) -> void:
	set_flow_time(flow_clock+delta)

func set_flow_time(seconds: float) -> void:
	flow_clock = seconds
	if animated_material!=null: animated_material.set_shader_parameter("flow_clock",seconds)

func create_rock_banks(curve: Curve3D,length: float,parent: Node3D) -> Dictionary:
	var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://tools/dev_visual_lab/bank_rock_templates.json"))
	var templates: Array = data["templates"]
	var meshes: Array[Mesh] = []
	var material := StandardMaterial3D.new()
	material.vertex_color_use_as_albedo = true
	material.roughness = 1.0
	material.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
	material.cull_mode = BaseMaterial3D.CULL_BACK
	for t in templates:
		var tool := SurfaceTool.new()
		tool.begin(Mesh.PRIMITIVE_TRIANGLES)
		for emitted in range(t["positions"].size()):
			# glTF fronts are counterclockwise; Godot fronts are clockwise.
			# Reverse each triangle when bypassing Godot's GLTF importer.
			var i: int = (emitted/3)*3+[0,2,1][emitted%3]
			var n: Array = t["normals"][i]
			var c: Array = t["colors"][i]
			var v: Array = t["positions"][i]
			tool.set_normal(Vector3(n[0],n[1],n[2]))
			# glTF COLOR_0 is linear; Godot StandardMaterial vertex colors use sRGB.
			tool.set_color(Color(c[0],c[1],c[2],c[3] if c.size()>3 else 1.0).linear_to_srgb())
			tool.add_vertex(Vector3(v[0],v[1],v[2]))
		tool.index()
		var mesh := tool.commit()
		mesh.surface_set_material(0,material)
		meshes.append(mesh)
	bank_meshes = meshes
	# Batches are spatially bounded (~90 units), for frustum culling.
	var batches := {}
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261019
	var count := 0
	for side in [-1.0,1.0]:
		var station := 0.0 if side<0 else 1.3
		while station<length:
			var id := rng.randi_range(0,meshes.size()-1)
			var p := curve.sample_baked(station,true)
			var direction := (curve.sample_baked(minf(length,station+0.5),true)-curve.sample_baked(maxf(0,station-0.5),true)).normalized()
			var across := Vector3(-direction.z,0,direction.x).normalized()
			var style := bank_style_at(station,float(side))
			var width := rng.randf_range(style["width"][0],style["width"][1])
			var height := rng.randf_range(style["height"][0],style["height"][1])
			var depth := rng.randf_range(style["depth"][0],style["depth"][1])
			p += across*side*(half_width_at(station)+width*0.40+rng.randf_range(-0.25,0.25))
			p.y = -0.28-rng.randf_range(0,0.18)
			var size: Array = templates[id]["size"]
			var basis := Basis(across,Vector3.UP,-direction)
			basis = basis*Basis(Vector3.UP,rng.randf_range(-0.33,0.33))
			basis = basis*Basis.from_scale(Vector3(width/size[0],height/size[1],depth/size[2]))
			var key := Vector2i(int(station/90.0),id)
			if not batches.has(key): batches[key] = []
			var placement := Transform3D(basis,p)
			if bank_instance_allowed(placement,meshes[id]):
				batches[key].append(placement)
				count += 1
			# Small, irregular shoulders break the single-file silhouette while
			# retaining the same eight source meshes and spatial batches.
			if rng.randf()<float(style["shoulder_chance"]):
				var shoulder: Vector3 = p+across*side*rng.randf_range(2.0,3.1)+direction*rng.randf_range(-1.0,1.0)
				shoulder.y = -0.24
				var shoulder_basis := Basis(across,Vector3.UP,-direction)*Basis(Vector3.UP,rng.randf_range(-1.2,1.2))
				shoulder_basis = shoulder_basis*Basis.from_scale(Vector3(rng.randf_range(2.1,3.5)/size[0],rng.randf_range(1.2,2.5)/size[1],rng.randf_range(2.7,4.2)/size[2]))
				var shoulder_placement := Transform3D(shoulder_basis,shoulder)
				if bank_instance_allowed(shoulder_placement,meshes[id]):
					batches[key].append(shoulder_placement)
					count += 1
			station += rng.randf_range(style["step"][0],style["step"][1])
	for key in batches:
		var transforms: Array = batches[key]
		if transforms.is_empty(): continue
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = meshes[key.y]
		mm.instance_count = transforms.size()
		for i in range(transforms.size()): mm.set_instance_transform(i,transforms[i])
		var instance := MultiMeshInstance3D.new()
		instance.name = "MainRiverBank_%s_%s" % [key.x,key.y]
		instance.multimesh = mm
		instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		parent.add_child(instance)
	return {"source":"02-mainriver.glb / MainRiver_rock","unique_original_blocks":meshes.size(),"triangles_per_block":22,"instances":count,"instanced_triangles":count*22,"spatial_batches":batches.size(),"seed":20261019,"method":"Original disconnected stone blocks, recentered only; scale/rotation placement along both continuous banks, shared instanced meshes"}
