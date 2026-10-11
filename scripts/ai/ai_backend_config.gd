class_name AIBackendConfig
extends RefCounted

## Safe runtime AI backend configuration (launcher milestone).
##
## Owns ONLY: the backend/model/endpoint shape, safe persistence
## (user://, never secrets), validation, and one-shot application into the
## existing Step7 ProjectSettings keys consumed by Step7OllamaConfig.
##
## Security boundary:
##   - The API key lives ONLY in the static _runtime_api_key (process memory).
##   - save_safe() NEVER writes the key. current()/DEV snapshots expose only
##     api_key_present=true/false. Nothing here logs the key.
##
## Backend types:
##   LOCAL_OLLAMA  - fully working (default, no key required).
##   OPENCODE_GO   - Cloud General via OpenCode Go (key + live discovery).
##   GENERIC_API   - legacy placeholder (loads; the UI maps it to OpenCode Go).

const BACKEND_LOCAL_OLLAMA := "LOCAL_OLLAMA"
const BACKEND_GENERIC_API := "GENERIC_API"
const BACKEND_OPENCODE_GO := "OPENCODE_GO"
const KNOWN_BACKENDS := [BACKEND_LOCAL_OLLAMA, BACKEND_GENERIC_API, BACKEND_OPENCODE_GO]

const DEFAULT_BACKEND := BACKEND_LOCAL_OLLAMA
const DEFAULT_ENDPOINT := "http://127.0.0.1:11434"
const DEFAULT_MODEL := "qwen38-jrell-mtp-256k:latest"
const DEFAULT_OPENCODE_MODEL := ""
const DEFAULT_TIMEOUT_SEC := 120.0
const DEFAULT_STARTUP_TIMEOUT_SEC := 90.0
const DEFAULT_WARMUP_TIMEOUT_SEC := 300.0
## Semantic-frontend role default (tiny Qwen3-0.6B Ollama tag registered
## from the cached GGUF by Step7SemanticModelManager; see
## scripts/step7/step7_semantic_model.gd). The TACTICAL role keeps `model`.
const DEFAULT_SEMANTIC_MODEL := "strategy-game-semantic-qwen06:latest"
## Long residency so the preloaded model stays in VRAM for the whole session,
## like any other game's embedded asset load (not a launcher preparation trick).
const DEFAULT_KEEP_ALIVE := "12h"

const SETTINGS_PATH := "user://ai_backend.cfg"
const LEGACY_PATH := "user://slm_settings.cfg"

# Keys consumed by the existing Step7OllamaConfig (do NOT rename).
const PS_BASE := "strategy_game/ollama/base_url"
const PS_MODEL := "strategy_game/ollama/model"
const PS_TIMEOUT := "strategy_game/ollama/timeout_seconds"
# Semantic-role key (tactical role keeps PS_MODEL). Written ONLY here.
const PS_SEMANTIC_MODEL := "strategy_game/ollama/semantic_model"
# Launcher-owned keys (AI-free gate + diagnostics).
const PS_AI_ENABLED := "strategy_game/ai/enabled"
const PS_BACKEND_TYPE := "strategy_game/ai/backend_type"
const PS_KEEP_ALIVE := "strategy_game/ai/keep_alive"
# OpenCode Go runtime keys (non-secret; the key itself stays in memory only).
const PS_OPENCODE_TRANSPORT := "strategy_game/ai/opencode_transport"
const PS_OPENCODE_OVERRIDE := "strategy_game/ai/opencode_override"
const PS_OPENCODE_TESTED := "strategy_game/ai/opencode_tested"

const SessionCls = preload("res://scripts/cloud2/cloud2_session.gd")

# Process memory only. Never persisted, never logged, never serialized.
static var _runtime_api_key := ""
# Monotonic configuration revision. Bumped on every apply_runtime() so
# in-flight Advisor responses snapshotted under an older identity can be
# discarded as stale when the user switches endpoint/model mid-request.
static var _config_revision := 0
# Boot restore runs once per process; later title entries keep the session.
static var _boot_applied := false


static func default_config() -> Dictionary:
	return {
		"backend_type": DEFAULT_BACKEND,
		"endpoint": DEFAULT_ENDPOINT,
		"model": DEFAULT_MODEL,
		"model_by_backend": {BACKEND_LOCAL_OLLAMA: DEFAULT_MODEL, BACKEND_OPENCODE_GO: DEFAULT_OPENCODE_MODEL},
		"endpoint_by_backend": {BACKEND_LOCAL_OLLAMA: DEFAULT_ENDPOINT, BACKEND_OPENCODE_GO: ""},
		"opencode_transport": "",
		"opencode_override": "",
		"opencode_tested": false,
		"semantic_model": DEFAULT_SEMANTIC_MODEL,
		"timeout_sec": DEFAULT_TIMEOUT_SEC,
		"startup_timeout_sec": DEFAULT_STARTUP_TIMEOUT_SEC,
		"warmup_timeout_sec": DEFAULT_WARMUP_TIMEOUT_SEC,
		"keep_alive": DEFAULT_KEEP_ALIVE,
		"ai_enabled": true,
	}


## Active-backend model/endpoint accessors over the per-backend slots, so
## switching backends never cross-contaminates the other backend's values.
static func slot_model(cfg: Dictionary, backend: String) -> String:
	var slots: Dictionary = cfg.get("model_by_backend", {})
	var v := str(slots.get(backend, "")).strip_edges()
	if v.is_empty():
		return DEFAULT_OPENCODE_MODEL if backend == BACKEND_OPENCODE_GO else DEFAULT_MODEL
	return v


static func slot_endpoint(cfg: Dictionary, backend: String) -> String:
	var slots: Dictionary = cfg.get("endpoint_by_backend", {})
	var v := str(slots.get(backend, "")).strip_edges()
	if v.is_empty() and backend == BACKEND_LOCAL_OLLAMA:
		return DEFAULT_ENDPOINT
	return v


static func set_slot(cfg: Dictionary, backend: String, model: String, endpoint: String) -> void:
	var ms: Dictionary = cfg.get("model_by_backend", {})
	ms[backend] = model.strip_edges()
	cfg["model_by_backend"] = ms
	var es: Dictionary = cfg.get("endpoint_by_backend", {})
	es[backend] = endpoint.strip_edges()
	cfg["endpoint_by_backend"] = es


## Load safe (non-secret) settings. Never returns an API key.
static func load_safe() -> Dictionary:
	var cfg := default_config()
	var file := ConfigFile.new()
	if file.load(SETTINGS_PATH) == OK:
		var b := str(file.get_value("ai_backend", "backend_type", DEFAULT_BACKEND)).strip_edges().to_upper()
		cfg["backend_type"] = b if b in KNOWN_BACKENDS else DEFAULT_BACKEND
		var ms: Dictionary = cfg["model_by_backend"]
		var es: Dictionary = cfg["endpoint_by_backend"]
		var m_ol := str(file.get_value("ai_backend", "model_ollama", "")).strip_edges()
		var m_oc := str(file.get_value("ai_backend", "model_opencode", "")).strip_edges()
		var e_ol := str(file.get_value("ai_backend", "endpoint_ollama", "")).strip_edges()
		var e_oc := str(file.get_value("ai_backend", "endpoint_opencode", "")).strip_edges()
		# Legacy mirror (pre-slot builds wrote flat model/endpoint keys).
		var m_leg := str(file.get_value("ai_backend", "model", "")).strip_edges()
		var e_leg := str(file.get_value("ai_backend", "endpoint", "")).strip_edges()
		if m_ol.is_empty() and not m_leg.is_empty():
			m_ol = m_leg
		if e_ol.is_empty():
			var ep_leg := sanitize_endpoint(e_leg)
			if bool(ep_leg.get("ok", false)):
				e_ol = str(ep_leg.get("value", ""))
		if not m_ol.is_empty():
			ms[BACKEND_LOCAL_OLLAMA] = m_ol
		if not e_ol.is_empty():
			var ep_ol := sanitize_endpoint(e_ol)
			es[BACKEND_LOCAL_OLLAMA] = str(ep_ol.get("value", DEFAULT_ENDPOINT)) if bool(ep_ol.get("ok", false)) else DEFAULT_ENDPOINT
		if not m_oc.is_empty():
			ms[BACKEND_OPENCODE_GO] = m_oc
		if not e_oc.is_empty():
			var ep_oc := sanitize_endpoint(e_oc)
			if bool(ep_oc.get("ok", false)):
				es[BACKEND_OPENCODE_GO] = str(ep_oc.get("value", ""))
		cfg["model_by_backend"] = ms
		cfg["endpoint_by_backend"] = es
		cfg["opencode_transport"] = str(file.get_value("ai_backend", "opencode_transport", "")).strip_edges().to_lower()
		cfg["opencode_override"] = str(file.get_value("ai_backend", "opencode_override", "")).strip_edges().to_lower()
		cfg["opencode_tested"] = false # tests never survive a relaunch (key is session-only)
		cfg["model"] = slot_model(cfg, str(cfg["backend_type"]))
		cfg["endpoint"] = slot_endpoint(cfg, str(cfg["backend_type"]))
		var sm := str(file.get_value("ai_backend", "semantic_model", DEFAULT_SEMANTIC_MODEL)).strip_edges()
		cfg["semantic_model"] = sm if not sm.is_empty() else DEFAULT_SEMANTIC_MODEL
		cfg["timeout_sec"] = maxf(5.0, float(file.get_value("ai_backend", "timeout_sec", DEFAULT_TIMEOUT_SEC)))
		cfg["startup_timeout_sec"] = clampf(float(file.get_value("ai_backend", "startup_timeout_sec", DEFAULT_STARTUP_TIMEOUT_SEC)), 10.0, 300.0)
		cfg["warmup_timeout_sec"] = clampf(float(file.get_value("ai_backend", "warmup_timeout_sec", DEFAULT_WARMUP_TIMEOUT_SEC)), 30.0, 600.0)
		var ka := str(file.get_value("ai_backend", "keep_alive", DEFAULT_KEEP_ALIVE)).strip_edges()
		cfg["keep_alive"] = ka if not ka.is_empty() else DEFAULT_KEEP_ALIVE
		return cfg
	# Legacy migration: old title-screen SLM dialog (endpoint + model only).
	var legacy := ConfigFile.new()
	if legacy.load(LEGACY_PATH) == OK:
		var ep2 := sanitize_endpoint(str(legacy.get_value("slm", "url", DEFAULT_ENDPOINT)))
		if bool(ep2.get("ok", false)):
			set_slot(cfg, BACKEND_LOCAL_OLLAMA, slot_model(cfg, BACKEND_LOCAL_OLLAMA), str(ep2.get("value", DEFAULT_ENDPOINT)))
			cfg["endpoint"] = slot_endpoint(cfg, str(cfg["backend_type"]))
		var m2 := str(legacy.get_value("slm", "model", "")).strip_edges()
		if not m2.is_empty():
			set_slot(cfg, BACKEND_LOCAL_OLLAMA, m2, slot_endpoint(cfg, BACKEND_LOCAL_OLLAMA))
			cfg["model"] = slot_model(cfg, str(cfg["backend_type"]))
	return cfg


## Persist safe settings only. The api_key argument is intentionally ABSENT:
## there is no code path that writes a secret to disk.
static func save_safe(cfg: Dictionary) -> void:
	var file := ConfigFile.new()
	var b := str(cfg.get("backend_type", DEFAULT_BACKEND)).strip_edges().to_upper()
	if not b in KNOWN_BACKENDS:
		b = DEFAULT_BACKEND
	file.set_value("ai_backend", "backend_type", b)
	# Per-backend slots (no cross-contamination between Ollama and OpenCode).
	var ms: Dictionary = cfg.get("model_by_backend", {})
	var es: Dictionary = cfg.get("endpoint_by_backend", {})
	file.set_value("ai_backend", "model_ollama", str(ms.get(BACKEND_LOCAL_OLLAMA, DEFAULT_MODEL)).strip_edges())
	file.set_value("ai_backend", "model_opencode", str(ms.get(BACKEND_OPENCODE_GO, DEFAULT_OPENCODE_MODEL)).strip_edges())
	file.set_value("ai_backend", "endpoint_ollama", str(es.get(BACKEND_LOCAL_OLLAMA, DEFAULT_ENDPOINT)).strip_edges())
	file.set_value("ai_backend", "endpoint_opencode", str(es.get(BACKEND_OPENCODE_GO, "")).strip_edges())
	# Legacy flat mirror: the ACTIVE values, for pre-slot readers.
	file.set_value("ai_backend", "endpoint", str(cfg.get("endpoint", DEFAULT_ENDPOINT)).strip_edges())
	file.set_value("ai_backend", "model", str(cfg.get("model", DEFAULT_MODEL)).strip_edges())
	file.set_value("ai_backend", "opencode_transport", str(cfg.get("opencode_transport", "")).strip_edges().to_lower())
	file.set_value("ai_backend", "opencode_override", str(cfg.get("opencode_override", "")).strip_edges().to_lower())
	file.set_value("ai_backend", "semantic_model", str(cfg.get("semantic_model", DEFAULT_SEMANTIC_MODEL)).strip_edges())
	file.set_value("ai_backend", "timeout_sec", maxf(5.0, float(cfg.get("timeout_sec", DEFAULT_TIMEOUT_SEC))))
	file.set_value("ai_backend", "startup_timeout_sec", clampf(float(cfg.get("startup_timeout_sec", DEFAULT_STARTUP_TIMEOUT_SEC)), 10.0, 300.0))
	file.set_value("ai_backend", "warmup_timeout_sec", clampf(float(cfg.get("warmup_timeout_sec", DEFAULT_WARMUP_TIMEOUT_SEC)), 30.0, 600.0))
	file.set_value("ai_backend", "keep_alive", str(cfg.get("keep_alive", DEFAULT_KEEP_ALIVE)).strip_edges())
	file.save(SETTINGS_PATH)


## Publish this config as the single runtime authority. The existing
## Step7OllamaConfig reads the PS_BASE/PS_MODEL/PS_TIMEOUT keys, so the
## Advisor pipeline needs NO logic changes. api_key stays in memory only.
static func apply_runtime(cfg: Dictionary, api_key: String = "") -> void:
	ProjectSettings.set_setting(PS_BASE, str(cfg.get("endpoint", DEFAULT_ENDPOINT)).strip_edges())
	ProjectSettings.set_setting(PS_MODEL, str(cfg.get("model", DEFAULT_MODEL)).strip_edges())
	ProjectSettings.set_setting(PS_SEMANTIC_MODEL, str(cfg.get("semantic_model", DEFAULT_SEMANTIC_MODEL)).strip_edges())
	ProjectSettings.set_setting(PS_TIMEOUT, maxf(5.0, float(cfg.get("timeout_sec", DEFAULT_TIMEOUT_SEC))))
	ProjectSettings.set_setting(PS_AI_ENABLED, bool(cfg.get("ai_enabled", true)))
	ProjectSettings.set_setting(PS_BACKEND_TYPE, str(cfg.get("backend_type", DEFAULT_BACKEND)).strip_edges().to_upper())
	ProjectSettings.set_setting(PS_KEEP_ALIVE, str(cfg.get("keep_alive", DEFAULT_KEEP_ALIVE)).strip_edges())
	ProjectSettings.set_setting(PS_OPENCODE_TRANSPORT, str(cfg.get("opencode_transport", "")).strip_edges().to_lower())
	ProjectSettings.set_setting(PS_OPENCODE_OVERRIDE, str(cfg.get("opencode_override", "")).strip_edges().to_lower())
	ProjectSettings.set_setting(PS_OPENCODE_TESTED, bool(cfg.get("opencode_tested", false)))
	_runtime_api_key = api_key
	_config_revision += 1
	ProjectSettings.set_setting("strategy_game/ai/config_revision", _config_revision)
	# Opencode state also arms the session authority (single truth for the
	# Cloud stack); an empty key never arms — it only clears the runtime.
	if str(cfg.get("backend_type", DEFAULT_BACKEND)).strip_edges().to_upper() == BACKEND_OPENCODE_GO \
			and not api_key.strip_edges().is_empty() and not str(cfg.get("model", "")).strip_edges().is_empty():
		SessionCls.arm("opencode", str(cfg.get("model", "")),
			str(cfg.get("endpoint", "")), str(cfg.get("opencode_transport", "")),
			"", str(cfg.get("opencode_override", "")), bool(cfg.get("opencode_tested", false)),
			"CONNECTED" if bool(cfg.get("opencode_tested", false)) else "DISCONNECTED",
			api_key)


## Boot restore (embedded-backend milestone): publish the last safe
## endpoint/model/backend into the runtime authority. The API key is NEVER
## restored — the user retypes it every launch.
## Process-once: re-entering the title (Title -> HvC -> Title) must NEVER
## wipe a live session key, so later calls are no-ops.
## Every call (first included) returns current(): the same live snapshot
## shape, so boot is idempotent for all callers.
static func ensure_boot_runtime() -> Dictionary:
	if _boot_applied:
		return current()
	_boot_applied = true
	var cfg := load_safe()
	cfg["ai_enabled"] = bool(ProjectSettings.get_setting(PS_AI_ENABLED, true))
	apply_runtime(cfg, "")
	return current()


## Authoritative AI-enabled flag for gameplay. Defaults to true so legacy
## scenes and headless tests behave exactly as before the launcher existed.
static func is_ai_enabled() -> bool:
	return bool(ProjectSettings.get_setting(PS_AI_ENABLED, true))


static func set_api_key(k: String) -> void:
	_runtime_api_key = k


static func has_api_key() -> bool:
	return not _runtime_api_key.strip_edges().is_empty()


## Memory-only key accessor for the HTTP transport. The caller must use it
## solely to build the Authorization header and must never log/store it.
static func get_api_key() -> String:
	return _runtime_api_key


static func clear_api_key() -> void:
	_runtime_api_key = ""
	SessionCls.clear_key()


## Runtime snapshot for UI/DEV. Exposes api_key_present (bool) — NEVER the key.
static func current() -> Dictionary:
	return {
		"backend_type": str(ProjectSettings.get_setting(PS_BACKEND_TYPE, DEFAULT_BACKEND)),
		"endpoint": str(ProjectSettings.get_setting(PS_BASE, DEFAULT_ENDPOINT)),
		"model": str(ProjectSettings.get_setting(PS_MODEL, DEFAULT_MODEL)),
		"opencode_transport": str(ProjectSettings.get_setting(PS_OPENCODE_TRANSPORT, "")),
		"opencode_override": str(ProjectSettings.get_setting(PS_OPENCODE_OVERRIDE, "")),
		"opencode_tested": bool(ProjectSettings.get_setting(PS_OPENCODE_TESTED, false)),
		"semantic_model": str(ProjectSettings.get_setting(PS_SEMANTIC_MODEL, DEFAULT_SEMANTIC_MODEL)),
		"timeout_sec": float(ProjectSettings.get_setting(PS_TIMEOUT, DEFAULT_TIMEOUT_SEC)),
		"keep_alive": str(ProjectSettings.get_setting(PS_KEEP_ALIVE, DEFAULT_KEEP_ALIVE)),
		"ai_enabled": bool(ProjectSettings.get_setting(PS_AI_ENABLED, true)),
		"api_key_present": has_api_key(),
		"config_revision": int(ProjectSettings.get_setting("strategy_game/ai/config_revision", _config_revision)),
		"config_identity": config_identity(),
	}


## Fingerprint of the live runtime configuration. Advisor requests snapshot
## this value; a response whose snapshot differs from the live value is
## stale (user switched endpoint/model/backend mid-flight) and discarded.
static func config_identity() -> String:
	var b := str(ProjectSettings.get_setting(PS_BACKEND_TYPE, DEFAULT_BACKEND)).strip_edges().to_upper()
	var e := str(ProjectSettings.get_setting(PS_BASE, DEFAULT_ENDPOINT)).strip_edges()
	var m := str(ProjectSettings.get_setting(PS_MODEL, DEFAULT_MODEL)).strip_edges()
	var r := int(ProjectSettings.get_setting("strategy_game/ai/config_revision", _config_revision))
	return "%s|%s|%s|r%d" % [b, e, m, r]


## Semantic-role identity (endpoint + semantic tag + revision). Tracked
## separately so the tactical tag can change without invalidating the
## frontend and vice versa.
static func semantic_identity() -> String:
	var b := str(ProjectSettings.get_setting(PS_BACKEND_TYPE, DEFAULT_BACKEND)).strip_edges().to_upper()
	var e := str(ProjectSettings.get_setting(PS_BASE, DEFAULT_ENDPOINT)).strip_edges()
	var m := str(ProjectSettings.get_setting(PS_SEMANTIC_MODEL, DEFAULT_SEMANTIC_MODEL)).strip_edges()
	var r := int(ProjectSettings.get_setting("strategy_game/ai/config_revision", _config_revision))
	return "%s|%s|%s|r%d" % [b, e, m, r]


static func semantic_model_tag() -> String:
	return str(ProjectSettings.get_setting(PS_SEMANTIC_MODEL, DEFAULT_SEMANTIC_MODEL)).strip_edges()


## Validate an Ollama/API endpoint URI without ever crashing HTTPRequest.
## Returns {ok, value(normalized), why}.
static func sanitize_endpoint(raw: String) -> Dictionary:
	var t := raw.strip_edges().trim_suffix("/")
	if t.is_empty():
		return {"ok": false, "value": "", "why": "empty"}
	if t.contains(" ") or t.contains("\t"):
		return {"ok": false, "value": t, "why": "whitespace"}
	if not (t.begins_with("http://") or t.begins_with("https://")):
		return {"ok": false, "value": t, "why": "scheme"}
	var rest := t.split("://", true, 1)
	if rest.size() < 2 or str(rest[1]).strip_edges().is_empty():
		return {"ok": false, "value": t, "why": "host"}
	return {"ok": true, "value": t, "why": ""}


static func tags_url(endpoint: String) -> String:
	return endpoint.strip_edges().trim_suffix("/") + "/api/tags"


static func chat_url(endpoint: String) -> String:
	return endpoint.strip_edges().trim_suffix("/") + "/api/chat"
