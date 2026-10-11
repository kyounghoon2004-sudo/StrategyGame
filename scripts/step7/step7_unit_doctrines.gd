class_name Step7UnitDoctrines
extends RefCounted

## Data-driven tactical doctrine registry (all-unit generalization).
##
## ONE evaluator framework (Step7CavalryEvaluator, kept by name for scene /
## probe compatibility) scores every class through THESE tables: base
## weights x profile multipliers + status gates + caps + vetoes. No per-class
## evaluator copies. Cavalry reuses Step7CavalryDoctrine consts by reference
## (human-passed baseline, never rewritten here).
##
## Weight scale: 0.0 ignored / 0.5 minor / 1.0 baseline / 2.0 strong / 3.0
## dominant. Badness features carry NEGATIVE base weights; features are
## normalized 0..1 by the extractor first.
##
## Class-specific features (computed for every class, weighted per doctrine):
##   INFORMATION_GAIN - lawful recon value: stale-contact refresh proximity
##     + novel-ground distance + escape geometry. No hidden state, no fog
##     reads beyond BLUE-authorized contacts and own positions.
##   SCREEN_PROTECTION - friendly screening geometry + distance from known
##     enemy cavalry access. Own positions + authorized contacts only.
##   CAVALRY_DENIAL - intercept value vs KNOWN enemy cavalry (spearmen want
##     closeness to block; everyone else fears it via COUNTER_RISK/THREAT).
##
## Feature keys DOUBLE as the LLM's evidence vocabulary (top strengths /
## concerns per option) and DEV diagnostics — never renamed per class.

const CavDoctrineScript = preload("res://scripts/step7/step7_cavalry_doctrine.gd")

const VERSION := "doctrine_registry_v1"

const PROFILES: Array = ["SAFE", "SUPPORTED", "BALANCED", "PRESSURE", "DEEP", "MAXIMUM"]

const COMBAT_CLASSES: Array = ["CAVALRY", "INFANTRY", "ARCHER", "SPEARMAN",
	"SCOUT", "SIEGE", "CONSCRIPT"]

## HQ / SUPPLY never enter combat scoring. Explicit policy, not an accident.
const SUPPORT_CLASSES := ["HQ", "SUPPLY"]

const EXTRA_FEATURES := ["INFORMATION_GAIN", "SCREEN_PROTECTION", "CAVALRY_DENIAL"]

const CAP_COUNTER_THREAT := 3.0
const CAP_SUPPORT_ISOLATION := 2.5
const CAP_MATCHUP_ARCHER := 2.5

# Contact-class groups for counter-risk (lowercased, plural-tolerant).
const COUNTER_SETS := {
	"CAVALRY": ["spear", "spearman", "spearmen"],
	"INFANTRY": [],
	"ARCHER": ["cavalry"],
	"SPEARMAN": ["archer", "archers"],
	"SCOUT": ["cavalry"],
	"SIEGE": ["cavalry"],
	"CONSCRIPT": ["cavalry"],
}

# Opportunity-access modes (see extractor):
#   cavalry  - matchup>1 within 3 + archer-access subchannel (legacy semantic)
#   matchup  - matchup>1 within 2 (sustainable frontline access)
#   ranged   - known enemies inside own firing influence (archers)
#   intercept- known enemy cavalry inside intercept envelope (spearmen)
#   siege    - known enemies inside assault range 2 (siege)
#   none     - no access seeking (scouts want information, conscripts support)
const ACCESS_MODES := {
	"CAVALRY": "cavalry", "INFANTRY": "matchup", "ARCHER": "ranged",
	"SPEARMAN": "intercept", "SCOUT": "none", "SIEGE": "siege",
	"CONSCRIPT": "matchup",
}

const BASE_W := {
	"INFANTRY": {
		"INTENT_PROGRESS": 1.6, "MOVEMENT_USE": 0.5, "OPEN_MANEUVER_SPACE": 0.4,
		"MOBILITY_FUTURE": 0.6, "FLANK_VALUE": 0.5, "MATCHUP_OPPORTUNITY": 0.8,
		"ARCHER_ACCESS": 0.6, "COUNTER_RISK": -1.2, "THREAT_EXPOSURE": -1.2,
		"FORMATION_SUPPORT": 1.8, "ISOLATION_RISK": -1.8, "RETREAT_SAFETY": 1.0,
		"TERRAIN_MOBILITY": 0.8, "ROUTE_COST": -0.8, "ROUTE_EXPOSURE": -0.6,
		"OBJECTIVE_VALUE": 1.4, "PRESSURE_VALUE": 1.2, "UNCERTAINTY_RISK": -0.5,
		"CLUSTER_ALIGNMENT": 1.4, "CLUSTER_COHESION": 1.6,
		"INFORMATION_GAIN": 0.2, "SCREEN_PROTECTION": 0.8, "CAVALRY_DENIAL": 0.0,
	},
	"ARCHER": {
		"INTENT_PROGRESS": 1.2, "MOVEMENT_USE": 0.4, "OPEN_MANEUVER_SPACE": 0.5,
		"MOBILITY_FUTURE": 0.8, "FLANK_VALUE": 0.4, "MATCHUP_OPPORTUNITY": 0.8,
		"ARCHER_ACCESS": 1.6, "COUNTER_RISK": -2.2, "THREAT_EXPOSURE": -1.6,
		"FORMATION_SUPPORT": 1.4, "ISOLATION_RISK": -1.8, "RETREAT_SAFETY": 1.4,
		"TERRAIN_MOBILITY": 0.8, "ROUTE_COST": -0.6, "ROUTE_EXPOSURE": -0.8,
		"OBJECTIVE_VALUE": 0.8, "PRESSURE_VALUE": 0.8, "UNCERTAINTY_RISK": -0.6,
		"CLUSTER_ALIGNMENT": 1.0, "CLUSTER_COHESION": 1.2,
		"INFORMATION_GAIN": 0.2, "SCREEN_PROTECTION": 1.8, "CAVALRY_DENIAL": 0.0,
	},
	"SPEARMAN": {
		"INTENT_PROGRESS": 1.4, "MOVEMENT_USE": 0.5, "OPEN_MANEUVER_SPACE": 0.5,
		"MOBILITY_FUTURE": 0.5, "FLANK_VALUE": 0.6, "MATCHUP_OPPORTUNITY": 0.8,
		"ARCHER_ACCESS": 0.5, "COUNTER_RISK": -1.8, "THREAT_EXPOSURE": -1.2,
		"FORMATION_SUPPORT": 1.8, "ISOLATION_RISK": -1.6, "RETREAT_SAFETY": 1.0,
		"TERRAIN_MOBILITY": 0.8, "ROUTE_COST": -0.7, "ROUTE_EXPOSURE": -0.6,
		"OBJECTIVE_VALUE": 1.2, "PRESSURE_VALUE": 1.0, "UNCERTAINTY_RISK": -0.5,
		"CLUSTER_ALIGNMENT": 1.4, "CLUSTER_COHESION": 1.6,
		"INFORMATION_GAIN": 0.2, "SCREEN_PROTECTION": 0.8, "CAVALRY_DENIAL": 1.8,
	},
	"SCOUT": {
		"INTENT_PROGRESS": 1.2, "MOVEMENT_USE": 0.6, "OPEN_MANEUVER_SPACE": 1.0,
		"MOBILITY_FUTURE": 1.6, "FLANK_VALUE": 0.6, "MATCHUP_OPPORTUNITY": 0.0,
		"ARCHER_ACCESS": 0.0, "COUNTER_RISK": -1.6, "THREAT_EXPOSURE": -1.4,
		"FORMATION_SUPPORT": 0.8, "ISOLATION_RISK": -1.0, "RETREAT_SAFETY": 1.6,
		"TERRAIN_MOBILITY": 1.2, "ROUTE_COST": -0.4, "ROUTE_EXPOSURE": -0.8,
		"OBJECTIVE_VALUE": 0.6, "PRESSURE_VALUE": 0.6, "UNCERTAINTY_RISK": -0.4,
		"CLUSTER_ALIGNMENT": 0.6, "CLUSTER_COHESION": 0.6,
		"INFORMATION_GAIN": 2.2, "SCREEN_PROTECTION": 0.4, "CAVALRY_DENIAL": 0.0,
	},
	"SIEGE": {
		"INTENT_PROGRESS": 1.2, "MOVEMENT_USE": 0.4, "OPEN_MANEUVER_SPACE": 0.4,
		"MOBILITY_FUTURE": 0.6, "FLANK_VALUE": 0.3, "MATCHUP_OPPORTUNITY": 0.6,
		"ARCHER_ACCESS": 0.8, "COUNTER_RISK": -2.0, "THREAT_EXPOSURE": -1.6,
		"FORMATION_SUPPORT": 1.6, "ISOLATION_RISK": -2.0, "RETREAT_SAFETY": 1.2,
		"TERRAIN_MOBILITY": 1.4, "ROUTE_COST": -1.2, "ROUTE_EXPOSURE": -0.8,
		"OBJECTIVE_VALUE": 1.2, "PRESSURE_VALUE": 0.6, "UNCERTAINTY_RISK": -0.6,
		"CLUSTER_ALIGNMENT": 1.0, "CLUSTER_COHESION": 1.2,
		"INFORMATION_GAIN": 0.1, "SCREEN_PROTECTION": 1.6, "CAVALRY_DENIAL": 0.0,
	},
	"CONSCRIPT": {
		"INTENT_PROGRESS": 1.2, "MOVEMENT_USE": 0.4, "OPEN_MANEUVER_SPACE": 0.4,
		"MOBILITY_FUTURE": 0.5, "FLANK_VALUE": 0.3, "MATCHUP_OPPORTUNITY": 0.4,
		"ARCHER_ACCESS": 0.3, "COUNTER_RISK": -1.8, "THREAT_EXPOSURE": -1.6,
		"FORMATION_SUPPORT": 2.2, "ISOLATION_RISK": -2.2, "RETREAT_SAFETY": 1.6,
		"TERRAIN_MOBILITY": 0.8, "ROUTE_COST": -0.8, "ROUTE_EXPOSURE": -0.8,
		"OBJECTIVE_VALUE": 1.0, "PRESSURE_VALUE": 0.5, "UNCERTAINTY_RISK": -0.7,
		"CLUSTER_ALIGNMENT": 1.2, "CLUSTER_COHESION": 2.0,
		"INFORMATION_GAIN": 0.1, "SCREEN_PROTECTION": 0.8, "CAVALRY_DENIAL": 0.0,
	},
}

# Sparse per-profile multipliers (absent = 1.0). Same grammar as cavalry.
const MULT := {
	"INFANTRY": {
		"SAFE": {"COUNTER_RISK": 1.4, "THREAT_EXPOSURE": 1.4, "RETREAT_SAFETY": 1.4,
			"FORMATION_SUPPORT": 1.4, "ISOLATION_RISK": 1.4, "PRESSURE_VALUE": 0.5,
			"CLUSTER_COHESION": 1.3},
		"SUPPORTED": {"FORMATION_SUPPORT": 2.5, "ISOLATION_RISK": 1.8,
			"CLUSTER_COHESION": 2.0, "CLUSTER_ALIGNMENT": 1.3, "PRESSURE_VALUE": 0.6},
		"BALANCED": {},
		"PRESSURE": {"PRESSURE_VALUE": 2.2, "OBJECTIVE_VALUE": 1.6, "MATCHUP_OPPORTUNITY": 1.6,
			"INTENT_PROGRESS": 1.2, "THREAT_EXPOSURE": 0.6, "ISOLATION_RISK": 0.7},
		"DEEP": {"INTENT_PROGRESS": 1.8, "OBJECTIVE_VALUE": 1.3, "PRESSURE_VALUE": 1.3,
			"THREAT_EXPOSURE": 0.7, "ISOLATION_RISK": 1.2, "FORMATION_SUPPORT": 0.6},
		"MAXIMUM": {"INTENT_PROGRESS": 2.6, "MOVEMENT_USE": 1.8, "THREAT_EXPOSURE": 0.4,
			"ISOLATION_RISK": 0.6, "ROUTE_COST": 0.5, "CLUSTER_COHESION": 0.5},
	},
	"ARCHER": {
		"SAFE": {"COUNTER_RISK": 1.6, "THREAT_EXPOSURE": 1.5, "RETREAT_SAFETY": 1.5,
			"SCREEN_PROTECTION": 1.5, "ISOLATION_RISK": 1.4, "PRESSURE_VALUE": 0.4,
			"ARCHER_ACCESS": 0.7},
		"SUPPORTED": {"FORMATION_SUPPORT": 2.2, "SCREEN_PROTECTION": 1.8,
			"ISOLATION_RISK": 1.6, "CLUSTER_COHESION": 1.6, "PRESSURE_VALUE": 0.6},
		"BALANCED": {},
		"PRESSURE": {"PRESSURE_VALUE": 2.0, "ARCHER_ACCESS": 2.2, "OBJECTIVE_VALUE": 1.4,
			"INTENT_PROGRESS": 1.2, "THREAT_EXPOSURE": 0.6, "COUNTER_RISK": 1.2},
		"DEEP": {"INTENT_PROGRESS": 1.8, "ARCHER_ACCESS": 1.6, "PRESSURE_VALUE": 1.3,
			"THREAT_EXPOSURE": 0.7, "ISOLATION_RISK": 1.2, "SCREEN_PROTECTION": 0.7},
		"MAXIMUM": {"INTENT_PROGRESS": 2.4, "MOVEMENT_USE": 1.8, "THREAT_EXPOSURE": 0.4,
			"COUNTER_RISK": 0.6, "SCREEN_PROTECTION": 0.6, "ROUTE_COST": 0.5},
	},
	"SPEARMAN": {
		"SAFE": {"COUNTER_RISK": 1.5, "THREAT_EXPOSURE": 1.4, "RETREAT_SAFETY": 1.4,
			"FORMATION_SUPPORT": 1.4, "CAVALRY_DENIAL": 0.7, "PRESSURE_VALUE": 0.5},
		"SUPPORTED": {"FORMATION_SUPPORT": 2.4, "CAVALRY_DENIAL": 1.4,
			"ISOLATION_RISK": 1.6, "CLUSTER_COHESION": 1.8, "PRESSURE_VALUE": 0.6},
		"BALANCED": {},
		"PRESSURE": {"PRESSURE_VALUE": 2.2, "CAVALRY_DENIAL": 2.0, "MATCHUP_OPPORTUNITY": 1.6,
			"OBJECTIVE_VALUE": 1.4, "THREAT_EXPOSURE": 0.6, "ISOLATION_RISK": 0.7},
		"DEEP": {"INTENT_PROGRESS": 1.7, "CAVALRY_DENIAL": 1.5, "PRESSURE_VALUE": 1.3,
			"THREAT_EXPOSURE": 0.7, "ISOLATION_RISK": 1.2, "FORMATION_SUPPORT": 0.6},
		"MAXIMUM": {"INTENT_PROGRESS": 2.4, "MOVEMENT_USE": 1.8, "THREAT_EXPOSURE": 0.4,
			"COUNTER_RISK": 0.6, "CAVALRY_DENIAL": 0.7, "ROUTE_COST": 0.5},
	},
	"SCOUT": {
		"SAFE": {"RETREAT_SAFETY": 1.6, "THREAT_EXPOSURE": 1.5, "COUNTER_RISK": 1.4,
			"MOBILITY_FUTURE": 1.3, "INFORMATION_GAIN": 0.7, "PRESSURE_VALUE": 0.4},
		"SUPPORTED": {"FORMATION_SUPPORT": 2.0, "CLUSTER_COHESION": 1.6,
			"INFORMATION_GAIN": 1.2, "ISOLATION_RISK": 1.4, "RETREAT_SAFETY": 1.2},
		"BALANCED": {},
		"PRESSURE": {"PRESSURE_VALUE": 2.0, "INFORMATION_GAIN": 1.6,
			"INTENT_PROGRESS": 1.3, "THREAT_EXPOSURE": 0.6, "MOBILITY_FUTURE": 1.2},
		"DEEP": {"INFORMATION_GAIN": 2.2, "INTENT_PROGRESS": 1.8, "MOBILITY_FUTURE": 1.5,
			"RETREAT_SAFETY": 1.1, "THREAT_EXPOSURE": 0.7, "ISOLATION_RISK": 0.8,
			"FORMATION_SUPPORT": 0.5},
		"MAXIMUM": {"INFORMATION_GAIN": 2.0, "INTENT_PROGRESS": 2.2, "MOVEMENT_USE": 1.8,
			"THREAT_EXPOSURE": 0.5, "MOBILITY_FUTURE": 1.2, "ROUTE_COST": 0.5},
	},
	"SIEGE": {
		"SAFE": {"COUNTER_RISK": 1.5, "THREAT_EXPOSURE": 1.5, "RETREAT_SAFETY": 1.4,
			"SCREEN_PROTECTION": 1.5, "TERRAIN_MOBILITY": 1.4, "ROUTE_COST": 1.4,
			"ISOLATION_RISK": 1.4, "PRESSURE_VALUE": 0.4},
		"SUPPORTED": {"FORMATION_SUPPORT": 2.2, "SCREEN_PROTECTION": 1.8,
			"ISOLATION_RISK": 1.6, "CLUSTER_COHESION": 1.5, "TERRAIN_MOBILITY": 1.2},
		"BALANCED": {},
		"PRESSURE": {"PRESSURE_VALUE": 1.8, "ARCHER_ACCESS": 1.8, "OBJECTIVE_VALUE": 1.5,
			"INTENT_PROGRESS": 1.2, "THREAT_EXPOSURE": 0.6, "SCREEN_PROTECTION": 1.1},
		"DEEP": {"INTENT_PROGRESS": 1.6, "OBJECTIVE_VALUE": 1.3, "TERRAIN_MOBILITY": 1.2,
			"THREAT_EXPOSURE": 0.7, "ISOLATION_RISK": 1.3, "SCREEN_PROTECTION": 0.8},
		"MAXIMUM": {"INTENT_PROGRESS": 2.2, "MOVEMENT_USE": 1.6, "TERRAIN_MOBILITY": 1.3,
			"THREAT_EXPOSURE": 0.5, "ROUTE_COST": 0.7, "SCREEN_PROTECTION": 0.7},
	},
	"CONSCRIPT": {
		"SAFE": {"RETREAT_SAFETY": 1.6, "FORMATION_SUPPORT": 1.6, "ISOLATION_RISK": 1.6,
			"THREAT_EXPOSURE": 1.5, "COUNTER_RISK": 1.4, "CLUSTER_COHESION": 1.5,
			"PRESSURE_VALUE": 0.3, "MATCHUP_OPPORTUNITY": 0.5},
		"SUPPORTED": {"FORMATION_SUPPORT": 2.6, "CLUSTER_COHESION": 2.2,
			"ISOLATION_RISK": 1.8, "RETREAT_SAFETY": 1.3, "PRESSURE_VALUE": 0.4},
		"BALANCED": {},
		"PRESSURE": {"PRESSURE_VALUE": 1.6, "OBJECTIVE_VALUE": 1.4, "MATCHUP_OPPORTUNITY": 1.2,
			"INTENT_PROGRESS": 1.1, "THREAT_EXPOSURE": 0.7, "ISOLATION_RISK": 0.9},
		"DEEP": {"INTENT_PROGRESS": 1.5, "OBJECTIVE_VALUE": 1.2,
			"THREAT_EXPOSURE": 0.8, "ISOLATION_RISK": 1.4, "FORMATION_SUPPORT": 0.7},
		"MAXIMUM": {"INTENT_PROGRESS": 2.0, "MOVEMENT_USE": 1.6, "THREAT_EXPOSURE": 0.5,
			"FORMATION_SUPPORT": 0.7, "CLUSTER_COHESION": 0.7, "ROUTE_COST": 0.6},
	},
}

const PRIMARY := {
	"INFANTRY": {"SAFE": "RETREAT_SAFETY", "SUPPORTED": "FORMATION_SUPPORT",
		"BALANCED": "INTENT_PROGRESS", "PRESSURE": "PRESSURE_VALUE",
		"DEEP": "INTENT_PROGRESS", "MAXIMUM": "INTENT_PROGRESS"},
	"ARCHER": {"SAFE": "RETREAT_SAFETY", "SUPPORTED": "FORMATION_SUPPORT",
		"BALANCED": "INTENT_PROGRESS", "PRESSURE": "PRESSURE_VALUE",
		"DEEP": "INTENT_PROGRESS", "MAXIMUM": "INTENT_PROGRESS"},
	"SPEARMAN": {"SAFE": "RETREAT_SAFETY", "SUPPORTED": "FORMATION_SUPPORT",
		"BALANCED": "INTENT_PROGRESS", "PRESSURE": "PRESSURE_VALUE",
		"DEEP": "CAVALRY_DENIAL", "MAXIMUM": "INTENT_PROGRESS"},
	"SCOUT": {"SAFE": "RETREAT_SAFETY", "SUPPORTED": "FORMATION_SUPPORT",
		"BALANCED": "INTENT_PROGRESS", "PRESSURE": "PRESSURE_VALUE",
		"DEEP": "INFORMATION_GAIN", "MAXIMUM": "INTENT_PROGRESS"},
	"SIEGE": {"SAFE": "RETREAT_SAFETY", "SUPPORTED": "FORMATION_SUPPORT",
		"BALANCED": "INTENT_PROGRESS", "PRESSURE": "PRESSURE_VALUE",
		"DEEP": "INTENT_PROGRESS", "MAXIMUM": "INTENT_PROGRESS"},
	"CONSCRIPT": {"SAFE": "RETREAT_SAFETY", "SUPPORTED": "FORMATION_SUPPORT",
		"BALANCED": "INTENT_PROGRESS", "PRESSURE": "PRESSURE_VALUE",
		"DEEP": "INTENT_PROGRESS", "MAXIMUM": "INTENT_PROGRESS"},
}

const MIN_INTENT := {
	"INFANTRY": {"SAFE": 0.25, "SUPPORTED": 0.2, "BALANCED": 0.15,
		"PRESSURE": 0.2, "DEEP": 0.3, "MAXIMUM": 0.3},
	"ARCHER": {"SAFE": 0.2, "SUPPORTED": 0.2, "BALANCED": 0.15,
		"PRESSURE": 0.2, "DEEP": 0.3, "MAXIMUM": 0.3},
	"SPEARMAN": {"SAFE": 0.25, "SUPPORTED": 0.2, "BALANCED": 0.15,
		"PRESSURE": 0.2, "DEEP": 0.3, "MAXIMUM": 0.3},
	"SCOUT": {"SAFE": 0.15, "SUPPORTED": 0.15, "BALANCED": 0.1,
		"PRESSURE": 0.15, "DEEP": 0.2, "MAXIMUM": 0.2},
	"SIEGE": {"SAFE": 0.2, "SUPPORTED": 0.15, "BALANCED": 0.1,
		"PRESSURE": 0.2, "DEEP": 0.3, "MAXIMUM": 0.25},
	"CONSCRIPT": {"SAFE": 0.2, "SUPPORTED": 0.15, "BALANCED": 0.1,
		"PRESSURE": 0.25, "DEEP": 0.35, "MAXIMUM": 0.3},
}

# DEEP hard vetoes per class (never suicidal, class-calibrated).
const DEEP_VETO := {
	"INFANTRY": {"min_mobility": 0.1, "min_retreat": 0.1, "max_counter": 0.9},
	"ARCHER": {"min_mobility": 0.1, "min_retreat": 0.15, "max_counter": 0.85},
	"SPEARMAN": {"min_mobility": 0.1, "min_retreat": 0.1, "max_counter": 0.9},
	"SCOUT": {"min_mobility": 0.1, "min_retreat": 0.05, "max_counter": 0.95},
	"SIEGE": {"min_mobility": 0.2, "min_retreat": 0.2, "max_counter": 0.8},
	"CONSCRIPT": {"min_mobility": 0.1, "min_retreat": 0.15, "max_counter": 0.85},
}

const HQ_POLICY := "지휘부는 채팅 기동 대상이 아닙니다. 지휘부 보존이 최우선이며, 위치 변경은 기존 지휘 절차를 따릅니다."
const SUPPLY_POLICY := "보급대는 전투 기동 대상이 아닙니다. 보급 연결과 도로 접근을 유지하십시오. 대기가 필요하면 '보급대 대기'로 명령하십시오."


static var _cache := {}


static func is_doctrine_class(cls: String) -> bool:
	return cls.strip_edges().to_upper() in COMBAT_CLASSES


static func needs_policy(cls: String) -> bool:
	return cls.strip_edges().to_upper() in SUPPORT_CLASSES


static func policy_text(cls: String) -> String:
	match cls.strip_edges().to_upper():
		"HQ":
			return HQ_POLICY
		"SUPPLY":
			return SUPPLY_POLICY
	return "이 편제는 채팅 기동 대상이 아닙니다."


## Full doctrine record for a class. Cavalry references the human-passed
## baseline consts (no copy, no drift). Others are registry-owned tables.
static func for_class(cls: String) -> Dictionary:
	var c := cls.strip_edges().to_upper()
	if c in _cache:
		return (_cache[c] as Dictionary).duplicate(true)
	var d := {}
	if c == "CAVALRY":
		d = {
			"version": "cav:" + str(CavDoctrineScript.VERSION),
			"features": (CavDoctrineScript.FEATURES as Array).duplicate(),
			"base_w": (CavDoctrineScript.BASE_W as Dictionary).duplicate(true),
			"mult": (CavDoctrineScript.MULT as Dictionary).duplicate(true),
			"primary": (CavDoctrineScript.PRIMARY as Dictionary).duplicate(true),
			"min_intent": (CavDoctrineScript.MIN_INTENT as Dictionary).duplicate(true),
			"caps": {"counter_threat": CavDoctrineScript.CAP_COUNTER_THREAT,
				"support_isolation": CavDoctrineScript.CAP_SUPPORT_ISOLATION,
				"matchup_archer": CavDoctrineScript.CAP_MATCHUP_ARCHER},
			"deep": {"min_mobility": CavDoctrineScript.DEEP_MIN_MOBILITY,
				"min_retreat": CavDoctrineScript.DEEP_MIN_RETREAT,
				"intent_frac": CavDoctrineScript.DEEP_MIN_INTENT_FRAC,
				"max_counter": CavDoctrineScript.DEEP_MAX_COUNTER},
		}
	elif c in COMBAT_CLASSES:
		var feats: Array = (CavDoctrineScript.FEATURES as Array).duplicate()
		for x in EXTRA_FEATURES:
			if not x in feats:
				feats.append(x)
		d = {
			"version": VERSION + ":" + c.to_lower(),
			"features": feats,
			"base_w": ((BASE_W.get(c, {}) as Dictionary).duplicate(true)),
			"mult": ((MULT.get(c, {}) as Dictionary).duplicate(true)),
			"primary": ((PRIMARY.get(c, {}) as Dictionary).duplicate(true)),
			"min_intent": ((MIN_INTENT.get(c, {}) as Dictionary).duplicate(true)),
			"caps": {"counter_threat": CAP_COUNTER_THREAT,
				"support_isolation": CAP_SUPPORT_ISOLATION,
				"matchup_archer": CAP_MATCHUP_ARCHER},
			"deep": ((DEEP_VETO.get(c, {}) as Dictionary).duplicate(true)),
		}
	else:
		return {}
	_cache[c] = d.duplicate(true)
	return d.duplicate(true)


static func final_weight(d: Dictionary, feature: String, profile: String) -> float:
	var base: float = float((d.get("base_w", {}) as Dictionary).get(feature, 0.0))
	var pm: Dictionary = (d.get("mult", {}) as Dictionary).get(profile, {})
	return base * float(pm.get(feature, 1.0))


static func counter_classes(cls: String) -> Array:
	return (COUNTER_SETS.get(cls.strip_edges().to_upper(), []) as Array).duplicate()


static func access_mode(cls: String) -> String:
	return str(ACCESS_MODES.get(cls.strip_edges().to_upper(), "matchup"))


## DEV/prompt summary: what each profile means for a class (game terms).
static func profile_line(cls: String, profile: String) -> String:
	var table := {
		"CAVALRY": {"PRESSURE": "flank access, exposed rear, mobility-preserving pressure",
			"DEEP": "outer-wing maneuver with escape routes"},
		"INFANTRY": {"PRESSURE": "sustainable frontline advance, line-connected pressure",
			"DEEP": "limited penetration that keeps the front connected"},
		"ARCHER": {"PRESSURE": "firing influence under screen protection",
			"DEEP": "forward firing position with retreat space"},
		"SPEARMAN": {"PRESSURE": "denial advance against known cavalry corridors",
			"DEEP": "intercept depth without losing the protective role"},
		"SCOUT": {"PRESSURE": "aggressive contact and screening pressure",
			"DEEP": "deep information penetration with multiple exits"},
		"SIEGE": {"PRESSURE": "useful forward assault/firing position on good ground",
			"DEEP": "forward relocation that keeps screen and road access"},
		"CONSCRIPT": {"PRESSURE": "supported line-density pressure, never heroic",
			"DEEP": "shallow follow-up that preserves cohesion"},
	}
	var row: Dictionary = table.get(cls.strip_edges().to_upper(), {})
	return str(row.get(profile.strip_edges().to_upper(),
		"standard %s realization" % profile.strip_edges().to_lower()))
