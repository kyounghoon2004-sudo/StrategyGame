extends RefCounted
## Every placeable model in the map editor, built from the local asset library (assets/ + SG_VISUAL_OUTPUT_ROOT).
## One entry = {group, kind, variant, label, path, fit, scale}.
##   kind  : what the importer reads (forest / tree / mountain / water / road / castle / fort / building / farm / unit)
##   group : palette tab only (several groups can share a kind, e.g. three mountain tabs)
##   fit   : > 0 scales the model so its widest side is `fit` editor units (a hex is 36 wide); 0 keeps `scale`
## Variants that already exist in saved maps keep their old ids (mixed/pine, massif ids, castle_vN, building_*).
const Paths = preload("res://tools/dev_visual_lab/visual_output_paths.gd")

const GROUPS := [
	["brush", "산 그리기"], ["ground", "바닥"], ["forest", "숲"], ["tree", "나무"], ["range", "산맥 통째로"],
	["water", "강 · 다리"], ["road", "길"], ["castle", "성곽"], ["fort", "요새 시설"], ["building", "건물"],
	["farm", "농지"], ["unit", "유닛"],
]
const UNIT_CLASSES := [["infantry", "보병"], ["spearman", "창병"], ["archer", "궁병"], ["conscript", "민병"],
	["scout", "정찰병 · 군견"], ["cavalry", "기병"], ["hq", "기마 지휘관"]]

static var _cache: Array = []


static func entries() -> Array:
	if not _cache.is_empty():
		return _cache
	var out: Array = []
	# Mountains are range25 only. The brush paints hex by hex (drag); each hex takes the range25 piece whose
	# neighbour shape matches its painted neighbours (map_editor.gd range_pieces()).
	out.append(_e("brush", "mountain", "brush_range", "산 그리기 (range25)", Paths.output("mountain-range-25/exports/straight_medium.glb"), 0.0, 0.75))
	# 바닥 = the asset library's five ground variants; the board blends them like the library (map_editor_board.gd).
	var B = load("res://tools/dev_visual_lab/map_editor_board.gd")
	for gid in B.VARIANTS.keys():
		out.append(_e("ground", "ground", gid, str(B.VARIANT_LABELS[gid]), "", 0.0))
	out.append(_e("forest", "forest", "mixed", "혼합 숲", Paths.output("full-map-lab/optimized/broadleaf_mid.glb"), 0.0))
	out.append(_e("forest", "forest", "pine", "소나무 숲", Paths.output("full-map-lab/optimized/tall_pine_mid.glb"), 0.0))
	for t in [["tall_pine", "큰 소나무"], ["compact_pine", "작은 소나무"], ["conifer", "침엽수"], ["broadleaf", "활엽수"],
			["cypress", "측백나무"], ["dead_tree", "고사목"]]:
		out.append(_e("tree", "tree", t[0], t[1], Paths.output("full-map-lab/optimized/%s_mid.glb" % t[0]), 16.0))
	for t in [["01-tall-straight-pine", "곧은 소나무"], ["02-windswept-mountain-pine", "바람 맞은 소나무"],
			["03-broad-layered-conifer", "층진 침엽수"], ["04-compact-hill-pine", "언덕 소나무"],
			["05-sparse-dead-tree", "마른 나무"], ["06-broadleaf-deciduous-tree", "낙엽 활엽수"],
			["07-tall-cypress-like-tree", "키 큰 측백"], ["08-sapling-cluster", "어린 나무 무리"]]:
		out.append(_e("tree", "tree", "src-" + t[0], t[1], "res://assets/map_composition_v0/source_glb/trees/%s.glb" % t[0], 16.0))
	for shape in [["straight", "직선"], ["c_curve", "C자"], ["s_curve", "S자"], ["y_branch", "Y자"], ["irregular", "불규칙"]]:
		for size in [["short_low", "짧고 낮음"], ["short_high", "짧고 높음"], ["medium", "중간"], ["long_low", "길고 낮음"], ["long_high", "길고 높음"]]:
			var id := "%s_%s" % [shape[0], size[0]]
			out.append(_e("range", "mountain", "range-" + id, "산맥 %s · %s" % [shape[1], size[1]],
				Paths.output("mountain-range-25/exports/%s.glb" % id), 0.0, 0.75))
	# River / road brushes: drag to paint; each hex draws its stretch toward its painted neighbours so the
	# whole line joins up (map_editor.gd add_path_piece). Single-hex river and bridge models stay below.
	out.append(_e("water", "water", "brush_river", "강 그리기 (이어짐)", "res://assets/map_composition_v0/source_glb/water/02-mainriver.glb", 36.0))
	out.append(_e("road", "road", "brush_road", "길 그리기 (이어짐)", "res://assets/map_composition_v0/source_glb/tiles/05-packed-dirt-trail.glb", 36.0))
	for w in [["narrow_stream", "01-narrowstream", "개울"], ["main_river", "02-mainriver", "큰 강"], ["shallow_ford", "03-shallowford", "얕은 여울"],
			["wooden_bridge", "04-woodenbridge", "나무 다리"], ["stone_bridge", "05-stonereinforcedbridge", "돌다리"],
			["rock_bank", "06-tallrockriverbank", "바위 강둑"]]:
		out.append(_e("water", "water", w[0], w[2], "res://assets/map_composition_v0/source_glb/water/%s.glb" % w[1], 36.0))
	out.append(_e("road", "road", "dirt_trail", "흙길", "res://assets/map_composition_v0/source_glb/tiles/05-packed-dirt-trail.glb", 36.0))
	out.append(_e("road", "road", "tracked_crossing", "갈림 흙길", "res://assets/map_composition_v0/source_glb/tiles/06-worn-crossing-tracked-ground.glb", 36.0))
	out.append(_e("road", "road", "kit_road", "길 조각", Paths.output("threejs-hex-terrain-kit/exports/smoke_road_lod0.glb"), 36.0))
	for i in range(4):
		out.append(_e("castle", "castle", "castle_v%d" % (i + 1), "성곽 %d" % (i + 1), Paths.output("scenery-scale-massif/castle4/exports/castle_v%d_lod0.glb" % (i + 1)), 0.0))
	for f in [["01-wooden-palisade-wall", "목책"], ["02-stone-earth-defensive-wall", "돌흙 성벽"], ["03-layered-gatehouse", "성문 누각"],
			["04-timber-watchtower", "망루"], ["05-hill-frontier-fort", "언덕 요새"], ["06-major-stronghold", "큰 거점"]]:
		out.append(_e("fort", "fort", f[0], f[1], "res://assets/map_composition_v0/source_glb/fortifications/%s.glb" % f[0], 32.0))
	var names := ["작은 집", "큰 집", "작업장", "창고", "마을 회관", "마을 문", "농장 창고"]
	var ids := ["building_small_house", "building_medium_house", "building_workshop", "building_granary", "building_hall", "building_gate", "building_farm_granary"]
	for i in range(ids.size()):
		out.append(_e("building", "building", ids[i], names[i], Paths.output("scenery-scale-massif/buildings/exports/%s_lod0.glb" % ids[i]), 0.0))
	for b in [["village_courtyard_apron", "마을 마당"], ["village_courtyard_props", "마당 소품"], ["village_wall_segment", "마을 담"], ["village_wall_corner", "담 모서리"]]:
		out.append(_e("building", "building", b[0], b[1], Paths.output("village-farmland-kit/exports/%s_lod0.glb" % b[0]), 34.0))
	for b in [["01-small-peasant-house", "초가집"], ["02-medium-family-house", "기와집"], ["03-raised-granary", "높은 곳간"],
			["04-workshop-utility", "공방"], ["05-communal-hall", "회관"], ["06-walled-village-gate", "마을 성문"]]:
		out.append(_e("building", "building", "src-" + b[0], b[1], "res://assets/map_composition_v0/source_glb/buildings/%s.glb" % b[0], 26.0))
	for f in [["farm_patch_dry", "밭"], ["farm_patch_rice", "논"], ["farm_patch_terrace", "계단식 논"], ["farm_edge_dike", "논둑"],
			["farm_channel_straight", "수로 직선"], ["farm_channel_bend60", "수로 굽이 60"], ["farm_channel_bend120", "수로 굽이 120"],
			["farm_channel_tee", "수로 갈림"], ["farm_channel_end_sluice", "수문"]]:
		out.append(_e("farm", "farm", f[0], f[1], Paths.output("village-farmland-kit/exports/%s_lod0.glb" % f[0]), 36.0))
	for a in [["01-drycropfield", "마른 밭"], ["02-irrigatedricefield", "물 댄 논"], ["03-terracedfield", "계단 밭"], ["04-ruralgranary", "시골 곳간"]]:
		out.append(_e("farm", "farm", "src-" + a[0], a[1], "res://assets/map_composition_v0/source_glb/agriculture/%s.glb" % a[0], 34.0))
	for faction in [["blue", "아군"], ["red", "적군"]]:
		for u in UNIT_CLASSES:
			out.append(_e("unit", "unit", "%s_%s" % [u[0], faction[0]], "%s %s" % [faction[1], u[1]], "", 0.0))
	_cache = out
	return out


static func _e(group: String, kind: String, variant: String, label: String, path: String, fit: float, scale: float = 1.0) -> Dictionary:
	return {"group": group, "kind": kind, "variant": variant, "label": label, "path": path, "fit": fit, "scale": scale}


static func find(kind: String, variant: String) -> Dictionary:
	for e in entries():
		if e.kind == kind and e.variant == variant:
			return e
	return {}


static func in_group(group: String) -> Array:
	var out: Array = []
	for e in entries():
		if e.group == group:
			out.append(e)
	return out


static func kinds() -> Array:
	var out: Array = []
	for e in entries():
		if not out.has(e.kind):
			out.append(e.kind)
	return out


static func file_path(e: Dictionary) -> String:
	var p := str(e.get("path", ""))
	return ProjectSettings.globalize_path(p) if p.begins_with("res://") else p
