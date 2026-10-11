extends SceneTree

## BRAIN SHOOTOUT A — authoritative Godot-side validation of Phi outputs.
##
## Reads a manifest JSON (list of {file, kind, turn, snapshot_id, roster})
## and runs the PRODUCTION validators:
##   initial -> Cloud2VictoryResponse.parse_initial
##   review  -> Cloud2VictoryResponse.parse_review
## Prints a JSON result object to stdout. Exit 0 = script ran (per-item
## ok flags carry the verdicts). No network, no weights, no training.
##
## Usage (Windows):
##   Godot_v4.2.2-stable_win64_console.exe --headless --path "D:\Game development\Demon slayer\StrategyGame" -s res://tools/phi_shootout_validate.gd -- <manifest.json> <out.json>

const ResponseCls = preload("res://scripts/cloud2/cloud2_victory_response.gd")

var _args: PackedStringArray = []


func _init() -> void:
	_args = OS.get_cmdline_user_args()
	call_deferred("_run")


func _run() -> void:
	if _args.size() < 2:
		printerr("[PhiValidate] need <manifest.json> <out.json>")
		quit(1)
		return
	var manifest_text := FileAccess.get_file_as_string(_args[0])
	if manifest_text.is_empty():
		printerr("[PhiValidate] empty manifest")
		quit(1)
		return
	var manifest: Variant = JSON.parse_string(manifest_text)
	if not manifest is Array:
		printerr("[PhiValidate] manifest is not an array")
		quit(1)
		return
	var results: Array = []
	for entry_val in (manifest as Array):
		if not entry_val is Dictionary:
			continue
		var entry: Dictionary = entry_val
		var path := str(entry.get("file", ""))
		var kind := str(entry.get("kind", "initial"))
		var text := FileAccess.get_file_as_string(path)
		if text.is_empty():
			results.append({"file": path, "kind": kind, "ok": false,
				"code": "READ_FAIL", "detail": "empty/unreadable output file"})
			continue
		var ctx := {"turn": int(entry.get("turn", 1)),
			"snapshot_id": str(entry.get("snapshot_id", "")),
			"roster": entry.get("roster", [])}
		var parsed: Dictionary = {}
		if kind == "review":
			parsed = ResponseCls.parse_review(text, ctx)
		else:
			parsed = ResponseCls.parse_initial(text, ctx)
		var item := {"file": path, "kind": kind,
			"ok": bool(parsed.get("ok", false)),
			"code": str(parsed.get("code", "")),
			"detail": str(parsed.get("detail", "")).left(300),
			"stale_snapshot": bool(parsed.get("stale_snapshot", false)),
			"contract": str(parsed.get("contract", ""))}
		if parsed.has("plan") and (parsed.get("plan", {}) as Dictionary).size() > 0:
			var plan: Dictionary = parsed.get("plan", {})
			var phases: Array = plan.get("phases", [])
			item["plan_phases"] = phases.size()
			item["plan_id"] = str(plan.get("victory_plan_id", ""))
			item["current_phase"] = str(plan.get("current_phase_id", ""))
			item["doctrine"] = plan.get("doctrine", {})
			item["review_horizon"] = int(plan.get("review_horizon_turns", -1))
			var slot_cov := _coverage(plan, ctx.get("roster", []))
			item["coverage_frac"] = slot_cov[0]
			item["coverage_units"] = slot_cov[1]
		if parsed.has("review") and (parsed.get("review", {}) as Dictionary).size() > 0:
			var rev: Dictionary = parsed.get("review", {})
			item["decision"] = str(rev.get("decision", ""))
			item["reason_len"] = str(rev.get("reason", "")).length()
			item["next_phase_id"] = str(rev.get("next_phase_id", ""))
			item["warnings"] = rev.get("warnings", [])
		results.append(item)
	var out := {"tool": "phi_shootout_validate", "results": results}
	var f := FileAccess.open(_args[1], FileAccess.WRITE)
	if f == null:
		printerr("[PhiValidate] cannot write out")
		quit(1)
		return
	f.store_string(JSON.stringify(out, "\t"))
	f.close()
	print(JSON.stringify(out))
	quit(0)


## Fraction of roster ids assigned anywhere in the ACTIVE-plan missions/groups.
static func _coverage(plan: Dictionary, roster: Array) -> Array:
	var want := {}
	for u in roster:
		want[str(u)] = true
	var got := {}
	for ph_val in (plan.get("phases", []) as Array):
		if not ph_val is Dictionary:
			continue
		var ph: Dictionary = ph_val
		var fi: Dictionary = ph.get("force_intent", {})
		for g_val in (fi.get("groups", []) as Array):
			if g_val is Dictionary:
				for u in (g_val as Dictionary).get("units", []):
					got[str(u)] = true
		for m_val in (ph.get("missions", []) as Array):
			if m_val is Dictionary:
				for u in (m_val as Dictionary).get("units", []):
					got[str(u)] = true
	var hit := 0
	for u in got.keys():
		if want.has(u):
			hit += 1
	var frac := 0.0
	if want.size() > 0:
		frac = float(hit) / float(want.size())
	return [frac, got.keys()]
