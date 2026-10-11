class_name Step7ScopeResolver
extends RefCounted

## Godot-owned semantic scope resolution (no language parsing here).
##
## Legacy scope dicts (class + region) compile to set-algebra expressions
## via Step7ScopeAlgebra.compile_legacy; ALL membership resolves through
## Step7ScopeAlgebra.resolve — the ONE membership authority. Thin wrappers
## here keep the legacy contract: Korean labels, ambiguity gates, caps,
## fail_kinds. The model can never invent membership: unknown regions,
## empty bands, and unsupported classes fail honestly.
##
## Ambiguity rule (§15/45): region ALL (or empty) with BLUE cavalry spread
## over more than one macro wing and no selected-unit context is NOT guessed
## — it returns needs_clarify with the distinct wings for the question.

const ClustersScript = preload("res://scripts/step7/step7_formation_clusters.gd")
const IntentScript = preload("res://scripts/step7/step7_chat_intent.gd")
const DoctrinesScript = preload("res://scripts/step7/step7_unit_doctrines.gd")
const ViewModelScript = preload("res://scripts/step7/step7_advisor_viewmodel.gd")
const AlgebraScript = preload("res://scripts/step7/step7_scope_algebra.gd")

const SUPPORTED_CLASS := "CAVALRY"

## NOTE (retired cap): staging caps used to slice membership here
## (MAX_SCOPE_UNITS). The semantic set is now NEVER truncated: HOLDs
## execute sequentially per unit, and doctrine selection runs in chunks.
## The `truncated` result key stays (always false) for contract stability.


static func _ids(units: Array) -> Array:
	var out: Array = []
	for u in units:
		out.append(str((u as Dictionary).get("id", "")))
	out.sort()
	return out


## Distinct macro wings holding the given unit dicts (LEFT/CENTER/RIGHT).
static func wings_of(units: Array) -> Array:
	var seen := {}
	for u_val in units:
		if not u_val is Dictionary:
			continue
		var cid := ClustersScript.cluster_of_unit(u_val)
		if cid.is_empty():
			continue
		var w := ClustersScript.wing_of_cluster(cid)
		if not str(w).is_empty():
			seen[str(w)] = true
	var out: Array = seen.keys()
	out.sort()
	return out


## Resolve a validated intent scope to live unit IDs for ANY doctrine class.
## deps: {unit_manager, selected_unit}.
## Membership comes from Step7ScopeAlgebra (ONE authority); this wrapper
## keeps the legacy contract: labels, ambiguity gate, caps, fail_kinds.
## Returns {ok, unit_ids, total, scope_label, wings, truncated} or
## {ok:false, fail_kind, fail_detail, wings}.
## fail_kind: UNSUPPORTED_CLASS | NO_SELECTION | NOT_CLASS_SELECTION |
##   EMPTY_SCOPE | AMBIGUOUS | UNKNOWN_REGION
static func resolve(scope: Dictionary, deps: Dictionary) -> Dictionary:
	var cls := str(scope.get("class", SUPPORTED_CLASS)).strip_edges().to_upper()
	if not DoctrinesScript.is_doctrine_class(cls):
		return {"ok": false, "fail_kind": "UNSUPPORTED_CLASS",
			"fail_detail": cls, "wings": []}
	var region := str(scope.get("region", "ALL")).strip_edges().to_upper()
	var um: RefCounted = deps.get("unit_manager") as RefCounted
	var sel: Dictionary = deps.get("selected_unit", {})
	var kr := ViewModelScript.class_kr(cls)
	if region == "SELECTED":
		if sel.is_empty():
			return {"ok": false, "fail_kind": "NO_SELECTION",
				"fail_detail": "no map-selected unit", "wings": []}
		if str(sel.get("faction", "")) != "blue":
			return {"ok": false, "fail_kind": "NO_SELECTION",
				"fail_detail": "selected unit is not BLUE", "wings": []}
		if str(sel.get("class", "")).to_upper() != cls:
			return {"ok": false, "fail_kind": "NOT_CLASS_SELECTION",
				"fail_detail": str(sel.get("class", "?")), "wings": []}
		var sid := str(sel.get("id", ""))
		var cid := ClustersScript.cluster_of_unit(sel)
		return {"ok": true, "unit_ids": [sid], "total": 1,
			"scope_label": "선택 %s %s (%s)" % [kr, sid, cid if not cid.is_empty() else "구역 확인 중"],
			"wings": wings_of([sel]), "truncated": false}
	var roster := units_of_class(cls, um)
	if roster.is_empty():
		return {"ok": false, "fail_kind": "EMPTY_SCOPE",
			"fail_detail": "no BLUE %s on the field" % cls, "wings": []}
	# Labels stay wrapper-side (presentation); the SET comes from the
	# compiled legacy expression through the ONE algebra resolver.
	var compiled := AlgebraScript.compile_legacy(scope)
	if not bool(compiled.get("ok", false)):
		return {"ok": false, "fail_kind": "UNKNOWN_REGION",
			"fail_detail": str(compiled.get("why", region)), "wings": []}
	var expr: Dictionary = compiled.get("expr", {})
	var label := ""
	if region == "ALL":
		label = "전군 %s" % kr
	elif region in ["LEFT", "CENTER", "RIGHT"]:
		label = {"LEFT": "좌익 %s", "CENTER": "중앙 %s", "RIGHT": "우익 %s"}.get(region, region) % kr
	elif region == "EXTREME_LEFT":
		var ex := ClustersScript.extreme_left()
		if ex.is_empty():
			return {"ok": false, "fail_kind": "EMPTY_SCOPE",
				"fail_detail": "no left bands", "wings": []}
		label = "극좌익 %s (%s)" % [kr, ex]
	elif region == "EXTREME_RIGHT":
		var ex2 := ClustersScript.extreme_right()
		if ex2.is_empty():
			return {"ok": false, "fail_kind": "EMPTY_SCOPE",
				"fail_detail": "no right bands", "wings": []}
		label = "극우익 %s (%s)" % [kr, ex2]
	elif IntentScript.is_concrete_band(region):
		label = "%s 구역 %s" % [region, kr]
	else:
		return {"ok": false, "fail_kind": "UNKNOWN_REGION",
			"fail_detail": region, "wings": []}
	var got := AlgebraScript.resolve(expr, deps)
	if bool(got.get("empty", true)):
		return {"ok": false, "fail_kind": "EMPTY_SCOPE",
			"fail_detail": label, "wings": []}
	var wings: Array = (got.get("wings", []) as Array).duplicate()
	if region == "ALL" and wings.size() > 1:
		return {"ok": false, "fail_kind": "AMBIGUOUS",
			"fail_detail": "cavalry in %d wings" % wings.size(), "wings": wings}
	var ids: Array = (got.get("unit_ids", []) as Array).duplicate()
	var total := int(got.get("total", ids.size()))
	return {"ok": true, "unit_ids": ids, "total": total,
		"scope_label": label, "wings": wings, "truncated": false}


## All live BLUE combat formations (any anchor class), id order. Used by
## HOLD / whole-force paths and the tactical layout table. Non-combat
## classes (HQ/SUPPLY) are excluded: they are never chat-maneuvered.
static func blue_force(unit_manager: RefCounted) -> Array:
	if unit_manager == null or not unit_manager.has_method("get_all_units_including_garrisoned"):
		return []
	var out: Array = []
	for u_val in (unit_manager.get_all_units_including_garrisoned() as Array):
		if not u_val is Dictionary:
			continue
		var u: Dictionary = u_val
		if str(u.get("faction", "")) != "blue":
			continue
		if not str(u.get("class", "")).to_upper() in ClustersScript.ANCHOR_CLASSES:
			continue
		if int(u.get("soldier_count", 0)) <= 0:
			continue
		if bool(u.get("garrisoned", false)) or bool(u.get("routed", false)):
			continue
		out.append(u)
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a.get("id", "")) < str(b.get("id", "")))
	return out


## Live BLUE units of one class (any anchor class), id order. The roster
## primitive behind class-wide chat scopes for every doctrine class.
static func units_of_class(cls: String, unit_manager: RefCounted) -> Array:
	var want := cls.strip_edges().to_upper()
	var out: Array = []
	for u in blue_force(unit_manager):
		if str((u as Dictionary).get("class", "")).to_upper() == want:
			out.append(u)
	return out


## Single live BLUE unit by id (any class). Empty Dictionary when unknown.
static func find_unit(uid: String, unit_manager: RefCounted) -> Dictionary:
	var want := uid.strip_edges().to_upper()
	if want.is_empty() or unit_manager == null:
		return {}
	if not unit_manager.has_method("get_all_units_including_garrisoned"):
		return {}
	for u_val in (unit_manager.get_all_units_including_garrisoned() as Array):
		if u_val is Dictionary and str((u_val as Dictionary).get("id", "")).to_upper() == want:
			return u_val
	return {}


## Class-aware scope resolution for non-LLM paths (HOLD, whole-force).
## Handles ALL_AVAILABLE (optionally class-filtered), UNIT (named or
## SELECTED), and class-filtered regions over the live roster.
## Membership comes from Step7ScopeAlgebra (ONE authority); the legacy
## contract (labels, caps, fail_kinds) is preserved, including two parity
## quirks: non-anchor classes (HQ/SUPPLY) resolve EMPTY over region
## branches (they never belonged to the BLUE maneuver pool), and a bare
## ALL_ARMS region (no UNION/ALL shape) resolves EMPTY. Returns the
## resolve() shape.
static func resolve_force(scope: Dictionary, deps: Dictionary) -> Dictionary:
	var um: RefCounted = deps.get("unit_manager") as RefCounted
	var cls := str(scope.get("class", "ALL_ARMS")).strip_edges().to_upper()
	var region := str(scope.get("region", "ALL")).strip_edges().to_upper()
	var stype := str(scope.get("type", "")).strip_edges().to_upper()
	if stype == "UNION":
		return resolve_union((scope.get("regions", []) as Array).duplicate(),
			cls if not cls.is_empty() else "ALL_ARMS", deps)
	if stype == "ALL_AVAILABLE" or region == "ALL":
		var compiled0 := AlgebraScript.compile_legacy(scope)
		if not bool(compiled0.get("ok", false)):
			return {"ok": false, "fail_kind": "EMPTY_SCOPE",
				"fail_detail": "no live BLUE formations", "wings": []}
		var got := AlgebraScript.resolve(compiled0.get("expr", {}), deps)
		if bool(got.get("empty", true)):
			return {"ok": false, "fail_kind": "EMPTY_SCOPE",
				"fail_detail": "no live BLUE formations", "wings": []}
		var ids: Array = (got.get("unit_ids", []) as Array).duplicate()
		var total := int(got.get("total", ids.size()))
		return {"ok": true, "unit_ids": ids, "total": total,
			"scope_label": "전군", "wings": (got.get("wings", []) as Array).duplicate(),
			"truncated": false}
	if stype == "UNIT" or region == "SELECTED":
		var sel: Dictionary = deps.get("selected_unit", {})
		var uid := str(scope.get("unit_id", "")).strip_edges()
		var target: Dictionary = find_unit(uid, um) if not uid.is_empty() else sel
		if target.is_empty():
			return {"ok": false, "fail_kind": "NO_SELECTION",
				"fail_detail": "no such unit", "wings": []}
		if str(target.get("faction", "")) != "blue":
			return {"ok": false, "fail_kind": "NO_SELECTION",
				"fail_detail": "not BLUE", "wings": []}
		var tid := str(target.get("id", ""))
		var cid := ClustersScript.cluster_of_unit(target)
		return {"ok": true, "unit_ids": [tid],
			"scope_label": "선택 부대 %s (%s)" % [tid, cid if not cid.is_empty() else "구역 확인 중"],
			"wings": wings_of([target]), "truncated": false}
	# Class-filtered region (legacy parity noted above).
	if cls == "ALL_ARMS" or (not cls in ClustersScript.ANCHOR_CLASSES and cls != SUPPORTED_CLASS):
		if cls == SUPPORTED_CLASS:
			return resolve(scope, deps)
		return {"ok": false, "fail_kind": "EMPTY_SCOPE",
			"fail_detail": region, "wings": []}
	if cls == SUPPORTED_CLASS:
		return resolve(scope, deps)
	var label := ""
	if region in ["LEFT", "CENTER", "RIGHT"]:
		label = {"LEFT": "좌익", "CENTER": "중앙", "RIGHT": "우익"}.get(region, region)
	elif region in ["EXTREME_LEFT", "EXTREME_RIGHT"]:
		var ex := ClustersScript.extreme_left() if region == "EXTREME_LEFT" else ClustersScript.extreme_right()
		if ex.is_empty():
			return {"ok": false, "fail_kind": "EMPTY_SCOPE",
				"fail_detail": "no bands", "wings": []}
		label = ex
	elif IntentScript.is_concrete_band(region):
		label = region
	else:
		return {"ok": false, "fail_kind": "UNKNOWN_REGION",
			"fail_detail": region, "wings": []}
	# Membership from the compiled legacy expression (ONE resolver).
	var compiled2 := AlgebraScript.compile_legacy(scope)
	if not bool(compiled2.get("ok", false)):
		return {"ok": false, "fail_kind": "UNKNOWN_REGION",
			"fail_detail": str(compiled2.get("why", region)), "wings": []}
	var got2 := AlgebraScript.resolve(compiled2.get("expr", {}), deps)
	if bool(got2.get("empty", true)):
		return {"ok": false, "fail_kind": "EMPTY_SCOPE",
			"fail_detail": label, "wings": []}
	var ids2: Array = (got2.get("unit_ids", []) as Array).duplicate()
	return {"ok": true, "unit_ids": ids2, "total": int(got2.get("total", ids2.size())),
		"scope_label": label, "wings": (got2.get("wings", []) as Array).duplicate(),
		"truncated": false}


## Multi-region union (UNION scope, "both" answers): resolve each wing/band
## intersected with the class through the algebra (ONE authority) and
## merge to ONE deterministic unit set. Empty regions contribute
## nothing but are reported; fully-empty unions fail honestly. Order and
## cap rules match resolve(). Legacy parity: non-anchor classes
## (HQ/SUPPLY) resolve EMPTY (they never belonged to the maneuver pool).
static func resolve_union(regions: Array, cls: String, deps: Dictionary) -> Dictionary:
	var want_cls := cls.strip_edges().to_upper()
	if want_cls.is_empty():
		want_cls = SUPPORTED_CLASS
	if want_cls != SUPPORTED_CLASS and want_cls != "ALL_ARMS" \
			and not DoctrinesScript.is_doctrine_class(want_cls):
		return {"ok": false, "fail_kind": "EMPTY_SCOPE",
			"fail_detail": "union has no live units", "wings": []}
	# Compositional ALL: regions ["ALL"] (multi-class orders with no wing
	# named, e.g. "보병과 창병 둘 다 전진") expands to every macro wing.
	# Macro wings cover all bands (LEFT = every L*, incl. extremes), so
	# nothing is silently narrowed; classes[]/class still restricts arms.
	var wings_all := ["LEFT", "CENTER", "RIGHT"]
	var expanded: Array = []
	for r_val in regions:
		if str(r_val).strip_edges().to_upper() == "ALL":
			for w in wings_all:
				if not w in expanded:
					expanded.append(w)
		elif not str(r_val) in expanded:
			expanded.append(str(r_val))
	# Per-region terms compile through the legacy compiler (ONE
	# construction site); each resolves through the algebra so empty
	# regions stay reportable; the merge is a UNION.
	var terms: Array = []
	var term_labels: Array = []
	for r_val2 in expanded:
		var region := str(r_val2).strip_edges().to_upper()
		var label := region
		if region in ["LEFT", "CENTER", "RIGHT"]:
			label = str({"LEFT": "좌익", "CENTER": "중앙", "RIGHT": "우익"}.get(region, region))
		elif region in ["EXTREME_LEFT", "EXTREME_RIGHT"]:
			var ex := ClustersScript.extreme_left() if region == "EXTREME_LEFT" else ClustersScript.extreme_right()
			if ex.is_empty():
				continue
			label = ex
		elif IntentScript.is_concrete_band(region):
			label = region
		else:
			continue
		var one := AlgebraScript.compile_legacy({"type": "WING_CLASS",
			"class": want_cls, "region": region, "unit_id": ""})
		if not bool(one.get("ok", false)):
			continue
		terms.append(one.get("expr", {}))
		term_labels.append(label)
	var merged: Array = []
	var seen := {}
	var empty_parts: Array = []
	var label_parts: Array = []
	var wing_set := {}
	var ti := 0
	for term in terms:
		var part := AlgebraScript.resolve(term, deps)
		var tlabel := str(term_labels[ti])
		ti += 1
		var part_ids: Array = part.get("unit_ids", [])
		if part_ids.is_empty():
			empty_parts.append(tlabel)
			continue
		label_parts.append(tlabel)
		for w2 in (part.get("wings", []) as Array):
			wing_set[str(w2)] = true
		for uid in part_ids:
			if not seen.has(str(uid)):
				seen[str(uid)] = true
				merged.append(str(uid))
	if merged.is_empty():
		return {"ok": false, "fail_kind": "EMPTY_SCOPE",
			"fail_detail": "union has no live units", "wings": []}
	merged.sort()
	var ids := merged.duplicate()
	var cls_label := "기병" if want_cls == SUPPORTED_CLASS else ("전 병력" if want_cls == "ALL_ARMS" else want_cls)
	var wing_list: Array = wing_set.keys()
	wing_list.sort()
	return {"ok": true, "unit_ids": ids, "total": merged.size(),
		"scope_label": "%s (%s)" % ["·".join(label_parts), cls_label],
		"wings": wing_list, "truncated": false,
		"empty_regions": empty_parts}


## One-line Korean wing list for clarification questions.
static func wings_kr(wings: Array) -> String:
	var names := {"LEFT": "좌익", "CENTER": "중앙", "RIGHT": "우익"}
	var out: Array = []
	for w in wings:
		out.append(str(names.get(str(w), str(w))))
	return ", ".join(out)
