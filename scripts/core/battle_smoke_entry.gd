## battle_smoke_entry.gd — BattleMap integration smoke test
## Loads battle_map.tscn, lets _ready() run for several frames, then checks the live tree.
extends SceneTree

var _map: Node
var _frames: int = 0
var _reported: bool = false
var _failed: bool = false
var _cleanup_started: bool = false

func _initialize() -> void:
	var scene: PackedScene = load("res://scenes/battle_map.tscn") as PackedScene
	if scene == null:
		push_error("[BattleSmoke] battle_map.tscn 로드 실패")
		_failed = true
		return
	_map = scene.instantiate()
	root.add_child(_map)


func _process(_delta: float) -> bool:
	_frames += 1
	if _cleanup_started:
		if _frames >= 20:
			quit(1 if _failed else 0)
		return false
	if _map == null or not is_instance_valid(_map):
		if _frames > 3:
			push_error("[BattleSmoke] BattleMap 인스턴스가 생성되지 않음")
			_failed = true
			quit(1)
		return false
	if not _reported and _frames >= 8:
		_reported = true
		var grid: Node = _map.get_node_or_null("HexGrid")
		var renderer: Node = _map.get_node_or_null("UnitRenderer")
		var beacon: Node = _map.get_node_or_null("TargetBeacon")
		var sidebar: Node = _map.get_node_or_null("TacticalSidebar")
		if sidebar == null:
			sidebar = _map.get_node_or_null("../TacticalSidebar")
		var grid_cells: int = int(grid.get("cell_data").size()) if grid != null else 0
		var rendered_units: int = int(renderer.get("unit_map").size()) if renderer != null else 0
		var status: Node = _map.get_node_or_null("CanvasLayer/TopStatusCapsule")
		var status_text_node: Node = status.get_node_or_null("StatusText") if status != null else null
		var status_text: String = str(status_text_node.get("text")) if status_text_node != null else ""
		var heatmaps: Dictionary = grid.get("_move_heatmap_textures") if grid != null else {}
		var fog_count: int = int(grid.call("get_fog_count")) if grid != null and grid.has_method("get_fog_count") else 0
		var fog_api_ok: bool = grid != null and grid.has_method("set_fog_hexes") and grid.has_method("reveal_hex") and grid.has_method("reveal_area")
		var fog_reveal_ok: bool = false
		if fog_api_ok and fog_count > 0:
			var fog_before: int = fog_count
			grid.call("reveal_hex", 6, 6)
			var fog_after: int = int(grid.call("get_fog_count"))
			fog_reveal_ok = fog_after == fog_before - 1
			grid.call("set_fog_hexes", [
				Vector2i(6, 6), Vector2i(6, 7), Vector2i(6, 8),
				Vector2i(7, 6), Vector2i(7, 7), Vector2i(8, 6),
				Vector2i(8, 7), Vector2i(8, 8),
			])
		var ambush_api_ok: bool = grid != null and grid.has_method("mark_ambush_hex") and grid.has_method("clear_ambush_hex")
		var ambush_marker_ok: bool = false
		if ambush_api_ok:
			grid.call("mark_ambush_hex", 6, 6)
			ambush_marker_ok = bool(grid.call("is_ambush_marked", 6, 6))
			grid.call("clear_ambush_hex", 6, 6)
		var scout_reveal_ok: bool = false
		if fog_api_ok and _map.has_method("_reveal_scout_area"):
			var scout_fog_before: int = int(grid.call("get_fog_count"))
			_map.call("_reveal_scout_area")
			scout_reveal_ok = int(grid.call("get_fog_count")) < scout_fog_before
			grid.call("set_fog_hexes", [
				Vector2i(6, 6), Vector2i(6, 7), Vector2i(6, 8),
				Vector2i(7, 6), Vector2i(7, 7), Vector2i(8, 6),
				Vector2i(8, 7), Vector2i(8, 8),
			])
		var ambush_flow_ok: bool = false
		if _map.has_method("_prepare_scout_ambush"):
			_map.call("_prepare_scout_ambush")
			ambush_flow_ok = int((_map.get("_prepared_ambushes") as Dictionary).size()) > 0
		var center_cell: Variant = grid.call("get_cell", 18, 12) if grid != null else null
		var fortress_ok: bool = center_cell != null and int(center_cell.get("terrain")) == 4
		var hp_ratio_ok: bool = false
		if renderer != null:
			var player_list: Array = _map.get("player_units") as Array
			if not player_list.is_empty():
				var sample_unit: Variant = player_list[0]
				var hp_map: Dictionary = renderer.get("hp_bar_map") as Dictionary
				var hp_node: Sprite2D = hp_map.get(int(sample_unit.get_instance_id())) as Sprite2D
				var original_count: int = int(sample_unit.get("soldier_count"))
				if hp_node != null and hp_node.texture is ImageTexture:
					sample_unit.set("soldier_count", maxi(1, int(original_count / 2)))
					renderer.call("update_unit_visual", sample_unit)
					var half_image: Image = (hp_node.texture as ImageTexture).get_image()
					var half_color: Color = half_image.get_pixel(20, 2)
					sample_unit.set("soldier_count", original_count)
					renderer.call("update_unit_visual", sample_unit)
					var full_image: Image = (hp_node.texture as ImageTexture).get_image()
					var full_color: Color = full_image.get_pixel(20, 2)
					hp_ratio_ok = full_color != half_color
		print("[BattleSmoke] grid_cells=%d rendered_units=%d beacon=%s sidebar=%s status=%s heatmaps=%d fog=%d fog_api=%s fog_reveal=%s scout_reveal=%s ambush_api=%s ambush_marker=%s ambush_flow=%s fortress=%s hp_ratio=%s" % [grid_cells, rendered_units, str(beacon != null), str(sidebar != null), str(status_text.find("턴: 10") >= 0), heatmaps.size(), fog_count, str(fog_api_ok), str(fog_reveal_ok), str(scout_reveal_ok), str(ambush_api_ok), str(ambush_marker_ok), str(ambush_flow_ok), str(fortress_ok), str(hp_ratio_ok)])
		if grid_cells != 864 or rendered_units != 12 or beacon == null or sidebar == null or status == null or heatmaps.size() != 4 or fog_count != 8 or not fog_api_ok or not fog_reveal_ok or not scout_reveal_ok or not ambush_api_ok or not ambush_marker_ok or not ambush_flow_ok or not fortress_ok or not hp_ratio_ok:
			push_error("[BattleSmoke] 통합 상태 불일치")
			_failed = true
	if _frames >= 18:
		if not _cleanup_started:
			_cleanup_started = true
			if _map != null and is_instance_valid(_map):
				root.remove_child(_map)
				_map.free()
			return false
		quit(1 if _failed else 0)
	return false
