class_name SupplyV2
extends RefCounted

## Rules V2 supply. HQ places bases (nodes) that auto-link to the HQ or another
## connected base within LINK radius. Zones (hex distance to nearest connected
## source): near <= NEAR, normal <= NORMAL, else out.
## Only bases can be destroyed/raided; roads are untouched.

const RulesCls = preload("res://scripts/rules_v2/rules_v2.gd")

var nodes: Array = []                 # {id, faction, q, r, raid_by, raid_turn}
var stock: Dictionary = {"blue": 3, "red": 3}
var towns: Dictionary = {}            # "q,r" -> {stock:int, raid_by:String, raid_turn:int}
var near_r: int = 4
var normal_r: int = 6
var link_r: int = 4
var _next_id: int = 1
var _rng := RandomNumberGenerator.new()
var log_lines: Array = []
## Per faction: {"entries":[Vector2i,...]} = the two fixed edge bases (always there, nobody can alter them).
## Their lines appear only once the HQ has built its first base: each edge base then connects to it.
var fixed: Dictionary = {}
var map_radius: int = 999
var edge_link: int = 8          # max hexes between an edge base and the first built base (line length limit)
const ENTRY_SPACING: int = 5   # ring hexes between the HQ foot point and each fixed edge base


func configure(cfg: Dictionary, town_hexes: Array = []) -> void:
	near_r = int(cfg.get("near", near_r))
	normal_r = int(cfg.get("normal", normal_r))
	link_r = int(cfg.get("link", link_r))
	edge_link = int(cfg.get("edge_link", edge_link))
	var s: Dictionary = cfg.get("stock", {})
	for f in ["blue", "red"]:
		stock[f] = int(s.get(f, stock[f]))
	_rng.seed = int(cfg.get("seed", 1031))
	for h in town_hexes:
		towns["%d,%d" % [int(h[0]), int(h[1])]] = {"stock": RulesCls.TOWN_PLUNDER_STOCK, "raid_by": "", "raid_turn": -1}


static func hex_line(a: Vector2i, b: Vector2i) -> Array:
	var n: int = maxi(abs(a.x - b.x), maxi(abs(a.y - b.y), abs((a.x + a.y) - (b.x + b.y))))
	if n == 0:
		return [a]
	var out: Array = []
	for i in range(n + 1):
		var t := float(i) / float(n)
		var fq := lerpf(a.x, b.x, t) + 1e-6
		var fr := lerpf(a.y, b.y, t) + 1e-6
		var fs := -fq - fr
		var rq := roundf(fq)
		var rr := roundf(fr)
		var rs := roundf(fs)
		var dq := absf(rq - fq)
		var dr := absf(rr - fr)
		var ds := absf(rs - fs)
		if dq > dr and dq > ds:
			rq = -rr - rs
		elif dr > ds:
			rr = -rq - rs
		out.append(Vector2i(int(rq), int(rr)))
	return out


## Two fixed edge bases per faction, each joined by a shortest hex line to the HQ start hex.
func setup_fixed(units: Dictionary, map_radius: int) -> void:
	fixed.clear()
	self.map_radius = map_radius
	for f in ["blue", "red"]:
		var hq := _hq_of(units, f)
		if hq.is_empty():
			continue
		var h := Vector2i(int(hq["q"]), int(hq["r"]))
		var ring: Array = []
		for q in range(-map_radius, map_radius + 1):
			for r in range(-map_radius, map_radius + 1):
				if maxi(abs(q), maxi(abs(r), abs(q + r))) == map_radius:
					ring.append(Vector2i(q, r))
		# ring in angular order; the nearest hex is the foot of the HQ, the two bases sit
		# ENTRY_SPACING hexes either side of it along the board edge
		ring.sort_custom(func(a, b): return atan2(float(a.y * 42 + a.x * 21), float(a.x * 36)) < atan2(float(b.y * 42 + b.x * 21), float(b.x * 36)))
		var foot_i := 0
		for k in range(ring.size()):
			if dist(ring[k].x, ring[k].y, h.x, h.y) < dist(ring[foot_i].x, ring[foot_i].y, h.x, h.y):
				foot_i = k
		var entries: Array = [ring[posmod(foot_i - ENTRY_SPACING, ring.size())], ring[posmod(foot_i + ENTRY_SPACING, ring.size())]]
		fixed[f] = {"entries": entries, "hq": h}


static func dist(aq: int, ar: int, bq: int, br: int) -> int:
	var dq := aq - bq
	var dr := ar - br
	return maxi(abs(dq), maxi(abs(dr), abs(dq + dr)))


func _hq_of(units: Dictionary, faction: String) -> Dictionary:
	for id in units:
		var u: Dictionary = units[id]
		if str(u.get("faction", "")) == faction and str(u.get("class", "")) == "hq" and int(u.get("soldier_count", 0)) > 0:
			return u
	return {}


## The first base the faction built: the edge lines connect to it.
func anchor_of(faction: String) -> Dictionary:
	for n in nodes:
		if str(n["faction"]) == faction:
			return n
	return {}


## Live HQ hex. The HQ is a unit and can march, so the hex captured by setup_fixed is only a
## fallback: every path query must use where the HQ actually stands now.
func hq_hex(units: Dictionary, faction: String) -> Vector2i:
	var hq := _hq_of(units, faction)
	if not hq.is_empty():
		return Vector2i(int(hq["q"]), int(hq["r"]))
	if fixed.has(faction):
		return Vector2i(fixed[faction].get("hq", Vector2i(9999, 9999)))
	return Vector2i(9999, 9999)


## Fixed edge lines: [[Vector2i,...] per edge base]. Each edge base joins the network at the
## closest cell it can reach - the HQ (no base built yet) or the first base - and hooks onto an
## existing supply line (T-junction) when that line passes closer than the anchor itself.
func fixed_paths(faction: String, units: Dictionary = {}) -> Array:
	var out: Array = []
	if not fixed.has(faction):
		return out
	var a := anchor_of(faction)
	var goal: Vector2i
	if a.is_empty():
		# 2026-11-01: building a base is no longer a prerequisite for supply. An edge base that
		# already sits inside the link range of the HQ is supplied, so its line is drawn straight
		# to the HQ. (Before this the whole network stayed hidden until the first base was built.)
		if units.is_empty():
			goal = Vector2i(fixed[faction].get("hq", Vector2i(9999, 9999)))
		else:
			goal = hq_hex(units, faction)
	else:
		goal = Vector2i(int(a["q"]), int(a["r"]))
	for e in fixed[faction]["entries"]:
		# every line starts AT its supply base and runs straight to the anchor / HQ (no hooking onto other lines)
		if dist(e.x, e.y, goal.x, goal.y) > edge_link:
			continue
		out.append(hex_line(e, goal))
	return out


func _root_sources(units: Dictionary, faction: String) -> Array:
	var hq := _hq_of(units, faction)
	var hqh := hq_hex(units, faction)
	if fixed.has(faction):
		var a := anchor_of(faction)
		if a.is_empty():
			# nothing built yet: the HQ carries its own supply radius; the edge bases stand where they are
			var base_src: Array = (fixed[faction]["entries"] as Array).duplicate()
			if not hq.is_empty():
				base_src.append(hqh)
			return base_src
		var cells: Array = []
		for p in fixed_paths(faction, units):
			for c in p:
				if not cells.has(c):
					cells.append(c)
		# every built base is a supply source (they chain to each other and to the HQ even when no edge line reaches them)
		for n in nodes:
			if str(n["faction"]) == faction:
				var nh := Vector2i(int(n["q"]), int(n["r"]))
				if not cells.has(nh):
					cells.append(nh)
		# the HQ is a source in its own right: it keeps its radius even after marching away
		if not hq.is_empty() and not cells.has(hqh):
			cells.append(hqh)
		return cells
	if hq.is_empty():
		return []
	return [hqh]


## Connected sources of a faction: HQ plus every node reachable by link chain.
func connected_sources(units: Dictionary, faction: String) -> Array:
	var src: Array = _root_sources(units, faction)
	if src.is_empty():
		return []
	var pending: Array = []
	for n in nodes:
		if str(n["faction"]) == faction:
			pending.append(n)
	var grew := true
	while grew:
		grew = false
		for n in pending.duplicate():
			for s in src:
				if dist(int(n["q"]), int(n["r"]), s.x, s.y) <= link_r:
					src.append(Vector2i(int(n["q"]), int(n["r"])))
					pending.erase(n)
					grew = true
					break
	return src


## Link edges of the connected chain: each base links to the nearest earlier source.
func link_edges(units: Dictionary, faction: String) -> Array:
	# Every line starts at a SUPPLY BASE (an edge base or a base the HQ built) and ends at the thing it supplies: another base or
	# the HQ. Lines never start on the HQ or in the middle of another line.
	var hq := _hq_of(units, faction)
	var has_hq := not hq.is_empty()
	var hqh := hq_hex(units, faction) if has_hq else Vector2i(9999, 9999)
	var bases: Array = []
	if fixed.has(faction):
		for e in fixed[faction]["entries"]:
			bases.append(Vector2i(e))
	var anchor := anchor_of(faction)
	if not anchor.is_empty():
		bases.append(Vector2i(int(anchor["q"]), int(anchor["r"])))
	var pending: Array = []
	for n in nodes:
		if str(n["faction"]) == faction and n != anchor:
			pending.append(n)
	var edges: Array = []
	var grew := true
	while grew:
		grew = false
		for n in pending.duplicate():
			var to := Vector2i(int(n["q"]), int(n["r"]))
			var best := 999
			var best_s := Vector2i.ZERO
			for b in bases:
				var dd := dist(to.x, to.y, b.x, b.y)
				if dd < best:
					best = dd
					best_s = b
			if best <= link_r:
				edges.append({"from": best_s, "to": to, "len": best})
				bases.append(to)
				pending.erase(n)
				grew = true
			elif has_hq and dist(to.x, to.y, hqh.x, hqh.y) <= link_r:
				edges.append({"from": to, "to": hqh, "len": dist(to.x, to.y, hqh.x, hqh.y), "hq": true})
				bases.append(to)
				pending.erase(n)
				grew = true
	# the HQ wherever it stands now: one line from the closest built base, unless a base already reaches it
	if has_hq and not anchor.is_empty():
		var linked := false
		for e in edges:
			if bool(e.get("hq", false)):
				linked = true
		var on_base := false
		var best_b := Vector2i.ZERO
		var best_d := 999
		for n in nodes:
			if str(n["faction"]) != faction:
				continue
			var nh := Vector2i(int(n["q"]), int(n["r"]))
			if nh == hqh:
				on_base = true
			var d2 := dist(hqh.x, hqh.y, nh.x, nh.y)
			if d2 < best_d:
				best_d = d2
				best_b = nh
		if not linked and not on_base and best_d <= link_r:
			edges.append({"from": best_b, "to": hqh, "len": best_d, "hq": true})
	return edges


## Hexes inside the healing (near) radius of a faction's connected sources.
func near_cells(units: Dictionary, faction: String) -> Dictionary:
	var out: Dictionary = {}
	for src in connected_sources(units, faction):
		for dq in range(-near_r, near_r + 1):
			for dr in range(maxi(-near_r, -dq - near_r), mini(near_r, -dq + near_r) + 1):
				var c := Vector2i(src.x + dq, src.y + dr)
				if maxi(abs(c.x), maxi(abs(c.y), abs(c.x + c.y))) <= map_radius:
					out[c] = true
	return out


func zone_of(units: Dictionary, faction: String, q: int, r: int) -> String:
	var best := 999
	for s in connected_sources(units, faction):
		best = mini(best, dist(q, r, s.x, s.y))
	if best <= near_r:
		return "near"
	if best <= normal_r:
		return "normal"
	return "out"


func node_at(q: int, r: int) -> Dictionary:
	for n in nodes:
		if int(n["q"]) == q and int(n["r"]) == r:
			return n
	return {}


## Why the HQ cannot drop a base now ("" = it can).
func place_block_reason(units: Dictionary, faction: String) -> String:
	var hq := _hq_of(units, faction)
	if hq.is_empty():
		return "no HQ"
	if int(stock.get(faction, 0)) <= 0:
		return "no base stock"
	var q := int(hq["q"])
	var r := int(hq["r"])
	if not node_at(q, r).is_empty():
		return "base already here"
	if fixed.has(faction) and anchor_of(faction).is_empty():
		# first base: allowed as soon as ONE edge base is inside the link distance (the line the player sees)
		for e in fixed[faction]["entries"]:
			if dist(q, r, e.x, e.y) <= edge_link:
				return ""
		return "out of link range"
	for s in connected_sources(units, faction):
		if dist(q, r, s.x, s.y) <= link_r:
			return ""
	return "out of link range"


## HQ drops a base on its own hex (cost: 1 stock).
func place_node(units: Dictionary, faction: String) -> Dictionary:
	var why := place_block_reason(units, faction)
	if why != "":
		return {"success": false, "error": why}
	var hq := _hq_of(units, faction)
	var q := int(hq["q"])
	var r := int(hq["r"])
	stock[faction] = int(stock[faction]) - 1
	var n := {"id": "%s_BASE_%d" % [faction.to_upper(), _next_id], "faction": faction, "q": q, "r": r, "raid_by": "", "raid_turn": -1, "hp": RulesCls.BASE_HP, "hp_max": RulesCls.BASE_HP}
	_next_id += 1
	nodes.append(n)
	return {"success": true, "node": n}


## Damage a base; returns true when it is destroyed (removed from the network).
func damage_node(n: Dictionary, amount: int) -> bool:
	n["hp"] = maxi(0, int(n.get("hp", RulesCls.BASE_HP)) - amount)
	if int(n["hp"]) <= 0:
		nodes.erase(n)
		return true
	return false


## Enemy bases a unit at (q,r) with `reach` can hit (hex distance 1..reach).
func bases_in_reach(faction: String, q: int, r: int, reach: int) -> Array:
	var out: Array = []
	for n in nodes:
		if str(n["faction"]) == faction:
			continue
		var d := dist(q, r, int(n["q"]), int(n["r"]))
		if d >= 1 and d <= reach:
			out.append(n)
	return out


## The links between a faction's edge bases and `node`: the fixed edge lines (to the first base) plus the
## chain of base-to-base links leading to it. Shown when that base is hovered / clicked.
func chain_to(units: Dictionary, faction: String, node: Dictionary) -> Dictionary:
	var edges_all: Array = link_edges(units, faction)
	var chain: Array = []
	var cur := Vector2i(int(node["q"]), int(node["r"]))
	var guard := 0
	while guard < 64:
		guard += 1
		var found := false
		for e in edges_all:
			if e["to"] == cur:
				if e["from"] == cur:
					break   # the first base hangs on the root itself (zero-length link)
				chain.append(e)
				cur = e["from"]
				found = true
				break
		if not found:
			for e in edges_all:
				if bool(e.get("hq", false)) and e["from"] == cur:
					chain.append(e)
					break
			break
	return {"edges": chain, "fixed": fixed_paths(faction, units)}


func destroy_node(unit: Dictionary) -> Dictionary:
	var n := node_at(int(unit["q"]), int(unit["r"]))
	if n.is_empty() or str(n["faction"]) == str(unit["faction"]):
		return {"success": false, "error": "no enemy base on this hex"}
	nodes.erase(n)
	return {"success": true, "destroyed": n["id"]}


## Raid an enemy base on the unit's hex (resolves at next tick, +1 stock) or a town (+3).
func begin_raid(unit: Dictionary, turn: int, town_terrain: bool) -> Dictionary:
	var q := int(unit["q"])
	var r := int(unit["r"])
	var n := node_at(q, r)
	if not n.is_empty() and str(n["faction"]) != str(unit["faction"]):
		n["raid_by"] = str(unit["id"])
		n["raid_turn"] = turn
		return {"success": true, "kind": "base"}
	var key := "%d,%d" % [q, r]
	if town_terrain and towns.has(key) and int(towns[key]["stock"]) > 0:
		towns[key]["raid_by"] = str(unit["id"])
		towns[key]["raid_turn"] = turn
		return {"success": true, "kind": "town"}
	return {"success": false, "error": "nothing to raid here"}


## Any hit on a raider cancels its raid, even if it survives.
func on_unit_attacked(unit_id: String) -> void:
	for n in nodes:
		if str(n["raid_by"]) == unit_id:
			n["raid_by"] = ""
	for k in towns:
		if str(towns[k]["raid_by"]) == unit_id:
			towns[k]["raid_by"] = ""


## Resolve raids started by `faction` that survived one full opposing phase.
func resolve_raids(units: Dictionary, turn: int, faction: String) -> Array:
	var events: Array = []
	for n in nodes.duplicate():
		var rid := str(n["raid_by"])
		if rid == "" or int(n["raid_turn"]) >= turn:
			continue
		var ru: Dictionary = units.get(rid, {})
		if ru.is_empty() or str(ru.get("faction", "")) != faction:
			continue
		if int(ru.get("soldier_count", 0)) <= 0 or int(ru["q"]) != int(n["q"]) or int(ru["r"]) != int(n["r"]):
			n["raid_by"] = ""
			continue
		nodes.erase(n)
		stock[faction] = int(stock.get(faction, 0)) + 1
		events.append("raid_base %s by %s" % [n["id"], rid])
	for k in towns:
		var t: Dictionary = towns[k]
		var rid2 := str(t["raid_by"])
		if rid2 == "" or int(t["raid_turn"]) >= turn:
			continue
		var tu: Dictionary = units.get(rid2, {})
		if tu.is_empty() or str(tu.get("faction", "")) != faction:
			continue
		if int(tu.get("soldier_count", 0)) <= 0 or "%d,%d" % [int(tu["q"]), int(tu["r"])] != k:
			t["raid_by"] = ""
			continue
		stock[faction] = int(stock.get(faction, 0)) + int(t["stock"])
		events.append("plunder_town %s +%d by %s" % [k, int(t["stock"]), rid2])
		t["stock"] = 0
		t["raid_by"] = ""
	return events


## Called once per full round (after both phases). Blue raids resolve here
## (they faced one red phase); red raids resolve at the start of red's next phase.
func tick(units: Dictionary, turn: int) -> Array:
	var events: Array = resolve_raids(units, turn, "blue")
	# 2) zone effects on every unit
	for id in units:
		var u: Dictionary = units[id]
		var hp := int(u.get("soldier_count", 0))
		if hp <= 0 or bool(u.get("garrisoned", false)):
			continue
		var f := str(u.get("faction", ""))
		if f != "blue" and f != "red":
			continue
		var z := zone_of(units, f, int(u["q"]), int(u["r"]))
		u["supply_zone"] = z
		var mx := int(u.get("max_count", hp))
		var m := float(u.get("morale", 100.0))
		match z:
			"near":
				u["soldier_count"] = mini(mx, hp + maxi(1, roundi(mx * RulesCls.NEAR_HEAL_FRAC)))
				m = minf(100.0, m + RulesCls.NEAR_MORALE)
			"normal":
				m = minf(100.0, m + RulesCls.NORMAL_MORALE)
			"out":
				m = maxf(0.0, m + RulesCls.OUT_MORALE)
		u["morale"] = m
		if m <= RulesCls.MORALE_BROKEN and str(u.get("class", "")) != "hq" and _rng.randf() < RulesCls.DESERT_P:
			var lost := maxi(1, roundi(mx * RulesCls.DESERT_FRAC))
			u["soldier_count"] = maxi(1, int(u["soldier_count"]) - lost)
			events.append("desert %s -%d" % [id, lost])
	return events
