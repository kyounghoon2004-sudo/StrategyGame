"""Cuts the 4x2 icon sheet (painted icons on a dark vignette) into the 8 glyph PNGs the game expects.

Each icon is matted out of its cell with GrabCut (rect = rough bbox of the painting), kept as the largest blob with
holes filled, trimmed and written as a transparent PNG to assets/ui/v2_icons/<name>.png. The game draws the dark disc and
the owner-coloured ring around it, so the result is a round icon in the same style as the existing ones.

usage: python tools/rules_v2/cut_icon_sheet.py "<sheet.png>" [--preview out.png]
"""
import sys, os
import numpy as np
import cv2
from PIL import Image

SHEET = sys.argv[1]
OUT_DIR = os.path.join(os.path.dirname(__file__), '..', '..', 'assets', 'ui', 'v2_icons')
OUT_DIR = os.path.abspath(OUT_DIR)
PREVIEW = None
if '--preview' in sys.argv:
    PREVIEW = sys.argv[sys.argv.index('--preview') + 1]

# name -> rough bbox (x0, y0, x1, y1) of the painting in the 1536x1024 sheet
BOXES = {
    'village':     (30, 120, 395, 455),
    'city':        (392, 90, 778, 445),
    'fortress':    (780, 165, 1172, 448),
    'supply_base': (1180, 90, 1495, 455),
    'edge_base':   (20, 525, 390, 895),
    'palisade':    (425, 635, 760, 910),
    'occupier':    (815, 570, 1130, 895),
    'raid':        (1200, 550, 1490, 900),
}

img = cv2.imdecode(np.fromfile(SHEET, dtype=np.uint8), cv2.IMREAD_COLOR)   # unicode-safe path
H, W = img.shape[:2]
sx = W / 1536.0
sy = H / 1024.0
os.makedirs(OUT_DIR, exist_ok=True)
results = {}
for name, (x0, y0, x1, y1) in BOXES.items():
    x0, x1 = int(x0 * sx), int(x1 * sx)
    y0, y1 = int(y0 * sy), int(y1 * sy)
    pad = 30
    cx0, cy0 = max(0, x0 - pad), max(0, y0 - pad)
    cx1, cy1 = min(W, x1 + pad), min(H, y1 + pad)
    crop = img[cy0:cy1, cx0:cx1].copy()
    rx0, ry0, rx1, ry1 = x0 - cx0, y0 - cy0, x1 - cx0, y1 - cy0
    # Seed from DETAIL: the painting is full of fine edges, the glow / vignette behind it is smooth.
    gray = cv2.cvtColor(crop, cv2.COLOR_BGR2GRAY).astype(np.float32)
    gx = cv2.Sobel(gray, cv2.CV_32F, 1, 0, ksize=3)
    gy = cv2.Sobel(gray, cv2.CV_32F, 0, 1, ksize=3)
    mag = cv2.GaussianBlur(np.sqrt(gx * gx + gy * gy), (0, 0), 2.0)
    detail = (mag > 14.0).astype(np.uint8)
    inside = np.zeros_like(detail)
    inside[ry0:ry1, rx0:rx1] = 1
    detail = detail & inside
    detail = cv2.dilate(detail, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (9, 9)))
    detail = cv2.morphologyEx(detail, cv2.MORPH_CLOSE, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (31, 31)))
    n0, lab0, st0, _ = cv2.connectedComponentsWithStats(detail, connectivity=8)
    if n0 > 1:
        detail = (lab0 == 1 + int(np.argmax(st0[1:, cv2.CC_STAT_AREA]))).astype(np.uint8)
    cnts0, _ = cv2.findContours(detail, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    seed = np.zeros_like(detail)
    cv2.drawContours(seed, cnts0, -1, 1, thickness=cv2.FILLED)
    sure = cv2.erode(seed, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (41, 41)))
    maybe = cv2.dilate(seed, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (13, 13)))
    mask = np.full(crop.shape[:2], cv2.GC_BGD, np.uint8)
    mask[maybe == 1] = cv2.GC_PR_FGD
    mask[seed == 1] = cv2.GC_PR_FGD
    mask[sure == 1] = cv2.GC_FGD
    bgd = np.zeros((1, 65), np.float64)
    fgd = np.zeros((1, 65), np.float64)
    cv2.grabCut(crop, mask, None, bgd, fgd, 8, cv2.GC_INIT_WITH_MASK)
    fg = ((mask == cv2.GC_FGD) | (mask == cv2.GC_PR_FGD)).astype(np.uint8)
    # largest blob, holes filled, a hair of dilation so the painted outline survives
    n, lab, stats, _ = cv2.connectedComponentsWithStats(fg, connectivity=8)
    if n > 1:
        big = 1 + int(np.argmax(stats[1:, cv2.CC_STAT_AREA]))
        fg = (lab == big).astype(np.uint8)
    cnts, _ = cv2.findContours(fg, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    filled = np.zeros_like(fg)
    cv2.drawContours(filled, cnts, -1, 1, thickness=cv2.FILLED)
    k = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (5, 5))
    filled = cv2.dilate(filled, k, iterations=1)
    alpha = cv2.GaussianBlur(filled.astype(np.float32), (0, 0), 1.2)
    alpha = np.clip(alpha * 1.15 - 0.05, 0.0, 1.0)
    rgba = np.dstack([cv2.cvtColor(crop, cv2.COLOR_BGR2RGB), (alpha * 255).astype(np.uint8)])
    pil = Image.fromarray(rgba, 'RGBA')
    bbox = pil.getbbox()
    pil = pil.crop(bbox)
    side = max(pil.size)
    sq = Image.new('RGBA', (side, side), (0, 0, 0, 0))
    sq.paste(pil, ((side - pil.width) // 2, (side - pil.height) // 2))
    sq = sq.resize((256, 256), Image.LANCZOS)
    sq.save(os.path.join(OUT_DIR, name + '.png'))
    results[name] = sq
    print(name, 'cut ->', os.path.join(OUT_DIR, name + '.png'), 'blob px', int(filled.sum()))

if PREVIEW:
    # how they will look in the game: dark disc + owner ring + glyph
    from PIL import ImageDraw
    cell = 160
    sheet = Image.new('RGB', (cell * 4, cell * 4), (58, 61, 64))
    d = ImageDraw.Draw(sheet)
    for i, (name, glyph) in enumerate(results.items()):
        for row, ring_col in enumerate([(77, 153, 255), (242, 77, 71)]):
            ox = (i % 4) * cell
            oy = ((i // 4) * 2 + row) * cell
            cxm, cym = ox + cell // 2, oy + cell // 2
            r = 62
            d.ellipse([cxm - r, cym - r, cxm + r, cym + r], fill=ring_col)
            d.ellipse([cxm - r + 7, cym - r + 7, cxm + r - 7, cym + r - 7], fill=(26, 26, 33))
            g = glyph.resize((84, 84), Image.LANCZOS)
            sheet.paste(g, (cxm - 42, cym - 42), g)
    sheet.save(PREVIEW)
    print('preview ->', PREVIEW)
