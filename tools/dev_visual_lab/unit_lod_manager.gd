extends Node3D
## Coarse visibility/animation scheduling; one update per 0.15 s, not per unit/frame.
const Unit = preload("res://tools/dev_visual_lab/unit_lod_formation.gd")
var camera: Camera3D
var entries: Array = []
var forced_detail := -1
var clock := 0.0
var counts := [0,0,0,0]
const ENTER_MARGIN := 100.0
const EXIT_MARGIN := 180.0
const EXIT_DELAY_MS := 350

func _process(delta: float) -> void:
	clock += delta
	if clock<0.15: return
	clock = 0.0
	update_visibility()

func update_visibility() -> void:
	if camera==null: return
	counts = [0,0,0,0]
	var size := get_viewport().get_visible_rect().size
	var screen := Rect2(Vector2.ZERO,size)
	var now := Time.get_ticks_msec()
	for entry in entries:
		var unit: Node3D = entry["node"]
		var bounds := formation_screen_bounds(entry)
		var margin := EXIT_MARGIN if unit.visible else ENTER_MARGIN
		var visible := bounds.has_area() and screen.grow(margin).intersects(bounds,true)
		if visible:
			entry.erase("outside_since")
		else:
			if not entry.has("outside_since"): entry["outside_since"] = now
			# Brief pans and border jitter must not toggle a whole formation.
			visible = unit.visible and now-int(entry["outside_since"])<EXIT_DELAY_MS
		unit.visible = visible
		if not visible:
			unit.actor.process_mode = Node.PROCESS_MODE_DISABLED
			counts[3] += 1
			continue
		var pixels := float(entry["height"])*size.y/maxf(camera.size,0.01)
		var level := forced_detail if forced_detail>=0 else (2 if pixels<11.0 else (1 if pixels<27.0 else 0))
		unit.set_detail(level)
		# Re-entering the frustum must resume animation even if LOD did not change.
		unit.actor.process_mode = Node.PROCESS_MODE_DISABLED if level==2 else Node.PROCESS_MODE_INHERIT
		counts[level] += 1

func formation_local_bounds(entry: Dictionary) -> AABB:
	if entry.has("visibility_bounds"): return entry["visibility_bounds"]
	var unit: Node3D = entry["node"]
	var height: float = entry["height"]
	var mounted: bool = entry["kind"] in ["cavalry","hq"]
	var horizontal := height*(1.35 if mounted else 0.85)+5.0
	var vertical := height*(3.0 if mounted else 1.9)
	var bounds := AABB(Vector3(-horizontal,-1.0,-horizontal),Vector3(horizontal*2.0,vertical+1.0,horizontal*2.0))
	# Include every member's feet, body, raised weapons and visual sortie reach.
	for point in unit.points:
		bounds = bounds.merge(AABB(point+Vector3(-horizontal,-1.0,-horizontal),Vector3(horizontal*2.0,vertical+1.0,horizontal*2.0)))
	if unit.proxy!=null: bounds = bounds.merge(unit.proxy.get_aabb().grow(2.0))
	entry["visibility_bounds"] = bounds
	return bounds

func formation_screen_bounds(entry: Dictionary) -> Rect2:
	var unit: Node3D = entry["node"]
	var bounds := formation_local_bounds(entry)
	var projected := Rect2()
	var front_count := 0
	for i in range(8):
		var corner := unit.to_global(bounds.get_endpoint(i))
		if camera.is_position_behind(corner): continue
		var point := camera.unproject_position(corner)
		projected = Rect2(point,Vector2.ZERO) if front_count==0 else projected.expand(point)
		front_count += 1
	# A near-plane intersection is visible; projecting only its front corners
	# could otherwise produce an invalid or deceptively small screen rectangle.
	if front_count>0 and front_count<8: return get_viewport().get_visible_rect()
	return projected

func add_formation(kind: String,faction: String,count: int,height: float,position: Vector3,seed_value: int,coord: Vector2i) -> Node3D:
	var unit := Unit.new(); add_child(unit)
	unit.position = position
	unit.setup(kind,faction,count,height,Vector3(0,0,1),seed_value)
	unit.place(scatter_points(count,kind,seed_value))
	apply_facing_variation(unit,kind,seed_value)
	entries.append({"node":unit,"kind":kind,"faction":faction,"count":count,"height":height,"coord":coord,"seed":seed_value})
	return unit

func scatter_points(count: int,kind: String,seed_value: int) -> Array:
	var rng := RandomNumberGenerator.new(); rng.seed = seed_value+73193
	if count==1: return [Vector3(rng.randf_range(-1.2,1.2),0,rng.randf_range(-1.0,1.0))]
	var points: Array = []
	if kind=="cavalry":
		# Long horse bodies need lateral clearance; loosen the line into a wedge.
		for i in range(count):
			points.append(Vector3((float(i)-float(count-1)*0.5)*8.8+rng.randf_range(-0.55,0.55),0,[-2.0,2.8,-0.8][i%3]+rng.randf_range(-0.8,0.8)))
		return points
	# Seeded best-candidate sampling fills the inset hex without rows or clumps.
	# The first member anchors the interior; subsequent members occupy open space.
	points.append(Vector3(rng.randf_range(-2.2,2.2),0,rng.randf_range(-2.2,2.2)))
	while points.size()<count:
		var best := Vector3.ZERO
		var best_score := -INF
		for candidate_index in range(160):
			var candidate := Vector3(rng.randf_range(-13.0,13.0),0,rng.randf_range(-11.25,11.25))
			if sqrt(3.0)*absf(candidate.x)+absf(candidate.z)>sqrt(3.0)*13.0: continue
			var nearest := INF
			for placed in points: nearest = minf(nearest,candidate.distance_squared_to(placed))
			var score := nearest+rng.randf_range(-1.5,1.5)
			if score>best_score: best_score = score; best = candidate
		points.append(best)
	return points

func apply_facing_variation(unit: Node3D,kind: String,seed_value: int) -> void:
	var mounted := kind in ["cavalry","hq"]
	var members: Array = unit.actor.get("_mounts" if mounted else "_soldiers")
	var rng := RandomNumberGenerator.new(); rng.seed = seed_value+92831
	for member in members:
		if not member.has("scatter_base_yaw"): member["scatter_base_yaw"] = member["yaw_home"]
		var yaw := float(member["scatter_base_yaw"])+rng.randf_range(-0.085,0.085) if mounted else float(member["scatter_base_yaw"])+rng.randf_range(-0.22,0.22)
		member["yaw_home"] = yaw
		member["holder"].rotation.y = yaw

func scatter_existing() -> void:
	# Live layout update: rebuild frozen poses too, so zooming out keeps the layout.
	Unit.frozen_meshes.clear()
	for i in range(entries.size()):
		var entry: Dictionary = entries[i]
		entry.erase("visibility_bounds")
		entry.erase("outside_since")
		var unit: Node3D = entry["node"]
		var seed_value := int(entry.get("seed",20261019+i))
		unit.place(scatter_points(int(entry["count"]),str(entry["kind"]),seed_value))
		apply_facing_variation(unit,str(entry["kind"]),seed_value)
		if unit.proxy!=null: unit.proxy.free(); unit.proxy = null
		unit.prewarm_proxy()
	update_visibility()

func prewarm() -> void:
	for entry in entries: entry["node"].prewarm_proxy()
	Unit.release_source_prototypes()
	update_visibility()
