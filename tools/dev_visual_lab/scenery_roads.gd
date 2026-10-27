extends RefCounted
## Wide center-to-center hex roads. Does not modify terrain or movement data.
var world: Object
var graph := AStar2D.new()
var points: Array[Vector3] = []
var point_ids := {}
var borders := {}
var bridge_edges := {}
var network := {}
var sites: Array[int] = []
var approaches: Array = []
var lookup := {}
var cell_ids := {}
var road_corridors := {}
var junctions := {}
var report := {}
var tool := SurfaceTool.new()
var triangle_count := 0
const DIRECTIONS := [Vector2i(1,0),Vector2i(1,-1),Vector2i(0,-1),Vector2i(-1,0),Vector2i(-1,1),Vector2i(0,1)]

func edge_key(a: int,b: int) -> String:
	return "%d:%d" % [mini(a,b),maxi(a,b)]

func center_of(coord: Vector2i) -> Vector3:
	return world.call("center",coord.x,coord.y)

func point_id(p: Vector3) -> int:
	var key := Vector2i(roundi(p.x*1000.0),roundi(p.z*1000.0))
	if not point_ids.has(key):
		point_ids[key] = points.size()
		points.append(Vector3(p.x,0,p.z))
	return int(point_ids[key])

func add_site(id: int) -> void:
	if id>=0 and not sites.has(id): sites.append(id)

func closest_id(p: Vector3) -> int:
	return graph.get_closest_point(Vector2(p.x,p.z))

func make_graph(cells: Array) -> void:
	for cell in cells:
		var coord := Vector2i(cell["q"],cell["r"])
		lookup[coord] = cell["kind"]
		if cell["kind"] not in ["plain","forest"]: continue
		var c := center_of(coord)
		var id := point_id(c)
		cell_ids[coord] = id
		var weight := 1.0 if cell["kind"]=="plain" else 1.8
		if bool(cell.get("road",false)): weight *= 0.8
		graph.add_point(id,Vector2(c.x,c.z),weight)
	for coord in cell_ids:
		for direction in DIRECTIONS:
			var neighbor: Vector2i = coord+direction
			if cell_ids.has(neighbor): graph.connect_points(cell_ids[coord],cell_ids[neighbor],true)
	# River crossing is allowed only via the existing three crossing assets.
	for r in [1,-3,4]:
		var coord := Vector2i(0,r)
		if lookup.get(coord,"")!="river": continue
		var c := center_of(coord)
		var left := point_id(c+Vector3(-6.0,0,0))
		var right := point_id(c+Vector3(6.0,0,0))
		var left_land := closest_id(c+Vector3(-32,0,0))
		var right_land := closest_id(c+Vector3(32,0,0))
		for id in [left,right]: graph.add_point(id,Vector2(points[id].x,points[id].z))
		graph.connect_points(left,left_land,true)
		graph.connect_points(right,right_land,true)
		graph.connect_points(left,right,true)
		bridge_edges[edge_key(left,right)] = true
		add_site(left); add_site(right)

func collect_sites(cells: Array) -> void:
	var assemblies: Array = world.get("hex_assemblies")
	var villages := 0
	var forts := 0
	for assembly in assemblies:
		if assembly["kind"]!="village": continue
		var center: Vector3 = assembly["centroid"]
		var lod_root: Node3D = assembly["lod_nodes"][0]
		for node in lod_root.get_children():
			if not String(node.name).begins_with("building_gate_"): continue
			var gate: Vector3 = node.global_position
			gate.y = 0
			var outward := (gate-center).normalized()
			var land := closest_id(center+outward*32.0)
			var entrance := point_id(gate+outward*0.4)
			graph.add_point(entrance,Vector2(points[entrance].x,points[entrance].z))
			graph.connect_points(entrance,land,true)
			add_site(entrance)
			villages += 1
			break
	for cell in cells:
		if cell["kind"]!="castle": continue
		var center := center_of(Vector2i(cell["q"],cell["r"]))
		var angle := float(cell.get("rotation",0))*PI/3.0
		var outward := Vector3(sin(angle),0,cos(angle))
		var land := closest_id(center+outward*32.0)
		var entrance := point_id(center+outward*13.4)
		graph.add_point(entrance,Vector2(points[entrance].x,points[entrance].z))
		graph.connect_points(entrance,land,true)
		add_site(entrance)
		forts += 1
	# Farming districts connect through an adjacent road hex and a short entrance.
	var farms := {}
	for cell in cells:
		if cell["kind"]=="farm": farms[Vector2i(cell["q"],cell["r"])] = true
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
		while cursor<queue.size():
			var coord: Vector2i = queue[cursor]; cursor += 1
			var center := center_of(coord)
			for d in DIRECTIONS:
				var neighbor: Vector2i = coord+d
				if farms.has(neighbor) and not seen.has(neighbor): seen[neighbor] = true; queue.append(neighbor)
			for direction in DIRECTIONS:
				var neighbor: Vector2i = coord+direction
				if not cell_ids.has(neighbor): continue
				var id: int = cell_ids[neighbor]
				for site in sites:
					var distance := points[id].distance_squared_to(points[site])
					if distance<best_distance:
						best_distance = distance; best = id
						best_entry = center+(points[id]-center).normalized()*13.0
		add_site(best)
		if best>=0: approaches.append([points[best],best_entry])
		farm_groups += 1
	report["village_entrances"] = villages
	report["fort_approaches"] = forts
	report["farm_districts"] = farm_groups

func connect_sites() -> void:
	var reached := {sites[0]:true}
	var failures := 0
	while reached.size()<sites.size():
		var best_a := -1
		var best_b := -1
		var best := INF
		for a in reached:
			for b in sites:
				if reached.has(b): continue
				var distance := points[a].distance_squared_to(points[b])
				if distance<best: best = distance; best_a = a; best_b = b
		if best_b<0: break
		var path := graph.get_id_path(best_a,best_b)
		if path.is_empty(): failures += 1
		for i in range(path.size()-1):
			var a := int(path[i]); var b := int(path[i+1])
			var key := edge_key(a,b)
			if not bridge_edges.has(key): network[key] = [a,b]
		reached[best_b] = true
	report["route_failures"] = failures
	report["sites"] = sites.size()
	report["unique_land_segments"] = network.size()

func coord_at(p: Vector3) -> Vector2i:
	var q := p.x/27.0
	var r := p.z/(sqrt(3.0)*18.0)-q*0.5
	var y := -q-r
	var iq := roundi(q); var ir := roundi(r); var iy := roundi(y)
	var dq := absf(float(iq)-q); var dr := absf(float(ir)-r); var dy := absf(float(iy)-y)
	if dq>dr and dq>dy: iq = -iy-ir
	elif dr>dy: ir = -iq-iy
	return Vector2i(iq,ir)

func near_fields(p: Vector3) -> bool:
	var coord := coord_at(p)
	for d in [Vector2i.ZERO]+DIRECTIONS:
		var neighbor: Vector2i = coord+d
		if lookup.get(neighbor,"")=="farm" and center_of(neighbor).distance_squared_to(p)<625.0: return true
	return false

func curved_path(raw: Array) -> Array[Vector3]:
	var curved: Array[Vector3] = [raw[0]]
	for i in range(1,raw.size()-1):
		var c: Vector3 = raw[i]
		var previous: Vector3 = raw[i-1]
		var next: Vector3 = raw[i+1]
		var cut := minf(8.0,minf(c.distance_to(previous),c.distance_to(next))*0.3)
		var a := c+(previous-c).normalized()*cut
		var b := c+(next-c).normalized()*cut
		curved.append(a)
		for step in range(1,9):
			var t := float(step)/8.0
			curved.append(a.lerp(c,t).lerp(c.lerp(b,t),t))
	curved.append(raw[-1])
	var sampled: Array[Vector3] = [curved[0]]
	for i in range(curved.size()-1):
		var count := maxi(1,ceili(curved[i].distance_to(curved[i+1])/2.5))
		for step in range(1,count+1):
			var p := curved[i].lerp(curved[i+1],float(step)/float(count))
			if p.distance_squared_to(sampled[-1])>0.000001: sampled.append(p)
	return sampled

func dirt_at(p: Vector3) -> Color:
	return Color("b29b73").srgb_to_linear().lightened(sin(p.x*0.19+p.z*0.13)*0.025)

func rut_strength(p: Vector3) -> float:
	var strength := 1.0
	var coord := coord_at(p)
	for d in [Vector2i.ZERO]+DIRECTIONS:
		var neighbor: Vector2i = coord+d
		for junction in junctions.get(neighbor,[]):
			var c: Vector3 = junction["center"]
			strength = minf(strength,smoothstep(float(junction["trim"]),float(junction["trim"])+7.0,p.distance_to(c)))
	return strength

func emit_triangle(a: Vector3,b: Vector3,c: Vector3,ca: Color,cb: Color,cc: Color) -> void:
	var vertices := [a,b,c]
	var colors := [ca,cb,cc]
	# Godot's clockwise front face must face up on the XZ plane.
	if (b.x-a.x)*(c.z-a.z)-(b.z-a.z)*(c.x-a.x)<0.0:
		vertices = [a,c,b]; colors = [ca,cc,cb]
	for i in range(3):
		tool.set_normal(Vector3.UP)
		tool.set_color(colors[i])
		tool.add_vertex(vertices[i])
	triangle_count += 1

func add_ribbon(raw: Array) -> void:
	if raw.size()<2: return
	var path := curved_path(raw)
	for i in range(path.size()-1):
		var coord := coord_at(path[i])
		for direction in [Vector2i.ZERO]+DIRECTIONS:
			var key: Vector2i = coord+direction
			if not road_corridors.has(key): road_corridors[key] = []
			road_corridors[key].append([path[i],path[i+1]])
	var rows: Array = []
	var colors: Array = []
	for i in range(path.size()):
		var c := path[i]
		var tangent := (path[mini(i+1,path.size()-1)]-path[maxi(0,i-1)]).normalized()
		var across := Vector3(-tangent.z,0,tangent.x)
		var field := near_fields(c)
		var half_width := 3.2
		var cross_section: Array[Vector3] = []
		var cross_colors: Array[Color] = []
		var outer: Color = Color("9a8964").srgb_to_linear() if field else world.call("sample_natural_ground_color",c.x,c.z)
		var dirt := dirt_at(c)
		var wear := rut_strength(c)
		for band in range(9):
			var offset: float = [-half_width-0.55,-half_width,-1.9,-1.2,0.0,1.2,1.9,half_width,half_width+0.55][band]
			var p := c+across*offset
			p.y = 0.135
			cross_section.append(p)
			cross_colors.append(outer if band in [0,8] else (dirt.darkened(0.12*wear) if band in [2,6] else dirt))
		rows.append(cross_section); colors.append(cross_colors)
	for row in range(rows.size()-1):
		for band in range(8):
			for v in [[row,band],[row+1,band],[row,band+1],[row,band+1],[row+1,band],[row+1,band+1]]:
				tool.set_normal(Vector3.UP)
				tool.set_color(colors[v[0]][v[1]])
				tool.add_vertex(rows[v[0]][v[1]])
			triangle_count += 2

func trace_network() -> void:
	# Farm access is a branch of the same graph, not an overlapping extra strip.
	for approach in approaches:
		for i in range(approach.size()-1):
			var a := point_id(approach[i])
			var b := point_id(approach[i+1])
			network[edge_key(a,b)] = [a,b]
	var adjacency := {}
	for edge in network.values():
		for i in range(2):
			if not adjacency.has(edge[i]): adjacency[edge[i]] = []
			adjacency[edge[i]].append(edge[1-i])
	var ports := {}
	var junction_list: Array = []
	for id in adjacency:
		if adjacency[id].size()<3: continue
		var trim := 8.0
		for neighbor in adjacency[id]: trim = minf(trim,points[id].distance_to(points[neighbor])*0.38)
		var arms: Array = []
		for neighbor in adjacency[id]:
			var direction: Vector3 = (points[neighbor]-points[id]).normalized()
			ports["%d:%d" % [id,neighbor]] = points[id]+direction*trim
			arms.append({"direction":direction,"angle":atan2(direction.z,direction.x)})
		arms.sort_custom(func(a: Dictionary,b: Dictionary) -> bool: return float(a["angle"])<float(b["angle"]))
		var junction := {"center":points[id],"trim":trim,"arms":arms}
		junction_list.append(junction)
		var coord := coord_at(points[id])
		if not junctions.has(coord): junctions[coord] = []
		junctions[coord].append(junction)
	var visited := {}
	var starts: Array = []
	for id in adjacency:
		if adjacency[id].size()!=2: starts.append(id)
	for id in adjacency:
		if adjacency[id].size()==2: starts.append(id)
	for start in starts:
		for next_id in adjacency[start]:
			if visited.has(edge_key(start,next_id)): continue
			var chain: Array = [points[start]]
			var previous: int = start
			var current: int = next_id
			while true:
				visited[edge_key(previous,current)] = true
				chain.append(points[current])
				if adjacency[current].size()!=2: break
				var following: int = adjacency[current][0] if adjacency[current][0]!=previous else adjacency[current][1]
				if visited.has(edge_key(current,following)): break
				previous = current; current = following
			if ports.has("%d:%d" % [start,next_id]): chain[0] = ports["%d:%d" % [start,next_id]]
			if ports.has("%d:%d" % [current,previous]): chain[-1] = ports["%d:%d" % [current,previous]]
			add_ribbon(chain)
	for junction in junction_list: add_junction(junction)
	report["junctions"] = junction_list.size()
	report["junction_method"] = "Trimmed arms and triangulated continuous filleted boundaries; no overlapping discs; wheel tracks fade before junctions"

func junction_outline(junction: Dictionary,width: float) -> PackedVector2Array:
	var result := PackedVector2Array()
	var c3: Vector3 = junction["center"]
	var c := Vector2(c3.x,c3.z)
	var trim: float = junction["trim"]
	var arms: Array = junction["arms"]
	for i in range(arms.size()):
		var arm: Dictionary = arms[i]
		var next: Dictionary = arms[(i+1)%arms.size()]
		var direction3: Vector3 = arm["direction"]
		var next3: Vector3 = next["direction"]
		var d := Vector2(direction3.x,direction3.z)
		var e := Vector2(next3.x,next3.z)
		var n := Vector2(-d.y,d.x)
		var m := Vector2(-e.y,e.x)
		var start := c+d*trim+n*width
		var finish := c+e*trim-m*width
		result.append(c+d*trim-n*width)
		result.append(start)
		var gap := fposmod(float(next["angle"])-float(arm["angle"]),TAU)
		if gap>PI+0.001:
			result.append(c+n*width)
			for step in range(1,9):
				var angle := float(arm["angle"])+PI*0.5+(gap-PI)*float(step)/8.0
				result.append(c+Vector2(cos(angle),sin(angle))*width)
			result.append(finish)
		else:
			var determinant := d.cross(e)
			var control := (start+finish)*0.5
			if absf(determinant)>0.001:
				var offset := -m*width-n*width
				control = c+n*width+d*(offset.cross(e)/determinant)
			for step in range(1,9):
				var t := float(step)/8.0
				result.append(start.lerp(control,t).lerp(control.lerp(finish,t),t))
	return result

func add_junction(junction: Dictionary) -> void:
	# Junction interiors are road too: reserve the whole center for clearance.
	var center: Vector3 = junction["center"]
	var coord := coord_at(center)
	for arm in junction["arms"]:
		var direction: Vector3 = arm["direction"]
		var end := center+direction*float(junction["trim"])
		for d in [Vector2i.ZERO]+DIRECTIONS:
			var key: Vector2i = coord+d
			if not road_corridors.has(key): road_corridors[key] = []
			road_corridors[key].append([center,end])
	var inner := junction_outline(junction,3.2)
	var outer := junction_outline(junction,3.75)
	# Consecutive arm ports share endpoints; duplicate vertices can prevent
	# ear clipping, particularly at large world coordinates after float rounding.
	var clean_inner := PackedVector2Array()
	var clean_outer := PackedVector2Array()
	for i in range(inner.size()):
		if not clean_inner.is_empty() and inner[i].distance_squared_to(clean_inner[-1])<0.000001: continue
		clean_inner.append(inner[i]); clean_outer.append(outer[i])
	if clean_inner.size()>1 and clean_inner[0].distance_squared_to(clean_inner[-1])<0.000001:
		clean_inner.resize(clean_inner.size()-1); clean_outer.resize(clean_outer.size()-1)
	inner = clean_inner; outer = clean_outer
	var indices := Geometry2D.triangulate_polygon(inner)
	if indices.is_empty():
		push_error("[SceneryRoads] Junction triangulation failed at "+str(junction["center"]))
		return
	for i in range(0,indices.size(),3):
		var a := Vector3(inner[indices[i]].x,0.135,inner[indices[i]].y)
		var b := Vector3(inner[indices[i+1]].x,0.135,inner[indices[i+1]].y)
		var c := Vector3(inner[indices[i+2]].x,0.135,inner[indices[i+2]].y)
		emit_triangle(a,b,c,dirt_at(a),dirt_at(b),dirt_at(c))
	for i in range(inner.size()):
		var j := (i+1)%inner.size()
		var a := Vector3(inner[i].x,0.135,inner[i].y)
		var b := Vector3(inner[j].x,0.135,inner[j].y)
		var c := Vector3(outer[i].x,0.135,outer[i].y)
		var d := Vector3(outer[j].x,0.135,outer[j].y)
		var cc: Color = world.call("sample_natural_ground_color",c.x,c.z)
		var cd: Color = world.call("sample_natural_ground_color",d.x,d.z)
		emit_triangle(a,b,c,dirt_at(a),dirt_at(b),cc)
		emit_triangle(b,d,c,dirt_at(b),cd,cc)

func tree_clearance(p: Vector3,coord: Vector2i) -> float:
	var distance := INF
	for segment in road_corridors.get(coord,[]):
		var a: Vector3 = segment[0]
		var b: Vector3 = segment[1]
		var delta := b-a
		var t := clampf((p-a).dot(delta)/maxf(delta.length_squared(),0.001),0.0,1.0)
		distance = minf(distance,p.distance_to(a+delta*t))
	return distance

func move_roadside_trees(document: Array,tree_keys: Array) -> int:
	var moved := 0
	for item in document:
		if item.get("role","") not in ["plain","forest"] or not tree_keys.has(item["key"]): continue
		var p: Array = item["p"]
		var original := Vector3(float(p[0]),0,float(p[2]))
		var coord := coord_at(original)
		if not road_corridors.has(coord): continue
		var clearance := 3.75+float(item["width"])*0.45
		if tree_clearance(original,coord)>=clearance: continue
		var c := center_of(coord)
		var chosen := original
		var best := INF
		var radius := maxf(6.0,14.0-float(item["width"])*0.4)
		for i in range(72):
			var angle := float(i)*TAU/24.0
			var candidate := c+Vector3(cos(angle),0,sin(angle))*radius*(0.65+float(i/24)*0.175)
			if tree_clearance(candidate,coord)<clearance: continue
			var score := candidate.distance_squared_to(original)
			if score<best: chosen = candidate; best = score
		if not is_inf(best):
			item["p"] = [chosen.x,p[1],chosen.z]
			moved += 1
		elif item.get("role","")=="forest":
			# A multi-tree source clump may exceed the available roadside wedge.
			# Compact that clump rather than leaving trunks in the road surface.
			var most_space := 0.0
			for i in range(48):
				var angle := float(i)*TAU/48.0
				var candidate := c+Vector3(cos(angle),0,sin(angle))*11.5
				var space := tree_clearance(candidate,coord)
				if space>most_space: most_space = space; chosen = candidate
			if most_space>4.5:
				item["p"] = [chosen.x,p[1],chosen.z]
				item["width"] = minf(float(item["width"]),(most_space-3.9)/0.45)
				moved += 1
	return moved

func build(source: Object) -> Node3D:
	world = source
	var cells: Array = world.get("cells")
	make_graph(cells)
	collect_sites(cells)
	connect_sites()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	trace_network()
	tool.index()
	var material := StandardMaterial3D.new()
	material.vertex_color_use_as_albedo = true
	material.roughness = 1.0
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	var root := Node3D.new()
	root.name = "ConnectedSceneryRoads"
	var node := MeshInstance3D.new()
	node.name = "RoundedDirtRoadNetwork"
	node.mesh = tool.commit()
	node.material_override = material
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(node)
	report["triangles"] = triangle_count
	report["opaque_surfaces"] = 1
	report["new_collision_shapes"] = 0
	report["routing"] = "Hex-center routes across tile interiors; village gates, farm entrances and existing bridges; rounded quadratic corners"
	report["road_width"] = 6.4
	report["shoulder_width_each_side"] = 0.55
	print("[SceneryRoads] sites=",sites.size()," segments=",network.size()," triangles=",triangle_count," failures=",report["route_failures"])
	return root
