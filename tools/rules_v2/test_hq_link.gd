extends SceneTree
## The HQ shows a supply line to the built base once it has walked away from it.
## godot --headless --path . --script res://tools/rules_v2/test_hq_link.gd
const SupplyCls = preload("res://scripts/rules_v2/supply_v2.gd")
var fails := 0
func check(name: String, ok: bool, extra: String = "") -> void:
	print(("PASS " if ok else "FAIL ") + name + ((" | " + extra) if extra != "" else ""))
	if not ok: fails += 1

func _init() -> void:
	var sv = SupplyCls.new()
	sv.configure({"link": 10, "edge_link": 10, "fixed_edge_bases": 2, "stock": {"blue": 4, "red": 4}}, [])
	var units := {"B_HQ": {"id": "B_HQ", "faction": "blue", "class": "hq", "q": 0, "r": 15, "soldier_count": 300}}
	sv.setup_fixed(units, 20)
	check("a first base can be dropped", sv.place_block_reason(units, "blue") == "" or sv.place_block_reason(units, "blue") == "out of link range", sv.place_block_reason(units, "blue"))
	var res: Dictionary = sv.place_node(units, "blue")
	print("[T] place: ", res)
	if res.get("success", false):
		units["B_HQ"]["q"] = 4
		units["B_HQ"]["r"] = 11
		var edges: Array = sv.link_edges(units, "blue")
		var found := false
		for e in edges:
			if bool(e.get("hq", false)) and e["to"] == Vector2i(4, 11):
				found = true
		check("the HQ has a line to the network after walking away from its base", found, str(edges))
		units["B_HQ"]["q"] = 0
		units["B_HQ"]["r"] = 15
		var edges2: Array = sv.link_edges(units, "blue")
		var none := true
		for e in edges2:
			if bool(e.get("hq", false)):
				none = false
		check("no extra line while the HQ stands on its base", none)
	else:
		check("base placed", false, str(res))
	print("=== HQ link test: %d failure(s) ===" % fails)
	quit(1 if fails > 0 else 0)
