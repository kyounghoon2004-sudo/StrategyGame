extends "res://tools/dev_visual_lab/environment_lab.gd"
## Additive environment library category. No battlefield, units, or tutorials.
const KIT := "C:/Users/User/Documents/Codex/2026-10-18/strategygame-godot-4-2-2-repo/outputs/threejs-hex-terrain-kit"
const LINES := ["straight","bend","bend_sharp","branch","compact19"]
const TITLES := ["산맥 라인 · 직선", "산맥 라인 · 완만한 굽힘", "산맥 라인 · 급한 굽힘", "산맥 라인 · 분기", "산맥 라인 · 매시프"]
var first_line := -1
var first_selection := true

func boot() -> void:
	first_line = entries.size()
	for i in range(LINES.size()):
		entries.append({"id":"mountain_line_"+LINES[i],"kind":"composition","family":"mountain_line","key":LINES[i],"variant":0,"role":"connected_mountain_line","path":TITLES[i]})
	await super.boot()
	root.title = "StrategyGame | Asset Library - Mountain Lines"
	var row := HBoxContainer.new()
	var column := picker.get_parent()
	column.add_child(row)
	column.move_child(row,picker.get_index())
	var peaks := Button.new()
	peaks.text = "기존 개별 산봉우리"
	peaks.pressed.connect(func():
		for i in range(entries.size()):
			if str(entries[i]["path"]).contains("source_glb/mountains/"):
				select_asset(i)
				break)
	row.add_child(peaks)
	for i in range(LINES.size()):
		var button := Button.new()
		button.text = TITLES[i]
		button.pressed.connect(select_asset.bind(first_line+i))
		row.add_child(button)
	if "--capture-ui" in OS.get_cmdline_user_args():
		await wait_frames(10)
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(out.path_join("mountain-line-library.png"))

func set_camera() -> void:
	if index>=0 and index<entries.size() and entries[index].get("family","")=="mountain_line":
		camera.size = 18.0 if far_view else 7.0
		camera.position = Vector3(12,12,18)
		camera.look_at(Vector3(0,0.5,0))
	else:
		super.set_camera()

func composition(item: Dictionary) -> Node3D:
	if item["family"] != "mountain_line": return super.composition(item)
	var path := KIT.path_join("exports/mountain_assembly_"+str(item["key"])+"_lod0.glb")
	var document := GLTFDocument.new()
	var state := GLTFState.new()
	var error := document.append_from_file(path,state)
	info["glb_path"] = path
	info["gltf_error"] = error
	if error != OK:
		push_error("Cannot load mountain line: "+path)
		return null
	return document.generate_scene(state) as Node3D

func select_asset(which: int) -> void:
	if first_selection:
		first_selection = false
		which = first_line
	super.select_asset(which)

func capture_all() -> void:
	DirAccess.make_dir_recursive_absolute(out.path_join("previews"))
	for i in range(LINES.size()):
		select_asset(first_line+i)
		await wait_frames(6)
		if info["loaded"]:
			info["near"] = await snapshot("near")
			far_view = true
			set_camera()
			await wait_frames(3)
			info["far"] = await snapshot("far")
		records.append(info.duplicate(true))
	var f := FileAccess.open(out.path_join("mountain-lines-runtime.json"),FileAccess.WRITE)
	f.store_string(JSON.stringify({"engine":Engine.get_version_info(),"gpu":RenderingServer.get_video_adapter_name(),"scope":"Environment asset library only; no battlefield or units loaded","preview_resolution":[640,480],"entries":records},"\t"))
	f.close()
	print("[MountainLineLibrary] captured ",records.size()," new library entries")
	call_deferred("finish")
