extends SceneTree
## Full-scene test (main.tscn, no backend) for milestone 3's floating-window
## framework: the wrist tablet's Windows page, and scripts/
## diegetic_panel.gd's first-claim-per-frame arbitration across several open
## windows at once. Same real-button/real-laser-interaction style as
## tests/tablet_scene.gd/tests/popup_keyboard.gd for the parts this session
## added (a real grip/trigger press can't be faked headless, so
## button_pressed/button_released are emitted directly, same precedent
## those two already use); opening the tablet itself is done through its
## own public open_tablet() rather than re-simulating the already-tested
## bullseye shot.
## Run: "$GODOT" --headless --path . --script res://tests/windows_tab.gd

var main
var tablet
var calc
var tree_window
var image_window
var browser_window
var l: XRController3D
var r: XRController3D
var cam: XRCamera3D


func find_button(viewport: SubViewport, pred: Callable) -> Button:
	var stack_nodes: Array = [viewport]
	while not stack_nodes.is_empty():
		var n: Node = stack_nodes.pop_back()
		if n is Button and n.is_visible_in_tree() and pred.call(n):
			return n
		stack_nodes.append_array(n.get_children())
	return null


func aim_and_click(panel, viewport: SubViewport, button: Button) -> void:
	## Generalised from tests/popup_keyboard.gd's own aim_and_click(): works
	## against a free-floating, camera-facing scripts/diegetic_panel.gd
	## window (Calculator/Assembly Tree/Image Viewer), whose own basis.z is
	## always roughly horizontal (see _place_in_front_of_camera()) - so
	## look_at(world, Vector3.UP) below is never asked to look straight up
	## or down. NOT safe for the wrist tablet - see aim_and_click_tablet().
	var c: Vector2 = button.global_position + button.size * 0.5
	var local_x: float = (c.x / panel.viewport_size.x - 0.5) * panel.panel_size.x
	var local_y: float = (0.5 - c.y / panel.viewport_size.y) * panel.panel_size.y
	var world: Vector3 = panel.global_transform * Vector3(local_x, local_y, 0)
	var standoff: Vector3 = panel.global_transform.basis.z.normalized() * 0.3
	r.global_position = world + standoff
	r.look_at(world, Vector3.UP)
	for i in 3:
		await process_frame
	r.button_pressed.emit("trigger_click")
	await process_frame
	r.button_released.emit("trigger_click")
	await process_frame


func aim_and_click_tablet(button: Button) -> void:
	## The wrist tablet is tilted on the wrist, so aim along its quad's normal: stand the hand 0.4 m out along it
	## and look straight at the button (a look_at(world, UP) from above would be degenerate for a flat tablet; this
	## one is tilted but the transform-based aim works for any tilt).
	var c: Vector2 = button.global_position + button.size * 0.5
	var lx: float = (c.x / tablet.viewport_size.x - 0.5) * tablet.panel_size.x
	var ly: float = (0.5 - c.y / tablet.viewport_size.y) * tablet.panel_size.y
	var xf: Transform3D = tablet._quad.global_transform
	var p: Vector3 = xf * Vector3(lx, ly, 0.0)
	var n: Vector3 = xf.basis.z.normalized()
	r.global_transform = Transform3D(Basis.looking_at(-n, Vector3.UP), p + n * 0.4)
	for i in 3:
		await process_frame
	r.button_pressed.emit("trigger_click")
	await process_frame
	r.button_released.emit("trigger_click")
	await process_frame


func _initialize() -> void:
	var packed: PackedScene = load("res://scenes/main.tscn")
	main = packed.instantiate()
	main.secrets_file_path = "res://__nonexistent__.cfg" # no backend => no network
	root.add_child(main)
	await process_frame
	var origin: XROrigin3D = main.get_node("XROrigin3D")
	cam = origin.get_node("XRCamera3D")
	l = origin.get_node("LeftController")
	r = origin.get_node("RightController")
	cam.position = Vector3(0, 1.6, 0); cam.rotation = Vector3.ZERO
	l.position = Vector3(-0.2, 1.0, 0)
	r.position = Vector3(0.2, 1.0, 0)
	tablet = main._tablet
	calc = main._calculator_window
	tree_window = main._assembly_tree_window
	image_window = main._image_viewer_window
	browser_window = main._browser_window
	for i in 4:
		await process_frame

	print("SMOKE all four windows start closed: ", not calc.is_open() and not tree_window.is_open() and not image_window.is_open() and not browser_window.is_open())

	tablet.open_tablet()
	await process_frame
	await create_timer(0.5).timeout # open_settle_seconds (0.4s): an immediate press is ignored - see tests/section_tab.gd's own identical wait for why
	var tree_button: Button = tablet.ui.home_tile("tree")
	print("SMOKE each window has its own tile on the home screen (tree, calculator, images, browser): ", tree_button != null and tablet.ui.home_tile("calculator") != null and tablet.ui.home_tile("images") != null and tablet.ui.home_tile("browser") != null)
	await aim_and_click_tablet(tree_button)
	print("SMOKE Assembly Tree window opens from its tile and the tablet stays on Home: ", tree_window.is_open() and tablet.ui.selected_category_id == "")
	print("SMOKE with no backend configured, its status says so rather than hanging: ", tree_window._status_label.text.begins_with("No assembly"))

	var calc_button: Button = tablet.ui.home_tile("calculator")
	await aim_and_click_tablet(calc_button)
	print("SMOKE Calculator window ALSO opens, while the tree window stays open too: ", calc.is_open() and tree_window.is_open())

	# Drive the calculator for real through its own laser/click path, to
	# prove a second simultaneously-open window is independently
	# interactive, not just visually present.
	await aim_and_click(calc, calc._viewport, find_button(calc._viewport, func(b: Button) -> bool: return b.text == "2"))
	await aim_and_click(calc, calc._viewport, find_button(calc._viewport, func(b: Button) -> bool: return b.text == "+"))
	await aim_and_click(calc, calc._viewport, find_button(calc._viewport, func(b: Button) -> bool: return b.text == "2"))
	await aim_and_click(calc, calc._viewport, find_button(calc._viewport, func(b: Button) -> bool: return b.text == "="))
	print("SMOKE the calculator computes 2+2 through a real laser/click sequence: ", calc._display.text == "4")

	var image_button: Button = tablet.ui.home_tile("images")
	await aim_and_click_tablet(image_button)
	print("SMOKE all three windows can be open at once: ", calc.is_open() and tree_window.is_open() and image_window.is_open())
	print("SMOKE image viewer's file list populates on open (empty models/ is fine - it's git-ignored and empty by default): ", image_window._list_box.get_child_count() > 0)

	var browser_button: Button = tablet.ui.home_tile("browser")
	await aim_and_click_tablet(browser_button)
	print("SMOKE Browser window ALSO opens, alongside the other three: ", browser_window.is_open() and calc.is_open() and tree_window.is_open() and image_window.is_open())
	print("SMOKE with no relay configured, its status says so rather than hanging: ", browser_window._status_label.text.begins_with("No browser relay"))

	# Close them via each window's own close() - independent of the tablet.
	calc.close()
	tree_window.close()
	image_window.close()
	browser_window.close()
	print("SMOKE each window closes independently of the others and the tablet: ", not calc.is_open() and not tree_window.is_open() and not image_window.is_open() and not browser_window.is_open() and tablet.is_open())

	# First-claim-per-frame arbitration: place two windows so their panels
	# genuinely overlap along the same laser ray, aim there, and confirm
	# exactly ONE of them ends up hovered - not both (the double-claim bug
	# an earlier "claim if nearer" draft of this had - see
	# diegetic_panel.gd's own docstring for the full story). Panels are
	# added in main.gd's _ready() in this order: assembly tree, then
	# calculator - so the tree window, processed first each frame, is the
	# one guaranteed to win a same-frame contest under this scheme, even
	# though calc here is placed nearer to the hand; that's the documented
	# trade-off (correctness over true-nearest), not a bug.
	tree_window.open()
	calc.open()
	await process_frame
	var base: Vector3 = r.global_position
	tree_window.global_transform = Transform3D(Basis.IDENTITY, base + Vector3(0, 0, -1.0))
	calc.global_transform = Transform3D(Basis.IDENTITY, base + Vector3(0, 0, -0.5)) # nearer, but processed second
	r.look_at(calc.global_position, Vector3.UP)
	for i in 3:
		await process_frame
	print("SMOKE with two overlapping panels, exactly one ends up hovered, never both: ", tree_window._hovering != calc._hovering)
	print("SMOKE the earlier-processed panel (assembly tree) wins the shared claim, per this scheme's documented trade-off: ", tree_window._hovering and not calc._hovering)

	# Grab handle: GRIP it with a hand near it and the whole panel should
	# follow 1:1; releasing should leave it exactly where dropped.
	calc.open()
	await process_frame
	calc.global_transform = Transform3D(Basis.IDENTITY, Vector3(0, 1.2, -1.0))
	l.position = calc._handle.global_position
	await physics_frame
	l.button_pressed.emit("grip_click")
	print("SMOKE gripping near the handle grabs the panel: ", calc._held_by == l)
	print("SMOKE gripping a window sets the window_held meta, so two_hand_model.gd won't also drag the world: ", l.get_meta("window_held", false) == true and not main._two_hand._hand_free_ignoring_button(l))
	var before: Vector3 = calc.global_position
	l.position += Vector3(0.3, 0.1, -0.2)
	for i in 3:
		await process_frame
	var moved: Vector3 = calc.global_position - before
	print("SMOKE dragging the handle moves the panel 1:1 with the hand: ", moved.is_equal_approx(Vector3(0.3, 0.1, -0.2)))
	print("SMOKE a window being carried by its handle isn't hoverable (no stale hover to click through): ", not calc._hovering)
	l.button_released.emit("grip_click")
	for i in 3:
		await process_frame
	var after_release: Vector3 = calc.global_position
	l.position += Vector3(1.0, 0, 0) # hand keeps moving after release
	for i in 3:
		await process_frame
	print("SMOKE releasing the handle stops the panel from following further hand movement: ", calc._held_by == null and calc.global_position.is_equal_approx(after_release))
	print("SMOKE releasing the window clears the window_held meta: ", l.get_meta("window_held", true) == false)

	# Closing a window while still gripping its handle must not leave the meta
	# stuck true (that would block whole-model drags with that hand forever).
	calc.global_transform = Transform3D(Basis.IDENTITY, Vector3(0, 1.2, -1.0))
	l.position = calc._handle.global_position
	await physics_frame
	l.button_pressed.emit("grip_click")
	var grabbed_again: bool = l.get_meta("window_held", false) == true
	calc.close()
	print("SMOKE closing a window mid-grab clears the window_held meta: ", grabbed_again and l.get_meta("window_held", true) == false)
	l.button_released.emit("grip_click")

	# controller.gd must NOT also grab a part/gizmo on a grip aimed at a window handle.
	calc.open()
	await process_frame
	calc.global_transform = Transform3D(Basis.IDENTITY, Vector3(0, 1.2, -1.0))
	l.position = calc._handle.global_position
	await physics_frame
	print("SMOKE a hand at a window's handle reports it in reach (controller.gd defers to the window): ", calc.handle_in_reach(l))
	l.position = calc._handle.global_position + Vector3(0.5, 0, 0)
	print("SMOKE a hand 50cm from the handle does not: ", not calc.handle_in_reach(l))
	calc.close()

	tree_window.close()
	image_window.close()
	browser_window.close()
	tablet.close_tablet()
	quit()
