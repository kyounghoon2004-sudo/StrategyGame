extends SceneTree

func _initialize() -> void:
	call_deferred("verify")

func verify() -> void:
	var title: Node = load("res://scenes/title_screen.tscn").instantiate()
	root.add_child(title)
	await process_frame
	await process_frame
	var collection: Node = title.find_child("DevMapCollectionPanel",true,false)
	assert(collection!=null,"Missing title map collection")
	var button: Button = collection.find_child("OpenAssetLibraryMap",true,false)
	assert(button!=null and not button.get_signal_connection_list("pressed").is_empty(),"Missing or disconnected asset map button")
	title.call("_on_map_collection_pressed")
	assert(collection.visible,"Map collection did not open")
	var entry = load("res://scripts/ui/dev_asset_library_entry.gd")
	assert(FileAccess.file_exists(entry.MAP_SCRIPT))
	assert(FileAccess.file_exists(entry.DATA_DIR.path_join("optimization-manifest.json")))
	print("[TitleLibraryMenuSmoke] PASS normal title -> map collection -> connected asset-library entry; local map data exists")
	quit()
