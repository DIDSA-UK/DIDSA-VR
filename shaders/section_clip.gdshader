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
// The part's whole look is the input (the Appearance tool, DIDSA-CAD
// docs/appearance-tool-scope.md): albedo (with alpha), metallic, roughness and
// emission, read by scripts/clip_look.gd off whatever material it replaces (the
// glTF-generated StandardMaterial3D or the Appearance tool's own). A part
// split by appearance (one surface per look) wears one of these per surface.
// A see-through look uses section_clip_alpha.gdshader (the same body, with
// alpha and a depth pre-pass). Never a textured part.
//
// METALLIC/ROUGHNESS defaults (when a wrapper doesn't set them) used to be hardcoded to the glTF spec's own
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

#include "res://shaders/section_clip_body.gdshaderinc"
