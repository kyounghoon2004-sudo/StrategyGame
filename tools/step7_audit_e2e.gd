extends SceneTree

## Audit E2E harness: REAL ChatCommander + REAL scope/evaluator/staging/
## execution, STUBBED LLM transport (canned Phase-1 = real model outputs
## from .audit_phase1_raw.json; Phase-2 = deterministic best-utility pick).
## Proves the plumbing layer end-to-end: intent -> scope -> packages ->
## deconflict -> stage (no mutation) -> preview -> approve/cancel ->
## canonical execution -> occupancy + accounting.
## Real-model Phase-1/Phase-2 quality is covered by step7_audit_phase1.py
## and live spot checks, not here.
## Evidence: tools/.audit_e2e.json. quit 0 = all pass, 1 = failures.

const RAW_PATH := "D:/Game development/Demon slayer/StrategyGame/tools/.audit_phase1_raw.json"
const OUT_PATH := "D:/Game development/Demon slayer/StrategyGame/tools/.audit_e2e.json"


class StubClient:
	extends Node
	signal chat_finished(request_id: String, result: Dictionary)
	var commander = null
	var raws := {}
	var phases: Array = []

	func request_chat(request_id: String, _endpoint: String, _model: String,
			_messages: Array, _options: Dictionary, _timeout_sec: float,
			_api_key: String = "") -> Dictionary:
		call_deferred("_reply", request_id)
		return {"ok": true, "request_id": request_id}

	func cancel_active() -> void:
		pass

	func has_active() -> bool:
		return false

	func _reply(request_id: String) -> void:
		if commander == null:
			return
		var act: Dictionary = commander.get("_active")
		if not act.has(request_id):
			return
		var rec: Dictionary = act[request_id]
		var phase := str(rec.get("phase", ""))
		phases.append(phase)
		var content := ""
		if phase == "intent":
			content = str(raws.get(str(rec.get("text", "")), ""))
		elif phase == "select":
			content = _build_selection(rec)
		elif phase == "info":
			content = _info_answer()
		chat_finished.emit(request_id, {"ok": true, "request_id": request_id,
			"http_status": 200, "content_text": content,
			"message_role": "assistant", "done_reason": "stop",
			"prompt_eval_count": 1, "eval_count": 10,
			"prompt_eval_duration_ns": 1, "eval_duration_ns": 2,
			"total_duration_ns": 3, "load_duration_ns": 0,
			"latency_ms": 5})

	func _info_answer() -> String:
		var d := {"answer": "INFO_STUB_ANSWER"}
		return JSON.stringify(d)

	func _build_selection(rec: Dictionary) -> String:
		var pkgs: Dictionary = rec.get("packages", {})
		# Chunk-aware: answer the CURRENT chunk only (mirrors the live
		# contract validated per chunk).
		var chunks: Array = rec.get("select_chunks", [])
		var ids: Array = pkgs.keys()
		if not chunks.is_empty():
			var idx := mini(int(rec.get("select_index", 0)), chunks.size() - 1)
			ids = (chunks[idx] as Array).duplicate()
		ids.sort()
		var sels: Array = []
		for uid in ids:
			var best := ""
			var best_u := -1e30
			for o_val in ((pkgs[uid] as Dictionary).get("options", []) as Array):
				if not o_val is Dictionary:
					continue
				var o: Dictionary = o_val
				if not str(o.get("status", "")).to_upper() in ["AVAILABLE", "DEGRADED"]:
					continue
				var u := float(o.get("utility", 0.0))
				if best.is_empty() or u > best_u:
					best = str(o.get("profile", ""))
					best_u = u
			if best.is_empty():
				return ""
			sels.append({"unit_id": str(uid), "selected_option_id": best})
		if sels.is_empty():
			return ""
		var d := {"selections": sels, "reason": "StubReasonText", "confidence": 0.85}
		return JSON.stringify(d)


var _raws := {}
var _results: Array = []
var _pass := 0
var _fail: Array = []
var _chatlog: Array = []


func _init() -> void:
	call_deferred("_run")


func _check(cond: bool, label: String, info: Dictionary = {}) -> void:
	if cond:
		_pass += 1
		_results.append({"label": label, "ok": true, "info": info})
	else:
		_fail.append(label)
		_results.append({"label": label, "ok": false, "info": info})
	print(("PASS " if cond else "FAIL ") + label)


func _load_raws() -> bool:
	var t := FileAccess.get_file_as_string(RAW_PATH)
	if t.is_empty():
		return false
	var data: Variant = JSON.parse_string(t)
	for r in ((data as Dictionary).get("results", []) as Array):
		_raws[str((r as Dictionary).get("tag", ""))] = str((r as Dictionary).get("raw", ""))
	return not _raws.is_empty()


func _wait_ms(timeout_ms: int, pred: Callable) -> bool:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < timeout_ms:
		await process_frame
		if bool(pred.call()):
			return true
	return bool(pred.call())


func _boot() -> Array:
	var packed: PackedScene = load("res://scenes/step2r_battlefield_shell.tscn")
	var battle: Node = packed.instantiate()
	get_root().add_child(battle)
	for _i in range(20):
		await process_frame
	var integration: Node = battle.get_node_or_null("Step7Integration")
	for _i in range(240):
		if integration and bool(integration.get("ready_for_step7")):
			break
		await process_frame
	if integration == null or not bool(integration.get("ready_for_step7")):
		return []
	for _i in range(30):
		await process_frame
	return [battle, integration]


func _wire(battle: Node, integration: Node, text_to_tag: Dictionary) -> Array:
	var adapter: Node = integration.get("_advisor_adapter")
	var commander: Node = adapter.get("_commander")
	var stub := StubClient.new()
	stub.commander = commander
	stub.name = "AuditStubClient"
	var map_text_raw := {}
	for text in text_to_tag.keys():
		map_text_raw[str(text)] = str(_raws.get(str(text_to_tag[text]), ""))
	stub.raws = map_text_raw
	var old = commander.get("_client")
	if old != null and old.has_signal("chat_finished"):
		old.chat_finished.disconnect(Callable(commander, "_on_chat_finished"))
	commander.set("_client", stub)
	battle.add_child(stub)
	stub.chat_finished.connect(Callable(commander, "_on_chat_finished"))
	var finished := {}
	var on_fin := func(cid: String, _ok: bool, _summary: String) -> void:
		finished[cid] = true
	commander.command_finished.connect(on_fin)
	return [adapter, commander, stub, finished]


func _positions(truth: RefCounted) -> Dictionary:
	var out := {}
	for u in truth.call("snapshot_units"):
		if not u is Dictionary:
			continue
		if str((u as Dictionary).get("faction", "")) != "blue":
			continue
		if bool((u as Dictionary).get("garrisoned", false)) or bool((u as Dictionary).get("routed", false)):
			continue
		if int((u as Dictionary).get("soldier_count", 0)) <= 0:
			continue
		out[str((u as Dictionary).get("id", ""))] = [int((u as Dictionary).get("q", 0)), int((u as Dictionary).get("r", 0))]
	return out


func _dup_cells(pos: Dictionary) -> Array:
	var seen := {}
	var dupes: Array = []
	for uid in pos.keys():
		var k := JSON.stringify(pos[uid])
		if seen.has(k):
			dupes.append(k)
		else:
			seen[k] = true
	return dupes


func _send_and_settle(commander: Node, text: String) -> bool:
	commander.send_chat(text)
	var settled := await _wait_ms(180000, Callable(self, "_is_settled").bind(commander))
	return settled


func _on_audit_chat(author: String, text: String) -> void:
	_chatlog.append(str(author) + ": " + str(text))


func _last_advisor_text() -> String:
	for i in range(_chatlog.size() - 1, -1, -1):
		var line := str(_chatlog[i])
		if line.begins_with("ADVISOR"):
			return line
	return ""


func _is_settled(commander: Node) -> bool:
	return not commander.has_active()


func _exec_done(commander: Node, svc: RefCounted) -> bool:
	return not commander.has_staged() and not bool(svc.call("is_executing"))


func _case_execute(tag: String, text: String, raw_tag: String, expect: Dictionary) -> void:
	var booted := await _boot()
	if booted.is_empty():
		_check(false, tag + ": boot")
		return
	var battle: Node = booted[0]
	var integration: Node = booted[1]
	var spec := {}
	spec[text] = raw_tag
	var wired := await _wire(battle, integration, spec)
	var commander: Node = wired[1]
	_chatlog = []
	commander.chat_append.connect(_on_audit_chat)
	var truth: RefCounted = integration.get("truth")
	var svc: RefCounted = integration.get("action_service")
	var v0 := int(truth.call("get_version"))
	var pos0 := _positions(truth)
	var settled := await _send_and_settle(commander, text)
	_check(settled, tag + ": pipeline settled")
	_check(commander.has_staged(), tag + ": staged")
	if not commander.has_staged():
		_check(false, tag + ": debug=" + JSON.stringify((commander.debug_snapshot().get("failure", "?"))).left(200))
		battle.queue_free()
		return
	var st: Dictionary = commander.staged_summary()
	_check(int(truth.call("get_version")) == v0, tag + ": SEND!=mutation")
	# Deconflict-dropped units (never staged) must be NAMED in the stage
	# text, not hidden in a count.
	var dbg: Dictionary = commander.debug_snapshot()
	var dropped: Array = ((dbg.get("deconflict_detail", {}) as Dictionary).get("dropped", []) as Array).duplicate()
	var stage_text := ""
	for line in _chatlog:
		stage_text += str(line) + "\n"
	var unnamed_drop: Array = []
	for d in dropped:
		if stage_text.find(str((d as Dictionary).get("unit_id", "?"))) < 0:
			unnamed_drop.append(str((d as Dictionary).get("unit_id", "?")))
	_check(unnamed_drop.is_empty(), tag + ": dropped units named at stage", {"dropped": dropped, "unnamed": unnamed_drop})
	_check(_positions(truth).keys().size() == pos0.keys().size(), tag + ": no roster change at stage")
	var units: Array = (st.get("unit_ids", []) as Array).duplicate()
	var want_min: int = int(expect.get("min_units", 1))
	_check(units.size() >= want_min, tag + ": staged count ok", {"units": units, "scope": str(st.get("scope_label", "?"))})
	if expect.has("want_ids"):
		var missing: Array = []
		for wid in (expect["want_ids"] as Array):
			if not str(wid) in units:
				missing.append(str(wid))
		_check(missing.is_empty(), tag + ": want ids present", {"missing": missing})
	if str(expect.get("truncation_note", "")) != "":
		_check(str(st.get("scope_label", "")).find("편성") >= 0, tag + ": truncation note", {"scope": str(st.get("scope_label", "?"))})
	if expect.has("full_count"):
		_check(units.size() == int(expect["full_count"]) and str(st.get("scope_label", "")).find("편성") < 0,
			tag + ": complete semantic set staged (%d, no slice note)" % units.size(),
			{"scope": str(st.get("scope_label", "?"))})
	if str(expect.get("exclusion_note", "")) != "":
		_check(str(st.get("scope_label", "")).find("제외") >= 0,
			tag + ": policy exclusion labeled", {"scope": str(st.get("scope_label", "?"))})
	# Full accounting invariant: staged + explicitly-excluded (unevaluable)
	# + deconflict-dropped == resolved semantic total. NOTHING vanishes.
	var sr: Dictionary = dbg.get("scope_resolution", {})
	var total := int(sr.get("total", sr.get("count", -1)))
	if total >= 0:
		var uneval: Array = dbg.get("unevaluable", [])
		var accounted := units.size() + uneval.size() + dropped.size()
		_check(accounted == total, tag + ": all %d resolved units accounted (%d staged+%d excl+%d drop)" % [total, units.size(), uneval.size(), dropped.size()],
			{"scope": str(st.get("scope_label", "?"))})
	var kind := str(st.get("kind", ""))
	if kind == "moves":
		var dests := {}
		var nodest := 0
		for it in (st.get("items", []) as Array):
			var d: Dictionary = (it as Dictionary).get("destination", {})
			if d.is_empty():
				nodest += 1
			else:
				var k := "%d,%d" % [int(d.get("q", 0)), int(d.get("r", 0))]
				dests[k] = int(dests.get(k, 0)) + 1
		var dupes: Array = []
		for k in dests.keys():
			if int(dests[k]) > 1:
				dupes.append(k)
		_check(nodest == 0, tag + ": every item has destination")
		_check(dupes.is_empty(), tag + ": no duplicate staged destinations", {"dupes": dupes})
		_check(not (st.get("preview_routes", []) as Array).is_empty(), tag + ": preview routes present")
	commander.approve_staged()
	var done := await _wait_ms(240000, Callable(self, "_exec_done").bind(commander, svc))
	_check(done, tag + ": execution finished")
	var v1 := int(truth.call("get_version"))
	var pos1 := _positions(truth)
	if kind == "holds":
		_check(pos0 == pos1, tag + ": holds move nothing")
	else:
		_check(v1 > v0, tag + ": version advanced")
		if kind == "moves":
			var staged_dest := {}
			for it in (st.get("items", []) as Array):
				var dd: Dictionary = (it as Dictionary).get("destination", {})
				staged_dest[str((it as Dictionary).get("unit_id", ""))] = [int(dd.get("q", 0)), int(dd.get("r", 0))]
			var mism: Array = []
			for uid in staged_dest.keys():
				if not pos1.has(uid):
					mism.append(str(uid) + ":missing")
				elif pos1[uid] != staged_dest[uid]:
					mism.append(str(uid) + ":moved-elsewhere")
			# Honest accounting (Failure B gate): every staged unit that
			# did not land exactly must be NAMED in the completion text
			# (failed / exec-adapted / contact short-stop), never hidden
			# in a bare count.
			var completion := _last_advisor_text()
			var unnamed: Array = []
			for m in mism:
				var uid2 := str(m).split(":")[0]
				if completion.find(uid2) < 0:
					unnamed.append(uid2)
			_check(unnamed.is_empty(), tag + ": all diverged units named in completion", {"mism": mism, "unnamed": unnamed, "completion": completion.left(300)})
			var missing: Array = []
			for m in mism:
				if str(m).ends_with(":missing"):
					missing.append(m)
			_check(missing.is_empty(), tag + ": no staged unit lost from roster", {"missing": missing})
		var moved := 0
		for uid in pos0.keys():
			if pos1.has(uid) and pos1[uid] != pos0[uid]:
				moved += 1
		_check(moved > 0 or kind == "native", tag + ": movement observed", {"moved": moved})
	_check(_dup_cells(pos1).is_empty(), tag + ": occupancy clean", {"dupes": _dup_cells(pos1)})
	battle.queue_free()
	for _i in range(10):
		await process_frame


func _run() -> void:
	if not _load_raws():
		print("AUDIT_E2E: no phase-1 raws; run step7_audit_phase1.py first")
		quit(2)
		return
	await _case_execute("E_whole", "전군 진격하라", "whole_advance_1", {"min_units": 8})
	await _case_clarify_union()
	await _case_execute("E_scout_recon", "좌익 정찰병 정찰", "sct_recon_left",
		{"min_units": 3, "want_ids": ["B_SCT_1", "B_SCT_2", "B_SCT_4"]})
	await _case_execute("E_inf", "중앙 보병 진격", "inf_center",
		{"min_units": 4, "want_ids": ["B_INF_1", "B_INF_2", "B_INF_3", "B_INF_6"]})
	await _case_execute("E_siege", "공성대 전진", "sie_bare", {"min_units": 2})
	await _case_execute("E_multi", "보병과 창병 둘 다 전진", "multi_inf_spe",
		{"min_units": 12, "full_count": 12})
	await _case_execute("E_hold", "양쪽 대기", "hold_both",
		{"min_units": 14, "full_count": 14})
	await _case_cancel()
	await _case_stale()
	await _case_deictic_freeze()
	await _case_expr_orders()
	await _case_readonly()
	_write()
	print("AUDIT_E2E_DONE pass=%d fail=%d" % [_pass, _fail.size()])
	for f in _fail:
		print("AUDIT_E2E_FAIL: " + str(f))
	quit(0 if _fail.is_empty() else 1)


func _case_clarify_union() -> void:
	var tag := "E_cav_union"
	var booted := await _boot()
	if booted.is_empty():
		_check(false, tag + ": boot")
		return
	var battle: Node = booted[0]
	var integration: Node = booted[1]
	var wired := await _wire(battle, integration, {"기병 전진": "cav_bare", "둘다": "both_answer"})
	var commander: Node = wired[1]
	var truth: RefCounted = integration.get("truth")
	var svc: RefCounted = integration.get("action_service")
	var v0 := int(truth.call("get_version"))
	var pos0 := _positions(truth)
	var s1 := await _send_and_settle(commander, "기병 전진")
	_check(s1, tag + ": step1 settled")
	_check(commander.has_pending() and not commander.has_staged(), tag + ": step1 asks")
	var s2 := await _send_and_settle(commander, "둘다")
	_check(s2, tag + ": step2 settled")
	_check(commander.has_staged(), tag + ": step2 UNION staged")
	if commander.has_staged():
		var st: Dictionary = commander.staged_summary()
		var units: Array = st.get("unit_ids", [])
		_check(units.size() == 4, tag + ": both wings staged", {"units": units})
		_check(int(truth.call("get_version")) == v0, tag + ": no mutation before execute")
		commander.approve_staged()
		var done := await _wait_ms(240000, Callable(self, "_exec_done").bind(commander, svc))
		_check(done, tag + ": executed")
		var pos1 := _positions(truth)
		var moved := 0
		for uid in ["B_CAV_1", "B_CAV_2", "B_CAV_3", "B_CAV_4"]:
			if pos1.has(uid) and pos1[uid] != pos0.get(uid, []):
				moved += 1
		_check(moved == 4, tag + ": all 4 cavalry moved", {"moved": moved})
		_check(_dup_cells(pos1).is_empty(), tag + ": occupancy clean")
	battle.queue_free()
	for _i in range(10):
		await process_frame


func _case_cancel() -> void:
	var tag := "E_cancel"
	var booted := await _boot()
	if booted.is_empty():
		_check(false, tag + ": boot")
		return
	var battle: Node = booted[0]
	var integration: Node = booted[1]
	var wired := await _wire(battle, integration, {"중앙 보병 진격": "inf_center"})
	var commander: Node = wired[1]
	var truth: RefCounted = integration.get("truth")
	var v0 := int(truth.call("get_version"))
	var pos0 := _positions(truth)
	var s := await _send_and_settle(commander, "중앙 보병 진격")
	_check(s and commander.has_staged(), tag + ": staged before cancel")
	commander.cancel_staged()
	for _i in range(10):
		await process_frame
	_check(not commander.has_staged(), tag + ": stage cleared")
	_check(int(truth.call("get_version")) == v0 and _positions(truth) == pos0, tag + ": cancel moves nothing")
	battle.queue_free()
	for _i in range(10):
		await process_frame


## Stale-stage gate (invariant 7): mutate the world after staging, then
## approve. The stale plan must NOT execute; the commander must regen from
## the original text and re-stage (stub transport answers the fresh
## selection round deterministically).
func _case_stale() -> void:
	var tag := "E_stale"
	var booted := await _boot()
	if booted.is_empty():
		_check(false, tag + ": boot")
		return
	var battle: Node = booted[0]
	var integration: Node = booted[1]
	var spec := {}
	spec["중앙 보병 진격"] = "inf_center"
	var wired := await _wire(battle, integration, spec)
	var commander: Node = wired[1]
	var truth: RefCounted = integration.get("truth")
	var svc: RefCounted = integration.get("action_service")
	_chatlog = []
	commander.chat_append.connect(_on_audit_chat)
	var settled := await _send_and_settle(commander, "중앙 보병 진격")
	_check(settled and commander.has_staged(), tag + ": staged")
	if not commander.has_staged():
		battle.queue_free()
		return
	var staged_units: Array = (commander.staged_summary().get("unit_ids", []) as Array).duplicate()
	var pos_stage := _positions(truth)
	var v_stage := int(truth.call("get_version"))
	# World moves under the staged plan: find ANY legal single-step nudge
	# for B_INF_7 (probed, never guessed) and execute it canonically.
	var base: Dictionary = truth.call("get_unit", "B_INF_7")
	var nudge := {}
	var offsets := [[1, 0], [1, -1], [0, -1], [-1, 0], [-1, 1], [0, 1]]
	for off in offsets:
		var cand := {"action": "MOVE",
			"scope": {"type": "UNIT_ID", "unit_id": "B_INF_7"},
			"direction": "",
			"target": {"type": "HEX", "q": int(base.get("q", 0)) + int(off[0]), "r": int(base.get("r", 0)) + int(off[1])},
			"posture": "NORMAL", "constraints": {}}
		var vdx: Dictionary = svc.call("validate_action", cand, "blue")
		if bool(vdx.get("ok", false)):
			nudge = cand
			break
	_check(not nudge.is_empty(), tag + ": setup nudge found")
	if nudge.is_empty():
		battle.queue_free()
		return
	var plan: Dictionary = svc.call("plan_action", nudge, "blue")
	svc.call("execute_plan", str(plan.get("plan_id", "")))
	var drained := await _wait_ms(120000, Callable(self, "_svc_idle").bind(svc))
	_check(drained, tag + ": world mutated")
	_check(int(truth.call("get_version")) > v_stage, tag + ": version advanced under stage")
	commander.approve_staged()
	var regen := await _wait_ms(180000, Callable(self, "_restaged").bind(commander))
	_check(regen, tag + ": stale plan NOT executed, regen re-staged")
	var saw_review := false
	for line in _chatlog:
		if str(line).find("다시 검토") >= 0:
			saw_review = true
	_check(saw_review, tag + ": player told about re-review")
	var pos_after := _positions(truth)
	var stale_moved: Array = []
	for uid in staged_units:
		if pos_after.get(str(uid), []) != pos_stage.get(str(uid), []):
			stale_moved.append(str(uid))
	_check(stale_moved.is_empty(), tag + ": no stale execution of staged units", {"moved": stale_moved})
	battle.queue_free()
	for _i in range(10):
		await process_frame


## Deictic freeze: stage "this unit" with B_CAV_2 selected, then change
## the map selection to B_CAV_4 BEFORE approval. The frozen B_CAV_2 must
## move; the newly selected unit must NOT be hijacked.
func _case_deictic_freeze() -> void:
	var tag := "E_deictic_freeze"
	var booted := await _boot()
	if booted.is_empty():
		_check(false, tag + ": boot")
		return
	var battle: Node = booted[0]
	var integration: Node = booted[1]
	var um: RefCounted = integration.get("unit_manager")
	var spec := {}
	spec["이 부대 앞으로"] = "deictic"
	var wired := await _wire(battle, integration, spec)
	var commander: Node = wired[1]
	var truth: RefCounted = integration.get("truth")
	var svc: RefCounted = integration.get("action_service")
	um.call("select_unit", "B_CAV_2")
	for _i in range(10):
		await process_frame
	var settled := await _send_and_settle(commander, "이 부대 앞으로")
	_check(settled and commander.has_staged(), tag + ": staged")
	if not commander.has_staged():
		battle.queue_free()
		return
	var st: Dictionary = commander.staged_summary()
	_check((st.get("unit_ids", []) as Array) == ["B_CAV_2"], tag + ": frozen to pointed unit",
		{"units": st.get("unit_ids", [])})
	var pos0 := _positions(truth)
	um.call("select_unit", "B_CAV_4")
	for _i in range(10):
		await process_frame
	commander.approve_staged()
	var done := await _wait_ms(240000, Callable(self, "_exec_done").bind(commander, svc))
	_check(done, tag + ": executed")
	var pos1 := _positions(truth)
	_check(pos1.get("B_CAV_2", []) != pos0.get("B_CAV_2", []), tag + ": frozen unit moved")
	_check(pos1.get("B_CAV_4", []) == pos0.get("B_CAV_4", []), tag + ": new selection untouched")
	battle.queue_free()
	for _i in range(10):
		await process_frame


## Composite driven by REAL model outputs (raws from the live Phase-1
## matrix): one combined stage, canonical execution, movement confined
## to staged units, must-move set honored.
func _case_composite_live(text: String, raw_tag: String, must_move: Array,
		hold_total: int) -> void:
	var tag := "E_comp_live_" + raw_tag
	var booted := await _boot()
	if booted.is_empty():
		_check(false, tag + ": boot")
		return
	var battle: Node = booted[0]
	var integration: Node = booted[1]
	var spec := {}
	spec[text] = raw_tag
	var wired := await _wire(battle, integration, spec)
	var commander: Node = wired[1]
	var truth: RefCounted = integration.get("truth")
	var svc: RefCounted = integration.get("action_service")
	_chatlog = []
	commander.chat_append.connect(_on_audit_chat)
	var settled := await _send_and_settle(commander, text)
	_check(settled and commander.has_staged(), tag + ": staged")
	if not commander.has_staged():
		battle.queue_free()
		return
	var st: Dictionary = commander.staged_summary()
	_check(str(st.get("kind", "")) == "composite", tag + ": kind composite")
	var staged: Array = st.get("unit_ids", [])
	var pos0 := _positions(truth)
	commander.approve_staged()
	var done := await _wait_ms(300000, Callable(self, "_exec_done").bind(commander, svc))
	_check(done, tag + ": executed")
	var pos1 := _positions(truth)
	var moved: Array = []
	for uid in pos0.keys():
		if pos1.has(uid) and pos1[uid] != pos0[uid]:
			moved.append(uid)
	var missing_move: Array = []
	for uid in must_move:
		if not uid in moved:
			missing_move.append(str(uid))
	_check(missing_move.is_empty(), tag + ": must-move set moved", {"missing": missing_move})
	var leaked: Array = []
	for uid in moved:
		if not uid in staged:
			leaked.append(str(uid))
	_check(leaked.is_empty(), tag + ": movement confined to staged", {"leaked": leaked})
	if hold_total >= 0:
		_check(staged.size() == moved.size() + hold_total, tag + ": holds accounted",
			{"staged": staged.size(), "moved": moved.size(), "holds": hold_total})
	_check(_dup_cells(pos1).is_empty(), tag + ": occupancy clean")
	battle.queue_free()
	for _i in range(10):
		await process_frame


func _svc_idle(svc: RefCounted) -> bool:
	return not bool(svc.call("is_executing"))


func _comp_raw(order_jsons: Array) -> String:
	return JSON.stringify({"request_type": "COMMAND", "orders": order_jsons,
		"confidence": 0.9, "question": "", "missing": []})


func _comp_order(action: String, scope: Dictionary, style: Dictionary, conf: float, ex: Dictionary = {}) -> Dictionary:
	return {"action": action, "scope": scope, "scope_expr": ex,
		"style": style, "confidence": conf}


func _std_style() -> Dictionary:
	return {"risk": "balanced", "pressure": "balanced", "depth": "normal"}


## Composite disjoint (hand-shaped model output): ADVANCE scouts +
## HOLD(ALL-SCOUT) stages ONE combined plan and executes canonically.
func _case_composite_disjoint() -> void:
	var tag := "E_comp_disjoint"
	var adv_scope := {"type": "WING_CLASS", "class": "SCOUT", "region": "LEFT", "unit_id": ""}
	var hold_scope := {"type": "ALL_AVAILABLE", "class": "ALL_ARMS", "region": "ALL", "unit_id": ""}
	_raws["comp_disjoint"] = _comp_raw([
		_comp_order("ADVANCE", adv_scope, _std_style(), 0.9),
		_comp_order("HOLD", hold_scope, _std_style(), 0.9,
			{"op": "DIFF", "left": {"op": "ALL_FRIENDLY"}, "right": {"op": "CLASS", "class": "SCOUT"}})])
	var booted := await _boot()
	if booted.is_empty():
		_check(false, tag + ": boot")
		return
	var battle: Node = booted[0]
	var integration: Node = booted[1]
	var spec := {}
	spec["정찰병은 전진하고 나머지는 대기"] = "comp_disjoint"
	var wired := await _wire(battle, integration, spec)
	var commander: Node = wired[1]
	var truth: RefCounted = integration.get("truth")
	var svc: RefCounted = integration.get("action_service")
	_chatlog = []
	commander.chat_append.connect(_on_audit_chat)
	var settled := await _send_and_settle(commander, "정찰병은 전진하고 나머지는 대기")
	_check(settled and commander.has_staged(), tag + ": one combined stage")
	if not commander.has_staged():
		battle.queue_free()
		return
	var st: Dictionary = commander.staged_summary()
	_check(str(st.get("kind", "")) == "composite", tag + ": kind composite", {"kind": str(st.get("kind", "?"))})
	var units: Array = st.get("unit_ids", [])
	_check(units.size() >= 30, tag + ": moves+holds combined (%d)" % units.size(), {"scope": str(st.get("scope_label", "?"))})
	var v0 := int(truth.call("get_version"))
	var pos0 := _positions(truth)
	_check(v0 == int(truth.call("get_version")), tag + ": no mutation before execute")
	commander.approve_staged()
	var done := await _wait_ms(300000, Callable(self, "_exec_done").bind(commander, svc))
	_check(done, tag + ": executed")
	var pos1 := _positions(truth)
	var scout_moved := 0
	for uid in ["B_SCT_1", "B_SCT_2", "B_SCT_4"]:
		if pos1.has(uid) and pos1[uid] != pos0.get(uid, []):
			scout_moved += 1
	_check(scout_moved == 3, tag + ": scouts advanced", {"moved": scout_moved})
	var rest_moved := 0
	for uid in pos0.keys():
		if not uid in ["B_SCT_1", "B_SCT_2", "B_SCT_4"] and pos1.has(uid) and pos1[uid] != pos0[uid]:
			rest_moved += 1
	_check(rest_moved == 0, tag + ": remainder held (zero movement)", {"moved": rest_moved})
	_check(_dup_cells(pos1).is_empty(), tag + ": occupancy clean")
	var completion := _last_advisor_text()
	_check(completion.find("복합") >= 0 or completion.find("대기") >= 0, tag + ": mixed completion",
		{"text": completion.left(200)})
	battle.queue_free()
	for _i in range(10):
		await process_frame


## Composite cancel: stage the combined plan, then cancel. Zero mutation,
## stage cleared, preview cleared.
func _case_composite_cancel() -> void:
	var tag := "E_comp_cancel"
	var booted := await _boot()
	if booted.is_empty():
		_check(false, tag + ": boot")
		return
	var battle: Node = booted[0]
	var integration: Node = booted[1]
	var spec := {}
	spec["정찰병은 전진하고 나머지는 대기"] = "comp_disjoint"
	var wired := await _wire(battle, integration, spec)
	var commander: Node = wired[1]
	var truth: RefCounted = integration.get("truth")
	var v0 := int(truth.call("get_version"))
	var pos0 := _positions(truth)
	var settled := await _send_and_settle(commander, "정찰병은 전진하고 나머지는 대기")
	_check(settled and commander.has_staged(), tag + ": staged")
	commander.cancel_staged()
	for _i in range(10):
		await process_frame
	_check(not commander.has_staged(), tag + ": cleared")
	_check(int(truth.call("get_version")) == v0 and _positions(truth) == pos0, tag + ": zero mutation")
	battle.queue_free()
	for _i in range(10):
		await process_frame


## Composite conflict (hand-shaped): ADVANCE(LEFT-combat) + HOLD(CAVALRY)
## overlap on LEFT cavalry with conflicting actions -> clarify, no stage.
func _case_composite_conflict() -> void:
	var tag := "E_comp_conflict"
	_raws["comp_conflict"] = _comp_raw([
		_comp_order("ADVANCE", {"type": "WING_CLASS", "class": "ALL_ARMS", "region": "LEFT", "unit_id": ""}, _std_style(), 0.9),
		_comp_order("HOLD", {"type": "WING_CLASS", "class": "CAVALRY", "region": "ALL", "unit_id": ""}, _std_style(), 0.9)])
	var booted := await _boot()
	if booted.is_empty():
		_check(false, tag + ": boot")
		return
	var battle: Node = booted[0]
	var integration: Node = booted[1]
	var spec := {}
	spec["좌익은 전진하고 기병은 대기"] = "comp_conflict"
	var wired := await _wire(battle, integration, spec)
	var commander: Node = wired[1]
	var truth: RefCounted = integration.get("truth")
	var v0 := int(truth.call("get_version"))
	var settled := await _send_and_settle(commander, "좌익은 전진하고 기병은 대기")
	_check(settled and commander.has_pending() and not commander.has_staged(), tag + ": conflict clarifies")
	_check(int(truth.call("get_version")) == v0, tag + ": nothing staged, nothing moved")
	battle.queue_free()
	for _i in range(10):
		await process_frame


## Empty-expression safety: INTERSECT(LEFT, SIEGE) is empty on the live
## map. Must resolve honestly, stage nothing, ask nothing, and NEVER
## invoke tactical selection (no select transport call).
func _case_expr_empty() -> void:
	var tag := "E_expr_empty"
	var booted := await _boot()
	if booted.is_empty():
		_check(false, tag + ": boot")
		return
	var battle: Node = booted[0]
	var integration: Node = booted[1]
	var spec := {}
	spec["좌익 공성 전진"] = "expr_empty"
	var wired := await _wire(battle, integration, spec)
	var commander: Node = wired[1]
	var stub: Node = wired[2]
	var truth: RefCounted = integration.get("truth")
	var v0 := int(truth.call("get_version"))
	stub.phases = []
	var settled := await _send_and_settle(commander, "좌익 공성 전진")
	_check(settled, tag + ": settled")
	_check(not commander.has_staged() and not commander.has_pending(), tag + ": nothing staged, nothing asked")
	_check(not ("select" in stub.phases), tag + ": selection never invoked", {"phases": stub.phases})
	_check(int(truth.call("get_version")) == v0, tag + ": world untouched")
	battle.queue_free()
	for _i in range(10):
		await process_frame


## Expression stale gate: stage an INTERSECT set, mutate the world, then
## approve. Must regen (never stale-execute); the frozen membership must
## not leak across the regen.
func _case_expr_stale() -> void:
	var tag := "E_expr_stale"
	var booted := await _boot()
	if booted.is_empty():
		_check(false, tag + ": boot")
		return
	var battle: Node = booted[0]
	var integration: Node = booted[1]
	var spec := {}
	spec["좌익 기병 전진"] = "expr_adv"
	var wired := await _wire(battle, integration, spec)
	var commander: Node = wired[1]
	var truth: RefCounted = integration.get("truth")
	var svc: RefCounted = integration.get("action_service")
	_chatlog = []
	commander.chat_append.connect(_on_audit_chat)
	var settled := await _send_and_settle(commander, "좌익 기병 전진")
	_check(settled and commander.has_staged(), tag + ": staged")
	if not commander.has_staged():
		battle.queue_free()
		return
	var staged_units: Array = (commander.staged_summary().get("unit_ids", []) as Array).duplicate()
	var pos_stage := _positions(truth)
	var base: Dictionary = truth.call("get_unit", "B_INF_7")
	var nudge := {}
	var offsets := [[1, 0], [1, -1], [0, -1], [-1, 0], [-1, 1], [0, 1]]
	for off in offsets:
		var cand := {"action": "MOVE",
			"scope": {"type": "UNIT_ID", "unit_id": "B_INF_7"},
			"direction": "",
			"target": {"type": "HEX", "q": int(base.get("q", 0)) + int(off[0]), "r": int(base.get("r", 0)) + int(off[1])},
			"posture": "NORMAL", "constraints": {}}
		var vdx: Dictionary = svc.call("validate_action", cand, "blue")
		if bool(vdx.get("ok", false)):
			nudge = cand
			break
	_check(not nudge.is_empty(), tag + ": setup nudge found")
	if nudge.is_empty():
		battle.queue_free()
		return
	var plan: Dictionary = svc.call("plan_action", nudge, "blue")
	svc.call("execute_plan", str(plan.get("plan_id", "")))
	var drained := await _wait_ms(120000, Callable(self, "_svc_idle").bind(svc))
	_check(drained, tag + ": world mutated")
	commander.approve_staged()
	var regen := await _wait_ms(180000, Callable(self, "_restaged").bind(commander))
	_check(regen, tag + ": stale plan NOT executed, regen re-staged")
	var pos_after := _positions(truth)
	var stale_moved: Array = []
	for uid in staged_units:
		if pos_after.get(str(uid), []) != pos_stage.get(str(uid), []):
			stale_moved.append(str(uid))
	_check(stale_moved.is_empty(), tag + ": no stale execution", {"moved": stale_moved})
	battle.queue_free()
	for _i in range(10):
		await process_frame


## Expression-scope execution proof (hand-written model-shaped Phase-1
## raws carrying scope_expr ASTs): HOLD(DIFF) stages through the existing
## holds machinery; ADVANCE(INTERSECT) stages moves. Zero model.
func _case_expr_orders() -> void:
	_raws["expr_hold"] = "{\"request_type\":\"COMMAND\",\"action\":\"HOLD\",\"scope\":{\"type\":\"ALL_AVAILABLE\",\"class\":\"ALL_ARMS\",\"region\":\"ALL\",\"unit_id\":\"\",\"regions\":[]},\"scope_expr\":{\"op\":\"DIFF\",\"left\":{\"op\":\"ALL_FRIENDLY\"},\"right\":{\"op\":\"CLASS\",\"class\":\"SCOUT\"}},\"style\":{\"risk\":\"balanced\",\"pressure\":\"balanced\",\"depth\":\"normal\"},\"confidence\":0.9,\"question\":\"\",\"missing\":[]}"
	_raws["expr_adv"] = "{\"request_type\":\"COMMAND\",\"action\":\"ADVANCE\",\"scope\":{\"type\":\"WING_CLASS\",\"class\":\"CAVALRY\",\"region\":\"LEFT\",\"unit_id\":\"\",\"regions\":[]},\"scope_expr\":{\"op\":\"INTERSECT\",\"args\":[{\"op\":\"WING\",\"wing\":\"LEFT\"},{\"op\":\"CLASS\",\"class\":\"CAVALRY\"}]},\"style\":{\"risk\":\"balanced\",\"pressure\":\"balanced\",\"depth\":\"normal\"},\"confidence\":0.92,\"question\":\"\",\"missing\":[]}"
	_raws["expr_hold_ci"] = "{\"request_type\":\"COMMAND\",\"action\":\"HOLD\",\"scope\":{\"type\":\"WING_CLASS\",\"class\":\"INFANTRY\",\"region\":\"CENTER\",\"unit_id\":\"\",\"regions\":[]},\"scope_expr\":{\"op\":\"INTERSECT\",\"args\":[{\"op\":\"WING\",\"wing\":\"CENTER\"},{\"op\":\"CLASS\",\"class\":\"INFANTRY\"}]},\"style\":{\"risk\":\"balanced\",\"pressure\":\"balanced\",\"depth\":\"normal\"},\"confidence\":0.9,\"question\":\"\",\"missing\":[]}"
	_raws["expr_hold_cavdiff"] = "{\"request_type\":\"COMMAND\",\"action\":\"HOLD\",\"scope\":{\"type\":\"WING_CLASS\",\"class\":\"CAVALRY\",\"region\":\"RIGHT\",\"unit_id\":\"\",\"regions\":[]},\"scope_expr\":{\"op\":\"DIFF\",\"left\":{\"op\":\"CLASS\",\"class\":\"CAVALRY\"},\"right\":{\"op\":\"INTERSECT\",\"args\":[{\"op\":\"WING\",\"wing\":\"LEFT\"},{\"op\":\"CLASS\",\"class\":\"CAVALRY\"}]}},\"style\":{\"risk\":\"balanced\",\"pressure\":\"balanced\",\"depth\":\"normal\"},\"confidence\":0.9,\"question\":\"\",\"missing\":[]}"
	_raws["expr_adv_center"] = "{\"request_type\":\"COMMAND\",\"action\":\"ADVANCE\",\"scope\":{\"type\":\"UNION\",\"class\":\"\",\"region\":\"\",\"unit_id\":\"\",\"regions\":[\"ALL\"],\"classes\":[\"INFANTRY\",\"SPEARMAN\"]},\"scope_expr\":{\"op\":\"INTERSECT\",\"args\":[{\"op\":\"WING\",\"wing\":\"CENTER\"},{\"op\":\"UNION\",\"args\":[{\"op\":\"CLASS\",\"class\":\"INFANTRY\"},{\"op\":\"CLASS\",\"class\":\"SPEARMAN\"}]}]},\"style\":{\"risk\":\"balanced\",\"pressure\":\"balanced\",\"depth\":\"normal\"},\"confidence\":0.9,\"question\":\"\",\"missing\":[]}"
	_raws["expr_empty"] = "{\"request_type\":\"COMMAND\",\"action\":\"ADVANCE\",\"scope\":{\"type\":\"WING_CLASS\",\"class\":\"SIEGE\",\"region\":\"LEFT\",\"unit_id\":\"\",\"regions\":[]},\"scope_expr\":{\"op\":\"INTERSECT\",\"args\":[{\"op\":\"WING\",\"wing\":\"LEFT\"},{\"op\":\"CLASS\",\"class\":\"SIEGE\"}]},\"style\":{\"risk\":\"balanced\",\"pressure\":\"balanced\",\"depth\":\"normal\"},\"confidence\":0.9,\"question\":\"\",\"missing\":[]}"
	_raws["expr_all_adv"] = "{\"request_type\":\"COMMAND\",\"action\":\"ADVANCE\",\"scope\":{\"type\":\"ALL_AVAILABLE\",\"class\":\"ALL_ARMS\",\"region\":\"ALL\",\"unit_id\":\"\",\"regions\":[]},\"scope_expr\":{\"op\":\"DIFF\",\"left\":{\"op\":\"ALL_FRIENDLY\"},\"right\":{\"op\":\"CLASS\",\"class\":\"SCOUT\"}},\"style\":{\"risk\":\"balanced\",\"pressure\":\"balanced\",\"depth\":\"normal\"},\"confidence\":0.9,\"question\":\"\",\"missing\":[]}"
	await _case_execute("E_expr_hold", "정찰병 제외하고 전군 대기", "expr_hold",
		{"min_units": 32, "full_count": 32})
	await _case_execute("E_expr_adv", "좌익 기병 전진", "expr_adv",
		{"min_units": 3, "want_ids": ["B_CAV_1", "B_CAV_2", "B_CAV_3"]})
	await _case_execute("E_expr_hold_ci", "중앙 보병 대기", "expr_hold_ci",
		{"min_units": 4, "full_count": 4,
			"want_ids": ["B_INF_1", "B_INF_2", "B_INF_3", "B_INF_6"]})
	await _case_execute("E_expr_hold_cavdiff", "좌익 제외 기병 대기", "expr_hold_cavdiff",
		{"min_units": 1, "full_count": 1, "want_ids": ["B_CAV_4"]})
	await _case_execute("E_expr_adv_center", "중앙 보병과 창병 전진", "expr_adv_center",
		{"min_units": 8, "full_count": 8})
	await _case_expr_empty()
	await _case_expr_stale()
	await _case_composite_disjoint()
	await _case_composite_conflict()
	await _case_composite_cancel()
	await _case_composite_live("정찰병은 전진하고 나머지는 대기", "comp_scout",
		["B_SCT_1", "B_SCT_2", "B_SCT_3", "B_SCT_4", "B_SCT_5"], 32)
	await _case_composite_live("좌익은 대기하고 우익은 전진", "comp_wings",
		[], -1)
	await _case_composite_cancel()
	await _case_execute("E_expr_all_adv", "정찰 제외 전군 전진", "expr_all_adv",
		{"min_units": 26, "exclusion_note": "yes"})


func _restaged(commander: Node) -> bool:
	return commander.has_staged()


func _case_readonly() -> void:
	var booted := await _boot()
	if booted.is_empty():
		_check(false, "R: boot")
		return
	var battle: Node = booted[0]
	var integration: Node = booted[1]
	var um: RefCounted = integration.get("unit_manager")
	var texts := {
		"좌익 철수": "ret_left",
		"지휘부 전진": "hq",
		"보급대 전진": "sup",
		"기병 우회": "cav_flank",
		"보병으로 궁병 보호해": "protect",
		"지금 전황이 어때": "advice",
		"어떤 기동이 좋을까": "advice_which",
		"음...": "vague",
		"김치찌개 먹고 싶다": "nonsense",
		"아까 말한 대로 해": "prev_do2",
		"정찰병 깊게 정찰": "sct_deep",
	}
	var wired := await _wire(battle, integration, texts)
	var commander: Node = wired[1]
	var truth: RefCounted = integration.get("truth")
	var v0 := int(truth.call("get_version"))
	for text in texts.keys():
		var t := str(text)
		var settled := await _send_and_settle(commander, t)
		var is_pending: bool = commander.has_pending()
		var is_staged: bool = commander.has_staged()
		if t == "정찰병 깊게 정찰":
			_check(settled and is_pending and not is_staged, "R_scout_bare: asks wings")
		elif t == "지금 전황이 어때":
			_check(settled and not is_staged and not is_pending, "R_info: answered, nothing staged")
		elif t in ["어떤 기동이 좋을까", "음...", "김치찌개 먹고 싶다", "아까 말한 대로 해"]:
			_check(settled and is_pending and not is_staged, "R_clarify open", {"text": t})
		else:
			_check(settled and not is_staged, "R_limit open", {"text": t})
		commander.cancel()
		for _i in range(5):
			await process_frame
	_check(int(truth.call("get_version")) == v0, "R: read-only cases mutate nothing")
	# Class-less RECON UNION backstop (hand-written model-shaped raw: UNION
	# with no combat class must ASK, never mislabel as policy case).
	(commander.get("_client") as Node).raws["양쪽 정찰"] = "{\"request_type\":\"COMMAND\",\"action\":\"RECON\",\"scope\":{\"type\":\"UNION\",\"class\":\"ALL_ARMS\",\"region\":\"\",\"unit_id\":\"\",\"regions\":[\"LEFT\",\"RIGHT\"]},\"style\":{\"risk\":\"balanced\",\"pressure\":\"balanced\",\"depth\":\"normal\"},\"confidence\":0.9,\"question\":\"\",\"missing\":[]}"
	var sb := await _send_and_settle(commander, "양쪽 정찰")
	_check(sb and commander.has_pending() and not commander.has_staged(),
		"R_recon_noclass: asks class")
	commander.cancel()
	for _i in range(5):
		await process_frame
	um.call("select_unit", "B_CAV_2")
	for _i in range(10):
		await process_frame
	(commander.get("_client") as Node).raws["이 부대 앞으로"] = str(_raws.get("deictic", ""))
	var sd := await _send_and_settle(commander, "이 부대 앞으로")
	var st: Dictionary = commander.staged_summary()
	_check(sd and commander.has_staged() and (st.get("unit_ids", []) as Array) == ["B_CAV_2"],
		"R_deictic: selected unit staged", {"units": st.get("unit_ids", [])})
	battle.queue_free()
	for _i in range(10):
		await process_frame


func _write() -> void:
	var f := FileAccess.open(OUT_PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({"pass": _pass, "failures": _fail, "results": _results}))
		f.close()
