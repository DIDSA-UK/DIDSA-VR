extends SceneTree
## NEEDS A REAL RENDER, not --headless (see tests/section_render.gd for the
## Xvfb + llvmpipe recipe). Regression test for the real-headset "the section
## tool makes the model disappear as the plane passes its centre" bug:
## shaders/section_clip.gdshader used MODEL_MATRIX * VERTEX inside fragment(),
## where VERTEX is VIEW-space, so under this app's real transform (assembly
## root scaled 0.001, offset from the origin, a camera that isn't sitting at
## the origin) every fragment collapsed to ~the model's origin and the clip
## became all-or-nothing. tests/section_render.gd can't see that — its part
## has an identity transform and its camera looks straight down -Z, where
## view-space and world-space nearly coincide.
##
## Here the part is a mm-scale box under a 0.001-scaled, offset parent (exactly
## like main.gd's assembly_root), viewed from a camera that is also moved, and
## the plane is placed at three fractions of the wall. A correct clip keeps a
## proportional strip of pixels each time (~75%/50%/25%); the bug keeps all or
## none. Run:
##   xvfb-run -a "$GODOT" --path . --script res://tests/section_render_transformed.gd

const SectionTool := preload("res://scripts/section_tool.gd")


func _lit_columns(img: Image) -> int:
	var n := 0
	for x in img.get_width():
		if img.get_pixel(x, 32).r > 0.3:
			n += 1
	return n


func _initialize() -> void:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(64, 64)
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

	# Camera well away from the origin, ortho, looking down -Z: world x spans 2 +/- 5.
	var camera := Camera3D.new()
	camera.current = true
	camera.position = Vector3(2, 1, 2)
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 10.0
	viewport.add_child(camera)

	var light := DirectionalLight3D.new()
	light.light_energy = 3.0
	light.rotation_degrees = Vector3(-40, -30, 0)
	viewport.add_child(light)

	# Like main.gd's assembly_root: mm geometry, 0.001 scale, offset from the origin.
	var assembly_root := Node3D.new()
	assembly_root.transform = Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * 0.001), Vector3(2, 1, -3))
	viewport.add_child(assembly_root)
	var part := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(8000, 8000, 10) # 8 m wide once scaled: world x = -2..6
	part.mesh = box
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1, 1, 1)
	box.surface_set_material(0, mat)
	assembly_root.add_child(part)

	var tool := SectionTool.new()
	root.add_child(tool)
	await process_frame
	tool.set_active(true, null)
	tool.reconcile([part])

	var results := {}
	# Plane at world x = 0, 2, 4 -> kept wall x-range 6, 4, 2 of 8 m -> ~38/26/13 lit columns of 64 (51 px wall = 8 of 10 m).
	for plane_x in [0.0, 2.0, 4.0]:
		tool.gizmo().global_transform = Transform3D(Basis.looking_at(Vector3(1, 0, 0), Vector3.UP), Vector3(plane_x, 1, -3))
		tool.set_flipped(false) # forces a full _update_global_plane() from the new gizmo pose
		for i in 4:
			await process_frame
		results[plane_x] = _lit_columns(viewport.get_texture().get_image())
	print("calibration — lit columns at plane x=0/2/4: ", results[0.0], "/", results[2.0], "/", results[4.0], " (expect ~38/26/13)")
	print("SMOKE section clip is proportional under a scaled+offset model and a moved camera (x=0 ~38): ", absi(results[0.0] - 38) <= 5)
	print("SMOKE section clip is proportional (x=2 ~26): ", absi(results[2.0] - 26) <= 5)
	print("SMOKE section clip is proportional (x=4 ~13): ", absi(results[4.0] - 13) <= 5)

	part.free()
	tool.free()
	quit()
