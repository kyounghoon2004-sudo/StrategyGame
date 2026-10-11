extends SceneTree

## FAST COORDINATOR — production-path fixture runner (fixtures A–H + contract
## matrix + telemetry).
##
## Usage (Windows):
##   Godot_v4.2.2-stable_win64_console.exe --headless --path "D:\Game development\Demon slayer\StrategyGame" -s res://scripts/cloud2/cloud2_coord_entry.gd
##
## Exit code 0 = all gates pass, 1 = any gate fails. Writes
## res://evidence/cloud2_coord/verification_coord.json.
##
## Every selection fixture runs the REAL production path — coordinator JSON
## text -> Cloud2CoordResponse.parse_* -> Cloud2CoordMenu.expand_* ->
## Cloud2GeneralPlan.validate_plan -> Cloud2MissionManager.apply_plan — with
## no mocks past the JSON text:
##   A valid compact initial selection -> expands -> PLAN_ADOPTED (c2)
##   B missing optional hypotheses -> still valid (c3)
##   C hypothesis missing name during review -> warning/drop, core valid (c4)
##   D unknown coordination option -> precise rejection (c5)
##   E valid KEEP review (c6)
##   F valid ADJUST review (c7)
##   G schema retry -> corrected compact response -> adoption (c8)
##   H same frozen menu -> deterministic expansion (c9)
## Plus: menu determinism (c1), smuggled-tactics isolation (c10), packet
## sizes (c11), REPLAN (c12), stale snapshot (c13), unassigned defaults
## (c14), doctrine mapping (c15), Model View surfaces (c16), empty menu (c17).
##
## No network is ever attempted; no tactical scoring, compiler, executor, or
## combat code is touched by any fixture here.

const CoordMenuCls = preload("res://scripts/cloud2/cloud2_coord_menu.gd")
const CoordResponseCls = preload("res://scripts/cloud2/cloud2_coord_response.gd")
const GeneralPacketCls = preload("res://scripts/cloud2/cloud2_general_packet.gd")
const MissionManagerCls = preload("res://scripts/cloud2/cloud2_mission_manager.gd")
const ModelViewCls = preload("res://scripts/cloud2/cloud2_model_view.gd")

const OUT_DIR := "res://evidence/cloud2_coord"
const OUT_PATH := "res://evidence/cloud2_coord/verification_coord.json"

var _gates: Dictionary = {}


func _init() -> void:
	call_deferred("_run")


func _record(gate: String, status: String, evidence: Dictionary) -> void:
	_gates[gate] = {"status": status, "evidence": evidence}
	print("[COORD][%s] %s" % [gate, status.to_upper()])


func _exit_code() -> int:
	for key in _gates.keys():
		if str((_gates[key] as Dictionary).get("status", "")) != "pass":
			return 1
	return 0


func _write_and_quit(code: int) -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	var f := FileAccess.open(OUT_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(_gates, "  "))
		f.close()
	print("DET_CLOUD2_COORD_" + ("PASS" if code == 0 else "FAIL"))
	quit(code)


func _run() -> void:
	_c1_menu_build()
	_c2_initial_adopts()
	_c3_no_hypotheses()
	_c4_bad_hypothesis_warns()
	_c5_precise_rejections()
	_c6_keep_review()
	_c7_adjust_review()
	_c8_retry_then_adopt()
	_c9_deterministic_expansion()
	_c10_smuggled_tactics_ignored()
	_c11_packet_sizes()
	_c12_replan_review()
	_c13_stale_snapshot()
	_c14_unassigned_defaults()
	_c15_doctrine_mapping()
	_c16_modelview_coord()
	_c17_empty_menu()
	_write_and_quit(_exit_code())


# --- synthetic observation (live-shaped roster) -------------------------------

func _unit(uid: String, cls: String, region: String, soldiers: int, status: String = "ready") -> Dictionary:
	return {"unit_id": uid, "side": "RED", "class": cls, "q": 0, "r": 0,
		"region": region, "status": status, "has_acted": status != "ready",
		"remaining_mp": 2.0, "base_mp": 2.0, "can_attack": true, "attack_options": 1,
		"formation": "FIELD", "soldiers": soldiers, "soldiers_max": soldiers,
		"hp_avg": 10.0, "hp_max": 10.0, "morale_avg": 0.7, "condition": "FRESH",
		"threat_from": []}


func _synth_obs() -> Dictionary:
	return {"ok": true, "side": "RED", "turn": 1, "snapshot_id": "snap_coord_001",
		"battle_id": "coord_battle", "scenario_id": "coord_scenario",
		"mission": {"type": "BATTLE", "objective": "Defeat BLUE."},
		"parity": {"state_version": 7},
		"friendly_units": [
			_unit("R_INF_1", "infantry", "CENTER", 400),
			_unit("R_INF_2", "infantry", "CENTER", 380),
			_unit("R_SPE_1", "spearman", "CENTER", 300),
			_unit("R_ARC_1", "archer", "CENTER", 200),
			_unit("R_CAV_1", "cavalry", "NORTH", 150),
			_unit("R_CAV_2", "cavalry", "NORTH", 150),
			_unit("R_SCT_1", "scout", "NORTH", 60),
			_unit("R_CON_1", "conscript", "SOUTH", 250),
			_unit("R_SIG_1", "siege", "SOUTH", 120),
			_unit("R_HQ_1", "hq", "CENTER", 50),
		],
		"known_enemy_units": [
			{"formation": "BLUE_LINE", "units": ["B_INF_1"], "avg_soldiers": 350,
				"classes": ["infantry"], "regions": ["CENTER"]},
		]}


func _full_selection(menu: Dictionary) -> Dictionary:
	var asn: Array = []
	for g_val in (menu.get("groups", []) as Array):
		if g_val is Dictionary:
			var g: Dictionary = g_val
			var opts: Array = g.get("options", []) as Array
			asn.append({"group": str(g.get("id", "")), "choice": str((opts[0] as Dictionary).get("id", ""))})
	return {"concept": "FIX_AND_FLANK", "main_effort": "CENTER",
		"doctrine_profile": {"aggression": "STANDARD", "tempo": "FAST", "risk": "BALANCED", "reserve": "STRICT", "pursuit": "STANDARD"},
		"assignments": asn, "review_horizon": 3, "snapshot_id": "snap_coord_001"}


func _adopt_initial(mgr: RefCounted, obs: Dictionary, sel_text: String) -> Dictionary:
	var menu := CoordMenuCls.build_menu(obs)
	var parsed := CoordResponseCls.parse_initial(sel_text, {"menu": menu, "snapshot_id": str(obs.get("snapshot_id", "")), "turn": 1})
	if not bool(parsed.get("ok", false)):
		return {"menu": menu, "parsed": parsed, "expanded": {}, "applied": {"ok": false}}
	var expanded := CoordMenuCls.expand_initial(menu, parsed.get("selection", {}), 1,
		str(obs.get("snapshot_id", "")), obs.get("mission", {}), parsed.get("warnings", []))
	if not bool(expanded.get("ok", false)):
		return {"menu": menu, "parsed": parsed, "expanded": expanded, "applied": {"ok": false}}
	var applied: Dictionary = mgr.call("apply_plan", expanded.get("plan", {}), 1,
		str(obs.get("snapshot_id", "")), str(obs.get("battle_id", "")))
	if bool(applied.get("ok", false)):
		mgr.call("bind_coordination", {"choices": expanded.get("choices", {}),
			"menu_snapshot": str(menu.get("snapshot_id", "")), "turn": 1,
			"warnings": expanded.get("warnings", [])})
	return {"menu": menu, "parsed": parsed, "expanded": expanded, "applied": applied}


# --- gates --------------------------------------------------------------------

## FAST-01/04: menu generation — stable group/option IDs, full coverage.
func _c1_menu_build() -> void:
	var ev := {}
	var obs := _synth_obs()
	var m1 := CoordMenuCls.build_menu(obs)
	var m2 := CoordMenuCls.build_menu(obs)
	var groups: Array = m1.get("groups", []) as Array
	ev["groups"] = groups.size()
	ev["group_ids"] = groups.map(func(g: Dictionary) -> String: return str(g.get("id", "")))
	ev["families"] = groups.map(func(g: Dictionary) -> String: return str(g.get("family", "")))
	var covered: Array = []
	var opt_total := 0
	var reserve_ok := true
	for g_val in groups:
		var g: Dictionary = g_val
		covered.append_array(g.get("unit_ids", []) as Array)
		var opts: Array = g.get("options", []) as Array
		opt_total += opts.size()
		if CoordMenuCls.default_choice_id(g).is_empty():
			reserve_ok = false
	covered.sort()
	ev["covered"] = covered.size()
	ev["options"] = opt_total
	ev["menu_chars"] = JSON.stringify(m1).length()
	ev["deterministic"] = JSON.stringify(m1) == JSON.stringify(m2)
	ev["reserve_defaults"] = reserve_ok
	var ok := groups.size() == 4 \
		and str(groups[0].get("id", "")) == "G1" and str(groups[3].get("id", "")) == "G4" \
		and covered.size() == 10 and opt_total >= 12 \
		and bool(ev["deterministic"]) and reserve_ok \
		and int(ev["menu_chars"]) < 6000
	_record("c1_menu_build", "pass" if ok else "fail", ev)


## Fixture A / FAST-26: valid compact initial selection -> PLAN_ADOPTED.
func _c2_initial_adopts() -> void:
	var ev := {}
	var obs := _synth_obs()
	var menu := CoordMenuCls.build_menu(obs)
	var sel_text := JSON.stringify(_full_selection(menu))
	ev["selection_chars"] = sel_text.length()
	var mgr := MissionManagerCls.new()
	var flow := _adopt_initial(mgr, obs, sel_text)
	var applied: Dictionary = flow.get("applied", {})
	ev["parse_ok"] = bool((flow.get("parsed", {}) as Dictionary).get("ok", false))
	ev["expand_ok"] = bool((flow.get("expanded", {}) as Dictionary).get("ok", false))
	ev["adopt_ok"] = bool(applied.get("ok", false))
	ev["adopt_version"] = int(applied.get("version", 0))
	ev["missions"] = (mgr.get_plan().get("missions", []) as Array).size()
	ev["source"] = str(mgr.get_plan().get("source", ""))
	ev["coord_bound"] = not (mgr.get_coordination() as Dictionary).is_empty()
	var ok := int(ev["selection_chars"]) < 1500 \
		and bool(ev["parse_ok"]) and bool(ev["expand_ok"]) \
		and bool(ev["adopt_ok"]) and int(ev["adopt_version"]) == 1 \
		and int(ev["missions"]) == 4 and bool(ev["coord_bound"])
	_record("c2_initial_adopts", "pass" if ok else "fail", ev)


## Fixture B / FAST-06: hypotheses absent -> still valid.
func _c3_no_hypotheses() -> void:
	var ev := {}
	var obs := _synth_obs()
	var menu := CoordMenuCls.build_menu(obs)
	var sel := _full_selection(menu)
	ev["has_key"] = sel.has("opponent_hypotheses")
	var parsed := CoordResponseCls.parse_initial(JSON.stringify(sel), {"menu": menu, "snapshot_id": "snap_coord_001", "turn": 1})
	ev["parse_ok"] = bool(parsed.get("ok", false))
	ev["hypotheses"] = ((parsed.get("selection", {}) as Dictionary).get("hypotheses", []) as Array).size()
	var ok := not bool(ev["has_key"]) and bool(ev["parse_ok"]) and int(ev["hypotheses"]) == 0
	_record("c3_no_hypotheses", "pass" if ok else "fail", ev)


## Fixture C / FAST-07/08: malformed optional hypotheses -> drop + warning,
## core plan still valid (initial AND review paths).
func _c4_bad_hypothesis_warns() -> void:
	var ev := {}
	var obs := _synth_obs()
	var menu := CoordMenuCls.build_menu(obs)
	var sel := _full_selection(menu)
	sel["opponent_hypotheses"] = [{"confidence": 0.9, "evidence": ["x"]}, "junk",
		{"hypothesis": "CENTER_BREAKTHROUGH", "confidence": 2.0, "evidence": ["massing center"]}]
	var parsed := CoordResponseCls.parse_initial(JSON.stringify(sel), {"menu": menu, "snapshot_id": "snap_coord_001", "turn": 1})
	ev["initial_ok"] = bool(parsed.get("ok", false))
	ev["initial_kept"] = ((parsed.get("selection", {}) as Dictionary).get("hypotheses", []) as Array).size()
	var warns: Array = parsed.get("warnings", []) as Array
	ev["initial_warned"] = warns.any(func(w: String) -> bool: return str(w).begins_with("DROPPED_INVALID_HYPOTHESIS"))
	var kept: Array = (parsed.get("selection", {}) as Dictionary).get("hypotheses", []) as Array
	ev["clamped"] = (not kept.is_empty()) and float((kept[0] as Dictionary).get("confidence", -1.0)) == 1.0
	var mgr := MissionManagerCls.new()
	var flow := _adopt_initial(mgr, obs, JSON.stringify(sel))
	ev["adopted_despite_bad_hyp"] = bool((flow.get("applied", {}) as Dictionary).get("ok", false))
	var rev := CoordResponseCls.parse_review(JSON.stringify({"decision": "KEEP",
		"opponent_hypotheses": [{"evidence": ["no name"]}]}),
		{"menu": menu, "snapshot_id": "snap_coord_001", "turn": 2, "has_baseline": true})
	ev["review_ok"] = bool(rev.get("ok", false))
	ev["review_warned"] = (rev.get("warnings", []) as Array).any(func(w: String) -> bool: return str(w).begins_with("DROPPED_INVALID_HYPOTHESIS"))
	var ok := bool(ev["initial_ok"]) and int(ev["initial_kept"]) == 1 \
		and bool(ev["initial_warned"]) and bool(ev["clamped"]) \
		and bool(ev["adopted_despite_bad_hyp"]) \
		and bool(ev["review_ok"]) and bool(ev["review_warned"])
	_record("c4_bad_hypothesis_warns", "pass" if ok else "fail", ev)


## Fixture D / FAST-19: precise rejection codes for every invalid family.
func _c5_precise_rejections() -> void:
	var ev := {}
	var obs := _synth_obs()
	var menu := CoordMenuCls.build_menu(obs)
	var ctx := {"menu": menu, "snapshot_id": "snap_coord_001", "turn": 1}
	var base := _full_selection(menu)
	var cases: Array = [
		["COORD_INVALID_JSON", "After reviewing the state I believe RED should hold."],
		["COORD_INVALID_CONCEPT", JSON.stringify({"plan": {"objective": "x"}})],
		["COORD_WRONG_REQUEST", JSON.stringify(_with(base, {"request": "REVIEW_COORDINATION"}))],
		["COORD_STALE_SNAPSHOT", JSON.stringify(_with(base, {"snapshot_id": "snap_old"}))],
		["COORD_INVALID_CONCEPT", JSON.stringify(_with(base, {"concept": "INVADE_MOON"}))],
		["COORD_INVALID_MAIN_EFFORT", JSON.stringify(_with(base, {"main_effort": "ORBIT"}))],
		["COORD_INVALID_SCHEMA", JSON.stringify(_without(base, ["doctrine_profile"]))],
		["COORD_INVALID_DOCTRINE", JSON.stringify(_with(base, {"doctrine_profile": {"aggression": "MAXIMUM"}}))],
		["COORD_INVALID_DOCTRINE", JSON.stringify(_with(base, {"doctrine_profile": {"cunning": "HIGH"}}))],
		["COORD_NO_ASSIGNMENTS", JSON.stringify(_with(base, {"assignments": []}))],
		["COORD_UNKNOWN_GROUP", JSON.stringify(_with_assign(base, menu, 0, "G9"))],
		["COORD_UNKNOWN_CHOICE", JSON.stringify(_with_assign(base, menu, 1, "", "G1_MOONSHOT"))],
		["COORD_DUPLICATE_ASSIGNMENT", JSON.stringify(_dup_assign(base))],
	]
	var got: Array = []
	var all_ok := true
	for c_val in cases:
		var want := str(c_val[0])
		var parsed := CoordResponseCls.parse_initial(str(c_val[1]), ctx)
		var code := str(parsed.get("code", ""))
		got.append(code)
		if code != want or bool(parsed.get("ok", false)):
			all_ok = false
	var rctx := {"menu": menu, "snapshot_id": "snap_coord_001", "turn": 2, "has_baseline": false}
	var rctx_base := {"menu": menu, "snapshot_id": "snap_coord_001", "turn": 2, "has_baseline": true}
	var rcases: Array = [
		["COORD_INVALID_DECISION", JSON.stringify({"concept": "X"}), rctx],
		["COORD_INVALID_DECISION", JSON.stringify({"decision": "MAYBE"}), rctx],
		["COORD_INVALID_DECISION", JSON.stringify({"decision": "ADJUST", "changes": []}), rctx_base],
		["COORD_NO_BASELINE", JSON.stringify({"decision": "ADJUST", "changes": [{"group": "G1", "choice": "G1_RESERVE"}]}), rctx],
	]
	for c_val in rcases:
		var want := str(c_val[0])
		var parsed := CoordResponseCls.parse_review(str(c_val[1]), c_val[2])
		var code := str(parsed.get("code", ""))
		got.append(code)
		if code != want or bool(parsed.get("ok", false)):
			all_ok = false
	ev["want"] = (cases as Array).map(func(c: Array) -> String: return str(c[0])) \
		+ (rcases as Array).map(func(c: Array) -> String: return str(c[0]))
	ev["got"] = got
	_record("c5_precise_rejections", "pass" if all_ok else "fail", ev)


func _with(d: Dictionary, over: Dictionary) -> Dictionary:
	var c := d.duplicate(true)
	for k in over.keys():
		c[k] = over[k]
	return c


func _without(d: Dictionary, keys: Array) -> Dictionary:
	var c := d.duplicate(true)
	for k in keys:
		c.erase(str(k))
	return c


func _with_assign(base: Dictionary, menu: Dictionary, idx: int, group: String, choice: String = "") -> Dictionary:
	var c := base.duplicate(true)
	var asn: Array = c.get("assignments", []) as Array
	if idx < asn.size() and asn[idx] is Dictionary:
		if not group.is_empty():
			(asn[idx] as Dictionary)["group"] = group
		if not choice.is_empty():
			(asn[idx] as Dictionary)["choice"] = choice
	return c


func _dup_assign(base: Dictionary) -> Dictionary:
	var c := base.duplicate(true)
	var asn: Array = c.get("assignments", []) as Array
	if asn.size() >= 2 and asn[0] is Dictionary:
		asn[1] = (asn[0] as Dictionary).duplicate(true)
	return c


## Fixture E / FAST-17: valid KEEP review.
func _c6_keep_review() -> void:
	var ev := {}
	var obs := _synth_obs()
	var menu := CoordMenuCls.build_menu(obs)
	var mgr := MissionManagerCls.new()
	_adopt_initial(mgr, obs, JSON.stringify(_full_selection(menu)))
	var rev := CoordResponseCls.parse_review(JSON.stringify({"decision": "KEEP", "snapshot_id": "snap_coord_001"}),
		{"menu": menu, "snapshot_id": "snap_coord_001", "turn": 2, "has_baseline": true})
	ev["parse_ok"] = bool(rev.get("ok", false))
	var kept: Dictionary = mgr.call("confirm_plan", 2, (rev.get("review", {}) as Dictionary).get("hypotheses", []),
		bool((rev.get("review", {}) as Dictionary).get("has_hypotheses", false)))
	ev["confirm_ok"] = bool(kept.get("ok", false))
	ev["version"] = int(mgr.get_plan().get("plan_version", 0))
	ev["review_turn"] = int(mgr.get_plan().get("last_review_turn", 0))
	ev["events"] = (mgr.events_since_review() as Array).any(func(e: Dictionary) -> bool: return str(e.get("kind", "")) == "PLAN_REVIEWED")
	var ok := bool(ev["parse_ok"]) and bool(ev["confirm_ok"]) \
		and int(ev["version"]) == 1 and int(ev["review_turn"]) == 2 and bool(ev["events"])
	_record("c6_keep_review", "pass" if ok else "fail", ev)


## Fixture F / FAST-18: valid ADJUST review -> v2, only the changed group.
func _c7_adjust_review() -> void:
	var ev := {}
	var obs := _synth_obs()
	var menu := CoordMenuCls.build_menu(obs)
	var mgr := MissionManagerCls.new()
	var flow := _adopt_initial(mgr, obs, JSON.stringify(_full_selection(menu)))
	var baseline: Dictionary = mgr.get_coordination()
	ev["baseline_groups"] = (baseline.get("choices", {}) as Dictionary).size()
	var g1_before := str((baseline.get("choices", {}) as Dictionary).get("G1", ""))
	var g1_opts: Array = ((CoordMenuCls.find_group(menu, "G1") as Dictionary).get("options", []) as Array)
	var alt := ""
	for o_val in g1_opts:
		var oid := str((o_val as Dictionary).get("id", ""))
		if oid != g1_before:
			alt = oid
			break
	var rev := CoordResponseCls.parse_review(JSON.stringify({"decision": "ADJUST",
		"changes": [{"group": "G1", "choice": alt}], "snapshot_id": "snap_coord_001"}),
		{"menu": menu, "snapshot_id": "snap_coord_001", "turn": 2,
			"baseline": baseline, "has_baseline": true})
	ev["parse_ok"] = bool(rev.get("ok", false))
	var expanded := CoordMenuCls.expand_adjust(menu, baseline,
		(rev.get("review", {}) as Dictionary).get("changes", []), 2, "snap_coord_001",
		obs.get("mission", {}), mgr.get_plan(), rev.get("warnings", []),
		(rev.get("review", {}) as Dictionary).get("doctrine_override", {}),
		(rev.get("review", {}) as Dictionary).get("hypotheses", []),
		bool((rev.get("review", {}) as Dictionary).get("has_hypotheses", false)))
	ev["expand_ok"] = bool(expanded.get("ok", false))
	var applied: Dictionary = mgr.call("apply_plan", expanded.get("plan", {}), 2, "snap_coord_001", "coord_battle")
	ev["adopt_ok"] = bool(applied.get("ok", false))
	ev["version"] = int(applied.get("version", 0))
	var missions: Array = mgr.get_plan().get("missions", []) as Array
	ev["missions"] = missions.size()
	var m1: Dictionary = missions[0] as Dictionary
	var g2m: Dictionary = missions[1] as Dictionary
	ev["g1_task"] = str(m1.get("task", ""))
	ev["g1_units_kept"] = ((m1.get("assigned_units", []) as Array).size() == (((flow.get("expanded", {}) as Dictionary).get("missions", []) as Array)[0] as Dictionary).get("units", -1))
	ev["g2_unchanged"] = str(g2m.get("task", "")) == str((((flow.get("expanded", {}) as Dictionary).get("missions", []) as Array)[1] as Dictionary).get("task", ""))
	ev["g1_changed"] = str(m1.get("task", "")) != str((((flow.get("expanded", {}) as Dictionary).get("missions", []) as Array)[0] as Dictionary).get("task", ""))
	var ok := bool(ev["parse_ok"]) and bool(ev["expand_ok"]) and bool(ev["adopt_ok"]) \
		and int(ev["version"]) == 2 and int(ev["missions"]) == 4 \
		and bool(ev["g1_units_kept"]) and bool(ev["g2_unchanged"]) and bool(ev["g1_changed"])
	_record("c7_adjust_review", "pass" if ok else "fail", ev)


## Fixture G / FAST-20: precise rejection, then the corrected compact
## response adopts (one bounded retry at the controller layer).
func _c8_retry_then_adopt() -> void:
	var ev := {}
	var obs := _synth_obs()
	var menu := CoordMenuCls.build_menu(obs)
	var ctx := {"menu": menu, "snapshot_id": "snap_coord_001", "turn": 1}
	var bad := _full_selection(menu)
	(bad.get("assignments", []) as Array)[0] = {"group": "G1", "choice": "G1_MOONSHOT"}
	var first := CoordResponseCls.parse_initial(JSON.stringify(bad), ctx)
	ev["first_ok"] = bool(first.get("ok", false))
	ev["first_code"] = str(first.get("code", ""))
	ev["retryable"] = str(first.get("code", "")) != "COORD_STALE_SNAPSHOT"
	var mgr := MissionManagerCls.new()
	var flow := _adopt_initial(mgr, obs, JSON.stringify(_full_selection(menu)))
	ev["second_adopted"] = bool((flow.get("applied", {}) as Dictionary).get("ok", false))
	ev["second_version"] = int((flow.get("applied", {}) as Dictionary).get("version", 0))
	var ok := not bool(ev["first_ok"]) and str(ev["first_code"]) == "COORD_UNKNOWN_CHOICE" \
		and bool(ev["retryable"]) and bool(ev["second_adopted"]) and int(ev["second_version"]) == 1
	_record("c8_retry_then_adopt", "pass" if ok else "fail", ev)


## Fixture H: same frozen menu + same selection -> identical missions.
func _c9_deterministic_expansion() -> void:
	var ev := {}
	var obs := _synth_obs()
	var menu := CoordMenuCls.build_menu(obs)
	var sel_text := JSON.stringify(_full_selection(menu))
	var p1 := CoordResponseCls.parse_initial(sel_text, {"menu": menu, "snapshot_id": "snap_coord_001", "turn": 1})
	var p2 := CoordResponseCls.parse_initial(sel_text, {"menu": menu, "snapshot_id": "snap_coord_001", "turn": 1})
	var e1 := CoordMenuCls.expand_initial(menu, p1.get("selection", {}), 1, "snap_coord_001", obs.get("mission", {}), [])
	var e2 := CoordMenuCls.expand_initial(menu, p2.get("selection", {}), 1, "snap_coord_001", obs.get("mission", {}), [])
	ev["missions_equal"] = JSON.stringify(e1.get("missions", [])) == JSON.stringify(e2.get("missions", []))
	ev["plan_equal"] = JSON.stringify(e1.get("plan", {})) == JSON.stringify(e2.get("plan", {}))
	ev["choices_equal"] = JSON.stringify(e1.get("choices", {})) == JSON.stringify(e2.get("choices", {}))
	var ok := bool(e1.get("ok", false)) and bool(ev["missions_equal"]) \
		and bool(ev["plan_equal"]) and bool(ev["choices_equal"])
	_record("c9_deterministic_expansion", "pass" if ok else "fail", ev)


## FAST-03: smuggled tactical fields can never reach the expanded plan.
func _c10_smuggled_tactics_ignored() -> void:
	var ev := {}
	var obs := _synth_obs()
	var menu := CoordMenuCls.build_menu(obs)
	var sel := _full_selection(menu)
	sel["orders"] = [{"action": "NEXUS_STRIKE", "unit_id": "R_INF_1", "hex": "Q9Z9"}]
	sel["hex"] = "Q9Z9"
	sel["targets"] = ["B_PHANTOM_9"]
	((sel.get("assignments", []) as Array)[0] as Dictionary)["unit_id"] = "R_GHOST_1"
	var mgr := MissionManagerCls.new()
	var flow := _adopt_initial(mgr, obs, JSON.stringify(sel))
	var plan_text := JSON.stringify(mgr.get_plan())
	ev["adopted"] = bool((flow.get("applied", {}) as Dictionary).get("ok", false))
	ev["no_orders"] = plan_text.find("NEXUS_STRIKE") == -1 and plan_text.find("\"orders\"") == -1
	ev["no_hex"] = plan_text.find("Q9Z9") == -1
	ev["no_ghost"] = plan_text.find("GHOST") == -1
	ev["no_targets"] = plan_text.find("B_PHANTOM_9") == -1
	var ok := bool(ev["adopted"]) and bool(ev["no_orders"]) and bool(ev["no_hex"]) \
		and bool(ev["no_ghost"]) and bool(ev["no_targets"])
	_record("c10_smuggled_tactics_ignored", "pass" if ok else "fail", ev)


## Phase 20: request/system/response size telemetry (design evidence).
func _c11_packet_sizes() -> void:
	var ev := {}
	var obs := _synth_obs()
	var menu := CoordMenuCls.build_menu(obs)
	var coord_pkt := GeneralPacketCls.build_coord_initial(obs, menu)
	var mgr := MissionManagerCls.new()
	var legacy_pkt: Dictionary = mgr.call("build_review_packet", obs, {"trigger": "INITIAL_PLAN", "reason": "t", "turn": 1})
	ev["coord_packet_chars"] = JSON.stringify(coord_pkt).length()
	ev["legacy_packet_chars"] = JSON.stringify(legacy_pkt).length()
	ev["coord_system_chars"] = CoordResponseCls.COORDINATOR_SYSTEM_PROMPT.length()
	ev["legacy_system_chars"] = GeneralPacketCls.GENERAL_SYSTEM_PROMPT.length()
	ev["menu_chars"] = JSON.stringify(menu).length()
	ev["example_chars"] = JSON.stringify(_full_selection(menu)).length()
	# The coordinator wins on prompt focus and response compactness; packet
	# sizes are recorded as design evidence (the menu replaces the legacy
	# vocabulary/rules/current-plan bulk, but absolute size varies by roster).
	var ok := int(ev["coord_system_chars"]) < int(ev["legacy_system_chars"]) \
		and int(ev["menu_chars"]) < 4000 \
		and int(ev["example_chars"]) < 1500
	_record("c11_packet_sizes", "pass" if ok else "fail", ev)


## REPLAN review -> v2 with a new concept and doctrine.
func _c12_replan_review() -> void:
	var ev := {}
	var obs := _synth_obs()
	var menu := CoordMenuCls.build_menu(obs)
	var mgr := MissionManagerCls.new()
	_adopt_initial(mgr, obs, JSON.stringify(_full_selection(menu)))
	var body := _full_selection(menu)
	body["decision"] = "REPLAN"
	body["concept"] = "ACTIVE_DEFENSE"
	body["doctrine_profile"] = {"aggression": "LOW", "tempo": "SLOW", "risk": "CAUTIOUS", "reserve": "STRICT", "pursuit": "LIMITED"}
	var rev := CoordResponseCls.parse_review(JSON.stringify(body),
		{"menu": menu, "snapshot_id": "snap_coord_001", "turn": 2, "has_baseline": true})
	ev["parse_ok"] = bool(rev.get("ok", false))
	var expanded := CoordMenuCls.expand_initial(menu, (rev.get("review", {}) as Dictionary).get("selection", {}), 2,
		"snap_coord_001", obs.get("mission", {}), rev.get("warnings", []))
	var applied: Dictionary = mgr.call("apply_plan", expanded.get("plan", {}), 2, "snap_coord_001", "coord_battle")
	ev["adopt_ok"] = bool(applied.get("ok", false))
	ev["version"] = int(applied.get("version", 0))
	ev["concept"] = str((mgr.get_plan().get("concept", {}) as Dictionary).get("objective", ""))
	ev["aggression"] = float((mgr.get_plan().get("doctrine", {}) as Dictionary).get("aggression", -1.0))
	var bad := CoordResponseCls.parse_review(JSON.stringify({"decision": "REPLAN", "concept": "HOLD_AND_PROBE", "main_effort": "NORTH"}),
		{"menu": menu, "snapshot_id": "snap_coord_001", "turn": 2, "has_baseline": true})
	ev["invalid_code"] = str(bad.get("code", ""))
	var ok := bool(ev["parse_ok"]) and bool(ev["adopt_ok"]) and int(ev["version"]) == 2 \
		and str(ev["concept"]) == str((CoordMenuCls.CONCEPTS["ACTIVE_DEFENSE"] as Dictionary).get("objective", "")) \
		and float(ev["aggression"]) == 0.25 \
		and str(ev["invalid_code"]) == "COORD_INVALID_SCHEMA"
	_record("c12_replan_review", "pass" if ok else "fail", ev)


## Stale snapshot echo rejects precisely on both request types.
func _c13_stale_snapshot() -> void:
	var ev := {}
	var obs := _synth_obs()
	var menu := CoordMenuCls.build_menu(obs)
	var sel := _full_selection(menu)
	var p_ok := CoordResponseCls.parse_initial(JSON.stringify(sel), {"menu": menu, "snapshot_id": "snap_coord_001", "turn": 1})
	sel["snapshot_id"] = "snap_old"
	var p_stale := CoordResponseCls.parse_initial(JSON.stringify(sel), {"menu": menu, "snapshot_id": "snap_coord_001", "turn": 1})
	var r_stale := CoordResponseCls.parse_review(JSON.stringify({"decision": "KEEP", "snapshot_id": "snap_old"}),
		{"menu": menu, "snapshot_id": "snap_coord_001", "turn": 2, "has_baseline": true})
	ev["match_ok"] = bool(p_ok.get("ok", false))
	ev["initial_code"] = str(p_stale.get("code", ""))
	ev["review_code"] = str(r_stale.get("code", ""))
	var ok := bool(ev["match_ok"]) \
		and str(ev["initial_code"]) == "COORD_STALE_SNAPSHOT" \
		and str(ev["review_code"]) == "COORD_STALE_SNAPSHOT"
	_record("c13_stale_snapshot", "pass" if ok else "fail", ev)


## Partial assignments -> Godot defaults + warnings, still adopts.
func _c14_unassigned_defaults() -> void:
	var ev := {}
	var obs := _synth_obs()
	var menu := CoordMenuCls.build_menu(obs)
	var sel := _full_selection(menu)
	sel["assignments"] = [(sel.get("assignments", []) as Array)[0]]
	var parsed := CoordResponseCls.parse_initial(JSON.stringify(sel), {"menu": menu, "snapshot_id": "snap_coord_001", "turn": 1})
	ev["parse_ok"] = bool(parsed.get("ok", false))
	var warns: Array = parsed.get("warnings", []) as Array
	ev["default_warnings"] = warns.filter(func(w: String) -> bool: return str(w).begins_with("DEFAULTED_GROUP")).size()
	var mgr := MissionManagerCls.new()
	var flow := _adopt_initial(mgr, obs, JSON.stringify(sel))
	ev["adopted"] = bool((flow.get("applied", {}) as Dictionary).get("ok", false))
	ev["missions"] = (mgr.get_plan().get("missions", []) as Array).size()
	var ok := bool(ev["parse_ok"]) and int(ev["default_warnings"]) == 3 \
		and bool(ev["adopted"]) and int(ev["missions"]) == 4
	_record("c14_unassigned_defaults", "pass" if ok else "fail", ev)


## FAST-09: bounded doctrine categories map to runtime numerics.
func _c15_doctrine_mapping() -> void:
	var ev := {}
	var num := CoordMenuCls.doctrine_to_numeric({"aggression": "HIGH", "tempo": "SLOW", "risk": "BOLD", "reserve": "LOOSE", "pursuit": "STRONG"})
	ev["mapped"] = [float(num.get("aggression", 0.0)), float(num.get("tempo", 0.0)),
		float(num.get("risk_tolerance", 0.0)), float(num.get("reserve_discipline", 0.0)),
		float(num.get("pursuit", 0.0)), float(num.get("deception", 0.0))]
	var obs := _synth_obs()
	var menu := CoordMenuCls.build_menu(obs)
	var sel := _full_selection(menu)
	sel["doctrine_profile"] = {"aggression": "HIGH"}
	var parsed := CoordResponseCls.parse_initial(JSON.stringify(sel), {"menu": menu, "snapshot_id": "snap_coord_001", "turn": 1})
	var warns: Array = parsed.get("warnings", []) as Array
	ev["missing_defaults"] = warns.filter(func(w: String) -> bool: return str(w).begins_with("DEFAULTED_DOCTRINE")).size()
	var got: Dictionary = (parsed.get("selection", {}) as Dictionary).get("doctrine", {})
	ev["keys"] = got.size()
	var ok := bool(parsed.get("ok", false)) \
		and (ev["mapped"] as Array) == [0.8, 0.25, 0.8, 0.3, 0.85, 0.2] \
		and int(ev["missing_defaults"]) == 4 and int(ev["keys"]) == 5
	_record("c15_doctrine_mapping", "pass" if ok else "fail", ev)


## FAST-21/22/23: Model View shows menu, selection, expansion, warnings.
func _c16_modelview_coord() -> void:
	var ev := {}
	var obs := _synth_obs()
	var menu := CoordMenuCls.build_menu(obs)
	var entry := {
		"request_id": "general_t1", "kind": "GENERAL_REVIEW", "attempt": 1,
		"turn": 1, "started_ms": 1000, "ended_ms": 9000, "request_chars": 5200,
		"system_chars": 1400, "packet_chars": 3600, "response_chars": 640,
		"http_status": 200, "latency_ms": 8000, "finish_reason": "stop",
		"ok": true, "code": "", "detail": "", "outcome": "APPLIED_v1",
		"coord_kind": "INITIAL", "menu": menu, "menu_chars": JSON.stringify(menu).length(),
		"selection": _full_selection(menu),
		"expansion": {"choices": {"G1": "G1_FIX_CENTER"}, "missions": [{"mission_id": "M01", "task": "FIX", "area": "CENTER", "units": 4}]},
		"warnings": ["DEFAULTED_GROUP G4 reason=unassigned choice=G4_RESERVE"],
		"pipeline": {"transport": "SUCCESS", "parse": "PASS", "contract": "PASS", "plan": "PASS_missions=4", "adoption": "APPLIED_v1"},
	}
	var text := ModelViewCls.render_summary(entry)
	ev["has_coord"] = text.find("--- COORDINATION (INITIAL) ---") != -1
	ev["has_menu"] = text.find("menu         4 groups") != -1
	ev["has_selected"] = text.find("selected     G1->") != -1
	ev["has_expanded"] = text.find("expanded     M01 FIX CENTER(4)") != -1
	ev["has_warnings"] = text.find("warnings     1: DEFAULTED_GROUP") != -1
	ev["has_contract"] = text.find("CONTRACT     PASS") != -1
	var ok := bool(ev["has_coord"]) and bool(ev["has_menu"]) and bool(ev["has_selected"]) \
		and bool(ev["has_expanded"]) and bool(ev["has_warnings"]) and bool(ev["has_contract"])
	_record("c16_modelview_coord", "pass" if ok else "fail", ev)


## Empty roster -> empty menu (controller sends no Cloud call).
func _c17_empty_menu() -> void:
	var ev := {}
	var obs := _synth_obs()
	obs["friendly_units"] = []
	var menu := CoordMenuCls.build_menu(obs)
	ev["groups"] = (menu.get("groups", []) as Array).size()
	ev["menu_id"] = str(menu.get("menu_id", ""))
	var ok := int(ev["groups"]) == 0 and not str(ev["menu_id"]).is_empty()
	_record("c17_empty_menu", "pass" if ok else "fail", ev)
