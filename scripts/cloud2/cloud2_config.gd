class_name Cloud2Config
extends RefCounted

## CLOUD-GENERAL STEP 2 — Cloud connection configuration (runtime only).
##
## Holds the provider/model/endpoint/timeout selected by the human in the
## in-game CLOUD CONNECTION panel. The API key lives in memory only, is never
## written to disk, never logged, and never placed in a turn packet.
##
## Persistence: SESSION ONLY by default. The explicit SAVE opt-in persists
## provider/model/endpoint/timeout to user:// (outside the repository);
## the key is NEVER persisted. No encryption is claimed.

const OpenCodeCls = preload("res://scripts/cloud2/cloud2_opencode.gd")
const AIConfigCls = preload("res://scripts/ai/ai_backend_config.gd")

const TRANSPORT_OPENAI := "openai_chat"
const TRANSPORT_ANTHROPIC := "anthropic_messages"
const TRANSPORT_RESPONSES := "openai_responses"
## Placeholder transport for the opencode provider before a model resolves;
## never sent on the wire (effective_transport() returns the resolved one).
const TRANSPORT_OPENCODE_ROUTED := "opencode_routed"

const OPENCODE_ID := "opencode"

const SAVE_PATH := "user://cloud2_connection.cfg"

## Provider-neutral endpoint table. Every entry is either OpenAI-compatible
## chat-completions or Anthropic messages; the adapter owns the wire shape.
const PROVIDERS := {
	"openai": {
		"label": "OpenAI",
		"transport": "openai_chat",
		"endpoint": "https://api.openai.com/v1/chat/completions",
		"needs_key": true,
		"models": ["gpt-4o-mini", "gpt-4o", "o4-mini"],
	},
	"anthropic": {
		"label": "Anthropic",
		"transport": "anthropic_messages",
		"endpoint": "https://api.anthropic.com/v1/messages",
		"needs_key": true,
		"models": ["claude-sonnet-4-5", "claude-haiku-4-5", "claude-opus-4-1"],
	},
	"openrouter": {
		"label": "OpenRouter",
		"transport": "openai_chat",
		"endpoint": "https://openrouter.ai/api/v1/chat/completions",
		"needs_key": true,
		"models": ["anthropic/claude-sonnet-4-5", "openai/gpt-4o-mini"],
	},
	"groq": {
		"label": "Groq",
		"transport": "openai_chat",
		"endpoint": "https://api.groq.com/openai/v1/chat/completions",
		"needs_key": true,
		"models": ["llama-3.3-70b-versatile", "llama-3.1-8b-instant"],
	},
	"mistral": {
		"label": "Mistral",
		"transport": "openai_chat",
		"endpoint": "https://api.mistral.ai/v1/chat/completions",
		"needs_key": true,
		"models": ["mistral-large-latest", "mistral-small-latest"],
	},
	"deepseek": {
		"label": "DeepSeek",
		"transport": "openai_chat",
		"endpoint": "https://api.deepseek.com/chat/completions",
		"needs_key": true,
		"models": ["deepseek-chat", "deepseek-reasoner"],
	},
	"nvidia": {
		"label": "NVIDIA NIM",
		"transport": "openai_chat",
		"endpoint": "https://integrate.api.nvidia.com/v1/chat/completions",
		"needs_key": true,
		"models": ["meta/llama-3.3-70b-instruct"],
	},
	"google": {
		"label": "Google (OpenAI-compat)",
		"transport": "openai_chat",
		"endpoint": "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions",
		"needs_key": true,
		"models": ["gemini-2.5-flash", "gemini-2.5-pro"],
	},
	"ollama": {
		"label": "Ollama (local)",
		"transport": "openai_chat",
		"endpoint": "http://127.0.0.1:11434/v1/chat/completions",
		"needs_key": false,
		"models": ["qwen3:8b", "llama3.1:8b"],
	},
	## Local Qwen3-8B Contract-SFT Brain (CSFT5), served by the Godot-owned
	## loopback worker (Cloud2LocalBrainLauncher). Default + only provider of
	## the "DEV: Human vs Local (Qwen 8B)" mode. Keyless, loopback only.
	"local_qwen8b": {
		"label": "Local Qwen3-8B (CSFT5)",
		"transport": "openai_chat",
		"endpoint": "http://127.0.0.1:8096/v1/chat/completions",
		"needs_key": false,
		"models": ["csft5"],
	},
	"opencode": {
		"label": "OpenCode Go",
		"transport": "opencode_routed",
		"endpoint": "",
		"needs_key": true,
		"models": [],
	},
	"custom": {
		"label": "Custom (OpenAI-compat)",
		"transport": "openai_chat",
		"endpoint": "",
		"needs_key": true,
		"models": [""],
	},
}

const STATUS_DISCONNECTED := "DISCONNECTED"
const STATUS_TESTING := "TESTING"
const STATUS_CONNECTED := "CONNECTED"
const STATUS_ERROR := "ERROR"

var provider_id := ""
var model := ""
var endpoint := ""
var api_key := "" # memory only; never persisted, never logged, never in packets
var timeout_sec := 60.0
var connection_status := STATUS_DISCONNECTED
var connection_note := ""
var connection_tested := false
var save_local := false
## OpenCode Go per-model routing (memory only except the manual override):
## resolved_transport is "" until the model resolves to a protocol family.
## discovered_models holds the last GET /models result: [{id, name, raw}].
var resolved_transport := ""
var protocol_source := ""
var protocol_override := ""
var discovered_models: Array = []


static func provider_ids() -> Array:
	var out: Array = PROVIDERS.keys()
	out.sort()
	return out


static func provider_label(pid: String) -> String:
	if PROVIDERS.has(pid):
		return str((PROVIDERS[pid] as Dictionary).get("label", pid))
	return pid


static func default_endpoint_for(pid: String) -> String:
	if PROVIDERS.has(pid):
		return str((PROVIDERS[pid] as Dictionary).get("endpoint", ""))
	return ""


static func transport_for(pid: String) -> String:
	if PROVIDERS.has(pid):
		return str((PROVIDERS[pid] as Dictionary).get("transport", TRANSPORT_OPENAI))
	return TRANSPORT_OPENAI


static func needs_key_for(pid: String) -> bool:
	if PROVIDERS.has(pid):
		return bool((PROVIDERS[pid] as Dictionary).get("needs_key", true))
	return true


static func default_models_for(pid: String) -> Array:
	if PROVIDERS.has(pid):
		return ((PROVIDERS[pid] as Dictionary).get("models", []) as Array).duplicate()
	return []


## Trim only accidental edge whitespace/CRLF pasted with the key.
## Characters inside the key are never altered.
static func clean_key(raw: String) -> String:
	return raw.strip_edges(true, true)


func set_provider(pid: String) -> void:
	provider_id = pid.strip_edges().to_lower()
	endpoint = default_endpoint_for(provider_id)
	connection_tested = false
	connection_status = STATUS_DISCONNECTED
	connection_note = ""
	resolved_transport = ""
	protocol_source = ""
	protocol_override = ""
	discovered_models = []
	if provider_id == OPENCODE_ID:
		_resolve_opencode()


func set_model(m: String) -> void:
	if model != m.strip_edges():
		connection_tested = false
		if connection_status == STATUS_CONNECTED:
			connection_status = STATUS_DISCONNECTED
	model = m.strip_edges()
	if provider_id == OPENCODE_ID:
		_resolve_opencode()


## Store a GET /models discovery result and re-resolve the current model
## against its metadata first, known table second.
func set_discovered_models(models: Array) -> void:
	discovered_models = models.duplicate(true)
	if provider_id == OPENCODE_ID:
		var before := resolved_transport
		_resolve_opencode()
		if resolved_transport != before:
			connection_tested = false
			if connection_status == STATUS_CONNECTED:
				connection_status = STATUS_DISCONNECTED


## Advanced manual protocol override for OpenCode Go ("" = Auto).
## Accepts the three wire transports; anything else clears to Auto.
func set_protocol_override(t: String) -> void:
	var want := t.strip_edges().to_lower()
	if want != TRANSPORT_OPENAI and want != TRANSPORT_ANTHROPIC and want != TRANSPORT_RESPONSES:
		want = ""
	if protocol_override != want:
		protocol_override = want
		if provider_id == OPENCODE_ID:
			_resolve_opencode()
			connection_tested = false
			if connection_status == STATUS_CONNECTED:
				connection_status = STATUS_DISCONNECTED


func opencode_metadata_by_id() -> Dictionary:
	var out := {}
	for m_val in discovered_models:
		if not m_val is Dictionary:
			continue
		var m: Dictionary = m_val
		var mid := str(m.get("id", "")).strip_edges()
		if mid.is_empty():
			continue
		out[mid.to_lower()] = m.get("raw", m)
	return out


func is_opencode() -> bool:
	return provider_id == OPENCODE_ID


func is_protocol_resolved() -> bool:
	if provider_id != OPENCODE_ID:
		return true
	return not resolved_transport.is_empty()


## The transport the adapter must speak for the current provider+model.
## For OpenCode Go this is the per-model resolution ("" = unresolved).
func effective_transport() -> String:
	if provider_id == OPENCODE_ID:
		return resolved_transport
	return transport_for(provider_id)


## Resolve the OpenCode Go model to a protocol family + full endpoint URL.
## Unknown models leave the endpoint EMPTY so no request can misroute.
func _resolve_opencode() -> void:
	resolved_transport = ""
	protocol_source = ""
	endpoint = ""
	if model.strip_edges().is_empty():
		return
	if not protocol_override.is_empty():
		resolved_transport = protocol_override
		protocol_source = "manual-override"
		endpoint = OpenCodeCls.endpoint_for(protocol_override)
		return
	var res := OpenCodeCls.resolve(model, opencode_metadata_by_id())
	if bool(res.get("ok", false)):
		resolved_transport = str(res.get("transport", ""))
		protocol_source = str(res.get("source", ""))
		endpoint = str(res.get("endpoint", ""))


func set_endpoint(e: String) -> void:
	if provider_id == OPENCODE_ID:
		_resolve_opencode() # endpoint is derived per model; never hand-set
		return
	if endpoint != e.strip_edges():
		connection_tested = false
		if connection_status == STATUS_CONNECTED:
			connection_status = STATUS_DISCONNECTED
	endpoint = e.strip_edges()


func set_api_key(raw: String) -> void:
	var cleaned := clean_key(raw)
	if cleaned != api_key:
		connection_tested = false
		if connection_status == STATUS_CONNECTED:
			connection_status = STATUS_DISCONNECTED
	api_key = cleaned


func has_key() -> bool:
	return not api_key.is_empty()


func redacted_key() -> String:
	if api_key.is_empty():
		return "(empty)"
	if api_key.length() <= 4:
		return "****"
	return "****" + api_key.right(4)


## Deterministic identity of the effective config the adapter consumes:
## provider|model|protocol|endpoint|tested. Displayed in DEV + Lab so any
## stale-config drift is immediately visible. Never contains the key.
func fingerprint() -> String:
	var proto := effective_transport()
	if proto.is_empty():
		proto = "?"
	return "%s|%s|%s|%s|%s" % [provider_id, model, proto,
		endpoint, "tested" if connection_tested else "untested"]


## Read-only effective snapshot for the Lab display block. Built from THIS
## object — the same one the adapter consumes. Never contains the key.
func effective_snapshot() -> Dictionary:
	return {
		"provider": provider_id,
		"provider_label": provider_label(provider_id),
		"model": model,
		"protocol": effective_transport(),
		"protocol_source": protocol_source,
		"endpoint": endpoint,
		"connection": connection_status,
		"tested": connection_tested,
		"has_key": has_key(),
		"fingerprint": fingerprint(),
	}


func is_configured() -> bool:
	if provider_id.is_empty() or model.is_empty() or endpoint.is_empty():
		return false
	if not (endpoint.begins_with("http://") or endpoint.begins_with("https://")):
		return false
	if needs_key_for(provider_id) and api_key.is_empty():
		return false
	return true


## Start gating: provider + model + endpoint + key + a passed connection test.
## OpenCode Go additionally requires a resolved model protocol. There is no
## silent fallback: an unresolved model gates as UNSUPPORTED_PROTOCOL.
func validate_for_start() -> Dictionary:
	if provider_id == OPENCODE_ID:
		if model.strip_edges().is_empty():
			return {"ok": false, "code": "CLOUD_NOT_CONFIGURED",
				"detail": "Choose an OpenCode Go model before Cloud turns can start."}
		if api_key.strip_edges().is_empty():
			return {"ok": false, "code": "CLOUD_NOT_CONFIGURED",
				"detail": "Paste the OpenCode Go API key before Cloud turns can start."}
		if resolved_transport.is_empty():
			return {"ok": false, "code": "UNSUPPORTED_PROTOCOL",
				"detail": "Model '%s' has an unknown OpenCode Go API protocol. Refresh models or set an Advanced protocol override." % model}
		if endpoint.strip_edges().is_empty():
			return {"ok": false, "code": "CLOUD_NOT_CONFIGURED",
				"detail": "No resolved OpenCode Go endpoint for model '%s'." % model}
		if not connection_tested or connection_status != STATUS_CONNECTED:
			return {"ok": false, "code": "CONNECTION_NOT_TESTED",
				"detail": "Press Test Connection and wait for CONNECTED before Cloud turns can start."}
		return {"ok": true, "code": "", "detail": ""}
	if not is_configured():
		return {"ok": false, "code": "CLOUD_NOT_CONFIGURED",
			"detail": "Provider, model, endpoint, and API key are required before Cloud turns can start."}
	if not connection_tested or connection_status != STATUS_CONNECTED:
		return {"ok": false, "code": "CONNECTION_NOT_TESTED",
			"detail": "Press Test Connection and wait for CONNECTED before Cloud turns can start."}
	return {"ok": true, "code": "", "detail": ""}


func mark_test_result(ok: bool, status: String, note: String = "") -> void:
	connection_tested = ok
	connection_status = status
	connection_note = note


## Safe for UI/logs: never contains the key.
func to_safe_dict() -> Dictionary:
	return {
		"provider": provider_id,
		"provider_label": provider_label(provider_id),
		"model": model,
		"endpoint": endpoint,
		"transport": effective_transport(),
		"protocol_source": protocol_source,
		"protocol_override": protocol_override,
		"discovered_models": discovered_models.size(),
		"timeout_sec": timeout_sec,
		"has_key": has_key(),
		"key": redacted_key(),
		"connection_status": connection_status,
		"connection_note": connection_note,
		"connection_tested": connection_tested,
	}


## Explicit opt-in persistence of NON-SECRET fields only (user://, untracked).
## The API key is never written.
func save_local_settings() -> Dictionary:
	var cfg := ConfigFile.new()
	cfg.set_value("cloud2", "provider", provider_id)
	cfg.set_value("cloud2", "model", model)
	cfg.set_value("cloud2", "endpoint", endpoint)
	cfg.set_value("cloud2", "timeout_sec", timeout_sec)
	cfg.set_value("cloud2", "protocol_override", protocol_override)
	cfg.set_value("cloud2", "note", "API key is never stored. Session key only.")
	var err := cfg.save(SAVE_PATH)
	if err != OK:
		return {"ok": false, "detail": "Could not write %s (err=%d)." % [SAVE_PATH, err]}
	return {"ok": true, "detail": "Saved provider/model/endpoint (key never stored)."}


func load_local_settings() -> Dictionary:
	var cfg := ConfigFile.new()
	if cfg.load(SAVE_PATH) != OK:
		return {"ok": false, "detail": "No saved connection."}
	set_provider(str(cfg.get_value("cloud2", "provider", "")))
	set_protocol_override(str(cfg.get_value("cloud2", "protocol_override", "")))
	set_endpoint(str(cfg.get_value("cloud2", "endpoint", "")))
	set_model(str(cfg.get_value("cloud2", "model", "")))
	timeout_sec = float(cfg.get_value("cloud2", "timeout_sec", 60.0))
	connection_tested = false
	connection_status = STATUS_DISCONNECTED
	return {"ok": true, "detail": "Loaded saved provider/model/endpoint (key still required)."}


## Pull the shared AI Settings runtime into this connection (additive).
## Applies ONLY when the AI backend runtime is OpenCode Go; otherwise this
## is a no-op and saved/local values stand. The session key travels
## memory-to-memory and is never written anywhere by this call.
## Returns {applied, detail}.
func apply_ai_backend_runtime() -> Dictionary:
	var cur: Dictionary = AIConfigCls.current()
	if str(cur.get("backend_type", "")) != AIConfigCls.BACKEND_OPENCODE_GO:
		return {"applied": false, "detail": "AI backend is not OpenCode Go; local values stand."}
	var rmodel := str(cur.get("model", "")).strip_edges()
	if rmodel.is_empty():
		return {"applied": false, "detail": "AI runtime carries no OpenCode Go model."}
	set_provider(OPENCODE_ID)
	set_protocol_override(str(cur.get("opencode_override", "")))
	set_model(rmodel)
	set_api_key(AIConfigCls.get_api_key())
	if bool(cur.get("opencode_tested", false)) and has_key() and is_protocol_resolved():
		mark_test_result(true, STATUS_CONNECTED, "Carried from AI Settings (session key).")
	return {"applied": true, "protocol": resolved_transport, "source": protocol_source,
		"tested": connection_tested, "detail": "OpenCode Go runtime applied."}
