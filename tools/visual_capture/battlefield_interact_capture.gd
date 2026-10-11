extends SceneTree
## Interaction capture: select a friendly unit by clicking its closeup card,
## preview + confirm a move by clicking ground hexes, capture each step.
## Usage: godot --path . --script res://tools/visual_capture/battlefield_interact_capture.gd -- <out_dir>

var _shell: Node
var _view: Node
var _frame: int = 0
var _out: String = ""
const HexUtilsCls = preload("res://scripts/core/hex_utils.gd")

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	_out = args[0] if args.size() > 0 else "user://cap"
	root.size = Vector2i(1920, 1080)
	_shell = (load("res://scenes/step2r_battlefield_shell.tscn") as PackedScene).instantiate()
	root.add_child(_shell)

func _save(n: String) -> void:
	root.get_texture().get_image().save_png(_out.path_join("act_%s.png" % n))
	print("[ACT] saved ", n)

func _click(p: Vector2) -> void:
	var mm := InputEventMouseMotion.new()
	mm.position = p
	mm.global_position = p
	root.push_input(mm)
	for pressed in [true, false]:
		var e := InputEventMouseButton.new()
		e.button_index = MOUSE_BUTTON_LEFT
		e.pressed = pressed
		e.position = p
		e.global_position = p
		root.push_input(e)

func _hex_screen(q: int, r: int) -> Vector2:
	return _view.call("world_to_screen", HexUtilsCls.hex_to_pixel(q, r))

func _process(_d: float) -> bool:
	_frame += 1
	if _frame == 80:
		_view = _shell.get_node_or_null("BattlefieldCloseupView")
		var sp: Vector2 = _hex_screen(-22, 0)
		var back: Vector2 = _view.call("screen_to_world", sp)
		print("[ACT] hex(-22,0) screen=", sp, " pick->", HexUtilsCls.pixel_to_hex(back))
		_click(sp)
	elif _frame == 110:
		var ur: Node = _shell.get("unit_renderer")
		print("[ACT] selected=", ur.call("get_selected_unit_id"))
		_save("selected")
		var tp: Vector2 = _hex_screen(-19, 0)
		print("[ACT] target(-19,0) pick->", HexUtilsCls.pixel_to_hex(_view.call("screen_to_world", tp)))
		_click(tp)
	elif _frame == 140:
		_save("preview")
		_click(_hex_screen(-19, 0))
	elif _frame == 230:
		var u: Dictionary = _shell.get("unit_manager").call("get_unit_by_id", str(_shell.get("unit_renderer").call("get_selected_unit_id")))
		print("[ACT] after move unit=", u.get("id", "?"), " at ", u.get("q", "?"), ",", u.get("r", "?"))
		_save("moved")
	elif _frame == 235:
		return true
	return false
