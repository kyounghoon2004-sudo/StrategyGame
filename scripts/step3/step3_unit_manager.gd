class_name Step3UnitManager
extends RefCounted

## STEP-03 & STEP-04R2 Unit Manager & Turn State Engine
## Tracks per-unit movement budgets, morale, combat state, fortress shields, Cavalry exploitation, (food/supply retired globally)
## AND multi-hex stronghold garrison system (STEP-04R2).
##
## Preserves STEP-04R1 fixes:
##   - RED infinite movement bug: cumulative per-turn budgets, no selection refresh
##   - NEXT unit flow
## Adds STEP-04R2:
##   - Multi-hex stronghold architecture (Fortress + Capital, 3-hex footprint each)
##   - Garrison enter/deploy with field↔roster transition
##   - One wall pool fortification shield
##   - Breach + multi-garrison targeting
##   - Perimeter queries + footprint occupancy blocking

const HexUtilsCls = preload("res://scripts/core/hex_utils.gd")
const Step3ConfigCls = preload("res://scripts/core/step3_config.gd")
const CombatCalculatorCls = preload("res://scripts/combat/combat_calculator.gd")
# 2026-10-06 (user): no field fortification anywhere unless the env FIELD_FORTIFY=1 (A/B tests).
var FIELD_FORTIFY_DISABLED: bool = OS.get_environment("FIELD_FORTIFY").strip_edges() != "1"
const StrongholdCls = preload("res://scripts/core/stronghold.gd")
const StrongholdManagerCls = preload("res://scripts/core/stronghold_manager.gd")
const Step6ConfigCls = preload("res://scripts/step6/step6_config.gd")

signal selection_changed(selected_unit: Dictionary)
signal unit_moved(unit_id: String, from_coord: Vector2i, to_coord: Vector2i, march_class: int)
signal turn_advanced(new_turn: int)
signal policy_changed(new_policy: int)
signal combat_resolved(combat_result: Dictionary)
signal unit_damaged(unit_id: String, casualties: int, remaining_troops: int, morale_delta: float)
signal unit_destroyed(unit_id: String, coord: Vector2i)
signal fortress_damaged(coord: Vector2i, damage: int, remaining_hp: int)
# STEP-04R2 new signals
signal stronghold_damaged(stronghold_id: String, wall_damage: int, remaining_hp: int, breached: bool)
signal garrison_entered(unit_id: String, stronghold_id: String, garrison_count: int)
signal garrison_deployed(unit_id: String, stronghold_id: String, target_hex: Vector2i)
signal garrison_target_damaged(garrison_unit_id: String, casualties: int, remaining_troops: int, stronghold_id: String)
# STEP-04R7.1 temporary field fortification signals
signal field_fortification_created(unit_id: String, hp: int)
signal field_fortification_damaged(unit_id: String, damage: int, remaining_hp: int)
signal field_fortification_destroyed(unit_id: String)
signal field_fortification_abandoned(unit_id: String)
# STEP-05 observable event stream (world-truth-free: only player-observable facts
# such as casualties/positions — never hidden morale/AI state). Future SLM input.
signal observable_event(evt: Dictionary)

var _units: Dictionary = {}         # unit_id -> Dictionary
var _occupied_map: Dictionary = {}  # "q,r" -> unit_id
var _fortress_map: Dictionary = {}  # "q,r" -> int fortification_hp (legacy compat, kept in sync)
var _map_bounds: Dictionary = {}    # scenario rect; empty = unconstrained (legacy)
var _selected_unit_id: String = ""
var _current_policy: int = Step3ConfigCls.MarchPolicy.RED_ALLOWED
var _current_turn: int = 1

# STEP-04R2 stronghold system
var _stronghold_mgr: RefCounted = null
var _garrisoned: Dictionary = {}    # unit_id -> stronghold_id
var _reviewed: Dictionary = {}      # unit_id -> bool (for NEXT flow)

# Default stronghold definitions for STEP-04R2 prototype
const DEFAULT_FORTRESS_FOOTPRINT: Array[Vector2i] = [Vector2i(-4, 2), Vector2i(-3, 2), Vector2i(-4, 3)]
const DEFAULT_CAPITAL_FOOTPRINT: Array[Vector2i] = [Vector2i(14, -5), Vector2i(15, -5), Vector2i(14, -4)]
const DEFAULT_FORTRESS_ID: String = "Fortress_Hulao"
const DEFAULT_CAPITAL_ID: String = "Capital_Luoyang"

# STEP-04R10/R11: Dismantling field fortification costs 1.0 MP; remaining MP can be used to move in the same turn
const FIELD_FORTIFICATION_DISMANTLE_MP_COST: float = 1.0

# STEP-05: capped observable event history for the future Advisor SLM (§18).
const OBSERVABLE_EVENT_CAP: int = 200
var _observable_events: Array = []

# ------------------------------------------------------------------
# Initialization
# ------------------------------------------------------------------
## `stronghold_defs` (scenario data, canonical battlefields): when non-empty it
## replaces the default Hulao/Luoyang registration with the map's own
## strongholds of the SAME existing types and rules. Empty = default map.
func initialize_from_renderer_units(renderer_units: Array, enable_strongholds: bool = true, stronghold_defs: Array = []) -> void:
	_units.clear()
	_occupied_map.clear()
	_fortress_map.clear()
	_selected_unit_id = ""
	_current_turn = 1
	_garrisoned.clear()
	_reviewed.clear()

	# Stronghold manager init
	_stronghold_mgr = StrongholdManagerCls.new()
	_stronghold_mgr.bind_occupancy(_occupied_map, self)

	if enable_strongholds and not stronghold_defs.is_empty():
		for sd in stronghold_defs:
			var fp: Array[Vector2i] = []
			for h in sd.get("footprint", []):
				fp.append(h)
			var st: int = StrongholdCls.StrongholdType.CAPITAL if str(sd.get("type", "")) == "capital" else StrongholdCls.StrongholdType.FORTRESS
			var hp: int = int(sd.get("hp", 1000))
			var sh: RefCounted = StrongholdCls.new(str(sd.get("id", "")), st, str(sd.get("owner", "red")), fp, hp, int(sd.get("slots", 4)))
			_stronghold_mgr.register_stronghold(sh)
			for h in fp:
				_fortress_map["%d,%d" % [h.x, h.y]] = hp
	elif enable_strongholds:
		# Register default multi-hex strongholds (§27 Current Map Requirement)
		# Fortress: 3 hexes, 4 slots, 1000 HP, Late Tang owner = red (enemy for blue player)
		var fortress_sh: RefCounted = StrongholdCls.new(
			DEFAULT_FORTRESS_ID,
			StrongholdCls.StrongholdType.FORTRESS,
			"red",
			DEFAULT_FORTRESS_FOOTPRINT,
			1000,
			4
		)
		_stronghold_mgr.register_stronghold(fortress_sh)
		for h in DEFAULT_FORTRESS_FOOTPRINT:
			_fortress_map["%d,%d" % [h.x, h.y]] = 1000

		# Capital: 3 hexes, 6 slots, 1500 HP (stronger), red owner, objective
		var capital_sh: RefCounted = StrongholdCls.new(
			DEFAULT_CAPITAL_ID,
			StrongholdCls.StrongholdType.CAPITAL,
			"red",
			DEFAULT_CAPITAL_FOOTPRINT,
			1500,
			6
		)
		_stronghold_mgr.register_stronghold(capital_sh)
		for h in DEFAULT_CAPITAL_FOOTPRINT:
			_fortress_map["%d,%d" % [h.x, h.y]] = 1500

	for u in renderer_units:
		var id: String = str(u.get("id", ""))
		var unit_class: String = str(u.get("class", "infantry"))
		if unit_class.to_lower() == "supply":
			continue # SUP-1: Supply-class units are retired and cannot spawn
		var faction: String = str(u.get("faction", "blue"))
		var q: int = int(u.get("q", 0))
		var r: int = int(u.get("r", 0))
		var soldier_count: int = int(u.get("soldier_count", 100))
		var max_count: int = int(u.get("max_count", soldier_count))
		var form_factor: String = str(u.get("form_factor", "form_a"))
		var base_mp: float = Step3ConfigCls.get_base_movement(unit_class)
		var blue_lim: float = Step3ConfigCls.get_blue_limit(base_mp)
		var red_lim: float = Step3ConfigCls.get_red_limit(base_mp)
		var black_lim: float = Step3ConfigCls.get_black_limit(base_mp)

		# §8 Stronghold occupancy: ordinary field units should not stand
		# independently on footprint hexes as if they were normal plains.
		# If a test unit was placed on a footprint hex, it belongs in garrison.
		var coord := Vector2i(q, r)
		var sh_at: Variant = _stronghold_mgr.get_stronghold_at_coord(coord) if _stronghold_mgr else null
		if sh_at != null:
			# This unit is on a stronghold footprint — move to garrison directly
			# Check ownership match: only same-faction units can be garrisoned
			if sh_at.owner == faction and sh_at.has_garrison_capacity():
				var legacy_data: Dictionary = {
					"id": id,
					"class": unit_class,
					"faction": faction,
					"q": q,
					"r": r,
					"soldier_count": soldier_count,
					"max_count": max_count,
					"form_factor": form_factor,
					"base_mp": base_mp,
					"blue_limit": blue_lim,
					"red_limit": red_lim,
					"black_limit": black_lim,
					"turn_move_cost_spent": 0.0,
					"remaining_mp": base_mp,
					"morale": 100.0,
					"action_ended": false,
					"has_moved": false,
					"has_attacked": false,
					"fortified": false,
					"field_fortified": false,
					"field_fortification_hp": 0,
					"field_fortification_hp_max": 0,
					"rested_this_turn": false,
					"resting_unguarded": false,
					"defense_ready": false,
					"unguarded": false,
					"turn_resolved": false,
					"reviewed_this_turn": false,
					"fatigue": 0.0,
					"routed": false,
					"rout_turns": 0,
					"is_hq": unit_class == "hq",
					"retreat_mark": false
				}
				var g_res: Dictionary = sh_at.enter_garrison(legacy_data)
				if g_res.get("success", false):
					_garrisoned[id] = sh_at.structure_id
					# Still track in _units for morale/troop preservation but mark garrisoned
					legacy_data["garrisoned"] = true
					legacy_data["stronghold_id"] = sh_at.structure_id
					_units[id] = legacy_data
					continue

		var unit_data: Dictionary = {
			"id": id,
			"class": unit_class,
			"faction": faction,
			"q": q,
			"r": r,
			"soldier_count": soldier_count,
			"max_count": max_count,
			"form_factor": form_factor,
			"base_mp": base_mp,
			"blue_limit": blue_lim,
			"red_limit": red_lim,
			"black_limit": black_lim,
			"turn_move_cost_spent": 0.0,
			"remaining_mp": base_mp,
			"morale": 100.0,
			"action_ended": false,
			"has_moved": false,
			"has_attacked": false,
			"fortified": false,
			"field_fortified": false,
			"field_fortification_hp": 0,
			"field_fortification_hp_max": 0,
			"rested_this_turn": false,
			"resting_unguarded": false,
			"defense_ready": false,
			"unguarded": false,
			"turn_resolved": false,
			"reviewed_this_turn": false,
			"garrisoned": false,
			"stronghold_id": "",
			"fatigue": 0.0,
			"routed": false,
			"rout_turns": 0,
			"is_hq": unit_class == "hq",
			"retreat_mark": false
		}
		_units[id] = unit_data
		var occ_key: String = "%d,%d" % [q, r]
		if _occupied_map.has(occ_key):
			# STEP-05R1 occupancy invariant: 0 or 1 field formation per hex.
			# Never silently stack two formations on one hex — relocate deterministically.
			var free_hex: Vector2i = _find_nearest_free_hex(coord)
			if free_hex.x != -999:
				print("[Step3UnitManager] OCCUPANCY FIX: %s duplicate hex %s -> relocated to (%d,%d)" % [id, occ_key, free_hex.x, free_hex.y])
				unit_data["q"] = free_hex.x
				unit_data["r"] = free_hex.y
				occ_key = "%d,%d" % [free_hex.x, free_hex.y]
			else:
				push_warning("[Step3UnitManager] OCCUPANCY VIOLATION: no free hex for %s near %s" % [id, occ_key])
		_occupied_map[occ_key] = id

# ------------------------------------------------------------------
# STRONGHOLD ACCESSORS (§24 Structure Perimeter Query)
# ------------------------------------------------------------------
func get_stronghold_manager() -> RefCounted:
	return _stronghold_mgr

func get_all_strongholds() -> Array:
	if _stronghold_mgr:
		return _stronghold_mgr.get_all_strongholds()
	return []

func get_stronghold_by_id(id: String) -> Variant:
	if _stronghold_mgr:
		return _stronghold_mgr.get_stronghold_by_id(id)
	return null

func is_stronghold_hex(q: int, r: int) -> bool:
	if _stronghold_mgr:
		return _stronghold_mgr.is_stronghold_hex(q, r)
	return false

func is_stronghold_hex_coord(coord: Vector2i) -> bool:
	if _stronghold_mgr:
		return _stronghold_mgr.is_stronghold_coord(coord)
	return false

func get_stronghold_at(q: int, r: int) -> Variant:
	if _stronghold_mgr:
		return _stronghold_mgr.get_stronghold_at(q, r)
	return null

func get_stronghold_at_coord(coord: Vector2i) -> Variant:
	if _stronghold_mgr:
		return _stronghold_mgr.get_stronghold_at_coord(coord)
	return null

func get_stronghold_perimeter_hexes(id: String) -> Array[Vector2i]:
	if _stronghold_mgr:
		return _stronghold_mgr.get_stronghold_perimeter_hexes(id)
	return []

func get_valid_assault_positions(id: String) -> Array[Vector2i]:
	if _stronghold_mgr:
		return _stronghold_mgr.get_valid_assault_positions(id)
	return []

func get_valid_deployment_hexes(id: String, garrison_unit_id: String = "") -> Array[Vector2i]:
	if _stronghold_mgr == null:
		return []
	# Use occupancy-aware version
	if _stronghold_mgr.has_method("get_valid_deployment_hexes2"):
		return _stronghold_mgr.get_valid_deployment_hexes2(id, garrison_unit_id)
	return _stronghold_mgr.get_valid_deployment_hexes(id, garrison_unit_id)

# ------------------------------------------------------------------
# GARRISON STATE (§4, §6, §7)
# ------------------------------------------------------------------
func is_garrisoned(unit_id: String) -> bool:
	return _garrisoned.has(unit_id)

func get_garrison_stronghold_id(unit_id: String) -> String:
	return str(_garrisoned.get(unit_id, ""))

func get_garrison_roster(stronghold_id: String) -> Array:
	var sh: Variant = get_stronghold_by_id(stronghold_id)
	if sh:
		return sh.get_garrison_roster()
	return []

func get_all_garrisoned_units() -> Array:
	var result: Array = []
	for uid in _garrisoned.keys():
		var sid: String = str(_garrisoned[uid])
		var sh: Variant = get_stronghold_by_id(sid)
		if sh:
			var gu: Dictionary = sh.get_garrison_unit(uid)
			if not gu.is_empty():
				result.append(gu)
	return result

func set_garrison_state(unit_id: String, garrisoned: bool, stronghold_id: String = "") -> void:
	if garrisoned:
		_garrisoned[unit_id] = stronghold_id
		if _units.has(unit_id):
			_units[unit_id]["garrisoned"] = true
			_units[unit_id]["stronghold_id"] = stronghold_id
	else:
		_garrisoned.erase(unit_id)
		if _units.has(unit_id):
			_units[unit_id]["garrisoned"] = false
			_units[unit_id]["stronghold_id"] = ""

func restore_from_garrison(unit_id: String, q: int, r: int, unit_data: Dictionary) -> bool:
	var key: String = "%d,%d" % [q, r]
	if _occupied_map.has(key):
		return false
	if _stronghold_mgr and _stronghold_mgr.is_stronghold_hex(q, r):
		return false
	var base_mp: float = Step3ConfigCls.get_base_movement(str(unit_data.get("class", "infantry")))
	var blue_lim: float = Step3ConfigCls.get_blue_limit(base_mp)
	var red_lim: float = Step3ConfigCls.get_red_limit(base_mp)
	var black_lim: float = Step3ConfigCls.get_black_limit(base_mp)
	var restored: Dictionary = {
		"id": unit_id,
		"class": str(unit_data.get("class", "infantry")),
		"faction": str(unit_data.get("faction", "neutral")),
		"q": q,
		"r": r,
		"soldier_count": int(unit_data.get("soldier_count", 0)),
		"max_count": int(unit_data.get("max_count", int(unit_data.get("soldier_count", 0)))),
		"form_factor": str(unit_data.get("form_factor", "form_a")),
		"base_mp": base_mp,
		"blue_limit": blue_lim,
		"red_limit": red_lim,
		"black_limit": black_lim,
		"turn_move_cost_spent": 0.0,
		"remaining_mp": base_mp,
		"morale": float(unit_data.get("morale", 100.0)),
		"action_ended": false,
		"has_moved": false,
		"has_attacked": false,
		"fortified": false,
		"field_fortified": false,
		"field_fortification_hp": 0,
		"field_fortification_hp_max": 0,
		"field_fortify_used": bool(unit_data.get("field_fortify_used", false)),
		"rested_this_turn": false,
		"resting_unguarded": false,
		"defense_ready": false,
		"unguarded": false,
		"turn_resolved": false,
		"reviewed_this_turn": false,
		"garrisoned": false,
		"stronghold_id": "",
		"fatigue": 0.0,
		"routed": false,
		"rout_turns": 0,
		"is_hq": str(unit_data.get("class", "")) == "hq",
		"retreat_mark": false
	}
	_units[unit_id] = restored
	_occupied_map[key] = unit_id
	_garrisoned.erase(unit_id)
	return true

## Garrison entry command (§6): friendly unit adjacent to or entering friendly stronghold
## Returns {success, reason, garrison_count?}
func garrison_enter(unit_id: String, stronghold_id: String) -> Dictionary:
	if not _units.has(unit_id):
		return {"success": false, "reason": "Unit not found"}
	if _garrisoned.has(unit_id):
		return {"success": false, "reason": "Unit already garrisoned"}
	var u: Dictionary = _units[unit_id]
	if bool(u.get("action_ended", false)):
		return {"success": false, "reason": "Unit action already ended"}
	var sh: Variant = get_stronghold_by_id(stronghold_id)
	if sh == null:
		return {"success": false, "reason": "Stronghold not found"}
	if sh.owner != str(u.get("faction", "")):
		return {"success": false, "reason": "Cannot enter enemy/neutral stronghold"}
	if not sh.has_garrison_capacity():
		return {"success": false, "reason": "Garrison full (%d/%d)" % [sh.get_garrison_count(), sh.garrison_slots]}
	# Check adjacency: unit must be adjacent to any footprint hex or on an adjacent legal entry hex
	var uq: int = int(u.get("q", 0))
	var ur: int = int(u.get("r", 0))
	var adj_ok: bool = false
	for h in sh.get_footprint():
		if HexUtilsCls.hex_distance_axial(Vector2i(uq, ur), h) == 1:
			adj_ok = true
			break
		if Vector2i(uq, ur) == h:
			adj_ok = true
			break
	if not adj_ok:
		return {"success": false, "reason": "Unit not adjacent to stronghold"}
	# Remove field occupancy and add to garrison roster
	var old_key: String = "%d,%d" % [uq, ur]
	_occupied_map.erase(old_key)
	# Preserve troop count, class, morale
	var entry_data: Dictionary = {
		"id": unit_id,
		"class": str(u.get("class", "infantry")),
		"faction": str(u.get("faction", "")),
		"q": uq,
		"r": ur,
		"soldier_count": int(u.get("soldier_count", 0)),
		"max_count": int(u.get("max_count", int(u.get("soldier_count", 0)))),
		"form_factor": str(u.get("form_factor", "form_a")),
		"base_mp": float(u.get("base_mp", 2.0)),
		"blue_limit": float(u.get("blue_limit", 2.0)),
		"red_limit": float(u.get("red_limit", 4.0)),
		"black_limit": float(u.get("black_limit", 4.4)),
		"turn_move_cost_spent": float(u.get("turn_move_cost_spent", 0.0)),
		"remaining_mp": float(u.get("remaining_mp", 2.0)),
		"morale": float(u.get("morale", 100.0))
	}
	var res: Dictionary = sh.enter_garrison(entry_data)
	if not res.get("success", false):
		# Rollback occupancy
		_occupied_map[old_key] = unit_id
		return {"success": false, "reason": res.get("reason", "Garrison entry failed")}
	_garrisoned[unit_id] = stronghold_id
	_units[unit_id]["garrisoned"] = true
	_units[unit_id]["stronghold_id"] = stronghold_id
	if _selected_unit_id == unit_id:
		deselect()
	garrison_entered.emit(unit_id, stronghold_id, sh.get_garrison_count())
	return {"success": true, "reason": "Entered garrison", "garrison_count": sh.get_garrison_count(), "remaining_slots": sh.get_available_slots()}

## Garrison deploy command (§7): deploy back to valid adjacent empty hex
func garrison_deploy(garrison_unit_id: String, target_hex: Vector2i, stronghold_id: String = "") -> Dictionary:
	var sid: String = stronghold_id
	if sid == "":
		sid = get_garrison_stronghold_id(garrison_unit_id)
	if sid == "":
		return {"success": false, "reason": "Unit not in garrison"}
	var sh: Variant = get_stronghold_by_id(sid)
	if sh == null:
		return {"success": false, "reason": "Stronghold not found"}
	if not sh.has_garrison_unit(garrison_unit_id):
		return {"success": false, "reason": "Garrison unit not found"}
	# Validate deployment hex
	var tk: String = "%d,%d" % [target_hex.x, target_hex.y]
	if _occupied_map.has(tk):
		return {"success": false, "reason": "Destination occupied"}
	if _stronghold_mgr and _stronghold_mgr.is_stronghold_hex(target_hex.x, target_hex.y):
		return {"success": false, "reason": "Destination inside stronghold footprint"}
	var adj_ok: bool = false
	for h in sh.get_footprint():
		if HexUtilsCls.hex_distance_axial(target_hex, h) == 1:
			adj_ok = true
			break
	if not adj_ok:
		return {"success": false, "reason": "Deployment hex not adjacent to stronghold"}
	var unit_data: Dictionary = sh.deploy_garrison_unit(garrison_unit_id)
	if unit_data.is_empty():
		return {"success": false, "reason": "Failed to remove from roster"}
	# Restore to field
	var ok: bool = restore_from_garrison(garrison_unit_id, target_hex.x, target_hex.y, unit_data)
	if not ok:
		# Rollback: re-add to garrison
		sh.enter_garrison(unit_data)
		return {"success": false, "reason": "Failed to restore to field"}
	garrison_deployed.emit(garrison_unit_id, sid, target_hex)
	return {"success": true, "reason": "Deployed", "unit_id": garrison_unit_id, "target_hex": target_hex, "troop_count": int(unit_data.get("soldier_count", 0)), "morale": float(unit_data.get("morale", 100.0))}

# ------------------------------------------------------------------
# Fortress State (Section 23, 24, 25) — now bridged to StrongholdManager
# ------------------------------------------------------------------
func set_fortress_hp(q: int, r: int, hp: int) -> void:
	var key: String = "%d,%d" % [q, r]
	_fortress_map[key] = hp
	# Sync to stronghold if this coord is part of a footprint
	var sh: Variant = get_stronghold_at(q, r)
	if sh:
		sh.fortification_hp = hp
		sh.breached = (hp <= 0)
		if hp <= 0:
			sh.fortification_hp = 0
			sh.breached = true

func get_fortress_hp(q: int, r: int) -> int:
	var sh: Variant = get_stronghold_at(q, r)
	if sh:
		return sh.fortification_hp
	var key: String = "%d,%d" % [q, r]
	return int(_fortress_map.get(key, 0))

# Stronghold-aware fortification query for any coordinate near footprint
func get_fortification_for_coord(q: int, r: int) -> int:
	return get_fortress_hp(q, r)

func get_fortification_for_stronghold(stronghold_id: String) -> int:
	var sh: Variant = get_stronghold_by_id(stronghold_id)
	if sh:
		return sh.fortification_hp
	return 0

# ------------------------------------------------------------------
# Selection (Section 3)
# ------------------------------------------------------------------
func select_unit(id: String) -> bool:
	if not _units.has(id):
		deselect()
		return false
	if _garrisoned.has(id):
		deselect()
		return false
	# STEP-06 §24-25: routed formations lost player control — cannot be selected.
	if bool(_units[id].get("routed", false)):
		return false

	var u: Dictionary = _units[id]
	_selected_unit_id = id
	selection_changed.emit(u)
	return true

func deselect() -> void:
	if _selected_unit_id != "" and _units.has(_selected_unit_id):
		_selected_unit_id = ""
		selection_changed.emit({})
	elif _selected_unit_id != "":
		_selected_unit_id = ""
		selection_changed.emit({})

func get_selected_unit_id() -> String:
	return _selected_unit_id

func get_selected_unit() -> Dictionary:
	if _selected_unit_id != "" and _units.has(_selected_unit_id):
		return _units[_selected_unit_id].duplicate()
	return {}

func is_unit_selected() -> bool:
	return _selected_unit_id != "" and _units.has(_selected_unit_id)

# ------------------------------------------------------------------
# March Policy (Section 18)
# ------------------------------------------------------------------
func set_policy(policy: int) -> void:
	if _current_policy != policy:
		_current_policy = policy
		policy_changed.emit(_current_policy)

func get_policy() -> int:
	return _current_policy

# ------------------------------------------------------------------
# Movement Execution (Sections 7, 8, 9, 10 Canonical Model)
# Movement expenditure persists for the ENTIRE turn.
# RED is finite but does NOT automatically end action.
# BLACK (and river crossing) ends action.
# ------------------------------------------------------------------
## Scenario board authority for state mutation. The sim sets this from the
## loaded scenario; an empty dict keeps legacy unconstrained behavior.
func set_map_bounds(bounds: Dictionary) -> void:
	_map_bounds = bounds.duplicate(true) if not bounds.is_empty() else {}


## True when every post-origin hex of a move path lies inside the scenario
## rect (or no bounds are set). The origin hex is exempt: a unit standing
## outside (pre-fix drift, restore flows) may always path back inside.
func _move_path_within_bounds(path: Array[Vector2i]) -> bool:
	if _map_bounds.is_empty():
		return true
	for i in range(1, path.size()):
		var h: Vector2i = path[i]
		if h.x < int(_map_bounds.get("q_min", h.x)) or h.x > int(_map_bounds.get("q_max", h.x)) \
			or h.y < int(_map_bounds.get("r_min", h.y)) or h.y > int(_map_bounds.get("r_max", h.y)):
			return false
	return true


func execute_move(
	unit_id: String,
	path: Array[Vector2i],
	cost: float,
	march_class: int,
	crosses_river: bool
) -> Dictionary:
	if not _units.has(unit_id):
		return {"success": false, "error": "Unit not found"}

	var u: Dictionary = _units[unit_id]
	if u.get("garrisoned", false):
		return {"success": false, "error": "Garrisoned unit cannot move on field"}
	# STEP-06 §25: routed formations cannot be ordered to move.
	if bool(u.get("routed", false)):
		return {"success": false, "error": "Routed — control lost (궤주 중)"}
	if u["action_ended"]:
		return {"success": false, "error": "Unit action already ended this turn"}

	if not _move_path_within_bounds(path):
		return {"success": false, "error": "Move path leaves the scenario board."}
	var old_q: int = int(u["q"])
	var old_r: int = int(u["r"])
	var old_key: String = "%d,%d" % [old_q, old_r]

	var dest: Vector2i = path[path.size() - 1]
	var new_key: String = "%d,%d" % [dest.x, dest.y]

	# STEP-05R2: occupancy invariant: validate against player-known state.
	# Hidden enemy truth must NEVER reject planning with stale_plan (Rule 8).
	var mover_is_blue: bool = (str(u.get("faction", "")) == "blue")
	if mover_is_blue:
		var stopped_by_hidden: bool = false
		var contact_eid: String = ""
		var truncated: Array[Vector2i] = [path[0]]
		for i in range(1, path.size()):
			var h: Vector2i = path[i]
			var k: String = "%d,%d" % [h.x, h.y]
			if _occupied_map.has(k) and str(_occupied_map[k]) != unit_id:
				var occ_id: String = str(_occupied_map[k])
				var occ_u: Dictionary = _units.get(occ_id, {})
				if str(occ_u.get("faction", "")) == "red":
					stopped_by_hidden = true
					contact_eid = occ_id
					break
				else:
					# Friendly unit block: stale plan is valid
					return {"success": false, "error": "Route blocked by friendly unit", "blocked_hex": h, "stale_plan": true}
			truncated.append(h)
		if stopped_by_hidden:
			if truncated.size() < 2:
				return {
					"success": true, "moved": false, "stopped_by_contact": true,
					"contact_kind": "hidden_enemy", "contact_id": contact_eid,
					"unit_id": unit_id, "from": Vector2i(old_q, old_r), "to": Vector2i(old_q, old_r),
					"remaining_mp": float(u.get("remaining_mp", 2.0)),
					"traversed_path": truncated, "traversed_cost": 0.0
				}
			path = truncated
			dest = path[path.size() - 1]
			new_key = "%d,%d" % [dest.x, dest.y]
	else:
		var path_check: Dictionary = validate_path_occupancy(path, unit_id)
		if not bool(path_check.get("ok", false)):
			var _bh: Vector2i = path_check.get("blocked_hex", dest)
			return {"success": false, "error": str(path_check.get("reason", "Path blocked")), "blocked_hex": _bh, "stale_plan": true}

	# §8 Stronghold occupancy: footprint belongs to structure, ordinary field units
	# should not stand independently on footprint hexes
	if _stronghold_mgr and _stronghold_mgr.is_stronghold_hex(dest.x, dest.y):
		return {"success": false, "error": "Destination is inside stronghold footprint — use garrison entry"}

	# Movement while fortified is blocked until explicitly dismantled
	if (bool(u.get("field_fortified", false)) or int(u.get("field_fortification_hp", 0)) > 0 or bool(u.get("fortified", false))) and dest != Vector2i(old_q, old_r):
		return {"success": false, "error": "Fortified — must explicitly dismantle field fortification before moving (uses [ 요새화 해제 ])"}

	# Apply resource consequences (morale only - food/supply retired globally, SUP-FINAL)
	var morale_penalty: float = Step3ConfigCls.get_morale_penalty(march_class)
	u["morale"] = maxf(0.0, float(u["morale"]) - morale_penalty)
	u["fatigue"] = minf(100.0, float(u.get("fatigue", 0.0)) + _s6_fatigue_for_march(march_class))
	u["has_moved"] = true

	# Canonical persistent movement expenditure
	var base_mp: float = float(u.get("base_mp", 2.0))
	var blue_lim: float = float(u.get("blue_limit", Step3ConfigCls.get_blue_limit(base_mp)))
	var red_lim: float = float(u.get("red_limit", Step3ConfigCls.get_red_limit(base_mp)))
	var black_lim: float = float(u.get("black_limit", Step3ConfigCls.get_black_limit(base_mp)))

	var cur_spent: float = float(u.get("turn_move_cost_spent", 0.0))
	var new_spent: float = cur_spent + cost
	u["turn_move_cost_spent"] = new_spent
	u["remaining_mp"] = maxf(0.0, blue_lim - new_spent)

	# STEP-04R10 §1,§17: BLUE (GREEN) → GUARD, RED/BLACK (ORANGE/RED) → UNGUARDED
	if march_class == Step3ConfigCls.MarchClass.GREEN:
		u["defense_ready"] = true
		u["unguarded"] = false
	elif march_class == Step3ConfigCls.MarchClass.ORANGE or march_class == Step3ConfigCls.MarchClass.RED or crosses_river:
		u["unguarded"] = true
		u["defense_ready"] = false
	# Also river crossing counts as forced

	# Section 9 & 10 (revised R10): Only river/black-limit ends action automatically; forced RED/BLACK resolves via NEXT
	var end_action: bool = false
	if crosses_river or new_spent >= black_lim - 0.001:
		u["action_ended"] = true
		end_action = true
	else:
		u["action_ended"] = false
		end_action = false

	# Update grid occupancy
	_occupied_map.erase(old_key)
	u["q"] = dest.x
	u["r"] = dest.y
	_occupied_map[new_key] = unit_id

	unit_moved.emit(unit_id, Vector2i(old_q, old_r), dest, march_class)

	if end_action and _selected_unit_id == unit_id:
		deselect()

	return {
		"success": true,
		"unit_id": unit_id,
		"from": Vector2i(old_q, old_r),
		"to": dest,
		"remaining_mp": u["remaining_mp"],
		"turn_move_cost_spent": u["turn_move_cost_spent"],
		"blue_limit": blue_lim,
		"red_limit": red_lim,
		"black_limit": black_lim,
		"morale": u["morale"],
		"action_ended": u["action_ended"],
		"defense_ready": bool(u.get("defense_ready", false)),
		"unguarded": bool(u.get("unguarded", false)),
		"march_class": march_class
	}

# ------------------------------------------------------------------
# Combat System (Sections 5-27, 34-37) + Stronghold Garrison Shield (§9-12)
# ------------------------------------------------------------------
func get_attackable_targets(attacker_id: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if not _units.has(attacker_id):
		return result

	var atk_u: Dictionary = _units[attacker_id]
	if atk_u.get("garrisoned", false):
		return result
	if bool(atk_u.get("action_ended", false)):
		return result
	# STEP-06R1 §19-21: spent attackers offer no further targets (authoritative
	# execute_* still rejects; this only keeps the UI from offering a 2nd shot).
	if bool(atk_u.get("has_attacked", false)):
		return result
	# STEP-06R1 §16: logistics trains never present as attackers.
	if str(atk_u.get("class", "")) == "supply":
		return result

	var atk_q: int = int(atk_u["q"])
	var atk_r: int = int(atk_u["r"])
	var atk_coord: Vector2i = Vector2i(atk_q, atk_r)
	var atk_faction: String = str(atk_u["faction"])
	var atk_class: String = str(atk_u["class"])
	var max_range: int = CombatCalculatorCls.get_attack_range(atk_class)

	for id in _units.keys():
		if _garrisoned.has(id):
			continue
		var def_u: Dictionary = _units[id]
		if str(def_u["faction"]) == atk_faction:
			continue
		if int(def_u["soldier_count"]) <= 0:
			continue

		var def_coord: Vector2i = Vector2i(int(def_u["q"]), int(def_u["r"]))
		var dist: int = HexUtilsCls.hex_distance_axial(atk_coord, def_coord)

		if dist <= max_range and dist > 0:
			var target_info: Dictionary = def_u.duplicate()
			target_info["distance"] = dist
			target_info["is_adjacent"] = (dist == 1)
			target_info["fortification_hp"] = get_fortress_hp(def_coord.x, def_coord.y)
			result.append(target_info)

	return result

## Stronghold-aware attackable query (§12 Multiple Garrison Targets)
## Returns strongholds that are in range, with breached state determining target list
func get_attackable_strongholds(attacker_id: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if not _units.has(attacker_id):
		return result
	var atk_u: Dictionary = _units[attacker_id]
	if atk_u.get("garrisoned", false):
		return result
	if bool(atk_u.get("action_ended", false)):
		return result
	# STEP-06R1 §19-21: spent attackers offer no stronghold targets either.
	if bool(atk_u.get("has_attacked", false)):
		return result
	if str(atk_u.get("class", "")) == "supply":
		return result
	var atk_q: int = int(atk_u["q"])
	var atk_r: int = int(atk_u["r"])
	var atk_coord: Vector2i = Vector2i(atk_q, atk_r)
	var atk_faction: String = str(atk_u["faction"])
	var atk_class: String = str(atk_u["class"])
	var max_range: int = CombatCalculatorCls.get_attack_range(atk_class)
	for sh in get_all_strongholds():
		if sh.owner == atk_faction:
			continue
		# Find minimal distance from attacker to any footprint hex
		var best_dist: int = 999
		for h in sh.get_footprint():
			var d: int = HexUtilsCls.hex_distance_axial(atk_coord, h)
			if d < best_dist:
				best_dist = d
		# Melee must be adjacent (dist==1) to any footprint hex; ranged within max_range
		var in_range: bool = false
		if atk_class == "archer" or atk_class == "siege":
			in_range = (best_dist <= max_range and best_dist > 0)
		else:
			in_range = (best_dist == 1)
		if in_range:
			var entry: Dictionary = {
				"structure_id": sh.structure_id,
				"structure_type": "FORTRESS" if sh.structure_type == StrongholdCls.StrongholdType.FORTRESS else "CAPITAL",
				"owner": sh.owner,
				"footprint_hexes": sh.get_footprint(),
				"anchor_hex": sh.get_anchor(),
				"fortification_hp": sh.fortification_hp,
				"fortification_hp_max": sh.fortification_hp_max,
				"breached": sh.breached,
				"state": sh.get_state_label(),
				"garrison_count": sh.get_garrison_count(),
				"garrison_slots": sh.garrison_slots,
				"distance": best_dist,
				"is_adjacent": best_dist == 1,
				"garrison_units": sh.get_garrison_roster()
			}
			result.append(entry)
	return result

func preview_attack(attacker_id: String, defender_id: String) -> Dictionary:
	if not _units.has(attacker_id) or not _units.has(defender_id):
		return {}

	var atk_u: Dictionary = _units[attacker_id]
	var def_u: Dictionary = _units[defender_id]

	var atk_coord: Vector2i = Vector2i(int(atk_u["q"]), int(atk_u["r"]))
	var def_coord: Vector2i = Vector2i(int(def_u["q"]), int(def_u["r"]))
	var dist: int = HexUtilsCls.hex_distance_axial(atk_coord, def_coord)
	var fort_hp: int = get_fortress_hp(def_coord.x, def_coord.y)

	return CombatCalculatorCls.preview_attack(atk_u, def_u, dist, fort_hp)

func execute_attack(
	attacker_id: String,
	defender_id: String,
	strategic_modifiers: Dictionary = {},
	variance: float = 1.0
) -> Dictionary:
	if not _units.has(attacker_id) or not _units.has(defender_id):
		return {"success": false, "error": "Unit not found"}

	var atk_u: Dictionary = _units[attacker_id]
	var def_u: Dictionary = _units[defender_id]
	# Freeze factual combat provenance before either formation can be removed.
	# Consumers such as the Cloud hierarchy may observe combat_resolved after
	# destruction, when get_unit_by_id(defender_id) legitimately returns {}.
	var atk_faction := str(atk_u.get("faction", "")).to_lower()
	var def_faction := str(def_u.get("faction", "")).to_lower()
	var raw_atk_class := str(atk_u.get("class", ""))
	var raw_def_class := str(def_u.get("class", ""))

	if atk_u.get("garrisoned", false):
		return {"success": false, "error": "Garrisoned attacker cannot attack from inside"}
	if def_u.get("garrisoned", false):
		return {"success": false, "error": "Cannot directly attack garrisoned defender — attack stronghold instead"}
	# STEP-06 §25: routed formations cannot be ordered to attack (they can be attacked).
	if bool(atk_u.get("routed", false)):
		return {"success": false, "error": "Routed — control lost (궤주 중)"}
	# STEP-06R1 §16: supply trains are non-combat logistics — never ordinary attackers.
	if str(atk_u.get("class", "")) == "supply":
		return {"success": false, "error": "Supply train cannot attack (보급대)"}
	# STEP-06R1 §19-21: authoritative one-attack-per-turn lock (cavalry included).
	if bool(atk_u.get("has_attacked", false)):
		return {"success": false, "error": "Already attacked this turn (공격 완료)"}
	if bool(atk_u.get("action_ended", false)):
		return {"success": false, "error": "Attacker action already ended"}

	var atk_coord: Vector2i = Vector2i(int(atk_u["q"]), int(atk_u["r"]))
	var def_coord: Vector2i = Vector2i(int(def_u["q"]), int(def_u["r"]))
	var dist: int = HexUtilsCls.hex_distance_axial(atk_coord, def_coord)
	var max_range: int = CombatCalculatorCls.get_attack_range(str(atk_u["class"]))

	if dist > max_range or dist <= 0:
		return {"success": false, "error": "Target out of attack range"}

	var fort_hp: int = get_fortress_hp(def_coord.x, def_coord.y)

	var res: Dictionary = CombatCalculatorCls.calculate_combat(
		atk_u, def_u, dist, fort_hp, strategic_modifiers, variance
	)

	if fort_hp > 0:
		var new_fort_hp: int = int(res["remaining_fortification_hp"])
		set_fortress_hp(def_coord.x, def_coord.y, new_fort_hp)
		fortress_damaged.emit(def_coord, int(res["wall_damage"]), new_fort_hp)
		# Also emit stronghold signal if applicable
		var sh: Variant = get_stronghold_at(def_coord.x, def_coord.y)
		if sh:
			stronghold_damaged.emit(sh.structure_id, int(res["wall_damage"]), new_fort_hp, sh.breached)

	# STEP-04R7.1 §8, §9, §10: Update Defender Field Fortification
	if bool(def_u.get("field_fortified", false)) or int(def_u.get("field_fortification_hp", 0)) > 0:
		var new_field_hp: int = int(res.get("remaining_field_fortification_hp", 0))
		var field_dmg: int = int(res.get("field_fortification_damage", 0))
		def_u["field_fortification_hp"] = new_field_hp
		if new_field_hp <= 0:
			def_u["field_fortified"] = false
			def_u["fortified"] = false
			def_u["field_fortification_hp_max"] = 0
			field_fortification_destroyed.emit(defender_id)
			print("[Step3UnitManager] Unit %s field fortification DESTROYED" % defender_id)
		elif field_dmg > 0:
			field_fortification_damaged.emit(defender_id, field_dmg, new_field_hp)

	var def_cas: int = int(res["defender_casualties"])
	def_u["soldier_count"] = int(res["defender_remaining_troops"])
	def_u["morale"] = float(res["defender_final_morale"])
	unit_damaged.emit(defender_id, def_cas, int(def_u["soldier_count"]), float(res["defender_morale_delta"]))

	var defender_destroyed: bool = (int(def_u["soldier_count"]) <= 0)
	if defender_destroyed:
		destroy_unit(defender_id)

	var atk_cas: int = int(res["attacker_casualties"])
	atk_u["soldier_count"] = int(res["attacker_remaining_troops"])
	atk_u["morale"] = float(res["attacker_final_morale"])
	if atk_cas > 0 or float(res["attacker_morale_delta"]) < 0:
		unit_damaged.emit(attacker_id, atk_cas, int(atk_u["soldier_count"]), float(res["attacker_morale_delta"]))

	var attacker_destroyed: bool = (int(atk_u["soldier_count"]) <= 0)
	if attacker_destroyed:
		destroy_unit(attacker_id)

	var atk_class: String = CombatCalculatorCls.normalize_class_name(str(atk_u.get("class", "infantry")))
	atk_u["has_attacked"] = true

	if atk_class == "cavalry" and not attacker_destroyed:
		atk_u["action_ended"] = false
	else:
		atk_u["action_ended"] = true
		atk_u["remaining_mp"] = 0.0
		if _selected_unit_id == attacker_id:
			deselect()

	res["success"] = true
	res["attacker_id"] = attacker_id
	res["defender_id"] = defender_id
	res["defender_destroyed"] = defender_destroyed
	res["attacker_destroyed"] = attacker_destroyed
	res["attacker_action_ended"] = bool(atk_u.get("action_ended", true))
	res["attacker_remaining_mp"] = float(atk_u.get("remaining_mp", 0.0))
	res["turn"] = _current_turn
	res["phase"] = "BLUE" if atk_faction == "blue" else ("RED" if atk_faction == "red" else "")
	res["attacker_faction"] = atk_faction
	res["defender_faction"] = def_faction
	res["attacker_class"] = raw_atk_class
	res["defender_class"] = raw_def_class
	res["attacker_coord"] = [atk_coord.x, atk_coord.y]
	res["defender_coord"] = [def_coord.x, def_coord.y]

	combat_resolved.emit(res)
	# STEP-05 observable evidence (casualties/positions only — no hidden truth).
	log_observable_event({
		"type": "battle",
		"unit_id": attacker_id,
		"attacker_id": attacker_id,
		"defender_id": defender_id,
		"attacker_faction": atk_faction,
		"defender_faction": def_faction,
		"attacker_class": raw_atk_class,
		"defender_class": raw_def_class,
		"attacker_casualties": int(res.get("attacker_casualties", 0)),
		"defender_casualties": int(res.get("defender_casualties", 0)),
		"attacker_remaining_troops": int(res.get("attacker_remaining_troops", 0)),
		"defender_remaining_troops": int(res.get("defender_remaining_troops", 0)),
		"attacker_destroyed": attacker_destroyed,
		"defender_destroyed": defender_destroyed,
		"hex": def_coord,
		"ranged": dist > 1,
	})
	return res

# ------------------------------------------------------------------
# STEP-05 observable event helpers (§18: preserve observable evidence only).
# ------------------------------------------------------------------
func log_observable_event(evt: Dictionary) -> void:
	var e: Dictionary = evt.duplicate()
	e["turn"] = _current_turn
	_observable_events.append(e)
	while _observable_events.size() > OBSERVABLE_EVENT_CAP:
		_observable_events.pop_front()
	observable_event.emit(e)

func get_observable_events() -> Array:
	return _observable_events.duplicate()

func get_recent_events_for_unit(unit_id: String, max_count: int = 8) -> Array:
	var out: Array = []
	for i in range(_observable_events.size() - 1, -1, -1):
		var e: Dictionary = _observable_events[i]
		if str(e.get("unit_id", "")) == unit_id or str(e.get("ambusher_id", "")) == unit_id or str(e.get("victim_id", "")) == unit_id:
			out.append(e)
			if out.size() >= max_count:
				break
	return out

# ------------------------------------------------------------------
# STEP-05 AMBUSH — opening strike with NO reciprocal damage (§22-26).
# Canonical trigger: a formation steps into a hex where a previously hidden
# enemy has a legal adjacent melee attack. The hidden enemy reveals and deals
# an opening strike; the surprised victim (incl. UNGUARDED forced-march
# formations) deals zero reciprocal damage in this exchange. Normal rules
# resume afterwards. The victim's movement stops (action ends, surprised).
# ------------------------------------------------------------------
func execute_ambush_strike(ambusher_id: String, victim_id: String) -> Dictionary:
	if not _units.has(ambusher_id) or not _units.has(victim_id):
		return {"success": false, "error": "Unit not found"}
	var atk_u: Dictionary = _units[ambusher_id]
	var vic_u: Dictionary = _units[victim_id]
	if bool(atk_u.get("garrisoned", false)) or bool(vic_u.get("garrisoned", false)):
		return {"success": false, "error": "Garrisoned units cannot ambush"}
	if int(atk_u.get("soldier_count", 0)) <= 0 or int(vic_u.get("soldier_count", 0)) <= 0:
		return {"success": false, "error": "Destroyed unit cannot ambush"}
	var atk_coord := Vector2i(int(atk_u["q"]), int(atk_u["r"]))
	var vic_coord := Vector2i(int(vic_u["q"]), int(vic_u["r"]))
	var dist: int = HexUtilsCls.hex_distance_axial(atk_coord, vic_coord)
	if dist != 1:
		return {"success": false, "error": "Ambush requires adjacency"}
	if CombatCalculatorCls.get_attack_range(str(atk_u["class"])) != 1:
		return {"success": false, "error": "Only melee ambush in Step 5"}
	var fort_hp: int = get_fortress_hp(vic_coord.x, vic_coord.y)
	var res: Dictionary = CombatCalculatorCls.calculate_combat(
		atk_u, vic_u, 1, fort_hp, {}, 1.0
	)
	# Surprise asymmetry: the ambusher takes NO reciprocal casualties and its
	# own state is untouched (free opening strike from concealment).
	res["attacker_casualties"] = 0
	res["attacker_remaining_troops"] = int(atk_u["soldier_count"])
	res["attacker_final_morale"] = float(atk_u["morale"])
	res["attacker_morale_delta"] = 0.0
	res["retaliation_occurred"] = false
	res["is_ambush_opening_strike"] = true
	# Defender field fortification absorbs first (same Model B pass-through).
	if bool(vic_u.get("field_fortified", false)) or int(vic_u.get("field_fortification_hp", 0)) > 0:
		var new_field_hp: int = int(res.get("remaining_field_fortification_hp", 0))
		var field_dmg: int = int(res.get("field_fortification_damage", 0))
		vic_u["field_fortification_hp"] = new_field_hp
		if new_field_hp <= 0:
			vic_u["field_fortified"] = false
			vic_u["fortified"] = false
			vic_u["field_fortification_hp_max"] = 0
			field_fortification_destroyed.emit(victim_id)
		elif field_dmg > 0:
			field_fortification_damaged.emit(victim_id, field_dmg, new_field_hp)
	var vic_cas: int = int(res["defender_casualties"])
	vic_u["soldier_count"] = int(res["defender_remaining_troops"])
	vic_u["morale"] = float(res["defender_final_morale"])
	unit_damaged.emit(victim_id, vic_cas, int(vic_u["soldier_count"]), float(res["defender_morale_delta"]))
	var victim_destroyed: bool = (int(vic_u["soldier_count"]) <= 0)
	if victim_destroyed:
		destroy_unit(victim_id)
	else:
		# Movement stops: surprised victim ends its action for this turn.
		vic_u["action_ended"] = true
		vic_u["remaining_mp"] = 0.0
		if _selected_unit_id == victim_id:
			deselect()
	res["success"] = true
	res["ambusher_id"] = ambusher_id
	res["victim_id"] = victim_id
	res["victim_destroyed"] = victim_destroyed
	res["victim_action_ended"] = true
	combat_resolved.emit(res)
	# Observable-only evidence for the future Advisor (no hidden truth).
	log_observable_event({
		"type": "ambush",
		"ambusher_id": ambusher_id,
		"victim_id": victim_id,
		"unit_id": victim_id,
		"ambusher_class": str(atk_u.get("class", "")),
		"victim_class": str(vic_u.get("class", "")),
		"victim_casualties": vic_cas,
		"hex": vic_coord,
	})
	return res

## Execute attack against a stronghold (§9-12, §21-23)
## attacker_id: field unit id
## stronghold_id: target structure
## garrison_target_id: which garrison unit to hit (only when breached)
func execute_stronghold_assault(
	attacker_id: String,
	stronghold_id: String,
	garrison_target_id: String = "",
	strategic_modifiers: Dictionary = {},
	variance: float = 1.0
) -> Dictionary:
	if not _units.has(attacker_id):
		return {"success": false, "error": "Attacker not found"}
	var atk_u: Dictionary = _units[attacker_id]
	if atk_u.get("garrisoned", false):
		return {"success": false, "error": "Garrisoned attacker cannot attack from inside"}
	# STEP-06 §25: routed formations cannot be ordered to attack (they can be attacked).
	if bool(atk_u.get("routed", false)):
		return {"success": false, "error": "Routed — control lost (궤주 중)"}
	# STEP-06R1 §16: supply trains are non-combat logistics — never ordinary attackers.
	if str(atk_u.get("class", "")) == "supply":
		return {"success": false, "error": "Supply train cannot attack (보급대)"}
	# STEP-06R1 §19-21: authoritative one-attack-per-turn lock (cavalry included).
	if bool(atk_u.get("has_attacked", false)):
		return {"success": false, "error": "Already attacked this turn (공격 완료)"}
	if bool(atk_u.get("action_ended", false)):
		return {"success": false, "error": "Attacker action already ended"}
	var sh: Variant = get_stronghold_by_id(stronghold_id)
	if sh == null:
		return {"success": false, "error": "Stronghold not found"}
	var atk_coord: Vector2i = Vector2i(int(atk_u["q"]), int(atk_u["r"]))
	var best_dist: int = 999
	for h in sh.get_footprint():
		var d: int = HexUtilsCls.hex_distance_axial(atk_coord, h)
		if d < best_dist:
			best_dist = d
	var atk_class: String = str(atk_u.get("class", "infantry"))
	var max_range: int = CombatCalculatorCls.get_attack_range(atk_class)
	var is_siege: bool = (CombatCalculatorCls.normalize_class_name(atk_class) == "siege")
	if atk_class == "archer" or is_siege:
		if best_dist > max_range or best_dist <= 0:
			return {"success": false, "error": "Stronghold out of attack range"}
	else:
		if best_dist != 1:
			return {"success": false, "error": "Melee must be adjacent to stronghold footprint"}

	var fort_hp: int = sh.fortification_hp
	var breached_before: bool = sh.breached

	if fort_hp > 0:
		# §9 Fortification shield: all ordinary attacks damage fortification, garrison casualties = 0
		var pseudo_def: Dictionary = {"class": "infantry", "soldier_count": 500, "morale": 100.0}
		var res: Dictionary = CombatCalculatorCls.calculate_combat(atk_u, pseudo_def, best_dist, fort_hp, strategic_modifiers, variance)
		var wall_dmg: int = int(res["wall_damage"])
		var new_hp: int = int(res["remaining_fortification_hp"])
		var became_breached: bool = bool(res["is_fortress_breached"])
		sh.fortification_hp = new_hp
		sh.breached = (new_hp <= 0)
		for h in sh.get_footprint():
			_fortress_map["%d,%d" % [h.x, h.y]] = new_hp
		fortress_damaged.emit(sh.get_anchor(), wall_dmg, new_hp)
		stronghold_damaged.emit(stronghold_id, wall_dmg, new_hp, sh.breached)

		# Attacker still suffers counter/retaliation if melee
		var atk_cas: int = int(res["attacker_casualties"])
		if atk_cas > 0:
			atk_u["soldier_count"] = int(res["attacker_remaining_troops"])
			unit_damaged.emit(attacker_id, atk_cas, int(atk_u["soldier_count"]), float(res["attacker_morale_delta"]))
		atk_u["morale"] = float(res["attacker_final_morale"])

		# §12 garrison casualties = 0 while intact
		# Attacker action ends (except cavalry)
		var norm_class: String = CombatCalculatorCls.normalize_class_name(atk_class)
		atk_u["has_attacked"] = true
		if norm_class == "cavalry" and int(atk_u["soldier_count"]) > 0:
			atk_u["action_ended"] = false
		else:
			atk_u["action_ended"] = true
			atk_u["remaining_mp"] = 0.0
			if _selected_unit_id == attacker_id:
				deselect()
		return {
			"success": true,
			"attacker_id": attacker_id,
			"stronghold_id": stronghold_id,
			"distance": best_dist,
			"wall_damage": wall_dmg,
			"remaining_fortification_hp": new_hp,
			"fortification_hp_max": sh.fortification_hp_max,
			"is_fortress_breached": became_breached,
			"breached": sh.breached,
			"breached_before": breached_before,
			"garrison_casualties": 0,
			"garrison_target_hit": "",
			"attacker_casualties": atk_cas,
			"attacker_remaining_troops": int(atk_u["soldier_count"]),
			"attacker_action_ended": bool(atk_u["action_ended"])
		}
	else:
		# Breached: §12 attacker must select WHICH garrison formation to attack
		if garrison_target_id == "":
			return {"success": false, "error": "Breached — must select garrison target"}
		if not sh.has_garrison_unit(garrison_target_id):
			return {"success": false, "error": "Garrison target not found"}
		var gu: Dictionary = sh.get_garrison_unit(garrison_target_id)
		var def_troops_before: int = int(gu.get("soldier_count", 0))
		var def_morale_before: float = float(gu.get("morale", 100.0))
		# Use combat calculator with fort_hp=0 for direct troop damage
		var res2: Dictionary = CombatCalculatorCls.calculate_combat(atk_u, gu, best_dist, 0, strategic_modifiers, variance)
		var def_cas: int = int(res2["defender_casualties"])
		var def_remaining: int = int(res2["defender_remaining_troops"])
		var def_morale_after: float = float(res2["defender_final_morale"])
		# Update garrison entry in place
		for entry in sh.garrison_units:
			if str(entry.get("id", "")) == garrison_target_id:
				entry["soldier_count"] = def_remaining
				entry["morale"] = def_morale_after
				break
		# Also sync to _units if that id still exists there (garrisoned units kept in _units)
		if _units.has(garrison_target_id):
			_units[garrison_target_id]["soldier_count"] = def_remaining
			_units[garrison_target_id]["morale"] = def_morale_after

		# Remove if destroyed
		var garrison_destroyed: bool = def_remaining <= 0
		if garrison_destroyed:
			sh.deploy_garrison_unit(garrison_target_id)
			_garrisoned.erase(garrison_target_id)
			if _units.has(garrison_target_id):
				var _gcoord: Vector2i = Vector2i(int(_units[garrison_target_id].get("q", 0)), int(_units[garrison_target_id].get("r", 0)))
				_units.erase(garrison_target_id)
				# BATTLE_TERMINAL_CONTRACT_V0: garrison kills are real destructions.
				unit_destroyed.emit(garrison_target_id, _gcoord)
			# STEP-06 §5: breached + garrison wiped = captured. Owner flips to the
			# attacker faction so the position becomes a forward logistics node.
			if sh.get_garrison_count() <= 0 and sh.breached:
				sh.owner = str(atk_u.get("faction", ""))
				log_observable_event({"type": "stronghold_captured", "stronghold_id": stronghold_id, "new_owner": str(sh.owner), "attacker_id": attacker_id})

		# Attacker casualties
		var atk_cas2: int = int(res2["attacker_casualties"])
		if atk_cas2 > 0:
			atk_u["soldier_count"] = int(res2["attacker_remaining_troops"])
			unit_damaged.emit(attacker_id, atk_cas2, int(atk_u["soldier_count"]), float(res2["attacker_morale_delta"]))
		atk_u["morale"] = float(res2["attacker_final_morale"])
		garrison_target_damaged.emit(garrison_target_id, def_cas, def_remaining, stronghold_id)

		var norm_class2: String = CombatCalculatorCls.normalize_class_name(atk_class)
		atk_u["has_attacked"] = true
		if norm_class2 == "cavalry" and int(atk_u["soldier_count"]) > 0:
			atk_u["action_ended"] = false
		else:
			atk_u["action_ended"] = true
			atk_u["remaining_mp"] = 0.0
			if _selected_unit_id == attacker_id:
				deselect()

		return {
			"success": true,
			"attacker_id": attacker_id,
			"stronghold_id": stronghold_id,
			"distance": best_dist,
			"wall_damage": 0,
			"remaining_fortification_hp": 0,
			"fortification_hp_max": sh.fortification_hp_max,
			"is_fortress_breached": false,
			"breached": true,
			"breached_before": true,
			"garrison_casualties": def_cas,
			"garrison_target_hit": garrison_target_id,
			"garrison_remaining": def_remaining,
			"garrison_destroyed": garrison_destroyed,
			"garrison_troops_before": def_troops_before,
			"captured": sh.get_garrison_count() <= 0 and bool(sh.breached),
			"new_owner": str(sh.owner),
			"garrison_morale_before": def_morale_before,
			"garrison_morale_after": def_morale_after,
			"attacker_casualties": atk_cas2,
			"attacker_remaining_troops": int(atk_u["soldier_count"]),
			"attacker_action_ended": bool(atk_u["action_ended"])
		}

# ------------------------------------------------------------------
# STEP-04R9 — Canonical Turn-Resolved Logic (§2, §3, §8, §26-29)
# A unit is RESOLVED when it has no actionable resource remaining,
# or player explicitly ends via REST/FORTIFY, or its action canonically ended.
# NEXT is navigation only — it never resolves a unit.
# ------------------------------------------------------------------
func _get_max_usable_budget_for_unit(u: Dictionary) -> float:
	var base: float = float(u.get("base_mp", 2.0))
	var blue: float = float(u.get("blue_limit", Step3ConfigCls.get_blue_limit(base)))
	var red: float = float(u.get("red_limit", Step3ConfigCls.get_red_limit(base)))
	var black: float = float(u.get("black_limit", Step3ConfigCls.get_black_limit(base)))
	match _current_policy:
		Step3ConfigCls.MarchPolicy.GREEN_ONLY:
			return blue
		Step3ConfigCls.MarchPolicy.ORANGE_ALLOWED:
			return red
		Step3ConfigCls.MarchPolicy.RED_ALLOWED:
			return black
		_:
			return blue

func is_unit_turn_resolved(unit_id: String) -> bool:
	if not _units.has(unit_id):
		return true
	return is_unit_data_turn_resolved(_units[unit_id])

func is_unit_data_turn_resolved(u: Dictionary) -> bool:
	# Destroyed / zero troops
	if int(u.get("soldier_count", 0)) <= 0:
		return true
	if bool(u.get("garrisoned", false)):
		return true
	# Explicit action_ended covers: REST, FORTIFY, BLACK, river, attack-end, etc.
	if bool(u.get("action_ended", false)):
		return true
	# Fortified units hold position and do not block turn end
	if bool(u.get("field_fortified", false)) or int(u.get("field_fortification_hp", 0)) > 0 or bool(u.get("fortified", false)):
		return true
	# Rested units
	if bool(u.get("rested_this_turn", false)):
		return true
	# STEP-06: routed formations resolve automatically (flee/rally); supply
	# convoys move on the logistics cycle — neither blocks the NEXT queue.
	if bool(u.get("routed", false)):
		return true
	if bool(u.get("is_convoy", false)) or str(u.get("class", "")) == "supply":
		return true
	# Check remaining normal (Blue) MP — if exhausted (only Red forced march or 0 MP), unit is resolved for normal cycle
	var base: float = float(u.get("base_mp", 2.0))
	var blue_lim: float = float(u.get("blue_limit", Step3ConfigCls.get_blue_limit(base)))
	var spent: float = float(u.get("turn_move_cost_spent", 0.0))
	if spent + 0.001 >= blue_lim:
		return true
	return false

func is_unit_data_can_move_blue(u: Dictionary) -> bool:
	return not is_unit_data_turn_resolved(u) and str(u.get("faction", "")) == "blue"

func can_unit_move_blue(unit_id: String) -> bool:
	if not _units.has(unit_id):
		return false
	return is_unit_data_can_move_blue(_units[unit_id])

func get_units_able_to_move_in_stable_order() -> Array:
	return get_unresolved_friendly_field_units_in_stable_order()

func get_unresolved_friendly_field_units_in_stable_order() -> Array:
	var candidates: Array = []
	for id in _units.keys():
		if _garrisoned.has(id):
			continue
		var u: Dictionary = _units[id]
		if str(u.get("faction", "")) != "blue":
			continue
		if int(u.get("soldier_count", 0)) <= 0:
			continue
		if is_unit_data_turn_resolved(u):
			continue
		candidates.append(u.duplicate())
	candidates.sort_custom(func(a, b): return str(a["id"]) < str(b["id"]))
	return candidates

func get_unresolved_count() -> int:
	return get_unresolved_friendly_field_units_in_stable_order().size()

func all_friendly_field_units_resolved() -> bool:
	return get_unresolved_friendly_field_units_in_stable_order().is_empty()

# ------------------------------------------------------------------
# LEGACY REVIEWED FLOW — preserved for compatibility but NOT used for turn-end
# NEXT is navigation only and must NEVER mark a unit reviewed/resolved.
# ------------------------------------------------------------------
func get_unreviewed_field_units() -> Array:
	var candidates: Array = []
	for id in _units.keys():
		if _garrisoned.has(id):
			continue
		var u: Dictionary = _units[id]
		if str(u.get("faction", "")) != "blue":
			continue
		if int(u.get("soldier_count", 0)) <= 0:
			continue
		if bool(u.get("reviewed_this_turn", false)) or _reviewed.has(id):
			continue
		candidates.append(u.duplicate())
	candidates.sort_custom(func(a, b): return str(a["id"]) < str(b["id"]))
	return candidates

func get_unreviewed_count() -> int:
	return get_unreviewed_field_units().size()

func next_field_unit() -> Dictionary:
	var candidates: Array = get_unreviewed_field_units()
	if candidates.is_empty():
		return {}
	var nxt: Dictionary = candidates[0]
	var uid: String = str(nxt["id"])
	select_unit(uid)
	mark_reviewed(uid)
	return nxt

func mark_reviewed(unit_id: String) -> void:
	_reviewed[unit_id] = true
	if _units.has(unit_id):
		_units[unit_id]["reviewed_this_turn"] = true

func is_reviewed(unit_id: String) -> bool:
	if _units.has(unit_id):
		return bool(_units[unit_id].get("reviewed_this_turn", false)) or _reviewed.has(unit_id)
	return _reviewed.has(unit_id)

func all_field_units_reviewed() -> bool:
	return get_unreviewed_field_units().is_empty()

func reset_review_state() -> void:
	_reviewed.clear()
	for id in _units.keys():
		_units[id]["reviewed_this_turn"] = false

# ------------------------------------------------------------------
# Unit Destruction (Section 34)
# ------------------------------------------------------------------
# STEP-06R1 §9-10: logistics convoy lifecycle. Convoys are dispatched on
# demand per formation link and despawn after delivery — not permanent sprites.
# Spawn writes full field-unit state (mirrors initialize); remove is silent
# (no kill credit, no destroyed signal) so delivery turnover never reads as
# combat. Both keep the 0/1-per-hex occupancy invariant.
func spawn_supply_convoy(convoy_id: String, faction: String, q: int, r: int, cargo: float = 0.0) -> Dictionary:
	push_warning("[UnitManager] Supply convoys are retired per SUP-1: " + convoy_id)
	return {"success": false, "error": "Supply convoys are retired"}

func remove_field_unit(unit_id: String) -> bool:
	if not _units.has(unit_id):
		return false
	var u: Dictionary = _units[unit_id]
	_occupied_map.erase("%d,%d" % [int(u.get("q", 0)), int(u.get("r", 0))])
	_units.erase(unit_id)
	_garrisoned.erase(unit_id)
	_reviewed.erase(unit_id)
	if _selected_unit_id == unit_id:
		deselect()
	return true

func destroy_unit(unit_id: String) -> void:
	if not _units.has(unit_id):
		return

	var u: Dictionary = _units[unit_id]
	var coord: Vector2i = Vector2i(int(u["q"]), int(u["r"]))
	var key: String = "%d,%d" % [coord.x, coord.y]

	_occupied_map.erase(key)
	_units.erase(unit_id)
	_garrisoned.erase(unit_id)
	_reviewed.erase(unit_id)

	if _selected_unit_id == unit_id:
		deselect()

	unit_destroyed.emit(unit_id, coord)
	print("[Step3UnitManager] Unit %s destroyed and removed from all registries at %s" % [unit_id, str(coord)])

# ------------------------------------------------------------------
# Turn State & End Turn (Sections 28, 29) — preserves RED infinite movement fix
# ------------------------------------------------------------------
func get_current_turn() -> int:
	return _current_turn

func end_turn() -> int:
	_current_turn += 1
	for id in _units.keys():
		var u: Dictionary = _units[id]
		var base: float = float(u["base_mp"])
		u["blue_limit"] = Step3ConfigCls.get_blue_limit(base)
		u["red_limit"] = Step3ConfigCls.get_red_limit(base)
		u["black_limit"] = Step3ConfigCls.get_black_limit(base)
		u["turn_move_cost_spent"] = 0.0
		u["remaining_mp"] = base
		u["action_ended"] = false
		u["turn_resolved"] = false
		u["has_moved"] = false
		u["has_attacked"] = false
		u["rested_this_turn"] = false
		u["resting_unguarded"] = false
		u["reviewed_this_turn"] = false
		# STEP-04R10 §10: Field fortification persists indefinitely while not destroyed/dismantled
		# Do NOT clear field_fortified / field_fortification_hp here.
		# Reset guard/unguarded for non-fortified; keep fortified as GUARD
		if bool(u.get("field_fortified", false)) or int(u.get("field_fortification_hp", 0)) > 0:
			u["defense_ready"] = true
			u["unguarded"] = false
		else:
			u["defense_ready"] = false
			u["unguarded"] = false

	_reviewed.clear()

	turn_advanced.emit(_current_turn)
	if _selected_unit_id != "" and _units.has(_selected_unit_id):
		selection_changed.emit(_units[_selected_unit_id])

	print("[Step3UnitManager] Turn advanced to %d — all unit MPs refreshed, rested cleared, fortifications preserved" % _current_turn)
	return _current_turn

# ------------------------------------------------------------------
# STEP-04R7.1: Unit REST & Temporary Field FORTIFY API (§2, §3, §5, §6, §12)
# ------------------------------------------------------------------
func can_unit_rest(unit_id: String) -> bool:
	if not _units.has(unit_id):
		return false
	var u: Dictionary = _units[unit_id]
	if bool(u.get("garrisoned", false)):
		return false
	# STEP-06: routed formations and auto-run convoys cannot REST/FORTIFY.
	if bool(u.get("routed", false)) or bool(u.get("is_convoy", false)):
		return false
	# 2026-10-06 (user): REST / FORTIFY follow the same rules for both sides (was BLUE-only).
	if bool(u.get("action_ended", false)):
		return false
	if bool(u.get("has_attacked", false)):
		return false
	if bool(u.get("has_moved", false)):
		return false
	if float(u.get("turn_move_cost_spent", 0.0)) > 0.001:
		return false
	return true

func is_unit_untouched(unit_id: String) -> bool:
	if not _units.has(unit_id):
		return false
	var u: Dictionary = _units[unit_id]
	return float(u.get("turn_move_cost_spent", 0.0)) <= 0.001 and not bool(u.get("has_moved", false)) and not bool(u.get("has_attacked", false)) and not bool(u.get("action_ended", false)) and not bool(u.get("garrisoned", false))

func is_unit_data_untouched(u: Dictionary) -> bool:
	return float(u.get("turn_move_cost_spent", 0.0)) <= 0.001 and not bool(u.get("has_moved", false)) and not bool(u.get("has_attacked", false)) and not bool(u.get("action_ended", false)) and not bool(u.get("garrisoned", false))

func can_unit_fortify(unit_id: String) -> bool:
	# 2026-10-06 (user): field fortification removed from the game: every mode, every unit, both sides.
	if FIELD_FORTIFY_DISABLED:
		return false
	if not _units.has(unit_id):
		return false
	var u: Dictionary = _units[unit_id]
	if bool(u.get("garrisoned", false)):
		return false
	# STEP-06: routed formations and auto-run convoys cannot REST/FORTIFY.
	if bool(u.get("routed", false)) or bool(u.get("is_convoy", false)):
		return false
	# 2026-10-06 (user): REST / FORTIFY follow the same rules for both sides (was BLUE-only).
	var spent: float = float(u.get("turn_move_cost_spent", 0.0))
	var has_moved: bool = bool(u.get("has_moved", false))
	var has_attacked: bool = bool(u.get("has_attacked", false))
	var ended: bool = bool(u.get("action_ended", false))
	if bool(u.get("field_fortified", false)) or int(u.get("field_fortification_hp", 0)) > 0:
		return false
	# 2026-10-18 (user, balance): a unit can field-fortify only once per game; destroyed or left fieldworks never come back.
	if bool(u.get("field_fortify_used", false)):
		return false
	return (spent <= 0.001 and not has_moved and not has_attacked and not ended)

func rest_unit(unit_id: String) -> Dictionary:
	if not _units.has(unit_id):
		return {"success": false, "error": "Unit not found"}
	var u: Dictionary = _units[unit_id]
	if bool(u.get("garrisoned", false)):
		return {"success": false, "error": "Garrison units cannot use field rest"}
	if not can_unit_rest(unit_id):
		return {"success": false, "error": "Unit not eligible to rest (must be untouched, no MP spent, no attack, not garrisoned)"}

	u["action_ended"] = true
	u["turn_resolved"] = true
	u["rested_this_turn"] = true
	u["resting_unguarded"] = false
	u["defense_ready"] = false
	u["unguarded"] = false
	u["reviewed_this_turn"] = true
	u["remaining_mp"] = 0.0
	# STEP-06 §21: REST restores morale + fatigue/readiness, never troops.
	u["morale"] = minf(100.0, float(u.get("morale", 100.0)) + Step6ConfigCls.REST_MORALE_RESTORE)
	u["fatigue"] = 0.0
	_reviewed[unit_id] = true

	print("[Step3UnitManager] Unit %s RESTED (ZZZ, action_ended=true, turn_resolved=true, troops=%d, morale=%.1f)" % [
		unit_id, int(u.get("soldier_count", 0)), float(u.get("morale", 100.0))
	])

	if _selected_unit_id == unit_id:
		selection_changed.emit(_units[unit_id].duplicate())

	return {
		"success": true,
		"unit_id": unit_id,
		"action_ended": true,
		"turn_resolved": true,
		"rested_this_turn": true,
		"resting_unguarded": false,
		"defense_ready": false,
		"unguarded": false,
		"fortified": bool(u.get("fortified", false)),
		"field_fortified": bool(u.get("field_fortified", false)),
		"field_fortification_hp": int(u.get("field_fortification_hp", 0)),
		"soldier_count": int(u.get("soldier_count", 0)),
		"morale": float(u.get("morale", 100.0))
	}

func fortify_unit(unit_id: String) -> Dictionary:
	if not _units.has(unit_id):
		return {"success": false, "error": "Unit not found"}
	var u: Dictionary = _units[unit_id]
	if bool(u.get("garrisoned", false)):
		return {"success": false, "error": "Garrison units cannot use field fortify"}
	if not can_unit_fortify(unit_id):
		return {
			"success": false,
			"error": "Unit not eligible to fortify (turn_move_cost_spent > 0, has_moved, attacked, or action_ended)"
		}

	var fort_hp: int = CombatCalculatorCls.FIELD_FORTIFICATION_DEFAULT_HP
	u["field_fortified"] = true
	u["fortified"] = true
	u["field_fortify_used"] = true
	u["field_fortification_hp"] = fort_hp
	u["field_fortification_hp_max"] = fort_hp
	u["resting_unguarded"] = false
	u["defense_ready"] = true
	u["unguarded"] = false
	u["action_ended"] = true
	u["turn_resolved"] = true
	u["reviewed_this_turn"] = true
	u["remaining_mp"] = 0.0
	_reviewed[unit_id] = true

	field_fortification_created.emit(unit_id, fort_hp)
	print("[Step3UnitManager] Unit %s FIELD FORTIFIED (field_fortification_hp=%d, action_ended=true, turn_resolved=true, defense_ready=true)" % [unit_id, fort_hp])

	if _selected_unit_id == unit_id:
		selection_changed.emit(_units[unit_id].duplicate())

	return {
		"success": true,
		"unit_id": unit_id,
		"fortified": true,
		"field_fortified": true,
		"field_fortification_hp": fort_hp,
		"field_fortification_hp_max": fort_hp,
		"action_ended": true,
		"turn_resolved": true,
		"defense_ready": true,
		"unguarded": false,
		"soldier_count": int(u.get("soldier_count", 0)),
		"morale": float(u.get("morale", 100.0))
	}

# STEP-04R10/R11 Explicit Dismantle / Leave Fortification
func can_dismantle_fortification(unit_id: String) -> bool:
	if not _units.has(unit_id):
		return false
	var u: Dictionary = _units[unit_id]
	if bool(u.get("garrisoned", false)):
		return false
	if not (bool(u.get("field_fortified", false)) or int(u.get("field_fortification_hp", 0)) > 0 or bool(u.get("fortified", false))):
		return false
	if bool(u.get("action_ended", false)):
		return false
	var base: float = float(u.get("base_mp", 2.0))
	var blue_lim: float = float(u.get("blue_limit", Step3ConfigCls.get_blue_limit(base)))
	var spent: float = float(u.get("turn_move_cost_spent", 0.0))
	# Need 1.0 MP available from remaining blue budget
	if spent + FIELD_FORTIFICATION_DISMANTLE_MP_COST > blue_lim + 0.001:
		return false
	return true

func dismantle_fortification(unit_id: String) -> Dictionary:
	if not _units.has(unit_id):
		return {"success": false, "error": "Unit not found"}
	var u: Dictionary = _units[unit_id]
	if not can_dismantle_fortification(unit_id):
		return {"success": false, "error": "Cannot dismantle: need field fortification, not action_ended, and at least %.1f MP remaining" % FIELD_FORTIFICATION_DISMANTLE_MP_COST}
	var base: float = float(u.get("base_mp", 2.0))
	var blue_lim: float = float(u.get("blue_limit", Step3ConfigCls.get_blue_limit(base)))
	# Pay cost (1.0 MP)
	u["turn_move_cost_spent"] = float(u.get("turn_move_cost_spent", 0.0)) + FIELD_FORTIFICATION_DISMANTLE_MP_COST
	u["remaining_mp"] = maxf(0.0, blue_lim - float(u["turn_move_cost_spent"]))
	u["field_fortified"] = false
	u["fortified"] = false
	u["field_fortification_hp"] = 0
	u["field_fortification_hp_max"] = 0
	u["defense_ready"] = false
	u["unguarded"] = false
	u["action_ended"] = false
	field_fortification_abandoned.emit(unit_id)
	print("[Step3UnitManager] Unit %s dismantled field fortification (cost 1.0 MP, spent now %.1f, remaining %.1f MP)" % [unit_id, float(u["turn_move_cost_spent"]), float(u["remaining_mp"])])
	if _selected_unit_id == unit_id:
		selection_changed.emit(_units[unit_id].duplicate())
	return {"success": true, "unit_id": unit_id, "spent": float(u["turn_move_cost_spent"]), "remaining_mp": float(u["remaining_mp"]), "cost": FIELD_FORTIFICATION_DISMANTLE_MP_COST}

# STEP-04R11 NEXT Resolution Policy
# "MP 가 남아있으면, 이동할수 있으면, 그 턴 스킵이 아니라 다시 돌아와야해. 다시 선택이 불가능한건 강행군 만"
func resolve_unit_via_next(unit_id: String) -> Dictionary:
	if not _units.has(unit_id):
		return {"success": false, "error": "Unit not found"}
	var u: Dictionary = _units[unit_id]
	if bool(u.get("garrisoned", false)):
		return {"success": false, "error": "Garrisoned"}
	if bool(u.get("action_ended", false)):
		return {"success": false, "error": "Already action_ended"}
	var base: float = float(u.get("base_mp", 2.0))
	var blue_lim: float = float(u.get("blue_limit", Step3ConfigCls.get_blue_limit(base)))
	var spent: float = float(u.get("turn_move_cost_spent", 0.0))
	var has_moved: bool = bool(u.get("has_moved", false))
	var unguarded_flag: bool = bool(u.get("unguarded", false))
	
	# Forced march → UNGUARDED
	if unguarded_flag:
		u["action_ended"] = true
		u["turn_resolved"] = true
		u["reviewed_this_turn"] = true
		u["remaining_mp"] = 0.0
		_reviewed[unit_id] = true
		print("[Step3UnitManager] Unit %s resolved via NEXT as UNGUARDED (forced march, spent %.1f)" % [unit_id, spent])
		if _selected_unit_id == unit_id:
			selection_changed.emit(_units[unit_id].duplicate())
		return {"success": true, "resolved": true, "stance": "unguarded", "unguarded": true, "defense_ready": false}
	
	# If blue MP is exhausted, mark GUARD / resolved
	if spent + 0.001 >= blue_lim and (has_moved or spent > 0.001):
		u["defense_ready"] = true
		u["unguarded"] = false
		u["action_ended"] = true
		u["turn_resolved"] = true
		u["reviewed_this_turn"] = true
		u["remaining_mp"] = 0.0
		_reviewed[unit_id] = true
		print("[Step3UnitManager] Unit %s resolved via NEXT as GUARD (Blue MP exhausted, spent %.1f)" % [unit_id, spent])
		if _selected_unit_id == unit_id:
			selection_changed.emit(_units[unit_id].duplicate())
		return {"success": true, "resolved": true, "stance": "guard", "defense_ready": true, "unguarded": false}
	
	# Blue MP still remains -> Do NOT end action! Unit can move again and comes back in cycle!
	return {"success": false, "resolved": false, "reason": "blue MP remains — unit can move again", "stance": "active"}

func wait_unit(unit_id: String) -> Dictionary:
	if not _units.has(unit_id):
		return {"success": false, "error": "Unit not found"}
	var u: Dictionary = _units[unit_id]
	if bool(u.get("garrisoned", false)):
		return {"success": false, "error": "Garrison units cannot wait"}
	u["action_ended"] = true
	u["turn_resolved"] = true
	u["defense_ready"] = true
	u["unguarded"] = false
	u["remaining_mp"] = 0.0
	_reviewed[unit_id] = true
	print("[Step3UnitManager] Unit %s WAITED (대기, action_ended=true, defense_ready=true)" % unit_id)
	if _selected_unit_id == unit_id:
		selection_changed.emit(_units[unit_id].duplicate())
	return {"success": true, "unit_id": unit_id}

func try_resolve_current_via_next() -> Dictionary:
	if _selected_unit_id == "" or not _units.has(_selected_unit_id):
		return {"success": false, "error": "No selected unit"}
	return resolve_unit_via_next(_selected_unit_id)

func abandon_field_fortification(unit_id: String) -> void:
	if not _units.has(unit_id):
		return
	var u: Dictionary = _units[unit_id]
	if bool(u.get("field_fortified", false)) or int(u.get("field_fortification_hp", 0)) > 0 or bool(u.get("fortified", false)):
		u["field_fortified"] = false
		u["fortified"] = false
		u["field_fortification_hp"] = 0
		u["field_fortification_hp_max"] = 0
		field_fortification_abandoned.emit(unit_id)
		print("[Step3UnitManager] Unit %s field fortification ABANDONED upon moving away" % unit_id)

func is_unit_field_fortified(unit_id: String) -> bool:
	if not _units.has(unit_id):
		return false
	var u: Dictionary = _units[unit_id]
	return bool(u.get("field_fortified", false)) or int(u.get("field_fortification_hp", 0)) > 0

func get_unit_field_fortification_hp(unit_id: String) -> int:
	if not _units.has(unit_id):
		return 0
	return int(_units[unit_id].get("field_fortification_hp", 0))

func is_unit_resting_unguarded(unit_id: String) -> bool:
	if not _units.has(unit_id):
		return false
	return bool(_units[unit_id].get("resting_unguarded", false))



# ------------------------------------------------------------------
# Query & Adjacency Helpers (Sections 15, 17, 38, 45)
# ------------------------------------------------------------------
func can_melee_attack_from(attacker_coord: Vector2i, target_coord: Vector2i, attacker_action_ended: bool) -> bool:
	if attacker_action_ended:
		return false
	return HexUtilsCls.hex_distance_axial(attacker_coord, target_coord) == 1

func is_adjacent(coord_a: Vector2i, coord_b: Vector2i) -> bool:
	return HexUtilsCls.hex_distance_axial(coord_a, coord_b) == 1

func can_act_after_movement(unit_id: String) -> bool:
	if not _units.has(unit_id):
		return false
	var u: Dictionary = _units[unit_id]
	if u.get("garrisoned", false):
		return false
	return not bool(u["action_ended"])

func get_unit_at(q: int, r: int) -> Dictionary:
	var key: String = "%d,%d" % [q, r]
	if _occupied_map.has(key):
		var id: String = _occupied_map[key]
		if _units.has(id):
			return _units[id].duplicate()
	return {}

# STEP-05R1: cross-faction occupancy authority (0 or 1 field formation per hex).
func is_hex_occupied(q: int, r: int, ignore_id: String = "") -> bool:
	var key: String = "%d,%d" % [q, r]
	if not _occupied_map.has(key):
		return false
	if ignore_id != "" and str(_occupied_map[key]) == ignore_id:
		return false
	return true

# STEP-05R2: full-path occupancy check against PLAYER-KNOWN occupancy.
# Hidden enemy truth must NEVER reject planning or pre-move checks (no blocked_hex/stale_plan leak).
# visible_enemy_ids: optional set of red enemy ids currently visible to the player.
func validate_path_occupancy(path: Array[Vector2i], mover_id: String, visible_enemy_ids: Dictionary = {}) -> Dictionary:
	if path.size() < 2:
		return {"ok": false, "reason": "Empty path", "blocked_hex": Vector2i(-999, -999)}
	var mover_is_blue: bool = false
	if _units.has(mover_id):
		mover_is_blue = (str(_units[mover_id].get("faction", "")) == "blue")
	for i in range(1, path.size()):
		var h: Vector2i = path[i]
		var key: String = "%d,%d" % [h.x, h.y]
		if _occupied_map.has(key) and str(_occupied_map[key]) != mover_id:
			var occ_id: String = str(_occupied_map[key])
			var occ_u: Dictionary = _units.get(occ_id, {})
			var occ_fac: String = str(occ_u.get("faction", ""))
			# STEP-05R2 §1/§8: Hidden enemy occupancy must NOT leak to blue mover planning
			if mover_is_blue and occ_fac == "red":
				if not visible_enemy_ids.has(occ_id):
					continue # unseen enemy truth — do not block planning
			if i == path.size() - 1:
				return {"ok": false, "reason": "Destination is occupied", "blocked_hex": h}
			return {"ok": false, "reason": "Route blocked by contact at (%d,%d) — no stacking" % [h.x, h.y], "blocked_hex": h}
	return {"ok": true}

# STEP-05R1: deterministic relocation for duplicate deployment (BFS rings).
func _find_nearest_free_hex(origin: Vector2i) -> Vector2i:
	if not _occupied_map.has("%d,%d" % [origin.x, origin.y]):
		return origin
	var frontier: Array[Vector2i] = [origin]
	var seen: Dictionary = {"%d,%d" % [origin.x, origin.y]: true}
	for _ring in range(6):
		var nxt: Array[Vector2i] = []
		for c in frontier:
			for n in HexUtilsCls.get_all_neighbors(c.x, c.y):
				var nk: String = "%d,%d" % [n.x, n.y]
				if seen.has(nk):
					continue
				seen[nk] = true
				if _stronghold_mgr and _stronghold_mgr.is_stronghold_hex(n.x, n.y):
					continue
				if not _occupied_map.has(nk):
					return n
				nxt.append(n)
		frontier = nxt
		if frontier.is_empty():
			break
	return Vector2i(-999, -999)

func get_unit_by_id(id: String) -> Dictionary:
	if _units.has(id):
		return _units[id].duplicate()
	return {}

func get_all_units() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for id in _units.keys():
		if _garrisoned.has(id):
			continue
		result.append(_units[id].duplicate())
	return result

func get_all_units_including_garrisoned() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for id in _units.keys():
		result.append(_units[id].duplicate())
	return result

func get_occupied_dict() -> Dictionary:
	var res: Dictionary = {}
	for k in _occupied_map.keys():
		var id: String = _occupied_map[k]
		if _units.has(id):
			res[k] = _units[id]
	return res

# STEP-05R2 §1-§3/§9: planning knowledge vs authoritative truth.
# Player path planning must behave as though hidden enemy occupancy is unknown.
# Enemy AI keeps using get_occupied_dict() (full truth). Player uses this.
func get_player_known_occupied(visible_enemy_ids: Dictionary) -> Dictionary:
	var res: Dictionary = {}
	for k in _occupied_map.keys():
		var id: String = str(_occupied_map[k])
		if not _units.has(id):
			continue
		var u: Dictionary = _units[id]
		var fac: String = str(u.get("faction", ""))
		if fac == "blue":
			res[k] = u
		elif fac == "red":
			if visible_enemy_ids.has(id):
				res[k] = u
			# else: hidden enemy => unknown space, omit from planning
		else:
			res[k] = u
	return res

# STEP-05R2 §4-§8: authoritative stepwise contact resolution.
# Never validate the whole planned route against hidden truth upfront.
# Walk one hex at a time; STOP before stacking on first occupied hex.
# Charges MP ONLY for hexes actually traversed. Returns partial-move success
# with contact info so the shell can reveal/cancel remaining path.
# visible_enemy_ids: set of red ids CURRENTLY visible (player-known blockers).
# cell_data/river_cells: for per-step terrain cost (mirrors pathfinding).
func execute_player_stepwise_move(
	unit_id: String,
	path: Array[Vector2i],
	visible_enemy_ids: Dictionary,
	cell_data: Dictionary,
	river_cells: Dictionary
) -> Dictionary:
	if not _units.has(unit_id):
		return {"success": false, "error": "Unit not found"}
	var u: Dictionary = _units[unit_id]
	if u.get("garrisoned", false):
		return {"success": false, "error": "Garrisoned unit cannot move on field"}
	# STEP-06 §25: routed formations cannot be ordered to move.
	if bool(u.get("routed", false)):
		return {"success": false, "error": "Routed — control lost (궤주 중)"}
	if bool(u.get("action_ended", false)):
		return {"success": false, "error": "Unit action already ended this turn"}
	if path.size() < 2:
		return {"success": false, "error": "Empty path"}
	if not _move_path_within_bounds(path):
		return {"success": false, "error": "Move path leaves the scenario board."}
	var old_q: int = int(u.get("q", 0))
	var old_r: int = int(u.get("r", 0))
	# Fortified lock (same rule as execute_move).
	var dest_probe: Vector2i = path[path.size() - 1]
	if (bool(u.get("field_fortified", false)) or int(u.get("field_fortification_hp", 0)) > 0 or bool(u.get("fortified", false))) and dest_probe != Vector2i(old_q, old_r):
		return {"success": false, "error": "Fortified — must explicitly dismantle field fortification before moving (uses [ 요새화 해제 ])"}
	var uclass: String = str(u.get("class", "infantry"))
	var traversed: Array[Vector2i] = [path[0]]
	var traversed_cost: float = 0.0
	var crossed: bool = false
	var contact_kind: String = ""
	var contact_id: String = ""
	var contact_hex: Vector2i = Vector2i(-999, -999)
	for i in range(1, path.size()):
		var h: Vector2i = path[i]
		var prev: Vector2i = path[i - 1]
		if _stronghold_mgr and _stronghold_mgr.is_stronghold_hex(h.x, h.y):
			contact_kind = "stronghold"
			contact_hex = h
			break
		var key: String = "%d,%d" % [h.x, h.y]
		if _occupied_map.has(key) and str(_occupied_map[key]) != unit_id:
			var occ_id: String = str(_occupied_map[key])
			var occ_u: Dictionary = _units.get(occ_id, {})
			var occ_fac: String = str(occ_u.get("faction", ""))
			if occ_fac == "blue":
				contact_kind = "friendly"
			elif occ_fac == "red":
				if visible_enemy_ids.has(occ_id):
					contact_kind = "visible_enemy"
				else:
					contact_kind = "hidden_enemy"
			else:
				contact_kind = "unknown"
			contact_id = occ_id
			contact_hex = h
			break
		# Per-step terrain cost (mirrors Step3Pathfinding).
		var cell: Variant = cell_data.get(key, null)
		var terrain: int = 0
		if cell != null:
			if cell is Dictionary:
				terrain = int((cell as Dictionary).get("terrain", 0))
			else:
				var tv: Variant = cell.get("terrain")
				if tv != null:
					terrain = int(tv)
		var step_cost: float = Step3ConfigCls.get_terrain_cost(terrain, uclass)
		var prev_key: String = "%d,%d" % [prev.x, prev.y]
		if bool(river_cells.has(prev_key)) or bool(river_cells.has(key)) or terrain == 7:
			crossed = true
		traversed_cost += step_cost
		traversed.append(h)
	var stopped: bool = contact_kind != ""
	var moved: bool = traversed.size() >= 2
	if not moved:
		# Discovered contact on the very next hex: no MP charged, no teleport.
		return {
			"success": true, "moved": false, "stopped_by_contact": stopped,
			"contact_kind": contact_kind, "contact_id": contact_id, "contact_hex": contact_hex,
			"traversed_path": traversed, "traversed_cost": 0.0,
			"march_class": Step3ConfigCls.MarchClass.GREEN, "crosses_river": false,
			"from": Vector2i(old_q, old_r), "to": Vector2i(old_q, old_r),
		}
	# Apply resource consequences for ACTUAL traversed cost only (§7).
	var base_mp: float = float(u.get("base_mp", 2.0))
	var blue_lim: float = float(u.get("blue_limit", Step3ConfigCls.get_blue_limit(base_mp)))
	var red_lim: float = float(u.get("red_limit", Step3ConfigCls.get_red_limit(base_mp)))
	var black_lim: float = float(u.get("black_limit", Step3ConfigCls.get_black_limit(base_mp)))
	var cur_spent: float = float(u.get("turn_move_cost_spent", 0.0))
	var march_class: int = Step3ConfigCls.classify_march_by_cumulative_cost(cur_spent + traversed_cost, blue_lim, red_lim, crossed)
	# Morale only - food/supply retired globally (SUP-FINAL)
	var morale_penalty: float = Step3ConfigCls.get_morale_penalty(march_class)
	u["morale"] = maxf(0.0, float(u.get("morale", 100.0)) - morale_penalty)
	u["fatigue"] = minf(100.0, float(u.get("fatigue", 0.0)) + _s6_fatigue_for_march(march_class))
	u["has_moved"] = true
	if march_class == Step3ConfigCls.MarchClass.GREEN and not crossed:
		u["defense_ready"] = true
		u["unguarded"] = false
	else:
		u["unguarded"] = true
		u["defense_ready"] = false
	var new_spent: float = cur_spent + traversed_cost
	u["turn_move_cost_spent"] = new_spent
	u["remaining_mp"] = maxf(0.0, blue_lim - new_spent)
	var end_action: bool = false
	if crossed or new_spent >= black_lim - 0.001:
		u["action_ended"] = true
		end_action = true
	else:
		u["action_ended"] = false
		end_action = false
	var old_key: String = "%d,%d" % [old_q, old_r]
	var final_hex: Vector2i = traversed[traversed.size() - 1]
	var new_key: String = "%d,%d" % [final_hex.x, final_hex.y]
	_occupied_map.erase(old_key)
	u["q"] = final_hex.x
	u["r"] = final_hex.y
	_occupied_map[new_key] = unit_id
	unit_moved.emit(unit_id, Vector2i(old_q, old_r), final_hex, march_class)
	if end_action and _selected_unit_id == unit_id:
		deselect()
	return {
		"success": true, "moved": true, "stopped_by_contact": stopped,
		"contact_kind": contact_kind, "contact_id": contact_id, "contact_hex": contact_hex,
		"traversed_path": traversed, "traversed_cost": traversed_cost,
		"march_class": march_class, "crosses_river": crossed,
		"from": Vector2i(old_q, old_r), "to": final_hex,
		"remaining_mp": u["remaining_mp"],
		"turn_move_cost_spent": u["turn_move_cost_spent"],
		"blue_limit": blue_lim, "red_limit": red_lim, "black_limit": black_lim,
		"morale": u["morale"], "action_ended": u["action_ended"],
		"defense_ready": bool(u.get("defense_ready", false)),
		"unguarded": bool(u.get("unguarded", false)),
	}

# Compatibility: expose fortress_map for legacy callers
func get_fortress_map() -> Dictionary:
	return _fortress_map.duplicate()

# Stronghold dump for evidence
func dump_strongholds() -> Dictionary:
	if _stronghold_mgr and _stronghold_mgr.has_method("dump_all"):
		return _stronghold_mgr.dump_all()
	return {"stronghold_count": 0, "strongholds": []}

# ------------------------------------------------------------------
# STEP-06 Battle Decision Layer API (§2-§45)
# The decision layer mutates unit state ONLY through these methods
# (get_unit_by_id/get_all_units return duplicates and must not be written).
# ------------------------------------------------------------------
const S6_WRITABLE_FIELDS: Array = [
	"local_supply", "supply_state", "fatigue", "routed", "rout_turns",
	"consecutive_hungry", "action_ended", "turn_resolved", "reviewed_this_turn",
	"retreat_mark", "remaining_mp", "morale",
]

func _s6_fatigue_for_march(march_class: int) -> float:
	if march_class == Step3ConfigCls.MarchClass.ORANGE:
		return Step6ConfigCls.FATIGUE_ORANGE
	if march_class == Step3ConfigCls.MarchClass.RED:
		return Step6ConfigCls.FATIGUE_RED
	return Step6ConfigCls.FATIGUE_GREEN

func s6_set_field(unit_id: String, field: String, value: Variant) -> bool:
	if not _units.has(unit_id):
		return false
	if not S6_WRITABLE_FIELDS.has(field):
		return false
	_units[unit_id][field] = value
	if field == "routed" and not bool(value):
		_units[unit_id]["rout_turns"] = 0
	if _selected_unit_id == unit_id:
		selection_changed.emit(_units[unit_id].duplicate())
	return true

func s6_add_morale(unit_id: String, delta: float) -> float:
	if not _units.has(unit_id):
		return 0.0
	_units[unit_id]["morale"] = clampf(float(_units[unit_id].get("morale", 100.0)) + delta, 0.0, 100.0)
	return float(_units[unit_id]["morale"])

func s6_set_routed(unit_id: String, routed: bool) -> void:
	if not _units.has(unit_id):
		return
	_units[unit_id]["routed"] = routed
	_units[unit_id]["rout_turns"] = 0
	if _selected_unit_id == unit_id and routed:
		deselect()
	else:
		selection_changed.emit(_units[unit_id].duplicate())

func s6_adjust_supply(unit_id: String, delta: float) -> Dictionary:
	if not _units.has(unit_id):
		return {"supply": 0.0, "shortage": true}
	var mx: float = float(_units[unit_id].get("local_supply_max", 1.0))
	_units[unit_id]["local_supply"] = clampf(float(_units[unit_id].get("local_supply", 0.0)) + delta, 0.0, mx)
	var cur: float = float(_units[unit_id]["local_supply"])
	return {"supply": cur, "shortage": cur <= 0.001}

func s6_add_fatigue(unit_id: String, delta: float) -> float:
	if not _units.has(unit_id):
		return 0.0
	_units[unit_id]["fatigue"] = clampf(float(_units[unit_id].get("fatigue", 0.0)) + delta, 0.0, 100.0)
	return float(_units[unit_id]["fatigue"])
