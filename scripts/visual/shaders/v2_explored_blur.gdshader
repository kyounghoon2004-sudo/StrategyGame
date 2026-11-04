shader_type canvas_item;
render_mode unshaded;

// 시야 밖(탐사 완료) 지역의 "기억" 처리: 완전한 안개가 아니라, 이미 그려진 화면을
// 흐리게(defocus) 만들고 채도를 살짝 빼서 읽히되 선명하지 않게 만든다.
// 완전 안개(unexplored)는 civ_shroud가 담당하고, 이 셰이더는 그 사이 단계만 맡는다.
uniform sampler2D screen_tex : hint_screen_texture, filter_linear;
uniform float blur_radius : hint_range(0.0, 16.0) = 8.0;
uniform float desaturate : hint_range(0.0, 1.0) = 0.0;
uniform float dim : hint_range(0.0, 0.4) = 0.0;

void fragment() {
	vec2 px = SCREEN_PIXEL_SIZE * blur_radius;
	vec3 c = texture(screen_tex, SCREEN_UV).rgb * 0.32;
	c += texture(screen_tex, SCREEN_UV + vec2(px.x, 0.0)).rgb * 0.17;
	c += texture(screen_tex, SCREEN_UV - vec2(px.x, 0.0)).rgb * 0.17;
	c += texture(screen_tex, SCREEN_UV + vec2(0.0, px.y)).rgb * 0.17;
	c += texture(screen_tex, SCREEN_UV - vec2(0.0, px.y)).rgb * 0.17;
	float l = dot(c, vec3(0.299, 0.587, 0.114));
	c = mix(c, vec3(l), desaturate) * (1.0 - dim);
	COLOR = vec4(c, COLOR.a);
}
