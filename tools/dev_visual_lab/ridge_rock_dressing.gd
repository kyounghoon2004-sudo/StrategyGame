extends RefCounted
## Repositions the existing rocky-ground tile's standalone rock meshes.
const SOURCE := "res://assets/map_composition_v0/source_glb/tiles/04-rocky-ground.glb"
const SOURCE_MESH_IDS := [1,4,6,7]
var variants: Array[Mesh] = []
var terrain_faces: Array = []
var placements: Array = []

func load_variants() -> void:
	var document := GLTFDocument.new()
	var state := GLTFState.new()
	assert(document.append_from_file(ProjectSettings.globalize_path(SOURCE),state)==OK)
	var meshes: Array = state.get_meshes()
	for mesh_id in SOURCE_MESH_IDS:
		var mesh: Mesh = meshes[mesh_id].get_mesh().get_mesh()
		assert(mesh.get_surface_count()==1)
		variants.append(mesh)

func faces_for(model: Node3D) -> Array:
	var faces: Array = []
	for item in model.find_children("*","MeshInstance3D",true,false):
		var instance: MeshInstance3D = item
		for surface in range(instance.mesh.get_surface_count()):
			var arrays := instance.mesh.surface_get_arrays(surface)
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
			var count: int = indices.size() if not indices.is_empty() else vertices.size()
			for i in range(0,count,3):
				var a := instance.global_transform*vertices[indices[i] if not indices.is_empty() else i]
				var b := instance.global_transform*vertices[indices[i+1] if not indices.is_empty() else i+1]
				var c := instance.global_transform*vertices[indices[i+2] if not indices.is_empty() else i+2]
				var den := (b.z-c.z)*(a.x-c.x)+(c.x-b.x)*(a.z-c.z)
				if absf(den)<0.000001: continue
				var normal := (b-a).cross(c-a).normalized()
				if normal.y<0: normal = -normal
				faces.append([a,b,c,den,normal,minf(a.x,minf(b.x,c.x)),maxf(a.x,maxf(b.x,c.x)),minf(a.z,minf(b.z,c.z)),maxf(a.z,maxf(b.z,c.z))])
	return faces

func surface_at(point: Vector2,faces: Array) -> Dictionary:
	for f in faces:
		if point.x<f[5]-0.0001 or point.x>f[6]+0.0001 or point.y<f[7]-0.0001 or point.y>f[8]+0.0001: continue
		var a: Vector3 = f[0]
		var b: Vector3 = f[1]
		var c: Vector3 = f[2]
		var u: float = ((b.z-c.z)*(point.x-c.x)+(c.x-b.x)*(point.y-c.z))/f[3]
		var v: float = ((c.z-a.z)*(point.x-c.x)+(a.x-c.x)*(point.y-c.z))/f[3]
		var w: float = 1.0-u-v
		if minf(u,minf(v,w))>=-0.0001: return {"height":u*a.y+v*b.y+w*c.y,"normal":f[4]}
	return {}

func plan_dressing(model: Node3D,centres: Array) -> void:
	terrain_faces = faces_for(model)
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261019
	for centre in centres:
		var candidates: Array = []
		var local_max := 0.0
		for x in [-9.0,-4.5,0.0,4.5,9.0]:
			for z in [-8.0,-4.0,0.0,4.0,8.0]:
				var point := Vector2(centre.x+x,centre.z+z)
				var hit := surface_at(point,terrain_faces)
				if hit.is_empty(): continue
				local_max = maxf(local_max,float(hit["height"]))
				if float(hit["height"])<1.2: continue
				var normal: Vector3 = hit["normal"]
				if normal.y<0.52: continue
				candidates.append({"point":point,"height":float(hit["height"]),"score":(1.0-normal.y)*7.0+rng.randf()*0.8})
		candidates.sort_custom(func(a,b): return a["score"]>b["score"])
		var selected: Array = []
		for candidate in candidates:
			if float(candidate["height"])>local_max*0.63: continue
			var point: Vector2 = candidate["point"]
			var nearby := false
			for old in selected:
				if point.distance_to(old)<6.5: nearby = true
			if nearby: continue
			selected.append(point)
			for n in range(3):
				var offset := Vector2.ZERO if n==0 else Vector2(1.65 if n==1 else -1.1,0.8 if n==1 else -1.3).rotated(rng.randf_range(-0.5,0.5))
				var p := point+offset
				# Keep every entire rock well inside its owner's hex.
				var local := p-Vector2(centre.x,centre.z)
				if absf(local.y)>11.0 or sqrt(3.0)*absf(local.x)+absf(local.y)>sqrt(3.0)*13.8: continue
				if surface_at(p,terrain_faces).is_empty(): continue
				placements.append({"xz":p,"variant":rng.randi()%variants.size(),"width":rng.randf_range(2.8,4.0) if n==0 else rng.randf_range(1.4,2.5),"height_scale":rng.randf_range(1.1,1.6),"yaw":rng.randf_range(0,TAU)})
			if selected.size()==3: break

func dress(model: Node3D,lod: int) -> Dictionary:
	var faces := terrain_faces if lod==0 else faces_for(model)
	var groups: Array = [[],[],[],[]]
	var triangle_count := 0
	for placement in placements:
		var hit := surface_at(placement["xz"],faces)
		if hit.is_empty(): continue
		var mesh: Mesh = variants[placement["variant"]]
		var box := mesh.get_aabb()
		var k: float = float(placement["width"])/maxf(box.size.x,box.size.z)
		var normal: Vector3 = hit["normal"]
		var tilt := Quaternion(Vector3.UP,normal)
		var limited := Quaternion.IDENTITY.slerp(tilt,0.60)
		var basis := Basis(limited)*Basis(Vector3.UP,float(placement["yaw"]))
		basis = basis*Basis.from_scale(Vector3(k,k*placement["height_scale"],k))
		var p: Vector2 = placement["xz"]
		var seat := Vector3(p.x,float(hit["height"])-box.size.y*k*0.60,p.y)
		var pivot := Vector3(box.get_center().x,box.position.y,box.get_center().z)
		var world := Transform3D(basis,seat-basis*pivot)
		groups[placement["variant"]].append(model.global_transform.affine_inverse()*world)
		var arrays := mesh.surface_get_arrays(0)
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		triangle_count += (indices.size() if not indices.is_empty() else arrays[Mesh.ARRAY_VERTEX].size())/3
	for i in range(groups.size()):
		if groups[i].is_empty(): continue
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = variants[i]
		mm.instance_count = groups[i].size()
		for n in range(mm.instance_count): mm.set_instance_transform(n,groups[i][n])
		var node := MultiMeshInstance3D.new()
		node.name = "ExistingRockVariant_%d" % SOURCE_MESH_IDS[i]
		node.multimesh = mm
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		model.add_child(node)
	return {"lod":lod,"instances":placements.size(),"triangles":triangle_count,"batches":groups.size(),"source":SOURCE,"source_mesh_ids":SOURCE_MESH_IDS,"seating":"Barycentric sample on each actual LOD surface, shallow burial; reused source geometry/materials"}
