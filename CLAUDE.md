# StrategyGame — standing rules

- **Map orientation (user decision, 2026-11-14):** the map editor view is the map's orientation.
  North = top of the editor view, south = bottom. **The player (blue / 아군) always starts at the south edge.**
  Full rule and reference picture: [docs/MAP_ORIENTATION.md](docs/MAP_ORIENTATION.md).
- **Mountains are range25 only** (`SG_VISUAL_OUTPUT_ROOT/mountain-range-25`). massif25, the source rock
  mountains and the hex-kit hills are not mountains and are not used.
- Current rules are Rules V2 on branch `rules-v2-m1` (RULES_V2_SPEC.md): no type matchups, HP / attack / move.
- Visual assets live outside git: `assets/` (gitignored) and `SG_VISUAL_OUTPUT_ROOT`
  (`D:/StrategyGame_Transfer/runtime_outputs`). Map editor saves go to `SG_MAP_EDITOR_DIR`
  (`D:/StrategyGame_Transfer/maps`). Backups: Google Drive `zip/StrategyGame_DEV_Visuals_2026-10-27_125804.zip`.
