extends SceneTree
## NEEDS A REAL RENDER, not --headless (run under Xvfb + Mesa like tests/section_render.gd):
##   xvfb-run -a "$GODOT" --path . --script res://tests/appearance_clip_render.gd
## Painted looks survive the clip shader (scripts/clip_look.gd): the real backend glb split by appearance
## (tests/fixtures/appearance_split.glb: two boxes, the second #E63946 at opacity 0.5) wrapped by the real section_tool.gd still
## draws the painted box red and see-through and the other plain, the plane still cuts, and a one-look repaint while sectioning
## (blue, glowing) draws in the clip material too. tests/clip_look.gd checks the bookkeeping headless; this is the pixels.

const MeshIdentity := preload("res://scripts/mesh_identity.gd")
const Look := preload("res://scripts/appearance/appearance_look.gd")
const SectionTool := preload("res://scripts/section_tool.gd")
const ClipLook := preload("res://scripts/clip_look.gd")


func _frames(n: int = 6) -> void:
	for i in n:
		await process_frame


func _initialize() -> void:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(128, 64)
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
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 50.0 # 50 units tall, 100 wide
	camera.position = Vector3(20, 5, 60)
	viewport.add_child(camera)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-30, -20, 0)
	viewport.add_child(light)

	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	doc.append_from_buffer(FileAccess.get_file_as_bytes("res://tests/fixtures/appearance_split.glb"), "", state)
	var scene := doc.generate_scene(state)
	MeshIdentity.tag_scene(state, scene)
	viewport.add_child(scene)
	var part: MeshInstance3D = scene.get_child(0) if scene.get_child_count() > 0 else scene as MeshInstance3D

	var tool := SectionTool.new()
	root.add_child(tool)
	await process_frame
	tool.set_active(true, null)
	# The plane at x = 20 (between the boxes), keeping x > 20 (the painted box) - as tests/section_render.gd aims it.
	tool.gizmo().global_transform = Transform3D(Basis.looking_at(Vector3(1, 0, 0), Vector3.UP), Vector3(20, 0, 0))
	tool.reconcile([part])
	print("SMOKE the split part is wrapped surface by surface: ", ClipLook.surfaces_wrapped(part))

	RenderingServer.global_shader_parameter_set("section_enabled", false)
	await _frames()
	var img: Image = viewport.get_texture().get_image()
	var plain := img.get_pixel(45, 32) # the box at x 0..10
	var painted := img.get_pixel(83, 32) # the box at x 30..40, red at half opacity
	print("SMOKE wrapped, the painted body still draws red: ", painted.r > painted.g * 2.0 and painted.r > painted.b * 2.0, " (", painted, ")")
	print("SMOKE ...and see-through (its red under 0.75 over black): ", painted.r < 0.75)
	print("SMOKE wrapped, the unpainted body draws plain (grey-white, not red): ", plain.r > 0.3 and absf(plain.r - plain.g) < 0.08 and absf(plain.g - plain.b) < 0.08, " (", plain, ")")

	tool.set_flipped(false) # the plane back on
	await _frames()
	img = viewport.get_texture().get_image()
	plain = img.get_pixel(45, 32)
	painted = img.get_pixel(83, 32)
	print("SMOKE clipped: the cut-away plain box goes to background: ", plain.r < 0.1 and plain.g < 0.1, " (", plain, ")")
	print("SMOKE clipped: the kept painted box still draws red: ", painted.r > painted.g * 2.0 and painted.r > 0.1, " (", painted, ")")

	tool.set_flipped(true)
	# a one-look repaint while sectioning: blue and glowing, wrapped again by reconcile
	Look.restyle(part, {}, {"colour": "#3498DB", "emission": "#3498DB", "emission_strength": 1.0})
	tool.reconcile([part])
	print("SMOKE a one-look repaint is wrapped in the clip material: ", ClipLook.is_clip(part.material_override))
	await _frames()
	img = viewport.get_texture().get_image()
	plain = img.get_pixel(45, 32)
	painted = img.get_pixel(83, 32)
	print("SMOKE flipped: the kept box draws blue: ", plain.b > plain.r * 1.5 and plain.b > 0.2, " (", plain, ")")
	print("SMOKE flipped: the other box is cut away: ", painted.b < 0.1 and painted.r < 0.1, " (", painted, ")")

	tool.set_active(false)
	await _frames()
	img = viewport.get_texture().get_image()
	print("SMOKE off: both boxes draw blue again: ", img.get_pixel(45, 32).b > 0.2 and img.get_pixel(83, 32).b > 0.2)
	tool.free()
	quit()
