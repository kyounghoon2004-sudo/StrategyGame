class_name Step7ScopeAlgebra
extends RefCounted

## Compositional friendly-force set algebra (ONE membership authority).
##
## A scope is a SET EXPRESSION, not an enum with fields:
##
##   Atoms:  ALL_FRIENDLY | ALL_COMBAT | CLASS(c) | WING(w) | CLUSTER(b) |
##           UNIT(id) | SELECTED | EMPTY
##   Ops:    UNION(args[]) | INTERSECT(args[]) | DIFF(left, right)
##
## Canonical dict format:
##   {"op": "CLASS", "class": "CAVALRY"}
##   {"op": "WING", "wing": "LEFT"}
##   {"op": "CLUSTER", "cluster": "L2"}
##   {"op": "UNIT", "unit_id": "B_CAV_2"}
##   {"op": "ALL_FRIENDLY"} / {"op": "ALL_COMBAT"} / {"op": "SELECTED"} / {"op": "EMPTY"}
##   {"op": "UNION", "args": [A, B, ...]}
##   {"op": "INTERSECT", "args": [A, B, ...]}
##   {"op": "DIFF", "left": A, "right": B}
##
## Laws enforced: ordinary set semantics over live BLUE formation ids.
## The LLM NEVER owns membership: it may emit this AST (validated by
## validate_expr), Godot resolves it. Membership (this file) is distinct
## from action eligibility (doctrine/policy/planner layers): atoms resolve
## truthfully, callers account for exclusions explicitly.
##
## Live definition (single standard): faction of the acting side ("blue" by
## default, "red" for Step 2 Cloud orders), soldier_count > 0,
## not garrisoned, not routed. (Legacy extreme-branch resolution used a
## looser filter; unified here — see equivalence tests.)
##
## deps for resolve(): {"unit_manager", "selected_unit" (default {}),
##   "side" (default "blue"; Step 2 passes "red" for Cloud orders),
##   "pool" (optional pre-filtered unit Array; default = all live acting-side).
##   CLASS/WING/CLUSTER/ALL_* draw from pool; UNIT/SELECTED are explicit
##   pointers and draw from the live roster (pool never vetoes a pointer).}

const ClustersScript = preload("res://scripts/step7/step7_formation_clusters.gd")
const CommandScript = preload("res://scripts/step7/step7_action_command.gd")

const OPS := ["UNION", "INTERSECT", "DIFF"]
const ATOMS := ["ALL_FRIENDLY", "ALL_COMBAT", "CLASS", "REGION", "FORMATION", "WING", "CLUSTER",
	"UNIT", "UNITS", "SELECTED", "EMPTY"]

const KNOWN_CLASSES := ["CAVALRY", "INFANTRY", "SPEARMAN", "ARCHER", "SCOUT",
	"SIEGE", "CONSCRIPT", "HQ"]
const REGIONS := ["NORTH", "CENTER", "SOUTH", "WEST", "EAST"]
const WINGS := ["LEFT", "CENTER", "RIGHT", "EXTREME_LEFT", "EXTREME_RIGHT"]

const MAX_DEPTH := 8
const MAX_ARGS := 8

const CLASS_KR := {"CAVALRY": "기병대", "INFANTRY": "보병대", "SPEARMAN": "창병대",
	"ARCHER": "궁병대", "SCOUT": "정찰병", "SIEGE": "공성", "CONSCRIPT": "징집",
	"HQ": "지휘부"}
const REGION_KR := {"NORTH": "북쪽", "CENTER": "중앙", "SOUTH": "남쪽", "WEST": "서쪽", "EAST": "동쪽"}
const WING_KR := {"LEFT": "좌익", "CENTER": "중앙", "RIGHT": "우익",
	"EXTREME_LEFT": "극좌익", "EXTREME_RIGHT": "극우익"}


## All live BLUE field formations in deterministic id order.
static func live_blue(unit_manager: RefCounted) -> Array:
	return live_side(unit_manager, "blue")


## All live acting-side field formations in deterministic id order.
## Step 2 addition: side defaults to "blue" so every Step 1 caller is
## byte-identical; Cloud RED orders resolve with side "red".
static func live_side(unit_manager: RefCounted, side: String = "blue") -> Array:
	var want := side.strip_edges().to_lower()
	if want != "red":
		want = "blue"
	var out: Array = []
	if unit_manager == null or not unit_manager.has_method("get_all_units_including_garrisoned"):
		return out
	for u_val in (unit_manager.get_all_units_including_garrisoned() as Array):
		if not u_val is Dictionary:
			continue
		var u: Dictionary = u_val
		if str(u.get("faction", "")) != want:
			continue
		if int(u.get("soldier_count", 0)) <= 0:
			continue
		if bool(u.get("garrisoned", false)) or bool(u.get("routed", false)):
			continue
		out.append(u)
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a.get("id", "")) < str(b.get("id", "")))
	return out


## Acting side for resolution. Anything but "red" means "blue" (Step 1).
static func _side_of(deps: Dictionary) -> String:
	if str(deps.get("side", "blue")).strip_edges().to_lower() == "red":
		return "red"
	return "blue"


static func _pool(deps: Dictionary, unit_manager: RefCounted) -> Array:
	if deps.has("pool") and deps.get("pool") is Array:
		var p: Array = (deps.get("pool") as Array).duplicate()
		p.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str((a as Dictionary).get("id", "")) < str((b as Dictionary).get("id", "")))
		return p
	return live_side(unit_manager, _side_of(deps))


static func _ids(units: Array) -> Array:
	var out: Array = []
	for u in units:
		if u is Dictionary and not str((u as Dictionary).get("id", "")).is_empty():
			out.append(str((u as Dictionary).get("id", "")))
	out.sort()
	return out


# --- Validation (allow-list; model output is untrusted) ---------------------

## Validate an AST. Returns {ok} or {ok:false, why}.
static func validate_expr(e: Variant, depth: int = 0) -> Dictionary:
	if depth > MAX_DEPTH:
		return {"ok": false, "why": "expression nests deeper than %d" % MAX_DEPTH}
	if not e is Dictionary:
		return {"ok": false, "why": "scope node must be an object"}
	var op := str((e as Dictionary).get("op", "")).strip_edges().to_upper()
	if op in OPS:
		if op == "DIFF":
			if not (e as Dictionary).has("left") or not (e as Dictionary).has("right"):
				return {"ok": false, "why": "DIFF needs left and right"}
			var l := validate_expr((e as Dictionary).get("left"), depth + 1)
			if not bool(l.get("ok", false)):
				return l
			return validate_expr((e as Dictionary).get("right"), depth + 1)
		var args: Variant = (e as Dictionary).get("args", [])
		if not args is Array or (args as Array).is_empty() or (args as Array).size() > MAX_ARGS:
			return {"ok": false, "why": "%s needs 1..%d args" % [op, MAX_ARGS]}
		for a in (args as Array):
			var r := validate_expr(a, depth + 1)
			if not bool(r.get("ok", false)):
				return r
		return {"ok": true}
	if not op in ATOMS:
		return {"ok": false, "why": "unknown scope op '%s'" % str((e as Dictionary).get("op", ""))}
	match op:
		"CLASS":
			var c := str((e as Dictionary).get("class", "")).strip_edges().to_upper()
			if c == "ALL_ARMS":
				return {"ok": false, "why": "CLASS(ALL_ARMS) is ALL_COMBAT; use that atom"}
			if not c in KNOWN_CLASSES:
				return {"ok": false, "why": "unknown class '%s'" % str((e as Dictionary).get("class", ""))}
		"REGION":
			var r := str((e as Dictionary).get("region", "")).strip_edges().to_upper()
			if not r in REGIONS:
				return {"ok": false, "why": "unknown region '%s'" % str((e as Dictionary).get("region", ""))}
		"FORMATION":
			if str((e as Dictionary).get("formation", "")).strip_edges().is_empty():
				return {"ok": false, "why": "FORMATION needs a formation name"}
		"UNITS":
			var uids: Variant = (e as Dictionary).get("unit_ids", [])
			if not uids is Array or (uids as Array).is_empty():
				return {"ok": false, "why": "UNITS needs a non-empty unit_ids array"}
		"WING":
			if not str((e as Dictionary).get("wing", "")).strip_edges().to_upper() in WINGS:
				return {"ok": false, "why": "unknown wing '%s'" % str((e as Dictionary).get("wing", ""))}
		"CLUSTER":
			if not CommandScript.is_valid_cluster_id(str((e as Dictionary).get("cluster", ""))):
				return {"ok": false, "why": "unknown cluster '%s'" % str((e as Dictionary).get("cluster", ""))}
		"UNIT":
			if str((e as Dictionary).get("unit_id", "")).strip_edges().is_empty():
				return {"ok": false, "why": "UNIT needs a unit_id"}
	return {"ok": true}


# --- Normalization (canonical form for fingerprints/debugging) --------------

## Normalize: flatten same-op nesting, drop EMPTY identities, A∩ALL_FRIENDLY→A,
## dedupe identical args, sort args by fingerprint. Returns canonical expr.
static func normalize(e: Dictionary) -> Dictionary:
	var op := str(e.get("op", "")).strip_edges().to_upper()
	if op == "UNION" or op == "INTERSECT":
		var flat: Array = []
		for a in (e.get("args", []) as Array):
			if not a is Dictionary:
				continue
			var n: Dictionary = normalize(a)
			if str(n.get("op", "")) == op:
				for sub in (n.get("args", []) as Array):
					flat.append(sub)
			else:
				flat.append(n)
		var kept: Array = []
		var seen := {}
		for f in flat:
			var fp := fingerprint(f)
			if seen.has(fp):
				continue
			seen[fp] = true
			kept.append(f)
		if op == "UNION":
			var no_empty: Array = []
			for k in kept:
				if str((k as Dictionary).get("op", "")) != "EMPTY":
					no_empty.append(k)
			if no_empty.size() != kept.size():
				kept = no_empty
			if kept.is_empty():
				return {"op": "EMPTY"}
			if kept.size() == 1:
				return kept[0]
		else:
			for k in kept:
				if str((k as Dictionary).get("op", "")) == "EMPTY":
					return {"op": "EMPTY"}
			var no_all: Array = []
			for k2 in kept:
				if str((k2 as Dictionary).get("op", "")) != "ALL_FRIENDLY":
					no_all.append(k2)
			if no_all.size() != kept.size() and not no_all.is_empty():
				kept = no_all
			if kept.size() == 1:
				return kept[0]
		kept.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return fingerprint(a) < fingerprint(b))
		return {"op": op, "args": kept}
	if op == "DIFF":
		var l: Dictionary = normalize(e.get("left", {}))
		var r: Dictionary = normalize(e.get("right", {}))
		if str(r.get("op", "")) == "EMPTY":
			return l
		if fingerprint(l) == fingerprint(r):
			return {"op": "EMPTY"}
		return {"op": "DIFF", "left": l, "right": r}
	return e.duplicate(true)


## Deterministic structural fingerprint of the (normalized) expression.
static func fingerprint(e: Dictionary) -> String:
	var n: Dictionary = normalize(e)
	return _fp(n)


static func _fp(e: Dictionary) -> String:
	var op := str(e.get("op", "")).strip_edges().to_upper()
	if op == "UNION" or op == "INTERSECT":
		var parts: Array = []
		for a in (e.get("args", []) as Array):
			parts.append(_fp(a))
		return "%s(%s)" % [op, ",".join(parts)]
	if op == "DIFF":
		return "DIFF(%s,%s)" % [_fp(e.get("left", {})), _fp(e.get("right", {}))]
	match op:
		"CLASS":
			return "CLASS:%s" % str(e.get("class", "")).strip_edges().to_upper()
		"REGION":
			return "REGION:%s" % str(e.get("region", "")).strip_edges().to_upper()
		"FORMATION":
			return "FORMATION:%s" % str(e.get("formation", "")).strip_edges().to_upper()
		"WING":
			return "WING:%s" % str(e.get("wing", "")).strip_edges().to_upper()
		"CLUSTER":
			return "CLUSTER:%s" % str(e.get("cluster", "")).strip_edges().to_upper()
		"UNIT":
			return "UNIT:%s" % str(e.get("unit_id", "")).strip_edges().to_upper()
		"UNITS":
			var uids: Array = (e.get("unit_ids", []) as Array).duplicate()
			uids.sort()
			return "UNITS:%s" % ",".join(uids)
	return op


## Bind the context-sensitive SELECTED atom to a frozen UNIT or UNITS atom.
## Pure function. Empty id/ids = no-op.
static func bind_selected(e: Dictionary, unit_ids_or_id: Variant) -> Dictionary:
	var ids: Array = []
	if unit_ids_or_id is String:
		var s := str(unit_ids_or_id).strip_edges().to_upper()
		if not s.is_empty():
			ids.append(s)
	elif unit_ids_or_id is Array:
		for v in (unit_ids_or_id as Array):
			var s2 := str(v).strip_edges().to_upper()
			if not s2.is_empty() and not s2 in ids:
				ids.append(s2)
	ids.sort()
	if ids.is_empty():
		return (e as Dictionary).duplicate(true)
	var op := str(e.get("op", "")).strip_edges().to_upper()
	if op.is_empty():
		# Legacy kind-form scope ({"kind": "SELECTED"}) — bind it the same way so
		# the shared representation materializes explicit UNIT/UNITS before use.
		var kind := str(e.get("kind", "")).strip_edges().to_upper()
		if kind == "SELECTED":
			if ids.size() == 1:
				return {"op": "UNIT", "unit_id": ids[0]}
			return {"op": "UNITS", "unit_ids": ids}
		if kind == "UNITS":
			var out_k: Dictionary = (e as Dictionary).duplicate(true)
			var keep: Array = []
			for raw in (out_k.get("unit_ids", []) as Array):
				var up := str(raw).strip_edges().to_upper()
				if up in ids or ids.is_empty():
					keep.append(up)
			out_k["unit_ids"] = keep
			return out_k
		return (e as Dictionary).duplicate(true)
	if op == "SELECTED":
		if ids.size() == 1:
			return {"op": "UNIT", "unit_id": ids[0]}
		else:
			return {"op": "UNITS", "unit_ids": ids}
	if op == "UNION" or op == "INTERSECT":
		var args: Array = []
		for a in (e.get("args", []) as Array):
			if a is Dictionary:
				args.append(bind_selected(a, ids))
		var out: Dictionary = (e as Dictionary).duplicate(true)
		out["args"] = args
		return out
	if op == "DIFF":
		return {"op": "DIFF",
			"left": bind_selected(e.get("left", {}), ids),
			"right": bind_selected(e.get("right", {}), ids)}
	return (e as Dictionary).duplicate(true)


## Player-facing natural description of an expression ("좌익 기병",
## "정찰 제외 전군"). summary_kr stays structural for DEV. Rules cover the
## common shapes; anything exotic falls back to structural joins (never
## raw AST syntax, never wrong).
static func describe_scope_kr(e: Dictionary) -> String:
	var n: Dictionary = normalize(e)
	var op := str(n.get("op", "")).strip_edges().to_upper()
	if op == "INTERSECT":
		var region := ""
		var wing := ""
		var cls := ""
		var cluster := ""
		var union_arg: Dictionary = {}
		var other := false
		for a in (n.get("args", []) as Array):
			var ao := str((a as Dictionary).get("op", "")).strip_edges().to_upper()
			if ao == "REGION" and region.is_empty():
				region = str((a as Dictionary).get("region", "")).strip_edges().to_upper()
			elif ao == "WING" and wing.is_empty():
				wing = str((a as Dictionary).get("wing", "")).strip_edges().to_upper()
			elif ao == "CLASS" and cls.is_empty():
				cls = str((a as Dictionary).get("class", "")).strip_edges().to_upper()
			elif ao == "CLUSTER" and cluster.is_empty():
				cluster = str((a as Dictionary).get("cluster", "")).strip_edges().to_upper()
			elif ao == "UNION" and union_arg.is_empty():
				union_arg = a as Dictionary
			else:
				other = true
		if not other:
			if not region.is_empty() and not cls.is_empty():
				return "%s %s" % [str(REGION_KR.get(region, region)), str(CLASS_KR.get(cls, cls))]
			if not region.is_empty() and not union_arg.is_empty():
				var u_parts: Array = []
				for ua in (union_arg.get("args", []) as Array):
					u_parts.append(describe_scope_kr(ua as Dictionary))
				return "%s %s" % [str(REGION_KR.get(region, region)), " + ".join(u_parts)]
			if not wing.is_empty() and not cls.is_empty():
				return "%s %s" % [str(WING_KR.get(wing, wing)), str(CLASS_KR.get(cls, cls))]
			if not cluster.is_empty() and not cls.is_empty():
				return "%s %s" % [cluster, str(CLASS_KR.get(cls, cls))]
		var parts: Array = []
		for a2 in (n.get("args", []) as Array):
			parts.append(describe_scope_kr(a2))
		return " ∩ ".join(parts)
	if op == "DIFF":
		var l: Dictionary = n.get("left", {})
		var r: Dictionary = n.get("right", {})
		var lop := str(l.get("op", "")).strip_edges().to_upper()
		if lop == "ALL_FRIENDLY" or lop == "ALL_COMBAT":
			return "전군 - %s" % describe_scope_kr(r)
		return "%s에서 %s 제외" % [describe_scope_kr(l), describe_scope_kr(r)]
	if op == "UNION":
		var parts2: Array = []
		for a3 in (n.get("args", []) as Array):
			parts2.append(describe_scope_kr(a3))
		return " + ".join(parts2)
	match op:
		"ALL_FRIENDLY":
			return "전군"
		"ALL_COMBAT":
			return "전투군"
		"CLASS":
			return str(CLASS_KR.get(str(n.get("class", "")).strip_edges().to_upper(),
				str(n.get("class", ""))))
		"REGION":
			return "%s 병력" % str(REGION_KR.get(str(n.get("region", "")).strip_edges().to_upper(),
				str(n.get("region", ""))))
		"FORMATION":
			return str(n.get("formation", "")).strip_edges().to_upper()
		"WING":
			return str(WING_KR.get(str(n.get("wing", "")).strip_edges().to_upper(),
				str(n.get("wing", ""))))
		"CLUSTER":
			return str(n.get("cluster", "")).strip_edges().to_upper()
		"UNIT":
			return str(n.get("unit_id", "")).strip_edges().to_upper()
		"UNITS":
			var ulist: Array = []
			for uid in (n.get("unit_ids", []) as Array):
				ulist.append(str(uid))
			return ", ".join(ulist)
		"SELECTED":
			return "선택부대"
		"EMPTY":
			return "∅"
	return "?"


## Short Korean structural summary for staged labels / DEV ("전군−정찰").
static func summary_kr(e: Dictionary) -> String:
	var op := str(e.get("op", "")).strip_edges().to_upper()
	if op == "UNION":
		var parts: Array = []
		for a in (e.get("args", []) as Array):
			parts.append(summary_kr(a))
		return "+".join(parts)
	if op == "INTERSECT":
		var parts2: Array = []
		for a2 in (e.get("args", []) as Array):
			parts2.append(summary_kr(a2))
		return "∩".join(parts2)
	if op == "DIFF":
		return "%s−%s" % [summary_kr(e.get("left", {})), summary_kr(e.get("right", {}))]
	match op:
		"ALL_FRIENDLY":
			return "전군"
		"ALL_COMBAT":
			return "전투군"
		"CLASS":
			return str(CLASS_KR.get(str(e.get("class", "")).strip_edges().to_upper(),
				str(e.get("class", ""))))
		"REGION":
			return str(REGION_KR.get(str(e.get("region", "")).strip_edges().to_upper(),
				str(e.get("region", ""))))
		"FORMATION":
			return str(e.get("formation", "")).strip_edges().to_upper()
		"WING":
			return str(WING_KR.get(str(e.get("wing", "")).strip_edges().to_upper(),
				str(e.get("wing", ""))))
		"CLUSTER":
			return str(e.get("cluster", "")).strip_edges().to_upper()
		"UNIT":
			return str(e.get("unit_id", "")).strip_edges().to_upper()
		"UNITS":
			var ulist2: Array = []
			for uid2 in (e.get("unit_ids", []) as Array):
				ulist2.append(str(uid2))
			return ",".join(ulist2)
		"SELECTED":
			return "선택부대"
		"EMPTY":
			return "∅"
	return "?"


# --- Resolution (the ONE membership authority) ------------------------------

## Resolve an AST to canonical sorted unit ids + distributions.
## deps: {"unit_manager", "selected_unit" (default {}), "pool" (optional)}.
## Returns {ok, unit_ids, total, classes{}, wings[], clusters{}, empty}
## or {ok:false, fail_kind:"BAD_EXPR", fail_detail}.
static func resolve(e: Dictionary, deps: Dictionary) -> Dictionary:
	var um: RefCounted = deps.get("unit_manager") as RefCounted
	var side := _side_of(deps)
	var units := _resolve_node(e, deps, um)
	var ids := _ids(units)
	# Metadata over id-sorted units (canonical insertion order; membership
	# itself is order-free, but diagnostics must be deterministic).
	var by_id := {}
	for u in units:
		by_id[str((u as Dictionary).get("id", ""))] = u
	var classes := {}
	var wings := {}
	var clusters := {}
	for uid in ids:
		var u: Dictionary = by_id[uid]
		var c := str(u.get("class", "?")).to_upper()
		classes[c] = int(classes.get(c, 0)) + 1
		var cid := ClustersScript.cluster_of_unit(u, side)
		if cid.is_empty():
			continue
		clusters[cid] = int(clusters.get(cid, 0)) + 1
		var w := ClustersScript.wing_of_cluster(cid)
		if not str(w).is_empty():
			wings[str(w)] = true
	var wing_list: Array = wings.keys()
	wing_list.sort()
	return {"ok": true, "unit_ids": ids, "total": ids.size(),
		"classes": classes, "wings": wing_list, "clusters": clusters,
		"empty": ids.is_empty(), "frozen_expr": e}


static func _resolve_node(e: Variant, deps: Dictionary, um: RefCounted) -> Array:
	if not e is Dictionary:
		return []
	var op := str((e as Dictionary).get("op", "")).strip_edges().to_upper()
	if op == "UNION":
		var seen := {}
		var out: Array = []
		for a in (((e as Dictionary).get("args", [])) as Array):
			for u in _resolve_node(a, deps, um):
				var uid := str((u as Dictionary).get("id", ""))
				if not seen.has(uid):
					seen[uid] = true
					out.append(u)
		return out
	if op == "INTERSECT":
		var acc: Variant = null
		for a in (((e as Dictionary).get("args", [])) as Array):
			var part := _resolve_node(a, deps, um)
			if acc == null:
				acc = part
			else:
				var want := {}
				for u in part:
					want[str((u as Dictionary).get("id", ""))] = true
				var cut: Array = []
				for u2 in (acc as Array):
					if want.has(str((u2 as Dictionary).get("id", ""))):
						cut.append(u2)
				acc = cut
			if (acc as Array).is_empty():
				return []
		return acc if acc != null else []
	if op == "DIFF":
		var left := _resolve_node((e as Dictionary).get("left", {}), deps, um)
		var right := _resolve_node((e as Dictionary).get("right", {}), deps, um)
		var drop := {}
		for u in right:
			drop[str((u as Dictionary).get("id", ""))] = true
		var out2: Array = []
		for u2 in left:
			if not drop.has(str((u2 as Dictionary).get("id", ""))):
				out2.append(u2)
		return out2
	return _resolve_atom(op, e, deps, um)


static func _resolve_atom(op: String, e: Dictionary, deps: Dictionary, um: RefCounted) -> Array:
	var pool := _pool(deps, um)
	match op:
		"ALL_FRIENDLY":
			return pool
		"ALL_COMBAT":
			var out: Array = []
			for u in pool:
				if str((u as Dictionary).get("class", "")).to_upper() in ClustersScript.ANCHOR_CLASSES:
					out.append(u)
			return out
		"CLASS":
			var want := str(e.get("class", "")).strip_edges().to_upper()
			var out2: Array = []
			for u in pool:
				if str((u as Dictionary).get("class", "")).to_upper() == want:
					out2.append(u)
			return out2
		"WING":
			return _resolve_wing(str(e.get("wing", "")), pool, _side_of(deps))
		"CLUSTER":
			var cid := str(e.get("cluster", "")).strip_edges().to_upper()
			var out3: Array = []
			for u in pool:
				if ClustersScript.cluster_of_unit(u) == cid:
					out3.append(u)
			return out3
		"UNIT":
			var want_id := str(e.get("unit_id", "")).strip_edges().to_upper()
			for u in live_side(um, _side_of(deps)):
				if str((u as Dictionary).get("id", "")).to_upper() == want_id:
					return [u]
			return []
		"UNITS":
			var want_ids: Array = []
			for x in (e.get("unit_ids", []) as Array):
				want_ids.append(str(x).strip_edges().to_upper())
			var out_u: Array = []
			for u in live_side(um, _side_of(deps)):
				var uid := str((u as Dictionary).get("id", "")).to_upper()
				if uid in want_ids:
					out_u.append(u)
			return out_u
		"REGION":
			var want_r := str(e.get("region", "")).strip_edges().to_upper()
			var bounds: Dictionary = deps.get("bounds", {})
			var out_r: Array = []
			for u in pool:
				var q := int(u.get("q", 0))
				var r := int(u.get("r", 0))
				if is_in_region(q, r, want_r, bounds):
					out_r.append(u)
			return out_r
		"FORMATION":
			var want_f := str(e.get("formation", "")).strip_edges().to_upper()
			var out_f: Array = []
			for u in pool:
				if str(u.get("formation", "")).strip_edges().to_upper() == want_f:
					out_f.append(u)
			return out_f
		"SELECTED":
			var sel: Dictionary = deps.get("selected_unit", {})
			if sel.is_empty() or str(sel.get("faction", "")) != _side_of(deps):
				return []
			if int(sel.get("soldier_count", 0)) <= 0:
				return []
			if bool(sel.get("garrisoned", false)) or bool(sel.get("routed", false)):
				return []
			return [sel]
		"EMPTY":
			return []
	return []


## Logical vertical coordinate strictly proportional to world Y:
## In HexUtils: y = float(r * ROW_STEP + q * ODD_Q_Y_OFFSET) = 42*r + 21*q = 21 * (2*r + q).
## Since 21 > 0, vertical_key = 2*r + q is directly proportional to world Y without screen pixel coupling.
static func logical_vertical(q: int, r: int) -> int:
	return 2 * r + q


## Extracts or derives the authoritative vertical key bounds (min_vertical, max_vertical).
## For canonical R=40 regular hexagon (4,921 cells), min_vertical = -80, max_vertical = 80.
static func get_vertical_bounds(bounds: Dictionary = {}) -> Dictionary:
	if bounds.has("min_vertical") and bounds.has("max_vertical"):
		return {
			"min_vertical": int(bounds["min_vertical"]),
			"max_vertical": int(bounds["max_vertical"])
		}
	if bounds.has("valid_cells") and bounds["valid_cells"] is Array:
		var min_v: int = 999999
		var max_v: int = -999999
		for c in (bounds["valid_cells"] as Array):
			var cq: int = int(c.x) if c is Vector2i else int((c as Dictionary).get("q", 0))
			var cr: int = int(c.y) if c is Vector2i else int((c as Dictionary).get("r", 0))
			var v := logical_vertical(cq, cr)
			if v < min_v: min_v = v
			if v > max_v: max_v = v
		if min_v <= max_v:
			return {"min_vertical": min_v, "max_vertical": max_v}
	if bounds.has("radius"):
		var rad := int(bounds["radius"])
		return {"min_vertical": -2 * rad, "max_vertical": 2 * rad}
	if bounds.has("q_min") and bounds.has("q_max") and bounds.has("r_min") and bounds.has("r_max"):
		var q_min := int(bounds["q_min"])
		var q_max := int(bounds["q_max"])
		var r_min := int(bounds["r_min"])
		var r_max := int(bounds["r_max"])
		var min_v: int = 999999
		var max_v: int = -999999
		for q in range(q_min, q_max + 1):
			for r in range(r_min, r_max + 1):
				var v := logical_vertical(q, r)
				if v < min_v: min_v = v
				if v > max_v: max_v = v
		return {"min_vertical": min_v, "max_vertical": max_v}
	return {"min_vertical": -80, "max_vertical": 80}


static func get_region_bounds(bounds: Dictionary = {}) -> Dictionary:
	var vb := get_vertical_bounds(bounds)
	var q_min: float = float(bounds.get("q_min", -40.0))
	var q_max: float = float(bounds.get("q_max", 40.0))
	var r_min: float = float(bounds.get("r_min", -40.0))
	var r_max: float = float(bounds.get("r_max", 40.0))
	return {
		"q_min": q_min, "q_max": q_max,
		"r_min": r_min, "r_max": r_max,
		"min_vertical": int(vb["min_vertical"]),
		"max_vertical": int(vb["max_vertical"])
	}


## Returns normalized vertical position t in [0.0, 1.0] along the battlefield vertical axis:
## t = (vertical_key - min_vertical) / (max_vertical - min_vertical).
static func normalized_vertical(q: int, r: int, bounds: Dictionary = {}) -> float:
	var vb := get_vertical_bounds(bounds)
	var min_v: float = float(vb["min_vertical"])
	var max_v: float = float(vb["max_vertical"])
	var span_v: float = max_v - min_v
	if span_v <= 0.001:
		return 0.5
	var v: float = float(logical_vertical(q, r))
	return (v - min_v) / span_v


## Canonical Single Region Authority: classifies (q, r) into NORTH / CENTER / SOUTH
## based on normalized logical vertical position t.
## NORTH:  t < 1/3
## CENTER: 1/3 <= t <= 2/3
## SOUTH:  t > 2/3
static func get_region_for_coord(q: int, r: int, bounds: Dictionary = {}) -> String:
	var t := normalized_vertical(q, r, bounds)
	if t < (1.0 / 3.0):
		return "NORTH"
	elif t > (2.0 / 3.0):
		return "SOUTH"
	else:
		return "CENTER"


## Tests if (q, r) falls inside the requested region using the canonical region classifier.
static func is_in_region(q: int, r: int, region: String, bounds: Dictionary = {}) -> bool:
	var reg := region.strip_edges().to_upper()
	if reg in ["NORTH", "CENTER", "SOUTH"]:
		return get_region_for_coord(q, r, bounds) == reg
	var q_min: float = float(bounds.get("q_min", -40.0))
	var q_max: float = float(bounds.get("q_max", 40.0))
	var span_q: float = q_max - q_min
	var norm_q: float = (float(q) - q_min) / span_q if span_q > 0.001 else 0.5
	match reg:
		"WEST":
			return norm_q < (1.0 / 3.0)
		"EAST":
			return norm_q > (2.0 / 3.0)
	return false


static func _resolve_wing(wing: String, pool: Array, side: String = "blue") -> Array:
	var w := wing.strip_edges().to_upper()
	if w in ["LEFT", "CENTER", "RIGHT"]:
		return ClustersScript.wing_members(w, pool, side)
	# Extremes: members of the outermost band (any class in pool).
	var ex := ""
	if w == "EXTREME_LEFT":
		ex = ClustersScript.extreme_left(side)
	elif w == "EXTREME_RIGHT":
		ex = ClustersScript.extreme_right(side)
	if ex.is_empty():
		return []
	var out: Array = []
	for u in pool:
		if ClustersScript.cluster_of_unit(u) == ex:
			out.append(u)
	return out


# --- Legacy compilation (old scope dicts -> algebra; ONE resolver) ----------

## Compile a legacy chat intent scope to an AST.
## Returns {ok, expr} or {ok:false, special:"PREVIOUS"} (PREVIOUS is a
## recommendation pointer, not a set) or {ok:false, why} for unknown shapes.
## Callers keep their ambiguity gates / labels / caps (presentation), but
## membership always comes from resolve().
static func compile_legacy(scope: Dictionary) -> Dictionary:
	var stype := str(scope.get("type", "")).strip_edges().to_upper()
	var cls := str(scope.get("class", "")).strip_edges().to_upper()
	var region := str(scope.get("region", "")).strip_edges().to_upper()
	if stype == "PREVIOUS" or region == "PREVIOUS":
		return {"ok": false, "special": "PREVIOUS"}
	if stype == "UNIT":
		var uid := str(scope.get("unit_id", "")).strip_edges()
		if not uid.is_empty():
			return {"ok": true, "expr": {"op": "UNIT", "unit_id": uid.to_upper()}}
		return {"ok": true, "expr": {"op": "SELECTED"}}
	if stype == "UNITS" or scope.has("unit_ids"):
		var uids: Array = []
		for x in (scope.get("unit_ids", []) as Array):
			uids.append(str(x).strip_edges().to_upper())
		return {"ok": true, "expr": {"op": "UNITS", "unit_ids": uids}}
	if region == "SELECTED":
		return {"ok": true, "expr": {"op": "SELECTED"}}
	if stype == "ALL_AVAILABLE":
		if cls.is_empty() or cls == "ALL_ARMS":
			return {"ok": true, "expr": {"op": "ALL_COMBAT"}}
		return {"ok": true, "expr": {"op": "CLASS", "class": cls}}
	if stype == "UNION":
		return _compile_union(scope)
	# WING_CLASS / CLUSTER_CLASS / REGION / class-wide shapes.
	var class_node := {"op": "ALL_COMBAT"}
	if not cls.is_empty() and cls != "ALL_ARMS":
		class_node = {"op": "CLASS", "class": cls}
	if region in ["NORTH", "CENTER", "SOUTH", "WEST", "EAST"]:
		return {"ok": true, "expr": {"op": "INTERSECT",
			"args": [{"op": "REGION", "region": region}, class_node]}}
	if region in ["LEFT", "CENTER", "RIGHT", "EXTREME_LEFT", "EXTREME_RIGHT"]:
		return {"ok": true, "expr": {"op": "INTERSECT",
			"args": [{"op": "WING", "wing": region}, class_node]}}
	if CommandScript.is_valid_cluster_id(region):
		return {"ok": true, "expr": {"op": "INTERSECT",
			"args": [{"op": "CLUSTER", "cluster": region}, class_node]}}
	if region == "ALL" or region.is_empty():
		return {"ok": true, "expr": class_node}
	return {"ok": false, "why": "unknown legacy region '%s'" % str(scope.get("region", ""))}


## UNION legacy shape (regions[] x classes[]) -> n-ary UNION of INTERSECTs.
## regions may contain compositional ALL (= every macro wing).
static func _compile_union(scope: Dictionary) -> Dictionary:
	var regions: Array = (scope.get("regions", []) as Array).duplicate()
	var expanded: Array = []
	for r_val in regions:
		if str(r_val).strip_edges().to_upper() == "ALL":
			for w in ["LEFT", "CENTER", "RIGHT"]:
				if not w in expanded:
					expanded.append(w)
		elif not str(r_val) in expanded:
			expanded.append(str(r_val))
	var classes: Array = []
	for c_val in (scope.get("classes", []) as Array):
		var c := str(c_val).strip_edges().to_upper()
		if not c.is_empty() and not c in classes:
			classes.append(c)
	var single := str(scope.get("class", "")).strip_edges().to_upper()
	if classes.is_empty() and not single.is_empty():
		classes = [single]
	if classes.is_empty():
		classes = ["ALL_ARMS"]
	var terms: Array = []
	for cls in classes:
		var class_node := {"op": "ALL_COMBAT"}
		if cls != "ALL_ARMS":
			class_node = {"op": "CLASS", "class": cls}
		for r_val2 in expanded:
			var region := str(r_val2).strip_edges().to_upper()
			var wing_node := {}
			if region in ["LEFT", "CENTER", "RIGHT", "EXTREME_LEFT", "EXTREME_RIGHT"]:
				wing_node = {"op": "WING", "wing": region}
			elif CommandScript.is_valid_cluster_id(region):
				wing_node = {"op": "CLUSTER", "cluster": region}
			else:
				continue
			terms.append({"op": "INTERSECT", "args": [wing_node, class_node]})
	if terms.is_empty():
		return {"ok": false, "why": "UNION scope has no resolvable wings/bands"}
	if terms.size() == 1:
		return {"ok": true, "expr": terms[0]}
	return {"ok": true, "expr": {"op": "UNION", "args": terms}}
