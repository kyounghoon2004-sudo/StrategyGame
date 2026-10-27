extends "res://tools/dev_visual_lab/all_ranges_world.gd"
## Read-only captures of existing compositions. No production asset changes.
const AUDIT_OUT := "C:/Users/User/Documents/Codex/2026-10-18/strategygame-godot-4-2-2-repo/outputs/settlement-farm-diagnosis"

func save_picture(name: String) -> void:
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(AUDIT_OUT.path_join(name+".png"))

func capture_suite() -> void:
	DirAccess.make_dir_recursive_absolute(AUDIT_OUT)
	ui.visible = false
	var shots := []
	for shot in [["village-near",Vector2i(-3,1),40.0],["village-context",Vector2i(-3,1),110.0],["farms-near",Vector2i(-3,3),58.0],["farms-context",Vector2i(-3,3),150.0]]:
		target = center(shot[1].x,shot[1].y)
		camera.size = shot[2]; yaw = 0.12; orbit = 0.78; update_camera()
		await wait_frames(5)
		await save_picture(shot[0])
		shots.append({"name":shot[0],"q":shot[1].x,"r":shot[1].y,"camera_size":shot[2],"lod":active_lod})
	var f := FileAccess.open(AUDIT_OUT.path_join("capture-receipt.json"),FileAccess.WRITE)
	f.store_string(JSON.stringify({"shots":shots,"layout_sha256":FileAccess.get_sha256(WORLD_OUT.path_join("world-map.json")),"layout_unchanged":cells==world_data["cells"],"placements":document.filter(func(p): return p["role"] in ["farm","village"])},"\t"))
	f.close()
	quit()
