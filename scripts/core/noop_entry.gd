extends SceneTree
var _frames: int = 0
func _process(_delta: float) -> bool:
	_frames += 1
	if _frames > 3:
		quit(0)
	return false
