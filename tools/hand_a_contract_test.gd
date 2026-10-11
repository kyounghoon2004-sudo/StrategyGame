extends SceneTree

## BRAIN→HAND A contract (frozen v1) — minimal wiring test (tool-only).
## BRAIN_CONTRACT_MODE=unalloc_v1: prompt build, parse -> validate -> adopt
## of one frozen-contract INITIAL plan, the 3 unallocated missions at the
## Hand A seam, no M00 coverage, and two rejections. Prints HA_* lines.

const VR = preload("res://scripts/cloud2/cloud2_victory_response.gd")
const AuthoringCls = preload("res://scripts/cloud2/cloud2_victory_authoring.gd")
const ManagerCls = preload("res://scripts/cloud2/cloud2_mission_manager.gd")

const ROSTER := ["R_ARC_1", "R_CAV_1", "R_CAV_2", "R_HQ_1", "R_INF_1", "R_INF_2", "R_SCT_1", "R_SPE_1"]

var fails := 0


func _init() -> void:
	call_deferred("_run")


func check(name: String, ok: bool, detail: Variant = "") -> void:
	print("HA_CHECK %s %s %s" % ["PASS" if ok else "FAIL", name, str(detail)])
	if not ok:
		fails += 1


static func example() -> Dictionary:
	return {"objective": "Fix BLUE's center, turn its north flank, and destroy BLUE HQ while preserving RED HQ.",
		"end_state": "BLUE HQ destroyed.", "cadence": 4, "doctrine": [0.6, 0.5, 0.6, 0.6, 0.7, 0.2],
		"phases": [
			{"id": "P1", "name": "FIX AND TURN", "purpose": "Pin the enemy main body and open the north flank.",
				"intent": "Center holds contact while a mobile force swings north; a reserve stays uncommitted.",
				"missions": [
					{"task": "FIX", "area": "CENTER", "intent": "Engage and pin the enemy main body; deny a breakthrough.", "priority": "high", "vs": "INFANTRY", "preserve": true},
					{"task": "FLANK", "area": "NORTH", "intent": "Move a mobile force around the north flank to threaten the enemy rear.", "priority": "high", "limits": ["Avoid prolonged spearman contact."]},
					{"task": "RESERVE", "area": "CENTER", "intent": "Stay uncommitted behind the center; reinforce whichever effort stalls.", "priority": "medium", "preserve": true}],
				"win": [{"when": "TURNS_ELAPSED", "turns": 4, "since": 1}], "lose": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.4}],
				"abort": ["HQ_THREATENED"], "next": "P2", "on_fail": "HOLD"},
			{"id": "P2", "name": "COLLAPSE", "purpose": "Convert the flank into an HQ strike.", "intent": "All efforts converge on the enemy HQ.",
				"missions": [
					{"task": "ATTACK", "area": "CENTER", "intent": "Break the pinned line.", "priority": "high"},
					{"task": "ATTACK", "area": "NORTH", "intent": "Drive from the flank onto the enemy HQ.", "priority": "high", "target": "B_HQ_1"},
					{"task": "RESERVE", "area": "CENTER", "intent": "Screen own HQ; commit only to finish.", "priority": "low", "preserve": true}],
				"next": "END", "on_fail": "HOLD"}],
		"abort": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.25}],
		"branches": [{"id": "B1", "if": "BLUE cavalry commits north", "when": {"when": "ENEMY_CLASS_DETECTED", "class": "CAVALRY", "region": "NORTH"}, "then": "REQUEST_REVIEW"}],
		"hypotheses": [{"h": "BLUE_CENTER_MASS", "conf": 0.6, "ev": ["Most BLUE infantry observed in CENTER."]}]}


func _run() -> void:
	OS.set_environment(AuthoringCls.CONTRACT_MODE_ENV, AuthoringCls.CONTRACT_UNALLOC)
	check("mode_on", AuthoringCls.unalloc_mode())
	# prompt
	var pr := VR.initial_prompt_for("red")
	var prb := VR.initial_prompt_for("blue")
	var rv := VR.review_prompt_for("red")
	check("prompt_red_clean", not pr.contains("ANCHOR_MISSING") and not pr.contains("R_INF_1") and not pr.contains("\"groups\"")
		and not pr.contains("\"reserve\"") and not pr.contains("\"release\"") and not pr.contains("\"roles\"") and pr.contains(VR.UNALLOC_RULE),
		"chars=%d" % pr.length())
	check("prompt_blue_clean", not prb.contains("ANCHOR_MISSING") and not prb.contains("B_INF_1") and prb.contains(VR.UNALLOC_RULE))
	check("prompt_review_clean", not rv.contains("ANCHOR_MISSING") and rv.contains(VR.UNALLOC_RULE))
	# parse + validate
	var ctx := {"turn": 1, "snapshot_id": "", "roster": ROSTER}
	var parsed: Dictionary = VR.parse_initial(JSON.stringify(example()), ctx)
	check("parse_validate_ok", bool(parsed.get("ok", false)), "%s %s" % [str(parsed.get("code", "")), str(parsed.get("detail", ""))])
	if not bool(parsed.get("ok", false)):
		_done()
		return
	var p1: Dictionary = ((parsed.get("plan", {}) as Dictionary).get("phases", []) as Array)[0]
	var p1_units := 0
	for m in (p1.get("missions", []) as Array):
		p1_units += ((m as Dictionary).get("assigned_units", []) as Array).size()
	check("p1_three_unallocated", (p1.get("missions", []) as Array).size() == 3 and p1_units == 0)
	# adopt
	var mgr: RefCounted = ManagerCls.new()
	var ap: Dictionary = mgr.vp_apply_initial(parsed.get("plan", {}), 1, "HA_T1_RED", "HA_BATTLE", "general")
	check("adopt_ok", bool(ap.get("ok", false)), ap)
	# M00 coverage must NOT fire in this mode
	var obs := {"friendly_units": []}
	for uid in ROSTER:
		(obs["friendly_units"] as Array).append({"unit_id": uid, "status": "ready"})
	mgr.call("_cover_unassigned", obs, 1)
	var m00 := false
	for m in ((mgr.call("get_plan") as Dictionary).get("missions", []) as Array):
		if str((m as Dictionary).get("mission_id", "")) == "M00":
			m00 = true
	check("no_m00_coverage", not m00)
	# the seam
	var req: Dictionary = mgr.hand_a_pending_allocation()
	check("seam_awaiting", str(req.get("state", "")) == ManagerCls.HAND_A_AWAITING and (req.get("missions", []) as Array).size() == 3,
		str(req.get("state", "")))
	print("HA_SEAM %s" % JSON.stringify(req))
	# rejections
	var bad1 := example()
	((bad1["phases"] as Array)[0]["missions"] as Array)[0]["units"] = ["R_INF_1"]
	var r1: Dictionary = VR.parse_initial(JSON.stringify(bad1), ctx)
	check("reject_units", not bool(r1.get("ok", true)) and str(r1.get("code", "")) == "VA_UNALLOC_FIELD", r1.get("detail", ""))
	var bad2 := example()
	((bad2["phases"] as Array)[1]["missions"] as Array).pop_back()
	var r2: Dictionary = VR.parse_initial(JSON.stringify(bad2), ctx)
	check("reject_not_three", not bool(r2.get("ok", true)) and str(r2.get("code", "")) == "VA_MISSIONS", r2.get("detail", ""))
	# legacy default untouched
	OS.set_environment(AuthoringCls.CONTRACT_MODE_ENV, "")
	check("legacy_prompt_identical", VR.initial_prompt_for("red") == VR.VICTORY_INITIAL_PROMPT)
	var rl: Dictionary = VR.parse_initial(JSON.stringify(example()), ctx)
	check("legacy_still_requires_units", str(rl.get("code", "")) == "VA_MISSION_UNITS", rl.get("code", ""))
	_done()


func _done() -> void:
	print("HA_RESULT %s fails=%d" % ["PASS" if fails == 0 else "FAIL", fails])
	quit(0 if fails == 0 else 1)
