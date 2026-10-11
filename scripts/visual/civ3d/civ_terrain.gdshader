shader_type spatial;
// CIV3D ground (VISUAL ONLY): lit painterly heightfield. Terrain colour per
// hex with soft, noise-wobbled transitions; rock on steep slopes; roads and
// rivers as bands between linked hex centres; a faint Civ-style hex grid;
// explored-but-unseen hexes as a sepia "old map"; the 2D board's gameplay
// overlays draped on top; hover / selection outlines.
render_mode cull_disabled, depth_draw_opaque, diffuse_burley, specular_disabled;

uniform sampler2D cell_tex : filter_nearest; // R terrain, G fog, B unit, A playable
uniform float hex_px = 5.3333;               // world px per 3D unit
uniform sampler2D overlay_tex : filter_linear;
uniform vec2 overlay_origin = vec2(-1500.0, -1750.0);
uniform vec2 overlay_size = vec2(3000.0, 3500.0);
uniform float grid_strength = 0.22;
uniform vec2 hover_hex = vec2(9999.0);
uniform vec2 select_hex = vec2(9999.0);
uniform float select_pulse = 1.0;

varying vec3 wpos;
varying vec3 wnorm;

const vec2 NEB[6] = { vec2(1.0, 0.0), vec2(1.0, -1.0), vec2(0.0, -1.0), vec2(-1.0, 0.0), vec2(-1.0, 1.0), vec2(0.0, 1.0) };

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float vnoise(vec2 p) {
	vec2 i = floor(p); vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1, 0)), u.x), mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), u.x), u.y);
}
float fbm(vec2 p) {
	float a = 0.5; float s = 0.0;
	for (int i = 0; i < 4; i++) { s += a * vnoise(p); p = p * 2.03 + vec2(17.1, 9.2); a *= 0.5; }
	return s;
}

vec2 axial_frac(vec2 wp) {
	float qf = wp.x / 36.0;
	return vec2(qf, (wp.y - qf * 21.0) / 42.0);
}
vec2 axial_round(vec2 f) {
	float q = f.x; float r = f.y; float s = -q - r;
	float rq = round(q); float rr = round(r); float rs = round(s);
	float dq = abs(rq - q); float dr = abs(rr - r); float ds = abs(rs - s);
	if (dq > dr && dq > ds) { rq = -rr - rs; } else if (dr > ds) { rr = -rq - rs; }
	return vec2(rq, rr);
}
vec2 hex_of_wp(vec2 wp) { return axial_round(axial_frac(wp)); }
vec4 cell(vec2 h) { return textureLod(cell_tex, (h + vec2(85.5)) / 171.0, 0.0); }
float terr_of(vec2 h) { return floor(cell(h).r * 255.0 + 0.5); }
vec2 hex_center_wp(vec2 h) { return vec2(h.x * 36.0, h.y * 42.0 + h.x * 21.0); }

// distance (world px) from wp to the border of hex h (positive inside)
float hex_edge_dist(vec2 wp, vec2 h) {
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

// Restrained historical palette (TREE standard), painterly variation.
vec3 terrain_color(float t, vec2 wp) {
	float n = fbm(wp * 0.035);
	float m = vnoise(wp * 0.11);
	vec3 grass = mix(vec3(0.28, 0.35, 0.18), vec3(0.38, 0.43, 0.23), n);
	grass = mix(grass, vec3(0.45, 0.43, 0.28), smoothstep(0.62, 0.8, m) * 0.45); // dry patches
	if (t < 0.5) return grass;
	if (t < 1.5) return mix(vec3(0.44, 0.40, 0.32), vec3(0.56, 0.52, 0.43), n);                // mountain foot
	if (t < 2.5) { // forest floor: dark moss with needle / leaf litter patches
		vec3 moss = mix(vec3(0.13, 0.19, 0.10), vec3(0.20, 0.26, 0.13), n);
		return mix(moss, vec3(0.29, 0.23, 0.14), smoothstep(0.55, 0.75, m) * 0.6);
	}
	if (t < 3.5) return mix(vec3(0.30, 0.36, 0.24), vec3(0.26, 0.34, 0.30), m);                // swamp
	if (t < 4.5 || t > 7.5 && t < 12.5) return mix(vec3(0.50, 0.46, 0.39), vec3(0.60, 0.56, 0.48), n); // paved
	if (t < 5.5) return mix(vec3(0.48, 0.44, 0.30), vec3(0.55, 0.50, 0.34), n);                // village yards
	if (t < 6.5) return grass;                                                                    // road (band below)
	if (t < 7.5) return mix(vec3(0.33, 0.41, 0.24), vec3(0.40, 0.46, 0.28), n);                // river banks
	return mix(vec3(0.30, 0.33, 0.24), vec3(0.38, 0.38, 0.29), n);                              // outer country
}

vec3 sepia(vec3 c) {
	float l = dot(c, vec3(0.3, 0.59, 0.11));
	return mix(c, vec3(l) * vec3(1.08, 0.94, 0.72), 0.82) * 0.86;
}

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wnorm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	vec2 wp = wpos.xz * hex_px;
	vec2 hx = hex_of_wp(wp);
	vec4 c = cell(hx);
	float terr = floor(c.r * 255.0 + 0.5);
	// Soft terrain transitions: colour from a noise-wobbled lookup.
	vec2 wob = (vec2(fbm(wp * 0.06), fbm(wp * 0.06 + 31.7)) - 0.5) * 14.0;
	float tcol = terr_of(hex_of_wp(wp + wob));
	vec3 col = terrain_color(tcol, wp);

	// steep slopes read as rock
	float steep = 1.0 - wnorm.y;
	vec3 rock = mix(vec3(0.42, 0.40, 0.36), vec3(0.55, 0.52, 0.47), vnoise(wp * 0.2));
	col = mix(col, rock, smoothstep(0.12, 0.3, steep));

	// roads / rivers: bands from this hex centre toward linked neighbours
	bool water = terr > 6.5 && terr < 7.5;
	if (road_like(terr) || water) {
		vec2 ctr = hex_center_wp(hx);
		float dmin = 1e9;
		bool any = false;
		for (int k = 0; k < 6; k++) {
			float nt = terr_of(hx + NEB[k]);
			bool linked = water ? (nt > 6.5 && nt < 7.5) : road_like(nt);
			if (linked) {
				any = true;
				dmin = min(dmin, seg_dist(wp, ctr, (ctr + hex_center_wp(hx + NEB[k])) * 0.5));
			}
		}
		if (!any) dmin = length(wp - ctr) * 1.6;
		dmin += (vnoise(wp * 0.15) - 0.5) * 3.0;
		if (water) {
			vec3 wc = mix(vec3(0.24, 0.36, 0.42), vec3(0.36, 0.50, 0.56), vnoise(wp * 0.08));
			col = mix(col, vec3(0.38, 0.36, 0.28), 1.0 - smoothstep(13.0, 15.5, dmin)); // muddy bank
			col = mix(col, wc, 1.0 - smoothstep(10.0, 12.0, dmin));
		} else {
			vec3 rc = mix(vec3(0.58, 0.50, 0.37), vec3(0.66, 0.58, 0.43), vnoise(wp * 0.3));
			col = mix(col, rc * 0.85, 1.0 - smoothstep(5.5, 7.0, dmin));
			col = mix(col, rc, 1.0 - smoothstep(4.0, 5.5, dmin));
		}
	}

	float playable = c.a;
	float fstate = c.g; // 0 unexplored, 0.5 explored, 1 visible
	float edge = hex_edge_dist(wp, hx);
	float px = fwidth(wp.x) + fwidth(wp.y);


	// Civ-style hex grid: thin, dark, fading out at strategic zoom
	float line = 1.0 - smoothstep(0.0, max(px * 0.8, 0.7), edge);
	col = mix(col, col * 0.55, line * grid_strength * playable * (1.0 - smoothstep(4.0, 9.0, px)));

	if (playable > 0.5 && fstate < 0.75) col = sepia(col);
	if (playable < 0.5) col = sepia(col) * 0.9;

	// gameplay overlay rendered from the 2D board
	vec2 ouv = (wp - overlay_origin) / overlay_size;
	if (ouv.x > 0.0 && ouv.y > 0.0 && ouv.x < 1.0 && ouv.y < 1.0) {
		vec4 o = texture(overlay_tex, ouv);
		col = mix(col, o.rgb, clamp(o.a, 0.0, 1.0));
	}

	float glow = 1.0 - smoothstep(0.0, max(px * 1.6, 1.8), edge);
	vec3 emit = vec3(0.0);
	if (distance(hx, hover_hex) < 0.1) { col = mix(col, vec3(1.0, 0.96, 0.78), glow * 0.85); emit += vec3(0.25, 0.24, 0.18) * glow; }
	if (distance(hx, select_hex) < 0.1) {
		col = mix(col, vec3(1.0, 0.82, 0.35), glow * select_pulse);
		col = mix(col, vec3(1.0, 0.85, 0.45), (1.0 - smoothstep(0.0, 7.0, edge)) * 0.2);
		emit += vec3(0.35, 0.26, 0.08) * glow * select_pulse;
	}
	ALBEDO = col;
	EMISSION = emit;
	ROUGHNESS = 0.95;
}
