extends SceneTree
## Canonical battlefield capture harness (windowed, VISUAL QA only).
## Boots the real battle shell on one battlefield and saves:
##   closeup        opening CLOSEUP (real fog)
##   tactical       tactical camera cap (real fog)
##   commander      commander camera zoom (real fog)
##   terrain_cmd    commander zoom with fog forced clear   (QA reveal, tool-only)
##   terrain_tac    tactical zoom with fog forced clear    (QA reveal, tool-only)
##   terrain_cu     CLOSEUP with fog forced clear          (QA reveal, tool-only)
## Tutorial battlefields use the native full-map 3D camera at every zoom; the
## Camera2D zoom/pan values drive that camera. They do not switch to HIGH when
## request_mode(false) is requested. Other battlefields may use the HIGH layer.
## The QA reveal writes the probe's copy of fog state only so terrain can be
## judged; it is never done by the game. Also records per-mode frame ms.
## Usage: godot --path <p> --script res://tools/battlefields/battlefield_canonical_capture.gd -- <BFxx|default> <out_dir>

var _shell: Node
var _id: String
var _out: String
var _frame: int = 0
var _ms: Dictionary = {}
var _acc: Array = []
var _last_us: int = 0
const HexUtilsCls = preload("res://scripts/core/hex_utils.gd")

func _focus_at(hex: Vector2i) -> void:
	var cam: Node = _shell.get_node_or_null("Camera2D")
	if cam:
		cam.set("anchor_provider", Callable())
		cam.call("focus_on", HexUtilsCls.hex_to_pixel(hex.x, hex.y), true)

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	_id = args[0]
	_out = args[1]
	DirAccess.make_dir_recursive_absolute(_out)
	root.size = Vector2i(1920, 1080)
	_shell = (load("res://scenes/step2r_battlefield_shell.tscn") as PackedScene).instantiate()
	if _id != "default":
		_shell.set("battlefield_id", _id)
	root.add_child(_shell)

func _save(n: String) -> void:
	root.get_texture().get_image().save_png(_out.path_join("%s_%s.png" % [_id.to_lower(), n]))
	if not _acc.is_empty():
		_acc.sort()
		_ms[n] = _acc[_acc.size() / 2]
	_acc.clear()
	print("[BF-CAP] ", _id, " ", n)

func _reveal() -> void:
	var fog = _shell.get("_fog")
	var cells: Dictionary = _shell.get("hex_grid").get("cell_data")
	for k in cells.keys():
		fog.visible[k] = true
		fog.explored[k] = true
	_shell.call("_apply_fog_terrain")
	_shell.call("_apply_enemy_observation")

func _focus_objective() -> void:
	var battlefield: Dictionary = _shell.get("_battlefield")
	var scenario: Dictionary = battlefield.get("scenario", {})
	var objectives: Array = scenario.get("objectives", [])
	if objectives.is_empty():
		return
	var objective_area: Dictionary = (objectives[0] as Dictionary).get("objective_area", {})
	var center: Array = objective_area.get("center", [0, 0])
	if center.size() != 2:
		return
	_focus_at(Vector2i(int(center[0]), int(center[1])))

func _focus_player_front() -> void:
	var battlefield: Dictionary = _shell.get("_battlefield")
	var scenario: Dictionary = battlefield.get("scenario", {})
	var deployment: Dictionary = scenario.get("deployment", {})
	for placement in deployment.get("unit_placements", []):
		var row: Dictionary = placement
		if str(row.get("side", "")) == "blue" and str(row.get("role", "")) == "field":
			var location: Array = row.get("location", [])
			if location.size() == 2:
				_focus_at(Vector2i(int(location[0]), int(location[1])))
				return
	_focus_objective()

func _process(_d: float) -> bool:
	_frame += 1
	var now: int = Time.get_ticks_usec()
	if _last_us > 0 and _frame > 40:
		_acc.append(float(now - _last_us) / 1000.0)
	_last_us = now
	var cam: Node = _shell.get_node_or_null("Camera2D")
	var v: Node = _shell.get_node_or_null("BattlefieldCloseupView")
	match _frame:
		90:
			_save("closeup")
			if v: v.call("request_mode", false)
		160:
			_save("tactical")
			if cam: cam.call("set_zoom_level", float(cam.get("min_zoom")), true)
		230:
			_save("commander")
			_reveal()
		290:
			_save("terrain_cmd")
			if cam:
				cam.call("set_zoom_level", 1.1, true)
				_focus_player_front()
		350:
			_save("terrain_tac")
			if cam:
				cam.call("set_zoom_level", 3.0, true)
				_focus_objective()
		440:
			_save("terrain_cu")
			var f := FileAccess.open(_out.path_join("%s_frame_ms.json" % _id.to_lower()), FileAccess.WRITE)
			f.store_string(JSON.stringify(_ms))
			f.close()
		444:
			return true
	return false
