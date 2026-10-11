extends SceneTree

## ============================================================================
## PRODUCTION FOOD/SUPPLY PROBE (cold, independent)
## ============================================================================
## Boots the REAL production battle scene (step2r_battlefield_shell.tscn), then
## performs a full played cycle through the ON-CANONICAL paths:
##   move (execute_step7_move) -> attack (service/manager) -> End Turn -> enemy
##   turn -> next player turn
## recording every food/supply-bearing unit field before/after each step.
##
## Purpose (verification task): reproduce "move consumed food=2" claim against
## the CURRENT repository state, and afterwards prove the retirement fix with a
## zero-delta food/supply trace.
##
## Run (fresh process, headless):
##   Godot_v4.2.2-stable_win64_console.exe --headless --path "<proj>" \
##     -s res://scripts/cloud1/audit/cloud1_prod_food_probe.gd
##
## Writes: evidence/cloud1_audit/prod_food_probe_<runid>.json (UTF-8)
## Exit code: always 0 (diagnostic probe; the gates live in the contract audit).

const PROD_SCENE := "res://scenes/step2r_battlefield_shell.tscn"
const REPORT_DIR := "D:/Game development/Demon slayer/StrategyGame/evidence/cloud1_audit"
const TOKENS := ["food", "supply", "ration", "convoy", "hungry", "stockpile", "starv"]

var scene: Node = null
var mgr: Variant = null
var service: Variant = null
var steps: Dictionary = {}
var _move_done := false
var _move_res: Dictionary = {}
var run_id := ""


func _initialize() -> void:
	_run()


func _food_keys(u: Dictionary) -> Dictionary:
	var out := {}
	for k in u.keys():
		var lk := str(k).to_lower()
		for t in TOKENS:
			if lk.contains(t):
				out[str(k)] = u[k]
				break
	return out


func _snapshot(label: String) -> Dictionary:
	var units := []
	var food_bearing := {}
	var morale_map := {}
	for u in (mgr.get_all_units_including_garrisoned() if mgr != null else []):
		if not (u is Dictionary):
			continue
		var uid := str((u as Dictionary).get("id", ""))
		units.append(uid)
		var fk := _food_keys(u as Dictionary)
		if not fk.is_empty():
			food_bearing[uid] = fk
		morale_map[uid] = float((u as Dictionary).get("morale", -1.0))
	var snap := {
		"label": label,
		"turn": int(mgr.get_current_turn()) if mgr != null else -1,
		"unit_count": units.size(),
		"food_supply_bearing_units": food_bearing,
		"food_supply_key_count": food_bearing.size(),
		"morale": morale_map,
	}
	steps[label] = snap
	print("[PROBE] %s | turn=%d | units=%d | food_supply_bearing=%d" % [label, int(snap["turn"]), int(snap["unit_count"]), int(snap["food_supply_key_count"])])
	return snap


func _on_move(res: Dictionary) -> void:
	_move_res = res
	_move_done = true


func _run() -> void:
	run_id = str(Time.get_unix_time_from_system()) + "_" + Time.get_datetime_string_from_system(true).replace(":", "").replace("-", "").replace("T", "_")
	print("========================================================")
	print("PRODUCTION FOOD/SUPPLY PROBE | run %s" % run_id)
	print("========================================================")
	change_scene_to_file(PROD_SCENE)
	await process_frame
	await process_frame
	await process_frame
	scene = current_scene
	if scene == null:
		print("[PROBE] production scene failed to load")
		_finish("scene_load_failed")
		return
	var ok_boot := false
	for _i in range(1800):
		await process_frame
		if scene.get("unit_manager") != null and scene.get("hex_grid") != null:
			ok_boot = true
			break
	if not ok_boot:
		print("[PROBE] production shell did not initialize")
		_finish("boot_failed")
		return
	mgr = scene.get("unit_manager")
	service = scene.get("_battle_command_service")
	var cfg := {
		"is_step0_sandbox": scene.get("is_step0_sandbox"),
		"step6": str(scene.get("_step6")),
		"supply_panel": str(scene.get("_supply_panel")),
		"supply_label": str(scene.get("_supply_label")),
		"battle_command_service_present": service != null,
	}
	print("[PROBE] boot cfg: %s" % str(cfg))
	_snapshot("s0_boot")

	# ---- MOVE: first blue non-hq combat unit through the production path ----
	var p_blue := ""
	for u in mgr.get_all_units_including_garrisoned():
		if u is Dictionary and str((u as Dictionary).get("faction", "")) == "blue" \
				and int((u as Dictionary).get("soldier_count", 0)) > 0 \
				and str((u as Dictionary).get("class", "")) != "hq":
			p_blue = str((u as Dictionary).get("id", ""))
			break
	var move_info := {"unit": p_blue}
	if not p_blue.is_empty():
		var u_from: Dictionary = mgr.get_unit_by_id(p_blue)
		var fq := int(u_from.get("q", 0))
		var fr := int(u_from.get("r", 0))
		var targets: Array = []
		if service != null and service.has_method("reachable_area"):
			var area: Dictionary = service.call("reachable_area", p_blue, "blue", "auto")
			targets = area.get("reachable", []) if area.get("reachable", []) is Array else []
		var dest := Vector2i(-999, -999)
		if not targets.is_empty():
			var t: Dictionary = targets[targets.size() - 1]
			dest = Vector2i(int(t.get("q", 0)), int(t.get("r", 0)))
		if dest.x != -999 and scene.has_method("execute_step7_move"):
			_move_done = false
			scene.call("execute_step7_move", p_blue, dest, "auto", Callable(self, "_on_move"))
			for _i in range(2400):
				await process_frame
				if _move_done:
					break
			var u_after: Dictionary = mgr.get_unit_by_id(p_blue)
			move_info["from"] = [fq, fr]
			move_info["requested"] = [dest.x, dest.y]
			move_info["to"] = [int(u_after.get("q", -999)), int(u_after.get("r", -999))]
			move_info["reachable_count"] = targets.size()
			move_info["move_result"] = _move_res
			if not _move_res.is_empty():
				move_info["result_food_consumed_field"] = _move_res.get("food_consumed", "<absent>")
				move_info["result_march_class"] = _move_res.get("march_class", -1)
				move_info["result_morale_after"] = _move_res.get("morale", -1)
			var u_moved: Dictionary = mgr.get_unit_by_id(p_blue)
			move_info["unit_food_fields_after"] = _food_keys(u_moved)
	print("[PROBE] move: %s" % str(move_info))
	steps["s1_after_move_info"] = move_info
	_snapshot("s1_after_move")

	# ---- ATTACK: first blue attacker with a legal target (authoritative path) ----
	var attack_info := {"executed": false}
	var attacker := ""
	var defender := ""
	for u in mgr.get_all_units_including_garrisoned():
		if not (u is Dictionary):
			continue
		if str((u as Dictionary).get("faction", "")) != "blue":
			continue
		if bool((u as Dictionary).get("action_ended", false)) or bool((u as Dictionary).get("garrisoned", false)):
			continue
		var ts: Array = mgr.get_attackable_targets(str((u as Dictionary).get("id", "")))
		if not ts.is_empty():
			attacker = str((u as Dictionary).get("id", ""))
			defender = str((ts[0] as Dictionary).get("id", ""))
			break
	if not attacker.is_empty():
		var d_before: Dictionary = mgr.get_unit_by_id(defender)
		var hp_before := int(d_before.get("soldier_count", 0))
		var res: Dictionary = {}
		if service != null and service.has_method("execute_attack_intent"):
			res = service.call("execute_attack_intent", attacker, defender, "blue", {})
		else:
			res = mgr.execute_attack(attacker, defender, {})
		var d_after: Dictionary = mgr.get_unit_by_id(defender)
		attack_info = {
			"executed": true,
			"attacker": attacker,
			"defender": defender,
			"hp_before": hp_before,
			"hp_after": int(d_after.get("soldier_count", 0)) if not d_after.is_empty() else 0,
			"attacker_food_fields_after": _food_keys(mgr.get_unit_by_id(attacker)),
			"defender_food_fields_after": _food_keys(d_after) if not d_after.is_empty() else {},
			"result_keys": res.keys(),
			"result_food_consumed_field": res.get("food_consumed", "<absent>"),
		}
	else:
		attack_info = {"executed": false, "reason": "no legal attack at probe time"}
	print("[PROBE] attack: %s" % str(attack_info))
	steps["s2_after_attack_info"] = attack_info
	_snapshot("s2_after_attack")

	# ---- END TURN -> enemy turn -> next player turn (twice) ----
	for n in range(2):
		var prev := int(mgr.get_current_turn())
		scene.call("end_player_phase")
		var advanced := false
		for _i in range(14400):
			await process_frame
			if int(scene.get("_turn_phase")) == 0 and int(mgr.get_current_turn()) == prev + 1:
				advanced = true
				break
		print("[PROBE] end turn #%d -> advanced=%s, turn=%d" % [n + 1, str(advanced), int(mgr.get_current_turn())])
		_snapshot("s%d_after_end_turn_%d" % [n + 3, n + 1])

	_finish("ok")


func _finish(status: String) -> void:
	var doc := {
		"probe": "PRODUCTION-FOOD-SUPPLY-PROBE",
		"run_id": run_id,
		"status": status,
		"started_iso": Time.get_datetime_string_from_system(true),
		"godot_version": Engine.get_version_info(),
		"steps": steps,
	}
	DirAccess.make_dir_recursive_absolute(REPORT_DIR)
	var path := REPORT_DIR + "/prod_food_probe_" + run_id + ".json"
	var wf := FileAccess.open(path, FileAccess.WRITE)
	if wf != null:
		wf.store_string(JSON.stringify(doc, "  "))
		print("[PROBE] wrote %s" % path)
	else:
		printerr("[PROBE] could not write %s" % path)
	# summary decision line
	var bearing_total := 0
	for label in steps.keys():
		var s: Variant = steps[label]
		if s is Dictionary and (s as Dictionary).has("food_supply_key_count"):
			bearing_total += int((s as Dictionary).get("food_supply_key_count", 0))
	var move_res: Dictionary = steps.get("s1_after_move_info", {}) as Dictionary
	var result_food: Variant = move_res.get("result_food_consumed_field", "<absent>")
	print("========================================================")
	print("PROBE RESULT: status=%s | food/supply-bearing units summed=%d | move food_consumed field=%s" % [status, bearing_total, str(result_food)])
	print("========================================================")
	quit(0)
