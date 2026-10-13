shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never, shadows_disabled;
// An Assembly Room's walls (scripts/room/room.gd): see-through glass, noticeable but not in the way.
//   * a faint tint over every face, a touch more where you look at the glass edge-on (fresnel),
//   * a soft glow along the box's edges, which is what always marks where the room is,
//   * a grid that FADES IN near your hands (so it shows where you are working, and nothing else is cluttered). Its cell is `grid_step` METRES in the room's
//     frame; room.gd picks a round real-world step for the room's scale (1, 2, 5, 10... mm) so a cell stays 0.25 to 0.6 m wide,
//   * the faces a corner-drag is holding light up (`active_faces`: a bit mask, bit 0..5 for +x, -x, +y, -y, +z, -z; 0 none).
// No blur: a real blur needs a copy of the screen, which is expensive on a headset and awkward in stereo. The mesh is a box of the room's full size in the
// ROOM's frame (no scale), so local positions are metres from the room's centre.

uniform vec4 tint : source_color = vec4(0.35, 0.85, 1.0, 1.0);
uniform vec3 half_size = vec3(1.5);
uniform float grid_step = 0.5;
uniform float line_width = 0.012;
uniform float face_alpha = 0.045;
uniform float edge_glow = 0.6;
uniform float edge_width = 0.07;
uniform float fresnel_alpha = 0.10;
uniform vec3 hand_a = vec3(1.0e6); // the two hands, in the room's frame (far away = no grid)
uniform vec3 hand_b = vec3(1.0e6);
uniform float reveal_radius = 0.9;
uniform int active_faces = 0;

varying vec3 local_pos;

void vertex() {
	local_pos = VERTEX;
}

void fragment() {
	vec3 a = half_size - abs(local_pos); // distance to each pair of faces: ~0 on the face being drawn
	// which axis is this face's normal: the one with the smallest distance
	int n = 0;
	if (a.y < a[n]) { n = 1; }
	if (a.z < a[n]) { n = 2; }
	// the other two axes lie in the face; the nearer of their distances is how close we are to an edge
	float d1 = a[(n + 1) % 3];
	float d2 = a[(n + 2) % 3];
	float edge = 1.0 - smoothstep(0.0, edge_width, min(d1, d2));

	float fres = pow(1.0 - abs(dot(normalize(NORMAL), normalize(VIEW))), 2.0);

	// grid on the face's own two axes, lines drawn with a screen-aware width
	vec2 uv = vec2(local_pos[(n + 1) % 3], local_pos[(n + 2) % 3]) / grid_step;
	vec2 g = abs(fract(uv - 0.5) - 0.5);
	vec2 w = max(fwidth(uv), vec2(line_width / grid_step));
	vec2 line = 1.0 - smoothstep(vec2(0.0), w * 1.5, g);
	float grid = max(line.x, line.y);
	float reveal = max(1.0 - smoothstep(0.0, reveal_radius, distance(local_pos, hand_a)), 1.0 - smoothstep(0.0, reveal_radius, distance(local_pos, hand_b)));

	float face_index = float(n) * 2.0 + (local_pos[n] > 0.0 ? 0.0 : 1.0);
	float held = ((active_faces >> int(face_index)) & 1) == 1 ? 1.0 : 0.0;

	float alpha = face_alpha + edge * edge_glow + fres * fresnel_alpha + grid * reveal * 0.55 + held * 0.18;
	ALBEDO = mix(tint.rgb, vec3(1.0), edge * 0.35 + held * 0.3);
	ALPHA = clamp(alpha, 0.0, 0.95);
}
