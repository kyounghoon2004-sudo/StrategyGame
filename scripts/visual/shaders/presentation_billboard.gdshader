shader_type canvas_item;
render_mode skip_vertex_transform;

// Presentation-only scenery billboards (MultiMeshInstance2D).
// Per instance: transform = T(anchor) * S(width * flip, height) (world px,
// screen-upright frame), INSTANCE_CUSTOM = atlas region (u, v, du, dv),
// instance colour = fog-memory tint.
// Quad mesh local VERTEX spans x in [-0.5, 0.5], y in [-0.5, 0.5]; upright
// items are bottom-anchored (y shifted to [-1, 0]), decals centered.
//
// The upright frame (yaw + perspective pre-stretch + convergence lean) is
// evaluated HERE from live view uniforms, so pitch / focal changes with zoom
// cost nothing on the CPU. Maths mirrors presentation_projection.gd.

uniform float yaw = 0.0;
uniform bool upright = true;
uniform bool perspective = false;
uniform vec2 board_x = vec2(1.0, 0.0);   // main canvas basis (world -> board)
uniform vec2 board_y = vec2(0.0, 1.0);
uniform vec2 board_o = vec2(0.0, 0.0);   // origin minus screen center
uniform float focal = 1200.0;
uniform float pitch_sin = 1.0;
uniform float pitch_cos = 0.0;
uniform float keep = 1.0;
uniform float presence = 1.0;
uniform float gy_min = -100000.0;
uniform float grade_desaturate = 0.12;
uniform vec3 grade_tint = vec3(1.0, 0.97, 0.86);
uniform float grade_gain = 0.97;
// Small ground dressing (tufts / flowers) fades toward the commander view,
// where it would otherwise read as dark speckle over the board.
uniform float opacity = 1.0;

varying vec4 region;
varying float ground_t;
// Fade items very close to the camera (ground magnification t): keeps the
// near foreground clear (used by the forward mist). Defaults disable it.
uniform float near_fade_start = 1000.0;
uniform float near_fade_end = 1001.0;
uniform float near_fade_floor = 0.0;

void vertex() {
	vec2 anchor = MODEL_MATRIX[3].xy;
	vec2 size = vec2(MODEL_MATRIX[0].x, MODEL_MATRIX[1].y);
	vec2 local = VERTEX;
	if (upright) {
		local.y -= 0.5;
	}
	vec2 off = local * size * (upright ? presence : 1.0);
	float st = 1.0;
	float lean = 0.0;
	ground_t = 1.0;
	if (upright && perspective) {
		vec2 g = board_x * anchor.x + board_y * anchor.y + board_o;
		float t = focal / (focal - max(g.y, gy_min) * pitch_cos);
		st = clamp(keep / (pitch_sin * t), 1.0, 14.0);
		ground_t = t;
		lean = g.x * pitch_cos * t / focal;
	}
	// M = [(1, 0), st * (-lean, 1)] in the screen-upright frame, then yaw.
	vec2 o2 = vec2(off.x - lean * st * off.y, off.y * st);
	float c = cos(yaw);
	float s = sin(yaw);
	VERTEX = anchor + vec2(c * o2.x - s * o2.y, s * o2.x + c * o2.y);
	region = INSTANCE_CUSTOM;
	UV = region.xy + UV * region.zw;
}

void fragment() {
	vec4 c = texture(TEXTURE, UV) * COLOR;
	c.a *= opacity * mix(1.0, near_fade_floor, smoothstep(near_fade_start, near_fade_end, ground_t));
	float luma = dot(c.rgb, vec3(0.299, 0.587, 0.114));
	c.rgb = mix(c.rgb, vec3(luma), grade_desaturate) * grade_tint * grade_gain;
	COLOR = c;
}
