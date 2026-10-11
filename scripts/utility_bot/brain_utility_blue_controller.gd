extends "res://scripts/cloud2/cloud2_turn_controller.gd"

## The autonomous dev match has no human decision panel. Preserve the real
## Brain failure and finish the current BLUE phase with the existing HOLD ALL
## command, then allow a fresh INITIAL request at the next BLUE phase.
func _wait_for_decision() -> String:
	print("[BrainUtility] BLUE Brain needs a decision; holding this phase after the recorded failure.")
	return "hold"


func rearm_failed_initial_for_dev() -> bool:
	if str(victory_initial_status().get("state", "")) != "FAILED":
		return false
	_rearm_initial_next_phase()
	print("[BrainUtility] BLUE INITIAL will retry at the next planning opportunity.")
	return true
