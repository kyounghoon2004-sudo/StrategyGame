extends SceneTree

## PLAN SEARCH step 2 (dev only): validate candidate opening plans with the PRODUCTION parser
## (Cloud2VictoryResponse.parse_initial) before any game is spent on them.
## Env: PLANS_IN (candidates.jsonl), PLANS_STATE (opening_state.json), PLANS_OUT (jsonl {id, ok, code, detail}).
## Run with BRAIN_CONTRACT_MODE=unalloc_v1 (the caller sets it).

const VictoryResponseCls = preload("res://scripts/cloud2/cloud2_victory_response.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var st: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(OS.get_environment("PLANS_STATE")))
	var packet: Dictionary = {}
	for m in st.get("messages", []):
		if str((m as Dictionary).get("role", "")) == "user":
			packet = JSON.parse_string(str((m as Dictionary).get("content", "")))
	var roster: Array = []
	for u in ((packet.get("compact_state", {}) as Dictionary).get("friendly_units", []) as Array):
		roster.append(str((u as Dictionary).get("unit_id", "")).to_upper())
	var ctx := {"turn": int(packet.get("turn", 1)), "snapshot_id": str(packet.get("snapshot_id", "")), "roster": roster}
	print("[Validate] contract=%s roster=%d" % [OS.get_environment("BRAIN_CONTRACT_MODE"), roster.size()])
	var out := FileAccess.open(OS.get_environment("PLANS_OUT"), FileAccess.WRITE)
	for line in FileAccess.get_file_as_string(OS.get_environment("PLANS_IN")).split("\n"):
		if line.strip_edges().is_empty():
			continue
		var row: Dictionary = JSON.parse_string(line)
		var parsed := VictoryResponseCls.parse_initial(JSON.stringify(row.get("plan", {})), ctx)
		out.store_line(JSON.stringify({"id": row.get("id", ""), "ok": bool(parsed.get("ok", false)),
			"code": str(parsed.get("code", "")), "detail": str(parsed.get("detail", ""))}))
	out.close()
	quit(0)
