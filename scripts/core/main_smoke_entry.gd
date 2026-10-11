## main_smoke_entry.gd — main.tscn/F5 boot smoke test
extends SceneTree

var _main: Node
var _frames: int = 0
var _failed: bool = false
var _reported: bool = false
var _cleanup_started: bool = false
var _smoke_slm: Node

func _initialize() -> void:
	var scene: PackedScene = load("res://scenes/main.tscn") as PackedScene
	if scene == null:
		push_error("[MainSmoke] main.tscn 로드 실패")
		_failed = true
		return
	_main = scene.instantiate()
	var director: Node = _main.get_node_or_null("GameDirector")
	if director != null:
		_smoke_slm = Node.new()
		_smoke_slm.name = "SmokeSLM"
		_main.add_child(_smoke_slm)
		director.set("slm_client", _smoke_slm)
		director.set("_auto_simulate", false)
	var audio: Node = root.get_node_or_null("AudioManager")
	if audio != null and audio.has_method("set_muted"):
		audio.call("set_muted", true)
	root.add_child(_main)


func _process(_delta: float) -> bool:
	_frames += 1
	if _cleanup_started:
		if _frames >= 32:
			quit(1 if _failed else 0)
		return false
	if _main == null or not is_instance_valid(_main):
		if _frames > 3:
			push_error("[MainSmoke] Main 인스턴스 생성 실패")
			_failed = true
			quit(1)
		return false
	if not _reported and _frames >= 20:
		_reported = true
		var battle: Node = _main.get_node_or_null("BattleMap")
		var grid: Node = battle.get_node_or_null("HexGrid") if battle != null else null
		var renderer: Node = battle.get_node_or_null("UnitRenderer") if battle != null else null
		var sidebar: Node = _main.get_node_or_null("TacticalSidebar")
		var cells: int = int(grid.get("cell_data").size()) if grid != null else 0
		var units: int = int(renderer.get("unit_map").size()) if renderer != null else 0
		var fog_count: int = int(grid.call("get_fog_count")) if grid != null and grid.has_method("get_fog_count") else 0
		print("[MainSmoke] battle=%s cells=%d units=%d fog=%d sidebar=%s" % [str(battle != null), cells, units, fog_count, str(sidebar != null)])
		if battle == null or cells != 864 or units != 12 or fog_count != 8 or sidebar == null:
			push_error("[MainSmoke] F5 체인 상태 불일치")
			_failed = true
	if _frames >= 30:
		if not _cleanup_started:
			_cleanup_started = true
			if _main != null and is_instance_valid(_main):
				root.remove_child(_main)
				_main.free()
			return false
		quit(1 if _failed else 0)
	return false
