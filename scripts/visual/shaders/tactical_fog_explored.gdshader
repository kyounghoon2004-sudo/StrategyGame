shader_type canvas_item;
render_mode unshaded;

// TACTICAL OBSCURITY, explored-but-not-visible hexes (VISUAL ONLY, HIGH /
// FLAT board). Remembered ground under a cool, flat memory tint - now with the
// memory read: the ground seen before is soft (blurred), drained of colour and
// a little darker. Static on purpose: no TIME, no noise, no drifting clouds.
// The blur samples the already-drawn terrain, so it costs one 5-tap fetch per
// pixel of fogged hex and nothing at all on visible ground.

uniform vec4 memory_tint : source_color = vec4(0.575, 0.625, 0.71, 0.47);
uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform float blur_radius : hint_range(0.0, 8.0) = 2.6;
uniform float blur_mix : hint_range(0.0, 1.0) = 0.65;
uniform float desaturate : hint_range(0.0, 1.0) = 0.55;
uniform float darken : hint_range(0.0, 1.0) = 0.16;
uniform float tint_mix : hint_range(0.0, 1.0) = 0.30;

void fragment() {
	vec2 px = SCREEN_PIXEL_SIZE * blur_radius;
	vec3 sharp = texture(screen_tex, SCREEN_UV).rgb;
	vec3 soft = sharp * 0.36;
	soft += texture(screen_tex, SCREEN_UV + vec2(px.x, 0.0)).rgb * 0.16;
	soft += texture(screen_tex, SCREEN_UV - vec2(px.x, 0.0)).rgb * 0.16;
	soft += texture(screen_tex, SCREEN_UV + vec2(0.0, px.y)).rgb * 0.16;
	soft += texture(screen_tex, SCREEN_UV - vec2(0.0, px.y)).rgb * 0.16;
	vec3 c = mix(sharp, soft, blur_mix);
	float l = dot(c, vec3(0.299, 0.587, 0.114));
	c = mix(c, vec3(l), desaturate);
	c = mix(c, memory_tint.rgb, tint_mix);
	c *= (1.0 - darken);
	COLOR = vec4(c, COLOR.a);
}
