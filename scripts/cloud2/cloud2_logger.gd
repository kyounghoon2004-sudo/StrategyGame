class_name Cloud2Logger
extends RefCounted

## CLOUD-GENERAL STEP 2 — Structured research logging (secret-free).
##
## One JSON file per Cloud turn under res://evidence/cloud2_logs/ plus a
## rolling session index. Records the full pipeline: snapshot, packet
## fingerprint, model/provider id, latency, plan, validated orders,
## per-order validation/compilation/execution, and pre/post fingerprints.
##
## Hygiene: records are scrubbed recursively — any dict key named like a
## credential (api_key, authorization, secret, token, bearer) is dropped
## before serialization. The API key must never be passed in, and the
## scrubber is the backstop, not the plan.

const LOG_DIR := "res://evidence/cloud2_logs"

const SECRET_KEYS := ["api_key", "apikey", "api-key", "authorization",
	"secret", "client_secret", "token", "access_token", "bearer"]


static func scrub(v: Variant) -> Variant:
	if v is Dictionary:
		var out := {}
		for k in (v as Dictionary).keys():
			var ks := str(k).strip_edges().to_lower()
			if ks in SECRET_KEYS:
				continue
			out[k] = scrub((v as Dictionary)[k])
		return out
	if v is Array:
		var cells: Array = []
		for item in (v as Array):
			cells.append(scrub(item))
		return cells
	return v


static func ensure_dir() -> bool:
	return ensure_dir_recursive(LOG_DIR)


## Create any res:// evidence directory tree (cloud2_logs and the newer
## cloud2_trace share this). Additive; existing callers keep working.
static func ensure_dir_recursive(dir: String) -> bool:
	var rel := dir.trim_prefix("res://")
	var d := DirAccess.open("res://")
	if d == null:
		return false
	if not d.dir_exists(rel):
		var err := d.make_dir_recursive(rel)
		if err != OK:
			return false
	return true


## Write one turn record. Returns {ok, path}.
static func log_turn(record: Dictionary) -> Dictionary:
	if not ensure_dir():
		return {"ok": false, "path": "", "detail": "Log directory unavailable."}
	var clean: Dictionary = scrub(record)
	var turn := int(clean.get("turn", 0))
	var stamp := Time.get_datetime_string_from_system(false).replace(":", "").replace("-", "").replace("T", "_")
	var fname := "cloud2_t%03d_%s.json" % [turn, stamp]
	var path := "%s/%s" % [LOG_DIR, fname]
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return {"ok": false, "path": "", "detail": "Could not open %s." % path}
	f.store_string(JSON.stringify(clean, "  "))
	f.close()
	_append_index({"file": fname, "turn": turn,
		"acting_side": str(clean.get("acting_side", "")),
		"status": str(clean.get("status", "")),
		"orders": int(clean.get("order_count", 0)),
		"executed": int(clean.get("executed_count", 0)),
		"rejected": int(clean.get("rejected_count", 0)),
		"latency_ms": int(clean.get("latency_ms", 0)),
		"model": str(clean.get("model", "")),
		"provider": str(clean.get("provider", "")),
		"snapshot_id": str(clean.get("snapshot_id", ""))})
	return {"ok": true, "path": path}


static func _append_index(row: Dictionary) -> void:
	var path := "%s/session_index.jsonl" % LOG_DIR
	var f := FileAccess.open(path, FileAccess.READ)
	var existing := ""
	if f != null:
		existing = f.get_as_text()
		f.close()
	var w := FileAccess.open(path, FileAccess.WRITE)
	if w == null:
		return
	w.store_string(existing + JSON.stringify(scrub(row)) + "\n")
	w.close()


static func required_keys() -> Array:
	return ["timestamp", "battle_id", "turn", "acting_side", "snapshot_id",
		"state_version", "provider", "model", "latency_ms", "plan",
		"orders", "validation", "executions", "pre_fingerprint",
		"post_fingerprint", "status"]
