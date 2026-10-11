shader_type spatial;
// CLOSEUP 2.5D card (VISUAL ONLY): one flat 2D sprite standing upright on the
// board, turned toward the camera about the vertical axis only. Used for
// units, trees, houses, mountains and strongholds alike, so the whole closeup
// is one sprite language. Unlit, alpha-cut (exact depth order), static.
//
// kind 0 = scenery : hidden on unexplored hexes, remembered tint on explored
// kind 1 = unit    : never fog-tinted (the 2D board already hides unseen units)
// kind 2 = landmark: on unexplored hexes drawn as a faint silhouette only
render_mode unshaded, cull_disabled, depth_draw_opaque;

#include "res://scripts/visual/closeup25d/closeup_common.gdshaderinc"

uniform sampler2D tex : source_color, filter_linear_mipmap;
uniform vec4 uv_rect = vec4(0.0, 0.0, 1.0, 1.0); // crop inside the texture
uniform int kind = 0;
uniform bool flip_by_instance = false;
// line-of-sight clearing: nearest units, xyz + radius (scenery only)
uniform float occ[64];
uniform int occ_count = 0;
uniform vec3 cam_world = vec3(0.0);
// scenery right at the lens thins out so the front of the army reads
uniform float near_fade_start = 0.0;
uniform float near_fade_end = 0.0;
uniform float mask_cap = 1.0;

varying vec3 wpos;
varying flat float v_fog;
varying flat float v_play;
varying flat float v_shade;
varying flat float v_flip;

void vertex() {
	vec3 origin = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	float sx = length(MODEL_MATRIX[0].xyz);
	float sy = length(MODEL_MATRIX[1].xyz);
	vec3 right = INV_VIEW_MATRIX[0].xyz;
	right.y = 0.0;
	right = normalize(right + vec3(1e-5, 0.0, 0.0));
	vec3 w = origin + right * VERTEX.x * sx + vec3(0.0, VERTEX.y * sy, 0.0);
	wpos = w;
	POSITION = PROJECTION_MATRIX * VIEW_MATRIX * vec4(w, 1.0);
	vec4 c = cu_cell(cu_hex_of(origin.xz));
	v_fog = c.g;
	v_play = c.a;
	v_shade = INSTANCE_CUSTOM.r > 0.0 ? INSTANCE_CUSTOM.r : 1.0;
	v_flip = (flip_by_instance && INSTANCE_CUSTOM.g > 0.5) ? 1.0 : 0.0;
}

float bayer4(vec2 p) {
	ivec2 i = ivec2(mod(p, 4.0));
	int m[16] = { 0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5 };
	return (float(m[i.y * 4 + i.x]) + 0.5) / 16.0;
}

void fragment() {
	vec2 uv = UV;
	if (v_flip > 0.5) uv.x = 1.0 - uv.x;
	vec4 t = texture(tex, uv_rect.xy + uv * uv_rect.zw);
	if (t.a < 0.5) { discard; }
	vec3 col = t.rgb * v_shade;
	float fog = v_play > 0.5 ? v_fog : 1.0;
	float dm = cu_distance_mask(wpos.xz);
	if (v_play < 0.5) dm = max(dm, 0.55);
	if (kind == 0) {
		if (fog < 0.25) { discard; }
		if (fog < 0.75) { col = cu_memory(col); }
		float th = bayer4(FRAGCOORD.xy);
		// thin scenery standing between the lens and a nearby unit
		for (int i = 0; i < 16; i++) {
			if (i >= occ_count) { break; }
			vec3 u = vec3(occ[i * 4], occ[i * 4 + 1], occ[i * 4 + 2]);
			vec3 d = u - cam_world;
			float len = length(d);
			vec3 dir = d / len;
			float along = dot(wpos - cam_world, dir);
			if (along > 0.0 && along < len - 0.2) {
				float off = length((wpos - cam_world) - dir * along);
				float k = 1.0 - smoothstep(occ[i * 4 + 3] * 0.55, occ[i * 4 + 3], off);
				if (k * 0.8 > th) { discard; }
			}
		}
		if (near_fade_end > 0.0) {
			float nd = distance(wpos, cam_world);
			float keep = smoothstep(near_fade_start, near_fade_end, nd);
			if (keep < th) { discard; }
		}
	} else if (kind == 2 && fog < 0.25) {
		// a known landmark in unknown country: faint silhouette only
		col = mix(ink, vec3(0.34, 0.36, 0.41), 0.55);
		dm = min(dm, 0.35);
	}
	ALBEDO = mix(col, ink, min(dm, mask_cap));
}
