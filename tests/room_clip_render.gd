extends SceneTree
## NEEDS A REAL RENDER, not --headless (see tests/section_render.gd): the room clip as pixels. shaders/clip_common.gdshaderinc, driven by the real
## room_registry.gd / room_clip.gd pipeline (the packed texture, the global uniforms, the per-material room_slot), genuinely DISCARDS:
##   * the world's parts inside any room's box (the world does not show through a room),
##   * a room's parts outside its own box (a room's content is cut off at its walls),
##   * and leaves a part that was told to ignore rooms (the design table's copy) alone.
## Two rooms at once (the loop over slots), a room that moves (the texture is updated in place), a removed room (its content disappears, the world
## comes back through the hole) and no rooms at all (everything back to normal) are all checked.
## Run: xvfb-run -a "$GODOT" --path . --script res://tests/room_clip_render.gd

const RoomVolume := preload("res://scripts/room/room_volume.gd")
const RoomRegistry := preload("res://scripts/room/room_registry.gd")
const RoomClip := preload("res://scripts/room/room_clip.gd")
const ClipShader := preload("res://shaders/section_clip.gdshader")

var viewport: SubViewport


func slab(y: float, colour: Color) -> MeshInstance3D:
	## A thin slab 8 m wide (x -4..4), 0.5 m tall, facing the camera, centred on height y.
	var part := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(8, 0.5, 0.1)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = colour
	box.material = mat
	part.mesh = box
	part.position = Vector3(0, y, 0)
	viewport.add_child(part)
	return part


func px(x: float, y: float) -> Color:
	## The rendered colour at world (x, y): the orthographic camera shows 10 m over 100 px, centred on the origin.
	var img: Image = viewport.get_texture().get_image()
	return img.get_pixel(int(50.0 + x * 10.0), int(50.0 - y * 10.0))


func lit(x: float, y: float) -> bool:
	return px(x, y).r > 0.3


func dark(x: float, y: float) -> bool:
	return px(x, y).r < 0.1


func frames() -> void:
	for i in 4:
		await process_frame


func _initialize() -> void:
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
	world_env.environment = env
	viewport.add_child(world_env)
	var camera := Camera3D.new()
	camera.current = true
	camera.position = Vector3(0, 0, 5)
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 10.0
	viewport.add_child(camera)
	var light := DirectionalLight3D.new()
	light.light_energy = 3.0
	light.rotation_degrees = Vector3(-40, -30, 0)
	viewport.add_child(light)

	var world_slab := slab(1.0, Color(1, 1, 1)) # the world, y = 0.75..1.25 (pixel row 40)
	var room_a_slab := slab(-1.0, Color(1, 1, 1)) # room A's content, row 60
	var room_b_slab := slab(-2.5, Color(1, 1, 1)) # room B's content, row 75
	var ignoring := slab(2.25, Color(1, 1, 1)) # a part that ignores rooms, row 27 (inside both rooms' height)
	var ignoring_mat := ShaderMaterial.new()
	ignoring_mat.shader = ClipShader
	ignoring_mat.set_shader_parameter("albedo_color", Color(1, 1, 1))
	ignoring.material_override = ignoring_mat # room_slot stays at its default, -2
	var parts := [world_slab, room_a_slab, room_b_slab] # the arena's parts; `ignoring` (the table's copy, say) is never handed to reconcile

	await frames()
	print("SMOKE calibration, no rooms: every slab is lit across its whole width: ", lit(-3, 1) and lit(0, 1) and lit(3.5, 1) and lit(0, -1) and lit(-3, -2.5))

	# two rooms: A is x -1..3, B is x -4..-2 (both tall: y -3..3, deep: z -1..1)
	var room_a := RoomVolume.make(Transform3D(Basis.IDENTITY, Vector3(1, 0, 0)), Vector3(4, 6, 2))
	var room_b := RoomVolume.make(Transform3D(Basis.IDENTITY, Vector3(-3, 0, 0)), Vector3(2, 6, 2))
	RoomRegistry.clear()
	var slot_a := RoomRegistry.add_room(room_a)
	var slot_b := RoomRegistry.add_room(room_b)
	room_a_slab.set_meta(RoomRegistry.META, slot_a)
	room_b_slab.set_meta(RoomRegistry.META, slot_b)
	RoomClip.reconcile(parts)
	await frames()
	print("SMOKE the world is cut away inside room A and inside room B: ", dark(0, 1) and dark(2.5, 1) and dark(-3, 1))
	print("SMOKE the world shows between and outside the rooms: ", lit(-1.5, 1) and lit(3.5, 1))
	print("SMOKE room A's content shows inside A, and is cut at A's walls: ", lit(0, -1) and lit(2.5, -1) and dark(-1.5, -1) and dark(3.5, -1) and dark(-3, -1))
	print("SMOKE room B's content shows inside B only (not in A, not outside): ", lit(-3, -2.5) and dark(0, -2.5) and dark(3.5, -2.5) and dark(-1.5, -2.5))
	print("SMOKE a part told to ignore rooms is untouched, inside and outside both: ", lit(-3, 2.25) and lit(0, 2.25) and lit(3.5, 2.25))

	# a room that moves: the texture is updated in place, nothing is rebuilt
	room_a.xform = Transform3D(Basis.IDENTITY, Vector3(3, 0, 0)) # A is now x 1..5
	RoomRegistry.push()
	await frames()
	print("SMOKE moving room A moves its window: the world is cut at x 2 and shows at x 0, A's content shows at x 2 and not at x 0: ", dark(2, 1) and lit(0, 1) and lit(2, -1) and dark(0, -1))

	# a removed room: the world comes back through the hole, and its content is gone (not left floating, not drawn anywhere)
	RoomRegistry.remove_room(room_b)
	await frames()
	print("SMOKE removing room B: the world shows where B was, and B's orphaned content is cut everywhere: ", lit(-3, 1) and dark(-3, -2.5) and dark(0, -2.5))

	# no rooms: back to normal; reconcile hands the parts their own materials back
	RoomRegistry.clear()
	RoomClip.reconcile(parts)
	await frames()
	print("SMOKE with no rooms left the world's slab is lit across its width again and wears its own material: ", lit(-3, 1) and lit(0, 1) and lit(3.5, 1) and world_slab.material_override == null)
	quit()
