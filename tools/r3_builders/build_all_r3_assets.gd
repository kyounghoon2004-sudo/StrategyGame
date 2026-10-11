extends SceneTree

## R3 Asset Builder — Generates high-fidelity painterly 2.5D assets for Visual Overhaul R3
## Implements Five Dynasties & Northern Song landscape painting aesthetic (References A, B, C)
## Output root: res://assets/visual_overhaul_r3/

const BASE_DIR: String = "res://assets/visual_overhaul_r3/"

func _init() -> void:
	print("==================================================")
	print("  STARTING R3 ASSET GENERATION PIPELINE")
	print("==================================================")
	
	build_terrain_mountains()
	build_terrain_forests()
	build_terrain_plains_and_marsh()
	build_terrain_rivers_and_roads()
	build_settlement_assets()
	build_formation_and_banner_assets()
	build_atmospheric_assets()
	build_ui_and_annotation_assets()
	
	print("==================================================")
	print("  R3 ASSET GENERATION COMPLETE!")
	print("==================================================")
	quit(0)

# ------------------------------------------------------------------
# UTILITY FUNCTIONS FOR PAINTERLY IMAGE SYNTHESIS
# ------------------------------------------------------------------
func create_blank_image(w: int, h: int, fill_col: Color = Color(0, 0, 0, 0)) -> Image:
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(fill_col)
	return img

func save_img(img: Image, rel_path: String) -> void:
	var full_path: String = BASE_DIR + rel_path
	var err := img.save_png(full_path)
	if err != OK:
		printerr("Failed to save: %s (error %d)" % [full_path, err])
	else:
		print("Saved: %s (%dx%d)" % [rel_path, img.get_width(), img.get_height()])

func blend_pixel(img: Image, x: int, y: int, col: Color) -> void:
	if x < 0 or x >= img.get_width() or y < 0 or y >= img.get_height():
		return
	var src := col
	if src.a <= 0.001:
		return
	var dst := img.get_pixel(x, y)
	var out_a: float = src.a + dst.a * (1.0 - src.a)
	if out_a <= 0.001:
		return
	var out_r: float = (src.r * src.a + dst.r * dst.a * (1.0 - src.a)) / out_a
	var out_g: float = (src.g * src.a + dst.g * dst.a * (1.0 - src.a)) / out_a
	var out_b: float = (src.b * src.a + dst.b * dst.a * (1.0 - src.a)) / out_a
	img.set_pixel(x, y, Color(out_r, out_g, out_b, out_a))

func draw_soft_circle(img: Image, cx: float, cy: float, radius: float, col: Color, softness: float = 0.5) -> void:
	var x_min: int = maxi(0, int(cx - radius - 1))
	var x_max: int = mini(img.get_width() - 1, int(cx + radius + 1))
	var y_min: int = maxi(0, int(cy - radius - 1))
	var y_max: int = mini(img.get_height() - 1, int(cy + radius + 1))
	var inner_r: float = radius * (1.0 - softness)
	for y in range(y_min, y_max + 1):
		for x in range(x_min, x_max + 1):
			var dist: float = Vector2(float(x) - cx, float(y) - cy).length()
			if dist <= radius:
				var alpha_factor: float = 1.0
				if dist > inner_r:
					alpha_factor = 1.0 - (dist - inner_r) / (radius - inner_r)
				var c := Color(col.r, col.g, col.b, col.a * alpha_factor)
				blend_pixel(img, x, y, c)

func draw_brush_stroke(img: Image, p1: Vector2, p2: Vector2, width: float, col: Color, wobble_noise: FastNoiseLite = null) -> void:
	var dist: float = p1.distance_to(p2)
	var steps: int = maxi(1, int(dist * 2.0))
	for i in range(steps + 1):
		var t: float = float(i) / float(steps)
		var p: Vector2 = p1.lerp(p2, t)
		if wobble_noise != null:
			var w_val: float = wobble_noise.get_noise_2d(p.x, p.y) * width * 0.4
			p += Vector2(- (p2.y - p1.y), p2.x - p1.x).normalized() * w_val
		draw_soft_circle(img, p.x, p.y, width * 0.5, col, 0.4)

# ------------------------------------------------------------------
# PHASE 2: MOUNTAINS (MONUMENTAL RANGES & RIDGES)
# ------------------------------------------------------------------
func build_terrain_mountains() -> void:
	print("--- Building Mountains Library ---")
	var noise := FastNoiseLite.new()
	noise.seed = 108
	noise.frequency = 0.04
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX

	# 1. Mountain Peak Large (256x256)
	_generate_mountain_peak("terrain/mountains/mountain_peak_large.png", 256, 256, 1.0, noise)
	# 2. Mountain Peak Medium (192x192)
	_generate_mountain_peak("terrain/mountains/mountain_peak_medium.png", 192, 192, 0.75, noise)
	# 3. Mountain Peak Small (128x128)
	_generate_mountain_peak("terrain/mountains/mountain_peak_small.png", 128, 128, 0.5, noise)

	# 4. Mountain Ridge Long (512x256)
	_generate_mountain_ridge("terrain/mountains/mountain_ridge_long.png", 512, 256, 3, noise)
	# 5. Mountain Ridge Medium (384x200)
	_generate_mountain_ridge("terrain/mountains/mountain_ridge_medium.png", 384, 200, 2, noise)
	# 6. Mountain Ridge Short (256x160)
	_generate_mountain_ridge("terrain/mountains/mountain_ridge_short.png", 256, 160, 1, noise)

	# 7. Mountain Pass (320x200)
	_generate_mountain_pass("terrain/mountains/mountain_pass.png", 320, 200, noise)
	# 8. Cliff Face (192x160)
	_generate_cliff_face("terrain/mountains/cliff_face.png", 192, 160, noise)
	# 9. Rocky Foothills (256x128)
	_generate_foothills("terrain/mountains/rocky_foothills.png", 256, 128, noise)
	# 10. Distant Mountain Silhouette (512x192)
	_generate_distant_mountains("terrain/mountains/distant_mountain_silhouette.png", 512, 192, noise)
	# 11. Mountain Mist Layer (384x128)
	_generate_mountain_mist("terrain/mountains/mountain_mist_layer.png", 384, 128)

func _generate_mountain_peak(path: String, w: int, h: int, scale_factor: float, noise: FastNoiseLite) -> void:
	var img := create_blank_image(w, h)
	var peak_x: float = float(w) * 0.48
	var peak_y: float = float(h) * 0.18
	var base_y: float = float(h) * 0.90
	var left_base_x: float = float(w) * 0.08
	var right_base_x: float = float(w) * 0.92

	# Primary color tones (Five Dynasties ink & mineral ochre)
	var col_lit_top := Color(0.76, 0.68, 0.52, 0.98)       # Ochre sunlight
	var col_lit_mid := Color(0.62, 0.54, 0.40, 0.96)       # Weathered stone
	var col_shade_deep := Color(0.18, 0.17, 0.18, 0.98)    # Deep ink shadow
	var col_shade_mid := Color(0.32, 0.28, 0.26, 0.95)     # Mid shadow
	var col_ridge_line := Color(0.14, 0.12, 0.12, 0.98)    # Sharp ink crest
	var col_foothill_mist := Color(0.86, 0.82, 0.74, 0.0)  # Mist base

	# Draw mountain mass scanlines
	for y in range(int(peak_y), int(base_y)):
		var progress: float = float(y - peak_y) / float(base_y - peak_y)
		var curve_pow: float = pow(progress, 0.85)
		var ridge_x: float = peak_x + sin(progress * 4.0) * (14.0 * scale_factor)
		var lx: float = lerpf(peak_x, left_base_x, curve_pow) - noise.get_noise_2d(float(y), 10.0) * 12.0
		var rx: float = lerpf(peak_x, right_base_x, curve_pow) + noise.get_noise_2d(float(y), 50.0) * 12.0

		for x in range(int(lx), int(rx)):
			var n_val: float = noise.get_noise_2d(float(x) * 0.8, float(y) * 0.8)
			var base_col: Color
			if x < ridge_x:
				# Lit northwest face
				var lit_t: float = float(x - lx) / float(ridge_x - lx)
				base_col = col_lit_mid.lerp(col_lit_top, lit_t)
				# Axe-cut strokes texture
				if fmod(abs(n_val * 10.0), 1.0) < 0.25:
					base_col = base_col.darkened(0.20)
			else:
				# Shaded southeast face
				var shade_t: float = float(x - ridge_x) / float(rx - ridge_x)
				base_col = col_shade_deep.lerp(col_shade_mid, 1.0 - shade_t)
				if fmod(abs(n_val * 8.0), 1.0) < 0.3:
					base_col = base_col.darkened(0.25)
			
			# Soften bottom edge for seamless ground blending
			if progress > 0.75:
				var mist_t: float = (progress - 0.75) / 0.25
				base_col.a *= (1.0 - mist_t * 0.75)
			blend_pixel(img, x, y, base_col)

	# Draw crisp calligraphic mountain spine ridge
	var prev_pt := Vector2(peak_x, peak_y)
	for y in range(int(peak_y), int(base_y * 0.85), 4):
		var progress2: float = float(y - peak_y) / float(base_y - peak_y)
		var rx2: float = peak_x + sin(progress2 * 4.0) * (14.0 * scale_factor)
		var cur_pt := Vector2(rx2, float(y))
		draw_brush_stroke(img, prev_pt, cur_pt, 2.5 * scale_factor, col_ridge_line, noise)
		prev_pt = cur_pt

	# Add foothill cloud mist at the base
	for i in range(12):
		var mx: float = lerpf(left_base_x, right_base_x, float(i) / 12.0)
		var my: float = base_y - 12.0 + sin(float(i) * 1.5) * 8.0
		draw_soft_circle(img, mx, my, 24.0 * scale_factor, Color(0.88, 0.84, 0.76, 0.45), 0.7)

	save_img(img, path)

func _generate_mountain_ridge(path: String, w: int, h: int, peaks_count: int, noise: FastNoiseLite) -> void:
	var img := create_blank_image(w, h)
	var base_y: float = float(h) * 0.88
	var step_x: float = float(w) / float(peaks_count + 1)
	
	for p_idx in range(peaks_count):
		var px: float = step_x * (float(p_idx) + 1.0) + noise.get_noise_1d(float(p_idx) * 20.0) * 25.0
		var py: float = float(h) * (0.15 + 0.08 * (p_idx % 2))
		var lx: float = px - step_x * 0.85
		var rx: float = px + step_x * 0.85
		
		# Draw individual sub-peak within ridge
		for y in range(int(py), int(base_y)):
			var t_y: float = float(y - py) / float(base_y - py)
			var sub_lx: float = lerpf(px, lx, pow(t_y, 0.8))
			var sub_rx: float = lerpf(px, rx, pow(t_y, 0.8))
			var ridge_x: float = px + sin(t_y * 3.0) * 10.0
			for x in range(int(sub_lx), int(sub_rx)):
				var n_val: float = noise.get_noise_2d(float(x) * 0.7, float(y) * 0.7)
				var c: Color
				if x < ridge_x:
					c = Color(0.68, 0.60, 0.46, 0.96).lerp(Color(0.78, 0.70, 0.55, 0.98), float(x - sub_lx) / float(ridge_x - sub_lx))
					if fmod(abs(n_val * 7.0), 1.0) < 0.2:
						c = c.darkened(0.18)
				else:
					c = Color(0.20, 0.18, 0.20, 0.98).lerp(Color(0.35, 0.30, 0.28, 0.95), 1.0 - float(x - ridge_x) / float(sub_rx - ridge_x))
				if t_y > 0.72:
					c.a *= (1.0 - (t_y - 0.72) / 0.28 * 0.8)
				blend_pixel(img, x, y, c)

	# Mountain base mist
	for x in range(0, w, 20):
		var my: float = base_y - 8.0 + noise.get_noise_1d(float(x)) * 12.0
		draw_soft_circle(img, float(x), my, 32.0, Color(0.88, 0.84, 0.75, 0.40), 0.75)

	save_img(img, path)

func _generate_mountain_pass(path: String, w: int, h: int, noise: FastNoiseLite) -> void:
	var img := create_blank_image(w, h)
	var mid_x: float = float(w) * 0.5
	# Left cliff
	for y in range(int(float(h) * 0.1), int(float(h) * 0.9)):
		var t: float = float(y) / float(h)
		var lx: float = 0.0
		var rx: float = mid_x - 30.0 + sin(t * 5.0) * 12.0
		for x in range(int(lx), int(rx)):
			blend_pixel(img, x, y, Color(0.55, 0.48, 0.38, 0.95))
	# Right cliff
	for y in range(int(float(h) * 0.1), int(float(h) * 0.9)):
		var t2: float = float(y) / float(h)
		var lx2: float = mid_x + 30.0 - sin(t2 * 5.0) * 12.0
		var rx2: float = float(w)
		for x in range(int(lx2), int(rx2)):
			blend_pixel(img, x, y, Color(0.22, 0.20, 0.22, 0.96))
	# Road corridor winding through pass
	for y in range(int(float(h) * 0.2), int(float(h) * 0.9)):
		var road_x: float = mid_x + sin(float(y) * 0.05) * 8.0
		draw_soft_circle(img, road_x, float(y), 10.0, Color(0.72, 0.64, 0.50, 0.90), 0.5)

	save_img(img, path)

func _generate_cliff_face(path: String, w: int, h: int, noise: FastNoiseLite) -> void:
	var img := create_blank_image(w, h)
	for y in range(10, h - 10):
		var t: float = float(y) / float(h)
		for x in range(10, w - 10):
			var n: float = noise.get_noise_2d(float(x) * 1.5, float(y) * 0.5)
			var c := Color(0.28, 0.25, 0.24, 0.96)
			if n > 0.1:
				c = c.lightened(0.25)
			elif n < -0.1:
				c = c.darkened(0.25)
			blend_pixel(img, x, y, c)
	save_img(img, path)

func _generate_foothills(path: String, w: int, h: int, noise: FastNoiseLite) -> void:
	var img := create_blank_image(w, h)
	for i in range(7):
		var cx: float = float(w) * (float(i) + 0.5) / 7.0
		var cy: float = float(h) * 0.6 + sin(float(i) * 2.0) * 14.0
		draw_soft_circle(img, cx, cy, 38.0, Color(0.58, 0.62, 0.42, 0.85), 0.6) # Mossy foothill mound
		draw_soft_circle(img, cx - 6.0, cy - 6.0, 20.0, Color(0.68, 0.60, 0.46, 0.70), 0.5) # Rock outcrop
	save_img(img, path)

func _generate_distant_mountains(path: String, w: int, h: int, noise: FastNoiseLite) -> void:
	var img := create_blank_image(w, h)
	# Soft blue-grey ink silhouette for map perimeter
	for x in range(w):
		var n: float = noise.get_noise_1d(float(x) * 0.8)
		var peak_y: float = float(h) * (0.35 + 0.30 * n)
		for y in range(int(peak_y), h):
			var t: float = float(y - peak_y) / float(h - peak_y)
			var alpha: float = (1.0 - t * 0.8) * 0.65
			blend_pixel(img, x, y, Color(0.38, 0.44, 0.52, alpha))
	save_img(img, path)

func _generate_mountain_mist(path: String, w: int, h: int) -> void:
	var img := create_blank_image(w, h)
	for i in range(16):
		var cx: float = float(w) * float(i) / 15.0
		var cy: float = float(h) * 0.5 + sin(float(i) * 1.8) * 15.0
		draw_soft_circle(img, cx, cy, 32.0, Color(0.92, 0.90, 0.85, 0.35), 0.8)
	save_img(img, path)

# ------------------------------------------------------------------
# PHASE 2: FORESTS (PINE, BAMBOO & BROADLEAF MASSES)
# ------------------------------------------------------------------
func build_terrain_forests() -> void:
	print("--- Building Forests Library ---")
	# Pine Clusters
	_generate_forest_cluster("terrain/forests/pine_cluster_large.png", 256, 160, true, 28)
	_generate_forest_cluster("terrain/forests/pine_cluster_medium.png", 192, 128, true, 18)
	_generate_forest_cluster("terrain/forests/pine_cluster_small.png", 128, 96, true, 9)
	# Bamboo / Broadleaf Clusters
	_generate_forest_cluster("terrain/forests/mixed_forest_large.png", 256, 160, false, 26)
	_generate_forest_cluster("terrain/forests/mixed_forest_small.png", 160, 120, false, 12)
	_generate_bamboo_cluster("terrain/forests/bamboo_cluster.png", 128, 96)
	_generate_forest_dense_center("terrain/forests/forest_dense_center.png", 256, 192)
	_generate_forest_shadow("terrain/forests/forest_shadow_underlay.png", 256, 160)

func _generate_forest_cluster(path: String, w: int, h: int, is_pine: bool, tree_count: int) -> void:
	var img := create_blank_image(w, h)
	var rng := RandomNumberGenerator.new()
	rng.seed = 204

	# Drop shadow under forest canopy
	for i in range(tree_count):
		var tx: float = rng.randf_range(float(w) * 0.15, float(w) * 0.85)
		var ty: float = rng.randf_range(float(h) * 0.35, float(h) * 0.85)
		draw_soft_circle(img, tx + 6.0, ty + 6.0, 16.0, Color(0.08, 0.12, 0.08, 0.40), 0.6)

	# Clustered tree crowns
	var col_deep := Color(0.16, 0.26, 0.16, 0.98) if is_pine else Color(0.24, 0.36, 0.18, 0.98)
	var col_mid := Color(0.24, 0.38, 0.22, 0.98) if is_pine else Color(0.34, 0.48, 0.24, 0.98)
	var col_high := Color(0.36, 0.52, 0.30, 0.98) if is_pine else Color(0.46, 0.62, 0.32, 0.98)

	# Sort back-to-front by Y
	var trees: Array[Vector2] = []
	for i in range(tree_count):
		trees.append(Vector2(rng.randf_range(float(w) * 0.12, float(w) * 0.88), rng.randf_range(float(h) * 0.20, float(h) * 0.80)))
	trees.sort_custom(func(a, b): return a.y < b.y)

	for pt in trees:
		var r: float = rng.randf_range(12.0, 18.0)
		# Tree body
		draw_soft_circle(img, pt.x, pt.y, r, col_deep, 0.35)
		draw_soft_circle(img, pt.x - 2.0, pt.y - 2.0, r * 0.75, col_mid, 0.45)
		draw_soft_circle(img, pt.x - 4.0, pt.y - 4.0, r * 0.45, col_high, 0.55)
		# Small trunk / root
		draw_brush_stroke(img, pt + Vector2(0, r * 0.6), pt + Vector2(0, r * 0.9), 2.5, Color(0.22, 0.16, 0.12, 0.9), null)

	save_img(img, path)

func _generate_bamboo_cluster(path: String, w: int, h: int) -> void:
	var img := create_blank_image(w, h)
	var rng := RandomNumberGenerator.new()
	rng.seed = 301
	for i in range(16):
		var bx: float = rng.randf_range(16.0, float(w) - 16.0)
		var by_top: float = rng.randf_range(12.0, 30.0)
		var by_bot: float = rng.randf_range(float(h) * 0.65, float(h) * 0.88)
		# Slender bamboo stalk
		draw_brush_stroke(img, Vector2(bx, by_bot), Vector2(bx, by_top), 2.0, Color(0.38, 0.52, 0.24, 0.95), null)
		# Bamboo leaf tufts
		for j in range(4):
			var ly: float = lerpf(by_top, by_bot, float(j) / 4.0)
			draw_soft_circle(img, bx + (5.0 if j % 2 == 0 else -5.0), ly, 7.0, Color(0.48, 0.66, 0.28, 0.9), 0.5)
	save_img(img, path)

func _generate_forest_dense_center(path: String, w: int, h: int) -> void:
	var img := create_blank_image(w, h)
	# Solid lush forest blanket
	for y in range(20, h - 20):
		for x in range(20, w - 20):
			var dist_center: float = Vector2(float(x - w / 2), float(y - h / 2)).length()
			if dist_center < float(w) * 0.42:
				blend_pixel(img, x, y, Color(0.20, 0.32, 0.18, 0.95))
	save_img(img, path)

func _generate_forest_shadow(path: String, w: int, h: int) -> void:
	var img := create_blank_image(w, h)
	draw_soft_circle(img, float(w) * 0.5, float(h) * 0.5, float(w) * 0.40, Color(0.06, 0.10, 0.06, 0.45), 0.7)
	save_img(img, path)

# ------------------------------------------------------------------
# PHASE 2: PLAINS, CROPS & MARSH
# ------------------------------------------------------------------
func build_terrain_plains_and_marsh() -> void:
	print("--- Building Plains & Marsh Library ---")
	var noise := FastNoiseLite.new()
	noise.seed = 404
	noise.frequency = 0.05
	
	# 1. Seamless Antique Silk Parchment Ground Texture (512x512)
	var ground_img := create_blank_image(512, 512)
	for y in range(512):
		for x in range(512):
			var n: float = noise.get_noise_2d(float(x) * 2.0, float(y) * 2.0)
			var base_c := Color(0.85, 0.80, 0.68, 1.0) # Warm silk parchment
			var grain: float = n * 0.06
			var c := Color(base_c.r + grain, base_c.g + grain * 0.8, base_c.b + grain * 0.5, 1.0)
			ground_img.set_pixel(x, y, c)
	save_img(ground_img, "terrain/plains/parchment_base_tile.png")

	# 2. Terraced Farm Plots (256x256)
	var farm_img := create_blank_image(256, 256)
	for i in range(6):
		var py: float = 30.0 + float(i) * 35.0
		var plot_c := Color(0.74, 0.72, 0.52, 0.75) if (i % 2 == 0) else Color(0.70, 0.66, 0.46, 0.75)
		for y in range(int(py), int(py + 28)):
			for x in range(25, 231):
				blend_pixel(farm_img, x, y, plot_c)
		# Paddy ridge divider line
		draw_brush_stroke(farm_img, Vector2(20, py), Vector2(235, py), 2.0, Color(0.50, 0.44, 0.32, 0.9), null)
	save_img(farm_img, "terrain/plains/farm_plots.png")

	# 3. Marsh Reed Clusters (192x128)
	var marsh_img := create_blank_image(192, 128)
	# Shallow silt puddle
	draw_soft_circle(marsh_img, 96.0, 64.0, 52.0, Color(0.38, 0.48, 0.42, 0.60), 0.6)
	draw_soft_circle(marsh_img, 96.0, 64.0, 36.0, Color(0.28, 0.42, 0.40, 0.75), 0.5)
	# Reed stalks
	for i in range(24):
		var rx: float = 60.0 + float(i) * 3.2
		var ry: float = 40.0 + sin(float(i) * 1.5) * 14.0
		draw_brush_stroke(marsh_img, Vector2(rx, ry + 22.0), Vector2(rx + sin(float(i)) * 4.0, ry), 1.8, Color(0.42, 0.50, 0.26, 0.95), null)
	save_img(marsh_img, "terrain/marsh/reed_cluster.png")

# ------------------------------------------------------------------
# PHASE 2: RIVERS & ROADS
# ------------------------------------------------------------------
func build_terrain_rivers_and_roads() -> void:
	print("--- Building Rivers & Roads Library ---")
	# River Straight Segment (256x96)
	var riv_img := create_blank_image(256, 96)
	for x in range(256):
		var my: float = 48.0 + sin(float(x) * 0.05) * 6.0
		# Sandy silt embankment
		draw_soft_circle(riv_img, float(x), my, 28.0, Color(0.76, 0.70, 0.56, 0.85), 0.5)
		# Translucent jade-turquoise water
		draw_soft_circle(riv_img, float(x), my, 18.0, Color(0.24, 0.52, 0.58, 0.95), 0.4)
		# Center deep turquoise channel
		draw_soft_circle(riv_img, float(x), my, 10.0, Color(0.18, 0.44, 0.52, 0.98), 0.3)
		# Whitewater ripple strokes
		if x % 32 == 0:
			draw_brush_stroke(riv_img, Vector2(float(x) - 8, my - 3), Vector2(float(x) + 8, my - 3), 1.5, Color(0.85, 0.95, 0.98, 0.7), null)
	save_img(riv_img, "terrain/rivers/river_straight.png")

	# Timber Beam Bridge (128x96)
	var bridge_img := create_blank_image(128, 96)
	# Stone pier foundation
	draw_brush_stroke(bridge_img, Vector2(34, 18), Vector2(34, 78), 10.0, Color(0.42, 0.40, 0.38, 0.98), null)
	draw_brush_stroke(bridge_img, Vector2(94, 18), Vector2(94, 78), 10.0, Color(0.42, 0.40, 0.38, 0.98), null)
	# Wooden deck planks
	for y in range(20, 76, 6):
		draw_brush_stroke(bridge_img, Vector2(24, float(y)), Vector2(104, float(y)), 4.0, Color(0.56, 0.42, 0.28, 0.98), null)
	# Handrails
	draw_brush_stroke(bridge_img, Vector2(20, 20), Vector2(108, 20), 3.0, Color(0.38, 0.26, 0.16, 0.98), null)
	draw_brush_stroke(bridge_img, Vector2(20, 76), Vector2(108, 76), 3.0, Color(0.38, 0.26, 0.16, 0.98), null)
	save_img(bridge_img, "terrain/rivers/timber_bridge.png")

	# Road Straight Segment (256x64)
	var road_img := create_blank_image(256, 64)
	for x in range(256):
		var ry: float = 32.0 + sin(float(x) * 0.08) * 3.0
		# Packed clay dirt pathway with soft edges
		draw_soft_circle(road_img, float(x), ry, 12.0, Color(0.68, 0.60, 0.46, 0.85), 0.6)
		draw_soft_circle(road_img, float(x), ry, 6.0, Color(0.62, 0.54, 0.40, 0.90), 0.5)
	save_img(road_img, "terrain/roads/road_straight.png")

# ------------------------------------------------------------------
# PHASE 3: SETTLEMENTS & MONUMENTAL STRONGHOLDS
# ------------------------------------------------------------------
func build_settlement_assets() -> void:
	print("--- Building Settlements & Strongholds Library ---")
	# 1. Rural Village (192x160)
	var vil_img := create_blank_image(192, 160)
	# 3 thatched cottages
	var cottage_pos := [Vector2(55, 60), Vector2(115, 50), Vector2(90, 105)]
	for p in cottage_pos:
		# Mud brick walls
		for y in range(int(p.y), int(p.y + 24)):
			for x in range(int(p.x - 16), int(p.x + 16)):
				blend_pixel(vil_img, x, y, Color(0.64, 0.58, 0.46, 0.98))
		# Thatched roof (steep hip roof)
		for y in range(int(p.y - 14), int(p.y)):
			var t: float = float(y - (p.y - 14)) / 14.0
			var hw: float = lerpf(4.0, 22.0, t)
			for x in range(int(p.x - hw), int(p.x + hw)):
				blend_pixel(vil_img, x, y, Color(0.76, 0.66, 0.42, 0.98))
		# Wooden door
		for y in range(int(p.y + 8), int(p.y + 24)):
			for x in range(int(p.x - 4), int(p.x + 4)):
				blend_pixel(vil_img, x, y, Color(0.32, 0.22, 0.14, 0.98))
	save_img(vil_img, "settlements/village/rural_village.png")

	# 2. Fortress Hulao (Mountain Pass Bastion, 320x240)
	var fort_img := create_blank_image(320, 240)
	# Heavy granite bastion walls
	for y in range(90, 180):
		for x in range(60, 260):
			var wall_c := Color(0.44, 0.42, 0.40, 0.98) if (y % 8 < 4) else Color(0.38, 0.36, 0.35, 0.98)
			blend_pixel(fort_img, x, y, wall_c)
	# Battlements / Crenels on top
	for x in range(60, 260, 16):
		for y in range(78, 90):
			for bx in range(x, x + 8):
				blend_pixel(fort_img, bx, y, Color(0.44, 0.42, 0.40, 0.98))
	# Central timber command turret with tiled roof
	for y in range(45, 78):
		for x in range(130, 190):
			blend_pixel(fort_img, x, y, Color(0.48, 0.26, 0.22, 0.98)) # Dark timber
	# Flared grey tile roof
	for y in range(25, 45):
		var t_roof: float = float(y - 25) / 20.0
		var r_hw: float = lerpf(10.0, 42.0, t_roof)
		for x in range(int(160.0 - r_hw), int(160.0 + r_hw)):
			blend_pixel(fort_img, x, y, Color(0.24, 0.26, 0.28, 0.98))
	# Barbican arched gateway
	for y in range(135, 180):
		for x in range(145, 175):
			blend_pixel(fort_img, x, y, Color(0.12, 0.10, 0.10, 0.98))
	# Garrison war banners
	draw_brush_stroke(fort_img, Vector2(100, 78), Vector2(100, 50), 2.0, Color(0.14, 0.12, 0.10, 1.0), null)
	draw_brush_stroke(fort_img, Vector2(220, 78), Vector2(220, 50), 2.0, Color(0.14, 0.12, 0.10, 1.0), null)
	for y in range(50, 70):
		for x in range(100, 118):
			blend_pixel(fort_img, x, y, Color(0.78, 0.18, 0.18, 0.95))
		for x in range(220, 238):
			blend_pixel(fort_img, x, y, Color(0.78, 0.18, 0.18, 0.95))
	save_img(fort_img, "settlements/fortress/fortress_hulao.png")

	# 3. Capital Luoyang Grand Citadel (512x384)
	var cap_img := create_blank_image(512, 384)
	# Outer water moat
	for y in range(140, 330):
		for x in range(50, 462):
			var dist_wall_x: float = minf(abs(float(x) - 70), abs(float(x) - 442))
			var dist_wall_y: float = minf(abs(float(y) - 160), abs(float(y) - 310))
			if dist_wall_x < 22 or dist_wall_y < 22:
				blend_pixel(cap_img, x, y, Color(0.22, 0.46, 0.52, 0.85))
	# Imperial red stone ramparts
	for y in range(160, 310):
		for x in range(70, 442):
			if x <= 95 or x >= 417 or y <= 185 or y >= 285:
				blend_pixel(cap_img, x, y, Color(0.58, 0.22, 0.20, 0.98)) # Red ashlar
			else:
				blend_pixel(cap_img, x, y, Color(0.72, 0.68, 0.58, 0.95)) # Inner courtyard
	# 4 Corner Watchtowers (角楼)
	var corners := [Vector2(70, 160), Vector2(442, 160), Vector2(70, 310), Vector2(442, 310)]
	for c_pos in corners:
		for y in range(int(c_pos.y - 20), int(c_pos.y + 15)):
			for x in range(int(c_pos.x - 18), int(c_pos.x + 18)):
				blend_pixel(cap_img, x, y, Color(0.68, 0.24, 0.20, 0.98))
		# Corner flared roofs
		for y in range(int(c_pos.y - 36), int(c_pos.y - 20)):
			var tw: float = lerpf(6.0, 24.0, float(y - (c_pos.y - 36)) / 16.0)
			for x in range(int(c_pos.x - tw), int(c_pos.x + tw)):
				blend_pixel(cap_img, x, y, Color(0.88, 0.68, 0.24, 0.98)) # Gold glazed tile
	# Grand Palace Pavilion in center (重檐庑殿顶 - 2 tiers)
	var pal_cx: float = 256.0
	var pal_cy: float = 230.0
	# Lower roof tier
	for y in range(int(pal_cy - 20), int(pal_cy)):
		var rw1: float = lerpf(20.0, 65.0, float(y - (pal_cy - 20)) / 20.0)
		for x in range(int(pal_cx - rw1), int(pal_cx + rw1)):
			blend_pixel(cap_img, x, y, Color(0.92, 0.72, 0.22, 0.98))
	# Upper roof tier
	for y in range(int(pal_cy - 48), int(pal_cy - 24)):
		var rw2: float = lerpf(10.0, 48.0, float(y - (pal_cy - 48)) / 24.0)
		for x in range(int(pal_cx - rw2), int(pal_cx + rw2)):
			blend_pixel(cap_img, x, y, Color(0.96, 0.78, 0.25, 0.98))
	# Barbican Main Gate
	for y in range(285, 315):
		for x in range(240, 272):
			blend_pixel(cap_img, x, y, Color(0.12, 0.08, 0.08, 0.98))
	# Stone bridge across moat at main gate
	for y in range(310, 335):
		for x in range(242, 270):
			blend_pixel(cap_img, x, y, Color(0.65, 0.62, 0.58, 0.98))
	save_img(cap_img, "settlements/capital/capital_luoyang.png")

# ------------------------------------------------------------------
# PHASE 4 & 5: ARMY FORMATIONS & WAR BANNERS
# ------------------------------------------------------------------
func build_formation_and_banner_assets() -> void:
	print("--- Building Formations & Banners Library ---")
	var classes: Array[String] = ["infantry", "spearman", "archer", "cavalry", "conscript", "scout", "siege", "hq", "supply"]
	var crests: Dictionary = {
		"hq": "帥", "infantry": "步", "spearman": "槍", "archer": "弓",
		"cavalry": "騎", "conscript": "勇", "scout": "斥", "siege": "器", "supply": "糧"
	}

	for cls in classes:
		# Allied formations (Deep Blue livery)
		_generate_formation_detachment("formations/ally/formation_%s.png" % cls, true, cls)
		# Enemy formations (Cinnabar Red livery)
		_generate_formation_detachment("formations/enemy/formation_%s.png" % cls, false, cls)
		# Distinct war banners
		_generate_war_banner("formations/banners/banner_ally_%s.png" % cls, true, crests[cls])
		_generate_war_banner("formations/banners/banner_enemy_%s.png" % cls, false, crests[cls])

	# Supply Wagon (128x96)
	_generate_supply_wagon("formations/supply/supply_wagon.png")

func _generate_formation_detachment(path: String, is_ally: bool, cls_name: String) -> void:
	var img := create_blank_image(192, 160)
	var col_armor := Color(0.18, 0.32, 0.58, 0.98) if is_ally else Color(0.68, 0.18, 0.18, 0.98)
	var col_trim := Color(0.92, 0.82, 0.45, 0.98) if is_ally else Color(0.48, 0.38, 0.24, 0.98)
	var col_flesh := Color(0.88, 0.74, 0.62, 0.98)

	# Ground shadow under detachment
	draw_soft_circle(img, 96.0, 115.0, 52.0, Color(0.08, 0.08, 0.10, 0.45), 0.7)

	# Draw small squad of ~12 soldiers in ordered ranks
	var squad_cols := 4
	var squad_rows := 3
	for r in range(squad_rows):
		for c in range(squad_cols):
			var sx: float = 58.0 + float(c) * 25.0 + (5.0 if r % 2 == 1 else 0.0)
			var sy: float = 78.0 + float(r) * 18.0
			
			if cls_name == "cavalry" or (cls_name == "hq" and r == 1 and c == 1):
				# Warhorse body
				draw_brush_stroke(img, Vector2(sx - 10, sy + 6), Vector2(sx + 10, sy + 6), 10.0, Color(0.24, 0.18, 0.14, 0.98), null)
				# Horse head & barding
				draw_brush_stroke(img, Vector2(sx + 8, sy + 4), Vector2(sx + 14, sy - 4), 6.0, col_armor, null)
			
			# Soldier Torso (Cuirass / Tunic)
			for y in range(int(sy - 10), int(sy + 4)):
				for x in range(int(sx - 4), int(sx + 4)):
					blend_pixel(img, x, y, col_armor)
			# Head & Helmet
			draw_soft_circle(img, sx, sy - 14.0, 4.0, col_flesh, 0.3)
			draw_soft_circle(img, sx, sy - 16.0, 4.5, col_trim, 0.3) # Bronze/gold helmet

			# Specific class weapons
			if cls_name == "spearman":
				# Tall upright pike with red tassel
				draw_brush_stroke(img, Vector2(sx + 5, sy + 6), Vector2(sx + 5, sy - 32), 1.8, Color(0.35, 0.28, 0.20, 0.98), null)
				draw_soft_circle(img, sx + 5, sy - 26, 3.0, Color(0.85, 0.20, 0.20, 0.95), 0.4) # Red tassel
			elif cls_name == "archer":
				# Composite reflex bow
				draw_brush_stroke(img, Vector2(sx + 6, sy - 12), Vector2(sx + 10, sy), 1.5, Color(0.48, 0.36, 0.22, 0.98), null)
			elif cls_name == "infantry":
				# Rattan / iron shield
				for y in range(int(sy - 8), int(sy + 4)):
					for x in range(int(sx - 8), int(sx - 4)):
						blend_pixel(img, x, y, col_trim)

	# High vertical commander banner on left
	draw_brush_stroke(img, Vector2(40, 130), Vector2(40, 24), 3.0, Color(0.18, 0.14, 0.12, 1.0), null)
	# Triangular saw-tooth pennant
	var banner_col := Color(0.18, 0.38, 0.72, 0.98) if is_ally else Color(0.78, 0.18, 0.18, 0.98)
	for y in range(26, 75):
		var t_b: float = float(y - 26) / 49.0
		var b_w: float = lerpf(38.0, 4.0, t_b)
		for x in range(40, int(40.0 + b_w)):
			blend_pixel(img, x, y, banner_col)

	save_img(img, path)

func _generate_war_banner(path: String, is_ally: bool, crest_char: String) -> void:
	var img := create_blank_image(96, 160)
	var col_banner := Color(0.16, 0.34, 0.68, 0.98) if is_ally else Color(0.78, 0.18, 0.18, 0.98)
	var col_crest := Color(0.96, 0.88, 0.45, 0.98) if is_ally else Color(0.96, 0.92, 0.82, 0.98)

	# Banner pole with spearhead finial
	draw_brush_stroke(img, Vector2(24, 150), Vector2(24, 12), 3.5, Color(0.20, 0.16, 0.12, 1.0), null)
	draw_soft_circle(img, 24.0, 10.0, 5.0, Color(0.85, 0.72, 0.30, 1.0), 0.3)

	# Silk banner body (saw-tooth swallowtail)
	for y in range(16, 110):
		var t: float = float(y - 16) / 94.0
		var bw: float = 46.0 - (12.0 if (y % 14 < 7) else 0.0) * t # Saw-tooth fringe
		for x in range(25, int(25.0 + bw)):
			blend_pixel(img, x, y, col_banner)
	
	# Gold border along top and hoist
	for y in range(16, 110):
		for x in range(25, 29):
			blend_pixel(img, x, y, Color(0.92, 0.82, 0.45, 1.0))
	for x in range(25, 71):
		for y in range(16, 20):
			blend_pixel(img, x, y, Color(0.92, 0.82, 0.45, 1.0))

	save_img(img, path)

func _generate_supply_wagon(path: String) -> void:
	var img := create_blank_image(128, 96)
	# Wooden cart bed
	for y in range(48, 62):
		for x in range(30, 95):
			blend_pixel(img, x, y, Color(0.48, 0.36, 0.24, 0.98))
	# White canvas arched cover
	for y in range(24, 48):
		var t: float = float(y - 24) / 24.0
		var hw: float = sqrt(1.0 - pow(1.0 - t, 2.0)) * 28.0
		for x in range(int(60.0 - hw), int(60.0 + hw)):
			blend_pixel(img, x, y, Color(0.88, 0.86, 0.80, 0.98))
	# 2 large wooden spoke wheels
	draw_soft_circle(img, 44.0, 65.0, 14.0, Color(0.32, 0.22, 0.14, 0.98), 0.3)
	draw_soft_circle(img, 44.0, 65.0, 9.0, Color(0, 0, 0, 0), 0.4) # Hub hole
	draw_soft_circle(img, 82.0, 65.0, 14.0, Color(0.32, 0.22, 0.14, 0.98), 0.3)
	draw_soft_circle(img, 82.0, 65.0, 9.0, Color(0, 0, 0, 0), 0.4)
	# Draft ox in front
	draw_brush_stroke(img, Vector2(95, 52), Vector2(118, 52), 12.0, Color(0.42, 0.34, 0.26, 0.98), null)
	save_img(img, path)

# ------------------------------------------------------------------
# PHASE 6: ATMOSPHERE & FOG OF WAR
# ------------------------------------------------------------------
func build_atmospheric_assets() -> void:
	print("--- Building Atmospheric & Fog Assets Library ---")
	var noise := FastNoiseLite.new()
	noise.seed = 505
	noise.frequency = 0.03

	# Rolling Cloud Banks (512x256)
	var cloud_img := create_blank_image(512, 256)
	for y in range(256):
		for x in range(512):
			var n: float = noise.get_noise_2d(float(x), float(y))
			if n > 0.0:
				var alpha: float = clampf(n * 1.5, 0.0, 0.85)
				cloud_img.set_pixel(x, y, Color(0.92, 0.90, 0.85, alpha))
	save_img(cloud_img, "atmosphere/rolling_clouds.png")

	# Valley Mist Wisps (384x128)
	var mist_img := create_blank_image(384, 128)
	for i in range(12):
		var mx: float = float(384) * float(i) / 11.0
		var my: float = 64.0 + sin(float(i) * 1.8) * 18.0
		draw_soft_circle(mist_img, mx, my, 40.0, Color(0.94, 0.92, 0.88, 0.35), 0.85)
	save_img(mist_img, "atmosphere/valley_mist.png")

# ------------------------------------------------------------------
# PHASE 7 & 8: UI & ADVISOR TACTICAL OVERLAYS
# ------------------------------------------------------------------
func build_ui_and_annotation_assets() -> void:
	print("--- Building UI & Advisor Annotations Library ---")
	# 1. Dragon Crest Lacquer Top Command Bar Header (640x54)
	var bar_img := create_blank_image(640, 54)
	# Charcoal black lacquer background
	for y in range(54):
		for x in range(640):
			blend_pixel(bar_img, x, y, Color(0.065, 0.075, 0.095, 0.95))
	# Gold border frame
	for x in range(640):
		blend_pixel(bar_img, x, 0, Color(0.85, 0.72, 0.35, 1.0))
		blend_pixel(bar_img, x, 1, Color(0.55, 0.45, 0.22, 0.8))
		blend_pixel(bar_img, x, 52, Color(0.55, 0.45, 0.22, 0.8))
		blend_pixel(bar_img, x, 53, Color(0.85, 0.72, 0.35, 1.0))
	for y in range(54):
		blend_pixel(bar_img, 0, y, Color(0.85, 0.72, 0.35, 1.0))
		blend_pixel(bar_img, 639, y, Color(0.85, 0.72, 0.35, 1.0))
	# Stylized gold imperial dragon crest medallion on left
	draw_soft_circle(bar_img, 32.0, 27.0, 18.0, Color(0.88, 0.74, 0.35, 0.95), 0.2)
	draw_soft_circle(bar_img, 32.0, 27.0, 14.0, Color(0.07, 0.08, 0.10, 0.95), 0.2)
	save_img(bar_img, "ui/top_command_bar.png")

	# 2. Advisor Oval Medallion Frame with Portrait (128x128)
	var adv_img := create_blank_image(128, 128)
	# Outer gold ornamental ring
	draw_soft_circle(adv_img, 64.0, 64.0, 56.0, Color(0.85, 0.70, 0.30, 1.0), 0.1)
	draw_soft_circle(adv_img, 64.0, 64.0, 52.0, Color(0.12, 0.14, 0.18, 1.0), 0.05)
	# Scholar / Strategist portrait silhouette (court hat & robes)
	draw_soft_circle(adv_img, 64.0, 50.0, 16.0, Color(0.88, 0.74, 0.62, 1.0), 0.2) # Face
	# Black scholar cap (Futou / Guan)
	for y in range(20, 44):
		for x in range(48, 80):
			blend_pixel(adv_img, x, y, Color(0.10, 0.10, 0.12, 1.0))
	# Blue court robe
	for y in range(66, 115):
		var rw: float = float(y - 66) * 1.1
		for x in range(int(64.0 - rw), int(64.0 + rw)):
			blend_pixel(adv_img, x, y, Color(0.18, 0.28, 0.48, 1.0))
	save_img(adv_img, "ui/advisor_portrait_frame.png")

	# 3. Advisor Tactical Overlays: Expected Enemy Route Arrow (256x128)
	var arrow_img := create_blank_image(256, 128)
	# Cinnabar curved arrow corridor
	for x in range(20, 200):
		var ay: float = 64.0 + sin(float(x) * 0.03) * 16.0
		# Dashed corridor
		if (x / 14) % 2 == 0:
			draw_soft_circle(arrow_img, float(x), ay, 10.0, Color(0.85, 0.20, 0.18, 0.65), 0.4)
	# Arrowhead
	for i in range(28):
		var p_top := Vector2(230.0 - float(i), 64.0 - float(i) * 0.9)
		var p_bot := Vector2(230.0 - float(i), 64.0 + float(i) * 0.9)
		draw_brush_stroke(arrow_img, p_top, Vector2(230, 64), 2.0, Color(0.92, 0.24, 0.20, 0.90), null)
		draw_brush_stroke(arrow_img, p_bot, Vector2(230, 64), 2.0, Color(0.92, 0.24, 0.20, 0.90), null)
	save_img(arrow_img, "advisor_overlays/expected_enemy_route.png")

	# 4. Clash Point Crossed-Swords Marker (128x128)
	var clash_img := create_blank_image(128, 128)
	draw_soft_circle(clash_img, 64.0, 64.0, 48.0, Color(0.78, 0.18, 0.18, 0.85), 0.3)
	draw_soft_circle(clash_img, 64.0, 64.0, 42.0, Color(0.12, 0.08, 0.08, 0.92), 0.1)
	# Crossed blades
	draw_brush_stroke(clash_img, Vector2(38, 38), Vector2(90, 90), 4.0, Color(0.95, 0.92, 0.88, 1.0), null)
	draw_brush_stroke(clash_img, Vector2(90, 38), Vector2(38, 90), 4.0, Color(0.95, 0.92, 0.88, 1.0), null)
	save_img(clash_img, "advisor_overlays/clash_point_marker.png")

	# 5. Strategic Objective Ring (128x128)
	var obj_img := create_blank_image(128, 128)
	# Green radiant concentric rings
	draw_soft_circle(obj_img, 64.0, 64.0, 46.0, Color(0.24, 0.72, 0.38, 0.85), 0.2)
	draw_soft_circle(obj_img, 64.0, 64.0, 38.0, Color(0, 0, 0, 0), 0.3)
	draw_soft_circle(obj_img, 64.0, 64.0, 22.0, Color(0.24, 0.72, 0.38, 0.95), 0.2)
	draw_soft_circle(obj_img, 64.0, 64.0, 14.0, Color(0, 0, 0, 0), 0.3)
	draw_soft_circle(obj_img, 64.0, 64.0, 7.0, Color(0.95, 0.90, 0.50, 1.0), 0.2) # Gold bullseye
	save_img(obj_img, "advisor_overlays/strategic_objective_marker.png")
