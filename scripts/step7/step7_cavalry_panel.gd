class_name Step7CavalryPanel
extends VBoxContainer

## DEV-ONLY cavalry tactical inspector (SB-CAVALRY-EVALUATOR §33–34).
## Mounted inside the deterministic DEV panel; never production UI.
## Reads map selection, evaluates six profiles, shows breakdown, previews
## route on the shared overlay, executes via the canonical ActionService.

const EvaluatorScript = preload("res://scripts/step7/step7_cavalry_evaluator.gd")
const ClustersScript = preload("res://scripts/step7/step7_formation_clusters.gd")

var _integration: Node = null
var _truth: RefCounted = null
var _command_service: RefCounted = null
var _projector: RefCounted = null
var _action_service: RefCounted = null
var _overlay: Node2D = null
var _unit_manager: RefCounted = null
var _evaluator: RefCounted = null

var _intent_btn: OptionButton = null
var _eval_btn: Button = null
var _exec_btn: Button = null
var _cluster_btn: OptionButton = null
var _cluster_eval_btn: Button = null
var _wing_btn: OptionButton = null
var _wing_eval_btn: Button = null
var _status: Label = null
var _rows: VBoxContainer = null
var _detail: RichTextLabel = null
var _result: Dictionary = {}
var _picked: int = -1


func setup(deps: Dictionary) -> void:
	_integration = deps.get("integration") as Node
	_truth = deps.get("truth") as RefCounted
	_command_service = deps.get("command_service") as RefCounted
	_projector = deps.get("projector") as RefCounted
	_action_service = deps.get("action_service") as RefCounted
	_overlay = deps.get("overlay") as Node2D
	_unit_manager = deps.get("unit_manager") as RefCounted
	_evaluator = EvaluatorScript.new()
	_build()


func _build() -> void:
	add_theme_constant_override("separation", 2)
	var h := Label.new()
	h.text = "CAVALRY TACTICAL OPTIONS (DEV)"
	h.add_theme_font_size_override("font_size", 13)
	add_child(h)
	var row := HBoxContainer.new()
	add_child(row)
	_intent_btn = OptionButton.new()
	_intent_btn.add_item("ADVANCE FORWARD")
	_intent_btn.add_item("FLANK RIGHT")
	row.add_child(_intent_btn)
	_eval_btn = Button.new()
	_eval_btn.text = "EVALUATE"
	_eval_btn.pressed.connect(_on_evaluate)
	row.add_child(_eval_btn)
	_exec_btn = Button.new()
	_exec_btn.text = "EXECUTE PICK"
	_exec_btn.disabled = true
	_exec_btn.pressed.connect(_on_execute)
	row.add_child(_exec_btn)
	var cluster_row := HBoxContainer.new()
	add_child(cluster_row)
	_cluster_btn = OptionButton.new()
	cluster_row.add_child(_cluster_btn)
	_cluster_eval_btn = Button.new()
	_cluster_eval_btn.text = "EVALUATE CLUSTER"
	_cluster_eval_btn.pressed.connect(_on_evaluate_cluster)
	cluster_row.add_child(_cluster_eval_btn)
	var wing_row := HBoxContainer.new()
	add_child(wing_row)
	_wing_btn = OptionButton.new()
	for w in ["LEFT", "CENTER", "RIGHT", "EXTREME_LEFT", "EXTREME_RIGHT"]:
		_wing_btn.add_item(w)
	wing_row.add_child(_wing_btn)
	_wing_eval_btn = Button.new()
	_wing_eval_btn.text = "EVALUATE WING"
	_wing_eval_btn.pressed.connect(_on_evaluate_wing)
	wing_row.add_child(_wing_eval_btn)
	_refresh_cluster_options()
	_status = Label.new()
	_status.text = "Select a cavalry formation on the map."
	_status.add_theme_font_size_override("font_size", 11)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_status)
	_rows = VBoxContainer.new()
	add_child(_rows)
	_detail = RichTextLabel.new()
	_detail.custom_minimum_size = Vector2(0, 150)
	_detail.scroll_following = false
	_detail.bbcode_enabled = true
	add_child(_detail)


func _selected_cavalry() -> Dictionary:
	if _unit_manager == null or not _unit_manager.has_method("is_unit_selected"):
		return {}
	if not bool(_unit_manager.is_unit_selected()):
		return {}
	var u: Dictionary = _unit_manager.get_selected_unit()
	if str(u.get("class", "")).to_lower() != "cavalry":
		return {}
	if str(u.get("faction", "")) != "blue":
		return {}
	return u


func _on_evaluate() -> void:
	for c in _rows.get_children():
		c.queue_free()
	_picked = -1
	_exec_btn.disabled = true
	var u := _selected_cavalry()
	if u.is_empty():
		_status.text = "Select a BLUE cavalry formation on the map first."
		return
	var intent := {"action": "ADVANCE", "direction": "FORWARD"}
	if _intent_btn.selected == 1:
		intent = {"action": "FLANK", "direction": "RIGHT"}
	var bk: Dictionary = _integration.call("get_blue_knowledge")
	var occ: Dictionary = _projector.known_occupancy("blue")
	var grid: Node = _integration.get("hex_grid") as Node
	var cell_data: Dictionary = grid.get("cell_data") as Dictionary if grid else {}
	_result = _evaluator.evaluate(str(u.get("id", "")), intent,
		_command_service, bk, cell_data, occ,
		int(_truth.get_version()), str(_truth.fingerprint()))
	if not bool(_result.get("ok", false)):
		_status.text = "Evaluate failed: " + str(_result.get("error", "?"))
		return
	var lat: Dictionary = _result.get("latency", {})
	_status.text = "unit=%s candidates=%d total=%.0fms (reach=%.0f route=%.0f feat=%.0f heads=%.0f)%s" % [
		str(_result.get("unit_id", "?")), int(_result.get("candidate_count", 0)),
		float(lat.get("total_ms", 0.0)), float(lat.get("reachability_ms", 0.0)),
		float(lat.get("route_resolution_ms", 0.0)), float(lat.get("feature_extraction_ms", 0.0)),
		float(lat.get("six_profile_scoring_ms", 0.0)),
		" cache=HIT" if bool(_result.get("cache_hit", false)) else ""]
	for o_val in (_result.get("options", []) as Array):
		var o: Dictionary = o_val
		var b := Button.new()
		var dest: Dictionary = o.get("destination", {})
		var rk: Dictionary = o.get("risk", {})
		var dest_txt := "(—)"
		if not dest.is_empty():
			dest_txt = "(%d,%d)" % [int(dest.get("q", 0)), int(dest.get("r", 0))]
		b.text = "%d %s — %s %s u=%.2f risk=%.2f" % [int(o.get("slot", 0)),
			str(o.get("profile", "?")), str(o.get("status", "?")), dest_txt,
			float(o.get("utility", 0.0)), float(rk.get("overall", 0.0))]
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		var idx := int(o.get("slot", 0)) - 1
		b.pressed.connect(func() -> void: _on_pick(idx))
		_rows.add_child(b)


## Cluster controls are generated from the live frozen geometry (§20):
## one button row per active cluster id, plus macro wing aliases. No
## hard-coded LEFT/CENTER/RIGHT sector authority remains in this panel.
func _refresh_cluster_options() -> void:
	_ensure_clusters()
	_cluster_btn.clear()
	var ids: Array = ClustersScript.cluster_ids()
	if ids.is_empty():
		_cluster_btn.add_item("(no clusters)")
	else:
		for cid in ids:
			_cluster_btn.add_item(str(cid))


func _ensure_clusters() -> void:
	if ClustersScript.is_built() or _unit_manager == null or _truth == null:
		return
	var live: Array = []
	for u_val in _unit_manager.get_all_units_including_garrisoned():
		if u_val is Dictionary and str((u_val as Dictionary).get("faction", "")) == "blue":
			live.append(u_val)
	ClustersScript.refresh(live, int(_truth.get_turn()))


func _cluster_ctx() -> Dictionary:
	var bk: Dictionary = _integration.call("get_blue_knowledge")
	var occ: Dictionary = _projector.known_occupancy("blue")
	var grid: Node = _integration.get("hex_grid") as Node
	var cell_data: Dictionary = grid.get("cell_data") as Dictionary if grid else {}
	return {"bk": bk, "occ": occ, "cell_data": cell_data}


func _show_package(pkg: Dictionary, scope_txt: String) -> void:
	_result = pkg
	var members: Array = pkg.get("member_ids", [])
	_status.text = "%s + CAVALRY -> [%s] rep=%s" % [scope_txt,
		", ".join(members) if not members.is_empty() else "(empty scope)",
		str(pkg.get("representative", "—"))]
	for o_val in (pkg.get("options", []) as Array):
		var o: Dictionary = o_val
		var b := Button.new()
		var dest: Dictionary = o.get("destination", {})
		var rk: Dictionary = o.get("risk", {})
		var dest_txt := "(—)"
		if not dest.is_empty():
			dest_txt = "(%d,%d)" % [int(dest.get("q", 0)), int(dest.get("r", 0))]
		b.text = "%d %s — %s %s u=%.2f risk=%.2f" % [int(o.get("slot", 0)),
			str(o.get("profile", "?")), str(o.get("status", "?")), dest_txt,
			float(o.get("utility", 0.0)), float(rk.get("overall", 0.0))]
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		var idx := int(o.get("slot", 0)) - 1
		b.pressed.connect(func() -> void: _on_pick(idx))
		_rows.add_child(b)


func _current_intent() -> Dictionary:
	var intent := {"action": "ADVANCE", "direction": "FORWARD"}
	if _intent_btn.selected == 1:
		intent = {"action": "FLANK", "direction": "RIGHT"}
	return intent


## Adaptive cluster evaluation: resolve FORMATION_CLUSTER_CLASS to live
## cavalry, evaluate the deterministic representative. Group optimization
## stays deferred — the package names all members and the representative.
func _on_evaluate_cluster() -> void:
	for c in _rows.get_children():
		c.queue_free()
	_picked = -1
	_exec_btn.disabled = true
	_refresh_cluster_options()
	var ids: Array = ClustersScript.cluster_ids()
	if ids.is_empty():
		_status.text = "No frozen cluster geometry (refresh at turn start)."
		return
	var cid: String = str(ids[clampi(_cluster_btn.selected, 0, ids.size() - 1)])
	var ctx := _cluster_ctx()
	var pkg: Dictionary = _evaluator.evaluate_cluster(cid, _current_intent(),
		_command_service, _unit_manager, ctx["bk"], ctx["cell_data"], ctx["occ"],
		int(_truth.get_version()), str(_truth.fingerprint()))
	_show_package(pkg, cid)


## Macro wing evaluation: LEFT = all L*, CENTER = C, RIGHT = all R*,
## EXTREME_* = outermost band. Scope purity holds by union (§38).
func _on_evaluate_wing() -> void:
	for c in _rows.get_children():
		c.queue_free()
	_picked = -1
	_exec_btn.disabled = true
	_refresh_cluster_options()
	var wing: String = str(_wing_btn.get_item_text(_wing_btn.selected))
	var ctx := _cluster_ctx()
	var pkg: Dictionary = {}
	if wing in ["EXTREME_LEFT", "EXTREME_RIGHT"]:
		var extreme := ClustersScript.extreme_left() if wing == "EXTREME_LEFT" else ClustersScript.extreme_right()
		if extreme.is_empty():
			_status.text = "%s: no live band on that side." % wing
			return
		pkg = _evaluator.evaluate_cluster(extreme, _current_intent(),
			_command_service, _unit_manager, ctx["bk"], ctx["cell_data"], ctx["occ"],
			int(_truth.get_version()), str(_truth.fingerprint()))
	else:
		pkg = _evaluator.evaluate_wing(wing, _current_intent(),
			_command_service, _unit_manager, ctx["bk"], ctx["cell_data"], ctx["occ"],
			int(_truth.get_version()), str(_truth.fingerprint()))
	_show_package(pkg, wing)


func _on_pick(idx: int) -> void:
	_picked = idx
	var o: Dictionary = (_result.get("options", []) as Array)[idx]
	var lines: Array = []
	lines.append("[b]%s — %s[/b]" % [str(o.get("profile", "?")), str(o.get("status", "?"))])
	if str(o.get("reason", "")).length() > 0:
		lines.append("Note: " + str(o.get("reason", "")))
	lines.append("Positive: " + ", ".join(o.get("top_positive", [])))
	lines.append("Negative: " + ", ".join(o.get("top_negative", [])))
	lines.append("---")
	var contrib: Array = o.get("contributions", [])
	contrib.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return abs(float(a.get("contribution", 0.0))) > abs(float(b.get("contribution", 0.0))))
	for c in contrib:
		lines.append("%s raw=%.2f w=%.2f → %+.2f" % [str(c.get("feature", "?")),
			float(c.get("raw", 0.0)), float(c.get("weight", 0.0)), float(c.get("contribution", 0.0))])
	var prov: Dictionary = o.get("provenance", {})
	lines.append("---")
	lines.append("known contacts: %s | stale: %s | objective fallback: %s" % [
		str(prov.get("known_ids", [])), str(prov.get("stale_ids", [])),
		str(prov.get("objective_fallback", true))])
	_detail.text = "\n".join(lines)
	_exec_btn.disabled = not o.has("destination")
	# Preview route on the shared overlay.
	if _overlay != null and o.has("route"):
		var cells: Array = []
		for p in ((o["route"] as Dictionary).get("path", []) as Array):
			if p is Array and (p as Array).size() == 2:
				cells.append(p)
		_overlay.set_routes([{"path_cells": cells}])


func _on_execute() -> void:
	if _picked < 0:
		return
	var o: Dictionary = (_result.get("options", []) as Array)[_picked]
	if not o.has("destination"):
		_status.text = "Pick has no destination (UNAVAILABLE)."
		return
	var d: Dictionary = o["destination"]
	var cmd := {"action": "MOVE",
		"scope": {"type": "UNIT_ID", "unit_id": str(_result.get("unit_id", ""))},
		"direction": "", "target": {"type": "HEX", "q": int(d.get("q", 0)), "r": int(d.get("r", 0))},
		"posture": "NORMAL", "constraints": {}}
	var vd: Dictionary = _action_service.validate_action(cmd, "blue")
	if not bool(vd.get("ok", false)):
		_status.text = "Canonical validation rejected the pick (discrepancy — see log)."
		push_warning("[CavPanel] evaluator pick failed canonical validation")
		return
	var plan: Dictionary = _action_service.plan_action(cmd, "blue")
	var ex: Dictionary = _action_service.execute_plan(str(plan.get("plan_id", "")))
	_status.text = "Executed %s → (%d,%d): %s" % [str(o.get("profile", "?")),
		int(d.get("q", 0)), int(d.get("r", 0)), str(ex.get("execution_status", "?"))]
