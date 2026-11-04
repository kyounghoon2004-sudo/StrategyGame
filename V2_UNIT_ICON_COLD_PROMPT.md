# ChatGPT cold prompt — unit badge icons (copy everything below the line into ChatGPT with image generation on)

---

You are an icon artist for a turn-based hex strategy game set in the Chinese Five Dynasties era (10th century). The unit badges on the map currently show a single Chinese character (卒, 步, 槍, 弓, 騎, 斥, 砲, 帥) — it is too complicated to read at a glance. I need **8 wordless unit icons** that replace those characters, in the spirit of the unit emblems of *Sid Meier's Civilization VI* (flat, bold, one clear silhouette per unit), with a **muted, painterly historical look**.

## Where the icon is used (this decides everything)

Each icon sits **inside a small dark-blue round seal about 30 px across**, so the icon itself is shown at only **about 20–24 px**. If it does not read at **24 x 24 px**, it is wrong. That means: ONE big simple silhouette, thick shapes, almost no interior detail, no thin lines.

## Hard requirements (please follow exactly)

1. **One icon per file, 8 files, each a separate downloadable PNG.** Exact file names are listed below.
2. **Canvas 512 x 512 px, square, TRANSPARENT background** (real alpha channel, not a checkerboard picture).
   - If you truly cannot produce transparency, use a **flat pure magenta background #FF00FF** with no gradients and no shadow on the background, so I can key it out. Say which you used.
3. **Icon only.** Centered, filling about **72 %** of the canvas (leave padding).
   - **NO ring, NO disc, NO frame, NO circle, NO badge background** — the game draws the blue seal and the gold rim itself.
   - **NO text, letters, numbers, or kanji.**
4. **Light icon for a dark blue background:** main shapes in warm parchment cream (#F1E6C8), shading in tan (#C2A872) and brown (#7A5E36), plus a **dark outline (#1B1712) about 14 px thick at 512** around the whole silhouette so it survives shrinking to 24 px. At most one small accent colour where noted.
5. **All 8 icons must look like one family:** identical outline weight, same top-left light direction, same level of detail, same corner softness, same painterly-flat shading. Pointing/weapon directions follow the notes below so the family also reads as one set.
6. Weapons/figures are **front or side flat views** — no perspective scene, no ground plane, no drop shadow, no glow, no gradient background, no watermark, no signature.
7. **Figures have no faces** (a helmet or hat shape is enough). Keep every icon under ~6 distinct shapes.

## The tier idea (please make it visible)

The units form a tree: **militia → infantry → {spear, cavalry, archer}**. The icons should read as a progression:
- militia is the humblest (a farming tool as a weapon),
- infantry is the standard soldier (sword + shield),
- spear, cavalry, archer are the specialised branches.
Scout, siege and HQ are separate unit types and should look clearly different from the tree.

## The 8 icons (file name — what it shows)

1. `conscript.png` — **militia (민병대)**: a **pitchfork / farm sickle crossed with a wooden club**, simple, slightly crude. Nothing metal-shiny. Accent: none.
2. `infantry.png` — **infantry (일반병)**: a **round shield in front with a straight sword (dao) crossed behind it**, blade pointing up-right. The standard soldier symbol.
3. `spear.png` — **spearman (창병)**: a **single long spear pointing straight up**, with a broad leaf-shaped head and a short tassel under the blade; add a **small round shield at the lower part** so it does not look like a plain stick. Diagonal-free, vertical.
4. `archer.png` — **archer (궁병)**: a **recurved bow with a nocked arrow**, drawn, arrow pointing right. Large clear bow curve. Accent: arrow feathers in muted red (#B5453A).
5. `cavalry.png` — **cavalry (기병)**: the **head and neck of a horse in profile, facing right**, with a bridle and a short plume on the forehead. Mane as 3 simple blocks. (Head only, so it stays readable.)
6. `scout.png` — **scout (척후병)**: a **pointed bamboo/straw hat (douli) in front view with a small leaf-shaped feather on its side**, the look of a lone light runner. Must be clearly different from `conscript.png` and `infantry.png`.
7. `siege.png` — **siege engine (공성)**: a **catapult / trebuchet in side view** with the arm raised and a small stone in the sling. Wooden browns, one stone in cream.
8. `hq.png` — **commander headquarters (사령부)**: a **tall command banner on a pole with a swallow-tail pennant, flanked by two short crossed halberds at its base**. Accent: pennant in muted gold (#D8B04A). The most "important" looking of the set.

## Output

- Give me the 8 PNG files as separate downloads, plus **one contact sheet** (a single image with all 8 shown twice: once large on a mid-grey #3A3D40 background, and once reduced to **24 x 24 px on a dark-blue #2B4C8C disc of 30 px**, labelled below each by file name) so I can judge whether they read at game size. The contact sheet is only for review; the 8 files themselves must have NO background and NO labels.
- If any icon is hard to read at 24 x 24 px, simplify it and tell me what you simplified.
- After generating, check each file for: transparent background (or flat #FF00FF), square 512 x 512, no text/kanji, no ring/frame, family consistency, **readable at 24 px**. List any file that fails and regenerate it before answering.

---

*(Where the files go on my side: `D:\Game development\Demon slayer\StrategyGame\assets\ui\unit_icons\` using exactly the file names above, e.g. `conscript.png`. If a magenta background was used, tell me — the game keys #FF00FF out automatically.)*
