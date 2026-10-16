shader_type spatial;
render_mode unshaded, cull_disabled, blend_mix, depth_draw_never, diffuse_lambert, specular_disabled;

// Replaces the old opaque floor plane from the first prototype: thin
// white grid lines on an otherwise fully transparent plane, so a part that
// drops below floor level (y < 0) stays visible instead of being hidden
// behind solid geometry. depth_draw_never above is deliberate, not an
// oversight — this is a visual reference only, so it must never occlude
// anything, including through its own mostly-transparent gaps.

uniform float cell_size_m = 0.6; // 600x600mm grid squares
uniform vec4 line_color : source_color = vec4(1.0, 1.0, 1.0, 0.4); // white, ~60% transparent
uniform float line_thickness_px = 1.5;
uniform float fade_start_m = 12.0; // distance from the camera where the grid starts fading
uniform float fade_end_m = 35.0; // distance where it's fully invisible, so the plane's own edge is never seen

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 coord = world_pos.xz / cell_size_m;
	vec2 deriv = fwidth(coord) * max(line_thickness_px * 0.5, 0.001);
	vec2 grid = abs(fract(coord - 0.5) - 0.5) / max(deriv, vec2(0.0001));
	float line = 1.0 - min(min(grid.x, grid.y), 1.0);

	float dist = length(world_pos - CAMERA_POSITION_WORLD);
	float fade = 1.0 - smoothstep(fade_start_m, fade_end_m, dist);

	ALBEDO = line_color.rgb;
	ALPHA = line_color.a * line * fade;
}
