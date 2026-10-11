class_name Step7ChatIntent
extends RefCounted

const AlgebraScript = preload("res://scripts/step7/step7_scope_algebra.gd")

## Chat-driven commander intent contract v2 (language layer, no game state).
##
## The LLM translates player natural language into ONE constrained semantic
## intent over the ACTUAL deterministic command vocabulary (audited against
## Step7ActionCommand VALID_ACTIONS / VALID_SCOPE_TYPES). Godot — never the
## model — resolves scopes, generates legal options, validates, stages, and
## (after player approval) executes. Model output is untrusted: allow-list
## validated by validate_intent().
##
## Intent JSON:
##   {"request_type": "COMMAND|ADVICE|INFORMATION|CLARIFICATION",
##    "action": "ADVANCE|HOLD|REPOSITION|...",
##    "scope": {"type": "ALL_AVAILABLE|WING_CLASS|CLUSTER_CLASS|UNIT|PREVIOUS",
##              "class": "CAVALRY|INFANTRY|...|ALL_ARMS",
##              "region": "LEFT|...|SELECTED|L1|...", "unit_id": ""},
##    "style": {"risk": "low|balanced|high", "pressure": "low|balanced|high",
##              "depth": "shallow|normal|deep"},
##    "confidence": 0.0-1.0, "question": "", "missing": []}
##
## Scope-type semantics:
##   ALL_AVAILABLE = whole BLUE force (전군). No wing subdivision. NEVER
##     rewrite this as cavalry-wing scope: it is a distinct first-class scope.
##   WING_CLASS    = one macro wing + one class (LEFT/CENTER/RIGHT/EXTREMEs).
##   CLUSTER_CLASS = one concrete band + one class (C, L1..Ln, R1..Rn).
##   UNIT          = one formation: named unit_id, or SELECTED region.
##   PREVIOUS      = last advice (follow-ups like "그렇게 해").

const REQUEST_TYPES := ["COMMAND", "ADVICE", "INFORMATION", "CLARIFICATION"]

## Audited against Step7ActionCommand.VALID_ACTIONS. The model may emit any
## of these; the commander honest-gates what chat can actually stage.
const ACTIONS := ["ADVANCE", "MOVE", "HOLD", "RETREAT", "RECON", "FLANK",
	"REPOSITION", "WITHDRAW", "REGROUP", "PROTECT", "SCREEN"]

const SCOPE_TYPES := ["ALL_AVAILABLE", "WING_CLASS", "CLUSTER_CLASS",
	"UNIT", "PREVIOUS", "UNION"]

## Multi-region union: two or more macro wings / concrete bands as ONE scope
## ("둘다", "양쪽", "좌우 모두"). Single-region answers keep region/….
const MAX_UNION_REGIONS := 4
const MAX_ORDERS := 4

const MACRO_REGIONS := ["LEFT", "CENTER", "RIGHT", "EXTREME_LEFT", "EXTREME_RIGHT",
	"ALL", "SELECTED", "PREVIOUS"]
## Canonical style levels. Validation ACCEPTS the wider natural vocabulary
## below and folds it (normal/medium/moderate -> balanced): live models emit
## "normal" for the middle level, and vetoing a perfect intent over a
## cosmetic preference token was a real player-facing MALFORMED (proven).
const STYLE_LEVELS := ["low", "balanced", "high"]
const STYLE_ACCEPT := ["low", "normal", "balanced", "medium", "moderate", "high"]
const STYLE_FOLD := {"low": "low", "normal": "balanced", "balanced": "balanced",
	"medium": "balanced", "moderate": "balanced", "high": "high"}
const DEPTH_LEVELS := ["shallow", "normal", "deep"]
const DEPTH_ACCEPT := ["shallow", "normal", "deep", "medium", "moderate"]
const DEPTH_FOLD := {"shallow": "shallow", "normal": "normal", "deep": "deep",
	"medium": "normal", "moderate": "normal"}
const KNOWN_CLASSES := ["CAVALRY", "INFANTRY", "SPEARMAN", "ARCHER", "SCOUT",
	"SIEGE", "CONSCRIPT", "HQ", "SUPPLY", "ALL_ARMS"]

const MAX_FIELD_CHARS := 600

## Deterministic alias normalization AFTER model output. The LLM does the
## interpretation; this only folds surface variants to canonical tokens.
const REGION_ALIASES := {
	"LEFT_WING": "LEFT", "RIGHT_WING": "RIGHT", "MIDDLE": "CENTER",
	"CENTRE": "CENTER", "EXTREME-LEFT": "EXTREME_LEFT",
	"EXTREME-RIGHT": "EXTREME_RIGHT", "FAR_LEFT": "EXTREME_LEFT",
	"FAR_RIGHT": "EXTREME_RIGHT", "OUTER_LEFT": "EXTREME_LEFT",
	"OUTER_RIGHT": "EXTREME_RIGHT", "EVERYWHERE": "ALL",
	"SELECTED_UNIT": "SELECTED", "THIS_UNIT": "SELECTED",
	"LAST": "PREVIOUS", "PREV": "PREVIOUS", "THAT": "PREVIOUS",
	"좌익": "LEFT", "좌측": "LEFT", "왼쪽": "LEFT", "좌": "LEFT",
	"우익": "RIGHT", "우측": "RIGHT", "오른쪽": "RIGHT", "우": "RIGHT",
	"중앙": "CENTER", "중부": "CENTER",
	"극좌익": "EXTREME_LEFT", "극좌": "EXTREME_LEFT",
	"극우익": "EXTREME_RIGHT", "극우": "EXTREME_RIGHT",
	"전체": "ALL", "전군": "ALL", "전부대": "ALL", "모두": "ALL",
	"선택": "SELECTED", "이전": "PREVIOUS", "직전": "PREVIOUS",
}

## Whole-force aliases: presence of these words (as scope) means the ENTIRE
## army, never one wing. Listed so tests and prompts share one source.
const WHOLE_FORCE_WORDS := ["전군", "전부대", "모두", "전체"]

## Surface-form action fold (normalization AFTER model output, NOT parsing:
## the model still interprets; this only folds Korean verb tokens some
## outputs use instead of canonical English tokens).
const ACTION_ALIASES := {
	"전진": "ADVANCE", "진격": "ADVANCE", "진군": "ADVANCE", "돌격": "ADVANCE",
	"대기": "HOLD", "정지": "HOLD", "후퇴": "RETREAT", "철수": "WITHDRAW",
	"정찰": "RECON", "측면": "FLANK", "우회": "FLANK", "재배치": "REPOSITION",
	"재집결": "REGROUP", "보호": "PROTECT", "엄호": "PROTECT",
}

## Surface-form class fold (same normalization layer as actions).
const CLASS_ALIASES := {
	"기병": "CAVALRY", "보병": "INFANTRY", "창병": "SPEARMAN",
	"궁병": "ARCHER", "정찰": "SCOUT", "정찰대": "SCOUT", "공성": "SIEGE",
	"징집": "CONSCRIPT", "전병과": "ALL_ARMS",
}


static func normalize_action(raw: String) -> String:
	var t := raw.strip_edges().to_upper()
	if t in ACTION_ALIASES:
		return str(ACTION_ALIASES[t])
	return t


static func normalize_class(raw: String) -> String:
	var t := raw.strip_edges().to_upper()
	if t in CLASS_ALIASES:
		return str(CLASS_ALIASES[t])
	return t


## Infer an omitted scope.type deterministically (never a guess about
## membership — only a shape default the router refines):
##   ALL + ALL_ARMS/empty -> ALL_AVAILABLE (whole force);
##   ALL + specific class -> WING_CLASS (class-wide ambiguity gate decides);
##   macro/extreme region -> WING_CLASS; concrete band -> CLUSTER_CLASS;
##   SELECTED -> UNIT; PREVIOUS -> PREVIOUS.
static func infer_scope_type(cls: String, region: String, unit_id: String) -> String:
	if region == "PREVIOUS":
		return "PREVIOUS"
	if not unit_id.is_empty():
		return "UNIT"
	if region == "SELECTED":
		return "UNIT"
	if region == "ALL":
		if cls.is_empty() or cls == "ALL_ARMS":
			return "ALL_AVAILABLE"
		return "WING_CLASS"
	if region in ["LEFT", "CENTER", "RIGHT", "EXTREME_LEFT", "EXTREME_RIGHT"]:
		return "WING_CLASS"
	if is_concrete_band(region):
		return "CLUSTER_CLASS"
	return ""


static func normalize_region(raw: String) -> String:
	var t := raw.strip_edges().to_upper().replace(" ", "_").replace("-", "_")
	if t in REGION_ALIASES:
		return str(REGION_ALIASES[t])
	return t


static func is_concrete_band(region: String) -> bool:
	var t := region.strip_edges().to_upper()
	if t == "C":
		return true
	if t.length() > 1 and (t.begins_with("L") or t.begins_with("R")) \
			and t.substr(1).is_valid_int():
		return int(t.substr(1)) >= 1
	return false


## Strict allow-list validation. Returns {ok, intent(normalized), why}.
## Contract v3: "orders"[] (one element for single orders). The legacy
## single-order shape (top-level action/scope/style/confidence) is still
## accepted and normalized to orders len-1 — byte-identical outcomes for
## every legacy raw. Top-level action/scope/style/confidence always mirror
## orders[0] so single-order consumers never change.
## CLARIFICATION may carry partial fields (action "" / region "" / class "")
## plus a missing[] list naming the unresolved semantic fields.
static func validate_intent(rec: Dictionary) -> Dictionary:
	if not rec.has("request_type"):
		return {"ok": false, "why": "missing key 'request_type'"}
	var rtype := str(rec.get("request_type", "")).strip_edges().to_upper()
	if not rtype in REQUEST_TYPES:
		return {"ok": false, "why": "request_type '%s' not in [%s]" % [str(rec.get("request_type", "")), ", ".join(REQUEST_TYPES)]}
	var partial := rtype == "CLARIFICATION"
	# CommandIR v2 passthrough (Step 1, additive only): optional semantic
	# envelope fields the normalizer owns. Preserved verbatim here (no
	# rejection — IR validation is the strict gate); absent in all legacy
	# outputs so legacy outcomes stay byte-identical.
	var relation_raw := str(rec.get("relation", "")).strip_edges().to_upper()
	var raw_orders: Array = []
	var is_legacy := true
	if rec.has("orders") and rec.get("orders") is Array and not (rec.get("orders") as Array).is_empty():
		raw_orders = (rec.get("orders") as Array).duplicate()
		is_legacy = false
		if raw_orders.size() > MAX_ORDERS:
			return {"ok": false, "why": "too many orders (max %d)" % MAX_ORDERS}
	else:
		for key in ["action", "scope", "style", "confidence"]:
			if not rec.has(key):
				return {"ok": false, "why": "missing key '%s'" % key}
		var legacy_one := {"action": rec.get("action", ""), "scope": rec.get("scope", {}),
			"style": rec.get("style", {}), "confidence": rec.get("confidence", -1.0)}
		if rec.has("scope_expr"):
			legacy_one["scope_expr"] = rec.get("scope_expr", {})
		if rec.has("source_evidence"):
			legacy_one["source_evidence"] = rec.get("source_evidence", [])
		if rec.has("modifiers"):
			legacy_one["modifiers"] = rec.get("modifiers", {})
		if rec.has("order_id"):
			legacy_one["order_id"] = rec.get("order_id", "")
		raw_orders = [legacy_one]
	var orders: Array = []
	var min_conf := 1.0
	for i in range(raw_orders.size()):
		var o_raw: Variant = raw_orders[i]
		if not o_raw is Dictionary:
			return {"ok": false, "why": "orders[%d] must be an object" % i}
		var o: Dictionary = o_raw
		# Legacy path uses idx -1 so every historically emitted error
		# string stays byte-identical.
		var idx := -1 if is_legacy else i
		var ac := _validate_action_token(o.get("action", ""), rtype, partial, idx)
		if not bool(ac.get("ok", false)):
			return ac
		var sc := _validate_scope(o.get("scope", {}), partial, idx)
		if not bool(sc.get("ok", false)):
			return sc
		var st := _validate_style(o.get("style", {}), idx)
		if not bool(st.get("ok", false)):
			return st
		var oc := 1.0
		if o.has("confidence"):
			oc = float(o.get("confidence", -1.0))
			if oc < 0.0 or oc > 1.0:
				if is_legacy:
					return {"ok": false, "why": "confidence outside 0.0-1.0"}
				return {"ok": false, "why": "orders[%d].confidence outside 0.0-1.0" % i}
		var scope_expr := {}
		if o.has("scope_expr") and not (o.get("scope_expr") is Dictionary and (o.get("scope_expr") as Dictionary).is_empty()):
			if not o.get("scope_expr") is Dictionary:
				if is_legacy:
					return {"ok": false, "why": "scope_expr must be an object"}
				return {"ok": false, "why": "orders[%d].scope_expr must be an object" % i}
			var se: Dictionary = AlgebraScript.validate_expr(o.get("scope_expr"))
			if not bool(se.get("ok", false)):
				if is_legacy:
					return {"ok": false, "why": "scope_expr: %s" % str(se.get("why", "?"))}
				return {"ok": false, "why": "orders[%d].scope_expr: %s" % [i, str(se.get("why", "?"))]}
			scope_expr = (o.get("scope_expr") as Dictionary).duplicate(true)
		# CommandIR passthrough: exact source quote(s) + semantic modifiers
		# + deterministic order identity. Lenient shape fold only (String
		# -> [String], dedupe, caps); strict checks live in CommandIR.
		var evidence: Array = []
		var ev_raw: Variant = o.get("source_evidence", o.get("evidence", []))
		if ev_raw is String:
			var _t := (ev_raw as String).strip_edges()
			if not _t.is_empty():
				evidence = [_t.left(MAX_FIELD_CHARS)]
		elif ev_raw is Array:
			for q_val in (ev_raw as Array):
				var _q := str(q_val).strip_edges()
				if _q.is_empty():
					continue
				if not _q in evidence:
					evidence.append(_q.left(MAX_FIELD_CHARS))
				if evidence.size() >= 4:
					break
		var modifiers := {}
		if o.get("modifiers", {}) is Dictionary:
			modifiers = (o.get("modifiers", {}) as Dictionary).duplicate(true)
		var order_entry := {"action": str(ac.get("action", "")),
			"scope": sc.get("scope", {}),
			"scope_expr": scope_expr,
			"style": st.get("style", {}),
			"confidence": oc,
			"source_evidence": evidence,
			"modifiers": modifiers}
		if str(o.get("order_id", "")).strip_edges() != "":
			order_entry["order_id"] = str(o.get("order_id", "")).strip_edges()
		orders.append(order_entry)
		min_conf = minf(min_conf, oc)
	var conf := min_conf
	if rec.has("confidence"):
		conf = float(rec.get("confidence", -1.0))
		if conf < 0.0 or conf > 1.0:
			return {"ok": false, "why": "confidence outside 0.0-1.0"}
	var question := str(rec.get("question", ""))
	if question.length() > MAX_FIELD_CHARS:
		return {"ok": false, "why": "question exceeds %d chars" % MAX_FIELD_CHARS}
	var missing: Array = []
	if rec.has("missing") and rec.get("missing") is Array:
		for m in (rec.get("missing") as Array):
			var mt := str(m).strip_edges().to_lower()
			if mt in ["action", "class", "region", "scope"] and not mt in missing:
				missing.append(mt)
	var first: Dictionary = orders[0]
	return {"ok": true, "intent": {
		"request_type": rtype,
		"action": str(first.get("action", "")),
		"scope": (first.get("scope", {}) as Dictionary).duplicate(true),
		"scope_expr": (first.get("scope_expr", {}) as Dictionary).duplicate(true),
		"style": (first.get("style", {}) as Dictionary).duplicate(true),
		"confidence": float(first.get("confidence", 0.0)),
		"orders": orders,
		"order_confidence": conf,
		"relation": relation_raw,
		"question": question, "missing": missing,
	}}


## Per-order action token validation (extracted verbatim from the legacy
## inline path; behavior identical).
static func _validate_action_token(action_raw: Variant, rtype: String, partial: bool, idx: int) -> Dictionary:
	var prefix := "" if idx < 0 else "orders[%d]." % idx
	var action := normalize_action(str(action_raw))
	if action.is_empty() and partial:
		return {"ok": true, "action": ""}
	elif action.is_empty() and (rtype == "INFORMATION" or rtype == "ADVICE"):
		return {"ok": true, "action": ""}
	elif not action in ACTIONS:
		return {"ok": false, "why": "%saction '%s' is not a canonical action" % [prefix, str(action_raw)]}
	return {"ok": true, "action": action}


## Per-order legacy scope validation (extracted verbatim; behavior identical).
## Returns {ok, scope(normalized)}.
static func _validate_scope(scope_raw: Variant, partial: bool, idx: int) -> Dictionary:
	var prefix := "" if idx < 0 else "orders[%d]." % idx
	if not scope_raw is Dictionary:
		return {"ok": false, "why": "%sscope must be an object" % prefix}
	var scope: Dictionary = scope_raw
	var stype := str(scope.get("type", "")).strip_edges().to_upper()
	var cls := normalize_class(str(scope.get("class", "")))
	if cls.is_empty():
		cls = "CAVALRY" if not partial else ""
	var region := normalize_region(str(scope.get("region", "")))
	if region.is_empty() and partial:
		pass
	elif stype == "ALL_AVAILABLE":
		region = "ALL"
		# Shape wins: ALL_AVAILABLE IS the whole army by definition. A
		# contradictory class token (model sometimes echoes CAVALRY for
		# "전군 진격") is normalized to ALL_ARMS so the flagship
		# whole-force path never degrades into a wing question. A named
		# class WITHOUT whole-force words must never arrive here (prompt
		# routes those to WING_CLASS/region ALL instead).
		cls = "ALL_ARMS"
	elif stype == "UNION":
		region = ""
	elif not region in MACRO_REGIONS and not is_concrete_band(region):
		return {"ok": false, "why": "%sscope.region '%s' is not a known formation token" % [prefix, str(scope.get("region", ""))]}
	if stype.is_empty() and not partial:
		stype = infer_scope_type(cls, region, str(scope.get("unit_id", "")))
		if stype.is_empty():
			return {"ok": false, "why": "%sscope.type omitted and not inferable" % prefix}
	if stype.is_empty() and partial:
		stype = ""
	elif not stype in SCOPE_TYPES:
		return {"ok": false, "why": "%sscope.type '%s' not in [%s]" % [prefix, str(scope.get("type", "")), ", ".join(SCOPE_TYPES)]}
	if stype == "UNION" and cls.is_empty() and not partial:
		cls = "CAVALRY"
	if cls.is_empty() and stype == "ALL_AVAILABLE":
		cls = "ALL_ARMS"
	if not cls.is_empty() and not cls in KNOWN_CLASSES:
		return {"ok": false, "why": "%sscope.class '%s' is not a known class" % [prefix, str(scope.get("class", ""))]}
	var unit_id := str(scope.get("unit_id", "")).strip_edges().to_upper()
	# Compositional multi-class scope ("좌익 보병과 창병"): classes[] with
	# UNION (or class-wide) shapes. Single-class commands keep class.
	var classes: Array = []
	if scope.has("classes") and scope.get("classes") is Array:
		for c_val in (scope.get("classes") as Array):
			var ct := normalize_class(str(c_val))
			if ct in KNOWN_CLASSES and not ct in classes:
				classes.append(ct)
		if classes.size() > 4:
			classes = classes.slice(0, 4)
	var regions: Array = []
	if scope.has("regions") and scope.get("regions") is Array:
		for r_val in (scope.get("regions") as Array):
			var rt := normalize_region(str(r_val))
			# "ALL" inside regions[] is compositional (union over all macro
			# wings: "보병과 창병 둘 다 전진" with no wing named). It is NOT
			# the whole-force scope: classes[]/class still restricts arms.
			if rt == "ALL":
				if not rt in regions:
					regions.append(rt)
			elif rt in ["LEFT", "CENTER", "RIGHT", "EXTREME_LEFT", "EXTREME_RIGHT"] \
					or is_concrete_band(rt):
				if not rt in regions:
					regions.append(rt)
		if regions.size() > MAX_UNION_REGIONS:
			regions = regions.slice(0, MAX_UNION_REGIONS)
	# Lenient coercion (normalization, traced by caller): regions with a
	# non-UNION type become UNION; UNION without regions falls back to the
	# single region shape so the answer is never lost to a shape mismatch.
	if not regions.is_empty() and stype != "UNION":
		stype = "UNION"
	if stype == "UNION" and regions.is_empty():
		if region in ["LEFT", "CENTER", "RIGHT", "EXTREME_LEFT", "EXTREME_RIGHT"] \
				or is_concrete_band(region):
			stype = "WING_CLASS" if not is_concrete_band(region) else "CLUSTER_CLASS"
		else:
			return {"ok": false, "why": "%sUNION scope needs a non-empty regions array" % prefix}
	return {"ok": true, "scope": {"type": stype, "class": cls, "region": region,
		"unit_id": unit_id, "regions": regions, "classes": classes}}


## Per-order style validation (extracted verbatim; behavior identical).
## Missing style defaults to balanced/normal (new orders path); the legacy
## path still requires the key (checked by the caller before delegating).
static func _validate_style(style_raw: Variant, idx: int) -> Dictionary:
	var prefix := "" if idx < 0 else "orders[%d]." % idx
	if not style_raw is Dictionary:
		return {"ok": false, "why": "%sstyle must be an object" % prefix}
	var style: Dictionary = style_raw
	var risk_raw := str(style.get("risk", "balanced")).strip_edges().to_lower()
	var pressure_raw := str(style.get("pressure", "balanced")).strip_edges().to_lower()
	var depth_raw := str(style.get("depth", "normal")).strip_edges().to_lower()
	if not risk_raw in STYLE_ACCEPT:
		return {"ok": false, "why": "%sstyle.risk '%s' invalid" % [prefix, str(style.get("risk", ""))]}
	if not pressure_raw in STYLE_ACCEPT:
		return {"ok": false, "why": "%sstyle.pressure '%s' invalid" % [prefix, str(style.get("pressure", ""))]}
	if not depth_raw in DEPTH_ACCEPT:
		return {"ok": false, "why": "%sstyle.depth '%s' invalid" % [prefix, str(style.get("depth", ""))]}
	# Depth folds through DEPTH_FOLD (shallow/normal/deep), never the
	# risk/pressure table: "deep" is not a STYLE_FOLD key and crashed
	# validation into a false MALFORMED for every "깊게" order (proven).
	return {"ok": true, "style": {"risk": STYLE_FOLD[risk_raw],
		"pressure": STYLE_FOLD[pressure_raw], "depth": DEPTH_FOLD[depth_raw]}}


static func intent_fingerprint(intent: Dictionary) -> String:
	var sc: Dictionary = intent.get("scope", {})
	var st: Dictionary = intent.get("style", {})
	var ex := ""
	if intent.has("scope_expr") and (intent.get("scope_expr") as Dictionary) is Dictionary \
			and not (intent.get("scope_expr", {}) as Dictionary).is_empty():
		ex = AlgebraScript.fingerprint(intent.get("scope_expr", {}))
	return "%s|%s|%s|%s|%s|%s|%s|%s|%s" % [
		str(intent.get("request_type", "")), str(intent.get("action", "")),
		str(sc.get("type", "")), str(sc.get("class", "")),
		str(sc.get("region", "")) + "+" + ",".join(sc.get("regions", [])) + "+" + ",".join(sc.get("classes", [])),
		ex,
		str(st.get("risk", "")), str(st.get("pressure", "")),
		str(st.get("depth", ""))]


## Canonical action vocabulary with meanings (mirrors VALID_ACTIONS).
const ACTION_VOCAB := """SUPPORTED_ACTIONS (canonical; emit ONLY these action tokens):
- ADVANCE: move formations forward toward the operational front/objective.
- HOLD: maintain current position (대기).
- REPOSITION: move toward a specified tactical region (재배치/이동).
- RETREAT: pull back toward safety (후퇴). WITHDRAW: disengage from contact (철수/이탈).
- RECON: scout/observe (정찰). FLANK: attack the enemy flank/side (측면 기동/우회 공격).
- PROTECT: guard a friendly formation (보호/엄호). REGROUP: reassemble cohesion (재집결).
- SCREEN: screen ahead of the army (엄호 전개). MOVE: exact-hex move (game resolves the hex, never invent one)."""


## Scope vocabulary the model may emit. Godot owns membership.
const SCOPE_VOCAB := """SUPPORTED_SCOPES (emit ONLY these scope shapes):
- {"type": "ALL_AVAILABLE"} whole BLUE force, 전군/전부대/모두/전체. NEVER subdivide this into a wing. Region MUST be ALL and class MUST be ALL_ARMS (never a combat class, even when the order mentions one alongside a whole-force word).
- {"type": "WING_CLASS", "class": "...", "region": "LEFT|CENTER|RIGHT|EXTREME_LEFT|EXTREME_RIGHT|ALL"} one macro wing + one class. 좌익/왼쪽→LEFT, 우익/오른쪽→RIGHT, 중앙→CENTER, 극좌익→EXTREME_LEFT, 극우익→EXTREME_RIGHT. Region ALL means a class-wide order with no wing named ("기병 전진", "정찰병 정찰"): emit it as a COMMAND, never as ALL_AVAILABLE (that scope is the whole army, never one class); the game asks which wing when several hold that class.
- {"type": "CLUSTER_CLASS", "class": "...", "region": "C|L1|R2|..."} one concrete band from the layout table + one class.
- {"type": "UNIT", "region": "SELECTED"} the map-selected unit (이/그/지금 부대). Or {"type": "UNIT", "unit_id": "B_CAV_2"} ONLY when the player names an exact id.
- {"type": "UNION", "class": "...", "regions": ["LEFT", "RIGHT"]} two or more wings/bands as ONE scope. Use when the pending question offers wings and the player answers both/all of them (둘다/둘 다/양쪽/좌우 모두/모두), keeping the pending action/class. Also for fresh multi-region orders (양쪽 기병 전진). NEVER narrow a both-answer to one wing. NEVER re-ask a sufficiently answered both.
- Multi-class: {"type": "UNION", "classes": ["INFANTRY", "SPEARMAN"], "regions": ["LEFT"]} for orders like 좌익 보병과 창병 전진. classes[] composes with regions[]; single-class orders keep class. Several classes with NO wing named ("보병과 창병 둘 다 전진") = {"type": "UNION", "classes": ["INFANTRY", "SPEARMAN"], "regions": ["ALL"]} ("둘 다" here means both CLASSES across the army, and ALL means every wing — never invent a narrower wing).
- Two formations in one order ("보병으로 궁병 보호해", "창병으로 기병 접근 막아"): scope is the ACTOR only (the 으로/가 unit doing it: 보병→INFANTRY, 창병→SPEARMAN). There is NO target field — never invent one, never stall deciding: emit the actor scope at honest confidence and stop. The game answers with its capability.
- Follow/accompany language (따라와/따라가/합류해, "공성대는 안전하게 따라와"): there is NO follow mechanic and NO anchor field. Scope the ACTOR only, action ADVANCE with risk low, at honest confidence. Decide and stop — never deliberate over the missing anchor.

COMPOSITIONAL SCOPE (scope_expr, ONLY for these three patterns — otherwise use the legacy scope shapes above):
- Atoms: {"op": "ALL_FRIENDLY"} every BLUE formation, {"op": "ALL_COMBAT"} combat classes, {"op": "CLASS", "class": "..."}, {"op": "WING", "wing": "LEFT|CENTER|RIGHT|EXTREME_LEFT|EXTREME_RIGHT"}, {"op": "CLUSTER", "cluster": "C|L1|R2..."}, {"op": "UNIT", "unit_id": "B_..."} (exact id named only), {"op": "SELECTED"} (map-selected unit only).
- Operators: {"op": "UNION", "args": [...]} either-or, {"op": "INTERSECT", "args": [...]} both, {"op": "DIFF", "left": A, "right": B} A-minus-B. Nest freely.
- "정찰병 제외 전군 대기" = action HOLD + scope_expr {"op": "DIFF", "left": {"op": "ALL_FRIENDLY"}, "right": {"op": "CLASS", "class": "SCOUT"}} (legacy scope mirrors it: ALL_AVAILABLE/ALL_ARMS/ALL).
- "보병과 창병 전진" (no wing) = action ADVANCE + scope_expr {"op": "UNION", "args": [{"op": "CLASS", "class": "INFANTRY"}, {"op": "CLASS", "class": "SPEARMAN"}]}.
- "좌익 기병 전진" = action ADVANCE + scope_expr {"op": "INTERSECT", "args": [{"op": "WING", "wing": "LEFT"}, {"op": "CLASS", "class": "CAVALRY"}]}.
- Emit scope_expr ONLY for exclusion ("제외/빼고") and the two compositional patterns above. NEVER emit unit-id lists; the game resolves membership. Omit scope_expr ({}) everywhere else.
- {"type": "PREVIOUS"} the immediately preceding recommendation (follow-ups: 그렇게 해/그대로 해/실행해).
Classes: CAVALRY 기병, INFANTRY 보병, SPEARMAN 창병, ARCHER 궁병, SCOUT 정찰, SIEGE 공성, CONSCRIPT 징집, ALL_ARMS 전병과. HQ (지휘부) and SUPPLY (보급대) are also valid class tokens: emit them when the player names them (even if the layout shows none) — the game answers with their explicit capability policy. NEVER substitute whole-force for a named HQ/SUPPLY order."""


## Phase-1 system prompt: language interpretation ONLY. Per-request context
## (capabilities, layout, selected, pending, history) arrives in the user
## block; the full trace is specified there.
const INTENT_SYSTEM_PROMPT := """You are Seo Yuseon (서유선), staff advisor interpreting your commander's Korean orders in a historical strategy battle. You translate language into a constrained semantic command: ONE order per clause, as an orders[] array (one element for single orders). You command nothing, invent nothing: no unit ids, no coordinates, no bands, no actions outside SUPPORTED_ACTIONS, no scope shapes outside SUPPORTED_SCOPES.

REQUEST TYPES (mandatory distinction)
- COMMAND: imperative (진격하라, 전진시켜, 움직여, 보내, 압박해, 대기해, 실행해). Carries orders[] with one element per clause. Leads to a staged plan.
- ADVICE: questions about what is good (좋을까, 어떨까, 어때, 권해줘). Recommendation only, NEVER a plan. Legacy single shape, no orders key.
- INFORMATION: status questions (상황이 어때, 어디에 있어). Answer only. Legacy single shape, no orders key.
- CLARIFICATION: a semantic field is genuinely missing. Ask ONE concise question naming the missing field. If the player message is vague (돌다 could be flank/reposition/retreat), ask which of the named canonical actions is meant. NEVER guess a consequential field. Legacy single shape, no orders key.

MULTI-CLAUSE ORDERS (one utterance, several battlefield orders)
- Split on clauses (하고/하고도/면서면/고): "정찰병은 전진하고 나머지는 대기" is TWO orders, never one. Each clause gets its own action + scope (+ scope_expr) + style + confidence.
- "나머지" (remainder) is ALWAYS set difference from the domain THIS message contrasts against — never a bare token, never a guess: "정찰병은 전진하고 나머지는 대기" → order 2 scope_expr DIFF(ALL_FRIENDLY, CLASS(SCOUT)); "좌익 기병은 전진하고 나머지 기병은 대기" → order 2 DIFF(CLASS(CAVALRY), INTERSECT(WING(LEFT), CLASS(CAVALRY))); "궁병은 대기하고 나머지는 전진" → order 2 DIFF(ALL_FRIENDLY, CLASS(ARCHER)). The domain is the whole the first clause was carved from (전군/본대/나머지 without qualifier → ALL_FRIENDLY; 나머지 + class → that CLASS).
- Every order's scope follows the SAME honesty rules below (bare class → region ALL, whole-force words → ALL_AVAILABLE, etc.).
- Wing-vs-wing pairings split the same way ("좌익은 대기하고 우익은 전진" = HOLD order scoped to LEFT + ADVANCE order scoped to RIGHT, each with its own action).
- Inside a multi-order message, NEVER collapse to CLARIFICATION just because one clause names a wing without a class: emit the ALL_ARMS wing scope for that clause normally (the game resolves the full wing explicitly named there).
- If any clause is genuinely unclear, prefer CLARIFICATION for the whole message over guessing one clause consequentially.

SCOPE HONESTY (critical)
- 전군/전부대/모두/전체 + an advance verb = {"type": "ALL_AVAILABLE"} with region ALL. NEVER narrow whole-force language to one wing. NEVER use ALL_AVAILABLE for a NAMED class ("기병 모두 전진" is still one class, not the whole army).
- A class with NO wing or band named ("기병 전진", "정찰병 정찰", "공성대 전진") = {"type": "WING_CLASS", "class": "<named>", "region": "ALL"} as a COMMAND with honest confidence. The wing is confirmed by the game afterwards; do NOT deliberate between shapes and do NOT emit CLARIFICATION for this — region ALL is the complete answer.
- A wing or band with NO class named ("좌익 전진" with no 병과 word): for ADVANCE or RECON this is genuinely ambiguous — emit CLARIFICATION with missing ["class"] and a concise Korean question naming the wing. NEVER silently default a consequential advance to one class. For HOLD the whole wing may hold ("양쪽 대기" = UNION regions with class ALL_ARMS). For any OTHER action, scope ALL_ARMS with that action and stop (the game answers with its capability; the scope token decides nothing). Whole-force words are ALL_AVAILABLE, never this case.
- A bare region word answering your wing question ("좌익") fills the pending request (see PENDING_CLARIFICATION): keep its action/class, set only the region.
- 이/그/지금 부대 with a selected unit given = {"type": "UNIT", "region": "SELECTED"} — ALWAYS, even if the deictic noun names a class (use the selected unit's real class; Godot corrects the token). With no selected unit, that is a missing region, not a guess. A deictic_reference block names the pointed unit id: use it verbatim when the player points.
- Follow-ups ("그렇게 해", "그대로 해", "아까 말한 대로 해", "실행해") with a prior recommendation visible in history or pending = {"type": "PREVIOUS"} at honest confidence. With NO prior recommendation anywhere (empty history, no pending): do NOT deliberate over PREVIOUS — emit CLARIFICATION immediately with missing ["action"] and one short Korean question. Decisiveness outranks exhaustiveness everywhere: pick the single best-fitting shape and stop.
- Open advice questions with no formation or action named ("어떤 기동이 좋을까", "뭐가 좋을까", "추천해줘"): emit ADVICE with empty action and ALL_AVAILABLE scope at honest confidence. The game asks which behavior the advice concerns. Decide and stop.
- Name a class ONLY when the player names it (보병→INFANTRY, 창병→SPEARMAN, 궁병→ARCHER, 정찰병/정찰대→SCOUT, 공성대→SIEGE, 징집병→CONSCRIPT). For HOLD with no class named, ALL_ARMS. Otherwise CAVALRY for wing/cluster/unit scopes, ALL_ARMS for ALL_AVAILABLE.

OUTPUT CONTRACT
- Return JSON ONLY — one object, no prose, no fences.
- COMMAND schema: {"request_type": "COMMAND", "orders": [{"action": "ADVANCE", "scope": {"type": "WING_CLASS", "class": "CAVALRY", "region": "LEFT", "unit_id": "", "regions": []}, "scope_expr": {}, "style": {"risk": "balanced", "pressure": "high", "depth": "normal"}, "confidence": 0.91}], "confidence": 0.91, "question": "", "missing": []}. Single orders use orders with EXACTLY one element.
- Two-order example ("정찰병은 전진하고 나머지는 대기"): {"request_type": "COMMAND", "orders": [{"action": "ADVANCE", "scope": {"type": "WING_CLASS", "class": "SCOUT", "region": "ALL", "unit_id": "", "regions": []}, "scope_expr": {}, "style": {"risk": "balanced", "pressure": "balanced", "depth": "normal"}, "confidence": 0.9}, {"action": "HOLD", "scope": {"type": "ALL_AVAILABLE", "class": "ALL_ARMS", "region": "ALL", "unit_id": "", "regions": []}, "scope_expr": {"op": "DIFF", "left": {"op": "ALL_FRIENDLY"}, "right": {"op": "CLASS", "class": "SCOUT"}}, "style": {"risk": "balanced", "pressure": "balanced", "depth": "normal"}, "confidence": 0.9}], "confidence": 0.9, "question": "", "missing": []}
- Legacy single shape (top-level action/scope/style/confidence, no orders key) is still read as one order; prefer orders[] for every COMMAND.
- Bare-class example ("정찰병 정찰"): {"request_type": "COMMAND", "action": "RECON", "scope": {"type": "WING_CLASS", "class": "SCOUT", "region": "ALL", "unit_id": "", "regions": []}, "style": {"risk": "balanced", "pressure": "balanced", "depth": "normal"}, "confidence": 0.9, "question": "", "missing": []}
- Multi-class example ("보병과 창병 둘 다 전진"): {"request_type": "COMMAND", "action": "ADVANCE", "scope": {"type": "UNION", "class": "", "region": "", "unit_id": "", "regions": ["ALL"], "classes": ["INFANTRY", "SPEARMAN"]}, "style": {"risk": "balanced", "pressure": "balanced", "depth": "normal"}, "confidence": 0.9, "question": "", "missing": []}
- With a compositional pattern, add "scope_expr": {...} NEXT TO "scope" (scope still mirrors the closest legacy shape: exclusion orders mirror ALL_AVAILABLE/ALL_ARMS/ALL). Omit scope_expr ({}) for every other order.
- Both-answer example: {"request_type": "COMMAND", "action": "ADVANCE", "scope": {"type": "UNION", "class": "CAVALRY", "region": "", "unit_id": "", "regions": ["LEFT", "RIGHT"]}, "style": {"risk": "balanced", "pressure": "balanced", "depth": "normal"}, "confidence": 0.9, "question": "", "missing": []}
- For CLARIFICATION with a truly unknown field, leave it "" and list it in missing (action|class|region), with a concise Korean question.
- Style is preference only (신중→risk low, 공격적/밀어→pressure high, 깊게/멀리→depth deep, 조금→depth shallow; middle values may be written balanced or normal). NEVER emit realization names (SAFE/SUPPORTED/...): that stage never sees this output.
- confidence is certainty about type+action+scope. Below ~0.45 prefer CLARIFICATION.
- SEMANTIC ENVELOPE (CommandIR v2, optional — omission stays valid, game defaults apply):
  - Multi-order relation: for 2+ orders include "relation": "PARALLEL" (independent, simultaneous: 좌익 대기 + 우익 전진) or "SEQUENCE" (order matters: 먼저 전진하고 그다음 대기). Single orders omit it (game uses SINGLE). NEVER use SINGLE with 2+ orders.
  - Per order, include "source_evidence": ["exact verbatim quote from the player message for THIS clause"] (e.g. "정찰병은 깊게 정찰하고" and "나머지는 대기"). Copy substrings exactly — no paraphrase, no offsets. The game binds them deterministically to detect dropped clauses.
  - Per order, you MAY include "modifiers": {"pace": "slow|fast", "extent": "partial|maximal", "formation": "keep"} for nuances the style triple cannot carry (천천히→pace slow, 조금만→extent partial, 전열을 유지하며→formation keep). Style stays for doctrine; modifiers preserve intent verbatim."""


const INTENT_REPAIR_TEMPLATE := """Your previous response was invalid: %s. COMMAND uses orders[] (one element per clause): {"request_type": "COMMAND", "orders": [{"action": "ADVANCE", "scope": {"type": "WING_CLASS", "class": "CAVALRY", "region": "LEFT", "unit_id": ""}, "scope_expr": {}, "style": {"risk": "balanced", "pressure": "balanced", "depth": "normal"}, "confidence": 0.8}], "confidence": 0.8, "question": "", "missing": []}. Valid actions are [ADVANCE, MOVE, HOLD, RETREAT, RECON, FLANK, REPOSITION, WITHDRAW, REGROUP, PROTECT, SCREEN]; scope types [ALL_AVAILABLE, WING_CLASS, CLUSTER_CLASS, UNIT, PREVIOUS]; style risk/pressure in [low, balanced, high] (or normal), depth in [shallow, normal, deep]. Return valid JSON only, exactly matching the schema."""


## Phase-2 system prompt: tactical SELECTION over supplied legal packages.
## The player's intent OUTRANKS generic caution: realize WHAT was asked
## using the live evidence. Style words are preference, never direct
## profile ids: compare actual options, adapt honestly when the closest
## realization differs, and say so in Korean.
const SELECT_SYSTEM_PROMPT := """You are Seo Yuseon (서유선), staff advisor choosing HOW to realize your commander's intent. A deterministic evaluator generated every legal realization; each AVAILABLE or DEGRADED option is legal to stage, UNAVAILABLE options are not. You invent nothing: no units, no destinations, no coordinates, no paths. Your choice is staged for the commander's [실행] approval — nothing moves on your answer.

JUDGMENT
- The commander's intent is supreme: an order to press hard must prefer high-pressure realizations when legal; an order for care must prefer low-risk ones. Never silently substitute SAFE for an aggressive order (or vice versa) without cause.
- Cause to deviate is EVIDENCE in the supplied packages: isolation that would ruin the asked pressure, retreat geometry that makes depth suicidal, a DEGRADED limitation that defeats the purpose. Then choose the closest legal realization and explain the tradeoff plainly.
- No scores are shown, by design: compare options by their strengths/concerns and risk evidence (support, pressure, mobility, retreat, intent progress, plus information for scouts, screen for archers/siege, denial for spearmen). Deliberate briefly (a few sentences per unit), decide, and stop — exhaustive re-comparison changes nothing.
- Each option carries qualitative risk evidence in its class doctrine vocabulary (support, pressure, mobility, retreat, intent progress, plus information for scouts, screen for archers/siege, denial for spearmen) with its availability and limitation. Weigh them as class-aware evidence: the same geometry ranks differently per class by design.
- Reason MUST use game terms (wing, support, retreat, pressure, information, screen, denial, contact). NEVER quote numeric scores. NEVER write profile ids (SAFE/SUPPORTED/BALANCED/PRESSURE/DEEP/MAXIMUM) in player-facing text: name formations and places instead.
- Fog of war: only listed contacts exist. Stale last-known contacts may have moved. Never assert enemy facts beyond the snapshot. Name units ONLY with supplied ids; anything else is generic 아군/적 부대.

OUTPUT CONTRACT
- Return JSON ONLY — one object, no prose, no fences.
- Schema: {"selections": [{"unit_id": "B_CAV_2", "selected_option_id": "PRESSURE"}], "reason": "...", "confidence": 0.85}
- selections MUST cover every supplied unit_id exactly once; selected_option_id MUST be an AVAILABLE or DEGRADED option of THAT unit's package.
- reason is natural Korean under 400 characters: who advances where and the key tradeoff, in wing/support/retreat/pressure words. No internal profile-name jargon."""


const SELECT_REPAIR_TEMPLATE := """Your previous response was invalid: %s. Valid unit ids are [%s]; each unit's legal option ids are listed in its package (AVAILABLE or DEGRADED only). Return valid JSON only with selections covering every supplied unit exactly once."""


## Defensive single-JSON-object extraction (no natural-language parser).
static func extract_json(text: String) -> Dictionary:
	var t := text.strip_edges()
	if t.begins_with("```"):
		var nl := t.find("\n")
		t = t.substr(nl + 1) if nl >= 0 else ""
		var fence := t.rfind("```")
		if fence >= 0:
			t = t.substr(0, fence)
		t = t.strip_edges()
	var parsed: Variant = JSON.parse_string(t)
	if parsed is Dictionary:
		return parsed
	var start := t.find("{")
	var stop := t.rfind("}")
	if start >= 0 and stop > start:
		var inner: Variant = JSON.parse_string(t.substr(start, stop - start + 1))
		if inner is Dictionary:
			return inner
	return {}
