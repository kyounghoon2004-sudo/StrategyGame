class_name Cloud2PlanMemory
extends RefCounted

## CLOUD-GENERAL STEP 2 — Compact tactical continuity (advisory only).
##
## Holds ONE compact structured plan across RED turns: objective, current
## intent, last result, reconsider condition. No conversation history, no
## observation copies, no game truth. Godot observation remains truth; this
## memory only seeds the next packet's "current_plan" hint.
##
## Every field is length-capped so a verbose model cannot bloat packets.

const MAX_FIELD := 280


var objective := ""
var current_intent := ""
var last_result := ""
var reconsider_if := ""
var turn := 0
var has_plan := false


static func _clip(v: Variant) -> String:
	var s := str(v).strip_edges()
	if s.length() > MAX_FIELD:
		return s.left(MAX_FIELD)
	return s


func update_from_plan(plan: Dictionary, for_turn: int) -> void:
	objective = _clip(plan.get("objective", ""))
	current_intent = _clip(plan.get("intent", ""))
	reconsider_if = _clip(plan.get("reconsider_if", ""))
	turn = for_turn
	has_plan = not (objective.is_empty() and current_intent.is_empty())


func note_result(text: String) -> void:
	last_result = _clip(text)


func reset() -> void:
	objective = ""
	current_intent = ""
	last_result = ""
	reconsider_if = ""
	turn = 0
	has_plan = false


func to_packet() -> Dictionary:
	return {
		"objective": objective,
		"current_intent": current_intent,
		"last_result": last_result,
		"reconsider_if": reconsider_if,
		"turn": turn,
		"has_plan": has_plan,
	}


func describe() -> String:
	if not has_plan and last_result.is_empty():
		return "(no plan yet)"
	return "objective=%s | intent=%s | last=%s | reconsider_if=%s" % [
		objective if not objective.is_empty() else "-",
		current_intent if not current_intent.is_empty() else "-",
		last_result if not last_result.is_empty() else "-",
		reconsider_if if not reconsider_if.is_empty() else "-",
	]
