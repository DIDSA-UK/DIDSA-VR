extends SceneTree
## The design table's handle can be grabbed with the laser, like every other handle (owner, 10 Nov 2026: needed when working seated). Full
## scene, no backend: a laser on the pill picks the table (the halo glows) but a laser on the glass does not (the glass is the table's own
## laser surface); a grip with the laser on the pill carries the table from where it is (window_held keeps the whole-model drag out); the
## carry keeps the slab's slope and turns it only about the vertical, towards you; A/X pulls it nearer; release drops it; the near grab still works.
## (A real grip can't be faked headless: controller.gd's _try_grab_panel_at_distance() and the handle's release are called directly.)
## Run: "$GODOT" --headless --path . --script res://tests/table_laser_grab.gd  (see tests/README.md)

var main
var table
var r: XRController3D
var cam: XRCamera3D


func frames(n: int = 3) -> void:
	for i in n:
		await physics_frame
		await process_frame


func aim_at(hand: XRController3D, point: Vector3, from: Vector3) -> void:
	hand.global_transform = Transform3D(Basis.looking_at((point - from).normalized(), Vector3.UP), from)


func slope(basis: Basis) -> float:
	## Degrees between the slab's normal and straight up.
	var up: Vector3 = (basis * Vector3.UP).normalized()
	return rad_to_deg(up.angle_to(Vector3.UP))


func _initialize() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	main.secrets_file_path = "res://__nonexistent__.cfg"
	root.add_child(main)
	await process_frame
	var origin: XROrigin3D = main.get_node("XROrigin3D")
	cam = origin.get_node("XRCamera3D")
	cam.position = Vector3(0, 1.2, 0) # seated
	r = origin.get_node("RightController")
	var l: XRController3D = origin.get_node("LeftController")
	l.position = Vector3(-2, 0.5, 2) # out of the way
	table = main.design_table
	table.open()
	# Put the table 1.5 m in front, out of arm's reach, its slab tipped 20 degrees towards you.
	table.global_transform = Transform3D(Basis(Vector3.RIGHT, deg_to_rad(20)), Vector3(0, 0.9, -1.5))
	await frames(3)
	var pill: Vector3 = table.handle.node.global_position
	var from := Vector3(0.2, 1.0, -0.2)

	aim_at(r, table.global_position, from)
	await frames(2)
	print("SMOKE a laser on the glass does not pick the table to carry: ", r._hover_panel != table)

	aim_at(r, pill + Vector3(0.01, 0.01, 0), from)
	await frames(2)
	print("SMOKE a laser on the handle picks the table (it glows): ", r._hover_panel == table and table.handle.is_hovered())
	print("SMOKE the hand is not near the handle (a distance grab): ", not table.handle_in_reach(r))
	var slope_before := slope(table.global_transform.basis)
	var grabbed: bool = r._try_grab_panel_at_distance()
	print("SMOKE a grip with the laser on the handle carries the table: ", grabbed and table.handle.held_by == r and table.handle.distance_mode)
	print("SMOKE ...and keeps the whole-model drag out (window_held): ", bool(r.get_meta("window_held", false)))

	# Swing the laser 40 degrees to the right: the table goes with it, keeps its 20 degree slope, and turns to stay towards you.
	var before_pos: Vector3 = table.global_position
	r.global_transform = Transform3D(Basis(Vector3.UP, deg_to_rad(-40)), Vector3.ZERO) * r.global_transform
	await frames(40)
	print("SMOKE the table follows the laser (moved, m): ", snappedf(table.global_position.distance_to(before_pos), 0.01), " (expect > 0.5)")
	print("SMOKE ...its slope is kept (degrees, before / after): ", snappedf(slope_before, 0.1), " / ", snappedf(slope(table.global_transform.basis), 0.1))
	var to_table: Vector3 = table.global_position - cam.global_position
	to_table.y = 0.0
	var front: Vector3 = table.global_transform.basis * Vector3.BACK # the slab's front edge (the handle's side) faces +Z
	front.y = 0.0
	print("SMOKE ...and it turned to stay towards you (front edge vs. line to you, degrees): ", snappedf(rad_to_deg(front.normalized().angle_to(-to_table.normalized())), 0.1), " (expect ~0)")

	var dist_before: float = table.handle.carry_distance()
	r.nudge_carried_panel(-1.0, 0.5) # A/X held for half a second
	print("SMOKE A/X pulls it nearer: ", table.handle.carry_distance() < dist_before)

	table.handle._on_released(table.handle.grab_action, r)
	await frames(2)
	var dropped_at: Vector3 = table.global_position
	await frames(5)
	print("SMOKE release drops it where it is (and clears window_held): ", table.global_position.is_equal_approx(dropped_at) and table.handle.held_by == null and not bool(r.get_meta("window_held", false)))

	# The near grab is unchanged.
	r.global_position = table.handle.node.global_position
	await frames(1)
	table.handle._on_pressed(table.handle.grab_action, r)
	print("SMOKE the near grab still works (hand on the handle, rigid): ", table.handle.held_by == r and not table.handle.distance_mode)
	table.handle._on_released(table.handle.grab_action, r)
	quit()
