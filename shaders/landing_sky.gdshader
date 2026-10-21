shader_type sky;
// The landing's night sky: deep navy to a warm band at the horizon, a scatter of stars. Static (no TIME), so the engine renders it once.

uniform vec3 zenith : source_color = vec3(0.008, 0.020, 0.062);
uniform vec3 mid : source_color = vec3(0.055, 0.120, 0.260);
uniform vec3 horizon : source_color = vec3(0.95, 0.42, 0.16);
uniform vec3 below : source_color = vec3(0.012, 0.022, 0.050);
uniform float star_cells = 190.0;
uniform float star_chance = 0.0075;

// The cell id is wrapped first so every number stays small: a hash that multiplies values into the tens of thousands needs full 32-bit floats, and a
// mobile GPU running this at half precision would turn whole patches of sky into "stars" (the Quest flicker suspect, docs/quest-first-run-fixes.md B2).
float hash13(highp vec3 id) {
	highp vec3 p = fract(mod(id, 289.0) * vec3(0.1031, 0.1030, 0.0973));
	p += dot(p, p.yzx + 19.19);
	return fract((p.x + p.y) * p.z);
}

void sky() {
	vec3 d = normalize(EYEDIR);
	float h = d.y;
	vec3 col = mix(horizon, mid, smoothstep(0.0, 0.22, h));
	col = mix(col, zenith, smoothstep(0.25, 1.0, h));
	col += horizon * exp(-abs(h) * 16.0) * 0.30; // the glow hugging the horizon
	if (h < 0.0) {
		col = mix(horizon * 0.28, below, smoothstep(0.0, 0.12, -h));
	}
	// stars: a hashed cell per direction, a soft dot in some of them, none near the horizon glow
	vec3 p = d * star_cells;
	vec3 id = floor(p);
	float r = hash13(id);
	vec3 f = fract(p) - 0.5;
	float dot_ = 1.0 - smoothstep(0.0, 0.30, length(f)); // a falling edge written the long way: smoothstep with edge0 > edge1 is undefined in GLSL
	float star = step(1.0 - star_chance, r) * dot_ * smoothstep(0.06, 0.35, h);
	vec3 tint = mix(vec3(0.75, 0.85, 1.0), vec3(1.0, 0.9, 0.75), fract(r * 91.7));
	col += star * tint * (0.6 + 1.4 * fract(r * 57.3));
	COLOR = clamp(col, vec3(0.0), vec3(4.0)); // never negative, never a NaN-sized value
}
