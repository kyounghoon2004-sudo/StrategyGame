class_name Step2UnitRenderer
extends Node2D

## Step2UnitRenderer — Renders 24x24 unit counters with always-on overhead badges
## Supports pointer hover detection, independent badge scaling, and tactical info readout.

signal unit_hovered(unit_data: Dictionary)
signal unit_unhovered(unit_data: Dictionary)
signal unit_clicked(unit_data: Dictionary)

var HexUtilsCls: Script = preload("res://scripts/core/hex_utils.gd")
var Step2UnitBadgeCls: Script = preload("res://scripts/core/step2_unit_badge.gd")

var _units: Array[Dictionary] = []
var _unit_nodes: Dictionary = {}        # id -> Node2D container
var _badge_nodes: Dictionary = {}       # id -> Node2D (badge)
var _hovered_unit_id: String = ""

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

func clear_units() -> void:
	for n in _unit_nodes.values():
		if is_instance_valid(n):
			n.queue_free()
	_units.clear()
	_unit_nodes.clear()
	_badge_nodes.clear()
	_hovered_unit_id = ""

func spawn_unit(id: String, unit_class: String, faction: String, q: int, r: int, soldier_count: int, form_factor: String = "form_a") -> Dictionary:
	var norm_class: String = TYPE_MAP.get(unit_class.to_lower(), "infantry")
	var norm_faction: String = "red" if (faction.to_lower() == "red" or faction.to_lower() == "enemy") else "blue"
	
	var data: Dictionary = {
		"id": id,
		"class": norm_class,
		"faction": norm_faction,
		"q": q,
		"r": r,
		"soldier_count": soldier_count,
		"max_count": soldier_count,
		"form_factor": form_factor
	}
	_units.append(data)
	_build_unit_node(data)
	return data

func _build_unit_node(data: Dictionary) -> Node2D:
	var q: int = data["q"]
	var r: int = data["r"]
	var id: String = data["id"]
	var world_pos: Vector2 = HexUtilsCls.hex_to_pixel(q, r)
	
	var container: Node2D = Node2D.new()
	container.name = "Unit_%s" % id
	container.position = world_pos
	container.z_index = 10 + r
	container.set_meta("unit_id", id)
	container.set_meta("q", q)
	container.set_meta("r", r)
	add_child(container)
	
	# 1. 24x24 Character Counter Sprite
	var sprite: Sprite2D = Sprite2D.new()
	sprite.name = "CharacterSprite"
	sprite.centered = true
	sprite.offset = Vector2(0, -2)
	sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	var sprite_path: String = "res://assets/sprites/unit_%s_%s.png" % [data["class"], data["faction"]]
	var sprite_tex: Texture2D = _load_tex(sprite_path)
	if sprite_tex != null:
		sprite.texture = sprite_tex
	else:
		push_warning("[Step2UnitRenderer] Missing unit sprite: %s" % sprite_path)
	container.add_child(sprite)
	
	# 2. Always-On Overhead Identification Badge (Form Factor A)
	var badge: Node2D = Step2UnitBadgeCls.new() as Node2D
	badge.name = "OverheadBadge"
	badge.position = Vector2(0, -14)
	if badge.has_method("setup"):
		badge.call("setup", data["class"], data["faction"], data["form_factor"])
	container.add_child(badge)
	
	# 3. Micro HP bar
	var hp_bar: Sprite2D = Sprite2D.new()
	hp_bar.name = "HPBar"
	hp_bar.centered = true
	hp_bar.position = Vector2(0, 9)
	hp_bar.texture = _generate_hp_texture(1.0, data["faction"] == "blue")
	hp_bar.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	hp_bar.z_index = 15
	container.add_child(hp_bar)
	
	# 4. Soldier count label
	var count_lbl: Label = Label.new()
	count_lbl.name = "CountLabel"
	count_lbl.position = Vector2(-24, 11)
	count_lbl.size = Vector2(48, 14)
	count_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	count_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	count_lbl.text = _format_soldier_count(data["soldier_count"])
	count_lbl.add_theme_font_size_override("font_size", 8)
	count_lbl.add_theme_color_override("font_color", Color(1, 1, 1, 1))
	count_lbl.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	count_lbl.add_theme_constant_override("shadow_offset_x", 1)
	count_lbl.add_theme_constant_override("shadow_offset_y", 1)
	container.add_child(count_lbl)
	
	_unit_nodes[id] = container
	_badge_nodes[id] = badge
	return container

func _format_soldier_count(count: int) -> String:
	if count >= 1000:
		var k: float = float(count) / 1000.0
		return "%.1fk" % k if (count % 1000 >= 100) else "%dk" % int(k)
	return str(count)

func _generate_hp_texture(ratio: float, is_friendly: bool) -> Texture2D:
	var width: int = 20
	var height: int = 3
	var image: Image = Image.create(width, height, false, Image.FORMAT_RGBA8)
	var black: Color = Color(0.05, 0.05, 0.08, 1.0)
	var fill_col: Color = Color(0.18, 0.80, 0.44, 1.0) if is_friendly else Color(0.91, 0.30, 0.24, 1.0)
	
	for y in range(height):
		for x in range(width):
			image.set_pixel(x, y, black)
	
	var inner_w: int = width - 2
	var fill_pixels: int = int(roundi(float(inner_w) * clampf(ratio, 0.0, 1.0)))
	for y in range(1, height - 1):
		for x in range(1, 1 + fill_pixels):
			image.set_pixel(x, y, fill_col)
	
	return ImageTexture.create_from_image(image)

func _load_tex(path: String) -> Texture2D:
	if ResourceLoader.exists(path):
		return load(path) as Texture2D
	elif FileAccess.file_exists(path):
		var img: Image = Image.load_from_file(path)
		if img != null:
			return ImageTexture.create_from_image(img)
	return null

func get_unit_at(q: int, r: int) -> Dictionary:
	for u in _units:
		if int(u["q"]) == q and int(u["r"]) == r:
			return u
	return {}

func get_unit_by_id(id: String) -> Dictionary:
	for u in _units:
		if str(u["id"]) == id:
			return u
	return {}

func get_all_units() -> Array[Dictionary]:
	return _units

func set_hover_at_hex(q: int, r: int) -> void:
	var target_unit: Dictionary = get_unit_at(q, r)
	var new_id: String = str(target_unit.get("id", ""))
	
	if new_id == _hovered_unit_id:
		return
	
	# Unhover previous
	if not _hovered_unit_id.is_empty():
		var old_badge: Node2D = _badge_nodes.get(_hovered_unit_id, null)
		if old_badge and is_instance_valid(old_badge) and old_badge.has_method("set_hovered"):
			old_badge.call("set_hovered", false)
		var old_unit: Dictionary = get_unit_by_id(_hovered_unit_id)
		if not old_unit.is_empty():
			unit_unhovered.emit(old_unit)
		_hovered_unit_id = ""
	
	# Hover new
	if not new_id.is_empty():
		_hovered_unit_id = new_id
		var new_badge: Node2D = _badge_nodes.get(new_id, null)
		if new_badge and is_instance_valid(new_badge) and new_badge.has_method("set_hovered"):
			new_badge.call("set_hovered", true)
		unit_hovered.emit(target_unit)

func clear_hover() -> void:
	if not _hovered_unit_id.is_empty():
		var old_badge: Node2D = _badge_nodes.get(_hovered_unit_id, null)
		if old_badge and is_instance_valid(old_badge) and old_badge.has_method("set_hovered"):
			old_badge.call("set_hovered", false)
		var old_unit: Dictionary = get_unit_by_id(_hovered_unit_id)
		if not old_unit.is_empty():
			unit_unhovered.emit(old_unit)
		_hovered_unit_id = ""

func get_hovered_unit() -> Dictionary:
	if _hovered_unit_id.is_empty():
		return {}
	return get_unit_by_id(_hovered_unit_id)
