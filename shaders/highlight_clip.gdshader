shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never;
// The Mates / Measure hover and pick highlights (scripts/face_highlight.gd): a flat translucent colour on the
// hovered or picked face / edge / ball, clipped by the SAME world-space plane as the section tool
// (shaders/section_clip.gdshader reads the same global uniforms), so the highlight on the cut-away half of a part
// is cut away with it instead of floating in the air where the part used to be.
uniform vec4 colour : source_color = vec4(1.0);

#include "res://shaders/clip_common.gdshaderinc" // the section plane and the sketch-window box

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz; // see section_clip.gdshader: world position has to come from vertex()
}

void fragment() {
	if (clipped(world_pos)) {
		discard;
	}
	ALBEDO = colour.rgb;
	ALPHA = colour.a;
}
