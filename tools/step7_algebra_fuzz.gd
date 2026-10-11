extends SceneTree

## Property/fuzz proof for the scope algebra (NO LLM): 300 seeded random
## expressions over the LIVE roster, each checked against an INDEPENDENT
## reference evaluator (separate straightforward implementation), plus:
## normalization membership-invariance, fingerprint stability, set-theory
## theorems on random triples, validation/security rejects, metadata
## agreement, RED-id safety. Evidence: tools/.audit_fuzz.json.

const OUT := "D:/Game development/Demon slayer/StrategyGame/tools/.audit_fuzz.json"
const AlgebraScript = preload("res://scripts/step7/step7_scope_algebra.gd")
const ClustersScript = preload("res://scripts/step7/step7_formation_clusters.gd")

const SEED := 20260916
const ITERS := 300

var failures: Array = []
var passed := 0
var _rng := RandomNumberGenerator.new()
var _live: Array = []
var _clusters: Array = []
var _red_ids: Array = []


func _init() -> void:
	call_deferred("_run")


func _check(cond: bool, label: String) -> void:
	if cond:
		passed += 1
	else:
		failures.append(label)
		print("FUZZ_FAIL " + label)


func _dict_eq(a: Variant, b: Dictionary) -> bool:
	if not a is Dictionary:
		return false
	var da: Dictionary = a
	if da.size() != b.size():
		return false
	for k in b.keys():
		if int(da.get(k, -1)) != int(b.get(k, -2)):
			return false
	return true


# --- Independent reference evaluator (deliberately straightforward) --------

func _ref_live(pool: Array) -> Array:
	var out: Array = []
	for u in pool:
		if u is Dictionary and str((u as Dictionary).get("faction", "")) == "blue" \
				and int((u as Dictionary).get("soldier_count", 0)) > 0 \
				and not bool((u as Dictionary).get("garrisoned", false)) \
				and not bool((u as Dictionary).get("routed", false)):
			out.append(u)
	return out


func _ref_atom(op: String, e: Dictionary, pool: Array, sel: Dictionary) -> Array:
	match op:
		"ALL_FRIENDLY":
			return pool.duplicate()
		"ALL_COMBAT":
			var out: Array = []
			for u in pool:
				if str((u as Dictionary).get("class", "")).to_upper() in ["CAVALRY", "INFANTRY", "SPEARMAN", "ARCHER", "SCOUT", "SIEGE", "CONSCRIPT"]:
					out.append(u)
			return out
		"CLASS":
			var want := str(e.get("class", "")).to_upper()
			var out2: Array = []
			for u in pool:
				if str((u as Dictionary).get("class", "")).to_upper() == want:
					out2.append(u)
			return out2
		"WING":
			var w := str(e.get("wing", "")).to_upper()
			var out3: Array = []
			for u in pool:
				var cid := ClustersScript.cluster_of_unit(u)
				var ok := false
				if w == "LEFT" and cid.begins_with("L"):
					ok = true
				elif w == "CENTER" and cid == "C":
					ok = true
				elif w == "RIGHT" and cid.begins_with("R"):
					ok = true
				elif w == "EXTREME_LEFT" and cid == ClustersScript.extreme_left():
					ok = true
				elif w == "EXTREME_RIGHT" and cid == ClustersScript.extreme_right():
					ok = true
				if ok:
					out3.append(u)
			return out3
		"CLUSTER":
			var cid2 := str(e.get("cluster", "")).to_upper()
			var out4: Array = []
			for u in pool:
				if ClustersScript.cluster_of_unit(u) == cid2:
					out4.append(u)
			return out4
		"UNIT", "SELECTED":
			return []
	return []


func _ref_ids(units: Array) -> Array:
	var out: Array = []
	for u in units:
		out.append(str((u as Dictionary).get("id", "")))
	out.sort()
	return out


func _ref_node(e: Dictionary, pool: Array, sel: Dictionary, live_all: Array) -> Array:
	var op := str(e.get("op", "")).to_upper()
	if op == "UNION":
		var acc: Array = []
		for a in (e.get("args", []) as Array):
			for u in _ref_node(a, pool, sel, live_all):
				var found := false
				for v in acc:
					if str((v as Dictionary).get("id", "")) == str((u as Dictionary).get("id", "")):
						found = true
						break
				if not found:
					acc.append(u)
		return acc
	if op == "INTERSECT":
		var cur: Variant = null
		for a in (e.get("args", []) as Array):
			var part := _ref_node(a, pool, sel, live_all)
			if cur == null:
				cur = part
			else:
				var nxt: Array = []
				for u in (cur as Array):
					for v in part:
						if str((v as Dictionary).get("id", "")) == str((u as Dictionary).get("id", "")):
							nxt.append(u)
							break
				cur = nxt
		return cur if cur != null else []
	if op == "DIFF":
		var l := _ref_node(e.get("left", {}), pool, sel, live_all)
		var r := _ref_node(e.get("right", {}), pool, sel, live_all)
		var out: Array = []
		for u in l:
			var drop := false
			for v in r:
				if str((v as Dictionary).get("id", "")) == str((u as Dictionary).get("id", "")):
					drop = true
					break
			if not drop:
				out.append(u)
		return out
	if op == "UNIT":
		var want := str(e.get("unit_id", "")).to_upper()
		for u in live_all:
			if str((u as Dictionary).get("id", "")).to_upper() == want:
				return [u]
		return []
	if op == "SELECTED":
		if sel.is_empty():
			return []
		for u in live_all:
			if str((u as Dictionary).get("id", "")) == str(sel.get("id", "")):
				return [u]
		return []
	if op == "EMPTY":
		return []
	return _ref_atom(op, e, pool, sel)


# --- Random expression generator --------------------------------------------

func _rand_atom() -> Dictionary:
	var k := _rng.randi_range(0, 9)
	match k:
		0:
			return {"op": "ALL_FRIENDLY"}
		1:
			return {"op": "ALL_COMBAT"}
		2:
			var classes := ["CAVALRY", "INFANTRY", "ARCHER", "SPEARMAN", "SCOUT", "SIEGE", "CONSCRIPT", "HQ", "SUPPLY"]
			return {"op": "CLASS", "class": classes[_rng.randi_range(0, classes.size() - 1)]}
		3:
			var wings := ["LEFT", "CENTER", "RIGHT", "EXTREME_LEFT", "EXTREME_RIGHT"]
			return {"op": "WING", "wing": wings[_rng.randi_range(0, wings.size() - 1)]}
		4:
			return {"op": "CLUSTER", "cluster": str(_clusters[_rng.randi_range(0, _clusters.size() - 1)])}
		5:
			return {"op": "UNIT", "unit_id": str((_live[_rng.randi_range(0, _live.size() - 1)] as Dictionary).get("id", ""))}
		6:
			return {"op": "SELECTED"}
		7:
			return {"op": "EMPTY"}
		8:
			return {"op": "UNIT", "unit_id": str(_red_ids[_rng.randi_range(0, _red_ids.size() - 1)])}
		_:
			return {"op": "UNIT", "unit_id": "BOGUS_%d" % _rng.randi_range(1, 99)}


func _rand_expr(depth: int) -> Dictionary:
	if depth <= 0 or _rng.randf() < 0.45:
		return _rand_atom()
	var k := _rng.randi_range(0, 2)
	if k == 2:
		return {"op": "DIFF", "left": _rand_expr(depth - 1), "right": _rand_expr(depth - 1)}
	var n := _rng.randi_range(1, 3)
	var args: Array = []
	for _i in range(n):
		args.append(_rand_expr(depth - 1))
	return {"op": "UNION" if k == 0 else "INTERSECT", "args": args}


# --- Main --------------------------------------------------------------------

func _run() -> void:
	_rng.seed = SEED
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
	for u in um.call("get_all_units_including_garrisoned"):
		if u is Dictionary and str((u as Dictionary).get("faction", "")) == "red":
			_red_ids.append(str((u as Dictionary).get("id", "")))
	_live = AlgebraScript.live_blue(um)
	_clusters = ClustersScript.cluster_ids()
	var sel := {}
	for u in _live:
		if str((u as Dictionary).get("id", "")) == "B_CAV_2":
			sel = u
	var deps := {"unit_manager": um, "selected_unit": sel}
	var pool := _ref_live(_live)
	var mism := 0
	var norm_mism := 0
	var fp_unstable := 0
	var meta_mism := 0
	var red_leak := 0
	for i in range(ITERS):
		var e := _rand_expr(3)
		var r: Dictionary = AlgebraScript.resolve(e, deps)
		var ref_ids := _ref_ids(_ref_node(e, pool, sel, _live))
		if (r.get("unit_ids", []) as Array) != ref_ids:
			mism += 1
			if mism <= 3:
				print("FUZZ_MEMBERSHIP %s algebra=%s ref=%s" % [JSON.stringify(e).left(200), str(r.get("unit_ids", [])), str(ref_ids)])
		var rn: Dictionary = AlgebraScript.resolve(AlgebraScript.normalize(e), deps)
		if (rn.get("unit_ids", []) as Array) != ref_ids:
			norm_mism += 1
		if AlgebraScript.fingerprint(e) != AlgebraScript.fingerprint((e as Dictionary).duplicate(true)):
			fp_unstable += 1
		# Metadata agreement: recompute distributions from final ids.
		var want_classes := {}
		var want_wings := {}
		var want_clusters := {}
		for uid in ref_ids:
			for u in _live:
				if str((u as Dictionary).get("id", "")) == uid:
					var c := str((u as Dictionary).get("class", "?")).to_upper()
					want_classes[c] = int(want_classes.get(c, 0)) + 1
					var cid := ClustersScript.cluster_of_unit(u)
					if not cid.is_empty():
						want_clusters[cid] = int(want_clusters.get(cid, 0)) + 1
						var w := ClustersScript.wing_of_cluster(cid)
						if not str(w).is_empty():
							want_wings[str(w)] = true
		if not _dict_eq(r.get("classes", {}), want_classes):
			meta_mism += 1
			if meta_mism <= 2:
				print("FUZZ_META classes %s vs %s" % [str(r.get("classes", {})), str(want_classes)])
		var got_wings: Array = ((r.get("wings", []) as Array).duplicate())
		got_wings.sort()
		var want_wing_list: Array = want_wings.keys()
		want_wing_list.sort()
		if str(got_wings) != str(want_wing_list):
			meta_mism += 1
		if not _dict_eq(r.get("clusters", {}), want_clusters):
			meta_mism += 1
		for uid in (r.get("unit_ids", []) as Array):
			if str(uid).begins_with("R_"):
				red_leak += 1
	_check(mism == 0, "fuzz membership agreement (%d iters)" % ITERS)
	_check(norm_mism == 0, "normalization preserves membership")
	_check(fp_unstable == 0, "fingerprint stability")
	_check(meta_mism == 0, "metadata agreement")
	_check(red_leak == 0, "no RED leakage")
	_theorems(deps, pool, sel)
	_validation_stress()
	_write({"iters": ITERS, "seed": SEED})
	print("FUZZ_" + ("PASS" if failures.is_empty() else "FAIL") + " (%d/%d)" % [passed, passed + failures.size()])
	quit(0 if failures.is_empty() else 1)


func _theorems(deps: Dictionary, pool: Array, sel: Dictionary) -> void:
	var t := 0
	var bad := 0
	for _i in range(60):
		var a := _rand_expr(1)
		var b := _rand_expr(1)
		var c := _rand_expr(1)
		# A - (B+C) == (A-B)-C
		var l1 := _ids_of(AlgebraScript.resolve({"op": "DIFF", "left": a,
			"right": {"op": "UNION", "args": [b, c]}}, deps))
		var r1 := _ids_of(AlgebraScript.resolve({"op": "DIFF",
			"left": {"op": "DIFF", "left": a, "right": b}, "right": c}, deps))
		t += 1
		if l1 != r1:
			bad += 1
		# A*(B+C) == (A*B)+(A*C)
		var l2 := _ids_of(AlgebraScript.resolve({"op": "INTERSECT", "args": [a,
			{"op": "UNION", "args": [b, c]}]}, deps))
		var r2 := _ids_of(AlgebraScript.resolve({"op": "UNION", "args": [
			{"op": "INTERSECT", "args": [a, b]},
			{"op": "INTERSECT", "args": [a, c]}]}, deps))
		t += 1
		if l2 != r2:
			bad += 1
		# D(U(A,B), I(B,C)) nested smoke: deterministic + dup-free.
		var nest := {"op": "DIFF",
			"left": {"op": "UNION", "args": [a, b]},
			"right": {"op": "INTERSECT", "args": [b, c]}}
		var rn: Dictionary = AlgebraScript.resolve(nest, deps)
		var ids: Array = rn.get("unit_ids", [])
		t += 1
		var srt: Array = ids.duplicate()
		srt.sort()
		if ids != srt:
			bad += 1
		var u := {}
		for x in ids:
			u[str(x)] = true
		if u.size() != ids.size():
			bad += 1
		t += 1
	_check(bad == 0, "set theorems on random triples (%d checks)" % t)
	# Fingerprint semantics: different ops/arg-order must differ; normalized
	# equivalents must match; dynamic SELECTED differs from frozen UNIT.
	var ca := {"op": "CLASS", "class": "CAVALRY"}
	var wl := {"op": "WING", "wing": "LEFT"}
	_check(AlgebraScript.fingerprint({"op": "UNION", "args": [ca, wl]}) != AlgebraScript.fingerprint({"op": "INTERSECT", "args": [ca, wl]}), "fp: UNION vs INTERSECT differ")
	_check(AlgebraScript.fingerprint({"op": "DIFF", "left": ca, "right": wl}) != AlgebraScript.fingerprint({"op": "DIFF", "left": wl, "right": ca}), "fp: DIFF order matters")
	_check(AlgebraScript.fingerprint({"op": "UNIT", "unit_id": "B_CAV_2"}) != AlgebraScript.fingerprint({"op": "SELECTED"}), "fp: UNIT(X) vs SELECTED differ")
	var leg := {"type": "WING_CLASS", "class": "CAVALRY", "region": "LEFT", "unit_id": ""}
	var hand := {"op": "INTERSECT", "args": [{"op": "WING", "wing": "LEFT"}, {"op": "CLASS", "class": "CAVALRY"}]}
	var comp := AlgebraScript.compile_legacy(leg)
	_check(bool(comp.get("ok", false)) and AlgebraScript.fingerprint(comp.get("expr", {})) == AlgebraScript.fingerprint(hand), "fp: legacy-compiled vs hand AST match")


func _ids_of(r: Dictionary) -> Array:
	return (r.get("unit_ids", []) as Array).duplicate()


func _validation_stress() -> void:
	var bad := 0
	var cases := [
		[{"op": "NOPE"}, false],
		[{"op": "UNION", "args": []}, false],
		[{"op": "UNION", "args": [{}, {}, {}, {}, {}, {}, {}, {}, {}]}, false],
		[{"op": "DIFF", "left": {"op": "EMPTY"}}, false],
		[{"op": "DIFF", "left": {"op": "EMPTY"}, "right": "X"}, false],
		[{"op": "CLASS", "class": "TANK"}, false],
		[{"op": "CLASS", "class": "ALL_ARMS"}, false],
		[{"op": "WING", "wing": "UP"}, false],
		[{"op": "CLUSTER", "cluster": "ZZ9"}, false],
		[{"op": "UNIT"}, false],
		[{"op": "UNIT", "unit_id": "R_GAR_SPE_1"}, true],
		[{"op": "CLASS"}, false],
		[{"op": "UNION", "args": "NOPE"}, false],
	]
	for c in cases:
		var got_ok := bool(AlgebraScript.validate_expr((c as Array)[0]).get("ok", false))
		if got_ok != bool((c as Array)[1]):
			bad += 1
			print("FUZZ_VALIDATE %s expect=%s" % [JSON.stringify((c as Array)[0]).left(120), str((c as Array)[1])])
	# Deep nesting over the cap.
	var deep := {"op": "CLASS", "class": "INFANTRY"}
	for _i in range(10):
		deep = {"op": "UNION", "args": [deep, {"op": "EMPTY"}]}
	if bool(AlgebraScript.validate_expr(deep).get("ok", true)):
		bad += 1
		print("FUZZ_VALIDATE deep-nesting accepted")
	_check(bad == 0, "validation/security stress")


func _write(info: Dictionary) -> void:
	var f := FileAccess.open(OUT, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({"status": "PASS" if failures.is_empty() else "FAIL",
			"failures": failures, "passed": passed, "info": info}))
		f.close()
