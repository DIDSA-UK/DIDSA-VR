extends SceneTree
## Full-scene test (main.tscn, no backend) for milestone 3's floating-window
## framework: the wrist tablet's new Windows tab, and scripts/
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
	## The wrist tablet's own quad lies flat (horizontal - mount rotation
	## turns its local +Z to point straight up, see wrist_tablet.gd's own
	## setup() comment), so aiming at one of its buttons means looking
	## straight down at it - exactly the case look_at(world, Vector3.UP)
	## can't handle (forward parallel to the up vector is degenerate: the
	## very bug this helper exists to avoid, caught by actually running
	## this test against a real Godot instead of only inspecting the code -
	## see docs/status.md). Ported directly from tests/section_tab.gd's own
	## proven aim_and_click(), which has always aimed at this same tablet
	## this same way: position the hand directly above the button (r's
	## rotation fixed to look straight down, set once in _initialize()),
	## rather than deriving an orientation from a look_at call at all.
	var c: Vector2 = button.global_position + button.size * 0.5
	var lx: float = (c.x / tablet.viewport_size.x - 0.5) * tablet.panel_size.x
	var ly: float = (0.5 - c.y / tablet.viewport_size.y) * tablet.panel_size.y
	r.position = Vector3(l.position.x + tablet.mount_position.x + lx, 1.5, l.position.z + tablet.mount_position.z - ly)
	r.rotation_degrees = Vector3(-90, 0, 0) # re-assert straight-down aim - a prior aim_and_click() (calc's own buttons) leaves r's rotation wherever its own look_at() pointed it
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
	r.rotation_degrees.x = -90 # aims straight down at the flat wrist tablet - see aim_and_click_tablet()
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
	var windows_tab: Button = find_button(tablet._viewport, func(b: Button) -> bool: return b.text == "Windows")
	print("SMOKE the Windows tab exists on the wrist tablet: ", windows_tab != null)
	await aim_and_click_tablet(windows_tab)
	print("SMOKE Windows tab selected: ", tablet._pages["Windows"].visible)

	var tree_button: Button = find_button(tablet._viewport, func(b: Button) -> bool: return b.text == "Assembly Tree")
	await aim_and_click_tablet(tree_button)
	print("SMOKE Assembly Tree window opens from its Windows-tab button: ", tree_window.is_open())
	print("SMOKE with no backend configured, its status says so rather than hanging: ", tree_window._status_label.text.begins_with("No assembly"))

	var calc_button: Button = find_button(tablet._viewport, func(b: Button) -> bool: return b.text == "Calculator")
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

	var image_button: Button = find_button(tablet._viewport, func(b: Button) -> bool: return b.text == "Image Viewer")
	await aim_and_click_tablet(image_button)
	print("SMOKE all three windows can be open at once: ", calc.is_open() and tree_window.is_open() and image_window.is_open())
	print("SMOKE image viewer's file list populates on open (empty models/ is fine - it's git-ignored and empty by default): ", image_window._list_box.get_child_count() > 0)

	var browser_button: Button = find_button(tablet._viewport, func(b: Button) -> bool: return b.text == "Browser")
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

	calc.close()
	tree_window.close()
	image_window.close()
	browser_window.close()
	tablet.close_tablet()
	quit()
