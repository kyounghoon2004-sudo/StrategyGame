class_name Step6Config
extends RefCounted

## STEP-06 Battle Decision Layer — centralized prototype tunables (§39).
## Human will tune later; keep every major Step-6 value here, not inline.

# ------------------------------------------------------------------
# Central stockpile & local carried supply (§6-§8)
# ------------------------------------------------------------------
const CENTRAL_STOCKPILE_START: float = 2400.0
const FOOD_PER_TROOP_PER_TURN: float = 0.01
const LOCAL_SUPPLY_TURNS: float = 5.0          # canonical carried-ration buffer (STEP-06R1 §17)
const HQ_SUPPLY_TURNS: float = 6.0             # HQ carries a deeper buffer
const FORCED_MARCH_EXTRA_TURNS: float = 1.0    # surcharge when unguarded+has_moved

# ------------------------------------------------------------------
# STEP-06R2: Fixed Supply Coverage Budgets & Mobile Supply Hubs (§6-§16)
# ------------------------------------------------------------------
const COVERAGE_HQ: float = 12.0                # HQ coverage budget (Dijkstra cost reach)
const COVERAGE_CITY: float = 12.0              # City/Capital coverage budget
const COVERAGE_FORTRESS: float = 9.0           # Fortress coverage budget
const LOGISTICS_RADIUS_STRONGHOLD: float = 9.0   # Default stronghold coverage budget
const COVERAGE_DEPOT: float = 7.0              # Depot/Base coverage budget
const COVERAGE_VILLAGE: float = 5.0            # Village coverage budget

const SUPPLY_UNIT_BASE_MP: float = 8.0         # Mobile supply unit speed (substantially faster than Scout's 4.0)
const SUPPLY_UNIT_SERVICE_RADIUS: int = 2      # Axial hex service radius along travelled path
const SUPPLY_UNIT_CARGO_CAPACITY: float = 400.0 # Food capacity carried by mobile hub
const SUPPLY_UNIT_CARGO_START: float = 400.0

const MAP_MODE_BATTLE: int = 0
const MAP_MODE_LOGISTICS: int = 1

# ------------------------------------------------------------------
# STEP-06R3: Supply Day Risk Tiers & Urgency Colors (§7-§8)
# ------------------------------------------------------------------
const SUPPLY_DAYS_HEALTHY: float = 3.0
const SUPPLY_DAYS_WARNING: float = 1.5
const SUPPLY_DAYS_CRITICAL: float = 0.0

const COLOR_SUPPLY_HEALTHY: Color = Color(0.38, 0.92, 0.48, 1.0) # Safe Green (Civ VI Lens style)
const COLOR_SUPPLY_WARNING: Color = Color(1.0, 0.78, 0.20, 1.0) # Amber / Warning
const COLOR_SUPPLY_CRITICAL: Color = Color(1.0, 0.32, 0.22, 1.0) # Red / Critical
const COLOR_SUPPLY_EMPTY: Color = Color(0.85, 0.15, 0.15, 1.0) # Deep Crimson / Starving

# ------------------------------------------------------------------
# STEP-06R3: Settler-Lens Multi-Tier Reach Ratios (§10-§12)
# ------------------------------------------------------------------
const REACH_TIER_STRONG: float = 0.45    # <= 45% budget: Bright Gold (Strong/Secure)
const REACH_TIER_MODERATE: float = 0.75  # <= 75% budget: Light Amber (Reachable)
const REACH_TIER_FRINGE: float = 1.00    # <= 100% budget: Muted Gold/Gray (Weak Reach)

# ------------------------------------------------------------------
# STEP-06R3: Trader Route Strategies & Vision (§17-§26)
# ------------------------------------------------------------------
const ROUTE_STRATEGY_FASTEST: String = "fastest"
const ROUTE_STRATEGY_ROAD: String = "road"
const ROUTE_STRATEGY_SAFE: String = "safe"
const SUPPLY_ROUTE_VISION_RADIUS: int = 2

# ------------------------------------------------------------------
# Deprecated Convoy & Forward Node Legacy values (preserved for compat)
# ------------------------------------------------------------------
const CONVOY_CAPACITY: float = 90.0
const CONVOY_POLICY: int = 1                   # Step3Config MarchPolicy.ORANGE_ALLOWED
const NODE_CATCHMENT_HEXES: int = 6            # replenishment reach (axial, provisional)
const NODE_ROUTE_CHECK_HEXES: int = 9          # route_ok probe reach (axial, provisional)
const NODE_STOCK_CAP: float = 150.0
const DEPOT_START_STOCK: float = 60.0

# ------------------------------------------------------------------
# Supply states (§15): 0=원활 1=불안정 2=부족 3=단절
# ------------------------------------------------------------------
const STATE_SMOOTH: int = 0
const STATE_UNSTABLE: int = 1
const STATE_SHORT: int = 2
const STATE_CUT: int = 3
const STATE_LABELS: Array[String] = ["원활", "불안정", "부족", "단절"]
const SMOOTH_TURNS: float = 2.0
const UNSTABLE_TURNS: float = 1.0

# ------------------------------------------------------------------
# Morale (§17-§21)
# ------------------------------------------------------------------
const REST_MORALE_RESTORE: float = 12.0
const HUNGER_MORALE_FIRST: float = -6.0
const HUNGER_MORALE_ONGOING: float = -10.0
const HUNGER_FATIGUE: float = 10.0
const SUPPLIED_FATIGUE_RECOVERY: float = 15.0
const HQ_NEAR_DIST: float = 3.0                # full command presence
const HQ_FAR_DIST: float = 18.0                # beyond: max distance penalty
const HQ_NEAR_BONUS: float = 2.0
const HQ_FAR_PENALTY: float = -4.0
const ENCIRCLE_ADJACENT: int = 4
const ENCIRCLE_PENALTY: float = -5.0
const WITNESS_ROUT_RADIUS: int = 4
const WITNESS_ROUT_SHOCK: float = -4.0         # per nearby allied rout (cap below)
const WITNESS_ROUT_CAP: float = -8.0
const WITNESS_DESTROY_SHOCK: float = -6.0      # per nearby allied destruction
const WITNESS_DESTROY_CAP: float = -12.0
const DRIFT_MIN: float = -15.0                 # per-turn drift clamp
const DRIFT_MAX: float = 8.0

# ------------------------------------------------------------------
# Fatigue (§16 cascade, §21 REST clears)
# ------------------------------------------------------------------
const FATIGUE_GREEN: float = 4.0
const FATIGUE_ORANGE: float = 18.0
const FATIGUE_RED: float = 32.0
const FATIGUE_EXHAUSTED: float = 60.0

# ------------------------------------------------------------------
# Combat effectiveness when degraded (§16, §20)
# ------------------------------------------------------------------
const STARVING_EFFECT_MULT: float = 0.85       # local supply <= 0
const EXHAUSTED_EFFECT_MULT: float = 0.90      # fatigue >= FATIGUE_EXHAUSTED
const ROUTED_DEFENSELESS_MULT: float = 1.25    # attacker bonus vs routed defender

# ------------------------------------------------------------------
# Rout & rally (§24-§25)
# ------------------------------------------------------------------
const ROUT_MORALE_LINE: float = 20.0
const ROUT_BASE_P: float = 0.25
const ROUT_MORALE_SCALE: float = 0.02          # +p per point below line
const ROUT_HUNGRY_P: float = 0.10
const ROUT_ENCIRCLED_P: float = 0.10
const ROUT_P_CAP: float = 0.80
const RALLY_MIN_TURNS: int = 2
const RALLY_NEAR_HQ: int = 6
const RALLY_BASE_P: float = 0.50
const RALLY_MORALE_FLOOR: float = 25.0

static func supply_state_label(st: int) -> String:
	var i: int = clampi(st, 0, 3)
	return STATE_LABELS[i]

static func buffer_turns(supply: float, max_troops: int) -> float:
	var need: float = float(maxi(1, max_troops)) * FOOD_PER_TROOP_PER_TURN
	if need <= 0.0:
		return 99.0
	return supply / need

static func supply_days_color(turns: float) -> Color:
	if turns >= SUPPLY_DAYS_HEALTHY:
		return COLOR_SUPPLY_HEALTHY
	elif turns >= SUPPLY_DAYS_WARNING:
		return COLOR_SUPPLY_WARNING
	elif turns > SUPPLY_DAYS_CRITICAL:
		return COLOR_SUPPLY_CRITICAL
	return COLOR_SUPPLY_EMPTY

static func supply_days_urgency_label(turns: float) -> String:
	if turns >= SUPPLY_DAYS_HEALTHY:
		return "안정"
	elif turns >= SUPPLY_DAYS_WARNING:
		return "경고"
	elif turns > SUPPLY_DAYS_CRITICAL:
		return "위기"
	return "고갈"
