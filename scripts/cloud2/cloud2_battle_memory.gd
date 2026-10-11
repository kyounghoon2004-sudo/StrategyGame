class_name Cloud2BattleMemory
extends RefCounted

## CLOUD-GENERAL MISSION HIERARCHY — persistent battle memory (files).
##
## Canonical storage under user://cloud_general/<battle_id>/:
##   mission.json, strategic_plan.json, opponent_model.json,
##   battle_summary.json, event_log.jsonl
##
## AUTHORITY RULE: files are MEMORY, not WORLD TRUTH. Godot runtime state
## always wins — loaded plans are reconciled (dead/unknown units dropped)
## and adopted only when their based_on_snapshot still matches the live
## snapshot; anything else is reported STALE, never executed blindly.
##
## Never stored: API keys, authorization material, hidden reasoning, raw
## chain-of-thought, or duplicated world state. Structured decisions and
## facts only (records pass through the shared secret scrubber).

const LoggerCls = preload("res://scripts/cloud2/cloud2_logger.gd")
const PlanCls = preload("res://scripts/cloud2/cloud2_general_plan.gd")
const VictoryPlanCls = preload("res://scripts/cloud2/cloud2_victory_plan.gd")

const MEMORY_ROOT := "user://cloud_general"
const MAX_EVENT_LINES := 512


static func battle_dir(battle_id: String) -> String:
	return "%s/%s" % [MEMORY_ROOT, _safe_id(battle_id)]


static func _safe_id(raw: String) -> String:
	var out := ""
	for i in range(raw.length()):
		var c := raw[i]
		if (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or (c >= "0" and c <= "9") or c == "_" or c == "-":
			out += c
		else:
			out += "_"
	if out.is_empty():
		out = "unknown_battle"
	return out.left(64)


static func ensure_dir(battle_id: String) -> bool:
	var d := DirAccess.open("user://")
	if d == null:
		return false
	var err := d.make_dir_recursive("cloud_general/%s" % _safe_id(battle_id))
	return err == OK


static func _write_json(path: String, data: Dictionary) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(LoggerCls.scrub(data), "  "))
	f.close()
	return true


static func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"ok": false, "code": "NO_FILE", "data": {}}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {"ok": false, "code": "UNREADABLE", "data": {}}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if not parsed is Dictionary:
		return {"ok": false, "code": "CORRUPT", "data": {}}
	return {"ok": true, "code": "", "data": parsed}


## Persist the full structured memory for one battle. Returns {ok, files}.
static func save_all(battle_id: String, mission: Dictionary, plan: Dictionary, hypotheses: Array, summary: Dictionary, events: Array) -> Dictionary:
	if not ensure_dir(battle_id):
		return {"ok": false, "files": []}
	var dir := battle_dir(battle_id)
	var files: Array = []
	if _write_json("%s/mission.json" % dir, {"battle_id": battle_id, "mission": mission}):
		files.append("mission.json")
	if _write_json("%s/strategic_plan.json" % dir, {"battle_id": battle_id, "plan": plan}):
		files.append("strategic_plan.json")
	if _write_json("%s/opponent_model.json" % dir, {"battle_id": battle_id, "hypotheses": hypotheses}):
		files.append("opponent_model.json")
	if _write_json("%s/battle_summary.json" % dir, {"battle_id": battle_id, "summary": summary}):
		files.append("battle_summary.json")
	if _write_events("%s/event_log.jsonl" % dir, events):
		files.append("event_log.jsonl")
	return {"ok": files.size() == 5, "files": files}


static func _write_events(path: String, events: Array) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	var tail: Array = events.slice(maxi(0, events.size() - MAX_EVENT_LINES))
	for e_val in tail:
		if e_val is Dictionary:
			f.store_string(JSON.stringify(LoggerCls.scrub(e_val)) + "\n")
	f.close()
	return true


static func load_plan(battle_id: String) -> Dictionary:
	var raw := _read_json("%s/strategic_plan.json" % battle_dir(battle_id))
	if not bool(raw.get("ok", false)):
		return {"ok": false, "code": str(raw.get("code", "NO_FILE")), "plan": {}}
	var plan: Variant = (raw.get("data", {}) as Dictionary).get("plan", {})
	if not plan is Dictionary:
		return {"ok": false, "code": "CORRUPT", "plan": {}}
	var checked := PlanCls.validate_plan(plan, {})
	if not bool(checked.get("ok", false)):
		return {"ok": false, "code": str(checked.get("code", "INVALID")), "plan": {}}
	return {"ok": true, "code": "", "plan": checked.get("plan", {})}


## VICTORY PLAN V0 (additive): persistent strategic memory.
## victory_plan.json (canonical plan), victory_plan_revisions.jsonl (every
## adopted revision, full snapshots), general_audit.jsonl (every General
## invocation). Same authority rule: memory, never world truth.
static func save_victory(battle_id: String, vp: Dictionary, revisions: Array, audit: Array) -> Dictionary:
	if not ensure_dir(battle_id):
		return {"ok": false, "files": []}
	var dir := battle_dir(battle_id)
	var files: Array = []
	if _write_json("%s/victory_plan.json" % dir, {"battle_id": battle_id, "plan": vp}):
		files.append("victory_plan.json")
	if _write_jsonl("%s/victory_plan_revisions.jsonl" % dir, revisions):
		files.append("victory_plan_revisions.jsonl")
	if _write_jsonl("%s/general_audit.jsonl" % dir, audit):
		files.append("general_audit.jsonl")
	return {"ok": files.size() == 3, "files": files}


static func _write_jsonl(path: String, rows: Array) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	for r_val in rows:
		if r_val is Dictionary:
			f.store_string(JSON.stringify(LoggerCls.scrub(r_val)) + "\n")
	f.close()
	return true


## Live API repair V1: append-only raw General response log
## (general_responses.jsonl, last 20, response text bounded). Forensic
## only: the NEXT malformed reply is diagnosable post-hoc from disk.
## Rows are scrubbed; model text carries no secrets by construction.
const MAX_GENERAL_RESPONSES := 20
const GENERAL_RESPONSE_TEXT_CHARS := 24000


static func append_general_response(battle_id: String, row: Dictionary) -> void:
	var bid := battle_id.strip_edges()
	if bid.is_empty():
		return
	if not ensure_dir(bid):
		return
	var path := "%s/general_responses.jsonl" % battle_dir(bid)
	var rows := _read_jsonl(path)
	var r := {
		"req": str(row.get("req", "?")),
		"turn": int(row.get("turn", 0)),
		"kind": str(row.get("kind", "?")),
		"http": int(row.get("http", 0)),
		"latency_ms": int(row.get("latency_ms", 0)),
		"finish": str(row.get("finish", "")),
		"final_chars": int(row.get("final_chars", 0)),
		"reasoning_present": bool(row.get("reasoning_present", false)),
		"reasoning_chars": int(row.get("reasoning_chars", 0)),
		"usage": row.get("usage", {}),
		"outcome": str(row.get("outcome", "?")),
		"budget": int(row.get("budget", 0)),
		"text": str(row.get("text", "")).left(GENERAL_RESPONSE_TEXT_CHARS),
	}
	rows.append(LoggerCls.scrub(r))
	while rows.size() > MAX_GENERAL_RESPONSES:
		rows.pop_front()
	_write_jsonl(path, rows)


static func load_victory(battle_id: String) -> Dictionary:
	var raw := _read_json("%s/victory_plan.json" % battle_dir(battle_id))
	if not bool(raw.get("ok", false)):
		return {"ok": false, "code": str(raw.get("code", "NO_FILE")), "vp": {}, "revisions": [], "audit": []}
	var vp: Variant = (raw.get("data", {}) as Dictionary).get("plan", {})
	if not vp is Dictionary:
		return {"ok": false, "code": "CORRUPT", "vp": {}, "revisions": [], "audit": []}
	var checked := VictoryPlanCls.validate_plan(vp, {})
	if not bool(checked.get("ok", false)):
		return {"ok": false, "code": str(checked.get("code", "INVALID")), "vp": {}, "revisions": [], "audit": []}
	return {"ok": true, "code": "", "vp": checked.get("plan", {}),
		"revisions": _read_jsonl("%s/victory_plan_revisions.jsonl" % battle_dir(battle_id)),
		"audit": _read_jsonl("%s/general_audit.jsonl" % battle_dir(battle_id))}


static func _read_jsonl(path: String) -> Array:
	if not FileAccess.file_exists(path):
		return []
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return []
	var out: Array = []
	while not f.eof_reached():
		var line := f.get_line().strip_edges()
		if line.is_empty():
			continue
		var parsed: Variant = JSON.parse_string(line)
		if parsed is Dictionary:
			out.append(parsed)
	f.close()
	return out


static func load_events(battle_id: String) -> Array:
	var path := "%s/event_log.jsonl" % battle_dir(battle_id)
	if not FileAccess.file_exists(path):
		return []
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return []
	var out: Array = []
	while not f.eof_reached():
		var line := f.get_line().strip_edges()
		if line.is_empty():
			continue
		var parsed: Variant = JSON.parse_string(line)
		if parsed is Dictionary:
			out.append(parsed)
	f.close()
	return out


static func load_hypotheses(battle_id: String) -> Array:
	var raw := _read_json("%s/opponent_model.json" % battle_dir(battle_id))
	if not bool(raw.get("ok", false)):
		return []
	var hyps: Variant = (raw.get("data", {}) as Dictionary).get("hypotheses", [])
	return (hyps as Array).duplicate(true) if hyps is Array else []


static func describe(battle_id: String) -> String:
	var dir := battle_dir(battle_id)
	var names := ["mission.json", "strategic_plan.json", "opponent_model.json", "battle_summary.json", "event_log.jsonl"]
	var have: Array = []
	for n in names:
		if FileAccess.file_exists("%s/%s" % [dir, n]):
			have.append(n)
	return "%s [%d/5 files]" % [dir, have.size()]
