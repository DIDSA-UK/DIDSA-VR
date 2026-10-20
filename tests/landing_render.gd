extends SceneTree
## NEEDS A REAL RENDER, not --headless (Xvfb + llvmpipe, same recipe as tests/tablet_render.gd):
##   LANDING_RENDER_DIR=/tmp/lab xvfb-run -a "$GODOT" --path . --script res://tests/landing_render.gd
## The landing as pixels, from where the user's eyes are: the launcher at arm's reach with its tiles and the connection pill, the tips
## reel to its left, the DIDSA logo 2.5 m ahead (its porthole brighter at the top of its pulse than at rest), the rocket garden's
## tallest rocket drawn far away and the others beside it. $LANDING_RENDER_DIR gets landing_scene.png, landing_logo.png (rest and
## pulse side by side) and landing_garden.png. GL-compatibility render, not the project's mobile renderer, so this is a layout and
## "is it really drawn" test: not colour calibration, and not a frame rate (the garden's cost on a Quest is not measured).

var main
var eye: Camera3D


func check(what: String, ok: bool) -> void:
	print("SMOKE ", what, ": ", ok)


func lit_in(img: Image, rect: Rect2i, threshold: float, brighter_than_bg: bool = true) -> int:
	## How many sampled pixels in `rect` differ from the backdrop (the Mid scene's grey, luminance about 0.1 once lit).
	var count := 0
	for y in range(maxi(rect.position.y, 0), mini(rect.end.y, img.get_height()), 3):
		for x in range(maxi(rect.position.x, 0), mini(rect.end.x, img.get_width()), 3):
			var lum := img.get_pixel(x, y).get_luminance()
			if lum > threshold if brighter_than_bg else lum < threshold:
				count += 1
	return count


func around(point: Vector3, half: int) -> Rect2i:
	var screen := eye.unproject_position(point)
	return Rect2i(int(screen.x) - half, int(screen.y) - half, half * 2, half * 2)


func _initialize() -> void:
	DisplayServer.window_set_size(Vector2i(1280, 720))
	OS.set_environment("DIDSA_SETTINGS_PATH", "user://settings_landing_render.cfg")
	OS.set_environment("DIDSA_RECENT_PATH", "user://recent_landing_render.cfg")
	main = load("res://scenes/main.tscn").instantiate()
	main.secrets_file_path = "res://__nonexistent__.cfg"
	main.landing_enabled = true
	root.add_child(main)
	await process_frame
	var origin: XROrigin3D = main.get_node("XROrigin3D")
	var xr_camera: XRCamera3D = origin.get_node("XRCamera3D")
	xr_camera.position = Vector3(0.0, 1.6, 0.0)
	eye = Camera3D.new()
	eye.fov = 75.0
	main.add_child(eye)
	eye.make_current()
	eye.global_position = Vector3(0.0, 1.6, 0.0)
	for i in 4:
		await process_frame
	var landing = main.landing
	landing.enter()
	var waited := 0
	while not landing.garden.is_built and waited < 600:
		await process_frame
		waited += 1
	for i in 10:
		await process_frame
	var dir := OS.get_environment("LANDING_RENDER_DIR")

	# --- the whole landing, looking straight ahead ------------------------------------------------------------------------
	var img := root.get_texture().get_image()
	if dir != "":
		img.save_png(dir.path_join("landing_scene.png"))
	var launcher = landing.launcher
	var launcher_rect := Rect2i(around(launcher.global_position + Vector3(-0.3, 0.2, 0.0), 4).position, Vector2i(300, 150))
	check("the launcher panel draws (its rect is lit)", lit_in(img, around(launcher.global_position, 60), 0.04) > 200)
	check("the launcher's tile grid draws below the pill (many lit samples)", lit_in(img, Rect2i(launcher_rect.position + Vector2i(0, 60), Vector2i(320, 180)), 0.05) > 300)
	check("the tips reel draws to the left of the launcher", landing.reel.global_position.x < launcher.global_position.x and lit_in(img, around(landing.reel.global_position, 50), 0.04, false) > 300) # its dark navy panel against the grey backdrop
	var logo = landing.logo
	var logo_lit := lit_in(img, around(logo.global_position, 70), 0.5)
	check("the logo draws near-white at 2.5 m ahead", logo_lit > 60)
	var left_rect := around(logo.global_position, 70)
	check("the logo is centred in the view", absf(eye.unproject_position(logo.global_position).x - 640.0) < 5.0)
	check("the logo is above the garden's ground line (eye height, not on the floor)", eye.unproject_position(logo.global_position).y < eye.unproject_position(Vector3(0.0, 0.0, -2.5)).y)

	# --- the logo, close, at rest and at the top of its pulse -----------------------------------------------------------------
	landing.launcher.close()
	landing.reel.close()
	landing.garden.visible = false
	eye.global_position = Vector3(0.0, 1.6, -1.1) # 1.4 m from the logo
	eye.fov = 50.0
	logo.set_clock(0.0)
	for i in 4:
		await process_frame
	var rest := root.get_texture().get_image()
	var porthole_world: Vector3 = logo.porthole.global_transform * logo.porthole.get_aabb().get_center()
	var port_rect := around(porthole_world, 14)
	logo.set_clock(1.3)
	for i in 4:
		await process_frame
	var pulse := root.get_texture().get_image()
	var combined := Image.create(rest.get_width() * 2, rest.get_height(), false, rest.get_format())
	combined.blit_rect(rest, Rect2i(Vector2i.ZERO, rest.get_size()), Vector2i.ZERO)
	combined.blit_rect(pulse, Rect2i(Vector2i.ZERO, pulse.get_size()), Vector2i(rest.get_width(), 0))
	if dir != "":
		combined.save_png(dir.path_join("landing_logo.png"))
	var rest_lit := lit_in(rest, port_rect, 0.35)
	var pulse_lit := lit_in(pulse, port_rect, 0.35)
	print("SMOKE porthole lit samples: rest ", rest_lit, " pulse ", pulse_lit)
	check("the porthole is brighter and larger at the top of its pulse than at rest", pulse_lit > rest_lit)
	check("the whole wordmark draws (the middle band is lit)", lit_in(rest, Rect2i(int(eye.unproject_position(logo.global_position).x) - 150, int(eye.unproject_position(logo.global_position).y) + 40, 300, 90), 0.5) > 100)
	logo.set_clock(0.0)

	# --- the garden --------------------------------------------------------------------------------------------------------------
	landing.garden.visible = true
	logo.visible = false
	eye.fov = 90.0
	eye.global_position = Vector3(0.0, 1.6, 0.0)
	eye.look_at(Vector3(0.0, 40.0, -60.0), Vector3.UP)
	for i in 6:
		await process_frame
	var garden_img := root.get_texture().get_image()
	if dir != "":
		garden_img.save_png(dir.path_join("landing_garden.png"))
	var saturn: Dictionary = {}
	for e in landing.garden.entries:
		if e["id"] == "Saturn_V":
			saturn = e
	var base: Vector3 = saturn["node"].global_position
	var top: Vector3 = base + Vector3(0.0, saturn["height"], 0.0)
	var base_px := eye.unproject_position(base)
	var top_px := eye.unproject_position(top)
	print("SMOKE saturn base px ", base_px, " top px ", top_px)
	check("Saturn V at 60 m is in view, base on the ground and top above it", top_px.y < base_px.y - 150.0 and top_px.y > -50.0 and base_px.x > 0.0 and base_px.x < 1280.0)
	var mid := base.lerp(top, 0.5)
	check("Saturn V's body is drawn (lit, against the ground and sky)", lit_in(garden_img, around(mid, 12), 0.3) + lit_in(garden_img, around(mid, 12), 0.04, false) > 40)
	var plates_visible := 0
	for e in landing.garden.entries:
		if eye.is_position_in_frustum(e["plate"].global_position):
			plates_visible += 1
	check("name plates are in view for the rockets in front of the user", plates_visible >= 3)
	var distinct := {}
	for y in range(0, garden_img.get_height(), 12):
		for x in range(0, garden_img.get_width(), 12):
			distinct[garden_img.get_pixel(x, y).to_html(false)] = true
	check("the garden view is not a flat colour", distinct.size() > 40)

	DirAccess.remove_absolute("user://settings_landing_render.cfg")
	DirAccess.remove_absolute("user://recent_landing_render.cfg")
	quit()
