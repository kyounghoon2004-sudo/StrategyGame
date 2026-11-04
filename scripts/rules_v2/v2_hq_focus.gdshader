shader_type canvas_item;
// Rules V2 "HQ focus": while an HQ is selected the battlefield render underneath is blurred and
// muted, so ground, roads and buildings become soft backing and the units (badges draw above this
// layer) stay instantly readable. No mask here: the three zone bands are hex polygons drawn by
// V2Overlay, so they line up with the board hexes exactly at any zoom.

uniform sampler2D screen_tex : hint_screen_texture, filter_linear;
uniform float radius_px = 2.0;   // blur radius in screen pixels
uniform float desat = 0.35;      // 1 = fully grey backing
uniform float dim = 0.08;        // darkening, 0 = none
uniform float strength = 0.0;    // 0 = off (bit-identical to no overlay), 1 = on

const vec2 DIRS[8] = vec2[8](
	vec2(1.0, 0.0), vec2(-1.0, 0.0), vec2(0.0, 1.0), vec2(0.0, -1.0),
	vec2(0.7071, 0.7071), vec2(-0.7071, 0.7071), vec2(0.7071, -0.7071), vec2(-0.7071, -0.7071));

void fragment() {
	vec3 base = texture(screen_tex, SCREEN_UV).rgb;
	vec2 step_px = SCREEN_PIXEL_SIZE * radius_px;
	vec3 acc = base * 4.0;
	float wsum = 4.0;
	for (int i = 0; i < 8; i++) {
		acc += texture(screen_tex, SCREEN_UV + DIRS[i] * step_px).rgb * 2.0;
		wsum += 2.0;
	}
	vec3 blurred = acc / wsum;
	float lum = dot(blurred, vec3(0.299, 0.587, 0.114));
	vec3 backing = mix(vec3(lum), blurred, 1.0 - desat) * (1.0 - dim);
	COLOR = vec4(mix(base, backing, strength), 1.0);
}
