extends SceneTree
## HQ HUD rules (2026-11-01): edge bases connect to the HQ without a built base, and the
## supply line tapers with distance (10 px at the base, 3 px after 5 hexes).
## godot --headless --path . --script res://tools/rules_v2/test_hq_hud.gd

const SupplyCls = preload("res://scripts/rules_v2/supply_v2.gd")
const OverlayCls = preload("res://scripts/rules_v2/v2_overlay.gd")

var fails := 0


func check(name: String, ok: bool, extra: String = "") -> void:
	print(("PASS " if ok else "FAIL ") + name + ((" | " + extra) if extra != "" else ""))
	if not ok:
		fails += 1


func _init() -> void:
	var cfg := {"near": 3, "normal": 6, "link": 6, "stock": {"blue": 4, "red": 4}, "seed": 1031, "edge_link": 10}
	# --- M1: blue HQ at (-6,-11) -------------------------------------------------
	var sv = SupplyCls.new()
	sv.configure(cfg, [])
	sv.setup_fixed({"B_HQ": {"id": "B_HQ", "faction": "blue", "class": "hq", "q": -6, "r": -11, "soldier_count": 300}}, 20)
	var e: Array = sv.fixed["blue"]["entries"]
	var d0: int = sv.dist(e[0].x, e[0].y, -6, -11)
	var d1: int = sv.dist(e[1].x, e[1].y, -6, -11)
	print("[HQHUD] M1 edge bases %s  distance to HQ %d / %d  (edge_link %d)" % [str(e), d0, d1, sv.edge_link])
	var paths: Array = sv.fixed_paths("blue")
	check("M1 edge bases connect before any base is built", paths.size() == 2, str(paths.size()))
	check("M1 supply line starts at an edge base", not paths.is_empty() and paths[0][0] == e[0])
	check("M1 supply line ends on the HQ", not paths.is_empty() and paths[0][paths[0].size() - 1] == Vector2i(-6, -11))
	check("nothing is built yet", sv.nodes.is_empty())

	# --- the HQ marches: the network must follow it (2026-11-01) -----------------------
	var moved := {"B_HQ": {"id": "B_HQ", "faction": "blue", "class": "hq", "q": -8, "r": -10, "soldier_count": 300}}
	var paths_moved: Array = sv.fixed_paths("blue", moved)
	check("supply lines follow a moved HQ", not paths_moved.is_empty() and paths_moved[0][paths_moved[0].size() - 1] == Vector2i(-8, -10), str(paths_moved[0][paths_moved[0].size() - 1]) if not paths_moved.is_empty() else "-")

	# --- every supply line starts AT a base (2026-11-04: no T-junctions, no lines starting mid-line) ------------
	var tj = SupplyCls.new()
	tj.configure(cfg, [])
	tj.setup_fixed({"B_HQ": {"id": "B_HQ", "faction": "blue", "class": "hq", "q": 0, "r": 0, "soldier_count": 300}}, 20)
	tj.fixed["blue"]["entries"] = [Vector2i(10, 0), Vector2i(5, -9)]
	var tj_paths: Array = tj.fixed_paths("blue")
	check("every edge line starts at its edge base", tj_paths.size() == 2 and tj_paths[0][0] == Vector2i(10, 0) and tj_paths[1][0] == Vector2i(5, -9), str(tj_paths.size()))
	check("no line hooks onto another line (both end at the HQ)", tj_paths.size() == 2 and tj_paths[1][tj_paths[1].size() - 1] == Vector2i(0, 0))

	# --- a built base stays put; the HQ keeps its own radius after marching ------------
	var start_units := {"B_HQ": {"id": "B_HQ", "faction": "blue", "class": "hq", "q": -6, "r": -11, "soldier_count": 300}}
	var placed: Dictionary = sv.place_node(start_units, "blue")
	check("base can be placed on the HQ hex", bool(placed.get("success", false)), str(placed.get("error", "")))
	var node_paths: Array = sv.fixed_paths("blue", moved)
	check("after building, lines end on the base, not the HQ", not node_paths.is_empty() and node_paths[0][node_paths[0].size() - 1] == Vector2i(-6, -11), str(node_paths[0][node_paths[0].size() - 1]) if not node_paths.is_empty() else "-")
	var src: Array = sv.connected_sources(moved, "blue")
	check("a marched HQ keeps its own supply radius", src.has(Vector2i(-8, -10)), str(src))

	# --- a HQ that is out of reach draws nothing ---------------------------------
	var far = SupplyCls.new()
	far.configure(cfg, [])
	far.setup_fixed({"B_HQ": {"id": "B_HQ", "faction": "blue", "class": "hq", "q": 20, "r": 0, "soldier_count": 300}}, 20)
	# entries are placed near their own HQ, so fabricate an out-of-reach base to prove the range check
	far.fixed["blue"]["entries"] = [Vector2i(0, 20)]
	print("[HQHUD] fabricated far entry %s distance %d" % [str(far.fixed["blue"]["entries"]), far.dist(0, 20, 20, 0)])
	check("out-of-range edge base stays disconnected", far.fixed_paths("blue").is_empty(), str(far.fixed_paths("blue").size()))

	# --- taper --------------------------------------------------------------------
	var w0: float = OverlayCls.link_width(0)
	var w5: float = OverlayCls.link_width(5)
	var w9: float = OverlayCls.link_width(9)
	check("line leaves the base at 10 px", is_equal_approx(w0, 10.0), "%.2f" % w0)
	check("line is 3 px after 5 hexes", is_equal_approx(w5, 3.0), "%.2f" % w5)
	check("line keeps thinning past the knee", w9 < w5 and w9 >= 1.0, "%.2f" % w9)
	check("taper is monotonic", w0 > w5 and w5 > w9)
	print("=== HQ HUD: %d failure(s) ===" % fails)
	quit(1 if fails > 0 else 0)
