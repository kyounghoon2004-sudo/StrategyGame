extends SceneTree

## DEV check: the curriculum match setup ("fixed" rules, STATIC/PASSIVE opponent) installs a valid episode.

const WatchCls = preload("res://scripts/cloud_pipeline/watch_llm_vs_utility.gd")
const RuntimeCls = preload("res://scripts/episodes/episode_runtime.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	for fam in ["fixed", "mild"]:
		WatchCls.start_match(self, fam, 100001, "STATIC", "BULWARK")
		for _i in range(30):
			await process_frame
		var cfg: Dictionary = root.get_meta("watch_llm_vs_utility_cfg", {}) if root.has_meta("watch_llm_vs_utility_cfg") else {}
		var drv := current_scene.get_node_or_null("WatchDriver") if current_scene != null else null
		print("[ladder] fam=%s episode=%s profile=%s variation_mp=%s" % [fam, RuntimeCls.episode_id(),
			drv.call("_profile_id") if drv != null else "?", str(((drv.get("_cfg") as Dictionary).get("overlay", {}) as Dictionary).get("variation", {}).get("base_mp", {})) if drv != null else "?"])
	quit(0)
