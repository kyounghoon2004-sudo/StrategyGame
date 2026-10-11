extends RefCounted

## VISUAL CONTRACT (VISUAL ONLY): the numbers every presentation layer must
## agree on. docs/visual/VISUAL_DESIGN_LANGUAGE.md explains each rule;
## tools/visual_contract/visual_contract_check.gd enforces them.
##
## Const-only and deliberately without class_name: preload it, never register
## it globally (keeps .godot/global_script_class_cache.cfg untouched).
##
## World px are battlefield pixels from HexUtils.hex_to_pixel (the logical
## grid). Presentation may scale, rotate or re-project them, but never writes
## them back: gameplay coordinates are axial (q, r) and nothing here changes.

## ---- Logical hex (flat-top, world px; mirrors HexUtils) ----------------------
const HEX_CORNER_W: float = 48.0  # corner-to-corner width (HexUtils.TILE_W)
const HEX_FLAT_H: float = 42.0    # flat-to-flat height   (HexUtils.TILE_H)
const HEX_CIRCUMRADIUS: float = 24.0

## ---- One unit = one hex ------------------------------------------------------
## Unit ground footprint radius: inset inside its own hex, never touching a
## neighbour (Step2RUnitRenderer.FOOTPRINT_RADIUS).
const UNIT_FOOTPRINT_RADIUS: float = 20.5

## ---- One city / stronghold / village = one hex -------------------------------
## Widest upright art (world px, after presence) allowed to stand on ONE hex.
## Anything wider visually claims a neighbour hex.
const ONE_HEX_ART_MAX_WIDTH: float = 44.0
## Stronghold keep art on the HIGH board (world px, before presence): fills
## most of its one hex (0.75 of the corner-to-corner width).
const STRONGHOLD_ART_WIDTH: float = 36.0
const STRONGHOLD_ART_MAX_HEIGHT: float = 46.0
## Upright "presence" growth for structures at low camera pitch (HIGH view).
## The effective value is further capped per sprite so that
## content_width * presence <= ONE_HEX_ART_MAX_WIDTH.
const STRUCTURE_PRESENCE_MAX: float = 1.4

## ---- CLOSEUP ---------------------------------------------------------------
## Closeup hex circumradius in closeup units (BattlefieldCloseupView.HEXR).
const CLOSEUP_HEXR: float = 4.5
## A stronghold card is at most this share of the hex flat-to-flat width.
const CLOSEUP_STRONGHOLD_WIDTH_OF_HEX: float = 0.837

## ---- Tactical obscurity (fog presentation, both modes) ----------------------
## Unknown ground is flat ink with a sparse static hatch; remembered ground is
## a cool desaturated memory tint. Never drifting, never weather.
const FOG_INK: Color = Color(0.155, 0.165, 0.19)
const FOG_HATCH_LIFT: float = 0.025

## ---- Performance budget -----------------------------------------------------
## Scripts (res paths) that may run per-frame _process work while presented.
## Everything else must be event-driven (signals, setters, epsilon gates).
const PER_FRAME_ALLOWLIST: Array[String] = [
	"res://scripts/step2r/step2r_camera_controller.gd",         # smoothing / WASD
	"res://scripts/visual/presentation_projection.gd",          # HIGH re-projection
	"res://scripts/visual/closeup25d/battlefield_closeup_view.gd", # CLOSEUP camera
	"res://scripts/visual/civ3d/civ_battlefield_view.gd",       # CIV3D camera (sig-gated)
	"res://scripts/step3/step3_envelope_renderer.gd",           # selection pulse
	"res://scripts/step2r/step2r_unit_renderer.gd",             # upright frames (gated)
	"res://scripts/visual/hex_native/battlefield_hex_visual_compositor.gd", # gated
	"res://scripts/visual/hex_native/approved_owned_terrain_layer.gd",      # gated
	"res://scripts/core/stronghold_renderer.gd",                # gated
	"res://scripts/core/step2r_stronghold_badge.gd",            # selection pulse
]
## Shaders allowed to read TIME (continuous animation). Empty on purpose: the
## only animation is the selection pulse, driven from script uniforms.
const TIME_SHADER_ALLOWLIST: Array[String] = []
## Node classes that must never appear in the battle presentation. The CIV3D
## view (Forward+) owns exactly one DirectionalLight3D sun with shadows.
const FORBIDDEN_NODE_CLASSES: Array[String] = [
	"OmniLight3D", "SpotLight3D", "PointLight2D",
	"DirectionalLight2D", "GPUParticles2D", "GPUParticles3D", "CPUParticles2D",
	"CPUParticles3D", "RigidBody2D", "RigidBody3D", "Skeleton3D",
	"FogVolume", "VoxelGI", "LightmapGI", "ReflectionProbe",
]

## ---- Retired paths (must never be referenced again) --------------------------
## Recorded in artifacts/visual_frontend_hardening_v1/AUDIT_AND_CLEANUP.md.
const RETIRED_SCRIPT_PATHS: Array[String] = [
	"res://scripts/visual/b3d/",
	"res://scripts/visual/r3/battlefield_visual_map_r3.gd",
	"res://scripts/visual/mountain_visual_review.gd",
	"res://scripts/visual/coherent_terrain_field.gd",
	"res://scripts/visual/hex_landmark.gd",
	"res://scripts/visual/battlefield_painted_terrain.gd",
	"res://scripts/visual/battlefield_vegetation.gd",
	"res://scripts/visual/tactical_map_annotations.gd",
	"res://scripts/visual/hex_native/hex_owned_terrain_layer.gd",
	"res://scripts/visual/hex_native/hex_mist_layer.gd",
	"res://scripts/step2r/step2r_boundary_renderer.gd",
	"res://scripts/step2r/step2r_outer_mountain_field.gd",
]
