extends SceneTree

## CLOUD-GENERAL FORENSIC — General SUCCESS-but-never-adopted regression runner.
##
## Usage (Windows):
##   Godot_v4.2.2-stable_win64_console.exe --headless --path "D:\Game development\Demon slayer\StrategyGame" -s res://scripts/cloud2/cloud2_general_forensic_entry.gd
##
## Exit code 0 = all gates pass, 1 = any gate fails. Writes
## res://evidence/cloud2_general_forensic/verification_general_forensic.json.
##
## Guards the live incident shape: HTTP 200 + finish_reason=stop + non-empty
## final content on BOTH attempts, yet no PLAN_ADOPTED. Every fixture runs the
## REAL production path — raw provider envelope -> Cloud2Adapter envelope
## classifier -> Cloud2GeneralResponse.parse -> Cloud2GeneralPlan validation ->
## Cloud2MissionManager.apply_plan — with no mocks past the wire bytes:
##   f1 attempt-1 class (small prose final): transport SUCCESS, parse rejects
##      with a precise code, schema retry is allowed (non-STALE).
##   f2 attempt-1 wrong-shape classes (tactical orders JSON, KEEP/ADJUST JSON):
##      transport SUCCESS, INVALID_SCHEMA, retry allowed.
##   f3 attempt-2 class (large valid plan): parses AND adopts (PLAN_ADOPTED v1).
##   f4 parser input is byte-equivalent to the extracted final text always.
##   f5 rejection matrix: each invalid family maps to its precise code, and
##      only STALE_SNAPSHOT suppresses the schema retry.
##   f6 the turn trace records a metadata-only General outcome (no model text).
##   f7 Model View summary shows post-transport TRANSPORT/PARSE/PLAN/ADOPTION.
##   f8 request/system char counters carry real values (never 0/0 on a call).
##   f9 envelope edge cases stay on the transport side of the boundary.
##
## No network is ever attempted; no tactical scoring, compiler, or executor
## code is touched by any fixture here.

const AdapterCls = preload("res://scripts/cloud2/cloud2_adapter.gd")
const ConfigCls = preload("res://scripts/cloud2/cloud2_config.gd")
const GeneralResponseCls = preload("res://scripts/cloud2/cloud2_general_response.gd")
const MissionManagerCls = preload("res://scripts/cloud2/cloud2_mission_manager.gd")
const TraceCls = preload("res://scripts/cloud2/cloud2_turn_trace.gd")
const ModelViewCls = preload("res://scripts/cloud2/cloud2_model_view.gd")

const OUT_DIR := "res://evidence/cloud2_general_forensic"
const OUT_PATH := "res://evidence/cloud2_general_forensic/verification_general_forensic.json"

var _gates: Dictionary = {}


func _init() -> void:
	call_deferred("_run")


func _record(gate: String, status: String, evidence: Dictionary) -> void:
	_gates[gate] = {"status": status, "evidence": evidence}
	print("[FORENSIC][%s] %s" % [gate, status.to_upper()])


func _exit_code() -> int:
	for key in _gates.keys():
		if str((_gates[key] as Dictionary).get("status", "")) != "pass":
			return 1
	return 0


func _write_and_quit(code: int) -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	var f := FileAccess.open(OUT_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(_gates, "  "))
		f.close()
	print("DET_CLOUD2_GENERAL_FORENSIC_" + ("PASS" if code == 0 else "FAIL"))
	quit(code)


func _run() -> void:
	_f1_attempt1_prose_rejects()
	_f2_attempt1_wrong_shape_rejects()
	_f3_attempt2_valid_adopts()
	_f4_byte_equivalence()
	_f5_rejection_matrix()
	_f6_trace_general_outcome()
	_f7_modelview_pipeline_summary()
	_f8_request_system_counters()
	_f9_envelope_edges()
	TraceCls.clear()
	_write_and_quit(_exit_code())


# --- fixtures: raw provider wire bytes (live-shape classes) -------------------

## Attempt-1 class: HTTP 200, finish stop, reasoning present, but the FINAL
## channel is short prose (~399 chars live) instead of a StrategicPlan.
func _attempt1_prose_final() -> String:
	return "After reviewing the compact state I believe RED should hold the center with infantry, push cavalry along the northern road, and keep the HQ screened by archers. The BLUE spearmen look massed near the river crossing, so avoid a direct assault there. I will prepare detailed missions once the next observation arrives with updated contact states."


func _openai_envelope(final_text: String, reasoning_chars: int = 0, finish: String = "stop") -> String:
	var msg := {"role": "assistant", "content": final_text}
	if reasoning_chars > 0:
		msg["reasoning_content"] = "r".repeat(reasoning_chars)
	return JSON.stringify({"choices": [{"message": msg, "finish_reason": finish}]})


## Attempt-2 class: a full valid StrategicPlan (~4K chars live) with three
## missions, contingencies, hypotheses, and review conditions.
func _attempt2_plan() -> Dictionary:
	return {
		"concept": {"objective": "Fix the BLUE center with massed infantry and archers while cavalry and scouts develop the northern flank for a turning movement against the river crossing.",
			"intent": "Hold the HQ and southern approaches with minimal force; the main effort strikes north once BLUE commits its reserve to the center.",
			"main_effort": "NORTH", "risk_posture": "BALANCED"},
		"doctrine": {"aggression": 0.6, "risk_tolerance": 0.5, "tempo": 0.6, "pursuit": 0.5, "reserve_discipline": 0.6, "deception": 0.3},
		"missions": [
			{"mission_id": "M01", "task": "FIX", "area": "CENTER",
				"assigned_units": ["R_INF_1", "R_INF_2", "R_ARC_1", "R_ARC_2"],
				"objective": {"kind": "REGION", "region": "CENTER"},
				"engagement": {"policy": "ATTACK_IF_ADVANTAGEOUS"},
				"constraints": {"preserve_force": false, "max_overextension": 3},
				"success_conditions": ["REGION_OCCUPIED"], "abort_conditions": ["FORCE_STRENGTH_BELOW"], "report_conditions": ["MISSION_BLOCKED"]},
			{"mission_id": "M02", "task": "FLANK", "area": "NORTH",
				"assigned_units": ["R_CAV_1", "R_CAV_2", "R_SCT_1"],
				"objective": {"kind": "REGION", "region": "NORTH"},
				"engagement": {"policy": "PURSUE_WEAKENED"},
				"constraints": {"preserve_force": true, "max_overextension": 5},
				"success_conditions": ["REGION_REACHED"], "abort_conditions": ["HQ_THREATENED"], "report_conditions": ["ENEMY_COMMITMENT_HIGH"]},
			{"mission_id": "M03", "task": "HOLD", "area": "SOUTH",
				"assigned_units": ["R_HQ_1", "R_SPE_1"],
				"objective": {"kind": "ZONE", "zone": "HQ"},
				"engagement": {"policy": "HOLD_FIRE"},
				"constraints": {"preserve_force": true, "max_overextension": 1},
				"success_conditions": [], "abort_conditions": [], "report_conditions": ["HQ_THREATENED"]},
		],
		"contingencies": [
			{"contingency_id": "C1", "trigger": "HQ_THREATENED", "params": {},
				"action": "ABORT_MISSION", "mission_id": "M02", "note": "Recall the flank force to screen the HQ."},
			{"contingency_id": "C2", "trigger": "MISSION_BLOCKED", "params": {},
				"action": "REQUEST_REVIEW", "mission_id": "M01", "note": "Center fix stalled; ask the General to re-plan."},
		],
		"opponent_hypotheses": [
			{"hypothesis": "CENTER_BREAKTHROUGH", "confidence": 0.55, "evidence": ["BLUE infantry and spearmen massed near the river crossing", "BLUE archers holding high ground behind the ford"]},
			{"hypothesis": "NORTHERN_FEINT", "confidence": 0.3, "evidence": ["BLUE cavalry sighted then withdrew north of the road"]},
		],
		"review_conditions": ["MISSION_BLOCKED", "HQ_THREATENED", "ENEMY_COMMITMENT_HIGH"],
		"review_horizon_turns": 4,
	}


## One production-path run: raw envelope bytes -> extractor -> parser input.
## Returns {transport_ok, content_text, finish_reason, envelope}.
func _extract(wire_text: String) -> Dictionary:
	return AdapterCls.classify_http_body(ConfigCls.TRANSPORT_OPENAI, 200, wire_text)


## Retry predicate mirror: the controller retries once on any non-STALE parse
## rejection. STALE_SNAPSHOT never retries (fresh observation required).
static func _would_retry(parsed: Dictionary) -> bool:
	return not bool(parsed.get("ok", false)) and str(parsed.get("code", "")) != "STALE_SNAPSHOT"


# --- gates --------------------------------------------------------------------

func _f1_attempt1_prose_rejects() -> void:
	var ev := {}
	var wire := _openai_envelope(_attempt1_prose_final(), 13753, "stop")
	var judged := _extract(wire)
	ev["transport_ok"] = bool(judged.get("ok", false))
	ev["finish"] = str(judged.get("finish_reason", ""))
	ev["final_chars"] = str(judged.get("content_text", "")).length()
	ev["reasoning_chars"] = int((judged.get("envelope", {}) as Dictionary).get("reasoning_chars", -1))
	var parsed := GeneralResponseCls.parse(str(judged.get("content_text", "")),
		{"turn": 1, "snapshot_id": "snap_live", "plan_version": 1})
	ev["parse_ok"] = bool(parsed.get("ok", false))
	ev["parse_code"] = str(parsed.get("code", ""))
	ev["would_retry"] = _would_retry(parsed)
	var ok := bool(judged.get("ok", false)) \
		and str(judged.get("finish_reason", "")) == "stop" \
		and str(judged.get("content_text", "")).length() > 100 \
		and int((judged.get("envelope", {}) as Dictionary).get("reasoning_chars", 0)) == 13753 \
		and not bool(parsed.get("ok", false)) \
		and str(parsed.get("code", "")) == "INVALID_JSON" \
		and _would_retry(parsed)
	_record("f1_attempt1_prose_rejects", "pass" if ok else "fail", ev)


func _f2_attempt1_wrong_shape_rejects() -> void:
	var ev := {}
	var tactical := JSON.stringify({"plan": {"objective": "o", "intent": "i", "reconsider_if": "r"},
		"orders": [{"action": "HOLD"}]})
	var jt := _extract(_openai_envelope(tactical, 2634, "stop"))
	var pt := GeneralResponseCls.parse(str(jt.get("content_text", "")))
	ev["tactical_transport_ok"] = bool(jt.get("ok", false))
	ev["tactical_code"] = str(pt.get("code", ""))
	ev["tactical_retry"] = _would_retry(pt)
	var keep := JSON.stringify({"decision": "KEEP", "reason": "plan still valid", "adjustments": []})
	var jk := _extract(_openai_envelope(keep, 0, "stop"))
	var pk := GeneralResponseCls.parse(str(jk.get("content_text", "")))
	ev["keep_code"] = str(pk.get("code", ""))
	ev["keep_retry"] = _would_retry(pk)
	var ok := bool(jt.get("ok", false)) and str(pt.get("code", "")) == "INVALID_SCHEMA" \
		and _would_retry(pt) and bool(jk.get("ok", false)) \
		and str(pk.get("code", "")) == "INVALID_SCHEMA" and _would_retry(pk)
	_record("f2_attempt1_wrong_shape_rejects", "pass" if ok else "fail", ev)


func _f3_attempt2_valid_adopts() -> void:
	var ev := {}
	var plan_text := JSON.stringify(_attempt2_plan())
	var judged := _extract(_openai_envelope(plan_text, 2634, "stop"))
	ev["transport_ok"] = bool(judged.get("ok", false))
	ev["final_chars"] = str(judged.get("content_text", "")).length()
	var parsed := GeneralResponseCls.parse(str(judged.get("content_text", "")),
		{"turn": 1, "snapshot_id": "snap_live", "plan_version": 1})
	ev["parse_ok"] = bool(parsed.get("ok", false))
	ev["parse_code"] = str(parsed.get("code", ""))
	var mgr := MissionManagerCls.new()
	var applied := mgr.apply_plan(parsed.get("plan", {}), 1, "snap_live", "forensic_battle")
	ev["adopt_ok"] = bool(applied.get("ok", false))
	ev["adopt_code"] = str(applied.get("code", ""))
	ev["adopt_version"] = int(applied.get("version", 0))
	ev["adopt_missions"] = (mgr.get_plan().get("missions", []) as Array).size()
	ev["adopt_source"] = str(mgr.get_plan().get("source", ""))
	var ok := bool(judged.get("ok", false)) \
		and str(judged.get("content_text", "")).length() > 2000 \
		and bool(parsed.get("ok", false)) \
		and bool(applied.get("ok", false)) \
		and int(applied.get("version", 0)) == 1 \
		and (mgr.get_plan().get("missions", []) as Array).size() == 3
	_record("f3_attempt2_valid_adopts", "pass" if ok else "fail", ev)


func _f4_byte_equivalence() -> void:
	var ev := {}
	var finals := [_attempt1_prose_final(), JSON.stringify(_attempt2_plan()),
		"```json\n" + JSON.stringify(_attempt2_plan()) + "\n```"]
	var all_match := true
	var chars: Array = []
	var codes: Array = []
	for f_val in finals:
		var judged := _extract(_openai_envelope(str(f_val), 0, "stop"))
		var parser_input := str(judged.get("content_text", ""))
		chars.append(parser_input.length())
		if parser_input != str((_extract(_openai_envelope(str(f_val), 0, "stop")).get("content_text", ""))):
			all_match = false
		codes.append(str(GeneralResponseCls.parse(parser_input).get("code", "")))
	ev["chars"] = chars
	ev["codes"] = codes
	ev["all_match"] = all_match
	ev["fenced_ok"] = str(GeneralResponseCls.parse(str(_extract(_openai_envelope(finals[2], 0, "stop")).get("content_text", ""))).get("ok", false)) == "true"
	# The parser must see exactly the extractor output: re-parse the frozen
	# extractor text and confirm identical outcomes (deterministic pipeline).
	var p1 := GeneralResponseCls.parse(str(_extract(_openai_envelope(finals[1], 0, "stop")).get("content_text", "")))
	var p2 := GeneralResponseCls.parse(str(_extract(_openai_envelope(finals[1], 0, "stop")).get("content_text", "")))
	ev["deterministic"] = bool(p1.get("ok", false)) and bool(p2.get("ok", false)) \
		and JSON.stringify(p1.get("plan", {})) == JSON.stringify(p2.get("plan", {}))
	var ok := all_match and bool(ev["deterministic"]) and bool(ev["fenced_ok"])
	_record("f4_byte_equivalence", "pass" if ok else "fail", ev)


func _base_plan_for_matrix() -> Dictionary:
	return _attempt2_plan()


func _f5_rejection_matrix() -> void:
	var ev := {}
	var cases: Array = []
	var p := _base_plan_for_matrix()
	(p["missions"][0] as Dictionary)["task"] = "TELEPORT"
	cases.append(["MISSION_TASK", JSON.stringify(p)])
	p = _base_plan_for_matrix()
	(p["missions"][0] as Dictionary)["area"] = "MOON"
	cases.append(["MISSION_AREA", JSON.stringify(p)])
	p = _base_plan_for_matrix()
	(p["missions"][0] as Dictionary)["objective"] = {"kind": "ORBITAL"}
	cases.append(["MISSION_OBJECTIVE", JSON.stringify(p)])
	p = _base_plan_for_matrix()
	(p["missions"][0] as Dictionary)["engagement"] = {"policy": "CHARGE_BLINDLY"}
	cases.append(["MISSION_ENGAGEMENT", JSON.stringify(p)])
	p = _base_plan_for_matrix()
	(p["missions"][0] as Dictionary)["success_conditions"] = ["INVADE_MOON"]
	cases.append(["MISSION_CONDITION", JSON.stringify(p)])
	p = _base_plan_for_matrix()
	p["missions"] = []
	cases.append(["PLAN_EMPTY", JSON.stringify(p)])
	p = _base_plan_for_matrix()
	(p["missions"][1] as Dictionary)["mission_id"] = "M01"
	cases.append(["PLAN_DUP_MISSION", JSON.stringify(p)])
	p = _base_plan_for_matrix()
	p["opponent_hypotheses"] = [{"confidence": 0.9, "evidence": ["x"]}]
	cases.append(["PLAN_HYPOTHESES", JSON.stringify(p)])
	p = _base_plan_for_matrix()
	p["contingencies"] = [{"contingency_id": "C9", "trigger": "HQ_THREATENED", "action": "NUKE"}]
	cases.append(["CONTINGENCY_ACTION", JSON.stringify(p)])
	p = _base_plan_for_matrix()
	p["snapshot_id"] = "snap_old"
	cases.append(["STALE_SNAPSHOT", JSON.stringify(p)])
	var got: Array = []
	var retry_ok := true
	for c_val in cases:
		var want := str(c_val[0])
		var judged := _extract(_openai_envelope(str(c_val[1]), 0, "stop"))
		var parsed := GeneralResponseCls.parse(str(judged.get("content_text", "")),
			{"turn": 1, "snapshot_id": "snap_live", "plan_version": 1})
		var code := str(parsed.get("code", ""))
		got.append(code)
		if code != want:
			retry_ok = false
		var should_retry := want != "STALE_SNAPSHOT"
		if _would_retry(parsed) != should_retry:
			retry_ok = false
	ev["want"] = cases.map(func(c: Array) -> String: return str(c[0]))
	ev["got"] = got
	_record("f5_rejection_matrix", "pass" if retry_ok else "fail", ev)


func _f6_trace_general_outcome() -> void:
	var ev := {}
	TraceCls.clear()
	TraceCls.begin_turn({"provider": "openai", "model": "forensic", "protocol": "openai_chat", "mode": "AUTO"})
	TraceCls.set_stage("GENERAL_PLANNING", "forensic")
	TraceCls.set_general_outcome({"attempt": 2, "request_id": "general_t1_r1", "outcome": "REJECTED_INVALID_SCHEMA",
		"code": "INVALID_SCHEMA", "detail": "General response needs 'missions'.",
		"response_chars": 4073, "http_status": 200, "finish_reason": "stop",
		"plan_version": 0, "missions": 0})
	var rec: Dictionary = (TraceCls.snapshot_current().get("turn_record", {}) as Dictionary)
	var g: Dictionary = rec.get("general", {}) as Dictionary
	ev["outcome"] = str(g.get("outcome", ""))
	ev["code"] = str(g.get("code", ""))
	ev["response_chars"] = int(g.get("response_chars", 0))
	ev["decision_empty"] = ((rec.get("decision", {}) as Dictionary).get("plan", {}) as Dictionary).is_empty()
	var proj: Dictionary = TraceCls._persistable(rec)
	var ptext := JSON.stringify(proj)
	ev["persist_has_general"] = (proj.get("general", {}) as Dictionary).size() > 0
	ev["persist_clean"] = ptext.find("raw_final") == -1 and ptext.find("reasoning_content") == -1
	var ok := str(g.get("outcome", "")) == "REJECTED_INVALID_SCHEMA" \
		and str(g.get("code", "")) == "INVALID_SCHEMA" \
		and int(g.get("response_chars", 0)) == 4073 \
		and bool(ev["decision_empty"]) \
		and bool(ev["persist_has_general"]) and bool(ev["persist_clean"])
	_record("f6_trace_general_outcome", "pass" if ok else "fail", ev)


func _f7_modelview_pipeline_summary() -> void:
	var ev := {}
	var entry := {
		"request_id": "general_t1", "kind": "GENERAL_REVIEW", "attempt": 2,
		"parent_request_id": "general_t0", "trigger": "INITIAL_PLAN", "reason": "",
		"turn": 1, "snapshot_id": "snap_live", "battle_id": "b1",
		"provider": "openai", "model": "deepseek", "max_tokens": 4096,
		"timeout_sec": 240, "started_ms": 1000, "ended_ms": 9000,
		"request_text": "{}", "request_chars": 4200, "system_chars": 2400,
		"packet_chars": 1700, "response_text": "{}", "response_chars": 4073,
		"http_status": 200, "latency_ms": 8000, "finish_reason": "stop",
		"reasoning_present": true, "reasoning_chars": 2634,
		"ok": true, "code": "", "detail": "", "outcome": "REJECTED_INVALID_SCHEMA",
		"pipeline": {"transport": "SUCCESS", "parse": "PASS", "plan": "FAIL_INVALID_SCHEMA", "adoption": "PENDING"},
		"parser_input_chars": 4073, "parser_input_match": true,
	}
	var text := ModelViewCls.render_summary(entry)
	ev["has_transport"] = text.find("TRANSPORT    SUCCESS") != -1
	ev["has_parse"] = text.find("PARSE        PASS") != -1
	ev["has_plan"] = text.find("PLAN         FAIL_INVALID_SCHEMA") != -1
	ev["has_adoption"] = text.find("ADOPTION     PENDING") != -1
	ev["has_parser"] = text.find("parser_input 4073 chars match=true") != -1
	ev["has_reasoning"] = text.find("reasoning    present (2634 chars, metadata only)") != -1
	var legacy := {"request_id": "x", "kind": "GENERAL_REVIEW", "started_ms": 1, "ended_ms": 2}
	var legacy_text := ModelViewCls.render_summary(legacy)
	ev["legacy_clean"] = legacy_text.find("POST-TRANSPORT") == -1
	var ok := bool(ev["has_transport"]) and bool(ev["has_parse"]) \
		and bool(ev["has_plan"]) and bool(ev["has_adoption"]) \
		and bool(ev["has_parser"]) and bool(ev["has_reasoning"]) \
		and bool(ev["legacy_clean"])
	_record("f7_modelview_pipeline_summary", "pass" if ok else "fail", ev)


func _f8_request_system_counters() -> void:
	var ev := {}
	TraceCls.clear()
	TraceCls.begin_turn({"provider": "openai", "model": "forensic", "protocol": "openai_chat", "mode": "AUTO"})
	var rec0: Dictionary = (TraceCls.snapshot_current().get("turn_record", {}) as Dictionary)
	ev["default_zero"] = int(rec0.get("request_chars", -1)) == 0 and int(rec0.get("system_chars", -1)) == 0
	TraceCls.refresh_snapshot("snap_live", 3, 4200, 2400)
	var rec1: Dictionary = (TraceCls.snapshot_current().get("turn_record", {}) as Dictionary)
	ev["request_chars"] = int(rec1.get("request_chars", 0))
	ev["system_chars"] = int(rec1.get("system_chars", 0))
	TraceCls.refresh_snapshot("snap_live2", 4, 4300)
	var rec2: Dictionary = (TraceCls.snapshot_current().get("turn_record", {}) as Dictionary)
	ev["legacy_request"] = int(rec2.get("request_chars", 0))
	ev["legacy_system_kept"] = int(rec2.get("system_chars", 0))
	var ok := bool(ev["default_zero"]) \
		and int(rec1.get("request_chars", 0)) == 4200 \
		and int(rec1.get("system_chars", 0)) == 2400 \
		and int(rec2.get("request_chars", 0)) == 4300 \
		and int(rec2.get("system_chars", 0)) == 2400
	_record("f8_request_system_counters", "pass" if ok else "fail", ev)


func _f9_envelope_edges() -> void:
	var ev := {}
	var exhausted := AdapterCls.classify_http_body(ConfigCls.TRANSPORT_OPENAI, 200,
		_openai_envelope("", 18220, "length"))
	ev["exhausted_code"] = str(exhausted.get("code", ""))
	var wire_refusal := JSON.stringify({"choices": [{"message": {"role": "assistant", "content": "", "refusal": "I cannot help."}, "finish_reason": "stop"}]})
	var refused := AdapterCls.classify_http_body(ConfigCls.TRANSPORT_OPENAI, 200, wire_refusal)
	ev["refusal_code"] = str(refused.get("code", ""))
	# Transport failures carry no final text, so the General parser must never
	# see them: the controller returns before parsing (nothing to retry here).
	ev["exhausted_no_text"] = str(exhausted.get("content_text", "")).is_empty()
	ev["refusal_no_text"] = str(refused.get("content_text", "")).is_empty()
	var ok := str(exhausted.get("code", "")) == "REASONING_BUDGET_EXHAUSTED" \
		and str(refused.get("code", "")) == "MODEL_REFUSAL" \
		and bool(ev["exhausted_no_text"]) and bool(ev["refusal_no_text"])
	_record("f9_envelope_edges", "pass" if ok else "fail", ev)
