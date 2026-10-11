class_name DirectLegalEnumerator
extends RefCounted

## Research-only (DIRECT_LEGAL_OPENJEV_POC_V0): enumerates the COMPLETE immediate
## legal action set for ALL ready blue units through the SAME authoritative
## queries the human shell path uses. Owns no rules.
##
## Human-path mirrors (step2r_battlefield_shell.gd + step3_unit_manager.gd):
##   MOVE ......... click hex -> find_route(found && is_valid_destination)
##                  [shell _update_preview_for_target / _execute_confirmed_move]
##   ATTACK ....... get_attackable_targets + fog-visible filter
##                  [shell _recalculate_envelope_for_unit]
##   ASSAULT ...... get_attackable_strongholds; breached strongholds require a
##                  per-garrison-unit target [manager execute_stronghold_assault]
##   WAIT (=HOLD) . button enabled iff not action_ended [shell _btn_wait gating]
##   REST ......... can_unit_rest / rest_unit
##   FORTIFY ...... can_unit_fortify / fortify_unit
##   DISMANTLE .... can_dismantle_fortification / dismantle_fortification
## Fortified units offer NO moves (stepwise rejects; dismantle first).
##   ENTER_GARRISON  adjacent own-stronghold + capacity [shell can_enter block]
##   END_TURN ..... always during a live player phase [shell end_player_phase]
## Excluded with evidence:
##   DEPLOY ....... _begin_deploy_mode has NO callers (dead UI path)
##   routed ....... shell refuses re-selection ("control lost")
##   garrisoned .. no field action offers; deploy path is dead
##
## Determinism: units in ascending id order; per unit MOVE (q,r ascending),
## ATTACK (target id ascending), ASSAULT (stronghold, garrison ascending),
## WAIT, REST, FORTIFY, DISMANTLE, ENTER_GARRISON; END_TURN last.
## candidate_id is stable.

const Step3PathfindingCls = preload("res://scripts/step3/step3_pathfinding.gd")
const Step3ConfigCls = preload("res://scripts/core/step3_config.gd")
const HexUtilsCls = preload("res://scripts/core/hex_utils.gd")

var _sim: RefCounted = null
var _manager: RefCounted = null
var _service: RefCounted = null
var _shim: Node = null
var _grid: Node = null


func configure(sim: RefCounted) -> String:
	_sim = sim
	if _sim == null:
		return "Enumerator needs a SimController."
	_manager = _sim.get_manager()
	_service = _sim.get_service()
	_shim = _sim.get("_shim") as Node
	_grid = _sim.get("_grid") as Node
	if _manager == null or _service == null or _shim == null or _grid == null:
		return "Enumerator needs loaded sim (manager/service/shim/grid)."
	return ""


func is_ready() -> bool:
	return _sim != null and _manager != null and _service != null and _shim != null and _grid != null


## Full legal pool for `side` ("blue"). Terminal battle -> no candidates at
## all (the shell ignores END TURN once the battle is over).
func enumerate_all(side: String = "blue") -> Dictionary:
	var out := {"side": side, "terminal": false, "candidates": [], "unit_ids": []}
	if not is_ready():
		(out as Dictionary)["error"] = "Enumerator not configured."
		return out
	var battle: Dictionary = (_sim as RefCounted).call("evaluate_battle")
	if bool(battle.get("terminal", false)):
		out["terminal"] = true
		return out
	var units: Array = []
	for u_val in (_manager as RefCounted).call("get_all_units"):
		var u: Dictionary = u_val
		if str(u.get("faction", "")) != side:
			continue
		if int(u.get("soldier_count", 0)) <= 0:
			continue
		if bool(u.get("garrisoned", false)):
			continue
		if bool(u.get("routed", false)):
			continue
		units.append(u)
	units.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a.get("id", "")) < str(b.get("id", "")))
	var cands: Array = []
	for u in units:
		var uid: String = str((u as Dictionary).get("id", ""))
		(out["unit_ids"] as Array).append(uid)
		_append_unit_candidates(cands, u, side)
	cands.append({"candidate_id": "END_TURN", "unit_id": "", "action_type": "END_TURN"})
	out["candidates"] = cands
	return out


func _append_unit_candidates(cands: Array, u: Dictionary, side: String) -> void:
	var uid: String = str(u.get("id", ""))
	var ended: bool = bool(u.get("action_ended", false))
	if not ended:
		if not _is_fortified(u):
			_append_moves(cands, u, side)
		_append_attacks(cands, u, side)
		_append_assaults(cands, u, side)
		cands.append({"candidate_id": "WAIT|%s" % uid, "unit_id": uid, "action_type": "WAIT"})
		if bool((_manager as RefCounted).call("can_unit_rest", uid)):
			cands.append({"candidate_id": "REST|%s" % uid, "unit_id": uid, "action_type": "REST"})
		if bool((_manager as RefCounted).call("can_unit_fortify", uid)):
			cands.append({"candidate_id": "FORTIFY|%s" % uid, "unit_id": uid, "action_type": "FORTIFY"})
		if bool((_manager as RefCounted).call("can_dismantle_fortification", uid)):
			cands.append({"candidate_id": "DISMANTLE|%s" % uid, "unit_id": uid, "action_type": "DISMANTLE"})
		_append_enter_garrison(cands, u)


func _is_fortified(u: Dictionary) -> bool:
	return bool(u.get("field_fortified", false)) or int(u.get("field_fortification_hp", 0)) > 0 or bool(u.get("fortified", false))


## MOVE legality == the human click path: find_route(found && valid) with the
## shell's exact arguments. Seeds come from calculate_envelope (same call the
## shell highlights from); every seed is re-confirmed by find_route.
func _append_moves(cands: Array, u: Dictionary, side: String) -> void:
	var uid: String = str(u.get("id", ""))
	var origin := Vector2i(int(u.get("q", 0)), int(u.get("r", 0)))
	var cell_data: Dictionary = _grid.get("cell_data") as Dictionary if _grid else {}
	# BLUE follows the battlefield shell's player-known occupancy. RED uses the
	# authorized observation projector (own units plus currently observed
	# enemies) and the same GREEN_ONLY policy as SimController._red_move.
	var occupied: Dictionary
	var policy: int
	if side == "blue":
		occupied = (_shim as Node).call("_player_known_occupied")
		policy = int((_manager as RefCounted).call("get_policy"))
	else:
		occupied = (_service as RefCounted).call("_occupied_for", side)
		policy = Step3ConfigCls.MarchPolicy.GREEN_ONLY
	var base_mp: float = float(u.get("base_mp", 2.0))
	var spent: float = float(u.get("turn_move_cost_spent", 0.0))
	var bounds: Dictionary = (_sim as RefCounted).call("map_bounds")
	var projection: RefCounted = (_sim as RefCounted).call("get_projector")
	var env: Variant = Step3PathfindingCls.calculate_envelope(
		origin, str(u.get("class", "infantry")), base_mp,
		float(u.get("remaining_mp", base_mp)), policy,
		cell_data, occupied,
		_shim.get("_river_cells") as Dictionary, side,
		_shim.get("_stronghold_cells") as Dictionary,
		spent,
		float(u.get("blue_limit", Step3ConfigCls.get_blue_limit(base_mp))),
		float(u.get("red_limit", Step3ConfigCls.get_red_limit(base_mp))),
		float(u.get("black_limit", Step3ConfigCls.get_black_limit(base_mp)))
	)
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
		var route: Variant = Step3PathfindingCls.find_route(
			origin, dest, str(u.get("class", "infantry")), base_mp,
			float(u.get("remaining_mp", base_mp)), policy,
			cell_data, occupied,
			_shim.get("_river_cells") as Dictionary, side,
			_shim.get("_stronghold_cells") as Dictionary,
			spent,
			float(u.get("blue_limit", Step3ConfigCls.get_blue_limit(base_mp))),
			float(u.get("red_limit", Step3ConfigCls.get_red_limit(base_mp))),
			float(u.get("black_limit", Step3ConfigCls.get_black_limit(base_mp))),
			bounds)
		var route_ok: bool = route != null and bool(route.found) and bool(route.is_valid_destination)
		if not route_ok:
			continue
		var d: Vector2i = dest
		var route_fully_visible := true
		if projection != null:
			for step_val in route.path:
				var step: Vector2i = step_val
				if not bool(projection.call("is_hex_visible_for_side", side, step.x, step.y)):
					route_fully_visible = false
					break
		cands.append({
			"candidate_id": "MOVE|%s|%d,%d" % [uid, d.x, d.y],
			"unit_id": uid, "action_type": "MOVE",
			"destination": [d.x, d.y],
			"cost": float(route.cost), "march_class": int(route.march_class),
			"route_fully_visible": route_fully_visible,
		})


func _append_attacks(cands: Array, u: Dictionary, side: String) -> void:
	var uid: String = str(u.get("id", ""))
	var targets: Array = (_manager as RefCounted).call("get_attackable_targets", uid)
	var vis: Array = []
	for t_val in targets:
		var t: Dictionary = t_val
		var tid: String = str(t.get("id", ""))
		if _is_enemy_visible_to_side(tid, side):
			vis.append(t)
	vis.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a.get("id", "")) < str(b.get("id", "")))
	for t in vis:
		var tid: String = str((t as Dictionary).get("id", ""))
		cands.append({
			"candidate_id": "ATTACK|%s|%s" % [uid, tid],
			"unit_id": uid, "action_type": "ATTACK", "target_id": tid,
		})


func _append_assaults(cands: Array, u: Dictionary, side: String) -> void:
	var uid: String = str(u.get("id", ""))
	var entries: Array = (_manager as RefCounted).call("get_attackable_strongholds", uid)
	entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a.get("structure_id", "")) < str(b.get("structure_id", "")))
	for e_val in entries:
		var e: Dictionary = e_val
		var sid: String = str(e.get("structure_id", ""))
		if bool(e.get("breached", false)):
			# Roster from the stronghold object (same call the panel uses).
			var sh: Variant = (_manager as RefCounted).call("get_stronghold_by_id", sid)
			var roster: Array = (sh.call("get_garrison_roster") as Array).duplicate() if sh != null else []
			roster.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a.get("id", "")) < str(b.get("id", "")))
			for g_val in roster:
				var gid: String = str((g_val as Dictionary).get("id", ""))
				# Garrison target IDs are observable to the bot only if the defender
				# is in the side-authorized current contact set.
				if not _is_enemy_visible_to_side(gid, side):
					continue
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


func _is_enemy_visible_to_side(enemy_id: String, side: String) -> bool:
	if side == "blue":
		return bool((_shim as Node).call("_fog_is_enemy_visible", enemy_id))
	var projector: Variant = (_service as RefCounted).get("projector")
	return projector != null and bool((projector as RefCounted).call("is_contact_visible", side, enemy_id))


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
		var adj := false
		for h in sh.get_footprint():
			if HexUtilsCls.hex_distance_axial(coord, h) == 1:
				adj = true
				break
		if adj:
			cands.append({
				"candidate_id": "ENTER_GARRISON|%s|%s" % [uid, str(sh.structure_id)],
				"unit_id": uid, "action_type": "ENTER_GARRISON",
				"stronghold_id": str(sh.structure_id),
			})
