extends RefCounted
## The global shader parameters shaders/clip_common.gdshaderinc declares (the section plane, the sketch-window box and the room boxes), registered once per process.
## Every shader that includes it needs all of them to exist, so whoever uses either clip calls ensure() (section_tool.gd, sketch_clip.gd). Re-adding a
## name is an engine error, hence the flag.

const PARAMS := {
	"section_plane_origin": [RenderingServer.GLOBAL_VAR_TYPE_VEC3, Vector3.ZERO],
	"section_plane_normal": [RenderingServer.GLOBAL_VAR_TYPE_VEC3, Vector3.UP],
	"section_enabled": [RenderingServer.GLOBAL_VAR_TYPE_BOOL, false],
	"window_clip_enabled": [RenderingServer.GLOBAL_VAR_TYPE_BOOL, false],
	"window_clip_origin": [RenderingServer.GLOBAL_VAR_TYPE_VEC3, Vector3.ZERO],
	"window_clip_u": [RenderingServer.GLOBAL_VAR_TYPE_VEC3, Vector3.RIGHT],
	"window_clip_v": [RenderingServer.GLOBAL_VAR_TYPE_VEC3, Vector3.UP],
	"window_clip_n": [RenderingServer.GLOBAL_VAR_TYPE_VEC3, Vector3.BACK],
	"window_clip_half": [RenderingServer.GLOBAL_VAR_TYPE_VEC3, Vector3(1, 1, 1)],
	"room_clip_count": [RenderingServer.GLOBAL_VAR_TYPE_INT, 0],
}

const ROOM_TEX_WIDTH := 4 ## texels per room: three rows of the world -> room-local matrix, then the half extents (room_registry.gd packs them)
const ROOM_TEX_ROWS := 16 ## one row per room slot; the shader's ROOM_CLIP_MAX


static var room_texture: ImageTexture ## the room boxes (`room_clip_tex`): room_registry.gd updates it in place

static var _done := false ## process-wide, and the only place that adds them (the list of existing ones is an editor-only call)


static func ensure() -> void:
	if _done:
		return
	_done = true
	for name in PARAMS:
		RenderingServer.global_shader_parameter_add(name, PARAMS[name][0], PARAMS[name][1])
	var blank := Image.create_empty(ROOM_TEX_WIDTH, ROOM_TEX_ROWS, false, Image.FORMAT_RGBAF)
	blank.fill(Color(0, 0, 0, 0))
	room_texture = ImageTexture.create_from_image(blank)
	RenderingServer.global_shader_parameter_add("room_clip_tex", RenderingServer.GLOBAL_VAR_TYPE_SAMPLER2D, room_texture)
