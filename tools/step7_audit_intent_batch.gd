extends SceneTree

## Audit batch validator: runs the REAL in-engine extract_json +
## validate_intent over raw model outputs captured by step7_audit_phase1.py
## (tools/.audit_phase1_raw.json). Writes tools/.audit_phase1_validated.json.
## Usage: Godot --headless --path <proj> -s tools/step7_audit_intent_batch.gd

const IN := "D:/Game development/Demon slayer/StrategyGame/tools/.audit_phase1_raw.json"
const OUT := "D:/Game development/Demon slayer/StrategyGame/tools/.audit_phase1_validated.json"

func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var IntentScript = load("res://scripts/step7/step7_chat_intent.gd")
	var raw_text := FileAccess.get_file_as_string(IN)
	if raw_text.is_empty():
		print("AUDIT_BATCH: no input (run step7_audit_phase1.py first)")
		quit(2)
		return
	var data: Variant = JSON.parse_string(raw_text)
	var rows: Array = []
	for res in ((data as Dictionary).get("results", []) as Array):
		var r: Dictionary = res
		var row := {"tag": str(r.get("tag", "?")), "text": str(r.get("text", "")),
			"transport_ok": bool(r.get("ok", false)),
			"latency_ms": float(r.get("latency_ms", 0.0))}
		if not bool(r.get("ok", false)):
			row["verdict"] = "TRANSPORT_FAIL"
			row["raw_head"] = str(r.get("error", "?")).left(200)
			rows.append(row)
			continue
		var raw := str(r.get("raw", ""))
		row["raw_head"] = raw.left(300)
		var parsed: Dictionary = IntentScript.extract_json(raw)
		if parsed.is_empty():
			row["verdict"] = "MALFORMED_NO_JSON"
			rows.append(row)
			continue
		var checked: Dictionary = IntentScript.validate_intent(parsed)
		if not bool(checked.get("ok", false)):
			row["verdict"] = "MALFORMED_SCHEMA"
			row["why"] = str(checked.get("why", "?"))
			row["parsed_head"] = JSON.stringify(parsed).left(400)
			rows.append(row)
			continue
		var intent: Dictionary = checked.get("intent", {})
		row["verdict"] = "VALID"
		row["fingerprint"] = IntentScript.intent_fingerprint(intent)
		row["intent"] = intent
		rows.append(row)
	var f := FileAccess.open(OUT, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({"rows": rows}))
		f.close()
	var n_valid := 0
	var n_malf := 0
	for row in rows:
		if str((row as Dictionary).get("verdict", "")) == "VALID":
			n_valid += 1
		else:
			n_malf += 1
		print("AUDIT_ROW %s | %s | %s" % [str((row as Dictionary).get("tag", "?")),
			str((row as Dictionary).get("verdict", "?")),
			str((row as Dictionary).get("fingerprint", (row as Dictionary).get("why", "")))])
	print("AUDIT_BATCH_DONE valid=%d malformed=%d total=%d" % [n_valid, n_malf, rows.size()])
	quit(0)
