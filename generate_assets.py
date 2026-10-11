import os
from PIL import Image, ImageDraw
import math

base_dir = r"d:\Game development\Demon slayer\StrategyGame\assets"
tiles_dir = os.path.join(base_dir, "tiles")
sprites_dir = os.path.join(base_dir, "sprites")
ui_dir = os.path.join(base_dir, "ui")

for d in [tiles_dir, sprites_dir, ui_dir]:
    os.makedirs(d, exist_ok=True)

# --- Tiles ---
# 64x56 Flat-top hex
hex_width = 64
hex_height = 56
size = hex_width / 2.0

def get_hex_polygon():
    w = hex_width
    h = hex_height
    return [
        (0, h/2),
        (w/4, 0),
        (w*3/4, 0),
        (w, h/2),
        (w*3/4, h),
        (w/4, h)
    ]

terrains = {
    "plains": {"bg": "#8BB174", "detail": "#70995B"},
    "mountains": {"bg": "#8A8D8F", "detail": "#595B5C"},
    "forest": {"bg": "#3B7D4F", "detail": "#255433"},
    "swamp": {"bg": "#6B7C63", "detail": "#4D5C46"},
    "fortress": {"bg": "#A9B3BA", "detail": "#6A747D"},
    "village": {"bg": "#D9A066", "detail": "#A87442"},
    "road": {"bg": "#8BB174", "detail": "#DED3AE"} # Plains bg, road detail
}

def draw_hex(color_bg, color_detail, name):
    img = Image.new("RGBA", (hex_width, hex_height), (0,0,0,0))
    draw = ImageDraw.Draw(img)
    poly = get_hex_polygon()
    draw.polygon(poly, fill=color_bg, outline="#444444", width=2)
    
    # Add some simple pattern for distinction
    if name == "mountains":
        draw.polygon([(16, 40), (32, 10), (48, 40)], fill=color_detail)
    elif name == "forest":
        draw.ellipse([(12, 12), (32, 44)], fill=color_detail)
        draw.ellipse([(32, 12), (52, 44)], fill=color_detail)
    elif name == "swamp":
        draw.rectangle([(20, 30), (44, 34)], fill=color_detail)
        draw.rectangle([(12, 20), (28, 24)], fill=color_detail)
    elif name == "fortress":
        draw.rectangle([(16, 16), (48, 40)], fill=color_detail, outline="#444444")
        draw.rectangle([(12, 12), (20, 20)], fill=color_detail)
        draw.rectangle([(44, 12), (52, 20)], fill=color_detail)
    elif name == "village":
        draw.rectangle([(24, 24), (40, 40)], fill=color_detail)
        draw.polygon([(20, 24), (32, 12), (44, 24)], fill="#A84242")
    elif name == "road":
        draw.polygon([(26, 0), (38, 0), (38, 56), (26, 56)], fill=color_detail)

    img.save(os.path.join(tiles_dir, f"terrain_{name}.png"))

for t_name, colors in terrains.items():
    draw_hex(colors["bg"], colors["detail"], t_name)


# --- Sprites ---
# 32x32 units
unit_types = {
    "infantry": "sword",
    "archers": "bow",
    "cavalry": "horse",
    "spearmen": "spear",
    "siege": "ram",
    "conscripts": "pitchfork",
    "scouts": "flag"
}

factions = {
    "blue": "#3A6EA5",
    "red": "#C14B51"
}

def draw_unit(unit_type, faction, color):
    img = Image.new("RGBA", (32, 32), (0,0,0,0))
    draw = ImageDraw.Draw(img)
    
    # Base body
    if unit_type == "cavalry":
        draw.rectangle([(4, 16), (28, 28)], fill="#6B4423") # horse
        draw.rectangle([(12, 6), (20, 16)], fill=color) # rider
    elif unit_type == "siege":
        draw.rectangle([(4, 12), (28, 28)], fill="#8A6B4E") # wood
        draw.rectangle([(8, 16), (24, 24)], fill="#444444") # iron
        draw.rectangle([(14, 4), (18, 12)], fill=color) # flag
    else:
        draw.rectangle([(10, 8), (22, 24)], fill=color) # body
        draw.ellipse([(12, 2), (20, 10)], fill="#FFD1A9") # head
        
        # Weapons/distinctions
        if unit_type == "infantry":
            draw.rectangle([(22, 12), (24, 22)], fill="#AAAAAA") # sword
            draw.ellipse([(6, 10), (12, 20)], fill="#777777") # shield
        elif unit_type == "archers":
            draw.arc([(18, 8), (28, 24)], start=270, end=90, fill="#6B4423", width=2) # bow
        elif unit_type == "spearmen":
            draw.rectangle([(22, 2), (24, 28)], fill="#AAAAAA") # spear
        elif unit_type == "conscripts":
            draw.rectangle([(22, 8), (24, 24)], fill="#6B4423") # stick
        elif unit_type == "scouts":
            draw.rectangle([(22, 4), (24, 24)], fill="#6B4423")
            draw.rectangle([(24, 4), (30, 10)], fill=color) # flag

    img.save(os.path.join(sprites_dir, f"unit_{unit_type}_{faction}.png"))

for u_name in unit_types.keys():
    for f_name, f_color in factions.items():
        draw_unit(u_name, f_name, f_color)

print("Assets generated successfully!")
