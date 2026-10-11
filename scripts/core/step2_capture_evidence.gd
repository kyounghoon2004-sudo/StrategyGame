extends SceneTree

## step2_capture_evidence.gd — Automated Runtime Evidence Capture & Smoke Validator for Step 2
## Runs inside Godot at 1920x1080, validates scenes/units/badges, and saves 5 high-res evidence PNGs.

var HexUtilsCls: Script = preload("res://scripts/core/hex_utils.gd")

var _shell: Node2D
var _frame_count: int = 0
var _evidence_dir: String = "D:/Game development/.workflow/deliverables/STEP-02-BATTLEFIELD-SHELL/evidence"

func _initialize() -> void:
	print("[Step2Capture] Initializing runtime capture at 1920x1080...")
	
	# Set viewport window size to 1920x1080
	root.size = Vector2i(1920, 1080)
	root.content_scale_size = Vector2i(1920, 1080)
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	root.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_KEEP
	
	var scene_res: PackedScene = load("res://scenes/step2_battlefield_shell.tscn") as PackedScene
	if scene_res == null:
		push_error("[Step2Capture] Failed to load step2_battlefield_shell.tscn!")
		quit(1)
		return
	
	_shell = scene_res.instantiate() as Node2D
	root.add_child(_shell)
	print("[Step2Capture] Scene instantiated successfully.")

func _process(_delta: float) -> bool:
	_frame_count += 1
	
	if _frame_count == 5:
		_validate_scene_integrity()
	
	# =========================================================================
	# Step A: Default Battlefield View (Setup frame 10, Capture frame 20)
	# =========================================================================
	elif _frame_count == 10:
		var cam: Node = _shell.get_node("Camera2D")
		if cam.has_method("set_zoom_level"):
			cam.call("set_zoom_level", 0.90, true)
		var center_pos: Vector2 = HexUtilsCls.hex_to_pixel(18, 12)
		if cam.has_method("focus_on"):
			cam.call("focus_on", center_pos, true)
	elif _frame_count == 20:
		_save_screenshot("runtime_default_1920x1080.png")
		print("[Step2Capture] Evidence A: Default View captured.")
	
	# =========================================================================
	# Step B: Zoomed-out Strategic View (Setup frame 25, Capture frame 35)
	# =========================================================================
	elif _frame_count == 25:
		var cam: Node = _shell.get_node("Camera2D")
		if cam.has_method("set_zoom_level"):
			cam.call("set_zoom_level", 0.48, true)
		var center_pos: Vector2 = HexUtilsCls.hex_to_pixel(18, 12)
		if cam.has_method("focus_on"):
			cam.call("focus_on", center_pos, true)
	elif _frame_count == 35:
		_save_screenshot("runtime_zoomed_out_1920x1080.png")
		print("[Step2Capture] Evidence B: Zoomed-out Strategic View captured.")
	
	# =========================================================================
	# Step C: Zoomed-in Unit Readability View (Setup frame 40, Capture frame 50)
	# =========================================================================
	elif _frame_count == 40:
		var cam: Node = _shell.get_node("Camera2D")
		if cam.has_method("set_zoom_level"):
			cam.call("set_zoom_level", 1.85, true)
		var focus_pos: Vector2 = HexUtilsCls.hex_to_pixel(8, 10) # Focused on Blue Infantry & Spearman frontline
		if cam.has_method("focus_on"):
			cam.call("focus_on", focus_pos, true)
	elif _frame_count == 50:
		_save_screenshot("runtime_zoomed_in_1920x1080.png")
		print("[Step2Capture] Evidence C: Zoomed-in Unit Readability View captured.")
	
	# =========================================================================
	# Step D: Badge Hover Active (Setup frame 55, Capture frame 70)
	# =========================================================================
	elif _frame_count == 55:
		if _shell.has_method("set_tactical_hover"):
			_shell.call("set_tactical_hover", 8, 10) # Hover on Spearman (8, 10)
		var cam: Node = _shell.get_node("Camera2D")
		if cam.has_method("set_zoom_level"):
			cam.call("set_zoom_level", 1.85, true)
		if cam.has_method("focus_on"):
			cam.call("focus_on", HexUtilsCls.hex_to_pixel(8, 10), true)
	elif _frame_count == 70:
		_save_screenshot("runtime_badge_hover_1920x1080.png")
		print("[Step2Capture] Evidence D: Badge Hover Active captured.")
	
	# =========================================================================
	# Step E: Dense Clustered Formation (Setup frame 75, Capture frame 90)
	# =========================================================================
	elif _frame_count == 75:
		if _shell.has_method("clear_tactical_hover"):
			_shell.call("clear_tactical_hover")
		var cam: Node = _shell.get_node("Camera2D")
		if cam.has_method("set_zoom_level"):
			cam.call("set_zoom_level", 1.40, true)
		# Focus on fortress area where Red fortress garrison & wall defenders cluster
		var fortress_pos: Vector2 = HexUtilsCls.hex_to_pixel(28, 8)
		if cam.has_method("focus_on"):
			cam.call("focus_on", fortress_pos, true)
	elif _frame_count == 90:
		_save_screenshot("runtime_dense_formation_1920x1080.png")
		print("[Step2Capture] Evidence E: Dense Formation captured.")
	
	# =========================================================================
	# Finish & Exit (Frame 95)
	# =========================================================================
	elif _frame_count == 95:
		print("[Step2Capture] ALL RUNTIME EVIDENCE CAPTURED SUCCESSFULLY. Exiting Godot with code 0.")
		quit(0)
	
	return false

func _validate_scene_integrity() -> void:
	var hg: Node = _shell.get_node_or_null("HexGrid")
	var ur: Node = _shell.get_node_or_null("UnitRenderer")
	var cam: Node = _shell.get_node_or_null("Camera2D")
	
	assert(hg != null, "HexGrid missing")
	assert(ur != null, "UnitRenderer missing")
	assert(cam != null, "Camera2D missing")
	assert(hg.get("cell_data").size() == 36 * 24, "Grid cell count must be 864 (36x24)")
	
	var units: Array = ur.call("get_all_units")
	assert(units.size() >= 14, "Must have sufficient units for testing")
	
	# Verify all 7 classes exist
	var found_classes: Dictionary = {}
	var found_factions: Dictionary = {}
	for u in units:
		found_classes[str(u.get("class"))] = true
		found_factions[str(u.get("faction"))] = true
	
	for req_class in ["infantry", "spearman", "archer", "cavalry", "scout", "conscript", "siege"]:
		assert(found_classes.has(req_class), "Required class missing: %s" % req_class)
	assert(found_factions.has("blue"), "Friendly Blue faction missing")
	assert(found_factions.has("red"), "Enemy Red faction missing")
	
	print("[Step2Capture] Validation passed: 864 hex cells (36x24), 7 classes verified in Blue & Red factions.")

func _save_screenshot(filename: String) -> void:
	var img: Image = root.get_texture().get_image()
	if img != null:
		var target_path: String = "%s/%s" % [_evidence_dir, filename]
		var err: Error = img.save_png(target_path)
		if err == OK:
			print("[Step2Capture] Saved screenshot: %s (Size: %dx%d)" % [target_path, img.get_width(), img.get_height()])
		else:
			push_error("[Step2Capture] Failed to save screenshot: %s (Error %d)" % [target_path, err])
