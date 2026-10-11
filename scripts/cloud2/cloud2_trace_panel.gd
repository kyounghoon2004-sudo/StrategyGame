class_name Cloud2TracePanel
extends VBoxContainer

## CLOUD-GENERAL STEP 2 — TRACE tab (Issue 1: Cloud turn observability).
##
## One scrolling diagnostic surface inside the existing floating Cloud
## General Lab. Sections, top to bottom:
##   LIVE STATUS   — pipeline stage (OBSERVING ... COMPLETE) + live elapsed
##   THINKING      — latest attempt telemetry: budget, elapsed, HTTP, reasoning
##                   presence/chars, provider-reported usage tokens, finish
##                   reason, retry reason. Char counts are labeled "chars";
##                   usage tokens are shown ONLY when the provider reported
##                   them (never estimated).
##   ATTEMPTS      — bounded per-turn attempt history (attempt 1 survives the
##                   retry; both remain inspectable)
##   DECISION      — the model's FINAL tactical decision (PLAN / RATIONALE /
##                   ORDERS) exactly as parsed, plus a DEV expandable raw
##                   final-content field (NOT reasoning_content)
##   ORDERS        — per-order GENERATED -> SCHEMA -> SEMANTIC -> COMPILED ->
##                   EXECUTED chain with resolved units and per-unit outcomes
##   SUMMARY       — turn counters incl. the OBSERVATION-ONLY ATTACK counters
##   HISTORY       — bounded compact summaries of recent Cloud turns
##
## Presentation only: zero tactical semantics. reasoning_content is never
## displayed or stored; no API secret can appear (the store carries none).

const TraceCls = preload("res://scripts/cloud2/cloud2_turn_trace.gd")
const ResponseCls = preload("res://scripts/cloud2/cloud2_response.gd")

const STAGE_ORDER := ["OBSERVING", "BUILDING REQUEST", "WAITING FOR MODEL",
	"THINKING", "RETRYING", "RESPONSE RECEIVED", "VALIDATING", "EXECUTING",
	"COMPLETE"]

const COL_SECTION := Color(0.5, 0.83, 1.0)
const COL_TEXT := Color(0.85, 0.88, 0.92)
const COL_DIM := Color(0.62, 0.66, 0.7)
const COL_OK := Color(0.55, 0.9, 0.6)
const COL_WARN := Color(0.95, 0.8, 0.4)
const COL_FAIL := Color(1.0, 0.5, 0.45)
const COL_RAW := Color(0.72, 0.78, 0.6)

var _status_lbl: Label = null
var _thinking_lbl: Label = null
var _attempts_lbl: Label = null
var _general_lbl: Label = null
var _decision_lbl: Label = null
var _raw_btn: Button = null
var _raw_view: TextEdit = null
var _raw_open := false
var _orders_lbl: Label = null
var _summary_lbl: Label = null
var _history_lbl: Label = null
var _raw_toggle_hint: Label = null


func _init() -> void:
	add_theme_constant_override("separation", 4)


func _ready() -> void:
	_build()
	_refresh()


# --- construction -----------------------------------------------------------

func _build() -> void:
	var scroll := ScrollContainer.new()
	scroll.name = "TraceScroll"
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 6)
	scroll.add_child(box)

	_status_lbl = _label(box, 13)
	_section(box, "LIVE STATUS")
	box.move_child(_status_lbl, box.get_child_count() - 1)

	_section(box, "THINKING TELEMETRY (latest attempt)")
	_thinking_lbl = _label(box, 12)

	_section(box, "ATTEMPT HISTORY (this turn)")
	_attempts_lbl = _label(box, 12)

	_section(box, "GENERAL PLANNING (strategic plan pipeline)")
	_general_lbl = _label(box, 12)

	_section(box, "DECISION TRACE (final model output)")
	_decision_lbl = _label(box, 12)
	var raw_row := HBoxContainer.new()
	raw_row.add_theme_constant_override("separation", 6)
	box.add_child(raw_row)
	_raw_btn = Button.new()
	_raw_btn.text = "DEV: FINAL MODEL CONTENT"
	_raw_btn.toggle_mode = true
	_raw_btn.tooltip_text = "Show the actual final model response passed to Cloud2Response.parse. This is the tactical final text — NOT reasoning_content."
	_raw_btn.add_theme_font_size_override("font_size", 11)
	_raw_btn.pressed.connect(_on_raw_toggled)
	raw_row.add_child(_raw_btn)
	_raw_toggle_hint = Label.new()
	_raw_toggle_hint.text = ""
	_raw_toggle_hint.add_theme_font_size_override("font_size", 10)
	_raw_toggle_hint.add_theme_color_override("font_color", COL_DIM)
	raw_row.add_child(_raw_toggle_hint)
	_raw_view = TextEdit.new()
	_raw_view.editable = false
	_raw_view.visible = false
	_raw_view.custom_minimum_size = Vector2(0, 180)
	_raw_view.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_raw_view.add_theme_font_size_override("font_size", 11)
	var mono := SystemFont.new()
	mono.font_names = PackedStringArray(["Consolas", "Menlo", "monospace"])
	_raw_view.add_theme_font_override("font", mono)
	box.add_child(_raw_view)

	_section(box, "ORDERS — GENERATED -> VALIDATED -> COMPILED -> EXECUTED")
	_orders_lbl = _label(box, 12)

	_section(box, "TURN SUMMARY")
	_summary_lbl = _label(box, 12)

	_section(box, "RECENT CLOUD TURNS (bounded)")
	_history_lbl = _label(box, 12)


func _section(parent: Control, text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 12)
	l.add_theme_color_override("font_color", COL_SECTION)
	parent.add_child(l)
	return l


func _label(parent: Control, size: int) -> Label:
	var l := Label.new()
	l.text = ""
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", COL_TEXT)
	var mono := SystemFont.new()
	mono.font_names = PackedStringArray(["Consolas", "Menlo", "monospace"])
	l.add_theme_font_override("font", mono)
	parent.add_child(l)
	return l


func _on_raw_toggled() -> void:
	_raw_open = _raw_btn.button_pressed
	_raw_view.visible = _raw_open
	_refresh()


# --- refresh ----------------------------------------------------------------

func _process(_delta: float) -> void:
	_refresh()


func _refresh() -> void:
	var snap: Dictionary = TraceCls.snapshot_current()
	var rec: Dictionary = snap.get("turn_record", {}) as Dictionary
	var has := bool(snap.get("has_turn", false))
	_render_status(rec, has)
	_render_thinking(rec, has)
	_render_attempts(rec, has)
	_render_general(rec, has)
	_render_decision(rec, has)
	_render_orders(rec, has)
	_render_summary(rec, has)
	_render_history(snap.get("history", []) as Array)


func _render_status(rec: Dictionary, has: bool) -> void:
	if _status_lbl == null:
		return
	if not has:
		_status_lbl.text = "No Cloud turn yet. Play BLUE, END TURN — the Cloud RED turn reports here."
		_status_lbl.add_theme_color_override("font_color", COL_DIM)
		return
	var stage := str(rec.get("stage", ""))
	var note := str(rec.get("stage_note", ""))
	var running := str(rec.get("status", "")) == "RUNNING"
	var line := "%s  ·  turn %d  ·  %s" % [stage, int(rec.get("turn", 0)), str(rec.get("status", "?"))]
	# Live elapsed while a model flight is in the air (production latency view).
	if running:
		var inflight: Dictionary = TraceCls.in_flight_attempt()
		if not inflight.is_empty():
			var el := float(Time.get_ticks_msec() - int(inflight.get("started_ms", 0))) / 1000.0
			line += "  ·  THINKING... %.1f s" % el
	if not note.is_empty():
		line += "\n%s" % note
	_status_lbl.text = line
	_status_lbl.add_theme_color_override("font_color",
		COL_OK if str(rec.get("status", "")) in ["EXECUTED", "PARTIAL", "HOLD_ALL", "SKIPPED"]
		else (COL_FAIL if str(rec.get("status", "")).begins_with("FAILED") else COL_WARN))


func _render_thinking(rec: Dictionary, has: bool) -> void:
	if _thinking_lbl == null:
		return
	if not has:
		_thinking_lbl.text = "—"
		return
	var attempts: Array = rec.get("attempts", []) as Array
	var a := {}
	for i in range(attempts.size() - 1, -1, -1):
		var cand: Dictionary = attempts[i]
		if str(cand.get("result", "")) != "IN_FLIGHT":
			a = cand
			break
	if a.is_empty():
		_thinking_lbl.text = "no finished attempt yet"
		return
	var lines: Array = []
	lines.append("Model: %s   Protocol: %s   Turn: RED %d   Mode: %s" % [
		_str(rec.get("model", "?")), _str(rec.get("protocol", "?")),
		int(rec.get("turn", 0)), _str(rec.get("mode", "?"))])
	lines.append("Attempt: %s   Output budget: %s tokens   Request: %s chars   System prompt: %s chars" % [
		_attempt_label(a, attempts), _num(a.get("budget", 0)),
		_num(rec.get("request_chars", 0)), _num(rec.get("system_chars", 0))])
	var lat := int(a.get("latency_ms", 0))
	lines.append("Elapsed: %s   HTTP: %s   Mock: %s" % [
		_secs(lat), _num(a.get("http_status", 0)), "yes" if bool(a.get("mock", false)) else "no"])
	lines.append("Reasoning: %s   Reasoning chars: %s" % [
		"present" if bool(a.get("reasoning_present", false)) else "none",
		_num(a.get("reasoning_chars", 0))])
	# Provider-reported usage ONLY: separate from char counts, never estimated.
	var usage: Dictionary = a.get("usage", {}) as Dictionary
	if usage.is_empty():
		lines.append("Usage tokens: (provider did not report)")
	else:
		var parts: Array = []
		for k in usage.keys():
			parts.append("%s=%s" % [str(k), _num(usage.get(k, 0))])
		lines.append("Usage tokens (provider-reported): %s" % ", ".join(parts))
	var finish := str(a.get("finish_reason", ""))
	lines.append("Final content: %s chars (%s)   Finish reason: %s" % [
		_num(a.get("content_chars", 0)),
		_str(a.get("content_type", "-")) if not str(a.get("content_type", "")).is_empty() else "-",
		finish if not finish.is_empty() else "-"])
	if bool(a.get("ok", false)):
		lines.append("Result: SUCCESS")
	else:
		lines.append("Result: %s — %s" % [_str(a.get("code", "?")), _str(a.get("detail", ""))])
	var retry := str(a.get("retry", ""))
	lines.append("Retry: %s" % (retry if not retry.is_empty() else "no"))
	_thinking_lbl.text = "\n".join(lines)


func _attempt_label(a: Dictionary, attempts: Array) -> String:
	# Attempts after the first same-turn auto-retry carry r1/r2 suffixes in
	# their request ids; reflect that without inventing anything.
	var idx := int(a.get("index", 0))
	var rid := str(a.get("request_id", ""))
	if rid.contains("_r"):
		var tail := rid.substr(rid.find("_r") + 2)
		return "%d (retry r%s)" % [idx, tail]
	return str(idx)


func _render_attempts(rec: Dictionary, has: bool) -> void:
	if _attempts_lbl == null:
		return
	if not has:
		_attempts_lbl.text = "—"
		return
	var attempts: Array = rec.get("attempts", []) as Array
	if attempts.is_empty():
		_attempts_lbl.text = "—"
		return
	var lines: Array = []
	for a_val in attempts:
		var a: Dictionary = a_val
		if str(a.get("result", "")) == "IN_FLIGHT":
			var el := float(Time.get_ticks_msec() - int(a.get("started_ms", 0))) / 1000.0
			lines.append("ATTEMPT %s  %s tokens  in flight %.1fs" % [
				_attempt_label(a, attempts), _num(a.get("budget", 0)), el])
			continue
		var verdict := "SUCCESS" if bool(a.get("ok", false)) else str(a.get("result", "?"))
		var retry := str(a.get("retry", ""))
		lines.append("ATTEMPT %s  %s tokens  %s  reasoning %s chars  final %s chars  finish=%s  %s%s" % [
			_attempt_label(a, attempts), _num(a.get("budget", 0)), _secs(int(a.get("latency_ms", 0))),
			_num(a.get("reasoning_chars", 0)), _num(a.get("content_chars", 0)),
			str(a.get("finish_reason", "-")) if not str(a.get("finish_reason", "")).is_empty() else "-",
			verdict,
			("  " + retry) if not retry.is_empty() else ""])
	_attempts_lbl.text = "\n".join(lines)


func _render_general(rec: Dictionary, has: bool) -> void:
	if _general_lbl == null:
		return
	if not has:
		_general_lbl.text = "—"
		return
	var g: Dictionary = rec.get("general", {}) as Dictionary
	var stage := str(rec.get("stage", ""))
	if g.is_empty():
		if stage == "GENERAL_PLANNING":
			_general_lbl.text = "GENERAL REVIEW in flight — THINKING above shows transport; parse/adoption lands here."
		else:
			_general_lbl.text = "—"
		return
	var lines: Array = []
	lines.append("Attempt: %d   Outcome: %s" % [int(g.get("attempt", 0)), _str(g.get("outcome", "?"))])
	var code := str(g.get("code", ""))
	if not code.is_empty():
		lines.append("Code: %s — %s" % [code, _str(g.get("detail", ""))])
	lines.append("Response: %s chars   HTTP: %s   Finish: %s" % [
		_num(g.get("response_chars", 0)), _num(g.get("http_status", 0)),
		_str(g.get("finish_reason", "-")) if not str(g.get("finish_reason", "")).is_empty() else "-"])
	var pv := int(g.get("plan_version", 0))
	if pv > 0:
		lines.append("Plan: v%d   Missions: %d" % [pv, int(g.get("missions", 0))])
	lines.append("(exact General final text: MODEL VIEW — never copied here)")
	_general_lbl.text = "\n".join(lines)


func _render_decision(rec: Dictionary, has: bool) -> void:
	if _decision_lbl == null:
		return
	if not has:
		_decision_lbl.text = "—"
		_raw_toggle_hint.text = ""
		return
	var decision: Dictionary = rec.get("decision", {}) as Dictionary
	var plan: Dictionary = decision.get("plan", {}) as Dictionary
	var rationale: Dictionary = decision.get("rationale", {}) as Dictionary
	var orders: Array = rec.get("orders", []) as Array
	var lines: Array = []
	if plan.is_empty() and orders.is_empty():
		if str(rec.get("stage", "")) == "GENERAL_PLANNING":
			lines.append("(General planning in flight — strategic plan pending; see GENERAL above)")
		else:
			lines.append("(no final decision reached this turn)")
	elif plan.has("missions"):
		# HIERARCHY decision: the General's validated strategic plan (concept
		# + doctrine + missions). Mission controllers decide locally from it.
		var concept: Dictionary = plan.get("concept", {}) as Dictionary
		lines.append("GENERAL STRATEGIC PLAN v%s" % _num(plan.get("plan_version", 0)))
		lines.append("  Objective: %s" % (_str(concept.get("objective", "")) if not str(concept.get("objective", "")).is_empty() else "—"))
		lines.append("  Intent: %s" % (_str(concept.get("intent", "")) if not str(concept.get("intent", "")).is_empty() else "—"))
		lines.append("  Main effort: %s   Risk: %s" % [
			_str(concept.get("main_effort", "—")) if not str(concept.get("main_effort", "")).is_empty() else "—",
			_str(concept.get("risk_posture", "—")) if not str(concept.get("risk_posture", "")).is_empty() else "—"])
		var missions: Array = plan.get("missions", []) as Array
		lines.append("MISSIONS (%d)" % missions.size())
		for m_val in missions:
			var m: Dictionary = m_val
			var units: Array = m.get("assigned_units", []) as Array
			lines.append("  %s  %s  area=%s  units=%d" % [
				_str(m.get("mission_id", "?")), _str(m.get("task", "?")),
				_str(m.get("area", "?")), units.size()])
		lines.append("(orders are decided locally by mission controllers from this plan)")
	else:
		lines.append("PLAN")
		lines.append("  Objective: %s" % (_str(plan.get("objective", "")) if not str(plan.get("objective", "")).is_empty() else "—"))
		lines.append("  Intent: %s" % (_str(plan.get("intent", "")) if not str(plan.get("intent", "")).is_empty() else "—"))
		lines.append("  Reconsider if: %s" % (_str(plan.get("reconsider_if", "")) if not str(plan.get("reconsider_if", "")).is_empty() else "—"))
		var has_rat := false
		for k in rationale.keys():
			if not str(rationale.get(k, "")).is_empty():
				has_rat = true
				break
		if has_rat:
			lines.append("RATIONALE (final model text)")
			for k2 in ["objective", "observations", "risk", "intent", "reconsider_if"]:
				var v := str(rationale.get(k2, ""))
				if not v.is_empty():
					lines.append("  %s: %s" % [k2, v])
		if orders.is_empty():
			lines.append("ORDERS: none parsed")
		else:
			lines.append("ORDERS (%d)" % orders.size())
			for o_val in orders:
				var o: Dictionary = o_val
				lines.append("  #%d  ACTION: %s  SCOPE: %s  TARGET: %s" % [
					int(o.get("index", 0)), _str(o.get("action", "?")),
					_str(o.get("scope_text", "?")), _str(o.get("target_text", "-"))])
	_decision_lbl.text = "\n".join(lines)
	var raw := str(decision.get("raw_final", ""))
	if raw.is_empty():
		if str(rec.get("stage", "")) == "GENERAL_PLANNING":
			_raw_toggle_hint.text = "(General final text lives in MODEL VIEW)"
		else:
			_raw_toggle_hint.text = "(no final content)"
		_raw_view.text = ""
	else:
		_raw_toggle_hint.text = "(%d chars)" % raw.length()
		_raw_view.text = raw


func _render_orders(rec: Dictionary, has: bool) -> void:
	if _orders_lbl == null:
		return
	if not has:
		_orders_lbl.text = "—"
		return
	var orders: Array = rec.get("orders", []) as Array
	if orders.is_empty():
		if str(rec.get("stage", "")) == "GENERAL_PLANNING":
			_orders_lbl.text = "(no orders yet — mission controllers decide locally after plan adoption)"
		else:
			_orders_lbl.text = "(no orders yet this turn)"
		return
	var lines: Array = []
	for o_val in orders:
		var o: Dictionary = o_val
		var pipe: Dictionary = o.get("pipeline", {}) as Dictionary
		var schema: Dictionary = o.get("schema", {}) as Dictionary
		var semantic: Dictionary = o.get("semantic", {}) as Dictionary
		var head := "#%d %s  scope=%s  target=%s" % [
			int(o.get("index", 0)), _str(o.get("action", "?")),
			_str(o.get("scope_text", "?")), _str(o.get("target_text", "-"))]
		lines.append(head)
		# Chain: GENERATED (always) -> SCHEMA -> SEMANTIC -> COMPILED -> EXECUTED
		var chain := "GENERATED ✓"
		var s_ok: Variant = schema.get("ok", null)
		if s_ok == false:
			chain += "   SCHEMA ✗ %s" % str(schema.get("code", "?"))
			chain += "   SEMANTIC —"
			chain += "   COMPILED ✗"
			chain += "   EXECUTED ✗"
		else:
			chain += "   SCHEMA ✓"
			var sem_ok: Variant = semantic.get("ok", null)
			if sem_ok == false:
				chain += "   SEMANTIC ✗ %s" % str(semantic.get("code", "?"))
				chain += "   COMPILED ✗"
				chain += "   EXECUTED ✗"
			else:
				chain += "   SEMANTIC ✓"
				if bool(pipe.get("compiled_ok", false)):
					chain += "   COMPILED ✓"
					chain += ("   EXECUTED ✓" if bool(pipe.get("executed_ok", false)) else "   EXECUTED ✗")
				else:
					chain += "   COMPILED ✗"
					chain += "   EXECUTED ✗"
		lines.append("   " + chain)
		if not bool(o.get("validation", {}).get("ok", true)) and not str((o.get("validation", {}) as Dictionary).get("detail", "")).is_empty():
			lines.append("   reason: %s" % str((o.get("validation", {}) as Dictionary).get("detail", "")))
		var resolved: Array = o.get("resolved_units", []) as Array
		if not resolved.is_empty():
			lines.append("   resolved: %s" % ", ".join(resolved))
		# COMPILER TRACE: what Godot produced (destinations for MOVE rows).
		var exec_rows: Array = o.get("executed", []) as Array
		for e_val in exec_rows:
			var e: Dictionary = e_val
			var kind := str(e.get("action", "?"))
			if kind == "MOVE":
				var to: Array = e.get("to", []) as Array
				var frm: Array = e.get("from", []) as Array
				var dest := "hex(%s,%s)" % [str(to[0]) if to.size() == 2 else "?", str(to[1]) if to.size() == 2 else "?"]
				var orig := "hex(%s,%s)" % [str(frm[0]) if frm.size() == 2 else "?", str(frm[1]) if frm.size() == 2 else "?"]
				lines.append("   compiled: %s → %s (%s)" % [str(e.get("unit_id", "?")), dest, str(e.get("via_action", "MOVE"))])
				lines.append("   executed: %s  MOVE %s → %s  SUCCESS" % [str(e.get("unit_id", "?")), orig, dest])
			elif kind == "ATTACK":
				lines.append("   executed: %s  ATTACK target %s  SUCCESS" % [str(e.get("unit_id", "?")), str(e.get("target_unit_id", "?"))])
			elif kind == "HOLD":
				lines.append("   executed: %s  HOLD  SUCCESS" % str(e.get("unit_id", "?")))
			else:
				lines.append("   executed: %s  %s" % [str(e.get("unit_id", "?")), kind])
		for f_val in (o.get("failed", []) as Array):
			var f: Dictionary = f_val
			lines.append("   executed: %s  %s  BLOCKED  reason: %s" % [
				_str(f.get("unit_id", "?")), _str(f.get("action", "MOVE")), _str(f.get("code", "?"))])
		for p_val in (o.get("plan_failed", []) as Array):
			var p: Dictionary = p_val
			lines.append("   compile-reject: %s  %s — %s" % [
				_str(p.get("unit_id", "?")), _str(p.get("code", "?")), _str(p.get("detail", ""))])
	_orders_lbl.text = "\n".join(lines)


func _render_summary(rec: Dictionary, has: bool) -> void:
	if _summary_lbl == null:
		return
	if not has:
		_summary_lbl.text = "—"
		return
	var s: Dictionary = rec.get("summary", {}) as Dictionary
	if s.is_empty():
		_summary_lbl.text = "(turn in progress — summary builds as orders execute)"
		return
	var status := str(rec.get("status", "?"))
	var lines: Array = []
	lines.append("Status: %s   Inference: %s   Retries: %s" % [
		status, _secs(int(s.get("inference_ms", 0))), _num(s.get("retries", 0))])
	lines.append("Generated orders: %s   Schema passed: %s   Semantic passed: %s   Compiled: %s   Executed: %s (%s unit actions)" % [
		_num(s.get("generated", 0)), _num(s.get("schema_passed", 0)),
		_num(s.get("semantic_passed", 0)), _num(s.get("compiled", 0)),
		_num(s.get("executed", 0)), _num(s.get("executed_units", 0))])
	# OBSERVATION ONLY — these counters feed Issue 3 later; nothing here
	# changes AI incentives, prompt, or ATTACK rules.
	lines.append("ATTACK generated: %s   validated: %s   compiled: %s   executed: %s" % [
		_num(s.get("attack_generated", 0)), _num(s.get("attack_validated", 0)),
		_num(s.get("attack_compiled", 0)), _num(s.get("attack_executed", 0))])
	_summary_lbl.text = "\n".join(lines)


func _render_history(hist: Array) -> void:
	if _history_lbl == null:
		return
	if hist.is_empty():
		_history_lbl.text = "—"
		return
	var lines: Array = []
	for h_val in hist:
		var h: Dictionary = h_val
		var retry_bit := "retry " if int(h.get("retries", 0)) > 0 else ""
		lines.append("T%d  %s%s  %s  %s orders  exec %s  A:%s/%s/%s" % [
			int(h.get("turn", 0)), retry_bit, _secs(int(h.get("inference_ms", 0))),
			_str(h.get("status", "?")), _num(h.get("orders", 0)),
			_num(h.get("executed", 0)), _num(h.get("attack_generated", 0)),
			_num(h.get("attack_validated", 0)), _num(h.get("attack_executed", 0))])
	_history_lbl.text = "\n".join(lines)


static func _str(v: Variant) -> String:
	return str(v)


static func _num(v: Variant) -> String:
	var n := int(v)
	var s := str(n)
	var out := ""
	while s.length() > 3:
		out = "," + s.right(3) + out
		s = s.left(s.length() - 3)
	return s + out


static func _secs(ms: int) -> String:
	return "%.2f s" % (float(ms) / 1000.0)
