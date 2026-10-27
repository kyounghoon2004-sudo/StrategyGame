# Local DEV visual integration — 2026-10-27

Code imported from `a845e8b4481ff36b60088158c6ddcc7df8d758d9` and handoff inventory from `d69b621`. The existing master worktree and unrelated uncommitted changes were preserved. The two DEV worlds are separate from the live battlefield and tutorial missions.

## Data and integrity

- Received `D:/Game development/StrategyGame_DEV_Visuals_2026-10-27_125804.zip`: SHA-256 `940302243c290549596edd11da991cf199bf27f7bdd7b5ad51d112eefacf301e`, matching the supplied checksum.
- Extracted into `D:/StrategyGame_Transfer/package`; all 4,602 entries listed by the transfer manifest were checked against size and SHA-256 while extracting. The 133 original inventory items independently matched.
- Runtime outputs are a separate copy in `D:/StrategyGame_Transfer/runtime_outputs`. The source package remains separate. Of 1,816 packaged asset files, 1,531 match existing project paths and 285 have no project counterpart; no project assets were overwritten or copied.
- Set `SG_VISUAL_OUTPUT_ROOT` to the runtime outputs directory. `SG_FULL_MAP_OUT` can override its `full-map-lab` subdirectory. A scoped resource loader resolves the producer's absolute unit texture dependencies without altering source `.res` files.
- Local launchers: `D:/StrategyGame_Transfer/Open_Candidate.cmd`, `Open_Baseline.cmd`, `Open_Game_With_Visuals.cmd`. The last supplies the environment to the main game so its DEV collection buttons can find both worlds.

## Runtime checks and limits

Godot 4.2.2 Forward+ with the RTX 5090 Laptop GPU loaded the baseline and candidate. The baseline reported 4,921 cells, 25 original ranges, and 56 formations. The candidate reported 12 castles, 7 building kinds, 56 formations and 25 exhibition massifs. The 9 unit mesh/LOD resources and their texture dependencies were loaded separately. Camera-matched screenshots are under `D:/StrategyGame_Transfer/review-final/`, with the baseline at `review-baseline.png` and the producer reference under `package/outputs/scenery-scale-massif/renders/`.

The original road junction outlines self-crossed at 18 of 67 junctions. The integration uses convex fallback surfaces for those cases and checks tree clearance against the fallback footprint; this changes the shape of those junctions. Inspect them visually before approving their appearance. Horse and dog scene owner consistency warnings remain. Automated M-key handler/LOD checks and screenshots do not replace a human's interactive inspection or a full visual approval. The 25 new massifs remain in the separate eastern exhibition, not in the actual battlefield. No tutorial M1–M5 tests were run and no mission/rule/balance files were changed for this integration. No performance claim is made.
