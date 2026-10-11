shader_type spatial;
// CIV3D 3D soldier skin (VISUAL ONLY): the supplied soldier texture, lit by the
// map sun. The red faction cloth is re-dyed for blue, and every soldier gets
// his own cloth / skin shade through per-instance uniforms.
render_mode diffuse_burley, specular_schlick_ggx;

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic;
uniform float faction_hue = 0.0;     // 0 = keep red, else target hue (blue ~0.60)
uniform float drab = 0.0;            // militia: undyed, worn cloth (0..1)
instance uniform float cloth_v = 1.0;
instance uniform float skin_v = 1.0;

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

void fragment() {
	vec3 c = texture(albedo_tex, UV).rgb;
	vec3 hsv = rgb2hsv(c);
	bool cloth = hsv.y > 0.38 && (hsv.x < 0.035 || hsv.x > 0.94);
	bool skin = !cloth && hsv.x > 0.03 && hsv.x < 0.11 && hsv.y > 0.2 && hsv.y < 0.6 && hsv.z > 0.45;
	if (cloth) {
		if (faction_hue > 0.0) { hsv.x = faction_hue; hsv.y *= 0.85; hsv.z *= 0.95; }
		hsv.z *= cloth_v;
	} else if (skin) {
		hsv.z *= skin_v;
	}
	if (!skin) {
		hsv.y *= 1.0 - 0.55 * drab;
		hsv.z *= 1.0 - 0.12 * drab;
	}
	ALBEDO = hsv2rgb(clamp(hsv, 0.0, 1.0));
	ROUGHNESS = 0.85;
}
