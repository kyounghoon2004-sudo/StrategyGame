class_name Cloud2VictoryResponse
extends RefCounted

## VICTORY PLAN V0 — General output contract + validation.
##
## Two request types (prompt and validator live in this one file so the
## contract cannot drift):
##   VICTORY_INITIAL — author a COMPLETE long-horizon VictoryPlan:
##     {final_objective, desired_end_state?, doctrine?, phases[1..6],
##      plan_abort_conditions?, branches?, opponent_hypotheses?,
##      review_horizon_turns?, snapshot_id?}
##   VICTORY_REVIEW — decide the fate of the persistent plan:
##     {decision: KEEP | ADVANCE_PHASE | AMEND_PLAN | EMERGENCY_REPLAN,
##      reason?, hypotheses?, next_phase_id? (ADVANCE),
##      phases? (AMEND: full phase array, terminal history immutable),
##      full plan body (EMERGENCY: final_objective + phases + ...)}
##
## The model is never trusted: structure, phase shape, mission shape,
## trigger names, and doctrine ranges are re-checked here (via
## Cloud2VictoryPlan), lifecycle rules (history immutability, advance
## targets) are enforced by the mission manager, and assignments are
## reconciled against live Godot state afterwards.
##
## Rejection codes: VP_INVALID_JSON plus Cloud2VictoryPlan / Cloud2Mission
## codes and VP_STALE_SNAPSHOT (echo mismatch).

const VictoryPlanCls = preload("res://scripts/cloud2/cloud2_victory_plan.gd")
const ResponseCls = preload("res://scripts/cloud2/cloud2_response.gd")
const AuthoringCls = preload("res://scripts/cloud2/cloud2_victory_authoring.gd")

const REQUEST_INITIAL := "VICTORY_INITIAL"
const REQUEST_REVIEW := "VICTORY_REVIEW"

const VICTORY_INITIAL_PROMPT := "You are the RED general. Deterministic controllers execute your missions with legal local actions; Godot owns legality, positions, outcome.\n\nWIN THE BATTLE. Your HQ destroyed = IMMEDIATE DEFEAT. Enemy HQ destroyed = IMMEDIATE VICTORY. SECONDARY: among winning plans prefer lowest friendly losses. No mission outranks HQ survival or a decisive HQ kill.\n\nAuthor a COMPLETE LONG-HORIZON plan (2-4 phases): how you win, what each phase achieves, what gates each advance, which forces serve which purpose, what is held in reserve and when released, what contingencies matter, what aborts the plan.\n\nOUTPUT: ONE compact JSON object ONLY. No Markdown, no code fences, no commentary before or after. Strings SHORT (objective <=200 chars, others <=160). 2-4 phases, <=4 missions per phase, <=4 conditions per list, <=3 branches. Godot assigns all ids, statuses, and clocks — never author them.\n\n{\"objective\": \"...\", \"end_state\": \"...\", \"cadence\": 4, \"doctrine\": [0.6, 0.5, 0.6, 0.6, 0.7, 0.2], \"phases\": [{\"id\": \"P1\", \"name\": \"FIX CENTER\", \"purpose\": \"...\", \"intent\": \"...\", \"groups\": {\"CenterFix\": [\"R_INF_1\", \"R_INF_2\"]}, \"missions\": [{\"task\": \"FIX\", \"area\": \"CENTER\", \"units\": [\"R_INF_1\", \"R_INF_2\"], \"vs\": \"INFANTRY\", \"preserve\": true, \"win\": [{\"when\": \"TURNS_ELAPSED\", \"turns\": 3, \"since\": 1}], \"stop\": [\"HQ_THREATENED\"]}], \"win\": [{\"when\": \"TURNS_ELAPSED\", \"turns\": 3, \"since\": 1}], \"lose\": [{\"when\": \"FORCE_STRENGTH_BELOW\", \"fraction\": 0.4}], \"abort\": [\"HQ_THREATENED\"], \"next\": \"P2\", \"on_fail\": \"HOLD\", \"reserve\": [\"R_CAV_1\"], \"release\": [{\"when\": \"TURNS_ELAPSED\", \"turns\": 3, \"since\": 1}], \"exploit\": \"...\"}], \"abort\": [{\"when\": \"FORCE_STRENGTH_BELOW\", \"fraction\": 0.25}], \"branches\": [{\"id\": \"B1\", \"if\": \"BLUE cavalry commits north\", \"when\": {\"when\": \"ENEMY_CLASS_DETECTED\", \"class\": \"CAVALRY\", \"region\": \"NORTH\"}, \"then\": \"REQUEST_REVIEW\"}], \"hypotheses\": [{\"h\": \"BLUE_FLANK\", \"conf\": 0.6, \"ev\": [\"...\"]}]}\n\nVocabulary. task: HOLD|ADVANCE|FIX|ATTACK|FLANK|RECON|RESERVE|WITHDRAW|EXECUTE (optional label only; omit or EXECUTE for free-form intent-driven missions). area/zone: NORTH|CENTER|SOUTH|WEST|EAST|ANY. vs: enemy class hint. target: enemy unit id. next: next phase id, \"\" = next in order, \"-\" = hold for review, \"END\" = plan complete. on_fail: HOLD|ADVANCE|EMERGENCY. then: REQUEST_REVIEW|HOLD_PHASE|RELEASE_RESERVE|NOTE_ONLY. Triggers (bare name or {\"when\": NAME, params}): MISSION_BLOCKED, MISSION_COMPLETE {mission_id}, FORCE_STRENGTH_BELOW {fraction}, ENEMY_COMMITMENT_HIGH {region, threshold}, ENEMY_CLASS_DETECTED {class, region}, HQ_THREATENED, LOCAL_ADVANTAGE_HIGH {region, ratio}, OBJECTIVE_EXPOSED, TURNS_ELAPSED {turns, since}, TARGET_DESTROYED {unit_id}, REGION_OCCUPIED {region, side}, REGION_REACHED {region, mission_id}.\n\nRich mission (all optional, concise): \"intent\" desired effect, \"effects\" (<=4), \"priority\", \"prefer\" {units,classes,areas}, \"roles\" {unit: role}, \"coord\" (how assigned units cooperate), \"limits\" (<=4, e.g. avoid spearmen), \"support\" [{from,to,kind}], \"tag\". Example: {\"units\":[\"R_CAV_1\",\"R_CAV_2\"],\"intent\":\"Pressure the ranged line and threaten its withdrawal route.\",\"roles\":{\"R_CAV_1\":\"Create immediate pressure.\",\"R_CAV_2\":\"Stay mobile; punish withdrawal.\"},\"limits\":[\"Avoid prolonged spearman contact.\"],\"coord\":\"CAV_1 pressures first; CAV_2 exploits displacement.\"}\n\ncadence (1-12) is REVIEW CADENCE (how often you re-validate), NOT planning horizon — the plan itself spans the battle. In phase P1 assign EVERY ready RED formation from friendly_units to exactly one mission; later phases reuse the same force. Use only real unit ids, areas, tasks, triggers from the packet. Shorter output is safer: if your reply risks the token limit, shorten strings first, never drop phases or missions."

const VICTORY_REVIEW_PROMPT := "You are the RED general reviewing your persistent VICTORY PLAN. Controllers execute the ACTIVE phase; Godot owns legality and truth. Do NOT rewrite the whole plan by default — decide its fate. WIN THE BATTLE (HQ lost = DEFEAT, enemy HQ destroyed = VICTORY); SECONDARY: minimize friendly losses.\n\nThe packet carries your plan in compact authoring form + live statuses + evaluated conditions + bounded events + WHY this review fired. Return ONE JSON object ONLY (no Markdown, fences, or prose):\n- KEEP (plan stands): {\"decision\": \"KEEP\", \"reason\": \"...\"}. Prefer this when the scheme is still valid.\n- ADVANCE_PHASE (active phase done; next activates, same lineage): {\"decision\": \"ADVANCE_PHASE\", \"reason\": \"...\", \"next_phase_id\": \"P2\"} (next_phase_id optional: defaults to the phase transition, else next in order).\n- AMEND_PLAN (same plan, revised phases; COMPLETED/FAILED phases MUST be carried unchanged — history is immutable): {\"decision\": \"AMEND_PLAN\", \"reason\": \"...\", \"phases\": [full phase array in COMPACT form: {\"id\", \"name\", \"purpose\", \"intent\", \"groups\", \"missions\": [{\"task\", \"area\", \"units\", \"vs\"?, \"target\"?, \"zone\"?, \"hold_fire\"?, \"pursue\"?, \"preserve\"?, \"win\"?, \"stop\"?}], \"entry\"?, \"win\"?, \"lose\"?, \"abort\"?, \"next\"?, \"on_fail\"?, \"reserve\"?, \"release\"?, \"exploit\"?}]}. Minor events deserve minor amendments.\n- EMERGENCY_REPLAN (concept unviable; old plan stays in history; rare): {\"decision\": \"EMERGENCY_REPLAN\", \"reason\": \"...\", \"objective\": \"...\", \"phases\": [...compact...], ...} (compact initial shape).\n\nOptional: \"hypotheses\": [{\"h\": \"NAME\", \"conf\": 0-1, \"ev\": [\"...\"]}], \"snapshot_id\" echo. Conditions: bare trigger names or {\"when\": NAME, params}. Keep strings short."

## SYMMETRIC V1: BLUE mirrors of the victory prompts. Same contract,
## same schema demands, side-relative framing + example ids only.
const VICTORY_INITIAL_PROMPT_BLUE := "You are the BLUE general. Deterministic controllers execute your missions with legal local actions; Godot owns legality, positions, outcome.\n\nWIN THE BATTLE. Your HQ destroyed = IMMEDIATE DEFEAT. Enemy HQ destroyed = IMMEDIATE VICTORY. SECONDARY: among winning plans prefer lowest friendly losses. No mission outranks HQ survival or a decisive HQ kill.\n\nAuthor a COMPLETE LONG-HORIZON plan (2-4 phases): how you win, what each phase achieves, what gates each advance, which forces serve which purpose, what is held in reserve and when released, what contingencies matter, what aborts the plan.\n\nOUTPUT: ONE compact JSON object ONLY. No Markdown, no code fences, no commentary before or after. Strings SHORT (objective <=200 chars, others <=160). 2-4 phases, <=4 missions per phase, <=4 conditions per list, <=3 branches. Godot assigns all ids, statuses, and clocks — never author them.\n\n{\"objective\": \"...\", \"end_state\": \"...\", \"cadence\": 4, \"doctrine\": [0.6, 0.5, 0.6, 0.6, 0.7, 0.2], \"phases\": [{\"id\": \"P1\", \"name\": \"FIX CENTER\", \"purpose\": \"...\", \"intent\": \"...\", \"groups\": {\"CenterFix\": [\"B_INF_1\", \"B_INF_2\"]}, \"missions\": [{\"task\": \"FIX\", \"area\": \"CENTER\", \"units\": [\"B_INF_1\", \"B_INF_2\"], \"vs\": \"INFANTRY\", \"preserve\": true, \"win\": [{\"when\": \"TURNS_ELAPSED\", \"turns\": 3, \"since\": 1}], \"stop\": [\"HQ_THREATENED\"]}], \"win\": [{\"when\": \"TURNS_ELAPSED\", \"turns\": 3, \"since\": 1}], \"lose\": [{\"when\": \"FORCE_STRENGTH_BELOW\", \"fraction\": 0.4}], \"abort\": [\"HQ_THREATENED\"], \"next\": \"P2\", \"on_fail\": \"HOLD\", \"reserve\": [\"B_CAV_1\"], \"release\": [{\"when\": \"TURNS_ELAPSED\", \"turns\": 3, \"since\": 1}], \"exploit\": \"...\"}], \"abort\": [{\"when\": \"FORCE_STRENGTH_BELOW\", \"fraction\": 0.25}], \"branches\": [{\"id\": \"B1\", \"if\": \"RED cavalry commits north\", \"when\": {\"when\": \"ENEMY_CLASS_DETECTED\", \"class\": \"CAVALRY\", \"region\": \"NORTH\"}, \"then\": \"REQUEST_REVIEW\"}], \"hypotheses\": [{\"h\": \"RED_FLANK\", \"conf\": 0.6, \"ev\": [\"...\"]}]}\n\nVocabulary. task: HOLD|ADVANCE|FIX|ATTACK|FLANK|RECON|RESERVE|WITHDRAW|EXECUTE (optional label only; omit or EXECUTE for free-form intent-driven missions). area/zone: NORTH|CENTER|SOUTH|WEST|EAST|ANY. vs: enemy class hint. target: enemy unit id. next: next phase id, \"\" = next in order, \"-\" = hold for review, \"END\" = plan complete. on_fail: HOLD|ADVANCE|EMERGENCY. then: REQUEST_REVIEW|HOLD_PHASE|RELEASE_RESERVE|NOTE_ONLY. Triggers (bare name or {\"when\": NAME, params}): MISSION_BLOCKED, MISSION_COMPLETE {mission_id}, FORCE_STRENGTH_BELOW {fraction}, ENEMY_COMMITMENT_HIGH {region, threshold}, ENEMY_CLASS_DETECTED {class, region}, HQ_THREATENED, LOCAL_ADVANTAGE_HIGH {region, ratio}, OBJECTIVE_EXPOSED, TURNS_ELAPSED {turns, since}, TARGET_DESTROYED {unit_id}, REGION_OCCUPIED {region, side}, REGION_REACHED {region, mission_id}.\n\nRich mission (all optional, concise): \"intent\" desired effect, \"effects\" (<=4), \"priority\", \"prefer\" {units,classes,areas}, \"roles\" {unit: role}, \"coord\" (how assigned units cooperate), \"limits\" (<=4, e.g. avoid spearmen), \"support\" [{from,to,kind}], \"tag\". Example: {\"units\":[\"B_CAV_1\",\"B_CAV_2\"],\"intent\":\"Pressure the ranged line and threaten its withdrawal route.\",\"roles\":{\"B_CAV_1\":\"Create immediate pressure.\",\"B_CAV_2\":\"Stay mobile; punish withdrawal.\"},\"limits\":[\"Avoid prolonged spearman contact.\"],\"coord\":\"CAV_1 pressures first; CAV_2 exploits displacement.\"}\n\ncadence (1-12) is REVIEW CADENCE (how often you re-validate), NOT planning horizon — the plan itself spans the battle. In phase P1 assign EVERY ready BLUE formation from friendly_units to exactly one mission; later phases reuse the same force. Use only real unit ids, areas, tasks, triggers from the packet. Shorter output is safer: if your reply risks the token limit, shorten strings first, never drop phases or missions."

const VICTORY_REVIEW_PROMPT_BLUE := "You are the BLUE general reviewing your persistent VICTORY PLAN. Controllers execute the ACTIVE phase; Godot owns legality and truth. Do NOT rewrite the whole plan by default — decide its fate. WIN THE BATTLE (HQ lost = DEFEAT, enemy HQ destroyed = VICTORY); SECONDARY: minimize friendly losses.\n\nThe packet carries your plan in compact authoring form + live statuses + evaluated conditions + bounded events + WHY this review fired. Return ONE JSON object ONLY (no Markdown, fences, or prose):\n- KEEP (plan stands): {\"decision\": \"KEEP\", \"reason\": \"...\"}. Prefer this when the scheme is still valid.\n- ADVANCE_PHASE (active phase done; next activates, same lineage): {\"decision\": \"ADVANCE_PHASE\", \"reason\": \"...\", \"next_phase_id\": \"P2\"} (next_phase_id optional: defaults to the phase transition, else next in order).\n- AMEND_PLAN (same plan, revised phases; COMPLETED/FAILED phases MUST be carried unchanged — history is immutable): {\"decision\": \"AMEND_PLAN\", \"reason\": \"...\", \"phases\": [full phase array in COMPACT form: {\"id\", \"name\", \"purpose\", \"intent\", \"groups\", \"missions\": [{\"task\", \"area\", \"units\", \"vs\"?, \"target\"?, \"zone\"?, \"hold_fire\"?, \"pursue\"?, \"preserve\"?, \"win\"?, \"stop\"?}], \"entry\"?, \"win\"?, \"lose\"?, \"abort\"?, \"next\"?, \"on_fail\"?, \"reserve\"?, \"release\"?, \"exploit\"?}]}. Minor events deserve minor amendments.\n- EMERGENCY_REPLAN (concept unviable; old plan stays in history; rare): {\"decision\": \"EMERGENCY_REPLAN\", \"reason\": \"...\", \"objective\": \"...\", \"phases\": [...compact...], ...} (compact initial shape).\n\nOptional: \"hypotheses\": [{\"h\": \"NAME\", \"conf\": 0-1, \"ev\": [\"...\"]}], \"snapshot_id\" echo. Conditions: bare trigger names or {\"when\": NAME, params}. Keep strings short."


## BRAIN_PROBE_3SUBPLAN (diagnostic gate, prompt-only): when the env var
## names this side ("red" | "blue" | "both"), the victory prompts gain one
## paragraph asking for EXACTLY 3 simultaneous missions per phase with
## near-total ready-formation coverage. Unset = legacy prompts, unchanged.
## Contract, parser, validator and runtime are untouched.
const PROBE_3SUBPLAN_ENV := "BRAIN_PROBE_3SUBPLAN"
const PROBE_3SUBPLAN_INITIAL := "\n\nCONCURRENT OPERATIONS: every phase has EXACTLY 3 missions. The 3 missions of a phase run AT THE SAME TIME as simultaneous sub-plans of ONE operation, not sequential steps. Give each mission a materially different battlefield function chosen from the actual situation (for example fix/hold the enemy main body, maneuver around a flank, reserve/support, recon/screen, secondary pressure) with a different task and/or area. Split the ready non-HQ formations across the 3 missions so each ready non-HQ formation is in exactly one mission of the phase; leave none unassigned. A held-back force is its own RESERVE mission, not an omission."
const PROBE_3SUBPLAN_REVIEW := "\n\nCONCURRENT OPERATIONS: any phase you author or amend has EXACTLY 3 simultaneous missions with materially different functions, and together they cover every ready non-HQ formation (each in exactly one mission of the phase)."


static func _probe_3subplan_on(side: String) -> bool:
	var v := OS.get_environment(PROBE_3SUBPLAN_ENV).strip_edges().to_lower()
	return v == "both" or (not v.is_empty() and v == side.strip_edges().to_lower())


## Side selectors for the victory prompts (default red = legacy).
static func initial_prompt_for(side: String) -> String:
	return _initial_prompt(side) + (CONTEXT_NOTE if BrainContextCls.enabled() else "")


static func _initial_prompt(side: String) -> String:
	var base := VICTORY_INITIAL_PROMPT_BLUE if side.strip_edges().to_lower() == "blue" else VICTORY_INITIAL_PROMPT
	if AuthoringCls.unalloc_mode():
		return unalloc_initial_prompt(base, side)
	return base + PROBE_3SUBPLAN_INITIAL if _probe_3subplan_on(side) else base


static func review_prompt_for(side: String) -> String:
	return _review_prompt(side) + (CONTEXT_NOTE if BrainContextCls.enabled() else "")


static func _review_prompt(side: String) -> String:
	var base := VICTORY_REVIEW_PROMPT_BLUE if side.strip_edges().to_lower() == "blue" else VICTORY_REVIEW_PROMPT
	if AuthoringCls.unalloc_mode():
		return unalloc_review_prompt(base)
	return base + PROBE_3SUBPLAN_REVIEW if _probe_3subplan_on(side) else base


## CONTEXTUAL BRAIN V0 (env BRAIN_CONTEXT_PACK=v0): input-side note only.
## The output schema/contract text above is not edited.
const BrainContextCls = preload("res://scripts/cloud2/cloud2_brain_context.gd")
const CONTEXT_NOTE := "

BATTLE CONTEXT: the packet's \"context\" block states THIS battle's rules (class movement, attack, defense, range, matchups, terrain costs), force composition, map summary and victory conditions. These values change between battles. Judge each class by its values here, not by its name. The output format above is unchanged."


## BRAIN→HAND A contract prompt (frozen v1): the trained prompt with its
## friendly-allocation parts removed and the frozen wording added. Built by
## exact substring edits of the trained text so everything else stays
## byte-identical; a missing anchor fails loudly (push_error + marker).
const UNALLOC_RULE := "Each phase has EXACTLY 3 missions that run AT THE SAME TIME, each with a materially different battlefield function. Missions are high-level: task, area, intent, priority (plus optional vs/target/limits/effects). Do NOT name friendly units, hexes, paths or per-unit actions — downstream controllers allocate forces and act. Areas are read relative to your own HQ."


static func _edit(text: String, old: String, new: String, ok: Array) -> String:
	if not text.contains(old):
		ok[0] = false
		push_error("[VictoryResponse] unalloc prompt anchor missing: %s" % old.left(60))
		return text
	return text.replace(old, new)


static func unalloc_initial_prompt(base: String, side: String) -> String:
	var px := "B_" if side.strip_edges().to_lower() == "blue" else "R_"
	var ok := [true]
	var t := base
	t = _edit(t, "2-4 phases, <=4 missions per phase", "2-4 phases, EXACTLY 3 missions per phase", ok)
	t = _edit(t, "\"groups\": {\"CenterFix\": [\"%sINF_1\", \"%sINF_2\"]}, " % [px, px], "", ok)
	t = _edit(t, "\"units\": [\"%sINF_1\", \"%sINF_2\"], " % [px, px], "\"intent\": \"...\", \"priority\": \"high\", ", ok)
	t = _edit(t, ", \"reserve\": [\"%sCAV_1\"], \"release\": [{\"when\": \"TURNS_ELAPSED\", \"turns\": 3, \"since\": 1}]" % px, "", ok)
	var rich_start := t.find("Rich mission (all optional, concise):")
	var rich_end := t.find("

cadence (1-12)")
	if rich_start < 0 or rich_end < rich_start:
		ok[0] = false
		push_error("[VictoryResponse] unalloc prompt anchor missing: rich mission block")
	else:
		t = t.left(rich_start) + "Mission fields (concise): \"task\", \"area\", \"intent\" desired effect, \"priority\"; optional \"vs\", \"target\" (ENEMY id only), \"zone\", \"effects\" (<=4), \"limits\" (<=4), \"prefer\" {classes,areas}, \"preserve\", \"hold_fire\", \"pursue\", \"win\", \"stop\", \"tag\"." + t.substr(rich_end)
	var side_up := "BLUE" if px == "B_" else "RED"
	t = _edit(t, "In phase P1 assign EVERY ready %s formation from friendly_units to exactly one mission; later phases reuse the same force." % side_up, UNALLOC_RULE, ok)
	t = _edit(t, "Use only real unit ids, areas, tasks, triggers from the packet.", "Use only areas, tasks, triggers and ENEMY ids from the packet.", ok)
	return t if ok[0] else t + "

[UNALLOC_PROMPT_ANCHOR_MISSING]"


static func unalloc_review_prompt(base: String) -> String:
	var ok := [true]
	var t := _edit(base, "\"missions\": [{\"task\", \"area\", \"units\", ", "\"missions\": [{\"task\", \"area\", \"intent\", \"priority\", ", ok)
	t += "

" + UNALLOC_RULE + " Never add groups, reserve, release, units, roles, support or coord."
	return t if ok[0] else t + "

[UNALLOC_PROMPT_ANCHOR_MISSING]"

const REJECTION_CODES := ["VP_INVALID_JSON", "VP_INVALID_SCHEMA", "VP_STALE_SNAPSHOT",
	"VP_OBJECTIVE", "VP_PHASES", "VP_PHASE", "VP_BRANCH", "VP_DECISION", "VP_HISTORY"]


static func response_schema() -> Dictionary:
	return {
		"initial_compact": {"objective": "string <=200 (required)", "end_state": "string <=200 (optional)",
			"cadence": "int 1..12 REVIEW CADENCE (optional, default 4)", "doctrine": "[6 numbers] (optional)",
			"phases": "compact array 2..4 (required)", "abort": "conditions (optional)",
			"branches": "compact <=3 (optional)", "hypotheses": "[{h, conf, ev}] (optional)",
			"snapshot_id": "string (optional echo)"},
		"initial_legacy": {"final_objective": "string (required)", "phases": "full array 1..6 (required)",
			"note": "accepted for DEBUG_AGENT/worker compat; live API uses compact"},
		"review": {"decision": "KEEP|ADVANCE_PHASE|AMEND_PLAN|EMERGENCY_REPLAN (required)",
			"reason": "string (optional, audited)", "next_phase_id": "ADVANCE target override (optional)",
			"phases": "compact full array (AMEND required; legacy accepted)", "objective+phases": "EMERGENCY compact (required)",
			"hypotheses": "array (optional)", "snapshot_id": "string (optional echo)"},
		"rejection_codes": REJECTION_CODES.duplicate(),
	}


## Parse a VICTORY_INITIAL reply. ctx: {"turn": int, "snapshot_id": "",
## "roster": [RED unit ids]}. Compact authoring is canonical for live API;
## the legacy full form still parses (DEBUG_AGENT / worker compat).
static func parse_initial(text: String, ctx: Dictionary = {}) -> Dictionary:
	if text.strip_edges().is_empty():
		return _fail("VP_INVALID_JSON", "General returned an empty response.")
	var doc := ResponseCls.extract_json(text)
	if doc.is_empty():
		return _fail("VP_INVALID_JSON", "General response is not a JSON object (%s)." % json_error_hint(text))
	var stale := _stale_echo(doc, str(ctx.get("snapshot_id", "")))
	if AuthoringCls.is_compact_doc(doc):
		var authored := AuthoringCls.author_initial(doc, ctx)
		if not bool(authored.get("ok", false)):
			return {"ok": false, "code": str(authored.get("code", "VP_INVALID_SCHEMA")),
				"detail": str(authored.get("detail", "")), "stale_snapshot": stale, "plan": {},
				"contract": AuthoringCls.AUTHORING_VERSION}
		if stale:
			return {"ok": false, "code": "VP_STALE_SNAPSHOT", "detail": "Snapshot echo does not match the live snapshot.",
				"stale_snapshot": true, "plan": {}, "contract": AuthoringCls.AUTHORING_VERSION}
		return {"ok": true, "code": "", "detail": "", "stale_snapshot": false, "plan": authored.get("plan", {}),
			"contract": AuthoringCls.AUTHORING_VERSION}
	var checked := VictoryPlanCls.validate_plan(doc, ctx)
	if not bool(checked.get("ok", false)):
		return {"ok": false, "code": str(checked.get("code", "VP_INVALID_SCHEMA")),
			"detail": str(checked.get("detail", "")), "stale_snapshot": stale, "plan": {}, "contract": "victory_plan_v1"}
	if stale:
		return {"ok": false, "code": "VP_STALE_SNAPSHOT", "detail": "Snapshot echo does not match the live snapshot.",
			"stale_snapshot": true, "plan": {}, "contract": "victory_plan_v1"}
	return {"ok": true, "code": "", "detail": "", "stale_snapshot": false, "plan": checked.get("plan", {}),
		"contract": "victory_plan_v1"}


## First-error locator for unparseable replies (diagnostics only): line +
## message of the raw text's JSON failure, so the next VP_INVALID_JSON is
## conclusive (truncation shows as an end-of-input error on the last line).
static func json_error_hint(text: String) -> String:
	var t := text.strip_edges()
	if t.is_empty():
		return "empty reply"
	var braces := t.count("{") - t.count("}")
	var brackets := t.count("[") - t.count("]")
	var tail := t.right(60).replace("\n", " ")
	if braces > 0 or brackets > 0:
		return "ends abruptly (unclosed {: +%d, [: +%d; tail: '%s'); likely output truncation" % [braces, brackets, tail]
	var j := JSON.new()
	var err := j.parse(t)
	if err != OK:
		return "line %d: %s" % [j.get_error_line(), j.get_error_message()]
	return "extracted span unparseable; tail: '%s'" % tail


## Bounded repair-retry system prompt: the retry must be DIFFERENT — it
## names the failure (incl. probable truncation), demands compact JSON
## only with shorter strings, and forbids prose/fences/reasoning text.
static func build_repair_prompt(code: String, detail: String, finish_reason: String, final_chars: int) -> String:
	var trunc_note := ""
	if finish_reason.strip_edges().to_lower() in ["length", "max_tokens"]:
		trunc_note = " Your previous reply was CUT OFF at the output token limit (finish=%s, %d chars received): it MUST be shorter." % [finish_reason, final_chars]
	elif final_chars <= 0:
		trunc_note = " Your previous reply carried no usable text."
	# SELFPLAY V1: the repair prompt REPLACES the system prompt that carries
	# the compact structural spec, so it must restate the required keys —
	# otherwise local models keep packet values but invent structure
	# (observed: plan_name/num/title instead of objective/phases/*).
	var schema := " Required top-level keys: objective, end_state, cadence, doctrine[6 numbers], phases[]. Phase keys: id, name, purpose, intent, groups{NAME:[unit_ids]}, missions[], win[], lose[], abort[], next, on_fail, reserve[], release[], exploit. Mission keys: task, area, units[], vs|target|zone, preserve, win[], stop[]. Branch 'then' responses: only REQUEST_REVIEW, HOLD_PHASE, RELEASE_RESERVE or NOTE_ONLY (never EXECUTE_Px / ADVANCE / invented actions). Never invent keys (no plan_name/num/title/next_trigger/conditions/targets). Close every brace: one } per {, no }} at phase end."
	# Length-aware brevity: only a truncated reply must be shorter; a
	# complete-but-defective reply must keep full detail and fix ONLY the
	# named defect (observed: "shorten" on complete replies yields rushed,
	# sloppy rewrites that fail again).
	var brevity := "Shorten every string, "
	if trunc_note.is_empty():
		brevity = "Keep the full plan with all phases/missions/conditions; fix ONLY the named defect. "
	return "REPAIR RETRY — your previous VictoryPlan output was rejected (%s: %s).%s Reply with ONLY the compact authoring JSON object: no Markdown, no code fences, no commentary, no reasoning text. %skeep 2-4 phases with their missions/conditions, preserve the strategic meaning, use only real unit ids/tasks/triggers from the packet.%s" % [code, detail.left(220), trunc_note, brevity, schema]


## Parse a VICTORY_REVIEW reply. ctx: {"turn": int, "snapshot_id": "",
## "roster": [RED unit ids]}. Structural validation only; lifecycle rules
## (history immutability, advance targets) are enforced by the mission
## manager at commit time. AMEND/EMERGENCY accept compact authoring
## (expanded canonically) or the legacy full form.
static func expand_amend_patch(patch: Array, authoring: Dictionary) -> Dictionary:
	var phases: Array = (authoring.get("phases", []) as Array).duplicate(true)
	if phases.is_empty():
		return {"ok": false, "detail": "no current plan to patch"}
	if patch.is_empty() or patch.size() > 6:
		return {"ok": false, "detail": "patch needs 1..6 entries"}
	for p_val in patch:
		if not p_val is Dictionary:
			return {"ok": false, "detail": "patch entry is not an object"}
		var p: Dictionary = p_val
		var pid := str(p.get("phase", "")).strip_edges().to_upper()
		var ph: Dictionary = {}
		for ph_val in phases:
			if ph_val is Dictionary and str((ph_val as Dictionary).get("id", "")).to_upper() == pid:
				ph = ph_val
		if ph.is_empty():
			return {"ok": false, "detail": "patch phase '%s' not in plan" % pid}
		var mv: Variant = p.get("mission", 0)
		var idx := int(mv) - 1 if (mv is int or mv is float) else int(str(mv).strip_edges().to_upper().trim_prefix("M")) - 1
		var missions: Array = ph.get("missions", [])
		if idx < 0 or idx >= missions.size():
			return {"ok": false, "detail": "patch mission %s out of range for %s" % [str(mv), pid]}
		var m: Dictionary = missions[idx]
		var changed := false
		for key in ["task", "area", "vs"]:
			if p.has(key):
				m[key] = str(p[key]).strip_edges().to_upper()
				changed = true
		if p.has("vs"):  # a new target class replaces any pinned target/zone
			m.erase("target")
			m.erase("zone")
		if p.has("priority"):
			m["priority"] = str(p["priority"]).strip_edges().to_lower()
			changed = true
		if not changed:
			return {"ok": false, "detail": "patch entry changes nothing"}
	return {"ok": true, "phases": phases}


static func parse_review(text: String, ctx: Dictionary = {}) -> Dictionary:
	if text.strip_edges().is_empty():
		return _fail("VP_INVALID_JSON", "General returned an empty response.")
	var doc := ResponseCls.extract_json(text)
	if doc.is_empty():
		return _fail("VP_INVALID_JSON", "General response is not a JSON object (%s)." % json_error_hint(text))
	var stale := _stale_echo(doc, str(ctx.get("snapshot_id", "")))
	var decision := str(doc.get("decision", "")).strip_edges().to_upper()
	if decision.is_empty():
		return _fail("VP_DECISION", "Review response needs a 'decision' (KEEP|ADVANCE_PHASE|AMEND_PLAN|EMERGENCY_REPLAN).")
	if not decision in VictoryPlanCls.DECISIONS:
		return _fail("VP_DECISION", "Unknown decision '%s'." % str(doc.get("decision", "")))
	var reason := str(doc.get("reason", "")).strip_edges().left(280)
	var hyps := _parse_hypotheses(doc.get("opponent_hypotheses", []))
	var review := {"decision": decision, "reason": reason, "hypotheses": hyps.get("hypotheses", []),
		"has_hypotheses": doc.has("opponent_hypotheses"), "warnings": hyps.get("warnings", [])}
	if decision == "KEEP":
		if stale:
			return _stale_fail()
		return {"ok": true, "code": "", "detail": "", "stale_snapshot": false, "review": review, "warnings": hyps.get("warnings", [])}
	if decision == "ADVANCE_PHASE":
		review["next_phase_id"] = str(doc.get("next_phase_id", "")).strip_edges().to_upper().left(8)
		if stale:
			return _stale_fail()
		return {"ok": true, "code": "", "detail": "", "stale_snapshot": false, "review": review, "warnings": hyps.get("warnings", [])}
	if decision == "AMEND_PLAN":
		# AMEND PATCH (contextual Brain, 2026-10-02): {"patch": [{"phase", "mission" (1-based or "M02"),
		# "task"?, "area"?, "vs"?, "priority"?}]} is expanded onto the CURRENT compact plan (ctx.plan_authoring,
		# passed only when the context pack is on). Completed phases are carried unchanged by construction.
		if not doc.get("phases") is Array and doc.get("patch") is Array and (ctx.get("plan_authoring", {}) as Dictionary).has("phases"):
			var ex := expand_amend_patch(doc.get("patch", []), ctx.get("plan_authoring", {}))
			if not bool(ex.get("ok", false)):
				return _fail("VP_PATCH", str(ex.get("detail", "")))
			doc["phases"] = ex.get("phases", [])
			review["patched"] = true
		if not doc.get("phases") is Array or (doc.get("phases") as Array).is_empty():
			return _fail("VP_PHASES", "AMEND_PLAN needs a full 'phases' array (past phases carried unchanged).")
		if AuthoringCls.is_compact_doc(doc):
			var authored := AuthoringCls.author_phases(doc.get("phases", []), ctx)
			if not bool(authored.get("ok", false)):
				return {"ok": false, "code": str(authored.get("code", "VP_PHASE")), "detail": str(authored.get("detail", "")),
					"stale_snapshot": stale, "review": {}}
			review["phases"] = authored.get("phases", [])
			review["contract"] = AuthoringCls.AUTHORING_VERSION
		else:
			var phases: Array = []
			var seen := {}
			for ph_val in (doc.get("phases") as Array):
				var one := VictoryPlanCls.validate_phase(ph_val)
				if not bool(one.get("ok", false)):
					return {"ok": false, "code": str(one.get("code", "VP_PHASE")), "detail": str(one.get("detail", "")),
						"stale_snapshot": stale, "review": {}}
				var ph: Dictionary = one.get("phase", {})
				if seen.has(str(ph.get("phase_id", ""))):
					return _fail("VP_PHASES", "Duplicate phase_id '%s'." % str(ph.get("phase_id", "")))
				seen[str(ph.get("phase_id", ""))] = true
				phases.append(ph)
				if phases.size() >= VictoryPlanCls.MAX_PHASES:
					break
			review["phases"] = phases
			review["contract"] = "victory_plan_v1"
		if stale:
			return _stale_fail()
		return {"ok": true, "code": "", "detail": "", "stale_snapshot": false, "review": review, "warnings": hyps.get("warnings", [])}
	# EMERGENCY_REPLAN: full replacement body under initial rules (compact
	# canonical for live API, legacy full form still accepted).
	if AuthoringCls.is_compact_doc(doc):
		var authored2 := AuthoringCls.author_initial(doc, ctx)
		if not bool(authored2.get("ok", false)):
			return {"ok": false, "code": str(authored2.get("code", "VP_INVALID_SCHEMA")),
				"detail": "EMERGENCY_REPLAN body: " + str(authored2.get("detail", "")), "stale_snapshot": stale, "review": {}}
		review["plan_body"] = authored2.get("plan", {})
		review["contract"] = AuthoringCls.AUTHORING_VERSION
	else:
		var checked := VictoryPlanCls.validate_plan(doc, ctx)
		if not bool(checked.get("ok", false)):
			return {"ok": false, "code": str(checked.get("code", "VP_INVALID_SCHEMA")),
				"detail": "EMERGENCY_REPLAN body: " + str(checked.get("detail", "")), "stale_snapshot": stale, "review": {}}
		review["plan_body"] = checked.get("plan", {})
		review["contract"] = "victory_plan_v1"
	if stale:
		return _stale_fail()
	return {"ok": true, "code": "", "detail": "", "stale_snapshot": false, "review": review, "warnings": hyps.get("warnings", [])}


static func _stale_echo(doc: Dictionary, want: String) -> bool:
	var echo := str(doc.get("snapshot_id", doc.get("snapshot", ""))).strip_edges()
	var want_s := want.strip_edges()
	return not echo.is_empty() and not want_s.is_empty() and echo != want_s


static func _stale_fail() -> Dictionary:
	return {"ok": false, "code": "VP_STALE_SNAPSHOT", "detail": "Snapshot echo does not match the live snapshot.",
		"stale_snapshot": true, "review": {}}


## Lenient hypotheses: malformed entries drop with a warning, never fatal.
static func _parse_hypotheses(h_val: Variant) -> Dictionary:
	if h_val == null or (h_val is Array and (h_val as Array).is_empty()):
		return {"hypotheses": [], "warnings": []}
	if not h_val is Array:
		return {"hypotheses": [], "warnings": ["DROPPED_HYPOTHESES reason=not-an-array"]}
	var out: Array = []
	var warnings: Array = []
	for e_val in (h_val as Array):
		if not e_val is Dictionary:
			warnings.append("DROPPED_HYPOTHESIS reason=not-an-object")
			continue
		var e: Dictionary = e_val
		var hname := str(e.get("h", e.get("hypothesis", ""))).strip_edges().to_upper().left(64)
		if hname.is_empty():
			warnings.append("DROPPED_HYPOTHESIS reason=missing-hypothesis-key")
			continue
		var conf := 0.5
		var craw: Variant = e.get("conf", e.get("confidence", 0.5))
		if (craw is int or craw is float) and not craw is bool:
			conf = clampf(float(craw), 0.0, 1.0)
		var ev: Array = []
		if e.get("ev", e.get("evidence", [])) is Array:
			for x in (e.get("ev", e.get("evidence", [])) as Array):
				ev.append(str(x).strip_edges().left(160))
				if ev.size() >= 6:
					break
		out.append({"hypothesis": hname, "confidence": conf, "evidence": ev})
		if out.size() >= 4:
			break
	return {"hypotheses": out, "warnings": warnings}


static func _fail(code: String, detail: String) -> Dictionary:
	return {"ok": false, "code": code, "detail": detail, "stale_snapshot": false, "review": {}, "plan": {}}


static func render_summary(parsed: Dictionary) -> String:
	if not bool(parsed.get("ok", false)):
		return "VICTORY RESPONSE REJECT %s: %s" % [str(parsed.get("code", "?")), str(parsed.get("detail", ""))]
	if parsed.has("plan") and not (parsed.get("plan", {}) as Dictionary).is_empty():
		return "VICTORY RESPONSE OK (INITIAL)\n" + VictoryPlanCls.render_summary(parsed.get("plan", {}))
	return "VICTORY RESPONSE OK (REVIEW decision=%s)" % str((parsed.get("review", {}) as Dictionary).get("decision", "?"))
