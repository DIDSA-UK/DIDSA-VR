shader_type spatial;
render_mode cull_disabled, depth_prepass_alpha;
// section_clip.gdshader for a see-through look (the Appearance tool's opacity below 1): the same body with ALPHA, drawn with a depth
// pre-pass so a see-through part doesn't show its own back faces. scripts/clip_look.gd picks it.
#define CLIP_ALPHA
#include "res://shaders/section_clip_body.gdshaderinc"
