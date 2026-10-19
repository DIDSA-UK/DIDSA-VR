// The body of section_clip.gdshader and section_clip_alpha.gdshader (CLIP_ALPHA): see section_clip.gdshader for why it is built this way.
uniform vec4 albedo_color : source_color = vec4(1.0);
uniform float metallic = 0.0;
uniform float roughness = 0.6;
uniform vec4 emission_color : source_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform float emission_energy = 0.0;

#include "res://shaders/clip_common.gdshaderinc" // the section plane and the sketch-window box, shared with the edge and highlight shaders

// World position must be computed in vertex(): in Godot 4's fragment(),
// VERTEX is VIEW-space, not model-space. The earlier version here did
// MODEL_MATRIX * VERTEX inside fragment(), which mixes the two — with the
// assembly root scaled 0.001 and placed at spawn_position, every fragment
// landed at ~the model's origin, so the clip test became all-or-nothing for
// the whole model and it "vanished" exactly when the plane crossed the
// model's origin (real-headset report). tests/section_render.gd missed it
// because it rendered an identity-transform mesh through a plain camera,
// where view-space happens to be close to world-space.
varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	if (clipped(world_pos)) {
		discard;
	}
	NORMAL = FRONT_FACING ? NORMAL : -NORMAL;
	// The newly-visible interior (a back face, only ever seen at all once
	// cull_disabled above stops hiding it) reads darker, same convention
	// real CAD tools use to mark a cut face as "inside", not just more of
	// the same outer surface.
	ALBEDO = FRONT_FACING ? albedo_color.rgb : albedo_color.rgb * 0.6;
	METALLIC = metallic;
	ROUGHNESS = roughness;
	EMISSION = emission_color.rgb * emission_energy;
#ifdef CLIP_ALPHA
	ALPHA = albedo_color.a;
#endif
}
