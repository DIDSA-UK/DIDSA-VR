shader_type spatial;
render_mode unshaded, blend_mix, depth_test_disabled, cull_disabled, skip_vertex_transform;
// A comfort vignette: the edges of both eyes darken while the view is carried (Follow presenter, Gather). A full-screen quad: the vertex is put straight on the
// screen (POSITION), so it covers each eye whatever the head does. `strength` 0 draws nothing; 1 closes in to about a third of the view.
uniform float strength : hint_range(0.0, 1.0) = 0.0;
uniform vec3 tint : source_color = vec3(0.0, 0.0, 0.02);

void vertex() {
	POSITION = vec4(VERTEX.xy, 0.0, 1.0);
}

void fragment() {
	vec2 centred = UV * 2.0 - 1.0;
	float d = length(centred * vec2(1.0, 1.0));
	float inner = mix(1.6, 0.30, strength);
	float edge = smoothstep(inner, inner + 0.55, d);
	ALBEDO = tint;
	ALPHA = clamp(edge, 0.0, 1.0) * step(0.001, strength);
}
