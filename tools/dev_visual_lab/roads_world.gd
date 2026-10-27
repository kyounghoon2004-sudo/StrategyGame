extends "res://tools/dev_visual_lab/natural_ground_world.gd"
const Roads = preload("res://tools/dev_visual_lab/scenery_roads.gd")
const ROADS_OUT := "C:/Users/User/Documents/Codex/2026-10-18/strategygame-godot-4-2-2-repo/outputs/scenery-roads"
var road_builder: RefCounted
var roads_root: Node3D

func ensure_roads() -> void:
	if roads_root!=null: return
	road_builder = Roads.new()
	roads_root = road_builder.build(self)
	stage.add_child(roads_root)
	move_trees_off_roads()
	DirAccess.make_dir_recursive_absolute(ROADS_OUT)
	var f := FileAccess.open(ROADS_OUT.path_join("roads-receipt.json"),FileAccess.WRITE)
	var report: Dictionary = road_builder.get("report").duplicate()
	report["logical_map_unchanged"] = cells==world_data["cells"]
	report["ranges"] = world_ranges.size()
	report["settlement_farm_assemblies"] = hex_assemblies.size()
	f.store_string(JSON.stringify(report,"\t")); f.close()
	# The complete road is also a reusable mesh resource with its material.
	var road_node: MeshInstance3D = roads_root.get_child(0)
	road_node.mesh.surface_set_material(0,road_node.material_override)
	ResourceSaver.save(road_node.mesh,ROADS_OUT.path_join("connected-roads.res"))

func move_trees_off_roads() -> void:
	if not optimized: return
	# Preserve the original chunk membership/order while updating every LOD.
	var groups := {}
	for item in document:
		var p: Array = item["p"]
		var group := "%s:%d:%d" % [item["key"],floori(float(p[0])/64),floori(float(p[2])/64)]
		if not groups.has(group): groups[group] = {"key":item["key"],"items":[]}
		groups[group]["items"].append(item)
	var moved: int = road_builder.move_roadside_trees(document,Lib.TREES.keys())
	var group_values: Array = groups.values()
	if group_values.size()!=current_meshes.size(): return
	for i in range(group_values.size()):
		var group: Dictionary = group_values[i]
		var bounds: Dictionary = Lib.bounds(group["key"])
		var box := AABB(bounds["min"],bounds["max"]-bounds["min"])
		for node in current_meshes[i]["lods"].values():
			for j in range(group["items"].size()):
				node.multimesh.set_instance_transform(j,placement_transform(group["items"][j],box))
	road_builder.report["trees_relocated_within_same_hex"] = moved
	print("[SceneryRoads] Trees moved aside within their hex: ",moved)

func boot() -> void:
	await super.boot()
	ensure_roads()
	root.title = "StrategyGame | Full Asset Library - Connected Roads"
	if not capture_mode: focus_crossing()

func save_picture(name: String) -> void:
	DirAccess.make_dir_recursive_absolute(ROADS_OUT)
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(ROADS_OUT.path_join(name+".png"))

func save_render_png(name: String) -> void:
	await save_picture(name)

func save_ground_render(name: String) -> void:
	await save_picture(name.get_basename())

func capture_suite() -> void:
	ensure_roads()
	ui.visible = false
	for shot in ["crossing","district","overview"]:
		if shot=="crossing": focus_crossing()
		elif shot=="district": focus_district1_near()
		else: show_world()
		await wait_frames(5)
		await save_picture(shot)
	if "--keep-open" in OS.get_cmdline_user_args():
		capture_mode = false
		ui.visible = true
		focus_crossing()
	else:
		quit()
