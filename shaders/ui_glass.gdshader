shader_type canvas_item;
render_mode blend_add, unshaded;

// The UI "glass" effect: an additive overlay drawn over a whole panel (tablet, side list, floating
// windows, popup keyboard). Two things, both STATIC (no time input) so the tablet's idle
// render gating still works:
//   * an inner edge glow: the panel's outline looks lit from within, fading over glow_width pixels;
//   * a soft top-down sheen: a faint diagonal highlight across the upper part of the glass.
// Additive on purpose: it can only brighten, so it never hides text, and one cheap fragment pass per
// render is the whole cost. Switched off by the "Shader effects" setting (the overlay is hidden).
// Parameters come from the UI theme (ui/themes/*.tres, the fx_* tokens); fx_overlay.gd sets them.

uniform vec2 rect_size = vec2(1000.0, 700.0); // the panel's size in pixels
uniform float radius = 22.0;                   // its corner radius in pixels
uniform vec4 glow_color : source_color = vec4(0.31, 0.77, 1.0, 1.0);
uniform float glow_width = 20.0;
uniform float glow_strength = 0.30;
uniform float sheen_strength = 0.05;
uniform float sheen_height = 0.45;             // fraction of the panel height the sheen reaches

float sd_round_box(vec2 p, vec2 half_size, float r) {
	vec2 q = abs(p) - half_size + vec2(r);
	return length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - r;
}

void fragment() {
	vec2 p = (UV - 0.5) * rect_size;
	float d = -sd_round_box(p, rect_size * 0.5, radius); // > 0 inside the rounded edge
	float inside = smoothstep(0.0, 1.5, d);              // clip to the rounded corners
	float edge = exp(-max(d, 0.0) / max(glow_width, 0.001)) * glow_strength;
	float sheen = (1.0 - smoothstep(0.0, sheen_height, UV.y + (0.5 - UV.x) * 0.18)) * sheen_strength;
	vec3 col = glow_color.rgb * edge + vec3(0.80, 0.90, 1.00) * sheen;
	COLOR = vec4(col, inside);
}
