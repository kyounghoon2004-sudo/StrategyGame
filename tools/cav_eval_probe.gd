extends SceneTree

## Cavalry tactical evaluator pilot probe (SB-CAVALRY-EVALUATOR).
## Boots the canonical battle, evaluates one live BLUE cavalry formation
## (ADVANCE + FLANK), runs doctrine/fog/determinism gates, executes the
## BALANCED pick through the canonical pipeline. No model, no network.
## Writes: D:/Game development/.workflow/deliverables/SB-CAVALRY-EVALUATOR/evidence.json

const EvalScript = preload("res://scripts/step7/step7_cavalry_evaluator.gd")

const OUT := "D:/Game development/.workflow/deliverables/SB-CAVALRY-EVALUATOR/evidence.json"
const LOG := "user://cav_probe.log"

var failures: Array = []
var notes: Array = []
var evidence := {}


func _init() -> void:
	call_deferred("_run")


func _check(cond: bool, name: String) -> void:
	if cond:
		notes.append("PASS " + name)
	else:
		failures.append(name)


func _log(s: String) -> void:
	var f := FileAccess.open(LOG, FileAccess.READ_WRITE)
	if f:
		f.seek_end()
		f.store_line(s)
	print(s)


func _run() -> void:
	var packed: PackedScene = load("res://scenes/step2r_battlefield_shell.tscn")
	var battle: Node = packed.instantiate()
	get_root().add_child(battle)
	for _i in range(20):
		await process_frame
	var integration: Node = battle.get_node_or_null("Step7Integration")
	for _i in range(120):
		if integration and bool(integration.get("ready_for_step7")):
			break
		await process_frame
	if integration == null or not bool(integration.get("ready_for_step7")):
		_write({"status": "FAIL", "failures": ["probe: integration not ready"], "notes": notes})
		_log("CAV_PROBE FAIL integration-not-ready")
		quit(2)
		return
	var truth: RefCounted = integration.get("truth")
	var cmd_svc: RefCounted = integration.get("command_service")
	var projector: RefCounted = integration.get("projector")
	var svc: RefCounted = integration.get("action_service")
	var ev: RefCounted = EvalScript.new()

	var cav_id := _pick_cavalry(truth, cmd_svc)
	if cav_id.is_empty():
		_write({"status": "FAIL", "failures": ["probe: no live BLUE cavalry found"], "notes": notes})
		_log("CAV_PROBE FAIL no-cavalry")
		quit(2)
		return
	var bk: Dictionary = integration.call("get_blue_knowledge")
	var occ: Dictionary = projector.call("known_occupancy", "blue")
	var sv: int = int(truth.call("get_version"))
	var fp: String = str(truth.call("fingerprint"))
	var cell_data: Dictionary = truth.call("cell_data")
	evidence["unit_id"] = cav_id
	evidence["state_version"] = sv
	evidence["battle_summary"] = _unit_summary(truth, cav_id)
	evidence["knowledge_summary"] = {"own": (bk.get("own_forces", []) as Array).size(),
		"visible": (bk.get("current_enemy_observations", []) as Array).size(),
		"stale": (bk.get("last_known_enemy_contacts", []) as Array).size()}

	# 1. ADVANCE × 6 slots, twice for determinism.
	var intent_adv := {"action": "ADVANCE", "direction": "FORWARD"}
	var r1: Dictionary = ev.call("evaluate", cav_id, intent_adv, cmd_svc, bk, cell_data, occ, sv, fp)
	var r2: Dictionary = ev.call("evaluate", cav_id, intent_adv, cmd_svc, bk, cell_data, occ, sv, fp)
	_check(bool(r1.get("ok", false)), "ADVANCE evaluates ok")
	_check((r1.get("options", []) as Array).size() == 6, "exactly six option slots")
	_check(_all_have_status(r1), "all slots have status")
	_check(_options_equal(r1, r2), "deterministic repeatability (same state → same six)")
	_check(int(r1.get("candidate_count", 0)) > 0, "candidate accounting non-empty")
	evidence["advance"] = _strip(r1)
	evidence["advance_repeat_match"] = _options_equal(r1, r2)
	evidence["latency_advance"] = r1.get("latency", {})
	evidence["cache_second_run_hit"] = bool(r2.get("cache_hit", false))

	# Reachable accounting: envelope entries vs evaluated candidates.
	var area: Dictionary = cmd_svc.call("reachable_area", cav_id, "blue", "auto")
	evidence["reachable_entries"] = (area.get("reachable", []) as Array).size()

	# 2. Archer opportunity (synthetic knowledge delta, relative offsets — map-agnostic).
	var u: Dictionary = truth.call("get_unit", cav_id)
	var uo := Vector2i(int(u.get("q", 0)), int(u.get("r", 0)))
	var bk_archer := _with_contacts(bk, [{"id": "SYN_ARCHER_1", "q": uo.x + 3, "r": uo.y,
		"class": "archer", "contact_state": "visible"}])
	var ev2: RefCounted = EvalScript.new()
	var r_arch: Dictionary = ev2.call("evaluate", cav_id, intent_adv, cmd_svc, bk_archer, cell_data, occ, sv, fp)
	evidence["archer_delta"] = _delta_summary(r1, r_arch)
	_check(_pressure_rose_or_accessed(r1, r_arch), "archer opportunity registers (PRESSURE/ARCHER_ACCESS)")

	# 3. Spearman screen on top of the archer opportunity.
	var bk_spear := _with_contacts(bk_archer, [{"id": "SYN_SPEAR_1", "q": uo.x + 2, "r": uo.y,
		"class": "spearman", "contact_state": "visible"}])
	var ev3: RefCounted = EvalScript.new()
	var r_spear: Dictionary = ev3.call("evaluate", cav_id, intent_adv, cmd_svc, bk_spear, cell_data, occ, sv, fp)
	evidence["spear_delta"] = _delta_summary(r_arch, r_spear)
	_check(_counter_registered(r_arch, r_spear), "spearman counter-risk changes ranking (no hard ban)")
	# No hard ban: PRESSURE destination must still validate canonically when AVAILABLE/DEGRADED.
	var p_pick := _pick_of(r_spear, "PRESSURE")
	if p_pick.has("destination"):
		var d: Dictionary = p_pick["destination"]
		var route: Variant = cmd_svc.call("preview_move_route", cav_id, Vector2i(int(d["q"]), int(d["r"])), "blue", "auto")
		_check(route != null and bool(route.found), "spear-screen PRESSURE pick still canonically legal")
	else:
		notes.append("INFO PRESSURE has no destination under spear screen (UNAVAILABLE accepted)")

	# 4. No known enemies: strip contacts.
	var bk_empty := _strip_contacts(bk)
	var ev4: RefCounted = EvalScript.new()
	var r_empty: Dictionary = ev4.call("evaluate", cav_id, intent_adv, cmd_svc, bk_empty, cell_data, occ, sv, fp)
	_check(bool(r_empty.get("ok", false)) and _all_have_status(r_empty), "no-contact fallback keeps six statuses")
	_check(_no_provenance(r_empty), "no-contact run cites no enemy provenance")
	evidence["no_contact"] = _strip(r_empty)

	# 5. Fog / hidden-truth isolation gate.
	var fog := _fog_gate(truth, projector, integration, ev, cav_id, intent_adv, cmd_svc, bk, cell_data, occ, sv, fp)
	evidence["fog_gate"] = fog

	# 6. Support/isolation + mobility differentials across the six picks.
	evidence["differentials"] = _differentials(r1)

	# 7. FLANK RIGHT (cheap composition).
	var ev5: RefCounted = EvalScript.new()
	var r_flank: Dictionary = ev5.call("evaluate", cav_id, {"action": "FLANK", "direction": "RIGHT"}, cmd_svc, bk, cell_data, occ, sv, fp)
	_check(bool(r_flank.get("ok", false)) and (r_flank.get("options", []) as Array).size() == 6, "FLANK composes to six slots")
	evidence["flank"] = _strip(r_flank)

	# 8. Baseline comparison: existing planner ADVANCE for cavalry class.
	evidence["baseline"] = _baseline(svc, r1)

	# 9. Canonical execution of the BALANCED ADVANCE pick.
	var exec_res := await _execute_pick(svc, truth, cav_id, _pick_of(r1, "BALANCED"))
	evidence["execution"] = exec_res
	_check(bool(exec_res.get("validated", false)), "selected option passes canonical validation")
	_check(bool(exec_res.get("moved", false)), "selected option executes through canonical pipeline")

	var status := "PASS" if failures.is_empty() else "FAIL"
	evidence["status"] = status
	evidence["failures"] = failures
	evidence["notes"] = notes
	_write(evidence)
	_log("CAV_PROBE_" + status + " failures=" + str(failures.size()))
	quit(0 if failures.is_empty() else 2)


func _pick_cavalry(truth: RefCounted, cmd_svc: RefCounted) -> String:
	for u_val in truth.call("snapshot_units"):
		if not u_val is Dictionary:
			continue
		var ud: Dictionary = u_val
		if str(ud.get("faction", "")) != "blue" or str(ud.get("class", "")).to_lower() != "cavalry":
			continue
		if int(ud.get("soldier_count", 0)) <= 0 or bool(ud.get("action_ended", false)):
			continue
		if bool(ud.get("garrisoned", false)) or bool(ud.get("routed", false)):
			continue
		var area: Dictionary = cmd_svc.call("reachable_area", str(ud.get("id", "")), "blue", "auto")
		if bool(area.get("ok", false)) and not (area.get("reachable", []) as Array).is_empty():
			return str(ud.get("id", ""))
	return ""


func _unit_summary(truth: RefCounted, cav_id: String) -> Dictionary:
	var ud: Dictionary = truth.call("get_unit", cav_id)
	return {"id": cav_id, "q": int(ud.get("q", 0)), "r": int(ud.get("r", 0)),
		"class": str(ud.get("class", "")), "remaining_mp": float(ud.get("remaining_mp", 0.0)),
		"soldiers": int(ud.get("soldier_count", 0))}


func _all_have_status(r: Dictionary) -> bool:
	var opts: Array = r.get("options", [])
	if opts.size() != 6:
		return false
	for o in opts:
		if not (o is Dictionary) or not (o as Dictionary).has("status"):
			return false
		if str((o as Dictionary)["status"]) not in ["AVAILABLE", "DEGRADED", "UNAVAILABLE"]:
			return false
	return true


func _options_equal(a: Dictionary, b: Dictionary) -> bool:
	return JSON.stringify(a.get("options", [])) == JSON.stringify(b.get("options", []))


func _strip(r: Dictionary) -> Dictionary:
	var c: Dictionary = r.duplicate(true)
	c.erase("latency")
	return c


func _pick_of(r: Dictionary, profile: String) -> Dictionary:
	for o in (r.get("options", []) as Array):
		if o is Dictionary and str((o as Dictionary).get("profile", "")) == profile:
			return o
	return {}


func _with_contacts(bk: Dictionary, extra: Array) -> Dictionary:
	var c: Dictionary = (bk.duplicate(true) as Dictionary)
	var cur: Array = c.get("current_enemy_observations", [])
	for e in extra:
		cur.append(e)
	c["current_enemy_observations"] = cur
	return c


func _strip_contacts(bk: Dictionary) -> Dictionary:
	var c: Dictionary = (bk.duplicate(true) as Dictionary)
	c["current_enemy_observations"] = []
	c["last_known_enemy_contacts"] = []
	return c


func _opt_utility(r: Dictionary, profile: String) -> float:
	var p := _pick_of(r, profile)
	return float(p.get("utility", -999.0))


func _delta_summary(before: Dictionary, after: Dictionary) -> Dictionary:
	var d := {}
	for p in ["SAFE", "SUPPORTED", "BALANCED", "PRESSURE", "DEEP", "MAXIMUM"]:
		var pb := _pick_of(before, p)
		var pa := _pick_of(after, p)
		d[p] = {"before_dest": pb.get("destination", {}), "after_dest": pa.get("destination", {}),
			"before_u": float(pb.get("utility", 0.0)), "after_u": float(pa.get("utility", 0.0)),
			"before_status": str(pb.get("status", "?")), "after_status": str(pa.get("status", "?"))}
	return d


func _pressure_rose_or_accessed(base: Dictionary, arch: Dictionary) -> bool:
	var pb := _pick_of(base, "PRESSURE")
	var pa := _pick_of(arch, "PRESSURE")
	var arch_raw := 0.0
	for c in (pa.get("contributions", []) as Array):
		if c is Dictionary and str((c as Dictionary).get("feature", "")) == "ARCHER_ACCESS":
			arch_raw = float((c as Dictionary).get("raw", 0.0))
	return arch_raw > 0.01 or float(pa.get("utility", 0.0)) != float(pb.get("utility", 0.0))


func _counter_registered(arch: Dictionary, spear: Dictionary) -> bool:
	var pa := _pick_of(arch, "PRESSURE")
	var ps := _pick_of(spear, "PRESSURE")
	var c_arch := 0.0
	var c_spear := 0.0
	for c in (pa.get("contributions", []) as Array):
		if c is Dictionary and str((c as Dictionary).get("feature", "")) == "COUNTER_RISK":
			c_arch = float((c as Dictionary).get("raw", 0.0))
	for c in (ps.get("contributions", []) as Array):
		if c is Dictionary and str((c as Dictionary).get("feature", "")) == "COUNTER_RISK":
			c_spear = float((c as Dictionary).get("raw", 0.0))
	return c_spear > c_arch or JSON.stringify(pa.get("destination", {})) != JSON.stringify(ps.get("destination", {}))


func _no_provenance(r: Dictionary) -> bool:
	for o in (r.get("options", []) as Array):
		if not (o is Dictionary):
			continue
		var prov: Dictionary = (o as Dictionary).get("provenance", {})
		if not (prov.get("known_ids", []) as Array).is_empty():
			return false
	return true


func _fog_gate(truth: RefCounted, projector: RefCounted, integration: Node, ev: RefCounted,
		cav_id: String, intent: Dictionary, cmd_svc: RefCounted, bk: Dictionary,
		cell_data: Dictionary, occ: Dictionary, sv: int, fp: String) -> Dictionary:
	var hidden_id := ""
	var hidden_pos := Vector2i.ZERO
	var hidden_class := "unknown"
	for u_val in truth.call("snapshot_units"):
		if not u_val is Dictionary:
			continue
		var ud: Dictionary = u_val
		if str(ud.get("faction", "")) == "red" and int(ud.get("soldier_count", 0)) > 0:
			if not bool(projector.call("is_contact_visible", "blue", str(ud.get("id", "")))):
				hidden_id = str(ud.get("id", ""))
				hidden_pos = Vector2i(int(ud.get("q", 0)), int(ud.get("r", 0)))
				hidden_class = str(ud.get("class", "unknown"))
				break
	if hidden_id.is_empty():
		notes.append("FOG: no hidden RED unit at boot; gate vacuous (as in smoke H)")
		return {"vacuous": true}
	var base: Dictionary = ev.call("evaluate", cav_id, intent, cmd_svc, bk, cell_data, occ, sv, fp)
	var leak := JSON.stringify(base).contains("\"" + hidden_id + "\"")
	_check(not leak, "fog: hidden unit absent from evaluator output")
	var bk_rev: Dictionary = _with_contacts(bk, [{"id": hidden_id, "q": hidden_pos.x, "r": hidden_pos.y,
		"class": hidden_class, "contact_state": "visible"}])
	var evb: RefCounted = EvalScript.new()
	var revealed: Dictionary = evb.call("evaluate", cav_id, intent, cmd_svc, bk_rev, cell_data, occ, sv, fp)
	var changed := JSON.stringify(base.get("options", [])) != JSON.stringify(revealed.get("options", []))
	_check(changed, "fog: scores change only after authorized knowledge change")
	return {"vacuous": false, "hidden_id": hidden_id, "hidden_class": hidden_class,
		"leaked": leak, "changed_after_reveal": changed}


func _differentials(r: Dictionary) -> Dictionary:
	var d := {}
	for o in (r.get("options", []) as Array):
		if not (o is Dictionary) or not (o as Dictionary).has("destination"):
			continue
		var od: Dictionary = o
		var rk: Dictionary = od.get("risk", {})
		d[str(od.get("profile", "?"))] = {"dest": od.get("destination", {}),
			"u": float(od.get("utility", 0.0)), "support": float(rk.get("support", 0.0)),
			"mobility": float(rk.get("mobility", 0.0)), "intent": float(rk.get("intent_progress", 0.0)),
			"risk": float(rk.get("overall", 0.0)), "status": str(od.get("status", "?"))}
	return d


func _baseline(svc: RefCounted, r1: Dictionary) -> Dictionary:
	var cmd := {"action": "ADVANCE", "scope": {"type": "CLASS", "class": "CAVALRY"},
		"direction": "FORWARD", "target": {}, "posture": "NORMAL", "constraints": {}}
	var prev: Dictionary = svc.call("preview_action", cmd, "blue")
	var bal := _pick_of(r1, "BALANCED")
	return {"planner_preview_ok": bool(prev.get("ok", false)),
		"planner_status": str(prev.get("plan_status", "?")),
		"evaluator_balanced_dest": bal.get("destination", {}),
		"note": "planner emits one deterministic destination; evaluator emits six explainable options"}


func _execute_pick(svc: RefCounted, truth: RefCounted, cav_id: String, pick: Dictionary) -> Dictionary:
	var out := {"validated": false, "moved": false}
	if not pick.has("destination"):
		out["error"] = "BALANCED has no destination"
		return out
	var d: Dictionary = pick["destination"]
	var dest := Vector2i(int(d.get("q", 0)), int(d.get("r", 0)))
	var cmd := {"action": "MOVE", "scope": {"type": "UNIT_ID", "unit_id": cav_id},
		"direction": "", "target": {"type": "HEX", "q": dest.x, "r": dest.y},
		"posture": "NORMAL", "constraints": {}}
	var vd: Dictionary = svc.call("validate_action", cmd, "blue")
	out["validated"] = bool(vd.get("ok", false))
	out["validate_keys"] = vd.keys()
	if not bool(vd.get("ok", false)):
		out["error"] = "canonical validation rejected evaluator destination"
		return out
	var plan: Dictionary = svc.call("plan_action", cmd, "blue")
	var pid := str(plan.get("plan_id", ""))
	if pid.is_empty():
		out["error"] = "no plan_id"
		return out
	var ex: Dictionary = svc.call("execute_plan", pid)
	out["execute_keys"] = ex.keys()
	out["execute_status"] = str(ex.get("execution_status", "?"))
	for _i in range(1500):
		var cur: Dictionary = truth.call("get_unit", cav_id)
		if Vector2i(int(cur.get("q", 0)), int(cur.get("r", 0))) == dest:
			break
		await process_frame
	var fin: Dictionary = truth.call("get_unit", cav_id)
	out["final_pos"] = [int(fin.get("q", 0)), int(fin.get("r", 0))]
	out["target_pos"] = [dest.x, dest.y]
	out["moved"] = Vector2i(int(fin.get("q", 0)), int(fin.get("r", 0))) == dest
	out["resulting_state_version"] = int(ex.get("resulting_state_version", -1))
	return out


func _write(value: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute((OUT as String).get_base_dir())
	var file := FileAccess.open(OUT, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(value, " "))
