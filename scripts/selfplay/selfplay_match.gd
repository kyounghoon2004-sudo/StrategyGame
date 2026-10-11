extends RefCounted

## HEADLESS SELF-PLAY V1 — terminal controls + progress/stalemate tracker.
##
## Training/self-play controls only; production Human-vs-Cloud rules are
## untouched (the shell still terminates on HQ destruction only).
##
## Terminal reasons emitted by this module:
##   Godot-owned ........ RED_HQ_DESTROYED / BLUE_HQ_DESTROYED /
##                        BATTLE_OVER_FLAGS_UNSET (via SymLocMatch)
##   Self-play timeout .. TURN_LIMIT_TIMEOUT (max_turns exceeded)
##   Self-play stalemate  STALEMATE_TIMEOUT (no_progress_window turns
##                        without an authoritative progress event)
##
## Rewards (canonical, RECORD ONLY in Stage 2 — no training):
##   WIN +5 / LOSS -3 / DRAW-or-TIMEOUT -2 (both sides).
##
## Progress is defined ONLY from authoritative Godot state:
##   - total soldiers of either side decreased (damage dealt)
##   - alive unit count of either side decreased (unit destroyed)
##   - HQ soldiers of either side decreased (HQ damage)
## "Unit moved / attacked" is deliberately NOT progress (reward-gameable).

const MatchCls = preload("res://scripts/symloc/symloc_match.gd")

const REASON_TURN_LIMIT := "TURN_LIMIT_TIMEOUT"
const REASON_STALEMATE := "STALEMATE_TIMEOUT"


## Explicit run configuration. SELFPLAY_MAX_TURNS wins; falls back to the
## sandbox SYMLOC_MAX_TURNS; <= 0 disables. The runner always sets both.
static func max_turns() -> int:
	var raw := OS.get_environment("SELFPLAY_MAX_TURNS").strip_edges()
	if not raw.is_empty():
		return maxi(0, int(raw))
	return MatchCls.max_turns()


## Stalemate window in full turns. 0/absent = disabled. Runner sets it.
static func no_progress_window() -> int:
	var raw := OS.get_environment("SELFPLAY_NO_PROGRESS_TURNS").strip_edges()
	if raw.is_empty():
		return 0
	return maxi(0, int(raw))


static func outcomes_for_winner(winner: String) -> Dictionary:
	return MatchCls.outcomes_for_winner(winner)


## Read the authoritative terminal state plus the self-play turn cap.
## Returns {over, winner, reason, turn}. winner is "" when not over.
static func read_terminal(shell: Node) -> Dictionary:
	var term := MatchCls.read_terminal(shell, max_turns())
	if bool(term.get("over", false)) and str(term.get("reason", "")).begins_with("TURN_CAP_"):
		term["reason"] = REASON_TURN_LIMIT
	return term


## Authoritative progress snapshot from live Godot truth.
## {turn, red_soldiers, blue_soldiers, red_units, blue_units,
##  red_hq_hp, blue_hq_hp, red_hq_alive, blue_hq_alive}
static func progress_snapshot(shell: Node) -> Dictionary:
	var snap := {"turn": 0, "red_soldiers": 0, "blue_soldiers": 0,
		"red_units": 0, "blue_units": 0,
		"red_hq_hp": 0, "blue_hq_hp": 0,
		"red_hq_alive": false, "blue_hq_alive": false}
	if shell == null:
		return snap
	var mgr: RefCounted = shell.get("unit_manager") as RefCounted
	if mgr == null:
		return snap
	snap["turn"] = int((mgr as RefCounted).call("get_current_turn"))
	var rows: Array = (mgr as RefCounted).call("get_all_units")
	for u_val in rows:
		if not u_val is Dictionary:
			continue
		var u: Dictionary = u_val
		if int(u.get("soldier_count", 0)) <= 0:
			continue
		var fac := str(u.get("faction", ""))
		var n := int(u.get("soldier_count", 0))
		var is_hq := str(u.get("class", "")) == "hq"
		if fac == "red":
			snap["red_soldiers"] = int(snap["red_soldiers"]) + n
			snap["red_units"] = int(snap["red_units"]) + 1
			if is_hq:
				snap["red_hq_hp"] = int(snap["red_hq_hp"]) + n
				snap["red_hq_alive"] = true
		elif fac == "blue":
			snap["blue_soldiers"] = int(snap["blue_soldiers"]) + n
			snap["blue_units"] = int(snap["blue_units"]) + 1
			if is_hq:
				snap["blue_hq_hp"] = int(snap["blue_hq_hp"]) + n
				snap["blue_hq_alive"] = true
	return snap


## Pure progress diff between two boundary snapshots.
## Returns {progress: bool, events: [{kind, side, detail}]}.
static func diff_progress(prev: Dictionary, cur: Dictionary) -> Dictionary:
	var events: Array = []
	if prev.is_empty():
		return {"progress": false, "events": events}
	for side in ["red", "blue"]:
		var ps := int(prev.get(side + "_soldiers", 0))
		var cs := int(cur.get(side + "_soldiers", 0))
		if cs < ps:
			events.append({"kind": "DAMAGE_DEALT", "side": side.to_upper(),
				"detail": "soldiers %d -> %d" % [ps, cs]})
		var pu := int(prev.get(side + "_units", 0))
		var cu := int(cur.get(side + "_units", 0))
		if cu < pu:
			events.append({"kind": "UNIT_DESTROYED", "side": side.to_upper(),
				"detail": "units %d -> %d" % [pu, cu]})
		var ph := int(prev.get(side + "_hq_hp", 0))
		var ch := int(cur.get(side + "_hq_hp", 0))
		if ch < ph:
			events.append({"kind": "HQ_DAMAGE", "side": side.to_upper(),
				"detail": "hq_hp %d -> %d" % [ph, ch]})
	return {"progress": not events.is_empty(), "events": events}
