extends SceneTree
## M2: a NEUTRAL structure is a valid target for both sides, takes wall damage and flips to the
## occupier at turn end (V2 contest rule). Rules layer only: no shell, no view.
## godot --headless --path . --script res://tools/rules_v2/test_m2_fort.gd

const Step3UnitManagerCls = preload("res://scripts/step3/step3_unit_manager.gd")
const RulesV2Cls = preload("res://scripts/rules_v2/rules_v2.gd")

const FORT := Vector2i(-4, -1)

var fails := 0


func check(name: String, ok: bool, extra: String = "") -> void:
	print(("PASS " if ok else "FAIL ") + name + ((" | " + extra) if extra != "" else ""))
	if not ok:
		fails += 1


func _init() -> void:
	RulesV2Cls.set_from_scenario({"rules_version": "v2", "rules_v2": {"supply": {"near": 3, "normal": 6, "link": 6}}})
	check("rules v2 on", RulesV2Cls.enabled)
	var units: Array = [
		{"id": "B_ATK", "class": "spearman", "faction": "blue", "q": FORT.x, "r": FORT.y - 1, "soldier_count": 62},
		{"id": "B_FAR", "class": "conscript", "faction": "blue", "q": FORT.x + 3, "r": FORT.y + 1, "soldier_count": 50},
		{"id": "B_HQ", "class": "hq", "faction": "blue", "q": -9, "r": -11, "soldier_count": 300},
		{"id": "R_ATK", "class": "conscript", "faction": "red", "q": FORT.x, "r": FORT.y + 1, "soldier_count": 58},
		{"id": "R_HQ", "class": "hq", "faction": "red", "q": 11, "r": -2, "soldier_count": 300},
	]
	var defs: Array = [{"id": "M2_GATE_FORT", "name": "Gate Fort", "type": "fortress", "owner": "neutral",
		"footprint": [FORT], "hp": 450, "slots": 0}]
	var um = Step3UnitManagerCls.new()
	um.initialize_from_renderer_units(units, true, defs)
	um.init_supply_v2({"near": 3, "normal": 6, "link": 6, "stock": {"blue": 4, "red": 4}, "seed": 1031}, [])
	var fort: Variant = um.get_stronghold_at_coord(FORT)
	check("neutral fort registered", fort != null and str(fort.owner) == "neutral", str(fort.owner) if fort != null else "-")
	check("fort HP 450", fort != null and int(fort.fortification_hp) == 450, str(int(fort.fortification_hp)))

	var seen_blue := false
	for e in um.get_attackable_strongholds("B_ATK"):
		if str(e.get("structure_id", "")) == "M2_GATE_FORT":
			seen_blue = true
	check("blue can target the neutral fort", seen_blue)
	var seen_red := false
	for e in um.get_attackable_strongholds("R_ATK"):
		if str(e.get("structure_id", "")) == "M2_GATE_FORT":
			seen_red = true
	check("red can target it too (neutral)", seen_red)

	var hp0: int = int(fort.fortification_hp)
	var res: Dictionary = um.call("execute_stronghold_assault", "B_ATK", "M2_GATE_FORT", "")
	check("assault resolves", bool(res.get("success", false)), str(res.get("error", res)))
	check("wall damage lands", int(fort.fortification_hp) < hp0, "%d -> %d" % [hp0, int(fort.fortification_hp)])
	check("a unit stays on its hex after assaulting an empty fort", Vector2i(int(um._units["B_ATK"]["q"]), int(um._units["B_ATK"]["r"])) == Vector2i(FORT.x, FORT.y - 1))

	# capture: wall at 0 + occupier at turn end
	fort.fortification_hp = 0
	var u: Dictionary = um._units["B_ATK"]
	u["q"] = FORT.x
	u["r"] = FORT.y
	um.end_turn()
	check("neutral fort flips to the occupier", str(fort.owner) == "blue", str(fort.owner))
	print("=== M2 fort: %d failure(s) ===" % fails)
	quit(1 if fails > 0 else 0)
