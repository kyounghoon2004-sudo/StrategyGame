class_name Step7SemanticFrontend
extends Node

## Tiny-model semantic front door (ONE inference on the fast path).
##
## PLAYER TEXT -> semantic Qwen3-0.6B (compact contract) -> SemanticEnvelope
## -> CommandIR v2 -> SemanticGate -> lane:
##   COMMAND valid        -> existing staging (ZERO large-model calls)
##   INFORMATION / TACTICAL_ADVICE / CONVERSATION -> existing large path
##   HARD_CONFLICT / SEQUENCE / EMPTY -> STOP + clarification, no staging
##   invalid / uncertain  -> large semantic fallback (fail closed)
##
## Semantic context only (no tactical matrix, no RED truth): selected unit
## pointer, pending clarification, last scope label, schema. Prompts stay
## compact: the 0.6B model gets mode/orders/scope-algebra/relations/
## modifiers/evidence and nothing else.

signal frontend_finished(request_id: String, result: Dictionary)

const EnvelopeScript = preload("res://scripts/step7/step7_semantic_envelope.gd")
const CommandIRScript = preload("res://scripts/step7/step7_command_ir.gd")
const GateScript = preload("res://scripts/step7/step7_semantic_gate.gd")
const IntentScript = preload("res://scripts/step7/step7_chat_intent.gd")

## Compact semantic contract for the tuned 0.6B checkpoint. Native
## tool/function serialization was inspected (distilana home-assistant
## <tool_call> JSON); under the Ollama /api/chat runtime strict JSON
## schema output measured more reliable, so the contract demands one raw
## JSON object and Godot normalizes it into envelope + CommandIR v2.
const SEMANTIC_SYSTEM := """You are the semantic front door of a Korean historical strategy game. Read the commander's Korean message and emit ONE raw JSON object, no prose, no fences.

MODES (semantic force, never punctuation):
- COMMAND: imperative orders (진격하라, 전진시켜, 대기해, 보내, 실행해). Must carry orders[].
- INFORMATION: status questions (상황이 어때, 어디에 있어, 알려줘).
- TACTICAL_ADVICE: asks what is GOOD (좋을까, 어떨까, 나을까, 권해줘, 어디로 보내는 게 좋아).
- CLARIFICATION: only when YOU cannot parse at all. Otherwise decide.
- CONVERSATION: greetings/small talk.
Minimal pairs: "기병 전진"=COMMAND, "기병 전진하는 게 좋을까"=TACTICAL_ADVICE, "기병이 대기 중이야"=INFORMATION, "적 기병 어디로 올 것 같아"=TACTICAL_ADVICE, "적 기병이 어디에 보여"=INFORMATION.

ACTIONS (emit ONLY these): ADVANCE HOLD MOVE RETREAT RECON FLANK REPOSITION WITHDRAW REGROUP PROTECT SCREEN.
Classes: CAVALRY 기병 INFANTRY 보병 SPEARMAN 창병 ARCHER 궁병 SCOUT 정찰(병) SIEGE 공성 CONSCRIPT 징집 ALL_ARMS 전병과. Regions: LEFT 좌익 CENTER 중앙 RIGHT 우익 EXTREME_LEFT 극좌익 EXTREME_RIGHT 극우익 ALL C L1 R1... SELECTED PREVIOUS.

ORDERS (COMMAND only, one per clause split on -하고/-고/-면서):
- Single: orders has EXACTLY one element.
- "정찰병은 전진하고 나머지는 대기" = TWO orders: ADVANCE scope WING_CLASS SCOUT/ALL + HOLD with scope_expr DIFF(ALL_FRIENDLY, CLASS(SCOUT)).
- "좌익은 대기하고 우익은 전진" = HOLD LEFT + ADVANCE RIGHT.
- remainder 나며지/본대 = DIFF from the carved domain (ALL_FRIENDLY default; 나머지 + class = that CLASS).
- relation: single omit (game uses SINGLE); multi PARALLEL, or SEQUENCE when 먼저/그다음/이어서/순서대로/차례로 appears. NEVER SINGLE with 2+ orders.
- Whole-force words 전군/전부대/모두/전체 = type ALL_AVAILABLE region ALL class ALL_ARMS. Bare class ("기병 전진") = WING_CLASS region ALL COMMAND. Wing with no class for HOLD = ALL_ARMS. "그렇게 해"/"아까 말한 대로" = PREVIOUS.
- scope_expr ONLY for exclusion (제외/빼고) and UNION/INTERSECT/DIFF compositions; atoms ALL_FRIENDLY ALL_COMBAT CLASS WING CLUSTER UNIT SELECTED EMPTY; ops UNION/INTERSECT/DIFF. NEVER unit-id lists. Omit ({}) otherwise.
- Each order: exact verbatim "source_evidence" quote from THIS clause (copy substring, no paraphrase). Optional "modifiers" {pace slow|fast, extent partial|maximal, formation keep} for nuance (천천히/조금만/전열 유지); style {risk low|balanced|high, pressure, depth shallow|normal|deep} stays.
- confidence 0.0-1.0; below ~0.45 use CLARIFICATION with Korean "question".

SCHEMA:
COMMAND: {"mode":"COMMAND","confidence":0.9,"relation":"PARALLEL","orders":[{"action":"ADVANCE","scope":{"type":"WING_CLASS","class":"SCOUT","region":"ALL","unit_id":"","regions":[],"classes":[]},"scope_expr":{},"style":{"risk":"balanced","pressure":"balanced","depth":"normal"},"modifiers":{},"source_evidence":["정찰병은 전진하고"],"confidence":0.9}],"question":"","reference":{}}
Non-COMMAND: {"mode":"INFORMATION","confidence":0.9,"orders":[],"question":"","reference":{},"source_evidence":[]}
Return JSON ONLY."""

const LOW_CONFIDENCE := 0.45


static func build_ctx(selected: Dictionary, pending: Dictionary,
		last_scope_label: String, history_note: String = "") -> Dictionary:
	return {"selected": selected.duplicate(true),
		"pending": pending.duplicate(true),
		"last_scope": last_scope_label, "history": history_note}


static func build_messages(text: String, ctx: Dictionary) -> Array:
	var user_block := {
		"message": text,
		"selected_unit": ctx.get("selected", {}),
		"pending_clarification": ctx.get("pending", {}),
		"last_scope": str(ctx.get("last_scope", "")),
		"instruction": "Emit ONE JSON object per the contract. Korean evidence quotes verbatim.",
	}
	if not str(ctx.get("history", "")).is_empty():
		user_block["history_note"] = str(ctx.get("history", ""))
	return [{"role": "system", "content": SEMANTIC_SYSTEM},
		{"role": "user", "content": "PLAYER_MESSAGE_JSON:\n" + JSON.stringify(user_block)}]


## Parse + normalize one raw tiny-model reply (pure, headless-testable).
## Returns {ok, envelope, intent, ir} or {ok:false, fallback_reason, why}.
static func handle_raw(raw: String, original_text: String) -> Dictionary:
	var parsed := IntentScript.extract_json(raw)
	if parsed.is_empty():
		return {"ok": false, "fallback_reason": "TINY_INVALID_JSON", "why": "no parseable JSON object"}
	var env_r: Dictionary = EnvelopeScript.from_tiny_output(parsed, original_text)
	if not bool(env_r.get("ok", false)):
		return {"ok": false, "fallback_reason": "TINY_INVALID_SCHEMA", "why": str(env_r.get("why", "?"))}
	var env: Dictionary = env_r.get("envelope", {})
	if float(env.get("confidence", 0.0)) < LOW_CONFIDENCE:
		return {"ok": false, "fallback_reason": "TINY_LOW_CONFIDENCE",
			"why": "confidence %.2f" % float(env.get("confidence", 0.0)), "envelope": env}
	var intent: Dictionary = EnvelopeScript.to_intent(env)
	var checked: Dictionary = IntentScript.validate_intent(intent)
	if not bool(checked.get("ok", false)):
		return {"ok": false, "fallback_reason": "TINY_INVALID_INTENT",
			"why": str(checked.get("why", "?")), "envelope": env}
	var normed: Dictionary = checked.get("intent", {})
	var ir_r: Dictionary = CommandIRScript.from_validated_intent(normed, original_text)
	if not bool(ir_r.get("ok", false)):
		return {"ok": false, "fallback_reason": "TINY_INVALID_IR",
			"why": str(ir_r.get("why", "?")), "envelope": env}
	return {"ok": true, "envelope": env, "intent": normed, "ir": ir_r.get("ir", {})}


## Full tiny pass incl. gate (pure over live deps for resolution).
## Returns {ok, envelope, intent, ir, gate} or {ok:false, fallback_reason,...}.
## Gate STOPs with fallback_to_large=false are returned as ok:true with a
## STOP gate (caller asks clarification / holds sequence WITHOUT any
## large call). Gate STOPs with fallback_to_large=true become fallback.
static func full_pass(raw: String, original_text: String, gate_deps: Dictionary) -> Dictionary:
	var h := handle_raw(raw, original_text)
	if not bool(h.get("ok", false)):
		return h
	var gate: Dictionary = GateScript.evaluate(h.get("ir", {}), gate_deps)
	if str(gate.get("verdict", "")) == "STOP" and bool(gate.get("fallback_to_large", false)):
		return {"ok": false, "fallback_reason": "GATE_" + str(gate.get("stop_kind", "STOP")),
			"why": str(gate.get("stop_kind", "?")), "envelope": h.get("envelope", {}),
			"ir": h.get("ir", {}), "gate": gate}
	return {"ok": true, "envelope": h.get("envelope", {}), "intent": h.get("intent", {}),
		"ir": h.get("ir", {}), "gate": gate}
