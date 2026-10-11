shader_type canvas_item;
render_mode unshaded;

// TACTICAL OBSCURITY, explored-but-not-visible hexes (VISUAL ONLY, HIGH /
// FLAT board). Remembered ground under a cool, flat memory tint. Static on
// purpose: no TIME, no noise (the CLOSEUP view uses the same idea as a
// desaturated memory tone in closeup_common.gdshaderinc).

uniform vec4 memory_tint : source_color = vec4(0.575, 0.625, 0.71, 0.47);

void fragment() {
	COLOR = vec4(memory_tint.rgb, memory_tint.a * COLOR.a);
}
