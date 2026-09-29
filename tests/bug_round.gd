extends SceneTree
## Headless regression checks for the "real-headset bug round" of 29 Sep 2026
## (docs/status.md): snap-turn direction, the wrist tablet's one-row category
## rail / scrolling / uncapped Files list, the assembly tree window's row list
## actually getting height, the A/X nudge steering, and the stripped-down
## controller ring. Boots main.tscn with NO backend.
## Run: "$GODOT" --headless --path . --script res://tests/bug_round.gd  (see tests/README.md)

var main
var origin: XROrigin3D
var cam: XRCamera3D
var l: XRController3D
var r: XRController3D
var tab


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
	tab = l.get_node("WristTablet")
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
		if n is MeshInstance3D and n.mesh is TorusMesh and n.get_parent() == r:
			ring = n
	print("SMOKE controller has no thumbstick/button discs any more: ", discs == 0)
	print("SMOKE controller ring is still there and moved back by ~one diameter (z ~ +0.083): ", ring != null and absf(ring.position.z - 0.083) < 0.002)

	# --- tablet: categories on ONE row; taller and wider than the old 640x600.
	tab.open_tablet()
	for i in 4:
		await process_frame
	var rail_ys := {}
	var buttons: Array = []
	_all_nodes(tab._viewport, buttons)
	for b in buttons:
		if b is Button and b.is_visible_in_tree() and b.text in ["View", "Assembly", "Windows", "Files", "Settings"]:
			rail_ys[b.text] = snappedf(b.global_position.y, 1.0)
	var ys := rail_ys.values()
	print("calibration — rail button y positions: ", rail_ys)
	print("SMOKE all four categories and Settings share one row: ", rail_ys.size() == 5 and ys.min() == ys.max())
	print("SMOKE tablet is 20% taller and wider than before: ", tab.viewport_size.y == 720 and tab.viewport_size.x > 640 and is_equal_approx(tab.panel_size.y, 0.27))
	var rail_right := 0.0
	for b in buttons:
		if b is Button and b.text in ["Settings", "X"] and b.is_visible_in_tree():
			rail_right = maxf(rail_right, b.global_position.x + b.size.x)
	print("SMOKE the rail fits inside the panel width: ", rail_right > 0.0 and rail_right <= tab.viewport_size.x)

	# --- tablet scrolling: add a tall dummy page and drive the stick scroll.
	var holder: Control = tab._pages_scroll.get_child(0)
	var tall := Control.new()
	tall.custom_minimum_size = Vector2(10, 2000)
	holder.add_child(tall)
	for i in 3:
		await process_frame
	tab._scroll_f = 0.0
	tab._scroll_by_stick(-1.0, 0.2) # stick pushed DOWN
	print("SMOKE pushing the right stick down scrolls the tablet down: ", tab._pages_scroll.scroll_vertical > 100)
	var scrolled: int = tab._pages_scroll.scroll_vertical
	tab._scroll_by_stick(1.0, 0.1) # stick pushed UP
	print("SMOKE pushing it up scrolls back up: ", tab._pages_scroll.scroll_vertical < scrolled)
	tab._scroll_by_stick(0.05, 0.1)
	var held: int = tab._pages_scroll.scroll_vertical
	tab._scroll_by_stick(0.0, 1.0)
	print("SMOKE inside the deadzone nothing moves: ", tab._pages_scroll.scroll_vertical == held)
	tab._scroll_by_stick(-1.0, 100.0) # absurdly long: must clamp, not run away
	var bottom: int = tab._pages_scroll.scroll_vertical
	tab._scroll_by_stick(1.0, 0.05)
	print("SMOKE scrolling past the bottom clamps, and pushing back up responds immediately: ", tab._pages_scroll.scroll_vertical < bottom)
	holder.remove_child(tall)
	tall.free()

	# --- locomotion backs off while the right laser is on a panel.
	r.set_meta("ui_hover", true)
	print("SMOKE the right stick belongs to the UI while a panel is hovered: ", origin._right_stick_owned_by_ui())
	r.set_meta("ui_hover", false)
	print("SMOKE ...and to locomotion again once it isn't: ", not origin._right_stick_owned_by_ui())

	# --- Files: every file listed (no "+ N more"), Add hidden on the loaded root.
	var root_id: String = main.native_file_root_part_id("res://tests/fixtures/Assy_Test_Plate.didsa")
	print("SMOKE native_file_root_part_id reads a fixture's root Part: ", root_id == "8e28a0bb-648e-4c30-959c-40288e4ec9c1")
	print("SMOKE ...and returns '' for a missing file: ", main.native_file_root_part_id("res://tests/fixtures/nope.didsa") == "")
	tab._rebuild_files()
	var labels: Array = []
	_all_nodes(tab._files_box, labels)
	var has_more_label := false
	for n in labels:
		if n is Label and "more (not listed" in n.text:
			has_more_label = true
	print("SMOKE the Files list no longer has a '+ N more (not listed yet)' cap: ", not has_more_label)

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
		r._nudge_towards_hand(part, aim_up, 1.0, 1.0 / 60.0)
	var rel: Vector3 = part.global_position - r.global_position
	print("SMOKE A/X pulls the part closer: ", rel.length() < start_dist - 0.3)
	print("SMOKE A/X with the controller tilted UP moves the part UP (was inverted): ", rel.y > 0.05)
	r.global_position = Vector3(0, 1.5, 0)
	part.global_position = Vector3(0, 1.5, -0.2)
	for i in 120:
		r._nudge_towards_hand(part, Vector3(0, 0, -1), 5.0, 1.0 / 60.0)
	print("SMOKE A/X stops short of the hand (nudge_min_distance): ", (part.global_position - r.global_position).length() >= r.nudge_min_distance - 0.001)
	part.free()

	quit()
