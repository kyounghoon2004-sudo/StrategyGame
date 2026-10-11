# Civ6-style visual overhaul — scope spec (2026-10-07)

Decisions confirmed with the user. Visual/presentation only.

## HARD BOUNDARY — never touched
- GX / gameplay: `scripts/gx_missions/`, `scripts/sim/`, `scripts/combat/`, `scripts/core/` gameplay logic,
  `scripts/ai/`, `scripts/selfplay/`, training/eval pipelines.
- Unit movement and its timing/interpolation (`scripts/step2r/step2r_unit_renderer.gd` behaviour),
  the Step2R shell's command/selection logic, the logical hex grid (`HexUtils`, axial q,r, 48px flat-top).
- Headless runs: the new view is never built headless (same rule as the current presentations).
- The new view only READS board state (cell_data, unit renderer nodes, fog truth, stronghold specs),
  exactly like `battlefield_closeup_view.gd` does today. Picking goes through `screen_to_world`.

## What changes
| Area | Now | New |
|---|---|---|
| Camera | Two modes: HIGH (2D re-projection) + CLOSEUP (2.5D behind HQ) | One continuous Civ6-style 3D perspective camera: pan/edge-scroll, wheel zoom with pitch easing, no rotation. Zoom-out is the strategic view (no separate paper map). |
| Renderer | `gl_compatibility`, lights forbidden | Full 3D: Forward+, sun DirectionalLight3D + shadows, environment/tonemap. `visual_contract.gd` rewritten accordingly. |
| Map composition | 2D board + unlit sprite cards | Civ6 tile-based 3D diorama: each hex is a modelled tile (height for hills/mountains, edge blending, rivers, roads), dense per-hex dressing (forest canopy, farms, settlements/forts), clear hex grid lines, territory/border colour lines. |
| Fog | Flat ink / desaturated memory | Civ6: unexplored = cloud/parchment shroud; explored-not-visible = sepia "old map" tint. |
| Units | PNG formation cards | PNG formations kept (~10 soldiers) + Civ6-style badge (round class icon, faction colour, HP bar) above. |
| HUD | battle_hud.gd / tactical_sidebar.gd | Civ6 layout: top bar, bottom-left unit panel + command buttons, bottom-right end-turn/next-action. Same functions, rearranged. |

## What stays
- Art direction/palette: historical Chu–Han, painterly, restrained colour (Civ6 STRUCTURE, not Civ6 saturation).
- Existing assets reused where good: TREE standard, `map_composition_v0` GLBs, mountain modules — regraded
  for lit 3D (materials), not discarded.
- All gameplay overlays (routes, envelopes, selection) — re-draped on the 3D ground.

## Rollout
1. Default full map (strict / full_dev_map) first. HC01 and tutorial later.
2. Old HIGH/CLOSEUP stay in code (switchable) until the new view is accepted, then retired.
