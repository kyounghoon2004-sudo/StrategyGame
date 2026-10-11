class_name StrongholdManager
extends RefCounted

## STRONGHOLD MANAGER — Central registry for all multi-hex structures
## Handles stronghold lifecycle, garrison commands, assault targeting,
## deployment, and perimeter queries.
##
## Contract: STEP-04R2-MULTIHEX-STRONGHOLD-GARRISON
## §6 Garrison Entry · §7 Garrison Exit/Deploy · §8 Stronghold Occupancy
## §12 Multiple Garrison Targets · §23 Perimeter Queries · §24, §25
## · §30-34 Machine Tests

const StrongholdCls = preload("res://scripts/core/stronghold.gd")
const HexUtilsCls = preload("res://scripts/core/hex_utils.gd")

var _strongholds: Array[Stronghold] = []
var _by_id: Dictionary = {}       # structure_id -> Stronghold
var _by_hex: Dictionary = {}      # "q,r" -> Stronghold

# ------------------------------------------------------------------
# REGISTRY
# ------------------------------------------------------------------

func get_all_strongholds() -> Array:
	return _strongholds.duplicate()

func get_stronghold_by_id(id: String) -> Stronghold:
	return _by_id.get(id, null)

func get_stronghold_at(q: int, r: int) -> Stronghold:
	return _by_hex.get("%d,%d" % [q, r], null)

func get_stronghold_at_coord(coord: Vector2i) -> Stronghold:
	return _by_hex.get("%d,%d" % [coord.x, coord.y], null)

func is_stronghold_hex(q: int, r: int) -> bool:
	return _by_hex.has("%d,%d" % [q, r])

func is_stronghold_coord(coord: Vector2i) -> bool:
	return _by_hex.has("%d,%d" % [coord.x, coord.y])

func get_stronghold_perimeter_hexes(id: String) -> Array[Vector2i]:
	var sh := get_stronghold_by_id(id)
	if sh:
		return sh.get_footprint()
	return []

func get_valid_assault_positions(id: String) -> Array[Vector2i]:
	var sh := get_stronghold_by_id(id)
	if not sh:
		return []
	var result: Array[Vector2i] = []
	var fp := sh.get_footprint()
	for h in fp:
		var neighbors: Array[Vector2i] = HexUtilsCls.get_all_neighbors(h.x, h.y)
		for n in neighbors:
			if not _by_hex.has("%d,%d" % [n.x, n.y]):
				result.append(n)
	return result

func get_valid_deployment_hexes(id: String, garrison_unit_id: String) -> Array[Vector2i]:
	var sh := get_stronghold_by_id(id)
	if not sh:
		return []
	var result: Array[Vector2i] = []
	if not sh.has_garrison_unit(garrison_unit_id):
		return result
	var fp := sh.get_footprint()
	for h in fp:
		var neighbors: Array[Vector2i] = HexUtilsCls.get_all_neighbors(h.x, h.y)
		for n in neighbors:
			var key: String = "%d,%d" % [n.x, n.y]
			if _by_hex.has(key):
				continue # inside another stronghold
			if _occupied_by_any_other(key, garrison_unit_id):
				continue
			result.append(n)
	return result

func _occupied_by_any_other(key: String, exclude_unit_id: String) -> bool:
	# Placeholder — filled by external occupancy map via set_occupied_map().
	# In unit_manager context, delegate to unit_manager's occupancy check.
	return false

# ------------------------------------------------------------------
# OCCUPANCY DELEGATE (set by unit_manager at init)
# ------------------------------------------------------------------

var _occupancy_map: Dictionary = {}  # "q,r" -> unit_id
var _unit_manager_ref: Variant = null

func bind_occupancy(occ_map: Dictionary, um_ref: Variant) -> void:
	_occupancy_map = occ_map
	_unit_manager_ref = um_ref

func is_hex_occupied_by_other(q: int, r: int, exclude_unit_id: String) -> bool:
	var key: String = "%d,%d" % [q, r]
	if not _occupancy_map.has(key):
		return false
	var occ_id: String = str(_occupancy_map[key])
	return occ_id != exclude_unit_id

# Override the private check
func _occupancy_check(key: String, exclude_unit_id: String) -> bool:
	if not _occupancy_map.has(key):
		return false
	var occ_id: String = str(_occupancy_map[key])
	return occ_id != exclude_unit_id

func get_valid_deployment_hexes2(id: String, garrison_unit_id: String) -> Array[Vector2i]:
	var sh := get_stronghold_by_id(id)
	if not sh:
		return []
	var result: Array[Vector2i] = []
	if not sh.has_garrison_unit(garrison_unit_id):
		return result
	var fp := sh.get_footprint()
	for h in fp:
		var neighbors: Array[Vector2i] = HexUtilsCls.get_all_neighbors(h.x, h.y)
		for n in neighbors:
			var key: String = "%d,%d" % [n.x, n.y]
			if _by_hex.has(key):
				continue
			if _occupancy_check(key, garrison_unit_id):
				continue
			# Exclude enemy stronghold footprint hexes
			result.append(n)
	return result

# ------------------------------------------------------------------
# LIFECYCLE
# ------------------------------------------------------------------

func register_stronghold(sh: Stronghold) -> void:
	if _by_id.has(sh.structure_id):
		push_warning("[StrongholdManager] Duplicate stronghold ID: %s" % sh.structure_id)
		return
	_strongholds.append(sh)
	_by_id[sh.structure_id] = sh
	for h in sh.get_footprint():
		_by_hex["%d,%d" % [h.x, h.y]] = sh
	print("[StrongholdManager] Registered %s at %s (%d hexes, %d slots)" % [
		str(sh.structure_id),
		str(sh.get_anchor()),
		sh.get_footprint_count(),
		sh.garrison_slots
	])

func unregister_stronghold(id: String) -> void:
	var sh := get_stronghold_by_id(id)
	if not sh:
		return
	_strongholds.erase(sh)
	_by_id.erase(id)
	for h in sh.get_footprint():
		_by_hex.erase("%d,%d" % [h.x, h.y])

func clear_all() -> void:
	_strongholds.clear()
	_by_id.clear()
	_by_hex.clear()

# ------------------------------------------------------------------
# GARRISON ENTRY  (§6)
# ------------------------------------------------------------------

## Attempt to move a field unit into the garrison of a friendly stronghold.
## unit_id: field unit ID
## stronghold_id: target structure
## Returns {success, reason, unit_data?}
func garrison_enter(unit_id: String, stronghold_id: String) -> Dictionary:
	var sh := get_stronghold_by_id(stronghold_id)
	if not sh:
		return {"success": false, "reason": "Stronghold not found: %s" % stronghold_id}
	if sh.owner == "enemy" or sh.owner == "neutral":
		return {"success": false, "reason": "Cannot enter enemy/neutral stronghold"}
	var unit: Dictionary = {}
	if _unit_manager_ref and _unit_manager_ref.has_method("get_unit_by_id"):
		unit = _unit_manager_ref.call("get_unit_by_id", unit_id) as Dictionary
	if unit.is_empty():
		return {"success": false, "reason": "Unit not found: %s" % unit_id}
	if str(unit.get("faction", "")) != sh.owner:
		return {"success": false, "reason": "Faction mismatch"}
	if unit.get("action_ended", false):
		return {"success": false, "reason": "Unit action already ended"}
	var result: Dictionary = sh.enter_garrison(unit)
	if not result["success"]:
		return {"success": false, "reason": result["reason"]}
	# Remove field occupancy
	var uq: int = int(unit.get("q", 0))
	var ur: int = int(unit.get("r", 0))
	var key: String = "%d,%d" % [uq, ur]
	if _occupancy_map.has(key) and str(_occupancy_map[key]) == unit_id:
		_occupancy_map.erase(key)
	# Mark unit as garrisoned (stored on unit dict for UI)
	if _unit_manager_ref and _unit_manager_ref.has_method("set_garrison_state"):
		_unit_manager_ref.call("set_garrison_state", unit_id, true, stronghold_id)
	return {
		"success": true,
		"reason": "Entered garrison",
		"unit_id": unit_id,
		"garrison_count": sh.get_garrison_count(),
		"remaining_slots": sh.get_available_slots()
	}

# ------------------------------------------------------------------
# GARRISON DEPLOY / EXIT  (§7)
# ------------------------------------------------------------------

## Deploy a garrisoned unit back to an adjacent empty playable hex.
## garrison_unit_id: ID of the garrison entry (same as original unit_id)
## target_hex: destination coord
## Returns {success, reason, unit_data?}
func garrison_deploy(garrison_unit_id: String, target_hex: Vector2i, stronghold_id: String) -> Dictionary:
	var sh := get_stronghold_by_id(stronghold_id)
	if not sh:
		return {"success": false, "reason": "Stronghold not found"}
	if not sh.has_garrison_unit(garrison_unit_id):
		return {"success": false, "reason": "Garrison unit not found in roster"}
	var unit_data := sh.deploy_garrison_unit(garrison_unit_id)
	if unit_data.is_empty():
		return {"success": false, "reason": "Failed to remove from roster"}
	var tk: String = "%d,%d" % [target_hex.x, target_hex.y]
	if _by_hex.has(tk):
		return {"success": false, "reason": "Destination is inside a stronghold"}
	if _occupancy_map.has(tk):
		return {"success": false, "reason": "Destination is occupied"}
	# Re-instate field occupancy
	_occupancy_map[tk] = garrison_unit_id
	# Restore unit to field via unit_manager
	var restored: bool = false
	if _unit_manager_ref and _unit_manager_ref.has_method("restore_from_garrison"):
		restored = bool(_unit_manager_ref.call("restore_from_garrison", garrison_unit_id, target_hex.x, target_hex.y, unit_data))
		if not restored:
			# Rollback: re-add to garrison
			sh.enter_garrison(unit_data)
			_occupancy_map.erase(tk)
			return {"success": false, "reason": "Failed to restore unit to field"}
	if _unit_manager_ref and _unit_manager_ref.has_method("set_garrison_state"):
		_unit_manager_ref.call("set_garrison_state", garrison_unit_id, false, "")
	return {
		"success": true,
		"reason": "Deployed to field",
		"unit_id": garrison_unit_id,
		"target_hex": target_hex,
		"troop_count": unit_data.get("soldier_count", 0),
		"morale": unit_data.get("morale", 100.0),
		"class": unit_data.get("class", "")
	}

# ------------------------------------------------------------------
# COMBAT ASSAULT TARGETING  (§9, §11, §12, §21)
# ------------------------------------------------------------------

## Assault a stronghold. If wall intact → damages wall only (garrison safe).
## If breached → damages selected garrison unit.
## attacker_data: {class, soldier_count, morale}
## stronghold_id: target structure
## garrison_target_id: if breached, which garrison unit to hit (ignore if wall intact)
## siege_bonus: whether attacker is siege (2.5x wall damage)
## Returns {wall_damage, wall_remaining, garrison_casualties, garrison_remaining, breached_now, garrison_target_hit}
func assault_stronghold(
	attacker_data: Dictionary,
	stronghold_id: String,
	garrison_target_id: String = "",
	siege_bonus: bool = false
) -> Dictionary:
	var sh := get_stronghold_by_id(stronghold_id)
	if not sh:
		return {"success": false, "reason": "Stronghold not found"}
	var atk_class: String = str(attacker_data.get("class", "infantry"))
	var atk_troops: int = int(attacker_data.get("soldier_count", 100))
	var atk_morale: float = float(attacker_data.get("morale", 100.0))
	# Compute effective attack strength
	var siege_mult: float = 2.5 if siege_bonus else 1.0
	var raw_atk: float = (float(atk_troops) / 100.0) * 10.0  # base infantry attack
	var siege_dmg: float = raw_atk * siege_mult * 12.0
	var wall_dmg: int = clampi(roundi(siege_dmg), 1, maxi(1, sh.fortification_hp))
	var result: Dictionary = sh.take_wall_damage(wall_dmg)
	var breached_now: bool = result["breached_now"]
	var garrison_cas: int = 0
	var garrison_remaining: int = 0
	var garrison_hit_id: String = ""
	if breached_now and garrison_target_id != "":
		# Attack selected garrison unit
		var gu := sh.get_garrison_unit(garrison_target_id)
		if not gu.is_empty():
			var def_troops: int = int(gu.get("soldier_count", 100))
			var def_morale: float = float(gu.get("morale", 100.0))
			var calc := _calc_troop_combat(atk_class, atk_troops, atk_morale, "infantry", def_troops, def_morale)
			garrison_cas = int(calc["defender_casualties"])
			garrison_remaining = int(calc["defender_remaining_troops"])
			var new_morale: float = float(calc["defender_final_morale"])
			# Update the garrison entry in place
			for g in sh.garrison_units:
				if str(g.get("id", "")) == garrison_target_id:
					g["soldier_count"] = garrison_remaining
					g["morale"] = new_morale
					break
			garrison_hit_id = garrison_target_id
	# Update fortification HP on the stronghold object
	sh.fortification_hp = result["remaining_hp"]
	sh.breached = result["breached_now"]
	return {
		"success": true,
		"wall_damage": result["wall_damage"],
		"wall_remaining": result["remaining_hp"],
		"wall_max": sh.fortification_hp_max,
		"breached": breached_now,
		"breached_now": breached_now,
		"garrison_casualties": garrison_cas,
		"garrison_remaining": garrison_remaining,
		"garrison_target_hit": garrison_hit_id,
		"garrison_count": sh.get_garrison_count(),
		"stronghold_state": sh.get_state_label()
	}

func _calc_troop_combat(
	atk_class: String, atk_troops: int, atk_morale: float,
	def_class: String, def_troops: int, def_morale: float
) -> Dictionary:
	var calc := {}  # minimal inline — reuse CombatCalculator if available
	var atk_base: float = 10.0
	var def_base: float = 10.0
	var matchup: float = 1.0
	var eff_atk: float = (float(atk_troops) / 100.0) * atk_base * matchup * (0.4 + 0.6 * (atk_morale / 100.0))
	var eff_def: float = (float(def_troops) / 100.0) * def_base * (0.4 + 0.6 * (def_morale / 100.0))
	var ratio: float = clampf(eff_atk / (maxf(eff_def, 1.0) * 4.2 + 80.0), 0.04, 0.60)
	var cas: int = clampi(roundi(float(def_troops) * ratio), 1, def_troops)
	var remaining: int = def_troops - cas
	var new_morale: float = clampf(def_morale - (float(cas) / maxf(1, def_troops)) * 35.0, 0.0, 100.0)
	return {
		"defender_casualties": cas,
		"defender_remaining_troops": remaining,
		"defender_final_morale": new_morale
	}

# ------------------------------------------------------------------
# BATTLEFIELD OCCUPANCY CONTRACT  (§8)
# ------------------------------------------------------------------

## Returns true if a hex is inside any stronghold footprint.
func is_footprint_hex(q: int, r: int) -> bool:
	return _by_hex.has("%d,%d" % [q, r])

## Ordinary field units should not stand on footprint hexes.
## Call this before placing a unit on a hex.
func footprint_blocks_independent_units(q: int, r: int) -> bool:
	return _by_hex.has("%d,%d" % [q, r])

# ------------------------------------------------------------------
# STATE DUMP (for evidence contracts)
# ------------------------------------------------------------------

func dump_all() -> Dictionary:
	var list: Array = []
	for sh in _strongholds:
		list.append(sh.to_dict())
	return {
		"stronghold_count": _strongholds.size(),
		"strongholds": list,
		"by_hex_count": _by_hex.size()
	}
