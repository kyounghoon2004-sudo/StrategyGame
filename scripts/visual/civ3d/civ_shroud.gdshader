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
	return (c.a < 0.5 || c.g < 0.25) ? 1.0 : 0.0;
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
	if (a <= 0.001) discard;
	// parchment clouds: paper base, painted swirls, darker rims at the edge
	float n = fbm(g * 0.012);
	float sw = fbm(g * 0.03 + vec2(n * 3.0));
	vec3 paper = mix(vec3(0.70, 0.63, 0.48), vec3(0.84, 0.78, 0.63), n);
	paper = mix(paper, vec3(0.92, 0.88, 0.76), smoothstep(0.55, 0.75, sw) * 0.6);
	paper = mix(paper, vec3(0.50, 0.43, 0.32), smoothstep(0.48, 0.5, sw) * (1.0 - smoothstep(0.5, 0.53, sw)) * 0.35);
	paper *= 0.92 + 0.08 * hash(floor(g * 0.5));
	float rim = 1.0 - smoothstep(0.2, 0.75, a);
	paper = mix(paper, paper * 0.62, rim);
	ALBEDO = paper;
	ALPHA = a;
}
