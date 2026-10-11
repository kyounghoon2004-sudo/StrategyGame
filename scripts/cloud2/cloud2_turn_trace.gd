class_name Cloud2TurnTrace
extends RefCounted

## CLOUD-GENERAL STEP 2 — Turn observability store (ISSUE 1 ONLY).
##
## Pure telemetry: records what the existing pipeline ALREADY did, stage by
## stage, so a human can separate MODEL DELIBERATION COST (thinking telemetry)
## from MODEL FINAL DECISION (plan/rationale/orders) from GODOT EXECUTION
## (compiled units, per-unit outcomes). It never mutates gameplay, never
## changes retry/budget policy, never re-scores or re-validates anything.
##
## Chain-of-thought safety: reasoning_content is NEVER stored here — only
## provider-safe telemetry (presence, char count, provider-reported usage
## tokens, finish_reason). The model's explicit FINAL text (plan/rationale/
## orders JSON) is stored separately as the Decision Trace and is the only
## model text that ever reached Cloud2Response.parse.
##
## Storage: static (process-lifetime), like Cloud2Session. Bounded:
##   - attempts per turn: MAX_ATTEMPTS (drops the OLDEST attempt record only
##     if a pathological turn exceeds it; real turns make 1..2)
##   - turn history: MAX_TURNS compact summaries (FIFO)
## Persistence (DEV evidence): end_turn writes one secret-free JSON under
## res://evidence/cloud2_trace/ through Cloud2Logger.scrub. Raw final model
## content and any reasoning text are deliberately NOT persisted.

const LoggerCls = preload("res://scripts/cloud2/cloud2_logger.gd")

const MAX_TURNS := 20
const MAX_ATTEMPTS := 8
const LOG_DIR := "res://evidence/cloud2_trace"
const RAW_FINAL_STORE_LIMIT := 200000 # in-memory display bound; never persisted

## Validator code families for the VALIDATION trace (classification only —
## validation itself always ran once in Cloud2Response, unchanged).
const SCHEMA_CODES := ["INVALID_COMMAND", "INVALID_SCHEMA", "UNKNOWN_ACTION",
	"ACTION_DEFERRED", "INVALID_SCOPE", "INVALID_TARGET", "INVALID_DIRECTION",
	"INVALID_STANCE", "INVALID_POLICY"]
const SEMANTIC_CODES := ["SELECTED_REJECTED", "SIDE_MISMATCH", "STALE_SNAPSHOT",
	"SEMANTIC_REJECT"]

static var _current: Dictionary = {}
static var _history: Array = [] # compact summaries, oldest first
static var _rev := 0 # bumped on every mutation; UI polls this
static var _persist := true
static var _seq := 0

# --- lifecycle -------------------------------------------------------------

## Start a fresh turn record (one per run_red_phase). Safe to call repeatedly:
## only the first call per phase wins; later calls during the same phase
## (human RETRY loops inside _run_inner) keep accumulating attempts.
static func begin_turn(meta: Dictionary) -> void:
	if not _current.is_empty() and str(_current.get("status", "")) == "RUNNING":
		return
	_seq += 1
	_current = {
		"seq": _seq,
		"turn": int(meta.get("turn", 0)),
		"provider": str(meta.get("provider", "")),
		"model": str(meta.get("model", "")),
		"protocol": str(meta.get("protocol", "")),
		"mode": str(meta.get("mode", "")),
		"snapshot_id": "",
		"state_version": -1,
		"request_chars": 0,
		"system_chars": 0,
		"stage": "OBSERVING",
		"stage_note": "",
		"status": "RUNNING",
		"note": "",
		"attempts": [],
		"decision": {"plan": {}, "rationale": {}, "raw_final": ""},
		"general": {},
		"orders": [],
		"summary": {},
		"started_ms": Time.get_ticks_msec(),
		"ended_ms": 0,
	}
	_bump()


static func set_stage(stage: String, note: String = "") -> void:
	if _current.is_empty():
		return
	_current["stage"] = stage
	if not note.is_empty():
		_current["stage_note"] = note
	_bump()


static func set_turn_meta(turn: int, snapshot_id: String, state_version: int,
		request_chars: int, system_chars: int) -> void:
	if _current.is_empty():
		return
	_current["turn"] = turn
	_current["snapshot_id"] = snapshot_id
	_current["state_version"] = state_version
	_current["request_chars"] = request_chars
	_current["system_chars"] = system_chars
	_bump()


## Re-announce after a human RETRY re-froze the observation (same turn record,
## newer snapshot): attempts keep accumulating. system_chars < 0 leaves the
## stored system count untouched (legacy callers); pass the real system-prompt
## length whenever it is known so THINKING telemetry never reads 0/0.
static func refresh_snapshot(snapshot_id: String, state_version: int, request_chars: int, system_chars: int = -1) -> void:
	if _current.is_empty():
		return
	_current["snapshot_id"] = snapshot_id
	_current["state_version"] = state_version
	_current["request_chars"] = request_chars
	if system_chars >= 0:
		_current["system_chars"] = system_chars
	_bump()


# --- attempts (THINKING TELEMETRY) ------------------------------------------

## One model flight begins. budget = output token budget for this flight.
static func begin_attempt(index: int, budget: int, request_id: String) -> void:
	if _current.is_empty():
		return
	var arr: Array = _current.get("attempts", [])
	if arr.size() >= MAX_ATTEMPTS:
		arr.pop_front()
	arr.append({
		"index": index,
		"budget": budget,
		"request_id": request_id,
		"started_ms": Time.get_ticks_msec(),
		"finished_ms": 0,
		"latency_ms": 0,
		"http_status": 0,
		"ok": false,
		"code": "",
		"detail": "",
		"finish_reason": "",
		"content_chars": 0,
		"content_type": "",
		"reasoning_present": false,
		"reasoning_chars": 0,
		"usage": {}, # provider-reported token usage; empty when absent
		"mock": false,
		"result": "IN_FLIGHT",
		"retry": "",
	})
	_current["attempts"] = arr
	_bump()


## The model flight ended. res is the adapter result (ok or failure envelope).
static func finish_attempt(res: Dictionary) -> void:
	if _current.is_empty():
		return
	var arr: Array = _current.get("attempts", [])
	if arr.is_empty():
		return
	var a: Dictionary = arr[arr.size() - 1]
	if str(a.get("result", "")) != "IN_FLIGHT":
		return # already finished (duplicate signal guard)
	var env: Dictionary = {}
	if res.get("envelope") is Dictionary:
		env = (res.get("envelope") as Dictionary).duplicate(true)
	a["finished_ms"] = Time.get_ticks_msec()
	a["latency_ms"] = int(res.get("latency_ms", 0))
	a["http_status"] = int(res.get("http_status", 0))
	a["mock"] = bool(res.get("mock", false))
	a["finish_reason"] = str(res.get("finish_reason", env.get("finish_reason", "")))
	a["usage"] = _safe_usage(env.get("usage", {}))
	if bool(res.get("ok", false)):
		a["ok"] = true
		a["code"] = ""
		a["result"] = "SUCCESS"
		a["detail"] = ""
		a["content_chars"] = str(res.get("content_text", "")).length()
		a["content_type"] = str(env.get("content_type", ""))
	else:
		a["ok"] = false
		a["code"] = str(res.get("code", "PROVIDER_ERROR"))
		a["result"] = a["code"]
		a["detail"] = str(res.get("detail", ""))
		a["content_chars"] = int(env.get("content_chars", 0))
		a["content_type"] = str(env.get("content_type", ""))
	a["reasoning_present"] = bool(env.get("reasoning_present", false))
	a["reasoning_chars"] = int(env.get("reasoning_chars", 0))
	_bump()


## The controller decided to auto-retry the just-finished attempt with a
## larger budget. Observation only — the retry decision itself is unchanged.
static func mark_retry(next_budget: int) -> void:
	if _current.is_empty():
		return
	var arr: Array = _current.get("attempts", [])
	for i in range(arr.size() - 1, -1, -1):
		var a: Dictionary = arr[i]
		if str(a.get("result", "")) == "IN_FLIGHT":
			continue
		a["retry"] = "YES -> %d" % next_budget
		break
	_bump()


## Started-but-unfinished attempt (for the live THINKING... elapsed readout).
static func in_flight_attempt() -> Dictionary:
	if _current.is_empty():
		return {}
	var arr: Array = _current.get("attempts", [])
	for i in range(arr.size() - 1, -1, -1):
		var a: Dictionary = arr[i]
		if str(a.get("result", "")) == "IN_FLIGHT":
			return a.duplicate(true)
	return {}


# --- decision (FINAL DECISION TRACE) ----------------------------------------

## The final tactical decision that reached the structured pipeline: the
## parsed plan/rationale plus the raw final model text (NOT reasoning_content)
## that was passed toward Cloud2Response.parse.
static func set_decision(parsed: Dictionary, raw_final: String) -> void:
	if _current.is_empty():
		return
	var clipped := raw_final
	if clipped.length() > RAW_FINAL_STORE_LIMIT:
		clipped = clipped.left(RAW_FINAL_STORE_LIMIT) + "...(truncated)"
	_current["decision"] = {
		"plan": (parsed.get("plan", {}) as Dictionary).duplicate(true),
		"rationale": (parsed.get("rationale", {}) as Dictionary).duplicate(true),
		"raw_final": clipped,
	}
	_bump()


## General planning outcome (hierarchy path): metadata ONLY — outcome code,
## response size, adoption result. Never model text: the exact General final
## response lives in the Model View interaction snapshot, and the tactical
## decision slot above stays tactical-only. Overwritten per attempt so the
## record always shows the latest General disposition for this turn.
static func set_general_outcome(o: Dictionary) -> void:
	if _current.is_empty():
		return
	_current["general"] = {
		"attempt": int(o.get("attempt", 0)),
		"request_id": str(o.get("request_id", "")),
		"outcome": str(o.get("outcome", "")),
		"code": str(o.get("code", "")),
		"detail": str(o.get("detail", "")).left(240),
		"response_chars": int(o.get("response_chars", 0)),
		"http_status": int(o.get("http_status", 0)),
		"finish_reason": str(o.get("finish_reason", "")),
		"plan_version": int(o.get("plan_version", 0)),
		"missions": int(o.get("missions", 0)),
	}
	_bump()


# --- orders (VALIDATION / COMPILER / EXECUTION) -----------------------------

## Receive the controller's per-order views (the SAME data its record/log get:
## validation result, resolved units, executed rows, failed rows). Called
## repeatedly during sequential execution; the store re-derives its traces.
static func set_orders(order_views: Array) -> void:
	if _current.is_empty():
		return
	var traces: Array = []
	for o_val in order_views:
		if not o_val is Dictionary:
			continue
		traces.append(_order_trace(o_val as Dictionary))
	_current["orders"] = traces
	_current["summary"] = _compute_summary(traces, _current.get("attempts", []))
	_bump()


static func _order_trace(o: Dictionary) -> Dictionary:
	var cmd: Dictionary = o.get("order", {}) as Dictionary
	var action := str(cmd.get("action", "?")).strip_edges().to_upper()
	var v: Dictionary = o.get("validation", {}) as Dictionary
	var v_ok := bool(v.get("ok", false))
	var v_code := str(v.get("code", ""))
	var schema := {"ok": true, "code": ""}
	var semantic := {"ok": true, "code": ""}
	if not v_ok:
		if v_code in SCHEMA_CODES:
			schema = {"ok": false, "code": v_code}
			semantic = {"ok": null, "code": "-"} # not reached: schema failed first
		elif v_code in SEMANTIC_CODES:
			schema = {"ok": true, "code": ""}
			semantic = {"ok": false, "code": v_code}
		else:
			# Executor refusal / transport-level codes: both gates passed.
			schema = {"ok": true, "code": ""}
			semantic = {"ok": true, "code": ""}
	var status := str(o.get("status", "?"))
	var rejected := status == "REJECTED"
	var executed_rows: Array = (o.get("executed", []) as Array).duplicate(true)
	var failed_rows: Array = (o.get("failed", []) as Array).duplicate(true)
	var plan_failed: Array = (o.get("plan_failed", []) as Array).duplicate(true)
	var resolved: Array = (o.get("resolved_units", []) as Array).duplicate(true)
	var compiled_ok := (not rejected) and (not resolved.is_empty() or not plan_failed.is_empty() or not executed_rows.is_empty())
	if rejected and not v_ok:
		compiled_ok = false
	var executed_ok := not executed_rows.is_empty()
	return {
		"index": int(o.get("index", 0)),
		"action": action,
		"scope_text": _scope_text(cmd),
		"target_text": _target_text(cmd),
		"order": cmd.duplicate(true),
		"status": status,
		"schema": schema,
		"semantic": semantic,
		"validation": {"ok": v_ok, "code": v_code, "detail": str(v.get("detail", ""))},
		"resolved_units": resolved,
		"plan_failed": plan_failed,
		"executed": executed_rows,
		"failed": failed_rows,
		"pipeline": {
			"generated": true,
			"schema_ok": bool(schema.get("ok", false)) if schema.get("ok", null) != null else false,
			"semantic_ok": bool(semantic.get("ok", false)) if semantic.get("ok", null) != null else null,
			"compiled_ok": compiled_ok,
			"executed_ok": executed_ok,
		},
	}


static func _scope_text(cmd: Dictionary) -> String:
	var scope: Dictionary = cmd.get("scope", {}) as Dictionary
	if scope.has("op"):
		return "AST:" + str(scope.get("op", "?"))
	var kind := str(scope.get("kind", "?")).strip_edges().to_upper()
	match kind:
		"CLASS":
			return "CLASS " + str(scope.get("class", "?"))
		"REGION":
			return "REGION " + str(scope.get("region", "?"))
		"FORMATION":
			return "FORMATION " + str(scope.get("formation", "?"))
		"UNITS":
			return "UNITS(" + ",".join(scope.get("unit_ids", []) as Array) + ")"
		_:
			return kind


static func _target_text(cmd: Dictionary) -> String:
	var target: Dictionary = cmd.get("target", {}) as Dictionary
	var ttype := str(target.get("type", target.get("kind", ""))).strip_edges().to_upper()
	match ttype:
		"DIRECTION":
			return str(target.get("direction", "?"))
		"HEX":
			return "hex(%d,%d)" % [int(target.get("q", 0)), int(target.get("r", 0))]
		"FORMATION":
			return str(target.get("unit_id", target.get("value", "?")))
		"ZONE":
			return "ZONE " + str(target.get("zone", target.get("value", "?")))
		"OBJECTIVE":
			return "OBJECTIVE"
		_:
			return "-" if ttype.is_empty() else ttype


static func _compute_summary(traces: Array, attempts: Array) -> Dictionary:
	var generated := traces.size()
	var schema_passed := 0
	var semantic_passed := 0
	var compiled := 0
	var executed := 0
	var attack_generated := 0
	var attack_validated := 0
	var attack_compiled := 0
	var attack_executed := 0
	var executed_units := 0
	for t_val in traces:
		var t: Dictionary = t_val
		var pipe: Dictionary = t.get("pipeline", {}) as Dictionary
		if bool(pipe.get("schema_ok", false)):
			schema_passed += 1
		if bool(pipe.get("semantic_ok", false)):
			semantic_passed += 1
		if bool(pipe.get("compiled_ok", false)):
			compiled += 1
		if bool(pipe.get("executed_ok", false)):
			executed += 1
		var rows: Array = t.get("executed", []) as Array
		executed_units += rows.size()
		if str(t.get("action", "")) == "ATTACK":
			attack_generated += 1
			if bool(pipe.get("schema_ok", false)) and bool(pipe.get("semantic_ok", false)):
				attack_validated += 1
			if bool(pipe.get("compiled_ok", false)):
				attack_compiled += 1
			for r_val in rows:
				if str((r_val as Dictionary).get("action", "")) == "ATTACK":
					attack_executed += 1
	var retries := 0
	var inference_ms := 0
	var last_ok_latency := 0
	for a_val in attempts:
		var a: Dictionary = a_val
		if str(a.get("result", "")) == "IN_FLIGHT":
			continue
		inference_ms += int(a.get("latency_ms", 0))
		if not str(a.get("retry", "")).is_empty():
			retries += 1
		if bool(a.get("ok", false)):
			last_ok_latency = int(a.get("latency_ms", 0))
	return {
		"generated": generated,
		"schema_passed": schema_passed,
		"semantic_passed": semantic_passed,
		"compiled": compiled,
		"executed": executed,
		"executed_units": executed_units,
		"attack_generated": attack_generated,
		"attack_validated": attack_validated,
		"attack_compiled": attack_compiled,
		"attack_executed": attack_executed,
		"retries": retries,
		"inference_ms": inference_ms,
		"final_latency_ms": last_ok_latency,
	}


# --- end --------------------------------------------------------------------

static func end_turn(status: String, note: String = "") -> void:
	if _current.is_empty():
		return
	if str(_current.get("status", "")) != "RUNNING":
		return
	_current["status"] = status
	_current["note"] = note
	_current["ended_ms"] = Time.get_ticks_msec()
	if (_current.get("summary", {}) as Dictionary).is_empty():
		_current["summary"] = _compute_summary(_current.get("orders", []) as Array,
			_current.get("attempts", []) as Array)
	_push_history(_compact_summary(_current))
	if _persist:
		_persist_turn(_current)
	_bump()


static func _compact_summary(t: Dictionary) -> Dictionary:
	var s: Dictionary = t.get("summary", {}) as Dictionary
	return {
		"seq": int(t.get("seq", 0)),
		"turn": int(t.get("turn", 0)),
		"status": str(t.get("status", "?")),
		"latency_ms": int(s.get("final_latency_ms", 0)),
		"inference_ms": int(s.get("inference_ms", 0)),
		"retries": int(s.get("retries", 0)),
		"orders": int(s.get("generated", 0)),
		"executed": int(s.get("executed_units", 0)),
		"attack_generated": int(s.get("attack_generated", 0)),
		"attack_validated": int(s.get("attack_validated", 0)),
		"attack_executed": int(s.get("attack_executed", 0)),
		"model": str(t.get("model", "")),
		"ended_ms": int(t.get("ended_ms", 0)),
	}


# --- persistence (DEV evidence, secret-free) --------------------------------

static func set_persistence(enabled: bool) -> void:
	_persist = enabled
	_bump()


static func persistence_enabled() -> bool:
	return _persist


static func _persist_turn(t: Dictionary) -> void:
	if not LoggerCls.ensure_dir_recursive(LOG_DIR):
		return
	var clean: Dictionary = LoggerCls.scrub(_persistable(t))
	var stamp := Time.get_datetime_string_from_system(false).replace(":", "").replace("-", "").replace("T", "_")
	var path := "%s/cloud2_trace_t%03d_%s.json" % [LOG_DIR, int(t.get("turn", 0)), stamp]
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(clean, "  "))
	f.close()


## Persistable projection: strips the raw final model content and never
## contains reasoning text (it is never stored). Scrub() drops any key that
## looks like a credential, as a backstop.
static func _persistable(t: Dictionary) -> Dictionary:
	var attempts: Array = []
	for a_val in (t.get("attempts", []) as Array):
		var a: Dictionary = (a_val as Dictionary).duplicate(true)
		a.erase("request_id") # internal only
		attempts.append(a)
	var decision: Dictionary = (t.get("decision", {}) as Dictionary).duplicate(true)
	decision.erase("raw_final")
	var general: Dictionary = (t.get("general", {}) as Dictionary).duplicate(true)
	general.erase("request_id") # internal only, like attempts
	return {
		"kind": "cloud2_turn_trace",
		"trace_version": 1,
		"seq": int(t.get("seq", 0)),
		"timestamp_end": Time.get_datetime_string_from_system(),
		"turn": int(t.get("turn", 0)),
		"provider": str(t.get("provider", "")),
		"model": str(t.get("model", "")),
		"protocol": str(t.get("protocol", "")),
		"mode": str(t.get("mode", "")),
		"snapshot_id": str(t.get("snapshot_id", "")),
		"state_version": int(t.get("state_version", -1)),
		"request_chars": int(t.get("request_chars", 0)),
		"system_chars": int(t.get("system_chars", 0)),
		"status": str(t.get("status", "?")),
		"note": str(t.get("note", "")),
		"attempts": attempts,
		"decision_plan": decision.get("plan", {}),
		"decision_rationale": decision.get("rationale", {}),
		"general": general,
		"orders": t.get("orders", []),
		"summary": t.get("summary", {}),
		"duration_ms": maxi(0, int(t.get("ended_ms", 0)) - int(t.get("started_ms", 0))),
	}


# --- readers ----------------------------------------------------------------

static func revision() -> int:
	return _rev


static func snapshot_current() -> Dictionary:
	if _current.is_empty():
		return {"has_turn": false, "turn_record": {}, "history": history(), "rev": _rev}
	return {
		"has_turn": true,
		"turn_record": _current.duplicate(true),
		"history": history(),
		"rev": _rev,
	}


static func history() -> Array:
	var out: Array = []
	for h_val in _history:
		out.append((h_val as Dictionary).duplicate(true))
	return out


static func history_size() -> int:
	return _history.size()


static func history_cap() -> int:
	return MAX_TURNS


## Test/diagnostic hook: forget everything (never called by gameplay code).
static func clear() -> void:
	_current = {}
	_history = []
	_rev += 1


static func _push_history(entry: Dictionary) -> void:
	_history.append(entry)
	while _history.size() > MAX_TURNS:
		_history.pop_front()


static func _bump() -> void:
	_rev += 1


## Provider-reported token usage only (never estimated, never secret).
## Unknown/absent fields stay absent; non-numeric values are dropped.
static func _safe_usage(u_val: Variant) -> Dictionary:
	if not u_val is Dictionary:
		return {}
	var u: Dictionary = u_val
	var out := {}
	for key in ["prompt_tokens", "completion_tokens", "total_tokens",
			"input_tokens", "output_tokens"]:
		var v: Variant = u.get(key, null)
		if v is int or v is float:
			out[key] = int(v)
	var details: Variant = u.get("completion_tokens_details", u.get("output_tokens_details", null))
	if details is Dictionary:
		var rt: Variant = (details as Dictionary).get("reasoning_tokens", null)
		if rt is int or rt is float:
			out["reasoning_tokens"] = int(rt)
	return out
