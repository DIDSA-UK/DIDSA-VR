extends SceneTree
## NEEDS A REAL RENDER (Xvfb, see tests/room_clip_render.gd): the world preview's shader (shaders/world_preview.gdshader) as pixels. A unit cube seen straight on:
##   * in the preview colour it is violet (blue and red above green) and clearly there;
##   * a part the edit changed (the changed tint) reads pink, not violet;
##   * the ghost is faint and pale compared with the preview;
##   * like any world part, the preview is cut away inside a room's box (room_slot -1) - the shader compiles with the shared clip include and obeys it.
## Run: xvfb-run -a "$GODOT" --path . --script res://tests/room_preview_render.gd

const WorldPreview := preload("res://scripts/room/world_preview.gd")
const RoomRegistry := preload("res://scripts/room/room_registry.gd")
const RoomVolume := preload("res://scripts/room/room_volume.gd")
const ClipGlobals := preload("res://scripts/clip_globals.gd")

var viewport: SubViewport


func px() -> Color:
	return viewport.get_texture().get_image().get_pixel(50, 50)


func frames() -> void:
	for i in 4:
		await process_frame


func make(tint: Color, alpha: float) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.mesh = BoxMesh.new()
	var m := ShaderMaterial.new()
	m.shader = WorldPreview.PreviewShader
	m.set_shader_parameter("tint", tint)
	m.set_shader_parameter("alpha", alpha)
	node.material_override = m
	node.set_instance_shader_parameter("room_slot", -1)
	return node


func _initialize() -> void:
	ClipGlobals.ensure()
	RoomRegistry.clear()
	viewport = SubViewport.new()
	viewport.size = Vector2i(100, 100)
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var world_env := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0, 0, 0)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(1, 1, 1)
	env.ambient_light_energy = 1.0
	world_env.environment = env
	viewport.add_child(world_env)
	var camera := Camera3D.new()
	camera.current = true
	camera.position = Vector3(0, 0, 10)
	camera.fov = 22.62 # (perspective, 4 m across at 10 m: the shader's rim reads VIEW, which an orthographic camera does not give it face-on)
	viewport.add_child(camera)

	var cube := make(WorldPreview.PREVIEW_TINT, 0.9)
	viewport.add_child(cube)
	await frames()
	var c := px()
	print("SMOKE the preview cube is violet: red and blue clearly above green, and it is visible: ", c.b > c.g + 0.1 and c.r > c.g + 0.05 and c.b > 0.15)
	var violet := c

	cube.material_override.set_shader_parameter("tint", WorldPreview.CHANGED_TINT)
	await frames()
	c = px()
	print("SMOKE a changed part reads pink: red well above blue, unlike the violet one: ", c.r > c.b + 0.05 and c.r > violet.r)

	cube.material_override.set_shader_parameter("tint", WorldPreview.GHOST_TINT)
	cube.material_override.set_shader_parameter("alpha", 0.18)
	await frames()
	c = px()
	print("SMOKE the ghost is fainter than the preview (dimmer over the same background): ", (c.r + c.g + c.b) < (violet.r + violet.g + violet.b) * 0.8)

	cube.material_override.set_shader_parameter("tint", WorldPreview.PREVIEW_TINT)
	cube.material_override.set_shader_parameter("alpha", 0.9)
	var volume := RoomVolume.make(Transform3D(Basis.IDENTITY, Vector3.ZERO), Vector3(3, 3, 3))
	RoomRegistry.add_room(volume)
	await frames()
	c = px()
	print("SMOKE like any world part it is cut away inside a room's box (the pixel is background again): ", c.r < 0.03 and c.g < 0.03 and c.b < 0.03)
	quit(0)
