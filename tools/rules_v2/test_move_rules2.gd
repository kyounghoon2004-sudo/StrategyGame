extends SceneTree
## V2: unseen ground is planned as flat; rivers can be crossed (whole base MP) but never stood on; execution uses TRUE terrain.
## godot --path . --script res://tools/rules_v2/test_move_rules2.gd
const PF = preload("res://scripts/step3/step3_pathfinding.gd")
const CFG = preload("res://scripts/core/step3_config.gd")
const V2 = preload("res://scripts/rules_v2/rules_v2.gd")
class Cell:
	var terrain: int = 0
var fails := 0
func check(name: String, ok: bool, extra: String = "") -> void:
	print(("PASS " if ok else "FAIL ") + name + ((" | " + extra) if extra != "" else ""))
	if not ok: fails += 1

func env(cells: Dictionary, spent: float = 0.0):
	return PF.calculate_envelope(Vector2i(0, 0), "infantry", 2.0, 2.0 - spent, CFG.MarchPolicy.GREEN_ONLY, cells, {}, {}, "blue", {}, spent, 2.0, 4.0, 4.4, {})

func _init() -> void:
	V2.enabled = true
	var cells := {}
	for q in range(-8, 9):
		for r in range(-8, 9):
			cells["%d,%d" % [q, r]] = Cell.new()
	(cells["1,0"] as Cell).terrain = 1   # mountain next to the unit
	V2.known_on = true
	V2.known = {}
	var e1 = env(cells)
	check("unseen mountain is planned as flat ground (route through it)", e1.reachable_data.has(Vector2i(2, 0)) and (e1.reachable_data[Vector2i(2, 0)]["path"] as Array).has(Vector2i(1, 0)))
	V2.known = {"1,0": true}
	var e2 = env(cells)
	check("seen mountain blocks (route avoids it)", not e2.reachable_data.has(Vector2i(1, 0)))
	# river
	(cells["1,0"] as Cell).terrain = 7
	V2.known = {"1,0": true, "2,0": true}
	var e3 = env(cells)
	check("river hex itself is never a destination", not e3.reachable_data.has(Vector2i(1, 0)))
	check("far bank is reachable with the full MP", e3.reachable_data.has(Vector2i(2, 0)), str(e3.reachable_data.get(Vector2i(2, 0), {}).get("cost", "-")))
	check("river crossing used the whole base MP", abs(float(e3.reachable_data.get(Vector2i(2, 0), {}).get("cost", -1.0)) - 2.0) < 0.01)
	check("nothing beyond the far bank", not e3.reachable_data.has(Vector2i(3, 0)))
	var e4 = env(cells, 1.0)
	check("with only 1 MP left the river is not crossed", not e4.reachable_data.has(Vector2i(2, 0)) or not (e4.reachable_data[Vector2i(2, 0)]["path"] as Array).has(Vector2i(1, 0)))
	# a bridge hex right behind the river is not a far bank: it cannot be reached by stepping out of the water
	(cells["2,0"] as Cell).terrain = 6
	V2.known = {"1,0": true, "2,0": true}
	var e5 = env(cells)
	check("a bridge hex cannot be entered straight out of a river hex", not e5.reachable_data.has(Vector2i(2, 0)) or not (e5.reachable_data[Vector2i(2, 0)]["path"] as Array).has(Vector2i(1, 0)))
	V2.known_on = false
	V2.enabled = false
	print("--- planning done; execution against the true terrain")
	# execution through the real unit manager
	V2.enabled = true
	var shell: Node = (load("res://scenes/step2r_battlefield_shell.tscn") as PackedScene).instantiate()
	shell.set("battlefield_id", "EDITOR_M1")
	shell.set("no_fog", true)
	root.add_child(shell)
	for i in 100:
		await process_frame
	var um = shell.get("unit_manager")
	var id := "B_CONS_2"
	var u: Dictionary = um._units[id]
	var o := Vector2i(int(u["q"]), int(u["r"]))
	var dirs := [Vector2i(1, 0), Vector2i(1, -1), Vector2i(0, -1), Vector2i(-1, 0), Vector2i(-1, 1), Vector2i(0, 1)]
	var dv: Vector2i = dirs[0]
	for d in dirs:
		var a: Vector2i = o + d
		var b: Vector2i = o + d * 2
		if not um._occupied_map.has("%d,%d" % [a.x, a.y]) and not um._occupied_map.has("%d,%d" % [b.x, b.y]):
			dv = d
			break
	var p1 := o + dv
	var p2 := o + dv * 2
	var truth := {}
	for dq in range(-3, 4):
		for dr in range(-3, 4):
			truth["%d,%d" % [o.x + dq, o.y + dr]] = {"terrain": 0}
	var vis := {}
	var path: Array[Vector2i] = [o, p1, p2]
	# mountain on the first step: stop before, nothing spent
	truth["%d,%d" % [p1.x, p1.y]] = {"terrain": 1}
	var r1: Dictionary = um.execute_player_stepwise_move(id, path, vis, truth, {})
	check("true mountain on the path: unit stays, stopped by terrain", not r1.get("moved", true) and r1.get("contact_kind", "") == "terrain", str(r1.get("contact_kind", "")))
	# river with full MP: crosses and lands beyond, MP gone
	truth["%d,%d" % [p1.x, p1.y]] = {"terrain": 7}
	var r2: Dictionary = um.execute_player_stepwise_move(id, path, vis, truth, {})
	var after := Vector2i(int(u["q"]), int(u["r"]))
	check("river crossed with full MP, landed on the far bank", r2.get("moved", false) and after == p2, str(after))
	check("crossing spent all the MP", float(u["remaining_mp"]) <= 0.001, str(u["remaining_mp"]))
	check("the unit never stands on the river", after != p1)
	# a river two hexes wide: crossing the first hex leaves no MP for the second -> the unit must stay on the near bank
	var p3 := o + dv * 3
	for kk in ["%d,%d" % [p1.x, p1.y], "%d,%d" % [p2.x, p2.y]]:
		truth[kk] = {"terrain": 7}
	truth["%d,%d" % [p3.x, p3.y]] = {"terrain": 0}
	u["remaining_mp"] = float(u["base_mp"])
	u["turn_move_cost_spent"] = 0.0
	u["action_ended"] = false
	var back_at := Vector2i(int(u["q"]), int(u["r"]))
	var path2: Array[Vector2i] = [back_at, back_at + dv, back_at + dv * 2, back_at + dv * 3]
	for hh in path2:
		truth["%d,%d" % [hh.x, hh.y]] = truth.get("%d,%d" % [hh.x, hh.y], {"terrain": 0})
	truth["%d,%d" % [path2[1].x, path2[1].y]] = {"terrain": 7}
	truth["%d,%d" % [path2[2].x, path2[2].y]] = {"terrain": 7}
	truth["%d,%d" % [path2[3].x, path2[3].y]] = {"terrain": 0}
	var r3: Dictionary = um.execute_player_stepwise_move(id, path2, vis, truth, {})
	var end3 := Vector2i(int(u["q"]), int(u["r"]))
	check("two-hex river: the unit never ends on a river hex", end3 != path2[1] and end3 != path2[2], str(end3))
	check("two-hex river: it stayed on the near bank and kept its MP", end3 == back_at and float(u["remaining_mp"]) > 0.0, str(u["remaining_mp"]))
	print("=== move rules 2 test: %d failure(s) ===" % fails)
	quit(1 if fails > 0 else 0)
