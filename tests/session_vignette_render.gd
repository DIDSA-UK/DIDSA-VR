extends SceneTree
## NEEDS A REAL RENDER, not --headless (run under Xvfb + Mesa like tests/section_render.gd):
##   xvfb-run -a "$GODOT" --path . --script res://tests/session_vignette_render.gd
## The comfort vignette (scripts/session/comfort_vignette.gd, shaders/comfort_vignette.gdshader) really draws: over a white view, strength 0 leaves every pixel white (and the node is hidden),
## strength 1 darkens the corners and leaves the middle white, a half strength darkens the corners less than a full one, and the dark is the same on a camera turned or moved (it is on the screen,
## not in the world). Whether it is COMFORTABLE, how fast it should close, and how it looks in two eyes: the owner's, on a headset.

const Vignette := preload("res://scripts/session/comfort_vignette.gd")


func _check(ok: bool, label: String) -> void:
	print("SMOKE ", label, ": ", ok)


func _initialize() -> void:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(96, 96)
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var world_env := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(1, 1, 1)
	world_env.environment = env
	viewport.add_child(world_env)
	var camera := Camera3D.new()
	camera.current = true
	viewport.add_child(camera)
	var vignette := Vignette.new()
	camera.add_child(vignette)
	await process_frame
	await process_frame
	var clear: Image = viewport.get_texture().get_image()
	_check(clear.get_pixel(1, 1).r > 0.95 and clear.get_pixel(48, 48).r > 0.95, "strength 0: the view is untouched (white corner, white middle)")
	_check(not vignette.visible, "...and the node is not drawn at all")
	vignette.strength = 1.0
	await process_frame
	await process_frame
	var full: Image = viewport.get_texture().get_image()
	_check(full.get_pixel(1, 1).r < 0.3 and full.get_pixel(94, 94).r < 0.3 and full.get_pixel(1, 94).r < 0.3, "strength 1: all four corners are dark (%.2f)" % full.get_pixel(1, 1).r)
	_check(full.get_pixel(48, 48).r > 0.95, "...and the middle of the view is still white (%.2f)" % full.get_pixel(48, 48).r)
	vignette.strength = 0.5
	await process_frame
	await process_frame
	var half: Image = viewport.get_texture().get_image()
	_check(half.get_pixel(1, 1).r > full.get_pixel(1, 1).r + 0.1 and half.get_pixel(1, 1).r < 0.95 and half.get_pixel(48, 48).r > 0.95, "strength 0.5: the corner is darker than clear and lighter than full, the middle white (%.2f)" % half.get_pixel(1, 1).r)
	vignette.strength = 1.0
	camera.rotation_degrees = Vector3(20, 70, 0)
	camera.position = Vector3(5, 2, 3)
	await process_frame
	await process_frame
	var turned: Image = viewport.get_texture().get_image()
	_check(absf(turned.get_pixel(1, 1).r - full.get_pixel(1, 1).r) < 0.05 and turned.get_pixel(48, 48).r > 0.95, "turn and move the camera: the same vignette (it is on the screen)")
	vignette.strength = 0.0
	await process_frame
	await process_frame
	var gone: Image = viewport.get_texture().get_image()
	_check(gone.get_pixel(1, 1).r > 0.95, "back to 0: the corners are white again")
	quit()
