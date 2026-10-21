shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled;
// A soft additive glow behind the logo: a radial falloff on a quad, tinted by `tint`.

uniform vec3 tint : source_color = vec3(0.15, 0.55, 1.0);
uniform float intensity = 0.42;
uniform float falloff = 2.4;

void fragment() {
	vec2 q = (UV - 0.5) * 2.0;
	q.x *= 0.78; // a little wider than tall: the logo is
	float d = length(q);
	float a = pow(max(1.0 - d, 0.0), falloff);
	ALBEDO = tint * a * intensity;
	ALPHA = a;
}
