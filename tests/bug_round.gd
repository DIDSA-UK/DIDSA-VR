extends SceneTree
## Headless regression checks for the "real-headset bug round" of 29 Sep 2026
## (docs/status.md): snap-turn direction, the wrist tablet's (layout/scroll/edge checks now live in tablet and laser_surface) category
## rail / scrolling / uncapped Files list, the assembly tree window's row list
## actually getting height, the A/X nudge steering, and the stripped-down
## controller ring. Boots main.tscn with NO backend.
## Run: "$GODOT" --headless --path . --script res://tests/bug_round.gd  (see tests/README.md)

var main
var origin: XROrigin3D
var cam: XRCamera3D
var l: XRController3D
var r: XRController3D


func _all_nodes(n: Node, out: Array) -> void:
	out.append(n)
	for c in n.get_children():
		_all_nodes(c, out)


func _initialize() -> void:
	var packed: PackedScene = load("res://scenes/main.tscn")
	main = packed.instantiate()
	main.secrets_file_path = "res://__nonexistent__.cfg"
	root.add_child(main)
	await process_frame
	origin = main.get_node("XROrigin3D")
	cam = origin.get_node("XRCamera3D")
	l = origin.get_node("LeftController")
	r = origin.get_node("RightController")
	for i in 4:
		await process_frame

	# --- snap-turn direction: a RIGHT push must turn the user right (clockwise
	# from above: the view direction -Z swings towards +X).
	var forward_before := -cam.global_transform.basis.z
	origin._snap_turn(1.0)
	var forward_after := -cam.global_transform.basis.z
	print("SMOKE snap-turn right: view direction swings towards +X (turns right): ", forward_after.x > forward_before.x + 0.3)
	origin._snap_turn(-1.0)
	origin._snap_turn(-1.0)
	print("SMOKE snap-turn left: view direction swings towards -X (turns left): ", (-cam.global_transform.basis.z).x < forward_before.x - 0.3)
	origin._snap_turn(1.0) # back to start

	# --- controller ring: only the ring remains (no button discs), moved back.
	var meshes: Array = []
	_all_nodes(r, meshes)
	var discs := 0
	var ring: MeshInstance3D = null
	for n in meshes:
		if n is MeshInstance3D and n.mesh is CylinderMesh and n.get_parent() == r and n.mesh.height < 0.01 and n.mesh.top_radius < 0.02:
			discs += 1
		if n is MeshInstance3D and n.mesh is TorusMesh and n.get_parent().get_parent() == r:
			ring = n # the ring's pieces (glow, face, accent ring) share one anchor node, which carries the position
	print("SMOKE controller has no thumbstick/button discs any more: ", discs == 0)
	print("SMOKE controller ring is still there and moved back by ~one diameter (z ~ +0.083): ", ring != null and absf((ring.get_parent() as Node3D).position.z - 0.083) < 0.002)

	# (The tablet's one-row category layout, size, stick scrolling and held-click edge slack moved with the
	# redesign: tests/tablet.gd covers the layout and size, tests/laser_surface.gd the scrolling and edge slack.)

	# --- locomotion backs off while the right laser is on a panel.
	r.set_meta("ui_hover", true)
	print("SMOKE the right stick belongs to the UI while a panel is hovered: ", origin._right_stick_owned_by_ui())
	r.set_meta("ui_hover", false)
	print("SMOKE ...and to locomotion again once it isn't: ", not origin._right_stick_owned_by_ui())

	# --- Files: every file listed (no "+ N more"), Add hidden on the loaded root.
	var root_id: String = main.native_file_root_part_id("res://tests/fixtures/Assy_Test_Plate.didsa")
	print("SMOKE native_file_root_part_id reads a fixture's root Part: ", root_id == "8e28a0bb-648e-4c30-959c-40288e4ec9c1")
	print("SMOKE ...and returns '' for a missing file: ", main.native_file_root_part_id("res://tests/fixtures/nope.didsa") == "")
	var tab = l.get_node("WristTablet")
	tab.pages._rescan_files()
	print("SMOKE the Files list shows every model file found, with no '+ N more' cap: ", tab.pages._files_rows().size() == main.list_model_files().size())

	# --- load errors carry the backend's own reason; overlapping loads are refused.
	var body := '{"detail":"Cannot insert a Part into itself"}'.to_utf8_buffer()
	print("SMOKE an HTTP error's text includes the backend's detail: ", main._http_error_text(422, 0, body) == "HTTP 422 (result 0): Cannot insert a Part into itself")
	print("SMOKE ...and copes with no body at all: ", main._http_error_text(500, 0, PackedByteArray()) == "HTTP 500 (result 0)")
	main._load_busy = true
	main.open_native_file("res://tests/fixtures/Assy_Test_Plate.didsa")
	print("SMOKE a second Open while one is in flight is refused with a visible message: ", main._load_busy and "Busy" in main.status_text)
	main._load_busy = false

	# --- Assembly Tree window: the row list must get real height inside the panel.
	var tree_window = main._assembly_tree_window
	tree_window.open()
	tree_window._tree = [{"id": "", "name": "Root", "named": true, "resolved_part_id": "p", "expanded": true, "children": [
		{"id": "a", "name": "Peg", "named": true, "resolved_part_id": "", "children": null, "expanded": false},
		{"id": "b", "name": "Plate", "named": true, "resolved_part_id": "", "children": null, "expanded": false},
	]}]
	tree_window._rebuild_rows()
	for i in 4:
		await process_frame
	var scroll: ScrollContainer = tree_window._rows_box.get_parent()
	print("calibration — tree row scroll height: ", scroll.size.y)
	print("SMOKE the Assembly Tree's row list has real height (rows visible, not collapsed to ~0): ", scroll.size.y > 150.0)
	tree_window.close()

	# --- A/X nudge: steered by the aim (tilt the controller and the part follows), not inverted.
	var part := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3.ONE * 0.1
	part.mesh = box
	main.add_child(part)
	await process_frame
	r.global_position = Vector3(0, 1.5, 0)
	part.global_position = Vector3(0, 1.5, -2.0) # straight ahead, 2 m out
	var aim_up := Vector3(0, 0.5, -1.0).normalized() # controller tilted UP
	var start_dist := (part.global_position - r.global_position).length()
	for i in 30:
		r._nudge_along_aim(part, aim_up, -1.0, 1.0, 1.0 / 60.0)
	var rel: Vector3 = part.global_position - r.global_position
	print("SMOKE A/X pulls the part closer: ", rel.length() < start_dist - 0.3)
	print("SMOKE A/X with the controller tilted UP moves the part UP (was inverted): ", rel.y > 0.05)
	r.global_position = Vector3(0, 1.5, 0)
	part.global_position = Vector3(0, 1.5, -0.2)
	for i in 120:
		r._nudge_along_aim(part, Vector3(0, 0, -1), -1.0, 5.0, 1.0 / 60.0)
	print("SMOKE A/X stops short of the hand (nudge_min_distance): ", (part.global_position - r.global_position).length() >= r.nudge_min_distance - 0.001)

	# B/Y and A/X share one routine, so sweeping the aim swings the part at the
	# SAME rate either way (was: A 6/s, B ~0).
	var swing := {}
	for dirn in [-1.0, 1.0]:
		r.global_position = Vector3(0, 1.5, 0)
		part.global_position = Vector3(0, 1.5, -2.0)
		for i in 30: # half a second of holding the button with the aim swung 45 degrees up
			r._nudge_along_aim(part, Vector3(0, 1, -1).normalized(), dirn, 0.0, 1.0 / 60.0) # speed 0: isolate the steering
		var rel2: Vector3 = part.global_position - r.global_position
		swing[dirn] = rad_to_deg((Vector3(0, 0, -1)).angle_to(rel2))
	print("calibration — steering swing after 0.5 s (deg) A: ", snappedf(swing[-1.0], 0.1), " B: ", snappedf(swing[1.0], 0.1))
	print("SMOKE A/X and B/Y steer towards the aim at the same rate: ", absf(swing[-1.0] - swing[1.0]) < 0.5)
	print("SMOKE ...and at a mid-point rate (not the old 6/s snap: well under a full swing in 0.5 s): ", swing[1.0] > 10.0 and swing[1.0] < 40.0)
	part.free()

	quit()
