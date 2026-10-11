shader_type spatial;
// CLOSEUP ground (VISUAL ONLY): a FLAT painted hex board. No heightfield, no
// lighting: flat pixel-art colour bands per terrain, chunky world-space
// pixels, roads / rivers as bands between linked hex centres, a clear hex
// grid, the 2D board's gameplay overlays, unit-hex tints and the tactical
// obscurity mask (fog of war + horizon).
render_mode unshaded, cull_disabled, depth_draw_opaque;

#include "res://scripts/visual/closeup25d/closeup_common.gdshaderinc"

uniform sampler2D overlay_tex : filter_linear;
uniform vec2 overlay_origin = vec2(-1500.0, -1750.0);
uniform vec2 overlay_size = vec2(3000.0, 3500.0);
uniform float grid_strength = 0.34;
uniform vec2 hover_hex = vec2(9999.0);
uniform vec2 select_hex = vec2(9999.0);
uniform float select_pulse = 1.0;
// Anchor hex of each stronghold: the one hex its card stands on.
uniform vec2 anchor_a = vec2(9999.0);
uniform vec2 anchor_b = vec2(9999.0);

varying vec3 wpos;

const float PIX = 2.0; // world px per art pixel (keeps ground pixels at unit-art density)
const vec2 NEB[6] = { vec2(1.0, 0.0), vec2(1.0, -1.0), vec2(0.0, -1.0), vec2(-1.0, 0.0), vec2(-1.0, 1.0), vec2(0.0, 1.0) };

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float vnoise(vec2 p) {
	vec2 i = floor(p); vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1, 0)), u.x), mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), u.x), u.y);
}

// distance (world px) from wp to the border of hex h (positive inside)
float hex_edge_dist(vec2 wp, vec2 h) {
	vec2 p = wp - cu_hex_center_wp(h);
	p.y *= 41.569 / 42.0;
	p = abs(p);
	return 20.785 - max(p.y, dot(p, vec2(0.8660254, 0.5)));
}

float seg_dist(vec2 p, vec2 a, vec2 b) {
	vec2 pa = p - a; vec2 ba = b - a;
	return length(pa - ba * clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0));
}

bool road_like(float t) { return t > 4.5 && t < 6.5 || t > 8.5 && t < 9.5 || t > 10.5 && t < 11.5; }

// 3-band flat palette pick (pixel art: no gradients)
vec3 band(vec3 a, vec3 b, vec3 c, float n) { return n < 0.36 ? a : (n < 0.72 ? b : c); }

vec3 terrain_color(float t, vec2 cp, bool anchor) {
	float n = vnoise(cp * 0.09) * 0.65 + hash(cp) * 0.35;
	vec3 grass = band(vec3(0.33, 0.45, 0.22), vec3(0.38, 0.51, 0.25), vec3(0.44, 0.56, 0.29), n);
	if (t < 0.5) return grass;
	if (t < 1.5) return band(vec3(0.42, 0.38, 0.30), vec3(0.48, 0.44, 0.35), vec3(0.54, 0.50, 0.40), n); // mountain foot
	if (t < 2.5) return band(vec3(0.20, 0.28, 0.16), vec3(0.24, 0.33, 0.18), vec3(0.29, 0.37, 0.20), n);  // forest floor
	if (t < 3.5) return band(vec3(0.27, 0.33, 0.22), vec3(0.24, 0.32, 0.29), vec3(0.32, 0.38, 0.26), n);  // swamp
	if (t < 4.5 || t > 7.5 && t < 12.5) {
		// stronghold: the anchor hex is paved; the rest of the logical
		// footprint reads as a stone apron (never as open ground)
		vec3 pave = band(vec3(0.50, 0.47, 0.41), vec3(0.56, 0.53, 0.46), vec3(0.61, 0.58, 0.51), n);
		return anchor ? pave : mix(grass, pave * 0.85, 0.55);
	}
	if (t < 5.5) return band(vec3(0.46, 0.44, 0.28), vec3(0.50, 0.47, 0.30), vec3(0.54, 0.51, 0.33), n);  // village yards
	if (t < 6.5) return grass;                                                                              // road hex (band drawn below)
	if (t < 7.5) return band(vec3(0.31, 0.40, 0.22), vec3(0.35, 0.44, 0.24), vec3(0.39, 0.47, 0.27), n); // river banks
	// outer mountains
	return band(vec3(0.24, 0.29, 0.20), vec3(0.28, 0.33, 0.22), vec3(0.32, 0.36, 0.25), n);
}

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

uniform bool assets_ground = false;

void fragment() {
	vec2 xz = wpos.xz;
	vec2 wp = xz * hex_px;
	vec2 cp = floor(wp / PIX);          // chunky art pixel
	vec2 wq = (cp + 0.5) * PIX;          // pixel-snapped world px
	vec2 hx = cu_hex_of(wq / hex_px);
	vec4 c = cu_cell(hx);
	float terr = floor(c.r * 255.0 + 0.5);
	bool anchor = distance(hx, anchor_a) < 0.1 || distance(hx, anchor_b) < 0.1;
	vec3 col = terrain_color(terr, cp, anchor);

	// roads / rivers: bands from this hex centre toward linked neighbours
	bool water = terr > 6.5 && terr < 7.5;
	if (road_like(terr) || water) {
		vec2 ctr = cu_hex_center_wp(hx);
		float dmin = 1e9;
		bool any = false;
		for (int k = 0; k < 6; k++) {
			vec2 d = NEB[k];
			float nt = floor(cu_cell(hx + d).r * 255.0 + 0.5);
			bool linked = water ? (nt > 6.5 && nt < 7.5) : (road_like(nt));
			if (linked) {
				any = true;
				dmin = min(dmin, seg_dist(wq, ctr, (ctr + cu_hex_center_wp(hx + d)) * 0.5));
			}
		}
		if (!any) dmin = length(wq - ctr) * 1.6;
		float wdt = water ? 13.0 : 6.0;
		if (dmin < wdt) {
			float n = hash(cp);
			vec3 rc = water ? (dmin < wdt - 3.0 ? (n < 0.8 ? vec3(0.30, 0.47, 0.60) : vec3(0.46, 0.62, 0.72)) : vec3(0.22, 0.34, 0.42))
			                : (dmin < wdt - 2.0 ? (n < 0.7 ? vec3(0.62, 0.53, 0.38) : vec3(0.56, 0.47, 0.33)) : vec3(0.46, 0.39, 0.27));
			col = rc;
		}
	}

	float edge = hex_edge_dist(wp, hx);
	float playable = c.a;

	// unit hex tint (faction)
	float uf = floor(c.b * 255.0 + 0.5);
	if (uf > 0.5) {
		vec3 fc = uf < 1.5 ? vec3(0.30, 0.52, 1.0) : vec3(1.0, 0.34, 0.26);
		col = mix(col, fc, 0.16);
	}
	// hex grid (map-like, stays faintly visible inside the obscurity)
	float px = fwidth(wp.x) + fwidth(wp.y);
	float line = 1.0 - smoothstep(0.0, max(px * 0.9, 0.8), edge);

	// tactical obscurity: fog-of-war state
	float fstate = c.g; // 0 unexplored, 0.5 explored, 1 visible
	if (playable > 0.5 && fstate < 0.75) {
		if (fstate > 0.25) {
			col = cu_memory(col);
		} else {
			// unknown: flat ink with a sparse static map hatch
			float hatch = step(0.82, fract((wp.x + wp.y) / 9.0));
			col = ink + vec3(0.025) * hatch;
		}
	}
	col = mix(col, vec3(0.90, 0.92, 0.84), line * grid_strength * playable * (fstate < 0.25 ? 0.35 : 1.0));

	// gameplay overlay rendered from the 2D board (orders stay readable over fog)
	vec2 ouv = (wp - overlay_origin) / overlay_size;
	if (ouv.x > 0.0 && ouv.y > 0.0 && ouv.x < 1.0 && ouv.y < 1.0) {
		vec4 o = texture(overlay_tex, ouv);
		col = mix(col, o.rgb, clamp(o.a, 0.0, 1.0));
	}

	// hover + selected outlines
	float glow = 1.0 - smoothstep(0.0, max(px * 1.6, 2.2), edge);
	if (distance(hx, hover_hex) < 0.1) { col = mix(col, vec3(1.0, 0.96, 0.75), glow * 0.9); }
	if (distance(hx, select_hex) < 0.1) {
		col = mix(col, vec3(1.0, 0.82, 0.35), glow * select_pulse);
		col = mix(col, vec3(1.0, 0.85, 0.45), (1.0 - smoothstep(0.0, 7.0, edge)) * 0.22);
	}

	// horizon obscurity: the closeup only reaches so far
	float dm = cu_distance_mask(xz);
	if (playable < 0.5) dm = max(dm, 0.55);
	ALBEDO = mix(col, ink, dm);
	if (assets_ground) {
		vec4 overlay = texture(overlay_tex, ouv);
		float selected = distance(hx, select_hex) < 0.1 ? glow * select_pulse : 0.0;
		float hovered = distance(hx, hover_hex) < 0.1 ? glow * 0.9 : 0.0;
		float outline = max(selected, hovered);
		ALBEDO = mix(overlay.rgb, vec3(1.0, 0.82, 0.35), outline);
		ALPHA = max(overlay.a, outline) * playable;
	}
}
