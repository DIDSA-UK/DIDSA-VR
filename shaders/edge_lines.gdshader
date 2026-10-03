shader_type spatial;
render_mode unshaded, cull_disabled;
// The part's real CAD edges (view_modes.gd: Shaded + edges, Wireframe), drawn as GL lines. Two details:
//   * the vertices are pulled a hair towards the eye (in world metres, so the same for any model scale) so a line lying exactly on the
//     boundary between two faces is not eaten by them (z-fighting);
//   * the section tool's clip plane (the same global uniforms as section_clip.gdshader) cuts the lines too, or a sectioned part
//     would keep a floating cage of edges on the removed half.

uniform vec4 line_color : source_color = vec4(0.15, 0.15, 0.15, 1.0);
uniform float bias_metres = 0.0015;

global uniform vec3 section_plane_origin;
global uniform vec3 section_plane_normal;
global uniform bool section_enabled;

varying vec3 world_pos;

void vertex() {
	vec3 w = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_pos = w;
	vec3 eye = INV_VIEW_MATRIX[3].xyz;
	w += normalize(eye - w) * bias_metres;
	POSITION = PROJECTION_MATRIX * VIEW_MATRIX * vec4(w, 1.0);
}

void fragment() {
	if (section_enabled && dot(world_pos - section_plane_origin, section_plane_normal) < 0.0) {
		discard;
	}
	ALBEDO = line_color.rgb;
}
