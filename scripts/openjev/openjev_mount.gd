class_name OpenJevMount
extends Node

## OPENJEV LIVE V0 — Human-vs-OpenJEV mount (additive; Step-1/Step-2 untouched).
##
## Sits beside the instanced Step2R battlefield in the OpenJev test scene:
##   Cloud1LiveBridge (live battle adapter, owns no state)
##   Cloud1LiveExecutor (explicit HOLD-ALL fallback path only)
##   Cloud2Config + Cloud2Adapter + Cloud2PlanMemory (General layer, shared)
##   OpenJevController (RED Hands: OpenJev direct legal-action authority)
## The controller is bound into shell.openjev_red_controller, which routes
## the RED phase to OpenJev (shell.red_controller_mode() == "OPENJEV") and
## leaves the deterministic routine dormant. The human keeps BLUE.
##
## Lifecycle: the owned OpenJev worker boots on scene entry (async, with
## visible status) and shuts down cleanly on scene exit. The user runs
## nothing manually.

const BridgeCls = preload("res://scripts/cloud1/cloud1_live_bridge.gd")
const ExecutorCls = preload("res://scripts/cloud1/cloud1_live_executor.gd")
const ConfigCls = preload("res://scripts/cloud2/cloud2_config.gd")
const SessionCls = preload("res://scripts/cloud2/cloud2_session.gd")
const AdapterCls = preload("res://scripts/cloud2/cloud2_adapter.gd")
const PlanCls = preload("res://scripts/cloud2/cloud2_plan_memory.gd")
const ControllerCls = preload("res://scripts/openjev/openjev_controller.gd")
const LaunchCls = preload("res://scripts/openjev/openjev_launcher.gd")
const HttpCls = preload("res://scripts/openjev/openjev_http.gd")
const DebugAgentCfgCls = preload("res://scripts/cloud2/cloud2_debug_agent_config.gd")

const BOOT_POLL_SEC := 0.5
const HUD_POLL_SEC := 0.5

var shell: Node = null
var det: Node = null
var bridge: RefCounted = null
var executor: ExecutorCls = null
var oj_config: ConfigCls = null
var oj_adapter: AdapterCls = null
var oj_plan: PlanCls = null
var oj_controller: ControllerCls = null

var mount_ready := false
var mount_error := ""

var _hud: PanelContainer = null
var _hud_lines: Array = []
var _boot_task := 0
var _hud_task := 0


func _ready() -> void:
	print("[OpenJevMount] _ready called")
	call_deferred("_bootstrap")


func _exit_tree() -> void:
	_boot_task += 1
	_hud_task += 1
	var res: Dictionary = LaunchCls.shutdown_owned()
	if bool(res.get("orphan", false)):
		push_warning("[OpenJevMount] owned worker pid=%s did not exit; orphan=%s" % [
			str(res.get("pid", "?")), str(res.get("orphan", true))])
	else:
		print("[OpenJevMount] worker shutdown: %s" % JSON.stringify(res))


func is_ready() -> bool:
	return mount_ready and bridge != null and bridge.is_loaded() \
		and oj_controller != null and shell != null \
		and shell.get("openjev_red_controller") == oj_controller


func red_controller_mode() -> String:
	if shell != null and shell.has_method("red_controller_mode"):
		return str(shell.call("red_controller_mode"))
	return "DETERMINISTIC"


func get_stats() -> Dictionary:
	return {
		"mount_ready": mount_ready,
		"mount_error": mount_error,
		"red_mode": red_controller_mode(),
		"enemy_routine_runs": int(shell.call("enemy_routine_runs")) if shell != null and shell.has_method("enemy_routine_runs") else -1,
		"service": LaunchCls.status_snapshot(),
		"controller": oj_controller.openjev_stats() if oj_controller != null else {},
	}


func _on_openjev_state_changed(state: Dictionary) -> void:
	if shell == null or not is_instance_valid(shell):
		return
	if int(shell.get("_turn_phase")) != 1: # ENEMY_PHASE only
		return
	var phase := str(state.get("phase", ""))
	if not bool(state.get("phase_active", false)) and phase != "WAITING_STEP":
		return
	var turn := 0
	if bridge != null:
		var mgr: RefCounted = bridge.get_manager()
		if mgr != null:
			turn = int(mgr.call("get_current_turn"))
	var lbl := shell.get("turn_label") as Label
	if lbl != null:
		if phase.begins_with("FAILED_"):
			lbl.text = "제 %d 턴 (적군) — OPENJEV 실패: HOLD-ALL" % turn
		elif phase == "PAUSED":
			lbl.text = "제 %d 턴 (적군) — OPENJEV 일시정지" % turn
		else:
			lbl.text = "제 %d 턴 (적군) — OPENJEV %s" % [turn, phase]
	if phase.begins_with("FAILED_"):
		if shell.has_method("_show_phase_banner"):
			shell.call("_show_phase_banner",
				"OPENJEV %s — explicit fallback" % phase, true, 2.5)


func _bootstrap() -> void:
	print("[OpenJevMount] _bootstrap starting")
	for _i in range(600):
		shell = get_parent().get_node_or_null("Battle")
		if shell != null and shell.get("unit_manager") != null and shell.get("hud_layer") != null:
			break
		await get_tree().process_frame
	if shell == null or shell.get("unit_manager") == null or shell.get("hud_layer") == null:
		mount_error = "Battle dependencies not found."
		push_warning("[OpenJevMount] %s" % mount_error)
		return
	det = shell.get_node_or_null("Step7Integration")
	for _j in range(600):
		if det != null and bool(det.get("ready_for_step7")):
			break
		await get_tree().process_frame
	if det == null or not bool(det.get("ready_for_step7")):
		mount_error = "Step7Integration not ready."
		push_warning("[OpenJevMount] %s" % mount_error)
		return
	bridge = BridgeCls.new()
	if not bridge.bind(shell, det):
		mount_error = "Bridge binding failed."
		push_warning("[OpenJevMount] %s" % mount_error)
		return
	executor = ExecutorCls.new()
	executor.name = "OpenJevLiveExecutor"
	add_child(executor)
	executor.bind(bridge)
	# General layer: identical wiring to the Cloud mount (shared provider
	# settings + session hydration), so the same General plans RED.
	oj_config = ConfigCls.new()
	oj_config.load_local_settings() # non-secret fields only; key stays empty
	if SessionCls.is_armed():
		SessionCls.hydrate(oj_config)
		print("[OpenJevMount] session hydrated: fp=%s" % oj_config.fingerprint())
		SessionCls.trace("OPENJEV_MOUNT_HYDRATE", null, oj_config)
	else:
		SessionCls.trace("OPENJEV_MOUNT_NOSESSION", null, oj_config)
		var pulled := oj_config.apply_ai_backend_runtime()
		if bool(pulled.get("applied", false)):
			print("[OpenJevMount] AI Settings runtime applied: protocol=%s tested=%s" % [
				str(pulled.get("protocol", "?")), str(bool(pulled.get("tested", false)))])
		SessionCls.trace("OPENJEV_MOUNT_FALLBACK", null, oj_config)
	oj_adapter = AdapterCls.new()
	oj_adapter.name = "OpenJevGeneralAdapter"
	add_child(oj_adapter)
	oj_plan = PlanCls.new()
	oj_controller = ControllerCls.new()
	oj_controller.name = "OpenJevController"
	add_child(oj_controller)
	oj_controller.setup(bridge, executor, oj_adapter, oj_config, oj_plan)
	oj_controller.set_control_mode("MISSION_HIERARCHY")
	var _gb := DebugAgentCfgCls.resolve_backend()
	if DebugAgentCfgCls.canonical_backend(_gb) == "EXTERNAL_AGENT":
		var _switched: Dictionary = oj_controller.set_agent_backend("DEBUG_AGENT")
		print("[OpenJevMount] GENERAL_BACKEND=%s -> %s" % [_gb, JSON.stringify(_switched)])
	oj_controller.cloud_state_changed.connect(_on_openjev_state_changed)
	oj_controller.openjev_decision.connect(_on_openjev_decision)
	_build_hud()
	# Boot the owned worker asynchronously (never blocks scene entry).
	_boot_task += 1
	_boot_async(_boot_task)
	_hud_task += 1
	_hud_poll_async(_hud_task)
	# Route the RED phase to OpenJev (deterministic off).
	shell.set("openjev_red_controller", oj_controller)
	SessionCls.trace("OPENJEV_SCENE_READY", null, oj_config)
	mount_ready = true
	print("[OpenJevMount] human-vs-openjev mounted | live=%s | turn=%d | red=%s | worker=%s" % [
		str(bridge.scenario_id()), int(bridge.get_manager().get_current_turn()),
		red_controller_mode(), str(LaunchCls.status_snapshot().get("status", "?"))])


func _boot_async(my: int) -> void:
	if not LaunchCls.auto_enabled():
		LaunchCls.mark_disabled("EXPLICIT_OFF")
		return
	if str(LaunchCls.status_snapshot().get("status", "COLD")) != "COLD":
		return
	if LaunchCls.fixed_url_mode():
		await _boot_fixed_async(my)
		return
	var spawned: Dictionary = LaunchCls.spawn_owned_or_fixed()
	if not bool(spawned.get("ok", false)):
		return
	if str(spawned.get("status", "")) == "READY":
		return
	var deadline := Time.get_ticks_msec() + LaunchCls.startup_timeout_ms()
	while Time.get_ticks_msec() < deadline:
		if my != _boot_task:
			return
		if LaunchCls.is_ready() or LaunchCls.is_disabled():
			return
		if not LaunchCls.boot_in_progress():
			return
		if not LaunchCls.owned_pid_alive():
			LaunchCls.mark_disabled("WORKER_DIED_DURING_BOOT")
			return
		var snap: Dictionary = LaunchCls.status_snapshot()
		var res: Dictionary = await _http_get_json(
			str(snap.get("host", "127.0.0.1")), int(snap.get("port", 11441)),
			"/health", 4.0)
		if my != _boot_task:
			return
		if LaunchCls.is_ready() or LaunchCls.is_disabled():
			return
		if bool(res.get("ok", false)) and res.get("body", {}) is Dictionary:
			var v: Dictionary = LaunchCls.verify_health_dict(res.get("body", {}))
			if bool(v.get("ok", false)):
				LaunchCls.mark_ready(v.get("identity", {}), (res.get("body", {}) as Dictionary).get("load", {}))
				_announce_ready()
				return
			LaunchCls.mark_disabled(str(v.get("error", "HEALTH_MISMATCH")))
			return
		await get_tree().create_timer(BOOT_POLL_SEC).timeout
	LaunchCls.on_boot_timeout()


func _boot_fixed_async(my: int) -> void:
	var deadline := Time.get_ticks_msec() + LaunchCls.FIXED_PROBE_TIMEOUT_MS * 3
	while Time.get_ticks_msec() < deadline:
		if my != _boot_task:
			return
		if LaunchCls.is_ready() or LaunchCls.is_disabled():
			return
		var ep: Dictionary = LaunchCls.fixed_endpoint()
		var res: Dictionary = await _http_get_json(
			str(ep.get("host", "127.0.0.1")), int(ep.get("port", 11441)),
			"/health", 4.0)
		if my != _boot_task:
			return
		if LaunchCls.is_ready() or LaunchCls.is_disabled():
			return
		if bool(res.get("ok", false)) and res.get("body", {}) is Dictionary:
			var v: Dictionary = LaunchCls.verify_health_dict(res.get("body", {}))
			if bool(v.get("ok", false)):
				LaunchCls.adopt_fixed_health(v.get("identity", {}),
					(res.get("body", {}) as Dictionary).get("load", {}),
					str(ep.get("host", "")), int(ep.get("port", 11441)))
				_announce_ready()
				return
			LaunchCls.mark_disabled("FIXED_IDENTITY_MISMATCH: %s" % str(v.get("error", "?")))
			return
		await get_tree().create_timer(BOOT_POLL_SEC).timeout
	LaunchCls.mark_disabled("FIXED_UNREACHABLE")


## Async HTTP GET across frames (non-blocking): bounded poll slices with
## awaits between them so scene entry never stalls on the worker.
func _http_get_json(host: String, port: int, path: String,
	timeout_sec: float) -> Dictionary:
	var deadline := Time.get_ticks_msec() + int(timeout_sec * 1000.0)
	var http := HTTPClient.new()
	if http.connect_to_host(host, port) != OK:
		return {"ok": false}
	while Time.get_ticks_msec() < deadline:
		http.poll()
		var st := http.get_status()
		if st == HTTPClient.STATUS_CONNECTED:
			break
		if st != HTTPClient.STATUS_RESOLVING and st != HTTPClient.STATUS_CONNECTING:
			http.close()
			return {"ok": false}
		await get_tree().process_frame
	if http.get_status() != HTTPClient.STATUS_CONNECTED:
		http.close()
		return {"ok": false}
	if http.request(HTTPClient.METHOD_GET, path, PackedStringArray(), "") != OK:
		http.close()
		return {"ok": false}
	while http.get_status() == HTTPClient.STATUS_REQUESTING:
		if Time.get_ticks_msec() > deadline:
			http.close()
			return {"ok": false}
		http.poll()
		await get_tree().process_frame
	if http.get_response_code() != 200:
		http.close()
		return {"ok": false}
	var chunks := PackedByteArray()
	while http.get_status() == HTTPClient.STATUS_BODY:
		if Time.get_ticks_msec() > deadline:
			http.close()
			return {"ok": false}
		http.poll()
		var chunk := http.read_response_body_chunk()
		if chunk.size() > 0:
			chunks.append_array(chunk)
		else:
			await get_tree().process_frame
	http.close()
	var parsed: Variant = JSON.parse_string(chunks.get_string_from_utf8())
	if parsed is Dictionary:
		return {"ok": true, "body": parsed}
	return {"ok": false}


func _announce_ready() -> void:
	var snap: Dictionary = LaunchCls.status_snapshot()
	var load_info: Dictionary = snap.get("load_info", {})
	print("[OpenJevMount] worker READY load_s=%s vram=%s" % [
		str(load_info.get("load_s", "?")), str(load_info.get("vram_gb", "?"))])
	if shell != null and shell.has_method("_show_combat_log"):
		shell.call("_show_combat_log", "OPENJEV READY — model %s (load %ss, VRAM %sGB)" % [
			LaunchCls.MODEL_IDENTITY, str(load_info.get("load_s", "?")),
			str(load_info.get("vram_gb", "?"))])


func _on_openjev_decision(info: Dictionary) -> void:
	# HUD refreshes on its poll; decisions also hit print for log capture.
	var ev := str(info.get("event", "?"))
	if ev == "DECISION":
		print("[OpenJevMount] t%d #%d %s pool=%d lat=%.0fms exec=%s" % [
			int(info.get("turn", 0)), int(info.get("step", 0)),
			str(info.get("selected", "?")), int(info.get("candidate_count", 0)),
			float(info.get("latency_ms", 0.0)), str(bool(info.get("executed", false)))])
	else:
		print("[OpenJevMount] %s %s" % [ev, JSON.stringify(info)])


func _build_hud() -> void:
	var hud: CanvasLayer = shell.get("hud_layer") as CanvasLayer
	if hud == null:
		return
	_hud = PanelContainer.new()
	_hud.name = "OpenJevHUD"
	_hud.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_hud.offset_left = -360
	_hud.offset_top = 8
	_hud.offset_right = -8
	_hud.offset_bottom = 150
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.04, 0.08, 0.10, 0.88)
	sb.border_width_left = 2
	sb.border_width_top = 2
	sb.border_width_right = 2
	sb.border_width_bottom = 2
	sb.border_color = Color(0.35, 0.85, 0.75, 0.9)
	sb.corner_radius_top_left = 4
	sb.corner_radius_top_right = 4
	sb.corner_radius_bottom_right = 4
	sb.corner_radius_bottom_left = 4
	_hud.add_theme_stylebox_override("panel", sb)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 2)
	_hud.add_child(vb)
	_hud_lines = []
	for i in range(6):
		var lbl := Label.new()
		lbl.add_theme_font_size_override("font_size", 13)
		lbl.add_theme_color_override("font_color", Color(0.75, 0.95, 0.88))
		lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		vb.add_child(lbl)
		_hud_lines.append(lbl)
	hud.add_child(_hud)
	_refresh_hud()


func _hud_poll_async(my: int) -> void:
	while my == _hud_task and is_instance_valid(_hud):
		_refresh_hud()
		await get_tree().create_timer(HUD_POLL_SEC).timeout


func _refresh_hud() -> void:
	if _hud == null or not is_instance_valid(_hud) or _hud_lines.is_empty():
		return
	var svc: Dictionary = LaunchCls.status_snapshot()
	var st := str(svc.get("status", "?"))
	var ctl: Dictionary = oj_controller.openjev_stats() if oj_controller != null else {}
	var last: Dictionary = ctl.get("last", {})
	var head := "RED HANDS: OPENJEV LIVE"
	var head_col := Color(0.45, 1.0, 0.75)
	if st != "READY":
		head = "RED HANDS: OPENJEV %s" % st
		head_col = Color(1.0, 0.75, 0.35)
	if bool(ctl.get("fallback_active", false)):
		head = "OPENJEV ERROR -> FALLBACK ACTIVE"
		head_col = Color(1.0, 0.40, 0.35)
	(_hud_lines[0] as Label).text = head
	(_hud_lines[0] as Label).add_theme_color_override("font_color", head_col)
	(_hud_lines[1] as Label).text = "model: %s | %s" % [LaunchCls.MODEL_IDENTITY, st]
	var load_info: Dictionary = svc.get("load_info", {})
	(_hud_lines[2] as Label).text = "load: %ss | VRAM: %sGB | pid: %s" % [
		str(load_info.get("load_s", "?")), str(load_info.get("vram_gb", "?")),
		str(svc.get("pid", "?"))]
	(_hud_lines[3] as Label).text = "turns: %d | decisions: %d | fallback: %d | stale: %d" % [
		int(ctl.get("red_turns", 0)), int(ctl.get("decision_count", 0)),
		int(ctl.get("fallback_count", 0)), int(ctl.get("stale_count", 0))]
	(_hud_lines[4] as Label).text = "moves: %d | attacks: %d | waits: %d | fails: %d" % [
		int(ctl.get("moves", 0)), int(ctl.get("attacks", 0)),
		int(ctl.get("waits", 0)), int(ctl.get("exec_failures", 0))]
	var last_txt := "last: —"
	if not last.is_empty():
		if str(last.get("event", "")) == "DECISION":
			last_txt = "last: %s [pool=%d, %.1fs]" % [str(last.get("selected", "?")),
				int(last.get("candidate_count", 0)), float(last.get("latency_ms", 0.0)) / 1000.0]
		else:
			last_txt = "last: %s" % str(last.get("event", "?"))
	(_hud_lines[5] as Label).text = last_txt
