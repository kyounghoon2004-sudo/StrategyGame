extends SceneTree

## organize_and_preview_v4.gd
## Organizes res://assets/visual_overhaul_v4/ into 5 clear category folders:
## - mountains/
## - forests/
## - terrain/
## - structures/
## - ui/
## And generates composite contact sheet previews in previews/

const ROOT: String = "res://assets/visual_overhaul_v4/"

func _init() -> void:
	print("--- Organizing V4 Assets & Generating Contact Sheets ---")
	
	_ensure_dirs()
	_organize_files()
	_generate_contact_sheets()
	_generate_html_browser()
	
	print("--- Completed V4 Asset Organization! ---")
	quit(0)

func _ensure_dirs() -> void:
	var dirs: Array[String] = ["mountains", "forests", "terrain", "structures", "ui", "previews"]
	for d in dirs:
		var dir_path: String = ROOT + d
		DirAccess.make_dir_recursive_absolute(dir_path)

func _organize_files() -> void:
	# Map of (old relative path -> new relative path)
	var renames: Dictionary = {
		# Mountains
		"terrain/mountains/mtn_foothill_01.png": "mountains/low_foothill_01.png",
		"terrain/mountains/mtn_foothill_02.png": "mountains/low_foothill_02.png",
		"terrain/mountains/mtn_foothill_03.png": "mountains/low_foothill_03.png",
		"terrain/mountains/mtn_rough_hill_01.png": "mountains/passable_rough_hill_01.png",
		"terrain/mountains/mtn_rough_hill_02.png": "mountains/passable_rough_hill_02.png",
		"terrain/mountains/mtn_high_peak_01.png": "mountains/high_peak_01.png",
		"terrain/mountains/mtn_high_peak_02.png": "mountains/high_peak_02.png",
		"terrain/mountains/mtn_high_peak_03.png": "mountains/high_peak_03.png",
		"terrain/mountains/mtn_ridge_connector_h.png": "mountains/ridge_connector_h.png",
		"terrain/mountains/mtn_ridge_connector_diag_nw.png": "mountains/ridge_connector_diag_nw.png",
		"terrain/mountains/mtn_ridge_connector_diag_ne.png": "mountains/ridge_connector_diag_ne.png",
		"terrain/mountains/mtn_pass_corridor.png": "mountains/pass_chokepoint_corridor.png",
		"terrain/mountains/mtn_cliff_edge_01.png": "mountains/cliff_accent_01.png",
		"terrain/mountains/mtn_cliff_edge_02.png": "mountains/cliff_accent_02.png",
		"terrain/mountains/mtn_valley_mist.png": "mountains/valley_mist.png",

		# Forests
		"terrain/forests/forest_dense_core_01.png": "forests/forest_dense_core_pine.png",
		"terrain/forests/forest_dense_core_02.png": "forests/forest_dense_core_cypress.png",
		"terrain/forests/forest_edge_light_01.png": "forests/forest_edge_light_01.png",
		"terrain/forests/forest_edge_light_02.png": "forests/forest_edge_light_02.png",
		"terrain/forests/forest_sparse_copse_01.png": "forests/forest_sparse_copse_01.png",
		"terrain/forests/forest_sparse_copse_02.png": "forests/forest_sparse_copse_02.png",
		"terrain/forests/forest_bamboo_grove_01.png": "forests/forest_bamboo_grove.png",
		"terrain/forests/forest_shadow_underlay.png": "forests/forest_shadow_underlay.png",

		# Terrain (Plains, Marshes, Roads, Rivers)
		"terrain/plains/parchment_base_seamless.png": "terrain/terrain_parchment_base.png",
		"terrain/plains/terrain_open_plain_patch.png": "terrain/terrain_open_plain_patch.png",
		"terrain/plains/terrain_dry_earth_patch.png": "terrain/terrain_dry_earth_patch.png",
		"terrain/plains/terrain_grassy_terrace.png": "terrain/terrain_grassy_terrace.png",
		"terrain/plains/terrain_road_adjacent.png": "terrain/terrain_road_adjacent.png",
		"terrain/marsh/terrain_marsh_reeds.png": "terrain/terrain_marsh_reeds.png",
		"terrain/roads/road_imperial_straight.png": "terrain/road_imperial_straight.png",
		"terrain/roads/road_imperial_bend_60.png": "terrain/road_imperial_bend_60.png",
		"terrain/roads/road_imperial_junction_3way.png": "terrain/road_imperial_junction_3way.png",
		"terrain/roads/road_branch_trail.png": "terrain/road_branch_trail.png",
		"terrain/rivers/river_channel_straight.png": "terrain/river_channel_straight.png",
		"terrain/rivers/river_channel_bend.png": "terrain/river_channel_bend.png",
		"terrain/rivers/river_tributary_narrow.png": "terrain/river_tributary_narrow.png",
		"terrain/rivers/bridge_timber_pier.png": "terrain/bridge_timber_pier.png",

		# Structures (Minor Settlements & Monumental Strongholds)
		"settlements/village/settlement_rural_village.png": "structures/village_rural_walled.png",
		"settlements/village/settlement_farm_hamlet.png": "structures/village_farm_hamlet.png",
		"settlements/outpost/settlement_grain_depot.png": "structures/outpost_grain_depot.png",
		"settlements/outpost/settlement_watchpost.png": "structures/outpost_watchpost_tower.png",
		"settlements/outpost/settlement_road_shrine.png": "structures/outpost_road_shrine.png",
		"settlements/fortress/fortress_hulao_bastion.png": "structures/stronghold_hulao_pass_bastion.png",
		"settlements/capital/capital_luoyang_citadel.png": "structures/stronghold_luoyang_grand_citadel.png",

		# UI
		"ui/unit_plinth_ally.png": "ui/ui_unit_plinth_ally.png",
		"ui/unit_plinth_enemy.png": "ui/ui_unit_plinth_enemy.png",
		"ui/hex_hover_highlight.png": "ui/ui_hex_hover_ring.png",
		"ui/command_bar_lacquer.png": "ui/ui_command_bar_lacquer.png",
	}

	for old_rel: String in renames:
		var new_rel: String = renames[old_rel]
		var old_p: String = ROOT + old_rel
		var new_p: String = ROOT + new_rel
		if FileAccess.file_exists(old_p):
			var img: Image = Image.load_from_file(old_p)
			if img != null:
				img.save_png(new_p)
				print("Organized: %s -> %s" % [old_rel, new_rel])

func _generate_contact_sheets() -> void:
	# 1. Mountains Contact Sheet (5 columns x 3 rows)
	var mtn_files := [
		"mountains/low_foothill_01.png", "mountains/low_foothill_02.png", "mountains/low_foothill_03.png",
		"mountains/passable_rough_hill_01.png", "mountains/passable_rough_hill_02.png",
		"mountains/high_peak_01.png", "mountains/high_peak_02.png", "mountains/high_peak_03.png",
		"mountains/ridge_connector_h.png", "mountains/ridge_connector_diag_nw.png", "mountains/ridge_connector_diag_ne.png",
		"mountains/pass_chokepoint_corridor.png", "mountains/cliff_accent_01.png", "mountains/cliff_accent_02.png",
		"mountains/valley_mist.png"
	]
	_make_contact_sheet("previews/preview_mountains.png", mtn_files, 5, 260, 200, "MODULAR MOUNTAINS KIT (15 ASSETS)")

	# 2. Forests Contact Sheet (4 columns x 2 rows)
	var forest_files := [
		"forests/forest_dense_core_pine.png", "forests/forest_dense_core_cypress.png",
		"forests/forest_edge_light_01.png", "forests/forest_edge_light_02.png",
		"forests/forest_sparse_copse_01.png", "forests/forest_sparse_copse_02.png",
		"forests/forest_bamboo_grove.png", "forests/forest_shadow_underlay.png"
	]
	_make_contact_sheet("previews/preview_forests.png", forest_files, 4, 250, 180, "FOREST VARIETY KIT (8 ASSETS)")

	# 3. Terrain Contact Sheet (5 columns x 3 rows)
	var terrain_files := [
		"terrain/terrain_parchment_base.png", "terrain/terrain_open_plain_patch.png", "terrain/terrain_dry_earth_patch.png",
		"terrain/terrain_grassy_terrace.png", "terrain/terrain_road_adjacent.png", "terrain/terrain_marsh_reeds.png",
		"terrain/road_imperial_straight.png", "terrain/road_imperial_bend_60.png", "terrain/road_imperial_junction_3way.png",
		"terrain/road_branch_trail.png", "terrain/river_channel_straight.png", "terrain/river_channel_bend.png",
		"terrain/river_tributary_narrow.png", "terrain/bridge_timber_pier.png"
	]
	_make_contact_sheet("previews/preview_terrain.png", terrain_files, 5, 240, 180, "BASE TERRAIN, ROADS & RIVERS (14 ASSETS)")

	# 4. Structures Contact Sheet (4 columns x 2 rows)
	var struct_files := [
		"structures/village_rural_walled.png", "structures/village_farm_hamlet.png",
		"structures/outpost_grain_depot.png", "structures/outpost_watchpost_tower.png",
		"structures/outpost_road_shrine.png", "structures/stronghold_hulao_pass_bastion.png",
		"structures/stronghold_luoyang_grand_citadel.png"
	]
	_make_contact_sheet("previews/preview_structures.png", struct_files, 4, 300, 240, "STRUCTURES & STRONGHOLDS (7 ASSETS)")

	# 5. UI Contact Sheet (4 columns x 1 row)
	var ui_files := [
		"ui/ui_unit_plinth_ally.png", "ui/ui_unit_plinth_enemy.png",
		"ui/ui_hex_hover_ring.png", "ui/ui_command_bar_lacquer.png"
	]
	_make_contact_sheet("previews/preview_ui.png", ui_files, 4, 240, 140, "TACTICAL READABILITY UI (4 ASSETS)")

func _make_contact_sheet(out_rel: String, files: Array, cols: int, cell_w: int, cell_h: int, title: String) -> void:
	var rows: int = int(ceil(float(files.size()) / float(cols)))
	var pad: int = 24
	var header_h: int = 48
	var sheet_w: int = cols * (cell_w + pad) + pad
	var sheet_h: int = rows * (cell_h + pad) + pad + header_h

	var sheet := Image.create(sheet_w, sheet_h, false, Image.FORMAT_RGBA8)
	# Warm parchment background for contact sheet
	sheet.fill(Color(0.88, 0.85, 0.77, 1.0))

	# Header bar
	for y in range(header_h):
		for x in range(sheet_w):
			sheet.set_pixel(x, y, Color(0.12, 0.14, 0.16, 0.98))
	for x in range(sheet_w):
		sheet.set_pixel(x, header_h - 1, Color(0.78, 0.65, 0.32, 0.98))

	for i in range(files.size()):
		var rel_p: String = files[i]
		var col_idx: int = i % cols
		var row_idx: int = i / cols
		var cx: int = pad + col_idx * (cell_w + pad)
		var cy: int = header_h + pad + row_idx * (cell_h + pad)

		# Cell backdrop card
		for y in range(cy, cy + cell_h):
			for x in range(cx, cx + cell_w):
				var is_border: bool = (x == cx or x == cx + cell_w - 1 or y == cy or y == cy + cell_h - 1)
				sheet.set_pixel(x, y, Color(0.72, 0.65, 0.52, 0.95) if is_border else Color(0.84, 0.80, 0.72, 0.75))

		# Stamp asset scaled inside cell
		var full_asset_path: String = ROOT + rel_p
		if FileAccess.file_exists(full_asset_path):
			var src := Image.load_from_file(full_asset_path)
			if src != null:
				var max_w: float = float(cell_w) - 16.0
				var max_h: float = float(cell_h) - 16.0
				var scale_fac: float = minf(max_w / float(src.get_width()), max_h / float(src.get_height()))
				if scale_fac > 1.0: scale_fac = 1.0
				var draw_w: int = int(float(src.get_width()) * scale_fac)
				var draw_h: int = int(float(src.get_height()) * scale_fac)
				src.resize(draw_w, draw_h, Image.INTERPOLATE_LANCZOS)
				
				var off_x: int = cx + (cell_w - draw_w) / 2
				var off_y: int = cy + (cell_h - draw_h) / 2
				
				for sy in range(draw_h):
					for sx in range(draw_w):
						var sc: Color = src.get_pixel(sx, sy)
						if sc.a > 0.001:
							var px: int = off_x + sx
							var py: int = off_y + sy
							if px >= 0 and px < sheet_w and py >= 0 and py < sheet_h:
								var dst: Color = sheet.get_pixel(px, py)
								var out_a: float = sc.a + dst.a * (1.0 - sc.a)
								var out_r: float = (sc.r * sc.a + dst.r * dst.a * (1.0 - sc.a)) / out_a
								var out_g: float = (sc.g * sc.a + dst.g * dst.a * (1.0 - sc.a)) / out_a
								var out_b: float = (sc.b * sc.a + dst.b * dst.a * (1.0 - sc.a)) / out_a
								sheet.set_pixel(px, py, Color(out_r, out_g, out_b, out_a))

	var save_path: String = ROOT + out_rel
	sheet.save_png(save_path)
	print("Saved Contact Sheet [%dx%d]: %s" % [sheet_w, sheet_h, out_rel])

func _generate_html_browser() -> void:
	var html: String = """<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>將軍 (General) - V4 Tactical Battlefield Asset Browser</title>
<style>
body { background: #18191c; color: #e2dac5; font-family: 'Segoe UI', system-ui, sans-serif; margin: 0; padding: 24px; }
h1 { color: #ebd173; font-size: 24px; border-bottom: 2px solid #c7a652; padding-bottom: 8px; margin-bottom: 24px; }
h2 { color: #c7a652; font-size: 18px; margin-top: 32px; border-left: 4px solid #c7a652; padding-left: 8px; }
.contact-sheet { max-width: 100%; border: 1px solid #3a3834; border-radius: 4px; box-shadow: 0 4px 16px rgba(0,0,0,0.5); margin-bottom: 20px; }
.grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(220px, 1fr)); gap: 16px; margin-bottom: 24px; }
.card { background: #222328; border: 1px solid #363532; border-radius: 6px; padding: 12px; text-align: center; }
.card img { max-width: 100%; max-height: 160px; object-fit: contain; background: #e2dac5; border-radius: 4px; padding: 8px; }
.card .name { font-size: 12px; color: #ebd173; margin-top: 8px; font-weight: bold; word-break: break-all; }
.card .meta { font-size: 11px; color: #9c9482; margin-top: 4px; }
.badge { display: inline-block; padding: 2px 6px; border-radius: 3px; font-size: 10px; font-weight: bold; margin-top: 4px; }
.badge-edge { background: #3b4e36; color: #b8e0a8; }
.badge-center { background: #522f2f; color: #ffb8b8; }
.badge-connector { background: #2e4458; color: #a8d5ff; }
.badge-accent { background: #544428; color: #ffe4a8; }
</style>
</head>
<body>
<h1>將軍 / General — V4 Tactical Asset Browser</h1>

<h2>1. Contact Sheet Previews</h2>
<p>Quick overview of each category on an antique silk parchment ground:</p>
<img class="contact-sheet" src="previews/preview_mountains.png" alt="Mountains Contact Sheet">
<img class="contact-sheet" src="previews/preview_forests.png" alt="Forests Contact Sheet">
<img class="contact-sheet" src="previews/preview_terrain.png" alt="Terrain Contact Sheet">
<img class="contact-sheet" src="previews/preview_structures.png" alt="Structures Contact Sheet">
<img class="contact-sheet" src="previews/preview_ui.png" alt="UI Contact Sheet">

</body>
</html>
"""
	var f := FileAccess.open(ROOT + "browser.html", FileAccess.WRITE)
	if f != null:
		f.store_string(html)
		f.close()
		print("Generated interactive browser: browser.html")
