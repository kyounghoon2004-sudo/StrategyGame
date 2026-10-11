extends SceneTree

## HAND B corpus v2 extractor (tool-only). Runtime candidate parity: the
## candidate set for every non-HQ unit comes from the REAL LayaEnumerator
## (normal-pace GREEN_ONLY MOVE, WAIT, REST/FORTIFY when the manager exposes
## them, fog-visible ATTACK), rendered with the runtime format_option_text.
## Optional scripted pre-moves (enemy repositions) run BEFORE extraction so
## the side's ledger carries legitimately last-known contacts.
## Usage: godot --headless --path <proj> -s res://tools/hand_b/extract_candidates_v2.gd -- --in a.json --out b.json

const SimControllerCls = preload("res://scripts/sim/sim_controller.gd")
const EnumCls = preload("res://scripts/laya/laya_enumerator.gd")
const LayaCtrlCls = preload("res://scripts/laya/laya_controller.gd")


func _init() -> void:
	call_deferred("_run")


func _arg(name: String) -> String:
	var a := OS.get_cmdline_user_args()
	for i in range(a.size() - 1):
		if a[i] == name:
			return a[i + 1]
	return ""


func _foes(ledger: Dictionary, side: String) -> Array:
	return (ledger.get("observed_blue_forces" if side == "red" else "current_enemy_observations", []) as Array)


func _run() -> void:
	var batch: Array = JSON.parse_string(FileAccess.get_file_as_string(_arg("--in")))
	var gs := GDScript.new()
	gs.source_code = "extends Node\nvar cell_data := {}\n"
	gs.reload()
	var out: Array = []
	for req in batch:
		var sim: RefCounted = SimControllerCls.new()
		var ld: Dictionary = sim.load_scenario(req["scenario"])
		if not bool(ld.get("ok", true)) and ld.has("error"):
			out.append({"id": req["id"], "error": str(ld.get("error", ""))})
			continue
		var mgr = sim.get_manager()
		var side: String = str(req.get("side", "red"))
		var foe_side := "blue" if side == "red" else "red"
		# Pass 1: see the initial picture (builds sightings), then scripted
		# enemy repositions -> contacts that left vision become last-known.
		sim.build_knowledge(side)
		for pm in (req.get("pre_moves", []) as Array):
			sim.do_move(str(pm["unit_id"]), int(pm["q"]), int(pm["r"]), foe_side)
		var know: Dictionary = sim.build_knowledge(side)
		var ledger: Dictionary = know.get("ledger", {})
		var troop := {}
		for f in _foes(ledger, side):
			troop[str((f as Dictionary).get("id", ""))] = str((f as Dictionary).get("troop_text", (f as Dictionary).get("troop_estimate", "?")))
		var grid := Node.new()
		grid.set_script(gs)
		grid.set("cell_data", sim.get("_cell_data"))
		var en = EnumCls.new()
		en.set_side(side)
		var cerr: String = en.configure(mgr, sim.get_service(), sim.get_projector(), grid, sim.map_bounds(), func() -> bool: return false)
		var units: Array = []
		if cerr == "":
			for u_val in (mgr.get_all_units() as Array):
				var u: Dictionary = u_val
				if str(u.get("faction", "")) != side or str(u.get("class", "")) == "hq":
					continue
				var pool: Dictionary = en.enumerate_for_unit(str(u.get("id", "")))
				if bool(pool.get("resolved", true)):
					continue
				var cands: Array = []
				for c_val in (pool.get("candidates", []) as Array):
					var c: Dictionary = (c_val as Dictionary).duplicate(true)
					if str(c.get("action_type", "")) == "ATTACK":
						c["matchup_mult"] = CombatCalculator.get_matchup_mult(str(u.get("class", "")), str(c.get("target_class", "")))
					var tid := str(c.get("target_id", ""))
					c["option_text"] = LayaCtrlCls.format_option_text(c, u, [], func(_t: String) -> String: return str(troop.get(tid, "?")))
					cands.append(c)
				units.append({"unit": {"id": str(u.get("id", "")), "class": str(u.get("class", "")), "q": int(u.get("q", 0)), "r": int(u.get("r", 0)),
					"soldier_count": int(u.get("soldier_count", 0)), "max_count": int(u.get("max_count", 0)), "morale": float(u.get("morale", 100.0)),
					"base_mp": float(u.get("base_mp", 2.0)), "remaining_mp": float(u.get("remaining_mp", 0.0))}, "candidates": cands})
		grid.free()
		out.append({"id": req["id"], "side": side, "turn": int(know.get("current_turn", 1)), "bounds": sim.map_bounds(),
			"ledger": ledger, "enum_error": cerr, "units": units})
	var fo := FileAccess.open(_arg("--out"), FileAccess.WRITE)
	fo.store_string(JSON.stringify(out))
	fo.close()
	quit(0)
