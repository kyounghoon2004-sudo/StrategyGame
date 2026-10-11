extends SceneTree

## Compile probe: load the full semantic/command chain scripts.
## Usage: Godot --headless --path <proj> -s tools/step7_semantic_compile_probe.gd

const CHAIN := [
	"res://scripts/step7/step7_semantic_model.gd",
	"res://scripts/step7/step7_semantic_model_manager.gd",
	"res://scripts/step7/step7_semantic_envelope.gd",
	"res://scripts/step7/step7_semantic_gate.gd",
	"res://scripts/step7/step7_semantic_frontend.gd",
	"res://scripts/step7/step7_chat_commander.gd",
	"res://scripts/step7/step7_advisor_adapter.gd",
	"res://scripts/ai/ai_backend_config.gd",
	"res://scripts/ai/ai_backend_bootstrap.gd",
	"res://scripts/ai/ai_setup_panel.gd",
]


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var bad := 0
	for p in CHAIN:
		var s: Script = load(p)
		if s == null or not s.can_instantiate() and not (s as Script).has_source_code():
			print("FAIL load " + p)
			bad += 1
		else:
			print("PASS load " + p)
	print("COMPILE_" + ("PASS" if bad == 0 else "FAIL"))
	quit(1 if bad > 0 else 0)
