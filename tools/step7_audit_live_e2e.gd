extends SceneTree

## LIVE real-model E2E: the REAL commander + REAL Ollama transport, zero
## stubs. Human-passed invariants + scout RECON through the full path:
## chat -> Phase-1 -> scope -> packages -> Phase-2 -> stage -> preview ->
## approve/cancel -> canonical execution. Fresh boot per movement case.
## Evidence: tools/.audit_live_e2e.json. quit 0 = all pass.

const OUT := "D:/Game development/Demon slayer/StrategyGame/tools/.audit_live_e2e.json"

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


func _on_chat(author: String, text: String) -> void:
	_chatlog.append(str(author) + ": " + str(text))
	print("CHAT %s: %s" % [author, text.left(220)])


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
	for _i in range(300):
		if integration and bool(integration.get("ready_for_step7")):
			break
		await process_frame
	if integration == null or not bool(integration.get("ready_for_step7")):
		return []
	for _i in range(30):
		await process_frame
	return [battle, integration]


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


func _send_settle(commander: Node, text: String) -> bool:
	commander.send_chat(text)
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 600000:
		await process_frame
		if not commander.has_active():
			return true
	return not commander.has_active()


func _run() -> void:
	await _live_case("LIVE_whole", ["전군 진격하라"], true)
	await _live_cav_union()
	await _live_case("LIVE_scout", ["좌익 정찰병 정찰"], true)
	await _live_cancel()
	await _live_case("LIVE_ast_hold", ["정찰병 제외하고 전군 대기"], true, false)
	await _live_case("LIVE_ast_adv", ["좌익 기병 전진"], true)
	await _live_case("LIVE_multi", ["보병과 창병 둘 다 전진"], true)
	var f := FileAccess.open(OUT, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({"pass": _pass, "failures": _fail, "results": _results}))
		f.close()
	print("AUDIT_LIVE_DONE pass=%d fail=%d" % [_pass, _fail.size()])
	for x in _fail:
		print("AUDIT_LIVE_FAIL: " + str(x))
	quit(0 if _fail.is_empty() else 1)


func _live_case(tag: String, texts: Array, approve: bool, expect_move: bool = true) -> void:
	var booted := await _boot()
	if booted.is_empty():
		_check(false, tag + ": boot")
		return
	var battle: Node = booted[0]
	var integration: Node = booted[1]
	var adapter: Node = integration.get("_advisor_adapter")
	var commander: Node = adapter.get("_commander")
	_chatlog = []
	commander.chat_append.connect(_on_chat)
	var truth: RefCounted = integration.get("truth")
	var svc: RefCounted = integration.get("action_service")
	_check(bool(commander.call("is_ready")), tag + ": commander ready")
	var v0 := int(truth.call("get_version"))
	var pos0 := _positions(truth)
	for text in texts:
		var ok := await _send_settle(commander, str(text))
		_check(ok, tag + ": settled", {"text": str(text)})
	_check(commander.has_staged(), tag + ": staged", commander.staged_summary())
	if not commander.has_staged():
		var dbg: Dictionary = commander.debug_snapshot()
		_results.append({"label": tag + ": debug", "ok": true,
			"info": {"failure": str(dbg.get("failure", "?")),
				"outcome": str(dbg.get("outcome", "?")),
				"trace": dbg.get("trace", [])}})
		battle.queue_free()
		return
	var st: Dictionary = commander.staged_summary()
	_check(int(truth.call("get_version")) == v0, tag + ": no mutation before execute")
	_results.append({"label": tag + ": stagedetail", "ok": true,
		"info": {"kind": str(st.get("kind", "?")),
			"scope": str(st.get("scope_label", "?")),
			"units": (st.get("unit_ids", []) as Array).duplicate()}})
	if approve:
		commander.approve_staged()
		var done := await _wait_ms(300000, Callable(self, "_exec_done").bind(commander, svc))
		_check(done, tag + ": execution finished")
		_check(int(truth.call("get_version")) > v0, tag + ": world moved")
		var pos1 := _positions(truth)
		var moved := 0
		for uid in pos0.keys():
			if pos1.has(uid) and pos1[uid] != pos0[uid]:
				moved += 1
		if expect_move:
			_check(moved > 0, tag + ": movement observed", {"moved": moved})
		else:
			_check(moved == 0 and pos1 == pos0, tag + ": holds move nothing", {"moved": moved})
		var dupes := _dup_cells(pos1)
		_check(dupes.is_empty(), tag + ": occupancy clean", {"dupes": dupes})
	battle.queue_free()
	for _i in range(10):
		await process_frame


func _live_cav_union() -> void:
	var tag := "LIVE_cav_union"
	var booted := await _boot()
	if booted.is_empty():
		_check(false, tag + ": boot")
		return
	var battle: Node = booted[0]
	var integration: Node = booted[1]
	var adapter: Node = integration.get("_advisor_adapter")
	var commander: Node = adapter.get("_commander")
	_chatlog = []
	commander.chat_append.connect(_on_chat)
	var truth: RefCounted = integration.get("truth")
	var svc: RefCounted = integration.get("action_service")
	var v0 := int(truth.call("get_version"))
	var pos0 := _positions(truth)
	_check(await _send_settle(commander, "기병 전진"), tag + ": step1 settled")
	_check(commander.has_pending() and not commander.has_staged(), tag + ": step1 asks")
	_check(await _send_settle(commander, "둘다"), tag + ": step2 settled")
	_check(commander.has_staged(), tag + ": step2 staged", commander.staged_summary())
	if commander.has_staged():
		_check(int(truth.call("get_version")) == v0, tag + ": no mutation before execute")
		commander.approve_staged()
		var done := await _wait_ms(300000, Callable(self, "_exec_done").bind(commander, svc))
		_check(done, tag + ": executed")
		var pos1 := _positions(truth)
		var moved := 0
		for uid in ["B_CAV_1", "B_CAV_2", "B_CAV_3", "B_CAV_4"]:
			if pos1.has(uid) and pos1[uid] != pos0.get(uid, []):
				moved += 1
		_check(moved == 4, tag + ": all cavalry moved", {"moved": moved})
	battle.queue_free()
	for _i in range(10):
		await process_frame


func _live_cancel() -> void:
	var tag := "LIVE_cancel"
	var booted := await _boot()
	if booted.is_empty():
		_check(false, tag + ": boot")
		return
	var battle: Node = booted[0]
	var integration: Node = booted[1]
	var adapter: Node = integration.get("_advisor_adapter")
	var commander: Node = adapter.get("_commander")
	_chatlog = []
	commander.chat_append.connect(_on_chat)
	var truth: RefCounted = integration.get("truth")
	var v0 := int(truth.call("get_version"))
	var pos0 := _positions(truth)
	_check(await _send_settle(commander, "중앙 보병 진격"), tag + ": settled")
	_check(commander.has_staged(), tag + ": staged")
	commander.cancel_staged()
	for _i in range(10):
		await process_frame
	_check(not commander.has_staged(), tag + ": cleared")
	_check(int(truth.call("get_version")) == v0 and _positions(truth) == pos0, tag + ": zero movement")
	battle.queue_free()
	for _i in range(10):
		await process_frame


func _exec_done(commander: Node, svc: RefCounted) -> bool:
	return not commander.has_staged() and not bool(svc.call("is_executing"))


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
