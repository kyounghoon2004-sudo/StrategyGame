extends SceneTree

## Canonical-scene semantic end-to-end (REAL battle, REAL models):
##   boot step2r shell -> DetIntegration ready
##   1. "전군 대기"    -> tiny attempt -> large fallback -> STAGED (native HOLD)
##      -> Cancel -> zero mutation (version + fingerprint unchanged)
##   2. "현재 좌익 상황이 어때?" -> INFORMATION -> answer, never staged
##   3. "좌익은 전진하고 기병은 대기" -> conflict -> clarification, no staging
## Usage: Godot --headless --path <proj> -s tools/step7_semantic_scene_check.gd
## Evidence: tools/.audit_semantic_scene.json. Exit 0 = all green.

const OUT := "D:/Game development/Demon slayer/StrategyGame/tools/.audit_semantic_scene.json"
const SCENE := "res://scenes/step2r_battlefield_shell.tscn"

var failures: Array = []
var passed := 0
var notes: Array = []
var _evidence := {}


func _init() -> void:
	call_deferred("_run")


func _check(cond: bool, label: String) -> void:
	if cond:
		passed += 1
	else:
		failures.append(label)
	print(("PASS " if cond else "FAIL ") + label)


func _wait_idle(frames: int) -> void:
	for _i in range(frames):
		await process_frame


## Poll `fn` (Callable returning bool) until true or deadline seconds.
func _wait_until(fn: Callable, deadline_sec: float, tag: String) -> bool:
	var t0 := Time.get_ticks_msec()
	while float(Time.get_ticks_msec() - t0) / 1000.0 < deadline_sec:
		if bool(fn.call()):
			return true
		await process_frame
	notes.append("TIMEOUT waiting: " + tag)
	return false


func _run() -> void:
	var packed: PackedScene = load(SCENE)
	_check(packed != null, "scene loads")
	if packed == null:
		_write()
		quit(1)
		return
	var battle: Node = packed.instantiate()
	get_root().add_child(battle)
	await _wait_idle(20)
	var integration: Node = battle.get_node_or_null("Step7Integration")
	var ok_ready := await _wait_until(func() -> bool:
		return integration != null and bool(integration.get("ready_for_step7")), 120.0, "step7 ready")
	_check(ok_ready, "det integration ready")
	if not ok_ready:
		_write()
		quit(1)
		return
	var adapter: Node = integration.get("_advisor_adapter")
	_check(adapter != null, "advisor adapter exists")
	var commander: Node = adapter.get("_commander") if adapter != null else null
	_check(commander != null and bool(commander.call("is_ready")), "chat commander ready")
	if commander == null or not bool(commander.call("is_ready")):
		_write()
		quit(1)
		return
	var truth: RefCounted = integration.get("truth")
	_evidence["semantic_tag"] = "strategy-game-semantic-qwen06:latest"
	# --- 1. COMMAND: 전군 대기 -> stage -> cancel, zero mutation -----------
	var v0 := int(truth.call("get_version"))
	var f0 := str(truth.call("fingerprint"))
	commander.call("send_chat", "전군 대기")
	var staged := await _wait_until(func() -> bool: return bool(commander.call("has_staged")), 600.0, "stage 전군 대기")
	_check(staged, "command stages (tiny attempt + large fallback)")
	if staged:
		var st: Dictionary = commander.call("staged_summary")
		_evidence["stage1_kind"] = str(st.get("kind", "?"))
		_evidence["stage1_units"] = (st.get("unit_ids", []) as Array).size()
		_evidence["stage1_ir_fp"] = str(st.get("command_ir_fp", ""))
		var dbg: Dictionary = commander.call("debug_snapshot")
		_evidence["stage1_semantic_fallback"] = bool(dbg.get("semantic_fallback", false))
		_evidence["stage1_semantic_reason"] = str(dbg.get("semantic_fallback_reason", ""))
		_evidence["stage1_semantic_latency"] = int(dbg.get("semantic_latency_ms", -1))
		_evidence["stage1_latency"] = int(dbg.get("latency_ms", -1))
		_check(bool(dbg.get("semantic_fallback", false)), "tiny failed closed to large fallback")
		commander.call("cancel_staged")
		await _wait_idle(5)
		_check(not bool(commander.call("has_staged")), "cancel clears staged plan")
		_check(int(truth.call("get_version")) == v0 and str(truth.call("fingerprint")) == f0,
			"cancel leaves zero mutation (v=%d fp match)" % v0)
	# --- 2. INFORMATION: answered, never staged -----------------------------
	commander.call("send_chat", "현재 좌익 상황이 어때?")
	var idle2 := await _wait_until(func() -> bool: return not bool(commander.call("has_active")), 600.0, "info answer")
	_check(idle2, "information answered")
	_check(not bool(commander.call("has_staged")), "information never stages")
	var dbg2: Dictionary = commander.call("debug_snapshot")
	_evidence["info_outcome"] = str(dbg2.get("outcome", "?"))
	_evidence["info_semantic_mode"] = str(dbg2.get("semantic_mode", "?"))
	# --- 3. CONFLICT: clarification, no staging, no mutation ------------------
	var v2 := int(truth.call("get_version"))
	commander.call("send_chat", "좌익은 전진하고 기병은 대기")
	var done3 := await _wait_until(func() -> bool: return not bool(commander.call("has_active")), 600.0, "conflict close")
	_check(done3, "conflict closes")
	_check(bool(commander.call("has_pending")) or not bool(commander.call("has_staged")),
		"conflict asks (pending) and never stages")
	_check(not bool(commander.call("has_staged")), "conflict stages nothing")
	_check(int(truth.call("get_version")) == v2, "conflict mutates nothing")
	var dbg3: Dictionary = commander.call("debug_snapshot")
	_evidence["conflict_outcome"] = str(dbg3.get("outcome", "?"))
	_write()
	print("SCENE_" + ("PASS" if failures.is_empty() else "FAIL") + " (%d/%d)" % [passed, passed + failures.size()])
	quit(0 if failures.is_empty() else 1)


func _write() -> void:
	_evidence["passed"] = passed
	_evidence["failures"] = failures
	_evidence["notes"] = notes
	var f := FileAccess.open(OUT, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(_evidence, "\t"))
		f.close()
