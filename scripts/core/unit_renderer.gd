class_name UnitRenderer
extends Node2D

## 유닛 스프라이트 + 실시간 픽셀 HP 바 + 병력 수치 렌더러.
## HP 바는 24x4, 검정 1px 외곽선, 아군 #2ECC71 / 적군 #E74C3C.

var HexUtilsCls: Script = load("res://scripts/core/hex_utils.gd") as Script

var unit_map: Dictionary = {}
var hp_bar_map: Dictionary = {}
var count_label_map: Dictionary = {}
var hp_text_map: Dictionary = {}
var max_hp_map: Dictionary = {}
var _tweens: Dictionary = {}

const TYPE_MAP := {
	"infantry": "infantry",
	"archers": "archer",
	"archer": "archer",
	"cavalry": "cavalry",
	"spearmen": "spearman",
	"spearman": "spearman",
	"siege": "siege",
	"conscripts": "conscript",
	"conscript": "conscript",
	"scouts": "scout",
	"scout": "scout",
}


func _ready() -> void:
	z_index = 10


func _sprite_key(unit: Variant) -> String:
	var unit_type: Variant = unit.get("unit_type")
	if unit_type == null:
		return "infantry"
	return str(TYPE_MAP.get(str(unit_type.get("id")), "infantry"))


func _faction_key(unit: Variant) -> String:
	var faction: String = str(unit.get("faction"))
	if faction == "enemy" or faction == "red":
		return "red"
	return "blue"


func _sprite_path(unit: Variant) -> String:
	return "res://assets/sprites/unit_%s_%s.png" % [_sprite_key(unit), _faction_key(unit)]


func _format_number(number: int) -> String:
	if number >= 10000:
		return "%d천" % int(number / 1000)
	if number >= 1000:
		var thousands: int = int(number / 1000)
		var remainder: int = number % 1000
		if remainder >= 100:
			return "%d.%d천" % [thousands, int(float(remainder) / 100.0)]
		return "%d천" % thousands
	return str(number)


func _make_hp_texture(ratio: float, is_player: bool) -> Texture2D:
	var width: int = 24
	var height: int = 4
	var image: Image = Image.create(width, height, false, Image.FORMAT_RGBA8)
	var black: Color = Color(0, 0, 0, 1)
	var green: Color = Color(46.0 / 255.0, 204.0 / 255.0, 113.0 / 255.0, 1)
	var red: Color = Color(231.0 / 255.0, 76.0 / 255.0, 60.0 / 255.0, 1)
	var fill_color: Color = green if is_player else red

	for y in range(height):
		for x in range(width):
			image.set_pixel(x, y, black)

	var inner_width: int = width - 2
	var filled: int = int(roundi(float(inner_width) * clampf(ratio, 0.0, 1.0)))
	for y in range(1, height - 1):
		for x in range(1, 1 + filled):
			image.set_pixel(x, y, fill_color)
	return ImageTexture.create_from_image(image)


func _unit_key(unit: Variant) -> int:
	return int(unit.get_instance_id())


func spawn_unit(unit: Variant, q: int, r: int) -> Node2D:
	var key: int = _unit_key(unit)
	if unit_map.has(key):
		var existing: Node2D = unit_map[key] as Node2D
		if existing and is_instance_valid(existing):
			existing.position = HexUtilsCls.hex_to_pixel(q, r)
			existing.set_meta("q", q)
			existing.set_meta("r", r)
			_update_count(unit)
			_update_hp(unit)
			return existing

	var container: Node2D = Node2D.new()
	container.name = "Unit_%d_%d" % [q, r]
	container.position = HexUtilsCls.hex_to_pixel(q, r)
	container.z_index = 10 + r
	container.set_meta("q", q)
	container.set_meta("r", r)
	add_child(container)

	var sprite: Sprite2D = Sprite2D.new()
	sprite.name = "Sprite"
	sprite.centered = true
	sprite.offset = Vector2(0, -3)
	sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	var texture: Texture2D = load(_sprite_path(unit)) as Texture2D
	if texture:
		sprite.texture = texture
	else:
		push_warning("[UnitRenderer] sprite missing: %s" % _sprite_path(unit))
	container.add_child(sprite)

	var hp_bar: Sprite2D = Sprite2D.new()
	hp_bar.name = "HpBar"
	hp_bar.centered = true
	hp_bar.position = Vector2(0, 8)
	hp_bar.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	hp_bar.z_index = 20
	container.add_child(hp_bar)

	var hp_text: Label = Label.new()
	hp_text.name = "HPText"
	hp_text.position = Vector2(-32, 10)
	hp_text.size = Vector2(64, 16)
	hp_text.horizontal_alignment = 1
	hp_text.add_theme_font_size_override("font_size", 8)
	hp_text.add_theme_color_override("font_color", Color(1, 1, 1, 1))
	hp_text.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	hp_text.add_theme_constant_override("shadow_offset_x", 1)
	hp_text.add_theme_constant_override("shadow_offset_y", 1)
	container.add_child(hp_text)

	var count_label: Label = Label.new()
	count_label.name = "CountLabel"
	count_label.position = Vector2(-32, 24)
	count_label.size = Vector2(64, 16)
	count_label.horizontal_alignment = 1
	count_label.add_theme_font_size_override("font_size", 9)
	count_label.add_theme_color_override("font_color", Color(1, 1, 1, 1))
	count_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	count_label.add_theme_constant_override("shadow_offset_x", 1)
	count_label.add_theme_constant_override("shadow_offset_y", 1)
	container.add_child(count_label)

	container.set_meta("unit_ref", unit)
	unit_map[key] = container
	hp_bar_map[key] = hp_bar
	hp_text_map[key] = hp_text
	count_label_map[key] = count_label
	max_hp_map[key] = maxi(1, int(unit.get("soldier_count")))
	_update_count(unit)
	_update_hp(unit)
	return container


func _update_count(unit: Variant) -> void:
	var key: int = _unit_key(unit)
	var label: Label = count_label_map.get(key) as Label
	if label and is_instance_valid(label):
		label.text = _format_number(maxi(0, int(unit.get("soldier_count"))))


func _update_hp(unit: Variant) -> void:
	var key: int = _unit_key(unit)
	var hp_bar: Sprite2D = hp_bar_map.get(key) as Sprite2D
	if hp_bar == null or not is_instance_valid(hp_bar):
		return
	var current_hp: int = maxi(0, int(unit.get("soldier_count")))
	var maximum_hp: int = int(max_hp_map.get(key, 0))
	if maximum_hp <= 0:
		maximum_hp = maxi(1, current_hp)
		max_hp_map[key] = maximum_hp
	var ratio: float = clampf(float(current_hp) / float(maximum_hp), 0.0, 1.0)
	var faction: String = str(unit.get("faction"))
	hp_bar.texture = _make_hp_texture(ratio, faction == "player" or faction == "blue")
	var hp_label: Label = hp_text_map.get(key) as Label
	if hp_label and is_instance_valid(hp_label):
		hp_label.text = "%d/%d" % [current_hp, maximum_hp]


func update_unit_visual(unit: Variant) -> void:
	var key: int = _unit_key(unit)
	if not unit_map.has(key):
		spawn_unit(unit, int(unit.get("hex_q")), int(unit.get("hex_r")))
	_update_count(unit)
	_update_hp(unit)


func update_unit_position(unit: Variant, q: int, r: int, instant: bool = false) -> void:
	var key: int = _unit_key(unit)
	var node: Node2D = unit_map.get(key) as Node2D
	if node == null or not is_instance_valid(node):
		spawn_unit(unit, q, r)
		return
	var target: Vector2 = HexUtilsCls.hex_to_pixel(q, r)
	if instant:
		node.position = target
	else:
		if _tweens.has(key) and is_instance_valid(_tweens[key]) and _tweens[key].is_valid():
			_tweens[key].kill()
		var tween: Tween = create_tween()
		_tweens[key] = tween
		tween.tween_property(node, "position", target, 0.22).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	node.z_index = 10 + r
	node.set_meta("q", q)
	node.set_meta("r", r)
	_update_hp(unit)


func move_unit_along_path(unit: Variant, path: Array[Vector2i]) -> void:
	if path.size() <= 1:
		return
	var key: int = _unit_key(unit)
	var node: Node2D = unit_map.get(key) as Node2D
	if node == null or not is_instance_valid(node):
		spawn_unit(unit, path[0].x, path[0].y)
		node = unit_map.get(key) as Node2D
	if node == null:
		return
	if _tweens.has(key) and is_instance_valid(_tweens[key]) and _tweens[key].is_valid():
		_tweens[key].kill()
	var tween: Tween = create_tween()
	_tweens[key] = tween
	for index in range(1, path.size()):
		var hex: Vector2i = path[index]
		tween.tween_property(node, "position", HexUtilsCls.hex_to_pixel(hex.x, hex.y), 0.18).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	var final_hex: Vector2i = path[path.size() - 1]
	tween.tween_callback(func():
		if is_instance_valid(node):
			node.set_meta("q", final_hex.x)
			node.set_meta("r", final_hex.y)
			node.z_index = 10 + final_hex.y
	)


func is_moving(unit: Variant) -> bool:
	var key: int = _unit_key(unit)
	return _tweens.has(key) and is_instance_valid(_tweens[key]) and _tweens[key].is_valid() and _tweens[key].is_running()


func get_unit_hex(unit: Variant) -> Vector2i:
	var key: int = _unit_key(unit)
	var node: Node2D = unit_map.get(key) as Node2D
	if node and is_instance_valid(node):
		return Vector2i(int(node.get_meta("q", unit.get("hex_q"))), int(node.get_meta("r", unit.get("hex_r"))))
	return Vector2i(int(unit.get("hex_q")), int(unit.get("hex_r")))


func remove_unit(unit: Variant) -> void:
	var key: int = _unit_key(unit)
	var node: Node2D = unit_map.get(key) as Node2D
	if node and is_instance_valid(node):
		var tween: Tween = create_tween()
		tween.tween_property(node, "modulate:a", 0.0, 0.28)
		tween.tween_callback(func():
			if is_instance_valid(node):
				node.queue_free()
	)
	unit_map.erase(key)
	hp_bar_map.erase(key)
	hp_text_map.erase(key)
	count_label_map.erase(key)
	max_hp_map.erase(key)
	_tweens.erase(key)


func refresh_all(units: Array) -> void:
	for unit in units:
		update_unit_visual(unit)
