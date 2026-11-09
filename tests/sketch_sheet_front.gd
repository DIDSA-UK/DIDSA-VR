extends SceneTree
## T4 (docs/test-report-30-oct-plan.md): while a sketch is open the sheet is hinged on the slab's FRONT edge and leans back (15 degrees from vertical by default,
## 10 / 25 by setting), so it is close to a user standing at the tool deck. With a part seated and the sheet put up (orient_to_plane): the sheet's lower edge lies on the
## slab's front edge (within 5 mm), its angle to the slab is 90 minus the lean, the window anchor is the sheet's middle, the part's sketch plane passes through it, and the
## pose Reset and Fit use puts the plane back on it. From the standing eye point the sheet's lower edge is above the tool deck's top edge on screen, at the smallest and
## largest slab. "Middle" gives the old floating sheet (60 degrees, anchor near the part). The settings round-trip. NOT checked: comfort on a headset.
## Run: "$GODOT" --headless --path . --script res://tests/sketch_sheet_front.gd  (see tests/README.md)

const AppSettings := preload("res://scripts/app_settings.gd")
const UiFeedback := preload("res://scripts/ui/ui_feedback.gd")
const SelectionDrawer := preload("res://scripts/design_table/selection_drawer.gd")

var main
var table


func check(what: String, ok: bool) -> void:
	print("SMOKE ", what, ": ", ok)


func frames(n: int = 3) -> void:
	for i in n:
		await physics_frame
		await process_frame


func plane() -> Dictionary:
	return {"origin": Vector3.ZERO, "n": Vector3(0, 0, 1), "x": Vector3(1, 0, 0), "y": Vector3(0, 1, 0)}


func lower_edge_and_angle() -> Array:
	## [the sheet's lower-edge middle in the console frame, the angle (degrees) between the sheet and the slab]
	var p := plane()
	var rot: Basis = table.pivot.basis.orthonormalized()
	var up: Vector3 = rot * (table.table_copy.basis * (p["y"] as Vector3)).normalized()
	var normal: Vector3 = rot * (table.table_copy.basis * (p["n"] as Vector3)).normalized()
	var lower: Vector3 = table.window_anchor - up * table.sheet_window_m.y * 0.5
	return [lower, rad_to_deg(acos(clampf(normal.dot(Vector3.UP), -1.0, 1.0)))]


func _initialize() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	main.secrets_file_path = "res://__nonexistent__.cfg"
	root.add_child(main)
	await process_frame
	UiFeedback.reduce_motion = true
	var camera: XRCamera3D = main.get_node("XROrigin3D/XRCamera3D")
	camera.position = Vector3(0, 1.6, 0)
	table = main.design_table
	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(60, 30, 20)
	mesh.mesh = box
	main.assembly_root.add_child(mesh)
	mesh.add_to_group("grabbable_parts")
	mesh.set_meta("owner_part_id", "P1")
	mesh.set_meta("occurrence_id", "occ_a")
	table.open()
	await frames(3)
	table.seat(mesh)
	await frames(3)
	check("the front-hinged sheet is the default, leaning back 15 degrees", table.sketch_sheet_front and is_equal_approx(table.sketch_lean_back_degrees, 15.0) and is_equal_approx(table.sketch_tilt(), 75.0))

	for lean in [15.0, 10.0, 25.0]:
		table.sketch_lean_back_degrees = lean
		table.orient_to_plane(plane())
		await frames(2)
		var edge := lower_edge_and_angle()
		var lower: Vector3 = edge[0]
		check("lean %d: the sheet's lower edge is on the slab's front edge less the drawer's depth (z within 5 mm: the sheet stands behind the selection drawer) and just above the glass" % int(lean), absf(lower.z - (table.slab_size.y * 0.5 - SelectionDrawer.DRAWER_SIZE.y)) < 0.005 and lower.y > 0.0 and lower.y < 0.03)
		check("lean %d: the sheet stands %d degrees up from the slab (the angle between their normals)" % [int(lean), int(90 - lean)], absf(float(edge[1]) - (90.0 - lean)) < 0.1)
		check("lean %d: the window anchor is the sheet's middle and the sketch plane passes through it" % int(lean), table.window_anchor.is_equal_approx(table.sheet_centre()) and absf((table.window_anchor - table.pivot.position - table.pivot.basis * (table.table_copy.transform * Vector3.ZERO)).dot(table.window_anchor_normal)) < 0.002)
		var back: Vector3 = table._plane_origin_at_sheet(table.sketch_rotation(plane()), 1.0, plane())
		check("lean %d: the pose Reset and Fit return to puts the plane's origin on the sheet's middle" % int(lean), (back + table.sketch_rotation(plane()).orthonormalized() * (table.table_copy.transform * Vector3.ZERO)).is_equal_approx(table.sheet_centre()))

	# --- the sheet stays at the front edge at the smallest and largest slab, and the eye sees it above the deck
	var eye := Camera3D.new()
	main.add_child(eye)
	eye.make_current()
	for size in [Vector2(0.5, 0.3), Vector2(1.4, 0.8)]:
		table.set_slab_size(size)
		table.recall()
		await frames(2)
		table.sketch_lean_back_degrees = 15.0
		table.orient_to_plane(plane())
		await frames(2)
		var lower2: Vector3 = lower_edge_and_angle()[0]
		check("slab %s: the lower edge follows the front edge (behind the drawer)" % str(size), absf(lower2.z - (size.y * 0.5 - SelectionDrawer.DRAWER_SIZE.y)) < 0.005)
		eye.global_transform = camera.global_transform
		var sheet_edge: Vector2 = eye.unproject_position(table.to_global(lower2))
		var deck_top: Vector2 = eye.unproject_position(table.to_global(Vector3(0.0, -0.01, size.y * 0.5 + table.deck_gap)))
		check("slab %s: from the standing eye point the sheet's lower edge is above the deck's top edge on screen" % str(size), sheet_edge.y < deck_top.y)

	# --- "Middle" is the old sheet
	table.set_slab_size(Vector2(0.6, 0.4))
	table.sketch_sheet_front = false
	table.orient_to_plane(plane())
	await frames(2)
	check("Middle: 60 degrees up and the window anchor is not the front sheet's middle", is_equal_approx(table.sketch_tilt(), 60.0) and not table.window_anchor.is_equal_approx(table.sheet_centre()))

	# --- settings
	var settings = AppSettings.new()
	settings.table_sheet_front = true
	check("default settings: front, 15", settings.table_sheet_front and settings.table_sheet_lean == 15)
	settings.set_table_sheet(false, 25)
	var again = AppSettings.new()
	again.load_from_disk()
	check("the choice and the lean are saved and read back", again.table_sheet_front == false and again.table_sheet_lean == 25)
	table.apply_settings(again)
	check("apply_settings hands them to the table", table.sketch_sheet_front == false and is_equal_approx(table.sketch_lean_back_degrees, 25.0))
	settings.set_table_sheet(true, 15)
	table.apply_settings(settings)
	quit()
