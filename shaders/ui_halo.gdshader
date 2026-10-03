shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled;

// The soft glow around a floating panel (window / keyboard) when a laser is on it or it is being
// carried. A quad a little bigger than the panel sits just BEHIND it: the panel's own quad hides the
// middle, so what shows is a halo that fades out over `margin` metres past the panel's edge.
// Static (no time input). intensity 0 = invisible (the node is hidden then anyway).

uniform vec4 glow_color : source_color = vec4(0.31, 0.77, 1.0, 1.0);
uniform float intensity = 0.5;
uniform vec2 inner = vec2(0.8, 0.8); // the panel's half-extent as a fraction of this quad's
uniform bool hollow = false; // the panel is see-through (the design table's glass slab): leave its own area clear

void fragment() {
	vec2 p = abs(UV - vec2(0.5)) * 2.0; // 0 in the centre, 1 at the quad's edge
	float d = max((p.x - inner.x) / max(1.0 - inner.x, 0.0001), (p.y - inner.y) / max(1.0 - inner.y, 0.0001));
	float a = 1.0 - clamp(d, 0.0, 1.0); // 1 at the panel's edge, 0 at the outer edge
	a = a * a;
	ALBEDO = glow_color.rgb;
	ALPHA = clamp(a * intensity, 0.0, 1.0);
	if (hollow && d <= 0.0) {
		ALPHA = 0.0;
	}
}
