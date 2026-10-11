"""Generate tileable soft mist-veil detail texture (new support asset, approved PNGs untouched)."""
import random
from PIL import Image, ImageDraw, ImageFilter

random.seed(20260906)
S = 256
BASE = (206, 213, 209)
img = Image.new("RGB", (S, S), BASE)
d = ImageDraw.Draw(img, "RGBA")

def wrapped_ellipse(cx, cy, rx, ry, fill):
    for ox in (-S, 0, S):
        for oy in (-S, 0, S):
            d.ellipse([cx - rx + ox, cy - ry + oy, cx + rx + ox, cy + ry + oy], fill=fill)

for _ in range(46):
    cx, cy = random.randrange(S), random.randrange(S)
    rx, ry = random.randint(28, 70), random.randint(14, 34)
    v = random.randint(-13, 13)
    a = random.randint(10, 26)
    wrapped_ellipse(cx, cy, rx, ry, (BASE[0] + v, BASE[1] + v, BASE[2] + v, a))

for _ in range(120):
    cx, cy = random.randrange(S), random.randrange(S)
    rx, ry = random.randint(10, 42), random.randint(2, 6)
    v = random.randint(-10, 12)
    a = random.randint(8, 20)
    wrapped_ellipse(cx, cy, rx, ry, (BASE[0] + v, BASE[1] + v, BASE[2] + v, a))

img = img.filter(ImageFilter.GaussianBlur(4.5))
px = img.load()
for y in range(S):
    for x in range(S):
        r, g, b = px[x, y]
        px[x, y] = (
            max(170, min(240, BASE[0] + (r - BASE[0]) * 2 // 3)),
            max(170, min(240, BASE[1] + (g - BASE[1]) * 2 // 3)),
            max(170, min(240, BASE[2] + (b - BASE[2]) * 2 // 3)),
        )
out = "D:/Game development/Demon slayer/StrategyGame/assets/terrain/coherence_v2/mist_veil_soft.png"
img.save(out)
print("saved", out, img.size, img.mode)
