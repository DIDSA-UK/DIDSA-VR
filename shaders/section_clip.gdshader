shader_type spatial;
render_mode cull_disabled;
// Milestone 4 (sections): a world-space clip plane, shared by every loaded
// part via a global shader uniform, so section_tool.gd only has to set it
// once per frame rather than per-material. Confirmed (real, non-headless
// Xvfb+llvmpipe render, tests/section_tool.gd's render check) that a
// fragment on the excluded side is actually discarded, not just made
// transparent — this produces a real visual cutaway, not a fade.
//
// Real-headset feedback: a solid part clipped past its own midpoint read as
// having simply vanished, not been cut open — confirmed by rendering the
// exact camera angle that exposes it (looking straight into the open cut,
// tests/section_render.gd's own Xvfb+llvmpipe setup): with the default
// cull_back, the discarded half leaves nothing but its OWN interior
// (back-facing) surfaces where it used to be, and those are invisible under
// normal culling — you look straight through the "hole" to whatever's
// behind, which is usually nothing. cull_disabled plus flipping the normal
// on a back face (below) renders that interior surface instead of hiding
// it, which — for the mechanical parts this app actually loads, almost
// always simple, near-solid volumes — reads as a real filled cross-section
// rather than a true stencil-capped one (which would need a second render
// pass this single fragment shader can't do), at zero extra draw calls.
//
// ALBEDO is the only per-part input: mesh_export.py's AssemblyGlbInstance
// only ever sets pbrMetallicRoughness.baseColorFactor (see that module's
// encode_assembly_glb) and never a metallicFactor/roughnessFactor override or
// any texture — this shader is never asked to render a textured part.
// section_tool.gd reads the current albedo_color off whatever material it's
// replacing (the glTF-generated StandardMaterial3D, or colour_tool.gd's flat
// override) before installing this.
//
// METALLIC/ROUGHNESS below used to be hardcoded to the glTF spec's own
// unset-field defaults (1.0 each, matching what mesh_export.py's own output
// technically carries) — real-headset feedback traced part of the
// "disappears" bug above to this too: fully metallic + fully rough has
// near-zero diffuse response and reads as flat black under this app's own
// (comparatively low-energy) directional light and ambient colour, with no
// reflection probe to give a metal surface anything to reflect. Lowered to
// a plain non-metallic, moderately rough surface so a sectioned part is
// reliably visible under normal in-app lighting — a deliberate departure
// from matching the export's own literal metallic/roughness values, not an
// oversight; visibility here matters more than exactly reproducing a shine
// difference nobody's actually asked for.

uniform vec4 albedo_color : source_color = vec4(1.0);

global uniform vec3 section_plane_origin;
global uniform vec3 section_plane_normal;
global uniform bool section_enabled;

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
	if (section_enabled) {
		if (dot(world_pos - section_plane_origin, section_plane_normal) < 0.0) {
			discard;
		}
	}
	NORMAL = FRONT_FACING ? NORMAL : -NORMAL;
	// The newly-visible interior (a back face, only ever seen at all once
	// cull_disabled above stops hiding it) reads darker, same convention
	// real CAD tools use to mark a cut face as "inside", not just more of
	// the same outer surface.
	ALBEDO = FRONT_FACING ? albedo_color.rgb : albedo_color.rgb * 0.6;
	METALLIC = 0.0;
	ROUGHNESS = 0.6;
}
