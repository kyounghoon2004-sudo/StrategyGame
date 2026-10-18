extends SceneTree

## GX MISSIONS v1 — minimal tests 1 + 2 (deterministic, isolated fixtures, no maps).
##   1. MissionRules terminal conditions + evaluation order.
##   2. BUILD_BASE legality (HQ only, own hex, refused after moving, HQ may move after building) + destroy-only.
## godot --headless --path <proj> -s res://tools/gx_missions_dev/test_mission_rules.gd

const HarnessCls = preload("res://tools/gx_missions_dev/gx_missions_harness.gd")
const HexUtilsCls = preload("res://scripts/core/hex_utils.gd")
const RulesCls = preload("res://scripts/gx_missions/mission_rules.gd")
const SandboxRulesCls = preload("res://scripts/core/sandbox_rules.gd")
const CombatCls = preload("res://scripts/combat/combat_calculator.gd")
const Step6Cls = preload("res://scripts/step6/step6_decision_layer.gd")

const EXPECTED_CHECKS := 23

var h: Node
var results: Array = []


func _initialize() -> void:
	call_deferred("_run")


func _check(name: String, ok: bool, detail: Variant = "") -> void:
	results.append({"test": name, "pass": ok, "detail": detail})
	print("[GxMissionsTest] %s %s %s" % ["PASS" if ok else "FAIL", name, JSON.stringify(detail)])


## Fresh MissionRules on the current board (start soldiers = the board now). Old ones are freed.
func _rules(mission: Dictionary) -> Node:
	var old: Variant = h.get("rules")
	if is_instance_valid(old):
		(old as Node).queue_free()
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
		if str(u.get("faction", "")) == side and str(u.get("class", "")) != "hq":  # collapse counts the field army
			units.append(u)
	var each := total / units.size()
	var rest := total - each * units.size()
	for i in range(units.size()):
		var u: Dictionary = (_mgr().get("_units") as Dictionary)[str(units[i]["id"])]
		u["soldier_count"] = each + (rest if i == 0 else 0)


func _mission(fam: String, extra: Dictionary = {}) -> Dictionary:
	# map_diameter 40 = the half-size preset for these fixtures: link range R = 10, morale 5 / 10, build cooldown 11.
	var m := {"mission_id": "T_" + fam, "family": fam, "round_limit": 30, "collapse_frac": 0.30, "morale": false, "map_diameter": 40}
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
	_test_supply_network()
	_test_village()
	_test_sites()
	_test_stronghold()
	_test_round_limit()
	_test_morale_switch()
	_test_morale_zones()
	_test_rout_blocked()
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
	# HQ soldiers never count: a side whose field army is gone collapses even with a full-strength HQ.
	_reset_board()
	var r2 := _rules(_mission("M3"))
	var hq_full := int((r2.call("hq_of", "red") as Dictionary).get("soldier_count", 0))
	_set_side_soldiers("red", 0)
	var o3: Dictionary = r2.call("evaluate_round", 1)
	_check("collapse_ignores_hq", hq_full > 0 and str(o3.get("reason", "")) == "collapse_red", {"red_hq": hq_full, "out": o3})


func _test_order() -> void:
	# collapse beats supply cut beats mission; HQ beats collapse.
	var r := _supply_setup(_mission("M1", {"village_hexes": [[0, 0]]}))
	_kill_base(r, "blue")  # blue supply cut from round 1 (expires at round 16)
	for rnd in range(1, 16):
		r.call("evaluate_round", rnd)
	_set_side_soldiers("red", int(r.call("collapse_line", "red")))  # collapse fires in the same round 16
	var o: Dictionary = r.call("evaluate_round", 16)
	_check("order_collapse_before_supply", str(o.get("reason", "")) == "collapse_red", o)
	r = _supply_setup(_mission("M1", {"village_hexes": [[0, 0], [1, 0]]}))
	_kill_base(r, "blue")
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


## Supply fixture (R = 10): each side's head 15 hexes straight behind its HQ (the board's own heads sit ~20 back),
## one base 7 from the head / 8 from the HQ -> both sides supplied through that base only.
const SUPPLY_HEAD_BACK := 15
const SUPPLY_BASE_BACK := 8


func _rear(side: String) -> Vector2i:
	return Vector2i(-1, 0) if side == "blue" else Vector2i(1, 0)


func _hq_hex(r: Node, side: String) -> Vector2i:
	var hq: Dictionary = r.call("hq_of", side)
	return Vector2i(int(hq["q"]), int(hq["r"]))


## Build a base for `side` at `hex` with the real executor (HQ teleported there and back, cooldown reset).
func _build_at(r: Node, side: String, hex: Vector2i) -> String:
	var hq: Dictionary = r.call("hq_of", side)
	var home := Vector2i(int(hq["q"]), int(hq["r"]))
	h.call("place_unit", str(hq["id"]), hex)
	(r.get("_last_build_round") as Dictionary)[side] = -1000
	var res: Dictionary = r.call("build_base", str(hq["id"]))
	h.call("place_unit", str(hq["id"]), home)
	return str(res.get("base_id", ""))


func _supply_setup(mission: Dictionary = {}) -> Node:
	_reset_board()
	var r := _rules(mission if not mission.is_empty() else _mission("M3"))
	for s in ["red", "blue"]:
		var hq := _hq_hex(r, s)
		(r.get("heads") as Dictionary)[s] = hq + _rear(s) * SUPPLY_HEAD_BACK
		_build_at(r, s, hq + _rear(s) * SUPPLY_BASE_BACK)
	return r


func _kill_base(r: Node, side: String) -> void:
	for b in r.call("bases_of", side):
		r.call("_destroy_base", str(b["id"]), "test")


func _test_supply_cut() -> void:
	var r := _supply_setup()
	var was := bool((r.call("supply_status", "blue") as Dictionary)["connected"])
	_kill_base(r, "blue")  # cut from round 1
	var first_loss := -1
	for rnd in range(1, 30):
		var o: Dictionary = r.call("evaluate_round", rnd)
		if not o.is_empty():
			first_loss = rnd if str(o.get("reason", "")) == "supply_cut_blue" else -100
			break
	_check("supply_cut_15_turns", was and first_loss == 16, {"connected_before": was, "cut_observed_round": 1,
		"loss_round": first_loss, "supply_turns": int((r.get("rules_cfg") as Dictionary)["supply_cut_turns"])})


func _test_supply_cancel() -> void:
	var r := _supply_setup()
	_kill_base(r, "blue")  # cut from round 1
	var early: Dictionary = {}
	for rnd in range(1, 11):
		early = r.call("evaluate_round", rnd)
	var rebuilt := _build_at(r, "blue", _hq_hex(r, "blue") + _rear("blue") * SUPPLY_BASE_BACK)  # reconnect at round 11
	var mid: Dictionary = r.call("evaluate_round", 11)
	var cancelled := not bool((((r.get("mission_state") as Dictionary)["supply"] as Dictionary)["blue"] as Dictionary)["countdown_active"])
	_kill_base(r, "blue")  # cut again at round 12
	var loss := -1
	for rnd in range(12, 30):
		var o: Dictionary = r.call("evaluate_round", rnd)
		if not o.is_empty():
			loss = rnd
			break
	_check("supply_reconnect_cancels", rebuilt != "" and early.is_empty() and mid.is_empty() and cancelled and loss == 27,
		{"cancelled_at": 11, "recut_at": 12, "loss_round": loss})


## Mesh network: nodes link within supply_link_range (path length); the HQ is supplied only through nodes
## linked to the head; an isolated base does not count; a destroyed base drops out and the rest re-link;
## an enemy on the line never cuts it.
func _test_supply_network() -> void:
	_reset_board()
	var r := _rules(_mission("M3"))
	var hq := _hq_hex(r, "blue")
	var back := _rear("blue")
	(r.get("heads") as Dictionary)["blue"] = hq + back * 20
	var none_st: Dictionary = r.call("supply_status", "blue")  # head 20 behind, no base -> cut
	var lone := _build_at(r, "blue", hq + back * 4)  # 16 from the head -> isolated, HQ still cut
	var lone_st: Dictionary = r.call("supply_status", "blue")
	var mid := _build_at(r, "blue", hq + back * 12)  # head 8 -> mid -> 8 -> lone -> 4 -> HQ
	var chain_st: Dictionary = r.call("supply_status", "blue")
	var net: Dictionary = r.call("supply_net", "blue")
	var live := 0
	for n in (net["nodes"] as Array):
		live += 1 if bool(n["live"]) else 0
	var extra := _build_at(r, "blue", hq + back * 13 + Vector2i(0, 1))  # a second path head -8- extra -9- lone (mesh)
	r.call("_destroy_base", mid, "test")
	var relink_st: Dictionary = r.call("supply_status", "blue")
	h.call("place_unit", "R_SCT_1", hq + back)  # enemy on the line: never cuts
	var foe_st: Dictionary = r.call("supply_status", "blue")
	_check("supply_network", not bool(none_st["connected"]) and str(none_st["reason"]) == "out_of_range" \
		and not bool(lone_st["connected"]) and bool(chain_st["connected"]) and live == 3 and extra != "" \
		and bool(relink_st["connected"]) and bool(foe_st["connected"]) and (foe_st["cut_hexes"] as Array).is_empty(),
		{"none": none_st["reason"], "lone": lone_st["connected"], "chain": chain_st["connected"], "live_nodes": live,
		"relink_after_mid_destroyed": relink_st["connected"], "foe_on_line": foe_st["connected"]})


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


func _blue_field_ids(n: int) -> Array:
	var out: Array = []
	for u in _mgr().call("get_all_units"):
		if str(u.get("faction", "")) == "blue" and str(u.get("class", "")) != "hq" \
				and int(u.get("soldier_count", 0)) > 0 and not bool(u.get("garrisoned", false)):
			out.append(str(u.get("id", "")))
			if out.size() >= n:
				break
	return out


func _set_morale(uid: String, v: float) -> void:
	_mgr().call("s6_set_field", uid, "morale", v)


func _morale_of(uid: String) -> float:
	return float((_mgr().call("get_unit_by_id", uid) as Dictionary).get("morale", 100.0))


func _m3_morale_rules() -> Node:
	return _supply_setup(_mission("M3", {"morale": true}))  # both sides supplied


func _test_morale_zones() -> void:
	# A. Near recovers +5/+7/+9/+11/+11, mid holds, far loses 5/round; zones published.
	var r := _m3_morale_rules()
	var ids := _blue_field_ids(3)
	var near := str(ids[0])
	var mid := str(ids[1])
	var far := str(ids[2])
	h.call("place_unit", near, Vector2i(-19, 0))
	h.call("place_unit", mid, Vector2i(-13, 0))
	h.call("place_unit", far, Vector2i(-8, 0))
	_set_morale(near, 50.0)
	_set_morale(mid, 50.0)
	_set_morale(far, 50.0)
	var seq: Array = []
	for rnd in range(1, 6):
		r.call("evaluate_round", rnd)
		seq.append([_morale_of(near), _morale_of(mid), _morale_of(far)])
	var mz: Dictionary = ((r.get("mission_state") as Dictionary).get("morale_zones", {}) as Dictionary).get("blue", {})
	var exp := [[55.0, 50.0, 45.0], [62.0, 50.0, 40.0], [71.0, 50.0, 35.0], [82.0, 50.0, 30.0], [93.0, 50.0, 25.0]]
	var ok_a := (mz.get(near, {}) as Dictionary) == {"zone": 1, "rounds": 5} \
		and (mz.get(mid, {}) as Dictionary) == {"zone": 2, "rounds": 0} \
		and (mz.get(far, {}) as Dictionary) == {"zone": 3, "rounds": 5}
	for i in range(5):
		for j in range(3):
			ok_a = ok_a and is_equal_approx(float((seq[i] as Array)[j]), float((exp[i] as Array)[j]))
	# B. Clamp 0/100; the HQ itself is excluded.
	r = _m3_morale_rules()
	ids = _blue_field_ids(2)
	near = str(ids[0])
	far = str(ids[1])
	h.call("place_unit", near, Vector2i(-19, 0))
	h.call("place_unit", far, Vector2i(-8, 0))
	_set_morale(near, 98.0)
	_set_morale(far, 3.0)
	_set_morale("B_HQ_1", 50.0)
	r.call("evaluate_round", 1)
	var mz2: Dictionary = ((r.get("mission_state") as Dictionary).get("morale_zones", {}) as Dictionary).get("blue", {})
	var b_hi := _morale_of(near)
	var b_lo := _morale_of(far)
	var b_hq := _morale_of("B_HQ_1")
	var ok_b := is_equal_approx(b_hi, 100.0) and is_equal_approx(b_lo, 0.0) \
		and is_equal_approx(b_hq, 50.0) and not mz2.has("B_HQ_1")
	# C. Unsupplied (no base, head ~20 back) the near zone does not recover; far still loses.
	_reset_board()
	r = _rules(_mission("M3", {"morale": true}))
	r.call("build_base", "R_HQ_1")  # red connected; blue has no base
	ids = _blue_field_ids(2)
	near = str(ids[0])
	far = str(ids[1])
	h.call("place_unit", near, Vector2i(-19, 0))
	h.call("place_unit", far, Vector2i(-8, 0))
	_set_morale(near, 50.0)
	_set_morale(far, 50.0)
	for rnd in range(1, 4):
		r.call("evaluate_round", rnd)
	var c_hi := _morale_of(near)
	var c_lo := _morale_of(far)
	var ok_c := is_equal_approx(c_hi, 50.0) and is_equal_approx(c_lo, 35.0)
	_check("morale_zones", ok_a and ok_b and ok_c, {"seq_a": seq, "zones_a": mz,
		"b": [b_hi, b_lo, b_hq], "c": [c_hi, c_lo]})


func _test_rout_blocked() -> void:
	_reset_board()
	var dl: RefCounted = Step6Cls.new()
	var uid := "B_INF_1"
	# Gate proof: allowed -> a 0-morale unit routs on some deterministic seed ...
	SandboxRulesCls.set_rout_allowed(true)
	_set_morale(uid, 0.0)
	var fired := -1
	for t in range(1, 41):
		_mgr().call("s6_set_routed", uid, false)
		dl.call("_rout_and_rally", _mgr(), {}, {}, {}, t, {"routed_new": [], "rallied": [], "fled": []})
		if bool((_mgr().call("get_unit_by_id", uid) as Dictionary).get("routed", false)):
			fired = t
			break
	# ... the morale mission blocks it across many seeds ...
	_mgr().call("s6_set_routed", uid, false)
	var r := _rules(_mission("M3", {"morale": true}))
	var blocked_flag := not bool(SandboxRulesCls.is_rout_allowed())
	var held := true
	for t in range(1, 41):
		_mgr().call("s6_set_routed", uid, false)
		_set_morale(uid, 0.0)
		dl.call("_rout_and_rally", _mgr(), {}, {}, {}, t, {"routed_new": [], "rallied": [], "fled": []})
		held = held and not bool((_mgr().call("get_unit_by_id", uid) as Dictionary).get("routed", false))
	# ... after_combat immediate rout is gated too (manager turn walks the seeds) ...
	var res := {"defender_class": "infantry", "defender_destroyed": false, "attacker_casualties": 0,
		"defender_casualties": 200, "attacker_destroyed": false}
	SandboxRulesCls.set_rout_allowed(true)
	var fired2 := false
	for i in range(40):
		_mgr().call("s6_set_routed", uid, false)
		_set_morale(uid, 0.0)
		dl.call("after_combat", _mgr(), "R_INF_1", uid, res)
		fired2 = fired2 or bool((_mgr().call("get_unit_by_id", uid) as Dictionary).get("routed", false))
		_mgr().call("end_turn")
	SandboxRulesCls.set_rout_allowed(false)
	var held2 := true
	for i in range(40):
		_mgr().call("s6_set_routed", uid, false)
		_set_morale(uid, 0.0)
		dl.call("after_combat", _mgr(), "R_INF_1", uid, res)
		held2 = held2 and not bool((_mgr().call("get_unit_by_id", uid) as Dictionary).get("routed", false))
		_mgr().call("end_turn")
	# ... and freeing the mission rules restores the previous flag.
	r.free()
	var restored := bool(SandboxRulesCls.is_rout_allowed())
	_check("rout_blocked_when_morale_on", fired > 0 and blocked_flag and held and fired2 and held2 and restored,
		{"rally_fired_turn": fired, "shock_fired": fired2, "restored": restored})


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
	# Build skill cooldown (40 preset: 11): refused for cd - 1 more rounds, available on round cd.
	var cd := int((r.get("rules_cfg") as Dictionary)["base_build_cooldown"])
	var codes: Array = []
	for _i in range(cd):
		_mgr().call("end_turn")
		codes.append(str((r.call("can_build_base", "B_HQ_1") as Dictionary).get("code", "")))
	var refused := codes.slice(0, cd - 1).all(func(c): return c == "COOLDOWN")
	_check("build_base_cooldown", cd == 11 and refused and codes[cd - 1] != "COOLDOWN", {"cooldown": cd, "codes": codes})
	# Two enemy entries: the first is absorbed (attacker pushed off the hex, action ended), the second destroys.
	var bhex: Array = built.get("hex", [0, 0])
	var bh := Vector2i(int(bhex[0]), int(bhex[1]))
	h.call("place_unit", "R_SCT_1", bh)
	r.call("evaluate_round", 2)
	var after1: Dictionary = r.call("base_at", bh)
	var sct: Dictionary = _mgr().call("get_unit_by_id", "R_SCT_1")
	var pushed := Vector2i(int(sct["q"]), int(sct["r"])) != bh and HexUtilsCls.hex_distance_axial(Vector2i(int(sct["q"]), int(sct["r"])), bh) == 1
	h.call("place_unit", "R_SCT_1", bh)
	r.call("evaluate_round", 3)
	var after2: Dictionary = r.call("base_at", bh)
	var destroyed_evt := false
	for e in (r.get("events") as Array):
		if str(e.get("type", "")) == "base_destroyed" and str(e.get("base_id", "")) == str(built.get("base_id", "")):
			destroyed_evt = true
	_check("base_two_hits", not after1.is_empty() and int(after1.get("hits_left", 0)) == 1 and pushed \
		and bool(sct.get("action_ended", false)) and after2.is_empty() and destroyed_evt,
		{"hits_left_after_1": after1.get("hits_left", null), "pushed_to": [sct["q"], sct["r"]], "destroyed": destroyed_evt})


func _finish() -> void:
	var ok := results.size() == EXPECTED_CHECKS  # a check aborted by a script error never reports
	for r in results:
		ok = ok and bool(r["pass"])
	if results.size() != EXPECTED_CHECKS:
		print("[GxMissionsTest] FAIL check_count %d of %d ran" % [results.size(), EXPECTED_CHECKS])
	var out := {"suite": "gx_missions_rules_build_base", "pass": ok, "results": results}
	var dir := ProjectSettings.globalize_path("res://artifacts/gx_missions_dev")
	DirAccess.make_dir_recursive_absolute(dir)
	var f := FileAccess.open(dir + "/test_mission_rules.json", FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(out, "  ", true))
		f.close()
	print("[GxMissionsTest] SUITE %s" % ("PASS" if ok else "FAIL"))
	quit(0 if ok else 1)
