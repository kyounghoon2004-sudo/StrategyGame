extends SceneTree

## Dataset candidate validator (deterministic project code ONLY):
## reads JSONL {user, envelope} -> envelope -> intent -> CommandIR v2,
## checks evidence binding + semantic coverage + relation sanity.
## Writes verdicts JSONL {user, ok, reason, fingerprint}.
## Usage: ... -s tools/step7_semantic_dataset_check.gd -- --in=D:/semSFT/data/x.jsonl --out=D:/semSFT/data/x.verdict.jsonl

const FrontendScript = preload("res://scripts/step7/step7_semantic_frontend.gd")
const CommandIRScript = preload("res://scripts/step7/step7_command_ir.gd")


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var inp := ""
	var outp := ""
	for a in OS.get_cmdline_user_args():
		if str(a).begins_with("--in="):
			inp = str(a).trim_prefix("--in=")
		if str(a).begins_with("--out="):
			outp = str(a).trim_prefix("--out=")
	if inp.is_empty() or outp.is_empty():
		print("NEED --in= --out=")
		quit(2)
		return
	var fin := FileAccess.open(inp, FileAccess.READ)
	if fin == null:
		print("NO INPUT " + inp)
		quit(2)
		return
	var total := 0
	var okc := 0
	var reasons := {}
	var fout := FileAccess.open(outp, FileAccess.WRITE)
	while not fin.eof_reached():
		var line := fin.get_line().strip_edges()
		if line.is_empty():
			continue
		total += 1
		var row: Variant = JSON.parse_string(line)
		var verdict := _validate_row(row)
		if bool(verdict.get("ok", false)):
			okc += 1
		else:
			var rs := str(verdict.get("reason", "?"))
			reasons[rs] = int(reasons.get(rs, 0)) + 1
		fout.store_string(JSON.stringify(verdict) + "\n")
	fin.close()
	fout.close()
	print("DATASET total=%d ok=%d reject=%d" % [total, okc, total - okc])
	for k in reasons.keys():
		print("  REJECT %s x%d" % [str(k), int(reasons[k])])
	print("WROTE " + outp)
	quit(0)


func _validate_row(row: Variant) -> Dictionary:
	if not row is Dictionary:
		return {"ok": false, "reason": "ROW_NOT_OBJECT"}
	var user := str((row as Dictionary).get("user", ""))
	var env_raw: Variant = (row as Dictionary).get("envelope", {})
	if user.strip_edges().is_empty():
		return {"ok": false, "reason": "EMPTY_USER", "user": user}
	if not env_raw is Dictionary:
		return {"ok": false, "reason": "ENVELOPE_NOT_OBJECT", "user": user}
	# Same pipeline as the live frontend: raw JSON -> envelope/intent/IR.
	var h: Dictionary = FrontendScript.handle_raw(JSON.stringify(env_raw), user)
	if not bool(h.get("ok", false)):
		return {"ok": false, "reason": "HANDLE_" + str(h.get("fallback_reason", "?")),
			"why": str(h.get("why", "")), "user": user}
	var ir: Dictionary = h.get("ir", {})
	var cov: Dictionary = ir.get("coverage", {})
	# Evidence/coverage binds COMMAND clauses only. Non-COMMAND envelopes
	# carry no orders by design (the question text is the payload) — same
	# as the SemanticGate, which passes them before evidence checks.
	if str(ir.get("kind", "")) == "COMMAND":
		if not (cov.get("unbound", []) as Array).is_empty():
			return {"ok": false, "reason": "UNBOUND_EVIDENCE", "user": user}
		var sem: Array = (cov.get("semantic_uncovered", []) as Array).duplicate()
		if not sem.is_empty():
			var toks: Array = []
			for e in sem:
				toks.append(str((e as Dictionary).get("token", "?")))
			return {"ok": false, "reason": "SEM_UNCOVERED:" + ",".join(toks.slice(0, 4)), "user": user}
	var orders: Array = ir.get("orders", [])
	if str(ir.get("kind", "")) == "COMMAND" and orders.is_empty():
		return {"ok": false, "reason": "COMMAND_NO_ORDERS", "user": user}
	return {"ok": true, "user": user,
		"fingerprint": str(ir.get("fingerprint", "")),
		"mode": str((h.get("envelope", {}) as Dictionary).get("mode", "?")),
		"orders": orders.size(), "relation": str(ir.get("relation", "")),
		"meta": (row as Dictionary).get("meta", {})}
