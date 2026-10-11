"""Terrain language v2 (VISUAL ONLY) — assets created during the canonical
battlefield QA pass (artifacts/battlefield_canonical_10_v1/QA_REPORT.md).

Why: the HIGH board's ground/route textures (assets/terrain/cohesion/approved_v1)
are unfinished placeholder gradients (every role, road and pass floor is the
same green blob), so roads, pass floors, marsh and rock ground were invisible
in HIGH; and the SF3D mountain dioramas drew as squashed, sheared slabs.

Outputs (deterministic):
  assets/terrain/ground_v2/<stem>.png   64x64 opaque ground tiles, one per role,
      palette taken from the CLOSEUP ground bands (closeup_ground.gdshader) so
      HIGH and CLOSEUP read as the same ground.
  assets/terrain/relief_v1/relief_atlas.png/.json   one small atlas of upright
      mountain cards (peaks, twin peaks, ridge humps, crags, knolls) in the
      dressing_v2 atlas format; drawn by the shared billboard MultiMesh.
  Registers every PNG in assets/production_ingestion_v1/alpha_bounds.json
  (bounds / canvas / bottom_contact / sha256) as the registry requires.

Run: python tools/battlefields/gen_terrain_language_v2.py [project_root]
"""
from __future__ import annotations

import hashlib
import json
import math
import random
import sys
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[2]
GROUND = ROOT / "assets" / "terrain" / "ground_v2"
RELIEF = ROOT / "assets" / "terrain" / "relief_v1"
BOUNDS = ROOT / "assets" / "production_ingestion_v1" / "alpha_bounds.json"
TILE = 64  # texels; 2 texels per art pixel -> 32 art px across a 48 px hex


def c8(v):
    return tuple(int(round(max(0.0, min(1.0, x)) * 255)) for x in v)


def mix(a, b, t):
    return tuple(a[i] * (1 - t) + b[i] * t for i in range(3))


# CLOSEUP bands (dark, mid, light), closeup_ground.gdshader
GRASS = ((0.33, 0.45, 0.22), (0.38, 0.51, 0.25), (0.44, 0.56, 0.29))
ROCK = ((0.42, 0.38, 0.30), (0.48, 0.44, 0.35), (0.54, 0.50, 0.40))
SWAMP = ((0.24, 0.32, 0.22), (0.27, 0.33, 0.22), (0.32, 0.38, 0.26))
YARD = ((0.46, 0.44, 0.28), (0.50, 0.47, 0.30), (0.54, 0.51, 0.33))
PAVE = ((0.50, 0.47, 0.41), (0.56, 0.53, 0.46), (0.61, 0.58, 0.51))
DIRT = ((0.46, 0.39, 0.27), (0.56, 0.47, 0.33), (0.62, 0.53, 0.38))
ROAD = ((0.60, 0.51, 0.36), (0.68, 0.58, 0.42), (0.74, 0.65, 0.48))
WATER = ((0.20, 0.30, 0.33), (0.25, 0.37, 0.40), (0.33, 0.46, 0.50))


def band_mix(a, b, t):
    return tuple(mix(a[i], b[i], t) for i in range(3))


def _vn(x, y, seed):
    def h(ix, iy):
        n = (ix * 374761393 + iy * 668265263 + seed * 97) & 0xFFFFFFFF
        n = ((n ^ (n >> 13)) * 1274126177) & 0xFFFFFFFF
        return ((n ^ (n >> 16)) & 0xFFFF) / 65535.0
    ix, iy = math.floor(x), math.floor(y)
    fx, fy = x - ix, y - iy
    fx, fy = fx * fx * (3 - 2 * fx), fy * fy * (3 - 2 * fy)
    return (h(ix, iy) * (1 - fx) + h(ix + 1, iy) * fx) * (1 - fy) + (h(ix, iy + 1) * (1 - fx) + h(ix + 1, iy + 1) * fx) * fy


def tileable_noise(x, y, seed, period):
    """Periodic value noise on an art-pixel grid (tiles seamlessly)."""
    def h(ix, iy):
        ix, iy = ix % period, iy % period
        n = (ix * 374761393 + iy * 668265263 + seed * 97) & 0xFFFFFFFF
        n = ((n ^ (n >> 13)) * 1274126177) & 0xFFFFFFFF
        return ((n ^ (n >> 16)) & 0xFFFF) / 65535.0
    ix, iy = math.floor(x), math.floor(y)
    fx, fy = x - ix, y - iy
    fx, fy = fx * fx * (3 - 2 * fx), fy * fy * (3 - 2 * fy)
    return (h(ix, iy) * (1 - fx) + h(ix + 1, iy) * fx) * (1 - fy) + (h(ix, iy + 1) * (1 - fx) + h(ix + 1, iy + 1) * fx) * fy


def ground_tile(stem, band, seed, speck=None, speck_p=0.0, pools=None, ruts=None, stones=None):
    """3-tone banded ground in chunky 2x2 art pixels (house pixel density)."""
    rng = random.Random(seed)
    A = TILE // 2
    img = Image.new("RGB", (TILE, TILE))
    px = img.load()
    for ay in range(A):
        for ax in range(A):
            n = 0.6 * tileable_noise(ax / 4.0, ay / 4.0, seed, A // 4) + 0.4 * tileable_noise(ax / 2.0, ay / 2.0, seed + 5, A // 2)
            n += (rng.random() - 0.5) * 0.18
            col = band[0] if n < 0.40 else (band[1] if n < 0.66 else band[2])
            if pools is not None:
                w = tileable_noise(ax / 5.0, ay / 5.0, seed + 11, max(1, A // 5 + (A % 5 > 0)))
                w = 0.6 * tileable_noise(ax / 4.0, ay / 4.0, seed + 11, A // 4) + 0.4 * tileable_noise(ax / 2.0, ay / 2.0, seed + 13, A // 2)
                if w > 0.64:
                    col = pools[1] if w < 0.74 else pools[2]
                elif w > 0.60:
                    col = pools[0]
            if ruts is not None:
                # two faint wheel ruts running across the tile (tileable)
                for ry in (A * 0.36, A * 0.64):
                    if abs(ay - ry - 1.2 * math.sin(ax * 2 * math.pi / A)) < 0.9:
                        col = ruts
            if speck is not None and rng.random() < speck_p:
                col = speck
            c = c8(col)
            for dy in range(2):
                for dx in range(2):
                    px[ax * 2 + dx, ay * 2 + dy] = c
    if stones:
        d = ImageDraw.Draw(img)
        for _ in range(stones[0]):
            x, y = rng.randrange(1, A - 2) * 2, rng.randrange(1, A - 2) * 2
            d.rectangle([x, y, x + 3, y + 1], fill=c8(stones[1]))
            d.rectangle([x, y - 2, x + 1, y - 1], fill=c8(stones[2]))
    return img


def ground_set():
    GROUND.mkdir(parents=True, exist_ok=True)
    dry = band_mix(GRASS, YARD, 0.28)
    loess = band_mix(GRASS, YARD, 0.38)
    lush = band_mix(GRASS, ((0.26, 0.42, 0.20), (0.31, 0.48, 0.23), (0.37, 0.53, 0.27)), 0.7)
    foot = band_mix(GRASS, ROCK, 0.45)
    worn = band_mix(GRASS, DIRT, 0.35)
    tiles = {
        "plain_parchment_v2": ground_tile("p", dry, 11, speck=GRASS[2], speck_p=0.02),
        "plain_loess_v2": ground_tile("l", loess, 12, speck=YARD[0], speck_p=0.03),
        "plain_grass_faded_v2": ground_tile("g", GRASS, 13, speck=GRASS[0], speck_p=0.02),
        "plain_battlefield_worn_v2": ground_tile("w", worn, 14, speck=DIRT[0], speck_p=0.05),
        "plain_lowland_green_v2": ground_tile("lg", lush, 15, speck=lush[2], speck_p=0.03),
        "ground_foothill_v2": ground_tile("f", foot, 16, stones=(5, ROCK[0], ROCK[2])),
        "pass_floor_v2": ground_tile("pf", PAVE, 17, speck=PAVE[0], speck_p=0.08, stones=(4, ROCK[0], PAVE[2])),
        "marsh_ground_v2": ground_tile("m", SWAMP, 18, pools=WATER, speck=(0.18, 0.24, 0.15), speck_p=0.06),
        "rock_ground_v2": ground_tile("r", ROCK, 19, speck=(0.34, 0.31, 0.25), speck_p=0.06, stones=(7, (0.32, 0.29, 0.23), (0.60, 0.57, 0.48))),
        # light tan like the CLOSEUP road centre, so the ribbon separates from grass
        "road_dirt_v2": ground_tile("rd", ROAD, 20, ruts=(0.52, 0.43, 0.30), speck=ROAD[0], speck_p=0.04),
        "road_pass_v2": ground_tile("rp", band_mix(DIRT, PAVE, 0.5), 21, ruts=(0.44, 0.39, 0.30), stones=(4, ROCK[0], PAVE[2])),
        "bridge_deck_v2": _planks(),
    }
    out = []
    for stem, img in tiles.items():
        p = GROUND / (stem + ".png")
        img.save(p)
        out.append(p)
    return out


def _planks():
    img = Image.new("RGB", (TILE, TILE))
    d = ImageDraw.Draw(img)
    dark, mid, light = c8((0.30, 0.22, 0.14)), c8((0.46, 0.34, 0.21)), c8((0.56, 0.43, 0.28))
    for i in range(TILE // 8):
        y = i * 8
        d.rectangle([0, y, TILE, y + 7], fill=mid if i % 2 else light)
        d.rectangle([0, y + 6, TILE, y + 7], fill=dark)
        off = (i * 22) % TILE
        d.rectangle([off, y, off + 1, y + 7], fill=dark)
    return img


# ------------------------------------------------------------- relief ----
SS = 4
APX = 2  # atlas px per world px (same as dressing_v2)
OUT = (0.16, 0.13, 0.11)


def _poly(d, pts, fill, outline=True):
    d.polygon(pts, fill=c8(fill) + (255,))
    if outline:
        d.line(pts + [pts[0]], fill=c8(OUT) + (255,), width=SS * 2, joint="curve")


def _massif(img, d, W, H, base, summits, rng, lit, mid, shade, deep, jag=0.05):
    """One rocky mass: jagged silhouette through the summits, light (left of
    each spine) and shade (right) faces, dark outline."""
    sil = [(SS * 2, base)]
    for i, (sx, sy) in enumerate(summits):
        prev_x = sil[-1][0]
        for t in (0.35, 0.7):
            x = prev_x + (sx - prev_x) * t
            y = base + (sy - base) * (t ** 0.8) + rng.uniform(-jag, jag) * H
            sil.append((x, min(base - SS, y)))
        sil.append((sx, sy))
        if i + 1 < len(summits):
            nx = summits[i + 1][0]
            sil.append(((sx + nx) / 2, sy + (base - sy) * rng.uniform(0.35, 0.5)))
    lx = sil[-1][0]
    for t in (0.3, 0.65):
        x = lx + (W - SS * 2 - lx) * t
        y = sil[-1][1] + (base - sil[-1][1]) * (t ** 0.8) + rng.uniform(-jag, jag) * H
        sil.append((x, min(base - SS, y)))
    sil.append((W - SS * 2, base))
    d.polygon(sil, fill=c8(shade) + (255,))
    # lit faces: from each summit down-left of its spine
    left_bound = 0.0
    for (sx, sy) in summits:
        foot = sx + W * rng.uniform(0.03, 0.10)
        lit_pts = [p for p in sil if left_bound <= p[0] < sx and p[0] >= sx - W * 0.42]
        if left_bound > 0.0:
            lit_pts = [(left_bound, base)] + lit_pts
        lit_pts = lit_pts + [(sx, sy), (foot, base)]
        left_bound = sx
        if len(lit_pts) >= 3:
            d.polygon(lit_pts, fill=c8(mid) + (255,))
            spine = [(sx, sy), (sx - W * 0.02, sy + (base - sy) * 0.45), (foot, base)]
            hl = [(sx - SS, sy + SS * 2)] + [(x + W * 0.05, y) for (x, y) in lit_pts if x < sx - SS * 3][:3]
            if len(hl) >= 3:
                d.polygon(hl, fill=c8(lit) + (255,))
            d.line(spine, fill=c8(deep) + (255,), width=SS)
    # strata / gullies, clipped to the silhouette
    mask = Image.new("L", (W, H), 0)
    ImageDraw.Draw(mask).polygon(sil, fill=255)
    gl = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    gd = ImageDraw.Draw(gl)
    for _ in range(4):
        x = rng.uniform(W * 0.35, W * 0.85)
        y = rng.uniform(H * 0.35, base - SS * 4)
        gd.line([(x, y), (x + W * 0.06, y + H * 0.12)], fill=c8(deep) + (255,), width=SS)
    img.paste(gl, (0, 0), Image.composite(gl.getchannel("A"), Image.new("L", (W, H), 0), mask))
    d.line(sil, fill=c8(OUT) + (255,), width=SS * 2, joint="curve")
    return sil


def peak_card(w, h, seed, twin=False, snow=0.2):
    """Upright pixel-art peak: jagged loess-rock mass, light from the upper
    left, dark outline, ground contact at the bottom."""
    rng = random.Random(seed)
    W, H = w * APX * SS, h * APX * SS
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    base = H - SS * 3
    if twin:
        summits = [(W * rng.uniform(0.30, 0.38), H * rng.uniform(0.16, 0.24)), (W * rng.uniform(0.62, 0.70), H * rng.uniform(0.05, 0.12))]
    else:
        summits = [(W * rng.uniform(0.44, 0.56), H * 0.05)]
    lit, mid, shade, deep = (0.70, 0.64, 0.52), (0.55, 0.50, 0.41), (0.38, 0.35, 0.31), (0.26, 0.24, 0.22)
    _massif(img, d, W, H, base, summits, rng, lit, mid, shade, deep)
    for (sx, sy) in summits:
        sh = (base - sy) * snow
        d.polygon([(sx - W * 0.07, sy + sh), (sx, sy + SS), (sx + W * 0.05, sy + sh * 0.8), (sx - W * 0.01, sy + sh * 1.3)], fill=c8((0.84, 0.82, 0.76)) + (255,))
    for _ in range(int(w / 3)):
        x = rng.uniform(W * 0.12, W * 0.88)
        rr = SS * rng.uniform(2.2, 3.4)
        d.ellipse([x - rr, base - rr * 1.4, x + rr, base + rr * 0.2], fill=c8((0.20, 0.28, 0.15)) + (255,))
        d.ellipse([x - rr * 0.6, base - rr * 1.5, x + rr * 0.3, base - rr * 0.5], fill=c8((0.33, 0.43, 0.23)) + (255,))
    return img


def ridge_card(w, h, seed):
    rng = random.Random(seed)
    W, H = w * APX * SS, h * APX * SS
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    base = H - SS * 3
    pts = [(SS * 2, base)]
    n = 6
    for i in range(1, n):
        x = W * i / n
        y = H * (0.18 + 0.22 * abs(math.sin(i * 1.1 + seed)) + rng.uniform(-0.05, 0.05))
        pts.append((x, y))
    pts.append((W - SS * 2, base))
    _poly(d, pts, (0.48, 0.44, 0.37))
    for i in range(1, len(pts) - 1):
        x, y = pts[i]
        d.polygon([(x, y + SS * 2), (x - W * 0.09, base - SS), (x + W * 0.03, base - SS)], fill=c8((0.60, 0.56, 0.48)) + (255,))
        d.polygon([(x + SS, y + SS * 3), (x + W * 0.03, base - SS), (x + W * 0.12, base - SS)], fill=c8((0.36, 0.33, 0.29)) + (255,))
    d.line(pts, fill=c8(OUT) + (255,), width=SS * 2, joint="curve")
    for _ in range(int(w / 4)):
        x = rng.uniform(W * 0.1, W * 0.9)
        rr = SS * rng.uniform(1.8, 2.8)
        d.ellipse([x - rr, base - rr * 1.3, x + rr, base + rr * 0.2], fill=c8((0.24, 0.32, 0.18)) + (255,))
    return img


def crag_card(w, h, seed):
    """Pass wall / cliff lip: a broad, steep-sided rock mass with flat-topped
    shoulders and horizontal strata (reads as a wall beside the pass)."""
    rng = random.Random(seed)
    W, H = w * APX * SS, h * APX * SS
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    base = H - SS * 3
    summits = [(W * 0.30, H * rng.uniform(0.10, 0.18)), (W * 0.70, H * rng.uniform(0.02, 0.10))]
    _massif(img, d, W, H, base, summits, rng, (0.66, 0.60, 0.50), (0.52, 0.47, 0.39), (0.36, 0.33, 0.29), (0.25, 0.23, 0.21), jag=0.02)
    sil = [(SS * 2, base)]
    return img


def knoll_card(w, h, seed):
    rng = random.Random(seed)
    W, H = w * APX * SS, h * APX * SS
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    base = H - SS * 3
    d.pieslice([SS * 2, H * 0.12, W - SS * 2, base * 2 - H * 0.12], 180, 360, fill=c8((0.44, 0.47, 0.30)) + (255,), outline=c8(OUT) + (255,), width=SS * 2)
    d.pieslice([SS * 5, H * 0.2, W * 0.62, base * 2 - H * 0.2], 190, 290, fill=c8((0.55, 0.57, 0.37)) + (255,))
    for _ in range(3):
        x = rng.uniform(W * 0.3, W * 0.8)
        y = rng.uniform(H * 0.45, base - SS * 3)
        d.rectangle([x, y, x + SS * 3, y + SS * 2], fill=c8((0.50, 0.46, 0.39)) + (255,), outline=c8((0.30, 0.27, 0.22)) + (255,))
    return img


def relief_atlas():
    RELIEF.mkdir(parents=True, exist_ok=True)
    cards = {}
    for i in range(3):
        cards["peak_%d" % i] = ("peak", 38, 34, peak_card(38, 34, 100 + i))
    for i in range(2):
        cards["twin_%d" % i] = ("peak", 40, 30, peak_card(40, 30, 200 + i, twin=True))
    for i in range(3):
        cards["ridge_%d" % i] = ("ridge", 40, 20, ridge_card(40, 20, 300 + i))
    for i in range(2):
        cards["crag_%d" % i] = ("crag", 34, 26, crag_card(34, 26, 400 + i))
    for i in range(2):
        cards["knoll_%d" % i] = ("knoll", 34, 14, knoll_card(34, 14, 500 + i))
    pad = 4
    small = {k: (kind, w, h, im.resize((w * APX, h * APX), Image.LANCZOS)) for k, (kind, w, h, im) in cards.items()}
    width = sum(im.size[0] + pad for _, _, _, im in small.values()) + pad
    height = max(im.size[1] for _, _, _, im in small.values()) + pad * 2
    atlas = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    meta = {"atlas_px_per_world_px": APX, "size": [width, height], "sprites": {}}
    x = pad
    for k, (kind, w, h, im) in small.items():
        a = im.getchannel("A").point(lambda v: 255 if v > 110 else 0)
        im.putalpha(a)
        atlas.paste(im, (x, pad))
        meta["sprites"][k] = {"kind": kind, "region": [x, pad, im.size[0], im.size[1]], "world_size": [w, h]}
        x += im.size[0] + pad
    p = RELIEF / "relief_atlas.png"
    atlas.save(p)
    (RELIEF / "relief_atlas.json").write_text(json.dumps(meta, indent=1), encoding="utf-8")
    return [p]


def register(paths):
    """alpha_bounds.json entries (the registry asserts every texture it samples)."""
    data = json.loads(BOUNDS.read_text(encoding="utf-8"))
    for p in paths:
        im = Image.open(p).convert("RGBA")
        bb = im.getchannel("A").getbbox() or (0, 0, im.size[0], im.size[1])
        x0, y0, x1, y1 = bb
        res = "res://" + p.relative_to(ROOT).as_posix()
        data[res] = {
            "bounds": [x0, y0, x1 - x0, y1 - y0],
            "content_width": x1 - x0, "content_height": y1 - y0,
            "bottom_contact": [round((x0 + x1) / 2.0, 3), y1],
            "visual_center": [round((x0 + x1) / 2.0, 1), round((y0 + y1) / 2.0, 1)],
            "canvas": [im.size[0], im.size[1]],
            "sha256": hashlib.sha256(p.read_bytes()).hexdigest(),
        }
    BOUNDS.write_text(json.dumps(data, indent=1), encoding="utf-8")


if __name__ == "__main__":
    g = ground_set()
    r = relief_atlas()
    register(g)
    print("ground_v2 %d tiles, relief atlas %s" % (len(g), r[0].name))
