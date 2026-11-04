extends Control

## CIV3D unit badge (VISUAL ONLY): Civ-style unit flag floating above a
## formation - a round seal in the faction colour with the class character,
## a gold rim (bright when selected / hovered) and a strength bar. Screen-space, constant pixel size, input-transparent.

const GLYPH := {
	"infantry": "步", "spearman": "槍", "spearmen": "槍", "spear": "槍",
	"archer": "弓", "archers": "弓", "cavalry": "騎", "scout": "斥", "scouts": "斥",
	"conscript": "卒", "conscripts": "卒", "siege": "砲", "hq": "帥", "supply": "輜",
}
const ICON_DIR := "res://assets/ui/unit_icons/"
const ICON_FILE := {
	"infantry": "infantry", "spearman": "spear", "spearmen": "spear", "spear": "spear",
	"archer": "archer", "archers": "archer", "cavalry": "cavalry", "scout": "scout", "scouts": "scout",
	"conscript": "conscript", "conscripts": "conscript", "siege": "siege", "hq": "hq",
}
static var _icon_cache: Dictionary = {}    # file name -> ImageTexture (null = no picture, keep the character)

static func _icon_for(unit_class: String) -> Texture2D:
	var f: String = str(ICON_FILE.get(unit_class, ""))
	if f == "":
		return null
	if not _icon_cache.has(f):
		var tex: ImageTexture = null
		var path: String = ProjectSettings.globalize_path(ICON_DIR + f + ".png")
		if FileAccess.file_exists(path):
			var img := Image.load_from_file(path)
			if img != null and not img.is_empty():
				img.convert(Image.FORMAT_RGBA8)
				img.resize(72, 72, Image.INTERPOLATE_LANCZOS)
				img.generate_mipmaps()
				tex = ImageTexture.create_from_image(img)
		_icon_cache[f] = tex
	return _icon_cache[f]

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

# Rules V2 morale ring (blue units only): three arcs around the seal, tier colour, blinking arc = the one that is filling / draining.
const MORALE_WEAK := 66.0
const MORALE_BROKEN := 33.0
const COL_OK := Color(0.45, 0.78, 0.32)    # one palette for the thumbnail AND the expanded ring: green -> yellow -> red
const COL_WEAK := Color(0.93, 0.78, 0.25)
const COL_BAD := Color(0.86, 0.26, 0.18)
const OUT_LOSS := 8.0         # morale lost per turn outside the supply radius (RulesV2.OUT_MORALE)
var morale: float = 100.0
var morale_trend: int = 0      # +1 rising next turn, -1 falling, 0 steady
var morale_on: bool = false    # unit has a morale ring (V2, own side)
# HQ: the ring shows the supply stock (bases it can still build) instead of morale, in its own colour
const COL_SUPPLY := Color(0.32, 0.74, 0.88)
var supply_on: bool = false
var supply_count: int = 0
var supply_cap: int = 4
var _grow: float = 0.0         # 0 = the gold rim itself is the thumbnail of the ring, 1 = expanded full ring (hover / selected)

func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
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

func set_morale(p_morale: float, p_trend: int, p_on: bool) -> void:
	if is_equal_approx(p_morale, morale) and p_trend == morale_trend and p_on == morale_on:
		return
	morale = p_morale
	morale_trend = p_trend
	morale_on = p_on
	queue_redraw()


func set_supply(p_count: int, p_cap: int, p_on: bool) -> void:
	if p_count == supply_count and p_cap == supply_cap and p_on == supply_on:
		return
	supply_count = p_count
	supply_cap = maxi(1, p_cap)
	supply_on = p_on
	queue_redraw()


func _process(delta: float) -> void:
	if not ((morale_on or supply_on) and visible and not compact):
		return
	var target: float = 1.0 if state > 0 else 0.0
	if not is_equal_approx(_grow, target):
		_grow = move_toward(_grow, target, delta * 7.0)
		queue_redraw()
	elif morale_on and (morale <= MORALE_WEAK or morale_trend != 0):
		queue_redraw()   # a blinking ring needs a redraw every frame


func _ring_shown() -> bool:
	return (morale_on or supply_on) and not compact


func _draw_supply_ring(c: Vector2) -> void:
	var g: float = _grow * _grow * (3.0 - 2.0 * _grow)
	var rr: float = lerpf(R + 1.25, R + 5.0, g)
	var tw: float = lerpf(2.6, 3.0, g)
	var n: int = supply_cap
	var seg: float = TAU / float(n)
	var gap: float = lerpf(0.20, 0.24, g) * (3.0 / float(n)) if n > 3 else lerpf(0.20, 0.24, g)
	for j in n:
		var a0: float = -PI * 0.5 + float(j) * seg + gap * 0.5
		var a1: float = a0 + seg - gap
		draw_arc(c, rr, a0, a1, 12, INK, lerpf(tw, tw + 2.0, g), true)
		# stock is spent clockwise: the first arc clockwise from the top empties first
		if j >= n - supply_count:
			draw_arc(c, rr, a0, a1, 12, COL_SUPPLY, tw, true)


func _draw_morale_ring(c: Vector2) -> void:
	var t: float = float(Time.get_ticks_msec()) / 1000.0
	var g: float = _grow * _grow * (3.0 - 2.0 * _grow)
	var tier_col: Color = Color.WHITE
	var pulse_hz: float = 0.0 if morale > MORALE_WEAK else (1.0 if morale > MORALE_BROKEN else 2.2)
	var base_a: float = 1.0 if pulse_hz == 0.0 else 0.62 + 0.38 * (0.5 + 0.5 * sin(t * TAU * pulse_hz))
	var blink: float = 0.5 + 0.5 * sin(t * TAU * 2.4)
	tier_col = COL_OK if morale > MORALE_WEAK else (COL_WEAK if morale > MORALE_BROKEN else COL_BAD)
	var rr: float = lerpf(R + 1.25, R + 7.0, g)
	var tw: float = lerpf(2.6, 3.0, g)
	var gap: float = lerpf(0.20, 0.24, g)
	# the thumbnail IS the gold rim; expanding only changes size / thickness, never the colour
	var seg: float = TAU / 3.0
	# The ring fills counter-clockwise and DRAINS CLOCKWISE: the first arc clockwise from the top is the highest tier (it empties
	# first), and inside an arc the fill is anchored at its clockwise end. k = tier of an arc (0 = lowest = last to empty).
	# changing arc: rising -> the first not-full tier (its empty rest flashes), falling -> the highest non-empty tier (its fill flashes)
	var active: int = -1
	if morale_trend > 0:
		for k in 3:
			if clampf((morale - float(k) * 33.34) / 33.34, 0.0, 1.0) < 0.999:
				active = k
				break
	elif morale_trend < 0:
		for k in range(2, -1, -1):
			if clampf((morale - float(k) * 33.34) / 33.34, 0.0, 1.0) > 0.001:
				active = k
				break
	for j in 3:
		var k: int = 2 - j
		var a0: float = -PI * 0.5 + float(j) * seg + gap * 0.5
		var a1: float = a0 + seg - gap
		var fill: float = clampf((morale - float(k) * 33.34) / 33.34, 0.0, 1.0)
		draw_arc(c, rr, a0, a1, 14, INK, lerpf(tw, tw + 2.0, g), true)    # track
		var fa: float = a1 - (a1 - a0) * fill                              # the fill runs from fa (its free edge) to a1
		if k == active and morale_trend > 0 and fill < 0.999:
			var glow: Color = tier_col.lerp(Color(1, 1, 1), 0.35 + 0.5 * blink)
			draw_arc(c, rr, a0, fa, 10, Color(glow.r, glow.g, glow.b, 0.25 + 0.55 * blink), tw, true)   # the part about to fill
		if fill > 0.001:
			var col: Color = tier_col
			col.a = base_a
			if k == active and morale_trend < 0:
				# draining: the slice that the next turn takes away (OUT_LOSS morale) blinks red, from its clockwise-leading edge.
				# Faint and slow at high morale, wider swing AND faster the lower the morale gets (never invisible: min swing 0.45).
				var inten: float = clampf(1.0 - morale / 100.0, 0.0, 1.0)
				var dn: float = 0.5 + 0.5 * sin(t * TAU * lerpf(1.1, 4.0, inten))
				var amp: float = lerpf(0.45, 1.0, inten)
				var next_fill: float = clampf((maxf(0.0, morale - OUT_LOSS) - float(k) * 33.34) / 33.34, 0.0, 1.0)
				var fa_next: float = a1 - (a1 - a0) * next_fill
				var lost: Color = tier_col.lerp(COL_BAD, 0.35 + 0.65 * amp * dn)
				lost.a = 1.0 - 0.75 * amp * (1.0 - dn)
				draw_arc(c, rr, fa, fa_next, 8, lost, tw, true)
				if next_fill > 0.001:
					draw_arc(c, rr, fa_next, a1, 14, col, tw, true)
			else:
				draw_arc(c, rr, fa, a1, 14, col, tw, true)
	# full ring that is still charging (inside the blue radius at max morale): a bright glint keeps running counter-clockwise
	if morale_trend > 0 and morale >= 99.9:
		var head: float = -PI * 0.5 - fposmod(t / 1.7, 1.0) * TAU
		for n in 5:
			var ang: float = head + float(n) * 0.11
			var al: float = (1.0 - float(n) / 5.0) * 0.9
			draw_arc(c, rr, ang - 0.09, ang, 4, Color(1, 1, 1, al), tw, true)


func _draw() -> void:
	var c := Vector2(36, 18)
	var fill: Color = FACTION_FILL.get(faction, Color(0.3, 0.3, 0.3))
	var rim: Color = RIM_HOT if state > 0 else RIM
	# drop shadow, rim, seal
	draw_circle(c + Vector2(1.5, 2.0), R + 2.5, Color(0, 0, 0, 0.35))
	if _ring_shown():
		draw_circle(c, R + 2.5, INK)   # the rim itself is drawn as the morale thumbnail below
	else:
		draw_circle(c, R + 2.5, rim)
	draw_circle(c, R, fill.darkened(0.25))
	draw_circle(c, R - 1.5, fill)
	if state == 2:
		draw_arc(c, R + 4.5, 0.0, TAU, 40, Color(1.0, 0.86, 0.45, 0.9), 2.0, true)
	var icon: Texture2D = _icon_for(unit_class)
	if icon != null:
		# painted unit icon (assets/ui/unit_icons/<class>.png) instead of the character
		var isz: float = 25.0
		draw_texture_rect(icon, Rect2(c - Vector2(isz, isz) * 0.5, Vector2(isz, isz)), false)
		if compact:
			return
	var font: Font = ThemeDB.fallback_font
	var g: String = GLYPH.get(unit_class, "兵")
	var fs: int = 17
	var gs: Vector2 = font.get_string_size(g, HORIZONTAL_ALIGNMENT_CENTER, -1, fs)
	if icon == null:
		draw_string(font, c + Vector2(-gs.x * 0.5, fs * 0.36), g, HORIZONTAL_ALIGNMENT_CENTER, -1, fs, Color(0.96, 0.92, 0.80))
	if compact:
		return
	if _ring_shown():
		if supply_on:
			_draw_supply_ring(c)
		else:
			_draw_morale_ring(c)
	# strength bar (below the ring; it steps down a little while the ring is expanded)
	var frac: float = clampf(float(count) / float(max_count), 0.0, 1.0)
	var bar := Rect2(c.x - 17, c.y + R + 5.0 + 6.0 * (_grow * _grow * (3.0 - 2.0 * _grow) if (morale_on or supply_on) else 0.0), 34, 5)
	draw_rect(bar.grow(1.0), INK)
	var hp: Color = Color(0.45, 0.78, 0.32).lerp(Color(0.93, 0.78, 0.25), clampf((0.7 - frac) / 0.35, 0.0, 1.0))
	hp = hp.lerp(Color(0.86, 0.26, 0.18), clampf((0.35 - frac) / 0.25, 0.0, 1.0))
	draw_rect(Rect2(bar.position, Vector2(bar.size.x * frac, bar.size.y)), hp)
