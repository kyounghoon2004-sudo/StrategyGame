extends SceneTree
## Regression: visible portions of a formation outlive its offscreen anchor.
const Manager = preload("res://tools/dev_visual_lab/unit_lod_manager.gd")
const Unit = preload("res://tools/dev_visual_lab/unit_lod_formation.gd")
const OUT := "C:/Users/User/Documents/Codex/2026-10-18/strategygame-godot-4-2-2-repo/outputs/unit-import-optimization/visibility-edge-check.json"

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	root.size = Vector2i(1600,900)
	var camera := Camera3D.new(); root.add_child(camera)
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL; camera.size = 72.0
	camera.position = Vector3(0,0,100); camera.look_at(Vector3.ZERO); camera.make_current()
	var manager := Manager.new(); root.add_child(manager); manager.camera = camera
	var unit := Unit.new(); root.add_child(unit)
	unit.points = manager.scatter_points(9,"infantry",20261019)
	var entry := {"node":unit,"height":9.6,"kind":"infantry"}
	await process_frame
	var screen := root.get_visible_rect()
	var rows: Array = []
	var w := screen.size.x; var h := screen.size.y
	for item in [["left-partial",Vector2(-200,h*0.5),true],["right-partial",Vector2(w+200,h*0.5),true],["top-partial",Vector2(w*0.5,20),true],["bottom-partial",Vector2(w*0.5,h+200),true],["fully-left",Vector2(-1200,h*0.5),false],["fully-right",Vector2(w+1200,h*0.5),false]]:
		unit.position = camera.project_position(item[1],100.0)
		var bounds: Rect2 = manager.formation_screen_bounds(entry)
		var intersects: bool = screen.intersects(bounds,true)
		if intersects!=item[2]: push_error("Formation edge regression: "+item[0]); quit(1); return
		var old_anchor := camera.unproject_position(unit.position+Vector3.UP*9.6)
		var old_visible := screen.grow(90).has_point(old_anchor)
		if item[0] in ["left-partial","right-partial"] and old_visible: push_error("Old anchor should be outside: "+item[0]); quit(1); return
		rows.append({"case":item[0],"formation_intersects_view":intersects,"old_anchor_visible":old_visible,"passed":true})
	var file := FileAccess.open(OUT,FileAccess.WRITE)
	file.store_string(JSON.stringify({"checks":rows,"policy":"Projected whole-formation bounds, 100px enter/180px exit margin, 350ms exit grace","passed":true},"\t")); file.close()
	print("[UnitVisibility] 6 edge cases passed")
	manager.free(); unit.free(); camera.free()
	quit()
