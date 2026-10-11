#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Sprint 5: Tactical UI & Visual Asset 1:1 Overhaul
Generates all assets per the visual specification:
- portrait_advisor.png (96x96, Zhuge Liang style)
- ui_target_beacon.png (48x48, golden crosshair)
- ui_move_green.png, ui_move_orange.png, ui_move_red.png, ui_move_black.png
  (48x42 hex-shaped heatmaps with specified alpha)
- ui_banner_target.png (golden banner)
- Updated unit sprites (green armor + blue/red faction accents)
- Updated fortress terrain tile (red tiled roof, gray stone walls)
- Tactical sidebar panel elements
"""
import os
from PIL import Image, ImageDraw, ImageFont

BASE = r"D:\Game development\Demon slayer\StrategyGame\assets"
TILE_DIR = os.path.join(BASE, "tiles")
SPRITE_DIR = os.path.join(BASE, "sprites")
UI_DIR = os.path.join(BASE, "ui")

for d in [TILE_DIR, SPRITE_DIR, UI_DIR]:
    os.makedirs(d, exist_ok=True)

# ============================================================
# Constants
# ============================================================
TILE_W = 48
TILE_H = 42
HEX_POINTS_FLAT = [(12, 0), (36, 0), (48, 21), (36, 42), (12, 42), (0, 21)]
HEX_POINTS_INNER = [(13, 1), (35, 1), (47, 21), (35, 41), (13, 41), (1, 21)]
SPRITE_W = 24
SPRITE_H = 24
DARK_OUTLINE = (20, 20, 24, 255)
BLACK = (26, 26, 26, 255)
GOLD = (212, 175, 55, 255)
GOLD_DARK = (166, 124, 30, 255)
GOLD_LIGHT = (255, 215, 0, 255)

# Palette colors from spec
GREEN = "#2ECC71"
ORANGE = "#E67E22"
RED = "#E74C3C"
DARK_BG = "#121218"
BEIGE = "#EFECE6"
CREAM = "#F8F9FA"
SLEEP = "#A67C1E"  # gold shadow
BLACK_HEX = "#1A1A24"

# Green armor (base for all units)
GREEN_ARMOR = (46, 147, 75, 255)
GREEN_ARMOR_DARK = (35, 110, 55, 255)
GREEN_ARMOR_LIGHT = (60, 170, 85, 255)
SKIN = (242, 201, 160, 255)
SKIN_SHADOW = (212, 167, 122, 255)
METAL = (192, 200, 208, 255)
METAL_LIGHT = (232, 238, 242, 255)
WOOD = (139, 90, 33, 255)
WOOD_DARK = (93, 58, 26, 255)
BLUE = (58, 112, 237, 255)      # ally accent
RED_ACCENT = (231, 77, 77, 255)  # enemy accent

# Movement heatmap colors with alpha (as specified)
HEATMAP_GREEN = (46, 204, 113, 115)   # #2ECC71 alpha 0.45
HEATMAP_ORANGE = (230, 126, 34, 128)   # #E67E22 alpha 0.50
HEATMAP_RED = (231, 76, 60, 140)       # #E74C3C alpha 0.55
HEATMAP_BLACK = (26, 26, 36, 178)      # #1A1A24 alpha 0.70


def hex_to_rgba(h):
    h = h.lstrip("#")
    return (int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16), 255)


# ============================================================
# TILE: Updated Fortress — red tiled roof, gray stone walls, red pillars
# ============================================================
def terrain_fortress_updated():
    img = Image.new("RGBA", (TILE_W, TILE_H), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    # Fill hex shape
    draw.polygon(HEX_POINTS_FLAT, fill=(138, 155, 162, 255))
    # Stone walls — gray with texture
    wall_outer = [12, 14, 36, 32]
    draw.rectangle(wall_outer, fill=(176, 188, 196, 255), outline=(44, 50, 52, 255), width=1)
    # Brick lines on walls
    for y in [18, 22, 26, 30]:
        draw.line([(13, y), (35, y)], fill=(139, 149, 158, 255), width=1)
    # Red pillars (4 red columns at corners)
    pillar_color = (200, 60, 50, 255)
    pillar_dark = (150, 40, 35, 255)
    # Left pillars
    for px in [12, 34]:
        draw.rectangle([px, 14, px + 3, 30], fill=pillar_color, outline=pillar_dark)
        # Pillar detail — groove
        draw.line([(px + 1, 16), (px + 1, 28)], fill=pillar_dark, width=1)
        draw.line([(px + 2, 16), (px + 2, 28)], fill=pillar_dark, width=1)
    # Red tiled roof — slanted
    roof_main = (180, 70, 55, 255)
    roof_dark = (140, 45, 35, 255)
    # Roof polygon (flat-top hex, roof sits below top edge)
    draw.polygon([(12, 14), (14, 10), (34, 10), (36, 14)], fill=roof_main, outline=roof_dark)
    # Roof tiles — horizontal ridges
    for y in [11, 13]:
        draw.line([(14, y), (34, y)], fill=roof_dark, width=1)
    # Roof edge highlight
    draw.line([(12, 14), (36, 14)], fill=roof_dark, width=1)
    # Gate — arched entrance between red pillars
    draw.rectangle([21, 24, 27, 32], fill=(40, 30, 25, 255), outline=(20, 15, 10, 255))
    draw.polygon([(21, 24), (24, 20), (27, 24)], fill=(40, 30, 25, 255))  # arch top
    draw.line([(21, 24), (24, 20)], fill=(20, 15, 10, 255), width=1)
    draw.line([(27, 24), (24, 20)], fill=(20, 15, 10, 255), width=1)
    # Door
    draw.rectangle([23, 26, 25, 32], fill=(60, 35, 20, 255))
    draw.line([(24, 26), (24, 32)], fill=(20, 15, 10, 255), width=1)
    # Window
    draw.rectangle([15, 20, 18, 22], fill=(60, 80, 100, 255))
    draw.rectangle([29, 20, 32, 22], fill=(60, 80, 100, 255))
    # Battlements on roof
    for x in [12, 16, 20, 24, 28]:
        draw.rectangle([x, 9, x + 3, 11], fill=(130, 40, 30, 255))
    # Hex outline
    draw.polygon(HEX_POINTS_FLAT, outline=(43, 43, 43, 255), width=1)
    # Top inner highlight
    draw.line([(13, 1), (35, 1)], fill=(230, 235, 240, 255), width=1)
    return img


# ============================================================
# UI: Portrait — Zhuge Liang style (96x96)
# ============================================================
def ui_portrait_advisor():
    W = H = 96
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    # Draw the hex frame first (portrait fits inside 88x88 circle/hex)
    # Use a hex frame
    hex_pts = [(8, 4), (28, 2), (68, 2), (88, 4), (88, 92), (68, 94), (28, 94), (8, 92)]
    # Actually, make it a rounded portrait — circular with gold frame
    cx, cy = 48, 50
    rad = 40
    # Gold frame
    draw.ellipse([cx - rad, cy - rad, cx + rad, cy + rad], outline=GOLD, width=3)
    # Inner dark bg
    draw.ellipse([cx - rad + 3, cy - rad + 3, cx + rad - 3, cy + rad - 3], fill=DARK_BG)
    # Face — pale skin
    draw.ellipse([cx - 26, cy - 22, cx + 26, cy + 30], fill=SKIN)
    # Beard — long, flowing
    beard_start = cy - 4
    # Beard shape (pointed at bottom)
    draw.polygon(
        [(cx - 14, beard_start), (cx + 14, beard_start), (cx + 10, cy + 28), (cx - 10, cy + 28)],
        fill=(40, 40, 40, 255),
        outline=DARK_BG,
    )
    # Mustache
    draw.polygon(
        [(cx - 12, cy + 8), (cx + 12, cy + 8), (cx + 8, cy + 22), (cx - 8, cy + 22)],
        fill=(30, 30, 30, 255),
    )
    # Eyes (half-closed, wise)
    draw.arc([cx - 10, cy - 8, cx - 2, cy + 2], 30, 150, fill=BLACK, width=1)
    draw.arc([cx + 2, cy - 8, cx + 10, cy + 2], 30, 150, fill=BLACK, width=1)
    # Black hat (broad, flowing)
    # Hat brim
    draw.rectangle([cx - 36, cy - 28, cx + 36, cy - 22], fill=BLACK)
    # Hat top (tall, narrow)
    draw.rectangle([cx - 22, cy - 52, cx + 22, cy - 28], fill=BLACK)
    # Gold crescent on hat
    crescent_y = cy - 42
    # Draw crescent: two overlapping ellipses, one gold one darker bg
    draw.ellipse([cx - 12, crescent_y - 4, cx + 12, crescent_y + 4], fill=GOLD)
    draw.ellipse([cx - 9, crescent_y - 3, cx + 9, crescent_y + 3], fill=BLACK)
    # Hat tassel / decoration
    draw.polygon(
        [(cx - 22, cy - 38), (cx - 16, cy - 32), (cx - 20, cy - 30)],
        fill=GOLD,
    )
    # Robe / clothing (dark with gold trim)
    draw.polygon(
        [(cx - 22, cy + 24), (cx + 22, cy + 24), (cx + 28, cy + 56), (cx - 28, cy + 56)],
        fill=DARK_BG,
        outline=GOLD_DARK,
    )
    # Gold trim on robe
    draw.line([(cx - 22, cy + 26), (cx - 24, cy + 38)], fill=G, width=1) if False else None
    draw.polygon(
        [(cx - 20, cy + 26), (cx + 20, cy + 26), (cx + 24, cy + 48), (cx - 24, cy + 48)],
        fill=(212, 175, 55, 60),
    )
    # Hands holding scrolls
    # Left hand
    draw.rectangle([cx - 28, cy + 40, cx - 24, cy + 52], fill=SKIN)
    # Right hand
    draw.rectangle([cx + 24, cy + 40, cx + 28, cy + 52], fill=SKIN)
    # Scrolls
    draw.rectangle([cx - 27, cy + 42, cx - 25, cy + 50], fill=(40, 30, 20, 255))
    draw.rectangle([cx + 25, cy + 42, cx + 27, cy + 50], fill=(40, 30, 20, 255))
    return img


# ============================================================
# UI: Target Beacon — golden crosshair (48x48)
# ============================================================
def ui_target_beacon():
    W = H = 48
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    cx, cy = W // 2, H // 2
    ring_outer = 18
    ring_inner = 12
    # Outer gold ring
    draw.ellipse(
        [cx - ring_outer, cy - ring_outer, cx + ring_outer, cy + ring_outer],
        outline=GOLD_LIGHT, width=2,
    )
    # Inner ring
    draw.ellipse(
        [cx - ring_inner, cy - ring_inner, cx + ring_inner, cy + ring_inner],
        outline=GOLD, width=1,
    )
    # Crosshairs (4 arms)
    arm_len = 6
    arm_w = 2
    # Vertical
    draw.rectangle([cx - arm_w // 2, cy - ring_inner - arm_len, cx + arm_w // 2, cy - ring_inner], fill=GOLD)
    draw.rectangle([cx - arm_w // 2, cy + ring_inner, cx + arm_w // 2, cy + ring_inner + arm_len], fill=GOLD)
    # Horizontal
    draw.rectangle([cx - ring_inner - arm_len, cy - arm_w // 2, cx - ring_inner, cy + arm_w // 2], fill=GOLD)
    draw.rectangle([cx + ring_inner, cy - arm_w // 2, cx + ring_inner + arm_len, cy + arm_w // 2], fill=GOLD)
    # Center dot
    draw.ellipse([cx - 2, cy - 2, cx + 2, cy + 2], fill=GOLD_LIGHT)
    # Glow particles (4 small dots around outer ring)
    for i in range(4):
        import math
        angle = i * math.pi / 2
        px = cx + int(24 * math.cos(angle))
        py = cy + int(24 * math.sin(angle))
        draw.ellipse([px - 1, py - 1, px + 1, py + 1], fill=(255, 215, 0, 180))
    return img


# ============================================================
# UI: Movement Heatmap Overlays (48x42 hex-shaped)
# ============================================================
def make_move_overlay(color_rgba, label=""):
    img = Image.new("RGBA", (TILE_W, TILE_H), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    # Fill hex with specified color
    draw.polygon(HEX_POINTS_FLAT, fill=color_rgba)
    # Subtle inner border
    draw.polygon(HEX_POINTS_INNER, outline=(255, 255, 255, 40), width=1)
    # Center indicator dot
    cx, cy = 24, 21
    draw.ellipse([cx - 3, cy - 3, cx + 3, cy + 3], fill=(255, 255, 255, 80), outline=(255, 255, 255, 120))
    return img


def ui_move_green():
    return make_move_overlay(HEATMAP_GREEN)


def ui_move_orange():
    return make_move_overlay(HEATMAP_ORANGE)


def ui_move_red():
    return make_move_overlay(HEATMAP_RED)


def ui_move_black():
    return make_move_overlay(HEATMAP_BLACK)


# ============================================================
# UI: Golden Target Banner (240x64)
# ============================================================
def ui_banner_target():
    W, H = 240, 64
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    # Banner base — golden yellow with dark gold border
    draw.rounded_rectangle(
        [2, 2, W - 2, H - 2],
        fill=GOLD,
        outline=GOLD_DARK,
        width=3,
        radius=6,
    )
    # Inner dark inset for text
    draw.rounded_rectangle(
        [8, 8, W - 8, H - 8],
        fill=(120, 90, 20, 255),
        radius=4,
    )
    # Top edge shine
    draw.line([(8, 8), (W - 8, 8)], fill=GOLD_LIGHT, width=1)
    # Text: "목표: 북부 요새 함락"
    txt = "목표: 북부 요새 함락"
    # Try to find a font
    font = None
    for fp in [
        "C:/Windows/Fonts/gulim.ttc",
        "C:/Windows/Fonts/malgunbd.ttf",
        "C:/Windows/Fonts/malgun.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    ]:
        if os.path.exists(fp):
            try:
                font = ImageFont.truetype(fp, 18)
                break
            except:
                pass
    if font is None:
        font = ImageFont.load_default()
    # Draw text centered
    bbox = draw.textbbox((0, 0), txt, font=font)
    tw = bbox[2] - bbox[0]
    th = bbox[3] - bbox[1]
    tx = (W - tw) // 2
    ty = (H - th) // 2 + 2
    draw.text((tx + 1, ty + 1), txt, fill=(20, 20, 24, 255), font=font)
    draw.text((tx, ty), txt, fill=(40, 40, 30, 255), font=font)
    # Gold border on text
    draw.text((tx, ty), txt, fill=None, font=font, outline=GOLD_DARK)
    return img


# ============================================================
# UI: Tactical Button Base (120x32) — dark gold filigree
# ============================================================
def ui_tactical_button(highlight=False):
    W, H = 120, 32
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    # Dark panel base
    draw.rounded_rectangle(
        [1, 1, W - 1, H - 1],
        fill=(30, 28, 26, 230),
        outline=GOLD if highlight else GOLD_DARK,
        width=2 if highlight else 1,
        radius=5,
    )
    # Inner bevel
    draw.line([(2, 2), (W - 2, 2)], fill=(50, 45, 38, 255), width=1)
    draw.line([(2, 2), (2, H - 2)], fill=(50, 45, 38, 255), width=1)
    return img


# ============================================================
# UI: Pixel icons for tactical buttons (16x16)
# ============================================================
def make_icon_sword():
    img = Image.new("RGBA", (16, 16), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    # Blade
    d.rectangle([7, 2, 9, 12], fill=METAL_LIGHT)
    d.line([(8, 3), (8, 11)], fill=METAL, width=1)
    # Guard
    d.line([(5, 12), (11, 12)], fill=GOLD, width=2)
    # Handle
    d.rectangle([7, 12, 9, 14], fill=(80, 50, 20, 255))
    # Pommel
    d.rectangle([7, 14, 9, 15], fill=METAL)
    return img


def make_icon_shield():
    img = Image.new("RGBA", (16, 16), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    # Shield shape
    d.polygon([(8, 1), (14, 4), (14, 10), (8, 15), (2, 10), (2, 4)], fill=(100, 80, 60, 255))
    d.polygon([(8, 2), (12, 4), (12, 9), (8, 13), (4, 9), (4, 4)], fill=(130, 100, 70, 255))
    # Emblem
    d.ellipse([6, 5, 10, 9], fill=GOLD)
    return img


def make_icon_forest():
    img = Image.new("RGBA", (16, 16), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    # Two trees
    for cx in [5, 11]:
        # Trunk
        d.rectangle([cx - 1, 8, cx + 1, 12], fill=(93, 62, 26, 255))
        # Canopy
        d.ellipse([cx - 4, 4, cx + 4, 10], fill=(47, 127, 58, 255))
        d.ellipse([cx - 3, 3, cx + 3, 9], fill=(47, 127, 58, 255))
    return img


def make_icon_arrow():
    img = Image.new("RGBA", (16, 16), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    # Arrow shaft
    d.rectangle([7, 3, 9, 13], fill=WOOD_DARK)
    d.line([(8, 4), (8, 12)], fill=WOOD, width=1)
    # Arrow head
    d.polygon([(5, 4), (11, 4), (8, 1)], fill=(192, 200, 208, 255))
    # Fletching
    d.polygon([(7, 13), (5, 15), (9, 14)], fill=(192, 200, 208, 255))
    d.polygon([(9, 13), (11, 15), (7, 14)], fill=(192, 200, 208, 255))
    # Tail feathers
    d.line([(8, 13), (6, 16)], fill=WOOD, width=1)
    return img


# ============================================================
# UI: Tactical Sidebar Panel Background (320x720)
# ============================================================
def ui_sidebar_panel():
    W, H = 320, 720
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    # Dark gold filigree background (#121218)
    draw.rounded_rectangle(
        [0, 0, W, H],
        fill=hex_to_rgba(DARK_BG),
        outline=GOLD,
        width=4,
        radius=16,
    )
    # Inner panel
    draw.rounded_rectangle(
        [6, 6, W - 6, H - 6],
        fill=hex_to_rgba("#0D0D12"),
        radius=12,
    )
    # Gold filigree border pattern — corners
    corner_patterns = [
        # Top-left
        [(8, 8), (18, 8), (8, 18)],
        [(10, 8), (18, 8), (10, 14)],
        # Top-right
        [(W - 8, 8), (W - 18, 8), (W - 8, 18)],
        [(W - 10, 8), (W - 18, 8), (W - 10, 14)],
        # Bottom-left
        [(8, H - 8), (18, H - 8), (8, H - 18)],
        [(10, H - 8), (18, H - 8), (10, H - 14)],
        # Bottom-right
        [(W - 8, H - 8), (W - 18, H - 8), (W - 8, H - 18)],
        [(W - 10, H - 8), (W - 18, H - 8), (W - 10, H - 14)],
    ]
    for poly in corner_patterns:
        draw.polygon(poly, fill=(212, 175, 55, 90))
    # Horizontal gold divider lines (filigree)
    for y in [120, 360, 660]:
        draw.line([(8, y), (W - 8, y)], fill=(212, 175, 55, 60), width=1)
        # Small diamond pattern along divider
        for x in range(20, W - 20, 24):
            draw.ellipse([x, y - 1, x + 2, y + 1], fill=(212, 175, 55, 80))
    return img


# ============================================================
# UI: Dialogue Bubble (280x80) — cream colored with left-pointing tail
# ============================================================
def ui_dialogue_bubble():
    W, H = 280, 80
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    # Cream box
    d.rounded_rectangle(
        [16, 2, W - 2, H - 2],
        fill=hex_to_rgba(CREAM),
        outline=hex_to_rgba("#8B734F"),
        width=1,
        radius=8,
    )
    # Inner darker inset for text
    d.rounded_rectangle(
        [18, 4, W - 4, H - 4],
        fill=hex_to_rgba("#F0EEDF"),
        radius=6,
    )
    # Tail — pointing left (toward portrait)
    tail = [(6, 30), (22, 42), (6, 54)]
    d.polygon(tail, fill=hex_to_rgba(CREAM), outline=hex_to_rgba("#8B734F"))
    # Tail inner shadow
    d.polygon([(7, 31), (20, 42), (7, 53)], fill=hex_to_rgba("#F0EEDF"))
    return img


# ============================================================
# UI: Command Input Bar (280x32) — dark field with > cursor
# ============================================================
def ui_command_input_bar():
    W, H = 280, 32
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    # Dark input field (#0D0D12)
    d.rounded_rectangle(
        [2, 2, W - 2, H - 2],
        fill=hex_to_rgba("#0D0D12"),
        outline=GOLD_DARK,
        width=2,
        radius=6,
    )
    # Inner padding
    d.rounded_rectangle(
        [6, 6, W - 6, H - 6],
        fill=hex_to_rgba("#0A0A0E"),
        radius=4,
    )
    # > cursor prompt
    d.text((10, 9), ">", fill=(212, 175, 55, 255))
    # Placeholder text "명령을 입력하세요..."
    d.text((22, 9), "명령을 입력하세요...", fill=(150, 140, 120, 200))
    return img


# ============================================================
# Unit Sprites — 24x24 with green armor + faction accents
# ============================================================
SPRITE_W = 24
SPRITE_H = 24
GREEN_ARMOR = (46, 125, 50, 255)     # Material green
GREEN_ARMOR_D = (35, 95, 40, 255)    # Dark green
GREEN_ARMOR_L = (72, 152, 65, 255)   # Light green
SKIN = (242, 201, 160, 255)
SKIN_D = (212, 167, 122, 255)
METAL = (192, 200, 208, 255)
METAL_L = (232, 238, 242, 255)
METAL_D = (130, 140, 150, 255)
WOOD = (139, 90, 33, 255)
WOOD_D = (93, 58, 26, 255)
BROWN = (108, 68, 34, 255)
BLACK = (26, 26, 26, 255)
WHITE = (245, 245, 245, 255)
BLUE_F = (58, 112, 237, 255)
RED_F = (220, 60, 55, 255)
DARK_OUTLINE = (20, 20, 24, 255)


def sprite_canvas():
    return Image.new("RGBA", (SPRITE_W, SPRITE_H), (0, 0, 0, 0)), ImageDraw.Draw(img)


def _new_sprite():
    img = Image.new("RGBA", (SPRITE_W, SPRITE_H), (0, 0, 0, 0))
    return img, ImageDraw.Draw(img)


def infantry_sprite(faction):
    img, d = _new_sprite()
    fac = BLUE_F if faction == "blue" else RED_F
    # Shadow
    d.ellipse([6, 19, 18, 22], fill=(0, 0, 0, 70))
    # Legs
    d.rectangle([7, 12, 9, 20], fill=GREEN_ARMOR_D, outline=DARK_OUTLINE)
    d.rectangle([15, 12, 17, 20], fill=GREEN_ARMOR_D, outline=DARK_OUTLINE)
    # Feet
    d.rectangle([6, 20, 10, 21], fill=(50, 40, 30, 255), outline=DARK_OUTLINE)
    d.rectangle([14, 20, 18, 21], fill=(50, 40, 30, 255), outline=DARK_OUTLINE)
    # Body armor (green)
    d.rectangle([7, 6, 17, 13], fill=GREEN_ARMOR, outline=DARK_OUTLINE)
    d.rectangle([8, 6, 16, 11], fill=GREEN_ARMOR_L)
    # Belt
    d.rectangle([7, 10, 17, 11], fill=(80, 60, 30, 255))
    # Shoulders with faction color
    d.rectangle([7, 6, 8, 8], fill=fac, outline=DARK_OUTLINE)
    d.rectangle([16, 6, 17, 8], fill=fac, outline=DARK_OUTLINE)
    # Head
    d.rectangle([9, 1, 15, 6], fill=SKIN, outline=DARK_OUTLINE)
    d.rectangle([9, 1, 11, 4], fill=SKIN)  # highlight
    # Green helmet
    d.rectangle([8, 0, 16, 3], fill=GREEN_ARMOR, outline=DARK_OUTLINE)
    # Faceguard / visor
    d.rectangle([10, 1, 14, 2], fill=(20, 20, 24, 255))
    # Eyes
    d.point((11, 1), fill=WHITE)
    d.point((13, 1), fill=WHITE)
    # Shield (round, left side)
    d.ellipse([3, 7, 7, 11], fill=WOOD, outline=DARK_OUTLINE)
    d.ellipse([4, 8, 6, 10], fill=fac, outline=DARK_OUTLINE)
    # Sword
    d.rectangle([18, 5, 20, 16], fill=METAL, outline=DARK_OUTLINE)
    d.line([(19, 6), (19, 15)], fill=METAL_L, width=1)
    d.line([(17, 12), (21, 12)], fill=fac, width=1)  # crosspiece
    d.rectangle([18, 16, 20, 17], fill=fac)  # pommel
    return img


def archer_sprite(faction):
    img, d = _new_sprite()
    fac = BLUE_F if faction == "blue" else RED_F
    # Shadow
    d.ellipse([6, 20, 18, 22], fill=(0, 0, 0, 70))
    # Legs
    d.rectangle([8, 14, 10, 20], fill=GREEN_ARMOR_D, outline=DARK_OUTLINE)
    d.rectangle([14, 14, 16, 20], fill=GREEN_ARMOR_D, outline=DARK_OUTLINE)
    d.rectangle([7, 20, 11, 21], fill=(50, 40, 30, 255), outline=DARK_OUTLINE)
    d.rectangle([13, 20, 17, 21], fill=(50, 40, 30, 255), outline=DARK_OUTLINE)
    # Body (green tunic)
    d.rectangle([8, 7, 16, 14], fill=GREEN_ARMOR, outline=DARK_OUTLINE)
    d.rectangle([8, 7, 10, 11], fill=GREEN_ARMOR_L)
    # Belt
    d.rectangle([8, 11, 16, 12], fill=(80, 60, 30, 255))
    # Green hood
    d.rectangle([9, 1, 15, 5], fill=GREEN_ARMOR, outline=DARK_OUTLINE)
    d.rectangle([9, 1, 12, 3], fill=GREEN_ARMOR_D)
    # Face visible
    d.rectangle([11, 2, 13, 4], fill=SKIN)
    d.point((11, 3), fill=BLACK)
    d.point((13, 3), fill=BLACK)
    # Arm drawing bow (left arm)
    d.rectangle([7, 9, 9, 11], fill=SKIN)
    # Bow — curved
    d.arc([(5, 5), (12, 12)], 315, 135, fill=WOOD, width=1)
    d.line([(6, 6), (6, 10)], fill=WOOD, width=1)
    # Bowstring
    d.line([(7, 6), (7, 10)], fill=(230, 230, 230, 255), width=1)
    # Arrow nocked
    d.line([(7, 7), (4, 7)], fill=WOOD_D, width=1)
    d.polygon([(4, 6), (4, 8), (2, 7)], fill=METAL)
    # Quiver on back
    d.rectangle([4, 7, 6, 14], fill=WOOD_D, outline=DARK_OUTLINE)
    # Faction armband
    d.rectangle([6, 7, 7, 8], fill=fac)
    return img


def cavalry_sprite(faction):
    img, d = _new_sprite()
    fac = BLUE_F if faction == "blue" else RED_F
    # Shadow (horse)
    d.ellipse([3, 19, 21, 22], fill=(0, 0, 0, 80))
    # Horse body (brown)
    horse_body = (108, 68, 34, 255)
    horse_dark = (80, 50, 26, 255)
    horse_light = (140, 90, 45, 255)
    # Horse torso
    d.rectangle([4, 10, 18, 18], fill=horse_body, outline=DARK_OUTLINE)
    d.rectangle([5, 11, 7, 17], fill=horse_light)
    # Horse neck and head
    d.rectangle([16, 6, 20, 11], fill=horse_body, outline=DARK_OUTLINE)
    d.rectangle([16, 6, 17, 9], fill=horse_light)
    d.rectangle([19, 8, 21, 12], fill=horse_body, outline=DARK_OUTLINE)
    d.rectangle([20, 9, 21, 10], fill=horse_dark)
    # Ears
    d.line([(18, 6), (19, 5)], fill=horse_dark, width=1)
    d.line([(19, 6), 20, 5], fill=horse_dark, width=1) if False else d.line([(20, 6), (21, 5)], fill=horse_dark, width=1)
    # Horse legs
    d.rectangle([5, 18, 7, 20], fill=horse_dark, outline=DARK_OUTLINE)
    d.rectangle([10, 18, 12, 20], fill=horse_dark, outline=DARK_OUTLINE)
    d.rectangle([14, 18, 16, 20], fill=horse_dark, outline=DARK_OUTLINE)
    d.rectangle([17, 18, 19, 20], fill=horse_dark, outline=DARK_OUTLINE)
    # Tail
    d.rectangle([3, 12, 4, 16], fill=horse_dark, outline=(50, 30, 15, 255))
    # Saddle
    d.rectangle([10, 9, 14, 11], fill=(120, 80, 40, 255), outline=DARK_OUTLINE)
    d.rectangle([11, 9, 13, 10], fill=(140, 90, 50, 255))
    # Rider body (green armor)
    d.rectangle([9, 4, 14, 9], fill=GREEN_ARMOR, outline=DARK_OUTLINE)
    d.rectangle([9, 4, 11, 7], fill=GREEN_ARMOR_L)
    # Rider head
    d.rectangle([10, 1, 14, 4], fill=SKIN, outline=DARK_OUTLINE)
    d.rectangle([10, 1, 12, 3], fill=SKIN)
    # Green helmet with plume
    d.rectangle([9, 0, 15, 2], fill=GREEN_ARMOR, outline=DARK_OUTLINE)
    d.rectangle([9, 0, 11, 1], fill=GREEN_ARMOR_D)
    # Plume
    d.rectangle([12, 0, 13, 1], fill=fac)
    # Eyes
    d.point((11, 2), fill=BLACK)
    d.point((13, 2), fill=BLACK)
    # Sword held forward
    d.rectangle([17, 3, 19, 14], fill=METAL, outline=DARK_OUTLINE)
    d.line([(18, 4), (18, 13)], fill=METAL_L, width=1)
    d.polygon([(18, 3), (20, 4), (18, 5)], fill=METAL_L)
    d.rectangle([17, 14, 19, 15], fill=fac)  # pommel
    return img


def spearman_sprite(faction):
    img, d = _new_sprite()
    fac = BLUE_F if faction == "blue" else RED_F
    # Shadow
    d.ellipse([6, 19, 18, 22], fill=(0, 0, 0, 70))
    # Legs
    d.rectangle([8, 12, 10, 20], fill=GREEN_ARMOR_D, outline=DARK_OUTLINE)
    d.rectangle([14, 12, 16, 20], fill=GREEN_ARMOR_D, outline=DARK_OUTLINE)
    d.rectangle([7, 20, 11, 21], fill=(50, 40, 30, 255), outline=DARK_OUTLINE)
    d.rectangle([13, 20, 17, 21], fill=(50, 40, 30, 255), outline=DARK_OUTLINE)
    # Body (green mail armor)
    d.rectangle([8, 6, 16, 13], fill=GREEN_ARMOR, outline=DARK_OUTLINE)
    d.rectangle([9, 6, 11, 11], fill=GREEN_ARMOR_L)
    # Belt
    d.rectangle([8, 10, 16, 11], fill=(80, 60, 30, 255))
    # Head with helm
    d.rectangle([10, 1, 14, 6], fill=SKIN, outline=DARK_OUTLINE)
    d.rectangle([9, 0, 15, 3], fill=GREEN_ARMOR, outline=DARK_OUTLINE)
    d.rectangle([9, 0, 12, 2], fill=GREEN_ARMOR_D)
    # Neck guard
    d.line([(9, 3), (8, 4)], fill=DARK_OUTLINE, width=1)
    d.line([(15, 3), (16, 4)], fill=DARK_OUTLINE, width=1)
    d.point((11, 4), fill=BLACK)
    d.point((13, 4), fill=BLACK)
    # Long spear — vertical, held with both hands
    d.rectangle([11, 0, 12, 18], fill=WOOD, outline=DARK_OUTLINE)
    d.line([(11, 2), (12, 17)], fill=WOOD_D, width=1)
    # Spearhead (blade)
    d.polygon([(10, 0), (13, 0), (12, 2), (11, 2)], fill=METAL, outline=METAL_D)
    d.line([(11, 1), (12, 1)], fill=METAL_L, width=1)
    # Spear butt
    d.rectangle([10, 18, 13, 20], fill=METAL_D, outline=DARK_OUTLINE)
    # Shoulder guards (faction color)
    d.rectangle([7, 6, 8, 8], fill=fac, outline=DARK_OUTLINE)
    d.rectangle([16, 6, 17, 8], fill=fac, outline=DARK_OUTLINE)
    # Small round shield on back left
    d.ellipse([4, 8, 8, 12], fill=WOOD, outline=DARK_OUTLINE)
    d.ellipse([5, 9, 7, 11], fill=fac, outline=METAL)
    return img


def siege_sprite(faction):
    img, d = _new_sprite()
    fac = BLUE_F if faction == "blue" else RED_F
    # Shadow
    d.ellipse([3, 19, 21, 22], fill=(0, 0, 0, 70))
    # Base platform
    d.rectangle([4, 16, 20, 19], fill=WOOD, outline=DARK_OUTLINE)
    d.rectangle([5, 17, 7, 18], fill=(150, 100, 55, 255))
    # Wheels
    d.ellipse([5, 18, 8, 21], fill=WOOD_D, outline=DARK_OUTLINE)
    d.ellipse([6, 19, 7, 20], fill=(58, 34, 12, 255))
    d.ellipse([16, 18, 19, 21], fill=WOOD_D, outline=DARK_OUTLINE)
    d.ellipse([17, 19, 18, 20], fill=(58, 34, 12, 255))
    # A-frame
    d.polygon([(8, 16), (11, 7), (12, 7), (9, 16)], fill=WOOD, outline=DARK_OUTLINE)
    d.polygon([(16, 16), (13, 7), (14, 7), (17, 16)], fill=WOOD_D, outline=DARK_OUTLINE)
    # Arm
    d.line([(10, 9), (18, 4)], fill=WOOD, width=1)
    d.polygon([(9, 8), (12, 6), (19, 4), (18, 6)], fill=WOOD, outline=DARK_OUTLINE)
    # Counterweight
    d.rectangle([8, 10, 10, 12], fill=METAL_D, outline=DARK_OUTLINE)
    d.rectangle([8, 10, 9, 11], fill=(100, 100, 110, 255))
    # Projectile
    d.ellipse([18, 2, 20, 4], fill=(180, 180, 180, 255), outline=DARK_OUTLINE)
    d.polygon([(18, 2), (21, 3), (18, 4)], fill=METAL, outline=DARK_OUTLINE)
    # Faction flag
    d.line([(12, 6), (12, 3)], fill=DARK_OUTLINE, width=1)
    d.rectangle([12, 3, 15, 5], fill=fac, outline=DARK_OUTLINE)
    d.rectangle([12, 3, 13, 4], fill=(fac[0], fac[1], fac[2], 200))
    # Crewman head
    d.ellipse([14, 12, 16, 14], fill=SKIN, outline=DARK_OUTLINE)
    # Armor on crew
    d.rectangle([13, 14, 17, 16], fill=GREEN_ARMOR, outline=DARK_OUTLINE)
    return img


def conscript_sprite(faction):
    img, d = _new_sprite()
    fac = BLUE_F if faction == "blue" else RED_F
    # Shadow
    d.ellipse([5, 20, 19, 22], fill=(0, 0, 0, 60))
    # Legs (ragged)
    d.rectangle([8, 13, 10, 20], fill=(122, 106, 74, 255), outline=DARK_OUTLINE)
    d.rectangle([14, 13, 16, 20], fill=(122, 106, 74, 255), outline=DARK_OUTLINE)
    d.rectangle([7, 20, 11, 21], fill=(74, 58, 34, 255), outline=DARK_OUTLINE)
    d.rectangle([13, 20, 17, 21], fill=(74, 58, 34, 255), outline=DARK_OUTLINE)
    # Rough tunic
    d.rectangle([7, 7, 17, 14], fill=(158, 139, 107, 255), outline=DARK_OUTLINE)
    d.rectangle([7, 7, 9, 12], fill=(180, 160, 120, 255))
    # Faction sash
    d.polygon([(7, 10), (11, 7), (12, 8), (8, 11)], fill=fac)
    d.polygon([(12, 14), (16, 11), (16, 12), (12, 15)], fill=fac)
    # Belt
    d.rectangle([7, 12, 17, 13], fill=(90, 74, 50, 255))
    # Head with straw hat
    d.rectangle([10, 3, 14, 7], fill=SKIN, outline=DARK_OUTLINE)
    d.point((11, 5), fill=BLACK)
    d.point((13, 5), fill=BLACK)
    # Straw hat
    d.ellipse([8, 2, 16, 5], fill=(215, 191, 130, 255), outline=DARK_OUTLINE)
    d.ellipse([9, 1, 15, 4], fill=(232, 213, 160, 255), outline=DARK_OUTLINE)
    # Pitchfork
    d.rectangle([18, 2, 19, 16], fill=WOOD, outline=DARK_OUTLINE)
    d.line([(18, 3), (18, 15)], fill=WOOD_D, width=1)
    # Fork prongs
    d.line([(17, 2), (17, 5)], fill=METAL, width=1)
    d.line([(19, 2), (19, 5)], fill=METAL, width=1)
    d.line([(17, 5), (19, 5)], fill=METAL, width=1)
    d.line([(18, 4), (18, 5)], fill=METAL, width=1)
    return img


def scout_sprite(faction):
    img, d = _new_sprite()
    fac = BLUE_F if faction == "blue" else RED_F
    # Shadow
    d.ellipse([6, 19, 18, 22], fill=(0, 0, 0, 70))
    # Legs
    d.rectangle([8, 14, 10, 20], fill=GREEN_ARMOR_D, outline=DARK_OUTLINE)
    d.rectangle([14, 14, 16, 20], fill=GREEN_ARMOR_D, outline=DARK_OUTLINE)
    d.rectangle([7, 20, 11, 21], fill=(50, 40, 30, 255), outline=DARK_OUTLINE)
    d.rectangle([13, 20, 17, 21], fill=(50, 40, 30, 255), outline=DARK_OUTLINE)
    # Body tunic (green)
    d.rectangle([8, 8, 16, 14], fill=GREEN_ARMOR, outline=DARK_OUTLINE)
    d.rectangle([8, 8, 10, 11], fill=GREEN_ARMOR_L)
    # Belt
    d.rectangle([8, 11, 16, 12], fill=(80, 60, 30, 255))
    # Head with hood
    d.rectangle([10, 2, 14, 6], fill=SKIN, outline=DARK_OUTLINE)
    # Hood (dark green, light cloak)
    d.rectangle([9, 1, 15, 4], fill=GREEN_ARMOR, outline=DARK_OUTLINE)
    d.rectangle([8, 3, 16, 5], fill=(40, 80, 40, 255), outline=DARK_OUTLINE)
    d.point((11, 4), fill=BLACK)
    d.point((13, 4), fill=BLACK)
    # Cloak flowing behind (faction color inside)
    d.polygon(
        [(7, 9), (9, 8), (15, 8), (17, 11), (16, 15), (6, 15)],
        fill=(50, 50, 50, 255), outline=DARK_OUTLINE
    )
    d.polygon([(8, 10), (14, 10), (14, 14), (8, 14)], fill=fac)
    # Dagger
    d.rectangle([17, 9, 18, 13], fill=METAL, outline=DARK_OUTLINE)
    d.polygon([(17, 9), (18, 9), (17, 11)], fill=METAL_L)
    d.rectangle([17, 13, 18, 14], fill=fac)
    # Speed lines
    d.line([(5, 13), (7, 12)], fill=(255, 255, 255, 100), width=1)
    return img


SPRITES = {
    "infantry": infantry_sprite,
    "archer": archer_sprite,
    "cavalry": cavalry_sprite,
    "spearman": spearman_sprite,
    "siege": siege_sprite,
    "conscript": conscript_sprite,
    "scout": scout_sprite,
}

# ============================================================
# Save all sprites
# ============================================================
for unit_key, fn in SPRITES.items():
    for faction in ["blue", "red"]:
        img = fn(faction)
        out = os.path.join(SPRITE_DIR, f"unit_{unit_key}_{faction}.png")
        img.save(out, "PNG")
        print(f"Sprite: {out}")

# ============================================================
# Save fortress tile (updated)
# ============================================================
fortress_img = terrain_fortress_updated()
fortress_img.save(os.path.join(TILE_DIR, "terrain_fortress.png"), "PNG")
print(f"Tile: {os.path.join(TILE_DIR, 'terrain_fortress.png')}")

# ============================================================
# Save UI assets
# ============================================================
ui_files = {
    "portrait_advisor.png": ui_portrait_advisor,
    "ui_target_beacon.png": ui_target_beacon,
    "ui_move_green.png": ui_move_green,
    "ui_move_orange.png": ui_move_orange,
    "ui_move_red.png": ui_move_red,
    "ui_move_black.png": ui_move_black,
    "ui_banner_target.png": ui_banner_target,
    "ui_tactical_button.png": ui_tactical_button,
    "ui_tactical_button_hover.png": lambda: ui_tactical_button(highlight=True),
    "ui_sidebar_panel.png": ui_sidebar_panel,
    "ui_dialogue_bubble.png": ui_dialogue_bubble,
    "ui_command_input.png": ui_command_input_bar,
}

# Save icon files
icon_files = {
    "ui_icon_sword.png": make_icon_sword,
    "ui_icon_shield.png": make_icon_shield,
    "ui_icon_forest.png": make_icon_forest,
    "ui_icon_arrow.png": make_icon_arrow,
}

for fname, fn in ui_files.items():
    img = fn()
    out = os.path.join(UI_DIR, fname)
    img.save(out, "PNG")
    print(f"UI: {out}")

for fname, fn in icon_files.items():
    img = fn()
    out = os.path.join(UI_DIR, fname)
    img.save(out, "PNG")
    print(f"UI: {out}")

# ============================================================
# Generate 1920x1080 preview PNG of full tactical UI layout
# ============================================================
def generate_preview():
    W, H = 1920, 1080
    img = Image.new("RGBA", (W, H), (30, 30, 40, 255))
    d = ImageDraw.Draw(img)

    # Right 75% — battle map (simulated hex grid)
    # Draw a section of hex grid
    import math
    tile_w, tile_h = 48, 42
    col_step = 36
    row_step = 42
    hex_pts = [(12, 0), (36, 0), (48, 21), (36, 42), (12, 42), (0, 21)]
    # Draw hex tiles from x=240 to right edge
    for q in range(0, 45):
        for r in range(0, 24):
            x = 240 + q * col_step
            y = 120 + r * row_step + (q & 1) * row_step // 2
            if x > W or y > H:
                continue
            # Offset points
            pts = [(px + x, py + y) for px, py in hex_pts]
            # Terrain coloring
            terrain_colors = [(139, 186, 85, 255), (150, 146, 138, 255), (59, 125, 79, 255),
                              (107, 124, 90, 255), (176, 188, 196, 255), (217, 160, 102, 255),
                              (194, 164, 119, 255)]
            tc = terrain_colors[(q * 7 + r * 13) % 7]
            d.polygon(pts, fill=tc, outline=(43, 43, 43, 255), width=1)
            # Hex inner detail
            inner_pts = [(px + x, py + y) for px, py in [(13, 1), (35, 1), (47, 21), (35, 41), (13, 41), (1, 21)]]
            d.polygon(inner_pts, outline=(60, 60, 70, 255), width=1)

    # Draw units as colored dots on hexes
    unit_positions = [
        (240 + 3 * 36, 120 + 4 * 42 + 21, BLUE_F),
        (240 + 2 * 36, 120 + 6 * 42 + 21, BLUE_F),
        (240 + 3 * 36, 120 + 5 * 42 + 21, BLUE_F),
        (240 + 14 * 36, 120 + 4 * 42 + 21, RED_F),
        (240 + 15 * 36, 120 + 5 * 42 + 21, RED_F),
        (240 + 14 * 36, 120 + 6 * 42 + 21, RED_F),
    ]
    for ux, uy, uc in unit_positions:
        d.ellipse([ux - 6, uy - 6, ux + 6, uy + 6], fill=uc, outline=DARK_OUTLINE, width=1)

    # Draw golden target beacon over center-right
    beacon_q, beacon_r = 30, 12
    bx = 240 + beacon_q * col_step
    by = 120 + beacon_r * row_step + (beacon_q & 1) * row_step // 2
    # Beacon: golden crosshair
    for ring_r in [18, 14, 6]:
        d.ellipse([bx - ring_r, by - ring_r, bx + ring_r, by + ring_r],
                  outline=GOLD_LIGHT, width=2 if ring_r == 18 else 1)
    # Crosshairs
    d.line([(bx, by - 24), (bx, by - 18)], fill=GOLD, width=2)
    d.line([(bx, by + 18), (bx, by + 24)], fill=GOLD, width=2)
    d.line([(bx - 24, by), (bx - 18, by)], fill=GOLD, width=2)
    d.line([(bx + 18, by), (bx + 24, by)], fill=GOLD, width=2)
    d.ellipse([bx - 2, by - 2, bx + 2, by + 2], fill=GOLD_LIGHT)

    # Golden banner below beacon
    banner_y = by + 40
    d.rounded_rectangle([bx - 120, banner_y, bx + 120, banner_y + 48],
                        fill=GOLD, outline=GOLD_DARK, width=3, radius=8)
    d.rounded_rectangle([bx - 112, banner_y + 4, bx + 112, banner_y + 44],
                        fill=(120, 90, 20, 255), radius=4)
    # Banner text
    d.text((bx - 80, banner_y + 12), "목표:", fill=(40, 40, 30, 255))
    d.text((bx - 48, banner_y + 12), "북부 요새 함락", fill=(40, 40, 30, 255))

    # Draw movement heatmap overlays (green/orange/red/black) on nearby hexes
    heatmap_colors = [HEATMAP_GREEN, HEATMAP_ORANGE, HEATMAP_RED, HEATMAP_BLACK]
    for i in range(4):
        hq = 5 + i * 2
        hr = 5 + i
        hx = 240 + hq * col_step
        hy = 120 + hr * row_step + (hq & 1) * row_step // 2
        pts = [(px + hx, py + hy) for px, py in hex_pts]
        d.polygon(pts, fill=heatmap_colors[i])

    # Left 25% — tactical sidebar (simulated from asset)
    sidebar_img = ui_sidebar_panel()
    img.paste(sidebar_img, (0, 0), sidebar_img)

    # Advisor portrait
    portrait_img = ui_portrait_advisor()
    img.paste(portrait_img, (24, 40), portrait_img)

    # Dialogue bubble
    bubble_img = ui_dialogue_bubble()
    img.paste(bubble_img, (40, 160), bubble_img)
    d.text((50, 190), "> 주공, 전황을 아뢰옵니다.", fill=(20, 20, 24, 255))
    d.text((50, 210), "   적의 보급로가 노출되어 있사오니...", fill=(20, 20, 24, 255))

    # Tactical buttons
    for i, (label, icon_name) in enumerate([("전진", "sword"), ("방어", "shield"), ("정찰", "forest")]):
        btn_img = ui_tactical_button()
        bx = 32
        by = 280 + i * 44
        img.paste(btn_img, (bx, by), btn_img)
        d.text((bx + 30, by + 10), label, fill=(212, 175, 55, 255))

    # Command input bar
    input_img = ui_command_input_bar()
    img.paste(input_img, (40, 680), input_img)

    # Top status capsule (simulated over battle map)
    cap_x = 240
    cap_y = 10
    d.rounded_rectangle([cap_x, cap_y, cap_x + 800, cap_y + 36],
                        fill=(26, 26, 34, 255), outline=GOLD_LIGHT, width=2, radius=18)
    d.text((cap_x + 12, cap_y + 8), "턴: 10  보급: 18/9일  아군: 1000명  적군: 130명  명성: 350",
           fill=(212, 175, 55, 255))

    return img


preview = generate_preview()
preview.save(os.path.join(BASE, "..", "preview_sprint5_layout.png"), "PNG")
print(f"Preview: {os.path.join(BASE, '..', 'preview_sprint5_layout.png')}")

print("\nAll Sprint 5 assets generated successfully!")
