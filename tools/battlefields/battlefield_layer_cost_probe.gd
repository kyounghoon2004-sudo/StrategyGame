extends SceneTree
## Layer cost probe (windowed, VISUAL QA only): boots one battlefield, forces
## the probe's fog copy fully clear (worst case: everything explored), sets
## the HIGH tactical zoom, then hides each board-compositor layer in turn and
## records the median frame time. Tells which layer a heavy map pays for.
## Usage: godot --path <p> --script res://tools/battlefields/battlefield_layer_cost_probe.gd -- <BFxx> <out.json>

var _shell: Node
var _id: String
var _out: String
var _frame: int = 0
var _targets: Array = []
var _ti: int = -1
var _acc: Array = []
var _last: int = 0
var _res: Dictionary = {}
const SETTLE := 20
const SAMPLE := 60

func _initialize() -> void:
	var a := OS.get_cmdline_user_args()
	_id = a[0]
	_out = a[1]
	root.size = Vector2i(1920, 1080)
	_shell = (load("res://scenes/step2r_battlefield_shell.tscn") as PackedScene).instantiate()
	if _id != "default":
		_shell.set("battlefield_id", _id)
	root.add_child(_shell)

func _collect(n: Node, depth: int) -> void:
	for c in n.get_children():
		if c is CanvasItem:
			_targets.append(c)
		if depth < 2:
			_collect(c, depth + 1)

func _process(_d: float) -> bool:
	_frame += 1
	var now := Time.get_ticks_usec()
	var dt := float(now - _last) / 1000.0
	_last = now
	if _frame == 60:
		var v: Node = _shell.get_node_or_null("BattlefieldCloseupView")
		if v: v.call("request_mode", false)
	elif _frame == 90:
		var fog = _shell.get("_fog")
		for k in (_shell.get("hex_grid").get("cell_data") as Dictionary).keys():
			fog.visible[k] = true
			fog.explored[k] = true
		_shell.call("_apply_fog_terrain")
		var cam: Node = _shell.get_node_or_null("Camera2D")
		if cam: cam.call("set_zoom_level", 1.1, true)
		_collect(_shell.get("hex_compositor"), 0)
		_ti = -1
		_acc.clear()
	elif _frame > 90 + SETTLE:
		_acc.append(dt)
		if _acc.size() >= SAMPLE:
			_acc.sort()
			var med: float = _acc[_acc.size() / 2]
			var label: String = "ALL_VISIBLE" if _ti < 0 else (str(_targets[_ti].get_path()).get_file() if is_instance_valid(_targets[_ti]) else "freed")
			if _ti >= 0 and is_instance_valid(_targets[_ti]) and _targets[_ti] is MultiMeshInstance2D and (_targets[_ti] as MultiMeshInstance2D).multimesh:
				label += " (%d inst)" % (_targets[_ti] as MultiMeshInstance2D).multimesh.instance_count
			_res[label] = snappedf(med, 0.01)
			print("[LAYER-COST] %s %.2f ms" % [label, med])
			if _ti >= 0 and is_instance_valid(_targets[_ti]):
				(_targets[_ti] as CanvasItem).visible = true
			_ti += 1
			while _ti < _targets.size() and (not is_instance_valid(_targets[_ti]) or not (_targets[_ti] as CanvasItem).visible):
				_ti += 1
			if _ti >= _targets.size():
				var f := FileAccess.open(_out, FileAccess.WRITE)
				f.store_string(JSON.stringify(_res, "  ", true))
				f.close()
				return true
			(_targets[_ti] as CanvasItem).visible = false
			_acc.clear()
			_frame = 90 + 1
	return false
