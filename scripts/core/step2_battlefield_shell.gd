class_name Step2BattlefieldShell
extends Node2D

## Step2BattlefieldShell — Main Controller for Step 2 Battlefield Shell
## Validates Direction A terrain, 36x24 grid, 7 unit classes in Blue/Red, Form A badges, and tactical camera.

const GRID_Q: int = 36
const GRID_R: int = 24

var HexUtilsCls: Script = preload("res://scripts/core/hex_utils.gd")
var HexCellCls: Script = preload("res://scripts/core/hex_cell.gd")
var HexGridCls: Script = preload("res://scripts/core/hex_grid.gd")
var Step2UnitRendererCls: Script = preload("res://scripts/core/step2_unit_renderer.gd")
var Step2CameraControllerCls: Script = preload("res://scripts/core/step2_camera_controller.gd")

var hex_grid: Node2D
var unit_renderer: Node2D
var camera: Camera2D

var hud_layer: CanvasLayer
var status_banner: Panel
var status_title: Label
var status_subtitle: Label
var info_label: Label
var controls_label: Label

var _current_hover_hex: Vector2i = Vector2i(-999, -999)

func _ready() -> void:
	_setup_scene_nodes()
	_generate_direction_a_battlefield()
	_deploy_test_armies()
	_setup_camera_and_bounds()
	_setup_hud()
	_connect_events()

func _setup_scene_nodes() -> void:
	hex_grid = get_node_or_null("HexGrid") as Node2D
	if hex_grid == null:
		hex_grid = HexGridCls.new() as Node2D
		hex_grid.name = "HexGrid"
		add_child(hex_grid)
	
	unit_renderer = get_node_or_null("UnitRenderer") as Node2D
	if unit_renderer == null:
		unit_renderer = Step2UnitRendererCls.new() as Node2D
		unit_renderer.name = "UnitRenderer"
		add_child(unit_renderer)
	
	camera = get_node_or_null("Camera2D") as Camera2D
	if camera == null:
		camera = Step2CameraControllerCls.new() as Camera2D
		camera.name = "Camera2D"
		add_child(camera)
	
	hud_layer = get_node_or_null("CanvasLayer") as CanvasLayer
	if hud_layer == null:
		hud_layer = CanvasLayer.new()
		hud_layer.name = "CanvasLayer"
		hud_layer.layer = 20
		add_child(hud_layer)

func _generate_direction_a_battlefield() -> void:
	hex_grid.set("cell_data", {})
	hex_grid.set("grid_size_q", GRID_Q)
	hex_grid.set("grid_size_r", GRID_R)
	var cell_data_dict: Dictionary = hex_grid.get("cell_data")
	
	# Terrain Types:
	# 0: Plains, 1: Mountains, 2: Forest, 3: Swamp, 4: Fortress, 5: Village, 6: Road, 7: River, 8: Wall
	for q in range(GRID_Q):
		for r in range(GRID_R):
			var t: int = 0 # default Plains
			
			# 1. Northern Ridge & Western Mountain Peaks
			if r <= 2 and (q >= 6 and q <= 33):
				t = 1 # Mountains
			elif q <= 2 and r >= 14:
				t = 1 # Western Mountains
			elif (q == 19 or q == 20) and r <= 4:
				t = 1 # Pass Peaks
			
			# 2. Central River Moat (winding north to south around q=17..19)
			elif (q == 17 and r >= 5 and r <= 9) or (q == 18 and (r >= 9 and r <= 15)) or (q == 19 and r >= 15 and r <= 23):
				t = 7 # River
			
			# 3. Fortress Complex (Northeast sector: q=27..32, r=5..10)
			elif (q >= 28 and q <= 31) and (r >= 6 and r <= 9):
				t = 4 # Fortress interior
			elif (q == 27 or q == 32) and (r >= 5 and r <= 10):
				t = 8 # Defensive Wall
			elif (q >= 27 and q <= 32) and (r == 5 or r == 10):
				t = 8 # Defensive Wall
			
			# 4. Swamps: River meanders & lowlands
			elif (q == 16 and r >= 12 and r <= 15) or (q == 20 and r >= 17 and r <= 19):
				t = 3 # Swamp
			
			# 5. Forest Groves: West Woods, Ambush Thicket, Mountain Forest, East Ridge
			elif (q >= 4 and q <= 7) and (r >= 5 and r <= 8):
				t = 2 # West Forest
			elif (q >= 13 and q <= 15) and (r >= 13 and r <= 16):
				t = 2 # Ambush Thicket
			elif (q >= 22 and q <= 24) and (r >= 2 and r <= 5):
				t = 2 # Mountain Forest
			elif (q >= 32 and q <= 34) and (r >= 14 and r <= 18):
				t = 2 # Eastern Woods
			
			# 6. Settlements: Southwest & Southeast villages
			elif (q == 5 and r == 16) or (q == 6 and r == 17) or (q == 25 and r == 18) or (q == 26 and r == 17):
				t = 5 # Village
			
			# 7. Road Network: East-West highway crossing river bridge, linking villages and fortress
			elif r == 11 and (q >= 0 and q <= 35):
				t = 6 # Main Highway
			elif q == 27 and r == 11:
				t = 6 # Fortress Gate Bridge Road
			elif (q == 6 and r >= 12 and r <= 16) or (q == 26 and r >= 12 and r <= 16):
				t = 6 # Village feeder roads
			
			# Overrides for Bridge crossings over river
			if t == 7 and r == 11:
				t = 6 # Road / Bridge over River
			if t == 8 and q == 27 and r == 8:
				t = 6 # Fortress Western Gate
			
			var cell: Variant = HexCellCls.new(q, r, t)
			cell_data_dict["%d,%d" % [q, r]] = cell
	
	hex_grid.call("generate_hexes")

func _deploy_test_armies() -> void:
	unit_renderer.call("clear_units")
	
	# =========================================================================
	# BLUE ARMY (Friendly / General Vanguard — Left Flank & Center)
	# =========================================================================
	# 1. Frontline Shield Wall (Infantry & Spearmen) — Clustered Formation
	unit_renderer.call("spawn_unit", "B_INF_1", "infantry", "blue", 8, 9, 450)
	unit_renderer.call("spawn_unit", "B_SPE_1", "spearman", "blue", 8, 10, 380)
	unit_renderer.call("spawn_unit", "B_INF_2", "infantry", "blue", 8, 11, 420)
	unit_renderer.call("spawn_unit", "B_SPE_2", "spearman", "blue", 8, 12, 360)
	unit_renderer.call("spawn_unit", "B_INF_3", "infantry", "blue", 9, 10, 400)
	
	# 2. Elevated Archer Support
	unit_renderer.call("spawn_unit", "B_ARC_1", "archer", "blue", 6, 9, 220)
	unit_renderer.call("spawn_unit", "B_ARC_2", "archer", "blue", 6, 11, 200)
	
	# 3. Southern Cavalry Strike Wing — Clustered Lance
	unit_renderer.call("spawn_unit", "B_CAV_1", "cavalry", "blue", 10, 16, 260)
	unit_renderer.call("spawn_unit", "B_CAV_2", "cavalry", "blue", 11, 15, 240)
	unit_renderer.call("spawn_unit", "B_CAV_3", "cavalry", "blue", 11, 17, 250)
	
	# 4. Scout Vanguard — Forest Recon (Isolated)
	unit_renderer.call("spawn_unit", "B_SCT_1", "scout", "blue", 14, 6, 80)
	unit_renderer.call("spawn_unit", "B_SCT_2", "scout", "blue", 14, 15, 75)
	
	# 5. Conscript Reserve Battalions
	unit_renderer.call("spawn_unit", "B_CON_1", "conscript", "blue", 4, 10, 600)
	unit_renderer.call("spawn_unit", "B_CON_2", "conscript", "blue", 4, 12, 580)
	
	# 6. Siege Engine Battery (Catapult)
	unit_renderer.call("spawn_unit", "B_SIG_1", "siege", "blue", 3, 7, 100)
	
	# =========================================================================
	# RED ARMY (Enemy / Imperial Garrison & Defenses — Right Flank & Fortress)
	# =========================================================================
	# 1. Fortress Interior Garrison — Clustered Defense
	unit_renderer.call("spawn_unit", "R_INF_1", "infantry", "red", 29, 7, 480)
	unit_renderer.call("spawn_unit", "R_SPE_1", "spearman", "red", 29, 8, 420)
	unit_renderer.call("spawn_unit", "R_ARC_1", "archer", "red", 30, 7, 260)
	
	# 2. Fortress Wall Rampart Defenders (Positioned on stone walls)
	unit_renderer.call("spawn_unit", "R_SPE_2", "spearman", "red", 27, 7, 320)
	unit_renderer.call("spawn_unit", "R_ARC_2", "archer", "red", 27, 9, 210)
	
	# 3. Forward Battle Line across River
	unit_renderer.call("spawn_unit", "R_INF_2", "infantry", "red", 21, 9, 440)
	unit_renderer.call("spawn_unit", "R_SPE_3", "spearman", "red", 21, 11, 390)
	unit_renderer.call("spawn_unit", "R_INF_3", "infantry", "red", 22, 10, 410)
	
	# 4. Heavy Cavalry Flank Force
	unit_renderer.call("spawn_unit", "R_CAV_1", "cavalry", "red", 21, 15, 280)
	unit_renderer.call("spawn_unit", "R_CAV_2", "cavalry", "red", 22, 16, 260)
	
	# 5. Mountain Scout Lookout (Isolated)
	unit_renderer.call("spawn_unit", "R_SCT_1", "scout", "red", 20, 3, 90)
	
	# 6. Conscript Levy Screen
	unit_renderer.call("spawn_unit", "R_CON_1", "conscript", "red", 23, 9, 650)
	unit_renderer.call("spawn_unit", "R_CON_2", "conscript", "red", 23, 11, 620)
	
	# 7. Enemy Siege Train
	unit_renderer.call("spawn_unit", "R_SIG_1", "siege", "red", 25, 14, 110)

func _setup_camera_and_bounds() -> void:
	var min_pos: Vector2 = HexUtilsCls.hex_to_pixel(0, 0)
	var max_pos: Vector2 = HexUtilsCls.hex_to_pixel(GRID_Q - 1, GRID_R - 1)
	
	if camera.has_method("set_map_bounds"):
		camera.call("set_map_bounds", min_pos, max_pos, Vector2(240, 180))
	
	# Center view on the battlefield
	var center_pos: Vector2 = (min_pos + max_pos) * 0.5
	if camera.has_method("focus_on"):
		camera.call("focus_on", center_pos, true)
	if camera.has_method("set_zoom_level"):
		camera.call("set_zoom_level", 0.90, true)

func _setup_hud() -> void:
	# 1. Top Status Banner (Clean Tactical Header)
	status_banner = Panel.new()
	status_banner.name = "TopStatusBanner"
	status_banner.position = Vector2(20, 16)
	status_banner.size = Vector2(620, 68)
	
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.10, 0.14, 0.92)
	style.border_color = Color(0.85, 0.70, 0.25, 1.0)
	style.set_border_width_all(2)
	style.set_corner_radius_all(6)
	style.shadow_color = Color(0, 0, 0, 0.5)
	style.shadow_size = 4
	status_banner.add_theme_stylebox_override("panel", style)
	hud_layer.add_child(status_banner)
	
	status_title = Label.new()
	status_title.name = "TitleLabel"
	status_title.position = Vector2(16, 8)
	status_title.size = Vector2(580, 24)
	status_title.text = "將軍 / General — Five Dynasties Battlefield Shell"
	status_title.add_theme_font_size_override("font_size", 16)
	status_title.add_theme_color_override("font_color", Color(0.96, 0.88, 0.65, 1.0))
	status_banner.add_child(status_title)
	
	status_subtitle = Label.new()
	status_subtitle.name = "SubtitleLabel"
	status_subtitle.position = Vector2(16, 34)
	status_subtitle.size = Vector2(580, 24)
	status_subtitle.text = "36x24 Hex Tactical Battlefield  |  Direction A Terrain  |  Form A Shield Badges"
	status_subtitle.add_theme_font_size_override("font_size", 12)
	status_subtitle.add_theme_color_override("font_color", Color(0.75, 0.80, 0.88, 1.0))
	status_banner.add_child(status_subtitle)
	
	# 2. Top-Right Tactical Readout Panel
	var info_panel: Panel = Panel.new()
	info_panel.name = "InfoPanel"
	info_panel.position = Vector2(1920 - 460, 16)
	info_panel.size = Vector2(440, 68)
	info_panel.add_theme_stylebox_override("panel", style)
	hud_layer.add_child(info_panel)
	
	info_label = Label.new()
	info_label.name = "InfoLabel"
	info_label.position = Vector2(16, 8)
	info_label.size = Vector2(408, 52)
	info_label.text = "Camera Zoom: 0.90x\nHover: Move cursor over hexes & unit badges"
	info_label.add_theme_font_size_override("font_size", 13)
	info_label.add_theme_color_override("font_color", Color(0.92, 0.94, 0.98, 1.0))
	info_panel.add_child(info_label)
	
	# 3. Bottom Guide Bar
	var bottom_panel: Panel = Panel.new()
	bottom_panel.name = "BottomGuidePanel"
	bottom_panel.position = Vector2(20, 1080 - 54)
	bottom_panel.size = Vector2(1880, 38)
	
	var bottom_style: StyleBoxFlat = StyleBoxFlat.new()
	bottom_style.bg_color = Color(0.06, 0.08, 0.12, 0.88)
	bottom_style.border_color = Color(0.40, 0.45, 0.55, 0.8)
	bottom_style.set_border_width_all(1)
	bottom_style.set_corner_radius_all(4)
	bottom_panel.add_theme_stylebox_override("panel", bottom_style)
	hud_layer.add_child(bottom_panel)
	
	controls_label = Label.new()
	controls_label.name = "ControlsLabel"
	controls_label.position = Vector2(16, 6)
	controls_label.size = Vector2(1848, 26)
	controls_label.text = "[WASD / Arrow Keys] Pan Camera  |  [Right / Middle Mouse Drag] Pan  |  [Mouse Wheel] Zoom In/Out  |  [Pointer Hover] Enlarge Unit Badge  |  [Space / R] Reset View"
	controls_label.add_theme_font_size_override("font_size", 13)
	controls_label.add_theme_color_override("font_color", Color(0.85, 0.90, 0.95, 1.0))
	bottom_panel.add_child(controls_label)

func _connect_events() -> void:
	if camera and camera.has_signal("camera_updated"):
		camera.connect("camera_updated", _on_camera_updated)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var mouse_world: Vector2 = get_global_mouse_position()
		var hex: Vector2i = HexUtilsCls.pixel_to_hex(mouse_world)
		if hex.x >= 0 and hex.x < GRID_Q and hex.y >= 0 and hex.y < GRID_R:
			set_tactical_hover(hex.x, hex.y)
		else:
			clear_tactical_hover()

func _on_camera_updated(_pos: Vector2, zoom_val: float) -> void:
	_update_tactical_readout(_current_hover_hex.x, _current_hover_hex.y, zoom_val)

func set_tactical_hover(q: int, r: int) -> void:
	_current_hover_hex = Vector2i(q, r)
	if unit_renderer and unit_renderer.has_method("set_hover_at_hex"):
		unit_renderer.call("set_hover_at_hex", q, r)
	_update_tactical_readout(q, r)

func clear_tactical_hover() -> void:
	_current_hover_hex = Vector2i(-999, -999)
	if unit_renderer and unit_renderer.has_method("clear_hover"):
		unit_renderer.call("clear_hover")
	_update_tactical_readout(-999, -999)

func _update_tactical_readout(q: int, r: int, zoom_val: float = -1.0) -> void:
	if zoom_val < 0.0:
		zoom_val = camera.zoom.x if camera else 1.0
	
	var zoom_text: String = "Zoom: %.2fx" % zoom_val
	if q == -999 or r == -999:
		info_label.text = "%s\nHover: -- (Move cursor over battlefield)" % zoom_text
		return
	
	var cell: Variant = hex_grid.call("get_cell", q, r)
	var tname: String = cell.call("get_terrain_name") if cell else "Plains"
	var unit: Dictionary = unit_renderer.call("get_unit_at", q, r)
	
	if not unit.is_empty():
		var fac_str: String = "Friendly (Blue)" if unit["faction"] == "blue" else "Enemy (Red)"
		var cls_str: String = str(unit["class"]).capitalize()
		var count: int = int(unit["soldier_count"])
		info_label.text = "%s | Hex: (%d, %d) [%s]\nUnit: %s %s (%d troops) ★ Badge Enlarge" % [
			zoom_text, q, r, tname, fac_str, cls_str, count
		]
	else:
		info_label.text = "%s | Hex: (%d, %d)\nTerrain: %s" % [zoom_text, q, r, tname]
