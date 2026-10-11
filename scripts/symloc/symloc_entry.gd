extends SceneTree

## SYMMETRIC LOCAL-vs-LOCAL SANDBOX V1 — headless verification harness.
##
## Usage (from a terminal):
##   godot --headless --path <project> --script res://scripts/symloc/symloc_entry.gd \
##     -- --run-dir=res://artifacts/symmetric_local_sandbox_v1/raw --gates=static,menu,hvc,symloc_boot
##
## Gates:
##   static ..... no scene, no models: reward contract, packet/prompt
##                symmetry, manager/controller side binding, trace, brain
##                config, enumerator, blackboard, VP lifecycle (BLUE).
##   menu ....... title screen exposes EXACTLY the two DEV battle entries.
##   hvc ........ Human-vs-Cloud scene boots; Cloud2Mount binds; RED routes
##                to CLOUD+LAYA; zero paid API calls (no backend configured).
##   symloc_boot  symmetric scene boots with LAYA_ENABLE=0 + no Brain:
##                both side controllers bind (same class/interface), loop
##                runs full turns via designed fallbacks, fog rows prove
##                no leak. Live-model loop proof is a separate attended run.
##
## NO TRAINING: this harness asserts control-plane facts only. It never
## touches weights, LoRA adapters, or RL entrypoints.

const MatchCls = preload("res://scripts/symloc/symloc_match.gd")
const BrainCls = preload("res://scripts/symloc/symloc_brain.gd")
const PacketCls = preload("res://scripts/cloud2/cloud2_general_packet.gd")
const VictoryRespCls = preload("res://scripts/cloud2/cloud2_victory_response.gd")
const ManagerCls = preload("res://scripts/cloud2/cloud2_mission_manager.gd")
const TurnCtrlCls = preload("res://scripts/cloud2/cloud2_turn_controller.gd")
const LayaCtrlCls = preload("res://scripts/laya/laya_controller.gd")
const RespCls = preload("res://scripts/cloud2/cloud2_response.gd")
const TableCls = preload("res://scripts/cloud1/cloud1_action_table.gd")
const TraceCls = preload("res://scripts/cloud2/cloud2_general_trace.gd")
const EnumCls = preload("res://scripts/laya/laya_enumerator.gd")
const BBCls = preload("res://scripts/laya/laya_blackboard.gd")
const CoordCls = preload("res://scripts/laya/laya_coordinator.gd")
const VPCtxCls = preload("res://scripts/cloud2/cloud2_victory_plan.gd")
const SessionCls = preload("res://scripts/cloud2/cloud2_session.gd")

var _gates := {}
var _evidence := {}
var _run_dir := ""
var _wanted := ["static", "menu", "hvc", "symloc_boot"]


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
	print("[SYMLOC][%s] %s %s" % [gate, "PASS" if ok else "FAIL", JSON.stringify(evidence)])


func _run_async() -> void:
	await process_frame
	if "static" in _wanted:
		_test_static()
	if "menu" in _wanted:
		await _test_menu()
	if "hvc" in _wanted:
		await _test_hvc()
	if "symloc_boot" in _wanted:
		await _test_symloc_boot()
	_write_and_quit()


func _write_and_quit() -> void:
	var fails := 0
	for g in _gates.keys():
		if not bool(_gates[g]):
			fails += 1
	if not _run_dir.is_empty():
		var d := DirAccess.open("res://")
		if d != null:
			d.make_dir_recursive(_run_dir)
		var f := FileAccess.open(_run_dir + "/gates_static.json", FileAccess.WRITE)
		if f != null:
			f.store_string(JSON.stringify({"gates": _gates, "evidence": _evidence}, "  "))
			f.close()
			print("[SYMLOC] evidence -> %s/gates_static.json" % _run_dir)
	print("[SYMLOC] GATES exit=%d" % fails)
	quit(fails)


# ------------------------------------------------------------------
# static: no scene, no models
# ------------------------------------------------------------------

func _test_static() -> void:
	# G1: terminal reward contract (+5/-3/-2), all three outcomes.
	var r := MatchCls.outcomes_for_winner("RED")
	var b := MatchCls.outcomes_for_winner("BLUE")
	var dr := MatchCls.outcomes_for_winner("DRAW")
	var g1 := int(r.get("reward_red", 0)) == 5 and int(r.get("reward_blue", 0)) == -3 \
		and int(b.get("reward_red", 0)) == -3 and int(b.get("reward_blue", 0)) == 5 \
		and int(dr.get("reward_red", 0)) == -2 and int(dr.get("reward_blue", 0)) == -2 \
		and str(r.get("outcome_red", "")) == "WIN" and str(b.get("outcome_blue", "")) == "WIN"
	_record("G1_reward_contract", g1, {"red": r, "blue": b, "draw": dr})
	var full := MatchCls.build_result("RED", "BLUE_HQ_DESTROYED", 7,
		{"scenario": "s", "red_brain": "m", "blue_brain": "m"})
	var g1b := int(full.get("turns", 0)) == 7 and str(full.get("training", "")) == "NONE" \
		and str(full.get("red_hands", "")) == "LAYA_LIVE" and str(full.get("blue_hands", "")) == "LAYA_LIVE"
	_record("G1b_match_result_shape", g1b, {"keys": full.keys()})

	# G2: VictoryPlan packet symmetry (same keys, mirrored side tags).
	var obs := _fixture_obs()
	var pr: Dictionary = PacketCls.build_victory_initial(obs, "red")
	var pb: Dictionary = PacketCls.build_victory_initial(obs, "blue")
	var kr: Array = pr.keys()
	var kb: Array = pb.keys()
	kr.sort()
	kb.sort()
	var fr: Dictionary = (pr.get("compact_state", {}) as Dictionary).get("force_summary", {})
	var fb: Dictionary = (pb.get("compact_state", {}) as Dictionary).get("force_summary", {})
	var g2 := str(pr.get("acting_side", "")) == "RED" and str(pb.get("acting_side", "")) == "BLUE" \
		and kr == kb and fr.has("red_formations") and fb.has("blue_formations") \
		and not fb.has("red_formations")
	_record("G2_packet_symmetry", g2, {"sides": [pr.get("acting_side"), pb.get("acting_side")],
		"red_keys": fr.keys(), "blue_keys": fb.keys()})
	var gr: Dictionary = PacketCls.build(obs, {}, [], {})
	var gb: Dictionary = PacketCls.build(obs, {}, [], {}, "blue")
	var vr: Dictionary = PacketCls.validate_shape(gr)
	var vb: Dictionary = PacketCls.validate_shape(gb)
	var bad := gr.duplicate(true)
	bad["acting_side"] = "GREEN"
	var vbad: Dictionary = PacketCls.validate_shape(bad)
	_record("G2b_packet_validate", bool(vr.get("ok", false)) and bool(vb.get("ok", false)) and not bool(vbad.get("ok", false)),
		{"red": vr.get("ok"), "blue": vb.get("ok"), "green_rejected": not bool(vbad.get("ok", false))})

	# G3: prompt mirrors (same contract, side-relative framing).
	var gp_r := PacketCls.general_prompt_for("red")
	var gp_b := PacketCls.general_prompt_for("blue")
	var vi_r := VictoryRespCls.initial_prompt_for("red")
	var vi_b := VictoryRespCls.initial_prompt_for("blue")
	var vr_r := VictoryRespCls.review_prompt_for("red")
	var vr_b := VictoryRespCls.review_prompt_for("blue")
	var g3 := gp_r == PacketCls.GENERAL_SYSTEM_PROMPT and gp_b == PacketCls.GENERAL_SYSTEM_PROMPT_BLUE \
		and gp_b.contains("BLUE") and not gp_b.contains("RED operational") \
		and vi_r == VictoryRespCls.VICTORY_INITIAL_PROMPT \
		and vi_b.contains("BLUE general") and vi_b.contains("B_INF_1") \
		and vr_b.contains("BLUE general")
	_record("G3_prompt_mirrors", g3, {"general_blue_chars": gp_b.length(),
		"initial_blue_chars": vi_b.length(), "review_blue_chars": vr_b.length()})

	# G4: manager side binding + memory namespacing.
	var mgr = ManagerCls.new()
	var g4a := str(mgr.get_side()) == "red"
	mgr.set_side("blue")
	mgr.set("_battle_id", "B1")
	var mem_blue: String = mgr.call("_mem_id")
	mgr.set_side("red")
	var mem_red: String = mgr.call("_mem_id")
	var g4 := g4a and str(mgr.get_side()) == "red" and mem_red == "B1" and mem_blue == "B1__blue"
	_record("G4_manager_side", g4, {"default_red": g4a, "mem_red": mem_red, "mem_blue": mem_blue})

	# G5: response gate accepts both acting sides (HOLD orders).
	var hold_r: Dictionary = TableCls.make_command("HOLD", TableCls.scope_units(["R_INF_1"]))
	var hold_b: Dictionary = TableCls.make_command("HOLD", TableCls.scope_units(["B_INF_1"]))
	var chk_r: Dictionary = RespCls.check_order(hold_r, {"acting_side": "RED"})
	var chk_b: Dictionary = RespCls.check_order(hold_b, {"acting_side": "BLUE"})
	_record("G5_response_gate_both_sides", bool(chk_r.get("ok", false)) and bool(chk_b.get("ok", false)),
		{"red": chk_r.get("code", ""), "blue": chk_b.get("code", "")})

	# G6: shared trace counts both sides.
	TraceCls.reset()
	TraceCls.note_side_turn("red", true, 2)
	TraceCls.note_side_turn("blue", false, 1)
	var snap: Dictionary = TraceCls.snapshot()
	var g6 := int(snap.get("red_turns", -1)) == 1 and int(snap.get("blue_turns", -1)) == 1 \
		and int(snap.get("turns_with_llm", 0)) == 1 and int(snap.get("turns_without_llm", 0)) == 1
	_record("G6_trace_sides", g6, {"red_turns": snap.get("red_turns"), "blue_turns": snap.get("blue_turns")})

	# G7: local Brain config builder (same model both sides by default).
	var cfg_r: RefCounted = BrainCls.build_config("red")
	var cfg_b: RefCounted = BrainCls.build_config("blue")
	var ep_r: String = cfg_r.get("endpoint")
	var ep_b: String = cfg_b.get("endpoint")
	var g7 := str(cfg_r.get("provider_id")) == str(cfg_b.get("provider_id")) \
		and str(cfg_r.get("model")) == str(cfg_b.get("model")) and ep_r == ep_b \
		and ep_r.ends_with("/v1/chat/completions") \
		and not str(cfg_r.get("model")).is_empty()
	_record("G7_brain_builder", g7,
		{"provider": str(cfg_r.get("provider_id")), "model": str(cfg_r.get("model")),
			"endpoint": ep_r, "label": BrainCls.backend_label(cfg_r)})

	# G8: blackboard staleness is side-symmetric.
	var bb_r = BBCls.create({"mission_id": "M1"}, ["R_INF_1"])
	bb_r.set_group_plan({"candidate_id": "p", "text": "t", "assignments": {}})
	bb_r.note_commitment("R_INF_1", {"action_type": "ATTACK", "target_id": "B_INF_9"},
		"R_INF_1 attacks B_INF_9", 1)
	bb_r.invalidate_stale(["R_INF_1"], [], "red")
	var bb_b = BBCls.create({"mission_id": "M1"}, ["B_INF_1"])
	bb_b.set_group_plan({"candidate_id": "p", "text": "t", "assignments": {}})
	bb_b.note_commitment("B_INF_1", {"action_type": "ATTACK", "target_id": "R_INF_9"},
		"B_INF_1 attacks R_INF_9", 1)
	bb_b.invalidate_stale([], ["B_INF_1"], "blue")
	var inv_r: Array = bb_r.get("invalidated")
	var inv_b: Array = bb_b.get("invalidated")
	_record("G8_blackboard_symmetric", inv_r.size() == 1 and inv_b.size() == 1,
		{"red_invalidated": inv_r, "blue_invalidated": inv_b})

	# G9: coordinator is deterministic + side-agnostic (same input, same
	# group candidates; BLUE units flow through the identical code path).
	var pools := {
		"B_CAV_1": [{"candidate_id": "a1", "unit_id": "B_CAV_1", "action_type": "ATTACK",
				"target_id": "R_ARC_1", "target_class": "ARCHER"},
			{"candidate_id": "w1", "unit_id": "B_CAV_1", "action_type": "WAIT"}],
		"B_CAV_2": [{"candidate_id": "a2", "unit_id": "B_CAV_2", "action_type": "ATTACK",
				"target_id": "R_ARC_2", "target_class": "ARCHER"},
			{"candidate_id": "m2", "unit_id": "B_CAV_2", "action_type": "MOVE",
				"destination": [3, 4]}]}
	var gen_a: Array = CoordCls.generate("M02", ["B_CAV_1", "B_CAV_2"], pools, Callable())
	var gen_b: Array = CoordCls.generate("M02", ["B_CAV_2", "B_CAV_1"], pools, Callable())
	_record("G9_coordinator_deterministic", JSON.stringify(gen_a) == JSON.stringify(gen_b) and not gen_a.is_empty(),
		{"candidates": gen_a.size(), "first_id": str((gen_a[0] as Dictionary).get("candidate_id", "?")) if not gen_a.is_empty() else "none"})

	# G10: VictoryPlan lifecycle on a BLUE manager (INITIAL/KEEP/ADVANCE/
	# AMEND/EMERGENCY) — mirrors the Liberation lifecycle test, BLUE roster.
	var vp_ev := _vp_lifecycle_blue()
	var g10 := bool(vp_ev.get("initial_ok", false)) and bool(vp_ev.get("applied_ok", false)) \
		and bool(vp_ev.get("keep_ok", false)) and bool(vp_ev.get("advance_ok", false)) \
		and bool(vp_ev.get("mem_namespaced", false))
	_record("G10_vp_lifecycle_blue", g10, vp_ev)

	# G11: enumerator side binding defaults.
	var en = EnumCls.new()
	var g11a := str(en.get_side()) == "red"
	en.set_side("blue")
	var g11b := str(en.get_side()) == "blue"
	en.set_side("green")
	var g11c := str(en.get_side()) == "red"
	_record("G11_enumerator_side", g11a and g11b and g11c,
		{"default": "red", "blue_ok": g11b, "coerce_ok": g11c})


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


func _vp_lifecycle_blue() -> Dictionary:
	var roster := ["B_CAV_1", "B_CAV_2"]
	var mgr = ManagerCls.new()
	mgr.set_side("blue")
	var doc := {"objective": "Destroy R_HQ_1.", "end_state": "BLUE wins.", "cadence": 4,
		"doctrine": [0.5, 0.5, 0.5, 0.5, 0.5, 0.5],
		"phases": [
			{"id": "P1", "name": "OPENING", "purpose": "Dislocate support.",
				"missions": [{"units": ["B_CAV_1", "B_CAV_2"],
					"intent": "Pressure the ranged line; preserve mobility.",
					"roles": {"B_CAV_1": "Press.", "B_CAV_2": "Exploit."},
					"win": [{"trigger": "TURNS_ELAPSED", "params": {"turns": 2, "since": 1}}]}],
				"transition": {"on_success": {"action": "ADVANCE", "next_phase_id": "P2"}}},
			{"id": "P2", "name": "CLOSING", "purpose": "Finish.",
				"missions": [{"units": ["B_CAV_1"], "task": "ATTACK", "area": "ANY"}]}]}
	var parsed: Dictionary = VictoryRespCls.parse_initial(JSON.stringify(doc),
		{"turn": 1, "snapshot_id": "SYM_T1", "roster": roster})
	var applied: Dictionary = mgr.vp_apply_initial(parsed.get("plan", {}), 1, "SYM_T1",
		"SYM_BATTLE", "symloc/static") if bool(parsed.get("ok", false)) else {"ok": false}
	var keep_p: Dictionary = VictoryRespCls.parse_review(
		JSON.stringify({"decision": "KEEP", "reason": "On track."}), {"turn": 2, "snapshot_id": "SYM_T2"})
	var keep_c: Dictionary = mgr.vp_compute_review(keep_p.get("review", {}), {"turn": 2}, 2)
	var keep_x: Dictionary = mgr.vp_commit_review(keep_c, {"type": "BATTLE"}, 2, "SYM_T2", "REVIEW_CADENCE")
	var adv_p: Dictionary = VictoryRespCls.parse_review(
		JSON.stringify({"decision": "ADVANCE_PHASE", "reason": "P1 done."}), {"turn": 5, "snapshot_id": "SYM_T5"})
	var adv_c: Dictionary = mgr.vp_compute_review(adv_p.get("review", {}), {"turn": 5}, 5)
	var adv_x: Dictionary = mgr.vp_commit_review(adv_c, {"type": "BATTLE"}, 5, "SYM_T5", "REVIEW_CADENCE")
	return {"initial_ok": bool(parsed.get("ok", false)), "applied_ok": bool(applied.get("ok", false)),
		"keep_ok": bool(keep_x.get("ok", false)), "advance_ok": bool(adv_x.get("ok", false)),
		"phase": str(applied.get("phase", "")),
		"side": str(mgr.get_side()), "mem_namespaced": str(mgr.call("_mem_id")) == "SYM_BATTLE__blue"}


# ------------------------------------------------------------------
# menu: exactly two DEV battle entries
# ------------------------------------------------------------------

func _test_menu() -> void:
	var ps: PackedScene = load("res://scenes/title_screen.tscn")
	if ps == null:
		_record("G12_menu_two_entries", false, {"error": "title scene missing"})
		return
	var title := ps.instantiate()
	root.add_child(title)
	for _i in range(30):
		await process_frame
	var found: Array = []
	var stack: Array = [title]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is Button and str((n as Button).text).begins_with("DEV:"):
			found.append(str((n as Button).text))
		for c in n.get_children():
			stack.append(c)
	found.sort()
	var want := ["DEV: Human vs Cloud General", "DEV: Local vs Local"]
	_record("G12_menu_two_entries", found == want, {"found": found, "want": want})
	title.queue_free()
	for _i in range(10):
		await process_frame


# ------------------------------------------------------------------
# hvc: Human-vs-Cloud regression (no paid API calls)
# ------------------------------------------------------------------

func _test_hvc() -> void:
	OS.set_environment("JEV_SHADOW_ENABLE", "0")
	var ps: PackedScene = load("res://scenes/cloud2_battle_test.tscn")
	if ps == null:
		_record("G13_hvc_boot", false, {"error": "cloud2 scene missing"})
		return
	var inst := ps.instantiate()
	root.add_child(inst)
	var mount: Node = inst.get_node_or_null("Cloud2LiveMount")
	var ok := false
	var mode := "?"
	var detail := {}
	for _i in range(1800):
		await process_frame
		if mount != null and bool(mount.get("mount_ready")):
			ok = true
			break
		if mount != null and not str(mount.get("mount_error")).is_empty():
			break
	if mount != null:
		mode = str(mount.call("red_controller_mode")) if mount.has_method("red_controller_mode") else "?"
		var ctl: Node = mount.get("cloud_controller")
		detail = {"mount_ready": bool(mount.get("mount_ready")),
			"mount_error": str(mount.get("mount_error")),
			"red_mode": mode,
			"controller_class": str(ctl.get_class()) if ctl != null else "null",
			"has_laya_stats": bool(ctl != null and ctl.has_method("laya_stats")),
			"side": str(ctl.call("get_side")) if ctl != null and ctl.has_method("get_side") else "?"}
	# Zero paid API calls: no key may be present (memory-only keys are
	# never persisted) and EITHER the session gate refuses transport
	# (provider label alone cannot send) OR the provider is local-only.
	var paid_safe := false
	if mount != null:
		var cfg: RefCounted = mount.get("cloud_config")
		if cfg != null:
			var prov := str(cfg.get("provider_id"))
			var ep := str(cfg.get("endpoint"))
			var local_only := prov.is_empty() or prov == "ollama" \
				or (prov == "custom" and (ep.contains("127.0.0.1") or ep.contains("localhost") or ep.is_empty()))
			var gate: Dictionary = SessionCls.resolve_for_use(cfg)
			var gate_closed := not bool(gate.get("ok", false))
			paid_safe = (not bool(cfg.call("has_key"))) and (gate_closed or local_only)
			detail["provider"] = prov
			detail["has_key"] = bool(cfg.call("has_key"))
			detail["gate_ok"] = bool(gate.get("ok", false))
			detail["gate_code"] = str(gate.get("code", ""))
	_record("G13_hvc_boot", ok and mode == "CLOUD+LAYA" and paid_safe, detail)
	inst.queue_free()
	for _i in range(30):
		await process_frame


# ------------------------------------------------------------------
# symloc_boot: symmetric boot + autonomous turns via fallbacks
# ------------------------------------------------------------------

func _test_symloc_boot() -> void:
	OS.set_environment("JEV_SHADOW_ENABLE", "0")
	OS.set_environment("LAYA_ENABLE", "0") # designed-fallback path; live Laya proven separately
	# Dead Brain endpoint: this gate proves the autonomous fallback loop
	# deterministically and fast (live Brains are proven by the attended
	# live run instead, where serialized INITIAL generations take minutes).
	OS.set_environment("SYMLOC_BRAIN_ENDPOINT", "http://127.0.0.1:9")
	var ps: PackedScene = load("res://scenes/symloc_battle_test.tscn")
	if ps == null:
		_record("G14_symloc_boot", false, {"error": "symloc scene missing"})
		return
	var inst := ps.instantiate()
	root.add_child(inst)
	var mount: Node = inst.get_node_or_null("SymLocMount")
	var detail := {}
	for _i in range(1800):
		await process_frame
		if mount != null and (bool(mount.get("mount_ready")) or not str(mount.get("mount_error")).is_empty()):
			break
	if mount == null or not bool(mount.get("mount_ready")):
		detail = {"mount_ready": false,
			"mount_error": str(mount.get("mount_error")) if mount != null else "no-mount"}
		_record("G14_symloc_boot", false, detail)
		inst.queue_free()
		return
	var rc: Node = mount.get("red_controller")
	var bc: Node = mount.get("blue_controller")
	detail["sides"] = [str(rc.call("get_side")), str(bc.call("get_side"))]
	detail["same_class"] = rc.get_class() == bc.get_class()
	detail["red_mode"] = str(mount.get("shell").call("red_controller_mode"))
	# Wait for the autonomous loop to complete at least one full turn
	# (turn 1 -> 2) with zero human input.
	var shell: Node = mount.get("shell")
	var t0 := Time.get_ticks_msec()
	var turn_seen := 1
	while Time.get_ticks_msec() - t0 < 240000:
		await process_frame
		if shell == null or not is_instance_valid(shell):
			break
		turn_seen = int((shell.get("unit_manager") as RefCounted).call("get_current_turn"))
		if turn_seen >= 2:
			break
	detail["turn_reached"] = turn_seen
	var rs: Dictionary = rc.call("laya_stats")
	var bs: Dictionary = bc.call("laya_stats")
	detail["red_side_turns"] = int(rs.get("side_turns", 0))
	detail["blue_side_turns"] = int(bs.get("side_turns", 0))
	var fog: Array = mount.get("fog_rows")
	var leak := false
	for row in fog:
		var rrow: Dictionary = (row as Dictionary).get("red", {})
		var brow: Dictionary = (row as Dictionary).get("blue", {})
		if bool(rrow.get("leak", false)) or bool(brow.get("leak", false)):
			leak = true
	detail["fog_rows"] = fog.size()
	detail["fog_leak"] = leak
	detail["fog_last"] = fog[fog.size() - 1] if not fog.is_empty() else {}
	detail["enemy_routine_runs"] = int(shell.get("_enemy_routine_runs"))
	var ok14 := turn_seen >= 2 and int(rs.get("side_turns", 0)) >= 1 \
		and int(bs.get("side_turns", 0)) >= 1 and not leak \
		and int(shell.get("_enemy_routine_runs")) == 0
	_record("G14_symloc_boot", ok14, detail)
	inst.queue_free()
	for _i in range(30):
		await process_frame
