extends Control

## CIV3D unit badge (VISUAL ONLY): Civ-style unit flag floating above a
## formation - a round seal in the faction colour with the class character,
## a gold rim (bright when selected / hovered) and a strength bar. Screen-space, constant pixel size, input-transparent.

const GLYPH := {
	"infantry": "步", "spearman": "槍", "spearmen": "槍", "spear": "槍",
	"archer": "弓", "archers": "弓", "cavalry": "騎", "scout": "斥", "scouts": "斥",
	"conscript": "卒", "conscripts": "卒", "siege": "砲", "hq": "帥", "supply": "輜",
}
const FACTION_FILL := {"blue": Color(0.17, 0.30, 0.55), "red": Color(0.58, 0.16, 0.12)}
const RIM := Color(0.78, 0.64, 0.34)
const RIM_HOT := Color(1.0, 0.86, 0.45)
const INK := Color(0.08, 0.07, 0.06, 0.85)
const R: float = 15.0

var unit_class: String = "infantry"
var faction: String = "blue"
var count: int = 0
var max_count: int = 1
var state: int = 0 # 0 normal, 1 hover, 2 selected
var compact: bool = false # far zoom: seal only

func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	size = Vector2(72, 48)
	pivot_offset = Vector2(36, 40)

func set_data(p_count: int, p_max: int, p_state: int, p_compact: bool) -> void:
	if p_count == count and p_max == max_count and p_state == state and p_compact == compact:
		return
	count = p_count
	max_count = maxi(1, p_max)
	state = p_state
	compact = p_compact
	queue_redraw()

func _draw() -> void:
	var c := Vector2(36, 18)
	var fill: Color = FACTION_FILL.get(faction, Color(0.3, 0.3, 0.3))
	var rim: Color = RIM_HOT if state > 0 else RIM
	# drop shadow, rim, seal
	draw_circle(c + Vector2(1.5, 2.0), R + 2.5, Color(0, 0, 0, 0.35))
	draw_circle(c, R + 2.5, rim)
	draw_circle(c, R, fill.darkened(0.25))
	draw_circle(c, R - 1.5, fill)
	if state == 2:
		draw_arc(c, R + 4.5, 0.0, TAU, 40, Color(1.0, 0.86, 0.45, 0.9), 2.0, true)
	var font: Font = ThemeDB.fallback_font
	var g: String = GLYPH.get(unit_class, "兵")
	var fs: int = 17
	var gs: Vector2 = font.get_string_size(g, HORIZONTAL_ALIGNMENT_CENTER, -1, fs)
	draw_string(font, c + Vector2(-gs.x * 0.5, fs * 0.36), g, HORIZONTAL_ALIGNMENT_CENTER, -1, fs, Color(0.96, 0.92, 0.80))
	if compact:
		return
	# strength bar
	var frac: float = clampf(float(count) / float(max_count), 0.0, 1.0)
	var bar := Rect2(c.x - 17, c.y + R + 5, 34, 5)
	draw_rect(bar.grow(1.0), INK)
	var hp: Color = Color(0.45, 0.78, 0.32).lerp(Color(0.93, 0.78, 0.25), clampf((0.7 - frac) / 0.35, 0.0, 1.0))
	hp = hp.lerp(Color(0.86, 0.26, 0.18), clampf((0.35 - frac) / 0.25, 0.0, 1.0))
	draw_rect(Rect2(bar.position, Vector2(bar.size.x * frac, bar.size.y)), hp)
