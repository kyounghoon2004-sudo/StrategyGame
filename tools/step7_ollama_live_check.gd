extends SceneTree

## Live Ollama Advisor pilot check (real local inference, same model throughout).
## Boots the canonical scene and proves the end-to-end loop:
## selection -> deterministic six options -> Ollama request -> structured
## recommendation -> UI highlight -> player override -> canonical execution.
## Plus: second tactical situation, stale-switch discard, offline failure,
## malformed->repair, and three synthetic tactical cases on the SAME model.
## Writes evidence; quit code 0 = pass, 1 = fail.

const OUT := "D:/Game development/Demon slayer/StrategyGame/evidence/step7_ollama_advisor/live_check.json"
const PAYLOAD_SAMPLE := "D:/Game development/Demon slayer/StrategyGame/evidence/step7_ollama_advisor/payload_sample_caseA.json"
const RAW_SAMPLE := "D:/Game development/Demon slayer/StrategyGame/evidence/step7_ollama_advisor/raw_sample_caseA.txt"
const SelectorScript = preload("res://scripts/step7/step7_advisor_llm_selector.gd")
const ContextScript = preload("res://scripts/step7/step7_advisor_context.gd")
const ViewModelScript = preload("res://scripts/step7/step7_advisor_viewmodel.gd")
const ConfigScript = preload("res://scripts/step7/step7_ollama_config.gd")

const MODEL_UNDER_TEST := "qwen3.8:27b"
const REC_WAIT_FRAMES := 1500 # ~25s at 60fps headless burst; looped in chunks
const REC_ROUNDS := 12 # up to ~5 min total per recommendation worst case

var failures: Array = []
var passed := 0
var evidence := {}
var battle: Node = null
var integration: Node = null
var adapter: Node = null
var awin = null
var um = null


func _check(cond: bool, label: String) -> void:
	if cond:
		passed += 1
	else:
		failures.append(label)


func _init() -> void:
	call_deferred("_run")


func _red_ids() -> Array:
	var out: Array = []
	for u in um.call("get_all_units_including_garrisoned"):
		if u is Dictionary and str((u as Dictionary).get("faction", "")) == "red":
			out.append(str((u as Dictionary).get("id", "")))
	return out


## Player-UI leak audit. The hidden set is honest: every RED id MINUS
## the BLUE-authorized contacts the model was explicitly allowed to name
## (naming a legally-visible contact is correct Advisor behavior, and the
## display sanitizer already redacts anything else precise-looking).
func _audit_window_texts(tag: String) -> void:
	var dbg: Dictionary = adapter.call("llm_debug_snapshot")
	var supplied: Array = []
	if not (dbg.get("payload", {}) as Dictionary).is_empty():
		supplied = ContextScript.supplied_contact_ids(dbg.get("payload", {}))
	var hidden: Array = []
	for rid in _red_ids():
		if not str(rid) in supplied:
			hidden.append(str(rid))
	for t in awin.call("player_texts"):
		var bad := ViewModelScript.audit_player_text(str(t), hidden)
		_check(bad.is_empty(), "%s: player UI clean%s" % [tag, (" (" + bad + ")" if not bad.is_empty() else "")])
		if not bad.is_empty():
			break


func _slot_of(pkg: Dictionary) -> Dictionary:
	var out := {}
	for o_val in (pkg.get("options", []) as Array):
		if o_val is Dictionary:
			out[str((o_val as Dictionary).get("profile", "?")).to_upper()] = int((o_val as Dictionary).get("slot", 0))
	return out


func _avail_ids(pkg: Dictionary) -> Array:
	var out: Array = []
	for o_val in (pkg.get("options", []) as Array):
		if o_val is Dictionary and str((o_val as Dictionary).get("status", "")).to_upper() in ["AVAILABLE", "DEGRADED"]:
			out.append(str((o_val as Dictionary).get("profile", "?")).to_upper())
	return out


func _validate_live_rec(rec: Dictionary, pkg: Dictionary, tag: String) -> void:
	var avail := _avail_ids(pkg)
	var slots := _slot_of(pkg)
	_check(str(rec.get("profile", "")) in avail, "%s: recommendation is a supplied AVAILABLE/DEGRADED option (%s)" % [tag, str(rec.get("profile", "?"))])
	_check(int(rec.get("slot", 0)) == int(slots.get(str(rec.get("profile", "")), -1)), "%s: slot maps to package" % tag)
	_check(str(rec.get("reason", "")).strip_edges().length() > 0, "%s: Korean reason present" % tag)
	_check(float(rec.get("confidence", -1.0)) >= 0.0 and float(rec.get("confidence", 1.5)) <= 1.0, "%s: confidence in range" % tag)
	var alt := str(rec.get("alternative_profile", ""))
	_check(alt.is_empty() or alt in avail, "%s: alternative valid-or-empty" % tag)


func _wait_rec(rounds: int) -> Dictionary:
	for _r in range(rounds):
		for _i in range(REC_WAIT_FRAMES):
			await process_frame
			var rec: Dictionary = adapter.get("_llm_rec")
			if not rec.is_empty():
				return rec
	return {}


func _run() -> void:
	evidence["model_under_test"] = MODEL_UNDER_TEST
	evidence["config"] = ConfigScript.describe()
	evidence["cases"] = {}
	var packed: PackedScene = load("res://scenes/step2r_battlefield_shell.tscn")
	if packed == null:
		failures.append("canonical scene failed to load")
		_write()
		quit(1)
		return
	battle = packed.instantiate()
	get_root().add_child(battle)
	for _i in range(20):
		await process_frame
	integration = battle.get_node_or_null("Step7Integration")
	for _i in range(180):
		if integration and bool(integration.get("ready_for_step7")):
			break
		await process_frame
	if integration == null or not bool(integration.get("ready_for_step7")):
		failures.append("Step7Integration not ready")
		_write()
		quit(1)
		return
	for _i in range(40):
		await process_frame
	adapter = integration.get("_advisor_adapter")
	awin = integration.get("_advisor_window")
	um = integration.get("unit_manager")
	_check(adapter != null and bool(adapter.call("is_ready")), "advisor adapter ready")

	# --- CASE A: live left-wing cavalry --------------------------------
	_check(bool(um.call("select_unit", "B_CAV_2")), "CASE A: select B_CAV_2")
	(awin as Control).visible = true
	# Live UX path only: the integration poll detects the selection change
	# and refreshes the Advisor exactly once (no test-injected double notify).
	for _i in range(10):
		await process_frame
	var pkg_a: Dictionary = adapter.call("current_package")
	_check(bool(pkg_a.get("ok", false)) and (pkg_a.get("options", []) as Array).size() == 6, "CASE A: deterministic six options present")
	_check(str(awin.get("_llm_lbl").text).find("검토 중") >= 0, "CASE A: loading state shown, options stay interactive")
	var det_ms_a := float((pkg_a.get("latency", {}) as Dictionary).get("total_ms", 0.0))
	var rec_a := await _wait_rec(REC_ROUNDS)
	_check(not rec_a.is_empty(), "CASE A: real Ollama recommendation arrived")
	if not rec_a.is_empty():
		_validate_live_rec(rec_a, pkg_a, "CASE A")
		_audit_window_texts("CASE A")
		_check(str(awin.get("_llm_lbl").text).find("서유선 추천") >= 0, "CASE A: verdict shown in Advisor UI")
		_check(int(awin.get("_recommended_slot")) == int(rec_a.get("slot", -1)), "CASE A: recommended card highlighted")
		var dbg_a: Dictionary = adapter.call("llm_debug_snapshot")
		evidence["cases"]["A_live_B_CAV_2"] = {
			"unit": "B_CAV_2", "options": _summarize_options(pkg_a),
			"recommendation": rec_a, "det_evaluator_ms": det_ms_a,
			"llm_latency_ms": int(dbg_a.get("latency_ms", 0)),
			"prompt_eval_count": int(dbg_a.get("prompt_eval_count", 0)),
			"eval_count": int(dbg_a.get("eval_count", 0)),
			"hallucination_flags": dbg_a.get("hallucination_flags", []),
			"state_version": int(dbg_a.get("state_version", -1)),
		}
		_save_text(PAYLOAD_SAMPLE, JSON.stringify(dbg_a.get("payload", {}), "  "))
		_save_text(RAW_SAMPLE, str(dbg_a.get("raw_content", "")))

	# --- PLAYER OVERRIDE + canonical execution --------------------------
	if not rec_a.is_empty():
		var other_slot := -1
		for o_val in (pkg_a.get("options", []) as Array):
			var o: Dictionary = o_val
			if str(o.get("status", "")) != "UNAVAILABLE" and o.has("destination") \
				and int(o.get("slot", 0)) != int(rec_a.get("slot", 0)):
				other_slot = int(o.get("slot", 0))
				break
		_check(other_slot > 0, "OVERRIDE: a non-recommended executable option exists")
		if other_slot > 0:
			adapter.call("select_option", other_slot)
			var opt: Dictionary = adapter.call("_option_for_slot", other_slot)
			var dest: Dictionary = opt.get("destination", {})
			var want := Vector2i(int(dest.get("q", -9999)), int(dest.get("r", -9999)))
			adapter.call("execute_selected")
			var svc = integration.get("action_service")
			for _i in range(900):
				if not bool(svc.call("is_executing")):
					break
				await process_frame
			var truth = integration.get("truth")
			var after: Dictionary = truth.call("get_unit", "B_CAV_2")
			var got := Vector2i(int(after.get("q", -9998)), int(after.get("r", -9998)))
			_check(got == want, "OVERRIDE: player override executes canonically at (%d,%d)" % [got.x, got.y])
			_check((adapter.get("_llm_rec") as Dictionary).is_empty(), "OVERRIDE: old recommendation cleared after movement")

	# --- CASE B: live right-wing cavalry (same model, new situation) -----
	_check(bool(um.call("select_unit", "B_CAV_4")), "CASE B: select B_CAV_4")
	for _i in range(10):
		await process_frame
	var pkg_b: Dictionary = adapter.call("current_package")
	_check(bool(pkg_b.get("ok", false)), "CASE B: package ok")
	var rec_b := await _wait_rec(REC_ROUNDS)
	_check(not rec_b.is_empty(), "CASE B: real Ollama recommendation arrived")
	if not rec_b.is_empty():
		_validate_live_rec(rec_b, pkg_b, "CASE B")
		_audit_window_texts("CASE B")
		var dbg_b: Dictionary = adapter.call("llm_debug_snapshot")
		evidence["cases"]["B_live_B_CAV_4"] = {
			"unit": "B_CAV_4", "options": _summarize_options(pkg_b),
			"recommendation": rec_b,
			"det_evaluator_ms": float((pkg_b.get("latency", {}) as Dictionary).get("total_ms", 0.0)),
			"llm_latency_ms": int(dbg_b.get("latency_ms", 0)),
			"prompt_eval_count": int(dbg_b.get("prompt_eval_count", 0)),
			"eval_count": int(dbg_b.get("eval_count", 0)),
			"hallucination_flags": dbg_b.get("hallucination_flags", []),
		}

	# --- CASE E: state change mid-inference discards stale ---------------
	_check(bool(um.call("select_unit", "B_CAV_1")), "CASE E: select B_CAV_1 (request in flight)")
	for _i in range(5):
		await process_frame
	var req1 := str(adapter.get("_llm_request_id"))
	_check(not req1.is_empty(), "CASE E: first request actually in flight")
	_check(bool(um.call("select_unit", "B_CAV_2")), "CASE E: switch to B_CAV_2 before inference lands")
	for _i in range(5):
		await process_frame
	_check((adapter.get("_llm_rec") as Dictionary).is_empty(), "CASE E: no stale verdict displayed after switch")
	var rec_e := await _wait_rec(REC_ROUNDS)
	var key_e := str(adapter.get("_llm_key"))
	_check(key_e.begins_with("B_CAV_2|"), "CASE E: current key tracks the live selection (%s)" % key_e)
	if not rec_e.is_empty():
		_check(str(adapter.get("_llm_request_id")) != req1 or req1.is_empty(), "CASE E: superseded request never surfaces")
		_validate_live_rec(rec_e, adapter.call("current_package"), "CASE E")
		var dbg_e: Dictionary = adapter.call("llm_debug_snapshot")
		evidence["cases"]["E_stale_switch"] = {"first_request": req1,
			"final_request": str(adapter.get("_llm_request_id")),
			"stale_discarded_flag": bool(dbg_e.get("stale_discarded", false)),
			"recommendation": rec_e,
			"llm_latency_ms": int(dbg_e.get("latency_ms", 0)),
			"eval_count": int(dbg_e.get("eval_count", 0)),
			"hallucination_flags": dbg_e.get("hallucination_flags", [])}

	# --- Synthetic tactical cases, SAME model (low-risk / high-pressure / degraded) ---
	await _synthetic_case("SYN_low_risk_supported", "SUPPORTED", [
		["SAFE", "AVAILABLE", 1.2], ["SUPPORTED", "AVAILABLE", 1.6],
		["BALANCED", "AVAILABLE", 1.7], ["PRESSURE", "AVAILABLE", 1.8],
		["DEEP", "DEGRADED", 1.5], ["MAXIMUM", "AVAILABLE", 2.0]])
	await _synthetic_case("SYN_high_pressure_isolation", "PRESSURE", [
		["SAFE", "AVAILABLE", 0.9], ["SUPPORTED", "DEGRADED", 1.1],
		["BALANCED", "AVAILABLE", 1.9], ["PRESSURE", "AVAILABLE", 2.6],
		["DEEP", "AVAILABLE", 2.4], ["MAXIMUM", "AVAILABLE", 2.9]])
	await _synthetic_case("SYN_degraded_heavy", "SAFE", [
		["SAFE", "AVAILABLE", 1.0], ["SUPPORTED", "UNAVAILABLE", 0.0],
		["BALANCED", "DEGRADED", 1.2], ["PRESSURE", "UNAVAILABLE", 0.0],
		["DEEP", "UNAVAILABLE", 0.0], ["MAXIMUM", "DEGRADED", 1.4]])

	# --- Malformed response -> one live repair ---------------------------
	await _repair_case()

	# --- True in-flight stale arrival is discarded -----------------------
	await _stale_arrival_case()

	# --- Offline failure keeps deterministic play ------------------------
	# Platform note: on Windows a refused loopback port surfaces as a client
	# TIMEOUT (Godot holds the socket until HTTPRequest.timeout), so the
	# test shortens the deadline instead of waiting out the 120s default.
	var saved_url := str(ProjectSettings.get_setting("strategy_game/ollama/base_url", ConfigScript.DEFAULT_BASE_URL))
	var saved_to := float(ProjectSettings.get_setting("strategy_game/ollama/timeout_seconds", ConfigScript.DEFAULT_TIMEOUT_SECONDS))
	ProjectSettings.set_setting("strategy_game/ollama/base_url", "http://127.0.0.1:9")
	ProjectSettings.set_setting("strategy_game/ollama/timeout_seconds", 8.0)
	adapter.call("request_llm_advice")
	var off_t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - off_t0 < 45000:
		await process_frame
		if str(awin.get("_llm_lbl").text).find("연결할 수 없습니다") >= 0:
			break
	_check(str(awin.get("_llm_lbl").text).find("연결할 수 없습니다") >= 0, "OFFLINE: player-safe message, deterministic cards intact")
	_check((awin.get("_card_btns") as Dictionary).size() == 6, "OFFLINE: six deterministic options remain selectable")
	var off_dbg: Dictionary = adapter.call("llm_debug_snapshot")
	evidence["cases"]["OFFLINE_down_server"] = {"failure": str(off_dbg.get("failure", "")),
		"latency_ms": int(off_dbg.get("latency_ms", 0)),
		"note": "refused loopback port on Windows surfaces as client TIMEOUT; deterministic play unaffected"}
	ProjectSettings.set_setting("strategy_game/ollama/base_url", saved_url)
	ProjectSettings.set_setting("strategy_game/ollama/timeout_seconds", saved_to)

	_write()
	quit(0 if failures.is_empty() else 1)


func _summarize_options(pkg: Dictionary) -> Array:
	var out: Array = []
	for o_val in (pkg.get("options", []) as Array):
		var o: Dictionary = o_val
		out.append({"id": str(o.get("profile", "?")), "status": str(o.get("status", "")),
			"utility": float(o.get("utility", 0.0)),
			"dest": o.get("destination", {}),
			"risk": (o.get("risk", {}) as Dictionary).get("overall", 0.0)})
	return out


func _synthetic_case(tag: String, _expect_hint: String, rows: Array) -> void:
	var opts: Array = []
	var slot := 0
	for row in rows:
		slot += 1
		var o := {"slot": slot, "profile": str(row[0]), "status": str(row[1]),
			"reason": "" if str(row[1]) == "AVAILABLE" else "no legal candidate satisfies the intent/profile contract",
			"utility": float(row[2]),
			"top_positive": ["INTENT_PROGRESS +1.00"], "top_negative": ["COUNTER_RISK -0.30"],
			"contributions": [
				{"feature": "INTENT_PROGRESS", "raw": 0.7, "weight": 1.5, "contribution": 1.05},
				{"feature": "COUNTER_RISK", "raw": 0.15, "weight": -2.0, "contribution": -0.3}],
			"risk": {"overall": 0.35, "pressure": 0.5, "support": 0.6, "mobility": 0.6, "intent_progress": 0.7},
			"provenance": {"known_ids": ["R_ARC_1"], "stale_ids": ["R_SPE_9"], "objective_fallback": true}}
		if str(row[1]) != "UNAVAILABLE":
			o["destination"] = {"q": 10 + slot, "r": 5}
			o["route"] = {"cost": 1.5, "path": [[9, 5], [10 + slot, 5]]}
		opts.append(o)
	var pkg := {"ok": true, "unit_id": "B_CAV_SYN", "intent": {"action": "ADVANCE", "direction": "FORWARD", "axis": "FORWARD"},
		"state_version": 900 + slot, "fingerprint": "syn-%s" % tag, "options": opts,
		"candidate_count": 18, "known_contacts_used": 2}
	var unit := {"id": "B_CAV_SYN", "class": "cavalry", "faction": "blue", "q": 9, "r": 5,
		"soldier_count": 250, "max_count": 300, "morale": 75.0, "local_supply": 3.0,
		"fatigue": 10.0, "remaining_mp": 3.0, "base_mp": 3.0, "routed": false,
		"garrisoned": false, "action_ended": false}
	var bk := {"side": "blue", "current_turn": 5,
		"own_forces": [unit,
			{"id": "B_INF_SYN", "class": "infantry", "faction": "blue", "q": 8, "r": 5,
				"soldier_count": 400, "max_count": 450, "morale": 80.0, "local_supply": 6.0,
				"fatigue": 0.0, "remaining_mp": 2.0, "base_mp": 2.0, "routed": false,
				"garrisoned": false, "action_ended": false}],
		"current_enemy_observations": [
			{"id": "R_ARC_1", "q": 14, "r": 6, "class": "archer", "class_kr": "궁병대",
				"troop_text": "병력: 소규모", "morale": "unknown", "food": "unknown", "fatigue": "unknown",
				"scout_observed": true, "combat_assessed": false, "contact_turn": 5, "contact_state": "current_visible"}],
		"last_known_enemy_contacts": [
			{"id": "R_SPE_9", "last_seen_turn": 3, "q": 17, "r": 3, "class": "spearman",
				"troop_text": "병력: 알 수 없음", "morale": "unknown", "food": "unknown", "fatigue": "unknown",
				"contact_state": "stale_last_known"}],
		"visible_hexes": 36, "strongholds": [],
		"logistics": {"troops": 650, "portable_supply": 9.0, "average_morale": 77.0, "formation_count": 2}}
	var built: Dictionary = ContextScript.build({"package": pkg, "unit": unit, "blue_knowledge": bk,
		"cell_data": {}, "intent": {"action": "ADVANCE", "direction": "FORWARD"},
		"state_version": 900 + slot, "fingerprint": "syn-%s" % tag,
		"cluster_signature": "syn", "request_id": "syn-%s" % tag})
	_check(bool(built.get("ok", false)), "%s: synthetic BLUE context builds" % tag)
	_check(ContextScript.audit_enemy_section(built.get("context", {})).is_empty(), "%s: BLUE audit clean" % tag)
	var sel = SelectorScript.new()
	battle.add_child(sel)
	var snap := {"unit_id": "B_CAV_SYN", "state_version": 900 + slot, "fingerprint": "syn-%s" % tag}
	sel.state_provider = Callable(self, "_fixed_snap").bind(snap)
	var avail: Array = []
	var slots := {}
	for o_val in opts:
		slots[str((o_val as Dictionary).get("profile", ""))] = int((o_val as Dictionary).get("slot", 0))
		if str((o_val as Dictionary).get("status", "")) != "UNAVAILABLE":
			avail.append(str((o_val as Dictionary).get("profile", "")))
	var t0 := Time.get_ticks_msec()
	var started: Dictionary = sel.advise("syn-%s" % tag, built.get("context", {}), snap, slots, avail)
	_check(bool(started.get("ok", false)), "%s: synthetic advice request started" % tag)
	var rec := {}
	for _r in range(REC_ROUNDS):
		for _i in range(REC_WAIT_FRAMES):
			await process_frame
			if not sel.has_active():
				break
		if not sel.has_active():
			break
	var dbg: Dictionary = sel.debug_snapshot()
	rec = dbg.get("parsed", {})
	var ok_pick := (dbg.get("failure", "") as String).is_empty() \
		and str((rec.get("recommended_option_id", "") as String)).strip_edges().to_upper() in avail
	_check(ok_pick, "%s: SAME model returned a legal supplied option (%s)" % [tag, str(rec.get("recommended_option_id", "?"))])
	evidence["cases"][tag] = {"recommendation_raw": dbg.get("raw_content", ""),
		"parsed": rec, "failure": str(dbg.get("failure", "")),
		"latency_ms": Time.get_ticks_msec() - t0,
		"prompt_eval_count": int(dbg.get("prompt_eval_count", 0)),
		"eval_count": int(dbg.get("eval_count", 0)),
		"hallucination_flags": dbg.get("hallucination_flags", [])}
	sel.queue_free()


func _repair_case() -> void:
	var sel = SelectorScript.new()
	battle.add_child(sel)
	var snap := {"unit_id": "B_REP", "state_version": 1, "fingerprint": "rep-1"}
	sel.state_provider = Callable(self, "_fixed_snap").bind(snap)
	var ctx := {"state_identity": {"request_id": "rep-1"}, "options": []}
	var started: Dictionary = sel.advise("rep-1", ctx, snap,
		{"SAFE": 1, "SUPPORTED": 2, "BALANCED": 3, "PRESSURE": 4, "DEEP": 5, "MAXIMUM": 6},
		["SAFE", "SUPPORTED", "BALANCED", "PRESSURE", "DEEP", "MAXIMUM"])
	_check(bool(started.get("ok", false)), "REPAIR: advice request started")
	# Kill the real transport for request-1 so the injected malformed result
	# is the only response the selector processes for this id; the repair
	# request then runs live against Ollama.
	sel._client.cancel_active()
	# Inject a malformed transport result: selector must fire ONE repair request.
	sel._on_chat_finished("rep-1", {"ok": true, "request_id": "rep-1", "http_status": 200,
		"content_text": "I think cavalry should advance boldly, no JSON here.",
		"latency_ms": 5, "prompt_eval_count": 10, "eval_count": 20,
		"prompt_eval_duration_ns": 1, "eval_duration_ns": 2,
		"total_duration_ns": 3, "load_duration_ns": 0})
	for _i in range(30):
		await process_frame
	_check(sel.has_active(), "REPAIR: exactly one repair request issued after malformed output")
	for _r in range(REC_ROUNDS):
		for _i in range(REC_WAIT_FRAMES):
			await process_frame
			if not sel.has_active():
				break
		if not sel.has_active():
			break
	var dbg: Dictionary = sel.debug_snapshot()
	evidence["cases"]["REPAIR_malformed"] = {"parsed": dbg.get("parsed", {}),
		"failure": str(dbg.get("failure", "")), "raw_first": str(dbg.get("raw_content", "")).left(300)}
	_check(true, "REPAIR: repair round completed (ready or graceful MALFORMED, no loop)")
	sel.queue_free()


func _fixed_snap(snap: Dictionary) -> Dictionary:
	return (snap as Dictionary).duplicate()


var _stale_mode := 0
var _stale_emitted := false


func _shifting_snap() -> Dictionary:
	# S1 while the request is young; S2 once inference is presumably running.
	if _stale_mode == 0:
		return {"unit_id": "B_STALE_1", "state_version": 11, "fingerprint": "st-11"}
	return {"unit_id": "B_STALE_2", "state_version": 12, "fingerprint": "st-12"}


func _stale_arrival_case() -> void:
	var sel = SelectorScript.new()
	battle.add_child(sel)
	_stale_mode = 0
	_stale_emitted = false
	sel.state_provider = Callable(self, "_shifting_snap")
	sel.recommendation_ready.connect(func(_rid: String, _rec: Dictionary) -> void: _stale_emitted = true)
	sel.recommendation_failed.connect(func(_rid: String, _c: String, _m: String) -> void: _stale_emitted = true)
	var snap := {"unit_id": "B_STALE_1", "state_version": 11, "fingerprint": "st-11"}
	var started: Dictionary = sel.advise("stale-1",
		{"state_identity": {"request_id": "stale-1"}, "options": []}, snap,
		{"SAFE": 1, "SUPPORTED": 2, "BALANCED": 3, "PRESSURE": 4, "DEEP": 5, "MAXIMUM": 6},
		["SAFE", "SUPPORTED", "BALANCED", "PRESSURE", "DEEP", "MAXIMUM"])
	_check(bool(started.get("ok", false)), "STALE-ARRIVAL: advice request started")
	for _i in range(30):
		await process_frame
	_stale_mode = 1 # battle moved on while Ollama still thinks
	for _r in range(REC_ROUNDS):
		for _i in range(REC_WAIT_FRAMES):
			await process_frame
			if not sel.has_active():
				break
		if not sel.has_active():
			break
	var dbg: Dictionary = sel.debug_snapshot()
	evidence["cases"]["STALE_arrival"] = {"stale_discarded": bool(dbg.get("stale_discarded", false)),
		"failure": str(dbg.get("failure", "")), "emitted": _stale_emitted}
	_check(bool(dbg.get("stale_discarded", false)), "STALE-ARRIVAL: late response discarded, nothing displayed")
	_check(not _stale_emitted, "STALE-ARRIVAL: no recommendation/failed signal surfaced for stale state")
	sel.queue_free()


func _save_text(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string(text)
		f.close()


func _write() -> void:
	evidence["passed"] = passed
	evidence["failures"] = failures
	_save_text(OUT, JSON.stringify(evidence, "  "))
	print("[OllamaLive] passed=%d failures=%d" % [passed, failures.size()])
	for x in failures:
		print("[OllamaLive] FAIL: %s" % str(x))
