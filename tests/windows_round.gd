extends SceneTree
## Headless checks for the 29 Sep 2026 floating-window round: the Image Viewer's
## picker -> full-window image -> Back flow and its scrolling picker, several
## Browser / Image Viewer windows open at once, close/back buttons that grow
## with the window, and the doubled resize-corner target. Boots main.tscn with
## NO backend. Writes (and removes) a few small PNGs in user://models.
## Run: "$GODOT" --headless --path . --script res://tests/windows_round.gd  (see tests/README.md)

var main
var r: XRController3D
const TEST_FILES := 26


func _initialize() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	main.secrets_file_path = "res://__nonexistent__.cfg"
	root.add_child(main)
	await process_frame
	var origin: XROrigin3D = main.get_node("XROrigin3D")
	r = origin.get_node("RightController")
	for i in 4:
		await process_frame

	# --- test images: enough that the picker list can't fit in the window
	DirAccess.make_dir_recursive_absolute("user://models")
	var written := []
	for i in TEST_FILES:
		var img := Image.create(64 + i, 32, false, Image.FORMAT_RGB8)
		img.fill(Color(0.2, 0.5 + 0.02 * i, 0.9))
		var path := "user://models/zz_windows_round_%02d.png" % i
		img.save_png(path)
		written.append(path)

	var viewer = main._image_viewer_window
	viewer.open()
	for i in 4:
		await process_frame
	print("SMOKE the Image Viewer opens on the picker, Back hidden: ", viewer.is_open() and viewer._picker_view.visible and not viewer._image_view.visible and not viewer._back_button.visible)
	print("SMOKE the picker lists every image: ", viewer._list_box.get_child_count() >= TEST_FILES)

	# --- the picker scrolls (long list), by the right thumbstick while the laser is on the window
	var scroll: ScrollContainer = viewer._picker_scroll
	var v_bar := scroll.get_v_scroll_bar()
	print("calibration — picker scroll range ", v_bar.max_value, " page ", v_bar.page)
	print("SMOKE the list is taller than the window (so it needs scrolling): ", v_bar.max_value > v_bar.page + 100.0)
	print("SMOKE the picker is the window's scroll target: ", viewer.scroll_target == scroll)
	viewer.scroll_by_stick(-1.0, 0.2) # stick pushed down
	print("SMOKE pushing the stick down scrolls the picker down: ", scroll.scroll_vertical > 100)
	var down: int = scroll.scroll_vertical
	viewer.scroll_by_stick(1.0, 0.1)
	print("SMOKE ...and up scrolls back: ", scroll.scroll_vertical < down)
	viewer.scroll_by_stick(-0.2, 1.0)
	var held: int = scroll.scroll_vertical
	viewer.scroll_by_stick(0.3, 1.0)
	print("SMOKE a light touch (inside the deadzone) doesn't scroll: ", scroll.scroll_vertical == held)
	viewer.scroll_by_stick(-1.0, 100.0)
	print("SMOKE the last entries are reachable (scrolled to the bottom): ", scroll.scroll_vertical + v_bar.page >= v_bar.max_value - 2.0)

	# --- pick an image: it fills the window, Back returns
	var first_button: Button = viewer._list_box.get_child(0)
	first_button.pressed.emit()
	for i in 4:
		await process_frame
	print("SMOKE picking an image switches to the image view (picker hidden, Back visible): ", viewer.is_showing_image() and viewer._image_view.visible and not viewer._picker_view.visible and viewer._back_button.visible)
	print("SMOKE the title becomes the file name: ", viewer._title_label.text.begins_with("zz_windows_round_"))
	var tr: TextureRect = viewer._texture_rect
	var content: Vector2 = viewer._content_holder.size
	print("calibration — image area ", tr.size, " inside content ", content)
	print("SMOKE the image fills the window's content area (width and height): ", tr.size.x >= content.x - 2.0 and tr.size.y >= content.y * 0.85 and tr.expand_mode == TextureRect.EXPAND_IGNORE_SIZE)
	print("SMOKE ...keeping its aspect ratio: ", tr.stretch_mode == TextureRect.STRETCH_KEEP_ASPECT_CENTERED)
	viewer._back_button.pressed.emit()
	await process_frame
	print("SMOKE Back returns to the picker (and hides itself, title restored): ", not viewer.is_showing_image() and viewer._picker_view.visible and not viewer._back_button.visible and viewer._title_label.text == "Image Viewer")
	viewer.close()

	# --- header buttons grow with the window
	var calc = main._calculator_window
	calc.open()
	await process_frame
	var close_button: Button = calc._chrome[0]["button"]
	var small: Vector2 = close_button.custom_minimum_size
	var size0: Vector2 = calc.panel_size
	calc._apply_panel_size(size0 * 2.0, true)
	await process_frame
	var big: Vector2 = close_button.custom_minimum_size
	print("calibration — close button ", small, " -> ", big, " when the window doubled")
	print("SMOKE the close button starts big (>= 64 px) and roughly doubles when the window doubles: ", small.x >= 64.0 and big.x > small.x * 1.8)
	var font_small := 34
	print("SMOKE its text grows too: ", close_button.get_theme_font_size("font_size") > font_small * 1.7)
	calc._apply_panel_size(size0 * 8.0, true)
	print("SMOKE the growth is capped (a huge window doesn't get absurd buttons): ", close_button.custom_minimum_size.x <= 64.0 * 3.01)
	calc._apply_panel_size(size0, true)
	await process_frame
	print("SMOKE shrinking back restores the size: ", close_button.custom_minimum_size.is_equal_approx(small))
	calc.close()
	# the Image Viewer's Back button scales the same way
	viewer.open()
	await process_frame
	viewer._load_image(written[0])
	var back_small: Vector2 = viewer._back_button.custom_minimum_size
	viewer._apply_panel_size(viewer.panel_size * 2.0, true)
	print("SMOKE the Back button grows with the window too: ", viewer._back_button.custom_minimum_size.x > back_small.x * 1.8)
	viewer._apply_panel_size(viewer.panel_size * 0.5, true)
	viewer.close()

	# --- several windows of a kind at once
	var browser = main._browser_window
	main.open_window("image")
	main.open_window("image")
	main.open_window("image")
	await process_frame
	print("SMOKE pressing Image Viewer three times gives three windows: ", main.open_window_count("image") == 3 and viewer.is_open())
	var extras: Array = main._extra_windows.filter(func(w: Node) -> bool: return w.get_meta("window_kind", "") == "image")
	print("SMOKE the extras are staggered, not stacked on the primary: ", extras.size() == 2 and extras[0].global_position.distance_to(viewer.global_position) > 0.05 and extras[1].global_position.distance_to(extras[0].global_position) > 0.05)
	print("SMOKE each keeps its own picture/state: ", extras[0] != viewer and extras[0]._texture_rect != viewer._texture_rect)
	extras[0]._load_image(written[1])
	print("SMOKE loading a picture in one doesn't change the others: ", extras[0].is_showing_image() and not viewer.is_showing_image() and not extras[1].is_showing_image())
	var doomed = extras[0]
	doomed.close()
	for i in 3:
		await process_frame
	print("SMOKE closing an extra deletes it and leaves the rest open: ", not is_instance_valid(doomed) and main.open_window_count("image") == 2 and viewer.is_open())
	viewer.close()
	print("SMOKE closing the primary just hides it (it can reopen): ", not viewer.is_open() and is_instance_valid(viewer))
	for w in main._extra_windows.duplicate():
		w.close()
	await process_frame
	await process_frame

	main.open_window("browser")
	main.open_window("browser")
	await process_frame
	print("SMOKE two Browser windows can be open at once: ", main.open_window_count("browser") == 2 and browser.is_open())
	var browser_extra = main._extra_windows.filter(func(w: Node) -> bool: return w.get_meta("window_kind", "") == "browser")[0]
	print("SMOKE the extra Browser has the keyboard hooked up (address bar / Aa work): ", browser_extra._keyboard == main._keyboard)
	print("SMOKE ...and each has its own address bar and view: ", browser_extra._url_bar != browser._url_bar and browser_extra._view != browser._view)
	browser_extra.close()
	browser.close()
	await process_frame
	await process_frame

	# --- the resize-corner target is doubled
	print("SMOKE the resize corner target is doubled (0.10 m): ", is_equal_approx(viewer.corner_hit_reach, 0.10))
	calc.open()
	await process_frame
	calc.global_transform = Transform3D(Basis.IDENTITY, Vector3(0, 1.4, -1.0))
	r.set_meta("ui_hover", false)
	var half: Vector2 = calc.panel_size * 0.5
	var far_local := Vector3(half.x + 0.08, half.y + 0.08, 0.0) # 8 cm out: outside the old 5 cm target, inside the new one
	var far_world: Vector3 = calc.global_transform * far_local
	r.global_position = far_world + Vector3(0, 0, 0.5)
	r.look_at(far_world, Vector3.UP)
	for i in 3:
		await process_frame
	print("SMOKE aiming 8 cm out from a corner (missed before) now hovers it: ", calc._hover_corner == 1)
	var farther_world: Vector3 = calc.global_transform * Vector3(half.x + 0.13, half.y + 0.13, 0.0)
	r.global_position = farther_world + Vector3(0, 0, 0.5)
	r.look_at(farther_world, Vector3.UP)
	for i in 3:
		await process_frame
	print("SMOKE ...but not 13 cm out: ", calc._hover_corner == -1)
	calc.close()

	# --- the assembly tree scrolls too
	var tree = main._assembly_tree_window
	print("SMOKE the Assembly Tree's rows are its scroll target: ", tree.scroll_target != null)

	for path in written:
		DirAccess.remove_absolute(path)
	quit()
