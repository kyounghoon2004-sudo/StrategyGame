class_name Step7SemanticGate
extends RefCounted

## Godot is the judge. The tiny model interprets; this gate disposes.
##
## evaluate(ir, deps) runs deterministic checks BEFORE any COMMAND reaches
## tactical selection/staging. Verdicts:
##   PASS  — route downstream (COMMAND staging / question lanes).
##   STOP  — never select, never stage, never mutate. Carries stop_kind +
##           a player-facing clarification (conflict/sequence) or a
##           fallback directive (invalid/uncertain -> large semantic path).
##
## deps: {"unit_manager" (optional), "pool" (optional unit Array),
##        "selected_unit", "has_previous" (bool), "sequence_supported"
##        (bool, default false), "min_coverage" (float, default 0.0),
##        "require_bound_evidence" (bool, default true)}
##
## Pure over CommandIR v2 + Scope Algebra. No inference, no state writes.

const CommandIRScript = preload("res://scripts/step7/step7_command_ir.gd")
const AlgebraScript = preload("res://scripts/step7/step7_scope_algebra.gd")
const IntentScript = preload("res://scripts/step7/step7_chat_intent.gd")

## Action pairs that can NEVER hold simultaneously on one formation.
## Same-action overlaps are benign (first order wins, deduped downstream).
const HARD_CONFLICT_PAIRS := [
	["ADVANCE", "HOLD"], ["ADVANCE", "RETREAT"], ["ADVANCE", "WITHDRAW"],
	["HOLD", "RETREAT"], ["HOLD", "WITHDRAW"], ["HOLD", "RECON"],
	["ADVANCE", "RECON"], ["RETREAT", "RECON"],
]


static func _stop(kind: String, checks: Array, clarification: String, fallback: bool) -> Dictionary:
	return {"verdict": "STOP", "stop_kind": kind, "checks": checks,
		"clarification": clarification, "fallback_to_large": fallback}


static func _pass(checks: Array, lane: String) -> Dictionary:
	return {"verdict": "PASS", "stop_kind": "", "checks": checks,
		"clarification": "", "fallback_to_large": false, "lane": lane}


static func _actions_conflict(a: String, b: String) -> bool:
	if a == b:
		return false
	var x := [a, b]
	x.sort()
	for p in HARD_CONFLICT_PAIRS:
		var y: Array = (p as Array).duplicate()
		y.sort()
		if x == y:
			return true
	# Conservative default: any two DIFFERENT movement-ish actions on one
	# formation in PARALLEL is a conflict (never silently pick one).
	var moves := ["ADVANCE", "MOVE", "RETREAT", "RECON", "FLANK", "REPOSITION", "WITHDRAW"]
	return a in moves and b in moves


## Resolve every order to unit-id sets. Returns {ok, sets, why}.
static func resolve_order_sets(ir: Dictionary, deps: Dictionary) -> Dictionary:
	var sets: Array = []
	for o_val in (ir.get("orders", []) as Array):
		var o: Dictionary = o_val
		var ex: Dictionary = CommandIRScript.effective_scope_expr(o)
		if ex.is_empty():
			var leg: Dictionary = AlgebraScript.compile_legacy(o.get("scope", {}))
			if not bool(leg.get("ok", false)):
				if str(leg.get("special", "")) == "PREVIOUS":
					return {"ok": false, "why": "UNRESOLVED_REFERENCE", "detail": "PREVIOUS"}
				return {"ok": false, "why": "INVALID_SCOPE", "detail": str(leg.get("why", "?"))}
			ex = leg.get("expr", {})
		var r: Dictionary = AlgebraScript.resolve(AlgebraScript.normalize(ex), deps)
		if not bool(r.get("ok", false)):
			return {"ok": false, "why": "INVALID_SCOPE", "detail": str(r.get("fail_detail", "?"))}
		sets.append({"order_id": str(o.get("order_id", "?")),
			"action": str(o.get("action", "")),
			"unit_ids": (r.get("unit_ids", []) as Array).duplicate(),
			"empty": bool(r.get("empty", true))})
	return {"ok": true, "sets": sets}


static func evaluate(ir: Dictionary, deps: Dictionary) -> Dictionary:
	var checks: Array = []
	var seq_ok := bool(deps.get("sequence_supported", false))
	var min_cov := float(deps.get("min_coverage", 0.0))
	var need_ev := bool(deps.get("require_bound_evidence", true))
	# 1) IR structurally valid.
	var v: Dictionary = CommandIRScript.validate_ir(ir)
	checks.append({"check": "ir_valid", "ok": bool(v.get("ok", false)), "detail": str(v.get("why", ""))})
	if not bool(v.get("ok", false)):
		return _stop("INVALID_IR", checks, "", true)
	var kind := str(ir.get("kind", "")).strip_edges().to_upper()
	var relation := str(ir.get("relation", "")).strip_edges().to_upper()
	var orders: Array = ir.get("orders", [])
	# 2) COMMAND carries orders.
	var has_orders := not orders.is_empty()
	checks.append({"check": "has_orders", "ok": has_orders or kind != "COMMAND", "detail": ""})
	if kind == "COMMAND" and not has_orders:
		return _stop("NO_ORDERS", checks, "", true)
	if kind != "COMMAND":
		checks.append({"check": "non_command_lane", "ok": true, "detail": kind})
		var lane := "QUESTION_LARGE" if kind in ["ADVICE", "INFORMATION"] else "CLARIFY"
		return _pass(checks, lane)
	# 3) Scope AST valid per order (no unit-id lists — enforced by IR).
	var scope_ok := true
	var scope_why := ""
	for i in range(orders.size()):
		var o: Dictionary = orders[i]
		var ex: Dictionary = CommandIRScript.effective_scope_expr(o)
		if ex.is_empty():
			var leg: Dictionary = AlgebraScript.compile_legacy(o.get("scope", {}))
			if not bool(leg.get("ok", false)):
				if str(leg.get("special", "")) == "PREVIOUS":
					checks.append({"check": "scope_ast", "ok": false, "detail": "UNRESOLVED_REFERENCE"})
					var has_prev := bool(deps.get("has_previous", false))
					if has_prev:
						checks.append({"check": "reference_previous", "ok": true, "detail": ""})
					else:
						return _stop("UNRESOLVED_REFERENCE", checks,
							"직전에 권고한 안이 없습니다. 먼저 물어보시거나 명령을 내려 주십시오.", false)
				else:
					return _stop("INVALID_SCOPE", checks, "", true)
				scope_ok = false
				scope_why = str(leg.get("why", "?"))
				break
			ex = leg.get("expr", {})
		var se: Dictionary = AlgebraScript.validate_expr(ex)
		if not bool(se.get("ok", false)):
			scope_ok = false
			scope_why = str(se.get("why", "?"))
			break
	checks.append({"check": "scope_ast", "ok": scope_ok, "detail": scope_why})
	if not scope_ok:
		return _stop("INVALID_SCOPE", checks, "", true)
	# 4) Source evidence bound (fail closed -> large fallback, not a guess).
	var cov: Dictionary = ir.get("coverage", {})
	var ev_status: Dictionary = cov.get("evidence_status", {})
	var unbound: Array = (cov.get("unbound", []) as Array).duplicate()
	var missing: Array = (cov.get("missing_evidence", []) as Array).duplicate()
	var ev_ok := unbound.is_empty() and (missing.is_empty() or not need_ev)
	if need_ev and not missing.is_empty():
		ev_ok = false
	checks.append({"check": "evidence_bound", "ok": ev_ok,
		"detail": "unbound=%d missing=%d" % [unbound.size(), missing.size()]})
	if not ev_ok:
		return _stop("UNBOUND_EVIDENCE", checks, "", true)
	# 5) Semantic-bearing clauses covered.
	var sem: Array = (cov.get("semantic_uncovered", []) as Array).duplicate()
	var ratio := float(cov.get("coverage_ratio", 0.0))
	var cov_ok := sem.is_empty() and ratio >= min_cov
	checks.append({"check": "coverage", "ok": cov_ok,
		"detail": "ratio=%.2f sem_uncovered=%d" % [ratio, sem.size()]})
	if not cov_ok:
		return _stop("UNCOVERED_SEMANTIC", checks, "", true)
	# 6) Reference atoms resolvable now (SELECTED without a selection).
	var rs: Dictionary = resolve_order_sets(ir, deps)
	if not bool(rs.get("ok", false)):
		checks.append({"check": "resolve", "ok": false, "detail": str(rs.get("detail", "?"))})
		if str(rs.get("why", "")) == "UNRESOLVED_REFERENCE":
			return _stop("UNRESOLVED_REFERENCE", checks,
				"직전에 권고한 안이 없습니다. 먼저 물어보시거나 명령을 내려 주십시오.", false)
		return _stop("INVALID_SCOPE", checks, "", true)
	checks.append({"check": "resolve", "ok": true, "detail": ""})
	var sets: Array = rs.get("sets", [])
	# Empty scope: honest STOP (no formation matches — never stage air).
	for s in sets:
		if bool((s as Dictionary).get("empty", true)):
			checks.append({"check": "non_empty", "ok": false,
				"detail": str((s as Dictionary).get("order_id", "?"))})
			return _stop("EMPTY_SCOPE", checks, "해당 조건에 속한 부대가 없습니다.", false)
	checks.append({"check": "non_empty", "ok": true, "detail": ""})
	# 7) SEQUENCE is understood but NOT executable here: STOP with an
	#    honest explanation (never misfile as PARALLEL contradiction).
	if relation == "SEQUENCE":
		checks.append({"check": "sequence_supported", "ok": seq_ok, "detail": relation})
		if not seq_ok:
			return _stop("SEQUENCE_UNSUPPORTED", checks,
				"순차 명령으로 이해했습니다만 순차 실행은 아직 지원하지 않습니다. 한 번에 하나씩 말씀해 주십시오.", false)
		return _pass(checks, "COMMAND_STAGE")
	checks.append({"check": "sequence_supported", "ok": true, "detail": relation})
	# 8) PARALLEL hard conflicts: overlapping units + incompatible actions.
	if relation == "PARALLEL" and sets.size() > 1:
		var conflicts: Array = []
		for i in range(sets.size()):
			for j in range(i + 1, sets.size()):
				var a: Dictionary = sets[i]
				var b: Dictionary = sets[j]
				var bset := {}
				for uid in (b.get("unit_ids", []) as Array):
					bset[str(uid)] = true
				var shared: Array = []
				for uid2 in (a.get("unit_ids", []) as Array):
					if bset.has(str(uid2)):
						shared.append(str(uid2))
				shared.sort()
				if shared.is_empty():
					continue
				if _actions_conflict(str(a.get("action", "")), str(b.get("action", ""))):
					conflicts.append({"a": str(a.get("order_id", "?")),
						"b": str(b.get("order_id", "?")),
						"action_a": str(a.get("action", "")),
						"action_b": str(b.get("action", "")),
						"shared": shared})
		checks.append({"check": "no_hard_conflict", "ok": conflicts.is_empty(),
			"detail": "conflicts=%d" % conflicts.size()})
		if not conflicts.is_empty():
			var first: Dictionary = conflicts[0]
			return _stop("HARD_CONFLICT", checks,
				conflict_clarification(first), false)
	else:
		checks.append({"check": "no_hard_conflict", "ok": true, "detail": relation})
	return _pass(checks, "COMMAND_STAGE")


## Player-facing clarification for a hard conflict. Unit display names are
## filled by the caller when live data exists (shared ids always listed).
static func conflict_clarification(c: Dictionary) -> String:
	var shared: Array = (c.get("shared", []) as Array).duplicate()
	shared.sort()
	var names := ", ".join(shared.slice(0, 3))
	if shared.size() > 3:
		names += " 외 %d기" % (shared.size() - 3)
	var a_kr := action_kr(str(c.get("action_a", "")))
	var b_kr := action_kr(str(c.get("action_b", "")))
	return "%s 부대가 %s 명령과 %s 명령에 동시에 포함됩니다. 해당 부대는 %s할까요, %s할까요?" % [names, a_kr, b_kr, a_kr, b_kr]


static func action_kr(a: String) -> String:
	match a.strip_edges().to_upper():
		"ADVANCE":
			return "전진"
		"HOLD":
			return "대기"
		"RETREAT":
			return "후퇴"
		"RECON":
			return "정찰"
		"MOVE":
			return "이동"
		"FLANK":
			return "측면 기동"
		"REPOSITION":
			return "재배치"
		"WITHDRAW":
			return "철수"
		"REGROUP":
			return "재집결"
		"PROTECT":
			return "엄호"
		"SCREEN":
			return "차단 전개"
	return a
