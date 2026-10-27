extends Control

## DEV / RESEARCH: map collection window (title screen, DEV section only).
##
## Lists battlefield sets that are not part of the production flow. Today it
## holds one set, the ten RL battlefields (rl_canonical_v1, see
## scripts/battlefields/battlefield_catalog.gd). Choosing a map sets
## BattlefieldCatalog.pending_id and opens the standard battle shell on it.
## The title screen resets pending_id on entry, so the production battle
## button and the other DEV entries always use the default map.
## Runtime-built UI; no .tscn, no gameplay or AI configuration is touched.

const BattlefieldCatalogScript = preload("res://scripts/battlefields/battlefield_catalog.gd")
const HandcraftedCatalogScript = preload("res://scripts/battlefields/handcrafted_battlefield_catalog.gd")
const TutorialCatalogScript = preload("res://scripts/battlefields/tutorial_battlefield_catalog.gd")
const SHELL_SCENE := "res://scenes/step2r_battlefield_shell.tscn"
const MISSION_PLAY_SCENE := "res://scenes/mission_play.tscn"
const MissionPlayMountScript = preload("res://scripts/gx_missions/mission_play_mount.gd")
const AssetLibraryEntry = preload("res://scripts/ui/dev_asset_library_entry.gd")

const COL_BG := Color(0.08, 0.08, 0.09, 0.97)
const COL_ROW := Color(0.12, 0.12, 0.13, 0.95)
const COL_GOLD := Color(0.83, 0.69, 0.38)
const COL_SILK := Color(0.93, 0.91, 0.85)
const COL_DIM := Color(0.66, 0.66, 0.62)

var _list: VBoxContainer = null


func _ready() -> void:
	name = "DevMapCollectionPanel"
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.62)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(1180, 800)
	panel.add_theme_stylebox_override("panel", _box(COL_BG, COL_GOLD, 2, 6))
	center.add_child(panel)
	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 18)
	panel.add_child(margin)
	var root_box := VBoxContainer.new()
	root_box.add_theme_constant_override("separation", 10)
	margin.add_child(root_box)

	var header := HBoxContainer.new()
	root_box.add_child(header)
	var title := Label.new()
	title.text = "DEV · 맵 모음 (Map Collection)"
	title.add_theme_font_size_override("font_size", 24)
	title.add_theme_color_override("font_color", COL_GOLD)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	var close := Button.new()
	close.name = "CloseButton"
	close.text = "닫기"
	close.custom_minimum_size = Vector2(110, 38)
	close.pressed.connect(close_panel)
	header.add_child(close)

	var note := Label.new()
	note.text = "프로덕션 전장이 아닌 맵 세트입니다. 선택한 맵은 표준 전투 셸에서 열리며, 기존 모드와 기본 전장에는 영향을 주지 않습니다."
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.add_theme_font_size_override("font_size", 14)
	note.add_theme_color_override("font_color", COL_DIM)
	root_box.add_child(note)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root_box.add_child(scroll)
	_list = VBoxContainer.new()
	_list.name = "MapList"
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 6)
	scroll.add_child(_list)
	_populate()


func open() -> void:
	visible = true
	move_to_front()


func close_panel() -> void:
	visible = false


func _unhandled_input(event: InputEvent) -> void:
	if visible and event.is_action_pressed("ui_cancel"):
		close_panel()
		get_viewport().set_input_as_handled()


## Row ids in display order (tools / probes use this).
func map_ids() -> Array:
	return BattlefieldCatalogScript.ids()


func _populate() -> void:
	var library_map := Button.new()
	library_map.name = "OpenAssetLibraryMap"
	library_map.text = "애셋 라이브러리 맵 — 산맥 25종 · 숲 · 마을 · 농작지 · 물길"
	library_map.tooltip_text = "전체 경관을 함께 배치한 DEV 맵. 휠 확대/축소 · 우클릭 회전 · WASD 이동 · Home 전체 보기"
	library_map.custom_minimum_size = Vector2(0,52)
	library_map.add_theme_font_size_override("font_size",18)
	library_map.pressed.connect(func(): AssetLibraryEntry.open_library())
	_list.add_child(library_map)
	var scaled_map := Button.new()
	scaled_map.name = "OpenScaledSceneryMap"
	scaled_map.text = "확대 경관 (후보)"
	scaled_map.tooltip_text = "경관 규모 확대 및 25종 다층 산맥 전시장 DEV 맵. 휠 확대/축소 · 우클릭 회전 · WASD 이동 · Home 전체 보기 · M 전시장 전환"
	scaled_map.custom_minimum_size = Vector2(0, 52)
	scaled_map.add_theme_font_size_override("font_size", 18)
	scaled_map.pressed.connect(func(): AssetLibraryEntry.open_scaled_library())
	_list.add_child(scaled_map)
	var full_map := Button.new()
	full_map.name = "OpenExistingProductionLayout"
	full_map.text = "Full map asset transplant - existing production layout (R=40, 4,921 hexes)"
	full_map.custom_minimum_size = Vector2(0, 52)
	full_map.add_theme_font_size_override("font_size", 18)
	full_map.pressed.connect(open_default_production_map)
	_list.add_child(full_map)
	var tutorial_label := Label.new()
	tutorial_label.text = "五关教学战场  ·  5 maps  ·  shared optimized production runtime"
	tutorial_label.add_theme_font_size_override("font_size", 17)
	tutorial_label.add_theme_color_override("font_color", COL_GOLD)
	_list.add_child(tutorial_label)
	for id in TutorialCatalogScript.ids():
		var tutorial: Dictionary = TutorialCatalogScript.summary_of(str(id))
		if not tutorial.is_empty():
			_list.add_child(_row(tutorial, "TutorialRow"))
	var divider_tutorial := HSeparator.new()
	_list.add_child(divider_tutorial)
	var handmade_label := Label.new()
	handmade_label.text = "%s  ·  실제 플레이 전장" % HandcraftedCatalogScript.SET_TITLE
	handmade_label.add_theme_font_size_override("font_size", 17)
	handmade_label.add_theme_color_override("font_color", COL_GOLD)
	_list.add_child(handmade_label)
	for id in HandcraftedCatalogScript.ids():
		var handmade: Dictionary = HandcraftedCatalogScript.summary_of(str(id))
		if not handmade.is_empty():
			_list.add_child(_row(handmade, "HandcraftedRow"))
	var divider := HSeparator.new()
	_list.add_child(divider)
	var set_label := Label.new()
	set_label.text = "%s  ·  %d maps  ·  set %s" % [BattlefieldCatalogScript.SET_TITLE, map_ids().size(), BattlefieldCatalogScript.SET_ID]
	set_label.add_theme_font_size_override("font_size", 17)
	set_label.add_theme_color_override("font_color", COL_SILK)
	_list.add_child(set_label)
	for id in map_ids():
		var s: Dictionary = BattlefieldCatalogScript.summary_of(str(id))
		if s.is_empty():
			continue
		_list.add_child(_row(s))


func _row(s: Dictionary, prefix: String = "Row") -> Control:
	var row := PanelContainer.new()
	row.name = "%s_%s" % [prefix, s["id"]]
	row.add_theme_stylebox_override("panel", _box(COL_ROW, Color(0.35, 0.30, 0.20, 0.9), 1, 4))
	var m := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		m.add_theme_constant_override("margin_" + side, 8)
	row.add_child(m)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 14)
	m.add_child(h)
	var id_label := Label.new()
	id_label.text = str(s["id"])
	id_label.custom_minimum_size = Vector2(64, 0)
	id_label.add_theme_font_size_override("font_size", 20)
	id_label.add_theme_color_override("font_color", COL_GOLD)
	h.add_child(id_label)
	var text := VBoxContainer.new()
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(text)
	var name_label := Label.new()
	var units: Dictionary = s.get("units", {})
	var sh: Array = s.get("strongholds", [])
	name_label.text = "%s  %s    BLUE %d · RED %d%s" % [s["name"], s["name_zh"], int(units.get("blue", 0)), int(units.get("red", 0)), ("    " + ", ".join(sh)) if not sh.is_empty() else ""]
	name_label.add_theme_font_size_override("font_size", 17)
	name_label.add_theme_color_override("font_color", COL_SILK)
	text.add_child(name_label)
	var tac := Label.new()
	tac.text = str(s["tactical"])
	tac.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	tac.add_theme_font_size_override("font_size", 13)
	tac.add_theme_color_override("font_color", COL_DIM)
	text.add_child(tac)
	var btn := Button.new()
	btn.name = "Open_%s" % s["id"]
	btn.text = "전장 열기"
	btn.custom_minimum_size = Vector2(120, 44)
	btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	btn.pressed.connect(open_map.bind(str(s["id"])))
	h.add_child(btn)
	return row


## Opens the battle shell on `id` (RL set). The only place pending_id is set.
func open_map(id: String) -> void:
	if not TutorialCatalogScript.has_battlefield(id) and not BattlefieldCatalogScript.has_battlefield(id) and not HandcraftedCatalogScript.has_battlefield(id):
		push_error("[DevMapCollection] unknown map %s" % id)
		return
	var am: Node = get_node_or_null("/root/AudioManager")
	if am != null:
		am.call("play_sfx", "ui_select")
	# Tutorial M1-M5: played under MissionRules + mission GX (MissionPlayMount), not the plain shell.
	if TutorialCatalogScript.FILES.has(id.to_upper()) and not BattlefieldCatalogScript.has_battlefield(id) 			and not HandcraftedCatalogScript.has_battlefield(id):
		get_tree().root.set_meta(MissionPlayMountScript.META, MissionPlayMountScript.pick(id.to_upper(), {"source": "tutorial"}))
		print("[DevMapCollection] open tutorial %s -> %s" % [id, MISSION_PLAY_SCENE])
		get_tree().change_scene_to_file(MISSION_PLAY_SCENE)
		return
	BattlefieldCatalogScript.pending_id = id.to_upper()
	print("[DevMapCollection] open %s -> %s" % [id, SHELL_SCENE])
	get_tree().change_scene_to_file(SHELL_SCENE)


static func _box(bg: Color, border: Color, bw: int, radius: int) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.border_width_left = bw
	sb.border_width_top = bw
	sb.border_width_right = bw
	sb.border_width_bottom = bw
	sb.corner_radius_top_left = radius
	sb.corner_radius_top_right = radius
	sb.corner_radius_bottom_right = radius
	sb.corner_radius_bottom_left = radius
	return sb


## DEV inspection entry to the existing production layout, without a new map or scene.
func open_default_production_map() -> void:
	BattlefieldCatalogScript.pending_id = ""
	print("[DevMapCollection] existing production layout -> " + SHELL_SCENE)
	get_tree().change_scene_to_file(SHELL_SCENE)
