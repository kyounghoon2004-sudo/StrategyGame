class_name Step3Config
extends RefCounted

## STEP-03 Movement & March Envelope Prototype Configuration
## Central tuning constants and logic for classes, terrain traversal, march envelopes, and policies.

## Canonical DEV contract: the Step 0 sandbox must not suffer march morale loss.
const SandboxRulesCls = preload("res://scripts/core/sandbox_rules.gd")
const EpisodeRuntimeCls = preload("res://scripts/episodes/episode_runtime.gd")

# ==================================================================
# 1. ENUMS
# ==================================================================
enum MarchClass {
	GREEN = 0,   # Normal march
	ORANGE = 1,  # Forced / Extended march
	RED = 2      # Extreme march
}

enum MarchPolicy {
	GREEN_ONLY = 0,      # Green only; blocks Orange & Red
	ORANGE_ALLOWED = 1,  # Green + Orange allowed; blocks Red
	RED_ALLOWED = 2      # Green, Orange, & Red allowed
}

# ==================================================================
# 2. CLASS MOVEMENT BASELINES (Section 6)
# ==================================================================
const CLASS_BASE_MOVEMENT: Dictionary = {
	"cavalry": 3.0,
	"infantry": 2.0,
	"archer": 2.0,
	"spear": 2.0,
	"spearman": 2.0,
	"scout": 4.0,
	"siege": 1.0,
	"conscript": 1.0,
	"hq": 1.0,
	"supply": 8.0 # STEP-06R2 §12: Fast mobile supply hub (8 MP, faster than Scout)
}

# Movement budget multipliers for full-turn envelope tiers
# Green = 1.0x, Orange = 1.5x, Red = 2.2x
const MARCH_MULTIPLIERS: Dictionary = {
	MarchClass.GREEN: 1.0,
	MarchClass.ORANGE: 1.5,
	MarchClass.RED: 2.2
}

# ==================================================================
# 3. TERRAIN MOVEMENT COSTS (Section 8)
# Road (0.5) < Plain (1.0) < Forest/Marsh (2.0) < Mountain (3.0)
# ==================================================================
const TERRAIN_COSTS_STANDARD: Dictionary = {
	0: 1.0,  # PLAINS
	1: 3.0,  # MOUNTAINS (normal internal)
	2: 2.0,  # FOREST
	3: 2.0,  # SWAMP / MARSH
	4: 1.0,  # FORTRESS
	5: 1.0,  # VILLAGE
	6: 0.5,  # ROAD
	7: 1.0,  # RIVER (traversable, edge triggers RED)
	8: 99.0,  # WALL (impassable)
	9: 99.0,  # STRONGHOLD_FOOTPRINT (multi-hex structure interior — impassable)
	10: 99.0,  # STRONGHOLD_WALL (perimeter wall hex — impassable)
}

# Scout terrain specialization (Section 7)
# Scout ignores normal movement-speed penalties from Forest and normal Mountain
const TERRAIN_COSTS_SCOUT: Dictionary = {
	0: 1.0,  # PLAINS
	1: 1.0,  # MOUNTAINS (treated like basic traversable terrain)
	2: 1.0,  # FOREST (treated like basic traversable terrain)
	3: 1.5,  # SWAMP / MARSH
	4: 1.0,  # FORTRESS
	5: 1.0,  # VILLAGE
	6: 0.5,  # ROAD
	7: 1.0,  # RIVER (traversable, edge triggers RED)
	8: 99.0,  # WALL (impassable)
	9: 99.0,  # STRONGHOLD_FOOTPRINT
	10: 99.0,  # STRONGHOLD_WALL
}

# ==================================================================
# 4. MORALE CONSEQUENCES (Sections 30, 31, 32)
# ==================================================================
# NOTE (SUP-FINAL): food/supply is retired globally from canonical gameplay.
# FOOD_CONSUMPTION + get_food_cost() are legacy definitions kept on disk with
# zero active canonical callers (verified by the SUP-FINAL-10 audit gate).
# The MORALE_PENALTY table below stays ACTIVE in production.
const FOOD_CONSUMPTION: Dictionary = {
	MarchClass.GREEN: 1.0,   # Baseline daily operational consumption
	MarchClass.ORANGE: 2.0,  # Additional food expenditure (+1.0)
	MarchClass.RED: 4.0      # Substantial food expenditure (+3.0)
}

const MORALE_PENALTY: Dictionary = {
	MarchClass.GREEN: 0.0,   # 0 march morale penalty
	MarchClass.ORANGE: 5.0,  # Moderate morale reduction (-5)
	MarchClass.RED: 15.0     # Substantial morale reduction (-15)
}

# ==================================================================
# 5. ANIMATION & TIMING CONSTANTS (Section 26)
# ==================================================================
const SECONDS_PER_HEX: float = 0.12
const MIN_ANIMATION_DURATION: float = 0.10
const MAX_ANIMATION_DURATION: float = 1.80

# ==================================================================
# 6. STATIC HELPER METHODS
# ==================================================================
static func get_base_movement(unit_class: String) -> float:
	var key: String = unit_class.to_lower()
	if key == "spearmen":
		key = "spearman"
	elif key == "archers":
		key = "archer"
	elif key == "scouts":
		key = "scout"
	elif key == "conscripts":
		key = "conscript"
	var episode_mp: Dictionary = EpisodeRuntimeCls.rules().get("base_mp", {})
	var episode_key := "spear" if key == "spearman" else key
	return float(episode_mp.get(episode_key, CLASS_BASE_MOVEMENT.get(key, 2.0)))

static func get_terrain_cost(terrain_type: int, unit_class: String) -> float:
	var key: String = unit_class.to_lower()
	var rules: Dictionary = EpisodeRuntimeCls.rules()
	if key == "scout" or key == "scouts":
		var scout: Dictionary = rules.get("terrain_scout", {})
		if scout.has(str(terrain_type)): return float(scout[str(terrain_type)])
		if scout.has(terrain_type): return float(scout[terrain_type])
		return float(TERRAIN_COSTS_SCOUT.get(terrain_type, 1.0))
	var standard: Dictionary = rules.get("terrain_standard", {})
	if standard.has(str(terrain_type)): return float(standard[str(terrain_type)])
	if standard.has(terrain_type): return float(standard[terrain_type])
	return float(TERRAIN_COSTS_STANDARD.get(terrain_type, 1.0))

static func is_impassable(terrain_type: int) -> bool:
	return terrain_type == 8 or terrain_type == 9 or terrain_type == 10 or terrain_type >= 99

static func is_policy_allowed(policy: int, march_class: int) -> bool:
	match policy:
		MarchPolicy.GREEN_ONLY:
			return march_class == MarchClass.GREEN
		MarchPolicy.ORANGE_ALLOWED:
			return march_class == MarchClass.GREEN or march_class == MarchClass.ORANGE
		MarchPolicy.RED_ALLOWED:
			return true
	return false

static func get_blue_limit(base_mp: float) -> float:
	return base_mp * 1.0

static func get_red_limit(base_mp: float) -> float:
	return base_mp * 2.0

static func get_black_limit(base_mp: float) -> float:
	return base_mp * 2.2

static func get_max_additional_budget(spent: float, blue_limit: float, red_limit: float, black_limit: float, policy_tier: int) -> float:
	match policy_tier:
		MarchPolicy.GREEN_ONLY, MarchClass.GREEN:
			return maxf(0.0, blue_limit - spent)
		MarchPolicy.ORANGE_ALLOWED, MarchClass.ORANGE:
			return maxf(0.0, red_limit - spent)
		MarchPolicy.RED_ALLOWED, MarchClass.RED:
			return maxf(0.0, black_limit - spent)
	return maxf(0.0, blue_limit - spent)

static func classify_march_by_cumulative_cost(total_spent_including_step: float, blue_limit: float, red_limit: float, crosses_river: bool) -> int:
	if crosses_river:
		return MarchClass.RED
	if total_spent_including_step <= blue_limit + 0.001:
		return MarchClass.GREEN
	elif total_spent_including_step <= red_limit + 0.001:
		return MarchClass.ORANGE
	return MarchClass.RED

static func classify_march_for_cost(route_cost: float, base_mp: float, remaining_mp: float, crosses_river: bool) -> int:
	# Legacy compatibility wrapper
	if crosses_river:
		return MarchClass.RED
	var blue_lim: float = get_blue_limit(base_mp)
	var red_lim: float = get_red_limit(base_mp)
	var spent: float = maxf(0.0, blue_lim - remaining_mp)
	return classify_march_by_cumulative_cost(spent + route_cost, blue_lim, red_lim, crosses_river)

static func get_max_budget_for_tier(base_mp: float, remaining_mp: float, tier: int) -> float:
	# Legacy compatibility wrapper
	var blue_lim: float = get_blue_limit(base_mp)
	var red_lim: float = get_red_limit(base_mp)
	var black_lim: float = get_black_limit(base_mp)
	var spent: float = maxf(0.0, blue_lim - remaining_mp)
	return get_max_additional_budget(spent, blue_lim, red_lim, black_lim, tier)

# Legacy (SUP-FINAL): zero active callers - food consumption is retired.
static func get_food_cost(march_class: int) -> float:
	return float(FOOD_CONSUMPTION.get(march_class, 1.0))

static func get_morale_penalty(march_class: int) -> float:
	if not SandboxRulesCls.morale_rout_enabled():
		return 0.0
	return float(MORALE_PENALTY.get(march_class, 0.0))

static func get_march_label(march_class: int) -> String:
	match march_class:
		MarchClass.GREEN: return "BLUE (일반 행군)"
		MarchClass.ORANGE: return "RED (강행군)"
		MarchClass.RED: return "BLACK (급행군/도하)"
	return "UNKNOWN"

static func get_policy_label(policy: int) -> String:
	match policy:
		MarchPolicy.GREEN_ONLY: return "BLUE ONLY (일반만)"
		MarchPolicy.ORANGE_ALLOWED: return "RED ALLOWED (강행군 허용)"
		MarchPolicy.RED_ALLOWED: return "BLACK ALLOWED (극행군/도하 허용)"
	return "UNKNOWN"
