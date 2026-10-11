extends SceneTree
const OUT := "res://assets/units/sword_charge_v0/"
const BONE_NAMES := ["joint_12","joint_13","joint_10","joint_9","joint_11","joint_4","joint_2","joint_1","joint_18","joint_21","joint_22","joint_7","joint_6","joint_5","joint_17","joint_16","joint_19"]
var mesh: ArrayMesh
var tri_count := 0

func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	build_sword()
	build_clips()
	quit()

func mat(color: Color, metal: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color; m.metallic = metal; m.roughness = .35 if metal > 0 else .8
	return m

func surface(vertices: Array, material: Material) -> void:
	var st := SurfaceTool.new();st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for v in vertices: st.add_vertex(v)
	st.generate_normals();st.set_material(material);st.commit(mesh)
	tri_count += vertices.size()/3

func box(center: Vector3, size: Vector3) -> Array:
	var v: Array = []
	for x in [-1,1]:
		for y in [-1,1]:
			for z in [-1,1]:v.append(center+Vector3(x,y,z)*size*.5)
	var result: Array = []
	for ids in [[0,1,3,2],[4,6,7,5],[0,4,5,1],[2,3,7,6],[0,2,6,4],[1,5,7,3]]:
		for i in [0,1,2,0,2,3]:result.append(v[ids[i]])
	return result

func build_sword() -> void:
	mesh = ArrayMesh.new();mesh.resource_name = "StraightSword_V0"
	# Grip centre is the origin; +Y is the blade axis. Metres, ready for reuse.
	var rings: Array = []
	for y in [.10,.77]:rings.append([Vector3(-.035,y,0),Vector3(0,y,-.010),Vector3(.035,y,0),Vector3(0,y,.010)])
	var blade: Array = []
	for i in range(4):
		var n := (i+1)%4
		blade.append_array([rings[0][i],rings[1][i],rings[1][n],rings[0][i],rings[1][n],rings[0][n]])
		blade.append_array([rings[1][i],Vector3(0,.91,0),rings[1][n]])
	surface(blade,mat(Color(.76,.81,.85),.85))
	surface(box(Vector3(0,.078,0),Vector3(.205,.035,.040))+box(Vector3(0,-.092,0),Vector3(.057,.034,.040)),mat(Color(.24,.26,.28),.7))
	surface(box(Vector3(0,-.008,0),Vector3(.036,.135,.034)),mat(Color(.15,.085,.04),0))
	assert(ResourceSaver.save(mesh,OUT+"straight_sword_mesh.tres") == OK)
	var root := Node3D.new();root.name = "StraightSword"
	var blade_mesh := MeshInstance3D.new();blade_mesh.name = "SwordMesh";blade_mesh.mesh = mesh
	root.add_child(blade_mesh);blade_mesh.owner = root
	var packed := PackedScene.new();packed.pack(root)
	assert(ResourceSaver.save(packed,OUT+"straight_sword.tscn") == OK)
	root.free()
	print("SWORD_TRIANGLES ",tri_count)

func skeleton_in(node: Node) -> Skeleton3D:
	if node is Skeleton3D:return node
	for c in node.get_children():
		var found := skeleton_in(c)
		if found:return found
	return null

func pose(values: Dictionary = {}) -> Dictionary:
	var p := {}
	for bone in BONE_NAMES:p[bone] = Vector3.ZERO
	# Ready guard: dominant hand stays outside the torso; sword points up/forward.
	p.joint_4 = Vector3(15,0,-5);p.joint_2 = Vector3(22,0,0);p.joint_1 = Vector3(15,0,0)
	p.joint_18 = Vector3(12,0,8);p.joint_21 = Vector3(22,0,0)
	for bone in values:p[bone] = values[bone]
	return p

func build_clips() -> void:
	var model = load("res://assets/units/formation_v0/supplied_soldier.glb").instantiate()
	var skel := skeleton_in(model)
	assert(skel != null and skel.get_bone_count() == 24)
	var skeleton_path := "Model/GLB/"+str(model.get_path_to(skel))
	var idle := pose()
	# A new low diagonal cut. No overhead reach or stacked torso twists.
	var windup := pose({"joint_13":Vector3(-3,0,0),"joint_4":Vector3(55,0,8),"joint_2":Vector3(60,0,0),"joint_1":Vector3(15,0,0)})
	var contact := pose({"joint_13":Vector3(-7,0,0),"joint_4":Vector3(30,0,8),"joint_2":Vector3(30,0,0),"joint_1":Vector3(-15,0,0)})
	var follow := pose({"joint_13":Vector3(-7,0,0),"joint_4":Vector3(10,0,5),"joint_2":Vector3(15,0,0),"joint_1":Vector3(-25,0,0)})
	var run_frames: Array = []
	for k in range(5):
		var wave := cos(k*PI*.5)
		run_frames.append(pose({"joint_13":Vector3(-4,0,0),"joint_4":Vector3(22-wave*6,0,5),"joint_2":Vector3(35,0,0),"joint_1":Vector3(0,0,0),"joint_18":Vector3(wave*20,0,6),"joint_21":Vector3(20,0,0),"joint_7":Vector3(wave*20,0,0),"joint_6":Vector3(-5-maxf(0,sin(k*PI*.5))*30,0,0),"joint_5":Vector3(5,0,0),"joint_17":Vector3(-wave*20,0,0),"joint_16":Vector3(-5-maxf(0,-sin(k*PI*.5))*30,0,0),"joint_19":Vector3(5,0,0)}))
	var library := AnimationLibrary.new()
	library.add_animation("idle",clip("SwordReadyIdle_V0",1.0,[0.0,1.0],[idle,idle],true,skeleton_path))
	library.add_animation("march",clip("SwordMarch_V0",.60,[0.0,.15,.30,.45,.60],run_frames,true,skeleton_path))
	library.add_animation("sword_cut",clip("SwordDiagonalCut_Fresh_V0",.68,[0.0,.20,.32,.43,.68],[idle,windup,contact,follow,idle],false,skeleton_path))
	assert(ResourceSaver.save(library,OUT+"sword_motion_library.tres") == OK)
	model.free()
	print("FRESH_CLIPS_BUILT ",skeleton_path)

func clip(label: String, duration: float, times: Array, poses: Array, looping: bool, path: String) -> Animation:
	var animation := Animation.new();animation.resource_name = label;animation.length = duration
	if looping:animation.loop_mode = Animation.LOOP_LINEAR
	for bone in BONE_NAMES:
		var track := animation.add_track(Animation.TYPE_ROTATION_3D)
		animation.track_set_path(track,NodePath(path+":"+bone))
		for k in range(times.size()):
			var degrees: Vector3 = poses[k][bone]
			animation.rotation_track_insert_key(track,times[k],Quaternion.from_euler(degrees*PI/180.0))
	return animation
