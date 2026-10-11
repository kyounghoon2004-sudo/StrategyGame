extends SceneTree

const ModelScript = preload("res://scripts/step7/step7_semantic_model.gd")


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var f := FileAccess.open(ModelScript.modelfile_path_global(), FileAccess.WRITE)
	if f != null:
		f.store_string(ModelScript.modelfile_text())
		f.close()
	print("WROTE_MODelfILE " + ModelScript.modelfile_path_global())
	print(ModelScript.modelfile_text())
	quit(0)
