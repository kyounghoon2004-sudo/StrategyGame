class_name SimRulesFingerprint
extends RefCounted

## Simulation Playground v0.1 — live rules/config fingerprint.
##
## Reads the CURRENT canonical balance values at runtime and hashes them.
## Contains ZERO copied balance numbers: every entry is a live reference
## (CombatCalculator.BASE_STATS, Step3Config.*, Step6Config.*, TerrainMods.*,
## MoraleSystem.*, MovementCalculator.*, fog vision defaults).
## A future balance change automatically changes this fingerprint, so every
## episode stays traceable to the rule configuration that produced it.

const CombatCalculatorCls = preload("res://scripts/combat/combat_calculator.gd")
const EpisodeRuntimeCls = preload("res://scripts/episodes/episode_runtime.gd")
const Step3ConfigCls = preload("res://scripts/core/step3_config.gd")
const Step6ConfigCls = preload("res://scripts/step6/step6_config.gd")
const TerrainModsCls = preload("res://scripts/combat/terrain_mods.gd")
const MoraleSystemCls = preload("res://scripts/combat/morale_system.gd")
const MovementCalculatorCls = preload("res://scripts/combat/movement_calculator.gd")
const FogCls = preload("res://scripts/step5/fog_of_war.gd")


static func compute() -> Dictionary:
	var sources: Dictionary = {
		"combat_calculator": {
			"base_stats": CombatCalculatorCls.BASE_STATS,
			"matchup_table": CombatCalculatorCls.MATCHUP_TABLE,
			"field_fortification_default_hp": CombatCalculatorCls.FIELD_FORTIFICATION_DEFAULT_HP,
			"field_fortification_absorb_excess": CombatCalculatorCls.FIELD_FORTIFICATION_ABSORB_EXCESS_DAMAGE,
		},
		"step3_movement": {
			"class_base_movement": Step3ConfigCls.CLASS_BASE_MOVEMENT,
			"terrain_costs_standard": Step3ConfigCls.TERRAIN_COSTS_STANDARD,
			"terrain_costs_scout": Step3ConfigCls.TERRAIN_COSTS_SCOUT,
			"food_consumption": Step3ConfigCls.FOOD_CONSUMPTION,
			"morale_penalty": Step3ConfigCls.MORALE_PENALTY,
			"march_multipliers": Step3ConfigCls.MARCH_MULTIPLIERS,
			# Live behavior probes (function outputs for base 1.0, not copies).
			"blue_limit_at_1": Step3ConfigCls.get_blue_limit(1.0),
			"red_limit_at_1": Step3ConfigCls.get_red_limit(1.0),
			"black_limit_at_1": Step3ConfigCls.get_black_limit(1.0),
		},
		"step6_decision": {
			"central_stockpile_start": Step6ConfigCls.CENTRAL_STOCKPILE_START,
			"food_per_troop_per_turn": Step6ConfigCls.FOOD_PER_TROOP_PER_TURN,
			"local_supply_turns": Step6ConfigCls.LOCAL_SUPPLY_TURNS,
			"hq_supply_turns": Step6ConfigCls.HQ_SUPPLY_TURNS,
			"forced_march_extra_turns": Step6ConfigCls.FORCED_MARCH_EXTRA_TURNS,
			"coverage_hq": Step6ConfigCls.COVERAGE_HQ,
			"coverage_city": Step6ConfigCls.COVERAGE_CITY,
			"coverage_fortress": Step6ConfigCls.COVERAGE_FORTRESS,
			"logistics_radius_stronghold": Step6ConfigCls.LOGISTICS_RADIUS_STRONGHOLD,
			"coverage_depot": Step6ConfigCls.COVERAGE_DEPOT,
			"coverage_village": Step6ConfigCls.COVERAGE_VILLAGE,
			"supply_unit_base_mp": Step6ConfigCls.SUPPLY_UNIT_BASE_MP,
			"supply_unit_service_radius": Step6ConfigCls.SUPPLY_UNIT_SERVICE_RADIUS,
			"supply_unit_cargo_capacity": Step6ConfigCls.SUPPLY_UNIT_CARGO_CAPACITY,
			"supply_days_healthy": Step6ConfigCls.SUPPLY_DAYS_HEALTHY,
			"supply_days_warning": Step6ConfigCls.SUPPLY_DAYS_WARNING,
			"supply_days_critical": Step6ConfigCls.SUPPLY_DAYS_CRITICAL,
			"rest_morale_restore": Step6ConfigCls.REST_MORALE_RESTORE,
			"hunger_morale_first": Step6ConfigCls.HUNGER_MORALE_FIRST,
			"hunger_morale_ongoing": Step6ConfigCls.HUNGER_MORALE_ONGOING,
			"hunger_fatigue": Step6ConfigCls.HUNGER_FATIGUE,
			"supplied_fatigue_recovery": Step6ConfigCls.SUPPLIED_FATIGUE_RECOVERY,
			"hq_near_dist": Step6ConfigCls.HQ_NEAR_DIST,
			"hq_far_dist": Step6ConfigCls.HQ_FAR_DIST,
			"hq_near_bonus": Step6ConfigCls.HQ_NEAR_BONUS,
			"hq_far_penalty": Step6ConfigCls.HQ_FAR_PENALTY,
			"encircle_adjacent": Step6ConfigCls.ENCIRCLE_ADJACENT,
			"encircle_penalty": Step6ConfigCls.ENCIRCLE_PENALTY,
			"witness_rout_radius": Step6ConfigCls.WITNESS_ROUT_RADIUS,
			"witness_rout_shock": Step6ConfigCls.WITNESS_ROUT_SHOCK,
			"witness_rout_cap": Step6ConfigCls.WITNESS_ROUT_CAP,
			"witness_destroy_shock": Step6ConfigCls.WITNESS_DESTROY_SHOCK,
			"witness_destroy_cap": Step6ConfigCls.WITNESS_DESTROY_CAP,
			"drift_min": Step6ConfigCls.DRIFT_MIN,
			"drift_max": Step6ConfigCls.DRIFT_MAX,
			"fatigue_green": Step6ConfigCls.FATIGUE_GREEN,
			"fatigue_orange": Step6ConfigCls.FATIGUE_ORANGE,
			"fatigue_red": Step6ConfigCls.FATIGUE_RED,
			"fatigue_exhausted": Step6ConfigCls.FATIGUE_EXHAUSTED,
			"starving_effect_mult": Step6ConfigCls.STARVING_EFFECT_MULT,
			"exhausted_effect_mult": Step6ConfigCls.EXHAUSTED_EFFECT_MULT,
			"routed_defenseless_mult": Step6ConfigCls.ROUTED_DEFENSELESS_MULT,
			"rout_morale_line": Step6ConfigCls.ROUT_MORALE_LINE,
			"rout_base_p": Step6ConfigCls.ROUT_BASE_P,
			"rout_morale_scale": Step6ConfigCls.ROUT_MORALE_SCALE,
			"rout_hungry_p": Step6ConfigCls.ROUT_HUNGRY_P,
			"rout_encircled_p": Step6ConfigCls.ROUT_ENCIRCLED_P,
			"rout_p_cap": Step6ConfigCls.ROUT_P_CAP,
			"rally_min_turns": Step6ConfigCls.RALLY_MIN_TURNS,
			"rally_near_hq": Step6ConfigCls.RALLY_NEAR_HQ,
			"rally_base_p": Step6ConfigCls.RALLY_BASE_P,
			"rally_morale_floor": Step6ConfigCls.RALLY_MORALE_FLOOR,
		},
		"terrain_mods": {
			"defense_bonus": TerrainModsCls.DEFENSE_BONUS,
			"archer_range_bonus": TerrainModsCls.ARCHER_RANGE_BONUS,
			"can_ambush": TerrainModsCls.CAN_AMBUSH,
			"default_passable": TerrainModsCls.DEFAULT_PASSABLE,
		},
		"morale_system": {
			"state_steady": MoraleSystemCls.STATE_STEADY,
			"state_wavering": MoraleSystemCls.STATE_WAVERING,
			"state_panic": MoraleSystemCls.STATE_PANIC,
			"state_break": MoraleSystemCls.STATE_BREAK,
		},
		"movement_calculator_legacy": {
			"terrain_cost": MovementCalculatorCls.TERRAIN_COST,
			"size_threshold": MovementCalculatorCls.SIZE_THRESHOLD,
			"size_per_300": MovementCalculatorCls.SIZE_PER_300,
			"size_divisor": MovementCalculatorCls.SIZE_DIVISOR,
			"conscript_cost_per_400": MovementCalculatorCls.CONSCRIPT_COST_PER_400,
		},
		"fog_defaults": _fog_defaults(),
	}
	if not EpisodeRuntimeCls.current().is_empty():
		sources["episode"] = EpisodeRuntimeCls.current()
	var canon := _canon(sources)
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(canon.to_utf8_buffer())
	var digest := ctx.finish()
	return {
		"fingerprint": digest.hex_encode(),
		"canonical_length": canon.length(),
		"source_tables": sources.keys(),
	}


static func _fog_defaults() -> Dictionary:
	var fog: RefCounted = FogCls.new()
	return {
		"normal_vision": int(fog.get("normal_vision")),
		"scout_vision": int(fog.get("scout_vision")),
	}


## Deterministic canonical serialization (sorted dict keys, fixed floats).
static func _canon(value: Variant) -> String:
	if value == null:
		return "null"
	if value is bool:
		return "true" if bool(value) else "false"
	if value is int:
		return str(int(value))
	if value is float:
		return "%.6f" % float(value)
	if value is String:
		return JSON.stringify(str(value))
	if value is Color:
		var c: Color = value as Color
		return "color(%.6f,%.6f,%.6f,%.6f)" % [c.r, c.g, c.b, c.a]
	if value is Vector2i:
		var v: Vector2i = value
		return "[%d,%d]" % [v.x, v.y]
	if value is Dictionary:
		var keys: Array = (value as Dictionary).keys()
		keys.sort()
		var parts: Array = []
		for k in keys:
			parts.append("%s:%s" % [JSON.stringify(str(k)), _canon((value as Dictionary)[k])])
		return "{%s}" % ",".join(parts)
	if value is Array:
		var cells: Array = []
		for item in (value as Array):
			cells.append(_canon(item))
		return "[%s]" % ",".join(cells)
	return JSON.stringify(str(value))
