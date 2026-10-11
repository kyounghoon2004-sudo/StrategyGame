class_name Step7SemanticModelManager
extends Node

## Zero-manual-setup lifecycle for the SEMANTIC role model.
##
## START GAME -> check Ollama tag -> if missing: download GGUF (chunked,
## resumable, progress) -> verify size -> write Modelfile -> `ollama create`
## -> warm into VRAM -> SEMANTIC READY. Second launch: tag present -> warm
## only, no download.
##
## Any failure is NON-FATAL: the game stays playable through the existing
## large-model semantic path (fail closed, large fallback). Report via
## finished(ok, info) with kind/player/dev fields.
##
## No inference here (the frontend owns calls). No tactical role here.

signal state_changed(state_name: String, player_text: String)
signal download_progress(downloaded_bytes: int, total_bytes: int)
signal finished(ok: bool, info: Dictionary)

enum State { IDLE, CHECKING_TAG, DOWNLOADING, VERIFYING, REGISTERING, WARMING, READY, FAILED }

const STATE_NAMES := ["IDLE", "CHECKING_TAG", "DOWNLOADING", "VERIFYING",
	"REGISTERING", "WARMING", "READY", "FAILED"]

const ModelScript = preload("res://scripts/step7/step7_semantic_model.gd")

const CHUNK_BYTES := 33554432 # 32 MiB per Range request (progress + resume).
const CHUNK_TIMEOUT_SEC := 120.0
const TAGS_TIMEOUT_SEC := 8.0
const REGISTER_TIMEOUT_SEC := 600.0
const POLL_SEC := 1.0

var state: int = State.IDLE
var last_error_kind := ""
var last_player_message := ""
var last_info: Dictionary = {}

var _session := 0
var _endpoint := "http://127.0.0.1:11434"
var _keep_alive := "12h"
var _warmup_timeout := 300.0
var _t0 := 0
var _lat: Dictionary = {}
var _downloaded := 0
var _tag_was_present := false
var _created_by_game := false


func state_name(s: int = -1) -> String:
	var idx := state if s < 0 else s
	if idx >= 0 and idx < STATE_NAMES.size():
		return str(STATE_NAMES[idx])
	return "UNKNOWN"


func is_busy() -> bool:
	return state != State.IDLE and state != State.READY and state != State.FAILED


func cancel() -> void:
	_session += 1
	_set_state(State.IDLE, "")


func dev_snapshot() -> Dictionary:
	var m := ModelScript.describe()
	m["state"] = state_name()
	m["tag_was_present"] = _tag_was_present
	m["created_by_game"] = _created_by_game
	m["downloaded_bytes"] = _downloaded
	m["latencies_ms"] = _lat.duplicate()
	m["last_error"] = last_error_kind
	m["cache_ok"] = (verify_cache().get("ok", false))
	return m


static func is_tag_present(models: Array) -> bool:
	return ModelScript.OLLAMA_TAG in models


## Size-integrity gate over the cached GGUF (upstream byte size ± slack).
static func verify_cache() -> Dictionary:
	var p := ModelScript.gguf_path_global()
	if not FileAccess.file_exists(p):
		return {"ok": false, "bytes": 0, "why": "ABSENT"}
	var sz := -1
	var f := FileAccess.open(p, FileAccess.READ)
	if f != null:
		sz = int(f.get_length())
		f.close()
	if sz < 0:
		return {"ok": false, "bytes": 0, "why": "UNREADABLE"}
	var lo := ModelScript.EXPECTED_BYTES - ModelScript.SIZE_TOLERANCE_BYTES
	var hi := ModelScript.EXPECTED_BYTES + ModelScript.SIZE_TOLERANCE_BYTES
	if sz < lo or sz > hi:
		return {"ok": false, "bytes": sz, "why": "SIZE_MISMATCH"}
	return {"ok": true, "bytes": sz, "why": ""}


func ensure_async(cfg: Dictionary) -> void:
	_session += 1
	var my := _session
	_endpoint = str(cfg.get("endpoint", _endpoint)).strip_edges().trim_suffix("/")
	_keep_alive = str(cfg.get("keep_alive", _keep_alive)).strip_edges()
	_warmup_timeout = clampf(float(cfg.get("warmup_timeout_sec", _warmup_timeout)), 30.0, 600.0)
	_lat = {}
	last_error_kind = ""
	last_player_message = ""
	_tag_was_present = false
	_created_by_game = false
	_downloaded = 0
	_t0 = Time.get_ticks_msec()
	# 1) Tag already registered? Warm only (fast second launch).
	_set_state(State.CHECKING_TAG, "의미 모델 확인 중...")
	var t0 := Time.get_ticks_msec()
	var tags := await _http_get_tags(my)
	if not _alive(my):
		return
	_lat["tag_check_ms"] = Time.get_ticks_msec() - t0
	if not bool(tags.get("ok", false)):
		_fail(my, "OFFLINE", "AI 서버에 연결할 수 없어 의미 모델을 확인하지 못했습니다.")
		return
	if is_tag_present(tags.get("models", [])):
		_tag_was_present = true
		await _warm(my)
		return
	# 2) Cache present + intact? Skip download.
	_set_state(State.VERIFYING, "의미 모델 파일 확인 중...")
	var vc := verify_cache()
	if bool(vc.get("ok", false)):
		_downloaded = int(vc.get("bytes", 0))
		download_progress.emit(_downloaded, ModelScript.EXPECTED_BYTES)
		await _register(my)
		return
	# Stale/corrupt cache: drop it and fetch fresh (never trust half bytes
	# whose size already exceeds upstream — likely a different artifact).
	if str(vc.get("why", "")) == "SIZE_MISMATCH" and int(vc.get("bytes", 0)) > ModelScript.EXPECTED_BYTES + ModelScript.SIZE_TOLERANCE_BYTES:
		_remove_path(ModelScript.gguf_path_global())
		_remove_path(ModelScript.part_path())
	# 3) Download (resumable chunks), then register + warm.
	await _download(my)


func _download(my: int) -> void:
	if not _alive(my):
		return
	_ensure_cache_dir()
	_set_state(State.DOWNLOADING, "의미 모델 다운로드 중... (약 %d MB, 최초 1회)" % int(ModelScript.expected_mb()))
	var t0 := Time.get_ticks_msec()
	var r := await _download_chunked(my)
	if not _alive(my):
		return
	_lat["download_ms"] = Time.get_ticks_msec() - t0
	if not bool(r.get("ok", false)):
		_fail(my, str(r.get("kind", "DOWNLOAD_FAILED")), str(r.get("player", "의미 모델 다운로드에 실패했습니다.")))
		return
	_set_state(State.VERIFYING, "의미 모델 무결성 확인 중...")
	var vc := verify_cache()
	if not bool(vc.get("ok", false)):
		_fail(my, "SIZE_MISMATCH", "다운로드한 의미 모델 파일 크기가 일치하지 않습니다. 다시 시도하십시오.")
		return
	await _register(my)


## Chunked GET with Range resume over the .part file. Emits progress per
## chunk. Returns {ok} or {ok:false, kind, player}.
func _download_chunked(my: int) -> Dictionary:
	var url := ModelScript.hf_url()
	var part := ModelScript.part_path()
	var have := _file_size(part)
	if have < 0:
		have = 0
	_downloaded = have
	download_progress.emit(_downloaded, ModelScript.EXPECTED_BYTES)
	var restarted := false
	while _downloaded < ModelScript.EXPECTED_BYTES:
		if not _alive(my):
			return {"ok": false, "kind": "CANCELLED", "player": ""}
		var stop := mini(_downloaded + CHUNK_BYTES - 1, ModelScript.EXPECTED_BYTES - 1)
		var got := await _http_get_range(my, url, _downloaded, stop)
		if not _alive(my):
			return {"ok": false, "kind": "CANCELLED", "player": ""}
		var code := int(got.get("http_status", 0))
		if code == 200 and not restarted and _downloaded > 0:
			# Server ignored Range: restart cleanly once (never append a
			# full body onto a prefix).
			restarted = true
			_remove_path(part)
			_downloaded = 0
			download_progress.emit(0, ModelScript.EXPECTED_BYTES)
			continue
		if code != 200 and code != 206:
			var kind := "OFFLINE" if int(got.get("transport_error", 0)) != 0 else "DOWNLOAD_FAILED"
			return {"ok": false, "kind": kind,
				"player": "의미 모델 다운로드 중 연결이 끊겼습니다. 다시 시도하면 이어받습니다."}
		var body: PackedByteArray = got.get("body", PackedByteArray())
		if body.is_empty():
			return {"ok": false, "kind": "DOWNLOAD_FAILED",
				"player": "의미 모델 다운로드가 비어 있습니다. 다시 시도하십시오."}
		if not _append_bytes(part, body):
			return {"ok": false, "kind": "DOWNLOAD_FAILED",
				"player": "의미 모델을 저장할 수 없습니다. 디스크 공간을 확인하십시오."}
		_downloaded += body.size()
		download_progress.emit(_downloaded, ModelScript.EXPECTED_BYTES)
	# Promote .part -> final atomically (same dir rename).
	if _file_size(part) != _file_size(ModelScript.gguf_path()) or not FileAccess.file_exists(ModelScript.gguf_path_global()):
		_remove_path(ModelScript.gguf_path_global())
		var err := DirAccess.rename_absolute(part, ModelScript.gguf_path_global())
		if err != OK:
			# Fallback: part already complete — accept it in place.
			DirAccess.rename_absolute(part, ModelScript.gguf_path_global())
	return {"ok": true}


func _register(my: int) -> void:
	if not _alive(my):
		return
	_set_state(State.REGISTERING, "의미 모델 등록 중... (최초 1회)")
	var t0 := Time.get_ticks_msec()
	_write_modelfile()
	var exe := _discover_ollama_exe()
	if exe.is_empty():
		_fail(my, "EXE_NOT_FOUND", "Ollama 실행 파일을 찾을 수 없습니다.")
		return
	OS.create_process(exe, PackedStringArray(["create", ModelScript.OLLAMA_TAG, "-f", ModelScript.modelfile_path_global()]), false)
	var ok := await _poll_tag(my)
	if not _alive(my):
		return
	_lat["register_ms"] = Time.get_ticks_msec() - t0
	if not ok:
		_fail(my, "REGISTER_TIMEOUT", "의미 모델 등록이 시간 초과되었습니다. 다시 시도하십시오.")
		return
	_created_by_game = true
	await _warm(my)


func _warm(my: int) -> void:
	if not _alive(my):
		return
	_set_state(State.WARMING, "의미 모델을 VRAM에 올리는 중...")
	var t0 := Time.get_ticks_msec()
	var w := await _chat_once(my, "Reply with exactly: READY.", 8)
	_lat["warmup_ms"] = Time.get_ticks_msec() - t0
	if not _alive(my):
		return
	if not bool(w.get("ok", false)):
		_fail(my, str(w.get("kind", "WARMUP_FAILED")), "의미 모델을 불러오지 못했습니다. 대형 모델로 계속합니다.")
		return
	_lat["total_ms"] = Time.get_ticks_msec() - _t0
	_set_state(State.READY, "의미 모델 준비 완료")
	last_info = {
		"ok": true, "tag": ModelScript.OLLAMA_TAG,
		"tag_was_present": _tag_was_present,
		"created_by_game": _created_by_game,
		"artifact": ModelScript.HF_FILE, "quant": ModelScript.QUANT_LABEL,
		"repo": ModelScript.HF_GGUF_REPO,
		"warm_ready_token": bool(w.get("ready_seen", false)),
		"latencies_ms": _lat.duplicate(),
		"dev": dev_snapshot(),
	}
	finished.emit(true, last_info.duplicate(true))


# --- HTTP primitives ----------------------------------------------------

func _http_get_tags(my: int) -> Dictionary:
	var http := HTTPRequest.new()
	http.timeout = TAGS_TIMEOUT_SEC
	add_child(http)
	var err := http.request(_endpoint + "/api/tags", PackedStringArray(["Accept: application/json"]), HTTPClient.METHOD_GET)
	if err != OK:
		http.queue_free()
		return {"ok": false, "transport_error": err, "http_status": 0}
	var res: Array = await http.request_completed
	if not _alive(my) or not is_instance_valid(http):
		if is_instance_valid(http):
			http.queue_free()
		return {"ok": false, "cancelled": true}
	http.queue_free()
	if res.size() < 4:
		return {"ok": false, "transport_error": -2, "http_status": 0}
	if int(res[0]) != HTTPRequest.RESULT_SUCCESS:
		return {"ok": false, "transport_error": int(res[0]), "http_status": 0}
	var code := int(res[1])
	if code < 200 or code >= 300:
		return {"ok": false, "transport_error": 0, "http_status": code}
	var out: Array = []
	var parsed: Variant = JSON.parse_string((res[3] as PackedByteArray).get_string_from_utf8())
	if parsed is Dictionary:
		for m in ((parsed as Dictionary).get("models", []) as Array):
			if m is Dictionary and str((m as Dictionary).get("name", "")).length() > 0:
				out.append(str((m as Dictionary).get("name", "")))
	out.sort()
	return {"ok": true, "http_status": code, "models": out}


func _http_get_range(my: int, url: String, start: int, stop: int) -> Dictionary:
	var http := HTTPRequest.new()
	http.timeout = CHUNK_TIMEOUT_SEC
	http.body_size_limit = CHUNK_BYTES + 1048576
	add_child(http)
	var headers := PackedStringArray(["Accept: application/octet-stream",
		"Range: bytes=%d-%d" % [start, stop]])
	var err := http.request(url, headers, HTTPClient.METHOD_GET)
	if err != OK:
		http.queue_free()
		return {"transport_error": err, "http_status": 0}
	var res: Array = await http.request_completed
	if not _alive(my) or not is_instance_valid(http):
		if is_instance_valid(http):
			http.queue_free()
		return {"transport_error": -1, "http_status": 0, "cancelled": true}
	http.queue_free()
	if res.size() < 4:
		return {"transport_error": -2, "http_status": 0}
	var gr := int(res[0])
	var code := int(res[1])
	var body := res[3] as PackedByteArray
	if gr != HTTPRequest.RESULT_SUCCESS:
		return {"transport_error": gr, "http_status": 0}
	return {"transport_error": 0, "http_status": code, "body": body}


func _poll_tag(my: int) -> bool:
	var deadline := Time.get_ticks_msec() + int(REGISTER_TIMEOUT_SEC * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if not _alive(my):
			return false
		var r := await _http_get_tags(my)
		if not _alive(my):
			return false
		if bool(r.get("ok", false)) and is_tag_present(r.get("models", [])):
			return true
		await get_tree().create_timer(POLL_SEC).timeout
		if not is_inside_tree():
			return false
	return false


func _chat_once(my: int, user_text: String, num_predict: int) -> Dictionary:
	var http := HTTPRequest.new()
	http.timeout = maxf(10.0, _warmup_timeout)
	http.body_size_limit = 262144
	add_child(http)
	var payload := {
		"model": ModelScript.OLLAMA_TAG,
		"stream": false,
		"keep_alive": _keep_alive,
		"think": false,
		"options": {"temperature": 0.0, "num_predict": num_predict, "num_ctx": 512},
		"messages": [
			{"role": "system", "content": "You are a local game preload endpoint."},
			{"role": "user", "content": user_text},
		],
	}
	var err := http.request(_endpoint + "/api/chat",
		PackedStringArray(["Content-Type: application/json"]),
		HTTPClient.METHOD_POST, JSON.stringify(payload))
	if err != OK:
		http.queue_free()
		return {"ok": false, "kind": "OFFLINE"}
	var res: Array = await http.request_completed
	if not _alive(my) or not is_instance_valid(http):
		if is_instance_valid(http):
			http.queue_free()
		return {"ok": false, "kind": "CANCELLED"}
	http.queue_free()
	if res.size() < 4:
		return {"ok": false, "kind": "BAD_RESPONSE"}
	var gr := int(res[0])
	var code := int(res[1])
	if gr == HTTPRequest.RESULT_TIMEOUT or gr == HTTPRequest.RESULT_REQUEST_FAILED:
		return {"ok": false, "kind": "WARMUP_TIMEOUT"}
	if gr != HTTPRequest.RESULT_SUCCESS:
		return {"ok": false, "kind": "OFFLINE"}
	if code == 404:
		return {"ok": false, "kind": "MODEL_MISSING"}
	if code < 200 or code >= 300:
		return {"ok": false, "kind": "HTTP_ERROR"}
	var parsed: Variant = JSON.parse_string((res[3] as PackedByteArray).get_string_from_utf8())
	if not parsed is Dictionary:
		return {"ok": false, "kind": "BAD_RESPONSE"}
	var msg: Variant = (parsed as Dictionary).get("message", {})
	if not msg is Dictionary:
		return {"ok": false, "kind": "BAD_RESPONSE"}
	var content := str((msg as Dictionary).get("content", ""))
	if content.strip_edges().is_empty():
		return {"ok": false, "kind": "BAD_RESPONSE"}
	return {"ok": true, "kind": "", "ready_seen": content.to_upper().contains("READY")}


# --- Files / process -----------------------------------------------------

func _ensure_cache_dir() -> void:
	DirAccess.make_dir_recursive_absolute(ModelScript.cache_dir())


func _file_size(path_global_or_user: String) -> int:
	var p := path_global_or_user
	if p.begins_with("user://"):
		p = ProjectSettings.globalize_path(p)
	if not FileAccess.file_exists(p):
		return -1
	var f := FileAccess.open(p, FileAccess.READ)
	if f == null:
		return -1
	var sz := int(f.get_length())
	f.close()
	return sz


func _file_size_part() -> int:
	return _file_size(ModelScript.part_path())


func _append_bytes(path_global_or_user: String, body: PackedByteArray) -> bool:
	var p := path_global_or_user
	if p.begins_with("user://"):
		p = ProjectSettings.globalize_path(p)
	var f := FileAccess.open(p, FileAccess.READ_WRITE)
	if f == null:
		f = FileAccess.open(p, FileAccess.WRITE_READ)
		if f == null:
			return false
	f.seek_end()
	f.store_buffer(body)
	f.flush()
	f.close()
	return _file_size(p) >= 0


func _remove_path(path_global_or_user: String) -> void:
	var p := path_global_or_user
	if p.begins_with("user://"):
		p = ProjectSettings.globalize_path(p)
	if FileAccess.file_exists(p):
		DirAccess.remove_absolute(p)


func _write_modelfile() -> void:
	_ensure_cache_dir()
	var f := FileAccess.open(ModelScript.modelfile_path_global(), FileAccess.WRITE)
	if f != null:
		f.store_string(ModelScript.modelfile_text())
		f.close()


func _discover_ollama_exe() -> String:
	var local := OS.get_environment("LOCALAPPDATA").strip_edges()
	if not local.is_empty():
		var t := local + "/Programs/Ollama/ollama.exe"
		if FileAccess.file_exists(t):
			return t
	for env in ["PROGRAMFILES", "PROGRAMFILES(X86)", "PROGRAMW6432"]:
		var p := OS.get_environment(env).strip_edges()
		if p.is_empty():
			continue
		var t2 := p + "/Ollama/ollama.exe"
		if FileAccess.file_exists(t2):
			return t2
	for d in OS.get_environment("PATH").split(";"):
		var dir := d.strip_edges().trim_suffix("/").trim_suffix("\\")
		if dir.is_empty():
			continue
		var t3 := dir + "/ollama.exe"
		if FileAccess.file_exists(t3):
			return t3
	return ""


# --- State ---------------------------------------------------------------

func _alive(my: int) -> bool:
	return my == _session


func _set_state(s: int, msg: String) -> void:
	state = s
	state_changed.emit(state_name(s), msg)


func _fail(my: int, kind: String, player_message: String) -> void:
	if not _alive(my):
		return
	last_error_kind = kind
	last_player_message = player_message
	_lat["total_ms"] = Time.get_ticks_msec() - _t0
	_set_state(State.FAILED, player_message)
	last_info = {"ok": false, "error_kind": kind,
		"player_message": player_message,
		"hint": "대형 모델로 계속 플레이할 수 있습니다.",
		"tag": ModelScript.OLLAMA_TAG,
		"latencies_ms": _lat.duplicate(), "dev": dev_snapshot()}
	finished.emit(false, last_info.duplicate(true))
