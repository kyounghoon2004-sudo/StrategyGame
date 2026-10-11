#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Five Dynasties Strategy - Visual Assets Generator v3
Minimalist pixel art, flat-top hex, readability first
Generate: 7 terrain tiles (48x42), 14 unit sprites (24x24), UI elements
"""
import os
from PIL import Image, ImageDraw

BASE = r"D:\Game development\Demon slayer\StrategyGame\assets"
TILE_DIR = os.path.join(BASE, "tiles")
SPRITE_DIR = os.path.join(BASE, "sprites")
UI_DIR = os.path.join(BASE, "ui")
DOCS_DIR = r"D:\Game development\Demon slayer\StrategyGame\docs"

for d in [TILE_DIR, SPRITE_DIR, UI_DIR, DOCS_DIR]:
    os.makedirs(d, exist_ok=True)

# ============================================================
# PALETTE
# ============================================================
PALETTE = {
    # terrain
    "plains_base": "#8BC67A",
    "plains_light": "#A8D98A",
    "plains_dark": "#6BA055",
    "plains_outline": "#3B4D2F",
    "plains_tuft": "#4A7A3A",

    "mountain_base": "#C9C5B8",
    "mountain_rock": "#9E9B94",
    "mountain_dark": "#6B6862",
    "mountain_light": "#E6E2D6",
    "mountain_snow": "#F2F2F2",
    "mountain_outline": "#3D3B38",

    "forest_base": "#7FB069",
    "forest_canopy_dark": "#2F5D32",
    "forest_canopy_mid": "#3B7A3E",
    "forest_canopy_light": "#5FAF5A",
    "forest_trunk": "#5D4037",
    "forest_trunk_light": "#8D6E63",
    "forest_outline": "#1E3A22",

    "swamp_base": "#8A9A7B",
    "swamp_mud": "#6B5A42",
    "swamp_mud_dark": "#4E3D2C",
    "swamp_water": "#6B7C8A",
    "swamp_water_dark": "#4A5A62",
    "swamp_reed": "#4A6B3A",
    "swamp_outline": "#3A4032",

    "fortress_stone": "#B8BEC2",
    "fortress_stone_dark": "#7A848C",
    "fortress_stone_light": "#D6DBDF",
    "fortress_brick": "#8A9198",
    "fortress_gate": "#3E3A33",
    "fortress_roof": "#4A4A4A",
    "fortress_outline": "#2C2E30",

    "village_base": "#8BC67A",
    "village_wall": "#E8DCC8",
    "village_wall_dark": "#C2B0A0",
    "village_roof_grey": "#5A5E62",
    "village_roof_red": "#7A3B2E",
    "village_wood": "#8B5A2B",
    "village_outline": "#3A2E28",

    "road_dirt": "#C2A47A",
    "road_dirt_light": "#D7BF9A",
    "road_dirt_dark": "#8D7355",
    "road_stone": "#A99E93",
    "road_outline": "#5A4A32",

    # factions
    "blue_primary": "#2F80ED",
    "blue_shadow": "#1B4C8A",
    "blue_highlight": "#7AB0FF",
    "blue_dark": "#0F2A52",
    "blue_outline": "#0A1E3A",

    "red_primary": "#EB5757",
    "red_shadow": "#8B2525",
    "red_highlight": "#FF8A80",
    "red_dark": "#5A1A1A",
    "red_outline": "#3D0F0F",

    # common
    "skin": "#F2C9A0",
    "skin_shadow": "#D4A77A",
    "skin_outline": "#8B5A3A",
    "metal": "#C0C8D0",
    "metal_dark": "#8A9098",
    "metal_light": "#E8EEF2",
    "metal_outline": "#3A3E42",
    "gold": "#D4A843",
    "wood": "#8B5A2B",
    "wood_dark": "#5D3A1A",
    "black": "#1A1A1A",
    "white": "#FFFFFF",
}

def hex_to_rgba(h):
    h = h.lstrip("#")
    return (int(h[0:2],16), int(h[2:4],16), int(h[4:6],16), 255)

# ============================================================
# TILE COMMON: Flat-top hex 48x42
# ============================================================
TILE_W = 48
TILE_H = 42
# flat-top points: (12,0) (36,0) (48,21) (36,42) (12,42) (0,21)
HEX_POINTS = [(12,0),(36,0),(48,21),(36,42),(12,42),(0,21)]
# inner inset for border
INNER_POINTS = [(13,1),(35,1),(47,21),(35,41),(13,41),(1,21)]

OUTLINE_COLOR = "#2B2B2B"

def new_tile():
    img = Image.new("RGBA", (TILE_W, TILE_H), (0,0,0,0))
    draw = ImageDraw.Draw(img)
    return img, draw

def draw_hex_outline(draw, color="#2B2B2B", width=1):
    # crisp 1px outline polygon
    draw.polygon(HEX_POINTS, outline=color, width=1)
    # draw again for thicker where needed - width 1 is enough, add inner line for depth
    # subtle bottom shadow line
    pass

def clip_hex(img):
    """Ensure outside hex is transparent (already, but clean anti-alias fringe)"""
    # Create mask: white inside hex, black outside
    mask = Image.new("L", (TILE_W, TILE_H), 0)
    md = ImageDraw.Draw(mask)
    md.polygon(HEX_POINTS, fill=255)
    # apply mask to alpha channel
    r,g,b,a = img.split()
    # combine original alpha with mask
    # where mask 0 -> transparent
    import PIL.ImageChops as chops
    # new alpha = min(original alpha, mask)
    # Pillow: point
    new_a = Image.new("L", (TILE_W, TILE_H), 0)
    # Use composite
    # For pixels outside hex, set alpha 0
    img_with_mask = Image.new("RGBA", (TILE_W, TILE_H), (0,0,0,0))
    # paste img where mask
    img_with_mask.paste(img, (0,0), mask)
    # but we already have hex polygon fill, so just re-apply mask to crisp edges
    # Ensure outline not clipped - skip
    return img

# ============================================================
# TERRAIN DRAW FUNCTIONS
# ============================================================

def terrain_plains():
    img, draw = new_tile()
    draw.polygon(HEX_POINTS, fill=PALETTE["plains_base"])
    # subtle texture: small grass tufts - deterministic pattern
    # 1px dots
    tufts_dark = [(8,14),(15,9),(22,12),(30,8),(35,15),(10,22),(18,20),(26,18),(33,24),(14,28),(22,30),(28,32),(38,28),(12,34),(20,36),(30,36),(36,34)]
    tufts_light = [(11,11),(19,15),(27,10),(32,12),(14,18),(21,24),(29,22),(17,32),(25,28),(33,30),(15,36),(38,32)]
    for x,y in tufts_dark:
        if 1 < x < 47 and 1 < y < 41:
            draw.point((x,y), fill=PALETTE["plains_dark"])
            # small double pixel occasionally
    for x,y in tufts_light:
        draw.point((x,y), fill=PALETTE["plains_light"])
    # 2x1 tufts
    for x,y in [(17,26),(24,14),(31,20),(9,30)]:
        draw.rectangle([x,y,x+1,y], fill=PALETTE["plains_tuft"])
    # bottom shadow gradient - slightly darker bottom edge inside hex
    draw.polygon([(12,39),(36,39),(35,41),(13,41)], fill="#7AB368")
    draw.polygon(HEX_POINTS, outline=PALETTE["plains_outline"])
    # inner highlight top edge
    draw.line([(13,1),(35,1)], fill="#B8E0A8", width=1)
    return img

def terrain_mountains():
    img, draw = new_tile()
    draw.polygon(HEX_POINTS, fill=PALETTE["mountain_base"])
    # rocky texture dots
    for x,y in [(10,20),(14,28),(18,15),(22,32),(28,18),(32,28),(36,22),(40,30),(16,35),(26,36)]:
        draw.point((x,y), fill=PALETTE["mountain_dark"])
    for x,y in [(12,15),(20,18),(28,12),(34,18),(18,25),(30,32)]:
        draw.point((x,y), fill=PALETTE["mountain_light"])
    # Main mountain ridge - two peaks inside hex
    # Primary peak centered
    # Shadow side (north-east light source: light from top-left, so right/bottom darker)
    # Peak 1: central large
    main_peak = [(14,34),(22,12),(32,22),(38,34)]
    # Fill with rock mid
    draw.polygon(main_peak, fill=PALETTE["mountain_rock"])
    # Highlight left slope
    highlight = [(14,34),(22,12),(26,18),(18,34)]
    draw.polygon(highlight, fill=PALETTE["mountain_light"])
    # Shadow right slope
    shadow = [(26,18),(32,22),(38,34),(18,34)]
    draw.polygon(shadow, fill=PALETTE["mountain_dark"])
    # Snow cap
    snow = [(20,16),(22,12),(24,15),(23,18),(19,18)]
    draw.polygon(snow, fill=PALETTE["mountain_snow"])
    # Second smaller peak left
    small_peak = [(8,32),(12,22),(16,28),(10,34)]
    draw.polygon(small_peak, fill=PALETTE["mountain_rock"])
    draw.polygon([(8,32),(12,22),(13,26),(10,32)], fill=PALETTE["mountain_light"])
    draw.polygon([(13,26),(16,28),(10,34),(10,32)], fill=PALETTE["mountain_dark"])
    # Ridge lines
    draw.line([(22,12),(18,34)], fill=PALETTE["mountain_dark"], width=1)
    draw.line([(22,12),(32,22)], fill=PALETTE["mountain_dark"], width=1)
    draw.line([(32,22),(38,34)], fill=PALETTE["mountain_dark"], width=1)
    # base shadow under mountains
    draw.polygon([(14,34),(38,34),(36,36),(12,36)], fill="#8A8780")
    draw.polygon(HEX_POINTS, outline=PALETTE["mountain_outline"])
    draw.line([(13,1),(35,1)], fill="#EDE9E0", width=1)
    return img

def terrain_forest():
    img, draw = new_tile()
    draw.polygon(HEX_POINTS, fill=PALETTE["forest_base"])
    # ground texture dots
    for x,y in [(10,32),(18,36),(30,34),(36,36),(22,30)]:
        draw.point((x,y), fill="#6A9E5A")
    # 3 trees in triangle formation for denseness
    def tree(cx, cy, scale=1.0):
        # trunk 2px wide
        trunk_w = max(1, int(2*scale))
        trunk_h = int(6*scale)
        trunk_x0 = cx - trunk_w//1
        # trunk
        draw.rectangle([cx-1, cy, cx+1, cy+trunk_h], fill=PALETTE["forest_trunk"])
        draw.rectangle([cx-1, cy, cx, cy+trunk_h], fill=PALETTE["forest_trunk_light"])  # highlight
        # canopy - stacked ellipses/circles for pixel clusters
        # top cluster
        r = int(8*scale)
        # dark shadow base canopy
        draw.ellipse([cx - r, cy - r +1, cx + r, cy + r//2], fill=PALETTE["forest_canopy_dark"])
        # mid canopy
        r2 = int(7*scale)
        draw.ellipse([cx - r2 +1, cy - r2, cx + r2 -1, cy + r2//3], fill=PALETTE["forest_canopy_mid"])
        # highlight top
        r3 = int(4*scale)
        draw.ellipse([cx - r3, cy - r3, cx + r3//2, cy -1], fill=PALETTE["forest_canopy_light"])
        # outline
        # trunk outline subtle
    tree(14, 12, 0.85)
    tree(34, 14, 0.9)
    tree(24, 22, 1.0)
    # fourth small tree bottom
    tree(16, 28, 0.65)
    # ground shadow under trees
    draw.ellipse([22, 28, 32, 33], fill="#5A8A4A")
    draw.polygon(HEX_POINTS, outline=PALETTE["forest_outline"])
    draw.line([(13,1),(35,1)], fill="#8AC07A", width=1)
    return img

def terrain_swamp():
    img, draw = new_tile()
    draw.polygon(HEX_POINTS, fill=PALETTE["swamp_base"])
    # mud texture - darker patches
    # irregular mud pools
    mud1 = [(14,16),(26,14),(28,22),(18,24)]
    mud2 = [(28,26),(38,24),(40,32),(30,34)]
    mud3 = [(10,28),(16,26),(16,32),(10,34)]
    for poly in [mud1, mud2, mud3]:
        draw.polygon(poly, fill=PALETTE["swamp_mud"])
        draw.polygon(poly, outline=PALETTE["swamp_mud_dark"])
    # water puddles - blue-grey with highlight
    water1 = [(18,18),(24,16),(26,20),(20,22)]
    water2 = [(32,28),(38,28),(38,32),(32,32)]
    for poly in [water1, water2]:
        draw.polygon(poly, fill=PALETTE["swamp_water"])
        draw.polygon(poly, outline=PALETTE["swamp_water_dark"])
        # highlight pixel
    draw.point((20,18), fill="#8AA0B0")
    draw.point((34,29), fill="#8AA0B0")
    # reeds - vertical 1px lines with 2px height variation
    reed_positions = [(12,20),(13,22),(27,18),(28,20),(30,30),(31,32),(15,30),(16,28)]
    for x,y in reed_positions:
        draw.line([(x,y),(x,y+4)], fill=PALETTE["swamp_reed"], width=1)
        draw.point((x,y+4), fill="#6B8A5A")
    # lily pads / tufts
    for x,y in [(22,26),(36,20),(14,18)]:
        draw.ellipse([x,y,x+4,y+2], fill="#5A6B3A", outline="#3A4A2A")
    draw.polygon(HEX_POINTS, outline=PALETTE["swamp_outline"])
    draw.line([(13,1),(35,1)], fill="#A8B89A", width=1)
    return img

def terrain_fortress():
    img, draw = new_tile()
    # base ground inside hex
    draw.polygon(HEX_POINTS, fill="#8A9A8A")
    # Fortress occupies central area: stone platform
    # Outer wall rectangle
    # Wall base
    wall_outer = [10,14,38,32]
    draw.rectangle(wall_outer, fill=PALETTE["fortress_stone"], outline=PALETTE["fortress_outline"])
    # Brick lines
    for y in [18,22,26,30]:
        draw.line([(11,y),(37,y)], fill=PALETTE["fortress_brick"], width=1)
    for x in [16,22,28,34]:
        # staggered
        off = 2 if (x//6)%2==0 else 0
        for y in [15+off,19+off,23+off,27+off]:
            if 15 < y < 31:
                draw.line([(x,y),(x,y+3)], fill=PALETTE["fortress_brick"], width=1)
    # Crenellations (battlements) top
    for x in [10,14,18,22,26,30,34]:
        draw.rectangle([x,11,x+3,14], fill=PALETTE["fortress_stone_light"], outline=PALETTE["fortress_outline"])
        if x%8==2:
            draw.rectangle([x+1,12,x+2,13], fill=PALETTE["fortress_stone_dark"])
    for x in [12,16,20,24,28,32,36]:
        # gaps
        draw.rectangle([x,12,x+1,14], fill="#6A747D")
    # Gate - arch
    draw.rectangle([21,24,27,32], fill=PALETTE["fortress_gate"], outline="#1A1A1A")
    # arch top
    draw.polygon([(21,24),(24,20),(27,24)], fill=PALETTE["fortress_gate"])
    draw.line([(21,24),(24,20)], fill="#1A1A1A", width=1)
    draw.line([(27,24),(24,20)], fill="#1A1A1A", width=1)
    # gate wood
    draw.rectangle([22,26,26,32], fill="#5D4037", outline="#2A1A0A")
    draw.line([(24,26),(24,32)], fill="#3E2723", width=1)
    # metal studs
    for x,y in [(23,28),(25,28),(23,30),(25,30)]:
        draw.point((x,y), fill=PALETTE["metal"])
    # Towers corners
    for tx in [10,34]:
        draw.rectangle([tx,14,tx+5,20], fill=PALETTE["fortress_stone_light"], outline=PALETTE["fortress_outline"])
        # roof small
        draw.polygon([(tx,14),(tx+2,9),(tx+5,14)], fill=PALETTE["fortress_roof"], outline="#1A1A1A")
        # window
        draw.rectangle([tx+2,16,tx+3,18], fill="#2A2A2A")
    # courtyard flag
    draw.line([(24,14),(24,11)], fill="#3A3A3A", width=1)
    draw.rectangle([24,9,28,11], fill="#C0392B", outline="#1A1A1A")
    draw.polygon(HEX_POINTS, outline="#1E2022", width=1)
    return img

def terrain_village():
    img, draw = new_tile()
    draw.polygon(HEX_POINTS, fill=PALETTE["village_base"])
    # ground dots
    for x,y in [(10,30),(34,32),(22,34),(12,36)]:
        draw.point((x,y), fill="#7AB368")
    # Village cluster - 3 houses oriented for top-down but with perspective
    # House 1 - left, grey roof
    # walls
    draw.rectangle([10,20,20,28], fill=PALETTE["village_wall"], outline=PALETTE["village_outline"])
    # roof - flat-top view: rectangle + triangle top
    draw.polygon([(9,20),(15,12),(21,20)], fill=PALETTE["village_roof_grey"], outline=PALETTE["village_outline"])
    # roof tiles lines
    for y in [15,17,19]:
        draw.line([(11+ (19-y)//2, y),(19- (19-y)//2, y)], fill="#3A3E42", width=1)
    # door
    draw.rectangle([14,24,16,28], fill=PALETTE["village_wood"], outline="#3A1E10")
    # House 2 - center, red roof (main hall)
    draw.rectangle([22,16,34,26], fill=PALETTE["village_wall"], outline=PALETTE["village_outline"])
    draw.polygon([(21,16),(28,8),(35,16)], fill=PALETTE["village_roof_red"], outline=PALETTE["village_outline"])
    for y in [11,13,15]:
        draw.line([(23 + (16-y), y),(33 - (16-y), y)], fill="#5A1A1A", width=1)
    # ridge ornament
    draw.rectangle([27,7,29,9], fill="#D4A84B", outline="#5A3A0A")
    # windows
    draw.rectangle([24,20,26,23], fill="#8B7355", outline="#3A2E28")
    draw.rectangle([30,20,32,23], fill="#8B7355", outline="#3A2E28")
    # door
    draw.rectangle([27,22,30,26], fill="#5D4037", outline="#1A0F0A")
    # House 3 - right small
    draw.rectangle([30,24,40,30], fill=PALETTE["village_wall"], outline=PALETTE["village_outline"])
    draw.polygon([(29,24),(35,18),(41,24)], fill=PALETTE["village_roof_grey"], outline=PALETTE["village_outline"])
    for y in [20,22]:
        draw.line([(31+(24-y)//2,y),(39-(24-y)//2,y)], fill="#3A3E42", width=1)
    # courtyard enclosure low wall
    draw.rectangle([10,28,40,30], fill="#C9B99A", outline="#5A4A32")
    # path to gate
    draw.rectangle([24,30,28,34], fill=PALETTE["road_dirt"], outline=PALETTE["road_dirt_dark"])
    # tree near village
    draw.rectangle([7,26,8,29], fill=PALETTE["forest_trunk"])
    draw.ellipse([4,22,11,28], fill=PALETTE["forest_canopy_mid"], outline=PALETTE["forest_outline"])
    draw.ellipse([5,20,10,25], fill=PALETTE["forest_canopy_light"])
    draw.polygon(HEX_POINTS, outline=PALETTE["village_outline"])
    draw.line([(13,1),(35,1)], fill="#B8D8A8", width=1)
    return img

def terrain_road():
    img, draw = new_tile()
    draw.polygon(HEX_POINTS, fill=PALETTE["plains_base"])
    # grass tufts at edges
    for x,y in [(10,14),(36,10),(14,34),(34,36)]:
        draw.point((x,y), fill=PALETTE["plains_dark"])
        draw.point((x+1,y), fill=PALETTE["plains_dark"])
    # Road - flat-top east-west straight + slight north-south branch to show connectivity
    # East-west main road through center horizontal (y=21)
    # Road width ~10px (y 17-25)
    # Draw road bed
    # Trapezoid to fit hex shape: road enters at (0,21) left point and exits at (48,21) right point
    road_poly = [(0,18),(48,18),(48,24),(0,24)]
    # But hex pinches at center, so clip to hex shape - draw full rectangle then hex outline will crop,
    # but we draw with consideration of hex shape: use polygon that follows hex edges
    # Simpler: draw horizontal band then overwrite outside hex with transparency? we'll just draw band
    # and let hex outline frame it. For visual connection, extend to edges.
    # Road bed
    # To make tiling clearer, road is straight horizontal line through middle with stone edges
    draw.polygon([(0,17),(48,17),(48,25),(0,25)], fill=PALETTE["road_dirt"])
    # center worn lighter track
    draw.polygon([(0,19),(48,19),(48,23),(0,23)], fill=PALETTE["road_dirt_light"])
    # center dashed line? - stone pavers periodic
    for x in range(4, 48, 8):
        draw.rectangle([x,20,x+3,22], fill=PALETTE["road_stone"], outline="#7A7065")
        draw.point((x+1,21), fill="#C4B8A8")
    # edge stones - border lines top/bottom of road
    draw.line([(0,17),(48,17)], fill=PALETTE["road_dirt_dark"], width=1)
    draw.line([(0,25),(48,25)], fill=PALETTE["road_dirt_dark"], width=1)
    # ruts - darker lines
    draw.line([(0,19),(48,19)], fill="#A68B6A", width=1)
    draw.line([(0,23),(48,23)], fill="#A68B6A", width=1)
    # North spur small (to show junction) - vertical stub to top edge center
    # draw a small vertical road segment from center to top edge
    # top entry at x=24, y=0
    draw.polygon([(22,0),(26,0),(26,21),(22,21)], fill=PALETTE["road_dirt"])
    draw.polygon([(23,0),(25,0),(25,21),(23,21)], fill=PALETTE["road_dirt_light"])
    draw.line([(22,0),(22,21)], fill=PALETTE["road_dirt_dark"], width=1)
    draw.line([(26,0),(26,21)], fill=PALETTE["road_dirt_dark"], width=1)
    # pavers on vertical
    for y in [4,8,12]:
        draw.rectangle([23,y,25,y+2], fill=PALETTE["road_stone"], outline="#7A7065")
    # center junction circle
    draw.ellipse([22,19,26,23], fill=PALETTE["road_dirt_light"], outline=PALETTE["road_dirt_dark"])
    draw.ellipse([23,20,25,22], fill=PALETTE["road_stone"])
    draw.polygon(HEX_POINTS, outline=PALETTE["road_outline"])
    draw.line([(13,1),(35,1)], fill="#E8D8B8", width=1)
    return img

TERRAINS = {
    "plains": terrain_plains,
    "mountains": terrain_mountains,
    "forest": terrain_forest,
    "swamp": terrain_swamp,
    "fortress": terrain_fortress,
    "village": terrain_village,
    "road": terrain_road,
}

for name, fn in TERRAINS.items():
    img = fn()
    out = os.path.join(TILE_DIR, f"terrain_{name}.png")
    img.save(out, "PNG")
    print(f"Tile saved: {out} {img.size}")

# ============================================================
# UNIT SPRITES 24x24
# ============================================================
SPRITE_W = 24
SPRITE_H = 24

# Faction palettes
BLUE = {
    "primary": hex_to_rgba(PALETTE["blue_primary"]),
    "shadow": hex_to_rgba(PALETTE["blue_shadow"]),
    "highlight": hex_to_rgba(PALETTE["blue_highlight"]),
    "dark": hex_to_rgba(PALETTE["blue_dark"]),
    "outline": hex_to_rgba(PALETTE["blue_outline"]),
}
RED = {
    "primary": hex_to_rgba(PALETTE["red_primary"]),
    "shadow": hex_to_rgba(PALETTE["red_shadow"]),
    "highlight": hex_to_rgba(PALETTE["red_highlight"]),
    "dark": hex_to_rgba(PALETTE["red_dark"]),
    "outline": hex_to_rgba(PALETTE["red_outline"]),
}
SKIN = hex_to_rgba(PALETTE["skin"])
SKIN_SHADOW = hex_to_rgba(PALETTE["skin_shadow"])
SKIN_OUTL = hex_to_rgba(PALETTE["skin_outline"])
METAL = hex_to_rgba(PALETTE["metal"])
METAL_D = hex_to_rgba(PALETTE["metal_dark"])
METAL_L = hex_to_rgba(PALETTE["metal_light"])
METAL_O = hex_to_rgba(PALETTE["metal_outline"])
WOOD = hex_to_rgba(PALETTE["wood"])
WOOD_D = hex_to_rgba(PALETTE["wood_dark"])
BLACK = (26,26,26,255)
DARK_OUTLINE = (20,20,24,255)

def sprite_canvas():
    img = Image.new("RGBA", (SPRITE_W, SPRITE_H), (0,0,0,0))
    draw = ImageDraw.Draw(img)
    return img, draw

def draw_outline_rect(draw, box, fill, outline=None):
    draw.rectangle(box, fill=fill, outline=outline)

def infantry_sprite(faction):
    img, draw = sprite_canvas()
    pal = BLUE if faction=="blue" else RED
    # shadow under feet
    draw.ellipse([7,20,17,23], fill=(0,0,0,80))
    # legs: 2 pixels wide each
    draw.rectangle([9,15,11,20], fill=pal["shadow"], outline=DARK_OUTLINE)
    draw.rectangle([13,15,15,20], fill=pal["shadow"], outline=DARK_OUTLINE)
    draw.rectangle([9,15,10,19], fill=pal["primary"]) # highlight left leg
    # boots
    draw.rectangle([8,20,11,21], fill=(40,30,20,255), outline=DARK_OUTLINE)
    draw.rectangle([13,20,16,21], fill=(40,30,20,255), outline=DARK_OUTLINE)
    # body armor
    draw.rectangle([8,8,16,15], fill=pal["primary"], outline=DARK_OUTLINE)
    # chest highlight
    draw.rectangle([9,9,11,13], fill=pal["highlight"])
    # belt
    draw.rectangle([8,13,16,14], fill=pal["dark"])
    draw.rectangle([11,13,13,14], fill=PALETTE["gold"] and hex_to_rgba("#D4A843") or (212,168,67,255))
    # head
    draw.rectangle([10,3,14,8], fill=SKIN, outline=DARK_OUTLINE)
    draw.rectangle([10,3,11,7], fill=(255,255,255,40)) # highlight - approximated
    # helmet
    draw.rectangle([9,2,15,5], fill=pal["shadow"], outline=DARK_OUTLINE)
    draw.rectangle([9,2,12,4], fill=pal["primary"])
    # helmet crest / top
    draw.rectangle([11,1,13,2], fill=pal["highlight"], outline=DARK_OUTLINE)
    # eyes (1px)
    draw.point((11,6), fill=BLACK)
    draw.point((13,6), fill=BLACK)
    # shield - large left side, distinctive
    # shield shape: vertical rectangle with pointed bottom? simple rect + triangle bottom
    draw.rectangle([4,7,8,16], fill=WOOD, outline=DARK_OUTLINE)
    # shield boss and faction color diagonal
    draw.rectangle([4,7,8,10], fill=pal["primary"])
    draw.polygon([(4,10),(8,10),(8,16),(4,12)], fill=pal["primary"])
    draw.rectangle([4,7,8,7], fill=pal["highlight"]) # top edge
    draw.ellipse([5,10,7,12], fill=METAL, outline=DARK_OUTLINE) # boss
    # sword - right side vertical with guard
    draw.rectangle([16,5,18,18], fill=METAL, outline=DARK_OUTLINE) # blade
    # blade highlight
    draw.line([(17,6),(17,16)], fill=METAL_L, width=1)
    # guard
    draw.rectangle([15,12,19,13], fill=WOOD, outline=DARK_OUTLINE)
    draw.rectangle([15,12,16,13], fill=(120,80,40,255))
    # hilt
    draw.rectangle([16,13,18,15], fill=WOOD_D, outline=DARK_OUTLINE)
    # pommel
    draw.rectangle([16,15,18,16], fill=METAL, outline=DARK_OUTLINE)
    return img

def archer_sprite(faction):
    img, draw = sprite_canvas()
    pal = BLUE if faction=="blue" else RED
    draw.ellipse([7,20,17,23], fill=(0,0,0,70))
    # legs slender
    draw.rectangle([9,14,11,20], fill=pal["shadow"], outline=DARK_OUTLINE)
    draw.rectangle([13,14,15,20], fill=pal["shadow"], outline=DARK_OUTLINE)
    draw.rectangle([9,14,10,19], fill=pal["primary"])
    draw.rectangle([8,20,11,21], fill=(50,35,25,255), outline=DARK_OUTLINE)
    draw.rectangle([13,20,16,21], fill=(50,35,25,255), outline=DARK_OUTLINE)
    # tunic
    draw.rectangle([9,8,15,14], fill=pal["primary"], outline=DARK_OUTLINE)
    draw.rectangle([9,8,11,12], fill=pal["highlight"])
    # belt
    draw.rectangle([9,12,15,13], fill=pal["dark"])
    # head smaller, hood? archer with headband
    draw.rectangle([10,3,14,8], fill=SKIN, outline=DARK_OUTLINE)
    draw.rectangle([9,3,15,5], fill=pal["shadow"], outline=DARK_OUTLINE) # headband/helmet light
    draw.rectangle([9,3,12,4], fill=pal["primary"])
    draw.point((11,6), fill=BLACK)
    draw.point((13,6), fill=BLACK)
    # bow - distinctive curved vertical on right side
    # bow shape: arc: use lines forming bow
    # bow stave
    draw.line([(17,4),(18,6),(18,14),(17,16)], fill=WOOD, width=1)
    draw.line([(17,4),(16,5)], fill=WOOD, width=1)
    draw.line([(17,16),(16,15)], fill=WOOD, width=1)
    # string
    draw.line([(16,5),(16,15)], fill=(230,230,230,255), width=1)
    # arrow nocked
    draw.line([(11,10),(16,10)], fill=WOOD_D, width=1)
    draw.polygon([(16,9),(18,10),(16,11)], fill=METAL)
    # quiver on back left
    draw.rectangle([6,8,8,14], fill=WOOD_D, outline=DARK_OUTLINE)
    for y in [8,10,12]:
        draw.line([(6,y),(8,y)], fill=WOOD, width=1)
        # arrow fletching protruding
        draw.point((7, y), fill=(200,200,220,255))
    # bow arm
    draw.rectangle([15,9,16,11], fill=SKIN, outline=DARK_OUTLINE)
    return img

def cavalry_sprite(faction):
    img, draw = sprite_canvas()
    pal = BLUE if faction=="blue" else RED
    # shadow larger for horse
    draw.ellipse([3,19,21,23], fill=(0,0,0,80))
    # horse body - side view, pixel horse
    # horse torso
    draw.rectangle([4,12,18,18], fill=hex_to_rgba("#8B5A2B") if False else hex_to_rgba("#6B4423"), outline=DARK_OUTLINE)
    # use brown
    horse_body = hex_to_rgba("#7A4A2A")
    horse_dark = hex_to_rgba("#5A3320")
    horse_light = hex_to_rgba("#A67C52")
    draw.rectangle([4,12,18,18], fill=horse_body, outline=DARK_OUTLINE)
    draw.rectangle([5,13,7,17], fill=horse_light) # highlight
    # horse neck and head
    draw.rectangle([16,8,19,13], fill=horse_body, outline=DARK_OUTLINE)
    draw.rectangle([16,8,17,12], fill=horse_light)
    draw.rectangle([18,10,20,13], fill=horse_body, outline=DARK_OUTLINE) # head
    draw.rectangle([19,10,20,11], fill=horse_dark) # nose
    # mane
    draw.line([(16,8),(16,11)], fill=(20,20,20,255), width=1)
    # legs
    draw.rectangle([5,18,7,20], fill=horse_dark, outline=DARK_OUTLINE)
    draw.rectangle([10,18,12,20], fill=horse_dark, outline=DARK_OUTLINE)
    draw.rectangle([14,18,16,20], fill=horse_dark, outline=DARK_OUTLINE)
    draw.rectangle([17,18,19,20], fill=horse_dark, outline=DARK_OUTLINE)
    # tail
    draw.rectangle([3,13,4,16], fill=horse_dark, outline=DARK_OUTLINE)
    # saddle
    draw.rectangle([10,11,14,13], fill=pal["shadow"], outline=DARK_OUTLINE)
    # rider
    # rider body
    draw.rectangle([9,5,14,11], fill=pal["primary"], outline=DARK_OUTLINE)
    draw.rectangle([9,5,10,10], fill=pal["highlight"])
    # head
    draw.rectangle([10,2,13,5], fill=SKIN, outline=DARK_OUTLINE)
    draw.point((11,4), fill=BLACK)
    # helmet with plume
    draw.rectangle([9,1,14,3], fill=pal["shadow"], outline=DARK_OUTLINE)
    draw.rectangle([9,1,11,2], fill=pal["primary"])
    # plume/banner fluttering
    draw.rectangle([12,0,13,1], fill=pal["highlight"])
    # lance / spear held by cavalry (diagonal)
    draw.line([(14,6),(20,2)], fill=METAL, width=1)
    draw.polygon([(20,1),(22,2),(20,3)], fill=METAL, outline=DARK_OUTLINE)
    # banner/flag flowing from lance
    draw.rectangle([12,4,14,6], fill=pal["primary"], outline=DARK_OUTLINE)
    draw.rectangle([12,4,13,5], fill=pal["highlight"])
    # rider legs
    draw.rectangle([9,11,11,13], fill=pal["shadow"], outline=DARK_OUTLINE)
    return img

def spearman_sprite(faction):
    img, draw = sprite_canvas()
    pal = BLUE if faction=="blue" else RED
    draw.ellipse([7,20,17,23], fill=(0,0,0,70))
    # legs
    draw.rectangle([9,14,11,20], fill=pal["shadow"], outline=DARK_OUTLINE)
    draw.rectangle([13,14,15,20], fill=pal["shadow"], outline=DARK_OUTLINE)
    draw.rectangle([8,20,11,21], fill=(40,30,20,255), outline=DARK_OUTLINE)
    draw.rectangle([13,20,16,21], fill=(40,30,20,255), outline=DARK_OUTLINE)
    # body - heavier armor
    draw.rectangle([8,8,16,15], fill=pal["primary"], outline=DARK_OUTLINE)
    draw.rectangle([9,9,11,14], fill=pal["highlight"])
    # shoulder pads
    draw.rectangle([7,8,9,10], fill=pal["shadow"], outline=DARK_OUTLINE)
    draw.rectangle([15,8,17,10], fill=pal["shadow"], outline=DARK_OUTLINE)
    # belt
    draw.rectangle([8,13,16,14], fill=pal["dark"])
    # head with spear helmet
    draw.rectangle([10,3,14,8], fill=SKIN, outline=DARK_OUTLINE)
    draw.rectangle([9,2,15,5], fill=pal["shadow"], outline=DARK_OUTLINE)
    draw.rectangle([9,2,12,4], fill=pal["primary"])
    draw.point((11,6), fill=BLACK)
    draw.point((13,6), fill=BLACK)
    # extremely long spear - vertical line from top to bottom on right, with spearhead above
    # shaft
    draw.rectangle([17,0,18,21], fill=WOOD, outline=DARK_OUTLINE)
    # shaft highlight
    draw.line([(17,1),(17,20)], fill=hex_to_rgba("#C19A6B"), width=1)
    # spearhead
    draw.polygon([(17,0),(18,0),(20,3),(17,4)], fill=METAL, outline=DARK_OUTLINE)
    draw.line([(18,1),(18,3)], fill=METAL_L, width=1)
    # spear butt
    draw.rectangle([17,21,18,22], fill=METAL, outline=DARK_OUTLINE)
    # shield small round left
    draw.ellipse([4,9,8,13], fill=pal["primary"], outline=DARK_OUTLINE)
    draw.ellipse([5,10,7,12], fill=METAL, outline=DARK_OUTLINE)
    return img

def siege_sprite(faction):
    img, draw = sprite_canvas()
    pal = BLUE if faction=="blue" else RED
    draw.ellipse([4,20,20,23], fill=(0,0,0,80))
    # trebuchet / catapult base frame wood
    # base platform
    draw.rectangle([4,16,20,19], fill=WOOD, outline=DARK_OUTLINE)
    draw.rectangle([5,17,7,18], fill=hex_to_rgba("#C19A6B"))
    # wheels
    draw.ellipse([5,18,8,21], fill=WOOD_D, outline=DARK_OUTLINE)
    draw.ellipse([6,19,7,20], fill=hex_to_rgba("#3A2A12"))
    draw.ellipse([16,18,19,21], fill=WOOD_D, outline=DARK_OUTLINE)
    draw.ellipse([17,19,18,20], fill=hex_to_rgba("#3A2A12"))
    # A-frame supports
    draw.polygon([(8,16),(11,6),(12,6),(9,16)], fill=WOOD, outline=DARK_OUTLINE)
    draw.polygon([(16,16),(13,6),(14,6),(17,16)], fill=WOOD_D, outline=DARK_OUTLINE)
    # beam arm diagonal
    draw.line([(10,8),(18,3)], fill=WOOD, width=1)
    draw.line([(10,8),(18,3)], fill=WOOD, width=1)
    # thicker arm via rectangle polygon
    draw.polygon([(9,8),(12,6),(19,3),(18,5)], fill=WOOD, outline=DARK_OUTLINE)
    # counterweight
    draw.rectangle([8,10,10,12], fill=hex_to_rgba("#6A6A6A"), outline=DARK_OUTLINE)
    draw.rectangle([8,10,9,11], fill=hex_to_rgba("#9A9A9A"))
    # projectile bucket / sling
    draw.rectangle([18,2,20,4], fill=pal["primary"], outline=DARK_OUTLINE)
    draw.ellipse([17,1,21,5], fill=(0,0,0,0), outline=DARK_OUTLINE) # rim?
    # stone
    draw.ellipse([18,1,20,3], fill=hex_to_rgba("#9E9E9E"), outline=DARK_OUTLINE)
    # flag on side
    draw.line([(12,6),(12,2)], fill=DARK_OUTLINE, width=1)
    draw.rectangle([12,2,15,4], fill=pal["primary"], outline=DARK_OUTLINE)
    draw.rectangle([12,2,13,3], fill=pal["highlight"])
    # crewman small behind
    draw.ellipse([14,12,16,14], fill=SKIN, outline=DARK_OUTLINE) # head
    draw.rectangle([13,14,17,16], fill=pal["primary"], outline=DARK_OUTLINE)
    return img

def conscript_sprite(faction):
    img, draw = sprite_canvas()
    pal = BLUE if faction=="blue" else RED
    # more ragged silhouette
    draw.ellipse([6,20,18,23], fill=(0,0,0,60))
    # legs ragged
    draw.rectangle([9,14,11,20], fill=hex_to_rgba("#7A6A4A"), outline=DARK_OUTLINE)
    draw.rectangle([13,14,15,20], fill=hex_to_rgba("#7A6A4A"), outline=DARK_OUTLINE)
    draw.rectangle([8,20,12,21], fill=hex_to_rgba("#4A3A2A"), outline=DARK_OUTLINE)
    draw.rectangle([13,20,17,21], fill=hex_to_rgba("#4A3A2A"), outline=DARK_OUTLINE)
    # tunic ragged - earthy but with faction armband/sash
    draw.rectangle([8,8,16,15], fill=hex_to_rgba("#9E8B6B"), outline=DARK_OUTLINE)
    # faction sash diagonal
    draw.polygon([(8,11),(12,8),(13,9),(9,12)], fill=pal["primary"])
    draw.polygon([(12,14),(16,11),(16,12),(12,15)], fill=pal["primary"])
    # belt rope
    draw.rectangle([8,12,16,13], fill=hex_to_rgba("#5A4A32"))
    # head with straw hat
    draw.rectangle([10,4,14,8], fill=SKIN, outline=DARK_OUTLINE)
    draw.point((11,6), fill=BLACK)
    draw.point((13,6), fill=BLACK)
    # straw hat wide
    draw.ellipse([8,3,16,6], fill=hex_to_rgba("#D7BF8A"), outline=DARK_OUTLINE)
    draw.ellipse([9,2,15,5], fill=hex_to_rgba("#E8D5A0"), outline=DARK_OUTLINE)
    # hat top
    draw.ellipse([10,1,14,4], fill=hex_to_rgba("#D7BF8A"), outline=DARK_OUTLINE)
    # pitchfork / farming tool - long with fork top
    # shaft
    draw.rectangle([17,3,18,21], fill=WOOD, outline=DARK_OUTLINE)
    # fork prongs
    draw.line([(16,3),(16,6)], fill=METAL, width=1)
    draw.line([(18,3),(18,6)], fill=METAL, width=1)
    draw.line([(16,6),(18,6)], fill=METAL, width=1)
    # middle prong shorter
    draw.line([(17,4),(17,6)], fill=METAL, width=1)
    # highlights
    draw.line([(17,3),(17,15)], fill=hex_to_rgba("#C8A882"), width=1)
    return img

def scout_sprite(faction):
    img, draw = sprite_canvas()
    pal = BLUE if faction=="blue" else RED
    draw.ellipse([7,20,17,23], fill=(0,0,0,70))
    # legs light, running pose with one leg forward?
    draw.rectangle([9,14,11,20], fill=pal["shadow"], outline=DARK_OUTLINE)
    draw.rectangle([13,14,15,20], fill=pal["shadow"], outline=DARK_OUTLINE)
    draw.rectangle([9,14,10,19], fill=pal["primary"])
    draw.rectangle([8,20,11,21], fill=(40,30,20,255), outline=DARK_OUTLINE)
    draw.rectangle([13,20,16,21], fill=(40,30,20,255), outline=DARK_OUTLINE)
    # cloak - extends behind
    draw.polygon([(7,9),(9,8),(15,8),(17,11),(16,15),(6,15)], fill=hex_to_rgba("#3A3A3A"), outline=DARK_OUTLINE)
    # cloak faction lining inside
    draw.polygon([(8,10),(14,10),(14,14),(8,14)], fill=pal["primary"])
    # body tunic under cloak
    draw.rectangle([9,8,15,14], fill=pal["primary"], outline=DARK_OUTLINE)
    draw.rectangle([9,8,11,12], fill=pal["highlight"])
    # head hooded but face visible
    draw.rectangle([10,3,14,8], fill=SKIN, outline=DARK_OUTLINE)
    # hood
    draw.rectangle([9,2,15,5], fill=hex_to_rgba("#2A2A2A"), outline=DARK_OUTLINE)
    draw.rectangle([9,2,11,4], fill=hex_to_rgba("#4A4A4A"))
    draw.point((11,6), fill=BLACK)
    draw.point((13,6), fill=BLACK)
    # dagger in hand right side
    draw.rectangle([16,10,17,14], fill=METAL, outline=DARK_OUTLINE)
    draw.polygon([(16,10),(17,10),(17,8)], fill=METAL, outline=DARK_OUTLINE)
    draw.line([(16,11),(16,13)], fill=METAL_L, width=1)
    draw.rectangle([16,14,17,15], fill=WOOD_D, outline=DARK_OUTLINE)
    # light cloak flutter
    draw.rectangle([6,11,7,14], fill=hex_to_rgba("#5A5A5A"))
    # speed lines? subtle
    draw.line([(5,12),(6,12)], fill=(255,255,255,90), width=1)
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

# Also need to support old filename mapping for backwards compat cleanup
OLD_NAMES = {
    "infantry": "infantry",
    "archer": "archer", # old was archers plural
    "cavalry": "cavalry",
    "spearman": "spearman", # old was spearmen
    "siege": "siege",
    "conscript": "conscript", # old was conscripts
    "scout": "scout", # old was scouts
}

for unit_key, fn in SPRITES.items():
    for faction in ["blue", "red"]:
        img = fn(faction)
        fname = f"unit_{unit_key}_{faction}.png"
        out = os.path.join(SPRITE_DIR, fname)
        img.save(out, "PNG")
        print(f"Sprite saved: {out} {img.size}")

# Clean up old incorrectly named sprites if they exist (archers, spearmen, etc)
import glob
for old in glob.glob(os.path.join(SPRITE_DIR, "unit_*_*.png")):
    bn = os.path.basename(old)
    # if plural, delete
    if "archers" in bn or "spearmen" in bn or "conscripts" in bn or "scouts" in bn:
        try:
            os.remove(old)
            print(f"Removed legacy: {old}")
        except: pass

# ============================================================
# UI ELEMENTS
# ============================================================
def ui_selection():
    img = Image.new("RGBA", (TILE_W, TILE_H), (0,0,0,0))
    draw = ImageDraw.Draw(img)
    # thick glowing hex outline - yellow/gold for selection
    # outer glow
    draw.polygon(HEX_POINTS, outline="#FFD54F", width=3)
    # inner bright
    inner = [(13,2),(35,2),(46,21),(35,40),(13,40),(2,21)]
    draw.polygon(inner, outline="#FFF176", width=1)
    # corners emphasis
    for x,y in HEX_POINTS:
        draw.ellipse([x-2,y-2,x+2,y+2], fill="#FFEB3B", outline="#FF6F00")
    return img

def ui_move_range():
    img = Image.new("RGBA", (TILE_W, TILE_H), (0,0,0,0))
    draw = ImageDraw.Draw(img)
    # translucent blue fill inside hex + subtle border
    draw.polygon(HEX_POINTS, fill=(47,128,237,80), outline=(47,128,237,180))
    inner = [(13,2),(35,2),(46,21),(35,40),(13,40),(2,21)]
    draw.polygon(inner, outline=(122,176,255,120), width=1)
    # small dot center
    draw.ellipse([22,19,26,23], fill=(47,128,237,140), outline=(255,255,255,100))
    return img

def ui_attack_range():
    img = Image.new("RGBA", (TILE_W, TILE_H), (0,0,0,0))
    draw = ImageDraw.Draw(img)
    draw.polygon(HEX_POINTS, fill=(235,87,87,75), outline=(235,87,87,190))
    inner = [(13,2),(35,2),(46,21),(35,40),(13,40),(2,21)]
    draw.polygon(inner, outline=(255,138,128,120), width=1)
    # crosshair center
    draw.line([(24,16),(24,26)], fill=(235,87,87,200), width=1)
    draw.line([(19,21),(29,21)], fill=(235,87,87,200), width=1)
    draw.ellipse([22,19,26,23], fill=(0,0,0,0), outline=(235,87,87,220))
    return img

def ui_fog():
    img = Image.new("RGBA", (TILE_W, TILE_H), (0,0,0,0))
    draw = ImageDraw.Draw(img)
    # dark fog with pattern
    draw.polygon(HEX_POINTS, fill=(30,30,40,170), outline=(20,20,30,220))
    # diagonal hatch
    for x in range(0, 48, 6):
        draw.line([(x,0),(x+12,42)], fill=(60,60,80,90), width=1)
    # center question / eye icon simplified
    draw.ellipse([18,16,30,26], fill=(50,50,70,180), outline=(80,80,110,200))
    draw.ellipse([22,19,26,23], fill=(30,30,40,200))
    return img

def ui_panel():
    # 9-slice panel 96x64
    W, H = 96, 64
    img = Image.new("RGBA", (W, H), (0,0,0,0))
    draw = ImageDraw.Draw(img)
    # base
    draw.rectangle([0,0,W-1,H-1], fill=(42,38,32,230), outline=(212,168,67,255), width=2)
    # inner highlight
    draw.rectangle([2,2,W-3,3], fill=(90,80,60,255))
    draw.rectangle([2,2,3,H-3], fill=(80,70,50,255))
    # inset inner frame
    draw.rectangle([6,6,W-7,H-7], fill=(28,24,20,255), outline=(60,55,45,255))
    # corner accents
    for x,y in [(0,0),(W-4,0),(0,H-4),(W-4,H-4)]:
        draw.rectangle([x,y,x+3,y+3], fill=(212,168,67,255), outline=(150,120,40,255))
    # title bar area
    draw.rectangle([6,6,W-7,16], fill=(58,50,38,255), outline=(80,70,50,255))
    # small gem centers
    draw.ellipse([W//2-2,8,W//2+2,12], fill=(212,168,67,255), outline=(150,120,40,255))
    return img

def ui_button():
    W, H = 64, 20
    img = Image.new("RGBA", (W, H), (0,0,0,0))
    draw = ImageDraw.Draw(img)
    draw.rectangle([0,0,W-1,H-1], fill=(70,65,55,255), outline=(212,168,67,255), width=1)
    draw.rectangle([1,1,W-2,3], fill=(110,100,80,255))
    draw.rectangle([1,1,2,H-2], fill=(100,90,70,255))
    draw.rectangle([2,4,W-3,H-3], fill=(50,45,35,255), outline=(80,70,55,255))
    # center highlight
    draw.rectangle([W//2-8,8,W//2+8,10], fill=(212,168,67,180))
    return img

def ui_button_hover():
    W, H = 64, 20
    img = Image.new("RGBA", (W, H), (0,0,0,0))
    draw = ImageDraw.Draw(img)
    draw.rectangle([0,0,W-1,H-1], fill=(90,85,70,255), outline=(255,213,79,255), width=1)
    draw.rectangle([1,1,W-2,3], fill=(140,130,100,255))
    draw.rectangle([2,4,W-3,H-3], fill=(70,60,40,255), outline=(110,100,70,255))
    draw.rectangle([W//2-8,8,W//2+8,10], fill=(255,213,79,220))
    # glow
    draw.rectangle([0,0,W-1,H-1], outline=(255,213,79,90), width=2)
    return img

def ui_hex_grid():
    # standalone hex outline tile for editor - 48x42 with no fill, just grid line
    img = Image.new("RGBA", (TILE_W, TILE_H), (0,0,0,0))
    draw = ImageDraw.Draw(img)
    draw.polygon(HEX_POINTS, outline=(255,255,255,60), width=1)
    inner = [(12,1),(36,1),(47,21),(36,41),(12,41),(1,21)]
    draw.polygon(inner, outline=(0,0,0,40), width=1)
    return img

ui_items = {
    "ui_selection.png": ui_selection,
    "ui_move_range.png": ui_move_range,
    "ui_attack_range.png": ui_attack_range,
    "ui_fog.png": ui_fog,
    "ui_panel.png": ui_panel,
    "ui_button.png": ui_button,
    "ui_button_hover.png": ui_button_hover,
    "ui_hex_grid.png": ui_hex_grid,
}

for fname, fn in ui_items.items():
    img = fn()
    out = os.path.join(UI_DIR, fname)
    img.save(out, "PNG")
    print(f"UI saved: {out} {img.size}")

print("All v3 assets generated.")
