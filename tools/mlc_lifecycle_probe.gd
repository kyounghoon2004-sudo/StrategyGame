extends SceneTree

## MISSION-LIFECYCLE gate probe (SYSTEM_DEBUG visibility; sim access ONLY through
## the normal stack: manager.red_turn -> response gate -> compiler). Zero provider
## calls: the General is never invoked; plans are injected via apply_plan. The
## keeper/adjust/replan decisions are exercised through the REAL manager/coord-menu
## code paths (confirm_plan, expand_initial/expand_adjust, apply_plan).
##
## Modes:
##   trace       — Phase 0: FORCE_STRENGTH_BELOW lifecycle trace (statuses, events,
##                 review_due, M00 entry, unit behavior per turn).
##   dedup       — one failure -> exactly one canonical event; no review storm.
##   cases       — controlled matrix A-G (incl. KEEP/ADJUST/REPLAN + recovery).
##   determinism — repeat-run fingerprint + executed-signature comparison.
##
## Usage:
##   Godot_console --headless --path StrategyGame -s res://tools/mlc_lifecycle_probe.gd -- \
##     --mode=trace|dedup|cases|determinism --tag=before|after --out-dir="<abs dir>"

const SimControllerCls = preload("res://scripts/sim/sim_controller.gd")
const ObsCls = preload("res://scripts/cloud1/cloud1_observation.gd")
const CompilerCls = preload("res://scripts/cloud1/cloud1_compiler.gd")
const ScenariosCls = preload("res://scripts/cloud2/cloud2_debug_scenarios.gd")
const MissionCls = preload("res://scripts/cloud2/cloud2_mission.gd")
const ManagerCls = preload("res://scripts/cloud2/cloud2_mission_manager.gd")
const ResponseCls = preload("res://scripts/cloud2/cloud2_response.gd")
const MenuCls = preload("res://scripts/cloud2/cloud2_coord_menu.gd")

var _out_dir := ""
var _mode := "trace"
var _tag := "before"

func _init() -> void:
	_parse_args()
	if _out_dir.is_empty():
		print("[MLC] FATAL: need --out-dir=<abs dir>")
		quit(4)
		return
	var res := {}
	match _mode:
		"trace":
			res = _mode_trace()
		"dedup":
			res = _mode_dedup()
		"cases":
			res = _mode_cases()
		"determinism":
			res = _mode_determinism()
		_:
			print("[MLC] modes: trace|dedup|cases|determinism")
			quit(4)
			return
	_write("%s_%s.json" % [_tag, _mode], res)
	print("[MLC] mode=%s tag=%s ok=%s" % [_mode, _tag, str(bool(res.get("ok", true)))])
	quit(0)

func _parse_args() -> void:
	var all: Array = []
	all.append_array(OS.get_cmdline_user_args())
	all.append_array(OS.get_cmdline_args())
	for a_val in all:
		var a := str(a_val).strip_edges()
		if a.begins_with("--out-dir="):
			_out_dir = a.get_slice("=", 1).strip_edges().trim_prefix("\"").trim_suffix("\"")
		elif a.begins_with("--mode="):
			_mode = a.get_slice("=", 1).strip_edges()
		elif a.begins_with("--tag="):
			_tag = a.get_slice("=", 1).strip_edges()

func _write(name: String, data: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(_out_dir)
	var path := _out_dir.path_join(name)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		print("[MLC] FATAL: cannot write %s" % path)
		quit(5)
		return
	f.store_string(JSON.stringify(data, "  "))
	f.close()
	print("[MLC] wrote %s" % path)

## --- shared helpers -----------------------------------------------------------

func _load_sim() -> Object:
	var built: Dictionary = ScenariosCls.build("COOP_BASELINE")
	if not bool(built.get("ok", false)):
		return null
	var scn: Dictionary = (built.get("scenario", {}) as Dictionary).duplicate(true)
	var sim: RefCounted = SimControllerCls.new()
	if not bool((sim.load_scenario(scn) as Dictionary).get("ok", false)):
		return null
	return sim

## Deterministic out-of-combat attrition injection (probe harness only; the
## lifecycle gate owns no combat-path edits). Mutates the same unit dicts the
## combat resolution writes (white-box access, mirrors engine-internal use).
func _weaken(sim: Object, uid: String, soldiers: int) -> void:
	var um: Object = (sim.get_manager() as Object)
	var units: Dictionary = um._units
	if units.has(uid):
		(units[uid] as Dictionary)["soldier_count"] = soldiers

func _obs(sim: Object) -> Dictionary:
	return ObsCls.build(sim, "red")

func _doctrine() -> Dictionary:
	return {"aggression": 0.5, "tempo": 0.5, "risk_tolerance": 0.5,
		"reserve_discipline": 0.6, "pursuit": 0.5}

func _mission_dict(mid: String, task: String, area: String, units: Array, objective: Dictionary, policy: String, preserve := false, aborts: Array = []) -> Dictionary:
	var m := MissionCls.default_mission(mid, task)
	m["area"] = area
	m["assigned_units"] = units.duplicate(true)
	m["objective"] = objective.duplicate(true)
	m["engagement"] = {"policy": policy}
	m["constraints"] = {"preserve_force": preserve, "max_overextension": 3}
	m["success_conditions"] = []
	m["abort_conditions"] = aborts
	m["report_conditions"] = []
	return m

func _plan_dict(missions: Array, obs: Dictionary) -> Dictionary:
	return {"concept": {"objective": "probe", "intent": "probe", "main_effort": "CENTER", "risk_posture": "BALANCED"},
		"doctrine": _doctrine(), "missions": missions,
		"contingencies": [], "opponent_hypotheses": [],
		"review_conditions": [], "review_horizon_turns": 12,
		"source": "probe", "based_on_snapshot": str(obs.get("snapshot_id", ""))}

func _exec_order(sim: Object, order: Dictionary) -> Dictionary:
	return CompilerCls.execute(sim, order, "", "red")

## One RED turn through the real stack (review_due happens inside red_turn).
func _red_turn(sim: Object, mgr: Object, turn: int) -> Dictionary:
	var obs: Dictionary = _obs(sim)
	var decided: Dictionary = mgr.red_turn(sim, obs)
	var acted: Array = []
	var orders: Array = []
	for o_val in (decided.get("orders", []) as Array):
		var order: Dictionary = (o_val as Dictionary).get("order", {})
		if order.is_empty():
			continue
		var ex: Dictionary = _exec_order(sim, order)
		for row_val in (ex.get("executed_units", []) as Array):
			acted.append(row_val)
		orders.append({"mission_id": str((o_val as Dictionary).get("mission_id", "?")),
			"order": order, "exec_status": str(ex.get("execution_status", "")),
			"executed": (ex.get("executed_units", []) as Array).duplicate(true),
			"failed": (ex.get("execution_failed", []) as Array).duplicate(true)})
	var turn_no := int(obs.get("turn", turn))
	mgr.post_turn(acted, turn_no)
	sim.sim_end_turn()  # advance the sim turn (mirrors the production loop)
	return {"decided": decided, "orders": orders, "obs": obs, "turn": turn_no}

## Run a battle: apply plan, run turns, capture per-turn lifecycle rows.
## mutate: {"<turn>": [{"uid": "...", "soldiers": N}, ...]} applied before that turn.
func _run_battle(missions: Array, max_turns: int, mutate: Dictionary = {}, keep_abort_on_m00 := false) -> Dictionary:
	var sim: Object = _load_sim()
	if sim == null:
		return {"ok": false, "error": "scenario load failed"}
	var obs0: Dictionary = _obs(sim)
	var mgr: Object = ManagerCls.new()
	mgr.reset_battle()
	var applied: Dictionary = mgr.apply_plan(_plan_dict(missions, obs0), 1, str(obs0.get("snapshot_id", "")),
		str(obs0.get("battle_id", "")))  # bind the REAL battle id or red_turn resets the plan
	var turns: Array = []
	for t in range(1, max_turns + 1):
		for mv_val in ((mutate.get(str(t), []) as Array)):
			var mv: Dictionary = mv_val
			_weaken(sim, str(mv.get("uid", "")), int(mv.get("soldiers", 0)))
		var out := _red_turn(sim, mgr, t)

		var ev_rows: Array = []
		for e_val in mgr.get_events():
			if int((e_val as Dictionary).get("turn", 0)) == t:
				ev_rows.append(e_val)
		turns.append({"turn": int(out["obs"].get("turn", t)), "statuses": (out["decided"].get("statuses", []) as Array).duplicate(true),
			"review": (out["decided"].get("review", {}) as Dictionary).duplicate(true),
			"events": ev_rows, "orders": out["orders"],
			"wakeup": mgr.wakeup_view(),
			"units": _side_units(sim)})
		if _decisive(sim):
			break
	return {"ok": true, "applied": applied, "turns": turns,
		"plan_final": mgr.get_plan(), "events_final": mgr.get_events(),
		"final_units": _side_units(sim)}

func _mission_soldiers_dbg(mgr: Object, obs: Dictionary, mid: String) -> int:
	var m := _mission_now(mgr._plan, mid)
	var ids := {}
	for u in (m.get("assigned_units", []) as Array):
		ids[str(u).strip_edges().to_upper()] = true
	var total := 0
	for u_val in (obs.get("friendly_units", []) as Array):
		if u_val is Dictionary and ids.has(str((u_val as Dictionary).get("unit_id", "")).strip_edges().to_upper()):
			total += int((u_val as Dictionary).get("soldiers", 0))
	return total

func _side_units(sim: Object) -> Dictionary:
	var out := {}
	for u_val in ((sim.get_manager() as Object).get_all_units_including_garrisoned() as Array):
		var u: Dictionary = u_val
		out[str(u.get("id", ""))] = {"q": int(u.get("q", 0)), "r": int(u.get("r", 0)), "soldiers": int(u.get("soldier_count", 0))}
	return out

func _decisive(sim: Object) -> bool:
	var blue_alive := 0
	var red_alive := 0
	for u_val in ((sim.get_manager() as Object).get_all_units_including_garrisoned() as Array):
		var u: Dictionary = u_val
		if int(u.get("soldier_count", 0)) > 0:
			if str(u.get("faction", "")) == "blue":
				blue_alive += 1
			else:
				red_alive += 1
	return blue_alive == 0 or red_alive == 0

func _status_to(run: Dictionary, status: String) -> Array:
	var out: Array = []
	for e_val in (run.get("events_final", []) as Array):
		var e: Dictionary = e_val
		if str(e.get("kind", "")) == "MISSION_STATUS":
			var d: Dictionary = (e.get("detail", {}) as Dictionary)
			if str(d.get("to", "")) == status:
				out.append({"turn": int(e.get("turn", 0)), "mission_id": str(d.get("mission_id", "")),
					"from": str(d.get("from", "")), "reason": str(d.get("reason", ""))})
	return out

func _mission_now(plan: Dictionary, mid: String) -> Dictionary:
	for m_val in (plan.get("missions", []) as Array):
		if str((m_val as Dictionary).get("mission_id", "")) == mid:
			return m_val
	return {}

func _m00_units(plan: Dictionary) -> Array:
	var m := _mission_now(plan, "M00")
	if m.is_empty():
		return []
	return (m.get("assigned_units", []) as Array).duplicate(true)

## Deterministic FORCE_STRENGTH_BELOW repro geometry: M02 = R_SCT_1(150)+R_CAV_1(320),
## baseline 470 captured at t1; before t2 R_CAV_1 -> 60 => mission 210 < 235 (0.5).
const M02_UNITS := ["R_SCT_1", "R_CAV_1"]
const FSB_MUTATE := {"2": [{"uid": "R_CAV_1", "soldiers": 60}]}

func _failure_missions() -> Array:
	return [
		_mission_dict("M01", "FIX", "CENTER", ["R_INF_1", "R_INF_2"], {"kind": "ENEMY_FORMATION", "unit_id": "B_INF_1"}, "ATTACK_DESIGNATED_ONLY"),
		_mission_dict("M02", "RECON", "ANY", M02_UNITS, {"kind": "NONE"}, "ATTACK_IF_ADVANTAGEOUS", false,
			[{"trigger": "FORCE_STRENGTH_BELOW", "params": {"fraction": 0.5}}]),
		_mission_dict("M03", "HOLD", "SOUTH", ["R_HQ_1", "R_SPE_1"], {"kind": "ZONE", "zone": "HQ"}, "HOLD_FIRE", true),
	]

## --- mode: trace ---------------------------------------------------------------

func _mode_trace() -> Dictionary:
	var run: Dictionary = _run_battle(_failure_missions(), 6, FSB_MUTATE)
	return {"ok": run.get("ok", false), "repro": {"mission": "M02", "task": "RECON",
		"units": M02_UNITS, "baseline": 470, "threshold_fraction": 0.5,
		"mutation_before_t2": "R_CAV_1 320 -> 130 (mission 470 -> 170 < 235)"},
		"aborted_transitions": _status_to(run, "ABORTED"),
		"m00_ever": _m00_units(run.get("plan_final", {})),
		"battle": run}

## --- mode: dedup ---------------------------------------------------------------

func _mode_dedup() -> Dictionary:
	var run: Dictionary = _run_battle(_failure_missions(), 6, FSB_MUTATE)
	var aborts := _status_to(run, "ABORTED")
	var m02_aborts: Array = []
	for a_val in aborts:
		if str((a_val as Dictionary).get("mission_id", "")) == "M02":
			m02_aborts.append(a_val)
	var review_requests: Array = []
	for t_val in (run.get("turns", []) as Array):
		var rv: Dictionary = (t_val as Dictionary).get("review", {})
		if bool(rv.get("requested", false)):
			review_requests.append({"turn": int((t_val as Dictionary).get("turn", 0)),
				"trigger": str(rv.get("trigger", "")), "reason": str(rv.get("reason", ""))})
	var failed_requests: Array = []
	for rr_val in review_requests:
		if str((rr_val as Dictionary).get("trigger", "")) == "MISSION_FAILED":
			failed_requests.append(rr_val)
	var prov: Array = (run.get("plan_final", {}).get("fallback_provenance", []) as Array)
	return {"ok": true, "m02_abort_transition_count": m02_aborts.size(),
		"m02_abort_transitions": m02_aborts,
		"review_requests": review_requests, "review_request_count": review_requests.size(),
		"mission_failed_requests": failed_requests,
		"fallback_provenance": prov,
		"dedup": {"one_emit": m02_aborts.size() <= 1,
			"one_mission_failed_request": failed_requests.size() == 1,
			"no_review_storm": review_requests.size() <= 3,
			"provenance_recorded": not prov.is_empty()}}

## --- mode: cases ---------------------------------------------------------------

func _mode_cases() -> Dictionary:
	return {"ok": true, "cases": {
		"A_NORMAL_ACTIVE": _case_normal_active(),
		"B_TEMPORARY_BLOCK": _case_temporary_block(),
		"C_FORCE_STRENGTH_FAILURE": _case_strength_failure(),
		"D_FAILURE_KEEP": _case_keep(),
		"E_FAILURE_ADJUST": _case_adjust(),
		"F_FAILURE_REPLAN": _case_replan(),
		"G_RECOVERY": _case_recovery()}}
	# E_FAILURE_ADJUST is exercised inside F via expand_adjust when the menu
	# supports it; see MISSION_LIFECYCLE_MATRIX.json notes.

func _case_normal_active() -> Dictionary:
	var missions: Array = [
		_mission_dict("M01", "FIX", "CENTER", ["R_INF_1", "R_INF_2"], {"kind": "ENEMY_FORMATION", "unit_id": "B_INF_1"}, "ATTACK_DESIGNATED_ONLY"),
		_mission_dict("M03", "HOLD", "SOUTH", ["R_HQ_1", "R_SPE_1"], {"kind": "ZONE", "zone": "HQ"}, "HOLD_FIRE", true),
	]
	var run: Dictionary = _run_battle(missions, 3)
	var reviews := _any_review(run)
	return {"ok": true, "abort_events": _status_to(run, "ABORTED"),
		"m00_units_final": _m00_units(run.get("plan_final", {})),
		"review_requests": reviews,
		"expect": "no aborts, no M00 population, no lifecycle reviews"}

func _case_temporary_block() -> Dictionary:
	# White-box wiring test (no privacy in GDScript): set a mission BLOCKED via
	# the manager's own _set_status, then verify review_due classifies it as a
	# review trigger while units remain assigned (no M00, no orphaning).
	var sim: Object = _load_sim()
	var obs0: Dictionary = _obs(sim)
	var mgr: Object = ManagerCls.new()
	mgr.reset_battle()
	var applied: Dictionary = mgr.apply_plan(_plan_dict(_failure_missions(), obs0), 1, str(obs0.get("snapshot_id", "")), str(obs0.get("battle_id", "")))
	var t1 := _red_turn(sim, mgr, 1)
	var plan: Dictionary = mgr.get_plan()
	# mutate the manager's live plan (white-box): BLOCKED M02 with explicit reason
	var live_plan: Dictionary = mgr._plan
	var m2 := _mission_now(live_plan, "M02")
	if not m2.is_empty():
		mgr._set_status(m2, "BLOCKED", "TEST_RECOVERABLE_BLOCK", 2)
	var rd: Dictionary = mgr.review_due(_obs(sim), 2)
	var m2_after := _mission_now(mgr.get_plan(), "M02")
	# resume: clear BLOCKED the way a controller resume does
	if not m2.is_empty():
		mgr._set_status(m2, "ACTIVE", "RESUMED", 2)
	return {"ok": true, "applied": applied, "turn1_orders": (t1["orders"] as Array).size(),
		"blocked_review": rd, "m2_after_block": {"status": str(m2_after.get("status", "")), "units": (m2_after.get("assigned_units", []) as Array)},
		"m00_units": _m00_units(mgr.get_plan()),
		"expect": "BLOCKED requests MISSION_BLOCKED review; units stay assigned; resume returns ACTIVE"}

func _case_strength_failure() -> Dictionary:
	var run: Dictionary = _run_battle(_failure_missions(), 4, FSB_MUTATE)
	var aborts := _status_to(run, "ABORTED")
	var m2 := _mission_now(run.get("plan_final", {}), "M02")
	var m2_row := {}
	if not m2.is_empty():
		m2_row = {"status": str(m2.get("status", "")), "reason": str(m2.get("status_reason", "")),
			"turn": int(m2.get("status_turn", 0)), "units": (m2.get("assigned_units", []) as Array)}
	return {"ok": true, "abort_transitions": aborts, "m2_final": m2_row,
		"m00_units_final": _m00_units(run.get("plan_final", {})),
		"expect": "exactly one explicit ABORTED transition with FORCE_STRENGTH_BELOW reason"}

## FAILURE + KEEP: abort at t2, then the General decision is KEEP via the real
## confirm_plan path; the plan stands, the failed mission stays failed.
func _case_keep() -> Dictionary:
	var sim: Object = _load_sim()
	var obs0: Dictionary = _obs(sim)
	var mgr: Object = ManagerCls.new()
	mgr.reset_battle()
	mgr.apply_plan(_plan_dict(_failure_missions(), obs0), 1, str(obs0.get("snapshot_id", "")), str(obs0.get("battle_id", "")))
	_red_turn(sim, mgr, 1)
	for mv_val in (FSB_MUTATE.get("2", []) as Array):
		_weaken(sim, str((mv_val as Dictionary).get("uid", "")), int((mv_val as Dictionary).get("soldiers", 0)))
	var t2 := _red_turn(sim, mgr, 2)
	var m2_before := _mission_now(mgr.get_plan(), "M02")
	var kept: Dictionary = mgr.confirm_plan(3, [], false)
	var t3 := _red_turn(sim, mgr, 3)
	var t4 := _red_turn(sim, mgr, 4)
	var m2_after := _mission_now(mgr.get_plan(), "M02")
	var plan: Dictionary = mgr.get_plan()
	var m2_resurrected := str(m2_after.get("status", "")) != "ABORTED"
	var orphan_units: Array = []
	for uid in (m2_before.get("assigned_units", []) as Array):
		var covered := false
		for m_val in (plan.get("missions", []) as Array):
			if str((m_val as Dictionary).get("status", "")) in ["SUCCESS", "FAILED", "ABORTED"]:
				continue
			if str(uid) in ((m_val as Dictionary).get("assigned_units", []) as Array):
				covered = true
				break
		if not covered:
			orphan_units.append(uid)
	return {"ok": true, "t2_review": (t2["decided"].get("review", {}) as Dictionary),
		"m2_at_abort": {"status": str(m2_before.get("status", "")), "reason": str(m2_before.get("status_reason", ""))},
		"keep_result": kept, "m2_after_keep": {"status": str(m2_after.get("status", "")), "reason": str(m2_after.get("status_reason", ""))},
		"m2_resurrected": m2_resurrected,
		"m00_units_after_keep": _m00_units(plan),
		"orphan_units": orphan_units,
		"t3_t4_orders": {"t3": (t3["orders"] as Array).size(), "t4": (t4["orders"] as Array).size()},
		"expect": "KEEP: plan stands, M02 stays ABORTED, freed units in explicit M00 coverage, no orphans"}

## FAILURE + ADJUST: the menu-derived baseline plan is adjusted (one group
## re-picked) and expanded through the real expand_adjust, then adopted.
func _case_adjust() -> Dictionary:
	var sim: Object = _load_sim()
	var obs0: Dictionary = _obs(sim)
	var mgr: Object = ManagerCls.new()
	mgr.reset_battle()
	mgr.apply_plan(_plan_dict(_failure_missions(), obs0), 1, str(obs0.get("snapshot_id", "")), str(obs0.get("battle_id", "")))
	_red_turn(sim, mgr, 1)
	for mv_val in (FSB_MUTATE.get("2", []) as Array):
		_weaken(sim, str((mv_val as Dictionary).get("uid", "")), int((mv_val as Dictionary).get("soldiers", 0)))
	var t2 := _red_turn(sim, mgr, 2)
	var obs2: Dictionary = _obs(sim)
	var menu: Dictionary = MenuCls.build_menu(obs2)
	var baseline := {"choices": {}}
	var changes: Array = []
	var first := true
	for g_val in (menu.get("groups", []) as Array):
		var g: Dictionary = g_val
		var opts: Array = g.get("options", [])
		if opts.is_empty() or not (opts[0] as Dictionary).has("id"):
			continue
		var gid := str(g.get("id", ""))
		var def_choice := str((opts[0] as Dictionary).get("id", ""))
		baseline["choices"][gid] = def_choice
		if first and opts.size() > 1:
			changes.append({"group": gid, "choice": str((opts[1] as Dictionary).get("id", ""))})
			first = false
	var expanded: Dictionary = MenuCls.expand_adjust(menu, baseline, changes, 3, str(obs2.get("snapshot_id", "")),
		(mgr.get_plan().get("mission", {}) as Dictionary), mgr.get_plan(), [])
	var adjust_result := {}
	if bool(expanded.get("ok", false)):
		adjust_result = mgr.apply_plan((expanded.get("plan", {}) as Dictionary).duplicate(true), 3,
			str(obs2.get("snapshot_id", "")), str(obs2.get("battle_id", "")))
	else:
		adjust_result = {"ok": false, "code": str(expanded.get("code", "")), "detail": str(expanded.get("detail", ""))}
	var t3 := _red_turn(sim, mgr, 3)
	var plan_after: Dictionary = mgr.get_plan()
	var ownership := {}
	for uid in M02_UNITS:
		var owner := ""
		for m_val in (plan_after.get("missions", []) as Array):
			var m: Dictionary = m_val
			if str(m.get("status", "")) in ["SUCCESS", "FAILED", "ABORTED"]:
				continue
			if str(uid) in ((m.get("assigned_units", []) as Array) as Array):
				owner = str(m.get("mission_id", ""))
				break
		ownership[uid] = owner
	return {"ok": true, "t2_review": (t2["decided"].get("review", {}) as Dictionary),
		"changes": changes, "adjust_result": adjust_result,
		"ownership_after": ownership, "m00_units_after": _m00_units(plan_after),
		"expect": "ADJUST: revised plan adopted; freed units reclaimed by a live mission"}

## FAILURE + REPLAN: abort at t2, then a fresh menu-based plan (the real
## expand_initial path, which REPLAN reviews reuse) reassigns the freed force.
func _case_replan() -> Dictionary:
	var sim: Object = _load_sim()
	var obs0: Dictionary = _obs(sim)
	var mgr: Object = ManagerCls.new()
	mgr.reset_battle()
	mgr.apply_plan(_plan_dict(_failure_missions(), obs0), 1, str(obs0.get("snapshot_id", "")), str(obs0.get("battle_id", "")))
	_red_turn(sim, mgr, 1)
	for mv_val in (FSB_MUTATE.get("2", []) as Array):
		_weaken(sim, str((mv_val as Dictionary).get("uid", "")), int((mv_val as Dictionary).get("soldiers", 0)))
	var t2 := _red_turn(sim, mgr, 2)
	var v_before := int(mgr.get_plan().get("plan_version", 0))
	var prov_before: Array = (mgr.get_plan().get("fallback_provenance", []) as Array)
	var obs2: Dictionary = _obs(sim)
	# Real REPLAN-style expansion: menu for the CURRENT state, pick templates,
	# expand through the production expand_initial, adopt via apply_plan.
	var menu: Dictionary = MenuCls.build_menu(obs2)
	var sel := {"concept": "HOLD_AND_SCREEN", "main_effort": "CENTER",
		"doctrine": {"aggression": "STANDARD", "tempo": "STANDARD", "risk": "BALANCED", "reserve": "STANDARD", "pursuit": "STANDARD"},
		"assignments": [], "horizon": 4, "hypotheses": []}
	for g_val in (menu.get("groups", []) as Array):
		var g: Dictionary = g_val
		var opts: Array = g.get("options", [])
		if not opts.is_empty() and opts[0] is Dictionary:
			(sel["assignments"] as Array).append({"group": str(g.get("id", "")), "choice": str((opts[0] as Dictionary).get("id", "?"))})
	var expanded: Dictionary = MenuCls.expand_initial(menu, sel, 3, str(obs2.get("snapshot_id", "")),
		(mgr.get_plan().get("mission", {}) as Dictionary), [])
	var replan_result := {}
	if bool(expanded.get("ok", false)):
		var new_plan: Dictionary = (expanded.get("plan", {}) as Dictionary).duplicate(true)
		replan_result = mgr.apply_plan(new_plan, 3, str(obs2.get("snapshot_id", "")), str(obs2.get("battle_id", "")))
	else:
		replan_result = {"ok": false, "code": str(expanded.get("code", "")), "detail": str(expanded.get("detail", ""))}
	var t3 := _red_turn(sim, mgr, 3)
	var plan_after: Dictionary = mgr.get_plan()
	var prov_after: Array = (plan_after.get("fallback_provenance", []) as Array)
	# which live mission owns the freed units now?
	var ownership := {}
	for uid in M02_UNITS:
		var owner := ""
		for m_val in (plan_after.get("missions", []) as Array):
			var m: Dictionary = m_val
			if str(m.get("status", "")) in ["SUCCESS", "FAILED", "ABORTED"]:
				continue
			if str(uid) in ((m.get("assigned_units", []) as Array) as Array):
				owner = str(m.get("mission_id", ""))
				break
		ownership[uid] = owner
	return {"ok": true, "t2_review": (t2["decided"].get("review", {}) as Dictionary),
		"version_before": v_before, "version_after": int(plan_after.get("plan_version", 0)),
		"replan_result": replan_result,
		"fallback_provenance_before": prov_before,
		"fallback_provenance_after": prov_after,
		"ownership_after": ownership,
		"m00_units_after": _m00_units(plan_after),
		"t3_statuses": (t3["decided"].get("statuses", []) as Array),
		"expect": "REPLAN: version bump, freed units owned by a live mission (not M00), fallback exits"}

## G. RECOVERY: fallback exits after replacement; replacement mission executes
## through the normal stack on the first turn after adoption.
func _case_recovery() -> Dictionary:
	var r: Dictionary = _case_replan()
	var t3_statuses: Array = (r.get("t3_statuses", []) as Array)
	var new_missions: Array = []
	var plan_rows: Array = r.get("t3_statuses", [])
	for row_val in plan_rows:
		var row: Dictionary = row_val
		if str(row.get("mission_id", "")) != "M00":
			new_missions.append(row)
	return {"ok": bool(r.get("ok", false)),
		"new_live_missions_at_t3": new_missions,
		"m00_units_after": r.get("m00_units_after", []),
		"ownership_after": r.get("ownership_after", {}),
		"expect": "replacement missions executing at t3; M00 no longer holds the freed force"}

func _any_review(run: Dictionary) -> Array:
	var out: Array = []
	for t_val in (run.get("turns", []) as Array):
		var rv: Dictionary = (t_val as Dictionary).get("review", {})
		if bool(rv.get("requested", false)):
			out.append({"turn": int((t_val as Dictionary).get("turn", 0)), "trigger": str(rv.get("trigger", ""))})
	return out

## --- mode: determinism ---------------------------------------------------------

func _battle_signature() -> Dictionary:
	var run: Dictionary = _run_battle(_failure_missions(), 5, FSB_MUTATE)
	var sigs: Array = []
	for t_val in (run.get("turns", []) as Array):
		var t: Dictionary = t_val
		for o_val in (t.get("orders", []) as Array):
			var o: Dictionary = o_val
			for e_val in (o.get("executed", []) as Array):
				sigs.append(JSON.stringify({"t": t.get("turn", 0), "m": o.get("mission_id", ""), "e": e_val}))
	var fps: Array = []
	for t_val in (run.get("turns", []) as Array):
		fps.append(JSON.stringify((t_val as Dictionary).get("units", {})))
	var aborts := _status_to(run, "ABORTED")
	return {"sigs": sigs, "fps": fps, "aborts": aborts, "m00": _m00_units(run.get("plan_final", {}))}

func _mode_determinism() -> Dictionary:
	var a := _battle_signature()
	var b := _battle_signature()
	return {"ok": a == b, "fingerprints_match": a == b, "sig_a": a, "sig_b": b}
