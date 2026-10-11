extends SceneTree
## HC01 live 3D map evidence. No debug fog reveal or scene substitutions.
const HexUtils = preload("res://scripts/core/hex_utils.gd")
const OUT := "res://evidence/handcrafted_v1/glb_views"
var shell: Node
var frame := 0
var shots: Array = []

func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	root.size = Vector2i(1920, 1080)
	shell = (load("res://scenes/step2r_battlefield_shell.tscn") as PackedScene).instantiate()
	shell.set("battlefield_id", "HC01")
	root.add_child(shell)

func _focus(q: int, r: int, zoom: float) -> void:
	var camera: Node = shell.get_node("Camera2D")
	camera.call("set_zoom_level", zoom, true)
	camera.call("focus_on", HexUtils.hex_to_pixel(q, r), true)

func _save(label: String) -> void:
	var picture := root.get_texture().get_image()
	var path := OUT + "/hc01_" + label + ".png"
	assert(picture != null and not picture.is_empty())
	assert(picture.save_png(path) == OK)
	var camera: Camera2D = shell.get_node("Camera2D")
	shots.append({"view": label, "size": [picture.get_width(), picture.get_height()],
		"camera_world": [camera.global_position.x, camera.global_position.y],
		"zoom": camera.zoom.x, "mode": "HC01 native 3D", "fog": "off in live game"})
	print("[HC01-GLB-CAP] ", label)

func _process(_delta: float) -> bool:
	frame += 1
	match frame:
		90:
			_save("entire_battlefield")
			_focus(-18, -6, 1.35)
		150:
			_save("western_forest")
			_focus(18, -8, 1.35)
		210:
			_save("eastern_ridge")
			_focus(5, -13, 1.35)
		270:
			_save("western_bridge")
			_focus(-4, 14, 1.35)
		330:
			_save("eastern_bridge")
			_focus(25, 3, 1.7)
		390:
			_save("capital")
			_focus(3, 24, 1.7)
		450:
			_save("saddle_fort")
			_focus(-31, 0, 1.7)
		510:
			_save("blue_deployment")
			var receipt := FileAccess.open(OUT + "/capture_receipt.json", FileAccess.WRITE)
			receipt.store_string(JSON.stringify({"battlefield": "HC01", "shots": shots}, "  "))
			receipt.close()
			quit(0)
			return true
	return false
