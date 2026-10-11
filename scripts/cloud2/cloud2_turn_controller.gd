class_name Cloud2TurnController
extends Node

## CLOUD-GENERAL STEP 2 ??RED Cloud turn controller (the only RED authority
## in Human-vs-Cloud mode).
##
## Owns the RED phase end to end:
##   freeze RED observation -> build packet -> model call -> schema +
##   semantic validation -> sequential per-order compile+execute through the
##   shared Cloud1Compiler/Cloud1LiveExecutor (side "red") -> summary ->
##   plan-memory update -> research log.
##
## Turn integrity:
## - One order executes at a time; every order is re-planned against CURRENT
##   state (the executor plans at execute() time), so earlier orders can
##   change later orders' legality honestly.
## - An invalid order is rejected with a deterministic code and the turn
##   continues with the next order (reject-and-continue policy).
## - Model/timeout/provider failures suspend the phase for a human decision
##   (RETRY / SKIP / HOLD ALL); battle state is never fabricated.
## - While a phase runs, the executor soft-lock blocks human BLUE orders
##   from interleaving RED execution, and the shell refuses roster resets.
##
## Modes: AUTO (act when the RED phase begins), STEP (wait for an explicit
## human trigger per RED turn). PAUSE suspends at safe boundaries (before
## observation freeze, before the model call, before each order).
##
## MISSION HIERARCHY (Cloud control modes): LEGACY_DIRECT keeps the original
## per-turn tactical inference above (benchmark/rollback path). MISSION_HIERARCHY
## routes RED turns through a persistent Cloud General plan executed by
## deterministic MissionControllers: most RED turns run with zero network
## requests, and the Cloud model is consulted only for the initial plan and
## event/periodic reviews (blocking when no valid plan exists, background
## otherwise). Compiler/executor/response-gate reuse is total: hierarchy
## orders execute through the same _execute_orders path below.

signal cloud_state_changed(state: Dictionary)
signal phase_finished(result: Dictionary)

const ObsCls = preload("res://scripts/cloud1/cloud1_observation.gd")
const TableCls = preload("res://scripts/cloud1/cloud1_action_table.gd")
const PacketCls = preload("res://scripts/cloud2/cloud2_turn_packet.gd")
const ResponseCls = preload("res://scripts/cloud2/cloud2_response.gd")
const LoggerCls = preload("res://scripts/cloud2/cloud2_logger.gd")
const AdapterCls = preload("res://scripts/cloud2/cloud2_adapter.gd")
const ConfigCls = preload("res://scripts/cloud2/cloud2_config.gd")
const PlanCls = preload("res://scripts/cloud2/cloud2_plan_memory.gd")
const SessionCls = preload("res://scripts/cloud2/cloud2_session.gd")
## Issue 1 observability: passive telemetry store. Records what this
## controller already decided/did; never consulted for any decision.
const TraceCls = preload("res://scripts/cloud2/cloud2_turn_trace.gd")
## Mission hierarchy stack (additive; legacy path never touches these).
const GeneralPacketCls = preload("res://scripts/cloud2/cloud2_general_packet.gd")
const ReviewContextCls = preload("res://scripts/cloud2/cloud2_brain_context.gd")
const GeneralPlanCls = preload("res://scripts/cloud2/cloud2_general_plan.gd")
const CoordMenuCls = preload("res://scripts/cloud2/cloud2_coord_menu.gd")
const CoordResponseCls = preload("res://scripts/cloud2/cloud2_coord_response.gd")
const MissionManagerCls = preload("res://scripts/cloud2/cloud2_mission_manager.gd")
const GeneralTraceCls = preload("res://scripts/cloud2/cloud2_general_trace.gd")
## VICTORY PLAN V0 (additive): persistent multi-phase planning path.
## TRAINING_CONTRACT_REVIEW_WAKE_V1 (additive): explicit TRAINING/EVAL
## STRICT scope + Brain-contract terminal mapping. Consulted only on the
## strict-gated paths below; STRICT OFF leaves every behavior unchanged.
const StrictCls = preload("res://scripts/selfplay/training_strict.gd")
const VictoryPlanCls = preload("res://scripts/cloud2/cloud2_victory_plan.gd")
const VictoryResponseCls = preload("res://scripts/cloud2/cloud2_victory_response.gd")
const BattleMemoryCls = preload("res://scripts/cloud2/cloud2_battle_memory.gd")

const MODE_AUTO := "AUTO"
const MODE_STEP := "STEP"

## Cloud control modes (compatibility switch; temporary benchmark path).
const CONTROL_LEGACY := "LEGACY_DIRECT"
const CONTROL_HIERARCHY := "MISSION_HIERARCHY"
## General review output budget: a plan/doctrine/missions JSON is smaller
## than per-turn tactical output, but reasoning-capable models still spend
## tokens before final content ??same headroom policy as tactical turns.
const GENERAL_MAX_TOKENS := 4096
## Strategic planning calls carry a full plan/doctrine/missions JSON plus the
## model's own deliberation: they budget 4x the tactical HTTP timeout instead
## of timing out a slow-but-working General mid-plan.
const GENERAL_TIMEOUT_SEC := 240.0
## SELFPLAY V1: local reasoning Brains (Qwen 9B-class, ~10 min/plan) exceed
## the 240 s cloud budget. SELFPLAY_GENERAL_TIMEOUT_SEC overrides the
## General/Victory timeout on Brain paths only; unset = 240 s production
## default (Human-vs-Cloud unchanged). Clamped to [60, 3600].
static func brain_timeout_sec() -> float:
	var raw := OS.get_environment("SELFPLAY_GENERAL_TIMEOUT_SEC").strip_edges()
	if not raw.is_empty():
		return clampf(float(raw), 60.0, 3600.0)
	return GENERAL_TIMEOUT_SEC
const GENERAL_REQUEST_PREFIX := "general_"
## VictoryPlan GENERATION ceilings (V3 deep debug, quality-first). Proven
## semantics on opencode/deepseek-v4.1-flash: max_tokens caps
## reasoning+final TOGETHER (PA: completion 3072 = reasoning 3072, 0 final;
## PB: 5084 = 3402 thinking + ~1682 final @16384, finish=stop; PR review:
## 789 total). The ceiling must fit NATURAL thinking (~3.4k observed) PLUS
## the bounded final (~1.7k): 16384 covers ~3x thinking variance with
## headroom, is provider-accepted, and costs nothing extra when the model
## stops early (PB 5084/16384, PR 789/16384). Reasoning is NOT
## constrained. Uniform across INITIAL/REVIEW/RETRY: a no-final retry with
## a SMALLER budget is a guaranteed repeat failure (V1's 2048 trap).
const VICTORY_INITIAL_MAX_TOKENS := 16384
const VICTORY_REVIEW_MAX_TOKENS := 16384
const VICTORY_REPAIR_MAX_TOKENS := 16384
## One initial plan generation sequence per battle. REQUESTING/RETRYING
## attach (never duplicate); READY consumes; FAILED latches visibly until
## an explicit manual retry. No infinite INITIAL_PLAN loop.
const VP_INIT_NOT_STARTED := "NOT_STARTED"
const VP_INIT_REQUESTING := "REQUESTING"
const VP_INIT_RETRYING := "RETRYING"
const VP_INIT_READY := "READY"
const VP_INIT_FAILED := "FAILED"
## Bounded General interaction history for the DEV Model View (one entry
## per request attempt; request/response halves frozen at capture).
const GENERAL_HISTORY_MAX := 12
## Blocking General reviews retry ONCE on schema rejection (same frozen
## packet + compact error feedback). Transport failures never auto-retry ??## the human decides, exactly like the legacy path.
const GENERAL_MAX_SCHEMA_RETRY := 1

## Automatic retry budget: EXACTLY ONE silent retry per RED phase, and
## ONLY for output-budget exhaustion (the model spent its tokens before
## producing final text). The retry reuses the SAME frozen observation
## snapshot ??no re-freeze, no partial execution ??and fails over to the
## normal human RETRY/SKIP/HOLD decision if state moved meanwhile.
const MAX_AUTO_RETRY := 1
const AUTO_RETRY_CODES := ["REASONING_BUDGET_EXHAUSTED", "FINISH_LENGTH_NO_FINAL"]


## Pure retry policy (tested): retryable transport/output failure that we
## have not already auto-retried. Semantic failures, refusals, auth, and
## stale snapshots NEVER auto-retry.
static func should_auto_retry(model_res: Dictionary, auto_retried: int) -> bool:
	if bool(model_res.get("ok", false)):
		return false
	if auto_retried >= MAX_AUTO_RETRY:
		return false
	return str(model_res.get("code", "")) in AUTO_RETRY_CODES


## TRAINING_CONTRACT_REVIEW_WAKE_V1: shared per-window review dedup.
## One serviced review per battle#turn window, whatever the trigger
## (event batch, horizon, mission, HQ, VictoryPlan transition). Both the
## pre-RED safe-window service and the post-turn refire guard consult
## this, so one trigger yields one intended review and a persistent
## trigger cannot storm within a turn. Empty history never suppresses.
static func review_window_already_serviced(last_serviced_window: String, review_window: String) -> bool:
	if last_serviced_window.strip_edges().is_empty():
		return false
	return last_serviced_window == review_window

var _bridge: RefCounted = null
var _executor: Node = null
var _adapter: AdapterCls = null
var _config: ConfigCls = null
var _plan: PlanCls = null
## SYMMETRIC V1: owning side of this controller ("red" default = legacy).
## Human-vs-Cloud never sets it; the symmetric sandbox binds one controller
## per side with the SAME class and interface.
var _side := "red"

## Fresh battles default to AUTO: BLUE End Turn dispatches the RED Cloud
## request with no extra click. STEP is debug-only; PAUSE is orthogonal
## (see set_paused). Nothing persists the mode: every mount starts here.
var _mode := MODE_AUTO
var _paused := false
var _phase_active := false
var _step_armed := false
var _decision := ""
var _turn_seq := 0

var _state := {"phase": "IDLE", "note": "Controller idle.", "mode": MODE_AUTO, "paused": false, "phase_active": false, "turn": 0, "failure_class": ""}
var _last_view := {}
var _prev_summary := {}
## Retained effective model input of the last RED turn (safe copies: the
## packet carries no secrets by construction). Read by the Context inspector.
var _last_packet := {}
var _last_obs := {}

var _model_result := {}
var _exec_result := {}
var _exec_seen := 0

## Mission hierarchy state (used only in MISSION_HIERARCHY control mode).
var _control_mode := CONTROL_LEGACY
var _manager: MissionManagerCls = null
var _staged_plan := {}
var _staged_coord := {}
var _review_base := {}
var _general_result := {}
var _review_in_flight := ""
var _general_history: Array = []
var _general_flight := {}
var _hier_last := {}
var _force_review := false
var _last_general_packet := {}
var _staged_review := {}
var _staged_review_decision := ""
var _last_event_review_window := ""
## TRAINING_CONTRACT_REVIEW_WAKE_V1: latched strict Brain-contract fault
## ({side, kind, code, detail, turn, call}; {} when none). Set only when
## TRAINING_STRICT_CONTRACT is on and a Brain response was rejected by
## production validation. First fault wins; cleared only by an explicit
## manual INITIAL re-arm. The match layer polls strict_fault() to
## finalize the authoritative terminal LOSS for the offending side.
var _strict_fault := {}
## Human play has no match layer to finalize a strict LOSS, so a latched
## REVIEW fault would freeze the side forever. Mounts for human play set
## this false: the bad review is still rejected (plan retained), not latched.
var strict_latch_reviews := true
## Optional normal-play fallback. A production parser/validator rejection
## leases exactly one side phase to a separately mounted UtilityBot controller.
## No controller is installed and the env flag is OFF by default.
var _utility_fallback_controller: Node = null
var _utility_fallback_pending: Dictionary = {}
## VICTORY PLAN V0 (additive): canonical Human-vs-Cloud path. Disable via
## set_victory_mode(false) or VICTORY_PLAN_MODE=off (falls back to the
## coordinator path; research modes are untouched).
var _victory_mode := true
var _staged_vp := {}
var _staged_vp_meta := {}
var _staged_vp_decision := ""
var _staged_vp_call := ""
## Initial-plan latch (live API repair V1): exactly one generation
## sequence per battle, started at boot prefetch when possible.
var _vp_init_state := VP_INIT_NOT_STARTED
var _vp_init_req := ""
var _vp_init_call := ""
var _vp_init_turn := 0
var _vp_init_snapshot := ""
var _vp_init_battle := ""
var _vp_init_packet := {}
## STRATEGIC REPLAN: force snapshot at the last plan (opening or replan), for the since_last_plan summary.
var _strategic_prev := {}
var _vp_init_plan := {}
var _vp_init_contract := ""
var _vp_init_error := ""
var _vp_init_retries := 0
var _vp_init_t0_msec := 0
var _vp_init_latency_ms := 0
var _vp_init_snap := {}
var _vp_init_trigger := {}
var _vp_init_prefetched := false
var _vp_init_done := {}
## V3: failure class of the last INITIAL attempt ("", NO_FINAL_GENERATION_
## LIMIT, FINAL_JSON_SYNTAX_INVALID, SCHEMA_INVALID, TRANSPORT_ERROR).
var _vp_init_failure_class := ""
## V3: boot prefetch armed while the backend is not READY yet. The obs is
## the FROZEN opening deployment (pre-BLUE); victory_backend_ready() fires
## it exactly once when the backend becomes tested+CONNECTED.
var _vp_init_armed := false
var _vp_init_armed_obs := {}
var _vp_init_armed_turn := 0


func setup(bridge: RefCounted, executor: Node, adapter: AdapterCls, config: ConfigCls, plan: PlanCls) -> void:
	_bridge = bridge
	_executor = executor
	_adapter = adapter
	_config = config
	_plan = plan
	_adapter.turn_finished.connect(_on_model_done)
	_manager = MissionManagerCls.new()
	_manager.set_side(_side)
	_executor.execution_finished.connect(_on_exec_finished)
	var live_mgr: RefCounted = _bridge.get_manager() if _bridge != null and _bridge.has_method("get_manager") else null
	var combat_cb := Callable(self, "_on_authoritative_combat_resolved")
	if live_mgr != null and live_mgr.has_signal("combat_resolved") and not live_mgr.is_connected("combat_resolved", combat_cb):
		live_mgr.connect("combat_resolved", combat_cb)
	if OS.has_environment("VICTORY_PLAN_MODE") and OS.get_environment("VICTORY_PLAN_MODE").strip_edges().to_lower() == "off":
		_victory_mode = false
		print("[CloudTurn] VICTORY_PLAN_MODE=off: coordinator path active.")
	_set_state("IDLE", "Controller ready (AUTO). END TURN as BLUE and the Cloud plays RED.")


## Combat is never paused for Cloud. The authoritative result is copied into
## the RED factual event buffer synchronously; review waits for the safe
## BLUE->RED phase boundary.
func _on_authoritative_combat_resolved(result: Dictionary) -> void:
	if _manager == null or _bridge == null:
		return
	var obs := ObsCls.build(_bridge, _side)
	if not bool(obs.get("ok", false)):
		return
	var captured := _manager.record_authoritative_combat_event(result, obs)
	if not bool(captured.get("recorded", false)):
		return
	var wake := _manager.wakeup_view()
	_sync_wakeup_state()
	print("[CloudTurn] WAKE_EVENT_BUFFERED kinds=%s pending=%d turn=%d" % [
		JSON.stringify((captured.get("events", []) as Array).map(
			func(e: Variant) -> String: return str((e as Dictionary).get("kind", "")))),
		int(wake.get("pending_event_count", 0)), int(obs.get("turn", 0))])


func _sync_wakeup_state() -> void:
	if _manager == null:
		return
	var wake := _manager.wakeup_view()
	_state["review_pending"] = bool(wake.get("review_pending", false))
	_state["pending_event_count"] = int(wake.get("pending_event_count", 0))
	cloud_state_changed.emit(_state.duplicate(true))


func red_controller_mode() -> String:
	return "CLOUD"


## SYMMETRIC V1: side binding. Propagates to the mission manager.
## BLUE forces victory mode: the coordinator fallback path is RED-only
## legacy, so a BLUE controller must never run it silently.
func set_side(s: String) -> void:
	var want := s.strip_edges().to_lower()
	_side = "blue" if want == "blue" else "red"
	if _manager != null:
		_manager.set_side(_side)
	if _side == "blue" and not _victory_mode:
		_victory_mode = true
		print("[CloudTurn] SYMMETRIC side=blue forces VICTORY_PLAN_MODE=on (coord path is RED-only).")


func get_side() -> String:
	return _side


func _SIDE() -> String:
	return _side.to_upper()


func _FOE() -> String:
	return "BLUE" if _side == "red" else "RED"


func is_phase_active() -> bool:
	return _phase_active


func get_mode() -> String:
	return _mode


func set_mode(m: String) -> void:
	var want := m.strip_edges().to_upper()
	if want != MODE_AUTO and want != MODE_STEP:
		return
	_mode = want
	_state["mode"] = _mode
	cloud_state_changed.emit(_state.duplicate(true))


func set_paused(v: bool) -> void:
	_paused = v
	_state["paused"] = _paused
	cloud_state_changed.emit(_state.duplicate(true))


func is_paused() -> bool:
	return _paused


## Cloud control mode: LEGACY_DIRECT (per-turn tactical inference) or
## MISSION_HIERARCHY (persistent General plan + mission controllers).
func get_control_mode() -> String:
	return _control_mode


## VICTORY PLAN V0: canonical Human-vs-Cloud planning path switch.
func set_victory_mode(v: bool) -> void:
	_victory_mode = v


func get_victory_mode() -> bool:
	return _victory_mode


func set_control_mode(m: String) -> void:
	var want := m.strip_edges().to_upper()
	if want != CONTROL_LEGACY and want != CONTROL_HIERARCHY:
		return
	_control_mode = want
	_state["control_mode"] = _control_mode
	cloud_state_changed.emit(_state.duplicate(true))


## Panel/test hook: force a General review on the next hierarchy RED turn.
func request_general_review() -> void:
	_force_review = true


# --- GENERAL_BACKEND boundary (additive) -------------------------------------
## PROVIDER (canonical HTTP transport ??production semantics, untouched),
## EXTERNAL_AGENT (DEV/testing: the external coding agent is the strategic
## brain; General requests PARK and are completed by structured submit
## calls through the playtest bridge ??never a production fallback), and
## MOCK (fixture transport via the adapter's existing mock_mode).
const BACKEND_PROVIDER := "PROVIDER"
const BACKEND_AGENT := "EXTERNAL_AGENT"
const BACKEND_MOCK := "MOCK"
## DEBUG-HARNESS aliases (Agent-as-General gate): REAL_PROVIDER names the
## production provider path; DEBUG_AGENT names the local-agent General path
## (same park/submit machinery as EXTERNAL_AGENT, served through the file
## debug transport by the headless harness). Default remains PROVIDER.
const BACKEND_REAL_PROVIDER := "REAL_PROVIDER"
const BACKEND_DEBUG_AGENT := "DEBUG_AGENT"

var _agent_backend := BACKEND_PROVIDER
## The currently parked EXTERNAL_AGENT General request ({} when none).
var _agent_parked := {}
## Processed agent submissions (observability only; never consulted).
var _agent_queue: Array = []


## Canonical backend value: the DEBUG-HARNESS aliases collapse to the
## production machinery (DEBUG_AGENT -> EXTERNAL_AGENT park/submit,
## REAL_PROVIDER -> PROVIDER). Unknown names return "".
static func canonical_backend(mode: String) -> String:
	var want := mode.strip_edges().to_upper()
	if want == BACKEND_AGENT or want == BACKEND_DEBUG_AGENT:
		return BACKEND_AGENT
	if want == BACKEND_PROVIDER or want == BACKEND_REAL_PROVIDER:
		return BACKEND_PROVIDER
	if want == BACKEND_MOCK:
		return BACKEND_MOCK
	return ""


## True for both local-agent General backends (EXTERNAL_AGENT, DEBUG_AGENT).
func _uses_agent_backend() -> bool:
	return _agent_backend == BACKEND_AGENT or _agent_backend == BACKEND_DEBUG_AGENT


## TRAINING_CONTRACT_REVIEW_WAKE_V1: explicit TRAINING/EVAL STRICT scope.
## Default OFF; Local-vs-Local alone never enables it.
func _strict_enabled() -> bool:
	return StrictCls.strict_enabled()


## Match-layer poll seam: the latched strict fault ({} when none).
func strict_fault() -> Dictionary:
	return _strict_fault.duplicate(true)


func set_utility_bot_fallback_controller(controller: Node) -> void:
	_utility_fallback_controller = controller


func utility_bot_fallback_status() -> Dictionary:
	return {"enabled": _utility_fallback_enabled(), "pending": _utility_fallback_pending.duplicate(true),
		"controller_bound": is_instance_valid(_utility_fallback_controller)}


func _utility_fallback_enabled() -> bool:
	if _strict_enabled():
		return false
	var raw := OS.get_environment("UTILITY_BOT_BRAIN_FALLBACK").strip_edges().to_lower()
	return raw in ["1", "true", "on", "yes"] \
		and is_instance_valid(_utility_fallback_controller) \
		and _utility_fallback_controller.has_method("run_side_phase") \
		and _utility_fallback_controller.has_signal("phase_finished")


func _utility_fallback_note(kind: String, code: String, detail: String, turn: int) -> void:
	if not _utility_fallback_enabled() or not StrictCls.is_brain_contract_code(code):
		return
	if not _utility_fallback_pending.is_empty():
		return
	_utility_fallback_pending = {"kind": kind, "code": code, "detail": detail.left(220), "brain_turn": turn}
	print("[CloudTurn] UTILITY_BOT_FALLBACK_LEASED side=%s kind=%s code=%s brain_turn=%d" % [_SIDE(), kind, code, turn])


func _utility_fallback_run(turn: int) -> Dictionary:
	var fault := _utility_fallback_pending.duplicate(true)
	_utility_fallback_pending = {}
	if not _utility_fallback_enabled() or not is_instance_valid(_utility_fallback_controller):
		return {"ok": false, "code": "UTILITY_BOT_FALLBACK_UNAVAILABLE", "detail": "UtilityBot controller unavailable."}
	print("[CloudTurn] UTILITY_BOT_FALLBACK_BEGIN side=%s turn=%d brain_failure=%s" % [_SIDE(), turn, str(fault.get("code", ""))])
	# Object.call() can return before an async Node method finishes. Subscribe
	# before starting it and wait for the explicit end-of-phase signal, so
	# Cloud never releases its RED phase lock while Utility is still acting.
	var utility := _utility_fallback_controller
	var completion := {"done": false, "result": {}}
	var on_complete := func(phase_result: Dictionary) -> void:
		completion["done"] = true
		completion["result"] = phase_result.duplicate(true)
	utility.connect("phase_finished", on_complete, CONNECT_ONE_SHOT)
	utility.call("run_side_phase")
	while not bool(completion["done"]):
		if not is_instance_valid(utility) or get_tree() == null:
			return {"ok": false, "code": "UTILITY_BOT_FALLBACK_INTERRUPTED", "detail": "UtilityBot controller left the tree before phase completion."}
		await get_tree().process_frame
	var result: Dictionary = completion["result"]
	result["utility_bot_fallback"] = true
	result["brain_failure"] = fault
	print("[CloudTurn] UTILITY_BOT_FALLBACK_END side=%s turn=%d ok=%s brain_failure=%s" % [_SIDE(), turn,
		str(bool(result.get("ok", false))), str(fault.get("code", ""))])
	# The failed INITIAL plan remains absent. Clear its failure latch only
	# after the bounded bot turn; the next normal planning opportunity fires
	# Brain. Manual victory_retry_initial() would prefetch immediately here.
	if str(fault.get("kind", "")) == "INITIAL" and _vp_init_state == VP_INIT_FAILED:
		_rearm_initial_next_phase()
	return result


func _rearm_initial_next_phase() -> void:
	_vp_init_state = VP_INIT_NOT_STARTED
	_vp_init_req = ""
	_vp_init_plan = {}
	_vp_init_error = ""
	_vp_init_failure_class = ""
	_vp_init_retries = 0
	_vp_init_prefetched = false
	_vp_init_done = {}
	_vp_init_armed = false
	_vp_init_armed_obs = {}
	print("[CloudTurn] INITIAL_REARMED_NEXT_PHASE side=%s" % _SIDE())


## Latch a strict Brain-contract fault. First fault wins; transport and
## internal codes never latch (no Brain response existed to judge).
func _strict_latch(kind: String, code: String, detail: String, turn: int, call_id: String = "") -> void:
	if not _strict_enabled():
		return
	if not _strict_fault.is_empty():
		return
	if not StrictCls.is_brain_contract_code(code):
		return
	if kind.strip_edges().to_upper() == "REVIEW" and not strict_latch_reviews:
		print("[CloudTurn] STRICT_REVIEW_REJECTED_NOT_LATCHED side=%s code=%s turn=%d (plan retained; human play)" % [_SIDE(), code, turn])
		return
	_strict_fault = {"side": _SIDE(), "kind": kind.strip_edges().to_upper(),
		"code": code.strip_edges().to_upper(), "detail": detail.left(220),
		"turn": turn, "call": str(call_id)}
	print("[CloudTurn] STRICT_BRAIN_CONTRACT_FAULT side=%s kind=%s code=%s turn=%d (no repair, no fallback; match layer finalizes LOSS)" % [
		_SIDE(), str(_strict_fault.get("kind", "")), str(_strict_fault.get("code", "")), turn])


## Strict short-circuit envelope for the hierarchy phase: no decision
## wait, no HOLD/skip substitution, no execution. The mount/self-play
## layer polls strict_fault() and finalizes the authoritative terminal.
func _strict_failure_result(turn: int) -> Dictionary:
	return {"ok": false, "code": "STRICT_BRAIN_CONTRACT_FAILURE",
		"status": "STRICT_BRAIN_CONTRACT_FAILURE",
		"detail": "Strict training/eval: first-try Brain response rejected (%s); %s loses." % [
			str(_strict_fault.get("code", "?")), _SIDE()],
		"strict_fault": _strict_fault.duplicate(true),
		"hierarchy": true, "turn": turn}


## Log/record label for the active agent backend (DEBUG_AGENT keeps its own
## name in telemetry so harness runs are distinguishable from MCP runs).
func _agent_provider_label() -> String:
	return "debug_agent" if _agent_backend == BACKEND_DEBUG_AGENT else "external_agent"


## Switch the General backend. EXTERNAL_AGENT / DEBUG_AGENT require the
## MISSION_HIERARCHY control mode (the legacy per-turn tactical path has no
## General requests).
func set_agent_backend(mode: String) -> Dictionary:
	var want := mode.strip_edges().to_upper()
	if canonical_backend(want).is_empty():
		return {"ok": false, "code": "INVALID_BACKEND", "detail": "mode must be PROVIDER | REAL_PROVIDER | EXTERNAL_AGENT | DEBUG_AGENT | MOCK."}
	if _phase_active:
		return {"ok": false, "code": "PHASE_ACTIVE", "detail": "Switch backends between phases."}
	if (want == BACKEND_AGENT or want == BACKEND_DEBUG_AGENT) and get_control_mode() != CONTROL_HIERARCHY:
		return {"ok": false, "code": "NEEDS_HIERARCHY", "detail": "EXTERNAL_AGENT/DEBUG_AGENT drives the MISSION_HIERARCHY path; switch control mode first."}
	if _adapter != null:
		_adapter.mock_mode = want == BACKEND_MOCK
	_agent_backend = want
	print("[CloudTurn] GENERAL_BACKEND -> %s" % _agent_backend)
	return {"ok": true, "code": "", "detail": "", "backend": _agent_backend}


func get_agent_backend() -> String:
	return _agent_backend


## Park one General request for the external agent (DEV transport). The
## packet/menu are EXACTLY what the provider path would have sent.
func agent_park_request(kind: String, packet: Dictionary, menu: Dictionary, req_id: String, system_prompt: String, turn: int) -> Dictionary:
	_agent_parked = {
		"kind": kind, "request_id": req_id, "turn": turn,
		"packet": packet.duplicate(true), "menu": menu.duplicate(true),
		"system_prompt": system_prompt,
		"parked_ms": Time.get_ticks_msec(),
	}
	print("[CloudTurn] AGENT_PARK kind=%s req=%s turn=%d packet_chars=%d" % [
		kind, req_id, turn, JSON.stringify(packet).length()])
	return {"ok": true, "code": "", "detail": "", "request_id": req_id}


## Complete the parked INITIAL_COORDINATION with the agent's selection text.
## The text flows through the SAME parse/expand/validate/adopt gates as a
## provider reply (the waiters poll _general_result by request_id).
func agent_submit_initial(selection_text: String) -> Dictionary:
	return _agent_complete("INITIAL", selection_text)


## Complete the parked REVIEW_COORDINATION with the agent's decision text
## (KEEP / ADJUST+changes / REPLAN+selection ??canonical contract).
func agent_submit_review(review_text: String) -> Dictionary:
	return _agent_complete("REVIEW", review_text)


func _agent_complete(kind: String, text: String) -> Dictionary:
	if not _uses_agent_backend():
		return {"ok": false, "code": "AGENT_BACKEND_OFF", "detail": "General backend is %s." % _agent_backend}
	if _agent_parked.is_empty():
		return {"ok": false, "code": "NO_PARKED_REQUEST", "detail": "No General request is parked."}
	if str(_agent_parked.get("kind", "")) != kind:
		return {"ok": false, "code": "PARKED_KIND_MISMATCH", "detail": "Parked request is %s." % str(_agent_parked.get("kind", ""))}
	var content := text.strip_edges()
	if content.is_empty():
		return {"ok": false, "code": "EMPTY_SUBMISSION", "detail": "Submission text is empty."}
	var req_id := str(_agent_parked.get("request_id", ""))
	_general_result = {
		"ok": true, "request_id": req_id, "http_status": 200,
		"content_text": content, "latency_ms": int(Time.get_ticks_msec() - int(_agent_parked.get("parked_ms", 0))),
		"provider": _agent_provider_label(), "model": "agent", "transport": "structured_tool",
		"finish_reason": "agent", "mock": false,
		"envelope": {"agent_backend": true, "finish_reason": "agent", "content_chars": content.length()},
	}
	_agent_queue.append({"request_id": req_id, "kind": kind, "turn": int(_agent_parked.get("turn", 0)),
		"chars": content.length(), "completed_ms": Time.get_ticks_msec()})
	if _agent_queue.size() > 32:
		_agent_queue = _agent_queue.slice(_agent_queue.size() - 32)
	_agent_parked = {}
	print("[CloudTurn] AGENT_SUBMIT kind=%s req=%s chars=%d ??canonical gates resume." % [kind, req_id, content.length()])
	return {"ok": true, "code": "", "detail": "Submitted; the controller continues canonical parse/expand/adoption.", "request_id": req_id}


## Agent work poll: the currently parked General request
## (kind/request_id/system_prompt/packet/menu/turn top-level), or {} when
## none is parked. The agent backend polls for work, then completes it via
## agent_submit_initial / agent_submit_review.
func agent_poll() -> Dictionary:
	return _agent_parked.duplicate(true)


## DEV observability: current agent-mode surface state.
func agent_surface() -> Dictionary:
	return {"backend": _agent_backend, "parked": _agent_parked.duplicate(true),
		"staged": not _staged_plan.is_empty(), "staged_decision": _staged_review_decision,
		"review_in_flight": _review_in_flight, "phase": str(_state.get("phase", "")),
		"submissions": _agent_queue.duplicate(true), "telemetry": GeneralTraceCls.snapshot()}


## General Lab view for the CLOUD tab (hierarchy observability). Separates
## what the Cloud General owns (plan/missions/doctrine) from what Godot owns
## (local candidate scoring, compiler checks, execution results).
func get_general_view() -> Dictionary:
	if _manager == null:
		return {"control_mode": _control_mode, "has_plan": false}
	return {
		"control_mode": _control_mode,
		"has_plan": true,
		"provider": _config.provider_id if _config != null else "",
		"model": _config.model if _config != null else "",
		"current_turn": int(_state.get("turn", 0)),
		"plan": _manager.get_plan(),
		"statuses": _hier_last.get("statuses", []),
		"traces": _hier_last.get("traces", []),
		"execution": _hier_execution_rows(),
		"review": _hier_last.get("review", {}),
		"staged": not _staged_plan.is_empty(),
		"review_in_flight": not _review_in_flight.is_empty(),
		"wakeup": _manager.wakeup_view(),
		"telemetry": GeneralTraceCls.snapshot(),
		"last_general_packet": _last_general_packet.duplicate(true),
		"coordination": _manager.get_coordination(),
		"victory_mode": _victory_mode,
		"victory_plan": _manager.vp_get_plan(),
		"victory_staged": not _staged_vp.is_empty(),
		"victory_staged_decision": _staged_vp_decision,
		"victory_last_call": _manager.vp_last_call(),
		"victory_last_revision": _manager.vp_last_revision(),
		"victory_revision_tail": _manager.vp_revision_tail(6),
		"victory_audit_tail": _manager.vp_audit_tail(6),
		"victory_initial": victory_initial_status(),
	}


## VICTORY PLAN V0 (additive): developer VictoryPlan view (HUD + Model View
## VICTORY tab). Read-only; never touches config, keys, or battle state.
func get_victory_plan_view() -> Dictionary:
	if _manager == null:
		return {"has_plan": false, "text": "(no manager)"}
	var vp := _manager.vp_get_plan()
	var init := victory_initial_status()
	if not VictoryPlanCls.has_plan(vp):
		var last := _manager.vp_last_call()
		var head := "(no VictoryPlan yet: the General drafts one at battle start)"
		if str(init.get("state", "")) == VP_INIT_FAILED:
			head = "NO VALID VICTORY PLAN (initial generation FAILED: %s). %s holds; use RETRY PLAN." % [str(init.get("error", "?")), _SIDE()]
		elif str(init.get("state", "")) in [VP_INIT_REQUESTING, VP_INIT_RETRYING]:
			head = "(VictoryPlan generating: %s %s, started t%d: applies at the first %s phase)" % [
				str(init.get("state", "?")), str(init.get("req", "?")), int(init.get("turn", 0)), _SIDE()]
		elif str(init.get("state", "")) == VP_INIT_READY:
			head = "(VictoryPlan READY v1: applies at the first %s phase, zero new calls)" % _SIDE()
		elif not last.is_empty():
			head = "(no VictoryPlan) last call: %s t%d %s -> %s (%s)" % [str(last.get("call_id", "?")),
				int(last.get("turn", 0)), str(last.get("trigger", "?")), str(last.get("decision", "?")),
				str(last.get("outcome", "?"))]
		return {"has_plan": false, "victory_mode": _victory_mode, "initial": init, "text": head, "last_call": last}
	var lines: Array = []
	lines.append("=== VICTORY PLAN ===")
	lines.append("Plan ID: %s   Revision: v%d (parent v%d)   Lineage: %s" % [
		str(vp.get("victory_plan_id", "?")), int(vp.get("revision", 0)), int(vp.get("parent_revision", 0)),
		str(vp.get("lineage_id", "?"))])
	lines.append("Final objective: %s" % str(vp.get("final_objective", "-")))
	lines.append("Desired end state: %s" % str(vp.get("desired_end_state", "-")))
	lines.append("Review cadence: every %d turn(s) (NOT a planning horizon)" % int(vp.get("review_horizon_turns", 0)))
	lines.append("Authored from snapshot: %s" % _manager.vp_get_initial_snapshot())
	lines.append("")
	lines.append("=== CURRENT PHASE ===")
	lines.append(VictoryPlanCls.render_current_phase(vp))
	var ph := VictoryPlanCls.active_phase(vp)
	lines.append("Commander intent: %s" % str(ph.get("commander_intent", "-")))
	lines.append("Entry: %s" % _vp_cond_short(ph.get("entry_conditions", [])))
	lines.append("Failure: %s" % _vp_cond_short(ph.get("failure_conditions", [])))
	lines.append("")
	lines.append("=== PHASES ===")
	for p_val in (vp.get("phases", []) as Array):
		if p_val is Dictionary:
			lines.append("- %s [%s] %s :: %s" % [str((p_val as Dictionary).get("phase_id", "?")),
				str((p_val as Dictionary).get("status", "?")), str((p_val as Dictionary).get("name", "")),
				str((p_val as Dictionary).get("purpose", ""))])
	lines.append("")
	lines.append("=== ACTIVE MISSIONS ===")
	for m_val in (_manager.get_plan().get("missions", []) as Array):
		if m_val is Dictionary:
			lines.append("- %s %s %s [%s] units=%s" % [str((m_val as Dictionary).get("mission_id", "?")),
				str((m_val as Dictionary).get("task", "?")), str((m_val as Dictionary).get("area", "?")),
				str((m_val as Dictionary).get("status", "?")),
				",".join((m_val as Dictionary).get("assigned_units", []))])
	var last_call := _manager.vp_last_call()
	lines.append("")
	lines.append("=== LAST GENERAL CALL ===")
	if last_call.is_empty():
		lines.append("(none)")
	else:
		lines.append("Call: %s  Turn: %d  Backend: %s" % [str(last_call.get("call_id", "?")),
			int(last_call.get("turn", 0)), str(last_call.get("backend", "?"))])
		lines.append("Trigger: %s" % str(last_call.get("trigger", "?")))
		lines.append("Why: %s" % str(last_call.get("why", "-")))
		lines.append("Decision: %s  Outcome: %s  Latency: %dms (http %s)" % [str(last_call.get("decision", "?")),
			str(last_call.get("outcome", "?")), int(last_call.get("latency_ms", 0)), str(last_call.get("http_status", "?"))])
		lines.append("finish=%s final=%dchars reasoning=%s(%d) usage=%s budget=%d contract=%s prefetch=%s" % [
			str(last_call.get("finish_reason", "-")) if not str(last_call.get("finish_reason", "")).is_empty() else "-",
			int(last_call.get("final_chars", 0)),
			"yes" if bool(last_call.get("reasoning_present", false)) else "no", int(last_call.get("reasoning_chars", 0)),
			JSON.stringify(last_call.get("usage", {})), int(last_call.get("output_budget", 0)),
			str(last_call.get("contract", "-")), str(bool(last_call.get("prefetch", false)))])
		lines.append("Revision: v%d -> v%d  Phase: %s -> %s  Laya notified: %s" % [
			int(last_call.get("revision_before", 0)), int(last_call.get("revision_after", 0)),
			str(last_call.get("phase_before", "-")), str(last_call.get("phase_after", "-")),
			str(bool(last_call.get("laya_notified", false)))])
		var vv: Dictionary = last_call.get("validation", {})
		if not bool(vv.get("ok", false)):
			lines.append("Validation: REJECT %s: %s" % [str(vv.get("code", "?")), str(vv.get("detail", ""))])
	var last_rev := _manager.vp_last_revision()
	lines.append("")
	lines.append("=== LAST REVISION ===")
	if last_rev.is_empty():
		lines.append("(none)")
	else:
		lines.append(VictoryPlanCls.render_revision(last_rev))
	var audit := _manager.vp_audit_tail(6)
	lines.append("")
	lines.append("=== GENERAL CALL HISTORY (last %d) ===" % audit.size())
	if audit.is_empty():
		lines.append("(none)")
	for a_val in audit:
		var a: Dictionary = a_val
		lines.append("- %s t%d %s -> %s (%s) rev v%d->v%d why: %s" % [str(a.get("call_id", "?")),
			int(a.get("turn", 0)), str(a.get("trigger", "?")), str(a.get("decision", "?")),
			str(a.get("outcome", "?")), int(a.get("revision_before", 0)), int(a.get("revision_after", 0)),
			str(a.get("why", "-")).left(100)])
	return {"has_plan": true, "victory_mode": _victory_mode, "initial": init, "text": "\n".join(lines),
		"plan": vp, "last_call": last_call, "last_revision": last_rev, "audit_tail": audit}


func _vp_cond_short(conds: Array) -> String:
	if conds.is_empty():
		return "-"
	var parts: Array = []
	for c_val in conds:
		if c_val is Dictionary:
			parts.append(str((c_val as Dictionary).get("trigger", "?")))
	return "; ".join(parts)


## Per-mission execution results of the last hierarchy turn (annotated onto
## the shared order views by mission_id right after execution).
func _hier_execution_rows() -> Array:
	var out: Array = []
	for o_val in (_last_view.get("orders", []) as Array):
		if not o_val is Dictionary or not (o_val as Dictionary).has("mission_id"):
			continue
		var o: Dictionary = o_val
		out.append({
			"mission_id": str(o.get("mission_id", "?")),
			"status": str(o.get("status", "?")),
			"executed": ((o.get("executed", []) as Array).size()),
			"failed": ((o.get("failed", []) as Array).size()),
			"plan_failed": ((o.get("plan_failed", []) as Array).size()),
		})
	return out


## STEP mode: arm exactly one Cloud turn.
func request_step() -> void:
	_step_armed = true


## Failure/needs-config decisions (also usable while WAITING_STEP).
func decide_retry() -> void:
	_decision = "retry"


func decide_skip() -> void:
	_decision = "skip"


func decide_hold_all() -> void:
	_decision = "hold"


func get_state() -> Dictionary:
	return _state.duplicate(true)


func get_last_view() -> Dictionary:
	return _last_view.duplicate(true)


func get_previous_summary() -> Dictionary:
	return _prev_summary.duplicate(true)


func get_plan_packet() -> Dictionary:
	if _plan == null:
		return {}
	return _plan.to_packet()


func live_unit_manager() -> RefCounted:
	if _bridge == null:
		return null
	return _bridge.get_manager()


## Effective model input of the last RED turn ({} packet before turn one).
func get_last_context() -> Dictionary:
	return {
		"has_turn": not _last_packet.is_empty(),
		"system_prompt": PacketCls.system_prompt_for(_side),
		"packet": _last_packet.duplicate(true),
		"observation": _last_obs.duplicate(true),
		"plan_memory": get_plan_packet(),
		"response_schema": ResponseCls.response_schema(),
		"provider": _config.provider_id if _config != null else "",
		"model": _config.model if _config != null else "",
	}


## Read-only preview of what the NEXT Cloud turn would send: freeze the
## current RED observation, build the packet, return it. Pure observation;
## no model call, no validation side effect, no state change.
func preview_context() -> Dictionary:
	if _bridge == null or _plan == null:
		return {"ok": false, "code": "NOT_BOUND", "detail": "Controller is not bound."}
	var obs := ObsCls.build(_bridge, _side)
	if not bool(obs.get("ok", false)):
		return {"ok": false, "code": "NO_OBSERVATION",
			"detail": str(obs.get("error", "Observation unavailable."))}
	var catalog := TableCls.build_catalog(obs)
	var packet := PacketCls.build(obs, catalog, _plan.to_packet(), _prev_summary.duplicate(true))
	return {
		"ok": true,
		"system_prompt": PacketCls.system_prompt_for(_side),
		"packet": packet,
		"observation": obs,
		"plan_memory": _plan.to_packet(),
		"response_schema": ResponseCls.response_schema(),
		"snapshot_id": str(obs.get("snapshot_id", "")),
		"turn": int(obs.get("turn", 0)),
	}


# --- main phase ---------------------------------------------------------

## Runs one full RED Cloud phase. Called (and awaited) by the shell during
## ENEMY_PHASE. Returns a result dict; also emits phase_finished.
func run_red_phase() -> Dictionary:
	return await run_side_phase()


## SYMMETRIC V1: runs one full phase for the bound side (RED or BLUE).
## The shell calls run_red_phase for RED; the symmetric sandbox calls
## run_side_phase on each side's controller directly.
func run_side_phase() -> Dictionary:
	if _phase_active:
		print("[CloudTurn] BLOCKED code=PHASE_ACTIVE")
		return {"ok": false, "code": "PHASE_ACTIVE", "detail": "A Cloud phase is already running."}
	if _bridge == null or _executor == null or _adapter == null or _config == null:
		print("[CloudTurn] BLOCKED code=NOT_BOUND")
		return {"ok": false, "code": "NOT_BOUND", "detail": "Controller is not bound."}
	print("[CloudTurn] %s_PHASE_BEGIN mode=%s fp=%s key=%s" % [_SIDE(), _mode, _config.fingerprint(),
		"YES" if _config.has_key() else "NO"])
	SessionCls.trace("%s_PHASE_BEGIN" % _SIDE(), null, _config)
	TraceCls.begin_turn({"provider": _config.provider_id, "model": _config.model,
		"protocol": _config.effective_transport(), "mode": _mode, "side": _SIDE()})
	_phase_active = true
	_state["phase_active"] = true
	_turn_seq += 1
	_executor.set_external_busy(true, "%s Cloud phase in progress." % _SIDE())
	var out := await _run_inner()
	_executor.set_external_busy(false)
	_phase_active = false
	_state["phase_active"] = false
	cloud_state_changed.emit(_state.duplicate(true))
	phase_finished.emit(out)
	print("[CloudTurn] %s_PHASE_END ok=%s code=%s" % [_SIDE(), str(bool(out.get("ok", false))), str(out.get("code", out.get("status", "?")))])
	out["side"] = _SIDE()
	return out


func _run_inner() -> Dictionary:
	# STEP gating: wait for the human to trigger this RED turn (or to
	# pre-decide SKIP/HOLD while waiting).
	if _mode == MODE_STEP and not _step_armed:
		_decision = ""
		_set_state("WAITING_STEP", "STEP mode: press RUN CLOUD TURN (or SKIP / HOLD ALL).")
		TraceCls.set_stage("WAITING_STEP", "STEP mode: press RUN CLOUD TURN.")
		print("[CloudTurn] WAITING_STEP ??press RUN CLOUD TURN on the CLOUD bar (or switch to AUTO mode).")
		var wframes := 0
		while not _step_armed and _decision.is_empty():
			await get_tree().process_frame
			wframes += 1
			_watchdog_tick(wframes, "STEP trigger")
		if not _decision.is_empty():
			var early := _decision
			_decision = ""
			_step_armed = false
			if early == "skip":
				return _end_skipped("step_skipped_by_human")
			if early == "hold":
				return await _end_hold_all("step_hold_all_by_human")
	else:
		print("[CloudTurn] %s_AUTO_TRIGGER mode=%s (no human trigger needed)" % [_SIDE(), _mode])
	_step_armed = false
	if _control_mode == CONTROL_HIERARCHY:
		return await _run_hierarchy_inner()
	var attempt := 0
	var auto_retries := 0
	while true:
		attempt += 1
		await _pause_point("Before RED observation freeze (attempt %d)." % attempt)
		var gate := SessionCls.resolve_for_use(_config)
		if not bool(gate.get("ok", false)):
			_set_state("NEEDS_CONFIG", str(gate.get("detail", "")))
			TraceCls.set_stage("NEEDS_CONFIG", str(gate.get("detail", "")))
			print("[CloudTurn] CLOUD TURN BLOCKED ??%s fp=%s" % [str(gate.get("code", "")), _config.fingerprint()])
			SessionCls.trace("%s_GATE" % _SIDE(), null, _config)
			var dec0 := await _wait_for_decision()
			if dec0 == "skip":
				return _end_skipped("not_configured")
			if dec0 == "hold":
				return await _end_hold_all("not_configured")
			continue # retry: the human configured in the panel meanwhile
		_set_state("OBSERVING", "Freezing %s authorized observation (attempt %d)." % [_SIDE(), attempt])
		TraceCls.set_stage("OBSERVING", "Freezing %s authorized observation (attempt %d)." % [_SIDE(), attempt])
		var pre_fp := str(_bridge.fingerprint())
		var obs := ObsCls.build(_bridge, _side)
		if not bool(obs.get("ok", false)):
			_set_state("FAILED_OBSERVATION", str(obs.get("error", "Observation unavailable.")), "observation")
			TraceCls.set_stage("FAILED_OBSERVATION", str(obs.get("error", "Observation unavailable.")))
			var dec_obs := await _wait_for_decision()
			if dec_obs == "skip":
				return _end_skipped("observation_failed")
			if dec_obs == "hold":
				return await _end_hold_all("observation_failed")
			continue
		var turn := int(obs.get("turn", 0))
		_state["turn"] = turn
		var catalog := TableCls.build_catalog(obs)
		var packet := PacketCls.build(obs, catalog, _plan.to_packet(), _prev_summary.duplicate(true))
		_last_packet = packet.duplicate(true)
		_last_obs = obs.duplicate(true)
		TraceCls.refresh_snapshot(str(obs.get("snapshot_id", "")),
			int((obs.get("parity", {}) as Dictionary).get("state_version", -1)),
			JSON.stringify(packet).length(), PacketCls.system_prompt_for(_side).length())
		TraceCls.set_stage("BUILDING REQUEST", "Turn %d packet built." % turn)
		await _pause_point("Before Cloud model call (turn %d)." % turn)
		_set_state("THINKING", "Cloud model reasoning (turn %d, attempt %d)." % [turn, attempt])
		TraceCls.set_stage("WAITING FOR MODEL", "Attempt %d in flight." % attempt)
		_model_result = {}
		var req_id := "cloud2_t%d_a%d" % [turn, attempt]
		TraceCls.begin_attempt(attempt, AdapterCls.TURN_MAX_TOKENS, req_id)
		var started := _adapter.request_turn(req_id, packet, _config, PacketCls.system_prompt_for(_side))
		if not bool(started.get("ok", false)):
			_set_state("FAILED_REQUEST", str(started.get("detail", "Request failed to start.")), "transport")
			print("[CloudTurn] CLOUD REQUEST FAILED ??%s" % str(started.get("code", "REQUEST_FAILED")))
			_last_view = _failure_view(obs, turn, pre_fp, str(started.get("code", "REQUEST_FAILED")), str(started.get("detail", "")), 0)
			var dec1 := await _wait_for_decision()
			if dec1 == "skip":
				return _end_skipped("request_failed")
			if dec1 == "hold":
				return await _end_hold_all("request_failed")
			continue
		var model_res := await _wait_for_model(req_id)
		var latency := int(model_res.get("latency_ms", 0))
		TraceCls.finish_attempt(model_res)
		print("[CloudTurn] %s_HTTP_STATUS=%s latency=%dms ok=%s" % [_SIDE(),
			str(model_res.get("http_status", "?")), latency, str(bool(model_res.get("ok", false)))])
		# Single automatic retry for output-budget exhaustion ONLY: same
		# frozen obs/packet/snapshot, larger budget, nothing executed from
		# attempt 1. If battle state moved meanwhile, fail over to the
		# human decision instead of reasoning from a stale snapshot.
		if should_auto_retry(model_res, auto_retries):
			if str(_bridge.fingerprint()) == pre_fp:
				auto_retries += 1
				_set_state("RETRYING", "Output budget exhausted (%s); retrying once with a larger budget (same snapshot)." % str(model_res.get("code", "")))
				TraceCls.set_stage("RETRYING", "Output budget exhausted (%s); retrying once with a larger budget (same snapshot)." % str(model_res.get("code", "")))
				TraceCls.mark_retry(AdapterCls.TURN_RETRY_MAX_TOKENS)
				print("[CloudTurn] %s_AUTO_RETRY %s attempt=%d snapshot=%s" % [_SIDE(),
					str(model_res.get("code", "")), auto_retries, str(obs.get("snapshot_id", ""))])
				_model_result = {}
				var retry_id := "cloud2_t%d_a%d_r%d" % [turn, attempt, auto_retries]
				TraceCls.begin_attempt(attempt + auto_retries, AdapterCls.TURN_RETRY_MAX_TOKENS, retry_id)
				var restarted := _adapter.request_turn(retry_id, packet, _config, PacketCls.system_prompt_for(_side), AdapterCls.TURN_RETRY_MAX_TOKENS)
				if bool(restarted.get("ok", false)):
					model_res = await _wait_for_model(retry_id)
					latency = int(model_res.get("latency_ms", 0))
					TraceCls.finish_attempt(model_res)
					print("[CloudTurn] %s_RETRY_HTTP_STATUS=%s latency=%dms ok=%s code=%s" % [_SIDE(),
						str(model_res.get("http_status", "?")), latency,
						str(bool(model_res.get("ok", false))), str(model_res.get("code", "-"))])
			else:
				print("[CloudTurn] %s_AUTO_RETRY_STALE ??state moved; human decides." % _SIDE())
		if not bool(model_res.get("ok", false)):
			_set_state("FAILED_" + str(model_res.get("code", "PROVIDER_ERROR")), str(model_res.get("detail", "")), "transport")
			print("[CloudTurn] MODEL RESPONSE FAILED ??%s %dms" % [str(model_res.get("code", "?")), latency])
			_last_view = _failure_view(obs, turn, pre_fp, str(model_res.get("code", "PROVIDER_ERROR")), str(model_res.get("detail", "")), latency, model_res, auto_retries)
			var dec2 := await _wait_for_decision()
			if dec2 == "skip":
				return _end_skipped(str(model_res.get("code", "provider_error")).to_lower())
			if dec2 == "hold":
				return await _end_hold_all(str(model_res.get("code", "provider_error")).to_lower())
			continue
		_set_state("VALIDATING", "Validating structured orders (turn %d)." % turn)
		TraceCls.set_stage("VALIDATING", "Validating structured orders (turn %d)." % turn)
		print("[CloudTurn] MODEL RESPONSE OK chars=%d %dms" % [str(model_res.get("content_text", "")).length(), latency])
		var final_text := str(model_res.get("content_text", ""))
		var parsed := ResponseCls.parse(final_text,
			{"acting_side": _SIDE(), "snapshot_id": str(obs.get("snapshot_id", ""))})
		# Decision trace = the model's explicit FINAL output only (never
		# reasoning_content). Recorded before any ok/fail branch so a partially
		# valid response is still diagnosable.
		TraceCls.set_decision(parsed, final_text)
		print("[CloudTurn] %s_RESPONSE_PARSED ok=%s orders=%d code=%s" % [_SIDE(),
			str(bool(parsed.get("ok", false))), int(parsed.get("order_count", 0)),
			str(parsed.get("code", ""))])
		if not bool(parsed.get("ok", false)) and int(parsed.get("order_count", 0)) == 0:
			_set_state("FAILED_" + str(parsed.get("code", "INVALID_RESPONSE")), str(parsed.get("detail", "")), "tactical_plan")
			_last_view = _failure_view(obs, turn, pre_fp, str(parsed.get("code", "INVALID_RESPONSE")), str(parsed.get("detail", "")), latency)
			_last_view["response_text_head"] = str(model_res.get("content_text", "")).left(600)
			var dec3 := await _wait_for_decision()
			if dec3 == "skip":
				return _end_skipped("invalid_response")
			if dec3 == "hold":
				return await _end_hold_all("invalid_response")
			continue
		print("[CloudTurn] %s_VALIDATION orders=%d proceeding to execution" % [_SIDE(), int(parsed.get("order_count", 0))])
		return await _execute_orders(obs, packet, parsed, model_res, pre_fp, turn, attempt, auto_retries)
	# Unreachable: the attempt loop only exits via return. Satisfies the
	# analyzer's exhaustive-return check.
	return {"ok": false, "code": "UNREACHABLE", "detail": "Unreachable."}


## Sequential multi-order execution with per-order revalidation.
func _execute_orders(obs: Dictionary, packet: Dictionary, parsed: Dictionary, model_res: Dictionary, pre_fp: String, turn: int, attempt: int, auto_retries: int = 0) -> Dictionary:
	var checked: Array = parsed.get("orders", [])
	print("[CloudTurn] %s_EXECUTION begin orders=%d" % [_SIDE(), checked.size()])
	_set_state("EXECUTING", "Executing %d order(s) sequentially (turn %d)." % [checked.size(), turn])
	TraceCls.set_stage("EXECUTING", "Executing %d order(s) sequentially (turn %d)." % [checked.size(), turn])
	var trace_views: Array = []
	var order_views: Array = []
	var executed_count := 0
	var rejected_count := 0
	var idx := 0
	# Issue-1 observability: per-order trace rows pushed to the telemetry
	# store as the sequential loop produces them (same views, no re-derivation).
	TraceCls.set_orders(trace_views)
	for o_val in checked:
		idx += 1
		var o: Dictionary = o_val
		if not bool(o.get("ok", false)):
			rejected_count += 1
			order_views.append({
				"index": idx, "status": "REJECTED",
				"validation": {"ok": false, "code": str(o.get("code", "?")), "detail": str(o.get("detail", ""))},
				"order": o.get("order", {}),
				"resolved_units": [], "executed": [], "failed": [],
			})
			trace_views.append(order_views[order_views.size() - 1])
			TraceCls.set_orders(trace_views)
			continue
		await _pause_point("Before order %d/%d (turn %d)." % [idx, checked.size(), turn])
		_set_state("EXECUTING", "Order %d/%d: %s (turn %d)." % [idx, checked.size(), str((o.get("order", {}) as Dictionary).get("action", "?")), turn])
		_exec_result = {}
		# The phase soft-lock blocks HUMAN orders; the controller's own call
		# must pass. Clearing and re-setting around execute() is atomic (no
		# await between): a refused human order cannot slip in, and an
		# accepted Cloud order holds the executor's own _busy immediately.
		_executor.set_external_busy(false)
		var acc: Dictionary = _executor.execute(o.get("order", {}), "", _side)
		_executor.set_external_busy(true, "%s Cloud phase in progress." % _SIDE())
		if not bool(acc.get("accepted", false)):
			rejected_count += 1
			order_views.append({
				"index": idx, "status": "REJECTED",
				"validation": {"ok": false, "code": str(acc.get("code", "EXECUTOR_REFUSED")), "detail": str(acc.get("detail", ""))},
				"order": o.get("order", {}),
				"resolved_units": [], "executed": [], "failed": [],
			})
			trace_views.append(order_views[order_views.size() - 1])
			TraceCls.set_orders(trace_views)
			continue
		var fin := await _wait_for_exec()
		var rows: Array = fin.get("executed_units", [])
		executed_count += rows.size()
		if not rows.is_empty():
			pass
		else:
			rejected_count += 1
		order_views.append({
			"index": idx, "status": str(fin.get("execution_status", "?")),
			"validation": {"ok": true, "code": "", "detail": ""},
			"order": o.get("order", {}),
			"snapshot_id": str(fin.get("snapshot_id", "")),
			"resolved_units": fin.get("resolved_units", []),
			"executed": rows,
			"failed": fin.get("execution_failed", []),
			"plan_failed": fin.get("plan_failed", []),
		})
		trace_views.append(order_views[order_views.size() - 1])
		TraceCls.set_orders(trace_views)
		TraceCls.set_stage("EXECUTING", "Order %d/%d done: %s" % [idx, checked.size(), str(fin.get("execution_status", "?"))])
	var post_fp := str(_bridge.fingerprint())
	var status := "EXECUTED"
	if executed_count == 0:
		status = "FAILED" if rejected_count > 0 else "EMPTY"
	elif rejected_count > 0:
		status = "PARTIAL"
	_plan.update_from_plan(parsed.get("plan", {}), turn)
	var result_note := "t%d: %d order(s), %d unit execution(s), %d rejected (%s)" % [turn, checked.size(), executed_count, rejected_count, status]
	print("[CloudTurn] ORDERS parsed=%d executed_units=%d rejected=%d status=%s" % [checked.size(), executed_count, rejected_count, status])
	_plan.note_result(result_note)
	_prev_summary = {
		"turn": turn, "status": status, "order_count": checked.size(),
		"executed_count": executed_count, "rejected_count": rejected_count,
		"note": result_note,
	}
	var record := {
		"timestamp": Time.get_datetime_string_from_system(),
		"battle_id": str(obs.get("battle_id", "")),
		"turn": turn, "attempt": attempt,
		"acting_side": _SIDE(),
		"snapshot_id": str(obs.get("snapshot_id", "")),
		"state_version": int((obs.get("parity", {}) as Dictionary).get("state_version", -1)),
		"observation_fingerprint": str((obs.get("parity", {}) as Dictionary).get("fingerprint", "")),
		"packet_version": str(packet.get("packet_version", "")),
		# AGENT-MCP-PLAYTEST metadata fix: stamp the ACTIVE General transport,
		# not the configured provider (EXTERNAL_AGENT / DEBUG_AGENT runs never call it).
		"provider": _agent_provider_label() if _uses_agent_backend() else _config.provider_id,
		"model": "agent" if _uses_agent_backend() else _config.model,
		"latency_ms": int(model_res.get("latency_ms", 0)),
		"mock": bool(model_res.get("mock", false)),
		"auto_retries": auto_retries,
		"plan": parsed.get("plan", {}),
		"rationale": parsed.get("rationale", {}),
		"orders": order_views,
		"order_count": checked.size(),
		"executed_count": executed_count,
		"rejected_count": rejected_count,
		"validation": {"ok": bool(parsed.get("ok", false)), "code": str(parsed.get("code", "")), "detail": str(parsed.get("detail", ""))},
		"executions": order_views,
		"pre_fingerprint": pre_fp,
		"post_fingerprint": post_fp,
		"status": status,
	}
	var logged := LoggerCls.log_turn(record)
	record["log_path"] = str(logged.get("path", ""))
	_last_view = {
		"model": _config.model, "provider": _config.provider_id,
		"turn": turn, "attempt": attempt,
		"latency_ms": int(model_res.get("latency_ms", 0)),
		"mock": bool(model_res.get("mock", false)),
		"auto_retries": auto_retries,
		"snapshot_id": str(obs.get("snapshot_id", "")),
		"state_version": int((obs.get("parity", {}) as Dictionary).get("state_version", -1)),
		"plan": parsed.get("plan", {}),
		"rationale": parsed.get("rationale", {}),
		"orders": order_views,
		"order_count": checked.size(),
		"executed_count": executed_count,
		"rejected_count": rejected_count,
		"pre_fingerprint": pre_fp,
		"post_fingerprint": post_fp,
		"status": status,
		"log_path": str(logged.get("path", "")),
		"summary": result_note,
	}
	_set_state("DONE", result_note)
	TraceCls.set_stage("COMPLETE", result_note)
	TraceCls.end_turn(status, result_note)
	print("[CloudTurn] %s_EXECUTION done executed=%d rejected=%d status=%s" % [_SIDE(),
		executed_count, rejected_count, status])
	var out := {
		"ok": true, "status": status, "turn": turn, "attempt": attempt,
		"order_count": checked.size(), "executed_count": executed_count,
		"rejected_count": rejected_count,
		"snapshot_id": str(obs.get("snapshot_id", "")),
		"pre_fingerprint": pre_fp, "post_fingerprint": post_fp,
		"log_path": str(logged.get("path", "")),
		"summary": result_note,
	}
	return out


## A SKIP/HOLD decision must not erase WHAT failed: when the outgoing view
## already holds this turn's failure record, it rides along into the skipped
## view and the summary names the code. Stale (other-turn) failures never
## carry.
func _carried_failure(turn: int) -> Dictionary:
	if _last_view.has("failure") and int(_last_view.get("turn", -1)) == turn:
		return {
			"failure": (_last_view.get("failure", {}) as Dictionary).duplicate(true),
			"diag": (_last_view.get("diag", {}) as Dictionary).duplicate(true),
			"head": str(_last_view.get("response_text_head", "")),
		}
	return {}


func _end_skipped(reason: String) -> Dictionary:
	TraceCls.end_turn("SKIPPED", reason)
	var turn := _current_turn()
	var carry := _carried_failure(turn)
	_prev_summary = {"turn": turn, "status": "SKIPPED", "order_count": 0,
		"executed_count": 0, "rejected_count": 0, "note": "%s phase skipped (%s)." % [_SIDE(), reason]}
	_plan.note_result("t%d: %s phase skipped (%s)." % [turn, _SIDE(), reason])
	var record := {
		"timestamp": Time.get_datetime_string_from_system(),
		"battle_id": "cloud_step1_neutral_skirmish",
		"turn": turn, "attempt": 0, "acting_side": _SIDE(),
		"snapshot_id": "", "state_version": -1,
		"provider": _config.provider_id, "model": _config.model,
		"latency_ms": 0, "plan": {}, "rationale": {},
		"orders": [], "order_count": 0, "executed_count": 0,
		"rejected_count": 0, "validation": {"ok": true, "code": "SKIPPED", "detail": reason},
		"executions": [], "pre_fingerprint": str(_bridge.fingerprint()),
		"post_fingerprint": str(_bridge.fingerprint()), "status": "SKIPPED",
	}
	var logged := LoggerCls.log_turn(record)
	_last_view = {
		"model": _config.model, "provider": _config.provider_id, "turn": turn,
		"latency_ms": 0, "snapshot_id": "", "plan": {}, "orders": [],
		"order_count": 0, "executed_count": 0, "rejected_count": 0,
		"pre_fingerprint": str(record["pre_fingerprint"]),
		"post_fingerprint": str(record["post_fingerprint"]),
		"status": "SKIPPED", "log_path": str(logged.get("path", "")),
		"summary": "%s phase skipped (%s)." % [_SIDE(), reason],
	}
	if not carry.is_empty():
		_last_view["failure"] = carry.get("failure", {})
		if not (carry.get("diag", {}) as Dictionary).is_empty():
			_last_view["diag"] = carry.get("diag", {})
		if not str(carry.get("head", "")).is_empty():
			_last_view["response_text_head"] = str(carry.get("head", ""))
		_last_view["summary"] = "%s phase skipped (%s) after %s." % [_SIDE(), reason,
			str((carry.get("failure", {}) as Dictionary).get("code", "?"))]
	_set_state("SKIPPED", "%s phase skipped (%s)." % [_SIDE(), reason])
	return {"ok": true, "status": "SKIPPED", "turn": turn, "order_count": 0,
		"executed_count": 0, "rejected_count": 0, "log_path": str(logged.get("path", "")),
		"summary": str(_last_view.get("summary", ""))}


func _end_hold_all(reason: String) -> Dictionary:
	var turn := _current_turn()
	var carry := _carried_failure(turn)
	_set_state("EXECUTING", "HOLD ALL fallback (%s)." % reason)
	TraceCls.set_stage("EXECUTING", "HOLD ALL fallback (%s)." % reason)
	var hold := TableCls.make_command("HOLD", TableCls.scope_all_friendly())
	_exec_result = {}
	_executor.set_external_busy(false)
	var acc: Dictionary = _executor.execute(hold, "", _side)
	_executor.set_external_busy(true, "%s Cloud phase in progress." % _SIDE())
	var rows: Array = []
	var failed: Array = []
	var status := "HOLD_ALL"
	if bool(acc.get("accepted", false)):
		var fin := await _wait_for_exec()
		rows = fin.get("executed_units", [])
		failed = fin.get("execution_failed", [])
	else:
		failed = [{"code": str(acc.get("code", "EXECUTOR_REFUSED")), "detail": str(acc.get("detail", ""))}]
	_prev_summary = {"turn": turn, "status": status, "order_count": 1,
		"executed_count": rows.size(), "rejected_count": 0,
		"note": "t%d: HOLD ALL fallback (%s), %d held." % [turn, reason, rows.size()]}
	_plan.note_result("t%d: HOLD ALL fallback (%s)." % [turn, reason])
	var record := {
		"timestamp": Time.get_datetime_string_from_system(),
		"battle_id": "cloud_step1_neutral_skirmish",
		"turn": turn, "attempt": 0, "acting_side": _SIDE(),
		"snapshot_id": "", "state_version": -1,
		"provider": _config.provider_id, "model": _config.model,
		"latency_ms": 0, "plan": {}, "rationale": {},
		"orders": [{"index": 1, "status": status, "order": hold, "executed": rows, "failed": failed}],
		"order_count": 1, "executed_count": rows.size(), "rejected_count": 0,
		"validation": {"ok": true, "code": "FALLBACK", "detail": reason},
		"executions": rows,
		"pre_fingerprint": "", "post_fingerprint": str(_bridge.fingerprint()),
		"status": status,
	}
	var logged := LoggerCls.log_turn(record)
	_last_view = {
		"model": _config.model, "provider": _config.provider_id, "turn": turn,
		"latency_ms": 0, "snapshot_id": "", "plan": {}, "orders": record["orders"],
		"order_count": 1, "executed_count": rows.size(), "rejected_count": 0,
		"post_fingerprint": str(_bridge.fingerprint()),
		"status": status, "log_path": str(logged.get("path", "")),
		"summary": "HOLD ALL fallback (%s)." % reason,
	}
	if not carry.is_empty():
		_last_view["failure"] = carry.get("failure", {})
		if not (carry.get("diag", {}) as Dictionary).is_empty():
			_last_view["diag"] = carry.get("diag", {})
		if not str(carry.get("head", "")).is_empty():
			_last_view["response_text_head"] = str(carry.get("head", ""))
		_last_view["summary"] = "HOLD ALL fallback (%s) after %s." % [reason,
			str((carry.get("failure", {}) as Dictionary).get("code", "?"))]
	_set_state(status, "HOLD ALL fallback done (%s)." % reason)
	TraceCls.set_stage("COMPLETE", "HOLD ALL fallback done (%s)." % reason)
	TraceCls.end_turn(status, "HOLD ALL fallback (%s)." % reason)
	return {"ok": true, "status": status, "turn": turn, "order_count": 1,
		"executed_count": rows.size(), "rejected_count": 0,
		"log_path": str(logged.get("path", "")), "summary": str(_last_view.get("summary", ""))}


# --- mission hierarchy ---------------------------------------------------

## MISSION_HIERARCHY RED phase: reconcile + mission controllers decide
## locally (zero network), orders execute through the shared sequential
## _execute_orders path, and the Cloud General is consulted ONLY for the
## initial plan (blocking, when configured) and event/periodic reviews
## (background). An unconfigured battle runs the deterministic local
## fallback plan instead of blocking on a decision.
func _run_hierarchy_inner() -> Dictionary:
	var attempt := 0
	while true:
		attempt += 1
		await _pause_point("Before RED observation freeze (hierarchy, attempt %d)." % attempt)
		var gate := SessionCls.resolve_for_use(_config)
		# EXTERNAL_AGENT / DEBUG_AGENT (DEV): the agent completes General requests
		# through structured submit calls ??no provider key exists or is required.
		var gate_ok := bool(gate.get("ok", false)) or _uses_agent_backend()
		if gate_ok:
			SessionCls.trace("%s_GATE_HIER" % _SIDE(), null, _config)
		else:
			print("[CloudTurn] HIER gate=%s ??local plan covers this turn; General review deferred." % str(gate.get("code", "")))
		_set_state("OBSERVING", "Freezing %s authorized observation (hierarchy, attempt %d)." % [_SIDE(), attempt])
		var pre_fp := str(_bridge.fingerprint())
		var obs := ObsCls.build(_bridge, _side)
		if not bool(obs.get("ok", false)):
			_set_state("FAILED_OBSERVATION", str(obs.get("error", "Observation unavailable.")), "observation")
			var dec_obs := await _wait_for_decision()
			if dec_obs == "skip":
				return _end_skipped("observation_failed")
			if dec_obs == "hold":
				return await _end_hold_all("observation_failed")
			continue
		var turn := int(obs.get("turn", 0))
		_state["turn"] = turn
		_last_obs = obs.duplicate(true)
		TraceCls.refresh_snapshot(str(obs.get("snapshot_id", "")),
			int((obs.get("parity", {}) as Dictionary).get("state_version", -1)), 0)
		# Safe transition: a staged background plan is adopted (or discarded
		# as stale) here at RED phase start ??never mid-turn, never blindly.
		_adopt_staged_if_fresh(obs, turn)
		# A REVIEW rejected while the human played is serviced at this safe
		# boundary. Never execute a fallback from a background callback.
		if not _utility_fallback_pending.is_empty() and _utility_fallback_enabled():
			return await _utility_fallback_run(turn)
		var used_llm := false
		var gen_latency := 0
		var event_review := {}
		var want_vp := _victory_mode and _control_mode == CONTROL_HIERARCHY
		var need_initial := (not _manager.vp_has_plan()) if want_vp else (not GeneralPlanCls.has_plan(_manager.get_plan()))
		if need_initial and want_vp and GeneralPlanCls.has_plan(_manager.get_plan()):
			var adopted := _manager.vp_adopt_legacy(turn, "Victory mode with a live legacy plan.")
			if bool(adopted.get("ok", false)):
				need_initial = false
				print("[CloudTurn] VICTORY legacy plan adopted as single-phase VP v1.")
		if need_initial:
			if gate_ok:
				_set_state("THINKING", "General drafting initial plan (turn %d)." % turn)
				TraceCls.set_stage("GENERAL_PLANNING", "Initial strategic plan (turn %d)." % turn)
				var gen := await _general_review_blocking(obs, {"trigger": "INITIAL_PLAN", "reason": "No strategic plan exists.", "turn": turn}, turn)
				if not bool(gen.get("ok", false)):
					# STRICT: a latched Brain-contract fault ends the phase
					# immediately: no RETRY/SKIP/HOLD decision, no fallback
					# plan substitution, no execution. The match layer
					# finalizes the authoritative terminal LOSS.
					if not _strict_fault.is_empty():
						return _strict_failure_result(turn)
					if not _utility_fallback_pending.is_empty() and _utility_fallback_enabled():
						return await _utility_fallback_run(turn)
					var gcode := str(gen.get("code", "GENERAL_ERROR"))
					_set_state("FAILED_" + gcode, str(gen.get("detail", "")), "general_plan")
					_last_view = _failure_view(obs, turn, pre_fp, gcode, str(gen.get("detail", "")), int(gen.get("latency_ms", 0)))
					var dec_g := await _wait_for_decision()
					if dec_g == "skip":
						return _end_skipped("general_failed:" + gcode)
					if dec_g == "hold":
						return await _end_hold_all("general_failed:" + gcode)
					continue
				used_llm = true
				gen_latency = int(gen.get("latency_ms", 0))
			else:
				print("[CloudTurn] HIER no plan + unconfigured ??deterministic local fallback covers turn %d." % turn)
		# Significant BLUE->RED combat was buffered without blocking any combat
		# action. At this single phase-boundary window, review the frozen batch,
		# pass it through KEEP/ADJUST/REPLAN, then run the staleness gate before
		# any RED MissionController decision executes.
		if _manager.vp_has_plan() or GeneralPlanCls.has_plan(_manager.get_plan()):
			var wake_service: Dictionary = await _service_event_review_before_red(obs, turn, gate_ok)
			obs = (wake_service.get("obs", obs) as Dictionary).duplicate(true)
			_last_obs = obs.duplicate(true)
			event_review = (wake_service.get("review", {}) as Dictionary).duplicate(true)
			used_llm = used_llm or bool(wake_service.get("called", false))
			# STRICT: a review rejected at the safe window ends the phase
			# before any mission decision executes (no fallback execution).
			if not _strict_fault.is_empty():
				return _strict_failure_result(turn)
			if not _utility_fallback_pending.is_empty() and _utility_fallback_enabled():
				return await _utility_fallback_run(turn)
		_set_state("PLANNING", "Mission controllers deciding (turn %d)." % turn)
		TraceCls.set_stage("MISSION_CONTROL", "Mission controllers deciding (turn %d)." % turn)
		await _pause_point("Before mission controller decisions (turn %d)." % turn)
		var decided: Dictionary = _manager.side_turn(_bridge, obs)
		if _force_review:
			_force_review = false
			decided["review"] = {"requested": true, "trigger": "MANUAL", "reason": "Manual review requested."}
		var checked: Array = []
		for o_val in (decided.get("orders", []) as Array):
			checked.append(ResponseCls.check_order((o_val as Dictionary).get("order", {}), {"acting_side": _SIDE()}))
		var hier_parsed := {"ok": true, "code": "", "detail": "",
			"acting_side": _SIDE(), "stale_snapshot": false,
			"plan": ResponseCls.default_plan(), "rationale": ResponseCls.default_rationale(),
			"orders": checked, "order_count": checked.size()}
		var hier_model := {"latency_ms": gen_latency, "mock": bool(_adapter.get("mock_mode"))}
		var hier_mids: Array = []
		for o_val in (decided.get("orders", []) as Array):
			hier_mids.append(str((o_val as Dictionary).get("mission_id", "?")))
		var out := await _execute_orders(obs, {"packet_version": "hierarchy_v1"}, hier_parsed, hier_model, pre_fp, turn, attempt, 0)
		# _execute_orders runs sequentially in input order: annotate each view
		# with its mission so the Lab can show per-mission execution results.
		var lv_orders: Array = _last_view.get("orders", [])
		for i in range(mini(hier_mids.size(), lv_orders.size())):
			(lv_orders[i] as Dictionary)["mission_id"] = hier_mids[i]
		# Post-turn: statuses, telemetry, and (when requested) a background
		# General review that resolves during the coming human turn.
		var acted: Array = []
		for ov_val in ((_last_view.get("orders", []) as Array)):
			for e_val in ((ov_val as Dictionary).get("executed", []) as Array):
				if e_val is Dictionary:
					acted.append(e_val)
		_manager.post_turn(acted, turn)
		GeneralTraceCls.note_side_turn(_side, used_llm, int(decided.get("decisions", 0)))
		_hier_last = {"turn": turn, "statuses": _manager.status_rows(),
			"traces": decided.get("traces", []), "review": decided.get("review", {}),
			"event_review": event_review, "wakeup": _manager.wakeup_view(),
			"corrections": decided.get("corrections", [])}
		var review: Dictionary = decided.get("review", {})
		if bool(review.get("requested", false)):
			var review_window := "%s#%d" % [str(obs.get("battle_id", "")), turn]
			if review_window_already_serviced(_last_event_review_window, review_window):
				print("[CloudTurn] HIER review %s already serviced in safe window %s; not refiring." % [str(review.get("trigger", "")), review_window])
			elif not _staged_plan.is_empty() or not _staged_vp.is_empty() or not _review_in_flight.is_empty():
				print("[CloudTurn] HIER review %s already pending (staged/in-flight); not refiring." % str(review.get("trigger", "")))
			elif not gate_ok:
				print("[CloudTurn] HIER review %s deferred (unconfigured)." % str(review.get("trigger", "")))
			else:
				var post_obs := ObsCls.build(_bridge, _side)
				_fire_background_review(post_obs if bool(post_obs.get("ok", false)) else obs, review)
		out["hierarchy"] = true
		out["general"] = {"used_llm": used_llm, "latency_ms": gen_latency,
			"review": review, "telemetry": GeneralTraceCls.snapshot()}
		return out
	# Unreachable: the attempt loop only exits via return.
	return {"ok": false, "code": "UNREACHABLE", "detail": "Unreachable."}


## DEV Model View: bounded history of General requests (newest last).
## Each entry freezes the request half at send time and the response half
## at receipt time; entries are append-only and deep-copied on read.
func get_general_history() -> Array:
	return _general_history.duplicate(true)


## DEV Model View: the currently in-flight General request ({} when idle).
func get_general_flight() -> Dictionary:
	return _general_flight.duplicate(true)


## Freeze the request half of a General snapshot. The canonical source is
## the exact review packet handed to the adapter plus the system prompt ??## the same bytes the model call is built from, never a re-render.
func _general_snap_request(req_id: String, attempt: int, parent_id: String,
		trigger: Dictionary, turn: int, obs: Dictionary, packet: Dictionary, menu: Dictionary = {}, coord_kind: String = "", system_prompt: String = "") -> Dictionary:
	var sys := system_prompt if not system_prompt.is_empty() else GeneralPacketCls.general_prompt_for(_side)
	var req_text := JSON.stringify({"system_prompt": sys, "packet": packet})
	var packet_plan: Dictionary = packet.get("current_plan", {})
	var event_rows: Array = (packet.get("events_since_review", []) as Array).duplicate(true)
	return {
		"request_id": req_id,
		"kind": "GENERAL_REVIEW",
		"attempt": attempt,
		"parent_request_id": parent_id,
		"trigger": str(trigger.get("trigger", "?")),
		"reason": str(trigger.get("reason", "")),
		"review_type": str(packet.get("request", packet.get("review", ""))),
		"trigger_events": event_rows,
		"event_count": event_rows.size(),
		"current_plan_version": int(packet_plan.get("plan_version", 0)),
		"current_group_assignments": (packet.get("baseline_choices", {}) as Dictionary).duplicate(true),
		"turn": turn,
		"side": _SIDE(),
		"snapshot_id": str(obs.get("snapshot_id", "")),
		"battle_id": str(obs.get("battle_id", "")),
		"provider": _config.provider_id if _config != null else "",
		"model": _config.model if _config != null else "",
		"max_tokens": GENERAL_MAX_TOKENS,
		"timeout_sec": int(brain_timeout_sec()),
		"started_ms": Time.get_ticks_msec(),
		"ended_ms": 0,
		"request_text": req_text,
		"request_chars": req_text.length(),
		"system_chars": sys.length(),
		"packet_chars": JSON.stringify(packet).length(),
		"menu": menu.duplicate(true),
		"menu_chars": JSON.stringify(menu).length(),
		"coord_kind": coord_kind,
		"selection": {},
		"expansion": {},
		"warnings": [],
		"response_text": "",
		"response_chars": 0,
		"http_status": 0,
		"latency_ms": 0,
		"finish_reason": "",
		"reasoning_present": false,
		"reasoning_chars": 0,
		"ok": false,
		"code": "",
		"detail": "",
		"outcome": "IN_FLIGHT",
		"pipeline": {"transport": "PENDING", "parse": "PENDING", "contract": "PENDING", "plan": "PENDING", "adoption": "PENDING"},
		"parser_input_chars": 0,
		"parser_input_match": false,
	}


## Freeze the response half of a General snapshot from the adapter result.
## Records transport facts only; the caller owns the final outcome label and
## the post-transport pipeline stages (parse/plan/adoption). Reasoning metadata
## is lengths/presence only ??the working text is never retained.
func _general_snap_response(snap: Dictionary, model_res: Dictionary) -> void:
	var body := str(model_res.get("content_text", ""))
	var env: Dictionary = model_res.get("envelope", {}) as Dictionary
	snap["response_text"] = body
	snap["response_chars"] = body.length()
	snap["http_status"] = int(model_res.get("http_status", 0))
	snap["latency_ms"] = int(model_res.get("latency_ms", 0))
	snap["finish_reason"] = str(model_res.get("finish_reason", env.get("finish_reason", "")))
	snap["reasoning_present"] = bool(env.get("reasoning_present", false))
	snap["reasoning_chars"] = int(env.get("reasoning_chars", 0))
	snap["ok"] = bool(model_res.get("ok", false))
	snap["code"] = str(model_res.get("code", ""))
	snap["detail"] = str(model_res.get("detail", "")).left(500)
	snap["ended_ms"] = Time.get_ticks_msec()
	var pipe: Dictionary = snap.get("pipeline", {})
	pipe["transport"] = "SUCCESS" if bool(model_res.get("ok", false)) \
		else "FAILED_" + str(model_res.get("code", "PROVIDER_ERROR"))
	snap["pipeline"] = pipe


func _set_flight(snap: Dictionary) -> void:
	if not _general_flight.is_empty() \
		and str(_general_flight.get("request_id", "")) != str(snap.get("request_id", "")):
		_general_flight["outcome"] = "SUPERSEDED"
		_general_flight["ended_ms"] = Time.get_ticks_msec()
		_general_history_append(_general_flight)
	_general_flight = snap


func _clear_flight(req_id: String) -> void:
	if str(_general_flight.get("request_id", "")) == req_id:
		_general_flight = {}


## Append-only history with a hard cap (oldest evicted first). Entries are
## scrubbed for secret-shaped keys before retention: packets carry no
## secrets by construction, but the View must never be the leak path.
func _general_history_append(snap: Dictionary) -> void:
	if snap.is_empty():
		return
	var entry: Dictionary = (snap.duplicate(true) as Dictionary)
	_scrub_secrets(entry)
	_general_history.append(entry)
	while _general_history.size() > GENERAL_HISTORY_MAX:
		_general_history.pop_front()
	_clear_flight(str(entry.get("request_id", "")))
	_persist_general_response(entry)


## Repair V1 forensics: every General attempt's raw reply lands on disk
## (bounded), so the next malformed response is diagnosable post-hoc.
func _persist_general_response(entry: Dictionary) -> void:
	var bid := str(entry.get("battle_id", ""))
	if bid.is_empty():
		return
	BattleMemoryCls.append_general_response(bid, {
		"req": str(entry.get("request_id", "?")),
		"turn": int(entry.get("turn", 0)),
		"kind": "%s/%s" % [str(entry.get("kind", "?")), str(entry.get("review_type", ""))],
		"http": int(entry.get("http_status", 0)),
		"latency_ms": int(entry.get("latency_ms", 0)),
		"finish": str(entry.get("finish_reason", "")),
		"final_chars": int(entry.get("response_chars", 0)),
		"reasoning_present": bool(entry.get("reasoning_present", false)),
		"reasoning_chars": int(entry.get("reasoning_chars", 0)),
		"usage": {},
		"outcome": str(entry.get("outcome", "?")),
		"budget": int(entry.get("max_tokens", 0)),
		"text": str(entry.get("response_text", "")),
	})


func _scrub_secrets(v: Variant) -> void:
	if v is Dictionary:
		var d: Dictionary = v
		for k in d.keys():
			var ks := str(k).to_lower()
			if ks.contains("api_key") or ks == "apikey" or ks.contains("secret") \
				or ks == "authorization" or ks == "bearer":
				d[k] = "<redacted>"
			else:
				_scrub_secrets(d[k])
	elif v is Array:
		for e_val in (v as Array):
			_scrub_secrets(e_val)


## Forensic pipeline helpers (General path only). _general_pipe_stage records
## one post-transport stage on the interaction snapshot; _general_note_attempt
## publishes the attempt's metadata-only outcome to the turn trace record.
## Neither helper ever sees model text or reasoning bodies ??sizes and codes.
func _general_pipe_stage(snap: Dictionary, stage: String, value: String) -> void:
	var pipe: Dictionary = snap.get("pipeline", {})
	pipe[stage] = value
	snap["pipeline"] = pipe


func _general_note_attempt(snap: Dictionary, outcome: String, code: String, detail: String, plan_version: int = 0, missions: int = 0) -> void:
	snap["outcome"] = outcome
	TraceCls.set_general_outcome({
		"attempt": int(snap.get("attempt", 0)),
		"request_id": str(snap.get("request_id", "")),
		"outcome": outcome,
		"code": code,
		"detail": detail,
		"response_chars": int(snap.get("response_chars", 0)),
		"http_status": int(snap.get("http_status", 0)),
		"finish_reason": str(snap.get("finish_reason", "")),
		"plan_version": plan_version,
		"missions": missions,
	})


## Parse one coordinator final response through the PRODUCTION parser and
## freeze the pipeline stages on the snapshot. Parser input is always the
## exact extracted content_text ??the same string _general_snap_response
## froze as response_text (parser_input_match proves it per attempt). Stages:
## parse = JSON extraction; contract = coordinator schema/menu validation;
## plan = Godot expansion (set by the caller afterwards). No validation logic
## is duplicated here; the production call is unchanged.
func _coord_parse_initial(model_res: Dictionary, snap: Dictionary, menu: Dictionary, turn: int, snapshot: String) -> Dictionary:
	var final_text := str(model_res.get("content_text", ""))
	snap["parser_input_chars"] = final_text.length()
	snap["parser_input_match"] = final_text == str(snap.get("response_text", ""))
	var parsed := CoordResponseCls.parse_initial(final_text,
		{"menu": menu, "snapshot_id": snapshot, "turn": turn})
	var pcode := str(parsed.get("code", "COORD_INVALID_SCHEMA"))
	if not bool(parsed.get("json_ok", false)):
		_general_pipe_stage(snap, "parse", "FAIL_" + pcode)
		_general_pipe_stage(snap, "contract", "UNREACHED")
		_general_pipe_stage(snap, "plan", "UNREACHED")
	elif not bool(parsed.get("ok", false)):
		_general_pipe_stage(snap, "parse", "PASS")
		_general_pipe_stage(snap, "contract", "FAIL_" + pcode)
		_general_pipe_stage(snap, "plan", "UNREACHED")
	else:
		_general_pipe_stage(snap, "parse", "PASS")
		_general_pipe_stage(snap, "contract", "PASS")
		_general_pipe_stage(snap, "plan", "PENDING")
		snap["selection"] = (parsed.get("selection", {}) as Dictionary).duplicate(true)
		snap["warnings"] = (parsed.get("warnings", []) as Array).duplicate(true)
	return parsed


## Blocking INITIAL_COORDINATION through the EXISTING Cloud transport (same
## adapter, session gate, key handling, and retry policy as tactical turns).
## Godot builds the coordination menu first; the Cloud only selects IDs from
## it, and Godot expands the selection into the canonical StrategicPlan.
func _general_review_blocking(obs: Dictionary, trigger: Dictionary, turn: int) -> Dictionary:
	_review_in_flight = "" # a blocking call supersedes any background flight
	if _victory_mode and _control_mode == CONTROL_HIERARCHY:
		return await _victory_review_blocking(obs, trigger, turn)
	_agent_parked = {} # a superseded background park can never be completed
	_general_result = {}
	var menu := _manager.build_coord_menu(obs)
	if (menu.get("groups", []) as Array).is_empty():
		print("[CloudTurn] GENERAL_PIPELINE attempt=0 01_REQUEST_BUILT COORD_EMPTY_MENU (no listed formations; no Cloud call)")
		return {"ok": false, "code": "COORD_EMPTY_MENU",
			"detail": "No force groups to coordinate; nothing was sent.", "latency_ms": 0}
	var packet := GeneralPacketCls.build_coord_initial(obs, menu)
	_last_general_packet = packet.duplicate(true)
	var req_id := "%st%d_%d" % [GENERAL_REQUEST_PREFIX, turn, _turn_seq]
	var snap := _general_snap_request(req_id, 1, "", trigger, turn, obs, packet, menu, "INITIAL", CoordResponseCls.COORDINATOR_SYSTEM_PROMPT)
	TraceCls.begin_attempt(1, GENERAL_MAX_TOKENS, req_id)
	TraceCls.refresh_snapshot(str(obs.get("snapshot_id", "")),
		int((obs.get("parity", {}) as Dictionary).get("state_version", -1)),
		int(snap.get("request_chars", 0)), int(snap.get("system_chars", 0)))
	print("[CloudTurn] GENERAL_REQUEST_START trigger=%s turn=%d req=%s packet_chars=%d timeout=%ds" % [
		str(trigger.get("trigger", "?")), turn, req_id, int(snap.get("request_chars", 0)), int(brain_timeout_sec())])
	print("[CloudTurn] GENERAL_PIPELINE attempt=1 01_REQUEST_BUILT request_chars=%d system_chars=%d packet_chars=%d menu_chars=%d groups=%d" % [
		int(snap.get("request_chars", 0)), int(snap.get("system_chars", 0)), int(snap.get("packet_chars", 0)),
		int(snap.get("menu_chars", 0)), (menu.get("groups", []) as Array).size()])
	_set_flight(snap)
	var started: Dictionary
	if _uses_agent_backend():
		started = agent_park_request("INITIAL", packet, menu, req_id, CoordResponseCls.COORDINATOR_SYSTEM_PROMPT, turn)
	else:
		started = _adapter.request_turn(req_id, packet, _config, CoordResponseCls.COORDINATOR_SYSTEM_PROMPT, GENERAL_MAX_TOKENS, brain_timeout_sec())
	if not bool(started.get("ok", false)):
		_clear_flight(req_id)
		_general_pipe_stage(snap, "transport", "START_FAILED_" + str(started.get("code", "REQUEST_FAILED")))
		_general_note_attempt(snap, "START_FAILED_" + str(started.get("code", "REQUEST_FAILED")),
			str(started.get("code", "REQUEST_FAILED")), str(started.get("detail", "")))
		snap["ended_ms"] = Time.get_ticks_msec()
		_general_history_append(snap)
		print("[CloudTurn] GENERAL_RESPONSE_ERROR: %s ??%s" % [
			str(started.get("code", "REQUEST_FAILED")), str(started.get("detail", "")).left(200)])
		print("[CloudTurn] GENERAL_PIPELINE attempt=1 11_CONTROLLER_TRANSITION FAILED_%s" % str(started.get("code", "REQUEST_FAILED")))
		return {"ok": false, "code": str(started.get("code", "REQUEST_FAILED")),
			"detail": str(started.get("detail", "")), "latency_ms": 0}
	var model_res := await _wait_for_general(req_id)
	_clear_flight(req_id)
	_general_snap_response(snap, model_res)
	var latency := int(model_res.get("latency_ms", 0))
	TraceCls.finish_attempt(model_res)
	GeneralTraceCls.note_general_call(latency, str(trigger.get("trigger", "")), turn)
	print("[CloudTurn] GENERAL_HTTP_STATUS=%s latency=%dms ok=%s" % [
		str(model_res.get("http_status", "?")), latency, str(bool(model_res.get("ok", false)))])
	print("[CloudTurn] GENERAL_RESPONSE_RECEIVED ok=%s chars=%d latency=%dms finish=%s http=%s" % [
		str(bool(model_res.get("ok", false))), str(model_res.get("content_text", "")).length(),
		latency, str(model_res.get("finish_reason", "-")), str(model_res.get("http_status", "?"))])
	print("[CloudTurn] GENERAL_PIPELINE attempt=1 02_HTTP_RESPONSE status=%s 03_ENVELOPE_EXTRACT ok=%s final_chars=%d finish=%s reasoning=%s(%d)" % [
		str(model_res.get("http_status", "?")), str(bool(model_res.get("ok", false))),
		str(model_res.get("content_text", "")).length(), str(model_res.get("finish_reason", "-")),
		"present" if bool((model_res.get("envelope", {}) as Dictionary).get("reasoning_present", false)) else "none",
		int((model_res.get("envelope", {}) as Dictionary).get("reasoning_chars", 0))])
	if not bool(model_res.get("ok", false)):
		GeneralTraceCls.note_general_disposition("REJECTED", 0, "", str(model_res.get("code", "PROVIDER_ERROR")))
		_general_note_attempt(snap, "FAILED_" + str(model_res.get("code", "PROVIDER_ERROR")),
			str(model_res.get("code", "PROVIDER_ERROR")), str(model_res.get("detail", "")))
		_general_history_append(snap)
		print("[CloudTurn] GENERAL_RESPONSE_ERROR: %s ??%s" % [
			str(model_res.get("code", "PROVIDER_ERROR")), str(model_res.get("detail", "")).left(200)])
		print("[CloudTurn] GENERAL_PIPELINE attempt=1 11_CONTROLLER_TRANSITION FAILED_%s" % str(model_res.get("code", "PROVIDER_ERROR")))
		return {"ok": false, "code": str(model_res.get("code", "PROVIDER_ERROR")),
			"detail": str(model_res.get("detail", "")), "latency_ms": latency}
	var parsed := _coord_parse_initial(model_res, snap, menu, turn, str(obs.get("snapshot_id", "")))
	var pipe1: Dictionary = snap.get("pipeline", {})
	print("[CloudTurn] GENERAL_PIPELINE attempt=1 04_TEXT_RECEIVED chars=%d match=%s 05_PARSE %s 06_CONTRACT %s" % [
		int(snap.get("parser_input_chars", 0)), str(bool(snap.get("parser_input_match", false))),
		str(pipe1.get("parse", "?")), str(pipe1.get("contract", "?"))])
	var schema_retries := 0
	var cur := snap
	# STRICT: no schema-repair retry; the first rejection below latches.
	while not bool(parsed.get("ok", false)) and schema_retries < GENERAL_MAX_SCHEMA_RETRY \
		and str(parsed.get("code", "")) != "COORD_STALE_SNAPSHOT" and not _strict_enabled() and not _utility_fallback_enabled():
		schema_retries += 1
		print("[CloudTurn] GENERAL_SCHEMA_RETRY %s (attempt %d, same snapshot)" % [
			str(parsed.get("code", "")), schema_retries])
		print("[CloudTurn] GENERAL_PIPELINE attempt=%d 07_RETRY_TRIGGER code=%s detail=%s" % [
			schema_retries, str(parsed.get("code", "")), str(parsed.get("detail", "")).left(160)])
		_set_state("THINKING", "Coordinator correcting rejected selection (%s)." % str(parsed.get("code", "")))
		_general_note_attempt(cur, "SCHEMA_REJECT_" + str(parsed.get("code", "COORD_INVALID_SCHEMA")),
			str(parsed.get("code", "COORD_INVALID_SCHEMA")), str(parsed.get("detail", "")))
		_general_history_append(cur)
		var packet2 := packet.duplicate(true)
		packet2["rejection_feedback"] = "%s: %s Use only the supplied group/choice IDs; reply with corrected JSON only." % [
			str(parsed.get("code", "")), str(parsed.get("detail", ""))]
		var retry_id := "%s_r%d" % [req_id, schema_retries]
		cur = _general_snap_request(retry_id, 1 + schema_retries, req_id, trigger, turn, obs, packet2, menu, "INITIAL", CoordResponseCls.COORDINATOR_SYSTEM_PROMPT)
		TraceCls.begin_attempt(1 + schema_retries, GENERAL_MAX_TOKENS, retry_id)
		TraceCls.refresh_snapshot(str(obs.get("snapshot_id", "")),
			int((obs.get("parity", {}) as Dictionary).get("state_version", -1)),
			int(cur.get("request_chars", 0)), int(cur.get("system_chars", 0)))
		print("[CloudTurn] GENERAL_PIPELINE attempt=%d 01_REQUEST_BUILT request_chars=%d system_chars=%d packet_chars=%d (schema retry, same snapshot)" % [
			1 + schema_retries, int(cur.get("request_chars", 0)), int(cur.get("system_chars", 0)), int(cur.get("packet_chars", 0))])
		_general_result = {}
		_set_flight(cur)
		var restarted := _adapter.request_turn(retry_id, packet2, _config, CoordResponseCls.COORDINATOR_SYSTEM_PROMPT, GENERAL_MAX_TOKENS, brain_timeout_sec())
		if not bool(restarted.get("ok", false)):
			_clear_flight(retry_id)
			_general_pipe_stage(cur, "transport", "START_FAILED_" + str(restarted.get("code", "REQUEST_FAILED")))
			_general_note_attempt(cur, "START_FAILED_" + str(restarted.get("code", "REQUEST_FAILED")),
				str(restarted.get("code", "REQUEST_FAILED")), str(restarted.get("detail", "")))
			cur["ended_ms"] = Time.get_ticks_msec()
			_general_history_append(cur)
			GeneralTraceCls.note_general_disposition("REJECTED", 0, "", str(restarted.get("code", "REQUEST_FAILED")))
			print("[CloudTurn] GENERAL_PIPELINE attempt=%d 11_CONTROLLER_TRANSITION FAILED_%s" % [
				1 + schema_retries, str(restarted.get("code", "REQUEST_FAILED"))])
			return {"ok": false, "code": str(restarted.get("code", "REQUEST_FAILED")),
				"detail": str(restarted.get("detail", "")), "latency_ms": latency}
		model_res = await _wait_for_general(retry_id)
		_clear_flight(retry_id)
		_general_snap_response(cur, model_res)
		latency += int(model_res.get("latency_ms", 0))
		TraceCls.finish_attempt(model_res)
		GeneralTraceCls.note_general_call(int(model_res.get("latency_ms", 0)), str(trigger.get("trigger", "")) + "_RETRY", turn)
		print("[CloudTurn] GENERAL_PIPELINE attempt=%d 02_HTTP_RESPONSE status=%s 03_ENVELOPE_EXTRACT ok=%s final_chars=%d finish=%s reasoning=%s(%d)" % [
			1 + schema_retries, str(model_res.get("http_status", "?")), str(bool(model_res.get("ok", false))),
			str(model_res.get("content_text", "")).length(), str(model_res.get("finish_reason", "-")),
			"present" if bool((model_res.get("envelope", {}) as Dictionary).get("reasoning_present", false)) else "none",
			int((model_res.get("envelope", {}) as Dictionary).get("reasoning_chars", 0))])
		if not bool(model_res.get("ok", false)):
			_general_note_attempt(cur, "FAILED_" + str(model_res.get("code", "PROVIDER_ERROR")),
				str(model_res.get("code", "PROVIDER_ERROR")), str(model_res.get("detail", "")))
			_general_history_append(cur)
			GeneralTraceCls.note_general_disposition("REJECTED", 0, "", str(model_res.get("code", "PROVIDER_ERROR")))
			print("[CloudTurn] GENERAL_PIPELINE attempt=%d 11_CONTROLLER_TRANSITION FAILED_%s" % [
				1 + schema_retries, str(model_res.get("code", "PROVIDER_ERROR"))])
			return {"ok": false, "code": str(model_res.get("code", "PROVIDER_ERROR")),
				"detail": str(model_res.get("detail", "")), "latency_ms": latency}
		parsed = _coord_parse_initial(model_res, cur, menu, turn, str(obs.get("snapshot_id", "")))
		var pipe_r: Dictionary = cur.get("pipeline", {})
		print("[CloudTurn] GENERAL_PIPELINE attempt=%d 04_TEXT_RECEIVED chars=%d match=%s 05_PARSE %s 06_CONTRACT %s" % [
			1 + schema_retries, int(cur.get("parser_input_chars", 0)), str(bool(cur.get("parser_input_match", false))),
			str(pipe_r.get("parse", "?")), str(pipe_r.get("contract", "?"))])
	if not bool(parsed.get("ok", false)):
		_strict_latch("INITIAL", str(parsed.get("code", "COORD_INVALID_SCHEMA")), str(parsed.get("detail", "")), turn, str(cur.get("request_id", "")))
		GeneralTraceCls.note_general_disposition("REJECTED", 0, "", str(parsed.get("code", "COORD_INVALID_SCHEMA")))
		_general_note_attempt(cur, "REJECTED_" + str(parsed.get("code", "COORD_INVALID_SCHEMA")),
			str(parsed.get("code", "COORD_INVALID_SCHEMA")), str(parsed.get("detail", "")))
		_general_history_append(cur)
		print("[CloudTurn] GENERAL_RESPONSE_ERROR: %s ??%s" % [
			str(parsed.get("code", "COORD_INVALID_SCHEMA")), str(parsed.get("detail", "")).left(200)])
		print("[CloudTurn] GENERAL_PIPELINE attempt=%d 09_SNAPSHOT_GATE %s 11_CONTROLLER_TRANSITION FAILED_%s" % [
			1 + schema_retries, "FAIL_COORD_STALE_SNAPSHOT" if str(parsed.get("code", "")) == "COORD_STALE_SNAPSHOT" else "PASS",
			str(parsed.get("code", "COORD_INVALID_SCHEMA"))])
		_utility_fallback_note("INITIAL", str(parsed.get("code", "COORD_INVALID_SCHEMA")), str(parsed.get("detail", "")), turn)
		return {"ok": false, "code": str(parsed.get("code", "COORD_INVALID_SCHEMA")),
			"detail": str(parsed.get("detail", "")), "latency_ms": latency}
	var expanded := CoordMenuCls.expand_initial(menu, parsed.get("selection", {}), turn,
		str(obs.get("snapshot_id", "")), obs.get("mission", {}), parsed.get("warnings", []))
	if not bool(expanded.get("ok", false)):
		_strict_latch("INITIAL", str(expanded.get("code", "COORD_EXPAND_INVALID")), str(expanded.get("detail", "")), turn, str(cur.get("request_id", "")))
		_general_pipe_stage(cur, "plan", "FAIL_" + str(expanded.get("code", "COORD_EXPAND_INVALID")))
		GeneralTraceCls.note_general_disposition("REJECTED", 0, "", str(expanded.get("code", "COORD_EXPAND_INVALID")))
		_general_note_attempt(cur, "EXPAND_FAIL_" + str(expanded.get("code", "COORD_EXPAND_INVALID")),
			str(expanded.get("code", "COORD_EXPAND_INVALID")), str(expanded.get("detail", "")))
		_general_history_append(cur)
		print("[CloudTurn] GENERAL_RESPONSE_ERROR: %s ??%s" % [
			str(expanded.get("code", "COORD_EXPAND_INVALID")), str(expanded.get("detail", "")).left(200)])
		print("[CloudTurn] GENERAL_PIPELINE attempt=%d 08_EXPANSION FAIL_%s 11_CONTROLLER_TRANSITION FAILED_%s" % [
			1 + schema_retries, str(expanded.get("code", "COORD_EXPAND_INVALID")), str(expanded.get("code", "COORD_EXPAND_INVALID"))])
		_utility_fallback_note("INITIAL", str(expanded.get("code", "COORD_EXPAND_INVALID")), str(expanded.get("detail", "")), turn)
		return {"ok": false, "code": str(expanded.get("code", "COORD_EXPAND_INVALID")),
			"detail": str(expanded.get("detail", "")), "latency_ms": latency}
	_general_pipe_stage(cur, "plan", "PASS_missions=%d" % ((expanded.get("missions", []) as Array).size()))
	cur["expansion"] = {"choices": (expanded.get("choices", {}) as Dictionary).duplicate(true),
		"missions": (expanded.get("missions", []) as Array).duplicate(true)}
	cur["warnings"] = (expanded.get("warnings", []) as Array).duplicate(true)
	print("[CloudTurn] GENERAL_PLAN_VALID v%d missions=%d warnings=%d (%s)" % [
		int((expanded.get("plan", {}) as Dictionary).get("plan_version", 0)),
		((expanded.get("plan", {}) as Dictionary).get("missions", []) as Array).size(),
		(expanded.get("warnings", []) as Array).size(), CoordMenuCls.render_choices_text(expanded.get("choices", {}))])
	# Hierarchy observability: the coordinator's validated selection expands
	# into the turn's decision trace (mission controllers decide locally and
	# produce no model text). Same final text that was just parsed ??never
	# reasoning text.
	TraceCls.set_decision({"plan": (expanded.get("plan", {}) as Dictionary).duplicate(true),
		"rationale": {}, "source": "GENERAL"}, str(model_res.get("content_text", "")))
	var applied := _manager.apply_plan(expanded.get("plan", {}), turn, str(obs.get("snapshot_id", "")),
		str(obs.get("battle_id", "")))
	if not bool(applied.get("ok", false)):
		_strict_latch("INITIAL", str(applied.get("code", "PLAN_INVALID")), str(applied.get("detail", "")), turn, str(cur.get("request_id", "")))
		GeneralTraceCls.note_general_disposition("REJECTED", 0, "", str(applied.get("code", "PLAN_INVALID")))
		_general_pipe_stage(cur, "adoption", "DENIED_" + str(applied.get("code", "PLAN_INVALID")))
		_general_note_attempt(cur, "DENIED_" + str(applied.get("code", "PLAN_INVALID")),
			str(applied.get("code", "PLAN_INVALID")), str(applied.get("detail", "")),
			int((expanded.get("plan", {}) as Dictionary).get("plan_version", 0)),
			((expanded.get("plan", {}) as Dictionary).get("missions", []) as Array).size())
		_general_history_append(cur)
		print("[CloudTurn] GENERAL_RESPONSE_ERROR: %s ??%s" % [
			str(applied.get("code", "PLAN_INVALID")), str(applied.get("detail", "")).left(200)])
		print("[CloudTurn] GENERAL_PIPELINE attempt=%d 09_SNAPSHOT_GATE PASS 10_PLAN_ADOPTION DENIED_%s 11_CONTROLLER_TRANSITION FAILED_%s" % [
			1 + schema_retries, str(applied.get("code", "PLAN_INVALID")), str(applied.get("code", "PLAN_INVALID"))])
		_utility_fallback_note("INITIAL", str(applied.get("code", "PLAN_INVALID")), str(applied.get("detail", "")), turn)
		return {"ok": false, "code": str(applied.get("code", "PLAN_INVALID")),
			"detail": str(applied.get("detail", "")), "latency_ms": latency}
	GeneralTraceCls.note_general_disposition("APPLIED", int(applied.get("version", 0)), str(obs.get("snapshot_id", "")))
	_general_pipe_stage(cur, "adoption", "APPLIED_v%d" % int(applied.get("version", 0)))
	_manager.bind_coordination({"choices": (expanded.get("choices", {}) as Dictionary).duplicate(true),
		"menu_snapshot": str(menu.get("snapshot_id", "")), "turn": turn,
		"warnings": (expanded.get("warnings", []) as Array).duplicate(true)})
	_general_note_attempt(cur, "APPLIED_v%d" % int(applied.get("version", 0)), "",
		"", int(applied.get("version", 0)), ((_manager.get_plan().get("missions", []) as Array).size()))
	_general_history_append(cur)
	print("[CloudTurn] GENERAL_PLAN_ADOPTED v%d missions=%d" % [
		int(applied.get("version", 0)), ((_manager.get_plan().get("missions", []) as Array).size())])
	print("[CloudTurn] GENERAL_PIPELINE attempt=%d 09_SNAPSHOT_GATE PASS 10_PLAN_ADOPTION APPLIED_v%d missions=%d 11_CONTROLLER_TRANSITION GENERAL_READY" % [
		1 + schema_retries, int(applied.get("version", 0)), ((_manager.get_plan().get("missions", []) as Array).size())])
	return {"ok": true, "code": "", "detail": "", "latency_ms": latency, "version": int(applied.get("version", 0))}


## VICTORY PLAN V0 (additive): blocking General call, latched (live API
## repair V1). INITIAL (no plan): exactly one generation sequence per
## battle ??REQUESTING/RETRYING attaches to the in-flight request, READY
## consumes the prefetched plan with zero new calls, FAILED returns
## visibly without new calls, NOT_STARTED begins the sequence now. Forced
## blocking reviews (a plan already exists) commit immediately.
func _victory_review_blocking(obs: Dictionary, trigger: Dictionary, turn: int) -> Dictionary:
	if _manager.vp_has_plan():
		return await _victory_blocking_review(obs, trigger, turn)
	if _vp_init_state == VP_INIT_READY:
		return victory_consume_initial(obs, turn)
	if _vp_init_state == VP_INIT_FAILED:
		print("[CloudTurn] VICTORY_INITIAL_LATCHED_FAILED error=%s (no new calls; RETRY PLAN re-arms)" % _vp_init_error)
		return {"ok": false, "code": "VP_INITIAL_FAILED_LATCHED", "detail": _vp_init_error, "latency_ms": 0}
	if _vp_init_state == VP_INIT_REQUESTING or _vp_init_state == VP_INIT_RETRYING:
		_set_state("THINKING", "INITIAL PLAN: FINISHING (started t%d, awaiting %s)." % [_vp_init_turn, _vp_init_req])
		var attached := await _wait_for_general(_vp_init_req)
		return await _vp_init_finish_and_consume(obs, turn, _vp_init_req, attached, true)
	# V3: prefer the armed frozen opening deployment over live obs when the
	# backend never became ready during BLUE's turn (strategy-from-opening).
	var fire_obs := obs
	if _vp_init_armed and not (_vp_init_armed_obs as Dictionary).is_empty():
		fire_obs = (_vp_init_armed_obs as Dictionary).duplicate(true)
	_vp_init_armed = false
	_vp_init_armed_obs = {}
	var fired := _vp_init_fire(fire_obs, trigger, turn)
	if not bool(fired.get("ok", false)):
		return {"ok": false, "code": str(fired.get("code", "VP_INIT_START_FAILED")),
			"detail": str(fired.get("detail", "")), "latency_ms": 0}
	_set_state("THINKING", "General drafting initial plan (turn %d)." % turn)
	var first := await _wait_for_general(_vp_init_req)
	return await _vp_init_finish_and_consume(obs, turn, _vp_init_req, first, true)


## Shared INITIAL tail: finish one attempt, run the single bounded repair
## retry when owed, consume on READY. allow_retry gates the retry so the
## prefetch waiter and the blocking path share the 1+1 bound.
func _vp_init_finish_and_consume(obs: Dictionary, turn: int, req_id: String, model_res: Dictionary, allow_retry: bool) -> Dictionary:
	if _vp_init_state == VP_INIT_READY:
		return victory_consume_initial(obs, turn)
	if _vp_init_state == VP_INIT_FAILED:
		return {"ok": false, "code": "VP_INITIAL_FAILED", "detail": _vp_init_error, "latency_ms": _vp_init_latency_ms}
	var done := _vp_init_finish(req_id, model_res)
	if str(done.get("status", "")) == "READY":
		return victory_consume_initial(obs, turn)
	if str(done.get("status", "")) == "RETRY" and allow_retry:
		var refired := _vp_init_retry_fire(done)
		if not bool(refired.get("ok", false)):
			return {"ok": false, "code": "VP_INIT_RETRY_FAILED", "detail": str(refired.get("detail", "")),
				"latency_ms": _vp_init_latency_ms}
		_set_state("THINKING", "General correcting rejected VictoryPlan (%s)." % str(done.get("code", "")))
		var second := await _wait_for_general(_vp_init_req)
		var done2 := _vp_init_finish(_vp_init_req, second)
		if str(done2.get("status", "")) == "READY":
			return victory_consume_initial(obs, turn)
	return {"ok": false, "code": "VP_INITIAL_FAILED", "detail": _vp_init_error, "latency_ms": _vp_init_latency_ms}


## BOOT PREFETCH (live API repair V1): start INITIAL generation during
## scene/bootstrap from the frozen deployment snapshot. Fire-and-forget:
## returns immediately so HUMAN BLUE plays turn one while the plan builds.
## Guards: victory hierarchy, no plan yet, latch NOT_STARTED, backend
## available (agent backends always; provider needs a usable session).
func victory_prefetch_initial(obs: Dictionary) -> Dictionary:
	if not _victory_mode or _control_mode != CONTROL_HIERARCHY:
		return {"started": false, "reason": "NOT_VICTORY_PATH"}
	if _manager == null or _manager.vp_has_plan():
		return {"started": false, "reason": "HAVE_PLAN"}
	if _vp_init_state != VP_INIT_NOT_STARTED:
		return {"started": false, "reason": "ALREADY_" + _vp_init_state}
	if not bool(obs.get("ok", false)):
		return {"started": false, "reason": "OBS_NOT_OK"}
	if not _uses_agent_backend():
		var gate := SessionCls.resolve_for_use(_config)
		if not bool(gate.get("ok", false)):
			# V3: not-ready is NOT terminal. Freeze the opening deployment
			# and arm; victory_backend_ready() fires it when CONNECTED.
			_vp_init_armed = true
			_vp_init_armed_obs = (obs as Dictionary).duplicate(true)
			_vp_init_armed_turn = int(obs.get("turn", 0))
			print("[CloudTurn] VICTORY_PREFETCH_ARMED snap=%s turn=%d (backend not ready; fires on CONNECTED)" % [
				str(obs.get("snapshot_id", "?")).left(48), _vp_init_armed_turn])
			return {"started": false, "reason": "BACKEND_NOT_READY", "armed": true}
	return _vp_prefetch_fire(obs)


## Shared prefetch fire tail (boot prefetch + backend-ready re-arm).
func _vp_prefetch_fire(obs: Dictionary) -> Dictionary:
	var turn := int(obs.get("turn", 0))
	var trigger := {"trigger": "INITIAL_PLAN", "reason": "No VictoryPlan exists; prefetching at battle start.",
		"turn": turn}
	var fired := _vp_init_fire(obs, trigger, turn)
	if bool(fired.get("ok", false)):
		_vp_init_prefetched = true
		_await_prefetch(_vp_init_req) # background coroutine; BLUE stays playable.
	return fired


## V3 backend-ready re-arm: fire an armed boot prefetch EXACTLY ONCE from
## the FROZEN opening snapshot. Called by the panel when the connection
## test passes (local event; no API polling). Safe to call repeatedly.
func victory_backend_ready() -> Dictionary:
	if not _vp_init_armed:
		return {"started": false, "reason": "NOT_ARMED"}
	var obs := (_vp_init_armed_obs as Dictionary).duplicate(true)
	_vp_init_armed = false
	_vp_init_armed_obs = {}
	if _manager != null and _manager.vp_has_plan():
		return {"started": false, "reason": "HAVE_PLAN"}
	if _vp_init_state != VP_INIT_NOT_STARTED:
		return {"started": false, "reason": "ALREADY_" + _vp_init_state}
	if not _uses_agent_backend():
		var gate := SessionCls.resolve_for_use(_config)
		if not bool(gate.get("ok", false)):
			_vp_init_armed = true # backend flapped; stay armed.
			_vp_init_armed_obs = obs
			return {"started": false, "reason": "BACKEND_NOT_READY", "armed": true}
	print("[CloudTurn] VICTORY_ARMED_FIRE snap=%s (frozen opening deployment)" % [
		str(obs.get("snapshot_id", "?")).left(48)])
	var fired := _vp_prefetch_fire(obs)
	fired["armed_fire"] = true
	return fired


## Latch state for UI/tests. snapshot_id is the FROZEN prefetch snapshot
## (BLUE moves after prefetch never mutate the in-flight packet).
func victory_initial_status() -> Dictionary:
	return {"state": _vp_init_state, "req": _vp_init_req, "call": _vp_init_call,
		"turn": _vp_init_turn, "snapshot_id": _vp_init_snapshot, "battle_id": _vp_init_battle,
		"retries": _vp_init_retries, "error": _vp_init_error, "contract": _vp_init_contract,
		"prefetched": _vp_init_prefetched, "latency_ms": _vp_init_latency_ms,
		"failure_class": _vp_init_failure_class, "armed": _vp_init_armed,
		"armed_snapshot": str((_vp_init_armed_obs as Dictionary).get("snapshot_id", "")),
		"armed_turn": _vp_init_armed_turn}


## Explicit manual retry path: re-arm a FAILED (or never-started) latch and
## immediately prefetch from live state when possible. Never auto-called.
func victory_retry_initial() -> Dictionary:
	if _manager != null and _manager.vp_has_plan():
		return {"ok": false, "code": "ALREADY_HAVE_PLAN", "detail": "A VictoryPlan is already bound."}
	if _vp_init_state == VP_INIT_REQUESTING or _vp_init_state == VP_INIT_RETRYING:
		return {"ok": false, "code": "ALREADY_RUNNING", "detail": "Initial generation is already in flight."}
	if _vp_init_state == VP_INIT_READY:
		return {"ok": false, "code": "READY_PENDING", "detail": "A prefetched plan is ready; it applies at the next %s phase." % _SIDE()}
	_vp_init_state = VP_INIT_NOT_STARTED
	_vp_init_req = ""
	_vp_init_plan = {}
	_vp_init_error = ""
	_vp_init_failure_class = ""
	_strict_fault = {}
	_vp_init_retries = 0
	_vp_init_prefetched = false
	_vp_init_done = {}
	_vp_init_armed = false
	_vp_init_armed_obs = {}
	if _bridge == null:
		return {"ok": true, "code": "", "detail": "Re-armed; the next %s phase begins generation." % _SIDE(), "started": false}
	var obs := ObsCls.build(_bridge, _side)
	var res := victory_prefetch_initial(obs)
	return {"ok": true, "code": "", "detail": "Re-armed.", "started": bool(res.get("started", false)),
		"reason": str(res.get("reason", ""))}


## Fire the one INITIAL attempt (sync): frozen packet + snapshot, park or
## POST, latch -> REQUESTING. No awaiting here; callers wait or poll.
func _vp_init_fire(obs: Dictionary, trigger: Dictionary, turn: int) -> Dictionary:
	_agent_parked = {}
	_general_result = {}
	_review_in_flight = ""
	var packet := GeneralPacketCls.build_victory_initial(obs, _side)
	_last_general_packet = packet.duplicate(true)
	var req_id := "%svi_t%d_%d" % [GENERAL_REQUEST_PREFIX, turn, _turn_seq]
	var call_id := _manager.vp_next_call_id()
	var snap := _general_snap_request(req_id, 1, "", trigger, turn, obs, packet, {}, "INITIAL",
		VictoryResponseCls.initial_prompt_for(_side))
	snap["victory"] = true
	snap["victory_call"] = call_id
	snap["max_tokens"] = VICTORY_INITIAL_MAX_TOKENS
	_vp_init_state = VP_INIT_REQUESTING
	_vp_init_req = req_id
	_vp_init_call = call_id
	_vp_init_turn = turn
	_vp_init_snapshot = str(obs.get("snapshot_id", ""))
	_vp_init_battle = str(obs.get("battle_id", ""))
	_vp_init_packet = packet.duplicate(true)
	_vp_init_snap = snap
	_vp_init_trigger = trigger.duplicate(true)
	_vp_init_retries = 0
	_vp_init_error = ""
	_vp_init_failure_class = ""
	_strict_fault = {}
	_vp_init_plan = {}
	_vp_init_contract = ""
	_vp_init_armed = false
	_vp_init_armed_obs = {}
	_vp_init_t0_msec = Time.get_ticks_msec()
	_vp_init_latency_ms = 0
	TraceCls.begin_attempt(1, VICTORY_INITIAL_MAX_TOKENS, req_id)
	print("[CloudTurn] VICTORY_REQUEST_START kind=INITIAL trigger=%s turn=%d req=%s call=%s packet_chars=%d snap=%s" % [
		str(trigger.get("trigger", "?")), turn, req_id, call_id, int(snap.get("request_chars", 0)),
		_vp_init_snapshot.left(48)])
	_set_flight(snap)
	var started: Dictionary
	if _uses_agent_backend():
		started = agent_park_request("INITIAL", packet, {}, req_id, VictoryResponseCls.initial_prompt_for(_side), turn)
	else:
		started = _adapter.request_turn(req_id, packet, _config, VictoryResponseCls.initial_prompt_for(_side),
			VICTORY_INITIAL_MAX_TOKENS, brain_timeout_sec())
	if not bool(started.get("ok", false)):
		_clear_flight(req_id)
		_general_pipe_stage(snap, "transport", "START_FAILED_" + str(started.get("code", "REQUEST_FAILED")))
		_general_note_attempt(snap, "START_FAILED_" + str(started.get("code", "REQUEST_FAILED")),
			str(started.get("code", "REQUEST_FAILED")), str(started.get("detail", "")))
		snap["ended_ms"] = Time.get_ticks_msec()
		_general_history_append(snap)
		_vp_init_state = VP_INIT_FAILED
		_vp_init_error = "START_FAILED_%s: %s" % [str(started.get("code", "REQUEST_FAILED")), str(started.get("detail", ""))]
		_vp_audit_call(call_id, obs, turn, trigger, "VICTORY_INITIAL",
			{"ok": false, "latency_ms": 0, "code": str(started.get("code", "REQUEST_FAILED")), "detail": str(started.get("detail", ""))},
			"-", "START_FAILED", 0, 0, "-", "-", {"ok": false, "code": str(started.get("code", "REQUEST_FAILED")),
			"detail": str(started.get("detail", ""))}, [], [],
			{"budget": VICTORY_INITIAL_MAX_TOKENS, "retry_of": "", "prefetch": _vp_init_prefetched})
		print("[CloudTurn] VICTORY_INITIAL_FAILED call=%s reason=%s" % [call_id, _vp_init_error])
		return {"ok": false, "code": str(started.get("code", "REQUEST_FAILED")), "detail": str(started.get("detail", ""))}
	return {"ok": true, "code": "", "detail": "", "started": true, "req": req_id, "call": call_id}


## Background prefetch waiter: bounded waits + the single shared retry,
## then terminal. Never touches battle state (READY only stores the plan).
func _await_prefetch(req_id: String) -> void:
	if get_tree() == null:
		return # headless/test: no frame pump; victory_poll_initial drives completion.
	var res := await _wait_for_general(req_id)
	if _vp_init_req != req_id or (_vp_init_state != VP_INIT_REQUESTING and _vp_init_state != VP_INIT_RETRYING):
		return # consumed, reset, or superseded while waiting.
	var done := _vp_init_finish(req_id, res)
	if str(done.get("status", "")) != "RETRY":
		return # READY (stored) or FAILED (latched + audited).
	var refired := _vp_init_retry_fire(done)
	if not bool(refired.get("ok", false)):
		return
	var res2 := await _wait_for_general(_vp_init_req)
	if _vp_init_req != str(refired.get("req", "")) or _vp_init_state != VP_INIT_RETRYING:
		return
	_vp_init_finish(_vp_init_req, res2)


## SYNC finish step for one INITIAL attempt (shared by prefetch waiter,
## blocking attach, and headless tests): reads model_res, freezes snap +
## trace + the VICTORY_ATTEMPT line, and returns {status READY | RETRY |
## FAILED, ...}. RETRY is returned at most once per sequence (1+1 bound).
## Idempotent finish wrapper: the prefetch waiter and a first-RED attach
## can wake on the same reply — exactly one of them runs the side effects
## (audit/history/trace/latch); the other receives the stored outcome.
func _vp_init_finish(req_id: String, model_res: Dictionary) -> Dictionary:
	if _vp_init_done.has(req_id):
		return (_vp_init_done[req_id] as Dictionary).duplicate(true)
	var done := _vp_init_finish_inner(req_id, model_res)
	_vp_init_done[req_id] = (done as Dictionary).duplicate(true)
	return done


func _vp_init_finish_inner(req_id: String, model_res: Dictionary) -> Dictionary:
	var snap: Dictionary = _vp_init_snap
	_clear_flight(req_id)
	if str(model_res.get("request_id", "")) != req_id:
		_vp_init_failure_class = "TRANSPORT_ERROR"
		return _vp_init_fail(snap, model_res, "TIMEOUT_WAIT", "No General reply within budget.", "TIMEOUT")
	_general_snap_response(snap, model_res)
	var latency := int(model_res.get("latency_ms", 0))
	_vp_init_latency_ms += latency
	TraceCls.finish_attempt(model_res)
	GeneralTraceCls.note_general_call(latency, "INITIAL_PLAN", _vp_init_turn)
	var finish := str(model_res.get("finish_reason", ""))
	var final_chars := str(model_res.get("content_text", "")).length()
	if not bool(model_res.get("ok", false)):
		var tcode := str(model_res.get("code", "PROVIDER_ERROR"))
		# V3: a length-exhausted reply with no final text is NOT "malformed
		# JSON to repair" — the model never reached its final. Classify so
		# the retry uses the corrected generation config, not a smaller one.
		var fclass := "TRANSPORT_ERROR"
		if tcode == "REASONING_BUDGET_EXHAUSTED" or tcode == "FINISH_LENGTH_NO_FINAL":
			fclass = "NO_FINAL_GENERATION_LIMIT"
		_vp_init_failure_class = fclass
		GeneralTraceCls.note_general_disposition("REJECTED", 0, "", tcode)
		_general_note_attempt(snap, "FAILED_" + tcode, tcode, str(model_res.get("detail", "")))
		_vp_log_attempt("INITIAL", req_id, snap, model_res, VICTORY_INITIAL_MAX_TOKENS if _vp_init_retries == 0 else VICTORY_REPAIR_MAX_TOKENS,
			{"parse_code": tcode, "parse_detail": str(model_res.get("detail", "")),
			"decision": "-", "outcome": "RETRY_TRANSPORT" if (_vp_init_retries < 1 and not _strict_enabled()) else "FAILED"})
		# STRICT: no second attempt of any kind (transport failures still
		# never latch a fault: no Brain response existed to judge).
		if _vp_init_retries < 1 and not _strict_enabled():
			_general_history_append(snap)
			return {"status": "RETRY", "kind": "TRANSPORT", "code": tcode,
				"failure_class": fclass,
				"detail": str(model_res.get("detail", "")), "finish": finish, "final_chars": final_chars}
		return _vp_init_fail(snap, model_res, tcode, str(model_res.get("detail", "")), "FAILED")
	var parsed := VictoryResponseCls.parse_initial(str(model_res.get("content_text", "")),
		{"turn": _vp_init_turn, "snapshot_id": _vp_init_snapshot, "roster": _vp_roster_of_packet()})
	if not bool(parsed.get("ok", false)):
		var pcode := str(parsed.get("code", "VP_INVALID_SCHEMA"))
		# V3: unparseable final text is a syntax failure (bounded repair
		# retry with feedback); anything else is a schema failure.
		var pfclass := "FINAL_JSON_SYNTAX_INVALID" if pcode == "VP_INVALID_JSON" else "SCHEMA_INVALID"
		_vp_init_failure_class = pfclass
		GeneralTraceCls.note_general_disposition("REJECTED", 0, "", pcode)
		_general_note_attempt(snap, "REJECTED_" + pcode, pcode, str(parsed.get("detail", "")))
		_vp_log_attempt("INITIAL", req_id, snap, model_res, VICTORY_INITIAL_MAX_TOKENS if _vp_init_retries == 0 else VICTORY_REPAIR_MAX_TOKENS,
			{"parse_code": pcode, "parse_detail": str(parsed.get("detail", "")),
			"decision": "-", "outcome": "RETRY_SCHEMA" if (_vp_init_retries < 1 and not _strict_enabled() and not _utility_fallback_enabled()) else "REJECTED"})
		# STRICT: first-try production rejection latches the terminal fault;
		# no repair retry, no fallback plan, no second generation.
		_strict_latch("INITIAL", pcode, str(parsed.get("detail", "")), _vp_init_turn, _vp_init_call)
		if _vp_init_retries < 1 and not _strict_enabled() and not _utility_fallback_enabled():
			_general_history_append(snap)
			return {"status": "RETRY", "kind": "SCHEMA", "code": pcode, "failure_class": pfclass,
				"detail": str(parsed.get("detail", "")), "finish": finish, "final_chars": final_chars}
		var failed := _vp_init_fail(snap, model_res, pcode, str(parsed.get("detail", "")), "REJECTED")
		_utility_fallback_note("INITIAL", pcode, str(parsed.get("detail", "")), _vp_init_turn)
		return failed
	_vp_init_plan = parsed.get("plan", {})
	_vp_init_contract = str(parsed.get("contract", ""))
	_vp_init_state = VP_INIT_READY
	var first_phase := ""
	var phs: Array = (_vp_init_plan.get("phases", []) as Array)
	if not phs.is_empty():
		first_phase = str((phs[0] as Dictionary).get("phase_id", "P1"))
	GeneralTraceCls.note_general_disposition("READY", 1, _vp_init_snapshot)
	_general_note_attempt(snap, "READY_v1", "", "", 1, -1)
	_general_history_append(snap)
	GeneralTraceCls.note_victory_call(latency, "INITIAL_PLAN", _vp_init_turn, "INITIAL")
	_vp_log_attempt("INITIAL", req_id, snap, model_res, VICTORY_INITIAL_MAX_TOKENS if _vp_init_retries == 0 else VICTORY_REPAIR_MAX_TOKENS,
		{"parse_code": "", "parse_detail": "", "decision": "INITIAL", "outcome": "READY"})
	_vp_audit_call(_vp_init_call, {"battle_id": _vp_init_battle, "snapshot_id": _vp_init_snapshot}, _vp_init_turn,
		_vp_init_trigger, "VICTORY_INITIAL", model_res, "INITIAL", "READY", 0, 1, "-", first_phase,
		{"ok": true, "code": "", "detail": ""}, ["plan created with %d phase(s)" % phs.size()], [],
		{"budget": VICTORY_INITIAL_MAX_TOKENS if _vp_init_retries == 0 else VICTORY_REPAIR_MAX_TOKENS,
		"retry_of": "", "contract": _vp_init_contract, "prefetch": _vp_init_prefetched})
	print("[CloudTurn] VICTORY_INITIAL_READY phases=%d first=%s contract=%s latency=%dms (prefetched=%s)" % [
		phs.size(), first_phase, _vp_init_contract, _vp_init_latency_ms, str(_vp_init_prefetched)])
	return {"status": "READY"}


## Terminal INITIAL failure: latch FAILED (visible, audited, no more
## calls) and return the failure envelope. No plan exists to retain.
func _vp_init_fail(snap: Dictionary, model_res: Dictionary, code: String, detail: String, outcome: String) -> Dictionary:
	_vp_init_state = VP_INIT_FAILED
	_vp_init_error = "%s: %s" % [code, detail.left(220)]
	if snap.is_empty():
		snap = _vp_init_snap
	if not snap.is_empty():
		_general_note_attempt(snap, outcome + "_" + code, code, detail)
		_general_history_append(snap)
	GeneralTraceCls.note_general_disposition("REJECTED", 0, "", code)
	GeneralTraceCls.note_victory_call(int(model_res.get("latency_ms", 0)), "INITIAL_PLAN", _vp_init_turn, outcome)
	_vp_log_attempt("INITIAL", _vp_init_req, snap, model_res, VICTORY_REPAIR_MAX_TOKENS,
		{"parse_code": code, "parse_detail": detail, "decision": "-", "outcome": outcome})
	_vp_audit_call(_vp_init_call, {"battle_id": _vp_init_battle, "snapshot_id": _vp_init_snapshot}, _vp_init_turn,
		_vp_init_trigger, "VICTORY_INITIAL", model_res, "-", outcome, 0, 0, "-", "-",
		{"ok": false, "code": code, "detail": detail}, [], [],
		{"budget": VICTORY_REPAIR_MAX_TOKENS, "retry_of": "", "contract": "", "prefetch": _vp_init_prefetched})
	print("[CloudTurn] VICTORY_INITIAL_FAILED call=%s reason=%s (latched; RETRY PLAN re-arms)" % [_vp_init_call, _vp_init_error])
	return {"status": "FAILED", "code": code, "detail": detail}


## The ONE bounded repair retry (1+1 bound): a DIFFERENT request ??slim
## repair system prompt naming the failure (+ truncation note when
## finish=length), same frozen packet, SAME corrected generation ceiling
## (V3: a no-final retry with a smaller budget is a guaranteed repeat).
func _vp_init_retry_fire(fail: Dictionary) -> Dictionary:
	if _strict_enabled():
		return {"ok": false, "code": "STRICT_NO_RETRY", "detail": "Strict training/eval: no repair retry, no second attempt."}
	if _vp_init_retries >= 1:
		return {"ok": false, "code": "ALREADY_RETRIED", "detail": "The single bounded retry already fired."}
	_vp_init_retries += 1
	var kind := str(fail.get("kind", "SCHEMA"))
	var repair_prompt := VictoryResponseCls.initial_prompt_for(_side)
	if kind == "SCHEMA":
		repair_prompt = VictoryResponseCls.build_repair_prompt(str(fail.get("code", "")), str(fail.get("detail", "")),
			str(fail.get("finish", "")), int(fail.get("final_chars", 0)))
	var packet2 := _vp_init_packet.duplicate(true)
	packet2["rejection_feedback"] = "%s: %s Reply with corrected compact JSON only." % [
		str(fail.get("code", "")), str(fail.get("detail", "")).left(220)]
	var retry_id := "%s_r1" % _vp_init_req
	var snap := _general_snap_request(retry_id, 2, _vp_init_req, _vp_init_trigger, _vp_init_turn,
		{"snapshot_id": _vp_init_snapshot, "battle_id": _vp_init_battle, "turn": _vp_init_turn,
		"mission": (_vp_init_packet.get("mission", {}) as Dictionary).duplicate(true)},
		packet2, {}, "INITIAL", repair_prompt)
	snap["victory"] = true
	snap["victory_call"] = _vp_init_call
	snap["max_tokens"] = VICTORY_REPAIR_MAX_TOKENS
	snap["retry_of"] = _vp_init_req
	_vp_init_state = VP_INIT_RETRYING
	_vp_init_req = retry_id
	_vp_init_snap = snap
	TraceCls.begin_attempt(2, VICTORY_REPAIR_MAX_TOKENS, retry_id)
	_general_result = {}
	_set_flight(snap)
	print("[CloudTurn] VICTORY_SCHEMA_RETRY %s (%s; budget=%d, repair prompt)" % [
		str(fail.get("code", "")), kind.to_lower(), VICTORY_REPAIR_MAX_TOKENS])
	var restarted: Dictionary
	if _uses_agent_backend():
		restarted = agent_park_request("INITIAL", packet2, {}, retry_id, repair_prompt, _vp_init_turn)
	else:
		restarted = _adapter.request_turn(retry_id, packet2, _config, repair_prompt, VICTORY_REPAIR_MAX_TOKENS, brain_timeout_sec())
	if not bool(restarted.get("ok", false)):
		_clear_flight(retry_id)
		_general_pipe_stage(snap, "transport", "START_FAILED_" + str(restarted.get("code", "REQUEST_FAILED")))
		_general_note_attempt(snap, "START_FAILED_" + str(restarted.get("code", "REQUEST_FAILED")),
			str(restarted.get("code", "REQUEST_FAILED")), str(restarted.get("detail", "")))
		snap["ended_ms"] = Time.get_ticks_msec()
		_general_history_append(snap)
		_vp_init_state = VP_INIT_FAILED
		_vp_init_error = "RETRY_START_FAILED_%s" % str(restarted.get("code", "REQUEST_FAILED"))
		_manager.vp_audit_update(_vp_init_call, {"outcome": "RETRY_START_FAILED"})
		return {"ok": false, "code": str(restarted.get("code", "REQUEST_FAILED")), "detail": str(restarted.get("detail", ""))}
	return {"ok": true, "code": "", "detail": "", "req": retry_id}


## Consume a READY prefetched plan at the first RED phase: adopt against
## CURRENT tactical state: BLUE moves first; execution truth is live,
## is live; strategy is the frozen opening plan). Zero new General calls.
## SYNC poll step (public seam for headless tests; the live waiter inlines
## the same finish->retry logic): if a reply for the in-flight INITIAL
## request is present, finish it ??firing the single bounded retry when
## owed. Returns {status: NO_RESULT | READY | RETRY_FIRED |
## RETRY_START_FAILED | FAILED, ...}.
func victory_poll_initial() -> Dictionary:
	if _vp_init_state != VP_INIT_REQUESTING and _vp_init_state != VP_INIT_RETRYING:
		return {"status": _vp_init_state}
	if str(_general_result.get("request_id", "")) != _vp_init_req:
		return {"status": "NO_RESULT", "req": _vp_init_req}
	var done := _vp_init_finish(_vp_init_req, _general_result.duplicate(true))
	if str(done.get("status", "")) == "RETRY":
		var refired := _vp_init_retry_fire(done)
		if not bool(refired.get("ok", false)):
			return {"status": "RETRY_START_FAILED", "code": str(refired.get("code", "")), "detail": str(refired.get("detail", ""))}
		return {"status": "RETRY_FIRED", "req": str(refired.get("req", "")), "kind": str(done.get("kind", "")),
			"code": str(done.get("code", "")), "failure_class": str(done.get("failure_class", "")),
			"retries": _vp_init_retries}
	return done


## Consume a READY prefetched plan at the first RED phase: adopt against
## CURRENT tactical state (BLUE moves first; execution truth is live while
## strategy is the frozen opening plan). Zero new General calls.
func victory_consume_initial(obs: Dictionary, turn: int) -> Dictionary:
	if _manager != null and _manager.vp_has_plan():
		return {"ok": true, "code": "", "detail": "", "latency_ms": _vp_init_latency_ms, "version": 1,
			"prefetched": _vp_init_prefetched, "hidden_ms": 0, "already": true}
	if _vp_init_plan.is_empty():
		_vp_init_state = VP_INIT_FAILED
		_vp_init_error = "READY plan missing at consume."
		return {"ok": false, "code": "VP_INIT_CONSUME_EMPTY", "detail": _vp_init_error, "latency_ms": _vp_init_latency_ms}
	var applied := _manager.vp_apply_initial(_vp_init_plan, _vp_init_turn, str(obs.get("snapshot_id", "")),
		str(obs.get("battle_id", "")), _vp_backend_label())
	if not bool(applied.get("ok", false)):
		_vp_init_state = VP_INIT_FAILED
		_strict_latch("INITIAL", str(applied.get("code", "VP_ADOPT")), str(applied.get("detail", "")), turn, _vp_init_call)
		_vp_init_error = "Consume rejected: %s" % str(applied.get("detail", ""))
		_manager.vp_audit_update(_vp_init_call, {"outcome": "CONSUME_REJECTED"})
		_utility_fallback_note("INITIAL", str(applied.get("code", "VP_ADOPT")), str(applied.get("detail", "")), turn)
		return {"ok": false, "code": str(applied.get("code", "VP_ADOPT")), "detail": str(applied.get("detail", "")),
			"latency_ms": _vp_init_latency_ms}
	_manager.vp_note_initial_snapshot(_vp_init_snapshot)
	_manager.vp_audit_update(_vp_init_call, {"outcome": "APPLIED"})
	GeneralTraceCls.note_general_disposition("APPLIED", 1, str(obs.get("snapshot_id", "")))
	var hidden_ms := maxi(0, Time.get_ticks_msec() - _vp_init_t0_msec - _vp_init_latency_ms) if _vp_init_prefetched else 0
	print("[CloudTurn] VICTORY_PLAN_ADOPTED v1 phases=%d active=%s contract=%s api_latency=%dms hidden_behind_blue=%dms" % [
		(_manager.vp_get_plan().get("phases", []) as Array).size(), str(applied.get("phase", "?")),
		_vp_init_contract, _vp_init_latency_ms, hidden_ms])
	return {"ok": true, "code": "", "detail": "", "latency_ms": _vp_init_latency_ms, "version": 1,
		"prefetched": _vp_init_prefetched, "hidden_ms": hidden_ms}


## CONTEXTUAL BRAIN (BRAIN_CONTEXT_PACK=v0 only; context OFF = packet unchanged):
## a review also shows where the friendly units are now (compact_state, the
## same block VICTORY_INITIAL carries) and what the Hands did since the last
## review (_review_force_feedback, subclass hook). Without it a review only
## sees sector counts and attacked/lost events.
func _augment_review_packet(packet: Dictionary, obs: Dictionary) -> void:
	if not ReviewContextCls.enabled():
		return
	packet["compact_state"] = GeneralPacketCls.compact_state(obs, _side)
	var fb := _review_force_feedback(int(obs.get("turn", 0)))
	if not fb.is_empty():
		packet["force_feedback"] = fb
	# Unallocated contract: the Brain assigns no units, so live mission rows
	# carried "units": [] and read as "no force on this mission". Show the
	# units the Hands actually assigned.
	var by_mission := _review_mission_units()
	if not by_mission.is_empty():
		for row_val in ((packet.get("plan_live", {}) as Dictionary).get("mission_statuses", []) as Array):
			var row: Dictionary = row_val
			if (row.get("units", []) as Array).is_empty():
				row["units"] = (by_mission.get(str(row.get("mission_id", "")), []) as Array).duplicate()
				row["units_source"] = "HAND_A"
				# The legacy layer marks every unallocated Brain mission ABORTED/NO_FORCE
				# (the Brain never assigns units in this contract). Report the live truth.
				if str(row.get("status_reason", "")) == "NO_FORCE":
					var manned := not (row["units"] as Array).is_empty()
					row["status"] = "ACTIVE" if manned else "UNASSIGNED"
					row["status_reason"] = "HAND_A_ASSIGNED" if manned else "HAND_A_ASSIGNED_NO_UNITS"


## STRATEGIC REPLAN context: the plan being replaced, how far it got, and what changed since it was
## written. The reply is a continuation plan for the next interval, not a fresh opening.
func _strategic_replan_context(obs: Dictionary, trigger: Dictionary) -> Dictionary:
	var turn := int(obs.get("turn", 0))
	var every := MissionManagerCls.strategic_replan_every()
	var now := _strategic_force_snapshot(GeneralPacketCls.compact_state(obs, _side), turn)
	var prev: Dictionary = _strategic_prev
	if prev.is_empty() and _vp_init_packet.has("compact_state"):
		prev = _strategic_force_snapshot(_vp_init_packet["compact_state"], 1)
	var live := _manager.build_victory_review_packet(obs, trigger)
	_augment_review_packet(live, obs)
	var pl: Dictionary = live.get("plan_live", {})
	var since := {}
	if not prev.is_empty():
		since["from_turn"] = prev.get("turn", 1)
		for k in ["own_formations", "own_soldiers", "own_hq_soldiers", "blue_visible_formations", "blue_hq_estimate"]:
			since[k] = {"then": prev.get(k), "now": now.get(k)}
	_strategic_prev = now
	return {
		"kind": "MID_BATTLE_REPLAN", "turn": turn, "horizon_turns": every,
		"instruction": ("Mid-battle replan at turn %d, NOT the opening. Write a full 2-3 phase plan covering the next ~%d turns "
			+ "as a continuation of previous_plan: keep what is working, change what is not, using since_last_plan and "
			+ "previous_plan_status. Same output format and rules as the opening plan (no unit ids).") % [turn, every],
		"previous_plan": (GeneralPacketCls.VictoryAuthoringCls.compress_plan(_manager.vp_get_plan()).get("authoring", {}) as Dictionary).get("phases", []),
		"previous_plan_status": {"current_phase_id": pl.get("current_phase_id", "-"), "missions": _strategic_mission_rows(pl)},
		"since_last_plan": since,
	}


## Mission progress without unit ids (the unalloc contract forbids naming units in a plan).
static func _strategic_mission_rows(pl: Dictionary) -> Array:
	var out: Array = []
	for row_val in pl.get("mission_statuses", []):
		if row_val is Dictionary:
			var r: Dictionary = row_val
			out.append({"mission_id": r.get("mission_id", ""), "task": r.get("task", ""), "area": r.get("area", ""),
				"status": r.get("status", ""), "assigned_units": (r.get("units", []) as Array).size()})
	return out


static func _strategic_force_snapshot(cs: Dictionary, turn: int) -> Dictionary:
	var fs: Dictionary = cs.get("force_summary", {})
	var own_hq := 0
	for u in cs.get("friendly_units", []):
		if u is Dictionary and str((u as Dictionary).get("class", "")).to_upper() == "HQ":
			own_hq = int((u as Dictionary).get("soldiers", 0))
	var blue_hq := "unknown"
	for e in cs.get("known_enemy_units", []):
		if e is Dictionary and str((e as Dictionary).get("class", "")).to_upper() == "HQ":
			blue_hq = str((e as Dictionary).get("troop_estimate", "unknown"))
	return {"turn": turn, "own_formations": int(fs.get("red_formations", 0)), "own_soldiers": int(fs.get("red_soldiers", 0)),
		"own_hq_soldiers": own_hq, "blue_visible_formations": int(fs.get("blue_visible", 0)), "blue_hq_estimate": blue_hq}


## STRATEGIC REPLAN: an opening-plan style reply becomes an EMERGENCY_REPLAN review (unparseable text is
## passed through unchanged, so the normal parser reports the error).
static func _as_strategic_replan(text: String) -> String:
	var doc: Variant = JSON.parse_string(text.strip_edges())
	if not doc is Dictionary:
		return text
	var d: Dictionary = doc
	if not d.has("decision"):
		d["decision"] = "EMERGENCY_REPLAN"
	if str(d.get("reason", "")).strip_edges().is_empty():
		d["reason"] = "Strategic replan from the current situation."
	return JSON.stringify(d)


## Context pack only: the review parser may expand a compact AMEND patch onto the CURRENT plan.
func _review_parse_ctx(ctx: Dictionary) -> Dictionary:
	if ReviewContextCls.enabled() and _manager != null and _manager.vp_has_plan():
		ctx["plan_authoring"] = (GeneralPacketCls.VictoryAuthoringCls.compress_plan(_manager.vp_get_plan()).get("authoring", {}) as Dictionary)
	return ctx


## Per-unit execution feedback for a review ({} = none). Hands controllers override.
func _review_force_feedback(_turn: int) -> Dictionary:
	return {}


## mission_id -> [unit_id] as allocated below the Brain ({} = none). Hands controllers override.
func _review_mission_units() -> Dictionary:
	return {}


## Forced blocking VICTORY_REVIEW (a plan already exists). Reviews never
## touch the initial latch.
func _victory_blocking_review(obs: Dictionary, trigger: Dictionary, turn: int) -> Dictionary:
	_agent_parked = {}
	_general_result = {}
	_review_in_flight = ""
	var packet := _manager.build_victory_review_packet(obs, trigger)
	_augment_review_packet(packet, obs)
	_last_general_packet = packet.duplicate(true)
	var req_id := "%svr%d_%d" % [GENERAL_REQUEST_PREFIX, turn, _turn_seq]
	var call_id := _manager.vp_next_call_id()
	var rev_before := int(_manager.vp_get_plan().get("revision", 0))
	var ph_before := str(_manager.vp_get_plan().get("current_phase_id", "-"))
	var snap := _general_snap_request(req_id, 1, "", trigger, turn, obs, packet, {}, "REVIEW",
		VictoryResponseCls.review_prompt_for(_side))
	snap["victory"] = true
	snap["victory_call"] = call_id
	snap["max_tokens"] = VICTORY_REVIEW_MAX_TOKENS
	TraceCls.begin_attempt(1, VICTORY_REVIEW_MAX_TOKENS, req_id)
	print("[CloudTurn] VICTORY_REQUEST_START kind=REVIEW trigger=%s turn=%d req=%s call=%s packet_chars=%d" % [
		str(trigger.get("trigger", "?")), turn, req_id, call_id, int(snap.get("request_chars", 0))])
	_set_flight(snap)
	var started: Dictionary
	if _uses_agent_backend():
		started = agent_park_request("REVIEW", packet, {}, req_id, VictoryResponseCls.review_prompt_for(_side), turn)
	else:
		started = _adapter.request_turn(req_id, packet, _config, VictoryResponseCls.review_prompt_for(_side),
			VICTORY_REVIEW_MAX_TOKENS, brain_timeout_sec())
	if not bool(started.get("ok", false)):
		_clear_flight(req_id)
		_general_pipe_stage(snap, "transport", "START_FAILED_" + str(started.get("code", "REQUEST_FAILED")))
		_general_note_attempt(snap, "START_FAILED_" + str(started.get("code", "REQUEST_FAILED")),
			str(started.get("code", "REQUEST_FAILED")), str(started.get("detail", "")))
		snap["ended_ms"] = Time.get_ticks_msec()
		_general_history_append(snap)
		_vp_audit_call(call_id, obs, turn, trigger, "VICTORY_REVIEW",
			{"ok": false, "latency_ms": 0, "code": str(started.get("code", "REQUEST_FAILED")), "detail": str(started.get("detail", ""))},
			"-", "START_FAILED", rev_before, rev_before, ph_before, ph_before,
			{"ok": false, "code": str(started.get("code", "REQUEST_FAILED")), "detail": str(started.get("detail", ""))}, [], [],
			{"budget": VICTORY_REVIEW_MAX_TOKENS, "retry_of": "", "prefetch": false})
		print("[CloudTurn] GENERAL_REVIEW_FAILED_PLAN_RETAINED call=%s reason=START_FAILED" % call_id)
		return {"ok": false, "code": str(started.get("code", "REQUEST_FAILED")), "detail": str(started.get("detail", "")), "latency_ms": 0}
	var model_res := await _wait_for_general(req_id)
	_clear_flight(req_id)
	_general_snap_response(snap, model_res)
	var latency := int(model_res.get("latency_ms", 0))
	TraceCls.finish_attempt(model_res)
	GeneralTraceCls.note_general_call(latency, str(trigger.get("trigger", "?")), turn)
	if not bool(model_res.get("ok", false)):
		GeneralTraceCls.note_general_disposition("REJECTED", 0, "", str(model_res.get("code", "PROVIDER_ERROR")))
		_general_note_attempt(snap, "FAILED_" + str(model_res.get("code", "PROVIDER_ERROR")),
			str(model_res.get("code", "PROVIDER_ERROR")), str(model_res.get("detail", "")))
		_general_history_append(snap)
		GeneralTraceCls.note_victory_call(latency, str(trigger.get("trigger", "?")), turn, "FAILED")
		_vp_log_attempt("REVIEW", req_id, snap, model_res, VICTORY_REVIEW_MAX_TOKENS,
			{"parse_code": str(model_res.get("code", "PROVIDER_ERROR")), "parse_detail": str(model_res.get("detail", "")),
			"decision": "-", "outcome": "FAILED"})
		_vp_audit_call(call_id, obs, turn, trigger, "VICTORY_REVIEW", model_res,
			"-", "FAILED", rev_before, rev_before, ph_before, ph_before,
			{"ok": false, "code": str(model_res.get("code", "PROVIDER_ERROR")), "detail": str(model_res.get("detail", ""))}, [], [],
			{"budget": VICTORY_REVIEW_MAX_TOKENS, "retry_of": "", "prefetch": false})
		print("[CloudTurn] GENERAL_REVIEW_FAILED_PLAN_RETAINED call=%s reason=%s" % [call_id, str(model_res.get("code", "PROVIDER_ERROR"))])
		return {"ok": false, "code": str(model_res.get("code", "PROVIDER_ERROR")), "detail": str(model_res.get("detail", "")), "latency_ms": latency}
	var parsed := VictoryResponseCls.parse_review(str(model_res.get("content_text", "")),
		_review_parse_ctx({"turn": turn, "snapshot_id": str(obs.get("snapshot_id", "")), "roster": _vp_roster_of_obs(obs)}))
	if not bool(parsed.get("ok", false)):
		_strict_latch("REVIEW", str(parsed.get("code", "VP_INVALID_SCHEMA")), str(parsed.get("detail", "")), turn, call_id)
		GeneralTraceCls.note_general_disposition("REJECTED", 0, "", str(parsed.get("code", "VP_INVALID_SCHEMA")))
		_general_note_attempt(snap, "REJECTED_" + str(parsed.get("code", "VP_INVALID_SCHEMA")),
			str(parsed.get("code", "VP_INVALID_SCHEMA")), str(parsed.get("detail", "")))
		_general_history_append(snap)
		GeneralTraceCls.note_victory_call(latency, str(trigger.get("trigger", "?")), turn, "REJECTED")
		_vp_log_attempt("REVIEW", req_id, snap, model_res, VICTORY_REVIEW_MAX_TOKENS,
			{"parse_code": str(parsed.get("code", "VP_INVALID_SCHEMA")), "parse_detail": str(parsed.get("detail", "")),
			"decision": str((parsed.get("review", {}) as Dictionary).get("decision", "-")), "outcome": "REJECTED"})
		_vp_audit_call(call_id, obs, turn, trigger, "VICTORY_REVIEW", model_res,
			str((parsed.get("review", {}) as Dictionary).get("decision", "-")), "REJECTED", rev_before, rev_before, ph_before, ph_before,
			{"ok": false, "code": str(parsed.get("code", "VP_INVALID_SCHEMA")), "detail": str(parsed.get("detail", ""))}, [], [],
			{"budget": VICTORY_REVIEW_MAX_TOKENS, "retry_of": "", "prefetch": false})
		print("[CloudTurn] GENERAL_REVIEW_FAILED_PLAN_RETAINED call=%s reason=%s" % [call_id, str(parsed.get("code", "VP_INVALID_SCHEMA"))])
		_utility_fallback_note("REVIEW", str(parsed.get("code", "VP_INVALID_SCHEMA")), str(parsed.get("detail", "")), turn)
		return {"ok": false, "code": str(parsed.get("code", "VP_INVALID_SCHEMA")), "detail": str(parsed.get("detail", "")), "latency_ms": latency}
	var review: Dictionary = parsed.get("review", {})
	var computed := _manager.vp_compute_review(review, obs, turn)
	if not bool(computed.get("ok", false)):
		_strict_latch("REVIEW", str(computed.get("code", "VP_COMPUTE")), str(computed.get("detail", "")), turn, call_id)
		GeneralTraceCls.note_general_disposition("REJECTED", 0, "", str(computed.get("code", "VP_COMPUTE")))
		_general_note_attempt(snap, "REJECTED_" + str(computed.get("code", "VP_COMPUTE")), str(computed.get("code", "VP_COMPUTE")), str(computed.get("detail", "")))
		_general_history_append(snap)
		GeneralTraceCls.note_victory_call(latency, str(trigger.get("trigger", "?")), turn, str(review.get("decision", "?")))
		_vp_log_attempt("REVIEW", req_id, snap, model_res, VICTORY_REVIEW_MAX_TOKENS,
			{"parse_code": str(computed.get("code", "VP_COMPUTE")), "parse_detail": str(computed.get("detail", "")),
			"decision": str(review.get("decision", "?")), "outcome": "REJECTED"})
		_vp_audit_call(call_id, obs, turn, trigger, "VICTORY_REVIEW", model_res, str(review.get("decision", "?")), "REJECTED",
			rev_before, rev_before, ph_before, ph_before,
			{"ok": false, "code": str(computed.get("code", "VP_COMPUTE")), "detail": str(computed.get("detail", ""))}, [], [],
			{"budget": VICTORY_REVIEW_MAX_TOKENS, "retry_of": "", "prefetch": false})
		print("[CloudTurn] GENERAL_REVIEW_FAILED_PLAN_RETAINED call=%s reason=%s" % [call_id, str(computed.get("code", "VP_COMPUTE"))])
		_utility_fallback_note("REVIEW", str(computed.get("code", "VP_COMPUTE")), str(computed.get("detail", "")), turn)
		return {"ok": false, "code": str(computed.get("code", "VP_COMPUTE")), "detail": str(computed.get("detail", "")), "latency_ms": latency}
	var committed := _manager.vp_commit_review(computed, (obs.get("mission", {}) as Dictionary).duplicate(true), turn,
		str(obs.get("snapshot_id", "")), str(trigger.get("trigger", "?")))
	GeneralTraceCls.note_general_disposition("KEPT" if str(review.get("decision", "")) == "KEEP" else "APPLIED",
		int(committed.get("revision", 0)), str(obs.get("snapshot_id", "")))
	_general_note_attempt(snap, "APPLIED_v%d" % int(committed.get("revision", 0)), "", "", int(committed.get("revision", 0)),
		((_manager.get_plan().get("missions", []) as Array).size()))
	_general_history_append(snap)
	GeneralTraceCls.note_victory_call(latency, str(trigger.get("trigger", "?")), turn, str(review.get("decision", "?")))
	var cdiff: Dictionary = committed.get("diff", {})
	_vp_log_attempt("REVIEW", req_id, snap, model_res, VICTORY_REVIEW_MAX_TOKENS,
		{"parse_code": "", "parse_detail": "", "decision": str(review.get("decision", "?")), "outcome": "APPLIED"})
	_vp_audit_call(call_id, obs, turn, trigger, "VICTORY_REVIEW", model_res, str(review.get("decision", "?")), "APPLIED",
		rev_before, int(committed.get("revision", 0)), ph_before, str(committed.get("phase", "?")),
		{"ok": true, "code": "", "detail": ""}, cdiff.get("changed", []), cdiff.get("mission_changes", []),
		{"budget": VICTORY_REVIEW_MAX_TOKENS, "retry_of": "", "contract": str(review.get("contract", "")), "prefetch": false})
	_manager.acknowledge_review_events(trigger, str(review.get("decision", "?")), int(committed.get("revision", 0)), "APPLIED")
	print("[CloudTurn] VICTORY_REVIEW_APPLIED decision=%s rev=%d phase=%s" % [str(review.get("decision", "?")),
		int(committed.get("revision", 0)), str(committed.get("phase", "?"))])
	return {"ok": true, "code": "", "detail": "", "latency_ms": latency, "version": int(committed.get("revision", 0))}


## RED roster ids from an obs (for authoring unit validation).
static func _vp_roster_of_obs(obs: Dictionary) -> Array:
	var out: Array = []
	for u_val in (obs.get("friendly_units", []) as Array):
		if u_val is Dictionary:
			out.append(str((u_val as Dictionary).get("unit_id", "")).strip_edges().to_upper())
	return out


## RED roster ids from the frozen prefetch packet's compact state.
func _vp_roster_of_packet() -> Array:
	var out: Array = []
	for u_val in (((_vp_init_packet.get("compact_state", {}) as Dictionary).get("friendly_units", [])) as Array):
		if u_val is Dictionary:
			out.append(str((u_val as Dictionary).get("unit_id", "")).strip_edges().to_upper())
	return out


static func _vp_is_length_finish(finish: String) -> bool:
	var f := finish.strip_edges().to_lower()
	return f == "length" or f == "max_tokens"


## One-line forensic record per victory attempt: transport + model +
## parse facts together, so a future VP_INVALID_JSON needs no archaeology.
func _vp_log_attempt(kind: String, req_id: String, snap: Dictionary, model_res: Dictionary, budget: int, extra: Dictionary) -> void:
	var env: Dictionary = model_res.get("envelope", {}) as Dictionary
	var usage: Dictionary = env.get("usage", {})
	print("[CloudTurn] VICTORY_ATTEMPT call=%s kind=%s turn=%d req=%s http=%s lat=%dms finish=%s final=%dchars reasoning=%s(%d) usage=%s budget=%d parse=%s decision=%s outcome=%s" % [
		str(snap.get("victory_call", "?")), kind, int(snap.get("turn", 0)), req_id,
		str(model_res.get("http_status", "?")), int(model_res.get("latency_ms", 0)),
		str(model_res.get("finish_reason", env.get("finish_reason", "-"))),
		str(model_res.get("content_text", "")).length(),
		"yes" if bool(env.get("reasoning_present", false)) else "no", int(env.get("reasoning_chars", 0)),
		JSON.stringify(usage), budget,
		str(extra.get("parse_code", "")) if not str(extra.get("parse_code", "")).is_empty() else "OK",
		str(extra.get("decision", "-")), str(extra.get("outcome", "?"))])


## One review window per BLUE->RED transition, for ANY legitimate review
## trigger: combat event batches AND non-event sources (periodic horizon,
## mission lifecycle, HQ condition, VictoryPlan transitions, plan review
## conditions). This waits only at the phase boundary, never inside an
## individual combat action. A valid ADJUST/REPLAN is staged by the
## ordinary collector and immediately passes the ordinary staleness gate
## before RED tactical decisions begin.
## TRAINING_CONTRACT_REVIEW_WAKE_V1: review_due == true must NOT require
## an event batch id to wake the General; the batch gate below used to
## silently discard every legitimate non-event review at this window.
func _service_event_review_before_red(obs: Dictionary, turn: int, gate_ok: bool) -> Dictionary:
	var out := {"obs": obs.duplicate(true), "review": {}, "called": false}
	var review: Dictionary = _manager.review_due(obs, turn)
	if not bool(review.get("requested", false)):
		return out
	out["review"] = review.duplicate(true)
	var review_window := "%s#%d" % [str(obs.get("battle_id", "")), turn]
	if review_window_already_serviced(_last_event_review_window, review_window):
		return out
	if not gate_ok:
		print("[CloudTurn] WAKE_REVIEW_DEFERRED trigger=%s count=%d reason=UNCONFIGURED" % [
			str(review.get("trigger", "")), int(review.get("event_count", 0))])
		return out
	# A review that began during the prior human turn is allowed to settle and
	# pass its own staleness gate first. Its packet may predate this event batch.
	if not _review_in_flight.is_empty():
		await _wait_for_background_review(_review_in_flight)
		var after_prior := ObsCls.build(_bridge, _side)
		if bool(after_prior.get("ok", false)):
			_adopt_staged_if_fresh(after_prior, turn)
			obs = after_prior
		review = _manager.review_due(obs, turn)
		out["obs"] = obs.duplicate(true)
		out["review"] = review.duplicate(true)
		if not bool(review.get("requested", false)):
			return out
	_last_event_review_window = review_window
	if int(review.get("event_batch_id", 0)) > 0:
		_set_state("THINKING", "General reviewing %d buffered combat event(s) before %s execution." % [int(review.get("event_count", 0)), _SIDE()])
	else:
		_set_state("THINKING", "General reviewing (%s) before %s execution." % [str(review.get("trigger", "?")), _SIDE()])
	var req_id := _fire_background_review(obs, review)
	if req_id.is_empty():
		return out
	out["called"] = true
	await _wait_for_background_review(req_id)
	var fresh := ObsCls.build(_bridge, _side)
	if bool(fresh.get("ok", false)):
		_adopt_staged_if_fresh(fresh, turn)
		out["obs"] = fresh.duplicate(true)
	_sync_wakeup_state()
	return out


func _wait_for_background_review(req_id: String) -> void:
	var budget_ms := int((brain_timeout_sec() + 12.0) * 1000.0)
	if _uses_agent_backend():
		budget_ms *= 4 # EXTERNAL_AGENT / DEBUG_AGENT (dev): agent submissions arrive from outside the engine.
	var t0 := Time.get_ticks_msec()
	var frames := 0
	while _review_in_flight == req_id:
		if get_tree() == null:
			return
		await get_tree().process_frame
		frames += 1
		_watchdog_tick(frames, "event review safe window")
		if Time.get_ticks_msec() - t0 > budget_ms:
			print("[CloudTurn] WAKE_REVIEW_WAIT_TIMEOUT request=%s" % req_id)
			return


## Fire a NON-BLOCKING REVIEW_COORDINATION. Ordinary periodic/manual reviews
## resolve during the human turn; an event review may be awaited by the safe
## phase-boundary service above.
## The collector below STAGES ADJUST/REPLAN results (validated
## data only) or confirms KEEP (review clock only). Battle state is never
## touched from the background flight.
func _fire_background_review(obs: Dictionary, review: Dictionary) -> String:
	if not _review_in_flight.is_empty() or not _staged_plan.is_empty() or not _staged_vp.is_empty():
		return ""
	if _victory_mode and _control_mode == CONTROL_HIERARCHY and _manager.vp_has_plan():
		return _fire_victory_review(obs, review)
	if not bool(obs.get("ok", false)):
		return ""
	var menu := _manager.build_coord_menu(obs)
	if (menu.get("groups", []) as Array).is_empty():
		print("[CloudTurn] HIER background review skipped: empty menu (no listed formations).")
		return ""
	var trigger := review.duplicate(true)
	trigger["trigger"] = str(review.get("trigger", ""))
	trigger["reason"] = str(review.get("reason", ""))
	trigger["turn"] = int(obs.get("turn", 0))
	var packet := GeneralPacketCls.build_coord_review(obs, menu, _manager.get_plan(), trigger,
		_manager.events_for_review(trigger), _manager.get_coordination(), _side)
	_last_general_packet = packet.duplicate(true)
	var req_id := "%sbg_t%d_%d" % [GENERAL_REQUEST_PREFIX, int(obs.get("turn", 0)), _turn_seq]
	var base := MissionManagerCls.review_base_from_obs(obs, _side)
	var snap := _general_snap_request(req_id, 1, "", trigger, int(obs.get("turn", 0)), obs, packet, menu, "REVIEW", CoordResponseCls.REVIEW_SYSTEM_PROMPT)
	snap["kind"] = "GENERAL_REVIEW_BG"
	_set_flight(snap)
	var started: Dictionary
	if _uses_agent_backend():
		started = agent_park_request("REVIEW", packet, menu, req_id, CoordResponseCls.REVIEW_SYSTEM_PROMPT, int(obs.get("turn", 0)))
	else:
		started = _adapter.request_turn(req_id, packet, _config, CoordResponseCls.REVIEW_SYSTEM_PROMPT, GENERAL_MAX_TOKENS, brain_timeout_sec())
	if not bool(started.get("ok", false)):
		_clear_flight(req_id)
		_general_pipe_stage(snap, "transport", "START_FAILED_" + str(started.get("code", "REQUEST_FAILED")))
		snap["outcome"] = "START_FAILED_" + str(started.get("code", "REQUEST_FAILED"))
		snap["ended_ms"] = Time.get_ticks_msec()
		_general_history_append(snap)
		print("[CloudTurn] HIER background review failed to start: %s" % str(started.get("code", "")))
		_manager.note_review_failed(trigger, "START_FAILED_" + str(started.get("code", "REQUEST_FAILED")))
		return ""
	_review_in_flight = req_id
	_review_base = base
	_manager.note_review_started(trigger)
	if int(trigger.get("event_batch_id", 0)) > 0:
		print("[CloudTurn] WAKE_REVIEW_FIRED trigger=%s events=%d batch=%d base=%s" % [
			str(trigger.get("trigger", "")), int(trigger.get("event_count", 0)),
			int(trigger.get("event_batch_id", 0)), str(base.get("snapshot_id", "")).left(48)])
	else:
		print("[CloudTurn] HIER background General review fired (%s) base=%s" % [
			str(trigger.get("trigger", "")), str(base.get("snapshot_id", "")).left(48)])
	_collect_background_review(req_id, base, trigger, snap)
	return req_id


## VICTORY PLAN V0 (additive): fire a non-blocking VICTORY_REVIEW. Same
## lifecycle as the coordinator background review; the collector stages
## ADVANCE/AMEND/EMERGENCY revisions or confirms KEEP.
func _fire_victory_review(obs: Dictionary, review: Dictionary) -> String:
	if not bool(obs.get("ok", false)):
		return ""
	var trigger := review.duplicate(true)
	trigger["trigger"] = str(review.get("trigger", ""))
	trigger["reason"] = str(review.get("reason", ""))
	trigger["turn"] = int(obs.get("turn", 0))
	# STRATEGIC REPLAN (context pack only): the request is the opening-plan request built from the current
	# state; the reply is installed as EMERGENCY_REPLAN by the collector.
	var strategic := str(trigger.get("trigger", "")) == "STRATEGIC_REPLAN"
	var packet := GeneralPacketCls.build_victory_initial(obs, _side) if strategic else _manager.build_victory_review_packet(obs, trigger)
	if not strategic:
		_augment_review_packet(packet, obs)
	var prompt := VictoryResponseCls.initial_prompt_for(_side) if strategic else VictoryResponseCls.review_prompt_for(_side)
	var budget := VICTORY_INITIAL_MAX_TOKENS if strategic else VICTORY_REVIEW_MAX_TOKENS
	if strategic:
		packet["replan_context"] = _strategic_replan_context(obs, trigger)
		_manager.vp_note_strategic(int(obs.get("turn", 0)))
	_last_general_packet = packet.duplicate(true)
	var req_id := "%svg_t%d_%d" % [GENERAL_REQUEST_PREFIX, int(obs.get("turn", 0)), _turn_seq]
	var call_id := _manager.vp_next_call_id()
	var base := MissionManagerCls.review_base_from_obs(obs, _side)
	var snap := _general_snap_request(req_id, 1, "", trigger, int(obs.get("turn", 0)), obs, packet, {}, "REVIEW", prompt)
	snap["kind"] = "VICTORY_REVIEW_BG"
	snap["victory"] = true
	snap["victory_call"] = call_id
	snap["victory_obs"] = obs.duplicate(true)
	snap["max_tokens"] = budget
	_set_flight(snap)
	var started: Dictionary
	if _uses_agent_backend():
		started = agent_park_request("REVIEW", packet, {}, req_id, prompt, int(obs.get("turn", 0)))
	else:
		started = _adapter.request_turn(req_id, packet, _config, prompt, budget, brain_timeout_sec())
	if not bool(started.get("ok", false)):
		_clear_flight(req_id)
		_general_pipe_stage(snap, "transport", "START_FAILED_" + str(started.get("code", "REQUEST_FAILED")))
		snap["outcome"] = "START_FAILED_" + str(started.get("code", "REQUEST_FAILED"))
		snap["ended_ms"] = Time.get_ticks_msec()
		_general_history_append(snap)
		print("[CloudTurn] VICTORY background review failed to start: %s" % str(started.get("code", "")))
		_manager.note_review_failed(trigger, "START_FAILED_" + str(started.get("code", "REQUEST_FAILED")))
		return ""
	_review_in_flight = req_id
	_review_base = base
	_manager.note_review_started(trigger)
	print("[CloudTurn] VICTORY background review fired (%s) call=%s base=%s" % [
		str(trigger.get("trigger", "")), call_id, str(base.get("snapshot_id", "")).left(48)])
	_collect_victory_review(req_id, base, trigger, snap)
	return req_id


## Victory background collector: waits for the review flight, validates the
## reply through the canonical victory contract, and stages ADVANCE / AMEND /
## EMERGENCY revisions (or confirms KEEP). Battle state is never touched
## from the background flight; failures retain the live plan.
func _collect_victory_review(req_id: String, base: Dictionary, trigger: Dictionary, snap: Dictionary) -> void:
	var budget_ms := int((brain_timeout_sec() + 10.0) * 1000.0)
	if _uses_agent_backend():
		budget_ms *= 4
	var t0 := Time.get_ticks_msec()
	while _review_in_flight == req_id and str(_general_result.get("request_id", "")) != req_id:
		if get_tree() == null:
			_manager.note_review_failed(trigger, "TREE_UNAVAILABLE")
			_finish_background_review(req_id)
			return
		await get_tree().process_frame
		if Time.get_ticks_msec() - t0 > budget_ms:
			break
	if _review_in_flight != req_id:
		_manager.note_review_failed(trigger, "SUPERSEDED")
		return
	var res := _general_result.duplicate(true)
	var call_id := str(snap.get("victory_call", ""))
	var rev_before := int(_manager.vp_get_plan().get("revision", 0))
	var ph_before := str(_manager.vp_get_plan().get("current_phase_id", "-"))
	if str(res.get("request_id", "")) != req_id:
		_general_pipe_stage(snap, "transport", "TIMEOUT_WAIT")
		snap["outcome"] = "TIMEOUT_WAIT"
		snap["ended_ms"] = Time.get_ticks_msec()
		_general_history_append(snap)
		print("[CloudTurn] VICTORY background review timed out waiting for %s" % req_id)
		_vp_log_attempt("REVIEW_BG", req_id, snap, {"ok": false, "latency_ms": 0, "code": "TIMEOUT_WAIT"}, VICTORY_REVIEW_MAX_TOKENS,
			{"parse_code": "TIMEOUT_WAIT", "parse_detail": "No General reply within budget.", "decision": "-", "outcome": "TIMEOUT"})
		_vp_audit_call(call_id, snap.get("victory_obs", {}), int(trigger.get("turn", 0)), trigger, "VICTORY_REVIEW",
			{"ok": false, "latency_ms": 0, "code": "TIMEOUT_WAIT", "detail": "No General reply within budget."},
			"-", "TIMEOUT", rev_before, rev_before, ph_before, ph_before,
			{"ok": false, "code": "TIMEOUT_WAIT", "detail": "No General reply within budget."}, [], [],
			{"budget": VICTORY_REVIEW_MAX_TOKENS, "retry_of": "", "prefetch": false})
		print("[CloudTurn] GENERAL_REVIEW_FAILED_PLAN_RETAINED call=%s reason=TIMEOUT_WAIT" % call_id)
		_manager.note_review_failed(trigger, "TIMEOUT_WAIT")
		_finish_background_review(req_id)
		return
	_general_snap_response(snap, res)
	var latency := int(res.get("latency_ms", 0))
	GeneralTraceCls.note_general_call(latency, str(trigger.get("trigger", "")) + "_BG", int(trigger.get("turn", 0)))
	if not bool(res.get("ok", false)):
		GeneralTraceCls.note_general_disposition("REJECTED", 0, "", str(res.get("code", "PROVIDER_ERROR")))
		snap["outcome"] = "FAILED_" + str(res.get("code", "PROVIDER_ERROR"))
		_general_history_append(snap)
		GeneralTraceCls.note_victory_call(latency, str(trigger.get("trigger", "")), int(trigger.get("turn", 0)), "FAILED")
		_vp_log_attempt("REVIEW_BG", req_id, snap, res, VICTORY_REVIEW_MAX_TOKENS,
			{"parse_code": str(res.get("code", "PROVIDER_ERROR")), "parse_detail": str(res.get("detail", "")),
			"decision": "-", "outcome": "FAILED"})
		_vp_audit_call(call_id, snap.get("victory_obs", {}), int(trigger.get("turn", 0)), trigger, "VICTORY_REVIEW", res,
			"-", "FAILED", rev_before, rev_before, ph_before, ph_before,
			{"ok": false, "code": str(res.get("code", "PROVIDER_ERROR")), "detail": str(res.get("detail", ""))}, [], [],
			{"budget": VICTORY_REVIEW_MAX_TOKENS, "retry_of": "", "prefetch": false})
		print("[CloudTurn] GENERAL_REVIEW_FAILED_PLAN_RETAINED call=%s reason=%s" % [call_id, str(res.get("code", "PROVIDER_ERROR"))])
		_manager.note_review_failed(trigger, str(res.get("code", "PROVIDER_ERROR")))
		_finish_background_review(req_id)
		return
	var final_text := str(res.get("content_text", ""))
	snap["parser_input_chars"] = final_text.length()
	snap["parser_input_match"] = final_text == str(snap.get("response_text", ""))
	if str(trigger.get("trigger", "")) == "STRATEGIC_REPLAN":
		final_text = _as_strategic_replan(final_text)
	var parsed := VictoryResponseCls.parse_review(final_text, _review_parse_ctx({"turn": int(trigger.get("turn", 0)),
		"snapshot_id": str(base.get("snapshot_id", "")),
		"roster": _vp_roster_of_obs(snap.get("victory_obs", {}))}))
	var pcode := str(parsed.get("code", "VP_INVALID_SCHEMA"))
	if not bool(parsed.get("ok", false)):
		_strict_latch("REVIEW", pcode, str(parsed.get("detail", "")), int(trigger.get("turn", 0)), call_id)
		GeneralTraceCls.note_general_disposition("REJECTED", 0, "", pcode)
		_general_pipe_stage(snap, "parse", "FAIL_" + pcode)
		snap["outcome"] = "REJECTED_" + pcode
		_general_history_append(snap)
		GeneralTraceCls.note_victory_call(latency, str(trigger.get("trigger", "")), int(trigger.get("turn", 0)), "REJECTED")
		_vp_log_attempt("REVIEW_BG", req_id, snap, res, VICTORY_REVIEW_MAX_TOKENS,
			{"parse_code": pcode, "parse_detail": str(parsed.get("detail", "")),
			"decision": str((parsed.get("review", {}) as Dictionary).get("decision", "-")), "outcome": "REJECTED"})
		_vp_audit_call(call_id, snap.get("victory_obs", {}), int(trigger.get("turn", 0)), trigger, "VICTORY_REVIEW", res,
			str((parsed.get("review", {}) as Dictionary).get("decision", "-")), "REJECTED", rev_before, rev_before, ph_before, ph_before,
			{"ok": false, "code": pcode, "detail": str(parsed.get("detail", ""))}, [], [],
			{"budget": VICTORY_REVIEW_MAX_TOKENS, "retry_of": "", "prefetch": false})
		print("[CloudTurn] GENERAL_REVIEW_FAILED_PLAN_RETAINED call=%s reason=%s" % [call_id, pcode])
		_manager.note_review_failed(trigger, pcode)
		_utility_fallback_note("REVIEW", pcode, str(parsed.get("detail", "")), int(trigger.get("turn", 0)))
		_finish_background_review(req_id)
		return
	_general_pipe_stage(snap, "parse", "PASS")
	_general_pipe_stage(snap, "contract", "PASS")
	snap["selection"] = (parsed.get("review", {}) as Dictionary).duplicate(true)
	_apply_victory_decision(parsed, snap, base, trigger, res)
	_finish_background_review(req_id)


## Apply a validated VICTORY decision: KEEP commits the review clock at
## once (no battle impact); ADVANCE/AMEND/EMERGENCY compute + validate the
## new revision and STAGE it for the next RED phase staleness gate.
func _apply_victory_decision(parsed: Dictionary, snap: Dictionary, base: Dictionary, trigger: Dictionary, res: Dictionary) -> void:
	var review: Dictionary = parsed.get("review", {})
	var decision := str(review.get("decision", ""))
	var call_id := str(snap.get("victory_call", ""))
	var latency := int(res.get("latency_ms", 0))
	var rturn := int(trigger.get("turn", 0))
	var obs_base: Dictionary = snap.get("victory_obs", {})
	var rev_before := int(_manager.vp_get_plan().get("revision", 0))
	var ph_before := str(_manager.vp_get_plan().get("current_phase_id", "-"))
	var computed := _manager.vp_compute_review(review, obs_base, rturn)
	if not bool(computed.get("ok", false)):
		_strict_latch("REVIEW", str(computed.get("code", "VP_COMPUTE")), str(computed.get("detail", "")), rturn, call_id)
		GeneralTraceCls.note_general_disposition("REJECTED", 0, "", str(computed.get("code", "VP_COMPUTE")))
		snap["outcome"] = "REJECTED_" + str(computed.get("code", "VP_COMPUTE"))
		_general_history_append(snap)
		GeneralTraceCls.note_victory_call(latency, str(trigger.get("trigger", "")), rturn, decision)
		_vp_log_attempt("REVIEW_BG", str(snap.get("request_id", "")), snap, res, VICTORY_REVIEW_MAX_TOKENS,
			{"parse_code": str(computed.get("code", "VP_COMPUTE")), "parse_detail": str(computed.get("detail", "")),
			"decision": decision, "outcome": "REJECTED"})
		_vp_audit_call(call_id, obs_base, rturn, trigger, "VICTORY_REVIEW", res, decision, "REJECTED",
			rev_before, rev_before, ph_before, ph_before,
			{"ok": false, "code": str(computed.get("code", "VP_COMPUTE")), "detail": str(computed.get("detail", ""))}, [], [],
			{"budget": VICTORY_REVIEW_MAX_TOKENS, "retry_of": "", "prefetch": false})
		print("[CloudTurn] GENERAL_REVIEW_FAILED_PLAN_RETAINED call=%s reason=%s" % [call_id, str(computed.get("code", "VP_COMPUTE"))])
		_manager.note_review_failed(trigger, str(computed.get("code", "VP_COMPUTE")))
		_utility_fallback_note("REVIEW", str(computed.get("code", "VP_COMPUTE")), str(computed.get("detail", "")), rturn)
		return
	if decision == "KEEP":
		var committed := _manager.vp_commit_review(computed, {}, rturn, str(base.get("snapshot_id", "")), str(trigger.get("trigger", "?")))
		GeneralTraceCls.note_general_disposition("KEPT", int(committed.get("revision", 0)), str(base.get("snapshot_id", "")))
		_general_pipe_stage(snap, "adoption", "KEPT_v%d" % int(committed.get("revision", 0)))
		snap["outcome"] = "KEPT_v%d" % int(committed.get("revision", 0))
		_general_history_append(snap)
		GeneralTraceCls.note_victory_call(latency, str(trigger.get("trigger", "")), rturn, "KEEP")
		_vp_log_attempt("REVIEW_BG", str(snap.get("request_id", "")), snap, res, VICTORY_REVIEW_MAX_TOKENS,
			{"parse_code": "", "parse_detail": "", "decision": "KEEP", "outcome": "KEPT"})
		_vp_audit_call(call_id, obs_base, rturn, trigger, "VICTORY_REVIEW", res, "KEEP", "KEPT",
			rev_before, int(committed.get("revision", 0)), ph_before, str(committed.get("phase", "?")),
			{"ok": true, "code": "", "detail": ""}, [], [],
			{"budget": VICTORY_REVIEW_MAX_TOKENS, "retry_of": "", "contract": str(review.get("contract", "")), "prefetch": false})
		_manager.acknowledge_review_events(trigger, "KEEP", int(committed.get("revision", 0)), "KEPT")
		print("[CloudTurn] VICTORY review KEEP confirmed (plan v%d stands)." % int(committed.get("revision", 0)))
		return
	var new_vp: Dictionary = computed.get("new_vp", {})
	var diff := VictoryPlanCls.semantic_diff(_manager.vp_get_plan(), new_vp)
	_staged_vp = {"new_vp": new_vp.duplicate(true)}
	_staged_vp_meta = (computed.get("meta", {}) as Dictionary).duplicate(true)
	_staged_vp_meta["action"] = str(computed.get("action", ""))
	_staged_vp_meta["snapshot"] = str(base.get("snapshot_id", ""))
	_staged_vp_decision = decision
	_staged_vp_call = call_id
	_staged_review = trigger.duplicate(true)
	_manager.note_review_staged(trigger, decision)
	GeneralTraceCls.note_general_disposition("STAGED", int(new_vp.get("revision", 0)), str(base.get("snapshot_id", "")))
	_general_pipe_stage(snap, "plan", "PASS_rev=%d" % int(new_vp.get("revision", 0)))
	_general_pipe_stage(snap, "adoption", "STAGED")
	snap["outcome"] = "STAGED"
	_general_history_append(snap)
	GeneralTraceCls.note_victory_call(latency, str(trigger.get("trigger", "")), rturn, decision)
	_vp_log_attempt("REVIEW_BG", str(snap.get("request_id", "")), snap, res, VICTORY_REVIEW_MAX_TOKENS,
		{"parse_code": "", "parse_detail": "", "decision": decision, "outcome": "STAGED"})
	_vp_audit_call(call_id, obs_base, rturn, trigger, "VICTORY_REVIEW", res, decision, "STAGED",
		rev_before, int(new_vp.get("revision", 0)), ph_before, str(new_vp.get("current_phase_id", "?")),
		{"ok": true, "code": "", "detail": ""}, diff.get("changed", []), diff.get("mission_changes", []),
		{"budget": VICTORY_REVIEW_MAX_TOKENS, "retry_of": "", "contract": str(review.get("contract", "")), "prefetch": false})
	print("[CloudTurn] VICTORY review %s STAGED (rev %d; applies at next %s phase after staleness gate)." % [decision, int(new_vp.get("revision", 0)), _SIDE()])


## Background collector: waits for the review flight, validates the reply,
## and stages ADJUST/REPLAN results (or confirms KEEP). Produces
## PROPOSED_PLAN_UPDATE only ??application happens at the next RED phase
## start after the staleness gate. KEEP touches only the review clock.
func _collect_background_review(req_id: String, base: Dictionary, trigger: Dictionary, snap: Dictionary) -> void:
	var budget_ms := int((brain_timeout_sec() + 10.0) * 1000.0)
	if _uses_agent_backend():
		budget_ms *= 4 # EXTERNAL_AGENT / DEBUG_AGENT (dev): agent submissions arrive from outside the engine.
	var t0 := Time.get_ticks_msec()
	while _review_in_flight == req_id and str(_general_result.get("request_id", "")) != req_id:
		if get_tree() == null:
			_manager.note_review_failed(trigger, "TREE_UNAVAILABLE")
			_finish_background_review(req_id)
			return
		await get_tree().process_frame
		if Time.get_ticks_msec() - t0 > budget_ms:
			break
	if _review_in_flight != req_id:
		_manager.note_review_failed(trigger, "SUPERSEDED")
		return # superseded by a blocking call; _set_flight archived our snap
	var res := _general_result.duplicate(true)
	if str(res.get("request_id", "")) != req_id:
		_general_pipe_stage(snap, "transport", "TIMEOUT_WAIT")
		snap["outcome"] = "TIMEOUT_WAIT"
		snap["ended_ms"] = Time.get_ticks_msec()
		_general_history_append(snap)
		print("[CloudTurn] HIER background review timed out waiting for %s" % req_id)
		_manager.note_review_failed(trigger, "TIMEOUT_WAIT")
		_finish_background_review(req_id)
		return
	_general_snap_response(snap, res)
	var latency := int(res.get("latency_ms", 0))
	GeneralTraceCls.note_general_call(latency, str(trigger.get("trigger", "")) + "_BG", int(trigger.get("turn", 0)))
	if not bool(res.get("ok", false)):
		GeneralTraceCls.note_general_disposition("REJECTED", 0, "", str(res.get("code", "PROVIDER_ERROR")))
		snap["outcome"] = "FAILED_" + str(res.get("code", "PROVIDER_ERROR"))
		_general_history_append(snap)
		print("[CloudTurn] GENERAL_RESPONSE_ERROR (background): %s ??%s" % [
			str(res.get("code", "")), str(res.get("detail", "")).left(200)])
		_manager.note_review_failed(trigger, str(res.get("code", "PROVIDER_ERROR")))
		_finish_background_review(req_id)
		return
	var menu: Dictionary = snap.get("menu", {})
	var baseline := _manager.get_coordination()
	var final_text := str(res.get("content_text", ""))
	snap["parser_input_chars"] = final_text.length()
	snap["parser_input_match"] = final_text == str(snap.get("response_text", ""))
	var parsed := CoordResponseCls.parse_review(final_text, {"menu": menu,
		"snapshot_id": str(base.get("snapshot_id", "")), "turn": int(trigger.get("turn", 0)),
		"baseline": baseline, "has_baseline": not baseline.is_empty()})
	var pcode := str(parsed.get("code", "COORD_INVALID_SCHEMA"))
	if not bool(parsed.get("json_ok", false)):
		_general_pipe_stage(snap, "parse", "FAIL_" + pcode)
		_general_pipe_stage(snap, "contract", "UNREACHED")
	elif not bool(parsed.get("ok", false)):
		_general_pipe_stage(snap, "parse", "PASS")
		_general_pipe_stage(snap, "contract", "FAIL_" + pcode)
	else:
		_general_pipe_stage(snap, "parse", "PASS")
		_general_pipe_stage(snap, "contract", "PASS")
		snap["selection"] = (parsed.get("review", {}) as Dictionary).duplicate(true)
	if not bool(parsed.get("ok", false)):
		_strict_latch("REVIEW", pcode, str(parsed.get("detail", "")), int(trigger.get("turn", 0)), str(snap.get("victory_call", "")))
		GeneralTraceCls.note_general_disposition("REJECTED", 0, "", pcode)
		snap["outcome"] = "REJECTED_" + pcode
		_general_history_append(snap)
		print("[CloudTurn] GENERAL_RESPONSE_ERROR (background): %s ??%s" % [
			pcode, str(parsed.get("detail", "")).left(200)])
		_manager.note_review_failed(trigger, pcode)
		_utility_fallback_note("REVIEW", pcode, str(parsed.get("detail", "")), int(trigger.get("turn", 0)))
		_finish_background_review(req_id)
		return
	_collect_background_decision(parsed, snap, menu, base, trigger, res)
	_finish_background_review(req_id)


func _finish_background_review(req_id: String) -> void:
	if _review_in_flight == req_id:
		_review_in_flight = ""
	if str(_agent_parked.get("request_id", "")) == req_id:
		_agent_parked = {} # timed-out/superseded park can never be completed
	_clear_flight(req_id)


## Apply a validated REVIEW decision: KEEP confirms the review clock at
## once (no battle impact); ADJUST/REPLAN expand through Godot templates and
## STAGE the result for the next RED phase staleness gate.
func _collect_background_decision(parsed: Dictionary, snap: Dictionary, menu: Dictionary, base: Dictionary, trigger: Dictionary, res: Dictionary) -> void:
	var review: Dictionary = parsed.get("review", {})
	var decision := str(review.get("decision", ""))
	var warnings: Array = (parsed.get("warnings", []) as Array).duplicate(true)
	var rturn := int(trigger.get("turn", 0))
	if decision == "KEEP":
		var kept := _manager.confirm_plan(rturn, review.get("hypotheses", []), bool(review.get("has_hypotheses", false)))
		if not bool(kept.get("ok", false)):
			GeneralTraceCls.note_general_disposition("REJECTED", 0, "", str(kept.get("code", "COORD_NO_PLAN")))
			snap["outcome"] = "REJECTED_" + str(kept.get("code", "COORD_NO_PLAN"))
			_general_history_append(snap)
			print("[CloudTurn] GENERAL_RESPONSE_ERROR (background): %s" % str(kept.get("code", "")))
			_manager.note_review_failed(trigger, str(kept.get("code", "COORD_NO_PLAN")))
			return
		GeneralTraceCls.note_general_disposition("KEPT", int(kept.get("version", 0)), str(base.get("snapshot_id", "")))
		_general_pipe_stage(snap, "adoption", "KEPT_v%d" % int(kept.get("version", 0)))
		snap["outcome"] = "KEPT_v%d" % int(kept.get("version", 0))
		snap["warnings"] = warnings
		_general_history_append(snap)
		_manager.acknowledge_review_events(trigger, "KEEP", int(kept.get("version", 0)), "KEPT")
		print("[CloudTurn] HIER review KEEP confirmed (plan v%d stands)." % int(kept.get("version", 0)))
		return
	var mission: Dictionary = (_manager.get_plan().get("mission", {}) as Dictionary).duplicate(true)
	var expanded := {}
	if decision == "ADJUST":
		expanded = CoordMenuCls.expand_adjust(menu, _manager.get_coordination(),
			review.get("changes", []), rturn, str(base.get("snapshot_id", "")), mission,
			_manager.get_plan(), warnings, review.get("doctrine_override", {}),
			review.get("hypotheses", []), bool(review.get("has_hypotheses", false)))
	else:
		expanded = CoordMenuCls.expand_initial(menu, review.get("selection", {}), rturn,
			str(base.get("snapshot_id", "")), mission, warnings)
	if not bool(expanded.get("ok", false)):
		_general_pipe_stage(snap, "plan", "FAIL_" + str(expanded.get("code", "COORD_EXPAND_INVALID")))
		GeneralTraceCls.note_general_disposition("REJECTED", 0, "", str(expanded.get("code", "COORD_EXPAND_INVALID")))
		snap["outcome"] = "EXPAND_FAIL_" + str(expanded.get("code", "COORD_EXPAND_INVALID"))
		_general_history_append(snap)
		print("[CloudTurn] GENERAL_RESPONSE_ERROR (background): %s ??%s" % [
			str(expanded.get("code", "")), str(expanded.get("detail", "")).left(200)])
		_manager.note_review_failed(trigger, str(expanded.get("code", "COORD_EXPAND_INVALID")))
		return
	_staged_plan = (expanded.get("plan", {}) as Dictionary).duplicate(true)
	_staged_plan["based_on_snapshot"] = str(base.get("snapshot_id", ""))
	_staged_coord = {"choices": (expanded.get("choices", {}) as Dictionary).duplicate(true),
		"menu_snapshot": str(menu.get("snapshot_id", "")), "turn": rturn,
		"warnings": (expanded.get("warnings", []) as Array).duplicate(true)}
	_staged_review = trigger.duplicate(true)
	_staged_review_decision = decision
	_manager.note_review_staged(trigger, decision)
	var expect_v := int(_manager.get_plan().get("plan_version", 0)) + 1
	GeneralTraceCls.note_general_disposition("STAGED", expect_v, str(base.get("snapshot_id", "")))
	_general_pipe_stage(snap, "plan", "PASS_missions=%d" % ((expanded.get("missions", []) as Array).size()))
	_general_pipe_stage(snap, "adoption", "STAGED")
	snap["expansion"] = {"choices": (expanded.get("choices", {}) as Dictionary).duplicate(true),
		"missions": (expanded.get("missions", []) as Array).duplicate(true)}
	snap["warnings"] = (expanded.get("warnings", []) as Array).duplicate(true)
	snap["outcome"] = "STAGED"
	_general_history_append(snap)
	print("[CloudTurn] HIER review %s STAGED (%s; applies at next %s phase after staleness gate)." % [
		decision, CoordMenuCls.render_choices_text(expanded.get("choices", {})), _SIDE()])


func _adopt_staged_if_fresh(obs: Dictionary, turn: int) -> void:
	if not _staged_vp.is_empty():
		_adopt_staged_victory(obs, turn)
		return
	if _staged_plan.is_empty():
		return
	var check := _manager.staged_staleness(_staged_plan, _review_base, obs)
	if bool(check.get("stale", false)):
		GeneralTraceCls.note_general_disposition("STALE", 0, "", str(check.get("reason", "STALE")))
		print("[CloudTurn] HIER staged plan STALE (%s) ??keeping current plan." % str(check.get("reason", "")))
		_manager.note_review_stale(_staged_review, str(check.get("reason", "STALE")))
		_staged_plan = {}
		_staged_coord = {}
		_staged_review = {}
		_staged_review_decision = ""
		_review_base = {}
		return
	var applied := _manager.apply_plan(_staged_plan, turn, str(obs.get("snapshot_id", "")),
		str(obs.get("battle_id", "")))
	if bool(applied.get("ok", false)):
		_manager.bind_coordination(_staged_coord)
		_manager.acknowledge_review_events(_staged_review, _staged_review_decision,
			int(applied.get("version", 0)), "ADOPTED")
		GeneralTraceCls.note_general_disposition("APPLIED", int(applied.get("version", 0)), str(obs.get("snapshot_id", "")))
		print("[CloudTurn] GENERAL_PLAN_ADOPTED v%d (staged; decision=%s)." % [
			int(applied.get("version", 0)), _staged_review_decision])
	else:
		GeneralTraceCls.note_general_disposition("REJECTED", 0, "", str(applied.get("code", "")))
		_manager.note_review_failed(_staged_review, str(applied.get("code", "PLAN_REJECTED")))
		print("[CloudTurn] HIER staged plan REJECTED at apply: %s" % str(applied.get("code", "")))
	_staged_plan = {}
	_staged_coord = {}
	_staged_review = {}
	_staged_review_decision = ""
	_review_base = {}


## VICTORY PLAN V0 (additive): adopt (or discard as stale) a staged
## victory revision at the RED phase boundary. Never mid-turn, never blindly.
func _adopt_staged_victory(obs: Dictionary, turn: int) -> void:
	var probe := {"based_on_snapshot": str(_staged_vp_meta.get("snapshot", ""))}
	var check := _manager.staged_staleness(probe, _review_base, obs)
	if bool(check.get("stale", false)):
		GeneralTraceCls.note_general_disposition("STALE", 0, "", str(check.get("reason", "STALE")))
		print("[CloudTurn] VICTORY staged rev STALE (%s) ??keeping current plan." % str(check.get("reason", "")))
		_manager.note_review_stale(_staged_review, str(check.get("reason", "STALE")))
		_manager.vp_audit_update(_staged_vp_call, {"outcome": "STAGED_STALE"})
		_staged_vp = {}
		_staged_vp_meta = {}
		_staged_vp_decision = ""
		_staged_vp_call = ""
		_staged_review = {}
		_review_base = {}
		return
	var adopted := _manager.vp_adopt_staged(_staged_vp, _staged_vp_meta,
		(obs.get("mission", {}) as Dictionary).duplicate(true), turn,
		str(obs.get("snapshot_id", "")), str(_staged_review.get("trigger", "?")))
	if bool(adopted.get("ok", false)):
		_manager.acknowledge_review_events(_staged_review, _staged_vp_decision,
			int(adopted.get("revision", 0)), "ADOPTED")
		GeneralTraceCls.note_general_disposition("APPLIED", int(adopted.get("revision", 0)), str(obs.get("snapshot_id", "")))
		_manager.vp_audit_update(_staged_vp_call, {"outcome": "STAGED_ADOPTED",
			"revision_after": int(adopted.get("revision", 0)), "phase_after": str(adopted.get("phase", "?"))})
		print("[CloudTurn] VICTORY_PLAN_ADOPTED v%d (staged; decision=%s phase=%s)." % [
			int(adopted.get("revision", 0)), _staged_vp_decision, str(adopted.get("phase", "?"))])
	else:
		GeneralTraceCls.note_general_disposition("REJECTED", 0, "", str(adopted.get("code", "")))
		_manager.note_review_failed(_staged_review, str(adopted.get("code", "VP_STAGED")))
		_manager.vp_audit_update(_staged_vp_call, {"outcome": "STAGED_REJECTED"})
		print("[CloudTurn] VICTORY staged rev REJECTED at adopt: %s ??keeping current plan." % str(adopted.get("code", "")))
	_staged_vp = {}
	_staged_vp_meta = {}
	_staged_vp_decision = ""
	_staged_vp_call = ""
	_staged_review = {}
	_review_base = {}


## Non-secret backend label for audit rows (provider/model only).
func _vp_backend_label() -> String:
	if _uses_agent_backend():
		return "%s/agent" % _agent_provider_label()
	var prov := str(_config.provider_id) if _config != null else "?"
	var mdl := str(_config.model) if _config != null else "?"
	return "%s/%s" % [prov, mdl]


## Append one General-invocation audit row. why = the concrete causal
## reason (trigger reason + General's own reason when present). extra:
## {budget, retry_of, contract, prefetch} (repair V1 diagnostics).
func _vp_audit_call(call_id: String, obs: Dictionary, turn: int, trigger: Dictionary, req_type: String,
		model_res: Dictionary, decision: String, outcome: String, rev_before: int, rev_after: int,
		ph_before: String, ph_after: String, validation: Dictionary, changed: Array, mission_changes: Array,
		extra: Dictionary = {}) -> void:
	var why := str(trigger.get("reason", ""))
	var env: Dictionary = model_res.get("envelope", {}) as Dictionary
	_manager.vp_audit_record({
		"call_id": call_id, "turn": turn, "side": _SIDE(), "battle_id": str(obs.get("battle_id", "")),
		"snapshot_id": str(obs.get("snapshot_id", "")), "backend": _vp_backend_label(),
		"trigger": str(trigger.get("trigger", "?")), "why": why, "request_type": req_type,
		"latency_ms": int(model_res.get("latency_ms", 0)), "http_status": str(model_res.get("http_status", "?")),
		"finish_reason": str(model_res.get("finish_reason", env.get("finish_reason", ""))),
		"final_chars": str(model_res.get("content_text", "")).length(),
		"reasoning_present": bool(env.get("reasoning_present", false)),
		"reasoning_chars": int(env.get("reasoning_chars", 0)),
		"usage": (env.get("usage", {}) as Dictionary).duplicate(true),
		"output_budget": int(extra.get("budget", 0)),
		"retry_of": str(extra.get("retry_of", "")),
		"contract": str(extra.get("contract", "")),
		"prefetch": bool(extra.get("prefetch", false)),
		"provider_outcome": ("ok" if bool(model_res.get("ok", false)) else str(model_res.get("code", "PROVIDER_ERROR"))),
		"provider_message": str(model_res.get("provider_message", "")),
		"decision": decision, "outcome": outcome, "revision_before": rev_before, "revision_after": rev_after,
		"phase_before": ph_before, "phase_after": ph_after, "validation": validation,
		"change_summary": changed, "mission_changes": mission_changes, "laya_notified": false,
	})


func _wait_for_general(req_id: String, budget_ms: int = 0) -> Dictionary:
	var budget := budget_ms if budget_ms > 0 else int((brain_timeout_sec() + 20.0) * 1000.0)
	if _uses_agent_backend() and budget_ms <= 0:
		budget *= 4 # EXTERNAL_AGENT / DEBUG_AGENT (dev): the agent submits from outside the engine.
	var t0 := Time.get_ticks_msec()
	var frames := 0
	while _general_result.is_empty() or str(_general_result.get("request_id", "")) != req_id:
		await get_tree().process_frame
		frames += 1
		_watchdog_tick(frames, "general " + req_id)
		if Time.get_ticks_msec() - t0 > budget:
			print("[CloudTurn] WAIT_TIMEOUT general %s after %ds ??abandoning wait." % [req_id, int(budget / 1000)])
			return {"ok": false, "code": "TIMEOUT", "request_id": req_id,
				"detail": "No provider response within %d s; the wait was abandoned." % int(budget / 1000),
				"http_status": 0, "latency_ms": Time.get_ticks_msec() - t0,
				"provider": _config.provider_id, "model": _config.model, "envelope": {}}
	return _general_result.duplicate(true)


# --- waits ---------------------------------------------------------------

func _pause_point(note: String) -> void:
	if not _paused:
		return
	var prev := str(_state.get("phase", ""))
	_set_state("PAUSED", note)
	while _paused:
		await get_tree().process_frame
	_set_state(prev if not prev.is_empty() else "IDLE", "Resumed.")


func _wait_for_decision() -> String:
	_decision = ""
	var frames := 0
	while _decision.is_empty():
		await get_tree().process_frame
		frames += 1
		_watchdog_tick(frames, "decision")
	var d := _decision
	_decision = ""
	return d


## Watchdog: a Cloud wait must never sit silent. Every 30 s the current
## state is re-announced (log + state signal, which the mount mirrors onto
## the battlefield banner). It never auto-decides ??the human (or test)
## still owns retry/skip/hold.
func _watchdog_tick(frames: int, waiting_for: String) -> void:
	if frames % 1800 != 0:
		return
	print("[CloudTurn] WATCHDOG still waiting (%ds) for %s: phase=%s note=%s" % [
		frames / 60, waiting_for, str(_state.get("phase", "")), str(_state.get("note", ""))])
	cloud_state_changed.emit(_state.duplicate(true))


## Bounded model waits: the adapter's HTTP timeout normally resolves every
## flight, but a lost result (killed scene timing, dropped signal) must fail
## the phase PRECISELY instead of spinning silently forever. The budget sits
## past the flight's own HTTP timeout, so a healthy lane never trips it; the
## watchdog keeps long-but-legit General waits visibly alive meanwhile.
func _wait_for_model(req_id: String, budget_ms: int = 0) -> Dictionary:
	var budget := budget_ms if budget_ms > 0 else int((_config.timeout_sec + 20.0) * 1000.0)
	var t0 := Time.get_ticks_msec()
	var frames := 0
	while _model_result.is_empty() or str(_model_result.get("request_id", "")) != req_id:
		await get_tree().process_frame
		frames += 1
		_watchdog_tick(frames, "model " + req_id)
		if Time.get_ticks_msec() - t0 > budget:
			print("[CloudTurn] WAIT_TIMEOUT model %s after %ds ??abandoning wait." % [req_id, int(budget / 1000)])
			return {"ok": false, "code": "TIMEOUT", "request_id": req_id,
				"detail": "No provider response within %d s; the wait was abandoned." % int(budget / 1000),
				"http_status": 0, "latency_ms": Time.get_ticks_msec() - t0,
				"provider": _config.provider_id, "model": _config.model, "envelope": {}}
	return _model_result.duplicate(true)


func _wait_for_exec() -> Dictionary:
	var seen := _exec_seen
	while _exec_seen == seen or _exec_result.is_empty():
		await get_tree().process_frame
	return _exec_result.duplicate(true)


func _on_model_done(request_id: String, result: Dictionary) -> void:
	# General review flights (blocking or background) carry the general_
	# prefix and land in their own slot; tactical flights keep the legacy
	# slot. A late background result can therefore never corrupt a RED
	# phase wait (or vice versa).
	if request_id.begins_with(GENERAL_REQUEST_PREFIX):
		_general_result = result.duplicate(true)
		_general_result["request_id"] = request_id
		return
	_model_result = result.duplicate(true)
	_model_result["request_id"] = request_id


func _on_exec_finished(result: Dictionary) -> void:
	_exec_seen += 1
	_exec_result = result.duplicate(true)


# --- helpers ---------------------------------------------------------------

## failure_class names WHAT failed for FAILED_* phases so the UI never
## mislabels a General plan parse/validation failure as a transport outage:
## "transport" (HTTP/provider/envelope), "general_plan" (General JSON/schema/
## plan/adoption), "tactical_plan" (legacy order validation), "observation".
## Empty for non-failure phases; stale classes never linger.
func _set_state(phase: String, note: String, failure_class: String = "") -> void:
	_state["phase"] = phase
	_state["note"] = note
	_state["mode"] = _mode
	_state["paused"] = _paused
	_state["phase_active"] = _phase_active
	_state["failure_class"] = failure_class if phase.begins_with("FAILED") else ""
	cloud_state_changed.emit(_state.duplicate(true))


func _current_turn() -> int:
	if _bridge == null:
		return 0
	var mgr: RefCounted = _bridge.get_manager()
	if mgr == null:
		return 0
	return int(mgr.get_current_turn())


func _failure_view(obs: Dictionary, turn: int, pre_fp: String, code: String, detail: String, latency: int, model_res: Dictionary = {}, auto_retries: int = 0) -> Dictionary:
	var env := {}
	if model_res.get("envelope") is Dictionary:
		env = (model_res.get("envelope") as Dictionary).duplicate(true)
	var diag := {
		"code": code,
		"http_status": int(model_res.get("http_status", 0)) if not model_res.is_empty() else 0,
		"finish_reason": str(env.get("finish_reason", model_res.get("finish_reason", ""))),
		"content_chars": int(env.get("content_chars", 0)),
		"content_type": str(env.get("content_type", "")),
		"reasoning_present": bool(env.get("reasoning_present", false)),
		"reasoning_chars": int(env.get("reasoning_chars", 0)),
		"refusal_present": bool(env.get("refusal_present", false)),
		"tool_calls": int(env.get("tool_calls", 0)),
		"response_chars": int(env.get("response_chars", 0)),
		"sse_suspected": bool(env.get("sse_suspected", false)),
		"auto_retries": auto_retries,
	}
	return {
		"model": _config.model, "provider": _config.provider_id,
		"turn": turn, "latency_ms": latency,
		"snapshot_id": str(obs.get("snapshot_id", "")),
		"state_version": int((obs.get("parity", {}) as Dictionary).get("state_version", -1)),
		"plan": {}, "rationale": {}, "orders": [],
		"order_count": 0, "executed_count": 0, "rejected_count": 0,
		"pre_fingerprint": pre_fp, "post_fingerprint": str(_bridge.fingerprint()),
		"status": "FAILED_" + code,
		"failure": {"code": code, "detail": detail},
		"diag": diag,
		"summary": "FAILED_%s: %s" % [code, detail],
	}
