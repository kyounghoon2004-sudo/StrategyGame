class_name Cloud1Inspector
extends RefCounted

const ObsCls = preload("res://scripts/cloud1/cloud1_observation.gd")

## CLOUD-GENERAL STEP 1 --Human inspector (developer-facing).
##
## Renders the EXACT canonical observation snapshot in two views:
##   render_text()   --readable unit list / mission / turn / rules / actions
##   render_payload()--raw machine-readable JSON (the model-facing payload)
## Both originate from the same obs Dictionary (single source). The human can
## answer "what exactly would the Cloud model know right now?" with no code.


static func render_text(obs: Dictionary, catalog: Array) -> String:
	var lines: Array = []
	lines.append("== CLOUD STEP 1 --SHARED TACTICAL VIEW ==")
	lines.append("snapshot : %s" % str(obs.get("snapshot_id", "?")))
	lines.append("battle   : %s | scenario: %s | turn: %d | phase: %s | side: %s" % [
		str(obs.get("battle_id", "?")), str(obs.get("scenario_id", "?")),
		int(obs.get("turn", 0)), str(obs.get("phase", "?")), str(obs.get("side", "?")),
	])
	var mission: Dictionary = obs.get("mission", {})
	lines.append("mission  : [%s] %s (status=%s, limit=%d, elapsed=%d)" % [
		str(mission.get("type", "?")), str(mission.get("objective", "?")),
		str(mission.get("status", "?")), int(mission.get("turn_limit", 0)), int(mission.get("turns_elapsed", 0)),
	])
	var board: Dictionary = obs.get("board", {})
	var dims: Dictionary = board.get("dimensions", {})
	lines.append("board    : %s q[%d..%d] r[%d..%d] neutral=%s" % [
		str(board.get("coordinate_system", "?")),
		int(dims.get("q_min", 0)), int(dims.get("q_max", 0)),
		int(dims.get("r_min", 0)), int(dims.get("r_max", 0)),
		str(board.get("neutral_terrain", true)),
	])
	lines.append("")
	lines.append("-- FRIENDLY (%d) --" % (obs.get("friendly_units", []) as Array).size())
	for u_val in (obs.get("friendly_units", []) as Array):
		var u: Dictionary = u_val
		lines.append("  %s %-8s (%3d,%3d) %-10s mp %s/%s atk=%s opts=%d fmt=%s sol=%d %s/%s" % [
			str(u.get("unit_id", "?")), str(u.get("class", "?")),
			int(u.get("q", 0)), int(u.get("r", 0)), str(u.get("status", "?")),
			str(u.get("remaining_mp", "?")), str(u.get("base_mp", "?")),
			"Y" if bool(u.get("can_attack", false)) else "-",
			int(u.get("attack_options", 0)), str(u.get("formation", "?")),
			int(u.get("soldiers", 0)), str(u.get("condition", "?")), str(u.get("morale_band", "?")),
		])
	lines.append("")
	lines.append("-- KNOWN ENEMY (%d; visible + stale only, never hidden truth) --" % (obs.get("known_enemy_units", []) as Array).size())
	for e_val in (obs.get("known_enemy_units", []) as Array):
		var e2: Dictionary = e_val
		lines.append("  %s %-8s (%3d,%3d) %-16s est='%s' seen_t=%d" % [
			str(e2.get("unit_id", "?")), str(e2.get("class", "?")),
			int(e2.get("q", 0)), int(e2.get("r", 0)), str(e2.get("contact_state", "?")),
			str(e2.get("troop_estimate", "?")), int(e2.get("last_seen_turn", 0)),
		])
	lines.append("")
	lines.append("-- RULES (live semantics, no memorized numbers) --")
	var rules: Dictionary = obs.get("rules", {})
	var move: Dictionary = rules.get("movement", {})
	lines.append("  move   : %s" % str(move.get("note", "")))
	lines.append("           %s" % JSON.stringify(move.get("base_mp_by_class", {})))
	var atk: Dictionary = rules.get("attack", {})
	lines.append("  attack : %s" % str(atk.get("note", "")))
	lines.append("           range=%s advantage=%s" % [JSON.stringify(atk.get("range_by_class", {})), JSON.stringify(atk.get("matchup_advantage", []))])
	lines.append("  turn   : %s" % str((rules.get("turn", {}) as Dictionary).get("note", "")))
	lines.append("  mission: %s" % str((rules.get("mission", {}) as Dictionary).get("note", "")))
	lines.append("")
	lines.append("-- ACTION CATALOG (what both Human and Cloud can express) --")
	for row_val in catalog:
		var row: Dictionary = row_val
		lines.append("  %-10s exec=%s scopes=%d targets=%s :: %s" % [
			str(row.get("action_family", "?")),
			"Y" if bool(row.get("executable", false)) else "-",
			(row.get("allowed_scopes", []) as Array).size(),
			JSON.stringify(row.get("allowed_targets", [])),
			str(row.get("note", "")),
		])
	lines.append("")
	var events: Array = obs.get("recent_events", [])
	lines.append("-- RECENT EVENTS (%d) --" % events.size())
	for ev in events.slice(maxi(0, events.size() - 4), events.size()):
		lines.append("  %s" % JSON.stringify(ev))
	lines.append("")
	var parity: Dictionary = obs.get("parity", {})
	lines.append("-- PARITY --")
	lines.append("  fingerprint=%s" % str(parity.get("fingerprint", "?")))
	lines.append("  state_version=%s acting=%s at_turn=%s" % [
		str(parity.get("state_version", "?")), str(parity.get("acting_side", "?")), str(parity.get("generated_at_turn", "?")),
	])
	lines.append("  (Inspector text and model JSON below describe this same snapshot.)")
	return "\n".join(lines)


## Exact serialized model-facing payload (pretty JSON).
static func render_payload(obs: Dictionary) -> String:
	return ObsCls.to_json(obs, true)


## Prove inspector text and payload share one snapshot: the payload parses,
## carries the same snapshot_id/fingerprint, and its tactical core
## re-fingerprints identically.
static func fingerprint_match(obs: Dictionary, payload_text: String) -> Dictionary:
	var parsed: Variant = JSON.parse_string(payload_text)
	if not parsed is Dictionary:
		return {"ok": false, "detail": "Payload is not valid JSON."}
	var p: Dictionary = parsed
	if str(p.get("snapshot_id", "")) != str(obs.get("snapshot_id", "")):
		return {"ok": false, "detail": "snapshot_id mismatch between inspector and payload."}
	var parity: Dictionary = p.get("parity", {})
	if str(parity.get("fingerprint", "")) != str((obs.get("parity", {}) as Dictionary).get("fingerprint", "")):
		return {"ok": false, "detail": "fingerprint mismatch between inspector and payload."}
	var core := {
		"schema_version": str(p.get("schema_version", "")),
		"turn": int(p.get("turn", 0)),
		"friendly_units": p.get("friendly_units", []),
		"known_enemy_units": p.get("known_enemy_units", []),
		"mission": p.get("mission", {}),
	}
	var recomputed := ObsCls.fingerprint_of(core, int(parity.get("state_version", -1)))
	if recomputed != str(parity.get("fingerprint", "")):
		return {"ok": false, "detail": "Payload tactical core does not re-fingerprint identically."}
	return {"ok": true, "detail": "Inspector and payload share snapshot %s." % str(p.get("snapshot_id", ""))}


## Human compilation view: intent -> units -> per-unit outcomes -> result.
static func render_compilation(result: Dictionary) -> String:
	var lines: Array = []
	lines.append("-- OPERATIONAL COMMAND --")
	lines.append("  %s" % JSON.stringify(result.get("command", {})))
	if str(result.get("snapshot_id", "")) != "":
		lines.append("  snapshot: %s (via %s)" % [str(result.get("snapshot_id", "")), str(result.get("effective_action", "?"))])
	if str(result.get("mapping_note", "")) != "":
		lines.append("  mapping : %s" % str(result.get("mapping_note", "")))
	lines.append("  resolved(%d): %s" % [int(result.get("candidate_count", 0)), JSON.stringify(result.get("resolved_units", []))])
	lines.append("-- PLANNED (%d) --" % (result.get("planned", []) as Array).size())
	for p_val in (result.get("planned", []) as Array):
		lines.append("  %s" % JSON.stringify(p_val))
	lines.append("-- PLAN-REJECTED (%d) --" % (result.get("failed", []) as Array).size())
	for f_val in (result.get("failed", []) as Array):
		lines.append("  %s" % JSON.stringify(f_val))
	if result.has("executed_units"):
		lines.append("-- EXECUTED (%d) status=%s --" % [(result.get("executed_units", []) as Array).size(), str(result.get("execution_status", "?"))])
		for x_val in (result.get("executed_units", []) as Array):
			lines.append("  OK  %s" % JSON.stringify(x_val))
		for y_val in (result.get("execution_failed", []) as Array):
			lines.append("  FAIL %s" % JSON.stringify(y_val))
	return "\n".join(lines)


## Research-console presentation helpers (pure rendering over canonical
## observation/plan dictionaries; no tactical semantics, no interpretation).

const CLASS_KR := {"INFANTRY": "보병", "CAVALRY": "기병", "ARCHER": "궁병",
	"SPEARMAN": "창병", "SCOUT": "정찰병", "SIEGE": "공성", "CONSCRIPT": "징집병",
	"HQ": "지휘부"}
const DIR_KR := {"FORWARD": "전방", "BACK": "후방", "LEFT": "좌측", "RIGHT": "우측",
	"NORTH": "북", "SOUTH": "남", "EAST": "동", "WEST": "서"}
const POLICY_KR := {"MINIMAL": "최소", "LIMITED": "제한", "STANDARD": "표준",
	"EXTENDED": "확장", "MAXIMUM": "최대"}
const VERB_KR := {"ADVANCE": "진격", "RECON": "정찰", "FLANK": "우회", "HOLD": "유지",
	"WITHDRAW": "후퇴", "REPOSITION": "재배치", "ATTACK": "공격", "PURSUE": "추격",
	"CONCENTRATE": "집결", "RESERVE": "예비", "PRESSURE": "압박", "SPREAD": "분산"}
const MOVE_LIKE := ["ADVANCE", "RECON", "FLANK", "PRESSURE", "PURSUE",
	"REPOSITION", "WITHDRAW", "CONCENTRATE"]
const MISSION_SHORT := {"destroy_all_red": "Destroy RED", "capture_capital": "Take Capital",
	"survive_turns": "Survive", "hold_hq": "Hold HQ"}


static func mission_short(mtype: String) -> String:
	return str(MISSION_SHORT.get(mtype.strip_edges().to_lower(), mtype))


## Grouped human-readable situation as BBCode (FACT display only).
static func render_situation_bbcode(obs: Dictionary) -> String:
	var L: Array = []
	var mission: Dictionary = obs.get("mission", {})
	L.append("[b][color=#7fd4ff]MISSION[/color][/b]")
	L.append("%s -- %s (status=%s, turn %d)" % [
		mission_short(str(mission.get("type", "?"))), str(mission.get("objective", "?")),
		str(mission.get("status", "?")), int(mission.get("turns_elapsed", 0))])
	L.append("")
	L.append("[b][color=#7fd4ff]TURN STATE[/color][/b]")
	var parity: Dictionary = obs.get("parity", {})
	L.append("%s | Turn %d | %s | state v%s" % [
		str(obs.get("side", "?")), int(obs.get("turn", 0)), str(obs.get("phase", "?")),
		str(parity.get("state_version", "?"))])
	L.append("")
	var friendlies: Array = obs.get("friendly_units", [])
	L.append("[b][color=#7fd4ff]FRIENDLY -- %d[/color][/b]" % friendlies.size())
	for u_val in friendlies:
		var u: Dictionary = u_val
		L.append("[code]%s[/code] %s (%d,%d) %s MP %s/%s %s" % [
			str(u.get("unit_id", "?")), str(u.get("class", "?")),
			int(u.get("q", 0)), int(u.get("r", 0)), str(u.get("status", "?")),
			str(u.get("remaining_mp", "?")), str(u.get("base_mp", "?")),
			str(u.get("formation", "?"))])
	L.append("")
	var enemies: Array = obs.get("known_enemy_units", [])
	var vis := 0
	for e_val in enemies:
		if str((e_val as Dictionary).get("contact_state", "")) == "current_visible":
			vis += 1
	L.append("[b][color=#7fd4ff]KNOWN ENEMY -- %d visible / %d stale[/color][/b]" % [vis, enemies.size() - vis])
	for e2_val in enemies:
		var e2: Dictionary = e2_val
		var stale := str(e2.get("contact_state", "")) != "current_visible"
		L.append("[code]%s[/code] %s (%d,%d) %s" % [
			str(e2.get("unit_id", "?")), str(e2.get("class", "?")),
			int(e2.get("q", 0)), int(e2.get("r", 0)),
			("stale, last seen t%d" % int(e2.get("last_seen_turn", 0))) if stale else "visible"])
	L.append("")
	L.append("[b][color=#7fd4ff]RULES[/color][/b]")
	var rules: Dictionary = obs.get("rules", {})
	var mv: Dictionary = rules.get("movement", {})
	var at: Dictionary = rules.get("attack", {})
	L.append("Move: %s" % str(mv.get("note", "")))
	L.append("Base MP: %s" % JSON.stringify(mv.get("base_mp_by_class", {})))
	L.append("Attack: %s" % str(at.get("note", "")))
	L.append("Range: %s" % JSON.stringify(at.get("range_by_class", {})))
	L.append("Advantage: %s" % JSON.stringify(at.get("matchup_advantage", [])))
	L.append("Turn: %s" % str((rules.get("turn", {}) as Dictionary).get("note", "")))
	L.append("")
	L.append("[b][color=#7fd4ff]RECENT EVENTS[/color][/b]")
	var events: Array = obs.get("recent_events", [])
	if events.is_empty():
		L.append("(none)")
	for ev in events.slice(maxi(0, events.size() - 4), events.size()):
		L.append(str(JSON.stringify(ev)))
	return "\n".join(L)


## Structured-command to readable-label rendering only (no NL parsing).
static func summarize_command_kr(cmd: Dictionary, selected_id: String = "") -> String:
	var action := str(cmd.get("action", "")).strip_edges().to_upper()
	var scope: Dictionary = cmd.get("scope", {})
	var target: Dictionary = cmd.get("target", {})
	var policy := str(cmd.get("movement_policy", "STANDARD")).strip_edges().to_upper()
	var verb := str(VERB_KR.get(action, action))
	var scope_txt := _scope_kr(scope, selected_id)
	var target_txt := _target_kr(action, target)
	if action == "ATTACK":
		return "%s %s 공격" % [scope_txt, str(target.get("unit_id", "?"))]
	if action == "FLANK" and str(target.get("type", "")) == "FORMATION":
		return "%s로 %s 측면을 우회" % [scope_txt, str(target.get("unit_id", "?"))]
	if target_txt.is_empty():
		return "%s %s" % [scope_txt, verb]
	if action in MOVE_LIKE:
		return "%s을 %s %s %s" % [scope_txt, target_txt, str(POLICY_KR.get(policy, policy)), verb]
	return "%s을 %s %s" % [scope_txt, target_txt, verb]


static func _scope_kr(scope: Dictionary, selected_id: String) -> String:
	if scope.has("op"):
		var op := str(scope.get("op", "")).to_upper()
		var args: Array = scope.get("args", [])
		if op == "INTERSECT" and args.size() >= 2:
			return "%s %s" % [_scope_kr(args[1], selected_id), _scope_kr(args[0], selected_id)]
		elif op == "UNION" and args.size() >= 2:
			return "%s 및 %s" % [_scope_kr(args[0], selected_id), _scope_kr(args[1], selected_id)]
		elif op == "DIFF" and args.size() >= 2:
			return "%s (제외: %s)" % [_scope_kr(args[0], selected_id), _scope_kr(args[1], selected_id)]
	match str(scope.get("kind", "")).strip_edges().to_upper():
		"ALL_FRIENDLY":
			return "전군"
		"ALL_COMBAT":
			return "전투군"
		"CLASS":
			var c := str(scope.get("class", scope.get("value", ""))).strip_edges().to_upper()
			return str(CLASS_KR.get(c, c)) + "대"
		"REGION":
			var reg := str(scope.get("region", scope.get("value", ""))).strip_edges().to_upper()
			var ScopeAlgebraScript = load("res://scripts/step7/step7_scope_algebra.gd")
			var r_kr: String = ScopeAlgebraScript.REGION_KR.get(reg, reg) if ScopeAlgebraScript != null else reg
			return r_kr + " 방면"
		"FORMATION":
			return str(scope.get("formation", scope.get("value", "?"))) + " 부대"
		"SELECTED":
			return ("선택한 " + selected_id) if not selected_id.is_empty() else "선택 부대"
		"UNITS":
			var ids: Array = scope.get("unit_ids", scope.get("units", scope.get("value", [])))
			if ids.is_empty():
				return "지정부대"
			if ids.size() == 1:
				return str(ids[0])
			return "%s 외 %d" % [str(ids[0]), ids.size() - 1]
	return "부대"


static func _target_kr(action: String, target: Dictionary) -> String:
	match str(target.get("type", "")).strip_edges().to_upper():
		"DIRECTION":
			var d := str(target.get("direction", "FORWARD")).strip_edges().to_upper()
			if d == "BACKWARD":
				d = "BACK"
			return str(DIR_KR.get(d, d)) + "으로"
		"HEX":
			return "(%d,%d)로" % [int(target.get("q", 0)), int(target.get("r", 0))]
		"ZONE":
			return "중앙으로" if str(target.get("zone", "")).strip_edges().to_upper() == "CENTER" else "HQ로"
		"FORMATION":
			return str(target.get("unit_id", "?")) + " 방향으로"
		"OBJECTIVE":
			return "목표 방향으로"
	return ""


## Compact preview counts for the builder summary + RESULT tab header.
static func preview_summary(plan: Dictionary) -> Dictionary:
	var planned: Array = plan.get("planned", [])
	var failed: Array = plan.get("failed", [])
	var moves := 0
	var holds := 0
	var attacks := 0
	for p_val in planned:
		match str((p_val as Dictionary).get("action", "")):
			"MOVE":
				moves += 1
			"HOLD":
				holds += 1
			"ATTACK":
				attacks += 1
	return {
		"ok": bool(plan.get("ok", false)),
		"code": str(plan.get("code", "")),
		"detail": str(plan.get("detail", "")),
		"resolved": (plan.get("resolved_units", []) as Array).size(),
		"planned": planned.size(),
		"moves": moves,
		"holds": holds,
		"attacks": attacks,
		"failed": failed.size(),
	}


## One scannable row: {text, unit_id, tone} with tone in
## ok / hold / fail / warn for restrained status colors.
static func format_preview_row(p: Dictionary) -> Dictionary:
	var uid := str(p.get("unit_id", "?"))
	match str(p.get("action", "")):
		"MOVE":
			var f: Array = p.get("from", [])
			var t: Array = p.get("to", [])
			return {"unit_id": uid, "tone": "ok",
				"text": "[OK] %s MOVE (%s) -> (%s)" % [uid, _cell_txt(f), _cell_txt(t)]}
		"HOLD":
			return {"unit_id": uid, "tone": "hold", "text": "[--] %s HOLD" % uid}
		"ATTACK":
			return {"unit_id": uid, "tone": "ok",
				"text": "[OK] %s ATTACK %s" % [uid, str(p.get("target_unit_id", "?"))]}
	return {"unit_id": uid, "tone": "warn", "text": "[??] %s" % uid}


static func format_failed_row(f: Dictionary) -> Dictionary:
	var uid := str(f.get("unit_id", "?"))
	var code := str(f.get("code", ""))
	var tone := "warn" if code in ["NO_LEGAL_DESTINATION", "NO_VALID_UNITS", "ALREADY_ACTED", "UNAVAILABLE"] else "fail"
	var tag := "[!!]" if tone == "warn" else "[XX]"
	return {"unit_id": uid, "tone": tone,
		"text": "%s %s %s -- %s" % [tag, uid if not uid.is_empty() else "(scope)", code, str(f.get("detail", ""))]}


static func format_exec_row(kind: String, row: Dictionary) -> Dictionary:
	var uid := str(row.get("unit_id", "?"))
	if kind == "executed":
		var a := str(row.get("action", ""))
		if a == "MOVE":
			return {"unit_id": uid, "tone": "ok",
				"text": "[OK] %s MOVE (%s) -> (%s)" % [uid, _cell_txt(row.get("from", [])), _cell_txt(row.get("to", []))]}
		return {"unit_id": uid, "tone": "ok" if a == "HOLD" else "ok",
			"text": "[OK] %s %s" % [uid, a]}
	return format_failed_row(row)


static func _cell_txt(c: Variant) -> String:
	if c is Array and (c as Array).size() == 2:
		return "%d,%d" % [int((c as Array)[0]), int((c as Array)[1])]
	return "?"
