extends SceneTree

## capture_r3_screenshots.gd — Automated High-Fidelity Capture Tool for Visual Overhaul R3
## Launches res://scenes/step2r_battlefield_shell.tscn at 1920x1080,
## configures each required visual presentation mode, and saves in-engine screenshots.

const HexUtilsCls = preload("res://scripts/core/hex_utils.gd")

var _shell: Node2D = null
var _frame_count: int = 0
var _capture_dirs: Array[String] = [
	"D:/Game development/.workflow/deliverables/VISUAL-OVERHAUL/screenshots",
	"D:/.workflow/deliverables/VISUAL-OVERHAUL/screenshots"
]

func _initialize() -> void:
	print("==================================================")
	print("[R3 Capture] Initializing 1920x1080 Viewport Runner...")
	print("==================================================")
	root.size = Vector2i(1920, 1080)
	root.content_scale_size = Vector2i(1920, 1080)
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	root.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_KEEP

	for d in _capture_dirs:
		DirAccess.make_dir_recursive_absolute(d)

	var scene_res: PackedScene = load("res://scenes/step2r_battlefield_shell.tscn") as PackedScene
	if scene_res == null:
		push_error("[R3] Failed to load res://scenes/step2r_battlefield_shell.tscn")
		quit(1)
		return

	_shell = scene_res.instantiate() as Node2D
	root.add_child(_shell)
	print("[R3] Shell instantiated successfully.")

func _process(_delta: float) -> bool:
	_frame_count += 1
	var cam: Camera2D = _shell.get_node_or_null("Camera2D") as Camera2D if _shell else null
	var pt: Node2D = _shell.get_node_or_null("PaintedTerrain") as Node2D if _shell else null
	var ur: Node2D = _shell.get_node_or_null("UnitRenderer") as Node2D if _shell else null

	# Frame 15: Setup Shot 1 — Normal Battlefield (Reference C)
	if _frame_count == 15:
		print("[R3] Setting up Shot 1: Normal Battlefield (Ref C)...")
		if _shell:
			_shell.call("_set_map_mode", 0)
		if pt:
			pt.call("set_advisor_mode", false)
			pt.call("set_hover_hex", Vector2i(-12, 0))
		if cam:
			var focus_pos: Vector2 = HexUtilsCls.hex_to_pixel(-13, 0)
			cam.call("focus_on", focus_pos, true)
			cam.call("set_zoom_level", 1.05, true)
		if ur and ur.has_method("set_camera_zoom"):
			ur.call("set_camera_zoom", 1.05)

	elif _frame_count == 25:
		_save_screenshot("01_normal_battle.png", "Normal Battlefield — Continuous 2.5D Painted Landscape, Jade River, Mountains, Formations & Banners")

	# Frame 35: Setup Shot 2 — Advisor / Tactical Analysis Mode (Reference A)
	elif _frame_count == 35:
		print("[R3] Setting up Shot 2: Advisor Tactical Analysis (Ref A)...")
		if _shell:
			_shell.call("_set_map_mode", 0)
		if pt:
			pt.call("set_advisor_mode", true)
			pt.call("set_hover_hex", Vector2i(-4, 2))
		if cam:
			var focus_pos: Vector2 = HexUtilsCls.hex_to_pixel(-5, 0)
			cam.call("focus_on", focus_pos, true)
			cam.call("set_zoom_level", 0.85, true)
		if ur and ur.has_method("set_camera_zoom"):
			ur.call("set_camera_zoom", 0.85)

	elif _frame_count == 45:
		_save_screenshot("02_advisor_analysis.png", "Advisor Mode — Military Cartography Annotations, Advance Corridors, Clash & Objective Rings")

	# Frame 55: Setup Shot 3 — Logistics Mode (Reference B)
	elif _frame_count == 55:
		print("[R3] Setting up Shot 3: Logistics Mode (Ref B)...")
		if _shell:
			_shell.call("_set_map_mode", 1)
		if pt:
			pt.call("set_advisor_mode", false)
			pt.call("set_hover_hex", Vector2i(-12, 2))
		if cam:
			var focus_pos: Vector2 = HexUtilsCls.hex_to_pixel(-6, 0)
			cam.call("focus_on", focus_pos, true)
			cam.call("set_zoom_level", 0.75, true)
		if ur and ur.has_method("set_camera_zoom"):
			ur.call("set_camera_zoom", 0.75)

	elif _frame_count == 65:
		_save_screenshot("03_logistics_mode.png", "Logistics Mode — Warm Evening Sepia Terrain, Radiant Golden Depot Halos, Supply Lines & Wagons")

	# Frame 75: Setup Shot 4 — Close Tactical Zoom
	elif _frame_count == 75:
		print("[R3] Setting up Shot 4: Close Tactical Zoom...")
		if pt:
			pt.call("set_logistics_mode", false)
			pt.call("set_advisor_mode", false)
			pt.call("set_hover_hex", Vector2i(-17, 0))
		if cam:
			var focus_pos: Vector2 = HexUtilsCls.hex_to_pixel(-18, 0)
			cam.call("focus_on", focus_pos, true)
			cam.call("set_zoom_level", 1.85, true)
		if ur and ur.has_method("set_camera_zoom"):
			ur.call("set_camera_zoom", 1.85)

	elif _frame_count == 85:
		_save_screenshot("04_tactical_zoom_close.png", "Tactical Zoom Close (1.85x) — Soldier Squads, Armor, Weapons, Calligraphy Banners, Bridge Detail")

	# Frame 95: Setup Shot 5 — Strategic Overview Zoom
	elif _frame_count == 95:
		print("[R3] Setting up Shot 5: Strategic Overview Zoom...")
		if pt:
			pt.call("set_logistics_mode", false)
			pt.call("set_advisor_mode", false)
			pt.call("set_hover_hex", Vector2i(-999, -999))
		if cam:
			cam.call("focus_on", Vector2(0, 0), true)
			cam.call("set_zoom_level", 0.35, true)
		if ur and ur.has_method("set_camera_zoom"):
			ur.call("set_camera_zoom", 0.35)

	elif _frame_count == 105:
		_save_screenshot("05_strategic_overview.png", "Strategic Overview (0.35x) — Full Campaign Scope, Grand Mountain Spine, Mist & Perimeter Clouds")

	# Frame 115: Done!
	elif _frame_count == 115:
		print("==================================================")
		print("[R3 Capture] All 5 Screenshots Captured Successfully!")
		print("==================================================")
		quit(0)

	return false

func _save_screenshot(file_name: String, desc: String) -> void:
	var img: Image = root.get_texture().get_image()
	if img == null:
		push_error("[R3] Failed to get viewport image for %s" % file_name)
		return

	for d in _capture_dirs:
		var full_path: String = "%s/%s" % [d, file_name]
		var err: Error = img.save_png(full_path)
		print("[R3 Capture] Saved: %s (err=%d, %dx%d) — %s" % [full_path, err, img.get_width(), img.get_height(), desc])
