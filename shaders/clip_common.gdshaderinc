// The two clips every part shader shares (section_clip, edge_lines, highlight_clip), so a part, its edge overlay and its hover / selection
// overlays are always cut the same way.
//   1. The SECTION plane (section_tool.gd): a world-space half-space, applied to everything while the tool is on.
//   2. The SKETCH WINDOW box (sketch_clip.gd): while a sketch is open, a box in the sketch plane (the window's rectangle, a depth either side
//      of the plane), so zooming a sketch right in does not fill the room with the part. It applies only to materials that ask for it with
//      the per-material `window_clip` switch (the design table's copy of the part, its edge lines and its overlays), never to the arena's parts.
// All world space, metres. Call clipped(world_pos) from fragment() with the position made in vertex() (see section_clip.gdshader).

global uniform vec3 section_plane_origin;
global uniform vec3 section_plane_normal;
global uniform bool section_enabled;

global uniform bool window_clip_enabled;
global uniform vec3 window_clip_origin; // the box's middle
global uniform vec3 window_clip_u; // its axes (unit): across the window,
global uniform vec3 window_clip_v; // up the window,
global uniform vec3 window_clip_n; // and off the sketch plane
global uniform vec3 window_clip_half; // half the box along u, v, n

uniform bool window_clip = false;

bool clipped(vec3 world_pos) {
	if (section_enabled && dot(world_pos - section_plane_origin, section_plane_normal) < 0.0) {
		return true;
	}
	if (window_clip && window_clip_enabled) {
		vec3 d = world_pos - window_clip_origin;
		if (abs(dot(d, window_clip_u)) > window_clip_half.x || abs(dot(d, window_clip_v)) > window_clip_half.y || abs(dot(d, window_clip_n)) > window_clip_half.z) {
			return true;
		}
	}
	return false;
}
