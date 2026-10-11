extends SceneTree

## One-shot helper: prints per-asset triangle counts + bounds (budget planning).

func _init() -> void:
	var Lib = load("res://scripts/visual/map_composition_v0/map_composition_library.gd")
	var keys: Array = ["tall_pine", "wind_pine", "conifer", "compact_pine", "dead_tree", "broadleaf", "cypress", "sapling", "small_house", "medium_house", "granary", "workshop", "hall", "gate", "palisade", "stone_wall", "gatehouse", "watchtower", "hill_fort", "stronghold"]
	for k in keys:
		var b: Dictionary = Lib.bounds(k)
		var h: Vector2 = b["half_xz"]
		print("%s tris=%d w=%.2f d=%.2f h=%.2f half=(%.2f,%.2f) circ=%.2f" % [k, Lib.triangles(k), h.x * 2.0, h.y * 2.0, b["max"].y - b["min"].y, h.x, h.y, b["circ_r"]])
	quit()
