extends SceneTree

## AGENT-AS-GENERAL DEBUG HARNESS — headless battle runner (NO provider).
##
## The local coding/debug agent acts as the RED General through the file debug
## transport: Godot writes General requests as JSON, parks, and waits; the
## agent submits KEEP / ADJUST / REPLAN through tools/debug_general.py; Godot
## validates through the SAME production validators and executes through the
## SAME MissionManager/MissionController/compiler path as the cloud game.
##
## No provider is constructed (no adapter/session/opencode/JEV preloads exist
## in this file), no API key is read, and a timeout NEVER falls back to a
## paid provider — it records DEBUG_AGENT_TIMEOUT and stops safely.
##
## Usage (Windows):
##   Godot_v4.2.2-stable_win64_console.exe --headless --path "<StrategyGame>" -s res://scripts/cloud2/cloud2_debug_agent_entry.gd -- --scenario HQ_SAFE --run-dir "<abs run dir>" [--blindness SYSTEM_DEBUG|BLIND_GENERAL] [--turns 8] [--review-every 2] [--timeout-sec 600] [--blue stationary|advance|aggressive] [--run-id ID]
##   ... -- --list-scenarios
##   ... -- --selftest [--run-dir "<abs dir>"]
##
## Exit codes: 0 DONE/STOPPED, 1 SELFTEST-FAIL, 3 DEBUG_AGENT_TIMEOUT, 4 ERROR.

const SimControllerCls = preload("res://scripts/sim/sim_controller.gd")
const ObsCls = preload("res://scripts/cloud1/cloud1_observation.gd")
const TableCls = preload("res://scripts/cloud1/cloud1_action_table.gd")
const CompilerCls = preload("res://scripts/cloud1/cloud1_compiler.gd")
const ResponseCls = preload("res://scripts/cloud2/cloud2_response.gd")
const GeneralPacketCls = preload("res://scripts/cloud2/cloud2_general_packet.gd")
const CoordMenuCls = preload("res://scripts/cloud2/cloud2_coord_menu.gd")
const CoordResponseCls = preload("res://scripts/cloud2/cloud2_coord_response.gd")
const MissionManagerCls = preload("res://scripts/cloud2/cloud2_mission_manager.gd")
const DebugCfgCls = preload("res://scripts/cloud2/cloud2_debug_agent_config.gd")
const TransportCls = preload("res://scripts/cloud2/cloud2_debug_agent_transport.gd")
const ScenariosCls = preload("res://scripts/cloud2/cloud2_debug_scenarios.gd")
const SelftestCls = preload("res://scripts/cloud2/cloud2_debug_agent_selftest.gd")

const POLL_MS := 250
const HEARTBEAT_SEC := 30

var _scenario_id := ""
var _run_dir := ""
var _run_id := ""
var _blindness := ""
var _turns := 8
var _review_every := 0
var _timeout_sec := 0.0
var _blue_override := ""
var _list_only := false
var _selftest_only := false

var _mgr: RefCounted = null
var _seq := 0
var _requests := 0
var _rejected := 0
var _quarantined := 0
var _decisions := {"INITIAL": 0, "KEEP": 0, "ADJUST": 0, "REPLAN": 0}
var _turn_rows: Array = []
var _stop_reason := ""
var _battle_terminal: Dictionary = {}


func _init() -> void:
	_parse_args()
	_run()


func _parse_args() -> void:
	var all: Array = []
	all.append_array(OS.get_cmdline_user_args())
	all.append_array(OS.get_cmdline_args())
	for a_val in all:
		var a := str(a_val).strip_edges()
		if a == "--list-scenarios":
			_list_only = true
		elif a == "--selftest":
			_selftest_only = true
		elif a.begins_with("--scenario="):
			_scenario_id = a.get_slice("=", 1).strip_edges().to_upper()
		elif a.begins_with("--run-dir="):
			_run_dir = a.get_slice("=", 1).strip_edges().trim_prefix("\"").trim_suffix("\"")
		elif a.begins_with("--run-id="):
			_run_id = a.get_slice("=", 1).strip_edges()
		elif a.begins_with("--blindness="):
			_blindness = a.get_slice("=", 1).strip_edges().to_upper()
		elif a.begins_with("--general-blindness="):
			_blindness = a.get_slice("=", 1).strip_edges().to_upper()
		elif a.begins_with("--turns="):
			_turns = clampi(int(a.get_slice("=", 1)), 1, 40)
		elif a.begins_with("--review-every="):
			_review_every = clampi(int(a.get_slice("=", 1)), 0, 40)
		elif a.begins_with("--timeout-sec=") or a.begins_with("--general-timeout="):
			_timeout_sec = maxf(5.0, float(a.get_slice("=", 1)))
		elif a.begins_with("--blue="):
			_blue_override = a.get_slice("=", 1).strip_edges().to_lower()


func _run() -> void:
	if _list_only:
		print(JSON.stringify(ScenariosCls.list_scenarios(), "  "))
		quit(DebugCfgCls.EXIT_DONE)
		return
	if _selftest_only:
		var res: Dictionary = SelftestCls.run()
		if not _run_dir.is_empty():
			TransportCls.ensure_layout(_run_dir)
			TransportCls.atomic_write(_run_dir + "/SELFTEST.json", JSON.stringify(res, "  "))
		print("DEBUG_AGENT_SELFTEST pass=%d fail=%d" % [int(res.get("pass_count", 0)), int(res.get("fail_count", 0))])
		quit(DebugCfgCls.EXIT_DONE if bool(res.get("ok", false)) else DebugCfgCls.EXIT_GATE_FAIL)
		return
	if _scenario_id.is_empty() or _run_dir.is_empty():
		print(_usage())
		quit(DebugCfgCls.EXIT_ERROR)
		return
	_cmd_battle()


func _usage() -> String:
	return "Usage: godot --headless --path <StrategyGame> -s res://scripts/cloud2/cloud2_debug_agent_entry.gd -- --scenario <ID> --run-dir <abs dir> [--blindness SYSTEM_DEBUG|BLIND_GENERAL] [--turns N] [--review-every N] [--timeout-sec S] [--blue stationary|advance|aggressive] [--run-id ID] | --list-scenarios | --selftest [--run-dir dir]"


func _cmd_battle() -> void:
	_blindness = DebugCfgCls.resolve_blindness(_blindness)
	_timeout_sec = DebugCfgCls.resolve_timeout_sec(_timeout_sec, 600.0)
	var layout := TransportCls.ensure_layout(_run_dir)
	if not bool(layout.get("ok", false)):
		print("[DebugAgent] FATAL %s" % str(layout.get("detail", "")))
		quit(DebugCfgCls.EXIT_ERROR)
		return
	if _run_id.is_empty():
		_run_id = "%s_%s_%d" % [_scenario_id.to_lower(),
			Time.get_datetime_string_from_system(true).replace(":", "").replace("-", "").replace("T", "_"),
			Time.get_ticks_msec() % 100000]
	var built: Dictionary = ScenariosCls.build(_scenario_id)
	if not bool(built.get("ok", false)):
		TransportCls.write_status(_run_dir, {"phase": "ERROR", "code": str(built.get("code", "")),
			"detail": str(built.get("detail", ""))})
		print("[DebugAgent] FATAL %s: %s" % [str(built.get("code", "")), str(built.get("detail", ""))])
		quit(DebugCfgCls.EXIT_ERROR)
		return
	var policy: Dictionary = (built.get("policy", {}) as Dictionary).duplicate(true)
	if not _blue_override.is_empty():
		policy["blue_policy"] = _blue_override
	TransportCls.write_control(_run_dir, {"stop": false})
	TransportCls.atomic_write(_run_dir + "/run.json", JSON.stringify({
		"run_id": _run_id, "scenario_id": _scenario_id,
		"backend": DebugCfgCls.BACKEND_DEBUG_AGENT,
		"blindness": _blindness,
		"turns_planned": _turns, "review_every": _review_every,
		"timeout_sec": _timeout_sec, "blue_policy": str(policy.get("blue_policy", "")),
		"protocol": DebugCfgCls.PROTOCOL_VERSION,
		"jev_authority": "WITHHELD",
		"provider_calls_expected": 0, "api_keys_required": 0,
		"created_at": TransportCls.now_iso(),
	}, "  "))
	TransportCls.write_status(_run_dir, {"phase": "STARTING", "run_id": _run_id,
		"scenario_id": _scenario_id, "turn": 0, "pending_request": null})
	TransportCls.append_audit(_run_dir, {"event": "RUN_START", "run_id": _run_id,
		"scenario_id": _scenario_id, "backend": DebugCfgCls.BACKEND_DEBUG_AGENT,
		"blindness": _blindness, "turns_planned": _turns, "timeout_sec": _timeout_sec,
		"jev_authority": "WITHHELD", "provider_calls": 0})
	var sim: RefCounted = SimControllerCls.new()
	var loaded: Dictionary = sim.load_scenario(built.get("scenario", {}))
	if not bool(loaded.get("ok", false)):
		TransportCls.write_status(_run_dir, {"phase": "ERROR", "detail": "Scenario load failed."})
		print("[DebugAgent] FATAL scenario load failed: %s" % JSON.stringify(loaded))
		quit(DebugCfgCls.EXIT_ERROR)
		return
	_mgr = MissionManagerCls.new()
	print("[DebugAgent] RUN %s scenario=%s blindness=%s turns=%d review_every=%d timeout=%ds blue=%s" % [
		_run_id, _scenario_id, _blindness, _turns, _review_every, int(_timeout_sec), str(policy.get("blue_policy", ""))])
	var outcome := "DONE"
	for t in range(1, _turns + 1):
		if _stop_requested():
			outcome = "STOPPED"
			_stop_reason = "operator stop via control.json"
			break
		var obs: Dictionary = ObsCls.build(sim, "red")
		if not bool(obs.get("ok", false)):
			outcome = "ERROR"
			_stop_reason = "observation failed"
			break
		var turn := int(obs.get("turn", t))
		# BATTLE_TERMINAL_CONTRACT_V0: no General request (INITIAL or REVIEW)
		# issues once the battle is terminal.
		if _decisive(sim):
			outcome = "DONE"
			_stop_reason = "battle terminal: winner=%s reason=%s turn=%d" % [
				str(_battle_terminal.get("winner", "")), str(_battle_terminal.get("reason", "")),
				int(_battle_terminal.get("turn", 0))]
			break
		var plan: Dictionary = _mgr.get_plan()
		if int(plan.get("plan_version", 0)) == 0:
			var ini := _do_initial(sim, obs, turn)
			if not bool(ini.get("ok", false)):
				outcome = str(ini.get("outcome", "ERROR"))
				_stop_reason = str(ini.get("detail", ""))
				break
		else:
			var review: Dictionary = _mgr.review_due(obs, turn)
			var forced := _review_every > 0 and turn > 1 and (turn - 1) % _review_every == 0
			if bool(review.get("requested", false)) or forced:
				var trigger := review.duplicate(true)
				if not bool(review.get("requested", false)):
					trigger = {"requested": true, "trigger": "FORCED_PERIODIC",
						"reason": "Harness periodic review every %d turns." % _review_every,
						"turn": turn, "event_count": 0, "event_batch_id": 0}
				var rev := _do_review(sim, obs, trigger, turn)
				if not bool(rev.get("ok", false)):
					outcome = str(rev.get("outcome", "ERROR"))
					_stop_reason = str(rev.get("detail", ""))
					break
		TransportCls.write_status(_run_dir, {"phase": "EXECUTING", "run_id": _run_id,
			"turn": turn, "pending_request": null})
		var trow := _red_turn_exec(sim, obs, turn)
		if _decisive(sim):
			trow["blue_note"] = "skipped: battle terminal during RED phase"
		else:
			_blue_phase(sim, str(policy.get("blue_policy", "stationary")), trow)
		trow["fingerprint_post"] = str(sim.fingerprint())
		_turn_rows.append(trow)
		TransportCls.append_audit(_run_dir, {"event": "TURN_EXECUTED", "run_id": _run_id,
			"turn": turn, "backend": DebugCfgCls.BACKEND_DEBUG_AGENT,
			"orders": (trow.get("orders", []) as Array).size(),
			"executed_units": int(trow.get("executed_units", 0)),
			"rejected_orders": int(trow.get("rejected_orders", 0)),
			"plan_version": int((_mgr.get_plan() as Dictionary).get("plan_version", 0)),
			"strength": _side_strength(sim)})
		if _decisive(sim):
			_stop_reason = "battle terminal: winner=%s reason=%s turn=%d" % [
				str(_battle_terminal.get("winner", "")), str(_battle_terminal.get("reason", "")),
				int(_battle_terminal.get("turn", 0))]
			break
		sim.sim_end_turn()
	_finish(sim, outcome)


func _next_request_id(turn: int) -> String:
	_seq += 1
	return "dbg_t%02d_%02d" % [turn, _seq]


func _do_initial(sim: RefCounted, obs: Dictionary, turn: int) -> Dictionary:
	var req_id := _next_request_id(turn)
	var menu: Dictionary = _mgr.build_coord_menu(obs)
	if ((menu.get("groups", []) as Array).is_empty()):
		return {"ok": false, "outcome": "ERROR", "detail": "COORD_EMPTY_MENU: no force groups."}
	var packet: Dictionary = GeneralPacketCls.build_coord_initial(obs, menu)
	var env := TransportCls.build_request_envelope(_run_id, req_id, "INITIAL", turn,
		_blindness, packet, menu, CoordResponseCls.COORDINATOR_SYSTEM_PROMPT, 0)
	var w := TransportCls.write_request(_run_dir, env)
	if not bool(w.get("ok", false)):
		return {"ok": false, "outcome": "ERROR", "detail": str(w.get("detail", ""))}
	TransportCls.write_truth(_run_dir, req_id, _build_truth(sim, req_id, turn, "INITIAL"))
	_requests += 1
	var t0 := Time.get_ticks_msec()
	TransportCls.write_status(_run_dir, {"phase": "PARKED", "run_id": _run_id, "turn": turn,
		"pending_request": req_id, "kind": "INITIAL", "plan_version": 0})
	TransportCls.append_audit(_run_dir, {"event": "REQUEST_WRITTEN", "run_id": _run_id,
		"request_id": req_id, "turn": turn, "kind": "INITIAL",
		"backend": DebugCfgCls.BACKEND_DEBUG_AGENT, "blindness": _blindness,
		"request_path": "requests/request_%s.json" % req_id,
		"request_sha256": str(w.get("sha256", "")), "request_chars": int(w.get("chars", 0)),
		"event_kinds": env.get("event_kinds", []), "event_count": int(env.get("event_count", 0)),
		"previous_plan_version": 0})
	print("[DebugAgent] DEBUG_AGENT_PARKED req=%s kind=INITIAL turn=%d menu_groups=%d" % [
		req_id, turn, (menu.get("groups", []) as Array).size()])
	while true:
		var poll := _poll_response(req_id)
		if str(poll.get("state", "")) != "FOUND":
			return {"ok": false, "outcome": str(poll.get("state", "ERROR")),
				"detail": str(poll.get("detail", ""))}
		var rd := TransportCls.read_response(_run_dir, req_id)
		if not bool(rd.get("ok", false)):
			TransportCls.append_audit(_run_dir, {"event": "SUBMISSION_ERROR", "run_id": _run_id,
				"request_id": req_id, "turn": turn, "code": str(rd.get("code", "")),
				"detail": str(rd.get("detail", ""))})
			_rejected += 1
			if not _quarantine(req_id):
				return {"ok": false, "outcome": "ERROR", "detail": "Cannot quarantine bad submission."}
			continue
		var text: String = str((rd.get("data", {}) as Dictionary).get("response_text", ""))
		var parsed: Dictionary = CoordResponseCls.parse_initial(text,
			{"menu": menu, "snapshot_id": str(obs.get("snapshot_id", "")), "turn": turn})
		if not bool(parsed.get("ok", false)):
			_reject(req_id, turn, "INITIAL", str(parsed.get("code", "")), str(parsed.get("detail", "")), text)
			if not _quarantine(req_id):
				return {"ok": false, "outcome": "ERROR", "detail": "Cannot quarantine bad submission."}
			continue
		var expanded: Dictionary = CoordMenuCls.expand_initial(menu, parsed.get("selection", {}),
			turn, str(obs.get("snapshot_id", "")), obs.get("mission", {}), parsed.get("warnings", []))
		if not bool(expanded.get("ok", false)):
			_reject(req_id, turn, "INITIAL", str(expanded.get("code", "")), str(expanded.get("detail", "")), text)
			if not _quarantine(req_id):
				return {"ok": false, "outcome": "ERROR", "detail": "Cannot quarantine bad submission."}
			continue
		var applied: Dictionary = _mgr.apply_plan(expanded.get("plan", {}), turn,
			str(obs.get("snapshot_id", "")), str(obs.get("battle_id", "")))
		if not bool(applied.get("ok", false)):
			_reject(req_id, turn, "INITIAL", str(applied.get("code", "")), str(applied.get("detail", "")), text)
			if not _quarantine(req_id):
				return {"ok": false, "outcome": "ERROR", "detail": "Cannot quarantine bad submission."}
			continue
		_mgr.bind_coordination({"choices": expanded.get("choices", {}),
			"menu_snapshot": str(menu.get("snapshot_id", "")), "turn": turn,
			"warnings": expanded.get("warnings", [])})
		_decisions["INITIAL"] = int(_decisions["INITIAL"]) + 1
		TransportCls.append_audit(_run_dir, {"event": "RESPONSE_ACCEPTED", "run_id": _run_id,
			"request_id": req_id, "turn": turn, "kind": "INITIAL", "decision": "INITIAL",
			"backend": DebugCfgCls.BACKEND_DEBUG_AGENT, "blindness": _blindness,
			"validator": "PASS", "previous_plan_version": 0,
			"new_plan_version": int(applied.get("version", 0)),
			"missions": ((_mgr.get_plan() as Dictionary).get("missions", []) as Array).size(),
			"warnings": expanded.get("warnings", []),
			"response_sha256": TransportCls.sha256_of(text), "response_chars": text.length(),
			"latency_ms": Time.get_ticks_msec() - t0})
		TransportCls.clear_pending(_run_dir)
		print("[DebugAgent] DEBUG_AGENT_ACCEPTED req=%s decision=INITIAL plan_v%d" % [req_id, int(applied.get("version", 0))])
		return {"ok": true}
	# Unreachable: the response loop only exits via return.
	return {"ok": false, "outcome": "ERROR", "detail": "Unreachable."}


func _do_review(sim: RefCounted, obs: Dictionary, trigger: Dictionary, turn: int) -> Dictionary:
	var req_id := _next_request_id(turn)
	var menu: Dictionary = _mgr.build_coord_menu(obs)
	var packet: Dictionary = GeneralPacketCls.build_coord_review(obs, menu, _mgr.get_plan(),
		trigger, _mgr.events_for_review(trigger), _mgr.get_coordination())
	var prev_version := int((_mgr.get_plan() as Dictionary).get("plan_version", 0))
	var env := TransportCls.build_request_envelope(_run_id, req_id, "REVIEW", turn,
		_blindness, packet, menu, CoordResponseCls.REVIEW_SYSTEM_PROMPT, prev_version)
	var w := TransportCls.write_request(_run_dir, env)
	if not bool(w.get("ok", false)):
		return {"ok": false, "outcome": "ERROR", "detail": str(w.get("detail", ""))}
	TransportCls.write_truth(_run_dir, req_id, _build_truth(sim, req_id, turn, "REVIEW"))
	_requests += 1
	var t0 := Time.get_ticks_msec()
	TransportCls.write_status(_run_dir, {"phase": "PARKED", "run_id": _run_id, "turn": turn,
		"pending_request": req_id, "kind": "REVIEW", "plan_version": prev_version,
		"trigger": str(trigger.get("trigger", ""))})
	TransportCls.append_audit(_run_dir, {"event": "REQUEST_WRITTEN", "run_id": _run_id,
		"request_id": req_id, "turn": turn, "kind": "REVIEW",
		"trigger": str(trigger.get("trigger", "")), "review_reason": str(trigger.get("reason", "")),
		"backend": DebugCfgCls.BACKEND_DEBUG_AGENT, "blindness": _blindness,
		"request_path": "requests/request_%s.json" % req_id,
		"request_sha256": str(w.get("sha256", "")), "request_chars": int(w.get("chars", 0)),
		"event_kinds": env.get("event_kinds", []), "event_count": int(env.get("event_count", 0)),
		"previous_plan_version": prev_version})
	print("[DebugAgent] DEBUG_AGENT_PARKED req=%s kind=REVIEW turn=%d trigger=%s plan_v%d" % [
		req_id, turn, str(trigger.get("trigger", "")), prev_version])
	var baseline: Dictionary = _mgr.get_coordination()
	while true:
		var poll := _poll_response(req_id)
		if str(poll.get("state", "")) != "FOUND":
			return {"ok": false, "outcome": str(poll.get("state", "ERROR")),
				"detail": str(poll.get("detail", ""))}
		var rd := TransportCls.read_response(_run_dir, req_id)
		if not bool(rd.get("ok", false)):
			TransportCls.append_audit(_run_dir, {"event": "SUBMISSION_ERROR", "run_id": _run_id,
				"request_id": req_id, "turn": turn, "code": str(rd.get("code", "")),
				"detail": str(rd.get("detail", ""))})
			_rejected += 1
			if not _quarantine(req_id):
				return {"ok": false, "outcome": "ERROR", "detail": "Cannot quarantine bad submission."}
			continue
		var text: String = str((rd.get("data", {}) as Dictionary).get("response_text", ""))
		var parsed: Dictionary = CoordResponseCls.parse_review(text,
			{"menu": menu, "snapshot_id": str(obs.get("snapshot_id", "")), "turn": turn,
				"baseline": baseline, "has_baseline": not baseline.is_empty()})
		if not bool(parsed.get("ok", false)):
			_reject(req_id, turn, "REVIEW", str(parsed.get("code", "")), str(parsed.get("detail", "")), text)
			if not _quarantine(req_id):
				return {"ok": false, "outcome": "ERROR", "detail": "Cannot quarantine bad submission."}
			continue
		var rev: Dictionary = parsed.get("review", {})
		var decision := str(rev.get("decision", ""))
		var new_version := prev_version
		var warnings: Array = (parsed.get("warnings", []) as Array).duplicate(true)
		if decision == "KEEP":
			var kept: Dictionary = _mgr.confirm_plan(turn, rev.get("hypotheses", []),
				bool(rev.get("has_hypotheses", false)))
			if not bool(kept.get("ok", false)):
				_reject(req_id, turn, "REVIEW", str(kept.get("code", "")), str(kept.get("detail", "")), text)
				if not _quarantine(req_id):
					return {"ok": false, "outcome": "ERROR", "detail": "Cannot quarantine bad submission."}
				continue
			new_version = int(kept.get("version", prev_version))
			_mgr.acknowledge_review_events(trigger, "KEEP", new_version, "KEPT")
		else:
			var mission: Dictionary = ((_mgr.get_plan() as Dictionary).get("mission", {}) as Dictionary).duplicate(true)
			var expanded := {}
			if decision == "ADJUST":
				expanded = CoordMenuCls.expand_adjust(menu, baseline, rev.get("changes", []),
					turn, str(obs.get("snapshot_id", "")), mission, _mgr.get_plan(), warnings,
					rev.get("doctrine_override", {}), rev.get("hypotheses", []),
					bool(rev.get("has_hypotheses", false)))
			else:
				expanded = CoordMenuCls.expand_initial(menu, rev.get("selection", {}), turn,
					str(obs.get("snapshot_id", "")), mission, warnings)
			if not bool(expanded.get("ok", false)):
				_reject(req_id, turn, "REVIEW", str(expanded.get("code", "")), str(expanded.get("detail", "")), text)
				if not _quarantine(req_id):
					return {"ok": false, "outcome": "ERROR", "detail": "Cannot quarantine bad submission."}
				continue
			warnings = (expanded.get("warnings", []) as Array).duplicate(true)
			var base := MissionManagerCls.review_base_from_obs(obs)
			var stale: Dictionary = _mgr.staged_staleness(expanded.get("plan", {}), base, obs)
			if bool(stale.get("stale", false)):
				TransportCls.append_audit(_run_dir, {"event": "STALE_DISCARDED", "run_id": _run_id,
					"request_id": req_id, "turn": turn, "decision": decision,
					"reason": str(stale.get("reason", ""))})
				new_version = prev_version
			else:
				var applied: Dictionary = _mgr.apply_plan(expanded.get("plan", {}), turn,
					str(obs.get("snapshot_id", "")), str(obs.get("battle_id", "")))
				if not bool(applied.get("ok", false)):
					_reject(req_id, turn, "REVIEW", str(applied.get("code", "")), str(applied.get("detail", "")), text)
					if not _quarantine(req_id):
						return {"ok": false, "outcome": "ERROR", "detail": "Cannot quarantine bad submission."}
					continue
				_mgr.bind_coordination({"choices": expanded.get("choices", {}),
					"menu_snapshot": str(menu.get("snapshot_id", "")), "turn": turn,
					"warnings": warnings})
				new_version = int(applied.get("version", prev_version))
				_mgr.acknowledge_review_events(trigger, decision, new_version, "ADOPTED")
		_decisions[decision] = int(_decisions.get(decision, 0)) + 1
		TransportCls.append_audit(_run_dir, {"event": "RESPONSE_ACCEPTED", "run_id": _run_id,
			"request_id": req_id, "turn": turn, "kind": "REVIEW", "decision": decision,
			"backend": DebugCfgCls.BACKEND_DEBUG_AGENT, "blindness": _blindness,
			"validator": "PASS", "previous_plan_version": prev_version,
			"new_plan_version": new_version,
			"warnings": warnings,
			"response_sha256": TransportCls.sha256_of(text), "response_chars": text.length(),
			"latency_ms": Time.get_ticks_msec() - t0})
		TransportCls.clear_pending(_run_dir)
		print("[DebugAgent] DEBUG_AGENT_ACCEPTED req=%s decision=%s plan_v%d->v%d" % [req_id, decision, prev_version, new_version])
		return {"ok": true}
	# Unreachable: the response loop only exits via return.
	return {"ok": false, "outcome": "ERROR", "detail": "Unreachable."}


func _reject(req_id: String, turn: int, kind: String, code: String, detail: String, text: String) -> void:
	_rejected += 1
	TransportCls.append_audit(_run_dir, {"event": "VALIDATION_REJECT", "run_id": _run_id,
		"request_id": req_id, "turn": turn, "kind": kind,
		"backend": DebugCfgCls.BACKEND_DEBUG_AGENT,
		"validator": "FAIL", "code": code, "detail": detail.left(400),
		"response_sha256": TransportCls.sha256_of(text), "response_chars": text.length()})
	print("[DebugAgent] DEBUG_AGENT_REJECT req=%s code=%s detail=%s" % [req_id, code, detail.left(160)])


func _poll_response(req_id: String) -> Dictionary:
	var path := "%s/responses/response_%s.json" % [_run_dir, req_id]
	var t0 := Time.get_ticks_msec()
	var budget_ms := int(_timeout_sec * 1000.0)
	var last_beat := t0
	while true:
		if _stop_requested():
			return {"state": "STOPPED", "detail": "operator stop via control.json"}
		if FileAccess.file_exists(path):
			return {"state": "FOUND"}
		var now := Time.get_ticks_msec()
		if now - t0 > budget_ms:
			TransportCls.append_audit(_run_dir, {"event": "TIMEOUT", "run_id": _run_id,
				"request_id": req_id, "code": "DEBUG_AGENT_TIMEOUT",
				"detail": "No debug response within %d s; no provider fallback attempted." % int(_timeout_sec),
				"backend": DebugCfgCls.BACKEND_DEBUG_AGENT, "provider_calls": 0})
			print("[DebugAgent] DEBUG_AGENT_TIMEOUT req=%s after %ds — no provider fallback." % [req_id, int(_timeout_sec)])
			return {"state": "TIMEOUT", "detail": "DEBUG_AGENT_TIMEOUT"}
		if now - last_beat > HEARTBEAT_SEC * 1000:
			last_beat = now
			print("[DebugAgent] waiting req=%s elapsed=%ds/%ds" % [req_id, int((now - t0) / 1000), int(_timeout_sec)])
		OS.delay_msec(POLL_MS)
	# Unreachable: the poll loop only exits via return.
	return {"state": "ERROR", "detail": "Unreachable."}


func _quarantine(req_id: String) -> bool:
	_quarantined += 1
	var src := "%s/responses/response_%s.json" % [_run_dir, req_id]
	var dst := "%s/responses/rejected_%s_%02d.json" % [_run_dir, req_id, _quarantined]
	return DirAccess.rename_absolute(src, dst) == OK


func _stop_requested() -> bool:
	return bool(TransportCls.read_control(_run_dir).get("stop", false))


func _red_turn_exec(sim: RefCounted, obs: Dictionary, turn: int) -> Dictionary:
	var decided: Dictionary = _mgr.red_turn(sim, obs)
	var trow := {"turn": turn, "snapshot_id": str(obs.get("snapshot_id", "")),
		"orders": [], "executed_units": 0, "rejected_orders": 0,
		"review": decided.get("review", {}), "corrections": decided.get("corrections", [])}
	var acted: Array = []
	for o_val in (decided.get("orders", []) as Array):
		var mid := str((o_val as Dictionary).get("mission_id", "?"))
		var order: Dictionary = (o_val as Dictionary).get("order", {})
		var gate: Dictionary = ResponseCls.check_order(order, {"acting_side": "RED"})
		var orow := {"mission_id": mid, "gate_ok": bool(gate.get("ok", false)),
			"gate_code": str(gate.get("code", "")), "exec_status": "GATE_REJECTED",
			"executed": [], "failed": []}
		if bool(gate.get("ok", false)):
			var octx: Dictionary = (o_val as Dictionary).get("exec_ctx", {})
			var ex: Dictionary = CompilerCls.execute(sim, order, "", "red", octx) if not octx.is_empty() else CompilerCls.execute(sim, order, "", "red")
			orow["exec_status"] = str(ex.get("execution_status", "?"))
			orow["executed"] = ex.get("executed_units", [])
			orow["failed"] = ex.get("execution_failed", [])
			orow["cancelled"] = ex.get("cancelled_units", [])
			for e_val in (ex.get("executed_units", []) as Array):
				acted.append({"unit_id": str((e_val as Dictionary).get("unit_id", ""))})
				trow["executed_units"] = int(trow.get("executed_units", 0)) + 1
		else:
			trow["rejected_orders"] = int(trow.get("rejected_orders", 0)) + 1
		(trow.get("orders", []) as Array).append(orow)
	_mgr.post_turn(acted, turn)
	if _mgr.has_method("status_rows"):
		trow["mission_statuses"] = _mgr.status_rows()
	return trow


func _blue_phase(sim: RefCounted, policy: String, trow: Dictionary) -> void:
	var acts: Array = []
	if policy == ScenariosCls.BLUE_STATIONARY:
		trow["blue_note"] = "stationary: BLUE holds position (no orders)"
		trow["blue_actions"] = acts
		return
	var mgr: RefCounted = sim.get_manager()
	var ids: Array = []
	for u_val in mgr.get_all_units():
		var u: Dictionary = u_val
		if str(u.get("faction", "")) != "blue":
			continue
		if bool(u.get("action_ended", false)) or int(u.get("soldier_count", 0)) <= 0:
			continue
		ids.append(str(u.get("id", "")))
	ids.sort()
	for uid in ids:
		var u2: Dictionary = mgr.get_unit_by_id(uid)
		var cmd := {}
		if str(u2.get("class", "")) == "hq":
			cmd = TableCls.make_command("HOLD", TableCls.scope_units([uid]))
		elif policy == ScenariosCls.BLUE_AGGRESSIVE:
			var targets: Array = mgr.get_attackable_targets(uid)
			if targets.is_empty():
				cmd = TableCls.make_command("ADVANCE", TableCls.scope_units([uid]), TableCls.target_direction("EAST"))
			else:
				var tids: Array = []
				for t_val in targets:
					tids.append(str((t_val as Dictionary).get("id", "")))
				tids.sort()
				cmd = TableCls.make_command("ATTACK", TableCls.scope_units([uid]), TableCls.target_formation(tids[0]))
		else:
			cmd = TableCls.make_command("ADVANCE", TableCls.scope_units([uid]), TableCls.target_direction("EAST"))
		var ex: Dictionary = CompilerCls.execute(sim, cmd, "", "blue")
		acts.append({"unit_id": uid, "command": cmd,
			"status": str(ex.get("execution_status", "?")),
			"executed": ex.get("executed_units", [])})
	trow["blue_policy"] = policy
	trow["blue_actions"] = acts


func _build_truth(sim: RefCounted, request_id: String, turn: int, kind: String) -> Dictionary:
	var rows: Array = []
	var mgr: RefCounted = sim.get_manager()
	for u_val in mgr.get_all_units_including_garrisoned():
		var u: Dictionary = u_val
		rows.append({"unit_id": str(u.get("id", "")), "faction": str(u.get("faction", "")),
			"class": str(u.get("class", "")), "q": int(u.get("q", 0)), "r": int(u.get("r", 0)),
			"soldiers": int(u.get("soldier_count", 0)), "action_ended": bool(u.get("action_ended", false)),
			"routed": bool(u.get("routed", false))})
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a.get("unit_id", "")) < str(b.get("unit_id", "")))
	return {"protocol": DebugCfgCls.PROTOCOL_VERSION, "request_id": request_id,
		"run_id": _run_id, "turn": turn, "kind": kind, "captured_at": TransportCls.now_iso(),
		"scenario_id": _scenario_id,
		"note": "ORCHESTRATOR ONLY — world truth. Never shown to the General in BLIND_GENERAL mode.",
		"world_truth": {"units": rows, "turn": turn}}


func _side_strength(sim: RefCounted) -> Dictionary:
	var out := {"red_formations": 0, "blue_formations": 0, "red_soldiers": 0, "blue_soldiers": 0}
	var mgr: RefCounted = sim.get_manager()
	for u_val in mgr.get_all_units_including_garrisoned():
		var u: Dictionary = u_val
		if int(u.get("soldier_count", 0)) <= 0:
			continue
		if str(u.get("faction", "")) == "red":
			out["red_formations"] = int(out["red_formations"]) + 1
			out["red_soldiers"] = int(out["red_soldiers"]) + int(u.get("soldier_count", 0))
		elif str(u.get("faction", "")) == "blue":
			out["blue_formations"] = int(out["blue_formations"]) + 1
			out["blue_soldiers"] = int(out["blue_soldiers"]) + int(u.get("soldier_count", 0))
	return out


## BATTLE_TERMINAL_CONTRACT_V0: the single canonical battle evaluator
## decides. Stashes the terminal record for _finish when terminal.
func _decisive(sim: RefCounted) -> bool:
	var b: Dictionary = sim.evaluate_battle()
	if not bool(b.get("terminal", false)):
		return false
	_battle_terminal = b
	return true


func _truth_was_exposed() -> bool:
	var path := _run_dir + "/truth_access.log"
	if not FileAccess.file_exists(path):
		return false
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return false
	return not f.get_as_text().strip_edges().is_empty()


func _finish(sim: RefCounted, outcome: String) -> void:
	var classification: Dictionary = DebugCfgCls.classify_run(_blindness, _truth_was_exposed())
	var battle := {"run_id": _run_id, "scenario_id": _scenario_id,
		"backend": DebugCfgCls.BACKEND_DEBUG_AGENT, "blindness": _blindness,
		"classification": str(classification.get("classification", "")),
		"evidence_valid": bool(classification.get("evidence_valid", false)),
		"outcome": outcome, "stop_reason": _stop_reason,
		"battle_terminal": _battle_terminal,
		"turns_executed": _turn_rows.size(), "turns": _turn_rows,
		"general_requests": _requests, "decisions": _decisions,
		"rejected_responses": _rejected,
		"provider_calls": 0, "api_keys_required": 0,
		"adapter_constructed": false, "session_used": false,
		"jev_authority": "WITHHELD",
		"final_strength": _side_strength(sim),
		"final_plan_version": int((_mgr.get_plan() as Dictionary).get("plan_version", 0)),
		"finished_at": TransportCls.now_iso()}
	TransportCls.atomic_write(_run_dir + "/battle.json", JSON.stringify(battle, "  "))
	TransportCls.write_status(_run_dir, {"phase": outcome, "run_id": _run_id,
		"turn": _turn_rows.size(), "pending_request": null,
		"classification": str(classification.get("classification", ""))})
	if outcome != "TIMEOUT":
		TransportCls.clear_pending(_run_dir)
	TransportCls.append_audit(_run_dir, {"event": "RUN_END", "run_id": _run_id,
		"backend": DebugCfgCls.BACKEND_DEBUG_AGENT, "outcome": outcome,
		"classification": str(classification.get("classification", "")),
		"turns_executed": _turn_rows.size(), "general_requests": _requests,
		"decisions": _decisions, "rejected_responses": _rejected,
		"provider_calls": 0, "jev_authority": "WITHHELD"})
	print("[DebugAgent] DEBUG_AGENT_%s run=%s turns=%d requests=%d decisions=%s rejected=%d provider_calls=0" % [
		outcome, _run_id, _turn_rows.size(), _requests, JSON.stringify(_decisions), _rejected])
	match outcome:
		"DONE", "STOPPED":
			quit(DebugCfgCls.EXIT_DONE)
		"TIMEOUT":
			quit(DebugCfgCls.EXIT_TIMEOUT)
		_:
			quit(DebugCfgCls.EXIT_ERROR)

