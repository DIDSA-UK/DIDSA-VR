shader_type spatial;
render_mode blend_mix, unshaded, cull_disabled, depth_draw_never, depth_test_disabled; // the sketch shows over the part, also when its plane is inside the part

// The sketch's lines, markers and dimension strokes on the design table: flat vertex colours, clipped to the canvas window. The
// geometry is built in the sketch's own (u, v) millimetres (the canvas node maps those onto the part), so the window is just a
// rectangle around `clip_centre` in vertex space and anything outside it is discarded.

uniform vec2 clip_centre = vec2(0.0);
uniform vec2 clip_half = vec2(1.0e9);

varying vec2 sketch_uv;

void vertex() {
	sketch_uv = VERTEX.xy;
}

void fragment() {
	vec2 e = abs(sketch_uv - clip_centre);
	if (e.x > clip_half.x || e.y > clip_half.y) {
		discard;
	}
	ALBEDO = COLOR.rgb;
	ALPHA = COLOR.a;
}
