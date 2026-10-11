extends SceneTree

const OverlayScript = preload("res://scripts/step7/step7_sector_overlay.gd")
const FrameScript = preload("res://scripts/step7/step7_tactical_frame.gd")

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var ov: Node2D = OverlayScript.new()
	get_root().add_child(ov)
	ov.call("set_show", true)
	var cache: Dictionary = ov.get("_cache")
	var total := 0
	for s in ["LEFT_WING", "CENTER", "RIGHT_WING"]:
		total += (cache.get(s, []) as Array).size()
	print("OVERLAY_CHECK showing=", ov.call("is_showing"),
		" cached=", total,
		" frame_total=", FrameScript.frame_info().get("total", -1),
		" labels=", (ov.get("_labels") as Array).size(),
		" z=", (ov as Node2D).z_index)
	ov.call("set_highlight", "LEFT_WING", [Vector2i(-16, -18)])
	print("OVERLAY_CHECK highlight_ok=", ov.get("_highlight_sector") == "LEFT_WING")
	quit(0 if total == 4921 else 2)
