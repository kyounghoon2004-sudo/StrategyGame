# DEV visual map editor: people and agent handoff

This is a separate authoring document, not a production battlefield, mission, or gameplay map. It uses the transferred DEV candidate assets; it does not change the existing reference or candidate worlds.

## Start and controls

On this PC run `D:/StrategyGame_Transfer/Open_Map_Editor.cmd`. From the main title, the DEV map collection also has `맵 만들기 — 경관 배치 · 저장` when the process is launched with `SG_VISUAL_OUTPUT_ROOT` set to the transferred runtime outputs. To run directly:

```powershell
$env:SG_VISUAL_OUTPUT_ROOT = 'D:/StrategyGame_Transfer/runtime_outputs'
$env:SG_MAP_EDITOR_DIR = 'D:/StrategyGame_Transfer/maps'
& "$env:LOCALAPPDATA/Programs/Godot/Godot_v4.2.2-stable_win64.exe" --path 'D:/Game development/Demon slayer/StrategyGame' --script res://tools/dev_visual_lab/map_editor.gd
```

Choose 숲, 산괴, 성곽, or 건물 on the right, click a model thumbnail, then click a hex to place. The active card has a gold border; scroll the palette to see all mountain variants. The left text selectors remain available. Select/move mode supports dragging an occupied anchor. To select a very large mountain, use the placement list; choose it, click the move button, then click an empty target hex. R rotates the selected item 60 degrees, Delete removes it, Ctrl+Z undoes, wheel zooms over the map (or use the + / − zoom buttons), right drag rotates, WASD moves, Home frames the map. The radius control supports 2–40; shrinking is rejected if an anchor would fall outside. Saving needs a name. New/load/close prompt before discarding unsaved changes.

## Thumbnail assets

The 38 palette images are rendered from the actual DEV models and stored outside Git under `<SG_VISUAL_OUTPUT_ROOT>/map-editor-thumbnails/`; they are derived previews, not the source assets. If the output directory is moved or the images are absent, generate them with the existing Godot 4.2.2 renderer:

```powershell
$env:SG_VISUAL_OUTPUT_ROOT = 'D:/StrategyGame_Transfer/runtime_outputs'
& "$env:LOCALAPPDATA/Programs/Godot/Godot_v4.2.2-stable_win64.exe" --path 'D:/Game development/Demon slayer/StrategyGame' --script res://tools/dev_visual_lab/build_map_editor_thumbnails.gd
```

The editor still shows a labeled placeholder for any missing thumbnail. It does not download or modify the original models.

## Authoritative document and collaboration

On this PC, maps are ordinary UTF-8 JSON files in `D:/StrategyGame_Transfer/maps/`. If `SG_MAP_EDITOR_DIR` is unset they are in Godot's `user://strategy_map_editor/maps/`. Names are display text, not filenames; the stable `map_...` id determines `<id>.json`. The editor refuses to overwrite a file whose SHA-256 changed since it was loaded/saved; reload to take in an agent's edit. Save makes a same-directory temporary file and preserves a `.bak.<token>` backup before replacing an existing file. Backups are not listed as maps. Do not have a human and an agent write the same file simultaneously; the hash check detects already-observed external edits but is not a lock.

Schema version 1 example (illustrative only; choose a fresh unique id):

```json
{
  "schema_version": 1,
  "id": "map_123456789_1",
  "name": "동쪽 계곡",
  "radius": 10,
  "hex_radius": 18,
  "objects": [
    {"kind":"forest", "variant":"mixed", "q":0, "r":0, "rotation":0},
    {"kind":"mountain", "variant":"straight_short_low", "q":3, "r":-1, "rotation":1},
    {"kind":"castle", "variant":"castle_v1", "q":-3, "r":1, "rotation":0},
    {"kind":"building", "variant":"building_small_house", "q":1, "r":3, "rotation":0}
  ]
}
```

Axial coordinates are integers satisfying `max(abs(q), abs(r), abs(q+r)) <= radius`. An anchor may hold at most one object. `rotation` is an integer 0–5, each step 60 degrees. Forest variants: `mixed`, `pine`; castles: `castle_v1`–`castle_v4`; buildings: `building_small_house`, `building_medium_house`, `building_workshop`, `building_granary`, `building_hall`, `building_gate`, `building_farm_granary`. Mountain IDs are the `id` values in `outputs/scenery-scale-massif/massif25/catalog.json`; their GLBs are loaded at authoring-to-game scale 0.75.

An agent should read the current JSON and its hash, write only the requested map, preserve its id, schema and unmodified data, and check before replacement that the source hash has not changed. Preserve a backup and write a same-directory temporary file before renaming. Verify before handing back:

```powershell
python tools/dev_visual_lab/map_editor_cli.py 'D:/StrategyGame_Transfer/maps/map_...json' --outputs 'D:/StrategyGame_Transfer/runtime_outputs'
```

Reload the map in the editor and visually inspect it. The command validates structure and catalog IDs, not visual appearance or footprint collisions.

Forests are provisional groves; mountains are whole multi-hex candidate massifs anchored to one hex. Automatic forest stitching, mountain stitching, rock dressing, ground blending, multi-hex ownership/collision, and map-edge clipping are not implemented. Different anchors can overlap visually, and a mountain can extend beyond the board. Those are explicit later polish tasks. The current editor does not generate roads, rivers, or playable battle data.
