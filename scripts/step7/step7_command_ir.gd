class_name Step7CommandIR
extends RefCounted

## CommandIR v2 — canonical semantic IR for player battlefield language.
##
## STEP 1 ONLY: strict separation between WHAT THE PLAYER MEANT (this file)
## and WHETHER IT IS VALID/EXECUTABLE (Step 2 Semantic Gate, deferred) and
## HOW TO REALIZE IT TACTICALLY (Phase-2 selection, untouched).
##
## Pipeline after Step 1:
##   PLAYER TEXT -> existing semantic model/parser -> raw semantic result
##   -> CommandIR v2 normalization + validation -> canonical CommandIR
##   -> EXISTING routing / scope / staging / execution (unchanged).
##
## Design invariants (deterministic, tested):
##   1. version == 2 always. kind in COMMAND|ADVICE|INFORMATION|CLARIFICATION.
##   2. Canonical truth is orders[] (never top-level action/scope mirrors).
##      Compatibility mirrors are kept under ir["legacy"] for legacy
##      consumers only and are explicitly NON-canonical.
##   3. SINGLE ⟺ orders.size() == 1. Multi-order is PARALLEL or SEQUENCE.
##      Empty explicit relation infers: len==1 -> SINGLE; len>1 -> SEQUENCE
##      when sequence cues occur in the original text, else PARALLEL.
##      Explicit mismatches (SINGLE with 2 orders, PARALLEL with 1) are
##      INVALID — never silently coerced.
##   4. scope_expr reuses the proven Scope Algebra ONLY. No unit-id LISTS
##      (plural key) are ever allowed inside scope_expr; explicit UNIT(id)
##      (singular) remains valid. Godot resolves membership; the LLM never
##      owns it. Legacy scopes without scope_expr compile via
##      compile_legacy() for fingerprinting (effective expression).
##   5. Modifiers preserve semantic intent separately from tactical
##      realization. Style {risk,pressure,depth} stays doctrine-compatible;
##      modifiers{} carries the same semantics PLUS pace/extent/formation
##      and raw phrases. Fingerprint covers both.
##   6. Source evidence binds DETERMINISTICALLY Godot-side: the model may
##      emit exact source quote(s) per order; Godot matches them as exact
##      substrings of the ORIGINAL utterance and computes covered /
##      uncovered ranges, per-order ownership, unbound quotes, and
##      semantic-bearing tokens left uncovered. Model offsets or bare
##      "coverage:true" are NEVER trusted. Missing evidence is reported as
##      MISSING (Step 2 will own the STOP policy; Step 1 only reports).
##   7. Fingerprint covers semantic meaning ONLY (kind, relation, ordered
##      orders, actions, effective scope fingerprints, style+modifiers).
##      Display prose and evidence identity are excluded; evidence has its
##      own fingerprint. Equivalent legacy/new shapes share the same fp.
##   8. Serialization round-trip (construct -> normalize -> serialize ->
##      deserialize -> normalize) is semantic-preserving: fingerprints
##      are recomputed deterministically and must match.
##
## Competing semantic truths AUDIT (debug question, Step 1 findings):
##   BEFORE this file the pipeline carried several parallel truths:
##     (a) validated intent top-level action/scope/style/confidence
##         (mirror of orders[0], kept for single-order consumers);
##     (b) validated intent orders[] (multi-order composite source);
##     (c) commander rec["orders"] (via _orders_of, re-normalized copy);
##     (d) rec["intent"] (full validated dict incl. mirrors);
##     (e) _pending {action,scope_type,class,region,unit_id,missing};
##     (f) _staged {intent,orders,items,command} (frozen for approval);
##     (g) _last_advice {profiles,unit_ids} (PREVIOUS pointer target).
##   AFTER Step 1 the canonical semantic authority for (a)-(d) is this
##   CommandIR (orders[] + relation + evidence + coverage + fingerprint).
##   Mirrors under ir["legacy"] exist ONLY for compatibility and are
##   documented non-canonical. Pending/staged/advice records are
##   conversation/execution state (Steps 3/5 scope) and intentionally keep
##   working unchanged; staged plans now ALSO carry command_ir_fp for
##   traceability without changing routing.

const IntentScript = preload("res://scripts/step7/step7_chat_intent.gd")
const AlgebraScript = preload("res://scripts/step7/step7_scope_algebra.gd")

const VERSION := 2
const KINDS := ["COMMAND", "ADVICE", "INFORMATION", "CLARIFICATION"]
const RELATIONS := ["SINGLE", "PARALLEL", "SEQUENCE"]
const MAX_ORDERS := 4
const MAX_EVIDENCE_PER_ORDER := 4
const MAX_EVIDENCE_CHARS := 600
const MAX_MODIFIER_KEYS := 12
const MAX_MODIFIER_VAL_CHARS := 64

## Relation cues (diagnostic/inference ONLY, not execution hacks).
## SEQUENCE is inferred for multi-order messages containing one of these
## verbatim substrings; everything else multi-order defaults to PARALLEL.
## Single-order messages are ALWAYS SINGLE regardless of cues.
const SEQUENCE_CUES := ["먼저", "그다음", "그 다음", "이어서", "순서대로", "차례로"]

## Diagnostic-only semantic-bearing cue sets for uncovered-span analysis.
## These NEVER drive routing; they only let Step 2 ask "is meaningful text
## uncovered?". Sourced from existing alias tables + a small documented
## remainder/exclusion/modifier cue list.
const REMAINDER_CUES := ["나머지", "본대"]
const EXCLUSION_CUES := ["제외", "빼고"]
const MODIFIER_CUES := ["깊게", "안전하게", "조금만", "최대한", "천천히", "빠르게", "전열"]
const PARALLEL_CUES := ["동시에", "함께"]


# --- Small helpers -----------------------------------------------------------

static func _fail(why: String) -> Dictionary:
	return {"ok": false, "why": why}


static func _valid_order_id_format(oid: String) -> bool:
	var t := oid.strip_edges()
	if t.is_empty() or t.length() > 16:
		return false
	var re := RegEx.new()
	re.compile("^[A-Za-z0-9_-]+$")
	return re.search(t) != null


static func _contains_key(node: Variant, key: String) -> bool:
	if node is Dictionary:
		var d: Dictionary = node
		if d.has(key):
			return true
		for k in d.keys():
			if _contains_key(d[k], key):
				return true
	elif node is Array:
		for v in (node as Array):
			if _contains_key(v, key):
				return true
	return false


# --- Modifiers ---------------------------------------------------------------
## Semantic modifiers: style-derived risk/pressure/depth PLUS explicit
## semantic extras (pace/extent/formation/...) preserved verbatim.
## Existing style fields are reused (never redefined); extras are extensible.

static func normalize_modifiers(style: Dictionary, raw_mod: Variant) -> Dictionary:
	var out := {}
	var risk := str(style.get("risk", "balanced")).strip_edges().to_lower()
	var pressure := str(style.get("pressure", "balanced")).strip_edges().to_lower()
	var depth := str(style.get("depth", "normal")).strip_edges().to_lower()
	if risk.is_empty():
		risk = "balanced"
	if pressure.is_empty():
		pressure = "balanced"
	if depth.is_empty():
		depth = "normal"
	out["risk"] = risk
	out["pressure"] = pressure
	out["depth"] = depth
	if raw_mod is Dictionary:
		var count := 0
		var keys: Array = (raw_mod as Dictionary).keys()
		keys.sort()
		for k in keys:
			var ks := str(k).strip_edges()
			if ks.is_empty() or ks in ["risk", "pressure", "depth"]:
				continue
			if count >= MAX_MODIFIER_KEYS:
				break
			var v: Variant = (raw_mod as Dictionary)[k]
			if v is String:
				out[ks] = str(v).strip_edges().left(MAX_MODIFIER_VAL_CHARS)
				count += 1
			elif v is Array:
				var arr: Array = []
				for e in (v as Array):
					arr.append(str(e).strip_edges().left(MAX_MODIFIER_VAL_CHARS))
					if arr.size() >= 8:
						break
				out[ks] = arr
				count += 1
			elif v is float or v is int or v is bool:
				out[ks] = str(v).left(MAX_MODIFIER_VAL_CHARS)
				count += 1
	return out


static func modifiers_fingerprint(m: Dictionary) -> String:
	var keys: Array = m.keys()
	keys.sort()
	var parts: Array = []
	for k in keys:
		var v: Variant = m[k]
		if v is Array:
			parts.append("%s=[%s]" % [str(k), ",".join(v)])
		else:
			parts.append("%s=%s" % [str(k), str(v)])
	return ",".join(parts)


# --- Scope -------------------------------------------------------------------

static func effective_scope_expr(order: Dictionary) -> Dictionary:
	var ex: Variant = order.get("scope_expr", {})
	if ex is Dictionary and not (ex as Dictionary).is_empty():
		return (ex as Dictionary).duplicate(true)
	var sc: Variant = order.get("scope", {})
	if sc is Dictionary and not (sc as Dictionary).is_empty():
		var leg: Dictionary = AlgebraScript.compile_legacy(sc)
		if bool(leg.get("ok", false)):
			return (leg.get("expr", {}) as Dictionary).duplicate(true)
	return {}


static func scope_fingerprint(order: Dictionary) -> String:
	var eff := effective_scope_expr(order)
	if eff.is_empty():
		var sc: Dictionary = order.get("scope", {})
		return "LEGACY:%s/%s/%s/%s/%s" % [
			str(sc.get("type", "")), str(sc.get("class", "")),
			str(sc.get("region", "")), ",".join(sc.get("regions", [])),
			",".join(sc.get("classes", []))]
	return AlgebraScript.fingerprint(eff)


static func style_fingerprint(style: Dictionary) -> String:
	return "%s/%s/%s" % [
		str(style.get("risk", "")), str(style.get("pressure", "")),
		str(style.get("depth", ""))]


static func order_fingerprint(order: Dictionary) -> String:
	var style: Dictionary = order.get("style", {})
	return "%s|%s|%s|%s" % [
		str(order.get("action", "")),
		scope_fingerprint(order),
		style_fingerprint(style),
		modifiers_fingerprint(order.get("modifiers", {}))]


static func compute_fingerprint(kind: String, relation: String, orders: Array) -> String:
	var parts: Array = []
	for o in orders:
		if o is Dictionary:
			parts.append(order_fingerprint(o))
	return "CIRv2:%s:%s:[%s]" % [kind, relation, ";".join(parts)]


static func compute_evidence_fingerprint(orders: Array, coverage: Dictionary) -> String:
	var parts: Array = []
	for o in orders:
		if not o is Dictionary:
			continue
		var ev: Array = (o as Dictionary).get("source_evidence", [])
		var qparts: Array = []
		for q in ev:
			qparts.append(str(q))
		qparts.sort()
		parts.append("%s={%s}" % [str((o as Dictionary).get("order_id", "?")), "|".join(qparts)])
	var bound: Array = []
	for r in (coverage.get("covered", []) as Array):
		bound.append("%d-%d:%s" % [int((r as Dictionary).get("start", 0)),
			int((r as Dictionary).get("end", 0)), str((r as Dictionary).get("order_id", "?"))])
	bound.sort()
	return "CIRev:[%s]/[%s]" % [";".join(parts), ";".join(bound)]


# --- Relation ----------------------------------------------------------------

static func infer_relation(original_text: String, explicit: String, order_count: int) -> Dictionary:
	var ex := explicit.strip_edges().to_upper()
	if not ex.is_empty() and not ex in RELATIONS:
		return {"ok": false, "why": "relation '%s' not in [%s]" % [explicit, ", ".join(RELATIONS)]}
	if order_count == 1:
		if ex.is_empty():
			return {"ok": true, "relation": "SINGLE", "source": "DEFAULT_SINGLE"}
		if ex == "SINGLE":
			return {"ok": true, "relation": "SINGLE", "source": "EXPLICIT"}
		return {"ok": false, "why": "relation '%s' conflicts with single order (must be SINGLE)" % ex}
	if order_count > 1:
		if ex == "PARALLEL" or ex == "SEQUENCE":
			return {"ok": true, "relation": ex, "source": "EXPLICIT"}
		if not ex.is_empty():
			return {"ok": false, "why": "relation '%s' conflicts with %d orders (must be PARALLEL or SEQUENCE)" % [ex, order_count]}
		for cue in SEQUENCE_CUES:
			if original_text.find(cue) >= 0:
				return {"ok": true, "relation": "SEQUENCE", "source": "INFERRED"}
		return {"ok": true, "relation": "PARALLEL", "source": "INFERRED"}
	return {"ok": false, "why": "COMMAND requires at least one order"}


# --- Evidence ----------------------------------------------------------------

static func normalize_evidence(raw: Variant) -> Array:
	var out: Array = []
	var src: Array = []
	if raw is String:
		var t := (raw as String).strip_edges()
		if not t.is_empty():
			src = [t]
	elif raw is Array:
		src = (raw as Array).duplicate()
	for q_val in src:
		var q := str(q_val).strip_edges()
		if q.is_empty():
			continue
		if q.length() > MAX_EVIDENCE_CHARS:
			q = q.left(MAX_EVIDENCE_CHARS)
		if not q in out:
			out.append(q)
		if out.size() >= MAX_EVIDENCE_PER_ORDER:
			break
	return out


static func _vocab_tokens() -> Array:
	var toks: Array = []
	for k in (IntentScript.ACTION_ALIASES as Dictionary).keys():
		toks.append(str(k))
	for k2 in (IntentScript.CLASS_ALIASES as Dictionary).keys():
		toks.append(str(k2))
	for k3 in (IntentScript.REGION_ALIASES as Dictionary).keys():
		var s := str(k3)
		if s.length() >= 2:
			toks.append(s)
	for w in (IntentScript.WHOLE_FORCE_WORDS as Array):
		toks.append(str(w))
	for c in REMAINDER_CUES + EXCLUSION_CUES + MODIFIER_CUES + PARALLEL_CUES + SEQUENCE_CUES:
		if not str(c) in toks:
			toks.append(str(c))
	for a in (IntentScript.ACTIONS as Array):
		toks.append(str(a))
	var uniq := {}
	var out: Array = []
	for t in toks:
		var s2 := str(t).strip_edges()
		if s2.length() >= 2 and not uniq.has(s2):
			uniq[s2] = true
			out.append(s2)
	out.sort()
	return out


static func _pos_in_ranges(pos: int, length: int, ranges: Array) -> bool:
	for r in ranges:
		if not r is Dictionary:
			continue
		var s := int((r as Dictionary).get("start", 0))
		var e := int((r as Dictionary).get("end", 0))
		if pos < e and (pos + length) > s:
			return true
	return false


static func bind_coverage(original_text: String, orders: Array) -> Dictionary:
	var text := original_text
	var total := text.length()
	var covered: Array = []
	var unbound: Array = []
	var per_order := {}
	var status := {}
	for o in orders:
		if not o is Dictionary:
			continue
		var oid := str((o as Dictionary).get("order_id", "?"))
		per_order[oid] = []
		var ev: Array = (o as Dictionary).get("source_evidence", [])
		if ev.is_empty():
			status[oid] = "MISSING"
			continue
		var bound_count := 0
		for q_val in ev:
			var q := str(q_val)
			if q.strip_edges().is_empty():
				continue
			var hits := 0
			var from := 0
			var found_any := false
			while from <= total - q.length() and hits < 16:
				var pos := text.find(q, from)
				if pos < 0:
					break
				found_any = true
				hits += 1
				var row := {"start": pos, "end": pos + q.length(),
					"order_id": oid, "quote": q}
				covered.append(row)
				(per_order[oid] as Array).append({"start": pos, "end": pos + q.length()})
				from = pos + 1
			if found_any:
				bound_count += 1
			else:
				unbound.append({"order_id": oid, "quote": q, "reason": "QUOTE_NOT_FOUND"})
		if (ev as Array).is_empty():
			status[oid] = "MISSING"
		elif bound_count == (ev as Array).size():
			status[oid] = "BOUND"
		elif bound_count > 0:
			status[oid] = "PARTIAL"
		else:
			status[oid] = "UNBOUND"
	covered.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if int(a.get("start", 0)) != int(b.get("start", 0)):
			return int(a.get("start", 0)) < int(b.get("start", 0))
		return int(a.get("end", 0)) < int(b.get("end", 0)))
	# Merge union for ratio + uncovered complement.
	var merged: Array = []
	for r in covered:
		var s := int((r as Dictionary).get("start", 0))
		var e := int((r as Dictionary).get("end", 0))
		if merged.is_empty():
			merged.append({"start": s, "end": e})
		else:
			var last: Dictionary = merged[merged.size() - 1]
			if s <= int(last.get("end", 0)):
				last["end"] = maxi(int(last.get("end", 0)), e)
			else:
				merged.append({"start": s, "end": e})
	var covered_len := 0
	for m in merged:
		covered_len += int((m as Dictionary).get("end", 0)) - int((m as Dictionary).get("start", 0))
	var uncovered: Array = []
	var cursor := 0
	for m2 in merged:
		var ms := int((m2 as Dictionary).get("start", 0))
		if ms > cursor:
			uncovered.append({"start": cursor, "end": ms,
				"text": text.substr(cursor, ms - cursor)})
		cursor = maxi(cursor, int((m2 as Dictionary).get("end", 0)))
	if cursor < total:
		uncovered.append({"start": cursor, "end": total,
			"text": text.substr(cursor, total - cursor)})
	var ratio := 1.0
	if total > 0:
		ratio = float(covered_len) / float(total)
	# Semantic-bearing tokens left uncovered (diagnostic only).
	var sem: Array = []
	var seen_sem := {}
	for tok in _vocab_tokens():
		var f := 0
		var guard := 0
		while guard < 32:
			guard += 1
			var p := text.find(tok, f)
			if p < 0:
				break
			if not _pos_in_ranges(p, tok.length(), merged):
				var key := "%s@%d" % [tok, p]
				if not seen_sem.has(key):
					seen_sem[key] = true
					sem.append({"token": tok, "start": p, "end": p + tok.length()})
			f = p + 1
	sem.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.get("start", 0)) < int(b.get("start", 0)))
	return {"covered": covered, "merged": merged, "uncovered": uncovered,
		"per_order": per_order, "unbound": unbound,
		"evidence_status": status,
		"missing_evidence": status.keys().filter(func(k: String) -> bool: return str(status[k]) == "MISSING"),
		"covered_chars": covered_len, "total_chars": total,
		"coverage_ratio": ratio,
		"semantic_uncovered": sem}


# --- Canonical constructor ---------------------------------------------------
## ONE canonical normalizer. Every player command funnels through here.
## Input: a VALIDATED intent (Step7ChatIntent.validate_intent output) plus
## the ORIGINAL player utterance (authoritative for coverage).
## Raw model outputs should go through from_raw_model_output() which chains
## validate_intent -> this function, so there is still exactly one
## semantic-normalization site.

static func from_validated_intent(intent: Dictionary, original_text: String, opts: Dictionary = {}) -> Dictionary:
	if not intent is Dictionary:
		return _fail("intent must be an object")
	var kind := str(intent.get("request_type", "")).strip_edges().to_upper()
	if kind.is_empty():
		return _fail("missing request_type")
	if not kind in KINDS:
		return _fail("request_type '%s' not in [%s]" % [str(intent.get("request_type", "")), ", ".join(KINDS)])
	var raw_orders: Variant = intent.get("orders", [])
	if not raw_orders is Array:
		return _fail("orders must be an array")
	var order_list: Array = raw_orders
	if kind == "COMMAND" and order_list.is_empty():
		return _fail("COMMAND requires non-empty orders[]")
	if order_list.size() > MAX_ORDERS:
		return _fail("too many orders (max %d)" % MAX_ORDERS)
	var orders: Array = []
	var seen_ids := {}
	for i in range(order_list.size()):
		var o_val: Variant = order_list[i]
		if not o_val is Dictionary:
			return _fail("orders[%d] must be an object" % i)
		var o: Dictionary = o_val
		# order_id: deterministic o1..oN when absent; strict uniqueness.
		var raw_id := str(o.get("order_id", "")).strip_edges()
		var oid := raw_id
		if oid.is_empty():
			oid = "o%d" % (i + 1)
		if not _valid_order_id_format(oid):
			return _fail("orders[%d].order_id '%s' invalid" % [i, raw_id])
		if seen_ids.has(oid):
			return _fail("duplicate order_id '%s'" % oid)
		seen_ids[oid] = true
		# action
		var action := IntentScript.normalize_action(str(o.get("action", "")))
		if kind == "COMMAND":
			if action.is_empty():
				return _fail("orders[%d].action missing for COMMAND" % i)
			if not action in (IntentScript.ACTIONS as Array):
				return _fail("orders[%d].action '%s' is not a canonical action" % [i, str(o.get("action", ""))])
		elif not action.is_empty() and not action in (IntentScript.ACTIONS as Array):
			return _fail("orders[%d].action '%s' is not a canonical action" % [i, str(o.get("action", ""))])
		# scope (legacy mirror, preserved for compat)
		var scope: Dictionary = {}
		if o.get("scope", {}) is Dictionary:
			scope = (o.get("scope", {}) as Dictionary).duplicate(true)
		# scope_expr (canonical set language; validated, normalized)
		var scope_expr: Dictionary = {}
		if o.get("scope_expr", {}) is Dictionary:
			scope_expr = (o.get("scope_expr", {}) as Dictionary).duplicate(true)
		if not scope_expr.is_empty():
			var se: Dictionary = AlgebraScript.validate_expr(scope_expr)
			if not bool(se.get("ok", false)):
				return _fail("orders[%d].scope_expr: %s" % [i, str(se.get("why", "?"))])
			if _contains_key(scope_expr, "unit_ids"):
				return _fail("orders[%d].scope_expr must not carry resolved unit-id lists" % i)
			scope_expr = AlgebraScript.normalize(scope_expr)
		# style (doctrine-compatible mirror)
		var style_raw: Variant = o.get("style", {"risk": "balanced", "pressure": "balanced", "depth": "normal"})
		if not style_raw is Dictionary:
			return _fail("orders[%d].style must be an object" % i)
		var style: Dictionary = (style_raw as Dictionary).duplicate(true)
		for sk in ["risk", "pressure", "depth"]:
			if not style.has(sk):
				style[sk] = "balanced" if sk != "depth" else "normal"
		var risk_s := str(style.get("risk", "balanced")).strip_edges().to_lower()
		var press_s := str(style.get("pressure", "balanced")).strip_edges().to_lower()
		var depth_s := str(style.get("depth", "normal")).strip_edges().to_lower()
		if not risk_s in (IntentScript.STYLE_FOLD as Dictionary).keys() and not risk_s in (IntentScript.STYLE_LEVELS as Array):
			if not risk_s in ["low", "balanced", "high"]:
				return _fail("orders[%d].style.risk '%s' invalid" % [i, str(style.get("risk", ""))])
		if not press_s in ["low", "balanced", "high", "normal", "medium", "moderate"]:
			return _fail("orders[%d].style.pressure '%s' invalid" % [i, str(style.get("pressure", ""))])
		if not depth_s in ["shallow", "normal", "deep", "medium", "moderate"]:
			return _fail("orders[%d].style.depth '%s' invalid" % [i, str(style.get("depth", ""))])
		style["risk"] = str((IntentScript.STYLE_FOLD as Dictionary).get(risk_s, risk_s))
		style["pressure"] = str((IntentScript.STYLE_FOLD as Dictionary).get(press_s, press_s))
		style["depth"] = str((IntentScript.DEPTH_FOLD as Dictionary).get(depth_s, depth_s))
		# modifiers (semantic preservation; style-derived + explicit extras)
		var modifiers := normalize_modifiers(style, o.get("modifiers", {}))
		# source evidence (exact quotes; Godot binds deterministically)
		var ev_raw: Variant = o.get("source_evidence", o.get("evidence", []))
		var evidence := normalize_evidence(ev_raw)
		# confidence
		var conf := 1.0
		if o.has("confidence"):
			conf = float(o.get("confidence", -1.0))
			if conf < 0.0 or conf > 1.0:
				return _fail("orders[%d].confidence outside 0.0-1.0" % i)
		orders.append({"order_id": oid, "action": action, "scope": scope,
			"scope_expr": scope_expr, "modifiers": modifiers, "style": style,
			"source_evidence": evidence, "confidence": conf})
	# relation
	var explicit := str(intent.get("relation", "")).strip_edges().to_upper()
	if opts.has("relation"):
		explicit = str(opts.get("relation", "")).strip_edges().to_upper()
	var rel: Dictionary = infer_relation(original_text, explicit, orders.size())
	if not bool(rel.get("ok", false)):
		# Non-COMMAND envelopes with zero orders have no relation to infer;
		# canonicalize them as SINGLE with zero orders (non-executable).
		if orders.is_empty() and kind != "COMMAND":
			rel = {"ok": true, "relation": "SINGLE", "source": "DEFAULT_SINGLE"}
		else:
			return _fail(str(rel.get("why", "bad relation")))
	var relation := str(rel.get("relation", "SINGLE"))
	var rel_source := str(rel.get("source", "INFERRED"))
	var coverage := bind_coverage(original_text, orders)
	var fp := compute_fingerprint(kind, relation, orders)
	var evfp := compute_evidence_fingerprint(orders, coverage)
	var question := str(intent.get("question", ""))
	var missing: Array = []
	if intent.get("missing", []) is Array:
		for m in (intent.get("missing", []) as Array):
			var mt := str(m).strip_edges().to_lower()
			if mt in ["action", "class", "region", "scope"] and not mt in missing:
				missing.append(mt)
	var msg_conf := 1.0
	if intent.has("order_confidence"):
		msg_conf = float(intent.get("order_confidence", 1.0))
	elif intent.has("confidence"):
		msg_conf = float(intent.get("confidence", 1.0))
	var legacy := {}
	if not orders.is_empty():
		var f0: Dictionary = orders[0]
		legacy = {"action": str(f0.get("action", "")),
			"scope": (f0.get("scope", {}) as Dictionary).duplicate(true),
			"scope_expr": (f0.get("scope_expr", {}) as Dictionary).duplicate(true),
			"style": (f0.get("style", {}) as Dictionary).duplicate(true)}
	var ir := {"version": VERSION, "kind": kind, "relation": relation,
		"relation_source": rel_source, "orders": orders,
		"original_text": original_text, "coverage": coverage,
		"fingerprint": fp, "evidence_fingerprint": evfp,
		"question": question, "missing": missing, "confidence": msg_conf,
		"legacy": legacy}
	var v := validate_ir(ir)
	if not bool(v.get("ok", false)):
		return _fail(str(v.get("why", "invalid IR")))
	return {"ok": true, "ir": ir}


## Convenience chain: raw model output -> validate -> canonical IR.
## Keeps ONE normalization site (from_validated_intent above).
static func from_raw_model_output(raw: Dictionary, original_text: String, opts: Dictionary = {}) -> Dictionary:
	var checked: Dictionary = IntentScript.validate_intent(raw)
	if not bool(checked.get("ok", false)):
		return _fail("raw invalid: %s" % str(checked.get("why", "?")))
	return from_validated_intent(checked.get("intent", {}), original_text, opts)


## Legacy single-command chain: top-level action/scope/style form.
static func from_legacy_command(action: String, scope: Dictionary, style: Dictionary,
		original_text: String, confidence: float = 0.9) -> Dictionary:
	var raw := {"request_type": "COMMAND", "action": action, "scope": scope,
		"style": style, "confidence": confidence, "question": "", "missing": []}
	return from_raw_model_output(raw, original_text)


# --- Validation --------------------------------------------------------------

static func validate_ir(ir: Dictionary) -> Dictionary:
	if not ir is Dictionary:
		return _fail("IR must be an object")
	if int(ir.get("version", -1)) != VERSION:
		return _fail("IR version must be %d (got %s)" % [VERSION, str(ir.get("version", "?"))])
	var kind := str(ir.get("kind", "")).strip_edges().to_upper()
	if not kind in KINDS:
		return _fail("IR kind '%s' not in [%s]" % [str(ir.get("kind", "")), ", ".join(KINDS)])
	var relation := str(ir.get("relation", "")).strip_edges().to_upper()
	if not relation in RELATIONS:
		return _fail("IR relation '%s' not in [%s]" % [str(ir.get("relation", "")), ", ".join(RELATIONS)])
	var orders: Variant = ir.get("orders", [])
	if not orders is Array:
		return _fail("IR orders must be an array")
	if kind == "COMMAND" and (orders as Array).is_empty():
		return _fail("COMMAND IR requires non-empty orders[]")
	if (orders as Array).size() > MAX_ORDERS:
		return _fail("too many orders (max %d)" % MAX_ORDERS)
	if (orders as Array).size() == 1 and relation != "SINGLE":
		return _fail("single-order IR must be SINGLE (got %s)" % relation)
	if (orders as Array).size() > 1 and relation == "SINGLE":
		return _fail("multi-order IR must be PARALLEL or SEQUENCE (got SINGLE)")
	var seen := {}
	for i in range((orders as Array).size()):
		var o_val: Variant = (orders as Array)[i]
		if not o_val is Dictionary:
			return _fail("orders[%d] must be an object" % i)
		var o: Dictionary = o_val
		var oid := str(o.get("order_id", ""))
		if not _valid_order_id_format(oid):
			return _fail("orders[%d].order_id invalid" % i)
		if seen.has(oid):
			return _fail("duplicate order_id '%s'" % oid)
		seen[oid] = true
		var action := str(o.get("action", ""))
		if kind == "COMMAND":
			if action.is_empty():
				return _fail("orders[%d].action missing for COMMAND" % i)
			if not action in (IntentScript.ACTIONS as Array):
				return _fail("orders[%d].action '%s' is not a canonical action" % [i, action])
		var scope: Variant = o.get("scope", {})
		if not scope is Dictionary:
			return _fail("orders[%d].scope must be an object" % i)
		var ex: Variant = o.get("scope_expr", {})
		if not ex is Dictionary:
			return _fail("orders[%d].scope_expr must be an object" % i)
		if not (ex as Dictionary).is_empty():
			var se: Dictionary = AlgebraScript.validate_expr(ex)
			if not bool(se.get("ok", false)):
				return _fail("orders[%d].scope_expr: %s" % [i, str(se.get("why", "?"))])
			if _contains_key(ex, "unit_ids"):
				return _fail("orders[%d].scope_expr must not carry resolved unit-id lists" % i)
		var mods: Variant = o.get("modifiers", {})
		if not mods is Dictionary:
			return _fail("orders[%d].modifiers must be an object" % i)
		var style: Variant = o.get("style", {})
		if not style is Dictionary:
			return _fail("orders[%d].style must be an object" % i)
		var ev: Variant = o.get("source_evidence", [])
		if not ev is Array:
			return _fail("orders[%d].source_evidence must be an array" % i)
		var cf := float(o.get("confidence", -1.0))
		if cf < 0.0 or cf > 1.0:
			return _fail("orders[%d].confidence outside 0.0-1.0" % i)
	var cov: Variant = ir.get("coverage", {})
	if not cov is Dictionary:
		return _fail("IR coverage must be an object")
	if not str(ir.get("fingerprint", "")).begins_with("CIRv2:"):
		return _fail("IR fingerprint missing or malformed")
	# Fingerprint self-consistency (semantic drift guard).
	var recomputed := compute_fingerprint(kind, relation, orders)
	if str(ir.get("fingerprint", "")) != recomputed:
		return _fail("IR fingerprint mismatch (stored=%s recomputed=%s)" % [
			str(ir.get("fingerprint", "")).left(60), recomputed.left(60)])
	return {"ok": true}


# --- Serialization -----------------------------------------------------------

static func to_dict(ir: Dictionary) -> Dictionary:
	return (ir as Dictionary).duplicate(true)


static func from_dict(d: Dictionary) -> Dictionary:
	if not d is Dictionary:
		return _fail("IR dict must be an object")
	if int(d.get("version", -1)) != VERSION:
		return _fail("IR version must be %d" % VERSION)
	# Re-normalize through the canonical constructor so stored bytes can
	# never drift from live semantics: rebuild orders then recompute
	# coverage + fingerprints deterministically.
	var kind := str(d.get("kind", "COMMAND")).strip_edges().to_upper()
	var orders: Array = []
	if d.get("orders", []) is Array:
		orders = ((d.get("orders", []) as Array).duplicate(true))
	var original := str(d.get("original_text", ""))
	var rebuilt := {"request_type": kind,
		"orders": [],
		"relation": str(d.get("relation", "")),
		"question": str(d.get("question", "")),
		"missing": (d.get("missing", []) as Array).duplicate() if d.get("missing", []) is Array else [],
		"order_confidence": float(d.get("confidence", 1.0))}
	for o_val in orders:
		if not o_val is Dictionary:
			return _fail("orders entry must be an object")
		var o: Dictionary = (o_val as Dictionary).duplicate(true)
		# from_validated_intent expects validated-style orders; stored
		# orders already are, so pass through verbatim.
		(rebuilt["orders"] as Array).append(o)
	# Non-COMMAND envelopes with zero orders bypass order normalization.
	if orders.is_empty() and kind != "COMMAND":
		var cov0 := bind_coverage(original, [])
		var ir0 := {"version": VERSION, "kind": kind,
			"relation": "SINGLE", "relation_source": "DEFAULT_SINGLE",
			"orders": [], "original_text": original, "coverage": cov0,
			"fingerprint": compute_fingerprint(kind, "SINGLE", []),
			"evidence_fingerprint": compute_evidence_fingerprint([], cov0),
			"question": str(rebuilt.get("question", "")),
			"missing": rebuilt.get("missing", []),
			"confidence": float(rebuilt.get("order_confidence", 1.0)),
			"legacy": {}}
		var v0 := validate_ir(ir0)
		if not bool(v0.get("ok", false)):
			return v0
		return {"ok": true, "ir": ir0}
	return from_validated_intent(rebuilt, original)


# --- Downstream adapter ------------------------------------------------------
## Legacy-shaped orders for the EXISTING router (no behavior change).
## Each entry: {action, scope, scope_expr, style, confidence, order_id}.

static func to_legacy_orders(ir: Dictionary) -> Array:
	var out: Array = []
	for o_val in (ir.get("orders", []) as Array):
		if not o_val is Dictionary:
			continue
		var o: Dictionary = o_val
		out.append({"action": str(o.get("action", "")),
			"scope": (o.get("scope", {}) as Dictionary).duplicate(true),
			"scope_expr": (o.get("scope_expr", {}) as Dictionary).duplicate(true),
			"style": (o.get("style", {}) as Dictionary).duplicate(true),
			"confidence": float(o.get("confidence", 0.0)),
			"order_id": str(o.get("order_id", "")),
			"request_type": str(ir.get("kind", "COMMAND"))})
	return out


# --- Diagnostics (DEV only; never player prose) ------------------------------

static func dev_diagnostics(ir: Dictionary) -> Dictionary:
	var cov: Dictionary = ir.get("coverage", {})
	var orders: Array = ir.get("orders", [])
	var ofps: Array = []
	for o in orders:
		if o is Dictionary:
			ofps.append({"order_id": str((o as Dictionary).get("order_id", "?")),
				"fp": order_fingerprint(o),
				"scope_fp": scope_fingerprint(o),
				"evidence": ((o as Dictionary).get("source_evidence", []) as Array).duplicate()})
	return {"version": int(ir.get("version", 0)), "kind": str(ir.get("kind", "")),
		"relation": str(ir.get("relation", "")),
		"relation_source": str(ir.get("relation_source", "")),
		"order_count": orders.size(), "orders": ofps,
		"fingerprint": str(ir.get("fingerprint", "")),
		"evidence_fingerprint": str(ir.get("evidence_fingerprint", "")),
		"coverage_ratio": float(cov.get("coverage_ratio", 0.0)),
		"covered_chars": int(cov.get("covered_chars", 0)),
		"total_chars": int(cov.get("total_chars", 0)),
		"uncovered_spans": ((cov.get("uncovered", []) as Array).duplicate(true)),
		"unbound": ((cov.get("unbound", []) as Array).duplicate(true)),
		"evidence_status": ((cov.get("evidence_status", {}) as Dictionary).duplicate(true)),
		"semantic_uncovered": ((cov.get("semantic_uncovered", []) as Array).duplicate(true))}


static func describe(ir: Dictionary) -> String:
	var cov: Dictionary = ir.get("coverage", {})
	return "CommandIR v%d %s %s orders=%d fp=%s cov=%.0f%% unbound=%d sem_uncovered=%d" % [
		int(ir.get("version", 0)), str(ir.get("kind", "?")),
		str(ir.get("relation", "?")), (ir.get("orders", []) as Array).size(),
		str(ir.get("fingerprint", "?")).left(48),
		float(cov.get("coverage_ratio", 0.0)) * 100.0,
		(cov.get("unbound", []) as Array).size(),
		(cov.get("semantic_uncovered", []) as Array).size()]
