extends RefCounted

## CIV3D soldier source (VISUAL ONLY): ONE approved single-soldier PNG at its
## native resolution (mipmapped) plus a region mask that tells the soldier
## shader which pixels are skin, faction cloth, cream under-cloth or
## leather / armour. The shader re-shades two or three of those regions per
## soldier (instance parameters from random_params()), so every man in every
## formation is an individual of the same class: silhouette, weapon and facing
## never change.

const Registry = preload("res://scripts/visual/hex_native/approved_asset_registry.gd")

const PAD: int = 4 # transparent border so mip levels never clamp into the art

enum Region { NONE, SKIN, CLOTH, CREAM, LEATHER }

static var _cache: Dictionary = {}

## {"texture", "regions", "aspect"}
static func source(resource_path: String) -> Dictionary:
	if _cache.has(resource_path):
		return _cache[resource_path]
	var src := Image.load_from_file(ProjectSettings.globalize_path(resource_path))
	if src == null or src.is_empty():
		push_error("[CivSoldierVariants] cannot read " + resource_path)
		return {}
	src.convert(Image.FORMAT_RGBA8)
	var b: Rect2 = Registry.body(resource_path)
	var crop := src.get_region(Rect2i(Vector2i(roundi(b.position.x), roundi(b.position.y)), Vector2i(roundi(b.size.x), roundi(b.size.y))))
	crop = crop.get_region(crop.get_used_rect())
	var img := Image.create(crop.get_width() + PAD * 2, crop.get_height() + PAD * 2, false, Image.FORMAT_RGBA8)
	img.blit_rect(crop, Rect2i(Vector2i.ZERO, crop.get_size()), Vector2i(PAD, PAD))
	var mask := _classify(img)
	img.generate_mipmaps()
	var res := {
		"texture": ImageTexture.create_from_image(img),
		"regions": ImageTexture.create_from_image(mask),
		"aspect": float(img.get_width()) / float(img.get_height()),
	}
	_cache[resource_path] = res
	return res

## Region id per pixel in the R channel (0..4).
static func _classify(img: Image) -> Image:
	var mask := Image.create(img.get_width(), img.get_height(), false, Image.FORMAT_R8)
	for y in range(img.get_height()):
		for x in range(img.get_width()):
			var c: Color = img.get_pixel(x, y)
			if c.a <= 0.5:
				continue
			var h: float = c.h
			var s: float = c.s
			var v: float = c.v
			var reg: int = Region.NONE
			if v < 0.16:
				reg = Region.NONE # outline / hair
			elif h > 0.025 and h < 0.115 and s > 0.22 and s < 0.62 and v > 0.58:
				reg = Region.SKIN
			elif (h > 0.53 and h < 0.72 and s > 0.3) or ((h > 0.94 or h < 0.025) and s > 0.45):
				reg = Region.CLOTH
			elif s < 0.2 and v > 0.68:
				reg = Region.CREAM
			elif h > 0.03 and h < 0.13 and v < 0.55 and s > 0.2:
				reg = Region.LEATHER
			mask.set_pixel(x, y, Color8(reg, 0, 0))
	return mask

## Instance parameters for one soldier: skin always shifts a little, then two
## or three of cloth / cream / leather. Neutral = (1, 1, 0.5, 0).
##   r skin value, g cloth value, b cloth hue (0.5 = none),
##   a = floor(cream * 15) / 16 + leather / 16  (cream 0..1 beige, leather 0..1 -> x0.7..x1.28)
static func random_params(rng: RandomNumberGenerator) -> Color:
	var skin: float = rng.randf_range(0.78, 1.1)
	var cloth_v: float = 1.0
	var cloth_h: float = 0.5
	var cream: float = 0.0
	var leather: float = 0.52 # neutral (x1.0)
	var picks: Array = [1, 2, 3]
	picks.shuffle()
	for i in range(rng.randi_range(2, 3)):
		match picks[i]:
			1:
				cloth_v = rng.randf_range(0.70, 1.18)
				cloth_h = rng.randf_range(0.0, 1.0)
			2:
				cream = rng.randf_range(0.35, 1.0)
			3:
				leather = rng.randf_range(0.0, 0.999)
	return Color(skin, cloth_v, cloth_h, floor(cream * 15.0) / 16.0 + leather / 16.0)
