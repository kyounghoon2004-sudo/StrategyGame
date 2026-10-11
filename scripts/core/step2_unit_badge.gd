class_name Step2UnitBadge
extends Node2D

## Step2UnitBadge — Always-on overhead unit identification badge
## Renders 16x16 Form Factor A Shield Crest (or Form B/C) with independent pointer hover scaling.

signal badge_hover_changed(is_hovered: bool)

@export var unit_class: String = "infantry"
@export var faction: String = "blue"
@export var form_factor: String = "form_a"

var _sprite: Sprite2D
var _hover_tween: Tween
var _is_hovered: bool = false
var _base_scale: Vector2 = Vector2(1.0, 1.0)
var _hover_scale: Vector2 = Vector2(1.35, 1.35)
var _tween_duration: float = 0.14

const BADGE_MAP := {
	"infantry": "infantry",
	"spearman": "spearman",
	"spearmen": "spearman",
	"archer": "archer",
	"archers": "archer",
	"cavalry": "cavalry",
	"scout": "scout",
	"scouts": "scout",
	"conscript": "conscript",
	"conscripts": "conscript",
	"siege": "siege",
}

func _ready() -> void:
	z_index = 25
	_ensure_sprite()
	update_badge()

func setup(p_class: String, p_faction: String, p_form: String = "form_a") -> void:
	unit_class = p_class.to_lower()
	faction = "red" if (p_faction.to_lower() == "red" or p_faction.to_lower() == "enemy") else "blue"
	form_factor = p_form.to_lower()
	_ensure_sprite()
	update_badge()

func _ensure_sprite() -> void:
	if _sprite == null or not is_instance_valid(_sprite):
		_sprite = Sprite2D.new()
		_sprite.name = "BadgeSprite"
		_sprite.centered = true
		_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		add_child(_sprite)

func update_badge() -> void:
	_ensure_sprite()
	var norm_class: String = BADGE_MAP.get(unit_class, "infantry")
	var path: String = "res://assets/badges/%s/badge_%s_%s_%s.png" % [faction, norm_class, faction, form_factor]
	var fallback_path: String = "res://assets/badges/%s/badge_%s_%s.png" % [faction, norm_class, faction]
	
	var tex: Texture2D = _load_tex(path)
	if tex == null:
		tex = _load_tex(fallback_path)
	
	if tex != null:
		_sprite.texture = tex
	else:
		push_warning("[Step2UnitBadge] Badge texture missing: %s" % path)

func _load_tex(path: String) -> Texture2D:
	if ResourceLoader.exists(path):
		return load(path) as Texture2D
	elif FileAccess.file_exists(path):
		var img: Image = Image.load_from_file(path)
		if img != null:
			return ImageTexture.create_from_image(img)
	return null

func set_hovered(hovered: bool) -> void:
	if _is_hovered == hovered:
		return
	_is_hovered = hovered
	
	if _hover_tween and _hover_tween.is_valid():
		_hover_tween.kill()
	
	_hover_tween = create_tween().set_parallel(true)
	if _is_hovered:
		z_index = 60
		_hover_tween.tween_property(_sprite, "scale", _hover_scale, _tween_duration).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		_hover_tween.tween_property(_sprite, "modulate", Color(1.15, 1.15, 1.15, 1.0), _tween_duration)
	else:
		z_index = 25
		_hover_tween.tween_property(_sprite, "scale", _base_scale, _tween_duration * 0.9).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		_hover_tween.tween_property(_sprite, "modulate", Color(1.0, 1.0, 1.0, 1.0), _tween_duration * 0.9)
	
	badge_hover_changed.emit(_is_hovered)

func is_hovered() -> bool:
	return _is_hovered

func get_badge_info() -> Dictionary:
	return {
		"class": BADGE_MAP.get(unit_class, "infantry"),
		"faction": faction,
		"form_factor": form_factor,
		"is_hovered": _is_hovered
	}
