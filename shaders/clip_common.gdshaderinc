// The two clips every part shader shares (section_clip, edge_lines, highlight_clip), so a part, its edge overlay and its hover / selection
// overlays are always cut the same way.
//   1. The SECTION plane (section_tool.gd): a world-space half-space, applied to everything while the tool is on.
//   2. The SKETCH WINDOW box (sketch_clip.gd): while a sketch is open, a box in the sketch plane (the window's rectangle, a depth either side
//      of the plane), so zooming a sketch right in does not fill the room with the part. It applies only to materials that ask for it with
//      the per-material `window_clip` switch (the design table's copy of the part, its edge lines and its overlays), never to the arena's parts.
//   3. ROOM boxes (scripts/room/room_registry.gd, docs/assembly-rooms-scope.md): finite oriented boxes that each hold their own assembly. A material says
//      which room it belongs to with the per-material `room_slot`: a slot >= 0 means "I live in that room: show me only inside its box", -1 means "I am
//      the world: hide me inside every room's box", and the default -2 means "ignore rooms" (the design table's copy, overlays that have not been told).
//      The boxes arrive as one small float texture (`room_clip_tex`, one row per room) so the number of rooms is not baked into the shader;
//      `room_clip_count` is the number of rows in use (0: rooms off, and the test below costs one comparison).
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

global uniform int room_clip_count;
global uniform sampler2D room_clip_tex; // RGBA float, 4 texels per room (row = slot): three rows of the world -> room-local 3x4 matrix (xyz = basis row, w = translation), then the half extents (xyz); a negative half extent = no room in this slot

uniform bool window_clip = false;
uniform int room_slot = -2; // see above: >= 0 a room's content, -1 the world, -2 ignore rooms

const int ROOM_CLIP_MAX = 16; // rows the texture holds (room_registry.gd's HARD_MAX)

bool room_contains(int slot, vec3 world_pos) {
	vec4 r0 = texelFetch(room_clip_tex, ivec2(0, slot), 0);
	vec4 r1 = texelFetch(room_clip_tex, ivec2(1, slot), 0);
	vec4 r2 = texelFetch(room_clip_tex, ivec2(2, slot), 0);
	vec3 h = texelFetch(room_clip_tex, ivec2(3, slot), 0).xyz;
	vec3 l = vec3(dot(r0.xyz, world_pos) + r0.w, dot(r1.xyz, world_pos) + r1.w, dot(r2.xyz, world_pos) + r2.w);
	return h.x >= 0.0 && abs(l.x) <= h.x && abs(l.y) <= h.y && abs(l.z) <= h.z;
}

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
	if (room_clip_count > 0 && room_slot > -2) {
		if (room_slot >= 0) {
			if (!room_contains(room_slot, world_pos)) {
				return true; // a room's own content is cut off at its walls
			}
		} else {
			for (int i = 0; i < ROOM_CLIP_MAX; i++) {
				if (i >= room_clip_count) {
					break;
				}
				if (room_contains(i, world_pos)) {
					return true; // the world does not show through a room
				}
			}
		}
	}
	return false;
}
