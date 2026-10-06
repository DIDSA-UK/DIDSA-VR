extends SceneTree
## NEEDS A REAL RENDER (Xvfb), not --headless: the sketch-window clip (scripts/design_table/sketch_clip.gd, shaders/clip_common.gdshaderinc)
## really discards fragments outside the box on the table's copy and its edge lines, leaves an arena part (switch off) whole, and goes away on end().
##   xvfb-run -a "$GODOT" --path . --script res://tests/sketch_clip_render.gd
## Two wide walls side by side in a 64 px orthographic view (the "copy", flagged, on the left half of the image's height; a plain "arena part" below it),
## the box set to a window in the middle of the picture. Pixels inside the box are lit, outside are background; the arena part is lit everywhere.

const SketchClip := preload("res://scripts/design_table/sketch_clip.gd")
const ViewModes := preload("res://scripts/view_modes.gd")


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
	world_env.environment = env
	viewport.add_child(world_env)
	var camera := Camera3D.new()
	camera.current = true
	camera.position = Vector3(0, 0, 5)
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 16.0 # 16 world units across 64 px: 4 px per unit
	viewport.add_child(camera)
	var light := DirectionalLight3D.new()
	light.light_energy = 3.0
	light.rotation_degrees = Vector3(-40, -30, 0)
	viewport.add_child(light)

	var modes := ViewModes.new()
	root.add_child(modes)
	modes.setup(null, ViewModes.Mode.SHADED_EDGES)

	# the "copy": a wide, thin wall across the top half (y 2..6), the "arena part": the same across the bottom half (y -6..-2)
	var copy := _wall(Vector3(0, 4, 0), viewport)
	var arena := _wall(Vector3(0, -4, 0), viewport)
	var window := SketchClip.new()
	window.begin(copy, modes)
	# the window: x -3..3 (a box 6 wide), y 0..8 (so the whole top wall's height), a sliver deep in z
	window.update(Vector3(0, 4, 0), Vector3.RIGHT, Vector3.UP, Vector3.BACK, Vector2(6.0, 8.0))
	for i in 12:
		await process_frame
	var img: Image = viewport.get_texture().get_image()
	print("calibration: ", px(img, 0, 4), px(img, 7, 4), px(img, 7, -4))
	print("SMOKE inside the window the copy is drawn: ", (px(img, 0, 4) as Color).r > 0.3 and (px(img, -2, 3) as Color).r > 0.3)
	print("SMOKE outside the window (to the side) the copy is cut away to the background: ", (px(img, 5, 4) as Color).r < 0.1 and (px(img, -6, 4) as Color).r < 0.1)
	print("SMOKE the arena part (switch off) is whole under the same global box: ", (px(img, 7, -4) as Color).r > 0.3 and (px(img, 0, -4) as Color).r > 0.3 and (px(img, -7, -4) as Color).r > 0.3)

	# the box moves with update(): slide the window to the right
	window.update(Vector3(6, 4, 0), Vector3.RIGHT, Vector3.UP, Vector3.BACK, Vector2(6.0, 8.0))
	for i in 4:
		await process_frame
	img = viewport.get_texture().get_image()
	print("SMOKE the box follows the window when it moves: ", (px(img, 0, 4) as Color).r < 0.1 and (px(img, 6, 4) as Color).r > 0.3)

	# depth: a box that is a sliver deep and sits behind the wall (the wall is z -0.1..0.1) cuts the whole copy
	window.update(Vector3(0, 4, 3), Vector3.RIGHT, Vector3.UP, Vector3.BACK, Vector2(40.0, 40.0))
	window.half = Vector3(20, 20, 0.5)
	RenderingServer.global_shader_parameter_set("window_clip_half", Vector3(20, 20, 0.5))
	for i in 4:
		await process_frame
	img = viewport.get_texture().get_image()
	print("SMOKE too far off the sketch plane (depth) is cut too: ", (px(img, 0, 4) as Color).r < 0.1)

	# edge lines: with a wide window the copy's edge lines show; with the box away from them they are cut with the faces
	window.update(Vector3(0, 4, 0), Vector3.RIGHT, Vector3.UP, Vector3.BACK, Vector2(40.0, 40.0))
	for i in 4:
		await process_frame
	img = viewport.get_texture().get_image()
	var edge_lit := false
	for x in range(8, 56):
		for y in range(21, 28): # the top wall's lower edge, y = 2 -> row 24
			var c: Color = img.get_pixel(x, y)
			if c.r < 0.25 and c.r > 0.02:
				edge_lit = true # a dark edge line over the lit face (the edge colour is 0.14 grey; the background is 0.0 black)
	print("SMOKE the copy's edge lines draw with a wide window: ", edge_lit)

	# end() removes the clip altogether
	window.update(Vector3(60, 4, 0), Vector3.RIGHT, Vector3.UP, Vector3.BACK, Vector2(2.0, 2.0))
	for i in 4:
		await process_frame
	img = viewport.get_texture().get_image()
	var cut_before := (px(img, 0, 4) as Color).r < 0.1
	window.end()
	for i in 4:
		await process_frame
	img = viewport.get_texture().get_image()
	print("SMOKE end() puts the copy back whole: ", cut_before and (px(img, 0, 4) as Color).r > 0.3 and (px(img, 7, 4) as Color).r > 0.3)
	quit()


func _wall(at: Vector3, parent: Node) -> MeshInstance3D:
	var part := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(16, 4, 0.2)
	part.mesh = box
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1, 1, 1)
	box.surface_set_material(0, mat)
	part.position = at
	parent.add_child(part)
	return part


func px(img: Image, x_world: float, y_world: float) -> Color:
	return img.get_pixel(int(32 + x_world * 4.0), int(32 - y_world * 4.0))
