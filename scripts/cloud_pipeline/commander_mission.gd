extends RefCounted
## Opt-in shared mission. Unconfigured running RL/replay retain their current rules.
static func enabled() -> bool:
	return OS.get_environment("WATCH_MISSION") == "remaining30_hq_guard"
static func share(default_share: float = 0.6) -> float:
	return 0.7 if enabled() else default_share
static func canonical_text(text: String) -> String:
	return text.replace("\r\n", "\n").replace("\r", "\n")
static func apply_prompt(head: String) -> String:
	if enabled():
		var start := head.find("WIN:")
		var end := head.find("Board:")
		if start >= 0 and end > start:
			head = head.left(start) + MISSION_TEXT + head.substr(end)
	if enabled() and not head.contains("Focus fire:"):
		head = canonical_text(head).replace("you can see.\n", "you can see.\n" + "Focus fire: prefer attacking the same BLUE unit with two or more of your units in the same turn, so it is destroyed\nbefore it can strike back again.\n")
	return canonical_text(head) if enabled() else head
const MISSION_TEXT := "WIN: reduce BLUE's surviving non-HQ units to 30% or less of their initial count (immediate; destroy at least 70%, rounded up). LOSE: 70% of your initial non-HQ units destroyed. Your HQ destroyed also means immediate defeat. Destroying the enemy HQ does not win this battle. If neither side has won by \"turn_limit\", you have\nfailed; \"turns_left\" = RED turns remaining, this one included.\n"
