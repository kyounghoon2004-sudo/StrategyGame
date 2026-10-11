class_name UtilityLiveLegalEnumerator
extends RefCounted

## Canonical per-unit direct-action enumerator for a live side.
##
## Enumerates the COMPLETE immediate legal action set for ONE RED unit
## through the SAME authoritative queries the human-equivalent live path
## uses. Owns no rules; every offer is re-checkable through the
## service/manager gates, and every offer must execute.
##
## Live-path mirrors (step2r_battlefield_shell.gd + step7_battle_command_service.gd
## + step3_unit_manager.gd + step7_observation_projector.gd):
##   MOVE ......... service.preview_move_route(uid, dest, "red", "green")
##                  (found && is_valid_destination) — the exact call the
##                  live RED executor runs before execute_move.
##                  Seeds from calculate_envelope with the same arguments
##                  (RED known occupancy + GREEN_ONLY march policy, matching
##                  the deterministic RED routine and the service default).
##   ATTACK ....... manager.get_attackable_targets + projector
##                  is_contact_visible("red") (service.preview_attack rule).
##   ASSAULT ...... manager.get_attackable_strongholds; breached strongholds
##                  require a per-garrison-unit target.
##   WAIT ......... unit not action_ended (manager.wait_unit gate).
##   REST ......... manager.can_unit_rest (authoritative gate owns this).
##   FORTIFY ...... manager.can_unit_fortify (authoritative gate owns this).
##   DISMANTLE .... manager.can_dismantle_fortification (side-agnostic).
##   ENTER_GARRISON adjacent-or-on-footprint own stronghold + capacity
##                  (manager.garrison_enter rule, mirrored exactly).
## No END_TURN: a per-unit set never offers phase control. Empty set means
## the unit resolves per game semantics without a model call.
## Excluded with evidence (same as the human contract):
##   routed ....... shell refuses re-selection ("control lost").
##   garrisoned .. no field action offers; deploy path is dead UI.
##   convoy/supply logistics-cycle units (never human-commanded; the
##                  deterministic RED routine skips them too).
##   fortified units offer NO moves (stepwise rejects; dismantle first).
##
## Determinism: MOVE (q,r asc), ATTACK (target id asc), ASSAULT
## (stronghold, garrison asc), WAIT, REST, FORTIFY, DISMANTLE,
## ENTER_GARRISON. candidate_id is stable.
##
## Unit order (NEXT semantics for RED): unresolved RED field units in
## ascending id; next-after-current with wrap. Mirrors the human NEXT queue
## (manager.is_unit_data_turn_resolved + ascending-id traversal).
##
## Binds to EITHER the live battle (bridge + shell) or a SimController
## (headless parity): both expose manager/service/projector/grid/bounds.

const Step3PathfindingCls = preload("res://scripts/step3/step3_pathfinding.gd")
const Step3ConfigCls = preload("res://scripts/core/step3_config.gd")
const HexUtilsCls = preload("res://scripts/core/hex_utils.gd")

const SIDE := "red"
const MARCH_MODE := "green"

## SYMMETRIC V1: bound side ("red" default = legacy).
var _side := SIDE


func set_side(s: String) -> void:
	var want := s.strip_edges().to_lower()
	_side = "blue" if want == "blue" else "red"


func get_side() -> String:
	return _side

var _manager: RefCounted = null
var _service: RefCounted = null
var _projector: RefCounted = null
var _grid: Node = null
var _bounds: Dictionary = {}
var _rivers: Dictionary = {}
var _stronghold_cells: Dictionary = {}
var _is_terminal: Callable = Callable()


func configure(manager: RefCounted, service: RefCounted,
	projector: RefCounted, grid: Node, bounds: Dictionary,
	is_terminal: Callable, rivers: Dictionary = {},
	stronghold_cells: Dictionary = {}) -> String:
	_manager = manager
	_service = service
	_projector = projector
	_grid = grid
	_bounds = bounds
	_is_terminal = is_terminal
	_rivers = rivers
	_stronghold_cells = stronghold_cells
	if _manager == null or _service == null or _projector == null or _grid == null:
		return "Enumerator needs manager/service/projector/grid."
	if _bounds.is_empty():
		return "Enumerator needs map bounds."
	if not _is_terminal.is_valid():
		return "Enumerator needs a terminal predicate."
	return ""


func is_ready() -> bool:
	return _manager != null and _service != null and _projector != null \
		and _grid != null and not _bounds.is_empty() and _is_terminal.is_valid()


# ------------------------------------------------------------------
# Canonical RED unit queue (NEXT semantics, RED side).
# ------------------------------------------------------------------

## RED field eligibility for the Hands queue (mirrors the human NEXT
## eligibility: live, field, commandable; garrisoned/routed/convoy/supply
## excluded exactly like the OpenJev global pool and the NEXT traversal).
func is_red_field_eligible(u: Dictionary) -> bool:
	return is_field_eligible(u)


## SYMMETRIC V1: side-parameterized field eligibility (same gates).
func is_field_eligible(u: Dictionary) -> bool:
	if str(u.get("faction", "")) != _side:
		return false
	if int(u.get("soldier_count", 0)) <= 0:
		return false
	if bool(u.get("garrisoned", false)):
		return false
	if bool(u.get("routed", false)):
		return false
	if bool(u.get("is_convoy", false)) or str(u.get("class", "")) == "supply":
		return false
	return true


## NEXT-resolution predicate for one RED unit. Delegates to the
## authoritative manager predicate (action_ended / fortified / rested /
## MP-exhausted / destroyed / garrisoned / routed / convoy).
func is_red_unit_resolved(u: Dictionary) -> bool:
	return is_unit_resolved(u)


## SYMMETRIC V1: side-parameterized resolution predicate (same gates).
func is_unit_resolved(u: Dictionary) -> bool:
	if not is_field_eligible(u):
		return true
	if not bool((_manager as RefCounted).call("is_unit_data_turn_resolved", u)):
		return false
	# MOVE_ATTACK_FIX_V1: the manager also resolves a unit whose normal MP is
	# spent, but the engine (and the human UI) still allow that unit to
	# strike from its new hex (a move does not end the action). Keep it
	# open while a visible target is in range so move->attack can finish
	# in the same turn; ATTACK or WAIT then ends the action.
	return not _can_still_strike(u)


func _can_still_strike(u: Dictionary) -> bool:
	if int(u.get("soldier_count", 0)) <= 0 or bool(u.get("action_ended", false)) \
			or bool(u.get("has_attacked", false)) or bool(u.get("garrisoned", false)) \
			or bool(u.get("rested_this_turn", false)) or bool(u.get("routed", false)) \
			or bool(u.get("is_convoy", false)) or _is_fortified(u):
		return false
	var cands: Array = []
	_append_attacks(cands, u)
	return not cands.is_empty()


func is_red_unit_id_resolved(uid: String) -> bool:
	return is_unit_id_resolved(uid)


## SYMMETRIC V1: side-parameterized id resolution check.
func is_unit_id_resolved(uid: String) -> bool:
	var u: Dictionary = (_manager as RefCounted).call("get_unit_by_id", uid)
	if u.is_empty():
		return true
	return is_unit_resolved(u)


## All unresolved RED field units, ascending id (canonical stable order).
## Terminal battle -> empty (no unit acts after the battle ends).
func unresolved_red_units() -> Array:
	return unresolved_units()


## SYMMETRIC V1: all unresolved own-side field units, ascending id.
func unresolved_units() -> Array:
	var out: Array = []
	if not is_ready():
		return out
	if bool(_is_terminal.call()):
		return out
	for u_val in (_manager as RefCounted).call("get_all_units"):
		var u: Dictionary = u_val
		if not is_field_eligible(u):
			continue
		if is_unit_resolved(u):
			continue
		out.append(u)
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a.get("id", "")) < str(b.get("id", "")))
	return out


## NEXT traversal: first unresolved RED unit with id > after_id, else wrap
## to unresolved[0]. Empty dict when none remain. Mirrors
## shell.select_next_friendly_field_unit traversal exactly.
func next_unresolved_red_unit(after_id: String) -> Dictionary:
	return next_unresolved_unit(after_id)


## SYMMETRIC V1: NEXT traversal for the bound side (same semantics).
func next_unresolved_unit(after_id: String) -> Dictionary:
	var unresolved: Array = unresolved_units()
	if unresolved.is_empty():
		return {}
	if not after_id.is_empty():
		for u in unresolved:
			if str((u as Dictionary).get("id", "")) > after_id:
				return u
	return unresolved[0]


# ------------------------------------------------------------------
# Per-unit enumeration.
# ------------------------------------------------------------------

## Full legal set for ONE unit. Terminal battle -> no candidates at all
## (post-terminal actions cannot exist).
func enumerate_for_unit(unit_id: String) -> Dictionary:
	var out := {"side": _side, "terminal": false, "unit_id": unit_id,
		"resolved": true, "candidates": []}
	if not is_ready():
		(out as Dictionary)["error"] = "Enumerator not configured."
		return out
	if bool(_is_terminal.call()):
		out["terminal"] = true
		return out
	var u: Dictionary = (_manager as RefCounted).call("get_unit_by_id", unit_id)
	if u.is_empty():
		(out as Dictionary)["error"] = "UNIT_GONE"
		return out
	if str(u.get("faction", "")) != _side:
		(out as Dictionary)["error"] = "UNIT_NOT_RED" if _side == "red" else "UNIT_NOT_BLUE"
		return out
	if is_unit_resolved(u):
		out["resolved"] = true
		return out
	out["resolved"] = false
	var cands: Array = []
	_append_unit_candidates(cands, u)
	out["candidates"] = cands
	return out


func _append_unit_candidates(cands: Array, u: Dictionary) -> void:
	var uid: String = str(u.get("id", ""))
	if bool(u.get("action_ended", false)):
		return
	if not _is_fortified(u):
		_append_moves(cands, u)
	_append_attacks(cands, u)
	_append_assaults(cands, u)
	cands.append({"candidate_id": "WAIT|%s" % uid, "unit_id": uid, "action_type": "WAIT"})
	# REST/FORTIFY gates are authoritative (faction-gated inside the
	# manager); call them unconditionally — never pre-filter by side here.
	if bool((_manager as RefCounted).call("can_unit_rest", uid)):
		cands.append({"candidate_id": "REST|%s" % uid, "unit_id": uid, "action_type": "REST"})
	if bool((_manager as RefCounted).call("can_unit_fortify", uid)):
		cands.append({"candidate_id": "FORTIFY|%s" % uid, "unit_id": uid, "action_type": "FORTIFY"})
	if bool((_manager as RefCounted).call("can_dismantle_fortification", uid)):
		cands.append({"candidate_id": "DISMANTLE|%s" % uid, "unit_id": uid, "action_type": "DISMANTLE"})
	_append_enter_garrison(cands, u)


func _is_fortified(u: Dictionary) -> bool:
	return bool(u.get("field_fortified", false)) or int(u.get("field_fortification_hp", 0)) > 0 or bool(u.get("fortified", false))


## MOVE legality == the live RED execution path: service.preview_move_route
## with side "red" and the RED march mode (GREEN_ONLY, matching the
## deterministic routine and execute_move_intent's default). Seeds come from
## calculate_envelope with identical arguments; every seed is re-confirmed
## by the service preview (found && is_valid_destination).
func _append_moves(cands: Array, u: Dictionary) -> void:
	var uid: String = str(u.get("id", ""))
	var origin := Vector2i(int(u.get("q", 0)), int(u.get("r", 0)))
	var cell_data: Dictionary = _grid.get("cell_data") as Dictionary if _grid else {}
	var occupied: Dictionary = (_projector as RefCounted).call("known_occupancy", _side)
	var policy: int = Step3ConfigCls.MarchPolicy.GREEN_ONLY
	var base_mp: float = float(u.get("base_mp", 2.0))
	var spent: float = float(u.get("turn_move_cost_spent", 0.0))
	var env: Variant = Step3PathfindingCls.calculate_envelope(
		origin, str(u.get("class", "infantry")), base_mp,
		float(u.get("remaining_mp", base_mp)), policy,
		cell_data, occupied, _rivers, _side, _stronghold_cells,
		spent,
		float(u.get("blue_limit", Step3ConfigCls.get_blue_limit(base_mp))),
		float(u.get("red_limit", Step3ConfigCls.get_red_limit(base_mp))),
		float(u.get("black_limit", Step3ConfigCls.get_black_limit(base_mp))),
		_bounds)
	var seeds: Array = []
	if env != null:
		for key in (env.reachable_data as Dictionary).keys():
			if key is Vector2i and (key as Vector2i) != origin:
				seeds.append(key)
	seeds.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		if a.x == b.x:
			return a.y < b.y
		return a.x < b.x
	)
	for dest in seeds:
		var route: Variant = (_service as RefCounted).call(
			"preview_move_route", uid, dest, _side, MARCH_MODE)
		if route == null or not bool(route.found) or not bool(route.is_valid_destination):
			continue
		var d: Vector2i = dest
		cands.append({
			"candidate_id": "MOVE|%s|%d,%d" % [uid, d.x, d.y],
			"unit_id": uid, "action_type": "MOVE",
			"origin": [origin.x, origin.y],
			"destination": [d.x, d.y],
			"cost": float(route.cost), "march_class": int(route.march_class),
			"direction": compass_from_to(origin, d),
			"terrain": terrain_at(d),
		})


func _append_attacks(cands: Array, u: Dictionary) -> void:
	var uid: String = str(u.get("id", ""))
	var targets: Array = (_manager as RefCounted).call("get_attackable_targets", uid)
	var vis: Array = []
	for t_val in targets:
		var t: Dictionary = t_val
		var tid: String = str(t.get("id", ""))
		if bool((_projector as RefCounted).call("is_contact_visible", _side, tid)):
			vis.append(t)
	vis.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a.get("id", "")) < str(b.get("id", "")))
	for t in vis:
		var tid: String = str((t as Dictionary).get("id", ""))
		cands.append({
			"candidate_id": "ATTACK|%s|%s" % [uid, tid],
			"unit_id": uid, "action_type": "ATTACK", "target_id": tid,
			"target_class": str((t as Dictionary).get("class", "?")),
			"target_q": int((t as Dictionary).get("q", 0)),
			"target_r": int((t as Dictionary).get("r", 0)),
		})


func _append_assaults(cands: Array, u: Dictionary) -> void:
	var uid: String = str(u.get("id", ""))
	var entries: Array = (_manager as RefCounted).call("get_attackable_strongholds", uid)
	entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a.get("structure_id", "")) < str(b.get("structure_id", "")))
	for e_val in entries:
		var e: Dictionary = e_val
		var sid: String = str(e.get("structure_id", ""))
		if bool(e.get("breached", false)):
			var sh: Variant = (_manager as RefCounted).call("get_stronghold_by_id", sid)
			var roster: Array = (sh.call("get_garrison_roster") as Array).duplicate() if sh != null else []
			roster.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a.get("id", "")) < str(b.get("id", "")))
			for g_val in roster:
				var gid: String = str((g_val as Dictionary).get("id", ""))
				cands.append({
					"candidate_id": "ASSAULT|%s|%s|%s" % [uid, sid, gid],
					"unit_id": uid, "action_type": "ASSAULT",
					"stronghold_id": sid, "garrison_target_id": gid,
				})
		else:
			cands.append({
				"candidate_id": "ASSAULT|%s|%s" % [uid, sid],
				"unit_id": uid, "action_type": "ASSAULT",
				"stronghold_id": sid, "garrison_target_id": "",
			})


func _append_enter_garrison(cands: Array, u: Dictionary) -> void:
	var uid: String = str(u.get("id", ""))
	var coord := Vector2i(int(u.get("q", 0)), int(u.get("r", 0)))
	var strongholds: Array = (_manager as RefCounted).call("get_all_strongholds")
	strongholds.sort_custom(func(a: Variant, b: Variant) -> bool: return str(a.structure_id) < str(b.structure_id))
	for sh in strongholds:
		if str(sh.owner) != str(u.get("faction", "")):
			continue
		if not bool(sh.has_garrison_capacity()):
			continue
		# Authority rule (garrison_enter): adjacent to any footprint hex
		# OR standing on a footprint hex. Mirrored exactly.
		var ok := false
		for h in sh.get_footprint():
			if HexUtilsCls.hex_distance_axial(coord, h) == 1 or coord == h:
				ok = true
				break
		if ok:
			cands.append({
				"candidate_id": "ENTER_GARRISON|%s|%s" % [uid, str(sh.structure_id)],
				"unit_id": uid, "action_type": "ENTER_GARRISON",
				"stronghold_id": str(sh.structure_id),
			})


## Deterministic spatial semantics for option text (factual translations of
## game state, not tactical judgments). Screen compass: N = up (-y).
static func compass_from_to(origin: Vector2i, dest: Vector2i) -> String:
	var a: Vector2 = HexUtilsCls.hex_to_pixel(origin.x, origin.y)
	var b: Vector2 = HexUtilsCls.hex_to_pixel(dest.x, dest.y)
	var dx: float = b.x - a.x
	var dy: float = b.y - a.y
	if dx == 0.0 and dy == 0.0:
		return "HERE"
	var ang: float = rad_to_deg(atan2(dy, dx)) # screen coords: +y = down
	if ang >= -22.5 and ang < 22.5:
		return "E"
	if ang >= 22.5 and ang < 67.5:
		return "SE"
	if ang >= 67.5 and ang < 112.5:
		return "S"
	if ang >= 112.5 and ang < 157.5:
		return "SW"
	if ang >= 157.5 or ang < -157.5:
		return "W"
	if ang >= -157.5 and ang < -112.5:
		return "NW"
	if ang >= -112.5 and ang < -67.5:
		return "N"
	return "NE"


## Short terrain tag at a hex from grid cell_data (best-effort factual;
## "?" when the cell carries no readable terrain, e.g. sim grids whose
## cell_data was never built — never invented).
func terrain_at(cell: Vector2i) -> String:
	var cell_data: Dictionary = _grid.get("cell_data") as Dictionary if _grid else {}
	# Live grids key cells by "q,r" strings; sim grids may use Vector2i.
	var c: Variant = null
	if cell_data.has(cell):
		c = cell_data[cell]
	else:
		var skey := "%d,%d" % [cell.x, cell.y]
		if cell_data.has(skey):
			c = cell_data[skey]
	if c != null:
		if c is Dictionary:
			return _short_terrain(str((c as Dictionary).get("terrain", (c as Dictionary).get("type", ""))))
		if c is Object and c.get("terrain") != null:
			return _terrain_tag_from_int(int(c.get("terrain")))
		return _short_terrain(str(c))
	if _rivers.has(cell):
		return "RIV"
	return "?"


## HexCell.TerrainType int -> tag (hex_cell.gd enum order).
static func _terrain_tag_from_int(t: int) -> String:
	match t:
		0:
			return "PLN"
		1:
			return "MTN"
		2:
			return "FOR"
		3:
			return "SWA"
		4:
			return "FORT"
		5:
			return "VIL"
		6:
			return "RD"
		7:
			return "RIV"
	return "T%d" % t


static func _short_terrain(raw: String) -> String:
	var t := raw.strip_edges().to_upper()
	if t.is_empty():
		return "?"
	if t.contains("MOUNTAIN") or t.contains("CLIFF") or t.contains("IMPASS"):
		return "MTN"
	if t.contains("FOREST") or t.contains("WOOD"):
		return "FOR"
	if t.contains("RIVER") or t.contains("WATER"):
		return "RIV"
	if t.contains("SWAMP") or t.contains("MARSH"):
		return "SWA"
	if t.contains("ROAD"):
		return "RD"
	if t.contains("VILLAGE") or t.contains("TOWN"):
		return "VIL"
	if t.contains("FORT") or t.contains("WALL") or t.contains("STRONGHOLD"):
		return "FORT"
	if t.contains("PLAIN") or t.contains("GRASS") or t.contains("FIELD"):
		return "PLN"
	return t.left(4)


## Fresh revalidation of ONE candidate against CURRENT truth. Read-only:
## previews and gates only, never executes. Returns {ok, code}.
func revalidate(cand: Dictionary) -> Dictionary:
	if not is_ready():
		return {"ok": false, "code": "ENUMERATOR_NOT_READY"}
	if bool(_is_terminal.call()):
		return {"ok": false, "code": "BATTLE_ALREADY_TERMINAL"}
	var t: String = str(cand.get("action_type", ""))
	var uid: String = str(cand.get("unit_id", ""))
	if t == "END_TURN":
		return {"ok": false, "code": "END_TURN_NOT_LEGAL_PER_UNIT"}
	var u: Dictionary = (_manager as RefCounted).call("get_unit_by_id", uid)
	if u.is_empty() or int(u.get("soldier_count", 0)) <= 0:
		return {"ok": false, "code": "UNIT_GONE"}
	if bool(u.get("action_ended", false)):
		return {"ok": false, "code": "UNIT_ACTED"}
	match t:
		"MOVE":
			if _is_fortified(u):
				return {"ok": false, "code": "FORTIFIED_NO_MOVE"}
			var d: Array = cand.get("destination", [])
			if d.size() < 2:
				return {"ok": false, "code": "BAD_DESTINATION"}
			var route: Variant = (_service as RefCounted).call(
				"preview_move_route", uid, Vector2i(int(d[0]), int(d[1])), _side, MARCH_MODE)
			if route != null and bool(route.found) and bool(route.is_valid_destination):
				return {"ok": true, "code": ""}
			return {"ok": false, "code": "MOVE_NOT_LEGAL"}
		"ATTACK":
			var tid: String = str(cand.get("target_id", ""))
			for tv in ((_manager as RefCounted).call("get_attackable_targets", uid) as Array):
				if str((tv as Dictionary).get("id", "")) == tid \
						and bool((_projector as RefCounted).call("is_contact_visible", _side, tid)):
					return {"ok": true, "code": ""}
			return {"ok": false, "code": "ATTACK_NOT_LEGAL"}
		"ASSAULT":
			var sid: String = str(cand.get("stronghold_id", ""))
			var gid: String = str(cand.get("garrison_target_id", ""))
			for ev in ((_manager as RefCounted).call("get_attackable_strongholds", uid) as Array):
				var e: Dictionary = ev
				if str(e.get("structure_id", "")) != sid:
					continue
				if bool(e.get("breached", false)):
					if gid.is_empty():
						return {"ok": false, "code": "ASSAULT_NEEDS_GARRISON_TARGET"}
					var sh: Variant = (_manager as RefCounted).call("get_stronghold_by_id", sid)
					if sh != null:
						for g_val in (sh.call("get_garrison_roster") as Array):
							if str((g_val as Dictionary).get("id", "")) == gid:
								return {"ok": true, "code": ""}
					return {"ok": false, "code": "ASSAULT_TARGET_GONE"}
				if gid.is_empty():
					return {"ok": true, "code": ""}
				return {"ok": false, "code": "ASSAULT_NOT_BREACHED"}
			return {"ok": false, "code": "ASSAULT_NOT_LEGAL"}
		"WAIT":
			return {"ok": true, "code": ""}
		"REST":
			if bool((_manager as RefCounted).call("can_unit_rest", uid)):
				return {"ok": true, "code": ""}
			return {"ok": false, "code": "REST_NOT_LEGAL"}
		"FORTIFY":
			if bool((_manager as RefCounted).call("can_unit_fortify", uid)):
				return {"ok": true, "code": ""}
			return {"ok": false, "code": "FORTIFY_NOT_LEGAL"}
		"DISMANTLE":
			if bool((_manager as RefCounted).call("can_dismantle_fortification", uid)):
				return {"ok": true, "code": ""}
			return {"ok": false, "code": "DISMANTLE_NOT_LEGAL"}
		"ENTER_GARRISON":
			var esid: String = str(cand.get("stronghold_id", ""))
			var coord := Vector2i(int(u.get("q", 0)), int(u.get("r", 0)))
			for shv in ((_manager as RefCounted).call("get_all_strongholds") as Array):
				if str(shv.structure_id) != esid:
					continue
				if str(shv.owner) != str(u.get("faction", "")):
					return {"ok": false, "code": "GARRISON_NOT_OWN"}
				if not bool(shv.has_garrison_capacity()):
					return {"ok": false, "code": "GARRISON_FULL"}
				for h in shv.get_footprint():
					if HexUtilsCls.hex_distance_axial(coord, h) == 1 or coord == h:
						return {"ok": true, "code": ""}
				return {"ok": false, "code": "GARRISON_NOT_ADJACENT"}
			return {"ok": false, "code": "GARRISON_GONE"}
	return {"ok": false, "code": "UNKNOWN_ACTION"}
