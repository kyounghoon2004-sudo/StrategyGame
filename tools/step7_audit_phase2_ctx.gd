extends SceneTree

## Audit Phase-2 context capture: builds REAL evaluator packages +
## representative BLUE context + the EXACT Phase-2 user block the commander
## would send, for two cases (3-scout RECON, 8-mixed ADVANCE UNION-ALL).
## Dumps tools/.audit_phase2_ctx.json for the Python live-selection probe.
## No LLM here.

const OUT := "D:/Game development/Demon slayer/StrategyGame/tools/.audit_phase2_ctx.json"

const EvaluatorScript = preload("res://scripts/step7/step7_cavalry_evaluator.gd")
const ClustersScript = preload("res://scripts/step7/step7_formation_clusters.gd")
const ContextScript = preload("res://scripts/step7/step7_advisor_context.gd")
const IntentScript = preload("res://scripts/step7/step7_chat_intent.gd")
const ResolverScript = preload("res://scripts/step7/step7_scope_resolver.gd")
const CommanderScript = preload("res://scripts/step7/step7_chat_commander.gd")


func _init() -> void:
	call_deferred("_run")


func _unit_dict(uid: String, um: RefCounted) -> Dictionary:
	for u in ResolverScript.blue_force(um):
		if str((u as Dictionary).get("id", "")) == uid:
			return u
	return {"id": uid}


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
		print("AUDIT_P2CTX: integration not ready")
		quit(2)
		return
	for _i in range(30):
		await process_frame
	var command_service: RefCounted = integration.get("command_service")
	var projector: RefCounted = integration.get("projector")
	var truth: RefCounted = integration.get("truth")
	var um: RefCounted = integration.get("unit_manager")
	var bk: Dictionary = integration.call("get_blue_knowledge")
	var occ: Dictionary = projector.known_occupancy("blue")
	var grid: Node = integration.get("hex_grid") as Node
	var cell_data: Dictionary = grid.get("cell_data") as Dictionary if grid else {}
	var evaluator: RefCounted = EvaluatorScript.new()
	var cases := {}
	# Case 1: LEFT scouts RECON (mirrors E_scout_recon).
	var res1 := ResolverScript.resolve(
		{"type": "WING_CLASS", "class": "SCOUT", "region": "LEFT", "unit_id": ""},
		{"unit_manager": um, "selected_unit": {}})
	cases["scout_recon"] = _build_case("scout_recon", evaluator,
		{"action": "RECON", "direction": "FORWARD"},
		{"request_type": "COMMAND", "action": "RECON",
			"scope": {"type": "WING_CLASS", "class": "SCOUT", "region": "LEFT", "unit_id": "", "regions": [], "classes": []},
			"style": {"risk": "balanced", "pressure": "balanced", "depth": "normal"},
			"confidence": 0.95, "question": "", "missing": []},
		(res1.get("unit_ids", []) as Array).duplicate(),
		command_service, bk, cell_data, occ, truth, um)
	# Case 2: INF+SPE UNION-ALL ADVANCE (mirrors E_multi, capped like router).
	var res2 := ResolverScript.resolve_union(["LEFT", "CENTER", "RIGHT"], "INFANTRY",
		{"unit_manager": um, "selected_unit": {}})
	var res3 := ResolverScript.resolve_union(["LEFT", "CENTER", "RIGHT"], "SPEARMAN",
		{"unit_manager": um, "selected_unit": {}})
	var merged: Array = []
	var seen := {}
	for uid in (res2.get("unit_ids", []) as Array) + (res3.get("unit_ids", []) as Array):
		if not seen.has(str(uid)):
			seen[str(uid)] = true
			merged.append(str(uid))
	merged.sort()
	if merged.size() > ResolverScript.MAX_SCOPE_UNITS:
		merged = merged.slice(0, ResolverScript.MAX_SCOPE_UNITS)
	cases["multi_advance"] = _build_case("multi_advance", evaluator,
		{"action": "ADVANCE", "direction": "FORWARD"},
		{"request_type": "COMMAND", "action": "ADVANCE",
			"scope": {"type": "UNION", "class": "CAVALRY", "region": "", "unit_id": "", "regions": ["ALL"], "classes": ["INFANTRY", "SPEARMAN"]},
			"style": {"risk": "balanced", "pressure": "balanced", "depth": "normal"},
			"confidence": 0.9, "question": "", "missing": []},
		merged, command_service, bk, cell_data, occ, truth, um)
	var out := {"select_system": IntentScript.SELECT_SYSTEM_PROMPT, "cases": cases}
	var f := FileAccess.open(OUT, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(out))
		f.close()
		print("AUDIT_P2CTX_WRITTEN scout=%d multi=%d" % [
			((cases["scout_recon"] as Dictionary).get("unit_ids", []) as Array).size(),
			((cases["multi_advance"] as Dictionary).get("unit_ids", []) as Array).size()])
	else:
		print("AUDIT_P2CTX_WRITE_FAILED")
	quit(0)


func _build_case(tag: String, evaluator: RefCounted, move_intent: Dictionary,
		intent: Dictionary, unit_ids: Array, command_service: RefCounted,
		bk: Dictionary, cell_data: Dictionary, occ: Dictionary,
		truth: RefCounted, um: RefCounted) -> Dictionary:
	var pkgs := {}
	for uid in unit_ids:
		var pkg: Dictionary = evaluator.evaluate(str(uid), move_intent,
			command_service, bk, cell_data, occ,
			int(truth.call("get_version")), str(truth.call("fingerprint")))
		if bool(pkg.get("ok", false)) and not (pkg.get("options", []) as Array).is_empty():
			pkgs[str(uid)] = pkg
	# Representative = furthest along FORWARD axis (mirrors commander).
	var best := ""
	var best_q := -(1 << 30)
	for uid in pkgs.keys():
		var u := _unit_dict(str(uid), um)
		var q := int(u.get("q", 0))
		if best.is_empty() or q > best_q or (q == best_q and str(uid) < best):
			best = str(uid)
			best_q = q
	var rep_pkg: Dictionary = pkgs[best]
	var rep_unit := _unit_dict(best, um)
	var built: Dictionary = ContextScript.build({
		"package": rep_pkg, "unit": rep_unit, "blue_knowledge": bk,
		"cell_data": cell_data, "intent": move_intent,
		"state_version": int(truth.call("get_version")),
		"fingerprint": str(truth.call("fingerprint")),
		"cluster_signature": ClustersScript.frozen_signature(),
		"request_id": "audit-" + tag,
	})
	var ctx: Dictionary = built.get("context", {})
	var enemies: Dictionary = ctx.get("authorized_enemy_knowledge", {})
	# EXACT live slimming: borrow the commander's own _slim_packages over a
	# bare instance (needs only _unit_manager). No duplicated transform.
	var cmdr = CommanderScript.new()
	cmdr.set("_unit_manager", um)
	var slim: Array = cmdr._slim_packages({"packages": pkgs})
	cmdr.queue_free()
	var user_block := {
		"command_id": "audit-" + tag,
		"mode": "STAGE_FOR_APPROVAL",
		"player_message": "AUDIT",
		"semantic_intent": intent,
		"resolved_scope": {"label": tag, "unit_ids": pkgs.keys()},
		"packages": slim,
		"enemy_summary": {"current_visible": (enemies.get("current_visible", []) as Array).size(),
			"stale_last_known": (enemies.get("stale_last_known", []) as Array).size(),
			"contacts": enemies.get("current_visible", [])},
		"prior_note": "",
		"recent_history": [],
		"order": "Select one legal realization PER unit for STAGING. Nothing moves on your answer; the commander approves on the map. JSON only.",
	}
	return {"unit_ids": pkgs.keys(), "packages": pkgs,
		"user_text": "TACTICAL_SELECTION_JSON:\n" + JSON.stringify(user_block)}
