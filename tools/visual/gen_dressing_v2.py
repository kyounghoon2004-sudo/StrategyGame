"""Generate the battlefield dressing atlas (presentation-only scenery).

Painterly, lightweight sprites drawn procedurally with PIL:
grass tufts, dry grass, flower patches, bushes, rocks, in-hex forest trees
(pines / broadleaf), and
flat dirt / worn-earth decals. Everything is packed into ONE atlas so the
in-game dressing layer renders as a couple of batched meshes.

Output:
  assets/vegetation/dressing_v2/dressing_atlas.png
  assets/vegetation/dressing_v2/dressing_atlas.json   (regions + world sizes)

Run:  python tools/visual/gen_dressing_v2.py
Deterministic (fixed seed).
"""
import json
import math
import os
import random

from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT_DIR = os.path.join(ROOT, "assets", "vegetation", "dressing_v2")
SS = 4          # supersample factor while drawing
ATLAS_PX = 2    # atlas pixels per world pixel (crisp at close zoom)
rng = random.Random(907)


def jitter(c, amt=14):
    return tuple(max(0, min(255, v + rng.randint(-amt, amt))) for v in c[:3]) + (255,)


def canvas(w, h):
    return Image.new("RGBA", (w * SS, h * SS), (0, 0, 0, 0))


def finish(img, w, h):
    small = img.resize((w * ATLAS_PX, h * ATLAS_PX), Image.LANCZOS)
    return small


def blob(d, cx, cy, r, dark, mid, light, n=14):
    """Leafy cluster: dark base, mid body, light top-left highlights."""
    for i in range(n):
        a = rng.random() * math.tau
        rr = r * math.sqrt(rng.random())
        x, y = cx + math.cos(a) * rr * 0.9, cy + math.sin(a) * rr * 0.7 + r * 0.15
        s = r * rng.uniform(0.35, 0.55)
        d.ellipse([x - s, y - s, x + s, y + s], fill=jitter(dark, 10))
    for i in range(n):
        a = rng.random() * math.tau
        rr = r * math.sqrt(rng.random()) * 0.85
        x, y = cx + math.cos(a) * rr * 0.9 - r * 0.08, cy + math.sin(a) * rr * 0.65 - r * 0.08
        s = r * rng.uniform(0.28, 0.45)
        d.ellipse([x - s, y - s, x + s, y + s], fill=jitter(mid, 12))
    for i in range(n // 2):
        a = rng.uniform(math.pi * 1.0, math.pi * 1.6)
        rr = r * rng.uniform(0.2, 0.75)
        x, y = cx + math.cos(a) * rr, cy + math.sin(a) * rr * 0.7
        s = r * rng.uniform(0.14, 0.26)
        d.ellipse([x - s, y - s, x + s, y + s], fill=jitter(light, 12))


def contact_shadow(d, cx, by, rx, ry, a=90):
    d.ellipse([cx - rx, by - ry, cx + rx, by + ry], fill=(24, 30, 16, a))


def grass_tuft(palette):
    w, h = 12, 10
    img = canvas(w, h)
    d = ImageDraw.Draw(img)
    cx, by = w * SS / 2, h * SS - 2
    contact_shadow(d, cx, by, w * SS * 0.33, SS * 1.2, 30)
    for i in range(26):
        x0 = cx + rng.uniform(-w * SS * 0.28, w * SS * 0.28)
        lean = rng.uniform(-0.9, 0.9)
        ln = rng.uniform(0.45, 0.95) * h * SS
        x1 = x0 + lean * ln * 0.45
        y1 = by - ln
        col = jitter(palette[rng.randrange(len(palette))], 10)
        d.line([(x0, by), ((x0 + x1) / 2 + lean * 2, (by + y1) / 2), (x1, y1)], fill=col, width=SS)
    return finish(img, w, h), (w, h)


def flower_patch(petals):
    img_w, img_h = 13, 10
    base, _ = grass_tuft([(88, 112, 50), (106, 128, 58), (74, 96, 44)])
    img = base.resize((img_w * SS, img_h * SS), Image.LANCZOS)
    d = ImageDraw.Draw(img)
    for i in range(11):
        x = rng.uniform(0.18, 0.82) * img_w * SS
        y = rng.uniform(0.15, 0.62) * img_h * SS
        s = SS * rng.uniform(0.7, 1.1)
        c = jitter(petals[rng.randrange(len(petals))], 8)
        d.ellipse([x - s, y - s, x + s, y + s], fill=c)
        d.ellipse([x - s * 0.35, y - s * 0.35, x + s * 0.35, y + s * 0.35], fill=(250, 226, 120, 255))
    return finish(img, img_w, img_h), (img_w, img_h)


def bush(dark, mid, light, w=20, h=15):
    img = canvas(w, h)
    d = ImageDraw.Draw(img)
    cx, by = w * SS / 2, h * SS - SS
    contact_shadow(d, cx, by, w * SS * 0.44, SS * 2.2, 70)
    for k in range(rng.randint(3, 4)):
        bx = cx + rng.uniform(-0.26, 0.26) * w * SS
        r = rng.uniform(0.24, 0.34) * w * SS
        by2 = by - r * 0.85 - rng.uniform(0, 0.12) * h * SS
        blob(d, bx, by2, r, dark, mid, light)
    img = img.filter(ImageFilter.SMOOTH)
    return finish(img, w, h), (w, h)


def rock(w=11, h=8):
    img = canvas(w, h)
    d = ImageDraw.Draw(img)
    cx, by = w * SS / 2, h * SS - SS
    contact_shadow(d, cx, by, w * SS * 0.46, SS * 1.6, 70)
    pts = []
    for i in range(8):
        a = math.pi + i * math.pi / 7
        rx = w * SS * rng.uniform(0.36, 0.46)
        ry = h * SS * rng.uniform(0.62, 0.86)
        pts.append((cx + math.cos(a) * rx, by + math.sin(a) * ry))
    base = jitter((138, 132, 118), 8)
    d.polygon(pts, fill=base)
    # lit facet (upper-left) and shaded lower band
    lit = [(p[0], p[1]) for p in pts[2:6]] + [(cx - w * SS * 0.05, by - h * SS * 0.25)]
    d.polygon(lit, fill=jitter((176, 170, 154), 6))
    d.line(pts + [pts[0]], fill=(110, 104, 92, 255), width=SS)
    d.ellipse([cx + SS, by - h * SS * 0.45, cx + SS * 3.5, by - h * SS * 0.3], fill=(96, 118, 60, 200))
    return finish(img, w, h), (w, h)


def pine(w=13, h=24, dark=(38, 58, 38), mid=(58, 82, 50), light=(92, 116, 66)):
    """Compact conifer: short trunk + 3 stacked tiers, fits inside a hex."""
    img = canvas(w, h)
    d = ImageDraw.Draw(img)
    cx, by = w * SS / 2, h * SS - SS
    contact_shadow(d, cx, by, w * SS * 0.42, SS * 1.8, 110)
    d.rectangle([cx - SS * 0.9, by - h * SS * 0.22, cx + SS * 0.9, by], fill=(78, 58, 42, 255))
    tiers = 3
    for i in range(tiers):
        f = i / (tiers - 1)
        tw = w * SS * (0.50 - 0.13 * i)
        ty_base = by - h * SS * (0.14 + 0.25 * i)
        ty_top = ty_base - h * SS * (0.40 - 0.05 * i)
        pts = [(cx - tw, ty_base), (cx + tw, ty_base), (cx, ty_top)]
        d.polygon(pts, fill=jitter(dark, 6))
        # lit left flank
        d.polygon([(cx - tw * 0.92, ty_base - SS * 0.4), (cx - tw * 0.05, ty_base - SS * 0.4), (cx, ty_top + SS)], fill=jitter(mid, 8))
        d.polygon([(cx - tw * 0.6, ty_base - SS * 1.2), (cx - tw * 0.25, ty_base - SS * 1.2), (cx - tw * 0.12, ty_top + SS * 3)], fill=jitter(light, 8))
    return finish(img, w, h), (w, h)


def broadleaf(w=15, h=19, dark=(52, 70, 38), mid=(80, 100, 52), light=(122, 140, 74)):
    """Rounded broadleaf tree with a short trunk, muted olive canopy."""
    img = canvas(w, h)
    d = ImageDraw.Draw(img)
    cx, by = w * SS / 2, h * SS - SS
    contact_shadow(d, cx, by, w * SS * 0.40, SS * 1.8, 110)
    d.polygon([(cx - SS * 1.2, by), (cx + SS * 1.2, by), (cx + SS * 0.7, by - h * SS * 0.42), (cx - SS * 0.7, by - h * SS * 0.42)], fill=(84, 62, 44, 255))
    for k in range(3):
        bx = cx + rng.uniform(-0.16, 0.16) * w * SS
        byy = by - h * SS * rng.uniform(0.55, 0.68)
        blob(d, bx, byy, rng.uniform(0.26, 0.32) * w * SS, dark, mid, light, n=12)
    img = img.filter(ImageFilter.SMOOTH)
    return finish(img, w, h), (w, h)


def dirt_decal(w=36, h=24, col=(122, 98, 66), worn=False):
    img = canvas(w, h)
    d = ImageDraw.Draw(img)
    cx, cy = w * SS / 2, h * SS / 2
    for i in range(40):
        a = rng.random() * math.tau
        rr = math.sqrt(rng.random()) * 0.32
        x, y = cx + math.cos(a) * rr * w * SS, cy + math.sin(a) * rr * h * SS
        s = rng.uniform(0.10, 0.2) * w * SS
        d.ellipse([x - s, y - s * 0.7, x + s, y + s * 0.7], fill=jitter(col, 10)[:3] + (105,))
    img = img.filter(ImageFilter.GaussianBlur(SS * 1.6))
    d = ImageDraw.Draw(img)
    for i in range(70):
        x = cx + rng.uniform(-0.34, 0.34) * w * SS
        y = cy + rng.uniform(-0.3, 0.3) * h * SS
        c = jitter((120, 100, 72) if rng.random() < 0.6 else (176, 158, 124), 10)
        d.point((x, y), fill=c[:3] + (120,))
        if worn and rng.random() < 0.15:
            d.line([(x, y), (x + rng.uniform(-6, 6), y + rng.uniform(-2, 2))], fill=(92, 110, 56, 150), width=SS // 2)
    return finish(img, w, h), (w, h)


def build():
    sprites = []  # (name, kind, image, world_size)
    olive = [(112, 132, 62), (128, 146, 70), (100, 120, 56), (146, 154, 80)]
    lush = [(84, 120, 52), (100, 136, 60), (76, 108, 48), (118, 150, 70)]
    dry = [(170, 150, 92), (150, 132, 80), (186, 166, 104), (128, 118, 70)]
    for i in range(3):
        im, sz = grass_tuft(olive); sprites.append((f"tuft_olive_{i}", "tuft", im, sz))
        im, sz = grass_tuft(lush); sprites.append((f"tuft_lush_{i}", "tuft", im, sz))
    for i in range(2):
        im, sz = grass_tuft(dry); sprites.append((f"tuft_dry_{i}", "tuft", im, sz))
    for i, pet in enumerate([[(236, 232, 214), (226, 212, 150)], [(226, 204, 110), (238, 226, 160)]]):
        im, sz = flower_patch(pet); sprites.append((f"flowers_{i}", "flower", im, sz))
    for i, pal in enumerate([((70, 94, 50), (96, 124, 62), (140, 164, 86)), ((78, 100, 54), (108, 134, 68), (156, 176, 98)), ((90, 100, 52), (124, 136, 68), (170, 176, 104))]):
        im, sz = bush(*pal); sprites.append((f"bush_{i}", "bush", im, sz))
    for i in range(3):
        im, sz = rock(); sprites.append((f"rock_{i}", "rock", im, sz))
    # In-hex forest trees (replace the multi-hex cluster art in perspective).
    for i, pal in enumerate([((52, 74, 48), (74, 100, 62), (112, 136, 80)), ((58, 80, 52), (82, 108, 66), (122, 144, 86)), ((64, 82, 50), (90, 110, 64), (130, 148, 88))]):
        im, sz = pine(dark=pal[0], mid=pal[1], light=pal[2]); sprites.append((f"pine_{i}", "forest_pine", im, sz))
    for i, pal in enumerate([((62, 82, 44), (92, 114, 60), (134, 154, 84)), ((74, 86, 46), (108, 122, 62), (152, 162, 94)), ((56, 78, 44), (84, 108, 58), (124, 148, 78))]):
        im, sz = broadleaf(dark=pal[0], mid=pal[1], light=pal[2]); sprites.append((f"broadleaf_{i}", "forest_broad", im, sz))
    for i in range(3):
        im, sz = dirt_decal(worn=(i == 2)); sprites.append((f"dirt_{i}", "decal", im, sz))
    im, sz = dirt_decal(40, 26, (150, 136, 84)); sprites.append(("dry_patch_0", "decal", im, sz))
    im, sz = dirt_decal(40, 26, (78, 110, 48)); sprites.append(("lush_patch_0", "decal", im, sz))

    # shelf-pack into a 1024-wide atlas with 4px padding
    pad = 4
    width = 1024
    x = y = row_h = 0
    placed = []
    for name, kind, im, sz in sorted(sprites, key=lambda s: -s[2].height):
        if x + im.width + pad > width:
            x = 0
            y += row_h + pad
            row_h = 0
        placed.append((name, kind, im, sz, x + pad, y + pad))
        x += im.width + pad
        row_h = max(row_h, im.height + pad)
    height = y + row_h + pad
    atlas = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    meta = {"atlas_px_per_world_px": ATLAS_PX, "size": [width, height], "sprites": {}}
    for name, kind, im, sz, px, py in placed:
        atlas.alpha_composite(im, (px, py))
        meta["sprites"][name] = {"kind": kind, "region": [px, py, im.width, im.height], "world_size": list(sz)}
    os.makedirs(OUT_DIR, exist_ok=True)
    atlas.save(os.path.join(OUT_DIR, "dressing_atlas.png"))
    with open(os.path.join(OUT_DIR, "dressing_atlas.json"), "w", encoding="utf-8") as f:
        json.dump(meta, f, indent=1)
    print("atlas", width, height, "sprites", len(placed))


if __name__ == "__main__":
    build()
