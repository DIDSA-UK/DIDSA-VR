shader_type spatial;
// Milestone 4 (sections): a world-space clip plane, shared by every loaded
// part via a global shader uniform, so section_tool.gd only has to set it
// once per frame rather than per-material. Confirmed (real, non-headless
// Xvfb+llvmpipe render, tests/section_tool.gd's render check) that a
// fragment on the excluded side is actually discarded, not just made
// transparent — this produces a real visual cutaway, not a fade.
//
// ALBEDO is the only per-part input: mesh_export.py's AssemblyGlbInstance
// only ever sets pbrMetallicRoughness.baseColorFactor (see that module's
// encode_assembly_glb) and never a metallicFactor/roughnessFactor override or
// any texture, so METALLIC/ROUGHNESS below are hardcoded to the glTF spec's
// own defaults (1.0 each) for both cases (a colour override baked at export
// time, or none at all) — this shader is never asked to render a textured
// part. section_tool.gd reads the current albedo_color off whatever
// material it's replacing (the glTF-generated StandardMaterial3D, or
// colour_tool.gd's flat override) before installing this, so the look
// doesn't change beyond gaining the ability to be clipped.

uniform vec4 albedo_color : source_color = vec4(1.0);

global uniform vec3 section_plane_origin;
global uniform vec3 section_plane_normal;
global uniform bool section_enabled;

void fragment() {
	if (section_enabled) {
		vec3 world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
		if (dot(world_pos - section_plane_origin, section_plane_normal) < 0.0) {
			discard;
		}
	}
	ALBEDO = albedo_color.rgb;
	METALLIC = 1.0;
	ROUGHNESS = 1.0;
}
