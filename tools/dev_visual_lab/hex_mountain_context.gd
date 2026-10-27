extends "res://tools/dev_visual_lab/hex_map_lab.gd"
## The previously reviewed hex document, extended with new owned ridge hexes.
const KIT_PATH := "C:/Users/User/Documents/Codex/2026-10-18/strategygame-godot-4-2-2-repo/outputs/threejs-hex-terrain-kit"
const PREVIEW_PATH := "C:/Users/User/Documents/Codex/2026-10-18/strategygame-godot-4-2-2-repo/outputs/hex-map-mountain-preview"
const OFFSET := Vector2i(10,-4)
const BRANCH := [Vector2i(0,0),Vector2i(1,0),Vector2i(2,0),Vector2i(-1,1),Vector2i(-2,2),Vector2i(-3,3),Vector2i(0,-1),Vector2i(0,-2)]
const HEIGHT_MULTIPLIER := 1.8
const RockDressing = preload("res://tools/dev_visual_lab/ridge_rock_dressing.gd")
var source_cells: Array = []
var added_keys: Dictionary = {}
var range_models: Array[Node3D] = []
var ridge_lod := -1
var imported_meshes := [0,0,0]
var rock_dressing: RefCounted
var rock_reports: Array = []

func boot() -> void:
	DirAccess.make_dir_recursive_absolute(PREVIEW_PATH)
	await super.boot()
	root.title = "StrategyGame | Hex Map - Connected Mountain Context"
	if not capture_mode:
		target = center(6,-1)
		camera.size = 205
		update_camera()
		await wait_frames(8)
		await save_picture("interactive")

func make_ui() -> void:
	super.make_ui()
	var column: VBoxContainer = info.get_parent()
	(column.get_child(0) as Label).text = "HEX MAP + CONNECTED RIDGE\nHEIGHT x1.8 / EXISTING ROCKS"
	var focus := Button.new()
	focus.text = "NEW RIDGE + EXISTING FOREST / CASTLE"
	focus.pressed.connect(func(): target = center(6,-1); camera.size = 195; update_camera())
	column.add_child(focus)
	var full := Button.new()
	full.text = "EXPANDED MAP OVERVIEW"
	full.pressed.connect(func(): target = Vector3(72,0,4); camera.size = 355; update_camera())
	column.add_child(full)
	var note := Label.new()
	note.text = "Added ridge: visual placement preview.\nExisting scenery layout is preserved.\nRidge footprint is fixed for comparison."
	column.add_child(note)

func generate() -> void:
	var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(out.path_join("edited-hex-map.json")))
	source_cells = data["cells"].duplicate(true)
	cells = source_cells.duplicate(true)
	seed_value = int(data["seed"])
	density = float(data["density"])
	meander = float(data["meander"])
	seed_input.value = seed_value
	density_input.value = density
	river_input.value = meander/50.0
	terrain_noise.seed = seed_value
	terrain_noise.frequency = 0.018
	moisture.seed = seed_value+974
	moisture.frequency = 0.032
	tile_lookup.clear()
	added_keys.clear()
	for i in range(cells.size()): tile_lookup[hex_key(cells[i]["q"],cells[i]["r"])] = i
	for local in BRANCH:
		var coord: Vector2i = OFFSET+local
		assert(not tile_lookup.has(hex_key(coord.x,coord.y)),"New ridge must not replace an existing hex")
		append_hex(coord,"mountain",true)
	# Add a continuous skirt of NEW hexes; never overwrite the reviewed map.
	for local in BRANCH:
		for d in DIRS:
			var coord: Vector2i = OFFSET+local+d
			if tile_lookup.has(hex_key(coord.x,coord.y)): continue
			append_hex(coord,"forest" if coord.y>=-1 and coord.x<=8 else "plain",false)
	chosen = -1
	recompose()
	info.text = "%d original hexes + %d new hexes\n8 connected mountain hexes, 2 main peaks.\nSame forest / castles / village / river." % [source_cells.size(),added_keys.size()]

func append_hex(coord: Vector2i,kind: String,ridge: bool) -> void:
	var key := hex_key(coord.x,coord.y)
	added_keys[key] = true
	tile_lookup[key] = cells.size()
	cells.append({"q":coord.x,"r":coord.y,"kind":kind,"variant":posmod(coord.x*5+coord.y*3,8),"rotation":0,"road":false,"ridge_preview":ridge})

func add_prop(cell: Dictionary,key: String,local: Vector2,width: float,angle: float = 0) -> void:
	if bool(cell.get("ridge_preview",false)): return
	super.add_prop(cell,key,local,width,angle)

func build_board_only() -> void:
	# The existing low flat connectors belong only to the legacy mountains.
	# New ridge hexes get their entire relief from the production GLB.
	for cell in cells:
		if bool(cell.get("ridge_preview",false)): cell["kind"] = "plain"
	super.build_terrain()
	for cell in cells:
		if bool(cell.get("ridge_preview",false)): cell["kind"] = "mountain"

func build_terrain() -> void:
	build_board_only()
	if not range_models.is_empty(): return
	for lod in range(3):
		var document := GLTFDocument.new()
		var state := GLTFState.new()
		var path := KIT_PATH.path_join("exports/mountain_assembly_branch_lod%d.glb" % lod)
		assert(document.append_from_file(path,state)==OK,"Production ridge import failed")
		var model := document.generate_scene(state) as Node3D
		model.name = "AddedMountainHexes_LOD%d" % lod
		model.scale = Vector3(R/24.0,R/24.0*HEIGHT_MULTIPLIER,R/24.0)
		model.position = center(OFFSET.x,OFFSET.y)+Vector3.UP*0.055
		stage.add_child(model)
		var meshes := model.find_children("*","MeshInstance3D",true,false)
		imported_meshes[lod] = meshes.size()
		assert(meshes.size()==BRANCH.size(),"Expected one imported mesh per new mountain hex")
		for mesh in meshes: mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		model.visible = lod==1
		range_models.append(model)
	rock_dressing = RockDressing.new()
	rock_dressing.load_variants()
	var centres: Array = []
	for local in BRANCH: centres.append(center(OFFSET.x+local.x,OFFSET.y+local.y))
	rock_dressing.plan_dressing(range_models[0],centres)
	for lod in range(3): rock_reports.append(rock_dressing.dress(range_models[lod],lod))
	print("[HexMountainContext] height x",HEIGHT_MULTIPLIER," reused rocks=",rock_dressing.placements.size())

func update_lod() -> void:
	super.update_lod()
	ridge_lod = 2 if camera.size>450 else (1 if camera.size>145 else 0)
	for i in range(range_models.size()): range_models[i].visible = i==ridge_lod

func make_actors() -> void:
	# The requested comparison is scenery only.
	pass

func handle_hex_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index==MOUSE_BUTTON_LEFT:
		var at := index_at(map_point(event.position))
		if (at>=0 and bool(cells[at].get("ridge_preview",false))) or (chosen>=0 and bool(cells[chosen].get("ridge_preview",false))):
			info.text = "New ridge hex: fixed asset comparison.\nUse RMB / wheel / WASD to inspect."
			dragging = false
			return
	super.handle_hex_input(event)

func save_document() -> void:
	var f := FileAccess.open(PREVIEW_PATH.path_join("expanded-hex-map.json"),FileAccess.WRITE)
	f.store_string(JSON.stringify({"schema_version":2,"seed":seed_value,"density":density,"meander":meander,"cells":cells,"ridge_source":"mountain_assembly_branch","offset":[OFFSET.x,OFFSET.y]},"\t"))
	f.close()

func load_document() -> void:
	# Reset to the saved reviewed map + the exact additive preview.
	generate()

func save_picture(name: String) -> void:
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(PREVIEW_PATH.path_join("taller-rocks-"+name+".png"))

func capture_suite() -> void:
	ui.visible = false
	yaw = 0.12
	orbit = 0.95
	target = Vector3(72,0,4)
	camera.size = 355
	update_camera()
	await wait_frames(14)
	await save_picture("expanded-map-overview")
	target = center(6,-1)
	camera.size = 205
	update_camera()
	await wait_frames(10)
	await save_picture("ridge-forest-castle-context")
	target = center(9,-3)
	camera.size = 130
	orbit = 0.70
	update_camera()
	await wait_frames(10)
	await save_picture("ridge-near")
	var unchanged := true
	for i in range(source_cells.size()):
		if source_cells[i]!=cells[i]: unchanged = false
	save_document()
	var f := FileAccess.open(PREVIEW_PATH.path_join("context-receipt.json"),FileAccess.WRITE)
	f.store_string(JSON.stringify({"engine":Engine.get_version_info(),"gpu":RenderingServer.get_video_adapter_name(),"original_hexes":source_cells.size(),"added_hexes":added_keys.size(),"new_mountain_hexes":8,"original_hex_records_unchanged":unchanged,"one_record_per_hex":tile_lookup.size()==cells.size(),"imported_meshes_per_lod":imported_meshes,"uniform_asset_scale":R/24.0,"unit_instances":actors.get_child_count(),"scope":"Same reviewed DEV hex map plus new hexes, existing scenery preserved; no mission or gameplay integration"},"\t"))
	f.close()
	var detail := FileAccess.open(PREVIEW_PATH.path_join("taller-rocks-receipt.json"),FileAccess.WRITE)
	detail.store_string(JSON.stringify({"height_multiplier":HEIGHT_MULTIPLIER,"footprint_scale":R/24.0,"rock_lods":rock_reports,"source_sha256":FileAccess.get_sha256(RockDressing.SOURCE),"original_hex_records_unchanged":unchanged,"scope":"Existing source rock meshes relocated into the raised ridge; no source models overwritten"},"\t"))
	detail.close()
	print("[HexMountainContext] original=",source_cells.size()," added=",added_keys.size()," original_unchanged=",unchanged)
	quit(0 if unchanged and tile_lookup.size()==cells.size() else 2)
