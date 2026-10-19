extends SceneTree
## NEEDS A REAL RENDER, not --headless (run under Xvfb + Mesa like tests/section_render.gd):
##   xvfb-run -a "$GODOT" --path . --script res://tests/appearance_render.gd
## The one thing tests/appearance_glb.gd can't check: that the materials of a real backend glb split by appearance
## (tests/fixtures/appearance_split.glb: two boxes, the second #E63946 at opacity 0.5) really draw - the painted box red and
## see-through over the black background, the other one plain - and that appearance_look.gd's restyle (here: the plain box
## painted blue, metal) draws too.

const MeshIdentity := preload("res://scripts/mesh_identity.gd")
const Look := preload("res://scripts/appearance/appearance_look.gd")


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
	for i in 6:
		await process_frame
	var img: Image = viewport.get_texture().get_image()
	var plain := img.get_pixel(45, 32) # the box at x 0..10
	var painted := img.get_pixel(83, 32) # the box at x 30..40, red at half opacity
	print("SMOKE the painted body draws red: ", painted.r > painted.g * 2.0 and painted.r > painted.b * 2.0, " (", painted, ")")
	print("SMOKE ...and see-through: darker than an opaque red would be over black (its red under 0.75): ", painted.r < 0.75)
	print("SMOKE the unpainted body draws plain (grey-white, not red): ", plain.r > 0.3 and absf(plain.r - plain.g) < 0.08 and absf(plain.g - plain.b) < 0.08, " (", plain, ")")

	# restyle: the whole part one look (blue metal) - an override over both surfaces
	Look.restyle(part, {}, {"colour": "#3498DB", "metallic": 0.6, "roughness": 0.3})
	for i in 6:
		await process_frame
	img = viewport.get_texture().get_image()
	var blue_a := img.get_pixel(45, 32)
	var blue_b := img.get_pixel(83, 32)
	print("SMOKE a restyle to one look draws both boxes blue: ", blue_a.b > blue_a.r * 1.5 and blue_b.b > blue_b.r * 1.5, " (", blue_a, " ", blue_b, ")")
	quit()
