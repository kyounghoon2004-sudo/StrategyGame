extends SceneTree

## Validation edge battery (NO model): hand-written raws asserting the
## refactored validator preserves legacy outcomes exactly, plus orders[]
## contract behavior. quit 0 = pass.

const IntentScript = preload("res://scripts/step7/step7_chat_intent.gd")

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


func _v(raw: Dictionary) -> Dictionary:
	return IntentScript.validate_intent(raw)


func _base() -> Dictionary:
	return {"request_type": "COMMAND", "action": "ADVANCE",
		"scope": {"type": "WING_CLASS", "class": "CAVALRY", "region": "LEFT", "unit_id": ""},
		"style": {"risk": "balanced", "pressure": "balanced", "depth": "normal"},
		"confidence": 0.9, "question": "", "missing": []}


func _run() -> void:
	# Legacy outcomes (must be byte-identical to pre-refactor behavior).
	var ok1 := _v(_base())
	_check(bool(ok1.get("ok", false)), "legacy valid")
	var it1: Dictionary = ok1.get("intent", {})
	_check(str((it1.get("scope", {}) as Dictionary).get("region", "")) == "LEFT", "legacy region kept")
	_check((it1.get("orders", []) as Array).size() == 1, "legacy wraps to orders len-1")
	_check(str(((it1.get("orders", []) as Array)[0] as Dictionary).get("action", "")) == "ADVANCE", "legacy order mirrors action")
	var bad := _base()
	bad.erase("action")
	_check(not bool(_v(bad).get("ok", false)) and str(_v(bad).get("why", "")) == "missing key 'action'", "legacy missing key error")
	var bad2 := _base()
	bad2["action"] = "FLY"
	_check(str(_v(bad2).get("why", "")) == "action 'FLY' is not a canonical action", "legacy bad action error")
	var bad3 := _base()
	(bad3["scope"] as Dictionary)["region"] = "MOON"
	_check(str(_v(bad3).get("why", "")) == "scope.region 'MOON' is not a known formation token", "legacy bad region error")
	var bad4 := _base()
	(bad4["scope"] as Dictionary)["region"] = "EXTREME_LEFT"
	(bad4["style"] as Dictionary)["depth"] = "deep"
	var ok4 := _v(bad4)
	_check(bool(ok4.get("ok", false)) and str(((ok4.get("intent", {}) as Dictionary).get("style", {}) as Dictionary).get("depth", "")) == "deep", "legacy depth deep folds")
	var bad5 := _base()
	bad5["confidence"] = 2.0
	_check(str(_v(bad5).get("why", "")) == "confidence outside 0.0-1.0", "legacy bad confidence error")
	var bad6 := _base()
	(bad6["scope"] as Dictionary)["type"] = "UNION"
	(bad6["scope"] as Dictionary)["regions"] = []
	(bad6["scope"] as Dictionary)["region"] = ""
	_check(str(_v(bad6).get("why", "")) == "UNION scope needs a non-empty regions array", "legacy union-no-regions error")
	var bad7 := _base()
	bad7["action"] = ""
	_check(str(_v(bad7).get("why", "")) == "action '' is not a canonical action", "legacy empty action COMMAND error")
	var info := _base()
	info["request_type"] = "INFORMATION"
	info["action"] = ""
	_check(bool(_v(info).get("ok", false)), "legacy INFORMATION empty action ok")
	# Whole-force coercion preserved.
	var whole := _base()
	(whole["scope"] as Dictionary)["type"] = "ALL_AVAILABLE"
	(whole["scope"] as Dictionary)["class"] = "CAVALRY"
	(whole["scope"] as Dictionary)["region"] = "ALL"
	var okw := _v(whole)
	_check(bool(okw.get("ok", false)) and str((((okw.get("intent", {}) as Dictionary).get("scope", {})) as Dictionary).get("class", "")) == "ALL_ARMS", "legacy ALL coercion")
	# Orders[] contract.
	var multi := {"request_type": "COMMAND",
		"orders": [
			{"action": "ADVANCE",
				"scope": {"type": "WING_CLASS", "class": "SCOUT", "region": "ALL", "unit_id": ""},
				"style": {"risk": "balanced", "pressure": "balanced", "depth": "normal"},
				"confidence": 0.9},
			{"action": "HOLD",
				"scope": {"type": "ALL_AVAILABLE", "class": "ALL_ARMS", "region": "ALL", "unit_id": ""},
				"scope_expr": {"op": "DIFF", "left": {"op": "ALL_FRIENDLY"}, "right": {"op": "CLASS", "class": "SCOUT"}},
				"style": {"risk": "balanced", "pressure": "balanced", "depth": "normal"},
				"confidence": 0.8}],
		"question": "", "missing": []}
	var okm := _v(multi)
	_check(bool(okm.get("ok", false)), "orders[2] validates")
	var itm: Dictionary = okm.get("intent", {})
	_check((itm.get("orders", []) as Array).size() == 2, "orders[2] kept")
	_check(str(itm.get("action", "")) == "ADVANCE", "mirror action = first order")
	_check(absf(float(itm.get("order_confidence", 1.0)) - 0.8) < 1e-9, "message confidence = min")
	var over := {"request_type": "COMMAND", "orders": [{}, {}, {}, {}, {}]}
	_check(str(_v(over).get("why", "")) == "too many orders (max 4)", "orders cap")
	var badord := {"request_type": "COMMAND", "orders": [{"action": "FLY",
		"scope": {"type": "WING_CLASS", "class": "SCOUT", "region": "ALL", "unit_id": ""}}]}
	_check(str(_v(badord).get("why", "")) == "orders[0].action 'FLY' is not a canonical action", "orders[0] error prefix")
	var badse := {"request_type": "COMMAND", "orders": [{"action": "HOLD",
		"scope": {"type": "ALL_AVAILABLE", "class": "ALL_ARMS", "region": "ALL", "unit_id": ""},
		"scope_expr": {"op": "NOPE"}}]}
	_check(str(_v(badse).get("why", "")) == "orders[0].scope_expr: unknown scope op 'NOPE'", "orders scope_expr rejected")
	# Fingerprint: legacy shape keeps the 9-segment format (expr field empty).
	var fp := IntentScript.intent_fingerprint(it1)
	_check(fp.count("|") == 8 and fp.contains("LEFT++||balanced"), "legacy fingerprint arity (%s)" % fp.left(70))
	print("VALIDATE_EDGE_" + ("PASS" if failures.is_empty() else "FAIL") + " (%d/%d)" % [passed, passed + failures.size()])
	quit(0 if failures.is_empty() else 1)
