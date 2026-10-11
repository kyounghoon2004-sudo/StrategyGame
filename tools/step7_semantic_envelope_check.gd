extends SceneTree

## Semantic envelope self-verification (NO LLM, NO scene): mode allow-list,
## COMMAND order requirements, non-COMMAND fabrication rejection, intent
## mapping, frontend handle_raw/full_pass fallback taxonomy.
## Usage: Godot --headless --path <proj> -s tools/step7_semantic_envelope_check.gd
## quit 0 = pass, 1 = fail. Evidence: tools/.audit_semantic_envelope.json

const OUT := "D:/Game development/Demon slayer/StrategyGame/tools/.audit_semantic_envelope.json"
const EnvelopeScript = preload("res://scripts/step7/step7_semantic_envelope.gd")
const FrontendScript = preload("res://scripts/step7/step7_semantic_frontend.gd")

var failures: Array = []
var passed := 0


func _init() -> void:
	call_deferred("_run")


func _check(cond: bool, label: String) -> void:
	if cond:
		passed += 1
	else:
		failures.append(label)
	print(("PASS " if cond else "FAIL ") + label)


func _cmd_order(action: String, stype: String, cls: String, region: String, ev: Array) -> Dictionary:
	return {"action": action,
		"scope": {"type": stype, "class": cls, "region": region, "unit_id": "", "regions": [], "classes": []},
		"scope_expr": {},
		"style": {"risk": "balanced", "pressure": "balanced", "depth": "normal"},
		"modifiers": {}, "source_evidence": ev, "confidence": 0.9}


func _run() -> void:
	# 1) Valid COMMAND envelope.
	var r: Dictionary = EnvelopeScript.from_tiny_output(
		{"mode": "COMMAND", "confidence": 0.9, "orders": [_cmd_order("ADVANCE", "WING_CLASS", "CAVALRY", "LEFT", ["좌익 기병 전진"])]},
		"좌익 기병 전진")
	_check(bool(r.get("ok", false)), "envelope.command ok (%s)" % str(r.get("why", "")))
	# 2) Bad mode rejected.
	var r2: Dictionary = EnvelopeScript.from_tiny_output({"mode": "ATTACK", "confidence": 0.9, "orders": []}, "x")
	_check(not bool(r2.get("ok", false)), "envelope.bad-mode rejected")
	# 3) COMMAND without orders rejected (fail closed).
	var r3: Dictionary = EnvelopeScript.from_tiny_output({"mode": "COMMAND", "confidence": 0.9, "orders": []}, "전진해")
	_check(not bool(r3.get("ok", false)), "envelope.command-no-orders rejected")
	# 4) Non-COMMAND with orders rejected (no fabricated orders).
	for m in ["INFORMATION", "TACTICAL_ADVICE", "CLARIFICATION", "CONVERSATION"]:
		var rx: Dictionary = EnvelopeScript.from_tiny_output(
			{"mode": m, "confidence": 0.9, "orders": [_cmd_order("ADVANCE", "WING_CLASS", "CAVALRY", "LEFT", ["x"])]}, "x")
		_check(not bool(rx.get("ok", false)), "envelope.%s-with-orders rejected" % m)
	# 5) Question modes accept empty orders.
	for m2 in ["INFORMATION", "TACTICAL_ADVICE", "CONVERSATION"]:
		var ry: Dictionary = EnvelopeScript.from_tiny_output(
			{"mode": m2, "confidence": 0.8, "orders": [], "question": "어디?"}, "어디?")
		_check(bool(ry.get("ok", false)), "envelope.%s empty-orders ok" % m2)
	# 6) Mode -> rtype map.
	_check(EnvelopeScript.to_rtype("TACTICAL_ADVICE") == "ADVICE", "map.tactical->advice")
	_check(EnvelopeScript.to_rtype("CONVERSATION") == "INFORMATION", "map.conversation->information")
	_check(EnvelopeScript.to_rtype("COMMAND") == "COMMAND", "map.command")
	# 7) to_intent preserves orders + relation + question.
	var env: Dictionary = r.get("envelope", {})
	var intent: Dictionary = EnvelopeScript.to_intent(env)
	_check(str(intent.get("request_type", "")) == "COMMAND", "intent.rtype")
	_check((intent.get("orders", []) as Array).size() == 1, "intent.orders")
	# 8) Frontend fallback taxonomy: garbage -> TINY_INVALID_JSON.
	var h: Dictionary = FrontendScript.handle_raw("이건 JSON이 아님", "이건 JSON이 아님")
	_check(not bool(h.get("ok", false)) and str(h.get("fallback_reason", "")) == "TINY_INVALID_JSON",
		"frontend.garbage -> TINY_INVALID_JSON")
	# 9) Valid JSON, bad schema -> TINY_INVALID_SCHEMA.
	var h2: Dictionary = FrontendScript.handle_raw("{\"mode\": \"COMMAND\", \"orders\": []}", "전진")
	_check(not bool(h2.get("ok", false)) and str(h2.get("fallback_reason", "")) == "TINY_INVALID_SCHEMA",
		"frontend.command-no-orders -> TINY_INVALID_SCHEMA")
	# 10) Low confidence -> TINY_LOW_CONFIDENCE (fail closed, never guess).
	var h3: Dictionary = FrontendScript.handle_raw(
		JSON.stringify({"mode": "COMMAND", "confidence": 0.1,
			"orders": [_cmd_order("HOLD", "WING_CLASS", "CAVALRY", "LEFT", ["좌익 기병 대기"])]}),
		"좌익 기병 대기")
	_check(not bool(h3.get("ok", false)) and str(h3.get("fallback_reason", "")) == "TINY_LOW_CONFIDENCE",
		"frontend.low-conf -> TINY_LOW_CONFIDENCE")
	# 11) Full valid tiny COMMAND normalizes end-to-end (envelope->intent->IR).
	var tiny_cmd := {"mode": "COMMAND", "confidence": 0.9,
		"orders": [_cmd_order("ADVANCE", "WING_CLASS", "SCOUT", "ALL", ["정찰병 전진"])]}
	var h4: Dictionary = FrontendScript.handle_raw(JSON.stringify(tiny_cmd), "정찰병 전진")
	_check(bool(h4.get("ok", false)), "frontend.valid-command ok (%s)" % str(h4.get("fallback_reason", h4.get("why", ""))))
	if bool(h4.get("ok", false)):
		var ir: Dictionary = h4.get("ir", {})
		_check(str(ir.get("kind", "")) == "COMMAND" and str(ir.get("relation", "")) == "SINGLE",
			"frontend.valid-command ir SINGLE")
		_check(str(ir.get("fingerprint", "")).begins_with("CIRv2:"), "frontend.valid-command fp")
	# 12) Confidence bounds enforced.
	var h5: Dictionary = FrontendScript.handle_raw("{\"mode\": \"INFORMATION\", \"confidence\": 9.0, \"orders\": []}", "어디?")
	_check(not bool(h5.get("ok", false)), "frontend.conf-out-of-range rejected")
	# 13) Unknown action rejected.
	var bad := _cmd_order("NUKE", "WING_CLASS", "CAVALRY", "LEFT", ["x"])
	var h6: Dictionary = FrontendScript.handle_raw(
		JSON.stringify({"mode": "COMMAND", "confidence": 0.9, "orders": [bad]}), "x")
	_check(not bool(h6.get("ok", false)), "frontend.unknown-action rejected")
	# 14) Non-COMMAND envelopes map to VALIDATABLE legacy intents (no
	# orders key — empty orders[] trips the legacy-keys branch).
	const IntentScript = preload("res://scripts/step7/step7_chat_intent.gd")
	for m3 in ["INFORMATION", "TACTICAL_ADVICE", "CONVERSATION"]:
		var er: Dictionary = EnvelopeScript.from_tiny_output(
			{"mode": m3, "confidence": 0.8, "orders": [], "question": "어디?"}, "어디?")
		var ii: Dictionary = EnvelopeScript.to_intent(er.get("envelope", {}))
		var vc: Dictionary = IntentScript.validate_intent(ii)
		_check(bool(vc.get("ok", false)), "envelope.%s to_intent validates (%s)" % [m3, str(vc.get("why", ""))])
	# 15) Tiny INFORMATION normalizes end-to-end via handle_raw.
	var h7: Dictionary = FrontendScript.handle_raw(
		JSON.stringify({"mode": "INFORMATION", "confidence": 0.85, "orders": [],
			"question": "현재 좌익 상황이 어때?"}), "현재 좌익 상황이 어때?")
	_check(bool(h7.get("ok", false)) and str((h7.get("ir", {}) as Dictionary).get("kind", "")) == "INFORMATION",
		"frontend.information ok (%s)" % str(h7.get("fallback_reason", h7.get("why", ""))))
	print("ENVELOPE_" + ("PASS" if failures.is_empty() else "FAIL") + " (%d/%d)" % [passed, passed + failures.size()])
	var f := FileAccess.open(OUT, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify({"passed": passed, "failures": failures}, "\t"))
		f.close()
	quit(0 if failures.is_empty() else 1)
