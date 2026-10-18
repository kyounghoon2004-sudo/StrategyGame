class_name SandboxRules
extends RefCounted

## ============================================================================
## CANONICAL DEV / STEP-0 CONTRACT AUTHORITY (single source of truth)
## ============================================================================
## The Cloud General DEV research environment (Step 0 flat sandbox) is a
## RUNTIME MODE, not a one-shot scene mutation. Every gameplay subsystem that
## could otherwise re-activate a production rule must consult this contract
## instead of re-deriving the mode from local flags.
##
## Contract (while active):
##   terrain effects      OFF      (flat neutral ground only)
##   obstacles/forts       OFF      (no strongholds, no field fortifications)
##   supply / food         OFF      (retired globally - canonical production AND the sandbox)
##   fog / stale contacts  OFF      (full information, chess-like visibility)
##   morale / rout         OFF      (morale cannot degrade, rout cannot trigger,
##                                   no morale combat modifier, no morale penalty)
##   roster                CONTROLLED (10v10 default, configurable)
##   control               STRUCTURED (no map-click dependency)
##
## The mode flag lives in ProjectSettings at runtime (never persisted), the same
## convention as Step7DevMode — so any script, test, or headless process can
## assert the contract without importing this class.
##
## Ownership: the battlefield shell sets the flag on every boot from its own
## `is_step0_sandbox` (scene export / --step0-sandbox / scene-name fallback),
## so Production and DEV can coexist in one process and neither inherits the
## other's rules.

const SETTING := "strategy_game/sandbox_mode"
const ROUT_SETTING := "strategy_game/rout_allowed"


static func set_active(v: bool) -> void:
	ProjectSettings.set_setting(SETTING, v)


static func is_active() -> bool:
	return bool(ProjectSettings.get_setting(SETTING, false))


static func set_rout_allowed(v: bool) -> void:
	ProjectSettings.set_setting(ROUT_SETTING, v)


static func is_rout_allowed() -> bool:
	return bool(ProjectSettings.get_setting(ROUT_SETTING, true))


# --- canonical rule queries (consumers ask these, never the raw flag) -------

static func terrain_effects_enabled() -> bool:
	return not is_active()


static func obstacles_enabled() -> bool:
	return not is_active()


static func supply_enabled() -> bool:
	# Supply is retired globally (canonical production AND the DEV sandbox) - SUP-FINAL.
	return false


static func food_enabled() -> bool:
	# Food consumption is retired globally (canonical production AND the DEV sandbox) - SUP-FINAL.
	return false


static func fog_enabled() -> bool:
	return not is_active()


static func stale_contacts_enabled() -> bool:
	return not is_active()


static func morale_rout_enabled() -> bool:
	return not is_active()


static func full_information() -> bool:
	return is_active()


static func default_roster() -> Dictionary:
	return {"hq": 1, "infantry": 2, "spearman": 2, "archer": 2, "cavalry": 2, "scout": 1}


## Machine-readable invariant snapshot for audit runners (DEV_* names).
static func invariants() -> Dictionary:
	return {
		"DEV_SUPPLY_ENABLED": supply_enabled(),
		"DEV_FOOD_ENABLED": food_enabled(),
		"DEV_TERRAIN_EFFECTS_ENABLED": terrain_effects_enabled(),
		"DEV_OBSTACLES_ENABLED": obstacles_enabled(),
		"DEV_FOG_ENABLED": fog_enabled(),
		"DEV_STALE_CONTACTS_ENABLED": stale_contacts_enabled(),
		"DEV_MORALE_ROUT_ENABLED": morale_rout_enabled(),
		"DEV_FULL_INFORMATION": full_information(),
		"SANDBOX_ACTIVE": is_active(),
	}
