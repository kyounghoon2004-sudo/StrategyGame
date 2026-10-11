"""Bake the HQ command banners (帥) for the B3D view."""
from PIL import Image, ImageDraw, ImageFont, ImageFilter
import random

def make(name, cloth, ink, border):
    W, H = 256, 320
    img = Image.new("RGB", (W, H), cloth)
    d = ImageDraw.Draw(img)
    rnd = random.Random(5)
    for i in range(1400):  # cloth grain
        x, y = rnd.randrange(W), rnd.randrange(H)
        c = tuple(max(0, v - rnd.randint(4, 14)) for v in cloth)
        d.point((x, y), fill=c)
    d.rectangle([0, 0, 26, H], fill=border)          # hoist band
    d.rectangle([0, 0, W, 18], fill=border)
    d.rectangle([0, H - 18, W, H], fill=border)
    d.rectangle([34, 28, W - 14, H - 28], outline=border, width=5)
    f = ImageFont.truetype("C:/Windows/Fonts/batang.ttc", 200, index=0)
    bb = d.textbbox((0, 0), "帥", font=f)
    tw, th = bb[2] - bb[0], bb[3] - bb[1]
    d.text(((W + 20 - tw) / 2 - bb[0], (H - th) / 2 - bb[1]), "帥", font=f, fill=ink)
    img = img.filter(ImageFilter.GaussianBlur(0.6))
    img.save("assets/b3d/" + name)
    print("wrote", name)

make("banner_blue.png", (232, 226, 206), (22, 34, 92), (26, 44, 118))
make("banner_red.png", (232, 222, 200), (120, 20, 14), (140, 26, 18))
