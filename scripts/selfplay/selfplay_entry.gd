extends SceneTree

## HEADLESS SELF-PLAY V1 — entry harness (static gates + autonomous match).
##
## Static gates (no scene, no models):
##   godot --headless --path <project> --script res://scripts/selfplay/selfplay_entry.gd \
##     -- --run-dir=res://artifacts/headless_selfplay_v1/raw --gates=static
##
## Autonomous match (Brain/Laya via env; Godot authoritative; zero input):
##   SELFPLAY_OUT_DIR=<match dir> SELFPLAY_RUN_ID=<run> SELFPLAY_MATCH_ID=<m>
##   SELFPLAY_MAX_TURNS=2 SELFPLAY_NO_PROGRESS_TURNS=6
##   SELFPLAY_MATCH_BUDGET_SEC=5400 SELFPLAY_GENERAL_TIMEOUT_SEC=900
##   SELFPLAY_PREFETCH_BUDGET_SEC=1200
##   SYMLOC_BRAIN_ENDPOINT=http://127.0.0.1:8092 SYMLOC_BRAIN_MODEL=Qwen/Qwen3.5-9B
##   LAYA_URL=http://127.0.0.1:11442
##   godot --headless --path <project> --script res://scripts/selfplay/selfplay_entry.gd
##
## Markers: SELFPLAY_DONE <match.json> / SELFPLAY_FAILED <reason>.
## NO TRAINING: rollout + recording + benchmark only.

const MatchLib = preload("res://scripts/selfplay/selfplay_match.gd")
const TrackerCls = preload("res://scripts/selfplay/selfplay_tracker.gd")
const RecorderCls = preload("res://scripts/selfplay/selfplay_recorder.gd")
const ManagerCls = preload("res://scripts/cloud2/cloud2_mission_manager.gd")
const VictoryRespCls = preload("res://scripts/cloud2/cloud2_victory_response.gd")
const AuthoringCls = preload("res://scripts/cloud2/cloud2_victory_authoring.gd")
const PlanCls = preload("res://scripts/cloud2/cloud2_victory_plan.gd")
const PacketCls = preload("res://scripts/cloud2/cloud2_general_packet.gd")
const TurnCtrlCls = preload("res://scripts/cloud2/cloud2_turn_controller.gd")
const AdapterCls = preload("res://scripts/cloud2/cloud2_adapter.gd")
const MemoryCls = preload("res://scripts/cloud2/cloud2_battle_memory.gd")

var _gates := {}
var _evidence := {}
var _run_dir := ""
var _wanted := ["match"]


func _init() -> void:
	var all: Array = []
	all.append_array(OS.get_cmdline_user_args())
	all.append_array(OS.get_cmdline_args())
	for a in all:
		var s := str(a).strip_edges()
		if s.begins_with("--run-dir="):
			_run_dir = s.get_slice("=", 1).strip_edges()
		elif s.begins_with("--gates="):
			_wanted = s.get_slice("=", 1).strip_edges().split(",")
	_run_async()


func _record(gate: String, ok: bool, evidence: Dictionary) -> void:
	_gates[gate] = ok
	_evidence[gate] = evidence
	print("[SELFPLAY][%s] %s %s" % [gate, "PASS" if ok else "FAIL", JSON.stringify(evidence)])


func _run_async() -> void:
	await process_frame
	if "static" in _wanted:
		_test_static()
		_write_static_and_quit()
		return
	await _run_match()


func _write_static_and_quit() -> void:
	var fails := 0
	for g in _gates.keys():
		if not bool(_gates[g]):
			fails += 1
	if not _run_dir.is_empty():
		var d := DirAccess.open("res://")
		if d != null:
			d.make_dir_recursive(_run_dir)
		var f := FileAccess.open(_run_dir + "/gates_selfplay_static.json", FileAccess.WRITE)
		if f != null:
			f.store_string(JSON.stringify({"gates": _gates, "evidence": _evidence}, "  "))
			f.close()
			print("[SELFPLAY] evidence -> %s/gates_selfplay_static.json" % _run_dir)
	print("[SELFPLAY] STATIC exit=%d" % fails)
	quit(fails)


# ------------------------------------------------------------------
# static gates
# ------------------------------------------------------------------

func _test_static() -> void:
	# S1: canonical reward contract (+5/-3/-2), all three outcomes.
	var r := MatchLib.outcomes_for_winner("RED")
	var b := MatchLib.outcomes_for_winner("BLUE")
	var dr := MatchLib.outcomes_for_winner("DRAW")
	_record("S1_reward_contract",
		int(r.get("reward_red", 0)) == 5 and int(r.get("reward_blue", 0)) == -3 \
		and int(b.get("reward_red", 0)) == -3 and int(b.get("reward_blue", 0)) == 5 \
		and int(dr.get("reward_red", 0)) == -2 and int(dr.get("reward_blue", 0)) == -2,
		{"red": r, "blue": b, "draw": dr})
	# S2: VP_HISTORY regression (explicit-priority verbatim echo passes;
	# guards still fire; stored terminal bodies preserved verbatim).
	_record("S2_vp_history_regression", _vp_regression()[0], _vp_regression()[1])
	# S3: stalemate tracker (progress resets; quiet turns accumulate).
	_record("S3_stalemate_tracker", _tracker_check()[0], _tracker_check()[1])
	# S4: policy packets carry no exact foe troop rows (fog by construction).
	var obs := _fixture_obs()
	var pr: Dictionary = PacketCls.build_victory_initial(obs, "red")
	var pb: Dictionary = PacketCls.build_victory_initial(obs, "blue")
	var foe_exact := 0
	for pkt in [pr, pb]:
		var cs: Dictionary = (pkt.get("compact_state", {}) as Dictionary)
		for e_val in (cs.get("known_enemy_units", []) as Array):
			if e_val is Dictionary and ((e_val as Dictionary).has("soldier_count") or (e_val as Dictionary).has("soldiers")):
				foe_exact += 1
	_record("S4_packet_fog", foe_exact == 0 \
		and str(pr.get("acting_side", "")) == "RED" and str(pb.get("acting_side", "")) == "BLUE",
		{"foe_exact_rows": foe_exact,
			"sides": [str(pr.get("acting_side", "")), str(pb.get("acting_side", ""))]})
	# S5: brain timeout helper (default 240; env override + clamp).
	var prev := OS.get_environment("SELFPLAY_GENERAL_TIMEOUT_SEC")
	OS.set_environment("SELFPLAY_GENERAL_TIMEOUT_SEC", "")
	var dflt := TurnCtrlCls.brain_timeout_sec()
	OS.set_environment("SELFPLAY_GENERAL_TIMEOUT_SEC", "900")
	var over := TurnCtrlCls.brain_timeout_sec()
	OS.set_environment("SELFPLAY_GENERAL_TIMEOUT_SEC", "5")
	var cl := TurnCtrlCls.brain_timeout_sec()
	OS.set_environment("SELFPLAY_GENERAL_TIMEOUT_SEC", prev)
	_record("S5_brain_timeout", dflt == 240.0 and over == 900.0 and cl == 60.0,
		{"default": dflt, "override": over, "clamped": cl})
	# S6: token usage passthrough incl. Qwen reasoning/final split.
	var wire := {"choices": [{"finish_reason": "stop", "message": {
		"role": "assistant", "content": "{\"decision\": \"KEEP\"}",
		"reasoning_content": "thinking..."}}],
		"usage": {"prompt_tokens": 4119, "completion_tokens": 7853,
			"total_tokens": 11972,
			"completion_tokens_details": {"reasoning_tokens": 7643,
				"final_output_tokens": 207}}}
	var judged: Dictionary = AdapterCls.extract_openai_final(wire)
	var usage: Dictionary = (judged.get("envelope", {}) as Dictionary).get("usage", {})
	var bare: Dictionary = AdapterCls.extract_openai_final(
		{"choices": [{"finish_reason": "stop",
			"message": {"role": "assistant", "content": "{\"decision\": \"KEEP\"}"}}]})
	var busage: Dictionary = (bare.get("envelope", {}) as Dictionary).get("usage", {})
	_record("S6_usage_passthrough",
		bool(judged.get("ok", false)) and int(usage.get("prompt_tokens", 0)) == 4119 \
		and int(usage.get("completion_tokens", 0)) == 7853 \
		and int(usage.get("reasoning_tokens", 0)) == 7643 \
		and int(usage.get("final_output_tokens", 0)) == 207 \
		and busage.is_empty(),
		{"qwen_usage": usage, "fixture_usage_empty": busage.is_empty()})
	# S7: self-play turn-cap env precedence (explicit config wins).
	var mprev := OS.get_environment("SELFPLAY_MAX_TURNS")
	var sprev := OS.get_environment("SYMLOC_MAX_TURNS")
	OS.set_environment("SELFPLAY_MAX_TURNS", "3")
	OS.set_environment("SYMLOC_MAX_TURNS", "9")
	var w1 := MatchLib.max_turns()
	OS.set_environment("SELFPLAY_MAX_TURNS", "")
	var w2 := MatchLib.max_turns()
	OS.set_environment("SELFPLAY_MAX_TURNS", mprev)
	OS.set_environment("SYMLOC_MAX_TURNS", sprev)
	_record("S7_turncap_precedence", w1 == 3 and w2 == 9,
		{"explicit": w1, "fallback": w2})
	# S8: fresh-brain isolation (SELFPLAY_FRESH_BRAIN=1 skips disk adoption;
	# unset adopts as production does). Real fixture file round-trip.
	_record("S8_fresh_brain_isolation", _fresh_check()[0], _fresh_check()[1])
	# S9: repair prompt restates the compact structural schema (it replaces
	# the system prompt that carries the spec; without it local models
	# invent plan_name/num/title structure).
	var rp := VictoryRespCls.build_repair_prompt("VP_INVALID_JSON", "x", "stop", 100)
	var rp_len := VictoryRespCls.build_repair_prompt("VP_INVALID_JSON", "x", "length", 100)
	_record("S9_repair_prompt_schema",
		rp.contains("objective") and rp.contains("phases[]") \
		and rp.contains("groups{NAME:[unit_ids]}") and rp.contains("vs|target|zone") \
		and rp.contains("plan_name/num/title") and rp.contains("VP_INVALID_JSON") \
		and rp.contains("REQUEST_REVIEW") and rp.contains("fix ONLY the named defect") \
		and not rp.contains("Shorten every string") \
		and rp_len.contains("Shorten every string") and rp_len.contains("CUT OFF"),
		{"chars": rp.length(), "len_chars": rp_len.length()})


func _fixture_obs() -> Dictionary:
	return {
		"ok": true, "side": "red", "turn": 1,
		"snapshot_id": "FIX", "battle_id": "FIXB", "scenario_id": "FIXS",
		"mission": {"type": "BATTLE", "objective": "x", "turn_limit": 6},
		"parity": {"state_version": 3, "fingerprint": "f"},
		"friendly_units": [
			{"unit_id": "R_INF_1", "class": "INFANTRY", "region": "CENTER",
				"soldiers": 100, "troop_estimate": "band", "q": 1, "r": 1}],
		"known_enemy_units": [
			{"unit_id": "B_INF_1", "class": "INFANTRY", "region": "NORTH",
				"contact_state": "current_visible", "troop_estimate": "band", "q": 2, "r": 2}],
		"recent_events": [],
	}


func _compact_doc(with_priority: bool) -> Dictionary:
	var p1 := {"id": "P1", "name": "FIX CENTER", "purpose": "Pin the enemy center in place.",
		"intent": "Fix center; watch flanks.", "groups": {"CenterFix": ["R_INF_1", "R_INF_2"]},
		"missions": [{"task": "FIX", "area": "CENTER", "units": ["R_INF_1", "R_INF_2"],
			"vs": "INFANTRY", "preserve": true,
			"win": [{"when": "TURNS_ELAPSED", "turns": 3, "since": 1}], "stop": ["HQ_THREATENED"]}],
		"win": [{"when": "TURNS_ELAPSED", "turns": 3, "since": 1}],
		"lose": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.4}],
		"abort": ["HQ_THREATENED"], "next": "P2", "on_fail": "HOLD",
		"reserve": ["R_CAV_1"], "release": [{"when": "TURNS_ELAPSED", "turns": 3, "since": 1}],
		"exploit": "Pursue if center breaks."}
	var p2 := {"id": "P2", "name": "BREAKTHROUGH", "purpose": "Break the weakened line.",
		"intent": "Commit reserve; break through.", "groups": {"Reserve": ["R_CAV_1"]},
		"missions": [{"task": "ATTACK", "area": "CENTER", "units": ["R_CAV_1"], "vs": "INFANTRY"}],
		"win": [{"when": "TURNS_ELAPSED", "turns": 6, "since": 1}], "next": "END"}
	if with_priority:
		p1["priority"] = 5
		p2["priority"] = 2
	return {"objective": "Destroy the enemy HQ.", "end_state": "Enemy HQ destroyed.",
		"cadence": 4, "doctrine": [0.6, 0.5, 0.6, 0.6, 0.7, 0.2], "phases": [p1, p2]}


func _setup_mgr(with_priority: bool):
	var roster := ["R_INF_1", "R_INF_2", "R_CAV_1"]
	var authored: Dictionary = AuthoringCls.author_initial(
		_compact_doc(with_priority), {"roster": roster})
	if not bool(authored.get("ok", false)):
		return null
	var mgr = ManagerCls.new()
	var applied: Dictionary = mgr.vp_apply_initial(
		authored.get("plan", {}), 1, "PROBE_T1", "PROBE_BATTLE", "selfplay/static")
	if not bool(applied.get("ok", false)):
		return null
	var adv_p: Dictionary = VictoryRespCls.parse_review(
		JSON.stringify({"decision": "ADVANCE_PHASE", "reason": "P1 done."}),
		{"turn": 5, "snapshot_id": "PROBE_T5"})
	var adv_c: Dictionary = mgr.vp_compute_review(adv_p.get("review", {}), {"turn": 5}, 5)
	var adv_x: Dictionary = mgr.vp_commit_review(
		adv_c, {"type": "BATTLE"}, 5, "PROBE_T5", "REVIEW_CADENCE")
	if not bool(adv_x.get("ok", false)):
		return null
	return mgr


func _amend(mgr, echo_phases: Array) -> Dictionary:
	var authored: Dictionary = AuthoringCls.author_phases(echo_phases, {})
	if not bool(authored.get("ok", false)):
		return {"stage": "author", "ok": false, "code": str(authored.get("code", ""))}
	var parsed := {"decision": "AMEND_PLAN", "reason": "Static amend.",
		"phases": authored.get("phases", []), "has_hypotheses": false, "hypotheses": []}
	var computed: Dictionary = mgr.vp_compute_review(parsed, {"turn": 6}, 6)
	if not bool(computed.get("ok", false)):
		return {"stage": "compute", "ok": false, "code": str(computed.get("code", "")),
			"detail": str(computed.get("detail", ""))}
	return {"stage": "compute", "ok": true, "code": "", "computed": computed}


func _vp_regression() -> Array:
	var ev := {}
	var mgr_a = _setup_mgr(false)
	if mgr_a == null:
		return [false, {"error": "setup_a"}]
	var vp_a: Dictionary = mgr_a.vp_get_plan()
	var echo_a: Array = ((AuthoringCls.compress_plan(vp_a).get("authoring", {}) as Dictionary).get("phases", []) as Array).duplicate(true)
	var ra := _amend(mgr_a, echo_a)
	ev["A_verbatim"] = ra.get("ok", false)
	var mgr_b = _setup_mgr(true)
	if mgr_b == null:
		return [false, {"error": "setup_b"}]
	var vp_b: Dictionary = mgr_b.vp_get_plan()
	var echo_b: Array = ((AuthoringCls.compress_plan(vp_b).get("authoring", {}) as Dictionary).get("phases", []) as Array).duplicate(true)
	var rb := _amend(mgr_b, echo_b)
	ev["B_priority_echo"] = rb.get("ok", false)
	ev["B_echo_has_priority"] = (echo_b[0] as Dictionary).has("priority")
	# E: rich drift in a terminal mission passes comparison (rich fields are
	# not in the echo contract) AND the stored body wins the merge.
	var mgr_e = _setup_mgr(true)
	var vp_e: Dictionary = mgr_e.vp_get_plan()
	var echo_e: Array = ((AuthoringCls.compress_plan(vp_e).get("authoring", {}) as Dictionary).get("phases", []) as Array).duplicate(true)
	((echo_e[0] as Dictionary).get("missions", []) as Array)[0]["roles"] = {"R_INF_1": "Rewritten role text."}
	var re := _amend(mgr_e, echo_e)
	ev["E_rich_drift_ok"] = re.get("ok", false)
	if bool(re.get("ok", false)):
		var merged: Dictionary = (re.get("computed", {}) as Dictionary).get("new_vp", {})
		var mp1 := PlanCls.phase_by_id(merged, "P1")
		var sp1 := PlanCls.phase_by_id(vp_e, "P1")
		ev["E_priority_preserved"] = int(mp1.get("priority", -1)) == 5
		ev["E_body_verbatim"] = mp1 == sp1
	else:
		ev["E_priority_preserved"] = false
		ev["E_body_verbatim"] = false
	var mgr_c = _setup_mgr(false)
	var vp_c: Dictionary = mgr_c.vp_get_plan()
	var echo_c: Array = ((AuthoringCls.compress_plan(vp_c).get("authoring", {}) as Dictionary).get("phases", []) as Array).duplicate(true)
	(echo_c[0] as Dictionary)["purpose"] = "Totally rewritten history."
	var rc := _amend(mgr_c, echo_c)
	ev["C_paraphrase_rejected"] = (not bool(rc.get("ok", false))) and str(rc.get("code", "")) == "VP_HISTORY"
	var mgr_d = _setup_mgr(false)
	var vp_d: Dictionary = mgr_d.vp_get_plan()
	var echo_d: Array = ((AuthoringCls.compress_plan(vp_d).get("authoring", {}) as Dictionary).get("phases", []) as Array).duplicate(true)
	echo_d.pop_front()
	var rd := _amend(mgr_d, echo_d)
	ev["D_dropped_rejected"] = (not bool(rd.get("ok", false))) and str(rd.get("code", "")) == "VP_HISTORY"
	var ok := bool(ev["A_verbatim"]) and bool(ev["B_priority_echo"]) \
		and not bool(ev["B_echo_has_priority"]) and bool(ev["E_rich_drift_ok"]) \
		and bool(ev["E_priority_preserved"]) and bool(ev["E_body_verbatim"]) \
		and bool(ev["C_paraphrase_rejected"]) and bool(ev["D_dropped_rejected"])
	return [ok, ev]


func _tracker_check() -> Array:
	var ev := {}
	var snap := func(turn: int, rs: int, bs: int, ru: int, bu: int) -> Dictionary:
		return {"turn": turn, "red_soldiers": rs, "blue_soldiers": bs,
			"red_units": ru, "blue_units": bu,
			"red_hq_hp": 50, "blue_hq_hp": 50,
			"red_hq_alive": true, "blue_hq_alive": true}
	var t = TrackerCls.new()
	t.configure(3, snap.call(1, 1000, 1000, 10, 10))
	var n2 := t.note(snap.call(2, 1000, 1000, 10, 10))
	var n3 := t.note(snap.call(3, 990, 1000, 10, 10))
	var n4 := t.note(snap.call(4, 990, 1000, 10, 10))
	var n5 := t.note(snap.call(5, 990, 1000, 10, 10))
	var n6 := t.note(snap.call(6, 990, 1000, 10, 10))
	ev["quiet_then_damage"] = int((n2 as Dictionary).get("turns_without_progress", -1)) == 1 \
		and bool((n3 as Dictionary).get("progress", false)) \
		and int((n3 as Dictionary).get("turns_without_progress", -1)) == 0
	ev["stalemate_at_window"] = bool((n6 as Dictionary).get("stalemate", false)) \
		and not bool((n5 as Dictionary).get("stalemate", true))
	ev["damage_kind"] = str((((n3 as Dictionary).get("events", []) as Array)[0] as Dictionary).get("kind", ""))
	var t0 = TrackerCls.new()
	t0.configure(0, snap.call(1, 1000, 1000, 10, 10))
	var q := t0.note(snap.call(9, 1000, 1000, 10, 10))
	ev["disabled_never"] = not bool((q as Dictionary).get("stalemate", true))
	var ok := bool(ev["quiet_then_damage"]) and bool(ev["stalemate_at_window"]) \
		and str(ev["damage_kind"]) == "DAMAGE_DEALT" and bool(ev["disabled_never"])
	return [ok, ev]


func _fresh_check() -> Array:
	var ev := {}
	var bid := "SELFPLAY_FIXTURE_B8"
	var src = _setup_mgr(false)
	if src == null:
		return [false, {"error": "setup"}]
	var vp: Dictionary = src.vp_get_plan()
	var saved: Dictionary = MemoryCls.save_victory(bid, vp,
		src.vp_get_revisions(), src.vp_get_audit())
	ev["fixture_saved"] = bool(saved.get("ok", false))
	if not bool(saved.get("ok", false)):
		return [false, ev]
	var prev := OS.get_environment("SELFPLAY_FRESH_BRAIN")
	# Positive control: unset env adopts the stored plan at the live turn.
	OS.set_environment("SELFPLAY_FRESH_BRAIN", "")
	var mgr_a = ManagerCls.new()
	mgr_a.set("_battle_id", bid)
	mgr_a.call("_vp_load_memory", {"turn": 5}, 5)
	ev["production_adopts"] = bool(mgr_a.call("vp_has_plan"))
	# Gate: env=1 skips adoption on an identical manager.
	OS.set_environment("SELFPLAY_FRESH_BRAIN", "1")
	var mgr_b = ManagerCls.new()
	mgr_b.set("_battle_id", bid)
	mgr_b.call("_vp_load_memory", {"turn": 5}, 5)
	ev["fresh_skips"] = not bool(mgr_b.call("vp_has_plan"))
	OS.set_environment("SELFPLAY_FRESH_BRAIN", prev)
	# Best-effort fixture cleanup (namespaced; harmless if left behind).
	var dd := DirAccess.open("user://cloud_general/%s" % bid)
	if dd != null:
		for fn in ["victory_plan.json", "victory_plan_revisions.jsonl",
				"general_audit.jsonl"]:
			if dd.file_exists(fn):
				dd.remove(fn)
	var ok := bool(ev["fixture_saved"]) and bool(ev["production_adopts"]) \
		and bool(ev["fresh_skips"])
	return [ok, ev]


# ------------------------------------------------------------------
# autonomous match
# ------------------------------------------------------------------

func _env(key: String, fallback: String) -> String:
	var v := OS.get_environment(key).strip_edges()
	return v if not v.is_empty() else fallback


func _run_match() -> void:
	var t_start := Time.get_ticks_msec()
	OS.set_environment("JEV_SHADOW_ENABLE", "0")
	var out_dir := _env("SELFPLAY_OUT_DIR", "")
	if out_dir.is_empty():
		print("SELFPLAY_FAILED empty SELFPLAY_OUT_DIR")
		quit(2)
		return
	var budget_sec := 5400.0
	var braw := _env("SELFPLAY_MATCH_BUDGET_SEC", "")
	if not braw.is_empty():
		budget_sec = clampf(float(braw), 60.0, 21600.0)
	var ps: PackedScene = load("res://scenes/symloc_battle_test.tscn")
	if ps == null:
		print("SELFPLAY_FAILED symloc scene missing")
		quit(2)
		return
	var inst := ps.instantiate()
	root.add_child(inst)
	var mount: Node = inst.get_node_or_null("SymLocMount")
	var t0 := Time.get_ticks_msec()
	while mount == null or (not bool(mount.get("mount_ready")) and str(mount.get("mount_error")).is_empty()):
		if Time.get_ticks_msec() - t0 > 300000:
			break
		await process_frame
		if mount == null:
			mount = inst.get_node_or_null("SymLocMount")
	if mount == null or not bool(mount.get("mount_ready")):
		print("SELFPLAY_FAILED mount_error=%s" % (
			str(mount.get("mount_error")) if mount != null else "no-mount"))
		quit(2)
		return
	var mount_ready_unix := Time.get_unix_time_from_system()
	print("[Selfplay] mount ready in %.1fs turn=%d max_turns=%d no_progress=%d budget=%.0fs timeout=%ds" % [
		float(Time.get_ticks_msec() - t_start) / 1000.0,
		int(MatchLib.progress_snapshot(mount.get("shell")).get("turn", 0)),
		MatchLib.max_turns(), MatchLib.no_progress_window(), budget_sec,
		int(TurnCtrlCls.brain_timeout_sec())])
	var rec = RecorderCls.new()
	rec.name = "SelfplayRecorder"
	mount.add_child(rec)
	var started: Dictionary = rec.setup(mount, {"out_dir": out_dir,
		"mount_ready_unix": mount_ready_unix})
	if not bool(started.get("ok", false)):
		print("SELFPLAY_FAILED recorder=%s" % str(started.get("error", "?")))
		quit(2)
		return
	var tracker = TrackerCls.new()
	tracker.configure(MatchLib.no_progress_window(),
		MatchLib.progress_snapshot(mount.get("shell")))
	rec.poll()
	# Watchdog: recorder drain + turn-boundary progress + terminal controls.
	while true:
		await process_frame
		if Time.get_ticks_msec() - t_start > budget_sec * 1000.0:
			var snap_b := MatchLib.progress_snapshot(mount.get("shell"))
			var term_b := {"over": true, "winner": "DRAW",
				"reason": "MATCH_BUDGET_EXCEEDED", "turn": int(snap_b.get("turn", 0))}
			rec.finalize(term_b, {"status": "INTERRUPTED", "tracker": tracker.view()})
			print("SELFPLAY_FAILED match budget exceeded (INTERRUPTED)")
			quit(3)
			return
		rec.poll()
		var snap := MatchLib.progress_snapshot(mount.get("shell"))
		var noted := tracker.note(snap)
		if bool(noted.get("turn_advanced", false)):
			rec.note_turn_boundary({"turn": int(snap.get("turn", 0)),
				"progress": bool(noted.get("progress", false)),
				"events": noted.get("events", []),
				"turns_without_progress": int(noted.get("turns_without_progress", 0))})
		if bool(mount.get("match_over")):
			var mr: Dictionary = mount.get("match_result")
			var mreason := str(mr.get("reason", ""))
			if mreason.begins_with("TURN_CAP_"):
				mreason = MatchLib.REASON_TURN_LIMIT
			var term := {"over": true, "winner": str(mr.get("winner", "DRAW")),
				"reason": mreason, "turn": int(mr.get("turns", 0))}
			rec.finalize(term, {"status": "COMPLETE", "tracker": tracker.view()})
			print("SELFPLAY_DONE %s/match.json" % out_dir)
			quit(0)
			return
		var term2 := MatchLib.read_terminal(mount.get("shell"))
		if bool(term2.get("over", false)):
			mount.call("_finalize", term2)
			continue
		if bool(noted.get("stalemate", false)):
			var term3 := {"over": true, "winner": "DRAW",
				"reason": MatchLib.REASON_STALEMATE, "turn": int(snap.get("turn", 0))}
			mount.call("_finalize", term3)
			continue
		await create_timer(0.5).timeout
