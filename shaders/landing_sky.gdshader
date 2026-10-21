shader_type sky;
// The landing's night sky: deep navy to a warm band at the horizon, a scatter of stars. Static (no TIME), so the engine renders it once.

uniform vec3 zenith : source_color = vec3(0.008, 0.020, 0.062);
uniform vec3 mid : source_color = vec3(0.030, 0.075, 0.170);
uniform vec3 horizon : source_color = vec3(0.95, 0.42, 0.16);
uniform vec3 below : source_color = vec3(0.012, 0.022, 0.050);
uniform float star_cells = 190.0;
uniform float star_chance = 0.0075;

float hash13(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.zyx + 31.32);
	return fract((p.x + p.y) * p.z);
}

void sky() {
	vec3 d = normalize(EYEDIR);
	float h = d.y;
	vec3 col = mix(horizon, mid, smoothstep(0.0, 0.16, h));
	col = mix(col, zenith, smoothstep(0.08, 0.85, h));
	col += horizon * exp(-abs(h) * 16.0) * 0.30; // the glow hugging the horizon
	if (h < 0.0) {
		col = mix(horizon * 0.28, below, smoothstep(0.0, 0.12, -h));
	}
	// stars: a hashed cell per direction, a soft dot in some of them, none near the horizon glow
	vec3 p = d * star_cells;
	vec3 id = floor(p);
	float r = hash13(id);
	vec3 f = fract(p) - 0.5;
	float dot_ = smoothstep(0.30, 0.0, length(f));
	float star = step(1.0 - star_chance, r) * dot_ * smoothstep(0.06, 0.35, h);
	vec3 tint = mix(vec3(0.75, 0.85, 1.0), vec3(1.0, 0.9, 0.75), fract(r * 91.7));
	col += star * tint * (0.6 + 1.4 * fract(r * 57.3));
	COLOR = col;
}
