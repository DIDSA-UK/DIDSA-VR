extends SceneTree
## NEEDS A REAL RENDER, not --headless (Xvfb + Mesa): T2's start buttons as pixels. From the standing eye point the empty design table's "New part" and
## "Open part..." buttons are drawn (the picture differs from the same view with them put away) and both lie inside the view, side by side, on the table
## and not behind the deck. $EMPTY_START_RENDER_DIR gets empty_start_table.png. GL-compatibility render, so this is a layout test, not colour calibration;
## whether the buttons are the right size and reach on a headset is not something it can say.
## Run: EMPTY_START_RENDER_DIR=/tmp/lab xvfb-run -a "$GODOT" --path . --script res://tests/empty_start_render.gd

var main
var eye: Camera3D


func check(what: String, ok: bool) -> void:
	print("SMOKE ", what, ": ", ok)


func differs(img: Image, base: Image, rect: Rect2i, threshold: float) -> int:
	var count := 0
	for y in range(maxi(rect.position.y, 0), mini(rect.end.y, img.get_height()), 2):
		for x in range(maxi(rect.position.x, 0), mini(rect.end.x, img.get_width()), 2):
			if absf(img.get_pixel(x, y).get_luminance() - base.get_pixel(x, y).get_luminance()) > threshold:
				count += 1
	return count


func button_rect(sb: Node3D, name: String) -> Rect2i:
	## The button's on-screen rectangle: its corners on the panel (metres from the panel's middle) through the camera.
	var button: Control = sb.find_child(name, true, false)
	var px: float = sb._pixels_per_metre
	var centre_px: Vector2 = button.global_position + button.size * 0.5 # in the SubViewport's pixels
	var panel: Vector2 = sb.panel_size
	var local := Vector3((centre_px.x / px) - panel.x * 0.5, panel.y * 0.5 - (centre_px.y / px), 0.0)
	var half := Vector3(button.size.x / px * 0.5, button.size.y / px * 0.5, 0.0)
	var a: Vector2 = eye.unproject_position(sb.to_global(local - half))
	var b: Vector2 = eye.unproject_position(sb.to_global(local + half))
	return Rect2i(Vector2i(mini(int(a.x), int(b.x)), mini(int(a.y), int(b.y))), Vector2i(absi(int(b.x - a.x)), absi(int(b.y - a.y))))


func _initialize() -> void:
	DisplayServer.window_set_size(Vector2i(1280, 720))
	main = load("res://scenes/main.tscn").instantiate()
	main.secrets_file_path = "res://__nonexistent__.cfg"
	root.add_child(main)
	await process_frame
	var xr_camera: XRCamera3D = main.get_node("XROrigin3D/XRCamera3D")
	xr_camera.position = Vector3(0.0, 1.6, 0.0)
	eye = Camera3D.new()
	eye.fov = 75.0
	main.add_child(eye)
	eye.make_current()
	eye.global_position = Vector3(0.0, 1.6, 0.0)
	for i in 4:
		await process_frame
	var table = main.design_table
	table.open()
	for i in 12:
		await process_frame
	var sb = table.start_buttons
	check("the start buttons are open over the empty table", sb.is_open())
	var dir := OS.get_environment("EMPTY_START_RENDER_DIR")
	var with := root.get_texture().get_image()
	if dir != "":
		with.save_png(dir.path_join("empty_start_table.png"))
	var new_rect := button_rect(sb, "StartNew")
	var open_rect := button_rect(sb, "StartOpen")
	var view := Rect2i(0, 0, 1280, 720)
	check("both buttons are inside the view from the standing eye point", view.encloses(new_rect) and view.encloses(open_rect))
	check("New part is left of Open part..., side by side", new_rect.end.x <= open_rect.position.x + 4 and absi(new_rect.position.y - open_rect.position.y) < 20)
	check("each is a real laser target on screen (more than 60 x 30 pixels)", new_rect.size.x > 60 and new_rect.size.y > 30 and open_rect.size.x > 60 and open_rect.size.y > 30)
	sb.empty = false
	for i in 6:
		await process_frame
	var without := root.get_texture().get_image()
	check("the picture changes where the New part button is when the buttons are put away", differs(with, without, new_rect, 0.06) > 40)
	check("...and where Open part... is", differs(with, without, open_rect, 0.06) > 40)
	quit()
