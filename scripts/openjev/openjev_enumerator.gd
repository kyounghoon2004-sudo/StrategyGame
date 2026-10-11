class_name OpenJevEnumerator
extends RefCounted

## OPENJEV LIVE V0 — canonical direct-action enumerator for LIVE RED.
##
## Enumerates the COMPLETE immediate legal action set for ALL ready RED
## units through the SAME authoritative queries the human-equivalent live
## path uses. Owns no rules; every offer is re-checkable through the
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
##   REST ......... manager.can_unit_rest (authoritative: false for RED —
##                  the gate owns this, never offered, never pruned by us).
##   FORTIFY ...... manager.can_unit_fortify (same: false for RED).
##   DISMANTLE .... manager.can_dismantle_fortification (side-agnostic).
##   ENTER_GARRISON adjacent-or-on-footprint own stronghold + capacity
##                  (manager.garrison_enter rule, mirrored exactly).
##   END_TURN ..... offered IFF no unit-level candidate exists (the RED
##                  analog of the human contract: END TURN exists only when
##                  nothing remains to resolve) and the battle is live.
## Excluded with evidence (same as the human contract):
##   routed ....... shell refuses re-selection ("control lost").
##   garrisoned .. no field action offers; deploy path is dead UI.
##   convoy/supply logistics-cycle units (never human-commanded; the
##                  deterministic RED routine skips them too).
##   fortified units offer NO moves (stepwise rejects; dismantle first).
##
## Determinism: units ascending id; per unit MOVE (q,r asc), ATTACK (target
## id asc), ASSAULT (stronghold, garrison asc), WAIT, REST, FORTIFY,
## DISMANTLE, ENTER_GARRISON; END_TURN last. candidate_id is stable.
##
## Binds to EITHER the live battle (bridge + shell) or a SimController
## (headless parity): both expose manager/service/projector/grid/bounds.

const Step3PathfindingCls = preload("res://scripts/step3/step3_pathfinding.gd")
const Step3ConfigCls = preload("res://scripts/core/step3_config.gd")
const HexUtilsCls = preload("res://scripts/core/hex_utils.gd")

const SIDE := "red"
const MARCH_MODE := "green"

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


## Full legal pool for RED. Terminal battle -> no candidates at all
## (post-terminal actions cannot exist).
func enumerate_all() -> Dictionary:
	var out := {"side": SIDE, "terminal": false, "candidates": [], "unit_ids": []}
	if not is_ready():
		(out as Dictionary)["error"] = "Enumerator not configured."
		return out
	if bool(_is_terminal.call()):
		out["terminal"] = true
		return out
	var units: Array = []
	for u_val in (_manager as RefCounted).call("get_all_units"):
		var u: Dictionary = u_val
		if str(u.get("faction", "")) != SIDE:
			continue
		if int(u.get("soldier_count", 0)) <= 0:
			continue
		if bool(u.get("garrisoned", false)):
			continue
		if bool(u.get("routed", false)):
			continue
		if bool(u.get("is_convoy", false)) or str(u.get("class", "")) == "supply":
			continue
		units.append(u)
	units.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a.get("id", "")) < str(b.get("id", "")))
	var cands: Array = []
	for u in units:
		var uid: String = str((u as Dictionary).get("id", ""))
		(out["unit_ids"] as Array).append(uid)
		_append_unit_candidates(cands, u)
	if cands.is_empty():
		cands.append({"candidate_id": "END_TURN", "unit_id": "", "action_type": "END_TURN"})
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
	var occupied: Dictionary = (_projector as RefCounted).call("known_occupancy", SIDE)
	var policy: int = Step3ConfigCls.MarchPolicy.GREEN_ONLY
	var base_mp: float = float(u.get("base_mp", 2.0))
	var spent: float = float(u.get("turn_move_cost_spent", 0.0))
	var env: Variant = Step3PathfindingCls.calculate_envelope(
		origin, str(u.get("class", "infantry")), base_mp,
		float(u.get("remaining_mp", base_mp)), policy,
		cell_data, occupied, _rivers, SIDE, _stronghold_cells,
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
			"preview_move_route", uid, dest, SIDE, MARCH_MODE)
		if route == null or not bool(route.found) or not bool(route.is_valid_destination):
			continue
		var d: Vector2i = dest
		cands.append({
			"candidate_id": "MOVE|%s|%d,%d" % [uid, d.x, d.y],
			"unit_id": uid, "action_type": "MOVE",
			"origin": [origin.x, origin.y],
			"destination": [d.x, d.y],
			"cost": float(route.cost), "march_class": int(route.march_class),
		})


func _append_attacks(cands: Array, u: Dictionary) -> void:
	var uid: String = str(u.get("id", ""))
	var targets: Array = (_manager as RefCounted).call("get_attackable_targets", uid)
	var vis: Array = []
	for t_val in targets:
		var t: Dictionary = t_val
		var tid: String = str(t.get("id", ""))
		if bool((_projector as RefCounted).call("is_contact_visible", SIDE, tid)):
			vis.append(t)
	vis.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a.get("id", "")) < str(b.get("id", "")))
	for t in vis:
		var tid: String = str((t as Dictionary).get("id", ""))
		cands.append({
			"candidate_id": "ATTACK|%s|%s" % [uid, tid],
			"unit_id": uid, "action_type": "ATTACK", "target_id": tid,
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
		var pool: Dictionary = enumerate_all()
		var only: Array = pool.get("candidates", [])
		if only.size() == 1 and str((only[0] as Dictionary).get("action_type", "")) == "END_TURN":
			return {"ok": true, "code": ""}
		return {"ok": false, "code": "END_TURN_NOT_LEGAL"}
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
				"preview_move_route", uid, Vector2i(int(d[0]), int(d[1])), SIDE, MARCH_MODE)
			if route != null and bool(route.found) and bool(route.is_valid_destination):
				return {"ok": true, "code": ""}
			return {"ok": false, "code": "MOVE_NOT_LEGAL"}
		"ATTACK":
			var tid: String = str(cand.get("target_id", ""))
			for tv in ((_manager as RefCounted).call("get_attackable_targets", uid) as Array):
				if str((tv as Dictionary).get("id", "")) == tid \
						and bool((_projector as RefCounted).call("is_contact_visible", SIDE, tid)):
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
