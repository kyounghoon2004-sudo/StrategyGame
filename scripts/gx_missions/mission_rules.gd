extends Node

## GX MISSIONS v1 — MissionRules: the Godot authority for mission outcomes (attached at runtime).
##
## The only judge. GX and the Brain read `mission_state` (read-only copy), never decide.
## Evaluated at the end of each round, order: HQ -> collapse -> supply-cut countdown -> mission -> round limit.
## Collapse = field army soldiers (HQ excluded) <= collapse_frac x the field army at start.
## HQ sudden death stays the existing shell hook (_on_s6_unit_destroyed); this node only records it first.
## Logistics (see the Logistics section): a fixed head base per side off the board behind its starting HQ;
## HQ-built bases (build cooldown, 2 enemy entries to destroy); nodes within the link range R (path length)
## link into a mesh; the HQ is supplied while a node linked to the head is within R of it, otherwise supply
## is cut (15-round countdown). Every distance follows the map diameter (MissionConfig.set_map_diameter).
## Morale switch per mission: flips the SandboxRules runtime flag that gates the live morale path
## (combat_calculator morale modifier / shock, march penalty); no rout anywhere.
## Strongholds in the sandbox: registered at runtime into the live StrongholdManager from the mission block.

const CfgCls = preload("res://scripts/gx_missions/mission_config.gd")
const ScenarioCls = preload("res://scripts/gx_missions/mission_scenario.gd")
const SandboxRulesCls = preload("res://scripts/core/sandbox_rules.gd")
const StrongholdCls = preload("res://scripts/core/stronghold.gd")
const HexUtilsCls = preload("res://scripts/core/hex_utils.gd")
const Step3ConfigCls = preload("res://scripts/core/step3_config.gd")

const DIRS: Array[Vector2i] = [Vector2i(1, 0), Vector2i(1, -1), Vector2i(0, -1),
	Vector2i(-1, 0), Vector2i(-1, 1), Vector2i(0, 1)]
const SIDES := ["red", "blue"]

signal outcome_decided(outcome: Dictionary)

var shell: Node
var manager: RefCounted
var mission: Dictionary = {}
var rules_cfg: Dictionary = {}
var start_soldiers := {"red": 0, "blue": 0}
var bases: Dictionary = {}          # base_id -> {id, owner, hex: Vector2i, built_round}
var _base_seq := 0
var cut_since := {"red": -1, "blue": -1}
var morale_zone := {}  # uid -> {side, zone, rounds} for HQ-distance morale
var _prev_rout_allowed := true
var village_streak := 0
var site_streak := {"red": 0, "blue": 0}
var last_round := 0
var outcome: Dictionary = {}
var mission_state: Dictionary = {}
var events: Array = []
var _prev_sandbox_flag := true
var _morale_switched := false
## End the shell battle on a decided winner (BLUE point of view flags). Tests may turn it off.
var drive_shell_terminal := true


func setup(host_shell: Node, mission_block: Dictionary) -> Dictionary:
	shell = host_shell
	manager = shell.get("unit_manager") as RefCounted
	CfgCls.set_map_diameter(int(mission_block.get("map_diameter", map_diameter())))
	rules_cfg = CfgCls.section("rules")
	mission = ScenarioCls.normalize(mission_block)
	if mission.has("error"):
		return {"ok": false, "error": str(mission["error"])}
	start_soldiers = soldiers_now()
	_init_heads()
	_apply_unit_mp()
	if mission["family"] in ["M2", "M5"]:
		var err := _install_stronghold()
		if not err.is_empty():
			return {"ok": false, "error": err}
	_prev_sandbox_flag = SandboxRulesCls.is_active()
	# Morale ON = the live morale path (gated by SandboxRules.morale_rout_enabled) runs; OFF = frozen.
	SandboxRulesCls.set_active(not bool(mission["morale"]))
	_prev_rout_allowed = SandboxRulesCls.is_rout_allowed()
	if bool(mission["morale"]):
		SandboxRulesCls.set_rout_allowed(false)
	_morale_switched = true
	manager.connect("unit_moved", _on_unit_moved)
	manager.connect("unit_destroyed", _on_unit_destroyed)
	publish()
	return {"ok": true, "mission": mission.duplicate(true)}


func _exit_tree() -> void:
	CfgCls.clear_map()
	if _morale_switched:
		SandboxRulesCls.set_active(_prev_sandbox_flag)
		SandboxRulesCls.set_rout_allowed(_prev_rout_allowed)


# ------------------------------------------------------------------
# Strongholds (M2/M5) — existing Stronghold / StrongholdManager, runtime-registered
# ------------------------------------------------------------------

func _install_stronghold() -> String:
	var sid := str(mission["stronghold_id"])
	if manager.call("get_stronghold_by_id", sid) != null:
		return ""  # the battlefield already registered it
	var d: Dictionary = mission.get("stronghold", {})
	if d.is_empty():
		return "stronghold '%s' not on the map and no stronghold def in the mission block" % sid
	var fp: Array[Vector2i] = []
	for h in (d.get("footprint", []) as Array):
		fp.append(Vector2i(int(h[0]), int(h[1])))
	var st: int = StrongholdCls.StrongholdType.CAPITAL if str(d.get("type", "")) == "capital" else StrongholdCls.StrongholdType.FORTRESS
	var owner := str(d.get("owner", ScenarioCls.defender_of(mission)))
	var sh: RefCounted = StrongholdCls.new(sid, st, owner, fp, int(d["hp"]), int(d["slots"]))
	(manager.call("get_stronghold_manager") as RefCounted).call("register_stronghold", sh)
	var fmap: Dictionary = manager.get("_fortress_map")
	var cells: Dictionary = shell.get("_stronghold_cells")
	for h in fp:
		fmap["%d,%d" % [h.x, h.y]] = int(d["hp"])
		cells["%d,%d" % [h.x, h.y]] = true
	var renderer: Node = shell.get("unit_renderer")
	for gid in (d.get("garrison", []) as Array):
		var res: Dictionary = manager.call("garrison_enter", str(gid), sid)
		if not bool(res.get("success", false)):
			return "garrison_enter %s failed: %s" % [str(gid), str(res.get("reason", res))]
		if renderer != null and renderer.has_method("remove_unit"):
			renderer.call("remove_unit", str(gid))
	var sr: Node = shell.get("stronghold_renderer")
	if sr != null and DisplayServer.get_name() != "headless" and sr.has_method("render_strongholds"):
		sr.visible = true
		sr.call("render_strongholds", manager.call("get_all_strongholds"))
	return ""


func stronghold() -> Variant:
	if not mission.has("stronghold_id"):
		return null
	return manager.call("get_stronghold_by_id", str(mission["stronghold_id"]))


## Existing rule "breached + empty garrison -> owner flips" also when the garrison was already empty
## when the wall fell (the assault path only flips on the killing blow).
func _check_capture() -> void:
	var sh: Variant = stronghold()
	if sh == null:
		return
	if bool(sh.breached) and int(sh.get_garrison_count()) <= 0:
		var att := ScenarioCls.attacker_of(mission)
		if not att.is_empty() and str(sh.owner) != att:
			sh.owner = att
			events.append({"type": "stronghold_captured", "round": last_round, "new_owner": att})


# ------------------------------------------------------------------
# Logistics: head bases, built bases, supply network
# ------------------------------------------------------------------
# Head base: one per side, fixed, just off the board behind the side's starting HQ (straight out the back).
#   Visible to both sides, never destroyed, never entered. It is the source of the side's supply.
# Built bases: the HQ builds one on its own hex (not in a turn it moved), then the build skill cools down
#   for base_build_cooldown rounds. A base takes base_hits enemy entries: each earlier entry is absorbed
#   (the entering unit is pushed back next to the base and its action ends); the last one destroys it.
#   Damage never heals. Own units may stand on own bases.
# Network: two nodes (head / bases) link when the movement path between them is <= supply_link_range
#   hexes; links may form any mesh. Nodes reachable from the head over links are live. The HQ is supplied
#   while a live node is within supply_link_range of it (path length). Otherwise supply is cut (the
#   supply_cut_turns countdown). Destroyed bases simply drop out; the rest re-link by the same rule.

var heads := {}  # side -> Vector2i (off-board hex behind the starting HQ)
var _last_build_round := {"red": -1000, "blue": -1000}
var _pending_render: Array = []  # [uid, Vector2i]: renderer catch-up after a push-back (after the move animation)


func base_at(hex: Vector2i) -> Dictionary:
	for b in bases.values():
		if (b as Dictionary)["hex"] == hex:
			return b
	return {}


func bases_of(side: String) -> Array:
	var out: Array = []
	for k in bases.keys():
		if str(bases[k]["owner"]) == side:
			out.append(bases[k])
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a["id"]) < str(b["id"]))
	return out


func link_range() -> int:
	return int(rules_cfg["supply_link_range"])


## Map diameter of the live board = the largest hex distance between two playable hexes
## (= the widest spread of q, r or s over the cells).
func map_diameter() -> int:
	var cells: Dictionary = (shell.get("hex_grid") as Node).get("cell_data") if shell.get("hex_grid") != null else {}
	if cells.is_empty():
		return int(rules_cfg.get("default_map_diameter", 16)) if not rules_cfg.is_empty() else 16
	var lo := [1 << 20, 1 << 20, 1 << 20]
	var hi := [-(1 << 20), -(1 << 20), -(1 << 20)]
	for c in cells.values():
		var v := [int(c.q), int(c.r), -int(c.q) - int(c.r)]
		for i in range(3):
			lo[i] = mini(lo[i], v[i])
			hi[i] = maxi(hi[i], v[i])
	return maxi(hi[0] - lo[0], maxi(hi[1] - lo[1], hi[2] - lo[2]))


## Every unit (HQ included, it moves like infantry) gets the movement of the board's size preset
## (rules_cfg.unit_mp); the march limits follow from base_mp every turn.
func _apply_unit_mp() -> void:
	var units: Dictionary = manager.get("_units")
	var table: Dictionary = rules_cfg.get("unit_mp", {})
	for uid in units.keys():
		var u: Dictionary = units[uid]
		var cls := str(u.get("class", "")).to_lower().trim_suffix("s")
		if not table.has(cls):
			continue
		var mp := float(table[cls])
		u["base_mp"] = mp
		u["remaining_mp"] = mp
		u["blue_limit"] = Step3ConfigCls.get_blue_limit(mp)
		u["red_limit"] = Step3ConfigCls.get_red_limit(mp)
		u["black_limit"] = Step3ConfigCls.get_black_limit(mp)


## Rounds until `side` may build again (0 = ready).
func build_cooldown_left(side: String) -> int:
	var cd := int(rules_cfg["base_build_cooldown"])
	var turn := int(manager.call("get_current_turn"))
	return maxi(0, int(_last_build_round.get(side, -1000)) + cd - turn)


func can_build_base(uid: String) -> Dictionary:
	if not outcome.is_empty() or _shell_over():
		return {"ok": false, "code": "BATTLE_OVER"}
	var u: Dictionary = manager.call("get_unit_by_id", uid)
	if u.is_empty() or int(u.get("soldier_count", 0)) <= 0:
		return {"ok": false, "code": "UNIT_GONE"}
	if str(u.get("class", "")) != "hq":
		return {"ok": false, "code": "NOT_HQ"}
	if bool(u.get("garrisoned", false)):
		return {"ok": false, "code": "GARRISONED"}
	if bool(u.get("action_ended", false)):
		return {"ok": false, "code": "ACTION_ENDED"}
	if bool(u.get("has_moved", false)) or float(u.get("turn_move_cost_spent", 0.0)) > 0.0:
		return {"ok": false, "code": "HQ_MOVED_THIS_TURN"}
	var left := build_cooldown_left(str(u.get("faction", "")))
	if left > 0:
		return {"ok": false, "code": "COOLDOWN", "turns_left": left}
	var hex := Vector2i(int(u.get("q", 0)), int(u.get("r", 0)))
	if not base_at(hex).is_empty():
		return {"ok": false, "code": "BASE_EXISTS"}
	return {"ok": true, "code": "", "hex": hex}


## BUILD_BASE executor (HQ only, own hex). Does not end the HQ's action: it may move afterwards.
func build_base(uid: String) -> Dictionary:
	var chk := can_build_base(uid)
	if not bool(chk["ok"]):
		return {"success": false, "code": str(chk["code"])}
	var u: Dictionary = manager.call("get_unit_by_id", uid)
	_base_seq += 1
	var side := str(u.get("faction", ""))
	var bid := "BASE_%s_%d" % [side.to_upper(), _base_seq]
	var turn := int(manager.call("get_current_turn"))
	bases[bid] = {"id": bid, "owner": side, "hex": chk["hex"], "built_round": turn,
		"hits_left": int(rules_cfg.get("base_hits", 2))}
	_last_build_round[side] = turn
	events.append({"type": "base_built", "base_id": bid, "owner": side, "hex": [chk["hex"].x, chk["hex"].y], "round": turn})
	publish()
	return {"success": true, "code": "", "base_id": bid, "hex": [chk["hex"].x, chk["hex"].y]}


## An enemy unit entering a base hex = one attack on the base.
func _on_unit_moved(unit_id: String, from: Vector2i, to: Vector2i, _march: int) -> void:
	var u: Dictionary = manager.call("get_unit_by_id", unit_id)
	var b := base_at(to)
	if not b.is_empty() and not u.is_empty() and str(u.get("faction", "")) != str(b["owner"]):
		_base_entered(str(b["id"]), unit_id, from)


## Safety net at round end: an enemy standing on a base hex (placed without a move) counts as an entry.
func _sweep_bases() -> void:
	for b in bases.values().duplicate():
		var occ := _unit_at(b["hex"])
		if not occ.is_empty() and str(occ.get("faction", "")) != str(b["owner"]):
			_base_entered(str(b["id"]), str(occ.get("id", "")), b["hex"])


## One hit. Survives (hits left) -> the attacker is pushed back to a free hex next to the base (the
## one nearest to where it came from) and its action ends; last hit -> destroyed, the attacker stays.
func _base_entered(bid: String, uid: String, from: Vector2i) -> void:
	if not bases.has(bid):
		return
	var b: Dictionary = bases[bid]
	var left := int(b.get("hits_left", 1)) - 1
	if left <= 0:
		_destroy_base(bid, uid)
		return
	b["hits_left"] = left
	events.append({"type": "base_damaged", "base_id": bid, "owner": b["owner"], "by": uid, "hits_left": left,
		"round": int(manager.call("get_current_turn"))})
	_push_back(uid, b["hex"], from)
	publish()


func _push_back(uid: String, base_hex: Vector2i, from: Vector2i) -> void:
	var units: Dictionary = manager.get("_units")  # live rows
	var occ: Dictionary = manager.get("_occupied_map")
	if not units.has(uid):
		return
	var best := Vector2i(-9999, -9999)
	var best_d := 1 << 30
	for d in DIRS:
		var n: Vector2i = base_hex + d
		if not _passable(n) or (not base_at(n).is_empty() and str(base_at(n)["owner"]) != str(units[uid].get("faction", ""))):
			continue
		var k := "%d,%d" % [n.x, n.y]
		if occ.has(k) and str(occ[k]) != uid:
			continue
		var dist := HexUtilsCls.hex_distance_axial(n, from)
		if dist < best_d:
			best_d = dist
			best = n
	if best.x == -9999:
		return  # boxed in: stays (rare); the base still took the hit
	var u: Dictionary = units[uid]
	if str(occ.get("%d,%d" % [int(u["q"]), int(u["r"])], "")) == uid:
		occ.erase("%d,%d" % [int(u["q"]), int(u["r"])])
	u["q"] = best.x
	u["r"] = best.y
	u["action_ended"] = true
	u["remaining_mp"] = 0.0
	occ["%d,%d" % [best.x, best.y]] = uid
	_pending_render.append([uid, best])


## Renderer catch-up for pushed-back units once the shell's move animation is over.
func _process(_d: float) -> void:
	if _pending_render.is_empty() or shell == null:
		return
	if bool(shell.get("_is_animating_movement")):
		return
	var r: Node = shell.get("unit_renderer")
	for e in _pending_render:
		if r != null and r.has_method("update_unit_position"):
			r.call("update_unit_position", str(e[0]), int(e[1].x), int(e[1].y))
	_pending_render.clear()


func _destroy_base(bid: String, by_uid: String) -> void:
	if not bases.has(bid):
		return
	var b: Dictionary = bases[bid]
	bases.erase(bid)
	events.append({"type": "base_destroyed", "base_id": bid, "owner": b["owner"], "by": by_uid,
		"round": int(manager.call("get_current_turn"))})
	publish()


func _unit_at(hex: Vector2i) -> Dictionary:
	for u in manager.call("get_all_units"):
		if int(u.get("q", 0)) == hex.x and int(u.get("r", 0)) == hex.y and not bool(u.get("garrisoned", false)) \
				and int(u.get("soldier_count", 0)) > 0:
			return u
	return {}


func hq_of(side: String) -> Dictionary:
	for u in manager.call("get_all_units_including_garrisoned"):
		if str(u.get("faction", "")) == side and str(u.get("class", "")) == "hq" and int(u.get("soldier_count", 0)) > 0:
			return u
	return {}


## Simple shortest path on the hex grid (BFS, fixed neighbor order). Units never block the path
## search; non-playable hexes and stronghold footprints do (the start and the target themselves may be
## off-board, e.g. a head base). max_len > 0 stops the search beyond that many steps.
## Returns [] when unreachable (or longer than max_len).
func shortest_path(a: Vector2i, b: Vector2i, max_len: int = 0) -> Array:
	if a == b:
		return [a]
	var prev := {a: a}
	var depth := {a: 0}
	var queue: Array = [a]
	var head := 0
	while head < queue.size():
		var cur: Vector2i = queue[head]
		head += 1
		if max_len > 0 and int(depth[cur]) >= max_len:
			continue
		for d in DIRS:
			var n: Vector2i = cur + d
			if prev.has(n):
				continue
			if n != b and not _passable(n):
				continue
			prev[n] = cur
			depth[n] = int(depth[cur]) + 1
			if n == b:
				var path: Array = [b]
				var p: Vector2i = b
				while p != a:
					p = prev[p]
					path.push_front(p)
				return path
			queue.append(n)
	return []


func _passable(h: Vector2i) -> bool:
	if shell.has_method("is_playable_hex") and not bool(shell.call("is_playable_hex", h)):
		return false
	return not bool(manager.call("is_stronghold_hex_coord", h))


static func _hex_px(h: Vector2i) -> Vector2:
	return Vector2(36.0 * h.x, 42.0 * h.y + 21.0 * h.x)


## Head bases: from each starting HQ, step straight out the back (the neighbour direction closest to
## "away from the enemy HQ") until the first hex off the board.
func _init_heads() -> void:
	var hb := hq_of("blue")
	var hr := hq_of("red")
	if hb.is_empty() or hr.is_empty():
		return
	var pos := {"blue": Vector2i(int(hb["q"]), int(hb["r"])), "red": Vector2i(int(hr["q"]), int(hr["r"]))}
	for s in SIDES:
		var dir: Vector2 = (_hex_px(pos[s]) - _hex_px(pos[_foe(s)])).normalized()
		var step: Vector2i = DIRS[0]
		var best := -INF
		for d in DIRS:
			var dd := _hex_px(d).normalized().dot(dir)
			if dd > best:
				best = dd
				step = d
		var h: Vector2i = pos[s]
		for _i in range(200):
			h += step
			if not (shell.has_method("is_playable_hex") and bool(shell.call("is_playable_hex", h))):
				break
		heads[s] = h


## The side's supply network: nodes (head + bases), links within supply_link_range (path length), which
## nodes are live (linked to the head), and the HQ link (shortest live node -> HQ path within range).
## {nodes: [{id, kind, hex, live}], links: [{a, b, path, len, live}], hq_link: {node, path, len} or {}, connected}
## Cached: paths depend only on the nodes, the HQ hex and the (static) board, never on other units, so the
## network is recomputed only when one of those changes. Callers treat the result as read-only.
var _net_cache := {}  # side -> {sig, net}


func supply_net(side: String) -> Dictionary:
	var hq0 := hq_of(side)
	var sig := JSON.stringify([link_range(), heads.get(side, null),
		bases_of(side).map(func(b): return [b["id"], b["hex"], b.get("hits_left", 1)]),
		[] if hq0.is_empty() else [int(hq0["q"]), int(hq0["r"])]])
	var hit: Dictionary = _net_cache.get(side, {})
	if not hit.is_empty() and str(hit["sig"]) == sig:
		return hit["net"]
	var net := _compute_supply_net(side)
	_net_cache[side] = {"sig": sig, "net": net}
	return net


func _compute_supply_net(side: String) -> Dictionary:
	var rng := link_range()
	var nodes: Array = []
	if heads.has(side):
		nodes.append({"id": "HEAD_%s" % side.to_upper(), "kind": "head", "hex": heads[side], "live": true})
	for b in bases_of(side):
		nodes.append({"id": str(b["id"]), "kind": "base", "hex": b["hex"], "live": false,
			"hits_left": int(b.get("hits_left", 1))})
	var links: Array = []
	var adj := {}
	for i in range(nodes.size()):
		adj[i] = []
	for i in range(nodes.size()):
		for j in range(i + 1, nodes.size()):
			var p := shortest_path(nodes[i]["hex"], nodes[j]["hex"], rng)
			if p.is_empty():
				continue
			links.append({"a": i, "b": j, "path": p, "len": p.size() - 1, "live": false})
			adj[i].append(j)
			adj[j].append(i)
	# Live = reachable from the head (node 0) over links.
	if not nodes.is_empty() and str(nodes[0]["kind"]) == "head":
		var stack: Array = [0]
		var seen := {0: true}
		while not stack.is_empty():
			var i: int = stack.pop_back()
			nodes[i]["live"] = true
			for j in adj[i]:
				if not seen.has(j):
					seen[j] = true
					stack.append(j)
	for l in links:
		l["live"] = bool(nodes[l["a"]]["live"])
	var hq_link := {}
	var hq := hq_of(side)
	if not hq.is_empty():
		var hq_hex := Vector2i(int(hq["q"]), int(hq["r"]))
		for i in range(nodes.size()):
			if not bool(nodes[i]["live"]):
				continue
			var p := shortest_path(nodes[i]["hex"], hq_hex, rng)
			if p.is_empty():
				continue
			if hq_link.is_empty() or p.size() < (hq_link["path"] as Array).size():
				hq_link = {"node": i, "path": p, "len": p.size() - 1}
	return {"nodes": nodes, "links": links, "hq_link": hq_link, "connected": not hq_link.is_empty(), "range": rng}


func supply_status(side: String) -> Dictionary:
	var hq := hq_of(side)
	var own := bases_of(side)
	if hq.is_empty():
		return {"connected": false, "has_base": not own.is_empty(), "line": [], "cut_hexes": [], "reason": "no_hq"}
	var net := supply_net(side)
	if not bool(net["connected"]):
		return {"connected": false, "has_base": not own.is_empty(), "line": [], "cut_hexes": [], "reason": "out_of_range"}
	var hl: Dictionary = net["hq_link"]
	var node: Dictionary = (net["nodes"] as Array)[int(hl["node"])]
	return {"connected": true, "has_base": not own.is_empty(), "line": hl["path"], "cut_hexes": [], "reason": "ok",
		"base_id": str(node["id"]) if str(node["kind"]) == "base" else ""}


## Display paths of the live network (links between live nodes + the HQ link), each an Array of Vector2i.
func supply_network(side: String) -> Array:
	var net := supply_net(side)
	var out: Array = []
	for l in (net["links"] as Array):
		if bool(l["live"]):
			out.append(l["path"])
	if not (net["hq_link"] as Dictionary).is_empty():
		out.append(net["hq_link"]["path"])
	return out


## JSON-friendly copy of supply_net for mission_state / the display.
func _net_view(side: String) -> Dictionary:
	var net := supply_net(side)
	var hx := func(h: Vector2i) -> Array: return [h.x, h.y]
	var nodes: Array = []
	for n in (net["nodes"] as Array):
		nodes.append({"id": n["id"], "kind": n["kind"], "hex": hx.call(n["hex"]), "live": n["live"]})
	var links: Array = []
	for l in (net["links"] as Array):
		links.append({"a": l["a"], "b": l["b"], "len": l["len"], "live": l["live"], "path": (l["path"] as Array).map(hx)})
	var hl: Dictionary = net["hq_link"]
	return {"nodes": nodes, "links": links, "range": net["range"], "connected": net["connected"],
		"hq_link": {} if hl.is_empty() else {"node": hl["node"], "len": hl["len"], "path": (hl["path"] as Array).map(hx)}}


# ------------------------------------------------------------------
# Round evaluation (order: HQ -> collapse -> supply -> mission -> round limit)
# ------------------------------------------------------------------

## Field army soldiers per side (HQ excluded: the HQ alone must not hold the army above the collapse line;
## its loss is the separate HQ rule). Used for the collapse line and the published "soldiers".
func soldiers_now() -> Dictionary:
	var out := {"red": 0, "blue": 0}
	for u in manager.call("get_all_units_including_garrisoned"):
		var f := str(u.get("faction", ""))
		if out.has(f) and str(u.get("class", "")) != "hq":
			out[f] += maxi(0, int(u.get("soldier_count", 0)))
	return out


func collapse_line(side: String) -> int:
	return int(floor(float(start_soldiers[side]) * float(mission["collapse_frac"])))


func _on_unit_destroyed(unit_id: String, _coord: Vector2i) -> void:
	# Existing HQ hook already flagged the shell; record it as the first check, immediately.
	if outcome.is_empty() and _shell_over():
		last_round = int(manager.call("get_current_turn"))
		_check_hq()


func _shell_over() -> bool:
	return shell != null and shell.has_method("_battle_over") and bool(shell.call("_battle_over"))


func _check_hq() -> bool:
	if bool(shell.get("_battle_won")):
		_decide("blue", "hq_destroyed")
		return true
	if bool(shell.get("_battle_lost")):
		_decide("red", "hq_destroyed")
		return true
	return false


func evaluate_round(completed_round: int) -> Dictionary:
	if not outcome.is_empty():
		return outcome
	last_round = completed_round
	_sweep_bases()
	_check_capture()
	# 1. HQ sudden death (existing shell hook)
	if _check_hq():
		return outcome
	# 2. Collapse: soldiers <= collapse_frac x start
	var now := soldiers_now()
	var broke: Array = []
	for s in SIDES:
		if int(now[s]) <= collapse_line(s):
			broke.append(s)
	if broke.size() == 2:
		_decide("", "mutual_collapse")
		return outcome
	if broke.size() == 1:
		_decide(_foe(broke[0]), "collapse_%s" % broke[0])
		return outcome
	# 3. Supply cut countdown (reconnect cancels)
	var lost_supply: Array = []
	for s in SIDES:
		var st := supply_status(s)
		if bool(st["connected"]):
			cut_since[s] = -1
		else:
			if int(cut_since[s]) < 0:
				cut_since[s] = completed_round
			if completed_round - int(cut_since[s]) >= int(rules_cfg["supply_cut_turns"]):
				lost_supply.append(s)
	if lost_supply.size() == 2:
		_decide("", "mutual_supply_cut")
		return outcome
	if lost_supply.size() == 1:
		_decide(_foe(lost_supply[0]), "supply_cut_%s" % lost_supply[0])
		return outcome
	# 3b. HQ-distance morale zones (morale missions only)
	_update_morale_zones()
	# 4. Mission condition
	var fam := str(mission["family"])
	if fam == "M1":
		var pres := village_presence()
		if int(pres["attacker_units"]) >= int(rules_cfg["m1_area_units"]) and int(pres["defender_units"]) == 0:
			village_streak += 1
		else:
			village_streak = 0
		if village_streak >= int(rules_cfg["m1_area_hold"]):
			_decide(ScenarioCls.attacker_of(mission), "village_occupied")
			return outcome
	elif fam in ["M2", "M5"]:
		var sh: Variant = stronghold()
		if sh != null and str(sh.owner) == ScenarioCls.attacker_of(mission):
			_decide(ScenarioCls.attacker_of(mission), "stronghold_captured")
			return outcome
	elif fam == "M4":
		var owners := site_owners()
		for s in SIDES:
			var n := owners.count(s)
			site_streak[s] = int(site_streak[s]) + 1 if n == owners.size() else 0
		for s in SIDES:
			if int(site_streak[s]) >= int(rules_cfg["m4_full_hold"]):
				_decide(s, "sites_full_hold")
				return outcome
	# 5. Round limit
	if completed_round >= int(mission["round_limit"]):
		if fam in ["M1", "M2", "M5"]:
			_decide(ScenarioCls.defender_of(mission), "round_limit_defender_holds")
		elif fam == "M4":
			var owners2 := site_owners()
			var winner := ""
			for s in SIDES:
				if owners2.count(s) >= int(rules_cfg["m4_majority"]):
					winner = s
			_decide(winner, "sites_majority_at_limit" if not winner.is_empty() else "round_limit_stalemate")
		else:
			_decide("", "round_limit_stalemate")
		return outcome
	publish()
	return {}


func _foe(s: String) -> String:
	return "blue" if s == "red" else "red"


func _decide(winner: String, reason: String) -> void:
	if not outcome.is_empty():
		return
	outcome = {"winner": winner if not winner.is_empty() else "none", "reason": reason,
		"round": last_round if last_round > 0 else int(manager.call("get_current_turn")),
		"family": str(mission.get("family", "")), "mission_id": str(mission.get("mission_id", ""))}
	events.append({"type": "outcome", "outcome": outcome.duplicate(true)})
	if drive_shell_terminal and not _shell_over():
		if winner == "blue":
			shell.call("_show_battle_win")
		elif winner == "red":
			shell.call("_show_battle_loss")
	publish()
	outcome_decided.emit(outcome.duplicate(true))


func village_presence() -> Dictionary:
	var village := ScenarioCls.hexes(mission, "village_hexes")
	var att := ScenarioCls.attacker_of(mission)
	var a := 0
	var d := 0
	for u in manager.call("get_all_units"):
		if bool(u.get("garrisoned", false)) or int(u.get("soldier_count", 0)) <= 0:
			continue
		if Vector2i(int(u["q"]), int(u["r"])) in village:
			if str(u["faction"]) == att:
				a += 1
			else:
				d += 1
	return {"attacker_units": a, "defender_units": d}


func site_owners() -> Array:
	var out: Array = []
	for h in ScenarioCls.hexes(mission, "site_hexes"):
		var b := base_at(h)
		out.append(str(b["owner"]) if not b.is_empty() else "none")
	return out


# ------------------------------------------------------------------
# Published read-only state
# ------------------------------------------------------------------

## HQ-distance morale zones (morale missions only): near recovers more the longer the stay,
## mid holds steady, far loses morale. Runs after the supply countdown in evaluate_round.
func _update_morale_zones() -> void:
	if not bool(mission.get("morale", false)):
		return
	var near_max := int(rules_cfg["morale_zone_near_max"])
	var mid_max := int(rules_cfg["morale_zone_mid_max"])
	var rec_base := float(rules_cfg["morale_recover_base"])
	var rec_step := float(rules_cfg["morale_recover_step"])
	var rec_cap := float(rules_cfg["morale_recover_cap"])
	var far_loss := float(rules_cfg["morale_far_loss"])
	var seen := {}
	for s in SIDES:
		var hq := hq_of(s)
		if hq.is_empty():
			continue
		var hq_hex := Vector2i(int(hq["q"]), int(hq["r"]))
		var has_base := bool(supply_status(s)["connected"])  # recovery near the HQ only while supplied
		for u in manager.call("get_all_units"):
			if str(u.get("faction", "")) != s:
				continue
			if str(u.get("class", "")) == "hq" or bool(u.get("garrisoned", false)):
				continue
			if int(u.get("soldier_count", 0)) <= 0:
				continue
			var uid := str(u.get("id", ""))
			seen[uid] = true
			var d := HexUtilsCls.hex_distance_axial(Vector2i(int(u.get("q", 0)), int(u.get("r", 0))), hq_hex)
			var zone := 1
			if d > mid_max:
				zone = 3
			elif d > near_max:
				zone = 2
			var prev: Dictionary = morale_zone.get(uid, {"zone": 0, "rounds": 0})
			var rounds := 1
			if int(prev.get("zone", 0)) == zone:
				rounds = int(prev.get("rounds", 0)) + 1
			if zone == 2:
				rounds = 0
			morale_zone[uid] = {"side": s, "zone": zone, "rounds": rounds}
			if zone == 1 and has_base:
				manager.call("s6_add_morale", uid, minf(rec_base + rec_step * float(rounds - 1), rec_cap))
			elif zone == 3:
				manager.call("s6_add_morale", uid, -far_loss)
	for uid in morale_zone.keys().duplicate():
		if not seen.has(uid):
			morale_zone.erase(uid)


func publish() -> Dictionary:
	var now := soldiers_now()
	var turn := int(manager.call("get_current_turn"))
	var completed := maxi(last_round, turn - 1)
	var st := {
		"mission_id": str(mission.get("mission_id", "")), "family": str(mission.get("family", "")),
		"roles": (mission.get("roles", {}) as Dictionary).duplicate(),
		"round": turn, "round_limit": int(mission.get("round_limit", 0)),
		"rounds_left": maxi(0, int(mission.get("round_limit", 0)) - completed),
		"soldiers": {}, "collapse_line": {}, "supply": {}, "hq_soldiers": {},
		"bases": [], "outcome": outcome.duplicate(true) if not outcome.is_empty() else null,
		"morale": bool(mission.get("morale", false)),
	}
	for s in SIDES:
		st["soldiers"][s] = {"start": int(start_soldiers[s]), "now": int(now[s])}
		st["collapse_line"][s] = collapse_line(s)
		var sup := supply_status(s)
		var since := int(cut_since[s])
		var elapsed := (completed - since) if since >= 0 else 0
		st["supply"][s] = {"connected": bool(sup["connected"]), "has_base": bool(sup["has_base"]),
			"reason": str(sup["reason"]), "countdown_active": since >= 0,
			"turns_left": int(rules_cfg["supply_cut_turns"]) - elapsed if since >= 0 else int(rules_cfg["supply_cut_turns"]),
			"line": (sup["line"] as Array).map(func(h): return [h.x, h.y]),
			"links": supply_network(s).map(func(p): return (p as Array).map(func(h): return [h.x, h.y])),
			"cut_hexes": (sup["cut_hexes"] as Array).map(func(h): return [h.x, h.y]),
			"net": _net_view(s), "build_cooldown": build_cooldown_left(s)}
		var hq := hq_of(s)
		st["hq_soldiers"][s] = int(hq.get("soldier_count", 0))
		st["morale_zones"] = {"red": {}, "blue": {}}
	for b in bases.values():
		st["bases"].append({"id": b["id"], "owner": b["owner"], "hex": [b["hex"].x, b["hex"].y],
			"hits_left": int(b.get("hits_left", 1))})
	st["heads"] = {}
	for s in heads.keys():
		st["heads"][s] = [heads[s].x, heads[s].y]
	var zones := {"red": {}, "blue": {}}
	for uid in morale_zone.keys():
		var z: Dictionary = morale_zone[uid]
		var side := str(z.get("side", "red"))
		if zones.has(side):
			zones[side][uid] = {"zone": int(z.get("zone", 0)), "rounds": int(z.get("rounds", 0))}
	st["morale_zones"] = zones
	var fam := str(mission.get("family", ""))
	if fam == "M1":
		var pres := village_presence()
		st["village"] = {"hexes": mission.get("village_hexes", []), "attacker_units": pres["attacker_units"],
			"defender_units": pres["defender_units"], "hold_streak": village_streak,
			"hold_needed": int(rules_cfg["m1_area_hold"]), "units_needed": int(rules_cfg["m1_area_units"])}
	elif fam == "M4":
		var owners := site_owners()
		var rows: Array = []
		var sh := ScenarioCls.hexes(mission, "site_hexes")
		for i in range(sh.size()):
			rows.append({"hex": [sh[i].x, sh[i].y], "owner": owners[i]})
		st["sites"] = rows
		st["site_streak"] = site_streak.duplicate()
		st["full_hold_needed"] = int(rules_cfg["m4_full_hold"])
		st["majority_needed"] = int(rules_cfg["m4_majority"])
	elif fam in ["M2", "M5"]:
		var s2: Variant = stronghold()
		if s2 != null:
			st["stronghold"] = {"id": str(s2.structure_id), "owner": str(s2.owner),
				"wall_hp": int(s2.fortification_hp), "wall_hp_max": int(s2.fortification_hp_max),
				"breached": bool(s2.breached), "garrison": int(s2.get_garrison_count()),
				"captured": str(s2.owner) == ScenarioCls.attacker_of(mission),
				"footprint": (s2.get_footprint() as Array).map(func(h): return [h.x, h.y])}
	mission_state = st
	return st


## Mission block as one side sees it (role resolved).
func mission_for_side(side: String) -> Dictionary:
	var m := mission.duplicate(true)
	m["side"] = side
	m["role"] = str((mission.get("roles", {}) as Dictionary).get(side, "none"))
	m["turn_limit"] = int(mission.get("round_limit", 0))
	m["type"] = "%s_%s" % [str(mission.get("family_name", "")).to_lower(), m["role"]]
	return m
