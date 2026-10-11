shader_type spatial;
// CIV3D soldier (VISUAL ONLY): one native-resolution soldier per MultiMesh
// instance. The card stands on its feet, turns to face the camera around the
// vertical axis and leans part of the way toward it so the figure stays
// readable from the high strategy pitch. INSTANCE_CUSTOM re-shades the skin /
// cloth / cream / leather regions (CivSoldierVariants.random_params) so every
// soldier is an individual of the same class.
// Drawn OVER the scenery (a unit on a mountain or among trees is never buried):
// no depth test, transparent pass sorted back-to-front per unit; inside a unit
// the MultiMesh lists the back rank first (the camera never rotates).
render_mode unshaded, cull_disabled, depth_test_disabled, depth_draw_never, shadows_disabled, blend_mix;

uniform sampler2D tex : source_color, filter_linear_mipmap_anisotropic;
uniform sampler2D regions : filter_nearest;
uniform float lean = 0.5;       // 0 upright, 1 fully facing the camera
uniform float brightness = 0.93;

varying vec4 vary;

vec3 rgb2hsv(vec3 c) {
	vec4 K = vec4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
	vec4 p = mix(vec4(c.bg, K.wz), vec4(c.gb, K.xy), step(c.b, c.g));
	vec4 q = mix(vec4(p.xyw, c.r), vec4(c.r, p.yzx), step(p.x, c.r));
	float d = q.x - min(q.w, q.y);
	float e = 1.0e-10;
	return vec3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
}
vec3 hsv2rgb(vec3 c) {
	vec3 p = abs(fract(c.xxx + vec3(1.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0);
	return c.z * mix(vec3(1.0), clamp(p - 1.0, 0.0, 1.0), c.y);
}

void vertex() {
	vary = INSTANCE_CUSTOM;
	vec3 to_cam = INV_VIEW_MATRIX[2].xyz;
	vec3 right = normalize(cross(vec3(0.0, 1.0, 0.0), to_cam));
	vec3 up = normalize(mix(vec3(0.0, 1.0, 0.0), INV_VIEW_MATRIX[1].xyz, lean));
	vec3 nrm = normalize(cross(right, up));
	float sx = length(MODEL_MATRIX[0].xyz);
	float sy = length(MODEL_MATRIX[1].xyz);
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(vec4(right * sx, 0.0), vec4(up * sy, 0.0), vec4(nrm, 0.0), MODEL_MATRIX[3]);
}

void fragment() {
	vec4 c = texture(tex, UV);
	float reg = floor(texture(regions, UV).r * 255.0 + 0.5);
	vec3 hsv = rgb2hsv(c.rgb);
	float cream = floor(vary.a * 16.0) / 15.0;
	float leather = fract(vary.a * 16.0);
	if (reg > 0.5 && reg < 1.5) {
		hsv.z *= vary.r;
	} else if (reg < 2.5 && reg > 1.5) {
		hsv.z *= vary.g;
		hsv.x = fract(hsv.x + (vary.b - 0.5) * 0.05);
	} else if (reg < 3.5 && reg > 2.5) {
		hsv.x = mix(hsv.x, 0.09, step(0.01, cream));
		hsv.y = mix(hsv.y, 0.26, cream * 0.8);
		hsv.z *= 1.0 - 0.18 * cream;
	} else if (reg > 3.5) {
		hsv.z *= 0.7 + 0.58 * leather;
	}
	ALBEDO = hsv2rgb(clamp(hsv, 0.0, 1.0)) * brightness;
	ALPHA = smoothstep(0.3, 0.7, c.a);
}
