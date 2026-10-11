class_name StrongholdRenderer
extends Node2D

## Visual renderer for multi-hex strongholds (§14-20, §26-30)
## Renders commanding 3-hex structure art for Fortress and Capital,
## plus always-visible adaptive strategic world badges with inverse zoom scaling.

const HexUtilsCls = preload("res://scripts/core/hex_utils.gd")
const StrongholdCls = preload("res://scripts/core/stronghold.gd")
const Step2RStrongholdBadgeCls = preload("res://scripts/core/step2r_stronghold_badge.gd")
const PresentationOrientationCls = preload("res://scripts/core/presentation_orientation.gd")

signal stronghold_clicked(structure_id: String)
signal stronghold_hover_changed(structure_id: String, is_hovered: bool)

var _stronghold_nodes: Dictionary = {} # structure_id -> Node2D container
var _hex_overlays: Dictionary = {}     # "q,r" -> Polygon2D
var _hex_outlines: Dictionary = {}     # "q,r" -> Line2D
var _badge_nodes: Dictionary = {}      # structure_id -> Step2RStrongholdBadge
var _selected_stronghold_id: String = ""
var _current_zoom: float = 1.15
var _stronghold_data_cache: Dictionary = {}
## Optional plate names (canonical battlefields): structure_id -> label.
var display_names: Dictionary = {}

func _ready() -> void:
	z_index = 5

func clear_all() -> void:
	for n in _stronghold_nodes.values():
		if is_instance_valid(n):
			n.queue_free()
	_stronghold_nodes.clear()
	for n in _hex_overlays.values():
		if is_instance_valid(n):
			n.queue_free()
	_hex_overlays.clear()
	for n in _hex_outlines.values():
		if is_instance_valid(n):
			n.queue_free()
	_hex_outlines.clear()
	for n in _badge_nodes.values():
		if is_instance_valid(n):
			n.queue_free()
	_badge_nodes.clear()
	_stronghold_data_cache.clear()
	_selected_stronghold_id = ""

func render_strongholds(strongholds: Array) -> void:
	clear_all()
	for sh in strongholds:
		_render_single(sh)

## Dynamic view: name plates follow the live upright stretch.
func _process(_delta: float) -> void:
	if not PresentationOrientationCls.perspective_active or not PresentationOrientationCls.board_presented():
		return
	for sid in _badge_nodes.keys():
		var badge: Node2D = _badge_nodes[sid] as Node2D
		if not is_instance_valid(badge):
			continue
		var sc := Vector2(1.0, PresentationOrientationCls.stretch_at_world(badge.global_position))
		if not badge.scale.is_equal_approx(sc):
			badge.scale = sc

func set_camera_zoom(zoom_val: float) -> void:
	_current_zoom = zoom_val
	for sid in _badge_nodes.keys():
		var badge: Node = _badge_nodes[sid]
		if is_instance_valid(badge) and badge.has_method("set_camera_zoom"):
			badge.call("set_camera_zoom", zoom_val)

func get_badge(stronghold_id: String) -> Variant:
	return _badge_nodes.get(stronghold_id, null)

func get_all_badges() -> Dictionary:
	return _badge_nodes

func _render_single(sh: Variant) -> void:
	var sid: String = str(sh.structure_id)
	var type: int = int(sh.structure_type)
	var anchor: Vector2i = sh.get_anchor()
	var is_capital: bool = (type == StrongholdCls.StrongholdType.CAPITAL)
	_stronghold_data_cache[sid] = sh

	# ONE STRONGHOLD = ONE HEX (visual contract): the board art is a single keep
	# on the anchor hex (HexStructureCompositor / closeup card). The retired
	# per-footprint procedural walls/moat/towers were built hidden and never
	# shown; only the strategic name-plate badge is drawn here.
	var anchor_pos: Vector2 = HexUtilsCls.hex_to_pixel(anchor.x, anchor.y)

	# Always-Visible Adaptive World Strategic Badge (§14-20)
	var badge: Node2D = Step2RStrongholdBadgeCls.new()
	badge.name = "Badge_%s" % sid
	badge.position = anchor_pos
	# Nameplate stays horizontal under the friendly-side yaw (yaw 0 -> 0).
	badge.rotation = PresentationOrientationCls.upright_rotation()
	badge.scale = PresentationOrientationCls.upright_scale()
	var sname: String = "호뢰관 (虎牢關)" if sid == "Fortress_Hulao" else ("낙양 (洛陽)" if sid == "Capital_Luoyang" else sid.replace("_", " "))
	if display_names.has(sid):
		sname = str(display_names[sid])
	badge.setup(
		sid,
		type,
		sname,
		str(sh.owner),
		int(sh.fortification_hp),
		int(sh.fortification_hp_max),
		int(sh.get_garrison_count()),
		int(sh.garrison_slots),
		is_capital,
		_current_zoom
	)
	badge.badge_clicked.connect(func(clicked_sid: String): stronghold_clicked.emit(clicked_sid))
	badge.badge_hover_changed.connect(func(is_hov: bool): stronghold_hover_changed.emit(sid, is_hov))
	add_child(badge)
	_badge_nodes[sid] = badge

func set_stronghold_hovered(stronghold_id: String, hovered: bool) -> void:
	var badge: Variant = _badge_nodes.get(stronghold_id, null)
	if badge and badge.has_method("set_hovered"):
		badge.call("set_hovered", hovered)

func update_stronghold_state(stronghold_id: String, hp: int, breached_state: bool, garrison_count: int) -> void:
	var badge: Variant = _badge_nodes.get(stronghold_id, null)
	if badge and badge.has_method("update_state"):
		badge.call("update_state", hp, breached_state, garrison_count)
	if breached_state:
		update_breach_state(stronghold_id, true)

func update_breach_state(stronghold_id: String, breached_state: bool) -> void:
	var container: Node2D = _stronghold_nodes.get(stronghold_id, null)
	if container:
		container.modulate = Color(0.85, 0.65, 0.65, 1.0) if breached_state else Color(1, 1, 1, 1)
	var badge: Variant = _badge_nodes.get(stronghold_id, null)
	if badge and badge.has_method("update_state"):
		var hp: int = 0 if breached_state else int(badge.get("fortification_hp"))
		var gc: int = int(badge.get("garrison_count"))
		badge.call("update_state", hp, breached_state, gc)

func highlight_stronghold(stronghold_id: String, do_highlight: bool) -> void:
	_selected_stronghold_id = stronghold_id if do_highlight else ""
	var badge: Variant = _badge_nodes.get(stronghold_id, null)
	if badge and badge.has_method("set_selected"):
		badge.call("set_selected", do_highlight)
	
	var sh: Variant = _stronghold_data_cache.get(stronghold_id, null)
	if sh:
		for hex in sh.get_footprint():
			var hkey: String = "%d,%d" % [hex.x, hex.y]
			var outline: Line2D = _hex_outlines.get(hkey, null)
			if outline:
				if do_highlight:
					outline.default_color = Color(1.0, 0.88, 0.25, 1.0)
					outline.width = 5.2
				else:
					var is_cap: bool = (sh.structure_type == StrongholdCls.StrongholdType.CAPITAL)
					outline.default_color = Color(0.85, 0.28, 0.22, 1.0) if is_cap else Color(0.55, 0.58, 0.68, 1.0)
					outline.width = 4.2 if is_cap else 3.6
