class_name Stronghold
extends RefCounted

## STRONGHOLD — Multi-Hex Strategic Structure Entity
## Fortress / Capital occupying 2-3 logical hexes with garrison roster.
##
## Contract: STEP-04R2-MULTIHEX-STRONGHOLD-GARRISON
## §2 Multi-Hex Footprint · §3 Footprint Contract · §4 Garrison State
## §5 Garrison Capacity · §9 Fortification Shield · §10 One Wall Pool
## §11 Breach State · §12 Multiple Garrison Targets

enum StrongholdType {
	FORTRESS,
	CAPITAL
}

var structure_id: String = ""
var structure_type: StrongholdType = StrongholdType.FORTRESS
var owner: String = "neutral"
var footprint_hexes: Array[Vector2i] = []
var anchor_hex: Vector2i = Vector2i(-999, -999)
var fortification_hp: int = 0
var fortification_hp_max: int = 0
var breached: bool = false
var garrison_slots: int = 4
var garrison_units: Array[Dictionary] = []

# ─────────────────────────────────────────────────────────────
# INITIALIZATION
# ─────────────────────────────────────────────────────────────

func _init(
	_id: String = "",
	_type: StrongholdType = StrongholdType.FORTRESS,
	_owner: String = "neutral",
	_footprint: Array[Vector2i] = [],
	_hp: int = 1000,
	_slots: int = 4
) -> void:
	structure_id = _id
	structure_type = _type
	owner = _owner
	footprint_hexes = _footprint.duplicate() if not _footprint.is_empty() else []
	if not footprint_hexes.is_empty():
		anchor_hex = footprint_hexes[0]
	fortification_hp_max = _hp
	fortification_hp = _hp
	garrison_slots = _slots
	breached = false

# ─────────────────────────────────────────────────────────────
# FOOTPRINT QUERIES  (§23 Structure Perimeter Query)
# ─────────────────────────────────────────────────────────────

## Returns true if the given coord is part of this stronghold's footprint.
func contains_hex(coord: Vector2i) -> bool:
	for h in footprint_hexes:
		if h == coord:
			return true
	return false

## Returns the footprint as a duplicate array.
func get_footprint() -> Array[Vector2i]:
	return footprint_hexes.duplicate()

## Returns the anchor (first) hex.
func get_anchor() -> Vector2i:
	return anchor_hex

## Returns the number of footprint hexes.
func get_footprint_count() -> int:
	return footprint_hexes.size()

# ─────────────────────────────────────────────────────────────
# STRONGHOLD STATE QUERIES  (§23)
# ─────────────────────────────────────────────────────────────

## Returns true if this coord is inside ANY stronghold footprint.
static func is_stronghold_hex(coord: Vector2i, all_strongholds: Array) -> bool:
	for sh in all_strongholds:
		if sh.contains_hex(coord):
			return true
	return false

## Returns the stronghold at the given coord, or null.
static func get_stronghold_at(coord: Vector2i, all_strongholds: Array) -> Stronghold:
	for sh in all_strongholds:
		if sh.contains_hex(coord):
			return sh
	return null

## Returns footprint hexes for a stronghold ID from a registry.
static func get_stronghold_perimeter_hexes(id: String, registry: Dictionary) -> Array[Vector2i]:
	if registry.has(id):
		return registry[id].get_footprint()
	return []

## Returns true if the stronghold is intact (wall HP > 0).
func is_intact() -> bool:
	return not breached and fortification_hp > 0

## Returns the current state label.
func get_state_label() -> String:
	if breached or fortification_hp <= 0:
		return "BREACHED"
	return "INTACT"

# ─────────────────────────────────────────────────────────────
# FORTIFICATION SHIELD  (§9, §10, §11)
# ─────────────────────────────────────────────────────────────

## Damage the fortification wall. garrison_casualties=0 while HP>0.
## Returns {wall_damage, remaining_hp, breached_now, garrison_casualties}.
func take_wall_damage(damage: int) -> Dictionary:
	if breached or fortification_hp <= 0:
		return {
			"wall_damage": 0,
			"remaining_hp": 0,
			"breached_now": false,
			"garrison_casualties": 0
		}
	var actual: int = clampi(damage, 1, fortification_hp)
	fortification_hp -= actual
	if fortification_hp <= 0:
		fortification_hp = 0
		breached = true
	return {
		"wall_damage": actual,
		"remaining_hp": fortification_hp,
		"breached_now": breached,
		"garrison_casualties": 0
	}

## Returns current wall HP ratio (0.0–1.0).
func get_wall_ratio() -> float:
	if fortification_hp_max <= 0:
		return 0.0
	return clampf(float(fortification_hp) / float(fortification_hp_max), 0.0, 1.0)

# ─────────────────────────────────────────────────────────────
# GARRISON SYSTEM  (§4, §5, §6, §7, §12)
# ─────────────────────────────────────────────────────────────

## Returns available garrison slots (max - filled).
func get_available_slots() -> int:
	return garrison_slots - garrison_units.size()

## Returns true if garrison still has room.
func has_garrison_capacity() -> bool:
	return garrison_units.size() < garrison_slots

## Attempt to add a unit to garrison.
## unit_data: {id, class, soldier_count, morale, faction, ...}
## Returns {success, reason} — fails if full or already present.
func enter_garrison(unit_data: Dictionary) -> Dictionary:
	if not has_garrison_capacity():
		return {"success": false, "reason": "Garrison full"}
	for gu in garrison_units:
		if str(gu.get("id", "")) == str(unit_data.get("id", "")):
			return {"success": false, "reason": "Unit already in garrison"}
	var entry: Dictionary = {
		"id": str(unit_data.get("id", "")),
		"class": str(unit_data.get("class", "infantry")),
		"soldier_count": int(unit_data.get("soldier_count", 0)),
		"morale": float(unit_data.get("morale", 100.0)),
		"faction": str(unit_data.get("faction", "neutral")),
		"name": str(unit_data.get("name", "")),
		"max_count": int(unit_data.get("max_count", int(unit_data.get("soldier_count", 0))))
	}
	garrison_units.append(entry)
	return {"success": true, "reason": "Entered garrison", "garrison_count": garrison_units.size()}

## Remove a garrison unit by ID and return its data.
## Returns null if not found.
func deploy_garrison_unit(unit_id: String) -> Dictionary:
	for i in range(garrison_units.size()):
		if str(garrison_units[i].get("id", "")) == unit_id:
			var unit: Dictionary = garrison_units[i].duplicate()
			garrison_units.remove_at(i)
			return unit
	return {}

## Returns the garrison unit dict for a given ID, or null.
func get_garrison_unit(unit_id: String) -> Dictionary:
	for gu in garrison_units:
		if str(gu.get("id", "")) == unit_id:
			return gu.duplicate()
	return {}

## Returns the full garrison roster (duplicates).
func get_garrison_roster() -> Array:
	return garrison_units.duplicate()

## Returns garrison count.
func get_garrison_count() -> int:
	return garrison_units.size()

## Returns true if a specific garrison unit ID is present.
func has_garrison_unit(unit_id: String) -> bool:
	for gu in garrison_units:
		if str(gu.get("id", "")) == unit_id:
			return true
	return false

# ─────────────────────────────────────────────────────────────
# SERIALIZATION HELPERS  (§3 Footprint Contract)
# ─────────────────────────────────────────────────────────────

func to_dict() -> Dictionary:
	var fd: Array = []
	for h in footprint_hexes:
		fd.append({"q": h.x, "r": h.y})
	var gd: Array = []
	for gu in garrison_units:
		gd.append({
			"id": gu.get("id", ""),
			"class": gu.get("class", ""),
			"soldier_count": gu.get("soldier_count", 0),
			"morale": gu.get("morale", 100.0),
			"faction": gu.get("faction", ""),
			"name": gu.get("name", "")
		})
	return {
		"structure_id": structure_id,
		"structure_type": "FORTRESS" if structure_type == StrongholdType.FORTRESS else "CAPITAL",
		"owner": owner,
		"footprint_hexes": fd,
		"anchor_hex": {"q": anchor_hex.x, "r": anchor_hex.y},
		"fortification_hp": fortification_hp,
		"fortification_hp_max": fortification_hp_max,
		"breached": breached,
		"garrison_slots": garrison_slots,
		"garrison_count": garrison_units.size(),
		"garrison_units": gd
	}

static func from_dict(d: Dictionary) -> Stronghold:
	var st: StrongholdType = StrongholdType.FORTRESS
	var t: String = str(d.get("structure_type", "FORTRESS"))
	if t == "CAPITAL":
		st = StrongholdType.CAPITAL
	var fp: Array[Vector2i] = []
	for h in d.get("footprint_hexes", []):
		fp.append(Vector2i(int(h.get("q", 0)), int(h.get("r", 0))))
	var sh: Stronghold = Stronghold.new(
		str(d.get("structure_id", "")),
		st,
		str(d.get("owner", "neutral")),
		fp,
		int(d.get("fortification_hp_max", 1000)),
		int(d.get("garrison_slots", 4))
	)
	sh.fortification_hp = int(d.get("fortification_hp", sh.fortification_hp_max))
	sh.breached = bool(d.get("breached", false))
	for gu in d.get("garrison_units", []):
		var entry: Dictionary = {
			"id": str(gu.get("id", "")),
			"class": str(gu.get("class", "infantry")),
			"soldier_count": int(gu.get("soldier_count", 0)),
			"morale": float(gu.get("morale", 100.0)),
			"faction": str(gu.get("faction", "neutral")),
			"name": str(gu.get("name", "")),
			"max_count": int(gu.get("max_count", int(gu.get("soldier_count", 0))))
		}
		sh.garrison_units.append(entry)
	return sh
