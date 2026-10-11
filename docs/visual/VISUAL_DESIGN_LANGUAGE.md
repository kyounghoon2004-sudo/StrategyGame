# Visual Design Language — Five Dynasties Hex Strategy

**Status:** canonical visual contract (v1, 2026-09-25; terrain language v2 and canonical battlefields, 2026-09-26). Read it before touching
anything under `scripts/visual/`, `scripts/step2r/`, the battle scene, or
`assets/`.
**Enforced by:** `tools/visual_contract/visual_contract_check.gd`
**Numbers live in:** `scripts/visual/visual_contract.gd`

This document says **what the game must look like** and **how visual code must
behave**. It was written after a cleanup of the presentation layer; every rule
below is either enforced by the checker or was learned from a real failure.

---

## 0. The ten rules (short version)

1. It is a **2D / 2.5D board game**. Never a 3D scene. Nothing is lit.
2. **One unit = one hex. One city / stronghold / village = one hex.**
3. **Two presentations, one battlefield:** HIGH (2D board) and CLOSEUP (2.5D
   cards behind the friendly HQ). Only `PresentationModeController` switches
   between them.
4. **BLUE forward (+q) is screen-up** in both modes. The friendly HQ is
   bottom-centre.
5. Upright art **stands up and faces the viewer**. It is never rotated with
   the board, mirrored vertically, or laid flat.
6. **Fog is tactical obscurity**: flat ink for unknown ground, a flat cool
   memory tint for remembered ground. It is never weather, never drifting.
7. **Nothing animates** except selection pulses (the selected hex, a
   selected stronghold plate) and one-shot action tweens (move, attack, hit,
   floating text).
8. **Presentation never writes gameplay.** It reads axial `(q, r)`, fog truth
   and unit state, and draws them.
9. **Headless builds no scenery.** Training, self-play and audits pay for
   gameplay only.
10. **The visual layer is cheap**: static art, shared materials, event-driven
    updates, no per-frame work that the player cannot see.

---

## 1. Art direction

- **Setting:** Five Dynasties and Ten Kingdoms China (五代十國). It should read as
  a campaign map on a commander's table: earth, lacquer, silk, iron.
- **Rendering style:** 2D pixel-art / painted sprites with a **dark outline**,
  **3–4 tone cel shading**, and **light from the upper left**. There are no
  gradients on ground bands in the closeup; world-space pixels are chunky and
  match the soldiers' pixel density.
- **Tone:** restrained and legible. It is a tactical instrument first and a
  diorama second. Spectacle never outranks readability.

## 2. The 2D / 2.5D rule

| Allowed | Forbidden |
|---|---|
| Flat ground (2D meshes on the board; one flat plane in the closeup) | Heightfields, terrain displacement, 3D terrain |
| Upright 2D sprite **cards** facing the camera (units, trees, houses, peaks, keeps) | Rigged or modelled 3D characters, 3D buildings, 3D trees |
| Unshaded shaders (`render_mode unshaded`) | Lights (`Light3D`, `PointLight2D`), shadows, PBR / `StandardMaterial3D` |
| A perspective *camera* over a flat board (the HIGH projection, the CLOSEUP `Camera3D`) | A physically simulated 3D world |

The CLOSEUP uses `Node3D` / `Camera3D` only as a convenient way to lay flat
cards on a ground plane and pick with a ray. It is still a board with standees
on it. The retired `scripts/visual/b3d/` view (lit meshes, swaying props) is
the anti-example.

## 3. HIGH vs CLOSEUP

| | HIGH (strategic → tactical) | CLOSEUP |
|---|---|---|
| What it is | The 2D board, re-projected by `PresentationProjection` from near top-down (commander, zoom ≤ 0.5) to a tactical pitch (zoom cap 1.1) | The same battle as standees behind the friendly HQ |
| Purpose | Overview, planning, reading territory | Presence, depth, local tactics |
| Code | `scripts/visual/presentation_projection.gd`, `scripts/visual/hex_native/*` | `scripts/visual/closeup25d/*` |
| Assets | Approved board art (`assets/*/approved_v1`) | The same approved art as cards, plus closeup-only trees (`assets/closeup25d`) |
| Fog | `HexFogRenderer` (flat ink / memory tint) | Ground-shader ink / memory tint, plus a horizon fade to the same ink |
| Camera | HQ-anchored `Camera2D` (`_hq_anchor_target`) | HQ-anchored `Camera3D` (`_hq_anchor`), dolly 0.75–1.8 |

- **Explicit state.** `PresentationOrientation.mode` is one of `HEADLESS`,
  `FLAT`, `HIGH`, or `CLOSEUP`. The shell sets it at build time, and
  `PresentationModeController.set_mode()` switches it after that. Nobody else
  writes it. Per-frame 2D work checks `PresentationOrientation.board_presented()`.
- **The switch is discrete, not a morph.** Wheeling past the board cap (zoom
  1.1) enters CLOSEUP. Wheeling out of the closeup returns to HIGH at that cap.
  A short flat ink fade (0.16 s in, 0.22 s out) hides the swap. Do not build a
  continuous 2D→3D camera.
- The battle **opens in CLOSEUP** when the closeup exists, otherwise in HIGH.
- Both modes show **the same logical battlefield**: same hexes, units, fog
  truth, and overlays (routes and envelopes are rendered once in 2D and draped
  onto the closeup ground).
- Separate closeup assets are encouraged when the board art cannot stand up.
  The board's vegetation is canopy seen from above, for example. They must
  still follow sections 1, 13 and 18.

## 4. Hex visual scale

The logical grid is flat-top axial. World pixels come from
`HexUtils.hex_to_pixel(q, r) = (36q, 42r + 21q)`.

| Quantity | Value | Where |
|---|---|---|
| Hex corner-to-corner width | 48 px | `VisualContract.HEX_CORNER_W` |
| Hex flat-to-flat height | 42 px | `VisualContract.HEX_FLAT_H` |
| Circumradius | 24 px | `VisualContract.HEX_CIRCUMRADIUS` |
| Unit ground footprint radius | 20.5 px (inset, never touching a neighbour) | `UNIT_FOOTPRINT_RADIUS` |
| Widest upright art on one hex (after growth) | 44 px | `ONE_HEX_ART_MAX_WIDTH` |
| Stronghold keep art on the board | 36 × ≤46 px | `STRONGHOLD_ART_WIDTH / _MAX_HEIGHT` |
| Structure "presence" growth at low pitch | ≤ 1.4, and capped per sprite by the 44 px rule | `STRUCTURE_PRESENCE_MAX` |
| Closeup hex circumradius | 4.5 closeup units (1 unit = 24/4.5 world px) | `CLOSEUP_HEXR` |
| Closeup stronghold card width | 0.837 × hex flat-to-flat | `CLOSEUP_STRONGHOLD_WIDTH_OF_HEX` |

A hex is a **meaningful piece of territory**: it holds one formation with
ground visible around it, or one city, or a patch of terrain dressing. It
never holds a crowd of props. The number of logical hexes never changes for
presentation.

## 5. One unit = one hex

- A unit is drawn **at its hex centre** (`hex_to_pixel(q, r)`), and nowhere
  else except during a move or attack tween.
- A **faction ground footprint** (hex-shaped, inset to 20.5 px) marks exactly
  the hex it holds. Blue is `#3366D1`-ish with a light rim; red is
  cinnabar with a warm rim. In CLOSEUP, the equivalent is a flat hex ring on
  the ground.
- The formation **body** (the dense soldier cluster, `Registry.body()`) fits
  inside the hex. Banners and spears may rise above it; that is fine because
  they do not touch the ground.
- HP bar, count label and status icons belong to that unit and are stacked
  above its body. They never float into the neighbouring hex's ground.
- Units always draw above terrain, structures and fog. See section 14.

## 6. One city / stronghold / village = one hex

- Every structure draws **exactly one upright sprite on its anchor hex**, at
  most 44 px wide. The checker (`W8d`) fails on a second sprite.
- A **multi-hex logical footprint** is gameplay's business. Fortress Hulao and
  Capital Luoyang currently have 3-hex footprints for garrisons and assault.
  Presentation draws the keep on the anchor hex and treats the other footprint
  cells as plain ground (HIGH) or a stone apron (CLOSEUP). It must never draw a
  castle across several hexes.
- **Stronghold locations have one visual source:**
  `Step2RBattlefieldShell.stronghold_visual_specs()`. Both HIGH
  (`HexStructureCompositor`) and CLOSEUP (`_build_strongholds`) read it; do not
  hard-code coordinates in visual code. The checker (`R8`) verifies the specs
  agree with gameplay `Stronghold.get_anchor()`.
- Villages are one terrain-5 hex each. There is no spill-over into neighbours
  (the old "granary on the next hex" is retired).
- Stronghold name plates (`Step2RStrongholdBadge`) sit on the anchor hex.

## 7. Unit presentation

- Board art: `assets/units/formations/approved_v1/` (blue) and `…/enemy/`
  (red), chosen by `ApprovedAssetRegistry.unit(class, faction)`.
- Closeup: the same approved art as one card per unit, body normalised to a
  2.6 × 3.0 closeup-unit box (`CARD_BODY_H/W`), feet on the hex centre.
- Selection and hover states come from **static** redraws on state change: a
  gold arc on the board, a gold ring in the closeup. Nothing pulses except the
  selected-hex ground outline.
- Routed or dimmed units lower their alpha. Fortified units show stakes. Rest
  and fortify icons are cached 32 px medallions.
- Everything procedural about units (shadow, rings, HP bars, markers) is
  rasterised **once per key** and shared (`Step2RUnitRenderer._tex_cache`).

## 8. Terrain presentation

- Base ground is **batched hex polygon meshes per terrain role** (parchment,
  loess, faded grass, worn, lowland green, foothill, pass floor, marsh,
  river, mountain rock), sampled from the **terrain language v2** tiles
  (`assets/terrain/ground_v2/`, `Registry.base_path()`). There are no
  per-cell sprites and no large overlapping decals.
- The v2 tiles are 64 px, opaque, 2 texels per art pixel, and take their
  3-tone bands from the CLOSEUP ground (`closeup_ground.gdshader`), so a
  grass, rock, marsh or road hex reads the same in both modes. They replaced
  the `cohesion/approved_v1` ground and route sources, which are unfinished
  placeholder gradients (every role was the same green). Regenerate with
  `tools/battlefields/gen_terrain_language_v2.py`.
- Mountain hexes sit on **rock ground** (`MOUNTAIN_GROUND`), so a massif reads
  as a band from the commander view. Open ground varies in round,
  world-space patches of faded grass and drier loess (no straight seams).
- Roads and rivers are **continuous ribbons** from the adjacency masks
  (`HexRouteAutotiler`, `HexRiverAutotiler`). Roads use one light-tan dirt
  surface (the CLOSEUP road centre), a stony one into passes, and planks on
  bridges. Bridges sit exactly on road/river crossings.
- Map data must not put three mutually adjacent road cells anywhere except a
  3-arm Y junction: the autotiler joins every adjacent pair, so kinks and
  parallel roads draw as ladders (the battlefield generator checks this).
- Hex borders are faint, warm, and drawn at ground level under all upright
  art. There is a stronger umber lattice on visible hexes, a cool slate one on
  remembered hexes, and none on unknown hexes.
- Mountains in HIGH are **relief cards** (peaks, twin peaks, ridge humps,
  pass-wall crags, knolls) from one atlas (`assets/terrain/relief_v1/`), one
  card per mountain hex, drawn as ONE MultiMesh through the shared upright
  billboard material. They stand at their natural aspect like the trees. The
  SF3D diorama sprites drew as squashed, sheared slabs there because they
  were redrawn with stretch but no lean. FLAT keeps the approved layer;
  CLOSEUP keeps the approved peak cards. Pass corridors stay visibly clear.
- Everything above is **built once** (`BattlefieldHexVisualCompositor.build_all`).
  After that, only the light paths run: `refresh_fog`, `refresh_units`,
  `set_hovered` and `set_selected`.

## 9. Forest and vegetation language

- Board: compact in-hex trees and shrubs from the dressing atlas (MultiMesh,
  one shared material), forest understory on forest hexes, sparse dressing on
  plains. The understory is ONE vertex-coloured mesh rebuilt on fog change,
  never one canvas command per hex: per-hex polygons cost ~43 ms/frame on an
  all-forest map once it was explored. Keep the **unit clearance** (≈ 30–40 % of the hex radius) open on
  occupiable forest hexes.
- Closeup: forests are tall pixel-art pines and broadleaf cards that **block
  sight**. Scenery between the lens and a nearby unit thins into a
  see-through corridor, and scenery right at the lens fades.
- **Vegetation never moves.** No sway, no wind, no grass simulation, no
  per-frame vertex animation.

## 10. Structures, cities, strongholds

See section 6 for the one-hex rule. In addition:

- Board keep art: `fortress_keep_A` (fortress), `command_hall_A` (capital).
  Closeup cards: `fortress_keep_A`, `stronghold_cluster_A`.
- Structures stay visible over unexplored fog as known landmarks: faint
  silhouettes in the closeup, and above the fog layer (z 99) on the board.
  Unexplored non-objective structures are hidden.
- No procedural wall, moat or tower drawings. The retired hidden 3-hex
  procedural stronghold in `stronghold_renderer.gd` was removed deliberately.

## 11. Tactical fog language

| Fog truth (`Step5FogOfWar`) | Board (HIGH / FLAT) | Closeup |
|---|---|---|
| Visible | clear | clear |
| Explored (memory) | flat cool tint `(0.575, 0.625, 0.71, 0.47)` | desaturated, dimmed, cool (`cu_memory`) |
| Unexplored | opaque flat **ink** `VisualContract.FOG_INK` `(0.155, 0.165, 0.19)`, with a faint per-hex tone | the same ink plus a sparse static map hatch |
| Beyond reach | — | horizon fade into the same ink |

- It is **static**. There is no `TIME`, no noise clouds, no drifting mist, no
  volumetrics, no frontier wisps, and no mist banks.
- Known routes may show faintly through explored fog. Unexplored routes are
  concealed.
- Fog truth is read-only. Presentation never computes visibility.

## 12. Colour and atmosphere

- **Factions:** BLUE, imperial blue on navy (`COLOR_ALLIED_BLUE #386BB8`,
  footprint `(0.20, 0.40, 0.82)`). RED, crimson on cinnabar
  (`COLOR_ENEMY_RED #C7332E`, footprint `(0.80, 0.20, 0.16)`). **Gold** is for
  selection, HQ and highlights only.
- **Ground:** earth, loess and faded-grass families (`FAMILY_BASE_COLORS` in
  `hex_base_terrain_mesh.gd`). Rivers are a muted teal.
- **UI:** dark charcoal lacquer panels with thin antique-gold borders and
  silk-white text (`historical_ui_theme.gd`).
- **Atmosphere** belongs only to the HIGH projection's distance: a mild haze
  toward the enemy side, a sky band with far ridges, and outer woods. It is
  static and screen-cheap. The unknown is ink, not cloud.
- There is no bloom, no colour grading pass, and no vignette stronger than the
  existing 0.30-alpha corner darkening.

## 13. Asset orientation conventions

- **Authoring frame:** upright art is drawn **as seen by a viewer standing on
  the friendly side**: up is sky, down is ground contact, light from the upper
  left.
- **Board runtime:** the `Camera2D` is rotated by
  `PresentationOrientation.BATTLE_BLUE_NEAR_SIDE_YAW` (120°). Upright
  containers take `rotation = upright_rotation()` (= yaw), which cancels it.
  Offsets use `upright_vector()` / `upright_position()`. Ground-plane art
  (hex footprints, roads, bridge decks, fog) is **not** counter-rotated.
- **Perspective:** upright art is pre-stretched vertically by the live
  per-position factor (`PresentationOrientation.stretch_at_world` /
  `frame_at_world`) so it stands at its natural aspect after projection.
- **Closeup:** cards rotate about the vertical axis only (`closeup_card.gdshader`).
  Scenery may mirror **horizontally** per instance for variety; never
  vertically.
- **Anchoring:** every approved asset has measured `bounds`, `dense` (body)
  and `bottom_contact` in `assets/production_ingestion_v1/alpha_bounds.json`.
  Sprites anchor at their bottom contact, never at the texture centre.
- Checker `R4` fails on rotated, sideways or upside-down unit art and name plates.
  Checker `W8d` fails on multi-sprite or oversized structures.

## 14. Depth ordering

Board (2D canvas, higher draws later):

| z (global) | Layer |
|---|---|
| ≈ −5 … +5 | Compositor: base terrain 0, borders 1, routes/rivers 2, transitions 3, forests/peaks/dressing 4, structures 5 (relative to the compositor at −5) |
| ≈ 6 | Fog (`HexFogRenderer`, z 11 relative) |
| 8 | Envelope and route previews (`Step3EnvelopeRenderer`) |
| 16 / 20 | Step7 sector overlay / preview overlay |
| 37 | Stronghold name plates |
| 99 | Stronghold keeps in HIGH (absolute; above fog, below every unit) |
| 100–180 | Unit containers: `calculate_unit_z` sorts by **screen depth** (nearer = higher) |
| unit z + 150 | Count labels / HP bars in perspective (absolute), so a front formation never hides a label |

- Upright scenery inside a layer is sorted by `PresentationOrientation.screen_depth()`.
  Do not sort by world `y`, because the camera is rotated.
- Closeup: a real depth buffer with alpha-cut cards (`depth_draw_opaque`).
  Overlays use `render_priority`: unit ring 2, count label 4, floating text 5.

## 15. Camera principles

- **Friendly-side view:** BLUE is at the bottom, RED is at the top, and the
  friendly HQ sits bottom-centre.
- **HQ-anchored:** in HIGH and CLOSEUP the camera path is
  `anchor(zoom) + pan_offset`. Zoom pivots on the HQ, and WASD, drag, NEXT and
  reset act on the offset only. There are no hard-coded camera coordinates.
- **The opening frame is set explicitly at build time:** zoom first, then
  position, with a zero pan offset. There are no deferred re-clamps. An
  instant `focus_on` lands on the clamped target (no drift after load).
- Picking is the exact inverse of what is drawn (`PresentationProjection.screen_to_world`
  or the closeup ray-plane hit). Never pick with `get_global_mouse_position()`
  in a projected mode.
- Board zoom range: commander 0.43 to tactical cap 1.1, and closeup beyond it.

## 16. Performance budget

The visual layer must be close to free compared with simulation and AI.

- **Headless** (training, self-play, audits): `Mode.HEADLESS`. There is no
  projection, closeup, board compositor, formation texture loads, or terrain
  sprites. Measured on the battle shell: about **121–126 MB** static memory,
  ~560 nodes (sandbox) or ~1,000 (production map), and 7–9 processing nodes.
  The gameplay result is byte-identical to a fully presented run.
- **Windowed:** event-driven updates only. The only per-frame scripts allowed
  are listed in `VisualContract.PER_FRAME_ALLOWLIST`, and each early-outs when
  nothing changed. Uniform pushes are gated on camera changes.
- **Materials:** one shared material per kind (fog, billboard, dressing). Do
  not create materials per node or inline `Shader.new()` strings; shaders live
  in `.gdshader` files so they can be scanned.
- **Textures:** size runtime art to its on-screen size (see section 18).
  Today's 1024² formation canvases drawn at ~40 px are a known waste (see the
  handoff).
- **Overdraw:** no stacked translucent full-screen layers, no fullscreen
  particles, and no second copy of the world rendered only to be covered.
  HIGH already renders the world offscreen once for the projection, so the
  main viewport culls the raw world layers.
- Baseline cost (1920×1080, this machine, default map): CLOSEUP ≈ 3.1 ms/frame
  (GPU 1.9), HIGH tactical ≈ 4.4 ms (GPU 3.2), HIGH commander ≈ 3.4 ms
  (GPU 2.2), vsync off (terrain language v2, 2026-09-26).
- **Map content must not change the cost class.** All ten canonical
  battlefields, including an 80 %-forest map fully explored, stay at the
  frame cap in every mode. A map may add terrain, not draw calls: scenery
  goes into shared MultiMeshes or one batched mesh per layer.

## 17. Forbidden and discouraged (learned from this project)

- **Do not convert characters, trees or buildings to full 3D** (see `b3d/`,
  retired).
- **Do not use realistic volumetric or weather fog as tactical fog.** No
  drifting noise clouds, mist banks or wisps (see the retired `hex_mist_layer`
  and the fbm fog shaders).
- **Do not add continuous vegetation animation** (sway, wind, grass) by
  default.
- **Do not animate with `TIME` in shaders.** The only animation is the
  selected-hex pulse, driven by a script uniform.
- **Do not draw a stronghold across several hexes** or add a second close-view
  sprite for it. That was the old "close castle" crossfade at 3.2× presence.
- **Do not keep hidden legacy presentation nodes "for compatibility".** Hidden
  nodes still load textures and memory (one hidden node cost ~500 MB). Delete
  them, and record them in `VisualContract.RETIRED_SCRIPT_PATHS`.
- **Do not add a second authority** for camera, mode, orientation, yaw or
  stronghold location. Extend `PresentationOrientation`,
  `PresentationModeController` or `stronghold_visual_specs()` instead.
- **Do not add deferred camera fixes** (`call_deferred` re-clamps or re-framing).
  Fix the order of operations at build time.
- **Do not duplicate orientation maths.** BLUE forward is
  `PresentationOrientation.friendly_forward_world()`.
- **Do not let presentation read or write gameplay-only state it does not
  need**, and never let gameplay import presentation scripts (checker `S5`).
- **Do not light anything**, add real-time shadows, or use PBR materials.
- **Do not add per-frame `_process` for static art**, or `queue_redraw()`
  every frame.
- **Do not load art with absolute `D:/…` paths.** Use `res://` paths.
- **Do not bypass the checker.** If a rule must change, change the contract,
  the checker and this document in the same change.

## 18. How to create a new asset that belongs

1. **Decide the family and the mode:** board art (`assets/<family>/approved_v1/`)
   or a closeup-only card (`assets/closeup25d/`).
2. **Draw in the house style:** a dark 1 px outline, 3–4 tone cel shading,
   light from the upper left, a transparent background, and the **ground
   contact at the bottom**. Silhouettes should read at 40 px on screen.
3. **Size it to fit one hex:** the body must fit a 48 × 42 hex (units:
   ≤ 32 px wide body; structures: ≤ 44 px wide after presence). Tall parts
   may rise above the hex.
4. **Canvas and texture size:** keep the source canvas square and centred as
   the existing sets do. For runtime, prefer the smallest texture that holds
   the largest on-screen size (≤ 256 px for units and props, ≤ 512 px for
   structures), via import `process/size_limit`. Mipmaps stay on for board
   art.
5. **Register it:** ingest through `tools/ingest_approved_hex_assets.py`
   (byte-preserving, manifest-listed) so its `bounds`, `dense`,
   `bottom_contact` and `canvas` land in `alpha_bounds.json`, and add its stem
   to `ApprovedAssetRegistry`. Closeup trees are generated by
   `tools/visual_capture/make_closeup_sprites.py`.
6. **Use it through the registry** (`Registry.sprite`, `Registry.cropped`,
   `Registry.surface`), with shared materials.
7. **Verify:** run the checker (windowed) and take a capture with
   `tools/visual_capture/battlefield_capture.gd`. Compare it with the
   neighbouring art at commander, tactical and closeup range.

## 19. How to create a new map without breaking visual consistency

0. Battlefields are **data**. The ten canonical maps form the **RL set**
   `data/battlefields/rl_canonical_v1/<id>_<slug>.json`
   (`canonical_battlefield_v1`: terrain rows, river / bridge cells,
   strongholds, opening deployment; `SET_MANIFEST.json` pins their hashes).
   They are loaded by `scripts/battlefields/battlefield_catalog.gd` and
   selected by `Step2RBattlefieldShell.battlefield_id`, `--battlefield=<ID>`,
   or the DEV map collection window (`scripts/ui/dev_map_collection_panel.gd`).
   The production menu does not list them. Empty = the default map,
   unchanged. Future hand-built battlefields belong in their own set. They are authored in screen
   space (BLUE bottom, RED top) by `tools/battlefields/build_canonical_battlefields.py`,
   which also validates them (bridges, road ladders, footprints, HQs, one
   unit per hex) and renders previews.
1. Terrain comes from gameplay (`cell_data`: `HexCell.terrain`). Presentation
   derives everything from descriptors, so a new map needs **no visual code
   changes** if it uses existing terrain types.
2. Strongholds and cities: define them in gameplay **and** in
   `stronghold_visual_specs()` (id, role, terrain, anchor, footprint). The
   anchor must be a stronghold-terrain cell. Checker `R8` verifies this.
3. Keep the friendly HQ on the BLUE side so the HQ-anchored framing opens
   bottom-centre. Do not move the camera by hand.
4. Keep roads continuous through passes, and put bridges at road/river
   crossings only.
5. Do not add per-map shaders, per-map fog colours or per-map lighting.
6. Run the checker (headless and windowed) and a capture pass (section 20).

## 20. Checklist for every visual change

- [ ] Is it 2D or 2.5D, unlit, with no new 3D models or lights?
- [ ] Does one unit and one structure each stay within one hex, in both modes?
- [ ] Does upright art stand up at every zoom and in both modes, never
      sideways, upside-down or squashed?
- [ ] Is fog still flat ink and memory tint, with no weather?
- [ ] Is there no new per-frame work, `TIME` shader, particle or light?
      Is any new per-frame script added to `PER_FRAME_ALLOWLIST` with a reason?
- [ ] Does it use shared materials and registry textures, with no absolute
      paths?
- [ ] Does it add no second authority for mode, camera, orientation or
      stronghold location?
- [ ] Does gameplay stay byte-identical?
      (`tools/visual_contract/gameplay_equivalence_probe.gd` before and after)
- [ ] Does the checker pass headless and windowed?
- [ ] Was it checked in captures at commander, tactical and closeup range?
- [ ] Were retired paths added to `VisualContract.RETIRED_SCRIPT_PATHS`, and
      were this document and the contract updated?

---

## Appendix A: where things live (the one live path)

```
scenes/step2r_battlefield_shell.tscn           battle scene (all DEV/test scenes and self-play instance it)
 └ scripts/step2r/step2r_battlefield_shell.gd  gameplay shell; sets presentation mode, builds presentation
    ├ HexGrid (scripts/core/hex_grid.gd)       terrain DATA only here (legacy_presentation = false)
    ├ HexVisualCompositor                      the ONE board presentation (scripts/visual/hex_native/*)
    │   ├ base / borders / routes / macros / dressing / structures
    │   └ HexFogRenderer                       tactical fog (shaders/tactical_fog_*.gdshader)
    ├ EnvelopeRenderer (scripts/step3/step3_envelope_renderer.gd)  move / attack / route overlays
    ├ StrongholdRenderer (scripts/core/stronghold_renderer.gd)     stronghold name plates only
    ├ UnitRenderer (scripts/step2r/step2r_unit_renderer.gd)        unit nodes (also the roster source)
    ├ Camera2D (scripts/step2r/step2r_camera_controller.gd)        HQ-anchored board camera
    ├ PresentationProjection (scripts/visual/presentation_projection.gd)    HIGH re-projection (windowed)
    ├ BattlefieldCloseupView (scripts/visual/closeup25d/*)                  CLOSEUP (windowed)
    └ PresentationModeController (scripts/visual/presentation_mode_controller.gd)  HIGH <-> CLOSEUP
scripts/core/presentation_orientation.gd       static presentation state: yaw, mode, upright helpers
scripts/visual/visual_contract.gd              contract constants, allowlists, retired paths
```

The legacy campaign scene (`scenes/main.tscn` → `battle_map.tscn`,
`scripts/core/battle_map.gd`, `unit_renderer.gd`, `camera_controller.gd`) and
the Step-2 prototype (`scenes/step2_battlefield_shell.tscn`,
`scripts/core/step2_*`) are **dormant legacy**. Do not extend them; new visual
work goes into the path above.

## Appendix B: verification commands

```
# contract (headless: safe next to training; windowed: modes, camera, one-hex art)
Godot_v4.2.2-stable_win64_console.exe --headless --path <project> --script res://tools/visual_contract/visual_contract_check.gd
Godot_v4.2.2-stable_win64_console.exe --path <project> --script res://tools/visual_contract/visual_contract_check.gd -- --windowed

# gameplay must not change: run on the old and new tree, outputs must be identical
... --headless --script res://tools/visual_contract/gameplay_equivalence_probe.gd -- <out.json> 0

# cost: headless boot/memory/nodes; windowed per-mode frame + GPU time
... --headless --script res://tools/visual_contract/headless_cost_probe.gd -- <out.json> 0
... --script res://tools/visual_contract/perf_modes_probe.gd -- <out.json> 0

# screenshots of every mode
... --script res://tools/visual_capture/battlefield_capture.gd -- <out_dir> <tag>

# canonical battlefields: build + validate data, headless smoke, per-map captures, layer cost
python tools/battlefields/build_canonical_battlefields.py --preview-dir <dir>   # --check: verify the frozen set
... --headless --script res://tools/battlefields/battlefield_smoke_probe.gd -- BF04 <out.json>
... --script res://tools/battlefields/battlefield_canonical_capture.gd -- BF04 <out_dir>
... --script res://tools/battlefields/battlefield_layer_cost_probe.gd -- BF03 <out.json>
```
The contract checker boots every canonical battlefield after the default
checks (runtime + R8 headless; also the W framing / one-hex checks windowed).

When training or other Godot processes may be running, run these against a
**copy of the project with its own `config/custom_user_dir_name`** so logs,
`user://` and the import cache are not shared.
