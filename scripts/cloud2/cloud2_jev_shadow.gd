class_name Cloud2JevShadow
extends RefCounted

## JEV GODOT SHADOW (SHADOW ONLY) — read-only tactical observer.
##
## Observes real MissionManager.red_turn tactical decisions, POSTs the SAME
## decision context to the persistent local JEV worker, and appends one JSONL
## telemetry record per decision. It NEVER mutates game state, NEVER calls
## the compiler/executor for authority, and NEVER feeds its result back into
## any decision. Single-launch: the worker is owned by the game and starts
## automatically; JEV_SHADOW_ENABLE=0 is the only off switch (every entry
## point then returns immediately with zero behavior change).
##
## Contract: artifacts/jev_godot_shadow_v0/SHADOW_CONTRACT.json
## (jev-shadow-contract-v1). Request schema: jev-shadow-request-v1.

const OptionCls = preload("res://scripts/cloud2/cloud2_class_option.gd")
const HexUtilsCls = preload("res://scripts/core/hex_utils.gd")
const LauncherCls = preload("res://scripts/cloud2/cloud2_jev_launcher.gd")

const SCHEMA_VERSION := "jev-shadow-request-v1"
const TELEMETRY_VERSION := "jev-shadow-telemetry-v1"
const DEFAULT_URL := "http://127.0.0.1:11439"
const DEFAULT_TIMEOUT_MS := 1500
const DEFAULT_TELEMETRY := "res://artifacts/jev_godot_shadow_v0/SHADOW_TELEMETRY.jsonl"
const PATCH_RADIUS := 5
const PATCH_CELL_COUNT := 91

static var _enabled_cache := -1
static var _config_cache := {}
static var _dir_ready := {}


static func enabled() -> bool:
	# Single-launch: shadow is automatic unless explicitly disabled with
	# JEV_SHADOW_ENABLE=0. "1" keeps legacy force-on semantics; unset means
	# auto (spawn owned worker, fail open to deterministic-only on any error).
	if _enabled_cache < 0:
		_enabled_cache = 0 if OS.get_environment("JEV_SHADOW_ENABLE").strip_edges() == "0" else 1
	return _enabled_cache == 1


static func config() -> Dictionary:
	if _config_cache.is_empty():
		var timeout := DEFAULT_TIMEOUT_MS
		if OS.has_environment("JEV_SHADOW_TIMEOUT_MS"):
			timeout = clampi(int(OS.get_environment("JEV_SHADOW_TIMEOUT_MS")), 100, 30000)
		var tele := DEFAULT_TELEMETRY
		if OS.has_environment("JEV_SHADOW_TELEMETRY") and not OS.get_environment("JEV_SHADOW_TELEMETRY").strip_edges().is_empty():
			tele = OS.get_environment("JEV_SHADOW_TELEMETRY").strip_edges()
		var run_id := ""
		if OS.has_environment("JEV_SHADOW_RUN_ID"):
			run_id = OS.get_environment("JEV_SHADOW_RUN_ID").strip_edges()
		_config_cache = {"timeout_ms": timeout, "telemetry": tele, "run_id": run_id}
	# Host/port resolve fresh on every call: the launcher may pick a dynamic
	# port after this cache was built. Explicit JEV_SHADOW_URL always wins.
	var ep := _resolve_endpoint()
	_config_cache["host"] = str(ep[0])
	_config_cache["port"] = int(ep[1])
	return _config_cache


static func _resolve_endpoint() -> Array:
	if OS.has_environment("JEV_SHADOW_URL") and not OS.get_environment("JEV_SHADOW_URL").strip_edges().is_empty():
		return _parse_url(OS.get_environment("JEV_SHADOW_URL").strip_edges())
	var snap: Dictionary = LauncherCls.status_snapshot()
	if str(snap.get("status", "COLD")) == "READY" or str(snap.get("status", "COLD")) == "BOOTING":
		return [str(snap.get("host", "127.0.0.1")), int(snap.get("port", 11439))]
	return _parse_url(DEFAULT_URL)


static func _parse_url(url: String) -> Array:
	var s := url.strip_edges()
	if s.begins_with("http://"):
		s = s.substr(7)
	elif s.begins_with("https://"):
		s = s.substr(8)
	s = s.rstrip("/")
	var host := "127.0.0.1"
	var port := 11439
	if s.contains(":"):
		var parts := s.split(":")
		host = parts[0]
		port = int(parts[1]) if parts.size() > 1 and parts[1].is_valid_int() else 11439
	elif not s.is_empty():
		host = s
	return [host, port]


## Observe one mission decision (called once per decided mission from
## MissionManager.red_turn). tables trace = res.trace (units: solve_unit
## tables). dctx = the exact ctx dict passed to ctrl.decide.
static func observe(sim: RefCounted, obs: Dictionary, mission: Dictionary,
	doctrine: Dictionary, dctx: Dictionary, trace: Dictionary,
	_seed_base: int) -> void:
	if not enabled():
		return
	# Single-launch: idempotent bounded ensure (fast when READY). Returns
	# silently on DISABLED so authoritative gameplay never stalls on JEV.
	var ens: Dictionary = LauncherCls.ensure_started_sync()
	if str(ens.get("status", "")) != "READY":
		return
	if sim == null or obs.is_empty() or mission.is_empty() or trace.is_empty():
		return
	var tables: Array = trace.get("units", [])
	if tables.is_empty():
		return
	var mgr: RefCounted = sim.get_manager() if sim.has_method("get_manager") else null
	var proj: RefCounted = sim.get_projector() if sim.has_method("get_projector") else null
	var mgr_units := _manager_unit_map(mgr)
	var cell_data: Dictionary = proj.get("_cell_data") if proj != null else {}
	var red_visible: Dictionary = proj.call("get_red_visible_ids") if proj != null and proj.has_method("get_red_visible_ids") else {}
	var friend_rows := _index_by(obs.get("friendly_units", []), "unit_id")
	var turn := int(obs.get("turn", 0))
	var battle_id := str(obs.get("battle_id", "battle"))
	var snapshot_id := str(obs.get("snapshot_id", ""))
	var cfg := config()
	var run_id: String = cfg.get("run_id", "")
	if run_id.is_empty():
		run_id = battle_id + "-shadow"
	for t_val in tables:
		if not t_val is Dictionary:
			continue
		var table: Dictionary = t_val
		_observe_unit(cfg, run_id, battle_id, turn, snapshot_id, obs,
			mission, doctrine, dctx, table, friend_rows, mgr_units,
			cell_data, red_visible)


static func _index_by(rows: Array, key: String) -> Dictionary:
	var out := {}
	for r_val in rows:
		if r_val is Dictionary:
			out[str((r_val as Dictionary).get(key, ""))] = r_val
	return out


## Read-only snapshot of live manager unit records (field reads only).
static func _manager_unit_map(mgr: RefCounted) -> Dictionary:
	var out := {}
	if mgr == null or not mgr.has_method("get_all_units_including_garrisoned"):
		return out
	var all: Array = mgr.get_all_units_including_garrisoned()
	for u_val in all:
		if u_val is Dictionary:
			out[str((u_val as Dictionary).get("id", ""))] = u_val
	return out


static func _observe_unit(cfg: Dictionary, run_id: String, battle_id: String,
	turn: int, snapshot_id: String, obs: Dictionary, mission: Dictionary,
	doctrine: Dictionary, dctx: Dictionary, table: Dictionary,
	friend_rows: Dictionary, mgr_units: Dictionary, cell_data: Dictionary,
	red_visible: Dictionary) -> void:
	var uid := str(table.get("unit_id", ""))
	var uclass := str(table.get("unit_class", "")).strip_edges().to_upper()
	var decision_id := "%s|%s|%s" % [run_id, snapshot_id, uid]
	var snap: Dictionary = LauncherCls.status_snapshot()
	var base_rec := {"schema_version": TELEMETRY_VERSION, "record_type": "decision",
		"run_id": run_id, "battle_id": battle_id, "decision_id": decision_id,
		"request_id": decision_id, "turn": turn, "faction": "RED",
		"actor_id": uid, "unit_class": uclass, "snapshot_id": snapshot_id,
		"worker_pid": int(snap.get("pid", -1)),
		"worker_port": int(snap.get("port", 0)),
		"shadow_mode": str(snap.get("mode", "AUTO")),
		"worker_owned": bool(snap.get("owned", false))}
	var built := _build_request(obs, mission, doctrine, dctx, table,
		friend_rows, mgr_units, cell_data, red_visible, base_rec)
	if not bool(built.get("ok", false)):
		base_rec["eligible"] = false
		base_rec["shadow_status"] = "GATHER_ERROR"
		base_rec["shadow_error"] = str(built.get("error", "gather failed"))
		_append_line(cfg, base_rec)
		return
	var req: Dictionary = built["request"]
	var t0 := Time.get_ticks_msec()
	var posted := _post_json(str(cfg["host"]), int(cfg["port"]), "/infer",
		JSON.stringify(req), int(cfg["timeout_ms"]))
	var client_ms := float(Time.get_ticks_msec() - t0)
	if not bool(posted.get("ok", false)):
		base_rec["eligible"] = true
		base_rec["mission"] = _mission_brief(mission)
		base_rec["baseline_slot"] = int((table.get("selected_slot", -1)))
		base_rec["baseline_option_id"] = str(table.get("selected_id", ""))
		base_rec["godot_legal"] = _godot_legal(table)
		base_rec["shadow_status"] = "WORKER_ERROR"
		base_rec["shadow_error"] = str(posted.get("error", "post failed"))
		base_rec["latency_ms"] = {"client": client_ms}
		base_rec["planned_command"] = table.get("resolved_command", {})
		_append_line(cfg, base_rec)
		return
	var parsed: Variant = JSON.parse_string(str(posted.get("body", "")))
	if not parsed is Dictionary:
		base_rec["eligible"] = true
		base_rec["shadow_status"] = "WORKER_ERROR"
		base_rec["shadow_error"] = "worker response is not JSON"
		base_rec["latency_ms"] = {"client": client_ms}
		_append_line(cfg, base_rec)
		return
	_record_response(cfg, base_rec, req, parsed, table, mission, client_ms)


static func _mission_brief(mission: Dictionary) -> Dictionary:
	return {"mission_id": str(mission.get("mission_id", "?")),
		"task": str(mission.get("task", "?")),
		"area": str(mission.get("area", "?")),
		"status": str(mission.get("status", "?")),
		"objective": mission.get("objective", {})}


static func _godot_legal(table: Dictionary) -> Array:
	var out: Array = []
	for o_val in (table.get("options", []) as Array):
		if o_val is Dictionary:
			out.append(not bool((o_val as Dictionary).get("masked", true)))
	return out


## Gather the SAME authorized decision context the solver used. Pure reads.
static func _build_request(obs: Dictionary, mission: Dictionary,
	doctrine: Dictionary, dctx: Dictionary, table: Dictionary,
	friend_rows: Dictionary, mgr_units: Dictionary, cell_data: Dictionary,
	red_visible: Dictionary, base_rec: Dictionary) -> Dictionary:
	var uid := str(base_rec["actor_id"])
	var uclass := str(base_rec["unit_class"])
	var turn := int(base_rec["turn"])
	var frow: Dictionary = friend_rows.get(uid, {})
	var mrow: Dictionary = mgr_units.get(uid, {})
	if frow.is_empty() or mrow.is_empty():
		return {"ok": false, "error": "UNIT_LOOKUP_FAILED"}
	var aq := int(mrow.get("q", 0))
	var ar := int(mrow.get("r", 0))
	var opts: Array = []
	for o_val in (table.get("options", []) as Array):
		if not o_val is Dictionary:
			return {"ok": false, "error": "TABLE_OPTION_SHAPE"}
		var o: Dictionary = o_val
		opts.append({"slot": int(o.get("slot", -1)),
			"option_id": str(o.get("option_id", "")),
			"kind": str(o.get("kind", "")),
			"masked": bool(o.get("masked", true)),
			"mask_reason": str(o.get("mask_reason", ""))})
	if opts.size() != 6:
		return {"ok": false, "error": "TABLE_OPTIONS_NOT_SIX"}
	var friendlies: Array = []
	var hq_pos: Variant = null
	for fr_val in (obs.get("friendly_units", []) as Array):
		if not fr_val is Dictionary:
			continue
		var fr: Dictionary = fr_val
		var fid := str(fr.get("unit_id", ""))
		var mr: Dictionary = mgr_units.get(fid, {})
		if mr.is_empty():
			continue
		friendlies.append({"unit_id": fid,
			"class": str(fr.get("class", "unknown")),
			"q": int(fr.get("q", 0)), "r": int(fr.get("r", 0)),
			"soldiers": int(fr.get("soldiers", 0)),
			"max_count": maxi(1, int(mr.get("max_count", int(fr.get("soldiers", 1))))),
			"has_acted": bool(fr.get("has_acted", false)),
			"status": str(fr.get("status", "ready"))})
		if str(fr.get("class", "")).strip_edges().to_lower() == "hq" \
				and int(fr.get("soldiers", 0)) > 0 \
				and str(fr.get("status", "")) != "garrisoned" and hq_pos == null:
			hq_pos = [int(fr.get("q", 0)), int(fr.get("r", 0))]
	var enemies: Array = []
	var stale: Array = []
	var enemy_hq := {"known": false, "alive": false, "q": 0, "r": 0}
	for e_val in (obs.get("known_enemy_units", []) as Array):
		if not e_val is Dictionary:
			continue
		var e: Dictionary = e_val
		if str(e.get("contact_state", "")) == "current_visible":
			enemies.append({"unit_id": str(e.get("unit_id", "")),
				"class": str(e.get("class", "unknown")),
				"q": int(e.get("q", 0)), "r": int(e.get("r", 0)),
				"last_seen_turn": turn})
			if str(e.get("class", "")).strip_edges().to_lower() == "hq" \
					and not bool(enemy_hq["known"]):
				enemy_hq = {"known": true, "alive": true,
					"q": int(e.get("q", 0)), "r": int(e.get("r", 0))}
		elif str(e.get("contact_state", "")) == "stale_last_known":
			stale.append({"unit_id": str(e.get("unit_id", "")),
				"class": str(e.get("class", "unknown")),
				"q": int(e.get("q", 0)), "r": int(e.get("r", 0)),
				"last_seen_turn": int(e.get("last_seen_turn", 0))})
	var cells := _patch_cells(aq, ar, cell_data)
	if (cells as Array).size() != PATCH_CELL_COUNT:
		return {"ok": false, "error": "PATCH_NOT_91"}
	var mpoint: Vector2i = OptionCls.mission_point(obs, mission, dctx)
	var bounds: Dictionary = dctx.get("bounds", {})
	if bounds.is_empty():
		bounds = (obs.get("board", {}) as Dictionary).get("dimensions", {})
	var doctr := {"aggression": float(doctrine.get("aggression", 0.5)),
		"risk_tolerance": float(doctrine.get("risk_tolerance", 0.5)),
		"tempo": float(doctrine.get("tempo", 0.5)),
		"pursuit": float(doctrine.get("pursuit", 0.5)),
		"reserve_discipline": float(doctrine.get("reserve_discipline", 0.6)),
		"deception": float(doctrine.get("deception", 0.2))}
	var meval: Dictionary = obs.get("mission", {})
	var req := {
		"schema_version": SCHEMA_VERSION,
		"request_id": str(base_rec["request_id"]),
		"battle_id": str(base_rec["battle_id"]),
		"decision_id": str(base_rec["decision_id"]),
		"turn": turn, "snapshot_id": str(base_rec["snapshot_id"]),
		"faction": "RED",
		"actor": {"unit_id": uid, "unit_class": str(mrow.get("class", "infantry")),
			"q": aq, "r": ar,
			"soldiers": int(mrow.get("soldier_count", 0)),
			"max_count": maxi(1, int(mrow.get("max_count", 1))),
			"remaining_mp": float(mrow.get("remaining_mp", 0.0)),
			"base_mp": float(mrow.get("base_mp", 0.0)),
			"turn_move_cost_spent": float(mrow.get("turn_move_cost_spent", 0.0)),
			"blue_limit": float(mrow.get("blue_limit", 1.0)),
			"can_attack": bool(frow.get("can_attack", false)),
			"has_attacked": bool(mrow.get("has_attacked", false)),
			"action_ended": bool(mrow.get("action_ended", false)),
			"status": str(frow.get("status", "ready")),
			"morale": float(mrow.get("morale", 100.0)),
			"routed": bool(mrow.get("routed", false)),
			"garrisoned": bool(mrow.get("garrisoned", false)),
			"defense_ready": bool(mrow.get("defense_ready", false)),
			"formation": str(frow.get("formation", "FIELD"))},
		"unit_class": uclass,
		"mission": {"mission_id": str(mission.get("mission_id", "?")),
			"task": str(mission.get("task", "HOLD")),
			"area": str(mission.get("area", "ANY")),
			"status": str(mission.get("status", "ACTIVE")),
			"objective": mission.get("objective", {}),
			"engagement": mission.get("engagement", {}),
			"constraints": mission.get("constraints", {}),
			"activated_turn": int(mission.get("activated_turn", 0)),
			"progress_turn": int(mission.get("progress_turn", 0))},
		"doctrine": doctr,
		"ctx": {"turns_active": int(dctx.get("turns_active", 0)),
			"urgency": float(dctx.get("urgency", 0.0)),
			"mission_status": str(mission.get("status", "ACTIVE")),
			"main_effort": str(dctx.get("main_effort", "")),
			"bounds": {"q_min": int(bounds.get("q_min", -30)),
				"q_max": int(bounds.get("q_max", -20)),
				"r_min": int(bounds.get("r_min", -5)),
				"r_max": int(bounds.get("r_max", 5))}},
		"godot_options": opts,
		"baseline": {"slot": int(table.get("selected_slot", -1)),
			"option_id": str(table.get("selected_id", ""))},
		"planned_command": table.get("resolved_command", {}),
		"friendlies": friendlies,
		"enemies_visible": enemies,
		"stale": stale,
		"hex_cells": cells,
		"red_visible_cells": (red_visible as Dictionary).keys(),
		"objective_hex": [int(mpoint.x), int(mpoint.y)],
		"hq_pos": hq_pos,
		"enemy_hq": enemy_hq,
		"turn_limit": int(meval.get("turn_limit", 0)),
		"mission_evaluation": {"primary_objective": str(meval.get("type", "")),
			"mission_status": str(meval.get("status", ""))},
	}
	return {"ok": true, "request": req}


## Actor-centered radius-5 diamond (91 cells). Order is irrelevant: the worker
## keys cells by coordinate and applies the canonical RING_MAJOR order itself.
static func _patch_cells(aq: int, ar: int, cell_data: Dictionary) -> Array:
	var out: Array = []
	var origin := Vector2i(aq, ar)
	for dq in range(-PATCH_RADIUS, PATCH_RADIUS + 1):
		for dr in range(-PATCH_RADIUS, PATCH_RADIUS + 1):
			if HexUtilsCls.hex_distance_axial(origin, Vector2i(aq + dq, ar + dr)) > PATCH_RADIUS:
				continue
			var key := "%d,%d" % [aq + dq, ar + dr]
			var terrain := 0
			var in_bounds := false
			if cell_data.has(key):
				in_bounds = true
				var cell: Variant = cell_data[key]
				if cell is Dictionary:
					terrain = int((cell as Dictionary).get("terrain", 0))
			out.append({"q": aq + dq, "r": ar + dr, "terrain": terrain,
				"in_bounds": in_bounds})
	return out


static func _record_response(cfg: Dictionary, base_rec: Dictionary,
	req: Dictionary, parsed: Dictionary, table: Dictionary,
	mission: Dictionary, client_ms: float) -> void:
	base_rec["mission"] = _mission_brief(mission)
	base_rec["doctrine_live"] = req["doctrine"]
	base_rec["godot_options"] = req["godot_options"]
	base_rec["godot_legal"] = _godot_legal(table)
	base_rec["baseline_slot"] = int(table.get("selected_slot", -1))
	base_rec["baseline_option_id"] = str(table.get("selected_id", ""))
	base_rec["planned_command"] = table.get("resolved_command", {})
	base_rec["role_context"] = {"formation": str((req["actor"] as Dictionary).get("formation", "FIELD"))}
	if not bool(parsed.get("ok", false)):
		base_rec["eligible"] = true
		base_rec["shadow_status"] = "WORKER_ERROR"
		var err: Dictionary = parsed.get("error", {})
		base_rec["shadow_error"] = "%s: %s" % [str(err.get("code", "?")), str(err.get("detail", ""))]
		base_rec["latency_ms"] = {"client": client_ms}
		_append_line(cfg, base_rec)
		return
	if not bool(parsed.get("eligible", false)):
		base_rec["eligible"] = false
		base_rec["shadow_status"] = "NOT_ELIGIBLE"
		base_rec["shadow_error"] = ""
		base_rec["not_eligible_reason"] = str(parsed.get("reason", "NOT_JEV_ELIGIBLE"))
		base_rec["latency_ms"] = {"client": client_ms}
		_append_line(cfg, base_rec)
		return
	base_rec["eligible"] = true
	base_rec["shadow_status"] = "ALL_ILLEGAL" if bool(parsed.get("all_illegal", false)) else "OK"
	base_rec["shadow_error"] = ""
	var mapping: Dictionary = parsed.get("mapping", {})
	(base_rec["role_context"] as Dictionary)["intent_mapped"] = str(mapping.get("intent_mapped", ""))
	(base_rec["role_context"] as Dictionary)["actor_role"] = str(mapping.get("actor_role", ""))
	base_rec["baseline_jev_slot"] = mapping.get("baseline_jev_slot", null)
	base_rec["jev"] = {"logits": parsed.get("logits", []),
		"masked_probabilities": parsed.get("probabilities", []),
		"masked_logits": parsed.get("masked_logits", []),
		"selected_slot": int(parsed.get("selected_slot", -1)),
		"selected_skill": parsed.get("selected_skill", null),
		"all_illegal": bool(parsed.get("all_illegal", false)),
		"legal_mask": parsed.get("legal_mask", [])}
	var bslot: Variant = mapping.get("baseline_jev_slot", null)
	var jsel := int(parsed.get("selected_slot", -1))
	base_rec["agreement_mapped"] = (int(bslot) == jsel) if bslot != null else null
	base_rec["index_agreement"] = int(table.get("selected_slot", -1)) == jsel
	base_rec["mapping"] = mapping
	var ident: Dictionary = parsed.get("identity", {})
	base_rec["model_identity"] = str(ident.get("model_version", ""))
	base_rec["checkpoint_sha256"] = str(ident.get("checkpoint_sha256", ""))
	base_rec["request_sha256"] = str(parsed.get("request_sha256", ""))
	var slat: Dictionary = parsed.get("latency_ms", {})
	base_rec["latency_ms"] = {"client": client_ms,
		"server_total": float(slat.get("total", 0.0)),
		"server_forward": float(slat.get("forward", 0.0))}
	_append_line(cfg, base_rec)


## Blocking bounded HTTP POST. Returns {ok, body, error}. Never raises.
static func _post_json(host: String, port: int, path: String, body: String,
	timeout_ms: int) -> Dictionary:
	var deadline := Time.get_ticks_msec() + timeout_ms
	var http := HTTPClient.new()
	var err := http.connect_to_host(host, port)
	if err != OK:
		return {"ok": false, "error": "CONNECT_FAIL: %s" % error_string(err)}
	while true:
		if Time.get_ticks_msec() > deadline:
			http.close()
			return {"ok": false, "error": "TIMEOUT_CONNECT"}
		http.poll()
		var st := http.get_status()
		if st == HTTPClient.STATUS_CONNECTED:
			break
		if st != HTTPClient.STATUS_RESOLVING and st != HTTPClient.STATUS_CONNECTING:
			http.close()
			return {"ok": false, "error": "CONNECT_STATUS_%d" % st}
		OS.delay_msec(5)
	err = http.request(HTTPClient.METHOD_POST, path,
		PackedStringArray(["Content-Type: application/json"]), body)
	if err != OK:
		http.close()
		return {"ok": false, "error": "REQUEST_FAIL: %s" % error_string(err)}
	while http.get_status() == HTTPClient.STATUS_REQUESTING:
		if Time.get_ticks_msec() > deadline:
			http.close()
			return {"ok": false, "error": "TIMEOUT_REQUEST"}
		http.poll()
		OS.delay_msec(5)
	if http.get_response_code() != 200:
		http.close()
		return {"ok": false, "error": "HTTP_%d" % http.get_response_code()}
	var chunks := PackedByteArray()
	while http.get_status() == HTTPClient.STATUS_BODY:
		if Time.get_ticks_msec() > deadline:
			http.close()
			return {"ok": false, "error": "TIMEOUT_BODY"}
		http.poll()
		var chunk := http.read_response_body_chunk()
		if chunk.size() > 0:
			chunks.append_array(chunk)
		else:
			OS.delay_msec(2)
	http.close()
	return {"ok": true, "body": chunks.get_string_from_utf8()}


## Execution outcome record (called by the det harness AFTER Compiler.execute).
## Correlated with decision records on run_id + turn + unit_id.
static func note_execution(run_id: String, battle_id: String, turn: int,
	unit_id: String, executed_action: String, exec_detail: Dictionary,
	casualties: Dictionary, destroyed: Array) -> void:
	if not enabled():
		return
	var cfg := config()
	var rid := run_id
	if rid.is_empty():
		rid = str(cfg.get("run_id", ""))
	if rid.is_empty():
		rid = battle_id + "-shadow"
	_append_line(cfg, {"schema_version": TELEMETRY_VERSION,
		"record_type": "exec", "run_id": rid, "battle_id": battle_id,
		"turn": turn, "unit_id": unit_id, "actor_id": unit_id,
		"executed_action": executed_action, "exec_detail": exec_detail,
		"casualties": casualties, "destroyed": destroyed})


## Per-turn mission/authority record (called by the det harness per turn).
static func note_turn(run_id: String, battle_id: String, turn: int,
	snapshot_id: String, statuses: Array, review: Dictionary,
	fingerprint_post: String, order_count: int) -> void:
	if not enabled():
		return
	var cfg := config()
	var rid := run_id
	if rid.is_empty():
		rid = str(cfg.get("run_id", ""))
	if rid.is_empty():
		rid = battle_id + "-shadow"
	_append_line(cfg, {"schema_version": TELEMETRY_VERSION,
		"record_type": "turn", "run_id": rid, "battle_id": battle_id,
		"turn": turn, "snapshot_id": snapshot_id, "statuses": statuses,
		"review": review, "fingerprint_post": fingerprint_post,
		"order_count": order_count})


static func _append_line(cfg: Dictionary, rec: Dictionary) -> void:
	var path := str(cfg.get("telemetry", DEFAULT_TELEMETRY))
	if not bool(_dir_ready.get(path, false)):
		var dir := path.get_base_dir()
		if dir.begins_with("res://"):
			dir = ProjectSettings.globalize_path(dir)
		DirAccess.make_dir_recursive_absolute(dir)
		_dir_ready[path] = true
	var line := JSON.stringify(rec)
	var f := FileAccess.open(path, FileAccess.READ_WRITE)
	if f == null:
		f = FileAccess.open(path, FileAccess.WRITE)
		if f == null:
			push_warning("[JEVSHADOW] telemetry open failed: %s" % path)
			return
	else:
		f.seek_end()
	f.store_line(line)
	f.close()
