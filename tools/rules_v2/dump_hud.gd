extends SceneTree
## Prints the shell's HUD node tree (names, types, visibility, rect) for EDITOR_M1.

func _init() -> void:
	var shell: Node = (load("res://scenes/step2r_battlefield_shell.tscn") as PackedScene).instantiate()
	shell.set("battlefield_id", "EDITOR_M1")
	root.add_child(shell)
	for i in 60:
		await process_frame
	_dump(shell, 0)
	quit(0)

func _dump(n: Node, depth: int) -> void:
	if depth > 3:
		return
	for c in n.get_children():
		if c is Control or c is CanvasLayer:
			var info := ""
			if c is Control:
				var ctrl := c as Control
				info = " vis=%s rect=%s" % [str(ctrl.visible), str(ctrl.get_global_rect())]
				if c is Label:
					info += " text='%s'" % str((c as Label).text).substr(0, 30)
				if c is Button:
					info += " btn='%s'" % str((c as Button).text).substr(0, 20)
			print("[HUD] ".rpad(6) + "  ".repeat(depth) + str(c.name) + " <" + c.get_class() + ">" + info)
			_dump(c, depth + 1)
