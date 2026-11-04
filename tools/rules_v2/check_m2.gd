extends SceneTree
## M2 scenario data checks (fast, no shell): terrain after hill removal, scenario block, rosters.
## godot --headless --path . --script res://tools/rules_v2/check_m2.gd

const CatalogCls = preload("res://scripts/battlefields/tutorial_battlefield_catalog.gd")

var fails := 0


func check(name: String, ok: bool, extra: String = "") -> void:
	print(("PASS " if ok else "FAIL ") + name + ((" | " + extra) if extra != "" else ""))
	if not ok:
		fails += 1


func _init() -> void:
	var bf: Dictionary = CatalogCls.load_battlefield("EDITOR_M2")
	check("catalog loads EDITOR_M2", not bf.is_empty())
	if bf.is_empty():
		quit(1)
		return
	var counts: Dictionary = {}
	for k in (bf["terrain"] as Dictionary):
		var v: int = int((bf["terrain"] as Dictionary)[k])
		counts[v] = int(counts.get(v, 0)) + 1
	check("plains 1039 (14 hills removed)", int(counts.get(0, 0)) == 1039, str(counts.get(0, 0)))
	check("mountains 34", int(counts.get(1, 0)) == 34, str(counts.get(1, 0)))
	check("forest 167", int(counts.get(2, 0)) == 167, str(counts.get(2, 0)))
	check("road 12", int(counts.get(6, 0)) == 12, str(counts.get(6, 0)))
	check("village 8", int(counts.get(5, 0)) == 8, str(counts.get(5, 0)))

	var sc: Dictionary = bf["scenario"]
	check("rules_version v2", str(sc.get("rules_version", "")) == "v2")
	check("round limit 30", int(sc.get("round_limit", 0)) == 30, str(sc.get("round_limit", 0)))
	check("fort is the objective", (sc.get("fortified_objective_refs", []) as Array).has("M2_GATE_FORT"))
	var sup: Dictionary = (sc.get("rules_v2", {}) as Dictionary).get("supply", {})
	check("supply near/normal/link 3/6/6", int(sup.get("near", 0)) == 3 and int(sup.get("normal", 0)) == 6 and int(sup.get("link", 0)) == 6, str(sup))
	check("supply stock 4/4", int((sup.get("stock", {}) as Dictionary).get("blue", 0)) == 4)

	var forts: Array = bf["strongholds"]
	var fort: Dictionary = {}
	var hall: Dictionary = {}
	for f in forts:
		if str(f["id"]) == "M2_GATE_FORT":
			fort = f
		elif str(f["id"]) == "M2_VILLAGE_HALL":
			hall = f
	check("neutral fort at (-4,-1) 450 HP", not fort.is_empty() and str(fort["owner"]) == "neutral" and int(fort["hp"]) == 450 and (fort["footprint"] as Array)[0] == Vector2i(-4, -1), str(fort.get("owner", "-")))
	check("village hall at (-10,-7) 300 HP blue", not hall.is_empty() and str(hall["owner"]) == "blue" and int(hall["hp"]) == 300 and (hall["footprint"] as Array)[0] == Vector2i(-10, -7))

	var units: Array = bf["units"]
	var blue := 0
	var red := 0
	var arch := 0
	var scout := 0
	var blocked := 0
	for u in units:
		if str(u["faction"]) == "blue":
			blue += 1
		else:
			red += 1
		if str(u["class"]) == "archer":
			arch += 1
		if str(u["class"]) == "scout":
			scout += 1
		var key := "%d,%d" % [int(u["q"]), int(u["r"])]
		if not (bf["terrain"] as Dictionary).has(key):
			blocked += 1
	check("8 blue / 8 red", blue == 8 and red == 8, "%d/%d" % [blue, red])
	check("one archer per side", arch == 2, str(arch))
	check("two scouts per side", scout == 4, str(scout))
	check("every unit stands on a playable hex", blocked == 0, str(blocked))
	print("=== M2 data: %d failure(s) ===" % fails)
	quit(1 if fails > 0 else 0)
