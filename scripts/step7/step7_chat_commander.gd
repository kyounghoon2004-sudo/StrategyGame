class_name Step7ChatCommander
extends Node

## Chat-driven LLM commander v2 (staged-approval product flow).
##
## Pipeline (SAME configured model, constrained calls, zero free agency):
##   USER CHAT -> Phase 1 intent (semantic JSON over the REAL command
##     vocabulary + live capabilities + live formation layout) ->
##   Godot scope resolution -> deterministic packages (doctrine
##     evaluator, one framework for all combat classes) or
##     planner-native staging (whole-force ADVANCE, HOLD) ->
##   STAGED PLAN + automatic map preview (routes + bands + highlights) ->
##   PLAYER [실행]/[취소] -> stale-checked canonical execution.
##
## SEND authorizes interpretation + planning, NEVER state mutation.
## The six realization profiles are LLM-internal; the player approves the
## staged plan only. Model output is untrusted at every phase: allow-list
## validated, one repair attempt, stale-checked against state_version +
## config_identity. Coordinates and membership come ONLY from Godot data.
##
## Signals:
##   chat_append(author, text)  author in USER|ADVISOR|SYSTEM (window renders)
##   chat_busy(b)
##   command_finished(command_id, ok, summary)

signal chat_append(author: String, text: String)
signal chat_busy(b: bool)
signal command_finished(command_id: String, ok: bool, summary: String)

const ClientScript = preload("res://scripts/step7/step7_ollama_client.gd")
const ConfigScript = preload("res://scripts/step7/step7_ollama_config.gd")
const BackendCfgScript = preload("res://scripts/ai/ai_backend_config.gd")
const IntentScript = preload("res://scripts/step7/step7_chat_intent.gd")
const ResolverScript = preload("res://scripts/step7/step7_scope_resolver.gd")
const ContextScript = preload("res://scripts/step7/step7_advisor_context.gd")
const ViewModelScript = preload("res://scripts/step7/step7_advisor_viewmodel.gd")
const EvaluatorScript = preload("res://scripts/step7/step7_cavalry_evaluator.gd")
const ClustersScript = preload("res://scripts/step7/step7_formation_clusters.gd")
const CommandScript = preload("res://scripts/step7/step7_action_command.gd")
const DoctrinesScript = preload("res://scripts/step7/step7_unit_doctrines.gd")
const AlgebraScript = preload("res://scripts/step7/step7_scope_algebra.gd")
const CommandIRScript = preload("res://scripts/step7/step7_command_ir.gd")
const FrontendScript = preload("res://scripts/step7/step7_semantic_frontend.gd")

const ADVANCE_INTENT := {"action": "ADVANCE", "direction": "FORWARD"}
const HISTORY_KEEP := 4
const HISTORY_CHARS := 220
const LOW_CONFIDENCE := 0.45

## Chat-executable actions. Everything else is interpreted, then answered
## with an honest capability limitation (never distorted into ADVANCE).
## ADVANCE + RECON stage through the doctrine evaluator for every combat
## class; HOLD stages natively for any BLUE scope.
const CHAT_DOCTRINE_ACTIONS := ["ADVANCE", "RECON"]
const CHAT_NATIVE_ANY_SCOPE := ["HOLD"]
## Tactical selection batch size: one Phase-2 model call chooses for at
## most this many units. Larger semantic sets stage COMPLETELY through
## sequential chunk calls (never sliced); deconfliction merges over all.
const SELECT_CHUNK := 8

const CANCEL_WORDS := ["취소", "그만", "취소해", "중지", "취소할게"]

var _integration: Node = null
var _truth: RefCounted = null
var _command_service: RefCounted = null
var _projector: RefCounted = null
var _action_service: RefCounted = null
var _overlay: Node2D = null
var _unit_manager: RefCounted = null
var _adapter = null # Step7AdvisorAdapter (staging/execution owner)
var _evaluator: RefCounted = null
var _client = null # Step7OllamaAdvisorClient (commander-owned transport)

var _seq := 0
var _active := {} # command_id -> record (single active command)
var _history: Array = [] # [{user, advisor}] bounded
var _pending := {} # structured pending clarification (see _set_pending)
var _staged := {} # staged plan awaiting approval (see _stage)
var _last_advice := {} # {unit_ids, profiles, scope_label, state, text}
var _debug := {}
var _trace: Array = []
## Semantic frontend fast-path state. _semantic_dead latches when the
## semantic tag is confirmed missing so later messages skip straight to
## the large-model path instead of paying a failing call each time.
var _semantic_dead := false
var _semantic_used := 0
var _semantic_fallbacks := 0
## Circuit breaker: the configured 0.6B checkpoint is English-domain
## fine-tuned; Korean direct parsing MEASURED as failing (recorded
## 2026-09-16: degenerate think-tag spew / empty JSON on Korean input,
## perfect only on in-distribution English tool calls). After STRIKE_LIMIT
## consecutive semantic-level failures the session bypasses the tiny call
## and goes straight to the large-model path — every command still pays
## at most one wasted tiny inference per session window, never one per
## message. A single tiny success resets the breaker. Transport failures
## (server down) never count: the large path would fail too.
const SEMANTIC_STRIKE_LIMIT := 3
var _semantic_strikes := 0


func setup(deps: Dictionary) -> void:
	_integration = deps.get("integration") as Node
	_truth = deps.get("truth") as RefCounted
	_command_service = deps.get("command_service") as RefCounted
	_projector = deps.get("projector") as RefCounted
	_action_service = deps.get("action_service") as RefCounted
	_overlay = deps.get("overlay") as Node2D
	_unit_manager = deps.get("unit_manager") as RefCounted
	_adapter = deps.get("adapter")
	_evaluator = EvaluatorScript.new()
	_client = ClientScript.new()
	_client.name = "ChatCommanderClient"
	add_child(_client)
	_client.chat_finished.connect(_on_chat_finished)


func is_ready() -> bool:
	return _integration != null and _truth != null and _command_service != null \
		and _projector != null and _action_service != null and _unit_manager != null \
		and _adapter != null and _client != null


func has_active() -> bool:
	return not _active.is_empty()


func has_staged() -> bool:
	return not _staged.is_empty()


func has_pending() -> bool:
	return not _pending.is_empty()


func staged_summary() -> Dictionary:
	return _staged.duplicate(true)


func cancel() -> void:
	if _client != null and _client.has_method("cancel_active"):
		_client.cancel_active()
	_active.clear()
	_clear_pending()
	_clear_stage()
	_refresh_preview_state()
	chat_busy.emit(false)


## Selection-change path: drop in-flight inference only. A validated staged
## plan survives selection changes (selection mutates no state); approval
## re-checks drift before any movement. Always releases the input lock so a
## superseded inference can never wedge the chat box disabled.
func cancel_active_only() -> void:
	if _client != null and _client.has_method("cancel_active"):
		_client.cancel_active()
	_active.clear()
	chat_busy.emit(false)


func debug_snapshot() -> Dictionary:
	var d := _debug.duplicate(true)
	d["trace"] = _trace.duplicate(true)
	d["has_staged"] = has_staged()
	d["has_pending"] = has_pending()
	d["semantic_dead"] = _semantic_dead
	d["semantic_used"] = _semantic_used
	d["semantic_fallbacks"] = _semantic_fallbacks
	d["semantic_strikes"] = _semantic_strikes
	d["semantic_bypassed"] = _semantic_strikes >= SEMANTIC_STRIKE_LIMIT
	d["semantic_tag"] = ConfigScript.semantic_model()
	d["tactical_tag"] = ConfigScript.model()
	return d


func last_advice_summary() -> Dictionary:
	return _last_advice.duplicate(true)


# --- Capability + layout (live, auditable) -------------------------------------

## Chat capability snapshot: live action/scope vocab + what chat can stage.
## This text steers Phase-1 deliberation, so it MUST match the router
## below: ADVANCE stages for every doctrine class, RECON stages through
## the same doctrine path, HOLD stages natively, everything else is
## interpreted then honestly limited. Stale capability text here was
## dithering fuel (the model saw "unsupported" while the router staged).
static func capability_snapshot() -> Dictionary:
	return {
		"audited_actions": (CommandScript.VALID_ACTIONS as Array).duplicate(),
		"audited_scope_types": (CommandScript.VALID_SCOPE_TYPES as Array).duplicate(),
		"chat_advance": "supported: ADVANCE stages for CAVALRY, INFANTRY, ARCHER, SPEARMAN, SCOUT, SIEGE, CONSCRIPT via doctrine evaluation + realization choice, staged for approval",
		"chat_recon": "supported: RECON stages like ADVANCE (forward observation movement scored by class doctrine), staged for approval",
		"chat_hold": "supported: planner-native HOLD for any BLUE scope, staged for approval",
		"chat_advance_whole_force": "supported: planner-native whole-force ADVANCE staged for approval (no per-unit LLM choice)",
		"chat_scope_expr": "supported: compositional scope AST (UNION/INTERSECT/DIFF over ALL_FRIENDLY/ALL_COMBAT/CLASS/WING/CLUSTER/UNIT/SELECTED) for the documented proof patterns; Godot validates and resolves membership",
		"chat_policy_classes": "HQ/SUPPLY never maneuver: interpret, then explicit capability policy",
		"chat_other_actions": "interpreted_only: MOVE, RETREAT, FLANK, REPOSITION, WITHDRAW, REGROUP, PROTECT, SCREEN are interpreted correctly, then answered with an honest limitation (never distorted into ADVANCE)",
	}


## Order[] data model (composite-order foundation).
##
## One player message MAY carry several orders in the future; today the
## intent layer always produces exactly one. Order:
##   {"action", "scope" (legacy), "scope_expr" (AST or {}),
##    "style", "request_type", "question", "missing", "confidence"}.
## Single order = list of length 1; the staged plan carries its orders.
static func make_order(intent: Dictionary) -> Dictionary:
	return {
		"action": str(intent.get("action", "")),
		"scope": (intent.get("scope", {}) as Dictionary).duplicate(true),
		"scope_expr": (intent.get("scope_expr", {}) as Dictionary).duplicate(true),
		"style": (intent.get("style", {}) as Dictionary).duplicate(true),
		"request_type": str(intent.get("request_type", "COMMAND")),
		"question": str(intent.get("question", "")),
		"missing": (intent.get("missing", []) as Array).duplicate(),
		"confidence": float(intent.get("confidence", 0.0)),
	}


## Orders view of a validated intent: the validated order list (each
## re-normalized through make_order), falling back to the mirrored
## single order for intents built before orders existed.
## (Step 1 fix: the old fallback recursed into itself; it now wraps the
## mirror directly. Validated intents always carry orders[], so this path
## is dead in practice — kept total for headless/legacy callers.)
static func _orders_of(intent: Dictionary) -> Array:
	var out: Array = []
	for o in (intent.get("orders", []) as Array):
		if o is Dictionary:
			out.append(make_order(o))
	if out.is_empty():
		out = [make_order(intent)]
	return out


## CommandIR v2 adapter (Step 1, additive): canonical semantic IR over a
## validated intent + the ORIGINAL utterance. Pure, never stages, never
## reroutes. Returns {ok, ir} or {ok:false, why}; callers record the
## diagnostic and keep existing routing UNCHANGED on failure.
static func command_ir_of(intent: Dictionary, original_text: String) -> Dictionary:
	return CommandIRScript.from_validated_intent(intent, original_text)


## Deterministic per-order resolution preview (DEV/diagnostic + future
## composite staging): [{action, scope_fp, unit_ids, count, empty}].
## Pure over the algebra; stages nothing, asks nothing.
static func resolve_orders(orders: Array, deps: Dictionary) -> Array:
	var out: Array = []
	for o_val in orders:
		if not o_val is Dictionary:
			continue
		var o: Dictionary = o_val
		var ex: Dictionary = o.get("scope_expr", {})
		if ex.is_empty():
			var leg := AlgebraScript.compile_legacy(o.get("scope", {}))
			if bool(leg.get("ok", false)):
				ex = leg.get("expr", {})
		if ex.is_empty():
			out.append({"action": str(o.get("action", "")), "scope_fp": "",
				"unit_ids": [], "count": 0, "empty": true})
			continue
		var r: Dictionary = AlgebraScript.resolve(AlgebraScript.normalize(ex), deps)
		out.append({"action": str(o.get("action", "")),
			"scope_fp": AlgebraScript.fingerprint(ex),
			"unit_ids": (r.get("unit_ids", []) as Array).duplicate(),
			"count": int(r.get("total", 0)), "empty": bool(r.get("empty", true))})
	return out


## Orders fingerprint for stale detection / DEV (expression semantics,
## not just membership).
static func orders_fingerprint(orders: Array) -> String:
	var parts: Array = []
	for o_val in orders:
		if not o_val is Dictionary:
			continue
		var o: Dictionary = o_val
		var ex: Dictionary = o.get("scope_expr", {})
		var fp := ""
		if not ex.is_empty():
			fp = AlgebraScript.fingerprint(ex)
		else:
			fp = IntentScript.intent_fingerprint({
				"request_type": str(o.get("request_type", "")),
				"action": str(o.get("action", "")),
				"scope": o.get("scope", {}), "style": o.get("style", {}),
				"confidence": float(o.get("confidence", 0.0))})
		parts.append("%s@%s" % [str(o.get("action", "")), fp])
	return "ORDERS[%s]" % ";".join(parts)


## Deterministic overlap analysis over resolved orders (diagnostic for
## the composite milestone — no execution use yet). Per pair:
## {a, b, relation, shared_ids} with relation in disjoint |
## overlap_same_action | overlap_conflict. Never silently merges.
static func analyze_order_overlap(orders: Array, deps: Dictionary) -> Array:
	var res := resolve_orders(orders, deps)
	var out: Array = []
	for i in range(res.size()):
		for j in range(i + 1, res.size()):
			var a: Dictionary = res[i]
			var b: Dictionary = res[j]
			var bset := {}
			for uid in (b.get("unit_ids", []) as Array):
				bset[str(uid)] = true
			var shared: Array = []
			for uid2 in (a.get("unit_ids", []) as Array):
				if bset.has(str(uid2)):
					shared.append(str(uid2))
			shared.sort()
			var rel := "disjoint"
			if not shared.is_empty():
				rel = "overlap_same_action" if str(a.get("action", "")) == str(b.get("action", "")) else "overlap_conflict"
			out.append({"a": i, "b": j, "relation": rel, "shared_ids": shared})
	return out


func friendly_layout() -> Array:
	var roster := ResolverScript.blue_force(_unit_manager)
	var by_band := {}
	for u in roster:
		var cid := ClustersScript.cluster_of_unit(u)
		if cid.is_empty():
			continue
		if not by_band.has(cid):
			by_band[cid] = []
		(by_band[cid] as Array).append(u)
	var out: Array = []
	for cid in ClustersScript.cluster_ids():
		var members: Array = (by_band.get(str(cid), []) as Array).duplicate()
		var counts := {}
		var cav_ids: Array = []
		for u in members:
			var c := str((u as Dictionary).get("class", "")).to_upper()
			counts[c] = int(counts.get(c, 0)) + 1
			if c == "CAVALRY":
				cav_ids.append(str((u as Dictionary).get("id", "")))
		cav_ids.sort()
		out.append({"band": str(cid),
			"wing": str(ClustersScript.wing_of_cluster(str(cid))),
			"extreme_left": str(cid) == ClustersScript.extreme_left(),
			"extreme_right": str(cid) == ClustersScript.extreme_right(),
			"class_counts": counts, "cavalry_ids": cav_ids})
	return out


# --- Entry ---------------------------------------------------------------------

func send_chat(raw_text: String) -> void:
	if not is_ready():
		return
	var text := raw_text.strip_edges()
	if text.is_empty():
		return
	if not _active.is_empty():
		chat_append.emit("SYSTEM", "이전 명령을 처리 중입니다. 잠시 후 다시 말씀해 주십시오.")
		return
	if text in CANCEL_WORDS:
		_cancel_everything()
		return
	_seq += 1
	var command_id := "cmd-%04d" % _seq
	_active[command_id] = {
		"text": text, "phase": "intent", "repair_used": false,
		"sent_msec": Time.get_ticks_msec(),
		"state_version": int(_truth.get_version()),
		"fingerprint": str(_truth.fingerprint()),
		"turn": _turn(),
		"cluster_sig": ClustersScript.frozen_signature(),
		"config_identity": BackendCfgScript.config_identity(),
		"intent": {}, "scope_label": "", "unit_ids": [],
		"packages": {}, "rep_context": {}, "supplied_ids": [],
		"selection": {},
	}
	_trace = ["USER: %s" % text.substr(0, 80)]
	chat_append.emit("USER", text)
	chat_append.emit("ADVISOR", "명령을 검토 중입니다...")
	chat_busy.emit(true)
	_debug = {"command_id": command_id, "user_text": text,
		"state_version": int(_truth.get_version()),
		"config_identity": str(_active[command_id]["config_identity"]),
		"semantic_identity": BackendCfgScript.semantic_identity(),
		"failure": "", "stale_discarded": false}
	if _semantic_should_try():
		_trace.append("SEMANTIC fast path (%s)" % ConfigScript.semantic_model())
		_send_semantic(command_id)
	else:
		_send_intent(command_id)


func _cancel_everything() -> void:
	var had := has_staged() or has_pending() or has_active()
	cancel()
	if _adapter != null and _adapter.has_method("clear_staged_preview"):
		_adapter.clear_staged_preview()
	_debug["outcome"] = "cancelled"
	chat_busy.emit(false)
	chat_append.emit("ADVISOR", "명령을 취소했습니다." if had else "취소할 명령이 없습니다.")


## Window [취소]: staged -> pending -> active, else nothing.
func cancel_staged() -> void:
	if has_staged():
		var cid := str(_staged.get("command_id", ""))
		_clear_stage()
		_refresh_preview_state()
		_debug["outcome"] = "cancelled"
		chat_append.emit("ADVISOR", "명령을 취소했습니다.")
		command_finished.emit(cid, false, "cancelled")
	elif has_pending():
		_clear_pending()
		_debug["outcome"] = "cancelled"
		chat_append.emit("ADVISOR", "명령을 취소했습니다.")
	elif has_active():
		cancel()
		_refresh_preview_state()
		_debug["outcome"] = "cancelled"
		chat_busy.emit(false)
		chat_append.emit("ADVISOR", "명령을 취소했습니다.")


## Silent staged drop (config change path): no chat spam.
func silent_drop_staged() -> void:
	_clear_stage()
	_refresh_preview_state()


func _refresh_preview_state() -> void:
	if _adapter != null and _adapter.has_method("clear_staged_preview"):
		_adapter.clear_staged_preview()
	if _adapter != null and _adapter.has_method("update_approval"):
		_adapter.update_approval()


func _clear_pending() -> void:
	_pending = {}


func _clear_stage() -> void:
	_staged = {}


func _pending_fresh() -> bool:
	if _pending.is_empty():
		return false
	if _config_drifted(_pending):
		_clear_pending()
		return false
	var cur := _live_state()
	if int(cur.get("state_version", -2)) != int(_pending.get("state_version", -1)) \
			or str(cur.get("fingerprint", "")) != str(_pending.get("fingerprint", "")) \
			or _turn() != int(_pending.get("turn", -1)):
		_clear_pending()
		return false
	return true


# --- Snapshots ------------------------------------------------------------------

func _turn() -> int:
	if _truth != null and _truth.has_method("get_turn"):
		return int(_truth.get_turn())
	return 1


func _live_state() -> Dictionary:
	if _truth == null:
		return {}
	return {"state_version": int(_truth.get_version()),
		"fingerprint": str(_truth.fingerprint())}


func _state_drifted(rec: Dictionary) -> bool:
	var cur := _live_state()
	if cur.is_empty():
		return false
	return int(cur.get("state_version", -2)) != int(rec.get("state_version", -1)) \
		or str(cur.get("fingerprint", "")) != str(rec.get("fingerprint", ""))


func _config_drifted(rec: Dictionary) -> bool:
	return BackendCfgScript.config_identity() != str(rec.get("config_identity", ""))


func _staged_drifted() -> bool:
	if _staged.is_empty():
		return true
	if _config_drifted(_staged):
		return true
	var cur := _live_state()
	if int(cur.get("state_version", -2)) != int(_staged.get("state_version", -1)):
		return true
	if str(cur.get("fingerprint", "")) != str(_staged.get("fingerprint", "")):
		return true
	if _turn() != int(_staged.get("turn", -1)):
		return true
	if ClustersScript.frozen_signature() != str(_staged.get("cluster_sig", "")):
		return true
	return false


func _selected_unit() -> Dictionary:
	if _unit_manager == null or not _unit_manager.has_method("is_unit_selected"):
		return {}
	if not bool(_unit_manager.is_unit_selected()):
		return {}
	if not _unit_manager.has_method("get_selected_unit"):
		return {}
	var u: Variant = _unit_manager.get_selected_unit()
	return u as Dictionary if u is Dictionary else {}


func _battlefield() -> Dictionary:
	var bk: Dictionary = _integration.call("get_blue_knowledge")
	var occ: Dictionary = _projector.known_occupancy("blue")
	var grid: Node = _integration.get("hex_grid") as Node
	var cell_data: Dictionary = grid.get("cell_data") as Dictionary if grid else {}
	return {"bk": bk, "occ": occ, "cell_data": cell_data}


# --- Phase 1: intent ---------------------------------------------------------------

## Deictic reference detection (Godot owns reference, not tactics): the
## player points at the map-selected unit with demonstrative language.
## Returns the selected unit id or "". This never decides action/type —
## it only lets phase 1 be constrained and corrected to the pointed unit.
func _deictic_unit_id(text: String) -> String:
	var sel := _selected_unit()
	if sel.is_empty():
		return ""
	var re := RegEx.new()
	re.compile("(이|그|저)\\s*(부대|기병|보병|창병|궁병|정찰대?|공성대?|징집병?|징집대?|병력|유닛|놈들|애들)")
	if re.search(text) == null:
		return ""
	return str(sel.get("id", ""))


func _send_intent(command_id: String) -> void:
	var rec: Dictionary = _active[command_id]
	_pending_fresh() # drop silently when invalid; block below reflects that.
	var sel := _selected_unit()
	var deictic := _deictic_unit_id(str(rec.get("text", "")))
	if not deictic.is_empty():
		rec["deictic_unit"] = deictic
		_active[command_id] = rec
		_trace.append("DEICTIC -> %s" % deictic)
	var user_block := {
		"player_message": str(rec.get("text", "")),
		"turn": _turn(),
		"capabilities": capability_snapshot(),
		"deictic_reference": {} if str(rec.get("deictic_unit", "")).is_empty() else {
			"unit_id": str(rec.get("deictic_unit", "")),
			"directive": "The player points at this unit. Scope MUST be UNIT for it unless the message explicitly names a different scope.",
		},
		"friendly_layout": friendly_layout(),
		"selected_unit": {} if sel.is_empty() else {
			"id": str(sel.get("id", "")), "class": str(sel.get("class", "")).to_upper(),
			"faction": str(sel.get("faction", "")),
			"cluster": ClustersScript.cluster_of_unit(sel)},
		"pending_clarification": _pending.duplicate(true),
		"recent_history": _history_block(),
		"instruction": "Use capabilities + layout + pending to emit ONE command JSON with orders[] (one order per clause; one element for single orders). Whole-force words (전군/전부대/모두/전체) MUST become ALL_AVAILABLE, never a wing.",
	}
	_debug["phase1_context"] = user_block.duplicate(true)
	var system := IntentScript.ACTION_VOCAB + "\n\n" + IntentScript.SCOPE_VOCAB \
		+ "\n\n" + IntentScript.INTENT_SYSTEM_PROMPT
	# Phase-1 pins greedy decoding: intent is deterministic scope
	# semantics (measured: 0.2 sampled different shapes per run).
	_send_phase(command_id, "intent", system,
		"PLAYER_MESSAGE_JSON:\n" + JSON.stringify(user_block), 0.0)


func _history_block() -> Array:
	var out: Array = []
	for h in _history.slice(maxi(0, _history.size() - HISTORY_KEEP)):
		out.append({"user": str((h as Dictionary).get("user", "")).substr(0, HISTORY_CHARS),
			"advisor": str((h as Dictionary).get("advisor", "")).substr(0, HISTORY_CHARS)})
	return out


func _send_phase(command_id: String, phase: String, system: String, user_text: String,
		p_temp: float = -1.0) -> void:
	var rec: Dictionary = _active[command_id]
	rec["phase"] = phase
	rec["last_user_text"] = user_text
	_active[command_id] = rec
	var cfg := ConfigScript.describe(p_temp)
	if phase == "semantic":
		cfg = ConfigScript.describe_semantic(0.0)
	var started: Dictionary = _client.request_chat(command_id,
		str(cfg.get("endpoint", "")), str(cfg.get("model", "")),
		[{"role": "system", "content": system}, {"role": "user", "content": user_text}],
		cfg.get("options", {}), float(cfg.get("timeout_seconds", 120.0)),
		BackendCfgScript.get_api_key())
	_debug["phase"] = phase
	_debug["model"] = str(cfg.get("model", "?"))
	_debug["model_role"] = str(cfg.get("role", "TACTICAL_MODEL"))
	_debug["endpoint"] = str(cfg.get("endpoint", "?"))
	if not bool(started.get("ok", false)):
		if phase == "semantic":
			_semantic_note_fallback(command_id, "TINY_START", str(started.get("detail", "")))
			_send_intent(command_id)
			return
		_fail(command_id, str(started.get("code", "OFFLINE")),
			str(started.get("detail", "")), true)


# --- Transport callback -------------------------------------------------------------

func _on_chat_finished(request_id: String, result: Dictionary) -> void:
	if not _active.has(request_id):
		return # superseded/cancelled.
	var rec: Dictionary = _active[request_id]
	if _config_drifted(rec):
		_debug["stale_discarded"] = true
		_debug["outcome"] = "stale"
		_active.erase(request_id)
		chat_busy.emit(false)
		print("[ChatCmd] STALE_CHAT_RESPONSE_DISCARDED command=%s (config changed)" % request_id)
		return
	if not bool(result.get("ok", false)):
		if str(rec.get("phase", "")) == "semantic":
			if str(result.get("code", "")) == "MODEL_MISSING":
				_semantic_dead = true
			_semantic_note_fallback(request_id, "TINY_" + str(result.get("code", "OFFLINE")),
				str(result.get("detail", "")))
			_send_intent(request_id)
			return
		_fail(request_id, str(result.get("code", "OFFLINE")),
			str(result.get("detail", "")), true)
		return
	_debug["http_status"] = int(result.get("http_status", 0))
	_debug["latency_ms"] = int(result.get("latency_ms", 0))
	# done_reason=length means the thinking model exhausted the token
	# budget before emitting content (proven failure mode): recorded so a
	# repeat points at generation options, not at player language.
	_debug["done_reason"] = str(result.get("done_reason", ""))
	var raw := str(result.get("content_text", ""))
	_debug["raw_" + str(rec.get("phase", "?"))] = raw
	match str(rec.get("phase", "")):
		"intent":
			_handle_intent_response(request_id, rec, raw)
		"semantic":
			_handle_semantic_response(request_id, rec, raw)
		"select":
			_handle_select_response(request_id, rec, raw)
		"info":
			_handle_info_response(request_id, rec, raw)


func _repair_or_fail(command_id: String, phase: String, why: String,
		system: String, valid_hint: String) -> void:
	var rec: Dictionary = _active[command_id]
	if bool(rec.get("repair_used", false)):
		_debug["failure"] = "repair failed: %s" % why
		_fail(command_id, "MALFORMED", why, true)
		return
	rec["repair_used"] = true
	_active[command_id] = rec
	var template := IntentScript.INTENT_REPAIR_TEMPLATE if phase == "intent" \
		else IntentScript.SELECT_REPAIR_TEMPLATE
	var repair_text := (template % [why, valid_hint]) if phase == "select" else (template % why)
	# Repair without context is unanswerable (stateless transport): re-attach
	# the original request so the model can actually correct itself.
	repair_text += "\nORIGINAL_REQUEST:\n" + str(rec.get("last_user_text", ""))
	# A greedy Phase-1 violation would repeat deterministically: escalate
	# the repair sample so the second chance is a real second chance.
	var repair_temp := -1.0
	if phase == "intent":
		repair_temp = 0.4
	_send_phase(command_id, phase, system, repair_text, repair_temp)


func _intent_system() -> String:
	return IntentScript.ACTION_VOCAB + "\n\n" + IntentScript.SCOPE_VOCAB \
		+ "\n\n" + IntentScript.INTENT_SYSTEM_PROMPT


## True when a deictic point exists but the validated intent does not use
## it (wrong shape, or a different unit). Single-shot per command.
func _needs_deictic_retry(command_id: String, rec: Dictionary, intent: Dictionary) -> bool:
	var pointed := str(rec.get("deictic_unit", ""))
	if pointed.is_empty() or bool(rec.get("deictic_retry", false)):
		return false
	var scope: Dictionary = intent.get("scope", {})
	if str(scope.get("type", "")) != "UNIT":
		return true
	if str(scope.get("region", "")) == "SELECTED" and str(scope.get("unit_id", "")).is_empty():
		return false
	return str(scope.get("unit_id", "")).strip_edges().to_upper() != pointed.to_upper()


# --- Phase 1 response ------------------------------------------------------------------

func _handle_intent_response(command_id: String, rec: Dictionary, raw: String) -> void:
	var parsed := IntentScript.extract_json(raw)
	if parsed.is_empty():
		_repair_or_fail(command_id, "intent",
			"response contained no parseable JSON object", _intent_system(), "")
		return
	_debug["parsed_intent"] = (parsed as Dictionary).duplicate(true)
	var checked := IntentScript.validate_intent(parsed)
	if not bool(checked.get("ok", false)):
		_repair_or_fail(command_id, "intent", str(checked.get("why", "invalid intent")),
			_intent_system(), "")
		return
	var intent: Dictionary = checked.get("intent", {})
	# Deictic guardrail: one corrective retry when the model ignored an
	# explicit point-at-selected-unit reference. Never forced: a second
	# non-conforming answer is accepted as the model's judgment.
	if _needs_deictic_retry(command_id, rec, intent):
		rec["deictic_retry"] = true
		_active[command_id] = rec
		_trace.append("DEICTIC retry (model missed the pointed unit)")
		_send_phase(command_id, "intent", _intent_system(),
			"CORRECTION: the player pointed at selected unit %s (see deictic_reference). Scope MUST be UNIT for it unless the message explicitly names a different scope. Freestyle re-interpretation is not allowed here.\nORIGINAL:\n%s" % [str(rec.get("deictic_unit", "")), str(rec.get("last_user_text", ""))], 0.0)
		return
	rec["intent"] = intent
	_active[command_id] = rec
	_continue_with_intent(command_id, rec, intent)


## Semantic frontend fast path: ONE tiny-model call with compact context.
## No tactical matrix, no RED truth — selection pointer, pending, last
## scope only. Large-model Phase-1 stays the fallback, never the default.
func _semantic_should_try() -> bool:
	if _semantic_dead:
		return false
	if _semantic_strikes >= SEMANTIC_STRIKE_LIMIT:
		return false
	if not BackendCfgScript.is_ai_enabled():
		return false
	return not ConfigScript.semantic_model().is_empty()


func _send_semantic(command_id: String) -> void:
	var rec: Dictionary = _active[command_id]
	_pending_fresh() # drop silently when invalid; block below reflects that.
	var sel := _selected_unit()
	var sel_block := {}
	if not sel.is_empty():
		sel_block = {"id": str(sel.get("id", "")),
			"class": str(sel.get("class", "")).to_upper()}
	var hist := ""
	if not _history.is_empty():
		var h0: Dictionary = _history[_history.size() - 1]
		hist = "last user: %s / advisor: %s" % [str(h0.get("user", "")), str(h0.get("advisor", ""))]
	var ctx := FrontendScript.build_ctx(sel_block, _pending.duplicate(true),
		str(_last_advice.get("scope_label", "")), hist)
	_debug["semantic_ctx"] = ctx.duplicate(true)
	var messages := FrontendScript.build_messages(str(rec.get("text", "")), ctx)
	_semantic_used += 1
	_send_phase(command_id, "semantic",
		str((messages[0] as Dictionary).get("content", "")),
		str((messages[1] as Dictionary).get("content", "")))


func _semantic_note_fallback(command_id: String, reason: String, why: String) -> void:
	_semantic_fallbacks += 1
	# Transport failures are not model evidence: only semantic-level
	# failures (bad schema / gate rejection) count toward the breaker.
	if not reason.begins_with("TINY_OFFLINE") and not reason.begins_with("TINY_TIMEOUT") \
			and reason != "TINY_START" and not reason.begins_with("TINY_HTTP"):
		_semantic_strikes += 1
	_debug["semantic_fallback"] = true
	_debug["semantic_fallback_reason"] = reason
	_debug["semantic_why"] = why
	_debug["semantic_strikes"] = _semantic_strikes
	_trace.append("SEMANTIC fallback %s (%s)" % [reason, why.left(60)])


func _semantic_gate_deps() -> Dictionary:
	var prev_ids: Array = (_last_advice.get("unit_ids", []) as Array).duplicate() \
		if (_last_advice.get("unit_ids", []) is Array) else []
	return {"unit_manager": _unit_manager, "selected_unit": _selected_unit(),
		"has_previous": not prev_ids.is_empty()}


## Tiny-model reply driver: envelope -> intent -> CommandIR -> gate.
## Valid COMMANDs continue with ZERO large-model calls. Questions continue
## into the existing large answer path (tiny route + large answer, never
## tiny parse + large re-parse). Gate STOPs close WITHOUT any large call.
## Anything invalid/uncertain falls back to the large Phase-1 path.
func _handle_semantic_response(command_id: String, rec: Dictionary, raw: String) -> void:
	_debug["semantic_raw"] = raw
	_debug["semantic_latency_ms"] = int(_debug.get("latency_ms", 0))
	if BackendCfgScript.semantic_identity() != str(rec.get("semantic_identity", BackendCfgScript.semantic_identity())) \
			and rec.has("semantic_identity"):
		_debug["stale_discarded"] = true
		_debug["outcome"] = "stale"
		_active.erase(command_id)
		chat_busy.emit(false)
		print("[ChatCmd] STALE_SEMANTIC_RESPONSE_DISCARDED command=%s (semantic config changed)" % command_id)
		return
	var text := str(rec.get("text", ""))
	var fp := FrontendScript.full_pass(raw, text, _semantic_gate_deps())
	if not bool(fp.get("ok", false)):
		_semantic_note_fallback(command_id, str(fp.get("fallback_reason", "TINY_FAIL")),
			str(fp.get("why", "")))
		_send_intent(command_id)
		return
	var env: Dictionary = fp.get("envelope", {})
	var intent: Dictionary = fp.get("intent", {})
	var ir: Dictionary = fp.get("ir", {})
	var gate: Dictionary = fp.get("gate", {})
	rec["intent"] = intent
	rec["orders"] = _orders_of(intent)
	rec["command_ir"] = ir.duplicate(true)
	rec["envelope"] = env.duplicate(true)
	_debug["semantic_fallback"] = false
	_debug["semantic_mode"] = str(env.get("mode", "?"))
	_debug["semantic_confidence"] = float(env.get("confidence", 0.0))
	_debug["semantic_fp"] = str(ir.get("fingerprint", ""))
	_debug["semantic_gate"] = gate.duplicate(true)
	_debug["semantic_lane"] = str(gate.get("lane", ""))
	_semantic_strikes = 0
	_debug["semantic_strikes"] = _semantic_strikes
	_debug["command_ir"] = CommandIRScript.dev_diagnostics(ir)
	_debug["command_ir_fp"] = str(ir.get("fingerprint", ""))
	_debug["intent_fingerprint"] = IntentScript.intent_fingerprint(intent)
	_debug["orders_fingerprint"] = orders_fingerprint(rec["orders"])
	_active[command_id] = rec
	_trace.append("SEMANTIC %s %s gate=%s/%s" % [str(env.get("mode", "?")),
		str(ir.get("fingerprint", "")).left(60),
		str(gate.get("verdict", "?")), str(gate.get("stop_kind", gate.get("lane", "")))])
	if str(gate.get("verdict", "")) == "STOP":
		_debug["outcome"] = "semantic:" + str(gate.get("stop_kind", "STOP"))
		var clar := str(gate.get("clarification", ""))
		if clar.is_empty():
			clar = "명령을 확정하지 못했습니다. 다시 말씀해 주십시오."
		_push_history(text, clar)
		_say_and_close(command_id, clar, "semantic:" + str(gate.get("stop_kind", "STOP")))
		return
	_continue_with_intent(command_id, rec, intent)


## Shared continuation for a VALIDATED intent (large Phase-1 and semantic
## frontend converge here). rec already holds text/snapshots; intent is the
## normalized intent dict. Never calls inference itself except through the
## existing route/info paths.
func _continue_with_intent(command_id: String, rec: Dictionary, intent: Dictionary) -> void:
	rec["intent"] = intent
	rec["orders"] = _orders_of(intent)
	# CommandIR v2 canonical layer (Step 1, additive): normalize the SAME
	# validated intent + ORIGINAL text. Routing below is unchanged; the IR
	# is the inspectable canonical truth for Step 2. Failures are
	# diagnostic-only here (never a new MALFORMED for legacy-safe shapes).
	var _ir := CommandIRScript.from_validated_intent(intent, str(rec.get("text", "")))
	if bool(_ir.get("ok", false)):
		var _irv: Dictionary = _ir.get("ir", {})
		rec["command_ir"] = (_irv as Dictionary).duplicate(true)
		_debug["command_ir"] = CommandIRScript.dev_diagnostics(_irv)
		_debug["command_ir_fp"] = str(_irv.get("fingerprint", ""))
	else:
		_debug["command_ir_error"] = str(_ir.get("why", "?"))
	_trace.append("COMMANDIR %s" % str((_ir.get("ir", {}) as Dictionary).get("fingerprint", str(_ir.get("why", "?")))).left(90))
	_active[command_id] = rec
	_debug["intent_fingerprint"] = IntentScript.intent_fingerprint(intent)
	_debug["orders_fingerprint"] = orders_fingerprint(rec["orders"])
	_trace.append("TYPE=%s ACTION=%s SCOPE=%s/%s/%s CONF=%.2f" % [
		str(intent.get("request_type", "")), str(intent.get("action", "")),
		str((intent.get("scope", {}) as Dictionary).get("type", "")),
		str((intent.get("scope", {}) as Dictionary).get("class", "")),
		str((intent.get("scope", {}) as Dictionary).get("region", "")),
		float(intent.get("confidence", 0.0))])
	var rtype := str(intent.get("request_type", ""))
	if rtype == "CLARIFICATION":
		_handle_model_clarification(command_id, rec, intent)
		return
	if float(intent.get("order_confidence", intent.get("confidence", 0.0))) < LOW_CONFIDENCE and rtype == "COMMAND":
		_set_pending(command_id, intent, ["region"],
			"명령의 대상이 분명치 않습니다. 좌익·중앙·우익·극좌익·극우익 중 어느 기병대를 말씀하십니까?")
		_ask_pending(command_id)
		return
	# Multi-order commands bypass single-order pending slot-filling (their
	# scopes are total expressions); a full multi-order command still
	# supersedes any pending clarification.
	if (rec.get("orders", []) as Array).size() > 1:
		_consume_pending_if_filled(intent)
		if rtype == "INFORMATION":
			_answer_information(command_id, rec, intent)
			return
		_route_command(command_id, rec, intent, rtype)
		return
	# "Both" answer to a wing question: pending wings + class-wide reply
	# (region ALL/empty, or explicit regions) resolve to the offered set.
	# Deterministic Godot-side slot filling, not a model re-parse.
	if _apply_pending_both(intent):
		rec["intent"] = intent
		rec["orders"] = _orders_of(intent)
		var _ir2 := CommandIRScript.from_validated_intent(intent, str(rec.get("text", "")))
		if bool(_ir2.get("ok", false)):
			rec["command_ir"] = ((_ir2.get("ir", {}) as Dictionary).duplicate(true))
			_debug["command_ir"] = CommandIRScript.dev_diagnostics(_ir2.get("ir", {}))
		_active[command_id] = rec
	# A full explicit command supersedes any pending clarification.
	_consume_pending_if_filled(intent)
	if rtype == "INFORMATION":
		_answer_information(command_id, rec, intent)
		return
	_route_command(command_id, rec, intent, rtype)


## Model-issued clarification: keep partial fields, ask its question verbatim.
func _handle_model_clarification(command_id: String, rec: Dictionary, intent: Dictionary) -> void:
	var scope: Dictionary = intent.get("scope", {})
	var missing: Array = (intent.get("missing", []) as Array).duplicate()
	if missing.is_empty():
		if str(intent.get("action", "")).is_empty() and not missing.has("action"):
			missing.append("action")
		if str(scope.get("region", "")).is_empty() and not missing.has("region"):
			missing.append("region")
		if missing.is_empty():
			missing.append("region")
	_set_pending(command_id, intent, missing, str(intent.get("question", "")))
	_ask_pending(command_id)


func _set_pending(command_id: String, intent: Dictionary, missing: Array, question: String) -> void:
	var rec: Dictionary = _active.get(command_id, {})
	var scope: Dictionary = intent.get("scope", {})
	_set_pending_raw({
		"command_id": command_id,
		"original_text": str(rec.get("text", "")),
		"action": str(intent.get("action", "")),
		"scope_type": str(scope.get("type", "")),
		"class": str(scope.get("class", "")),
		"region": str(scope.get("region", "")),
		"unit_id": str(scope.get("unit_id", "")),
		"missing": missing.duplicate(),
		"question": question,
	})
	_trace.append("PENDING missing=[%s]" % ", ".join(missing))


func _set_pending_raw(data: Dictionary) -> void:
	_pending = data
	_pending["state_version"] = int(_truth.get_version())
	_pending["fingerprint"] = str(_truth.fingerprint())
	_pending["turn"] = _turn()
	_pending["config_identity"] = BackendCfgScript.config_identity()


func _ask_pending(command_id: String) -> void:
	var q := str(_pending.get("question", "어느 부대를 말씀하십니까?"))
	if q.strip_edges().is_empty():
		q = "어느 부대를 말씀하십니까? 좌익·중앙·우익 중 지정해 주십시오."
	_push_history(str((_active.get(command_id, {}) as Dictionary).get("text", "")), q)
	_say_and_close(command_id, q, "clarify")


## A new full command consumes pending when it fills the missing fields (or
## re-specifies everything explicitly). A regions[] union also fills region.
func _consume_pending_if_filled(intent: Dictionary) -> void:
	if _pending.is_empty():
		return
	# A full multi-order COMMAND always supersedes pending (its scopes are
	# total expressions, not slot fills).
	if str(intent.get("request_type", "")) == "COMMAND" \
			and (intent.get("orders", []) as Array).size() > 1:
		_trace.append("PENDING superseded by multi-order command")
		_clear_pending()
		return
	var scope: Dictionary = intent.get("scope", {})
	var filled := true
	for m in (_pending.get("missing", []) as Array):
		match str(m):
			"action":
				if str(intent.get("action", "")).is_empty():
					filled = false
			"class":
				if str(scope.get("class", "")).is_empty():
					filled = false
			"region", "scope":
				if str(scope.get("region", "")).is_empty() \
						and ((scope.get("regions", []) as Array).is_empty()):
					filled = false
	if filled:
		_trace.append("PENDING filled by new intent")
		_clear_pending()
	elif str(intent.get("request_type", "")) == "COMMAND" \
			and not str(intent.get("action", "")).is_empty() \
			and (not str(scope.get("region", "")).is_empty() \
				or not (scope.get("regions", []) as Array).is_empty()):
		_trace.append("PENDING superseded by explicit command")
		_clear_pending()


## "Both" continuation: pending wing question + class-wide reply means the
## OFFERED wings (exactly two), preserving the pending action/class. More
## than two offered stays ambiguous (re-ask path handles it downstream).
## Returns true when the intent was rewritten to UNION.
func _apply_pending_both(intent: Dictionary) -> bool:
	if _pending.is_empty():
		return false
	if not _pending_fresh():
		return false
	if not (_pending.get("missing", []) as Array).has("region"):
		return false
	var scope: Dictionary = intent.get("scope", {})
	if not (scope.get("regions", []) as Array).is_empty():
		return false # explicit regions: normal union path handles it.
	var region := str(scope.get("region", "")).strip_edges().to_upper()
	if region != "ALL" and region != "":
		return false
	var paction := str(_pending.get("action", ""))
	if not paction.is_empty() and str(intent.get("action", "")) != paction:
		return false # different action: genuinely new command.
	var offered: Array = (_pending.get("wings", []) as Array).duplicate()
	if offered.size() != 2:
		return false
	var pcls := str(_pending.get("class", "CAVALRY"))
	if pcls.is_empty():
		pcls = "CAVALRY"
	var icls := str(scope.get("class", ""))
	if not icls.is_empty() and icls != pcls:
		return false
	offered.sort()
	scope["type"] = "UNION"
	scope["class"] = pcls
	scope["region"] = ""
	scope["regions"] = offered
	intent["scope"] = scope
	_trace.append("PENDING both -> UNION[%s]" % ", ".join(offered))
	_clear_pending()
	return true


# --- Routing (capability gate) ------------------------------------------------------------

## Expression-scope route: membership from the algebra, staging through
## the EXISTING machinery (doctrine packages for ADVANCE/RECON,
## per-unit canonical HOLDs for HOLD). No expression-specific execution
## path. Caps match legacy scopes (MAX_SCOPE_UNITS, noted explicitly).
func _route_expr(command_id: String, rec: Dictionary, intent: Dictionary,
		rtype: String, expr: Dictionary) -> void:
	var action := str(intent.get("action", ""))
	# Whole-force expression ADVANCE (ALL_COMBAT / ALL_FRIENDLY) takes the
	# SAME native whole-force path as legacy ALL_AVAILABLE: shape must not
	# change gameplay meaning (native includes HQ/supply wagons in the
	# planner maneuver set by long-standing shipped behavior; the doctrine
	# path would hold them out via policy exclusion).
	var norm0 := AlgebraScript.normalize(expr)
	if action == "ADVANCE" and (AlgebraScript.fingerprint(norm0) == "ALL_COMBAT" \
			or AlgebraScript.fingerprint(norm0) == "ALL_FRIENDLY"):
		_trace.append("ROUTE-EXPR whole-force -> native")
		_stage_native_whole(command_id, rec, intent, rtype)
		return
	# SELECTED freeze via the shared helper (stable regen/approval).
	var frozen: Dictionary = expr.duplicate(true)
	var fro := _freeze_selected_expr(expr)
	if bool(fro.get("terminal", false)):
		_say_and_close(command_id, "선택된 아군 부대가 없습니다. 지도에서 부대를 고르고 다시 말씀해 주십시오.", "fail:NO_SELECTION")
		return
	frozen = fro.get("expr", {})
	if AlgebraScript.fingerprint(frozen) != AlgebraScript.fingerprint(expr):
		_trace.append("SELECTED freeze applied")
		intent["scope_expr"] = frozen
		rec["orders"] = _orders_of(intent)
		_active[command_id] = rec
	var norm := AlgebraScript.normalize(frozen)
	var r := AlgebraScript.resolve(norm, {
		"unit_manager": _unit_manager, "selected_unit": _selected_unit()})
	_debug["scope_resolution"] = {"ok": true,
		"expr_fp": AlgebraScript.fingerprint(expr),
		"frozen_fp": AlgebraScript.fingerprint(frozen),
		"norm_fp": AlgebraScript.fingerprint(norm),
		"count": int(r.get("total", 0)),
		"classes": (r.get("classes", {}) as Dictionary).duplicate(true)}
	if bool(r.get("empty", true)):
		_say_and_close(command_id, "해당 조건에 속한 부대가 없습니다.", "fail:EMPTY_SCOPE")
		return
	var ids: Array = (r.get("unit_ids", []) as Array).duplicate()
	# Semantic completeness: the FULL resolved set stages. HOLDs execute
	# sequentially per unit; doctrine selection runs in chunks. Never slice
	# membership to fit one model call. The staged label is player-natural;
	# DEV keeps structural fingerprints in debug.
	var label := AlgebraScript.describe_scope_kr(norm)
	rec["unit_ids"] = ids
	rec["scope_label"] = label
	rec["scope_expr_fp"] = AlgebraScript.fingerprint(frozen)
	_active[command_id] = rec
	if action in CHAT_DOCTRINE_ACTIONS:
		_package_and_select(command_id, rec, intent, rtype)
		return
	if action == "HOLD":
		_stage_hold_items(command_id, rec, intent, rtype)
		return
	_limitation(command_id, intent,
		"%s 명령은 이해했지만 채팅 실행은 아직 병과 전진·정찰·대기와 전군 진격에 한정되어 있습니다." % action)


# --- Composite multi-order flow -------------------------------------------------
#
# One message, several orders, ONE combined staged plan. Each order keeps
## its own action + scope; Godot resolves every scope, gates overlaps,
## evaluates/selects per order through the EXISTING single-order machinery,
## then merges into one staged operation (single approval, canonical
## sequential execution: moves first, then holds). Any order-level terminal
## failure aborts the whole command honestly (nothing staged yet).

static func _composite_active(rec: Dictionary) -> bool:
	return rec.has("composite") and (rec.get("composite", {}) as Dictionary).has("orders")


## Order dict -> single-intent-shaped dict for the shared per-order helpers.
func _order_intent(order: Dictionary, rtype: String) -> Dictionary:
	return {"action": str(order.get("action", "")),
		"scope": (order.get("scope", {}) as Dictionary).duplicate(true),
		"scope_expr": (order.get("scope_expr", {}) as Dictionary).duplicate(true),
		"style": (order.get("style", {}) as Dictionary).duplicate(true),
		"request_type": rtype,
		"confidence": float(order.get("confidence", 0.0)),
		"question": "", "missing": []}


func _route_composite(command_id: String, rec: Dictionary, intent: Dictionary,
		rtype: String) -> void:
	var orders: Array = rec.get("orders", [])
	_trace.append("COMPOSITE %d orders" % orders.size())
	var deps := {"unit_manager": _unit_manager, "selected_unit": _selected_unit()}
	var resolved := resolve_orders(orders, deps)
	_debug["composite_resolution"] = resolved.duplicate(true)
	var ov := analyze_order_overlap(orders, deps)
	_debug["composite_overlap"] = ov.duplicate(true)
	var conflicts: Array = []
	for p in ov:
		if str((p as Dictionary).get("relation", "")) == "overlap_conflict":
			conflicts.append(p)
	if not conflicts.is_empty():
		var first: Dictionary = conflicts[0]
		var shared: Array = (first.get("shared_ids", []) as Array).duplicate()
		shared.sort()
		_set_pending(command_id, intent, ["scope"],
			"두 명령이 %s에서 겹쳐 서로 다른 행동을 요구합니다. 어느 쪽을 우선할지 말씀해 주십시오." % _unit_disp_list(shared))
		_ask_pending(command_id)
		return
	# Same-action overlaps: first order wins; later duplicates are stripped
	# (documented, never double-executed).
	var res_lists: Array = []
	for r in resolved:
		res_lists.append(((r as Dictionary).get("unit_ids", []) as Array).duplicate())
	var strip_notes: Array = []
	for p in ov:
		if str((p as Dictionary).get("relation", "")) != "overlap_same_action":
			continue
		var a := int((p as Dictionary).get("a", -1))
		var b := int((p as Dictionary).get("b", -1))
		if a < 0 or b < 0 or a >= res_lists.size() or b >= res_lists.size():
			continue
		var aset := {}
		for uid in (res_lists[a] as Array):
			aset[str(uid)] = true
		var kept: Array = []
		var cut: Array = []
		for uid2 in (res_lists[b] as Array):
			if aset.has(str(uid2)):
				cut.append(str(uid2))
			else:
				kept.append(str(uid2))
		if not cut.is_empty():
			res_lists[b] = kept
			strip_notes.append(cut)
	rec["composite"] = {"orders": orders, "index": 0, "eval_index": 0,
		"resolved": res_lists, "evals": [], "selects": [], "sel_queue": [],
		"strip_notes": strip_notes}
	_active[command_id] = rec
	_composite_eval_next(command_id, rec, rtype)


## Composite per-order resolution: SELECTED-freeze, then legacy-compile
## + algebra (total semantics — composite scopes are explicit sets, so no
## ambiguity gate; remainder-complements REQUIRE totality). Terminal
## failures abort the whole command honestly. Returns {terminal} or
## {terminal:false, units, label}.
func _composite_resolve_order(command_id: String, rec: Dictionary,
		order: Dictionary) -> Dictionary:
	var ex: Dictionary = (order.get("scope_expr", {}) as Dictionary).duplicate(true)
	var fro := _freeze_selected_expr(ex)
	if bool(fro.get("terminal", false)):
		_say_and_close(command_id, "선택된 아군 부대가 없습니다. 지도에서 부대를 고르고 다시 말씀해 주십시오.", "fail:NO_SELECTION")
		return {"terminal": true}
	ex = fro.get("expr", {})
	var scope: Dictionary = order.get("scope", {})
	if ex.is_empty():
		# Composite totality: a legacy UNION naming wings but no combat
		# class ("우익은 전진") means the WHOLE wing maneuver body, not a
		# question — resolve over every combat class (single-order path
		# still asks; composite scopes are explicit sets). Deterministic,
		# so regen reproduces it without write-back.
		if str(scope.get("type", "")) == "UNION" \
				and str(order.get("action", "")) in CHAT_DOCTRINE_ACTIONS:
			var eff0 := scope_classes({"scope": scope})
			if (eff0["combat"] as Array).is_empty() \
					and (eff0["policy"] as Array).is_empty():
				var ures0 := _resolve_union_classes(
					(scope.get("regions", []) as Array).duplicate(),
					(DoctrinesScript.COMBAT_CLASSES as Array).duplicate())
				if bool(ures0.get("ok", false)):
					return {"terminal": false,
						"units": (ures0.get("unit_ids", []) as Array).duplicate(),
						"label": str(ures0.get("scope_label", ""))}
				_handle_scope_failure(command_id, ures0)
				return {"terminal": true}
		var leg := AlgebraScript.compile_legacy(scope)
		if not bool(leg.get("ok", false)):
			if str(leg.get("special", "")) == "PREVIOUS":
				_say_and_close(command_id, "직전 권고는 단일 명령에서 사용해 주십시오. 새로 명령해 주십시오.", "fail:PREVIOUS_IN_COMPOSITE")
			else:
				_say_and_close(command_id, "명령의 대상을 확정하지 못했습니다. 다시 말씀해 주십시오.", "fail:UNKNOWN_SCOPE")
			return {"terminal": true}
		ex = leg.get("expr", {})
	# Write-back keeps regen/approval stable (frozen intent travels).
	order["scope_expr"] = ex.duplicate(true)
	var norm := AlgebraScript.normalize(ex)
	var rr := AlgebraScript.resolve(norm, {
		"unit_manager": _unit_manager, "selected_unit": _selected_unit()})
	if bool(rr.get("empty", true)):
		_say_and_close(command_id, "해당 조건에 속한 부대가 없습니다.", "fail:EMPTY_SCOPE")
		return {"terminal": true}
	return {"terminal": false,
		"units": (rr.get("unit_ids", []) as Array).duplicate(),
		"label": AlgebraScript.describe_scope_kr(norm)}


## SELECTED-atom freeze helper shared by single and composite routes:
## {terminal} when a SELECTED node exists but nothing is pointed at;
## otherwise {terminal:false, expr} with nodes bound to the live id.
func _freeze_selected_expr(expr: Dictionary) -> Dictionary:
	if expr.is_empty() or not AlgebraScript.fingerprint(expr).contains("SELECTED"):
		return {"terminal": false, "expr": (expr as Dictionary).duplicate(true)}
	var sel := _selected_unit()
	if sel.is_empty() or str(sel.get("faction", "")) != "blue":
		return {"terminal": true}
	_trace.append("SELECTED freeze -> %s" % str(sel.get("id", "?")))
	return {"terminal": false,
		"expr": AlgebraScript.bind_selected(expr, str(sel.get("id", "")))}


## Evaluate orders sequentially (HOLD orders need no packages and pass
## straight through). Terminal per-order failures abort the whole command.
func _composite_eval_next(command_id: String, rec: Dictionary, rtype: String) -> void:
	var comp: Dictionary = rec.get("composite", {})
	var orders: Array = comp.get("orders", [])
	var idx := int(comp.get("eval_index", 0))
	if idx >= orders.size():
		_composite_select_start(command_id, rec, rtype)
		return
	var order: Dictionary = orders[idx]
	var ointent := _order_intent(order, rtype)
	var action := str(ointent.get("action", ""))
	if action == "HOLD":
		comp["eval_index"] = idx + 1
		_active[command_id] = rec
		_trace.append("COMPOSITE order %d HOLD (%d units, no packaging)" % [idx,
			((comp.get("resolved", []) as Array)[idx] as Array).size() if idx < (comp.get("resolved", []) as Array).size() else 0])
		_composite_eval_next(command_id, rec, rtype)
		return
	if not action in CHAT_DOCTRINE_ACTIONS:
		_limitation(command_id, ointent,
			"%s 명령은 이해했지만 채팅 실행은 아직 병과 전진·정찰·대기와 전군 진격에 한정되어 있습니다." % action)
		return
	var ro := _composite_resolve_order(command_id, rec, order)
	if bool(ro.get("terminal", false)):
		return
	var units: Array = (ro.get("units", []) as Array).duplicate()
	var label := str(ro.get("label", ""))
	# Intersect with the overlap-gated resolved set (same-action dedupe).
	var gated: Array = ((comp.get("resolved", []) as Array)[idx] as Array).duplicate() \
		if idx < (comp.get("resolved", []) as Array).size() else units.duplicate()
	var gset := {}
	for uid in gated:
		gset[str(uid)] = true
	var final_units: Array = []
	for uid2 in units:
		if gset.has(str(uid2)):
			final_units.append(str(uid2))
	rec["unit_ids"] = final_units
	rec["scope_label"] = label
	_active[command_id] = rec
	var ev := _eval_packages(command_id, rec, ointent)
	if bool(ev.get("terminal", false)):
		return
	var evals: Array = comp.get("evals", [])
	while evals.size() <= idx:
		evals.append({})
	evals[idx] = {"pkgs": (ev.get("pkgs", {}) as Dictionary).duplicate(true),
		"unevaluable": (ev.get("unevaluable", []) as Array).duplicate(true),
		"label": str(rec.get("scope_label", ""))}
	comp["evals"] = evals
	comp["eval_index"] = idx + 1
	_active[command_id] = rec
	_composite_eval_next(command_id, rec, rtype)


## Begin (or continue) selection over doctrine orders: swap in each
## order's packages, run the shared chunked selection, capture picks.
func _composite_select_start(command_id: String, rec: Dictionary, rtype: String) -> void:
	var comp: Dictionary = rec.get("composite", {})
	var orders: Array = comp.get("orders", [])
	var queue: Array = []
	for i in range(orders.size()):
		var a := str((orders[i] as Dictionary).get("action", ""))
		if a in CHAT_DOCTRINE_ACTIONS and (comp.get("evals", []) as Array).size() > i \
				and not ((comp.get("evals", []) as Array)[i] as Dictionary).is_empty():
			queue.append(i)
	if queue.is_empty():
		_stage_composite(command_id, rec, rtype)
		return
	comp["sel_queue"] = queue
	comp["sel_pos"] = 0
	_active[command_id] = rec
	_composite_select_one(command_id, rec, rtype)


func _composite_select_one(command_id: String, rec: Dictionary, rtype: String) -> void:
	var comp: Dictionary = rec.get("composite", {})
	var queue: Array = comp.get("sel_queue", [])
	var pos := int(comp.get("sel_pos", 0))
	if pos >= queue.size():
		_stage_composite(command_id, rec, rtype)
		return
	var oi := int(queue[pos])
	var orders: Array = comp.get("orders", [])
	var evals: Array = comp.get("evals", [])
	var ev: Dictionary = evals[oi]
	rec["packages"] = (ev.get("pkgs", {}) as Dictionary).duplicate(true)
	rec["unit_ids"] = (rec.get("packages", {}) as Dictionary).keys()
	rec["scope_label"] = str(ev.get("label", ""))
	rec["select_chunks"] = []
	rec["select_index"] = 0
	rec["select_results"] = {}
	rec["select_reasons"] = []
	rec["select_conf"] = 1.0
	_active[command_id] = rec
	_send_selection(command_id, rec, _order_intent(orders[oi], rtype), rtype)


## Capture one order's merged picks; advance to the next selecting order
## or to the merged staging.
func _composite_capture_selection(command_id: String, rec: Dictionary,
		profiles: Dictionary, reason: String) -> void:
	var comp: Dictionary = rec.get("composite", {})
	var queue: Array = comp.get("sel_queue", [])
	var pos := int(comp.get("sel_pos", 0))
	var selects: Array = comp.get("selects", [])
	while selects.size() < (comp.get("orders", []) as Array).size():
		selects.append({})
	selects[int(queue[pos])] = {"profiles": profiles.duplicate(true),
		"reason": reason, "conf": float(rec.get("select_conf", 0.0))}
	comp["selects"] = selects
	comp["sel_pos"] = pos + 1
	_active[command_id] = rec
	_trace.append("COMPOSITE order %d selected (%d units)" % [int(queue[pos]), profiles.size()])
	_composite_select_one(command_id, rec, str((rec.get("intent", {}) as Dictionary).get("request_type", "COMMAND")))


## Merge all orders into ONE staged operation (single approval).
func _stage_composite(command_id: String, rec: Dictionary, rtype: String) -> void:
	var comp: Dictionary = rec.get("composite", {})
	var orders: Array = comp.get("orders", [])
	var evals: Array = comp.get("evals", [])
	var selects: Array = comp.get("selects", [])
	var resolved: Array = comp.get("resolved", [])
	var moves_items: Array = []
	var all_pkgs := {}
	var holds_units: Array = []
	var labels: Array = []
	var reasons: Array = []
	var all_unit_ids: Array = []
	var seen := {}
	for i in range(orders.size()):
		var order: Dictionary = orders[i]
		var action := str(order.get("action", ""))
		if action == "HOLD":
			var hu: Array = (resolved[i] as Array).duplicate() if i < resolved.size() else []
			for uid in hu:
				if not seen.has(str(uid)):
					seen[str(uid)] = true
					holds_units.append(str(uid))
					all_unit_ids.append(str(uid))
			if not hu.is_empty():
				labels.append(_describe_scope(_order_intent(order, rtype)) + " 대기")
			continue
		if i >= selects.size() or (selects[i] as Dictionary).is_empty():
			continue
		var sel: Dictionary = selects[i]
		var ev: Dictionary = evals[i] if i < evals.size() else {}
		var opkgs: Dictionary = ev.get("pkgs", {})
		for k in opkgs.keys():
			all_pkgs[str(k)] = opkgs[k]
		var oi := _selections_to_items((sel.get("profiles", {}) as Dictionary), opkgs)
		for it in oi:
			moves_items.append(it)
			if not seen.has(str((it as Dictionary).get("unit_id", ""))):
				seen[str((it as Dictionary).get("unit_id", ""))] = true
				all_unit_ids.append(str((it as Dictionary).get("unit_id", "")))
		if not oi.is_empty():
			labels.append(str((ev.get("label", "") as String)))
		if not str(sel.get("reason", "")).is_empty():
			reasons.append(str(sel.get("reason", "")))
	if moves_items.is_empty() and holds_units.is_empty():
		_fail(command_id, "NO_OPTIONS", "composite empty", false,
			"현재 상황에서 실행 가능한 편성안이 없습니다.")
		return
	# Merged destination deconfliction across ALL moves orders.
	var adapted: Array = []
	var dropped: Array = []
	var contended := 0
	if not moves_items.is_empty():
		var dc := deconflict_destinations(moves_items, all_pkgs)
		moves_items = (dc["items"] as Array).duplicate(true)
		adapted = (dc["adapted"] as Array).duplicate(true)
		dropped = (dc["dropped"] as Array).duplicate(true)
		contended = int(dc["contended"])
		if not adapted.is_empty():
			reasons.append("%s은 목표 헥스가 겹쳐 동등한 인접 실현으로 조정했습니다." % _unit_disp_list(adapted))
		if not dropped.is_empty():
			if moves_items.is_empty() and holds_units.is_empty():
				_fail(command_id, "NO_OPTIONS", "all contended", false,
					"겹치지 않는 목표를 찾지 못해 이번 명령을 편성하지 못했습니다.")
				return
			reasons.append("%s은 겹치지 않는 실현이 없어 이번 편성에서 제외했습니다." % _unit_disp_list(dropped))
	for it in moves_items:
		var iuid := str((it as Dictionary).get("unit_id", ""))
		(it as Dictionary)["fallbacks"] = _fallback_options(
			all_pkgs.get(iuid, {}), it as Dictionary)
	var kept: Array = []
	for it in moves_items:
		kept.append(str((it as Dictionary).get("unit_id", "")))
	for uid in holds_units:
		if not uid in kept:
			kept.append(uid)
	rec["unit_ids"] = kept
	var dropped_ids := {}
	for d in dropped:
		dropped_ids[str((d as Dictionary).get("unit_id", ""))] = true
	var final_ids: Array = []
	for uid in all_unit_ids:
		if not dropped_ids.has(uid):
			final_ids.append(uid)
	rec["unit_ids"] = final_ids
	# Combined label: per-order labels joined; strip-note from dedupe.
	var scope_label := " + ".join(labels)
	var strip_notes: Array = comp.get("strip_notes", [])
	if not strip_notes.is_empty():
		var flat: Array = []
		for s in strip_notes:
			for uid in (s as Array):
				flat.append(str(uid))
		scope_label += " (중복 %d기 정리)" % flat.size()
		_trace.append("COMPOSITE dedupe %s" % str(flat))
	rec["scope_label"] = scope_label
	rec["deconflict"] = {"adapted": adapted, "dropped": dropped, "contended": contended}
	_debug["deconflict"] = {"adapted": adapted.size(), "dropped": dropped.size(), "contended": contended}
	_debug["deconflict_detail"] = {"adapted": adapted, "dropped": dropped}
	_active[command_id] = rec
	var items_all: Array = moves_items.duplicate(true)
	for uid in holds_units:
		var u := _unit_dict(str(uid))
		items_all.append({"unit_id": str(uid),
			"from": [int(u.get("q", 0)), int(u.get("r", 0))]})
	if rtype == "ADVICE":
		_last_advice = {"unit_ids": final_ids.duplicate(),
			"profiles": _merged_profiles(comp),
			"composite_orders": (orders as Array).duplicate(true),
			"action": "MIXED",
			"scope_label": scope_label,
			"state_version": int(_truth.get_version()),
			"fingerprint": str(_truth.fingerprint()),
			"config_identity": BackendCfgScript.config_identity(),
			"text": " ".join(reasons)}
		_push_history(str(rec.get("text", "")), " ".join(reasons))
		_say_and_close(command_id, "%s\n(권고만 — 실행하지 않았습니다.)" % " ".join(reasons), "advice")
		return
	_stage(command_id, rec, rec.get("intent", {}), "composite", items_all, {})
	_push_history(str(rec.get("text", "")), " ".join(reasons))
	_say(command_id, " ".join(reasons))
	_after_stage_announce(command_id)


## Merged move profiles across composite orders (DEV/advice records).
static func _merged_profiles(comp: Dictionary) -> Dictionary:
	var out := {}
	for s in (comp.get("selects", []) as Array):
		if s is Dictionary:
			for k in ((s as Dictionary).get("profiles", {}) as Dictionary).keys():
				out[str(k)] = str(((s as Dictionary).get("profiles", {}) as Dictionary)[k])
	return out


func _route_command(command_id: String, rec: Dictionary, intent: Dictionary,
		rtype: String) -> void:
	var orders: Array = rec.get("orders", [])
	# Multi-order messages take the composite flow (ONE combined staged
	# plan); single orders keep the exact legacy path below.
	if orders.size() > 1:
		_route_composite(command_id, rec, intent, rtype)
		return
	var action := str(intent.get("action", ""))
	var scope: Dictionary = intent.get("scope", {})
	var stype := str(scope.get("type", ""))
	var cls := str(scope.get("class", ""))
	_trace.append("ROUTE action=%s type=%s class=%s" % [action, stype, cls])
	# Compositional scope expression (set-algebra AST) takes precedence
	# for MEMBERSHIP when present: expressions are total (explicit sets),
	# so no ambiguity gate applies. Legacy PREVIOUS keeps its own flow.
	var expr: Dictionary = intent.get("scope_expr", {})
	if not expr.is_empty() and stype != "PREVIOUS":
		_trace.append("ROUTE-EXPR %s" % AlgebraScript.fingerprint(expr))
		_route_expr(command_id, rec, intent, rtype, expr)
		return
	_correct_selected_scope(intent)
	rec["orders"] = _orders_of(intent)
	_active[command_id] = rec
	# Whole-force (ALL arms, ALL bands) executes natively regardless of the
	# shape token: intent is whole-army when class is ALL_ARMS (or empty)
	# with region ALL/empty. A class-scoped ALL is NOT whole-force: it
	# enters the class-wide ambiguity gate below (multi-wing must ask, never
	# silently sprawl; single-wing resolves).
	if action == "ADVANCE" and region_in(_scope_region(intent), ["ALL", ""]) \
			and (cls == "ALL_ARMS" or (cls.is_empty() and stype == "ALL_AVAILABLE")) \
			and stype in ["ALL_AVAILABLE", "WING_CLASS", "CLUSTER_CLASS", ""]:
		_stage_native_whole(command_id, rec, intent, rtype)
		return
	if action in CHAT_DOCTRINE_ACTIONS and region_in(_scope_region(intent), ["ALL", ""]) \
			and stype in ["ALL_AVAILABLE", "WING_CLASS", "CLUSTER_CLASS", ""]:
		_resolve_class_wide(command_id, rec, intent, rtype)
		return
	if action in CHAT_NATIVE_ANY_SCOPE and action == "HOLD":
		if stype == "UNION":
			_stage_multi_hold(command_id, rec, intent, rtype)
			return
		_stage_native_hold(command_id, rec, intent, rtype)
		return
	if action in CHAT_DOCTRINE_ACTIONS and DoctrinesScript.is_doctrine_class(cls) \
			and stype in ["WING_CLASS", "CLUSTER_CLASS", "UNIT", "PREVIOUS", "UNION"]:
		_resolve_and_package(command_id, rec, intent, rtype)
		return
	if action in CHAT_DOCTRINE_ACTIONS and stype == "UNION":
		# Class-less UNION for a stagable action (model skipped the class
		# question): ask instead of failing with a misleading message.
		# HQ/SUPPLY entries keep their explicit policy text below.
		var eff0 := scope_classes(intent)
		if (eff0["combat"] as Array).is_empty() \
				and (eff0["policy"] as Array).is_empty():
			_set_pending(command_id, intent, ["class"],
				"어느 병과를 말씀하십니까? 기병·보병·궁병·창병·정찰·공성·징집 중에서 지정해 주십시오.")
			_ask_pending(command_id)
			return
	if action in CHAT_DOCTRINE_ACTIONS and DoctrinesScript.needs_policy(cls):
		_limitation(command_id, intent, DoctrinesScript.policy_text(cls))
		return
	if action in CHAT_DOCTRINE_ACTIONS:
		_limitation(command_id, intent,
			"%s 명령은 이해했지만 자동 편성 대상이 아닙니다. 전투 병과(기병·보병·궁병·창병·정찰·공성·징집)로 지정해 주십시오." % _describe_scope(intent))
		return
	if action.is_empty() and rtype == "ADVICE":
		_set_pending(command_id, intent, ["action"],
			"어떤 행동에 대한 조언을 원하십니까? 전진·정찰·대기 중에서 말씀해 주십시오.")
		_ask_pending(command_id)
		return
	_limitation(command_id, intent,
		"%s 명령은 이해했지만 채팅 실행은 아직 병과 전진·정찰·대기와 전군 진격에 한정되어 있습니다." % action)


## Scope-cap honesty (invariant 9): when the resolver caps a large scope,
## the staged label says so explicitly instead of silently dropping units.
static func truncation_note(res: Dictionary) -> String:
	if not bool(res.get("truncated", false)):
		return ""
	var total := int(res.get("total", (res.get("unit_ids", []) as Array).size()))
	var kept := (res.get("unit_ids", []) as Array).size()
	return " (%d기 중 %d기만 편성)" % [total, kept]


func _describe_scope(intent: Dictionary) -> String:
	var expr: Dictionary = intent.get("scope_expr", {})
	if not expr.is_empty():
		return AlgebraScript.describe_scope_kr(expr)
	var scope: Dictionary = intent.get("scope", {})
	var cls := str(scope.get("class", ""))
	var region := str(scope.get("region", ""))
	var names := {"CAVALRY": "기병", "INFANTRY": "보병", "ARCHER": "궁병",
		"SPEARMAN": "창병", "SCOUT": "정찰", "SIEGE": "공성", "ALL_ARMS": "전 병력",
		"LEFT": "좌익", "RIGHT": "우익", "CENTER": "중앙",
		"EXTREME_LEFT": "극좌익", "EXTREME_RIGHT": "극우익", "ALL": "전군"}
	var regions: Array = scope.get("regions", [])
	if not regions.is_empty():
		var parts: Array = []
		for r in regions:
			parts.append(str(names.get(str(r), str(r))))
		region = "·".join(parts)
	return "%s %s" % [str(names.get(region, region)), str(names.get(cls, cls))]


func _limitation(command_id: String, intent: Dictionary, text: String) -> void:
	_trace.append("LIMITATION: %s" % text.substr(0, 60))
	_debug["outcome"] = "fail:NO_CAPABILITY"
	_push_history(str((_active.get(command_id, {}) as Dictionary).get("text", "")), text)
	_say_and_close(command_id, text, "fail:NO_CAPABILITY")


static func region_in(region: String, options: Array) -> bool:
	return region.strip_edges().to_upper() in options


static func _scope_region(intent: Dictionary) -> String:
	return str((intent.get("scope", {}) as Dictionary).get("region", ""))


## Deictic correction: a scope pointing at a Godot-known unit (SELECTED with
## a live selection, or an explicitly named unit_id) resolves class from the
## LIVE unit — the pointer is a Godot fact, the model token is a guess
## ("이 부대" + scout selected + CAVALRY token -> SCOUT; unit_id B_SCO_1 +
## empty class -> SCOUT). Traced, never silent. Unknown ids are left alone
## so resolution still fails honestly ("no such unit").
func _correct_selected_scope(intent: Dictionary) -> void:
	var scope: Dictionary = intent.get("scope", {})
	var pointed := {}
	var uid := str(scope.get("unit_id", "")).strip_edges()
	if not uid.is_empty():
		var found := ResolverScript.find_unit(uid, _unit_manager)
		if not found.is_empty() and str(found.get("faction", "")) == "blue":
			pointed = found
	elif str(scope.get("region", "")).strip_edges().to_upper() == "SELECTED":
		var sel := _selected_unit()
		if not sel.is_empty() and str(sel.get("faction", "")) == "blue":
			pointed = sel
	if pointed.is_empty():
		return
	var actual := str(pointed.get("class", "")).to_upper()
	if not actual.is_empty() and actual != str(scope.get("class", "")).strip_edges().to_upper():
		_trace.append("POINTER class %s->%s (live unit %s wins)" % [str(scope.get("class", "")), actual, str(pointed.get("id", "?"))])
		scope["class"] = actual
	# Freeze the pointer: the command means THIS formation even if the map
	# selection changes before approval (regen re-resolves the frozen id).
	var pid := str(pointed.get("id", "")).strip_edges().to_upper()
	if not pid.is_empty() and str(scope.get("unit_id", "")).strip_edges().to_upper() != pid:
		_trace.append("POINTER freeze -> %s" % pid)
		scope["unit_id"] = pid
	intent["scope"] = scope


## Class-wide scope with no band ("기병 전진", "보병 전진"): understood, but
## the wing is genuinely missing. Zero live units -> honest empty; exactly
## one wing -> deterministic resolve (no ambiguity exists); several ->
## structured pending + wing question. NEVER whole-force execution, NEVER a
## guessed wing. Works for every doctrine class, not just cavalry.
func _resolve_class_wide(command_id: String, rec: Dictionary, intent: Dictionary,
		rtype: String) -> void:
	var scope: Dictionary = intent.get("scope", {})
	var cls := str(scope.get("class", "CAVALRY"))
	if cls.is_empty():
		cls = "CAVALRY"
	if DoctrinesScript.needs_policy(cls):
		_limitation(command_id, intent, DoctrinesScript.policy_text(cls))
		return
	if not DoctrinesScript.is_doctrine_class(cls):
		_limitation(command_id, intent,
			"%s 명령은 이해했지만 자동 편성 대상이 아닙니다." % _describe_scope(intent))
		return
	var roster := ResolverScript.units_of_class(cls, _unit_manager)
	if roster.is_empty():
		_say_and_close(command_id, "현재 지휘 가능한 %s가 없습니다." % ViewModelScript.class_kr(cls), "fail:EMPTY_SCOPE")
		return
	var wings := ResolverScript.wings_of(roster)
	if wings.size() == 1:
		var only := str(wings[0])
		_trace.append("CLASS_WIDE single wing %s: deterministic resolve" % only)
		var scope2: Dictionary = (intent.get("scope", {}) as Dictionary).duplicate(true)
		scope2["type"] = "WING_CLASS"
		scope2["region"] = only
		intent["scope"] = scope2
		rec["intent"] = intent
		_active[command_id] = rec
		_resolve_and_package(command_id, rec, intent, rtype)
		return
	_set_pending_raw({
		"command_id": command_id,
		"original_text": str(rec.get("text", "")),
		"action": str(intent.get("action", "ADVANCE")),
		"scope_type": "WING_CLASS", "class": cls, "region": "",
		"unit_id": "", "missing": ["region"],
		"question": "어느 %s를 말씀하십니까? %s 중 지정해 주십시오." % [ViewModelScript.class_kr(cls), ResolverScript.wings_kr(wings)],
		"wings": wings.duplicate(),
	})
	_trace.append("CLASS_WIDE ambiguous wings=[%s]" % ", ".join(wings))
	_ask_pending(command_id)


## Multi-region HOLD ("양쪽 대기"): one staged plan, per-unit canonical
## HOLDs executed sequentially after approval. No destinations involved.
func _stage_multi_hold(command_id: String, rec: Dictionary, intent: Dictionary,
		rtype: String) -> void:
	var scope: Dictionary = intent.get("scope", {})
	var cls := str(scope.get("class", "CAVALRY"))
	if cls.is_empty():
		cls = "CAVALRY"
	var ures := ResolverScript.resolve_union(
		(scope.get("regions", []) as Array).duplicate(), cls, {
		"unit_manager": _unit_manager, "selected_unit": _selected_unit()})
	_debug["scope_resolution"] = ures.duplicate(true)
	if not bool(ures.get("ok", false)):
		_handle_scope_failure(command_id, ures)
		return
	var units: Array = (ures.get("unit_ids", []) as Array).duplicate()
	rec["unit_ids"] = units
	rec["scope_label"] = str(ures.get("scope_label", "")) + truncation_note(ures)
	_active[command_id] = rec
	_stage_hold_items(command_id, rec, intent, rtype)


## Shared holds-staging core: rec unit_ids/scope_label are inputs; ADVICE
## records the recommendation, COMMAND stages per-unit canonical HOLDs.
## Identical for legacy UNION and expression scopes.
func _stage_hold_items(command_id: String, rec: Dictionary, intent: Dictionary,
		rtype: String) -> void:
	var units: Array = (rec.get("unit_ids", []) as Array).duplicate()
	_stage_hold_list(command_id, rec, intent, rtype, units)


## HOLD items builder (pure over live positions): [{unit_id, from}].
## Shared by single holds staging and composite merge.
func _hold_items(units: Array) -> Array:
	var items: Array = []
	for uid in units:
		var u := _unit_dict(str(uid))
		items.append({"unit_id": str(uid),
			"from": [int(u.get("q", 0)), int(u.get("r", 0))]})
	return items


func _stage_hold_list(command_id: String, rec: Dictionary, intent: Dictionary,
		rtype: String, units: Array) -> void:
	_trace.append("HOLDS %s -> [%s]" % [str(rec.get("scope_label", "")), ", ".join(units)])
	if rtype == "ADVICE":
		_last_advice = {"unit_ids": units.duplicate(), "profiles": {},
			"hold_units": true, "action": "HOLD",
			"scope_label": str(rec.get("scope_label", "")),
			"state_version": int(_truth.get_version()),
			"fingerprint": str(_truth.fingerprint()),
			"config_identity": BackendCfgScript.config_identity(),
			"text": ""}
		var msg := "%s, %d개 대대가 대기 가능합니다. \"그렇게 해\"라고 하시면 편성안을 올리겠습니다." % [str(rec.get("scope_label", "")), units.size()]
		_push_history(str(rec.get("text", "")), msg)
		_say_and_close(command_id, msg, "advice")
		return
	var items: Array = _hold_items(units)
	_stage(command_id, rec, intent, "holds", items, {})
	var msg2 := "%s, %d개 대대를 대기시키겠습니다." % [str(rec.get("scope_label", "")), units.size()]
	_push_history(str(rec.get("text", "")), msg2)
	_say(command_id, msg2)
	_after_stage_announce(command_id)


# --- Native staging (whole-force ADVANCE, HOLD) ----------------------------------------------

func _native_scope_dict(intent: Dictionary) -> Dictionary:
	var scope: Dictionary = (intent.get("scope", {}) as Dictionary).duplicate()
	var stype := str(scope.get("type", ""))
	var region := str(scope.get("region", ""))
	var cls := str(scope.get("class", "ALL_ARMS"))
	if stype == "ALL_AVAILABLE":
		if cls == "ALL_ARMS" or cls.is_empty():
			return {"type": "ALL_AVAILABLE"}
		return {"type": "CLASS", "class": cls}
	# Class-wide HOLD ("기병 대기", "지휘부 대기"): the whole class as one
	# planner-native CLASS scope. Previously unmapped (UNKNOWN_REGION
	# failure for every class-wide HOLD); the planner resolves CLASS
	# canonically and per-unit validation stays authoritative.
	if region in ["ALL", ""] and stype in ["WING_CLASS", "CLUSTER_CLASS", ""]:
		if cls == "ALL_ARMS" or cls.is_empty():
			return {"type": "ALL_AVAILABLE"}
		return CommandScript.scope_class(cls)
	if stype == "UNIT":
		var uid := str(scope.get("unit_id", ""))
		if not uid.is_empty():
			return {"type": "UNIT_ID", "unit_id": uid}
		var sel := _selected_unit()
		if not sel.is_empty():
			return {"type": "UNIT_ID", "unit_id": str(sel.get("id", ""))}
		return {}
	if region in ["LEFT", "CENTER", "RIGHT"]:
		return {"type": "FORMATION_WING_CLASS", "wing": region, "class": cls}
	if region in ["EXTREME_LEFT", "EXTREME_RIGHT"]:
		var ex := ClustersScript.extreme_left() if region == "EXTREME_LEFT" else ClustersScript.extreme_right()
		if ex.is_empty():
			return {}
		return {"type": "FORMATION_CLUSTER_CLASS", "cluster": ex, "class": cls}
	if IntentScript.is_concrete_band(region):
		return {"type": "FORMATION_CLUSTER_CLASS", "cluster": region, "class": cls}
	return {}


func _stage_native_whole(command_id: String, rec: Dictionary, intent: Dictionary,
		rtype: String) -> void:
	var cmd := CommandScript.make("ADVANCE", {"type": "ALL_AVAILABLE"}, "FORWARD")
	_stage_native(command_id, rec, intent, rtype, cmd, "전군")


func _stage_native_hold(command_id: String, rec: Dictionary, intent: Dictionary,
		rtype: String) -> void:
	var scope: Dictionary = intent.get("scope", {})
	if str(scope.get("type", "")) == "PREVIOUS":
		_resolve_previous(command_id, rec, intent, rtype)
		return
	var res := ResolverScript.resolve_force(scope, {
		"unit_manager": _unit_manager, "selected_unit": _selected_unit()})
	_debug["scope_resolution"] = res.duplicate(true)
	if not bool(res.get("ok", false)):
		_handle_scope_failure(command_id, res)
		return
	var nscope := _native_scope_dict(intent)
	if nscope.is_empty():
		_handle_scope_failure(command_id, {"fail_kind": "UNKNOWN_REGION",
			"fail_detail": str(scope.get("region", "")), "wings": []})
		return
	rec["unit_ids"] = (res.get("unit_ids", []) as Array).duplicate()
	rec["scope_label"] = str(res.get("scope_label", "")) + truncation_note(res)
	_active[command_id] = rec
	var cmd := CommandScript.make("HOLD", nscope)
	_stage_native(command_id, rec, intent, rtype, cmd, str(res.get("scope_label", "")))


func _stage_native(command_id: String, rec: Dictionary, intent: Dictionary,
		rtype: String, cmd: Dictionary, label: String) -> void:
	var vd: Dictionary = _action_service.validate_action(cmd, "blue")
	if not bool(vd.get("ok", false)):
		var errs: Array = vd.get("validation_errors", [])
		var code := str((errs[0] as Dictionary).get("code", "NO_VALID_UNITS")) if not errs.is_empty() else "NO_VALID_UNITS"
		_trace.append("NATIVE validate failed: %s" % code)
		_fail(command_id, "NO_OPTIONS", code, false,
			"현재 %s 명령을 이행할 수 있는 부대가 없습니다." % label)
		return
	var resolved: Array = vd.get("resolved_units", [])
	var units: Array = []
	for a in resolved:
		if a is Dictionary:
			units.append(str((a as Dictionary).get("unit_id", "")))
	rec["unit_ids"] = units
	rec["scope_label"] = label
	_active[command_id] = rec
	var pv: Dictionary = _action_service.preview_action(cmd, "blue")
	var proutes: Array = []
	var cells: Array = []
	for a in (vd.get("resolved_units", []) as Array):
		if a is Dictionary:
			var f: Variant = (a as Dictionary).get("from", [])
			if f is Array and (f as Array).size() == 2:
				cells.append(Vector2i(int((f as Array)[0]), int((f as Array)[1])))
	for r in (pv.get("routes", []) as Array):
		if r is Dictionary:
			proutes.append({"path_cells": ((r as Dictionary).get("path_cells", []) as Array).duplicate(true)})
	_debug["scope_resolution"] = {"ok": true, "unit_ids": units,
		"scope_label": label, "native": true,
		"preview_routes": proutes.size()}
	rec["preview_routes"] = proutes
	rec["preview_cells"] = cells
	rec["highlight_token"] = ""
	_active[command_id] = rec
	if rtype == "ADVICE":
		_last_advice = {"unit_ids": units.duplicate(),
			"profiles": {}, "native_command": cmd.duplicate(true),
			"action": str(intent.get("action", "ADVANCE")),
			"scope_label": label,
			"state_version": int(_truth.get_version()),
			"fingerprint": str(_truth.fingerprint()),
			"config_identity": BackendCfgScript.config_identity(),
			"text": ""}
		var msg := "%s, %d개 대대가 이행 가능합니다. \"그렇게 해\"라고 하시면 편성안을 올리겠습니다." % [label, units.size()]
		_push_history(str(rec.get("text", "")), msg)
		_say_and_close(command_id, msg, "advice")
		return
	_stage(command_id, rec, intent, "native", [], cmd)
	var msg2 := "%s, %d개 대대를 %s시키겠습니다." % [label, units.size(),
		"전진" if str(intent.get("action", "")) == "ADVANCE" else "대기"]
	_push_history(str(rec.get("text", "")), msg2)
	_say(command_id, msg2)
	_after_stage_announce(command_id)


# --- Cavalry LLM path ------------------------------------------------------------------

## PREVIOUS follow-up ("그렇게 해") shared by the cavalry, native, and
## multi-hold paths. Returns true when the caller should continue to fresh
## packaging (profiles shape); otherwise the follow-up is fully handled here
## (re-staged native/holds, or an honest terminal message).
func _resolve_previous(command_id: String, rec: Dictionary, intent: Dictionary,
		rtype: String) -> bool:
	if _last_advice.is_empty() or ((_last_advice.get("unit_ids", []) as Array).is_empty()):
		_ask(command_id, "직전에 권고한 안이 없습니다. 먼저 물어보시거나 명령을 내려 주십시오.")
		return false
	# A follow-up naming a DIFFERENT action than advised must not
	# silently reuse the old realization (e.g. advised HOLD, ordered
	# ADVANCE): say so honestly instead of executing the wrong thing.
	if str(intent.get("action", "ADVANCE")) != str(_last_advice.get("action", "ADVANCE")):
		_say_and_close(command_id, "직전 권고는 %s에 대한 것이었습니다. 새로 명령해 주십시오." % str(_last_advice.get("action", "?")), "fail:ACTION_MISMATCH")
		return false
	if _last_advice.has("native_command"):
		_stage_native(command_id, rec, intent, rtype,
			(_last_advice.get("native_command", {}) as Dictionary).duplicate(true),
			str(_last_advice.get("scope_label", "직전 권고 부대")))
		return false
	if _last_advice.has("hold_units"):
		var units: Array = (_last_advice.get("unit_ids", []) as Array).duplicate()
		rec["unit_ids"] = units
		rec["scope_label"] = str(_last_advice.get("scope_label", "직전 권고 부대"))
		_active[command_id] = rec
		if rtype == "ADVICE":
			_say_and_close(command_id, "이미 대기 권고를 드렸습니다. \"그렇게 해\"는 명령으로 말씀해 주십시오.", "advice")
			return false
		var items: Array = []
		for uid in units:
			var u := _unit_dict(str(uid))
			items.append({"unit_id": str(uid),
				"from": [int(u.get("q", 0)), int(u.get("r", 0))]})
		_stage(command_id, rec, intent, "holds", items, {})
		var msg := "%s, %d개 대대를 대기시키겠습니다." % [str(rec.get("scope_label", "")), units.size()]
		_push_history(str(rec.get("text", "")), msg)
		_say(command_id, msg)
		_after_stage_announce(command_id)
		return false
	rec["unit_ids"] = (_last_advice.get("unit_ids", []) as Array).duplicate()
	rec["scope_label"] = "직전 권고 부대"
	rec["prior_profiles"] = (_last_advice.get("profiles", {}) as Dictionary).duplicate(true)
	_active[command_id] = rec
	return true


func _resolve_and_package(command_id: String, rec: Dictionary, intent: Dictionary,
		rtype: String) -> void:
	var scope: Dictionary = intent.get("scope", {})
	if str(scope.get("type", "")) == "PREVIOUS":
		if not _resolve_previous(command_id, rec, intent, rtype):
			return
		_package_and_select(command_id, rec, intent, rtype)
		return
	var r := _resolve_legacy_units(command_id, rec, intent)
	if bool(r.get("terminal", false)):
		return
	rec["unit_ids"] = (r.get("units", []) as Array).duplicate()
	rec["scope_label"] = str(r.get("label", ""))
	_active[command_id] = rec
	_package_and_select(command_id, rec, intent, rtype)


## Legacy single-scope resolution to a unit set (UNION / named UNIT /
## regimented scopes). Shared by the single path and composite orders.
## Terminal failures (limitation / scope-failure message) are said inside
## and reported via {terminal: true}. Otherwise {terminal: false, units,
## label}. Never stages, never packages.
func _resolve_legacy_units(command_id: String, rec: Dictionary, intent: Dictionary) -> Dictionary:
	var scope: Dictionary = intent.get("scope", {})
	if str(scope.get("type", "")) == "PREVIOUS":
		_say_and_close(command_id, "직전 권고는 단일 명령에서 사용해 주십시오. 새로 명령해 주십시오.", "fail:PREVIOUS_IN_COMPOSITE")
		return {"terminal": true}
	if str(scope.get("type", "")) == "UNION":
		var eff := scope_classes(intent)
		if (eff["combat"] as Array).is_empty():
			_limitation(command_id, intent, _policy_text_for(eff["policy"] as Array))
			return {"terminal": true}
		var ures := _resolve_union_classes(
			(scope.get("regions", []) as Array).duplicate(),
			eff["combat"] as Array)
		_debug["scope_resolution"] = ures.duplicate(true)
		if not bool(ures.get("ok", false)):
			_handle_scope_failure(command_id, ures)
			return {"terminal": true}
		rec["unit_ids"] = (ures.get("unit_ids", []) as Array).duplicate()
		rec["scope_label"] = str(ures.get("scope_label", "")) + truncation_note(ures)
		if not ((ures.get("empty_regions", []) as Array).is_empty()):
			rec["scope_label"] += " (해당 없음: %s)" % ", ".join(ures.get("empty_regions", []))
		if not ((eff["policy"] as Array).is_empty()):
			rec["scope_label"] += " (%s 제외)" % _class_names_kr(eff["policy"] as Array)
		_active[command_id] = rec
		return {"terminal": false,
			"units": (ures.get("unit_ids", []) as Array).duplicate(),
			"label": str(rec.get("scope_label", ""))}
	elif str(scope.get("type", "")) == "UNIT" and not str(scope.get("unit_id", "")).strip_edges().is_empty():
		var named := _resolve_named_unit(command_id, rec, intent)
		if named.is_empty():
			return {"terminal": true}
		rec["unit_ids"] = [str(named.get("id", ""))]
		rec["scope_label"] = str(named.get("label", ""))
		_active[command_id] = rec
		return {"terminal": false, "units": [str(named.get("id", ""))],
			"label": str(named.get("label", ""))}
	else:
		var res := ResolverScript.resolve(scope, {
			"unit_manager": _unit_manager, "selected_unit": _selected_unit()})
		_debug["scope_resolution"] = res.duplicate(true)
		if not bool(res.get("ok", false)):
			_handle_scope_failure(command_id, res)
			return {"terminal": true}
		rec["unit_ids"] = (res.get("unit_ids", []) as Array).duplicate()
		rec["scope_label"] = str(res.get("scope_label", "")) + truncation_note(res)
		_active[command_id] = rec
		return {"terminal": false,
			"units": (res.get("unit_ids", []) as Array).duplicate(),
			"label": str(rec.get("scope_label", ""))}


## Shared doctrine-packaging core: evaluator packages for rec unit_ids,
## doctrine scoring evidence, representative context, Phase-2 selection.
## rec["unit_ids"] / rec["scope_label"] are inputs; packages, selection,
## staging flow from here identically for legacy and expression scopes.
func _package_and_select(command_id: String, rec: Dictionary, intent: Dictionary,
		rtype: String) -> void:
	_trace.append("RESOLVED %s -> [%s]" % [str(rec.get("scope_label", "")),
		", ".join(rec.get("unit_ids", []))])
	var ev := _eval_packages(command_id, rec, intent)
	if bool(ev.get("terminal", false)):
		return
	_begin_selection(command_id, rec, intent, rtype)


## Evaluator pass over rec["unit_ids"]: packages + explicit unevaluable
## accounting + availability filter. Says the terminal message itself on
## total failure and reports {terminal: true}. Otherwise updates rec
## (unit_ids, scope_label exclusion note, packages, debug) and reports
## {terminal: false, pkgs, unevaluable}.
func _eval_packages(command_id: String, rec: Dictionary, intent: Dictionary) -> Dictionary:
	# Movement intent for the doctrine path: ADVANCE and RECON both score
	# forward observation/pressure movement through class doctrines (the
	# moves pipeline below is action-agnostic; legality stays Godot-side).
	var move_action := str(intent.get("action", "ADVANCE"))
	if move_action != "RECON":
		move_action = "ADVANCE"
	var move_intent := {"action": move_action, "direction": "FORWARD"}
	var bf := _battlefield()
	var pkgs := {}
	var unevaluable: Array = []
	for uid in (rec.get("unit_ids", []) as Array):
		var pkg: Dictionary = _evaluator.evaluate(str(uid), move_intent,
			_command_service, bf["bk"], bf["cell_data"], bf["occ"],
			int(_truth.get_version()), str(_truth.fingerprint()))
		if not bool(pkg.get("ok", false)):
			var ud := ResolverScript.find_unit(str(uid), _unit_manager)
			unevaluable.append({"unit_id": str(uid),
				"class": str(ud.get("class", "?")).to_upper(),
				"why": str(pkg.get("error", "EVALUATE_FAILED"))})
			continue
		if (pkg.get("options", []) as Array).is_empty():
			# No candidates at all: account explicitly (never silently
			# dropped from the semantic set).
			var ud2 := ResolverScript.find_unit(str(uid), _unit_manager)
			unevaluable.append({"unit_id": str(uid),
				"class": str(ud2.get("class", "?")).to_upper(),
				"why": "NO_OPTIONS"})
			continue
		pkgs[str(uid)] = pkg
	if pkgs.is_empty():
		_no_package_message(command_id, rec, unevaluable)
		return {"terminal": true}
	# Units with zero AVAILABLE/DEGRADED options never enter selection:
	# repair could not fix them (no legal pick exists), and one such
	# unit must not poison its chunk. Accounted explicitly below.
	var avail_units: Array = []
	var noopt: Array = []
	for uid in pkgs.keys():
		if _available_ids(pkgs[uid]).size() > 0:
			avail_units.append(str(uid))
		else:
			noopt.append(str(uid))
	for uid in noopt:
		var udx := ResolverScript.find_unit(str(uid), _unit_manager)
		unevaluable.append({"unit_id": str(uid),
			"class": str(udx.get("class", "?")).to_upper(),
			"why": "NO_AVAILABLE_OPTION"})
		pkgs.erase(uid)
	if pkgs.is_empty():
		_no_package_message(command_id, rec, unevaluable)
		return {"terminal": true}
	# Evaluable units only from here: every scoped formation is still
	# accounted for (staged, or named in the exclusion note below).
	rec["unit_ids"] = pkgs.keys()
	if not unevaluable.is_empty():
		var ex_classes: Array = []
		for u in unevaluable:
			var c := str((u as Dictionary).get("class", "?"))
			if not c in ex_classes:
				ex_classes.append(c)
		rec["scope_label"] = str(rec.get("scope_label", "")) + " (%s 제외)" % _class_names_kr(ex_classes)
		_trace.append("UNEVALUABLE %s" % JSON.stringify(unevaluable))
	rec["packages"] = pkgs
	_active[command_id] = rec
	_debug["unevaluable"] = unevaluable.duplicate(true)
	_debug["package_units"] = pkgs.keys()
	if avail_units.is_empty():
		_fail(command_id, "NO_OPTIONS", "all UNAVAILABLE", false,
			"현재 %s의 실행 가능한 전술안이 없습니다. 상황이 바뀌면 다시 말씀해 주십시오." % str(rec.get("scope_label", "해당 부대")))
		return {"terminal": true}
	return {"terminal": false, "pkgs": pkgs, "unevaluable": unevaluable}


## Representative BLUE context + Phase-2 selection round over
## rec["packages"]. Shared by single and composite orders.
func _begin_selection(command_id: String, rec: Dictionary, intent: Dictionary,
		rtype: String) -> void:
	var move_action := str(intent.get("action", "ADVANCE"))
	if move_action != "RECON":
		move_action = "ADVANCE"
	var move_intent := {"action": move_action, "direction": "FORWARD"}
	var bf := _battlefield()
	var pkgs: Dictionary = rec.get("packages", {})
	var rep := _representative_unit(pkgs)
	var rep_pkg: Dictionary = pkgs[rep]
	var rep_unit := _unit_dict(str(rep))
	var built: Dictionary = ContextScript.build({
		"package": rep_pkg, "unit": rep_unit, "blue_knowledge": bf["bk"],
		"cell_data": bf["cell_data"], "intent": move_intent,
		"state_version": int(_truth.get_version()),
		"fingerprint": str(_truth.fingerprint()),
		"cluster_signature": ClustersScript.frozen_signature(),
		"request_id": command_id,
	})
	if not bool(built.get("ok", false)):
		_fail(command_id, "MALFORMED", str(built.get("error", "?")), false,
			"자문을 준비하지 못했습니다.")
		return
	var ctx: Dictionary = built.get("context", {})
	var audit_hit := ContextScript.audit_enemy_section(ctx)
	if not audit_hit.is_empty():
		push_error("[ChatCmd] BLUE-KNOWLEDGE AUDIT FAILED: %s" % audit_hit)
		_fail(command_id, "MALFORMED", audit_hit, false, "자문을 준비하지 못했습니다.")
		return
	rec["rep_context"] = ctx
	rec["supplied_ids"] = ContextScript.supplied_contact_ids(ctx)
	_active[command_id] = rec
	_send_selection(command_id, rec, intent, rtype)


func _handle_scope_failure(command_id: String, res: Dictionary) -> void:
	var kind := str(res.get("fail_kind", "UNKNOWN"))
	var rec: Dictionary = _active.get(command_id, {})
	var intent: Dictionary = rec.get("intent", {})
	var icls := str((intent.get("scope", {}) as Dictionary).get("class", "CAVALRY"))
	if icls.is_empty():
		icls = "CAVALRY"
	var kr := ViewModelScript.class_kr(icls)
	match kind:
		"AMBIGUOUS":
			_set_pending_raw({
				"command_id": command_id,
				"original_text": str(rec.get("text", "")),
				"action": str(intent.get("action", "ADVANCE")),
				"scope_type": "WING_CLASS", "class": icls, "region": "",
				"unit_id": "", "missing": ["region"],
				"question": "어느 %s를 말씀하십니까? %s 중 지정해 주십시오." % [kr, ResolverScript.wings_kr(res.get("wings", []))],
				"wings": (res.get("wings", []) as Array).duplicate(),
			})
			_trace.append("PENDING missing=[region]")
			_ask_pending(command_id)
		"EMPTY_SCOPE":
			_say_and_close(command_id, "현재 %s에서 지휘 가능한 부대가 없습니다." % str(res.get("fail_detail", "해당 구역")), "fail:EMPTY_SCOPE")
		"UNSUPPORTED_CLASS":
			_say_and_close(command_id, "이 병종(%s)은 채팅 전술 편성 대상이 아닙니다." % str(res.get("fail_detail", "?")), "fail:UNSUPPORTED_CLASS")
		"NO_SELECTION", "NOT_CAVALRY_SELECTION", "NOT_CLASS_SELECTION":
			_set_pending_raw({
				"command_id": command_id,
				"original_text": str(rec.get("text", "")),
				"action": str(intent.get("action", "ADVANCE")),
				"scope_type": "WING_CLASS", "class": icls,
				"region": "", "unit_id": "", "missing": ["region"],
				"question": "선택된 %s이 없습니다. 지도에서 부대를 고르시거나 구역(좌익·중앙·우익·극좌익·극우익)을 말씀해 주십시오." % kr,
				"wings": [],
			})
			_trace.append("PENDING missing=[region]")
			_ask_pending(command_id)
		_:
			_say_and_close(command_id, "명령의 대상을 확정하지 못했습니다. 다시 말씀해 주십시오.", "fail:" + kind)


## Explicitly named unit (UNIT + unit_id): the pointer IS the scope. Returns
## {id, label} or {} after an honest terminal message. Doctrine-gated: named
## HQ/SUPPLY gets policy text, never combat scoring.
func _resolve_named_unit(command_id: String, rec: Dictionary, intent: Dictionary) -> Dictionary:
	var scope: Dictionary = intent.get("scope", {})
	var uid := str(scope.get("unit_id", "")).strip_edges().to_upper()
	var found := ResolverScript.find_unit(uid, _unit_manager)
	if found.is_empty() or str(found.get("faction", "")) != "blue":
		_say_and_close(command_id, "지명한 부대(%s)를 찾을 수 없습니다." % uid, "fail:NO_SELECTION")
		return {}
	var cls := str(found.get("class", "")).to_upper()
	if DoctrinesScript.needs_policy(cls):
		_limitation(command_id, intent, DoctrinesScript.policy_text(cls))
		return {}
	if not DoctrinesScript.is_doctrine_class(cls):
		_say_and_close(command_id, "이 병종(%s)은 채팅 전술 편성 대상이 아닙니다." % ViewModelScript.class_kr(cls), "fail:UNSUPPORTED_CLASS")
		return {}
	var cid := ClustersScript.cluster_of_unit(found)
	rec["unit_ids"] = [str(found.get("id", ""))]
	rec["scope_label"] = "지명 %s %s (%s)" % [ViewModelScript.class_kr(cls), str(found.get("id", "")), cid if not cid.is_empty() else "구역 확인 중"]
	_active[command_id] = rec
	_trace.append("NAMED %s class=%s" % [str(found.get("id", "")), cls])
	return {"id": str(found.get("id", "")), "label": str(rec.get("scope_label", ""))}


static func _available_ids(pkg: Dictionary) -> Array:
	var out: Array = []
	for o_val in (pkg.get("options", []) as Array):
		if not o_val is Dictionary:
			continue
		if str((o_val as Dictionary).get("status", "")).to_upper() in ["AVAILABLE", "DEGRADED"]:
			out.append(str((o_val as Dictionary).get("profile", "?")).to_upper())
	return out


## Effective doctrine classes for an intent scope: classes[] when the model
## composed several, else the single class. Non-doctrine entries (HQ/SUPPLY)
## are reported separately so they are never silently treated as combatants.
static func scope_classes(intent: Dictionary) -> Dictionary:
	var scope: Dictionary = intent.get("scope", {})
	var out: Array = []
	for c_val in (scope.get("classes", []) as Array):
		var c := str(c_val).strip_edges().to_upper()
		if DoctrinesScript.is_doctrine_class(c) and not c in out:
			out.append(c)
	var single := str(scope.get("class", "")).strip_edges().to_upper()
	if out.is_empty() and DoctrinesScript.is_doctrine_class(single):
		out.append(single)
	var dropped: Array = []
	for c_val in (scope.get("classes", []) as Array):
		var c2 := str(c_val).strip_edges().to_upper()
		if DoctrinesScript.needs_policy(c2) and not c2 in dropped:
			dropped.append(c2)
	if single != "" and DoctrinesScript.needs_policy(single) and not single in dropped:
		dropped.append(single)
	return {"combat": out, "policy": dropped}


## Multi-class union resolution: one resolve_union per combat class, merged
## to a single deterministic unit set with per-class labels preserved.
func _resolve_union_classes(regions: Array, classes: Array) -> Dictionary:
	var merged: Array = []
	var seen := {}
	var labels: Array = []
	var wings := {}
	var empty: Array = []
	var total := 0
	for cls in classes:
		var r := ResolverScript.resolve_union(regions.duplicate(),
			str(cls), {"unit_manager": _unit_manager,
			"selected_unit": _selected_unit()})
		if not bool(r.get("ok", false)):
			continue
		labels.append(str(r.get("scope_label", "")))
		for w in (r.get("wings", []) as Array):
			wings[str(w)] = true
		for e in (r.get("empty_regions", []) as Array):
			if not str(e) in empty:
				empty.append(str(e))
		total += int(r.get("total", ((r.get("unit_ids", []) as Array).size())))
		for uid in (r.get("unit_ids", []) as Array):
			if not seen.has(str(uid)):
				seen[str(uid)] = true
				merged.append(str(uid))
	if merged.is_empty():
		return {"ok": false, "fail_kind": "EMPTY_SCOPE",
			"fail_detail": "union has no live units", "wings": []}
	merged.sort()
	return {"ok": true, "unit_ids": merged, "total": total,
		"scope_label": " + ".join(labels),
		"wings": wings.keys(), "truncated": false, "empty_regions": empty}


static func _class_names_kr(classes: Array) -> String:
	var out: Array = []
	for c in classes:
		out.append(ViewModelScript.class_kr(str(c)))
	return ", ".join(out)


## Honest terminal message when NO unit in scope produced a package:
## policy classes (HQ/SUPPLY) get their explicit doctrine text, anything
## else gets the generic no-doctrine message. Never MALFORMED, never silent.
func _no_package_message(command_id: String, rec: Dictionary, unevaluable: Array) -> void:
	_debug["unevaluable"] = unevaluable.duplicate(true)
	_trace.append("UNEVALUABLE %s" % JSON.stringify(unevaluable))
	var policy: Array = []
	var other: Array = []
	for u in unevaluable:
		var c := str((u as Dictionary).get("class", "?"))
		if DoctrinesScript.needs_policy(c) and not c in policy:
			policy.append(c)
		elif not c in other:
			other.append(c)
	if not policy.is_empty() and other.is_empty():
		_say_and_close(command_id, _policy_text_for(policy), "fail:NO_DOCTRINE")
		return
	if not other.is_empty():
		_say_and_close(command_id, "이 병종(%s)의 전술 평가 모델은 아직 준비되지 않았습니다." % _class_names_kr(other), "fail:NO_DOCTRINE")
		return
	_fail(command_id, "NO_OPTIONS", "no packages", false,
		"현재 상황에서 실행 가능한 전술안이 없습니다.")


static func _policy_text_for(policy_classes: Array) -> String:
	if policy_classes.is_empty():
		return DoctrinesScript.policy_text("")
	var msgs: Array = []
	for c in policy_classes:
		msgs.append(DoctrinesScript.policy_text(str(c)))
	return " ".join(msgs)


func _unit_dict(uid: String) -> Dictionary:
	for u in ResolverScript.blue_force(_unit_manager):
		if str((u as Dictionary).get("id", "")) == uid:
			return u
	var sel := _selected_unit()
	if str(sel.get("id", "")) == uid:
		return sel
	return {"id": uid}


func _representative_unit(pkgs: Dictionary) -> String:
	var best := ""
	var best_q := -(1 << 30)
	for uid in pkgs.keys():
		var u := _unit_dict(str(uid))
		var q := int(u.get("q", 0))
		if best.is_empty() or q > best_q or (q == best_q and str(uid) < best):
			best = str(uid)
			best_q = q
	return best


# --- Phase 2: selection --------------------------------------------------------------------

func _slim_packages(rec: Dictionary, only_ids: Array = []) -> Array:
	var out: Array = []
	var keys: Array = (rec.get("packages", {}) as Dictionary).keys()
	keys.sort()
	var want := {}
	for w in only_ids:
		want[str(w)] = true
	for uid in keys:
		if not want.is_empty() and not want.has(str(uid)):
			continue
		var pkg: Dictionary = (rec.get("packages", {}) as Dictionary)[uid]
		var opts: Array = []
		for o_val in (pkg.get("options", []) as Array):
			if not o_val is Dictionary:
				continue
			var o: Dictionary = o_val
			var row := {"profile": str(o.get("profile", "?")).to_upper(),
				"slot": int(o.get("slot", 0)),
				"status": str(o.get("status", "UNAVAILABLE")).to_upper()}
			if o.has("destination"):
				var d: Dictionary = o["destination"]
				row["destination"] = {"q": int(d.get("q", 0)), "r": int(d.get("r", 0))}
			var rk: Dictionary = o.get("risk", {})
			# Class-aware evidence for the model: qualitative risk scalars
			# per option (support/pressure/mobility/information/screen/
			# denial/intent) plus the doctrine's own top strengths/concerns
			# (feature names, never magnitudes). Raw utility scores and
			# feature-contribution magnitudes stay Godot-side by design:
			# the model judges INTENT fit from evidence (never scores —
			# none are shown), and live models quote numbers and profile
			# ids into player text otherwise (proven quality leak). DEV
			# diagnostics keep the full package via debug_snapshot().
			row["risk"] = {"overall": snappedf(float(rk.get("overall", 0.0)), 0.01),
				"support": snappedf(float(rk.get("support", 0.0)), 0.01),
				"pressure": snappedf(float(rk.get("pressure", 0.0)), 0.01),
				"mobility": snappedf(float(rk.get("mobility", 0.0)), 0.01),
				"intent_progress": snappedf(float(rk.get("intent_progress", 0.0)), 0.01),
				"information": snappedf(float(rk.get("information", 0.0)), 0.01),
				"screen": snappedf(float(rk.get("screen", 0.0)), 0.01),
				"denial": snappedf(float(rk.get("denial", 0.0)), 0.01)}
			row["strengths"] = _driver_names(o.get("top_positive", []), 3)
			row["concerns"] = _driver_names(o.get("top_negative", []), 3)
			if str(o.get("status", "")).to_upper() == "DEGRADED":
				row["limitation"] = str(o.get("reason", ""))
			opts.append(row)
		var u := _unit_dict(str(uid))
		var pkg0: Dictionary = (rec.get("packages", {}) as Dictionary).get(uid, {})
		out.append({"unit_id": str(uid),
			"unit_class": str(pkg0.get("unit_class", "")),
			"doctrine": str(pkg0.get("doctrine", "")),
			"cluster": ClustersScript.cluster_of_unit(u),
			"position": [int(u.get("q", 0)), int(u.get("r", 0))],
			"options": opts})
	return out


## Feature-name drivers for Phase-2 evidence ("INTENT_PROGRESS +1.20" ->
## "INTENT_PROGRESS", top N, order kept). Magnitudes never cross to the
## model: names carry the tactical semantics, numbers only fed spirals.
static func _driver_names(drivers: Variant, keep: int) -> Array:
	var out: Array = []
	if not drivers is Array:
		return out
	for d_val in (drivers as Array):
		var tok := str(d_val).strip_edges().split(" ")[0].to_upper()
		if tok.is_empty() or tok in out:
			continue
		out.append(tok)
		if out.size() >= keep:
			break
	return out


func _send_selection(command_id: String, rec: Dictionary, intent: Dictionary,
		rtype: String) -> void:
	# Chunked selection: the FULL semantic set stages; the model chooses
	# per chunk (SELECT_CHUNK units per call) and Godot merges.
	var chunks: Array = rec.get("select_chunks", [])
	if chunks.is_empty():
		var all_ids: Array = (rec.get("packages", {}) as Dictionary).keys()
		all_ids.sort()
		var cur: Array = []
		for uid in all_ids:
			cur.append(str(uid))
			if cur.size() >= SELECT_CHUNK:
				chunks.append(cur)
				cur = []
		if not cur.is_empty():
			chunks.append(cur)
		rec["select_chunks"] = chunks
		rec["select_index"] = 0
		rec["select_results"] = {}
		rec["select_reasons"] = []
		rec["select_conf"] = 1.0
		_active[command_id] = rec
	var idx := mini(int(rec.get("select_index", 0)), chunks.size() - 1)
	var chunk: Array = (chunks[idx] as Array).duplicate()
	var ctx: Dictionary = rec.get("rep_context", {})
	var enemies: Dictionary = ctx.get("authorized_enemy_knowledge", {})
	var user_block := {
		"command_id": command_id,
		"mode": "STAGE_FOR_APPROVAL" if rtype == "COMMAND" else "RECOMMEND_ONLY",
		"player_message": str(rec.get("text", "")),
		"semantic_intent": intent,
		"resolved_scope": {"label": str(rec.get("scope_label", "")),
			"unit_ids": chunk},
		"packages": _slim_packages(rec, chunk),
		"enemy_summary": {"current_visible": (enemies.get("current_visible", []) as Array).size(),
			"stale_last_known": (enemies.get("stale_last_known", []) as Array).size(),
			"contacts": enemies.get("current_visible", [])},
		"prior_note": "Prior recommendation for these units (follow-up context, re-evaluate fresh): %s" % JSON.stringify(rec.get("prior_profiles", {})) if rec.has("prior_profiles") else "",
		"recent_history": _history_block(),
	}
	if chunks.size() > 1:
		user_block["batch"] = {"index": idx + 1, "total": chunks.size(),
			"note": "One tactical group of a larger order; choose for THESE units only."}
	if rtype == "COMMAND":
		user_block["order"] = "Select one legal realization PER unit for STAGING. Nothing moves on your answer; the commander approves on the map. JSON only."
	else:
		user_block["order"] = "Recommend one legal realization PER unit. NOTHING will move or stage. JSON only."
	_send_phase(command_id, "select", IntentScript.SELECT_SYSTEM_PROMPT,
		"TACTICAL_SELECTION_JSON:\n" + JSON.stringify(user_block))


## Selection validation over an EXPLICIT package subset (one chunk).
## Pure function: every supplied unit exactly once, each pick a legal
## AVAILABLE/DEGRADED option of THAT unit. Returns {ok, selections,
## confidence, reason} or {ok:false, why}.
static func _validate_selections(pkgs: Dictionary, parsed: Dictionary) -> Dictionary:
	if not parsed.has("selections"):
		return {"ok": false, "why": "missing key 'selections'"}
	var sels: Variant = parsed.get("selections", [])
	if not sels is Array or (sels as Array).is_empty():
		return {"ok": false, "why": "selections must be a non-empty array"}
	var seen := {}
	for s_val in (sels as Array):
		if not s_val is Dictionary:
			return {"ok": false, "why": "selection entries must be objects"}
		var s: Dictionary = s_val
		var uid := str(s.get("unit_id", "")).strip_edges()
		var pick := str(s.get("selected_option_id", "")).strip_edges().to_upper()
		if not pkgs.has(uid):
			return {"ok": false, "why": "unit '%s' was not supplied" % uid}
		if seen.has(uid):
			return {"ok": false, "why": "duplicate selection for '%s'" % uid}
		seen[uid] = true
		if not pick in _available_ids(pkgs[uid]):
			return {"ok": false, "why": "'%s' is not an available option for %s" % [pick, uid]}
	for uid in pkgs.keys():
		if not seen.has(str(uid)):
			return {"ok": false, "why": "no selection for supplied unit %s" % str(uid)}
	var conf := float(parsed.get("confidence", -1.0))
	if conf < 0.0 or conf > 1.0:
		return {"ok": false, "why": "confidence outside 0.0-1.0"}
	var reason := str(parsed.get("reason", ""))
	if reason.strip_edges().is_empty():
		return {"ok": false, "why": "reason is empty"}
	if reason.length() > 1200:
		return {"ok": false, "why": "reason exceeds 1200 chars"}
	return {"ok": true, "selections": sels, "confidence": conf, "reason": reason}


func _handle_select_response(command_id: String, rec: Dictionary, raw: String) -> void:
	var parsed := IntentScript.extract_json(raw)
	if parsed.is_empty():
		_repair_select(command_id, rec, "response contained no parseable JSON object")
		return
	_debug["parsed_selection"] = (parsed as Dictionary).duplicate(true)
	var checked := _validate_selections(_chunk_packages(rec), parsed)
	if not bool(checked.get("ok", false)):
		_repair_select(command_id, rec, str(checked.get("why", "invalid selection")))
		return
	_finalize_selection(command_id, rec, checked)


## The current chunk's package subset for validation/repair hints.
func _chunk_packages(rec: Dictionary) -> Dictionary:
	var pkgs: Dictionary = rec.get("packages", {})
	var chunks: Array = rec.get("select_chunks", [])
	if chunks.is_empty():
		return pkgs
	var idx := mini(int(rec.get("select_index", 0)), chunks.size() - 1)
	var out := {}
	for uid in (chunks[idx] as Array):
		if pkgs.has(str(uid)):
			out[str(uid)] = pkgs[str(uid)]
	return out


func _repair_select(command_id: String, rec: Dictionary, why: String) -> void:
	if _state_drifted(rec) or _config_drifted(rec):
		_debug["stale_discarded"] = true
		_debug["outcome"] = "stale"
		_active.erase(command_id)
		chat_busy.emit(false)
		print("[ChatCmd] STALE_CHAT_RESPONSE_DISCARDED command=%s (repair suppressed)" % command_id)
		return
	var units: Array = (_chunk_packages(rec) as Dictionary).keys()
	_repair_or_fail(command_id, "select", why,
		IntentScript.SELECT_SYSTEM_PROMPT, ", ".join(units))


func _finalize_selection(command_id: String, rec: Dictionary, checked: Dictionary) -> void:
	if _config_drifted(rec):
		_debug["stale_discarded"] = true
		_debug["outcome"] = "stale"
		_active.erase(command_id)
		chat_busy.emit(false)
		print("[ChatCmd] STALE_CHAT_RESPONSE_DISCARDED command=%s" % command_id)
		return
	# State moved during selection: never stage stale packages. Rebuild from
	# the same text (fresh packages + fresh choice) instead of dropping the
	# command on the floor.
	if _state_drifted(rec):
		_trace.append("SELECTION state-drifted: auto regen")
		chat_append.emit("ADVISOR", "전황이 바뀌어 명령안을 다시 검토합니다...")
		var text := str(rec.get("text", ""))
		var intent: Dictionary = (rec.get("intent", {}) as Dictionary).duplicate(true)
		_active.erase(command_id)
		_regen_pipeline(text, intent)
		return
	var clean: Dictionary = ViewModelScript.sanitize_advisor_text(
		str(checked.get("reason", "")), rec.get("supplied_ids", []))
	var chunk_reason := str(clean.get("text", ""))
	_debug["redactions"] = int(_debug.get("redactions", 0)) + ((clean.get("redactions", []) as Array).size())
	# Chunk accumulation: merge this chunk's picks into the running
	# selection; more chunks -> next call; last chunk -> stage all.
	var acc: Dictionary = rec.get("select_results", {})
	for s_val in (checked.get("selections", []) as Array):
		var s0: Dictionary = s_val
		acc[str(s0.get("unit_id", ""))] = str(s0.get("selected_option_id", "")).to_upper()
	rec["select_results"] = acc
	var reasons: Array = rec.get("select_reasons", [])
	reasons.append(chunk_reason)
	rec["select_reasons"] = reasons
	rec["select_conf"] = minf(float(rec.get("select_conf", 1.0)), float(checked.get("confidence", 1.0)))
	var chunks: Array = rec.get("select_chunks", [])
	var idx := int(rec.get("select_index", 0))
	_active[command_id] = rec
	if idx + 1 < chunks.size():
		rec["select_index"] = idx + 1
		_active[command_id] = rec
		_trace.append("SELECT chunk %d/%d accumulated" % [idx + 1, chunks.size()])
		_send_selection(command_id, rec, rec.get("intent", {}), str((rec.get("intent", {}) as Dictionary).get("request_type", "COMMAND")))
		return
	var profiles := acc
	var reason := " ".join(reasons)
	if reason.length() > 1500:
		reason = reason.left(1500)
	var intent: Dictionary = rec.get("intent", {})
	var rtype := str(intent.get("request_type", "COMMAND"))
	# Composite capture: stash this order-group's picks; staging happens
	# once, merged, after the last order.
	if _composite_active(rec):
		_composite_capture_selection(command_id, rec, profiles, reason)
		return
	var items: Array = _selections_to_items(profiles, rec.get("packages", {}))
	var pkgs: Dictionary = rec.get("packages", {})
	if rtype == "ADVICE":
		_last_advice = {"unit_ids": profiles.keys(),
			"profiles": profiles.duplicate(true),
			"action": str(intent.get("action", "ADVANCE")),
			"scope_label": str(rec.get("scope_label", "")),
			"state_version": int(_truth.get_version()),
			"fingerprint": str(_truth.fingerprint()),
			"config_identity": BackendCfgScript.config_identity(),
			"text": reason}
		_push_history(str(rec.get("text", "")), reason)
		_say_and_close(command_id, "%s\n(권고만 — 실행하지 않았습니다. \"그렇게 해\"라고 하시면 편성안을 올리겠습니다.)" % reason, "advice")
		return
	# Stage-time coherence (Failure A, COMMAND only): duplicate destinations
	# across the group plan are resolved deterministically BEFORE staging,
	# so the map preview matches what execution can actually do.
	var dc := deconflict_destinations(items, pkgs)
	items = (dc["items"] as Array).duplicate(true)
	# Staged membership = kept units only; dropped units stay accounted for
	# in deconflict/diag records and the player note, never in the plan.
	var kept: Array = []
	for it in items:
		kept.append(str((it as Dictionary).get("unit_id", "")))
	rec["unit_ids"] = kept
	rec["deconflict"] = {"adapted": dc["adapted"], "dropped": dc["dropped"],
		"contended": int(dc["contended"])}
	_debug["deconflict"] = {"adapted": (dc["adapted"] as Array).size(),
		"dropped": (dc["dropped"] as Array).size(),
		"contended": int(dc["contended"])}
	_debug["deconflict_detail"] = {"adapted": dc["adapted"], "dropped": dc["dropped"]}
	_trace.append("DECONFLICT contended=%d adapted=%d dropped=%d" % [
		int(dc["contended"]), (dc["adapted"] as Array).size(),
		(dc["dropped"] as Array).size()])
	if not (dc["adapted"] as Array).is_empty():
		reason += "\n%s은 목표 헥스가 겹쳐 동등한 인접 실현으로 조정했습니다." % _unit_disp_list(dc["adapted"] as Array)
	if not (dc["dropped"] as Array).is_empty():
		if items.is_empty():
			_fail(command_id, "NO_OPTIONS", "all contended", false,
				"겹치지 않는 목표를 찾지 못해 이번 명령을 편성하지 못했습니다.")
			return
		reason += "\n%s은 겹치지 않는 실현이 없어 이번 편성에서 제외했습니다." % _unit_disp_list(dc["dropped"] as Array)
	# Execution-time fallback options per unit (Failure B fix): sequential
	# execution mutates occupancy, so a staged destination can turn illegal
	# before its turn (proven: congestion repricing). Each staged item
	# them against the CURRENT world and adapts honestly instead of
	# failing silently. Coordinates stay Godot-owned throughout.
	for it in items:
		var iuid := str((it as Dictionary).get("unit_id", ""))
		(it as Dictionary)["fallbacks"] = _fallback_options(
			pkgs.get(iuid, {}), it as Dictionary)
	rec["selection"] = {"profiles": profiles, "reason": reason,
		"confidence": float(checked.get("confidence", 0.0))}
	_active[command_id] = rec
	_debug["selection"] = {"profiles": profiles,
		"confidence": float(rec.get("select_conf", 0.0)),
		"chunks": (rec.get("select_chunks", []) as Array).size()}
	_trace.append("SELECTED %s" % JSON.stringify(profiles))
	# DEV doctrine inspector: per-formation class/action/scope/candidates/
	# statuses/choice/destination/risk/drivers/provenance/deconfliction.
	# Player text never carries these; debug_snapshot() does.
	var diag := {}
	var dcinfo: Dictionary = rec.get("deconflict", {})
	var adapted_by := {}
	for a in (dcinfo.get("adapted", []) as Array):
		adapted_by[str((a as Dictionary).get("unit_id", ""))] = a
	for uid in pkgs.keys():
		var pkg: Dictionary = pkgs[uid]
		var chosen := _option_of(pkg, str(profiles.get(str(uid), "")))
		var co: Dictionary = chosen.get("destination", {})
		var statuses := {}
		for o_val in (pkg.get("options", []) as Array):
			statuses[str((o_val as Dictionary).get("profile", "?"))] = str((o_val as Dictionary).get("status", "?"))
		diag[str(uid)] = {"class": str(pkg.get("unit_class", "?")),
			"doctrine": str(pkg.get("doctrine", "?")),
			"action": str(intent.get("action", "?")),
			"scope": str(rec.get("scope_label", "?")),
			"candidates": int(pkg.get("candidate_count", 0)),
			"statuses": statuses,
			"chosen": str(profiles.get(str(uid), "?")),
			"destination": {"q": int(co.get("q", 0)), "r": int(co.get("r", 0))},
			"risk": chosen.get("risk", {}),
			"top_strengths": (chosen.get("top_positive", []) as Array).duplicate(),
			"top_concerns": (chosen.get("top_negative", []) as Array).duplicate(true),
			"provenance": chosen.get("provenance", {}),
			"deconflicted": adapted_by.get(str(uid), {}),
			"dropped": str(uid) in ((dcinfo.get("dropped", []) as Array).map(func(d: Dictionary) -> String: return str(d.get("unit_id", ""))))}
	rec["doctrine_diag"] = diag
	_debug["doctrine_diag"] = diag.duplicate(true)
	# COMMAND: stage for approval (SEND never mutates state).
	_stage(command_id, rec, intent, "moves", items, {})
	_push_history(str(rec.get("text", "")), reason)
	_say(command_id, reason)
	_after_stage_announce(command_id)


## Selections-to-items builder (pure over packages): [{unit_id, profile,
## slot, from, destination, path}] in sorted unit order. Shared by single
## staging and composite merge.
func _selections_to_items(profiles: Dictionary, pkgs: Dictionary) -> Array:
	var items: Array = []
	var pkeys: Array = profiles.keys()
	pkeys.sort()
	for uid in pkeys:
		if not pkgs.has(uid):
			continue
		var pick := str(profiles[uid])
		var opt := _option_of(pkgs[uid], pick)
		var d: Dictionary = opt.get("destination", {})
		var ufrom := _unit_dict(uid)
		items.append({"unit_id": uid, "profile": pick,
			"slot": int(opt.get("slot", 0)),
			"from": [int(ufrom.get("q", 0)), int(ufrom.get("r", 0))],
			"destination": {"q": int(d.get("q", 0)), "r": int(d.get("r", 0))},
			"path": ((opt.get("route", {}) as Dictionary).get("path", []) as Array).duplicate(true)})
	return items


## Ordered execution-time fallbacks for one staged item: non-chosen
## AVAILABLE/DEGRADED realizations by utility, distinct destinations,
## capped at 3. Pure function over the package — headless-testable.
static func _fallback_options(pkg: Dictionary, chosen: Dictionary) -> Array:
	var out: Array = []
	if pkg.is_empty() or chosen.is_empty():
		return out
	var cd: Dictionary = chosen.get("destination", {})
	var ckey := "%d,%d" % [int(cd.get("q", -9999)), int(cd.get("r", -9999))]
	var cands: Array = []
	for o_val in (pkg.get("options", []) as Array):
		if not o_val is Dictionary:
			continue
		var o: Dictionary = o_val
		if not str(o.get("status", "")).to_upper() in ["AVAILABLE", "DEGRADED"]:
			continue
		if not o.has("destination"):
			continue
		var od: Dictionary = o["destination"]
		var okey := "%d,%d" % [int(od.get("q", -9999)), int(od.get("r", -9999))]
		if okey == ckey:
			continue
		cands.append({"key": okey, "utility": float(o.get("utility", 0.0)),
			"profile": str(o.get("profile", "?")).to_upper(),
			"destination": {"q": int(od.get("q", 0)), "r": int(od.get("r", 0))}})
	cands.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if absf(float(a["utility"]) - float(b["utility"])) > 1e-9:
			return float(a["utility"]) > float(b["utility"])
		return str(a["profile"]) < str(b["profile"]))
	var seen := {}
	seen[ckey] = true
	for c in cands:
		if seen.has(str(c["key"])):
			continue
		seen[str(c["key"])] = true
		out.append({"profile": str(c["profile"]),
			"destination": (c["destination"] as Dictionary).duplicate()})
		if out.size() >= 3:
			break
	return out


## Map-correlatable unit list for player-facing notes ("창병대 B_SPE_1,
## 보병대 B_INF_7 외 2기"). BLUE-own ids only; max 3 names then 외 N기.
func _unit_disp_list(rows: Array) -> String:
	var names: Array = []
	var shown := 0
	for r in rows:
		if shown >= 3:
			break
		var uid := str((r as Dictionary).get("unit_id", "")) if r is Dictionary else str(r)
		if uid.is_empty():
			continue
		var cls := ""
		var u := ResolverScript.find_unit(uid, _unit_manager)
		if not (u as Dictionary).is_empty():
			cls = str((u as Dictionary).get("class", "")).to_upper()
		names.append("%s %s" % [ViewModelScript.class_kr(cls), uid] if not cls.is_empty() else uid)
		shown += 1
	var out := ", ".join(names)
	if rows.size() > shown:
		out += " 외 %d기" % (rows.size() - shown)
	return out


func _option_of(pkg: Dictionary, profile: String) -> Dictionary:
	for o_val in (pkg.get("options", []) as Array):
		if o_val is Dictionary and str((o_val as Dictionary).get("profile", "")).to_upper() == profile:
			return o_val
	return {}


## Deterministic destination deconfliction (Failure A fix).
##
## Per-unit packages may independently prefer the same valuable hex. The
## FINAL staged plan must never pretend several formations can occupy one
## hex: claims resolve in sorted unit-id order; losers take their best free
## legal realization (any profile, utility order); units with no free
## realization are dropped with an explicit reason. Pure function over
## staged items + packages — headless-testable, no game reads.
##
## items: [{unit_id, profile, slot, from, destination{q,r}, path}].
## pkgs: {unit_id: package with options[{profile, slot, status,
##         destination{q,r}, route{path}, utility}]}.
## Returns {items, adapted:[{unit_id, from_profile, to_profile,
##   destination}], dropped:[{unit_id, reason}], contended}.
static func deconflict_destinations(items: Array, pkgs: Dictionary) -> Dictionary:
	var by_id := {}
	for it in items:
		if it is Dictionary and not str((it as Dictionary).get("unit_id", "")).is_empty():
			by_id[str((it as Dictionary).get("unit_id", ""))] = it
	var order: Array = by_id.keys()
	order.sort()
	var claimed := {}
	var final_by_id := {}
	var adapted: Array = []
	var dropped: Array = []
	var contended := 0
	for uid in order:
		var it: Dictionary = by_id[uid]
		var d: Dictionary = it.get("destination", {})
		var key := "%d,%d" % [int(d.get("q", -9999)), int(d.get("r", -9999))]
		if d.is_empty() or not pkgs.has(uid):
			dropped.append({"unit_id": str(uid), "reason": "NO_DESTINATION"})
			continue
		if not claimed.has(key):
			claimed[key] = str(uid)
			final_by_id[uid] = it
			continue
		# Contended: best free legal realization of THIS unit wins a new hex.
		contended += 1
		var alts: Array = []
		for o_val in ((pkgs[uid] as Dictionary).get("options", []) as Array):
			if not o_val is Dictionary:
				continue
			var o: Dictionary = o_val
			if not str(o.get("status", "")).to_upper() in ["AVAILABLE", "DEGRADED"]:
				continue
			if not o.has("destination"):
				continue
			var od: Dictionary = o["destination"]
			var okey := "%d,%d" % [int(od.get("q", -9999)), int(od.get("r", -9999))]
			if claimed.has(okey):
				continue
			alts.append({"key": okey, "utility": float(o.get("utility", 0.0)),
				"profile": str(o.get("profile", "?")).to_upper(), "opt": o})
		alts.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			if absf(float(a["utility"]) - float(b["utility"])) > 1e-9:
				return float(a["utility"]) > float(b["utility"])
			return str(a["profile"]) < str(b["profile"]))
		if alts.is_empty():
			dropped.append({"unit_id": str(uid),
				"reason": "NO_FREE_DESTINATION (destination contention)"})
			continue
		var win: Dictionary = alts[0]
		var wopt: Dictionary = win["opt"]
		var wd: Dictionary = wopt["destination"]
		var fixed := (it as Dictionary).duplicate(true)
		fixed["profile"] = str(win["profile"])
		fixed["slot"] = int(wopt.get("slot", 0))
		fixed["destination"] = {"q": int(wd.get("q", 0)), "r": int(wd.get("r", 0))}
		fixed["path"] = ((wopt.get("route", {}) as Dictionary).get("path", []) as Array).duplicate(true)
		claimed[str(win["key"])] = str(uid)
		final_by_id[uid] = fixed
		adapted.append({"unit_id": str(uid),
			"from_profile": str(it.get("profile", "?")),
			"to_profile": str(win["profile"]),
			"destination": {"q": int(wd.get("q", 0)), "r": int(wd.get("r", 0))}})
	var out_items: Array = []
	for it in items:
		if it is Dictionary and final_by_id.has(str((it as Dictionary).get("unit_id", ""))):
			out_items.append(final_by_id[str((it as Dictionary).get("unit_id", ""))])
	return {"items": out_items, "adapted": adapted, "dropped": dropped,
		"contended": contended}


# --- Staging + approval ------------------------------------------------------------------

## Freeze a validated plan as provisional. No mutation, no movement.
## Carries its own preview truth: routes + unit cells + band-highlight token.
func _stage(command_id: String, rec: Dictionary, intent: Dictionary,
		kind: String, items: Array, command: Dictionary) -> void:
	var scope: Dictionary = intent.get("scope", {})
	var region := str(scope.get("region", ""))
	var token := ""
	if region in ["LEFT", "CENTER", "RIGHT"]:
		token = region
	elif region in ["EXTREME_LEFT", "EXTREME_RIGHT"]:
		var ex := ClustersScript.extreme_left() if region == "EXTREME_LEFT" else ClustersScript.extreme_right()
		token = ex
	elif IntentScript.is_concrete_band(region):
		token = region
	var cells: Array = []
	var routes: Array = []
	if kind == "moves" or kind == "composite":
		for it in items:
			var f: Variant = (it as Dictionary).get("from", [])
			if f is Array and (f as Array).size() == 2:
				cells.append(Vector2i(int((f as Array)[0]), int((f as Array)[1])))
			var p: Variant = (it as Dictionary).get("path", [])
			routes.append({"path_cells": (p as Array).duplicate(true) if p is Array else []})
	else:
		token = ""
		cells = (rec.get("preview_cells", []) as Array).duplicate(true)
		routes = (rec.get("preview_routes", []) as Array).duplicate(true)
	var _cir_fp := ""
	var _cir_diag := {}
	if rec.has("command_ir") and (rec.get("command_ir", {}) as Dictionary).has("fingerprint"):
		_cir_fp = str((rec.get("command_ir", {}) as Dictionary).get("fingerprint", ""))
		_cir_diag = CommandIRScript.dev_diagnostics(rec.get("command_ir", {}))
	_staged = {
		"command_id": command_id,
		"original_text": str(rec.get("text", "")),
		"intent": (intent as Dictionary).duplicate(true),
		"orders": (rec.get("orders", _orders_of(intent)) as Array).duplicate(true),
		"orders_fp": orders_fingerprint(rec.get("orders", _orders_of(intent))),
		"command_ir": (rec.get("command_ir", {}) as Dictionary).duplicate(true) if rec.has("command_ir") else {},
		"command_ir_fp": _cir_fp,
		"command_ir_diag": _cir_diag,
		"scope_expr_fp": str(rec.get("scope_expr_fp", "")),
		"kind": kind,
		"scope_label": str(rec.get("scope_label", "")),
		"unit_ids": (rec.get("unit_ids", []) as Array).duplicate(),
		"items": items.duplicate(true),
		"command": (command as Dictionary).duplicate(true),
		"highlight_token": token,
		"preview_cells": cells,
		"preview_routes": routes,
		"state_version": int(_truth.get_version()),
		"fingerprint": str(_truth.fingerprint()),
		"turn": _turn(),
		"cluster_sig": ClustersScript.frozen_signature(),
		"config_identity": BackendCfgScript.config_identity(),
		"status": "READY_FOR_APPROVAL",
	}
	_trace.append("STAGED kind=%s units=%d" % [kind, (rec.get("unit_ids", []) as Array).size()])
	_debug["outcome"] = "staged"
	_debug["staged"] = _staged.duplicate(true)
	_active.erase(command_id)
	chat_busy.emit(false)
	if _adapter != null and _adapter.has_method("show_staged_preview"):
		_adapter.show_staged_preview(_staged)


func _after_stage_announce(command_id: String) -> void:
	chat_append.emit("ADVISOR", "지도에 편성안을 표시했습니다. [실행] 또는 [취소]하십시오.")


## Window [실행]: stale-check, then canonical execution (or regen + re-ask).
func approve_staged() -> void:
	if not has_staged():
		return
	var st := _staged.duplicate(true)
	if _staged_drifted():
		_clear_stage()
		if _adapter != null and _adapter.has_method("clear_staged_preview"):
			_adapter.clear_staged_preview()
		chat_append.emit("ADVISOR", "전황이 바뀌어 명령안을 다시 검토합니다...")
		chat_busy.emit(true)
		_regen_from_original(st)
		return
	var cid := str(st.get("command_id", ""))
	chat_busy.emit(true)
	if str(st.get("kind", "")) == "native":
		_adapter.execute_native_plan(cid,
			(st.get("command", {}) as Dictionary).duplicate(true),
			Callable(self, "_on_execution_done"))
	elif str(st.get("kind", "")) == "holds":
		_adapter.execute_hold_units(cid,
			(st.get("items", []) as Array).duplicate(true),
			Callable(self, "_on_execution_done"))
	elif str(st.get("kind", "")) == "composite":
		var moves: Array = []
		var holds: Array = []
		for it in (st.get("items", []) as Array):
			if it is Dictionary and (it as Dictionary).has("destination"):
				moves.append((it as Dictionary).duplicate(true))
			elif it is Dictionary:
				holds.append(str((it as Dictionary).get("unit_id", "")))
		_adapter.execute_composite(cid, moves, holds,
			Callable(self, "_on_execution_done"))
	else:
		_adapter.execute_chat_moves(cid,
			(st.get("items", []) as Array).duplicate(true),
			Callable(self, "_on_execution_done"))


## Rebuild from the ORIGINAL user text after approval-time drift: fresh
## packages, fresh LLM selection, then stage again (Execute required anew).
## Shared with the finalize-time drift path via _regen_pipeline().
func _regen_from_original(st: Dictionary) -> void:
	_regen_pipeline(str(st.get("original_text", "")),
		(st.get("intent", {}) as Dictionary).duplicate(true))


func _regen_pipeline(text: String, intent: Dictionary) -> void:
	_seq += 1
	var command_id := "cmd-%04d" % _seq
	_active[command_id] = {
		"text": text, "phase": "regen", "repair_used": false,
		"sent_msec": Time.get_ticks_msec(),
		"state_version": int(_truth.get_version()),
		"fingerprint": str(_truth.fingerprint()),
		"turn": _turn(),
		"cluster_sig": ClustersScript.frozen_signature(),
		"config_identity": BackendCfgScript.config_identity(),
		"intent": intent.duplicate(true),
		"orders": _orders_of(intent),
		"scope_label": "", "unit_ids": [],
		"packages": {}, "rep_context": {}, "supplied_ids": [],
		"selection": {},
	}
	_trace.append("REGEN from: %s" % text.substr(0, 60))
	chat_append.emit("USER", "(재검토) " + text)
	chat_busy.emit(true)
	var rec: Dictionary = _active[command_id]
	_debug["command_id"] = command_id
	_route_command(command_id, rec, intent, str(intent.get("request_type", "COMMAND")))


# --- INFORMATION ------------------------------------------------------------------------------

func _answer_information(command_id: String, rec: Dictionary, intent: Dictionary) -> void:
	var layout := friendly_layout()
	var tote := 0
	for b in layout:
		for c in ((b as Dictionary).get("class_counts", {}) as Dictionary).values():
			tote += int(c)
	var sel := _selected_unit()
	var user_block := {
		"player_message": str(rec.get("text", "")),
		"turn": _turn(),
		"friendly_layout": layout,
		"total_blue_formations": tote,
		"selected_unit": {} if sel.is_empty() else {"id": str(sel.get("id", "")),
			"cluster": ClustersScript.cluster_of_unit(sel)},
		"recent_history": _history_block(),
		"order": "Answer in Korean, under 400 characters, from THESE facts only. JSON only: {\"answer\": \"...\"}.",
	}
	_send_phase(command_id, "info",
		"You are Seo Yuseon (서유선), staff advisor. Answer status questions from supplied facts only. Never invent units, positions, or enemy facts. JSON only.",
		"STATUS_QUESTION_JSON:\n" + JSON.stringify(user_block))


func _handle_info_response(command_id: String, rec: Dictionary, raw: String) -> void:
	var parsed := IntentScript.extract_json(raw)
	var answer := str(parsed.get("answer", ""))
	if parsed.is_empty() or answer.strip_edges().is_empty():
		if bool(rec.get("repair_used", false)):
			_fail(command_id, "MALFORMED", "empty answer", true)
			return
		rec["repair_used"] = true
		_active[command_id] = rec
		_send_phase(command_id, "info",
			"You are Seo Yuseon (서유선). Answer from supplied facts only. JSON only: {\"answer\": \"...\"}.",
			"Your previous response had no usable answer. Return valid JSON only.")
		return
	var clean: Dictionary = ViewModelScript.sanitize_advisor_text(
		answer, rec.get("supplied_ids", []))
	_push_history(str(rec.get("text", "")), str(clean.get("text", "")))
	_say_and_close(command_id, str(clean.get("text", "")), "info")


# --- Execution callback --------------------------------------------------------------------------

func _on_execution_done(command_id: String, summary: Dictionary) -> void:
	_push_history(str((_staged.get("original_text", ""))), str(summary.get("short", "")))
	_clear_stage()
	if _adapter != null and _adapter.has_method("update_approval"):
		_adapter.update_approval()
	_say_and_close(command_id, str(summary.get("player_text",
		"이동을 완료했습니다.")), "executed")
	command_finished.emit(command_id, bool(summary.get("ok", false)),
		str(summary.get("short", "")))


# --- Chat helpers -------------------------------------------------------------------------------------

func _say(command_id: String, text: String) -> void:
	chat_append.emit("ADVISOR", display_profile_kr(text))


## Display mapping for leaked internal profile ids (defense in depth behind
## the prompt contract): SAFE/SUPPORTED/... become game terms. Word-boundary
## safe, idempotent, never touches unit ids or body text otherwise.
static func display_profile_kr(text: String) -> String:
	var out := text
	for p in ["SAFE", "SUPPORTED", "BALANCED", "PRESSURE", "DEEP", "MAXIMUM"]:
		var re := RegEx.new()
		re.compile("\\b%s\\b" % p)
		out = re.sub(out, ViewModelScript.profile_kr(p), true)
	return out


func _say_and_close(command_id: String, text: String, outcome: String = "closed") -> void:
	_debug["outcome"] = outcome
	_trace.append("OUTCOME=%s" % outcome)
	chat_append.emit("ADVISOR", display_profile_kr(text))
	_active.erase(command_id)
	chat_busy.emit(false)


func _ask(command_id: String, question: String, outcome: String = "clarify") -> void:
	var rec: Dictionary = _active.get(command_id, {})
	_push_history(str(rec.get("text", "")), question)
	_say_and_close(command_id, question, outcome)


func _push_history(user_text: String, advisor_text: String) -> void:
	_history.append({"user": user_text.substr(0, HISTORY_CHARS),
		"advisor": advisor_text.substr(0, HISTORY_CHARS)})
	while _history.size() > HISTORY_KEEP * 2:
		_history.pop_front()
	_debug["history_depth"] = _history.size()


func _fail(command_id: String, code: String, detail: String, transport: bool,
		override_text: String = "") -> void:
	_debug["failure"] = "%s: %s" % [code, detail]
	_debug["outcome"] = "fail:" + code
	_trace.append("FAIL %s" % code)
	_active.erase(command_id)
	chat_busy.emit(false)
	var msg := override_text
	if msg.is_empty():
		msg = _player_message_for(code)
	chat_append.emit("ADVISOR", msg)
	command_finished.emit(command_id, false, code)
	print("[ChatCmd] command %s failed: %s" % [command_id, code])


func _player_message_for(code: String) -> String:
	match code:
		"OFFLINE", "TIMEOUT":
			return "현재 전술 자문 모델에 연결할 수 없습니다."
		"MODEL_MISSING":
			return "자문 모델을 찾을 수 없습니다. AI 설정에서 모델을 확인해 주십시오."
		"MALFORMED", "BAD_RESPONSE":
			return "자문 서신이 흐트러졌습니다. 다시 한 번 말씀해 주십시오."
		"NO_OPTIONS":
			return "실행 가능한 전술안이 없습니다."
		_:
			return "자문을 받아오지 못했습니다. 다시 말씀해 주십시오."
