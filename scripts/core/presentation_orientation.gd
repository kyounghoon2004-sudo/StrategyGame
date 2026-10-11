class_name PresentationOrientation
extends RefCounted

## THE presentation state authority (VISUAL ONLY): camera yaw, upright-art
## helpers, perspective pre-stretch and the explicit HIGH / CLOSEUP mode.
## Nothing here is read by gameplay; axial coordinates never pass through it.
##
## STEP 0 / STEP 1 research-sandbox presentation frame (VISUAL ONLY).
##
## The DEV sandbox presents the board chess-style: the BLUE (allied) army sits
## on the player-facing near side of the screen, RED on the far side. The whole
## world is re-oriented by rotating the Camera2D — every axial (q, r) keeps its
## canonical meaning, scope algebra / command compilation / execution semantics
## are untouched, and pointer->world conversion still goes through the camera
## transform (Camera2D.get_global_mouse_position), so clicks stay correct.
##
## World-space TEXT must stay upright on the rotated screen. Any script that
## creates a Label inside the battlefield canvas should place it with
## upright_rotation() / upright_position() instead of hard-coded values.
## When yaw_rad is 0 (production, or any non-sandbox scene) both helpers return
## exactly the un-rotated values, so those scenes behave identically.

## yaw that maps world -X (BLUE, west) to screen bottom and world +X (RED) to
## screen top, i.e. "my side at the near side". +PI/2 in Godot's convention
## (screen = R(-yaw) * world for a Camera2D rotated by yaw).
const SAND0_BLUE_NEAR_SIDE_YAW: float = PI * 0.5

## Battle presentation yaw (VISUAL ONLY) used by the Step2R battlefield shell.
## BLUE FORWARD is +q, whose flat-top pixel direction is (36, 21), i.e. 30deg
## below screen-east. Rotating the camera by 120deg maps +q to straight
## screen-UP, so the friendly side sits at the bottom, the enemy at the top,
## every axial r-row becomes a vertical lane (world north / LEFT -> screen
## left) and flat-top hexes stay flat-top (hex symmetry is 60deg), so the grid
## reads exactly as before. Logic, pathing and axial meaning are untouched.
const BATTLE_BLUE_NEAR_SIDE_YAW: float = PI * 2.0 / 3.0

const HexUtilsCls = preload("res://scripts/core/hex_utils.gd")

static var yaw_rad: float = 0.0

## ---------------------------------------------------------------------------
## PRESENTATION MODE: the one authoritative answer to "what is on screen".
## Written only by the battle shell (at build) and PresentationModeController
## (HIGH <-> CLOSEUP switches). Every other presentation script only reads it.
##   HEADLESS  no display (training / self-play / audits): build no scenery
##   FLAT      rotated flat 2D board, no projection
##   HIGH      2D board seen through PresentationProjection (strategic/tactical)
##   CLOSEUP   2.5D view behind the friendly HQ; the 2D board is not drawn
## See docs/visual/VISUAL_DESIGN_LANGUAGE.md.
enum Mode { HEADLESS, FLAT, HIGH, CLOSEUP }
static var mode: int = Mode.FLAT


static func set_mode(value: int) -> void:
	mode = value


static func is_headless() -> bool:
	return mode == Mode.HEADLESS


## True while the flat 2D board (terrain, structures, unit nodes) is what the
## player sees, directly (FLAT) or re-projected (HIGH). Per-frame 2D
## presentation work early-outs when this is false.
static func board_presented() -> bool:
	return mode == Mode.FLAT or mode == Mode.HIGH


## BLUE forward (+q) in world px, normalized. The one orientation rule shared
## by both modes: HIGH rotates the camera so it points to screen-up, CLOSEUP
## looks along it from behind the friendly HQ.
static func friendly_forward_world() -> Vector2:
	return HexUtilsCls.hex_to_pixel(1, 0).normalized()


## Owner of the static presentation state (instance id of the battle shell
## that set it). A shell leaving the tree may only reset state it owns, so a
## late-freed old shell can never clobber the yaw / mode of a newer one.
static var owner_id: int = 0


static func claim(owner: Object) -> void:
	owner_id = owner.get_instance_id() if owner != null else 0


## Static presentation state must not leak into the next scene.
static func reset(owner: Object = null) -> void:
	if owner != null and owner.get_instance_id() != owner_id:
		return
	owner_id = 0
	set_yaw(0.0)
	mode = Mode.FLAT


static func set_yaw(value: float) -> void:
	yaw_rad = value
	if is_zero_approx(value):
		set_upright_stretch(1.0)
		perspective_active = false
		view_e = 0.0


static func is_rotated() -> bool:
	return absf(yaw_rad) > 0.0001


## Local rotation a world-space label needs so its text renders horizontal.
static func upright_rotation() -> float:
	if not is_rotated():
		return 0.0
	return yaw_rad


## Local position a world-space Control needs so it keeps its original SCREEN
## offset from the parent origin while its text stays horizontal.
## `center_offset` = original top-left offset + half the label size (its centre
## in parent space); `pivot` = the Control's pivot_offset (rotation anchor).
## At yaw 0 this returns `center_offset - pivot`, which IS the original
## top-left offset — byte-identical to the pre-sandbox behaviour.
static func upright_position(center_offset: Vector2, pivot: Vector2) -> Vector2:
	if not is_rotated():
		return center_offset - pivot
	return center_offset.rotated(yaw_rad) - pivot


## Perspective presentation (VISUAL ONLY): the flat board is re-projected onto
## a pitched ground plane, which also compresses anything drawn in it
## vertically. Upright art (units, trees, buildings, name plates) is
## pre-stretched on the flat board by this factor so it stands at a natural
## aspect after projection. 1.0 = no perspective (unchanged behaviour).
static var upright_stretch: float = 1.0
## True while the perspective presentation is active for this battle (set
## by the shell before the world is built; independent of the live pitch).
static var perspective_active: bool = false
## Live view blend from PresentationProjection: 0 = commander (near top-down)
## .. 1 = battlefield (low pitch). Drives unit presentation blending.
static var view_e: float = 0.0
## Close-range presence multiplier (1 = none) published by the projection.
static var presence: float = 1.0
## Optional per-position provider (Callable(world_pos) -> float) set by the
## projection so live units get the exact local factor for their depth.
static var stretch_provider: Callable = Callable()
## Optional Callable(world_pos) -> Vector2(stretch, lean), see projection.
static var frame_provider: Callable = Callable()


static func set_upright_stretch(value: float, provider: Callable = Callable()) -> void:
	upright_stretch = value
	stretch_provider = provider
	if not provider.is_valid():
		frame_provider = Callable()


static func stretch_at_world(world_pos: Vector2) -> float:
	if stretch_provider.is_valid():
		return float(stretch_provider.call(world_pos))
	return upright_stretch


## Vector3(stretch, lean, readability_boost).
static func frame_at_world(world_pos: Vector2) -> Vector3:
	if frame_provider.is_valid():
		return frame_provider.call(world_pos)
	return Vector3(stretch_at_world(world_pos), 0.0, 1.0)


static func upright_scale() -> Vector2:
	return Vector2(1.0, upright_stretch)


## A SCREEN-space offset (e.g. "27px above") expressed as a world vector,
## including the perspective pre-stretch. Identity at yaw 0 / stretch 1.
static func upright_vector(screen_offset: Vector2, stretch: float = -1.0) -> Vector2:
	var st: float = upright_stretch if stretch < 0.0 else stretch
	var v := Vector2(screen_offset.x, screen_offset.y * st)
	return v.rotated(yaw_rad) if is_rotated() else v


## Screen-space vertical depth of a world point (larger = nearer the viewer /
## lower on screen). Used only for painter's-order sorting of upright art.
## At yaw 0 this is exactly world y.
static func screen_depth(world_pos: Vector2) -> float:
	if not is_rotated():
		return world_pos.y
	return world_pos.rotated(-yaw_rad).y
