## local_test_entry.gd — Godot 4.2.2 headless entry point
## Adds the Node test after SceneTree initialization, then exits on a later frame.
extends SceneTree

var _test_node: Node
var _phase: int = 0

func _initialize() -> void:
	var test_script: Script = load("res://scripts/core/local_test.gd") as Script
	if test_script == null:
		push_error("[LocalTestEntry] 테스트 스크립트 로드 실패")
		_phase = 99
		return
	_test_node = Node.new()
	_test_node.name = "LocalTest"
	_test_node.set_script(test_script)
	root.add_child(_test_node)
	_phase = 1

func _process(_delta: float) -> bool:
	if _phase == 1:
		_phase = 2
		return false
	if _phase == 2:
		_phase = 3
		return false
	if _phase == 3:
		quit(0)
		_phase = 4
	return false
