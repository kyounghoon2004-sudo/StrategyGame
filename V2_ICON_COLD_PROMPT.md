# ChatGPT cold prompt — map icon set (copy everything below the line into ChatGPT with image generation on)

---

You are an icon artist for a turn-based hex strategy game set in the Chinese Five Dynasties era (10th century). I need a consistent set of **map-marker glyph icons**, drawn in the spirit of the map emblems of *Sid Meier's Civilization VI* (flat, bold, instantly readable), but with a **muted, painterly historical look**.

## Hard requirements (please follow exactly)

1. **One icon per file, 8 files, each a separate downloadable PNG.** Exact file names are listed below.
2. **Canvas 512 x 512 px, square, TRANSPARENT background** (real alpha channel, not a checkerboard picture).
   - If you truly cannot produce transparency, use a **flat pure magenta background #FF00FF** with no gradients and no shadow on the background, so I can key it out. Say which you used.
3. **Glyph only.** Draw just the symbol, centered, filling about **70 %** of the canvas (leave padding).
   - **NO outer ring, NO disc, NO frame, NO circle, NO badge background** — the game draws a dark disc and a colored owner ring behind the glyph itself.
   - **NO text, letters, numbers, or kanji.**
4. **Light glyph for a dark background:** main shapes in warm parchment / aged cream (#EBE0C0 to #F4EBD2), with shading in darker tan / brown (#B59B6A, #7A5E36) and a thin **dark outline (#1B1712)** around every shape so it stays readable when scaled down to **44 x 44 px**. Optional single accent colour per icon where noted.
5. **All 8 icons must look like one family:** same outline weight (about 10 px at 512), same top-left light direction, same level of detail, same corner softness, same painterly-flat shading. Simple silhouettes beat detail — it must read at 44 px.
6. No drop shadow outside the glyph, no glow, no gradient background, no perspective scene, no ground plane. Front/side flat view of the object.
7. Do not add any watermark or signature.

## The 8 icons (file name — what it shows)

1. `village.png` — a small village: one peasant house with a thatched/tiled gabled roof in front, a smaller second house behind it. Warm and humble.
2. `city.png` — a walled city: a gate tower with a curved Chinese-style tiled roof, crenellated wall on both sides, a small pennant on the roof ridge.
3. `fortress.png` — a stone fort: a thick crenellated wall with a central arched gate and two squat corner towers. Heavier and more austere than the city.
4. `supply_base.png` — a **field supply depot (병참기지)**: a stack of 3 grain sacks and 2 wooden crates in front of a small timber storehouse, with a short flagpole and a small pennant. Accent: pennant in muted gold (#D8B04A).
5. `edge_base.png` — the **main supply entry depot at the map edge**: a covered ox-cart / wagon loaded with sacks and a banner pole, with a small downward-pointing chevron or arrow-like road marker on its front to suggest "supplies come from here". Must clearly differ from `supply_base.png`. Accent: gold (#D8B04A).
6. `palisade.png` — **field fortification**: a row of 5 sharpened wooden stakes (a log palisade) lashed together with rope, slightly leaning, pointed tops. Wood in browns (#8A6238, #B58A52).
7. `occupier.png` — a **soldier occupying the place**: a simple helmet in front view (round iron helmet with a short plume and cheek guards). No face.
8. `raid.png` — **raiding / plundering**: a burning torch crossed with a loot sack. Flame in warm orange (#E8862A) with a yellow core; sack in cream.

## Output

- Give me the 8 PNG files as separate downloads, plus **one contact sheet** (a single image with all 8 on a mid-grey #3A3D40 background, labelled below each by file name) so I can judge consistency. The contact sheet is only for review; the 8 files themselves must have NO background and NO labels.
- If any icon is hard to read at 44 x 44 px, simplify it and tell me what you simplified.
- After generating, check each file for: transparent background (or flat #FF00FF), square 512 x 512, no text, no ring/frame, family consistency. List any file that fails and regenerate it before answering.

---

*(Where the files go on my side: `D:\Game development\Demon slayer\StrategyGame\assets\ui\v2_icons\` using exactly the file names above, e.g. `village.png`. If magenta background was used, tell me — the game keys #FF00FF out automatically.)*
