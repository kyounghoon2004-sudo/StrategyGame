extends "res://scripts/utility_bot/live_legal_enumerator.gd"

## GX MISSIONS v1 — the live per-unit legal enumerator + BUILD_BASE (HQ only, own hex, not after moving).
## Legality is owned by MissionRules.can_build_base (the authority); this only offers and re-checks it.
## Every other action is the unchanged base enumeration.

var mission_rules: Node = null


func _append_unit_candidates(cands: Array, u: Dictionary) -> void:
	super._append_unit_candidates(cands, u)
	_append_build_base(cands, u)


func _append_build_base(cands: Array, u: Dictionary) -> void:
	if mission_rules == null or bool(u.get("action_ended", false)):
		return
	var uid := str(u.get("id", ""))
	var chk: Dictionary = mission_rules.call("can_build_base", uid)
	if bool(chk.get("ok", false)):
		var hex: Vector2i = chk["hex"]
		cands.append({"candidate_id": "BUILD_BASE|%s|%d,%d" % [uid, hex.x, hex.y], "unit_id": uid,
			"action_type": "BUILD_BASE", "hex": [hex.x, hex.y]})


func revalidate(cand: Dictionary) -> Dictionary:
	if str(cand.get("action_type", "")) != "BUILD_BASE":
		return super.revalidate(cand)
	if not is_ready():
		return {"ok": false, "code": "ENUMERATOR_NOT_READY"}
	if bool(_is_terminal.call()) or mission_rules == null:
		return {"ok": false, "code": "BATTLE_ALREADY_TERMINAL"}
	var chk: Dictionary = mission_rules.call("can_build_base", str(cand.get("unit_id", "")))
	return {"ok": bool(chk.get("ok", false)), "code": str(chk.get("code", ""))}
