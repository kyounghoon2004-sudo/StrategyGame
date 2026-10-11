class_name Step7DevMode
extends RefCounted

## Single authoritative PLAYER vs DEV UI policy (player/advisor milestone).
##
## PLAYER MODE (default): normal battlefield UI + Advisor window only.
## DEV MODE: additionally exposes the deterministic DEV surfaces
## (DEV ACTIONS panel, TACTICAL CLUSTERS browser, CAVALRY raw evaluator,
## feature/weight/scope diagnostics). DEV tools are never deleted — they
## stay intact behind this flag for future doctrine tuning.
##
## Sources (highest priority first):
##   1. Runtime override via set_dev_mode() / toggle() (e.g. F9 in battle).
##   2. Command line: --step7-dev / --dev  vs  --step7-player.
##   3. ProjectSettings "strategy_game/dev_mode" (default false).
##
## Do NOT scatter OS.is_debug_build() checks through UI scripts — every
## DEV-visibility decision must consult is_dev_mode().

const SETTING := "strategy_game/dev_mode"

static var _override := -1 # -1 = unset, 0 = player, 1 = dev


static func is_dev_mode() -> bool:
	if _override == 1:
		return true
	if _override == 0:
		return false
	var args := OS.get_cmdline_args()
	if "--step7-dev" in args or "--dev" in args:
		return true
	if "--step7-player" in args:
		return false
	return bool(ProjectSettings.get_setting(SETTING, false))


static func set_dev_mode(v: bool) -> void:
	_override = 1 if v else 0
	ProjectSettings.set_setting(SETTING, v)


static func toggle() -> bool:
	set_dev_mode(not is_dev_mode())
	return is_dev_mode()


static func mode_name() -> String:
	return "DEV" if is_dev_mode() else "PLAYER"
