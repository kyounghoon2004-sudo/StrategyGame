class_name Cloud2Mount
extends Node

## CLOUD STEP 2 — Human-vs-Cloud mount (additive; Step-1 scene untouched).
##
## Sits beside the instanced Step2R battlefield in the Step-2 test scene and
## mounts the SAME battlefield + systems as Step 1, plus the Cloud RED side:
##   Cloud1LiveBridge / Overlay / Cloud1LiveExecutor / Cloud1Dock (CLOUD tab on)
##   Cloud2Config + Cloud2Adapter + Cloud2PlanMemory + LayaController
## RED BRAIN = the configured Cloud/API General (unchanged hierarchy:
## planning, missions, reviews, memory, trace). RED HANDS = Laya per-unit
## sequential (LayaController inherits the whole General layer and overrides
## only tactical execution; six-slot orders are computed for bookkeeping
## then explicitly bypassed). ONE controller instance owns RED — it is
## bound into shell.cloud_red_controller only, which routes the RED phase
## to it (shell.red_controller_mode() == "CLOUD+LAYA") and leaves the
## deterministic routine dormant. The human keeps the BLUE console.
##
## Lifecycle: the owned Laya worker boots on scene entry (async, with
## visible status) and shuts down cleanly on scene exit. The user runs
## nothing manually.

const BridgeCls = preload("res://scripts/cloud1/cloud1_live_bridge.gd")
const ExecutorCls = preload("res://scripts/cloud1/cloud1_live_executor.gd")
const DockCls = preload("res://scripts/cloud1/cloud1_dock.gd")
const OverlayCls = preload("res://scripts/cloud1/cloud1_preview_overlay.gd")
const ConfigCls = preload("res://scripts/cloud2/cloud2_config.gd")
const SessionCls = preload("res://scripts/cloud2/cloud2_session.gd")
const AdapterCls = preload("res://scripts/cloud2/cloud2_adapter.gd")
const PlanCls = preload("res://scripts/cloud2/cloud2_plan_memory.gd")
const ObsCls = preload("res://scripts/cloud1/cloud1_observation.gd")
const ControllerCls = preload("res://scripts/cloud2/cloud2_turn_controller.gd")
const LayaControllerCls = preload("res://scripts/laya/laya_controller.gd")
const LYLaunchCls = preload("res://scripts/laya/laya_launcher.gd")
const TurnBarCls = preload("res://scripts/cloud2/cloud2_turn_bar.gd")
## AGENT-MCP-PLAYTEST: structured tool bridge for the external coding agent
## (DEV/testing transport; adds no AI, reuses canonical paths only).
const AgentBridgeCls = preload("res://scripts/agent_playtest/agent_playtest_bridge.gd")
const DebugAgentCfgCls = preload("res://scripts/cloud2/cloud2_debug_agent_config.gd")
const WorkerLinkCls = preload("res://scripts/cloud2/cloud2_worker_handshake.gd")
const LocalBrainCls = preload("res://scripts/cloud2/cloud2_local_brain_launcher.gd")
const UtilityLiveCls = preload("res://scripts/utility_bot/utility_live_controller.gd")
const StrictCls = preload("res://scripts/selfplay/training_strict.gd")
const HandsABCls = preload("res://scripts/cloud_pipeline/hands_ab_controller.gd")
const AuthoringCls = preload("res://scripts/cloud2/cloud2_victory_authoring.gd")
const JevShadowCls = preload("res://scripts/cloud2/cloud2_jev_shadow.gd")
const JevLaunchCls = preload("res://scripts/cloud2/cloud2_jev_launcher.gd")

## "cloud" (default, unchanged Human-vs-Cloud) | "local_qwen8b" (DEV: Human vs
## Local (Qwen 8B)): the RED General is the local Qwen3-8B CSFT5 Brain served
## by a Godot-owned loopback worker. Local mode never reads cloud settings,
## session or AI-runtime config, runs STRICT (no repair / retry / fallback;
## an invalid plan is not executed), and auto-tests its own connection.
## "full_pipeline_v0" (DEV: Human vs Cloud General — CLOUD FULL PIPELINE V0):
## the same local CSFT5 Brain (strict) under the unalloc_v1 VictoryPlan
## contract, RED Hands = frozen Hand A + frozen Hand B (HandsABController,
## LayaLauncher HANDS_AB profile). No provider, agent, UtilityBot or base Laya.
@export var brain_mode := "cloud"
var _contract_prev := ""
var _jev_prev := ""
const STRICT_ENV := "TRAINING_STRICT_CONTRACT"
var _strict_prev := ""
var _local_task := 0

const BOOT_POLL_SEC := 0.5
const HUD_POLL_SEC := 0.5

var shell: Node = null
var det: Node = null
var bridge: RefCounted = null
var executor: ExecutorCls = null
var overlay: OverlayCls = null
var dock: DockCls = null
var cloud_config: ConfigCls = null
var cloud_adapter: AdapterCls = null
var cloud_plan: PlanCls = null
## The ONE merged RED controller: Cloud General brain + Laya hands.
var cloud_controller: LayaControllerCls = null
var utility_fallback_controller: Node = null
var turn_bar: TurnBarCls = null
## Structured playtest tool bridge (agent_command entry point).
var agent_bridge: AgentBridgeCls = null
## Live worker-General file channel (agent backends only; null otherwise).
var worker_link: WorkerLinkCls = null

var mount_ready := false
var mount_error := ""

var _hud: PanelContainer = null
var _hud_lines: Array = []
var _boot_task := 0
var _hud_task := 0


func _ready() -> void:
	print("[Cloud2Mount] _ready called")
	if _is_full_pipeline():
		# No old-JEV shadow worker in the full pipeline (it has no authority,
		# but nothing outside Brain -> Hand A -> Hand B may run for RED).
		_jev_prev = OS.get_environment("JEV_SHADOW_ENABLE")
		OS.set_environment("JEV_SHADOW_ENABLE", "0")
		JevShadowCls._enabled_cache = 0
		print("[Cloud2Mount] FULL PIPELINE: JEV shadow off (worker: %s)" % JSON.stringify(JevLaunchCls.shutdown_owned()))
		JevLaunchCls.mark_disabled("FULL_PIPELINE_V0: no JEV shadow in this mode")
	call_deferred("_bootstrap")


func _is_local_brain() -> bool:
	return brain_mode == "local_qwen8b" or _is_full_pipeline()


func _is_full_pipeline() -> bool:
	return brain_mode == "full_pipeline_v0"


func _exit_tree() -> void:
	_boot_task += 1
	_hud_task += 1
	if _is_local_brain():
		_local_task += 1
		print("[Cloud2Mount] local brain shutdown: %s" % JSON.stringify(LocalBrainCls.shutdown_owned()))
		OS.set_environment(STRICT_ENV, _strict_prev)
	if _is_full_pipeline():
		OS.set_environment(AuthoringCls.CONTRACT_MODE_ENV, _contract_prev)
		OS.set_environment("JEV_SHADOW_ENABLE", _jev_prev)
		# Other modes get their lazy shadow back (observe() re-ensures it).
		JevShadowCls._enabled_cache = -1
		JevLaunchCls._reset_to_cold()
	var res: Dictionary = LYLaunchCls.shutdown_owned()
	if bool(res.get("orphan", false)):
		push_warning("[Cloud2Mount] owned worker pid=%s did not exit; orphan=%s" % [
			str(res.get("pid", "?")), str(res.get("orphan", true))])
	else:
		print("[Cloud2Mount] worker shutdown: %s" % JSON.stringify(res))


func is_ready() -> bool:
	return mount_ready and dock != null and bridge != null and bridge.is_loaded() \
		and cloud_controller != null and shell != null and shell.get("cloud_red_controller") == cloud_controller


func red_controller_mode() -> String:
	if shell != null and shell.has_method("red_controller_mode"):
		return str(shell.call("red_controller_mode"))
	return "DETERMINISTIC"


## Surface RED Cloud waits/failures on the battlefield itself. The shell
## owns its labels on every phase transition, so these notes can never
## leak into the BLUE turn — but while RED waits, the human must see WHY
## (and where to decide) instead of a bare "ENEMY PHASE".
func _on_cloud_state_changed(state: Dictionary) -> void:
	if shell == null or not is_instance_valid(shell):
		return
	# Issue 1: bring the TRACE tab forward once per Cloud phase so the human
	# can watch deliberation -> decision -> execution live. UI-only.
	if dock != null and is_instance_valid(dock):
		dock.call("show_trace_for_phase", bool(state.get("phase_active", false)))
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
		if phase == "WAITING_STEP":
			lbl.text = "제 %d 턴 (적군) — CLOUD 대기: TRIGGER" % turn
		elif phase == "NEEDS_CONFIG":
			lbl.text = "제 %d 턴 (적군) — CLOUD BLOCKED: 설정 필요" % turn
		elif phase.begins_with("FAILED_"):
			lbl.text = "제 %d 턴 (적군) — CLOUD 실패: RETRY/SKIP" % turn
		elif phase == "PAUSED":
			lbl.text = "제 %d 턴 (적군) — CLOUD 일시정지" % turn
		else:
			lbl.text = "제 %d 턴 (적군) — CLOUD %s" % [turn, phase]
	if phase in ["WAITING_STEP", "NEEDS_CONFIG", "PAUSED"] or phase.begins_with("FAILED_"):
		if shell.has_method("_show_phase_banner"):
			shell.call("_show_phase_banner",
				"CLOUD %s — CLOUD 탭에서 결정 (TRIGGER/RETRY/SKIP/HOLD)" % phase, true, 2.5)


func _bootstrap() -> void:
	print("[Cloud2Mount] _bootstrap starting")
	for _i in range(600):
		shell = get_parent().get_node_or_null("Battle")
		if shell != null and shell.get("unit_manager") != null and shell.get("hud_layer") != null:
			break
		await get_tree().process_frame
	print("[Cloud2Mount] shell wait done, shell=%s" % [str(shell != null)])
	if shell == null or shell.get("unit_manager") == null or shell.get("hud_layer") == null:
		mount_error = "Battle dependencies not found."
		push_warning("[Cloud2Mount] %s" % mount_error)
		print("[Cloud2Mount] %s" % mount_error)
		return
	det = shell.get_node_or_null("Step7Integration")
	for _j in range(600):
		if det != null and bool(det.get("ready_for_step7")):
			break
		await get_tree().process_frame
	print("[Cloud2Mount] det wait done, det=%s, ready=%s" % [str(det != null), str(bool(det.get("ready_for_step7"))) if det != null else "false"])
	if det == null or not bool(det.get("ready_for_step7")):
		mount_error = "Step7Integration not ready."
		push_warning("[Cloud2Mount] %s" % mount_error)
		print("[Cloud2Mount] %s" % mount_error)
		return
	bridge = BridgeCls.new()
	if not bridge.bind(shell, det):
		mount_error = "Bridge binding failed."
		push_warning("[Cloud2Mount] %s" % mount_error)
		print("[Cloud2Mount] %s" % mount_error)
		return
	overlay = OverlayCls.new()
	overlay.name = "Cloud1PreviewOverlay"
	overlay.z_index = 22
	shell.add_child(overlay)
	executor = ExecutorCls.new()
	executor.name = "Cloud1LiveExecutor"
	add_child(executor)
	executor.bind(bridge)
	# Cloud RED stack (Node children so HTTP + awaits run in the tree).
	cloud_config = ConfigCls.new()
	if _is_local_brain():
		_configure_local_brain()
	else:
		_configure_cloud_brain()
	cloud_adapter = AdapterCls.new()

	cloud_adapter.name = "Cloud2Adapter"
	add_child(cloud_adapter)
	cloud_plan = PlanCls.new()
	if _is_full_pipeline():
		# Brain contract: unallocated missions (Hand A allocates). Hands: the
		# frozen Hand A + Hand B worker profile (must precede any spawn).
		_contract_prev = OS.get_environment(AuthoringCls.CONTRACT_MODE_ENV)
		OS.set_environment(AuthoringCls.CONTRACT_MODE_ENV, AuthoringCls.CONTRACT_UNALLOC)
		if not LYLaunchCls.use_hands_ab_profile():
			mount_error = "HANDS_AB profile unavailable (a base Laya worker is already live)."
			push_warning("[Cloud2Mount] %s" % mount_error)
			return
		cloud_controller = HandsABCls.new()
		print("[Cloud2Mount] FULL PIPELINE V0: brain=local CSFT5 contract=%s hands=%s" % [
			OS.get_environment(AuthoringCls.CONTRACT_MODE_ENV), LYLaunchCls.model_label()])
	else:
		cloud_controller = LayaControllerCls.new()
	cloud_controller.name = "Cloud2TurnController"
	add_child(cloud_controller)
	dock = DockCls.new()
	# Step-2 Lab: same console + the CLOUD tab. Must be set before setup().
	dock.show_cloud_tab = true
	# Floating tool window (drag/resize/minimize/hide) instead of the fixed
	# right dock. Step-1 never sets this, so its dock is untouched.
	dock.floating_mode = true
	var hud: CanvasLayer = shell.get("hud_layer") as CanvasLayer
	hud.add_child(dock)
	print("[Cloud2Mount] calling dock.setup")
	dock.setup(bridge, executor, overlay)
	var panel: Control = dock.get_cloud_panel()
	if panel == null or not panel.has_method("setup"):
		mount_error = "CLOUD tab panel missing."
		push_warning("[Cloud2Mount] %s" % mount_error)
		print("[Cloud2Mount] %s" % mount_error)
		return
	cloud_controller.setup(bridge, executor, cloud_adapter, cloud_config, cloud_plan)
	if _is_local_brain():
		cloud_controller.strict_latch_reviews = false
	# Optional normal-play fallback is a separate live controller. It never
	# binds the shell's RED slot; Cloud keeps ownership and delegates only a
	# single rejected Brain turn. Strict training/eval always bypasses it.
	var fallback_flag := OS.get_environment("UTILITY_BOT_BRAIN_FALLBACK").strip_edges().to_lower()
	if fallback_flag in ["1", "true", "on", "yes"] and not StrictCls.strict_enabled():
		var utility := UtilityLiveCls.new()
		utility.name = "UtilityBrainFallback"
		utility.auto_mount = false
		add_child(utility)
		var utility_bound: Dictionary = utility.bind_live(shell, det, false)
		if bool(utility_bound.get("ok", false)):
			utility_fallback_controller = utility
			cloud_controller.set_utility_bot_fallback_controller(utility)
			print("[Cloud2Mount] optional UtilityBot Brain fallback READY seed=%s" % str(utility_bound.get("seed", "?")))
		else:
			print("[Cloud2Mount] optional UtilityBot Brain fallback unavailable: %s" % str(utility_bound.get("error", "?")))
			utility.queue_free()
	# New Human-vs-Cloud testing default: persistent General + mission
	# controllers. LEGACY_DIRECT stays available as the benchmark path.
	cloud_controller.set_control_mode("MISSION_HIERARCHY")
	# GENERAL_BACKEND (debug harness): GENERAL_BACKEND env / --general-backend=
	# may select DEBUG_AGENT for live-scene agent runs. Unset or PROVIDER /
	# REAL_PROVIDER keeps production behavior unchanged.
	var _gb := DebugAgentCfgCls.resolve_backend()
	if DebugAgentCfgCls.canonical_backend(_gb) == "EXTERNAL_AGENT" and not _is_full_pipeline():
		var _switched: Dictionary = cloud_controller.set_agent_backend("DEBUG_AGENT")
		print("[Cloud2Mount] GENERAL_BACKEND=%s -> %s" % [_gb, JSON.stringify(_switched)])
	# Worker-General live channel: when the effective backend is an agent
	# backend, the in-scene file poller serves parked General requests.
	# Provider mode is untouched (worker_link stays null).
	if cloud_controller.has_method("get_agent_backend") \
			and str(cloud_controller.get_agent_backend()) in ["DEBUG_AGENT", "EXTERNAL_AGENT"] \
			and cloud_controller.has_method("agent_poll"):
		worker_link = WorkerLinkCls.new()
		worker_link.name = "WorkerGeneralLink"
		add_child(worker_link)
		worker_link.setup(cloud_controller)
	cloud_controller.cloud_state_changed.connect(_on_cloud_state_changed)
	cloud_controller.laya_decision.connect(_on_laya_decision)
	_build_hud()
	# Boot the owned Laya worker asynchronously (never blocks scene entry).
	_boot_task += 1
	_boot_async(_boot_task)
	_hud_task += 1
	_hud_poll_async(_hud_task)
	turn_bar = TurnBarCls.new()
	add_child(turn_bar)
	turn_bar.setup(cloud_controller)
	# AGENT-MCP-PLAYTEST: mount the structured tool bridge beside the battle
	# (pure observability/adapter layer — it stores no battle state).
	agent_bridge = AgentBridgeCls.new()
	agent_bridge.name = "AgentPlaytestBridge"
	add_child(agent_bridge)
	panel.call("setup", cloud_controller, cloud_config, cloud_adapter)
	# Route the RED phase to the Cloud controller (deterministic off).
	shell.set("cloud_red_controller", cloud_controller)
	if shell.has_signal("roster_rebuilt"):
		shell.connect("roster_rebuilt", Callable(dock, "refresh_observation"))
	print("[Cloud2Mount] dock.setup finished")
	SessionCls.trace("CLOUD2_SCENE_READY", null, cloud_config)
	mount_ready = true
	var brain_txt := "WORKER" if worker_link != null else "%s/%s" % [
		str(cloud_config.provider_id), str(cloud_config.model)]
	print("[Cloud2Mount] human-vs-%s mounted" % ("local" if _is_local_brain() else "cloud") + " | live=%s | turn=%d | red=%s | brain=%s hands=%s worker=%s" % [
		str(bridge.scenario_id()), int(bridge.get_manager().get_current_turn()), red_controller_mode(),
		brain_txt, LYLaunchCls.model_label(), str(LYLaunchCls.status_snapshot().get("status", "?"))])
	if _is_local_brain():
		_local_task += 1
		_local_brain_boot_async(_local_task)
	else:
		_prefetch_victory_initial()


## Human-vs-Cloud (unchanged): saved non-secret settings, then session
## authority, then the title-screen runtime pull as the legacy fallback.
func _configure_cloud_brain() -> void:
	cloud_config.load_local_settings() # non-secret fields only; key stays empty
	# Session authority first (test-pass/apply armed it, with key + cache);
	# title-screen runtime pull stays as the legacy fallback.
	if SessionCls.is_armed():
		SessionCls.hydrate(cloud_config)
		print("[Cloud2Mount] session hydrated: fp=%s" % cloud_config.fingerprint())
		SessionCls.trace("CLOUD2_MOUNT_HYDRATE", null, cloud_config)
	else:
		SessionCls.trace("CLOUD2_MOUNT_NOSESSION", null, cloud_config)
		var pulled := cloud_config.apply_ai_backend_runtime() # title-screen AI Settings (OpenCode Go) wins when present
		if bool(pulled.get("applied", false)):
			print("[Cloud2Mount] AI Settings runtime applied: protocol=%s tested=%s" % [
				str(pulled.get("protocol", "?")), str(bool(pulled.get("tested", false)))])
		SessionCls.trace("CLOUD2_MOUNT_FALLBACK", null, cloud_config)


## Human-vs-Local: the local CSFT5 Brain is the default and only provider.
## No saved settings, session, key or AI-runtime pull is consulted.
func _configure_local_brain() -> void:
	cloud_config.set_provider("local_qwen8b")
	cloud_config.set_endpoint(LocalBrainCls.ENDPOINT)
	cloud_config.set_model(LocalBrainCls.MODEL_ID)
	cloud_config.timeout_sec = 300.0
	_strict_prev = OS.get_environment(STRICT_ENV)
	OS.set_environment(STRICT_ENV, "1")
	print("[Cloud2Mount] LOCAL BRAIN mode: provider=local_qwen8b model=%s endpoint=%s strict=ON (no repair/retry/fallback)" % [
		LocalBrainCls.MODEL_ID, LocalBrainCls.ENDPOINT])


## Boot (or reuse) the owned CSFT5 server, then run the REAL production
## connection test through the adapter, then prefetch the INITIAL plan.
func _local_brain_boot_async(my: int) -> void:
	var started: Dictionary = LocalBrainCls.start()
	if not bool(started.get("ok", false)):
		push_warning("[Cloud2Mount] local brain unavailable: %s" % str(started.get("error", "")))
		return
	var deadline := Time.get_ticks_msec() + LocalBrainCls.STARTUP_TIMEOUT_MS
	while LocalBrainCls.poll_ready() == "BOOTING" and Time.get_ticks_msec() < deadline:
		if my != _local_task:
			return
		await get_tree().create_timer(1.0).timeout
	if my != _local_task:
		return
	if str(LocalBrainCls.status_snapshot().get("status", "")) != "READY":
		push_warning("[Cloud2Mount] local brain not ready: %s" % JSON.stringify(LocalBrainCls.status_snapshot()))
		return
	var result := {}
	var on_test := func(r: Dictionary) -> void: result.merge(r, true)
	cloud_adapter.test_finished.connect(on_test)
	cloud_adapter.test_connection(cloud_config)
	var t_deadline := Time.get_ticks_msec() + 30000
	while result.is_empty() and Time.get_ticks_msec() < t_deadline:
		if my != _local_task:
			return
		await get_tree().process_frame
	cloud_adapter.test_finished.disconnect(on_test)
	var ok := bool(result.get("ok", false))
	cloud_config.mark_test_result(ok, ConfigCls.STATUS_CONNECTED if ok else ConfigCls.STATUS_ERROR,
		"Local CSFT5 Brain auto-test" if ok else "Local CSFT5 Brain test failed: %s" % str(result.get("code", "")))
	print("[Cloud2Mount] local brain connection test ok=%s" % str(ok))
	if ok:
		_prefetch_victory_initial()


## Repair V1 prefetch: start INITIAL VictoryPlan generation from the frozen
## deployment snapshot while HUMAN BLUE plays turn one. Fire-and-forget.
func _prefetch_victory_initial() -> void:
	if cloud_controller == null or bridge == null:
		return
	if not cloud_controller.has_method("victory_prefetch_initial"):
		return
	var obs := ObsCls.build(bridge, "red")
	var res: Dictionary = cloud_controller.victory_prefetch_initial(obs)
	print("[Cloud2Mount] victory prefetch started=%s reason=%s armed=%s snap=%s (frozen pre-BLUE opening)" % [
		str(bool(res.get("started", false))), str(res.get("reason", "")),
		str(bool(res.get("armed", false))), str(obs.get("snapshot_id", "?")).left(48)])


## Owned Laya worker boot + RED HANDS HUD (same lifecycle contract as the
## Laya mount: async boot, visible status, clean shutdown, no manual step).
func _boot_async(my: int) -> void:
	if not LYLaunchCls.auto_enabled():
		LYLaunchCls.mark_disabled("EXPLICIT_OFF")
		return
	if str(LYLaunchCls.status_snapshot().get("status", "COLD")) != "COLD":
		return
	if LYLaunchCls.fixed_url_mode():
		await _boot_fixed_async(my)
		return
	var spawned: Dictionary = LYLaunchCls.spawn_owned_or_fixed()
	if not bool(spawned.get("ok", false)):
		return
	if str(spawned.get("status", "")) == "READY":
		return
	var deadline := Time.get_ticks_msec() + LYLaunchCls.startup_timeout_ms()
	while Time.get_ticks_msec() < deadline:
		if my != _boot_task:
			return
		if LYLaunchCls.is_ready() or LYLaunchCls.is_disabled():
			return
		if not LYLaunchCls.boot_in_progress():
			return
		if not LYLaunchCls.owned_pid_alive():
			LYLaunchCls.mark_disabled("WORKER_DIED_DURING_BOOT")
			return
		var snap: Dictionary = LYLaunchCls.status_snapshot()
		var res: Dictionary = await _http_get_json(
			str(snap.get("host", "127.0.0.1")), int(snap.get("port", 11442)),
			"/health", 4.0)
		if my != _boot_task:
			return
		if LYLaunchCls.is_ready() or LYLaunchCls.is_disabled():
			return
		if bool(res.get("ok", false)) and res.get("body", {}) is Dictionary:
			var v: Dictionary = LYLaunchCls.verify_health_dict(res.get("body", {}))
			if bool(v.get("ok", false)):
				LYLaunchCls.mark_ready(v.get("identity", {}), (res.get("body", {}) as Dictionary).get("load", {}))
				_announce_ready()
				return
			LYLaunchCls.mark_disabled(str(v.get("error", "HEALTH_MISMATCH")))
			return
		await get_tree().create_timer(BOOT_POLL_SEC).timeout
	LYLaunchCls.on_boot_timeout()


func _boot_fixed_async(my: int) -> void:
	var deadline := Time.get_ticks_msec() + LYLaunchCls.FIXED_PROBE_TIMEOUT_MS * 3
	while Time.get_ticks_msec() < deadline:
		if my != _boot_task:
			return
		if LYLaunchCls.is_ready() or LYLaunchCls.is_disabled():
			return
		var ep: Dictionary = LYLaunchCls.fixed_endpoint()
		var res: Dictionary = await _http_get_json(
			str(ep.get("host", "127.0.0.1")), int(ep.get("port", 11442)),
			"/health", 4.0)
		if my != _boot_task:
			return
		if LYLaunchCls.is_ready() or LYLaunchCls.is_disabled():
			return
		if bool(res.get("ok", false)) and res.get("body", {}) is Dictionary:
			var v: Dictionary = LYLaunchCls.verify_health_dict(res.get("body", {}))
			if bool(v.get("ok", false)):
				LYLaunchCls.adopt_fixed_health(v.get("identity", {}),
					(res.get("body", {}) as Dictionary).get("load", {}),
					str(ep.get("host", "")), int(ep.get("port", 11442)))
				_announce_ready()
				return
			LYLaunchCls.mark_disabled("FIXED_IDENTITY_MISMATCH: %s" % str(v.get("error", "?")))
			return
		await get_tree().create_timer(BOOT_POLL_SEC).timeout
	LYLaunchCls.mark_disabled("FIXED_UNREACHABLE")


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
	var snap: Dictionary = LYLaunchCls.status_snapshot()
	var load_info: Dictionary = snap.get("load_info", {})
	print("[Cloud2Mount] worker READY load_s=%s vram=%s" % [
		str(load_info.get("load_s", "?")), str(load_info.get("vram_gb", "?"))])
	if shell != null and shell.has_method("_show_combat_log"):
		shell.call("_show_combat_log", "%s READY — model %s (load %ss, VRAM %sGB)" % [
			"HAND A+B" if _is_full_pipeline() else "LAYA", LYLaunchCls.model_label(), str(load_info.get("load_s", "?")),
			str(load_info.get("vram_gb", "?"))])


func _on_laya_decision(info: Dictionary) -> void:
	# HUD refreshes on its poll; decisions also hit print for log capture.
	var ev := str(info.get("event", "?"))
	if ev == "DECISION":
		print("[Cloud2Mount] t%d #%d %s unit=%s pool=%d lat=%.0fms exec=%s" % [
			int(info.get("turn", 0)), int(info.get("step", 0)),
			str(info.get("selected", "?")), str(info.get("unit_id", "?")),
			int(info.get("candidate_count", 0)),
			float(info.get("latency_ms", 0.0)), str(bool(info.get("executed", false)))])
		var lbl := shell.get("turn_label") as Label if shell != null else null
		if lbl != null and shell != null and int(shell.get("_turn_phase")) == 1:
			lbl.text = "제 %d 턴 (적군) — LAYA %s #%d: %s [pool=%d, %.0fms]" % [
				int(info.get("turn", 0)), str(info.get("unit_id", "?")),
				int(info.get("step", 0)), str(info.get("selected", "?")),
				int(info.get("candidate_count", 0)), float(info.get("latency_ms", 0.0))]
	else:
		print("[Cloud2Mount] %s %s" % [ev, JSON.stringify(info)])


func _build_hud() -> void:
	var hud: CanvasLayer = shell.get("hud_layer") as CanvasLayer
	if hud == null:
		return
	_hud = PanelContainer.new()
	_hud.name = "LayaHUD"
	_hud.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_hud.offset_left = -400
	_hud.offset_top = 8
	_hud.offset_right = -8
	_hud.offset_bottom = 268
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.05, 0.12, 0.88)
	sb.border_width_left = 2
	sb.border_width_top = 2
	sb.border_width_right = 2
	sb.border_width_bottom = 2
	sb.border_color = Color(0.65, 0.55, 1.0, 0.9)
	sb.corner_radius_top_left = 4
	sb.corner_radius_top_right = 4
	sb.corner_radius_bottom_right = 4
	sb.corner_radius_bottom_left = 4
	_hud.add_theme_stylebox_override("panel", sb)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 2)
	_hud.add_child(vb)
	_hud_lines = []
	for i in range(11):
		var lbl := Label.new()
		lbl.add_theme_font_size_override("font_size", 13)
		lbl.add_theme_color_override("font_color", Color(0.85, 0.82, 1.0))
		lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		vb.add_child(lbl)
		_hud_lines.append(lbl)
	hud.add_child(_hud)
	_refresh_hud()


func _hud_poll_async(my: int) -> void:
	while my == _hud_task and is_instance_valid(_hud):
		_refresh_hud()
		await get_tree().create_timer(HUD_POLL_SEC).timeout


## General status line: worker channel state in worker mode, plan in
## provider mode. Never implies a fallback Brain is active.
func _general_status_line(plan: Dictionary) -> String:
	var plan_txt := "plan v%d src=%s" % [
		int(plan.get("plan_version", 0)), str(plan.get("source", "?"))]
	if worker_link == null:
		return plan_txt
	var ws: Dictionary = worker_link.get_status()
	if not bool(ws.get("channel_ok", false)):
		return "WORKER GENERAL OFFLINE (%s)" % str(ws.get("channel_error", "?"))
	match str(ws.get("state", "")):
		"THINKING":
			return "General: THINKING worker %s t%d (%ds) | %s" % [
				str(ws.get("request_id", "?")), int(ws.get("turn", 0)),
				int(ws.get("wait_s", 0)), plan_txt]
		"TIMED_OUT":
			var to: Dictionary = ws.get("last_timeout", {})
			return "General: TIMED_OUT %s (phase holds, no fallback Brain) | %s" % [
				str(to.get("request_id", "?")), plan_txt]
		_:
			return "General: WAITING worker | %s" % plan_txt


func _refresh_hud() -> void:
	if _hud == null or not is_instance_valid(_hud) or _hud_lines.is_empty():
		return
	var svc: Dictionary = LYLaunchCls.status_snapshot()
	var st := str(svc.get("status", "?"))
	var ctl: Dictionary = cloud_controller.laya_stats() if cloud_controller != null else {}
	var last: Dictionary = ctl.get("last", {})
	var hands_txt := "HAND A + HAND B" if _is_full_pipeline() else "LAYA"
	var head := "RED HANDS: %s" % hands_txt
	var head_col := Color(0.75, 0.70, 1.0)
	if st != "READY":
		head = "RED HANDS: %s %s" % [hands_txt, st]
		head_col = Color(1.0, 0.75, 0.35)
	if bool(ctl.get("fallback_active", false)):
		head = "%s ERROR -> EXPLICIT HOLD (%s)" % [hands_txt, str(ctl.get("fallback_reason", "?"))] if _is_full_pipeline() else "LAYA ERROR -> FALLBACK ACTIVE"
		head_col = Color(1.0, 0.40, 0.35)
	(_hud_lines[0] as Label).text = head
	(_hud_lines[0] as Label).add_theme_color_override("font_color", head_col)
	if worker_link != null:
		(_hud_lines[1] as Label).text = "RED BRAIN: WORKER GENERAL"
		(_hud_lines[1] as Label).add_theme_color_override("font_color", Color(0.60, 1.0, 0.65))
	elif _is_local_brain():
		var lb: Dictionary = LocalBrainCls.status_snapshot()
		var lst := str(lb.get("status", "?"))
		var conn := str(cloud_config.connection_status) if cloud_config != null else "?"
		(_hud_lines[1] as Label).text = "RED BRAIN: LOCAL Qwen3-8B CSFT5%s | %s | %s | strict" % [
			" unalloc_v1" if _is_full_pipeline() else "", lst, conn if lst == "READY" else "wait before ending BLUE turn"]
		(_hud_lines[1] as Label).add_theme_color_override("font_color",
			Color(0.60, 1.0, 0.65) if lst == "READY" and conn == ConfigCls.STATUS_CONNECTED else Color(1.0, 0.75, 0.35))
	else:
		(_hud_lines[1] as Label).text = "RED BRAIN: %s/%s" % [
			str(cloud_config.provider_id) if cloud_config != null else "?",
			str(cloud_config.model) if cloud_config != null else "?"]
	(_hud_lines[2] as Label).text = "model: %s | %s" % [LYLaunchCls.model_label(), st]
	if _is_full_pipeline():
		var hab: Dictionary = ctl.get("hand_ab", {})
		var cov: Dictionary = hab.get("hand_a_coverage", {})
		(_hud_lines[2] as Label).text = "HAND A: calls %d | coverage %d/%d | PIPELINE FAILURES: %d" % [
			int(hab.get("hand_a_calls", 0)), int(cov.get("assigned", 0)), int(cov.get("ready", 0)),
			int(hab.get("pipeline_failure_count", 0))]
	var load_info: Dictionary = svc.get("load_info", {})
	(_hud_lines[3] as Label).text = "load: %ss | VRAM: %sGB | pid: %s" % [
		str(load_info.get("load_s", "?")), str(load_info.get("vram_gb", "?")),
		str(svc.get("pid", "?"))]
	(_hud_lines[4] as Label).text = "turns: %d | decisions: %d | forced: %d | fallback: %d | stale: %d" % [
		int(ctl.get("red_turns", 0)), int(ctl.get("decision_count", 0)),
		int(ctl.get("forced_count", 0)), int(ctl.get("fallback_count", 0)),
		int(ctl.get("stale_count", 0))]
	(_hud_lines[5] as Label).text = "moves: %d | attacks: %d | waits: %d | fails: %d" % [
		int(ctl.get("moves", 0)), int(ctl.get("attacks", 0)),
		int(ctl.get("waits", 0)), int(ctl.get("exec_failures", 0))]
	var last_txt := "last: —"
	if not last.is_empty():
		if str(last.get("event", "")) == "DECISION":
			last_txt = "last: %s unit=%s [pool=%d, %.0fms]" % [str(last.get("selected", "?")),
				str(last.get("unit_id", "?")), int(last.get("candidate_count", 0)),
				float(last.get("latency_ms", 0.0))]
		else:
			last_txt = "last: %s" % str(last.get("event", "?"))
	(_hud_lines[6] as Label).text = last_txt
	var plan: Dictionary = cloud_controller.get_general_view().get("plan", {}) if cloud_controller != null else {}
	(_hud_lines[7] as Label).text = _general_status_line(plan)
	_refresh_victory_hud()


## VICTORY PLAN V0 (additive): persistent-plan HUD lines (read-only).
func _refresh_victory_hud() -> void:
	if _hud_lines.size() < 11:
		return
	if cloud_controller == null or not cloud_controller.has_method("get_victory_plan_view"):
		(_hud_lines[8] as Label).text = "VICTORY PLAN: (n/a)"
		(_hud_lines[9] as Label).text = ""
		(_hud_lines[10] as Label).text = ""
		return
	var view: Dictionary = cloud_controller.get_victory_plan_view()
	if not bool(view.get("has_plan", false)):
		var init: Dictionary = view.get("initial", {})
		var state := str(init.get("state", "NOT_STARTED"))
		if state == "FAILED":
			(_hud_lines[8] as Label).text = "VICTORY PLAN: ERROR (no valid plan)"
			(_hud_lines[9] as Label).text = "PLAN ERROR: %s" % str(init.get("error", "?")).left(60)
			(_hud_lines[10] as Label).text = "Use RETRY PLAN (Cloud panel)"
		elif state == "REQUESTING" or state == "RETRYING":
			(_hud_lines[8] as Label).text = "VICTORY PLAN: generating..."
			(_hud_lines[9] as Label).text = ""
			(_hud_lines[10] as Label).text = ""
		elif state == "READY":
			(_hud_lines[8] as Label).text = "VICTORY PLAN: ready v1 (awaiting RED)"
			(_hud_lines[9] as Label).text = ""
			var last0: Dictionary = view.get("last_call", {})
			(_hud_lines[10] as Label).text = "LAST GENERAL: t%d %s -> %s" % [int(last0.get("turn", 0)),
				str(last0.get("trigger", "?")), str(last0.get("decision", "?"))] if not last0.is_empty() else ""
		else:
			(_hud_lines[8] as Label).text = "VICTORY PLAN: (none yet)"
			(_hud_lines[9] as Label).text = ""
			(_hud_lines[10] as Label).text = ""
		return
	var vp: Dictionary = view.get("plan", {})
	var phases: Array = vp.get("phases", [])
	var cur := ""
	var cur_name := ""
	for p_val in phases:
		if p_val is Dictionary and str((p_val as Dictionary).get("phase_id", "")) == str(vp.get("current_phase_id", "")):
			cur = str((p_val as Dictionary).get("status", "?"))
			cur_name = str((p_val as Dictionary).get("name", ""))
	(_hud_lines[8] as Label).text = "VICTORY PLAN: %s v%d" % [str(vp.get("victory_plan_id", "?")), int(vp.get("revision", 0))]
	var idx := 0
	for i in range(phases.size()):
		if (phases[i] as Dictionary).get("phase_id", "") == str(vp.get("current_phase_id", "")):
			idx = i + 1
	(_hud_lines[9] as Label).text = "PHASE: %s (%d/%d) %s [%s]" % [str(vp.get("current_phase_id", "?")),
		idx, phases.size(), cur_name.left(18), cur]
	var last: Dictionary = view.get("last_call", {})
	if last.is_empty():
		(_hud_lines[10] as Label).text = "LAST GENERAL: (none)"
	else:
		(_hud_lines[10] as Label).text = "LAST GENERAL: t%d %s -> %s" % [int(last.get("turn", 0)),
			str(last.get("trigger", "?")), str(last.get("decision", "?"))]
