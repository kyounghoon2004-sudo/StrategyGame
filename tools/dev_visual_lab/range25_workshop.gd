extends "res://tools/dev_visual_lab/hex_mountain_context.gd"
## 25 opt-in scenery variants on the reviewed DEV hex map, no battle logic.
const OUT25 := "C:/Users/User/Documents/Codex/2026-10-18/strategygame-godot-4-2-2-repo/outputs/mountain-range-25"
var catalog25: Array = []
var selected25 := 22
var offset25 := Vector2i.ZERO
var shape_picker: OptionButton
var size_picker: OptionButton
var captures25: Array = []

func boot() -> void:
	catalog25 = JSON.parse_string(FileAccess.get_file_as_string(KIT_PATH.path_join("range25/catalog.json")))["catalog"]
	DirAccess.make_dir_recursive_absolute(OUT25.path_join("images"))
	DirAccess.make_dir_recursive_absolute(OUT25.path_join("exports"))
	await super.boot()
	root.title = "StrategyGame | 25 Mountain Ranges - Hex Map"
	if not capture_mode:
		focus25(true)
		await wait_frames(8)
		await save_picture("workshop")
		if "--ui-smoke" in OS.get_cmdline_user_args(): await exercise25()

func exercise25() -> void:
	shape_picker.select(3)
	shape_picker.emit_signal("item_selected",3)
	var shape_ok := selected25==17
	size_picker.select(1)
	size_picker.emit_signal("item_selected",1)
	var size_ok := selected25==16 and int(catalog25[selected25]["hexCount"])==8
	var column := info.get_parent()
	for child in column.get_children():
		if child is Button and child.text=="다음 산맥": child.emit_signal("pressed")
	var next_ok := selected25==17
	for child in column.get_children():
		if child is Button and child.text=="이전 산맥": child.emit_signal("pressed")
	var previous_ok := selected25==16
	select25(22)
	await wait_frames(6)
	await save_picture("workshop")
	var f := FileAccess.open(OUT25.path_join("ui-receipt.json"),FileAccess.WRITE)
	f.store_string(JSON.stringify({"shape_selector":shape_ok,"size_selector":size_ok,"next_button":next_ok,"previous_button":previous_ok,"restored_variant":catalog25[selected25]["id"],"method":"Real OptionButton/Button signal handlers, no synthetic OS pointer clicks"},"\t"))
	f.close()
	print("[Range25UI] shape=",shape_ok," size=",size_ok," next=",next_ok," previous=",previous_ok)
	quit(0 if shape_ok and size_ok and next_ok and previous_ok else 2)

func make_ui() -> void:
	super.make_ui()
	var column: VBoxContainer = info.get_parent()
	# Keep inherited widgets alive for composition internals, show a focused chooser.
	for child in column.get_children(): child.visible = false
	var heading := Label.new()
	heading.text = "산맥 25종 · 헥스 맵 비교"
	heading.add_theme_font_size_override("font_size",23)
	column.add_child(heading)
	var help := Label.new()
	help.text = "휠: 확대/축소 · 우클릭: 회전\nWASD: 이동 · 원본 지형 배치 유지"
	column.add_child(help)
	shape_picker = OptionButton.new()
	for label in ["직선","완만한 C자","굽이치는 S자","Y자 분기","불규칙 확장"]: shape_picker.add_item(label)
	shape_picker.select(selected25/5)
	shape_picker.item_selected.connect(func(i): select25(i*5+size_picker.selected))
	column.add_child(shape_picker)
	size_picker = OptionButton.new()
	for label in ["짧고 낮음 · 6헥스","짧고 높음 · 8헥스","중간 · 12헥스","길고 낮음 · 18헥스","길고 높음 · 24헥스"]: size_picker.add_item(label)
	size_picker.select(selected25%5)
	size_picker.item_selected.connect(func(i): select25(shape_picker.selected*5+i))
	column.add_child(size_picker)
	for pair in [["이전 산맥",-1],["다음 산맥",1]]:
		var button := Button.new()
		button.text = pair[0]
		button.pressed.connect(func(): select25(posmod(selected25+int(pair[1]),25)))
		column.add_child(button)
	for label in ["숲·성과 함께 보기","산맥 가까이 보기","전체 맵 보기"]:
		var button := Button.new()
		button.text = label
		if label=="숲·성과 함께 보기": button.pressed.connect(func(): focus25(true))
		elif label=="산맥 가까이 보기": button.pressed.connect(func(): focus25(false))
		else: button.pressed.connect(overview25)
		column.add_child(button)
	info.visible = true
	status.visible = true
	column.move_child(info,column.get_child_count()-1)
	column.move_child(status,column.get_child_count()-1)

func select25(which: int) -> void:
	selected25 = which
	shape_picker.select(which/5)
	size_picker.select(which%5)
	generate()
	focus25(true)

func generate() -> void:
	for model in range_models: model.free()
	range_models.clear()
	rock_reports.clear()
	var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(out.path_join("edited-hex-map.json")))
	source_cells = data["cells"].duplicate(true)
	cells = source_cells.duplicate(true)
	seed_value = int(data["seed"])
	density = float(data["density"])
	meander = float(data["meander"])
	terrain_noise.seed = seed_value
	terrain_noise.frequency = 0.018
	moisture.seed = seed_value+974
	moisture.frequency = 0.032
	tile_lookup.clear()
	added_keys.clear()
	for i in range(cells.size()): tile_lookup[hex_key(cells[i]["q"],cells[i]["r"])] = i
	var entry: Dictionary = catalog25[selected25]
	var anchor: Dictionary = entry["cells"][0]
	for c in entry["cells"]:
		if int(c["q"])<int(anchor["q"]): anchor = c
	offset25 = Vector2i(7-int(anchor["q"]),-1-int(anchor["r"]))
	for c in entry["cells"]:
		var coord := Vector2i(c["q"],c["r"])+offset25
		assert(not tile_lookup.has(hex_key(coord.x,coord.y)))
		append_hex(coord,"mountain",true)
	for c in entry["cells"]:
		for d in DIRS:
			var coord: Vector2i = Vector2i(c["q"],c["r"])+offset25+d
			if not tile_lookup.has(hex_key(coord.x,coord.y)):
				append_hex(coord,"forest" if coord.x<=8 and coord.y>=-1 else "plain",false)
	chosen = -1
	recompose()
	info.text = "%d / 25 · %s\n%s · 높이 x%.2f\n%d 산 헥스 · %d 주봉 · 바위 %d개\n같은 헥스 크기 / 연속 산맥" % [selected25+1,entry["shapeLabel"],entry["sizeLabel"],entry["heightMultiplier"],entry["hexCount"],entry["peakCount"],rock_dressing.placements.size()]

func build_terrain() -> void:
	build_board_only()
	var entry: Dictionary = catalog25[selected25]
	for lod in range(3):
		var document := GLTFDocument.new()
		var state := GLTFState.new()
		var path := KIT_PATH.path_join("range25/"+str(entry["files"][lod]["file"]))
		assert(document.append_from_file(path,state)==OK)
		var model := document.generate_scene(state) as Node3D
		model.scale = Vector3.ONE*(R/24.0)
		model.position = center(offset25.x,offset25.y)+Vector3.UP*0.055
		stage.add_child(model)
		var meshes := model.find_children("*","MeshInstance3D",true,false)
		assert(meshes.size()==int(entry["hexCount"]))
		for mesh in meshes: mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		model.visible = lod==1
		range_models.append(model)
	rock_dressing = RockDressing.new()
	rock_dressing.load_variants()
	var centres: Array = []
	for c in entry["cells"]: centres.append(center(offset25.x+int(c["q"]),offset25.y+int(c["r"])))
	rock_dressing.plan_dressing(range_models[0],centres)
	for lod in range(3): rock_reports.append(rock_dressing.dress(range_models[lod],lod))

func bounds25(context: bool) -> AABB:
	var entry: Dictionary = catalog25[selected25]
	var lo: Array = entry["bounds"]["min"]
	var hi: Array = entry["bounds"]["max"]
	var origin := center(offset25.x,offset25.y)
	var box := AABB(Vector3(lo[0],lo[1],lo[2])*(R/24.0)+origin,(Vector3(hi[0],hi[1],hi[2])-Vector3(lo[0],lo[1],lo[2]))*(R/24.0))
	if context:
		box = box.expand(center(3,1)+Vector3(-20,0,-25))
		box = box.expand(center(5,1)+Vector3(15,12,20))
	return box

func focus25(context: bool) -> void:
	yaw = 0.12
	orbit = 0.78
	var box := bounds25(context)
	target = box.get_center()
	update_camera()
	var inv := camera.global_transform.basis.inverse()
	var extent := Vector2.ZERO
	for i in range(8):
		var p := inv*(box.get_endpoint(i)-target)
		extent.x = maxf(extent.x,absf(p.x))
		extent.y = maxf(extent.y,absf(p.y))
	camera.size = maxf(80.0,maxf(extent.y*2,extent.x*2/(1920.0/1080.0))*1.20)
	update_camera()

func overview25() -> void:
	var box := bounds25(true).expand(Vector3(-180,0,-190)).expand(Vector3(-180,0,190))
	target = box.get_center()
	camera.size = maxf(355,box.size.x/(1920.0/1080.0)*1.20)
	update_camera()

func save_picture(name: String) -> void:
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(OUT25.path_join("images/"+name+".png"))

func export_dressed25(entry: Dictionary) -> Dictionary:
	var clean := Node3D.new()
	clean.name = entry["id"]
	var model: Node3D = range_models[0]
	var inverse := model.global_transform.affine_inverse()
	var expected := 0
	for source in model.find_children("*","MeshInstance3D",true,false):
		var node := MeshInstance3D.new()
		node.mesh = source.mesh
		node.transform = inverse*source.global_transform
		clean.add_child(node)
		expected += 1
	for source in model.find_children("*","MultiMeshInstance3D",true,false):
		for i in range(source.multimesh.instance_count):
			var node := MeshInstance3D.new()
			node.mesh = source.multimesh.mesh
			node.transform = inverse*source.global_transform*source.multimesh.get_instance_transform(i)
			clean.add_child(node)
			expected += 1
	var document := GLTFDocument.new()
	var state := GLTFState.new()
	var path := OUT25.path_join("exports/"+str(entry["id"])+".glb")
	var error := document.append_from_scene(clean,state)
	if error==OK: error = document.write_to_filesystem(state,path)
	clean.free()
	var reload := GLTFDocument.new()
	var reload_state := GLTFState.new()
	var reload_error := reload.append_from_file(path,reload_state) if error==OK else error
	var count := 0
	if reload_error==OK:
		var scene := reload.generate_scene(reload_state)
		count = scene.find_children("*","MeshInstance3D",true,false).size()
		scene.free()
	return {"file":path,"export_error":error,"reload_error":reload_error,"expected_meshes":expected,"reloaded_meshes":count,"sha256":FileAccess.get_sha256(path) if error==OK else "","ok":error==OK and reload_error==OK and count==expected}

func capture_suite() -> void:
	ui.visible = false
	for which in range(25):
		if which!=selected25: selected25 = which; generate()
		var entry: Dictionary = catalog25[which]
		var original_ok := true
		for i in range(source_cells.size()):
			if source_cells[i]!=cells[i]: original_ok = false
		focus25(false)
		# Common camera scale across the full matrix: lengths stay comparable.
		camera.size = 490
		update_camera()
		land.visible = false
		props.visible = false
		await wait_frames(4)
		await save_picture(str(entry["id"])+"_comparison")
		land.visible = true
		props.visible = true
		focus25(true)
		await wait_frames(4)
		await save_picture(str(entry["id"])+"_context")
		var export_result := export_dressed25(entry)
		captures25.append({"id":entry["id"],"hexes":entry["hexCount"],"original_cells_unchanged":original_ok,"unique_hexes":cells.size()==tile_lookup.size(),"rocks":rock_reports.duplicate(true),"export":export_result})
		var f := FileAccess.open(OUT25.path_join("godot-receipt.json"),FileAccess.WRITE)
		f.store_string(JSON.stringify({"engine":Engine.get_version_info(),"gpu":RenderingServer.get_video_adapter_name(),"entries":captures25,"scope":"25 variants on the reviewed DEV hex document; no tutorials/units/gameplay changes"},"\t"))
		f.close()
		print("[Range25] ",which+1,"/25 ",entry["id"]," rocks=",rock_dressing.placements.size()," export/reload=",export_result["ok"])
	var ok := captures25.size()==25
	for record in captures25: ok = ok and record["original_cells_unchanged"] and record["unique_hexes"] and record["export"]["ok"]
	quit(0 if ok else 2)
