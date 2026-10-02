extends SceneTree
## NEEDS A REAL RENDER, not --headless (Xvfb + llvmpipe, same recipe as
## tests/section_render.gd):
##   TABLET_RENDER_DIR=/tmp/lab xvfb-run -a "$GODOT" --path . --script res://tests/tablet_render.gd
## Opens the redesigned tablet in the real scene, goes to Assembly > Mates, and renders it
## from where a user's eyes would be, saving PNGs ($TABLET_RENDER_DIR) so the 3D result
## — quad, tilt, the angled side list, the hand badge — can be eyeballed. Checks the
## panel is actually drawn (not blank) and the side panel appears when Mates is shown.
## GL-compatibility render, not the project's mobile renderer: a layout smoke test.

func _initialize() -> void:
	DisplayServer.window_set_size(Vector2i(1280, 720))
	var main: Node = load("res://scenes/main.tscn").instantiate()
	main.secrets_file_path = "res://__nonexistent__.cfg"
	root.add_child(main)
	await process_frame
	var origin: XROrigin3D = main.get_node("XROrigin3D")
	var cam: XRCamera3D = origin.get_node("XRCamera3D")
	var l: XRController3D = origin.get_node("LeftController")
	var r: XRController3D = origin.get_node("RightController")
	l.position = Vector3(-0.15, 1.0, -0.35)
	r.position = Vector3(0.25, 1.2, -0.3)
	# A plain Camera3D at roughly eye height, looking down at the wrist (the XRCamera3D's pose is the
	# XR server's, so it isn't used for the picture).
	var eye := Camera3D.new()
	eye.fov = 70.0
	main.add_child(eye)
	eye.make_current()
	eye.global_position = Vector3(0.25, 1.45, 0.25)
	eye.look_at(Vector3(0.0, 1.0, -0.35))
	var tab = l.get_node("WristTablet")
	for i in 3:
		await process_frame
	tab.open_tablet()
	tab.ui.select_category("assembly")
	tab.ui.select_tool("mates", true)
	await create_timer(0.8).timeout # let the open / unfold / fade-in animations finish
	var dir := OS.get_environment("TABLET_RENDER_DIR")
	var img := root.get_texture().get_image()
	if dir != "":
		img.save_png(dir.path_join("tablet_scene.png"))
	var lit := 0
	for y in range(0, img.get_height(), 8):
		for x in range(0, img.get_width(), 8):
			if img.get_pixel(x, y).get_luminance() > 0.05:
				lit += 1
	var side_ok: bool = tab._side_open and tab.badge.visible # captured now: opening Settings below closes the side panel
	# Second shot: the Settings page scrolled to Comfort (Reduce motion, Sound, Volume, Haptics).
	tab.ui.set_settings_open(true)
	await create_timer(0.5).timeout
	var sound_btn: Button = null
	for b in tab.ui.find_children("*", "Button", true, false):
		if b.text.begins_with("Sound:"):
			sound_btn = b
	tab.ui.pages_scroll.ensure_control_visible(sound_btn)
	tab.ui.pages_scroll.scroll_vertical += 120
	eye.global_position = Vector3(0.0, 1.45, 0.05)
	eye.look_at(Vector3(0.0, 1.0, -0.33))
	await create_timer(0.5).timeout
	if dir != "":
		root.get_texture().get_image().save_png(dir.path_join("tablet_settings.png"))
	print("SMOKE the Settings page has Sound and Volume controls in Comfort: ", sound_btn != null)
	print("SMOKE the tablet draws something into the 3D view: ", lit > 200)
	print("SMOKE the side panel is up while Mates is shown, the badge is on the right hand: ", side_ok)
	quit()
