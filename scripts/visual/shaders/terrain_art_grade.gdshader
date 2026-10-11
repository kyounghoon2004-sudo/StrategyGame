shader_type canvas_item;

// Presentation grade for upright terrain art (trees / peaks). VISUAL ONLY.
// Matches approved_hex_surface's calmer, earthier ground grade so forests stop
// reading neon and unit silhouettes separate from them. Alpha is untouched,
// so sprite footprints / occupancy are unchanged.
uniform float grade_desaturate = 0.30;
uniform vec3 grade_tint = vec3(1.0, 0.97, 0.86);
uniform float grade_gain = 0.90;

void fragment() {
	vec4 c = texture(TEXTURE, UV) * COLOR;
	float luma = dot(c.rgb, vec3(0.299, 0.587, 0.114));
	c.rgb = mix(c.rgb, vec3(luma), grade_desaturate) * grade_tint * grade_gain;
	COLOR = c;
}
