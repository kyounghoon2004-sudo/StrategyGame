extends SceneTree

## CommandIR v2 real-model normalization (NO scene, deterministic Godot
## side): reads tools/.audit_command_ir_live_raw.json (Ollama raws),
## runs extract_json + validate_intent + CommandIR normalization, prints
## raw / IR / evidence / coverage / fingerprint per case.
## The goal is preservation proof (what the model interpreted survives),
## NOT conflict resolution. quit 0 = pipeline worked (valid rows
## normalized); quit 1 = harness failure or zero valid rows.

const IN := "D:/Game development/Demon slayer/StrategyGame/tools/.audit_command_ir_live_raw.json"
const OUT := "D:/Game development/Demon slayer/StrategyGame/tools/.audit_command_ir_live.json"

const IntentScript = preload("res://scripts/step7/step7_chat_intent.gd")
const IRScript = preload("res://scripts/step7/step7_command_ir.gd")

var failures: Array = []
var passed := 0


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var txt := FileAccess.get_file_as_string(IN)
	if txt.is_empty():
		print("LIVE_CHECK: no input (run step7_command_ir_live.py first)")
		quit(2)
		return
	var data: Variant = JSON.parse_string(txt)
	var rows: Array = []
	var n_valid := 0
	var n_ir := 0
	for res in ((data as Dictionary).get("results", []) as Array):
		var r: Dictionary = res
		var row := {"tag": str(r.get("tag", "?")), "text": str(r.get("text", "")),
			"transport_ok": bool(r.get("ok", false)),
			"latency_ms": float(r.get("latency_ms", 0.0)),
			"done_reason": str(r.get("done_reason", ""))}
		if not bool(r.get("ok", false)):
			row["verdict"] = "TRANSPORT_FAIL"
			row["raw_head"] = str(r.get("error", "?")).left(200)
			rows.append(row)
			continue
		var raw := str(r.get("raw", ""))
		row["raw_head"] = raw.left(400)
		var parsed: Dictionary = IntentScript.extract_json(raw)
		if parsed.is_empty():
			row["verdict"] = "MALFORMED_NO_JSON"
			rows.append(row)
			continue
		var checked: Dictionary = IntentScript.validate_intent(parsed)
		if not bool(checked.get("ok", false)):
			row["verdict"] = "MALFORMED_SCHEMA"
			row["why"] = str(checked.get("why", "?"))
			rows.append(row)
			continue
		n_valid += 1
		var intent: Dictionary = checked.get("intent", {})
		row["intent_fp"] = IntentScript.intent_fingerprint(intent)
		row["orders"] = (intent.get("orders", []) as Array).size()
		row["relation_raw"] = str(intent.get("relation", ""))
		var nir: Dictionary = IRScript.from_validated_intent(intent, str(r.get("text", "")))
		if not bool(nir.get("ok", false)):
			row["verdict"] = "IR_REJECT"
			row["why"] = str(nir.get("why", "?"))
			rows.append(row)
			continue
		n_ir += 1
		var ir: Dictionary = nir.get("ir", {})
		var diag: Dictionary = IRScript.dev_diagnostics(ir)
		row["verdict"] = "IR_OK"
		row["ir_fp"] = str(ir.get("fingerprint", ""))
		row["ir_ev_fp"] = str(ir.get("evidence_fingerprint", ""))
		row["ir_relation"] = "%s (%s)" % [str(ir.get("relation", "")), str(ir.get("relation_source", ""))]
		row["ir_orders"] = (ir.get("orders", []) as Array).size()
		row["coverage_ratio"] = float((ir.get("coverage", {}) as Dictionary).get("coverage_ratio", 0.0))
		row["evidence_status"] = (ir.get("coverage", {}) as Dictionary).get("evidence_status", {})
		row["unbound"] = ((ir.get("coverage", {}) as Dictionary).get("unbound", []) as Array).size()
		row["semantic_uncovered"] = (ir.get("coverage", {}) as Dictionary).get("semantic_uncovered", [])
		row["order_fps"] = []
		for o in (diag.get("orders", []) as Array):
			(row["order_fps"] as Array).append("%s=%s" % [str((o as Dictionary).get("order_id", "?")), str((o as Dictionary).get("scope_fp", "?"))])
		rows.append(row)
		print("LIVE %s | orders=%s rel=%s | fp=%s | cov=%.2f ev=%s unbound=%s sem=%d" % [
			str(row.get("tag", "?")), str(row.get("ir_orders", "?")),
			str(row.get("ir_relation", "?")), str(row.get("ir_fp", "")).left(64),
			float(row.get("coverage_ratio", 0.0)), JSON.stringify(row.get("evidence_status", {})),
			str(row.get("unbound", "?")),
			(row.get("semantic_uncovered", []) as Array).size()])
		passed += 1
	var f := FileAccess.open(OUT, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({"rows": rows, "valid": n_valid, "ir_ok": n_ir}))
		f.close()
	print("LIVE_CHECK_DONE valid=%d ir_ok=%d total=%d" % [n_valid, n_ir, rows.size()])
	if n_ir == 0:
		failures.append("zero IR-normalized rows")
	quit(0 if failures.is_empty() else 1)
