extends SceneTree
## Gameplay equivalence probe (visual frontend hardening): boots the real
## battle shell headless, plays a fixed script of player moves + enemy phases
## through the shell's public API, and dumps the authoritative state (units,
## strongholds, fog key sets, turn) as canonical JSON. Run on the pre- and
## post-change trees; the outputs must be byte-identical.
## Usage: godot --headless --path <p> --script res://tools/visual_contract/gameplay_equivalence_probe.gd -- <out.json> <sandbox 0|1>

var _shell: Node
var _out: String
var _frame: int = 0
var _phase: int = 0
var _wait: int = 0
var _turns: int = 0
var _log: Array = []
const TURNS := 3
const ADVANCE := [Vector2i(3, 0), Vector2i(2, 1), Vector2i(2, -1), Vector2i(4, 0)]

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	_out = args[0]
	var ps: PackedScene = load("res://scenes/step2r_battlefield_shell.tscn")
	_shell = ps.instantiate()
	_shell.set("is_step0_sandbox", args.size() > 1 and args[1] == "1")
	root.add_child(_shell)

func _busy() -> bool:
	return bool(_shell.get("_is_animating_movement")) or bool(_shell.get("_is_animating_combat"))

func _player_phase() -> bool:
	return int(_shell.get("_turn_phase")) == 0

func _state() -> Dictionary:
	var um = _shell.get("unit_manager")
	var units: Array = []
	for u in um.get_all_units_including_garrisoned():
		var row: Dictionary = {}
		for k in u.keys():
			var v = u[k]
			if v is Object:
				continue
			row[str(k)] = var_to_str(v)
		units.append(row)
	units.sort_custom(func(a, b): return str(a.get("id", "")) < str(b.get("id", "")))
	var shs: Array = []
	for sh in um.get_all_strongholds():
		shs.append({"id": str(sh.structure_id), "hp": int(sh.fortification_hp), "garrison": str(sh.get_garrison_roster()), "breached": bool(sh.breached), "owner": str(sh.owner)})
	var fog = _shell.get("_fog")
	var vis: Array = []
	var exp: Array = []
	if fog != null:
		for k in (fog.get("visible") as Dictionary).keys():
			vis.append(str(k))
		for k in (fog.get("explored") as Dictionary).keys():
			exp.append(str(k))
	vis.sort()
	exp.sort()
	var cells: Dictionary = _shell.get("hex_grid").get("cell_data")
	var terr_hash: int = 0
	for key in cells.keys():
		terr_hash = hash(str(terr_hash) + str(key) + str(cells[key].terrain))
	return {
		"turn": um.get_current_turn(), "units": units, "strongholds": shs,
		"fog_visible": vis, "fog_explored": exp, "cells": cells.size(),
		"terrain_hash": terr_hash, "battle_lost": _shell.get("_battle_lost"),
		"battle_won": _shell.get("_battle_won"), "log": _log,
	}

func _issue_moves() -> void:
	var um = _shell.get("unit_manager")
	var blues: Array = []
	for u in um.get_all_units():
		if str(u.get("faction", "")) == "blue" and str(u.get("class", "")) != "hq":
			blues.append(u)
	blues.sort_custom(func(a, b): return str(a["id"]) < str(b["id"]))
	_pending_moves.clear()
	for i in range(mini(6, blues.size())):
		var u: Dictionary = blues[i]
		var dest: Vector2i = Vector2i(int(u["q"]), int(u["r"])) + ADVANCE[i % ADVANCE.size()]
		_pending_moves.append([str(u["id"]), dest])

var _pending_moves: Array = []

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
			if _frame > 30:
				_log.append("start turn=%d" % int(_shell.get("unit_manager").get_current_turn()))
				_phase = 1
		1:
			_issue_moves()
			_phase = 2
		2:
			if _pending_moves.is_empty():
				_phase = 3
			else:
				var mv: Array = _pending_moves.pop_front()
				var res: Dictionary = _shell.call("execute_step7_move", mv[0], mv[1], "auto")
				_log.append("move %s -> %s ok=%s" % [mv[0], str(mv[1]), str(res.get("success", res.get("ok", "?")))])
				_wait = 2
		3:
			_shell.call("end_player_phase")
			_phase = 4
			_wait = 2
		4:
			if _player_phase():
				_turns += 1
				_log.append("turn done -> %d" % int(_shell.get("unit_manager").get_current_turn()))
				if _turns >= TURNS or bool(_shell.get("_battle_lost")) or bool(_shell.get("_battle_won")):
					_finish("OK")
					return true
				_phase = 1
	return false

func _finish(status: String) -> void:
	var st := _state()
	st["status"] = status
	var f := FileAccess.open(_out, FileAccess.WRITE)
	f.store_string(JSON.stringify(st, "  ", true))
	f.close()
	print("[EQUIV] %s turn=%d units=%d vis=%d frames=%d" % [status, int(st["turn"]), (st["units"] as Array).size(), (st["fog_visible"] as Array).size(), _frame])
