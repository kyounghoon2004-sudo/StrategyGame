# Rules V2 spec (draft, 2026-10-31) — decisions from the grilling session

Scope: M1–M5 tutorial battlefields first. GX / LLM commander ignored for now.

## Units
- Tree (Civ-style upgrade branch): 민병대(conscript) -> 일반병(infantry) -> {창병(spear) | 기병(cavalry) | 궁병(archer)}.
  - Spear is kept as a 일반병 variant (third branch).
  - Siege: not decided (dropped from tree; check M4/M5 rosters).
- Scout: 2 fixed per mission, spot-only (vision 4, fast, weak attack), no tree, no XP.
- HQ: moves like cavalry (3 MP), weak fighter with own HP, loss = defeat / kill = victory (as now).
- Stats per unit: HP, attack, move only. No defense stat, no type matchups (combat_calculator matchup table removed).
- Red follows the same rules (symmetric, 2 scouts per mission).

## Promotion
- Earned by combat XP. Player triggers it (ready flag, click to promote). Branch chosen at 일반병 -> branch step.
- Promotion only while supplied (unsupplied units cannot upgrade).
- XP thresholds: TBD (balance).

## Combat
- Attacker deals damage = attack (scaled by morale and supply). Adjacent defender counterattacks. Archers range 2–3, no counter.
- HP only (no troop count). Figures in a hex die off one by one by HP band; per-class figure counts already exist in the asset library (reuse, do not invent).

## Terrain / forts
- No terrain defense bonuses. Mountain = impassable. Hills removed (convert hill -> plains in M1–M5 maps, diff for choke points).
- Forest: slower movement, denser fog only.
- Fortifications (요새화) are buildings with their own HP.

## Fog of war
- Existing system kept (vision 2 / scout 4, LOS). Forest makes fog denser. Exact LOS rules for forest: TBD.

## Supply
- HQ places supply bases (nodes) on hexes; each auto-links to HQ / previous node. Roads are not destroyable; only the bases built by HQ can be destroyed/raided.
- Node stock fixed per mission; replenished by plunder: town gives ~+3 (tune). Raid takes 1 extra turn and is cancelled if the raider is attacked (even if not killed). Destroy is immediate.
- Radius around HQ and every connected node (scales with map size): near / normal / out.
  - near: HP and morale recover. normal: morale held. out: morale decays gradually.
  - morale <= 66%: attack and move reduced. morale <= 33%: probabilistic desertion.
- HQ node placement cost vs move: TBD (the user chose "nodes cost resource"; placing consumes stock, move-cost unspecified).

## Order of work
1. Rewrite core rules (units, combat, supply, fog, HQ) in code and python_sim.
2. Convert M1–M5 map terrain; rewrite rosters; import unit assets from the asset library.
3. Make M1 playable, balance, then M2 -> M5.

## Open questions
- Siege fate; XP numbers; supply radii per map; HP/attack numbers; exact plunder yields; HQ node-placement move cost; town definition in map data.

## M1 implementation status (2026-10-31)
- Opt-in per map: scenario.rules_version = "v2" (only M1). Code: scripts/rules_v2/{rules_v2,supply_v2}.gd, hooks in combat_calculator, step3_config (HQ move 3, mountain impassable), step3_unit_manager (end_turn tick, XP, promote, base API), shell (keys B base, R raid, K destroy, P/O/I promote; red drops a base when HQ has none within 2 hexes).
- Tests: tools/rules_v2/test_rules_v2.gd (27 checks pass), run_m1_headless.gd (6-round run), shot_m1.gd (windowed capture, tools/rules_v2/shots/m1_v2.png).
- Not done: supply zone/base overlay graphics, promotion menu UI (keyboard only), red raiding/promotion AI, python_sim parity, M2-M5.

## Maps and structures (2026-10-31, from user)
- M1-M5 = the five map_*.json in D:/StrategyGame_Transfer/maps (opened in map_editor.gd). The 9x9 tutorial_v1 M1 used for the first V2 run is NOT the designed map; V2 must be rebuilt on the designed maps. Editor maps are visual-only (ground + objects, radius 20 for M1); gameplay (terrain, rosters, structures) must be derived from them.
- Structures (city / fortress / village) get an Civ-style icon above HP and armor bars. Types and HP derive automatically from map objects (castle_v1-4, buildings, gates/forts), overridable per map.
- Icon: border = owner color; when a unit stands in the hex a side badge slides out showing the occupier (class + color); neutral = grey.
- Protection: damage is split between the structure HP and the units inside (units wear down while walls hold). Ownership flips when structure HP is 0 and an attacker occupies the hex.
- Supply line: yellow line along shortest hex path, narrowing toward max length. Base building: reuse an existing building asset arranged on a small hex.

## M1 on the designed map, round 2 (2026-10-31)
- Game map = editor map rotated 180 deg (G(q,r)=E(-q,-r)) so the village is at the bottom next to blue HQ; baked scene (data/baked_maps/EDITOR_M1.scn, tools/rules_v2/bake_editor_map.gd) is rotated to match. Generator: tools/rules_v2/gen_m1_gameplay.py.
- Mission: blue defends the village hall (blue HQ just south of it); red attacks from the north edge. Same rules for both sides.
- Supply: each side has 2 fixed edge bases on the map edge nearest its HQ start, joined to the HQ start by fixed lines; nobody can destroy/raid them; every line hex is a supply source. HQ-placed bases auto-link to the nearest source.
- View: baked maps use the 3D animated civ3d view (civ_battlefield_view) with a transparent overlay plane (civ_designed_overlay.gdshader) for grid, selection and the 2D V2 overlay.

## M1 round 3 (2026-10-31)
- Structure hexes are ordinary walkable hexes under V2 (Civ 6 style): a unit just moves onto the village; unit and structure both exist and the structure icon stays (owner border, occupier badge). No garrison-enter step, nobody starts garrisoned.
- A hit on a unit standing on a structure splits: half goes to the structure HP (x7 wall multiplier), half to the unit (RulesV2.FORT_STRUCT_SHARE). The empty-structure assault keeps the full wall hit. Owner flips at turn end when structure HP is 0 and a hostile unit stands on it (HP restored to 25%).
- The 2 fixed edge supply bases sit ENTRY_SPACING=5 ring hexes either side of the HQ's foot point on the board edge (10 apart).
- Tests: tools/rules_v2/test_village_walk.gd, test_rules_v2.gd.
- (round 3b) No garrison concept under V2: slots 0, nothing garrisons, structure click path (stronghold panel / garrison enter) is bypassed - the village hex is an ordinary hex for select/move/attack. Only an empty, intact, enemy-owned structure takes the assault click. Fixed: execute_player_stepwise_move used to stop at structure hexes ("contact_kind stronghold"); execute_move and init no longer block/garrison. Test: tools/rules_v2/test_village_walk.gd (click out, click back in, split damage, capture).
- (round 3c) Action bar logic: 휴식 = unit untouched this turn -> +REST_HEAL_FRAC (15%) HP unless out of supply, +12 morale, ends action; 대기 = ends action on guard; 건설 (HQ only) = builds a supply base where it stands, uses up the HQ's action. Raid/destroy/promote also end the action. Root cause of "buttons do nothing": the shell's click guard only knew the old HUD layer, so clicks on the V2 bar hit the map and deselected the unit; fixed in _is_click_over_hud. Tests: real mouse-click tests in test_village_walk.gd.
- (round 3d) Supply lines only appear when built: the 2 edge bases are always visible/untouchable, but their lines exist only after the HQ builds its FIRST base - each edge base then connects to that base (edge_link=10 max reach for the first base). Later bases auto-link to the nearest connected source (link=6). Before the first base the HQ carries its own supply radius. Line width = lerp(7px, 2px, length / max length) per link (longer = thinner).
- (round 4) Action bar = 휴식 (무방비) / 턴 스킵 / 요새화 (1회).
  - 휴식: only inside the healing (near) radius, untouched unit; ends its action, +15% HP, +12 morale; during the next enemy phase it cannot counter in melee ("rested_this_turn" -> no counter in RulesV2.calc). Marker "ZZZ 무방비".
  - 턴 스킵 = the old 대기: ends the action in place, counter works normally.
  - 요새화: once per unit per game (fort_used), untouched unit only, not HQ/scout. Gives a wooden palisade with its own HP (RulesV2.FORT_HP=120); hits split half to the palisade, half to the unit; counters still work. Moving off drops it (the one use stays spent). Visual: 6-sided ring of the existing 01-wooden-palisade-wall asset (scripts/rules_v2/v2_fort_layer.gd) rising segment by segment while the soldiers play their strike clip (civ view v2_play_work); segments drop away as HP falls; sinks when broken/abandoned.
- (round 4b) 휴식 disabled-reason is shown in the action bar ("HQ 치유 반경 밖") and the healing radius (near zone around the HQ / lines / edge bases) is tinted green on the map while a blue unit is selected. tools/rules_v2/live_click_test.gd = windowed end-to-end click test of the three buttons.
- (round 4c) 요새화 visual: palisade ring now reaches the hex edge (RING_R 23) and is 1.6x taller; a separate billboard badge (owner-coloured disc with a stake-fence glyph + its own HP gauge) stands in front of the wall (toward the player), redrawn when the palisade HP changes; the flat 2D bar was removed.
- (round 4d) 턴 스킵 raises no dust: the 3D view treated every floating text as a hit (impact burst + flinch); now only damage numbers ("-N...") do. 휴식: the unit's men lie on their backs one after another (Formation3D.set_resting), dogs slump, a stream of Z/z rises (civ view v2_set_resting), driven from rested_this_turn by V2FortLayer; they get up when the flag clears at the next turn start. 요새화 is refused on the village / any structure or town hex. Test: tools/rules_v2/live_click_test.gd.
- (round 4e) 요새화 keeps the trampled-dust bursts (liked): civ view v2_fortify_dust fires BattleFx.impact at the unit and round the ring a beat apart as the palisade rises. 턴 스킵 / 휴식 stay dust-free.
- (round 5) Artifacts: 병참기지 now has its own HP (RulesV2.BASE_HP=80); an adjacent enemy attacks it from the action bar ("기지 공격 (HP n)", damage x BASE_DMG_MULT 2.0, no counter, ~3 hits), the instant "기지 파괴" button is gone, 약탈 stays. Every base (incl. the 2 edge bases) has a 3D depot model assembled from the existing building assets (granary + house + workshop + short palisade + owner banner; edge bases add a timber watchtower). Structures and bases share ONE icon style (owner-coloured ring + glyph) drawn by scripts/rules_v2/v2_artifact_layer.gd; several artifacts on one hex (village + base + occupier) are laid out side by side in one row. Palisade HP gauge, base/structure HP bars and supply lines show only on hover and stay pinned by a click (click again or an empty hex to unpin); supply lines: a hovered base shows the chain feeding it, an edge base / the selected HQ shows the whole network. Hand-drawn glyphs: drop PNGs into assets/ui/v2_icons/ (names in V2_ICON_COLD_PROMPT.md); they replace the procedural glyphs automatically.
- (round 5b) Icons are screen-space (same layer as the unit badges): the row of artifact icons sits BESIDE the unit standing on that hex ([icons][unit badge]; the badge is pushed sideways via civ view v2_badge_shift), centred alone on an empty hex. The generic "occupier" disc is gone (the unit's own badge is the occupier). Only HQ-built bases get an icon; the 2 edge bases keep a model but no icon (hover/click one to see its network). Enemy artifacts (models, icons, hover) exist only on hexes the fog of war currently shows. Icon PNGs in assets/ui/v2_icons/ are hot-reloaded and auto-prepared (magenta + flat corner background keyed out, margins trimmed, padded square) - see the folder README. Tests: tools/rules_v2/test_fog_artifacts.gd, live_click_test.gd.
- (round 5c) Icon PNGs are in: the 8 glyphs were cut from the user's sheet (tools/rules_v2/cut_icon_sheet.py) and are drawn inside the same round disc + owner ring as before (icon size 52 px, glyph 80% of it). Merge fix: an icon row beside a unit now needs the unit LOGICALLY on the hex AND its formation VISUALLY within 0.9 units of the hex centre (it is still walking otherwise); the row then eases next to the unit badge (blend 0->1 in ~0.2 s).

## M2 (2026-11-01, grilling decisions)
- Role: **neutral gate fort contest** - nobody owns the fort at start. Capture = victory; HQ loss still ends the game. Round limit 30 (provisional).
- Blue starts at the village (bottom of the screen), red marches in from beyond the mountain belt (top). Measured march: blue HQ->fort 12 hexes, red HQ->fort 15.
- No terrain diff: the west flank stays open (user decision "leave it, the detour is the point").
  **Measured caveat:** blocking the fort + its 6 neighbours changes the village-to-north distance by 0 for 587 tested cells; only 73 cells (NE tip, q 1..9 / r -19..-7) actually need the fort. Today the fort is an OBJECTIVE and a strongpoint, not a chokepoint. Making the detour real needs a ~12-16 hex mountain diff AND the same change in the source map, otherwise the baked scenery and the walkable terrain disagree. Open item.
- Roster 8 vs 8, symmetric: HQ 300, 3 conscripts, 1 spearman, **1 archer (first ranged unit)**, 2 scouts.
- Structures: gate fort E(4,1)->G(-4,-1), **450 HP, owner neutral, 0 slots**; village hall E(10,7)->G(-10,-7), 300 HP, blue. The other 7 village house cells are decoration.
- Hills removed: the 14 hill cells become plains, and the hill scenery is skipped at bake time so visuals match walkability.
- Supply config identical to M1 (near 3 / normal 6 / link 6 / stock 4 / 2 edge bases / edge_link 10).
- Baked scenes are generated locally and gitignored (M1 70 MB, M2 35 MB).

### Orientation (measured, 6 rotations scored in screen space)
Camera yaw is fixed (PresentationOrientation.BATTLE_BLUE_NEAR_SIDE_YAW = 120 deg => +q is screen up), so the DATA rotation decides the view. Scoring (village y / red y / mountain-belt angle, y+ = down):

| k | village | red | belt |
|---|---------|-----|------|
| 0 | y -439 | y -352 | 4.8 |
| 1 | (508,-2) | y -709 | 65.3 |
| 2 | (252,436) | (618,-357) | -54.4 |
| **3** | **(-256,439)** | **(615,352)** | **4.8** |
| 4 | y -508 | y 709 | 65.3 |
| 5 | (-252,-436) | (-618,357) | -54.4 |

k=3 is the only orientation with the village at the bottom AND the belt horizontal. It is exactly the 180 deg rotation M1 already uses (G(q,r)=E(-q,-r)), so M2 reuses the M1 pipeline unchanged and the fort lands in a gap of the belt.

**Coordinate trap:** the stored (q,r) are odd-q OFFSET (HexUtils), not axial. Distances must go through offset_to_axial; the axial max() formula gives wrong answers on this map (8/10/31 instead of 9/12/15).

### M2 implementation (2026-11-01)
- Data: tools/rules_v2/gen_m2_gameplay.py (idempotent; rotates 180, hills->plains, neutral fort, hall, archer rosters).
- Bake: tools/rules_v2/bake_editor_map.gd --skip-hills. Needs SG_VISUAL_OUTPUT_ROOT=D:/StrategyGame_Transfer/runtime_outputs (the editor's fallback path C:/Users/User/Documents/... does not exist on this machine).
- Tests: tools/rules_v2/check_m2.gd (17 data checks), tools/rules_v2/test_m2_fort.gd (9 checks: neutral fort targetable by BOTH sides, 95 wall damage per assault => 5 hits on 450, capture flips the owner at turn end when a unit stands on the 0-HP fort).
- A shell-level headless boot of EDITOR_M2 hangs after the scene loads (no script error; M1 scripts use the same pattern), so M2 rules are verified at the Step3UnitManager layer.

## HQ focus / supply display (2026-11-01, all V2 maps)
Applies whenever `scenario.rules_version == "v2"` (M1, M2, and M3-M5 when they land).

### HQ click = Civ-prophet framing
- Selecting an HQ draws a **morale-delta heatmap** of its influence: green inside the healing radius
  (`supply near`, +10 morale), fading green out to the normal radius (morale held, 0), with an amber
  ring where morale stops being held and starts to decay. Colour only, no per-hex numbers.
- The rest of the battlefield is **desaturated + dimmed** (one fullscreen pass; `desat 0.85`, `dim 0.30`,
  soft feather at the radius). Enemies stay readable as silhouettes because the dim is shallow.
- Radii are the supply radii from the map's own `rules_v2.supply` (near 3 / normal 6), never a second
  tuning variable.
- Implementation: `scripts/rules_v2/v2_overlay.gd` (heatmap + radius) drives
  `scripts/rules_v2/v2_hq_focus.gd` + `v2_hq_focus.gdshader` (CanvasLayer 6 - above the board and unit
  badges at layer 5, below the HUD at 30/40, so the interface never greys out). Fades in 0.22 s, out 0.16 s.
- Shader gotcha: `uniform vec2 x : source_color` does not compile (source_color is vec3/vec4 only); the
  failed shader filled the screen and every capture came out near-solid.

### Supply lines no longer wait for a built base
- `SupplyV2.fixed_paths()` used to return empty until the HQ built its first base (round 3d), which hid
  the whole network. Now an edge base links straight to the HQ **whenever it is inside `edge_link`**, and
  building a base only re-points the lines at the first built base.
- Measured on M1: the two blue edge bases sit 8 and 5 hexes from the HQ (edge_link 10) -> both connect on
  turn 1. `setup_fixed` therefore stores the HQ hex in `fixed[faction]["hq"]`.
- Line thickness is now distance-based instead of per-path: **10 px where it leaves a base, 3 px after 5
  hexes**, then a slow fade to a 1.2 px floor (`V2Overlay.link_width`). Segment-by-segment drawing.
- Tests: `tools/rules_v2/test_hq_hud.gd` (10 checks: auto-link, out-of-range stays dark, taper values).
  `test_village_walk.gd`'s old "no supply line before anything is built" assertion was updated.
- Capture harness: `tools/rules_v2/shot_hq_focus.gd` (HQ selected, then with one built base).

#### Correction (2026-11-01, after play-testing)
- The first two attempts drew the bands in the 2D canvas and then tried a screen-space lattice. Both drift
  against the board: the map is a PERSPECTIVE 3D render (`cam.unproject_position`), not an affine 2D canvas,
  and a single screen basis breaks as soon as the player zooms.
- Final design: `V2HqFocus._draw_bands()` projects **every hex corner** through the 3D camera
  (`Vector3(px * 0.1875, 0, py * 0.1875)`), so the bands sit on the board hexes at any zoom.
- The blur is one pass on `CanvasLayer -1` (2 px, 9 taps, desat 0.35): it softens the battlefield only, and
  badges (layer 5), supply lines, bands and the HUD stay crisp. Redraw happens only when the camera changes
  (transform/fov/viewport signature), not every frame.

## Over-run (강행군) scrapped (2026-11-03, user decision) — V2 maps only for now
- Decision: base MP is the whole movement budget. No ORANGE/RED tiers, no UNGUARDED state from moving, no river-crossing
  penalty/forced stop. Applies to V2 maps (EDITOR_M1~M5) only; legacy battlefields and the Bolt/RL pipeline keep over-run.
- Clicking a hex outside the reach does nothing (no path preview, the unit stays selected). The white reach outline is the
  whole truth.
- MP left is spent over several moves in the same turn (reselect and continue), as before.
- Expensive terrain: with MP left, ONE adjacent hex is always enterable (the excess just empties the MP); nothing can be
  reached through it.
- Code (all gated on `RulesV2.enabled`): `Step3Config.get_max_additional_budget` / `classify_march_by_cumulative_cost`,
  `Step3Pathfinding.calculate_envelope` (first-step exception), `Step3UnitManager.execute_move` and
  `execute_player_stepwise_move` (cap, GREEN only, no river stop), shell `_handle_hex_click` (no-op out of reach).
- Test: `tools/rules_v2/test_move_cap.gd`. `test_village_walk.gd` now steps to an ADJACENT hex (it used to rely on over-run).
- **To apply to the whole game later**: drop the `RulesV2Cls.enabled` gates above (or make them a ruleset flag), then
  re-baseline: `sim_rules_fingerprint.gd` (`forced_march_extra_turns`), Step4 evidence generators / `verify_step4r*.gd`
  (forced_march contracts), `python_sim` movement budget, openjev / direct / utility-bot legal enumerators (they call
  `calculate_envelope`), shell UNGUARDED labels, and the RL data that contains forced-march actions.

## Balance patch (2026-11-04, user decisions)
- Attack / move: conscript 7/2, infantry 10/2, spear 15/2, archer 10/2 (range 2), cavalry 12/4 (user, 2026-11-04: spear 15, cavalry 12), scout 3/5, hq 6/3.
- Archers hit up to 2 hexes away (`RulesV2.RANGE`, `CombatCalculator.get_attack_range`); the damage calc only counters at distance 1,
  so a shot from 2 hexes draws no counter. Applies to every V2 map (M1~M5); one table, no per-map override.

## Map orientation (2026-11-14, user decision — overrides any earlier wording)
- The map editor view is the map's orientation: north = top, south = bottom of the editor view.
- The player (blue) ALWAYS starts at the south edge. See docs/MAP_ORIENTATION.md (with reference picture).
- The `G(q,r) = E(-q,-r)` import rotation is a coordinate change for the game camera only; the game picture
  must match the editor picture (blue at the bottom).
