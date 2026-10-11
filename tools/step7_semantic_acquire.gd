extends SceneTree

## First-run semantic acquisition driver (REAL download -> verify ->
## register -> warm). Runs the game code path (Step7SemanticModelManager),
## not a shell shortcut.
## Usage: Godot --headless --path <proj> -s tools/step7_semantic_acquire.gd
## Evidence: tools/.audit_semantic_acquire.json (also printed).

const OUT := "D:/Game development/Demon slayer/StrategyGame/tools/.audit_semantic_acquire.json"
const MgrScript = preload("res://scripts/step7/step7_semantic_model_manager.gd")

var _t0 := 0


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_t0 = Time.get_ticks_msec()
	var mgr := MgrScript.new()
	mgr.name = "SemanticAcquire"
	root.add_child(mgr)
	mgr.state_changed.connect(func(sn: String, text: String) -> void:
		print("[acquire] state=%s %s" % [sn, text]))
	mgr.download_progress.connect(func(dl: int, total: int) -> void:
		print("[acquire] progress %d / %d MB (%.1f%%)" % [dl / 1048576, total / 1048576,
			100.0 * float(dl) / float(maxi(total, 1))]))
	mgr.ensure_async({"endpoint": "http://127.0.0.1:11434", "keep_alive": "12h",
		"warmup_timeout_sec": 300.0})
	var res: Array = await mgr.finished
	var ok := bool(res[0]) if res.size() > 0 else false
	var info: Dictionary = (res[1] as Dictionary).duplicate(true) \
		if res.size() > 1 and res[1] is Dictionary else {"ok": ok}
	info["wall_ms"] = Time.get_ticks_msec() - _t0
	print("[acquire] finished ok=%s kind=%s" % [str(bool(info.get("ok", false))), str(info.get("error_kind", ""))])
	print("[acquire] info=" + JSON.stringify(info).left(1500))
	var f := FileAccess.open(OUT, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(info, "\t"))
		f.close()
	mgr.queue_free()
	quit(0 if bool(info.get("ok", false)) else 1)
