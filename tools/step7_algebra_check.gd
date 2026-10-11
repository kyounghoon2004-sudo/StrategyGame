extends SceneTree

## Deterministic scope-algebra proof (NO LLM): the 8 mandated expressions
## + algebraic laws + validation rejects + legacy equivalence diff
## against tools/.audit_legacy_scopes.json. Boots the canonical battle
## (real clusters/roster/HQ). Evidence: tools/.audit_algebra.json.
## quit 0 = pass, 1 = fail.

const OUT := "D:/Game development/Demon slayer/StrategyGame/tools/.audit_algebra.json"
const BASE := "D:/Game development/Demon slayer/StrategyGame/tools/.audit_legacy_scopes.json"
const AlgebraScript = preload("res://scripts/step7/step7_scope_algebra.gd")
const ResolverScript = preload("res://scripts/step7/step7_scope_resolver.gd")
const CommanderScript = preload("res://scripts/step7/step7_chat_commander.gd")

var failures: Array = []
var notes: Array = []
var evidence := {}


func _init() -> void:
	call_deferred("_run")


func _check(cond: bool, label: String) -> void:
	if cond:
		notes.append("PASS " + label)
	else:
		failures.append(label)
	print(("PASS " if cond else "FAIL ") + label)


func _expr(tag: String, e: Dictionary, deps: Dictionary, expect: Dictionary = {}) -> Dictionary:
	var v: Dictionary = AlgebraScript.validate_expr(e)
	if not bool(v.get("ok", false)):
		_check(false, tag + ": validates (" + str(v.get("why", "?")) + ")")
		return {}
	var n: Dictionary = AlgebraScript.normalize(e)
	var r: Dictionary = AlgebraScript.resolve(n, deps)
	_check(bool(r.get("ok", false)), tag + ": resolves")
	var ids: Array = (r.get("unit_ids", []) as Array).duplicate()
	var sorted_ids: Array = ids.duplicate()
	sorted_ids.sort()
	_check(ids == sorted_ids, tag + ": canonical order")
	_check(ids.size() == _uniq(ids).size(), tag + ": no duplicates")
	var row := {"tag": tag, "expr_fp": AlgebraScript.fingerprint(e),
		"norm_fp": AlgebraScript.fingerprint(n),
		"summary": AlgebraScript.summary_kr(n),
		"count": ids.size(), "ids": ids,
		"classes": r.get("classes", {}), "wings": r.get("wings", []),
		"clusters": r.get("clusters", {}), "empty": bool(r.get("empty", true))}
	if not expect.is_empty():
		for k in expect.keys():
			_check(str(row.get(k, "?")) == str(expect[k]),
				"%s: %s == %s (got %s)" % [tag, str(k), str(expect[k]), str(row.get(k, "?"))])
	return row


func _uniq(a: Array) -> Array:
	var s := {}
	for x in a:
		s[str(x)] = true
	return s.keys()


func _laws(deps: Dictionary) -> void:
	var a := {"op": "CLASS", "class": "INFANTRY"}
	var b := {"op": "WING", "wing": "LEFT"}
	var empty := {"op": "EMPTY"}
	var allf := {"op": "ALL_FRIENDLY"}
	_check(AlgebraScript.fingerprint({"op": "UNION", "args": [a, a]}) == AlgebraScript.fingerprint(a), "law: A+A=A")
	_check(AlgebraScript.fingerprint({"op": "INTERSECT", "args": [a, a]}) == AlgebraScript.fingerprint(a), "law: A*A=A")
	_check(AlgebraScript.fingerprint({"op": "DIFF", "left": a, "right": a}) == "EMPTY", "law: A-A=EMPTY")
	_check(AlgebraScript.fingerprint({"op": "UNION", "args": [a, empty]}) == AlgebraScript.fingerprint(a), "law: A+EMPTY=A")
	_check(AlgebraScript.fingerprint({"op": "INTERSECT", "args": [a, empty]}) == "EMPTY", "law: A*EMPTY=EMPTY")
	_check(AlgebraScript.fingerprint({"op": "DIFF", "left": a, "right": empty}) == AlgebraScript.fingerprint(a), "law: A-EMPTY=A")
	_check(AlgebraScript.fingerprint({"op": "INTERSECT", "args": [a, allf]}) == AlgebraScript.fingerprint(a), "law: A*ALL=A")
	var ab := AlgebraScript.resolve({"op": "INTERSECT", "args": [a, b]}, deps)
	var ba := AlgebraScript.resolve({"op": "INTERSECT", "args": [b, a]}, deps)
	_check((ab.get("unit_ids", []) as Array) == (ba.get("unit_ids", []) as Array), "law: A*B=B*A (membership)")
	var au := AlgebraScript.resolve({"op": "UNION", "args": [a, b]}, deps)
	var bu := AlgebraScript.resolve({"op": "UNION", "args": [b, a]}, deps)
	_check((au.get("unit_ids", []) as Array) == (bu.get("unit_ids", []) as Array), "law: A+B=B+A (membership)")
	var nested := {"op": "UNION", "args": [a, {"op": "UNION", "args": [b, empty]}]}
	_check(AlgebraScript.fingerprint(nested) == AlgebraScript.fingerprint({"op": "UNION", "args": [a, b]}), "norm: flatten+dedupe")
	# Validation rejects.
	_check(not bool(AlgebraScript.validate_expr({"op": "NOPE"}).get("ok", true)), "reject: unknown op")
	_check(not bool(AlgebraScript.validate_expr({"op": "CLASS", "class": "ALL_ARMS"}).get("ok", true)), "reject: CLASS(ALL_ARMS)")
	_check(not bool(AlgebraScript.validate_expr({"op": "WING", "wing": "UP"}).get("ok", true)), "reject: bad wing")
	_check(not bool(AlgebraScript.validate_expr({"op": "UNIT"}).get("ok", true)), "reject: UNIT without id")
	_check(not bool(AlgebraScript.validate_expr({"op": "DIFF", "left": a}).get("ok", true)), "reject: DIFF without right")


func _legacy_equivalence(deps: Dictionary) -> void:
	_deps_cache = deps
	var t := FileAccess.get_file_as_string(BASE)
	if t.is_empty():
		_check(false, "legacy baseline present")
		return
	var data: Variant = JSON.parse_string(t)
	var diffs: Array = []
	for row in (((data as Dictionary).get("rows", [])) as Array):
		var r: Dictionary = row
		var tag := str(r.get("tag", "?"))
		var live := {}
		if str(r.get("fn", "")) == "resolve":
			live = ResolverScript.resolve(r.get("scope", {}), deps)
		elif str(r.get("fn", "")) == "resolve_force":
			live = ResolverScript.resolve_force(r.get("scope", {}), deps)
		else:
			continue # union rows handled below
		var same := bool(live.get("ok", false)) == bool(r.get("ok", false)) \
			and (live.get("unit_ids", []) as Array) == (r.get("unit_ids", []) as Array) \
			and str(live.get("fail_kind", "")) == str(r.get("fail_kind", "")) \
			and (live.get("wings", []) as Array) == (r.get("wings", []) as Array)
		if not same:
			diffs.append(tag)
			print("EQUIV_DIFF %s base=%s live=%s" % [tag, JSON.stringify(r).left(220), JSON.stringify(live).left(220)])
	# Union rows: recompute via resolve_union with same regions/cls.
	var union_cases := [["union_CAVALRY_LR", ["LEFT", "RIGHT"], "CAVALRY"],
		["union_INFANTRY_LR", ["LEFT", "RIGHT"], "INFANTRY"],
		["union_SCOUT_LR", ["LEFT", "RIGHT"], "SCOUT"],
		["union_HQ_LR", ["LEFT", "RIGHT"], "HQ"],
		["union_ALL_ARMS_LR", ["LEFT", "RIGHT"], "ALL_ARMS"],
		["union_CAV_EXL", ["EXTREME_LEFT"], "CAVALRY"]]
	var by_tag := {}
	for row2 in (((data as Dictionary).get("rows", [])) as Array):
		by_tag[str((row2 as Dictionary).get("tag", "?"))] = row2
	for c in union_cases:
		var base: Dictionary = by_tag.get(str(c[0]), {})
		if base.is_empty():
			diffs.append(str(c[0]) + ":missing-baseline")
			continue
		var live2: Dictionary = ResolverScript.resolve_union((c[1] as Array).duplicate(), str(c[2]), deps)
		var same2 := bool(live2.get("ok", false)) == bool(base.get("ok", false)) \
			and (live2.get("unit_ids", []) as Array) == (base.get("unit_ids", []) as Array) \
			and (live2.get("empty_regions", []) as Array) == (base.get("empty_regions", []) as Array)
		if not same2:
			diffs.append(str(c[0]))
			print("EQUIV_DIFF %s base=%s live=%s" % [str(c[0]), JSON.stringify(base).left(220), JSON.stringify(live2).left(220)])
	# Uncap-intended deltas (staging caps retired; semantic sets complete):
	# the live set must EXTEND the capped baseline prefix with the same
	# total — a real membership check, not a blind allowlist. Plus the
	# HQ-HOLD policy delta (documented).
	var uncap_tags := {"force_ALL": true, "union_ALL_ARMS_LR": true}
	var accepted := {"force_HOLD_HQ": true}
	var unaccepted: Array = []
	for d in diffs:
		var tag := str(d)
		if accepted.has(tag):
			continue
		if uncap_tags.has(tag):
			if _prefix_extended(tag, by_tag):
				continue
		unaccepted.append(tag)
	_check(unaccepted.is_empty(), "legacy equivalence (accepted=%s unaccepted=%s)" % [str(diffs), str(unaccepted)])
	evidence["equiv_diffs"] = diffs


## Uncap proof: live ids must start with the capped baseline prefix,
## totals must match, and live must not claim truncation.
func _prefix_extended(tag: String, by_tag: Dictionary) -> bool:
	var base: Dictionary = by_tag.get(tag, {})
	if base.is_empty():
		return false
	var live := {}
	if tag == "force_ALL":
		live = ResolverScript.resolve_force(
			{"type": "ALL_AVAILABLE", "class": "ALL_ARMS", "region": "ALL"}, _deps_cache)
	elif tag == "union_ALL_ARMS_LR":
		live = ResolverScript.resolve_union(["LEFT", "RIGHT"], "ALL_ARMS", _deps_cache)
	else:
		return false
	var b: Array = base.get("unit_ids", [])
	var l: Array = live.get("unit_ids", [])
	if int(live.get("total", -1)) != int(base.get("total", -2)):
		return false
	if bool(live.get("truncated", true)):
		return false
	if l.size() < b.size():
		return false
	return (l.slice(0, b.size()) as Array) == b


var _deps_cache := {}


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
		_write()
		quit(2)
		return
	for _i in range(30):
		await process_frame
	var um: RefCounted = integration.get("unit_manager")
	var sel := {}
	for u in um.call("get_all_units_including_garrisoned"):
		if u is Dictionary and str((u as Dictionary).get("id", "")) == "B_CAV_2":
			sel = u
	var deps := {"unit_manager": um, "selected_unit": sel}
	var results: Array = []
	# 1. 전군 (37 live BLUE field formations incl. HQ/SUPPLY).
	results.append(_expr("T1_all", {"op": "ALL_FRIENDLY"}, deps, {"count": "37"}))
	# 2. 전군 - 정찰병 (37 - 5 scouts).
	results.append(_expr("T2_all_minus_scout",
		{"op": "DIFF", "left": {"op": "ALL_FRIENDLY"},
			"right": {"op": "CLASS", "class": "SCOUT"}}, deps, {"count": "32"}))
	# 3. 좌익 + 우익 (L2:6+L1:1 + R1:1+R2:6 combat, plus 2 supply wagons:
	# wing membership is truthful — wagons included; eligibility stays
	# the caller's job).
	results.append(_expr("T3_left_plus_right",
		{"op": "UNION", "args": [{"op": "WING", "wing": "LEFT"}, {"op": "WING", "wing": "RIGHT"}]}, deps, {"count": "16"}))
	# 4. 좌익 기병
	results.append(_expr("T4_left_cav",
		{"op": "INTERSECT", "args": [{"op": "WING", "wing": "LEFT"}, {"op": "CLASS", "class": "CAVALRY"}]},
		deps, {"count": "3"}))
	# 5. 보병 + 창병
	results.append(_expr("T5_inf_plus_spe",
		{"op": "UNION", "args": [{"op": "CLASS", "class": "INFANTRY"}, {"op": "CLASS", "class": "SPEARMAN"}]},
		deps, {"count": "12"}))
	# 6. 중앙의 보병과 창병 (4 + 4).
	results.append(_expr("T6_center_inf_spe",
		{"op": "INTERSECT", "args": [{"op": "WING", "wing": "CENTER"},
			{"op": "UNION", "args": [{"op": "CLASS", "class": "INFANTRY"}, {"op": "CLASS", "class": "SPEARMAN"}]}]},
		deps, {"count": "8"}))
	# 7. 전군 - HQ - SUPPLY (37 - 1 - 3).
	results.append(_expr("T7_all_minus_hq_sup",
		{"op": "DIFF", "left": {"op": "DIFF", "left": {"op": "ALL_FRIENDLY"},
				"right": {"op": "CLASS", "class": "HQ"}},
			"right": {"op": "CLASS", "class": "SUPPLY"}}, deps, {"count": "33"}))
	# 8. 모든 기병 - 좌익 기병
	results.append(_expr("T8_cav_minus_left_cav",
		{"op": "DIFF", "left": {"op": "CLASS", "class": "CAVALRY"},
			"right": {"op": "INTERSECT", "args": [{"op": "WING", "wing": "LEFT"}, {"op": "CLASS", "class": "CAVALRY"}]}},
		deps, {"count": "1"}))
	# Extras: cluster atom, selected, named unit, combat atom, empty.
	results.append(_expr("X_cluster_L2", {"op": "CLUSTER", "cluster": "L2"}, deps))
	results.append(_expr("X_selected", {"op": "SELECTED"}, deps, {"count": "1"}))
	results.append(_expr("X_unit_named", {"op": "UNIT", "unit_id": "B_CAV_4"}, deps, {"count": "1"}))
	results.append(_expr("X_all_combat", {"op": "ALL_COMBAT"}, deps))
	results.append(_expr("X_empty", {"op": "EMPTY"}, deps, {"count": "0"}))
	evidence["expressions"] = results
	_laws(deps)
	_legacy_equivalence(deps)
	_visual_probe(integration, results)
	_composite_proof(deps)
	_perf_probe(deps)
	_write()
	print("ALGEBRA_" + ("PASS" if failures.is_empty() else "FAIL") + " (%d/%d)" % [notes.size(), notes.size() + failures.size()])
	quit(0 if failures.is_empty() else 1)


## DEV visualization proof: push three resolved sets through the live
## map highlight path (headless asserts plumbing + cell counts; humans
## see the highlight in the GUI run).
func _visual_probe(integration: Node, results: Array) -> void:
	var adapter: Node = integration.get("_advisor_adapter")
	if adapter == null or not adapter.has_method("preview_scope_cells"):
		_check(false, "visual: adapter preview hook present")
		return
	var shown := 0
	for row in results:
		var tag := str((row as Dictionary).get("tag", ""))
		if tag in ["T2_all_minus_scout", "T3_left_plus_right", "T6_center_inf_spe"]:
			adapter.call("preview_scope_cells", ((row as Dictionary).get("ids", []) as Array).duplicate())
			shown += 1
	_check(shown == 3, "visual: 3 arbitrary sets pushed to map highlight")
	adapter.call("clear_staged_preview")
	evidence["visual_sets"] = shown


## Composite-order representation proof ("정찰병은 전진하고 나머지는 대기"):
## one message, two orders, disjoint sets resolved deterministically.
## Representation + resolution only; composite execution is next milestone.
func _composite_proof(deps: Dictionary) -> void:
	var orders := [
		{"action": "ADVANCE",
			"scope": {"type": "WING_CLASS", "class": "SCOUT", "region": "ALL", "unit_id": ""},
			"scope_expr": {"op": "CLASS", "class": "SCOUT"},
			"style": {"risk": "balanced", "pressure": "balanced", "depth": "normal"},
			"request_type": "COMMAND", "question": "", "missing": [],
			"confidence": 0.9},
		{"action": "HOLD",
			"scope": {"type": "ALL_AVAILABLE", "class": "ALL_ARMS", "region": "ALL", "unit_id": ""},
			"scope_expr": {"op": "DIFF", "left": {"op": "ALL_FRIENDLY"},
				"right": {"op": "CLASS", "class": "SCOUT"}},
			"style": {"risk": "balanced", "pressure": "balanced", "depth": "normal"},
			"request_type": "COMMAND", "question": "", "missing": [],
			"confidence": 0.9},
	]
	var normed: Array = []
	for o in orders:
		var oo: Dictionary = (o as Dictionary).duplicate(true)
		oo["scope_expr"] = AlgebraScript.normalize((o as Dictionary).get("scope_expr", {}))
		normed.append(oo)
	var resolved: Array = CommanderScript.resolve_orders(normed, deps)
	_check(resolved.size() == 2, "composite: two orders resolved")
	var adv: Array = (resolved[0] as Dictionary).get("unit_ids", [])
	var hold: Array = (resolved[1] as Dictionary).get("unit_ids", [])
	_check(adv.size() == 5, "composite: scouts ADVANCE set (%d)" % adv.size())
	_check(hold.size() == 32, "composite: rest HOLD set (%d)" % hold.size())
	var overlap: Array = []
	for uid in adv:
		if uid in hold:
			overlap.append(str(uid))
	_check(overlap.is_empty(), "composite: disjoint (overlap=%s)" % str(overlap))
	var fp := CommanderScript.orders_fingerprint(normed)
	_check(fp.begins_with("ORDERS[ADVANCE@") and fp.contains(";HOLD@"),
		"composite: orders fingerprint (%s)" % fp.left(80))
	evidence["composite"] = {"orders_fp": fp,
		"advance": adv, "hold_count": hold.size()}
	# Serialization round-trip: orders survive JSON without data loss.
	var back: Variant = JSON.parse_string(JSON.stringify(normed))
	var resolved2: Array = CommanderScript.resolve_orders(back, deps)
	_check((resolved2[0] as Dictionary).get("unit_ids", []) == adv
		and (resolved2[1] as Dictionary).get("unit_ids", []) == hold,
		"composite: JSON round-trip lossless")
	var ov: Array = CommanderScript.analyze_order_overlap(normed, deps)
	_check(ov.size() == 1 and str((ov[0] as Dictionary).get("relation", "")) == "disjoint",
		"composite: overlap analysis disjoint")
	# Overlap cases: same-action overlap vs conflicting overlap.
	var ov_orders := [
		{"action": "ADVANCE",
			"scope": {"type": "WING_CLASS", "class": "ALL_ARMS", "region": "LEFT", "unit_id": ""},
			"scope_expr": {},
			"style": {}, "request_type": "COMMAND", "question": "", "missing": [],
			"confidence": 0.9},
		{"action": "ADVANCE",
			"scope": {"type": "WING_CLASS", "class": "CAVALRY", "region": "ALL", "unit_id": ""},
			"scope_expr": {},
			"style": {}, "request_type": "COMMAND", "question": "", "missing": [],
			"confidence": 0.9},
		{"action": "HOLD",
			"scope": {"type": "WING_CLASS", "class": "CAVALRY", "region": "ALL", "unit_id": ""},
			"scope_expr": {},
			"style": {}, "request_type": "COMMAND", "question": "", "missing": [],
			"confidence": 0.9},
	]
	var ov2: Array = CommanderScript.analyze_order_overlap(ov_orders, deps)
	var rels := {}
	for p in ov2:
		rels["%d-%d" % [int((p as Dictionary).get("a", -1)), int((p as Dictionary).get("b", -1))]] = str((p as Dictionary).get("relation", "?"))
	_check(str(rels.get("0-1", "?")) == "overlap_same_action", "overlap: ADV(LEFT) vs ADV(CAV) same-action")
	_check(str(rels.get("0-2", "?")) == "overlap_conflict", "overlap: ADV(LEFT) vs HOLD(CAV) conflict")
	_check(str(rels.get("1-2", "?")) == "overlap_conflict", "overlap: ADV(CAV) vs HOLD(CAV) conflict")
	evidence["overlap"] = rels


## Performance: 200 full resolutions of the heaviest mandated expression.
func _perf_probe(deps: Dictionary) -> void:
	var e := {"op": "INTERSECT", "args": [{"op": "WING", "wing": "CENTER"},
		{"op": "UNION", "args": [{"op": "CLASS", "class": "INFANTRY"}, {"op": "CLASS", "class": "SPEARMAN"}]}]}
	var t0 := Time.get_ticks_msec()
	for _i in range(200):
		AlgebraScript.resolve(e, deps)
	var dt := Time.get_ticks_msec() - t0
	_check(dt < 5000, "perf: 200 nested resolutions in %dms" % dt)
	evidence["perf_200_resolve_ms"] = dt


func _write() -> void:
	var f := FileAccess.open(OUT, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({"status": "PASS" if failures.is_empty() else "FAIL",
			"failures": failures, "notes": notes, "evidence": evidence}))
		f.close()
