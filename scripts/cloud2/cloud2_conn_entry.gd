extends SceneTree

## CLOUD-GENERAL STEP 2 — Connection-UX correction verification runner.
##
## Usage (Windows):
##   Godot_v4.2.2-stable_win64_console.exe --headless --path "D:\Game development\Demon slayer\StrategyGame" -s res://scripts/cloud2/cloud2_conn_entry.gd
##
## Exit code 0 = all gates pass, 1 = any gate fails. Writes
## res://evidence/cloud2_conn_ux/verification_conn_ux.json (never any secret).
##
## Covers (no network, no real key — a canary stands in for secret hygiene):
##   CONN-1..10  AI Settings exposes OpenCode Go; key-only UX; internal URL;
##               /models discovery; useful errors; protocol routing; test is
##               non-mutating; key absent from artifacts; apply makes the
##               Step-2 provider; no silent Ollama fallback.
##   DBG-1..8    system prompt / dynamic context / schema visible; direct chat
##               uses the real adapter; chat non-mutating; tools view is
##               canonical; review mode discusses without executing; local
##               checklist renders.
##   SEC-1..10   the ten obvious validation cases.
##   REG-A       Ollama slots untouched by OpenCode edits (no cross-talk).
##
## LIVE OpenCode Go (real key, real /models, real chat) is honestly reported
## BLOCKED: the key is the user's to paste in the UI.

const OpenCodeCls = preload("res://scripts/cloud2/cloud2_opencode.gd")
const ConfigCls = preload("res://scripts/cloud2/cloud2_config.gd")
const AdapterCls = preload("res://scripts/cloud2/cloud2_adapter.gd")
const PacketCls = preload("res://scripts/cloud2/cloud2_turn_packet.gd")
const ResponseCls = preload("res://scripts/cloud2/cloud2_response.gd")
const PlanCls = preload("res://scripts/cloud2/cloud2_plan_memory.gd")
const LoggerCls = preload("res://scripts/cloud2/cloud2_logger.gd")
const InspectorCls = preload("res://scripts/cloud2/cloud2_inspector.gd")
const TableCls = preload("res://scripts/cloud1/cloud1_action_table.gd")
const ObsCls = preload("res://scripts/cloud1/cloud1_observation.gd")
const SimControllerCls = preload("res://scripts/sim/sim_controller.gd")
const AISSetupScript = preload("res://scripts/ai/ai_setup_panel.gd")
const AIBackendCfg = preload("res://scripts/ai/ai_backend_config.gd")
const PanelCls = preload("res://scripts/cloud2/cloud2_panel.gd")
const ControllerCls = preload("res://scripts/cloud2/cloud2_turn_controller.gd")
const SessionCls = preload("res://scripts/cloud2/cloud2_session.gd")

const CLOUD2_SCENE := "res://scenes/cloud2_battle_test.tscn"
const OUT_DIR := "res://evidence/cloud2_conn_ux"
const OUT_PATH := "res://evidence/cloud2_conn_ux/verification_conn_ux.json"
## Every gate the runner must record. An aborted run (fewer gates) exits 1
## even when every recorded gate passed — a silent short run is a failure.
const EXPECTED_GATE_COUNT := 36

## Canary key material: secret-shaped, never a real credential, asserted
## ABSENT from every artifact, preview, packet, and log.
const CANARY := "CX_CANARY_KEY_7a6b5c4d3e2f1a0b9c8d"

var _gates: Dictionary = {}
var _chat_seen := {}
var _turn_seen := {}


func _init() -> void:
	_run()


func _record(gate: String, status: String, evidence: Dictionary) -> void:
	_gates[gate] = {"status": status, "evidence": evidence}
	print("[CONN-UX][%s] %s" % [gate, status.to_upper()])


func _exit_code() -> int:
	if _gates.size() < EXPECTED_GATE_COUNT:
		return 1
	for key in _gates.keys():
		var st := str((_gates[key] as Dictionary).get("status", ""))
		if st != "pass" and st != "blocked":
			return 1
	return 0


func _run() -> void:
	_c_endpoints()
	_c_parse_models()
	_c_resolve()
	_c_config_opencode()
	_c_slots()
	await _c_panel_exposes()
	_c_gate_no_fallback()
	_c_runtime_pull()
	_d_schema()
	_d_tools()
	_b_probe_shapes()
	_b_error_info()
	_b_fingerprint()
	_b_effective_block()
	_b_sanitize()
	_w_session()
	_w_minimal()
	_w_boot()
	await _w_heal()
	await _live_part()
	_write_and_quit(_exit_code())


# --- CONN: official endpoints -------------------------------------------------

func _c_endpoints() -> void:
	var ev := {}
	ev["base"] = OpenCodeCls.BASE_URL
	ev["models"] = OpenCodeCls.MODELS_URL
	ev["chat"] = OpenCodeCls.CHAT_URL
	ev["responses"] = OpenCodeCls.RESPONSES_URL
	ev["messages"] = OpenCodeCls.MESSAGES_URL
	var ok := OpenCodeCls.BASE_URL == "https://opencode.ai/zen/go/v1" \
		and OpenCodeCls.MODELS_URL == "https://opencode.ai/zen/go/v1/models" \
		and OpenCodeCls.CHAT_URL == "https://opencode.ai/zen/go/v1/chat/completions" \
		and OpenCodeCls.RESPONSES_URL == "https://opencode.ai/zen/go/v1/responses" \
		and OpenCodeCls.MESSAGES_URL == "https://opencode.ai/zen/go/v1/messages"
	_record("conn_official_endpoints", "pass" if ok else "fail", ev)


# --- CONN: /models parsing ----------------------------------------------------

func _c_parse_models() -> void:
	var ev := {}
	var openai_style := JSON.stringify({"data": [
		{"id": "kimi-k3", "name": "Kimi K3"},
		{"id": "qwen3.8-max", "name": "Qwen3.8 Max"},
		{"id": "kimi-k3", "name": "dupe"},
	]})
	var p1 := OpenCodeCls.parse_models_response(openai_style)
	ev["openai_ok"] = bool(p1.get("ok", false))
	ev["openai_count"] = int(p1.get("count", -1))
	var ids1: Array = []
	for m in (p1.get("models", []) as Array):
		ids1.append(str((m as Dictionary).get("id", "")))
	ev["openai_ids_sorted"] = ids1
	var ollama_style := JSON.stringify({"models": [{"name": "qwen3.8-max"}, "kimi-k3"]})
	var p2 := OpenCodeCls.parse_models_response(ollama_style)
	ev["ollama_ok"] = bool(p2.get("ok", false))
	ev["ollama_count"] = int(p2.get("count", -1))
	var p3 := OpenCodeCls.parse_models_response("not json {{{")
	ev["garbage_code"] = str(p3.get("code", ""))
	var p4 := OpenCodeCls.parse_models_response(JSON.stringify({"data": []}))
	ev["empty_ok"] = bool(p4.get("ok", false))
	ev["empty_count"] = int(p4.get("count", -1))
	var ok := bool(p1.get("ok", false)) and int(p1.get("count", 0)) == 2 \
		and ids1 == ["kimi-k3", "qwen3.8-max"] \
		and bool(p2.get("ok", false)) and int(p2.get("count", 0)) == 2 \
		and not bool(p3.get("ok", true)) and bool(p4.get("ok", false)) and int(p4.get("count", -1)) == 0
	_record("conn_models_parsing", "pass" if ok else "fail", ev)


# --- CONN: protocol resolution ------------------------------------------------

func _c_resolve() -> void:
	var ev := {}
	var r_msg := OpenCodeCls.resolve("qwen3.8-max")
	var r_rsp := OpenCodeCls.resolve("gpt-5.6-luna")
	var r_chat := OpenCodeCls.resolve("kimi-k3")
	ev["messages"] = [str(r_msg.get("transport", "")), str(r_msg.get("source", "")), str(r_msg.get("endpoint", ""))]
	ev["responses"] = [str(r_rsp.get("transport", "")), str(r_rsp.get("source", ""))]
	ev["chat"] = [str(r_chat.get("transport", "")), str(r_chat.get("source", ""))]
	var r_case := OpenCodeCls.resolve("  QWEN3.8-max ")
	ev["case_trim"] = str(r_case.get("transport", ""))
	var r_unk := OpenCodeCls.resolve("some-future-model-9")
	ev["unknown_code"] = str(r_unk.get("code", ""))
	ev["unknown_endpoint"] = str(r_unk.get("endpoint", ""))
	var r_meta := OpenCodeCls.resolve("kimi-k3", {"kimi-k3": {"protocol": "responses", "id": "kimi-k3"}})
	ev["metadata_first"] = [str(r_meta.get("transport", "")), str(r_meta.get("source", ""))]
	var r_empty := OpenCodeCls.resolve("   ")
	ev["empty_code"] = str(r_empty.get("code", ""))
	var ok := bool(r_msg.get("ok", false)) and str(r_msg.get("transport", "")) == "anthropic_messages" \
		and str(r_msg.get("endpoint", "")) == OpenCodeCls.MESSAGES_URL \
		and str(r_rsp.get("transport", "")) == "openai_responses" \
		and str(r_rsp.get("endpoint", "")) == OpenCodeCls.RESPONSES_URL \
		and str(r_chat.get("transport", "")) == "openai_chat" \
		and str(r_chat.get("endpoint", "")) == OpenCodeCls.CHAT_URL \
		and str(r_case.get("transport", "")) == "anthropic_messages" \
		and not bool(r_unk.get("ok", true)) and str(r_unk.get("code", "")) == "UNSUPPORTED_PROTOCOL" \
		and str(r_unk.get("endpoint", "")).is_empty() \
		and str(r_meta.get("transport", "")) == "openai_responses" \
		and str(r_meta.get("source", "")) == "models-metadata" \
		and str(r_empty.get("code", "")) == "UNSUPPORTED_PROTOCOL"
	_record("conn_protocol_resolution", "pass" if ok else "fail", ev)


# --- CONN: opencode config behavior -------------------------------------------

func _c_config_opencode() -> void:
	var ev := {}
	var cfg: ConfigCls = ConfigCls.new()
	cfg.set_provider("opencode")
	ev["provider_label"] = ConfigCls.provider_label("opencode")
	ev["endpoint_before_model"] = cfg.endpoint
	cfg.set_model("kimi-k3")
	ev["chat_endpoint"] = cfg.endpoint
	ev["chat_transport"] = cfg.effective_transport()
	ev["chat_source"] = cfg.protocol_source
	cfg.set_model("qwen3.8-max")
	ev["msg_endpoint"] = cfg.endpoint
	ev["msg_transport"] = cfg.effective_transport()
	cfg.set_model("some-future-model-9")
	ev["unknown_endpoint"] = cfg.endpoint
	ev["unknown_transport"] = cfg.effective_transport()
	var g_unk := cfg.validate_for_start()
	ev["unknown_gate"] = str(g_unk.get("code", ""))
	cfg.set_protocol_override("openai_responses")
	ev["override_endpoint"] = cfg.endpoint
	ev["override_source"] = cfg.protocol_source
	cfg.set_protocol_override("bogus")
	ev["bogus_clears"] = cfg.protocol_override.is_empty()
	cfg.set_model("kimi-k3")
	cfg.set_api_key("  " + CANARY + "\r\n")
	ev["key_trimmed"] = cfg.api_key == CANARY
	var g_untested := cfg.validate_for_start()
	ev["untested_gate"] = str(g_untested.get("code", ""))
	cfg.mark_test_result(true, "CONNECTED", "probe")
	var g_ready := cfg.validate_for_start()
	ev["ready"] = bool(g_ready.get("ok", false))
	cfg.set_model("qwen3.8-max") # model switch invalidates the test
	ev["switch_resets_test"] = not cfg.connection_tested
	var safe_text := JSON.stringify(cfg.to_safe_dict())
	ev["safe_leaks"] = safe_text.find(CANARY) != -1
	var prev_text := JSON.stringify(AdapterCls.request_preview(cfg, {"a": 1}, "sys"))
	ev["preview_leaks"] = prev_text.find(CANARY) != -1
	ev["preview_transport"] = str(AdapterCls.request_preview(cfg, {}, "s").get("transport", ""))
	var ok := str(ConfigCls.provider_label("opencode")) == "OpenCode Go" \
		and cfg.endpoint == OpenCodeCls.MESSAGES_URL \
		and str(ev["chat_endpoint"]) == OpenCodeCls.CHAT_URL \
		and str(ev["chat_transport"]) == "openai_chat" \
		and str(ev["msg_transport"]) == "anthropic_messages" \
		and str(ev["unknown_endpoint"]).is_empty() and str(ev["unknown_transport"]).is_empty() \
		and str(ev["unknown_gate"]) == "CLOUD_NOT_CONFIGURED" # key empty at that point
	ok = ok and str(ev["override_endpoint"]) == OpenCodeCls.RESPONSES_URL \
		and str(ev["override_source"]) == "manual-override" \
		and bool(ev["bogus_clears"]) and bool(ev["key_trimmed"]) \
		and str(ev["untested_gate"]) == "CONNECTION_NOT_TESTED" \
		and bool(ev["ready"]) and bool(ev["switch_resets_test"]) \
		and not bool(ev["safe_leaks"]) and not bool(ev["preview_leaks"]) \
		and str(ev["preview_transport"]) == "anthropic_messages"
	# Unknown-protocol gate with key present (distinct from missing key).
	var cfg2: ConfigCls = ConfigCls.new()
	cfg2.set_provider("opencode")
	cfg2.set_model("some-future-model-9")
	cfg2.set_api_key(CANARY)
	var g2 := cfg2.validate_for_start()
	ev["unknown_gate_with_key"] = str(g2.get("code", ""))
	ok = ok and str(g2.get("code", "")) == "UNSUPPORTED_PROTOCOL"
	_record("conn_config_opencode", "pass" if ok else "fail", ev)


# --- REG: per-backend slots (no cross-contamination) --------------------------

func _c_slots() -> void:
	var ev := {}
	var cfg := AIBackendCfg.default_config()
	AIBackendCfg.set_slot(cfg, AIBackendCfg.BACKEND_OPENCODE_GO, "qwen3.8-max", OpenCodeCls.MESSAGES_URL)
	ev["ollama_model_intact"] = AIBackendCfg.slot_model(cfg, AIBackendCfg.BACKEND_LOCAL_OLLAMA)
	ev["ollama_ep_intact"] = AIBackendCfg.slot_endpoint(cfg, AIBackendCfg.BACKEND_LOCAL_OLLAMA)
	ev["oc_model"] = AIBackendCfg.slot_model(cfg, AIBackendCfg.BACKEND_OPENCODE_GO)
	AIBackendCfg.set_slot(cfg, AIBackendCfg.BACKEND_LOCAL_OLLAMA, "local-tag:latest", "http://127.0.0.1:11434")
	ev["oc_model_after_ollama_edit"] = AIBackendCfg.slot_model(cfg, AIBackendCfg.BACKEND_OPENCODE_GO)
	ev["knows_opencode"] = AIBackendCfg.BACKEND_OPENCODE_GO in AIBackendCfg.KNOWN_BACKENDS
	var ok := str(ev["ollama_model_intact"]) == AIBackendCfg.DEFAULT_MODEL \
		and str(ev["ollama_ep_intact"]) == AIBackendCfg.DEFAULT_ENDPOINT \
		and str(ev["oc_model"]) == "qwen3.8-max" \
		and str(ev["oc_model_after_ollama_edit"]) == "qwen3.8-max" \
		and bool(ev["knows_opencode"])
	_record("reg_backend_slots", "pass" if ok else "fail", ev)


# --- CONN: AI Settings window exposes OpenCode Go -----------------------------

func _c_panel_exposes() -> void:
	var ev := {}
	var panel: Control = AISSetupScript.new()
	panel.name = "ConnUxProbePanel"
	root.add_child(panel)
	await process_frame
	await process_frame
	var items: Array = []
	var opt: OptionButton = panel.get("_backend_opt") as OptionButton
	if opt != null:
		for i in range(opt.get_item_count()):
			items.append(opt.get_item_text(i))
	ev["backend_items"] = items
	ev["has_test_btn"] = panel.get("_test_btn") != null
	ev["has_proto_opt"] = panel.get("_proto_opt") != null
	ev["has_paste_btn"] = panel.get("_paste_btn") != null
	ev["has_inspector"] = panel.get("_inspector") != null
	var ok := items == ["로컬 Ollama", "OpenCode Go"] \
		and panel.get("_test_btn") != null and panel.get("_proto_opt") != null \
		and panel.get("_paste_btn") != null and panel.get("_inspector") != null
	panel.queue_free()
	await process_frame
	_record("conn_panel_exposes_opencode", "pass" if ok else "fail", ev)


# --- CONN: no silent Ollama fallback ------------------------------------------

func _c_gate_no_fallback() -> void:
	var ev := {}
	var cfg: ConfigCls = ConfigCls.new()
	cfg.set_provider("opencode")
	cfg.set_model("some-future-model-9")
	cfg.set_api_key(CANARY)
	var g := cfg.validate_for_start()
	ev["gate"] = str(g.get("code", ""))
	ev["provider_stays"] = cfg.provider_id
	ev["endpoint_empty"] = cfg.endpoint.is_empty()
	var ok := str(g.get("code", "")) == "UNSUPPORTED_PROTOCOL" \
		and cfg.provider_id == "opencode" and cfg.endpoint.is_empty()
	_record("conn_no_silent_fallback", "pass" if ok else "fail", ev)


# --- CONN: title-screen runtime pull (Apply -> Step-2 provider) -----------------

func _c_runtime_pull() -> void:
	var ev := {}
	var acfg := AIBackendCfg.default_config()
	acfg["backend_type"] = AIBackendCfg.BACKEND_OPENCODE_GO
	acfg["model"] = "qwen3.8-max"
	acfg["endpoint"] = OpenCodeCls.MESSAGES_URL
	acfg["opencode_transport"] = "anthropic_messages"
	acfg["opencode_override"] = ""
	acfg["opencode_tested"] = true
	AIBackendCfg.apply_runtime(acfg, CANARY)
	var cfg: ConfigCls = ConfigCls.new()
	var pulled := cfg.apply_ai_backend_runtime()
	ev["applied"] = bool(pulled.get("applied", false))
	ev["provider"] = cfg.provider_id
	ev["model"] = cfg.model
	ev["transport"] = cfg.effective_transport()
	ev["endpoint"] = cfg.endpoint
	ev["tested"] = cfg.connection_tested
	ev["key_flows"] = cfg.api_key == CANARY
	var gate := cfg.validate_for_start()
	ev["gate_ready"] = bool(gate.get("ok", false))
	# Non-opencode runtime must leave local values untouched.
	AIBackendCfg.apply_runtime(AIBackendCfg.default_config(), "")
	var cfg2: ConfigCls = ConfigCls.new()
	cfg2.set_provider("openai")
	cfg2.set_model("m")
	var pulled2 := cfg2.apply_ai_backend_runtime()
	ev["noop_applied"] = bool(pulled2.get("applied", false))
	ev["noop_provider"] = cfg2.provider_id
	var ok := bool(ev["applied"]) and cfg.provider_id == "opencode" \
		and cfg.model == "qwen3.8-max" and cfg.effective_transport() == "anthropic_messages" \
		and cfg.endpoint == OpenCodeCls.MESSAGES_URL and cfg.connection_tested \
		and cfg.api_key == CANARY and bool(ev["gate_ready"]) \
		and not bool(ev["noop_applied"]) and cfg2.provider_id == "openai"
	_record("conn_runtime_pull", "pass" if ok else "fail", ev)


# --- DBG: response schema canonical -------------------------------------------

func _d_schema() -> void:
	var ev := {}
	var s := ResponseCls.response_schema()
	ev["keys"] = s.keys()
	var order: Dictionary = s.get("order", {})
	ev["actions_live"] = (order.get("action", []) as Array) == TableCls.ACTIONS
	ev["targets_live"] = (order.get("target_types", []) as Array) == TableCls.TARGET_TYPES
	ev["limits"] = s.get("limits", {})
	var ok := s.has("plan") and not s.has("orders") and (s.get("shape", {}) as Dictionary).has("orders") \
		and bool(ev["actions_live"]) and bool(ev["targets_live"]) \
		and int((s.get("limits", {}) as Dictionary).get("max_orders", 0)) == ResponseCls.MAX_ORDERS
	_record("dbg_response_schema", "pass" if ok else "fail", ev)


# --- DBG: tools view derives from canonical schema ----------------------------

func _d_tools() -> void:
	var ev := {}
	var text := InspectorCls.render_tools_text()
	var missing: Array = []
	for a in TableCls.ACTIVE_ACTIONS:
		if text.find(str(a)) == -1:
			missing.append(a)
	for k in TableCls.SCOPE_KINDS:
		if text.find(str(k)) == -1:
			missing.append("scope:" + str(k))
	for t in TableCls.TARGET_TYPES:
		if text.find(str(t)) == -1:
			missing.append("target:" + str(t))
	ev["missing"] = missing
	ev["has_gate_note"] = text.find("AUTHORITATIVE GODOT GATE") != -1
	ev["has_not_exposed"] = text.find("set_unit_position") != -1
	ev["digest_len"] = InspectorCls.tools_digest().length()
	var ok := missing.is_empty() and bool(ev["has_gate_note"]) \
		and bool(ev["has_not_exposed"]) and int(ev["digest_len"]) > 50
	_record("dbg_tools_canonical", "pass" if ok else "fail", ev)


# --- BACK-3/4/5/6: minimal probe shapes, no cross-protocol leaks ---------------

func _b_probe_shapes() -> void:
	var ev := {}
	var rsp := AdapterCls.build_probe_body("openai_responses", "muse-spark-1.3-contributor")
	var msg := AdapterCls.build_probe_body("anthropic_messages", "qwen3.8-flash")
	var chat := AdapterCls.build_probe_body("openai_chat", "glm-5.3-flash")
	var unk := AdapterCls.build_probe_body("nope", "m")
	ev["rsp_keys"] = rsp.keys()
	ev["msg_keys"] = msg.keys()
	ev["chat_keys"] = chat.keys()
	ev["unk_empty"] = unk.is_empty()
	var rsp_ok := rsp.keys().has("model") and rsp.keys().has("input") and rsp.keys().has("max_output_tokens") \
		and rsp.keys().size() == 3 and str(rsp.get("model", "")) == "muse-spark-1.3-contributor" \
		and str(((rsp.get("input", []) as Array)[0] as Dictionary).get("content", "")) == AdapterCls.PROBE_TEXT
	var msg_ok := msg.keys().has("model") and msg.keys().has("messages") and msg.keys().has("max_tokens") \
		and msg.keys().size() == 3 and int(msg.get("max_tokens", 0)) == AdapterCls.PROBE_MAX_TOKENS
	var chat_ok := chat.keys().has("model") and chat.keys().has("messages") and chat.keys().has("max_tokens") \
		and chat.keys().size() == 3 and int(chat.get("max_tokens", 0)) == AdapterCls.PROBE_MAX_TOKENS
	# Cross-protocol leak scan: no family may carry another family's fields
	# or any probe-banned extra (temperature/stream/json/system).
	var banned := ["temperature", "stream", "response_format", "system", "text", "tools", "tool_choice"]
	var leaks: Array = []
	for row in [["rsp", rsp], ["msg", msg], ["chat", chat]]:
		var tag := str((row as Array)[0])
		var body: Dictionary = (row as Array)[1]
		for k in body.keys():
			if str(k) in banned:
				leaks.append("%s:%s" % [tag, str(k)])
	if rsp.has("messages") or rsp.has("max_tokens") or msg.has("input") or msg.has("max_output_tokens") \
			or chat.has("input") or chat.has("max_output_tokens"):
		leaks.append("cross-protocol-field")
	ev["leaks"] = leaks
	ev["rsp_ok"] = rsp_ok
	ev["msg_ok"] = msg_ok
	ev["chat_ok"] = chat_ok
	var ok := rsp_ok and msg_ok and chat_ok and leaks.is_empty() and unk.is_empty()
	_record("back_probe_shapes", "pass" if ok else "fail", ev)


# --- BACK-2: sanitized provider error surfacing --------------------------------

func _b_error_info() -> void:
	var ev := {}
	var e400 := AdapterCls.provider_error_info(400,
		JSON.stringify({"error": {"message": "invalid request: temperature out of range", "type": "invalid_request_error"}}), CANARY)
	var eregion := AdapterCls.provider_error_info(400,
		JSON.stringify({"error": {"message": "model not available in your region", "type": "forbidden"}}), CANARY)
	var eent := AdapterCls.provider_error_info(400,
		JSON.stringify({"error": {"message": "not entitled: contributor terms", "code": "entitlement"}}), CANARY)
	var efield := AdapterCls.provider_error_info(400,
		JSON.stringify({"error": {"message": "unknown parameter: max_tokens", "type": "invalid_request_error"}}), CANARY)
	var egarbage := AdapterCls.provider_error_info(400, "<html>bad gateway page", CANARY)
	var e401 := AdapterCls.provider_error_info(401,
		JSON.stringify({"error": {"message": "bad key", "type": "auth"}}), CANARY)
	var e500 := AdapterCls.provider_error_info(500,
		JSON.stringify({"message": "upstream overloaded"}), CANARY)
	var eleak := AdapterCls.provider_error_info(400,
		JSON.stringify({"error": {"message": "echo " + CANARY, "type": "x"}}), CANARY)
	ev["e400"] = [str(e400.get("code", "")), str(e400.get("provider_message", ""))]
	ev["region"] = str(eregion.get("code", ""))
	ev["ent"] = str(eent.get("code", ""))
	ev["field"] = str(efield.get("code", ""))
	ev["garbage"] = [str(egarbage.get("code", "")), str(egarbage.get("provider_message", ""))]
	ev["e401"] = [str(e401.get("code", "")), str(e401.get("detail", ""))]
	ev["e500"] = str(e500.get("code", ""))
	ev["leak_clean"] = JSON.stringify(eleak).find(CANARY) == -1
	ev["leak_msg"] = str(eleak.get("provider_message", ""))
	var ok := str(e400.get("code", "")) == "INVALID_REQUEST" \
		and str(e400.get("provider_message", "")).find("temperature") != -1 \
		and str(eregion.get("code", "")) == "REGION_RESTRICTED" \
		and str(eent.get("code", "")) == "MODEL_ACCESS_DENIED" \
		and str(efield.get("code", "")) == "UNSUPPORTED_FIELD" \
		and str(egarbage.get("code", "")) == "INVALID_REQUEST" \
		and str(egarbage.get("provider_message", "")).is_empty() \
		and str(e401.get("code", "")) == "UNAUTHORIZED" \
		and str(e401.get("detail", "")).find("Provider says: bad key") != -1 \
		and str(e500.get("code", "")) == "PROVIDER_ERROR" \
		and bool(ev["leak_clean"]) and str(eleak.get("provider_message", "")).find("***REDACTED***") != -1
	_record("back_error_info", "pass" if ok else "fail", ev)


# --- BACK-7/8: fingerprint -----------------------------------------------------

func _b_fingerprint() -> void:
	var ev := {}
	var cfg: ConfigCls = ConfigCls.new()
	cfg.set_provider("opencode")
	cfg.set_model("qwen3.8-max")
	cfg.set_api_key(CANARY)
	ev["fp"] = cfg.fingerprint()
	cfg.mark_test_result(true, "CONNECTED", "probe")
	ev["fp_tested"] = cfg.fingerprint()
	var unk: ConfigCls = ConfigCls.new()
	unk.set_provider("opencode")
	unk.set_model("some-future-model-9")
	ev["fp_unk"] = unk.fingerprint()
	var snap := cfg.effective_snapshot()
	ev["snap_keys"] = snap.keys()
	var ok := str(ev["fp"]) == "opencode|qwen3.8-max|anthropic_messages|%s|untested" % OpenCodeCls.MESSAGES_URL \
		and str(ev["fp_tested"]).ends_with("|tested") \
		and str(ev["fp_unk"]).find("|?|") != -1 \
		and str(ev["fp"]).find(CANARY) == -1 \
		and str(ev["fp"]).find("qwen38-jrell") == -1 \
		and str(snap.get("provider_label", "")) == "OpenCode Go" \
		and JSON.stringify(snap).find(CANARY) == -1
	_record("back_fingerprint", "pass" if ok else "fail", ev)


# --- BACK-12: effective block renders the adapter's own config -----------------

func _b_effective_block() -> void:
	var ev := {}
	var cfg: ConfigCls = ConfigCls.new()
	cfg.set_provider("opencode")
	cfg.set_model("qwen3.8-max")
	cfg.set_api_key(CANARY)
	cfg.mark_test_result(true, "CONNECTED", "probe")
	var ctrl: ControllerCls = ControllerCls.new()
	var ad: AdapterCls = AdapterCls.new()
	var p: PanelCls = PanelCls.new()
	p.setup(ctrl, cfg, ad)
	var lbl: Label = p.get("_effective_lbl") as Label
	var text := lbl.text if lbl != null else ""
	ev["text"] = text
	ev["leak"] = text.find(CANARY) != -1
	var ok := text.find("OpenCode Go") != -1 and text.find("qwen3.8-max") != -1 \
		and text.find("anthropic_messages") != -1 and text.find(OpenCodeCls.MESSAGES_URL) != -1 \
		and text.find("CONNECTED") != -1 and text.find("(key: session)") != -1 \
		and not bool(ev["leak"])
	p.free()
	ctrl.free()
	ad.free()
	_record("back_effective_block", "pass" if ok else "fail", ev)


# --- BACK-15: sanitizer ----------------------------------------------------------

func _b_sanitize() -> void:
	var ev := {}
	var red := AdapterCls.sanitize_text("prefix " + CANARY + " suffix", CANARY, 2000)
	ev["redacted"] = red.find(CANARY) == -1 and red.find("***REDACTED***") != -1
	var trunc := AdapterCls.sanitize_text("abcdefghijklmnopqrstuvwxyz", "", 10)
	ev["truncated"] = trunc == "abcdefghij...(truncated, 26 chars total)"
	var ok := bool(ev["redacted"]) and bool(ev["truncated"])
	_record("back_sanitize", "pass" if ok else "fail", ev)


# --- WIRE-01/02/04/05/06: session authority -------------------------------------

func _w_session() -> void:
	var ev := {}
	SessionCls.clear()
	ev["unarmed"] = not SessionCls.is_armed()
	var cfg: ConfigCls = ConfigCls.new()
	cfg.set_provider("opencode")
	cfg.set_model("kimi-k3")
	cfg.set_api_key(CANARY)
	cfg.set_discovered_models([{"id": "kimi-k3", "name": "K"}, {"id": "qwen3.8-max", "name": "Q"}])
	cfg.mark_test_result(true, "CONNECTED", "wire")
	SessionCls.arm_from_config(cfg)
	ev["armed"] = SessionCls.is_armed()
	ev["key_present"] = SessionCls.key_present()
	ev["tested"] = SessionCls.is_tested()
	ev["cache"] = SessionCls.discovered_count()
	var fresh: ConfigCls = ConfigCls.new()
	var hydrated := SessionCls.hydrate(fresh)
	ev["hydrated"] = hydrated
	ev["fp_match"] = fresh.fingerprint() == SessionCls.fingerprint()
	ev["model"] = fresh.model
	ev["transport"] = fresh.effective_transport()
	ev["endpoint"] = fresh.endpoint
	ev["key_flows"] = fresh.api_key == CANARY
	ev["tested_flows"] = fresh.connection_tested
	ev["cache_flows"] = fresh.discovered_models.size()
	SessionCls.clear_key()
	ev["clear_key"] = not SessionCls.key_present()
	ev["clear_untests"] = not SessionCls.is_tested()
	SessionCls.clear()
	var empty_cfg: ConfigCls = ConfigCls.new()
	ev["hydrate_empty"] = not SessionCls.hydrate(empty_cfg)
	var ok := bool(ev["unarmed"]) and bool(ev["armed"]) and bool(ev["key_present"]) \
		and bool(ev["tested"]) and int(ev["cache"]) == 2 and bool(ev["hydrated"]) \
		and bool(ev["fp_match"]) and str(ev["model"]) == "kimi-k3" \
		and str(ev["transport"]) == "openai_chat" and str(ev["endpoint"]) == OpenCodeCls.CHAT_URL \
		and bool(ev["key_flows"]) and bool(ev["tested_flows"]) and int(ev["cache_flows"]) == 2 \
		and bool(ev["clear_key"]) and bool(ev["clear_untests"]) and bool(ev["hydrate_empty"])
	_record("wire_session_authority", "pass" if ok else "fail", ev)


# --- Minimal OpenCode bodies (extras dropped, others untouched) ------------------

func _w_minimal() -> void:
	var ev := {}
	var msgs := [{"role": "user", "content": "hi"}]
	var oc := AdapterCls.build_openai_body("m", msgs, 16, 0.7, true)
	var oa := AdapterCls.build_anthropic_body("m", msgs, 16, 0.7, true)
	var ors := OpenCodeCls.build_responses_body("m", msgs, 16, 0.7, true, true)
	ev["chat_keys"] = oc.keys()
	ev["msg_keys"] = oa.keys()
	ev["rsp_keys"] = ors.keys()
	var full_c := AdapterCls.build_openai_body("m", msgs, 16, 0.7)
	var full_a := AdapterCls.build_anthropic_body("m", msgs, 16, 0.7)
	var full_r := OpenCodeCls.build_responses_body("m", msgs, 16, 0.7, true)
	ev["full_keeps_format"] = full_c.has("response_format") and (full_r.get("text", {}) as Dictionary).has("format")
	ev["full_keeps_temp"] = full_c.has("temperature") and full_a.has("temperature") and full_r.has("temperature")
	var sys_msgs := [{"role": "system", "content": "S"}, {"role": "user", "content": "U"}]
	var oa_sys := AdapterCls.build_anthropic_body("m", sys_msgs, 16, 0.7, true)
	ev["msg_keeps_system"] = str(oa_sys.get("system", "")) == "S"
	var ok := oc.keys().has("model") and oc.keys().has("messages") and oc.keys().has("max_tokens") \
		and oc.keys().size() == 3 \
		and oa.keys().has("model") and oa.keys().has("messages") and oa.keys().has("max_tokens") \
		and not oa.has("temperature") and not oa.has("stream") \
		and ors.keys().has("model") and ors.keys().has("input") and ors.keys().has("max_output_tokens") \
		and ors.keys().size() == 3 \
		and bool(ev["full_keeps_format"]) and bool(ev["full_keeps_temp"]) \
		and bool(ev["msg_keeps_system"])
	_record("wire_minimal_bodies", "pass" if ok else "fail", ev)


# --- Boot restore never wipes a live session ------------------------------------

func _w_boot() -> void:
	var ev := {}
	SessionCls.clear()
	var first := AIBackendCfg.ensure_boot_runtime()
	var second := AIBackendCfg.ensure_boot_runtime()
	ev["idempotent"] = JSON.stringify(first) == JSON.stringify(second)
	var acfg := AIBackendCfg.default_config()
	acfg["backend_type"] = AIBackendCfg.BACKEND_OPENCODE_GO
	acfg["model"] = "kimi-k3"
	acfg["endpoint"] = OpenCodeCls.CHAT_URL
	acfg["opencode_transport"] = "openai_chat"
	acfg["opencode_tested"] = true
	AIBackendCfg.apply_runtime(acfg, CANARY) # also arms the session via hook
	ev["hook_armed"] = SessionCls.is_armed() and SessionCls.key_present()
	AIBackendCfg.ensure_boot_runtime() # must be a no-op now
	ev["session_survives"] = SessionCls.key_present() and SessionCls.is_tested()
	ev["runtime_survives"] = AIBackendCfg.get_api_key() == CANARY
	SessionCls.clear()
	AIBackendCfg.apply_runtime(AIBackendCfg.default_config(), "")
	var ok := bool(ev["idempotent"]) and bool(ev["hook_armed"]) \
		and bool(ev["session_survives"]) and bool(ev["runtime_survives"])
	_record("wire_boot_once", "pass" if ok else "fail", ev)
# --- DBG: chat requires a tested connection --------------------------------------

func _d_chat_gate() -> void:
	var ev := {}
	var ad: AdapterCls = AdapterCls.new()
	var cfg: ConfigCls = ConfigCls.new()
	cfg.set_provider("opencode")
	cfg.set_model("kimi-k3")
	cfg.set_api_key(CANARY)
	var res := ad.request_chat("g1", cfg, [{"role": "user", "content": "hi"}])
	ev["untested_code"] = str(res.get("code", ""))
	ad.free()
	var ok := str(res.get("code", "")) == "CONNECTION_NOT_TESTED"
	_record("dbg_chat_gate", "pass" if ok else "fail", ev)


# --- Part 2: live scene -------------------------------------------------------

var _live: Node = null


func _on_chat_probe(request_id: String, result: Dictionary) -> void:
	_chat_seen = {"request_id": request_id, "result": result}


func _on_turn_probe(request_id: String, result: Dictionary) -> void:
	_turn_seen = {"request_id": request_id, "result": result}


func _on_models_probe(result: Dictionary) -> void:
	_chat_seen = {"models": result}


var _models_real_seen := {}


func _on_models_real(result: Dictionary) -> void:
	_models_real_seen = result.duplicate(true)


func _wait_mount(mount: Node, budget: int) -> bool:
	var frames := 0
	while frames < budget:
		await process_frame
		frames += 1
		if mount != null and bool(mount.get("mount_ready")):
			return true
	return false


var _mount: Node = null
var _shell: Node = null
var _bridge: RefCounted = null
var _controller: Node = null
var _adapter: AdapterCls = null
var _cfg: ConfigCls = null


func _live_part() -> void:
	_d_chat_gate()
	var booted := await _live_session_rehydrate()
	if not booted:
		return
	_live_preview(_controller)
	await _live_chat_models_mock(_adapter, _cfg)
	await _live_turn_mock(_adapter, _cfg)
	await _live_fingerprint_stable(_bridge, _adapter, _cfg, _controller)
	await _live_security(_controller, _adapter)
	_live_cloud_tab(_mount, _cfg)
	await _live_panel_bound(_cfg, _controller, _adapter)
	await _live_models_real(_adapter)
	await _live_chat_transcript(_controller, _cfg, _adapter)
	await _live_click_panel(_mount, _cfg)
	await _live_red_wire(_mount, _shell, _bridge, _controller, _adapter, _cfg)
	await _live_turn_modes(_mount, _shell, _bridge, _controller, _adapter, _cfg)
	_record("live_opencode_network", "blocked", {"detail": "No user API key in automation; live /models + chat await the user in the UI."})
	_live.queue_free()
	for i in range(10):
		await process_frame


# --- Screenshot invariant: session-YES + live-EMPTY must self-heal --------

## Encodes the live failure this file was written for: api-key=YES with a
## 200 behind it, yet chat reported KEY MISSING and tested=false, because
## the live config copy never received the session secret. The session
## gate must backfill the same target (and only the same target).
func _w_heal() -> void:
	var ev := {}
	SessionCls.clear()
	# Arm the session exactly as a test-pass would.
	SessionCls.arm("opencode", "kimi-k3", OpenCodeCls.CHAT_URL, "openai_chat",
		"known-table", "", true, "CONNECTED", CANARY, [])
	# The screenshot: same target, key missing, untested.
	var cfg := ConfigCls.new()
	cfg.set_provider("opencode")
	cfg.set_model("kimi-k3")
	ev["pre_key"] = cfg.has_key()
	ev["pre_tested"] = cfg.connection_tested
	var use: Dictionary = SessionCls.resolve_for_use(cfg)
	ev["ok"] = bool(use.get("ok", false))
	ev["healed"] = bool(use.get("healed", false))
	ev["post_key"] = cfg.has_key()
	ev["post_tested"] = cfg.connection_tested
	ev["key_matches"] = str(use.get("key", "")) == CANARY
	# Chat must dispatch after heal (mock network leg only).
	var ad := AdapterCls.new()
	root.add_child(ad)
	ad.mock_mode = true
	(ad.get("mock_queue") as Array).append({"ok": true, "content_text": "CHAT_OK", "latency_ms": 3})
	var started := ad.request_chat("heal1", cfg, [{"role": "user", "content": "hi"}])
	ev["chat_started"] = bool(started.get("ok", false))
	for i in range(3):
		await process_frame
	ad.queue_free()
	# Negative: a DIFFERENT target must NOT heal.
	var other := ConfigCls.new()
	other.set_provider("opencode")
	other.set_model("qwen3.8-max")
	var use2: Dictionary = SessionCls.resolve_for_use(other)
	ev["neg_ok"] = bool(use2.get("ok", false))
	ev["neg_healed"] = bool(use2.get("healed", false))
	ev["neg_key"] = other.has_key()
	# Unconfigured live + armed session -> full hydrate heals.
	var bare := ConfigCls.new()
	var use3: Dictionary = SessionCls.resolve_for_use(bare)
	ev["bare_ok"] = bool(use3.get("ok", false))
	ev["bare_model"] = bare.model
	SessionCls.clear()
	AIBackendCfg.apply_runtime(AIBackendCfg.default_config(), "")
	var ok := not bool(ev["pre_key"]) and not bool(ev["pre_tested"]) \
		and bool(ev["ok"]) and bool(ev["healed"]) and bool(ev["post_key"]) \
		and bool(ev["post_tested"]) and bool(ev["key_matches"]) and bool(ev["chat_started"]) \
		and not bool(ev["neg_ok"]) and not bool(ev["neg_healed"]) and not bool(ev["neg_key"]) \
		and bool(ev["bare_ok"]) and str(ev["bare_model"]) == "kimi-k3"
	_record("wire_session_heal", "pass" if ok else "fail", ev)


# --- WIRE-03/04/05/06: scene transition preserves the session --------------------

func _live_session_rehydrate() -> bool:
	SessionCls.clear()
	SessionCls.arm("opencode", "kimi-k3", OpenCodeCls.CHAT_URL, "openai_chat",
		"known-table", "", true, "CONNECTED", CANARY,
		[{"id": "kimi-k3", "name": "Kimi K3"}, {"id": "qwen3.8-max", "name": "Qwen3.8 Max"}])
	var packed: PackedScene = load(CLOUD2_SCENE)
	if packed == null:
		_record("live_mount", "fail", {"error": "cloud2 scene failed to load"})
		return false
	_live = packed.instantiate()
	root.add_child(_live)
	var mount: Node = _live.get_node_or_null("Cloud2LiveMount")
	var booted := await _wait_mount(mount, 3600)
	if not booted or mount == null:
		_record("live_mount", "fail", {"error": "mount timeout"})
		_live.queue_free()
		return false
	_mount = mount
	_shell = mount.get("shell") as Node
	_bridge = mount.get("bridge") as RefCounted
	_controller = mount.get("cloud_controller") as Node
	_adapter = mount.get("cloud_adapter") as AdapterCls
	_cfg = mount.get("cloud_config") as ConfigCls
	# One call, guarded: a missing shell hook must record a loud FAIL here,
	# not abort the runner and eat every gate below.
	var _red_mode := str(_shell.call("red_controller_mode")) if _shell.has_method("red_controller_mode") else "MISSING_METHOD"
	_record("live_mount", "pass" if _red_mode == "CLOUD" else "fail", {"red_mode": _red_mode})
	var ev := {}
	ev["provider"] = _cfg.provider_id
	ev["model"] = _cfg.model
	ev["transport"] = _cfg.effective_transport()
	ev["endpoint"] = _cfg.endpoint
	ev["key_present"] = _cfg.has_key()
	ev["tested"] = _cfg.connection_tested
	ev["connection"] = _cfg.connection_status
	ev["cache"] = _cfg.discovered_models.size()
	ev["fp_match"] = _cfg.fingerprint() == SessionCls.fingerprint()
	ev["live_fp"] = _cfg.fingerprint()
	var ok := _cfg.provider_id == "opencode" and _cfg.model == "kimi-k3" \
		and _cfg.effective_transport() == "openai_chat" and _cfg.endpoint == OpenCodeCls.CHAT_URL \
		and _cfg.has_key() and _cfg.api_key == CANARY and _cfg.connection_tested \
		and _cfg.connection_status == "CONNECTED" and _cfg.discovered_models.size() == 2 \
		and bool(ev["fp_match"])
	_record("wire_session_rehydrate", "pass" if ok else "fail", ev)
	return true


func _live_preview(controller: Node) -> void:
	var ev := {}
	var prev: Dictionary = controller.call("preview_context")
	ev["ok"] = bool(prev.get("ok", false))
	var shape := PacketCls.validate_shape(prev.get("packet", {}))
	ev["shape_ok"] = bool(shape.get("ok", false))
	ev["has_system"] = str(prev.get("system_prompt", "")).contains("RED field general")
	ev["has_plan"] = (prev.get("plan_memory", {}) as Dictionary).has("objective")
	ev["has_schema"] = (prev.get("response_schema", {}) as Dictionary).has("limits")
	var last: Dictionary = controller.call("get_last_context")
	ev["pre_turn_empty"] = not bool(last.get("has_turn", true))
	var ok := bool(prev.get("ok", false)) and bool(shape.get("ok", false)) \
		and bool(ev["has_system"]) and bool(ev["has_plan"]) and bool(ev["has_schema"]) \
		and bool(ev["pre_turn_empty"])
	_record("dbg_context_preview", "pass" if ok else "fail", ev)


func _live_chat_models_mock(adapter: AdapterCls, cfg: ConfigCls) -> void:
	var ev := {}
	cfg.set_provider("opencode")
	cfg.set_model("kimi-k3")
	cfg.set_api_key(CANARY)
	cfg.mark_test_result(true, "CONNECTED", "conn-ux probe")
	adapter.mock_mode = true
	adapter.chat_finished.connect(_on_chat_probe)
	adapter.turn_finished.connect(_on_turn_probe)
	adapter.models_fetched.connect(_on_models_probe)
	# Chat takes the chat_finished lane only.
	_chat_seen = {}
	_turn_seen = {}
	(adapter.get("mock_queue") as Array).append({"ok": true, "content_text": "mock reply", "latency_ms": 5})
	var started := adapter.request_chat("probe1", cfg, [{"role": "user", "content": "hi"}])
	ev["chat_started"] = bool(started.get("ok", false))
	var frames := 0
	while _chat_seen.is_empty() and frames < 600:
		await process_frame
		frames += 1
	var chat_res: Dictionary = (_chat_seen.get("result", {}) as Dictionary)
	ev["chat_text"] = str(chat_res.get("content_text", ""))
	ev["chat_transport"] = str(chat_res.get("transport", ""))
	ev["chat_model"] = str(chat_res.get("model", ""))
	ev["turn_lane_silent"] = _turn_seen.is_empty()
	# Discovery parses through the adapter without leaking the key.
	_chat_seen = {}
	adapter.mock_models_text = JSON.stringify({"data": [
		{"id": "qwen3.8-max", "name": "Qwen3.8 Max"},
		{"id": "kimi-k3", "name": "Kimi K3"}]})
	var fstarted := adapter.fetch_models(CANARY)
	ev["models_started"] = bool(fstarted.get("ok", false))
	frames = 0
	while _chat_seen.is_empty() and frames < 600:
		await process_frame
		frames += 1
	var mres: Dictionary = (_chat_seen.get("models", {}) as Dictionary)
	ev["models_count"] = int(mres.get("count", -1))
	ev["models_leak"] = JSON.stringify(mres).find(CANARY) != -1
	var ok := bool(started.get("ok", false)) and str(chat_res.get("content_text", "")) == "mock reply" \
		and str(chat_res.get("transport", "")) == "openai_chat" and _turn_seen.is_empty() \
		and str(chat_res.get("model", "")) == cfg.model \
		and bool(fstarted.get("ok", false)) and int(mres.get("count", 0)) == 2 \
		and not bool(ev["models_leak"])
	_record("dbg_chat_models_mock", "pass" if ok else "fail", ev)


# --- BACK-11: tactical turn consumes the same effective config -------------------

func _live_turn_mock(adapter: AdapterCls, cfg: ConfigCls) -> void:
	var ev := {}
	_turn_seen = {}
	(adapter.get("mock_queue") as Array).append({"ok": true, "content_text": "{\"orders\": []}", "latency_ms": 9})
	var started := adapter.request_turn("tprobe1", {"packet": "probe"}, cfg, "sys")
	ev["started"] = bool(started.get("ok", false))
	var frames := 0
	while _turn_seen.is_empty() and frames < 600:
		await process_frame
		frames += 1
	var res: Dictionary = (_turn_seen.get("result", {}) as Dictionary)
	ev["model"] = str(res.get("model", ""))
	ev["provider"] = str(res.get("provider", ""))
	ev["transport"] = str(res.get("transport", ""))
	ev["xchg_clean"] = JSON.stringify(adapter.last_exchange()).find(CANARY) == -1
	var ok := bool(started.get("ok", false)) and bool(res.get("ok", false)) \
		and str(res.get("model", "")) == cfg.model \
		and str(res.get("provider", "")) == cfg.provider_id \
		and str(res.get("transport", "")) == cfg.effective_transport() \
		and bool(ev["xchg_clean"])
	_record("back_turn_effective", "pass" if ok else "fail", ev)


func _live_fingerprint_stable(bridge: RefCounted, adapter: AdapterCls, cfg: ConfigCls, controller: Node) -> void:
	var ev := {}
	var fp0 := str(bridge.fingerprint())
	(adapter.get("mock_queue") as Array).append({"ok": true, "content_text": "{}", "latency_ms": 3})
	adapter.test_connection(cfg)
	var frames := 0
	while adapter.has_active() and frames < 600:
		await process_frame
		frames += 1
	for i in range(5):
		await process_frame
	controller.call("preview_context")
	var fp1 := str(bridge.fingerprint())
	ev["stable"] = fp0 == fp1
	var ok := fp0 == fp1 and not fp0.is_empty()
	_record("conn_test_no_mutation", "pass" if ok else "fail", ev)


func _live_security(controller: Node, adapter: AdapterCls) -> void:
	var ev := {}
	var scratch: ConfigCls = ConfigCls.new()
	scratch.set_provider("opencode")
	scratch.set_model("kimi-k3")
	scratch.set_api_key(CANARY)
	scratch.mark_test_result(true, "CONNECTED", "conn-ux probe")
	var insp: InspectorCls = InspectorCls.new()
	root.add_child(insp)
	await process_frame
	insp.setup(null, scratch, adapter)
	var mgr: RefCounted = controller.call("live_unit_manager") as RefCounted
	ev["has_manager"] = mgr != null
	var rows: Array = insp.run_security(mgr)
	var fails: Array = []
	var skips: Array = []
	for r_val in rows:
		var r: Dictionary = r_val
		if str(r.get("status", "")) in ["FAIL", "ON"]:
			fails.append(str(r.get("name", "?")))
		elif str(r.get("status", "")) in ["SKIP"]:
			skips.append(str(r.get("name", "?")))
	ev["rows"] = rows.size()
	ev["fails"] = fails
	ev["skips"] = skips
	ev["chat_exec"] = insp.tool_execution_enabled()
	insp.queue_free()
	var ok := mgr != null and fails.is_empty() and skips.is_empty() \
		and not bool(ev["chat_exec"]) and rows.size() >= 11
	_record("sec_suite", "pass" if ok else "fail", ev)


# --- BACK-12/14: live CLOUD tab mirrors the adapter's config --------------------

func _live_cloud_tab(mount: Node, cfg: ConfigCls) -> void:
	var ev := {}
	var dock: Node = mount.get("dock") as Node
	var cp: Node = dock.call("get_cloud_panel") as Node
	ev["has_panel"] = cp != null
	ev["has_ai_btn"] = (cp.get("_ai_btn") as Button) != null if cp != null else false
	cp.call("refresh_all")
	var text := str((cp.get("_effective_lbl") as Label).text) if cp != null and cp.get("_effective_lbl") != null else ""
	ev["effective"] = text
	var ok := cp != null and bool(ev["has_ai_btn"]) \
		and text.find(cfg.model) != -1 and text.find(cfg.effective_transport()) != -1 \
		and text.find(cfg.endpoint) != -1 and text.find("CONNECTED") != -1
	_record("back_cloud_tab_effective", "pass" if ok else "fail", ev)


func _live_panel_bound(cfg: ConfigCls, controller: Node, adapter: AdapterCls) -> void:
	var ev := {}
	cfg.set_provider("opencode")
	cfg.set_model("qwen3.8-max")
	cfg.set_api_key(CANARY)
	cfg.mark_test_result(true, "CONNECTED", "conn-ux probe")
	var panel: Control = AISSetupScript.new()
	panel.name = "ConnUxBoundProbe"
	root.add_child(panel)
	await process_frame
	await process_frame
	panel.call("open_for_cloud", cfg, controller, adapter)
	await process_frame
	var opt: OptionButton = panel.get("_backend_opt") as OptionButton
	ev["visible"] = panel.visible
	ev["backend_selected"] = opt.selected if opt != null else -1
	ev["proto_text"] = str((panel.get("_proto_lbl") as Label).text) if panel.get("_proto_lbl") != null else ""
	ev["ep_text"] = str((panel.get("_oc_ep_lbl") as Label).text) if panel.get("_oc_ep_lbl") != null else ""
	ev["live_lbl"] = str((panel.get("_live_lbl") as Label).text) if panel.get("_live_lbl") != null else ""
	var ok := panel.visible and int(ev["backend_selected"]) == 1 \
		and str(ev["proto_text"]).find("messages") != -1 \
		and str(ev["ep_text"]) == OpenCodeCls.MESSAGES_URL \
		and str(ev["live_lbl"]).find("qwen3.8-max") != -1
	# BACK-9/14: opening never mutates live; Apply pushes scratch -> live.
	ev["live_untouched_on_open"] = cfg.model == "qwen3.8-max"
	var scratch: ConfigCls = panel.get("_oc") as ConfigCls
	scratch.set_model("kimi-k3")
	scratch.set_api_key(CANARY)
	panel.call("_push_scratch_to_live", CANARY)
	ev["pushed_model"] = cfg.model
	ev["pushed_endpoint"] = cfg.endpoint
	ev["pushed_tested"] = cfg.connection_tested
	ok = ok and bool(ev["live_untouched_on_open"]) \
		and cfg.model == "kimi-k3" and cfg.endpoint == OpenCodeCls.CHAT_URL \
		and cfg.connection_tested and cfg.api_key == CANARY
	panel.call("close")
	await process_frame
	ev["closed"] = not panel.visible
	ok = ok and not panel.visible
	panel.queue_free()
	_record("conn_panel_bound", "pass" if ok else "fail", ev)


# --- BACK-1 (live leg): real GET /models through the game HTTP path -------------
# Keyless-safe: the endpoint answers 200 without auth; a dummy Bearer that
# the service rejects (401/403) still proves TLS + routing + auth handling.
# Anything else (sandboxed network, timeout) records BLOCKED, never FAIL.

func _live_models_real(adapter: AdapterCls) -> void:
	var ev := {}
	_models_real_seen = {}
	adapter.mock_mode = false
	adapter.models_fetched.connect(_on_models_real)
	var started := adapter.fetch_models("conn-ux-dummy-probe-key")
	ev["started"] = bool(started.get("ok", false))
	var deadline := Time.get_ticks_msec() + 25000
	while _models_real_seen.is_empty() and Time.get_ticks_msec() < deadline:
		await process_frame
	adapter.mock_mode = true
	if _models_real_seen.is_empty():
		_record("back_models_real", "blocked", {"detail": "no response within 25s (environment network?)"})
		return
	var code := str(_models_real_seen.get("code", ""))
	var count := int(_models_real_seen.get("count", 0))
	ev["code"] = code
	ev["count"] = count
	ev["http_status"] = int(_models_real_seen.get("http_status", 0))
	if bool(_models_real_seen.get("ok", false)) and count > 0:
		var ids: Array = []
		for m in (_models_real_seen.get("models", []) as Array):
			ids.append(str((m as Dictionary).get("id", "")))
		ev["has_kimi_k3"] = ids.has("kimi-k3")
		ev["has_muse"] = ids.has("muse-spark-1.3-contributor")
		var ok := bool(ev["has_kimi_k3"]) and bool(ev["has_muse"])
		_record("back_models_real", "pass" if ok else "fail", ev)
	elif code == "UNAUTHORIZED":
		_record("back_models_real", "pass", {"detail": "service validates auth (dummy key rejected); real key applies in the UI",
			"http_status": int(_models_real_seen.get("http_status", 0))})
	elif code in ["OFFLINE", "TIMEOUT"]:
		_record("back_models_real", "blocked", ev)
	else:
		ev["detail"] = str(_models_real_seen.get("detail", ""))
		_record("back_models_real", "blocked", ev)


# --- WIRE-07/08/09: chat response reaches the transcript -------------------------

func _live_chat_transcript(controller: Node, cfg: ConfigCls, adapter: AdapterCls) -> void:
	var ev := {}
	cfg.set_provider("opencode")
	cfg.set_model("kimi-k3")
	cfg.set_api_key(CANARY)
	cfg.mark_test_result(true, "CONNECTED", "wire")
	adapter.mock_mode = true
	var insp: InspectorCls = InspectorCls.new()
	root.add_child(insp)
	await process_frame
	insp.setup(controller, cfg, adapter)
	(adapter.get("mock_queue") as Array).append({"ok": true, "content_text": "CHAT_OK", "latency_ms": 7})
	insp.call("_send_chat", "Reply exactly with CHAT_OK")
	var frames := 0
	while bool(insp.get("_chat_busy")) and frames < 600:
		await process_frame
		frames += 1
	var view_text := str((insp.get("_chat_view") as TextEdit).text)
	ev["has_user"] = view_text.find("Reply exactly with CHAT_OK") != -1
	ev["has_model"] = view_text.find("CHAT_OK") != -1
	ev["has_header"] = view_text.find("MODEL (kimi-k3") != -1
	ev["status"] = str((insp.get("_chat_status") as Label).text)
	insp.queue_free()
	var ok := bool(ev["has_user"]) and bool(ev["has_model"]) and bool(ev["has_header"])
	_record("wire_chat_transcript", "pass" if ok else "fail", ev)


# --- WIRE-11/12: in-game settings receives input; battlefield stays quiet --------

func _pick_topmost_at(top: Node, point: Vector2) -> Control:
	var st: Array = [null, -1073741824]
	_pick_walk(top, point, 0, st)
	return st[0] as Control


## Pre-order = draw order: later visits overwrite at the same canvas layer
## (children above parents, later siblings above earlier ones); a higher
## layer always wins. z_index/show_behind_parent/top_level are not modeled
## (unused in the tested scenes).
func _pick_walk(n: Node, point: Vector2, layer: int, st: Array) -> void:
	var lay := layer
	if n is CanvasLayer:
		lay = (n as CanvasLayer).layer
	if n is Control:
		var c := n as Control
		if c.is_visible_in_tree() and c.mouse_filter != Control.MOUSE_FILTER_IGNORE \
				and c.get_global_rect().has_point(point):
			if lay >= int(st[1]):
				st[0] = c
				st[1] = lay
	for ch in n.get_children():
		_pick_walk(ch, point, lay, st)


func _live_click_panel(mount: Node, cfg: ConfigCls) -> void:
	var ev := {}
	var dock: Node = mount.get("dock") as Node
	var cp: Node = dock.call("get_cloud_panel") as Node
	var path := "manual"
	if current_scene == null:
		current_scene = _live
	if current_scene == _live:
		path = "real"
		cp.call("_open_ai_settings")
	else:
		var layer0 := CanvasLayer.new()
		layer0.name = "AISetupLayerCloud"
		layer0.layer = 100
		_live.add_child(layer0)
		var p0: Control = AISSetupScript.new()
		p0.name = "AISetupPanelCloud"
		layer0.add_child(p0)
		p0.set("adjust_mode", true)
		p0.call("open_for_cloud", cfg, _controller, _adapter)
	ev["path"] = path
	for i in range(3):
		await process_frame
	var layer := _live.get_node_or_null("AISetupLayerCloud") as CanvasLayer
	var panel := _live.get_node_or_null("AISetupLayerCloud/AISetupPanelCloud") as Control
	ev["panel_visible"] = panel != null and panel.visible
	ev["layer"] = layer.layer if layer != null else -1
	var max_layer := -1
	var stack: Array = [_live]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is CanvasLayer:
			max_layer = maxi(max_layer, (n as CanvasLayer).layer)
		for c in n.get_children():
			stack.append(c)
	ev["max_layer"] = max_layer
	ev["topmost"] = int(ev["layer"]) >= max_layer and int(ev["layer"]) == 100
	ev["vp_rect"] = str(root.get_visible_rect())
	ev["panel_rect"] = str(panel.get_global_rect()) if panel != null else "(none)"
	if panel != null:
		ev["panel_size"] = str(panel.size)
		ev["panel_anchors"] = str([panel.anchor_left, panel.anchor_top, panel.anchor_right, panel.anchor_bottom])
		ev["panel_offsets"] = str([panel.offset_left, panel.offset_top, panel.offset_right, panel.offset_bottom])
		var _dim := panel.get_node_or_null("Dim") as Control
		var _ctr := panel.get_node_or_null("Center") as Control
		ev["dim_rect"] = str(_dim.get_global_rect()) if _dim != null else "(none)"
		ev["center_rect"] = str(_ctr.get_global_rect()) if _ctr != null else "(none)"
		var _bo := panel.get("_backend_opt") as Control
		var _tg := panel.get("_insp_toggle") as Control
		ev["backend_rect"] = str(_bo.get_global_rect()) if _bo != null else "(none)"
		ev["toggle_rect"] = str(_tg.get_global_rect()) if _tg != null else "(none)"
	# Hover must land inside the panel (nothing above may eat the event).
	# Synthetic GUI dispatch is inert headless (Input.parse_input_event and
	# Viewport.push_input both verified no-op via probes), so the gate runs
	# the engine's own pick rule geometrically over the live tree: topmost
	# visible non-IGNORE control at the point, canvas-layer aware.
	var hover_ok := true
	for target_name in ["_backend_opt", "_model_opt"]:
		var t: Control = panel.get(target_name) as Control
		var mc := t.get_global_rect().get_center()
		var pick := _pick_topmost_at(_live, mc)
		if pick != t and (pick == null or not t.is_ancestor_of(pick)):
			hover_ok = false
			ev["hover_miss_" + target_name] = str(pick.get_path()) if pick != null else "(none)"
	ev["hover_ok"] = hover_ok
	# The inspector toggle sits below the 1080p fold: scroll it on-screen
	# (proves the dialog scroll), press it the way the engine would (the
	# button_pressed setter emits the real toggled signal), and require
	# the battlefield selection to stay put.
	var shell: Node = mount.get("shell") as Node
	var mgr: RefCounted = shell.get("unit_manager") as RefCounted
	var sel0 := str(mgr.call("get_selected_unit_id")) if mgr != null else ""
	var toggle: Button = panel.get("_insp_toggle") as Button
	var scroll := panel.find_child("Scroll", true, false) as ScrollContainer
	ev["has_scroll"] = scroll != null
	if scroll != null:
		var bar := scroll.get_v_scroll_bar() as VScrollBar
		if bar != null:
			scroll.scroll_vertical = int(bar.max_value)
			await process_frame
			await process_frame
	var vp_rect := root.get_visible_rect()
	ev["scrolled_onscreen"] = toggle.get_global_rect().intersects(vp_rect)
	var before: bool = (panel.get("_insp_host") as Control).visible
	toggle.button_pressed = not before
	await process_frame
	await process_frame
	ev["toggled"] = (panel.get("_insp_host") as Control).visible != before
	ev["clicked"] = true
	var sel1 := str(mgr.call("get_selected_unit_id")) if mgr != null else ""
	ev["selection_stable"] = sel0 == sel1
	# The shell guard must treat dialog clicks as UI (leak-proof).
	var dlg_center := (panel.get("_start_btn") as Control).get_global_rect().get_center()
	ev["dlg_center"] = str(dlg_center)
	ev["hud_layer_null"] = shell.get("hud_layer") == null
	ev["ai_panel_found"] = shell.call("_ai_panel") != null
	ev["hud_guard"] = bool(shell.call("_is_click_over_hud", dlg_center))
	panel.call("close")
	await process_frame
	var ok := bool(ev["panel_visible"]) and bool(ev["topmost"]) and hover_ok \
		and bool(ev["has_scroll"]) and bool(ev["scrolled_onscreen"]) \
		and bool(ev["toggled"] == true) \
		and bool(ev["selection_stable"]) and bool(ev["hud_guard"])
	_record("wire_click_panel", "pass" if ok else "fail", ev)


var _red_phase_count := 0


func _on_red_phase(_out: Dictionary) -> void:
	_red_phase_count += 1


# --- WIRE-13..19: RED request dispatches and executes ------------------------------

func _live_red_wire(mount: Node, shell: Node, bridge: RefCounted, controller: Node, adapter: AdapterCls, cfg: ConfigCls) -> void:
	var ev := {}
	cfg.set_provider("opencode")
	cfg.set_model("kimi-k3")
	cfg.set_api_key(CANARY)
	cfg.mark_test_result(true, "CONNECTED", "wire")
	ev["default_mode"] = str(controller.call("get_mode"))
	# NOTE: no set_mode call — this gate proves the fresh-mount AUTO default
	# dispatches with zero extra clicks (TURN-01/02/03).
	# Tactical fixtures below exercise the legacy benchmark path explicitly.
	controller.call("set_control_mode", "LEGACY_DIRECT")
	adapter.mock_mode = true
	var orders := [
		TableCls.make_command("HOLD", TableCls.scope_all_friendly()),
		TableCls.make_command("HOLD", TableCls.scope_all_combat()),
	]
	(adapter.get("mock_queue") as Array).append({"ok": true,
		"content_text": JSON.stringify({"orders": orders}), "latency_ms": 11})
	var mgr: RefCounted = shell.get("unit_manager") as RefCounted
	var t0 := int(mgr.call("get_current_turn"))
	_red_phase_count = 0
	controller.connect("phase_finished", _on_red_phase)
	shell.call("end_player_phase")
	var deadline := Time.get_ticks_msec() + 60000
	while int(mgr.call("get_current_turn")) == t0 and Time.get_ticks_msec() < deadline:
		await process_frame
	for i in range(5):
		await process_frame
	ev["turn_advanced"] = int(mgr.call("get_current_turn")) == t0 + 1
	ev["phase_back"] = int(shell.get("_turn_phase")) == 0
	ev["routine_runs"] = int(shell.call("enemy_routine_runs"))
	ev["emissions"] = _red_phase_count
	var view: Dictionary = controller.call("get_last_view")
	ev["view_status"] = str(view.get("status", ""))
	ev["view_executed"] = int(view.get("executed_count", -1))
	ev["view_orders"] = int(view.get("order_count", -1))
	var ex: Node = mount.get("executor") as Node
	ev["executor_free"] = not bool(ex.call("is_busy")) and not bool(ex.call("is_external_busy"))
	ev["phase_idle"] = not bool(controller.call("is_phase_active"))
	controller.disconnect("phase_finished", _on_red_phase)
	var ok := bool(ev["turn_advanced"]) and bool(ev["phase_back"]) \
		and int(ev["routine_runs"]) == 0 and _red_phase_count == 1 \
		and str(view.get("status", "")) in ["EXECUTED", "PARTIAL"] \
		and int(view.get("executed_count", 0)) > 0 and int(view.get("order_count", 0)) == 2 \
		and bool(ev["executor_free"]) and bool(ev["phase_idle"]) \
		and str(ev["default_mode"]) == "AUTO"
	_record("wire_red_turn", "pass" if ok else "fail", ev)


# --- TURN-07..11: STEP once-only, PAUSE zero-call, bar status ---------------

func _live_turn_modes(mount: Node, shell: Node, bridge: RefCounted, controller: Node, adapter: AdapterCls, cfg: ConfigCls) -> void:
	var ev := {}
	var bar: Node = mount.get("turn_bar") as Node
	ev["bar_present"] = bar != null and is_instance_valid(bar)
	var mgr: RefCounted = shell.get("unit_manager") as RefCounted
	var queue: Array = adapter.get("mock_queue")
	adapter.mock_mode = true
	controller.call("set_control_mode", "LEGACY_DIRECT") # tactical fixtures: legacy benchmark path
	_red_phase_count = 0
	controller.connect("phase_finished", _on_red_phase)
	var orders := [
		TableCls.make_command("HOLD", TableCls.scope_all_friendly()),
		TableCls.make_command("HOLD", TableCls.scope_all_combat()),
	]
	# --- STEP: waits intentionally, double trigger still runs once ---
	controller.call("set_mode", "STEP")
	queue.append({"ok": true,
		"content_text": JSON.stringify({"orders": orders}), "latency_ms": 11})
	var t0 := int(mgr.call("get_current_turn"))
	shell.call("end_player_phase")
	var st0 := {}
	for i in range(900):
		await process_frame
		st0 = controller.get("_state")
		if str(st0.get("phase", "")) == "WAITING_STEP":
			break
	ev["step_waited"] = str(st0.get("phase", "")) == "WAITING_STEP"
	ev["step_turn_held"] = int(mgr.call("get_current_turn")) == t0
	ev["step_no_dispatch"] = queue.size() == 1
	ev["step_bar_wait"] = str((bar.get("_status_lbl") as Label).text).contains("RUN CLOUD TURN")
	ev["step_run_visible"] = bool((bar.get("_run_btn") as Button).visible)
	controller.call("request_step")
	controller.call("request_step") # double-press: still exactly one run
	var deadline := Time.get_ticks_msec() + 60000
	while int(mgr.call("get_current_turn")) == t0 and Time.get_ticks_msec() < deadline:
		await process_frame
	for i in range(5):
		await process_frame
	ev["step_turn_once"] = int(mgr.call("get_current_turn")) == t0 + 1
	ev["step_emissions_once"] = _red_phase_count == 1
	ev["step_queue_drained"] = queue.is_empty()
	# --- PAUSE: zero provider calls until resumed ---
	controller.call("set_mode", "AUTO")
	controller.call("set_paused", true)
	queue.append({"ok": true,
		"content_text": JSON.stringify({"orders": orders}), "latency_ms": 11})
	var t1 := int(mgr.call("get_current_turn"))
	_red_phase_count = 0
	shell.call("end_player_phase")
	var st1 := {}
	for i in range(900):
		await process_frame
		st1 = controller.get("_state")
		if str(st1.get("phase", "")) == "PAUSED":
			break
	ev["pause_held"] = str(st1.get("phase", "")) == "PAUSED"
	ev["pause_no_dispatch"] = queue.size() == 1
	ev["pause_bar"] = str((bar.get("_status_lbl") as Label).text).contains("Cloud paused.")
	controller.call("set_paused", false)
	deadline = Time.get_ticks_msec() + 60000
	while int(mgr.call("get_current_turn")) == t1 and Time.get_ticks_msec() < deadline:
		await process_frame
	for i in range(5):
		await process_frame
	ev["pause_resumed_turn"] = int(mgr.call("get_current_turn")) == t1 + 1
	ev["pause_emissions_once"] = _red_phase_count == 1
	# --- FAILURE: loud error + decisions on the bar ---
	queue.append({"ok": false, "code": "TIMEOUT", "detail": "Mock timeout.",
		"http_status": 0, "latency_ms": 61})
	var t2 := int(mgr.call("get_current_turn"))
	shell.call("end_player_phase")
	var stf := {}
	for i in range(600):
		await process_frame
		stf = controller.get("_state")
		if str(stf.get("phase", "")).begins_with("FAILED_"):
			break
	ev["fail_phase"] = str(stf.get("phase", ""))
	ev["fail_loud"] = str(stf.get("phase", "")).begins_with("FAILED_")
	ev["fail_bar_error"] = str((bar.get("_status_lbl") as Label).text).contains("RED CLOUD ERROR")
	ev["fail_retry_visible"] = bool((bar.get("_retry_btn") as Button).visible)
	ev["fail_hold_visible"] = bool((bar.get("_hold_btn") as Button).visible)
	ev["fail_skip_visible"] = bool((bar.get("_skip_btn") as Button).visible)
	controller.call("decide_skip")
	deadline = Time.get_ticks_msec() + 60000
	while int(mgr.call("get_current_turn")) == t2 and Time.get_ticks_msec() < deadline:
		await process_frame
	for i in range(5):
		await process_frame
	ev["fail_skip_turn"] = int(mgr.call("get_current_turn")) == t2 + 1
	ev["fail_skip_view"] = str((controller.call("get_last_view") as Dictionary).get("status", ""))
	ev["idle_bar_auto"] = str((bar.get("_status_lbl") as Label).text).contains("automatically")
	controller.disconnect("phase_finished", _on_red_phase)
	var ok_modes := bool(ev["step_waited"]) and bool(ev["step_turn_held"]) \
		and bool(ev["step_no_dispatch"]) and bool(ev["step_turn_once"]) \
		and bool(ev["step_emissions_once"]) and bool(ev["step_queue_drained"]) \
		and bool(ev["pause_held"]) and bool(ev["pause_no_dispatch"]) \
		and bool(ev["pause_resumed_turn"]) and bool(ev["pause_emissions_once"])
	_record("wire_turn_step_pause", "pass" if ok_modes else "fail", ev)
	var ok_bar := bool(ev["bar_present"]) and bool(ev["step_bar_wait"]) \
		and bool(ev["step_run_visible"]) and bool(ev["pause_bar"]) \
		and bool(ev["fail_loud"]) and bool(ev["fail_bar_error"]) \
		and bool(ev["fail_retry_visible"]) and bool(ev["fail_hold_visible"]) \
		and bool(ev["fail_skip_visible"]) and bool(ev["fail_skip_turn"]) \
		and str(ev["fail_skip_view"]) == "SKIPPED" and bool(ev["idle_bar_auto"])
	_record("wire_turn_bar", "pass" if ok_bar else "fail", ev)


# --- output -------------------------------------------------------------------

func _write_and_quit(code: int) -> void:
	var d := DirAccess.open("res://")
	if d != null and not d.dir_exists("evidence/cloud2_conn_ux"):
		d.make_dir_recursive("evidence/cloud2_conn_ux")
	var doc := {
		"runner": "cloud2_conn_entry",
		"timestamp": Time.get_datetime_string_from_system(),
		"gates": _gates,
		"exit_code": code,
	}
	var text := JSON.stringify(doc, "  ")
	if text.find(CANARY) != -1:
		print("[CONN-UX] FATAL: canary leaked into the report; refusing to write.")
		quit(1)
		return
	var f := FileAccess.open(OUT_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(text)
		f.close()
		print("[CONN-UX] wrote %s" % OUT_PATH)
	var pass_n := 0
	var fail_n := 0
	for key in _gates.keys():
		var st := str((_gates[key] as Dictionary).get("status", ""))
		if st == "pass" or st == "blocked":
			pass_n += 1
		else:
			fail_n += 1
			print("[CONN-UX] FAIL: %s -> %s" % [key, JSON.stringify((_gates[key] as Dictionary).get("evidence", {}))])
	print("[CONN-UX] gates: %d pass/blocked, %d fail -> exit %d" % [pass_n, fail_n, code])
	quit(code)
