class_name Step7AdvisorAdapter
extends Node

## Deterministic Advisor integration boundary (player/advisor milestone).
##
## Responsibilities ONLY:
##   selected unit / scope -> request current evaluator package ->
##   translate package to UI-safe view model -> request preview ->
##   request execution.
##
## Must NOT own: legality (ActionService), tactical scoring (Evaluator),
## movement state (UnitManager/shell), hidden truth (WorldTruth).
##
## Shared-truth contract (§21): the package is produced by the SAME
## Step7CavalryEvaluator.evaluate() call shape the DEV cavalry panel uses
## (ADVANCE/FORWARD intent, BLUE knowledge, BLUE-known occupancy, state
## version + fingerprint). The Advisor never computes options separately.
##
## Transactionality (§36): every entry point clears stale preview /
## selection / status / overlay state BEFORE presenting new state.

const EvaluatorScript = preload("res://scripts/step7/step7_cavalry_evaluator.gd")
const ClustersScript = preload("res://scripts/step7/step7_formation_clusters.gd")
const ViewModelScript = preload("res://scripts/step7/step7_advisor_viewmodel.gd")
const ContextScript = preload("res://scripts/step7/step7_advisor_context.gd")
const SelectorScript = preload("res://scripts/step7/step7_advisor_llm_selector.gd")
const CommanderScript = preload("res://scripts/step7/step7_chat_commander.gd")
const DevModeScript = preload("res://scripts/step7/step7_dev_mode.gd")
const BackendCfgScript = preload("res://scripts/ai/ai_backend_config.gd")

const DEFAULT_INTENT := {"action": "ADVANCE", "direction": "FORWARD"}

var _integration: Node = null
var _truth: RefCounted = null
var _command_service: RefCounted = null
var _projector: RefCounted = null
var _action_service: RefCounted = null
var _overlay: Node2D = null
var _unit_manager: RefCounted = null
var _window = null # Step7AdvisorWindow (untyped: avoids cyclic class ref)
var _evaluator: RefCounted = null
var _selector: Node = null # Step7AdvisorLLMSelector (Ollama tactical Advisor)
var _commander = null # Step7ChatCommander (chat-driven commander, PLAYER flow)

# Chat execution state (staged COMMAND approval): sequential per-unit MOVEs,
# per-unit HOLDs, one native plan, or ONE composite (moves then holds).
# Exactly one chat execution at a time.
var _chat_queue: Array = []
var _chat_holds: Array = []
var _chat_native := {}
var _chat_kind := "" # moves | holds | native | composite
var _chat_command_id := ""
var _chat_done_cb := Callable()
var _chat_moved := 0
var _chat_failed: Array = []
# Execution-time honesty records (Failure B fix): planned destinations for
# short-stop detection, exec-time fallback adaptations, short landings.
var _chat_planned := {} # unit_id -> [q, r] promised at stage time
var _chat_exec_adapted: Array = [] # [{unit_id, destination{q,r}}]
var _chat_short: Array = [] # [{unit_id, planned[q,r], landed[q,r]}]
# Composite accounting: initial moves/holds membership for the mixed
# completion text (failed rows are classified by membership).
var _chat_comp_moves: Array = []
var _chat_comp_holds: Array = []

var _package: Dictionary = {}
var _cards: Array = []
var _picked := -1 # option slot 1..6, -1 = none
var _unit_id := ""

# Ollama Advisor lifecycle: one active inference at most, keyed by the exact
# deterministic snapshot it reasoned over. The recommendation highlights a
# card only; the player always picks and executes through the canonical path.
var _llm_key := "" # unit|version|fingerprint dedup key
var _llm_request_id := ""
var _llm_rec := {} # validated current recommendation (or empty)
var _llm_seq := 0


func setup(deps: Dictionary) -> void:
	_integration = deps.get("integration") as Node
	_truth = deps.get("truth") as RefCounted
	_command_service = deps.get("command_service") as RefCounted
	_projector = deps.get("projector") as RefCounted
	_action_service = deps.get("action_service") as RefCounted
	_overlay = deps.get("overlay") as Node2D
	_unit_manager = deps.get("unit_manager") as RefCounted
	_window = deps.get("window")
	_evaluator = EvaluatorScript.new()
	_selector = SelectorScript.new()
	_selector.name = "AdvisorLLMSelector"
	add_child(_selector)
	_selector.state_provider = Callable(self, "_current_llm_snapshot")
	_selector.recommendation_ready.connect(_on_llm_ready)
	_selector.recommendation_failed.connect(_on_llm_failed)
	_commander = CommanderScript.new()
	_commander.name = "ChatCommander"
	add_child(_commander)
	_commander.setup({
		"integration": _integration, "truth": _truth,
		"command_service": _command_service, "projector": _projector,
		"action_service": _action_service, "overlay": _overlay,
		"unit_manager": _unit_manager, "adapter": self})
	_commander.chat_append.connect(_on_chat_append)
	_commander.chat_busy.connect(_on_chat_busy)
	_commander.command_finished.connect(_on_chat_command_finished)
	if _action_service != null and _action_service.has_signal("execution_finished"):
		_action_service.connect("execution_finished", Callable(self, "_on_execution_finished"))


func is_ready() -> bool:
	return _integration != null and _truth != null and _command_service != null \
		and _projector != null and _action_service != null and _unit_manager != null \
		and _window != null


# --- Panel-state transactionality --------------------------------------

func _clear_state() -> void:
	_package = {}
	_cards = []
	_picked = -1
	_unit_id = ""
	_llm_key = ""
	_llm_request_id = ""
	_llm_rec = {}
	if _selector != null and _selector.has_method("cancel"):
		_selector.cancel()
	if _commander != null and _commander.has_method("cancel_active_only"):
		_commander.cancel_active_only()
	# A validated staged plan (and its map preview) survives selection
	# changes: selection mutates no state, approval re-checks drift.
	var staged_alive: bool = _commander != null and _commander.has_method("has_staged") \
		and bool(_commander.has_staged())
	if not staged_alive and _overlay != null and _overlay.has_method("set_routes"):
		_overlay.set_routes([])
	if _window != null:
		_window.clear_preview_state()
		if _window.has_method("clear_llm_state"):
			_window.clear_llm_state()


func _selected_blue_unit() -> Dictionary:
	if _unit_manager == null or not _unit_manager.has_method("is_unit_selected"):
		return {}
	if not bool(_unit_manager.is_unit_selected()):
		return {}
	var u: Dictionary = _unit_manager.get_selected_unit()
	if str(u.get("faction", "")) != "blue":
		return {}
	return u


# --- Selection / turn synchronization -----------------------------------

## Canonical entry (§3): re-read the SAME selection state the battlefield
## uses and refresh. The Advisor keeps no independent selected unit.
func refresh_from_current_selection() -> void:
	notify_selection()


## Map selection changed (or Advisor opened): transactional refresh.
func notify_selection() -> void:
	if not is_ready():
		return
	var had_state := not _unit_id.is_empty() or not _package.is_empty()
	_clear_state()
	var u := _selected_blue_unit()
	if u.is_empty():
		_window.show_neutral()
		if had_state:
			print("[Advisor] selection cleared -> neutral")
		return
	var cls := str(u.get("class", "")).to_lower()
	if cls != "cavalry":
		_window.show_unsupported(str(u.get("id", "?")), ViewModelScript.class_kr(cls))
		print("[Advisor] %s is %s -> unsupported-class state" % [str(u.get("id", "?")), cls])
		return
	_evaluate_selected(u)


## Turn advanced: stale plan cleared, cluster/options refreshed.
func notify_turn() -> void:
	notify_selection()


## Advisor closed: return the battlefield to its normal presentation.
func notify_closed() -> void:
	_clear_state()
	set_tactical_overlay(false)


func _evaluate_selected(u: Dictionary) -> void:
	_unit_id = str(u.get("id", ""))
	var bk: Dictionary = _integration.call("get_blue_knowledge")
	var occ: Dictionary = _projector.known_occupancy("blue")
	var grid: Node = _integration.get("hex_grid") as Node
	var cell_data: Dictionary = grid.get("cell_data") as Dictionary if grid else {}
	var pkg: Dictionary = _evaluator.evaluate(_unit_id, DEFAULT_INTENT,
		_command_service, bk, cell_data, occ,
		int(_truth.get_version()), str(_truth.fingerprint()))
	if not bool(pkg.get("ok", false)):
		_window.show_neutral()
		_window.set_status("현재 부대의 전술안을 만들 수 없습니다.")
		print("[Advisor] evaluate failed for %s: %s" % [_unit_id, str(pkg.get("error", "?"))])
		return
	_package = pkg
	_cards = ViewModelScript.option_cards(pkg)
	var cluster := ClustersScript.cluster_of_unit(u)
	var cluster_txt := ViewModelScript.cluster_display(
		cluster, ClustersScript.extreme_left(), ClustersScript.extreme_right())
	var members: Array = ClustersScript.resolve_cluster_class(
		cluster, "CAVALRY", "blue", _unit_manager)
	var scope_txt := "작전 구역: %s" % cluster_txt
	if not cluster.is_empty() and not members.is_empty():
		scope_txt += "  ·  같은 구역 아군 기병 %d기" % members.size()
	var briefing := "균형 기동을 기본안으로 여섯 가지 기동 방침을 올립니다. 안을 고르시면 전장에 예상 경로를 표시합니다."
	# BALANCED is the neutral default (§26): surfaced in briefing copy only,
	# never auto-selected or auto-executed.
	_window.show_unit(
		"현재 부대: %s · 기병대" % _unit_id, scope_txt, briefing, _cards)
	print("[Advisor] %s cavalry @ (%d,%d) cluster=%s cards=%d" % [_unit_id,
		int(u.get("q", 0)), int(u.get("r", 0)), cluster if not cluster.is_empty() else "—", _cards.size()])
	_maybe_request_llm(u, bk, cell_data)


# --- Option select / preview / cancel ------------------------------------

func select_option(slot: int) -> void:
	if _package.is_empty() or _cards.is_empty():
		return
	var card := _card_for_slot(slot)
	if card.is_empty() or not bool(card.get("available", false)):
		return
	_picked = slot
	var opt := _option_for_slot(slot)
	if opt.is_empty() or not opt.has("destination"):
		_window.set_status("선택한 안은 현재 실행할 수 없습니다.")
		return
	_preview_option(opt)
	var detail := "%s — %s\n%s" % [
		str(card.get("title", "?")), "제한적" if str(card.get("status", "")) == "DEGRADED" else "실행 가능",
		str(card.get("summary", ""))]
	if str(card.get("note", "")).length() > 0:
		detail += "\n" + str(card.get("note", ""))
	_window.set_selected(slot, detail, true)
	_window.set_status("지도에 예상 경로를 표시합니다. [실행] 또는 [취소]하십시오.")


## Preview reuses the existing Step7 shared overlay (same surface the DEV
## panels preview on). No Advisor-only preview implementation.
func _preview_option(opt: Dictionary) -> void:
	if _overlay == null or not _overlay.has_method("set_routes"):
		return
	var cells: Array = []
	for p in ((opt.get("route", {}) as Dictionary).get("path", []) as Array):
		if p is Array and (p as Array).size() == 2:
			cells.append(p)
	_overlay.set_routes([{"path_cells": cells}])


func cancel() -> void:
	if _package.is_empty():
		return
	# Keep the six cards; drop only the armed selection + preview.
	_picked = -1
	if _overlay != null and _overlay.has_method("set_routes"):
		_overlay.set_routes([])
	_window.clear_preview_state()
	_window.set_status("선택을 취소했습니다. 다른 안을 고르실 수 있습니다.")


# --- Canonical execution --------------------------------------------------

## Advisor option execution converges into the existing deterministic path:
## normalized ActionCommand -> ActionService validate/plan -> execute_plan ->
## BattleCommandService/UnitManager -> shell movement animation. No direct
## position changes, no second execution path.
func execute_selected() -> void:
	if _picked < 0 or _package.is_empty():
		return
	var opt := _option_for_slot(_picked)
	if opt.is_empty() or not opt.has("destination"):
		_window.set_status("선택한 안은 현재 실행할 수 없습니다.")
		return
	if _action_service.is_executing():
		_window.set_status("다른 부대가 이동 중입니다. 잠시 후 다시 시도하십시오.")
		return
	var d: Dictionary = opt["destination"]
	var cmd := {"action": "MOVE",
		"scope": {"type": "UNIT_ID", "unit_id": str(_package.get("unit_id", _unit_id))},
		"direction": "", "target": {"type": "HEX", "q": int(d.get("q", 0)), "r": int(d.get("r", 0))},
		"posture": "NORMAL", "constraints": {}}
	var vd: Dictionary = _action_service.validate_action(cmd, "blue")
	if not bool(vd.get("ok", false)):
		_window.set_status("현재 조건에서 실행할 수 없습니다. 다른 안을 고르십시오.")
		push_warning("[Advisor] evaluator pick failed canonical validation")
		return
	var plan: Dictionary = _action_service.plan_action(cmd, "blue")
	_window.set_busy(true)
	var ex: Dictionary = _action_service.execute_plan(str(plan.get("plan_id", "")))
	if str(ex.get("execution_status", "")) != "IN_PROGRESS":
		_window.set_busy(false)
		_after_execution(ex)


func _on_execution_finished(result: Dictionary) -> void:
	if not is_ready():
		return
	if not _chat_command_id.is_empty():
		_chat_moved += ((result.get("executed_units", []) as Array).size())
		for f in (result.get("failed_units", []) as Array):
			_chat_failed.append(f)
		_note_short_landings(result.get("executed_units", []))
		if not _chat_holds.is_empty():
			_execute_next_chat_hold()
			return
		_execute_next_chat_move()
		return
	_window.set_busy(false)
	_after_execution(result)
	# Canonical finalization done: re-read CURRENT cluster membership (§34).
	notify_selection()


func _after_execution(result: Dictionary) -> void:
	var ok_count := (result.get("executed_units", []) as Array).size()
	var fail_count := (result.get("failed_units", []) as Array).size()
	if str(result.get("execution_status", "")) == "EXECUTED" and fail_count == 0:
		_window.set_status("이동을 완료했습니다. (%d기)" % ok_count)
	elif fail_count > 0:
		_window.set_status("이동이 일부 실패했습니다. (성공 %d기 / 실패 %d기)" % [ok_count, fail_count])
	else:
		_window.set_status("이행 상태: %s" % str(result.get("execution_status", "?")))


# --- Tactical overlay request ---------------------------------------------

func set_tactical_overlay(want: bool) -> void:
	if _integration != null and _integration.has_method("request_tactical_overlay"):
		_integration.request_tactical_overlay(want, "advisor")


# --- Ollama Advisor lifecycle (single local LLM, advisory only) -----------

## Live snapshot for the selector's stale comparison. Identity fields must
## match what the request was built from; any drift discards the response.
func _current_llm_snapshot() -> Dictionary:
	if _package.is_empty() or _unit_id.is_empty() or _truth == null:
		return {}
	return {"unit_id": _unit_id,
		"state_version": int(_truth.get_version()),
		"fingerprint": str(_truth.fingerprint())}


func _llm_dedup_key() -> String:
	var s := _current_llm_snapshot()
	if s.is_empty():
		return ""
	return "%s|%d|%s" % [str(s.get("unit_id", "")), int(s.get("state_version", -1)),
		str(s.get("fingerprint", ""))]


func _slot_of_package() -> Dictionary:
	var out := {}
	for o_val in (_package.get("options", []) as Array):
		if o_val is Dictionary:
			out[str((o_val as Dictionary).get("profile", "?")).to_upper()] = int((o_val as Dictionary).get("slot", 0))
	return out


func _available_ids() -> Array:
	var out: Array = []
	for o_val in (_package.get("options", []) as Array):
		if not o_val is Dictionary:
			continue
		if str((o_val as Dictionary).get("status", "")).to_upper() in ["AVAILABLE", "DEGRADED"]:
			out.append(str((o_val as Dictionary).get("profile", "?")).to_upper())
	return out


## Auto-request on meaningful selection change (§48). Dedup: the exact same
## snapshot reuses its current result instead of inferring again. Never
## called from _process (evaluation runs on selection change only).
func _maybe_request_llm(u: Dictionary, bk: Dictionary, cell_data: Dictionary, force: bool = false) -> void:
	if _selector == null or _package.is_empty():
		return
	# AI-free launch (launcher milestone): six deterministic options stay,
	# LLM recommendation stays off, zero network traffic, zero retry spam.
	if not BackendCfgScript.is_ai_enabled():
		_window.show_llm_unavailable("AI 자문 비활성화 — 여섯 가지 안을 직접 고르십시오.")
		return
	# Chat-driven product flow: PLAYER commands through chat; the legacy
	# selection-triggered auto-advice + six cards live in DEV mode only.
	if not DevModeScript.is_dev_mode():
		return
	var key := _llm_dedup_key()
	if key.is_empty():
		return
	if not force and key == _llm_key:
		if not _llm_rec.is_empty():
			_window.show_llm_recommendation(_llm_rec)
		elif not _llm_request_id.is_empty():
			_window.show_llm_loading()
		return
	# New snapshot: drop the old verdict, show loading, infer async.
	_llm_key = key
	_llm_request_id = ""
	_llm_rec = {}
	_window.clear_llm_state()
	_window.show_llm_loading()
	_llm_seq += 1
	var request_id := "adv-%04d-%s" % [_llm_seq, _unit_id]
	var built: Dictionary = ContextScript.build({
		"package": _package, "unit": u, "blue_knowledge": bk,
		"cell_data": cell_data, "intent": DEFAULT_INTENT,
		"state_version": int(_truth.get_version()),
		"fingerprint": str(_truth.fingerprint()),
		"cluster_signature": ClustersScript.frozen_signature(),
		"request_id": request_id,
	})
	if not bool(built.get("ok", false)):
		_window.show_llm_unavailable("자문을 준비하지 못했습니다.")
		print("[AdvisorLLM] context build failed: %s" % str(built.get("error", "?")))
		return
	var context: Dictionary = built.get("context", {})
	var audit_hit := ContextScript.audit_enemy_section(context)
	if not audit_hit.is_empty():
		_window.show_llm_unavailable("자문을 준비하지 못했습니다.")
		push_error("[AdvisorLLM] BLUE-KNOWLEDGE AUDIT FAILED, request suppressed: %s" % audit_hit)
		return
	_llm_request_id = request_id
	var started: Dictionary = _selector.advise(request_id, context,
		_current_llm_snapshot(), _slot_of_package(), _available_ids())
	if not bool(started.get("ok", false)):
		var code := str(started.get("code", "OFFLINE"))
		_llm_request_id = ""
		_window.show_llm_unavailable(_selector._player_message_for(code))
		print("[AdvisorLLM] request start failed: %s %s" % [code, str(started.get("detail", ""))])
		return
	print("[AdvisorLLM] request %s sent unit=%s key=%s" % [request_id, _unit_id, key])


## Backend settings changed mid-battle (AI Settings adjust mode): drop any
## in-flight old-config inference and re-request under the new endpoint /
## model. Late old-config responses are additionally discarded by the
## selector's config-identity stale guard.
func notify_ai_config_changed() -> void:
	if _selector != null and _selector.has_method("cancel"):
		_selector.cancel()
	if _commander != null and _commander.has_method("cancel"):
		_commander.cancel()
	_chat_queue = []
	_chat_holds = []
	_chat_native = {}
	_chat_command_id = ""
	_chat_done_cb = Callable()
	_chat_failed = []
	clear_staged_preview()
	update_approval()
	_llm_request_id = ""
	_llm_rec = {}
	_llm_key = ""
	if _window != null and _window.has_method("clear_llm_state"):
		_window.clear_llm_state()
	if _package.is_empty() or _unit_id.is_empty():
		return
	if not BackendCfgScript.is_ai_enabled():
		_window.show_llm_unavailable("AI 자문 비활성화 — 여섯 가지 안을 직접 고르십시오.")
		return
	request_llm_advice()


## Manual refresh (§48): the [전술 자문 요청] button. Reuses the current
## package; forces a fresh request id even for an identical snapshot.
func request_llm_advice() -> void:
	if _package.is_empty() or _unit_id.is_empty():
		return
	if _unit_manager == null or not _unit_manager.has_method("get_selected_unit"):
		return
	var u: Dictionary = _unit_manager.get_selected_unit()
	if str(u.get("id", "")) != _unit_id:
		return
	var bk: Dictionary = _integration.call("get_blue_knowledge")
	var grid: Node = _integration.get("hex_grid") as Node
	var cell_data: Dictionary = grid.get("cell_data") as Dictionary if grid else {}
	_maybe_request_llm(u, bk, cell_data, true)


func _on_llm_ready(request_id: String, rec: Dictionary) -> void:
	if request_id != _llm_request_id or _package.is_empty():
		return # superseded selection; selector already stale-guards too.
	if str(rec.get("request_id", request_id)) != request_id:
		return
	_llm_rec = rec
	_window.show_llm_recommendation(rec)
	_window.set_status("서유선의 자문이 도착했습니다. 안을 고르시면 경로를 표시합니다.")
	print("[AdvisorLLM] request %s ready: recommend=%s conf=%.2f latency=%dms eval=%d toks" % [
		request_id, str(rec.get("profile", "?")), float(rec.get("confidence", 0.0)),
		int(rec.get("latency_ms", 0)), int(rec.get("eval_count", 0))])


func _on_llm_failed(request_id: String, code: String, player_message: String) -> void:
	if request_id != _llm_request_id:
		return
	_llm_request_id = ""
	_window.show_llm_unavailable(player_message)
	_push_llm_dev_diagnostics()
	print("[AdvisorLLM] request %s failed: %s" % [request_id, code])


## DEV-only backend diagnostics (safe: model/endpoint/status/latency,
## key-presence only — never the secret, never request headers).
func _push_llm_dev_diagnostics() -> void:
	if _selector == null or not _selector.has_method("debug_snapshot"):
		return
	if _window == null or not _window.has_method("set_llm_dev"):
		return
	var d: Dictionary = _selector.debug_snapshot()
	_window.set_llm_dev("DEV 자문: backend=%s model=%s http=%s err=%s latency=%dms apikey=%s" % [
		str(d.get("backend_type", "?")), str(d.get("model", "?")),
		str(d.get("http_status", 0)), str(d.get("failure", "—")),
		int(d.get("latency_ms", 0)),
		"YES" if bool(d.get("api_key_present", false)) else "NO"])


## DEV diagnostics (§29/§54): full request/response/latency snapshot.
func llm_debug_snapshot() -> Dictionary:
	if _selector != null and _selector.has_method("debug_snapshot"):
		var d: Dictionary = _selector.debug_snapshot()
		d["dedup_key"] = _llm_key
		d["current_recommendation"] = _llm_rec.duplicate(true)
		if _commander != null and _commander.has_method("debug_snapshot"):
			d["chat_commander"] = _commander.debug_snapshot()
			d["chat_last_advice"] = _commander.last_advice_summary()
		return d
	return {}


# --- Chat-driven commander (PLAYER primary flow) -------------------------------

func on_execute_button() -> void:
	# Staged chat plan wins; DEV card pick is the fallback.
	if _commander != null and _commander.has_method("has_staged") \
			and bool(_commander.has_staged()):
		_commander.approve_staged()
		return
	execute_selected()


func on_cancel_button() -> void:
	if _commander != null and _commander.has_method("has_staged") \
			and (bool(_commander.has_staged()) or bool(_commander.has_pending()) \
				or bool(_commander.has_active())):
		_commander.cancel_staged()
		return
	cancel()


## Approval affordance: [실행]/[취소] live only with a staged plan and no
## running execution.
func update_approval() -> void:
	if _window == null or not _window.has_method("set_approval"):
		return
	var is_staged: bool = _commander != null and _commander.has_method("has_staged") \
		and bool(_commander.has_staged())
	var busy: bool = _action_service.is_executing() or not _chat_command_id.is_empty()
	_window.set_approval(is_staged and not busy)
	_push_chat_dev()


## DEV line for the staged/approval state (safe: no key, no headers).
func _push_chat_dev() -> void:
	if _window == null or not _window.has_method("set_llm_dev"):
		return
	if _commander == null or not _commander.has_method("staged_summary"):
		return
	var st: Dictionary = _commander.staged_summary()
	if st.is_empty():
		return
	_window.set_llm_dev("DEV 편성: kind=%s scope=%s units=%d sv=%d" % [
		str(st.get("kind", "?")), str(st.get("scope_label", "?")),
		(st.get("unit_ids", []) as Array).size(),
		int(st.get("state_version", -1))])


func _sector_overlay() -> Node:
	if _integration != null:
		return _integration.get("sector_overlay") as Node
	return null


## Automatic staged preview: shared route overlay + adaptive band heatmap
## with the staged scope emphasized + affected-unit cells outlined.
func show_staged_preview(staged: Dictionary) -> void:
	if _overlay != null and _overlay.has_method("set_routes"):
		_overlay.set_routes((staged.get("preview_routes", []) as Array).duplicate(true))
	if _integration != null and _integration.has_method("request_tactical_overlay"):
		_integration.request_tactical_overlay(true, "advisor")
	var so := _sector_overlay()
	if so != null and so.has_method("set_highlight"):
		so.call("set_highlight", str(staged.get("highlight_token", "")),
			(staged.get("preview_cells", []) as Array).duplicate(true))
	update_approval()


## Clear staged visuals. The band heatmap returns to the manual toggle
## state so a user-enabled overlay is never yanked away.
func clear_staged_preview() -> void:
	if _overlay != null and _overlay.has_method("set_routes"):
		_overlay.set_routes([])
	var so := _sector_overlay()
	if so != null and so.has_method("set_highlight"):
		so.call("set_highlight", "", [])
	var keep := false
	if _window != null and _window.has_method("is_overlay_checked"):
		keep = bool(_window.is_overlay_checked())
	if not keep and _integration != null and _integration.has_method("request_tactical_overlay"):
		_integration.request_tactical_overlay(false, "advisor")
	update_approval()


## DEV scope-set preview (algebra debugging instrument, not player UI):
## highlight the CURRENT cells of an arbitrary resolved unit-id set on the
## live map. Cleared by clear_staged_preview() / the next staged preview.
func preview_scope_cells(unit_ids: Array) -> void:
	var cells: Array = []
	if _command_service != null and _command_service.has_method("get_unit"):
		for uid in unit_ids:
			var u: Variant = _command_service.call("get_unit", str(uid))
			if u is Dictionary and (u as Dictionary).has("q") and (u as Dictionary).has("r"):
				cells.append(Vector2i(int((u as Dictionary).get("q", 0)), int((u as Dictionary).get("r", 0))))
	if _overlay != null and _overlay.has_method("set_routes"):
		_overlay.set_routes([])
	var so := _sector_overlay()
	if so != null and so.has_method("set_highlight"):
		so.call("set_highlight", "", cells)
	if _integration != null and _integration.has_method("request_tactical_overlay"):
		_integration.request_tactical_overlay(true, "advisor")


func send_chat(text: String) -> void:
	if not is_ready():
		return
	if not BackendCfgScript.is_ai_enabled():
		_window.append_chat("ADVISOR", "AI 자문 비활성화 — 여섯 가지 안을 직접 고르십시오.")
		return
	if _commander != null and _commander.has_method("send_chat"):
		_commander.send_chat(text)


func _on_chat_append(author: String, text: String) -> void:
	if _window != null and _window.has_method("append_chat"):
		_window.append_chat(author, text)


func _on_chat_busy(b: bool) -> void:
	if _window != null and _window.has_method("set_chat_busy"):
		_window.set_chat_busy(b)


func _on_chat_command_finished(_command_id: String, _ok: bool, summary: String) -> void:
	if _window != null and not str(summary).is_empty():
		_window.set_status(str(summary))


## Composite execution for a staged multi-order plan: sequential canonical
## MOVEs first, then sequential canonical HOLDs, one shared completion
## report. Same per-unit validate/plan/execute chain as the single paths;
## no composite-specific movement logic.
func execute_composite(command_id: String, moves_items: Array, hold_ids: Array,
		done_cb: Callable) -> void:
	if _action_service.is_executing():
		done_cb.call(command_id, {"ok": false, "moved": 0,
			"player_text": "다른 부대가 이동 중입니다. 잠시 후 다시 말씀해 주십시오.",
			"short": "busy"})
		return
	_chat_queue = (moves_items as Array).duplicate(true)
	_chat_holds = []
	for hid in hold_ids:
		if not str(hid).is_empty():
			_chat_holds.append(str(hid))
	_chat_command_id = command_id
	_chat_done_cb = done_cb
	_chat_moved = 0
	_chat_failed = []
	_chat_native = {}
	_chat_kind = "composite"
	_chat_planned = {}
	_chat_exec_adapted = []
	_chat_short = []
	_chat_comp_moves = []
	for it in _chat_queue:
		if it is Dictionary:
			_chat_comp_moves.append(str((it as Dictionary).get("unit_id", "")))
			if (it as Dictionary).has("destination"):
				var dd: Dictionary = (it as Dictionary)["destination"]
				_chat_planned[str((it as Dictionary).get("unit_id", ""))] = [int(dd.get("q", 0)), int(dd.get("r", 0))]
	_chat_comp_holds = _chat_holds.duplicate()
	_window.set_status("이동 중... (0/%d)" % (_chat_queue.size() + _chat_holds.size()))
	update_approval()
	if _overlay != null and _overlay.has_method("set_routes"):
		var routes: Array = []
		for it2 in _chat_queue:
			routes.append({"path_cells": ((it2 as Dictionary).get("path", []) as Array).duplicate(true) if (it2 as Dictionary).has("path") else []})
		_overlay.set_routes(routes)
	_execute_next_chat_move()


## Canonical sequential execution for a validated chat COMMAND. items:
## [{unit_id, profile, slot, destination{q,r}, path}]. Never executes model
## text: every step rebuilds a deterministic MOVE through validate/plan.
func execute_chat_moves(command_id: String, items: Array, done_cb: Callable) -> void:
	if _action_service.is_executing():
		done_cb.call(command_id, {"ok": false, "moved": 0,
			"player_text": "다른 부대가 이동 중입니다. 잠시 후 다시 말씀해 주십시오.",
			"short": "busy"})
		return
	_chat_queue = items.duplicate(true)
	_chat_holds = []
	_chat_command_id = command_id
	_chat_done_cb = done_cb
	_chat_moved = 0
	_chat_failed = []
	_chat_native = {}
	_chat_kind = "moves"
	_chat_comp_moves = []
	_chat_comp_holds = []
	_chat_planned = {}
	_chat_exec_adapted = []
	_chat_short = []
	for it0 in items:
		if it0 is Dictionary and (it0 as Dictionary).has("destination"):
			var dd0: Dictionary = (it0 as Dictionary)["destination"]
			_chat_planned[str((it0 as Dictionary).get("unit_id", ""))] = [int(dd0.get("q", 0)), int(dd0.get("r", 0))]
	_window.set_status("이동 중... (0/%d)" % items.size())
	update_approval()
	if _overlay != null and _overlay.has_method("set_routes"):
		var routes: Array = []
		for it in items:
			routes.append({"path_cells": (it as Dictionary).get("path", [])})
		_overlay.set_routes(routes)
	_execute_next_chat_move()


## Single-plan native execution (whole-force ADVANCE, HOLD). Fresh
## validate at approval time; the stored command is never trusted blind.
func execute_native_plan(command_id: String, command: Dictionary, done_cb: Callable) -> void:
	if _action_service.is_executing():
		done_cb.call(command_id, {"ok": false, "moved": 0,
			"player_text": "다른 부대가 이동 중입니다. 잠시 후 다시 말씀해 주십시오.",
			"short": "busy"})
		return
	var vd: Dictionary = _action_service.validate_action(command, "blue")
	if not bool(vd.get("ok", false)):
		done_cb.call(command_id, {"ok": false, "moved": 0,
			"player_text": "전황이 바뀌어 편성안을 이행할 수 없습니다. 다시 명령해 주십시오.",
			"short": "revalidate-failed"})
		return
	var plan: Dictionary = _action_service.plan_action(command, "blue")
	_chat_queue = []
	_chat_holds = []
	_chat_native = {"command_id": command_id,
		"action": str(command.get("action", "ADVANCE"))}
	_chat_kind = "native"
	_chat_command_id = command_id
	_chat_done_cb = done_cb
	_chat_moved = 0
	_chat_failed = []
	_chat_planned = {}
	_chat_exec_adapted = []
	_chat_short = []
	_chat_comp_moves = []
	_chat_comp_holds = []
	_window.set_busy(true)
	_window.set_status("이동 중...")
	update_approval()
	var ex: Dictionary = _action_service.execute_plan(str(plan.get("plan_id", "")))
	if str(ex.get("execution_status", "")) != "IN_PROGRESS":
		_window.set_busy(false)
		_chat_moved += ((ex.get("executed_units", []) as Array).size())
		for f in (ex.get("failed_units", []) as Array):
			_chat_failed.append(f)
		_finish_chat_execution()


## Sequential per-unit HOLD execution for staged multi-hold plans. Same
## canonical validate/plan/execute chain as moves; shares the finish path.
func execute_hold_units(command_id: String, items: Array, done_cb: Callable) -> void:
	if _action_service.is_executing():
		done_cb.call(command_id, {"ok": false, "moved": 0,
			"player_text": "다른 부대가 이동 중입니다. 잠시 후 다시 말씀해 주십시오.",
			"short": "busy"})
		return
	_chat_queue = []
	_chat_holds = []
	for it in items:
		if it is Dictionary and not str((it as Dictionary).get("unit_id", "")).is_empty():
			_chat_holds.append(str((it as Dictionary).get("unit_id", "")))
	_chat_command_id = command_id
	_chat_done_cb = done_cb
	_chat_moved = 0
	_chat_failed = []
	_chat_native = {}
	_chat_kind = "holds"
	_chat_comp_moves = []
	_chat_comp_holds = []
	_chat_planned = {}
	_chat_exec_adapted = []
	_chat_short = []
	_window.set_status("대기 이행 중... (0/%d)" % _chat_holds.size())
	update_approval()
	_execute_next_chat_hold()


func _execute_next_chat_hold() -> void:
	while not _chat_holds.is_empty():
		var uid := str(_chat_holds.pop_front())
		var cmd := {"action": "HOLD",
			"scope": {"type": "UNIT_ID", "unit_id": uid},
			"direction": "", "target": {}, "posture": "NORMAL", "constraints": {}}
		var vd: Dictionary = _action_service.validate_action(cmd, "blue")
		if not bool(vd.get("ok", false)):
			_chat_failed.append({"unit_id": uid, "code": "VALIDATE_FAILED"})
			continue
		var plan: Dictionary = _action_service.plan_action(cmd, "blue")
		_window.set_busy(true)
		var ex: Dictionary = _action_service.execute_plan(str(plan.get("plan_id", "")))
		if str(ex.get("execution_status", "")) == "IN_PROGRESS":
			_window.set_status("대기 이행 중... (%d/%d)" % [_chat_moved, _chat_moved + _chat_holds.size() + 1])
			return # continuation arrives via _on_execution_finished.
		_window.set_busy(false)
		_chat_moved += ((ex.get("executed_units", []) as Array).size())
		for f in (ex.get("failed_units", []) as Array):
			_chat_failed.append(f)
	_finish_chat_execution()


func _execute_next_chat_move() -> void:
	while not _chat_queue.is_empty():
		var it: Dictionary = _chat_queue.pop_front()
		var uid := str(it.get("unit_id", ""))
		# Ordered candidates: staged destination first, then the staged
		# fallback realizations. Each is validated against the CURRENT
		# world (earlier queue moves change occupancy/costs), so a unit
		# whose promised hex turned illegal adapts instead of failing.
		var cands: Array = []
		if it.has("destination"):
			cands.append((it.get("destination", {}) as Dictionary).duplicate())
		for fb in (it.get("fallbacks", []) as Array):
			if fb is Dictionary and (fb as Dictionary).has("destination"):
				cands.append(((fb as Dictionary).get("destination", {}) as Dictionary).duplicate())
		var picked := {}
		var last_err := {}
		for cand in cands:
			var cd: Dictionary = cand
			var cmd := {"action": "MOVE",
				"scope": {"type": "UNIT_ID", "unit_id": uid},
				"direction": "", "target": {"type": "HEX", "q": int(cd.get("q", 0)), "r": int(cd.get("r", 0))},
				"posture": "NORMAL", "constraints": {}}
			var vd: Dictionary = _action_service.validate_action(cmd, "blue")
			if bool(vd.get("ok", false)):
				picked = cd
				break
			var verrs: Array = vd.get("validation_errors", [])
			if not verrs.is_empty() and verrs[0] is Dictionary:
				last_err = verrs[0]
		if picked.is_empty():
			_chat_failed.append({"unit_id": uid,
				"code": str(last_err.get("code", "VALIDATE_FAILED")),
				"detail": str(last_err.get("detail", "Destination cannot currently be completed."))})
			continue
		if int(picked.get("q", -9999)) != int((_chat_planned.get(uid, [-9999, -9998]) as Array)[0]) \
				or int(picked.get("r", -9999)) != int((_chat_planned.get(uid, [-9999, -9998]) as Array)[1]):
			_chat_planned[uid] = [int(picked.get("q", 0)), int(picked.get("r", 0))]
			_chat_exec_adapted.append({"unit_id": uid,
				"destination": {"q": int(picked.get("q", 0)), "r": int(picked.get("r", 0))}})
		var cmd2 := {"action": "MOVE",
			"scope": {"type": "UNIT_ID", "unit_id": uid},
			"direction": "", "target": {"type": "HEX", "q": int(picked.get("q", 0)), "r": int(picked.get("r", 0))},
			"posture": "NORMAL", "constraints": {}}
		var vd2: Dictionary = _action_service.validate_action(cmd2, "blue")
		if not bool(vd2.get("ok", false)):
			var e2: Array = vd2.get("validation_errors", [])
			var row0 := {"unit_id": uid, "code": "VALIDATE_FAILED",
				"detail": "Destination cannot currently be completed."}
			if not e2.is_empty() and e2[0] is Dictionary:
				row0["code"] = str((e2[0] as Dictionary).get("code", "VALIDATE_FAILED"))
				row0["detail"] = str((e2[0] as Dictionary).get("detail", row0["detail"]))
			_chat_failed.append(row0)
			continue
		var plan: Dictionary = _action_service.plan_action(cmd2, "blue")
		if not bool(plan.get("ok", false)) or str(plan.get("plan_id", "")).is_empty():
			var pe: Array = plan.get("validation_errors", [])
			var row1 := {"unit_id": uid, "code": "NO_LEGAL_DESTINATION",
				"detail": "Destination cannot currently be completed."}
			if not pe.is_empty() and pe[0] is Dictionary:
				row1["code"] = str((pe[0] as Dictionary).get("code", "NO_LEGAL_DESTINATION"))
				row1["detail"] = str((pe[0] as Dictionary).get("detail", row1["detail"]))
			_chat_failed.append(row1)
			continue
		var ex: Dictionary = _action_service.execute_plan(str(plan.get("plan_id", "")))
		if str(ex.get("execution_status", "")) == "IN_PROGRESS":
			_window.set_status("이동 중... (%d/%d)" % [_chat_moved, _chat_moved + _chat_queue.size() + 1])
			return # continuation arrives via _on_execution_finished.
		_window.set_busy(false)
		_chat_moved += ((ex.get("executed_units", []) as Array).size())
		_note_short_landings(ex.get("executed_units", []))
		for f in (ex.get("failed_units", []) as Array):
			_chat_failed.append(f)
	# Moves drained: composite continues with holds; otherwise finalize.
	if _chat_kind == "composite" and not _chat_holds.is_empty():
		_window.set_status("대기 이행 중... (0/%d)" % _chat_holds.size())
		_execute_next_chat_hold()
		return
	# Queue drained: finalize canonically and report to the commander.
	_finish_chat_execution()


## Short-landing detection (Failure B fix): an executed row whose actual
## `to` differs from the promised destination (contact stops, march
## envelope) is recorded factually — the completion text must say where
## the formation actually ended, not what was planned.
func _note_short_landings(executed: Array) -> void:
	for row_val in executed:
		if not row_val is Dictionary:
			continue
		var row: Dictionary = row_val
		var uid := str(row.get("unit_id", ""))
		if uid.is_empty() or not _chat_planned.has(uid):
			continue
		if not row.has("to"):
			continue
		var landed: Array = row.get("to", [])
		if landed.size() != 2:
			continue
		var promised: Array = _chat_planned[uid]
		if int(landed[0]) != int(promised[0]) or int(landed[1]) != int(promised[1]):
			var dup := false
			for s in _chat_short:
				if str((s as Dictionary).get("unit_id", "")) == uid:
					dup = true
			if not dup:
				_chat_short.append({"unit_id": uid,
					"planned": [int(promised[0]), int(promised[1])],
					"landed": [int(landed[0]), int(landed[1])]})


## Shared chat-execution finalization (moves/holds drained, native done).
func _finish_chat_execution() -> void:
	_window.set_busy(false)
	if _overlay != null and _overlay.has_method("set_routes"):
		_overlay.set_routes([])
	var cid := _chat_command_id
	var cb := _chat_done_cb
	var moved := _chat_moved
	var failed: Array = _chat_failed.duplicate(true)
	var adapted: Array = _chat_exec_adapted.duplicate(true)
	var shorts: Array = _chat_short.duplicate(true)
	var holding := _chat_kind == "holds" \
		or str(_chat_native.get("action", "")) == "HOLD"
	var comp_moves: Array = _chat_comp_moves.duplicate()
	var comp_holds: Array = _chat_comp_holds.duplicate()
	_chat_queue = []
	_chat_holds = []
	_chat_native = {}
	_chat_kind = ""
	_chat_command_id = ""
	_chat_done_cb = Callable()
	_chat_failed = []
	_chat_planned = {}
	_chat_exec_adapted = []
	_chat_short = []
	_chat_comp_moves = []
	_chat_comp_holds = []
	var player_text := ""
	if not comp_moves.is_empty() or not comp_holds.is_empty():
		# Composite mixed report: moves part + holds part (classified by
		# initial membership, not by free-form text).
		var move_failed := 0
		for f in failed:
			if not str((f as Dictionary).get("unit_id", "")) in comp_holds:
				move_failed += 1
		var hold_failed := failed.size() - move_failed
		var moves_done := comp_moves.size() - move_failed
		var holds_done := comp_holds.size() - hold_failed
		var bits: Array = []
		if not comp_moves.is_empty():
			bits.append("이동 %d기 이행" % moves_done)
		if not comp_holds.is_empty():
			bits.append("대기 %d기 이행" % holds_done)
		player_text = "복합 명령을 이행했습니다. (" + ", ".join(bits) + ")"
	else:
		player_text = "대기 명령을 이행했습니다. (%d기)" % moved if holding \
			else "이동을 완료했습니다. (%d기)" % moved
	player_text += _exec_detail_text(failed, adapted, shorts)
	_window.set_status(player_text)
	update_approval()
	notify_selection()
	if cb.is_valid():
		cb.call(cid, {"ok": failed.is_empty(), "moved": moved,
			"failed": failed.size(), "failed_units": failed,
			"adapted_units": adapted, "short_units": shorts,
			"player_text": player_text,
			"short": player_text})


## Failure-code to short player-facing Korean (no internal tokens).
static func _fail_kr(code: String) -> String:
	match code.strip_edges().to_upper():
		"OCCUPIED":
			return "목적지가 막혔습니다"
		"TARGET_UNREACHABLE":
			return "경로가 없습니다"
		"INSUFFICIENT_MOVEMENT":
			return "이동력이 부족합니다"
		"UNIT_NOT_READY":
			return "이동할 수 없는 상태입니다"
		"STALE_STATE":
			return "전황이 바뀌었습니다"
		"NO_VALID_UNITS", "VALIDATE_FAILED", "NO_LEGAL_DESTINATION":
			return "지금은 이행할 수 없습니다"
	return "이행하지 못했습니다"


## Map-correlatable unit display: class label + live id ("창병대 B_SPE_1").
## BLUE-own ids are map-visible; RED truth never appears here.
func _unit_disp(uid: String) -> String:
	var cls := ""
	if _command_service != null and _command_service.has_method("get_unit"):
		var u: Variant = _command_service.call("get_unit", uid)
		if u is Dictionary:
			cls = str((u as Dictionary).get("class", "")).to_upper()
	if cls.is_empty():
		return uid
	return "%s %s" % [ViewModelScript.class_kr(cls), uid]


## Honest completion detail: names failed / adapted / short-stopped
## formations (max 3 names per group, then 외 N기) with landing hexes.
## Counts alone hid which formations need new orders (proven gap).
func _exec_detail_text(failed: Array, adapted: Array, shorts: Array) -> String:
	var out := ""
	if not failed.is_empty():
		var parts: Array = []
		var shown := 0
		for f in failed:
			if shown >= 3:
				break
			if not f is Dictionary:
				continue
			parts.append("%s은 %s" % [_unit_disp(str((f as Dictionary).get("unit_id", "?"))),
				_fail_kr(str((f as Dictionary).get("code", "")))])
			shown += 1
		out += " " + ", ".join(parts) + "."
		if failed.size() > shown:
			out += " 외 %d기" % (failed.size() - shown) + "."
	if not adapted.is_empty():
		var names: Array = []
		var shown2 := 0
		for a in adapted:
			if shown2 >= 3:
				break
			if not a is Dictionary:
				continue
			var dd: Dictionary = (a as Dictionary).get("destination", {})
			names.append("%s은 (%d, %d)로" % [_unit_disp(str((a as Dictionary).get("unit_id", "?"))),
				int(dd.get("q", 0)), int(dd.get("r", 0))])
			shown2 += 1
		out += " " + ", ".join(names) + " 인접 지점으로 이동했습니다."
		if adapted.size() > shown2:
			out += " 외 %d기." % (adapted.size() - shown2)
	if not shorts.is_empty():
		var bits: Array = []
		var shown3 := 0
		for s in shorts:
			if shown3 >= 3:
				break
			if not s is Dictionary:
				continue
			var ld: Array = (s as Dictionary).get("landed", [])
			if ld.size() != 2:
				continue
			bits.append("%s은 (%d, %d)까지만 이동했습니다" % [
				_unit_disp(str((s as Dictionary).get("unit_id", "?"))),
				int(ld[0]), int(ld[1])])
			shown3 += 1
		out += " " + ", ".join(bits) + "."
		if shorts.size() > shown3:
			out += " 외 %d기." % (shorts.size() - shown3)
	return out


# --- Package access for tests / DEV comparison -----------------------------

func current_package() -> Dictionary:
	return _package.duplicate(true)


func current_unit_id() -> String:
	return _unit_id


func picked_slot() -> int:
	return _picked


func _card_for_slot(slot: int) -> Dictionary:
	for c in _cards:
		if c is Dictionary and int((c as Dictionary).get("slot", 0)) == slot:
			return c
	return {}


func _option_for_slot(slot: int) -> Dictionary:
	for o_val in (_package.get("options", []) as Array):
		if o_val is Dictionary and int((o_val as Dictionary).get("slot", 0)) == slot:
			return o_val
	return {}
