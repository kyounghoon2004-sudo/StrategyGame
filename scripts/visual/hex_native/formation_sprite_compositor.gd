extends RefCounted

## Builds one cached presentation texture from ten copies of an approved
## single-soldier formation PNG. It creates no soldier nodes or game actors.
## The closer ranks preserve visible head/torso silhouettes at the opening
## strategy zoom instead of collapsing into tiny marks inside each hex.
const Registry = preload("res://scripts/visual/hex_native/approved_asset_registry.gd")
static var _cache: Dictionary = {}

static func compose(resource_path: String) -> Dictionary:
	if _cache.has(resource_path):
		return _cache[resource_path]
	var source := Image.load_from_file(ProjectSettings.globalize_path(resource_path))
	if source == null or source.is_empty():
		push_error("[FormationSpriteCompositor] cannot read approved PNG " + resource_path)
		return {}
	# The registered dense crop keeps the complete person and their weapon while
	# dropping sparse outer pixels that otherwise make the ten-person formation
	# fit too small inside its own logical hex.
	var source_bounds := Registry.body(resource_path)
	var source_rect := Rect2i(
		Vector2i(roundi(source_bounds.position.x), roundi(source_bounds.position.y)),
		Vector2i(roundi(source_bounds.size.x), roundi(source_bounds.size.y))
	)
	var soldier := source.get_region(source_rect)
	if soldier == null or soldier.is_empty():
		push_error("[FormationSpriteCompositor] empty approved sprite crop " + resource_path)
		return {}
	var scale_factor := minf(0.85, 116.0 / float(soldier.get_height()))
	var target_size := Vector2i(
		maxi(1, roundi(float(soldier.get_width()) * scale_factor)),
		maxi(1, roundi(float(soldier.get_height()) * scale_factor))
	)
	soldier.resize(target_size.x, target_size.y, Image.INTERPOLATE_NEAREST)
	var out := Image.create(368, 272, true, Image.FORMAT_RGBA8)
	# Back to front, four soldiers in the front rank and three in each rear rank.
	var placements: Array[Vector2i] = [
		Vector2i(119, 8), Vector2i(180, 8), Vector2i(241, 8),
		Vector2i(91, 80), Vector2i(152, 80), Vector2i(213, 80),
		Vector2i(27, 152), Vector2i(91, 152), Vector2i(155, 152), Vector2i(219, 152),
	]
	var body_local := Rect2(Vector2.ZERO, Vector2(target_size))
	var body_union := Rect2()
	for index in range(placements.size()):
		var dst: Vector2i = placements[index]
		out.blend_rect(soldier, Rect2i(Vector2i.ZERO, target_size), dst)
		var placed_body := Rect2(Vector2(dst) + body_local.position, body_local.size)
		body_union = placed_body if index == 0 else body_union.merge(placed_body)
	var used := out.get_used_rect()
	if used.position != Vector2i.ZERO or used.size != out.get_size():
		out = out.get_region(used)
		body_union.position -= Vector2(used.position)
	out.generate_mipmaps()
	var texture := ImageTexture.create_from_image(out)
	var result := {
		"texture": texture,
		"bounds": Rect2(Vector2.ZERO, Vector2(out.get_size())),
		"body": body_union,
		"soldier_count": placements.size(),
		"source": resource_path,
	}
	_cache[resource_path] = result
	return result
