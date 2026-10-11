class_name Cloud2DebugAgentTransport
extends RefCounted

## AGENT-AS-GENERAL DEBUG HARNESS — file debug transport (pure helpers).
##
## Layout under the run dir (absolute path, outside res:// by default):
##   run.json                  run config (scenario, blindness, backend, timeout)
##   status.json               live harness status (phase, turn, pending request)
##   control.json              {stop: bool} — the CLI sets stop=true to terminate
##   pending.json              {request_id or null} — current parked request
##   requests/request_<id>.json   General-facing request (BLIND-safe by construction)
##   truth/truth_<id>.json        orchestrator-only world truth sidecar (NEVER
##                                General-facing in BLIND_GENERAL mode)
##   responses/response_<id>.json agent submission envelope
##   audit.jsonl               append-only audit log (one JSON object per line)
##   truth_access.log          truth-display events (contamination tracking)
##   battle.json               final battle summary
##
## Writes are atomic (tmp file + rename). No network, no provider, no keys:
## every envelope is scanned for secret-shaped keys before write (defense in
## depth — the debug path must never become a secret exfiltration channel).

const ConfigCls = preload("res://scripts/cloud2/cloud2_debug_agent_config.gd")

const SECRET_KEY_HINTS := ["api_key", "apikey", "secret", "authorization", "bearer", "x-api-key"]


static func ensure_layout(run_dir: String) -> Dictionary:
	for d in [run_dir, run_dir + "/requests", run_dir + "/truth", run_dir + "/responses"]:
		var err := DirAccess.make_dir_recursive_absolute(d)
		if err != OK:
			return {"ok": false, "detail": "Cannot create %s (err=%d)." % [d, err]}
	return {"ok": true, "detail": ""}


static func atomic_write(path: String, text: String) -> Dictionary:
	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return {"ok": false, "detail": "Cannot write %s." % tmp}
	f.store_string(text)
	f.close()
	var err := DirAccess.rename_absolute(tmp, path)
	if err != OK:
		return {"ok": false, "detail": "Cannot rename %s -> %s (err=%d)." % [tmp, path, err]}
	return {"ok": true, "detail": ""}


static func read_json_file(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"ok": false, "code": "NOT_FOUND", "detail": "Missing %s." % path, "data": {}}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {"ok": false, "code": "READ_FAILED", "detail": "Cannot read %s." % path, "data": {}}
	var text := f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(text)
	if parsed is Dictionary:
		return {"ok": true, "code": "", "detail": "", "data": parsed, "text": text}
	if parsed is Array:
		return {"ok": true, "code": "", "detail": "", "data": {"_array": parsed}, "text": text}
	return {"ok": false, "code": "INVALID_JSON", "detail": "%s is not a JSON object." % path, "data": {}}


static func _has_secret_key(v: Variant) -> String:
	if v is Dictionary:
		for k in (v as Dictionary).keys():
			var ks := str(k).to_lower()
			for hint in SECRET_KEY_HINTS:
				if ks == hint or ks.contains(hint):
					return str(k)
			var sub := _has_secret_key((v as Dictionary)[k])
			if not sub.is_empty():
				return sub
	elif v is Array:
		for e in (v as Array):
			var sub2 := _has_secret_key(e)
			if not sub2.is_empty():
				return sub2
	return ""


static func sha256_of(text: String) -> String:
	return text.sha256_text()


static func now_iso() -> String:
	return Time.get_datetime_string_from_system(false)


## Write one General-facing request envelope. Refuses envelopes carrying
## secret-shaped keys. Updates pending.json to this request.
static func write_request(run_dir: String, envelope: Dictionary) -> Dictionary:
	var leak := _has_secret_key(envelope)
	if not leak.is_empty():
		return {"ok": false, "code": "SECRET_REFUSED",
			"detail": "Request envelope carries secret-shaped key '%s'; refused." % leak}
	var req_id := str(envelope.get("request_id", ""))
	if req_id.is_empty():
		return {"ok": false, "code": "NO_REQUEST_ID", "detail": "Envelope needs request_id."}
	var text := JSON.stringify(envelope, "  ")
	var w := atomic_write("%s/requests/request_%s.json" % [run_dir, req_id], text)
	if not bool(w.get("ok", false)):
		return {"ok": false, "code": "WRITE_FAILED", "detail": str(w.get("detail", ""))}
	atomic_write(run_dir + "/pending.json", JSON.stringify({"request_id": req_id}))
	return {"ok": true, "code": "", "detail": "", "sha256": sha256_of(text), "chars": text.length()}


static func write_truth(run_dir: String, request_id: String, truth: Dictionary) -> Dictionary:
	var text := JSON.stringify(truth, "  ")
	var w := atomic_write("%s/truth/truth_%s.json" % [run_dir, request_id], text)
	if not bool(w.get("ok", false)):
		return {"ok": false, "code": "WRITE_FAILED", "detail": str(w.get("detail", ""))}
	return {"ok": true, "code": "", "detail": "", "sha256": sha256_of(text), "chars": text.length()}


static func clear_pending(run_dir: String) -> void:
	atomic_write(run_dir + "/pending.json", JSON.stringify({"request_id": null}))


## Read one agent response envelope. Shape-checked only (presence + id
## match); semantic validation stays in the canonical response validators.
static func read_response(run_dir: String, request_id: String) -> Dictionary:
	var path := "%s/responses/response_%s.json" % [run_dir, request_id]
	if not FileAccess.file_exists(path):
		return {"ok": false, "code": "NO_RESPONSE", "detail": "No response yet.", "data": {}}
	var got := read_json_file(path)
	if not bool(got.get("ok", false)):
		return {"ok": false, "code": "RESPONSE_UNREADABLE",
			"detail": str(got.get("detail", "")), "data": {}}
	var data: Dictionary = got.get("data", {})
	if str(data.get("request_id", "")) != request_id:
		return {"ok": false, "code": "RESPONSE_ID_MISMATCH",
			"detail": "Response targets '%s', want '%s'." % [str(data.get("request_id", "")), request_id],
			"data": data}
	if not data.has("response_text") or str(data.get("response_text", "")).strip_edges().is_empty():
		return {"ok": false, "code": "EMPTY_SUBMISSION",
			"detail": "Response carries no response_text.", "data": data}
	return {"ok": true, "code": "", "detail": "", "data": data, "text": str(got.get("text", ""))}


static func append_audit(run_dir: String, record: Dictionary) -> void:
	var row: Dictionary = record.duplicate(true)
	row["logged_at"] = now_iso()
	var f := FileAccess.open(run_dir + "/audit.jsonl", FileAccess.READ_WRITE)
	if f == null:
		var w := FileAccess.open(run_dir + "/audit.jsonl", FileAccess.WRITE)
		if w == null:
			return
		w.store_line(JSON.stringify(row))
		w.close()
		return
	f.seek_end()
	f.store_line(JSON.stringify(row))
	f.close()


static func write_status(run_dir: String, status: Dictionary) -> void:
	var row: Dictionary = status.duplicate(true)
	row["updated_at"] = now_iso()
	atomic_write(run_dir + "/status.json", JSON.stringify(row, "  "))


static func read_control(run_dir: String) -> Dictionary:
	var got := read_json_file(run_dir + "/control.json")
	if not bool(got.get("ok", false)):
		return {"stop": false}
	return got.get("data", {"stop": false})


static func write_control(run_dir: String, control: Dictionary) -> Dictionary:
	return atomic_write(run_dir + "/control.json", JSON.stringify(control, "  "))


## Build the General-facing request envelope. The packet/menu/prompt are
## EXACTLY what the provider path would have sent (same builders); the
## envelope adds only transport metadata (ids, timestamps, backend label).
static func build_request_envelope(run_id: String, request_id: String, kind: String,
		turn: int, blindness: String, packet: Dictionary, menu: Dictionary,
		system_prompt: String, plan_version: int) -> Dictionary:
	var kinds: Array = []
	for e_val in (packet.get("events_since_review", packet.get("trigger_events", [])) as Array):
		if e_val is Dictionary:
			kinds.append(str((e_val as Dictionary).get("kind", "")))
	return {
		"protocol": ConfigCls.PROTOCOL_VERSION,
		"request_id": request_id,
		"run_id": run_id,
		"backend": ConfigCls.BACKEND_DEBUG_AGENT,
		"blindness": blindness.strip_edges().to_upper(),
		"kind": kind,
		"turn": turn,
		"requested_at": now_iso(),
		"snapshot_id": str(packet.get("snapshot_id", "")),
		"battle_id": str(packet.get("battle_id", "")),
		"scenario_id": str(packet.get("scenario_id", "")),
		"previous_plan_version": plan_version,
		"event_kinds": kinds,
		"event_count": kinds.size(),
		"system_prompt": system_prompt,
		"packet": packet.duplicate(true),
		"menu": menu.duplicate(true),
		"observation_scope": "RED-authorized observation only. No BLUE/world truth is present in this envelope by construction (same builders as the provider path).",
	}
