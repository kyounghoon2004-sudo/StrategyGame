extends Node

## GX MISSIONS v1 — MissionRules: the Godot authority for mission outcomes (attached at runtime).
##
## The only judge. GX and the Brain read `mission_state` (read-only copy), never decide.
## Evaluated at the end of each round, order: HQ -> collapse -> supply-cut countdown -> mission -> round limit.
## HQ sudden death stays the existing shell hook (_on_s6_unit_destroyed); this node only records it first.
## Logistics bases: built only by the HQ on its own hex, not in a turn the HQ moved, destroy-only
## (an enemy field unit entering the base hex destroys it). Supply line = shortest hex path HQ -> own base;
## it is cut while an enemy field unit stands on it (or the side has no base, config rules.supply_no_base_counts_as_cut).
## Morale switch per mission: flips the SandboxRules runtime flag that gates the live morale path
## (combat_calculator morale modifier / shock, march penalty); no rout anywhere.
## Strongholds in the sandbox: registered at runtime into the live StrongholdManager from the mission block.

const CfgCls = preload("res://scripts/gx_missions/mission_config.gd")
const ScenarioCls = preload("res://scripts/gx_missions/mission_scenario.gd")
const SandboxRulesCls = preload("res://scripts/core/sandbox_rules.gd")
const StrongholdCls = preload("res://scripts/core/stronghold.gd")

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
	rules_cfg = CfgCls.section("rules")
	mission = ScenarioCls.normalize(mission_block)
	if mission.has("error"):
		return {"ok": false, "error": str(mission["error"])}
	start_soldiers = soldiers_now()
	if mission["family"] in ["M2", "M5"]:
		var err := _install_stronghold()
		if not err.is_empty():
			return {"ok": false, "error": err}
	_prev_sandbox_flag = SandboxRulesCls.is_active()
	# Morale ON = the live morale path (gated by SandboxRules.morale_rout_enabled) runs; OFF = frozen.
	SandboxRulesCls.set_active(not bool(mission["morale"]))
	_morale_switched = true
	manager.connect("unit_moved", _on_unit_moved)
	manager.connect("unit_destroyed", _on_unit_destroyed)
	publish()
	return {"ok": true, "mission": mission.duplicate(true)}


func _exit_tree() -> void:
	if _morale_switched:
		SandboxRulesCls.set_active(_prev_sandbox_flag)


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
# Logistics bases + supply line
# ------------------------------------------------------------------

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
	bases[bid] = {"id": bid, "owner": side, "hex": chk["hex"], "built_round": int(manager.call("get_current_turn"))}
	events.append({"type": "base_built", "base_id": bid, "owner": side, "hex": [chk["hex"].x, chk["hex"].y],
		"round": int(manager.call("get_current_turn"))})
	publish()
	return {"success": true, "code": "", "base_id": bid, "hex": [chk["hex"].x, chk["hex"].y]}


## Destroy-only: an enemy field unit on the base hex destroys it (never captured).
func _on_unit_moved(unit_id: String, _from: Vector2i, to: Vector2i, _march: int) -> void:
	var u: Dictionary = manager.call("get_unit_by_id", unit_id)
	var b := base_at(to)
	if not b.is_empty() and not u.is_empty() and str(u.get("faction", "")) != str(b["owner"]):
		_destroy_base(str(b["id"]), unit_id)


func _sweep_bases() -> void:
	for b in bases.values().duplicate():
		var occ := _unit_at(b["hex"])
		if not occ.is_empty() and str(occ.get("faction", "")) != str(b["owner"]):
			_destroy_base(str(b["id"]), str(occ.get("id", "")))


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
## search; non-playable hexes and stronghold footprints do. Returns [] when unreachable.
func shortest_path(a: Vector2i, b: Vector2i) -> Array:
	if a == b:
		return [a]
	var prev := {a: a}
	var queue: Array = [a]
	var head := 0
	while head < queue.size():
		var cur: Vector2i = queue[head]
		head += 1
		for d in DIRS:
			var n: Vector2i = cur + d
			if prev.has(n):
				continue
			if n != b and not _passable(n):
				continue
			prev[n] = cur
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


func supply_status(side: String) -> Dictionary:
	var hq := hq_of(side)
	var own := bases_of(side)
	if hq.is_empty():
		return {"connected": false, "has_base": not own.is_empty(), "line": [], "cut_hexes": [], "reason": "no_hq"}
	if own.is_empty():
		var cut := bool(rules_cfg.get("supply_no_base_counts_as_cut", true))
		return {"connected": not cut, "has_base": false, "line": [], "cut_hexes": [], "reason": "no_base"}
	var hq_hex := Vector2i(int(hq["q"]), int(hq["r"]))
	var best_line: Array = []
	var best_cut: Array = []
	for b in own:
		var path := shortest_path(hq_hex, b["hex"])
		if path.is_empty():
			continue
		var cut_hexes: Array = []
		for h in path:
			if h == hq_hex:
				continue
			var occ := _unit_at(h)
			if not occ.is_empty() and str(occ.get("faction", "")) != side:
				cut_hexes.append(h)
		if cut_hexes.is_empty():
			return {"connected": true, "has_base": true, "line": path, "cut_hexes": [], "reason": "ok"}
		if best_line.is_empty() or path.size() < best_line.size():
			best_line = path
			best_cut = cut_hexes
	return {"connected": false, "has_base": true, "line": best_line, "cut_hexes": best_cut, "reason": "cut"}


# ------------------------------------------------------------------
# Round evaluation (order: HQ -> collapse -> supply -> mission -> round limit)
# ------------------------------------------------------------------

func soldiers_now() -> Dictionary:
	var out := {"red": 0, "blue": 0}
	for u in manager.call("get_all_units_including_garrisoned"):
		var f := str(u.get("faction", ""))
		if out.has(f):
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
			"cut_hexes": (sup["cut_hexes"] as Array).map(func(h): return [h.x, h.y])}
		var hq := hq_of(s)
		st["hq_soldiers"][s] = int(hq.get("soldier_count", 0))
	for b in bases.values():
		st["bases"].append({"id": b["id"], "owner": b["owner"], "hex": [b["hex"].x, b["hex"].y]})
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
