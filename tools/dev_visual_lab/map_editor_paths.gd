extends "res://tools/dev_visual_lab/river_shoreline.gd"
## Map editor river / road layer.
## Painted river and road hexes carry `links` (the directions the drag actually went), so the network follows
## the stroke instead of every touching hex. The network is split into chains (between ends and junctions);
## every river chain is drawn with the asset library's real river (river_shoreline: wide water strip,
## source rock banks, river-owned shore ground, reeds), every road chain as one smooth rounded dirt road.
const DIRS := [Vector2i(1,0), Vector2i(1,-1), Vector2i(0,-1), Vector2i(-1,0), Vector2i(-1,1), Vector2i(0,1)]
var forced_path: Array[Vector3] = []
var other_water: Array = []     # polylines of the other river chains (junctions)
const WIDTH_SCALE := 1.45       # the library river is sized for a wide map; in a hex map it should fill most of the hex


func half_width_at(distance: float) -> float:
	return super.half_width_at(distance) * WIDTH_SCALE


## No bank rock may sit on another chain's water (where a branch meets the main river).
func bank_instance_allowed(placement: Transform3D, mesh: Mesh) -> bool:
	var o := placement.origin
	for line in other_water:
		for i in range(line.size() - 1):
			var a: Vector3 = line[i]; var b: Vector3 = line[i + 1]
			var ab := b - a; ab.y = 0.0
			var t := clampf((o - a).dot(ab) / maxf(0.0001, ab.length_squared()), 0.0, 1.0)
			var q := a + ab * t
			if Vector2(o.x - q.x, o.z - q.z).length() < 13.0: return false
	return super.bank_instance_allowed(placement, mesh)


## Diagonal strokes zig-zag between hex centres; a few smoothing passes (ends fixed) give a natural course
## that still runs through the painted hexes.
static func smooth(pts: Array, passes: int = 3) -> Array:
	var out := pts.duplicate()
	for _p in range(passes):
		if out.size() < 3: break
		var nxt: Array = [out[0]]
		for i in range(1, out.size() - 1):
			nxt.append(out[i] * 0.5 + (out[i - 1] + out[i + 1]) * 0.25)
		nxt.append(out[-1])
		out = nxt
	return out


## river_shoreline orders a channel from its north-most to south-most hex; the editor hands it the chain in
## stroke order instead, so bends and U-turns keep every hex.
func ordered_trunk(cells: Array, _centres: Callable) -> Dictionary:
	return {"path": forced_path.duplicate(), "river_cells": cells.size(), "trunk_cells": forced_path.size(), "connected": true}


## nodes: {Vector2i: Array[int] link dirs}. Links to hexes that are not in `nodes` are ignored.
## Returns chains of cells; a junction hex ends one chain and starts the next, a closed loop comes back to its start.
static func chains(nodes: Dictionary) -> Array:
	var adj := {}
	for c in nodes.keys():
		var out: Array = []
		for d in nodes[c]:
			var n: Vector2i = c + DIRS[int(d)]
			if nodes.has(n) and not out.has(n): out.append(n)
		adj[c] = out
	for c in adj.keys():          # make links symmetric
		for n in adj[c]:
			if not adj[n].has(c): adj[n].append(c)
	var used := {}
	var result: Array = []
	var starts: Array = []
	for c in adj.keys():
		if adj[c].size() != 2: starts.append(c)
	starts.sort()
	for s in starts:
		if adj[s].is_empty(): result.append([s]); continue
		for n in adj[s]:
			if used.has(_ek(s, n)): continue
			result.append(_walk(adj, used, s, n))
	var rest: Array = adj.keys(); rest.sort()
	for s in rest:                # closed loops
		for n in adj[s]:
			if not used.has(_ek(s, n)): result.append(_walk(adj, used, s, n))
	return result


static func _walk(adj: Dictionary, used: Dictionary, s: Vector2i, n: Vector2i) -> Array:
	var chain: Array = [s]
	var prev := s; var cur := n
	used[_ek(s, n)] = true
	while true:
		chain.append(cur)
		if adj[cur].size() != 2 or cur == s: break
		var nxt: Vector2i = adj[cur][0] if adj[cur][0] != prev else adj[cur][1]
		if used.has(_ek(cur, nxt)): break
		used[_ek(cur, nxt)] = true
		prev = cur; cur = nxt
	return chain


static func _ek(a: Vector2i, b: Vector2i) -> String:
	return "%d,%d|%d,%d" % ([a.x, a.y, b.x, b.y] if (a.x < b.x or (a.x == b.x and a.y < b.y)) else [b.x, b.y, a.x, a.y])


## Real river for every chain. `centre` is the editor's center(q, r).
func build_rivers(nodes: Dictionary, centre: Callable, parent: Node3D) -> void:
	var all_chains := chains(nodes)
	var lines: Array = []
	for chain in all_chains:
		var raw: Array = []
		for c in chain: raw.append(centre.call(c.x, c.y))
		if raw.size() == 1: raw = [raw[0] + Vector3(-12, 0, 0), raw[0] + Vector3(12, 0, 0)]
		lines.append(smooth(raw))
	for ci in range(all_chains.size()):
		var chain: Array = all_chains[ci]
		var pts: Array[Vector3] = []
		for v in lines[ci]: pts.append(v)
		other_water = []
		for cj in range(lines.size()):
			if cj != ci: other_water.append(lines[cj])
		forced_path = pts
		bridge_points.clear(); bridge_stations.clear()
		var cells: Array = []
		for c in chain: cells.append({"q": c.x, "r": c.y, "kind": "river"})
		var holder := Node3D.new(); holder.name = "River"; parent.add_child(holder)
		create_channel(cells, centre, holder, false)


## One smooth rounded dirt road per chain (same corner rounding as the library's scenery roads).
const BRIDGE_GAP := 17.0      # road left empty this far either side of a crossing's centre (river + banks)
const BRIDGE_MODEL := "res://assets/map_composition_v0/source_glb/water/04-woodenbridge.glb"
const BRIDGE_PARTS := ["timber", "mortar", "soil", "masonry", "banner"]   # the bridge itself; its water, banks and plants are dropped
static var _bridge: Node3D


static func build_roads(nodes: Dictionary, centre: Callable, parent: Node3D, bridges: Dictionary) -> void:
	var dirt := SurfaceTool.new(); dirt.begin(Mesh.PRIMITIVE_TRIANGLES)
	var edge := SurfaceTool.new(); edge.begin(Mesh.PRIMITIVE_TRIANGLES)
	for chain in chains(nodes):
		var raw: Array = []
		for c in chain: raw.append(centre.call(c.x, c.y))
		if raw.size() == 1:
			_disc(dirt, raw[0], 3.2, 0.18); _disc(edge, raw[0], 4.1, 0.12); continue
		var pts := _rounded(smooth(raw, 2))
		# Crossings: the road stops at both banks and the library bridge, stretched to the gap, carries it over.
		var holes: Array = []
		for i in range(chain.size()):
			if not bridges.has(chain[i]): continue
			var c: Vector3 = raw[i]
			var a: Vector3 = raw[i - 1] if i > 0 else c - (raw[i + 1] - c)
			var b: Vector3 = raw[i + 1] if i < raw.size() - 1 else c + (c - a)
			holes.append(c)
			_place_bridge(parent, c, (b - a).normalized(), BRIDGE_GAP * 2.0 + 4.0)
		var run: Array = []
		for p in pts:
			var wet := false
			for h in holes:
				if Vector2(p.x - h.x, p.z - h.z).length() < BRIDGE_GAP: wet = true
			if wet:
				if run.size() >= 2: _ribbon(edge, run, 4.1, 0.12); _ribbon(dirt, run, 3.2, 0.18)
				run = []
			else:
				run.append(p)
		if run.size() >= 2: _ribbon(edge, run, 4.1, 0.12); _ribbon(dirt, run, 3.2, 0.18)
	for pair in [[edge, Color("6d5a3c")], [dirt, Color("a38a5c")]]:
		var mi := MeshInstance3D.new(); mi.mesh = (pair[0] as SurfaceTool).commit()
		var mat := StandardMaterial3D.new(); mat.albedo_color = pair[1]; mat.roughness = 1.0; mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		mi.material_override = mat; mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		parent.add_child(mi)


## The wooden bridge from the asset library, its own water / banks / plants removed, turned along the road and
## scaled so its deck spans `length` (bank to bank), standing on the ground.
static func _place_bridge(parent: Node3D, at: Vector3, dir: Vector3, length: float) -> void:
	if _bridge == null:
		var doc := GLTFDocument.new(); var st := GLTFState.new()
		if doc.append_from_file(ProjectSettings.globalize_path(BRIDGE_MODEL), st) != OK: return
		_bridge = doc.generate_scene(st) as Node3D
		for mi in _bridge.find_children("*", "MeshInstance3D", true, false):
			var keep := false
			for part in BRIDGE_PARTS:
				if String(mi.name).to_lower().ends_with("_" + part): keep = true
			if not keep: mi.free()
	var b := {"min": Vector3.INF, "max": -Vector3.INF}
	_span(_bridge, Transform3D.IDENTITY, b, _bridge)
	if b.min == Vector3.INF: return
	var deck_len: float = b.max.x - b.min.x
	var sc := length / maxf(0.001, deck_len)
	var copy := _bridge.duplicate() as Node3D
	var holder := Node3D.new(); holder.name = "Bridge"; parent.add_child(holder)
	holder.position = Vector3(at.x, 0.0, at.z)
	holder.rotation.y = atan2(-dir.z, dir.x)        # model deck runs along +x
	holder.add_child(copy)
	copy.scale = Vector3.ONE * sc
	copy.position = Vector3(-(b.min.x + b.max.x) * 0.5 * sc, -b.min.y * sc, -(b.min.z + b.max.z) * 0.5 * sc)


static func _span(n: Node, xf: Transform3D, b: Dictionary, root: Node) -> void:
	var t := xf
	if n is Node3D and n != root: t = xf * (n as Node3D).transform
	if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
		var box: AABB = (n as MeshInstance3D).mesh.get_aabb()
		for i in range(8):
			var p := t * box.get_endpoint(i)
			b.min = Vector3(minf(b.min.x,p.x),minf(b.min.y,p.y),minf(b.min.z,p.z)); b.max = Vector3(maxf(b.max.x,p.x),maxf(b.max.y,p.y),maxf(b.max.z,p.z))
	for c in n.get_children(): _span(c, t, b, root)


static func _rounded(raw: Array) -> Array:
	var curved: Array = [raw[0]]
	for i in range(1, raw.size() - 1):
		var c: Vector3 = raw[i]; var p: Vector3 = raw[i - 1]; var n: Vector3 = raw[i + 1]
		var cut := minf(14.0, minf(c.distance_to(p), c.distance_to(n)) * 0.45)
		var a := c + (p - c).normalized() * cut; var b := c + (n - c).normalized() * cut
		curved.append(a)
		for step in range(1, 9):
			var t := float(step) / 8.0
			curved.append(a.lerp(c, t).lerp(c.lerp(b, t), t))
	curved.append(raw[-1])
	var out: Array = [curved[0]]
	for i in range(curved.size() - 1):
		var count := maxi(1, ceili(curved[i].distance_to(curved[i + 1]) / 2.0))
		for step in range(1, count + 1):
			var q: Vector3 = curved[i].lerp(curved[i + 1], float(step) / float(count))
			if q.distance_squared_to(out[-1]) > 0.0001: out.append(q)
	return out


static func _ribbon(st: SurfaceTool, pts: Array, half: float, y: float) -> void:
	var sides: Array = []
	for i in range(pts.size()):
		var a: Vector3 = pts[maxi(0, i - 1)]; var b: Vector3 = pts[mini(pts.size() - 1, i + 1)]
		var d := b - a; d.y = 0.0
		sides.append(Vector3(-d.z, 0, d.x).normalized() * half if d.length() > 0.0001 else Vector3.RIGHT * half)
	var up := Vector3.UP * y
	for i in range(pts.size() - 1):
		_tri(st, pts[i] - sides[i] + up, pts[i + 1] - sides[i + 1] + up, pts[i + 1] + sides[i + 1] + up)
		_tri(st, pts[i] - sides[i] + up, pts[i + 1] + sides[i + 1] + up, pts[i] + sides[i] + up)
	_disc(st, pts[0], half, y); _disc(st, pts[-1], half, y)


static func _disc(st: SurfaceTool, at: Vector3, r: float, y: float) -> void:
	var up := Vector3.UP * y
	for i in range(16):
		var a0 := TAU * float(i) / 16.0; var a1 := TAU * float(i + 1) / 16.0
		_tri(st, at + up, at + Vector3(cos(a1), 0, sin(a1)) * r + up, at + Vector3(cos(a0), 0, sin(a0)) * r + up)


static func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3) -> void:
	if (b - a).cross(c - a).y > 0.0:
		var t := b; b = c; c = t
	for v in [a, b, c]:
		st.set_normal(Vector3.UP); st.add_vertex(v)
