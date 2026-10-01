extends SceneTree
## Distance grab of floating windows and the popup keyboard (controller.gd + scripts/ui/panel_handle.gd),
## full scene (main.tscn, no backend): a laser on a panel makes it GLOW (halo) and picks the nearest one;
## a part in front of it blocks that; a grip with the laser on it carries it from where it is (sets
## window_held so the whole-model grab stays out), the panel follows the hand but turns to FACE you and stays
## upright (the full keyboard keeps its lean); A/X pulls it towards you and B/Y pushes it away at a speed
## proportional to its distance (and never through the hand); release drops it; closing mid-carry clears the
## hand; a part the hand is touching wins over a window; the near handle grab is untouched; either hand can do
## it; the laser stops on a far window. Also: the hovered part's name label ("MESH 2") is gone.
## (A real A/B press can't be faked headless: nudge_carried_panel() is called directly, as the part nudge tests do.)
## Run: "$GODOT" --headless --path . --script res://tests/panel_distance_grab.gd  (see tests/README.md)

var main
var l: XRController3D
var r: XRController3D
var cam: XRCamera3D
var calc
var kb

func frames(n: int = 3) -> void:
	for i in n:
		await process_frame
		await physics_frame

func aim_at(hand: XRController3D, panel_point: Vector3, from: Vector3) -> void:
	hand.global_transform = Transform3D(Basis.looking_at((panel_point - from).normalized(), Vector3.UP), from)

func _initialize() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	main.secrets_file_path = "res://__nonexistent__.cfg"
	root.add_child(main)
	await process_frame
	var origin: XROrigin3D = main.get_node("XROrigin3D")
	cam = origin.get_node("XRCamera3D")
	l = origin.get_node("LeftController")
	r = origin.get_node("RightController")
	cam.global_position = Vector3(0, 1.6, 0)
	calc = main._calculator_window
	kb = main._keyboard
	await frames(2)

	# a window placed somewhere awkward: 4 m away, off to the side, low
	calc.open()
	await frames(2)
	calc.global_transform = Transform3D(Basis.looking_at(Vector3(0, 0, 1), Vector3.UP), Vector3(2.5, 0.7, -4.0)) # facing +Z; 4 m ahead of the camera
	r.global_position = Vector3(0.0, 1.3, 0.0)
	await frames(2)
	aim_at(r, calc.global_position, r.global_position)
	await frames(3)
	print("SMOKE a laser aimed at a window 4+ m away makes it hovered: ", calc.handle.is_hovered() and r._hover_panel == calc)
	print("SMOKE ...and it GLOWS (halo shown at the hover level): ", calc.handle._halo.visible and is_equal_approx(calc.handle.glow_level, 0.5))
	var dist: float = r.global_position.distance_to(calc.global_position)
	print("SMOKE ...and the laser stops on it instead of passing through (even past its normal 3 m): ", absf(r._laser_mesh.height - dist) < 0.2 and dist > 3.0)
	r.global_transform = Transform3D(Basis.looking_at(Vector3(0, 0, 1), Vector3.UP), r.global_position) # turn away
	await frames(3)
	print("SMOKE aiming away stops the glow: ", not calc.handle.is_hovered() and not calc.handle._halo.visible and r._hover_panel == null)

	# --- a part in front blocks it
	var part := MeshInstance3D.new()
	var bm := BoxMesh.new(); bm.size = Vector3(0.6, 0.6, 0.2); part.mesh = bm
	main.assembly_root.add_child(part)
	part.add_to_group("grabbable_parts")
	part.create_trimesh_collision()
	part.global_position = Vector3(1.2, 1.0, -2.0)
	await frames(2)
	aim_at(r, calc.global_position, r.global_position)
	var line: Vector3 = (calc.global_position - r.global_position)
	part.global_position = r.global_position + line * 0.4
	await frames(3)
	print("SMOKE a part in front of the window means the laser is on the part, not the window: ", not calc.handle.is_hovered())
	part.global_position = Vector3(30, 30, 30)
	await frames(3)
	print("SMOKE ...and the window glows again once the part is out of the way: ", calc.handle.is_hovered())

	# --- grab
	var before_pos: Vector3 = calc.global_position
	r.button_pressed.emit("grip_click")
	await frames(2)
	print("SMOKE a grip with the laser on the window carries it (distance grab): ", calc.handle.held_by == r and calc.handle.distance_mode)
	print("SMOKE ...it glows brighter while carried, and the hand is marked busy so the whole model isn't dragged too: ", is_equal_approx(calc.handle.glow_level, 1.0) and r.get_meta("window_held", false) == true and not main._two_hand._hand_free_ignoring_button(r))
	var d0: float = calc.handle.carry_distance()
	# swing the hand to the right: the window follows (position), and faces the camera, upright
	r.global_position += Vector3(0.5, 0.2, 0.0)
	r.global_transform = Transform3D(Basis.looking_at(Vector3(0.3, -0.1, -1.0).normalized(), Vector3.UP), r.global_position)
	await frames(30)
	var moved: Vector3 = calc.global_position - before_pos
	print("SMOKE moving the hand moves the window with it: ", moved.length() > 0.2)
	var to_cam: Vector3 = cam.global_position - calc.global_position
	to_cam.y = 0.0
	var front: Vector3 = calc.global_transform.basis.z
	front.y = 0.0
	print("SMOKE ...and it always turns to face you: ", front.normalized().dot(to_cam.normalized()) > 0.99)
	print("SMOKE ...staying upright (no roll, no pitch): ", absf(calc.global_transform.basis.y.dot(Vector3.UP)) > 0.999)
	print("SMOKE its distance from the hand is kept as grabbed: ", absf(calc.handle.carry_distance() - d0) < 0.01)

	# --- A / B
	var d1: float = calc.handle.carry_distance()
	r.nudge_carried_panel(1.0, 0.5)
	var d2: float = calc.handle.carry_distance()
	print("SMOKE B/Y pushes it away from the hand, quickly when it's far (proportional speed): ", d2 > d1 + 0.5 * 0.6 * d1 * 0.9)
	r.nudge_carried_panel(-1.0, 0.5)
	var d3: float = calc.handle.carry_distance()
	print("SMOKE A/X pulls it back towards you: ", d3 < d2 - 0.1)
	for i in 60:
		r.nudge_carried_panel(-1.0, 0.2)
	print("SMOKE ...but never through the hand (stops at the minimum distance): ", absf(calc.handle.carry_distance() - calc.handle.min_pull_distance) < 0.01)
	for i in 200:
		r.nudge_carried_panel(1.0, 0.5)
	print("SMOKE ...and never absurdly far (capped): ", calc.handle.carry_distance() <= calc.handle.max_distance + 0.001)
	r.nudge_carried_panel(-1.0, 3.0)
	r.nudge_carried_panel(-1.0, 3.0)
	await frames(4)
	var pulled_close: float = r.global_position.distance_to(calc.global_position)

	# --- release
	r.button_released.emit("grip_click")
	await frames(2)
	var dropped_at: Vector3 = calc.global_position
	print("SMOKE releasing drops it where it is: ", calc.handle.held_by == null and not calc.handle.distance_mode and r.get_meta("window_held", true) == false)
	r.global_position += Vector3(2, 0, 0)
	await frames(3)
	print("SMOKE ...and it no longer follows the hand: ", calc.global_position.is_equal_approx(dropped_at))

	# --- hand touching a part wins over a window under the laser
	calc.global_transform = Transform3D(Basis.looking_at(Vector3(0, 0, 1), Vector3.UP), Vector3(0, 1.2, -3.0))
	part.global_position = Vector3(0.3, 1.2, -1.0)
	r.global_position = part.global_position
	aim_at(r, calc.global_position, r.global_position)
	await frames(3)
	var held_before: Node3D = r.held_node
	r._on_button_pressed("grip_click")
	await physics_frame
	print("SMOKE a grip while the hand is touching a part grabs the PART, not a window the laser is on: ", r.held_node == part and calc.handle.held_by == null)
	r._try_release()
	part.global_position = Vector3(30, 30, 30)
	await frames(2)

	# --- the near handle grab is unchanged and a near grip never becomes a distance grab
	calc.global_transform = Transform3D(Basis.IDENTITY, Vector3(0, 1.2, -1.0))
	l.global_position = calc.handle.node.global_position
	await physics_frame
	l.button_pressed.emit("grip_click")
	print("SMOKE the near handle grab still works and stays a rigid carry: ", calc.handle.held_by == l and not calc.handle.distance_mode)
	l.button_released.emit("grip_click")
	await frames(2)

	# --- the LEFT hand can do it too
	calc.global_transform = Transform3D(Basis.looking_at(Vector3(0, 0, 1), Vector3.UP), Vector3(-2.0, 1.0, -3.5))
	l.global_position = Vector3(0.0, 1.2, 0.0)
	aim_at(l, calc.global_position, l.global_position)
	await frames(3)
	print("SMOKE the left hand's laser picks a window too: ", l._hover_panel == calc and calc.handle.is_hovered())
	l.button_pressed.emit("grip_click")
	await frames(2)
	print("SMOKE ...and its grip carries it: ", calc.handle.held_by == l and calc.handle.distance_mode)
	calc.close()
	await frames(2)
	print("SMOKE closing a window mid-carry clears the hand and the glow: ", l.get_meta("window_held", true) == false and calc.handle.held_by == null and not calc.handle._halo.visible)
	l.button_released.emit("grip_click")

	# --- the popup keyboard is grabbable at a distance and keeps its lean
	main.open_keyboard_for("", func(_t: String) -> void: pass, {"mode": "full"})
	await frames(3)
	var lean_before: float = kb.global_transform.basis.get_euler(EULER_ORDER_YXZ).x
	kb.global_position = Vector3(1.5, 0.4, -3.0)
	r.global_position = Vector3(0.0, 1.2, 0.0)
	aim_at(r, kb.global_position, r.global_position)
	await frames(3)
	print("SMOKE the keyboard glows under the laser: ", r._hover_panel == kb and kb.handle.is_hovered())
	r.button_pressed.emit("grip_click")
	await frames(2)
	r.global_position += Vector3(-0.4, 0.0, 0.0)
	await frames(30)
	var lean_after: float = kb.global_transform.basis.get_euler(EULER_ORDER_YXZ).x
	print("SMOKE a distance-carried full keyboard keeps its lean while facing you: ", kb.handle.held_by == r and absf(lean_after - lean_before) < 0.05 and absf(lean_before) > 0.2)
	r.button_released.emit("grip_click")
	await frames(2)
	kb.close()

	# --- the hovered part's name label is gone
	var stray := 0
	for hand in [l, r]:
		for c in hand.get_children():
			if c is Label3D:
				stray += 1
	print("SMOKE hovering a mesh with the laser no longer shows a name label (no Label3D hangs off either controller): ", stray == 0)
	quit()
