class_name Cloud2TurnPacket
extends RefCounted

## CLOUD-GENERAL STEP 2 — Model-facing RED turn packet (pure builder).
##
## Compacts the canonical RED observation (Cloud1Observation.build(sim,"red"))
## into the structured packet the Cloud model receives. Adds the action /
## scope / target contracts (live reads from Cloud1ActionTable — never a
## parallel action language), side-relative orientation facts, the previous
## compact plan, and the previous turn summary.
##
## Sends NO screen, NO screenshots, NO World Truth beyond the authorized
## observation, NO UI state, and NO secrets.

const TableCls = preload("res://scripts/cloud1/cloud1_action_table.gd")

const PACKET_VERSION := "cloud2_turn_packet_v1"

## Static action contract, stated ONCE here instead of repeated in every
## per-action catalog row (the packet's available_actions carries only the
## dynamic per-turn parts). Must mirror Cloud1ActionTable constants.
const STATIC_CONTRACT := "STATIC CONTRACT (same every turn):\n- executable actions: ADVANCE, HOLD, WITHDRAW, REPOSITION, ATTACK, FLANK, RECON, CONCENTRATE\n- scope atoms: ALL_FRIENDLY, ALL_COMBAT, CLASS, REGION, FORMATION, UNIT, UNITS, EMPTY; ops: UNION, INTERSECT, DIFF; SELECTED is rejected\n- target types: DIRECTION (direction FORWARD/BACKWARD/LEFT/RIGHT/NORTH/SOUTH/EAST/WEST), HEX (q,r), FORMATION (enemy unit_id), OBJECTIVE, ZONE (CENTER/HQ)\n- stance (optional, default BALANCED): CAUTIOUS, BALANCED, ASSERTIVE, AGGRESSIVE\n- ATTACK requires a FORMATION target naming a visible enemy unit; HOLD takes no target"

const FINAL_FIRST := "FINAL RESPONSE RULES (read first, obey exactly):\n- Be concise: no essay, no Markdown, no code fences.\n- Do NOT restate the battlefield and do NOT show working notes; return the decision directly.\n- The whole reply must be ONE JSON object: {\"plan\": {...}, \"orders\": [...]} with 1-8 orders.\n- Keep plan fields short: objective <= 160 chars, intent <= 240 chars, reconsider_if <= 160 chars.\n- plans/notes are advisory; only orders execute, and only after Godot validation."

const VALID_EXAMPLE := "{\"plan\": {\"objective\": \"Pressure the center\", \"intent\": \"Advance infantry while cavalry flanks\", \"reconsider_if\": \"Enemy cavalry threatens the flank\"}, \"orders\": [{\"action\": \"ADVANCE\", \"scope\": {\"op\": \"CLASS\", \"class\": \"INFANTRY\"}, \"target\": {\"kind\": \"DIRECTION\", \"direction\": \"FORWARD\"}}]}"

const SYSTEM_PROMPT := "You are the RED field general in a deterministic turn-based hex battle.\n\nYour objective is given in the mission contract of the turn packet.\nYou receive only the battlefield information authorized to RED.\nChoose operational orders using ONLY the supplied action, scope, and target schema.\nDo not invent units, coordinates, rules, actions, or hidden information.\nGodot owns legality, pathfinding, combat, and state mutation.\nPrefer coherent multi-unit tactics over unnecessary unit-by-unit micromanagement.\nReturn only the required structured response: {\"plan\": {...}, \"orders\": [...], \"rationale\": {...}}.\n\n" + STATIC_CONTRACT + "\n\n" + FINAL_FIRST + "\n\nOne complete valid reply:\n" + VALID_EXAMPLE

## SYMMETRIC V1: BLUE mirror of the tactical prompt (legacy-direct path).
const SYSTEM_PROMPT_BLUE := "You are the BLUE field general in a deterministic turn-based hex battle.\n\nYour objective is given in the mission contract of the turn packet.\nYou receive only the battlefield information authorized to BLUE.\nChoose operational orders using ONLY the supplied action, scope, and target schema.\nDo not invent units, coordinates, rules, actions, or hidden information.\nGodot owns legality, pathfinding, combat, and state mutation.\nPrefer coherent multi-unit tactics over unnecessary unit-by-unit micromanagement.\nReturn only the required structured response: {\"plan\": {...}, \"orders\": [...], \"rationale\": {...}}.\n\n" + STATIC_CONTRACT + "\n\n" + FINAL_FIRST + "\n\nOne complete valid reply:\n" + VALID_EXAMPLE


## Side selector for the tactical system prompt (default red = legacy).
static func system_prompt_for(side: String) -> String:
	if side.strip_edges().to_lower() == "blue":
		return SYSTEM_PROMPT_BLUE
	return SYSTEM_PROMPT

## Side-relative orientation facts (mirror of Cloud1Compiler._axis_score).
## Absolute compass is map-relative; FORWARD/BACKWARD/LEFT/RIGHT are
## faction-relative. BLUE FORWARD = +q (EAST, toward RED); RED FORWARD = -q
## (WEST, toward BLUE).
const ORIENTATION := {
	"coordinate_system": "axial_flat_top",
	"blue_forward": "+q (EAST, toward the RED side)",
	"red_forward": "-q (WEST, toward the BLUE side)",
	"absolute": {
		"NORTH": "map-relative (-axial_y)",
		"SOUTH": "map-relative (+axial_y)",
		"EAST": "map-relative (+q)",
		"WEST": "map-relative (-q)",
	},
	"relative_note": "FORWARD/BACKWARD/LEFT/RIGHT resolve relative to the acting faction. For RED, FORWARD advances toward BLUE; BACKWARD withdraws toward the RED rear; LEFT/RIGHT are mirrored versus BLUE (a 180-degree facing).",
}


static func scope_contract() -> Dictionary:
	return {
		"kind_form": {"kinds": TableCls.SCOPE_KINDS.duplicate()},
		"ast_form": {
			"atoms": ["ALL_FRIENDLY", "ALL_COMBAT", "CLASS", "REGION", "FORMATION", "UNIT", "UNITS", "EMPTY"],
			"ops": ["UNION", "INTERSECT", "DIFF"],
			"note": "SELECTED is a human map pointer and is rejected for Cloud orders; use explicit UNIT/UNITS ids from friendly_units.",
		},
		"classes": TableCls.KNOWN_CLASSES.duplicate(),
		"regions": ["NORTH", "CENTER", "SOUTH", "WEST", "EAST"],
		"example": {"op": "INTERSECT", "args": [{"op": "CLASS", "class": "CAVALRY"}, {"op": "REGION", "region": "NORTH"}]},
	}


static func target_contract() -> Dictionary:
	return {
		"types": TableCls.TARGET_TYPES.duplicate(),
		"directions": TableCls.DIRECTIONS.duplicate(),
		"zones": TableCls.ZONES.duplicate(),
		"examples": [
			{"type": "DIRECTION", "direction": "FORWARD"},
			{"type": "FORMATION", "unit_id": "B_INF_1"},
			{"type": "ZONE", "zone": "CENTER"},
			{"type": "HEX", "q": 0, "r": 0},
			{"type": "OBJECTIVE"},
		],
	}


## Build the packet. obs must be a canonical observation dict (side RED);
## catalog from Cloud1ActionTable.build_catalog(obs); plan_mem from
## Cloud2PlanMemory.to_packet(); prev_summary from the last turn ({} if none).
static func build(obs: Dictionary, catalog: Array, plan_mem: Dictionary, prev_summary: Dictionary) -> Dictionary:
	var mission: Dictionary = (obs.get("mission", {}) as Dictionary).duplicate(true)
	var parity: Dictionary = obs.get("parity", {})
	return {
		"packet_version": PACKET_VERSION,
		"schema_version": str(obs.get("schema_version", "")),
		"snapshot_id": str(obs.get("snapshot_id", "")),
		"battle_id": str(obs.get("battle_id", "")),
		"scenario_id": str(obs.get("scenario_id", "")),
		"turn": int(obs.get("turn", 0)),
		"phase": str(obs.get("phase", "ENGAGE")),
		"acting_side": str(obs.get("side", "RED")),
		"mission": mission,
		"battlefield": {
			"board": obs.get("board", {}),
			"regions": ["NORTH (t<1/3)", "CENTER (1/3..2/3)", "SOUTH (t>2/3)"],
			"orientation": ORIENTATION,
		},
		"friendly_units": obs.get("friendly_units", []),
		"enemy_units": obs.get("known_enemy_units", []),
		"recent_events": obs.get("recent_events", []),
		"rules": obs.get("rules", {}),
		"available_actions": compact_catalog(catalog),
		"scope_contract": scope_contract(),
		"target_contract": target_contract(),
		"previous_turn_summary": prev_summary,
		"current_plan": plan_mem,
		"state_version": int(parity.get("state_version", -1)),
	}


## Slim each catalog row to its DYNAMIC per-turn parts (scopes allowed
## now, targets allowed now, executable now, gating note). The STATIC
## parts (movement policies, stances, stance note) are identical in every
## row and stated once in STATIC_CONTRACT instead — same information,
## roughly half the catalog bytes. Step-1 build_catalog is untouched.
static func compact_catalog(catalog: Array) -> Array:
	var out: Array = []
	for row_val in catalog:
		if not row_val is Dictionary:
			continue
		var row: Dictionary = row_val
		var slim := {
			"action_family": str(row.get("action_family", "")),
			"allowed_scopes": row.get("allowed_scopes", []),
			"allowed_targets": row.get("allowed_targets", []),
			"executable": bool(row.get("executable", false)),
		}
		var note := str(row.get("note", "")).strip_edges()
		if not note.is_empty():
			slim["note"] = note
		out.append(slim)
	return out


static func to_json(packet: Dictionary, pretty: bool = false) -> String:
	return JSON.stringify(packet, "  " if pretty else "")


## Structural self-check (builder output only; model output is untrusted).
static func validate_shape(packet: Dictionary) -> Dictionary:
	var required := ["packet_version", "snapshot_id", "battle_id", "turn",
		"acting_side", "mission", "friendly_units", "enemy_units",
		"available_actions", "scope_contract", "target_contract"]
	for k in required:
		if not packet.has(k):
			return {"ok": false, "code": "PACKET_SHAPE", "detail": "Packet misses '%s'." % k}
	if not str(packet.get("acting_side", "")) in ["RED", "BLUE"]:
		return {"ok": false, "code": "PACKET_SIDE", "detail": "Step 2 packets act as RED or BLUE."}
	return {"ok": true, "code": "", "detail": ""}
