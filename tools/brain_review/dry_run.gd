extends SceneTree

## HEADLESS DRY-RUN HARNESS (tools/brain_review, dev only — no production edits).
##
## Replays captured VICTORY_REVIEW targets through the PRODUCTION code:
##   Cloud2VictoryResponse.parse_review  -> structural / unalloc_v1 validation
##   Cloud2MissionManager.vp_compute_review -> lifecycle validation (amend_phases
##     history immutability, advance dispositions) on a reconstructed VictoryPlan.
##
## Plan reconstruction (documented): the internal VictoryPlan is rebuilt from
## the packet's plan_authoring (production author_initial), then Godot-owned
## state is restored from plan_live: revision, current_phase_id, and phase
## statuses. Statuses follow phase order around the active phase: earlier
## phases COMPLETED (terminal - the strictest AMEND history check), the active
## phase ACTIVE, later phases PLANNED (so ADVANCE targets validate). Teacher
## AMEND targets carry every non-active phase byte-identical from
## plan_authoring, so the history echo holds under any live status assignment.
##
## Input  (env DRYRUN_IN):  JSONL rows {row_id, packet, target}
## Output (env DRYRUN_OUT): JSONL rows {row_id, ok, stage, code, detail, action, decision}
## Run with BRAIN_CONTRACT_MODE=unalloc_v1 (the caller sets it).

const VictoryResponseCls = preload("res://scripts/cloud2/cloud2_victory_response.gd")
const VictoryAuthoringCls = preload("res://scripts/cloud2/cloud2_victory_authoring.gd")
const VictoryPlanCls = preload("res://scripts/cloud2/cloud2_victory_plan.gd")
const MissionMgrCls = preload("res://scripts/cloud2/cloud2_mission_manager.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var inp := OS.get_environment("DRYRUN_IN")
	var outp := OS.get_environment("DRYRUN_OUT")
	assert(not inp.is_empty() and not outp.is_empty(), "DRYRUN_IN / DRYRUN_OUT required")
	print("[DryRun] contract=%s in=%s" % [OS.get_environment("BRAIN_CONTRACT_MODE"), inp])
	var out := FileAccess.open(outp, FileAccess.WRITE)
	var n := 0
	var ok_n := 0
	for line in FileAccess.get_file_as_string(inp).split("\n"):
		if line.strip_edges().is_empty():
			continue
		var row: Variant = JSON.parse_string(line)
		if not (row is Dictionary):
			continue
		var res := _one(row)
		out.store_string(JSON.stringify(res) + "\n")
		n += 1
		if bool(res.get("ok", false)):
			ok_n += 1
	out.close()
	print("[DryRun] done %d rows ok=%d" % [n, ok_n])
	quit(0)


func _roster(packet: Dictionary) -> Array:
	var out: Array = []
	for u in (((packet.get("compact_state", {}) as Dictionary).get("friendly_units", [])) as Array):
		if u is Dictionary:
			out.append(str((u as Dictionary).get("unit_id", "")).to_upper())
	return out


func _obs_of(packet: Dictionary) -> Dictionary:
	var obs: Dictionary = packet.duplicate(true)
	obs["turn"] = int(packet.get("turn", 0))
	return obs


func _one(row: Dictionary) -> Dictionary:
	var packet: Dictionary = row.get("packet", {}) as Dictionary
	var target: Dictionary = row.get("target", {}) as Dictionary
	var rid := str(row.get("row_id", ""))
	var turn := int(packet.get("turn", 0))
	var ctx := {"turn": turn, "snapshot_id": str(packet.get("snapshot_id", "")), "roster": _roster(packet),
		"plan_authoring": packet.get("plan_authoring", {})}
	var parsed := VictoryResponseCls.parse_review(JSON.stringify(target), ctx)
	if not bool(parsed.get("ok", false)):
		return {"row_id": rid, "ok": false, "stage": "parse_review",
			"code": str(parsed.get("code", "?")), "detail": str(parsed.get("detail", "")), "decision": str(target.get("decision", ""))}
	var review: Dictionary = parsed.get("review", {})
	# Reconstruct the internal VictoryPlan from plan_authoring (production expansion).
	var authored := VictoryAuthoringCls.author_initial(packet.get("plan_authoring", {}), ctx)
	if not bool(authored.get("ok", false)):
		return {"row_id": rid, "ok": false, "stage": "reconstruct",
			"code": str(authored.get("code", "?")), "detail": str(authored.get("detail", "")), "decision": str(review.get("decision", ""))}
	var plan: Dictionary = (authored.get("plan", {}) as Dictionary).duplicate(true)
	var live: Dictionary = packet.get("plan_live", {}) as Dictionary
	var cur := str(live.get("current_phase_id", ""))
	plan["revision"] = int(live.get("revision", 1))
	plan["parent_revision"] = int(live.get("revision", 1)) - 1
	plan["current_phase_id"] = cur
	var seen_active := false
	for p_val in (plan.get("phases", []) as Array):
		var ph: Dictionary = p_val
		if str(ph.get("phase_id", "")) == cur:
			seen_active = true
			ph["status"] = "ACTIVE"
		else:
			# earlier than active -> terminal history (strictest echo check);
			# later -> PLANNED (advance targets must be PLANNED)
			ph["status"] = "COMPLETED" if not seen_active else "PLANNED"
		ph["status_turn"] = turn
		ph["status_reason"] = "DRYRUN"
	var mgr := MissionMgrCls.new()
	mgr.set("_vp", plan)
	var computed: Dictionary = mgr.vp_compute_review(review, _obs_of(packet), turn)
	if not bool(computed.get("ok", false)):
		return {"row_id": rid, "ok": false, "stage": "vp_compute_review",
			"code": str(computed.get("code", "?")), "detail": str(computed.get("detail", "")), "decision": str(review.get("decision", ""))}
	return {"row_id": rid, "ok": true, "stage": "committed", "code": "", "detail": "",
		"action": str(computed.get("action", "")), "decision": str(review.get("decision", ""))}
