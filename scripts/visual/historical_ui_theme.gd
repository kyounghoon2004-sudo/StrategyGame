class_name HistoricalUITheme
extends RefCounted

## HistoricalUITheme — Five Dynasties / Ten Kingdoms Military Command Table Aesthetics
## Lacquer-black base, muted antique gold ornaments, deep military blue and crimson accents.
## Designed to eliminate sci-fi and modern generic flat styling in favor of an authentic
## historical East Asian command desk presentation.

# Core Color Palette
const COLOR_LACQUER_BASE := Color(0.065, 0.075, 0.095, 0.94)    # Deep charcoal lacquer (#111318)
const COLOR_LACQUER_DARK := Color(0.045, 0.050, 0.065, 0.96)    # Dark lacquer shadow (#0B0D10)
const COLOR_LACQUER_CARD := Color(0.080, 0.090, 0.115, 0.92)    # Card panel background

const COLOR_GOLD_ORNAMENT := Color(0.78, 0.65, 0.32, 1.0)       # Muted antique gold (#C7A652)
const COLOR_GOLD_BRIGHT := Color(0.92, 0.82, 0.45, 1.0)         # Illuminated gold highlight (#EBD173)
const COLOR_GOLD_SUBDUE := Color(0.52, 0.44, 0.24, 0.80)        # Muted brass (#85703D)
const COLOR_GOLD_BORDER := Color(0.72, 0.60, 0.30, 0.85)        # Thin gold border

const COLOR_ALLIED_BLUE := Color(0.22, 0.42, 0.72, 1.0)         # Deep Imperial Blue
const COLOR_ALLIED_BLUE_DARK := Color(0.12, 0.22, 0.40, 0.95)   # Navy lacquer
const COLOR_ENEMY_RED := Color(0.78, 0.20, 0.18, 1.0)           # Imperial Crimson
const COLOR_ENEMY_RED_DARK := Color(0.42, 0.12, 0.12, 0.95)     # Dark cinnabar

const COLOR_TEXT_PRIMARY := Color(0.92, 0.90, 0.84, 1.0)        # Silk parchment white
const COLOR_TEXT_SECONDARY := Color(0.72, 0.70, 0.64, 1.0)      # Muted stone grey
const COLOR_TEXT_GOLD := Color(0.92, 0.82, 0.48, 1.0)           # Calligraphic gold
const COLOR_TEXT_CRIMSON := Color(0.92, 0.38, 0.32, 1.0)        # Warning cinnabar

static func create_lacquer_panel(border_width: int = 1, corner_radius: int = 4, border_col: Color = COLOR_GOLD_BORDER) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = COLOR_LACQUER_BASE
	style.border_color = border_col
	style.set_border_width_all(border_width)
	style.set_corner_radius_all(corner_radius)
	style.shadow_color = Color(0, 0, 0, 0.70)
	style.shadow_size = 6
	style.shadow_offset = Vector2(0, 3)
	return style

static func create_card_panel(border_col: Color = COLOR_GOLD_BORDER) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = COLOR_LACQUER_CARD
	style.border_color = border_col
	style.set_border_width_all(1)
	style.set_corner_radius_all(4)
	style.shadow_color = Color(0, 0, 0, 0.55)
	style.shadow_size = 4
	return style

static func create_gold_button(hover: bool = false, pressed: bool = false) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	if pressed:
		style.bg_color = Color(0.24, 0.20, 0.12, 0.95)
		style.border_color = COLOR_GOLD_BRIGHT
	elif hover:
		style.bg_color = Color(0.18, 0.16, 0.12, 0.92)
		style.border_color = COLOR_GOLD_BRIGHT
	else:
		style.bg_color = Color(0.10, 0.11, 0.13, 0.90)
		style.border_color = COLOR_GOLD_BORDER
	style.set_border_width_all(1)
	style.set_corner_radius_all(3)
	style.shadow_color = Color(0, 0, 0, 0.4)
	style.shadow_size = 3
	return style

static func create_tactical_pill_button(active: bool = false) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	if active:
		style.bg_color = Color(0.22, 0.20, 0.14, 0.95)
		style.border_color = COLOR_GOLD_BRIGHT
	else:
		style.bg_color = Color(0.08, 0.09, 0.12, 0.88)
		style.border_color = COLOR_GOLD_SUBDUE
	style.set_border_width_all(1)
	style.set_corner_radius_all(12)
	return style

static func create_primary_action_button() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.18, 0.15, 0.08, 0.95)
	style.border_color = COLOR_GOLD_BRIGHT
	style.set_border_width_all(2)
	style.set_corner_radius_all(6)
	style.shadow_color = Color(0.78, 0.65, 0.32, 0.30)
	style.shadow_size = 6
	return style
