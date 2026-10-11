extends SceneTree
## Canonical battlefield smoke probe (headless-safe): boots the real battle
## shell on one battlefield, checks the loaded map matches its data file,
## then plays TURNS full turns (player phase ends, the existing enemy phase
## runs) and writes a JSON summary. Gameplay rules are untouched: this only
## calls the shell's public turn API.
## Usage: godot --headless --path <p> --script res://tools/battlefields/battlefield_smoke_probe.gd -- <BFxx> <out.json>

const Catalog = preload("res://scripts/battlefields/battlefield_catalog.gd")
const TURNS := 3

var _shell: Node
var _id: String
var _out: String
var _frame: int = 0
var _turns: int = 0
var _phase: int = 0
var _wait: int = 0
var _t0: int = 0
var _res: Dictionary = {}

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	_id = args[0]
	_out = args[1]
	_t0 = Time.get_ticks_msec()
	var ps: PackedScene = load("res://scenes/step2r_battlefield_shell.tscn")
	_shell = ps.instantiate()
	_shell.set("battlefield_id", _id)
	root.add_child(_shell)
	_res["boot_ms"] = Time.get_ticks_msec() - _t0

func _check_loaded() -> void:
	var data: Dictionary = Catalog.load_battlefield(_id)
	var cells: Dictionary = _shell.get("hex_grid").get("cell_data")
	var mism: int = 0
	for k in data["terrain"].keys():
		if not cells.has(k) or int(cells[k].terrain) != int(data["terrain"][k]):
			mism += 1
	var um = _shell.get("unit_manager")
	var shs: Array = []
	for sh in um.get_all_strongholds():
		shs.append({"id": str(sh.structure_id), "garrison": int(sh.get_garrison_count()), "owner": str(sh.owner)})
	var specs: Array = _shell.call("stronghold_visual_specs")
	_res["id"] = _id
	_res["loaded_id"] = str(_shell.get("battlefield_id"))
	_res["cells"] = cells.size()
	_res["terrain_mismatch"] = mism
	_res["river_cells"] = (_shell.get("_river_cells") as Dictionary).size()
	_res["river_expected"] = (data["river"] as Dictionary).size()
	_res["units_expected"] = (data["units"] as Array).size()
	_res["units_live"] = um.get_all_units_including_garrisoned().size()
	_res["strongholds"] = shs
	_res["specs"] = specs.size()
	_res["fog_visible_t0"] = (_shell.get("_fog").get("visible") as Dictionary).size()

func _busy() -> bool:
	return bool(_shell.get("_is_animating_movement")) or bool(_shell.get("_is_animating_combat"))

func _process(_d: float) -> bool:
	_frame += 1
	if _frame > 6000:
		_finish("TIMEOUT")
		return true
	if _wait > 0:
		_wait -= 1
		return false
	if _busy():
		return false
	match _phase:
		0:
			if _frame > 20:
				_check_loaded()
				_phase = 1
		1:
			_shell.call("end_player_phase")
			_phase = 2
			_wait = 2
		2:
			if int(_shell.get("_turn_phase")) == 0:
				_turns += 1
				if _turns >= TURNS or bool(_shell.get("_battle_lost")) or bool(_shell.get("_battle_won")):
					_finish("OK")
					return true
				_phase = 1
	return false

func _finish(status: String) -> void:
	var um = _shell.get("unit_manager")
	_res["status"] = status
	_res["turn"] = int(um.get_current_turn())
	_res["units_after"] = um.get_all_units_including_garrisoned().size()
	_res["total_ms"] = Time.get_ticks_msec() - _t0
	_res["static_mem_mb"] = snappedf(float(OS.get_static_memory_usage()) / 1048576.0, 0.1)
	_res["nodes"] = int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	var f := FileAccess.open(_out, FileAccess.WRITE)
	f.store_string(JSON.stringify(_res, "  ", true))
	f.close()
	print("[BF-SMOKE] %s %s turn=%d units=%d/%d mism=%d river=%d/%d strongholds=%s" % [
		_id, status, _res["turn"], _res["units_live"], _res["units_expected"], _res["terrain_mismatch"],
		_res["river_cells"], _res["river_expected"], str(_res["strongholds"])])
