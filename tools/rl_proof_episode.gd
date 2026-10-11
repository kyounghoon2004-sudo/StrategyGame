extends SceneTree

## RL_PIPELINE_PROOF_V0 — proof-only episode runner (NO production changes).
##
## Real Qwen candidate completion bytes -> REAL production INITIAL path
## (TurnController MISSION_HIERARCHY + mock adapter carrying the exact
## completion text, TRAINING_STRICT_CONTRACT=1) -> production
## parser/validator (Cloud2VictoryResponse/Authoring/Plan) -> strict fault
## latch or plan adoption -> StrictCls.poll_strict_terminal over the two
## REAL controllers -> SymLocMatch.outcomes_for_winner reward mapping.
## Valid plans resolve through a bounded deterministic Godot battle using
## production CombatCalculator.calculate_combat (-> HQ terminal or turn
## cap DRAW). Frozen BLUE opponent fixture goes through the same
## production parse/adopt path.
##
## Usage:
##   godot --headless --path <project> -s res://tools/rl_proof_episode.gd \
##     -- <in_json> <out_json>
##
## In JSON:
##   {rollout_id, side:"RED", seed:int, completion_text:str, kind:"INITIAL",
##    ctx:{turn:1, snapshot_id:str, roster:[...]}, max_turns:int}
## Out JSON: rollout record (validator, retries, fallbacks, terminal,
## winner, candidate outcome/reward, provenance).
##
## No network. No repair. No fallback. No second Brain call.

const SimControllerCls = preload("res://scripts/sim/sim_controller.gd")
const ObsCls = preload("res://scripts/cloud1/cloud1_observation.gd")
const AdapterCls = preload("res://scripts/cloud2/cloud2_adapter.gd")
const ConfigCls = preload("res://scripts/cloud2/cloud2_config.gd")
const TacticalPlanCls = preload("res://scripts/cloud2/cloud2_plan_memory.gd")
const TurnControllerCls = preload("res://scripts/cloud2/cloud2_turn_controller.gd")
const MatchCls = preload("res://scripts/symloc/symloc_match.gd")
const StrictCls = preload("res://scripts/selfplay/training_strict.gd")
const CombatCls = preload("res://scripts/combat/combat_calculator.gd")

const CANARY := "rl_proof_v0_fixture_canary_not_a_real_key"
const MAX_SETTLE_FRAMES := 1200


class ExecutorStub extends Node:
	signal execution_finished(result: Dictionary)
	var busy := false
	func set_external_busy(v: bool, _reason: String = "") -> void:
		busy = v


func _red_forces() -> Array:
	return [
		{"id": "R_ARC_1", "class": "archer", "faction": "red", "q": -29, "r": -6, "soldiers": 260},
		{"id": "R_ARC_2", "class": "archer", "faction": "red", "q": -29, "r": -5, "soldiers": 260},
		{"id": "R_CAV_1", "class": "cavalry", "faction": "red", "q": -29, "r": -4, "soldiers": 300},
		{"id": "R_CAV_2", "class": "cavalry", "faction": "red", "q": -29, "r": -3, "soldiers": 300},
		{"id": "R_HQ_1", "class": "hq", "faction": "red", "q": -29, "r": -2, "soldiers": 300},
		{"id": "R_INF_1", "class": "infantry", "faction": "red", "q": -29, "r": -1, "soldiers": 450},
		{"id": "R_INF_2", "class": "infantry", "faction": "red", "q": -29, "r": 0, "soldiers": 450},
		{"id": "R_SCT_1", "class": "scout", "faction": "red", "q": -29, "r": 1, "soldiers": 260},
		{"id": "R_SPE_1", "class": "spearman", "faction": "red", "q": -29, "r": 2, "soldiers": 400},
		{"id": "R_SPE_2", "class": "spearman", "faction": "red", "q": -29, "r": 3, "soldiers": 400},
	]


func _blue_forces() -> Array:
	var out: Array = []
	for u in _red_forces():
		var d: Dictionary = (u as Dictionary).duplicate(true)
		d["id"] = str(d["id"]).replace("R_", "B_")
		d["faction"] = "blue"
		d["q"] = int(d["q"]) - 2
		out.append(d)
	return out


func _blue_doc() -> Dictionary:
	var p1 := {"id": "P1", "name": "FIX CENTER", "purpose": "Pin the enemy center in place.",
		"intent": "Fix center; watch flanks.", "groups": {"CenterFix": ["B_INF_1", "B_INF_2"]},
		"missions": [{"task": "FIX", "area": "CENTER", "units": ["B_INF_1", "B_INF_2"],
			"vs": "INFANTRY", "preserve": true,
			"win": [{"when": "TURNS_ELAPSED", "turns": 3, "since": 1}], "stop": ["HQ_THREATENED"]}],
		"win": [{"when": "TURNS_ELAPSED", "turns": 3, "since": 1}],
		"lose": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.4}],
		"abort": ["HQ_THREATENED"], "next": "P2", "on_fail": "HOLD",
		"reserve": ["B_CAV_1"], "release": [{"when": "TURNS_ELAPSED", "turns": 3, "since": 1}],
		"exploit": "Pursue if center breaks."}
	var p2 := {"id": "P2", "name": "BREAKTHROUGH", "purpose": "Break the weakened line.",
		"intent": "Commit reserve; break through.", "groups": {"Reserve": ["B_CAV_1"]},
		"missions": [{"task": "ATTACK", "area": "CENTER", "units": ["B_CAV_1"], "vs": "INFANTRY"}],
		"win": [{"when": "TURNS_ELAPSED", "turns": 6, "since": 1}], "next": "END"}
	return {"objective": "Destroy the enemy HQ.", "end_state": "Enemy HQ destroyed.",
		"cadence": 4, "doctrine": [0.6, 0.5, 0.6, 0.6, 0.7, 0.2], "phases": [p1, p2]}


func _fresh_sim(label: String, forces: Array) -> RefCounted:
	var sim: RefCounted = SimControllerCls.new()
	sim.load_scenario({
		"scenario_id": "rlproof_%s" % label,
		"scenario_version": "1.0.0",
		"seed": 29,
		"mission_contract": {"primary_objective": "destroy_all_red", "turn_limit": 12},
		"map": {"bounds": {"q_min": -34, "q_max": -14, "r_min": -8, "r_max": 8},
			"default_terrain": 0, "terrain_overrides": {}, "river_cells": []},
		"forces": forces,
		"start_turn": 1,
	})
	return sim


func _make_controller(label: String, forces: Array, side: String, reply_text: String) -> Dictionary:
	var sim := _fresh_sim(label, forces)
	var adapter := AdapterCls.new()
	var executor := ExecutorStub.new()
	var controller := TurnControllerCls.new()
	get_root().add_child(adapter)
	get_root().add_child(executor)
	get_root().add_child(controller)
	var cfg := ConfigCls.new()
	cfg.provider_id = "openai"
	cfg.model = "mock-fixture"
	cfg.endpoint = "https://mock.local/v1/chat/completions"
	cfg.set_api_key(CANARY)
	cfg.mark_test_result(true, "CONNECTED", "rlproof fixture")
	adapter.mock_mode = true
	adapter.mock_queue.append({"ok": true, "latency_ms": 5, "content_text": reply_text})
	controller.setup(sim, executor, adapter, cfg, TacticalPlanCls.new())
	controller.set_side(side)
	controller.set_control_mode("MISSION_HIERARCHY")
	return {"sim": sim, "adapter": adapter, "executor": executor, "controller": controller, "cfg": cfg}


func _free_fixture(f: Dictionary) -> void:
	(f["controller"] as Node).queue_free()
	(f["executor"] as Node).queue_free()
	(f["adapter"] as Node).queue_free()
	await process_frame


func _settle_initial(f: Dictionary) -> Dictionary:
	var last := {}
	for i in range(MAX_SETTLE_FRAMES):
		last = f["controller"].victory_poll_initial()
		var st := str(last.get("status", ""))
		if st == "READY" or st == "FAILED":
			return last
		await process_frame
	return {"status": "TIMEOUT", "last": last}


func _attack_units(vp: Dictionary) -> Array:
	var out: Array = []
	for ph in (vp.get("phases", []) as Array):
		if not (ph is Dictionary):
			continue
		var st := str((ph as Dictionary).get("status", "ACTIVE")).to_upper()
		if st == "COMPLETED" or st == "FAILED":
			continue
		for m in ((ph as Dictionary).get("missions", []) as Array):
			if not (m is Dictionary):
				continue
			var md: Dictionary = m
			var t := str(md.get("task", md.get("mission_task", md.get("order", "")))).to_upper()
			if t == "ATTACK" or t == "FLANK":
				var ul: Array = md.get("assigned_units", md.get("units", md.get("unit_ids", md.get("assigned", []))))
				for u in ul:
					if not (str(u) in out):
						out.append(str(u))
	return out


func _resolve_battle(red_vp: Dictionary, blue_vp: Dictionary, seed: int, max_turns: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var units := {}
	for u in _red_forces():
		var d: Dictionary = (u as Dictionary).duplicate(true)
		units[str(d["id"])] = {"class": str(d["class"]), "side": "RED", "soldiers": int(d["soldiers"])}
	for u in _blue_forces():
		var d2: Dictionary = (u as Dictionary).duplicate(true)
		units[str(d2["id"])] = {"class": str(d2["class"]), "side": "BLUE", "soldiers": int(d2["soldiers"])}
	var init_field := 0
	for id in units.keys():
		if str((units[id] as Dictionary).get("side", "")) != "HQ":
			pass
		if not str(id).ends_with("_HQ_1"):
			init_field += int((units[id] as Dictionary).get("soldiers", 0))
	var red_atk := _attack_units(red_vp)
	var blue_atk := _attack_units(blue_vp)
	var log: Array = []
	var winner := ""
	var reason := ""
	var turns_run := 0
	for t in range(1, int(max_turns) + 1):
		turns_run = t
		for side in ["RED", "BLUE"]:
			var atk_list: Array = red_atk if side == "RED" else blue_atk
			var foe := "BLUE" if side == "RED" else "RED"
			var foes: Array = []
			var field_left := 0
			for id in units.keys():
				var ud: Dictionary = units[id]
				if str(ud.get("side", "")) != foe or int(ud.get("soldiers", 0)) <= 0:
					continue
				foes.append(str(id))
				if not str(id).ends_with("_HQ_1"):
					field_left += int(ud.get("soldiers", 0))
			foes.sort()
			if foes.is_empty():
				continue
			var hq_first := field_left < int(float(init_field) * 0.4)
			foes.sort_custom(func(a: String, b: String) -> bool:
				var ah := 0 if a.ends_with("_HQ_1") else 1
				var bh := 0 if b.ends_with("_HQ_1") else 1
				if hq_first:
					return ah > bh
				return ah < bh)
			var idx := 0
			for au in atk_list:
				if not units.has(au):
					continue
				var ad: Dictionary = units[au]
				if str(ad.get("side", "")) != side or int(ad.get("soldiers", 0)) <= 0:
					continue
				var tgt: String = foes[idx % foes.size()]
				var td: Dictionary = units[tgt]
				if int(td.get("soldiers", 0)) <= 0:
					var found := false
					for cand in foes:
						if int((units[cand] as Dictionary).get("soldiers", 0)) > 0:
							tgt = cand
							td = units[cand]
							found = true
							break
					if not found:
						continue
				var res: Dictionary = CombatCls.calculate_combat(
					{"class": str(ad.get("class", "infantry")),
						"soldier_count": int(ad.get("soldiers", 0)), "morale": 100.0},
					{"class": str(td.get("class", "infantry")),
						"soldier_count": int(td.get("soldiers", 0)), "morale": 100.0},
					1, 0, {}, 0.9 + rng.randf() * 0.2)
				td["soldiers"] = maxi(0, int(td.get("soldiers", 0)) - int(res.get("defender_casualties", 0)))
				ad["soldiers"] = maxi(0, int(ad.get("soldiers", 0)) - int(res.get("attacker_casualties", 0)))
				idx += 1
		var rhq := int((units["R_HQ_1"] as Dictionary).get("soldiers", 0))
		var bhq := int((units["B_HQ_1"] as Dictionary).get("soldiers", 0))
		log.append({"turn": t, "red_hq": rhq, "blue_hq": bhq})
		if rhq <= 0 and bhq <= 0:
			winner = "DRAW"
			reason = "MUTUAL_HQ_DESTROYED"
			break
		if bhq <= 0:
			winner = "RED"
			reason = "BLUE_HQ_DESTROYED"
			break
		if rhq <= 0:
			winner = "BLUE"
			reason = "RED_HQ_DESTROYED"
			break
	if winner.is_empty():
		winner = "DRAW"
		reason = "TURN_CAP_%d" % int(max_turns)
	var red_left := 0
	var blue_left := 0
	for id in units.keys():
		if str((units[id] as Dictionary).get("side", "")) == "RED":
			red_left += int((units[id] as Dictionary).get("soldiers", 0))
		else:
			blue_left += int((units[id] as Dictionary).get("soldiers", 0))
	return {"winner": winner, "reason": reason, "turns": turns_run,
		"red_attack_units": red_atk, "blue_attack_units": blue_atk,
		"red_soldiers_left": red_left, "blue_soldiers_left": blue_left, "hq_log": log}


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var prev := OS.get_environment("TRAINING_STRICT_CONTRACT")
	OS.set_environment("TRAINING_STRICT_CONTRACT", "1")
	var args := OS.get_cmdline_user_args()
	if args.size() < 2:
		printerr("[RLProof] need: -- <in_json> <out_json>")
		OS.set_environment("TRAINING_STRICT_CONTRACT", prev)
		quit(2)
		return
	var in_path := args[0]
	var out_path := args[1]
	var raw := FileAccess.get_file_as_string(in_path)
	var req: Variant = JSON.parse_string(raw)
	if not (req is Dictionary):
		printerr("[RLProof] bad input JSON")
		OS.set_environment("TRAINING_STRICT_CONTRACT", prev)
		quit(2)
		return
	var rec := await _episode(req)
	OS.set_environment("TRAINING_STRICT_CONTRACT", prev)
	var f := FileAccess.open(out_path, FileAccess.WRITE)
	if f == null:
		printerr("[RLProof] cannot write %s" % out_path)
		quit(2)
		return
	f.store_string(JSON.stringify(rec, "\t"))
	f.close()
	print("[RLProof] %s winner=%s reward=%s reason=%s" % [
		str(rec.get("rollout_id", "")), str(rec.get("winner", "")),
		str(rec.get("candidate_reward", "")), str(rec.get("terminal_reason", ""))])
	quit(0)


func _episode(req: Dictionary) -> Dictionary:
	var rid := str(req.get("rollout_id", "r0"))
	var seed := int(req.get("seed", 1))
	var text := str(req.get("completion_text", ""))
	var max_turns := int(req.get("max_turns", 6))
	var side := str(req.get("side", "RED")).to_upper()
	if side != "BLUE":
		side = "RED"
	var rec := {"rollout_id": rid, "side": side, "seed": seed,
		"strict_enabled": true, "completion_chars": text.length(),
		"completion_sha256": text.sha256_text(),
		"general_calls": 0, "retries": -1, "fallback_calls": 0,
		"fallback_plan_adopted": false, "provider_calls": 0}
	var red_text := text if side == "RED" else JSON.stringify(_blue_doc())
	var blue_text := JSON.stringify(_blue_doc()) if side == "RED" else text
	var fr := _make_controller("rlr_%s" % rid, _red_forces(), "red", red_text)
	var fb := _make_controller("rlb_%s" % rid, _blue_forces(), "blue", blue_text)
	var obs_r: Dictionary = ObsCls.build(fr["sim"], "red")
	var fired_r: Dictionary = fr["controller"]._vp_init_fire(obs_r,
		{"trigger": "INITIAL_PLAN", "reason": "RL proof rollout.", "turn": 1}, 1)
	var obs_b: Dictionary = ObsCls.build(fb["sim"], "blue")
	var fired_b: Dictionary = fb["controller"]._vp_init_fire(obs_b,
		{"trigger": "INITIAL_PLAN", "reason": "RL proof opponent.", "turn": 1}, 1)
	rec["fire_ok_red"] = bool(fired_r.get("ok", false))
	rec["fire_ok_blue"] = bool(fired_b.get("ok", false))
	var done_r := await _settle_initial(fr)
	var done_b := await _settle_initial(fb)
	rec["status_red"] = str(done_r.get("status", ""))
	rec["status_blue"] = str(done_b.get("status", ""))
	var st_r: Dictionary = fr["controller"].victory_initial_status()
	var st_b: Dictionary = fb["controller"].victory_initial_status()
	var hist_r: Array = fr["controller"].get_general_history()
	var hist_b: Array = fb["controller"].get_general_history()
	var cand_hist: Array = hist_r if side == "RED" else hist_b
	var cand_st: Dictionary = st_r if side == "RED" else st_b
	rec["general_calls"] = cand_hist.size()
	rec["retries"] = int(cand_st.get("retries", -1))
	rec["queue_left"] = (fr["adapter"].mock_queue as Array).size() + (fb["adapter"].mock_queue as Array).size()
	rec["validator_code"] = ""
	rec["validator_detail"] = ""
	if cand_hist.size() > 0:
		var last_h: Dictionary = cand_hist[cand_hist.size() - 1]
		rec["validator_code"] = str(last_h.get("code", ""))
		rec["validator_detail"] = str(last_h.get("detail", "")).left(220)
	var fault_r: Dictionary = fr["controller"].strict_fault()
	var fault_b: Dictionary = fb["controller"].strict_fault()
	rec["fault_red"] = fault_r.get("code", "")
	rec["fault_blue"] = fault_b.get("code", "")
	# Production adoption step: consume the READY prefetched plan into the
	# manager (zero new General calls). Consume-rejects latch strict too.
	rec["consume_red"] = {}
	rec["consume_blue"] = {}
	if str(done_r.get("status", "")) == "READY":
		rec["consume_red"] = fr["controller"].victory_consume_initial(obs_r, 1)
	if str(done_b.get("status", "")) == "READY":
		rec["consume_blue"] = fb["controller"].victory_consume_initial(obs_b, 1)
	fault_r = fr["controller"].strict_fault()
	fault_b = fb["controller"].strict_fault()
	rec["fault_red"] = fault_r.get("code", "")
	rec["fault_blue"] = fault_b.get("code", "")
	var sterm: Dictionary = StrictCls.poll_strict_terminal(fr["controller"], fb["controller"])
	if not sterm.is_empty():
		var term_w := str(sterm.get("winner", "DRAW"))
		var term_r := str(sterm.get("reason", ""))
		var off := str(sterm.get("offender_side", ""))
		var oc: Dictionary = MatchCls.outcomes_for_winner(term_w)
		var cand_outcome := str(oc.get("outcome_red", "DRAW")) if side == "RED" else str(oc.get("outcome_blue", "DRAW"))
		var cand_reward := int(oc.get("reward_red", -2)) if side == "RED" else int(oc.get("reward_blue", -2))
		rec["path"] = "STRICT_TERMINAL"
		rec["terminal_reason"] = term_r
		rec["winner"] = term_w
		rec["offender_side"] = off
		rec["candidate_outcome"] = cand_outcome
		rec["candidate_reward"] = cand_reward
		rec["opponent_reward"] = int(oc.get("reward_blue", -2)) if side == "RED" else int(oc.get("reward_red", -2))
		rec["fault_is_brain_code"] = StrictCls.is_brain_contract_code(str(fault_r.get("code", "")) if side == "RED" else str(fault_b.get("code", "")))
		var off_fault: Dictionary = fault_r if str(sterm.get("offender_side", "")) == "RED" else fault_b
		rec["validator_code"] = str(off_fault.get("code", ""))
		rec["validator_detail"] = str(off_fault.get("detail", "")).left(220)
		rec["plan_adopted"] = false
		await _free_fixture(fr)
		await _free_fixture(fb)
		return rec
	# No strict fault: both plans adopted through production. Resolve.
	var mgr_r = fr["controller"].get("_manager")
	var mgr_b = fb["controller"].get("_manager")
	var vp_r: Dictionary = mgr_r.vp_get_plan()
	var vp_b: Dictionary = mgr_b.vp_get_plan()
	rec["plan_adopted"] = bool(mgr_r.vp_has_plan()) if side == "RED" else bool(mgr_b.vp_has_plan())
	rec["vp_keys"] = vp_r.keys() if side == "RED" else vp_b.keys()
	rec["plan_revision"] = int(vp_r.get("revision", 0)) if side == "RED" else int(vp_b.get("revision", 0))
	rec["phase_count"] = (vp_r.get("phases", []) as Array).size() if side == "RED" else (vp_b.get("phases", []) as Array).size()
	var red_vp: Dictionary = vp_r
	var blue_vp: Dictionary = vp_b
	var cand_vp: Dictionary = red_vp if side == "RED" else blue_vp
	var task_audit: Array = []
	for ph in (cand_vp.get("phases", []) as Array):
		if ph is Dictionary:
			for m in ((ph as Dictionary).get("missions", []) as Array):
				if m is Dictionary:
					task_audit.append({"task": str((m as Dictionary).get("task", "")),
						"units": (m as Dictionary).get("assigned_units", (m as Dictionary).get("units", []))})
	rec["mission_tasks"] = task_audit
	rec["phases_dump"] = (cand_vp.get("phases", []) as Array).duplicate(true)
	var res := _resolve_battle(red_vp, blue_vp, 1000 + seed, max_turns)
	var oc2: Dictionary = MatchCls.outcomes_for_winner(str(res.get("winner", "DRAW")))
	rec["path"] = "GODOT_RESOLUTION"
	rec["terminal_reason"] = str(res.get("reason", ""))
	rec["winner"] = str(res.get("winner", "DRAW"))
	rec["battle_turns"] = int(res.get("turns", 0))
	rec["red_attack_units"] = res.get("red_attack_units", [])
	rec["blue_attack_units"] = res.get("blue_attack_units", [])
	rec["red_soldiers_left"] = int(res.get("red_soldiers_left", 0))
	rec["blue_soldiers_left"] = int(res.get("blue_soldiers_left", 0))
	rec["hq_log"] = res.get("hq_log", [])
	rec["candidate_outcome"] = str(oc2.get("outcome_red", "DRAW")) if side == "RED" else str(oc2.get("outcome_blue", "DRAW"))
	rec["candidate_reward"] = int(oc2.get("reward_red", -2)) if side == "RED" else int(oc2.get("reward_blue", -2))
	rec["opponent_reward"] = int(oc2.get("reward_blue", -2)) if side == "RED" else int(oc2.get("reward_red", -2))
	rec["fault_is_brain_code"] = true
	await _free_fixture(fr)
	await _free_fixture(fb)
	return rec
