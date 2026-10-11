extends RefCounted

## SYMMETRIC LOCAL-vs-LOCAL SANDBOX V1 — local Brain config builder.
##
## Reuses the existing stacks, nothing duplicated:
##   AI config infra .... AIBackendConfig LOCAL_OLLAMA slot (endpoint+model)
##   Brain contract ..... Cloud2Config (provider ollama|custom) + Cloud2Adapter
##   validator .......... Cloud2VictoryResponse / Cloud2GeneralResponse
##   plan ............... Cloud2VictoryPlan (same schema both sides)
##
## Default: ONE local endpoint/model serves BOTH sides (shared server
## requests are serialized; batching is not required in V1).
## Env split for future leagues (RED = B_current, BLUE = B_old):
##   SYMLOC_RED_MODEL / SYMLOC_BLUE_MODEL (endpoint shared unless
##   SYMLOC_RED_ENDPOINT / SYMLOC_BLUE_ENDPOINT are also set).
## Global overrides: SYMLOC_BRAIN_PROVIDER (ollama|custom),
## SYMLOC_BRAIN_ENDPOINT (base URL), SYMLOC_BRAIN_MODEL.

const AICfgCls = preload("res://scripts/ai/ai_backend_config.gd")
const ConfigCls = preload("res://scripts/cloud2/cloud2_config.gd")


static func describe_source() -> Dictionary:
	return {
		"provider": _env("SYMLOC_BRAIN_PROVIDER", "ollama"),
		"endpoint": _resolve_endpoint(""),
		"model": _resolve_model(""),
		"red_model": _resolve_model("red"),
		"blue_model": _resolve_model("blue"),
	}


static func _env(key: String, fallback: String) -> String:
	# NOTE: OS.has_environment() does NOT see OS.set_environment() values
	# in-process on this Godot/Windows build (it reads the launch
	# snapshot); OS.get_environment() does. Always read live.
	var v := OS.get_environment(key).strip_edges()
	if not v.is_empty():
		return v
	return fallback


static func _resolve_endpoint(side: String) -> String:
	var tagged := ""
	if side == "red":
		tagged = _env("SYMLOC_RED_ENDPOINT", "")
	elif side == "blue":
		tagged = _env("SYMLOC_BLUE_ENDPOINT", "")
	if not tagged.is_empty():
		return tagged
	var glob := _env("SYMLOC_BRAIN_ENDPOINT", "")
	if not glob.is_empty():
		return glob
	var cfg: Dictionary = AICfgCls.load_safe()
	return AICfgCls.slot_endpoint(cfg, AICfgCls.BACKEND_LOCAL_OLLAMA)


static func _resolve_model(side: String) -> String:
	var tagged := ""
	if side == "red":
		tagged = _env("SYMLOC_RED_MODEL", "")
	elif side == "blue":
		tagged = _env("SYMLOC_BLUE_MODEL", "")
	if not tagged.is_empty():
		return tagged
	var glob := _env("SYMLOC_BRAIN_MODEL", "")
	if not glob.is_empty():
		return glob
	var cfg: Dictionary = AICfgCls.load_safe()
	return AICfgCls.slot_model(cfg, AICfgCls.BACKEND_LOCAL_OLLAMA)


## Full chat-completions URL for the General adapter. Ollama serves the
## OpenAI-compatible API under /v1; a custom OpenAI-compatible base gets
## the same suffix unless it already carries a /v1/ path.
static func chat_completions_url(base_endpoint: String) -> String:
	var t := base_endpoint.strip_edges().trim_suffix("/")
	if t.contains("/v1/"):
		return t
	return t + "/v1/chat/completions"


## Build one provider config for a side ("red"/"blue"/""). The config is
## untested; the mount runs test_connection + mark_test_result (the same
## mechanism the CLOUD panel uses) before the session gate opens.
static func build_config(side: String) -> RefCounted:
	var provider := _env("SYMLOC_BRAIN_PROVIDER", "ollama").strip_edges().to_lower()
	if provider != "ollama" and provider != "custom":
		provider = "ollama"
	var cfg: RefCounted = ConfigCls.new()
	(cfg as RefCounted).call("set_provider", provider)
	(cfg as RefCounted).call("set_endpoint", chat_completions_url(_resolve_endpoint(side)))
	(cfg as RefCounted).call("set_model", _resolve_model(side))
	return cfg


## Human-readable backend label for match metadata + HUD.
static func backend_label(cfg: RefCounted) -> String:
	if cfg == null:
		return "unconfigured"
	return "local:%s/%s" % [str((cfg as RefCounted).get("provider_id")),
		str((cfg as RefCounted).get("model"))]


## Programmatic connection test (same mechanism as the panel's Test
## Connection). Awaits the adapter signal; marks the config on success so
## SessionCls.resolve_for_use opens. Returns {ok, code, detail}.
static func test_and_mark(adapter: Node, cfg: RefCounted, timeout_sec: float = 30.0) -> Dictionary:
	var started: Dictionary = (adapter as Node).call("test_connection", cfg)
	if not bool(started.get("ok", false)):
		return {"ok": false, "code": str(started.get("code", "TEST_START_FAILED")),
			"detail": str(started.get("detail", ""))}
	var tree: SceneTree = (adapter as Node).get_tree()
	var t0 := Time.get_ticks_msec()
	# NOTE: GDScript lambdas cannot rebind outer locals, so the result is
	# delivered by MUTATING this box (rebinding `got = result` silently
	# never escapes the closure).
	var box := {}
	var on_done := func(result: Dictionary) -> void: box["res"] = result
	(adapter as Node).connect("test_finished", on_done)
	while not box.has("res"):
		if tree == null:
			break
		await tree.process_frame
		if Time.get_ticks_msec() - t0 > timeout_sec * 1000.0:
			break
	if (adapter as Node).is_connected("test_finished", on_done):
		(adapter as Node).disconnect("test_finished", on_done)
	if not box.has("res"):
		return {"ok": false, "code": "TEST_TIMEOUT", "detail": "No test_finished within budget."}
	var got: Dictionary = box.get("res", {})
	if bool(got.get("ok", false)):
		(cfg as RefCounted).call("mark_test_result", true, "CONNECTED",
			"%s symloc probe" % str((cfg as RefCounted).get("model")))
		return {"ok": true, "code": "", "detail": "CONNECTED",
			"latency_ms": int(got.get("latency_ms", 0))}
	# Reasoning models can exhaust the tiny probe budget with reasoning and
	# no final text. HTTP 200 still proves server+model connectivity (the
	# probe's only question); real calls carry full output budgets.
	if int(got.get("http_status", 0)) == 200:
		(cfg as RefCounted).call("mark_test_result", true, "CONNECTED",
			"%s symloc probe (reasoning-only short reply; connectivity proven)" % str((cfg as RefCounted).get("model")))
		return {"ok": true, "code": "", "detail": "CONNECTED_VIA_HTTP200",
			"latency_ms": int(got.get("latency_ms", 0)),
			"probe_note": str(got.get("detail", ""))}
	return {"ok": false, "code": str(got.get("code", "TEST_FAILED")),
		"detail": str(got.get("detail", got.get("provider_message", "")))}
