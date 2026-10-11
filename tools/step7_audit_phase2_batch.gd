extends SceneTree

## Audit Phase-2 batch validator: runs the REAL commander selection
## validation over raw model selection responses captured by
## step7_audit_phase2.py (tools/.audit_phase2_raw.json) against the REAL
## packages from step7_audit_phase2_ctx.gd. Writes
## tools/.audit_phase2_validated.json.

const IN := "D:/Game development/Demon slayer/StrategyGame/tools/.audit_phase2_raw.json"
const CTX := "D:/Game development/Demon slayer/StrategyGame/tools/.audit_phase2_ctx.json"
const OUT := "D:/Game development/Demon slayer/StrategyGame/tools/.audit_phase2_validated.json"

const CommanderScript = preload("res://scripts/step7/step7_chat_commander.gd")
const IntentScript = preload("res://scripts/step7/step7_chat_intent.gd")
const ViewModelScript = preload("res://scripts/step7/step7_advisor_viewmodel.gd")


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var ctx: Variant = JSON.parse_string(FileAccess.get_file_as_string(CTX))
	var raw: Variant = JSON.parse_string(FileAccess.get_file_as_string(IN))
	if not (ctx is Dictionary) or not (raw is Dictionary):
		print("AUDIT_P2BATCH: missing input")
		quit(2)
		return
	var rows: Array = []
	var cmdr = CommanderScript.new()
	for res in (((raw as Dictionary).get("results", [])) as Array):
		var r: Dictionary = res
		var tag := str(r.get("tag", "?"))
		var row := {"tag": tag, "transport_ok": bool(r.get("ok", false)),
			"latency_ms": float(r.get("latency_ms", 0.0)),
			"done_reason": str(r.get("done_reason", "")),
			"eval_count": int(r.get("eval_count", 0)),
			"thinking_len": int(r.get("thinking_len", 0))}
		if not bool(r.get("ok", false)):
			row["verdict"] = "TRANSPORT_FAIL"
			rows.append(row)
			continue
		var content := str(r.get("raw", ""))
		row["raw_head"] = content.left(200)
		var parsed: Dictionary = IntentScript.extract_json(content)
		if parsed.is_empty():
			row["verdict"] = "MALFORMED_NO_JSON"
			rows.append(row)
			continue
		var case_ctx: Dictionary = ((ctx as Dictionary).get("cases", {}) as Dictionary).get(tag, {})
		var pkgs: Dictionary = (case_ctx.get("packages", {}) as Dictionary).duplicate(true)
		var rec := {"packages": pkgs}
		# Shape rec.packages like the live path: options keyed per unit.
		var checked: Dictionary = cmdr._validate_selections(pkgs, parsed)
		if not bool(checked.get("ok", false)):
			row["verdict"] = "MALFORMED_SCHEMA"
			row["why"] = str(checked.get("why", "?"))
			rows.append(row)
			continue
		row["verdict"] = "VALID"
		var sels: Array = []
		for s in (checked.get("selections", []) as Array):
			sels.append({"unit_id": str((s as Dictionary).get("unit_id", "?")),
				"pick": str((s as Dictionary).get("selected_option_id", "?"))})
		row["selections"] = sels
		row["reason"] = str(parsed.get("reason", ""))
		row["confidence"] = float(parsed.get("confidence", -1.0))
		# Player-facing quality gate: no internal jargon in the reason.
		var supplied: Array = []
		for uid in (case_ctx.get("unit_ids", []) as Array):
			supplied.append(str(uid))
		var leak := ViewModelScript.audit_player_text(str(parsed.get("reason", "")), [])
		row["text_audit"] = leak
		rows.append(row)
	cmdr.queue_free()
	var f := FileAccess.open(OUT, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({"rows": rows}))
		f.close()
	var nv := 0
	for row in rows:
		var rd: Dictionary = row
		if str(rd.get("verdict", "")) == "VALID":
			nv += 1
		print("AUDIT_P2ROW %s | %s | %s" % [str(rd.get("tag", "?")),
			str(rd.get("verdict", "?")), str(rd.get("why", JSON.stringify(rd.get("selections", [])))).left(220)])
	print("AUDIT_P2BATCH_DONE valid=%d total=%d" % [nv, rows.size()])
	quit(0)
