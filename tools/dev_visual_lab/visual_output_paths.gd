extends RefCounted
## Producer outputs may be relocated without modifying the original assets.
const LEGACY_ROOT := "C:/Users/User/Documents/Codex/2026-10-18/strategygame-godot-4-2-2-repo/outputs"

static func output(relative: String) -> String:
	var root := OS.get_environment("SG_VISUAL_OUTPUT_ROOT")
	if root.is_empty():
		root = LEGACY_ROOT
	return root.path_join(relative)
