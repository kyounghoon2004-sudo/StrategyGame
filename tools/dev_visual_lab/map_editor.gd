extends SceneTree
## Separate visual map authoring tool; saved JSON is the shared source of truth.
const Paths = preload("res://tools/dev_visual_lab/visual_output_paths.gd")
const Store = preload("res://tools/dev_visual_lab/map_editor_store.gd")
const Lib = preload("res://scripts/visual/map_composition_v0/map_composition_library.gd")
const Pal = preload("res://tools/dev_visual_lab/map_editor_palette.gd")
const UnitManager = preload("res://tools/dev_visual_lab/unit_lod_manager.gd")
const PathLayer = preload("res://tools/dev_visual_lab/map_editor_paths.gd")
const GroundPaint = preload("res://tools/dev_visual_lab/map_editor_ground.gd")
var path_layer_builder: RefCounted
const R := 18.0
const SQRT3 := 1.7320508075688772
const BUILDINGS := ["building_small_house", "building_medium_house", "building_workshop", "building_granary", "building_hall", "building_gate", "building_farm_granary"]
const BUILDING_NAMES := ["작은 집", "큰 집", "작업장", "창고", "마을 회관", "마을 문", "농장 창고"]
## Tool list: select, every palette group (map_editor_palette.gd), erase. A group maps to a stored object kind.
const KINDS := ["select", "brush", "ground", "forest", "tree", "range", "water", "road", "castle", "fort", "building", "farm", "unit", "erase"]
const KIND_NAMES := ["선택 · 이동", "산 그리기", "바닥", "숲", "나무", "산맥 통째로", "강 · 다리", "길", "성곽", "요새 시설", "건물", "농지", "유닛", "지우개"]
var unit_loader: ResourceFormatLoader
## Multi-hex mountains: cell -> [object index, [mesh indices on that cell]], rebuilt with the objects.
var coverage := {}
## Drag editing (Clash-of-Clans style): one stroke = one undo step.
var stroke_active := false
var stroke_saved := false
var stroke_last := Vector2i(999,999)
var drag_group: Array = []          # object indices being dragged in select mode
var drag_from := Vector2i(999,999)
var drag_to := Vector2i(999,999)
## range25 cut into one-hex pieces: [{scene, mask}] where mask has bit i set when HEX_DIRS[i] is also mountain.
var _range_pieces: Array = []
var _dir_step := 0.0
const HEX_DIRS := [Vector2i(1,0), Vector2i(1,-1), Vector2i(0,-1), Vector2i(-1,0), Vector2i(-1,1), Vector2i(0,1)]
var store: RefCounted
var doc: Dictionary
var saved_hash := ""
var dirty := false
var history: Array = []
var catalog: Array = []
var scene_cache := {}
var stage: Node3D
var placed_root: Node3D
var board_root: Node3D
var camera: Camera3D
var target := Vector3.ZERO
var yaw := 0.12
var orbit := 0.85
var rotating := false
var pressed_cell := Vector2i(999,999)
var selected_cell := Vector2i(999,999)
var panel: PanelContainer
var palette_panel: PanelContainer
var palette_title: Label
var palette_grid: GridContainer
var palette_group: ButtonGroup
var thumbnail_cache := {}
var small_thumbnail_cache := {}
var map_name: LineEdit
var radius_picker: SpinBox
var saved_maps: OptionButton
var tool_picker: OptionButton
var variant_picker: OptionButton
var object_picker: OptionButton
var move_pending := false
var message: Label
var selection: Label
var confirm: ConfirmationDialog
var pending_action := ""
var pending_path := ""
var marker: MeshInstance3D

class InputRelay extends Node:
	var controller: Object
	func _input(event: InputEvent) -> void:
		# A release can land over the panel and be consumed by its controls.
		if event is InputEventMouseButton and not event.pressed and event.button_index == MOUSE_BUTTON_RIGHT:
			controller.rotating = false
	func _unhandled_input(event: InputEvent) -> void:
		controller.handle_world_input(event)

func _initialize() -> void:
	var outputs := OS.get_environment("SG_VISUAL_OUTPUT_ROOT")
	if outputs.is_empty(): outputs = Paths.LEGACY_ROOT
	var catalog_path := outputs.path_join("scenery-scale-massif/massif25/catalog.json")
	if not FileAccess.file_exists(catalog_path):
		push_error("[MapEditor] Missing visual outputs: " + catalog_path)
		quit(2)
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(catalog_path))
	if not parsed is Dictionary or not parsed.get("catalog") is Array:
		push_error("[MapEditor] Invalid mountain catalog")
		quit(2)
		return
	catalog = parsed.catalog
	var save_dir := OS.get_environment("SG_MAP_EDITOR_DIR")
	if save_dir.is_empty(): save_dir = ProjectSettings.globalize_path("user://strategy_map_editor/maps")
	store = Store.new(save_dir)
	doc = store.new_document()
	call_deferred("boot")

func boot() -> void:
	set_auto_accept_quit(false)
	root.close_requested.connect(func(): request_action("quit", ""))
	root.title = "StrategyGame | 맵 만들기"
	root.size = Vector2i(1440,900)
	root.min_size = Vector2i(1000,650)
	if "--small-window" in OS.get_cmdline_user_args():
		root.size = Vector2i(1000,650)
		DisplayServer.window_set_size(Vector2i(1000,650))
	root.msaa_3d = Viewport.MSAA_2X
	stage = Node3D.new(); root.add_child(stage)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color("263c43")
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color("dce4ce")
	env.environment.ambient_light_energy = 0.65
	stage.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-48,-32,0); sun.light_color = Color("fff0ce"); sun.light_energy = 1.05
	stage.add_child(sun)
	camera = Camera3D.new(); camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 280; camera.far = 6000; stage.add_child(camera); camera.make_current()
	placed_root = Node3D.new(); stage.add_child(placed_root)
	var selection_mesh := CylinderMesh.new()
	selection_mesh.top_radius = R * 0.96; selection_mesh.bottom_radius = R * 0.96
	selection_mesh.height = 0.12; selection_mesh.radial_segments = 6
	marker = MeshInstance3D.new(); marker.mesh = selection_mesh
	var gold := StandardMaterial3D.new(); gold.albedo_color = Color(1,0.75,0.2,0.35)
	gold.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA; gold.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	marker.material_override = gold; marker.visible = false; stage.add_child(marker)
	make_board()
	make_ui()
	var relay := InputRelay.new()
	relay.controller = self
	root.add_child(relay)
	update_camera()
	if "--editor-smoke" in OS.get_cmdline_user_args(): call_deferred("smoke_test")
	elif "--editor-reopen-test" in OS.get_cmdline_user_args(): call_deferred("reopen_test")
	elif "--palette-smoke" in OS.get_cmdline_user_args(): call_deferred("palette_smoke_test")

func center(q: int, r: int) -> Vector3:
	return Vector3(1.5*R*q, 0, SQRT3*R*(r + q*0.5))

func make_board() -> void:
	if board_root != null: board_root.free()
	board_root = Node3D.new(); stage.add_child(board_root)
	var surface := SurfaceTool.new(); surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var lines := ImmediateMesh.new(); lines.surface_begin(Mesh.PRIMITIVE_LINES)
	for q in range(-int(doc.radius), int(doc.radius)+1):
		for r in range(-int(doc.radius), int(doc.radius)+1):
			if maxi(absi(q), maxi(absi(r), absi(q+r))) > int(doc.radius): continue
			var c := center(q,r)
			var col := Color("83965b").srgb_to_linear().lightened(float(posmod(q*7+r*11,5))*0.008)
			for k in range(6):
				var a := Vector3(c.x + R*cos(k*PI/3),0,c.z + R*sin(k*PI/3))
				var b := Vector3(c.x + R*cos((k+1)*PI/3),0,c.z + R*sin((k+1)*PI/3))
				for vertex in [c,b,a]: surface.set_normal(Vector3.UP); surface.set_color(col); surface.add_vertex(vertex)
				lines.surface_add_vertex(a+Vector3.UP*0.06); lines.surface_add_vertex(b+Vector3.UP*0.06)
	var ground := MeshInstance3D.new(); ground.mesh = surface.commit()
	var ground_mat := StandardMaterial3D.new(); ground_mat.vertex_color_use_as_albedo = true; ground_mat.roughness = 1.0; ground_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	ground.material_override = ground_mat; board_root.add_child(ground)
	var grid := MeshInstance3D.new(); grid.mesh = lines
	var line_mat := StandardMaterial3D.new(); line_mat.albedo_color = Color(0.12,0.17,0.1,0.45); line_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA; line_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	grid.material_override = line_mat; board_root.add_child(grid)

func make_ui() -> void:
	var layer := CanvasLayer.new(); root.add_child(layer)
	panel = PanelContainer.new(); panel.position = Vector2(16,16); panel.custom_minimum_size = Vector2(320,0)
	var style := StyleBoxFlat.new(); style.bg_color = Color(0.055,0.085,0.09,0.96); style.border_color = Color("9a936a"); style.set_border_width_all(1); style.set_corner_radius_all(6); style.set_content_margin_all(14)
	panel.add_theme_stylebox_override("panel",style); layer.add_child(panel)
	var col := VBoxContainer.new(); col.add_theme_constant_override("separation",7); panel.add_child(col)
	var title := Label.new(); title.text = "맵 만들기  ·  DEV"; title.add_theme_font_size_override("font_size",23); col.add_child(title)
	var help := Label.new(); help.text = "휠 줌 · 우클릭 회전 · WASD 이동\n클릭 배치 · 선택 후 드래그 이동\nR 회전 · Delete 삭제 · Ctrl+Z 되돌리기"; help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART; col.add_child(help)
	var zoom_row := HBoxContainer.new(); col.add_child(zoom_row)
	var zoom_in := Button.new(); zoom_in.text = "확대 +"; zoom_in.size_flags_horizontal = Control.SIZE_EXPAND_FILL; zoom_in.pressed.connect(func(): zoom_camera(true)); zoom_row.add_child(zoom_in)
	var zoom_out := Button.new(); zoom_out.text = "축소 −"; zoom_out.size_flags_horizontal = Control.SIZE_EXPAND_FILL; zoom_out.pressed.connect(func(): zoom_camera(false)); zoom_row.add_child(zoom_out)
	map_name = LineEdit.new(); map_name.placeholder_text = "맵 이름"; map_name.text = doc.name; col.add_child(map_name)
	map_name.text_changed.connect(func(_text): dirty = true)
	var save_row := HBoxContainer.new(); col.add_child(save_row)
	var save_button := Button.new(); save_button.text = "저장"; save_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL; save_button.pressed.connect(save_map); save_row.add_child(save_button)
	var new_button := Button.new(); new_button.text = "새 맵"; new_button.pressed.connect(func(): request_action("new", "")); save_row.add_child(new_button)
	saved_maps = OptionButton.new(); saved_maps.size_flags_horizontal = Control.SIZE_EXPAND_FILL; col.add_child(saved_maps)
	var load_button := Button.new(); load_button.text = "선택한 맵 불러오기"; load_button.pressed.connect(func():
		if saved_maps.selected >= 0:
			var path := str(saved_maps.get_item_metadata(saved_maps.selected))
			if not path.is_empty(): request_action("load", path))
	col.add_child(load_button)
	var size_row := HBoxContainer.new(); col.add_child(size_row)
	var size_label := Label.new(); size_label.text = "맵 반경"; size_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL; size_row.add_child(size_label)
	radius_picker = SpinBox.new(); radius_picker.min_value = 2; radius_picker.max_value = 40; radius_picker.step = 1; radius_picker.value = doc.radius; radius_picker.custom_minimum_size.x = 85; size_row.add_child(radius_picker)
	var resize_button := Button.new(); resize_button.text = "크기 적용"; resize_button.pressed.connect(resize_map); size_row.add_child(resize_button)
	var sep := HSeparator.new(); col.add_child(sep)
	var caption := Label.new(); caption.text = "배치 도구"; caption.add_theme_font_size_override("font_size",17); col.add_child(caption)
	tool_picker = OptionButton.new(); for label in KIND_NAMES: tool_picker.add_item(label)
	col.add_child(tool_picker); tool_picker.item_selected.connect(func(_i): update_variants())
	variant_picker = OptionButton.new(); col.add_child(variant_picker)
	variant_picker.item_selected.connect(func(_i): refresh_palette())
	update_variants()
	selection = Label.new(); selection.text = "선택된 헥스 없음"; selection.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART; col.add_child(selection)
	object_picker = OptionButton.new(); col.add_child(object_picker)
	object_picker.item_selected.connect(func(i):
		var cell: Variant = object_picker.get_item_metadata(i)
		if cell is Vector2i: select_cell(cell))
	refresh_objects()
	var move_button := Button.new(); move_button.text = "선택 배치 이동: 목적지 클릭"; col.add_child(move_button)
	move_button.pressed.connect(func():
		if index_at(selected_cell) < 0: set_message("먼저 이동할 배치를 선택하세요."); return
		tool_picker.select(0); update_variants(); move_pending = true
		set_message("이동할 빈 헥스를 클릭하세요."))
	var rotate_button := Button.new(); rotate_button.text = "선택 회전 60° (R)"; rotate_button.pressed.connect(rotate_selected); col.add_child(rotate_button)
	var undo_button := Button.new(); undo_button.text = "되돌리기 (Ctrl+Z)"; undo_button.pressed.connect(undo); col.add_child(undo_button)
	message = Label.new(); message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART; message.custom_minimum_size = Vector2(280,42); message.add_theme_color_override("font_color", Color("e6d7a4")); col.add_child(message)
	var note := Label.new(); note.text = "숲과 산괴는 배치 단위입니다.\n연결부와 산기슭 다듬기는 추후 작업.\n산괴는 여러 헥스를 덮을 수 있습니다."; note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART; note.add_theme_font_size_override("font_size",13); col.add_child(note)
	confirm = ConfirmationDialog.new(); confirm.title = "저장하지 않은 변경"; confirm.dialog_text = "저장하지 않은 변경을 버리고 계속할까요?"; layer.add_child(confirm)
	confirm.confirmed.connect(func(): perform_action(pending_action, pending_path))
	make_palette(layer, style)
	refresh_maps()
	set_message("새 맵입니다. 도구를 고르고 헥스를 클릭하세요.")

func update_variants() -> void:
	variant_picker.clear()
	for e in Pal.in_group(KINDS[tool_picker.selected]):
		variant_picker.add_item(str(e.label)); variant_picker.set_item_metadata(variant_picker.item_count-1, str(e.variant))
	variant_picker.disabled = variant_picker.item_count == 0
	refresh_palette()

func thumbnail_for(kind: String, variant: String) -> Texture2D:
	var key := kind + "__" + variant
	if thumbnail_cache.has(key): return thumbnail_cache[key]
	var path := Paths.output("map-editor-thumbnails/" + key + ".png")
	if not FileAccess.file_exists(path): return null
	var image := Image.load_from_file(path)
	if image == null or image.is_empty(): return null
	var texture := ImageTexture.create_from_image(image)
	thumbnail_cache[key] = texture
	return texture

func small_thumbnail_for(kind: String, variant: String) -> Texture2D:
	var key := kind + "__" + variant
	if small_thumbnail_cache.has(key): return small_thumbnail_cache[key]
	var large := thumbnail_for(kind,variant)
	if large == null: return null
	var image := large.get_image()
	image.resize(32,24,Image.INTERPOLATE_LANCZOS)
	var texture := ImageTexture.create_from_image(image)
	small_thumbnail_cache[key] = texture
	return texture

func make_palette(layer: CanvasLayer, style: StyleBoxFlat) -> void:
	palette_panel = PanelContainer.new()
	palette_panel.name = "VisualPalette"
	palette_panel.anchor_left = 1.0; palette_panel.anchor_right = 1.0
	palette_panel.anchor_top = 0.0; palette_panel.anchor_bottom = 1.0
	palette_panel.offset_left = -416; palette_panel.offset_right = -16
	palette_panel.offset_top = 16; palette_panel.offset_bottom = -16
	palette_panel.add_theme_stylebox_override("panel",style.duplicate())
	layer.add_child(palette_panel)
	var box := VBoxContainer.new(); box.add_theme_constant_override("separation",8); palette_panel.add_child(box)
	var heading := Label.new(); heading.text = "배치할 경관"; heading.add_theme_font_size_override("font_size",21); box.add_child(heading)
	var categories := GridContainer.new(); categories.columns = 4; box.add_child(categories)
	for index in range(1, KINDS.size() - 1):
		var category := Button.new(); category.text = KIND_NAMES[index]; category.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		category.name = "PaletteCategory%d" % index
		category.pressed.connect(func(): tool_picker.select(index); update_variants())
		categories.add_child(category)
	palette_title = Label.new(); palette_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART; box.add_child(palette_title)
	var scroller := ScrollContainer.new(); scroller.name = "PaletteScroll"; scroller.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroller.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED; box.add_child(scroller)
	palette_grid = GridContainer.new(); palette_grid.columns = 2
	palette_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	palette_grid.add_theme_constant_override("h_separation",8); palette_grid.add_theme_constant_override("v_separation",10)
	scroller.add_child(palette_grid)
	tool_picker.select(1); update_variants()

func refresh_palette() -> void:
	if palette_grid == null: return
	for child in palette_grid.get_children(): child.queue_free()
	palette_group = ButtonGroup.new()
	var kind: String = group_kind(KINDS[tool_picker.selected])
	if KINDS[tool_picker.selected] in ["select", "erase"]:
		palette_title.text = "위의 카테고리를 눌러 배치할 모델을 선택하세요."
		return
	palette_title.text = KIND_NAMES[tool_picker.selected] + " · 그림을 선택한 뒤 맵을 클릭"
	for i in range(variant_picker.item_count):
		var card := VBoxContainer.new(); card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		card.add_theme_constant_override("separation",3); palette_grid.add_child(card)
		var button := Button.new(); button.name = "PaletteItem%d" % i
		button.toggle_mode = true; button.button_group = palette_group
		var idle := StyleBoxFlat.new(); idle.bg_color = Color("182a28"); idle.border_color = Color("49605b"); idle.set_border_width_all(1); idle.set_corner_radius_all(4)
		var chosen_style := idle.duplicate() as StyleBoxFlat; chosen_style.bg_color = Color("3b3b27"); chosen_style.border_color = Color("e6c270"); chosen_style.set_border_width_all(3)
		var hover := idle.duplicate() as StyleBoxFlat; hover.border_color = Color("d0bf85"); hover.set_border_width_all(2)
		button.add_theme_stylebox_override("normal",idle); button.add_theme_stylebox_override("hover",hover); button.add_theme_stylebox_override("pressed",chosen_style)
		button.custom_minimum_size = Vector2(150,110); button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.expand_icon = true; button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
		var variant := str(variant_picker.get_item_metadata(i))
		button.icon = thumbnail_for(kind,variant)
		if button.icon == null: button.text = "이미지 없음"
		button.tooltip_text = variant_picker.get_item_text(i)
		button.button_pressed = i == variant_picker.selected
		var chosen: int = i
		button.pressed.connect(func():
			variant_picker.select(chosen)
			set_message(variant_picker.get_item_text(chosen) + " 선택됨 · 맵을 클릭하세요."))
		card.add_child(button)
		var label := Label.new(); label.text = variant_picker.get_item_text(i)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.add_theme_font_size_override("font_size",14); card.add_child(label)

func refresh_objects() -> void:
	if object_picker == null: return
	object_picker.clear()
	object_picker.add_item("배치 목록에서 선택…")
	object_picker.set_item_metadata(0, null)
	for item in doc.objects:
		object_picker.add_item("%s · (%d, %d)" % [str(item.variant), int(item.q), int(item.r)])
		var icon := small_thumbnail_for(str(item.kind),str(item.variant))
		if icon != null: object_picker.set_item_icon(object_picker.item_count-1, icon)
		object_picker.set_item_metadata(object_picker.item_count - 1, Vector2i(int(item.q), int(item.r)))
	object_picker.select(0)

func set_message(text: String) -> void:
	message.text = text

func refresh_maps() -> void:
	var previous := ""
	if saved_maps.selected >= 0: previous = str(saved_maps.get_item_metadata(saved_maps.selected))
	saved_maps.clear()
	var dir := DirAccess.open(store.directory)
	if dir != null:
		var names := dir.get_files(); names.sort()
		for file in names:
			if not file.ends_with(".json"): continue
			var path: String = store.directory.path_join(file)
			var result: Dictionary = store.read(path)
			if result.has("error"): continue
			saved_maps.add_item(str(result.document.name) + "  ·  " + file)
			saved_maps.set_item_metadata(saved_maps.item_count-1,path)
			if path == previous or str(result.document.id) == str(doc.id): saved_maps.select(saved_maps.item_count-1)
	if saved_maps.item_count == 0: saved_maps.add_item("저장된 맵 없음"); saved_maps.set_item_metadata(0,"")

func save_map() -> void:
	doc.name = map_name.text.strip_edges()
	var result: Dictionary = store.save(doc, saved_hash)
	if result.has("error"): set_message("저장 실패: " + str(result.error)); return
	saved_hash = result.hash; dirty = false; refresh_maps()
	set_message("저장 완료: " + str(result.path))

func request_action(action: String, path: String) -> void:
	if dirty:
		pending_action = action; pending_path = path; confirm.popup_centered(); return
	perform_action(action,path)

func perform_action(action: String, path: String) -> void:
	if action == "quit":
		quit()
		return
	if action == "new": doc = store.new_document(); saved_hash = ""
	elif action == "load":
		var result: Dictionary = store.read(path)
		if result.has("error"): set_message("불러오기 실패: " + str(result.error)); return
		var bad := validate_variants(result.document)
		if not bad.is_empty(): set_message("알 수 없는 애셋: " + bad); return
		doc = result.document; saved_hash = result.hash
	map_name.text = doc.name
	radius_picker.value = doc.radius
	dirty = false; history.clear(); selected_cell = Vector2i(999,999); marker.visible = false
	make_board(); rebuild_objects(); refresh_maps(); set_message("새 맵" if action == "new" else "불러오기 완료: " + path)

func validate_variants(data: Dictionary) -> String:
	for item in data.objects:
		var e := Pal.find(str(item.kind), str(item.variant))
		if e.is_empty(): return "%s/%s" % [str(item.kind), str(item.variant)]
		var path := Pal.file_path(e)
		if not path.is_empty() and not FileAccess.file_exists(path): return path
	return ""

## Stored object kind for a palette group (e.g. massif / range / small_mountain -> mountain).
func group_kind(group: String) -> String:
	var list := Pal.in_group(group)
	return str(list[0].kind) if not list.is_empty() else group

func remember() -> void:
	if stroke_active and stroke_saved:
		dirty = true; return
	stroke_saved = stroke_active
	history.append({"objects": doc.objects.duplicate(true), "radius": int(doc.radius), "ground": (doc.get("ground", {}) as Dictionary).duplicate(true)})
	if history.size() > 50: history.pop_front()
	dirty = true

func undo() -> void:
	if history.is_empty(): return
	var old: Dictionary = history.pop_back()
	doc.objects = old.objects; doc.radius = old.radius; doc.ground = old.get("ground", {}); radius_picker.value = doc.radius
	dirty = true; make_board(); rebuild_objects()
	if inside(selected_cell): select_cell(selected_cell)
	else: marker.visible = false; selection.text = "선택된 헥스 없음"
	set_message("이전 상태로 되돌렸습니다.")

func resize_map() -> void:
	var new_radius := int(radius_picker.value)
	if new_radius == int(doc.radius): return
	for item in doc.objects:
		var q := int(item.q); var r := int(item.r)
		if maxi(absi(q),maxi(absi(r),absi(q+r))) > new_radius:
			set_message("맵 밖으로 나가는 배치가 있어 줄일 수 없습니다.")
			radius_picker.value = doc.radius
			return
	remember(); doc.radius = new_radius; make_board()
	set_message("맵 크기 변경됨 · 저장 전")

func index_at(cell: Vector2i) -> int:
	for i in range(doc.objects.size()):
		var item: Dictionary = doc.objects[i]
		if int(item.q) == cell.x and int(item.r) == cell.y: return i
	return -1

func inside(cell: Vector2i) -> bool:
	return maxi(absi(cell.x),maxi(absi(cell.y),absi(cell.x+cell.y))) <= int(doc.radius)

func select_cell(cell: Vector2i) -> void:
	selected_cell = cell
	marker.visible = inside(cell)
	if marker.visible: marker.position = center(cell.x,cell.y) + Vector3.UP*0.08
	var index := index_at(cell)
	selection.text = "헥스 (%d, %d)  ·  %s" % [cell.x,cell.y, str(doc.objects[index].variant) if index >= 0 else "비어 있음"]

func place_at(cell: Vector2i) -> void:
	if not inside(cell): return
	select_cell(cell)
	var group: String = KINDS[tool_picker.selected]
	var kind: String = group_kind(group)
	var index := index_at(cell)
	if group == "select": return
	if group == "ground":
		if variant_picker.selected < 0: return
		var gv := str(variant_picker.get_item_metadata(variant_picker.selected))
		var ground: Dictionary = doc.get("ground", {})
		var key := "%d,%d" % [cell.x, cell.y]
		if str(ground.get(key, "")) == gv: return
		remember(); ground[key] = gv; doc.ground = ground
		build_ground_layer(); set_message("바닥 칠함 · 저장 전"); return
	if group == "erase":
		if cut_piece(cell): return
		if index < 0:
			var g2: Dictionary = doc.get("ground", {})
			var k2 := "%d,%d" % [cell.x, cell.y]
			if g2.has(k2): remember(); g2.erase(k2); build_ground_layer(); set_message("바닥 지움 · 저장 전")
			return
		remember(); doc.objects.remove_at(index); rebuild_objects(); select_cell(cell); return
	if index >= 0:
		var here: Dictionary = doc.objects[index]
		if group == "road" and variant_picker.selected >= 0 and str(variant_picker.get_item_metadata(variant_picker.selected)) == "brush_road" \
				and is_brush(here) and str(here.kind) == "water" and not bool(here.get("bridge", false)):
			remember(); here.bridge = true; rebuild_objects(); select_cell(cell); set_message("다리 놓음 · 저장 전"); return
		if not stroke_active: set_message("이미 배치가 있습니다. 지우거나 선택해 이동하세요.")
		return
	if variant_picker.selected < 0: return
	var variant := str(variant_picker.get_item_metadata(variant_picker.selected))
	var required := asset_path(kind, variant)
	if not required.is_empty() and not FileAccess.file_exists(required): set_message("애셋 파일이 없습니다: " + required); return
	remember()
	doc.objects.append({"kind":kind,"variant":variant,"q":cell.x,"r":cell.y,"rotation":0})
	rebuild_objects(); select_cell(cell); set_message("배치됨 · 저장 전")

## Erase on a multi-hex mountain removes only the piece on that hex (its meshes go into item.cut);
## the whole object goes once nothing of it is left. Returns false when the hex holds no such piece.
func cut_piece(cell: Vector2i) -> bool:
	if not coverage.has(cell): return false
	var entry: Array = coverage[cell]
	var oi: int = entry[0]
	if oi < 0 or oi >= doc.objects.size(): return false
	var item: Dictionary = doc.objects[oi]
	remember()
	var cut: Array = item.get("cut", [])
	for m in entry[1]:
		if not cut.has(m): cut.append(m)
	item.cut = cut
	var left := 0
	for c in coverage.keys():
		if int(coverage[c][0]) == oi and c != cell: left += 1
	if left == 0:
		doc.objects.remove_at(oi); set_message("산 전체 삭제됨 · 저장 전")
	else:
		set_message("산 조각 삭제됨 (%d, %d) · 저장 전" % [cell.x, cell.y])
	rebuild_objects(); select_cell(cell)
	return true

## World position on the board -> axial hex (same rounding as pick_cell).
func world_cell(p: Vector3) -> Vector2i:
	var q := p.x/(1.5*R); var r := p.z/(SQRT3*R) - q*0.5; var y := -q-r
	var iq := roundi(q); var ir := roundi(r); var iy := roundi(y)
	if absf(float(iq)-q)>absf(float(ir)-r) and absf(float(iq)-q)>absf(float(iy)-y): iq = -ir-iy
	elif absf(float(ir)-r)>absf(float(iy)-y): ir = -iq-iy
	return Vector2i(iq,ir)

## Hexes on the straight line a..b (so a fast drag paints without gaps).
func hex_line(a: Vector2i, b: Vector2i) -> Array:
	var n := hex_dist(a, b)
	var out: Array = []
	for i in range(n + 1):
		var t := float(i) / float(maxi(1, n))
		var fq := lerpf(float(a.x), float(b.x), t) + 1e-6
		var fr := lerpf(float(a.y), float(b.y), t) + 1e-6
		var c := world_cell(Vector3(1.5*R*fq, 0, SQRT3*R*(fr + fq*0.5)))
		if out.is_empty() or out[-1] != c: out.append(c)
	return out

## River / road strokes remember the way the drag went: consecutive hexes get a link in both directions,
## so the line follows the stroke (bends stay bends) instead of joining every touching hex.
func link_cells(a: Vector2i, b: Vector2i) -> void:
	var group: String = KINDS[tool_picker.selected]
	if group not in ["water", "road"] or variant_picker.selected < 0: return
	if not str(variant_picker.get_item_metadata(variant_picker.selected)).begins_with("brush"): return
	var d := HEX_DIRS.find(b - a)
	if d < 0: return
	var key := "links"
	var ia := index_at(a); var ib := index_at(b)
	if ia < 0 or ib < 0: return
	for pair in [[ia, d], [ib, (d + 3) % 6]]:
		var it: Dictionary = doc.objects[pair[0]]
		var k := key
		if group == "road" and str(it.kind) == "water": k = "road_links"
		elif str(it.kind) != group: return
		var list: Array = it.get(k, [])
		if not list.has(pair[1]): list.append(pair[1])
		it[k] = list
	rebuild_objects()

func hex_dist(a: Vector2i, b: Vector2i) -> int:
	var dq := a.x - b.x; var dr := a.y - b.y
	return maxi(absi(dq), maxi(absi(dr), absi(dq + dr)))

func is_brush(item: Dictionary) -> bool:
	return str(item.get("variant", "")).begins_with("brush")

## Select mode: press on a painted mountain grabs its whole connected range; anything else grabs that one object.
func begin_drag(cell: Vector2i) -> void:
	drag_group = []; drag_from = cell; drag_to = cell
	var index := index_at(cell)
	if index < 0: return
	if not is_brush(doc.objects[index]):
		drag_group = [index]; return
	var kind := str(doc.objects[index].kind)
	var at := {}
	for i in range(doc.objects.size()):
		if is_brush(doc.objects[i]) and str(doc.objects[i].kind) == kind: at[Vector2i(int(doc.objects[i].q), int(doc.objects[i].r))] = i
	var todo := [cell]
	var seen := {cell: true}
	while not todo.is_empty():
		var c: Vector2i = todo.pop_back()
		drag_group.append(at[c])
		for d in HEX_DIRS:
			var n: Vector2i = c + d
			if at.has(n) and not seen.has(n):
				seen[n] = true; todo.append(n)
	set_message("이어진 %d칸을 잡았습니다 · 끌어서 놓으세요." % drag_group.size())

func preview_drag(cell: Vector2i) -> void:
	if cell == drag_to: return
	drag_to = cell
	var off := center(cell.x, cell.y) - center(drag_from.x, drag_from.y)
	var nodes := placed_root.get_children()
	for i in drag_group:
		if i < nodes.size():
			var it: Dictionary = doc.objects[i]
			(nodes[i] as Node3D).position = center(int(it.q), int(it.r)) + Vector3.UP*0.08 + off + Vector3.UP*3.0

func end_drag() -> void:
	var delta := drag_to - drag_from
	var group := drag_group.duplicate()
	drag_group = []
	if delta == Vector2i.ZERO:
		rebuild_objects(); return
	for i in group:
		var to := Vector2i(int(doc.objects[i].q), int(doc.objects[i].r)) + delta
		var other := index_at(to)
		if not inside(to) or (other >= 0 and not group.has(other)):
			set_message("놓을 자리에 다른 배치가 있거나 맵 밖입니다."); rebuild_objects(); return
	remember()
	for i in group:
		doc.objects[i].q = int(doc.objects[i].q) + delta.x; doc.objects[i].r = int(doc.objects[i].r) + delta.y
	rebuild_objects(); select_cell(drag_to)
	set_message("%d칸 이동됨 · 저장 전" % group.size())

func rotate_selected() -> void:
	var index := index_at(selected_cell)
	if index < 0: return
	remember(); doc.objects[index].rotation = (int(doc.objects[index].rotation) + 1) % 6; rebuild_objects(); set_message("회전됨 · 저장 전")

func move_selected(from: Vector2i, to: Vector2i) -> void:
	var index := index_at(from)
	if index < 0 or not inside(to) or from == to: return
	if index_at(to) >= 0: set_message("목적지 헥스에 다른 배치가 있습니다."); return
	remember(); doc.objects[index].q = to.x; doc.objects[index].r = to.y; rebuild_objects(); select_cell(to); set_message("이동됨 · 저장 전")

func asset_path(kind: String, variant: String) -> String:
	return Pal.file_path(Pal.find(kind, variant))

func glb_scene(path: String) -> Node3D:
	if scene_cache.has(path): return scene_cache[path]
	if not FileAccess.file_exists(path): push_error("[MapEditor] Missing asset: " + path); return null
	var gltf := GLTFDocument.new(); var state := GLTFState.new()
	var err := gltf.append_from_file(path,state)
	if err != OK: push_error("[MapEditor] Cannot import " + path); return null
	var model := gltf.generate_scene(state) as Node3D
	if model == null: return null
	for mesh in model.find_children("*","MeshInstance3D",true,false): mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	scene_cache[path] = model
	return model

func rebuild_objects() -> void:
	_rebuild_objects_only()
	build_path_layer()
	build_ground_layer()

## Ground paint lives in doc.ground {"q,r": variant} on its own layer under objects, rivers and roads.
var ground_root: Node3D
func build_ground_layer() -> void:
	if ground_root == null or not is_instance_valid(ground_root):
		ground_root = Node3D.new(); ground_root.name = "GroundLayer"; stage.add_child(ground_root)
	for c in ground_root.get_children(): c.free()
	var ground: Dictionary = doc.get("ground", {})
	for key in ground.keys():
		var parts := str(key).split(",")
		var e := Pal.find("ground", str(ground[key]))
		if e.is_empty() or parts.size() != 2: continue
		var hex := GroundPaint.build_hex(str(ground[key]), R * 1.005, int(parts[0]) * 7919 + int(parts[1]) * 104729)
		hex.position = center(int(parts[0]), int(parts[1]))
		ground_root.add_child(hex)

## Rivers and roads as continuous chains (map_editor_paths.gd). Old maps without links join touching hexes.
func build_path_layer() -> void:
	var rivers := {}; var roads := {}; var bridges := {}
	for it in doc.objects:
		if not is_brush(it): continue
		var c := Vector2i(int(it.q), int(it.r))
		var all := [0, 1, 2, 3, 4, 5]
		if str(it.kind) == "water":
			rivers[c] = it.get("links", all)
			if bool(it.get("bridge", false)):
				roads[c] = it.get("road_links", all); bridges[c] = true
		elif str(it.kind) == "road":
			roads[c] = it.get("links", all)
	if rivers.is_empty() and roads.is_empty(): return
	var layer := Node3D.new(); layer.name = "PathLayer"; placed_root.add_child(layer)
	if not rivers.is_empty():
		if path_layer_builder == null: path_layer_builder = PathLayer.new()
		path_layer_builder.call("build_rivers", rivers, Callable(self, "center"), layer)
	if not roads.is_empty():
		PathLayer.build_roads(roads, Callable(self, "center"), layer, bridges)

func _rebuild_objects_only() -> void:
	refresh_objects()
	for child in placed_root.get_children(): child.free()
	coverage = {}
	var brush_cells := {}
	var path_cells := {"water": {}, "road": {}}
	for it in doc.objects:
		if not is_brush(it): continue
		var cc := Vector2i(int(it.q), int(it.r))
		if str(it.kind) == "mountain": brush_cells[cc] = true
		elif path_cells.has(str(it.kind)): path_cells[str(it.kind)][cc] = true
		if bool(it.get("bridge", false)): path_cells["road"][cc] = true
	for oi in range(doc.objects.size()):
		var item: Dictionary = doc.objects[oi]
		var group := Node3D.new(); placed_root.add_child(group)
		group.position = center(int(item.q),int(item.r)) + Vector3.UP*0.08
		group.rotation.y = -float(item.rotation)*PI/3.0
		if is_brush(item) and str(item.kind) != "mountain":
			pass   # drawn by build_path_layer() as whole chains
		elif is_brush(item): add_brush_piece(group, item, brush_cells)
		elif item.kind == "forest": add_forest(group,item)
		elif item.kind == "unit": add_unit(group,item)
		else:
			var model := glb_scene(asset_path(item.kind,item.variant))
			if model != null:
				var copy := model.duplicate() as Node3D
				fit_model(copy, Pal.find(str(item.kind), str(item.variant)))
				group.add_child(copy)
				if item.kind == "mountain": apply_cuts(copy, item, oi)

## Every hex of every range25 model becomes a reusable piece (its meshes only, centred on the hex) tagged with
## which of its six neighbours the original range continues into. Built once, then duplicated per painted hex.
func range_pieces() -> Array:
	if not _range_pieces.is_empty(): return _range_pieces
	var a0 := atan2(center(HEX_DIRS[0].x, HEX_DIRS[0].y).z, center(HEX_DIRS[0].x, HEX_DIRS[0].y).x)
	var a1 := atan2(center(HEX_DIRS[1].x, HEX_DIRS[1].y).z, center(HEX_DIRS[1].x, HEX_DIRS[1].y).x)
	_dir_step = wrapf(a1 - a0, -PI, PI)
	for e in Pal.in_group("range"):
		var model := glb_scene(Pal.file_path(e))
		if model == null: continue
		var meshes := model.find_children("*","MeshInstance3D",true,false)
		var by_cell := {}
		for i in range(meshes.size()):
			var mi := meshes[i] as MeshInstance3D
			var xf := Transform3D.IDENTITY
			var n: Node = mi
			while n != null and n != model:
				if n is Node3D: xf = (n as Node3D).transform * xf
				n = n.get_parent()
			var c := world_cell((Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * 0.75), Vector3.ZERO) * xf) * mi.mesh.get_aabb().get_center())
			if not by_cell.has(c): by_cell[c] = []
			by_cell[c].append(i)
		for c in by_cell.keys():
			var mask := 0
			for d in range(6):
				if by_cell.has(c + HEX_DIRS[d]): mask |= 1 << d
			var copy := model.duplicate() as Node3D
			var copy_meshes := copy.find_children("*","MeshInstance3D",true,false)
			for i in range(copy_meshes.size()):
				if not by_cell[c].has(i): copy_meshes[i].free()
			copy.scale = Vector3.ONE * 0.75
			var holder := Node3D.new(); holder.add_child(copy)
			copy.position = -center(c.x, c.y)
			_range_pieces.append({"scene": holder, "mask": mask, "source": str(e.variant)})
	return _range_pieces

static func rot_mask(mask: int, k: int) -> int:
	var out := 0
	for d in range(6):
		if mask & (1 << d): out |= 1 << ((d + k) % 6)
	return out

static func bit_count(m: int) -> int:
	var n := 0
	for d in range(6): n += (m >> d) & 1
	return n

## One painted mountain hex: the range25 piece whose neighbour shape matches the painted neighbours,
## turned by the matching 60-degree step. Ties pick by hex hash so long ranges don't repeat one piece.
func add_brush_piece(group: Node3D, item: Dictionary, cells: Dictionary) -> void:
	var c := Vector2i(int(item.q), int(item.r))
	var want := 0
	for d in range(6):
		if cells.has(c + HEX_DIRS[d]): want |= 1 << d
	var best_score := -99
	var best: Array = []
	for p in range_pieces():
		for k in range(6):
			var m := rot_mask(int(p.mask), k)
			var score := 6 - bit_count(m ^ want)
			if score > best_score: best_score = score; best = []
			if score == best_score: best.append([p, k])
	if best.is_empty(): return
	var pick: Array = best[posmod(c.x * 73 + c.y * 31, best.size())]
	var node := (pick[0].scene as Node3D).duplicate() as Node3D
	group.rotation.y = 0.0
	node.rotation.y = -_dir_step * float(pick[1])
	group.add_child(node)

## One painted river / road hex: a smooth strip from each painted neighbour's shared edge to this hex.
## Two neighbours -> one curve through the centre; one -> a rounded end; three or more -> spokes meeting
## in a rounded junction. Strips end on the shared edge midpoint facing straight across it, so neighbouring
## hexes always meet without a seam: the line grows progressively as you drag.
func add_path_piece(group: Node3D, item: Dictionary, cells: Dictionary) -> void:
	var c := Vector2i(int(item.q), int(item.r))
	var mids: Array = []
	for d in range(6):
		if cells.has(c + HEX_DIRS[d]):
			mids.append((center(c.x + HEX_DIRS[d].x, c.y + HEX_DIRS[d].y) - center(c.x, c.y)) * 0.5)
	group.rotation.y = 0.0
	var river := str(item.kind) == "water"
	var layers: Array = [[26.0, 0.10, Color("6b6a45")], [17.0, 0.22, Color("3f7f8c")]] if river else [[8.2, 0.10, Color("6d5a3c")], [6.4, 0.16, Color("9c8358")]]
	if str(item.kind) == "bridge": layers = [[9.0, 1.4, Color("5a4026")], [7.4, 1.5, Color("8a6a43")]]
	for layer in layers:
		var tool := SurfaceTool.new(); tool.begin(Mesh.PRIMITIVE_TRIANGLES)
		var w: float = layer[0] * 0.5
		var y: float = layer[1]
		if mids.size() == 2:
			var pts: Array = []
			for i in range(13):
				var t := float(i) / 12.0
				pts.append(mids[0] * (1.0 - t) * (1.0 - t) + mids[1] * t * t)
			_strip(tool, pts, w, y)
		else:
			for m in mids: _strip(tool, [Vector3.ZERO, m], w, y)
			_disc(tool, w * (1.15 if mids.size() >= 3 else 1.0), y)
		var mi := MeshInstance3D.new(); mi.mesh = tool.commit()
		var mat := StandardMaterial3D.new(); mat.cull_mode = BaseMaterial3D.CULL_DISABLED; mat.albedo_color = layer[2]; mat.roughness = 0.25 if (river and y > 0.2) else 1.0
		if river and y > 0.2: mat.metallic_specular = 0.8
		mi.material_override = mat; mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		group.add_child(mi)

func _strip(tool: SurfaceTool, pts: Array, w: float, y: float) -> void:
	for i in range(pts.size() - 1):
		var a: Vector3 = pts[i]; var b: Vector3 = pts[i + 1]
		var dir := (b - a); dir.y = 0.0
		if dir.length() < 0.001: continue
		var side := Vector3(-dir.z, 0, dir.x).normalized() * w
		var up := Vector3.UP * y
		_tri(tool, a - side + up, b - side + up, b + side + up)
		_tri(tool, a - side + up, b + side + up, a + side + up)
	# round the ends so joins between hexes never show a corner
	_disc_at(tool, pts[0], w, y); _disc_at(tool, pts[-1], w, y)

func _disc(tool: SurfaceTool, r: float, y: float) -> void:
	_disc_at(tool, Vector3.ZERO, r, y)

func _disc_at(tool: SurfaceTool, at: Vector3, r: float, y: float) -> void:
	for i in range(16):
		var a0 := TAU * float(i) / 16.0; var a1 := TAU * float(i + 1) / 16.0
		var up := Vector3.UP * y
		_tri(tool, at + up, at + Vector3(cos(a1), 0, sin(a1)) * r + up, at + Vector3(cos(a0), 0, sin(a0)) * r + up)

## Every triangle faces up (clockwise seen from above, Godot's front face), so no strip is lit from behind.
func _tri(tool: SurfaceTool, a: Vector3, b: Vector3, c: Vector3) -> void:
	if (b - a).cross(c - a).y > 0.0:
		var t := b; b = c; c = t
	for v in [a, b, c]:
		tool.set_normal(Vector3.UP); tool.add_vertex(v)

## Multi-hex mountains are one mesh per hex (massif: hex_q_r, ranges: several per hex). Cut meshes are freed,
## the rest are mapped to board hexes; item.cells keeps the covered hexes so the importer can mark them all.
func apply_cuts(model: Node3D, item: Dictionary, oi: int) -> void:
	var meshes := model.find_children("*","MeshInstance3D",true,false)
	if meshes.size() <= 1:
		item.erase("cells"); return
	var cut: Array = item.get("cut", [])
	var cells := {}
	for i in range(meshes.size()):
		var mi := meshes[i] as MeshInstance3D
		if cut.has(i) or cut.has(float(i)):
			mi.queue_free(); continue
		var c := world_cell(mi.global_transform * mi.mesh.get_aabb().get_center())
		if not coverage.has(c): coverage[c] = [oi, []]
		if int(coverage[c][0]) == oi: coverage[c][1].append(i)
		cells[c] = true
	var out: Array = []
	for c in cells.keys(): out.append([c.x, c.y])
	out.sort()
	item.cells = out

## Palette sizing: `fit` > 0 scales the widest horizontal side to `fit` editor units and sets the base on the ground.
func fit_model(model: Node3D, e: Dictionary) -> void:
	var fit := float(e.get("fit", 0.0))
	if fit <= 0.0:
		model.scale = Vector3.ONE * float(e.get("scale", 1.0)); return
	var b := {"min": Vector3.INF, "max": -Vector3.INF}
	_bounds(model, Transform3D.IDENTITY, b)
	if b.min == Vector3.INF: return
	var ext: Vector3 = b.max - b.min
	var sc := fit / maxf(0.001, maxf(ext.x, ext.z))
	model.scale = Vector3.ONE * sc
	model.position = Vector3(-(b.min.x + b.max.x) * 0.5 * sc, -b.min.y * sc, -(b.min.z + b.max.z) * 0.5 * sc)

func _bounds(n: Node, xf: Transform3D, b: Dictionary) -> void:
	var t := xf
	if n is Node3D: t = xf * (n as Node3D).transform
	if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
		var box: AABB = (n as MeshInstance3D).mesh.get_aabb()
		for i in range(8):
			var p := t * box.get_endpoint(i)
			b.min = Vector3(minf(b.min.x,p.x),minf(b.min.y,p.y),minf(b.min.z,p.z)); b.max = Vector3(maxf(b.max.x,p.x),maxf(b.max.y,p.y),maxf(b.max.z,p.z))
	for c in n.get_children(): _bounds(c, t, b)

## Units use the asset library's own formations (unit_lod_manager). Marked so the bake can drop them.
func add_unit(group: Node3D, item: Dictionary) -> void:
	group.set_meta("editor_unit", true)
	if unit_loader == null:
		unit_loader = preload("res://tools/dev_visual_lab/visual_resource_remap.gd").new()
		ResourceLoader.add_resource_format_loader(unit_loader, true)
	var parts := str(item.variant).rsplit("_", true, 1)
	var cls := parts[0]; var faction := parts[1] if parts.size() > 1 else "blue"
	var mgr := UnitManager.new(); mgr.camera = camera; group.add_child(mgr)
	var count := 1 if cls == "hq" else (3 if cls == "cavalry" else 9)
	mgr.add_formation(cls, faction, count, 12.0 if cls == "hq" else 9.6, Vector3.ZERO, 20261114 + int(item.q) * 41 + int(item.r), Vector2i(int(item.q), int(item.r)))
	mgr.forced_detail = 0

func add_forest(group: Node3D, item: Dictionary) -> void:
	var offsets := [Vector2(-10,-3),Vector2(-5,-8),Vector2(2,-9),Vector2(9,-5),Vector2(-9,4),Vector2(-3,0),Vector2(4,-2),Vector2(10,3),Vector2(-5,8),Vector2(2,7),Vector2(6,5)]
	for i in range(offsets.size()):
		var key := "tall_pine" if item.variant == "pine" or i%2 == 0 else "broadleaf"
		var source := glb_scene(Paths.output("full-map-lab/optimized/"+key+"_mid.glb"))
		if source == null: continue
		var model := source.duplicate() as Node3D
		var bounds: Dictionary = Lib.bounds(key)
		var extent: Vector3 = bounds.max - bounds.min
		var sc := 8.0 / maxf(extent.x,extent.z)
		model.scale = Vector3.ONE * sc
		model.position = Vector3(offsets[i].x, -float(bounds.min.y)*sc, offsets[i].y)
		model.rotation.y = float(posmod(int(item.q)*13+int(item.r)*7+i*5,12))*PI/6.0
		group.add_child(model)

func update_camera() -> void:
	var direction := Vector3(sin(yaw)*cos(orbit),sin(orbit),cos(yaw)*cos(orbit))
	camera.position = target + direction*1800
	camera.look_at(target)

func pick_cell(pos: Vector2) -> Vector2i:
	var origin := camera.project_ray_origin(pos); var dir := camera.project_ray_normal(pos)
	if absf(dir.y) < 0.00001: return Vector2i(999,999)
	var p: Vector3 = origin + dir * (-origin.y/dir.y)
	var q := p.x/(1.5*R); var r := p.z/(SQRT3*R) - q*0.5; var y := -q-r
	var iq := roundi(q); var ir := roundi(r); var iy := roundi(y)
	if absf(float(iq)-q)>absf(float(ir)-r) and absf(float(iq)-q)>absf(float(iy)-y): iq = -ir-iy
	elif absf(float(ir)-r)>absf(float(iy)-y): ir = -iq-iy
	return Vector2i(iq,ir)

func zoom_camera(closer: bool) -> void:
	camera.size = maxf(30.0,camera.size*0.86) if closer else minf(3000.0,camera.size/0.86)
	update_camera()

func handle_world_input(event: InputEvent) -> void:
	if camera == null or panel == null: return
	if event is InputEventMouseButton:
		if panel.get_global_rect().has_point(event.position) or (palette_panel != null and palette_panel.get_global_rect().has_point(event.position)): return
		if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed: zoom_camera(true)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed: zoom_camera(false)
		elif event.button_index == MOUSE_BUTTON_RIGHT: rotating = event.pressed
		elif event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed and root.gui_get_focus_owner() is LineEdit:
				root.gui_get_focus_owner().release_focus()
			var cell := pick_cell(event.position)
			if event.pressed:
				if move_pending:
					move_pending = false
					move_selected(selected_cell, cell)
					pressed_cell = Vector2i(999,999)
					return
				pressed_cell = cell
				if KINDS[tool_picker.selected] != "select":
					stroke_active = true; stroke_saved = false; stroke_last = cell
					place_at(cell)
				elif inside(cell):
					select_cell(cell)
					begin_drag(cell)
			else:
				if KINDS[tool_picker.selected] == "select" and not drag_group.is_empty(): end_drag()
				stroke_active = false; stroke_saved = false
	elif event is InputEventMouseMotion and (event.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0 and not rotating:
		if panel.get_global_rect().has_point(event.position) or (palette_panel != null and palette_panel.get_global_rect().has_point(event.position)): return
		var cell := pick_cell(event.position)
		if KINDS[tool_picker.selected] == "select":
			if not drag_group.is_empty(): preview_drag(cell)
		elif stroke_active and cell != stroke_last:
			var prev := stroke_last
			for c in hex_line(stroke_last, cell):
				if c == stroke_last: continue
				place_at(c)
				link_cells(prev, c)
				prev = c
			stroke_last = cell
	elif event is InputEventMouseMotion and rotating:
		yaw -= event.relative.x*0.006; orbit = clampf(orbit+event.relative.y*0.004,0.35,1.42); update_camera()
	elif event is InputEventKey and event.pressed and not event.echo:
		if root.gui_get_focus_owner() is LineEdit: return
		if event.keycode == KEY_HOME: target = Vector3.ZERO; camera.size = maxf(280.0,float(doc.radius)*36.0); update_camera()
		elif event.keycode == KEY_R: rotate_selected()
		elif event.keycode == KEY_Z and event.ctrl_pressed: undo()
		elif event.keycode == KEY_DELETE:
			var index := index_at(selected_cell)
			if index >= 0: remember(); doc.objects.remove_at(index); rebuild_objects(); select_cell(selected_cell)

func _process(delta: float) -> bool:
	if camera == null or root.gui_get_focus_owner() is LineEdit: return false
	var move := Vector3.ZERO
	if Input.is_key_pressed(KEY_W): move.z -= 1
	if Input.is_key_pressed(KEY_S): move.z += 1
	if Input.is_key_pressed(KEY_A): move.x -= 1
	if Input.is_key_pressed(KEY_D): move.x += 1
	if move != Vector3.ZERO: target += move.normalized().rotated(Vector3.UP,yaw)*delta*camera.size*0.6; update_camera()
	return false

func smoke_click(cell: Vector2i, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	event.position = camera.unproject_position(center(cell.x,cell.y))
	root.push_input(event, true)

func smoke_test() -> void:
	# Uses a caller-provided isolated save directory, never the user's map folder.
	await process_frame
	for spec in [[1,Vector2i(0,0)],[2,Vector2i(3,-1)],[3,Vector2i(-3,1)],[4,Vector2i(1,3)]]:
		tool_picker.select(spec[0]); update_variants()
		smoke_click(spec[1], true); smoke_click(spec[1], false)
	assert(doc.objects.size() == 4)
	tool_picker.select(0); update_variants()
	for i in range(5): await process_frame
	await RenderingServer.frame_post_draw
	var before_path := OS.get_environment("SG_EDITOR_TEST_BEFORE_ZOOM_SCREENSHOT")
	if not before_path.is_empty(): assert(root.get_texture().get_image().save_png(before_path) == OK)
	var old_size := camera.size
	var zoom := InputEventMouseButton.new(); zoom.button_index = MOUSE_BUTTON_WHEEL_UP; zoom.pressed = true; zoom.position = Vector2(800,400); root.push_input(zoom, true)
	assert(camera.size < old_size)
	await process_frame
	await RenderingServer.frame_post_draw
	var zoomed := root.get_texture().get_image()
	var zoom_path := OS.get_environment("SG_EDITOR_TEST_ZOOM_SCREENSHOT")
	if not zoom_path.is_empty(): assert(zoomed.save_png(zoom_path) == OK)
	var zoom_out := InputEventMouseButton.new(); zoom_out.button_index = MOUSE_BUTTON_WHEEL_DOWN; zoom_out.pressed = true; zoom_out.position = Vector2(800,400); root.push_input(zoom_out, true)
	assert(is_equal_approx(camera.size, old_size))
	var right := InputEventMouseButton.new(); right.button_index = MOUSE_BUTTON_RIGHT; right.pressed = true; right.position = Vector2(800,400); root.push_input(right, true)
	var old_yaw := yaw
	var motion := InputEventMouseMotion.new(); motion.position = Vector2(820,400); motion.relative = Vector2(20,0); root.push_input(motion, true)
	assert(yaw != old_yaw)
	right.pressed = false; root.push_input(right, true)
	yaw = old_yaw; update_camera()
	smoke_click(Vector2i(0,0),true); smoke_click(Vector2i(0,1),false)
	assert(index_at(Vector2i(0,1)) >= 0 and index_at(Vector2i(0,0)) < 0)
	rotate_selected(); assert(int(doc.objects[index_at(Vector2i(0,1))].rotation) == 1)
	undo(); assert(int(doc.objects[index_at(Vector2i(0,1))].rotation) == 0)
	radius_picker.value = 12; resize_map(); assert(int(doc.radius) == 12)
	undo(); assert(int(doc.radius) == 10)
	radius_picker.value = 40; resize_map(); assert(int(doc.radius) == 40)
	undo(); assert(int(doc.radius) == 10)
	select_cell(Vector2i(3,-1)); move_pending = true
	smoke_click(Vector2i(4,-1),true); smoke_click(Vector2i(4,-1),false)
	assert(index_at(Vector2i(4,-1)) >= 0 and index_at(Vector2i(3,-1)) < 0)
	undo(); assert(index_at(Vector2i(3,-1)) >= 0)
	request_action("new", "")
	assert(confirm.visible and doc.objects.size() == 4)
	confirm.hide()
	map_name.text = "검증용 맵"
	save_map(); assert(not saved_hash.is_empty() and not dirty)
	var path: String = store.path_for(doc.id)
	var loaded: Dictionary = store.read(path)
	print("[MapEditor] saved reload result=", loaded.has("error"))
	assert(not loaded.has("error") and JSON.stringify(loaded.document.objects) == JSON.stringify(doc.objects))
	print("[MapEditor] reload matched")
	var external := FileAccess.open(path,FileAccess.READ_WRITE)
	external.seek_end(); external.store_string(" "); external.close()
	assert(store.save(doc,saved_hash).has("error"))
	print("[MapEditor] conflict rejected")
	perform_action("load",path)
	assert(not dirty and doc.objects.size() == 4)
	var bad := doc.duplicate(true); bad.objects.append(bad.objects[0].duplicate(true))
	assert(not store.validate(bad).is_empty())
	await process_frame
	print("[MapEditor] waiting render")
	await RenderingServer.frame_post_draw
	var shot := OS.get_environment("SG_EDITOR_TEST_SCREENSHOT")
	if not shot.is_empty():
		var image_error := root.get_texture().get_image().save_png(shot)
		assert(image_error == OK)
	print("[MapEditor] SMOKE_PASS placement=4 drag list_move rotate undo radius40 unsaved_guard save reload conflict duplicate wheel_in_out right_drag event_dispatch camera_pick")
	quit()

func _finalize() -> void:
	for model in scene_cache.values():
		if is_instance_valid(model): model.free()
	scene_cache.clear()

func reopen_test() -> void:
	await process_frame
	var directory := DirAccess.open(store.directory)
	assert(directory != null)
	var found := ""
	for file in directory.get_files():
		if file.ends_with(".json"): found = store.directory.path_join(file); break
	assert(not found.is_empty())
	perform_action("load", found)
	assert(doc.objects.size() == 4 and str(doc.name) == "검증용 맵" and not dirty)
	print("[MapEditor] REOPEN_PASS objects=4 name=검증용 맵")
	quit()

func palette_click(control: Control) -> void:
	var pos := control.get_global_rect().get_center()
	var event := InputEventMouseButton.new(); event.button_index = MOUSE_BUTTON_LEFT
	event.position = pos; event.global_position = pos; event.pressed = true; root.push_input(event, true)
	event.pressed = false; root.push_input(event, true)

func palette_smoke_test() -> void:
	for i in range(5): await process_frame
	for category in [1,2,3,4]:
		var category_button := palette_panel.find_child("PaletteCategory%d" % category, true, false) as Button
		assert(category_button != null)
		palette_click(category_button)
		for i in range(3): await process_frame
		assert(tool_picker.selected == category)
		var expected := 2 if category == 1 else (25 if category == 2 else (4 if category == 3 else 7))
		assert(variant_picker.item_count == expected and palette_grid.get_child_count() == expected)
		for i in range(expected):
			var card_button := palette_grid.find_child("PaletteItem%d" % i, true, false) as Button
			assert(card_button != null and card_button.icon != null)
		if category == 2:
			var scroll := palette_panel.find_child("PaletteScroll", true, false) as ScrollContainer
			scroll.scroll_vertical = 99999
			for frame in range(3): await process_frame
			var last := palette_grid.find_child("PaletteItem24", true, false) as Button
			assert(scroll.get_global_rect().has_point(last.get_global_rect().get_center()))
			palette_click(last)
			assert(variant_picker.selected == 24 and last.button_pressed)
		if category == 3:
			var button := palette_grid.find_child("PaletteItem2", true, false) as Button
			palette_click(button)
			assert(variant_picker.selected == 2 and button.button_pressed)
			assert(str(variant_picker.get_item_metadata(2)) == "castle_v3")
			smoke_click(Vector2i(0,0),true); smoke_click(Vector2i(0,0),false)
			assert(doc.objects.size() == 1 and doc.objects[0].variant == "castle_v3")
			await RenderingServer.frame_post_draw
			var screenshot := OS.get_environment("SG_PALETTE_TEST_SCREENSHOT")
			if not screenshot.is_empty(): assert(root.get_texture().get_image().save_png(screenshot) == OK)
	print("[MapEditor] PALETTE_PASS 38 icons; category, scroll and card clicks through GUI; castle_v3 placed")
	quit()
