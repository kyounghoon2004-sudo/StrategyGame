"""Generate soft mist-bank sprites for the perspective fog presentation.

Output: assets/vegetation/dressing_v2/mist_atlas.png + mist_atlas.json
Each sprite is a billowing, bottom-heavy vapour bank (alpha soft edges),
world size ~ 64 x 44 px. Deterministic.
"""
import json, os, random, math
from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(ROOT, "assets", "vegetation", "dressing_v2")
rng = random.Random(4219)
W, H = 256, 176  # atlas px per sprite (4 px per world px)


def bank():
    img = Image.new("L", (W, H), 0)
    d = ImageDraw.Draw(img)
    base = H * 0.86
    for i in range(26):
        x = rng.uniform(0.12, 0.88) * W
        r = rng.uniform(0.11, 0.24) * W * (1.0 - abs(x / W - 0.5) * 0.9)
        y = base - rng.uniform(0.0, 0.55) * H * (1.0 - abs(x / W - 0.5) * 1.3) - r * 0.2
        v = int(rng.uniform(150, 235))
        d.ellipse([x - r, y - r * 0.8, x + r, y + r * 0.8], fill=v)
    d.rectangle([W * 0.08, base - H * 0.12, W * 0.92, base], fill=210)
    img = img.filter(ImageFilter.GaussianBlur(9))
    # fade the very bottom so banks sit IN the ground instead of on a line
    px = img.load()
    for y in range(H):
        fb = min(1.0, max(0.0, (H - y) / (H * 0.10)))
        for x in range(W):
            px[x, y] = int(px[x, y] * fb)
    rgba = Image.new("RGBA", (W, H))
    shade = Image.new("L", (W, H))
    sp = shade.load()
    for y in range(H):
        for x in range(W):
            # lit billow tops, cooler shadowed underside
            sp[x, y] = int(236 - 34 * (y / H))
    rgba = Image.merge("RGBA", (shade, shade.point(lambda v: min(255, v + 4)), shade.point(lambda v: min(255, v + 8)), img))
    return rgba


def main():
    n = 4
    atlas = Image.new("RGBA", (W * n, H), (0, 0, 0, 0))
    meta = {"size": [W * n, H], "sprites": {}}
    for i in range(n):
        atlas.alpha_composite(bank(), (W * i, 0))
        meta["sprites"][f"mist_{i}"] = {"kind": "mist", "region": [W * i, 0, W, H], "world_size": [64, 44]}
    os.makedirs(OUT, exist_ok=True)
    atlas.save(os.path.join(OUT, "mist_atlas.png"))
    json.dump(meta, open(os.path.join(OUT, "mist_atlas.json"), "w"), indent=1)
    print("mist atlas", atlas.size)


if __name__ == "__main__":
    main()
