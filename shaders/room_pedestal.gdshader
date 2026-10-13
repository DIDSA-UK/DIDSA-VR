shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled;
// The ghostly column that runs from a room's console down to the floor (scripts/room/room_console.gd): purely aesthetic, so it is faint and fades out towards the
// floor and does not hide anything. The mesh is a unit-height cylinder (local y from -0.5 at the floor to +0.5 at the console).

uniform vec4 tint : source_color = vec4(0.35, 0.85, 1.0, 1.0);
uniform float strength = 0.22;

varying float height;

void vertex() {
	height = VERTEX.y + 0.5; // 0 at the floor, 1 at the console
}

void fragment() {
	float fres = pow(1.0 - abs(dot(normalize(NORMAL), normalize(VIEW))), 1.5);
	ALBEDO = tint.rgb;
	ALPHA = strength * height * (0.35 + 0.65 * fres);
}
