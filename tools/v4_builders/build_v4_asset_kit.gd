extends SceneTree

## build_v4_asset_kit.gd — Asset Production Pipeline for Visual Overhaul v4
## Generates the approved modular battlefield asset kit:
## - Modular Mountain Kit (Foothills, Rough Hills, High Peaks, Ridge Connectors, Cliff Accents)
## - Forest & Woodland Variety Kit (Dense Cores, Light Edges, Sparse Copses, Bamboo, Shadows)
## - Base Terrain Readability Layer (Parchment, Grassland, Dry Earth, Terraces, Road Verges, Marshes)
## - Roads & Rivers Kit (Highways, Bends, Junctions, Trails, Channels, Meanders, Bridges)
## - Minor Settlements & Outposts (Villages, Hamlets, Granaries, Watchtowers, Shrines)
## - Stronghold Landmarks (Hulao Bastion, Luoyang Citadel)
## - Tactical Readability Foundations (Allied/Enemy Plinths, Hex Rings, Lacquer Header)

const OUT_ROOT: String = "res://assets/visual_overhaul_v4/"

func _init() -> void:
	print("==================================================")
	print("  STARTING V4 ASSET GENERATION PIPELINE")
	print("==================================================")

	build_mountain_modular_kit()
	build_forest_variety_kit()
	build_base_terrain_kit()
	build_road_and_river_kit()
	build_settlement_kit()
	build_stronghold_kit()
	build_readability_ui_kit()

	print("==================================================")
	print("  V4 ASSET GENERATION COMPLETE!")
	print("==================================================")
	quit(0)

# ------------------------------------------------------------------
# UTILITY FUNCTIONS FOR PAINTERLY SYNTHESIS
# ------------------------------------------------------------------
func create_blank(w: int, h: int, fill: Color = Color(0, 0, 0, 0)) -> Image:
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(fill)
	return img

func save_asset(img: Image, rel_path: String) -> void:
	var full_path: String = OUT_ROOT + rel_path
	var err := img.save_png(full_path)
	if err != OK:
		printerr("FAILED to save: %s (error %d)" % [full_path, err])
	else:
		print("Saved [%dx%d]: %s" % [img.get_width(), img.get_height(), rel_path])

func blend_px(img: Image, x: int, y: int, col: Color) -> void:
	if x < 0 or x >= img.get_width() or y < 0 or y >= img.get_height():
		return
	if col.a <= 0.001:
		return
	var dst := img.get_pixel(x, y)
	var out_a: float = col.a + dst.a * (1.0 - col.a)
	if out_a <= 0.001:
		return
	var out_r: float = (col.r * col.a + dst.r * dst.a * (1.0 - col.a)) / out_a
	var out_g: float = (col.g * col.a + dst.g * dst.a * (1.0 - col.a)) / out_a
	var out_b: float = (col.b * col.a + dst.b * dst.a * (1.0 - col.a)) / out_a
	img.set_pixel(x, y, Color(out_r, out_g, out_b, out_a))

func draw_soft_circle(img: Image, cx: float, cy: float, r: float, col: Color, softness: float = 0.5) -> void:
	var x0: int = maxi(0, int(cx - r - 1))
	var x1: int = mini(img.get_width() - 1, int(cx + r + 1))
	var y0: int = maxi(0, int(cy - r - 1))
	var y1: int = mini(img.get_height() - 1, int(cy + r + 1))
	var inner_r: float = r * (1.0 - softness)
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			var d: float = Vector2(float(x) - cx, float(y) - cy).length()
			if d <= r:
				var a_factor: float = 1.0
				if d > inner_r:
					a_factor = 1.0 - (d - inner_r) / (r - inner_r)
				blend_px(img, x, y, Color(col.r, col.g, col.b, col.a * a_factor))

func draw_brush_stroke(img: Image, p1: Vector2, p2: Vector2, width: float, col: Color, noise: FastNoiseLite = null) -> void:
	var dist: float = p1.distance_to(p2)
	var steps: int = maxi(1, int(dist * 1.5))
	for i in range(steps + 1):
		var t: float = float(i) / float(steps)
		var p: Vector2 = p1.lerp(p2, t)
		if noise != null:
			var w_val: float = noise.get_noise_2d(p.x, p.y) * width * 0.35
			p += Vector2(-(p2.y - p1.y), p2.x - p1.x).normalized() * w_val
		draw_soft_circle(img, p.x, p.y, width * 0.5, col, 0.45)

# ------------------------------------------------------------------
# 1. MODULAR MOUNTAIN KIT
# ------------------------------------------------------------------
func build_mountain_modular_kit() -> void:
	print("--- Building Modular Mountain Kit ---")
	var noise := FastNoiseLite.new()
	noise.seed = 2024
	noise.frequency = 0.04
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX

	# Low Foothills (3 variations)
	_gen_foothill("terrain/mountains/mtn_foothill_01.png", 192, 128, 0.9, 0, noise)
	_gen_foothill("terrain/mountains/mtn_foothill_02.png", 192, 128, 1.0, 1, noise)
	_gen_foothill("terrain/mountains/mtn_foothill_03.png", 160, 112, 0.75, 2, noise)

	# Passable Rough Hills (2 variations)
	_gen_rough_hill("terrain/mountains/mtn_rough_hill_01.png", 224, 160, 1.0, noise)
	_gen_rough_hill("terrain/mountains/mtn_rough_hill_02.png", 224, 160, 0.85, noise)

	# High Mountain Peaks (3 variations)
	_gen_high_peak("terrain/mountains/mtn_high_peak_01.png", 256, 256, 1.0, 0, noise)
	_gen_high_peak("terrain/mountains/mtn_high_peak_02.png", 208, 208, 0.8, 1, noise)
	_gen_high_peak("terrain/mountains/mtn_high_peak_03.png", 256, 224, 0.95, 2, noise)

	# Mountain Ridge Connectors (Horizontal, Diagonal NW, Diagonal NE)
	_gen_ridge_connector_h("terrain/mountains/mtn_ridge_connector_h.png", 384, 192, noise)
	_gen_ridge_connector_diag("terrain/mountains/mtn_ridge_connector_diag_nw.png", 320, 224, true, noise)
	_gen_ridge_connector_diag("terrain/mountains/mtn_ridge_connector_diag_ne.png", 320, 224, false, noise)

	# Mountain Pass Chokepoint
	_gen_pass_chokepoint("terrain/mountains/mtn_pass_corridor.png", 288, 192, noise)

	# Cliff Edge Accents
	_gen_cliff_accent("terrain/mountains/mtn_cliff_edge_01.png", 160, 128, noise)
	_gen_cliff_accent("terrain/mountains/mtn_cliff_edge_02.png", 144, 112, noise)

	# Valley Mist
	_gen_valley_mist("terrain/mountains/mtn_valley_mist.png", 256, 96)

func _gen_foothill(path: String, w: int, h: int, scale_fac: float, var_seed: int, noise: FastNoiseLite) -> void:
	var img := create_blank(w, h)
	var cx: float = float(w) * (0.46 + float(var_seed) * 0.05)
	var cy: float = float(h) * 0.42
	var base_y: float = float(h) * 0.88
	var rx_rad: float = float(w) * 0.42 * scale_fac

	for y in range(int(cy), int(base_y)):
		var prog: float = float(y - cy) / float(base_y - cy)
		var curve: float = pow(prog, 0.65)
		var lx: float = cx - rx_rad * curve + noise.get_noise_2d(float(y) * 2.0, float(var_seed) * 10.0) * 8.0
		var rx: float = cx + rx_rad * curve + noise.get_noise_2d(float(y) * 2.0, float(var_seed) * 30.0) * 8.0
		var ridge_x: float = cx + (prog - 0.5) * 12.0

		for x in range(int(lx), int(rx)):
			var n: float = noise.get_noise_2d(float(x) * 1.2, float(y) * 1.2)
			var c: Color
			if x < ridge_x:
				var t: float = float(x - lx) / maxi(1.0, ridge_x - lx)
				c = Color(0.66, 0.60, 0.46, 0.94).lerp(Color(0.74, 0.68, 0.54, 0.96), t)
				if n > 0.15:
					c = c.lerp(Color(0.42, 0.52, 0.36, 0.92), 0.35)
			else:
				var t2: float = float(x - ridge_x) / maxi(1.0, rx - ridge_x)
				c = Color(0.38, 0.34, 0.30, 0.95).lerp(Color(0.50, 0.44, 0.38, 0.92), 1.0 - t2)
				if n > 0.2:
					c = c.lerp(Color(0.30, 0.38, 0.26, 0.90), 0.30)
			if prog > 0.70:
				c.a *= (1.0 - (prog - 0.70) / 0.30 * 0.85)
			blend_px(img, x, y, c)

	for x in range(0, w, 16):
		draw_soft_circle(img, float(x), base_y - 6.0, 18.0 * scale_fac, Color(0.88, 0.85, 0.77, 0.35), 0.75)
	save_asset(img, path)

func _gen_rough_hill(path: String, w: int, h: int, scale_fac: float, noise: FastNoiseLite) -> void:
	var img := create_blank(w, h)
	var cx: float = float(w) * 0.50
	var cy: float = float(h) * 0.30
	var base_y: float = float(h) * 0.90
	var rw: float = float(w) * 0.45 * scale_fac

	for y in range(int(cy), int(base_y)):
		var prog: float = float(y - cy) / float(base_y - cy)
		var curve: float = pow(prog, 0.75)
		var lx: float = cx - rw * curve + noise.get_noise_2d(float(y), 15.0) * 14.0
		var rx: float = cx + rw * curve + noise.get_noise_2d(float(y), 45.0) * 14.0
		var ridge_x: float = cx + sin(prog * 5.0) * 16.0

		for x in range(int(lx), int(rx)):
			var n: float = noise.get_noise_2d(float(x) * 0.9, float(y) * 0.9)
			var c: Color
			if x < ridge_x:
				var t: float = float(x - lx) / maxi(1.0, ridge_x - lx)
				c = Color(0.62, 0.54, 0.42, 0.96).lerp(Color(0.74, 0.66, 0.52, 0.98), t)
				if fmod(abs(n * 6.0), 1.0) < 0.25:
					c = c.darkened(0.20)
			else:
				var t2: float = float(x - ridge_x) / maxi(1.0, rx - ridge_x)
				c = Color(0.24, 0.22, 0.22, 0.98).lerp(Color(0.42, 0.36, 0.32, 0.95), 1.0 - t2)
				if fmod(abs(n * 6.0), 1.0) < 0.25:
					c = c.darkened(0.22)
			if prog > 0.75:
				c.a *= (1.0 - (prog - 0.75) / 0.25 * 0.80)
			blend_px(img, x, y, c)

	for y in range(int(cy + 20), int(base_y - 10), 3):
		var ty: float = float(y - cy) / float(base_y - cy)
		var tx: float = cx + sin(ty * 4.0) * 14.0 - 4.0
		draw_soft_circle(img, tx, float(y), 3.5, Color(0.58, 0.50, 0.38, 0.75), 0.4)

	for x in range(0, w, 20):
		draw_soft_circle(img, float(x), base_y - 8.0, 22.0, Color(0.88, 0.84, 0.76, 0.40), 0.7)
	save_asset(img, path)

func _gen_high_peak(path: String, w: int, h: int, scale_fac: float, style: int, noise: FastNoiseLite) -> void:
	var img := create_blank(w, h)
	var peak_x: float = float(w) * (0.47 + float(style) * 0.04)
	var peak_y: float = float(h) * 0.14
	var base_y: float = float(h) * 0.92
	var lx_base: float = float(w) * 0.08
	var rx_base: float = float(w) * 0.92

	for y in range(int(peak_y), int(base_y)):
		var prog: float = float(y - peak_y) / float(base_y - peak_y)
		var curve: float = pow(prog, 0.88)
		var ridge_x: float = peak_x + sin(prog * 4.0) * (16.0 * scale_fac)
		var lx: float = lerpf(peak_x, lx_base, curve) - noise.get_noise_2d(float(y), 10.0) * 12.0
		var rx: float = lerpf(peak_x, rx_base, curve) + noise.get_noise_2d(float(y), 60.0) * 12.0

		for x in range(int(lx), int(rx)):
			var n: float = noise.get_noise_2d(float(x) * 0.8, float(y) * 0.8)
			var c: Color
			if x < ridge_x:
				var t: float = float(x - lx) / maxi(1.0, ridge_x - lx)
				c = Color(0.62, 0.54, 0.40, 0.96).lerp(Color(0.78, 0.70, 0.54, 0.98), t)
				if fmod(abs(n * 8.0), 1.0) < 0.28:
					c = c.darkened(0.24)
			else:
				var t2: float = float(x - ridge_x) / maxi(1.0, rx - ridge_x)
				c = Color(0.16, 0.15, 0.16, 0.98).lerp(Color(0.32, 0.28, 0.26, 0.95), 1.0 - t2)
				if fmod(abs(n * 7.0), 1.0) < 0.32:
					c = c.darkened(0.28)
			if prog > 0.78:
				c.a *= (1.0 - (prog - 0.78) / 0.22 * 0.85)
			blend_px(img, x, y, c)

	var prev_pt := Vector2(peak_x, peak_y)
	for y in range(int(peak_y), int(base_y * 0.82), 3):
		var p_y: float = float(y - peak_y) / float(base_y - peak_y)
		var rx2: float = peak_x + sin(p_y * 4.0) * (16.0 * scale_fac)
		var cur_pt := Vector2(rx2, float(y))
		draw_brush_stroke(img, prev_pt, cur_pt, 2.8 * scale_fac, Color(0.12, 0.10, 0.10, 0.98), noise)
		prev_pt = cur_pt

	for x in range(0, w, 18):
		draw_soft_circle(img, float(x), base_y - 10.0, 28.0 * scale_fac, Color(0.88, 0.84, 0.76, 0.45), 0.75)
	save_asset(img, path)

func _gen_ridge_connector_h(path: String, w: int, h: int, noise: FastNoiseLite) -> void:
	var img := create_blank(w, h)
	var base_y: float = float(h) * 0.88
	var peaks := [w * 0.22, w * 0.52, w * 0.80]

	for i in range(peaks.size()):
		var px: float = peaks[i]
		var py: float = float(h) * (0.16 + (i % 2) * 0.08)
		for y in range(int(py), int(base_y)):
			var ty: float = float(y - py) / float(base_y - py)
			var half_w: float = lerpf(2.0, float(w) * 0.28, pow(ty, 0.82))
			var lx: float = px - half_w - noise.get_noise_2d(float(y), float(i) * 10.0) * 8.0
			var rx: float = px + half_w + noise.get_noise_2d(float(y), float(i) * 30.0) * 8.0
			var ridge_x: float = px + sin(ty * 3.5) * 8.0
			for x in range(int(lx), int(rx)):
				var n: float = noise.get_noise_2d(float(x) * 0.8, float(y) * 0.8)
				var c: Color
				if x < ridge_x:
					c = Color(0.64, 0.56, 0.42, 0.96).lerp(Color(0.76, 0.68, 0.54, 0.98), float(x - lx) / maxi(1.0, ridge_x - lx))
					if fmod(abs(n * 6.0), 1.0) < 0.24: c = c.darkened(0.20)
				else:
					c = Color(0.18, 0.17, 0.18, 0.98).lerp(Color(0.34, 0.30, 0.28, 0.95), 1.0 - float(x - ridge_x) / maxi(1.0, rx - ridge_x))
				if ty > 0.74: c.a *= (1.0 - (ty - 0.74) / 0.26 * 0.85)
				blend_px(img, x, y, c)

		# Sharp ink ridge crest for each peak
		var prev := Vector2(px, py)
		for y in range(int(py), int(base_y * 0.75), 4):
			var cur := Vector2(px + sin(float(y - py) / float(base_y - py) * 3.5) * 8.0, float(y))
			draw_brush_stroke(img, prev, cur, 2.2, Color(0.12, 0.10, 0.10, 0.95), noise)
			prev = cur

	for x in range(0, w, 20):
		draw_soft_circle(img, float(x), base_y - 8.0, 26.0, Color(0.88, 0.84, 0.76, 0.40), 0.75)
	save_asset(img, path)

func _gen_ridge_connector_diag(path: String, w: int, h: int, is_nw: bool, noise: FastNoiseLite) -> void:
	var img := create_blank(w, h)
	var p1 := Vector2(w * 0.15, h * 0.80) if is_nw else Vector2(w * 0.85, h * 0.80)
	var p2 := Vector2(w * 0.85, h * 0.20) if is_nw else Vector2(w * 0.15, h * 0.20)
	var base_y: float = float(h) * 0.90

	var steps := 28
	for i in range(steps):
		var t: float = float(i) / float(steps)
		var cp: Vector2 = p1.lerp(p2, t)
		var r_size: float = 34.0 + noise.get_noise_1d(float(i) * 12.0) * 10.0
		# Lit NW
		draw_soft_circle(img, cp.x - 7.0, cp.y - 4.0, r_size, Color(0.72, 0.65, 0.50, 0.94), 0.45)
		# Shaded SE
		draw_soft_circle(img, cp.x + 7.0, cp.y + 4.0, r_size * 0.95, Color(0.24, 0.22, 0.22, 0.96), 0.45)

	# Diagonal ink crest
	draw_brush_stroke(img, p1, p2, 2.6, Color(0.14, 0.12, 0.12, 0.95), noise)

	for x in range(0, w, 20):
		draw_soft_circle(img, float(x), base_y - 6.0, 24.0, Color(0.88, 0.84, 0.76, 0.35), 0.75)
	save_asset(img, path)

func _gen_pass_chokepoint(path: String, w: int, h: int, noise: FastNoiseLite) -> void:
	var img := create_blank(w, h)
	var base_y: float = float(h) * 0.88
	for y in range(int(h * 0.15), int(base_y)):
		var prog: float = float(y - h * 0.15) / float(base_y - h * 0.15)
		var lx: float = 10.0
		var rx: float = lerpf(w * 0.35, w * 0.44, prog) + noise.get_noise_2d(float(y), 10.0) * 10.0
		for x in range(int(lx), int(rx)):
			var c := Color(0.68, 0.60, 0.46, 0.96).lerp(Color(0.25, 0.23, 0.22, 0.98), float(x - lx) / maxi(1.0, rx - lx))
			if prog > 0.8: c.a *= (1.0 - (prog - 0.8) / 0.2 * 0.8)
			blend_px(img, x, y, c)
	for y in range(int(h * 0.15), int(base_y)):
		var prog2: float = float(y - h * 0.15) / float(base_y - h * 0.15)
		var lx2: float = lerpf(w * 0.65, w * 0.56, prog2) + noise.get_noise_2d(float(y), 50.0) * 10.0
		var rx2: float = float(w) - 10.0
		for x in range(int(lx2), int(rx2)):
			var c2 := Color(0.22, 0.20, 0.22, 0.98).lerp(Color(0.38, 0.34, 0.30, 0.95), float(x - lx2) / maxi(1.0, rx2 - lx2))
			if prog2 > 0.8: c2.a *= (1.0 - (prog2 - 0.8) / 0.2 * 0.8)
			blend_px(img, x, y, c2)
	for y in range(int(h * 0.25), int(base_y)):
		var cx: float = float(w) * 0.50 + sin(float(y) * 0.08) * 8.0
		draw_soft_circle(img, cx, float(y), 7.0, Color(0.68, 0.58, 0.42, 0.85), 0.4)
	save_asset(img, path)

func _gen_cliff_accent(path: String, w: int, h: int, noise: FastNoiseLite) -> void:
	var img := create_blank(w, h)
	var top_y: float = float(h) * 0.20
	var bot_y: float = float(h) * 0.85
	for y in range(int(top_y), int(bot_y)):
		var prog: float = float(y - top_y) / float(bot_y - top_y)
		var lx: float = float(w) * 0.20 - noise.get_noise_2d(float(y) * 2.0, 10.0) * 12.0
		var rx: float = float(w) * 0.80 + noise.get_noise_2d(float(y) * 2.0, 30.0) * 12.0
		for x in range(int(lx), int(rx)):
			var n: float = noise.get_noise_2d(float(x) * 1.5, float(y) * 1.5)
			var c := Color(0.55, 0.48, 0.38, 0.96) if x < (lx + rx) * 0.5 else Color(0.22, 0.20, 0.20, 0.98)
			if fmod(abs(n * 6.0), 1.0) < 0.3: c = c.darkened(0.25)
			if prog > 0.75: c.a *= (1.0 - (prog - 0.75) / 0.25 * 0.85)
			blend_px(img, x, y, c)
	save_asset(img, path)

func _gen_valley_mist(path: String, w: int, h: int) -> void:
	var img := create_blank(w, h)
	for i in range(16):
		var cx: float = float(w) * (float(i) / 16.0) + 12.0
		var cy: float = float(h) * 0.50 + sin(float(i) * 1.2) * 10.0
		draw_soft_circle(img, cx, cy, 28.0, Color(0.90, 0.86, 0.78, 0.35), 0.8)
	save_asset(img, path)

# ------------------------------------------------------------------
# 2. FOREST & WOODLAND VARIETY KIT (ORGANIC MULTI-TREE CROWNS)
# ------------------------------------------------------------------
func build_forest_variety_kit() -> void:
	print("--- Building Forest Variety Kit ---")
	_gen_forest_dense_core("terrain/forests/forest_dense_core_01.png", 224, 160, true, 22)
	_gen_forest_dense_core("terrain/forests/forest_dense_core_02.png", 224, 160, false, 20)
	_gen_forest_edge_light("terrain/forests/forest_edge_light_01.png", 192, 128, 12)
	_gen_forest_edge_light("terrain/forests/forest_edge_light_02.png", 192, 128, 10)
	_gen_forest_sparse_copse("terrain/forests/forest_sparse_copse_01.png", 160, 112, 5)
	_gen_forest_sparse_copse("terrain/forests/forest_sparse_copse_02.png", 144, 96, 4)
	_gen_bamboo_grove("terrain/forests/forest_bamboo_grove_01.png", 160, 128)
	_gen_forest_shadow_underlay("terrain/forests/forest_shadow_underlay.png", 224, 144)

func _gen_forest_dense_core(path: String, w: int, h: int, is_pine: bool, tree_count: int) -> void:
	var img := create_blank(w, h)
	var rng := RandomNumberGenerator.new()
	rng.seed = 404 if is_pine else 505

	# 1. Ground shadow
	draw_soft_circle(img, float(w) * 0.5, float(h) * 0.65, float(w) * 0.42, Color(0.08, 0.12, 0.08, 0.45), 0.7)

	# 2. Back-to-front Y-sorted trees
	var trees: Array[Vector2] = []
	for i in range(tree_count):
		# Leave center slightly lower density so units on top stay clearly framed
		var tx: float = rng.randf_range(float(w) * 0.12, float(w) * 0.88)
		var ty: float = rng.randf_range(float(h) * 0.22, float(h) * 0.82)
		trees.append(Vector2(tx, ty))
	trees.sort_custom(func(a, b): return a.y < b.y)

	var col_deep := Color(0.14, 0.24, 0.14, 0.98) if is_pine else Color(0.20, 0.32, 0.16, 0.98)
	var col_mid := Color(0.22, 0.36, 0.20, 0.98) if is_pine else Color(0.30, 0.44, 0.22, 0.98)
	var col_high := Color(0.34, 0.50, 0.28, 0.98) if is_pine else Color(0.42, 0.58, 0.30, 0.98)

	for pt in trees:
		var r: float = rng.randf_range(11.0, 16.0)
		# Trunk
		draw_brush_stroke(img, pt + Vector2(0, r * 0.5), pt + Vector2(0, r * 0.85), 2.4, Color(0.26, 0.18, 0.12, 0.92), null)
		# Crisp layered crown
		draw_soft_circle(img, pt.x, pt.y, r, col_deep, 0.35)
		draw_soft_circle(img, pt.x - 2.0, pt.y - 2.0, r * 0.75, col_mid, 0.42)
		draw_soft_circle(img, pt.x - 4.0, pt.y - 4.0, r * 0.45, col_high, 0.50)

	save_asset(img, path)

func _gen_forest_edge_light(path: String, w: int, h: int, tree_count: int) -> void:
	var img := create_blank(w, h)
	var rng := RandomNumberGenerator.new()
	rng.seed = 606

	draw_soft_circle(img, float(w) * 0.5, float(h) * 0.65, float(w) * 0.38, Color(0.10, 0.14, 0.08, 0.30), 0.75)

	var trees: Array[Vector2] = []
	for i in range(tree_count):
		trees.append(Vector2(rng.randf_range(float(w) * 0.18, float(w) * 0.82), rng.randf_range(float(h) * 0.30, float(h) * 0.80)))
	trees.sort_custom(func(a, b): return a.y < b.y)

	for pt in trees:
		var r: float = rng.randf_range(12.0, 17.0)
		draw_brush_stroke(img, pt + Vector2(0, r * 0.5), pt + Vector2(0, r * 0.95), 2.5, Color(0.32, 0.22, 0.14, 0.92), null)
		draw_soft_circle(img, pt.x, pt.y, r, Color(0.18, 0.32, 0.18, 0.92), 0.35)
		draw_soft_circle(img, pt.x - 2.0, pt.y - 2.0, r * 0.75, Color(0.28, 0.46, 0.26, 0.94), 0.42)
		draw_soft_circle(img, pt.x - 4.0, pt.y - 4.0, r * 0.45, Color(0.38, 0.58, 0.34, 0.94), 0.50)

	save_asset(img, path)

func _gen_forest_sparse_copse(path: String, w: int, h: int, count: int) -> void:
	var img := create_blank(w, h)
	var rng := RandomNumberGenerator.new()
	rng.seed = 707
	for i in range(count):
		var tx: float = float(w) * (0.20 + 0.60 * float(i) / maxi(1.0, float(count - 1)))
		var ty: float = float(h) * (0.45 + (i % 2) * 0.18)
		var r: float = rng.randf_range(12.0, 16.0)
		# Trunk visible with ground clearance
		draw_brush_stroke(img, Vector2(tx, ty + r * 0.4), Vector2(tx, ty + r * 1.1), 2.4, Color(0.30, 0.20, 0.14, 0.95), null)
		draw_soft_circle(img, tx, ty, r, Color(0.18, 0.34, 0.18, 0.95), 0.35)
		draw_soft_circle(img, tx - 2.0, ty - 2.0, r * 0.75, Color(0.28, 0.48, 0.26, 0.95), 0.42)
		draw_soft_circle(img, tx - 4.0, ty - 4.0, r * 0.45, Color(0.40, 0.62, 0.36, 0.95), 0.50)
	save_asset(img, path)

func _gen_bamboo_grove(path: String, w: int, h: int) -> void:
	var img := create_blank(w, h)
	var rng := RandomNumberGenerator.new()
	rng.seed = 808
	for i in range(14):
		var bx: float = rng.randf_range(16.0, float(w) - 16.0)
		var by_top: float = rng.randf_range(14.0, 32.0)
		var by_bot: float = rng.randf_range(float(h) * 0.68, float(h) * 0.88)
		draw_brush_stroke(img, Vector2(bx, by_bot), Vector2(bx, by_top), 2.0, Color(0.38, 0.52, 0.24, 0.95), null)
		for j in range(4):
			var ly: float = lerpf(by_top, by_bot, float(j) / 4.0)
			draw_soft_circle(img, bx + (5.0 if j % 2 == 0 else -5.0), ly, 7.0, Color(0.48, 0.66, 0.28, 0.92), 0.45)
	save_asset(img, path)

func _gen_forest_shadow_underlay(path: String, w: int, h: int) -> void:
	var img := create_blank(w, h)
	draw_soft_circle(img, float(w) * 0.5, float(h) * 0.5, float(w) * 0.45, Color(0.10, 0.14, 0.08, 0.40), 0.75)
	save_asset(img, path)

# ------------------------------------------------------------------
# 3. BASE TERRAIN READABILITY LAYER
# ------------------------------------------------------------------
func build_base_terrain_kit() -> void:
	print("--- Building Base Terrain Kit ---")
	var noise := FastNoiseLite.new()
	noise.seed = 3033
	noise.frequency = 0.06

	_gen_parchment_seamless("terrain/plains/parchment_base_seamless.png", 512, 512, noise)
	_gen_plain_patch("terrain/plains/terrain_open_plain_patch.png", 256, 256, Color(0.78, 0.74, 0.62, 0.65), noise)
	_gen_plain_patch("terrain/plains/terrain_dry_earth_patch.png", 256, 256, Color(0.72, 0.64, 0.48, 0.70), noise)
	_gen_grassy_terrace("terrain/plains/terrain_grassy_terrace.png", 256, 192, noise)
	_gen_road_adjacent("terrain/plains/terrain_road_adjacent.png", 192, 96)
	_gen_marsh_reeds("terrain/marsh/terrain_marsh_reeds.png", 192, 128)

func _gen_parchment_seamless(path: String, w: int, h: int, noise: FastNoiseLite) -> void:
	var img := create_blank(w, h)
	var col_base := Color(0.88, 0.85, 0.76, 1.0)
	var col_grain := Color(0.82, 0.78, 0.68, 1.0)
	for y in range(h):
		for x in range(w):
			var n: float = noise.get_noise_2d(float(x), float(y))
			var c: Color = col_base.lerp(col_grain, (n + 1.0) * 0.35)
			img.set_pixel(x, y, c)
	save_asset(img, path)

func _gen_plain_patch(path: String, w: int, h: int, tint: Color, noise: FastNoiseLite) -> void:
	var img := create_blank(w, h)
	var cx: float = float(w) * 0.5
	var cy: float = float(h) * 0.5
	draw_soft_circle(img, cx, cy, float(w) * 0.44, tint, 0.65)
	save_asset(img, path)

func _gen_grassy_terrace(path: String, w: int, h: int, noise: FastNoiseLite) -> void:
	var img := create_blank(w, h)
	for tier in range(4):
		var ty: float = float(h) * (0.25 + float(tier) * 0.18)
		for x in range(int(w * 0.15), int(w * 0.85)):
			var dy: float = ty + sin(float(x) * 0.05) * 6.0
			draw_soft_circle(img, float(x), dy, 4.0, Color(0.55, 0.62, 0.44, 0.75), 0.4)
			blend_px(img, x, int(dy + 2), Color(0.42, 0.36, 0.26, 0.85))
	save_asset(img, path)

func _gen_road_adjacent(path: String, w: int, h: int) -> void:
	var img := create_blank(w, h)
	draw_soft_circle(img, float(w) * 0.5, float(h) * 0.5, float(w) * 0.42, Color(0.66, 0.58, 0.44, 0.50), 0.7)
	save_asset(img, path)

func _gen_marsh_reeds(path: String, w: int, h: int) -> void:
	var img := create_blank(w, h)
	draw_soft_circle(img, float(w) * 0.45, float(h) * 0.55, 42.0, Color(0.24, 0.46, 0.44, 0.60), 0.5)
	draw_soft_circle(img, float(w) * 0.62, float(h) * 0.48, 32.0, Color(0.20, 0.42, 0.40, 0.60), 0.5)
	for i in range(12):
		var rx: float = float(w) * (0.25 + float(i) * 0.05)
		var ry: float = float(h) * 0.65
		draw_brush_stroke(img, Vector2(rx, ry), Vector2(rx - 2.0, ry - 18.0), 1.8, Color(0.38, 0.52, 0.28, 0.95))
		draw_soft_circle(img, rx - 2.0, ry - 20.0, 2.0, Color(0.48, 0.38, 0.24, 0.95), 0.2)
	save_asset(img, path)

# ------------------------------------------------------------------
# 4. ROAD & RIVER KIT
# ------------------------------------------------------------------
func build_road_and_river_kit() -> void:
	print("--- Building Road and River Kit ---")
	_gen_road_straight("terrain/roads/road_imperial_straight.png", 256, 64)
	_gen_road_bend("terrain/roads/road_imperial_bend_60.png", 192, 128)
	_gen_road_junction("terrain/roads/road_imperial_junction_3way.png", 192, 192)
	_gen_road_trail("terrain/roads/road_branch_trail.png", 224, 48)

	_gen_river_straight("terrain/rivers/river_channel_straight.png", 256, 96)
	_gen_river_bend("terrain/rivers/river_channel_bend.png", 224, 160)
	_gen_river_tributary("terrain/rivers/river_tributary_narrow.png", 192, 80)
	_gen_timber_bridge("terrain/rivers/bridge_timber_pier.png", 128, 96)

func _gen_road_straight(path: String, w: int, h: int) -> void:
	var img := create_blank(w, h)
	var cy: float = float(h) * 0.5
	for x in range(w):
		draw_soft_circle(img, float(x), cy, 14.0, Color(0.70, 0.60, 0.44, 0.85), 0.5)
		draw_soft_circle(img, float(x), cy, 6.0, Color(0.58, 0.48, 0.34, 0.92), 0.4)
	save_asset(img, path)

func _gen_road_bend(path: String, w: int, h: int) -> void:
	var img := create_blank(w, h)
	for i in range(60):
		var t: float = float(i) / 60.0
		var rad: float = t * (PI * 0.4)
		var x: float = cos(rad) * float(w) * 0.75
		var y: float = sin(rad) * float(h) * 0.75
		draw_soft_circle(img, x, y, 14.0, Color(0.70, 0.60, 0.44, 0.85), 0.5)
	save_asset(img, path)

func _gen_road_junction(path: String, w: int, h: int) -> void:
	var img := create_blank(w, h)
	var cx: float = float(w) * 0.5
	var cy: float = float(h) * 0.5
	for b in range(3):
		var ang: float = float(b) * TAU / 3.0
		for step in range(30):
			var r: float = float(step) * 2.8
			var x: float = cx + cos(ang) * r
			var y: float = cy + sin(ang) * r
			draw_soft_circle(img, x, y, 12.0, Color(0.70, 0.60, 0.44, 0.85), 0.5)
	save_asset(img, path)

func _gen_road_trail(path: String, w: int, h: int) -> void:
	var img := create_blank(w, h)
	var cy: float = float(h) * 0.5
	for x in range(w):
		var y: float = cy + sin(float(x) * 0.08) * 4.0
		draw_soft_circle(img, float(x), y, 5.5, Color(0.64, 0.54, 0.40, 0.80), 0.4)
	save_asset(img, path)

func _gen_river_straight(path: String, w: int, h: int) -> void:
	var img := create_blank(w, h)
	var cy: float = float(h) * 0.5
	for x in range(w):
		draw_soft_circle(img, float(x), cy, 28.0, Color(0.74, 0.68, 0.54, 0.80), 0.4)
		draw_soft_circle(img, float(x), cy, 18.0, Color(0.24, 0.52, 0.58, 0.95), 0.4)
		draw_soft_circle(img, float(x), cy, 8.0, Color(0.18, 0.42, 0.50, 0.98), 0.3)
	save_asset(img, path)

func _gen_river_bend(path: String, w: int, h: int) -> void:
	var img := create_blank(w, h)
	for i in range(80):
		var t: float = float(i) / 80.0
		var rad: float = t * (PI * 0.5)
		var x: float = cos(rad) * float(w) * 0.70
		var y: float = sin(rad) * float(h) * 0.70
		draw_soft_circle(img, x, y, 28.0, Color(0.74, 0.68, 0.54, 0.80), 0.4)
		draw_soft_circle(img, x, y, 18.0, Color(0.24, 0.52, 0.58, 0.95), 0.4)
		draw_soft_circle(img, x, y, 8.0, Color(0.18, 0.42, 0.50, 0.98), 0.3)
	save_asset(img, path)

func _gen_river_tributary(path: String, w: int, h: int) -> void:
	var img := create_blank(w, h)
	var cy: float = float(h) * 0.5
	for x in range(w):
		var y: float = cy + sin(float(x) * 0.06) * 6.0
		draw_soft_circle(img, float(x), y, 12.0, Color(0.72, 0.66, 0.52, 0.75), 0.4)
		draw_soft_circle(img, float(x), y, 7.0, Color(0.26, 0.50, 0.54, 0.92), 0.3)
	save_asset(img, path)

func _gen_timber_bridge(path: String, w: int, h: int) -> void:
	var img := create_blank(w, h)
	var cx: float = float(w) * 0.5
	var cy: float = float(h) * 0.5
	draw_soft_circle(img, cx - 38.0, cy, 14.0, Color(0.48, 0.45, 0.42, 0.95), 0.3)
	draw_soft_circle(img, cx + 38.0, cy, 14.0, Color(0.48, 0.45, 0.42, 0.95), 0.3)
	for x in range(int(cx - 36), int(cx + 36)):
		for y in range(int(cy - 12), int(cy + 12)):
			var c := Color(0.48, 0.34, 0.22, 0.98)
			if (x % 6) == 0: c = c.darkened(0.25)
			blend_px(img, x, y, c)
	for x in range(int(cx - 36), int(cx + 36), 8):
		draw_soft_circle(img, float(x), cy - 14.0, 2.2, Color(0.32, 0.22, 0.14, 0.98), 0.2)
		draw_soft_circle(img, float(x), cy + 14.0, 2.2, Color(0.32, 0.22, 0.14, 0.98), 0.2)
	save_asset(img, path)

# ------------------------------------------------------------------
# 5. SETTLEMENTS & OUTPOSTS KIT
# ------------------------------------------------------------------
func build_settlement_kit() -> void:
	print("--- Building Settlement Kit ---")
	_gen_rural_village("settlements/village/settlement_rural_village.png", 192, 144)
	_gen_farm_hamlet("settlements/village/settlement_farm_hamlet.png", 160, 112)
	_gen_grain_depot("settlements/outpost/settlement_grain_depot.png", 160, 128)
	_gen_watchpost("settlements/outpost/settlement_watchpost.png", 128, 128)
	_gen_road_shrine("settlements/outpost/settlement_road_shrine.png", 96, 96)

func _gen_rural_village(path: String, w: int, h: int) -> void:
	var img := create_blank(w, h)
	draw_soft_circle(img, float(w) * 0.5, float(h) * 0.58, 56.0, Color(0.66, 0.58, 0.44, 0.85), 0.6)
	var b_coords := [Vector2(0.32, 0.48), Vector2(0.68, 0.48), Vector2(0.50, 0.72)]
	for bc in b_coords:
		var bx: float = float(w) * bc.x
		var by: float = float(h) * bc.y
		for y in range(int(by - 8), int(by + 12)):
			for x in range(int(bx - 16), int(bx + 16)):
				blend_px(img, x, y, Color(0.72, 0.64, 0.50, 0.98))
		for y in range(int(by), int(by + 12)):
			for x in range(int(bx - 3), int(bx + 3)):
				blend_px(img, x, y, Color(0.28, 0.20, 0.14, 0.98))
		for y in range(int(by - 24), int(by - 8)):
			var prog: float = float(y - (by - 24)) / 16.0
			var hw: float = lerpf(3.0, 20.0, prog)
			for x in range(int(bx - hw), int(bx + hw)):
				var c := Color(0.58, 0.46, 0.28, 0.98)
				if (x % 4 == 0): c = c.darkened(0.15)
				blend_px(img, x, y, c)
	save_asset(img, path)

func _gen_farm_hamlet(path: String, w: int, h: int) -> void:
	var img := create_blank(w, h)
	draw_soft_circle(img, float(w) * 0.5, float(h) * 0.55, 46.0, Color(0.66, 0.58, 0.44, 0.75), 0.6)
	for i in range(2):
		var bx: float = float(w) * (0.35 + float(i) * 0.32)
		var by: float = float(h) * 0.54
		for y in range(int(by - 8), int(by + 10)):
			for x in range(int(bx - 14), int(bx + 14)):
				blend_px(img, x, y, Color(0.70, 0.62, 0.48, 0.98))
		for y in range(int(by + 1), int(by + 10)):
			for x in range(int(bx - 3), int(bx + 3)):
				blend_px(img, x, y, Color(0.26, 0.18, 0.12, 0.98))
		for y in range(int(by - 22), int(by - 8)):
			var prog: float = float(y - (by - 22)) / 14.0
			var hw: float = lerpf(3.0, 18.0, prog)
			for x in range(int(bx - hw), int(bx + hw)):
				var c := Color(0.56, 0.44, 0.26, 0.98)
				if (x % 4 == 0): c = c.darkened(0.15)
				blend_px(img, x, y, c)
	save_asset(img, path)

func _gen_grain_depot(path: String, w: int, h: int) -> void:
	var img := create_blank(w, h)
	draw_soft_circle(img, float(w) * 0.60, float(h) * 0.60, 48.0, Color(0.60, 0.52, 0.40, 0.85), 0.6)
	for s in range(3):
		var sx: float = float(w) * (0.30 + float(s) * 0.20)
		var sy: float = float(h) * 0.50
		draw_soft_circle(img, sx, sy, 14.0, Color(0.52, 0.42, 0.30, 0.98), 0.2)
		draw_soft_circle(img, sx, sy - 8.0, 12.0, Color(0.62, 0.50, 0.32, 0.98), 0.3)
	save_asset(img, path)

func _gen_watchpost(path: String, w: int, h: int) -> void:
	var img := create_blank(w, h)
	var cx: float = float(w) * 0.5
	var cy: float = float(h) * 0.55
	draw_soft_circle(img, cx, cy + 18.0, 24.0, Color(0.48, 0.36, 0.22, 0.85), 0.3)
	draw_brush_stroke(img, Vector2(cx - 10, cy + 18), Vector2(cx - 6, cy - 24), 3.0, Color(0.36, 0.24, 0.16, 0.98))
	draw_brush_stroke(img, Vector2(cx + 10, cy + 18), Vector2(cx + 6, cy - 24), 3.0, Color(0.36, 0.24, 0.16, 0.98))
	for y in range(int(cy - 32), int(cy - 22)):
		for x in range(int(cx - 14), int(cx + 14)):
			blend_px(img, x, y, Color(0.42, 0.30, 0.18, 0.98))
	save_asset(img, path)

func _gen_road_shrine(path: String, w: int, h: int) -> void:
	var img := create_blank(w, h)
	var cx: float = float(w) * 0.5
	var cy: float = float(h) * 0.55
	draw_soft_circle(img, cx, cy + 6.0, 14.0, Color(0.52, 0.48, 0.44, 0.95), 0.3)
	for y in range(int(cy - 12), int(cy + 4)):
		for x in range(int(cx - 4), int(cx + 4)):
			blend_px(img, x, y, Color(0.32, 0.30, 0.28, 0.98))
	for y in range(int(cy - 20), int(cy - 12)):
		var hw: float = float(cy - 12 - y) * 1.5 + 8.0
		for x in range(int(cx - hw), int(cx + hw)):
			blend_px(img, x, y, Color(0.68, 0.26, 0.20, 0.98))
	save_asset(img, path)

# ------------------------------------------------------------------
# 6. STRONGHOLD KIT
# ------------------------------------------------------------------
func build_stronghold_kit() -> void:
	print("--- Building Stronghold Kit ---")
	_gen_hulao_bastion("settlements/fortress/fortress_hulao_bastion.png", 320, 240)
	_gen_luoyang_citadel("settlements/capital/capital_luoyang_citadel.png", 512, 384)

func _gen_hulao_bastion(path: String, w: int, h: int) -> void:
	var img := create_blank(w, h)
	var cx: float = float(w) * 0.5
	var cy: float = float(h) * 0.58
	for y in range(int(cy - 30), int(cy + 40)):
		var hw: float = 78.0
		for x in range(int(cx - hw), int(cx + hw)):
			var c := Color(0.48, 0.44, 0.40, 0.98)
			if ((y / 8) % 2 == 0 and x % 16 == 0) or ((y / 8) % 2 == 1 and (x + 8) % 16 == 0):
				c = c.darkened(0.25)
			blend_px(img, x, y, c)
	draw_soft_circle(img, cx, cy + 24.0, 18.0, Color(0.12, 0.10, 0.10, 0.98), 0.2)
	for y in range(int(cy - 65), int(cy - 30)):
		for x in range(int(cx - 35), int(cx + 35)):
			blend_px(img, x, y, Color(0.42, 0.28, 0.18, 0.98))
	for y in range(int(cy - 82), int(cy - 65)):
		var hw: float = float(cy - 65 - y) * 2.2 + 38.0
		for x in range(int(cx - hw), int(cx + hw)):
			blend_px(img, x, y, Color(0.72, 0.24, 0.18, 0.98))
	save_asset(img, path)

func _gen_luoyang_citadel(path: String, w: int, h: int) -> void:
	var img := create_blank(w, h)
	var cx: float = float(w) * 0.5
	var cy: float = float(h) * 0.55
	draw_soft_circle(img, cx, cy, 175.0, Color(0.24, 0.50, 0.56, 0.85), 0.3)
	for y in range(int(cy - 75), int(cy + 65)):
		var hw: float = 135.0
		for x in range(int(cx - hw), int(cx + hw)):
			var c := Color(0.68, 0.26, 0.20, 0.98)
			if (y % 10 == 0) or (x % 20 == 0): c = c.darkened(0.20)
			blend_px(img, x, y, c)
	var corners := [Vector2(-135, -75), Vector2(135, -75), Vector2(-135, 65), Vector2(135, 65)]
	for cp in corners:
		var tx: float = cx + cp.x
		var ty: float = cy + cp.y
		draw_soft_circle(img, tx, ty, 24.0, Color(0.72, 0.28, 0.22, 0.98), 0.2)
		draw_soft_circle(img, tx, ty - 10.0, 18.0, Color(0.85, 0.72, 0.28, 0.98), 0.3)
	for y in range(int(cy - 50), int(cy - 10)):
		var hw: float = float(cy - 10 - y) * 1.5 + 45.0
		for x in range(int(cx - hw), int(cx + hw)):
			blend_px(img, x, y, Color(0.88, 0.74, 0.26, 0.98))
	save_asset(img, path)

# ------------------------------------------------------------------
# 7. READABILITY UI & TACTICAL FOUNDATIONS
# ------------------------------------------------------------------
func build_readability_ui_kit() -> void:
	print("--- Building Readability UI Kit ---")
	_gen_unit_plinth("ui/unit_plinth_ally.png", 96, 48, true)
	_gen_unit_plinth("ui/unit_plinth_enemy.png", 96, 48, false)
	_gen_hex_ring("ui/hex_hover_highlight.png", 64, 64)
	_gen_command_bar("ui/command_bar_lacquer.png", 640, 54)

func _gen_unit_plinth(path: String, w: int, h: int, is_ally: bool) -> void:
	var img := create_blank(w, h)
	var cx: float = float(w) * 0.5
	var cy: float = float(h) * 0.5
	draw_soft_circle(img, cx, cy + 6.0, 36.0, Color(0.06, 0.08, 0.10, 0.60), 0.6)
	var base_col := Color(0.10, 0.17, 0.26, 0.92) if is_ally else Color(0.28, 0.10, 0.10, 0.92)
	var border_col := Color(0.88, 0.76, 0.32, 0.98) if is_ally else Color(0.80, 0.45, 0.22, 0.98)
	for y in range(int(cy - 10), int(cy + 10)):
		for x in range(int(cx - 32), int(cx + 32)):
			blend_px(img, x, y, base_col)
	for x in range(int(cx - 32), int(cx + 32)):
		blend_px(img, x, int(cy - 10), border_col)
		blend_px(img, x, int(cy + 9), border_col)
	for y in range(int(cy - 10), int(cy + 10)):
		blend_px(img, int(cx - 32), y, border_col)
		blend_px(img, int(cx + 31), y, border_col)
	for dx in [-32, 28]:
		for dy in [-10, 6]:
			draw_soft_circle(img, cx + dx + 2.0, cy + dy + 2.0, 3.0, Color(1.0, 0.90, 0.40, 0.98), 0.2)
	save_asset(img, path)

func _gen_hex_ring(path: String, w: int, h: int) -> void:
	var img := create_blank(w, h)
	var cx: float = float(w) * 0.5
	var cy: float = float(h) * 0.5
	var r: float = 24.0
	for deg in range(360):
		var rad: float = deg_to_rad(float(deg))
		var x: float = cx + cos(rad) * r
		var y: float = cy + sin(rad) * r
		draw_soft_circle(img, x, y, 2.0, Color(0.96, 0.86, 0.42, 0.95), 0.4)
	save_asset(img, path)

func _gen_command_bar(path: String, w: int, h: int) -> void:
	var img := create_blank(w, h)
	for y in range(h):
		for x in range(w):
			var c := Color(0.07, 0.08, 0.10, 0.98)
			if y == 0 or y == h - 1: c = Color(0.78, 0.65, 0.32, 0.95)
			elif y == 1 or y == h - 2: c = Color(0.45, 0.38, 0.20, 0.85)
			blend_px(img, x, y, c)
	save_asset(img, path)
