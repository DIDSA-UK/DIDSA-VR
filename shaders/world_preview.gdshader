shader_type spatial;
render_mode cull_disabled, depth_draw_opaque;
// The world copy of a sub-assembly you are editing in an Assembly Room (scripts/room/world_preview.gd): either a faint ghost of the original, or the edited
// copy in the preview colour, at each place the sub-assembly sits in the world. Same clip rules as every world part (the section plane, and hidden inside any
// room), so the room_slot instance uniform is set to -1 by the owner. A soft rim keeps the shape readable while the body stays see-through.

uniform vec4 tint : source_color = vec4(0.62, 0.3, 0.95, 1.0);
uniform float alpha = 0.55;
uniform float rim = 0.45; // extra opacity at grazing angles
uniform float pulse = 0.0; // 0 = steady; > 0 breathes the opacity by this much (the aesthetic option)
uniform float time_offset = 0.0;

#include "res://shaders/clip_common.gdshaderinc"

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	if (clipped(world_pos)) {
		discard;
	}
	float facing = abs(dot(normalize(NORMAL), normalize(VIEW))); // (a double-sided surface's back faces arrive with their normal already turned; abs() is right either way)
	float breathe = pulse > 0.0 ? pulse * sin((TIME + time_offset) * 2.4) : 0.0;
	ALBEDO = tint.rgb;
	EMISSION = tint.rgb * 0.25;
	ALPHA = clamp(alpha + breathe + rim * pow(1.0 - facing, 2.0), 0.0, 1.0);
	METALLIC = 0.0;
	ROUGHNESS = 0.7;
}
