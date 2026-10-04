shader_type spatial;
render_mode blend_mix, unshaded, cull_disabled, depth_draw_never;

// The sketch sheet on the design table: a faint tinted pane with a grid on it. Drawn on one quad whose UV spans the
// whole sheet, in the sketch's own millimetres, so the lines sit exactly where the sketch's coordinates are. Minor lines
// every `minor_mm`, a stronger line every `major_every` of them, the two axes through the sketch origin in red (u) and
// green (v), and everything fades out towards the sheet's edge. The spacing is chosen on the CPU from the part's current
// scale (SketchMath.grid_step) so the lines stay about the same distance apart on screen however far you zoom.

uniform vec2 sheet_mm = vec2(300.0, 150.0);      // the quad's size, mm
uniform vec2 centre_mm = vec2(0.0);              // the sketch (u, v) of the sheet's middle
uniform float minor_mm = 10.0;
uniform float major_every = 5.0;
uniform vec4 tint : source_color = vec4(0.31, 0.77, 1.0, 0.07);
uniform vec4 line_color : source_color = vec4(0.62, 0.84, 1.0, 1.0);
uniform vec4 u_axis_color : source_color = vec4(1.0, 0.35, 0.35, 0.9);
uniform vec4 v_axis_color : source_color = vec4(0.4, 0.95, 0.5, 0.9);
uniform float minor_strength = 0.16;
uniform float major_strength = 0.34;
uniform float fade_mm = 40.0;                    // the band at the sheet's edge over which the lines fade

float grid_line(float coord, float step_mm) {
	float f = coord / step_mm;
	float d = abs(fract(f - 0.5) - 0.5);          // 0 on a line, in cells
	float w = max(fwidth(f), 0.0001);
	return 1.0 - smoothstep(0.0, w * 1.4, d);
}

void fragment() {
	vec2 p = centre_mm + vec2(UV.x - 0.5, 0.5 - UV.y) * sheet_mm;
	vec2 edge = (0.5 * sheet_mm - abs(p - centre_mm));
	float fade = smoothstep(0.0, max(fade_mm, 0.001), min(edge.x, edge.y));
	float minor = max(grid_line(p.x, minor_mm), grid_line(p.y, minor_mm));
	float major = max(grid_line(p.x, minor_mm * major_every), grid_line(p.y, minor_mm * major_every));
	float strength = max(minor * minor_strength, major * major_strength) * fade;
	vec3 colour = tint.rgb;
	float alpha = tint.a + strength;
	float wu = max(fwidth(p.y), 0.0001) * 1.2;
	float wv = max(fwidth(p.x), 0.0001) * 1.2;
	float on_u = 1.0 - smoothstep(0.0, wu, abs(p.y));
	float on_v = 1.0 - smoothstep(0.0, wv, abs(p.x));
	colour = mix(tint.rgb, line_color.rgb, clamp(strength * 4.0, 0.0, 1.0));
	colour = mix(colour, u_axis_color.rgb, on_u * fade);
	colour = mix(colour, v_axis_color.rgb, on_v * fade);
	alpha = max(alpha, max(on_u, on_v) * 0.8 * fade);
	// a thin bright border at the very edge of the window
	float rim = 1.0 - smoothstep(0.0, max(fwidth(edge.x), 0.0001) * 1.5 + 0.0, min(edge.x, edge.y));
	colour = mix(colour, line_color.rgb, rim);
	ALBEDO = colour;
	ALPHA = clamp(max(alpha, rim * 0.6), 0.0, 1.0);
}
