class_name Cloud2BrainContext
extends RefCounted

## CONTEXTUAL BRAIN V0 — Brain-visible context pack (INPUT ONLY).
##
## PLAN = f(observed battlefield, CURRENT ruleset, CURRENT forces, CURRENT
## map, CURRENT game mode). This builder makes the last four explicit so the
## Brain can condition on them instead of memorizing one balance.
##
## Sources (nothing copied, nothing hidden):
##   rules   -> the SAME engine accessors combat/movement use (Step3Config /
##              CombatCalculator), which read EpisodeRuntime (Track B) when an
##              episode is installed and the stock tables otherwise.
##   forces  -> the acting side's fog-projected observation only (friendly
##              truth + known enemy contacts). Never WorldTruth / spec armies.
##   map     -> public terrain: the caller's terrain dict, else the catalog
##              battlefield named by obs.episode_context.map.id, else none.
##   mode    -> obs.mission (sim-evaluated contract) + episode objective.
## Derived values are deterministic facts (ranks, ratios, path costs, turn
## estimates). No tactical recommendation is emitted.
##
## Gate: env BRAIN_CONTEXT_PACK=v0. Unset = packets byte-identical to before.
## The Brain OUTPUT contract (unalloc_v1) is untouched by this file.

const Step3ConfigCls = preload("res://scripts/core/step3_config.gd")
const CombatCalculatorCls = preload("res://scripts/combat/combat_calculator.gd")
const EpisodeRuntimeCls = preload("res://scripts/episodes/episode_runtime.gd")
const CatalogCls = preload("res://scripts/battlefields/battlefield_catalog.gd")
const ScopeAlgebraCls = preload("res://scripts/step7/step7_scope_algebra.gd")

const VERSION := "brain_context_v0"
const ENV := "BRAIN_CONTEXT_PACK"
const SECTORS := ["NORTH", "CENTER", "SOUTH", "WEST", "EAST"]
const TERRAIN_NAMES := {0: "plains", 1: "mountain", 2: "forest", 3: "marsh", 4: "fortress",
	5: "village", 6: "road", 7: "river", 8: "wall", 9: "stronghold", 10: "stronghold_wall", 11: "capital"}
## Axial neighbours; index i and i+3 are opposite.
const HEX_DIRS := [Vector2i(1, 0), Vector2i(1, -1), Vector2i(0, -1), Vector2i(-1, 0), Vector2i(-1, 1), Vector2i(0, 1)]
const Q := 4  # path costs in quarter-MP units (engine costs are multiples of 0.25)

static var _catalog_cache := {}


static func enabled() -> bool:
	return OS.get_environment(ENV).strip_edges().to_lower() == "v0"


## terrain: {"q,r" or Vector2i: terrain id}; {} = resolve from the episode map.
static func build(obs: Dictionary, side: String = "red", terrain: Dictionary = {}) -> Dictionary:
	var friends: Array = obs.get("friendly_units", [])
	var enemies: Array = obs.get("known_enemy_units", [])
	var present := _present_classes(friends, enemies)
	var cells := _cells(terrain if not terrain.is_empty() else terrain_for(obs))
	var bounds := _bounds(obs, cells)
	var ep: Dictionary = obs.get("episode_context", {})
	return {
		"version": VERSION,
		"episode": {"id": str(ep.get("episode_id", "")).left(16), "family": str(ep.get("family", "")),
			"map": str((ep.get("map", {}) as Dictionary).get("id", ""))} if not ep.is_empty() else {},
		"rules": _rules(present, cells),
		"forces": _forces(friends, enemies, bounds),
		"map": _map(cells, friends, enemies, bounds),
		"mode": _mode(obs, side),
	}


## Public catalog terrain for the installed episode map ({} when none).
static func terrain_for(obs: Dictionary) -> Dictionary:
	var map_id := str(((obs.get("episode_context", {}) as Dictionary).get("map", {}) as Dictionary).get("id", ""))
	if map_id.is_empty() or not CatalogCls.has_battlefield(map_id):
		return {}
	if not _catalog_cache.has(map_id):
		_catalog_cache[map_id] = (CatalogCls.load_battlefield(map_id).get("terrain", {}) as Dictionary)
	return _catalog_cache[map_id]


# --- rules ------------------------------------------------------------------

static func _key(cls: String) -> String:
	return CombatCalculatorCls.normalize_class_name(cls)


static func _label(cls: String) -> String:
	return cls.strip_edges().to_upper()


static func _present_classes(friends: Array, enemies: Array) -> Array:
	var seen := {}
	for rows in [friends, enemies]:
		for u in rows:
			var c := str((u as Dictionary).get("class", "")).to_lower()
			if not c.is_empty() and c != "unknown":
				seen[c] = true
	var out: Array = seen.keys()
	out.sort()
	return out


static func _stats(cls: String) -> Dictionary:
	# Same lookup calculate_combat uses (episode class_stats, else BASE_STATS).
	var table: Dictionary = EpisodeRuntimeCls.rules().get("class_stats", CombatCalculatorCls.BASE_STATS)
	var row: Dictionary = table.get(_key(cls), {"attack": 10.0, "defense": 10.0})
	return {"mp": snappedf(Step3ConfigCls.get_base_movement(_key(cls)), 0.01),
		"atk": snappedf(float(row.get("attack", 10.0)), 0.01),
		"def": snappedf(float(row.get("defense", 10.0)), 0.01),
		"rng": CombatCalculatorCls.get_attack_range(cls)}


## Dense rank, 1 = highest value, among the classes present in THIS battle.
static func _rank(rows: Dictionary, field: String) -> Dictionary:
	var vals: Array = []
	for k in rows.keys():
		var v: float = float((rows[k] as Dictionary)[field])
		if not vals.has(v):
			vals.append(v)
	vals.sort()
	vals.reverse()
	var out := {}
	for k in rows.keys():
		out[k] = vals.find(float((rows[k] as Dictionary)[field])) + 1
	return out


static func _rules(present: Array, cells: Dictionary) -> Dictionary:
	var rows := {}
	for c in present:
		rows[_label(c)] = _stats(c)
	for field in ["mp", "atk", "def", "rng"]:
		var ranks := _rank(rows, field)
		for k in rows.keys():
			(rows[k] as Dictionary)[field + "_rank"] = ranks[k]
	var matchups: Array = []
	for a in present:
		for b in present:
			if a == b:
				continue
			var m := CombatCalculatorCls.get_matchup_mult(a, b)
			if m > 1.001:
				matchups.append([_label(a), _label(b), snappedf(m, 0.01)])
	# Terrain cost per class group, only for terrain present on this map.
	var ids := {}
	for t in cells.values():
		ids[int(t)] = true
	var id_list: Array = ids.keys()
	id_list.sort()
	var groups := {}
	for c in present:
		var costs := {}
		for t in id_list:
			var cost := Step3ConfigCls.get_terrain_cost(t, _key(c))
			costs[str(TERRAIN_NAMES.get(t, str(t)))] = "blocked" if Step3ConfigCls.is_impassable(t) or cost >= 99.0 else snappedf(cost, 0.01)
		var sig := JSON.stringify(costs)
		if not groups.has(sig):
			groups[sig] = {"classes": [], "cost": costs}
		(groups[sig]["classes"] as Array).append(_label(c))
	return {"classes": rows, "matchups": matchups, "terrain_cost": groups.values(),
		"note": "ranks: 1 = highest value among classes in this battle; matchups list attacker>defender multipliers above 1."}


# --- forces -----------------------------------------------------------------

## Midpoint of a fog troop band ("병력: 200~300", "약 250"); 0 = unknown.
static func troop_estimate(text: String) -> int:
	var clean := text.replace(",", "")
	if clean.strip_edges().is_valid_int():
		return int(clean)
	var vals: Array = []
	for seg in clean.split("~"):
		var digits := ""
		for ch in seg:
			if ch >= "0" and ch <= "9":
				digits += ch
		if not digits.is_empty():
			vals.append(int(digits))
	if vals.size() >= 2:
		return int((vals[0] + vals[1]) / 2)
	return vals[0] if vals.size() == 1 else 0


static func _forces(friends: Array, enemies: Array, bounds: Dictionary) -> Dictionary:
	var own := {"n": 0, "soldiers": 0, "by_class": {}, "ranged_soldiers": 0, "mp_sum": 0.0}
	var vis := {"n": 0, "est": 0, "unestimated": 0, "by_class": {}, "ranged_n": 0, "mp_sum": 0.0}
	var stale := {"n": 0, "by_class": {}}
	var sector := {}
	for s in SECTORS:
		sector[s] = [0, 0]
	for u in friends:
		var c := str(u.get("class", ""))
		var n := int(u.get("soldiers", 0))
		var st := _stats(c)
		own["n"] += 1
		own["soldiers"] += n
		var row: Array = (own["by_class"] as Dictionary).get(_label(c), [0, 0])
		(own["by_class"] as Dictionary)[_label(c)] = [int(row[0]) + 1, int(row[1]) + n]
		if int(st["rng"]) >= 2:
			own["ranged_soldiers"] += n
		own["mp_sum"] += float(st["mp"])
		for s in _sectors_of(int(u.get("q", 0)), int(u.get("r", 0)), bounds):
			sector[s][0] += 1
	for e in enemies:
		var c := str(e.get("class", "unknown"))
		if str(e.get("contact_state", "")) != "current_visible":
			stale["n"] += 1
			(stale["by_class"] as Dictionary)[_label(c)] = int((stale["by_class"] as Dictionary).get(_label(c), 0)) + 1
			continue
		var est := troop_estimate(str(e.get("troop_estimate", "")))
		vis["n"] += 1
		vis["est"] += est
		if est <= 0:
			vis["unestimated"] += 1
		var row2: Array = (vis["by_class"] as Dictionary).get(_label(c), [0, 0])
		(vis["by_class"] as Dictionary)[_label(c)] = [int(row2[0]) + 1, int(row2[1]) + est]
		if c != "unknown":
			var st2 := _stats(c)
			if int(st2["rng"]) >= 2:
				vis["ranged_n"] += 1
			vis["mp_sum"] += float(st2["mp"])
		for s in _sectors_of(int(e.get("q", 0)), int(e.get("r", 0)), bounds):
			sector[s][1] += 1
	var out := {
		"friendly": {"formations": own["n"], "soldiers": own["soldiers"], "by_class": own["by_class"],
			"ranged_share": snappedf(float(own["ranged_soldiers"]) / maxf(1.0, float(own["soldiers"])), 0.01),
			"mean_mp": snappedf(float(own["mp_sum"]) / maxf(1.0, float(own["n"])), 0.01)},
		"enemy_visible": {"formations": vis["n"], "soldiers_est": vis["est"], "unestimated": vis["unestimated"],
			"by_class": vis["by_class"],
			"ranged_formation_share": snappedf(float(vis["ranged_n"]) / float(vis["n"]), 0.01) if int(vis["n"]) > 0 else null,
			"mean_mp": snappedf(float(vis["mp_sum"]) / float(vis["n"]), 0.01) if int(vis["n"]) > 0 else null},
		"enemy_last_known": {"formations": stale["n"], "by_class": stale["by_class"]},
		"visible_soldier_ratio": snappedf(float(own["soldiers"]) / float(vis["est"]), 0.01) if int(vis["est"]) > 0 else null,
		"formations_by_sector": sector,
		"note": "by_class: [formations, soldiers]; enemy soldiers are fog band estimates of VISIBLE contacts only; formations_by_sector: [friendly, enemy_visible].",
	}
	return out


# --- map --------------------------------------------------------------------

## Board rect from the obs; with terrain, vertical extent comes from the real
## cells (hex maps) so sectors agree with the obs region classifier.
static func _bounds(obs: Dictionary, cells: Dictionary) -> Dictionary:
	var b: Dictionary = ((obs.get("board", {}) as Dictionary).get("dimensions", {}) as Dictionary).duplicate(true)
	if not cells.is_empty():
		var lo := 1 << 30
		var hi := -(1 << 30)
		for c in cells.keys():
			lo = mini(lo, 2 * c.y + c.x)
			hi = maxi(hi, 2 * c.y + c.x)
		b["min_vertical"] = lo
		b["max_vertical"] = hi
	return b


static func _sectors_of(q: int, r: int, bounds: Dictionary) -> Array:
	var out: Array = []
	for s in SECTORS:
		if ScopeAlgebraCls.is_in_region(q, r, s, bounds):
			out.append(s)
	return out


static func _cells(terrain: Dictionary) -> Dictionary:
	var out := {}
	for k in terrain.keys():
		if k is Vector2i:
			out[k] = int(terrain[k])
		else:
			var parts := str(k).split(",")
			if parts.size() == 2:
				out[Vector2i(int(parts[0]), int(parts[1]))] = int(terrain[k])
	return out


static func _hex_dist(a: Vector2i, b: Vector2i) -> int:
	return maxi(absi(a.x - b.x), maxi(absi(a.y - b.y), absi((a.x + a.y) - (b.x + b.y))))


## Cost to ENTER a cell in quarter-MP units for one class; -1 = blocked.
static func _qcost(t: int, cls: String) -> int:
	if Step3ConfigCls.is_impassable(t):
		return -1
	var c := Step3ConfigCls.get_terrain_cost(t, _key(cls))
	return -1 if c >= 99.0 else maxi(1, roundi(c * Q))


## Single-source shortest path costs (Dial's bucket queue; costs are small ints).
static func _dijkstra(cells: Dictionary, start: Vector2i, cls: String) -> Dictionary:
	var qc := {}
	for t in cells.values():
		if not qc.has(t):
			qc[t] = _qcost(int(t), cls)
	var dist := {start: 0}
	var buckets := {0: [start]}
	var d := 0
	var max_d := 0
	while d <= max_d:
		if buckets.has(d):
			for cell in buckets[d]:
				if int(dist[cell]) != d:
					continue
				for dir in HEX_DIRS:
					var n: Vector2i = cell + dir
					if not cells.has(n):
						continue
					var step: int = qc[cells[n]]
					if step < 0:
						continue
					var nd := d + step
					if nd < int(dist.get(n, 1 << 30)):
						dist[n] = nd
						if not buckets.has(nd):
							buckets[nd] = []
						(buckets[nd] as Array).append(n)
						max_d = maxi(max_d, nd)
			buckets.erase(d)
		d += 1
	return dist


## Anchor hex of a compass sector (same geometry Hand A uses to map areas).
static func _anchor(sector: String, bounds: Dictionary) -> Vector2i:
	var vb := ScopeAlgebraCls.get_vertical_bounds(bounds)
	var q_min := float(bounds.get("q_min", -10))
	var q_max := float(bounds.get("q_max", 10))
	var v_min := float(vb["min_vertical"])
	var v_max := float(vb["max_vertical"])
	var qc := (q_min + q_max) / 2.0
	var vc := (v_min + v_max) / 2.0
	var q := qc
	var v := vc
	match sector:
		"NORTH":
			v = v_min + (v_max - v_min) / 6.0
		"SOUTH":
			v = v_min + 5.0 * (v_max - v_min) / 6.0
		"WEST":
			q = q_min + (q_max - q_min) / 6.0
		"EAST":
			q = q_min + 5.0 * (q_max - q_min) / 6.0
	return Vector2i(roundi(q), roundi((v - q) / 2.0))


## Nearest passable cell to an anchor (ties by q, r; deterministic).
static func _snap(cells: Dictionary, anchor: Vector2i) -> Vector2i:
	var best := anchor
	var best_d := 1 << 30
	for c in cells.keys():
		if Step3ConfigCls.is_impassable(int(cells[c])):
			continue
		var d := _hex_dist(c, anchor)
		if d < best_d or (d == best_d and (c.x < best.x or (c.x == best.x and c.y < best.y))):
			best = c
			best_d = d
	return best


static func _map(cells: Dictionary, friends: Array, enemies: Array, bounds: Dictionary) -> Dictionary:
	var q_span := int(bounds.get("q_max", 0)) - int(bounds.get("q_min", 0)) + 1
	var r_span := int(bounds.get("r_max", 0)) - int(bounds.get("r_min", 0)) + 1
	var out := {"size_q_r": [q_span, r_span],
		"diameter": _hex_dist(Vector2i(int(bounds.get("q_min", 0)), int(bounds.get("r_max", 0))),
			Vector2i(int(bounds.get("q_max", 0)), int(bounds.get("r_min", 0))))}
	var contact := -1
	for u in friends:
		for e in enemies:
			if str(e.get("contact_state", "")) == "current_visible":
				var dd := _hex_dist(Vector2i(int(u.get("q", 0)), int(u.get("r", 0))), Vector2i(int(e.get("q", 0)), int(e.get("r", 0))))
				contact = dd if contact < 0 else mini(contact, dd)
	out["nearest_visible_contact_hexes"] = contact if contact >= 0 else null
	if cells.is_empty():
		out["terrain_source"] = "none"
		out["note"] = "No terrain data for this battle: treat ground as unknown, not as open plains."
		return out
	out["terrain_source"] = "episode_map"
	# Sector summaries (compass sectors == the Brain's mission areas).
	var agg := {}
	for s in SECTORS:
		agg[s] = {"cells": 0, "blocked": 0, "cost_sum": 0.0, "mix": {}, "gaps": 0}
	for c in cells.keys():
		var t := int(cells[c])
		var blocked := Step3ConfigCls.is_impassable(t)
		var gap := false
		if not blocked:
			for i in range(3):
				var a: Vector2i = c + HEX_DIRS[i]
				var b: Vector2i = c + HEX_DIRS[i + 3]
				if cells.has(a) and cells.has(b) and Step3ConfigCls.is_impassable(int(cells[a])) and Step3ConfigCls.is_impassable(int(cells[b])):
					gap = true
		for s in _sectors_of(c.x, c.y, bounds):
			var row: Dictionary = agg[s]
			row["cells"] += 1
			var name := str(TERRAIN_NAMES.get(t, str(t)))
			row["mix"][name] = int((row["mix"] as Dictionary).get(name, 0)) + 1
			if blocked:
				row["blocked"] += 1
			else:
				row["cost_sum"] += Step3ConfigCls.get_terrain_cost(t, "infantry")
			if gap:
				row["gaps"] += 1
	var sectors := {}
	for s in SECTORS:
		var row: Dictionary = agg[s]
		var n := maxi(1, int(row["cells"]))
		var open_n := maxi(1, int(row["cells"]) - int(row["blocked"]))
		var mix := {}
		for k in (row["mix"] as Dictionary).keys():
			var f := snappedf(float(row["mix"][k]) / float(n), 0.05)
			if f >= 0.05:
				mix[k] = f
		sectors[s] = {"passable": snappedf(1.0 - float(row["blocked"]) / float(n), 0.01),
			"mean_cost_infantry": snappedf(float(row["cost_sum"]) / float(open_n), 0.01),
			"terrain_mix": mix, "gap_hexes": row["gaps"]}
	out["sectors"] = sectors
	# Travel estimates from own HQ to each sector anchor (and to a known enemy HQ).
	var hq := {}
	for u in friends:
		if str(u.get("class", "")) == "hq":
			hq = u
	if hq.is_empty():
		return out
	var start := Vector2i(int(hq.get("q", 0)), int(hq.get("r", 0)))
	var targets := {}
	for s in SECTORS:
		targets[s] = _snap(cells, _anchor(s, bounds))
	# Known contacts only (visible or last-known): nearest per N/C/S band + HQ.
	for e in enemies:
		var p := Vector2i(int(e.get("q", 0)), int(e.get("r", 0)))
		if str(e.get("class", "")) == "hq":
			targets["ENEMY_HQ"] = p
		for sec in _sectors_of(p.x, p.y, bounds):
			var key: String = "NEAREST_ENEMY_" + str(sec)
			if sec in ["NORTH", "CENTER", "SOUTH"] and (not targets.has(key) or _hex_dist(start, p) < _hex_dist(start, targets[key])):
				targets[key] = p
	var classes := {}
	for u in friends:
		var c := str(u.get("class", ""))
		if c != "hq":
			classes[c] = true
	var cls_list: Array = classes.keys()
	cls_list.sort()
	var searches := {}  # classes sharing a terrain-cost table share one search
	var travel := {}
	for t_name in targets.keys():
		var std: Dictionary = _search(searches, cells, start, "infantry")
		var tgt: Vector2i = targets[t_name]
		travel[t_name] = {"hexes": _hex_dist(start, tgt),
			"path_cost_std_terrain": snappedf(float(std[tgt]) / Q, 0.25) if std.has(tgt) else "unreachable",
			"turns": {}}
		for c in cls_list:
			var dist: Dictionary = _search(searches, cells, start, c)
			var mp := maxf(0.25, Step3ConfigCls.get_base_movement(_key(c)))
			travel[t_name]["turns"][_label(c)] = ceili(float(dist[tgt]) / Q / mp) if dist.has(tgt) else "unreachable"
	out["travel_from_own_hq"] = travel
	out["travel_note"] = "From own HQ to each sector anchor and to known enemy contacts. turns = ceil(least path cost / base mp) at normal march, ignoring units; hexes = straight distance; path cost > hexes means terrain detour."
	return out


static func _search(cache: Dictionary, cells: Dictionary, start: Vector2i, cls: String) -> Dictionary:
	var sig := ""
	for t in TERRAIN_NAMES.keys():
		sig += str(_qcost(t, cls)) + ","
	if not cache.has(sig):
		cache[sig] = _dijkstra(cells, start, cls)
	return cache[sig]


# --- mode -------------------------------------------------------------------

## Side-relative terminal conditions. Mirrors SimController.evaluate_mission
## (BLUE-authored objective codes; RED wins exactly when BLUE loses).
## ponytail: mirrored table, drifts if evaluate_mission changes; Track B's
## EpisodeSpec.objective should become the single source (see TRACK_B.md).
static func _mode(obs: Dictionary, side: String) -> Dictionary:
	var m: Dictionary = obs.get("mission", {})
	var code := str(m.get("type", "destroy_all_red"))
	var limit := int(m.get("turn_limit", 0))
	var turn := int(obs.get("turn", 0))
	var red := side.strip_edges().to_lower() == "red"
	var win: Array = ["ENEMY_HQ_DESTROYED", "ALL_ENEMY_FORMATIONS_DESTROYED"]
	var lose: Array = ["OWN_HQ_DESTROYED", "ALL_OWN_FORMATIONS_DESTROYED"]
	var at_limit := "DRAW_EXPIRED"
	match code:
		"capture_capital":
			if red:
				lose.append("OWN_CAPITAL_BREACHED_OR_TAKEN")
			else:
				win.append("ENEMY_CAPITAL_BREACHED_OR_TAKEN")
		"survive_turns", "hold_hq":
			at_limit = "LOSS_IF_ENEMY_HQ_ALIVE" if red else "WIN_IF_OWN_HQ_ALIVE"
	var ep_obj: Dictionary = (obs.get("episode_context", {}) as Dictionary).get("objective", {})
	return {"objective_code": code, "episode_mode": str(ep_obj.get("mode", "")),
		"win_if_any": win, "lose_if_any": lose,
		"turn_limit": limit if limit > 0 else null,
		"turns_left": maxi(0, limit - turn + 1) if limit > 0 else null,
		"at_turn_limit": at_limit if limit > 0 else "NO_LIMIT"}
