shader_type spatial;
// CIV3D shroud (VISUAL ONLY): Civ-style unexplored space. A plane above the
// tallest scenery; each fragment looks up the fog state of the GROUND point
// behind it (camera ray -> ground plane), so the parchment clouds sit exactly
// over the unexplored hexes from any camera angle and hide their scenery.
// Static: no TIME.
render_mode unshaded, cull_disabled, depth_draw_never, shadows_disabled, blend_mix;

uniform sampler2D cell_tex : filter_nearest; // R terrain, G fog, B unit, A playable
uniform float hex_px = 5.3333;
uniform float ground_y = 0.1;
// Civ-style "seen before, not in sight now": the ground is redrawn as flat old-map paper (hex lines, river and road ink
// from the terrain data) and the REAL 3D scenery (trees, mountains, buildings) is kept but recoloured to a brown ink
// ramp. Scenery is told apart from ground by the scene depth (height above the board).
// 0 = off (legacy maps), 1 = on (designed maps).
uniform float explored_blur : hint_range(0.0, 1.0) = 0.0;
uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;

// ---- old-map look (tune here) ----
const vec3 INK_DARK = vec3(0.22, 0.14, 0.07);   // darkest ink (scenery shadows)
const vec3 INK_LIGHT = vec3(0.78, 0.68, 0.49);  // lightest scenery tone (highlights, close to the paper)
const vec3 INK_WATER = vec3(0.30, 0.41, 0.46);
const vec3 INK_ROAD = vec3(0.45, 0.34, 0.20);
const float RIVER_W = 4.6;       // half-width of the river line, world px
const float OBJ_H = 0.3;         // scene points higher than this (3D units) count as scenery, not board

varying vec3 wpos;

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float vnoise(vec2 p) {
	vec2 i = floor(p); vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1, 0)), u.x), mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), u.x), u.y);
}
float fbm(vec2 p) {
	float a = 0.5; float s = 0.0;
	for (int i = 0; i < 5; i++) { s += a * vnoise(p); p = p * 2.07 + vec2(13.3, 7.9); a *= 0.5; }
	return s;
}
vec2 axial_round(vec2 f) {
	float q = f.x; float r = f.y; float s = -q - r;
	float rq = round(q); float rr = round(r); float rs = round(s);
	float dq = abs(rq - q); float dr = abs(rr - r); float ds = abs(rs - s);
	if (dq > dr && dq > ds) { rq = -rr - rs; } else if (dr > ds) { rr = -rq - rs; }
	return vec2(rq, rr);
}
// 1 = hidden (unexplored or off the playable board), 0 = known
float hidden_at(vec2 wp) {
	float qf = wp.x / 36.0;
	vec2 h = axial_round(vec2(qf, (wp.y - qf * 21.0) / 42.0));
	if (abs(h.x) > 84.0 || abs(h.y) > 84.0) return 1.0;
	vec4 c = textureLod(cell_tex, (h + vec2(85.5)) / 171.0, 0.0);
	if (c.a < 0.5) { return 1.0; }
	return 1.0 - smoothstep(0.08, 0.42, c.g);   // continuous: the view fades cells in/out as the march passes
}

vec2 hex_center_wp(vec2 h) { return vec2(h.x * 36.0, h.y * 42.0 + h.x * 21.0); }
// distance (world px) from wp to the border of its hex (positive inside)
float hex_edge_dist(vec2 wp) {
	float qf = wp.x / 36.0;
	vec2 h = axial_round(vec2(qf, (wp.y - qf * 21.0) / 42.0));
	vec2 p = wp - hex_center_wp(h);
	p.y *= 41.569 / 42.0;
	p = abs(p);
	return 20.785 - max(p.y, dot(p, vec2(0.8660254, 0.5)));
}

// terrain id of the hex under wp (R channel of the cell texture)
float terr_at(vec2 wp) {
	float qf = wp.x / 36.0;
	vec2 h = axial_round(vec2(qf, (wp.y - qf * 21.0) / 42.0));
	if (abs(h.x) > 84.0 || abs(h.y) > 84.0) return 0.0;
	return floor(textureLod(cell_tex, (h + vec2(85.5)) / 171.0, 0.0).r * 255.0 + 0.5);
}

// 1 = explored but not visible right now
float explored_at(vec2 wp) {
	float qf = wp.x / 36.0;
	vec2 h = axial_round(vec2(qf, (wp.y - qf * 21.0) / 42.0));
	if (abs(h.x) > 84.0 || abs(h.y) > 84.0) return 0.0;
	vec4 c = textureLod(cell_tex, (h + vec2(85.5)) / 171.0, 0.0);
	if (c.a < 0.5) { return 0.0; }
	return smoothstep(0.08, 0.42, c.g) * (1.0 - smoothstep(0.58, 0.95, c.g));   // 1 = remembered, fades out as the cell is lit
}

vec2 hex_of(vec2 wp) {
	float qf = wp.x / 36.0;
	return axial_round(vec2(qf, (wp.y - qf * 21.0) / 42.0));
}
float terr_h(vec2 h) {
	if (abs(h.x) > 84.0 || abs(h.y) > 84.0) return 0.0;
	return floor(textureLod(cell_tex, (h + vec2(85.5)) / 171.0, 0.0).r * 255.0 + 0.5);
}
float edge_in_hex(vec2 wp, vec2 h) {   // distance (world px) from wp to the border of hex h, positive inside
	vec2 p = wp - hex_center_wp(h);
	p.y *= 41.569 / 42.0;
	p = abs(p);
	return 20.785 - max(p.y, dot(p, vec2(0.8660254, 0.5)));
}
float seg_dist(vec2 p, vec2 a, vec2 b) {
	vec2 pa = p - a; vec2 ba = b - a;
	return length(pa - ba * clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0));
}
bool road_like(float t) { return t > 4.5 && t < 6.5 || t > 8.5 && t < 9.5 || t > 10.5 && t < 11.5; }
const vec2 NEB[6] = { vec2(1.0, 0.0), vec2(1.0, -1.0), vec2(0.0, -1.0), vec2(-1.0, 0.0), vec2(-1.0, 1.0), vec2(0.0, 1.0) };

// The remembered ground as an inked old map. g = ground point in world px, n = paper noise.
vec3 old_map(vec2 g, float n, float px) {
	vec2 hx = hex_of(g);
	float terr = terr_h(hx);
	vec3 col = mix(vec3(0.78, 0.67, 0.47), vec3(0.87, 0.77, 0.58), n);
	col += (vnoise(g * 0.45) - 0.5) * 0.045 + (hash(floor(g * 0.7)) - 0.5) * 0.02;

	// river / road ribbons from this hex centre toward linked neighbours (same idea as civ_terrain)
	bool water = terr > 6.5 && terr < 7.5;
	if (terr > 5.5 && terr < 6.5) {   // a bridge hex (road on a river): the river keeps flowing under it
		for (int k = 0; k < 6; k++) {
			float nt = terr_h(hx + NEB[k]);
			if (nt > 6.5 && nt < 7.5) { water = true; }
		}
	}
	if (water || road_like(terr)) {
		vec2 ctr = hex_center_wp(hx);
		float dmin = 1e9;
		bool any = false;
		for (int k = 0; k < 6; k++) {
			float nt = terr_h(hx + NEB[k]);
			bool linked = water ? (nt > 6.5 && nt < 7.5 || nt > 5.5 && nt < 6.5) : road_like(nt);   // rivers also reach the bridge hexes
			if (linked) { any = true; dmin = min(dmin, seg_dist(g, ctr, (ctr + hex_center_wp(hx + NEB[k])) * 0.5)); }
		}
		if (!any) dmin = length(g - ctr) * 1.5;
		dmin += (vnoise(g * 0.18) - 0.5) * 2.4;
		if (water) {
			col = mix(col, col * 0.86, 1.0 - smoothstep(RIVER_W + 2.0, RIVER_W + 5.0, dmin));
			col = mix(col, INK_WATER, 1.0 - smoothstep(RIVER_W - 0.8, RIVER_W + 0.4, dmin));
		} else {
			col = mix(col, INK_ROAD, (1.0 - smoothstep(1.0, 2.0, dmin)) * 0.7);
		}
	}
	// hex lines, brown ink
	float line = 1.0 - smoothstep(0.0, max(px * 0.8, 0.7), edge_in_hex(g, hx));
	col = mix(col, col * 0.74, line * (1.0 - smoothstep(4.0, 9.0, px)) * 0.9);
	return col;
}

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec3 cam = INV_VIEW_MATRIX[3].xyz;
	vec3 dir = wpos - cam;
	float t = (ground_y - cam.y) / min(dir.y, -0.0001);
	vec2 g = (cam + dir * t).xz * hex_px; // ground point (world px) behind this pixel
	// soft, cloudy edges: average a few noise-wobbled lookups
	vec2 wob = (vec2(fbm(g * 0.03), fbm(g * 0.03 + 41.0)) - 0.5) * 30.0;
	float hsum = 0.0;
	hsum += hidden_at(g + wob);
	hsum += hidden_at(g + wob + vec2(7.0, 4.0));
	hsum += hidden_at(g + wob + vec2(-6.0, 5.0));
	hsum += hidden_at(g + wob + vec2(1.0, -8.0));
	float a = smoothstep(0.2, 0.95, hsum * 0.25);
	// parchment clouds: paper base, painted swirls, darker rims at the edge
	float n = fbm(g * 0.012);
	float sw = fbm(g * 0.03 + vec2(n * 3.0));
	vec3 paper = mix(vec3(0.70, 0.63, 0.48), vec3(0.84, 0.78, 0.63), n);
	paper = mix(paper, vec3(0.92, 0.88, 0.76), smoothstep(0.55, 0.75, sw) * 0.6);
	paper = mix(paper, vec3(0.50, 0.43, 0.32), smoothstep(0.48, 0.5, sw) * (1.0 - smoothstep(0.5, 0.53, sw)) * 0.35);
	paper *= 0.92 + 0.08 * hash(floor(g * 0.5));
	float rim = 1.0 - smoothstep(0.2, 0.75, a);
	paper = mix(paper, paper * 0.62, rim);

	// Seen before, not in sight now (designed maps): flat paper ground + the real scenery recoloured to ink.
	float e = 0.0;
	vec3 under = vec3(0.0);
	if (explored_blur > 0.5) {
		float depth = textureLod(depth_tex, SCREEN_UV, 0.0).r;
		vec4 vv = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth, 1.0);
		vec3 sp = (INV_VIEW_MATRIX * vec4(vv.xyz / vv.w, 1.0)).xyz;       // world position of what is drawn here
		float obj_t = terr_h(hex_of(sp.xz * hex_px));
		bool bridge_hex = obj_t > 5.5 && obj_t < 6.5;
		float obj_h = bridge_hex ? 0.2 : OBJ_H;   // bridge decks sit low; the earth ramp under them stays ground
		bool is_obj = depth > 0.00001 && sp.y > obj_h;
		vec2 eg = is_obj ? sp.xz * hex_px : g;                           // scenery follows ITS OWN hex, not the ground behind it
		float esum = 0.0;
		esum += explored_at(eg + wob);
		esum += explored_at(eg + wob + vec2(7.0, 4.0));
		esum += explored_at(eg + wob + vec2(-6.0, 5.0));
		esum += explored_at(eg + wob + vec2(1.0, -8.0));
		e = smoothstep(0.1, 0.9, esum * 0.25);
		if (e > 0.001) {
			if (is_obj) {
				vec3 live = textureLod(screen_tex, SCREEN_UV, 0.0).rgb;
				float l = clamp((dot(live, vec3(0.3, 0.59, 0.11)) - 0.04) / 0.62, 0.0, 1.0);
				under = mix(INK_DARK, INK_LIGHT, bridge_hex ? l * 0.55 : l);   // bridges read as darker ink
			} else {
				under = old_map(g, n, fwidth(g.x) + fwidth(g.y));
			}
		}
	}
	float alpha = max(a, e);
	if (alpha <= 0.001) discard;
	ALBEDO = mix(under, paper, a / alpha);
	ALPHA = alpha;
}
