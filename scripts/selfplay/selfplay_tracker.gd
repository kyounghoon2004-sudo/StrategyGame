extends RefCounted

## HEADLESS SELF-PLAY V1 — stalemate tracker (turn-boundary progress).
##
## Noted with a progress snapshot on every poll; evaluated ONLY when the
## authoritative turn number advances. turns_without_progress counts full
## turns with zero authoritative progress events (damage / destroyed /
## HQ damage as diffed by SelfplayMatch). Reaching the configured window
## means STALEMATE_TIMEOUT (DRAW, -2/-2).

const MatchLib = preload("res://scripts/selfplay/selfplay_match.gd")

var window := 0
var armed := false
var last_turn := 0
var turns_without_progress := 0
var boundary_snapshot := {}
var progress_events_total := 0
var log: Array = []


func configure(window_turns: int, first_snapshot: Dictionary) -> void:
	window = maxi(0, window_turns)
	boundary_snapshot = (first_snapshot as Dictionary).duplicate(true)
	last_turn = int(first_snapshot.get("turn", 0))
	turns_without_progress = 0
	progress_events_total = 0
	armed = true
	log = []


## Note one poll snapshot. Returns {turn_advanced, progress, events,
## turns_without_progress, stalemate}.
func note(snap: Dictionary) -> Dictionary:
	var out := {"turn_advanced": false, "progress": false, "events": [],
		"turns_without_progress": turns_without_progress, "stalemate": false}
	if not armed:
		return out
	var turn := int((snap as Dictionary).get("turn", 0))
	if turn == last_turn:
		return out
	out["turn_advanced"] = true
	var diff := MatchLib.diff_progress(boundary_snapshot, snap)
	var evs: Array = diff.get("events", [])
	out["progress"] = bool(diff.get("progress", false))
	out["events"] = evs
	if bool(diff.get("progress", false)):
		turns_without_progress = 0
		progress_events_total += evs.size()
	else:
		turns_without_progress += 1
	boundary_snapshot = (snap as Dictionary).duplicate(true)
	last_turn = turn
	log.append({"turn": turn, "progress": bool(diff.get("progress", false)),
		"events": evs.size(), "quiet_turns": turns_without_progress})
	if log.size() > 64:
		log.pop_front()
	out["turns_without_progress"] = turns_without_progress
	out["stalemate"] = window > 0 and turns_without_progress >= window
	return out


func view() -> Dictionary:
	return {"window": window, "last_turn": last_turn,
		"turns_without_progress": turns_without_progress,
		"progress_events_total": progress_events_total, "log": log.duplicate(true)}
