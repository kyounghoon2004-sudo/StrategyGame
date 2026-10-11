extends SceneTree
## DEV map collection probe (windowed UI check):
##  1. title screen: the existing entries are present, no map selector sits
##     under the production battle button, the DEV map button exists;
##  2. the window lists the 10 RL battlefields;
##  3. "전장 열기" on BF08 changes scene to the battle shell on BF08;
##  4. back on the title screen the selection is cleared, so a shell built
##     afterwards (production flow) loads the default map.
## Usage: godot --path <p> --script res://tools/battlefields/dev_map_collection_probe.gd

const Catalog = preload("res://scripts/battlefields/battlefield_catalog.gd")
const TITLE := "res://scenes/title_screen.tscn"
var _frame: int = 0
var _fails: Array = []

func _ok(cond: bool, what: String) -> void:
	print("[MAPCOL-PROBE] %s %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)

func _initialize() -> void:
	change_scene_to_file(TITLE)

func _process(_d: float) -> bool:
	_frame += 1
	if _frame == 15:
		var t: Node = current_scene
		var box: Node = t.get_node("VBox/Buttons")
		var names: Array = []
		for c in box.get_children():
			names.append(str(c.name))
		for keep in ["BtnCampaign", "BtnBattle", "BtnSLM", "BtnQuit"]:
			_ok(names.has(keep), "existing entry %s present" % keep)
		_ok(box.get_node_or_null("BattlefieldSelect") == null, "no map selector in the production menu")
		_ok(names.has("BtnDevMapCollection"), "DEV map collection button present (%s)" % ", ".join(names))
		var panel: Node = t.get("_map_collection")
		panel.call("open")
		var rows: int = 0
		for c in panel.find_child("MapList", true, false).get_children():
			if str(c.name).begins_with("Row_"):
				rows += 1
		_ok(rows == 10, "window lists %d RL maps" % rows)
		(panel.find_child("Open_BF08", true, false) as Button).emit_signal("pressed")
	elif _frame == 60:
		var sh: Node = current_scene
		_ok(sh != null and str(sh.get("battlefield_id")) == "BF08", "opened shell is BF08 (%s)" % (str(sh.get("battlefield_id")) if sh else "null"))
		change_scene_to_file(TITLE)
	elif _frame == 80:
		_ok(Catalog.pending_id == "", "title screen cleared the map selection")
		var shell: Node = (load("res://scenes/step2r_battlefield_shell.tscn") as PackedScene).instantiate()
		root.add_child(shell)
		_ok(str(shell.get("battlefield_id")) == "", "production flow shell loads the default map")
		print("[MAPCOL-PROBE] %s" % ("ALL PASS" if _fails.is_empty() else "FAILED: " + str(_fails)))
		return true
	return false
