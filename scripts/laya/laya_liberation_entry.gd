extends SceneTree

## LIBERATION V1 behavioral matrix (deterministic, no network, no model).
## Run: godot --headless --path <proj> -s res://scripts/laya/laya_liberation_entry.gd --libmatrix [--run-dir=...]
## Python worker-render checks live in tools/laya/test_render_l2.py.

const BBC = preload("res://scripts/laya/laya_blackboard.gd")
const COC = preload("res://scripts/laya/laya_coordinator.gd")
const LYC = preload("res://scripts/laya/laya_controller.gd")
const MissionCls = preload("res://scripts/cloud2/cloud2_mission.gd")
const AuthoringCls = preload("res://scripts/cloud2/cloud2_victory_authoring.gd")
const VictoryPlanCls = preload("res://scripts/cloud2/cloud2_victory_plan.gd")
const VictoryResponseCls = preload("res://scripts/cloud2/cloud2_victory_response.gd")
const MissionManagerCls = preload("res://scripts/cloud2/cloud2_mission_manager.gd")

var _run_dir := ""
var _gates: Dictionary = {}
var _evidence: Dictionary = {}
var _playproof: Dictionary = {}


func _init() -> void:
	var all: Array = []
	all.append_array(OS.get_cmdline_user_args())
	all.append_array(OS.get_cmdline_args())
	var playproof := false
	for a in all:
		var s := str(a).strip_edges()
		if s.begins_with("--run-dir="):
			_run_dir = s.get_slice("=", 1).strip_edges()
		elif s == "--playproof":
			playproof = true
	if playproof:
		_run_playproof()
		_write_playproof_and_quit()
		return
	_run_libmatrix()
	_write_and_quit()


func _record(gate: String, ok: bool, evidence: Dictionary) -> void:
	_gates[gate] = ok
	_evidence[gate] = evidence
	print("[LIB][%s] %s" % [gate, "PASS" if ok else "FAIL"])


func _write_and_quit() -> void:
	var fails := 0
	for g in _gates.keys():
		if not bool(_gates[g]):
			fails += 1
	if not _run_dir.is_empty():
		var d := DirAccess.open("res://")
		if d != null:
			d.make_dir_recursive(_run_dir)
		var f := FileAccess.open(_run_dir + "/lib_matrix.json", FileAccess.WRITE)
		if f != null:
			f.store_string(JSON.stringify({"gates": _gates, "evidence": _evidence}, "  "))
			f.close()
			print("[LIB] evidence -> %s/lib_matrix.json" % _run_dir)
	print("[LIB] LIBMATRIX exit=%d" % fails)
	quit(fails)


func _run_playproof() -> void:
	var mission := {"mission_id": "M02",
		"intent": "Split pressure across both archers; keep cavalry mobile."}
	var units := ["R_CAV_1", "R_CAV_2"]
	var pools := _pools_split()
	var cands: Array = COC.generate("M02", units, pools, Callable())
	var plan := {}
	for c_val in cands:
		var a: Dictionary = (c_val as Dictionary).get("assignments", {})
		if str((a.get("R_CAV_1", {}) as Dictionary).get("target", "")) == "B_ARC_1" \
				and str((a.get("R_CAV_2", {}) as Dictionary).get("target", "")) == "B_ARC_2":
			plan = c_val
			break
	var bb = BBC.create(mission, units)
	bb.set_group_plan({"candidate_id": str(plan.get("candidate_id", "")),
		"text": str(plan.get("option_text", "")), "assignments": plan.get("assignments", {})})
	var a_pick := {"candidate_id": "a1", "action_type": "ATTACK", "target_id": "B_ARC_1"}
	bb.note_commitment("R_CAV_1", a_pick, "R_CAV_1 attacks B_ARC_1 (near archer)", 1)
	var b_ctx: String = str((bb.serialize_for_laya() as Dictionary).get("text", ""))
	var b_sees_a := b_ctx.contains("COMMIT R_CAV_1:ATTACK B_ARC_1")
	var b_pick := {"candidate_id": "a2", "action_type": "ATTACK", "target_id": "B_ARC_2"}
	bb.note_commitment("R_CAV_2", b_pick, "R_CAV_2 attacks B_ARC_2 (far archer)", 2)
	var committed: Array = bb.active_commitments()
	var targets := {}
	for c_val in committed:
		targets[str((c_val as Dictionary).get("unit", ""))] = \
			str((c_val as Dictionary).get("ref", ""))
	var coordinated: bool = b_sees_a and targets.get("R_CAV_1", "") == "B_ARC_1" \
		and targets.get("R_CAV_2", "") == "B_ARC_2" \
		and targets.get("R_CAV_1", "") != targets.get("R_CAV_2", "")
	_playproof = {"ranker": "STUB deterministic pick (model replaced; real blackboard/coordinator/pools)",
		"mission": mission, "group_candidates": cands.size(),
		"plan_id": str(plan.get("candidate_id", "-")),
		"plan_text": str(plan.get("option_text", "")),
		"trace": [
			{"step": 1, "actor": "R_CAV_1", "decision": a_pick,
				"effect": "R_CAV_1 attacks B_ARC_1 (near archer)"},
			{"step": 2, "actor": "BLACKBOARD",
				"commitment": "COMMIT R_CAV_1:ATTACK B_ARC_1",
				"b_context_excerpt": b_ctx.left(400)},
			{"step": 3, "actor": "R_CAV_2", "decision": b_pick,
				"conditioned_on": "COMMIT R_CAV_1:ATTACK B_ARC_1",
				"effect": "R_CAV_2 attacks B_ARC_2 (far archer)"}],
		"verdict": {"b_context_contains_a_commit": b_sees_a,
			"final_targets": targets, "coordinated_split": coordinated}}
	print("[LIB][PLAYPROOF] %s" % ("PASS" if coordinated else "FAIL"))


func _write_playproof_and_quit() -> void:
	var ok := bool((_playproof.get("verdict", {}) as Dictionary).get("coordinated_split", false))
	if not _run_dir.is_empty():
		var d := DirAccess.open("res://")
		if d != null:
			d.make_dir_recursive(_run_dir)
		var f := FileAccess.open(_run_dir + "/playproof.json", FileAccess.WRITE)
		if f != null:
			f.store_string(JSON.stringify(_playproof, "  "))
			f.close()
			print("[LIB] evidence -> %s/playproof.json" % _run_dir)
	print("[LIB] PLAYPROOF exit=%d" % (0 if ok else 1))
	quit(0 if ok else 1)


func _scan_file(path: String, tokens: Array) -> Array:
	var hits: Array = []
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ["UNREADABLE:" + path]
	var text := f.get_as_text()
	f.close()
	for t in tokens:
		if text.contains(str(t)):
			hits.append("%s :: %s" % [path, str(t)])
	return hits


func _rich_compact() -> Dictionary:
	return {"units": ["R_CAV_1", "R_CAV_2"],
		"intent": "One cavalry pressures the ranged line; the other threatens its retreat; avoid spear contact.",
		"effects": ["BLUE ranged line displaced."],
		"priority": "Keep both cavalry mobile.",
		"prefer": {"classes": ["ARCHER"], "areas": ["CENTER"]},
		"roles": {"R_CAV_1": "Create immediate pressure and force displacement.",
			"R_CAV_2": "Stay mobile and position to punish withdrawal."},
		"coord": "CAV_1 pressures first; CAV_2 exploits displacement.",
		"limits": ["Avoid prolonged contact with BLUE spearmen."],
		"support": [{"from": "R_CAV_2", "to": "R_CAV_1", "kind": "cover withdrawal"}]}


func _pools_split() -> Dictionary:
	return {
		"R_CAV_1": [{"candidate_id": "a1", "unit_id": "R_CAV_1", "action_type": "ATTACK",
				"target_id": "B_ARC_1", "target_class": "ARCHER"},
			{"candidate_id": "w1", "unit_id": "R_CAV_1", "action_type": "WAIT"}],
		"R_CAV_2": [{"candidate_id": "a2", "unit_id": "R_CAV_2", "action_type": "ATTACK",
				"target_id": "B_ARC_2", "target_class": "ARCHER"},
			{"candidate_id": "m2", "unit_id": "R_CAV_2", "action_type": "MOVE",
				"destination": [3, 4]}]}


func _pools_focus() -> Dictionary:
	return {
		"R_CAV_1": [{"candidate_id": "a1", "unit_id": "R_CAV_1", "action_type": "ATTACK",
				"target_id": "B_ARC_1", "target_class": "ARCHER"}],
		"R_CAV_2": [{"candidate_id": "a2", "unit_id": "R_CAV_2", "action_type": "ATTACK",
				"target_id": "B_ARC_1", "target_class": "ARCHER"},
			{"candidate_id": "a3", "unit_id": "R_CAV_2", "action_type": "ATTACK",
				"target_id": "B_ARC_2", "target_class": "ARCHER"}]}


func _run_libmatrix() -> void:
	_test_a_intent()
	_test_b_split()
	_test_c_focus()
	_test_d_invalidation()
	_test_e_matchup()
	_test_f_no_dictionary()
	_test_g_legality()
	_test_h_fog()
	_test_i_lifecycle()
	_test_j_legacy()


func _test_a_intent() -> void:
	var ex: Dictionary = AuthoringCls.expand_mission(_rich_compact(), "P1", 2, {})
	var m := (ex.get("mission", {}) as Dictionary) if bool(ex.get("ok", false)) else {}
	var mv: Dictionary = MissionCls.validate_mission(m) if not m.is_empty() else {"ok": false}
	var cm := (mv.get("mission", {}) as Dictionary) if bool(mv.get("ok", false)) else {}
	var bb = BBC.create(cm, ["R_CAV_1", "R_CAV_2"]) if not cm.is_empty() else null
	var ser: Dictionary = bb.serialize_for_laya() if bb != null else {}
	var vp := {"victory_plan_id": "LIB", "revision": 1, "current_phase_id": "P1",
		"phases": [{"phase_id": "P1", "purpose": "Test.", "missions": [cm]}]}
	var ctx: Dictionary = VictoryPlanCls.victory_context_for_laya(vp, cm) if not cm.is_empty() else {}
	var a_ok := bool(ex.get("ok", false)) and str(m.get("task", "")) == "EXECUTE" \
		and bool(mv.get("ok", false)) \
		and str(cm.get("intent", "")).contains("threatens its retreat") \
		and str((cm.get("force_roles", {}) as Dictionary).get("R_CAV_2", "")).contains("punish withdrawal") \
		and str(ser.get("text", "")).contains("threatens its retreat") \
		and str(ctx.get("unit_mission_intent", "")).contains("threatens its retreat")
	_record("A_free_intent", a_ok, {"task": str(m.get("task", "")),
		"intent_kept": str(cm.get("intent", "")).left(60),
		"tactical_chars": int(ser.get("chars", 0)),
		"ctx_intent": str(ctx.get("unit_mission_intent", "")).left(60)})


func _test_b_split() -> void:
	var cands: Array = COC.generate("M02", ["R_CAV_1", "R_CAV_2"], _pools_split(), Callable())
	var split := {}
	for c_val in cands:
		var a: Dictionary = (c_val as Dictionary).get("assignments", {})
		if str((a.get("R_CAV_1", {}) as Dictionary).get("target", "")) == "B_ARC_1" \
				and str((a.get("R_CAV_2", {}) as Dictionary).get("target", "")) == "B_ARC_2":
			split = c_val
			break
	var bb = BBC.create({"mission_id": "M02", "intent": "Split pressure."}, ["R_CAV_1", "R_CAV_2"])
	if not split.is_empty():
		bb.set_group_plan({"candidate_id": str(split.get("candidate_id", "")),
			"text": str(split.get("option_text", "")), "assignments": split.get("assignments", {})})
		bb.note_commitment("R_CAV_1", {"action_type": "ATTACK", "target_id": "B_ARC_1"},
			"R_CAV_1 attacks B_ARC_1", 1)
	var ser: Dictionary = bb.serialize_for_laya()
	var b_ok := not cands.is_empty() and not split.is_empty() \
		and str(ser.get("text", "")).contains("COMMIT R_CAV_1:ATTACK B_ARC_1")
	_record("B_split_roles", b_ok, {"candidates": cands.size(),
		"split_id": str(split.get("candidate_id", "-")),
		"unit2_sees_commit": str(ser.get("text", "")).contains("COMMIT R_CAV_1")})


func _test_c_focus() -> void:
	var cands: Array = COC.generate("M02", ["R_CAV_1", "R_CAV_2"], _pools_focus(), Callable())
	var foc := {}
	for c_val in cands:
		var a: Dictionary = (c_val as Dictionary).get("assignments", {})
		if str((a.get("R_CAV_1", {}) as Dictionary).get("target", "")) == "B_ARC_1" \
				and str((a.get("R_CAV_2", {}) as Dictionary).get("target", "")) == "B_ARC_1":
			foc = c_val
			break
	var both := false
	if not foc.is_empty():
		var fa: Dictionary = foc.get("assignments", {})
		both = str((fa.get("R_CAV_1", {}) as Dictionary).get("target", "")) == "B_ARC_1" \
			and str((fa.get("R_CAV_2", {}) as Dictionary).get("target", "")) == "B_ARC_1"
	_record("C_focus_fire", not foc.is_empty() and both,
		{"candidates": cands.size(), "focus_id": str(foc.get("candidate_id", "-"))})


func _test_d_invalidation() -> void:
	var bb = BBC.create({"mission_id": "M02", "target_preferences": {"units": ["B_ARC_1"]}},
		["R_CAV_1", "R_CAV_2"])
	bb.note_commitment("R_CAV_1", {"action_type": "ATTACK", "target_id": "B_ARC_1"},
		"R_CAV_1 attacks B_ARC_1", 1)
	bb.invalidate_stale(["R_CAV_1", "R_CAV_2"], ["B_ARC_2"])
	var st := ""
	for c_val in (bb.commitments as Array):
		st = str((c_val as Dictionary).get("status", ""))
	var d_ok := st == "INVALIDATED" and not (bb.invalidated as Array).is_empty() \
		and (bb.focus_targets as Array).is_empty() \
		and str((bb.serialize_for_laya() as Dictionary).get("text", "")).contains("DROP")
	_record("D_invalidation", d_ok, {"status": st,
		"invalidated": (bb.invalidated as Array).size(), "focus_left": (bb.focus_targets as Array).size()})


func _test_e_matchup() -> void:
	var atk := {"action_type": "ATTACK", "target_id": "B_ARC_1", "target_class": "ARCHER",
		"target_q": 5, "target_r": 6, "matchup_mult": 1.5, "candidate_id": "a1"}
	var unit := {"q": 3, "r": 4}
	var troop_of := func(_tid: String) -> String: return "band"
	var text: String = LYC.format_option_text(atk, unit, [], troop_of)
	var mm: float = CombatCalculator.get_matchup_mult("CAVALRY", "ARCHER")
	var hits: Array = []
	for p in ["res://scripts/laya/laya_controller.gd", "res://scripts/laya/laya_coordinator.gd",
			"res://scripts/laya/laya_blackboard.gd"]:
		hits.append_array(_scan_file(p, ["GOOD_TARGET", "ATTACK_THIS", "PRIORITY_TARGET",
			"BEST_TARGET", "should_attack", "preferred_target"]))
	_record("E_matchup", text.contains("x1.50") and mm == CombatCalculator.get_matchup_mult("CAVALRY", "ARCHER") and hits.is_empty(),
		{"option_text": text, "matchup": mm, "policy_hits": hits})


func _test_f_no_dictionary() -> void:
	var p1 := _pools_split()
	var c1: Array = COC.generate("M02", ["R_CAV_1", "R_CAV_2"], p1, Callable())
	var c1b: Array = COC.generate("M02", ["R_CAV_1", "R_CAV_2"], p1, Callable())
	var p2 := {
		"R_CAV_1": (p1["R_CAV_1"] as Array).duplicate(true),
		"R_CAV_2": (p1["R_CAV_2"] as Array).duplicate(true)}
	(p2["R_CAV_1"] as Array).append({"candidate_id": "a9", "unit_id": "R_CAV_1",
		"action_type": "ATTACK", "target_id": "B_SPE_1", "target_class": "SPEARMAN"})
	var c2: Array = COC.generate("M02", ["R_CAV_1", "R_CAV_2"], p2, Callable())
	var sees_new := false
	for c_val in c2:
		if str((c_val as Dictionary).get("option_text", "")).contains("B_SPE_1"):
			sees_new = true
	var derived_ok := true
	for c_val in c2:
		for uid in (((c_val as Dictionary).get("assignments", {}) as Dictionary) as Dictionary).keys():
			var a: Dictionary = ((c_val as Dictionary).get("assignments", {}) as Dictionary)[uid]
			var k := str(a.get("kind", ""))
			var t := str(a.get("target", ""))
			if k == "ATTACK" and not t in ["B_ARC_1", "B_ARC_2", "B_SPE_1"]:
				derived_ok = false
	var hits: Array = []
	for p in ["res://scripts/laya/laya_blackboard.gd", "res://scripts/laya/laya_coordinator.gd",
			"res://scripts/laya/laya_controller.gd", "res://tools/laya/worker.py"]:
		hits.append_array(_scan_file(p, ["DOUBLE_CHARGE", "RETREAT_CUT", "PIN_ACTION",
			"FEINT", "PINCER", "ENVELOP", "TACTICS_DICTIONARY"]))
	_record("F_no_dictionary", JSON.stringify(c1) == JSON.stringify(c1b) and sees_new and derived_ok and hits.is_empty(),
		{"deterministic": JSON.stringify(c1) == JSON.stringify(c1b),
			"new_target_seen": sees_new, "derived_only": derived_ok, "dict_hits": hits})


func _test_g_legality() -> void:
	var cands: Array = COC.generate("M02", ["R_CAV_1", "R_CAV_2"], _pools_split(), Callable())
	var shape_ok := not cands.is_empty()
	for c_val in cands:
		var cd: Dictionary = c_val
		if not str(cd.get("candidate_id", "")).begins_with("G"):
			shape_ok = false
		if cd.has("candidate_id") and str(cd.get("candidate_id", "")).begins_with("a"):
			shape_ok = false
		for uid in ((cd.get("assignments", {}) as Dictionary) as Dictionary).keys():
			var k := str((((cd.get("assignments", {}) as Dictionary) as Dictionary)[uid] as Dictionary).get("kind", ""))
			if not k in ["ATTACK", "ASSAULT", "HOLD", "REPOSITION", "MOVE"]:
				shape_ok = false
	var hits: Array = []
	for p in ["res://scripts/laya/laya_blackboard.gd", "res://scripts/laya/laya_coordinator.gd"]:
		hits.append_array(_scan_file(p, ["_bridge", "get_manager", "build_knowledge",
			"OS.execute", "create_process"]))
	_record("G_legality", shape_ok and hits.is_empty(),
		{"candidates": cands.size(), "skeleton_only": shape_ok, "exec_hits": hits})


func _test_h_fog() -> void:
	var bb = BBC.create({"mission_id": "M02", "intent": "Probe.",
		"target_preferences": {"units": ["B_ARC_1"]}}, ["R_CAV_1"])
	bb.set_group_plan({"candidate_id": "G1", "text": "R_CAV_1:ATTACK B_ARC_1",
		"assignments": {"R_CAV_1": {"kind": "ATTACK", "target": "B_ARC_1"}}})
	bb.note_commitment("R_CAV_1", {"action_type": "ATTACK", "target_id": "B_ARC_1"},
		"R_CAV_1 attacks B_ARC_1", 1)
	bb.note_risks(["B_SPE_1 SPEARMAN 3hex of R_CAV_1 [band]"])
	var blob := str((bb.serialize_for_laya() as Dictionary).get("text", ""))
	for c_val in COC.generate("M02", ["R_CAV_1", "R_CAV_2"], _pools_split(), Callable()):
		blob += "\n" + str((c_val as Dictionary).get("option_text", ""))
	var leak := false
	for k in ["morale", "fatigue", "soldier_count", "max_count", "hit_points"]:
		if blob.contains(k):
			leak = true
	_record("H_fog", not leak, {"chars": blob.length(), "leak": leak})


func _lib_initial_doc() -> Dictionary:
	return {"objective": "Destroy B_HQ_1.", "end_state": "RED wins.", "cadence": 4,
		"doctrine": [0.5, 0.5, 0.5, 0.5, 0.5, 0.5],
		"phases": [
			{"id": "P1", "name": "OPENING", "purpose": "Dislocate support.",
				"missions": [{"units": ["R_CAV_1", "R_CAV_2"],
					"intent": "Pressure the ranged line; preserve mobility.",
					"roles": {"R_CAV_1": "Press.", "R_CAV_2": "Exploit."},
					"win": [{"trigger": "TURNS_ELAPSED", "params": {"turns": 2, "since": 1}}]}],
				"transition": {"on_success": {"action": "ADVANCE", "next_phase_id": "P2"}}},
			{"id": "P2", "name": "CLOSING", "purpose": "Finish.",
				"missions": [{"units": ["R_CAV_1"], "task": "ATTACK", "area": "ANY"}]}]}


func _test_i_lifecycle() -> void:
	var roster := ["R_CAV_1", "R_CAV_2"]
	var mgr = MissionManagerCls.new()
	var parsed: Dictionary = VictoryResponseCls.parse_initial(JSON.stringify(_lib_initial_doc()),
		{"turn": 1, "snapshot_id": "LIB_T1", "roster": roster})
	var applied: Dictionary = mgr.vp_apply_initial(parsed.get("plan", {}), 1, "LIB_T1",
		"LIB_BATTLE", "worker/general") if bool(parsed.get("ok", false)) else {"ok": false}
	var m02 := {}
	for m_val in ((mgr.get_plan() as Dictionary).get("missions", []) as Array):
		if m_val is Dictionary and str((m_val as Dictionary).get("mission_id", "")) == "M01":
			m02 = m_val
	var keep_p: Dictionary = VictoryResponseCls.parse_review(
		JSON.stringify({"decision": "KEEP", "reason": "On track."}), {"turn": 2, "snapshot_id": "LIB_T2"})
	var keep_c: Dictionary = mgr.vp_compute_review(keep_p.get("review", {}), {"turn": 2}, 2)
	var keep_x: Dictionary = mgr.vp_commit_review(keep_c, {"type": "BATTLE"}, 2, "LIB_T2", "REVIEW_CADENCE")
	var adv_p: Dictionary = VictoryResponseCls.parse_review(
		JSON.stringify({"decision": "ADVANCE_PHASE", "reason": "P1 done."}), {"turn": 5, "snapshot_id": "LIB_T5"})
	var adv_c: Dictionary = mgr.vp_compute_review(adv_p.get("review", {}), {"turn": 5}, 5)
	var adv_x: Dictionary = mgr.vp_commit_review(adv_c, {"type": "BATTLE"}, 5, "LIB_T5", "REVIEW_CADENCE")
	var amend_phases: Array = []
	for p_val in ((mgr.vp_get_plan() as Dictionary).get("phases", []) as Array):
		amend_phases.append((p_val as Dictionary).duplicate(true))
	for a_val in amend_phases:
		for m_val in (((a_val as Dictionary).get("missions", []) as Array)):
			if m_val is Dictionary and str((m_val as Dictionary).get("mission_id", "")) == "M01":
				(m_val as Dictionary)["intent"] = "Revised pressure."
	var amd_p: Dictionary = VictoryResponseCls.parse_review(
		JSON.stringify({"decision": "AMEND_PLAN", "reason": "Adapt.", "phases": amend_phases}),
		{"turn": 6, "snapshot_id": "LIB_T6"})
	var amd_c: Dictionary = mgr.vp_compute_review(amd_p.get("review", {}), {"turn": 6}, 6)
	var amd_x: Dictionary = mgr.vp_commit_review(amd_c, {"type": "BATTLE"}, 6, "LIB_T6", "REVIEW_CADENCE")
	var emg_m := {"mission_id": "M99", "task": "HOLD", "area": "ANY", "assigned_units": ["R_CAV_1"],
		"objective": {"kind": "NONE"}, "engagement": {"policy": "ATTACK_IF_ADVANTAGEOUS"}}
	var emg_p: Dictionary = VictoryResponseCls.parse_review(JSON.stringify({"decision": "EMERGENCY_REPLAN",
		"reason": "Collapse.", "final_objective": "Hold.", "desired_end_state": "Survive.",
		"phases": [{"phase_id": "P1", "name": "HOLD", "purpose": "Survive.", "missions": [emg_m],
			"success_conditions": [{"trigger": "TURNS_ELAPSED", "params": {"turns": 3, "since": 7}}],
			"transition": {"on_success": {"action": "HOLD_FOR_REVIEW", "next_phase_id": ""}}}]}),
		{"turn": 7, "snapshot_id": "LIB_T7", "roster": roster})
	var emg_c: Dictionary = mgr.vp_compute_review(emg_p.get("review", {}), {"turn": 7}, 7)
	var i_ok := bool(parsed.get("ok", false)) and bool(applied.get("ok", false)) \
		and str(m02.get("intent", "")).contains("preserve mobility") \
		and bool(keep_x.get("ok", false)) and bool(adv_x.get("ok", false)) \
		and bool(amd_x.get("ok", false)) and bool(emg_c.get("ok", false))
	_record("I_lifecycle", i_ok, {"initial": bool(applied.get("ok", false)),
		"m01_intent": str(m02.get("intent", "")).left(50),
		"keep": bool(keep_x.get("ok", false)), "advance": bool(adv_x.get("ok", false)),
		"amend": bool(amd_x.get("ok", false)), "emergency": bool(emg_c.get("ok", false)),
		"adv_code": str(adv_c.get("code", "")), "amd_code": str(amd_c.get("code", "")),
		"emg_p_code": str(emg_p.get("code", "")), "emg_p_detail": str(emg_p.get("detail", "")).left(160),
		"emg_c_code": str(emg_c.get("code", "")), "emg_c_detail": str(emg_c.get("detail", "")).left(160)})


func _test_j_legacy() -> void:
	var mv: Dictionary = MissionCls.validate_mission({"mission_id": "M01", "task": "FIX",
		"area": "CENTER", "assigned_units": ["R_INF_1"]})
	var cm := (mv.get("mission", {}) as Dictionary) if bool(mv.get("ok", false)) else {}
	var bb = BBC.create(cm, ["R_INF_1"]) if not cm.is_empty() else null
	var ser: Dictionary = bb.serialize_for_laya() if bb != null else {}
	var sk: Array = COC.skeletons_for_unit("R_INF_1",
		[{"candidate_id": "w", "unit_id": "R_INF_1", "action_type": "WAIT"}], Callable())
	var single: Array = COC.generate("M01", ["R_INF_1"],
		{"R_INF_1": [{"candidate_id": "w", "unit_id": "R_INF_1", "action_type": "WAIT"}]}, Callable())
	var troop_of := func(_tid: String) -> String: return "band"
	var legacy_text: String = LYC.format_option_text({"action_type": "ATTACK",
		"target_id": "B_INF_1", "target_class": "INFANTRY", "target_q": 1, "target_r": 2,
		"candidate_id": "a"}, {"q": 0, "r": 0}, [], troop_of)
	_record("J_legacy", bool(mv.get("ok", false)) and str(cm.get("task", "")) == "FIX" \
		and str(cm.get("intent", "")).is_empty() \
		and str(ser.get("text", "")).begins_with("BB M01") \
		and not str(ser.get("text", "")).contains("NEED ") \
		and sk.size() == 1 and str((sk[0] as Dictionary).get("kind", "")) == "HOLD" \
		and single.is_empty() and not legacy_text.contains(" x"),
		{"task": str(cm.get("task", "")), "skel": str((sk[0] as Dictionary).get("kind", "")) if not sk.is_empty() else "-",
			"legacy_text": legacy_text})
