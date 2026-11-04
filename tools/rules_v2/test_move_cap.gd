extends SceneTree
## Rules V2: base MP is the whole budget (no over-run), first hex always enterable with MP left.
## godot --headless --path . --script res://tools/rules_v2/test_move_cap.gd

const PF = preload("res://scripts/step3/step3_pathfinding.gd")
const CFG = preload("res://scripts/core/step3_config.gd")
const V2 = preload("res://scripts/rules_v2/rules_v2.gd")
class Cell:
	var terrain: int = 0
var fails := 0

func check(name: String, ok: bool, extra: String = "") -> void:
	print(("PASS " if ok else "FAIL ") + name + ((" | " + extra) if extra != "" else ""))
	if not ok: fails += 1

func _init() -> void:
	V2.enabled = true
	var cells := {}
	for q in range(-8, 9):
		for r in range(-8, 9):
			cells["%d,%d" % [q, r]] = Cell.new()
	var o := Vector2i(0, 0)
	var env = PF.calculate_envelope(o, "infantry", 2.0, 2.0, CFG.MarchPolicy.RED_ALLOWED, cells, {}, {}, "blue", {}, 0.0, 2.0, 4.0, 4.4, {})
	var far := 0
	for c in env.reachable_data:
		if max(abs(c.x), abs(c.y), abs(c.x + c.y)) > 2: far += 1
	check("plains, MP 2: nothing beyond 2 hexes (even with RED policy)", far == 0, "beyond=%d" % far)
	check("no orange / red hexes", env.orange_hexes.is_empty() and env.red_hexes.is_empty())
	check("2-hex target is reachable", env.reachable_data.has(Vector2i(2, 0)))
	var rt = PF.find_route(o, Vector2i(3, 0), "infantry", 2.0, 2.0, CFG.MarchPolicy.RED_ALLOWED, cells, {}, {}, "blue", {}, 0.0, 2.0, 4.0, 4.4, {})
	check("3-hex target has no route (no preview)", not rt.found)
	# expensive terrain next to the unit: forest cost 2 > remaining 1 -> still enterable, as a dead end
	var forest := Vector2i(1, 0)
	(cells["1,0"] as Cell).terrain = 2
	var cost_f: float = CFG.get_terrain_cost(2, "infantry")
	var env2 = PF.calculate_envelope(o, "infantry", 2.0, 1.0, CFG.MarchPolicy.RED_ALLOWED, cells, {}, {}, "blue", {}, 1.0, 2.0, 4.0, 4.4, {})
	check("MP 1 left: adjacent forest (cost %.1f) is still enterable" % cost_f, env2.reachable_data.has(forest))
	check("... but nothing behind it", not env2.reachable_data.has(Vector2i(2, 0)) or env2.reachable_data[Vector2i(2, 0)]["path"].size() == 3 and not env2.reachable_data[Vector2i(2, 0)]["path"].has(forest))
	var env3 = PF.calculate_envelope(o, "infantry", 2.0, 0.0, CFG.MarchPolicy.RED_ALLOWED, cells, {}, {}, "blue", {}, 2.0, 2.0, 4.0, 4.4, {})
	check("MP 0: no reach at all", env3.reachable_data.is_empty())
	check("every class is GREEN", CFG.classify_march_by_cumulative_cost(9.0, 2.0, 4.0, true) == CFG.MarchClass.GREEN)
	V2.enabled = false
	var env4 = PF.calculate_envelope(o, "infantry", 2.0, 2.0, CFG.MarchPolicy.RED_ALLOWED, cells, {}, {}, "blue", {}, 0.0, 2.0, 4.0, 4.4, {})
	check("legacy rules untouched: still has orange/red tiers", not env4.orange_hexes.is_empty() or not env4.red_hexes.is_empty())
	print("=== move cap test: %d failure(s) ===" % fails)
	quit(1 if fails > 0 else 0)
