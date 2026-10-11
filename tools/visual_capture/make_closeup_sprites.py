"""Generate the CLOSEUP-only 2.5D tree sprites (VISUAL ONLY).

Tall pixel-art conifers / broadleaf trees / shrubs drawn side-on, in the same
language as the approved formation + structure art (dark outline, 4-tone cel
shading, light from the upper left). The board's approved vegetation is drawn
as canopy seen from above, which cannot read as a tall line-of-sight-blocking
forest in the closeup, so the closeup gets its own upright set.

Usage (from the project root):  python tools/visual_capture/make_closeup_sprites.py
Writes assets/closeup25d/*.png (loaded at runtime via Image.load_from_file).
"""
import math
import os
import random

from PIL import Image

OUT = "assets/closeup25d/"
SCALE = 2  # native pixel art -> stored size (nearest), keeps pixels crisp on screen
# Native sizes are chosen so on-screen pixel density matches the approved
# formation art at closeup range (no chunkier than the soldiers).

OUTLINE = (16, 28, 22, 255)
PINE = [(28, 52, 38), (40, 74, 50), (60, 100, 60), (96, 132, 72)]  # dark .. highlight
BROAD = [(34, 62, 30), (52, 92, 40), (82, 124, 52), (126, 160, 74)]
AUTUMN = [(92, 50, 22), (150, 86, 30), (196, 128, 44), (230, 176, 82)]
TRUNK = [(40, 28, 20), (72, 50, 32), (104, 74, 48)]


def outline(img):
    """1px dark outline around every opaque pixel (the approved-art look)."""
    w, h = img.size
    src = img.load()
    out = img.copy()
    dst = out.load()
    for y in range(h):
        for x in range(w):
            if src[x, y][3] > 0:
                continue
            for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                nx, ny = x + dx, y + dy
                if 0 <= nx < w and 0 <= ny < h and src[nx, ny][3] > 0:
                    dst[x, y] = OUTLINE
                    break
    return out


def shade(pal, lx):
    """Cel band for a light term in [-1, 1] (4 flat tones, no gradients)."""
    if lx > 0.55:
        return pal[3]
    if lx > 0.1:
        return pal[2]
    if lx > -0.4:
        return pal[1]
    return pal[0]


def trunk(px, cx, top, bottom, half):
    for y in range(top, bottom):
        for x in range(cx - half, cx + half + 1):
            t = (x - cx) / max(half, 1)
            px[x, y] = TRUNK[2] + (255,) if t < -0.3 else (TRUNK[1] + (255,) if t < 0.4 else TRUNK[0] + (255,))


def conifer(seed, w, h, tiers):
    rnd = random.Random(seed)
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    px = img.load()
    cx = w // 2
    base = h - 2
    trunk(px, cx, base - 10, base, 1)
    top = 2
    crown_bottom = base - 7
    span = crown_bottom - top
    for i in range(tiers):
        # tiers overlap downward, each wider than the last
        t0 = top + int(span * (i / tiers) * 0.92)
        t1 = top + int(span * ((i + 1) / tiers)) + 3
        max_half = (w // 2 - 2) * (0.35 + 0.65 * (i + 1) / tiers)
        for y in range(t0, min(t1, crown_bottom + 1)):
            k = (y - t0) / max(t1 - t0, 1)
            half = max_half * (0.12 + 0.88 * k ** 0.8)
            jag = rnd.randint(-1, 1) if k > 0.6 else 0
            for x in range(int(cx - half) - jag, int(cx + half) + jag + 1):
                if 0 <= x < w:
                    lx = -(x - cx) / max(half, 1) * 0.9 + (0.35 - k) * 0.6 + rnd.uniform(-0.12, 0.12)
                    px[x, y] = shade(PINE, lx) + (255,)
        # drooping under-edge of each tier stays in shadow
        for x in range(int(cx - max_half), int(cx + max_half) + 1):
            y = min(t1 - 1, crown_bottom)
            if 0 <= x < w and px[x, y][3] > 0 and rnd.random() < 0.7:
                px[x, y] = PINE[0] + (255,)
    return outline(img)


def blob(px, w, h, cx, cy, r, pal, rnd):
    for y in range(int(cy - r) - 1, int(cy + r) + 2):
        for x in range(int(cx - r) - 1, int(cx + r) + 2):
            if not (0 <= x < w and 0 <= y < h):
                continue
            dx, dy = (x - cx) / r, (y - cy) / r
            d = dx * dx + dy * dy
            if d <= 1.0 + rnd.uniform(-0.08, 0.05):
                lx = -dx * 0.7 - dy * 0.8 + rnd.uniform(-0.15, 0.15)
                px[x, y] = shade(pal, lx) + (255,)


def broadleaf(seed, w, h, pal):
    rnd = random.Random(seed)
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    px = img.load()
    cx = w // 2
    base = h - 2
    trunk(px, cx, int(h * 0.45), base, 2)
    crown_c = h * 0.36
    rr = w * 0.30
    lobes = [(0, 0, 1.0)] + [(math.cos(a) * rr * 0.75, math.sin(a) * rr * 0.55, rnd.uniform(0.6, 0.8)) for a in [i * math.tau / 6 + rnd.uniform(-0.3, 0.3) for i in range(6)]]
    # back-to-front: lower lobes last so the top-left light reads
    for ox, oy, s in sorted(lobes, key=lambda l: l[1]):
        blob(px, w, h, cx + ox, crown_c + oy, rr * s, pal, rnd)
    return outline(img)


def shrub(seed, w, h, pal):
    rnd = random.Random(seed)
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    px = img.load()
    for i in range(4):
        blob(px, w, h, w * rnd.uniform(0.3, 0.7), h - 2 - h * rnd.uniform(0.25, 0.45), w * rnd.uniform(0.18, 0.26), pal, rnd)
    return outline(img)


WALL = [(150, 128, 98), (190, 168, 128), (222, 204, 164)]
ROOF = [(44, 50, 62), (66, 74, 88), (96, 106, 120)]
WOOD = (92, 58, 36)


def house(seed, w, h, roof):
    """Small village house seen 3/4 from the front, eaves swept up at the ends."""
    rnd = random.Random(seed)
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    px = img.load()
    base = h - 2
    wall_top = int(h * 0.52)
    side = int(w * 0.30)  # right-hand side wall, in shadow
    for y in range(wall_top, base):
        for x in range(3, w - 3):
            c = WALL[2] if x < w - 3 - side else WALL[0]
            px[x, y] = c + (255,)
    # door + window + timber posts
    dx = int((w - side) * 0.42)
    for y in range(base - int(h * 0.26), base):
        for x in range(dx, dx + 4):
            px[x, y] = WOOD + (255,)
    for y in range(wall_top + 3, wall_top + 7):
        for x in range(dx + 8, dx + 12):
            if x < w - 3 - side:
                px[x, y] = (60, 40, 28, 255)
    for x in (3, w - 4 - side, w - 4):
        for y in range(wall_top, base):
            px[x, y] = WOOD + (255,)
    # hip roof: front slope lit, right slope in shadow, eaves curl up
    rt = 2
    for y in range(rt, wall_top + 2):
        k = (y - rt) / max(wall_top + 2 - rt, 1)
        inset = int((1.0 - k) * w * 0.22)
        lift = 2 if k > 0.85 else 0
        for x in range(inset - lift, w - inset + lift):
            if 0 <= x < w:
                c = roof[2] if y < rt + 2 else (roof[1] if x < w - side - inset * 0.3 else roof[0])
                if (x + y) % 4 == 0 and y > rt + 2:
                    c = roof[0]  # tile rows
                px[x, y] = c + (255,)
    return outline(img)


def save(img, name, scale=SCALE):
    img = img.resize((img.width * scale, img.height * scale), Image.NEAREST)
    img.save(OUT + name)
    print("wrote", OUT + name, img.size)


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    save(conifer(1, 80, 192, 7), "pine_0.png")
    save(conifer(2, 72, 168, 6), "pine_1.png")
    save(conifer(3, 88, 216, 8), "pine_2.png")
    save(conifer(4, 60, 140, 6), "pine_3.png")
    save(broadleaf(5, 88, 120, BROAD), "broad_0.png")
    save(broadleaf(6, 80, 112, AUTUMN), "broad_1.png")
    save(shrub(7, 48, 28, BROAD), "shrub_0.png")
    save(shrub(8, 40, 24, AUTUMN), "shrub_1.png")
    save(house(9, 40, 30, ROOF), "house_0.png", 3)
    save(house(10, 34, 26, [(92, 46, 34), (128, 64, 44), (160, 90, 60)]), "house_1.png", 3)
