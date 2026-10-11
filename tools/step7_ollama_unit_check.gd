extends SceneTree

## Offline unit check for the Ollama Advisor pilot (no network, no scene).
## Verifies: BLUE-only context boundary, audit tripwire, JSON extraction,
## recommendation validation matrix, stale comparison, hallucination screen.
## Writes evidence; quit code 0 = pass, 1 = fail.

const OUT := "D:/Game development/Demon slayer/StrategyGame/evidence/step7_ollama_advisor/unit_check.json"
const ContextScript = preload("res://scripts/step7/step7_advisor_context.gd")
const SelectorScript = preload("res://scripts/step7/step7_advisor_llm_selector.gd")
const ViewModelScript = preload("res://scripts/step7/step7_advisor_viewmodel.gd")

var failures: Array = []
var passed := 0


func _check(cond: bool, label: String) -> void:
	if cond:
		passed += 1
	else:
		failures.append(label)


func _init() -> void:
	call_deferred("_run")


func _mk_option(profile: String, slot: int, status: String, util: float) -> Dictionary:
	return {"slot": slot, "profile": profile, "status": status,
		"reason": "" if status == "AVAILABLE" else "no legal candidate satisfies the intent/profile contract",
		"destination": {"q": 10 + slot, "r": 5}, "route": {"cost": 1.0 + slot * 0.2, "path": [[9, 5], [10 + slot, 5]]},
		"utility": util, "top_positive": ["INTENT_PROGRESS +1.10"], "top_negative": ["COUNTER_RISK -0.40"],
		"contributions": [
			{"feature": "INTENT_PROGRESS", "raw": 0.8, "weight": 1.5, "contribution": 1.2},
			{"feature": "COUNTER_RISK", "raw": 0.2, "weight": -2.0, "contribution": -0.4}],
		"risk": {"overall": 0.3, "pressure": 0.5, "support": 0.6, "mobility": 0.7, "intent_progress": 0.8},
		"provenance": {"known_ids": ["R_ARC_1"], "stale_ids": ["R_SPE_9"], "objective_fallback": true}}


func _mk_bk(with_hidden_trap: bool) -> Dictionary:
	var cur := {"id": "R_ARC_1", "q": 15, "r": 6, "class": "archer",
		"class_kr": "궁병대", "troop_text": "병력: 소규모",
		"morale": "unknown", "food": "unknown", "fatigue": "unknown",
		"scout_observed": true, "combat_assessed": false,
		"contact_turn": 3, "contact_state": "current_visible"}
	if with_hidden_trap:
		# Simulates a hostile upstream: exact vitals must still never cross.
		cur["soldier_count"] = 250
		cur["plan"] = "AMBUSH_AT_20_8"
	var stale := {"id": "R_SPE_9", "last_seen_turn": 1, "q": 18, "r": 2,
		"class": "spearman", "troop_text": "병력: 알 수 없음",
		"morale": "unknown", "food": "unknown", "fatigue": "unknown",
		"contact_state": "stale_last_known"}
	return {"side": "blue", "current_turn": 3,
		"own_forces": [
			{"id": "B_CAV_2", "class": "cavalry", "remaining_mp": 3.0, "base_mp": 3.0,
				"faction": "blue", "q": 12, "r": 5, "soldier_count": 260, "max_count": 300,
				"morale": 82.0, "local_supply": 4.5, "fatigue": 5.0, "routed": false,
				"garrisoned": false, "action_ended": false, "is_convoy": false},
			{"id": "B_CAV_1", "class": "cavalry", "remaining_mp": 3.0, "base_mp": 3.0,
				"faction": "blue", "q": 11, "r": 4, "soldier_count": 280, "max_count": 300,
				"morale": 90.0, "local_supply": 5.0, "fatigue": 0.0, "routed": false,
				"garrisoned": false, "action_ended": false, "is_convoy": false}],
		"current_enemy_observations": [cur],
		"last_known_enemy_contacts": [stale],
		"visible_hexes": 40, "strongholds": [],
		"logistics": {"troops": 540, "portable_supply": 9.5, "average_morale": 86.0, "formation_count": 2}}


func _mk_pkg() -> Dictionary:
	return {"ok": true, "unit_id": "B_CAV_2",
		"intent": {"action": "ADVANCE", "direction": "FORWARD", "axis": "FORWARD"},
		"state_version": 7, "fingerprint": "fp-unit-7",
		"options": [
			_mk_option("SAFE", 1, "AVAILABLE", 1.2), _mk_option("SUPPORTED", 2, "AVAILABLE", 1.5),
			_mk_option("BALANCED", 3, "AVAILABLE", 1.8), _mk_option("PRESSURE", 4, "AVAILABLE", 2.1),
			_mk_option("DEEP", 5, "DEGRADED", 1.9), _mk_option("MAXIMUM", 6, "AVAILABLE", 2.4)],
		"candidate_count": 24, "known_contacts_used": 2}


func _mk_unit() -> Dictionary:
	return {"id": "B_CAV_2", "class": "cavalry", "faction": "blue", "q": 12, "r": 5,
		"soldier_count": 260, "max_count": 300, "morale": 82.0, "local_supply": 4.5,
		"fatigue": 5.0, "remaining_mp": 3.0, "base_mp": 3.0, "routed": false,
		"garrisoned": false, "action_ended": false}


func _good_rec() -> Dictionary:
	return {"recommended_option_id": "PRESSURE", "confidence": 0.78,
		"reason": "좌익 기병이 지원 속에 전진 압박을 걸 수 있는 형세이다.",
		"primary_risk": "궁병 대응 사격에 일부 노출된다.",
		"alternative_option_id": "SUPPORTED", "alternative_reason": "지원을 더 두텁게 유지하는 차선이다.",
		"battlefield_assessment": "전반적으로 아군에게 유리한 국면이다."}


func _run() -> void:
	var pkg := _mk_pkg()
	var built: Dictionary = ContextScript.build({"package": pkg, "unit": _mk_unit(),
		"blue_knowledge": _mk_bk(false), "cell_data": {},
		"intent": {"action": "ADVANCE", "direction": "FORWARD"},
		"state_version": 7, "fingerprint": "fp-unit-7",
		"cluster_signature": "t=3|C:1.0", "request_id": "unit-001"})
	_check(bool(built.get("ok", false)), "context builds from BLUE sources")
	var ctx: Dictionary = built.get("context", {})
	_check(str((ctx.get("state_identity", {}) as Dictionary).get("request_id", "")) == "unit-001", "state identity carries request id")
	_check((ctx.get("options", []) as Array).size() == 6, "all six options serialized")
	_check(ContextScript.audit_enemy_section(ctx).is_empty(), "enemy-section audit clean")
	var audit: Dictionary = built.get("audit", {})
	_check(bool(audit.get("world_truth_read", true)) == false, "audit records no WorldTruth read")

	# Hidden-trap knowledge must still not cross the boundary.
	var built2: Dictionary = ContextScript.build({"package": pkg, "unit": _mk_unit(),
		"blue_knowledge": _mk_bk(true), "cell_data": {},
		"intent": {"action": "ADVANCE", "direction": "FORWARD"},
		"state_version": 7, "fingerprint": "fp-unit-7",
		"cluster_signature": "t=3|C:1.0", "request_id": "unit-002"})
	var ctx2: Dictionary = built2.get("context", {})
	_check(ContextScript.audit_enemy_section(ctx2).is_empty(), "injected exact vitals still excluded from enemy section")
	var enemy_text := JSON.stringify(ctx2.get("authorized_enemy_knowledge", {}))
	_check(enemy_text.find("250") < 0 and enemy_text.find("AMBUSH_AT_20_8") < 0, "injected troop count/plan absent from enemy section")

	# --- Selector validation matrix (no network) ---
	var sel = SelectorScript.new()
	get_root().add_child(sel)
	var entry := {"available": ["SAFE", "SUPPORTED", "BALANCED", "PRESSURE", "DEEP", "MAXIMUM"]}
	var ok_res: Dictionary = sel._validate(_good_rec(), entry)
	_check(bool(ok_res.get("ok", false)) and str(ok_res.get("pick", "")) == "PRESSURE", "valid recommendation accepted")

	var invented := _good_rec()
	invented["recommended_option_id"] = "FLANK_LEFT"
	_check(not bool(sel._validate(invented, entry).get("ok", true)), "invented option id rejected")

	var gone := _good_rec()
	gone["recommended_option_id"] = "DEEP"
	var entry2 := {"available": ["SAFE", "SUPPORTED", "BALANCED", "PRESSURE", "MAXIMUM"]}
	_check(not bool(sel._validate(gone, entry2).get("ok", true)), "UNAVAILABLE pick rejected")

	var missing := _good_rec()
	missing.erase("primary_risk")
	_check(not bool(sel._validate(missing, entry).get("ok", true)), "missing key rejected")

	var badconf := _good_rec()
	badconf["confidence"] = 1.5
	_check(not bool(sel._validate(badconf, entry).get("ok", true)), "out-of-range confidence rejected")

	var dupalt := _good_rec()
	dupalt["alternative_option_id"] = "PRESSURE"
	_check(not bool(sel._validate(dupalt, entry).get("ok", true)), "alternative duplicating pick rejected")

	var badalt := _good_rec()
	badalt["alternative_option_id"] = "RETREAT_NOW"
	_check(not bool(sel._validate(badalt, entry).get("ok", true)), "invented alternative rejected")

	var empty := _good_rec()
	empty["reason"] = "   "
	_check(not bool(sel._validate(empty, entry).get("ok", true)), "empty reason rejected")

	# --- JSON extraction ---
	var fenced: Dictionary = SelectorScript._extract_json("```json\n{\"a\": 1}\n```")
	_check(int(fenced.get("a", 0)) == 1, "fenced JSON extracted")
	var prose: Dictionary = SelectorScript._extract_json("Here is my call: {\"recommended_option_id\": \"SAFE\"} done.")
	_check(str(prose.get("recommended_option_id", "")) == "SAFE", "prose-wrapped JSON extracted")
	_check((SelectorScript._extract_json("no braces at all") as Dictionary).is_empty(), "non-JSON yields empty (repair path)")

	# --- Stale comparison (state_provider only, no HTTP) ---
	var live := {"unit_id": "B_CAV_2", "state_version": 7, "fingerprint": "fp-unit-7"}
	sel.state_provider = Callable(self, "_snap_a").bind(live)
	_check(not bool(sel._is_stale(live.duplicate())), "identical snapshot not stale")
	_check(bool(sel._is_stale({"unit_id": "B_CAV_3", "state_version": 7, "fingerprint": "fp-unit-7"})), "unit switch detected stale")
	_check(bool(sel._is_stale({"unit_id": "B_CAV_2", "state_version": 8, "fingerprint": "fp-unit-8"})), "post-move version detected stale")

	# --- Hallucination screen ---
	var supplied: Array = ContextScript.supplied_contact_ids(ctx)
	_check("B_CAV_1" in supplied and "R_SPE_9" in supplied, "supplied set covers roster + provenance contacts")
	var hrec := _good_rec()
	hrec["reason"] = "B_CAV_2가 R_ARC_1 방향으로 R_GHOST_9를 경계하며 FORMATION_SUPPORT를 유지한다."
	var flags: Array = sel._screen_hallucinations(hrec, supplied)
	_check("R_GHOST_9" in flags, "unsupplied id flagged")
	_check(not ("R_ARC_1" in flags) and not ("B_CAV_2" in flags), "supplied ids not flagged")
	_check(not ("FORMATION_SUPPORT" in flags), "doctrine vocabulary not flagged")

	# --- Display sanitizer ---
	var dirty := "R_GHOST_9와 B_PHANTOM_1이 접근하고 R_ARC_1이 보이며 FORMATION_SUPPORT가 중요하다."
	var clean: Dictionary = ViewModelScript.sanitize_advisor_text(dirty, supplied)
	_check(str(clean.get("text", "")).find("R_GHOST_9") < 0 and str(clean.get("text", "")).find("B_PHANTOM_1") < 0, "invented ids redacted from player text")
	_check(str(clean.get("text", "")).find("R_ARC_1") >= 0 and str(clean.get("text", "")).find("FORMATION_SUPPORT") >= 0, "supplied ids and vocabulary preserved")
	_check((clean.get("redactions", []) as Array).size() == 2, "redaction count reported")
	_check(str(clean.get("text", "")).find("적 부대") >= 0 and str(clean.get("text", "")).find("아군 부대") >= 0, "side-appropriate generics used")

	# --- Audit uses token boundaries (R_GAR_INF_1 is not R_INF_1) ---
	_check(ViewModelScript.audit_player_text("R_GAR_INF_1 부대가 보인다.", ["R_INF_1"]).is_empty(), "garrison id does not trip sub-id audit")
	_check(not ViewModelScript.audit_player_text("R_INF_1 부대가 보인다.", ["R_INF_1"]).is_empty(), "exact hidden id still trips audit")

	_write()
	quit(0 if failures.is_empty() else 1)


func _snap_a(live: Dictionary) -> Dictionary:
	return (live as Dictionary).duplicate()


func _write() -> void:
	DirAccess.make_dir_recursive_absolute("D:/Game development/Demon slayer/StrategyGame/evidence/step7_ollama_advisor")
	var f := FileAccess.open(OUT, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({"passed": passed, "failures": failures}, "  "))
		f.close()
	print("[OllamaUnit] passed=%d failures=%d" % [passed, failures.size()])
	for x in failures:
		print("[OllamaUnit] FAIL: %s" % str(x))
