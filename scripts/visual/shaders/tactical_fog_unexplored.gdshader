shader_type canvas_item;
render_mode unshaded;

// TACTICAL OBSCURITY, unexplored hexes (VISUAL ONLY, HIGH / FLAT board).
// A map's unknown space, not weather: flat ink with a faint per-hex tone
// (vertex colour) so the unknown reads as territory, never as cloud.
// Static on purpose: no TIME, no noise. Same ink as the CLOSEUP view
// (VisualContract.FOG_INK).

uniform vec4 ink : source_color = vec4(0.155, 0.165, 0.19, 1.0);
// Share of the per-hex vertex tone mixed into the ink.
uniform float tone_mix = 0.18;

void fragment() {
	COLOR = vec4(mix(ink.rgb, COLOR.rgb, tone_mix), COLOR.a);
}
