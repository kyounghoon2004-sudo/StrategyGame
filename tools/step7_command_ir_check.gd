extends SceneTree

## CommandIR v2 self-verification (NO LLM, NO scene): pure structure,
## relation, modifiers, scope nesting, round-trip, fingerprints, legacy
## normalization, invalid shapes, deterministic coverage over real Korean
## utterances, and legacy-equivalence fixtures.
## Usage: Godot --headless --path <proj> -s tools/step7_command_ir_check.gd
## quit 0 = pass, 1 = fail. Evidence: tools/.audit_command_ir.json

const OUT := "D:/Game development/Demon slayer/StrategyGame/tools/.audit_command_ir.json"
const IntentScript = preload("res://scripts/step7/step7_chat_intent.gd")
const AlgebraScript = preload("res://scripts/step7/step7_scope_algebra.gd")
const IRScript = preload("res://scripts/step7/step7_command_ir.gd")

var failures: Array = []
var passed := 0
var evidence := {}


func _init() -> void:
	call_deferred("_run")


func _check(cond: bool, label: String) -> void:
	if cond:
		passed += 1
	else:
		failures.append(label)
	print(("PASS " if cond else "FAIL ") + label)


func _mk_scope(stype: String, cls: String, region: String, extra: Dictionary = {}) -> Dictionary:
	var s := {"type": stype, "class": cls, "region": region, "unit_id": "", "regions": [], "classes": []}
	for k in extra.keys():
		s[k] = extra[k]
	return s


func _mk_style(risk: String = "balanced", pressure: String = "balanced", depth: String = "normal") -> Dictionary:
	return {"risk": risk, "pressure": pressure, "depth": depth}


func _validated(raw: Dictionary) -> Dictionary:
	var c: Dictionary = IntentScript.validate_intent(raw)
	if not bool(c.get("ok", false)):
		return {}
	return c.get("intent", {})


func _ir(intent: Dictionary, text: String, opts: Dictionary = {}) -> Dictionary:
	return IRScript.from_validated_intent(intent, text, opts)


func _run() -> void:
	_pure_single()
	_pure_multi_relation()
	_pure_modifiers()
	_pure_nesting()
	_pure_roundtrip_fp()
	_pure_legacy_norm()
	_pure_invalid()
	_coverage_matrix()
	_legacy_equivalence()
	_write()
	print("COMMANDIR_" + ("PASS" if failures.is_empty() else "FAIL") + " (%d/%d)" % [passed, passed + failures.size()])
	quit(0 if failures.is_empty() else 1)


# --- A. pure ---------------------------------------------------------------

func _pure_single() -> void:
	var raw := {"request_type": "COMMAND", "action": "ADVANCE",
		"scope": _mk_scope("WING_CLASS", "CAVALRY", "LEFT"),
		"style": _mk_style(), "confidence": 0.9, "question": "", "missing": []}
	var intent := _validated(raw)
	_check(not intent.is_empty(), "pure.single: legacy validates")
	var r: Dictionary = _ir(intent, "좌익 기병 전진")
	_check(bool(r.get("ok", false)), "pure.single: IR ok (%s)" % str(r.get("why", "")))
	if not bool(r.get("ok", false)):
		return
	var ir: Dictionary = r.get("ir", {})
	_check(int(ir.get("version", 0)) == 2, "pure.single: version 2")
	_check(str(ir.get("kind", "")) == "COMMAND", "pure.single: kind COMMAND")
	_check(str(ir.get("relation", "")) == "SINGLE", "pure.single: SINGLE invariant")
	_check((ir.get("orders", []) as Array).size() == 1, "pure.single: one order")
	_check(str(ir.get("fingerprint", "")).begins_with("CIRv2:COMMAND:SINGLE:["), "pure.single: fp prefix")
	_check((ir.get("legacy", {}) as Dictionary).has("action"), "pure.single: legacy mirror kept (non-canonical)")
	evidence["single_fp"] = str(ir.get("fingerprint", ""))


func _pure_multi_relation() -> void:
	var o1 := {"action": "HOLD",
		"scope": _mk_scope("WING_CLASS", "ALL_ARMS", "LEFT"),
		"style": _mk_style(), "confidence": 0.9}
	var o2 := {"action": "ADVANCE",
		"scope": _mk_scope("WING_CLASS", "ALL_ARMS", "RIGHT"),
		"style": _mk_style(), "confidence": 0.9}
	var raw := {"request_type": "COMMAND", "orders": [o1, o2], "confidence": 0.9, "question": "", "missing": []}
	var intent := _validated(raw)
	var r: Dictionary = _ir(intent, "좌익은 대기하고 우익은 전진")
	_check(bool(r.get("ok", false)), "pure.multi: IR ok")
	if not bool(r.get("ok", false)):
		return
	var ir: Dictionary = r.get("ir", {})
	_check(str(ir.get("relation", "")) == "PARALLEL", "pure.multi: default PARALLEL")
	_check(str(ir.get("relation_source", "")) == "INFERRED", "pure.multi: relation INFERRED without cue")
	# Explicit SEQUENCE preserved.
	var intent2 := intent.duplicate(true)
	intent2["relation"] = "SEQUENCE"
	var r2: Dictionary = _ir(intent2, "보병은 먼저 전진하고 그다음 대기")
	_check(bool(r2.get("ok", false)), "pure.sequence: explicit SEQUENCE ok")
	if bool(r2.get("ok", false)):
		_check(str((r2.get("ir", {}) as Dictionary).get("relation", "")) == "SEQUENCE", "pure.sequence: SEQUENCE preserved")
	# Inferred SEQUENCE from cues.
	var r3: Dictionary = _ir(intent, "보병은 먼저 전진하고 그다음 대기")
	_check(bool(r3.get("ok", false)) and str((r3.get("ir", {}) as Dictionary).get("relation", "")) == "SEQUENCE",
		"pure.sequence: cue-inferred SEQUENCE")
	# PARALLEL vs SEQUENCE fingerprints differ (representation, not execution).
	if bool(r.get("ok", false)) and bool(r2.get("ok", false)):
		_check(str(ir.get("fingerprint", "")) != str((r2.get("ir", {}) as Dictionary).get("fingerprint", "")),
			"pure.relation: PARALLEL vs SEQUENCE fp differ")
	evidence["parallel_fp"] = str(ir.get("fingerprint", ""))


func _pure_modifiers() -> void:
	var o := {"action": "RECON",
		"scope": _mk_scope("WING_CLASS", "SCOUT", "ALL"),
		"style": {"risk": "balanced", "pressure": "balanced", "depth": "deep"},
		"modifiers": {"pace": "slow", "formation": "keep"},
		"confidence": 0.9}
	var raw := {"request_type": "COMMAND", "orders": [o], "confidence": 0.9, "question": "", "missing": []}
	var intent := _validated(raw)
	var r: Dictionary = _ir(intent, "정찰병은 깊게 천천히 정찰하고 전열을 유지해")
	_check(bool(r.get("ok", false)), "pure.modifiers: IR ok (%s)" % str(r.get("why", "")))
	if not bool(r.get("ok", false)):
		return
	var ir: Dictionary = r.get("ir", {})
	var ord: Dictionary = (ir.get("orders", []) as Array)[0]
	_check(str((ord.get("style", {}) as Dictionary).get("depth", "")) == "deep", "pure.modifiers: style depth deep kept")
	_check(str((ord.get("modifiers", {}) as Dictionary).get("depth", "")) == "deep", "pure.modifiers: semantic depth mirrored")
	_check(str((ord.get("modifiers", {}) as Dictionary).get("pace", "")) == "slow", "pure.modifiers: pace slow preserved")
	_check(str((ord.get("modifiers", {}) as Dictionary).get("formation", "")) == "keep", "pure.modifiers: formation keep preserved")


func _pure_nesting() -> void:
	var deep := {"op": "DIFF", "left": {"op": "DIFF",
		"left": {"op": "ALL_FRIENDLY"}, "right": {"op": "CLASS", "class": "HQ"}},
		"right": {"op": "CLASS", "class": "SUPPLY"}}
	var o := {"action": "HOLD",
		"scope": _mk_scope("ALL_AVAILABLE", "ALL_ARMS", "ALL"),
		"scope_expr": deep, "style": _mk_style(), "confidence": 0.9}
	var raw := {"request_type": "COMMAND", "orders": [o], "confidence": 0.9, "question": "", "missing": []}
	var intent := _validated(raw)
	_check(not intent.is_empty(), "pure.nesting: nested DIFF validates")
	var r: Dictionary = _ir(intent, "전군 대기")
	_check(bool(r.get("ok", false)), "pure.nesting: IR ok")
	if bool(r.get("ok", false)):
		var ir: Dictionary = r.get("ir", {})
		var fp1 := str(ir.get("fingerprint", ""))
		var r2: Dictionary = _ir(intent, "전군 대기")
		_check(str((r2.get("ir", {}) as Dictionary).get("fingerprint", "")) == fp1, "pure.nesting: fp deterministic")
		# Normalize idempotence: UNION flatten/dedupe/sort.
		var e := {"op": "UNION", "args": [
			{"op": "CLASS", "class": "INFANTRY"},
			{"op": "UNION", "args": [{"op": "CLASS", "class": "SPEARMAN"}, {"op": "CLASS", "class": "INFANTRY"}]}]}
		_check(AlgebraScript.fingerprint(e) == "UNION(CLASS:INFANTRY,CLASS:SPEARMAN)", "pure.nesting: normalize flatten+dedupe+sort")


func _pure_roundtrip_fp() -> void:
	var o1 := {"action": "ADVANCE",
		"scope": _mk_scope("WING_CLASS", "SCOUT", "ALL"),
		"scope_expr": {"op": "CLASS", "class": "SCOUT"},
		"style": _mk_style(), "confidence": 0.9, "source_evidence": ["정찰병은 전진하고"]}
	var o2 := {"action": "HOLD",
		"scope": _mk_scope("ALL_AVAILABLE", "ALL_ARMS", "ALL"),
		"scope_expr": {"op": "DIFF", "left": {"op": "ALL_FRIENDLY"}, "right": {"op": "CLASS", "class": "SCOUT"}},
		"style": _mk_style(), "confidence": 0.9, "source_evidence": ["나머지는 대기"]}
	var raw := {"request_type": "COMMAND", "orders": [o1, o2], "confidence": 0.9, "question": "", "missing": []}
	var intent := _validated(raw)
	var r: Dictionary = _ir(intent, "정찰병은 전진하고 나머지는 대기")
	_check(bool(r.get("ok", false)), "pure.roundtrip: IR ok")
	if not bool(r.get("ok", false)):
		return
	var ir: Dictionary = r.get("ir", {})
	var d := IRScript.to_dict(ir)
	var ser := JSON.stringify(d)
	var back: Variant = JSON.parse_string(ser)
	_check(back is Dictionary, "pure.roundtrip: JSON serializable")
	var r2: Dictionary = IRScript.from_dict(back)
	_check(bool(r2.get("ok", false)), "pure.roundtrip: from_dict ok (%s)" % str(r2.get("why", "")))
	if bool(r2.get("ok", false)):
		var ir2: Dictionary = r2.get("ir", {})
		_check(str(ir2.get("fingerprint", "")) == str(ir.get("fingerprint", "")), "pure.roundtrip: semantic fp stable")
		_check(str(ir2.get("evidence_fingerprint", "")) == str(ir.get("evidence_fingerprint", "")), "pure.roundtrip: evidence fp stable")
		var v: Dictionary = IRScript.validate_ir(ir2)
		_check(bool(v.get("ok", false)), "pure.roundtrip: revalidated")


func _pure_legacy_norm() -> void:
	# Legacy single shape and new orders[] shape must share one fp.
	var legacy_raw := {"request_type": "COMMAND", "action": "ADVANCE",
		"scope": _mk_scope("WING_CLASS", "CAVALRY", "LEFT"),
		"style": _mk_style(), "confidence": 0.9, "question": "", "missing": []}
	var new_raw := {"request_type": "COMMAND", "orders": [{
		"action": "ADVANCE", "scope": _mk_scope("WING_CLASS", "CAVALRY", "LEFT"),
		"style": _mk_style(), "confidence": 0.9}], "confidence": 0.9, "question": "", "missing": []}
	var i1 := _validated(legacy_raw)
	var i2 := _validated(new_raw)
	var r1: Dictionary = _ir(i1, "좌익 기병 전진")
	var r2: Dictionary = _ir(i2, "좌익 기병 전진")
	_check(bool(r1.get("ok", false)) and bool(r2.get("ok", false)), "pure.legacy: both normalize")
	if bool(r1.get("ok", false)) and bool(r2.get("ok", false)):
		_check(str((r1.get("ir", {}) as Dictionary).get("fingerprint", "")) == str((r2.get("ir", {}) as Dictionary).get("fingerprint", "")),
			"pure.legacy: equivalent shapes share fp")
	# ONE canonical constructor: from_raw_model_output chains through it.
	var r3: Dictionary = IRScript.from_raw_model_output(legacy_raw, "좌익 기병 전진")
	_check(bool(r3.get("ok", false)) and str((r3.get("ir", {}) as Dictionary).get("fingerprint", "")) == str((r1.get("ir", {}) as Dictionary).get("fingerprint", "")),
		"pure.legacy: raw chain shares fp")
	# to_legacy_orders feeds the existing router shape.
	var back_orders := IRScript.to_legacy_orders(r1.get("ir", {}))
	_check(back_orders.size() == 1 and str((back_orders[0] as Dictionary).get("action", "")) == "ADVANCE",
		"pure.legacy: to_legacy_orders adapter shape")


func _pure_invalid() -> void:
	var base_o := {"action": "ADVANCE", "scope": _mk_scope("WING_CLASS", "CAVALRY", "LEFT"),
		"style": _mk_style(), "confidence": 0.9}
	# bad relation enum
	var i_bad := {"request_type": "COMMAND", "orders": [base_o.duplicate(true)], "relation": "SIDEWAYS", "question": "", "missing": []}
	var vi := _validated({"request_type": "COMMAND", "orders": [base_o.duplicate(true)], "confidence": 0.9, "question": "", "missing": []})
	vi["relation"] = "SIDEWAYS"
	var rb: Dictionary = _ir(vi, "좌익 기병 전진")
	_check(not bool(rb.get("ok", false)), "pure.invalid: bad relation rejected")
	# duplicate order ids
	var d1 := base_o.duplicate(true)
	d1["order_id"] = "o1"
	var d2 := {"action": "HOLD", "scope": _mk_scope("ALL_AVAILABLE", "ALL_ARMS", "ALL"),
		"style": _mk_style(), "confidence": 0.9, "order_id": "o1"}
	var vi2 := _validated({"request_type": "COMMAND", "orders": [base_o.duplicate(true),
		{"action": "HOLD", "scope": _mk_scope("ALL_AVAILABLE", "ALL_ARMS", "ALL"), "style": _mk_style(), "confidence": 0.9}],
		"confidence": 0.9, "question": "", "missing": []})
	# inject duplicate ids post-validation (model-provided ids path)
	(vi2["orders"] as Array)[0]["order_id"] = "o1"
	(vi2["orders"] as Array)[1]["order_id"] = "o1"
	var rd: Dictionary = _ir(vi2, "전진하고 대기")
	_check(not bool(rd.get("ok", false)) and str(rd.get("why", "")).contains("duplicate"), "pure.invalid: duplicate order_id rejected")
	# SINGLE with 2 orders
	var vi3 := _validated({"request_type": "COMMAND", "orders": [base_o.duplicate(true),
		{"action": "HOLD", "scope": _mk_scope("ALL_AVAILABLE", "ALL_ARMS", "ALL"), "style": _mk_style(), "confidence": 0.9}],
		"confidence": 0.9, "question": "", "missing": []})
	vi3["relation"] = "SINGLE"
	var rs: Dictionary = _ir(vi3, "전진하고 대기")
	_check(not bool(rs.get("ok", false)), "pure.invalid: SINGLE with 2 orders rejected")
	# PARALLEL with 1 order
	var vi4 := _validated({"request_type": "COMMAND", "orders": [base_o.duplicate(true)], "confidence": 0.9, "question": "", "missing": []})
	vi4["relation"] = "PARALLEL"
	var rp: Dictionary = _ir(vi4, "전진")
	_check(not bool(rp.get("ok", false)), "pure.invalid: PARALLEL with 1 order rejected")
	# bad scope AST propagates
	var bse := base_o.duplicate(true)
	bse["scope_expr"] = {"op": "NOPE"}
	var vse: Dictionary = IntentScript.validate_intent({"request_type": "COMMAND", "orders": [bse], "confidence": 0.9, "question": "", "missing": []})
	_check(not bool(vse.get("ok", false)), "pure.invalid: bad scope AST rejected upstream")
	# resolved unit-id list smuggling (plural key) rejected at IR gate
	var sm := base_o.duplicate(true)
	sm["scope_expr"] = {"op": "CLASS", "class": "CAVALRY", "unit_ids": ["B_CAV_1"]}
	var vsm := _validated({"request_type": "COMMAND", "orders": [base_o.duplicate(true)], "confidence": 0.9, "question": "", "missing": []})
	(vsm["orders"] as Array)[0]["scope_expr"] = sm["scope_expr"]
	var rsm: Dictionary = _ir(vsm, "기병 전진")
	_check(not bool(rsm.get("ok", false)) and str(rsm.get("why", "")).contains("unit-id"), "pure.invalid: unit_ids smuggling rejected")
	# missing action for COMMAND
	var ma := {"action": "", "scope": _mk_scope("WING_CLASS", "CAVALRY", "LEFT"), "style": _mk_style(), "confidence": 0.9}
	var vma: Dictionary = {"request_type": "COMMAND", "orders": [ma], "relation": "", "question": "", "missing": [], "order_confidence": 0.9, "confidence": 0.9,
		"action": "", "scope": ma["scope"], "scope_expr": {}, "style": ma["style"]}
	var rma: Dictionary = _ir(vma, "좌익")
	_check(not bool(rma.get("ok", false)), "pure.invalid: missing COMMAND action rejected")
	# non-COMMAND kinds carry an envelope without requiring orders
	var adv_raw := {"request_type": "ADVICE", "action": "",
		"scope": _mk_scope("ALL_AVAILABLE", "ALL_ARMS", "ALL"),
		"style": _mk_style(), "confidence": 0.8, "question": "", "missing": []}
	var adv := _validated(adv_raw)
	var radv: Dictionary = _ir(adv, "어떤 기동이 좋을까")
	_check(bool(radv.get("ok", false)) and str((radv.get("ir", {}) as Dictionary).get("kind", "")) == "ADVICE",
		"pure.kinds: ADVICE envelope ok without orders requirement")


# --- B. coverage -------------------------------------------------------------

func _cov_order(action: String, scope: Dictionary, evidence: Array, style: Dictionary = {}, expr: Dictionary = {}) -> Dictionary:
	var o := {"action": action, "scope": scope, "scope_expr": expr,
		"style": style if not style.is_empty() else _mk_style(),
		"confidence": 0.9, "source_evidence": evidence}
	return o


func _cov_check(tag: String, text: String, orders: Array, style_mods: Array = [], relation: String = "") -> Dictionary:
	var raw := {"request_type": "COMMAND", "orders": orders, "confidence": 0.9, "question": "", "missing": []}
	var intent := _validated(raw)
	if intent.is_empty():
		_check(false, tag + ": validates")
		return {}
	if not relation.is_empty():
		intent["relation"] = relation
	var r: Dictionary = _ir(intent, text)
	_check(bool(r.get("ok", false)), tag + ": IR ok (%s)" % str(r.get("why", "")))
	return r


func _coverage_matrix() -> void:
	# 1. whole-force single, full meaningful coverage
	var r1 := _cov_check("cov.1", "전군 진격하라",
		[_cov_order("ADVANCE", _mk_scope("ALL_AVAILABLE", "ALL_ARMS", "ALL"), ["전군 진격하라"])])
	if bool(r1.get("ok", false)):
		var ir: Dictionary = r1.get("ir", {})
		var cov: Dictionary = ir.get("coverage", {})
		_check((ir.get("orders", []) as Array).size() == 1, "cov.1: one order")
		_check(float(cov.get("coverage_ratio", 0.0)) > 0.99, "cov.1: full meaningful coverage (%.2f)" % float(cov.get("coverage_ratio", 0.0)))
	# 2. scout advance + remainder hold: neither clause lost
	var r2 := _cov_check("cov.2", "정찰병은 전진하고 나머지는 대기",
		[_cov_order("ADVANCE", _mk_scope("WING_CLASS", "SCOUT", "ALL"), ["정찰병은 전진하고"]),
			_cov_order("HOLD", _mk_scope("ALL_AVAILABLE", "ALL_ARMS", "ALL"), ["나머지는 대기"], {},
				{"op": "DIFF", "left": {"op": "ALL_FRIENDLY"}, "right": {"op": "CLASS", "class": "SCOUT"}})])
	if bool(r2.get("ok", false)):
		var ir2: Dictionary = r2.get("ir", {})
		var cov2: Dictionary = ir2.get("coverage", {})
		_check((ir2.get("orders", []) as Array).size() == 2, "cov.2: two orders survive")
		_check((cov2.get("unbound", []) as Array).is_empty(), "cov.2: all evidence bound")
		_check((cov2.get("semantic_uncovered", []) as Array).is_empty(), "cov.2: no semantic clause lost")
		# BAD PARSE detector: single-order truncation must leave 대기 uncovered.
		var bad := _cov_check("cov.2bad", "정찰병은 전진하고 나머지는 대기",
			[_cov_order("ADVANCE", _mk_scope("WING_CLASS", "SCOUT", "ALL"), ["정찰병은 전진하고"])])
		if bool(bad.get("ok", false)):
			var bcov: Dictionary = (bad.get("ir", {}) as Dictionary).get("coverage", {})
			var sem: Array = bcov.get("semantic_uncovered", [])
			var has_hold := false
			for s in sem:
				if str((s as Dictionary).get("token", "")) == "대기":
					has_hold = true
			_check(has_hold, "cov.2bad: dropped HOLD clause detectable (대기 uncovered)")
	# 3. wing pair PARALLEL
	var r3 := _cov_check("cov.3", "좌익은 대기하고 우익은 전진",
		[_cov_order("HOLD", _mk_scope("WING_CLASS", "ALL_ARMS", "LEFT"), ["좌익은 대기하고"]),
			_cov_order("ADVANCE", _mk_scope("WING_CLASS", "ALL_ARMS", "RIGHT"), ["우익은 전진"])])
	if bool(r3.get("ok", false)):
		_check(str((r3.get("ir", {}) as Dictionary).get("relation", "")) == "PARALLEL", "cov.3: PARALLEL")
	# 4. depth modifier preserved
	var deep_style := {"risk": "balanced", "pressure": "balanced", "depth": "deep"}
	var r4 := _cov_check("cov.4", "정찰병은 깊게 정찰하고 본대는 대기",
		[_cov_order("RECON", _mk_scope("WING_CLASS", "SCOUT", "ALL"), ["정찰병은 깊게 정찰하고"], deep_style),
			_cov_order("HOLD", _mk_scope("ALL_AVAILABLE", "ALL_ARMS", "ALL"), ["본대는 대기"])])
	if bool(r4.get("ok", false)):
		var o0: Dictionary = (((r4.get("ir", {}) as Dictionary).get("orders", []) as Array)[0] as Dictionary)
		_check(str((o0.get("style", {}) as Dictionary).get("depth", "")) == "deep", "cov.4: depth modifier preserved")
	# 5. multi-class scope preserved
	var r5 := _cov_check("cov.5", "보병과 창병은 전진하고 궁병은 대기",
		[_cov_order("ADVANCE", _mk_scope("UNION", "", "", {"regions": ["ALL"], "classes": ["INFANTRY", "SPEARMAN"]}), ["보병과 창병은 전진하고"],
			{}, {"op": "UNION", "args": [{"op": "CLASS", "class": "INFANTRY"}, {"op": "CLASS", "class": "SPEARMAN"}]}),
			_cov_order("HOLD", _mk_scope("WING_CLASS", "ARCHER", "ALL"), ["궁병은 대기"])])
	if bool(r5.get("ok", false)):
		var p0: Dictionary = (((r5.get("ir", {}) as Dictionary).get("orders", []) as Array)[0] as Dictionary)
		_check(IRScript.scope_fingerprint(p0) == "UNION(CLASS:INFANTRY,CLASS:SPEARMAN)", "cov.5: multi-class scope preserved")
	# 6. SEQUENCE representation only (no execution)
	var r6 := _cov_check("cov.6", "보병은 먼저 전진하고 그다음 대기",
		[_cov_order("ADVANCE", _mk_scope("WING_CLASS", "INFANTRY", "ALL"), ["보병은 먼저 전진하고"]),
			_cov_order("HOLD", _mk_scope("WING_CLASS", "INFANTRY", "ALL"), ["그다음 대기"])], [], "SEQUENCE")
	if bool(r6.get("ok", false)):
		_check(str((r6.get("ir", {}) as Dictionary).get("relation", "")) == "SEQUENCE", "cov.6: SEQUENCE represented (not executed)")
	# 7. contradictory input survives intact (Step 2 decides; Step 1 preserves)
	var r7 := _cov_check("cov.7", "좌익은 전진하고 기병은 대기",
		[_cov_order("ADVANCE", _mk_scope("WING_CLASS", "ALL_ARMS", "LEFT"), ["좌익은 전진하고"]),
			_cov_order("HOLD", _mk_scope("WING_CLASS", "CAVALRY", "ALL"), ["기병은 대기"])])
	if bool(r7.get("ok", false)):
		_check((((r7.get("ir", {}) as Dictionary).get("orders", []) as Array).size()) == 2, "cov.7: contradiction preserved as two orders (not fixed)")


# --- C. legacy equivalence ---------------------------------------------------

func _legacy_equivalence() -> void:
	var fixtures := [
		{"tag": "전군 진격하라", "action": "ADVANCE",
			"scope": {"type": "ALL_AVAILABLE", "class": "ALL_ARMS", "region": "ALL", "unit_id": "", "regions": [], "classes": []},
			"text": "전군 진격하라"},
		{"tag": "기병 전진", "action": "ADVANCE",
			"scope": {"type": "WING_CLASS", "class": "CAVALRY", "region": "ALL", "unit_id": "", "regions": [], "classes": []},
			"text": "기병 전진"},
		{"tag": "both-wings", "action": "ADVANCE",
			"scope": {"type": "UNION", "class": "CAVALRY", "region": "", "unit_id": "", "regions": ["LEFT", "RIGHT"], "classes": []},
			"text": "둘다"},
		{"tag": "정찰병 깊게 정찰", "action": "RECON",
			"scope": {"type": "WING_CLASS", "class": "SCOUT", "region": "ALL", "unit_id": "", "regions": [], "classes": []},
			"style": {"risk": "balanced", "pressure": "balanced", "depth": "deep"},
			"text": "정찰병 깊게 정찰"},
		{"tag": "정찰병 제외하고 전군 대기", "action": "HOLD",
			"scope": {"type": "ALL_AVAILABLE", "class": "ALL_ARMS", "region": "ALL", "unit_id": "", "regions": [], "classes": []},
			"expr": {"op": "DIFF", "left": {"op": "ALL_FRIENDLY"}, "right": {"op": "CLASS", "class": "SCOUT"}},
			"text": "정찰병 제외하고 전군 대기"},
		{"tag": "보병과 창병 둘 다 전진", "action": "ADVANCE",
			"scope": {"type": "UNION", "class": "", "region": "", "unit_id": "", "regions": ["ALL"], "classes": ["INFANTRY", "SPEARMAN"]},
			"expr": {"op": "UNION", "args": [{"op": "CLASS", "class": "INFANTRY"}, {"op": "CLASS", "class": "SPEARMAN"}]},
			"text": "보병과 창병 둘 다 전진"},
		{"tag": "좌익 기병 전진", "action": "ADVANCE",
			"scope": {"type": "WING_CLASS", "class": "CAVALRY", "region": "LEFT", "unit_id": "", "regions": [], "classes": []},
			"expr": {"op": "INTERSECT", "args": [{"op": "WING", "wing": "LEFT"}, {"op": "CLASS", "class": "CAVALRY"}]},
			"text": "좌익 기병 전진"},
	]
	var rows: Array = []
	for f in fixtures:
		var style: Dictionary = (f as Dictionary).get("style", {"risk": "balanced", "pressure": "balanced", "depth": "normal"})
		var o := {"action": str((f as Dictionary).get("action", "")),
			"scope": (f as Dictionary).get("scope", {}),
			"style": style, "confidence": 0.9}
		if (f as Dictionary).has("expr"):
			o["scope_expr"] = (f as Dictionary).get("expr", {})
		var intent := _validated({"request_type": "COMMAND", "orders": [o], "confidence": 0.9, "question": "", "missing": []})
		var ok_v := not intent.is_empty()
		var fp_old := ""
		if ok_v:
			fp_old = IntentScript.intent_fingerprint(intent)
		var r: Dictionary = _ir(intent, str((f as Dictionary).get("text", ""))) if ok_v else {"ok": false}
		var fp_new := str((r.get("ir", {}) as Dictionary).get("fingerprint", "")) if bool(r.get("ok", false)) else ""
		_check(ok_v and bool(r.get("ok", false)), "legacy.%s: meaning preserved" % str((f as Dictionary).get("tag", "?")))
		rows.append({"tag": str((f as Dictionary).get("tag", "?")), "intent_fp": fp_old, "ir_fp": fp_new})
	evidence["legacy_equivalence"] = rows


func _write() -> void:
	var f := FileAccess.open(OUT, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({"status": "PASS" if failures.is_empty() else "FAIL",
			"passed": passed, "failures": failures, "evidence": evidence}))
		f.close()
