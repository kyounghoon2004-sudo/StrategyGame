shader_type spatial;
// CIV3D contact shadow under each soldier (VISUAL ONLY): a soft dark ellipse.
render_mode unshaded, cull_disabled, depth_draw_never, shadows_disabled, blend_mix, depth_test_disabled;

uniform float strength = 0.38;

void fragment() {
	float d = length(UV - vec2(0.5)) * 2.0;
	ALBEDO = vec3(0.06, 0.06, 0.04);
	ALPHA = strength * (1.0 - smoothstep(0.35, 1.0, d));
}
