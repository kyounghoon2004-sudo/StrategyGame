shader_type spatial;
render_mode cull_disabled;

uniform float flow_clock = 0.0;

// Opaque water with two sparse, thin, curved white strokes per repeat.
// Longitudinal UV uses physical distance along the shared river strip.
void fragment() {
	float phase = mod(UV.y - flow_clock * 8.0, 180.0);
	float center_a = 0.35 + sin(UV.y * 0.19) * 0.045;
	float center_b = 0.65 + sin(UV.y * 0.16 + 1.7) * 0.035;
	float aa = max(fwidth(UV.x), 0.002);
	float a = 1.0 - smoothstep(0.005, 0.005 + aa, abs(UV.x - center_a));
	float b = 1.0 - smoothstep(0.006, 0.006 + aa, abs(UV.x - center_b));
	a *= smoothstep(0.0, 2.0, phase) * (1.0 - smoothstep(9.0, 13.0, phase));
	b *= smoothstep(87.0, 89.0, phase) * (1.0 - smoothstep(97.0, 101.0, phase));
	ALBEDO = mix(COLOR.rgb, vec3(0.88, 0.95, 0.91), max(a, b) * 0.65);
	ROUGHNESS = 0.63;
}
