extends RefCounted

## Commander support for mission maps (2026-10-09): terrain-aware movement costs for path choice and eta facts, and
## the mission's rules / state as the commander is told them. Facts only: what a player sees on the map and the
## rules the game applies (scripts/gx_missions/mission_rules.gd judges the match).

const ConfigCls = preload("res://scripts/core/step3_config.gd")
const DIRS := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1), Vector2i(1, -1), Vector2i(-1, 1)]
const NAMES := {0: "plains", 1: "mountain", 2: "forest", 3: "swamp", 4: "fortress", 5: "village", 6: "road", 7: "river",
	8: "wall", 9: "stronghold", 10: "stronghold wall", 11: "citadel", 12: "citadel wall", 13: "mountain"}
const INF := 1.0e9

var terrain := {}   # Vector2i -> terrain id
var river := {}     # Vector2i -> true
var footprint := {} # Vector2i -> stronghold id (entered only by its garrison)


func setup(battlefield: Dictionary) -> void:
	terrain.clear()
	river.clear()
	footprint.clear()
	for key in (battlefield.get("terrain", {}) as Dictionary).keys():
		var p := str(key).split(",")
		terrain[Vector2i(int(p[0]), int(p[1]))] = int(battlefield["terrain"][key])
	for key in (battlefield.get("river", {}) as Dictionary).keys():
		var p2 := str(key).split(",")
		river[Vector2i(int(p2[0]), int(p2[1]))] = true
	for sd in battlefield.get("strongholds", []):
		for h in (sd as Dictionary).get("footprint", []):
			footprint[h if h is Vector2i else Vector2i(int(h[0]), int(h[1]))] = str(sd.get("id", ""))


func active() -> bool:
	return not terrain.is_empty()


func name_of(h: Vector2i) -> String:
	if river.has(h) and int(terrain.get(h, 0)) != 6:
		return "river"
	return str(NAMES.get(int(terrain.get(h, 0)), "plains"))


## Cost of entering hex h for a unit of class cls (INF = cannot enter).
func cost(h: Vector2i, cls: String) -> float:
	if not terrain.has(h) or footprint.has(h):
		return INF
	var t := int(terrain[h])
	if ConfigCls.is_impassable(t) or t >= 11:
		return INF
	return ConfigCls.get_terrain_cost(t, cls.to_lower())


## Movement cost from every hex to dest (Dijkstra out from dest; blocked hexes, e.g. other units, are skipped).
func field(dest: Vector2i, cls: String, blocked: Dictionary = {}) -> Dictionary:
	var dist := {dest: 0.0}
	var frontier: Array = [[0.0, dest]]
	while not frontier.is_empty():
		var bi := 0
		for i in range(1, frontier.size()):
			if float(frontier[i][0]) < float(frontier[bi][0]):
				bi = i
		var top: Array = frontier[bi]
		frontier.remove_at(bi)
		var d := float(top[0])
		var cur: Vector2i = top[1]
		if d > float(dist.get(cur, INF)):
			continue
		# A unit at nxt reaching cur pays the cost of entering cur (the destination itself counts 1).
		var enter := 1.0 if cur == dest else cost(cur, cls)
		if enter >= INF:
			continue
		for dv in DIRS:
			var nxt: Vector2i = cur + dv
			if blocked.has(nxt) or not terrain.has(nxt):
				continue
			var nd := d + enter
			if nd < float(dist.get(nxt, INF)):
				dist[nxt] = nd
				frontier.append([nd, nxt])
	return dist


## Turns of movement until a unit at p is within `reach` hexes of the field's destination (approximation: the last
## `reach` steps count 1 each); -1 when it cannot get there.
static func eta_from(fieldmap: Dictionary, p: Vector2i, reach: int, mp: int) -> int:
	if not fieldmap.has(p):
		return -1
	return int(ceil(maxf(0.0, float(fieldmap[p]) - float(reach)) / float(maxi(1, mp))))


## WIN / LOSE text for one side (written as RED; the commander swaps sides in the prompt for a BLUE commander).
static func mission_prompt(m: Dictionary, my_side: String) -> String:
	var fam := str(m.get("family", ""))
	var role := str((m.get("roles", {}) as Dictionary).get(my_side, "none"))
	var lim := int(m.get("round_limit", 0))
	var s := ""
	match fam:
		"M1":
			if role == "attacker":
				s = "WIN: take the village (the \"village\" hexes): 2 or more of your units in it and no BLUE unit in it, at the end of 2 rounds in a row. LOSE: it is not taken by round %d." % lim
			else:
				s = "WIN: keep the village (the \"village\" hexes) until round %d ends: BLUE takes it with 2 or more units in it and none of yours in it, at the end of 2 rounds in a row. LOSE: it is taken." % lim
		"M2", "M5":
			var sid := str(m.get("stronghold_id", ""))
			if role == "attacker":
				s = "WIN: capture the stronghold \"%s\": ASSAULT damages its walls; once they are breached, ASSAULT hits its garrison; it is yours when breached with no garrison left. LOSE: not captured by round %d." % [sid, lim]
			else:
				s = "WIN: your stronghold \"%s\" is still yours when round %d ends. LOSE: BLUE captures it (walls breached and no garrison left)." % [sid, lim]
		"M3":
			s = "WIN: BLUE's army collapses (below). If neither side has won by round %d, you have failed." % lim
		"M4":
			s = "WIN: hold all 3 sites (the \"sites\" hexes) at the end of 3 rounds in a row, or more sites than BLUE (at least 2) when round %d ends. A site is held by the side whose logistics base stands on it (your HQ builds one there)." % lim
	s += "\nAlso: your HQ destroyed = LOSE (BLUE's HQ destroyed = WIN). A side whose soldiers fall to 30% of its starting soldiers or less loses at the end of that round (army collapse)."
	s += "\nSupply: your HQ must keep a logistics base it can reach: the HQ builds one on its own hex (BUILD_BASE, not in a turn it moved). A BLUE field unit entering a base destroys it. Your supply is cut while you have no base or a BLUE unit stands on the shortest path from your HQ to each of your bases; after 15 rounds cut you LOSE (the count restarts once reconnected)."
	s += "\n\"rounds_left\" = rounds left including this one; the match is judged at the end of each round."
	return s


const BOARD_TEXT := "Board: the hexes of the map, axial (q, r); distance = (|dq| + |dr| + |dq + dr|) / 2. Moving into a hex costs movement points: plains/village 1, road 0.5, forest and swamp 2, mountain 3 (a SCOUT: forest and mountain 1, swamp 1.5). Walls, stronghold and citadel hexes cannot be entered (a garrison enters its own stronghold with GARRISON). A move into or out of a river hex ends that unit's movement for the turn; a road across a river is a bridge. \"terrain\" (first message) lists the walls, rivers and the objective hexes; your units show the terrain they stand on."


## The mission part of the state for one side: role, round, objective state, supply of both sides, bases.
static func mission_view(st: Dictionary, my_side: String) -> Dictionary:
	var foe := "blue" if my_side == "red" else "red"
	var v := {"family": st.get("family", ""), "role": str((st.get("roles", {}) as Dictionary).get(my_side, "none")),
		"round": st.get("round", 0), "round_limit": st.get("round_limit", 0), "rounds_left": st.get("rounds_left", 0)}
	var sup: Dictionary = st.get("supply", {})
	for pair in [["my_supply", my_side], ["enemy_supply", foe]]:
		var s: Dictionary = sup.get(pair[1], {})
		var row := {"connected": s.get("connected", false), "has_base": s.get("has_base", false)}
		if bool(s.get("countdown_active", false)):
			row["cut_rounds_left"] = s.get("turns_left", 0)
		v[pair[0]] = row
	var sol: Dictionary = st.get("soldiers", {})
	var line: Dictionary = st.get("collapse_line", {})
	v["my_soldiers"] = {"now": (sol.get(my_side, {}) as Dictionary).get("now", 0), "collapse_at": line.get(my_side, 0)}
	v["bases"] = (st.get("bases", []) as Array).map(func(b): return {"owner": b["owner"], "hex": b["hex"]})
	if st.has("village"):
		var vi: Dictionary = st["village"]
		v["village"] = {"hexes": vi.get("hexes", []), "attacker_units": vi.get("attacker_units", 0),
			"defender_units": vi.get("defender_units", 0), "hold_streak": vi.get("hold_streak", 0)}
	if st.has("sites"):
		v["sites"] = st["sites"]
		v["site_streak"] = st.get("site_streak", {})
	if st.has("stronghold"):
		var sh: Dictionary = st["stronghold"]
		v["stronghold"] = {"id": sh.get("id", ""), "owner": sh.get("owner", ""), "walls": sh.get("wall_hp", 0),
			"walls_max": sh.get("wall_hp_max", 0), "breached": sh.get("breached", false), "garrison": sh.get("garrison", 0),
			"hexes": sh.get("footprint", [])}
	return v
