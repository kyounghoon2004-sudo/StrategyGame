shader_type spatial;
// Unit hex base (VISUAL ONLY): flat translucent fill + crisp rim in faction
// colour, marking exactly the one hex the unit occupies.
render_mode unshaded, cull_disabled, blend_mix, depth_draw_never;
uniform vec3 base_color : source_color = vec3(0.3, 0.55, 1.0);
uniform float fill_alpha = 0.14;
uniform float rim_alpha = 0.9;
void fragment() {
	float rim = step(0.5, UV.x);
	ALBEDO = base_color * mix(0.9, 1.25, rim);
	ALPHA = mix(fill_alpha, rim_alpha, rim);
}
