extends ResourceFormatLoader
## Redirect only the producer's serialized unit texture dependencies.
const OLD_PREFIX := "C:/Users/User/Documents/Codex/2026-10-18/strategygame-godot-4-2-2-repo/outputs/unit-import-optimization/textures/"
const Paths = preload("res://tools/dev_visual_lab/visual_output_paths.gd")

func _get_recognized_extensions() -> PackedStringArray:
	return PackedStringArray(["res"])

func _handles_type(_type: StringName) -> bool:
	return true

func _recognize_path(path: String, _type: StringName) -> bool:
	return path.begins_with(OLD_PREFIX)

func _exists(path: String) -> bool:
	return path.begins_with(OLD_PREFIX) and FileAccess.file_exists(_mapped(path))

func _load(path: String, _original_path: String, _use_sub_threads: bool, cache_mode: int) -> Variant:
	if not path.begins_with(OLD_PREFIX):
		return ERR_FILE_UNRECOGNIZED
	return ResourceLoader.load(_mapped(path), "", cache_mode)

func _mapped(path: String) -> String:
	return Paths.output("unit-import-optimization/textures").path_join(path.trim_prefix(OLD_PREFIX))
