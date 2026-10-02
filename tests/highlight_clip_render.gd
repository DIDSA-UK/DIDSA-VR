extends SceneTree
## NEEDS A REAL RENDER, not --headless (Xvfb + llvmpipe, same recipe as tests/section_render.gd):
##   xvfb-run -a "$GODOT" --path . --script res://tests/highlight_clip_render.gd
## The Mates / Measure highlight (shaders/highlight_clip.gdshader) is clipped by the section plane exactly like the
## part: a lit quad is drawn in front of a camera with the global section plane through its middle; the half on the
## cut-away side must NOT be drawn (background shows), the kept half must be lit, and with sectioning off the whole
## quad is lit again. GL-compatibility render, not the project's mobile renderer.

func _initialize() -> void:
	DisplayServer.window_set_size(Vector2i(640, 360))
	var main: Node = load("res://scenes/main.tscn").instantiate() # registers the global section parameters
	main.secrets_file_path = "res://__nonexistent__.cfg"
	root.add_child(main)
	await process_frame
	var fh = main.face_highlight
	var quad := MeshInstance3D.new()
	var qm := QuadMesh.new()
	qm.size = Vector2(2.0, 2.0)
	quad.mesh = qm
	quad.material_override = fh._make_material(Color(1.0, 0.0, 0.0, 1.0))
	main.add_child(quad)
	quad.global_position = Vector3(0, 1.5, -3.0)
	var eye := Camera3D.new()
	main.add_child(eye)
	eye.make_current()
	eye.global_position = Vector3(0, 1.5, 0)
	eye.look_at(Vector3(0, 1.5, -3), Vector3.UP)
	RenderingServer.global_shader_parameter_set("section_plane_origin", Vector3(0, 1.5, -3.0))
	RenderingServer.global_shader_parameter_set("section_plane_normal", Vector3(1, 0, 0)) # keeps x > 0
	RenderingServer.global_shader_parameter_set("section_enabled", true)
	for i in 4:
		await process_frame
	await RenderingServer.frame_post_draw
	var img := root.get_viewport().get_texture().get_image()
	var w := img.get_width()
	var h := img.get_height()
	var left := img.get_pixel(int(w * 0.46), int(h * 0.5))
	var right := img.get_pixel(int(w * 0.54), int(h * 0.5))
	var is_red := func(c: Color) -> bool: return c.r > 0.6 and c.g < 0.3 and c.b < 0.3
	print("SMOKE with a section plane through it, the highlight on the cut-away half is NOT drawn: ", not is_red.call(left))
	print("SMOKE ...and the kept half still is: ", is_red.call(right))
	RenderingServer.global_shader_parameter_set("section_enabled", false)
	for i in 3:
		await process_frame
	await RenderingServer.frame_post_draw
	img = root.get_viewport().get_texture().get_image()
	print("SMOKE with sectioning off the whole highlight is drawn again: ", is_red.call(img.get_pixel(int(w * 0.46), int(h * 0.5))) and is_red.call(img.get_pixel(int(w * 0.54), int(h * 0.5))))
	quit()
