class_name Cloud2Response
extends RefCounted

## CLOUD-GENERAL STEP 2 — Model response contract + semantic gate.
##
## Parses the Cloud model's structured reply and validates every order
## against the SAME OperationalCommand schema the human console uses
## (Cloud1ActionTable.validate_command). The model is never trusted because
## its JSON parses: structure, side, snapshot, and references are all
## re-checked here, and scope membership + legality are re-checked again at
## compile time against live Godot state.
##
## Accepted shape:
##   {"plan": {"objective","intent","reconsider_if"},
##    "orders": [OperationalCommand, ...],
##    "rationale": {"objective","observations","risk","intent","reconsider_if"}}
## plan/rationale are advisory and optional; orders are required (1..8).
##
## Rejection codes: INVALID_JSON, INVALID_SCHEMA, EMPTY_ORDERS,
## TOO_MANY_ORDERS, plus the Table codes (UNKNOWN_ACTION, ACTION_DEFERRED,
## INVALID_SCOPE, INVALID_TARGET, INVALID_DIRECTION, INVALID_STANCE,
## INVALID_POLICY) and gate codes SELECTED_REJECTED, SIDE_MISMATCH,
## STALE_SNAPSHOT.

const TableCls = preload("res://scripts/cloud1/cloud1_action_table.gd")
const ScopeAlgebraCls = preload("res://scripts/step7/step7_scope_algebra.gd")

const MAX_ORDERS := 8
const MAX_TEXT := 500


## Canonical model output contract, built live from the same constants the
## parser enforces. The Context inspector renders THIS (never a copy), so
## the displayed schema cannot drift from validation.
static func response_schema() -> Dictionary:
	return {
		"shape": {"plan": "object (optional, advisory)", "orders": "array (required, 1..%d)" % MAX_ORDERS,
			"rationale": "object (optional, advisory)", "snapshot_id": "string (optional echo)"},
		"plan": {"objective": "string <= %d chars" % MAX_TEXT, "intent": "string <= %d chars" % MAX_TEXT,
			"reconsider_if": "string <= %d chars" % MAX_TEXT},
		"rationale": {"objective": "string", "observations": "string", "risk": "string",
			"intent": "string", "reconsider_if": "string (each clipped to %d chars)" % MAX_TEXT},
		"order": {
			"action": TableCls.ACTIONS.duplicate(),
			"executable_now": TableCls.EXECUTABLE.duplicate(),
			"deferred": TableCls.DEFERRED_ACTIONS.duplicate(),
			"scope_kind_form": TableCls.SCOPE_KINDS.duplicate(),
			"scope_ast_atoms": ["ALL_FRIENDLY", "ALL_COMBAT", "CLASS", "REGION", "FORMATION", "UNIT", "UNITS", "EMPTY"],
			"scope_ast_ops": ["UNION", "INTERSECT", "DIFF"],
			"scope_note": "SELECTED is rejected for Cloud orders; name explicit UNIT/UNITS ids.",
			"target_types": TableCls.TARGET_TYPES.duplicate(),
			"directions": TableCls.DIRECTIONS.duplicate(),
			"zones": TableCls.ZONES.duplicate(),
			"stances": TableCls.STANCES.duplicate(),
			"policies": TableCls.POLICIES.duplicate(),
		},
		"limits": {"min_orders": 1, "max_orders": MAX_ORDERS, "text_clip": MAX_TEXT},
		"extra_fields": "STRIP: validation keeps action/scope/target/stance only; anything else is dropped, never acted on.",
		"rejection_codes": ["INVALID_JSON", "INVALID_SCHEMA", "EMPTY_ORDERS", "TOO_MANY_ORDERS",
			"UNKNOWN_ACTION", "ACTION_DEFERRED", "INVALID_SCOPE", "INVALID_TARGET",
			"INVALID_DIRECTION", "INVALID_STANCE", "INVALID_POLICY",
			"SELECTED_REJECTED", "SIDE_MISMATCH", "STALE_SNAPSHOT"],
	}


static func default_plan() -> Dictionary:
	return {"objective": "", "intent": "", "reconsider_if": ""}


static func default_rationale() -> Dictionary:
	return {"objective": "", "observations": "", "risk": "", "intent": "", "reconsider_if": ""}


static func _clip(v: Variant) -> String:
	var s := str(v)
	if s.length() > MAX_TEXT:
		return s.left(MAX_TEXT)
	return s


## Extract a JSON object from raw model text. Accepts a bare object or a
## ```json fenced block. Returns {} when nothing parses as an object.
static func extract_json(text: String) -> Dictionary:
	var t := text.strip_edges()
	if t.is_empty():
		return {}
	var direct: Variant = JSON.parse_string(t)
	if direct is Dictionary:
		return direct
	var fence := t.find("```")
	if fence != -1:
		var open_end := t.find("\n", fence)
		var close := t.find("```", maxi(open_end, fence + 3))
		if open_end != -1 and close != -1 and close > open_end:
			var inner: Variant = JSON.parse_string(t.substr(open_end + 1, close - open_end - 1).strip_edges())
			if inner is Dictionary:
				return inner
	var first := t.find("{")
	var last := t.rfind("}")
	if first != -1 and last != -1 and last > first:
		var span: Variant = JSON.parse_string(t.substr(first, last - first + 1))
		if span is Dictionary:
			return span
	return {}


## Parse + structurally validate a full model reply.
## ctx: {"acting_side": "RED", "snapshot_id": "", "state_version": -1}.
## snapshot/state matching applies only when the model echoes them.
static func parse(text: String, ctx: Dictionary = {}) -> Dictionary:
	var side := str(ctx.get("acting_side", "RED")).strip_edges().to_upper()
	if side.is_empty():
		side = "RED"
	if text.strip_edges().is_empty():
		return _fail("INVALID_JSON", "Model returned an empty response.", side)
	var doc := extract_json(text)
	if doc.is_empty():
		return _fail("INVALID_JSON", "Model response is not a JSON object.", side)
	if not doc.has("orders") or not doc.get("orders") is Array:
		return _fail("INVALID_SCHEMA", "Response needs an 'orders' array.", side)
	var orders: Array = doc.get("orders")
	if orders.is_empty():
		return _fail("EMPTY_ORDERS", "Response carries no orders.", side)
	if orders.size() > MAX_ORDERS:
		return _fail("TOO_MANY_ORDERS", "Response carries %d orders (max %d)." % [orders.size(), MAX_ORDERS], side)
	var plan := default_plan()
	if doc.get("plan") is Dictionary:
		var praw: Dictionary = doc.get("plan")
		plan = {
			"objective": _clip(praw.get("objective", "")),
			"intent": _clip(praw.get("intent", "")),
			"reconsider_if": _clip(praw.get("reconsider_if", "")),
		}
	var rationale := default_rationale()
	if doc.get("rationale") is Dictionary:
		var rraw: Dictionary = doc.get("rationale")
		rationale = {
			"objective": _clip(rraw.get("objective", "")),
			"observations": _clip(rraw.get("observations", "")),
			"risk": _clip(rraw.get("risk", "")),
			"intent": _clip(rraw.get("intent", "")),
			"reconsider_if": _clip(rraw.get("reconsider_if", "")),
		}
	var checked: Array = []
	var all_ok := true
	for o_val in orders:
		var one := check_order(o_val, ctx)
		checked.append(one)
		if not bool(one.get("ok", false)):
			all_ok = false
	# Snapshot echo check (model-advisory; mismatch = stale, not trusted).
	var echo := str(doc.get("snapshot_id", doc.get("snapshot", ""))).strip_edges()
	var want := str(ctx.get("snapshot_id", "")).strip_edges()
	var stale := false
	if not echo.is_empty() and not want.is_empty() and echo != want:
		stale = true
	return {
		"ok": all_ok and not stale,
		"code": "" if (all_ok and not stale) else ("STALE_SNAPSHOT" if stale else "ORDER_REJECTED"),
		"detail": "" if (all_ok and not stale) else ("Snapshot echo '%s' does not match '%s'." % [echo, want] if stale else "One or more orders failed validation."),
		"acting_side": side,
		"stale_snapshot": stale,
		"plan": plan,
		"rationale": rationale,
		"orders": checked,
		"order_count": checked.size(),
	}


static func _fail(code: String, detail: String, side: String) -> Dictionary:
	return {"ok": false, "code": code, "detail": detail, "acting_side": side,
		"stale_snapshot": false, "plan": default_plan(),
		"rationale": default_rationale(), "orders": [], "order_count": 0}


## Validate ONE order: shared Table schema first, then the semantic gate.
## Returns {ok, code, detail, order} where order is the canonical command.
static func check_order(order_val: Variant, ctx: Dictionary = {}) -> Dictionary:
	var side := str(ctx.get("acting_side", "RED")).strip_edges().to_upper()
	if side.is_empty():
		side = "RED"
	if not order_val is Dictionary:
		return {"ok": false, "code": "INVALID_SCHEMA", "detail": "Order must be an object.", "order": {}}
	var order: Dictionary = (order_val as Dictionary).duplicate(true)
	var structural := TableCls.validate_command(order)
	if not bool(structural.get("ok", false)):
		return {"ok": false, "code": str(structural.get("code", "INVALID_COMMAND")),
			"detail": str(structural.get("detail", "Rejected.")), "order": order}
	var gate := semantic_check(order, side)
	if not bool(gate.get("ok", false)):
		return {"ok": false, "code": str(gate.get("code", "SEMANTIC_REJECT")),
			"detail": str(gate.get("detail", "Rejected.")), "order": order}
	return {"ok": true, "code": "", "detail": "", "order": _canonicalize(order)}


## Semantic gate: side ownership of explicit unit pointers, SELECTED ban
## (a human map pointer the Cloud does not have), snapshot echo.
static func semantic_check(order: Dictionary, side: String) -> Dictionary:
	var s := side.strip_edges().to_upper()
	var echo_side := str(order.get("acting_side", order.get("side", ""))).strip_edges().to_upper()
	if not echo_side.is_empty() and echo_side != s:
		return {"ok": false, "code": "SIDE_MISMATCH",
			"detail": "Order side '%s' does not match acting side '%s'." % [echo_side, s]}
	var scope: Dictionary = order.get("scope", {})
	var sel := _contains_selected(scope)
	if sel:
		return {"ok": false, "code": "SELECTED_REJECTED",
			"detail": "SELECTED is a human map pointer; Cloud orders must name explicit UNIT/UNITS ids."}
	var prefix := "R_" if s == "RED" else "B_"
	var foe := "B_" if s == "RED" else "R_"
	var bad := _foreign_unit_ids(scope, foe)
	if not bad.is_empty():
		return {"ok": false, "code": "SIDE_MISMATCH",
			"detail": "Scope names enemy-side units %s for acting side %s." % [str(bad), s]}
	var own_target := _formation_target_side(order)
	if not own_target.is_empty() and own_target != foe and str(order.get("action", "")).strip_edges().to_upper() == "ATTACK":
		return {"ok": false, "code": "SIDE_MISMATCH",
			"detail": "ATTACK must target an enemy FORMATION unit."}
	if prefix.is_empty():
		return {"ok": false, "code": "SEMANTIC_REJECT", "detail": "Unreachable."}
	return {"ok": true, "code": "", "detail": ""}


## Canonicalize validated orders to the shared shape (same keys the human
## builder emits): uppercase action/scope/target atoms, stance default.
static func _canonicalize(order: Dictionary) -> Dictionary:
	var action := str(order.get("action", "")).strip_edges().to_upper()
	var scope: Dictionary = (order.get("scope", {}) as Dictionary).duplicate(true)
	var target: Dictionary = (order.get("target", {}) as Dictionary).duplicate(true)
	var stance := str(order.get("stance", "BALANCED")).strip_edges().to_upper()
	if stance.is_empty():
		stance = "BALANCED"
	return TableCls.make_command(action, scope, target, stance)


static func _contains_selected(scope: Dictionary) -> bool:
	if scope.is_empty():
		return false
	if scope.has("op"):
		var v: Dictionary = ScopeAlgebraCls.validate_expr(scope)
		if not bool(v.get("ok", false)):
			return false
		return _ast_has_selected(scope)
	return str(scope.get("kind", "")).strip_edges().to_upper() == "SELECTED"


static func _ast_has_selected(e: Dictionary) -> bool:
	var op := str(e.get("op", "")).strip_edges().to_upper()
	if op == "SELECTED":
		return true
	if op == "UNION" or op == "INTERSECT":
		for a in (e.get("args", []) as Array):
			if a is Dictionary and _ast_has_selected(a):
				return true
	if op == "DIFF":
		if (e.get("left") is Dictionary and _ast_has_selected(e.get("left"))) or (e.get("right") is Dictionary and _ast_has_selected(e.get("right"))):
			return true
	return false


static func _foreign_unit_ids(scope: Dictionary, foe_prefix: String) -> Array:
	var out: Array = []
	_collect_unit_ids(scope, out)
	var bad: Array = []
	for uid in out:
		if str(uid).strip_edges().to_upper().begins_with(foe_prefix):
			bad.append(str(uid))
	bad.sort()
	return bad


static func _collect_unit_ids(scope: Dictionary, out: Array) -> void:
	if scope.is_empty():
		return
	if scope.has("op"):
		_ast_unit_ids(scope, out)
		return
	if str(scope.get("kind", "")).strip_edges().to_upper() == "UNITS":
		var ids: Variant = scope.get("unit_ids", scope.get("units", scope.get("value", [])))
		if ids is Array:
			for x in (ids as Array):
				out.append(str(x))


static func _ast_unit_ids(e: Dictionary, out: Array) -> void:
	var op := str(e.get("op", "")).strip_edges().to_upper()
	if op == "UNIT":
		out.append(str(e.get("unit_id", "")))
	elif op == "UNITS":
		for x in (e.get("unit_ids", []) as Array):
			out.append(str(x))
	elif op == "UNION" or op == "INTERSECT":
		for a in (e.get("args", []) as Array):
			if a is Dictionary:
				_ast_unit_ids(a, out)
	elif op == "DIFF":
		if e.get("left") is Dictionary:
			_ast_unit_ids(e.get("left"), out)
		if e.get("right") is Dictionary:
			_ast_unit_ids(e.get("right"), out)


static func _formation_target_side(order: Dictionary) -> String:
	var target: Dictionary = order.get("target", {})
	var ttype := str(target.get("type", target.get("kind", ""))).strip_edges().to_upper()
	if ttype != "FORMATION":
		return ""
	var uid := str(target.get("unit_id", target.get("value", ""))).strip_edges().to_upper()
	if uid.begins_with("B_"):
		return "B_"
	if uid.begins_with("R_"):
		return "R_"
	return "?"


## Compact human/audit rendering of a parsed reply (no secrets involved).
static func render_summary(parsed: Dictionary) -> String:
	var lines: Array = []
	lines.append("CLOUD RESPONSE side=%s ok=%s code=%s orders=%d" % [
		str(parsed.get("acting_side", "?")), str(bool(parsed.get("ok", false))),
		str(parsed.get("code", "-")), int(parsed.get("order_count", 0))])
	var plan: Dictionary = parsed.get("plan", {})
	lines.append("plan objective=%s" % str(plan.get("objective", "-")))
	lines.append("plan intent=%s" % str(plan.get("intent", "-")))
	var i := 0
	for o_val in (parsed.get("orders", []) as Array):
		i += 1
		var o: Dictionary = o_val
		if bool(o.get("ok", false)):
			var cmd: Dictionary = o.get("order", {})
			lines.append("order %d OK action=%s scope=%s target=%s" % [i,
				str(cmd.get("action", "?")), JSON.stringify(cmd.get("scope", {})),
				JSON.stringify(cmd.get("target", {}))])
		else:
			lines.append("order %d REJECT %s: %s" % [i, str(o.get("code", "?")), str(o.get("detail", ""))])
	if bool(parsed.get("stale_snapshot", false)):
		lines.append("STALE_SNAPSHOT: model echo does not match the frozen snapshot.")
	return "\n".join(lines)
