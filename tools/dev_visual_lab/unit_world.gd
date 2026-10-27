extends "res://tools/dev_visual_lab/roads_world.gd"
## Additive unit presentation on the complete DEV asset world; no battle shell.
const Manager = preload("res://tools/dev_visual_lab/unit_lod_manager.gd")
const UNIT_OUT := "C:/Users/User/Documents/Codex/2026-10-18/strategygame-godot-4-2-2-repo/outputs/unit-import-optimization"
const UNIT_KINDS := ["infantry","spearman","archer","conscript","scout","cavalry","hq"]
const STRATEGIC_FIGURE_HEIGHT := 9.6
const HQ_FIGURE_HEIGHT := 12.0
var unit_manager: Node3D
var unit_status: Label
var units_ready := false

func boot() -> void:
	await super.boot()
	if not units_ready: await setup_units()
	root.title = "StrategyGame | Asset Library - 3D Units + LOD"
	focus_unit(0)

func make_actors() -> void:
	pass

func make_ui() -> void:
	super.make_ui()
	var column: VBoxContainer = info.get_parent()
	var focus := Button.new(); focus.text = "3D 유닛 구역 보기"; column.add_child(focus)
	focus.pressed.connect(func(): focus_unit(0))
	var picker := OptionButton.new()
	for name in ["보병","창병","궁병","민병","정찰병·군견","기병","기마 지휘관"]: picker.add_item(name)
	picker.item_selected.connect(focus_unit); column.add_child(picker)
	var lod := OptionButton.new()
	for name in ["유닛 LOD: 자동","근경: 원본 형상·애니메이션","중경: 경량 메시·15 Hz","원경: 정적 부대 메시"]: lod.add_item(name)
	lod.item_selected.connect(func(index):
		if unit_manager!=null: unit_manager.forced_detail = index-1; unit_manager.update_visibility())
	column.add_child(lod)
	var attack := Button.new(); attack.text = "유닛 공격 모션 미리보기"; column.add_child(attack)
	attack.pressed.connect(func():
		if unit_manager!=null:
			for entry in unit_manager.entries:
				if entry["node"].visible: entry["node"].play_attack())
	unit_status = Label.new(); unit_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(unit_status)
	# Keep the new controls above the long mountain/settlement bookmark list.
	for control in [focus,picker,lod,attack,unit_status]: column.move_child(control,column.get_children().find(bookmarks))

func setup_units() -> void:
	if units_ready: return
	units_ready = true
	unit_manager = Manager.new(); unit_manager.name = "DevUnitLODManager"; stage.add_child(unit_manager)
	unit_manager.camera = camera
	var available: Array = []
	var trees := plain_tree_heatmap()
	for cell in cells:
		var coord := Vector2i(cell["q"],cell["r"])
		if cell["kind"]=="plain" and int(trees.get(coord,0))==0 and absi(coord.x)<=11 and absi(coord.y)<=12:
			available.append(coord)
	# First seven types sit close to the main district; the rest give map-scale load.
	available.sort_custom(func(a: Vector2i,b: Vector2i) -> bool: return center(a.x,a.y).distance_squared_to(center(2,3))<center(b.x,b.y).distance_squared_to(center(2,3)))
	var placed := 0
	for coord in available:
		if placed>=56: break
		var kind: String = UNIT_KINDS[placed%7]
		var count := 1 if kind=="hq" else (3 if kind=="cavalry" else 9)
		var faction := "blue" if int(placed/7)%2==0 else "red"
		var height := HQ_FIGURE_HEIGHT if kind=="hq" else STRATEGIC_FIGURE_HEIGHT
		unit_manager.add_formation(kind,faction,count,height,center(coord.x,coord.y)+Vector3.UP*0.16,20261019+placed,coord)
		placed += 1
	await wait_frames(10)
	unit_manager.prewarm()
	var record: Array = []
	for entry in unit_manager.entries:
		record.append({"kind":entry["kind"],"faction":entry["faction"],"figures":entry["count"],"height":entry["height"],"q":entry["coord"].x,"r":entry["coord"].y})
	var file := FileAccess.open(UNIT_OUT.path_join("world-unit-placements.json"),FileAccess.WRITE)
	file.store_string(JSON.stringify({"formations":record,"terrain_unchanged":cells==world_data["cells"],"haruki":false,"scope":"DEV presentation; no movement, combat or mission data modified"},"\t")); file.close()
	print("[UnitWorld] Ready: ",placed," formations, 7 unit classes; near/mid/far + offscreen scheduling")

func focus_unit(index: int) -> void:
	if unit_manager==null or unit_manager.entries.is_empty(): return
	var entry: Dictionary = unit_manager.entries[clampi(index,0,6)]
	target = entry["node"].position
	camera.size = 72.0; yaw = 0.12; orbit = 0.72; update_camera()

func update_lod() -> void:
	super.update_lod()
	if unit_manager!=null: unit_manager.update_visibility()

func _process(delta: float) -> bool:
	var result := super._process(delta)
	if unit_manager!=null and unit_status!=null:
		info.text = info.text.replace("유닛 없음","유닛 56부대")
		var counts: Array = unit_manager.counts
		unit_status.text = "3D 유닛: 56개 부대 · 7병종\n근경 %d / 중경 %d / 원경 %d / 화면 밖 %d\nDEV 시각 표시 · 전투·밸런스 변경 없음" % counts
	return result

func capture_suite() -> void:
	ensure_roads()
	await setup_units()
	ui.visible = false
	for index in [0,4,5,6]:
		focus_unit(index)
		await wait_frames(15)
		await unit_picture("world-"+UNIT_KINDS[index])
	unit_manager.forced_detail = 2; focus_unit(0); unit_manager.update_visibility()
	await wait_frames(5); await unit_picture("world-frozen-close")
	unit_manager.forced_detail = -1
	target = center(2,3); camera.size = 280; update_camera()
	await wait_frames(10); await unit_picture("world-unit-district")
	if "--keep-open" in OS.get_cmdline_user_args():
		capture_mode = false; ui.visible = true; focus_unit(0)
	else: quit()

func unit_picture(name: String) -> void:
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(UNIT_OUT.path_join(name+".png"))
