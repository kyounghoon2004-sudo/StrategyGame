class_name UpdateHpBar
extends RefCounted

## HP-bar helper — 유닛의 현재 병력 / 최대 병력을 24x4 픽셀 바로 렌더링
## 아군 #2ECC71, 적군 #E74C3C, 검정 1px 외곽선.

func update_hp_bar_from_unit(unit: Variant, hp_bar: Sprite2D) -> void:
	if hp_bar == null:
		return
	if unit == null:
		hp_bar.texture = _make_bar_texture(0.0, false)
		return

	var current_hp: int = int(unit.get("soldier_count"))
	var maximum_hp: int = int(unit.get("max_soldier_count"))
	if maximum_hp <= 0:
		maximum_hp = maxi(1, current_hp)
	var ratio: float = clampf(float(current_hp) / float(maximum_hp), 0.0, 1.0)
	var faction: String = str(unit.get("faction"))
	hp_bar.texture = _make_bar_texture(ratio, faction == "player" or faction == "blue")


func _make_bar_texture(ratio: float, is_player: bool) -> Texture2D:
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
