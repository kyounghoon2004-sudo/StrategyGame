"""Generate the B3D closeup foreground foliage frames (blurred near leaves)."""
import math, random
from PIL import Image, ImageDraw, ImageFilter

OUT = "assets/b3d/"

def leaf(draw, x, y, ang, L, W, col):
    pts = []
    for i in range(24):
        t = i / 23.0 * math.pi
        # leaf outline: pointed ellipse
        lx = math.cos(t) * L * 0.5
        ly = math.sin(t) ** 1.3 * W * 0.5
        pts.append((lx, ly))
    pts += [(-p[0], -p[1]) for p in pts]
    ca, sa = math.cos(ang), math.sin(ang)
    draw.polygon([(x + px * ca - py * sa, y + px * sa + py * ca) for px, py in pts], fill=col)

def branch(draw, rnd, x0, y0, ang, length, depth, leaf_scale, cols):
    x1 = x0 + math.cos(ang) * length
    y1 = y0 + math.sin(ang) * length
    draw.line([(x0, y0), (x1, y1)], fill=(18, 16, 10, 255), width=max(2, int(depth * 3)))
    n = int(length / (14 * leaf_scale)) + 2
    for i in range(n):
        t = i / max(n - 1, 1)
        bx = x0 + (x1 - x0) * t
        by = y0 + (y1 - y0) * t
        for s in (-1, 1):
            a = ang + s * rnd.uniform(0.5, 1.2)
            L = rnd.uniform(34, 60) * leaf_scale
            leaf(draw, bx + math.cos(a) * L * 0.45, by + math.sin(a) * L * 0.45, a, L, L * rnd.uniform(0.32, 0.45), rnd.choice(cols))
    if depth > 1:
        for k in range(rnd.randint(2, 3)):
            branch(draw, rnd, x0 + (x1 - x0) * rnd.uniform(0.3, 0.9), y0 + (y1 - y0) * rnd.uniform(0.3, 0.9),
                   ang + rnd.uniform(-0.9, 0.9), length * rnd.uniform(0.45, 0.7), depth - 1, leaf_scale * 0.9, cols)

def make(name, size, seeds, blur, cols, fade_edge):
    rnd = random.Random(hash(name) & 0xFFFF)
    img = Image.new("RGBA", size, (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    for (x, y, a, L, depth, sc) in seeds:
        branch(d, rnd, x, y, a, L, depth, sc, cols)
    img = img.filter(ImageFilter.GaussianBlur(blur))
    # soften the inner edge so the frame never ends in a hard line
    w, h = size
    mask = Image.new("L", size, 0)
    md = mask.load()
    for yy in range(h):
        for xx in range(w):
            md[xx, yy] = int(255 * fade_edge(xx / w, yy / h))
    a = img.split()[3]
    from PIL import ImageChops
    img.putalpha(ImageChops.multiply(a, mask))
    img.save(OUT + name)
    print("wrote", name, size)

dark = [(20, 30, 16, 255), (26, 38, 20, 255), (34, 46, 24, 255), (16, 24, 13, 255), (40, 52, 28, 255)]

make("fg_left.png", (620, 820),
     [(-40, 830, -1.05, 520, 3, 1.25), (-60, 700, -0.55, 480, 3, 1.15), (40, 900, -1.45, 600, 3, 1.3), (-30, 560, -0.25, 300, 2, 1.0)],
     7, dark, lambda u, v: min(1.0, (1.0 - u) * 1.6) * min(1.0, v * 1.8))
make("fg_right.png", (560, 620),
     [(620, 660, -2.2, 460, 3, 1.2), (600, 560, -2.7, 380, 3, 1.1), (560, 700, -1.8, 420, 2, 1.25)],
     8, dark, lambda u, v: min(1.0, u * 1.7) * min(1.0, v * 1.8))
make("fg_top.png", (760, 360),
     [(800, -20, 2.75, 560, 3, 1.1), (780, 40, 3.0, 420, 2, 1.0), (700, -40, 2.4, 300, 2, 0.95)],
     6, dark, lambda u, v: min(1.0, u * 1.8) * min(1.0, (1.0 - v) * 1.8))
