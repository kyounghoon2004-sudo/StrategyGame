extends RefCounted
## Plain, versioned, sparse map documents shared by the editor and agents.
const VERSION := 1
const KINDS := ["forest", "tree", "mountain", "water", "road", "castle", "fort", "building", "farm", "unit"]
var directory: String

func _init(path: String) -> void:
	directory = path

func new_document() -> Dictionary:
	var id := "map_%d_%d" % [int(Time.get_unix_time_from_system()), Time.get_ticks_usec()]
	return {"schema_version": VERSION, "id": id, "name": "새 맵", "radius": 20, "hex_radius": 18.0, "objects": []}

func path_for(id: String) -> String:
	return directory.path_join(id + ".json")

func validate(doc: Variant) -> String:
	if not doc is Dictionary: return "맵 문서가 객체가 아닙니다."
	if doc.get("schema_version", 0) != VERSION: return "지원하지 않는 맵 버전입니다."
	var id: Variant = doc.get("id", "")
	if not id is String or not id.begins_with("map_") or id.length() > 80: return "맵 ID가 올바르지 않습니다."
	for ch in id:
		if ch not in "abcdefghijklmnopqrstuvwxyz0123456789_": return "맵 ID에 사용할 수 없는 문자가 있습니다."
	if not doc.get("name") is String or doc.name.strip_edges().is_empty() or doc.name.length() > 100: return "맵 이름을 입력하세요 (최대 100자)."
	if not doc.get("radius") is int and not doc.get("radius") is float: return "맵 크기가 올바르지 않습니다."
	var radius := int(doc.radius)
	if float(doc.radius) != float(radius) or radius < 2 or radius > 40: return "맵 크기는 2–40이어야 합니다."
	if not doc.get("hex_radius") is int and not doc.get("hex_radius") is float: return "헥스 크기가 올바르지 않습니다."
	if float(doc.get("hex_radius", 0)) != 18.0: return "지원하지 않는 헥스 크기입니다."
	if not doc.get("objects") is Array: return "배치 목록이 올바르지 않습니다."
	if doc.has("ground") and not doc.ground is Dictionary: return "바닥 목록이 올바르지 않습니다."
	var occupied := {}
	for item in doc.objects:
		if not item is Dictionary or not item.get("kind") in KINDS: return "알 수 없는 배치 종류입니다."
		if not item.get("variant") is String or item.variant.is_empty() or item.variant.length() > 80: return "배치 종류의 변형이 잘못됐습니다."
		if (not item.get("q") is int and not item.get("q") is float) or (not item.get("r") is int and not item.get("r") is float): return "좌표가 올바르지 않습니다."
		var q := int(item.q); var r := int(item.r)
		if float(q) != float(item.q) or float(r) != float(item.r) or maxi(absi(q), maxi(absi(r), absi(q+r))) > radius: return "헥스 좌표가 맵 밖이거나 정수가 아닙니다."
		var rotation: Variant = item.get("rotation", 0)
		if (not rotation is int and not rotation is float) or int(rotation) != float(rotation) or int(rotation) < 0 or int(rotation) > 5: return "회전은 0–5여야 합니다."
		var cut: Variant = item.get("cut", [])
		if not cut is Array: return "산 조각 삭제 목록이 올바르지 않습니다."
		for m in cut:
			if (not m is int and not m is float) or int(m) < 0: return "산 조각 번호가 올바르지 않습니다."
		if not item.get("cells", []) is Array: return "산이 덮는 헥스 목록이 올바르지 않습니다."
		var cell := "%d,%d" % [q,r]
		if occupied.has(cell): return "같은 헥스에 두 배치가 있습니다: " + cell
		occupied[cell] = true
	return ""

func read(path: String) -> Dictionary:
	if not FileAccess.file_exists(path): return {"error": "파일이 없습니다."}
	var parser := JSON.new()
	if parser.parse(FileAccess.get_file_as_string(path)) != OK: return {"error": "JSON을 읽을 수 없습니다."}
	var problem := validate(parser.data)
	if not problem.is_empty(): return {"error": problem}
	if path.get_file() != str(parser.data.id) + ".json": return {"error": "파일 이름과 맵 ID가 다릅니다."}
	return {"document": parser.data, "hash": FileAccess.get_sha256(path)}

func save(doc: Dictionary, expected_hash: String) -> Dictionary:
	var problem := validate(doc)
	if not problem.is_empty(): return {"error": problem}
	var err := DirAccess.make_dir_recursive_absolute(directory)
	if err != OK: return {"error": "저장 폴더를 만들 수 없습니다: " + error_string(err)}
	var path := path_for(doc.id)
	if FileAccess.file_exists(path):
		if expected_hash.is_empty() or FileAccess.get_sha256(path) != expected_hash: return {"error": "파일이 외부에서 바뀌었습니다. 다시 불러온 뒤 저장하세요."}
	elif not expected_hash.is_empty():
		return {"error": "원래 파일이 없어졌습니다. 다시 불러오세요."}
	var token := str(Time.get_ticks_usec())
	var temporary := path + ".tmp." + token
	var backup := path + ".bak." + token
	var f := FileAccess.open(temporary, FileAccess.WRITE)
	if f == null: return {"error": "임시 저장 파일을 만들 수 없습니다."}
	f.store_string(JSON.stringify(doc, "\t", true) + "\n")
	f.flush()
	var file_error := f.get_error()
	f.close()
	if file_error != OK: return {"error": "맵 쓰기에 실패했습니다: " + error_string(file_error)}
	var had_old := FileAccess.file_exists(path)
	if had_old:
		err = DirAccess.rename_absolute(path, backup)
		if err != OK: return {"error": "기존 맵 백업에 실패했습니다: " + error_string(err)}
	err = DirAccess.rename_absolute(temporary, path)
	if err != OK:
		if had_old: DirAccess.rename_absolute(backup, path)
		return {"error": "맵 교체에 실패했습니다: " + error_string(err)}
	return {"path": path, "hash": FileAccess.get_sha256(path)}
