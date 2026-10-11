class_name Cloud2WorkerHandshake
extends Node

## WORKER GENERAL live handshake (production file channel for the
## agent-as-General seam). Active only when the scene runs with an agent
## General backend (GENERAL_BACKEND=DEBUG_AGENT/EXTERNAL_AGENT).
##
## Protocol (same canonical gates as the provider path; only the transport
## differs — files instead of HTTP):
##   1. Controller parks a General request (RED-authorized packet+menu).
##   2. Poller dumps it to user://worker_general/live/requests/request_<id>.json
##      plus pending.json {request_id, session}. HUD shows THINKING.
##   3. The worker (live agent session) writes
##      user://worker_general/live/responses/response_<id>.json with the
##      SAME request_id + session stamp and a response_text decision.
##   4. Poller reads it, rejects stale/mismatched files, submits the text
##      through agent_submit_initial/agent_submit_review, archives the file.
##   5. If the parked request clears with no poller submission (engine
##      timeout), the request is recorded TIMED_OUT. No fallback Brain is
##      ever engaged; the phase holds explicitly via the standard
##      counted/flagged auto-HOLD, and the next request re-opens the channel.
##
## No provider, no API key, no model download. The user never touches JSON.

const LIVE_DIR := "user://worker_general/live"
const POLL_SEC := 0.5

var _ctl: Node = null
var _session := ""
var _dumped := {}
var _submitted := {}
var _accum := 0.0
var _channel_ok := false
var _channel_error := ""
var _wait_start := 0
var _last_req := ""
var _last_kind := ""
var _last_turn := 0
var _last_submission := {}
var _last_timeout := {}
var _counts := {"dumped": 0, "submitted": 0, "stale_rejected": 0, "timeouts": 0}


func setup(controller: Node) -> void:
	_ctl = controller
	_session = "%d_%d" % [Time.get_unix_time_from_system(), get_instance_id() % 100000]
	_channel_ok = _init_dirs()
	if not _channel_ok:
		_channel_error = "live dir not writable"
		push_error("[WorkerLink] OFFLINE: %s" % _channel_error)
		set_process(false)
		return
	_write_json(LIVE_DIR + "/pending.json", {"request_id": null, "session": _session})
	_write_handshake("LISTENING")
	print("[WorkerLink] listening session=%s dir=%s" % [_session, LIVE_DIR])
	set_process(true)


func _init_dirs() -> bool:
	for d in [LIVE_DIR, LIVE_DIR + "/requests", LIVE_DIR + "/responses"]:
		if DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(d)) != OK:
			return false
	var probe := FileAccess.open(LIVE_DIR + "/.__w", FileAccess.WRITE)
	if probe == null:
		return false
	probe.store_string("ok")
	probe.close()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(LIVE_DIR + "/.__w"))
	return true


func _process(delta: float) -> void:
	if _ctl == null or not _channel_ok:
		return
	_accum += delta
	if _accum < POLL_SEC:
		return
	_accum = 0.0
	var poll: Dictionary = _ctl.call("agent_poll")
	var parked: Dictionary = poll.get("parked", {})
	if parked.is_empty():
		_check_timeout_cleared()
		return
	var req_id := str(parked.get("request_id", ""))
	if req_id.is_empty():
		return
	if not _dumped.has(req_id):
		_dump_request(req_id, parked)
	_try_submit(req_id, str(parked.get("kind", "")))


func _dump_request(req_id: String, parked: Dictionary) -> void:
	_dumped[req_id] = true
	_last_req = req_id
	_last_kind = str(parked.get("kind", ""))
	_last_turn = int(parked.get("turn", 0))
	_wait_start = Time.get_ticks_msec()
	var packet: Dictionary = parked.get("packet", {})
	var dump := {"request_id": req_id, "kind": _last_kind, "turn": _last_turn,
		"snapshot_id": str(packet.get("snapshot_id", "")),
		"system_prompt": str(parked.get("system_prompt", "")),
		"packet": packet, "menu": parked.get("menu", {}),
		"session": _session}
	if not _write_json(LIVE_DIR + "/requests/request_" + req_id + ".json", dump):
		_channel_ok = false
		_channel_error = "request dump failed"
		push_error("[WorkerLink] OFFLINE: %s" % _channel_error)
		set_process(false)
		return
	_write_json(LIVE_DIR + "/pending.json",
		{"request_id": req_id, "session": _session, "kind": _last_kind, "turn": _last_turn})
	_counts["dumped"] += 1
	_write_handshake("THINKING")
	print("[WorkerLink] PARKED req=%s kind=%s turn=%d (RED-authorized packet+menu only)" % [
		req_id, _last_kind, _last_turn])


func _try_submit(req_id: String, kind: String) -> void:
	var rpath := LIVE_DIR + "/responses/response_" + req_id + ".json"
	if not FileAccess.file_exists(rpath):
		_write_handshake("THINKING")
		return
	var got := _read_json(rpath)
	var data: Dictionary = got.get("data", {}) if bool(got.get("ok", false)) else {}
	var ok_file := bool(got.get("ok", false)) \
		and str(data.get("request_id", "")) == req_id \
		and str(data.get("session", "")) == _session \
		and not str(data.get("response_text", "")).strip_edges().is_empty()
	if not ok_file:
		_counts["stale_rejected"] += 1
		_archive(rpath, "stale")
		_write_handshake("THINKING",
			"stale response rejected for %s (want session %s)" % [req_id, _session])
		print("[WorkerLink] STALE response rejected req=%s" % req_id)
		return
	var rtext := str(data.get("response_text", ""))
	var sub := {"ok": false, "code": "SUBMIT_ERROR", "detail": "empty"}
	if kind == "REVIEW":
		sub = _ctl.call("agent_submit_review", rtext)
	else:
		sub = _ctl.call("agent_submit_initial", rtext)
	_submitted[req_id] = true
	_counts["submitted"] += 1
	_last_submission = {"request_id": req_id, "kind": kind,
		"ok": bool(sub.get("ok", false)), "code": str(sub.get("code", "")),
		"detail": str(sub.get("detail", "")).left(200)}
	_archive(rpath, "done")
	_write_json(LIVE_DIR + "/pending.json", {"request_id": null, "session": _session})
	_write_handshake("SUBMITTED")
	print("[WorkerLink] SUBMIT req=%s kind=%s ok=%s code=%s" % [
		req_id, kind, str(bool(sub.get("ok", false))), str(sub.get("code", ""))])


func _check_timeout_cleared() -> void:
	# Parked cleared with no poller submission: engine timeout/supersede.
	if _last_req.is_empty() or _submitted.has(_last_req):
		if _last_req.is_empty():
			return
		_last_req = ""
		_write_handshake("LISTENING")
		return
	if not _dumped.has(_last_req):
		_last_req = ""
		return
	_counts["timeouts"] += 1
	_last_timeout = {"request_id": _last_req, "kind": _last_kind, "turn": _last_turn}
	_write_json(LIVE_DIR + "/pending.json", {"request_id": null, "session": _session})
	_write_handshake("TIMED_OUT")
	print("[WorkerLink] TIMED_OUT req=%s (worker did not answer in budget; phase holds explicitly, no fallback Brain)" % _last_req)
	_last_req = ""


func _archive(rpath: String, tag: String) -> void:
	var fname := rpath.get_file().replace("response_", tag + "_")
	DirAccess.rename_absolute(ProjectSettings.globalize_path(rpath),
		ProjectSettings.globalize_path(LIVE_DIR + "/responses/" + fname))


func get_status() -> Dictionary:
	var state := "LISTENING"
	if not _channel_ok:
		state = "OFFLINE"
	elif not _last_req.is_empty() and not _submitted.has(_last_req):
		state = "THINKING"
	elif not _last_submission.is_empty() and _last_req.is_empty():
		state = "SUBMITTED"
	return {"channel_ok": _channel_ok, "channel_error": _channel_error,
		"state": state, "session": _session,
		"request_id": _last_req, "kind": _last_kind, "turn": _last_turn,
		"wait_s": int((Time.get_ticks_msec() - _wait_start) / 1000) if not _last_req.is_empty() else 0,
		"last_submission": _last_submission, "last_timeout": _last_timeout,
		"counts": _counts.duplicate()}


func _write_handshake(state: String, note: String = "") -> void:
	_write_json(LIVE_DIR + "/handshake.json", {"status": state, "session": _session,
		"request_id": _last_req if state == "THINKING" else null,
		"kind": _last_kind if state == "THINKING" else "",
		"wait_s": int((Time.get_ticks_msec() - _wait_start) / 1000) if state == "THINKING" else 0,
		"last_submission": _last_submission, "last_timeout": _last_timeout,
		"counts": _counts, "note": note,
		"updated": Time.get_datetime_string_from_system()})


func _write_json(path: String, doc: Variant) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(doc, "  "))
	f.close()
	return true


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"ok": false}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {"ok": false}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if parsed is Dictionary:
		return {"ok": true, "data": parsed}
	return {"ok": false}
