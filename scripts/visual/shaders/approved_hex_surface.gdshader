shader_type canvas_item;
render_mode unshaded;
uniform sampler2D art : source_color, filter_linear_mipmap, repeat_disable;
uniform vec4 content_uv;

// Presentation grade (VISUAL ONLY). Pulls the ground toward a calmer, earthier
// palette so unit silhouettes separate from it, and adds low-frequency
// world-space tonal breakup (patches ~10 hexes wide) so the per-hex texture
// does not read as a repeated tile. Frequency is far below hex size, so hex
// edges and per-hex terrain identity are unaffected.
uniform float grade_desaturate = 0.24;
uniform vec3 grade_tint = vec3(1.03, 0.99, 0.88);
uniform float grade_gain = 0.93;
uniform float breakup_strength = 0.085;
uniform float breakup_scale = 0.0024;
uniform float detail_mix = 1.0;
uniform float grain_strength = 0.0;

varying vec2 world_pos;

float hash21(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash21(i), hash21(i + vec2(1.0, 0.0)), u.x),
			mix(hash21(i + vec2(0.0, 1.0)), hash21(i + vec2(1.0, 1.0)), u.x), u.y);
}

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
}

void fragment() {
	vec2 local_uv = clamp(UV, vec2(0.0), vec2(1.0));
	vec4 pigment = texture(art, content_uv.xy + local_uv * content_uv.zw);
	vec3 center = texture(art, content_uv.xy + content_uv.zw * 0.5).rgb;
	// Open-ground materials keep only part of the per-hex painted pattern
	// (its interior-light / rim-dark vignette made every hex a "bubble") and
	// gain continuous world-space grass grain instead: one coherent surface,
	// hex identity carried by the grid lines. Roads/banks keep full detail.
	vec3 col = mix(center, pigment.rgb, pigment.a * detail_mix) * COLOR.rgb;
	float grain = value_noise(world_pos * 0.42) * 0.55 + value_noise(world_pos * 0.13 + vec2(9.0, 4.0)) * 0.45;
	col *= 1.0 + (grain - 0.5) * grain_strength;
	float luma = dot(col, vec3(0.299, 0.587, 0.114));
	col = mix(col, vec3(luma), grade_desaturate);
	float n = value_noise(world_pos * breakup_scale) * 0.65 + value_noise(world_pos * breakup_scale * 2.7 + vec2(17.0, 5.0)) * 0.35;
	col *= grade_tint * grade_gain * (1.0 + (n - 0.5) * 2.0 * breakup_strength);
	// Drier, sun-warmed patches on the high end of the breakup field.
	col = mix(col, col * vec3(1.05, 1.0, 0.84), smoothstep(0.55, 0.85, n) * 0.55);
	// Separate meadow field: lush green hollows vs straw-yellow dry rises,
	// like the reference's natural ground variety (still far below hex scale).
	float m = value_noise(world_pos * 0.0017 + vec2(41.0, 9.0)) * 0.7 + value_noise(world_pos * 0.0051 + vec2(3.0, 77.0)) * 0.3;
	col = mix(col, col * vec3(0.90, 1.05, 0.88), smoothstep(0.58, 0.82, m) * 0.6);
	col = mix(col, col * vec3(1.12, 1.04, 0.80), smoothstep(0.40, 0.18, m) * 0.5);
	COLOR = vec4(col, 1.0);
}
