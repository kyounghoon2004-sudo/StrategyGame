// Shared CLOSEUP 2.5D helpers (VISUAL ONLY): hex maths in closeup units,
// the live cell texture lookup and the tactical-obscurity mask.
//
// Obscurity is ONE ink tone used for every kind of "you cannot see this":
// unexplored hexes, the horizon beyond the closeup's reach, and the sky.
// It is static (no drift, no noise animation): a map's unknown space, not
// weather.

uniform sampler2D cell_tex : filter_nearest; // R terrain, G fog, B unit, A playable
uniform float hex_px = 8.0;                  // world px per closeup unit (24 / HEXR)
uniform vec3 ink : source_color = vec3(0.155, 0.165, 0.19);
uniform vec2 focus_xz = vec2(0.0);           // closeup focus (friendly HQ + pan)
uniform float mask_start = 30.0;             // closeup units from focus: obscurity begins
uniform float mask_end = 58.0;               // ... and is total

vec2 cu_axial_frac(vec2 xz) {
	vec2 wp = xz * hex_px;
	float qf = wp.x / 36.0;
	return vec2(qf, (wp.y - qf * 21.0) / 42.0);
}
vec2 cu_axial_round(vec2 f) {
	float q = f.x; float r = f.y; float s = -q - r;
	float rq = round(q); float rr = round(r); float rs = round(s);
	float dq = abs(rq - q); float dr = abs(rr - r); float ds = abs(rs - s);
	if (dq > dr && dq > ds) { rq = -rr - rs; } else if (dr > ds) { rr = -rq - rs; }
	return vec2(rq, rr);
}
vec2 cu_hex_of(vec2 xz) { return cu_axial_round(cu_axial_frac(xz)); }
vec4 cu_cell(vec2 h) { return textureLod(cell_tex, (h + vec2(85.5)) / 171.0, 0.0); }
vec2 cu_hex_center_wp(vec2 h) { return vec2(h.x * 36.0, h.y * 42.0 + h.x * 21.0); }

// 0 = clear, 1 = fully inside the horizon obscurity
float cu_distance_mask(vec2 xz) {
	return smoothstep(mask_start, mask_end, distance(xz, focus_xz));
}

// Remembered-but-not-currently-seen ground: cool, desaturated, dimmed.
vec3 cu_memory(vec3 c) {
	float l = dot(c, vec3(0.3, 0.59, 0.11));
	return mix(c, vec3(l) * vec3(0.80, 0.84, 0.92), 0.7) * 0.72;
}
