class_name Cloud2Session
extends RefCounted

## CLOUD-GENERAL STEP 2 — session-lifetime configuration authority.
##
## The API key is intentionally SESSION ONLY, and scene-local nodes die on
## scene change — so the effective backend session lives HERE, in static
## (process-lifetime) state: provider/model/protocol/endpoint/tested state,
## the in-memory key, and the discovery cache. Static state survives scene
## changes in both the game and headless (-s) runners with no autoload.
##
## Single truth, one direction:
##   AI window test-pass / apply  ->  CloudSession.arm(...)
##   AIBackendConfig.apply_runtime ->  CloudSession (opencode state)
##   Cloud2Mount                  <-  CloudSession.hydrate(live_config)
##   Direct chat / turns          <-  the hydrated live config object
##
## The key is memory-only: never persisted, never logged, never fingerprinted.
## Only key_present (bool) is ever exposed.

static var _provider := ""
static var _model := ""
static var _endpoint := ""
static var _transport := ""
static var _proto_source := ""
static var _override := ""
static var _tested := false
static var _connection := "DISCONNECTED"
static var _key := ""
static var _discovered: Array = []
static var _discovered_msec := 0
static var _armed_msec := 0


static func clear() -> void:
	_provider = ""
	_model = ""
	_endpoint = ""
	_transport = ""
	_proto_source = ""
	_override = ""
	_tested = false
	_connection = "DISCONNECTED"
	_key = ""
	_discovered = []
	_discovered_msec = 0
	_armed_msec = 0


## Explicit user action: forget the key this instant (tested state falls
## with it — a keyless session can never claim CONNECTED).
static func clear_key() -> void:
	_key = ""
	_tested = false
	_connection = "DISCONNECTED"


## Publish a validated backend session. Called on Test Connection PASS
## (so Apply-skipping still preserves the session) and on Apply.
## cfg is untyped (Cloud2Config) to avoid a preload cycle; only safe
## fields plus the memory-only key are copied.
static func arm_from_config(cfg: RefCounted) -> void:
	if cfg == null:
		return
	var disc: Variant = cfg.get("discovered_models")
	if not disc is Array:
		disc = []
	arm(str(cfg.get("provider_id")), str(cfg.get("model")),
		str(cfg.get("endpoint")), str(cfg.call("effective_transport")),
		str(cfg.get("protocol_source")), str(cfg.get("protocol_override")),
		bool(cfg.get("connection_tested")), str(cfg.get("connection_status")),
		str(cfg.get("api_key")), disc)


static func arm(provider: String, model: String, endpoint: String, transport: String,
		source: String, override: String, tested: bool, connection: String,
		key: String, discovered: Array = []) -> void:
	_provider = provider.strip_edges().to_lower()
	_model = model.strip_edges()
	_endpoint = endpoint.strip_edges()
	_transport = transport.strip_edges()
	_proto_source = source.strip_edges()
	_override = override.strip_edges().to_lower()
	_tested = tested and not key.strip_edges().is_empty() and not _model.is_empty()
	_connection = connection if _tested else "DISCONNECTED"
	_key = key.strip_edges()
	if not discovered.is_empty():
		_discovered = (discovered as Array).duplicate(true)
		_discovered_msec = Time.get_ticks_msec()
	_armed_msec = Time.get_ticks_msec()
	print("[CloudSession] armed fp=%s key=%s" % [fingerprint(), "YES" if key_present() else "NO"])


## Push the session into a (usually fresh, scene-local) Cloud2Config.
## Returns true when the session held an armed backend. Untyped cfg.
static func hydrate(cfg: RefCounted) -> bool:
	if cfg == null or not is_armed():
		return false
	cfg.call("set_provider", _provider)
	cfg.call("set_protocol_override", _override)
	if not _discovered.is_empty():
		cfg.call("set_discovered_models", _discovered)
	cfg.call("set_model", _model)
	cfg.call("set_api_key", _key)
	if _tested:
		cfg.call("mark_test_result", true, "CONNECTED", "Hydrated from session.")
	print("[CloudSession] hydrate -> fp=%s" % fingerprint())
	return true


static func is_armed() -> bool:
	return not _provider.is_empty() and not _model.is_empty()


static func key_present() -> bool:
	return not _key.strip_edges().is_empty()


static func get_key() -> String:
	return _key


static func is_tested() -> bool:
	return _tested and key_present()


## Cache a discovery result without arming (metadata is keyless and safe).
## Lets scene transitions reuse the model list before any test runs.
static func note_discovered(models: Array) -> void:
	if models.is_empty():
		return
	_discovered = (models as Array).duplicate(true)
	_discovered_msec = Time.get_ticks_msec()


static func discovered_cache() -> Array:
	return _discovered.duplicate(true)


static func discovered_count() -> int:
	return _discovered.size()


static func fingerprint() -> String:
	var proto := _transport if not _transport.is_empty() else "?"
	return "%s|%s|%s|%s|%s" % [_provider, _model, proto, _endpoint,
		"tested" if _tested else "untested"]


## Non-secret addressing fingerprint: provider|model|transport|endpoint.
## The tested flag is deliberately EXCLUDED: it compares TARGETS, and the
## session's own tested bit decides validity.
static func config_fingerprint() -> String:
	var proto := _transport if not _transport.is_empty() else "?"
	return "%s|%s|%s|%s" % [_provider, _model, proto, _endpoint]


static func _cfg_fp(cfg: RefCounted) -> String:
	var proto := str(cfg.call("effective_transport"))
	if proto.is_empty():
		proto = "?"
	return "%s|%s|%s|%s" % [str(cfg.get("provider_id")), str(cfg.get("model")),
		proto, str(cfg.get("endpoint"))]


## Single gate for every consumer (chat, RED, adapter). The config copy
## owns ADDRESSING (provider/model/protocol/endpoint); the session owns
## the SECRET + TESTED validity. Heals narrowly and loudly:
## - same target + key missing/untested + session tested -> backfill both
## - live unconfigured + session armed -> full hydrate
## Never fabricates addressing; never touches a differently-targeted live.
## Returns {ok, code, detail, key, healed}. cfg is duck-typed (no preload
## cycle: Cloud2Config -> AIBackendConfig -> Cloud2Session).
static func resolve_for_use(cfg: RefCounted) -> Dictionary:
	if cfg == null or not is_instance_valid(cfg):
		return {"ok": false, "code": "CLOUD_NOT_CONFIGURED",
			"detail": "No Cloud configuration bound.", "key": "", "healed": false}
	var gate: Dictionary = cfg.call("validate_for_start")
	if bool(gate.get("ok", false)):
		return {"ok": true, "code": "", "detail": "",
			"key": str(cfg.get("api_key")), "healed": false}
	if not key_present():
		return {"ok": false, "code": str(gate.get("code", "CLOUD_NOT_CONFIGURED")),
			"detail": str(gate.get("detail", "")), "key": "", "healed": false}
	var live_unconfigured := str(cfg.get("provider_id")).strip_edges().is_empty() \
		or str(cfg.get("model")).strip_edges().is_empty()
	if live_unconfigured and is_armed():
		hydrate(cfg)
		trace("SESSION_HEAL_FULL", null, cfg)
		var g2: Dictionary = cfg.call("validate_for_start")
		if bool(g2.get("ok", false)):
			return {"ok": true, "code": "", "detail": "", "key": _key, "healed": true}
		return {"ok": false, "code": str(g2.get("code", "")), "detail": str(g2.get("detail", "")),
			"key": "", "healed": true}
	if is_tested() and _cfg_fp(cfg) == config_fingerprint():
		cfg.call("set_api_key", _key)
		cfg.call("mark_test_result", true, "CONNECTED", "Backfilled from session (same target).")
		trace("SESSION_HEAL_KEY", null, cfg)
		var g3: Dictionary = cfg.call("validate_for_start")
		if bool(g3.get("ok", false)):
			return {"ok": true, "code": "", "detail": "", "key": _key, "healed": true}
	return {"ok": false, "code": str(gate.get("code", "CLOUD_NOT_CONFIGURED")),
		"detail": str(gate.get("detail", "")), "key": "", "healed": false}


## Safe diagnostics (never the key).
static func snapshot() -> Dictionary:
	return {
		"provider": _provider,
		"model": _model,
		"endpoint": _endpoint,
		"transport": _transport,
		"protocol_source": _proto_source,
		"override": _override,
		"tested": _tested,
		"connection": _connection,
		"key_present": key_present(),
		"discovered": _discovered.size(),
		"fingerprint": fingerprint(),
	}


## ONE-LINE SAFE TRACE (never the key): session + optional scratch/live
## config objects with instance ids. Call at every ownership transition so
## the FIRST key_present YES->NO or tested true->false is visible.
static func trace(tag: String, scratch: RefCounted = null, live: RefCounted = null) -> void:
	var parts: Array = ["[CloudTrace]", tag,
		"session{key=%s tested=%s conn=%s fp=%s}" % [
			"YES" if key_present() else "NO", str(is_tested()),
			_connection, fingerprint()]]
	for pair in [["scratch", scratch], ["live", live]]:
		var o: RefCounted = pair[1] as RefCounted
		if o != null and is_instance_valid(o):
			parts.append("%s{id=%s key=%s tested=%s conn=%s fp=%s}" % [
				str(pair[0]), str(o.get_instance_id()),
				"YES" if bool(o.call("has_key")) else "NO",
				str(bool(o.get("connection_tested"))),
				str(o.get("connection_status")), str(o.call("fingerprint"))])
	print(" ".join(parts))
