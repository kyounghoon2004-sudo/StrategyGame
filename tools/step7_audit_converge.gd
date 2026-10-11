extends SceneTree

## Convergence + native-divergence probe (NO LLM transport here; uses
## validated Phase-1 outputs from .audit_phase1_raw.json):
## 1. NL shape convergence: variant phrasings of one order must resolve
##    to IDENTICAL membership whether the model emitted legacy scope or
##    scope_expr AST.
## 2. Native-vs-algebra: planner ALL_AVAILABLE ADVANCE membership vs
##    algebra ALL_COMBAT membership on the same boot (documents the
##    intentional relationship).
## Evidence: tools/.audit_converge.json.

const OUT := "D:/Game development/Demon slayer/StrategyGame/tools/.audit_converge.json"
const RAW := "D:/Game development/Demon slayer/StrategyGame/tools/.audit_phase1_raw.json"
const AlgebraScript = preload("res://scripts/step7/step7_scope_algebra.gd")
const IntentScript = preload("res://scripts/step7/step7_chat_intent.gd")
const CmdScript = preload("res://scripts/step7/step7_action_command.gd")

var failures: Array = []
var passed := 0


func _init() -> void:
	call_deferred("_run")


func _check(cond: bool, label: String, info: Dictionary = {}) -> void:
	if cond:
		passed += 1
	else:
		failures.append(label)
	print(("PASS " if cond else "FAIL ") + label + (" " + JSON.stringify(info).left(200) if not info.is_empty() else ""))


func _membership(intent: Dictionary, deps: Dictionary) -> Array:
	var ex: Dictionary = intent.get("scope_expr", {})
	if ex.is_empty():
		var leg := AlgebraScript.compile_legacy(intent.get("scope", {}))
		if not bool(leg.get("ok", false)):
			return []
		ex = leg.get("expr", {})
	var r: Dictionary = AlgebraScript.resolve(AlgebraScript.normalize(ex), deps)
	return (r.get("unit_ids", []) as Array).duplicate()


func _run() -> void:
	var packed: PackedScene = load("res://scenes/step2r_battlefield_shell.tscn")
	var battle: Node = packed.instantiate()
	get_root().add_child(battle)
	for _i in range(20):
		await process_frame
	var integration: Node = battle.get_node_or_null("Step7Integration")
	for _i in range(240):
		if integration and bool(integration.get("ready_for_step7")):
			break
		await process_frame
	if integration == null:
		failures.append("integration not ready")
		_write({})
		quit(2)
		return
	for _i in range(30):
		await process_frame
	var um: RefCounted = integration.get("unit_manager")
	var svc: RefCounted = integration.get("action_service")
	var deps := {"unit_manager": um, "selected_unit": {}}
	var raw: Variant = JSON.parse_string(FileAccess.get_file_as_string(RAW))
	var by_tag := {}
	for r in (((raw as Dictionary).get("results", [])) as Array):
		by_tag[str((r as Dictionary).get("tag", ""))] = r
	# 1. Shape convergence over live membership.
	var sets := {}
	for tag in ["cav_left_push", "cav_left_v2", "cav_left_v3", "ast_adv_intersect"]:
		if not by_tag.has(tag):
			_check(false, "converge: raw present for " + tag)
			continue
		var parsed: Dictionary = IntentScript.extract_json(str((by_tag[tag] as Dictionary).get("raw", "")))
		var checked: Dictionary = IntentScript.validate_intent(parsed)
		if not bool(checked.get("ok", false)):
			_check(false, "converge: valid intent for " + tag, {"why": str(checked.get("why", "?"))})
			continue
		var intent: Dictionary = checked.get("intent", {})
		sets[tag] = _membership(intent, deps)
		print("CONVERGE %s fp=%s ids=%s" % [tag, IntentScript.intent_fingerprint(intent), str(sets[tag])])
	var base: Array = sets.get("cav_left_push", ["MISSING"])
	var same := true
	for tag in ["cav_left_v2", "cav_left_v3", "ast_adv_intersect"]:
		if sets.get(tag, ["X"]) != base:
			same = false
	_check(same and base == ["B_CAV_1", "B_CAV_2", "B_CAV_3"], "converge: 4 phrasings, one membership")
	# 2. Native-vs-algebra on the same boot.
	var cmd := CmdScript.make("ADVANCE", CmdScript.scope_all(), "FORWARD")
	var pv: Dictionary = svc.call("preview_action", cmd, "blue")
	var native_ids: Array = []
	var native_classes := {}
	for a in (pv.get("resolved_units", []) as Array):
		if a is Dictionary:
			native_ids.append(str((a as Dictionary).get("unit_id", "")))
			var c := str((a as Dictionary).get("class", "?")).to_upper()
			native_classes[c] = int(native_classes.get(c, 0)) + 1
	native_ids.sort()
	var alg: Dictionary = AlgebraScript.resolve({"op": "ALL_COMBAT"}, deps)
	var alg_ids: Array = (alg.get("unit_ids", []) as Array).duplicate()
	# Documented relationship (Class 13): the native planner maneuver set
	# and the algebra combat set differ ONLY by (a) HQ/SUPPLY wagons, which
	# the native whole-force path marches by long-standing shipped behavior
	# while the doctrine path holds out via policy exclusion, and (b)
	# formations for which the planner finds no legal action right now
	# (situational, honestly excluded at execution). Membership direction
	# (a) is asserted exactly; (b) is reported.
	var algset := {}
	for uid in alg_ids:
		algset[str(uid)] = true
	var native_extra: Array = []
	for uid in native_ids:
		if not algset.has(str(uid)):
			native_extra.append(str(uid))
	var extra_policy_only := true
	for uid in native_extra:
		var u := {}
		for x in um.call("get_all_units_including_garrisoned"):
			if x is Dictionary and str((x as Dictionary).get("id", "")) == uid:
				u = x
		if not str((u as Dictionary).get("class", "")).to_upper() in ["HQ", "SUPPLY"]:
			extra_policy_only = false
	_check(extra_policy_only, "native-vs-algebra: planner extras are HQ/SUPPLY only",
		{"extras": native_extra})
	var alg_missing: Array = []
	for uid in algset.keys():
		if not uid in native_ids:
			alg_missing.append(str(uid))
	var info := {"native_count": native_ids.size(), "algebra_count": alg_ids.size(),
		"native_classes": native_classes, "native_extras": native_extra,
		"algebra_not_in_native": alg_missing, "sets": sets}
	_write(info)
	print("CONVERGE_" + ("PASS" if failures.is_empty() else "FAIL") + " (%d/%d)" % [passed, passed + failures.size()])
	quit(0 if failures.is_empty() else 1)


func _write(info: Dictionary) -> void:
	var f := FileAccess.open(OUT, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({"status": "PASS" if failures.is_empty() else "FAIL",
			"failures": failures, "passed": passed, "info": info}))
		f.close()
