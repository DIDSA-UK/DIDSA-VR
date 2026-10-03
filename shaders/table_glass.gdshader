shader_type spatial;
render_mode blend_mix, unshaded, cull_disabled, depth_draw_never;

// The design table's slab: a pane of glass lying in the console's XZ plane, with rounded corners, a
// bright rim (the border) and a soft inner edge glow, drawn from a signed-distance rounded box so the
// corner radius and the rim width are in metres whatever size the slab is dragged to. The middle is
// mostly clear (you see the arena through it) with a faint top-down sheen. `glow` (0..1) lifts the rim
// and the inner glow: the table is engaged. Static (no time input). Parameters from design_table.gd.

uniform vec2 size = vec2(0.6, 0.4);          // the slab, metres
uniform float radius = 0.045;                // corner radius, metres
uniform float border_width = 0.006;          // rim width, metres
uniform vec4 fill_color : source_color = vec4(0.05, 0.075, 0.12, 0.30);
uniform vec4 border_color : source_color = vec4(0.31, 0.77, 1.0, 1.0);
uniform float glow = 0.0;
uniform float glow_width = 0.06;             // metres the inner glow fades over
uniform float sheen_strength = 0.07;

float sd_round_box(vec2 p, vec2 half_size, float r) {
	vec2 q = abs(p) - half_size + vec2(r);
	return length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - r;
}

void fragment() {
	vec2 p = (UV - 0.5) * size;
	float d = -sd_round_box(p, size * 0.5, min(radius, min(size.x, size.y) * 0.5)); // > 0 inside the rounded edge
	float aa = max(fwidth(d), 0.0004);
	float inside = smoothstep(0.0, aa, d);
	float rim = 1.0 - smoothstep(border_width - aa, border_width, d);
	float edge_glow = exp(-max(d, 0.0) / max(glow_width, 0.001)) * (0.22 + 0.55 * glow);
	float sheen = (1.0 - smoothstep(0.0, 0.7, UV.y + (0.5 - UV.x) * 0.25)) * sheen_strength;
	vec3 body = fill_color.rgb + vec3(0.80, 0.90, 1.00) * sheen + border_color.rgb * edge_glow * 0.6;
	float body_alpha = clamp(fill_color.a + sheen + edge_glow * 0.45, 0.0, 1.0);
	vec3 rim_col = mix(border_color.rgb, vec3(1.0), 0.25 * glow);
	ALBEDO = mix(body, rim_col, rim);
	ALPHA = mix(body_alpha, 1.0, rim) * inside;
}
