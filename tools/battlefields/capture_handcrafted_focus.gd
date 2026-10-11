extends SceneTree
## Capture HC01 from the live battle compositor. Fog reveal and camera focus are
## confined to this evidence process; gameplay assets and rules are untouched.

const HexUtils = preload("res://scripts/core/hex_utils.gd")
const OUT := "res://evidence/handcrafted_v1/live_capture"

var _shell: Node
var _frame := 0
var _receipt: Array = []


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	root.size = Vector2i(1920, 1080)
	_shell = (load("res://scenes/step2r_battlefield_shell.tscn") as PackedScene).instantiate()
	_shell.set("battlefield_id", "HC01")
	root.add_child(_shell)


func _reveal() -> void:
	var fog = _shell.get("_fog")
	var cells: Dictionary = _shell.get("hex_grid").get("cell_data")
	for key in cells:
		fog.visible[key] = true
		fog.explored[key] = true
	_shell.call("_apply_fog_terrain")
	_shell.call("_apply_enemy_observation")


func _focus(coord: Vector2i, zoom: float) -> void:
	var cam: Node = _shell.get_node("Camera2D")
	cam.call("set_zoom_level", zoom, true)
	cam.call("focus_on", HexUtils.hex_to_pixel(coord.x, coord.y), true)


func _save(name: String) -> void:
	var img := root.get_texture().get_image()
	if img == null or img.is_empty():
		push_error("[HC01-CAP] empty viewport image")
		quit(1)
		return
	var path := OUT + "/hc01_" + name + ".png"
	var err := img.save_png(path)
	if err != OK:
		push_error("[HC01-CAP] save failed " + path)
		quit(1)
		return
	var cam: Camera2D = _shell.get_node("Camera2D")
	_receipt.append({"view": name, "path": path,
		"size": [img.get_width(), img.get_height()],
		"zoom": cam.zoom.x, "position": [cam.global_position.x, cam.global_position.y],
		"fog": "revealed in capture process only"})
	print("[HC01-CAP] saved " + path)


func _process(_delta: float) -> bool:
	_frame += 1
	match _frame:
		90:
			var closeup := _shell.get_node_or_null("BattlefieldCloseupView")
			if closeup != null:
				closeup.call("request_mode", false)
			_reveal()
			_focus(Vector2i(0, 0), 0.30)
		160:
			_save("full_map_revealed")
			_focus(Vector2i(5, -13), 0.85)
		225:
			_save("west_bridge_revealed")
			_focus(Vector2i(-4, 14), 0.85)
		290:
			_save("east_bridge_revealed")
			_focus(Vector2i(25, 3), 0.85)
		355:
			_save("capital_revealed")
			_focus(Vector2i(3, 24), 0.85)
		420:
			_save("saddle_fort_revealed")
			var f := FileAccess.open(OUT + "/hc01_focus_receipt.json", FileAccess.WRITE)
			f.store_string(JSON.stringify({"id": "HC01", "shots": _receipt}, "  "))
			f.close()
			quit(0)
			return true
	return false
