extends Node

## PresentationModeController (VISUAL ONLY): the ONE authority for which
## presentation draws the battle. Created by the Step2R shell in windowed runs
## only (headless runs stay in PresentationOrientation.Mode.HEADLESS and never
## build it).
##
##   HIGH     2D board re-projected by PresentationProjection (strategic ->
##            tactical zoom range)
##   CLOSEUP  2.5D view behind the friendly HQ (BattlefieldCloseupView)
##
## set_mode() is the only place the mode changes. It publishes the mode to
## PresentationOrientation, switches which renderer is active and sets the
## main viewport's canvas cull mask. Both modes hide the raw 2D world canvas
## from the main viewport: HIGH shows it through the projection's offscreen
## render (drawn over the full screen, so the direct draw was invisible work),
## CLOSEUP shows its own 3D camera and drapes the 2D overlay on its ground.
##
## Canvas visibility layers (bits) used by both modes:
##   LAYER_WORLD    board presentation nodes (terrain, structures, units)
##   LAYER_OVERLAY  gameplay overlays under the shell (routes, envelopes)
## CanvasLayer subtrees (HUD, projection, fade) keep the default layer 1.
##
## Nothing here reads or writes gameplay state.

const PresentationOrientationCls = preload("res://scripts/core/presentation_orientation.gd")

const LAYER_WORLD: int = 2
const LAYER_OVERLAY: int = 4
const WORLD_VISUAL_KEYS: Array[String] = ["hex_grid", "hex_compositor", "unit_renderer", "stronghold_renderer"]

var shell: Node = null
var projection: Node = null
var closeup: Node = null
var _base_cull_mask: int = 0xFFFFFFFF

func _init() -> void:
	name = "PresentationModeController"

func setup(p_shell: Node, p_projection: Node, p_closeup: Node) -> void:
	shell = p_shell
	projection = p_projection
	closeup = p_closeup
	_base_cull_mask = get_viewport().canvas_cull_mask
	(shell as CanvasItem).visibility_layer = LAYER_OVERLAY | LAYER_WORLD
	for c in shell.get_children():
		_classify(c)
	get_tree().node_added.connect(_on_node_added)
	if closeup != null:
		closeup.set("mode_controller", self)
	# The battle opens in the closeup when it exists (HQ-anchored), else HIGH.
	_apply(PresentationOrientationCls.Mode.HIGH)
	if closeup != null:
		call_deferred("set_mode", PresentationOrientationCls.Mode.CLOSEUP)

func _exit_tree() -> void:
	if get_tree() and get_tree().node_added.is_connected(_on_node_added):
		get_tree().node_added.disconnect(_on_node_added)

func mode() -> int:
	return PresentationOrientationCls.mode

## The one mode switch. Safe to call repeatedly with the current mode.
func set_mode(m: int) -> void:
	if m == PresentationOrientationCls.Mode.CLOSEUP and closeup == null:
		m = PresentationOrientationCls.Mode.HIGH
	if m == PresentationOrientationCls.mode:
		return
	_apply(m)

func _apply(m: int) -> void:
	var to_closeup: bool = m == PresentationOrientationCls.Mode.CLOSEUP
	if not to_closeup and closeup != null and bool(closeup.call("is_active")):
		closeup.call("apply_active", false)
	_set_projection_enabled(not to_closeup)
	PresentationOrientationCls.set_mode(m)
	get_viewport().canvas_cull_mask = _base_cull_mask & ~(LAYER_WORLD | LAYER_OVERLAY)
	if to_closeup:
		closeup.call("apply_active", true)

func _set_projection_enabled(on: bool) -> void:
	if projection == null:
		return
	projection.process_mode = Node.PROCESS_MODE_INHERIT if on else Node.PROCESS_MODE_DISABLED
	var layer: CanvasLayer = projection.get("_layer")
	if layer:
		layer.visible = on
	for key in ["_sub", "_sub_far"]:
		var sv: SubViewport = projection.get(key)
		if sv:
			sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS if on else SubViewport.UPDATE_DISABLED
	if on:
		projection.call("_sync", true)

# ------------------------------------------------------------ canvas layers

func _is_world_visual(n: Node) -> bool:
	for key in WORLD_VISUAL_KEYS:
		if shell.get(key) == n:
			return true
	return false

func _classify(n: Node) -> void:
	if n is CanvasLayer or n == closeup or n == self:
		return
	if n is CanvasItem:
		if _is_world_visual(n):
			(n as CanvasItem).visibility_layer = LAYER_WORLD
			return
		(n as CanvasItem).visibility_layer = LAYER_OVERLAY
	for c in n.get_children():
		_classify(c)

## Nodes added later under the shell inherit the same classification; nodes
## inside a world visual keep their parent's layer (visibility layers are
## per item, so they are set explicitly here).
func _on_node_added(n: Node) -> void:
	if not (n is CanvasItem) or shell == null or not shell.is_ancestor_of(n):
		return
	var p: Node = n.get_parent()
	while p != null and p != shell:
		if p is CanvasLayer:
			return
		if _is_world_visual(p):
			(n as CanvasItem).visibility_layer = LAYER_WORLD
			if closeup != null and PresentationOrientationCls.mode == PresentationOrientationCls.Mode.CLOSEUP:
				closeup.call("on_world_node_added", n)
			return
		p = p.get_parent()
	(n as CanvasItem).visibility_layer = LAYER_WORLD if _is_world_visual(n) else LAYER_OVERLAY
