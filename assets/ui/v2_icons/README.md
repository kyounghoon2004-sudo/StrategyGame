# V2 map icons — just crop and paste PNGs here

The game uses these files as the **glyph inside the icon** (the coloured owner ring and the dark disc are drawn by the game).
Copy a cropped PNG into this folder with the exact file name below. **It is picked up while the game is running** (checked about every 2 seconds) — no restart, no import step.

| file name          | used for                                        | shown today? |
|--------------------|-------------------------------------------------|--------------|
| `village.png`      | village structure                               | yes          |
| `city.png`         | city structure                                  | yes (later maps) |
| `fortress.png`     | fortress structure                              | yes (later maps) |
| `supply_base.png`  | 병참기지 built by the HQ (never the edge bases) | yes          |
| `edge_base.png`    | fixed edge supply base (currently has no icon)  | reserved     |
| `occupier.png`     | unit occupying a place                          | reserved     |
| `palisade.png`     | 요새화 palisade badge                           | reserved     |
| `raid.png`         | raid in progress                                | reserved     |

## What the game does to a pasted file (so a rough crop is fine)

- A **magenta (#FF00FF)** background is made transparent.
- A **flat background colour that touches all four corners** (e.g. you cropped it out of a contact sheet with a grey background) is flooded away automatically.
- **Empty margins are trimmed** and the glyph is **padded to a square**, so crop size and aspect ratio do not matter.
- The glyph is scaled to about 30 px inside the icon (20 px for small badges); simple, bold shapes with a dark outline read best.
- If a file is missing, the game falls back to its built-in placeholder glyph for that icon.

Prompt for generating the set: `V2_ICON_COLD_PROMPT.md` in the project root.

## Where the current set came from

The 8 PNGs here were cut out of `동아시아풍 전략 게임 건물 아이콘 시트.png` with `tools/rules_v2/cut_icon_sheet.py`
(GrabCut seeded from the painting's fine detail, so the glow behind each icon is dropped). To redo it:

    python tools/rules_v2/cut_icon_sheet.py "<sheet.png>" --preview preview.png
