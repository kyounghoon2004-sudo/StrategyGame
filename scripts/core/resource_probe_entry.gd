extends SceneTree
var _step: int = 0
var _items: Array[String] = [
	"res://scripts/core/update_hp_bar.gd",
	"res://scripts/ui/tactical_sidebar.gd",
	"res://scripts/core/unit_renderer.gd",
	"res://assets/sprites/unit_infantry_blue.png",
	"res://assets/ui/ui_target_beacon.png",
	"res://assets/ui/ui_move_green.png",
	"res://assets/ui/ui_move_orange.png",
	"res://assets/ui/ui_move_red.png",
	"res://assets/ui/ui_move_black.png",
	"res://assets/ui/portrait_advisor.png"
]
func _process(_delta: float) -> bool:
	if _step < _items.size():
		var path: String = _items[_step]
		print("[Probe] before ", _step, " ", path)
		var resource: Resource = load(path)
		print("[Probe] after ", _step, " valid=", resource != null)
		_step += 1
		return false
	quit(0)
	return false
