extends Node3D
## Visual adapter only: full animated near, skinned LOD at 15 Hz mid,
## one shared frozen mesh per formation variant far. No gameplay dependencies.
const Foot = preload("res://scripts/visual/civ3d/civ_formation3d.gd")
const Mount = preload("res://scripts/visual/civ3d/civ_cavalry3d.gd")
const OUT := "C:/Users/User/Documents/Codex/2026-10-18/strategygame-godot-4-2-2-repo/outputs/unit-import-optimization"
static var meshes := {}
static var materials := {}
static var frozen_meshes := {}
static var image_cache := {}
static var far_material: StandardMaterial3D
var actor: Node3D
var proxy: MeshInstance3D
var parts: Array = []
var detail := -1
var class_key := ""
var faction_key := ""
var figure_count := 0
var figure_height := 0.0
var variant := 0
var points: Array = []

func setup(kind: String,faction: String,count: int,height: float,facing: Vector3,seed_value: int) -> void:
	class_key = kind; faction_key = faction; figure_count = count; figure_height = height; variant = posmod(seed_value,3)
	actor = Mount.new() if kind in ["cavalry","hq"] else Foot.new()
	add_child(actor)
	actor.call("setup",kind,faction,count,height,facing,seed_value)
	for node in actor.find_children("*","MeshInstance3D",true,false):
		if node.skin==null: continue
		var triangles := 0
		for surface in range(node.mesh.get_surface_count()): triangles += node.mesh.surface_get_arrays(surface)[Mesh.ARRAY_INDEX].size()/3
		var asset := "soldier" if triangles==13316 else ("horse" if triangles==24480 else "dog")
		assert(triangles in [13316,24480,10450],"Unknown unit mesh; add it to the manifest")
		for level in ["near","mid","far"]:
			var key: String = asset+"-"+level
			if not meshes.has(key): meshes[key] = load(OUT.path_join("meshes/"+key+".res"))
		parts.append({"node":node,"asset":asset})
		for surface in range(node.mesh.get_surface_count()):
			var old: Material = node.get_active_material(surface)
			if not old is ShaderMaterial: continue
			var key := "%s:%s:%d" % [asset,old.get_instance_id(),surface]
			if not materials.has(key):
				var mat: ShaderMaterial = old.duplicate()
				var reduced: BaseMaterial3D = meshes[asset+"-near"].surface_get_material(surface)
				mat.set_shader_parameter("albedo_tex",reduced.albedo_texture)
				materials[key] = mat
			if node.material_override!=null: node.material_override = materials[key]
			else: node.set_surface_override_material(surface,materials[key])
	set_detail(0)

func place(formation: Array) -> void:
	points = formation.duplicate()
	actor.call("place",formation)

func set_detail(level: int) -> void:
	if level==detail: return
	detail = level
	if level>=2:
		if proxy==null: make_proxy()
		actor.call("set_far",true)
		actor.process_mode = Node.PROCESS_MODE_DISABLED
		actor.visible = false
		proxy.visible = true
	else:
		if proxy!=null: proxy.visible = false
		actor.process_mode = Node.PROCESS_MODE_INHERIT
		actor.visible = true
		actor.call("set_far",false)
		actor.call("set_rate",15.0 if level==1 else 0.0)
		for part in parts:
			var mi: MeshInstance3D = part["node"]
			mi.mesh = meshes[part["asset"]+("-near" if level==0 else "-mid")]
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

func make_proxy() -> void:
	for part in parts: part["node"].mesh = meshes[part["asset"]+"-far"]
	var key := "%s:%s:%d:%.3f:%d:%s" % [class_key,faction_key,figure_count,figure_height,variant,str(points)]
	if not frozen_meshes.has(key): frozen_meshes[key] = bake_pose()
	proxy = MeshInstance3D.new(); proxy.name = "FrozenFormation"
	proxy.mesh = frozen_meshes[key]
	if far_material==null:
		far_material = StandardMaterial3D.new()
		far_material.vertex_color_use_as_albedo = true
		far_material.roughness = 0.95
	proxy.material_override = far_material
	proxy.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(proxy)

func prewarm_proxy() -> void:
	if proxy!=null: return
	var previous := detail
	make_proxy()
	proxy.visible = false
	detail = -1
	set_detail(previous)

static func clear_caches() -> void:
	frozen_meshes.clear(); meshes.clear(); materials.clear(); image_cache.clear(); far_material = null
	release_source_prototypes()

static func release_source_prototypes() -> void:
	# Every current instance now references derived meshes and shared small textures.
	# Drop unused GLTF prototypes/material caches instead of retaining source 4K maps.
	if Foot._dog_proto!=null: Foot._dog_proto.free(); Foot._dog_proto = null
	if Mount._horse_proto!=null: Mount._horse_proto.free(); Mount._horse_proto = null
	Foot._mats.clear(); Mount._mats.clear()

func bake_pose() -> ArrayMesh:
	var tool := SurfaceTool.new(); tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	var to_local := global_transform.affine_inverse()
	for mi in actor.find_children("*","MeshInstance3D",true,false):
		var mesh: Mesh = mi.mesh
		var sk: Skeleton3D = mi.get_node_or_null(mi.skeleton) if mi.skin!=null else null
		var matrices: Array[Transform3D] = []
		if sk!=null:
			for bind in range(mi.skin.get_bind_count()):
				var bone: int = sk.find_bone(mi.skin.get_bind_name(bind))
				if bone<0: bone = mi.skin.get_bind_bone(bind)
				assert(bone>=0)
				matrices.append(to_local*sk.global_transform*sk.get_bone_global_pose(bone)*mi.skin.get_bind_pose(bind))
		var rigid: Transform3D = to_local*mi.global_transform
		for surface in range(mesh.get_surface_count()):
			var arrays := mesh.surface_get_arrays(surface)
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
			var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV] if arrays[Mesh.ARRAY_TEX_UV]!=null else PackedVector2Array()
			var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX]!=null else PackedInt32Array()
			if indices.is_empty():
				for i in range(vertices.size()): indices.append(i)
			var colors := PackedColorArray(); colors.resize(vertices.size())
			var mat: Material = mi.get_active_material(surface)
			var source_colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR] if arrays[Mesh.ARRAY_COLOR]!=null else PackedColorArray()
			var bones: PackedInt32Array = arrays[Mesh.ARRAY_BONES] if sk!=null else PackedInt32Array()
			var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS] if sk!=null else PackedFloat32Array()
			var stride: int = weights.size()/maxi(1,vertices.size())
			for i in range(vertices.size()):
				var p := vertices[i]; var n := normals[i]
				if sk!=null:
					var posed := Vector3.ZERO; var normal := Vector3.ZERO
					for j in range(stride):
						var weight := weights[i*stride+j]
						if weight<=0.0: continue
						var transform := matrices[bones[i*stride+j]]
						posed += (transform*p)*weight
						normal += (transform.basis*n)*weight
					vertices[i] = posed; normals[i] = normal.normalized()
				else:
					vertices[i] = rigid*p; normals[i] = (rigid.basis*n).normalized()
				colors[i] = vertex_color(mi,mat,uvs[i] if not uvs.is_empty() else Vector2.ZERO)
				if not source_colors.is_empty() and mat is BaseMaterial3D and mat.vertex_color_use_as_albedo:
					colors[i] *= source_colors[i].srgb_to_linear() if mat.vertex_color_is_srgb else source_colors[i]
			for index in indices:
				tool.set_normal(normals[index]); tool.set_color(colors[index]); tool.add_vertex(vertices[index])
	tool.index()
	return tool.commit()

func vertex_color(mi: MeshInstance3D,mat: Material,uv: Vector2) -> Color:
	var texture: Texture2D
	var hue := 0.0; var drab := 0.0
	var color := Color.WHITE
	if mat is ShaderMaterial:
		texture = mat.get_shader_parameter("albedo_tex")
		hue = float(mat.get_shader_parameter("faction_hue")); drab = float(mat.get_shader_parameter("drab"))
	elif mat is BaseMaterial3D:
		texture = mat.albedo_texture; color = mat.albedo_color
	if texture!=null:
		var key := texture.get_instance_id()
		if not image_cache.has(key):
			var image := texture.get_image()
			if image.is_compressed(): image.decompress()
			image_cache[key] = image
		var image: Image = image_cache[key]
		var x := clampi(int(fposmod(uv.x,1.0)*image.get_width()),0,image.get_width()-1)
		var y := clampi(int(fposmod(uv.y,1.0)*image.get_height()),0,image.get_height()-1)
		color *= image.get_pixel(x,y).srgb_to_linear()
	if mat is ShaderMaterial:
		var cloth := color.s>0.38 and (color.h<0.035 or color.h>0.94)
		var skin := not cloth and color.h>0.03 and color.h<0.11 and color.s>0.2 and color.s<0.6 and color.v>0.45
		var h := color.h; var s := color.s; var v := color.v
		if cloth:
			if hue>0.0: h = hue; s *= 0.85; v *= 0.95
			var cloth_v: Variant = mi.get_instance_shader_parameter("cloth_v")
			v *= float(cloth_v) if cloth_v!=null else 1.0
		elif skin:
			var skin_v: Variant = mi.get_instance_shader_parameter("skin_v")
			v *= float(skin_v) if skin_v!=null else 1.0
		if not skin: s *= 1.0-0.55*drab; v *= 1.0-0.12*drab
		color = Color.from_hsv(clampf(h,0,1),clampf(s,0,1),clampf(v,0,1))
	return color

func play_attack() -> void:
	if detail>=2: set_detail(1)
	actor.call("play_attack")

func set_moving(moving: bool) -> void:
	if moving and detail>=2: set_detail(1)
	actor.call("set_moving",moving)

func set_speed(speed: float) -> void:
	actor.call("set_speed",speed)
