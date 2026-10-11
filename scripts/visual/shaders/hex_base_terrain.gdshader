// res://scripts/visual/shaders/hex_base_terrain.gdshader
shader_type canvas_item;
render_mode unshaded;

uniform sampler2D terrain_texture : filter_linear, repeat_enable;
uniform vec4 base_tint : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform vec4 background_earth : source_color = vec4(0.702, 0.631, 0.482, 1.0); // #b3a17b parchment tone

void fragment() {
	vec4 tex = texture(terrain_texture, UV);
	// Blend sampled texture over solid background earth tone,
	// then apply per-hex ownership tint from vertex color (Phase 3).
	vec3 blended_rgb = mix(background_earth.rgb, tex.rgb * base_tint.rgb, tex.a);
	COLOR = vec4(blended_rgb * COLOR.rgb, 1.0);
}
