shader_type spatial;
render_mode unshaded, cull_back, depth_draw_opaque;
// The landing's floor: a dark launch pad with a fine cyan engineering grid (1 m and 10 m), and rings every 10 m around the centre, which is where
// the rockets stand (40-60 m out). Lines fade with distance so the far field stays calm. Drawn unshaded: cheap on a headset.

uniform vec3 base : source_color = vec3(0.008, 0.016, 0.034);
uniform vec3 line : source_color = vec3(0.12, 0.72, 1.0);
uniform vec2 centre = vec2(0.0, 0.0); // world x, z
uniform float fade_start = 25.0;
uniform float fade_end = 170.0;

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

float grid(vec2 p, float cell) {
	vec2 q = p / cell;
	vec2 w = fwidth(q) * 1.2;
	vec2 g = abs(fract(q - 0.5) - 0.5) / max(w, vec2(0.0001));
	return 1.0 - min(min(g.x, g.y), 1.0);
}

void fragment() {
	vec2 p = world_pos.xz;
	float dist = length(VERTEX);
	float fade = 1.0 - smoothstep(fade_start, fade_end, dist);
	float minor = grid(p, 1.0) * (1.0 - smoothstep(6.0, 40.0, dist)); // the 1 m grid only near you
	float major = grid(p, 10.0);
	float rr = length(p - centre);
	float rw = max(fwidth(rr) * 1.6, 0.0001);
	float ring = 1.0 - min(abs(fract(rr / 10.0 - 0.5) - 0.5) * 10.0 / rw, 1.0);
	float ring_major = 1.0 - min(abs(fract(rr / 20.0 - 0.5) - 0.5) * 20.0 / rw, 1.0);
	float spoke = 0.0;
	float ang = atan(p.y - centre.y, p.x - centre.x);
	float sa = abs(fract(ang / 0.5235988 - 0.5) - 0.5) * 0.5235988 * max(rr, 1.0) / max(rw * 2.0, 0.0001); // a spoke every 30 degrees
	spoke = (1.0 - min(sa, 1.0)) * smoothstep(8.0, 20.0, rr) * (1.0 - smoothstep(60.0, 75.0, rr));
	float glow = minor * 0.10 + major * 0.32 + ring * 0.22 + ring_major * 0.55 + spoke * 0.18;
	vec3 col = base + line * glow * fade;
	// a soft pool of light near the user so the floor under your feet is readable
	col += line * 0.04 * (1.0 - smoothstep(0.0, 8.0, dist));
	ALBEDO = col;
}
