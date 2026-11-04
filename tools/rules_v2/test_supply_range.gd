extends SceneTree
## Supply V2 radii (2026-11-01): the HQ buffs morale/heals within 4 hexes and holds it to 6.
## godot --headless --path . --script res://tools/rules_v2/test_supply_range.gd

const SupplyCls = preload("res://scripts/rules_v2/supply_v2.gd")

var fails := 0


func check(name: String, ok: bool, extra: String = "") -> void:
	print(("PASS " if ok else "FAIL ") + name + ((" | " + extra) if extra != "" else ""))
	if not ok:
		fails += 1


func _init() -> void:
	var sv = SupplyCls.new()
	sv.configure({}, [])   # shipped defaults, not a test override
	check("default near radius is 4", sv.near_r == 4, str(sv.near_r))
	check("default normal radius is 6", sv.normal_r == 6, str(sv.normal_r))

	var hq := {"B_HQ": {"id": "B_HQ", "faction": "blue", "class": "hq", "q": 0, "r": 0, "soldier_count": 300}}
	sv.setup_fixed(hq, 20)
	# the HQ is a supply root, so its own hex and the ring around it are "near"
	check("HQ hex is a supply source", sv.connected_sources(hq, "blue").has(Vector2i(0, 0)), str(sv.connected_sources(hq, "blue")))
	check("4 hexes out is near (morale + heal)", sv.zone_of(hq, "blue", 4, 0) == "near", sv.zone_of(hq, "blue", 4, 0))
	check("5 hexes out is normal (morale held)", sv.zone_of(hq, "blue", 5, 0) == "normal", sv.zone_of(hq, "blue", 5, 0))
	check("6 hexes out is still normal", sv.zone_of(hq, "blue", 6, 0) == "normal", sv.zone_of(hq, "blue", 6, 0))
	check("7 hexes out is out of supply", sv.zone_of(hq, "blue", 7, 0) == "out", sv.zone_of(hq, "blue", 7, 0))

	var cells: Dictionary = sv.near_cells(hq, "blue")
	check("near area includes the 4th ring", cells.has(Vector2i(4, 0)), str(cells.size()))
	check("near area excludes the 5th ring", not cells.has(Vector2i(5, 0)))
	print("=== SUPPLY RANGE: %d failure(s) ===" % fails)
	quit(1 if fails > 0 else 0)
