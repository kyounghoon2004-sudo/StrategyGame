extends "res://tools/dev_visual_lab/full_map_lab.gd"
## One hex = one scenery. A separate DEV document; no mission map dependencies.
const R := 18.0
const H := 15.588457268
const SQRT3 := 1.73205080757
const TYPES := ["plain","forest","mountain","castle","village","farm","river"]
const DIRS := [Vector2i(1,0),Vector2i(1,-1),Vector2i(0,-1),Vector2i(-1,0),Vector2i(-1,1),Vector2i(0,1)]
var cells: Array = []
var chosen := -1
var brush: OptionButton
var hex_history: Array = []
var relay: Node
var tile_lookup := {}
var structural_report := {}
var original_manifest: Dictionary
class InputRelay extends Node:
	var controller: Object
	func _unhandled_input(event: InputEvent) -> void:
		controller.handle_hex_input(event)

func boot() -> void:
	root.title = "StrategyGame | DEV Hex Scenery Workshop"
	relay = InputRelay.new()
	relay.controller = self
	root.add_child(relay)
	original_manifest = JSON.parse_string(FileAccess.get_file_as_string(out.path_join("optimization-manifest.json")))
	await super.boot()

func center(q: int,r: int) -> Vector3:
	return Vector3(1.5*R*q,0,SQRT3*R*(r+q*0.5))

func hex_key(q: int,r: int) -> String:
	return "%d,%d" % [q,r]

func inside(p: Vector2, inset: float = 0.96) -> bool:
	return absf(p.y)<=H*inset and SQRT3*absf(p.x)+absf(p.y)<=SQRT3*R*inset

func make_ui() -> void:
	super.make_ui()
	var column: VBoxContainer = info.get_parent()
	(column.get_child(0) as Label).text = "HEX SCENERY WORKSHOP\nONE HEX / ONE SCENERY"
	(column.get_child(1) as Label).text = "Click: select hex  |  Drag: swap scenery\nWheel: zoom   RMB: orbit   WASD: pan\nR: rotate hex   Ctrl+Z: undo   Home: map"
	for n in column.get_children():
		if n is Label and n.text == "RIVER MEANDER": n.text = "FOREST MIX (pine / broadleaf)"
	brush = OptionButton.new()
	for kind in TYPES: brush.add_item(kind.to_upper())
	column.add_child(brush)
	var apply := Button.new()
	apply.text = "PAINT SELECTED HEX"
	apply.pressed.connect(func():
		if chosen<0: return
		push_hex_history()
		cells[chosen]["kind"] = TYPES[brush.selected]
		recompose())
	column.add_child(apply)
	var legend := Label.new()
	legend.text = "Forest + forest = continuous woodland\nMountain + mountain = connected ridge\nCastle stays within ONE hex."
	column.add_child(legend)

func generate() -> void:
	density = maxf(density,0.86) if cells.is_empty() else density
	density_input.value = density
	terrain_noise.seed = seed_value
	terrain_noise.frequency = 0.018
	moisture.seed = seed_value+974
	moisture.frequency = 0.032
	cells.clear()
	tile_lookup.clear()
	for q in range(-6,7):
		for r in range(-5,6):
			if abs(q+r)>6: continue
			var kind := "plain"
			if (r<=-3 and q!=0) or (q>=4 and r==-2): kind = "mountain"
			elif (q>=2 and r>=-1 and r<=3) or (q<=-3 and r<=0 and r>=-2): kind = "forest"
			elif q<=-2 and r>=2 and r<=4: kind = "farm"
			if q==0: kind = "river"
			if q==-3 and r==1: kind = "village"
			if q==3 and r==1: kind = "castle"
			if q==-4 and r==-2: kind = "castle"
			var id := cells.size()
			cells.append({"q":q,"r":r,"kind":kind,"variant":posmod(q*5+r*3,8),"rotation":0,"road":r==1})
			tile_lookup[hex_key(q,r)] = id
	chosen = -1
	if ring!=null: ring.visible = false
	recompose()

func add_prop(cell: Dictionary,key: String,local: Vector2,width: float,angle: float = 0) -> void:
	var b: Dictionary = Lib.bounds(key)
	var size: Vector3 = b["max"]-b["min"]
	var rotated_local := local.rotated(float(cell["rotation"])*PI/3)
	var angle_total: float = angle+float(cell["rotation"])*PI/3
	var actual := width
	var violation := true
	for attempt in range(18):
		violation = false
		var half := Vector2(size.x,size.z)*actual/maxf(size.x,size.z)*0.5
		for sx in [-1.0,1.0]:
			for sz in [-1.0,1.0]:
				var v := Vector2(half.x*sx,half.y*sz).rotated(-angle_total)+rotated_local
				if not inside(v): violation = true
		if not violation: break
		actual *= 0.88
	if violation: return
	var c := center(int(cell["q"]),int(cell["r"]))
	var p := c+Vector3(rotated_local.x,0,rotated_local.y)
	document.append({"id":document.size(),"key":key,"p":[p.x,0.16,p.z],"width":actual,"yaw":angle_total,"cell":[cell["q"],cell["r"]],"role":cell["kind"]})

func recompose() -> void:
	var started := Time.get_ticks_msec()
	document.clear()
	for cell in cells:
		var kind: String = cell["kind"]
		var rng := RandomNumberGenerator.new()
		rng.seed = seed_value+int(cell["q"])*92821+int(cell["r"])*68917
		var variant: int = cell["variant"]
		match kind:
			"castle":
				add_prop(cell,"stronghold" if int(cell["q"])>0 else "hill_fort",Vector2(0,-3),15)
				add_prop(cell,"gatehouse",Vector2(0,10),6)
				for side in range(6):
					var angle: float = side*PI/3
					add_prop(cell,"stone_wall" if int(cell["q"])>0 else "palisade",Vector2(cos(angle)*13,sin(angle)*13),8,PI*0.5-angle)
				for p in [Vector2(-10,-6),Vector2(10,-6),Vector2(-10,6),Vector2(10,6)]: add_prop(cell,"watchtower",p,3.4)
				add_prop(cell,"small_house",Vector2(-6,4),4)
				add_prop(cell,"granary",Vector2(6,4),4)
			"village":
				var keys := ["small_house","medium_house","workshop","granary","small_house","medium_house"]
				for i in range(6): add_prop(cell,keys[i],Vector2((i%3-1)*8,-6 if i<3 else 6),6,PI if i<3 else 0)
				add_prop(cell,"hall",Vector2(0,-0.5),7)
				add_prop(cell,"gate",Vector2(12,0),4,PI*0.5)
			"farm":
				var keys := ["dry_field","rice_field","terraced_field"]
				add_prop(cell,keys[variant%3],Vector2.ZERO,25)
				add_prop(cell,"farm_granary",Vector2(-9,8),4)
				if variant%2==0: add_prop(cell,"irrigation",Vector2(8,-9),5)
			"mountain":
				var keys: Array = Lib.MOUNTAINS.keys()
				add_prop(cell,keys[variant],Vector2.ZERO,31,0)
				# Flank joins run along neighbouring mountain cells, preserving hex ownership.
				var c := Vector2i(int(cell["q"]),int(cell["r"]))
				for d in DIRS:
					var key := hex_key(c.x+d.x,c.y+d.y)
					if tile_lookup.has(key) and cells[tile_lookup[key]]["kind"]=="mountain":
						var off := center(c.x+d.x,c.y+d.y)-center(c.x,c.y)
						# Ridge continuity is rendered by a clipped half-edge ridge mesh below.
						pass
			"forest":
				var pine: bool = int(cell["r"])<1 or meander<20
				var mix := ["tall_pine","compact_pine","conifer","wind_pine"] if pine else ["broadleaf","cypress","sapling"]
				var filled := 0
				for z in range(-2,3):
					for x in range(-2,3):
						var p := Vector2(x*6.0+rng.randf_range(-0.85,0.85),z*6.0+rng.randf_range(-0.85,0.85))
						if not inside(p,0.80) or rng.randf()>density: continue
						var key: String = mix[rng.randi()%mix.size()]
						if filled==0 and variant==2: key = "dead_tree"
						var bounds: Dictionary = Lib.bounds(key)
						var extent: Vector3 = bounds["max"]-bounds["min"]
						var desired_width: float = rng.randf_range(10.0,12.0)*maxf(extent.x,extent.z)/extent.y
						add_prop(cell,key,p,desired_width,rng.randf()*TAU)
						filled += 1
			"plain":
				if variant%3==0: add_prop(cell,"sapling",Vector2(-8,6),4)
	build_terrain()
	rebuild_props()
	if actors!=null and actors.get_child_count()>0: make_actors()
	build_ms = Time.get_ticks_msec()-started
	info.text = "%d hexes | %d props | seed %d\nSelected hex sets one scenery.\nNeighbouring forests / ridges connect.\nDEV only: no mission state." % [cells.size(),document.size(),seed_value]

func cell_color(cell: Dictionary) -> Color:
	var kind: String = cell["kind"]
	var c := Color("899b65")
	match kind:
		"forest": c = Color("65764b")
		"mountain": c = Color("9b9681")
		"castle","village": c = Color("b4a281")
		"farm": c = Color("a2a06c")
		"river": c = Color("7b9b94")
	var pos := center(cell["q"],cell["r"])
	return c.lightened(terrain_noise.get_noise_2d(pos.x,pos.z)*0.05).srgb_to_linear()

func build_terrain() -> void:
	for n in land.get_children(): n.free()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var outline := SurfaceTool.new()
	outline.begin(Mesh.PRIMITIVE_TRIANGLES)
	for cell in cells:
		var c := center(cell["q"],cell["r"])
		var color := cell_color(cell)
		for side in range(6):
			var a: float = side*PI/3
			var b: float = (side+1)*PI/3
			var p := c+Vector3(cos(a)*R,0,sin(a)*R)
			var q := c+Vector3(cos(b)*R,0,sin(b)*R)
			for v in [c,q,p]:
				st.set_color(color)
				st.set_normal(Vector3.UP)
				st.add_vertex(v)
			# Thin shared edges keep cell identity without separating the landscape.
			var pin := c+(p-c)*0.994
			var qin := c+(q-c)*0.994
			for v in [p,q,pin,pin,q,qin]:
				outline.set_color(color.darkened(0.25))
				outline.set_normal(Vector3.UP)
				outline.add_vertex(v+Vector3.UP*0.035)
			# Continuous exposed board perimeter only, no gaps between tiles.
			var pdown := p-Vector3.UP*3
			var qdown := q-Vector3.UP*3
			for v in [p,pdown,q,q,pdown,qdown]:
				st.set_color(Color("514c3c").srgb_to_linear())
				st.set_normal(Vector3(cos(a+PI/6),0,sin(a+PI/6)))
				st.add_vertex(v)
	add_mesh(land,st.commit(),material)
	add_mesh(land,outline.commit(),material)
	# River connectors are derived from hex adjacency, never free-scattered pieces.
	var paths := SurfaceTool.new()
	paths.begin(Mesh.PRIMITIVE_TRIANGLES)
	var path_count := 0
	for cell in cells:
		if cell["kind"]!="mountain": continue
		var c := center(cell["q"],cell["r"])
		for d in DIRS:
			var key := hex_key(cell["q"]+d.x,cell["r"]+d.y)
			if tile_lookup.has(key) and cells[tile_lookup[key]]["kind"]=="mountain":
				var delta := (center(cell["q"]+d.x,cell["r"]+d.y)-c)*0.5
				var perp := Vector3(-delta.z,0,delta.x).normalized()*5.5
				var peak := c+Vector3.UP*0.9
				var edge := c+delta+Vector3.UP*0.65
				for triangle in [[c-perp,peak,edge-perp],[peak,edge,edge-perp],[peak,c+perp,edge+perp],[peak,edge+perp,edge]]:
					var normal: Vector3 = (triangle[1]-triangle[0]).cross(triangle[2]-triangle[0]).normalized()
					for vertex in triangle:
						paths.set_normal(normal)
						paths.set_color(Color("96917e").srgb_to_linear())
						paths.add_vertex(vertex)
				path_count += 1
	for cell in cells:
		var c := center(cell["q"],cell["r"])
		if cell["kind"]=="river":
			for d in [Vector2i(0,1),Vector2i(1,0),Vector2i(1,-1)]:
				var key := hex_key(cell["q"]+d.x,cell["r"]+d.y)
				if tile_lookup.has(key) and cells[tile_lookup[key]]["kind"]=="river":
					ribbon(paths,c,center(cell["q"]+d.x,cell["r"]+d.y),10,Color("527f89").srgb_to_linear(),0.08)
					path_count += 1
		if cell["road"]:
			for d in [Vector2i(1,0),Vector2i(0,1)]:
				var key := hex_key(cell["q"]+d.x,cell["r"]+d.y)
				if tile_lookup.has(key) and cells[tile_lookup[key]]["road"]:
					ribbon(paths,c,center(cell["q"]+d.x,cell["r"]+d.y),2.4,Color("b7a37c").srgb_to_linear(),0.10)
					path_count += 1
	if path_count>0: add_mesh(land,paths.commit(),material)
	# Each existing crossing scene is contained in exactly one river hex.
	for coord in [Vector2i(0,1),Vector2i(0,-3),Vector2i(0,4)]:
		var index: int = tile_lookup.get(hex_key(coord.x,coord.y),-1)
		if index<0 or cells[index]["kind"]!="river": continue
		var key := "wooden_bridge" if coord.y==1 else ("stone_bridge" if coord.y==-3 else "shallow_ford")
		var raw := Lib.instance_grounded(key)
		var b: Dictionary = Lib.bounds(key)
		var size: Vector3 = b["max"]-b["min"]
		var wrap := Node3D.new()
		wrap.scale = Vector3.ONE*(24.0/maxf(size.x,size.z))
		wrap.add_child(raw)
		wrap.position = center(coord.x,coord.y)+Vector3.UP*0.1
		land.add_child(wrap)

func add_mesh(parent: Node3D,mesh: Mesh,mat: Material) -> void:
	var node := MeshInstance3D.new()
	node.mesh = mesh
	node.material_override = mat
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(node)

func ribbon(st: SurfaceTool,a: Vector3,b: Vector3,width: float,color: Color,y: float) -> void:
	var delta := (b-a).normalized()
	var perpendicular := Vector3(-delta.z,0,delta.x)*width*0.5
	for p in [a-perpendicular,b-perpendicular,a+perpendicular,a+perpendicular,b-perpendicular,b+perpendicular]:
		st.set_color(color)
		st.set_normal(Vector3.UP)
		st.add_vertex(p+Vector3.UP*y)

func template_for(key: String,lod: String) -> Mesh:
	var chosen_lod := "mid" if lod=="far" and not Lib.TREES.has(key) else lod
	return super.template_for(key,chosen_lod)

func height_at(_x: float,_z: float) -> float:
	return 0.0

func push_hex_history() -> void:
	hex_history.append({"cells":cells.duplicate(true),"seed":seed_value,"density":density,"meander":meander})
	if hex_history.size()>40: hex_history.pop_front()

func index_at(pos: Vector3) -> int:
	for i in range(cells.size()):
		var c := center(cells[i]["q"],cells[i]["r"])
		if inside(Vector2(pos.x-c.x,pos.z-c.z),1.0): return i
	return -1

func handle_hex_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.pressed and ui.get_global_rect().has_point(event.position): return
		if event.button_index==MOUSE_BUTTON_WHEEL_UP and event.pressed: camera.size = maxf(28,camera.size*0.86); update_camera()
		if event.button_index==MOUSE_BUTTON_WHEEL_DOWN and event.pressed: camera.size = minf(500,camera.size/0.86); update_camera()
		if event.button_index==MOUSE_BUTTON_RIGHT: rotating = event.pressed
		if event.button_index==MOUSE_BUTTON_LEFT:
			if event.pressed:
				chosen = index_at(map_point(event.position))
				dragging = chosen>=0
				if chosen>=0:
					var cell: Dictionary = cells[chosen]
					brush.select(TYPES.find(cell["kind"]))
					ring.visible = true
					ring.position = center(cell["q"],cell["r"])+Vector3.UP*0.2
					info.text = "Hex (%d,%d): %s\nPaint changes this hex only.\nDrag swaps whole sceneries." % [cell["q"],cell["r"],cell["kind"]]
			elif dragging:
				dragging = false
				var destination := index_at(map_point(event.position))
				if destination>=0 and destination!=chosen:
					push_hex_history()
					for field in ["kind","variant","rotation"]:
						var value: Variant = cells[chosen][field]
						cells[chosen][field] = cells[destination][field]
						cells[destination][field] = value
					chosen = destination
					recompose()
	if event is InputEventMouseMotion and rotating:
		yaw -= event.relative.x*0.006
		orbit = clampf(orbit+event.relative.y*0.004,0.35,1.42)
		update_camera()
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode==KEY_HOME: target = Vector3.ZERO; camera.size = 340; update_camera()
		if event.keycode==KEY_R and chosen>=0: push_hex_history(); cells[chosen]["rotation"] = (int(cells[chosen]["rotation"])+1)%6; recompose()
		if event.keycode==KEY_Z and event.ctrl_pressed and not hex_history.is_empty():
			var state: Dictionary = hex_history.pop_back()
			cells = state["cells"]
			seed_value = state["seed"]
			density = state["density"]
			meander = state["meander"]
			recompose()

func make_actors() -> void:
	for n in actors.get_children(): n.free()
	for i in range(7):
		var coord := Vector2i(-3+i,2)
		if not tile_lookup.has(hex_key(coord.x,coord.y)): continue
		var node: Node3D = Foot.new() if i<5 else Mount.new()
		actors.add_child(node)
		var key: String = ["infantry","spearman","archer","conscript","scout","cavalry","hq"][i]
		node.call("setup",key,"blue",3 if i<6 else 1,2.0,Vector3(0,0,1),seed_value+i)
		var points: Array = [Vector3(-2.0,0,0),Vector3.ZERO,Vector3(2,0,0)] if i<6 else [Vector3.ZERO]
		node.call("place",points)
		node.position = center(coord.x,coord.y)+Vector3(0,0.2,9)

func save_document() -> void:
	var f := FileAccess.open(out.path_join("edited-hex-map.json"),FileAccess.WRITE)
	f.store_string(JSON.stringify({"schema_version":2,"generator":"hex_scenery_v1","hex_radius":R,"seed":seed_value,"density":density,"meander":meander,"cells":cells},"\t"))
	info.text = "Saved edited-hex-map.json\nOne scenery record per axial hex."

func load_document() -> void:
	var path := out.path_join("edited-hex-map.json")
	if not FileAccess.file_exists(path): info.text = "No saved hex document yet."; return
	var value: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not value is Dictionary or value.get("schema_version",0)!=2 or not value.get("cells") is Array:
		info.text = "Unsupported hex document."; return
	var seen := {}
	for cell in value["cells"]:
		if not cell is Dictionary or not TYPES.has(cell.get("kind","")) or not cell.has_all(["q","r","variant","rotation"]): info.text = "Invalid hex entry."; return
		var key := hex_key(int(cell["q"]),int(cell["r"]))
		if seen.has(key) or abs(int(cell["q"]))>30 or abs(int(cell["r"]))>30: info.text = "Invalid / duplicate hex coordinate."; return
		seen[key] = true
	push_hex_history()
	cells = value["cells"]
	seed_value = int(value["seed"])
	density = clampf(float(value["density"]),0.1,1)
	meander = clampf(float(value["meander"]),5,50)
	tile_lookup.clear()
	for i in range(cells.size()): tile_lookup[hex_key(cells[i]["q"],cells[i]["r"])] = i
	terrain_noise.seed = seed_value
	moisture.seed = seed_value+974
	seed_input.value = seed_value
	density_input.value = density
	river_input.value = meander/50
	recompose()

func validate_scene() -> Dictionary:
	var violations := []
	var types := {}
	for cell in cells: types[cell["kind"]] = int(types.get(cell["kind"],0))+1
	for item in document:
		var coord: Array = item["cell"]
		var c := center(coord[0],coord[1])
		var b: Dictionary = Lib.bounds(item["key"])
		var size: Vector3 = b["max"]-b["min"]
		var half := Vector2(size.x,size.z)*float(item["width"])/maxf(size.x,size.z)*0.5
		for sx in [-1.0,1.0]:
			for sz in [-1.0,1.0]:
				var p := Vector2(half.x*sx,half.y*sz).rotated(-float(item["yaw"]))+Vector2(float(item["p"][0])-c.x,float(item["p"][2])-c.z)
				if not inside(p,0.961): violations.append(item["id"])
	var before := JSON.stringify(cells)
	var placement_before := JSON.stringify(document)
	save_document()
	load_document()
	var roundtrip: bool = before==JSON.stringify(cells) and placement_before==JSON.stringify(document)
	var duplicate_count := cells.size()-tile_lookup.size()
	return {"one_record_per_hex":duplicate_count==0,"scenery_types":types,"footprint_corner_violations":violations,"save_load_exact":roundtrip,"hexes":cells.size(),"props":document.size(),"scope":"Static footprint containment + exact DEV document round trip. No gameplay reachability assertions."}

func exercise_editor() -> Dictionary:
	ui.visible = false
	var original_cells := cells.duplicate(true)
	var index: int = tile_lookup[hex_key(1,2)]
	var point := camera.unproject_position(center(1,2))
	var down := InputEventMouseButton.new()
	down.position = point
	down.button_index = MOUSE_BUTTON_LEFT
	down.pressed = true
	Input.parse_input_event(down)
	await wait_frames(2)
	var up := InputEventMouseButton.new()
	up.position = point
	up.button_index = MOUSE_BUTTON_LEFT
	up.pressed = false
	Input.parse_input_event(up)
	await wait_frames(2)
	var clicked: bool = chosen==index
	brush.select(TYPES.find("forest"))
	var panel: VBoxContainer = info.get_parent()
	for node in panel.get_children():
		if node is Button and node.text=="PAINT SELECTED HEX": node.emit_signal("pressed")
	var painted: bool = cells[index]["kind"]=="forest"
	var isolated := true
	for i in range(cells.size()):
		if i!=index and cells[i]!=original_cells[i]: isolated = false
	var key := InputEventKey.new()
	key.keycode = KEY_R
	key.pressed = true
	Input.parse_input_event(key)
	await wait_frames(2)
	var rotated: bool = int(cells[index]["rotation"])==1
	var undo := InputEventKey.new()
	undo.keycode = KEY_Z
	undo.ctrl_pressed = true
	undo.pressed = true
	Input.parse_input_event(undo)
	await wait_frames(2)
	var undone: bool = int(cells[index]["rotation"])==0
	cells = original_cells
	chosen = -1
	ring.visible = false
	hex_history.clear()
	recompose()
	return {"input_relay_select":clicked,"paint_selected_hex":painted,"other_hexes_unchanged":isolated,"rotate_via_input":rotated,"undo_via_input":undone}

func capture_suite() -> void:
	camera.size = 340
	yaw = 0.12
	orbit = 0.95
	target = Vector3.ZERO
	update_camera()
	ui.visible = false
	var mode := "hex_optimized" if optimized else "hex_original"
	var result := await measure(mode)
	await save_picture(mode+"_overview")
	if optimized:
		structural_report = validate_scene()
		structural_report["input_checks"] = await exercise_editor()
		for pair in [["castle",Vector2i(3,1),76.0],["forest",Vector2i(3,0),95.0],["ridge",Vector2i(2,-4),105.0],["village",Vector2i(-3,1),95.0]]:
			target = center(pair[1].x,pair[1].y)
			camera.size = pair[2]
			update_camera()
			await wait_frames(12)
			await save_picture("hex_"+pair[0])
		ui.visible = true
		target = Vector3.ZERO
		camera.size = 340
		update_camera()
		await wait_frames(6)
		await save_picture("hex_editor")
	var f := FileAccess.open(out.path_join(mode+"-receipt.json"),FileAccess.WRITE)
	f.store_string(JSON.stringify({"performance":result,"seed":seed_value,"hexes":cells.size(),"props":document.size(),"used_prop_keys":cover_keys.keys(),"validation":structural_report,"design":"One hex = one scenery. Adjacency forms forest/ridge. No mission map loaded."},"\t"))
	print("[HexSceneryLab] COMPLETE ",mode)
	# Free static imported animal prototypes owned by this DEV process only.
	stage.free()
	templates.clear()
	if Foot._dog_proto!=null: Foot._dog_proto.free(); Foot._dog_proto = null
	if Mount._horse_proto!=null: Mount._horse_proto.free(); Mount._horse_proto = null
	await wait_frames(2)
	quit()
