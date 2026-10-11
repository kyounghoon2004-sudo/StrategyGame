class_name Step7SemanticEnvelope
extends RefCounted

## ONE strict semantic envelope for the tiny frontend.
##
## Tiny model output (JSON) -> from_tiny_output() -> envelope ->
## to_intent() -> existing Step7ChatIntent.validate_intent() ->
## existing Step7CommandIR.from_validated_intent().
##
## Modes: COMMAND | INFORMATION | TACTICAL_ADVICE | CLARIFICATION |
## CONVERSATION. Internal routing map: TACTICAL_ADVICE -> ADVICE,
## CONVERSATION -> INFORMATION (+conversation flag; answered by the large
## model from dialogue state, never staged).
##
## COMMAND envelopes MUST carry orders[] (else the frontend failed — fail
## closed, never stage). Non-COMMAND envelopes MUST NOT carry orders
## (fabricated orders are rejected, never executed).

const IntentScript = preload("res://scripts/step7/step7_chat_intent.gd")

const MODES := ["COMMAND", "INFORMATION", "TACTICAL_ADVICE", "CLARIFICATION", "CONVERSATION"]

## Envelope -> legacy request_type for the EXISTING pipeline.
const MODE_TO_RTYPE := {
	"COMMAND": "COMMAND",
	"INFORMATION": "INFORMATION",
	"TACTICAL_ADVICE": "ADVICE",
	"CLARIFICATION": "CLARIFICATION",
	"CONVERSATION": "INFORMATION",
}

const MAX_ORDERS := 4
const MAX_FIELD_CHARS := 600


static func _fail(why: String) -> Dictionary:
	return {"ok": false, "why": why}


## Validate one raw tiny-model JSON object into a canonical envelope.
## parsed: JSON object from the frontend call. original_text: authoritative
## player utterance (stored, never trusted from the model).
static func from_tiny_output(parsed: Dictionary, original_text: String) -> Dictionary:
	if not parsed is Dictionary:
		return _fail("envelope must be an object")
	var mode := str(parsed.get("mode", "")).strip_edges().to_upper()
	if mode.is_empty():
		return _fail("envelope.mode missing")
	if not mode in MODES:
		return _fail("envelope.mode '%s' not in [%s]" % [str(parsed.get("mode", "")), ", ".join(MODES)])
	var conf := 0.0
	if parsed.has("confidence"):
		conf = float(parsed.get("confidence", -1.0))
		if conf < 0.0 or conf > 1.0:
			return _fail("envelope.confidence outside 0.0-1.0")
	var raw_orders: Variant = parsed.get("command_orders", parsed.get("orders", []))
	var orders: Array = []
	if raw_orders is Array:
		orders = (raw_orders as Array).duplicate()
	elif raw_orders != null and not (raw_orders is Array):
		return _fail("envelope.orders must be an array")
	if mode == "COMMAND" and orders.is_empty():
		return _fail("COMMAND envelope requires non-empty orders[]")
	if mode != "COMMAND" and not orders.is_empty():
		return _fail("%s envelope must not fabricate orders[]" % mode)
	if orders.size() > MAX_ORDERS:
		return _fail("too many orders (max %d)" % MAX_ORDERS)
	var norm_orders: Array = []
	for i in range(orders.size()):
		var o_val: Variant = orders[i]
		if not o_val is Dictionary:
			return _fail("orders[%d] must be an object" % i)
		var o: Dictionary = (o_val as Dictionary).duplicate(true)
		var action := IntentScript.normalize_action(str(o.get("action", "")))
		if action.is_empty():
			return _fail("orders[%d].action missing" % i)
		if not action in (IntentScript.ACTIONS as Array):
			return _fail("orders[%d].action '%s' is not canonical" % [i, str(o.get("action", ""))])
		o["action"] = action
		if not o.get("scope", {}) is Dictionary:
			return _fail("orders[%d].scope must be an object" % i)
		if o.has("scope_expr") and not o.get("scope_expr") is Dictionary:
			return _fail("orders[%d].scope_expr must be an object" % i)
		if not o.get("style", {"risk": "balanced"}) is Dictionary:
			return _fail("orders[%d].style must be an object" % i)
		var oc := 1.0
		if o.has("confidence"):
			oc = float(o.get("confidence", -1.0))
			if oc < 0.0 or oc > 1.0:
				return _fail("orders[%d].confidence outside 0.0-1.0" % i)
		o["confidence"] = oc
		var ev: Array = []
		var ev_raw: Variant = o.get("source_evidence", o.get("evidence", []))
		if ev_raw is String:
			var t := (ev_raw as String).strip_edges()
			if not t.is_empty():
				ev = [t.left(MAX_FIELD_CHARS)]
		elif ev_raw is Array:
			for q in (ev_raw as Array):
				var qs := str(q).strip_edges()
				if qs.is_empty():
					continue
				if not qs in ev:
					ev.append(qs.left(MAX_FIELD_CHARS))
				if ev.size() >= 4:
					break
		o["source_evidence"] = ev
		if not o.get("modifiers", {}) is Dictionary:
			o["modifiers"] = {}
		var oid := str(o.get("order_id", "")).strip_edges()
		o["order_id"] = oid if not oid.is_empty() else ("o%d" % (i + 1))
		if not o.get("scope_expr", {}) is Dictionary:
			o["scope_expr"] = {}
		if not o.get("style", {}) is Dictionary:
			o["style"] = {}
		norm_orders.append(o)
	var question := str(parsed.get("question", "")).left(MAX_FIELD_CHARS)
	var reference := {}
	if parsed.get("reference", {}) is Dictionary:
		reference = (parsed.get("reference", {}) as Dictionary).duplicate(true)
	var glob_ev: Array = []
	var gevol_raw: Variant = parsed.get("source_evidence", [])
	if gevol_raw is String:
		var gt := (gevol_raw as String).strip_edges()
		if not gt.is_empty():
			glob_ev = [gt.left(MAX_FIELD_CHARS)]
	elif gevol_raw is Array:
		for q2 in (gevol_raw as Array):
			var q2s := str(q2).strip_edges()
			if not q2s.is_empty() and not q2s in glob_ev:
				glob_ev.append(q2s.left(MAX_FIELD_CHARS))
	var relation := str(parsed.get("relation", "")).strip_edges().to_upper()
	var env := {"mode": mode, "confidence": conf,
		"orders": norm_orders, "relation": relation,
		"question": question, "reference": reference,
		"source_evidence": glob_ev, "original_text": original_text}
	var v := validate_envelope(env)
	if not bool(v.get("ok", false)):
		return v
	return {"ok": true, "envelope": env}


static func validate_envelope(env: Dictionary) -> Dictionary:
	if not env is Dictionary:
		return _fail("envelope must be an object")
	var mode := str(env.get("mode", "")).strip_edges().to_upper()
	if not mode in MODES:
		return _fail("envelope.mode invalid")
	var orders: Variant = env.get("orders", [])
	if not orders is Array:
		return _fail("envelope.orders must be an array")
	if mode == "COMMAND" and (orders as Array).is_empty():
		return _fail("COMMAND envelope requires non-empty orders[]")
	if mode != "COMMAND" and not (orders as Array).is_empty():
		return _fail("%s envelope must not carry orders[]" % mode)
	return {"ok": true}


static func to_rtype(mode: String) -> String:
	return str(MODE_TO_RTYPE.get(mode.strip_edges().to_upper(), "INFORMATION"))


## Envelope -> validated-intent-shaped dict for the EXISTING pipeline.
## COMMAND envelopes carry orders[]. Non-COMMAND envelopes use the legacy
## single shape (no orders key: top-level action/scope/style mirrors),
## exactly like the existing Phase-1 INFORMATION/ADVICE outputs — an
## empty orders[] array would trip the legacy-required-keys branch of
## validate_intent ("missing key 'action'").
static func to_intent(env: Dictionary) -> Dictionary:
	var mode := str(env.get("mode", "")).strip_edges().to_upper()
	var rtype := to_rtype(mode)
	var conf := float(env.get("confidence", 1.0))
	var question := str(env.get("question", ""))
	if question.is_empty() and mode != "COMMAND":
		question = str(env.get("original_text", ""))
	var reference := {}
	if (env.get("reference", {}) as Dictionary) is Dictionary:
		reference = (env.get("reference", {}) as Dictionary).duplicate(true)
	if (env.get("orders", []) as Array).is_empty():
		# Neutral whole-force mirror (validates; carries no semantics —
		# the question text is the payload, the large model answers).
		var intent := {"request_type": rtype, "action": "",
			"scope": {"type": "ALL_AVAILABLE", "class": "ALL_ARMS", "region": "ALL",
				"unit_id": "", "regions": [], "classes": []},
			"style": {"risk": "balanced", "pressure": "balanced", "depth": "normal"},
			"confidence": conf, "question": question, "missing": []}
		if mode == "CONVERSATION":
			intent["conversation"] = true
		if not reference.is_empty():
			intent["reference"] = reference
		return intent
	var orders: Array = []
	for o_val in (env.get("orders", []) as Array):
		var o: Dictionary = (o_val as Dictionary).duplicate(true)
		orders.append({
			"action": str(o.get("action", "")),
			"scope": (o.get("scope", {}) as Dictionary).duplicate(true),
			"scope_expr": (o.get("scope_expr", {}) as Dictionary).duplicate(true),
			"style": (o.get("style", {"risk": "balanced", "pressure": "balanced", "depth": "normal"}) as Dictionary).duplicate(true),
			"confidence": float(o.get("confidence", 1.0)),
			"source_evidence": (o.get("source_evidence", []) as Array).duplicate(),
			"modifiers": (o.get("modifiers", {}) as Dictionary).duplicate(true),
			"order_id": str(o.get("order_id", "")),
		})
	var intent2 := {"request_type": rtype, "orders": orders,
		"relation": str(env.get("relation", "")),
		"question": question, "missing": [],
		"confidence": conf,
		"order_confidence": conf}
	if not reference.is_empty():
		intent2["reference"] = reference
	return intent2


static func describe(env: Dictionary) -> String:
	return "Envelope %s conf=%.2f orders=%d q=%s" % [
		str(env.get("mode", "?")), float(env.get("confidence", 0.0)),
		(env.get("orders", []) as Array).size(),
		"yes" if not str(env.get("question", "")).is_empty() else "no"]
