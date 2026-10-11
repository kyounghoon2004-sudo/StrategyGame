extends SceneTree

## STEP 7 semantic execution matrix (§39): representative dimensions only.
## Preview/validate accounting + HOLD_ALL execute regression + same-turn
## UNIT_NOT_READY + exact-unit + collision + no-inference checks.
## Boots ONE fresh battle; previews never mutate, execution runs last.
## Evidence: evidence/step7_matrix_50.json

const AC = preload("res://scripts/step7/step7_action_command.gd")
const OUT := "D:/Game development/Demon slayer/StrategyGame/evidence/step7_matrix_50.json"

var failures: Array = []
var notes: Array = []
var finished_res: Dictionary = {}


func _init() -> void:
	call_deferred("_run")


func _check(cond: bool, name: String) -> void:
	if cond:
		notes.append("PASS " + name)
	else:
		failures.append(name)


func _only_class(res: Dictionary, want: String) -> bool:
	var resolved: Array = res.get("resolved_units", [])
	if resolved.is_empty():
		return false
	for a in resolved:
		if a is Dictionary and str((a as Dictionary).get("class", "")).to_upper() != want:
			return false
	return true


func _unexplained(res: Dictionary) -> int:
	var n := 0
	for c in res.get("candidate_units", []):
		if c is Dictionary:
			if not bool((c as Dictionary).get("initially_planned", false)) and str((c as Dictionary).get("initial_code", "")).is_empty():
				n += 1
	return n


func _dupe_dest(res: Dictionary) -> Array:
	var seen := {}
	var dupes: Array = []
	for a in res.get("resolved_units", []):
		if a is Dictionary and (a as Dictionary).has("to"):
			var k := JSON.stringify((a as Dictionary)["to"])
			if seen.has(k):
				dupes.append(k)
			else:
				seen[k] = true
	return dupes


func _any_rej_code(res: Dictionary, code: String) -> bool:
	for r in res.get("rejected_units", []):
		if r is Dictionary and str((r as Dictionary).get("code", "")) == code:
			return true
	for e in res.get("validation_errors", []):
		if e is Dictionary and str((e as Dictionary).get("code", "")) == code:
			return true
	return false


## Advisor-owned transports (advisory only, never gameplay resolution):
## the panel selector client + the chat commander client. Gameplay stays
## deterministic; any OTHER HTTPRequest under the integration is a
## gameplay-inference leak and fails the gate.
func _foreign_http(n: Node, acc: Array) -> void:
	if n is HTTPRequest:
		var nm := str(n.name)
		if nm != "OllamaAdvisorClient" and nm != "ChatCommanderClient" \
				and nm != "OllamaChatRequest":
			acc.append(str(_battle_path(n)))
	for ch in n.get_children():
		_foreign_http(ch, acc)


func _battle_path(n: Node) -> String:
	var parts: Array = []
	var cur: Node = n
	while cur != null:
		parts.push_front(str(cur.name))
		cur = cur.get_parent()
	return "/".join(parts)


func _count_http(n: Node) -> int:
	var c := 0
	if n is HTTPRequest:
		c += 1
	for ch in n.get_children():
		c += _count_http(ch)
	return c


func _run() -> void:
	var packed: PackedScene = load("res://scenes/step2r_battlefield_shell.tscn")
	var battle: Node = packed.instantiate()
	get_root().add_child(battle)
	for _i in range(20):
		await process_frame
	var integration: Node = battle.get_node_or_null("Step7Integration")
	for _i in range(180):
		if integration and bool(integration.get("ready_for_step7")):
			break
		await process_frame
	if integration == null or not bool(integration.get("ready_for_step7")):
		failures.append("integration not ready")
		_write()
		quit(2)
		return
	var svc: RefCounted = integration.get("action_service")
	var truth: RefCounted = integration.get("truth")
	var presets: Dictionary = AC.presets()
	var foreign: Array = []
	_foreign_http(integration, foreign)
	_check(foreign.is_empty(), "no-inference: no non-advisor HTTPRequest nodes (gameplay LLM/MCP = 0, foreign=%s)" % str(foreign))
	# Representative dimensions: group / scope / verb coverage.
	var dims := [
		["ADVANCE_ALL_FORWARD", "GENERAL/ALL/directional", ""],
		["ADVANCE_ALL_LEFT", "GENERAL/ALL/LEFT axis", ""],
		["HOLD_ALL", "GENERAL/ALL/HOLD", ""],
		["RETREAT_ALL", "GENERAL/ALL/RETREAT", ""],
		["REGROUP_ALL_TO_HQ", "GENERAL/ALL/target REGROUP", ""],
		["WITHDRAW_ALL_TO_HQ", "GENERAL/ALL/target WITHDRAW", ""],
		["ADVANCE_CAVALRY_RIGHT", "CAVALRY/CLASS", "CAVALRY"],
		["FLANK_CAVALRY_LEFT", "CAVALRY/FLANK", "CAVALRY"],
		["WITHDRAW_CAVALRY_TO_HQ", "CAVALRY/target", "CAVALRY"],
		["RECON_SCOUT_FORWARD", "SCOUT/RECON", "SCOUT"],
		["RECON_SCOUT_SOUTH", "SCOUT/RECON south", "SCOUT"],
		["ADVANCE_INFANTRY_FORWARD", "INFANTRY/CLASS", "INFANTRY"],
		["PROTECT_HQ_INFANTRY", "INFANTRY/PROTECT", "INFANTRY"],
		["REPOSITION_INFANTRY_TO_STRONGHOLD", "INFANTRY/STRONGHOLD", "INFANTRY"],
		["ADVANCE_SPEARMAN_FORWARD", "SPEARMAN/CLASS", "SPEARMAN"],
		["REPOSITION_ARCHER_FORWARD", "ARCHER/REPOSITION", "ARCHER"],
		["REPOSITION_ARCHER_BACK", "ARCHER/REPOSITION back", "ARCHER"],
		["ADVANCE_SIEGE_FORWARD", "SIEGE/CLASS", "SIEGE"],
		["REPOSITION_SIEGE_TO_STRONGHOLD", "SIEGE/STRONGHOLD", "SIEGE"],
		["RETREAT_SCOUT", "SCOUT/RETREAT", "SCOUT"],
	]
	for d in dims:
		var pid := str(d[0])
		var cmd: Dictionary = ((presets[pid] as Dictionary).get("command", {}) as Dictionary).duplicate(true)
		var res: Dictionary = svc.call("validate_action", cmd, "blue")
		var tag: String = str(d[1])
		_check(not (res.get("candidate_units", []) as Array).is_empty(), "%s %s: candidates non-empty" % [pid, tag])
		_check(_unexplained(res) == 0, "%s %s: unexplained == 0" % [pid, tag])
		_check(_dupe_dest(res).is_empty(), "%s %s: no duplicate destinations" % [pid, tag])
		if str(d[2]) != "":
			_check(_only_class(res, str(d[2])), "%s %s: scope purity %s" % [pid, tag, str(d[2])])
	# UNIT_ID templates bound to a live blue unit.
	var blue_unit := {}
	for u in truth.call("snapshot_units"):
		if u is Dictionary and str((u as Dictionary).get("faction", "")) == "blue" and int((u as Dictionary).get("soldier_count", 0)) > 0 and not bool((u as Dictionary).get("garrisoned", false)) and not bool((u as Dictionary).get("routed", false)):
			blue_unit = u
			break
	_check(not blue_unit.is_empty(), "UNIT_ID: live blue unit available")
	if not blue_unit.is_empty():
		var uid := str(blue_unit.get("id", ""))
		for tpid in ["HOLD_SELECTED_UNIT", "RETREAT_SELECTED_UNIT", "MOVE_SELECTED_UNIT_TO_HQ", "MOVE_SELECTED_UNIT_TO_CENTER"]:
			var trow: Dictionary = presets[tpid]
			var tcmd: Dictionary = AC.bind_preset(trow, uid, int(blue_unit.get("q", 0)), int(blue_unit.get("r", 0)))
			_check(not tcmd.is_empty() and str((tcmd.get("scope", {}) as Dictionary).get("unit_id", "")) == uid, "%s binds UNIT_ID %s" % [tpid, uid])
			var tres: Dictionary = svc.call("validate_action", tcmd, "blue")
			_check(tres.has("candidate_units"), "%s validates with candidate accounting" % tpid)
		# Exact-unit self-target rejects honestly (no silent no-op).
		var self_cmd: Dictionary = AC.bind_preset(presets["MOVE_SELECTED_UNIT_TO_HEX"], uid, int(blue_unit.get("q", 0)), int(blue_unit.get("r", 0)))
		var self_res: Dictionary = svc.call("validate_action", self_cmd, "blue")
		_check(not bool(self_res.get("ok", false)), "UNIT_ID MOVE to own hex rejects (no silent no-op)")
	# Sequential HOLD_ALL execution regression (runs LAST — mutates turn state).
	var v0 := int(truth.call("get_version"))
	var hold_cmd: Dictionary = ((presets["HOLD_ALL"] as Dictionary).get("command", {}) as Dictionary).duplicate(true)
	var preview: Dictionary = svc.call("preview_action", hold_cmd, "blue")
	var n_cand := (preview.get("candidate_units", []) as Array).size()
	_check(bool(preview.get("ok", false)) and n_cand > 0, "HOLD_ALL preview READY (%d candidates)" % n_cand)
	svc.connect("execution_finished", func(res: Dictionary) -> void: finished_res["res"] = res)
	var ex: Dictionary = svc.call("execute_plan", str(preview.get("plan_id", "")))
	_check(str(ex.get("execution_status", "")) == "IN_PROGRESS", "HOLD_ALL execution launches sequential queue")
	for _i in range(3000):
		if finished_res.has("res"):
			break
		await process_frame
	_check(finished_res.has("res"), "HOLD_ALL execution finished via callback")
	if finished_res.has("res"):
		var fr: Dictionary = finished_res["res"]
		var done := (fr.get("executed_units", []) as Array).size() + (fr.get("failed_units", []) as Array).size()
		_check(done == n_cand and int(fr.get("unexplained_count", -1)) == 0, "HOLD_ALL accounts all %d/%d, unexplained 0" % [done, n_cand])
		_check(int(truth.call("get_version")) > v0, "state version advanced %d -> %d" % [v0, int(truth.call("get_version"))])
	# Same-turn readiness: acting again must report UNIT_NOT_READY, not reset.
	var again: Dictionary = svc.call("validate_action", ((presets["ADVANCE_ALL_FORWARD"] as Dictionary).get("command", {}) as Dictionary).duplicate(true), "blue")
	_check((again.get("resolved_units", []) as Array).is_empty() and _any_rej_code(again, "UNIT_NOT_READY"), "same-turn ADVANCE_ALL reports UNIT_NOT_READY")
	_write()
	print("MATRIX_" + ("PASS" if failures.is_empty() else "FAIL") + " (%d/%d)" % [notes.size(), notes.size() + failures.size()])
	quit(0 if failures.is_empty() else 2)


func _write() -> void:
	DirAccess.make_dir_recursive_absolute((OUT as String).get_base_dir())
	var file := FileAccess.open(OUT, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify({"status": "PASS" if failures.is_empty() else "FAIL", "failures": failures, "notes": notes}, "  "))
