class_name UtilityProfiles
extends RefCounted

## GENERALIZED_UTILITY_AI_V0 — deterministic parameterized opponent profiles.
##
## 3 tiers x 4 styles = 12 profiles. Tiers differ in PLANNING DEPTH and risk
## calibration — never in deliberately crippled play (no forced WAITs, no
## blind spots, no stat handicaps):
##   BASIC ........ planning_depth 0 (V0 one-action scoring, generalized)
##   INTERMEDIATE . planning_depth 1 (V1 tactical + pair synergy, generalized)
##   ADVANCED ..... planning_depth 2 (V2 full-turn plan + intents, generalized)
## Styles differ in doctrine weights, all operating on the SAME current ruleset:
##   SPEARHEAD .... high aggression / objective commitment (assault doctrine)
##   BULWARK ...... high caution / reserve discipline (defensive doctrine)
##   OUTRIDER ..... high maneuver / concentration (flanking doctrine)
##   HARRIER ...... high counterattack / threat removal (opportunist doctrine)
##
## Determinism: profile base params are constants; per-match jitter is drawn
## from the bot's OWN seeded stream inside configure(), so same seed +
## same profile + same world => identical replay.

const TIERS := ["BASIC", "INTERMEDIATE", "ADVANCED"]
const STYLES := ["SPEARHEAD", "BULWARK", "OUTRIDER", "HARRIER"]

# archetype mapping preserves the useful V0/V1/V2 behavioral priors.
const STYLE_ARCHETYPE := {
	"SPEARHEAD": "AGGRESSIVE",
	"BULWARK": "DEFENSIVE",
	"OUTRIDER": "MANEUVER",
	"HARRIER": "OPPORTUNIST",
}

const PROFILE_IDS := [
	"GX_BASIC_SPEARHEAD", "GX_BASIC_BULWARK", "GX_BASIC_OUTRIDER", "GX_BASIC_HARRIER",
	"GX_INTER_SPEARHEAD", "GX_INTER_BULWARK", "GX_INTER_OUTRIDER", "GX_INTER_HARRIER",
	"GX_ADV_SPEARHEAD", "GX_ADV_BULWARK", "GX_ADV_OUTRIDER", "GX_ADV_HARRIER",
]

const DEPTH_BY_TIER := {"BASIC": 0, "INTERMEDIATE": 1, "ADVANCED": 2}

# Doctrine core per style: aggression, caution, concentration, maneuver,
# reserve_discipline, counterattack, objective_commitment. All in [0,1].
const DOCTRINE := {
	"SPEARHEAD": {"aggression": 0.85, "caution": 0.30, "concentration": 0.70,
		"maneuver": 0.45, "reserve_discipline": 0.35, "counterattack": 0.55, "objective_commitment": 0.90},
	"BULWARK": {"aggression": 0.30, "caution": 0.85, "concentration": 0.55,
		"maneuver": 0.30, "reserve_discipline": 0.90, "counterattack": 0.70, "objective_commitment": 0.45},
	"OUTRIDER": {"aggression": 0.60, "caution": 0.45, "concentration": 0.85,
		"maneuver": 0.90, "reserve_discipline": 0.50, "counterattack": 0.45, "objective_commitment": 0.65},
	"HARRIER": {"aggression": 0.65, "caution": 0.50, "concentration": 0.60,
		"maneuver": 0.60, "reserve_discipline": 0.55, "counterattack": 0.90, "objective_commitment": 0.60},
}

# Tier calibration: planning depth, temperature band, top-k width, V2 params.
# BASIC is broader (more exploratory) but stays inside the bounded rational
# set — weaker by planning, not by sabotage.
const TIER_CALIBRATION := {
	"BASIC": {"depth": 0, "temp_lo": 0.55, "temp_hi": 0.95, "top_k": 6,
		"sacrifice": 0.45, "tempo": 0.55, "conservatism": 0.55, "concentration": 0.55, "conversion": 0.55},
	"INTERMEDIATE": {"depth": 1, "temp_lo": 0.42, "temp_hi": 0.75, "top_k": 4,
		"sacrifice": 0.55, "tempo": 0.65, "conservatism": 0.60, "concentration": 0.65, "conversion": 0.65},
	"ADVANCED": {"depth": 2, "temp_lo": 0.38, "temp_hi": 0.65, "top_k": 5,
		"sacrifice": 0.60, "tempo": 0.70, "conservatism": 0.60, "concentration": 0.70, "conversion": 0.70},
}


static func is_profile_id(s: String) -> bool:
	return s.strip_edges().to_upper() in PROFILE_IDS


static func tier_of(profile_id: String) -> String:
	var p := profile_id.strip_edges().to_upper()
	if p.begins_with("GX_BASIC"):
		return "BASIC"
	if p.begins_with("GX_INTER"):
		return "INTERMEDIATE"
	return "ADVANCED"


static func style_of(profile_id: String) -> String:
	var p := profile_id.strip_edges().to_upper()
	for s in STYLES:
		if p.ends_with(s):
			return s
	return "SPEARHEAD"


static func archetype_of(profile_id: String) -> String:
	return str(STYLE_ARCHETYPE.get(style_of(profile_id), "AGGRESSIVE"))


static func doctrine_of(profile_id: String) -> Dictionary:
	return (DOCTRINE.get(style_of(profile_id), DOCTRINE["SPEARHEAD"]) as Dictionary).duplicate(true)


static func calibration_of(profile_id: String) -> Dictionary:
	return (TIER_CALIBRATION.get(tier_of(profile_id), TIER_CALIBRATION["BASIC"]) as Dictionary).duplicate(true)


static func describe(profile_id: String) -> Dictionary:
	var p := profile_id.strip_edges().to_upper()
	return {"profile_id": p, "tier": tier_of(p), "style": style_of(p),
		"archetype": archetype_of(p), "doctrine": doctrine_of(p),
		"planning_depth": int(DEPTH_BY_TIER.get(tier_of(p), 0))}
