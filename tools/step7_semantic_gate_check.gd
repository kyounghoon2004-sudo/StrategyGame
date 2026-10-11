extends SceneTree

## Semantic gate self-verification (NO LLM, NO scene): PASS lanes,
## HARD_CONFLICT stop, SEQUENCE distinction, fail-closed taxonomy,
## empty-scope stop, evidence binding, frontend full_pass integration.
## Usage: Godot --headless --path <proj> -s tools/step7_semantic_gate_check.gd
## quit 0 = pass, 1 = fail. Evidence: tools/.audit_semantic_gate.json

const OUT := "D:/Game development/Demon slayer/StrategyGame/tools/.audit_semantic_gate.json"
const IntentScript = preload("res://scripts/step7/step7_chat_intent.gd")
const IRScript = preload("res://scripts/step7/step7_command_ir.gd")
const GateScript = preload("res://scripts/step7/step7_semantic_gate.gd")
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


func _unit(uid: String, cls: String) -> Dictionary:
	return {"id": uid, "faction": "blue", "class": cls, "soldier_count": 10,
		"q": 0, "r": 0, "garrisoned": false, "routed": false}


func _pool() -> Array:
	return [_unit("B_CAV_1", "CAVALRY"), _unit("B_CAV_2", "CAVALRY"),
		_unit("B_INF_1", "INFANTRY"), _unit("B_SCO_1", "SCOUT")]


func _deps() -> Dictionary:
	return {"pool": _pool(), "selected_unit": {}, "has_previous": false}


func _scope(cls: String) -> Dictionary:
	return {"type": "WING_CLASS", "class": cls, "region": "ALL",
		"unit_id": "", "regions": [], "classes": []}


func _style() -> Dictionary:
	return {"risk": "balanced", "pressure": "balanced", "depth": "normal"}


func _order(action: String, cls: String, expr: Dictionary, ev: Array) -> Dictionary:
	return {"action": action, "scope": _scope(cls), "scope_expr": expr,
		"style": _style(), "confidence": 0.9,
		"source_evidence": ev, "modifiers": {}}


func _ir(text: String, orders: Array, relation: String = "") -> Dictionary:
	var raw := {"request_type": "COMMAND", "orders": orders,
		"relation": relation, "confidence": 0.9, "question": "", "missing": []}
	var c: Dictionary = IntentScript.validate_intent(raw)
	if not bool(c.get("ok", false)):
		return {"ok": false, "why": "validate: " + str(c.get("why", "?"))}
	return IRScript.from_validated_intent(c.get("intent", {}), text)


func _run() -> void:
	# 1) Valid single COMMAND -> PASS / COMMAND_STAGE.
	var r1 := _ir("기병 전진", [_order("ADVANCE", "CAVALRY",
		{"op": "CLASS", "class": "CAVALRY"}, ["기병 전진"])])
	_check(bool(r1.get("ok", false)), "gate.ir1 builds (%s)" % str(r1.get("why", "")))
	var g1: Dictionary = GateScript.evaluate(r1.get("ir", {}), _deps())
	_check(str(g1.get("verdict", "")) == "PASS" and str(g1.get("lane", "")) == "COMMAND_STAGE",
		"gate.single-command PASS/STAGE")
	# 2) Contradiction: ADVANCE(CAV) + HOLD(CAV) PARALLEL -> HARD_CONFLICT STOP.
	var r2 := _ir("좌익은 전진하고 기병은 대기",
		[_order("ADVANCE", "CAVALRY", {"op": "CLASS", "class": "CAVALRY"}, ["좌익은 전진하고"]),
			_order("HOLD", "CAVALRY", {"op": "CLASS", "class": "CAVALRY"}, ["기병은 대기"])])
	_check(bool(r2.get("ok", false)), "gate.ir2 builds (%s)" % str(r2.get("why", "")))
	var g2: Dictionary = GateScript.evaluate(r2.get("ir", {}), _deps())
	_check(str(g2.get("verdict", "")) == "STOP" and str(g2.get("stop_kind", "")) == "HARD_CONFLICT",
		"gate.contradiction HARD_CONFLICT STOP")
	_check(not bool(g2.get("fallback_to_large", true)), "gate.conflict needs no large call")
	_check(not str(g2.get("clarification", "")).is_empty(), "gate.conflict asks clarification")
	# 3) Disjoint pair: ADVANCE(CAV) + HOLD(SCOUT) -> PASS (no conflict).
	var r3 := _ir("기병은 전진하고 정찰병은 대기",
		[_order("ADVANCE", "CAVALRY", {"op": "CLASS", "class": "CAVALRY"}, ["기병은 전진하고"]),
			_order("HOLD", "SCOUT", {"op": "CLASS", "class": "SCOUT"}, ["정찰병은 대기"])])
	var g3: Dictionary = GateScript.evaluate(r3.get("ir", {}), _deps())
	_check(str(g3.get("verdict", "")) == "PASS", "gate.disjoint-pair PASS")
	# 4) SEQUENCE preserved + held: 먼저/그다음 -> STOP SEQUENCE_UNSUPPORTED.
	var r4 := _ir("보병은 먼저 전진하고 그다음 대기",
		[_order("ADVANCE", "INFANTRY", {"op": "CLASS", "class": "INFANTRY"}, ["보병은 먼저 전진하고"]),
			_order("HOLD", "INFANTRY", {"op": "CLASS", "class": "INFANTRY"}, ["그다음 대기"])])
	_check(bool(r4.get("ok", false)) and str((r4.get("ir", {}) as Dictionary).get("relation", "")) == "SEQUENCE",
		"gate.sequence-relation preserved")
	var g4: Dictionary = GateScript.evaluate(r4.get("ir", {}), _deps())
	_check(str(g4.get("verdict", "")) == "STOP" and str(g4.get("stop_kind", "")) == "SEQUENCE_UNSUPPORTED",
		"gate.sequence STOP (not misfiled as conflict)")
	# 5) Same-action overlap (ADVANCE CAV + ADVANCE CAV-remainder) -> PASS.
	var r5 := _ir("기병 전진하고 나머지 기병도 전진",
		[_order("ADVANCE", "CAVALRY", {"op": "CLASS", "class": "CAVALRY"}, ["기병 전진하고"]),
			_order("ADVANCE", "CAVALRY", {"op": "CLASS", "class": "CAVALRY"}, ["나머지 기병도 전진"])])
	var g5: Dictionary = GateScript.evaluate(r5.get("ir", {}), _deps())
	_check(str(g5.get("verdict", "")) == "PASS", "gate.same-action-overlap PASS")
	# 6) INFORMATION (zero orders) -> PASS / QUESTION_LARGE, never staging.
	var raw6 := {"request_type": "INFORMATION", "action": "", "scope": _scope("CAVALRY"),
		"style": _style(), "confidence": 0.8, "question": "현재 좌익 상황이 어때?", "missing": []}
	var c6: Dictionary = IntentScript.validate_intent(raw6)
	var ir6: Dictionary = IRScript.from_validated_intent(c6.get("intent", {}), "현재 좌익 상황이 어때?")
	var g6: Dictionary = GateScript.evaluate(ir6.get("ir", {}), _deps())
	_check(str(g6.get("verdict", "")) == "PASS" and str(g6.get("lane", "")) == "QUESTION_LARGE",
		"gate.information -> QUESTION_LARGE")
	# 7) Unbound evidence -> STOP UNBOUND_EVIDENCE + large fallback.
	var r7 := _ir("기병 전진", [_order("ADVANCE", "CAVALRY",
		{"op": "CLASS", "class": "CAVALRY"}, ["전혀 다른 문장"])])
	var g7: Dictionary = GateScript.evaluate(r7.get("ir", {}), _deps())
	_check(str(g7.get("verdict", "")) == "STOP" and str(g7.get("stop_kind", "")) == "UNBOUND_EVIDENCE"
		and bool(g7.get("fallback_to_large", false)), "gate.unbound-evidence fallback")
	# 8) Empty scope (SIEGE absent) -> STOP EMPTY_SCOPE, no mutation path.
	var r8 := _ir("공성대 전진", [_order("ADVANCE", "SIEGE",
		{"op": "CLASS", "class": "SIEGE"}, ["공성대 전진"])])
	var g8: Dictionary = GateScript.evaluate(r8.get("ir", {}), _deps())
	_check(str(g8.get("verdict", "")) == "STOP" and str(g8.get("stop_kind", "")) == "EMPTY_SCOPE",
		"gate.empty-scope STOP")
	# 9) Structurally invalid IR -> STOP INVALID_IR + fallback.
	var g9: Dictionary = GateScript.evaluate({"version": 99, "kind": "COMMAND"}, _deps())
	_check(str(g9.get("verdict", "")) == "STOP" and str(g9.get("stop_kind", "")) == "INVALID_IR"
		and bool(g9.get("fallback_to_large", false)), "gate.invalid-ir fallback")
	# 10) full_pass integration: garbage -> TINY_INVALID_JSON fallback.
	var f10: Dictionary = FrontendScript.full_pass("말이 안 되는 출력 {", "기병 전진", _deps())
	_check(not bool(f10.get("ok", false)) and str(f10.get("fallback_reason", "")) == "TINY_INVALID_JSON",
		"gate.fullpass garbage fallback")
	# 11) full_pass integration: valid tiny COMMAND -> ok + PASS gate.
	var tiny := {"mode": "COMMAND", "confidence": 0.9,
		"orders": [_order("HOLD", "CAVALRY", {"op": "CLASS", "class": "CAVALRY"}, ["기병 대기"])]}
	var f11: Dictionary = FrontendScript.full_pass(JSON.stringify(tiny), "기병 대기", _deps())
	_check(bool(f11.get("ok", false)), "gate.fullpass valid ok (%s)" % str(f11.get("fallback_reason", f11.get("why", ""))))
	if bool(f11.get("ok", false)):
		_check(str((f11.get("gate", {}) as Dictionary).get("verdict", "")) == "PASS",
			"gate.fullpass valid PASS")
	# 12) full_pass: tiny contradiction -> ok:true with STOP gate (no large).
	var tiny2 := {"mode": "COMMAND", "confidence": 0.9,
		"orders": [_order("ADVANCE", "CAVALRY", {"op": "CLASS", "class": "CAVALRY"}, ["좌익은 전진하고"]),
			_order("HOLD", "CAVALRY", {"op": "CLASS", "class": "CAVALRY"}, ["기병은 대기"])]}
	var f12: Dictionary = FrontendScript.full_pass(JSON.stringify(tiny2), "좌익은 전진하고 기병은 대기", _deps())
	_check(bool(f12.get("ok", false))
		and str((f12.get("gate", {}) as Dictionary).get("stop_kind", "")) == "HARD_CONFLICT",
		"gate.fullpass contradiction STOP-without-large")
	print("GATE_" + ("PASS" if failures.is_empty() else "FAIL") + " (%d/%d)" % [passed, passed + failures.size()])
	var f := FileAccess.open(OUT, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify({"passed": passed, "failures": failures}, "\t"))
		f.close()
	quit(0 if failures.is_empty() else 1)
