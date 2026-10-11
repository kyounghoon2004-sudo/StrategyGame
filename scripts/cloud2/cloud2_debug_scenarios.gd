class_name Cloud2DebugScenarios
extends RefCounted

## AGENT-AS-GENERAL DEBUG HARNESS — deterministic scenario seam.
##
## Pure builders: scenario id -> SimController.load_scenario dict + harness
## policy. Scenario setup (world truth: placement, HP, threat geometry) is
## separated from General response generation (RED-authorized packets only).
##
## READY scenarios prove the seam this gate; RESERVED ids are declared for
## the NEXT gate (HQ Threat + Cooperative Attack diagnostic) and fail closed
## with a precise code instead of silently substituting another setup.

const SCENARIO_SEED := 11

const STATUS_READY := "READY"
const STATUS_RESERVED := "RESERVED"

const BLUE_STATIONARY := "stationary"
const BLUE_ADVANCE := "advance"
const BLUE_AGGRESSIVE := "aggressive"


static func list_scenarios() -> Array:
	return [
		{"id": "HQ_SAFE", "status": STATUS_READY,
			"description": "Baseline: RED and BLUE out of combat range; HQ unthreatened. Expects planning without threat triggers."},
		{"id": "HQ_THREATENED", "status": STATUS_READY,
			"description": "One BLUE cavalry pushed mid-map toward the RED HQ; threat develops within a few turns. BLUE advances."},
		{"id": "HQ_ATTACKED", "status": STATUS_READY,
			"description": "BLUE infantry + cavalry start in striking distance of the RED HQ and attack aggressively from turn 1."},
		{"id": "HQ_CRITICAL", "status": STATUS_READY,
			"description": "HQ_ATTACKED geometry plus a weakened RED HQ garrison; HQ survival pressure from the first review."},
		{"id": "COOP_BASELINE", "status": STATUS_READY,
			"description": "One BLUE infantry isolated forward with RED fast forces on its flank; baseline cooperation geometry, BLUE stationary."},
		{"id": "COOP_OPPORTUNITY", "status": STATUS_RESERVED,
			"description": "Reserved for the next gate: a timed cooperation opportunity window."},
		{"id": "COOP_REQUIRED", "status": STATUS_RESERVED,
			"description": "Reserved for the next gate: cooperation required to avoid loss."},
	]


static func is_ready(scenario_id: String) -> bool:
	for row in list_scenarios():
		if str(row.get("id", "")) == scenario_id.strip_edges().to_upper():
			return str(row.get("status", "")) == STATUS_READY
	return false


static func _map() -> Dictionary:
	return {
		"bounds": {"q_min": -32, "q_max": -16, "r_min": -8, "r_max": 8},
		"default_terrain": 0,
		"terrain_overrides": {},
		"river_cells": [],
	}


## Base 7v7 force set. BLUE west (q -30..-28), RED east (q -20..-18),
## minimum pairwise distance 8 (max attack range 3) — out of range.
static func _base_forces() -> Array:
	return [
		{"id": "B_INF_1", "class": "infantry", "faction": "blue", "q": -28, "r": 1, "soldiers": 450},
		{"id": "B_INF_2", "class": "infantry", "faction": "blue", "q": -28, "r": 2, "soldiers": 450},
		{"id": "B_CAV_1", "class": "cavalry", "faction": "blue", "q": -28, "r": 0, "soldiers": 330},
		{"id": "B_SPE_1", "class": "spearman", "faction": "blue", "q": -29, "r": 1, "soldiers": 340},
		{"id": "B_ARC_1", "class": "archer", "faction": "blue", "q": -29, "r": 2, "soldiers": 260},
		{"id": "B_SCT_1", "class": "scout", "faction": "blue", "q": -29, "r": 0, "soldiers": 150},
		{"id": "B_HQ_1", "class": "hq", "faction": "blue", "q": -30, "r": 1, "soldiers": 300},
		{"id": "R_INF_1", "class": "infantry", "faction": "red", "q": -20, "r": -1, "soldiers": 477},
		{"id": "R_INF_2", "class": "infantry", "faction": "red", "q": -20, "r": -2, "soldiers": 477},
		{"id": "R_SPE_1", "class": "spearman", "faction": "red", "q": -20, "r": 0, "soldiers": 340},
		{"id": "R_CAV_1", "class": "cavalry", "faction": "red", "q": -20, "r": -3, "soldiers": 320},
		{"id": "R_ARC_1", "class": "archer", "faction": "red", "q": -19, "r": -2, "soldiers": 290},
		{"id": "R_SCT_1", "class": "scout", "faction": "red", "q": -19, "r": 0, "soldiers": 150},
		{"id": "R_HQ_1", "class": "hq", "faction": "red", "q": -18, "r": -1, "soldiers": 200},
	]


static func _move(forces: Array, unit_id: String, q: int, r: int) -> void:
	for f_val in forces:
		if f_val is Dictionary and str((f_val as Dictionary).get("id", "")) == unit_id:
			(f_val as Dictionary)["q"] = q
			(f_val as Dictionary)["r"] = r


static func _weaken(forces: Array, unit_id: String, soldiers: int) -> void:
	for f_val in forces:
		if f_val is Dictionary and str((f_val as Dictionary).get("id", "")) == unit_id:
			(f_val as Dictionary)["soldiers"] = soldiers


## Build one READY scenario. Returns {ok, code, detail, scenario, policy}.
## policy: {blue_policy, review_every, note}. review_every=0 means reviews
## fire only on production triggers (manager review_due); N>0 forces a
## periodic review at least every N turns (labeled FORCED_PERIODIC).
static func build(scenario_id: String) -> Dictionary:
	var sid := scenario_id.strip_edges().to_upper()
	var forces := _base_forces()
	var policy := {"blue_policy": BLUE_STATIONARY, "review_every": 0, "note": ""}
	match sid:
		"HQ_SAFE":
			policy["note"] = "Baseline geometry; BLUE holds."
		"HQ_THREATENED":
			_move(forces, "B_CAV_1", -23, -1)
			policy["blue_policy"] = BLUE_ADVANCE
			policy["note"] = "BLUE cavalry mid-map, advancing on the RED HQ."
		"HQ_ATTACKED":
			_move(forces, "B_CAV_1", -21, -1)
			_move(forces, "B_INF_1", -22, -1)
			_move(forces, "B_ARC_1", -23, 0)
			policy["blue_policy"] = BLUE_AGGRESSIVE
			policy["note"] = "BLUE strike group in range of the RED HQ; attacks from turn 1."
		"HQ_CRITICAL":
			_move(forces, "B_CAV_1", -21, -1)
			_move(forces, "B_INF_1", -22, -1)
			_move(forces, "B_ARC_1", -23, 0)
			_weaken(forces, "R_HQ_1", 60)
			policy["blue_policy"] = BLUE_AGGRESSIVE
			policy["note"] = "HQ_ATTACKED geometry with a weakened RED HQ garrison (60). HQ survival pressure immediately."
		"COOP_BASELINE":
			_move(forces, "B_INF_1", -24, -1)
			policy["note"] = "One BLUE infantry isolated forward; RED fast wing poised to flank. BLUE holds."
		_:
			for row in list_scenarios():
				if str(row.get("id", "")) == sid:
					return {"ok": false, "code": "SCENARIO_RESERVED",
						"detail": "Scenario '%s' is reserved for the next gate: %s" % [sid, str(row.get("description", ""))],
						"scenario": {}, "policy": {}}
			return {"ok": false, "code": "SCENARIO_UNKNOWN",
				"detail": "Unknown scenario '%s'." % sid, "scenario": {}, "policy": {}}
	var scenario := {
		"scenario_id": "debug_agent_" + sid.to_lower(),
		"scenario_version": "1.0.0",
		"seed": SCENARIO_SEED,
		"mission_contract": {"primary_objective": "destroy_all_red", "turn_limit": 40},
		"map": _map(),
		"forces": forces,
		"start_turn": 1,
	}
	return {"ok": true, "code": "", "detail": "", "scenario": scenario, "policy": policy}
