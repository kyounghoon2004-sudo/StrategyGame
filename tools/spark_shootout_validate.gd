extends SceneTree

## Spark-X2.5 shootout B: AUTHORITATIVE GeneralResponse / VictoryPlan validation.
##
## Uses the production validators unmodified:
##   Cloud2VictoryResponse.parse_initial / parse_review
##   (-> Cloud2VictoryAuthoring.author_initial / author_phases
##    -> Cloud2VictoryPlan.validate_plan)
##
## Input  (argv user arg 1): JSON array of rows
##   {row_id, kind: "INITIAL"|"REVIEW", text_path, ctx: {turn, snapshot_id, roster}}
## Output (argv user arg 2): JSON array of per-row validator results.
##
## Read-only w.r.t. project code. No network. Exit 0 after writing results;
## exit 2 on harness-level failure (bad args / unreadable input).

const ResponseCls = preload("res://scripts/cloud2/cloud2_victory_response.gd")


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 2:
		printerr("[SparkValidate] need: -- <in_json> <out_json>")
		quit(2)
		return
	var in_path := args[0]
	var out_path := args[1]
	var raw := FileAccess.get_file_as_string(in_path)
	if raw.is_empty():
		printerr("[SparkValidate] unreadable input %s" % in_path)
		quit(2)
		return
	var rows: Variant = JSON.parse_string(raw)
	if not (rows is Array):
		printerr("[SparkValidate] input is not a JSON array")
		quit(2)
		return

	var results: Array = []
	for row_v in (rows as Array):
		var row: Dictionary = row_v
		var text := FileAccess.get_file_as_string(str(row.get("text_path", "")))
		var ctx: Dictionary = row.get("ctx", {})
		var kind := str(row.get("kind", "INITIAL"))
		var parsed: Dictionary = {}
		if kind == "REVIEW":
			parsed = ResponseCls.parse_review(text, ctx)
		else:
			parsed = ResponseCls.parse_initial(text, ctx)
		var rec := {
			"row_id": str(row.get("row_id", "")),
			"ok": bool(parsed.get("ok", false)),
			"code": str(parsed.get("code", "")),
			"detail": str(parsed.get("detail", "")),
			"stale_snapshot": bool(parsed.get("stale_snapshot", false)),
		}
		if kind == "REVIEW":
			var rv: Dictionary = parsed.get("review", {})
			rec["decision"] = str(rv.get("decision", ""))
			rec["next_phase_id"] = str(rv.get("next_phase_id", ""))
			rec["amend_phase_count"] = (rv.get("phases", []) as Array).size()
		else:
			var plan: Dictionary = parsed.get("plan", {})
			var phases: Array = plan.get("phases", [])
			var missions := 0
			for ph in phases:
				missions += (ph.get("missions", []) as Array).size()
			rec["phase_count"] = phases.size()
			rec["mission_count"] = missions
		results.append(rec)

	var f := FileAccess.open(out_path, FileAccess.WRITE)
	if f == null:
		printerr("[SparkValidate] cannot write %s" % out_path)
		quit(2)
		return
	f.store_string(JSON.stringify(results, "\t"))
	f.close()
	print("[SparkValidate] validated %d row(s) -> %s" % [results.size(), out_path])
	quit(0)
