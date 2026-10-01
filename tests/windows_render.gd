extends SceneTree
## NEEDS A REAL RENDER, not --headless (Xvfb + llvmpipe, same recipe as
## tests/section_render.gd):
##   WINDOWS_RENDER_DIR=/tmp/lab xvfb-run -a "$GODOT" --path . --script res://tests/windows_render.gd
## Opens the Calculator window and the FULL popup keyboard in the real scene (their redesigned
## chrome: theme panel, icon close button, accent confirm key, handle pill, corner brackets) and
## renders them from eye height; $WINDOWS_RENDER_DIR gets windows_scene.png. Checks both draw.
## GL-compatibility render, not the project's mobile renderer: a layout smoke test.

func _initialize() -> void:
	DisplayServer.window_set_size(Vector2i(1280, 720))
	var main: Node = load("res://scenes/main.tscn").instantiate()
	main.secrets_file_path = "res://__nonexistent__.cfg"
	root.add_child(main)
	await process_frame
	var origin: XROrigin3D = main.get_node("XROrigin3D")
	var eye := Camera3D.new()
	eye.fov = 75.0
	main.add_child(eye)
	eye.make_current()
	eye.global_position = Vector3(0.0, 1.5, 0.3)
	eye.look_at(Vector3(0.0, 1.0, -0.5))
	origin.get_node("XRCamera3D").global_position = eye.global_position
	origin.get_node("XRCamera3D").global_rotation = eye.global_rotation
	for i in 3:
		await process_frame
	main._calculator_window.open()
	main._calculator_window.global_position += Vector3(-0.15, 0.1, 0.0)
	main.open_keyboard_for("", func(_t: String) -> void: pass, {"mode": "full", "title": "Web address"})
	for i in 8:
		await process_frame
	var dir := OS.get_environment("WINDOWS_RENDER_DIR")
	var img := root.get_texture().get_image()
	if dir != "":
		img.save_png(dir.path_join("windows_scene.png"))
	var lit := 0
	for y in range(0, img.get_height(), 8):
		for x in range(0, img.get_width(), 8):
			if img.get_pixel(x, y).get_luminance() > 0.04:
				lit += 1
	print("SMOKE the window and the keyboard draw into the 3D view: ", lit > 300)
	# The distance-grab glow, on the keyboard (fully in view): a laser on it (hover), then carried (brighter).
	var hand: XRController3D = origin.get_node("RightController")
	var kbh = main._keyboard.handle
	var fake_laser := Node.new() # a stand-in laser: the real right controller would (rightly) clear the hover every frame, it isn't aimed here
	kbh.set_hover(fake_laser, true)
	for i in 4:
		await process_frame
	if dir != "":
		root.get_texture().get_image().save_png(dir.path_join("windows_scene_glow_hover.png"))
	var hover_img := root.get_texture().get_image()
	kbh.set_hover(fake_laser, false)
	kbh.start_laser_grab(hand) # carried: the hand stays put, so the keyboard stays where it is
	for i in 4:
		await process_frame
	if dir != "":
		root.get_texture().get_image().save_png(dir.path_join("windows_scene_glow_held.png"))
	var held_img := root.get_texture().get_image()
	kbh.clear()
	var sum_plain := 0.0; var sum_hover := 0.0; var sum_held := 0.0
	for y in range(0, img.get_height(), 4):
		for x in range(0, img.get_width(), 4):
			sum_plain += img.get_pixel(x, y).get_luminance()
			sum_hover += hover_img.get_pixel(x, y).get_luminance()
			sum_held += held_img.get_pixel(x, y).get_luminance()
	print("SMOKE the halo shader draws: the scene is brighter hovered than plain, and brighter again when carried: ", sum_hover > sum_plain and sum_held > sum_hover)
	quit()
