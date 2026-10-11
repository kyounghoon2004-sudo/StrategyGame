shader_type canvas_item;
render_mode unshaded;

// Presentation-only perspective re-projection of the flat battlefield board.
// Inverse-maps every screen pixel onto the pitched ground plane, samples the
// offscreen top-down render, and adds depth haze + a distant backdrop where
// the board ends. Math mirrors presentation_projection.gd exactly.

uniform sampler2D src_tex : filter_linear, repeat_disable;
uniform vec2 screen_size = vec2(1920.0, 1080.0);
uniform float pitch_sin = 0.73;
uniform float pitch_cos = 0.68;
uniform float focal = 1250.0;
uniform float lens_shift = 250.0;
uniform float gy_min = -2600.0;
uniform vec2 src_origin;
uniform vec2 src_size;
uniform sampler2D far_tex : filter_linear, repeat_disable;
uniform vec2 far_origin;
uniform vec2 far_size = vec2(1.0);
uniform float gy_split = -1000000.0;
uniform float split_blend = 70.0;
uniform float sharpen = 0.65;

uniform vec3 haze_color = vec3(0.74, 0.78, 0.80);
uniform float haze_start = 500.0;
uniform float haze_end = 2700.0;
uniform float haze_max = 0.50;
uniform vec3 sky_top = vec3(0.47, 0.62, 0.78);
uniform vec3 sky_low = vec3(0.86, 0.84, 0.76);
uniform vec3 ridge_far = vec3(0.56, 0.63, 0.68);
uniform vec3 ridge_near = vec3(0.36, 0.44, 0.40);
uniform vec3 land_far = vec3(0.50, 0.54, 0.44);
uniform vec3 sun_tint = vec3(1.06, 1.00, 0.90);
uniform float sun_strength = 0.6;

float hash11(float p) {
	return fract(sin(p * 127.1) * 43758.5453);
}
float noise1(float x) {
	float i = floor(x);
	float f = fract(x);
	float u = f * f * (3.0 - 2.0 * f);
	return mix(hash11(i), hash11(i + 1.0), u);
}
float fbm1(float x) {
	return noise1(x) * 0.55 + noise1(x * 2.13 + 7.0) * 0.28 + noise1(x * 4.7 + 3.0) * 0.17;
}

float hash21(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}
float noise2(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash21(i), hash21(i + vec2(1.0, 0.0)), u.x), mix(hash21(i + vec2(0.0, 1.0)), hash21(i + vec2(1.0, 1.0)), u.x), u.y);
}
// Woodland canopy surrounding the playable map (board-space, so it follows
// the perspective): clumped crowns with light tops and dark gaps.
vec3 outer_woods(vec2 g) {
	float n = noise2(g * 0.045) * 0.55 + noise2(g * 0.11 + 7.0) * 0.30 + noise2(g * 0.26 + 3.0) * 0.15;
	float big = noise2(g * 0.006 + 13.0);
	vec3 dark = vec3(0.17, 0.24, 0.16);
	vec3 mid = mix(vec3(0.27, 0.36, 0.22), vec3(0.34, 0.38, 0.24), big);
	vec3 lit = vec3(0.42, 0.50, 0.30);
	vec3 c = mix(dark, mid, smoothstep(0.30, 0.55, n));
	return mix(c, lit, smoothstep(0.62, 0.80, n) * 0.7);
}

// Far tier: low-resolution render of distant ground (already minified).
vec4 sample_far(vec2 g, vec2 footprint) {
	vec2 uv = (g - far_origin) / far_size;
	if (uv.x < 0.0 || uv.y < 0.0 || uv.x > 1.0 || uv.y > 1.0) {
		return vec4(0.0);
	}
	vec2 d = footprint / far_size * 0.35;
	vec4 c = texture(far_tex, uv);
	c += texture(far_tex, uv + vec2(d.x, d.y));
	c += texture(far_tex, uv + vec2(-d.x, d.y));
	c += texture(far_tex, uv + vec2(d.x, -d.y));
	c += texture(far_tex, uv + vec2(-d.x, -d.y));
	return c * 0.2;
}

vec4 sample_src(vec2 g, vec2 footprint) {
	vec2 uv = (g - src_origin) / src_size;
	if (uv.x < 0.0 || uv.y < 0.0 || uv.x > 1.0 || uv.y > 1.0) {
		return vec4(0.0);
	}
	// footprint is in BOARD px per output px; the near tier is supersampled,
	// so measure it in SOURCE px to decide how to filter (viewport textures
	// have no mipmaps).
	vec2 d = footprint / src_size; // one output pixel, in uv
	vec2 px = footprint * (vec2(textureSize(src_tex, 0)) / src_size);
	float fpx = max(px.x, px.y);
	vec4 c;
	if (fpx > 1.1) {
		// Minified (supersampled commander view, far rows): rotated-grid
		// 4-tap resolve over the output pixel -> clean, unbroken hex lines.
		c = (texture(src_tex, uv + d * vec2(0.125, 0.375)) + texture(src_tex, uv + d * vec2(-0.375, 0.125))
			+ texture(src_tex, uv + d * vec2(0.375, -0.125)) + texture(src_tex, uv + d * vec2(-0.125, -0.375))) * 0.25;
		if (fpx > 2.6) {
			c = mix(c, (texture(src_tex, uv + d * 0.45) + texture(src_tex, uv - d * 0.45)) * 0.5, 0.35);
		}
	} else {
		c = texture(src_tex, uv);
	}
	// Unsharp mask at output-pixel scale: restores edge crispness lost to the
	// re-projection resample (units, hex lines, grass). Fades on far rows.
	vec4 blur = (texture(src_tex, uv + vec2(d.x, 0.0) * 0.8) + texture(src_tex, uv - vec2(d.x, 0.0) * 0.8)
		+ texture(src_tex, uv + vec2(0.0, d.y) * 0.8) + texture(src_tex, uv - vec2(0.0, d.y) * 0.8)) * 0.25;
	float amt = sharpen * (1.0 - smoothstep(1.2, 3.0, max(footprint.x, footprint.y)));
	c.rgb = clamp(c.rgb + (c.rgb - blur.rgb) * amt, 0.0, 1.0);
	return c;
}

// Distant scenery beyond the rendered board: sky, three ridge layers and a
// dark tree line whose fringe dips just below the board's far edge (cap_y)
// so the edge dissolves. Returns rgb + coverage (a) for the fringe.
vec4 scenery(vec2 s, float cap_y) {
	float top = -screen_size.y * 0.5;
	float k = clamp((s.y - top) / max(1.0, cap_y - top), 0.0, 1.0);
	vec3 col = mix(sky_top, sky_low, pow(k, 1.4));
	// soft sun glow upper-left
	vec2 sun_p = vec2(-screen_size.x * 0.28, top + 40.0);
	col += vec3(0.10, 0.08, 0.04) * exp(-length(s - sun_p) / 260.0);
	float a = 0.0;
	// far mountain range: tall hazy blue peaks
	float r0 = cap_y - 70.0 - 190.0 * pow(fbm1(s.x * 0.0019 + 21.0), 1.6) - 40.0 * noise1(s.x * 0.011);
	// mid foothills: blue-green, rounded
	float r1 = cap_y - 40.0 - 80.0 * fbm1(s.x * 0.0036 + 11.0);
	if (s.y > r0) {
		float sh = smoothstep(r0, cap_y, s.y);
		// sunlit left faces vs shaded right faces via the ridge slope
		float slope = fbm1((s.x + 3.0) * 0.0019 + 21.0) - fbm1((s.x - 3.0) * 0.0019 + 21.0);
		vec3 rock = mix(vec3(0.52, 0.58, 0.66), vec3(0.44, 0.50, 0.58), clamp(slope * 40.0 + 0.5, 0.0, 1.0));
		col = mix(rock, mix(rock, sky_low, 0.35), sh);
		a = 1.0;
	}
	if (s.y > r1) {
		float sh = smoothstep(r1, cap_y, s.y);
		col = mix(vec3(0.40, 0.49, 0.47), vec3(0.34, 0.43, 0.38), sh);
		a = 1.0;
	}
	// near tree line: irregular clumps of rounded crowns and pines in two rows
	for (int row = 0; row < 2; row++) {
		float fr = float(row);
		float cw = 15.0 + 9.0 * fr;
		float off = fr * 7.3;
		float cell = floor((s.x + off) / cw);
		float fx = fract((s.x + off) / cw) - 0.5;
		float h = hash11(cell * 1.7 + 3.0 + fr * 11.0);
		float gap = step(0.18, fbm1(cell * 0.35 + fr * 5.0));
		float base_y = cap_y + 4.0 - fr * 10.0;
		float crown_h = gap * (10.0 + 22.0 * h + 18.0 * fbm1(s.x * 0.004 + 5.0 + fr));
		float prof = hash11(cell * 3.1 + fr) > 0.62 ? max(0.0, 1.0 - abs(fx) * 2.1) : sqrt(max(0.0, 1.0 - fx * fx * 3.6));
		float rr = base_y - crown_h * prof;
		if (s.y > rr) {
			float shade = smoothstep(rr, rr + crown_h + 1.0, s.y);
			float tex = 0.86 + 0.14 * noise1(s.x * 0.31 + s.y * 0.2);
			vec3 crown = mix(vec3(0.40, 0.50, 0.34), vec3(0.23, 0.30, 0.22), shade) * tex;
			col = mix(crown, haze_color, 0.30 - fr * 0.08);
			a = 1.0;
		}
	}
	// tree-line fringe below the board edge: coverage fades out quickly
	float fringe = cap_y + 6.0 + 10.0 * noise1(s.x * 0.12);
	if (s.y > cap_y) {
		a = s.y < fringe ? 1.0 - smoothstep(cap_y, fringe, s.y) : 0.0;
		col = mix(vec3(0.24, 0.31, 0.23), haze_color, 0.25) * (0.85 + 0.15 * noise1(s.x * 0.2));
	}
	// aerial perspective on the scenery itself
	col = mix(col, haze_color, 0.18);
	return vec4(col, a);
}

void fragment() {
	vec2 s = UV * screen_size - screen_size * 0.5;
	float syp = s.y - lens_shift;
	float den = focal * pitch_sin + syp * pitch_cos;
	float cap_t = focal / (focal - gy_min * pitch_cos);
	float cap_y = gy_min * pitch_sin * cap_t + lens_shift;
	// The distant scenery only shows above the board edge and in the thin
	// tree-line fringe just below it (<= cap_y + 16 px); deeper ground pixels
	// skip it entirely (identical output, much less ALU per frame).
	bool on_ground = den > 1.0 && s.y >= cap_y;
	vec4 sc = vec4(0.0);
	if (!on_ground || s.y < cap_y + 16.5) {
		sc = scenery(s, cap_y);
	}
	vec3 col = sc.rgb;
	if (on_ground) {
		float gy = syp * focal / den;
		float t = focal / (focal - gy * pitch_cos);
		vec2 g = vec2(s.x / t, gy);
		vec4 c = vec4(0.0);
		if (gy >= gy_min) {
			vec2 fp = vec2(1.0 / t, 1.0 / (pitch_sin * t * t));
			// Near tier above the split, far tier beyond, blended at the seam.
			if (gy >= gy_split) {
				vec4 n = sample_src(g, fp);
				float w = smoothstep(gy_split, gy_split + split_blend, gy);
				c = w >= 0.999 ? n : mix(sample_far(g, fp), n, w);
			} else {
				c = sample_far(g, fp);
			}
		}
		// Off-board woodland only where the board render is not opaque.
		vec3 ground = c.a >= 1.0 ? c.rgb / max(c.a, 0.001) : mix(outer_woods(g), c.rgb / max(c.a, 0.001), clamp(c.a, 0.0, 1.0));
		// Atmospheric perspective: the enemy side sits further away.
		float h = smoothstep(haze_start, haze_end, -gy) * haze_max;
		ground = mix(ground, haze_color, h);
		col = mix(ground, sc.rgb, sc.a);
	}
	// Soft warm key light from the upper left.
	float sun = clamp(0.5 - (UV.x - 0.2) * 0.35 - (UV.y - 0.2) * 0.25, 0.0, 1.0);
	col *= mix(vec3(1.0), sun_tint, sun * sun_strength);
	COLOR = vec4(col, 1.0);
}
