extends SceneTree
## Headless rules-V2 checks:
## godot --headless --path . --script res://tools/rules_v2/test_rules_v2.gd

const RulesV2Cls = preload("res://scripts/rules_v2/rules_v2.gd")
const Step3UnitManagerCls = preload("res://scripts/step3/step3_unit_manager.gd")
const Step3ConfigCls = preload("res://scripts/core/step3_config.gd")
const CombatCls = preload("res://scripts/combat/combat_calculator.gd")

var fails := 0

func check(name: String, ok: bool, extra: String = "") -> void:
	print(("PASS " if ok else "FAIL ") + name + ((" | " + extra) if extra != "" else ""))
	if not ok:
		fails += 1

func _init() -> void:
	RulesV2Cls.set_from_scenario({"rules_version": "v2", "rules_v2": {}})
	check("v2 enabled", RulesV2Cls.enabled)
	check("hq move 3, cavalry 4 (balance patch 2026-11-04)", Step3ConfigCls.get_base_movement("hq") == 3.0 and Step3ConfigCls.get_base_movement("cavalry") == 4.0)
	check("mountain impassable", Step3ConfigCls.is_impassable(1))
	# no matchup: same attack stat -> same damage regardless of defender class
	var a := {"class": "infantry", "soldier_count": 60, "max_count": 60, "morale": 100.0}
	var d1 := {"class": "archer", "soldier_count": 60, "max_count": 60, "morale": 100.0}
	var d2 := {"class": "cavalry", "soldier_count": 60, "max_count": 60, "morale": 100.0}
	var r1 := CombatCls.calculate_combat(a, d1, 1, 0)
	var r2 := CombatCls.calculate_combat(a, d2, 1, 0)
	check("no matchup", int(r1["defender_casualties"]) == int(r2["defender_casualties"]), "dmg %d" % int(r1["defender_casualties"]))
	var weak := a.duplicate()
	weak["morale"] = 50.0
	var rw := CombatCls.calculate_combat(weak, d1, 1, 0)
	check("morale<=66 cuts attack", int(rw["defender_casualties"]) < int(r1["defender_casualties"]), "%d<%d" % [int(rw["defender_casualties"]), int(r1["defender_casualties"])])
	var arch := CombatCls.calculate_combat(a, d1, 3, 0)
	check("ranged no counter", int(arch["attacker_casualties"]) == 0)

	var um := Step3UnitManagerCls.new()
	var units: Array = [
		{"id": "B_HQ", "class": "hq", "faction": "blue", "q": 0, "r": 0, "soldier_count": 300},
		{"id": "B_MIL", "class": "conscript", "faction": "blue", "q": 0, "r": 1, "soldier_count": 50},
		{"id": "B_FAR", "class": "infantry", "faction": "blue", "q": 6, "r": 0, "soldier_count": 60},
		{"id": "R_HQ", "class": "hq", "faction": "red", "q": 8, "r": -4, "soldier_count": 300},
		{"id": "R_RAID", "class": "scout", "faction": "red", "q": 2, "r": 0, "soldier_count": 30},
	]
	um.initialize_from_renderer_units(units, false, [])
	um.init_supply_v2({"near": 2, "normal": 4, "link": 4, "stock": {"blue": 2, "red": 2}, "seed": 7}, [])
	# damage the near unit to test heal; zones
	um._units["B_MIL"]["soldier_count"] = 20
	um._units["B_FAR"]["morale"] = 80.0
	um.end_turn()
	check("near heals HP", int(um.get_unit_by_id("B_MIL")["soldier_count"]) > 20 and int(um.get_unit_by_id("B_MIL")["soldier_count"]) < 50)
	check("far unit is out", str(um.get_unit_by_id("B_FAR").get("supply_zone", "")) == "out")
	check("out decays morale", float(um.get_unit_by_id("B_FAR")["morale"]) < 80.0)
	for i in 6:
		um.end_turn()
	for i in 8:
		um.end_turn()
	var far: Dictionary = um._units["B_FAR"]
	check("morale <=33 and attack/move reduced", float(far["morale"]) <= 33.0 and float(far["remaining_mp"]) < 2.0, "morale %.0f mp %.0f hp %d" % [float(far["morale"]), float(far["remaining_mp"]), int(far["soldier_count"])])
	check("desertion drained HP", int(far["soldier_count"]) < 60, "hp %d" % int(far["soldier_count"]))
	# bases
	var p1: Dictionary = um.v2_place_base("blue")
	check("place base at HQ", p1.get("success", false))
	check("dup base rejected", not um.v2_place_base("blue").get("success", false))
	check("stock spent", int(um.supply_v2.stock["blue"]) == 1)
	um._units["B_HQ"]["q"] = 4
	var p2: Dictionary = um.v2_place_base("blue")
	check("auto-link second base", p2.get("success", false))
	um._units["B_HQ"]["q"] = 8
	um._units["B_HQ"]["r"] = 0
	check("no stock -> rejected", not um.v2_place_base("blue").get("success", false))
	# far unit now covered by linked base at (4,0)
	check("linked base extends zone", um.supply_v2.zone_of(um._units, "blue", 6, 0) == "near")
	# raid: red scout steps on blue base (0,0), survives a round -> base lost, +1 red stock
	um._units["R_RAID"]["q"] = 0
	um._units["R_RAID"]["r"] = 0
	var rr: Dictionary = um.v2_begin_raid("R_RAID", false)
	check("begin raid", rr.get("success", false))
	um.end_turn()
	check("red raid waits a blue phase", not um.supply_v2.node_at(0, 0).is_empty())
	um.v2_resolve_raids("red")
	check("raid completes", um.supply_v2.node_at(0, 0).is_empty() and int(um.supply_v2.stock["red"]) == 3)
	# raid cancelled when raider hit
	um._units["R_RAID"]["q"] = 4
	um._units["R_RAID"]["r"] = 0
	var rr2: Dictionary = um.v2_begin_raid("R_RAID", false)
	check("begin raid 2", rr2.get("success", false))
	um.supply_v2.on_unit_attacked("R_RAID")
	um.end_turn()
	um.v2_resolve_raids("red")
	check("raid cancelled by attack", not um.supply_v2.node_at(4, 0).is_empty())
	# destroy
	um._units["R_RAID"]["action_ended"] = false
	check("destroy base", um.v2_destroy_base("R_RAID").get("success", false) and um.supply_v2.node_at(4, 0).is_empty())
	# defender XP from counterattack
	um._units["B_FAR"]["q"] = 3
	um._units["B_FAR"]["r"] = 3
	um._units["R_RAID"]["q"] = 4
	um._units["R_RAID"]["r"] = 3
	um._units["R_RAID"]["action_ended"] = false
	um._units["R_RAID"]["has_attacked"] = false
	um._units["B_FAR"]["xp"] = 0
	um._units["B_FAR"]["soldier_count"] = 60
	um._units["B_FAR"]["max_count"] = 60
	var ar: Dictionary = um.execute_attack("R_RAID", "B_FAR")
	check("defender earns XP on counter", int(um._units["B_FAR"].get("xp", 0)) > 0 and ar.get("success", false), "xp %d" % int(um._units["B_FAR"].get("xp", 0)))
	# rest (휴식): heals HP when supplied; wait (대기) ends the action; build (건설) uses the HQ's action
	um._units["B_HQ"]["q"] = 0
	um._units["B_HQ"]["r"] = 0   # the healing radius moves with the HQ
	var restu: Dictionary = um._units["B_MIL"]
	restu["soldier_count"] = 20
	restu["max_count"] = 50
	restu["action_ended"] = false
	restu["has_moved"] = false
	restu["has_attacked"] = false
	restu["turn_move_cost_spent"] = 0.0
	restu["supply_zone"] = "near"
	var rr_: Dictionary = um.rest_unit("B_MIL")
	check("rest heals HP and ends action", rr_.get("success", false) and int(restu["soldier_count"]) > 20 and bool(restu["action_ended"]), "hp %d" % int(restu["soldier_count"]))
	var wu: Dictionary = um._units["B_FAR"]
	wu["action_ended"] = false
	check("wait ends the action", um.wait_unit("B_FAR").get("success", false) and bool(wu["action_ended"]))
	var hqu: Dictionary = um._units["B_HQ"]
	hqu["q"] = 0
	hqu["r"] = 0
	hqu["action_ended"] = false
	um.supply_v2.stock["blue"] = 2
	um.supply_v2.nodes.clear()
	var bb: Dictionary = um.v2_build_base("B_HQ")
	check("build base succeeds and ends the HQ action", bb.get("success", false) and bool(hqu["action_ended"]), str(bb.get("error", "")))
	check("a second build the same turn is refused", not um.v2_build_base("B_HQ").get("success", false))
	check("only the HQ builds", not um.v2_build_base("B_MIL").get("success", false))
	# 휴식 = 무방비 (no melee counter), 요새화 (own HP, 1 use, dropped on move)
	var da := {"class": "infantry", "soldier_count": 50, "max_count": 50, "morale": 100.0, "rested_this_turn": true}
	var aa := {"class": "infantry", "soldier_count": 50, "max_count": 50, "morale": 100.0}
	var rr1 := CombatCls.calculate_combat(aa, da, 1, 0)
	var rr3 := CombatCls.calculate_combat(aa, {"class": "infantry", "soldier_count": 50, "max_count": 50, "morale": 100.0}, 1, 0)
	check("resting unit cannot counter in melee", int(rr1["attacker_casualties"]) == 0 and int(rr3["attacker_casualties"]) > 0)
	var df := {"class": "infantry", "soldier_count": 50, "max_count": 50, "morale": 100.0, "fort_hp": 120}
	var rf := CombatCls.calculate_combat(aa, df, 1, 0)
	check("fortified unit: hit splits to palisade and unit, counter still works", int(rf["unit_fort_damage"]) > 0 and int(rf["defender_casualties"]) > 0 and int(rf["attacker_casualties"]) > 0, "fort -%d hp -%d" % [int(rf["unit_fort_damage"]), int(rf["defender_casualties"])])
	check("fortified unit takes less direct damage than an open unit", int(rf["defender_casualties"]) < int(rr3["defender_casualties"]))
	var fu: Dictionary = um._units["B_FAR"]
	fu["action_ended"] = false
	fu["has_moved"] = false
	fu["has_attacked"] = false
	check("fortify allowed for an untouched infantry", um.v2_fortify_block("B_FAR") == "")
	var fres: Dictionary = um.v2_fortify("B_FAR")
	check("fortify sets HP, spends the one use and ends the action", fres.get("success", false) and int(fu["fort_hp"]) == 120 and bool(fu["fort_used"]) and bool(fu["action_ended"]))
	fu["action_ended"] = false
	check("second fortify refused (once per game)", um.v2_fortify_block("B_FAR") != "")
	check("HQ cannot fortify", um.v2_fortify_block("B_HQ") != "")
	check("rest refused outside the healing radius", not um.can_unit_rest("B_FAR") or um.supply_v2.zone_of(um._units, "blue", int(fu["q"]), int(fu["r"])) == "near")
	# 병참기지 HP: broken by an adjacent enemy attack (no counter, 약탈 kept, 파괴 button gone)
	um.supply_v2.nodes.clear()
	um.supply_v2.stock["red"] = 3
	var rb: Dictionary = um.supply_v2.place_node(um._units, "red")
	check("red base starts with its own HP", rb.get("success", false) and int(rb["node"]["hp"]) == 80 and int(rb["node"]["hp_max"]) == 80)
	var bq: int = int(um._units["R_HQ"]["q"])
	var br_: int = int(um._units["R_HQ"]["r"])
	um._units["R_HQ"]["q"] = bq + 4   # the red HQ leaves the base hex empty
	var bat: Dictionary = um._units["B_FAR"]
	bat["q"] = bq - 1
	bat["r"] = br_
	bat["morale"] = 100.0
	bat["soldier_count"] = 60
	bat["max_count"] = 60
	bat["action_ended"] = false
	bat["has_attacked"] = false
	check("adjacent enemy can attack the base", um.v2_attackable_bases("B_FAR").size() == 1)
	var hp_before: int = int(rb["node"]["hp"])
	var ar1: Dictionary = um.v2_attack_base("B_FAR", str(rb["node"]["id"]))
	check("attack damages the base HP and spends the action", ar1.get("success", false) and int(rb["node"]["hp"]) < hp_before and bool(bat["action_ended"]) and int(bat["soldier_count"]) == 60, str(ar1))
	var rounds_ := 0
	while not um.supply_v2.node_at(bq, br_).is_empty() and rounds_ < 12:
		bat["action_ended"] = false
		bat["has_attacked"] = false
		um.v2_attack_base("B_FAR", str(rb["node"]["id"]))
		rounds_ += 1
	check("repeated attacks destroy the base", um.supply_v2.node_at(bq, br_).is_empty(), "rounds %d" % rounds_)
	check("a base two hexes away is out of melee reach", um.v2_attackable_bases("B_MIL").is_empty())
	# supply chain shown on hover: the links that feed one base
	um.supply_v2.nodes.clear()
	um.supply_v2.stock["blue"] = 5
	um._units["B_HQ"]["q"] = 0
	um._units["B_HQ"]["r"] = 0
	um._units["B_HQ"]["action_ended"] = false
	um.v2_build_base("B_HQ")
	um._units["B_HQ"]["q"] = 4
	um._units["B_HQ"]["action_ended"] = false
	um.v2_build_base("B_HQ")
	um._units["B_HQ"]["q"] = 8
	um._units["B_HQ"]["action_ended"] = false
	um.v2_build_base("B_HQ")
	um._units["B_HQ"]["q"] = 0   # legacy (no edge bases): the chain is rooted at the HQ
	var n3: Dictionary = um.supply_v2.node_at(8, 0)
	var ch: Dictionary = um.supply_v2.chain_to(um._units, "blue", n3)
	check("chain to the third base has two links back to the first", (ch["edges"] as Array).size() == 2, str((ch["edges"] as Array).size()))
	var n1c: Dictionary = um.supply_v2.chain_to(um._units, "blue", um.supply_v2.node_at(0, 0))
	check("chain to the first base has no base-to-base links", (n1c["edges"] as Array).is_empty())
	# promotion
	var mil: Dictionary = um._units["B_MIL"]
	mil["action_ended"] = false
	check("promotion locked without xp", um.v2_promotion_options("B_MIL").is_empty())
	mil["xp"] = 50
	mil["supply_zone"] = "near"
	check("promotion offers infantry", um.v2_promotion_options("B_MIL") == ["infantry"])
	var pr: Dictionary = um.v2_promote("B_MIL", "infantry")
	check("promote conscript->infantry", pr.get("success", false) and str(mil["class"]) == "infantry" and int(mil["soldier_count"]) == int(mil["max_count"]), str(pr))
	mil["action_ended"] = false
	mil["xp"] = 100
	check("infantry branches", um.v2_promotion_options("B_MIL") == ["spear", "cavalry", "archer"])
	check("promote to cavalry sets mp 4", um.v2_promote("B_MIL", "cavalry").get("success", false) and float(mil["base_mp"]) == 4.0)
	print("=== rules_v2 test: %d failure(s) ===" % fails)
	quit(1 if fails > 0 else 0)
