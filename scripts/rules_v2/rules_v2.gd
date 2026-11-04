class_name RulesV2
extends RefCounted

## Rules V2 (2026-10-31, see RULES_V2_SPEC.md). Opt-in per battlefield via
## scenario.rules_version == "v2"; every other mission keeps legacy rules.
## Units: HP (soldier_count), attack, move. No defense stat, no matchups.

static var enabled: bool = false
static var config: Dictionary = {}
## Cells the player has seen (explored or visible), set by the shell after every fog recompute. Movement PLANNING for blue treats
## every other cell as flat ground (cost 1): unseen terrain does not leak into the route / reach preview. Execution is truthful.
static var known: Dictionary = {}
static var known_on: bool = false


static func planned_terrain(key: String, terrain: int, faction: String) -> int:
	if enabled and known_on and faction == "blue" and not known.has(key):
		return 0
	return terrain   # scenario.rules_v2 overrides (supply radii, stock ...)

# Tuning constants (first pass, balance in M1).
const ATTACK: Dictionary = {
	"conscript": 7.0, "infantry": 10.0, "spear": 15.0, "archer": 10.0,
	"cavalry": 12.0, "scout": 3.0, "hq": 6.0, "siege": 14.0,
}
const MOVE: Dictionary = {
	"conscript": 2.0, "infantry": 2.0, "spear": 2.0, "archer": 2.0,
	"cavalry": 4.0, "scout": 5.0, "hq": 3.0, "siege": 1.0,
}
## Attack range in hexes (default 1). Archers reach one hex further; a shot from 2 hexes draws no counter (the calc only
## counters at distance 1).
const RANGE: Dictionary = {"archer": 2}
const DAMAGE_SCALE: float = 1.5      # attack -> HP damage
const HP_FLOOR: float = 0.4          # wounded units hit at 40% + 60% * hp_frac
const FORT_WALL_MULT: float = 7.0    # damage -> building HP
const FORT_STRUCT_SHARE: float = 0.5 # share of a hit that goes to the structure when a unit stands on it
const MORALE_SHOCK_DEF: float = 30.0 # x (damage / max_hp)
const MORALE_SHOCK_ATK: float = 18.0

# Promotion tree: conscript -> infantry -> {spear, cavalry, archer}.
const PROMOTE_XP: Dictionary = {"conscript": 40, "infantry": 90}
const PROMOTE_HP_BONUS: int = 10
const TREE: Dictionary = {
	"conscript": ["infantry"],
	"infantry": ["spear", "cavalry", "archer"],
}
const XP_PER_DAMAGE: float = 1.0
const XP_KILL_BONUS: int = 15

# Supply thresholds (morale, 0..100).
const MORALE_WEAK: float = 66.0
const MORALE_BROKEN: float = 33.0
const WEAK_MULT: float = 0.7          # attack and move
const DESERT_P: float = 0.35          # per turn when morale <= BROKEN
const DESERT_FRAC: float = 0.10       # of max HP
const NEAR_HEAL_FRAC: float = 0.10    # of max HP per turn
const NEAR_MORALE: float = 20.0
const NORMAL_MORALE: float = 6.0      # inside the outer ring: morale still recovers
const OUT_MORALE: float = -8.0
const TOWN_PLUNDER_STOCK: int = 3
const REST_HEAL_FRAC: float = 0.15    # 휴식: of max HP; only inside the healing (near) radius
const BASE_DMG_MULT: float = 2.0      # an attack's damage -> base HP (about 3 hits to break 80 HP)
const BASE_HP: int = 80               # 병참기지: own HP, broken by an adjacent enemy attack (no counter)
const FORT_HP: int = 120              # 요새화: the wooden palisade has its own HP; one use per unit per game


static func set_from_scenario(scenario: Dictionary) -> void:
	enabled = str(scenario.get("rules_version", "")) == "v2"
	config = (scenario.get("rules_v2", {}) as Dictionary).duplicate(true) if enabled else {}


static func norm(cls: String) -> String:
	var n := cls.to_lower().strip_edges()
	if n == "spearman" or n == "spearmen":
		return "spear"
	if n == "archers":
		return "archer"
	if n == "scouts":
		return "scout"
	if n == "conscripts":
		return "conscript"
	return n


static func attack_of(cls: String) -> float:
	return float(ATTACK.get(norm(cls), 8.0))


static func range_of(cls: String) -> int:
	return int(RANGE.get(norm(cls), 1))


static func move_of(cls: String) -> float:
	return float(MOVE.get(norm(cls), 2.0))


## Morale/supply multiplier shared by attack and move.
static func weak_mult(morale: float) -> float:
	return WEAK_MULT if morale <= MORALE_WEAK else 1.0


static func hp_mult(hp: int, max_hp: int) -> float:
	var f := clampf(float(hp) / float(maxi(1, max_hp)), 0.0, 1.0)
	return HP_FLOOR + (1.0 - HP_FLOOR) * f


static func calc(attacker: Dictionary, defender: Dictionary, distance: int, fortification_hp: int) -> Dictionary:
	var atk_cls := norm(str(attacker.get("class", "infantry")))
	var def_cls := norm(str(defender.get("class", "infantry")))
	var atk_hp := int(attacker.get("soldier_count", 1))
	var def_hp := int(defender.get("soldier_count", 1))
	var atk_max := int(attacker.get("max_count", atk_hp))
	var def_max := int(defender.get("max_count", def_hp))
	var atk_m := float(attacker.get("morale", 100.0))
	var def_m := float(defender.get("morale", 100.0))

	var dmg := attack_of(atk_cls) * DAMAGE_SCALE * hp_mult(atk_hp, atk_max) * weak_mult(atk_m)
	var wall_damage := 0
	var new_fort := fortification_hp
	var def_cas := 0
	var unit_fort := int(defender.get("fort_hp", 0))
	var unit_fort_dmg := 0
	var structure_only := bool(defender.get("structure_only", false))
	if fortification_hp > 0 and structure_only:
		wall_damage = clampi(roundi(dmg * FORT_WALL_MULT), 1, fortification_hp)
		new_fort = fortification_hp - wall_damage
	elif unit_fort > 0:
		# the unit's own palisade takes its share first-hand; the rest hits the unit
		unit_fort_dmg = clampi(roundi(dmg * FORT_WALL_MULT * FORT_STRUCT_SHARE), 1, unit_fort)
		def_cas = clampi(roundi(dmg * (1.0 - FORT_STRUCT_SHARE)), 1, def_hp)
	elif fortification_hp > 0:
		# a unit stands on a structure: the hit is split between wall and unit
		wall_damage = clampi(roundi(dmg * FORT_WALL_MULT * FORT_STRUCT_SHARE), 1, fortification_hp)
		new_fort = fortification_hp - wall_damage
		def_cas = clampi(roundi(dmg * (1.0 - FORT_STRUCT_SHARE)), 1, def_hp)
	else:
		def_cas = clampi(roundi(dmg), 1, def_hp)

	var atk_cas := 0
	# 휴식 = 무방비: no melee counter during the enemy phase after resting
	var defenseless := bool(defender.get("rested_this_turn", false))
	if distance == 1 and not structure_only and not defenseless and not bool(defender.get("unguarded", false)):
		var counter := attack_of(def_cls) * DAMAGE_SCALE * hp_mult(def_hp, def_max) * weak_mult(def_m)
		atk_cas = clampi(roundi(counter), 0, atk_hp)

	var def_shock := 0.0
	if def_cas > 0:
		def_shock = MORALE_SHOCK_DEF * float(def_cas) / float(maxi(1, def_max))
	var atk_shock := MORALE_SHOCK_ATK * float(atk_cas) / float(maxi(1, atk_max))
	return {
		"attacker_class": atk_cls, "defender_class": def_cls,
		"attacker_initial_troops": atk_hp, "defender_initial_troops": def_hp,
		"attacker_casualties": atk_cas, "defender_casualties": def_cas,
		"attacker_remaining_troops": maxi(0, atk_hp - atk_cas),
		"defender_remaining_troops": maxi(0, def_hp - def_cas),
		"wall_damage": wall_damage,
		"initial_fortification_hp": fortification_hp,
		"remaining_fortification_hp": new_fort,
		"is_fortress_breached": fortification_hp > 0 and new_fort <= 0,
		"initial_field_fortification_hp": 0, "remaining_field_fortification_hp": 0,
		"field_fortification_damage": 0, "is_field_fortification_destroyed": false,
		"attacker_initial_morale": atk_m, "defender_initial_morale": def_m,
		"attacker_final_morale": clampf(atk_m - atk_shock, 0.0, 100.0),
		"defender_final_morale": clampf(def_m - def_shock, 0.0, 100.0),
		"attacker_morale_delta": -atk_shock, "defender_morale_delta": -def_shock,
		"matchup_multiplier": 1.0, "effective_attack": dmg, "effective_defense": 0.0,
		"distance": distance, "is_ranged": distance > 1,
		"retaliation_occurred": distance == 1,
		"is_defender_field_fortified": false, "is_defender_fortified": false,
		"fortification_casualty_mult": 1.0,
		"unit_fort_damage": unit_fort_dmg, "unit_fort_remaining": unit_fort - unit_fort_dmg,
	}
