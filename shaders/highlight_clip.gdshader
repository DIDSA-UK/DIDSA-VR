shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never;
// The Mates / Measure hover and pick highlights (scripts/face_highlight.gd): a flat translucent colour on the
// hovered or picked face / edge / ball, clipped by the SAME world-space plane as the section tool
// (shaders/section_clip.gdshader reads the same global uniforms), so the highlight on the cut-away half of a part
// is cut away with it instead of floating in the air where the part used to be.
uniform vec4 colour : source_color = vec4(1.0);

global uniform vec3 section_plane_origin;
global uniform vec3 section_plane_normal;
global uniform bool section_enabled;

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz; // see section_clip.gdshader: world position has to come from vertex()
}

void fragment() {
	if (section_enabled && dot(world_pos - section_plane_origin, section_plane_normal) < 0.0) {
		discard;
	}
	ALBEDO = colour.rgb;
	ALPHA = colour.a;
}
