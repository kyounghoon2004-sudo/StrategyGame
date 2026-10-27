# Local integration status (2026-10-27)

The DEV visual implementation was taken from `a845e8b4481ff36b60088158c6ddcc7df8d758d9`; the cold prompt and asset inventory were taken from `d69b621`. Existing master menu behavior was retained while adding the original and candidate DEV entries. No mission, tutorial, rule, level, or gameplay changes were imported.

This PC does not have the original producer path `C:/Users/User/Documents/Codex/2026-10-18/strategygame-godot-4-2-2-repo/outputs/scenery-scale-massif`. The inventory records 108 GLBs and 25 rock JSON files, not transferred assets. Six original water GLBs exist in this checkout; other original and derived dependencies have not been fully verified. Runtime and visual acceptance remain blocked until the files are available.

After receiving the entire producer `outputs` tree and required original assets, verify the 133 inventory items and locate missing output directories with:

    python tools/dev_visual_lab/check_transferred_scenery.py <absolute-path-to-outputs>

This is a file and directory check, not a full dependency or rendering test. The source still contains producer-specific paths across the launch entry and several DEV scripts. `SG_FULL_MAP_OUT` alone does not make the candidate portable; adapt and validate those paths for the actual transferred layout before launch. Then load both worlds with Godot 4.2.2 and inspect the actual interactive render, including castle/HQ/village, roads, and the M-key 25-massif exhibition. Do not infer production battlefield placement or visual approval from code import.
