extends SceneTree

## GX MISSIONS v1 — minimal tests 1 + 2 (deterministic, isolated fixtures, no maps).
##   1. MissionRules terminal conditions + evaluation order.
##   2. BUILD_BASE legality (HQ only, own hex, refused after moving, HQ may move after building) + destroy-only.
## godot --headless --path <proj> -s res://tools/gx_missions_dev/test_mission_rules.gd

const HarnessCls = preload("res://tools/gx_missions_dev/gx_missions_harness.gd")
const RulesCls = preload("res://scripts/gx_missions/mission_rules.gd")
const SandboxRulesCls = preload("res://scripts/core/sandbox_rules.gd")
const CombatCls = preload("res://scripts/combat/combat_calculator.gd")

var h: Node
var results: Array = []


func _initialize() -> void:
	call_deferred("_run")


func _check(name: String, ok: bool, detail: Variant = "") -> void:
	results.append({"test": name, "pass": ok, "detail": detail})
	print("[GxMissionsTest] %s %s %s" % ["PASS" if ok else "FAIL", name, JSON.stringify(detail)])


## Fresh MissionRules on the current board (start soldiers = the board now). Old ones are freed.
func _rules(mission: Dictionary) -> Node:
	var old: Node = h.get("rules")
	if old != null and is_instance_valid(old):
		old.queue_free()
	var r: Node = RulesCls.new()
	r.set("drive_shell_terminal", false)
	h.add_child(r)
	var res: Dictionary = r.call("setup", h.get("shell"), mission)
	if not bool(res.get("ok", false)):
		push_error("rules setup failed: " + str(res))
	h.set("rules", r)
	return r


func _reset_board() -> void:
	var shell: Node = h.get("shell")
	shell.set("_battle_won", false)
	shell.set("_battle_lost", false)
	h.set("fixture", {"layout": "default_10v10"})
	h.call("apply_layout")


func _mgr() -> RefCounted:
	return h.get("manager")


func _set_side_soldiers(side: String, total: int) -> void:
	var units: Array = []
	for u in _mgr().call("get_all_units_including_garrisoned"):
		if str(u.get("faction", "")) == side:
			units.append(u)
	var each := total / units.size()
	var rest := total - each * units.size()
	for i in range(units.size()):
		var u: Dictionary = (_mgr().get("_units") as Dictionary)[str(units[i]["id"])]
		u["soldier_count"] = each + (rest if i == 0 else 0)


func _mission(fam: String, extra: Dictionary = {}) -> Dictionary:
	var m := {"mission_id": "T_" + fam, "family": fam, "round_limit": 30, "collapse_frac": 0.30, "morale": false}
	if fam in ["M1", "M2", "M5"]:
		m["roles"] = {"red": "attacker", "blue": "defender"}
	m.merge(extra, true)
	return m


func _run() -> void:
	h = HarnessCls.new()
	root.add_child(h)
	current_scene = h
	var booted: Dictionary = await h.call("boot", HarnessCls.load_fixture("M3"), {"blue_profile": "GX_ADV_SPEARHEAD", "red_profile": "GX_ADV_SPEARHEAD"})
	if not bool(booted.get("ok", false)):
		_check("boot", false, booted)
		_finish()
		return
	_test_collapse()
	_test_order()
	_test_hq()
	_test_supply_cut()
	_test_supply_cancel()
	_test_village()
	_test_sites()
	_test_stronghold()
	_test_round_limit()
	_test_morale_switch()
	await _test_build_base()
	_finish()


# ---------------- 1. MissionRules ----------------

func _test_collapse() -> void:
	_reset_board()
	var r := _rules(_mission("M3"))
	var line := int(r.call("collapse_line", "red"))
	_set_side_soldiers("red", line + 1)
	var o1: Dictionary = r.call("evaluate_round", 1)
	_set_side_soldiers("red", line)
	var o2: Dictionary = r.call("evaluate_round", 2)
	_check("collapse_exactly_30pct", o1.is_empty() and str(o2.get("winner", "")) == "blue" and str(o2.get("reason", "")) == "collapse_red",
		{"start": r.get("start_soldiers"), "line": line, "above_line": o1, "at_line": o2})


func _test_order() -> void:
	# collapse beats supply cut beats mission; HQ beats collapse.
	_reset_board()
	var r := _rules(_mission("M1", {"village_hexes": [[0, 0]]}))
	# Blue base + HQ moved off it + red scout on the line: blue supply cut from round 1 (expires at round 16).
	r.call("build_base", "B_HQ_1")
	r.call("build_base", "R_HQ_1")
	h.call("place_unit", "B_HQ_1", Vector2i(-20, 4))
	h.call("place_unit", "R_SCT_1", Vector2i(-20, 2))
	for rnd in range(1, 16):
		r.call("evaluate_round", rnd)
	_set_side_soldiers("red", int(r.call("collapse_line", "red")))  # collapse fires in the same round 16
	var o: Dictionary = r.call("evaluate_round", 16)
	_check("order_collapse_before_supply", str(o.get("reason", "")) == "collapse_red", o)
	_reset_board()
	r = _rules(_mission("M1", {"village_hexes": [[0, 0], [1, 0]]}))
	r.call("build_base", "B_HQ_1")
	r.call("build_base", "R_HQ_1")
	h.call("place_unit", "B_HQ_1", Vector2i(-20, 4))
	h.call("place_unit", "R_SCT_1", Vector2i(-20, 2))
	for rnd in range(1, 15):
		r.call("evaluate_round", rnd)
	# Village held from round 15 -> held 2 rounds at round 16, the same round blue's supply countdown expires.
	h.call("place_unit", "R_INF_1", Vector2i(0, 0))
	h.call("place_unit", "R_INF_2", Vector2i(1, 0))
	var o15: Dictionary = r.call("evaluate_round", 15)
	var hit: Dictionary = r.call("evaluate_round", 16)
	_check("order_supply_before_mission", o15.is_empty() and str(hit.get("reason", "")) == "supply_cut_blue", hit)
	_reset_board()
	r = _rules(_mission("M3"))
	_set_side_soldiers("red", int(r.call("collapse_line", "red")))
	_mgr().call("destroy_unit", "R_HQ_1")
	var o3: Dictionary = r.get("outcome")
	_check("order_hq_first", str(o3.get("reason", "")) == "hq_destroyed" and str(o3.get("winner", "")) == "blue", o3)


func _test_hq() -> void:
	_reset_board()
	var r := _rules(_mission("M3"))
	_mgr().call("destroy_unit", "B_HQ_1")
	var o: Dictionary = r.call("evaluate_round", 1)
	_check("hq_sudden_death", str(o.get("winner", "")) == "red" and str(o.get("reason", "")) == "hq_destroyed", o)


func _supply_setup() -> Node:
	_reset_board()
	var r := _rules(_mission("M3"))
	for s in ["red", "blue"]:
		r.call("build_base", str((r.call("hq_of", s) as Dictionary)["id"]))
	h.call("place_unit", "B_HQ_1", Vector2i(-20, 4))  # line (-20,4) -> base (-20,0)
	return r


func _test_supply_cut() -> void:
	var r := _supply_setup()
	h.call("place_unit", "R_SCT_1", Vector2i(-20, 2))
	var first_loss := -1
	for rnd in range(1, 30):
		var o: Dictionary = r.call("evaluate_round", rnd)
		if not o.is_empty():
			first_loss = rnd if str(o.get("reason", "")) == "supply_cut_blue" else -100
			break
	_check("supply_cut_15_turns", first_loss == 16, {"cut_observed_round": 1, "loss_round": first_loss,
		"supply_turns": int((r.get("rules_cfg") as Dictionary)["supply_cut_turns"])})


func _test_supply_cancel() -> void:
	var r := _supply_setup()
	h.call("place_unit", "R_SCT_1", Vector2i(-20, 2))
	var early: Dictionary = {}
	for rnd in range(1, 11):
		early = r.call("evaluate_round", rnd)
	h.call("place_unit", "R_SCT_1", Vector2i(-12, -7))  # reconnect at round 11
	var mid: Dictionary = r.call("evaluate_round", 11)
	var cancelled := not bool((((r.get("mission_state") as Dictionary)["supply"] as Dictionary)["blue"] as Dictionary)["countdown_active"])
	h.call("place_unit", "R_SCT_1", Vector2i(-20, 2))  # cut again at round 12
	var loss := -1
	for rnd in range(12, 30):
		var o: Dictionary = r.call("evaluate_round", rnd)
		if not o.is_empty():
			loss = rnd
			break
	_check("supply_reconnect_cancels", early.is_empty() and mid.is_empty() and cancelled and loss == 27,
		{"cancelled_at": 11, "recut_at": 12, "loss_round": loss})


func _test_village() -> void:
	_reset_board()
	var r := _rules(_mission("M1", {"village_hexes": [[0, 0], [1, 0], [0, 1]]}))
	for s in ["red", "blue"]:
		r.call("build_base", str((r.call("hq_of", s) as Dictionary)["id"]))
	h.call("place_unit", "R_INF_1", Vector2i(0, 0))
	h.call("place_unit", "R_INF_2", Vector2i(1, 0))
	h.call("place_unit", "B_INF_1", Vector2i(0, 1))
	var contested: Dictionary = r.call("evaluate_round", 1)
	var o2: Dictionary = r.call("evaluate_round", 2)
	h.call("place_unit", "B_INF_1", Vector2i(-17, -5))
	var o3: Dictionary = r.call("evaluate_round", 3)
	var o4: Dictionary = r.call("evaluate_round", 4)
	_check("village_hold", contested.is_empty() and o2.is_empty() and o3.is_empty() \
		and str(o4.get("reason", "")) == "village_occupied" and str(o4.get("winner", "")) == "red",
		{"hold_needed": int((r.get("rules_cfg") as Dictionary)["m1_area_hold"]), "won_round": o4.get("round", -1)})


func _sites_rules() -> Node:
	_reset_board()
	var r := _rules(_mission("M4", {"site_hexes": [[0, -6], [0, 0], [0, 6]]}))
	for s in ["red", "blue"]:
		r.call("build_base", str((r.call("hq_of", s) as Dictionary)["id"]))
	return r


func _put_base(r: Node, owner: String, hex: Vector2i) -> void:
	var b: Dictionary = r.get("bases")
	b["T_%s_%d_%d" % [owner, hex.x, hex.y]] = {"id": "T_%s_%d_%d" % [owner, hex.x, hex.y], "owner": owner, "hex": hex, "built_round": 0}


func _test_sites() -> void:
	var r := _sites_rules()
	for hx in [Vector2i(0, -6), Vector2i(0, 0), Vector2i(0, 6)]:
		_put_base(r, "blue", hx)
	var seq: Array = []
	for rnd in range(1, 4):
		seq.append(r.call("evaluate_round", rnd))
	_check("sites_full_hold_3_rounds", (seq[0] as Dictionary).is_empty() and (seq[1] as Dictionary).is_empty() \
		and str(seq[2].get("reason", "")) == "sites_full_hold" and str(seq[2].get("winner", "")) == "blue", seq[2])
	r = _sites_rules()
	_put_base(r, "blue", Vector2i(0, -6))
	_put_base(r, "blue", Vector2i(0, 0))
	_put_base(r, "red", Vector2i(0, 6))
	var before: Dictionary = r.call("evaluate_round", 29)
	var at_limit: Dictionary = r.call("evaluate_round", 30)
	_check("sites_2_of_3_at_limit", before.is_empty() and str(at_limit.get("reason", "")) == "sites_majority_at_limit" \
		and str(at_limit.get("winner", "")) == "blue", at_limit)


func _test_stronghold() -> void:
	_reset_board()
	h.call("place_unit", "B_INF_2", Vector2i(-13, 0))
	var r := _rules(_mission("M2", {"stronghold_id": "T_FORT", "stronghold": {"footprint": [[-12, 0], [-11, 0], [-12, 1]],
		"hp": 1000, "slots": 4, "owner": "blue", "garrison": ["B_INF_2"]}}))
	for s in ["red", "blue"]:
		r.call("build_base", str((r.call("hq_of", s) as Dictionary)["id"]))
	var sh: Variant = r.call("stronghold")
	var intact: Dictionary = r.call("evaluate_round", 1)
	sh.fortification_hp = 0
	sh.breached = true
	var garrisoned: Dictionary = r.call("evaluate_round", 2)
	sh.deploy_garrison_unit("B_INF_2")  # garrison emptied
	_mgr().get("_garrisoned").erase("B_INF_2")
	var o: Dictionary = r.call("evaluate_round", 3)
	_check("stronghold_capture", intact.is_empty() and garrisoned.is_empty() and str(o.get("reason", "")) == "stronghold_captured" \
		and str(o.get("winner", "")) == "red" and str(sh.owner) == "red", o)


func _test_round_limit() -> void:
	_reset_board()
	var r := _rules(_mission("M1", {"village_hexes": [[0, 0]], "round_limit": 5}))
	for s in ["red", "blue"]:
		r.call("build_base", str((r.call("hq_of", s) as Dictionary)["id"]))
	var o: Dictionary = {}
	for rnd in range(1, 6):
		o = r.call("evaluate_round", rnd)
	var r2 := _rules(_mission("M3", {"round_limit": 5}))
	for s in ["red", "blue"]:
		r2.call("build_base", str((r2.call("hq_of", s) as Dictionary)["id"]))
	var o2: Dictionary = {}
	for rnd in range(1, 6):
		o2 = r2.call("evaluate_round", rnd)
	_check("round_limit", str(o.get("winner", "")) == "blue" and str(o.get("reason", "")) == "round_limit_defender_holds" \
		and str(o2.get("reason", "")) == "round_limit_stalemate", {"M1": o, "M3": o2})


func _test_morale_switch() -> void:
	_reset_board()
	_rules(_mission("M3", {"morale": true}))
	var on_mod := CombatCls.get_morale_modifier(50.0)
	var on := SandboxRulesCls.morale_rout_enabled()
	_rules(_mission("M3", {"morale": false}))
	var off_mod := CombatCls.get_morale_modifier(50.0)
	var off := SandboxRulesCls.morale_rout_enabled()
	_check("morale_switch_per_mission", on and not off and is_equal_approx(on_mod, 0.7) and is_equal_approx(off_mod, 1.0),
		{"on_modifier_at_50": on_mod, "off_modifier_at_50": off_mod})


# ---------------- 2. BUILD_BASE ----------------

func _cands(ctl: Node, uid: String) -> Array:
	return (ctl.get("enumerator").call("enumerate_for_unit", uid) as Dictionary).get("candidates", [])


func _find(cands: Array, kind: String) -> Dictionary:
	for c in cands:
		if str(c.get("action_type", "")) == kind:
			return c
	return {}


func _test_build_base() -> void:
	_reset_board()
	var r := _rules(_mission("M3"))
	var ctl: Node = h.get("blue_ctl")
	ctl.set("mission_rules", r)
	ctl.get("enumerator").set("mission_rules", r)
	var hq_c := _cands(ctl, "B_HQ_1")
	var inf_c := _cands(ctl, "B_INF_1")
	var bb := _find(hq_c, "BUILD_BASE")
	_check("build_base_hq_only", not bb.is_empty() and _find(inf_c, "BUILD_BASE").is_empty() \
		and str((r.call("build_base", "B_INF_1") as Dictionary).get("code", "")) == "NOT_HQ", {"hq_offer": bb})
	_check("build_base_own_hex", not bb.is_empty() and bb["hex"] == [-20, 0], bb.get("hex", null))
	# Refused after moving.
	var mv := _find(hq_c, "MOVE")
	var moved: Dictionary = await ctl.call("_execute_fresh", mv)
	var after_move := _find(_cands(ctl, "B_HQ_1"), "BUILD_BASE")
	var refuse: Dictionary = r.call("build_base", "B_HQ_1")
	_check("build_base_refused_after_move", bool(moved.get("success", false)) and after_move.is_empty() \
		and str(refuse.get("code", "")) == "HQ_MOVED_THIS_TURN", {"move": mv.get("destination", []), "code": refuse.get("code", "")})
	# Next turn: build, then the HQ may still move.
	_mgr().call("end_turn")
	var bb2 := _find(_cands(ctl, "B_HQ_1"), "BUILD_BASE")
	var built: Dictionary = await ctl.call("_execute_fresh", bb2)
	var post := _cands(ctl, "B_HQ_1")
	var mv2 := _find(post, "MOVE")
	var moved2: Dictionary = {}
	if not mv2.is_empty():
		moved2 = await ctl.call("_execute_fresh", mv2)
	_check("build_base_then_move", bool(built.get("success", false)) and _find(post, "BUILD_BASE").is_empty() \
		and bool(moved2.get("success", false)), {"base": built.get("base_id", ""), "moved_to": mv2.get("destination", [])})
	# Destroy-only: an enemy unit entering the base hex destroys it; it never changes owner.
	var bhex: Array = built.get("hex", [0, 0])
	h.call("place_unit", "R_SCT_1", Vector2i(int(bhex[0]), int(bhex[1])))
	r.call("evaluate_round", 2)
	var remaining: Array = (r.get("mission_state") as Dictionary)["bases"]
	var captured := false
	for b in remaining:
		if b["hex"] == bhex:
			captured = true
	var destroyed_evt := false
	for e in (r.get("events") as Array):
		if str(e.get("type", "")) == "base_destroyed" and str(e.get("base_id", "")) == str(built.get("base_id", "")):
			destroyed_evt = true
	_check("base_destroy_only", destroyed_evt and not captured, {"bases_after": remaining})


func _finish() -> void:
	var ok := true
	for r in results:
		ok = ok and bool(r["pass"])
	var out := {"suite": "gx_missions_rules_build_base", "pass": ok, "results": results}
	var dir := ProjectSettings.globalize_path("res://artifacts/gx_missions_dev")
	DirAccess.make_dir_recursive_absolute(dir)
	var f := FileAccess.open(dir + "/test_mission_rules.json", FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(out, "  ", true))
		f.close()
	print("[GxMissionsTest] SUITE %s" % ("PASS" if ok else "FAIL"))
	quit(0 if ok else 1)
