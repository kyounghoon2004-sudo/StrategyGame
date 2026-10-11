extends RefCounted

## SYMMETRIC LOCAL-vs-LOCAL SANDBOX V1 — match result + reward contract.
##
## Terminal reward contract (RECORD ONLY — zero weight updates in V1):
##   WIN  = +5
##   LOSS = -3
##   DRAW / TIMEOUT = -2
##
## Decisive RED win:  red +5 / blue -3.
## Decisive BLUE win: blue +5 / red -3.
## Draw/timeout:      both -2.
##
## Terminal detection reads ONLY the authoritative shell flags
## (_battle_over/_battle_won/_battle_lost) plus the configurable
## sandbox turn cap. No model bypass: Godot owns the outcome.

const REWARD_WIN := 5
const REWARD_LOSS := -3
const REWARD_DRAW := -2

## Configurable sandbox turn cap. 0 = unlimited (no permanent production
## rule exists: the shell terminates on HQ destruction only; the
## mission_contract turn_limit is displayed but NOT enforced anywhere).
## Env SYMLOC_MAX_TURNS overrides; <= 0 disables.
static func max_turns() -> int:
	# Live get_environment read (has_environment misses in-process sets).
	var raw := OS.get_environment("SYMLOC_MAX_TURNS").strip_edges()
	if not raw.is_empty():
		return maxi(0, int(raw))
	return 0


## Outcome pair for a winner tag. Pure mapping (terminal fixture target).
static func outcomes_for_winner(winner: String) -> Dictionary:
	match winner.strip_edges().to_upper():
		"RED":
			return {"winner": "RED", "outcome_red": "WIN", "outcome_blue": "LOSS",
				"reward_red": REWARD_WIN, "reward_blue": REWARD_LOSS}
		"BLUE":
			return {"winner": "BLUE", "outcome_red": "LOSS", "outcome_blue": "WIN",
				"reward_red": REWARD_LOSS, "reward_blue": REWARD_WIN}
		_:
			return {"winner": "DRAW", "outcome_red": "DRAW", "outcome_blue": "DRAW",
				"reward_red": REWARD_DRAW, "reward_blue": REWARD_DRAW}


## Read the authoritative terminal state from the live shell.
## Returns {over, winner, reason, turn}. winner is "" when not over.
static func read_terminal(shell: Node, cap_turns: int = -1) -> Dictionary:
	var out := {"over": false, "winner": "", "reason": "", "turn": 0}
	if shell == null:
		return out
	var mgr: RefCounted = shell.get("unit_manager") as RefCounted
	if mgr != null:
		out["turn"] = int((mgr as RefCounted).call("get_current_turn"))
	var over := false
	if shell.has_method("_battle_over"):
		over = bool(shell.call("_battle_over"))
	if over:
		out["over"] = true
		# _battle_won  = RED HQ destroyed = BLUE victory (human perspective).
		# _battle_lost = BLUE HQ destroyed = RED victory.
		if bool(shell.get("_battle_lost")):
			out["winner"] = "RED"
			out["reason"] = "BLUE_HQ_DESTROYED"
		elif bool(shell.get("_battle_won")):
			out["winner"] = "BLUE"
			out["reason"] = "RED_HQ_DESTROYED"
		else:
			out["reason"] = "BATTLE_OVER_FLAGS_UNSET"
		return out
	var cap := cap_turns if cap_turns >= 0 else max_turns()
	if cap > 0 and int(out["turn"]) > cap:
		out["over"] = true
		out["winner"] = "DRAW"
		out["reason"] = "TURN_CAP_%d" % cap
	return out


## Full match metadata for future training (telemetry only in V1).
static func build_result(winner: String, reason: String, turns: int, meta: Dictionary) -> Dictionary:
	var res := outcomes_for_winner(winner)
	res["reason"] = reason
	res["turns"] = turns
	res["seed"] = str(meta.get("seed", ""))
	res["seed_source"] = str(meta.get("seed_source", ""))
	res["scenario"] = str(meta.get("scenario", ""))
	res["battle_id"] = str(meta.get("battle_id", ""))
	res["opening_rule"] = str(meta.get("opening_rule", ""))
	res["max_turns"] = int(meta.get("max_turns", 0))
	res["red_brain"] = str(meta.get("red_brain", ""))
	res["blue_brain"] = str(meta.get("blue_brain", ""))
	res["red_hands"] = str(meta.get("red_hands", "LAYA_LIVE"))
	res["blue_hands"] = str(meta.get("blue_hands", "LAYA_LIVE"))
	res["red_plan_revision"] = int(meta.get("red_plan_revision", 0))
	res["blue_plan_revision"] = int(meta.get("blue_plan_revision", 0))
	res["laya_worker"] = (meta.get("laya_worker", {}) as Dictionary).duplicate(true)
	res["training"] = "NONE"
	return res
