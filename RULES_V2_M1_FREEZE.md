# Rules V2 — M1 freeze: what you may and may not touch

Date: 2026-11-04. M1 (`EDITOR_M1`, River Roads) is judged **functionally complete** by the user. The next person will debug and
optimise it. This file says what is allowed. When in doubt: **do not change behaviour or looks; only make the same thing cheaper.**

Run copy: `D:\Game development\Demon slayer\StrategyGame_opt` (full runnable copy). Snapshot overlay: `...\StrategyGame_M1_snapshot`
(`_original_HEAD/` = pre-V2 versions of the shared files). Longer notes: `RULES_V2_SPEC.md`, `handoff_rules_v2.md`.

## 1. GREEN — free to change (must keep output identical)
Performance work whose result is unchanged (same numbers, same pixels, same tests passing):
- Per-frame loops: `civ_battlefield_view.gd` `_sync_fog_of_war` / `_visual_fog_recalc` (shadow fog every frame), `_sync_units`, `_sync_ghosts`,
  `_sync_tree_clearing`, `_sync_wading`, `_sync_morale_ring`; `v2_artifact_layer.gd` `_sync`, `_layout_clusters`, `_layout_banners`;
  `v2_overlay.gd` redraw; `v2_unit_card.gd` / `v2_action_panel.gd` (redraw only on change).
- Shader cost: `civ_shroud.gdshader` (screen + depth reads, noise loops, 4-tap lookups), `v2_hq_focus.gdshader`.
- Caching, pooling, lower update rates **only if the visible result is the same**; lazy creation; avoiding `queue_redraw` every frame.
- Bug fixes (crashes, input getting stuck, leaks). Add tests. Add comments / notes.

## 2. YELLOW — only with the user's OK (changes what the player sees or how the game plays)
- Any number in `scripts/rules_v2/rules_v2.gd` (ATTACK / MOVE / RANGE, DAMAGE_SCALE, HP_FLOOR, morale and supply constants, XP, HP).
  Current decided values: attack conscript 7, infantry 10, spear 15, archer 10 (range 2), cavalry 12, scout 3, hq 6;
  move conscript/infantry/spear/archer 2, cavalry 4, scout 5, hq 3.
- Supply rules (`supply_v2.gd`): lines start at bases, link 10 / edge_link 10, HQ line, base HP 80, zones near 3 / normal 6.
- Fog rules: remembered terrain look (ink-on-paper), half-blur removal, continuous fade, ghost (last-known) enemies.
- Movement rules: base MP is the whole budget (no over-run), unseen terrain planned as flat, rivers crossable only with full MP and never stood on, mountains impassable.
- All UI looks the user fixed by hand: unit card (parchment, hex portrait, sizes, fonts 18-26), action buttons and icons, tooltip (solid black, 15 px),
  morale ring (3 arcs, green/yellow/red, clockwise drain), HQ supply ring (cyan), village banner (name plate, grey HP arc), badge size/position (`"top"`, `badge_mult`),
  zoom limit `ZOOM_MIN 1.6`, camera pitch 47/35, white unit/structure icons.
- `m1.json` data (units, positions, scenario.rules_v2 supply config, strongholds + `name_kr`) and the baked map `EDITOR_M1.scn`.

## 3. RED — do not touch
- **Legacy / other tracks:** everything outside V2 behaviour. All V2 code is gated by `RulesV2Cls.enabled` (`scenario.rules_version == "v2"`); do not remove the gates or
  change the legacy branch behind them. Do not touch `scripts/cloud_pipeline/`, `tools/cmd_rl/`, `tools/synth_adv_v1/`, Bolt/Nemotron/RL docs, `python_jev/`, `python_sim/`,
  `scripts/sim/sim_rules_fingerprint.gd`, step4 evidence generators / `verify_step4r*.gd`, openjev / utility-bot enumerators (they still assume over-run and old ranges).
- The map editor and its tools (`tools/dev_visual_lab/`, `scripts/ui/dev_*`), and the user's source maps in `D:\StrategyGame_Transfer\maps\`.
- `assets/` originals: do not overwrite `assets/ui/v2_icons/_painted/` or the 3D asset library. White icons are generated from them (`tools/rules_v2/cut_icon_sheet.py` + the whitening step).
- Do not re-derive the M1 map from the editor file or rotate it again: G(q,r) = E(-q,-r), 180 degrees, is baked in `m1.json` and `EDITOR_M1.scn`.
- Do not "fix" things the user explicitly asked for in a certain way (e.g. archers have no counter at range 2, banner stays above badges, no hotkeys, no sound).
- Do not change the `RulesV2Cls.known` / `_fow_ever` sharing: movement planning must know exactly what the screen has shown.

## 4. Rules for any change
1. Work in `StrategyGame_opt`, not in the original.
2. Syntax-check what you edit: `Godot_console.exe --headless --path . --check-only --script res://<file>.gd` (a timed-out check is NOT a pass).
3. Run the tests below; all must report 0 failures before and after.
   - headless: `tools/rules_v2/test_rules_v2.gd`, `test_move_cap.gd`, `test_move_rules2.gd`, `test_hq_link.gd`, `test_hq_hud.gd`, `test_supply_range.gd`
   - windowed: `test_village_walk.gd`, `test_fog_artifacts.gd`, `test_fog_follow.gd`, `test_banner_hover.gd`, `test_idle_freeze.gd`, `test_auto_next.gd`, `live_click_test.gd`
4. For anything visual, capture before/after (`tools/rules_v2/shot_*.gd`) and compare; the user is the judge, not the numbers.
5. Measure first (frame time, draw calls) and record the numbers; do not "optimise" by guessing.

## 5. Known gaps (not bugs you introduced)
- Promotion / wading / archer-range animations and the unit-card / banner changes of the last session were never verified in game.
- Red AI does not raid, promote, fortify or use archer range. `python_sim` is out of parity. M2-M5 not converted (M2 partly).
- `data/baked_maps/EDITOR_M1.scn` (70 MB) is gitignored: regenerate with `tools/rules_v2/bake_editor_map.gd` or copy it from the snapshot.
