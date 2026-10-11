extends SceneTree
## Visual capture harness: closeup (opening state) -> mist veil -> board
## tactical cap -> board top-down. Saves PNGs to <out_dir>.
## Usage: godot --path . --script res://tools/visual_capture/battlefield_capture.gd -- <out_dir> [tag]

var _shell: Node
var _frame: int = 0
var _out: String = ""
var _tag: String = "cap"

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	_out = args[0] if args.size() > 0 else "user://cap"
	_tag = args[1] if args.size() > 1 else "cap"
	DirAccess.make_dir_recursive_absolute(_out)
	root.size = Vector2i(1920, 1080)
	_shell = (load("res://scenes/step2r_battlefield_shell.tscn") as PackedScene).instantiate()
	root.add_child(_shell)

func _save(n: String) -> void:
	root.get_texture().get_image().save_png(_out.path_join("%s_%s.png" % [_tag, n]))
	print("[CAP] saved ", n, " fps=", Engine.get_frames_per_second())

func _process(_d: float) -> bool:
	_frame += 1
	var cam: Node = _shell.get_node_or_null("Camera2D")
	var v: Node = _shell.get_node_or_null("BattlefieldCloseupView")
	if _frame == 90:
		_save("closeup")
		if v: v.set("_dolly", 1.4)
	elif _frame == 96:
		_save("closeup_mid")
		if v: v.set("_dolly", 1.8)
	elif _frame == 102:
		_save("closeup_out")
		if v: v.set("_dolly", 1.0)
		if v: v.call("request_mode", false)
	elif _frame == 110:
		_save("veil")
	elif _frame == 160:
		_save("tactical")
		if cam: cam.call("set_zoom_level", float(cam.get("min_zoom")), true)
	elif _frame == 230:
		_save("high")
		if v: v.call("request_mode", true)
	elif _frame == 360:
		_save("closeup_again")
		if cam: cam.call("focus_on", Vector2(-4 * 36, 2 * 42 - 4 * 21) - Vector2(36, 21).normalized() * 70.0, true)
		if v: v.set("_dolly", 0.8)
	elif _frame == 420:
		_save("stronghold")
	elif _frame == 424:
		return true
	return false
