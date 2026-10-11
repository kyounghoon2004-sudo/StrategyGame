extends SceneTree

## Audit probe: dump the EXACT Phase-1 prompt strings + capability snapshot
## so the Python real-model harness uses byte-identical context.
## Writes tools/.audit_phase1_ctx.json

const OUT := "D:/Game development/Demon slayer/StrategyGame/tools/.audit_phase1_ctx.json"

func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var IntentScript = load("res://scripts/step7/step7_chat_intent.gd")
	var CmdrScript = load("res://scripts/step7/step7_chat_commander.gd")
	var out := {
		"action_vocab": IntentScript.ACTION_VOCAB,
		"scope_vocab": IntentScript.SCOPE_VOCAB,
		"intent_system": IntentScript.INTENT_SYSTEM_PROMPT,
		"select_system": IntentScript.SELECT_SYSTEM_PROMPT,
		"capabilities": CmdrScript.capability_snapshot(),
	}
	var f := FileAccess.open(OUT, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(out))
		f.close()
		print("AUDIT_CTX_WRITTEN")
	else:
		print("AUDIT_CTX_WRITE_FAILED")
	quit(0)
