class_name Cloud2OpenCode
extends RefCounted

## CLOUD-GENERAL STEP 2 — OpenCode Go canonical transport/router.
##
## Single authority for everything OpenCode Go: official endpoint URLs, live
## /models discovery parsing, per-model protocol resolution, and the
## OpenAI-Responses wire shape (the third protocol family next to the
## OpenAI-compatible chat-completions and Anthropic-style messages shapes
## the Cloud2Adapter already speaks).
##
## Protocol resolution order (never silently misroute):
##   1. Metadata returned by GET /models for this exact model id.
##   2. Maintained known-model table (mirrors current OpenCode Go docs).
##   3. Unknown -> UNSUPPORTED_PROTOCOL (UI shows it; Advanced override only).
##
## Secrets: this file never sees the API key. Callers build headers with
## auth_headers()/models_headers() and must never log them.

const BASE_URL := "https://opencode.ai/zen/go/v1"
const MODELS_URL := "https://opencode.ai/zen/go/v1/models"
const CHAT_URL := "https://opencode.ai/zen/go/v1/chat/completions"
const RESPONSES_URL := "https://opencode.ai/zen/go/v1/responses"
const MESSAGES_URL := "https://opencode.ai/zen/go/v1/messages"

const TRANSPORT_CHAT := "openai_chat"
const TRANSPORT_RESPONSES := "openai_responses"
const TRANSPORT_MESSAGES := "anthropic_messages"

## Official client guidance (opencode.ai/docs/go): send a dedicated
## User-Agent (never a generic SDK/HTTP-library name) and a stable
## per-conversation id in x-opencode-session.
const USER_AGENT := "strategy-game-cloud-general/2.0"

static var _session_id := ""


static func session_id() -> String:
	if _session_id.is_empty():
		var rng := RandomNumberGenerator.new()
		rng.randomize()
		var hex := ""
		for i in range(16):
			hex += "%x" % rng.randi_range(0, 15)
		_session_id = hex
	return _session_id

## Known-model protocol table. Routing fallback only — the model DROPDOWN
## itself always comes from live GET /models discovery. Keys are lowercase.
const KNOWN_PROTOCOLS := {
	# OpenAI Responses family.
	"grok-4.5": "openai_responses",
	"grok-4.6": "openai_responses",
	"gpt-5.6-luna": "openai_responses",
	"muse-spark-1.3-contributor": "openai_responses",
	"muse-spark-1.2-contributor": "openai_responses",
	# Anthropic-style messages family.
	"qwen3.8-max": "anthropic_messages",
	"qwen3.8-flash": "anthropic_messages",
	"qwen3.7-max": "anthropic_messages",
	"qwen3.7-plus": "anthropic_messages",
	"qwen3.6-plus": "anthropic_messages",
	"qwen3.5-plus": "anthropic_messages",
	"minimax-m3": "anthropic_messages",
	"minimax-m2.7": "anthropic_messages",
	"minimax-m2.5": "anthropic_messages",
	# OpenAI-compatible chat-completions family.
	"glm-5.3-flash": "openai_chat",
	"glm-5.3": "openai_chat",
	"glm-5.2": "openai_chat",
	"glm-5.1": "openai_chat",
	"glm-5": "openai_chat",
	"kimi-k3": "openai_chat",
	"kimi-k2.7-code": "openai_chat",
	"kimi-k2.6": "openai_chat",
	"kimi-k2.5": "openai_chat",
	"longcat-2.0": "openai_chat",
	"deepseek-v4.1-flash": "openai_chat",
	"deepseek-v4-pro": "openai_chat",
	"deepseek-v4-flash": "openai_chat",
	"deepseek-flash": "openai_chat",
	"deepseek-v4-flash-vision-exp": "openai_chat",
	"mimo-v2.5": "openai_chat",
	"mimo-v2.5-pro": "openai_chat",
	"mimo-v2-pro": "openai_chat",
	"mimo-v2-omni": "openai_chat",
	"hy4-preview": "openai_chat",
	"hy3-preview": "openai_chat",
	"hy3": "openai_chat",
}
## NOTE: union-alpha / omen-alpha are live-catalog ids with no documented
## protocol family; they stay UNSUPPORTED until documented (Advanced
## override remains available). Never prefix-guess unknown families.

## Human-readable names for known models (dropdown display). Discovery
## metadata "name"/"display_name" wins when present; otherwise this table;
## otherwise the raw model id.
const DISPLAY_NAMES := {
	"qwen3.8-max": "Qwen3.8 Max",
	"qwen3.8-flash": "Qwen3.8 Flash",
	"qwen3.7-max": "Qwen3.7 Max",
	"qwen3.7-plus": "Qwen3.7 Plus",
	"qwen3.6-plus": "Qwen3.6 Plus",
	"qwen3.5-plus": "Qwen3.5 Plus",
	"glm-5.3-flash": "GLM-5.3 Flash",
	"glm-5.3": "GLM-5.3",
	"glm-5.2": "GLM-5.2",
	"glm-5.1": "GLM-5.1",
	"glm-5": "GLM-5",
	"kimi-k3": "Kimi K3",
	"kimi-k2.7-code": "Kimi K2.7 Code",
	"kimi-k2.6": "Kimi K2.6",
	"kimi-k2.5": "Kimi K2.5",
	"gpt-5.6-luna": "GPT 5.6 Luna",
	"grok-4.5": "Grok 4.5",
	"grok-4.6": "Grok 4.6",
	"muse-spark-1.3-contributor": "Muse Spark 1.3 Contributor",
	"muse-spark-1.2-contributor": "Muse Spark 1.2 Contributor",
	"minimax-m3": "MiniMax M3",
	"minimax-m2.7": "MiniMax M2.7",
	"minimax-m2.5": "MiniMax M2.5",
	"longcat-2.0": "LongCat 2.0",
	"deepseek-v4.1-flash": "DeepSeek V4.1 Flash",
	"deepseek-v4-pro": "DeepSeek V4 Pro",
	"deepseek-v4-flash": "DeepSeek V4 Flash",
	"deepseek-v4-flash-vision-exp": "DeepSeek V4 Flash Vision Exp",
	"deepseek-flash": "DeepSeek Flash",
	"mimo-v2.5": "MiMo V2.5",
	"mimo-v2.5-pro": "MiMo V2.5 Pro",
	"mimo-v2-pro": "MiMo V2 Pro",
	"mimo-v2-omni": "MiMo V2 Omni",
	"hy4-preview": "Hy4 Preview",
	"hy3-preview": "Hy3 Preview",
	"hy3": "Hy3",
}

const META_KEYS := ["protocol", "api", "api_type", "transport", "endpoint", "url", "family", "type"]


static func endpoint_for(transport: String) -> String:
	match transport:
		TRANSPORT_RESPONSES:
			return RESPONSES_URL
		TRANSPORT_MESSAGES:
			return MESSAGES_URL
		TRANSPORT_CHAT:
			return CHAT_URL
	return ""


static func display_name_for(model_id: String) -> String:
	var key := model_id.strip_edges().to_lower()
	if DISPLAY_NAMES.has(key):
		return str(DISPLAY_NAMES[key])
	var pretty := model_id.strip_edges().replace("_", " ").replace("-", " ")
	if pretty.is_empty():
		return model_id
	return pretty.substr(0, 1).to_upper() + pretty.substr(1)


## Parse a GET /models body. Accepts OpenAI-style {"data": [...]} and
## Ollama-style {"models": [...]} envelopes, plus a bare array.
## Returns {ok, models: [{id, name}], count, code, detail}.
## Never carries secrets: only id/name metadata is kept per model.
static func parse_models_response(text: String) -> Dictionary:
	var parsed: Variant = JSON.parse_string(text.strip_edges())
	var items: Array = []
	if parsed is Dictionary:
		var d: Dictionary = parsed
		if d.get("data") is Array:
			items = d.get("data")
		elif d.get("models") is Array:
			items = d.get("models")
		else:
			return {"ok": false, "models": [], "count": 0, "code": "BAD_RESPONSE",
				"detail": "Models body has neither 'data' nor 'models'."}
	elif parsed is Array:
		items = parsed
	else:
		return {"ok": false, "models": [], "count": 0, "code": "BAD_RESPONSE",
			"detail": "Models body is not JSON."}
	var out: Array = []
	var seen := {}
	for it in items:
		var mid := ""
		var mname := ""
		var raw: Variant = it
		if it is String:
			mid = str(it).strip_edges()
		elif it is Dictionary:
			var dd: Dictionary = it
			mid = str(dd.get("id", dd.get("name", dd.get("model", "")))).strip_edges()
			mname = str(dd.get("name", dd.get("display_name", ""))).strip_edges()
			if mname == mid:
				mname = ""
		if mid.is_empty() or seen.has(mid.to_lower()):
			continue
		seen[mid.to_lower()] = true
		if mname.is_empty():
			mname = display_name_for(mid)
		out.append({"id": mid, "name": mname, "raw": raw})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var an := str(a.get("name", "")).to_lower()
		var bn := str(b.get("name", "")).to_lower()
		if an == bn:
			return str(a.get("id", "")) < str(b.get("id", ""))
		return an < bn)
	return {"ok": true, "models": out, "count": out.size(), "code": "", "detail": ""}


## Inspect one model's /models metadata for protocol hints.
## Returns a transport id, or "" when nothing conclusive is present.
static func protocol_from_metadata(meta: Variant) -> String:
	if not meta is Dictionary:
		return ""
	var d: Dictionary = meta
	# Nested "raw" envelope (as stored by parse_models_response callers).
	if d.has("raw") and d.get("raw") is Dictionary and not _has_meta_keys(d):
		d = d.get("raw")
	var blob := ""
	for k in META_KEYS:
		if d.has(k):
			blob += " " + str(d.get(k)).to_lower()
	blob = blob.strip_edges()
	if blob.is_empty():
		return ""
	if blob.find("responses") != -1:
		return TRANSPORT_RESPONSES
	if blob.find("messages") != -1 or blob.find("anthropic") != -1:
		return TRANSPORT_MESSAGES
	if blob.find("chat") != -1 or blob.find("completion") != -1:
		return TRANSPORT_CHAT
	return ""


static func _has_meta_keys(d: Dictionary) -> bool:
	for k in META_KEYS:
		if d.has(k):
			return true
	return false


## Resolve the transport + endpoint for one model id.
## metadata_by_id: lowercase-id -> raw metadata dict (from discovery).
## Returns {ok, transport, endpoint, source} or
## {ok: false, code: "UNSUPPORTED_PROTOCOL", detail}.
static func resolve(model_id: String, metadata_by_id: Dictionary = {}) -> Dictionary:
	var mid := model_id.strip_edges()
	var key := mid.to_lower()
	if mid.is_empty():
		return {"ok": false, "transport": "", "endpoint": "", "source": "",
			"code": "UNSUPPORTED_PROTOCOL", "detail": "No model selected."}
	var meta: Variant = metadata_by_id.get(key, metadata_by_id.get(mid, null))
	var hit := protocol_from_metadata(meta)
	if not hit.is_empty():
		return {"ok": true, "transport": hit, "endpoint": endpoint_for(hit),
			"source": "models-metadata", "code": "", "detail": ""}
	if KNOWN_PROTOCOLS.has(key):
		var t := str(KNOWN_PROTOCOLS[key])
		return {"ok": true, "transport": t, "endpoint": endpoint_for(t),
			"source": "known-table", "code": "", "detail": ""}
	return {"ok": false, "transport": "", "endpoint": "", "source": "",
		"code": "UNSUPPORTED_PROTOCOL",
		"detail": "Model '%s' has no known OpenCode Go API protocol. Pick a discovered model or set an Advanced protocol override." % mid}


## OpenAI-Responses request body. messages: [{role, content}] with
## system/user/assistant roles; system maps to the Responses "developer" role.
static func build_responses_body(model: String, messages: Array, max_tokens: int, temperature: float, json_mode: bool, minimal: bool = false) -> Dictionary:
	var items: Array = []
	for m_val in messages:
		if not m_val is Dictionary:
			continue
		var m: Dictionary = m_val
		var role := str(m.get("role", "user")).strip_edges().to_lower()
		if role == "system":
			role = "developer"
		elif role != "developer" and role != "assistant":
			role = "user"
		items.append({"role": role, "content": str(m.get("content", ""))})
	if minimal:
		# OpenCode Go gateway: live evidence shows extras rejected while
		# minimal probes pass. Turns rely on the system-prompt contract +
		# the fence-tolerant parser instead of a JSON format constraint.
		return {"model": model, "input": items, "max_output_tokens": max_tokens}
	var body := {
		"model": model,
		"input": items,
		"max_output_tokens": max_tokens,
		"temperature": temperature,
		"stream": false,
	}
	if json_mode:
		body["text"] = {"format": {"type": "json_object"}}
	return body


## Extract model text from an OpenAI-Responses envelope. Handles the
## aggregated "output_text" field and the granular output[] message parts.
static func extract_responses_content(envelope: Dictionary) -> String:
	var agg := str(envelope.get("output_text", "")).strip_edges()
	if not agg.is_empty():
		return agg
	var parts: Array = []
	for o_val in (envelope.get("output", []) as Array):
		if not o_val is Dictionary:
			continue
		var o: Dictionary = o_val
		if str(o.get("type", "")) == "message":
			for c_val in (o.get("content", []) as Array):
				if c_val is Dictionary and str((c_val as Dictionary).get("type", "")) in ["output_text", "text"]:
					var t := str((c_val as Dictionary).get("text", "")).strip_edges()
					if not t.is_empty():
						parts.append(t)
		elif str(o.get("type", "")) == "text":
			var t2 := str(o.get("text", "")).strip_edges()
			if not t2.is_empty():
				parts.append(t2)
	return "\n".join(parts)


## Headers for chat/turn POSTs. The Authorization header bears the secret
## and must never be printed; the key is trimmed, never altered inside.
static func auth_headers(api_key: String, transport: String) -> PackedStringArray:
	var h := PackedStringArray(["Content-Type: application/json", "Accept: application/json",
		"User-Agent: " + USER_AGENT, "x-opencode-session: " + session_id()])
	if not api_key.strip_edges().is_empty():
		h.append("Authorization: Bearer " + api_key.strip_edges())
	if transport == TRANSPORT_MESSAGES:
		h.append("anthropic-version: 2023-06-01")
	return h


static func models_headers(api_key: String) -> PackedStringArray:
	var h := PackedStringArray(["Accept: application/json",
		"User-Agent: " + USER_AGENT, "x-opencode-session: " + session_id()])
	if not api_key.strip_edges().is_empty():
		h.append("Authorization: Bearer " + api_key.strip_edges())
	return h
