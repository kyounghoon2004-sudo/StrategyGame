class_name OpenJevRules
extends RefCounted

## OPENJEV LIVE V0 — single authoritative source for runtime rule strings.
##
## If game rules change later, edit THIS file (or its callers' authoritative
## sources): OpenJev consumes the new strings at runtime with no retraining.
## Nothing here is baked into model weights. The worker passes these through
## verbatim into every /score premise.


static func runtime_rules() -> Array:
	return [
		"PRIMARY: WIN THE BATTLE. Destroy the enemy (BLUE) HQ to win immediately.",
		"TERMINAL: OWN (RED) HQ DESTROYED = IMMEDIATE DEFEAT. ENEMY (BLUE) HQ DESTROYED = IMMEDIATE VICTORY. The battle ends the moment either HQ falls; no further actions exist after that.",
		"SECONDARY: AMONG COMPARABLY WINNING OPTIONS, MINIMIZE UNNECESSARY FRIENDLY (RED) LOSSES. Force preservation never overrides actually winning.",
		"MISSION: FOLLOW THE COMMANDER MISSION, TARGET, AND DOCTRINE given in context, UNLESS an immediate terminal victory or the prevention of an immediate terminal defeat overrides it.",
		"LEGALITY: CHOOSE ONLY FROM THE PROVIDED LEGAL ACTIONS. Every listed candidate is currently legal; anything not listed is illegal or unavailable.",
	]


## Short machine tag for logs/evidence (rules version tracking).
static func rules_version() -> String:
	return "openjev-runtime-rules-v1"
