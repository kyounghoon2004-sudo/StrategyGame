class_name Step7CavalryDoctrine
extends RefCounted

## Cavalry pilot doctrine DATA (SB-CAVALRY-EVALUATOR design.md, sections 5-7).
## No logic here: base weights × profile multipliers + status gates + caps.
## Weight scale: 0.0 ignored / 0.5 minor / 1.0 baseline / 2.0 strong / 3.0 dominant.
## Badness features carry NEGATIVE base weights; all features normalized 0..1 first.

const VERSION := "cav_pilot_v2"

const PROFILES: Array = ["SAFE", "SUPPORTED", "BALANCED", "PRESSURE", "DEEP", "MAXIMUM"]

const FEATURES: Array = [
	"INTENT_PROGRESS", "MOVEMENT_USE", "OPEN_MANEUVER_SPACE", "MOBILITY_FUTURE",
	"FLANK_VALUE", "MATCHUP_OPPORTUNITY", "ARCHER_ACCESS", "COUNTER_RISK",
	"THREAT_EXPOSURE", "FORMATION_SUPPORT", "ISOLATION_RISK", "RETREAT_SAFETY",
	"TERRAIN_MOBILITY", "ROUTE_COST", "ROUTE_EXPOSURE", "OBJECTIVE_VALUE",
	"PRESSURE_VALUE", "UNCERTAINTY_RISK",
	"CLUSTER_ALIGNMENT", "CLUSTER_COHESION",
]

const BADNESS: Array = [
	"COUNTER_RISK", "THREAT_EXPOSURE", "ISOLATION_RISK",
	"ROUTE_COST", "ROUTE_EXPOSURE", "UNCERTAINTY_RISK",
]

const BASE_W := {
	"INTENT_PROGRESS": 1.5, "MOVEMENT_USE": 0.5, "OPEN_MANEUVER_SPACE": 1.0,
	"MOBILITY_FUTURE": 1.5, "FLANK_VALUE": 1.0, "MATCHUP_OPPORTUNITY": 1.0,
	"ARCHER_ACCESS": 1.0, "COUNTER_RISK": -2.0, "THREAT_EXPOSURE": -1.2,
	"FORMATION_SUPPORT": 1.0, "ISOLATION_RISK": -1.2, "RETREAT_SAFETY": 1.2,
	"TERRAIN_MOBILITY": 1.0, "ROUTE_COST": -0.5, "ROUTE_EXPOSURE": -0.5,
	"OBJECTIVE_VALUE": 0.8, "PRESSURE_VALUE": 0.8, "UNCERTAINTY_RISK": -0.5,
	"CLUSTER_ALIGNMENT": 1.0, "CLUSTER_COHESION": 0.8,
}

# Sparse multipliers; absent = 1.0.
# Cluster pilot: cohesion profiles value the tactical band; DEEP/MAXIMUM accept drift.
const MULT := {
	"SAFE": {"COUNTER_RISK": 1.5, "THREAT_EXPOSURE": 1.5, "RETREAT_SAFETY": 1.5,
		"MOBILITY_FUTURE": 1.3, "TERRAIN_MOBILITY": 1.3, "PRESSURE_VALUE": 0.4,
		"ARCHER_ACCESS": 0.5, "ISOLATION_RISK": 1.3,
		"CLUSTER_ALIGNMENT": 1.2, "CLUSTER_COHESION": 1.2},
	"SUPPORTED": {"FORMATION_SUPPORT": 2.5, "ISOLATION_RISK": 1.8, "RETREAT_SAFETY": 1.3,
		"INTENT_PROGRESS": 1.2, "PRESSURE_VALUE": 0.5, "FLANK_VALUE": 0.7,
		"CLUSTER_COHESION": 2.0, "CLUSTER_ALIGNMENT": 1.3},
	"BALANCED": {},
	"PRESSURE": {"PRESSURE_VALUE": 2.5, "MATCHUP_OPPORTUNITY": 1.8, "ARCHER_ACCESS": 2.0,
		"FLANK_VALUE": 1.5, "OBJECTIVE_VALUE": 1.5, "INTENT_PROGRESS": 1.2,
		"THREAT_EXPOSURE": 0.5, "ISOLATION_RISK": 0.5, "ROUTE_EXPOSURE": 0.5,
		"COUNTER_RISK": 1.0, "RETREAT_SAFETY": 0.7,
		"CLUSTER_ALIGNMENT": 0.8, "CLUSTER_COHESION": 0.7},
	"DEEP": {"INTENT_PROGRESS": 2.0, "FLANK_VALUE": 2.0, "ARCHER_ACCESS": 1.5,
		"PRESSURE_VALUE": 1.5, "MOBILITY_FUTURE": 1.5, "OBJECTIVE_VALUE": 1.3,
		"THREAT_EXPOSURE": 0.6, "ISOLATION_RISK": 0.6, "COUNTER_RISK": 1.0,
		"RETREAT_SAFETY": 0.8, "FORMATION_SUPPORT": 0.5,
		"CLUSTER_ALIGNMENT": 0.7, "CLUSTER_COHESION": 0.7},
	"MAXIMUM": {"INTENT_PROGRESS": 3.0, "MOVEMENT_USE": 2.0, "THREAT_EXPOSURE": 0.3,
		"COUNTER_RISK": 0.5, "ISOLATION_RISK": 0.5, "TERRAIN_MOBILITY": 0.5,
		"RETREAT_SAFETY": 0.5, "ROUTE_COST": 0.5,
		"CLUSTER_ALIGNMENT": 0.5, "CLUSTER_COHESION": 0.5},
}

const PRIMARY := {
	"SAFE": "RETREAT_SAFETY", "SUPPORTED": "FORMATION_SUPPORT", "BALANCED": "INTENT_PROGRESS",
	"PRESSURE": "PRESSURE_VALUE", "DEEP": "FLANK_VALUE", "MAXIMUM": "INTENT_PROGRESS",
}

# Intent-floor: fraction of best legal INTENT_PROGRESS a pick must reach (else UNAVAILABLE).
const MIN_INTENT := {
	"SAFE": 0.25, "SUPPORTED": 0.2, "BALANCED": 0.15,
	"PRESSURE": 0.2, "DEEP": 0.35, "MAXIMUM": 0.3,
}

# Correlation caps (§4): combined magnitudes beyond these are scaled back in the scorer.
const CAP_COUNTER_THREAT := 3.0
const CAP_SUPPORT_ISOLATION := 2.5
const CAP_MATCHUP_ARCHER := 2.5

# DEEP hard vetoes (DEEP = high-risk, never suicidal).
const DEEP_MIN_MOBILITY := 0.15
const DEEP_MIN_RETREAT := 0.1
const DEEP_MIN_INTENT_FRAC := 0.5
const DEEP_MAX_COUNTER := 0.85


static func final_weight(feature: String, profile: String) -> float:
	var base: float = float(BASE_W.get(feature, 0.0))
	var pm: Dictionary = MULT.get(profile, {}) as Dictionary
	return base * float(pm.get(feature, 1.0))


static func is_badness(feature: String) -> bool:
	return feature in BADNESS
