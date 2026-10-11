class_name Cloud2Utility
extends RefCounted

## CLOUD-GENERAL MISSION HIERARCHY — bounded utility scoring for missions.
##
## ONE scoring table shared by every MissionController instance. Behavior
## varies through the assigned mission, doctrine parameters, and live
## battlefield features — never through per-agent special cases. All
## weights live in DEFAULT_WEIGHTS (observable + tunable); scoring is
## deterministic except for seeded tie-breaking among near-equal
## candidates (same seed + same state = same choice).
##
## Pure math. No network, no game truth, no mutation.

## Centralized weights. Scores land on a 0..100 scale; terms are small on
## purpose — these are initial tunables, not frozen doctrine.
const DEFAULT_WEIGHTS := {
	"attack_kill": 30.0,
	"attack_matchup": 15.0,
	"attack_pressure": 10.0,
	"attack_aggression": 12.0,
	"attack_designated": 8.0,
	"attack_class_match": 8.0,
	"attack_advantage": 6.0,
	"attack_loss": -25.0,
	"attack_preserve": -10.0,
	"attack_overextension": -8.0,
	"attack_fix_contact": 14.0,
	"attack_flank_exploit": 14.0,
	"advance_progress": 25.0,
	"advance_pressure": 10.0,
	"advance_tempo": 10.0,
	"advance_aggression": 6.0,
	"advance_task_fit": 15.0,
	"advance_fix_approach": 18.0,
	"advance_exposure": -15.0,
	"advance_break": -10.0,
	"advance_preserve": -8.0,
	"hold_defense": 30.0,
	"hold_fit": 15.0,
	"hold_reserve": 12.0,
	"hold_calm": 8.0,
	"hold_opportunity": -15.0,
	"withdraw_threat": 30.0,
	"withdraw_preserve": 12.0,
	"withdraw_hold_pressure": -20.0,
	"withdraw_retreat_cost": -8.0,
}

## Which candidate actions each mission task may consider, in evaluation
## order (order carries no score weight; the utility number decides).
const CANDIDATES_BY_TASK := {
	"HOLD": ["HOLD", "ATTACK", "REPOSITION"],
	"ADVANCE": ["ATTACK", "ADVANCE", "HOLD"],
	"FIX": ["ATTACK", "ADVANCE", "HOLD", "REPOSITION"],
	"ATTACK": ["ATTACK", "ADVANCE", "HOLD"],
	"FLANK": ["ATTACK", "ADVANCE", "HOLD"],
	"RECON": ["ADVANCE", "ATTACK", "WITHDRAW", "HOLD"],
	"RESERVE": ["HOLD", "ATTACK"],
	"WITHDRAW": ["WITHDRAW", "HOLD"],
}

## Score gap inside which the top candidates enter seeded weighted choice.
const TIE_MARGIN := 6.0


static func default_weights() -> Dictionary:
	return DEFAULT_WEIGHTS.duplicate(true)


static func candidates_for_task(task: String) -> Array:
	return (CANDIDATES_BY_TASK.get(task.strip_edges().to_upper(), ["HOLD"]) as Array).duplicate()


## Score one candidate. features carries 0..1-normalized inputs (documented
## per kind below); doctrine carries the General's 0..1 parameters.
## Returns {score, parts} with every term exposed for the trace.
static func score_candidate(kind: String, features: Dictionary, doctrine: Dictionary, weights: Dictionary) -> Dictionary:
	match kind.strip_edges().to_upper():
		"ATTACK":
			return _score_attack(features, doctrine, weights)
		"ADVANCE", "REPOSITION":
			return _score_move(kind, features, doctrine, weights)
		"WITHDRAW":
			return _score_withdraw(features, doctrine, weights)
	return _score_hold(features, doctrine, weights)


## ATTACK features: kill (0..1), loss (0..1), matchup_edge (-1..1 normalized
## to 0..1 by caller), pressure (0..1), designated (0/1), class_match (0/1),
## fix_contact (0/1 — mission-conditioned FIX pressure on the designated
## target, set by the solver), flank_exploit (0/1 — mission-conditioned
## post-maneuver exploitation of the designated target), advantage (0..1),
## preserve (0/1), overextension (0..1).
static func _score_attack(f: Dictionary, d: Dictionary, w: Dictionary) -> Dictionary:
	var parts := {
		"kill": float(f.get("kill", 0.0)) * float(w.get("attack_kill", 0.0)),
		"matchup": float(f.get("matchup_edge", 0.0)) * float(w.get("attack_matchup", 0.0)),
		"pressure": float(f.get("pressure", 0.0)) * float(w.get("attack_pressure", 0.0)),
		"aggression": float(d.get("aggression", 0.5)) * float(w.get("attack_aggression", 0.0)),
		"designated": float(f.get("designated", 0.0)) * float(w.get("attack_designated", 0.0)),
		"class_match": float(f.get("class_match", 0.0)) * float(w.get("attack_class_match", 0.0)),
		"fix_contact": float(f.get("fix_contact", 0.0)) * float(w.get("attack_fix_contact", 0.0)),
		"flank_exploit": float(f.get("flank_exploit", 0.0)) * float(w.get("attack_flank_exploit", 0.0)),
		"advantage": float(f.get("advantage", 0.0)) * float(w.get("attack_advantage", 0.0)),
		"loss": float(f.get("loss", 0.0)) * float(w.get("attack_loss", 0.0)),
		"preserve": float(f.get("preserve", 0.0)) * float(w.get("attack_preserve", 0.0)),
		"overextension": float(f.get("overextension", 0.0)) * float(w.get("attack_overextension", 0.0)),
	}
	return {"score": clampf(_sum(parts), 0.0, 100.0), "parts": parts}


## ADVANCE/REPOSITION features: progress (0..1 hexes gained toward the
## mission point), pressure, task_fit (0..1 — how strongly the assigned
## mission task calls for movement; mirrors HOLD's mission_fit so a FIX or
## RECON force closes distance instead of camping), fix_approach (0/1 —
## mission-conditioned FIX pre-contact closing term, set by the solver only
## when the resolved destination actually closes on the designated target
## and the actor is healthy), exposure (0..1), formation_break (0..1),
## preserve (0/1).
static func _score_move(kind: String, f: Dictionary, d: Dictionary, w: Dictionary) -> Dictionary:
	var fit := 1.0 if kind.strip_edges().to_upper() == "ADVANCE" else 0.85
	var parts := {
		"progress": float(f.get("progress", 0.0)) * float(w.get("advance_progress", 0.0)) * fit,
		"pressure": float(f.get("pressure", 0.0)) * float(w.get("advance_pressure", 0.0)),
		"tempo": float(d.get("tempo", 0.5)) * float(w.get("advance_tempo", 0.0)) * fit,
		"task_fit": float(f.get("task_fit", 0.5)) * float(w.get("advance_task_fit", 0.0)),
		"fix_approach": float(f.get("fix_approach", 0.0)) * float(w.get("advance_fix_approach", 0.0)),
		"aggression": float(d.get("aggression", 0.5)) * float(w.get("advance_aggression", 0.0)),
		"exposure": float(f.get("exposure", 0.0)) * float(w.get("advance_exposure", 0.0)),
		"formation_break": float(f.get("formation_break", 0.0)) * float(w.get("advance_break", 0.0)),
		"preserve": float(f.get("preserve", 0.0)) * float(w.get("advance_preserve", 0.0)),
	}
	return {"score": clampf(_sum(parts), 0.0, 100.0), "parts": parts}


## HOLD features: defense (0..1), mission_fit (0..1), opportunity (0..1 —
## value of the best forgone attack/move, dampens camping).
static func _score_hold(f: Dictionary, d: Dictionary, w: Dictionary) -> Dictionary:
	var parts := {
		"defense": float(f.get("defense", 0.5)) * float(w.get("hold_defense", 0.0)),
		"mission_fit": float(f.get("mission_fit", 0.5)) * float(w.get("hold_fit", 0.0)),
		"reserve": float(d.get("reserve_discipline", 0.5)) * float(w.get("hold_reserve", 0.0)),
		"calm": (1.0 - float(d.get("tempo", 0.5))) * float(w.get("hold_calm", 0.0)),
		"opportunity": float(f.get("opportunity", 0.0)) * float(w.get("hold_opportunity", 0.0)),
	}
	var total := clampf(_sum(parts), 0.0, 100.0)
	# Damping MARKER (excluded from the sum above; the split applies it as a
	# factor on base+doctrine): the solver damps HOLD camping when a
	# mission-conditioned contact bonus is live (FIX pressure / FLANK exploit).
	var damp := clampf(float(f.get("hold_damp", 0.0)), 0.0, 1.0)
	if damp > 0.0:
		parts["hold_damp"] = damp
	return {"score": total, "parts": parts}


## WITHDRAW features: threat (0..1), hold_pressure (0..1 — mission reasons
## to stay), preserve (0/1), retreat_cost (0..1 — ground already paid for).
static func _score_withdraw(f: Dictionary, d: Dictionary, w: Dictionary) -> Dictionary:
	var parts := {
		"threat": float(f.get("threat", 0.0)) * float(w.get("withdraw_threat", 0.0)),
		"preserve": (float(f.get("preserve", 0.0)) + float(d.get("risk_tolerance", 0.5)) * 0.5) * float(w.get("withdraw_preserve", 0.0)),
		"hold_pressure": float(f.get("hold_pressure", 0.0)) * float(w.get("withdraw_hold_pressure", 0.0)),
		"retreat_cost": float(f.get("retreat_cost", 0.0)) * float(w.get("withdraw_retreat_cost", 0.0)),
	}
	return {"score": clampf(_sum(parts), 0.0, 100.0), "parts": parts}


static func _sum(parts: Dictionary) -> float:
	var total := 0.0
	for k in parts.keys():
		total += float(parts[k])
	return total


## Deterministic best pick with BOUNDED stochasticity: the top candidate
## wins outright unless rivals land inside TIE_MARGIN of it, in which case
## a seeded weighted roll decides among the tied set only. scored is an
## array of {score, ...} sorted or not; seed should mix battle/turn/mission
## (see Cloud2MissionController.tie_seed). Same inputs = same pick.
static func pick_best(scored: Array, seed_value: int, margin: float = TIE_MARGIN) -> Dictionary:
	if scored.is_empty():
		return {"index": -1, "rolled": false, "seed": seed_value, "margin": margin, "tied": []}
	var top := 0
	for i in range(scored.size()):
		if float((scored[i] as Dictionary).get("score", 0.0)) > float((scored[top] as Dictionary).get("score", 0.0)):
			top = i
	var top_score := float((scored[top] as Dictionary).get("score", 0.0))
	var tied: Array = []
	for i in range(scored.size()):
		if top_score - float((scored[i] as Dictionary).get("score", 0.0)) <= margin:
			tied.append(i)
	if tied.size() <= 1:
		return {"index": top, "rolled": false, "seed": seed_value, "margin": margin, "tied": tied}
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var total := 0.0
	for i in tied:
		total += maxf(0.01, float((scored[int(i)] as Dictionary).get("score", 0.0)))
	var roll := rng.randf() * total
	var acc := 0.0
	var chosen: int = tied[0]
	for i in tied:
		acc += maxf(0.01, float((scored[int(i)] as Dictionary).get("score", 0.0)))
		if roll <= acc:
			chosen = int(i)
			break
	return {"index": chosen, "rolled": true, "seed": seed_value, "margin": margin, "tied": tied, "roll": roll}
