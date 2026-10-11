extends SceneTree

## Dump raw_head samples from a live evidence file.
## Usage: ... -s tools/step7_semantic_dump_probe.gd -- --file=<name> --idx=0,2,12

const DIR := "D:/Game development/Demon slayer/StrategyGame/tools/"


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var fname := ".audit_semantic_live.json"
	var wanted := {}
	for a in OS.get_cmdline_user_args():
		if str(a).begins_with("--file="):
			fname = str(a).trim_prefix("--file=")
		if str(a).begins_with("--idx="):
			for p in str(a).trim_prefix("--idx=").split(","):
				wanted[int(p)] = true
	var t := FileAccess.open(DIR + fname, FileAccess.READ)
	if t == null:
		print("NO FILE " + fname)
		quit(1)
		return
	var parsed: Variant = JSON.parse_string(t.get_as_text())
	t.close()
	if not parsed is Dictionary:
		print("PARSE FAIL")
		quit(1)
		return
	for r in ((parsed as Dictionary).get("results", []) as Array):
		var i := int((r as Dictionary).get("idx", -1))
		if not wanted.is_empty() and not wanted.has(i):
			continue
		print("### idx=%d text=%s" % [i, str((r as Dictionary).get("text", ""))])
		print("mode=%s route=%s fb=%s lat=%dms" % [str((r as Dictionary).get("mode", (r as Dictionary).get("fallback_reason", "?"))),
			str((r as Dictionary).get("route_ok", "?")), str((r as Dictionary).get("fallback_reason", "—")),
			int((r as Dictionary).get("latency_ms", 0))])
		print("RAW: " + str((r as Dictionary).get("raw_head", "—")).left(500))
		print("")
	quit(0)
