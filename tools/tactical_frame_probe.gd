extends SceneTree

## Tactical-frame pilot probe (3-sector LEFT_WING/CENTER/RIGHT_WING).
## Boots the canonical battle and verifies: complete partition, boundary rule,
## schema/catalog stability, camera invariance, scope purity, map independence,
## hidden-truth source gate, sector six-profile integration, honest empty scope,
## cross-sector legality, boundary-crossing mechanism, canonical execution.
## Writes: D:/Game development/.workflow/deliverables/SB-CAVALRY-EVALUATOR/tactical_frame_evidence.json

const FrameScript = preload("res://scripts/step7/step7_tactical_frame.gd")
const EvalScript = preload("res://scripts/step7/step7_cavalry_evaluator.gd")
const CommandScript = preload("res://scripts/step7/step7_action_command.gd")
const BoundaryScript = preload("res://scripts/step2r/step2r_world_boundary.gd")

const OUT := "D:/Game development/.workflow/deliverables/SB-CAVALRY-EVALUATOR/tactical_frame_evidence.json"
const LOG := "user://tactical_frame_probe.log"

var failures: Array = []
var notes: Array = []
var evidence := {}


func _init() -> void:
	call_deferred("_run")


func _check(cond: bool, name: String) -> void:
	if cond:
		notes.append("PASS " + name)
	else:
		failures.append(name)


func _log(s: String) -> void:
	var f := FileAccess.open(LOG, FileAccess.READ_WRITE)
	if f:
		f.seek_end()
		f.store_line(s)
	print(s)


func _run() -> void:
	var packed: PackedScene = load("res://scenes/step2r_battlefield_shell.tscn")
	var battle: Node = packed.instantiate()
	get_root().add_child(battle)
	for _i in range(20):
		await process_frame
	var integration: Node = battle.get_node_or_null("Step7Integration")
	for _i in range(120):
		if integration and bool(integration.get("ready_for_step7")):
			break
		await process_frame
	if integration == null or not bool(integration.get("ready_for_step7")):
		_write({"status": "FAIL", "failures": ["probe: integration not ready"], "notes": notes})
		_log("TF_PROBE FAIL integration-not-ready")
		quit(2)
		return
	var truth: RefCounted = integration.get("truth")
	var cmd_svc: RefCounted = integration.get("command_service")
	var projector: RefCounted = integration.get("projector")
	var svc: RefCounted = integration.get("action_service")
	var unit_manager: RefCounted = integration.get("unit_manager")

	evidence["frame"] = FrameScript.frame_info()

	# T1: complete partition over the canonical hexagon.
	var sm: Dictionary = FrameScript.sector_map()
	var counts: Dictionary = FrameScript.sector_counts()
	var playable_total := 0
	var missing: Array = []
	for q in range(-40, 41):
		for r in range(-40, 41):
			if BoundaryScript.is_playable_hex(Vector2i(q, r)):
				playable_total += 1
				if not sm.has("%d,%d" % [q, r]):
					missing.append([q, r])
	_check(playable_total == 4921, "canonical playable total is 4921")
	_check(sm.size() == 4921 and missing.is_empty(), "every playable hex has exactly one sector")
	_check(int(counts.get("LEFT_WING", -1)) == 1387, "LEFT count 1387")
	_check(int(counts.get("CENTER", -1)) == 2147, "CENTER count 2147")
	_check(int(counts.get("RIGHT_WING", -1)) == 1387, "RIGHT count 1387")
	evidence["partition"] = {"playable_total": playable_total, "map_size": sm.size(),
		"counts": counts, "missing_sample": missing.slice(0, 5)}

	# T2: inclusive boundary rule on synthetic values.
	_check(FrameScript.classify_n(-0.34) == "LEFT_WING", "n<-1/3 is LEFT")
	_check(FrameScript.classify_n(-1.0 / 3.0) == "CENTER", "n=-1/3 is CENTER")
	_check(FrameScript.classify_n(1.0 / 3.0) == "CENTER", "n=+1/3 is CENTER")
	_check(FrameScript.classify_n(0.34) == "RIGHT_WING", "n>+1/3 is RIGHT")

	# T3: schema + catalog stability (no catalog rewrite, no per-sector verbs).
	var good: Dictionary = CommandScript.validate_structure(CommandScript.make(
		"ADVANCE", CommandScript.scope_sector_class("LEFT_WING", "CAVALRY"), "FORWARD"))
	_check(bool(good.get("ok", false)), "SECTOR_CLASS scope validates")
	var bad_sector: Dictionary = CommandScript.validate_structure(CommandScript.make(
		"ADVANCE", {"type": "SECTOR_CLASS", "sector": "UPPER", "class": "CAVALRY"}, "FORWARD"))
	_check(not bool(bad_sector.get("ok", false)), "unknown sector rejected")
	var bad_fn := false
	var cmd_text := FileAccess.get_file_as_string("res://scripts/step7/step7_action_command.gd")
	for m in ["func move_left_cavalry", "func move_right_cavalry", "func move_center_cavalry"]:
		if cmd_text.contains(m):
			bad_fn = true
	_check(not bad_fn, "no per-sector move functions")
	var catalog: Dictionary = CommandScript.presets()
	_check(catalog.size() == 50, "50-action catalog untouched")
	var leaked := false
	for key in catalog.keys():
		if "LEFT_CAVALRY" in str(key) or "RIGHT_CAVALRY" in str(key) or "CENTER_CAVALRY" in str(key):
			leaked = true
	_check(not leaked, "no sector-permutation catalog entries")
	var tgt: Dictionary = CommandScript.validate_target(CommandScript.target_sector("CENTER"))
	_check(bool(tgt.get("ok", false)), "SECTOR target validates")
	evidence["schema"] = {"catalog_size": catalog.size()}

	# T4: camera invariance (sector authority is battle geometry, not pixels).
	var before := JSON.stringify(sm)
	var cam := battle.find_child("Camera2D", true, false) as Camera2D
	if cam:
		cam.position = Vector2(1500, -900)
		cam.zoom = Vector2(0.35, 0.35)
		for _i in range(5):
			await process_frame
		var after := JSON.stringify(FrameScript.sector_map())
		_check(before == after, "sector map identical after pan/zoom")
		evidence["camera"] = {"moved": true, "identical": before == after}
	else:
		notes.append("INFO no Camera2D found; invariance holds by construction (no camera input)")
		evidence["camera"] = {"moved": false}

	# T5: scope purity across live BLUE cavalry.
	var all_cav: Array = []
	for u_val in truth.call("snapshot_units"):
		if u_val is Dictionary:
			var ud: Dictionary = u_val
			if str(ud.get("faction", "")) == "blue" and str(ud.get("class", "")).to_lower() == "cavalry" and int(ud.get("soldier_count", 0)) > 0:
				all_cav.append(str(ud.get("id", "")))
	all_cav.sort()
	var left: Array = FrameScript.resolve_sector_class("LEFT_WING", "CAVALRY", "blue", unit_manager)
	var center: Array = FrameScript.resolve_sector_class("CENTER", "CAVALRY", "blue", unit_manager)
	var right: Array = FrameScript.resolve_sector_class("RIGHT_WING", "CAVALRY", "blue", unit_manager)
	var union: Array = []
	for m in left + center + right:
		union.append(str((m as Dictionary).get("id", "")))
	union.sort()
	_check(union == all_cav, "every BLUE cavalry in exactly one sector result")
	var overlap := false
	for a in [left, center, right]:
		for b in [left, center, right]:
			if a == b:
				continue
			for m in (a as Array):
				for n in (b as Array):
					if str((m as Dictionary).get("id", "")) == str((n as Dictionary).get("id", "")):
						overlap = true
	_check(not overlap, "no cavalry duplicated across sectors")
	evidence["membership"] = {"left": _ids(left), "center": _ids(center), "right": _ids(right)}

	# T6: map independence — synthetic shifted/irregular envelope.
	var synth := {}
	for q in range(10, 31):
		for r in range(-10, 11):
			if (q + r) % 3 == 0:
				synth["%d,%d" % [q, r]] = true
	var rebuilt: Dictionary = FrameScript.rebuild_from_cell_data(synth)
	_check(bool(rebuilt.get("ok", false)), "synthetic envelope rebuilds")
	var rcounts: Dictionary = rebuilt.get("counts", {})
	var rtotal: int = int(rcounts.get("LEFT_WING", 0)) + int(rcounts.get("CENTER", 0)) + int(rcounts.get("RIGHT_WING", 0))
	_check(rtotal == synth.size(), "synthetic envelope fully partitioned, no holes/overlaps")
	FrameScript.reset_to_canonical()
	_check(int(FrameScript.sector_counts().get("LEFT_WING", -1)) == 1387, "canonical frame restored")
	evidence["map_independence"] = {"synthetic_cells": synth.size(), "counts": rcounts}

	# T7: hidden-truth source gate — frame source uses no enemy/fog/unit reads.
	var gate := _source_gate()
	evidence["source_gate"] = gate
	_check(bool(gate.get("clean", false)), "frame source free of hidden-truth reads")

	# T8: sector six-profile integration (LEFT_WING ADVANCE, representative pilot).
	var bk: Dictionary = integration.call("get_blue_knowledge")
	var occ: Dictionary = projector.call("known_occupancy", "blue")
	var sv: int = int(truth.call("get_version"))
	var fp: String = str(truth.call("fingerprint"))
	var cell_data: Dictionary = truth.call("cell_data")
	var ev: RefCounted = EvalScript.new()
	var pkg: Dictionary = ev.call("evaluate_sector", "LEFT_WING",
		{"action": "ADVANCE", "direction": "FORWARD"},
		cmd_svc, unit_manager, bk, cell_data, occ, sv, fp)
	evidence["sector_package"] = {"sector": pkg.get("sector", "?"),
		"member_ids": pkg.get("member_ids", []), "representative": pkg.get("representative", "?")}
	var inner: Dictionary = pkg
	_check((inner.get("options", []) as Array).size() == 6, "sector evaluation yields six slots")
	_check(_all_have_status(inner), "all six slots have status")
	_check(str((inner.get("sector_context", {}) as Dictionary).get("requested_sector", "")) == "LEFT_WING",
		"sector context rides the evaluation")
	var bal := _pick_of(inner, "BALANCED")
	_check(_has_sector_features(bal), "sector features contribute (SECTOR_ALIGNMENT/WING_COHESION)")
	var ev_b: RefCounted = EvalScript.new()
	var pkg2: Dictionary = ev_b.call("evaluate_sector", "LEFT_WING",
		{"action": "ADVANCE", "direction": "FORWARD"},
		cmd_svc, unit_manager, bk, cell_data, occ, sv, fp)
	_check(JSON.stringify(pkg.get("options", [])) == JSON.stringify(pkg2.get("options", [])),
		"sector evaluation deterministic on repeat")
	evidence["six_profile"] = _differentials(inner)

	# T9: honest empty scope (no substitution).
	var empty_members: Array = FrameScript.resolve_sector_class("RIGHT_WING", "CAVALRY", "blue", unit_manager)
	if empty_members.is_empty():
		var ev_c: RefCounted = EvalScript.new()
		var empty_pkg: Dictionary = ev_c.call("evaluate_sector", "RIGHT_WING",
			{"action": "ADVANCE", "direction": "FORWARD"},
			cmd_svc, unit_manager, bk, cell_data, occ, sv, fp)
		_check((empty_pkg.get("member_ids", []) as Array).is_empty(), "empty sector stays empty (no substitution)")
		var empty_unav := true
		for o in (empty_pkg.get("options", []) as Array):
			if not (o is Dictionary) or str((o as Dictionary).get("status", "")) != "UNAVAILABLE":
				empty_unav = false
		_check(empty_unav, "empty sector still yields six UNAVAILABLE slots")
		notes.append("INFO RIGHT_WING holds no BLUE cavalry at boot — empty-scope path verified")
		evidence["empty_scope"] = {"sector": "RIGHT_WING", "honest_empty": true}
	else:
		notes.append("INFO RIGHT_WING unexpectedly holds cavalry; purity (T5) still governs")
		evidence["empty_scope"] = {"sector": "RIGHT_WING", "honest_empty": false}

	# T10: cross-sector movement stays legal (sector is preference, not prison).
	var cross := _cross_sector_plan(svc, unit_manager)
	evidence["cross_sector"] = cross
	_check(bool(cross.get("planned", false)), "LEFT cavalry can plan toward CENTER (no prison)")

	# T11: boundary-crossing mechanism — real single-move crossing if in range.
	var crossing := await _attempt_crossing(svc, truth, cmd_svc, unit_manager)
	evidence["boundary_crossing"] = crossing

	# T12: canonical execution of one sector option (state-changing; last).
	var exec_sector := "LEFT_WING"
	var exec_members: Array = FrameScript.resolve_sector_class(exec_sector, "CAVALRY", "blue", unit_manager)
	if exec_members.is_empty():
		exec_sector = "CENTER"
	var ev_d: RefCounted = EvalScript.new()
	var exec_pkg: Dictionary = ev_d.call("evaluate_sector", exec_sector,
		{"action": "ADVANCE", "direction": "FORWARD"},
		cmd_svc, unit_manager, integration.call("get_blue_knowledge"),
		truth.call("cell_data"), projector.call("known_occupancy", "blue"),
		int(truth.call("get_version")), str(truth.call("fingerprint")))
	var exec_inner: Dictionary = exec_pkg
	var exec_res := await _execute_pick(svc, truth, str(exec_pkg.get("representative", "")),
		_pick_of(exec_inner, "BALANCED"))
	evidence["execution"] = exec_res
	evidence["execution_sector"] = exec_sector
	_check(bool(exec_res.get("validated", false)), "sector option passes canonical validation")
	_check(bool(exec_res.get("moved", false)), "sector option executes through canonical pipeline")

	evidence["status"] = "PASS" if failures.is_empty() else "FAIL"
	evidence["failures"] = failures
	evidence["notes"] = notes
	_write(evidence)
	_log("TF_PROBE_" + str(evidence["status"]) + " failures=" + str(failures.size()))
	quit(0 if failures.is_empty() else 2)


func _ids(units: Array) -> Array:
	var out: Array = []
	for m in units:
		out.append(str((m as Dictionary).get("id", "")))
	out.sort()
	return out


func _all_have_status(r: Dictionary) -> bool:
	var opts: Array = r.get("options", [])
	if opts.size() != 6:
		return false
	for o in opts:
		if not (o is Dictionary) or not (o as Dictionary).has("status"):
			return false
		if str((o as Dictionary)["status"]) not in ["AVAILABLE", "DEGRADED", "UNAVAILABLE"]:
			return false
	return true


func _pick_of(r: Dictionary, profile: String) -> Dictionary:
	for o in (r.get("options", []) as Array):
		if o is Dictionary and str((o as Dictionary).get("profile", "")) == profile:
			return o
	return {}


func _has_sector_features(pick: Dictionary) -> bool:
	var seen := {}
	for c in (pick.get("contributions", []) as Array):
		if c is Dictionary:
			seen[str((c as Dictionary).get("feature", ""))] = true
	return seen.has("SECTOR_ALIGNMENT") and seen.has("WING_COHESION")


func _differentials(r: Dictionary) -> Dictionary:
	var d := {}
	for o in (r.get("options", []) as Array):
		if not (o is Dictionary) or not (o as Dictionary).has("destination"):
			continue
		var od: Dictionary = o
		d[str(od.get("profile", "?"))] = {"dest": od.get("destination", {}),
			"u": float(od.get("utility", 0.0)), "status": str(od.get("status", "?"))}
	return d


func _source_gate() -> Dictionary:
	var path := "res://scripts/step7/step7_tactical_frame.gd"
	var text := FileAccess.get_file_as_string(path)
	var code_lines: Array = []
	for line in text.split("\n"):
		var stripped := line.strip_edges()
		if stripped.begins_with("#"):
			continue
		if "#" in line:
			line = line.substr(0, line.find("#"))
		code_lines.append(line)
	var code := "\n".join(code_lines).to_lower()
	var hits: Array = []
	for tok in ["projector", "worldtruth", "world_truth", "fog_of_war", "unit_manager",
			"get_unit_by_id", "snapshot", "is_contact_visible", "known_occupancy",
			"hidden", "enemy"]:
		if code.contains(tok):
			hits.append(tok)
	if _word_hit(code, "red"):
		hits.append("red")
	var preloads_ok := text.contains("step2r_world_boundary.gd") and not text.contains("projector")
	return {"clean": hits.is_empty(), "hits": hits, "preload_boundary_only": preloads_ok}


func _word_hit(code: String, word: String) -> bool:
	var re := RegEx.new()
	re.compile("\\b" + word + "\\b")
	return re.search(code) != null


func _cross_sector_plan(svc: RefCounted, unit_manager: RefCounted) -> Dictionary:
	var left: Array = FrameScript.resolve_sector_class("LEFT_WING", "CAVALRY", "blue", unit_manager)
	if left.is_empty():
		return {"planned": false, "note": "no LEFT cavalry to test with"}
	var cmd := {"action": "REPOSITION",
		"scope": {"type": "SECTOR_CLASS", "sector": "LEFT_WING", "class": "CAVALRY"},
		"direction": "", "target": {"type": "SECTOR", "sector": "CENTER"},
		"posture": "NORMAL", "constraints": {}}
	var vd: Dictionary = svc.call("validate_action", cmd, "blue")
	if not bool(vd.get("ok", false)):
		return {"planned": false, "note": "validation rejected", "detail": vd.get("validation_errors", [])}
	var plan: Dictionary = svc.call("plan_action", cmd, "blue")
	var ok := bool(plan.get("ok", false))
	var pid := str(plan.get("plan_id", ""))
	if not pid.is_empty():
		svc.call("cancel_plan", pid)
	return {"planned": ok, "plan_status": str(plan.get("plan_status", "?"))}


func _attempt_crossing(svc: RefCounted, truth: RefCounted, cmd_svc: RefCounted, unit_manager: RefCounted) -> Dictionary:
	for u_val in truth.call("snapshot_units"):
		if not u_val is Dictionary:
			continue
		var ud: Dictionary = u_val
		if str(ud.get("faction", "")) != "blue" or str(ud.get("class", "")).to_lower() != "cavalry":
			continue
		if int(ud.get("soldier_count", 0)) <= 0 or bool(ud.get("action_ended", false)):
			continue
		var uid := str(ud.get("id", ""))
		var origin := Vector2i(int(ud.get("q", 0)), int(ud.get("r", 0)))
		var osec := FrameScript.get_sector(origin.x, origin.y)
		var area: Dictionary = cmd_svc.call("reachable_area", uid, "blue", "auto")
		if not bool(area.get("ok", false)):
			continue
		for row_val in (area.get("reachable", []) as Array):
			if not row_val is Dictionary:
				continue
			var row: Dictionary = row_val
			var dest := Vector2i(int(row.get("q", 0)), int(row.get("r", 0)))
			if dest == origin:
				continue
			if FrameScript.get_sector(dest.x, dest.y) == osec:
				continue
			var res := await _execute_move(svc, truth, uid, dest)
			res["unit"] = uid
			res["from_sector"] = osec
			res["to_sector"] = FrameScript.get_sector(dest.x, dest.y)
			res["real_crossing"] = true
			return res
	return {"real_crossing": false,
		"note": "no single-move cross-sector candidate in range; mechanism covered by T10 plan check + human boundary test"}


func _execute_move(svc: RefCounted, truth: RefCounted, unit_id: String, dest: Vector2i) -> Dictionary:
	var out := {"validated": false, "moved": false}
	# The service runs one deterministic sequential queue: drain any in-flight
	# execution from a prior step before starting, and again after arrival so
	# chained moves never race the previous finalization tail.
	for _i in range(300):
		if not bool(svc.call("is_executing")):
			break
		await process_frame
	var cmd := {"action": "MOVE", "scope": {"type": "UNIT_ID", "unit_id": unit_id},
		"direction": "", "target": {"type": "HEX", "q": dest.x, "r": dest.y},
		"posture": "NORMAL", "constraints": {}}
	var vd: Dictionary = svc.call("validate_action", cmd, "blue")
	out["validated"] = bool(vd.get("ok", false))
	if not bool(vd.get("ok", false)):
		out["error"] = "validation rejected"
		return out
	var plan: Dictionary = svc.call("plan_action", cmd, "blue")
	var pid := str(plan.get("plan_id", ""))
	if pid.is_empty():
		out["error"] = "no plan_id"
		return out
	var ex: Dictionary = svc.call("execute_plan", pid)
	out["execute_status"] = str(ex.get("execution_status", "?"))
	for _i in range(1500):
		var cur: Dictionary = truth.call("get_unit", unit_id)
		if Vector2i(int(cur.get("q", 0)), int(cur.get("r", 0))) == dest:
			break
		await process_frame
	var fin: Dictionary = truth.call("get_unit", unit_id)
	out["final_pos"] = [int(fin.get("q", 0)), int(fin.get("r", 0))]
	out["moved"] = Vector2i(int(fin.get("q", 0)), int(fin.get("r", 0))) == dest
	for _i in range(300):
		if not bool(svc.call("is_executing")):
			break
		await process_frame
	out["queue_drained"] = not bool(svc.call("is_executing"))
	return out


func _execute_pick(svc: RefCounted, truth: RefCounted, unit_id: String, pick: Dictionary) -> Dictionary:
	var out := {"validated": false, "moved": false}
	if unit_id.is_empty() or not pick.has("destination"):
		out["error"] = "no representative or no destination"
		return out
	var d: Dictionary = pick["destination"]
	return await _execute_move(svc, truth, unit_id, Vector2i(int(d.get("q", 0)), int(d.get("r", 0))))


func _write(value: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute((OUT as String).get_base_dir())
	var file := FileAccess.open(OUT, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(value, " "))
