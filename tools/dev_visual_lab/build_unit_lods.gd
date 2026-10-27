extends SceneTree
## Offline native mesh derivatives; source GLBs, rigs and clips remain immutable.
const OUT := "C:/Users/User/Documents/Codex/2026-10-18/strategygame-godot-4-2-2-repo/outputs/unit-import-optimization"
const SOURCES := {
	"soldier":"res://assets/units/formation_v0/supplied_soldier.glb",
	"horse":"res://assets/units/cavalry_v0/horse_rigged.glb",
	"dog":"res://assets/units/scout_v0/dog_rigged.glb"
}
var manifest := {"engine":"Godot 4.2.2","method":"meshoptimizer 1.3.0 attribute-aware index simplification; compacted original streams retain UVs, normals, bone palette and weights; textures capped to 1024 with mipmaps","assets":{}}
var jobs: Array = []
var textures := {}

func _initialize() -> void:
	call_deferred("build")

func build() -> void:
	DirAccess.make_dir_recursive_absolute(OUT.path_join("meshes"))
	DirAccess.make_dir_recursive_absolute(OUT.path_join("toolchain/input"))
	DirAccess.make_dir_recursive_absolute(OUT.path_join("textures"))
	for key in SOURCES:
		var path: String = SOURCES[key]
		var model: Node3D
		if key=="soldier": model = (load(path) as PackedScene).instantiate()
		else:
			var doc := GLTFDocument.new(); var state := GLTFState.new()
			assert(doc.append_from_file(ProjectSettings.globalize_path(path),state)==OK)
			model = doc.generate_scene(state)
		var meshes := model.find_children("*","MeshInstance3D",true,false)
		assert(meshes.size()==1)
		var mi: MeshInstance3D = meshes[0]
		var source: Mesh = mi.mesh
		var source_triangles := 0
		for surface in range(source.get_surface_count()):
			var arrays := source.surface_get_arrays(surface)
			var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
			source_triangles += indices.size()/3
			if "--prepare" in OS.get_cmdline_user_args(): prepare(key,surface,arrays,mi.skin.get_bind_count())
		if "--prepare" in OS.get_cmdline_user_args(): model.free(); continue
		var row := {"source":path,"source_sha256":FileAccess.get_sha256(path),"source_triangles":source_triangles,"surfaces":source.get_surface_count(),"skin_bind_count":mi.skin.get_bind_count(),"lods":{}}
		for level in ["near","mid","far"]:
			var mesh := ArrayMesh.new()
			var triangles := 0; var vertices := 0
			for surface in range(source.get_surface_count()):
				var arrays: Array = source.surface_get_arrays(surface)
				var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
				if level!="near":
					indices = FileAccess.get_file_as_bytes(OUT.path_join("toolchain/input/%s-%d-%s.bin" % [key,surface,level])).to_int32_array()
					assert(indices.size()>0,"Run toolchain/simplify.mjs first")
				arrays = compact(arrays,indices)
				triangles += indices.size()/3
				vertices += arrays[Mesh.ARRAY_VERTEX].size()
				mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arrays)
				mesh.surface_set_material(surface,reduced_material(source.surface_get_material(surface),key,surface))
			var file := OUT.path_join("meshes/%s-%s.res" % [key,level])
			assert(ResourceSaver.save(mesh,file,ResourceSaver.FLAG_COMPRESS)==OK)
			row["lods"][level] = {"path":file,"triangles":triangles,"vertices":vertices,"bytes":FileAccess.get_file_as_bytes(file).size()}
		manifest["assets"][key] = row
		print("[UnitLOD] ",key," ",JSON.stringify(row))
		model.free()
	var file := FileAccess.open(OUT.path_join("toolchain/jobs.json" if "--prepare" in OS.get_cmdline_user_args() else "unit-import-manifest.json"),FileAccess.WRITE)
	file.store_string(JSON.stringify(jobs if "--prepare" in OS.get_cmdline_user_args() else manifest,"\t")); file.close()
	quit()

func prepare(key: String,surface: int,arrays: Array,bone_count: int) -> void:
	var stem := OUT.path_join("toolchain/input/%s-%d" % [key,surface])
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var uv: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	var bones: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
	var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var stride := 5+bone_count
	var influences: int = weights.size()/vertices.size()
	var attributes := PackedFloat32Array(); attributes.resize(vertices.size()*stride); attributes.fill(0.0)
	for i in range(vertices.size()):
		attributes[i*stride] = normals[i].x; attributes[i*stride+1] = normals[i].y; attributes[i*stride+2] = normals[i].z
		attributes[i*stride+3] = uv[i].x; attributes[i*stride+4] = uv[i].y
		for j in range(influences): attributes[i*stride+5+bones[i*influences+j]] += weights[i*influences+j]
	for item in [["pos",vertices.to_byte_array()],["attr",attributes.to_byte_array()],["index",indices.to_byte_array()]]:
		var file := FileAccess.open(stem+"-"+item[0]+".bin",FileAccess.WRITE); file.store_buffer(item[1]); file.close()
	jobs.append({"key":key,"surface":surface,"stem":stem,"stride":stride,"source_indices":indices.size()})

func reduced_material(source: Material,key: String,surface: int) -> Material:
	var result := source.duplicate() as BaseMaterial3D
	if result==null: return source
	var texture: Texture2D = result.albedo_texture
	if texture==null: return result
	var id := "%s-%d" % [key,surface]
	if not textures.has(id):
		var image := texture.get_image()
		var size := maxi(image.get_width(),image.get_height())
		if image.is_compressed(): image.decompress()
		if size>1024:
			var factor := 1024.0/float(size)
			image.resize(maxi(1,roundi(image.get_width()*factor)),maxi(1,roundi(image.get_height()*factor)),Image.INTERPOLATE_LANCZOS)
		image.generate_mipmaps()
		var reduced := ImageTexture.create_from_image(image)
		var file := OUT.path_join("textures/"+id+"-albedo.res")
		assert(ResourceSaver.save(reduced,file,ResourceSaver.FLAG_COMPRESS)==OK)
		reduced.take_over_path(file)
		textures[id] = reduced
	result.albedo_texture = textures[id]
	for property in result.get_property_list():
		var property_name: String = property["name"]
		if property_name!="albedo_texture" and result.get(property_name) is Texture2D: result.set(property_name,null)
	result.normal_enabled = false
	result.metallic = 0.0; result.roughness = 0.9
	return result

func compact(arrays: Array,indices: PackedInt32Array) -> Array:
	var source_vertices: int = arrays[Mesh.ARRAY_VERTEX].size()
	var used := PackedInt32Array()
	var remap := {}
	var mapped := PackedInt32Array(); mapped.resize(indices.size())
	for i in range(indices.size()):
		var old := indices[i]
		if not remap.has(old): remap[old] = used.size(); used.append(old)
		mapped[i] = remap[old]
	var result := arrays.duplicate()
	for slot in range(Mesh.ARRAY_MAX):
		if slot==Mesh.ARRAY_INDEX or arrays[slot]==null or arrays[slot].size()==0: continue
		var stride: int = arrays[slot].size()/source_vertices
		var values: Variant = arrays[slot].duplicate()
		values.resize(used.size()*stride)
		for i in range(used.size()):
			for j in range(stride): values[i*stride+j] = arrays[slot][used[i]*stride+j]
		result[slot] = values
	result[Mesh.ARRAY_INDEX] = mapped
	return result
