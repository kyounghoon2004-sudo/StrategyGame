extends SceneTree

## Legacy-output capture: runs the CURRENT resolver over a battery of
## legacy scopes on the live scene, writes tools/.audit_legacy baseline
## JSON. After the algebra convergence, the equivalence probe diffs
## against this file. No LLM.

const OUT := "D:/Game development/Demon slayer/StrategyGame/tools/.audit_legacy_scopes.json"
const ResolverScript = preload("res://scripts/step7/step7_scope_resolver.gd")

var rows: Array = []


func _run_case(tag: String, fn: String, scope: Dictionary, deps: Dictionary) -> void:
	var res := {}
	if fn == "resolve":
		res = ResolverScript.resolve(scope, deps)
	else:
		res = ResolverScript.resolve_force(scope, deps)
	var row := {"tag": tag, "fn": fn, "scope": scope,
		"ok": bool(res.get("ok", false)),
		"unit_ids": (res.get("unit_ids", []) as Array).duplicate(),
		"total": int(res.get("total", 0)),
		"scope_label": str(res.get("scope_label", "")),
		"wings": (res.get("wings", []) as Array).duplicate(),
		"truncated": bool(res.get("truncated", false)),
		"fail_kind": str(res.get("fail_kind", "")),
		"fail_detail": str(res.get("fail_detail", "")),
		"empty_regions": (res.get("empty_regions", []) as Array).duplicate()}
	rows.append(row)


func _init() -> void:
	call_deferred("_run")


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
	for _i in range(30):
		await process_frame
	var um: RefCounted = integration.get("unit_manager")
	var sel := {}
	for u in um.call("get_all_units_including_garrisoned"):
		if u is Dictionary and str((u as Dictionary).get("id", "")) == "B_CAV_2":
			sel = u
	var deps := {"unit_manager": um, "selected_unit": sel}
	for cls in ["CAVALRY", "INFANTRY", "ARCHER", "SPEARMAN", "SCOUT", "SIEGE", "CONSCRIPT"]:
		_run_case("resolve_%s_ALL" % cls, "resolve",
			{"type": "WING_CLASS", "class": cls, "region": "ALL", "unit_id": ""}, deps)
		for region in ["LEFT", "CENTER", "RIGHT", "EXTREME_LEFT", "EXTREME_RIGHT", "L2", "C", "R2"]:
			_run_case("resolve_%s_%s" % [cls, region], "resolve",
				{"type": "WING_CLASS", "class": cls, "region": region, "unit_id": ""}, deps)
	_run_case("resolve_CAV_SELECTED", "resolve",
		{"type": "UNIT", "class": "CAVALRY", "region": "SELECTED", "unit_id": ""}, deps)
	_run_case("resolve_SCT_SELECTED", "resolve",
		{"type": "UNIT", "class": "SCOUT", "region": "SELECTED", "unit_id": ""}, deps)
	_run_case("resolve_HQ", "resolve",
		{"type": "WING_CLASS", "class": "HQ", "region": "ALL", "unit_id": ""}, deps)
	_run_case("force_ALL", "resolve_force",
		{"type": "ALL_AVAILABLE", "class": "ALL_ARMS", "region": "ALL"}, deps)
	_run_case("force_HOLD_CAV_LEFT", "resolve_force",
		{"type": "WING_CLASS", "class": "CAVALRY", "region": "LEFT"}, deps)
	_run_case("force_HOLD_INF_CENTER", "resolve_force",
		{"type": "WING_CLASS", "class": "INFANTRY", "region": "CENTER"}, deps)
	_run_case("force_HOLD_HQ", "resolve_force",
		{"type": "WING_CLASS", "class": "HQ", "region": "ALL"}, deps)
	_run_case("force_UNIT_named", "resolve_force",
		{"type": "UNIT", "class": "CAVALRY", "region": "", "unit_id": "B_CAV_4"}, deps)
	for cls2 in ["CAVALRY", "INFANTRY", "SCOUT", "HQ", "ALL_ARMS"]:
		var res: Dictionary = ResolverScript.resolve_union(["LEFT", "RIGHT"], cls2, deps)
		rows.append({"tag": "union_%s_LR" % cls2, "fn": "resolve_union",
			"ok": bool(res.get("ok", false)),
			"unit_ids": (res.get("unit_ids", []) as Array).duplicate(),
			"total": int(res.get("total", 0)),
			"scope_label": str(res.get("scope_label", "")),
			"wings": (res.get("wings", []) as Array).duplicate(),
			"truncated": bool(res.get("truncated", false)),
			"fail_kind": str(res.get("fail_kind", "")),
			"fail_detail": str(res.get("fail_detail", "")),
			"empty_regions": (res.get("empty_regions", []) as Array).duplicate()})
	var res_ex: Dictionary = ResolverScript.resolve_union(["EXTREME_LEFT"], "CAVALRY", deps)
	rows.append({"tag": "union_CAV_EXL", "fn": "resolve_union",
		"ok": bool(res_ex.get("ok", false)),
		"unit_ids": (res_ex.get("unit_ids", []) as Array).duplicate(),
		"total": int(res_ex.get("total", 0)),
		"scope_label": str(res_ex.get("scope_label", "")),
		"wings": (res_ex.get("wings", []) as Array).duplicate(),
		"truncated": bool(res_ex.get("truncated", false)),
		"fail_kind": str(res_ex.get("fail_kind", "")),
		"fail_detail": str(res_ex.get("fail_detail", "")),
		"empty_regions": (res_ex.get("empty_regions", []) as Array).duplicate()})
	var f := FileAccess.open(OUT, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({"rows": rows}))
		f.close()
		print("AUDIT_LEGACY_CAPTURED rows=%d" % rows.size())
	else:
		print("AUDIT_LEGACY_WRITE_FAILED")
	quit(0)
