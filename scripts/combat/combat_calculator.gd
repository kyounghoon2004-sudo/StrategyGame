class_name CombatCalculator
extends RefCounted

## STEP-04 Auditable Combat Pipeline Engine
## Evaluates:
##   raw_force_strength * class_matchup * morale_modifier * strategic_modifiers * seeded_variance
##   -> effective combat strength -> casualties & casualty-to-morale shock.

## Canonical DEV contract: while the Step 0 sandbox is active, morale must not
## be able to affect combat (modifier) or degrade from combat (shock).
const SandboxRulesCls = preload("res://scripts/core/sandbox_rules.gd")
const EpisodeRuntimeCls = preload("res://scripts/episodes/episode_runtime.gd")

# ==================================================================
# 1. Base Class Stats (Section 5)
# ==================================================================
const BASE_STATS: Dictionary = {
	"cavalry": {"attack": 14.0, "defense": 6.0, "range": 1},
	"infantry": {"attack": 10.0, "defense": 10.0, "range": 1},
	"archer": {"attack": 12.0, "defense": 4.0, "range": 3},
	"archers": {"attack": 12.0, "defense": 4.0, "range": 3},
	"spear": {"attack": 8.0, "defense": 14.0, "range": 1},
	"spearman": {"attack": 8.0, "defense": 14.0, "range": 1},
	"spearmen": {"attack": 8.0, "defense": 14.0, "range": 1},
	"scout": {"attack": 2.0, "defense": 3.0, "range": 1},
	"scouts": {"attack": 2.0, "defense": 3.0, "range": 1},
	"siege": {"attack": 18.0, "defense": 2.0, "range": 2},
	"conscript": {"attack": 5.0, "defense": 5.0, "range": 1},
	"conscripts": {"attack": 5.0, "defense": 5.0, "range": 1},
	"hq": {"attack": 8.0, "defense": 12.0, "range": 1},
	"supply": {"attack": 1.0, "defense": 2.0, "range": 1}
}

# ==================================================================
# 2. Canonical Matchup Multipliers (Section 6)
# ==================================================================
const MATCHUP_TABLE: Dictionary = {
	"cavalry_vs_archer": 1.35,
	"cavalry_vs_archers": 1.35,
	"archer_vs_spear": 1.35,
	"archers_vs_spear": 1.35,
	"archer_vs_spearman": 1.35,
	"archers_vs_spearmen": 1.35,
	"spear_vs_cavalry": 1.40,
	"spearman_vs_cavalry": 1.40,
	"spearmen_vs_cavalry": 1.40,
	"infantry_vs_archer": 1.20,
	"infantry_vs_archers": 1.20,
	"infantry_vs_cavalry": 0.85,
	"infantry_vs_spear": 0.85,
	"infantry_vs_spearman": 0.85,
	"infantry_vs_spearmen": 0.85,
	"conscript_vs_regular": 0.60,
	"scout_vs_regular": 0.55
}

# ==================================================================
# 2b. Temporary Field Fortification System (STEP-04R7.1 §5, §6, §7, §10, §11)
# Note: Old provisional FIELD_FORTIFICATION_CASUALTY_MULT = 0.85 is SUPERSEDED.
# Field fortification operates as a temporary defensive structure with dedicated HP.
# ==================================================================
const FIELD_FORTIFICATION_DEFAULT_HP: int = 180
const FIELD_FORTIFICATION_ABSORB_EXCESS_DAMAGE: bool = false # Model B: excess damage passes to troops
const FIELD_FORTIFICATION_CASUALTY_MULT_DEPRECATED: float = 0.85


static func normalize_class_name(cname: String) -> String:
	var n: String = cname.to_lower().strip_edges()
	if n == "archers": return "archer"
	if n == "spearman" or n == "spearmen": return "spear"
	if n == "scouts": return "scout"
	if n == "conscripts": return "conscript"
	return n

static func get_matchup_mult(attacker_class: String, defender_class: String) -> float:
	var atk: String = normalize_class_name(attacker_class)
	var def: String = normalize_class_name(defender_class)
	var table: Dictionary = EpisodeRuntimeCls.rules().get("matchup", MATCHUP_TABLE)
	
	if atk == def:
		return 1.0
	
	var direct_key: String = "%s_vs_%s" % [atk, def]
	if table.has(direct_key):
		return float(table[direct_key])
	
	var rev_key: String = "%s_vs_%s" % [def, atk]
	if table.has(rev_key):
		return 1.0 / float(table[rev_key])
	
	if atk == "conscript" and def != "conscript":
		return float(table["conscript_vs_regular"])
	if def == "conscript" and atk != "conscript":
		return 1.0 / float(table["conscript_vs_regular"])
		
	if atk == "scout" and def != "scout":
		return float(table["scout_vs_regular"])
	if def == "scout" and atk != "scout":
		return 1.0 / float(table["scout_vs_regular"])
	
	return 1.0

static func get_attack_range(unit_class: String) -> int:
	var n: String = normalize_class_name(unit_class)
	var episode_stats: Dictionary = EpisodeRuntimeCls.rules().get("class_stats", {})
	if episode_stats.has(n):
		return int(episode_stats[n]["range"])
	if BASE_STATS.has(n):
		return int(BASE_STATS[n]["range"])
	return 1

# ==================================================================
# 3. Morale Combat Multiplier (Section 9, 10, 11)
# ==================================================================
static func get_morale_modifier(morale: float) -> float:
	if not SandboxRulesCls.morale_rout_enabled():
		# DEV sandbox contract: morale is neutral — no morale combat modifier.
		return 1.0
	var m: float = clampf(morale, 0.0, 100.0)
	# Morale curve: 100 morale = 1.0x, 70 morale = 0.82x, 50 morale = 0.70x, 0 morale = 0.40x
	return 0.40 + 0.60 * (m / 100.0)

# ==================================================================
# 4. Combat Pipeline Calculation (Section 29)
# ==================================================================
static func calculate_combat(
	attacker_data: Dictionary,
	defender_data: Dictionary,
	distance: int = 1,
	fortification_hp: int = 0,
	strategic_modifiers: Dictionary = {},
	variance: float = 1.0
) -> Dictionary:
	var atk_class: String = normalize_class_name(str(attacker_data.get("class", "infantry")))
	var def_class: String = normalize_class_name(str(defender_data.get("class", "infantry")))
	
	var atk_troops: int = int(attacker_data.get("soldier_count", 100))
	var def_troops: int = int(defender_data.get("soldier_count", 100))
	
	var atk_morale: float = float(attacker_data.get("morale", 100.0))
	var def_morale: float = float(defender_data.get("morale", 100.0))
	
	var live_stats: Dictionary = EpisodeRuntimeCls.rules().get("class_stats", BASE_STATS)
	var atk_base_stat: Dictionary = live_stats.get(atk_class, {"attack": 10.0, "defense": 10.0, "range": 1})
	var def_base_stat: Dictionary = live_stats.get(def_class, {"attack": 10.0, "defense": 10.0, "range": 1})
	
	var atk_base_atk: float = float(atk_base_stat["attack"])
	var def_base_def: float = float(def_base_stat["defense"])
	var def_base_atk: float = float(def_base_stat["attack"])
	var atk_base_def: float = float(atk_base_stat["defense"])
	
	# 1. Raw Force Strength (Section 8: approximately linear force size)
	var raw_force_strength: float = (float(atk_troops) / 100.0) * atk_base_atk
	
	# 2. Matchup Multiplier (Section 6)
	var matchup_mult: float = get_matchup_mult(atk_class, def_class)
	
	# 3. Morale Modifier (Section 9, 10)
	var atk_morale_mod: float = get_morale_modifier(atk_morale)
	var def_morale_mod: float = get_morale_modifier(def_morale)
	
	# 4. Strategic Modifiers (Section 30 extension point)
	var strat_atk_mult: float = float(strategic_modifiers.get("attacker_bonus", 1.0))
	var strat_def_mult: float = float(strategic_modifiers.get("defender_bonus", 1.0))
	
	# 5. Effective Combat Strength
	var eff_atk: float = raw_force_strength * matchup_mult * atk_morale_mod * strat_atk_mult * variance
	var eff_def: float = (float(def_troops) / 100.0) * def_base_def * def_morale_mod * strat_def_mult * variance
	
	# 6. Fortress Hard Shield Layer vs Temporary Field Fortification vs Standard Combat
	var wall_damage: int = 0
	var new_fortification_hp: int = fortification_hp
	var def_casualties: int = 0
	
	# Field fortification state tracking (STEP-04R7.1 §6, §8, §9, §10)
	var init_field_fort_hp: int = int(defender_data.get("field_fortification_hp", 0))
	var is_field_fortified: bool = bool(defender_data.get("field_fortified", false)) or bool(defender_data.get("fortified", false)) or (init_field_fort_hp > 0)
	if is_field_fortified and init_field_fort_hp <= 0 and (defender_data.has("fortified") or defender_data.has("field_fortified")):
		if bool(defender_data.get("field_fortified", false)) or bool(defender_data.get("fortified", false)):
			init_field_fort_hp = FIELD_FORTIFICATION_DEFAULT_HP

	var field_fort_damage: int = 0
	var rem_field_fort_hp: int = init_field_fort_hp
	var is_field_fort_destroyed: bool = false

	if fortification_hp > 0:
		# Fortress Hard Shield Layer (Section 23, 24, 25): Attack directly damages wall HP. Garrison troops take ZERO casualties.
		var siege_mult: float = 2.5 if atk_class == "siege" else 1.0
		var raw_wall_dmg: float = eff_atk * siege_mult * 12.0
		wall_damage = clampi(roundi(raw_wall_dmg), 1, fortification_hp)
		new_fortification_hp = maxi(0, fortification_hp - wall_damage)
		def_casualties = 0
	else:
		# Standard troop combat (LOW_STRENGTH_CONTRACT_V0):
		# - the ratio floor scales with RELATIVE power (dealer/victim eff): an
		#   outclassed attacker keeps only chip damage instead of full
		#   defender-scaled floor damage (previously 1 soldier == 50 soldiers).
		# - absolute finish power (dealer eff * RATIO_MAX) lets overwhelming
		#   force finish remnants instead of grinding 1/hit (previously a
		#   300-strong attacker needed 4+ clean hits to kill 5 soldiers).
		# Both reuse existing constants; healthy-vs-healthy numbers are unchanged.
		var power_scale: float = clampf(eff_atk / maxf(eff_def, 0.001), 0.0, 1.0)
		var damage_ratio: float = clampf(eff_atk / (maxf(eff_def, 1.0) * 4.2 + 80.0), 0.04 * power_scale, 0.60)
		var percent_damage: int = roundi(float(def_troops) * damage_ratio)
		var finish_damage: int = mini(def_troops, roundi(eff_atk * 0.60))
		var raw_troop_damage: int = clampi(maxi(percent_damage, finish_damage), 1, def_troops)
		
		if init_field_fort_hp > 0:
			# ZOMBIE_FORT_FIX_V1: the fieldwork absorbs the attacker's UNCAPPED
			# strike. raw_troop_damage is capped at def_troops (you cannot kill
			# more soldiers than exist), but that cap must not limit damage to
			# the fortification: previously a 2-soldier fortified remnant took
			# 2 fort damage per hit (90 hits to break 180 HP) -- remaining
			# strength acted inversely as armor. Casualties stay capped below.
			var strike_damage: int = maxi(1, maxi(percent_damage, roundi(eff_atk * 0.60)))
			field_fort_damage = mini(strike_damage, init_field_fort_hp)
			rem_field_fort_hp = maxi(0, init_field_fort_hp - field_fort_damage)
			is_field_fort_destroyed = (rem_field_fort_hp <= 0)

			if FIELD_FORTIFICATION_ABSORB_EXCESS_DAMAGE:
				def_casualties = 0
			else:
				var excess_damage: int = strike_damage - field_fort_damage
				def_casualties = clampi(excess_damage, 0, def_troops)
		else:
			def_casualties = raw_troop_damage
	
	# 7. Counter-Attack / Retaliation (Section 15, 17)
	# Ranged attacks (distance > 1) receive NO return damage.
	# Melee attacks (distance == 1) cause mutual combat.
	# STEP-04R10 §19: GUARD = normal reciprocal, FORTIFIED = reciprocal behind fieldwork, UNGUARDED = no opening reciprocal
	var atk_casualties: int = 0
	var defender_unguarded: bool = bool(defender_data.get("unguarded", false))
	# REST is no longer unguarded per R10 §6, so only forced march triggers this
	if distance == 1 and def_troops > 0 and not defender_unguarded:
		var counter_matchup: float = 1.0 / matchup_mult
		var raw_def_atk: float = (float(def_troops) / 100.0) * def_base_atk
		var eff_counter_atk: float = raw_def_atk * counter_matchup * def_morale_mod * variance
		var eff_counter_def: float = (float(atk_troops) / 100.0) * atk_base_def * atk_morale_mod * variance
		var counter_scale: float = clampf(eff_counter_atk / maxf(eff_counter_def, 0.001), 0.0, 1.0)
		var counter_ratio: float = clampf(eff_counter_atk / (maxf(eff_counter_def, 1.0) * 5.5 + 110.0), 0.02 * counter_scale, 0.40)
		var counter_percent: int = roundi(float(atk_troops) * counter_ratio)
		var counter_finish: int = mini(atk_troops, roundi(eff_counter_atk * 0.40))
		atk_casualties = clampi(maxi(counter_percent, counter_finish), 0, atk_troops)
	elif defender_unguarded and distance == 1:
		# UNGUARDED defender does not inflict normal opening reciprocal damage (R10 defer fallback: 0)
		atk_casualties = 0
	
	# 8. Casualty-to-Morale Shock (Section 10, 11)
	var def_loss_prop: float = float(def_casualties) / float(maxi(1, def_troops))
	var atk_loss_prop: float = float(atk_casualties) / float(maxi(1, atk_troops))
	
	var def_morale_shock: float = 0.0
	if fortification_hp > 0:
		# Wall damage inflicts small morale vibration
		def_morale_shock = float(wall_damage) / 1000.0 * 5.0
	elif init_field_fort_hp > 0 and def_casualties == 0:
		def_morale_shock = float(field_fort_damage) / 500.0 * 2.0
	else:
		def_morale_shock = def_loss_prop * 35.0 + (3.0 if def_casualties > 0 else 0.0)
	
	var atk_morale_shock: float = 0.0
	if atk_casualties > 0:
		atk_morale_shock = atk_loss_prop * 35.0 + 2.0
	
	var new_def_morale: float = clampf(def_morale - def_morale_shock, 0.0, 100.0)
	var new_atk_morale: float = clampf(atk_morale - atk_morale_shock, 0.0, 100.0)
	if not SandboxRulesCls.morale_rout_enabled():
		# DEV sandbox contract: combat cannot degrade morale (pinned at entry value),
		# and reports zero shock so downstream morale writers stay neutral too.
		def_morale_shock = 0.0
		atk_morale_shock = 0.0
		new_def_morale = def_morale
		new_atk_morale = atk_morale
	
	return {
		"attacker_class": atk_class,
		"defender_class": def_class,
		"attacker_initial_troops": atk_troops,
		"defender_initial_troops": def_troops,
		"attacker_casualties": atk_casualties,
		"defender_casualties": def_casualties,
		"attacker_remaining_troops": maxi(0, atk_troops - atk_casualties),
		"defender_remaining_troops": maxi(0, def_troops - def_casualties),
		"wall_damage": wall_damage,
		"initial_fortification_hp": fortification_hp,
		"remaining_fortification_hp": new_fortification_hp,
		"is_fortress_breached": (fortification_hp > 0 and new_fortification_hp <= 0),
		"initial_field_fortification_hp": init_field_fort_hp,
		"remaining_field_fortification_hp": rem_field_fort_hp,
		"field_fortification_damage": field_fort_damage,
		"is_field_fortification_destroyed": is_field_fort_destroyed,
		"attacker_initial_morale": atk_morale,
		"defender_initial_morale": def_morale,
		"attacker_final_morale": new_atk_morale,
		"defender_final_morale": new_def_morale,
		"attacker_morale_delta": -atk_morale_shock,
		"defender_morale_delta": -def_morale_shock,
		"matchup_multiplier": matchup_mult,
		"effective_attack": eff_atk,
		"effective_defense": eff_def,
		"distance": distance,
		"is_ranged": distance > 1,
		"retaliation_occurred": distance == 1,
		"is_defender_field_fortified": (rem_field_fort_hp > 0),
		"is_defender_fortified": (rem_field_fort_hp > 0),
		"fortification_casualty_mult": 1.0
	}

# ==================================================================
# 5. Attack Damage Preview (Section 13, 36)
# ==================================================================
static func preview_attack(
	attacker_data: Dictionary,
	defender_data: Dictionary,
	distance: int = 1,
	fortification_hp: int = 0,
	strategic_modifiers: Dictionary = {}
) -> Dictionary:
	var low_res: Dictionary = calculate_combat(attacker_data, defender_data, distance, fortification_hp, strategic_modifiers, 0.95)
	var high_res: Dictionary = calculate_combat(attacker_data, defender_data, distance, fortification_hp, strategic_modifiers, 1.05)
	var base_res: Dictionary = calculate_combat(attacker_data, defender_data, distance, fortification_hp, strategic_modifiers, 1.00)
	
	var min_def_cas: int = mini(low_res["defender_casualties"], high_res["defender_casualties"])
	var max_def_cas: int = maxi(low_res["defender_casualties"], high_res["defender_casualties"])
	
	var min_atk_cas: int = mini(low_res["attacker_casualties"], high_res["attacker_casualties"])
	var max_atk_cas: int = maxi(low_res["attacker_casualties"], high_res["attacker_casualties"])
	
	var min_wall_dmg: int = mini(low_res["wall_damage"], high_res["wall_damage"])
	var max_wall_dmg: int = maxi(low_res["wall_damage"], high_res["wall_damage"])
	
	return {
		"attacker_class": base_res["attacker_class"],
		"defender_class": base_res["defender_class"],
		"matchup_multiplier": base_res["matchup_multiplier"],
		"distance": distance,
		"is_ranged": distance > 1,
		"fortification_hp": fortification_hp,
		"expected_enemy_casualties_min": min_def_cas,
		"expected_enemy_casualties_max": max_def_cas,
		"expected_friendly_casualties_min": min_atk_cas,
		"expected_friendly_casualties_max": max_atk_cas,
		"expected_wall_damage_min": min_wall_dmg,
		"expected_wall_damage_max": max_wall_dmg,
		"attacker_troops": base_res["attacker_initial_troops"],
		"defender_troops": base_res["defender_initial_troops"],
		"attacker_morale": base_res["attacker_initial_morale"],
		"defender_morale": base_res["defender_initial_morale"],
		"expected_defender_morale_loss": absf(base_res["defender_morale_delta"])
	}
