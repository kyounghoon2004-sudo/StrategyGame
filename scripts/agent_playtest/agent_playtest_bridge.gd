class_name AgentPlaytestBridge
extends Node

## AGENT-MCP-PLAYTEST — live-game tool surface for the external coding agent.
##
## Installed as a deferred child of the live Cloud2BattleTest battle scene
## (see cloud2_mount.gd). The agent reaches it through the MCP toolkit's
## `execute_code` tool with channel="runtime" and scope_path pointed at this
## node, e.g.:
##
##   execute_code {channel:"runtime", scope_path:"Cloud2BattleTest/AgentPlaytestBridge",
##                 code:"agent_command(\"general.get_status\", {})"}
##
## Every handler is a thin adapter over the EXISTING canonical paths:
##   - RED General: Cloud2MissionManager / Cloud2CoordMenu / Cloud2CoordResponse /
##     Cloud2TurnController (EXTERNAL_AGENT backend) / Cloud2GeneralTrace.
##   - BLUE Player: Cloud1Compiler.plan + Cloud1LiveExecutor.execute (side blue)
##     + Step7BattleCommandService previews — the exact human click-flow seam.
##   - Battle: shell turn authority + mission manager observability.
##
## No provider API. No local AI. No parallel tactical AI. Godot stays
## authoritative for every mutation; the agent is only the strategic brain
## (RED) and the player (BLUE) through these structured calls.

const CompilerCls = preload("res://scripts/cloud1/cloud1_compiler.gd")
const ObsCls = preload("res://scripts/cloud1/cloud1_observation.gd")
const CoordResponseCls = preload("res://scripts/cloud2/cloud2_coord_response.gd")
const GeneralTraceCls = preload("res://scripts/cloud2/cloud2_general_trace.gd")
const CoordMenuCls = preload("res://scripts/cloud2/cloud2_coord_menu.gd")

## Bounded by the runtime WS frame (~1MB); reads are windowed above this.
const MAX_PAYLOAD_CHARS := 200000


## Structured envelopes in the canonical MCPToolkit error/success shape, built
## locally (the contract classes are editor-side; this bridge runs in-game).
static func _fail(code: String, message: String, hint: String = "") -> Dictionary:
	var result := {"success": false, "error": message, "code": code}
	if hint != "":
		result["hint"] = hint
	return result


static func _ok(data: Dictionary = {}) -> Dictionary:
	data["success"] = true
	return data


func _ready() -> void:
	print("[AgentPlaytestBridge] ready — call agent_command(<tool>, <args-dict>) here")


# ---- entry -------------------------------------------------------------------

## Single entry point used by execute_code. `args` must be a Dictionary.
func agent_command(tool_name: String, args: Variant = {}) -> Dictionary:
	var t := tool_name.strip_edges()
	var a: Dictionary = args if args is Dictionary else {}
	var kind := t.split(".", true, 1)[0] if t.contains(".") else ""
	var action := t.split(".", true, 1)[1] if t.contains(".") else t
	var ctrl := _ctrl()
	match kind:
		"battle":
			return _battle(action, a, ctrl)
		"general", "agent":
			return _general(action, a, ctrl)
		"player":
			return _player(action, a, ctrl)
		"ping":
			return _ok({"ok": true, "tool": "ping", "bridge": true})
		"_":
			pass
	return _fail("UNKNOWN_TOOL", "Unknown tool '%s' (battle.*, general.*, player.*)." % t)


# ---- resolution ---------------------------------------------------------------

func _ctrl() -> Node:
	var stack: Array = [get_parent()]
	while not stack.is_empty():
		var n: Node = stack.pop_front()
		if n != null and is_instance_valid(n) and n.has_method("run_red_phase") and n.has_method("set_control_mode"):
			return n
		for c in n.get_children():
			stack.append(c)
	return null


func _bridge() -> RefCounted:
	var c := _ctrl()
	if c != null:
		var b: Variant = c.get("_bridge")
		if b != null and b.has_method("is_loaded") and bool(b.call("is_loaded")):
			return b
	return null


func _manager() -> RefCounted:
	var c := _ctrl()
	if c != null:
		var m: Variant = c.get("_manager")
		if m != null and m.has_method("get_plan"):
			return m
	return null


func _executor() -> Node:
	var c := _ctrl()
	if c != null:
		var e: Variant = c.get("_executor")
		if e is Node:
			return e
	return null


func _shell() -> Node:
	var b := _bridge()
	if b != null:
		var s: Variant = b.call("get_shell")
		if s is Node:
			return s
	return null


func _svc() -> RefCounted:
	var b := _bridge()
	if b != null:
		return b.call("get_service")
	return null


func _mgr() -> RefCounted:
	var b := _bridge()
	if b != null:
		return b.call("get_manager")
	return null


func _turn() -> int:
	var m := _mgr()
	if m != null and m.has_method("get_current_turn"):
		return int(m.call("get_current_turn"))
	return 0


func _phase() -> String:
	var shell := _shell()
	if shell == null:
		return "NO_SHELL"
	var p := int(shell.get("_turn_phase"))
	if p == 0:
		return "PLAYER"
	if p == 1:
		return "ENEMY"
	return "UNKNOWN_%d" % p


func _cap(text: String) -> String:
	if text.length() <= MAX_PAYLOAD_CHARS:
		return text
	return text.left(MAX_PAYLOAD_CHARS) + "...[TRUNCATED %d chars]" % (text.length() - MAX_PAYLOAD_CHARS)


func _json(data: Variant) -> String:
	return _cap(JSON.stringify(data))


# ---- battle -------------------------------------------------------------------

func _battle(action: String, a: Dictionary, ctrl: Node) -> Dictionary:
	match action:
		"get_state":
			return _battle_state(ctrl)
		"get_turn":
			return _ok({"ok": true, "tool": "battle.get_turn", "turn": _turn(), "phase": _phase()})
		"restart":
			return _battle_restart(ctrl)
		"get_events":
			return _battle_events()
		"get_summary":
			return _battle_summary(ctrl)
		"get_recent_events":
			return _battle_events()
		"get_scoreboard":
			return _battle_summary(ctrl)
		"export_snapshot":
			return _battle_export()
		"advance_until_player_input":
			return _ok({"ok": true, "note": "Turns advance by player.end_turn; the RED phase runs to completion and control returns to PLAYER phase automatically.", "phase": _phase()})
	return _fail("UNKNOWN_TOOL", "battle.%s" % action)


func _battle_state(ctrl: Node) -> Dictionary:
	var st: Dictionary = ctrl.call("get_state") if ctrl != null and ctrl.has_method("get_state") else {}
	var mode := str(ctrl.get("_control_mode")) if ctrl != null else "?"
	var backend := str(ctrl.get("_agent_backend")) if ctrl != null else "?"
	var manager := _manager()
	var out := {
		"ok": true, "tool": "battle.get_state",
		"turn": _turn(), "phase": _phase(),
		"red_control_mode": mode, "general_backend": backend,
		"cloud_phase": str(st.get("phase", "")), "cloud_note": str(st.get("note", "")),
		"review_pending": bool(st.get("review_pending", false)),
		"pending_event_count": int(st.get("pending_event_count", 0)),
		"plan_version": int((manager.call("get_plan") as Dictionary).get("plan_version", 0)) if manager != null else 0,
		"casualties": _side_strength(),
	}
	return out


func _side_strength() -> Dictionary:
	var out := {"red_formations": 0, "blue_formations": 0, "red_soldiers": 0, "blue_soldiers": 0}
	var m := _mgr()
	if m == null:
		return out
	for u_val in (m.call("get_all_units_including_garrisoned") as Array):
		if not u_val is Dictionary:
			continue
		var u: Dictionary = u_val
		var fac := str(u.get("faction", ""))
		var sol := int(u.get("soldier_count", 0))
		if fac == "red":
			out["red_formations"] = int(out["red_formations"]) + 1
			out["red_soldiers"] = int(out["red_soldiers"]) + sol
		elif fac == "blue":
			out["blue_formations"] = int(out["blue_formations"]) + 1
			out["blue_soldiers"] = int(out["blue_soldiers"]) + sol
	return out


func _battle_restart(ctrl: Node) -> Dictionary:
	if ctrl != null and bool(ctrl.get("_phase_active")):
		return _fail("PHASE_ACTIVE", "A RED phase is running; wait for it to finish.")
	var tree := get_tree()
	if tree == null:
		return _fail("INTERNAL", "no scene tree")
	print("[AgentPlaytest] battle.restart requested")
	tree.reload_current_scene()
	return _ok({"ok": true, "tool": "battle.restart", "note": "Scene reload requested; wait a moment, then re-resolve the bridge node path."})


func _battle_events() -> Dictionary:
	var manager := _manager()
	if manager == null:
		return _fail("NO_CONTROLLER", "MissionManager unavailable.")
	var events: Array = manager.call("get_events")
	var start: int = maxi(0, events.size() - 40)
	return _ok({"ok": true, "tool": "battle.get_events", "total": events.size(),
		"events": (events as Array).slice(start)})


func _battle_summary(ctrl: Node) -> Dictionary:
	var manager := _manager()
	var plan: Dictionary = (manager.call("get_plan") as Dictionary) if manager != null else {}
	var statuses: Array = manager.call("status_rows") if manager != null and manager.has_method("status_rows") else []
	var wakeup: Dictionary = manager.call("wakeup_view") if manager != null and manager.has_method("wakeup_view") else {}
	var out := {
		"ok": true, "tool": "battle.get_summary", "turn": _turn(), "phase": _phase(),
		"strength": _side_strength(),
		"plan_version": int(plan.get("plan_version", 0)),
		"missions": statuses, "wakeup": wakeup,
		"telemetry": (GeneralTraceCls.snapshot() if ctrl != null else {}),
	}
	return out


func _battle_export() -> Dictionary:
	var manager := _manager()
	var payload := {
		"exported_at": Time.get_datetime_string_from_system(),
		"turn": _turn(), "phase": _phase(),
		"plan": (manager.call("get_plan") as Dictionary) if manager != null else {},
		"coordination": (manager.call("get_coordination") as Dictionary) if manager != null else {},
		"events": (manager.call("get_events") as Array) if manager != null else [],
		"strength": _side_strength(),
		"telemetry": GeneralTraceCls.snapshot(),
	}
	var dir := "user://agent_playtest"
	DirAccess.make_dir_recursive_absolute(dir)
	var path := "%s/snapshot_t%d_%d.json" % [dir, _turn(), Time.get_ticks_msec()]
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return _fail("WRITE_FAILED", "Cannot write %s" % path)
	f.store_string(JSON.stringify(payload, "  "))
	f.close()
	return _ok({"ok": true, "tool": "battle.export_snapshot", "path": path, "inline": payload})


# ---- general (RED strategy) ------------------------------------------------------

func _general(action: String, a: Dictionary, ctrl: Node) -> Dictionary:
	if ctrl == null:
		return _fail("NO_CONTROLLER", "Cloud2TurnController not found (is the cloud2 battle scene running?).")
	match action:
		"get_status", "get_backend_status":
			return _general_status(ctrl)
		"set_backend":
			return _general_set_backend(ctrl, a)
		"get_observation":
			return _general_obs()
		"get_coordination_menu", "get_coord_menu":
			return _general_coord_menu()
		"get_current_plan":
			return _general_plan()
		"get_pending_events":
			return _general_pending()
		"submit_initial_coordination":
			return _general_submit_initial(ctrl, a)
		"submit_review":
			return _general_submit_review(ctrl, a)
		"poll_request":
			return _general_poll(ctrl, a)
		"get_execution_trace":
			return _general_trace(ctrl)
		"request_review":
			ctrl.call("request_general_review")
			return _ok({"ok": true, "note": "Manual review requested on the next hierarchy RED turn."})
		"_":
			pass
	return _fail("UNKNOWN_TOOL", "general.%s" % action)


func _general_status(ctrl: Node) -> Dictionary:
	var manager := _manager()
	return _ok({"ok": true, "tool": "general.get_status",
		"control_mode": str(ctrl.get("_control_mode")),
		"backend": str(ctrl.get("_agent_backend")),
		"cloud_phase": str((ctrl.call("get_state") as Dictionary).get("phase", "")),
		"phase_active": bool(ctrl.get("_phase_active")),
		"turn": _turn(), "phase": _phase(),
		"plan_version": int(((manager.call("get_plan") as Dictionary) if manager != null else {}).get("plan_version", 0)),
		"coordination": (manager.call("get_coordination") as Dictionary) if manager != null else {},
		"wakeup": (manager.call("wakeup_view") as Dictionary) if manager != null and manager.has_method("wakeup_view") else {},
		"staged_review": str(ctrl.get("_staged_review_decision")),
		"telemetry": GeneralTraceCls.snapshot()})


func _general_set_backend(ctrl: Node, a: Dictionary) -> Dictionary:
	if not ctrl.has_method("set_agent_backend"):
		return _fail("NOT_INSTALLED", "Controller patch (set_agent_backend) not loaded — restart the game scene after the patch edit.")
	var res: Dictionary = ctrl.call("set_agent_backend", str(a.get("mode", "")))
	if not bool(res.get("ok", false)):
		return _fail(str(res.get("code", "BACKEND_SWITCH_FAILED")), str(res.get("detail", "")))
	return _ok({"ok": true, "tool": "general.set_backend", "backend": res.get("backend", "")})


func _general_obs() -> Dictionary:
	var b := _bridge()
	if b == null:
		return _fail("NO_LIVE_STATE", "Live bridge unavailable.")
	var obs: Dictionary = ObsCls.build(b, "red")
	if not bool(obs.get("ok", false)):
		return _fail("OBSERVATION_FAILED", str(obs.get("error", "")))
	obs["ok"] = true
	obs["tool"] = "general.get_observation"
	return obs


func _general_coord_menu() -> Dictionary:
	var manager := _manager()
	var b := _bridge()
	if manager == null or b == null:
		return _fail("NO_CONTROLLER", "Manager/bridge unavailable.")
	var obs: Dictionary = ObsCls.build(b, "red")
	if not bool(obs.get("ok", false)):
		return _fail("OBSERVATION_FAILED", str(obs.get("error", "")))
	var menu: Dictionary = manager.call("build_coord_menu", obs)
	menu["ok"] = true
	menu["tool"] = "general.get_coordination_menu"
	menu["rendered"] = CoordMenuCls.render_menu_text(menu)
	return menu


func _general_plan() -> Dictionary:
	var manager := _manager()
	if manager == null:
		return _fail("NO_CONTROLLER", "MissionManager unavailable.")
	return _ok({"ok": true, "tool": "general.get_current_plan", "plan": manager.call("get_plan")})


func _general_pending() -> Dictionary:
	var manager := _manager()
	if manager == null:
		return _fail("NO_CONTROLLER", "MissionManager unavailable.")
	return _ok({"ok": true, "tool": "general.get_pending_events", "wakeup": manager.call("wakeup_view"),
		"events_since_review": manager.call("events_since_review") if manager.has_method("events_since_review") else []})


func _general_submit_initial(ctrl: Node, a: Dictionary) -> Dictionary:
	if not ctrl.has_method("agent_submit_initial"):
		return _fail("NOT_INSTALLED", "Controller patch (agent_submit_initial) not loaded.")
	var b := _bridge()
	var manager := _manager()
	if b == null or manager == null:
		return _fail("NO_LIVE_STATE", "Live battle unavailable.")
	var obs: Dictionary = ObsCls.build(b, "red")
	if not bool(obs.get("ok", false)):
		return _fail("OBSERVATION_FAILED", str(obs.get("error", "")))
	var menu: Dictionary = manager.call("build_coord_menu", obs)
	# Canonical contract: build the JSON exactly like the provider reply and
	# let the SAME parser/validators judge it.
	var doc := {
		"request": "INITIAL_COORDINATION",
		"concept": str(a.get("concept", "")),
		"main_effort": str(a.get("main_effort", "ANY")),
		"doctrine_profile": a.get("doctrine_profile", {}),
		"assignments": a.get("assignments", []),
		"review_horizon": a.get("review_horizon", 4),
		"snapshot_id": str(a.get("snapshot_id", obs.get("snapshot_id", ""))),
	}
	var text := JSON.stringify(doc)
	var parsed: Dictionary = CoordResponseCls.parse_initial(text, {"menu": menu, "snapshot_id": str(obs.get("snapshot_id", "")), "turn": _turn()})
	if not bool(parsed.get("ok", false)):
		return _fail(str(parsed.get("code", "COORD_INVALID_SCHEMA")), str(parsed.get("detail", "")) + " | menu: " + CoordMenuCls.render_menu_text(menu))
	var submit: Dictionary = ctrl.call("agent_submit_initial", text)
	if not bool(submit.get("ok", false)):
		return _fail(str(submit.get("code", "SUBMIT_FAILED")), str(submit.get("detail", "")))
	return _ok({"ok": true, "tool": "general.submit_initial_coordination",
		"request_id": submit.get("request_id", ""), "warnings": parsed.get("warnings", []),
		"note": "Parked request completed; the RED phase applies the canonical expansion."})


func _general_submit_review(ctrl: Node, a: Dictionary) -> Dictionary:
	if not ctrl.has_method("agent_submit_review"):
		return _fail("NOT_INSTALLED", "Controller patch (agent_submit_review) not loaded.")
	var decision := str(a.get("decision", "")).strip_edges().to_upper()
	if decision != "KEEP" and decision != "ADJUST" and decision != "REPLAN":
		return _fail("INVALID_DECISION", "decision must be KEEP | ADJUST | REPLAN.")
	var b := _bridge()
	var manager := _manager()
	if b == null or manager == null:
		return _fail("NO_LIVE_STATE", "Live battle unavailable.")
	var doc := {"request": "REVIEW_COORDINATION", "decision": decision, "snapshot_id": str(a.get("snapshot_id", ""))}
	if decision == "ADJUST":
		doc["changes"] = a.get("changes", [])
	elif decision == "REPLAN":
		doc["concept"] = str(a.get("concept", ""))
		doc["main_effort"] = str(a.get("main_effort", "ANY"))
		doc["doctrine_profile"] = a.get("doctrine_profile", {})
		doc["assignments"] = a.get("assignments", [])
		doc["review_horizon"] = a.get("review_horizon", 4)
	var text := JSON.stringify(doc)
	# Local contract pre-check so obvious schema mistakes fail fast with the
	# menu in the error (the controller re-validates identically).
	var menu: Dictionary = (ctrl.get("_agent_parked") as Dictionary).get("menu", {}) if ctrl.get("_agent_parked") is Dictionary else {}
	if not menu.is_empty():
		var parsed: Dictionary = CoordResponseCls.parse_review(text, {"menu": menu,
			"snapshot_id": str((ctrl.get("_agent_parked") as Dictionary).get("packet", {}).get("snapshot_id", "")) if (ctrl.get("_agent_parked") as Dictionary).get("packet", {}) is Dictionary else "",
			"turn": _turn(), "baseline": manager.call("get_coordination"),
			"has_baseline": not (manager.call("get_coordination") as Dictionary).is_empty()})
		if not bool(parsed.get("ok", false)):
			return _fail(str(parsed.get("code", "COORD_INVALID_SCHEMA")), str(parsed.get("detail", "")) + " | menu: " + CoordMenuCls.render_menu_text(menu))
	var submit: Dictionary = ctrl.call("agent_submit_review", text)
	if not bool(submit.get("ok", false)):
		return _fail(str(submit.get("code", "SUBMIT_FAILED")), str(submit.get("detail", "")))
	return _ok({"ok": true, "tool": "general.submit_review", "decision": decision,
		"request_id": submit.get("request_id", ""),
		"note": "Submitted into the parked review request; canonical staging/adoption applies."})


func _general_poll(ctrl: Node, a: Dictionary) -> Dictionary:
	if ctrl.has_method("agent_poll"):
		return _ok({"ok": true, "tool": "general.poll_request", "agent": ctrl.call("agent_poll"),
			"last_view": ctrl.call("get_last_view") if a.get("with_view", false) else {}})
	return _fail("NOT_INSTALLED", "Controller patch not loaded.")


func _general_trace(ctrl: Node) -> Dictionary:
	var view: Dictionary = ctrl.call("get_last_view")
	var hier: Variant = ctrl.get("_hier_last")
	return _ok({"ok": true, "tool": "general.get_execution_trace",
		"last_view": view, "hierarchy": (hier as Dictionary).duplicate(true) if hier is Dictionary else {},
		"telemetry": GeneralTraceCls.snapshot()})


# ---- player (BLUE direct control) -------------------------------------------------

func _player(action: String, a: Dictionary, _ctrl_node: Node) -> Dictionary:
	match action:
		"get_status":
			return _player_status()
		"get_units":
			return _player_units()
		"get_unit":
			return _player_unit(a)
		"get_legal_actions":
			return _player_legal(a)
		"move_unit":
			return _player_move(a)
		"move_toward":
			return _player_move_toward(a)
		"attack":
			return _player_attack(a)
		"hold", "end_unit_action":
			return _player_hold(a)
		"get_combat_preview":
			return _player_preview(a)
		"get_battle_log":
			return _player_log()
		"get_visible_enemies":
			return _player_visible()
		"end_turn":
			return _player_end_turn()
	return _fail("UNKNOWN_TOOL", "player.%s" % action)


func _blue_obs() -> Dictionary:
	var b := _bridge()
	if b == null:
		return {}
	return ObsCls.build(b, "blue")


func _player_status() -> Dictionary:
	var obs := _blue_obs()
	if obs.is_empty() or not bool(obs.get("ok", false)):
		return _fail("NO_LIVE_STATE", "Live bridge unavailable.")
	return _ok({"ok": true, "tool": "player.get_status", "turn": int(obs.get("turn", 0)), "phase": _phase(),
		"units": (obs.get("friendly_units", []) as Array).size(),
		"visible_enemies": (obs.get("known_enemy_units", []) as Array).filter(func(e: Variant) -> bool:
			return e is Dictionary and str((e as Dictionary).get("contact_state", "")) == "current_visible").size(),
		"mission": obs.get("mission", {})})


func _player_units() -> Dictionary:
	var obs := _blue_obs()
	if not bool(obs.get("ok", false)):
		return _fail("NO_LIVE_STATE", str(obs.get("error", "Live bridge unavailable.")))
	return _ok({"ok": true, "tool": "player.get_units", "turn": int(obs.get("turn", 0)), "units": obs.get("friendly_units", [])})


func _player_unit(a: Dictionary) -> Dictionary:
	var obs := _blue_obs()
	if not bool(obs.get("ok", false)):
		return _fail("NO_LIVE_STATE", str(obs.get("error", "Live bridge unavailable.")))
	var want := str(a.get("unit_id", "")).strip_edges().to_upper()
	for u_val in (obs.get("friendly_units", []) as Array):
		if u_val is Dictionary and str((u_val as Dictionary).get("unit_id", "")).strip_edges().to_upper() == want:
			return _ok({"ok": true, "tool": "player.get_unit", "unit": u_val})
	return _fail("UNIT_NOT_FOUND", "No BLUE formation '%s'." % want)


func _player_legal(a: Dictionary) -> Dictionary:
	var uid := str(a.get("unit_id", "")).strip_edges()
	var svc := _svc()
	var mgr := _mgr()
	if svc == null or mgr == null:
		return _fail("NO_LIVE_STATE", "Live battle unavailable.")
	var unit: Dictionary = mgr.call("get_unit_by_id", uid)
	if unit.is_empty():
		return _fail("UNIT_NOT_FOUND", "No unit '%s'." % uid)
	if str(unit.get("faction", "")) != "blue":
		return _fail("WRONG_SIDE", "'%s' is not a BLUE formation." % uid)
	var acted := bool(unit.get("action_ended", false))
	var garrisoned := bool(unit.get("garrisoned", false))
	var routed := bool(unit.get("routed", false))
	var out := {"ok": true, "tool": "player.get_legal_actions", "unit_id": uid,
		"can_move": not acted and not garrisoned and not routed,
		"can_attack": false, "can_hold": not acted and not garrisoned and not routed,
		"reachable_hexes": [], "attackable_targets": [], "notes": []}
	if acted:
		out["notes"].append("action_ended")
	if garrisoned:
		out["notes"].append("garrisoned")
	if routed:
		out["notes"].append("routed")
	if not bool(out["can_move"]):
		return out
	var area: Dictionary = svc.call("reachable_area", uid, "blue", "auto")
	if bool(area.get("ok", false)):
		out["reachable_hexes"] = area.get("reachable", [])
	# Attack legality via the authoritative service preview (fog enforced).
	for t_val in (mgr.call("get_attackable_targets", uid) as Array):
		if not t_val is Dictionary:
			continue
		var tid := str((t_val as Dictionary).get("id", ""))
		var pv: Dictionary = svc.call("preview_attack", uid, tid, "blue")
		if bool(pv.get("ok", false)):
			var row := (t_val as Dictionary).duplicate(true)
			row["preview"] = {"ok": true, "expected": pv.get("expected", {}), "distance": pv.get("distance", "")}
			out["attackable_targets"].append(row)
			out["can_attack"] = true
	return out


func _player_move(a: Dictionary) -> Dictionary:
	return _player_exec_move(a)


func _player_move_toward(a: Dictionary) -> Dictionary:
	# Compiles to a canonical ADVANCE with a DIRECTION target (forward/east/
	# west/north/south) — the direction resolver picks the legal best hex.
	var dir := str(a.get("direction", "forward")).strip_edges().to_upper()
	var cmd := {"action": "ADVANCE", "scope": {"kind": "UNITS", "unit_ids": [str(a.get("unit_id", ""))]},
		"target": {"type": "DIRECTION", "direction": dir}}
	return _player_exec_cmd(cmd)


func _player_exec_move(a: Dictionary) -> Dictionary:
	var q := int(a.get("q", -9999))
	var r := int(a.get("r", -9999))
	if q == -9999 or r == -9999:
		return _fail("INVALID_PARAMS", "player.move_unit needs unit_id, q, r.")
	var cmd := {"action": "REPOSITION", "scope": {"kind": "UNITS", "unit_ids": [str(a.get("unit_id", ""))]},
		"target": {"type": "HEX", "q": q, "r": r},
		"movement_policy": str(a.get("march_policy", "STANDARD")).strip_edges().to_upper()}
	return _player_exec_cmd(cmd)


func _player_attack(a: Dictionary) -> Dictionary:
	var attacker := str(a.get("attacker_id", a.get("unit_id", ""))).strip_edges()
	var target := str(a.get("target_id", a.get("target", ""))).strip_edges()
	if attacker.is_empty() or target.is_empty():
		return _fail("INVALID_PARAMS", "player.attack needs attacker_id and target_id.")
	var cmd := {"action": "ATTACK", "scope": {"kind": "UNITS", "unit_ids": [attacker]},
		"target": {"type": "FORMATION", "unit_id": target}}
	return _player_exec_cmd(cmd)


func _player_hold(a: Dictionary) -> Dictionary:
	var cmd := {"action": "HOLD", "scope": {"kind": "UNITS", "unit_ids": [str(a.get("unit_id", ""))]}, "target": {}}
	return _player_exec_cmd(cmd)


func _player_exec_cmd(cmd: Dictionary) -> Dictionary:
	if _phase() != "PLAYER":
		return _fail("NOT_PLAYER_PHASE", "BLUE commands require the PLAYER phase (current: %s)." % _phase())
	var executor := _executor()
	if executor == null:
		return _fail("NO_EXECUTOR", "Cloud1LiveExecutor not found.")
	var dry: Dictionary = CompilerCls.plan(_bridge(), cmd, "", "blue")
	if not bool(dry.get("ok", false)):
		var fails: Array = dry.get("failed", [])
		var first: String = str((fails[0] as Dictionary).get("detail", "")) if not fails.is_empty() and fails[0] is Dictionary else str(dry.get("detail", ""))
		return _fail(str(dry.get("code", "COMPILER_REJECTED")), first + " | planned=0 failed=%d" % fails.size())
	var res: Dictionary = executor.call("execute", cmd, "", "blue")
	if not bool(res.get("accepted", false)):
		return _fail(str(res.get("code", "EXECUTOR_REFUSED")), str(res.get("detail", "")))
	# The executor runs asynchronously row-by-row; execution results ride the
	# executor's signals into the controller trace. Report the dry-run plan
	# plus acceptance here; player.get_legal_actions shows the mutated state.
	return _ok({"ok": true, "tool": "player.command", "action": str(cmd.get("action", "")),
		"accepted": true, "planned": dry.get("planned", []), "failed": dry.get("failed", []),
		"note": "Execution is asynchronous; poll player.get_units / battle.get_state to confirm."})


func _player_preview(a: Dictionary) -> Dictionary:
	var svc := _svc()
	if svc == null:
		return _fail("NO_LIVE_STATE", "Live battle unavailable.")
	return _ok({"ok": true, "tool": "player.get_combat_preview",
		"preview": svc.call("preview_attack", str(a.get("attacker_id", "")), str(a.get("target_id", "")), "blue")})


func _player_log() -> Dictionary:
	var manager := _manager()
	var events: Array = manager.call("get_events") if manager != null else []
	var start: int = maxi(0, events.size() - 40)
	return _ok({"ok": true, "tool": "player.get_battle_log", "events": (events as Array).slice(start)})


func _player_visible() -> Dictionary:
	var obs := _blue_obs()
	if not bool(obs.get("ok", false)):
		return _fail("NO_LIVE_STATE", str(obs.get("error", "Live bridge unavailable.")))
	var visible: Array = []
	var stale: Array = []
	for e_val in (obs.get("known_enemy_units", []) as Array):
		if not e_val is Dictionary:
			continue
		if str((e_val as Dictionary).get("contact_state", "")) == "current_visible":
			visible.append(e_val)
		else:
			stale.append(e_val)
	return _ok({"ok": true, "tool": "player.get_visible_enemies", "visible": visible, "stale_contacts": stale})


func _player_end_turn() -> Dictionary:
	if _phase() != "PLAYER":
		return _fail("NOT_PLAYER_PHASE", "End turn requires the PLAYER phase (current: %s)." % _phase())
	var shell := _shell()
	if shell == null or not shell.has_method("end_player_turn"):
		return _fail("NO_SHELL", "Battlefield shell unavailable.")
	print("[AgentPlaytest] player.end_turn dispatched")
	shell.call("end_player_turn")
	return _ok({"ok": true, "tool": "player.end_turn", "note": "RED phase dispatched; poll battle.get_state until phase returns to PLAYER."})
