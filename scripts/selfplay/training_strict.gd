extends RefCounted

## TRAINING_CONTRACT_REVIEW_WAKE_V1 — explicit TRAINING/EVAL STRICT scope.
##
## STRICT Brain-failure contract (training/eval only):
##   A first-try Brain response rejected by the production parser/validator
##   is an immediate LOSS for that policy side: no repair, no semantic
##   fallback, no second attempt. The unexecutable General action resolves
##   through the EXISTING terminal LOSS path (reward -3). This module adds
##   no reward, no shaping, no parser: judgment always flows through the
##   production validators (Cloud2VictoryResponse / Cloud2GeneralResponse /
##   authoring / mission-manager adoption), and rewards always flow through
##   SymLocMatch.outcomes_for_winner.
##
## Scope is EXPLICIT and default OFF:
##   TRAINING_STRICT_CONTRACT=1 enables strict handling. Local-vs-Local
##   alone never implies it. STRICT OFF preserves Human-vs-Cloud / dev
##   behavior exactly (bounded repair retries, fallback plans, manual
##   decisions all untouched).
##
## Only parser/validator rejections of an actual Brain response latch a
## strict fault (VP_*/VA_*/COORD_*/PLAN_* codes). Transport failures
## (START_FAILED_*, TIMEOUT*, PROVIDER_ERROR, ...) never latch: no Brain
## response existed to judge. Strict mode still makes no second attempt
## of any kind (deterministic single generation per decision point).
##
## Godot remains terminal/outcome authority: this module only maps a
## latched fault to a terminal dict; the symmetric mount (or self-play
## observer) finalizes the match from it like any other terminal read.

const MatchCls = preload("res://scripts/symloc/symloc_match.gd")

const ENV_FLAG := "TRAINING_STRICT_CONTRACT"
const REASON_BRAIN_CONTRACT := "BRAIN_CONTRACT_FAILURE"

## Rejection-code prefixes that prove a Brain response was judged and
## rejected by production validation (authoring VA_* included: unknown
## task / trigger / unit, bad shape).
const BRAIN_CONTRACT_PREFIXES := ["VP_", "VA_", "COORD_", "PLAN_"]
## Non-Brain codes that must never latch even at a latch call site.
const NON_BRAIN_CODES := ["COORD_EMPTY_MENU", "VP_INIT_CONSUME_EMPTY",
	"VP_INITIAL_FAILED_LATCHED", "VP_NO_PLAN", "COORD_NO_PLAN"]


## Explicit strict scope. Live env read (has_environment misses
## in-process sets on this Godot/Windows build); default OFF.
static func strict_enabled() -> bool:
	var raw := OS.get_environment(ENV_FLAG).strip_edges().to_lower()
	return raw == "1" or raw == "true" or raw == "on" or raw == "yes"


## True when a rejection code proves production validation judged a
## Brain response (vs transport/internal conditions with no response).
static func is_brain_contract_code(code: String) -> bool:
	var c := code.strip_edges().to_upper()
	if c.is_empty() or c in NON_BRAIN_CODES:
		return false
	for p in BRAIN_CONTRACT_PREFIXES:
		if c.begins_with(p):
			return true
	return false


## Authoritative terminal reason for an offender side. The fault code is
## part of the reason so the match record names the failed contract.
static func reason_for_offender(offender_side: String, fault_code: String = "") -> String:
	var side := offender_side.strip_edges().to_upper()
	if side != "BLUE":
		side = "RED"
	var code := fault_code.strip_edges().to_upper()
	if code.is_empty():
		return "%s_%s" % [REASON_BRAIN_CONTRACT, side]
	return "%s_%s_%s" % [REASON_BRAIN_CONTRACT, side, code]


## Opponent of an offender side (RED<->BLUE; unknown coerces to RED
## offender / BLUE winner, matching controller side coercion).
static func winner_for_offender(offender_side: String) -> String:
	if offender_side.strip_edges().to_upper() == "BLUE":
		return "RED"
	return "BLUE"


## Terminal dict for a latched strict fault. Same shape as
## SymLocMatch.read_terminal ({over, winner, reason, turn}) plus the
## fault facts the match record audits. Rewards are NOT computed here:
## callers resolve them through MatchCls.outcomes_for_winner(winner).
static func terminal_for_offender(offender_side: String, fault: Dictionary, turn: int = 0) -> Dictionary:
	var side := offender_side.strip_edges().to_upper()
	if side != "BLUE":
		side = "RED"
	var code := str(fault.get("code", "")).strip_edges().to_upper()
	var t := turn
	if t <= 0:
		t = int(fault.get("turn", 0))
	return {"over": true, "winner": winner_for_offender(side),
		"reason": reason_for_offender(side, code), "turn": t,
		"offender_side": side, "fault_code": code,
		"fault_kind": str(fault.get("kind", "")),
		"fault_detail": str(fault.get("detail", "")).left(220)}


## Match-layer poll: first latched strict fault across both side
## controllers becomes the authoritative terminal. {} when strict is
## off or no fault is latched. Controllers are duck-typed (real
## Laya/Cloud2 controllers or test doubles exposing strict_fault()).
## Serialized phases mean at most one fault can exist; the fixed
## RED-first order is a tiebreak that cannot trigger in a real match.
static func poll_strict_terminal(red_ctl: Variant, blue_ctl: Variant) -> Dictionary:
	if not strict_enabled():
		return {}
	for ctl in [red_ctl, blue_ctl]:
		if ctl == null:
			continue
		if not (ctl as Object).has_method("strict_fault"):
			continue
		var fault: Dictionary = (ctl as Object).call("strict_fault")
		if fault.is_empty():
			continue
		var side := str(fault.get("side", "")).strip_edges().to_upper()
		if side != "RED" and side != "BLUE" and (ctl as Object).has_method("get_side"):
			side = str((ctl as Object).call("get_side")).strip_edges().to_upper()
		return terminal_for_offender(side, fault)
	return {}
